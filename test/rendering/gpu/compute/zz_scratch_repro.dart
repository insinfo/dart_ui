import 'package:dart_ui/src/backends/win32/d3d12/d3d12_compute_segment_driver.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/rendering/gpu/compute/d3d12_compute_segment_executor.dart';
import 'package:dart_ui/src/rendering/gpu/vector/compute_tile_scene.dart';
import 'package:dart_ui/src/rendering/path/fill_rule.dart';
import 'package:test/test.dart';

import '../../../backends/win32/d3d12/d3d12_session.dart';

ComputeTilePlan build(int draws, int size, int tileSize) {
  final ComputeTileScene scene = ComputeTileScene();
  final Rect clip = Rect.fromLTRB(0, 0, size.toDouble(), size.toDouble());
  for (var i = 0; i < draws; i++) {
    final double span = size / 6.0;
    final int free = size - span.ceil() - 2;
    final double x = (i * 37 % free).toDouble() + 1;
    final double y = (i * 53 % free).toDouble() + 1;
    scene.appendPath(
      (PathBuilder()
            ..addRoundedRect(
                Rect.fromLTWH(x, y, span, span * 0.75), span / 6, span / 8))
          .build(),
      clip: clip,
      materialIndex: i,
      fillRule: FillRule.nonZero,
    );
  }
  return scene.build(width: size, height: size, tileSize: tileSize);
}

void main() {
  final D3d12Session session = D3d12Session.open();
  test('unchained 256 draws 1024', () {
    if (session.device == null) {
      markTestSkipped('no device');
      return;
    }
    final D3d12ComputeSegmentDriver driver =
        D3d12ComputeSegmentDriver(session.device!);
    final ComputeSegmentBinningExecutor executor =
        ComputeSegmentBinningExecutor(driver)..initialize();
    for (final (int draws, int size) in <(int, int)>[
      (8, 256),
      (64, 512),
      (256, 1024),
    ]) {
      final ComputeTilePlan plan = build(draws, size, 16);
      // ignore: avoid_print
      print('$draws/$size refs=${plan.references.length} '
          'tileSegs=${plan.tileSegments.length} segs=${plan.segmentCount}');
      final ComputeSegmentBinningResult r = executor.binSegments(
        scene: ComputeSegmentScene(
          segments: plan.segments,
          draws: plan.draws,
          bounds: plan.bounds,
        ),
        bins: plan.bins,
        references: plan.references,
        grid: ComputeSegmentBinningGrid(
          width: plan.width,
          height: plan.height,
          tileSize: plan.tileSize,
        ),
      );
      expect(r.referenceSegments, plan.referenceSegments);
      expect(r.tileSegments, plan.tileSegments);
      expect(r.backdrops, plan.referenceBackdrops);
      // ignore: avoid_print
      print('  ok, passes=${r.passes} budget=${r.tileSegmentBudget}');
    }
    executor.dispose();
    driver.dispose();
  });
  tearDownAll(session.close);
}
