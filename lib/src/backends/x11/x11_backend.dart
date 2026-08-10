/// The X11 windowing backend, per section 15 of the roadmap.
///
/// This is the X11 entry point: it implements [WindowingBackend], opens the
/// XCB connection, resolves the scale (section 6.5 and the precedence in
/// `x11_scale.dart`), owns the display connection and routes core window
/// events and exposes a retained core PutImage CPU framebuffer when the root
/// visual accepts the framework's BGRA layout.
///
/// ## Bootstrap order
///
///   1. Open the XCB connection (or fail with diagnostics).
///   2. Read the screen's physical size and the `RESOURCE_MANAGER` property.
///   3. Resolve the scale via [resolveX11Scale].
///   4. Check for RANDR and other extensions (detected, not required).
///   5. Create windows on demand.
///   6. Pump and coalesce events in [pumpEvents].
///   7. Shutdown: dispose owned resources and disconnect.
///
/// ## What this cannot do yet, said plainly
///
///   * **No RANDR per-monitor.** The scale comes from the core protocol's
///     screen, which is the bounding box of all monitors.  Per-output
///     geometry needs `libxcb-randr` and three chained round trips; the
///     gap is documented in `x11_scale.dart` and is detected here.
///   * **No Xkb integration.**  Future keyboard input must not stop at core
///     protocol keycodes. Xkb gives layouts, compose sequences and LED state;
///     it needs
///     `libxcb-xkb` and is the next extension to add.
///   * **PutImage copies.** The core CPU path works on compatible TrueColor
///     visuals, but `xcb-shm` would eliminate that copy; it is detected here
///     and is the first performance extension to wire.
library;

import 'dart:io' show Platform;

import '../../foundation/diagnostics.dart';

import '../../platform/native_window.dart';
import '../../platform/window_events.dart';
import 'x11_bindings.dart';
import 'x11_connection.dart';
import 'x11_events.dart';
import 'x11_libc.dart';
import 'x11_protocol.dart';
import 'x11_scale.dart';
import 'x11_surface.dart';
import 'x11_window.dart';

/// Opens one X11 connection for [display].
///
/// This seam is public only because `src/` backends are tested directly. A
/// production caller should use the default supplied by [X11WindowingBackend].
typedef X11ConnectionOpener = X11ConnectionAttempt Function(String display);

/// Creates and owns X11 windows.
final class X11WindowingBackend implements WindowingBackend {
  X11WindowingBackend({
    bool? isLinux,
    String? operatingSystem,
    Map<String, String>? environment,
    X11ConnectionOpener? connectionOpener,
  })  : _isLinux = isLinux ?? Platform.isLinux,
        _operatingSystem = operatingSystem ?? Platform.operatingSystem,
        _environment = Map<String, String>.unmodifiable(
          environment ?? Platform.environment,
        ),
        _connectionOpener = connectionOpener ?? _openNativeConnection;

  @override
  String get name => 'x11';

  final List<X11Window> _windows = <X11Window>[];
  final Map<int, X11Window> _windowsByXid = <int, X11Window>{};
  final List<BackendDiagnostic> _diagnostics = <BackendDiagnostic>[];
  final bool _isLinux;
  final String _operatingSystem;
  final Map<String, String> _environment;
  final X11ConnectionOpener _connectionOpener;

  X11WindowClient? _connection;
  X11ScaleResolution? _scale;
  final X11RawEvent _rawEvent = X11RawEvent();
  int _nextWindowId = 1;
  bool _initialized = false;
  bool _quitRequested = false; // ignore: prefer_final_fields
  bool _serverDisconnected = false;

  // Extension detection flags — set during initialize, available for diagnostics.
  // ignore: prefer_final_fields
  bool _hasRandr = false;
  // ignore: prefer_final_fields
  bool _hasShm = false;
  // ignore: prefer_final_fields
  bool _hasXkb = false;
  bool _supportsCpuPresentation = false;

  /// The resolved scale, available after [probe] or [initialize].
  X11ScaleResolution? get scale => _scale;

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
          message: 'x11 needs Linux',
          detail: 'Platform.operatingSystem=$_operatingSystem',
        ),
      ));
    }

    final diagnostics = <BackendDiagnostic>[];
    final display = _getDisplay();
    if (display == null) {
      diagnostics.add(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'DISPLAY not set',
        detail: 'X11 requires a running X server; '
            'set DISPLAY or use the Wayland backend',
      ));
      _resolveScale(null, diagnostics);
      return _recordProbe(_probeResult(false, diagnostics));
    }

    diagnostics.add(BackendDiagnostic.note('DISPLAY=$display'));
    final attempt = _tryOpen(display);
    diagnostics.addAll(attempt.diagnostics);
    final connection = attempt.connection;
    var supported = false;
    try {
      final initiallyValid = connection != null && connection.isValid;
      if (initiallyValid) {
        _inspectConnection(connection, diagnostics);
        if (connection.isValid) {
          supported = connection is X11WindowClient;
          diagnostics.add(
            supported
                ? const BackendDiagnostic.note(
                    'X11 core window lifecycle is available',
                  )
                : const BackendDiagnostic(
                    kind: DiagnosticKind.rejectedByPolicy,
                    message: 'X11 connection has no window protocol client',
                  ),
          );
        } else {
          diagnostics.add(const BackendDiagnostic(
            kind: DiagnosticKind.connectionFailed,
            message: 'X11 connection became invalid after probe inspection',
          ));
        }
      } else {
        if (connection != null) {
          diagnostics.add(const BackendDiagnostic(
            kind: DiagnosticKind.connectionFailed,
            message: 'X11 connection became invalid during probe',
          ));
        }
        _resolveScale(null, diagnostics);
      }
    } on Object catch (error) {
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'failed to inspect X11 connection',
        detail: '$error',
      ));
      _resolveScale(null, diagnostics);
    } finally {
      try {
        connection?.dispose();
      } on Object catch (error) {
        supported = false;
        diagnostics.add(BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'failed to close X11 probe connection',
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

    if (!_isLinux || _getDisplay() == null) {
      final result = probe();
      throw BackendSelectionError(
          requested: name, attempts: <BackendProbeResult>[result]);
    }

    final display = _getDisplay()!;
    final diagnostics = <BackendDiagnostic>[
      BackendDiagnostic.note('DISPLAY=$display'),
    ];
    final attempt = _tryOpen(display);
    diagnostics.addAll(attempt.diagnostics);
    final candidate = attempt.connection;
    final connection = candidate is X11WindowClient ? candidate : null;
    if (connection == null || !connection.isValid) {
      candidate?.dispose();
      if (candidate != null) {
        diagnostics.add(const BackendDiagnostic(
          kind: DiagnosticKind.rejectedByPolicy,
          message: 'X11 connection cannot create top-level windows',
        ));
      }
      _resolveScale(null, diagnostics);
      final result = _recordProbe(_probeResult(false, diagnostics));
      throw BackendSelectionError(
          requested: name, attempts: <BackendProbeResult>[result]);
    }

    bool stillValid;
    try {
      _inspectConnection(connection, diagnostics);
      stillValid = connection.isValid;
    } on Object catch (error) {
      connection.dispose();
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'failed to initialize X11 connection',
        detail: '$error',
      ));
      final result = _recordProbe(_probeResult(false, diagnostics));
      throw BackendSelectionError(
          requested: name, attempts: <BackendProbeResult>[result]);
    }

    if (!stillValid) {
      connection.dispose();
      diagnostics.add(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message:
            'X11 connection became invalid after initialization inspection',
      ));
      final result = _recordProbe(_probeResult(false, diagnostics));
      throw BackendSelectionError(
          requested: name, attempts: <BackendProbeResult>[result]);
    }

    diagnostics.add(const BackendDiagnostic.note(
      'X11 window lifecycle initialized',
      detail: 'core PutImage presentation is used on compatible visuals',
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
    for (final window in List<X11Window>.of(_windows).reversed) {
      try {
        window.dispose();
      } on Object catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }
    _windows.clear();
    _windowsByXid.clear();

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
    final scaleResolution = _scale;
    final resolvedScale = scaleResolution?.scale ?? 1.0;
    final window = X11Window.create(
      client: connection,
      id: NativeWindowId(_nextWindowId++),
      options: options,
      scale: resolvedScale,
      desktopScale: scaleResolution?.effectiveDesktopScale ?? resolvedScale,
      onClosed: _onWindowClosed,
    );
    if (_windowsByXid.containsKey(window.xcbWindow)) {
      window.dispose();
      throw StateError(
        'XCB reused live window id 0x${window.xcbWindow.toRadixString(16)}',
      );
    }
    _windows.add(window);
    _windowsByXid[window.xcbWindow] = window;
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
          message: 'X11 server connection was lost during event pump',
        ));
      }
      _quitRequested = true;
      return false;
    }
    if (drained > 0) {
      for (final window in List<X11Window>.of(_windows)) {
        window.flushPendingEvents();
      }
    }
    return !_quitRequested;
  }

  int _drainQueuedEvents(X11WindowClient connection) {
    // A fixed budget prevents a producer flooding MotionNotify from starving
    // Dart tasks forever. Remaining events stay queued for the next pump.
    const budget = 4096;
    var drained = 0;
    while (drained < budget && connection.pollEventInto(_rawEvent)) {
      drained++;
      if (_rawEvent.type == xcbError) {
        connection.recordError(_rawEvent.describeError());
        continue;
      }
      if (_rawEvent.type == xcbPropertyNotify &&
          _rawEvent.window == connection.root) {
        for (final window in _windows) {
          window.handleRawEvent(_rawEvent);
        }
        continue;
      }
      _windowsByXid[_rawEvent.window]?.handleRawEvent(_rawEvent);
    }
    return drained;
  }

  void _onWindowClosed(X11Window window) {
    _windowsByXid.remove(window.xcbWindow);
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

  static X11ConnectionAttempt _openNativeConnection(String display) {
    final diagnostics = <BackendDiagnostic>[];
    final xcb = XcbBindings.load(diagnostics);
    if (xcb == null) {
      return X11ConnectionAttempt(connection: null, diagnostics: diagnostics);
    }
    final libc = X11Libc.open(diagnostics);
    if (libc == null) {
      return X11ConnectionAttempt(connection: null, diagnostics: diagnostics);
    }
    final attempt = X11Connection.open(xcb: xcb, libc: libc, display: display);
    return X11ConnectionAttempt(
      connection: attempt.connection,
      diagnostics: <BackendDiagnostic>[
        ...diagnostics,
        ...attempt.diagnostics,
      ],
    );
  }

  X11ConnectionAttempt _tryOpen(String display) {
    try {
      return _connectionOpener(display);
    } on Object catch (error) {
      return X11ConnectionAttempt(
        connection: null,
        diagnostics: <BackendDiagnostic>[
          BackendDiagnostic(
            kind: DiagnosticKind.connectionFailed,
            message: 'X11 connection opener threw',
            detail: '$error',
          ),
        ],
      );
    }
  }

  void _inspectConnection(
    X11BackendConnection connection,
    List<BackendDiagnostic> diagnostics,
  ) {
    final extensions = connection.extensions;
    _hasRandr = extensions.contains('RANDR');
    _hasShm = extensions.contains('MIT-SHM');
    _hasXkb = extensions.contains('XKEYBOARD');
    final cpuClient =
        connection is X11CpuClient ? connection as X11CpuClient : null;
    _supportsCpuPresentation = cpuClient?.supportsBgraPutImage ?? false;
    _resolveScale(connection, diagnostics);
    diagnostics.add(BackendDiagnostic.note(
      'extensions: randr=${_hasRandr ? "yes" : "no"}, '
      'shm=${_hasShm ? "yes" : "no"}, xkb=${_hasXkb ? "yes" : "no"}',
    ));
    diagnostics.add(BackendDiagnostic.note(
      _supportsCpuPresentation
          ? 'core BGRA PutImage presentation is available'
          : 'core BGRA PutImage presentation is unavailable',
    ));
  }

  void _resolveScale(
    X11BackendConnection? connection,
    List<BackendDiagnostic> diagnostics,
  ) {
    _scale = resolveX11Scale(
      dartUiScaleEnvironment: _env('DART_UI_SCALE'),
      gdkScaleEnvironment: _env('GDK_SCALE'),
      qtScaleFactorEnvironment: _env('QT_SCALE_FACTOR'),
      resourceDatabase: connection?.readResourceManager(),
      screen: connection?.physicalScreen,
    );
    diagnostics.add(_scale!.toDiagnostic());
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
              Capability.orderlyShutdown,
              if (_supportsCpuPresentation) Capability.cpuPresentation,
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

  String? _getDisplay() {
    final display = _env('DISPLAY');
    return display == null || display.trim().isEmpty ? null : display;
  }

  String? _env(String name) => _environment[name];

  void _requireInitialized(String operation) {
    if (!_initialized) {
      throw StateError('$name.$operation before initialize()');
    }
  }

  @override
  String toString() => 'X11WindowingBackend(initialized: $_initialized, '
      'windows: ${_windows.length}, scale: ${_scale?.scale})';
}
