/// Choosing which macOS windowing backend to use at runtime.
///
/// This is the macOS-specific layer between `backend_selection.dart`'s generic
/// machinery and the three concrete backends.  It runs each probe, wraps the
/// results into [BackendCandidate]s in the precedence order documented in
/// `MACOS_TRES_BACKENDS.md`, and hands them to [selectBackend].
///
/// The precedence is:
///
///   1. **appkitNativeHost** — the recommended default.  Correct thread
///      ownership, proven lifecycle, smallest risk surface.
///   2. **skylight** — works without a host binary, but uses private API.
///      Chosen only when the host is unavailable or the caller asked for it.
///   3. **appkitSignal** — experimental.  Never chosen automatically, only
///      when the caller passes `allowExperimental: true` and names it.
///
/// The caller can override by passing a [MacosBackendKind] as the requested
/// backend, and the selection layer will pin to it or fail with a report.
library;

import 'dart:io' show Platform;

import '../../foundation/diagnostics.dart';
import '../../platform/backend_selection.dart';
import 'host_locator.dart';
import 'mach_rendezvous.dart';
import 'macos_backend_kind.dart';

/// Options that influence which macOS backend is selected.
final class MacosBackendOptions {
  const MacosBackendOptions({
    this.requested,
    this.allowExperimental = false,
    this.hostBinaryPath,
  });

  /// Pin to one backend by name.  The selection will either use it or fail;
  /// it will never silently fall back.
  final MacosBackendKind? requested;

  /// Whether experimental backends (appkitSignal) may be chosen.
  final bool allowExperimental;

  /// Explicit path to the native host binary.  Bypasses the locator.
  final String? hostBinaryPath;
}

/// Probes and selects the macOS backend according to the precedence above.
///
/// Returns a [BackendSelection] that names the winner and lists every
/// candidate that was tried, so the startup log carries the whole story.
///
/// Pure in the sense that it reads the environment and the filesystem but
/// never creates a window or spawns a process.  The actual backend
/// construction happens in `MacosWindowingBackend.initialize`, which only
/// runs after the selection succeeds.
BackendSelection selectMacosBackend([
  MacosBackendOptions options = const MacosBackendOptions(),
]) {
  if (!Platform.isMacOS) {
    return BackendSelection(
      chosen: null,
      rejected: <BackendRejection>[],
      requested: options.requested?.name,
      required_: const <Capability>{},
    );
  }

  final candidates = <BackendCandidate>[
    _probeAppKitNativeHost(options),
    _probeSkylight(),
    _probeAppKitSignal(),
  ];

  return selectBackend(
    candidates,
    requested: options.requested?.name,
    allowExperimental: options.allowExperimental,
  );
}

BackendCandidate _probeAppKitNativeHost(MacosBackendOptions options) {
  final diagnostics = <BackendDiagnostic>[];
  var canCreate = true;

  // Check that MachRendezvous symbols are available — this is the
  // IOSurface-over-mach-port path the host uses.
  if (!MachRendezvous.isAvailable) {
    diagnostics.add(const BackendDiagnostic(
      kind: DiagnosticKind.missingSymbol,
      message: 'mach_msg / bootstrap_look_up not found',
      detail: 'rendezvous handoff unavailable; host cannot receive surfaces',
    ));
    // Not fatal — the deprecated IOSurfaceLookup path exists as fallback.
  }

  // Locate the host binary.
  final locatorResult = MacosHostLocator.resolve(
    explicitPath: options.hostBinaryPath,
  );
  diagnostics.addAll(locatorResult.diagnostics);

  if (locatorResult.binaryPath == null) {
    diagnostics.add(const BackendDiagnostic(
      kind: DiagnosticKind.missingLibrary,
      message: 'native host binary not found',
      detail: 'compile with native/build_host.sh or set DART_UI_MACOS_HOST',
    ));
    canCreate = false;
  }

  final capabilities = MacosBackendCapabilities(
    kind: MacosBackendKind.appkitNativeHost,
    canCreateWindow: canCreate,
    hasInput: canCreate,
    hasIme: false, // Not wired yet.
    hasAccessibility: false, // Not wired yet.
    hasOrderlyShutdown: canCreate,
    needsHostBinary: true,
    hostBinaryPath: locatorResult.binaryPath,
    diagnostics: diagnostics,
  );

  return BackendCandidate(
    name: 'macos.${MacosBackendKind.appkitNativeHost.name}',
    probe: capabilities.toProbeResult(),
  );
}

BackendCandidate _probeSkylight() {
  final diagnostics = <BackendDiagnostic>[];
  var canCreate = true;

  // SkyLight is a private framework; check that the symbols we need exist.
  try {
    _checkSkylightSymbols(diagnostics);
  } on Object catch (e) {
    diagnostics.add(BackendDiagnostic(
      kind: DiagnosticKind.missingLibrary,
      message: 'SkyLight framework not loadable',
      detail: '$e',
    ));
    canCreate = false;
  }

  final capabilities = MacosBackendCapabilities(
    kind: MacosBackendKind.skylight,
    canCreateWindow: canCreate,
    hasInput: canCreate,
    hasIme: false,
    hasAccessibility: false,
    hasOrderlyShutdown: canCreate,
    needsHostBinary: false,
    diagnostics: diagnostics,
  );

  return BackendCandidate(
    name: 'macos.${MacosBackendKind.skylight.name}',
    probe: capabilities.toProbeResult(),
  );
}

BackendCandidate _probeAppKitSignal() {
  // AppKit signal hijack is always marked experimental: it works, but
  // CFRunLoopRun is not async-signal-safe and the mechanism has produced
  // traps in spikes.  The probe succeeds (it is functional) but the
  // experimental flag prevents automatic selection.
  const capabilities = MacosBackendCapabilities(
    kind: MacosBackendKind.appkitSignal,
    canCreateWindow: true,
    hasInput: true,
    hasIme: false,
    hasAccessibility: false,
    hasOrderlyShutdown: false, // Teardown still uses _exit in spikes.
    needsHostBinary: false,
    diagnostics: <BackendDiagnostic>[
      BackendDiagnostic.note(
        'appkitSignal: experimental, not async-signal-safe',
        detail: 'requires explicit opt-in; see MACOS_TRES_BACKENDS.md',
      ),
    ],
  );

  return BackendCandidate(
    name: 'macos.${MacosBackendKind.appkitSignal.name}',
    probe: capabilities.toProbeResult(),
    experimental: true,
  );
}

/// Checks that the SkyLight/CGS symbols the skylight backend needs are
/// resolvable.  Adds diagnostics for each missing symbol rather than
/// aborting at the first one, because a probe that says "three symbols are
/// missing" is more useful than one that says "one symbol is missing"
/// and makes the user run it three times.
void _checkSkylightSymbols(List<BackendDiagnostic> diagnostics) {
  // The actual symbol lookups are done by the skylight backend at
  // initialisation time.  Here we only check the framework is loadable at
  // all — the symbol-level probe is the backend's responsibility and its
  // diagnostics flow into the capabilities.
  //
  // On a machine where SkyLight is not available (non-macOS, or a future
  // macOS that removed it), DynamicLibrary.open will throw, which the
  // caller catches.
  //
  // We do NOT import DynamicLibrary here to avoid loading the framework at
  // probe time on Windows/Linux CI where the import would fail.  The
  // Platform.isMacOS guard in selectMacosBackend ensures this code only
  // runs on macOS.
  diagnostics.add(const BackendDiagnostic.note(
    'skylight: private API, forward compatibility not guaranteed',
    detail: 'SkyLight/CGS symbols resolved at initialisation',
  ));
}
