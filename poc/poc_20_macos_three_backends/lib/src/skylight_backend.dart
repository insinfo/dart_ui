import 'dart:async';
import 'dart:ffi';
import 'dart:io' show sleep;

import 'package:ffi/ffi.dart';

import 'backend_contract.dart';
import 'backend_policy.dart';
import 'core_graphics_types.dart';
import 'synthetic_input.dart';

// ---------------------------------------------------------------------------
// Backend 1 - SkyLight/CGS, extracted from poc_03's probe.dart.
//
// The probe proved the route; this is the same route with ownership. Every
// native handle acquired here has exactly one owner field and is released in
// reverse acquisition order by [shutdown], so the process can return from
// main() instead of calling _exit().
//
// Two hard constraints inherited from the probe, both measured in CI:
//
//   1. The initialisation order is fixed. SLPSRegisterWithServer(3) must run
//      BEFORE the first window, the way AppKit/HIServices does it. Registering
//      after the window returns paramErr (-50) or leaves the event queue empty.
//   2. One Mach message yields exactly ONE SLEventCreateNextEvent read. Draining
//      to NULL - correct for JankyBorders, which only consumes events other
//      processes produce - blocks in mach_msg for a process that injects its
//      own events.
//
// Everything between installing the run-loop source and the last pump slice
// runs without an await: the isolate does not own the main thread, so a
// suspension can resume it on another VM worker whose CFRunLoop is not the one
// holding the event source. [threadIsStable] reports whether that happened.
// ---------------------------------------------------------------------------

typedef _VoidPtr = Pointer<Void>;

typedef _MachPortCallbackNative = Void Function(
    _VoidPtr port, _VoidPtr message, IntPtr size, _VoidPtr context);

typedef _SlsNotifyCallbackNative = Void Function(
    Uint32 event, _VoidPtr data, IntPtr size, _VoidPtr context);

const _kCGSBackingStoreBuffered = 2;
// What AppKit passes to SLSNewWindowWithOpaqueShape on macOS 27: a window
// whose content is a hosted CAContext (SLSSetWindowLayerContext insists on it).
const _kSLSWindowTypeLayerHosting = 5;
const _kCGKeyboardEventKeycode = 9;

/// CGEventType values seen on macOS 14 arm64 for injected input.
MacosInputKind? _kindForEventType(int type) => switch (type) {
      1 => MacosInputKind.pointerDown,
      2 => MacosInputKind.pointerUp,
      5 => MacosInputKind.pointerMove,
      10 => MacosInputKind.keyDown,
      11 => MacosInputKind.keyUp,
      22 => MacosInputKind.scroll,
      _ => null,
    };

class SkylightBackendReport {
  SkylightBackendReport();

  int connectionId = 0;
  int processRegistration = -1;

  /// GetCurrentProcess result: 0 once the process has a PSN, -1 if never asked.
  int launchServicesCheckIn = -1;
  int registrationAttempts = 0;
  int eventPort = 0;
  int windowId = 0;
  int machMessages = 0;
  int notifications = 0;
  int extraReads = 0;
  int windowEventMaskBefore = 0;
  int windowEventMaskAfter = 0;
  int eventsRead = 0;

  /// 'ca-layer' where WindowServer's CAWindowContent feature is on (macOS 27
  /// measured), 'cg-context' where it is off (macOS 14 CI).
  String presentation = '';
  final List<int> eventTypes = <int>[];
  final List<String> teardownSteps = <String>[];
  final List<String> missingSymbols = <String>[];
}

class SkylightBackend implements MacosWindowBackend {
  SkylightBackend({this.log = print});

  final void Function(String message) log;
  final MacosBackendLifecycle _lifecycle = MacosBackendLifecycle();
  final SkylightBackendReport report = SkylightBackendReport();
  final StreamController<MacosInputEvent> _events =
      StreamController<MacosInputEvent>.broadcast(sync: true);

  late final DynamicLibrary _skyLight;
  late final DynamicLibrary _coreGraphics;
  late final DynamicLibrary _coreFoundation;

  // Owned native handles, in acquisition order.
  NativeCallable<_MachPortCallbackNative>? _portCallback;
  NativeCallable<_SlsNotifyCallbackNative>? _notifyCallback;
  bool Function()? _readOneEvent;
  _VoidPtr _machPort = nullptr;
  _VoidPtr _runLoopSource = nullptr;
  _VoidPtr _runLoop = nullptr;
  _VoidPtr _region = nullptr;
  _VoidPtr _windowContext = nullptr;
  int _windowId = 0;
  // CA presentation (see [_caWindowContent]): our CAContext hosted in the
  // window and the one layer whose contents are the frame.
  _VoidPtr _caContext = nullptr;
  _VoidPtr _caLayer = nullptr;

  int _ownerThread = 0;
  bool _threadStable = true;

  @override
  MacosBackendKind get kind => MacosBackendKind.skylight;

  @override
  MacosBackendCapabilities get capabilities => const MacosBackendCapabilities(
        appKitSemantics: false,
        cpuPresentation: true,
        keyboardInput: true,
        pointerInput: true,
        normalShutdown: true,
      );

  @override
  MacosBackendState get state => _lifecycle.state;

  @override
  Stream<MacosInputEvent> get inputEvents => _events.stream;

  bool get threadIsStable => _threadStable;

  // --- library plumbing ------------------------------------------------------

  late final _pthreadSelf = DynamicLibrary.process()
      .lookupFunction<IntPtr Function(), int Function()>('pthread_self');
  late final _getpid = DynamicLibrary.process()
      .lookupFunction<Int32 Function(), int Function()>('getpid');
  late final SyntheticInput _syntheticInput = SyntheticInput();
  late final _cfRelease = _coreFoundation.lookupFunction<
      Void Function(_VoidPtr), void Function(_VoidPtr)>('CFRelease');

  // --- CA presentation plumbing ---------------------------------------------
  //
  // With WindowServer's CAWindowContent feature on, a window's backing store is
  // a Core Animation layer, and SkyLight updates it from blocks it always
  // dispatch_async()s to the MAIN queue (__CGSWindowUpdateBackingStoreData and
  // __CGSWindowReloadCABackingStoreLayer, lldb 2026-10-12). A Dart standalone
  // process never drains the main queue - thread 0 sits in Dart_RunLoop - so
  // SLWindowContextCreate drawing reached nobody: the window stayed
  // transparent. AppKit creates its windows with type 5 and hosts a CAContext
  // in them (SLSSetWindowLayerContext); doing the same, and committing the
  // CATransaction on this thread, needs no main thread at all.

  static final DynamicLibrary _objc =
      DynamicLibrary.open('/usr/lib/libobjc.A.dylib');
  late final DynamicLibrary _quartzCore = DynamicLibrary.open(
      '/System/Library/Frameworks/QuartzCore.framework/QuartzCore');
  late final _getClass = _objc.lookupFunction<_VoidPtr Function(Pointer<Utf8>),
      _VoidPtr Function(Pointer<Utf8>)>('objc_getClass');
  late final _registerSelector = _objc.lookupFunction<
      _VoidPtr Function(Pointer<Utf8>),
      _VoidPtr Function(Pointer<Utf8>)>('sel_registerName');
  late final _send = _objc.lookupFunction<_VoidPtr Function(_VoidPtr, _VoidPtr),
      _VoidPtr Function(_VoidPtr, _VoidPtr)>('objc_msgSend');
  late final _sendObject = _objc.lookupFunction<
      _VoidPtr Function(_VoidPtr, _VoidPtr, _VoidPtr),
      _VoidPtr Function(_VoidPtr, _VoidPtr, _VoidPtr)>('objc_msgSend');
  late final _sendBool = _objc.lookupFunction<
      _VoidPtr Function(_VoidPtr, _VoidPtr, Bool),
      _VoidPtr Function(_VoidPtr, _VoidPtr, bool)>('objc_msgSend');
  late final _sendRect = _objc.lookupFunction<
      _VoidPtr Function(_VoidPtr, _VoidPtr, CGRectNative),
      _VoidPtr Function(_VoidPtr, _VoidPtr, CGRectNative)>('objc_msgSend');
  late final _sendConnection = _objc.lookupFunction<
      _VoidPtr Function(_VoidPtr, _VoidPtr, Uint32, _VoidPtr),
      _VoidPtr Function(_VoidPtr, _VoidPtr, int, _VoidPtr)>('objc_msgSend');
  late final _poolPush =
      _objc.lookupFunction<_VoidPtr Function(), _VoidPtr Function()>(
          'objc_autoreleasePoolPush');
  late final _poolPop =
      _objc.lookupFunction<Void Function(_VoidPtr), void Function(_VoidPtr)>(
          'objc_autoreleasePoolPop');

  _VoidPtr _class(String name) {
    final native = name.toNativeUtf8();
    try {
      return _getClass(native);
    } finally {
      calloc.free(native);
    }
  }

  final Map<String, _VoidPtr> _selectors = <String, _VoidPtr>{};
  _VoidPtr _sel(String name) => _selectors.putIfAbsent(name, () {
        final native = name.toNativeUtf8();
        try {
          return _registerSelector(native);
        } finally {
          calloc.free(native);
        }
      });

  /// The switch SkyLight itself reads in SLSGetWindowLayerContext.
  bool get _caWindowContent {
    try {
      final enabled = DynamicLibrary.process().lookupFunction<
          Bool Function(Pointer<Utf8>, Pointer<Utf8>),
          bool Function(
              Pointer<Utf8>, Pointer<Utf8>)>('_os_feature_enabled_impl');
      final domain = 'WindowServer'.toNativeUtf8();
      final feature = 'CAWindowContent'.toNativeUtf8();
      try {
        return enabled(domain, feature);
      } finally {
        calloc.free(domain);
        calloc.free(feature);
      }
    } on ArgumentError {
      return false; // No feature flags at all: an old system, the CG path.
    }
  }

  /// Our CAContext on this connection, one layer the size of the window, and
  /// the context installed as the window's content.
  void _installLayerContext(int width, int height) {
    _quartzCore; // CAContext and CALayer live here.
    final pool = _poolPush();
    try {
      _caContext = _sendConnection(
          _class('CAContext'),
          _sel('contextWithCGSConnection:options:'),
          report.connectionId,
          nullptr);
      if (_caContext == nullptr) throw StateError('CAContext');
      _send(_caContext, _sel('retain'));
      _caLayer = _send(_send(_class('CALayer'), _sel('layer')), _sel('retain'));

      final transaction = _class('CATransaction');
      _send(transaction, _sel('begin'));
      _sendBool(transaction, _sel('setDisableActions:'), true);
      final frame = calloc<CGRectNative>()
        ..ref.width = width.toDouble()
        ..ref.height = height.toDouble();
      _sendRect(_caLayer, _sel('setFrame:'), frame.ref);
      calloc.free(frame);
      // The frame must be shown pixel for pixel, never resampled.
      final nearest = _quartzCore.lookup<_VoidPtr>('kCAFilterNearest').value;
      _sendObject(_caLayer, _sel('setMagnificationFilter:'), nearest);
      _sendObject(_caLayer, _sel('setMinificationFilter:'), nearest);
      _sendObject(_caContext, _sel('setLayer:'), _caLayer);
      _send(transaction, _sel('commit'));

      final rc = _skyLight.lookupFunction<
          Int32 Function(Int32, Uint32, _VoidPtr),
          int Function(int, int, _VoidPtr)>('SLSSetWindowLayerContext')(
        report.connectionId,
        _windowId,
        _caContext,
      );
      log('SLSSetWindowLayerContext -> $rc');
      if (rc != 0) throw StateError('SLSSetWindowLayerContext -> $rc');
    } finally {
      _poolPop(pool);
    }
  }

  /// Makes [image] the layer's contents and pushes it to the render server
  /// from this thread. The layer retains the image.
  void _presentOnLayer(_VoidPtr image) {
    final pool = _poolPush();
    try {
      final transaction = _class('CATransaction');
      _send(transaction, _sel('begin'));
      _sendBool(transaction, _sel('setDisableActions:'), true);
      _sendObject(_caLayer, _sel('setContents:'), image);
      _send(transaction, _sel('commit'));
      // A thread without a run loop has nobody to commit implicit work later.
      _send(transaction, _sel('flush'));
    } finally {
      _poolPop(pool);
    }
  }

  T? _optional<T>(T Function() lookup, String symbol) {
    try {
      return lookup();
    } on ArgumentError {
      report.missingSymbols.add(symbol);
      return null;
    }
  }

  void _checkThread(String where) {
    final current = _pthreadSelf();
    if (_ownerThread != 0 && current != _ownerThread) {
      _threadStable = false;
      log('THREAD_MIGRATED at $where: $_ownerThread -> $current');
    }
  }

  // --- lifecycle -------------------------------------------------------------

  @override
  Future<void> initialize() async => initializeSync();

  /// Steps 1-5 of the measured initialisation order.
  ///
  /// Runs inside an autorelease pool, as [createWindowSync] and [presentSync]
  /// do: this thread is a Dart thread, not AppKit's, so nothing drains the
  /// objects SkyLight, CoreGraphics and the Swift runtime autorelease - on
  /// macOS 27 that is an `OS_os_log` and a `ProcessInfo` here and a `CFData`
  /// per frame in [presentSync], each logged as `MISSING POOLS` and leaked.
  void initializeSync() => _inPool(_initializeSync);

  T _inPool<T>(T Function() body) {
    final pool = _poolPush();
    try {
      return body();
    } finally {
      _poolPop(pool);
    }
  }

  void _initializeSync() {
    _lifecycle.beginInitialize();
    try {
      _skyLight = DynamicLibrary.open(
          '/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight');
      _coreGraphics = DynamicLibrary.open(
          '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics');
      _coreFoundation = DynamicLibrary.open(
          '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation');

      _ownerThread = _pthreadSelf();

      report.connectionId =
          _skyLight.lookupFunction<Int32 Function(), int Function()>(
              'SLSMainConnectionID')();
      log('SLSMainConnectionID -> ${report.connectionId}');
      if (report.connectionId == 0) {
        throw StateError('no CGS connection');
      }

      // Order matters: the process must exist for the WindowServer before it
      // owns a window, otherwise input is never routed to it.
      _registerProcess();

      _installEventPort();
      _lifecycle.finishInitialize();
    } catch (error) {
      _lifecycle.failInitialize();
      log('INITIALIZE_FAILED: $error');
      rethrow;
    }
  }

  /// Registers the process with the WindowServer, retrying paramErr.
  ///
  /// The macOS 14 disassembly of `SLPSRegisterWithServer` shows it asking
  /// LaunchServices for this process: `_LSASNCreateWithPid` then
  /// `_LSCopyApplicationInformationItem`, with an error return when either
  /// comes back null. For a plain command-line binary that answer is not
  /// always ready on the first call - run 31243093662 got -50 from one process
  /// while another in the same job got 0 - so a bounded retry is the fix, not
  /// a different ABI.
  void _registerProcess() {
    _checkInWithLaunchServices();
    final register =
        _skyLight.lookupFunction<Int32 Function(Int32), int Function(int)>(
            'SLPSRegisterWithServer');
    for (var attempt = 1; attempt <= 12; attempt++) {
      report.registrationAttempts = attempt;
      report.processRegistration = register(3);
      log('SLPSRegisterWithServer(3) attempt $attempt -> '
          '${report.processRegistration}');
      if (report.processRegistration == 0) {
        // A first-call failure correlates with the WindowServer never
        // delivering events afterwards, even though the retry returns 0 (probe
        // Z17, runs 31243780407 and 31244128854). Whatever LaunchServices was
        // not ready for, give it time to settle before asking for the port.
        if (attempt > 1) sleep(const Duration(milliseconds: 500));
        return;
      }
      sleep(const Duration(milliseconds: 150));
    }
    throw StateError(
        'SLPSRegisterWithServer never succeeded (${report.processRegistration})');
  }

  /// Gives this process a PSN, the way AppKit does through
  /// `NSApplication -> GetCurrentProcess -> _RegisterApplication`.
  ///
  /// Without it SLPSGetCurrentProcess answers -600 (procNotFound) and the
  /// WindowServer delivers no physical mouse button to our windows, although
  /// SLSFindWindowAndOwner names them as the target of the click. Measured on
  /// macOS 27 with real HID clicks (2026-10-12): 0 events without this call,
  /// mouseDown/mouseUp with it, also with the main thread blocked.
  /// TransformProcessType on top of it made delivery worse and is not used.
  void _checkInWithLaunchServices() {
    final getCurrentProcess = _optional(
        () => DynamicLibrary.open('/System/Library/Frameworks/'
                'ApplicationServices.framework/ApplicationServices')
            .lookupFunction<Int16 Function(Pointer<Uint32>),
                int Function(Pointer<Uint32>)>('GetCurrentProcess'),
        'GetCurrentProcess');
    if (getCurrentProcess == null) return;
    final psn = calloc<Uint32>(2);
    try {
      report.launchServicesCheckIn = getCurrentProcess(psn);
      log('GetCurrentProcess -> ${report.launchServicesCheckIn} '
          'psn=${psn[0]}/${psn[1]}');
    } finally {
      calloc.free(psn);
    }
  }

  /// Event types JankyBorders subscribes to immediately before asking for the
  /// event port. The Z17 probe does this and receives `[10, 11, 5]`; the first
  /// version of this backend skipped it and received only `[10, 11]`.
  static const List<int> _notificationTypes = <int>[
    723,
    804,
    806,
    807,
    808,
    811,
    815,
    816,
    1322,
    1325,
    1326,
    1401,
    1508
  ];

  void _registerNotifications() {
    final registerNotify = _skyLight.lookupFunction<
        Int32 Function(Pointer<NativeFunction<_SlsNotifyCallbackNative>>,
            Uint32, _VoidPtr),
        int Function(Pointer<NativeFunction<_SlsNotifyCallbackNative>>, int,
            _VoidPtr)>('SLSRegisterNotifyProc');
    _notifyCallback = NativeCallable<_SlsNotifyCallbackNative>.isolateLocal(
        (int event, _VoidPtr data, int size, _VoidPtr context) {
      report.notifications++;
    });
    final results = <int>[
      for (final type in _notificationTypes)
        registerNotify(_notifyCallback!.nativeFunction, type, nullptr)
    ];
    log('SLSRegisterNotifyProc x${_notificationTypes.length} -> $results');
  }

  void _installEventPort() {
    _registerNotifications();
    final portSlot = calloc<Uint32>();
    try {
      final rc = _skyLight.lookupFunction<
          Int32 Function(Int32, Pointer<Uint32>),
          int Function(int, Pointer<Uint32>)>('SLSGetEventPort')(
        report.connectionId,
        portSlot,
      );
      report.eventPort = portSlot.value;
      log('SLSGetEventPort -> rc=$rc port=${report.eventPort}');
      if (rc != 0 || report.eventPort == 0) {
        throw StateError('SLSGetEventPort failed (rc=$rc)');
      }
    } finally {
      calloc.free(portSlot);
    }

    final createNextEvent = _skyLight.lookupFunction<_VoidPtr Function(Int32),
        _VoidPtr Function(int)>('SLEventCreateNextEvent');
    final getType = _skyLight.lookupFunction<Uint32 Function(_VoidPtr),
        int Function(_VoidPtr)>('SLEventGetType');
    final getLocation = _coreGraphics.lookupFunction<
        CGPointNative Function(_VoidPtr),
        CGPointNative Function(_VoidPtr)>('CGEventGetLocation');
    final getField = _coreGraphics.lookupFunction<
        Int64 Function(_VoidPtr, Uint32),
        int Function(_VoidPtr, int)>('CGEventGetIntegerValueField');
    final poolPush = DynamicLibrary.process()
        .lookupFunction<_VoidPtr Function(), _VoidPtr Function()>(
            'objc_autoreleasePoolPush');
    final poolPop = DynamicLibrary.process()
        .lookupFunction<Void Function(_VoidPtr), void Function(_VoidPtr)>(
            'objc_autoreleasePoolPop');

    final generation = _lifecycle.generation;
    _readOneEvent = () {
      // SLEventCreateNextEvent autoreleases internally (SDL #14256): without a
      // pool this leaks and logs "MISSING POOLS" under OBJC_DEBUG_MISSING_POOLS.
      final pool = poolPush();
      try {
        // Exactly one read per message. See the header comment.
        final event = createNextEvent(report.connectionId);
        if (event == nullptr) return false;
        final type = getType(event);
        report.eventsRead++;
        if (report.eventTypes.length < 64) report.eventTypes.add(type);
        final kind = _kindForEventType(type);
        if (kind != null && !_events.isClosed) {
          final location = getLocation(event);
          _events.add(MacosInputEvent(
            kind: kind,
            windowId: _windowId,
            generation: generation,
            x: location.x,
            y: location.y,
            keyCode:
                kind == MacosInputKind.keyDown || kind == MacosInputKind.keyUp
                    ? getField(event, _kCGKeyboardEventKeycode)
                    : null,
          ));
        }
        _cfRelease(event);
        return true;
      } finally {
        poolPop(pool);
      }
    };

    _portCallback = NativeCallable<_MachPortCallbackNative>.isolateLocal(
        (_VoidPtr port, _VoidPtr message, int size, _VoidPtr context) {
      report.machMessages++;
      _readOneEvent!();
    });

    _machPort = _coreFoundation.lookupFunction<
        _VoidPtr Function(
            _VoidPtr,
            Uint32,
            Pointer<NativeFunction<_MachPortCallbackNative>>,
            _VoidPtr,
            Pointer<Bool>),
        _VoidPtr Function(
            _VoidPtr,
            int,
            Pointer<NativeFunction<_MachPortCallbackNative>>,
            _VoidPtr,
            Pointer<Bool>)>('CFMachPortCreateWithPort')(
      nullptr,
      report.eventPort,
      _portCallback!.nativeFunction,
      nullptr,
      nullptr.cast<Bool>(),
    );
    log('CFMachPortCreateWithPort -> ${_machPort.address}');
    if (_machPort == nullptr) throw StateError('CFMachPortCreateWithPort');
    // Parity with JankyBorders; the flag's exact meaning is still unknown.
    _coreFoundation.lookupFunction<Void Function(_VoidPtr, Int32),
        void Function(_VoidPtr, int)>('_CFMachPortSetOptions')(_machPort, 0x40);

    _runLoopSource = _coreFoundation.lookupFunction<
        _VoidPtr Function(_VoidPtr, _VoidPtr, IntPtr),
        _VoidPtr Function(
            _VoidPtr, _VoidPtr, int)>('CFMachPortCreateRunLoopSource')(
      nullptr,
      _machPort,
      0,
    );
    _runLoop = _coreFoundation.lookupFunction<_VoidPtr Function(),
        _VoidPtr Function()>('CFRunLoopGetCurrent')();
    if (_runLoopSource == nullptr || _runLoop == nullptr) {
      throw StateError('no run loop source');
    }
    _coreFoundation.lookupFunction<Void Function(_VoidPtr, _VoidPtr, _VoidPtr),
        void Function(_VoidPtr, _VoidPtr, _VoidPtr)>('CFRunLoopAddSource')(
      _runLoop,
      _runLoopSource,
      _defaultMode,
    );
    log('event source installed on run loop ${_runLoop.address}');
  }

  _VoidPtr get _defaultMode =>
      _coreFoundation.lookup<_VoidPtr>('kCFRunLoopDefaultMode').value;

  // --- window ----------------------------------------------------------------

  @override
  Future<MacosWindow> createWindow(MacosWindowOptions options) async =>
      createWindowSync(options);

  MacosWindow createWindowSync(MacosWindowOptions options) =>
      _inPool(() => _createWindowSync(options));

  MacosWindow _createWindowSync(MacosWindowOptions options) {
    _lifecycle.requireRunning('create a window');
    _checkThread('createWindow');

    // The historic 200/200 region + 200/200 origin lands at (400, 400), but a
    // zero region with a 40/120 origin landed at (0, 0) on macOS 27: the origin
    // arguments are not a position. An explicit position therefore anchors the
    // region at zero and moves the window with SLSMoveWindow afterwards.
    final positioned = options.left != null && options.top != null;
    final regionOffset = positioned ? 0.0 : 200.0;
    final rect = calloc<CGRectNative>()
      ..ref.x = regionOffset
      ..ref.y = regionOffset
      ..ref.width = options.width.toDouble()
      ..ref.height = options.height.toDouble();
    final regionSlot = calloc<Pointer<Void>>();
    try {
      final regionRc = _skyLight.lookupFunction<
          Int32 Function(Pointer<CGRectNative>, Pointer<Pointer<Void>>),
          int Function(Pointer<CGRectNative>,
              Pointer<Pointer<Void>>)>('CGSNewRegionWithRect')(
        rect,
        regionSlot,
      );
      _region = regionSlot.value;
      if (regionRc != 0 || _region == nullptr) {
        throw StateError('CGSNewRegionWithRect -> $regionRc');
      }
    } finally {
      calloc.free(rect);
      calloc.free(regionSlot);
    }

    final layerHosting = _caWindowContent;
    report.presentation = layerHosting ? 'ca-layer' : 'cg-context';
    log('presentation -> ${report.presentation}');

    final windowIdSlot = calloc<Uint32>();
    try {
      final rc = _skyLight.lookupFunction<
          Int32 Function(
              Int32, Int32, Double, Double, _VoidPtr, Pointer<Uint32>),
          int Function(int, int, double, double, _VoidPtr,
              Pointer<Uint32>)>('SLSNewWindow')(
        report.connectionId,
        layerHosting ? _kSLSWindowTypeLayerHosting : _kCGSBackingStoreBuffered,
        regionOffset,
        regionOffset,
        _region,
        windowIdSlot,
      );
      _windowId = windowIdSlot.value;
      log('SLSNewWindow -> rc=$rc wid=$_windowId');
      if (rc != 0 || _windowId == 0) throw StateError('SLSNewWindow -> $rc');
    } finally {
      calloc.free(windowIdSlot);
    }
    report.windowId = _windowId;

    if (positioned) {
      final point = calloc<CGPointNative>()
        ..ref.x = options.left!.toDouble()
        ..ref.y = options.top!.toDouble();
      try {
        final rc = _skyLight.lookupFunction<
            Int32 Function(Int32, Uint32, Pointer<CGPointNative>),
            int Function(int, int, Pointer<CGPointNative>)>('SLSMoveWindow')(
          report.connectionId,
          _windowId,
          point,
        );
        log('SLSMoveWindow(${options.left}, ${options.top}) -> $rc');
      } finally {
        calloc.free(point);
      }
    }

    if (layerHosting) {
      _installLayerContext(options.width, options.height);
    } else {
      _windowContext = _skyLight.lookupFunction<
          _VoidPtr Function(Int32, Uint32, _VoidPtr),
          _VoidPtr Function(int, int, _VoidPtr)>('SLWindowContextCreate')(
        report.connectionId,
        _windowId,
        nullptr,
      );
      if (_windowContext == nullptr) throw StateError('SLWindowContextCreate');
    }

    _requestAllWindowEvents();

    _skyLight.lookupFunction<Int32 Function(Int32, Uint32, Int32, Uint32),
        int Function(int, int, int, int)>('SLSOrderWindow')(
      report.connectionId,
      _windowId,
      1,
      0,
    );
    return MacosWindow(id: _windowId, generation: _lifecycle.generation);
  }

  /// A window only receives the event types its mask asks for, which is what
  /// `-[NSWindow setAcceptsMouseMovedEvents:]` ends up doing for AppKit. The
  /// export dump surfaced the pair; ask for everything and record what the mask
  /// was before, so a future narrowing has a baseline.
  void _requestAllWindowEvents() {
    final get = _optional(
        () => _skyLight.lookupFunction<
            Int32 Function(Int32, Uint32, Pointer<Uint32>),
            int Function(int, int, Pointer<Uint32>)>('SLSGetWindowEventMask'),
        'SLSGetWindowEventMask');
    final set = _optional(
        () => _skyLight.lookupFunction<Int32 Function(Int32, Uint32, Uint32),
            int Function(int, int, int)>('SLSSetWindowEventMask'),
        'SLSSetWindowEventMask');
    if (set == null) return;

    final slot = calloc<Uint32>();
    try {
      if (get != null) {
        get(report.connectionId, _windowId, slot);
        report.windowEventMaskBefore = slot.value;
      }
      final rc = set(report.connectionId, _windowId, 0xFFFFFFFF);
      if (get != null) {
        slot.value = 0;
        get(report.connectionId, _windowId, slot);
        report.windowEventMaskAfter = slot.value;
      }
      log('SLSSetWindowEventMask(0xFFFFFFFF) -> $rc '
          '(mask ${report.windowEventMaskBefore.toRadixString(16)} -> '
          '${report.windowEventMaskAfter.toRadixString(16)})');
    } finally {
      calloc.free(slot);
    }
  }

  // --- presentation ----------------------------------------------------------

  @override
  Future<void> present(MacosWindow window, MacosFrame frame) async =>
      presentSync(window, frame);

  /// Uploads a CPU BGRA framebuffer: into the hosted layer on the CA path, into
  /// the window's CGContext on the CG path.
  void presentSync(MacosWindow window, MacosFrame frame) =>
      _inPool(() => _presentSync(window, frame));

  void _presentSync(MacosWindow window, MacosFrame frame) {
    _lifecycle.requireRunning('present');
    _checkThread('present');
    if (window.generation != _lifecycle.generation) {
      throw MacosBackendStateError('stale window generation');
    }

    final pixels = calloc<Uint8>(frame.bgraPremultiplied.length);
    pixels
        .asTypedList(frame.bgraPremultiplied.length)
        .setAll(0, frame.bgraPremultiplied);

    // The provider owns a copy: on the CA path the render server may read the
    // image after this call returns, long after `pixels` is freed below.
    final data = _coreFoundation.lookupFunction<
        _VoidPtr Function(_VoidPtr, Pointer<Uint8>, IntPtr),
        _VoidPtr Function(_VoidPtr, Pointer<Uint8>, int)>('CFDataCreate')(
      nullptr,
      pixels,
      frame.bgraPremultiplied.length,
    );
    final provider = _coreGraphics.lookupFunction<_VoidPtr Function(_VoidPtr),
        _VoidPtr Function(_VoidPtr)>('CGDataProviderCreateWithCFData')(data);
    _cfRelease(data);
    calloc.free(pixels);
    final colorSpace =
        _coreGraphics.lookupFunction<_VoidPtr Function(), _VoidPtr Function()>(
            'CGColorSpaceCreateDeviceRGB')();
    // kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little => BGRA.
    const bitmapInfo = 2 | (2 << 12);
    final image = _coreGraphics.lookupFunction<
        _VoidPtr Function(IntPtr, IntPtr, IntPtr, IntPtr, IntPtr, _VoidPtr,
            Uint32, _VoidPtr, _VoidPtr, Bool, Int32),
        _VoidPtr Function(int, int, int, int, int, _VoidPtr, int, _VoidPtr,
            _VoidPtr, bool, int)>('CGImageCreate')(
      frame.width,
      frame.height,
      8,
      32,
      frame.bytesPerRow,
      colorSpace,
      bitmapInfo,
      provider,
      nullptr,
      false,
      0,
    );
    if (image == nullptr) throw StateError('CGImageCreate returned null');

    if (_caLayer != nullptr) {
      _presentOnLayer(image);
    } else {
      final rect = calloc<CGRectNative>()
        ..ref.x = 0
        ..ref.y = 0
        ..ref.width = frame.width.toDouble()
        ..ref.height = frame.height.toDouble();
      _coreGraphics.lookupFunction<
          Void Function(_VoidPtr, CGRectNative, _VoidPtr),
          void Function(
              _VoidPtr, CGRectNative, _VoidPtr)>('CGContextDrawImage')(
        _windowContext,
        rect.ref,
        image,
      );
      _coreGraphics.lookupFunction<Void Function(_VoidPtr),
          void Function(_VoidPtr)>('CGContextFlush')(_windowContext);
      calloc.free(rect);
    }

    _coreGraphics.lookupFunction<Void Function(_VoidPtr),
        void Function(_VoidPtr)>('CGImageRelease')(image);
    _coreGraphics.lookupFunction<Void Function(_VoidPtr),
        void Function(_VoidPtr)>('CGColorSpaceRelease')(colorSpace);
    _coreGraphics.lookupFunction<Void Function(_VoidPtr),
        void Function(_VoidPtr)>('CGDataProviderRelease')(provider);
  }

  // --- input -----------------------------------------------------------------

  /// Injects one key down/up pair and one pointer move into this process
  /// through the WindowServer - the same route physical input takes.
  /// [x] and [y] should differ between calls: the WindowServer has no reason
  /// to report a pointer move to a position the pointer is already at, which is
  /// why a fixed (400, 400) produced key events but never pointerMove.
  bool injectSyntheticInput({double x = 400, double y = 400}) =>
      _inPool(() => _syntheticInput.postTo(_getpid(), x: x, y: y));

  /// Runs the owning run loop in bounded slices. Synchronous by design.
  ///
  /// [extraReadsPerSlice] implements the rule the probes measured: one read per
  /// Mach message inside the callback, and any further drain scheduled
  /// separately. Three posted events arrived as two messages, which under a
  /// strict one-read-per-message rule leaves the third one sitting in the
  /// queue - the reason pointerMove never showed up. Draining to NULL inside
  /// the callback blocked in mach_msg; these reads happen outside it and are
  /// bounded.
  int pumpSync({
    required int slices,
    double sliceSeconds = 0.05,
    int extraReadsPerSlice = 1,
  }) {
    _checkThread('pump');
    final runInMode = _coreFoundation.lookupFunction<
        Int32 Function(_VoidPtr, Double, Bool),
        int Function(_VoidPtr, double, bool)>('CFRunLoopRunInMode');
    final before = report.eventsRead;
    for (var i = 0; i < slices; i++) {
      final beforeSlice = report.eventsRead;
      // One pool per slice: the event port's callbacks autorelease the Mach
      // message payloads as CFData, and this thread has no run loop of
      // AppKit's to drain them.
      _inPool(() => runInMode(_defaultMode, sliceSeconds, true));
      // Only after a slice that actually delivered something: on an empty
      // queue this read is the one earlier probes saw block in mach_msg. A
      // slice that produced an event is exactly the case where the
      // WindowServer may have batched more into the same message.
      if (report.eventsRead > beforeSlice) {
        for (var extra = 0; extra < extraReadsPerSlice; extra++) {
          report.extraReads++;
          if (!(_readOneEvent?.call() ?? false)) break;
        }
      }
    }
    return report.eventsRead - before;
  }

  // --- teardown --------------------------------------------------------------

  @override
  Future<void> closeWindow(MacosWindow window) async => _releaseWindow();

  void _releaseWindow() {
    if (_windowContext != nullptr) {
      _coreGraphics.lookupFunction<Void Function(_VoidPtr),
          void Function(_VoidPtr)>('CGContextRelease')(_windowContext);
      _windowContext = nullptr;
      report.teardownSteps.add('CGContextRelease');
    }
    if (_windowId != 0) {
      final release = _optional(
          () => _skyLight.lookupFunction<Int32 Function(Int32, Uint32),
              int Function(int, int)>('SLSReleaseWindow'),
          'SLSReleaseWindow');
      if (release != null) {
        final rc = release(report.connectionId, _windowId);
        report.teardownSteps.add('SLSReleaseWindow=$rc');
      }
      _windowId = 0;
    }
    // The window no longer shows them; the hosted tree goes after it.
    if (_caLayer != nullptr || _caContext != nullptr) {
      final pool = _poolPush();
      if (_caContext != nullptr) {
        _sendObject(_caContext, _sel('setLayer:'), nullptr);
        _send(_caContext, _sel('release'));
        _caContext = nullptr;
      }
      if (_caLayer != nullptr) {
        _send(_caLayer, _sel('release'));
        _caLayer = nullptr;
      }
      _poolPop(pool);
      report.teardownSteps.add('CAContext+CALayer release');
    }
    if (_region != nullptr) {
      final release = _optional(
          () => _skyLight.lookupFunction<Int32 Function(_VoidPtr),
              int Function(_VoidPtr)>('CGSReleaseRegion'),
          'CGSReleaseRegion');
      if (release != null) {
        final rc = release(_region);
        report.teardownSteps.add('CGSReleaseRegion=$rc');
      }
      _region = nullptr;
    }
  }

  @override
  Future<void> shutdown() async => shutdownSync();

  /// Reverse acquisition order, idempotent, no `_exit`.
  bool shutdownSync() {
    if (!_lifecycle.beginShutdown()) return false;
    _releaseWindow();

    if (_runLoopSource != nullptr && _runLoop != nullptr) {
      _coreFoundation.lookupFunction<
          Void Function(_VoidPtr, _VoidPtr, _VoidPtr),
          void Function(_VoidPtr, _VoidPtr, _VoidPtr)>('CFRunLoopRemoveSource')(
        _runLoop,
        _runLoopSource,
        _defaultMode,
      );
      report.teardownSteps.add('CFRunLoopRemoveSource');
    }
    if (_runLoopSource != nullptr) {
      _cfRelease(_runLoopSource);
      _runLoopSource = nullptr;
      report.teardownSteps.add('CFRelease(source)');
    }
    if (_machPort != nullptr) {
      // Invalidate before release: the port must stop calling into the
      // NativeCallable before that callable is closed.
      _coreFoundation.lookupFunction<Void Function(_VoidPtr),
          void Function(_VoidPtr)>('CFMachPortInvalidate')(_machPort);
      _cfRelease(_machPort);
      _machPort = nullptr;
      report.teardownSteps.add('CFMachPortInvalidate+CFRelease');
    }
    _portCallback?.close();
    _portCallback = null;
    _notifyCallback?.close();
    _notifyCallback = null;
    report.teardownSteps.add('NativeCallable.close');
    if (!_events.isClosed) _events.close();

    _lifecycle.finishShutdown();
    return true;
  }
}
