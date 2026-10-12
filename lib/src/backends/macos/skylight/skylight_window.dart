/// A [NativeWindow] made directly with the WindowServer through SkyLight.
///
/// No AppKit, so no title bar, no shadow-casting frame and no system move or
/// resize: the window is a bare rectangle. The framework draws the bar
/// ([ClientDecoratedWindow], the same `ClientDecorationFrame` a Wayland
/// window without server decorations gets), and moving and resizing are done
/// here by following the drag that started on it - nobody else would.
library;

import 'dart:async';

import '../../../foundation/diagnostics.dart';
import '../../../foundation/lifecycle.dart';
import '../../../foundation/value_notifier.dart';
import '../../../geometry/offset.dart';
import '../../../geometry/rect.dart';
import '../../../geometry/size.dart';
import '../../../platform/input_events.dart';
import '../../../platform/native_window.dart';
import '../../../platform/window_events.dart';
import '../../../rendering/framebuffer.dart';
import '../../../rendering/renderer.dart';
import '../macos_cpu_window.dart';
import '../macos_event_translation.dart';
import 'skylight_dock.dart';
import 'skylight_session.dart';

/// The CPU surface of one [SkylightWindow] at one size.
final class SkylightCpuSurface implements MacosCpuSurface {
  SkylightCpuSurface._(
      this._window, this.generation, this.framebuffer, this.scale);

  final SkylightWindow _window;

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

enum _DragMode { move, resize }

/// One SkyLight window.
final class SkylightWindow
    with DisposableMixin
    implements
        NativeWindow,
        MacosCpuWindow,
        ClientDecoratedWindow,
        WindowStateControl,
        ActivatableWindow {
  SkylightWindow._({
    required SkylightSession session,
    required SkylightNativeWindow native,
    required NativeWindowId id,
    required String title,
    required bool decorated,
    required void Function(SkylightWindow window) onClosed,
    required void Function(SkylightWindow window) onActivate,
  })  : _session = session,
        _native = native,
        _id = id,
        _title = title,
        _onClosed = onClosed,
        _onActivate = onActivate,
        clientDecorations = ValueNotifier<bool>(decorated) {
    _rebuildSurface();
  }

  /// Creates and shows a window for [options] at the display's scale.
  static SkylightWindow create({
    required SkylightSession session,
    required NativeWindowId id,
    required WindowOptions options,
    required void Function(SkylightWindow window) onClosed,
    required void Function(SkylightWindow window) onActivate,
  }) {
    final SkylightNativeWindow native = session.createWindow(
      width: options.size.width.round(),
      height: options.size.height.round(),
      x: options.position?.dx,
      y: options.position?.dy,
    );
    final SkylightWindow window = SkylightWindow._(
      session: session,
      native: native,
      id: id,
      title: options.title,
      // A menu or tooltip has no bar; neither has an undecorated window.
      decorated: options.decorated && options.kind.takesActivation,
      onClosed: onClosed,
      onActivate: onActivate,
    );
    if (options.visible) window.show();
    return window;
  }

  final SkylightSession _session;
  final SkylightNativeWindow _native;
  final NativeWindowId _id;
  final void Function(SkylightWindow window) _onClosed;
  final void Function(SkylightWindow window) _onActivate;
  final GenerationToken _generation = GenerationToken();
  final StreamController<PlatformWindowEvent> _events =
      StreamController<PlatformWindowEvent>.broadcast();
  final List<BackendDiagnostic> _diagnostics = <BackendDiagnostic>[];
  SkylightCpuSurface? _surface;
  String _title;
  bool _visible = false;
  bool _closedEmitted = false;
  WindowState _state = WindowState.normal;
  WindowState _stateBeforeMinimize = WindowState.normal;

  /// Whether the window has left the screen since it was sent to the Dock:
  /// it stays ordered in through the minimise effect, which is not a
  /// restore.
  bool _leftScreen = false;
  Rect? _restoreBounds;

  /// The SkyLight window id, the one `screencapture -l` takes.
  int get windowNumber => _native.id;

  /// Whether the WindowServer has the window on screen - false while it is
  /// in the Dock.
  bool get isOnScreen => !isDisposed && _session.isOrderedIn(_native);

  List<BackendDiagnostic> get diagnostics =>
      List<BackendDiagnostic>.unmodifiable(_diagnostics);

  // -------------------------------------------------------------------------
  // NativeWindow
  // -------------------------------------------------------------------------

  @override
  NativeWindowId get id => _id;

  @override
  int get generation => _generation.current;

  @override
  Size get clientSize =>
      Size(_native.width.toDouble(), _native.height.toDouble());

  @override
  double get renderScale => _session.mainDisplayScale;

  @override
  double get desktopScale => _session.mainDisplayScale;

  @override
  WindowState get state => _state;

  @override
  List<NativeSurfaceDescriptor> get surfaces {
    final SkylightCpuSurface? surface = _surface;
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
    _session.order(_native, visible: true);
    _visible = true;
    // The first frame: nothing else will ask for one.
    scheduleMicrotask(() => requestRedraw());
  }

  @override
  void hide() {
    if (isDisposed || !_visible) return;
    _session.order(_native, visible: false);
    _visible = false;
  }

  @override
  void close() => dispose();

  @override
  void setTitle(String value) => _title = value;

  @override
  void setBounds(Rect bounds) {
    if (isDisposed) return;
    _session.move(_native, bounds.left, bounds.top);
    _resizeTo(bounds.width.round(), bounds.height.round());
  }

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

  @override
  Offset screenToClient(Offset screenPosition) =>
      screenPosition - Offset(_native.x, _native.y);

  @override
  Offset clientToScreen(Offset clientPosition) =>
      clientPosition + Offset(_native.x, _native.y);

  // -------------------------------------------------------------------------
  // Activation, state, decorations
  // -------------------------------------------------------------------------

  @override
  void activate() {
    if (!isDisposed) _onActivate(this);
  }

  bool _active = false;

  /// Called by the backend when the keyboard moves to or from this window.
  void setActive(bool active) {
    if (active == _active || isDisposed) return;
    _active = active;
    _emit(WindowActivationEvent(
      windowId: _id,
      generation: _generation.current,
      activation:
          active ? WindowActivation.activated : WindowActivation.deactivated,
    ));
  }

  @override
  final ValueNotifier<bool> clientDecorations;

  @override
  String get title => _title;

  _DragMode? _drag;
  WindowResizeEdge? _dragEdge;
  Offset _dragStartPointer = Offset.zero;
  Rect _dragStartBounds = Rect.zero;
  Offset _lastScreenPointer = Offset.zero;

  /// Where the last press went down, in global points: a move started by a
  /// drag that began there keeps that point under the pointer, rather than
  /// the point the gesture recognised the drag at, a few points later.
  Offset _lastPressScreen = Offset.zero;

  Rect get _bounds => Rect.fromLTWH(_native.x, _native.y,
      _native.width.toDouble(), _native.height.toDouble());

  @override
  bool beginMove() => _beginDrag(_DragMode.move, null);

  @override
  bool beginResize(WindowResizeEdge edge) => _beginDrag(_DragMode.resize, edge);

  bool _beginDrag(_DragMode mode, WindowResizeEdge? edge) {
    if (isDisposed || _state == WindowState.maximised) return false;
    _drag = mode;
    _dragEdge = edge;
    _dragStartPointer = _lastPressScreen;
    _dragStartBounds = _bounds;
    // From here the drag is ours, not the widget's that asked for it.
    _emit(PointerCancelEvent(
      windowId: _id,
      generation: _generation.current,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: screenToClient(_lastScreenPointer),
    ));
    return true;
  }

  void _followDrag(Offset screen) {
    final Offset delta = screen - _dragStartPointer;
    final Rect start = _dragStartBounds;
    if (_drag == _DragMode.move) {
      _session.move(_native, start.left + delta.dx, start.top + delta.dy);
      return;
    }
    const double minimum = 120;
    double left = start.left, top = start.top;
    double right = start.right, bottom = start.bottom;
    final WindowResizeEdge edge = _dragEdge!;
    if (edge == WindowResizeEdge.left ||
        edge == WindowResizeEdge.topLeft ||
        edge == WindowResizeEdge.bottomLeft) {
      left = (start.left + delta.dx)
          .clamp(double.negativeInfinity, right - minimum);
    }
    if (edge == WindowResizeEdge.right ||
        edge == WindowResizeEdge.topRight ||
        edge == WindowResizeEdge.bottomRight) {
      right = (start.right + delta.dx).clamp(left + minimum, double.infinity);
    }
    if (edge == WindowResizeEdge.top ||
        edge == WindowResizeEdge.topLeft ||
        edge == WindowResizeEdge.topRight) {
      top = (start.top + delta.dy)
          .clamp(double.negativeInfinity, bottom - minimum);
    }
    if (edge == WindowResizeEdge.bottom ||
        edge == WindowResizeEdge.bottomLeft ||
        edge == WindowResizeEdge.bottomRight) {
      bottom = (start.bottom + delta.dy).clamp(top + minimum, double.infinity);
    }
    setBounds(Rect.fromLTRB(left, top, right, bottom));
  }

  @override
  bool showWindowMenu(Offset position) => false;

  /// Only with a Dock tile: a minimised window is one the Dock can bring
  /// back, and without the tile nothing could.
  @override
  bool get canMinimize => _session.dock != null;

  @override
  void minimize() => requestState(WindowState.minimised);

  @override
  void setMaximized(bool maximized) =>
      requestState(maximized ? WindowState.maximised : WindowState.normal);

  @override
  bool get isMaximized => _state == WindowState.maximised;

  @override
  void requestClose() => _emit(WindowCloseRequestedEvent(
        windowId: _id,
        generation: _generation.current,
      ));

  @override
  bool requestState(WindowState state) {
    if (isDisposed) return false;
    if (state == WindowState.minimised) {
      if (_state == WindowState.minimised) return true;
      final SkylightDock? dock = _session.dock;
      if (dock == null || !_visible) return false;
      if (!dock.minimize(_native.id, _title)) return false;
      _stateBeforeMinimize = _state;
      _leftScreen = false;
      _setState(WindowState.minimised);
      return true;
    }
    if (_state == WindowState.minimised) {
      // Back from the Dock first, into the state it left; then whatever
      // else was asked.
      if (!(_session.dock?.restore(_native.id) ?? false)) return false;
      _setState(_stateBeforeMinimize);
      if (state == WindowState.normal) return true;
    }
    switch (state) {
      case WindowState.minimised:
        return false;
      case WindowState.normal:
        final Rect? restore = _restoreBounds;
        _restoreBounds = null;
        if (restore != null) setBounds(restore);
      case WindowState.maximised || WindowState.fullscreen:
        _restoreBounds ??= _bounds;
        final display = _session.mainDisplayBounds;
        // Below the menu bar for maximised; the whole display for full
        // screen, which is what a borderless window over it is.
        final double top = state == WindowState.maximised ? 25 : 0;
        setBounds(Rect.fromLTWH(
            display.x, display.y + top, display.width, display.height - top));
    }
    _setState(state);
    return true;
  }

  /// Brings the window back from the Dock, for a click on the app's tile.
  void restoreFromDock() {
    if (_state == WindowState.minimised) requestState(WindowState.normal);
  }

  /// Notices a restore the Dock did by itself - a minimised window picked
  /// from the tile's menu is ordered back in without asking the app.
  void syncDockState() {
    if (isDisposed || _state != WindowState.minimised) return;
    final bool onScreen = _session.isOrderedIn(_native);
    if (!onScreen) {
      _leftScreen = true;
    } else if (_leftScreen) {
      _setState(_stateBeforeMinimize);
    }
  }

  void _setState(WindowState next) {
    if (next == _state) return;
    _state = next;
    _emit(WindowStateChangedEvent(
      windowId: _id,
      generation: _generation.current,
      state: next,
    ));
  }

  // -------------------------------------------------------------------------
  // Surface
  // -------------------------------------------------------------------------

  void _rebuildSurface() {
    final double scale = _session.mainDisplayScale;
    final int width = (_native.width * scale).round();
    final int height = (_native.height * scale).round();
    _surface = width <= 0 || height <= 0
        ? null
        : SkylightCpuSurface._(
            this,
            _generation.current,
            Framebuffer.allocate(width: width, height: height),
            scale,
          );
  }

  void _resizeTo(int width, int height) {
    if (width == _native.width && height == _native.height) return;
    _session.resize(_native, width, height);
    _generation.invalidate();
    _rebuildSurface();
    _emit(WindowResizedEvent(
      windowId: _id,
      generation: _generation.current,
      clientSize: clientSize,
      renderScale: renderScale,
    ));
  }

  BackendDiagnostic? _present(SkylightCpuSurface surface) {
    if (isDisposed || !identical(surface, _surface)) {
      return const BackendDiagnostic.note('stale SkyLight surface');
    }
    try {
      final Framebuffer buffer = surface.framebuffer;
      _session.present(
        _native,
        buffer.pixels,
        width: buffer.width,
        height: buffer.height,
        bytesPerRow: buffer.bytesPerRow,
      );
      return null;
    } on Object catch (error) {
      return BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'SkyLight present failed',
        detail: '$error',
      );
    }
  }

  // -------------------------------------------------------------------------
  // Input
  // -------------------------------------------------------------------------

  /// One WindowServer event routed here by the backend.
  void handleEvent(MacosRawEvent event) {
    if (isDisposed) return;
    final Offset screen = Offset(event.screenX, event.screenY);
    final bool pointerEvent =
        event.type != 10 && event.type != 11 && event.type != 12;
    if (pointerEvent) _lastScreenPointer = screen;
    if (event.type == 1 || event.type == 3 || event.type == 25) {
      _lastPressScreen = screen;
    }
    if (_drag != null) {
      switch (event.type) {
        case 5 || 6 || 7 || 27:
          _followDrag(screen);
          return;
        case 1 || 3 || 25:
          // A press while dragging means the release was missed: stop.
          _drag = null;
          _dragEdge = null;
        case 2:
          _drag = null;
          _dragEdge = null;
          return;
      }
    }
    translateMacosRawEvent(
      event,
      local: screenToClient(screen),
      windowId: _id,
      generation: _generation.current,
      emit: _emit,
    );
  }

  void _emit(PlatformWindowEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  @override
  void onDispose() {
    _surface = null;
    _generation.invalidate();
    if (_state == WindowState.minimised) _session.dock?.remove(_native.id);
    _session.release(_native);
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
