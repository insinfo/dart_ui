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
///      It requires explicit private-API permission and an ABI validation for
///      the running macOS build.
///   3. **appkitSignal** — experimental.  Never chosen automatically, only
///      when the caller explicitly permits the unsafe signal path and names
///      it.
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
    this.allowPrivateApi = false,
    this.skylightAbiValidated = false,
    this.allowUnsafeSignal = false,
    this.hostBinaryPath,
  });

  /// Pin to one backend by name.  The selection will either use it or fail;
  /// it will never silently fall back.
  final MacosBackendKind? requested;

  /// Legacy opt-in for experimental backends.
  ///
  /// Kept for source compatibility. New code should use
  /// [allowUnsafeSignal], which names the actual risk being accepted.
  final bool allowExperimental;

  /// Whether the caller accepts using the private SkyLight/CGS API.
  final bool allowPrivateApi;

  /// Whether SkyLight's private ABI was validated for this macOS build.
  ///
  /// Permission alone is insufficient: a private ABI mismatch can corrupt
  /// native memory before Dart has a chance to report an error.
  final bool skylightAbiValidated;

  /// Whether the caller accepts entering AppKit from a signal handler.
  final bool allowUnsafeSignal;

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
      requested: _candidateName(options.requested),
      required_: const <Capability>{},
    );
  }

  final candidates = <BackendCandidate>[
    _probeAppKitNativeHost(options),
    _probeSkylight(),
    _probeAppKitSignal(options),
  ];

  return selectMacosBackendCandidates(candidates, options);
}

/// Applies macOS policy to already-probed candidates.
///
/// Kept separate from the platform probes so the security-sensitive naming
/// and opt-in rules can be regression-tested on Linux and Windows CI.
BackendSelection selectMacosBackendCandidates(
  List<BackendCandidate> candidates,
  MacosBackendOptions options,
) {
  final guardedCandidates = <BackendCandidate>[
    for (final candidate in candidates)
      if (candidate.name == _candidateName(MacosBackendKind.skylight) &&
          (!options.allowPrivateApi || !options.skylightAbiValidated))
        _rejectByPolicy(
          candidate,
          !options.allowPrivateApi
              ? 'SkyLight private API was not explicitly allowed'
              : 'SkyLight ABI is not validated for this macOS build',
        )
      else
        candidate,
  ];
  return selectBackend(
    guardedCandidates,
    requested: _candidateName(options.requested),
    // appkitSignal must be both named and explicitly allowed. Merely enabling
    // experimental features must never insert it into the fallback chain.
    allowExperimental: options.requested == MacosBackendKind.appkitSignal &&
        (options.allowUnsafeSignal || options.allowExperimental),
  );
}

BackendCandidate _rejectByPolicy(
  BackendCandidate candidate,
  String message,
) {
  return BackendCandidate(
    name: candidate.name,
    experimental: candidate.experimental,
    probe: BackendProbeResult(
      backendName: candidate.probe.backendName,
      supported: false,
      diagnostics: <BackendDiagnostic>[
        ...candidate.probe.diagnostics,
        BackendDiagnostic(
          kind: DiagnosticKind.rejectedByPolicy,
          message: message,
        ),
      ],
    ),
  );
}

String? _candidateName(MacosBackendKind? kind) =>
    kind == null ? null : 'macos.${kind.name}';

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
    // Fatal: production currently implements only the Mach-port handoff.
    // Claiming the deprecated ID lookup as a fallback here used to make the
    // probe pass even though the supervisor had no such attach path.
    canCreate = false;
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
  final diagnostics = <BackendDiagnostic>[
    const BackendDiagnostic.note(
      'skylight: private API, forward compatibility not guaranteed',
    ),
  ];

  diagnostics.add(const BackendDiagnostic(
    kind: DiagnosticKind.missingLibrary,
    message: 'SkyLight production backend is not integrated',
    detail: 'the validated implementation currently exists only in POC 20',
  ));

  // The POC is evidence, not a production implementation. Keep this false
  // until createWindow/pumpEvents/wake have a concrete SkyLight delegate.
  const canCreate = false;

  final capabilities = MacosBackendCapabilities(
    kind: MacosBackendKind.skylight,
    canCreateWindow: canCreate,
    hasInput: canCreate,
    hasIme: false,
    hasAccessibility: false,
    hasOrderlyShutdown: false,
    needsHostBinary: false,
    diagnostics: diagnostics,
  );

  return BackendCandidate(
    name: 'macos.${MacosBackendKind.skylight.name}',
    probe: capabilities.toProbeResult(),
  );
}

BackendCandidate _probeAppKitSignal(MacosBackendOptions options) {
  // AppKit signal hijack is always marked experimental: it works, but
  // CFRunLoopRun is not async-signal-safe and the mechanism has produced
  // traps in spikes. The experimental flag prevents automatic selection,
  // while the unsupported probe records that it has not reached lib yet.
  final explicitlyAllowed =
      options.allowUnsafeSignal || options.allowExperimental;
  final diagnostics = <BackendDiagnostic>[
    const BackendDiagnostic.note(
      'appkitSignal: experimental, not async-signal-safe',
      detail: 'requires explicit opt-in; see MACOS_TRES_BACKENDS.md',
    ),
    if (!explicitlyAllowed)
      const BackendDiagnostic(
        kind: DiagnosticKind.rejectedByPolicy,
        message: 'unsafe AppKit signal hijack was not explicitly allowed',
      ),
    const BackendDiagnostic(
      kind: DiagnosticKind.missingLibrary,
      message: 'appkitSignal production backend is not integrated',
      detail: 'the LLDB-validated implementation remains a monolithic POC',
    ),
  ];
  final capabilities = MacosBackendCapabilities(
    kind: MacosBackendKind.appkitSignal,
    canCreateWindow: false,
    hasInput: false,
    hasIme: false,
    hasAccessibility: false,
    // LLDB run 31341132992 proves CFRunLoopStop + WakeUp unwinds to
    // Dart_RunLoop and exits normally. The entry mechanism remains unsafe.
    hasOrderlyShutdown: true,
    needsHostBinary: false,
    diagnostics: diagnostics,
  );

  return BackendCandidate(
    name: 'macos.${MacosBackendKind.appkitSignal.name}',
    probe: capabilities.toProbeResult(),
    experimental: true,
  );
}
