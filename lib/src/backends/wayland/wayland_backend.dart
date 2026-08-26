/// The Wayland windowing backend, per section 16 of the roadmap.
///
/// This is the Wayland entry point: it implements [WindowingBackend], opens
/// the compositor socket at `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY`, performs the
/// registry handshake, owns the display connection, routes events to windows
/// and exposes a retained `wl_shm` CPU framebuffer.
///
/// The protocol is spoken natively: pure-Dart marshalling over a unix socket,
/// with FFI only where `dart:io` cannot go (SCM_RIGHTS fd passing, memfd,
/// mmap). No libwayland-client is loaded, which is the roadmap's premise for
/// this backend taken one step further than the XML generator it sketches -
/// the handful of interfaces needed were transcribed by hand instead.
///
/// ## Probe policy
///
/// Section 15.4's rule is applied verbatim: *never assume Wayland just
/// because the variable exists - test the connection*. The probe resolves the
/// socket path from `WAYLAND_DISPLAY`/`XDG_RUNTIME_DIR` (with the `wayland-0`
/// default when `XDG_SESSION_TYPE=wayland` says a session is there), connects
/// and completes the registry handshake before reporting support. A machine
/// where that fails falls through to the X11 backend with the reason on
/// record.
///
/// ## What this cannot do yet, said plainly
///
///   * **Keyboard input is the minimal xkb subset.** First group, two shift
///     levels, no dead keys, no compose and no IME. Client-side key repeat is
///     driven by `wl_keyboard.repeat_info`; unresolvable keys deliver
///     [KeyEvent]s but never guessed text. `wayland_keymap.dart` carries the
///     details.
///   * **Client-side decorations are negotiated but not drawn here.**
///     `zxdg_decoration_manager_v1` is used to ask for a server-side frame;
///     when the compositor has no such protocol (GNOME) the window reports
///     [WaylandWindow.hasServerSideDecorations] as false and the framework
///     must draw its own frame. Nothing in this backend paints one.
///   * **Drag and drop carries no drag icon.** Receiving is complete and
///     starting a drag works, but `DragRequest.feedback` is ignored: a drag
///     icon is a `wl_surface` with an shm buffer of its own, which
///     `wayland_drag_drop_backend.dart` names in a TODO rather than emulating
///     badly. The compositor's own cursor is used instead.
///   * **No touch, no primary selection, no fractional scale.** `wl_touch`,
///     `zwp_primary_selection_v1` and `wp_fractional_scale_v1` are unbound;
///     scaling is integer only.
///
/// What *is* wired end to end: xdg-shell toplevels and popups, `wl_shm`
/// presentation with a release-driven buffer swapchain, `wl_surface.frame`
/// pacing, clipboard text, key repeat, and pointer cursors loaded from the
/// user's XCursor theme.
library;

import 'dart:async';
import 'dart:io' show File, Platform;

import '../../foundation/diagnostics.dart';
import '../../platform/clipboard.dart';
import '../../platform/compose_sequences.dart';
import '../../platform/compose_sequences_platform_stub.dart'
    if (dart.library.io) '../../platform/compose_sequences_platform_io.dart'
    as compose_platform;
import '../../platform/drag_drop.dart';
import '../../platform/native_window.dart';
import '../../platform/text_input.dart';
import '../../platform/window_events.dart';
import 'wayland_clipboard.dart';
import 'wayland_connection.dart';
import 'wayland_cursor.dart';
import 'wayland_cursor_theme.dart';
import 'wayland_drag_drop.dart';
import 'wayland_drag_drop_backend.dart';
import 'wayland_events.dart';
import 'wayland_key_repeat.dart';
import 'wayland_libc.dart';
import 'wayland_memfd.dart';
import 'wayland_protocol.dart';
import 'wayland_shm.dart';
import 'wayland_text_input.dart';
import 'wayland_transport.dart';
import 'wayland_window.dart';

/// Opens one Wayland connection for the socket at [socketPath].
///
/// Public only because `src/` backends are tested directly; production code
/// uses the default supplied by [WaylandWindowingBackend].
typedef WaylandConnectionOpener = WaylandConnectionAttempt Function(
  String socketPath,
);

/// Where the compositor socket is, or why it could not be determined.
final class WaylandSocketPathResolution {
  const WaylandSocketPathResolution({required this.path, required this.detail});

  /// Null when no Wayland session is indicated; [detail] then names the gap.
  final String? path;
  final String detail;
}

/// Resolves the socket path the way libwayland does: `WAYLAND_DISPLAY` may be
/// a name under `$XDG_RUNTIME_DIR` or an absolute path; when it is unset, a
/// session that declares `XDG_SESSION_TYPE=wayland` gets the `wayland-0`
/// default. No variable at all means no Wayland - that is the X11 fallback
/// signal, not an error.
WaylandSocketPathResolution resolveWaylandSocketPath(
  Map<String, String> environment,
) {
  String? read(String name) {
    final value = environment[name];
    if (value == null || value.trim().isEmpty) return null;
    return value.trim();
  }

  var display = read('WAYLAND_DISPLAY');
  var defaulted = false;
  if (display == null) {
    final sessionType = read('XDG_SESSION_TYPE')?.toLowerCase();
    if (sessionType == 'wayland') {
      display = 'wayland-0';
      defaulted = true;
    } else {
      return const WaylandSocketPathResolution(
        path: null,
        detail: 'WAYLAND_DISPLAY not set and XDG_SESSION_TYPE is not wayland',
      );
    }
  }
  if (display.startsWith('/')) {
    return WaylandSocketPathResolution(
      path: display,
      detail: 'WAYLAND_DISPLAY is an absolute path',
    );
  }
  final runtimeDir = read('XDG_RUNTIME_DIR');
  if (runtimeDir == null) {
    return WaylandSocketPathResolution(
      path: null,
      detail: 'XDG_RUNTIME_DIR not set; cannot locate socket "$display"',
    );
  }
  return WaylandSocketPathResolution(
    path: '$runtimeDir/$display',
    detail: defaulted
        ? 'XDG_SESSION_TYPE=wayland with the wayland-0 default'
        : 'WAYLAND_DISPLAY=$display',
  );
}

/// Creates and owns Wayland windows.
final class WaylandWindowingBackend
    implements
        WindowingBackend,
        ClipboardProvider,
        DragDropProvider,
        TextInputProvider {
  WaylandWindowingBackend({
    bool? isLinux,
    String? operatingSystem,
    Map<String, String>? environment,
    WaylandConnectionOpener? connectionOpener,
    int Function()? monotonicMilliseconds,
  })  : _isLinux = isLinux ?? Platform.isLinux,
        _operatingSystem = operatingSystem ?? Platform.operatingSystem,
        _environment = Map<String, String>.unmodifiable(
          environment ?? Platform.environment,
        ),
        _connectionOpener = connectionOpener ?? _openNativeConnection,
        _monotonicMilliseconds =
            monotonicMilliseconds ?? _defaultMonotonicMilliseconds;

  static final Stopwatch _monotonicClock = Stopwatch()..start();
  static int _defaultMonotonicMilliseconds() =>
      _monotonicClock.elapsedMilliseconds;

  @override
  String get name => 'wayland';

  final List<WaylandWindow> _windows = <WaylandWindow>[];
  final Map<int, WaylandWindow> _windowsBySurfaceId = <int, WaylandWindow>{};
  final List<BackendDiagnostic> _diagnostics = <BackendDiagnostic>[];
  final bool _isLinux;
  final String _operatingSystem;
  final Map<String, String> _environment;
  final WaylandConnectionOpener _connectionOpener;
  final int Function() _monotonicMilliseconds;

  WaylandWindowClient? _connection;
  final WaylandRawEvent _rawEvent = WaylandRawEvent();
  final WaylandKeyRepeat _keyRepeat = WaylandKeyRepeat();
  int _nextWindowId = 1;
  bool _initialized = false;
  bool _quitRequested = false;
  bool _serverDisconnected = false;
  bool _supportsCpuPresentation = false;
  bool _supportsClipboard = false;
  bool _supportsDragAndDrop = false;
  bool _supportsTextInput = false;

  /// The machine's Compose table, read once at [initialize].
  ///
  /// Read once rather than per window because it is a file on disk that does
  /// not change while the application runs, and parsing the standard
  /// `en_US.UTF-8` table is a few thousand lines.
  ComposeTable _composeTable = ComposeTable.empty;
  WaylandDragDropBackend? _dragDrop;
  WaylandTextInputBackend? _textInput;

  @override
  Clipboard get clipboard {
    final Object? candidate = _connection;
    if (candidate case final WaylandSelectionClient client
        when client.supportsClipboard) {
      return WaylandClipboard(client);
    }
    return const UnavailableClipboard(
      'the active Wayland compositor exposes no usable '
      'wl_data_device_manager clipboard',
    );
  }

  /// Drag and drop over `wl_data_device`, or a named refusal.
  ///
  /// Only ever non-[UnavailableDragDrop] after [initialize] has run: unlike
  /// the clipboard, whose whole state is one round trip, a drag needs the
  /// manager to be listening from the first `data_offer` the compositor sends,
  /// and installing it at probe time would attach a state machine to a
  /// connection that is about to be closed.
  @override
  DragDropBackend get dragAndDrop {
    final WaylandDragDropBackend? backend = _dragDrop;
    if (backend != null) return backend;
    return const UnavailableDragDrop(
      name: 'wayland',
      reason: 'the active Wayland compositor exposes no usable '
          'wl_data_device_manager, so no drop can be received and no drag '
          'started',
    );
  }

  /// Input methods over `zwp_text_input_v3`, or a named refusal.
  ///
  /// Only ever non-[UnavailableTextInput] after [initialize], for
  /// [dragAndDrop]'s reason: the state machine has to be listening from the
  /// compositor's first `enter`, and installing it at probe time would attach
  /// it to a connection that is about to be closed.
  ///
  /// **A refusal here is not a keyboard that does not work.** Plain typing
  /// comes from `wl_keyboard` and the xkb subset in `wayland_keymap.dart`;
  /// what is missing without this is composition - CJK, and any method that
  /// needs a preedit.
  @override
  TextInputBackend get textInput {
    final WaylandTextInputBackend? backend = _textInput;
    if (backend != null) return backend;
    return const UnavailableTextInput(
      name: 'wayland',
      reason: 'the active Wayland compositor advertises no '
          'zwp_text_input_manager_v3, so no input method can be reached; '
          'plain typing still works through wl_keyboard',
    );
  }

  /// Everything worth noting since probe/init.
  List<BackendDiagnostic> get diagnostics =>
      List<BackendDiagnostic>.unmodifiable(_diagnostics);

  /// The interface names the compositor's registry advertised on the live
  /// connection, empty before [initialize] and after [shutdown].
  ///
  /// Exists for the same reason the X11 backend exposes its keyboard state:
  /// a smoke test running against a real compositor has to be able to say
  /// *which* compositor answered and with what, and the probe diagnostics
  /// summarise only three of the globals.
  Set<String> get globalInterfaces =>
      _connection?.globalInterfaces ?? const <String>{};

  /// Whether `wl_keyboard.keymap` arrived and parsed into a usable map.
  ///
  /// False means the compositor sent no keymap, or the fd it passed through
  /// `SCM_RIGHTS` could not be mapped or decoded; key events then carry their
  /// evdev code and no text. Named after the X11 backend's getter because it
  /// answers the same question.
  bool get hasKeyboardMap => _connection?.keymap != null;

  // ---------------------------------------------------------------------------
  // Probe
  // ---------------------------------------------------------------------------

  @override
  BackendProbeResult probe() {
    if (!_isLinux) {
      return _recordProbe(BackendProbeResult.unsupported(
        name,
        BackendDiagnostic(
          kind: DiagnosticKind.unsupportedPlatform,
          message: 'wayland needs Linux',
          detail: 'Platform.operatingSystem=$_operatingSystem',
        ),
      ));
    }

    final diagnostics = <BackendDiagnostic>[];
    final resolution = resolveWaylandSocketPath(_environment);
    final path = resolution.path;
    if (path == null) {
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'no Wayland session detected',
        detail: resolution.detail,
      ));
      return _recordProbe(_probeResult(false, diagnostics));
    }
    diagnostics.add(BackendDiagnostic.note(
      'Wayland socket: $path',
      detail: resolution.detail,
    ));

    final attempt = _tryOpen(path);
    diagnostics.addAll(attempt.diagnostics);
    final connection = attempt.connection;
    var supported = false;
    try {
      if (connection != null && connection.isValid) {
        _inspectConnection(connection, diagnostics);
        supported = connection is WaylandWindowClient && connection.isValid;
        if (!supported) {
          diagnostics.add(const BackendDiagnostic(
            kind: DiagnosticKind.rejectedByPolicy,
            message: 'Wayland connection has no window protocol client',
          ));
        }
      } else if (connection != null) {
        diagnostics.add(const BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'Wayland connection became invalid during probe',
        ));
      }
    } on Object catch (error) {
      supported = false;
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'failed to inspect Wayland connection',
        detail: '$error',
      ));
    } finally {
      try {
        connection?.dispose();
      } on Object catch (error) {
        supported = false;
        diagnostics.add(BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'failed to close Wayland probe connection',
          detail: '$error',
        ));
      }
    }
    return _recordProbe(_probeResult(supported, diagnostics));
  }

  // ---------------------------------------------------------------------------
  // Initialize / Shutdown
  // ---------------------------------------------------------------------------

  @override
  Future<void> initialize() async {
    if (_initialized) return;

    final resolution = _isLinux ? resolveWaylandSocketPath(_environment) : null;
    if (resolution?.path == null) {
      final result = probe();
      throw BackendSelectionError(
          requested: name, attempts: <BackendProbeResult>[result]);
    }

    final path = resolution!.path!;
    final diagnostics = <BackendDiagnostic>[
      BackendDiagnostic.note('Wayland socket: $path',
          detail: resolution.detail),
    ];
    final attempt = _tryOpen(path);
    diagnostics.addAll(attempt.diagnostics);
    final candidate = attempt.connection;
    final connection = candidate is WaylandWindowClient ? candidate : null;
    if (connection == null || !connection.isValid) {
      candidate?.dispose();
      if (candidate != null) {
        diagnostics.add(const BackendDiagnostic(
          kind: DiagnosticKind.rejectedByPolicy,
          message: 'Wayland connection cannot create toplevel windows',
        ));
      }
      final result = _recordProbe(_probeResult(false, diagnostics));
      throw BackendSelectionError(
          requested: name, attempts: <BackendProbeResult>[result]);
    }

    try {
      _inspectConnection(connection, diagnostics);
    } on Object catch (error) {
      connection.dispose();
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'failed to initialize Wayland connection',
        detail: '$error',
      ));
      final result = _recordProbe(_probeResult(false, diagnostics));
      throw BackendSelectionError(
          requested: name, attempts: <BackendProbeResult>[result]);
    }

    _installCursorManager(connection, diagnostics);
    if (connection is WaylandConnection && connection.supportsDragAndDrop) {
      final WaylandDragDropManager manager = WaylandDragDropManager(connection);
      connection.dragDrop = manager;
      _dragDrop = WaylandDragDropBackend(manager);
      diagnostics.add(const BackendDiagnostic.note(
        'drag and drop is available through wl_data_device',
        detail: 'reachable as DragDropProvider.dragAndDrop; drag icons '
            '(DragRequest.feedback) are not drawn',
      ));
    } else {
      _dragDrop = null;
    }
    if (connection is WaylandConnection && connection.supportsTextInput) {
      final WaylandTextInputManager manager =
          WaylandTextInputManager(connection);
      connection.textInput = manager;
      _textInput = WaylandTextInputBackend(manager);
      diagnostics.add(const BackendDiagnostic.note(
        'input methods are available through zwp_text_input_v3',
        detail: 'reachable as TextInputProvider.textInput; v3 carries no '
            'preedit styling, so the whole preedit is underlined as one run',
      ));
    } else {
      _textInput = null;
    }
    if (!_supportsTextInput) {
      _composeTable = compose_platform.loadSystemComposeTable();
      diagnostics.add(BackendDiagnostic.note(
        _composeTable.isEmpty
            ? 'no X11 Compose table was found; dead keys will not compose'
            : 'dead keys compose from the X11 Compose table '
                '(${_composeTable.sequenceCount} sequences, '
                '${_composeTable.skippedSequences} lines not understood)',
      ));
    } else {
      _composeTable = ComposeTable.empty;
    }
    diagnostics.add(const BackendDiagnostic.note(
      'Wayland window lifecycle initialized',
      detail: 'xdg-shell toplevels with wl_shm presentation',
    ));
    _connection = connection;
    _initialized = true;
    _quitRequested = false;
    _serverDisconnected = false;
    _replaceDiagnostics(diagnostics);
  }

  @override
  Future<void> shutdown() async {
    if (!_initialized && _connection == null) return;
    _initialized = false;
    _keyRepeat.cancel();
    // The manager dies with the connection below; dropping the port half here
    // keeps `dragAndDrop` from handing out a backend over a dead socket.
    _dragDrop = null;
    _textInput = null;

    Object? firstError;
    StackTrace? firstStack;
    for (final window in List<WaylandWindow>.of(_windows).reversed) {
      try {
        window.dispose();
      } on Object catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }
    _windows.clear();
    _windowsBySurfaceId.clear();

    final connection = _connection;
    _connection = null;
    try {
      connection?.dispose();
    } on Object catch (error, stack) {
      firstError ??= error;
      firstStack ??= stack;
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStack!);
    }
  }

  // ---------------------------------------------------------------------------
  // Windows
  // ---------------------------------------------------------------------------

  @override
  List<NativeWindow> get windows => List<NativeWindow>.unmodifiable(_windows);

  @override
  Future<NativeWindow> createWindow(WindowOptions options) async {
    _requireInitialized('createWindow');
    final connection = _connection!;
    final window = WaylandWindow.create(
      client: connection,
      id: NativeWindowId(_nextWindowId++),
      options: options,
      onClosed: _onWindowClosed,
    );
    // Dead keys, from the machine's own Compose table.
    //
    // Only when there is no input method: a compositor with
    // `zwp_text_input_v3` has one, and an input method already composes dead
    // keys itself. Running both would apply the accent twice - `´` then `a`
    // becoming `áa` or `á´` depending on which ran first - which is why this is
    // the *fallback* the roadmap's section 16.8 asks for and not an addition.
    if (!_supportsTextInput && !_composeTable.isEmpty) {
      window.composeEngine = ComposeEngine(_composeTable);
    }
    if (_windowsBySurfaceId.containsKey(window.surfaceId)) {
      window.dispose();
      throw StateError(
        'Wayland reused live surface id ${window.surfaceId}',
      );
    }
    _windows.add(window);
    _windowsBySurfaceId[window.surfaceId] = window;
    _quitRequested = false;
    return window;
  }

  // ---------------------------------------------------------------------------
  // Event pump
  // ---------------------------------------------------------------------------

  @override
  bool pumpEvents({Duration timeout = Duration.zero}) {
    _requireInitialized('pumpEvents');
    if (_quitRequested) return false;
    final connection = _connection!;
    _keyRepeat.configure(
      rateHz: connection.repeatRateHz,
      delayMilliseconds: connection.repeatDelayMilliseconds,
    );
    var drained = _drainQueuedEvents(connection);
    drained += _deliverDueRepeats();
    if (drained == 0 && timeout != Duration.zero) {
      var milliseconds = timeout.isNegative
          ? -1
          : timeout.inMicroseconds == 0
              ? 0
              : (timeout.inMicroseconds / 1000).ceil();
      final untilRepeat =
          _keyRepeat.millisecondsUntilDue(_monotonicMilliseconds());
      if (untilRepeat != null &&
          (milliseconds < 0 || untilRepeat < milliseconds)) {
        milliseconds = untilRepeat;
      }
      connection.waitForActivity(milliseconds);
      drained += _drainQueuedEvents(connection);
      drained += _deliverDueRepeats();
    }
    if (!connection.isValid) {
      if (!_serverDisconnected) {
        _serverDisconnected = true;
        _diagnostics.add(const BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'Wayland compositor connection was lost during event pump',
        ));
      }
      _quitRequested = true;
      return false;
    }
    if (drained > 0) {
      for (final window in List<WaylandWindow>.of(_windows)) {
        window.flushPendingEvents();
      }
      connection.flush();
    }
    return !_quitRequested;
  }

  int _drainQueuedEvents(WaylandWindowClient connection) {
    // A fixed budget prevents a motion flood starving Dart tasks forever.
    // Remaining events stay queued for the next pump.
    const budget = 4096;
    var drained = 0;
    while (drained < budget && connection.pollEventInto(_rawEvent)) {
      drained++;
      _updateKeyRepeat(_rawEvent);
      if (_rawEvent.surfaceId == 0) {
        // Display-wide events (an output scale change) concern every window.
        for (final window in _windows) {
          window.handleRawEvent(_rawEvent);
        }
        continue;
      }
      _windowsBySurfaceId[_rawEvent.surfaceId]?.handleRawEvent(_rawEvent);
    }
    return drained;
  }

  void _updateKeyRepeat(WaylandRawEvent raw) {
    switch (raw.type) {
      case WaylandRawEventType.keyboardKey:
        if (raw.state == wlKeyboardKeyStatePressed) {
          if (_isRepeatableEvdevKey(raw.key)) {
            _keyRepeat.onKeyDown(
              raw.key,
              raw.surfaceId,
              _monotonicMilliseconds(),
            );
          }
        } else if (raw.state == wlKeyboardKeyStateReleased) {
          _keyRepeat.onKeyUp(raw.key);
        }
      case WaylandRawEventType.keyboardLeave:
        _keyRepeat.cancel();
      case WaylandRawEventType.xdgToplevelClose:
        if (raw.surfaceId == _keyRepeat.armedSurfaceId) _keyRepeat.cancel();
      default:
        break;
    }
  }

  int _deliverDueRepeats() {
    final count = _keyRepeat.takeDueRepeats(_monotonicMilliseconds());
    if (count == 0) return 0;
    final window = _windowsBySurfaceId[_keyRepeat.armedSurfaceId];
    if (window == null) {
      _keyRepeat.cancel();
      return 0;
    }
    for (var i = 0; i < count; i++) {
      _rawEvent
        ..reset()
        ..type = WaylandRawEventType.keyboardKey
        ..surfaceId = _keyRepeat.armedSurfaceId
        ..timeMilliseconds = _monotonicMilliseconds()
        ..key = _keyRepeat.armedKey
        ..state = wlKeyboardKeyStatePressed
        ..repeat = true;
      window.handleRawEvent(_rawEvent);
    }
    return count;
  }

  /// Modifier and lock keys never auto-repeat. The evdev codes are stable;
  /// every other key is left eligible because navigation/function keys may
  /// legitimately repeat even when they produce no text.
  static bool _isRepeatableEvdevKey(int key) =>
      key != 29 && // Control_L
      key != 42 && // Shift_L
      key != 54 && // Shift_R
      key != 56 && // Alt_L
      key != 58 && // Caps_Lock
      key != 97 && // Control_R
      key != 100 && // Alt_R / AltGr
      key != 125 && // Super_L
      key != 126; // Super_R

  void _onWindowClosed(WaylandWindow window) {
    if (_keyRepeat.armedSurfaceId == window.surfaceId) _keyRepeat.cancel();
    _windowsBySurfaceId.remove(window.surfaceId);
    _windows.remove(window);
    if (_initialized && _windows.isEmpty) _quitRequested = true;
  }

  @override
  void wake() {
    _connection?.signalWake();
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  static WaylandConnectionAttempt _openNativeConnection(String socketPath) {
    final diagnostics = <BackendDiagnostic>[];
    final libc = WaylandLibc.open(diagnostics);
    if (libc == null) {
      return WaylandConnectionAttempt(
          connection: null, diagnostics: diagnostics);
    }
    final transportAttempt = WaylandSocketTransport.open(
      libc: libc,
      socketPath: socketPath,
    );
    diagnostics.addAll(transportAttempt.diagnostics);
    final transport = transportAttempt.transport;
    if (transport == null) {
      return WaylandConnectionAttempt(
          connection: null, diagnostics: diagnostics);
    }
    final attempt = WaylandConnection.open(
      transport: transport,
      allocator: WaylandMemfdAllocator(libc),
    );
    return WaylandConnectionAttempt(
      connection: attempt.connection,
      diagnostics: <BackendDiagnostic>[
        ...diagnostics,
        ...attempt.diagnostics,
      ],
    );
  }

  WaylandConnectionAttempt _tryOpen(String socketPath) {
    try {
      return _connectionOpener(socketPath);
    } on Object catch (error) {
      return WaylandConnectionAttempt(
        connection: null,
        diagnostics: <BackendDiagnostic>[
          BackendDiagnostic(
            kind: DiagnosticKind.connectionFailed,
            message: 'Wayland connection opener threw',
            detail: '$error',
          ),
        ],
      );
    }
  }

  /// Attaches a cursor manager to a live connection, if cursors are possible.
  ///
  /// Kept out of [WaylandConnection] because locating a theme is filesystem
  /// policy, not protocol: the connection knows how to upload pixels, and
  /// this decides which pixels the user asked for.
  void _installCursorManager(
    WaylandWindowClient connection,
    List<BackendDiagnostic> diagnostics,
  ) {
    if (connection is! WaylandConnection) return;
    final resolution = resolveWaylandCursorTheme(_environment);
    connection.cursorManager = WaylandCursorManager(
      client: connection,
      fileSystem: const _IoCursorFileSystem(),
      resolution: resolution,
      timer: _cursorTimer,
    );
    diagnostics.add(BackendDiagnostic.note(
      'cursor theme: ${resolution.themeName} at ${resolution.size}px',
      detail: '${resolution.searchPaths.length} search path(s); '
          'themes are read from disk on first use',
    ));
  }

  /// The animation timer for cursors. A plain [Timer] rather than the
  /// dispatcher's, because a cursor frame must keep ticking while the
  /// application is idle and the dispatcher is parked in `poll`.
  static void Function() _cursorTimer(Duration delay, void Function() tick) {
    final timer = Timer(delay, tick);
    return timer.cancel;
  }

  void _inspectConnection(
    WaylandBackendConnection connection,
    List<BackendDiagnostic> diagnostics,
  ) {
    final cpuClient =
        connection is WaylandCpuClient ? connection as WaylandCpuClient : null;
    _supportsCpuPresentation = cpuClient?.supportsShmPresentation ?? false;
    final selectionClient = connection is WaylandSelectionClient
        ? connection as WaylandSelectionClient
        : null;
    _supportsClipboard = selectionClient?.supportsClipboard ?? false;
    final dragClient = connection is WaylandDragDropClient
        ? connection as WaylandDragDropClient
        : null;
    _supportsDragAndDrop = dragClient?.supportsDragAndDrop ?? false;
    final textInputClient = connection is WaylandTextInputClient
        ? connection as WaylandTextInputClient
        : null;
    _supportsTextInput = textInputClient?.supportsTextInput ?? false;
    final globals = connection.globalInterfaces;
    diagnostics.add(BackendDiagnostic.note(
      'globals: seat=${globals.contains('wl_seat') ? "yes" : "no"}, '
      'output=${globals.contains('wl_output') ? "yes" : "no"}, '
      'decoration=${globals.contains('zxdg_decoration_manager_v1') ? "yes" : "no"}',
    ));
    diagnostics.add(BackendDiagnostic.note(
      _supportsCpuPresentation
          ? 'wl_shm ARGB8888 presentation is available'
          : 'wl_shm ARGB8888 presentation is unavailable',
    ));
    diagnostics.add(BackendDiagnostic.note(
      _supportsClipboard
          ? 'wl_data_device text clipboard is available'
          : 'wl_data_device text clipboard is unavailable',
    ));
    diagnostics.add(BackendDiagnostic.note(
      _supportsDragAndDrop
          ? 'wl_data_device drag and drop is available'
          : 'wl_data_device drag and drop is unavailable',
    ));
    diagnostics.add(BackendDiagnostic.note(
      _supportsTextInput
          ? 'zwp_text_input_v3 is available'
          : 'zwp_text_input_v3 is unavailable',
    ));
    diagnostics.add(BackendDiagnostic.note(
      'pointer motion, buttons, crossings and axis scroll are normalized; '
      'keyboard uses the minimal xkb text subset with client-side repeat '
      '(no dead keys/compose)'
      '${_supportsTextInput ? '; composition is handled by the input method '
          'through zwp_text_input_v3' : '; and no input method'}',
    ));
  }

  BackendProbeResult _probeResult(
    bool supported,
    List<BackendDiagnostic> diagnostics,
  ) {
    return BackendProbeResult(
      backendName: name,
      supported: supported,
      capabilities: supported
          ? <Capability>{
              Capability.window,
              Capability.multipleWindows,
              Capability.pointerInput,
              Capability.scrollInput,
              Capability.keyboardInput,
              Capability.orderlyShutdown,
              if (_supportsCpuPresentation) Capability.cpuPresentation,
              if (_supportsCpuPresentation) Capability.partialPresent,
              if (_supportsClipboard) Capability.clipboardText,
              if (_supportsDragAndDrop) Capability.dragAndDrop,
              if (_supportsTextInput) Capability.textComposition,
            }
          : const <Capability>{},
      diagnostics: diagnostics,
    );
  }

  BackendProbeResult _recordProbe(BackendProbeResult result) {
    _replaceDiagnostics(result.diagnostics);
    return result;
  }

  void _replaceDiagnostics(Iterable<BackendDiagnostic> diagnostics) {
    _diagnostics
      ..clear()
      ..addAll(diagnostics);
  }

  void _requireInitialized(String operation) {
    if (!_initialized) {
      throw StateError('$name.$operation before initialize()');
    }
  }

  @override
  String toString() => 'WaylandWindowingBackend(initialized: $_initialized, '
      'windows: ${_windows.length})';
}

/// The real filesystem, behind the seam the cursor loader is tested against.
final class _IoCursorFileSystem implements CursorFileSystem {
  const _IoCursorFileSystem();

  @override
  bool fileExists(String path) {
    try {
      return File(path).existsSync();
    } on Object {
      // An unreadable directory is "no cursor here", not a crash on hover.
      return false;
    }
  }

  @override
  List<int>? readFile(String path) {
    try {
      return File(path).readAsBytesSync();
    } on Object {
      return null;
    }
  }
}
