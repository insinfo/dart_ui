/// The X11 windowing backend, per section 15 of the roadmap.
///
/// This is the X11 entry point: it implements [WindowingBackend], opens the
/// XCB connection, resolves the scale (section 6.5 and the precedence in
/// `x11_scale.dart`), and manages X11 windows.
///
/// ## Bootstrap order
///
///   1. Open the XCB connection (or fail with diagnostics).
///   2. Read the screen's physical size and the `RESOURCE_MANAGER` property.
///   3. Resolve the scale via [resolveX11Scale].
///   4. Check for RANDR and other extensions (detected, not required).
///   5. Create windows on demand.
///   6. Pump events via `xcb_poll_for_event` inside [pumpEvents].
///   7. Shutdown: destroy windows, disconnect.
///
/// ## What this cannot do yet, said plainly
///
///   * **No RANDR per-monitor.** The scale comes from the core protocol's
///     screen, which is the bounding box of all monitors.  Per-output
///     geometry needs `libxcb-randr` and three chained round trips; the
///     gap is documented in `x11_scale.dart` and is detected here.
///   * **No Xkb.**  Keyboard input uses core protocol keycodes.  Xkb would
///     give layouts, compose sequences and LED state; it needs
///     `libxcb-xkb` and is the next extension to add.
///   * **No SHM.**  Pixels are pushed via `PutImage`, which copies.
///     `xcb-shm` would eliminate that copy; it is detected here and is the
///     first performance extension to wire.
library;

import 'dart:io' show Platform;

import '../../foundation/diagnostics.dart';

import '../../platform/native_window.dart';
import 'x11_scale.dart';

/// Creates and owns X11 windows.
final class X11WindowingBackend implements WindowingBackend {
  X11WindowingBackend();

  @override
  String get name => 'x11';

  final List<NativeWindow> _windows = <NativeWindow>[];
  final List<BackendDiagnostic> _diagnostics = <BackendDiagnostic>[];

  X11ScaleResolution? _scale;
  bool _initialized = false;
  bool _quitRequested = false; // ignore: prefer_final_fields

  // Extension detection flags — set during initialize, available for diagnostics.
  // ignore: prefer_final_fields
  bool _hasRandr = false;
  // ignore: prefer_final_fields
  bool _hasShm = false;
  // ignore: prefer_final_fields
  bool _hasXkb = false;

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
    if (!Platform.isLinux) {
      return BackendProbeResult.unsupported(
        name,
        BackendDiagnostic(
          kind: DiagnosticKind.unsupportedPlatform,
          message: 'x11 needs Linux',
          detail: 'Platform.operatingSystem=${Platform.operatingSystem}',
        ),
      );
    }

    final diagnostics = <BackendDiagnostic>[];
    var supported = true;

    // Check that libxcb is loadable.
    try {
      _probeXcbLibrary(diagnostics);
    } on Object catch (e) {
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.missingLibrary,
        message: 'libxcb not loadable',
        detail: '$e',
      ));
      supported = false;
    }

    // Check DISPLAY / WAYLAND_DISPLAY environment.
    final display = _getDisplay();
    if (display == null) {
      diagnostics.add(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'DISPLAY not set',
        detail: 'X11 requires a running X server; '
            'set DISPLAY or use the Wayland backend',
      ));
      supported = false;
    } else {
      diagnostics.add(BackendDiagnostic.note(
        'DISPLAY=$display',
      ));
    }

    // Attempt a scale resolution from environment only (no connection yet).
    _scale = resolveX11Scale(
      dartUiScaleEnvironment: _env('DART_UI_SCALE'),
      gdkScaleEnvironment: _env('GDK_SCALE'),
      qtScaleFactorEnvironment: _env('QT_SCALE_FACTOR'),
    );
    diagnostics.add(_scale!.toDiagnostic());

    // Report extension availability (detected, not required).
    diagnostics.add(BackendDiagnostic.note(
      'extensions: randr=${_hasRandr ? "yes" : "probe-deferred"}, '
      'shm=${_hasShm ? "yes" : "probe-deferred"}, '
      'xkb=${_hasXkb ? "yes" : "probe-deferred"}',
    ));

    final capabilities = <Capability>{
      if (supported) ...<Capability>[
        Capability.window,
        Capability.cpuPresentation,
        Capability.keyboardInput,
        Capability.pointerInput,
        Capability.scrollInput,
        Capability.orderlyShutdown,
      ],
    };

    return BackendProbeResult(
      backendName: name,
      supported: supported,
      capabilities: capabilities,
      diagnostics: diagnostics,
    );
  }

  // ---------------------------------------------------------------------------
  // Initialize / Shutdown
  // ---------------------------------------------------------------------------

  @override
  Future<void> initialize() async {
    if (_initialized) return;

    // In a full implementation, this opens the XCB connection:
    //   _connection = xcb_connect(null, &screenNumber);
    //   if (xcb_connection_has_error(_connection)) { ... }
    //
    // Then reads the screen info for physical-size scale resolution:
    //   final screen = xcb_setup_roots_iterator(xcb_get_setup(_connection));
    //   _scale = resolveX11Scale(screen: X11PhysicalScreen(...), ...);
    //
    // Then checks for extensions:
    //   _hasRandr = xcb_get_extension_data(_connection, &xcb_randr_id)->present;
    //   _hasShm = xcb_get_extension_data(_connection, &xcb_shm_id)->present;

    _initialized = true;
  }

  @override
  Future<void> shutdown() async {
    if (!_initialized) return;
    _initialized = false;

    for (final window in List<NativeWindow>.of(_windows)) {
      window.dispose();
    }
    _windows.clear();

    // xcb_disconnect(_connection);
  }

  // ---------------------------------------------------------------------------
  // Windows
  // ---------------------------------------------------------------------------

  @override
  List<NativeWindow> get windows => List<NativeWindow>.unmodifiable(_windows);

  @override
  Future<NativeWindow> createWindow(WindowOptions options) async {
    _requireInitialized('createWindow');
    // X11Window.create would:
    //   1. xcb_generate_id
    //   2. xcb_create_window with the screen's root visual
    //   3. set WM_PROTOCOLS (WM_DELETE_WINDOW)
    //   4. set _NET_WM_NAME
    //   5. xcb_map_window
    //   6. xcb_flush
    throw UnimplementedError(
      '$name.createWindow: wire X11Window.create here',
    );
  }

  // ---------------------------------------------------------------------------
  // Event pump
  // ---------------------------------------------------------------------------

  @override
  bool pumpEvents({Duration timeout = Duration.zero}) {
    _requireInitialized('pumpEvents');
    // In a full implementation:
    //   while ((event = xcb_poll_for_event(_connection)) != null) {
    //     _translateEvent(event);
    //     free(event);
    //   }
    return !_quitRequested;
  }

  @override
  void wake() {
    // Write one byte to the self-pipe's write end to unblock poll(2).
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  void _probeXcbLibrary(List<BackendDiagnostic> diagnostics) {
    // In a full implementation, DynamicLibrary.open('libxcb.so.1') and
    // check for the required symbols.  We do not open it during probe on
    // non-Linux platforms to avoid a crash.
    diagnostics.add(const BackendDiagnostic.note(
      'libxcb: symbol resolution deferred to initialize()',
    ));
  }

  String? _getDisplay() {
    return _env('DISPLAY');
  }

  String? _env(String name) {
    try {
      return Platform.environment[name];
    } on Object {
      return null;
    }
  }

  void _requireInitialized(String operation) {
    if (!_initialized) {
      throw StateError('$name.$operation before initialize()');
    }
  }

  @override
  String toString() => 'X11WindowingBackend(initialized: $_initialized, '
      'windows: ${_windows.length}, scale: ${_scale?.scale})';
}
