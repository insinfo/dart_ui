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

/// The outcome of selection, whether or not it succeeded.
final class BackendSelection {
  const BackendSelection({
    required this.chosen,
    required this.rejected,
    required this.requested,
    required this.required_,
  });

  /// Null when nothing qualified. [describe] then says what was tried.
  final BackendCandidate? chosen;

  final List<BackendRejection> rejected;
  final String? requested;
  final Set<Capability> required_;

  bool get isSuccess => chosen != null;

  /// The whole story in one blob, meant to be logged verbatim on startup.
  ///
  /// Printed even on success: knowing that Metal was chosen is useful, and
  /// knowing that Vulkan was right behind it and why is what makes the next
  /// bug report answerable.
  String describe() {
    final buffer = StringBuffer('backend selection');
    if (requested != null) buffer.write(' (requested: $requested)');
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
/// belongs here.
///
/// [requested] pins one by name. A pinned backend that cannot run is a
/// failure, never a silent fallback: the caller asked for something specific
/// and quietly giving them something else is exactly the behaviour section 6.6
/// is written against.
BackendSelection selectBackend(
  List<BackendCandidate> candidates, {
  String? requested,
  Set<Capability> required = const <Capability>{},
  bool allowExperimental = false,
}) {
  final rejected = <BackendRejection>[];
  BackendCandidate? chosen;

  for (final candidate in candidates) {
    if (chosen != null) {
      rejected.add(BackendRejection(
        name: candidate.name,
        reason: RejectionReason.outranked,
        probe: candidate.probe,
        detail: 'chose ${chosen.name} first',
      ));
      continue;
    }
    if (requested != null && candidate.name != requested) {
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
    requested: requested,
    required_: required,
  );
}
