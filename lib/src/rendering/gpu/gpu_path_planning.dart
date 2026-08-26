/// Observe strategy decisions for real path draws without changing pixels.
library;

import '../../geometry/path.dart';
import '../../geometry/rect.dart';
import '../../geometry/transform2d.dart';
import '../../graphics/content_hint.dart';
import '../path/fill_rule.dart';
import '../render_diagnostics.dart';
import '../render_policy.dart';
import 'gpu_path_strategy.dart';
import 'gpu_path_workload_builder.dart';
import 'vector/sparse_strip_draw_plan.dart';

typedef GpuPathStabilityProbe = bool Function(Path path);

/// The properties of one draw that change which routes are *correct* for it,
/// as opposed to merely cheaper.
///
/// Both are about the paint rather than the geometry, which is why neither
/// belongs in [GpuPathWorkload]: a workload describes what the shape costs, and
/// two draws of the same shape can have different answers here.
final class GpuPathDrawTraits {
  const GpuPathDrawTraits({this.antiAlias = true, this.hasGradient = false});

  /// Whether the fill needs a coverage fringe. A route that produces none is
  /// a correct answer for an aliased fill and a visibly wrong one otherwise.
  final bool antiAlias;

  /// Whether the paint carries a gradient shader.
  ///
  /// This one does not merely narrow the choice, it can *invert* it: the dense
  /// coverage atlas stores alpha and modulates it by a single colour, so it
  /// cannot draw a gradient at all. A pass that reports `coverageAtlas` for a
  /// gradient draw is promising a picture it would render as a flat fill.
  final bool hasGradient;

  @override
  bool operator ==(Object other) =>
      other is GpuPathDrawTraits &&
      other.antiAlias == antiAlias &&
      other.hasGradient == hasGradient;

  @override
  int get hashCode => Object.hash(antiAlias, hasGradient);

  @override
  String toString() =>
      'GpuPathDrawTraits(antiAlias: $antiAlias, hasGradient: $hasGradient)';
}

/// What the *current* render pass can execute for a draw of this kind.
///
/// Capabilities are not constant across a frame, and they are not constant
/// across draws within a pass either. Two things decide together:
///
///   * the pass's attachments - stencil-then-cover needs a stencil buffer, and
///     geometric antialiasing needs samples - which differ between the surface
///     and a pooled layer target inside the same frame;
///   * the draw's own [GpuPathDrawTraits].
///
/// A fixed [GpuPathPlanningTelemetry.candidateCapabilities] can only describe
/// the device. This describes the target and the draw. See
/// `gpu_layer_stack.dart`'s `GpuPassAttachments`.
typedef GpuPathCapabilitiesProbe = GpuPathStrategyCapabilities Function(
  GpuPathDrawTraits traits,
);

/// Whether the dense atlas would by now be caching this draw, had an
/// experimental route not been taking it. See `gpu_path_repetition.dart` for
/// why that is a different question from `denseMaskCacheHit`, and for the
/// measurement that made it necessary.
/// How many (segment, tile) crossings the sparse encoder had to visit for the
/// draw the sparse metrics were just measured for.
///
/// Separate from `sparseMetricsProbe` rather than folded into its result,
/// because that result type is shared with backends that do not measure this
/// and adding a field there would have them reporting a number they never
/// computed. Null means "not measured", which the selector reads as a reason
/// to keep the older transfer-bytes rule.
typedef GpuPathCrossingsProbe = int? Function();

typedef GpuPathRepetitionProbe = bool Function(
  Path path,
  Transform2D localToTarget,
  Rect clip,
  FillRule fillRule,
);
typedef GpuSparseMetricsProbe = SparseStripPlanMetrics? Function(
  Path path,
  Transform2D localToTarget,
  Rect clip,
  FillRule fillRule,
);

/// A selector result that has not affected the command stream yet.
///
/// Planning and execution are deliberately separate. An experimental backend
/// first obtains this immutable proposal, then attempts to record a complete
/// ordered command. Only after that attempt does [GpuPathPlanningTelemetry]
/// publish an event naming the strategy that really owns the pixels.
final class GpuPathPlanningProposal {
  const GpuPathPlanningProposal({
    required this.label,
    required this.workload,
    required this.candidate,
    this.hint = ContentHint.none,
  });

  final String label;

  /// The measured facts, **before** [hint] was applied.
  ///
  /// Raw on purpose: a telemetry event has to be able to say what was
  /// measured and what was declared separately, or a support log cannot tell a
  /// route chosen from evidence apart from one chosen from advice.
  /// [effectiveWorkload] is the pair combined, which is what the selector
  /// actually read.
  final GpuPathWorkload workload;
  final GpuPathStrategyDecision candidate;

  /// What the application declared about the subtree this draw is in.
  final ContentHint hint;

  /// [workload] as the selector saw it.
  GpuPathWorkload get effectiveWorkload => workload.withContentHint(hint);

  /// True when the hint actually moved a cost fact for this draw.
  bool get hintChangedWorkload => !identical(effectiveWorkload, workload);
}

/// One advisory decision and the strategy that actually produced its pixels.
final class GpuPathPlanningEvent {
  const GpuPathPlanningEvent({
    required this.label,
    required this.workload,
    required this.candidate,
    this.hint = ContentHint.none,
    this.executedStrategy = GpuPathStrategy.coverageAtlas,
  });

  final String label;
  final GpuPathWorkload workload;
  final GpuPathStrategyDecision candidate;

  /// The application's advice that was in force for this draw. Reported
  /// beside the measured [workload] rather than folded into it, so a log can
  /// separate what was measured from what was declared.
  final ContentHint hint;

  /// The strategy that was actually recorded for ordered submission.
  ///
  /// Coverage-atlas remains the default so an observer attached to the
  /// established dense replay reports the truth without any extra argument.
  /// Experimental dispatch supplies its accepted strategy only after it has
  /// successfully recorded a complete command; a rejected or partial plan
  /// must leave this as coverage rather than claiming pixels it never drew.
  final GpuPathStrategy executedStrategy;

  bool get candidateDiffersFromExecution =>
      candidate.strategy != executedStrategy;
}

/// Optional telemetry seam used by [GpuRasterSink]'s dense path route.
///
/// Candidate capabilities may describe experimental executors, but this
/// object never dispatches to them. It derives a workload and reports what the
/// selector would choose while the sink continues through its existing dense
/// mask atlas. Planning and callback failures are contained and recorded so
/// enabling telemetry cannot turn a renderable frame into an exception.
final class GpuPathPlanningTelemetry {
  GpuPathPlanningTelemetry({
    this.builder = const GpuPathWorkloadBuilder(),
    GpuPathStrategySelector? selector,
    RenderPolicy? policy,
    RenderDiagnosticsRecorder? diagnostics,
    this.candidateCapabilities = const GpuPathStrategyCapabilities(),
    this.capabilitiesProbe,
    this.stabilityProbe,
    this.repetitionProbe,
    this.sparseMetricsProbe,
    this.crossingsProbe,
    this.onEvent,
  })  : policy = policy ?? RenderPolicyScope.policy,
        diagnostics = diagnostics ?? RenderPolicyScope.diagnostics,
        selector =
            selector ?? (policy ?? RenderPolicyScope.policy).buildSelector();

  final GpuPathWorkloadBuilder builder;

  /// The application's declared policy, read once when this object is built.
  ///
  /// Once and not per draw, because `Application.start` installs the policy
  /// before any backend opens a device and a policy that could change under a
  /// running frame would make two draws of the same shape in one frame answer
  /// differently. A caller that passes one explicitly - a test - is not
  /// reading the scope at all.
  final RenderPolicy policy;

  /// Where [RenderPolicy.restrict] records what it took away.
  ///
  /// [RenderDiagnosticsRecorder.disabled] unless the policy asked for
  /// diagnostics, so an unconfigured process pays nothing per draw.
  final RenderDiagnosticsRecorder diagnostics;

  /// The selector [policy] asks for, unless the caller named one.
  ///
  /// This is how [RenderQualityPreference] reaches the branch it changes:
  /// `speed` and `exact` move [RenderPolicy.stencilThresholdFor], and the
  /// threshold is a field of the selector rather than an argument to it.
  final GpuPathStrategySelector selector;

  /// The device-wide answer, used when [capabilitiesProbe] is null.
  final GpuPathStrategyCapabilities candidateCapabilities;

  /// Per-draw capabilities of the pass being recorded into, when the backend
  /// can tell them apart from the device's. A probe that throws is contained
  /// like any other planning failure: the draw stays on the dense atlas.
  final GpuPathCapabilitiesProbe? capabilitiesProbe;

  final GpuPathStabilityProbe? stabilityProbe;

  /// Asked once per observed draw, before the sparse cost is even measured.
  /// Null means every draw is treated as fresh, which is what this class did
  /// before the probe existed.
  final GpuPathRepetitionProbe? repetitionProbe;
  final GpuSparseMetricsProbe? sparseMetricsProbe;

  /// Asked immediately after [sparseMetricsProbe], so it reports the encode
  /// that probe just performed.
  final GpuPathCrossingsProbe? crossingsProbe;
  final void Function(GpuPathPlanningEvent event)? onEvent;

  int observationCount = 0;
  int failureCount = 0;
  GpuPathPlanningEvent? lastEvent;
  Object? lastError;
  StackTrace? lastStackTrace;

  GpuPathPlanningEvent? observe({
    required String label,
    required Path path,
    required Transform2D localToTarget,
    required Rect clip,
    required FillRule fillRule,
    required bool denseMaskCacheHit,
    GpuPathDrawTraits traits = const GpuPathDrawTraits(),
    ContentHint hint = ContentHint.none,
    GpuPathStrategy executedStrategy = GpuPathStrategy.coverageAtlas,
  }) {
    final GpuPathPlanningProposal? proposal = plan(
      label: label,
      path: path,
      localToTarget: localToTarget,
      clip: clip,
      fillRule: fillRule,
      denseMaskCacheHit: denseMaskCacheHit,
      traits: traits,
      hint: hint,
    );
    if (proposal == null) return null;
    return complete(proposal, executedStrategy: executedStrategy);
  }

  /// Selects a candidate without publishing an execution event.
  GpuPathPlanningProposal? plan({
    required String label,
    required Path path,
    required Transform2D localToTarget,
    required Rect clip,
    required FillRule fillRule,
    required bool denseMaskCacheHit,
    GpuPathDrawTraits traits = const GpuPathDrawTraits(),
    // What the application declared about the subtree, delivered at the sink
    // boundary by `ContentHintAwareSink`. `ContentHint.none` - the default -
    // is a backend that has not wired the seam, and reproduces exactly the
    // behaviour this class had before the hint existed.
    ContentHint hint = ContentHint.none,
  }) {
    observationCount++;
    try {
      // The backend reports what its device and this pass can execute; the
      // policy takes routes away from that and can never add one. This is the
      // single place the two meet, which is why it is here rather than
      // repeated in each backend's capability probe: a backend added later
      // gets the kill switches and the quality trade without knowing they
      // exist, and there is one place to read to find out whether a route was
      // removed by the device or by the application.
      final GpuPathStrategyCapabilities capabilities = policy.restrict(
        capabilitiesProbe?.call(traits) ?? candidateCapabilities,
        diagnostics: diagnostics,
      );
      final workload = builder.build(
        path,
        bounds: localToTarget.transformRect(path.bounds),
        clip: clip,
        localToTarget: localToTarget,
        geometryStable: stabilityProbe?.call(path) ?? false,
        denseMaskCacheHit: denseMaskCacheHit,
        denseMaskLikelyCacheable:
            repetitionProbe?.call(path, localToTarget, clip, fillRule) ?? false,
        // Measured only where the answer can be acted on. The sparse probe
        // rasterises the path to find out how large its encoding is, and doing
        // that for a pass that cannot execute sparse strips would spend the
        // CPU cost of the route without any chance of its benefit.
        sparseMetrics: capabilities.sparseStrips
            ? sparseMetricsProbe?.call(path, localToTarget, clip, fillRule)
            : null,
        // After the metrics probe and only when it ran: it reports the encode
        // that probe just performed.
        tileCrossings:
            capabilities.sparseStrips ? crossingsProbe?.call() : null,
      );
      final proposal = GpuPathPlanningProposal(
        label: label,
        workload: workload,
        hint: hint,
        // The hint goes to the selector rather than being applied here: the
        // precedence rule - what a hint may and may not overrule - belongs
        // beside the branches it is ordered against. See
        // [GpuPathStrategySelector.select].
        candidate: selector.select(workload, capabilities, hint: hint),
      );
      lastError = null;
      lastStackTrace = null;
      return proposal;
    } catch (error, stackTrace) {
      failureCount++;
      lastEvent = null;
      lastError = error;
      lastStackTrace = stackTrace;
      return null;
    }
  }

  /// Publishes [proposal] after ordered recording chose its real executor.
  GpuPathPlanningEvent complete(
    GpuPathPlanningProposal proposal, {
    required GpuPathStrategy executedStrategy,
  }) {
    final event = GpuPathPlanningEvent(
      label: proposal.label,
      workload: proposal.workload,
      candidate: proposal.candidate,
      hint: proposal.hint,
      executedStrategy: executedStrategy,
    );
    lastEvent = event;
    lastError = null;
    lastStackTrace = null;
    try {
      onEvent?.call(event);
    } catch (error, stackTrace) {
      failureCount++;
      lastError = error;
      lastStackTrace = stackTrace;
    }
    return event;
  }
}
