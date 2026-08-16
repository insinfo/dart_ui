/// Choosing a backend, and never doing it quietly.
///
/// Section 6.6 forbids catching an exception and moving on to the next
/// candidate. That rule exists because the failure mode it prevents is
/// miserable: an application runs on the CPU renderer on a machine with a
/// perfectly good GPU, nobody notices for months, and when someone finally
/// asks, there is nothing in any log that says why.
///
/// So selection here produces a *report*, always - on success as much as on
/// failure. The chosen backend is one field of it; the others are every
/// candidate that was tried and the named reason each was passed over.
library;

import '../foundation/diagnostics.dart';

/// Why a candidate was not chosen. Distinct from [BackendDiagnostic] because
/// this is about the *selection*, not about the backend: a backend can be
/// perfectly healthy and still be passed over for one ranked above it.
enum RejectionReason {
  /// The backend said it cannot run here. Its own diagnostics say why.
  unsupported,

  /// It ran, but lacked a capability the caller required.
  missingCapability,

  /// It was healthy and something ranked higher was chosen first.
  outranked,

  /// Experimental, and the caller did not opt in. The macOS signal-hijack
  /// backend is the reason this exists: it works, and choosing it
  /// automatically would still be wrong.
  needsExplicitOptIn,

  /// The caller asked for a different backend by name.
  notRequested,
}

final class BackendCandidate {
  const BackendCandidate({
    required this.name,
    required this.probe,
    this.experimental = false,
  });

  final String name;
  final BackendProbeResult probe;

  /// Never chosen automatically, whatever it reports. Must be asked for.
  final bool experimental;
}

final class BackendRejection {
  const BackendRejection({
    required this.name,
    required this.reason,
    required this.probe,
    this.detail,
  });

  final String name;
  final RejectionReason reason;
  final BackendProbeResult probe;
  final String? detail;

  @override
  String toString() {
    final buffer = StringBuffer('$name: ${reason.name}');
    if (detail != null) buffer.write(' ($detail)');
    for (final diagnostic in probe.failures) {
      buffer.write('\n      $diagnostic');
    }
    return buffer.toString();
  }
}

/// Where a pinned name came from.
///
/// Recorded rather than inferred because the three sources fail differently.
/// A name burned into the source is a build-time decision and its failure is a
/// bug; a name from the environment is usually an operator debugging a machine
/// and its failure is a typo; a name from the command line is a developer
/// bisecting a backend and its failure should be the very first line they see.
/// A report that says only "requested: vulkan" cannot tell them apart.
enum SelectionOverrideSource {
  /// Nothing pinned anything; the ranked order decided.
  none,

  /// The caller passed a name in code.
  explicit,

  /// [kBackendEnvironmentVariable] or [kPresentationEnvironmentVariable].
  environmentVariable,

  /// [kBackendFlag] or [kPresentationFlag] on the command line.
  commandLineFlag,
}

/// The outcome of selection, whether or not it succeeded.
final class BackendSelection {
  const BackendSelection({
    required this.chosen,
    required this.rejected,
    required this.requested,
    required this.required_,
    this.overrideSource = SelectionOverrideSource.none,
  });

  /// Null when nothing qualified. [describe] then says what was tried.
  final BackendCandidate? chosen;

  final List<BackendRejection> rejected;
  final String? requested;
  final Set<Capability> required_;

  /// How [requested] arrived. [SelectionOverrideSource.none] when nothing was
  /// pinned.
  final SelectionOverrideSource overrideSource;

  bool get isSuccess => chosen != null;

  /// Every probe that took part, chosen and rejected alike.
  ///
  /// This is what a [BackendSelectionError] must carry: section 6.6's rule is
  /// that a failure names *what was tried*, and a list that stopped at the
  /// first rejection would be exactly the log that cannot answer the next bug
  /// report.
  List<BackendProbeResult> get attempts => <BackendProbeResult>[
        if (chosen != null) chosen!.probe,
        for (final rejection in rejected) rejection.probe,
      ];

  /// This selection as the error a caller should throw when it failed.
  ///
  /// Deliberately not thrown by [selectBackend] itself: asking whether
  /// anything qualifies must be safe, and only the caller knows whether "no
  /// backend" is fatal or merely one branch of a wider search.
  BackendSelectionError toError() => BackendSelectionError(
        requested: requested,
        attempts: attempts,
      );

  /// The whole story in one blob, meant to be logged verbatim on startup.
  ///
  /// Printed even on success: knowing that Metal was chosen is useful, and
  /// knowing that Vulkan was right behind it and why is what makes the next
  /// bug report answerable.
  String describe() {
    final buffer = StringBuffer('backend selection');
    if (requested != null) {
      buffer.write(' (requested: $requested');
      if (overrideSource != SelectionOverrideSource.none) {
        buffer.write(' via ${overrideSource.name}');
      }
      buffer.write(')');
    }
    if (required_.isNotEmpty) {
      final names = required_.map((c) => c.name).toList()..sort();
      buffer.write(' (required: ${names.join(', ')})');
    }
    buffer.writeln();
    buffer.writeln(
      chosen == null ? '  chosen: none' : '  chosen: ${chosen!.name}',
    );
    if (rejected.isEmpty) {
      buffer.writeln('  passed over: none');
    } else {
      buffer.writeln('  passed over:');
      for (final rejection in rejected) {
        buffer.writeln('    - $rejection');
      }
    }
    return buffer.toString();
  }
}

/// Picks the first candidate that qualifies, in the order given.
///
/// Order is the caller's policy, not this function's - a renderer prefers GPU
/// over CPU, a windowing layer prefers Wayland over X11, and neither ranking
/// belongs here. [preferred] is the one exception, and it is still the
/// caller's policy: it re-orders [candidates] by name before the scan, which
/// is how a `DartUiConfig`-style declared preference (section 5.1) is applied
/// without the caller having to sort the list itself.
///
/// [requested] pins one by name. A pinned backend that cannot run is a
/// failure, never a silent fallback: the caller asked for something specific
/// and quietly giving them something else is exactly the behaviour section 6.6
/// is written against. When [requested] is null the override is looked for in
/// [arguments] (`--backend=x11`) and then in [environment]
/// ([kBackendEnvironmentVariable]); see [resolveSelectionOverride] for why the
/// flag wins.
BackendSelection selectBackend(
  List<BackendCandidate> candidates, {
  String? requested,
  Set<Capability> required = const <Capability>{},
  bool allowExperimental = false,
  List<String> preferred = const <String>[],
  List<String> arguments = const <String>[],
  Map<String, String> environment = const <String, String>{},
}) {
  final override = resolveSelectionOverride(
    explicit: requested,
    flag: kBackendFlag,
    environmentVariable: kBackendEnvironmentVariable,
    arguments: arguments,
    environment: environment,
  );
  final pinned = override.value;
  final rejected = <BackendRejection>[];
  BackendCandidate? chosen;

  for (final candidate in _rankByPreference(
    candidates,
    preferred,
    (BackendCandidate candidate) => candidate.name,
  )) {
    if (chosen != null) {
      rejected.add(BackendRejection(
        name: candidate.name,
        reason: RejectionReason.outranked,
        probe: candidate.probe,
        detail: 'chose ${chosen.name} first',
      ));
      continue;
    }
    if (pinned != null && candidate.name != pinned) {
      rejected.add(BackendRejection(
        name: candidate.name,
        reason: RejectionReason.notRequested,
        probe: candidate.probe,
      ));
      continue;
    }
    if (candidate.experimental && !allowExperimental) {
      rejected.add(BackendRejection(
        name: candidate.name,
        reason: RejectionReason.needsExplicitOptIn,
        probe: candidate.probe,
      ));
      continue;
    }
    if (!candidate.probe.supported) {
      rejected.add(BackendRejection(
        name: candidate.name,
        reason: RejectionReason.unsupported,
        probe: candidate.probe,
      ));
      continue;
    }
    final missing = required.difference(candidate.probe.capabilities);
    if (missing.isNotEmpty) {
      final names = missing.map((c) => c.name).toList()..sort();
      rejected.add(BackendRejection(
        name: candidate.name,
        reason: RejectionReason.missingCapability,
        probe: candidate.probe,
        detail: names.join(', '),
      ));
      continue;
    }
    chosen = candidate;
  }

  return BackendSelection(
    chosen: chosen,
    rejected: rejected,
    requested: pinned,
    required_: required,
    overrideSource: override.source,
  );
}

// ---------------------------------------------------------------------------
// Section 5.1: choosing the presentation path, and the override that pins it
// ---------------------------------------------------------------------------

/// Environment variable that pins the windowing backend, e.g. `x11`.
const String kBackendEnvironmentVariable = 'DART_UI_BACKEND';

/// Environment variable that pins the presentation path, e.g. `cpu`.
const String kPresentationEnvironmentVariable = 'DART_UI_PRESENTATION';

/// Command-line flag that pins the windowing backend.
const String kBackendFlag = '--backend';

/// Command-line flag that pins the presentation path.
const String kPresentationFlag = '--presentation';

/// A pinned name and where it came from.
final class SelectionOverride {
  const SelectionOverride(this.value, this.source);

  /// The name that was pinned, or null when nothing pinned anything.
  final String? value;

  final SelectionOverrideSource source;

  static const SelectionOverride none =
      SelectionOverride(null, SelectionOverrideSource.none);
}

/// Resolves the three ways a name can be pinned, most specific first.
///
/// Precedence is [explicit] > flag > environment, and the order is not
/// arbitrary. A value passed in code is a decision the program already made
/// and nothing outside it should overrule silently. A flag is typed for *this
/// run* by somebody watching the output. An environment variable outlives the
/// shell it was set in - it is the one most likely to still be exported from a
/// debugging session three days ago, which is precisely why it loses to a flag
/// rather than winning over it.
///
/// Both `--presentation=cpu` and `--presentation cpu` are accepted, because a
/// user who guesses the other form should not be told, silently, that they
/// pinned nothing. An empty value (`--presentation=`) is treated as *no*
/// override rather than as a path named `''`, which nothing can ever match.
SelectionOverride resolveSelectionOverride({
  String? explicit,
  required String flag,
  required String environmentVariable,
  List<String> arguments = const <String>[],
  Map<String, String> environment = const <String, String>{},
}) {
  if (explicit != null && explicit.isNotEmpty) {
    return SelectionOverride(explicit, SelectionOverrideSource.explicit);
  }
  for (var i = 0; i < arguments.length; i++) {
    final argument = arguments[i];
    if (argument.startsWith('$flag=')) {
      final value = argument.substring(flag.length + 1);
      if (value.isEmpty) continue;
      return SelectionOverride(value, SelectionOverrideSource.commandLineFlag);
    }
    if (argument == flag && i + 1 < arguments.length) {
      final value = arguments[i + 1];
      if (value.isEmpty) continue;
      return SelectionOverride(value, SelectionOverrideSource.commandLineFlag);
    }
  }
  final fromEnvironment = environment[environmentVariable];
  if (fromEnvironment != null && fromEnvironment.isNotEmpty) {
    return SelectionOverride(
      fromEnvironment,
      SelectionOverrideSource.environmentVariable,
    );
  }
  return SelectionOverride.none;
}

/// Which family of hardware a presentation path drives.
///
/// Two values, not a list of APIs. Selection cares about the *class* of the
/// path because that is what decides which [Capability] must be present; the
/// concrete API (`direct2d`, `metal`, `opengl`, a Win32 DIB section) is the
/// candidate's name, and nothing here branches on it.
enum PresentationKind {
  /// Renders on the GPU and presents through a swapchain or a layer.
  gpu,

  /// Rasterises into a CPU framebuffer the window can blit.
  cpu,
}

/// The capability a GPU presentation path must advertise.
///
/// This is the extension point [selectPresentation] hangs its GPU branch on,
/// and it is deliberately one named constant rather than a literal buried in
/// the scan. It was null while [Capability] had `cpuPresentation` and nothing
/// else - a GPU candidate could not be *verified*, only guessed at - and
/// flipping it here is the entire cost of turning the branch on.
///
/// `GlRendererBackend.probe` is the other half and reports
/// [Capability.gpuPresentation] exactly when a window surface can be handed to
/// `createTarget` and the pixels reach a screen without a readback. An
/// offscreen-only GL context still reports [Capability.cpuPresentation],
/// because that is what it honestly does.
///
/// Setting this to null again - or passing null to
/// [selectPresentation] - is still meaningful and still loud: every
/// [PresentationKind.gpu] candidate is then rejected with
/// [RejectionReason.missingCapability] and a detail that names this constant,
/// rather than quietly losing to the CPU path. That silent loss is the exact
/// failure section 6.6 exists to prevent: an application on the software
/// rasteriser on a machine with a good GPU and nothing in any log saying why.
// Nullable on purpose, and the analyzer is right that today's value is not:
// null is a meaningful setting here - "verify no GPU path" - and narrowing the
// type would make turning the branch off a compile error instead of a policy.
// ignore: unnecessary_nullable_for_final_variable_declarations
const Capability? kGpuPresentationCapability = Capability.gpuPresentation;

/// One way of getting pixels onto a window's surface.
final class PresentationCandidate {
  const PresentationCandidate({
    required this.name,
    required this.kind,
    required this.probe,
    this.experimental = false,
  });

  /// Stable identifier - `cpu`, `direct2d`, `opengl`, `win32-dib`. Selection
  /// policy may match on this; rendering code may not.
  final String name;

  final PresentationKind kind;
  final BackendProbeResult probe;

  /// Never chosen automatically, whatever it reports. Must be asked for.
  final bool experimental;
}

/// The outcome of choosing a presentation path.
final class PresentationSelection {
  const PresentationSelection({
    required this.chosen,
    required this.rejected,
    required this.requested,
    required this.overrideSource,
    required this.gpuPresentationCapability,
  });

  /// Null when nothing qualified. [describe] then says what was tried.
  final PresentationCandidate? chosen;

  final List<BackendRejection> rejected;
  final String? requested;
  final SelectionOverrideSource overrideSource;

  /// What GPU candidates were checked against, or null while the capability is
  /// unwired. Reported because "no GPU path qualified" means something very
  /// different in the two cases.
  final Capability? gpuPresentationCapability;

  bool get isSuccess => chosen != null;

  List<BackendProbeResult> get attempts => <BackendProbeResult>[
        if (chosen != null) chosen!.probe,
        for (final rejection in rejected) rejection.probe,
      ];

  BackendSelectionError toError() => BackendSelectionError(
        requested: requested,
        attempts: attempts,
      );

  /// The whole story in one blob, meant to be logged verbatim on startup.
  String describe() {
    final buffer = StringBuffer('presentation selection');
    if (requested != null) {
      buffer.write(' (requested: $requested');
      if (overrideSource != SelectionOverrideSource.none) {
        buffer.write(' via ${overrideSource.name}');
      }
      buffer.write(')');
    }
    buffer.writeln();
    buffer.writeln(
      chosen == null
          ? '  chosen: none'
          : '  chosen: ${chosen!.name} (${chosen!.kind.name})',
    );
    buffer.writeln(
      '  gpu capability: ${gpuPresentationCapability?.name ?? 'none supplied '
          '(see kGpuPresentationCapability)'}',
    );
    if (rejected.isEmpty) {
      buffer.writeln('  passed over: none');
    } else {
      buffer.writeln('  passed over:');
      for (final rejection in rejected) {
        buffer.writeln('    - $rejection');
      }
    }
    return buffer.toString();
  }
}

/// Chooses a presentation path under the policy of section 5.1.
///
/// The policy, in the order it is applied:
///
///   1. **Declared preference.** [preferred] re-orders [candidates] by name,
///      which is the `DartUiConfig(renderers: [...])` of the roadmap.
///   2. **Override.** [requested], then [kPresentationFlag] in [arguments],
///      then [kPresentationEnvironmentVariable] in [environment]. A pinned
///      path that cannot run is a failure, never a fallback.
///   3. **Capability.** A [PresentationKind.cpu] candidate must report
///      [Capability.cpuPresentation]; a [PresentationKind.gpu] candidate must
///      report [gpuPresentationCapability], and is rejected by name when that
///      is null. See [kGpuPresentationCapability].
///   4. **Report.** Every candidate that was passed over is in the result with
///      the reason, on success as much as on failure.
///
/// Note what is *not* here: no `try { ... } catch { next }`. A probe that
/// throws is a bug in the probe and must reach the caller; a probe that says
/// "no" says why in its own diagnostics, and those travel into the report.
PresentationSelection selectPresentation(
  List<PresentationCandidate> candidates, {
  List<String> preferred = const <String>[],
  String? requested,
  List<String> arguments = const <String>[],
  Map<String, String> environment = const <String, String>{},
  bool allowExperimental = false,
  Capability? gpuPresentationCapability = kGpuPresentationCapability,
}) {
  final override = resolveSelectionOverride(
    explicit: requested,
    flag: kPresentationFlag,
    environmentVariable: kPresentationEnvironmentVariable,
    arguments: arguments,
    environment: environment,
  );
  final pinned = override.value;
  final rejected = <BackendRejection>[];
  PresentationCandidate? chosen;

  for (final candidate in _rankByPreference(
    candidates,
    preferred,
    (PresentationCandidate candidate) => candidate.name,
  )) {
    if (chosen != null) {
      rejected.add(BackendRejection(
        name: candidate.name,
        reason: RejectionReason.outranked,
        probe: candidate.probe,
        detail: 'chose ${chosen.name} first',
      ));
      continue;
    }
    if (pinned != null && candidate.name != pinned) {
      rejected.add(BackendRejection(
        name: candidate.name,
        reason: RejectionReason.notRequested,
        probe: candidate.probe,
      ));
      continue;
    }
    if (candidate.experimental && !allowExperimental) {
      rejected.add(BackendRejection(
        name: candidate.name,
        reason: RejectionReason.needsExplicitOptIn,
        probe: candidate.probe,
      ));
      continue;
    }
    if (!candidate.probe.supported) {
      rejected.add(BackendRejection(
        name: candidate.name,
        reason: RejectionReason.unsupported,
        probe: candidate.probe,
      ));
      continue;
    }
    final required = switch (candidate.kind) {
      PresentationKind.cpu => Capability.cpuPresentation,
      PresentationKind.gpu => gpuPresentationCapability,
    };
    if (required == null) {
      rejected.add(BackendRejection(
        name: candidate.name,
        reason: RejectionReason.missingCapability,
        probe: candidate.probe,
        detail: 'gpuPresentation: no capability was supplied to verify a GPU '
            'path against, so this candidate could only have been guessed at. '
            'Pass selectPresentation(gpuPresentationCapability: ...), or use '
            'the default, kGpuPresentationCapability',
      ));
      continue;
    }
    if (!candidate.probe.supports(required)) {
      rejected.add(BackendRejection(
        name: candidate.name,
        reason: RejectionReason.missingCapability,
        probe: candidate.probe,
        detail: required.name,
      ));
      continue;
    }
    chosen = candidate;
  }

  return PresentationSelection(
    chosen: chosen,
    rejected: rejected,
    requested: pinned,
    overrideSource: override.source,
    gpuPresentationCapability: gpuPresentationCapability,
  );
}

/// [candidates], with the ones named in [preferred] hoisted to the front in
/// the order [preferred] gives them.
///
/// A stable partition rather than a sort: a name in [preferred] that matches
/// nothing is simply absent from the result, and a candidate nobody expressed
/// a preference about keeps its position relative to its peers. That matters
/// because the caller's list order is already a policy - it is the fallback
/// chain - and a preference for one entry must not scramble the rest of it.
List<T> _rankByPreference<T extends Object>(
  List<T> candidates,
  List<String> preferred,
  String Function(T candidate) nameOf,
) {
  if (preferred.isEmpty) return candidates;
  final ranked = <T>[];
  for (final name in preferred) {
    for (final candidate in candidates) {
      if (nameOf(candidate) == name && !ranked.contains(candidate)) {
        ranked.add(candidate);
      }
    }
  }
  for (final candidate in candidates) {
    if (!ranked.contains(candidate)) ranked.add(candidate);
  }
  return ranked;
}
