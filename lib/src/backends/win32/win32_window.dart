/// One real HWND behind the framework's [NativeWindow] contract.
///
/// ## What this window does not do yet
///
/// Deferred, and documented here because this is where a caller meets them:
///
///   * **Wheel and extended pointer input.** Core mouse movement/buttons and
///     keyboard transitions are normalized into the common input contract.
///     Wheel, high-resolution pointer data and device-specific state remain
///     deferred until their common contracts exist.
///   * **IME** (roadmap 13.7). WM_IME_* is unhandled, so composition falls back
///     to whatever `DefWindowProcW` does. Text input in CJK and with dead keys
///     will be wrong until the text-composition contract exists.
///   * **Clipboard** (13.8), **drag-and-drop** (13.9) and **accessibility**
///     (13.16). None of them are claimed in the probe's capabilities, so a
///     caller asking `probe().supports(Capability.clipboardText)` gets a
///     truthful no rather than a runtime surprise.
///   * **Fullscreen.** [WindowState.fullscreen] is never reported; the
///     borderless-on-monitor-bounds dance needs monitor enumeration, which
///     belongs with the screens module of 13.1.
library;

import 'dart:async';
import 'dart:ffi';

import '../../foundation/diagnostics.dart';
import '../../foundation/lifecycle.dart';
import '../../geometry/offset.dart';
import '../../geometry/rect.dart';
import '../../geometry/size.dart';
import '../../platform/input_events.dart';
import '../../platform/native_window.dart';
import '../../platform/window_events.dart';
import '../../rendering/renderer.dart';
import 'uia/uia_bridge.dart';
import 'win32_api.dart';
import 'win32_constants.dart';
import 'win32_coordinates.dart';
import 'win32_diagnostics.dart';
import 'win32_dib_surface.dart';
import 'win32_structs.dart';
import 'win32_window_class.dart';

/// `SWP_SHOWWINDOW`, `WS_DISABLED` and `HWND_TOP`.
///
/// Declared here rather than in `win32_constants.dart` because they are used
/// by exactly one file and that file is this one; the shared constant list is
/// for values more than one caller has to agree on.
const int _swpShowwindow = 0x0040;
const int _wsDisabled = 0x08000000;
const int _hwndTop = 0;
const int _wsExNoactivate = 0x08000000;
const int _wsExTopmost = 0x00000008;

/// A Win32 window.
///
/// Sizes crossing this boundary are logical; sizes below it are physical
/// pixels. The conversion happens once, in [Win32CoordinateSpace], and the
/// fields are named `_pixelWidth` / `clientSize` so that a mix-up reads wrong.
final class Win32Window
    with DisposableMixin
    implements
        NativeWindow,
        ActivatableWindow,
        EnableableWindow,
        LiveResizeWindow {
  Win32Window._({
    required Win32Api api,
    required Win32WindowClass windowClass,
    required void Function(Win32Window window) onClosed,
    required void Function() onSessionEnding,
    required int dpi,
    required int style,
    required int exStyle,
    required this.kind,
    required Size? minimumSize,
    required Size? maximumSize,
    required int? backgroundColor,
  })  : _api = api,
        _class = windowClass,
        _onClosed = onClosed,
        _onSessionEnding = onSessionEnding,
        _dpi = dpi,
        _style = style,
        _exStyle = exStyle,
        _minimumSize = minimumSize,
        _maximumSize = maximumSize {
    _desktopDpi = api.systemDpi();
    // A brush of our own rather than the class's `hbrBackground`, and the two
    // are not interchangeable: a class brush is painted by `DefWindowProcW`
    // over the *whole* update region, which during a resize includes every
    // pixel the framebuffer already owns - that is the flash the class comment
    // refuses. This one is used by [_onEraseBackground], which paints only the
    // strip nothing has drawn into yet.
    _backgroundBrush = _createBackgroundBrush(api, backgroundColor);
    // The window class deliberately has no cursor (see Win32WindowClass), so
    // WM_SETCURSOR belongs to us - which means a window that never calls
    // setCursor() would answer that message with nothing and leave whatever
    // the *previous* window put on screen: the resize arrow from dragging a
    // border, or the app-starting spinner. Starting from a real arrow handle
    // is what makes the client area look like a window rather than a hang.
    _cursorHandle = _handleForCursor(SystemCursor.arrow);
    _token = Win32WindowRegistry.attach(this);
    // Acquisition order, released in reverse by [onDispose]: token, scratch
    // memory, event stream, HWND. Destroying the HWND last means WM_DESTROY
    // still finds a live stream to report the close on and a live token to
    // resolve through.
    _resources
      ..add(_token, () => Win32WindowRegistry.detach(_token))
      ..add(_scratchRect, () => api.allocator.free(_scratchRect))
      ..add(_scratchPoint, () => api.allocator.free(_scratchPoint))
      ..add(_events, _events.close)
      ..add(this, _destroyHandle);
    if (_backgroundBrush != 0) {
      // A GDI object, not a system brush: this one is ours to delete, and a
      // window per second that leaked one would exhaust the process's GDI
      // handle quota long before its memory.
      _resources.add(
          _backgroundBrush, () => api.deleteObject(_backgroundBrush));
    }
  }

  /// A solid brush for [color], or for the system's window colour when null.
  ///
  /// Never left at zero when the API can produce one: zero is exactly the
  /// state that makes a newly exposed strip show whatever was in video memory,
  /// which is the black this window is trying to stop showing.
  static int _createBackgroundBrush(Win32Api api, int? color) {
    // Premultiplied BGRA packed as 0xAARRGGBB (little-endian byte order B,G,R,A)
    // on this side; COLORREF is 0x00BBGGRR on the other. The swap is the whole
    // conversion - GDI has no alpha here, and the framebuffer's own alpha is
    // meaningless against an opaque window.
    final colorRef = color == null
        ? api.getSysColor(colorWindow)
        : ((color >> 16) & 0xFF) |
            (((color >> 8) & 0xFF) << 8) |
            ((color & 0xFF) << 16);
    return api.createSolidBrush(colorRef);
  }

  /// Creates the window, or throws [Win32Failure] naming the call that failed.
  static Win32Window create({
    required Win32Api api,
    required Win32WindowClass windowClass,
    required WindowOptions options,
    required void Function(Win32Window window) onClosed,
    required void Function() onSessionEnding,
  }) {
    final kind = options.kind;
    final decorated = options.decorated && kind.isDecoratedByDefault;
    var style = decorated ? wsOverlappedWindow : wsPopup;
    if (!options.resizable) {
      // A non-resizable window keeps its caption and buttons but loses the
      // sizing border, which is what "not resizable" means to a user.
      style &= ~(wsThickframe | wsMaximizebox);
    }
    // An owned window is a tool window as far as the shell is concerned: it
    // belongs to its owner and must not get its own taskbar button, or closing
    // the owner leaves an orphaned entry the user can click.
    final owner = options.owner;
    final ownerHandle = owner is Win32Window ? owner.handle : 0;
    var exStyle =
        ownerHandle == 0 && kind.isTopLevel ? wsExAppwindow : wsExToolwindow;
    if (!kind.takesActivation) {
      // WS_EX_NOACTIVATE is what stops a menu from stealing the caret out of
      // the window that opened it. Without it, `ShowWindow` on the popup sends
      // the owner a WM_ACTIVATE(WA_INACTIVE) and every focus ring in it goes
      // grey while the user is merely reading a menu.
      exStyle |= _wsExNoactivate | _wsExTopmost;
    }

    // The window is created at the system DPI and corrected once its real
    // monitor is known: GetDpiForWindow needs an HWND, so there is no way to
    // get the first size exactly right in one call.
    final window = Win32Window._(
      api: api,
      windowClass: windowClass,
      onClosed: onClosed,
      onSessionEnding: onSessionEnding,
      dpi: api.systemDpi(),
      style: style,
      exStyle: exStyle,
      kind: kind,
      minimumSize: options.minimumSize,
      maximumSize: options.maximumSize,
      backgroundColor: options.backgroundColor,
    );

    final title = api.toUtf16(options.title);
    int handle;
    int lastError;
    try {
      handle = api.createWindowExW(
        exStyle,
        windowClass.namePointer,
        title,
        style,
        cwUseDefault,
        cwUseDefault,
        cwUseDefault,
        cwUseDefault,
        // hWndParent doubles as the *owner* for an overlapped or popup window,
        // which is what makes a dialog float above the window that opened it,
        // minimise with it and die with it. Zero for a top-level window.
        ownerHandle,
        0,
        windowClass.instanceHandle,
        window._token,
      );
      lastError = handle == 0 ? api.getLastError() : 0;
    } finally {
      api.heapRelease(title);
    }

    if (handle == 0) {
      window.dispose();
      throw Win32Failure(
        win32CallFailed(
          'CreateWindowExW',
          lastError,
          context: 'class "${windowClass.name}", '
              '${options.size.width}x${options.size.height} logical',
        ),
      );
    }
    window._hwnd = handle;

    final perWindowDpi = api.getDpiForWindow;
    if (perWindowDpi != null) {
      final dpi = perWindowDpi(handle);
      if (dpi > 0) window._dpi = dpi;
    }

    final failure = window._applyClientBounds(
      logicalSize: options.size,
      logicalPosition: options.position,
    );
    if (failure != null) {
      window.dispose();
      throw Win32Failure(failure);
    }

    // WM_SIZE normally builds the surface; a window that was created at
    // exactly the requested size never gets one.
    window._ensureSurface();

    if (options.visible) window.show();
    return window;
  }

  /// What this window is: an ordinary top-level window, a dialog, a menu or a
  /// tooltip. Decides its styles, whether showing it activates it, and whether
  /// closing it can end the application.
  final WindowKind kind;

  final Win32Api _api;
  final Win32WindowClass _class;
  final void Function(Win32Window window) _onClosed;
  final void Function() _onSessionEnding;
  final DisposableBag _resources = DisposableBag();
  final GenerationToken _generation = GenerationToken();

  final StreamController<PlatformWindowEvent> _events =
      StreamController<PlatformWindowEvent>.broadcast();

  /// Reused rather than allocated per message. Section 6.5 forbids an
  /// allocation per native callback, and WM_PAINT plus WM_MOUSEMOVE alone would
  /// otherwise allocate thousands of native blocks a second.
  late final Pointer<Win32Rect> _scratchRect = _api.allocator<Win32Rect>();
  late final Pointer<Win32Point> _scratchPoint = _api.allocator<Win32Point>();
  bool _scratchRectBusy = false;
  bool _scratchPointBusy = false;

  final List<BackendDiagnostic> _diagnostics = <BackendDiagnostic>[];

  int _token = 0;
  int _hwnd = 0;
  int _dpi;
  int _desktopDpi = defaultScreenDpi;
  final int _style;
  final int _exStyle;

  int _pixelWidth = 0;
  int _pixelHeight = 0;
  WindowState _state = WindowState.normal;
  SystemCursor _cursor = SystemCursor.arrow;
  int _cursorHandle = 0;
  Win32DibSurface? _surface;
  bool _destroyed = false;

  final Size? _minimumSize;
  final Size? _maximumSize;
  late final int _backgroundBrush;

  /// The client area, in physical pixels, that something has actually
  /// presented into.
  ///
  /// Not the same as [pixelSize], and the difference is the bug: a resize makes
  /// the client area bigger *first* and the frame follows, so between the two
  /// there is a strip of window that no framebuffer has ever covered. This is
  /// the rectangle that has been covered, and [_onEraseBackground] paints
  /// exactly what is outside it.
  int _paintedWidth = 0;
  int _paintedHeight = 0;

  /// Whether Windows is inside its own modal resize/move loop.
  bool _inSizeMove = false;

  /// The synchronous frame hook, and the guard that stops it re-entering. See
  /// [LiveResizeWindow].
  LiveResizeCallback? _liveResizeCallback;
  bool _inLiveFrame = false;
  int _liveResizeFrames = 0;
  int _liveResizeFramesSuppressed = 0;
  int _backgroundFills = 0;

  /// System cursors are shared objects owned by the OS: loading the same one
  /// twice returns the same handle and destroying one is forbidden. Caching
  /// keeps `setCursor` off the loader entirely after the first use.
  static final Map<SystemCursor, int> _cursorCache = <SystemCursor, int>{};

  /// The native handle. Public because a renderer backend needs it to build a
  /// swapchain; treat it as read-only.
  int get handle => _hwnd;

  /// The window class this window belongs to, for diagnostics.
  String get className => _class.name;

  /// Non-fatal failures this window has seen. Bounded: a window that fails to
  /// present every frame must not turn into a memory leak.
  List<BackendDiagnostic> get diagnostics =>
      List<BackendDiagnostic>.unmodifiable(_diagnostics);

  @override
  NativeWindowId get id => NativeWindowId(_token);

  @override
  int get generation => _generation.current;

  /// Whether work stamped with [generation] still applies. The public form of
  /// the comparison every late callback has to make.
  bool isCurrent(int generation) => _generation.accepts(generation);

  @override
  void setLiveResizeCallback(LiveResizeCallback? callback) =>
      _liveResizeCallback = callback;

  @override
  bool get isLiveResizing => _inSizeMove;

  /// Frames driven synchronously out of `WM_SIZE` since this window opened.
  ///
  /// The number that makes "the modal loop really is being painted through"
  /// checkable rather than asserted.
  int get liveResizeFrames => _liveResizeFrames;

  /// Resize messages that wanted a synchronous frame and were refused because
  /// one was already running.
  ///
  /// Counted rather than merely returned from, because a suppressed frame and
  /// a frame that was never asked for look identical from outside, and only one
  /// of the two is the reentrancy guard doing its job.
  int get liveResizeFramesSuppressed => _liveResizeFramesSuppressed;

  /// The client area, in physical pixels, that has actually been presented
  /// into. See [_paintedWidth].
  ({int width, int height}) get paintedPixelSize =>
      (width: _paintedWidth, height: _paintedHeight);

  /// The brush the not-yet-drawn strip is filled with. Zero only when GDI
  /// refused to make one.
  int get backgroundBrush => _backgroundBrush;

  /// How many times the background brush has actually been put on pixels.
  ///
  /// Exposed because the alternative claim - "the exposed strip is painted" -
  /// is otherwise only checkable by reading the screen, and a fill that stopped
  /// happening would look exactly like a fill that had nothing to do.
  int get backgroundFills => _backgroundFills;

  @override
  Size get clientSize =>
      _space.physicalSizeToLogical(_pixelWidth, _pixelHeight);

  /// The client area in physical pixels, which is what a framebuffer is
  /// allocated at.
  ({int width, int height}) get pixelSize =>
      (width: _pixelWidth, height: _pixelHeight);

  @override
  double get renderScale => win32ScaleForDpi(_dpi);

  /// The desktop's own scale.
  ///
  /// Windows has no separate text-scale factor outside WinRT's
  /// `UISettings.TextScaleFactor`, so this is the system DPI rather than an
  /// accessibility setting. It differs from [renderScale] exactly when the
  /// window sits on a monitor that is not at the system scale, which is the
  /// case the two-scale split exists for.
  @override
  double get desktopScale => win32ScaleForDpi(_desktopDpi);

  /// The window's DPI, for callers that want the raw number.
  int get dpi => _dpi;

  @override
  WindowState get state => _state;

  @override
  List<NativeSurfaceDescriptor> get surfaces {
    final surface = _surface;
    return surface == null
        ? const <NativeSurfaceDescriptor>[]
        : <NativeSurfaceDescriptor>[surface];
  }

  /// The CPU surface, typed. Null while the window has no client area - a
  /// minimised window, or one being torn down.
  Win32DibSurface? get dibSurface => _surface;

  @override
  Stream<PlatformWindowEvent> get events => _events.stream;

  /// Whether anybody would see an error put on [events]. The fault policy
  /// needs to know before it chooses between the stream and the zone.
  bool get hasEventListener => _events.hasListener;

  /// Surfaces an error on [events]. Used by the backend's WndProc fault
  /// policy; an application never calls it.
  void reportError(Object error, StackTrace stackTrace) {
    if (_events.isClosed) return;
    _events.addError(error, stackTrace);
  }

  /// Records a renderer-side failure against this window.
  ///
  /// Public only for the Win32 CPU presenter, which lives in a separate
  /// library so its event-driven behaviour can be tested without user32.
  void recordRenderDiagnostic(BackendDiagnostic diagnostic) =>
      _record(diagnostic);

  Win32CoordinateSpace get _space => Win32CoordinateSpace(
        clientOriginX: _clientOriginX,
        clientOriginY: _clientOriginY,
        scale: win32ScaleForDpi(_dpi),
      );

  int _clientOriginX = 0;
  int _clientOriginY = 0;

  // ---------------------------------------------------------------------------
  // NativeWindow surface
  // ---------------------------------------------------------------------------

  @override
  void show() {
    if (_hwnd == 0) return;
    // SW_SHOWNOACTIVATE for a menu or a tooltip: showing one must not take the
    // keyboard away from the window that opened it. That is not cosmetic - a
    // text field whose window was deactivated stops blinking its caret and
    // dims its selection, so a menu that activated itself would make every
    // field look unfocused for as long as the menu was open.
    _api.showWindow(
      _hwnd,
      kind.takesActivation ? swShowNormal : swShowNoActivate,
    );
    _api.updateWindow(_hwnd);
  }

  @override
  void hide() {
    if (_hwnd == 0) return;
    _api.showWindow(_hwnd, swHide);
  }

  /// Raises the window and asks for the keyboard.
  ///
  /// `SetWindowPos` to the top *without* `SWP_NOACTIVATE` is the activation
  /// path, rather than `SetForegroundWindow`: the two do the same thing for a
  /// window of the process the user is already in, and Windows refuses
  /// foreground stealing from a process that is not - so
  /// `SetForegroundWindow`'s extra power is exactly the power that gets
  /// silently denied. Nothing here believes it worked: the application's focus
  /// bookkeeping moves on the WM_ACTIVATE / WM_SETFOCUS that comes back.
  @override
  void activate() {
    if (_hwnd == 0 || _destroyed) return;
    if (!kind.takesActivation) return;
    if (!isEnabled) {
      // A disabled window cannot take the keyboard, and asking makes Windows
      // beep at the user. Its modal child is what should be activated, and
      // that is the application layer's decision, not this one's.
      return;
    }
    _api.showWindow(_hwnd, swShowNormal);
    if (_api.setWindowPos(
          _hwnd,
          _hwndTop,
          0,
          0,
          0,
          0,
          swpNomove | swpNosize | _swpShowwindow,
        ) ==
        0) {
      _record(win32CallFailed(
        'SetWindowPos',
        _api.getLastError(),
        context: 'activating window 0x${_hwnd.toRadixString(16)}',
      ));
    }
  }

  /// Whether Windows will deliver mouse and keyboard input to this window.
  @override
  bool get isEnabled {
    if (_hwnd == 0) return false;
    return (_api.getWindowLongPtrW(_hwnd, gwlStyle) & _wsDisabled) == 0;
  }

  /// Turns platform input to this window on or off - the platform half of
  /// modality.
  ///
  /// Implemented by toggling `WS_DISABLED` through `SetWindowLongPtrW` rather
  /// than by `EnableWindow`, because `EnableWindow` is not among the symbols
  /// this backend binds and the style bit *is* what `EnableWindow` sets. What
  /// is given up by not calling it is the `WM_ENABLE` notification, which
  /// nothing in this framework listens for: the application layer already
  /// knows it opened the modal, and it refuses to route events to a blocked
  /// window on its own account.
  @override
  void setEnabled(bool value) {
    if (_hwnd == 0 || _destroyed) return;
    final style = _api.getWindowLongPtrW(_hwnd, gwlStyle);
    final next = value ? style & ~_wsDisabled : style | _wsDisabled;
    if (next == style) return;
    _api.setWindowLongPtrW(_hwnd, gwlStyle, next);
  }

  /// The last activation state reported upwards, or null before the first one.
  ///
  /// Nullable rather than false-by-default so that the very first message -
  /// whichever of WM_ACTIVATE, WM_SETFOCUS or WM_KILLFOCUS arrives first - is
  /// always reported. A window created behind another one really is inactive,
  /// and swallowing that first "inactive" would leave the application
  /// believing a background window had the keyboard.
  bool? _activated;

  /// Whether Windows last told us this window has the keyboard.
  bool get isActivated => _activated ?? false;

  void _reportActivation({required bool active}) {
    if (_activated == active) return;
    _activated = active;
    _emit(
      WindowActivationEvent(
        windowId: id,
        generation: _generation.current,
        activation:
            active ? WindowActivation.activated : WindowActivation.deactivated,
      ),
    );
  }

  /// Destroys the window. WM_DESTROY arrives synchronously from inside
  /// `DestroyWindow`, so the closed event is emitted before this returns.
  @override
  void close() => _destroyHandle();

  @override
  void setTitle(String value) {
    if (_hwnd == 0) return;
    final title = _api.toUtf16(value);
    final ok = _api.setWindowTextW(_hwnd, title);
    final error = ok == 0 ? _api.getLastError() : 0;
    _api.heapRelease(title);
    if (ok == 0) _record(win32CallFailed('SetWindowTextW', error));
  }

  @override
  void setBounds(Rect bounds) {
    final failure = _applyClientBounds(
      logicalSize: bounds.size,
      logicalPosition: bounds.topLeft,
    );
    if (failure != null) _record(failure);
  }

  @override
  void setCursor(SystemCursor cursor) {
    _cursor = cursor;
    _cursorHandle = _handleForCursor(cursor);
    // Apply immediately: if the pointer is already inside the window, no
    // WM_SETCURSOR will arrive until it moves again.
    if (_cursorHandle != 0) _api.setCursor(_cursorHandle);
  }

  /// The cursor last requested, for tests and diagnostics.
  SystemCursor get cursor => _cursor;

  /// The native `HCURSOR` this window answers `WM_SETCURSOR` with.
  ///
  /// Zero means the client area sets no cursor at all, which is the failure
  /// this class must never be in: see the constructor.
  int get cursorHandle => _cursorHandle;

  int _handleForCursor(SystemCursor cursor) {
    final cached = _cursorCache[cursor];
    if (cached != null) return cached;
    final id = switch (cursor) {
      SystemCursor.arrow => idcArrow,
      SystemCursor.text => idcIbeam,
      SystemCursor.hand => idcHand,
      SystemCursor.resizeHorizontal => idcSizeWe,
      SystemCursor.resizeVertical => idcSizeNs,
      SystemCursor.resizeDiagonalDown => idcSizeNwse,
      SystemCursor.resizeDiagonalUp => idcSizeNesw,
      SystemCursor.wait => idcWait,
      SystemCursor.crosshair => idcCross,
      SystemCursor.notAllowed => idcNo,
    };
    final handle = _api.loadCursorW(0, id);
    if (handle == 0) {
      _record(win32CallFailed(
        'LoadCursorW',
        _api.getLastError(),
        context: 'cursor ${cursor.name} (IDC $id)',
      ));
      return 0;
    }
    _cursorCache[cursor] = handle;
    return handle;
  }

  @override
  void requestRedraw([Rect? dirtyRect]) {
    if (_hwnd == 0) return;
    if (dirtyRect == null) {
      // bErase = 0: the class has no background brush and every pixel comes
      // from the framebuffer, so erasing would only cause a flash.
      _api.invalidateRect(_hwnd, nullptr, 0);
      return;
    }
    final physical = _space.logicalRectToPhysical(dirtyRect);
    _withScratchRect((rect) {
      rect.ref
        ..left = physical.left
        ..top = physical.top
        ..right = physical.right
        ..bottom = physical.bottom;
      _api.invalidateRect(_hwnd, rect, 0);
    });
  }

  @override
  Offset screenToClient(Offset screenPosition) =>
      _refreshOrigin().screenToClient(screenPosition);

  @override
  Offset clientToScreen(Offset clientPosition) =>
      _refreshOrigin().clientToScreen(clientPosition);

  /// Asks Windows where the client area currently is.
  ///
  /// Cheaper than it looks - one syscall, no allocation - and always right,
  /// which a cached origin is not: a window can be moved by the shell, by
  /// another process, or by a monitor being unplugged, and not every one of
  /// those routes through WM_MOVE before the caller asks.
  Win32CoordinateSpace _refreshOrigin() {
    if (_hwnd == 0) return _space;
    _withScratchPoint((point) {
      point.ref
        ..x = 0
        ..y = 0;
      if (_api.clientToScreen(_hwnd, point) != 0) {
        _clientOriginX = point.ref.x;
        _clientOriginY = point.ref.y;
      }
    });
    return _space;
  }

  // ---------------------------------------------------------------------------
  // Message handling
  // ---------------------------------------------------------------------------

  /// Called from the shared WndProc once the token resolved to this window.
  ///
  /// Internal: public only because the router lives in another library.
  int handleMessage(int hwnd, int msg, int wParam, int lParam) {
    switch (msg) {
      case wmErasebkgnd:
        return _onEraseBackground(wParam);

      case wmPaint:
        return _onPaint(hwnd);

      case wmSize:
        return _onSize(wParam, lParam);

      case wmGetminmaxinfo:
        return _onGetMinMaxInfo(lParam);

      // The two ends of the OS's own modal loop. Windows does not return from
      // `DispatchMessageW` between them, so between them nothing on the Dart
      // side runs unless the platform calls it directly - which is what
      // [LiveResizeWindow] exists to arrange, and why the flag has to be set
      // here rather than inferred from WM_SIZE.
      case wmEntersizemove:
        _inSizeMove = true;
        return 0;

      case wmExitsizemove:
        _inSizeMove = false;
        // The queued events - one WindowResizedEvent per mouse movement, plus
        // the exposures - are about to be drained all at once by a message loop
        // that can finally return. Asking for a repaint here is what makes the
        // *last* size the one that gets a properly scheduled frame, whether or
        // not live resize drew anything during the drag.
        requestRedraw();
        return 0;

      case wmMove:
        return _onMove(lParam);

      case wmDpichanged:
        return _onDpiChanged(wParam, lParam);

      case wmActivate:
        // A half-delivered surrogate pair cannot survive the window losing the
        // keyboard: its low half is going to another window, and keeping the
        // high half would fuse it onto whatever is typed here next.
        if (win32LoWord(wParam) == waInactive) _textAssembler.reset();
        _reportActivation(active: win32LoWord(wParam) != waInactive);
        return _api.defWindowProcW(hwnd, msg, wParam, lParam);

      // WM_SETFOCUS and WM_KILLFOCUS are the *keyboard* half of activation,
      // and they are handled as well as WM_ACTIVATE rather than instead of it
      // because the two are not the same event and neither implies the other:
      //
      //   * WM_ACTIVATE is about the window the user is working in. It is what
      //     the title bar renders and what the shell means by "the active
      //     window". A window can be active and hand the caret to an owned
      //     tool window without ever being deactivated.
      //   * WM_SETFOCUS / WM_KILLFOCUS is about which HWND the keyboard is
      //     actually wired to, which is the one a text field must obey. A
      //     click on another window of the *same* application delivers these
      //     without necessarily delivering WM_ACTIVATE first.
      //
      // Both are normalised into one [WindowActivationEvent], de-duplicated by
      // [_reportActivation] so the pair that arrives together on an ordinary
      // Alt+Tab is one event and not two.
      case wmSetfocus:
        _reportActivation(active: true);
        return _api.defWindowProcW(hwnd, msg, wParam, lParam);

      case wmKillfocus:
        _textAssembler.reset();
        _reportActivation(active: false);
        return _api.defWindowProcW(hwnd, msg, wParam, lParam);

      case wmSetcursor:
        // Only the client area is ours; the frame's cursors (resize arrows on
        // the border) belong to DefWindowProc.
        if (win32LoWord(lParam) == htClient && _cursorHandle != 0) {
          _api.setCursor(_cursorHandle);
          return 1;
        }
        return _api.defWindowProcW(hwnd, msg, wParam, lParam);

      case wmClose:
        // A request, not an order: the framework decides. Nothing is destroyed
        // here, so an application that ignores the event keeps its window -
        // which is why every application must handle it.
        _emit(
          WindowCloseRequestedEvent(
            windowId: id,
            generation: _generation.current,
          ),
        );
        return 0;

      case wmQueryendsession:
        _onSessionEnding();
        return _api.defWindowProcW(hwnd, msg, wParam, lParam);

      case wmEndsession:
        if (wParam != 0) _onSessionEnding();
        return _api.defWindowProcW(hwnd, msg, wParam, lParam);

      case wmDestroy:
        _onDestroy();
        return 0;

      case wmNcdestroy:
        _onNcDestroy();
        return _api.defWindowProcW(hwnd, msg, wParam, lParam);

      case wmMousemove:
        return _onPointerMove(lParam);

      case wmLbuttondown:
        return _onPointerDown(PointerButton.primary, lParam);

      case wmLbuttonup:
        return _onPointerUp(PointerButton.primary, lParam);

      case wmRbuttondown:
        return _onPointerDown(PointerButton.secondary, lParam);

      case wmRbuttonup:
        return _onPointerUp(PointerButton.secondary, lParam);

      case wmMbuttondown:
        return _onPointerDown(PointerButton.middle, lParam);

      case wmMbuttonup:
        return _onPointerUp(PointerButton.middle, lParam);

      // The second press of a double click, which Windows sends *instead of* a
      // second `WM_BUTTONDOWN` because the class carries `CS_DBLCLKS`. Not
      // handling these is not a missing feature, it is a **lost press**: the
      // framework saw one down where the user made two, so no amount of
      // counting downstream could ever reach two. See [wmLbuttondblclk].
      //
      // Emitted as an ordinary down, so every consumer that only cares about
      // presses keeps working unchanged, and `clickCount: 2` carries the one
      // thing this message knows and a Dart timer cannot: that *Windows*
      // matched the two presses, using the interval and the rectangle the user
      // configured.
      case wmLbuttondblclk:
        return _onPointerDown(PointerButton.primary, lParam, clickCount: 2);

      case wmRbuttondblclk:
        return _onPointerDown(PointerButton.secondary, lParam, clickCount: 2);

      case wmMbuttondblclk:
        return _onPointerDown(PointerButton.middle, lParam, clickCount: 2);

      // The two side buttons, and the one family of mouse message whose button
      // is *not* in the message id: `XBUTTON1` and `XBUTTON2` arrive in the
      // high word of wParam, so one case has to serve both. The X11 backend
      // already emits these from buttons 8 and 9, which made the gap a
      // divergence between backends rather than a missing feature - and a
      // divergence is the kind of bug that surfaces as "back works on Linux".
      //
      // These three are also the only mouse messages that must answer TRUE:
      // the documented protocol says a handler returns TRUE, and DefWindowProcW
      // returns FALSE, which is how a sender learns nobody wanted it.
      case wmXbuttondown:
        _onPointerDown(_sideButton(wParam), lParam);
        return 1;

      case wmXbuttonup:
        _onPointerUp(_sideButton(wParam), lParam);
        return 1;

      case wmXbuttondblclk:
        _onPointerDown(_sideButton(wParam), lParam, clickCount: 2);
        return 1;

      case wmMousewheel:
        return _onPointerScroll(wParam, lParam, horizontal: false);

      // The tilt wheel and a trackpad's sideways swipe. Handled separately
      // rather than folded into the arm above because the two disagree about
      // sign: WM_MOUSEHWHEEL is already positive-to-the-right, which is the
      // framework's own direction, while WM_MOUSEWHEEL is positive-away-from
      // -the-user, which is the opposite of it. See [_onPointerScroll].
      case wmMousehwheel:
        return _onPointerScroll(wParam, lParam, horizontal: true);

      // The tilt wheel and a trackpad's sideways swipe. Handled separately
      // rather than folded into the arm above because the two disagree about
      // sign: WM_MOUSEHWHEEL is already positive-to-the-right, which is the
      // framework's own direction, while WM_MOUSEWHEEL is positive-away-from
      // -the-user, which is the opposite of it. See [_onPointerScroll].

      case wmMouseleave:
        return _onPointerLeave();

      case wmCapturechanged:
        return _onCaptureLost();

      case wmKeydown:
      case wmSyskeydown:
        return _onKeyDown(wParam, lParam);

      case wmGetobject:
        // lParam == UiaRootObjectId (-25) is a UI Automation client asking for
        // a provider. Anything else - OBJID_CLIENT above all - is MSAA and
        // belongs to DefWindowProcW, which is what a null answer means. The
        // returned LRESULT is a cookie from UiaReturnRawElementProvider, not a
        // pointer: return it unchanged.
        final int? provider =
            Win32UiaBridge.handleGetObject(hwnd, wParam, lParam);
        if (provider != null) return provider;
        return _api.defWindowProcW(hwnd, msg, wParam, lParam);

      case wmKeyup:
      case wmSyskeyup:
        return _onKeyUp(wParam, lParam);

      case wmChar:
        return _onChar(wParam);

      case wmSyschar:
      case wmDeadchar:
      case wmSysdeadchar:
        // Declared rather than left to fall through the default arm, because
        // "the default arm happens to do the right thing" is not a decision
        // anybody can review. None of the three is text:
        //
        //   * WM_SYSCHAR is an Alt chord - a menu mnemonic. Typing `f` for
        //     Alt+F would insert into the document while the user was opening
        //     a menu.
        //   * WM_DEADCHAR / WM_SYSDEADCHAR is the accent half of a dead-key
        //     sequence. Inserting it would give `´a` where the user typed `á`;
        //     the composed character arrives afterwards as its own WM_CHAR.
        //
        // Handed to DefWindowProcW, which is what keeps system mnemonics
        // working and keeps the dead-key state machine in the OS where it
        // belongs.
        return _api.defWindowProcW(hwnd, msg, wParam, lParam);

      default:
        // Every input message lands here: one call out, nothing allocated.
        return _api.defWindowProcW(hwnd, msg, wParam, lParam);
    }
  }

  /// Called from WM_NCCREATE, before `CreateWindowExW` has returned.
  void attachHandle(int hwnd) => _hwnd = hwnd;

  bool _trackingMouse = false;

  int _onPointerMove(int lParam) {
    if (!_trackingMouse) {
      _trackingMouse = true;
      final tme = _api.allocator<TrackMouseEventStruct>();
      try {
        tme.ref
          ..cbSize = sizeOf<TrackMouseEventStruct>()
          ..dwFlags = tmeLeave
          ..hwndTrack = _hwnd
          ..dwHoverTime = 0;
        _api.trackMouseEvent(tme);
      } finally {
        _api.allocator.free(tme);
      }
      _emit(
        WindowPointerEnterEvent(
          windowId: id,
          generation: _generation.current,
        ),
      );
    }
    _lastPointerPosition = _space.physicalToLogical(
      win32SignedLoWord(lParam),
      win32SignedHiWord(lParam),
    );
    _emit(
      PointerMoveEvent(
        windowId: id,
        generation: _generation.current,
        timestamp: _eventTimestamp(),
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: _lastPointerPosition,
      ),
    );
    return 0;
  }

  /// Which side button a `WM_XBUTTON*` message is about.
  ///
  /// `XBUTTON1` is the one nearer the user's thumb-rest, which every desktop
  /// and every browser maps to Back; `XBUTTON2` is Forward. That is the same
  /// assignment the X11 backend makes for buttons 8 and 9, which is the point:
  /// a framework whose Back button depended on the platform would be worse than
  /// one that had none.
  static PointerButton _sideButton(int wParam) =>
      win32HiWord(wParam) == xbutton2
          ? PointerButton.forward
          : PointerButton.back;

  /// Buttons currently held down, so capture is released exactly once - when
  /// the last of them comes up rather than when the first does.
  final Set<PointerButton> _heldButtons = <PointerButton>{};

  int _onPointerDown(PointerButton button, int lParam, {int clickCount = 1}) {
    // Mouse capture at the OS level. The framework's own capture routes an
    // event to the control that took the pointer, but it can only route events
    // that arrive - and Windows stops sending WM_MOUSEMOVE the instant the
    // cursor leaves the window. Without this, dragging a slider off the edge
    // of the window freezes it, which is the same bug one layer down.
    if (_heldButtons.isEmpty && _hwnd != 0) _api.setCapture(_hwnd);
    _heldButtons.add(button);
    _emit(
      PointerDownEvent(
        windowId: id,
        generation: _generation.current,
        timestamp: _eventTimestamp(),
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: _space.physicalToLogical(
          win32SignedLoWord(lParam),
          win32SignedHiWord(lParam),
        ),
        button: button,
        clickCount: clickCount,
      ),
    );
    return 0;
  }

  int _onPointerUp(PointerButton button, int lParam) {
    _heldButtons.remove(button);
    // Released only when the last button comes up: letting go of the right
    // button in the middle of a left-drag must not end the drag. Held past the
    // event so the framework still sees the release as captured.
    if (_heldButtons.isEmpty && _api.getCapture() == _hwnd) {
      _api.releaseCapture();
    }
    _emit(
      PointerUpEvent(
        windowId: id,
        generation: _generation.current,
        timestamp: _eventTimestamp(),
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: _space.physicalToLogical(
          win32SignedLoWord(lParam),
          win32SignedHiWord(lParam),
        ),
        button: button,
      ),
    );
    return 0;
  }

  /// The capture went away while a button was still down.
  ///
  /// It can be taken by anything - another window, a system drag, Alt+Tab -
  /// and no release will ever arrive for the press we are holding. Without a
  /// synthesized cancel the control stays armed forever: visibly stuck in its
  /// pressed state, and ready to activate on some later unrelated click.
  ///
  /// Our own ReleaseCapture in [_onPointerUp] also lands here, and clears
  /// [_heldButtons] *before* releasing precisely so that this does not fire a
  /// cancel at the end of an ordinary click.
  int _onCaptureLost() {
    if (_heldButtons.isEmpty) return 0;
    _heldButtons.clear();
    _emit(
      PointerCancelEvent(
        windowId: id,
        generation: _generation.current,
        timestamp: _eventTimestamp(),
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: _lastPointerPosition,
      ),
    );
    return 0;
  }

  Offset _lastPointerPosition = Offset.zero;

  int _onPointerLeave() {
    _trackingMouse = false;
    _emit(
      WindowPointerLeaveEvent(
        windowId: id,
        generation: _generation.current,
      ),
    );
    return 0;
  }

  /// `WM_MOUSEWHEEL` and `WM_MOUSEHWHEEL`, normalised into one event.
  ///
  /// Two things happen here that are easy to get wrong in opposite directions.
  ///
  /// **The coordinates are screen coordinates.** Alone among the mouse
  /// messages, the wheel's `lParam` is relative to the desktop rather than to
  /// the client area. Reading it like the others puts the scroll at the
  /// window's position on the desktop instead of under the pointer, which on a
  /// maximised window on a second monitor lands outside every scrollable there
  /// is.
  ///
  /// **The vertical sign is inverted and the horizontal one is not.** Windows
  /// makes `WHEEL_DELTA` positive when the wheel is rolled *away* from the
  /// user, which is scrolling **up**; this framework's contract is the
  /// opposite and says so in three independent places -
  /// `PointerScrollEvent.scrollDelta` is documented as "toward increasing
  /// coordinates", `RenderScrollViewer` maps Down to `applyDelta(+lineExtent)`,
  /// and the X11 backend maps wheel-down (button 5) to `Offset(0, +1)`. So the
  /// vertical word is negated. `WM_MOUSEHWHEEL` is already positive-to-the
  /// -right, which *is* toward increasing coordinates, so it must not be - and
  /// negating both, which is the natural way to write this, would leave
  /// horizontal scrolling backwards in exchange for fixing vertical.
  int _onPointerScroll(int wParam, int lParam, {required bool horizontal}) {
    var x = win32SignedLoWord(lParam);
    var y = win32SignedHiWord(lParam);
    _withScratchPoint((point) {
      point.ref
        ..x = x
        ..y = y;
      if (_api.screenToClient(_hwnd, point) != 0) {
        x = point.ref.x;
        y = point.ref.y;
      }
    });
    final detents = win32SignedHiWord(wParam) / wheelDelta;
    // Shift+vertical wheel is the conventional stand-in for a horizontal wheel
    // on a mouse that has none, and it inherits the vertical message's sign.
    final onHorizontalAxis = horizontal || (wParam & mkShift) != 0;
    final delta = horizontal ? detents : -detents;
    final position = _space.physicalToLogical(x, y);
    _emit(
      PointerScrollEvent(
        windowId: id,
        generation: _generation.current,
        timestamp: _eventTimestamp(),
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: position,
        scrollDelta: onHorizontalAxis ? Offset(delta, 0) : Offset(0, delta),
        scrollDeltaUnit: ScrollDeltaUnit.lines,
      ),
    );
    return 0;
  }

  /// The one clock every input event of this backend is stamped with.
  ///
  /// Two things were wrong before, and they compounded. The clock was
  /// `DateTime.now()`, which `PlatformInputEvent.timestamp` explicitly is not
  /// allowed to be - it is documented as "monotonic timestamp of the event, as
  /// reported by the OS", and `DateTime.now()` is neither monotonic (the user
  /// can move it, NTP does move it) nor the OS's opinion about *this message*.
  /// And it was read in two different units in the same class: pointer and key
  /// events stamped milliseconds-since-epoch while scroll and text stamped
  /// microseconds-since-epoch, so the two families of event were a literal
  /// factor of 1000 apart in a field whose whole purpose is to be subtracted.
  /// Nothing crossed the two groups yet, which is the only reason it had not
  /// produced a bug - `_countClick` compares a down to a down.
  ///
  /// `GetMessageTime` is the OS's own stamp for the message being dispatched,
  /// in milliseconds since the system started. It moves forward with the
  /// system clock frozen, and it is the same value for every event derived
  /// from one message. It is a 32-bit signed count, so it wraps every ~24.8
  /// days of uptime; a consumer that subtracts two of them across the wrap sees
  /// a negative interval, which is precisely the case `_countClick` already
  /// guards with `since >= Duration.zero`.
  Duration _eventTimestamp() => Duration(milliseconds: _api.getMessageTime());

  int _onKeyDown(int wParam, int lParam) {
    _emit(
      KeyDownEvent(
        windowId: id,
        generation: _generation.current,
        timestamp: _eventTimestamp(),
        physicalKey: (lParam >> 16) & 0xFF,
        logicalKey: wParam,
        modifiers: _modifiers(),
        isRepeat: ((lParam >> 30) & 1) != 0,
        location: _keyLocation(wParam, lParam),
      ),
    );
    return 0;
  }

  int _onKeyUp(int wParam, int lParam) {
    _emit(
      KeyUpEvent(
        windowId: id,
        generation: _generation.current,
        timestamp: _eventTimestamp(),
        physicalKey: (lParam >> 16) & 0xFF,
        logicalKey: wParam,
        modifiers: _modifiers(),
        location: _keyLocation(wParam, lParam),
      ),
    );
    return 0;
  }

  /// Holds a high surrogate between the two WM_CHAR messages that make up one
  /// astral character. See [TextInputAssembler] for both rules it applies.
  final TextInputAssembler _textAssembler = TextInputAssembler();

  /// `WM_CHAR`: the text the keyboard layout produced, and the only place this
  /// backend gets text from.
  ///
  /// Windows has already applied the layout, Shift, CapsLock, NumLock, AltGr
  /// and any pending dead key by the time this arrives, which is precisely
  /// what no amount of virtual-key arithmetic can reproduce. `wParam` is one
  /// UTF-16 code unit, so an emoji arrives as two messages and is emitted as
  /// one event; a control character - Backspace, Tab, Enter, Escape,
  /// Ctrl+letter - is not text and is emitted as nothing, because it reached
  /// the framework already, as a [KeyDownEvent].
  int _onChar(int wParam) {
    final String? text = _textAssembler.accept(wParam & 0xFFFF);
    if (text == null) return 0;
    _emit(
      TextInputEvent(
        windowId: id,
        generation: _generation.current,
        timestamp: _eventTimestamp(),
        text: text,
      ),
    );
    return 0;
  }

  /// Which physical key produced [virtualKey], for the keys that exist twice.
  ///
  /// Two of the three rules Windows uses are *not* the extended-key flag, and
  /// writing all three as if they were is how this ended up with a branch that
  /// could never be taken:
  ///
  ///   * **Ctrl and Alt** really are told apart by the extended flag: right
  ///     Ctrl and right Alt (which is AltGr on most layouts) are extended keys.
  ///   * **Shift is not.** Windows never sets the extended flag for `VK_SHIFT`;
  ///     the two Shifts differ by *scan code*, 0x2A on the left and 0x36 on the
  ///     right. Asking the flag therefore reported every Shift as left, and
  ///     `KeyLocation.right` for Shift was unreachable.
  ///   * **The numeric keypad is not either.** The flag marks AltGr, right
  ///     Ctrl, the grey arrow/navigation cluster, NumLock, keypad Divide and
  ///     keypad Enter - and it is deliberately *clear* for `VK_NUMPAD0` -
  ///     `VK_NUMPAD9`, because those virtual keys already say "keypad" by
  ///     existing. Requiring the flag as well made `KeyLocation.numpad` dead
  ///     code: no key in the range can ever satisfy both halves.
  ///
  /// So the keypad is the whole `VK_NUMPAD0`..`VK_DIVIDE` block, unconditional,
  /// plus the one keypad key that shares a virtual key with a standard one -
  /// Enter, which is `VK_RETURN` with the extended flag set.
  KeyLocation _keyLocation(int virtualKey, int lParam) {
    final extended = ((lParam >> 24) & 1) != 0;
    final scanCode = (lParam >> 16) & 0xFF;
    if (virtualKey == vkShift) {
      return scanCode == scanCodeRightShift
          ? KeyLocation.right
          : KeyLocation.left;
    }
    if (virtualKey == vkControl || virtualKey == vkMenu) {
      return extended ? KeyLocation.right : KeyLocation.left;
    }
    if (virtualKey >= vkNumpad0 && virtualKey <= vkDivide) {
      return KeyLocation.numpad;
    }
    if (virtualKey == vkReturn && extended) return KeyLocation.numpad;
    return KeyLocation.standard;
  }

  Set<KeyModifier> _modifiers() {
    int state(int key) => _api.getKeyState(key);
    final modifiers = <KeyModifier>{};
    if ((state(vkShift) & 0x8000) != 0) modifiers.add(KeyModifier.shift);
    if ((state(vkControl) & 0x8000) != 0) modifiers.add(KeyModifier.control);
    if ((state(vkMenu) & 0x8000) != 0) modifiers.add(KeyModifier.alt);
    if ((state(vkLwin) & 0x8000) != 0 || (state(vkRwin) & 0x8000) != 0) {
      modifiers.add(KeyModifier.meta);
    }
    if ((state(vkCapital) & 1) != 0) modifiers.add(KeyModifier.capsLock);
    if ((state(vkNumlock) & 1) != 0) modifiers.add(KeyModifier.numLock);
    if ((state(vkScroll) & 1) != 0) modifiers.add(KeyModifier.scrollLock);
    return modifiers;
  }

  int _onPaint(int hwnd) {
    _withScratchRect((rect) {
      final hasUpdate = _api.getUpdateRect(hwnd, rect, 0) != 0;
      final dirty = hasUpdate
          ? _space.physicalRectToLogical(
              rect.ref.left,
              rect.ref.top,
              rect.ref.right,
              rect.ref.bottom,
            )
          : null;
      // Validate before reporting, not after: presenting is asynchronous, and
      // an update region left dirty makes Windows resend WM_PAINT immediately,
      // which turns pumpEvents into a spin.
      _api.validateRect(hwnd, nullptr);
      _emit(
        WindowExposedEvent(
          windowId: id,
          generation: _generation.current,
          dirtyRect: dirty,
        ),
      );
    });
    return 0;
  }

  int _onSize(int wParam, int lParam) {
    if (wParam == sizeMinimized) {
      // A minimised window reports a 0x0 client area. Resizing surfaces to
      // nothing and back is pure churn, so the size is left alone and only the
      // state changes.
      _state = WindowState.minimised;
      return 0;
    }
    _state =
        wParam == sizeMaximized ? WindowState.maximised : WindowState.normal;

    final width = win32LoWord(lParam);
    final height = win32HiWord(lParam);
    if (width == _pixelWidth && height == _pixelHeight) return 0;

    _pixelWidth = width;
    _pixelHeight = height;
    // The surfaces are about to be freed, so everything stamped with the old
    // generation is now stale by definition.
    _generation.invalidate();
    _rebuildSurface();
    _emit(
      WindowResizedEvent(
        windowId: id,
        generation: _generation.current,
        clientSize: clientSize,
        renderScale: renderScale,
      ),
    );
    // A frame, or failing that a colour. The window has just grown and there
    // is a strip of it that no framebuffer has ever covered; something has to
    // put pixels there before the user sees it, and this handler is the last
    // code that runs before they do.
    if (!_drawLiveResizeFrame()) _paintExposedRegion();
    return 0;
  }

  /// Produces one whole frame, synchronously, from inside this handler.
  ///
  /// The event emitted just above will not be delivered until the Dart event
  /// loop runs again, and during a border drag it does not run again until the
  /// drag ends: `DispatchMessageW` is inside the OS's modal loop and the
  /// isolate is inside `DispatchMessageW`. Anything that goes through the
  /// stream is therefore *queued*, and the window shows stale pixels - or, in
  /// the strip it has just grown into, none at all - for the whole drag.
  ///
  /// This is the one path that does not go through the queue. It is only taken
  /// while the modal loop is actually running ([_inSizeMove]), because outside
  /// it the ordinary asynchronous path works and is cheaper: a synchronous
  /// frame is a build, a layout, a paint and a present on the mouse's thread,
  /// with no chance to coalesce two resize messages into one frame.
  ///
  /// Returns whether a frame was actually drawn, because the caller's fallback
  /// depends on it: the strip is filled with a flat colour exactly when no
  /// frame is going to cover it, and filling it first and then drawing over it
  /// would be a flat-colour flash under every frame of the drag.
  bool _drawLiveResizeFrame() {
    final callback = _liveResizeCallback;
    if (callback == null || !_inSizeMove) return false;
    if (_destroyed || isDisposed || _hwnd == 0) return false;
    if (_pixelWidth <= 0 || _pixelHeight <= 0) return false;
    if (_inLiveFrame) {
      // Re-entered: a frame is already on the stack and something inside it
      // resized the window again. Starting a second one is the reentrancy that
      // `ManualDispatcher` throws on, and throwing here would cross the FFI
      // boundary; the message that was refused is counted instead, and the
      // resize it carried is already in `_pixelWidth` for the outer frame to
      // finish against.
      _liveResizeFramesSuppressed++;
      return false;
    }
    _inLiveFrame = true;
    try {
      _liveResizeFrames++;
      callback(logicalSize: clientSize, renderScale: renderScale);
      // "Drew" means "covered the strip", which is what the caller is asking.
      // A frame that was rejected on generation left the strip untouched, and
      // the flat colour is then better than what is there.
      return _paintedWidth >= _pixelWidth && _paintedHeight >= _pixelHeight;
    } finally {
      _inLiveFrame = false;
    }
  }

  /// `WM_GETMINMAXINFO`: the only chance to bound a drag *before* it happens.
  ///
  /// Windows fills the structure with its own defaults and then asks; whatever
  /// is in it when the handler returns 0 is what the user is allowed to drag
  /// to. Only the two track sizes are touched, so every default that was not
  /// configured survives - a window with a minimum but no maximum still
  /// maximises to the work area.
  ///
  /// The sizes cross this boundary as logical client sizes and have to leave it
  /// as physical *window* sizes, which is two conversions and not one: the
  /// scale, and then the frame. `AdjustWindowRectExForDpi` is what supplies the
  /// second, the same call [_applyClientBounds] uses, so a minimum of 320x240
  /// means 320x240 of client area at any DPI rather than 320x240 minus a
  /// caption.
  int _onGetMinMaxInfo(int lParam) {
    final minimum = _minimumSize;
    final maximum = _maximumSize;
    if (lParam == 0 || (minimum == null && maximum == null)) return 0;
    final info = Pointer<MinMaxInfo>.fromAddress(lParam);
    if (minimum != null) {
      final frame = _windowSizeForClient(minimum);
      info.ref.ptMinTrackSize
        ..x = frame.width
        ..y = frame.height;
    }
    if (maximum != null) {
      final frame = _windowSizeForClient(maximum);
      info.ref.ptMaxTrackSize
        ..x = frame.width
        ..y = frame.height;
    }
    return 0;
  }

  /// A logical client size as the physical window size that contains it.
  ({int width, int height}) _windowSizeForClient(Size logical) {
    final pixels = _space.logicalSizeToPhysical(logical);
    var width = pixels.width;
    var height = pixels.height;
    _withScratchRect((rect) {
      rect.ref
        ..left = 0
        ..top = 0
        ..right = pixels.width
        ..bottom = pixels.height;
      if (_api.adjustWindowRect(rect, _style, _exStyle, _dpi) == 0) return;
      width = rect.ref.right - rect.ref.left;
      height = rect.ref.bottom - rect.ref.top;
    });
    return (width: width, height: height);
  }

  /// `WM_ERASEBKGND`, and the reason the answer is no longer a bare `return 1`.
  ///
  /// Returning 1 means "the background is erased, do not touch it". Together
  /// with `hbrBackground = 0` on the class that used to mean *nobody* painted
  /// the background, which is right for every pixel the framebuffer covers and
  /// wrong for every pixel it does not. During a drag of the bottom-right
  /// corner the window grows first and the frame follows, so there is a strip
  /// of client area that no framebuffer has ever covered, and what Windows
  /// leaves there is uninitialised - black, in practice. That is the bug the
  /// user reported.
  ///
  /// The fix is not a class brush. A class brush would have `DefWindowProcW`
  /// paint the *whole* update region, which after a resize is the whole client
  /// area, so every frame would be preceded by a full-window flash of flat
  /// colour - which is exactly what the class comment refuses and what the
  /// existing test pins. So the erase stays ours, and it paints only what is
  /// outside [_paintedWidth] x [_paintedHeight]: the strip nothing has drawn
  /// into. Where the framebuffer has already been, nothing happens and there is
  /// nothing to flash.
  ///
  /// Still returns 1 in every case, including when there is no brush: the
  /// contract with `DefWindowProcW` is unchanged, only the pixels are.
  ///
  /// ### And why this is not where the fix lives
  ///
  /// It is not reached on the path that matters, and finding that out is the
  /// reason [_paintExposedRegion] exists. `WM_ERASEBKGND` is not sent by
  /// dispatching `WM_PAINT`; it is sent by **`BeginPaint`**, and [_onPaint]
  /// deliberately does not call `BeginPaint` - it reads the update rectangle
  /// and validates, because presentation here is asynchronous and does not go
  /// through the paint DC. So during a real drag this handler never runs at
  /// all, and a fix that lived only here would have been dead code that
  /// passed its own test.
  ///
  /// It is still handled, because the paths that *do* send it are real -
  /// `RedrawWindow` with `RDW_ERASE | RDW_ERASENOW`, `ScrollWindow`, and any
  /// future return to `BeginPaint` - and because answering 0 would hand the
  /// erase to `DefWindowProcW`, which is what the class comment refuses.
  int _onEraseBackground(int hdc) {
    if (hdc != 0) _fillExposedRegion(hdc);
    return 1;
  }

  /// Paints the strip a resize just exposed, immediately, at the moment it is
  /// exposed.
  ///
  /// This is the reachable half of the pair. `WM_SIZE` is the last code of ours
  /// that runs before the user sees the bigger window - inside the modal loop
  /// there is nothing after it - so the colour has to go on here rather than
  /// wait for a paint message that may not be delivered for another whole
  /// gesture. See [_onEraseBackground] for why the obvious place does not work.
  void _paintExposedRegion() {
    if (_backgroundBrush == 0 || _hwnd == 0 || _destroyed) return;
    if (_paintedWidth >= _pixelWidth && _paintedHeight >= _pixelHeight) return;
    final hdc = _api.getDC(_hwnd);
    if (hdc == 0) return;
    try {
      _fillExposedRegion(hdc);
    } finally {
      _api.releaseDC(_hwnd, hdc);
    }
  }

  /// Fills the client area outside [_paintedWidth] x [_paintedHeight] on [hdc].
  ///
  /// Two rectangles rather than one, and never the whole client area: the part
  /// a framebuffer has already covered keeps its pixels. Painting all of it
  /// would be the full-window flash of flat colour that `hbrBackground = 0`
  /// exists to prevent - the window would blink to grey on every message of a
  /// drag instead of only growing into it.
  void _fillExposedRegion(int hdc) {
    final brush = _backgroundBrush;
    if (brush == 0) return;
    final width = _pixelWidth;
    final height = _pixelHeight;
    final painted = _paintedWidth;
    final paintedHeight = _paintedHeight;
    if (painted >= width && paintedHeight >= height) return;
    _backgroundFills++;
    _withScratchRect((rect) {
      if (painted < width) {
        rect.ref
          ..left = painted
          ..top = 0
          ..right = width
          ..bottom = height;
        _api.fillRect(hdc, rect, brush);
      }
      if (paintedHeight < height) {
        rect.ref
          ..left = 0
          ..top = paintedHeight
          ..right = painted < width ? painted : width
          ..bottom = height;
        _api.fillRect(hdc, rect, brush);
      }
    });
  }

  /// A full-surface present landed: the client area is covered out to
  /// [width] x [height] and [_onEraseBackground] has that much less to do.
  void _notePresented(int width, int height) {
    _paintedWidth = width;
    _paintedHeight = height;
  }

  int _onMove(int lParam) {
    _clientOriginX = win32SignedLoWord(lParam);
    _clientOriginY = win32SignedHiWord(lParam);
    _emit(
      WindowMovedEvent(
        windowId: id,
        generation: _generation.current,
        screenPosition: _space.logicalOrigin,
      ),
    );
    return 0;
  }

  int _onDpiChanged(int wParam, int lParam) {
    final dpi = win32LoWord(wParam);
    if (dpi <= 0 || _hwnd == 0) return 0;

    // Copy the suggested rectangle out before anything else runs: lParam
    // points into memory the OS owns for the duration of this message only.
    final suggested = Pointer<Win32Rect>.fromAddress(lParam);
    final left = suggested.ref.left;
    final top = suggested.ref.top;
    final width = suggested.ref.right - left;
    final height = suggested.ref.bottom - top;

    _dpi = dpi;
    _desktopDpi = _api.systemDpi();

    final before = _generation.current;
    // Accepting the suggested rectangle is what keeps the window the same
    // physical size on the new monitor; ignoring it makes a window jump size
    // when it crosses a DPI boundary.
    final moved = _api.setWindowPos(
      _hwnd,
      0,
      left,
      top,
      width,
      height,
      swpNozorder | swpNoactivate,
    );
    if (moved == 0) {
      _record(win32CallFailed(
        'SetWindowPos',
        _api.getLastError(),
        context: 'WM_DPICHANGED to $dpi dpi',
      ));
    }
    if (_generation.current == before) {
      // No WM_SIZE followed - same pixel size, new scale. The surfaces are
      // still the wrong resolution for the new scale, so invalidate anyway.
      _generation.invalidate();
      _rebuildSurface();
    }
    _emit(
      WindowScaleChangedEvent(
        windowId: id,
        generation: _generation.current,
        renderScale: renderScale,
        desktopScale: desktopScale,
      ),
    );
    return 0;
  }

  void _onDestroy() {
    _destroyed = true;
    _releaseSurface();
    _emit(
      WindowClosedEvent(windowId: id, generation: _generation.current),
    );
    _onClosed(this);
    // The HWND is gone, so everything else this object owns is dead weight -
    // and the backend has just forgotten the window, so nothing else would
    // ever release it. Disposing here also covers the user pressing Alt+F4 on
    // a window the application never explicitly closed. Idempotent, so the
    // dispose() that got us here (if that is the path) does not recurse.
    dispose();
  }

  void _onNcDestroy() {
    // Last message this HWND will ever receive: the token must go now, or a
    // recycled HWND could resolve to a dead window.
    Win32WindowRegistry.detach(_token);
    _hwnd = 0;
  }

  // ---------------------------------------------------------------------------
  // Surfaces
  // ---------------------------------------------------------------------------

  void _ensureSurface() {
    if (_surface != null || _destroyed || isDisposed) return;
    if (_pixelWidth <= 0 || _pixelHeight <= 0) {
      _readClientSize();
    }
    _rebuildSurface();
  }

  void _readClientSize() {
    if (_hwnd == 0) return;
    _withScratchRect((rect) {
      if (_api.getClientRect(_hwnd, rect) == 0) {
        _record(win32CallFailed('GetClientRect', _api.getLastError()));
        return;
      }
      _pixelWidth = rect.ref.right - rect.ref.left;
      _pixelHeight = rect.ref.bottom - rect.ref.top;
    });
  }

  void _rebuildSurface() {
    _releaseSurface();
    if (_destroyed || isDisposed || _hwnd == 0) return;
    if (_pixelWidth <= 0 || _pixelHeight <= 0) return;
    try {
      _surface = Win32DibSurface.create(
        api: _api,
        hwnd: _hwnd,
        pixelWidth: _pixelWidth,
        pixelHeight: _pixelHeight,
        scale: renderScale,
        generation: _generation.current,
        onFullPresent: _notePresented,
      );
    } on Win32Failure catch (failure) {
      // A failed surface is not a failed window: the window still exists and
      // can be resized back to a size GDI will accept.
      _record(failure.diagnostic);
    }
  }

  void _releaseSurface() {
    _surface?.dispose();
    _surface = null;
  }

  /// Presents the CPU surface, optionally only [damage] (logical units).
  ///
  /// Returns the diagnostic for the call that failed, or null. Convenience
  /// over [dibSurface] so the common case does not have to null-check twice.
  BackendDiagnostic? present({Rect? damage}) {
    final surface = _surface;
    if (surface == null) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'no CPU surface to present',
        detail: 'the window is minimised or has a zero-sized client area',
      );
    }
    final failure = surface.present(damage: damage);
    if (failure != null) _record(failure);
    return failure;
  }

  // ---------------------------------------------------------------------------
  // Geometry
  // ---------------------------------------------------------------------------

  /// Moves and resizes so the *client area* matches what was asked for.
  ///
  /// Callers think in client rectangles - that is where their pixels go - and
  /// the frame is a platform detail, so the frame is computed here with
  /// `AdjustWindowRectExForDpi` rather than left for the caller to guess at.
  BackendDiagnostic? _applyClientBounds({
    Size? logicalSize,
    Offset? logicalPosition,
  }) {
    if (_hwnd == 0) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'SetWindowPos skipped: the window has no handle',
      );
    }
    final space = _space;
    var flags = swpNozorder | swpNoactivate | swpNoownerzorder;
    var x = 0;
    var y = 0;
    var width = 0;
    var height = 0;

    BackendDiagnostic? failure;
    _withScratchRect((rect) {
      final pixels = logicalSize == null
          ? (width: _pixelWidth, height: _pixelHeight)
          : space.logicalSizeToPhysical(logicalSize);
      rect.ref
        ..left = 0
        ..top = 0
        ..right = pixels.width
        ..bottom = pixels.height;
      if (_api.adjustWindowRect(rect, _style, _exStyle, _dpi) == 0) {
        failure = win32CallFailed(
          'AdjustWindowRectExForDpi',
          _api.getLastError(),
          context: '${pixels.width}x${pixels.height} at $_dpi dpi',
        );
        return;
      }
      width = rect.ref.right - rect.ref.left;
      height = rect.ref.bottom - rect.ref.top;
      if (logicalPosition == null) {
        flags |= swpNomove;
      } else {
        // rect.left is the (negative) distance from the frame to the client
        // area, so adding it turns a client position into a window position.
        x = space.logicalToPhysical(logicalPosition.dx) + rect.ref.left;
        y = space.logicalToPhysical(logicalPosition.dy) + rect.ref.top;
      }
      if (logicalSize == null) flags |= swpNosize;
    });
    if (failure != null) return failure;

    if (_api.setWindowPos(_hwnd, 0, x, y, width, height, flags) == 0) {
      return win32CallFailed(
        'SetWindowPos',
        _api.getLastError(),
        context: '${width}x$height at ($x, $y)',
      );
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Scratch memory
  // ---------------------------------------------------------------------------

  /// Runs [body] with a RECT, reusing the per-window scratch block.
  ///
  /// The busy flag is not paranoia: WM_DPICHANGED calls `SetWindowPos`, which
  /// sends WM_SIZE synchronously, so a handler really can re-enter another
  /// handler on the same window. Reusing the scratch block in that case would
  /// have the inner call overwrite the outer one's rectangle.
  T _withScratchRect<T>(T Function(Pointer<Win32Rect> rect) body) {
    if (_scratchRectBusy) {
      final temporary = _api.allocator<Win32Rect>();
      try {
        return body(temporary);
      } finally {
        _api.allocator.free(temporary);
      }
    }
    _scratchRectBusy = true;
    try {
      return body(_scratchRect);
    } finally {
      _scratchRectBusy = false;
    }
  }

  T _withScratchPoint<T>(T Function(Pointer<Win32Point> point) body) {
    if (_scratchPointBusy) {
      final temporary = _api.allocator<Win32Point>();
      try {
        return body(temporary);
      } finally {
        _api.allocator.free(temporary);
      }
    }
    _scratchPointBusy = true;
    try {
      return body(_scratchPoint);
    } finally {
      _scratchPointBusy = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Teardown
  // ---------------------------------------------------------------------------

  void _destroyHandle() {
    final handle = _hwnd;
    if (handle == 0 || _destroyed) return;
    if (_api.destroyWindow(handle) == 0) {
      _record(win32CallFailed(
        'DestroyWindow',
        _api.getLastError(),
        context: 'window 0x${handle.toRadixString(16)}',
      ));
    }
  }

  @override
  void onDispose() {
    _resources.dispose();
    _releaseSurface();
  }

  void _emit(PlatformWindowEvent event) {
    if (_events.isClosed) return;
    _events.add(event);
  }

  /// Records a non-fatal failure. Bounded so a per-frame failure cannot grow
  /// without limit.
  void _record(BackendDiagnostic diagnostic) {
    if (_diagnostics.length >= 64) _diagnostics.removeAt(0);
    _diagnostics.add(diagnostic);
  }

  @override
  String toString() => 'Win32Window(id: ${id.value}, '
      'hwnd: 0x${_hwnd.toRadixString(16)}, '
      '${_pixelWidth}x${_pixelHeight}px @ $renderScale)';
}
