/// The repetition model, and the selector branch it feeds.
library;

import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/transform2d.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_path_repetition.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_path_strategy.dart';
import 'package:dart_ui/src/rendering/path/fill_rule.dart';
import 'package:test/test.dart';

void main() {
  GpuPathRepetitionKey keyFor(Path path, {double dx = 0}) =>
      GpuPathRepetitionKey(
        path,
        transform: Transform2D.translation(dx, 0),
        clip: const Rect.fromLTRB(0, 0, 256, 256),
        fillRule: FillRule.nonZero,
      );

  Path square() => (PathBuilder()
        ..moveTo(0, 0)
        ..lineTo(40, 0)
        ..lineTo(40, 40)
        ..lineTo(0, 40)
        ..close())
      .build();

  group('GpuPathRepetitionTracker', () {
    test('a first sighting is fresh, a second is cacheable', () {
      final tracker = GpuPathRepetitionTracker();
      tracker.beginFrame();
      expect(tracker.observe(keyFor(square())), isFalse,
          reason: 'nothing has been drawn yet, so nothing can be cached');
      tracker.beginFrame();
      expect(tracker.observe(keyFor(square())), isTrue,
          reason: 'the atlas would have rasterised it on the frame before');
      expect(tracker.freshCount, 1);
      expect(tracker.cacheableCount, 1);
    });

    test('the key is by content, which is what makes it work at all', () {
      // A rebuilt display list produces a new Path object with the same verbs.
      // Identity would call every frame of a static screen "fresh" and the
      // model would never fire.
      final tracker = GpuPathRepetitionTracker();
      tracker.beginFrame();
      tracker.observe(keyFor(square()));
      tracker.beginFrame();
      expect(tracker.observe(keyFor(square())), isTrue);
    });


    test('a whole-pixel translation still hits, as the atlas would', () {
      // Guard 4 from the reference survey: the dense atlas keys on the mask's
      // *sub-pixel* offset and size, not on the absolute translation, so a
      // shape scrolled by exact pixels is a cache hit there. A repetition key
      // holding the raw transform would call every frame of a scrolling list a
      // new draw and hand it to another route - losing exactly the hits the
      // atlas was built to capture.
      final tracker = GpuPathRepetitionTracker();
      tracker.beginFrame();
      tracker.observe(keyFor(square()));
      for (var frame = 1; frame < 5; frame++) {
        tracker.beginFrame();
        expect(tracker.observe(keyFor(square(), dx: frame * 4.0)), isTrue,
            reason: 'whole-pixel scroll, frame $frame');
      }
    });

    test('a sub-pixel translation is a different draw', () {
      // The other side: the atlas would miss, because the coverage really is
      // different, so predicting a hit would be predicting the wrong thing.
      final tracker = GpuPathRepetitionTracker();
      tracker.beginFrame();
      tracker.observe(keyFor(square()));
      tracker.beginFrame();
      expect(tracker.observe(keyFor(square(), dx: 0.25)), isFalse);
    });

    test('scale is compared exactly, never approximately', () {
      // Every reference agrees on this: Skia requires the 2x2 to match
      // exactly, Vello's glyph cache compares f32 bits. A mask reused at a
      // different scale is a blurrier mask, not a cheaper one.
      final tracker = GpuPathRepetitionTracker();
      tracker.beginFrame();
      tracker.observe(GpuPathRepetitionKey(square(),
          transform: Transform2D.identity,
          clip: const Rect.fromLTRB(0, 0, 256, 256),
          fillRule: FillRule.nonZero));
      tracker.beginFrame();
      expect(
        tracker.observe(GpuPathRepetitionKey(square(),
            transform: const Transform2D(1.001, 0, 0, 1.001, 0, 0),
            clip: const Rect.fromLTRB(0, 0, 256, 256),
            fillRule: FillRule.nonZero)),
        isFalse,
        reason: 'a scale that differs by a thousandth is a different mask',
      );
    });

    test('a shape that moves never becomes cacheable', () {
      // The workload the whole model has to get right: an animation produces a
      // new device transform every frame, so the atlas would be rasterising it
      // every frame too, and there is nothing for it to cache.
      final tracker = GpuPathRepetitionTracker();
      for (var frame = 0; frame < 20; frame++) {
        tracker.beginFrame();
        // Sub-pixel motion, which is what an animation actually produces and
        // what the atlas genuinely cannot cache.
        expect(tracker.observe(keyFor(square(), dx: frame * 0.25)), isFalse,
            reason: 'frame $frame');
      }
      expect(tracker.cacheableCount, 0);
      expect(tracker.length, lessThanOrEqualTo(tracker.capacity));
    });

    test('a gap in the run starts it again', () {
      // A shape that flickers is not the steady state this protects, and the
      // atlas may well have evicted it in between.
      final tracker = GpuPathRepetitionTracker();
      tracker.beginFrame();
      tracker.observe(keyFor(square()));
      tracker.beginFrame();
      expect(tracker.observe(keyFor(square())), isTrue);
      tracker
        ..beginFrame()
        ..beginFrame();
      expect(tracker.observe(keyFor(square())), isFalse,
          reason: 'it missed a frame, so the run restarts');
    });

    test('the map is bounded, because the key holds a transform', () {
      // A step that does not divide a pixel, so no two frames share a
      // sub-pixel phase: 0.25 would repeat every fourth frame and the cache
      // would hold four entries rather than filling.
      final tracker = GpuPathRepetitionTracker(capacity: 8);
      for (var frame = 0; frame < 50; frame++) {
        tracker.beginFrame();
        tracker.observe(keyFor(square(), dx: frame * 0.0137));
      }
      expect(tracker.length, 8);
    });
  });

  group('the selector branch it feeds', () {
    const selector = GpuPathStrategySelector();
    const everything = GpuPathStrategyCapabilities(
      sparseStrips: true,
      tessellation: true,
      stencil: true,
      compute: true,
    );

    GpuPathWorkload workload({required bool cacheable}) => GpuPathWorkload(
          pixelWidth: 256,
          pixelHeight: 256,
          segmentCount: 8,
          geometryStable: true,
          denseMaskLikelyCacheable: cacheable,
          sparseUploadBytes: 1024,
          sparseInstanceBytes: 1024,
          sparseEstimatedDrawCalls: 2,
          sparseAtlasPageCount: 1,
        );

    test('a repeated draw goes to the atlas whatever else is available', () {
      // Ahead of *every* experimental route, not priced against each: the
      // route that wins a repeat is the route that keeps the atlas empty.
      final decision = selector.select(workload(cacheable: true), everything);
      expect(decision.strategy, GpuPathStrategy.coverageAtlas);
      expect(decision.reason, contains('repeated'));
    });

    test('a fresh draw is still costed normally', () {
      // The fix must not just disable the experimental routes.
      final decision = selector.select(workload(cacheable: false), everything);
      expect(decision.strategy, GpuPathStrategy.sparseStrips);
    });

    test('a gradient repeat is not sent to an atlas that cannot draw it', () {
      // Gradients report `coverageAtlas: false`, so the branch must not fire -
      // the atlas is not a cheaper route for them, it is no route at all.
      final decision = selector.select(
        workload(cacheable: true),
        const GpuPathStrategyCapabilities(
          analyticPrimitives: false,
          coverageAtlas: false,
          sparseStrips: true,
        ),
      );
      expect(decision.strategy, GpuPathStrategy.sparseStrips);
    });
  });
}
