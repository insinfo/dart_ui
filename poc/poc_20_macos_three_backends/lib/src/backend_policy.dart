/// The three macOS execution strategies investigated by this repository.
enum MacosBackendKind {
  /// Private WindowServer/SkyLight calls made directly through Dart FFI.
  skylight,

  /// AppKit entered by parking thread 0 from a signal handler.
  appkitSignal,

  /// A conventional Objective-C executable whose `main` owns thread 0.
  appkitNativeHost,
}

enum MacosBackendSupport {
  recommended,
  privateApi,
  experimentalUnsafe,
}

class MacosBackendDescriptor {
  const MacosBackendDescriptor({
    required this.kind,
    required this.support,
    required this.usesPrivateApi,
    required this.requiresNativeArtifact,
    required this.hasNormalAppKitLifecycle,
  });

  final MacosBackendKind kind;
  final MacosBackendSupport support;
  final bool usesPrivateApi;
  final bool requiresNativeArtifact;
  final bool hasNormalAppKitLifecycle;
}

const macosBackendDescriptors = <MacosBackendKind, MacosBackendDescriptor>{
  MacosBackendKind.skylight: MacosBackendDescriptor(
    kind: MacosBackendKind.skylight,
    support: MacosBackendSupport.privateApi,
    usesPrivateApi: true,
    requiresNativeArtifact: false,
    hasNormalAppKitLifecycle: false,
  ),
  MacosBackendKind.appkitSignal: MacosBackendDescriptor(
    kind: MacosBackendKind.appkitSignal,
    support: MacosBackendSupport.experimentalUnsafe,
    usesPrivateApi: false,
    requiresNativeArtifact: false,
    hasNormalAppKitLifecycle: false,
  ),
  MacosBackendKind.appkitNativeHost: MacosBackendDescriptor(
    kind: MacosBackendKind.appkitNativeHost,
    support: MacosBackendSupport.recommended,
    usesPrivateApi: false,
    requiresNativeArtifact: true,
    hasNormalAppKitLifecycle: true,
  ),
};

class MacosBackendAvailability {
  const MacosBackendAvailability({
    required this.nativeHostAvailable,
    required this.skylightAbiValidated,
    required this.signalHijackAvailable,
  });

  final bool nativeHostAvailable;
  final bool skylightAbiValidated;
  final bool signalHijackAvailable;
}

class MacosBackendRequest {
  const MacosBackendRequest({
    this.preferred,
    this.allowPrivateApi = false,
    this.allowUnsafeSignal = false,
    this.allowFallback = true,
  });

  final MacosBackendKind? preferred;
  final bool allowPrivateApi;
  final bool allowUnsafeSignal;
  final bool allowFallback;
}

class MacosBackendAttempt {
  const MacosBackendAttempt({
    required this.kind,
    required this.accepted,
    required this.reason,
  });

  final MacosBackendKind kind;
  final bool accepted;
  final String reason;
}

class MacosBackendSelection {
  const MacosBackendSelection({
    required this.selected,
    required this.attempts,
  });

  final MacosBackendKind? selected;
  final List<MacosBackendAttempt> attempts;

  bool get succeeded => selected != null;
}

/// Selects a backend without hiding rejected candidates.
///
/// The signal backend is considered only when explicitly requested. It is
/// never inserted into the automatic fallback chain, even when unsafe signals
/// have been allowed by the caller.
MacosBackendSelection selectMacosBackend({
  required MacosBackendAvailability availability,
  MacosBackendRequest request = const MacosBackendRequest(),
}) {
  final attempts = <MacosBackendAttempt>[];

  MacosBackendAttempt evaluate(MacosBackendKind kind) {
    switch (kind) {
      case MacosBackendKind.appkitNativeHost:
        return MacosBackendAttempt(
          kind: kind,
          accepted: availability.nativeHostAvailable,
          reason: availability.nativeHostAvailable
              ? 'native AppKit host is available and owns thread 0'
              : 'native AppKit host artifact is unavailable',
        );
      case MacosBackendKind.skylight:
        if (!request.allowPrivateApi) {
          return MacosBackendAttempt(
            kind: kind,
            accepted: false,
            reason: 'private APIs were not explicitly allowed',
          );
        }
        return MacosBackendAttempt(
          kind: kind,
          accepted: availability.skylightAbiValidated,
          reason: availability.skylightAbiValidated
              ? 'SkyLight ABI is validated for this macOS build'
              : 'SkyLight ABI is not validated for this macOS build',
        );
      case MacosBackendKind.appkitSignal:
        if (!request.allowUnsafeSignal) {
          return MacosBackendAttempt(
            kind: kind,
            accepted: false,
            reason: 'unsafe signal hijack was not explicitly allowed',
          );
        }
        return MacosBackendAttempt(
          kind: kind,
          accepted: availability.signalHijackAvailable,
          reason: availability.signalHijackAvailable
              ? 'experimental signal hijack is available'
              : 'experimental signal hijack is unavailable',
        );
    }
  }

  MacosBackendKind? tryKind(MacosBackendKind kind) {
    final attempt = evaluate(kind);
    attempts.add(attempt);
    return attempt.accepted ? kind : null;
  }

  final preferred = request.preferred;
  if (preferred != null) {
    final selected = tryKind(preferred);
    if (selected != null || !request.allowFallback) {
      return MacosBackendSelection(selected: selected, attempts: attempts);
    }
  }

  // Deliberately excludes appkitSignal. Unsafe signal entry is opt-in only.
  for (final candidate in const [
    MacosBackendKind.appkitNativeHost,
    MacosBackendKind.skylight,
  ]) {
    if (candidate == preferred) continue;
    final selected = tryKind(candidate);
    if (selected != null) {
      return MacosBackendSelection(selected: selected, attempts: attempts);
    }
  }

  return MacosBackendSelection(selected: null, attempts: attempts);
}
