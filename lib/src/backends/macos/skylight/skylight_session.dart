/// One connection to the WindowServer through SkyLight, with no AppKit.
///
/// The route `exploracao-inicial:poc/poc_20_macos_three_backends` measured (see
/// `doc/MACOS_TRES_BACKENDS.md`), with one change that makes it usable from
/// an asynchronous application: **no CFRunLoop**. The POC installed the event
/// port as a run-loop source on the current thread and then could not
/// `await` until the last pump, because a Dart isolate may resume on another
/// OS thread whose run loop does not hold the source. Here the port is
/// polled instead - `mach_port_get_attributes` reports how many messages are
/// queued without receiving any, and `SLEventCreateNextEvent` is called once
/// per queued message, exactly the "one read per message" rule the POC
/// found, but from whatever thread the isolate is on. Measured on macOS 27,
/// 2026-10-12: key down/up and pointer moves all arrive with an `await`
/// between every poll.
///
/// Everything else keeps the POC's measured constraints:
///
///   * the process registers with the WindowServer (`SLPSRegisterWithServer`)
///     and checks in with LaunchServices **before** the first window;
///   * where WindowServer's `CAWindowContent` feature is on (macOS 27) a
///     window's content is a hosted `CAContext` whose layer holds the frame,
///     committed with an explicit `CATransaction` from this thread - nothing
///     here ever needs the main thread;
///   * every call runs inside an autorelease pool, because this thread is
///     Dart's and nobody else drains it.
library;

import 'dart:ffi';
import 'dart:io' show Platform, sleep;
import 'dart:typed_data';

import '../../../ffi/objc_runtime.dart';
import '../../../foundation/diagnostics.dart';
import '../io_surface.dart' show macosCalloc, macosFree;
import '../macos_event_translation.dart';
import 'skylight_dock.dart';

typedef _VoidPtr = Pointer<Void>;

final class _CGPoint extends Struct {
  @Double()
  external double x;
  @Double()
  external double y;
}

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

typedef _NotifyNative = Void Function(Uint32, _VoidPtr, IntPtr, _VoidPtr);

const int _kCGSBackingStoreBuffered = 2;
const int _kSLSWindowTypeLayerHosting = 5;

/// `kCGBlendModeCopy`.
const int _kCGBlendModeCopy = 17;

// CGEventField numbers.
const int _fieldClickState = 1;
const int _fieldButtonNumber = 3;
const int _fieldKeycode = 9;
const int _fieldScrollAxis1 = 11;
const int _fieldScrollAxis2 = 12;
const int _fieldScrollContinuous = 88;
const int _fieldWindowUnderPointer = 91;
const int _fieldScrollPointAxis1 = 96;
const int _fieldScrollPointAxis2 = 97;

/// A SkyLight window: its id and what presents into it.
final class SkylightNativeWindow {
  SkylightNativeWindow._(this.id);

  /// The WindowServer's id. It changes when the CoreGraphics path grows a
  /// window, which replaces it (see [SkylightSession.resize]).
  int id;
  _VoidPtr _region = nullptr;
  _VoidPtr _cgContext = nullptr;
  Pointer<ObjCObject> _caContext = nullptr;
  Pointer<ObjCObject> _layer = nullptr;
  bool released = false;

  /// Top-left position in global points, as last placed.
  double x = 0;
  double y = 0;
  int width = 0;
  int height = 0;
}

/// The WindowServer connection and its event port.
final class SkylightSession {
  SkylightSession._(this._skyLight, this._coreGraphics, this._coreFoundation,
      this.connectionId);

  /// Opens the connection and registers the process, or returns null with
  /// [diagnostics] explaining why - no SkyLight (not macOS), no connection
  /// (no GUI session), or a registration the WindowServer never accepted.
  static SkylightSession? open(List<BackendDiagnostic> diagnostics) {
    final DynamicLibrary skyLight;
    final DynamicLibrary coreGraphics;
    final DynamicLibrary coreFoundation;
    try {
      skyLight = DynamicLibrary.open(
          '/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight');
      coreGraphics = DynamicLibrary.open(
          '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics');
      coreFoundation = DynamicLibrary.open('/System/Library/Frameworks/'
          'CoreFoundation.framework/CoreFoundation');
    } on Object catch (error) {
      diagnostics.add(BackendDiagnostic.missingLibrary('SkyLight.framework',
          detail: '$error'));
      return null;
    }
    return ObjCAutoreleasePool.run(() {
      final int connection =
          skyLight.lookupFunction<Int32 Function(), int Function()>(
              'SLSMainConnectionID')();
      if (connection == 0) {
        diagnostics.add(const BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'SkyLight: no WindowServer connection (no GUI session)',
        ));
        return null;
      }
      final SkylightSession session =
          SkylightSession._(skyLight, coreGraphics, coreFoundation, connection);
      if (!session._register(diagnostics) ||
          !session._installEventPort(diagnostics)) {
        session.dispose();
        return null;
      }
      session.dock = SkylightDock.open(coreFoundation);
      return session;
    });
  }

  final DynamicLibrary _skyLight;
  final DynamicLibrary _coreGraphics;
  final DynamicLibrary _coreFoundation;
  final int connectionId;
  int _eventPort = 0;

  /// The Dock tile and its minimise, null when the process could not
  /// become a foreground application.
  SkylightDock? dock;
  NativeCallable<_NotifyNative>? _notify;
  bool _disposed = false;

  late final DynamicLibrary _quartzCore = DynamicLibrary.open(
      '/System/Library/Frameworks/QuartzCore.framework/QuartzCore');

  late final void Function(_VoidPtr) _cfRelease = _coreFoundation
      .lookupFunction<Void Function(_VoidPtr), void Function(_VoidPtr)>(
          'CFRelease');

  /// Whether window content is a hosted Core Animation layer (macOS 27) or a
  /// CoreGraphics backing store (macOS 14 and the CI runner).
  /// `DART_UI_SKYLIGHT_CG=1` forces the backing store, to exercise that
  /// path on a Mac that would host a layer.
  late final bool layerHosting = () {
    if (Platform.environment['DART_UI_SKYLIGHT_CG'] == '1') return false;
    try {
      final enabled = DynamicLibrary.process().lookupFunction<
          Bool Function(Pointer<Uint8>, Pointer<Uint8>),
          bool Function(
              Pointer<Uint8>, Pointer<Uint8>)>('_os_feature_enabled_impl');
      final Pointer<Uint8> domain = objcAllocateCString('WindowServer');
      final Pointer<Uint8> feature = objcAllocateCString('CAWindowContent');
      try {
        return enabled(domain, feature);
      } finally {
        objcFreeCString(domain);
        objcFreeCString(feature);
      }
    } on ArgumentError {
      return false;
    }
  }();

  bool _register(List<BackendDiagnostic> diagnostics) {
    // A PSN first: without it the WindowServer routes no mouse button to
    // our windows (SLPSGetCurrentProcess answers procNotFound).
    try {
      final getCurrentProcess = DynamicLibrary.open('/System/Library/'
              'Frameworks/ApplicationServices.framework/ApplicationServices')
          .lookupFunction<Int16 Function(Pointer<Uint32>),
              int Function(Pointer<Uint32>)>('GetCurrentProcess');
      final Pointer<Uint32> psn = macosCalloc<Uint32>(8);
      try {
        getCurrentProcess(psn);
      } finally {
        macosFree(psn);
      }
    } on Object {
      // Optional: keys still arrive without it.
    }
    final register =
        _skyLight.lookupFunction<Int32 Function(Int32), int Function(int)>(
            'SLPSRegisterWithServer');
    for (var attempt = 1; attempt <= 12; attempt++) {
      if (register(3) == 0) {
        // A first refusal leaves LaunchServices settling; the POC measured
        // no events at all without this pause.
        if (attempt > 1) sleep(const Duration(milliseconds: 500));
        return true;
      }
      sleep(const Duration(milliseconds: 150));
    }
    diagnostics.add(const BackendDiagnostic(
      kind: DiagnosticKind.connectionFailed,
      message: 'SkyLight: SLPSRegisterWithServer never succeeded',
    ));
    return false;
  }

  /// Event types JankyBorders subscribes to before asking for the port; the
  /// POC received no pointer moves without them.
  static const List<int> _notificationTypes = <int>[
    723, 804, 806, 807, 808, 811, 815, 816, 1322, 1325, 1326, 1401, 1508, //
  ];

  bool _installEventPort(List<BackendDiagnostic> diagnostics) {
    final registerNotify = _skyLight.lookupFunction<
        Int32 Function(
            Pointer<NativeFunction<_NotifyNative>>, Uint32, _VoidPtr),
        int Function(Pointer<NativeFunction<_NotifyNative>>, int,
            _VoidPtr)>('SLSRegisterNotifyProc');
    _notify = NativeCallable<_NotifyNative>.isolateLocal(
        (int event, _VoidPtr data, int size, _VoidPtr context) {});
    for (final int type in _notificationTypes) {
      registerNotify(_notify!.nativeFunction, type, nullptr);
    }
    final Pointer<Uint32> port = macosCalloc<Uint32>(4);
    try {
      final int rc = _skyLight.lookupFunction<
          Int32 Function(Int32, Pointer<Uint32>),
          int Function(int, Pointer<Uint32>)>('SLSGetEventPort')(
        connectionId,
        port,
      );
      _eventPort = port.value;
      if (rc != 0 || _eventPort == 0) {
        diagnostics.add(BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'SkyLight: SLSGetEventPort failed ($rc)',
        ));
        return false;
      }
    } finally {
      macosFree(port);
    }
    return true;
  }

  // -------------------------------------------------------------------------
  // Events
  // -------------------------------------------------------------------------

  late final int _taskSelf =
      DynamicLibrary.process().lookup<Uint32>('mach_task_self_').value;
  late final int Function(int, int, int, Pointer<Uint32>, Pointer<Uint32>)
      _portAttributes = DynamicLibrary.process().lookupFunction<
          Int32 Function(
              Uint32, Uint32, Int32, Pointer<Uint32>, Pointer<Uint32>),
          int Function(int, int, int, Pointer<Uint32>,
              Pointer<Uint32>)>('mach_port_get_attributes');
  late final _VoidPtr Function(int) _createNextEvent = _skyLight.lookupFunction<
      _VoidPtr Function(Int32),
      _VoidPtr Function(int)>('SLEventCreateNextEvent');
  late final int Function(_VoidPtr) _eventType = _skyLight.lookupFunction<
      Uint32 Function(_VoidPtr), int Function(_VoidPtr)>('SLEventGetType');
  late final _CGPoint Function(_VoidPtr) _eventLocation = _coreGraphics
      .lookupFunction<_CGPoint Function(_VoidPtr), _CGPoint Function(_VoidPtr)>(
          'CGEventGetLocation');
  late final int Function(_VoidPtr, int) _intField =
      _coreGraphics.lookupFunction<Int64 Function(_VoidPtr, Uint32),
          int Function(_VoidPtr, int)>('CGEventGetIntegerValueField');
  late final double Function(_VoidPtr, int) _doubleField =
      _coreGraphics.lookupFunction<Double Function(_VoidPtr, Uint32),
          double Function(_VoidPtr, int)>('CGEventGetDoubleValueField');
  late final int Function(_VoidPtr) _eventFlags = _coreGraphics.lookupFunction<
      Uint64 Function(_VoidPtr), int Function(_VoidPtr)>('CGEventGetFlags');
  late final int Function(_VoidPtr) _eventTimestamp = _coreGraphics
      .lookupFunction<Uint64 Function(_VoidPtr), int Function(_VoidPtr)>(
          'CGEventGetTimestamp');
  late final void Function(_VoidPtr, int, Pointer<Uint64>, Pointer<Uint16>)
      _unicodeString = _coreGraphics.lookupFunction<
          Void Function(
              _VoidPtr, UnsignedLong, Pointer<Uint64>, Pointer<Uint16>),
          void Function(_VoidPtr, int, Pointer<Uint64>,
              Pointer<Uint16>)>('CGEventKeyboardGetUnicodeString');

  /// Messages waiting on the event port, without receiving any.
  int _queuedMessages() => _queuedOn(_eventPort);

  /// Messages waiting on [port], without receiving any.
  int _queuedOn(int port) {
    final Pointer<Uint32> info = macosCalloc<Uint32>(40);
    final Pointer<Uint32> count = macosCalloc<Uint32>(4)..value = 10;
    try {
      // MACH_PORT_RECEIVE_STATUS; mps_msgcount is the fifth word.
      if (_portAttributes(_taskSelf, port, 2, info, count) != 0) {
        return 0;
      }
      return info[4];
    } finally {
      macosFree(info);
      macosFree(count);
    }
  }

  /// Every event queued now, decoded, without ever blocking: a read happens
  /// only while the port reports a queued message, which is what keeps
  /// `SLEventCreateNextEvent` out of its blocking `mach_msg`.
  List<MacosRawEvent> poll({int limit = 256}) {
    if (_disposed || _eventPort == 0) return const <MacosRawEvent>[];
    return ObjCAutoreleasePool.run(() {
      final List<MacosRawEvent> events = <MacosRawEvent>[];
      for (var guard = 0; guard < limit; guard++) {
        if (_queuedMessages() <= 0) break;
        final _VoidPtr event = _createNextEvent(connectionId);
        // A notification rather than an event: consumed, nothing to report.
        if (event == nullptr) break;
        try {
          events.add(_decode(event));
        } finally {
          _cfRelease(event);
        }
      }
      return events;
    });
  }

  /// What the Dock asked since the last call - a click on the tile, Quit
  /// from its menu.
  List<SkylightDockRequest> pollDock() {
    final SkylightDock? dock = this.dock;
    if (_disposed || dock == null) return const <SkylightDockRequest>[];
    return dock.poll(_queuedOn);
  }

  /// Whether [window] is on screen - false while it is in the Dock.
  bool isOrderedIn(SkylightNativeWindow window) {
    if (window.released) return false;
    final Pointer<Uint8> slot = macosCalloc<Uint8>(4);
    try {
      final int rc = _skyLight.lookupFunction<
          Int32 Function(Int32, Uint32, Pointer<Uint8>),
          int Function(int, int, Pointer<Uint8>)>('SLSWindowIsOrderedIn')(
        connectionId,
        window.id,
        slot,
      );
      return rc == 0 && slot.value != 0;
    } finally {
      macosFree(slot);
    }
  }

  MacosRawEvent _decode(_VoidPtr event) {
    final int type = _eventType(event);
    final _CGPoint location = _eventLocation(event);
    final bool key = type == 10 || type == 11;
    final bool scroll = type == 22;
    String characters = '';
    if (type == 10) {
      final Pointer<Uint64> length = macosCalloc<Uint64>(8);
      final Pointer<Uint16> buffer = macosCalloc<Uint16>(64);
      try {
        _unicodeString(event, 32, length, buffer);
        characters =
            String.fromCharCodes(buffer.asTypedList(length.value.clamp(0, 32)));
      } finally {
        macosFree(length);
        macosFree(buffer);
      }
    }
    return MacosRawEvent(
      type: type,
      screenX: location.x,
      screenY: location.y,
      windowUnderPointer: key ? 0 : _intField(event, _fieldWindowUnderPointer),
      flags: _eventFlags(event),
      timestampNanos: _eventTimestamp(event),
      keyCode: key || type == 12 ? _intField(event, _fieldKeycode) : 0,
      characters: characters,
      clickCount: key || scroll ? 0 : _intField(event, _fieldClickState),
      buttonNumber: key || scroll ? 0 : _intField(event, _fieldButtonNumber),
      scrollLinesX: scroll ? _intField(event, _fieldScrollAxis2).toDouble() : 0,
      scrollLinesY: scroll ? _intField(event, _fieldScrollAxis1).toDouble() : 0,
      scrollPointsX: scroll ? _doubleField(event, _fieldScrollPointAxis2) : 0,
      scrollPointsY: scroll ? _doubleField(event, _fieldScrollPointAxis1) : 0,
      continuousScroll: scroll && _intField(event, _fieldScrollContinuous) != 0,
    );
  }

  // -------------------------------------------------------------------------
  // Display
  // -------------------------------------------------------------------------

  late final int _mainDisplay = _coreGraphics
      .lookupFunction<Uint32 Function(), int Function()>('CGMainDisplayID')();

  /// The main display in global points, origin at its top left.
  ({double x, double y, double width, double height}) get mainDisplayBounds {
    final _CGRect rect = _coreGraphics.lookupFunction<_CGRect Function(Uint32),
        _CGRect Function(int)>('CGDisplayBounds')(_mainDisplay);
    return (x: rect.x, y: rect.y, width: rect.width, height: rect.height);
  }

  /// Device pixels per point on the main display: 2 on Retina, 1 otherwise.
  late final double mainDisplayScale = () {
    final _VoidPtr mode = _coreGraphics.lookupFunction<
        _VoidPtr Function(Uint32),
        _VoidPtr Function(int)>('CGDisplayCopyDisplayMode')(_mainDisplay);
    if (mode == nullptr) return 1.0;
    try {
      final int pixels = _coreGraphics.lookupFunction<IntPtr Function(_VoidPtr),
          int Function(_VoidPtr)>('CGDisplayModeGetPixelWidth')(mode);
      final int points = _coreGraphics.lookupFunction<IntPtr Function(_VoidPtr),
          int Function(_VoidPtr)>('CGDisplayModeGetWidth')(mode);
      return points > 0 && pixels >= points ? pixels / points : 1.0;
    } finally {
      _coreGraphics.lookupFunction<Void Function(_VoidPtr),
          void Function(_VoidPtr)>('CGDisplayModeRelease')(mode);
    }
  }();

  // -------------------------------------------------------------------------
  // Windows
  // -------------------------------------------------------------------------

  /// A window at ([x], [y]) in global points, [width] by [height], ordered
  /// in front. Throws [StateError] when the WindowServer refuses.
  SkylightNativeWindow createWindow({
    required int width,
    required int height,
    double? x,
    double? y,
  }) =>
      ObjCAutoreleasePool.run(() {
        final _VoidPtr region = _newRegion(width, height);
        final int id = _newWindow(region);
        final SkylightNativeWindow window = SkylightNativeWindow._(id)
          .._region = region
          ..width = width
          ..height = height;
        if (layerHosting) {
          _installLayer(window);
        } else {
          window._cgContext = _createCGContext(id);
        }
        _requestAllEvents(id);
        move(window, x ?? 200, y ?? 200);
        return window;
      });

  /// A new WindowServer window shaped [region]; releases [region] and
  /// throws [StateError] when refused.
  int _newWindow(_VoidPtr region) {
    final Pointer<Uint32> idSlot = macosCalloc<Uint32>(4);
    try {
      final int rc = _skyLight.lookupFunction<
          Int32 Function(
              Int32, Int32, Double, Double, _VoidPtr, Pointer<Uint32>),
          int Function(int, int, double, double, _VoidPtr,
              Pointer<Uint32>)>('SLSNewWindow')(
        connectionId,
        layerHosting ? _kSLSWindowTypeLayerHosting : _kCGSBackingStoreBuffered,
        0,
        0,
        region,
        idSlot,
      );
      final int id = idSlot.value;
      if (rc != 0 || id == 0) {
        _releaseRegion(region);
        throw StateError('SLSNewWindow -> $rc');
      }
      return id;
    } finally {
      macosFree(idSlot);
    }
  }

  _VoidPtr _newRegion(int width, int height) {
    final Pointer<_CGRect> rect = macosCalloc<_CGRect>(sizeOf<_CGRect>())
      ..ref.width = width.toDouble()
      ..ref.height = height.toDouble();
    final Pointer<_VoidPtr> slot = macosCalloc<_VoidPtr>(8);
    try {
      final int rc = _skyLight.lookupFunction<
          Int32 Function(Pointer<_CGRect>, Pointer<_VoidPtr>),
          int Function(Pointer<_CGRect>,
              Pointer<_VoidPtr>)>('CGSNewRegionWithRect')(rect, slot);
      if (rc != 0 || slot.value == nullptr) {
        throw StateError('CGSNewRegionWithRect -> $rc');
      }
      return slot.value;
    } finally {
      macosFree(rect);
      macosFree(slot);
    }
  }

  void _releaseRegion(_VoidPtr region) {
    if (region == nullptr) return;
    _skyLight.lookupFunction<Int32 Function(_VoidPtr), int Function(_VoidPtr)>(
        'CGSReleaseRegion')(region);
  }

  void _installLayer(SkylightNativeWindow window) {
    _quartzCore;
    final Pointer<ObjCObject> context = objcSendPointer2(
      objcClass('CAContext'),
      objcSelector('contextWithCGSConnection:options:'),
      connectionId,
      0,
    );
    if (context == nullptr) throw StateError('CAContext');
    window._caContext = objcRetain(context);
    window._layer = objcRetain(
        objcSendPointer(objcClass('CALayer'), objcSelector('layer')));
    final Pointer<ObjCObject> transaction = objcClass('CATransaction');
    objcSendVoid(transaction, objcSelector('begin'));
    objcSendVoid1(transaction, objcSelector('setDisableActions:'), 1);
    _setLayerFrame(window._layer, window.width, window.height);
    // Pixel for pixel, never resampled.
    final int nearest = _quartzCore.lookup<IntPtr>('kCAFilterNearest').value;
    objcSendVoid1(
        window._layer, objcSelector('setMagnificationFilter:'), nearest);
    objcSendVoid1(
        window._layer, objcSelector('setMinificationFilter:'), nearest);
    objcSendVoid1(
        window._caContext, objcSelector('setLayer:'), window._layer.address);
    objcSendVoid(transaction, objcSelector('commit'));
    final int rc = _skyLight.lookupFunction<
        Int32 Function(Int32, Uint32, _VoidPtr),
        int Function(int, int, _VoidPtr)>('SLSSetWindowLayerContext')(
      connectionId,
      window.id,
      window._caContext.cast(),
    );
    if (rc != 0) throw StateError('SLSSetWindowLayerContext -> $rc');
  }

  void _setLayerFrame(Pointer<ObjCObject> layer, int width, int height) {
    final Pointer<ObjCDouble4> frame =
        macosCalloc<ObjCDouble4>(sizeOf<ObjCDouble4>())
          ..ref.a2 = width.toDouble()
          ..ref.a3 = height.toDouble();
    try {
      objcSendVoidDouble4(layer, objcSelector('setFrame:'), frame.ref);
    } finally {
      macosFree(frame);
    }
  }

  void _requestAllEvents(int id) {
    try {
      _skyLight.lookupFunction<Int32 Function(Int32, Uint32, Uint32),
          int Function(int, int, int)>('SLSSetWindowEventMask')(
        connectionId,
        id,
        0xFFFFFFFF,
      );
    } on ArgumentError {
      // Older systems: the default mask still carries keys and buttons.
    }
  }

  /// Moves [window]'s top-left corner to ([x], [y]) in global points.
  void move(SkylightNativeWindow window, double x, double y) {
    final Pointer<_CGPoint> point = macosCalloc<_CGPoint>(sizeOf<_CGPoint>())
      ..ref.x = x
      ..ref.y = y;
    try {
      _skyLight.lookupFunction<Int32 Function(Int32, Uint32, Pointer<_CGPoint>),
          int Function(int, int, Pointer<_CGPoint>)>('SLSMoveWindow')(
        connectionId,
        window.id,
        point,
      );
      window
        ..x = x
        ..y = y;
    } finally {
      macosFree(point);
    }
  }

  /// Resizes [window] to [width] by [height] points.
  void resize(SkylightNativeWindow window, int width, int height) =>
      ObjCAutoreleasePool.run(() {
        if (width == window.width && height == window.height) return;
        if (window._cgContext != nullptr) {
          _replace(window, width, height);
          return;
        }
        final _VoidPtr region = _newRegion(width, height);
        _skyLight.lookupFunction<Int32 Function(Int32, Uint32, _VoidPtr),
            int Function(int, int, _VoidPtr)>('SLSSetWindowShape')(
          connectionId,
          window.id,
          region,
        );
        _releaseRegion(window._region);
        window
          .._region = region
          ..width = width
          ..height = height;
        if (window._layer != nullptr) {
          final Pointer<ObjCObject> transaction = objcClass('CATransaction');
          objcSendVoid(transaction, objcSelector('begin'));
          objcSendVoid1(transaction, objcSelector('setDisableActions:'), 1);
          _setLayerFrame(window._layer, width, height);
          objcSendVoid(transaction, objcSelector('commit'));
        }
      });

  /// Resizes a CoreGraphics-path window by replacing it with one of the new
  /// size, in the same place and order. A reshaped backing-store window
  /// keeps its old backing store on macOS 14: drawing the larger frame wrote
  /// past it (SIGSEGV in CGContextDrawImage, with a fresh context too),
  /// while a window created at that size draws.
  void _replace(SkylightNativeWindow window, int width, int height) {
    final bool shown = isOrderedIn(window);
    final int oldId = window.id;
    final _VoidPtr oldContext = window._cgContext;
    final _VoidPtr oldRegion = window._region;
    final _VoidPtr region = _newRegion(width, height);
    final int id = _newWindow(region);
    window
      ..id = id
      .._region = region
      ..width = width
      ..height = height
      .._cgContext = _createCGContext(id);
    _requestAllEvents(id);
    move(window, window.x, window.y);
    final orderWindow = _skyLight.lookupFunction<
        Int32 Function(Int32, Uint32, Int32, Uint32),
        int Function(int, int, int, int)>('SLSOrderWindow');
    // kCGSOrderAbove the window it replaces, before that one goes.
    if (shown) orderWindow(connectionId, id, 1, oldId);
    _cfRelease(oldContext);
    orderWindow(connectionId, oldId, 0, 0);
    _skyLight.lookupFunction<Int32 Function(Int32, Uint32),
        int Function(int, int)>('SLSReleaseWindow')(connectionId, oldId);
    _releaseRegion(oldRegion);
  }

  _VoidPtr _createCGContext(int id) => _skyLight.lookupFunction<
          _VoidPtr Function(Int32, Uint32, _VoidPtr),
          _VoidPtr Function(int, int, _VoidPtr)>('SLWindowContextCreate')(
        connectionId,
        id,
        nullptr,
      );

  /// Shows (`in front`) or hides [window].
  void order(SkylightNativeWindow window, {required bool visible}) {
    _skyLight.lookupFunction<Int32 Function(Int32, Uint32, Int32, Uint32),
        int Function(int, int, int, int)>('SLSOrderWindow')(
      connectionId,
      window.id,
      visible ? 1 : 0,
      0,
    );
  }

  /// Shows [pixels] - BGRA, premultiplied, [bytesPerRow] apart - in
  /// [window]. The bytes are copied before this returns.
  void present(
    SkylightNativeWindow window,
    Uint8List pixels, {
    required int width,
    required int height,
    required int bytesPerRow,
  }) =>
      ObjCAutoreleasePool.run(() {
        if (window.released) return;
        final int length = bytesPerRow * height;
        // Slack past the last row: vImage's blitters read whole vectors,
        // and a frame ending on a page boundary faulted on macOS 14.
        const int slack = 64;
        final Pointer<Uint8> native = macosCalloc<Uint8>(length + slack);
        native.asTypedList(length).setRange(0, length, pixels);
        final _VoidPtr data = _coreFoundation.lookupFunction<
            _VoidPtr Function(_VoidPtr, Pointer<Uint8>, IntPtr),
            _VoidPtr Function(_VoidPtr, Pointer<Uint8>, int)>('CFDataCreate')(
          nullptr,
          native,
          length + slack,
        );
        macosFree(native);
        final _VoidPtr provider = _coreGraphics.lookupFunction<
            _VoidPtr Function(_VoidPtr),
            _VoidPtr Function(
                _VoidPtr)>('CGDataProviderCreateWithCFData')(data);
        _cfRelease(data);
        final _VoidPtr colorSpace = _coreGraphics.lookupFunction<
            _VoidPtr Function(),
            _VoidPtr Function()>('CGColorSpaceCreateDeviceRGB')();
        // kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little.
        const int bitmapInfo = 2 | (2 << 12);
        final _VoidPtr image = _coreGraphics.lookupFunction<
            _VoidPtr Function(IntPtr, IntPtr, IntPtr, IntPtr, IntPtr, _VoidPtr,
                Uint32, _VoidPtr, _VoidPtr, Bool, Int32),
            _VoidPtr Function(int, int, int, int, int, _VoidPtr, int, _VoidPtr,
                _VoidPtr, bool, int)>('CGImageCreate')(
          width,
          height,
          8,
          32,
          bytesPerRow,
          colorSpace,
          bitmapInfo,
          provider,
          nullptr,
          false,
          0,
        );
        try {
          if (image == nullptr) throw StateError('CGImageCreate');
          if (window._layer != nullptr) {
            final Pointer<ObjCObject> transaction = objcClass('CATransaction');
            objcSendVoid(transaction, objcSelector('begin'));
            objcSendVoid1(transaction, objcSelector('setDisableActions:'), 1);
            objcSendVoid1(
                window._layer, objcSelector('setContents:'), image.address);
            objcSendVoid(transaction, objcSelector('commit'));
            // No run loop here to commit implicit work later.
            objcSendVoid(transaction, objcSelector('flush'));
          } else if (window._cgContext != nullptr) {
            final Pointer<_CGRect> rect =
                macosCalloc<_CGRect>(sizeOf<_CGRect>())
                  ..ref.width = width.toDouble()
                  ..ref.height = height.toDouble();
            // The frame replaces the window's pixels: a copy, not a blend
            // that reads the backing store back (the macOS 14 crash was in
            // vPremultipliedAlphaBlend after a reshape).
            _coreGraphics.lookupFunction<Void Function(_VoidPtr, Int32),
                    void Function(_VoidPtr, int)>('CGContextSetBlendMode')(
                window._cgContext, _kCGBlendModeCopy);
            _coreGraphics.lookupFunction<
                Void Function(_VoidPtr, _CGRect, _VoidPtr),
                void Function(
                    _VoidPtr, _CGRect, _VoidPtr)>('CGContextDrawImage')(
              window._cgContext,
              rect.ref,
              image,
            );
            _coreGraphics.lookupFunction<Void Function(_VoidPtr),
                void Function(_VoidPtr)>('CGContextFlush')(window._cgContext);
            macosFree(rect);
          }
        } finally {
          if (image != nullptr) _cfRelease(image);
          _cfRelease(colorSpace);
          _cfRelease(provider);
        }
      });

  /// Releases [window]'s WindowServer and Core Animation objects.
  void release(SkylightNativeWindow window) => ObjCAutoreleasePool.run(() {
        if (window.released) return;
        window.released = true;
        order(window, visible: false);
        if (window._cgContext != nullptr) {
          _cfRelease(window._cgContext);
          window._cgContext = nullptr;
        }
        try {
          _skyLight.lookupFunction<Int32 Function(Int32, Uint32),
              int Function(int, int)>('SLSReleaseWindow')(
            connectionId,
            window.id,
          );
        } on ArgumentError {
          // Older SkyLight: the window goes with the connection.
        }
        if (window._caContext != nullptr) {
          objcSendVoid1(window._caContext, objcSelector('setLayer:'), 0);
          objcRelease(window._caContext);
          window._caContext = nullptr;
        }
        if (window._layer != nullptr) {
          objcRelease(window._layer);
          window._layer = nullptr;
        }
        _releaseRegion(window._region);
        window._region = nullptr;
      });

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    dock?.dispose();
    dock = null;
    _notify?.close();
    _notify = null;
  }
}
