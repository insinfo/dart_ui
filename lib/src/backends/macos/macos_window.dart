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
import 'dart:convert';

import '../../foundation/diagnostics.dart';
import '../../foundation/lifecycle.dart';
import '../../foundation/value_notifier.dart';
import '../../geometry/offset.dart';
import '../../geometry/rect.dart';
import '../../geometry/size.dart';
import '../../platform/input_events.dart';
import '../../platform/native_menu.dart';
import '../../platform/native_window.dart';
import '../../platform/window_events.dart';
import '../../rendering/framebuffer.dart';
import '../../rendering/present_mode.dart';
import '../../rendering/renderer.dart';
import 'host_process.dart';
import 'host_protocol.dart';
import 'host_supervisor.dart';
import 'io_surface.dart';
import 'macos_accessibility.dart';
import 'macos_drag_drop.dart';
import 'macos_input.dart';
import 'macos_native_menu.dart';
import 'macos_text_input.dart';
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
/// How long a paced present waits for the previous frame's refresh.
///
/// Three refreshes at 60 Hz. The host's display link pauses while the window
/// is hidden or fully occluded, and then no refresh comes: the wait ends here
/// and the loop runs at this rate instead, which is what a window nobody can
/// see should cost.
const Duration kMacosVsyncTimeout = Duration(milliseconds: 50);

final class MacosWindow
    with DisposableMixin
    implements
        NativeWindow,
        MacosSurfaceHost,
        MacosImeWindow,
        MacosDropWindow,
        MacosAccessibilityWindow,
        NativeHandleWindow,
        PresentPacer,
        WindowStateControl,
        NativeMenuBarWindow,
        HiddenTitleBarWindow {
  MacosWindow({
    required NativeWindowId id,
    required MacosSurfaceFactory surfaceFactory,
    required Size clientSize,
    required double renderScale,
    required double desktopScale,
    required void Function(BackendDiagnostic diagnostic) onDiagnostic,
    required void Function(MacosWindow window) onClosed,
    bool globalSurfaces = false,
    int slotCount = 3,
    MacosHostStarter? hostStarter,
    MacosSurfacePoolAttacher? poolAttacher,
  })  : _id = id,
        _surfaceFactory = surfaceFactory,
        _clientSize = clientSize,
        _renderScale = renderScale,
        _desktopScale = desktopScale,
        _onDiagnostic = onDiagnostic,
        _onClosed = onClosed,
        _globalSurfaces = globalSurfaces,
        _slotCount = slotCount,
        _hostStarter = hostStarter,
        _poolAttacher = poolAttacher;

  final NativeWindowId _id;
  final MacosSurfaceFactory _surfaceFactory;
  final void Function(BackendDiagnostic diagnostic) _onDiagnostic;
  final void Function(MacosWindow window) _onClosed;
  final bool _globalSurfaces;
  final int _slotCount;
  final MacosHostStarter? _hostStarter;
  final MacosSurfacePoolAttacher? _poolAttacher;

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

  bool _titleBarHidden = false;
  final ValueNotifier<Rect> _systemButtons = ValueNotifier<Rect>(Rect.zero);
  double _titleBarHeight = 0;

  @override
  bool get isTitleBarHidden => _titleBarHidden;

  @override
  ValueNotifier<Rect> get systemButtons => _systemButtons;

  @override
  double get titleBarHeight => _titleBarHeight;

  @override
  bool beginMove() {
    if (isDisposed || !_titleBarHidden) return false;
    return _supervisor?.send(HostCommands.beginDrag()) ?? false;
  }

  @override
  void toggleMaximized() {
    requestState(_state == WindowState.maximised
        ? WindowState.normal
        : WindowState.maximised);
  }

  void _onTitleBar(
      double x, double y, double width, double height, double titleBarHeight) {
    _titleBarHeight = titleBarHeight;
    _systemButtons.value = width <= 0 || height <= 0
        ? Rect.zero
        : Rect.fromLTWH(x, y, width, height);
  }

  Offset _screenPosition = Offset.zero;
  bool _resizeInFlight = false;
  bool _closed = false;
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

  /// The current host's pasteboard channel, when it has one that works.
  ///
  /// Null between hosts (during recovery) and for a host too old to have
  /// announced `clipboard`. Read every time rather than cached, because a
  /// recovered window has a different process behind it.
  MacosClipboardChannel? get clipboardChannel {
    final MacosHostProcessHandle? host = _supervisor?.host;
    if (host is! MacosClipboardChannel) return null;
    final MacosClipboardChannel channel = host as MacosClipboardChannel;
    return channel.supportsClipboard ? channel : null;
  }

  List<ScreenInfo> get hostScreens => <ScreenInfo>[
        for (final MacosHostScreen screen
            in _supervisor?.handshake?.screens ?? const <MacosHostScreen>[])
          ScreenInfo(
            bounds: Rect.fromLTWH(
              screen.x,
              screen.y,
              screen.width,
              screen.height,
            ),
            workArea: Rect.fromLTWH(
              screen.workX,
              screen.workY,
              screen.workWidth,
              screen.workHeight,
            ),
            scale: screen.scale,
            isPrimary: screen.isPrimary,
            name: screen.name,
          ),
      ];

  /// How many times the host has been replaced under this window.
  int get hostRestartCount => _supervisor?.restartCount ?? 0;

  MacosSurfaceHandoff? get surfaceHandoff => _supervisor?.activeHandoff;

  /// The pool, for a renderer that wants the zero-copy path.
  MacosSurfacePool? get pool => _pool;

  set inputListener(MacosInputListener? listener) => _inputListener = listener;

  /// The focused field's input method connection, set by
  /// [MacosTextInputBackend.attach]. See `macos_text_input.dart`.
  @override
  MacosImeHandler? imeHandler;

  @override
  bool sendImeCommand(String command) {
    if (!command.startsWith('IME_')) {
      throw ArgumentError.value(command, 'command', 'not an IME_ command');
    }
    return _supervisor?.send(command) ?? false;
  }

  /// Opaque, as [NativeHandleWindow] says: the window's id, because the
  /// `NSWindow` is in the host process and its number changes when a host is
  /// restarted. It keys the accessibility bridge, which is in this process.
  @override
  int get nativeHandle => _id.value;

  @override
  MacosWindowAccessibility? accessibility;

  @override
  bool sendAccessibilityCommand(String command) {
    if (!command.startsWith('A11Y_')) {
      throw ArgumentError.value(command, 'command', 'not an A11Y_ command');
    }
    return _supervisor?.send(command) ?? false;
  }

  /// The view's accessibility tree as a client reads it, one line per element
  /// (`<depth>:<role>:<label>:<value>`, base64 text), for a probe.
  Future<List<String>> debugAccessibilityDump() {
    final Completer<List<String>> done = Completer<List<String>>();
    _accessibilityDump = <String>[];
    _accessibilityDumpDone = done;
    synthesizeInput('SYNTH_A11Y_DUMP');
    return done.future.timeout(const Duration(seconds: 5));
  }

  /// Presses the first element labelled [label] the way VoiceOver does
  /// (`accessibilityPerformPress`), for a probe. Completes with whether the
  /// host found and pressed one.
  Future<bool> debugAccessibilityPress(String label) {
    final Completer<bool> done = Completer<bool>();
    _accessibilityPressDone = done;
    synthesizeInput('SYNTH_A11Y_PRESS ${base64.encode(utf8.encode(label))}');
    return done.future.timeout(const Duration(seconds: 5));
  }

  List<String>? _accessibilityDump;
  Completer<List<String>>? _accessibilityDumpDone;
  Completer<bool>? _accessibilityPressDone;

  void _onAccessibilityDump(String line) {
    if (line.startsWith('PRESS:')) {
      _accessibilityPressDone?.complete(line == 'PRESS:YES');
      _accessibilityPressDone = null;
      return;
    }
    final List<String>? lines = _accessibilityDump;
    if (lines == null) return;
    if (line == 'END') {
      _accessibilityDump = null;
      _accessibilityDumpDone?.complete(lines);
      _accessibilityDumpDone = null;
      return;
    }
    lines.add(line);
  }

  /// The drop target registered on this window, if any. See
  /// `macos_drag_drop.dart`.
  @override
  MacosDropTarget? dropTarget;

  @override
  bool sendDropCommand(String command) {
    if (!command.startsWith('DROP_') && !command.startsWith('DRAG_START ')) {
      throw ArgumentError.value(
          command, 'command', 'not a DROP_ or DRAG_START command');
    }
    return _supervisor?.send(command) ?? false;
  }

  /// Posts a synthetic `NSEvent` into the host's own event queue.
  ///
  /// For smokes: `tool/macos_input_smoke.dart` drives clicks, keys and scrolls
  /// through the real dequeue and event monitor with it, because a synthetic
  /// event from another process needs accessibility permission and never
  /// arrived on the machine this was written on. Accepts only the `SYNTH_`
  /// commands the host documents above `synthesize:`, so it cannot be used to
  /// send anything else down the pipe. Returns false when there is no host.
  bool synthesizeInput(String command) {
    if (!command.startsWith('SYNTH_') || command.contains('\n')) {
      throw ArgumentError.value(command, 'command', 'not a SYNTH_ command');
    }
    return _supervisor?.send('$command\n') ?? false;
  }

  /// Brings the window up: starts hidden, reads its scale, then attaches pixels.
  ///
  /// The handshake must come first because it carries the backing scale. The
  /// host starts hidden so a Retina window never flashes a temporary 1x pool.
  Future<bool> open({
    required MacosHostSpawnOptions spawnOptions,
    MacosRecoveryPolicy policy = const MacosRecoveryPolicy(),
    MacosSurfaceHandoff handoff = MacosSurfaceHandoff.rendezvous,
  }) async {
    throwIfDisposed();
    _titleBarHidden = spawnOptions.decorated && spawnOptions.titleBarHidden;
    _transient = spawnOptions.kind == MacosHostWindowKind.popup ||
        spawnOptions.kind == MacosHostWindowKind.tooltip;
    final supervisor = MacosHostSupervisor(
      spawnOptions: MacosHostSpawnOptions(
        binaryPath: spawnOptions.binaryPath,
        logicalWidth: spawnOptions.logicalWidth,
        logicalHeight: spawnOptions.logicalHeight,
        title: spawnOptions.title,
        x: spawnOptions.x,
        y: spawnOptions.y,
        visible: false,
        decorated: spawnOptions.decorated,
        titleBarHidden: spawnOptions.titleBarHidden,
        resizable: spawnOptions.resizable,
        kind: spawnOptions.kind,
        handshakeTimeout: spawnOptions.handshakeTimeout,
      ),
      sink: _HostSink(this),
      onDiagnostic: _onDiagnostic,
      onHostReplaced: _onHostReplaced,
      onRecoveryExhausted: _onRecoveryExhausted,
      policy: policy,
      handoff: handoff,
      starter: _hostStarter,
      poolAttacher: _poolAttacher,
    );
    _supervisor = supervisor;
    final started = await supervisor.start();
    if (!started) return false;

    final handshakeScale = supervisor.handshake?.renderScale ?? _renderScale;
    if (handshakeScale > 0) {
      _renderScale = handshakeScale;
      _desktopScale = handshakeScale;
    }
    final pool = _allocatePool();
    if (pool == null) {
      await supervisor.stop();
      return false;
    }
    _pool = pool;
    _descriptor = pool.describe(_renderScale, host: this);
    if (!await supervisor.attachPool(pool)) {
      pool.dispose();
      _pool = null;
      _descriptor = null;
      await supervisor.stop();
      return false;
    }
    supervisor.rememberTitle(spawnOptions.title);
    supervisor.rememberVisibility(spawnOptions.visible);
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
    // The final event is queued before dispose, so listeners can still read
    // the window's last geometry. Native ownership ends once the host stops,
    // even if an old host omitted WINDOW=CLOSED while terminating.
    unawaited(_shutdown().whenComplete(_emitClosed));
  }

  @override
  void setTitle(String value) {
    // Newlines would end the command early and let the rest of the title be
    // parsed as commands. Stripping is cheaper to reason about than escaping.
    _supervisor
        ?.rememberTitle(value.replaceAll('\n', ' ').replaceAll('\r', ' '));
  }

  /// A menu or tooltip panel, which has no zoom box and no full screen.
  bool _transient = false;

  /// `zoom:`, `miniaturize:` and `toggleFullScreen:` in the host. The
  /// numbering is [WindowState]'s own, which the host's `WINDOW=STATE` already
  /// uses. Full screen animates, so its answer comes a moment later.
  @override
  bool requestState(WindowState state) {
    if (isDisposed || _transient) return false;
    return _supervisor?.send(HostCommands.setState(state.index)) ?? false;
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

  /// The menus in the menu bar, as last sent; null for none.
  String? _menuJson;
  int _menuGeneration = 0;
  void Function(int id)? _onMenuSelected;

  @override
  void setNativeMenuBar(
    List<NativeMenu>? menus,
    void Function(int id) onSelected,
  ) {
    _onMenuSelected = onSelected;
    final String? json = menus == null ? null : encodeMacosMenus(menus);
    if (json == _menuJson || isDisposed) return;
    _menuJson = json;
    // A new generation each time: an item id is only meaningful in the menus
    // it was sent with, and a click can cross a replacement on the pipe.
    _supervisor?.rememberMenu(++_menuGeneration, json);
  }

  void _onMenuAction(int generation, int id) {
    if (generation != _menuGeneration) return;
    _onMenuSelected?.call(id);
  }

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
    final MacosHostProcessHandle? host = _supervisor?.host;
    final bool paced = _presentMode == PresentMode.fifo &&
        host is MacosVsyncChannel &&
        (host as MacosVsyncChannel).supportsVsync;
    if (paced) {
      // FIFO: at most one present per refresh. This frame goes out once the
      // previous one has reached the screen - the bound a swap chain's
      // present puts on a loop that asks for a frame every frame, which an
      // IOSurface present, a line on a pipe, otherwise does not have.
      final Future<bool>? previous = _pendingVsync;
      _pendingVsync = null;
      if (previous != null) await previous;
      // A resize or a close while waiting replaced or released the pool;
      // this frame was drawn for the old one.
      if (isDisposed || !identical(_pool, pool)) {
        return const PresentResult(status: PresentStatus.stale);
      }
    }
    final slot = pool.backSlot;
    final sequence = pool.markPresented(slot);
    final sent = await _supervisor!.present(slot, sequence, vsync: paced);
    if (sent && paced) {
      _pendingVsync =
          (host as MacosVsyncChannel).awaitVsync(sequence, kMacosVsyncTimeout);
    }
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

  /// Presents a back buffer the caller filled by other means.
  ///
  /// The GPU path of ADR 0005. [present] copies a [Framebuffer] in and
  /// [drawAndPresent] runs a CPU closure over the surface's own memory; this
  /// one assumes the pixels are **already there** because Metal wrote them
  /// straight into the `IOSurface`, and only does the bookkeeping and the
  /// `PRESENT_SLOT`.
  ///
  /// The caller is responsible for the ordering that makes this safe: `commit`
  /// enqueues and does not complete, so a presenter that called this straight
  /// after committing would hand the host a half-written surface.
  /// `MetalWindowTarget` waits on `addCompletedHandler:` first.
  @override
  Future<PresentResult> presentBackBuffer({required int generation}) {
    final PresentResult? stale = _rejectStale(generation);
    if (stale != null) return Future<PresentResult>.value(stale);
    return _presentBackBuffer(_pool!);
  }

  // --- pacing ----------------------------------------------------------------

  PresentMode _presentMode = PresentMode.fifo;

  /// The refresh the last paced present is waiting for, or null.
  Future<bool>? _pendingVsync;

  /// FIFO, paced by the host's display link, and immediate. Not
  /// `mailbox`: the host shows whatever `layer.contents` holds at the
  /// refresh, so there is no queue to replace a frame in.
  @override
  Set<PresentMode> get supportedPresentModes =>
      const <PresentMode>{PresentMode.fifo, PresentMode.immediate};

  @override
  PresentMode get presentMode => _presentMode;

  @override
  PresentModeOutcome requestPresentMode(PresentMode mode) {
    if (supportedPresentModes.contains(mode)) {
      _presentMode = mode;
      if (mode == PresentMode.immediate) _pendingVsync = null;
      return PresentModeOutcome.honoured(mode);
    }
    return PresentModeOutcome.refused(
      mode,
      applied: _presentMode,
      reason: 'the AppKit host shows whatever the layer holds at each '
          'refresh; there is no present queue for mailbox to replace a frame '
          'in',
    );
  }

  /// False always: under FIFO the wait is inside the present itself, which
  /// holds a frame until the previous one has reached the screen, so a second
  /// wait here would halve the frame rate rather than pace it.
  @override
  bool awaitVerticalBlank() => false;

  @override
  MacosSurfacePool? get currentPool => _pool;

  /// Whether a present would reach a host at all. See [MacosSurfaceHost].
  @override
  bool get isPresentable =>
      !isDisposed &&
      _pool != null &&
      !_resizeInFlight &&
      _supervisor?.host != null;

  @override
  int get presentGeneration => _generation.current;

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
      case HostWindowEventKind.pointerEntered:
        _emit(WindowPointerEnterEvent(
          windowId: _id,
          generation: _generation.current,
        ));
      case HostWindowEventKind.pointerLeft:
        _emit(WindowPointerLeaveEvent(
          windowId: _id,
          generation: _generation.current,
        ));
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
        if (index >= 0 &&
            index < WindowState.values.length &&
            WindowState.values[index] != _state) {
          _state = WindowState.values[index];
          _emit(
            WindowStateChangedEvent(
              windowId: _id,
              generation: _generation.current,
              state: _state,
            ),
          );
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
    final pixelsChanged = _pool != null &&
        ((width * scale).round() != _pool!.surfaces.first.width ||
            (height * scale).round() != _pool!.surfaces.first.height);

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
    if (changed && _pool != null) {
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
    var attachedNew = false;
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
      _descriptor = pool.describe(_renderScale, host: this);
      previous?.dispose();
      attachedNew = true;
    } finally {
      _resizeInFlight = false;
    }
    // A failed attach waits for the next resize, as before - retrying here
    // would spin on a machine that cannot allocate.
    if (isDisposed || !attachedNew) return;
    // A zoom, a double-click on the title bar or a live resize sends a burst
    // of sizes while this was attaching; they were not dropped silently but
    // deferred to here. Chase the size the window has *now* - stopping at the
    // first one left surfaces from mid-animation, every frame was rejected
    // for the wrong size and the window stayed white.
    if (_poolStale) {
      _generation.invalidate();
      unawaited(_reallocate());
      return;
    }
    // The surfaces finally match. Announce them as a resize under the new
    // generation: the resize sent while they were being made pointed the
    // presenter at the pool being replaced, and it rebinds on this one.
    _emit(
      WindowResizedEvent(
        windowId: _id,
        generation: _generation.current,
        clientSize: _clientSize,
        renderScale: _renderScale,
      ),
    );
  }

  /// Whether the pool's pixel size differs from what the window needs.
  bool get _poolStale {
    final pool = _pool;
    if (pool == null) return false;
    return (_clientSize.width * _renderScale).round() !=
            pool.surfaces.first.width ||
        (_clientSize.height * _renderScale).round() !=
            pool.surfaces.first.height;
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
    if (_closed || _events.isClosed) return;
    _closed = true;
    _generation.invalidate();
    _events.add(
      WindowClosedEvent(windowId: _id, generation: _generation.current),
    );
    _onClosed(this);
    dispose();
  }

  /// Host input, as framework input. See `macos_input.dart`.
  ///
  /// Until this existed the probe reported keyboard, pointer and scroll input
  /// for this backend while nothing in `lib/` turned an `INPUT=` line into an
  /// event: the lines reached [inputListener], which only the latency tools
  /// set, and a window could be neither clicked nor typed into.
  void _onInputDetail(HostInputDetail detail) {
    if (detail.kind == HostInputKind.keyDown) {
      _lastKeyDownMachTime = detail.machTime;
    }
    translateMacosInput(
      detail,
      windowId: _id,
      generation: _generation.current,
      emit: _emit,
    );
  }

  /// The key press a `TEXT_INPUT=` line belongs to: the host prints the text
  /// straight after the `INPUT=keyDown` that produced it.
  int _lastKeyDownMachTime = 0;

  void _onTextInput(String base64) {
    final String? text = macosTextInput(base64);
    if (text == null) return;
    _emit(TextInputEvent(
      windowId: _id,
      generation: _generation.current,
      timestamp: macosMachTimeToDuration(_lastKeyDownMachTime),
      text: text,
    ));
  }

  void _onComposition(String base64, int selectedLocation, int length) {
    final String? text = decodeImeText(base64);
    if (text == null) return;
    imeHandler?.onComposition(text, selectedLocation, length);
  }

  /// Text that ends a composition. To the focused client when one is
  /// enabled; otherwise typing, like `TEXT_INPUT` - a dead key resolved while
  /// no field had an input method connection still types its letter.
  void _onCommit(String base64) {
    final MacosImeHandler? handler = imeHandler;
    if (handler != null && handler.isEnabled) {
      final String? text = decodeImeText(base64);
      if (text != null && text.isNotEmpty) handler.onCommit(text);
      return;
    }
    _onTextInput(base64);
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
  void onTitleBar(double x, double y, double width, double height,
          double titleBarHeight) =>
      _window._onTitleBar(x, y, width, height, titleBarHeight);

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

  @override
  void onInputDetail(HostInputDetail detail) => _window._onInputDetail(detail);

  @override
  void onTextInput(String base64) => _window._onTextInput(base64);

  @override
  void onComposition(String base64, int selectedLocation, int selectedLength) =>
      _window._onComposition(base64, selectedLocation, selectedLength);

  @override
  void onCommit(String base64) => _window._onCommit(base64);

  @override
  void onImeDelete(int before, int after) =>
      _window.imeHandler?.onDeleteSurrounding(before, after);

  @override
  void onDragItem(String kind, String base64) =>
      _window.dropTarget?.onItem(kind, base64);

  @override
  void onDrag(HostDragPhase phase, double x, double y, int mask, int flags) =>
      _window.dropTarget?.onDrag(phase, x, y, mask, flags);

  @override
  void onDragSourceEnd(int request, int operation) =>
      macosDragSourceEnded(request, operation);

  @override
  void onAccessibilityRequested() => _window.accessibility?.onRequested();

  @override
  void onAccessibilityAction(int node, String action) =>
      _window.accessibility?.onAction(node, action);

  @override
  void onAccessibilityDump(String line) => _window._onAccessibilityDump(line);

  @override
  void onMenuAction(int generation, int id) =>
      _window._onMenuAction(generation, id);
}

/// The default factory: real `IOSurface`s.
///
/// [global] carries a security decision. A global surface is visible to every
/// process on the machine. Production passes false because its only supported
/// handoff is a Mach port. The flag remains explicit for diagnostics and
/// experiments that deliberately exercise deprecated `IOSurfaceLookup`.
MacosSurfacePool createIOSurfacePool({
  required int pixelWidth,
  required int pixelHeight,
  required bool global,
  // Three, so a slot the window server is still compositing never has to
  // be written - see MacosSurfacePool._nextWritable.
  int slotCount = 3,
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
