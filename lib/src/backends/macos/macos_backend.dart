/// The macOS windowing backend, per section 20 of the roadmap.
///
/// This is the entry point for macOS windowing: it implements the
/// cross-platform [WindowingBackend] contract and delegates to whichever of
/// the three macOS backends the selection layer chose.
///
/// The three backends — SkyLight, AppKit signal hijack and AppKit native
/// host — are documented in `MACOS_TRES_BACKENDS.md`.  This file knows
/// which one to instantiate; the code above it does not, and must not.
///
/// ## Lifecycle
///
/// [probe] runs before [initialize] and reports what is available.
/// [initialize] creates the selected backend.
/// [createWindow] delegates to it.
/// [shutdown] tears down in reverse order.
///
/// Every public method on this class is reachable from two paths: the happy
/// path through the application, and the teardown path through the
/// framework's shutdown.  Both must work, and neither may leave native
/// handles behind.  That is `lifecycle.dart`'s rule, and it applies to the
/// backend as much as to the window.
library;

import 'dart:async';
import 'dart:io' show Platform;

import '../../foundation/diagnostics.dart';
import '../../platform/backend_selection.dart';
import '../../platform/native_window.dart';
import 'macos_backend_kind.dart';
import 'macos_backend_selection.dart';

/// Creates and owns macOS windows through the selected backend strategy.
final class MacosWindowingBackend implements WindowingBackend {
  MacosWindowingBackend({
    MacosBackendOptions options = const MacosBackendOptions(),
  }) : _options = options;

  final MacosBackendOptions _options;
  final List<NativeWindow> _windows = <NativeWindow>[];
  final List<BackendDiagnostic> _diagnostics = <BackendDiagnostic>[];

  BackendSelection? _selection;
  MacosBackendKind? _activeKind;
  bool _initialized = false;
  bool _quitRequested = false; // ignore: prefer_final_fields

  /// Which backend was selected, available after [probe].
  MacosBackendKind? get activeKind => _activeKind;

  @override
  String get name =>
      _activeKind != null ? 'macos.${_activeKind!.name}' : 'macos';

  @override
  BackendProbeResult probe() {
    if (!Platform.isMacOS) {
      return BackendProbeResult.unsupported(
        name,
        BackendDiagnostic(
          kind: DiagnosticKind.unsupportedPlatform,
          message: 'macOS backend needs macOS',
          detail: 'Platform.operatingSystem=${Platform.operatingSystem}',
        ),
      );
    }

    _selection = selectMacosBackend(_options);
    final selection = _selection!;

    if (!selection.isSuccess) {
      final diagnostics = <BackendDiagnostic>[
        BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'no macOS backend available',
          detail: selection.describe(),
        ),
        for (final rejection in selection.rejected)
          ...rejection.probe.diagnostics,
      ];
      return BackendProbeResult(
        backendName: name,
        supported: false,
        diagnostics: diagnostics,
      );
    }

    final chosen = selection.chosen!;
    _activeKind = MacosBackendKind.values.firstWhere(
      (k) => chosen.name.endsWith(k.name),
      orElse: () => MacosBackendKind.appkitNativeHost,
    );

    _diagnostics.add(BackendDiagnostic.note(
      'selected macOS backend: ${_activeKind!.name}',
      detail: selection.describe().trim(),
    ));

    return chosen.probe;
  }

  @override
  Future<void> initialize() async {
    if (_initialized) return;

    if (_selection == null) probe();
    if (_activeKind == null) {
      throw BackendSelectionError(
        requested: _options.requested?.name,
        attempts: _selection == null
            ? const <BackendProbeResult>[]
            : <BackendProbeResult>[
                for (final r in _selection!.rejected) r.probe,
              ],
      );
    }

    // Actual backend-specific initialisation depends on the selected kind.
    // appkitNativeHost: spawn the host process (MacosWindow handles this).
    // skylight: open SkyLight framework and resolve symbols.
    // appkitSignal: install the signal handler.
    //
    // For now, mark initialised and let createWindow perform the lazy setup
    // that MacosWindow already implements for appkitNativeHost.
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
  }

  @override
  Future<NativeWindow> createWindow(WindowOptions options) async {
    _requireInitialized('createWindow');
    // The MacosWindow class already handles the host process lifecycle for
    // appkitNativeHost.  The other two backends will need their own window
    // implementations; for now we support the recommended default.
    if (_activeKind != MacosBackendKind.appkitNativeHost) {
      throw UnsupportedCapabilityError(
        backendName: name,
        capability: Capability.window,
        detail: '${_activeKind!.name} window creation not yet implemented; '
            'use appkitNativeHost',
      );
    }

    // MacosWindow.create is asynchronous because it spawns the host.
    // The WindowOptions → MacosWindowOptions mapping is straightforward.
    throw UnimplementedError(
      '$name.createWindow: wire MacosWindow.create here once the host '
      'locator result is threaded through',
    );
  }

  @override
  List<NativeWindow> get windows => List<NativeWindow>.unmodifiable(_windows);

  @override
  bool pumpEvents({Duration timeout = Duration.zero}) {
    _requireInitialized('pumpEvents');
    // The pump depends on the active backend:
    // - appkitNativeHost: read from the host process pipe
    // - skylight: read from the SkyLight event port
    // - appkitSignal: pump the CFRunLoop
    //
    // Each is wired when its window implementation lands.
    return !_quitRequested;
  }

  @override
  void wake() {
    // Wake depends on the active backend:
    // - appkitNativeHost: signal the pipe
    // - skylight: write to a self-pipe or CFRunLoopSource
    // - appkitSignal: CFRunLoopWakeUp
  }

  /// Diagnostics collected during probe and initialisation.
  List<BackendDiagnostic> get diagnostics =>
      List<BackendDiagnostic>.unmodifiable(_diagnostics);

  void _requireInitialized(String operation) {
    if (!_initialized) {
      throw StateError('$name.$operation before initialize()');
    }
  }

  @override
  String toString() =>
      'MacosWindowingBackend(kind: ${_activeKind?.name ?? "none"}, '
      'initialized: $_initialized, windows: ${_windows.length})';
}
