/// A [NativeWindow] that is a real `NSWindow`, made and driven on the main
/// thread [AppKitSignalSession] parked in its run loop.
///
/// Unlike SkyLight this window has everything AppKit gives: the title bar,
/// the traffic lights, moving and resizing by the system, the Window menu's
/// zoom and minimise. The framework draws only the content, as a CPU frame
/// set as the content view's layer contents.
library;

import 'dart:async';
import 'dart:ffi';

import '../../../ffi/objc_runtime.dart';
import '../../../foundation/diagnostics.dart';
import '../../../foundation/lifecycle.dart';
import '../../../geometry/offset.dart';
import '../../../geometry/rect.dart';
import '../../../geometry/size.dart';
import '../../../platform/input_events.dart';
import '../../../platform/native_window.dart';
import '../../../platform/window_events.dart';
import '../../../rendering/framebuffer.dart';
import '../../../rendering/renderer.dart';
import '../io_surface.dart' show macosCalloc, macosFree;
import '../macos_cpu_window.dart';
import '../macos_event_translation.dart';
import 'appkit_signal_session.dart';

typedef _VoidPtr = Pointer<Void>;

final class _NSPoint extends Struct {
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

final DynamicLibrary _objc = DynamicLibrary.open('/usr/lib/libobjc.A.dylib');

// NSEvent getters with a struct or floating-point result: the strict shapes
// of objc_runtime.dart refuse aggregate returns, and these two are the only
// ones this file needs. A two-double struct and a double come back in
// floating-point registers on both arm64 and x86_64, through plain
// objc_msgSend.
final _NSPoint Function(Pointer<ObjCObject>, Pointer<ObjCSelector>) _sendPoint =
    _objc.lookupFunction<
        _NSPoint Function(Pointer<ObjCObject>, Pointer<ObjCSelector>),
        _NSPoint Function(
            Pointer<ObjCObject>, Pointer<ObjCSelector>)>('objc_msgSend');
final double Function(Pointer<ObjCObject>, Pointer<ObjCSelector>) _sendDouble =
    _objc.lookupFunction<
        Double Function(Pointer<ObjCObject>, Pointer<ObjCSelector>),
        double Function(
            Pointer<ObjCObject>, Pointer<ObjCSelector>)>('objc_msgSend');

typedef _PerformCloseNative = Void Function(
    Pointer<ObjCObject>, Pointer<ObjCSelector>, Pointer<ObjCObject>);

/// `DartUiSignalWindow`: an `NSWindow` whose close button asks instead of
/// closing. Defined once per process; [_closeRequests] maps each instance to
/// its Dart window.
final Map<int, AppKitSignalWindow> _byNative = <int, AppKitSignalWindow>{};
NativeCallable<_PerformCloseNative>? _performClose;
final Pointer<ObjCObject> _windowClass = () {
  // performClose: is what the red button, Cmd+W and Window > Close all send.
  // AppKit calls it on the main thread; a listener posts it to the isolate
  // and returns at once, and not calling super is what keeps the window open
  // until the framework decides.
  _performClose = NativeCallable<_PerformCloseNative>.listener(
      (Pointer<ObjCObject> self, Pointer<ObjCSelector> cmd,
          Pointer<ObjCObject> sender) {
    _byNative[self.address]?._closeRequested();
  })
    // A listener keeps its isolate alive by default, and this one lives for
    // the process: with it the program never exits after its last window.
    ..keepIsolateAlive = false;
  final ObjCClassBuilder builder =
      ObjCClassBuilder('DartUiSignalWindow', 'NSWindow')
        ..addMethod<_PerformCloseNative>(
          selector: 'performClose:',
          typeEncoding: 'v@:@',
          implementation: _performClose!.nativeFunction,
        );
  return builder.register();
}();

/// The CPU surface of one [AppKitSignalWindow] at one size.
final class AppKitSignalCpuSurface implements MacosCpuSurface {
  AppKitSignalCpuSurface._(
      this._window, this.generation, this.framebuffer, this.scale);

  final AppKitSignalWindow _window;

  @override
  final int generation;

  @override
  final Framebuffer framebuffer;

  @override
  final double scale;

  @override
  String get kind => macosCpuSurfaceKind;

  @override
  int get pixelWidth => framebuffer.width;

  @override
  int get pixelHeight => framebuffer.height;

  @override
  BackendDiagnostic? present({Rect? damage}) => _window._present(this);
}

/// One `NSWindow` on the hijacked main thread.
final class AppKitSignalWindow
    with DisposableMixin
    implements
        NativeWindow,
        MacosCpuWindow,
        WindowStateControl,
        ActivatableWindow {
  AppKitSignalWindow._(this._session, this._native, this._id, this._onClosed);

  /// Creates the window on the main thread and shows it when [options] says
  /// visible.
  static AppKitSignalWindow create({
    required AppKitSignalSession session,
    required NativeWindowId id,
    required WindowOptions options,
    required void Function(AppKitSignalWindow window) onClosed,
  }) =>
      ObjCAutoreleasePool.run(() {
        final bool decorated =
            options.decorated && options.kind.takesActivation;
        // Titled | Closable | Miniaturizable | Resizable, or borderless.
        final int style =
            decorated ? 1 | 2 | 4 | (options.resizable ? 8 : 0) : 0;
        final Pointer<ObjCObject> allocated =
            objcSendPointer(_windowClass, objcSelector('alloc'));
        final Pointer<ObjCObject> native = session.callObject(
          allocated,
          'initWithContentRect:styleMask:backing:defer:',
          args: <MainArg>[
            RectArg(
              options.position?.dx ?? 200,
              options.position?.dy ?? 200,
              options.size.width,
              options.size.height,
            ),
            IntArg(style),
            const IntArg(2), // NSBackingStoreBuffered
            const BoolArg(false),
          ],
        );
        if (native == nullptr) throw StateError('NSWindow init failed');
        final AppKitSignalWindow window =
            AppKitSignalWindow._(session, native, id, onClosed);
        _byNative[native.address] = window;
        window._configure(options.title);
        if (options.visible) window.show();
        return window;
      });

  final AppKitSignalSession _session;
  final Pointer<ObjCObject> _native;
  final NativeWindowId _id;
  final void Function(AppKitSignalWindow window) _onClosed;
  final GenerationToken _generation = GenerationToken();
  final StreamController<PlatformWindowEvent> _events =
      StreamController<PlatformWindowEvent>.broadcast();
  final List<BackendDiagnostic> _diagnostics = <BackendDiagnostic>[];
  Pointer<ObjCObject> _contentView = nullptr;
  Pointer<ObjCObject> _layer = nullptr;
  AppKitSignalCpuSurface? _surface;
  Size _size = Size.zero;
  double _scale = 1;
  bool _visible = false;
  bool _active = false;
  bool _closedEmitted = false;
  WindowState _state = WindowState.normal;

  /// The AppKit window number, the one `screencapture -l` takes.
  late final int windowNumber =
      _session.call(_native, 'windowNumber', returns: MainReturn.integer);

  void _configure(String title) {
    _session
      ..call(_native, 'setReleasedWhenClosed:',
          args: const <MainArg>[BoolArg(false)])
      ..call(_native, 'setAcceptsMouseMovedEvents:',
          args: const <MainArg>[BoolArg(true)]);
    setTitle(title);
    _contentView = objcRetain(_session.callObject(_native, 'contentView'));
    _session
      ..call(_contentView, 'setWantsLayer:',
          args: const <MainArg>[BoolArg(true)])
      // Never: a plain view has nothing to draw, and AppKit redisplaying it
      // on a resize would wipe the frame the framework set as contents.
      ..call(_contentView, 'setLayerContentsRedrawPolicy:',
          args: const <MainArg>[IntArg(0)]);
    _layer = objcRetain(_session.callObject(_contentView, 'layer'));
    final DynamicLibrary quartz = DynamicLibrary.open(
        '/System/Library/Frameworks/QuartzCore.framework/QuartzCore');
    final int nearest = quartz.lookup<IntPtr>('kCAFilterNearest').value;
    _session
      ..call(_layer, 'setMagnificationFilter:',
          args: <MainArg>[PointerArg(nearest)])
      ..call(_layer, 'setMinificationFilter:',
          args: <MainArg>[PointerArg(nearest)]);
    _scale = _session.callDouble(_native, 'backingScaleFactor');
    final List<double> frame = _session.callRect(_contentView, 'frame');
    _size = Size(frame[2], frame[3]);
    _rebuildSurface();
  }

  // -------------------------------------------------------------------------
  // NativeWindow
  // -------------------------------------------------------------------------

  @override
  NativeWindowId get id => _id;

  @override
  int get generation => _generation.current;

  @override
  Size get clientSize => _size;

  @override
  double get renderScale => _scale;

  @override
  double get desktopScale => _scale;

  @override
  WindowState get state => _state;

  @override
  List<NativeSurfaceDescriptor> get surfaces {
    final AppKitSignalCpuSurface? surface = _surface;
    return surface == null
        ? const <NativeSurfaceDescriptor>[]
        : <NativeSurfaceDescriptor>[surface];
  }

  @override
  MacosCpuSurface? get cpuSurface => _surface;

  @override
  Stream<PlatformWindowEvent> get events => _events.stream;

  @override
  void recordRenderDiagnostic(BackendDiagnostic diagnostic) =>
      _diagnostics.add(diagnostic);

  @override
  void show() {
    if (isDisposed || _visible) return;
    ObjCAutoreleasePool.run(() => _session.call(
        _native, 'makeKeyAndOrderFront:',
        args: const <MainArg>[PointerArg(0)]));
    _visible = true;
    scheduleMicrotask(() => requestRedraw());
  }

  @override
  void hide() {
    if (isDisposed || !_visible) return;
    ObjCAutoreleasePool.run(() => _session
        .call(_native, 'orderOut:', args: const <MainArg>[PointerArg(0)]));
    _visible = false;
  }

  @override
  void close() => dispose();

  @override
  void setTitle(String value) => ObjCAutoreleasePool.run(() {
        final Pointer<Uint8> text = objcAllocateCString(value);
        try {
          final Pointer<ObjCObject> title = objcSendPointer1(
              objcClass('NSString'),
              objcSelector('stringWithUTF8String:'),
              text.address);
          _session.call(_native, 'setTitle:',
              args: <MainArg>[PointerArg.object(title)]);
        } finally {
          objcFreeCString(text);
        }
      });

  @override
  void setBounds(Rect bounds) => ObjCAutoreleasePool.run(() {
        _session.call(_native, 'setContentSize:', args: <MainArg>[
          SizeArg(bounds.width, bounds.height),
        ]);
        refreshGeometry();
      });

  @override
  void setCursor(SystemCursor cursor) {}

  @override
  void requestRedraw([Rect? dirtyRect]) {
    if (isDisposed) return;
    _emit(WindowExposedEvent(
      windowId: _id,
      generation: _generation.current,
      dirtyRect: dirtyRect,
    ));
  }

  /// The window's frame - x, y, width, height - in AppKit's bottom-left
  /// screen coordinates.
  List<double> get frame =>
      ObjCAutoreleasePool.run(() => _session.callRect(_native, 'frame'));

  /// The content area's top-left corner in global points, top-left origin.
  ///
  /// AppKit's frame is bottom-left-origin, relative to the main display's
  /// bottom; the content area is the frame minus the title bar on top.
  Offset get _contentOrigin => ObjCAutoreleasePool.run(() {
        final List<double> frame = _session.callRect(_native, 'frame');
        final double mainHeight = _coreGraphics
            .lookupFunction<_CGRect Function(Uint32), _CGRect Function(int)>(
                'CGDisplayBounds')
            (_coreGraphics.lookupFunction<Uint32 Function(), int Function()>(
                'CGMainDisplayID')())
            .height;
        final double frameTop = mainHeight - (frame[1] + frame[3]);
        final double titleBar = frame[3] - _size.height;
        return Offset(frame[0], frameTop + titleBar);
      });

  @override
  Offset screenToClient(Offset screenPosition) =>
      screenPosition - _contentOrigin;

  @override
  Offset clientToScreen(Offset clientPosition) =>
      clientPosition + _contentOrigin;

  @override
  void activate() {
    if (isDisposed) return;
    _session.bringToFront();
    ObjCAutoreleasePool.run(() => _session.call(
        _native, 'makeKeyAndOrderFront:',
        args: const <MainArg>[PointerArg(0)]));
  }

  // -------------------------------------------------------------------------
  // State
  // -------------------------------------------------------------------------

  @override
  bool requestState(WindowState state) {
    if (isDisposed) return false;
    ObjCAutoreleasePool.run(() {
      final bool zoomed = _bool('isZoomed');
      final bool miniaturized = _bool('isMiniaturized');
      final bool fullscreen = _fullscreen;
      void send(String selector) => _session
          .call(_native, selector, args: const <MainArg>[PointerArg(0)]);
      switch (state) {
        case WindowState.normal:
          if (fullscreen) send('toggleFullScreen:');
          if (miniaturized) send('deminiaturize:');
          if (zoomed) send('zoom:');
        case WindowState.minimised:
          if (!miniaturized) send('miniaturize:');
        case WindowState.maximised:
          if (miniaturized) send('deminiaturize:');
          if (!zoomed) send('zoom:');
        case WindowState.fullscreen:
          if (!fullscreen) {
            // NSWindowCollectionBehaviorFullScreenPrimary.
            _session.call(_native, 'setCollectionBehavior:',
                args: const <MainArg>[IntArg(1 << 7)]);
            send('toggleFullScreen:');
          }
      }
    });
    refreshGeometry();
    return true;
  }

  bool _bool(String selector) =>
      _session.call(_native, selector, returns: MainReturn.boolean) != 0;

  bool get _fullscreen =>
      (_session.call(_native, 'styleMask', returns: MainReturn.integer) &
          (1 << 14)) !=
      0;

  /// Re-reads size, scale, key state and window state from AppKit, and
  /// reports what changed. The backend calls it after every pump: AppKit
  /// resizes, zooms and activates the window itself, in `sendEvent:`.
  void refreshGeometry() {
    if (isDisposed) return;
    ObjCAutoreleasePool.run(() {
      final List<double> frame = _session.callRect(_contentView, 'frame');
      final double scale = _session.callDouble(_native, 'backingScaleFactor');
      final Size size = Size(frame[2], frame[3]);
      if (size != _size || scale != _scale) {
        _size = size;
        _scale = scale;
        _generation.invalidate();
        _rebuildSurface();
        _emit(WindowResizedEvent(
          windowId: _id,
          generation: _generation.current,
          clientSize: _size,
          renderScale: _scale,
        ));
      }
      final bool active = _bool('isKeyWindow');
      if (active != _active) {
        _active = active;
        _emit(WindowActivationEvent(
          windowId: _id,
          generation: _generation.current,
          activation: active
              ? WindowActivation.activated
              : WindowActivation.deactivated,
        ));
      }
      final WindowState state = _fullscreen
          ? WindowState.fullscreen
          : _bool('isMiniaturized')
              ? WindowState.minimised
              : _bool('isZoomed')
                  ? WindowState.maximised
                  : WindowState.normal;
      if (state != _state) {
        _state = state;
        _emit(WindowStateChangedEvent(
          windowId: _id,
          generation: _generation.current,
          state: state,
        ));
      }
    });
  }

  /// Sends `performClose:` as the red button does, for a smoke test.
  void debugPerformClose() => ObjCAutoreleasePool.run(() => _session
      .call(_native, 'performClose:', args: const <MainArg>[PointerArg(0)]));

  void _closeRequested() {
    if (isDisposed) return;
    _emit(WindowCloseRequestedEvent(
      windowId: _id,
      generation: _generation.current,
    ));
  }

  // -------------------------------------------------------------------------
  // Surface and presentation
  // -------------------------------------------------------------------------

  void _rebuildSurface() {
    final int width = (_size.width * _scale).round();
    final int height = (_size.height * _scale).round();
    _surface = width <= 0 || height <= 0
        ? null
        : AppKitSignalCpuSurface._(
            this,
            _generation.current,
            Framebuffer.allocate(width: width, height: height),
            _scale,
          );
  }

  late final DynamicLibrary _coreGraphics = DynamicLibrary.open(
      '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics');
  late final DynamicLibrary _coreFoundation = DynamicLibrary.open(
      '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation');

  BackendDiagnostic? _present(AppKitSignalCpuSurface surface) {
    if (isDisposed || !identical(surface, _surface)) {
      return const BackendDiagnostic.note('stale AppKit signal surface');
    }
    try {
      ObjCAutoreleasePool.run(() {
        final _VoidPtr image = _createImage(surface.framebuffer);
        try {
          _session
            ..call(_layer, 'setContents:',
                args: <MainArg>[PointerArg(image.address)])
            // Without an explicit flush the frame waits for the next implicit
            // transaction.
            ..call(objcClass('CATransaction'), 'flush');
        } finally {
          _cfRelease(image);
        }
      });
      return null;
    } on Object catch (error) {
      return BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'AppKit signal present failed',
        detail: '$error',
      );
    }
  }

  late final void Function(_VoidPtr) _cfRelease = _coreFoundation
      .lookupFunction<Void Function(_VoidPtr), void Function(_VoidPtr)>(
          'CFRelease');

  _VoidPtr _createImage(Framebuffer buffer) {
    final int length = buffer.bytesPerRow * buffer.height;
    final Pointer<Uint8> native = macosCalloc<Uint8>(length);
    native.asTypedList(length).setRange(0, length, buffer.pixels);
    final _VoidPtr data = _coreFoundation.lookupFunction<
        _VoidPtr Function(_VoidPtr, Pointer<Uint8>, IntPtr),
        _VoidPtr Function(_VoidPtr, Pointer<Uint8>, int)>('CFDataCreate')(
      nullptr,
      native,
      length,
    );
    macosFree(native);
    final _VoidPtr provider = _coreGraphics.lookupFunction<
        _VoidPtr Function(_VoidPtr),
        _VoidPtr Function(_VoidPtr)>('CGDataProviderCreateWithCFData')(data);
    _cfRelease(data);
    final _VoidPtr colorSpace =
        _coreGraphics.lookupFunction<_VoidPtr Function(), _VoidPtr Function()>(
            'CGColorSpaceCreateDeviceRGB')();
    final _VoidPtr image = _coreGraphics.lookupFunction<
        _VoidPtr Function(IntPtr, IntPtr, IntPtr, IntPtr, IntPtr, _VoidPtr,
            Uint32, _VoidPtr, _VoidPtr, Bool, Int32),
        _VoidPtr Function(int, int, int, int, int, _VoidPtr, int, _VoidPtr,
            _VoidPtr, bool, int)>('CGImageCreate')(
      buffer.width,
      buffer.height,
      8,
      32,
      buffer.bytesPerRow,
      colorSpace,
      2 | (2 << 12), // premultiplied first, 32-bit little endian: BGRA
      provider,
      nullptr,
      false,
      0,
    );
    _cfRelease(colorSpace);
    _cfRelease(provider);
    if (image == nullptr) throw StateError('CGImageCreate');
    return image;
  }

  // -------------------------------------------------------------------------
  // Input
  // -------------------------------------------------------------------------

  /// Decodes an `NSEvent` for this window and emits what it means. Called by
  /// the backend before it hands the event back to AppKit.
  ///
  /// Returns whether the event fell inside the content area, where AppKit
  /// delivers it to the view instead of running a loop of its own.
  bool handleEvent(Pointer<ObjCObject> event, int type) {
    if (isDisposed) return false;
    final MacosRawEvent raw = decodeNSEvent(
      event,
      type,
      characters: (Pointer<ObjCObject> event) =>
          _session.callObject(event, 'characters'),
    );
    // Window coordinates have their origin at the bottom left of the
    // content area; the framework's are top-left.
    final Offset local = Offset(raw.screenX, _size.height - raw.screenY);
    translateMacosRawEvent(
      raw,
      local: local,
      windowId: _id,
      generation: _generation.current,
      emit: _emit,
    );
    // The resize margin AppKit claims along a resizable window's edges.
    const double edge = 4;
    return local.dx >= edge &&
        local.dy >= 0 &&
        local.dx < _size.width - edge &&
        local.dy < _size.height - edge;
  }

  /// Ends the press the framework saw when AppKit took the rest of the
  /// gesture - a title-bar drag or an edge resize runs its own loop inside
  /// `sendEvent:` and the release never comes back out.
  void cancelPointer() {
    if (isDisposed) return;
    _emit(PointerCancelEvent(
      windowId: _id,
      generation: _generation.current,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: Offset.zero,
    ));
  }

  void _emit(PlatformWindowEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  @override
  void onDispose() {
    _surface = null;
    _generation.invalidate();
    _byNative.remove(_native.address);
    try {
      ObjCAutoreleasePool.run(() {
        _session
          ..call(_native, 'orderOut:', args: const <MainArg>[PointerArg(0)])
          ..call(_native, 'close');
      });
    } on StateError {
      // The session went first: thread 0 is the VM's again and the window
      // goes with the process.
    }
    objcRelease(_layer);
    objcRelease(_contentView);
    objcRelease(_native);
    if (!_closedEmitted) {
      _closedEmitted = true;
      _emit(WindowClosedEvent(
        windowId: _id,
        generation: _generation.current,
      ));
    }
    unawaited(_events.close());
    _onClosed(this);
  }
}

/// The characters each key last typed, by key code, for its key-up.
final Map<int, String> _typedByKey = <int, String>{};

/// Reads the fields of an `NSEvent` the translation needs. Getters only, on
/// the calling thread: an event is a value by the time it is dequeued.
///
/// Except `characters`, which [characters] fetches: it consults the keyboard
/// input source for dead keys, and HIToolbox asserts that happens on the main
/// queue - called from the Dart thread it aborts the process.
MacosRawEvent decodeNSEvent(
  Pointer<ObjCObject> event,
  int type, {
  required Pointer<ObjCObject> Function(Pointer<ObjCObject> event) characters,
}) {
  int unsigned(String selector) =>
      objcSendUnsigned(event, objcSelector(selector));
  final bool key = type == 10 || type == 11;
  final bool scroll = type == 22;
  final _NSPoint location = _sendPoint(event, objcSelector('locationInWindow'));
  final double deltaX =
      scroll ? _sendDouble(event, objcSelector('scrollingDeltaX')) : 0;
  final double deltaY =
      scroll ? _sendDouble(event, objcSelector('scrollingDeltaY')) : 0;
  final bool precise = scroll &&
      (objcSendUnsigned(event, objcSelector('hasPreciseScrollingDeltas')) &
              0xFF) !=
          0;
  String typed = '';
  // keyUp reuses what its keyDown typed: `characters` on a key-up that
  // carries none - a synthesized one does not - raises inside AppKit.
  if (type == 11) typed = _typedByKey[unsigned('keyCode') & 0xFFFF] ?? '';
  if (type == 10) {
    final Pointer<ObjCObject> text = characters(event);
    if (text != nullptr) {
      final Pointer<ObjCObject> utf8 =
          objcSendPointer(text, objcSelector('UTF8String'));
      if (utf8 != nullptr) typed = objcReadCString(utf8.cast());
    }
  }
  if (type == 10) _typedByKey[unsigned('keyCode') & 0xFFFF] = typed;
  return MacosRawEvent(
    type: type,
    screenX: location.x,
    screenY: location.y,
    windowUnderPointer: unsigned('windowNumber'),
    flags: unsigned('modifierFlags'),
    timestampNanos:
        (_sendDouble(event, objcSelector('timestamp')) * 1e9).round(),
    keyCode: key || type == 12 ? unsigned('keyCode') & 0xFFFF : 0,
    characters: typed,
    clickCount: key || scroll || type == 12 ? 0 : unsigned('clickCount'),
    buttonNumber: key || scroll || type == 12 ? 0 : unsigned('buttonNumber'),
    scrollPointsX: deltaX,
    scrollPointsY: deltaY,
    // A wheel without precise deltas reports lines in the same getters.
    scrollLinesX: deltaX,
    scrollLinesY: deltaY,
    continuousScroll: precise,
  );
}
