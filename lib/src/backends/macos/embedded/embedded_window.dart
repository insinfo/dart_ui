/// One window of the embedded backend: a real `NSWindow` - or an `NSPanel`
/// for a menu or tooltip - in this process, made and driven on the main
/// thread the embedded runtime runs the isolate on.
///
/// The pixels are a rotating pool of `IOSurface`s (`surface_pool.dart`), the
/// same buffers the native host shows, set as the content view's layer
/// `contents`. Metal renders straight into them (`MetalPresentSurface`, ADR
/// 0005) and the CPU rasteriser writes them in place, so neither path copies
/// a frame and both share the pool's never-write-what-is-shown rule.
///
/// A popup is a child window of its owner (`addChildWindow:ordered:`): it
/// stays directly above the owner in the window order, moves with it, and
/// leaves with it - the z-order the native host has to rebuild across
/// processes is AppKit's own here.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io' show Platform, stderr;

import '../../../ffi/objc_runtime.dart';
import '../../../foundation/diagnostics.dart';
import '../../../foundation/lifecycle.dart';
import '../../../foundation/value_notifier.dart';
import '../../../geometry/offset.dart';
import '../../../geometry/rect.dart';
import '../../../geometry/size.dart';
import '../../../platform/native_window.dart';
import '../../../platform/window_events.dart';
import '../../../rendering/framebuffer.dart';
import '../../../rendering/renderer.dart';
import '../../apple/cocoa_ffi.dart';
import '../appkit_event_decoding.dart';
import '../io_surface.dart' show MacosIOSurface, MacosPoolSurface;
import '../macos_event_translation.dart';
import '../macos_window.dart' show createIOSurfacePool;
import '../surface_pool.dart';
import 'embedded_appkit.dart';

/// `DART_UI_EMBEDDED_TRACE=1` prints every view event to stderr.
final bool _trace = Platform.environment['DART_UI_EMBEDDED_TRACE'] == '1';

/// The `kind` of the CPU path into an embedded window's `IOSurface`s.
const String macosEmbeddedSurfaceKind = 'macos-embedded-iosurface';

// NSWindowStyleMask.
const int _titled = 1 << 0;
const int _closable = 1 << 1;
const int _miniaturizable = 1 << 2;
const int _resizable = 1 << 3;
const int _nonactivatingPanel = 1 << 7;
const int _fullScreen = 1 << 14;
const int _fullSizeContentView = 1 << 15;

// NSTrackingAreaOptions: entered/exited, moved, always, the view's rect.
const int _trackingOptions = 0x01 | 0x02 | 0x80 | 0x200;

/// The geometry of the screen everything is measured against: AppKit's
/// origin is the bottom left of the primary screen, the framework's the top
/// left.
double macosPrimaryScreenHeight() {
  final Pointer<ObjCObject> screens =
      objcSendPointer(objcClass('NSScreen'), objcSelector('screens'));
  if (screens == nullptr ||
      objcSendUnsigned(screens, objcSelector('count')) == 0) {
    return 0;
  }
  final Pointer<ObjCObject> primary =
      objcSendPointer1(screens, objcSelector('objectAtIndex:'), 0);
  return sendRect(primary, 'frame').size.height;
}

/// An AppKit rect (bottom-left origin) as a framework rect (top-left).
Rect macosRectFromAppKit(CGRect rect, double primaryHeight) => Rect.fromLTWH(
      rect.origin.x,
      primaryHeight - rect.origin.y - rect.size.height,
      rect.size.width,
      rect.size.height,
    );

/// A framework rect (top-left origin) as an AppKit rect.
CGRect macosRectToAppKit(Rect rect, double primaryHeight) => cgRect(
      rect.left,
      primaryHeight - rect.top - rect.height,
      rect.width,
      rect.height,
    );

final class MacosEmbeddedWindow
    with DisposableMixin
    implements
        NativeWindow,
        MacosSurfaceHost,
        WindowStateControl,
        ActivatableWindow,
        HiddenTitleBarWindow {
  MacosEmbeddedWindow._({
    required NativeWindowId id,
    required WindowOptions options,
    required Pointer<ObjCObject> native,
    required Pointer<ObjCObject> view,
    required this.owner,
    required void Function(MacosEmbeddedWindow window) onClosed,
    required void Function() onEvent,
  })  : _id = id,
        _options = options,
        _native = native,
        _view = view,
        _onClosed = onClosed,
        _onEvent = onEvent;

  /// Makes the window on this thread - the main one - and shows it when
  /// [options] says visible.
  static MacosEmbeddedWindow create({
    required MacosEmbeddedClasses classes,
    required Pointer<ObjCObject> delegate,
    required NativeWindowId id,
    required WindowOptions options,
    required MacosEmbeddedWindow? owner,
    required void Function(MacosEmbeddedWindow window) onClosed,
    required void Function() onEvent,
  }) =>
      ObjCAutoreleasePool.run(() {
        final bool transient = !options.kind.takesActivation;
        final bool decorated = options.decorated && !transient;
        final bool hiddenTitle =
            decorated && options.titleBar == WindowTitleBar.hidden;
        final int style = transient
            ? _nonactivatingPanel
            : decorated
                ? _titled |
                    _closable |
                    _miniaturizable |
                    (options.resizable ? _resizable : 0) |
                    (hiddenTitle ? _fullSizeContentView : 0)
                : (options.resizable ? _resizable : 0);
        final double primary = macosPrimaryScreenHeight();
        final Offset? position = options.position;
        final CGRect content = position == null
            ? cgRect(0, 0, options.size.width, options.size.height)
            : macosRectToAppKit(
                Rect.fromLTWH(position.dx, position.dy, options.size.width,
                    options.size.height),
                primary);
        final Pointer<ObjCObject> native = sendInitWithRect(
          objcSendPointer(transient ? classes.panel : classes.window,
              objcSelector('alloc')),
          'initWithContentRect:styleMask:backing:defer:',
          content,
          style,
          2, // NSBackingStoreBuffered
          0,
        );
        if (native == nullptr) throw StateError('NSWindow init failed');
        final Pointer<ObjCObject> view = objcSendPointer(
            objcSendPointer(classes.view, objcSelector('alloc')),
            objcSelector('init'));
        final MacosEmbeddedWindow window = MacosEmbeddedWindow._(
          id: id,
          options: options,
          native: native,
          view: view,
          owner: owner,
          onClosed: onClosed,
          onEvent: onEvent,
        );
        window._configure(
          delegate: delegate,
          transient: transient,
          hiddenTitle: hiddenTitle,
          centred: position == null,
        );
        if (options.visible) window.show();
        return window;
      });

  final NativeWindowId _id;
  final WindowOptions _options;
  final Pointer<ObjCObject> _native;
  final Pointer<ObjCObject> _view;

  /// The window this one is a child of, for a popup or a dialog.
  final MacosEmbeddedWindow? owner;
  final void Function(MacosEmbeddedWindow window) _onClosed;
  final void Function() _onEvent;
  final GenerationToken _generation = GenerationToken();
  final StreamController<PlatformWindowEvent> _events =
      StreamController<PlatformWindowEvent>.broadcast();
  final List<BackendDiagnostic> _diagnostics = <BackendDiagnostic>[];
  final ValueNotifier<Rect> _systemButtons = ValueNotifier<Rect>(Rect.zero);
  Pointer<ObjCObject> _layer = nullptr;
  Pointer<ObjCObject> _trackingArea = nullptr;
  Pointer<ObjCObject> _lastMouseDown = nullptr;
  MacosSurfacePool? _pool;
  MacosSurfaceDescriptor? _descriptor;
  Size _size = Size.zero;
  double _scale = 1;
  bool _visible = false;
  bool _key = false;
  bool _transient = false;
  bool _hiddenTitle = false;
  bool _closedEmitted = false;
  bool _childAttached = false;
  bool _liveResizing = false;
  int _lastMoveEvent = 0;
  double _titleBarHeight = 0;
  WindowState _state = WindowState.normal;

  /// The `NSWindow`.
  Pointer<ObjCObject> get nativeWindow => _native;

  /// The content view, `DartUiEmbeddedView`.
  Pointer<ObjCObject> get view => _view;

  /// The AppKit window number - the CGWindowID `screencapture -l` takes.
  int get windowNumber =>
      objcSendUnsigned(_native, objcSelector('windowNumber'));

  /// What the window was opened as.
  WindowKind get kind => _options.kind;

  /// Whether AppKit is in its live-resize loop for this window.
  bool get isLiveResizing => _liveResizing;

  void _configure({
    required Pointer<ObjCObject> delegate,
    required bool transient,
    required bool hiddenTitle,
    required bool centred,
  }) {
    _transient = transient;
    _hiddenTitle = hiddenTitle;
    objcSendVoid1(_native, objcSelector('setReleasedWhenClosed:'), 0);
    objcSendVoid1(_native, objcSelector('setDelegate:'), delegate.address);
    objcSendVoid1(_native, objcSelector('setAcceptsMouseMovedEvents:'), 1);
    if (_options.title.isNotEmpty) setTitle(_options.title);
    if (transient) {
      // A menu: no frame, no activation, a shadow from the alpha it draws,
      // and the pixels it leaves transparent show the desktop
      // (Capability.transparentPopups). Its level is its owner's: as a child
      // window it is ordered directly above it instead of above every
      // application.
      objcSendVoid1(_native, objcSelector('setOpaque:'), 0);
      objcSendVoid1(
          _native,
          objcSelector('setBackgroundColor:'),
          objcSendPointer(objcClass('NSColor'), objcSelector('clearColor'))
              .address);
      objcSendVoid1(_native, objcSelector('setHasShadow:'), 1);
      objcSendVoid1(_native, objcSelector('setHidesOnDeactivate:'), 0);
      objcSendVoid1(_native, objcSelector('setBecomesKeyOnlyIfNeeded:'), 1);
      // NSWindowCollectionBehaviorTransient | IgnoresCycle.
      objcSendVoid1(
          _native, objcSelector('setCollectionBehavior:'), (1 << 3) | (1 << 6));
      if (_options.kind == WindowKind.tooltip) {
        objcSendVoid1(_native, objcSelector('setIgnoresMouseEvents:'), 1);
      }
    }
    if (hiddenTitle) {
      objcSendVoid1(_native, objcSelector('setTitlebarAppearsTransparent:'), 1);
      objcSendVoid1(_native, objcSelector('setTitleVisibility:'), 1);
    }
    if (_options.minimumSize case final Size minimum) {
      sendVoidSize(
          _native, 'setContentMinSize:', cgSize(minimum.width, minimum.height));
    }
    if (_options.maximumSize case final Size maximum) {
      sendVoidSize(
          _native, 'setContentMaxSize:', cgSize(maximum.width, maximum.height));
    }

    objcSendVoid1(_native, objcSelector('setContentView:'), _view.address);
    objcSendVoid1(_view, objcSelector('setWantsLayer:'), 1);
    // Never: the view draws nothing itself, and AppKit redisplaying it on a
    // resize would wipe the surface set as the layer's contents.
    objcSendVoid1(_view, objcSelector('setLayerContentsRedrawPolicy:'), 0);
    _layer = objcRetain(objcSendPointer(_view, objcSelector('layer')));
    final DynamicLibrary quartz = DynamicLibrary.open(
        '/System/Library/Frameworks/QuartzCore.framework/QuartzCore');
    final int nearest = quartz.lookup<IntPtr>('kCAFilterNearest').value;
    final int topLeft = quartz.lookup<IntPtr>('kCAGravityTopLeft').value;
    objcSendVoid1(_layer, objcSelector('setMagnificationFilter:'), nearest);
    objcSendVoid1(_layer, objcSelector('setMinificationFilter:'), nearest);
    // A frame drawn for the old size stays pinned to the top left while a
    // live resize outruns it, instead of being stretched.
    objcSendVoid1(_layer, objcSelector('setContentsGravity:'), topLeft);
    if (_options.backgroundColor case final int color) {
      _setLayerBackground(color);
    } else if (transient) {
      _setLayerBackground(0);
    }
    _trackingArea = sendInitWithRect(
      objcSendPointer(objcClass('NSTrackingArea'), objcSelector('alloc')),
      'initWithRect:options:owner:userInfo:',
      cgRect(0, 0, 0, 0),
      _trackingOptions,
      _view.address,
      0,
    );
    objcSendVoid1(
        _view, objcSelector('addTrackingArea:'), _trackingArea.address);
    objcSendBool1(_native, objcSelector('makeFirstResponder:'), _view.address);
    if (centred) objcSendVoid(_native, objcSelector('center'));
    _readGeometry();
    _rebuildPool();
  }

  /// [color] - premultiplied BGRA in an int, as `WindowOptions` carries it -
  /// as the layer's background, what shows before the first frame.
  void _setLayerBackground(int color) {
    final double a = ((color >> 24) & 0xFF) / 255;
    final double r = ((color >> 16) & 0xFF) / 255;
    final double g = ((color >> 8) & 0xFF) / 255;
    final double b = (color & 0xFF) / 255;
    final Pointer<ObjCObject> nsColor = _colorWith(r, g, b, a);
    final Pointer<ObjCObject> cg =
        objcSendPointer(nsColor, objcSelector('CGColor'));
    objcSendVoid1(_layer, objcSelector('setBackgroundColor:'), cg.address);
  }

  static final Pointer<ObjCObject> Function(Pointer<ObjCObject>,
          Pointer<ObjCSelector>, double, double, double, double) _colorSend =
      DynamicLibrary.open('/usr/lib/libobjc.A.dylib').lookupFunction<
          Pointer<ObjCObject> Function(Pointer<ObjCObject>,
              Pointer<ObjCSelector>, Double, Double, Double, Double),
          Pointer<ObjCObject> Function(Pointer<ObjCObject>,
              Pointer<ObjCSelector>, double, double, double, double)>(
    'objc_msgSend',
  );

  static Pointer<ObjCObject> _colorWith(
          double r, double g, double b, double a) =>
      _colorSend(objcClass('NSColor'),
          objcSelector('colorWithSRGBRed:green:blue:alpha:'), r, g, b, a);

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
    final MacosSurfaceDescriptor? descriptor = _descriptor;
    return descriptor == null
        ? const <NativeSurfaceDescriptor>[]
        : <NativeSurfaceDescriptor>[descriptor];
  }

  @override
  Stream<PlatformWindowEvent> get events => _events.stream;

  /// What went wrong drawing into this window, newest last.
  List<BackendDiagnostic> get diagnostics =>
      List<BackendDiagnostic>.unmodifiable(_diagnostics);

  void recordRenderDiagnostic(BackendDiagnostic diagnostic) =>
      _diagnostics.add(diagnostic);

  @override
  void show() {
    if (isDisposed || _visible) return;
    ObjCAutoreleasePool.run(() {
      final MacosEmbeddedWindow? parent = owner;
      if (_transient) {
        // A menu never takes the keyboard from its owner.
        objcSendVoid1(_native, objcSelector('orderFront:'), 0);
      } else {
        objcSendVoid1(_native, objcSelector('makeKeyAndOrderFront:'), 0);
      }
      if (parent != null && !parent.isDisposed && !_childAttached) {
        // NSWindowAbove: directly in front of the owner, wherever it is in
        // the order, and moving with it.
        objcSendVoid2(parent._native, objcSelector('addChildWindow:ordered:'),
            _native.address, 1);
        _childAttached = true;
      }
    });
    _visible = true;
    scheduleMicrotask(requestRedraw);
  }

  @override
  void hide() {
    if (isDisposed || !_visible) return;
    ObjCAutoreleasePool.run(() {
      _detachFromOwner();
      objcSendVoid1(_native, objcSelector('orderOut:'), 0);
    });
    _visible = false;
  }

  void _detachFromOwner() {
    final MacosEmbeddedWindow? parent = owner;
    if (!_childAttached || parent == null) return;
    _childAttached = false;
    if (parent.isDisposed) return;
    objcSendVoid1(
        parent._native, objcSelector('removeChildWindow:'), _native.address);
  }

  @override
  void close() => dispose();

  @override
  void setTitle(String value) => ObjCAutoreleasePool.run(() => objcSendVoid1(
      _native, objcSelector('setTitle:'), nsString(value).address));

  /// [bounds] is the client area in screen points, top-left origin.
  @override
  void setBounds(Rect bounds) {
    if (isDisposed) return;
    ObjCAutoreleasePool.run(() {
      final CGRect frame = sendRectWithRect(
        _native,
        'frameRectForContentRect:',
        macosRectToAppKit(bounds, macosPrimaryScreenHeight()),
      );
      sendVoidRectWord(_native, 'setFrame:display:', frame, 1);
    });
    refreshGeometry();
  }

  @override
  void setCursor(SystemCursor cursor) {
    final String selector = switch (cursor) {
      SystemCursor.arrow => 'arrowCursor',
      SystemCursor.text => 'IBeamCursor',
      SystemCursor.hand => 'pointingHandCursor',
      SystemCursor.resizeHorizontal => 'resizeLeftRightCursor',
      SystemCursor.resizeVertical => 'resizeUpDownCursor',
      SystemCursor.resizeDiagonalDown => 'crosshairCursor',
      SystemCursor.resizeDiagonalUp => 'crosshairCursor',
      SystemCursor.wait => 'arrowCursor',
      SystemCursor.crosshair => 'crosshairCursor',
      SystemCursor.notAllowed => 'operationNotAllowedCursor',
    };
    objcSendVoid(objcSendPointer(objcClass('NSCursor'), objcSelector(selector)),
        objcSelector('set'));
  }

  @override
  void requestRedraw([Rect? dirtyRect]) {
    if (isDisposed) return;
    _emit(WindowExposedEvent(
      windowId: _id,
      generation: _generation.current,
      dirtyRect: dirtyRect,
    ));
  }

  /// The client area's top-left corner in screen points, top-left origin.
  Offset get _contentOrigin => ObjCAutoreleasePool.run(() {
        final CGRect content = sendRectWithRect(
            _native, 'contentRectForFrameRect:', sendRect(_native, 'frame'));
        return macosRectFromAppKit(content, macosPrimaryScreenHeight()).topLeft;
      });

  @override
  Offset screenToClient(Offset screenPosition) =>
      screenPosition - _contentOrigin;

  @override
  Offset clientToScreen(Offset clientPosition) =>
      clientPosition + _contentOrigin;

  @override
  void activate() {
    if (isDisposed || _transient) return;
    ObjCAutoreleasePool.run(() {
      final Pointer<ObjCObject> app = objcSendPointer(
          objcClass('NSApplication'), objcSelector('sharedApplication'));
      objcSendVoid1(app, objcSelector('activateIgnoringOtherApps:'), 1);
      objcSendVoid1(_native, objcSelector('makeKeyAndOrderFront:'), 0);
    });
  }

  // -------------------------------------------------------------------------
  // State
  // -------------------------------------------------------------------------

  bool _bool(String selector) => objcSendBool(_native, objcSelector(selector));

  bool get _isFullScreen =>
      (objcSendUnsigned(_native, objcSelector('styleMask')) & _fullScreen) != 0;

  @override
  bool requestState(WindowState state) {
    if (isDisposed || _transient) return false;
    void send(String selector) =>
        objcSendVoid1(_native, objcSelector(selector), 0);
    final bool zoomed = _bool('isZoomed');
    final bool miniaturized = _bool('isMiniaturized');
    final bool fullscreen = _isFullScreen;
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
          objcSendVoid1(
              _native, objcSelector('setCollectionBehavior:'), 1 << 7);
          send('toggleFullScreen:');
        }
    }
    refreshGeometry();
    return true;
  }

  // -------------------------------------------------------------------------
  // HiddenTitleBarWindow
  // -------------------------------------------------------------------------

  @override
  bool get isTitleBarHidden => _hiddenTitle;

  @override
  ValueNotifier<Rect> get systemButtons => _systemButtons;

  @override
  double get titleBarHeight => _titleBarHeight;

  @override
  bool beginMove() {
    final Pointer<ObjCObject> press = _lastMouseDown;
    if (isDisposed || press == nullptr) return false;
    objcSendVoid1(
        _native, objcSelector('performWindowDragWithEvent:'), press.address);
    return true;
  }

  @override
  void toggleMaximized() {
    if (isDisposed) return;
    objcSendVoid1(_native, objcSelector('zoom:'), 0);
  }

  /// Where the three buttons are, in client points, and how tall the title
  /// bar they sit in is.
  void _readTitleBar() {
    if (!_hiddenTitle) return;
    if (_isFullScreen) {
      _titleBarHeight = 0;
      _systemButtons.value = Rect.zero;
      return;
    }
    final CGRect frame = sendRect(_native, 'frame');
    final CGRect layout = sendRect(_native, 'contentLayoutRect');
    _titleBarHeight = frame.size.height - layout.size.height;
    Rect? buttons;
    // NSWindowCloseButton, MiniaturizeButton, ZoomButton.
    for (var kind = 0; kind <= 2; kind++) {
      final Pointer<ObjCObject> button = objcSendPointer1(
          _native, objcSelector('standardWindowButton:'), kind);
      if (button == nullptr) continue;
      final Pointer<ObjCObject> superview =
          objcSendPointer(button, objcSelector('superview'));
      // The button's frame in its superview, then in the window, then flipped
      // to the content view's top-left origin (the content view fills the
      // window when the title bar is hidden).
      final CGRect inWindow = sendRectWithRectAndObject(
          superview, 'convertRect:toView:', sendRect(button, 'frame'), nullptr);
      final Rect rect = Rect.fromLTWH(
        inWindow.origin.x,
        frame.size.height - inWindow.origin.y - inWindow.size.height,
        inWindow.size.width,
        inWindow.size.height,
      );
      buttons = buttons == null ? rect : buttons.union(rect);
    }
    _systemButtons.value = buttons ?? Rect.zero;
  }

  // -------------------------------------------------------------------------
  // From AppKit
  // -------------------------------------------------------------------------

  /// Re-reads size, scale, key state and window state, and reports what
  /// changed. AppKit's notifications land here; so does every setter that can
  /// move the window.
  void refreshGeometry() {
    if (isDisposed) return;
    ObjCAutoreleasePool.run(() {
      final Size before = _size;
      final double beforeScale = _scale;
      _readGeometry();
      if (_size != before || _scale != beforeScale) {
        _generation.invalidate();
        _rebuildPool();
        _emit(WindowResizedEvent(
          windowId: _id,
          generation: _generation.current,
          clientSize: _size,
          renderScale: _scale,
        ));
      }
      final WindowState state = _isFullScreen
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

  void _readGeometry() {
    final CGRect bounds = sendRect(_view, 'bounds');
    _size = Size(bounds.size.width, bounds.size.height);
    _scale = sendDouble(_native, 'backingScaleFactor');
    if (_scale <= 0) _scale = 1;
    sendVoidDouble(_layer, 'setContentsScale:', _scale);
    _readTitleBar();
  }

  /// A window notification from the delegate.
  void notification(MacosEmbeddedWindowNotification kind) {
    if (isDisposed) return;
    if (_trace) {
      stderr.writeln('dart_ui embedded: #$windowNumber ${_options.kind.name} '
          '${kind.selector}');
    }
    switch (kind) {
      case MacosEmbeddedWindowNotification.didBecomeKey ||
            MacosEmbeddedWindowNotification.didResignKey:
        final bool key = kind == MacosEmbeddedWindowNotification.didBecomeKey;
        if (key == _key) return;
        _key = key;
        _emit(WindowActivationEvent(
          windowId: _id,
          generation: _generation.current,
          activation:
              key ? WindowActivation.activated : WindowActivation.deactivated,
        ));
      case MacosEmbeddedWindowNotification.didMove:
        _emit(WindowMovedEvent(
          windowId: _id,
          generation: _generation.current,
          screenPosition: _contentOrigin,
        ));
      case MacosEmbeddedWindowNotification.willStartLiveResize:
        _liveResizing = true;
      case MacosEmbeddedWindowNotification.didEndLiveResize:
        _liveResizing = false;
        refreshGeometry();
      case MacosEmbeddedWindowNotification.didResize ||
            MacosEmbeddedWindowNotification.didChangeBackingProperties ||
            MacosEmbeddedWindowNotification.didMiniaturize ||
            MacosEmbeddedWindowNotification.didDeminiaturize ||
            MacosEmbeddedWindowNotification.didEnterFullScreen ||
            MacosEmbeddedWindowNotification.didExitFullScreen:
        refreshGeometry();
    }
  }

  /// An `NSEvent` the content view received.
  void viewEvent(Pointer<ObjCObject> event, int type) {
    if (isDisposed) return;
    if (type == 8 || type == 9) {
      _emit(type == 8
          ? WindowPointerEnterEvent(
              windowId: _id, generation: _generation.current)
          : WindowPointerLeaveEvent(
              windowId: _id, generation: _generation.current));
      return;
    }
    // A move reaches the view twice in a key window - from its tracking
    // area and as the first responder of a window that accepts moves.
    if (type == 5) {
      if (event.address == _lastMoveEvent) return;
      _lastMoveEvent = event.address;
    }
    if (type == 1) {
      final Pointer<ObjCObject> previous = _lastMouseDown;
      _lastMouseDown = objcRetain(event);
      objcRelease(previous);
    }
    final MacosRawEvent raw = decodeNSEvent(
      event,
      type,
      characters: (Pointer<ObjCObject> event) =>
          objcSendPointer(event, objcSelector('characters')),
    );
    // locationInWindow has its origin at the bottom left of the window,
    // which is the content view's - the title bar is above it.
    final Offset local = Offset(raw.screenX, _size.height - raw.screenY);
    if (_trace) {
      stderr.writeln('dart_ui embedded: #$windowNumber ${_options.kind.name} '
          'event $type at $local clicks ${raw.clickCount}');
    }
    translateMacosRawEvent(
      raw,
      local: local,
      windowId: _id,
      generation: _generation.current,
      emit: _emit,
    );
  }

  void closeRequested() {
    if (isDisposed) return;
    _emit(WindowCloseRequestedEvent(
      windowId: _id,
      generation: _generation.current,
    ));
  }

  // -------------------------------------------------------------------------
  // Surfaces and presentation
  // -------------------------------------------------------------------------

  void _rebuildPool() {
    final MacosSurfacePool? previous = _pool;
    final int width = (_size.width * _scale).round();
    final int height = (_size.height * _scale).round();
    if (width <= 0 || height <= 0) {
      _pool = null;
      _descriptor = null;
    } else {
      try {
        final MacosSurfacePool pool = createIOSurfacePool(
            pixelWidth: width, pixelHeight: height, global: false);
        _pool = pool;
        _descriptor = pool.describe(_scale, host: this);
      } on Object catch (error) {
        _pool = null;
        _descriptor = null;
        _diagnostics.add(BackendDiagnostic(
          kind: DiagnosticKind.surfaceCreationFailed,
          message: 'IOSurface pool for ${width}x$height failed',
          detail: '$error',
        ));
      }
    }
    // The layer keeps its own reference to the surface it shows, and a Metal
    // texture to the one it wraps; releasing ours is safe now.
    previous?.dispose();
  }

  @override
  bool get isPresentable => !isDisposed && _pool != null;

  @override
  int get presentGeneration => _generation.current;

  @override
  MacosSurfacePool? get currentPool => _pool;

  /// Shows the back slot, which the GPU has finished writing.
  @override
  Future<PresentResult> presentBackBuffer({required int generation}) =>
      Future<PresentResult>.value(_presentBack(generation));

  /// Runs [draw] over the back slot's own memory and shows it: the CPU
  /// path, with no copy.
  PresentResult drawAndPresent(
    void Function(Framebuffer buffer) draw, {
    int? frameGeneration,
  }) {
    final MacosSurfacePool? pool = _pool;
    if (isDisposed || pool == null) {
      return const PresentResult(
        status: PresentStatus.stale,
        diagnostic:
            BackendDiagnostic.note('the embedded window has no surface'),
      );
    }
    if (frameGeneration != null && !_generation.accepts(frameGeneration)) {
      return const PresentResult(status: PresentStatus.stale);
    }
    pool.withBackBuffer(draw);
    return _presentBack(_generation.current);
  }

  PresentResult _presentBack(int generation) {
    final MacosSurfacePool? pool = _pool;
    if (isDisposed || pool == null || pool.isDisposed) {
      return const PresentResult(
        status: PresentStatus.deviceLost,
        diagnostic: BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'present on a closed embedded window',
        ),
      );
    }
    if (!_generation.accepts(generation)) {
      return const PresentResult(status: PresentStatus.stale);
    }
    final int slot = pool.backSlot;
    final MacosPoolSurface surface = pool.surfaces[slot];
    if (surface is! MacosIOSurface) {
      return const PresentResult(
        status: PresentStatus.failed,
        diagnostic: BackendDiagnostic(
          kind: DiagnosticKind.surfaceCreationFailed,
          message: 'the back slot is not an IOSurface',
        ),
      );
    }
    final Pointer<ObjCObject> transaction = objcClass('CATransaction');
    objcSendVoid(transaction, objcSelector('begin'));
    objcSendVoid1(transaction, objcSelector('setDisableActions:'), 1);
    objcSendVoid1(
        _layer, objcSelector('setContents:'), surface.surfaceRef.address);
    objcSendVoid(transaction, objcSelector('commit'));
    pool.markPresented(slot);
    return const PresentResult(status: PresentStatus.presented);
  }

  // -------------------------------------------------------------------------
  // Synthetic input, for probes
  // -------------------------------------------------------------------------

  static final Pointer<ObjCObject> Function(
          Pointer<ObjCObject>,
          Pointer<ObjCSelector>,
          int,
          CGPoint,
          int,
          double,
          int,
          Pointer<ObjCObject>,
          int,
          int,
          double) _mouseEvent =
      DynamicLibrary.open('/usr/lib/libobjc.A.dylib').lookupFunction<
          Pointer<ObjCObject> Function(
              Pointer<ObjCObject>,
              Pointer<ObjCSelector>,
              UintPtr,
              CGPoint,
              UintPtr,
              Double,
              IntPtr,
              Pointer<ObjCObject>,
              IntPtr,
              IntPtr,
              Float),
          Pointer<ObjCObject> Function(
              Pointer<ObjCObject>,
              Pointer<ObjCSelector>,
              int,
              CGPoint,
              int,
              double,
              int,
              Pointer<ObjCObject>,
              int,
              int,
              double)>('objc_msgSend');

  static final Pointer<ObjCObject> Function(
          Pointer<ObjCObject>,
          Pointer<ObjCSelector>,
          int,
          CGPoint,
          int,
          double,
          int,
          Pointer<ObjCObject>,
          Pointer<ObjCObject>,
          Pointer<ObjCObject>,
          int,
          int) _keyEvent =
      DynamicLibrary.open('/usr/lib/libobjc.A.dylib').lookupFunction<
          Pointer<ObjCObject> Function(
              Pointer<ObjCObject>,
              Pointer<ObjCSelector>,
              UintPtr,
              CGPoint,
              UintPtr,
              Double,
              IntPtr,
              Pointer<ObjCObject>,
              Pointer<ObjCObject>,
              Pointer<ObjCObject>,
              Uint8,
              Uint16),
          Pointer<ObjCObject> Function(
              Pointer<ObjCObject>,
              Pointer<ObjCSelector>,
              int,
              CGPoint,
              int,
              double,
              int,
              Pointer<ObjCObject>,
              Pointer<ObjCObject>,
              Pointer<ObjCObject>,
              int,
              int)>('objc_msgSend');

  /// Posts an event into AppKit's own queue, addressed to this window, as
  /// the native host's `SYNTH_*` commands do - the same grammar, so a probe
  /// reads alike on both backends:
  ///
  ///   * `SYNTH_MOUSE <down|up|move|drag> <x> <y> <button> <clicks> <flags>`
  ///   * `SYNTH_KEY <down|up> <keyCode> <flags> <characters|-> <ignoring|->`
  ///     (plain text here, not base64; no spaces)
  ///   * `SYNTH_POINTER <enter|leave>`
  ///
  /// x and y are client points, top-left origin. AppKit routes the event as
  /// it would a real one: hit-testing, the first responder, child windows.
  bool synthesizeInput(String command) {
    if (isDisposed) return false;
    final List<String> parts = command.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) return false;
    return ObjCAutoreleasePool.run(() {
      final double now = sendDouble(
          objcSendPointer(
              objcClass('NSProcessInfo'), objcSelector('processInfo')),
          'systemUptime');
      switch (parts) {
        case ['SYNTH_POINTER', final String phase]:
          viewEvent(nullptr, phase == 'enter' ? 8 : 9);
          _onEvent();
          return true;
        case [
            'SYNTH_MOUSE',
            final String phase,
            final String x,
            final String y,
            final String button,
            final String clicks,
            final String flags,
          ]:
          final int index = int.parse(button);
          final int type = switch (phase) {
            'move' => 5,
            'drag' => index == 0 ? 6 : (index == 1 ? 7 : 27),
            'down' => index == 0 ? 1 : (index == 1 ? 3 : 25),
            _ => index == 0 ? 2 : (index == 1 ? 4 : 26),
          };
          final Pointer<ObjCObject> event = _mouseEvent(
            objcClass('NSEvent'),
            objcSelector('mouseEventWithType:location:modifierFlags:timestamp:'
                'windowNumber:context:eventNumber:clickCount:pressure:'),
            type,
            // Window coordinates: bottom-left origin of the content view.
            cgPoint(double.parse(x), _size.height - double.parse(y)),
            int.parse(flags),
            now,
            windowNumber,
            nullptr,
            0,
            int.parse(clicks),
            type == 5 ? 0 : 1,
          );
          return _post(event);
        case [
            'SYNTH_KEY',
            final String phase,
            final String keyCode,
            final String flags,
            final String characters,
            final String ignoring,
          ]:
          final Pointer<ObjCObject> event = _keyEvent(
            objcClass('NSEvent'),
            objcSelector('keyEventWithType:location:modifierFlags:timestamp:'
                'windowNumber:context:characters:'
                'charactersIgnoringModifiers:isARepeat:keyCode:'),
            phase == 'down' ? 10 : 11,
            cgPoint(0, 0),
            int.parse(flags),
            now,
            windowNumber,
            nullptr,
            nsString(characters == '-' ? '' : characters),
            nsString(ignoring == '-' ? '' : ignoring),
            0,
            int.parse(keyCode),
          );
          return _post(event);
        default:
          return false;
      }
    });
  }

  bool _post(Pointer<ObjCObject> event) {
    if (event == nullptr) return false;
    final Pointer<ObjCObject> app = objcSendPointer(
        objcClass('NSApplication'), objcSelector('sharedApplication'));
    objcSendVoid2(app, objcSelector('postEvent:atStart:'), event.address, 0);
    return true;
  }

  // -------------------------------------------------------------------------
  // Teardown
  // -------------------------------------------------------------------------

  void _emit(PlatformWindowEvent event) {
    if (!_events.isClosed) _events.add(event);
    _onEvent();
  }

  @override
  void onDispose() {
    _generation.invalidate();
    ObjCAutoreleasePool.run(() {
      _detachFromOwner();
      // A child still attached would keep a pointer to this window after it
      // is gone; the framework closes popups first, this is the backstop.
      final Pointer<ObjCObject> children =
          objcSendPointer(_native, objcSelector('childWindows'));
      final int count = children == nullptr
          ? 0
          : objcSendUnsigned(children, objcSelector('count'));
      for (var index = count - 1; index >= 0; index--) {
        objcSendVoid1(
            _native,
            objcSelector('removeChildWindow:'),
            objcSendPointer1(children, objcSelector('objectAtIndex:'), index)
                .address);
      }
      objcSendVoid1(_native, objcSelector('setDelegate:'), 0);
      objcSendVoid1(_native, objcSelector('orderOut:'), 0);
      objcSendVoid(_native, objcSelector('close'));
      objcSendVoid1(_layer, objcSelector('setContents:'), 0);
    });
    _pool?.dispose();
    _pool = null;
    _descriptor = null;
    objcRelease(_lastMouseDown);
    _lastMouseDown = nullptr;
    objcRelease(_trackingArea);
    objcRelease(_layer);
    // Autoreleased, not released: this can run inside an AppKit call that
    // still holds the window, and the pool of the run loop's turn is the
    // first moment nothing does.
    objcAutorelease(_view);
    objcAutorelease(_native);
    _visible = false;
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
