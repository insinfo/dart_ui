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
import '../../platform/clipboard.dart';
import '../../platform/input_events.dart';
import '../../platform/native_window.dart';
import '../../platform/window_events.dart';
import '../../rendering/renderer.dart';
import 'headless_test_support.dart' show FakeClipboard;

/// An always-available in-memory windowing backend.
final class HeadlessWindowingBackend
    implements WindowingBackend, ClipboardProvider {
  HeadlessWindowingBackend({
    this.renderScale = 1,
    this.desktopScale = 1,
  }) {
    _validateScale(renderScale, 'renderScale');
    _validateScale(desktopScale, 'desktopScale');
  }

  @override
  String get name => 'headless';

  /// The in-memory clipboard every headless application gets by default.
  ///
  /// Typed as [FakeClipboard] rather than [Clipboard] on purpose: a test that
  /// drives copy and paste through the shell needs to seed it, read it back and
  /// make it fail on demand, and a test that had to install its own clipboard
  /// to do so would no longer be exercising the *default* path - which is the
  /// path that was broken.
  @override
  final FakeClipboard clipboard = FakeClipboard();

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
      activateExclusively: _activateExclusively,
    );
    _windows.add(window);
    return window;
  }

  /// Gives one window the keyboard and takes it from every other.
  ///
  /// The desktop invariant, modelled rather than assumed: exactly one window of
  /// a display server is active at a time, so activating one *deactivates* the
  /// previous holder and the deactivation is a real queued event with a real
  /// ordering. A headless test of cross-window focus is only worth anything if
  /// the backend enforces this the way a window manager does.
  ///
  /// Note that creating a visible window does **not** go through here and emits
  /// nothing: on every real platform a window is mapped first and activated
  /// second, and the two are separate messages.
  void _activateExclusively(HeadlessWindow window) {
    for (final HeadlessWindow other in _windows) {
      if (identical(other, window)) continue;
      other._deactivate();
    }
    window._activate();
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
final class HeadlessWindow
    with DisposableMixin
    implements NativeWindow, ActivatableWindow, EnableableWindow {
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
    required void Function(HeadlessWindow window) activateExclusively,
  })  : _id = id,
        _clientSize = options.size,
        _position = options.position ?? Offset.zero,
        _title = options.title,
        _visible = options.visible,
        // A window that is mapped at creation is the one the user is looking
        // at, so it starts active - but silently, because no platform sends an
        // activation message for a window that has not existed yet.
        _active = options.visible && options.kind.takesActivation,
        owner = options.owner,
        kind = options.kind,
        _renderScale = renderScale,
        _desktopScale = desktopScale,
        _enqueueEvent = enqueueEvent,
        _onClosed = onClosed,
        _activateExclusively = activateExclusively {
    _surface = _createSurface();
  }

  final NativeWindowId _id;
  final double _renderScale;
  final double _desktopScale;
  final void Function(HeadlessWindow window, PlatformWindowEvent event)
      _enqueueEvent;
  final void Function(HeadlessWindow window) _onClosed;
  final void Function(HeadlessWindow window) _activateExclusively;

  /// The window this one belongs to, or null for a top-level window.
  ///
  /// Recorded rather than acted on: there is no window manager here to keep an
  /// owned window above its owner, and the application layer is what closes
  /// owned windows with their owner. Exposed so a test can assert the
  /// relationship reached the backend at all.
  final NativeWindow? owner;

  /// What this window is. A [WindowKind.popup] or [WindowKind.tooltip] refuses
  /// activation the way `WS_EX_NOACTIVATE` makes a real menu refuse it, so a
  /// headless test of "opening a menu must not deactivate the window behind
  /// it" is testing the same rule the Win32 backend enforces.
  final WindowKind kind;
  final GenerationToken _generation = GenerationToken();
  final StreamController<PlatformWindowEvent> _events =
      StreamController<PlatformWindowEvent>.broadcast(sync: true);

  late MemorySurfaceDescriptor _surface;
  Size _clientSize;
  Offset _position;
  String _title;
  bool _visible;
  bool _active;
  bool _enabled = true;
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

  /// Whether this window currently holds the keyboard.
  bool get isActive => _active;

  @override
  void show() {
    throwIfDisposed();
    if (_visible) return;
    _visible = true;
    if (!kind.takesActivation) return;
    _activateExclusively(this);
  }

  @override
  void hide() {
    throwIfDisposed();
    if (!_visible) return;
    _visible = false;
    _deactivate();
  }

  /// Takes the keyboard, deactivating whichever window had it.
  ///
  /// A disabled window refuses, which is the platform half of modality: a
  /// window blocked by a modal dialog cannot be clicked into focus.
  @override
  void activate() {
    throwIfDisposed();
    if (!_enabled || !kind.takesActivation) return;
    _visible = true;
    _activateExclusively(this);
  }

  @override
  bool get isEnabled => _enabled;

  @override
  void setEnabled(bool value) {
    throwIfDisposed();
    if (value == _enabled) return;
    _enabled = value;
    if (!value) _deactivate();
  }

  void _activate() {
    if (_active || isDisposed) return;
    _active = true;
    _emit(WindowActivationEvent(
      windowId: id,
      generation: generation,
      activation: WindowActivation.activated,
    ));
  }

  void _deactivate() {
    if (!_active || isDisposed) return;
    _active = false;
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
  /// False means the event was stale, belonged to another window, or arrived
  /// at a window the platform has been told to refuse input for - the modal
  /// case. Tests can assert the drop explicitly instead of relying on a silent
  /// callback.
  bool dispatchInput(PlatformInputEvent event) {
    throwIfDisposed();
    if (event.windowId != id || event.generation != generation) return false;
    if (!_enabled) return false;
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
