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
///   * **Frame-callback pacing is not wired.** Commits happen when the
///     framework presents; `wl_callback` is implemented for `sync` but no
///     frame throttling uses it yet.
///   * **Single shm buffer per surface.** The compositor may still be reading
///     the buffer when the next frame is rasterised into it; compositors copy
///     shm promptly so this shows as, at worst, transient tearing. A proper
///     multi-buffer swapchain keyed on `wl_buffer.release` is the next step.
///   * **Keyboard input is the minimal xkb subset.** First group, two shift
///     levels, no dead keys, no compose, no IME, no key repeat; unresolvable
///     keys deliver [KeyEvent]s but never guessed text. `wayland_keymap.dart`
///     carries the details.
///   * **No client-side decorations and no xdg-decoration.** On compositors
///     that do not draw server-side frames (GNOME) windows appear borderless.
///   * **Clipboard, drag-and-drop, cursors and popups are deferred**, exactly
///     as their X11 counterparts are.
library;

import 'dart:io' show Platform;

import '../../foundation/diagnostics.dart';
import '../../platform/native_window.dart';
import '../../platform/window_events.dart';
import 'wayland_connection.dart';
import 'wayland_events.dart';
import 'wayland_libc.dart';
import 'wayland_memfd.dart';
import 'wayland_shm.dart';
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
final class WaylandWindowingBackend implements WindowingBackend {
  WaylandWindowingBackend({
    bool? isLinux,
    String? operatingSystem,
    Map<String, String>? environment,
    WaylandConnectionOpener? connectionOpener,
  })  : _isLinux = isLinux ?? Platform.isLinux,
        _operatingSystem = operatingSystem ?? Platform.operatingSystem,
        _environment = Map<String, String>.unmodifiable(
          environment ?? Platform.environment,
        ),
        _connectionOpener = connectionOpener ?? _openNativeConnection;

  @override
  String get name => 'wayland';

  final List<WaylandWindow> _windows = <WaylandWindow>[];
  final Map<int, WaylandWindow> _windowsBySurfaceId = <int, WaylandWindow>{};
  final List<BackendDiagnostic> _diagnostics = <BackendDiagnostic>[];
  final bool _isLinux;
  final String _operatingSystem;
  final Map<String, String> _environment;
  final WaylandConnectionOpener _connectionOpener;

  WaylandWindowClient? _connection;
  final WaylandRawEvent _rawEvent = WaylandRawEvent();
  int _nextWindowId = 1;
  bool _initialized = false;
  bool _quitRequested = false;
  bool _serverDisconnected = false;
  bool _supportsCpuPresentation = false;

  /// Everything worth noting since probe/init.
  List<BackendDiagnostic> get diagnostics =>
      List<BackendDiagnostic>.unmodifiable(_diagnostics);

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

    final resolution =
        _isLinux ? resolveWaylandSocketPath(_environment) : null;
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
    var drained = _drainQueuedEvents(connection);
    if (drained == 0 && timeout != Duration.zero) {
      final milliseconds = timeout.isNegative
          ? -1
          : timeout.inMicroseconds == 0
              ? 0
              : (timeout.inMicroseconds / 1000).ceil();
      connection.waitForActivity(milliseconds);
      drained += _drainQueuedEvents(connection);
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

  void _onWindowClosed(WaylandWindow window) {
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

  void _inspectConnection(
    WaylandBackendConnection connection,
    List<BackendDiagnostic> diagnostics,
  ) {
    final cpuClient =
        connection is WaylandCpuClient ? connection as WaylandCpuClient : null;
    _supportsCpuPresentation = cpuClient?.supportsShmPresentation ?? false;
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
    diagnostics.add(const BackendDiagnostic.note(
      'pointer motion, buttons, crossings and axis scroll are normalized; '
      'keyboard uses the minimal xkb text subset (no dead keys/compose/IME)',
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
