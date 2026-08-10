/// Deterministic windowing backend for tests, goldens, and servers without a
/// display system.
///
/// The backend deliberately implements the same [WindowingBackend] contract
/// as Win32, X11, and AppKit. A headless test therefore exercises window
/// lifecycle, generations, coordinate conversion, and input normalization
/// without replacing those layers with mocks.
library;

import 'dart:async';
import 'dart:collection';

import '../../foundation/diagnostics.dart';
import '../../foundation/lifecycle.dart';
import '../../geometry/offset.dart';
import '../../geometry/rect.dart';
import '../../geometry/size.dart';
import '../../platform/input_events.dart';
import '../../platform/native_window.dart';
import '../../platform/window_events.dart';
import '../../rendering/renderer.dart';

/// An always-available in-memory windowing backend.
final class HeadlessWindowingBackend implements WindowingBackend {
  HeadlessWindowingBackend({
    this.renderScale = 1,
    this.desktopScale = 1,
  }) {
    _validateScale(renderScale, 'renderScale');
    _validateScale(desktopScale, 'desktopScale');
  }

  @override
  String get name => 'headless';

  /// Physical pixels allocated for each logical unit.
  final double renderScale;

  /// Synthetic desktop text/UI scale reported by every window.
  final double desktopScale;

  final List<HeadlessWindow> _windows = <HeadlessWindow>[];
  final ListQueue<_QueuedHeadlessEvent> _eventQueue =
      ListQueue<_QueuedHeadlessEvent>();
  var _nextWindowId = 1;
  var _initialized = false;

  bool get isInitialized => _initialized;

  @override
  BackendProbeResult probe() => BackendProbeResult(
        backendName: name,
        supported: true,
        capabilities: const <Capability>{
          Capability.window,
          Capability.multipleWindows,
          Capability.cpuPresentation,
          Capability.partialPresent,
          Capability.keyboardInput,
          Capability.pointerInput,
          Capability.scrollInput,
          Capability.orderlyShutdown,
        },
        diagnostics: const <BackendDiagnostic>[
          BackendDiagnostic.note(
            'pure Dart in-memory windowing; no display server required',
          ),
        ],
      );

  @override
  Future<void> initialize() async {
    _initialized = true;
  }

  @override
  Future<void> shutdown() async {
    if (!_initialized) return;
    for (final window in List<HeadlessWindow>.of(_windows).reversed) {
      window.dispose();
    }
    _drainQueuedEvents();
    _windows.clear();
    _eventQueue.clear();
    _initialized = false;
  }

  @override
  Future<HeadlessWindow> createWindow(WindowOptions options) async {
    _requireInitialized('createWindow');
    _validateSize(options.size);
    final window = HeadlessWindow._(
      id: NativeWindowId(_nextWindowId++),
      options: options,
      renderScale: renderScale,
      desktopScale: desktopScale,
      enqueueEvent: _enqueueEvent,
      onClosed: _removeWindow,
    );
    _windows.add(window);
    return window;
  }

  @override
  List<HeadlessWindow> get windows =>
      List<HeadlessWindow>.unmodifiable(_windows);

  /// Events waiting for the next deterministic [pumpEvents].
  int get pendingEventCount => _eventQueue.length;

  @override
  bool pumpEvents({Duration timeout = Duration.zero}) {
    _requireInitialized('pumpEvents');
    // A headless pump never sleeps: timeout is accepted for contract parity,
    // but no wall clock participates in delivery or ordering.
    _drainQueuedEvents();
    return _windows.isNotEmpty;
  }

  @override
  void wake() => _requireInitialized('wake');

  void _enqueueEvent(HeadlessWindow window, PlatformWindowEvent event) {
    _eventQueue.addLast(_QueuedHeadlessEvent(window, event));
  }

  void _drainQueuedEvents() {
    while (_eventQueue.isNotEmpty) {
      final queued = _eventQueue.removeFirst();
      queued.window._deliver(queued.event);
    }
  }

  void _removeWindow(HeadlessWindow window) => _windows.remove(window);

  void _requireInitialized(String operation) {
    if (!_initialized) {
      throw StateError('$name.$operation before initialize()');
    }
  }

  static void _validateScale(double value, String name) {
    if (!value.isFinite || value <= 0) {
      throw ArgumentError.value(value, name, 'must be finite and positive');
    }
  }

  static void _validateSize(Size size) {
    if (!size.width.isFinite ||
        !size.height.isFinite ||
        size.width <= 0 ||
        size.height <= 0) {
      throw ArgumentError.value(
          size, 'options.size', 'must be finite and positive');
    }
  }
}

/// A virtual top-level window backed by a [MemorySurfaceDescriptor].
final class HeadlessWindow with DisposableMixin implements NativeWindow {
  HeadlessWindow._({
    required NativeWindowId id,
    required WindowOptions options,
    required double renderScale,
    required double desktopScale,
    required void Function(
      HeadlessWindow window,
      PlatformWindowEvent event,
    ) enqueueEvent,
    required void Function(HeadlessWindow window) onClosed,
  })  : _id = id,
        _clientSize = options.size,
        _position = options.position ?? Offset.zero,
        _title = options.title,
        _visible = options.visible,
        _renderScale = renderScale,
        _desktopScale = desktopScale,
        _enqueueEvent = enqueueEvent,
        _onClosed = onClosed {
    _surface = _createSurface();
  }

  final NativeWindowId _id;
  final double _renderScale;
  final double _desktopScale;
  final void Function(HeadlessWindow window, PlatformWindowEvent event)
      _enqueueEvent;
  final void Function(HeadlessWindow window) _onClosed;
  final GenerationToken _generation = GenerationToken();
  final StreamController<PlatformWindowEvent> _events =
      StreamController<PlatformWindowEvent>.broadcast(sync: true);

  late MemorySurfaceDescriptor _surface;
  Size _clientSize;
  Offset _position;
  String _title;
  bool _visible;
  SystemCursor _cursor = SystemCursor.arrow;

  @override
  NativeWindowId get id => _id;

  @override
  int get generation => _generation.current;

  @override
  Size get clientSize => _clientSize;

  Offset get position => _position;

  String get title => _title;

  bool get isVisible => _visible;

  SystemCursor get cursor => _cursor;

  @override
  double get renderScale => _renderScale;

  @override
  double get desktopScale => _desktopScale;

  @override
  WindowState get state => WindowState.normal;

  @override
  List<NativeSurfaceDescriptor> get surfaces => isDisposed
      ? const <NativeSurfaceDescriptor>[]
      : <NativeSurfaceDescriptor>[_surface];

  MemorySurfaceDescriptor get memorySurface {
    throwIfDisposed();
    return _surface;
  }

  @override
  Stream<PlatformWindowEvent> get events => _events.stream;

  @override
  void show() {
    throwIfDisposed();
    if (_visible) return;
    _visible = true;
    _emit(WindowActivationEvent(
      windowId: id,
      generation: generation,
      activation: WindowActivation.activated,
    ));
  }

  @override
  void hide() {
    throwIfDisposed();
    if (!_visible) return;
    _visible = false;
    _emit(WindowActivationEvent(
      windowId: id,
      generation: generation,
      activation: WindowActivation.deactivated,
    ));
  }

  @override
  void close() => dispose();

  @override
  void setTitle(String value) {
    throwIfDisposed();
    _title = value;
  }

  @override
  void setBounds(Rect bounds) {
    throwIfDisposed();
    if (!bounds.left.isFinite ||
        !bounds.top.isFinite ||
        !bounds.width.isFinite ||
        !bounds.height.isFinite ||
        bounds.isEmpty) {
      throw ArgumentError.value(
          bounds, 'bounds', 'must be finite and positive');
    }

    final moved = bounds.topLeft != _position;
    final resized = bounds.size != _clientSize;
    _position = bounds.topLeft;
    if (resized) {
      _clientSize = bounds.size;
      _generation.invalidate();
      _surface = _createSurface();
    }
    if (moved) {
      _emit(WindowMovedEvent(
        windowId: id,
        generation: generation,
        screenPosition: _position,
      ));
    }
    if (resized) {
      _emit(WindowResizedEvent(
        windowId: id,
        generation: generation,
        clientSize: clientSize,
        renderScale: renderScale,
      ));
    }
  }

  @override
  void setCursor(SystemCursor cursor) {
    throwIfDisposed();
    _cursor = cursor;
  }

  @override
  void requestRedraw([Rect? dirtyRect]) {
    throwIfDisposed();
    _emit(WindowExposedEvent(
      windowId: id,
      generation: generation,
      dirtyRect: dirtyRect,
    ));
  }

  @override
  Offset screenToClient(Offset screenPosition) => screenPosition - _position;

  @override
  Offset clientToScreen(Offset clientPosition) => clientPosition + _position;

  /// Queues normalized synthetic input for the next backend event pump.
  ///
  /// False means the event was stale or belonged to another window. Tests can
  /// assert the drop explicitly instead of relying on a silent callback.
  bool dispatchInput(PlatformInputEvent event) {
    throwIfDisposed();
    if (event.windowId != id || event.generation != generation) return false;
    _emit(event);
    return true;
  }

  MemorySurfaceDescriptor _createSurface() => MemorySurfaceDescriptor(
        pixelWidth: (_clientSize.width * _renderScale).ceil().clamp(1, 1 << 30),
        pixelHeight:
            (_clientSize.height * _renderScale).ceil().clamp(1, 1 << 30),
        scale: _renderScale,
      );

  void _emit(PlatformWindowEvent event) {
    _enqueueEvent(this, event);
  }

  void _deliver(PlatformWindowEvent event) {
    if (_events.isClosed || event.windowId != id) return;
    if (event is WindowClosedEvent) {
      _events.add(event);
      _events.close();
      return;
    }
    _events.add(event);
  }

  @override
  void onDispose() {
    _generation.invalidate();
    _emit(WindowClosedEvent(windowId: id, generation: generation));
    _onClosed(this);
  }

  @override
  String toString() => 'HeadlessWindow(id: ${id.value}, '
      '${clientSize.width}x${clientSize.height} @ $renderScale)';
}

final class _QueuedHeadlessEvent {
  const _QueuedHeadlessEvent(this.window, this.event);

  final HeadlessWindow window;
  final PlatformWindowEvent event;
}
