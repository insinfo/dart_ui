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
///   * **Minimum and maximum sizes.** WM_GETMINMAXINFO is unhandled, so the
///     platform defaults apply.
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
import 'win32_api.dart';
import 'win32_constants.dart';
import 'win32_coordinates.dart';
import 'win32_diagnostics.dart';
import 'win32_dib_surface.dart';
import 'win32_structs.dart';
import 'win32_window_class.dart';

/// A Win32 window.
///
/// Sizes crossing this boundary are logical; sizes below it are physical
/// pixels. The conversion happens once, in [Win32CoordinateSpace], and the
/// fields are named `_pixelWidth` / `clientSize` so that a mix-up reads wrong.
final class Win32Window with DisposableMixin implements NativeWindow {
  Win32Window._({
    required Win32Api api,
    required Win32WindowClass windowClass,
    required void Function(Win32Window window) onClosed,
    required void Function() onSessionEnding,
    required int dpi,
    required int style,
    required int exStyle,
  })  : _api = api,
        _class = windowClass,
        _onClosed = onClosed,
        _onSessionEnding = onSessionEnding,
        _dpi = dpi,
        _style = style,
        _exStyle = exStyle {
    _desktopDpi = api.systemDpi();
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
  }

  /// Creates the window, or throws [Win32Failure] naming the call that failed.
  static Win32Window create({
    required Win32Api api,
    required Win32WindowClass windowClass,
    required WindowOptions options,
    required void Function(Win32Window window) onClosed,
    required void Function() onSessionEnding,
  }) {
    var style = options.decorated ? wsOverlappedWindow : wsPopup;
    if (!options.resizable) {
      // A non-resizable window keeps its caption and buttons but loses the
      // sizing border, which is what "not resizable" means to a user.
      style &= ~(wsThickframe | wsMaximizebox);
    }
    const exStyle = wsExAppwindow;

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
        0,
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
    _api.showWindow(_hwnd, swShowNormal);
    _api.updateWindow(_hwnd);
  }

  @override
  void hide() {
    if (_hwnd == 0) return;
    _api.showWindow(_hwnd, swHide);
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
        // Claim the erase so Windows does not paint the background between the
        // erase and the present, which is what makes a resize flicker.
        return 1;

      case wmPaint:
        return _onPaint(hwnd);

      case wmSize:
        return _onSize(wParam, lParam);

      case wmMove:
        return _onMove(lParam);

      case wmDpichanged:
        return _onDpiChanged(wParam, lParam);

      case wmActivate:
        _emit(
          WindowActivationEvent(
            windowId: id,
            generation: _generation.current,
            activation: win32LoWord(wParam) == waInactive
                ? WindowActivation.deactivated
                : WindowActivation.activated,
          ),
        );
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

      case wmMousewheel:
        return _onPointerScroll(wParam, lParam);

      case wmMouseleave:
        return _onPointerLeave();

      case wmCapturechanged:
        return _onCaptureLost();

      case wmKeydown:
      case wmSyskeydown:
        return _onKeyDown(wParam, lParam);

      case wmKeyup:
      case wmSyskeyup:
        return _onKeyUp(wParam, lParam);

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
        timestamp:
            Duration(milliseconds: DateTime.now().millisecondsSinceEpoch),
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: _lastPointerPosition,
      ),
    );
    return 0;
  }

  /// Buttons currently held down, so capture is released exactly once - when
  /// the last of them comes up rather than when the first does.
  final Set<PointerButton> _heldButtons = <PointerButton>{};

  int _onPointerDown(PointerButton button, int lParam) {
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
        timestamp:
            Duration(milliseconds: DateTime.now().millisecondsSinceEpoch),
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
        timestamp:
            Duration(milliseconds: DateTime.now().millisecondsSinceEpoch),
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
        timestamp:
            Duration(milliseconds: DateTime.now().millisecondsSinceEpoch),
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

  int _onPointerScroll(int wParam, int lParam) {
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
    final delta = win32SignedHiWord(wParam) / 120.0;
    final position = _space.physicalToLogical(x, y);
    _emit(
      PointerScrollEvent(
        windowId: id,
        generation: _generation.current,
        timestamp: _eventTimestamp(),
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: position,
        scrollDelta:
            (wParam & mkShift) != 0 ? Offset(delta, 0) : Offset(0, delta),
        scrollDeltaUnit: ScrollDeltaUnit.lines,
      ),
    );
    return 0;
  }

  Duration _eventTimestamp() =>
      Duration(microseconds: DateTime.now().microsecondsSinceEpoch);

  int _onKeyDown(int wParam, int lParam) {
    _emit(
      KeyDownEvent(
        windowId: id,
        generation: _generation.current,
        timestamp:
            Duration(milliseconds: DateTime.now().millisecondsSinceEpoch),
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
        timestamp:
            Duration(milliseconds: DateTime.now().millisecondsSinceEpoch),
        physicalKey: (lParam >> 16) & 0xFF,
        logicalKey: wParam,
        modifiers: _modifiers(),
        location: _keyLocation(wParam, lParam),
      ),
    );
    return 0;
  }

  KeyLocation _keyLocation(int virtualKey, int lParam) {
    final extended = ((lParam >> 24) & 1) != 0;
    if (virtualKey == 0x10) {
      return extended ? KeyLocation.right : KeyLocation.left;
    }
    if (virtualKey == 0x11) {
      return extended ? KeyLocation.right : KeyLocation.left;
    }
    if (virtualKey == 0x12) {
      return extended ? KeyLocation.right : KeyLocation.left;
    }
    if (extended && virtualKey >= 0x60 && virtualKey <= 0x69) {
      return KeyLocation.numpad;
    }
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
    return 0;
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
