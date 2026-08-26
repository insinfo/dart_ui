/// `RenderPolicy` as the planner reads it: a kill switch really removes a
/// route, and the quality preference really moves the cover-pass threshold.
///
/// The seam under test is one line in [GpuPathPlanningTelemetry.plan]: what a
/// backend reports its device and pass can execute goes through
/// [RenderPolicy.restrict] before it reaches the selector. That is the only
/// place the two meet, which is what makes "the policy is wired" a checkable
/// claim for every backend at once rather than a promise repeated in three
/// capability probes.
///
/// Two properties are asserted beside the effect, because they are what make a
/// kill switch shippable rather than a debug build:
///
///   * **it is subtractive.** A route the device never reported cannot be
///     turned on by a policy, so a policy can cost frame time and cannot
///     produce a wrong picture;
///   * **it is observable.** Every subtraction lands in the frame diagnostics
///     with the reason, so a support log says which routes were off.
library;

import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/transform2d.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_path_planning.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_path_strategy.dart';
import 'package:dart_ui/src/rendering/path/fill_rule.dart';
import 'package:dart_ui/src/rendering/render_diagnostics.dart';
import 'package:dart_ui/src/rendering/render_policy.dart';
import 'package:test/test.dart';

void main() {
  // Everything the experimental executors of this repository can offer, so a
  // route that disappears disappeared because the policy removed it and not
  // because it was never on offer.
  const GpuPathStrategyCapabilities everything = GpuPathStrategyCapabilities(
    sparseStrips: true,
    tessellation: true,
    stencil: true,
    compute: true,
  );

  GpuPathStrategyDecision decide({
    required RenderPolicy policy,
    RenderDiagnosticsRecorder? diagnostics,
    GpuPathStrategyCapabilities capabilities = everything,
    Path? path,
    Rect clip = const Rect.fromLTRB(0, 0, 512, 512),
  }) {
    final GpuPathPlanningTelemetry telemetry = GpuPathPlanningTelemetry(
      policy: policy,
      diagnostics: diagnostics,
      candidateCapabilities: capabilities,
      stabilityProbe: (_) => true,
    );
    final GpuPathPlanningProposal? proposal = telemetry.plan(
      label: 'policy',
      path: path ?? _triangle(),
      localToTarget: Transform2D.identity,
      clip: clip,
      fillRule: FillRule.nonZero,
      denseMaskCacheHit: false,
    );
    expect(proposal, isNotNull, reason: '${telemetry.lastError}');
    return proposal!.candidate;
  }

  group('the kill switches reach the selector', () {
    test('tessellation off moves a retainable mesh off that route', () {
      expect(
        decide(policy: RenderPolicy.defaults).strategy,
        GpuPathStrategy.tessellatedMesh,
        reason: 'the baseline this test is about turning off',
      );

      final GpuPathStrategyDecision restricted = decide(
        policy: const RenderPolicy(
          strategies: GpuStrategySwitches(tessellation: false),
        ),
      );

      expect(restricted.strategy, isNot(GpuPathStrategy.tessellatedMesh));
    });

    test('denseOnly leaves the parity route and nothing else', () {
      final GpuPathStrategyDecision restricted = decide(
        policy: const RenderPolicy(strategies: GpuStrategySwitches.denseOnly),
      );

      expect(
        restricted.strategy,
        anyOf(
          GpuPathStrategy.coverageAtlas,
          GpuPathStrategy.analyticPrimitive,
        ),
        reason: 'every optional route falls back to the dense analytic atlas, '
            'which is why a kill switch cannot produce a wrong picture',
      );
    });

    test('a policy cannot turn on a route the device never reported', () {
      // The device offers the dense atlas only. `GpuStrategySwitches.all` says
      // nothing is disabled - it does not say anything is available.
      final GpuPathStrategyDecision decision = decide(
        policy: const RenderPolicy(),
        capabilities: const GpuPathStrategyCapabilities(),
      );

      expect(decision.strategy, GpuPathStrategy.coverageAtlas);
    });

    test('every subtraction is recorded with its reason', () {
      final RenderDiagnosticsRecorder recorder =
          RenderDiagnosticsRecorder.forMode(RenderDiagnosticsMode.counters);
      recorder.beginFrame();

      decide(
        policy: const RenderPolicy(
          strategies: GpuStrategySwitches(
            tessellation: false,
            sparseStrips: false,
          ),
          diagnostics: RenderDiagnosticsMode.counters,
        ),
        diagnostics: recorder,
      );

      final FrameRenderDiagnostics frame = recorder.snapshot();
      expect(
        frame.refusalFor(GpuPathStrategy.tessellatedMesh),
        kStrategyDisabledByPolicy,
      );
      expect(
        frame.refusalFor(GpuPathStrategy.sparseStrips),
        kStrategyDisabledByPolicy,
      );
    });
  });

  group('the quality preference reaches the selector', () {
    test('exact removes the cover pass and names why', () {
      final RenderDiagnosticsRecorder recorder =
          RenderDiagnosticsRecorder.forMode(RenderDiagnosticsMode.counters);
      recorder.beginFrame();

      decide(
        policy: const RenderPolicy(
          quality: RenderQualityPreference.exact,
          diagnostics: RenderDiagnosticsMode.counters,
        ),
        diagnostics: recorder,
      );

      expect(
        recorder.snapshot().refusalFor(GpuPathStrategy.stencilThenCover),
        kStencilRefusedForQuality,
      );
    });

    test('the selector carries the threshold the policy asked for', () {
      // The trade `RenderQualityPreference` exists for is a *number* on the
      // selector, not a branch in `restrict`, so this is the half that would
      // silently do nothing if only the capabilities were policy-aware.
      expect(
        GpuPathPlanningTelemetry(
          policy: const RenderPolicy(quality: RenderQualityPreference.speed),
        ).selector.stencilMinimumDenseMaskBytes,
        4096,
      );
      expect(
        GpuPathPlanningTelemetry(policy: RenderPolicy.defaults)
            .selector
            .stencilMinimumDenseMaskBytes,
        16384,
      );
      expect(
        GpuPathPlanningTelemetry(
          selector: const GpuPathStrategySelector(
            stencilMinimumDenseMaskBytes: 1,
          ),
          policy: const RenderPolicy(quality: RenderQualityPreference.speed),
        ).selector.stencilMinimumDenseMaskBytes,
        1,
        reason: 'a caller that names a selector is not reading the policy',
      );
    });
  });

  group('the installed process policy is what an unconfigured backend gets',
      () {
    tearDown(RenderPolicyScope.reset);

    test('a telemetry built with no policy reads the installed one', () {
      RenderPolicyScope.install(
        const RenderPolicy(
          strategies: GpuStrategySwitches(tessellation: false),
        ),
      );

      final GpuPathPlanningTelemetry telemetry = GpuPathPlanningTelemetry(
        candidateCapabilities: everything,
        stabilityProbe: (_) => true,
      );
      final GpuPathStrategy strategy = telemetry
          .plan(
            label: 'installed',
            path: _triangle(),
            localToTarget: Transform2D.identity,
            clip: const Rect.fromLTRB(0, 0, 512, 512),
            fillRule: FillRule.nonZero,
            denseMaskCacheHit: false,
          )!
          .candidate
          .strategy;

      expect(strategy, isNot(GpuPathStrategy.tessellatedMesh));
    });

    test('the default install changes nothing', () {
      RenderPolicyScope.install(RenderPolicy.defaults);

      expect(
        GpuPathPlanningTelemetry(
          candidateCapabilities: everything,
          stabilityProbe: (_) => true,
        )
            .plan(
              label: 'default',
              path: _triangle(),
              localToTarget: Transform2D.identity,
              clip: const Rect.fromLTRB(0, 0, 512, 512),
              fillRule: FillRule.nonZero,
              denseMaskCacheHit: false,
            )!
            .candidate
            .strategy,
        GpuPathStrategy.tessellatedMesh,
      );
    });
  });
}

Path _triangle() => (PathBuilder()
      ..moveTo(4, 4)
      ..lineTo(300, 8)
      ..lineTo(150, 280)
      ..close())
    .build();
