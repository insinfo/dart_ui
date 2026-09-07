/// The join between the flatten stage and the segment stage.
///
/// `RELATORIO_POC_23_GPU_2D_STRATEGIES_INTEL_UHD.md` named this as the first of
/// two gaps left in approach D, and named the failure mode precisely: the
/// flatten stage was a dead end *inside its own chain*, because the segment
/// stage was handed a `ComputeTilePlan`'s segments and its
/// `firstSegment`/`segmentCount` table from the CPU while the segments the
/// device had just produced went unread. Wiring one to the other naively would
/// bind a segment numbering to an index built for a different one - **wrong
/// edges, not a failure**. Nothing throws; a picture comes out.
///
/// So this file compares pixels, and nothing else would do.
///
/// ## What is compared, and why the oracle is the CPU-planned route
///
/// `ComputeTileD3d12Executor.submit(plan)` is the coverage route
/// `d3d12_compute_tile_parity_test.dart` proved against
/// `ComputeTileCpuReference`, over a plan `ComputeTileScene.build` produced on
/// the CPU. The joined route shares no array with it: its segments come from
/// `csEmitSegments`, its per-draw ranges from `csDrawTable`, its tile index and
/// backdrops from the two stages between them. Only the geometry is common. So
/// an agreement here is an agreement between two independent flatteners, two
/// independent binners and two independent segment tables, and a disagreement
/// is attributable to exactly the join.
///
/// ## Why the tolerance is not zero everywhere, and where it is
///
/// The two flatteners subdivide the same curve into the same *number* of
/// segments - `compute_curve_scene.dart` fixes that formula for both - but they
/// place the interior points differently on purpose: `Path.flattenTo` walks a
/// curve by forward differences in float64 and the GPU evaluates `B(j / n)`
/// directly in float32, which `compute_flatten_reference_test.dart` measures as
/// the *more* accurate of the two. On a scene of straight edges there is no
/// interior point and the two polylines are identical, so the bar is byte for
/// byte with no tolerance. On a scene with curves the polylines genuinely
/// differ, by less than the flattening tolerance the whole stage is built
/// around, and the honest bound is the one a subsample flip costs. Each scene
/// below states which it is and why, and the test prints what was actually
/// observed rather than leaving the bound to stand in for a measurement.
///
/// ## The degenerate contour is a scene here, not a footnote
///
/// It is where the two halves disagreed by construction: `ComputeTileScene`'s
/// sink drops a zero-length edge and then skips the closing edge of a contour
/// that produced none, while `ComputeCurveScene` decides the closing edge per
/// contour before any flattening has happened and keeps the degenerate records.
/// The two therefore assign a draw a *different number of segments* for the
/// same path - which is the numbering the naive wiring would have crossed - and
/// the claim that it changes no pixel is the claim this scene checks.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/backends/win32/d3d12/d3d12_compute_raster_driver.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/rendering/gpu/compute/compute_curve_scene.dart';
import 'package:dart_ui/src/rendering/gpu/compute/compute_flatten_reference.dart';
import 'package:dart_ui/src/rendering/gpu/compute/compute_raster_pipeline.dart';
import 'package:dart_ui/src/rendering/gpu/compute/d3d12_compute_binning_executor.dart';
import 'package:dart_ui/src/rendering/gpu/compute/d3d12_compute_coverage_executor.dart';
import 'package:dart_ui/src/rendering/gpu/compute/d3d12_compute_segment_executor.dart';
import 'package:dart_ui/src/rendering/gpu/d3d12/d3d12_compute_tile_executor.dart';
import 'package:dart_ui/src/rendering/gpu/vector/compute_tile_scene.dart';
import 'package:dart_ui/src/rendering/path/fill_rule.dart';
import 'package:test/test.dart';

import '../../../backends/win32/d3d12/d3d12_session.dart';

const int _width = 64;
const int _height = 64;
const int _tileSize = 16;
const Rect _clip = Rect.fromLTRB(0, 0, 64, 64);

/// One flipped subsample of sixteen, at the default grid.
///
/// The unit a coverage byte moves by when two evaluations of the same crossing
/// land on opposite sides of one subpixel centre.
const int _oneSubsample = 16;

void main() {
  final D3d12Session session = D3d12Session.open(computeTiles: true);
  D3d12ComputeRasterDriver? driver;
  ComputeRasterPipeline? pipeline;

  tearDownAll(() {
    pipeline?.dispose();
    driver?.dispose();
    session.close();
  });

  ComputeRasterPipeline open() {
    if (pipeline != null) return pipeline!;
    final D3d12ComputeRasterDriver made =
        D3d12ComputeRasterDriver(session.device!);
    driver = made;
    return pipeline = ComputeRasterPipeline(made)..initialize();
  }

  group('the draw table is the flatten stage own scan', () {
    test('csDrawTable agrees with the CPU oracle, entry by entry', () {
      if (_skipped(session)) return;
      // The table is four uints per draw and three of them are copied through,
      // so the one that can be wrong is the pair that comes out of the scan.
      // Compared against `ComputeFlattenReference`, which is the oracle the
      // flatten stage is already proved against.
      for (final _Scene scene in _scenes()) {
        final ComputeCurveUpload curves = scene.curves();
        final ComputeRasterResult ran = _joined(open(), scene, curves);
        final Uint32List? table = ran.flatten!.drawTable;
        expect(table, isNotNull,
            reason: 'the joined shape reads the draw table back');
        final ComputeFlattenReference reference =
            ComputeFlattenReference(curves);
        for (var draw = 0; draw < curves.pathCount; draw++) {
          final int first = curves.paths[draw * kComputeCurvePathStride];
          final int count = curves.paths[draw * kComputeCurvePathStride + 1];
          expect(table![draw * 4 + 0], reference.offsets[first],
              reason: '${scene.name}: draw $draw first segment');
          expect(table[draw * 4 + 1],
              reference.offsets[first + count] - reference.offsets[first],
              reason: '${scene.name}: draw $draw segment count');
          expect(table[draw * 4 + 2], draw,
              reason: '${scene.name}: draw $draw material');
          expect(table[draw * 4 + 3], scene.rule.index,
              reason: '${scene.name}: draw $draw fill rule');
        }
      }
    });
  });

  group('the joined route draws what the proven route draws', () {
    for (final _Scene scene in _scenes()) {
      test('${scene.name}: within ${scene.tolerance}', () {
        if (_skipped(session)) return;
        final ComputeTilePlan plan = scene.plan();
        expect(plan.drawCount, scene.paths.length,
            reason: 'the CPU planner kept every draw, so the two routes index '
                'the same draws');

        final ComputeCurveUpload curves = scene.curves();
        final ComputeCoverageResult joined =
            _joined(open(), scene, curves).coverage!;
        final ComputeTileCoverage proven =
            session.device!.submitComputeTiles(plan);

        var worst = 0;
        for (var draw = 0; draw < plan.drawCount; draw++) {
          final Uint8List got = joined.rasterizedDraw(draw);
          final Uint8List want = proven.rasterizedDraw(draw);
          expect(got.length, want.length);
          for (var i = 0; i < got.length; i++) {
            final int delta = (got[i] - want[i]).abs();
            if (delta > worst) worst = delta;
          }
        }
        printOnFailure('${scene.name}: worst deviation $worst');
        expect(worst, lessThanOrEqualTo(scene.tolerance), reason: scene.why);
        // ignore: avoid_print
        print('| ${scene.name} | ${scene.tolerance} | $worst |');
      });
    }
  });

  group('the join is what makes it right, and here is the proof', () {
    test('a plan segment table read through the flatten numbering is wrong',
        () {
      if (_skipped(session)) return;
      // The failure the report names, staged deliberately: the *plan's*
      // segments with a draw table built from the *flatten* stage's offsets.
      // Both tables are well formed, nothing refuses, and the run just resolves
      // each draw to a segment range that belongs to a different flattener.
      //
      // Two draws, because one is not enough to show it. With a single draw the
      // crossed range runs off the end of the plan's segment array, and a root
      // descriptor past its buffer reads zeros - a `float4(0,0,0,0)` is a
      // horizontal edge, and a horizontal edge crosses nothing. The second
      // draw is what puts *real* edges in the range the first one now claims,
      // which is the actual shape of the bug: not garbage, another draw's
      // geometry.
      final _Scene scene = _crossable();
      final ComputeTilePlan plan = scene.plan();
      final ComputeFlattenReference reference =
          ComputeFlattenReference(scene.curves());
      final Uint32List crossed =
          Uint32List(plan.drawCount * kComputeTileDrawStride);
      for (var draw = 0; draw < plan.drawCount; draw++) {
        final int first = scene.curves().paths[draw * kComputeCurvePathStride];
        final int count =
            scene.curves().paths[draw * kComputeCurvePathStride + 1];
        crossed[draw * kComputeTileDrawStride + 0] = reference.offsets[first];
        crossed[draw * kComputeTileDrawStride + 1] =
            reference.offsets[first + count] - reference.offsets[first];
        crossed[draw * kComputeTileDrawStride + 2] = draw;
        crossed[draw * kComputeTileDrawStride + 3] = scene.rule.index;
      }
      expect(crossed, isNot(plan.draws),
          reason:
              'if the two numberings agreed there would be no gap to close');

      final ComputeCoverageResult sabotaged = _seeded(
        open(),
        scene,
        ComputeSegmentScene(
          segments: plan.segments,
          draws: crossed,
          bounds: plan.bounds,
        ),
        plan,
      );
      final ComputeTileCoverage proven =
          session.device!.submitComputeTiles(plan);
      var worst = 0;
      var moved = 0;
      for (var draw = 0; draw < plan.drawCount; draw++) {
        final Uint8List got = sabotaged.rasterizedDraw(draw);
        final Uint8List want = proven.rasterizedDraw(draw);
        for (var i = 0; i < got.length; i++) {
          final int delta = (got[i] - want[i]).abs();
          if (delta != 0) moved++;
          if (delta > worst) worst = delta;
        }
      }
      // ignore: avoid_print
      print('crossed numbering: $moved pixels moved, worst $worst of 255');
      expect(worst, greaterThan(_oneSubsample),
          reason: 'a crossed numbering has to be visible, or this test proves '
              'nothing about the join it is guarding');
    });

    test('dropping the closing edge of a contour is visible', () {
      if (_skipped(session)) return;
      // The other half of the specification. `compute_curve_scene.dart` decides
      // the closing edge per contour before anything is flattened; this deletes
      // the record that decision emits - the last curve of each path, which for
      // these scenes is exactly the closing line - and rasterises the result
      // through the same joined route.
      //
      // A filled shape whose outline does not close leaks winding along the
      // missing edge, so this must be a large difference. If it ever came back
      // small, the parity above would be passing for a reason other than the
      // rule being obeyed.
      // Not `_triangle()`: its closing edge is horizontal, and a horizontal
      // edge is neither upward nor downward for any sample, so deleting it
      // changes nothing and the sabotage would prove nothing. This one closes
      // on a slanted edge.
      final _Scene scene = _Scene(
        'a scalene triangle',
        <Path>[_scalene()],
        tolerance: 0,
        why: 'unused',
      );
      final ComputeCurveUpload whole = scene.curves();
      final ComputeCurveUpload open_ = _withoutLastCurveOfEachPath(whole);
      expect(open_.curveCount, whole.curveCount - 1);

      final ComputeCoverageResult closed =
          _joined(open(), scene, whole).coverage!;
      final ComputeCoverageResult opened =
          _joined(open(), scene, open_).coverage!;
      var moved = 0;
      var worst = 0;
      final Uint8List a = closed.rasterizedDraw(0);
      final Uint8List b = opened.rasterizedDraw(0);
      for (var i = 0; i < a.length; i++) {
        final int delta = (a[i] - b[i]).abs();
        if (delta != 0) moved++;
        if (delta > worst) worst = delta;
      }
      // ignore: avoid_print
      print('closing edge dropped: $moved pixels moved, worst $worst of 255');
      expect(worst, 255,
          reason: 'an unclosed outline leaks winding; the difference is whole '
              'pixels and not a rounding');
    });
  });

  group('the joined shape is deterministic and leaves nothing behind', () {
    test('the same scene twice produces the same buffer', () {
      if (_skipped(session)) return;
      // The stages in front of coverage place their references with atomics and
      // rank-sort the runs, so the intermediate buffers genuinely differ
      // between runs while the sorted output does not. The join adds one more
      // consumer of that ordering.
      final _Scene scene = _scenes().first;
      final ComputeCurveUpload curves = scene.curves();
      final ComputeCoverageResult first =
          _joined(open(), scene, curves).coverage!;
      final ComputeCoverageResult second =
          _joined(open(), scene, curves).coverage!;
      expect(second.values, first.values);
    });

    test('a smaller scene after a larger one leaves no ink behind', () {
      if (_skipped(session)) return;
      // The coverage buffer is grown and reused and only the pixels a tile
      // references are written, so without the per-run zero-fill a large scene
      // stays lit under a small one - which reads as a shape that grew.
      final ComputeRasterPipeline built = open();
      final _Scene wide = _Scene('wide', <Path>[_rect(2, 2, 62, 62)],
          tolerance: 0, why: 'unused');
      _joined(built, wide, wide.curves());
      final _Scene narrow = _Scene('narrow', <Path>[_rect(20, 20, 28, 28)],
          tolerance: 0, why: 'unused');
      final ComputeCoverageResult after =
          _joined(built, narrow, narrow.curves()).coverage!;
      final ComputeTileCoverage fresh =
          session.device!.submitComputeTiles(narrow.plan());
      expect(after.rasterizedDraw(0), fresh.rasterizedDraw(0));
    });
  });

  group('the joined shape refuses what it cannot know', () {
    test('a widest-draw bound that is too small is grown, not obeyed', () {
      if (_skipped(session)) return;
      // The segment kernel's guard is `local >= segmentCount`, so a ragged
      // dispatch narrower than the widest draw drops that draw's tail segments
      // and says nothing. The pipeline recomputes the widest draw from the scan
      // it read back and resubmits; this asserts that it did, and that what
      // came out is still right.
      final _Scene scene = _Scene('an ellipse', <Path>[_ellipse()],
          tolerance: _oneSubsample, why: 'unused');
      final ComputeCurveUpload curves = scene.curves();
      final ComputeRasterResult ran = open().run(
        scene: curves,
        bounds: scene.bounds(),
        drawCount: curves.pathCount,
        grid: _grid,
        junction: ComputeFlattenJunction(drawCount: curves.pathCount),
        coverage: const ComputeCoverageRequest(),
        budget: const ComputeRasterBudget(
          segments: 4096,
          references: 4096,
          tileSegments: 4096,
          drawSegments: 1,
        ),
      );
      expect(ran.submissions, greaterThan(1),
          reason: 'a bound of one segment cannot cover an ellipse');
      expect(ran.budget.drawSegments, greaterThan(1));
      final ComputeTileCoverage proven =
          session.device!.submitComputeTiles(scene.plan());
      var worst = 0;
      final Uint8List got = ran.coverage!.rasterizedDraw(0);
      final Uint8List want = proven.rasterizedDraw(0);
      for (var i = 0; i < got.length; i++) {
        final int delta = (got[i] - want[i]).abs();
        if (delta > worst) worst = delta;
      }
      expect(worst, lessThanOrEqualTo(_oneSubsample));
    });

    test('a joined submission that reads nothing back still records', () {
      if (_skipped(session)) return;
      // The shape a frame path would use: four stages, one list, no fence and
      // no readback. There is nothing to compare, which is the point - what is
      // asserted is that the joined wiring records and submits, and that the
      // budget it demands is the one `run` handed back.
      final _Scene scene = _scenes().first;
      final ComputeCurveUpload curves = scene.curves();
      final ComputeRasterPipeline built = open();
      final ComputeRasterBudget learned = _joined(built, scene, curves).budget;
      expect(learned.drawSegments, greaterThan(0));
      final int before = built.submissions;
      final int waited = built.waits;
      built.submit(
        scene: curves,
        bounds: scene.bounds(),
        drawCount: curves.pathCount,
        grid: _grid,
        junction: ComputeFlattenJunction(drawCount: curves.pathCount),
        coverage: const ComputeCoverageRequest(),
        budget: learned,
      );
      expect(built.submissions, before + 1);
      expect(built.waits, waited, reason: 'submit does not wait');
      expect(built.finish(), isTrue);
    });

    test('a joined submission with no widest-draw bound is refused', () {
      if (_skipped(session)) return;
      // The fallback `run` uses - the segment budget - is safe but silently
      // over-dispatches, and a submission that reads nothing back cannot find
      // out either way. So it is named rather than guessed.
      final _Scene scene = _scenes().first;
      final ComputeCurveUpload curves = scene.curves();
      expect(
        () => open().submit(
          scene: curves,
          bounds: scene.bounds(),
          drawCount: curves.pathCount,
          grid: _grid,
          junction: ComputeFlattenJunction(drawCount: curves.pathCount),
          budget: const ComputeRasterBudget(
            segments: 4096,
            references: 4096,
            tileSegments: 4096,
          ),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a plan and a junction together are refused by name', () {
      if (_skipped(session)) return;
      final _Scene scene = _scenes().first;
      final ComputeCurveUpload curves = scene.curves();
      final ComputeTilePlan plan = scene.plan();
      expect(
        () => open().run(
          scene: curves,
          bounds: scene.bounds(),
          drawCount: curves.pathCount,
          grid: _grid,
          segmentScene: ComputeSegmentScene(
            segments: plan.segments,
            draws: plan.draws,
            bounds: plan.bounds,
          ),
          junction: ComputeFlattenJunction(drawCount: curves.pathCount),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a junction whose draw count is not the scene is refused', () {
      if (_skipped(session)) return;
      final _Scene scene = _scenes().first;
      final ComputeCurveUpload curves = scene.curves();
      expect(
        () => open().run(
          scene: curves,
          bounds: scene.bounds(),
          drawCount: curves.pathCount,
          grid: _grid,
          junction: ComputeFlattenJunction(drawCount: curves.pathCount + 1),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('what the join costs, measured against the route it replaces', () {
    test('the same scenes, both routes, five runs each', () {
      if (_skipped(session)) return;
      // The trap this report has fallen into before, stated in its own words:
      // a ratio is only a ratio when both columns do the same work. Here they
      // do on the GPU side - four stages, one submission, one readback of one
      // `uint` per pixel per draw, which at 512x512 with 64 draws is 64 MiB and
      // dominates everything else in both columns alike. **So neither column's
      // absolute number is the cost of a stage, and the difference between them
      // is not attributable to chaining: both are chained.**
      //
      // What differs is the CPU side, and that is the measurement. The seeded
      // column needs a `ComputeTilePlan`, which is `ComputeTileScene.build`
      // doing the flatten, the bounds, the dedup and the encode; the joined
      // column needs none of it and pays one extra kernel instead. The `plan`
      // column is that CPU work, timed on its own, so the honest comparison is
      // `plan + seeded` against `joined`.
      //
      // Five runs and the median, because a single `Stopwatch` reading over one
      // submission on this adapter swung by more than two to one between runs
      // of this same file.
      const int runs = 5;
      final ComputeRasterPipeline built = open();
      final StringBuffer table = StringBuffer()
        ..writeln()
        ..writeln('| scene | draws | plan (CPU) | seeded | plan + seeded | '
            'joined |')
        ..writeln('|---|---:|---:|---:|---:|---:|');
      for (final _Bench bench in _benchmarks()) {
        final ComputeCurveScene curveScene = ComputeCurveScene();
        for (var i = 0; i < bench.paths.length; i++) {
          curveScene.appendPath(bench.paths[i], materialIndex: i);
        }
        final ComputeCurveUpload curves = curveScene.upload();
        final Float32List bounds =
            curveScene.deviceBounds(width: bench.size, height: bench.size);
        final ComputeBinningGrid grid = ComputeBinningGrid(
          width: bench.size,
          height: bench.size,
          tileSize: bench.tileSize,
        );

        final ComputeTilePlan plan = bench.plan();
        final ComputeSegmentScene seededScene = ComputeSegmentScene(
          segments: plan.segments,
          draws: plan.draws,
          bounds: plan.bounds,
        );
        // Learn the budgets first, so neither column is timed growing a buffer.
        // That is also the shape a frame path has: last frame's totals carried
        // forward.
        final ComputeRasterBudget seededBudget = built
            .run(
              scene: curves,
              bounds: plan.bounds,
              drawCount: plan.drawCount,
              grid: grid,
              segmentScene: seededScene,
              coverage: const ComputeCoverageRequest(),
            )
            .budget;
        final ComputeRasterBudget joinedBudget = built
            .run(
              scene: curves,
              bounds: bounds,
              drawCount: curves.pathCount,
              grid: grid,
              junction: ComputeFlattenJunction(drawCount: curves.pathCount),
              coverage: const ComputeCoverageRequest(),
            )
            .budget;

        final List<int> planning = <int>[];
        final List<int> seeded = <int>[];
        final List<int> joined = <int>[];
        for (var run = 0; run < runs; run++) {
          final Stopwatch clock = Stopwatch()..start();
          bench.plan();
          clock.stop();
          planning.add(clock.elapsedMicroseconds);

          clock
            ..reset()
            ..start();
          built.run(
            scene: curves,
            bounds: plan.bounds,
            drawCount: plan.drawCount,
            grid: grid,
            segmentScene: seededScene,
            coverage: const ComputeCoverageRequest(),
            budget: seededBudget,
          );
          clock.stop();
          seeded.add(clock.elapsedMicroseconds);

          clock
            ..reset()
            ..start();
          built.run(
            scene: curves,
            bounds: bounds,
            drawCount: curves.pathCount,
            grid: grid,
            junction: ComputeFlattenJunction(drawCount: curves.pathCount),
            coverage: const ComputeCoverageRequest(),
            budget: joinedBudget,
          );
          clock.stop();
          joined.add(clock.elapsedMicroseconds);
        }
        final int planMedian = _median(planning);
        final int seededMedian = _median(seeded);
        table.writeln('| ${bench.name} | ${bench.draws} | $planMedian us | '
            '$seededMedian us | ${planMedian + seededMedian} us | '
            '${_median(joined)} us |');
      }
      // ignore: avoid_print
      print(table);
    });
  });
}

final ComputeBinningGrid _grid =
    ComputeBinningGrid(width: _width, height: _height, tileSize: _tileSize);

/// Runs the joined four-stage chain and returns everything it read back.
///
/// Two calls: the first learns the budgets and the second runs with them, so
/// what is compared is a submission that did not have to grow anything - which
/// is also the shape a frame path has.
ComputeRasterResult _joined(
  ComputeRasterPipeline pipeline,
  _Scene scene,
  ComputeCurveUpload curves,
) {
  final ComputeRasterResult learned = pipeline.run(
    scene: curves,
    bounds: scene.boundsOf(curves),
    drawCount: curves.pathCount,
    grid: _grid,
    junction: ComputeFlattenJunction(drawCount: curves.pathCount),
    coverage: const ComputeCoverageRequest(),
  );
  final ComputeRasterResult ran = pipeline.run(
    scene: curves,
    bounds: scene.boundsOf(curves),
    drawCount: curves.pathCount,
    grid: _grid,
    junction: ComputeFlattenJunction(drawCount: curves.pathCount),
    coverage: const ComputeCoverageRequest(),
    budget: learned.budget,
  );
  expect(ran.submissions, 1,
      reason: 'four stages in one command list, once the budgets are known');
  expect(ran.coverage, isNotNull);
  return ran;
}

/// The same chain in the seeded shape, for the sabotage that needs a hand-built
/// segment table.
ComputeCoverageResult _seeded(
  ComputeRasterPipeline pipeline,
  _Scene scene,
  ComputeSegmentScene segmentScene,
  ComputeTilePlan plan,
) {
  final ComputeCurveUpload curves = scene.curves();
  final ComputeRasterResult learned = pipeline.run(
    scene: curves,
    bounds: plan.bounds,
    drawCount: plan.drawCount,
    grid: _grid,
    segmentScene: segmentScene,
    coverage: const ComputeCoverageRequest(),
  );
  return pipeline
      .run(
        scene: curves,
        bounds: plan.bounds,
        drawCount: plan.drawCount,
        grid: _grid,
        segmentScene: segmentScene,
        coverage: const ComputeCoverageRequest(),
        budget: learned.budget,
      )
      .coverage!;
}

/// The scene with the last curve of every path deleted.
///
/// For a contour written `moveTo, lineTo, lineTo, close` that record is the
/// closing line `ComputeCurveScene` emitted, so this is the encoded scene the
/// other closing-edge rule would have produced if it had decided "never".
ComputeCurveUpload _withoutLastCurveOfEachPath(ComputeCurveUpload scene) {
  final List<int> curves = <int>[];
  final List<double> points = <double>[];
  final List<int> paths = <int>[];
  for (var path = 0; path < scene.pathCount; path++) {
    final int first = scene.paths[path * kComputeCurvePathStride];
    final int count = scene.paths[path * kComputeCurvePathStride + 1];
    final int kept = count - 1;
    paths
      ..add(curves.length ~/ kComputeCurveHeaderStride)
      ..add(kept)
      ..add(scene.paths[path * kComputeCurvePathStride + 2])
      ..add(scene.paths[path * kComputeCurvePathStride + 3]);
    for (var curve = first; curve < first + kept; curve++) {
      for (var i = 0; i < kComputeCurveHeaderStride; i++) {
        curves.add(scene.curves[curve * kComputeCurveHeaderStride + i]);
      }
      for (var i = 0; i < kComputeCurvePointStride; i++) {
        points.add(scene.curvePoints[curve * kComputeCurvePointStride + i]);
      }
    }
  }
  return ComputeCurveUpload(
    curves: Uint32List.fromList(curves),
    curvePoints: Float32List.fromList(points),
    transforms: scene.transforms,
    paths: Uint32List.fromList(paths),
    curveCount: curves.length ~/ kComputeCurveHeaderStride,
    pathCount: paths.length ~/ kComputeCurvePathStride,
  );
}

final class _Scene {
  _Scene(
    this.name,
    this.paths, {
    required this.tolerance,
    required this.why,
    this.rule = FillRule.nonZero,
  });

  final String name;
  final List<Path> paths;

  /// The bound against the CPU-planned route.
  final int tolerance;

  /// Why that number and not another.
  final String why;

  final FillRule rule;

  ComputeCurveUpload? _curves;

  ComputeCurveUpload curves() {
    final ComputeCurveUpload? cached = _curves;
    if (cached != null) return cached;
    final ComputeCurveScene scene = ComputeCurveScene();
    for (var i = 0; i < paths.length; i++) {
      scene.appendPath(paths[i], materialIndex: i, fillRule: rule);
    }
    _bounds = scene.deviceBounds(width: _width, height: _height);
    return _curves = scene.upload();
  }

  Float32List? _bounds;

  Float32List bounds() {
    curves();
    return _bounds!;
  }

  Float32List boundsOf(ComputeCurveUpload upload) =>
      identical(upload, _curves) ? bounds() : _boundsFor(upload);

  ComputeTilePlan plan() {
    final ComputeTileScene scene = ComputeTileScene();
    for (var i = 0; i < paths.length; i++) {
      scene.appendPath(paths[i], clip: _clip, materialIndex: i, fillRule: rule);
    }
    return scene.build(width: _width, height: _height, tileSize: _tileSize);
  }
}

/// The device box of a hand-built upload, for the perturbed scenes that did not
/// come out of a [ComputeCurveScene].
Float32List _boundsFor(ComputeCurveUpload scene) {
  final Float32List result = Float32List(scene.pathCount * 4);
  for (var path = 0; path < scene.pathCount; path++) {
    final int first = scene.paths[path * kComputeCurvePathStride];
    final int count = scene.paths[path * kComputeCurvePathStride + 1];
    var left = double.infinity;
    var top = double.infinity;
    var right = double.negativeInfinity;
    var bottom = double.negativeInfinity;
    for (var curve = first; curve < first + count; curve++) {
      for (var corner = 0; corner < 4; corner++) {
        final double x =
            scene.curvePoints[curve * kComputeCurvePointStride + corner * 2];
        final double y = scene
            .curvePoints[curve * kComputeCurvePointStride + corner * 2 + 1];
        if (x < left) left = x;
        if (x > right) right = x;
        if (y < top) top = y;
        if (y > bottom) bottom = y;
      }
    }
    if (left < 0) left = 0;
    if (top < 0) top = 0;
    if (right > _width) right = _width.toDouble();
    if (bottom > _height) bottom = _height.toDouble();
    if (!(right > left) || !(bottom > top)) continue;
    result[path * 4 + 0] = left;
    result[path * 4 + 1] = top;
    result[path * 4 + 2] = right;
    result[path * 4 + 3] = bottom;
  }
  return result;
}

/// The six scenes the report's parity claim is stated over, plus the one it
/// named as the place the two halves disagreed.
List<_Scene> _scenes() => <_Scene>[
      _Scene(
        'one rectangle',
        <Path>[_rect(8, 8, 40, 40)],
        tolerance: 0,
        why: 'four axis-aligned lines: the two flatteners emit the same four '
            'segments, so there is nothing left to round',
      ),
      _Scene(
        'a draw in one tile of sixteen',
        <Path>[_rect(18, 18, 28, 28)],
        tolerance: 0,
        why: 'the same, over a grid where fifteen tiles are empty',
      ),
      _Scene(
        'two draws sharing tiles',
        <Path>[_rect(4, 4, 36, 36), _rect(20, 20, 60, 60)],
        tolerance: 0,
        why: 'two draws means the draw table is indexed rather than assumed, '
            'and both draws are straight-edged',
      ),
      _Scene(
        'a triangle',
        <Path>[_triangle()],
        tolerance: 0,
        why: 'slanted but still straight: no curve, no interior sample, so the '
            'two polylines are the same points',
      ),
      _Scene(
        'an ellipse',
        <Path>[_ellipse()],
        tolerance: _oneSubsample,
        why: 'the first scene with real curves. The two flatteners agree on '
            'the segment count and place the interior points differently - '
            'forward differences in float64 against direct evaluation in '
            'float32 - so a crossing can land on the other side of a subsample',
      ),
      _degenerate(),
      _Scene(
        'an even-odd bowtie',
        <Path>[_bowtie()],
        tolerance: 0,
        why: 'even-odd, so the fill rule the draw table carries is read; still '
            'straight-edged, so the bar stays exact',
        rule: FillRule.evenOdd,
      ),
    ];

/// The degenerate square, plus a second draw whose edges the crossed numbering
/// can reach.
///
/// The two draws have to differ, or `ComputeTileScene` deduplicates their
/// encodings and both point at one segment run - which is the case the crossed
/// numbering cannot show. The second draw is a *triangle* and not a box: every
/// edge of an axis-aligned box is either horizontal, and so crossed by no
/// sample at all, or one of a pair that cancels, so borrowing one of them
/// changes nothing. Every edge of this triangle is slanted, and it sits inside
/// the first draw's box, so an edge the first draw wrongly claims really does
/// change its winding.
_Scene _crossable() => _Scene(
      'a degenerate square and a wedge',
      <Path>[
        _degenerate().paths.single,
        (PathBuilder()
              ..moveTo(48, 14)
              ..lineTo(60, 22)
              ..lineTo(48, 38)
              ..close())
            .build(),
      ],
      tolerance: 0,
      why: 'unused',
    );

/// A square with three degenerate contours attached.
///
/// Each of the three is one of the cases `compute_curve_scene.dart` answers: a
/// contour of two coincident points, a contour of one point, and a contour that
/// returns to its start. The CPU sink drops all of them and skips their closing
/// edges; the curve encoder keeps the records and decides the closing edge
/// before it knows they are degenerate. So the two halves give this draw a
/// different segment count for the same path - and the same picture, which is
/// what the bar of zero says.
_Scene _degenerate() => _Scene(
      'a square with degenerate contours',
      <Path>[
        (PathBuilder()
              ..moveTo(10, 10)
              ..lineTo(44, 10)
              ..lineTo(44, 44)
              ..lineTo(10, 44)
              ..close()
              ..moveTo(50, 50)
              ..lineTo(50, 50)
              ..close()
              ..moveTo(20, 52)
              ..close()
              ..moveTo(52, 20)
              ..lineTo(58, 20)
              ..lineTo(52, 20)
              ..close())
            .build(),
      ],
      tolerance: 0,
      why: 'the extra edges the curve encoder keeps are zero length in device '
          'space, and a zero-length edge is neither upward nor downward for '
          'any sample, so it changes no winding',
    );

Path _rect(double left, double top, double right, double bottom) =>
    (PathBuilder()..addRect(Rect.fromLTRB(left, top, right, bottom))).build();

/// A triangle whose closing edge is slanted, so deleting it is visible.
Path _scalene() => (PathBuilder()
      ..moveTo(10, 54)
      ..lineTo(32, 6)
      ..lineTo(54, 40)
      ..close())
    .build();

Path _triangle() => (PathBuilder()
      ..moveTo(10, 54)
      ..lineTo(32, 6)
      ..lineTo(54, 54)
      ..close())
    .build();

Path _ellipse() =>
    (PathBuilder()..addOval(const Rect.fromLTRB(3, 20, 61, 44))).build();

Path _bowtie() => (PathBuilder()
      ..moveTo(8, 8)
      ..lineTo(56, 56)
      ..lineTo(8, 56)
      ..lineTo(56, 8)
      ..close())
    .build();

int _median(List<int> values) {
  final List<int> sorted = List<int>.of(values)..sort();
  return sorted[sorted.length ~/ 2];
}

bool _skipped(D3d12Session session) {
  if (session.device != null) return false;
  markTestSkipped(session.skipReason ?? 'no Direct3D 12 device');
  return true;
}

/// The benchmark's scenes, which are not the parity scenes.
///
/// Larger, for the reason `d3d12_compute_coverage_parity_test.dart` states, and
/// capped by the same thing: one `uint` per pixel per draw.
final class _Bench {
  _Bench(this.name, this.draws, this.size, this.tileSize);

  final String name;
  final int draws;
  final int size;
  final int tileSize;

  late final List<Path> paths = <Path>[
    for (var i = 0; i < draws; i++) _panel(i),
  ];

  ComputeTilePlan plan() {
    final ComputeTileScene scene = ComputeTileScene();
    final Rect clip = Rect.fromLTRB(0, 0, size.toDouble(), size.toDouble());
    for (var i = 0; i < draws; i++) {
      scene.appendPath(paths[i],
          clip: clip, materialIndex: i, fillRule: FillRule.nonZero);
    }
    return scene.build(width: size, height: size, tileSize: tileSize);
  }

  /// A rounded panel, so the flatten stage has real curves - the same shape the
  /// coverage parity test benchmarks, so the two files measure one geometry.
  Path _panel(int i) {
    final double span = size / 6.0;
    final int free = size - span.ceil() - 2;
    final double x = (i * 37 % free).toDouble() + 1;
    final double y = (i * 53 % free).toDouble() + 1;
    return (PathBuilder()
          ..addRoundedRect(
            Rect.fromLTWH(x, y, span, span * 0.75),
            span / 6,
            span / 8,
          ))
        .build();
  }
}

List<_Bench> _benchmarks() => <_Bench>[
      _Bench('4 draws, 128x128', 4, 128, 16),
      _Bench('16 draws, 256x256', 16, 256, 16),
      _Bench('64 draws, 512x512', 64, 512, 16),
    ];
