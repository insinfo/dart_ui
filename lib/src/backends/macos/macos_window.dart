/// A `NativeWindow` backed by the AppKit host process.
///
/// The window object lives in Dart; the `NSWindow` lives in the host. What
/// crosses between them is a line protocol for control and input, and an
/// `IOSurface` pool for pixels - the split ADR 0001 chose and measured.
///
/// Two consequences shape this file.
///
/// **Every event carries a generation.** Not decoration: the host can die and
/// be replaced, and events already in the pipe when it died belong to a window
/// that no longer exists. Comparing two integers is the only reliable way to
/// tell a live event from a late one, which is `lifecycle.dart`'s rule and was
/// paid for by this repository's own macOS spike.
///
/// **A resize invalidates surfaces.** The pool is allocated at pixel size, so
/// a resize or a scale change means new surfaces, a new attach handshake and a
/// bumped generation. Presents stamped with the old generation are dropped
/// rather than drawn into memory that moved.
library;

import 'dart:async';

import '../../foundation/diagnostics.dart';
import '../../foundation/lifecycle.dart';
import '../../geometry/offset.dart';
import '../../geometry/rect.dart';
import '../../geometry/size.dart';
import '../../platform/native_window.dart';
import '../../platform/window_events.dart';
import '../../rendering/framebuffer.dart';
import '../../rendering/renderer.dart';
import 'host_process.dart';
import 'host_protocol.dart';
import 'host_supervisor.dart';
import 'io_surface.dart';
import 'surface_pool.dart';

/// Called for every input event the host dequeued.
///
/// A callback with primitive parameters rather than a `Stream` of event
/// objects, for two reasons. The first is the allocation budget: pointer moves
/// arrive at input rates and an object per move is garbage this layer does not
/// need to create. The second is that `window_events.dart` models *window*
/// events only - hit testing, focus and gesture recognition live above this
/// layer, and the production input contract they will consume does not exist
/// yet. When it lands, this is the one place that has to map onto it.
typedef MacosInputListener = void Function(
  HostInputKind kind,
  double x,
  double y,
  int keyCode,
  int machTime,
);

/// Creates the surfaces a window presents through.
///
/// Injected so the pool can be faked in a test that has no IOSurface, and so
/// the `global` decision - which is a security trade, not a detail - is made
/// in one place.
typedef MacosSurfaceFactory = MacosSurfacePool Function({
  required int pixelWidth,
  required int pixelHeight,
  required bool global,
});

/// A window owned by a host process.
final class MacosWindow with DisposableMixin implements NativeWindow {
  MacosWindow({
    required NativeWindowId id,
    required MacosSurfaceFactory surfaceFactory,
    required Size clientSize,
    required double renderScale,
    required double desktopScale,
    required void Function(BackendDiagnostic diagnostic) onDiagnostic,
    required void Function(MacosWindow window) onClosed,
    bool globalSurfaces = true,
    int slotCount = 2,
  })  : _id = id,
        _surfaceFactory = surfaceFactory,
        _clientSize = clientSize,
        _renderScale = renderScale,
        _desktopScale = desktopScale,
        _onDiagnostic = onDiagnostic,
        _onClosed = onClosed,
        _globalSurfaces = globalSurfaces,
        _slotCount = slotCount;

  final NativeWindowId _id;
  final MacosSurfaceFactory _surfaceFactory;
  final void Function(BackendDiagnostic diagnostic) _onDiagnostic;
  final void Function(MacosWindow window) _onClosed;
  final bool _globalSurfaces;
  final int _slotCount;

  /// Single subscription rather than broadcast, and therefore buffered until
  /// somebody listens. A broadcast controller silently drops everything that
  /// arrives before the first listener, which on this backend means the first
  /// resize - the one that tells the framework how big the window really is.
  final StreamController<PlatformWindowEvent> _events =
      StreamController<PlatformWindowEvent>();

  final GenerationToken _generation = GenerationToken();

  MacosHostSupervisor? _supervisor;
  MacosSurfacePool? _pool;
  MacosSurfaceDescriptor? _descriptor;
  MacosInputListener? _inputListener;

  Size _clientSize;
  double _renderScale;
  double _desktopScale;
  WindowState _state = WindowState.normal;
  Offset _screenPosition = Offset.zero;
  bool _resizeInFlight = false;
  Future<void>? _teardown;

  @override
  NativeWindowId get id => _id;

  @override
  int get generation => _generation.current;

  @override
  Size get clientSize => _clientSize;

  @override
  double get renderScale => _renderScale;

  @override
  double get desktopScale => _desktopScale;

  @override
  WindowState get state => _state;

  @override
  Stream<PlatformWindowEvent> get events => _events.stream;

  @override
  List<NativeSurfaceDescriptor> get surfaces {
    final descriptor = _descriptor;
    return descriptor == null
        ? const <NativeSurfaceDescriptor>[]
        : <NativeSurfaceDescriptor>[descriptor];
  }

  /// The `CGSWindowID` of the current host's window.
  ///
  /// Diagnostics only, and it *changes* after a recovery - the replacement
  /// host creates a new `NSWindow`. That is exactly why [id] is a separate,
  /// stable value, as `window_events.dart` requires.
  int get hostWindowNumber => _supervisor?.handshake?.windowNumber ?? 0;

  int get hostPid => _supervisor?.handshake?.hostPid ?? 0;

  /// How many times the host has been replaced under this window.
  int get hostRestartCount => _supervisor?.restartCount ?? 0;

  MacosSurfaceHandoff? get surfaceHandoff => _supervisor?.activeHandoff;

  /// The pool, for a renderer that wants the zero-copy path.
  MacosSurfacePool? get pool => _pool;

  set inputListener(MacosInputListener? listener) => _inputListener = listener;

  /// Brings the window up: allocates surfaces, then starts the host.
  ///
  /// Surfaces first, deliberately. They outlive every host this window will
  /// ever spawn, and a host that starts before them would have a window with
  /// nothing to show - which is also the state a recovery passes through.
  Future<bool> open({
    required MacosHostSpawnOptions spawnOptions,
    MacosRecoveryPolicy policy = const MacosRecoveryPolicy(),
    MacosSurfaceHandoff handoff = MacosSurfaceHandoff.rendezvous,
    bool allowLookupFallback = true,
  }) async {
    throwIfDisposed();
    final pool = _allocatePool();
    if (pool == null) return false;
    _pool = pool;
    _descriptor = pool.describe(_renderScale);

    final supervisor = MacosHostSupervisor(
      spawnOptions: spawnOptions,
      sink: _HostSink(this),
      onDiagnostic: _onDiagnostic,
      onHostReplaced: _onHostReplaced,
      onRecoveryExhausted: _onRecoveryExhausted,
      policy: policy,
      handoff: handoff,
      allowLookupFallback: allowLookupFallback,
    );
    _supervisor = supervisor;
    final started = await supervisor.start();
    if (!started || !await supervisor.attachPool(pool)) {
      pool.dispose();
      _pool = null;
      _descriptor = null;
      return false;
    }
    supervisor.rememberTitle(spawnOptions.title);
    return true;
  }

  MacosSurfacePool? _allocatePool() {
    final pixelWidth = (_clientSize.width * _renderScale).round();
    final pixelHeight = (_clientSize.height * _renderScale).round();
    if (pixelWidth <= 0 || pixelHeight <= 0) {
      _onDiagnostic(
        BackendDiagnostic(
          kind: DiagnosticKind.surfaceCreationFailed,
          message: 'macOS window has no pixels',
          detail: '${_clientSize.width}x${_clientSize.height} '
              'at ${_renderScale}x',
        ),
      );
      return null;
    }
    try {
      return _surfaceFactory(
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        global: _globalSurfaces,
      );
    } on Object catch (error) {
      _onDiagnostic(
        BackendDiagnostic(
          kind: DiagnosticKind.surfaceCreationFailed,
          message: 'could not allocate the macOS surface pool',
          detail: '$pixelWidth x $pixelHeight x $_slotCount: $error',
        ),
      );
      return null;
    }
  }

  // --- NativeWindow ----------------------------------------------------------

  @override
  void show() => _supervisor?.rememberVisibility(true);

  @override
  void hide() => _supervisor?.rememberVisibility(false);

  @override
  void close() {
    if (isDisposed) return;
    // A close is not a dispose: the framework may still read the window's last
    // size out of the closed event. dispose() releases; this only stops the
    // host.
    unawaited(_shutdown());
  }

  @override
  void setTitle(String value) {
    // Newlines would end the command early and let the rest of the title be
    // parsed as commands. Stripping is cheaper to reason about than escaping.
    _supervisor
        ?.rememberTitle(value.replaceAll('\n', ' ').replaceAll('\r', ' '));
  }

  @override
  void setBounds(Rect bounds) {
    _supervisor?.rememberBounds(
      bounds.left,
      bounds.top,
      bounds.width,
      bounds.height,
    );
  }

  @override
  void setCursor(SystemCursor cursor) =>
      _supervisor?.rememberCursor(cursor.name);

  @override
  void requestRedraw([Rect? dirtyRect]) {
    final supervisor = _supervisor;
    if (supervisor == null) return;
    supervisor.send(
      dirtyRect == null
          ? HostCommands.redrawAll()
          : HostCommands.redraw(
              dirtyRect.left,
              dirtyRect.top,
              dirtyRect.width,
              dirtyRect.height,
            ),
    );
  }

  /// Screen points are top-left origin.
  ///
  /// The flip out of AppKit's bottom-left origin happens in the host, which is
  /// the only place that knows the screen frame. Doing it here would mean a
  /// second copy of the convention, in a second language, going stale
  /// separately.
  @override
  Offset screenToClient(Offset screenPosition) =>
      screenPosition - _screenPosition;

  @override
  Offset clientToScreen(Offset clientPosition) =>
      clientPosition + _screenPosition;

  // --- presentation ----------------------------------------------------------

  /// Copies [frame] into the back buffer and asks the host to present it.
  ///
  /// The copy is what "presenting a Framebuffer" means when the renderer owns
  /// its own memory. A renderer that can draw straight into the surface should
  /// use [drawAndPresent] instead and skip it.
  Future<PresentResult> present(Framebuffer frame, {int? frameGeneration}) {
    final stale = _rejectStale(frameGeneration);
    if (stale != null) return Future<PresentResult>.value(stale);
    final pool = _pool!;
    if (!pool.copyIntoBackBuffer(frame)) {
      return Future<PresentResult>.value(
        PresentResult(
          status: PresentStatus.failed,
          diagnostic: BackendDiagnostic(
            kind: DiagnosticKind.surfaceCreationFailed,
            message: 'frame does not match the macOS surface',
            detail: '${frame.width}x${frame.height} ${frame.format.name} '
                'into ${pool.describe(_renderScale)}',
          ),
        ),
      );
    }
    return _presentBackBuffer(pool);
  }

  /// Runs [draw] against the back buffer's own memory and presents it.
  ///
  /// This is the path the transport benchmark measured: the surface is handed
  /// to the layer once and each later frame only marks the contents changed,
  /// which is why the cost is 66-130 us from 480x320 to 4K.
  Future<PresentResult> drawAndPresent(
    void Function(Framebuffer buffer) draw, {
    int? frameGeneration,
  }) {
    final stale = _rejectStale(frameGeneration);
    if (stale != null) return Future<PresentResult>.value(stale);
    final pool = _pool!;
    pool.withBackBuffer(draw);
    return _presentBackBuffer(pool);
  }

  PresentResult? _rejectStale(int? frameGeneration) {
    if (isDisposed) {
      return const PresentResult(
        status: PresentStatus.deviceLost,
        diagnostic: BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'present on a disposed macOS window',
        ),
      );
    }
    if (frameGeneration != null && !_generation.accepts(frameGeneration)) {
      return const PresentResult(status: PresentStatus.stale);
    }
    if (_resizeInFlight) {
      // Not an error: this is precisely what a resize during a frame looks
      // like, and the caller's response - draw the next one - is already right.
      return const PresentResult(status: PresentStatus.stale);
    }
    if (_pool == null || _supervisor?.host == null) {
      return const PresentResult(
        status: PresentStatus.deviceLost,
        diagnostic: BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'no macOS host to present to',
          detail: 'the host died and recovery has not finished; the surfaces '
              'are intact, so the next frame after recovery will land',
        ),
      );
    }
    return null;
  }

  Future<PresentResult> _presentBackBuffer(MacosSurfacePool pool) async {
    final slot = pool.backSlot;
    final sequence = pool.markPresented(slot);
    final sent = await _supervisor!.present(slot, sequence);
    if (!sent) {
      return const PresentResult(
        status: PresentStatus.deviceLost,
        diagnostic: BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'macOS host did not accept the present',
        ),
      );
    }
    return const PresentResult(status: PresentStatus.presented);
  }

  /// Presents and waits for the host to confirm.
  ///
  /// Only for conformance: it costs the measured 188 us round trip per frame
  /// and proves nothing the double buffer does not already guarantee.
  Future<bool> presentAndAwaitAck({Duration? timeout}) async {
    final pool = _pool;
    final supervisor = _supervisor;
    if (pool == null || supervisor == null) return false;
    final slot = pool.backSlot;
    final sequence = pool.markPresented(slot);
    return supervisor.present(slot, sequence, awaitAck: true);
  }

  // --- host events -----------------------------------------------------------

  void _onWindowEvent(
    HostWindowEventKind kind,
    double a,
    double b,
    double c,
    double d,
  ) {
    switch (kind) {
      case HostWindowEventKind.resized:
        _handleResized(a, b, c);
      case HostWindowEventKind.moved:
        _screenPosition = Offset(a, b);
        _emit(
          WindowMovedEvent(
            windowId: _id,
            generation: _generation.current,
            screenPosition: _screenPosition,
          ),
        );
      case HostWindowEventKind.scaleChanged:
        _handleScaleChanged(a, b);
      case HostWindowEventKind.exposed:
        _emit(
          WindowExposedEvent(
            windowId: _id,
            generation: _generation.current,
            // An all-zero rect is the host saying it could not tell us which
            // part; repainting everything is the documented response.
            dirtyRect: c > 0 && d > 0 ? Rect.fromLTWH(a, b, c, d) : null,
          ),
        );
      case HostWindowEventKind.activated:
        _emit(
          WindowActivationEvent(
            windowId: _id,
            generation: _generation.current,
            activation: WindowActivation.activated,
          ),
        );
      case HostWindowEventKind.deactivated:
        _emit(
          WindowActivationEvent(
            windowId: _id,
            generation: _generation.current,
            activation: WindowActivation.deactivated,
          ),
        );
      case HostWindowEventKind.stateChanged:
        final index = a.round();
        if (index >= 0 && index < WindowState.values.length) {
          _state = WindowState.values[index];
        }
      case HostWindowEventKind.closeRequested:
        _emit(
          WindowCloseRequestedEvent(
            windowId: _id,
            generation: _generation.current,
          ),
        );
      case HostWindowEventKind.closed:
        _emitClosed();
        unawaited(_shutdown());
    }
  }

  void _handleResized(double width, double height, double scale) {
    final size = Size(width, height);
    final scaleChanged = scale != _renderScale;
    final pixelsChanged = _pool == null ||
        (width * scale).round() != _pool!.surfaces.first.width ||
        (height * scale).round() != _pool!.surfaces.first.height;

    _clientSize = size;
    _renderScale = scale;
    if (scaleChanged) _desktopScale = scale;

    if (pixelsChanged) {
      // Bump BEFORE the event: a listener that reacts by presenting must be
      // rejected, because the surface it would draw into is about to be freed.
      _generation.invalidate();
      unawaited(_reallocate());
    }
    _supervisor?.updateSpawnGeometry(width, height);
    _emit(
      WindowResizedEvent(
        windowId: _id,
        generation: _generation.current,
        clientSize: size,
        renderScale: scale,
      ),
    );
  }

  void _handleScaleChanged(double renderScale, double desktopScale) {
    final changed = renderScale != _renderScale;
    _renderScale = renderScale;
    _desktopScale = desktopScale;
    if (changed) {
      _generation.invalidate();
      unawaited(_reallocate());
    }
    _emit(
      WindowScaleChangedEvent(
        windowId: _id,
        generation: _generation.current,
        renderScale: renderScale,
        desktopScale: desktopScale,
      ),
    );
  }

  /// Allocates a new pool at the current pixel size and attaches it.
  ///
  /// Reverse order at the end: the new pool is attached before the old one is
  /// released, so the layer never holds a surface whose last reference we just
  /// dropped.
  Future<void> _reallocate() async {
    if (isDisposed || _resizeInFlight) return;
    _resizeInFlight = true;
    final previous = _pool;
    try {
      final pool = _allocatePool();
      if (pool == null) return;
      final supervisor = _supervisor;
      if (supervisor == null) {
        pool.dispose();
        return;
      }
      final attached = await supervisor.attachPool(pool);
      if (!attached) {
        _onDiagnostic(
          const BackendDiagnostic(
            kind: DiagnosticKind.surfaceCreationFailed,
            message: 'could not attach the resized macOS surface pool',
            detail: 'the window keeps its previous surfaces; the next resize '
                'will try again',
          ),
        );
        pool.dispose();
        return;
      }
      _pool = pool;
      _descriptor = pool.describe(_renderScale);
      previous?.dispose();
    } finally {
      _resizeInFlight = false;
    }
  }

  void _onHostReplaced(MacosHostHandshake handshake, Duration downtime) {
    if (isDisposed) return;
    // The framebuffer survived - measured - but the window did not: this is a
    // different NSWindow, at a fresh position, showing nothing yet. Bumping
    // the generation drops events that were in the pipe when the old host
    // died, and the exposed event asks for the repaint that makes the new
    // window show something.
    _generation.invalidate();
    _emit(
      WindowResizedEvent(
        windowId: _id,
        generation: _generation.current,
        clientSize: _clientSize,
        renderScale: _renderScale,
      ),
    );
    _emit(
      WindowExposedEvent(
        windowId: _id,
        generation: _generation.current,
      ),
    );
  }

  void _onRecoveryExhausted() {
    if (isDisposed) return;
    _emitClosed();
  }

  void _emitClosed() {
    _generation.invalidate();
    _events.add(
      WindowClosedEvent(windowId: _id, generation: _generation.current),
    );
    _onClosed(this);
  }

  void _emit(PlatformWindowEvent event) {
    if (_events.isClosed) return;
    _events.add(event);
  }

  // --- teardown --------------------------------------------------------------

  Future<void> _shutdown() {
    return _teardown ??= () async {
      final supervisor = _supervisor;
      _supervisor = null;
      if (supervisor != null) await supervisor.stop();
    }();
  }

  /// Reverse acquisition order: host first, then surfaces, then the stream.
  ///
  /// Releasing the surfaces while the host still has them as layer contents is
  /// the macOS version of the Mach-port bug `lifecycle.dart` was written for.
  @override
  void onDispose() {
    final pool = _pool;
    _pool = null;
    _descriptor = null;
    _inputListener = null;
    _teardown = _shutdown().whenComplete(() {
      pool?.dispose();
      if (!_events.isClosed) _events.close();
    });
  }

  /// Completes when teardown has actually finished, since [dispose] cannot
  /// await a process.
  Future<void> get teardown => _teardown ?? Future<void>.value();
}

/// Routes host messages into the window.
///
/// A separate object rather than making [MacosWindow] the sink, so that
/// `HostMessageSink`'s eleven methods do not sit in the middle of the window's
/// public contract.
final class _HostSink with HostMessageSinkAdapter {
  _HostSink(this._window);

  final MacosWindow _window;

  @override
  void onWindowEvent(
    HostWindowEventKind kind,
    double a,
    double b,
    double c,
    double d,
  ) =>
      _window._onWindowEvent(kind, a, b, c, d);

  @override
  void onInput(
    HostInputKind kind,
    double x,
    double y,
    int keyCode,
    int machTime,
  ) =>
      _window._inputListener?.call(kind, x, y, keyCode, machTime);
}

/// The default factory: real `IOSurface`s.
///
/// [global] carries a security decision. A global surface is visible to every
/// process on the machine, which is what the deprecated `IOSurfaceLookup`
/// fallback needs; the rendezvous path does not, and a build that turns the
/// fallback off gets private surfaces.
MacosSurfacePool createIOSurfacePool({
  required int pixelWidth,
  required int pixelHeight,
  required bool global,
  int slotCount = 2,
}) {
  final surfaces = <MacosPoolSurface>[];
  try {
    for (var slot = 0; slot < slotCount; slot++) {
      surfaces.add(
        MacosIOSurface.create(
          width: pixelWidth,
          height: pixelHeight,
          global: global,
        ),
      );
    }
  } on Object {
    // A partially built pool would leak every surface before the one that
    // failed - the same rule the host's own pool code follows.
    for (var index = surfaces.length - 1; index >= 0; index--) {
      surfaces[index].dispose();
    }
    rethrow;
  }
  return MacosSurfacePool(surfaces);
}
