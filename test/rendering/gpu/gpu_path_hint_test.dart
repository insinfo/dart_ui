/// The content hint as the selector reads it, and the promise it keeps.
///
/// Two halves, and the second is the important one:
///
///   * the hint *participates*: it moves a draw between routes exactly where
///     the history-based repetition model would have answered a frame late;
///   * the hint is *advice*: it is ordered after the two facts it must not
///     overrule, it cannot reach a capability, and it cannot reach a
///     correctness fact. `test/widgets/content_hint_test.dart` takes the same
///     claim to pixels.
library;

import 'package:dart_ui/src/graphics/content_hint.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_path_strategy.dart';
import 'package:dart_ui/src/rendering/render_policy.dart';
import 'package:test/test.dart';

void main() {
  const GpuPathStrategySelector selector = GpuPathStrategySelector();

  GpuPathWorkload workload({
    int width = 256,
    int height = 256,
    int segments = 40,
    bool analytic = false,
    bool cacheHit = false,
    bool cacheable = false,
    bool stable = false,
    bool selfIntersects = false,
    bool tessellationEligible = false,
    int? crossings,
  }) =>
      GpuPathWorkload(
        pixelWidth: width,
        pixelHeight: height,
        segmentCount: segments,
        isAnalyticPrimitive: analytic,
        denseMaskCacheHit: cacheHit,
        denseMaskLikelyCacheable: cacheable,
        geometryStable: stable,
        hasSelfIntersections: selfIntersects,
        tessellationEligible: tessellationEligible,
        sparseEstimatedDrawCalls: 2,
        sparseAtlasPageCount: 1,
        tileCrossings: crossings,
      );

  // Everything the experimental executors of this repository can offer, so a
  // test that expects a hint *not* to change the answer cannot be passing
  // because there was no other answer available.
  const GpuPathStrategyCapabilities everything = GpuPathStrategyCapabilities(
    sparseStrips: true,
    tessellation: true,
    stencil: true,
  );

  group('the hint participates in the decision', () {
    test('animating overrides a repeat the history model believed in', () {
      // The case the architecture document names: a subtree that has been
      // still for many frames starts moving. The repetition model still says
      // "this repeats", because all it has is the previous frames, and it
      // will go on saying so until the next frame proves otherwise. The
      // declaration answers before that frame is drawn.
      final GpuPathWorkload w = workload(cacheable: true, crossings: 200);

      expect(
        selector.select(w, everything).strategy,
        GpuPathStrategy.coverageAtlas,
        reason: 'without advice, history decides and it is one frame stale',
      );
      expect(
        selector.select(w, everything, hint: ContentHint.animating).strategy,
        isNot(GpuPathStrategy.coverageAtlas),
      );
    });

    test('staticContent reaches the atlas before the second sighting', () {
      // The mirror image, and the one that costs a frame in the other
      // direction: a static shape's *first* frame looks fresh to the history
      // model, so it is promoted to a route that never populates the atlas -
      // and because a promoted draw never reaches the atlas, the mask it
      // would have cached is not there on the second frame either.
      final GpuPathWorkload w = workload(crossings: 200);

      expect(
        selector.select(w, everything).strategy,
        GpuPathStrategy.sparseStrips,
      );
      expect(
        selector
            .select(w, everything, hint: ContentHint.staticContent)
            .strategy,
        GpuPathStrategy.coverageAtlas,
        reason: 'the atlas is warmed on the frame the subtree appears, not '
            'on the frame after the one that proved it repeats',
      );
    });

    test('transforming is not a synonym for animating', () {
      // The split no single boolean could express: local geometry repeats, so
      // a mesh keyed on local coordinates survives, while the dense mask -
      // keyed on device space - misses every frame of the zoom.
      final GpuPathWorkload w = workload(
        cacheable: true,
        tessellationEligible: true,
        crossings: 20000,
      );

      expect(
        selector.select(w, everything, hint: ContentHint.transforming).strategy,
        GpuPathStrategy.tessellatedMesh,
      );
      expect(
        selector.select(w, everything, hint: ContentHint.animating).strategy,
        isNot(GpuPathStrategy.tessellatedMesh),
        reason: 'animating geometry has no mesh to retain',
      );
    });
  });

  group('the hint is advice, not an order', () {
    test('an analytic primitive stays analytic under every hint', () {
      for (final ContentMotionHint motion in ContentMotionHint.values) {
        expect(
          selector
              .select(
                workload(analytic: true, cacheable: true, crossings: 4),
                everything,
                hint: ContentHint(motion: motion),
              )
              .strategy,
          GpuPathStrategy.analyticPrimitive,
          reason: '$motion',
        );
      }
    });

    test('a resident mask is a measurement and survives animating', () {
      // The single case where a wrong hint could have cost more than the
      // frame it was meant to save: the mask is *already there*, so it costs
      // one quad and no transfer however the subtree is moving.
      expect(
        selector
            .select(
              workload(cacheHit: true, crossings: 4),
              everything,
              hint: ContentHint.animating,
            )
            .strategy,
        GpuPathStrategy.coverageAtlas,
      );
    });

    test('a hint cannot enable a route the device did not report', () {
      const GpuPathStrategyCapabilities denseOnly =
          GpuPathStrategyCapabilities();
      for (final ContentMotionHint motion in ContentMotionHint.values) {
        expect(
          selector
              .select(
                workload(cacheable: true, crossings: 4),
                denseOnly,
                hint: ContentHint(motion: motion),
              )
              .strategy,
          GpuPathStrategy.coverageAtlas,
          reason: '$motion must not invent an executor',
        );
      }
    });

    test('a hint cannot win the cost rule that sparse still has to win', () {
      // `crossings * k < area` is measured, not declared. A shape dense in
      // edges loses it, and saying "animating" does not change how many tile
      // crossings it costs - only which routes are worth pricing.
      final GpuPathWorkload edgeDense = workload(crossings: 20000);
      const GpuPathStrategyCapabilities sparseOnly =
          GpuPathStrategyCapabilities(sparseStrips: true);

      expect(
        selector
            .select(edgeDense, sparseOnly, hint: ContentHint.animating)
            .strategy,
        GpuPathStrategy.coverageAtlas,
      );
      expect(
        selector
            .select(workload(crossings: 20), sparseOnly,
                hint: ContentHint.animating)
            .strategy,
        GpuPathStrategy.sparseStrips,
        reason: 'the same hint on a shape that does win the rule',
      );
    });

    test('a hint cannot touch a correctness fact', () {
      // Tessellation eligibility and self-intersection decide whether a route
      // draws the *right shape*, which is why they are not in the two fields
      // a hint may move. A refused topology stays refused.
      final GpuPathWorkload refused = workload(
        selfIntersects: true,
        crossings: 20000,
      );
      for (final ContentMotionHint motion in ContentMotionHint.values) {
        final GpuPathWorkload hinted =
            refused.withContentHint(ContentHint(motion: motion));
        expect(hinted.hasSelfIntersections, isTrue, reason: '$motion');
        expect(hinted.tessellationEligible, isFalse, reason: '$motion');
        expect(hinted.tileCrossings, refused.tileCrossings, reason: '$motion');
        expect(hinted.denseMaskCacheHit, refused.denseMaskCacheHit,
            reason: '$motion');
        expect(
          selector
              .select(
                refused,
                const GpuPathStrategyCapabilities(tessellation: true),
                hint: ContentHint(motion: motion),
              )
              .strategy,
          isNot(GpuPathStrategy.tessellatedMesh),
          reason: '$motion',
        );
      }
    });

    test('an undeclared hint is the behaviour that existed before hints', () {
      for (final bool cacheable in <bool>[false, true]) {
        for (final int? crossings in <int?>[null, 20, 20000]) {
          final GpuPathWorkload w =
              workload(cacheable: cacheable, crossings: crossings);
          expect(
            identical(w.withContentHint(ContentHint.none), w),
            isTrue,
            reason: 'no allocation and no change on the common path',
          );
          expect(
            selector.select(w, everything, hint: ContentHint.none).strategy,
            selector.select(w, everything).strategy,
          );
        }
      }
    });

    test('quality is the policy seam, and it is separate from motion', () {
      // A motion declaration must not move the edge-quality trade, and a
      // quality declaration must not move the motion facts.
      const RenderPolicy policy = RenderPolicy.defaults;
      expect(policy.qualityFor(ContentHint.animating),
          RenderQualityPreference.balanced);
      expect(
        policy.qualityFor(
            const ContentHint(quality: RenderQualityHint.preferQuality)),
        RenderQualityPreference.exact,
      );
      final GpuPathWorkload w = workload(cacheable: true);
      expect(
        identical(
          w.withContentHint(
              const ContentHint(quality: RenderQualityHint.preferSpeed)),
          w,
        ),
        isTrue,
      );
    });

    test('RenderPolicy.applyContentHint is the same rule', () {
      // The forwarder kept for the name the seam was documented under.
      final GpuPathWorkload w = workload(cacheable: true, stable: true);
      for (final ContentMotionHint motion in ContentMotionHint.values) {
        const List<RenderQualityHint> qualities = RenderQualityHint.values;
        for (final RenderQualityHint quality in qualities) {
          final ContentHint hint =
              ContentHint(motion: motion, quality: quality);
          final GpuPathWorkload viaPolicy =
              RenderPolicy.applyContentHint(w, hint);
          final GpuPathWorkload viaWorkload = w.withContentHint(hint);
          expect(viaPolicy.geometryStable, viaWorkload.geometryStable);
          expect(viaPolicy.denseMaskLikelyCacheable,
              viaWorkload.denseMaskLikelyCacheable);
        }
      }
    });
  });
}
