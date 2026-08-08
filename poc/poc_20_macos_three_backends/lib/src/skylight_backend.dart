import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'backend_contract.dart';
import 'backend_policy.dart';

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

final class _CGRect extends Struct {
  @Double()
  external double x;
  @Double()
  external double y;
  @Double()
  external double width;
  @Double()
  external double height;
}

final class _CGPoint extends Struct {
  @Double()
  external double x;
  @Double()
  external double y;
}

typedef _MachPortCallbackNative = Void Function(
    _VoidPtr port, _VoidPtr message, IntPtr size, _VoidPtr context);

const _kCGSBackingStoreBuffered = 2;
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
  int eventPort = 0;
  int windowId = 0;
  int machMessages = 0;
  int eventsRead = 0;
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
  _VoidPtr _machPort = nullptr;
  _VoidPtr _runLoopSource = nullptr;
  _VoidPtr _runLoop = nullptr;
  _VoidPtr _region = nullptr;
  _VoidPtr _windowContext = nullptr;
  int _windowId = 0;

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

  late final _pthreadSelf =
      DynamicLibrary.process().lookupFunction<IntPtr Function(), int Function()>(
          'pthread_self');
  late final _getpid = DynamicLibrary.process()
      .lookupFunction<Int32 Function(), int Function()>('getpid');
  late final _cfRelease = _coreFoundation
      .lookupFunction<Void Function(_VoidPtr), void Function(_VoidPtr)>(
          'CFRelease');

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
  void initializeSync() {
    _lifecycle.beginInitialize();
    try {
      _skyLight = DynamicLibrary.open(
          '/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight');
      _coreGraphics = DynamicLibrary.open(
          '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics');
      _coreFoundation = DynamicLibrary.open(
          '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation');

      _ownerThread = _pthreadSelf();

      report.connectionId = _skyLight
          .lookupFunction<Int32 Function(), int Function()>(
              'SLSMainConnectionID')();
      log('SLSMainConnectionID -> ${report.connectionId}');
      if (report.connectionId == 0) {
        throw StateError('no CGS connection');
      }

      // Order matters: the process must exist for the WindowServer before it
      // owns a window, otherwise input is never routed to it.
      report.processRegistration = _skyLight
          .lookupFunction<Int32 Function(Int32), int Function(int)>(
              'SLPSRegisterWithServer')(3);
      log('SLPSRegisterWithServer(3) -> ${report.processRegistration}');

      _installEventPort();
      _lifecycle.finishInitialize();
    } catch (error) {
      _lifecycle.failInitialize();
      log('INITIALIZE_FAILED: $error');
      rethrow;
    }
  }

  void _installEventPort() {
    final portSlot = calloc<Uint32>();
    try {
      final rc = _skyLight.lookupFunction<Int32 Function(Int32, Pointer<Uint32>),
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
    final getType = _skyLight
        .lookupFunction<Uint32 Function(_VoidPtr), int Function(_VoidPtr)>(
            'SLEventGetType');
    final getLocation = _coreGraphics.lookupFunction<_CGPoint Function(_VoidPtr),
        _CGPoint Function(_VoidPtr)>('CGEventGetLocation');
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
    _portCallback = NativeCallable<_MachPortCallbackNative>.isolateLocal(
        (_VoidPtr port, _VoidPtr message, int size, _VoidPtr context) {
      report.machMessages++;
      // SLEventCreateNextEvent autoreleases internally (SDL #14256): without a
      // pool this leaks and logs "MISSING POOLS" under OBJC_DEBUG_MISSING_POOLS.
      final pool = poolPush();
      try {
        // Exactly one read per message. See the header comment.
        final event = createNextEvent(report.connectionId);
        if (event == nullptr) return;
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
            keyCode: kind == MacosInputKind.keyDown ||
                    kind == MacosInputKind.keyUp
                ? getField(event, _kCGKeyboardEventKeycode)
                : null,
          ));
        }
        _cfRelease(event);
      } finally {
        poolPop(pool);
      }
    });

    _machPort = _coreFoundation.lookupFunction<
        _VoidPtr Function(_VoidPtr, Uint32,
            Pointer<NativeFunction<_MachPortCallbackNative>>, _VoidPtr,
            Pointer<Bool>),
        _VoidPtr Function(_VoidPtr, int,
            Pointer<NativeFunction<_MachPortCallbackNative>>, _VoidPtr,
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
    _runLoop = _coreFoundation
        .lookupFunction<_VoidPtr Function(), _VoidPtr Function()>(
            'CFRunLoopGetCurrent')();
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

  MacosWindow createWindowSync(MacosWindowOptions options) {
    _lifecycle.requireRunning('create a window');
    _checkThread('createWindow');

    final rect = calloc<_CGRect>()
      ..ref.x = 200
      ..ref.y = 200
      ..ref.width = options.width.toDouble()
      ..ref.height = options.height.toDouble();
    final regionSlot = calloc<Pointer<Void>>();
    try {
      final regionRc = _skyLight.lookupFunction<
          Int32 Function(Pointer<_CGRect>, Pointer<Pointer<Void>>),
          int Function(Pointer<_CGRect>,
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

    final windowIdSlot = calloc<Uint32>();
    try {
      final rc = _skyLight.lookupFunction<
          Int32 Function(Int32, Int32, Double, Double, _VoidPtr, Pointer<Uint32>),
          int Function(int, int, double, double, _VoidPtr,
              Pointer<Uint32>)>('SLSNewWindow')(
        report.connectionId,
        _kCGSBackingStoreBuffered,
        200.0,
        200.0,
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

    _windowContext = _skyLight.lookupFunction<
        _VoidPtr Function(Int32, Uint32, _VoidPtr),
        _VoidPtr Function(int, int, _VoidPtr)>('SLWindowContextCreate')(
      report.connectionId,
      _windowId,
      nullptr,
    );
    if (_windowContext == nullptr) throw StateError('SLWindowContextCreate');

    _skyLight.lookupFunction<Int32 Function(Int32, Uint32, Int32, Uint32),
        int Function(int, int, int, int)>('SLSOrderWindow')(
      report.connectionId,
      _windowId,
      1,
      0,
    );
    return MacosWindow(id: _windowId, generation: _lifecycle.generation);
  }

  // --- presentation ----------------------------------------------------------

  @override
  Future<void> present(MacosWindow window, MacosFrame frame) async =>
      presentSync(window, frame);

  /// Uploads a CPU BGRA framebuffer into the window's CGContext.
  void presentSync(MacosWindow window, MacosFrame frame) {
    _lifecycle.requireRunning('present');
    _checkThread('present');
    if (window.generation != _lifecycle.generation) {
      throw MacosBackendStateError('stale window generation');
    }

    final pixels = calloc<Uint8>(frame.bgraPremultiplied.length);
    pixels
        .asTypedList(frame.bgraPremultiplied.length)
        .setAll(0, frame.bgraPremultiplied);

    final provider = _coreGraphics.lookupFunction<
        _VoidPtr Function(_VoidPtr, _VoidPtr, IntPtr, _VoidPtr),
        _VoidPtr Function(_VoidPtr, _VoidPtr, int,
            _VoidPtr)>('CGDataProviderCreateWithData')(
      nullptr,
      pixels.cast(),
      frame.bgraPremultiplied.length,
      nullptr,
    );
    final colorSpace = _coreGraphics
        .lookupFunction<_VoidPtr Function(), _VoidPtr Function()>(
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
    if (image == nullptr) {
      calloc.free(pixels);
      throw StateError('CGImageCreate returned null');
    }

    final rect = calloc<_CGRect>()
      ..ref.x = 0
      ..ref.y = 0
      ..ref.width = frame.width.toDouble()
      ..ref.height = frame.height.toDouble();
    _coreGraphics.lookupFunction<Void Function(_VoidPtr, _CGRect, _VoidPtr),
        void Function(_VoidPtr, _CGRect, _VoidPtr)>('CGContextDrawImage')(
      _windowContext,
      rect.ref,
      image,
    );
    _coreGraphics
        .lookupFunction<Void Function(_VoidPtr), void Function(_VoidPtr)>(
            'CGContextFlush')(_windowContext);
    calloc.free(rect);

    _coreGraphics
        .lookupFunction<Void Function(_VoidPtr), void Function(_VoidPtr)>(
            'CGImageRelease')(image);
    _coreGraphics
        .lookupFunction<Void Function(_VoidPtr), void Function(_VoidPtr)>(
            'CGColorSpaceRelease')(colorSpace);
    _coreGraphics
        .lookupFunction<Void Function(_VoidPtr), void Function(_VoidPtr)>(
            'CGDataProviderRelease')(provider);
    // CGImageCreate copies nothing; the provider held the buffer and is gone
    // now, so the frame bytes can go too.
    calloc.free(pixels);
  }

  // --- input -----------------------------------------------------------------

  /// Injects one key down/up pair and one pointer move into this process
  /// through the WindowServer - the same route physical input takes.
  bool injectSyntheticInput() {
    final createKey = _coreGraphics.lookupFunction<
        _VoidPtr Function(_VoidPtr, Uint16, Bool),
        _VoidPtr Function(
            _VoidPtr, int, bool)>('CGEventCreateKeyboardEvent');
    final createMouse = _coreGraphics.lookupFunction<
        _VoidPtr Function(_VoidPtr, Uint32, _CGPoint, Uint32),
        _VoidPtr Function(
            _VoidPtr, int, _CGPoint, int)>('CGEventCreateMouseEvent');
    final postToPid = _skyLight.lookupFunction<Void Function(Int32, _VoidPtr),
        void Function(int, _VoidPtr)>('SLEventPostToPid');
    final pid = _getpid();

    final down = createKey(nullptr, 0, true);
    final up = createKey(nullptr, 0, false);
    if (down == nullptr) return false;
    postToPid(pid, down);
    if (up != nullptr) postToPid(pid, up);
    _cfRelease(down);
    if (up != nullptr) _cfRelease(up);

    final point = calloc<_CGPoint>()
      ..ref.x = 400
      ..ref.y = 400;
    final move = createMouse(nullptr, 5, point.ref, 0);
    calloc.free(point);
    if (move != nullptr) {
      postToPid(pid, move);
      _cfRelease(move);
    }
    return true;
  }

  /// Runs the owning run loop in bounded slices. Synchronous by design.
  int pumpSync({required int slices, double sliceSeconds = 0.05}) {
    _checkThread('pump');
    final runInMode = _coreFoundation.lookupFunction<
        Int32 Function(_VoidPtr, Double, Bool),
        int Function(_VoidPtr, double, bool)>('CFRunLoopRunInMode');
    final before = report.eventsRead;
    for (var i = 0; i < slices; i++) {
      runInMode(_defaultMode, sliceSeconds, true);
    }
    return report.eventsRead - before;
  }

  // --- teardown --------------------------------------------------------------

  @override
  Future<void> closeWindow(MacosWindow window) async => _releaseWindow();

  void _releaseWindow() {
    if (_windowContext != nullptr) {
      _coreGraphics
          .lookupFunction<Void Function(_VoidPtr), void Function(_VoidPtr)>(
              'CGContextRelease')(_windowContext);
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
      _coreFoundation.lookupFunction<Void Function(_VoidPtr, _VoidPtr, _VoidPtr),
          void Function(
              _VoidPtr, _VoidPtr, _VoidPtr)>('CFRunLoopRemoveSource')(
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
      _coreFoundation
          .lookupFunction<Void Function(_VoidPtr), void Function(_VoidPtr)>(
              'CFMachPortInvalidate')(_machPort);
      _cfRelease(_machPort);
      _machPort = nullptr;
      report.teardownSteps.add('CFMachPortInvalidate+CFRelease');
    }
    _portCallback?.close();
    _portCallback = null;
    report.teardownSteps.add('NativeCallable.close');
    if (!_events.isClosed) _events.close();

    _lifecycle.finishShutdown();
    return true;
  }
}
