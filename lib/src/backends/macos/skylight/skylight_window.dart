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
import '../macos_input.dart';
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
  Rect? _restoreBounds;

  /// The SkyLight window id, the one `screencapture -l` takes.
  int get windowNumber => _native.id;

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

  /// No Dock to minimise into without AppKit: a minimised window would be
  /// one nothing can bring back. Refused rather than lost.
  @override
  bool get canMinimize => false;

  @override
  void minimize() {}

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
  void handleEvent(SkylightEvent event) {
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
    final Duration timestamp =
        Duration(microseconds: event.timestampNanos ~/ 1000);
    final Offset local = screenToClient(screen);
    final int generation = _generation.current;
    void pointer(PointerEvent Function() build) => _emit(build());
    switch (event.type) {
      case 1 || 3 || 25:
        final PointerButton? button = _button(event);
        if (button == null) return;
        pointer(() => PointerDownEvent(
              windowId: _id,
              generation: generation,
              timestamp: timestamp,
              pointerId: 0,
              kind: PointerKind.mouse,
              logicalPosition: local,
              button: button,
              clickCount: event.clickCount < 1 ? 1 : event.clickCount,
            ));
      case 2 || 4 || 26:
        final PointerButton? button = _button(event);
        if (button == null) return;
        pointer(() => PointerUpEvent(
              windowId: _id,
              generation: generation,
              timestamp: timestamp,
              pointerId: 0,
              kind: PointerKind.mouse,
              logicalPosition: local,
              button: button,
            ));
      case 5 || 6 || 7 || 27:
        pointer(() => PointerMoveEvent(
              windowId: _id,
              generation: generation,
              timestamp: timestamp,
              pointerId: 0,
              kind: PointerKind.mouse,
              logicalPosition: local,
            ));
      case 22:
        final bool precise = event.continuousScroll;
        final double dx =
            precise ? event.scrollPointsX : event.scrollLinesX.toDouble();
        final double dy =
            precise ? event.scrollPointsY : event.scrollLinesY.toDouble();
        if (dx == 0 && dy == 0) return;
        // The WindowServer's sign is the content's direction; the
        // framework's is the offset's, as for AppKit's deltas.
        pointer(() => PointerScrollEvent(
              windowId: _id,
              generation: generation,
              timestamp: timestamp,
              pointerId: 0,
              kind: PointerKind.mouse,
              logicalPosition: local,
              scrollDelta: Offset(-dx, -dy),
              scrollDeltaUnit:
                  precise ? ScrollDeltaUnit.pixels : ScrollDeltaUnit.lines,
            ));
      case 10 || 11:
        _emitKey(event, down: event.type == 10, timestamp: timestamp);
      case 12:
        final bool? down = _modifierDown(event);
        if (down != null) _emitKey(event, down: down, timestamp: timestamp);
    }
  }

  static PointerButton? _button(SkylightEvent event) => switch (event.type) {
        1 || 2 => PointerButton.primary,
        3 || 4 => PointerButton.secondary,
        _ => macosPointerButton(event.buttonNumber),
      };

  /// Whether a flags-changed event is its modifier going down or up, from
  /// the flag that key controls; null for a key this cannot tell.
  static bool? _modifierDown(SkylightEvent event) {
    final int? mask = switch (event.keyCode) {
      56 || 60 => 1 << 17, // shift
      59 || 62 => 1 << 18, // control
      58 || 61 => 1 << 19, // option
      55 || 54 => 1 << 20, // command
      57 => 1 << 16, // caps lock
      _ => null,
    };
    return mask == null ? null : (event.flags & mask) != 0;
  }

  void _emitKey(SkylightEvent event,
      {required bool down, required Duration timestamp}) {
    final String characters = event.characters;
    final int keyChar = characters.isEmpty ? 0 : characters.codeUnitAt(0);
    final int logicalKey = macosLogicalKey(event.keyCode, keyChar);
    final Set<KeyModifier> modifiers = macosKeyModifiers(event.flags);
    final KeyLocation location = macosKeyLocation(event.keyCode);
    final int generation = _generation.current;
    _emit(down
        ? KeyDownEvent(
            windowId: _id,
            generation: generation,
            timestamp: timestamp,
            physicalKey: event.keyCode,
            logicalKey: logicalKey,
            modifiers: modifiers,
            location: location,
          )
        : KeyUpEvent(
            windowId: _id,
            generation: generation,
            timestamp: timestamp,
            physicalKey: event.keyCode,
            logicalKey: logicalKey,
            modifiers: modifiers,
            location: location,
          ));
    if (!down) return;
    // Text, as macosTextInput filters it: no controls, no function keys,
    // and nothing typed while Command or Control turns it into a shortcut.
    if (modifiers.contains(KeyModifier.meta) ||
        modifiers.contains(KeyModifier.control)) {
      return;
    }
    final StringBuffer text = StringBuffer();
    for (final int rune in characters.runes) {
      if (rune < 0x20 || (rune >= 0x7F && rune <= 0x9F)) continue;
      if (rune >= 0xF700 && rune <= 0xF8FF) continue;
      text.writeCharCode(rune);
    }
    if (text.isEmpty) return;
    _emit(TextInputEvent(
      windowId: _id,
      generation: generation,
      timestamp: timestamp,
      text: text.toString(),
    ));
  }

  void _emit(PlatformWindowEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  @override
  void onDispose() {
    _surface = null;
    _generation.invalidate();
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
