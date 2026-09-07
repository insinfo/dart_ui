/// The coverage stage, chained onto the pipeline that now feeds it.
///
/// Until this file the pipeline stopped at the binned scene. Coverage ran on
/// the device - `d3d12_compute_tile_shader.dart` has rasterised a
/// `ComputeTilePlan` since well before the chain existed - but it ran from a
/// plan the **CPU** built, which means `ComputeTileScene.build` did the flatten,
/// the coarse binning, the segment binning and the backdrops before the GPU saw
/// anything. Chaining coverage after the segment stage removes that: the tile
/// index, the tile references, the per-reference segment lists and the
/// backdrops are produced on the device and consumed on the device, in one
/// command list, with no fence and no copy in between.
///
/// ## What a disagreement here would mean, and why the first oracle is the
/// other GPU route
///
/// The comparison that matters is against
/// `ComputeTileD3d12Executor.submit(plan)`: the coverage route that
/// `d3d12_compute_tile_parity_test.dart` already proved against
/// `ComputeTileCpuReference`. Both routes run the same transcribed loop over
/// the same segment table with the same integer quantisation, and the earlier
/// stages are byte-for-byte identical to the CPU planner - which
/// `d3d12_compute_raster_pipeline_test.dart` asserts on the same three arrays
/// this kernel reads. So the comparison is **exact, with no tolerance**, and a
/// difference cannot be rounding. It can only be one of the things this stage
/// is uniquely exposed to:
///
///   * an alias bound to the wrong producer's buffer - five of the six
///     read-write slots are somebody else's, and every one of them is a
///     plausible-looking array of `uint`s;
///   * a missing barrier between the segment stage's last dispatch and this
///     one, which would rasterise a half-written tile list;
///   * the zero-fill erasing a borrowed buffer instead of the output;
///   * the over-dispatch over tiles rather than commands writing something
///     through a command slot that was supposed to be empty.
///
/// None of those shows up in a unit test of any single stage, and all of them
/// produce a picture rather than a failure.
///
/// The CPU reference is then compared too, at the tolerance
/// `d3d12_compute_tile_parity_test.dart` measured and states: Dart evaluates
/// the crossing in float64 over float32 inputs and a shader evaluates it in
/// float32, so a crossing within a float32 ulp of a subsample can flip one
/// subsample, which is `255 / (sampleGrid * sampleGrid)` levels. On this
/// adapter the observed deviation was **0 on every scene**, the triangle, the
/// ellipse and the bowtie included; the tolerance is kept at the bound anyway,
/// for the reason stated where it is asserted.
///
/// ## The over-dispatch is tested by construction, not by an extra knob
///
/// The chained stage dispatches one thread group per **tile**, because the
/// occupied-tile count is the coarse stage's output and reading it is the fence
/// being removed. The unchained route dispatches one per **occupied tile**,
/// because its caller holds the plan. A scene whose draw touches one tile of
/// sixteen therefore runs the two routes at two different dispatch sizes over
/// the same scene, and requiring them to be byte-identical is exactly the claim
/// that a zeroed command slot writes nothing. The scenes below assert that they
/// really are different sizes before comparing, so the check cannot pass by
/// covering every tile.
library;

import 'package:dart_ui/src/backends/win32/d3d12/d3d12_compute_raster_driver.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/rendering/gpu/compute/compute_curve_scene.dart';
import 'package:dart_ui/src/rendering/gpu/compute/compute_raster_pipeline.dart';
import 'package:dart_ui/src/rendering/gpu/compute/d3d12_compute_binning_executor.dart';
import 'package:dart_ui/src/rendering/gpu/compute/d3d12_compute_coverage_executor.dart';
import 'package:dart_ui/src/rendering/gpu/compute/d3d12_compute_coverage_shader.dart';
import 'package:dart_ui/src/rendering/gpu/compute/d3d12_compute_segment_executor.dart';
import 'package:dart_ui/src/rendering/gpu/d3d12/d3d12_compute_tile_executor.dart';
import 'package:dart_ui/src/rendering/gpu/d3d12/d3d12_compute_tile_shader.dart';
import 'package:dart_ui/src/rendering/gpu/vector/compute_tile_reference.dart';
import 'package:dart_ui/src/rendering/gpu/vector/compute_tile_scene.dart';
import 'package:dart_ui/src/rendering/path/fill_rule.dart';
import 'package:test/test.dart';

import '../../../backends/win32/d3d12/d3d12_session.dart';

const int _width = 64;
const int _height = 64;
const int _tileSize = 16;
const Rect _clip = Rect.fromLTRB(0, 0, 64, 64);

/// One flipped subsample of sixteen, at the default grid.
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

  group('the two coverage kernels agree about the dispatch they share', () {
    test('the same thread group, asserted rather than assumed', () {
      // Two files declare a 16x16 group and a tile-size guard against it. If
      // one were edited alone, every scene below would still pass - they all
      // tile at 16 - and a scene tiled at 8 on one route and 16 on the other
      // would sample tile edges twice on exactly one of them.
      expect(kComputeCoverageMaxTileSize, kD3d12ComputeTileMaxTileSize);
    });

    test('the root-constant blocks share a prefix', () {
      // The parity below feeds the same scene to both kernels through two
      // encoders. They agree here or the comparison is between two different
      // dispatches wearing the same name.
      expect(ComputeCoverageRootConstant.width,
          D3d12ComputeTileRootConstant.width);
      expect(ComputeCoverageRootConstant.height,
          D3d12ComputeTileRootConstant.height);
      expect(ComputeCoverageRootConstant.tileSize,
          D3d12ComputeTileRootConstant.tileSize);
      expect(ComputeCoverageRootConstant.columns,
          D3d12ComputeTileRootConstant.columns);
      expect(ComputeCoverageRootConstant.sampleGrid,
          D3d12ComputeTileRootConstant.sampleGrid);
      expect(ComputeCoverageRootConstant.pixelsPerDraw,
          D3d12ComputeTileRootConstant.pixelsPerDraw);
      expect(ComputeCoverageRootConstant.commandCount,
          D3d12ComputeTileRootConstant.commandCount);
      expect(ComputeCoverageRootConstant.drawCount,
          D3d12ComputeTileRootConstant.drawCount);
      expect(ComputeCoverageRootConstant.selectedDraw,
          D3d12ComputeTileRootConstant.selectedDraw);
      expect(kComputeCoverageRootConstantCount,
          greaterThan(kD3d12ComputeTileRootConstantCount),
          reason: 'the two bounds this kernel needs and that one does not');
    });

    test('the contract check accepts the source it ships with', () {
      // Runs without a device, so a constant that drifted from the HLSL fails
      // on every runner rather than only where there is an adapter.
      expect(validateComputeCoverageShaderContract, returnsNormally);
    });
  });

  group('the chained pipeline builds the fourth stage on this device', () {
    test('four stages compile into one driver', () {
      if (_skipped(session)) return;
      final ComputeRasterPipeline built = open();
      expect(built.isInitialized, isTrue);
      expect(driver!.isBuilt, isTrue);
    });
  });

  group('chained coverage matches the coverage route already proved', () {
    for (final _Scene scene in _scenes()) {
      test('${scene.name}: byte for byte', () {
        if (_skipped(session)) return;
        final ComputeTilePlan plan = scene.plan();
        // The plan's own invariants first. A bin that omitted a covering draw
        // would make both routes agree on the *wrong* answer, because the
        // chained stages reproduce the same bins byte for byte.
        expect(ComputeTileCpuReference(plan).validateBins(), isEmpty);

        final ComputeCoverageResult chained =
            _chainedCoverage(open(), plan, scene.paths);
        final ComputeTileCoverage unchained =
            session.device!.submitComputeTiles(plan);

        expect(chained.commandSlots, plan.tileCount,
            reason:
                'the chain dispatches over tiles; it cannot read the count');
        expect(unchained.groupCount, plan.commandCount);
        if (scene.overDispatches) {
          expect(plan.commandCount, lessThan(plan.tileCount),
              reason: 'this scene exists to run the two routes at two sizes');
        }

        for (var draw = 0; draw < plan.drawCount; draw++) {
          expect(chained.rasterizedDraw(draw), unchained.rasterizedDraw(draw),
              reason: 'draw $draw differs between the chained and the '
                  'unchained coverage route');
        }
      });
    }
  });

  group('chained coverage matches the CPU reference', () {
    for (final _Scene scene in _scenes()) {
      test('${scene.name}: within ${scene.tolerance}', () {
        if (_skipped(session)) return;
        final ComputeTilePlan plan = scene.plan();
        final ComputeTileCpuReference reference = ComputeTileCpuReference(plan);
        final ComputeCoverageResult chained =
            _chainedCoverage(open(), plan, scene.paths);

        var worst = 0;
        for (var draw = 0; draw < plan.drawCount; draw++) {
          final expected = reference.rasterizeDrawUsingSegmentBins(draw);
          expect(expected, isNotNull,
              reason: 'draw $draw is missing from a tile it covers, which is a '
                  'binning failure and not a coverage one');
          for (var i = 0; i < expected!.length; i++) {
            final int got = chained.values[draw * chained.pixelsPerDraw + i];
            final int delta = (got - expected[i]).abs();
            if (delta > worst) worst = delta;
          }
        }
        expect(worst, lessThanOrEqualTo(scene.tolerance),
            reason: 'the float32/float64 crossing bound is one subsample, '
                '$_oneSubsample levels at this grid');
        // Observed on this adapter: 0 on every scene, slanted and curved
        // included. The tolerance stays at the bound rather than dropping to
        // what was measured, because the bound is a property of evaluating the
        // crossing in float32 against float64 and not of this run - a scene
        // whose crossing lands nearer a subsample would exercise it, and
        // tightening to 0 would turn that into a failure of the wrong thing.
      });
    }
  });

  group('the stage is deterministic and does not leak between runs', () {
    test('the same scene twice produces the same buffer', () {
      if (_skipped(session)) return;
      // The stages in front of this one place their references with atomics
      // and then rank-sort the runs, so the intermediate buffers genuinely
      // differ between runs while the sorted output does not. This asserts the
      // property survives one more consumer: a coverage kernel that read an
      // unsorted run would still produce *a* picture, and a different one each
      // time.
      final _Scene scene = _scenes().first;
      final ComputeTilePlan plan = scene.plan();
      final ComputeCoverageResult first =
          _chainedCoverage(open(), plan, scene.paths);
      final ComputeCoverageResult second =
          _chainedCoverage(open(), plan, scene.paths);
      expect(second.values, first.values);
    });

    test('a smaller scene after a larger one leaves no ink behind', () {
      if (_skipped(session)) return;
      // The coverage buffer is grown and reused, and only the pixels a tile
      // references are written. Without the per-run zero-fill the pixels a
      // large scene covered would still be lit under a small one - which reads
      // as a shape that grew rather than as a failure.
      final ComputeRasterPipeline built = open();
      final Path wide = _rect(2, 2, 62, 62);
      _chainedCoverage(built, _planFor(wide), <Path>[wide]);
      final Path narrow = _rect(20, 20, 28, 28);
      final ComputeTilePlan small = _planFor(narrow);
      final ComputeCoverageResult after =
          _chainedCoverage(built, small, <Path>[narrow]);
      final ComputeTileCoverage fresh =
          session.device!.submitComputeTiles(small);
      expect(after.rasterizedDraw(0), fresh.rasterizedDraw(0));
    });
  });

  group('the stage refuses what it cannot read', () {
    test('coverage without the segment stage is refused by name', () {
      // The three per-reference arrays are the segment stage's output. Without
      // it they are this pass's own zeroed buffers, every reference reads an
      // empty run, and every pixel comes back zero - a plausible answer, and
      // therefore the worst kind of wrong.
      if (_skipped(session)) return;
      final ComputeTilePlan plan = _planFor(_rect(8, 8, 40, 40));
      expect(
        () => open().run(
          scene: _curvesFor(<Path>[_rect(8, 8, 40, 40)]),
          bounds: plan.bounds,
          drawCount: plan.drawCount,
          grid: _gridFor(plan),
          coverage: const ComputeCoverageRequest(),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a coverage buffer over the ceiling is refused by name, not sized',
        () {
      // Without a device: the refusal is arithmetic over the caller's numbers,
      // and one word per pixel per draw reaches an impossible size on a scene
      // that is otherwise ordinary.
      expect(
        () => ComputeCoverageDispatch.of(
          width: 4096,
          height: 4096,
          tileSize: 16,
          columns: 256,
          drawCount: 64,
          commandSlots: 1,
          referenceSlots: 1,
          tileSegmentSlots: 1,
        ),
        throwsA(isA<ComputeCoverageError>().having(
          (ComputeCoverageError error) => error.rejection,
          'rejection',
          ComputeCoverageRejection.coverageBudgetExceeded,
        )),
      );
    });

    test('a zero borrowed budget is refused rather than rasterised empty', () {
      // Zero slots would drop every reference in the kernel's guard and return
      // a blank surface, which is indistinguishable from a scene that covers
      // nothing.
      expect(
        () => ComputeCoverageDispatch.of(
          width: 64,
          height: 64,
          tileSize: 16,
          columns: 4,
          drawCount: 1,
          commandSlots: 16,
          referenceSlots: 0,
          tileSegmentSlots: 16,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('what chaining coverage costs, against the route it replaces', () {
    test('the two routes, timed on the same scenes in one run', () {
      if (_skipped(session)) return;
      // The comparison has to be like for like, and the trap named in
      // `RELATORIO_POC_23_GPU_2D_STRATEGIES_INTEL_UHD.md` is comparing a
      // microkernel against a pipeline. So both columns below produce **the
      // same buffer**: one uint of coverage per pixel per draw, read back on
      // the CPU. Neither is a fragment of the work.
      //
      //   * "CPU plan + GPU coverage" is the route that exists today and is the
      //     only one reachable from a draw: `ComputeTileScene.build` flattens,
      //     bins, bins segments and computes backdrops on the CPU, and
      //     `submitComputeTiles` uploads all nine arrays and rasterises.
      //   * "chained" is this stage: the four kernels in one command list, with
      //     the binned scene never leaving the device.
      //
      // The chained column still does *more*, not less - it also flattens the
      // curves, which `build()` did before its clock started - so the number is
      // conservative against it.
      //
      // **What the gap is not only measuring.** Both columns read back the same
      // buffer, and at one uint per pixel per draw the largest row here is 64
      // MiB of it. Zeroing that buffer is not the same operation on the two
      // sides: `D3d12ComputePass` copies from a device-local page of zeros,
      // while `D3d12ComputeTileDriver` reserves upload memory and memsets it on
      // the CPU - and `RASTERIZADOR_COMPUTE_D.md` measured those at about 45-150
      // us/MB against about 700 us/MB. On the largest row that difference alone
      // accounts for tens of milliseconds, so the ratio below is **not** a clean
      // reading of what chaining bought. What it does show is where the
      // crossover sits, and that the chained route stops losing well before the
      // scene sizes that document benchmarks. And the budgets are known before the clock
      // starts, which is the frame shape: a frame carries the previous frame's
      // totals forward.
      final ComputeRasterPipeline built = open();
      final StringBuffer table = StringBuffer()
        ..writeln()
        ..writeln('| scene | draws | tiles | refs | tile segs | CPU plan + GPU '
            'coverage | chained |')
        ..writeln('|---|---:|---:|---:|---:|---:|---:|');

      for (final _Bench scene in _benchmarks()) {
        final ComputeTilePlan plan = scene.plan();
        final ComputeCurveUpload curves = _curvesFor(scene.paths);
        final ComputeSegmentScene segmentScene = ComputeSegmentScene(
          segments: plan.segments,
          draws: plan.draws,
          bounds: plan.bounds,
        );
        final ComputeBinningGrid grid = _gridFor(plan);
        final ComputeRasterBudget budget = built
            .run(
              scene: curves,
              bounds: plan.bounds,
              drawCount: plan.drawCount,
              grid: grid,
              segmentScene: segmentScene,
              coverage: const ComputeCoverageRequest(),
            )
            .budget;

        final double today = _time(_kIterations, () {
          // Rebuilt every iteration on purpose: it is what is being timed, and
          // a cached plan would be measuring the second frame of a static scene
          // rather than the cost of the route.
          session.device!.submitComputeTiles(scene.plan());
        });
        final double chained = _time(_kIterations, () {
          built.run(
            scene: curves,
            bounds: plan.bounds,
            drawCount: plan.drawCount,
            grid: grid,
            segmentScene: segmentScene,
            coverage: const ComputeCoverageRequest(),
            budget: budget,
          );
        });

        table.writeln('| ${scene.name} | ${plan.drawCount} | '
            '${plan.tileCount} | ${plan.referenceCount} | '
            '${plan.tileSegmentReferenceCount} | '
            '${today.round()} us | ${chained.round()} us |');
      }
      // Printed rather than asserted. A threshold on a wall clock is a test
      // that fails when the machine is busy, and the number this file is
      // responsible for is the parity above.
      // ignore: avoid_print
      print(table.toString());
    });
  });
}

/// Iterations per batch, and batches per measurement.
///
/// The reported number is the **minimum** batch mean, for the reason
/// `d3d12_compute_raster_pipeline_test.dart` states at length: an integrated
/// GPU shares its power budget with the cores, a mean moved by a factor of
/// seven between two runs a minute apart, and a minimum cannot be below the
/// true cost while interference can only make a batch worse.
const int _kIterations = 8;
const int _kBatches = 4;

double _time(int iterations, void Function() body) {
  var best = double.infinity;
  for (var batch = 0; batch < _kBatches; batch++) {
    final Stopwatch clock = Stopwatch()..start();
    for (var i = 0; i < iterations; i++) {
      body();
    }
    clock.stop();
    final double mean = clock.elapsedMicroseconds / iterations;
    if (mean < best) best = mean;
  }
  return best;
}

/// Runs the four-stage chain and returns its coverage.
///
/// Two calls, not one: the first learns the budgets and the second runs with
/// them, so the comparison is against a submission that did not have to grow
/// anything. That is also the shape a frame path has - the previous frame's
/// totals carried forward - so what is compared is what would run.
ComputeCoverageResult _chainedCoverage(
  ComputeRasterPipeline pipeline,
  ComputeTilePlan plan,
  List<Path> paths,
) {
  final ComputeCurveUpload curves = _curvesFor(paths);
  final ComputeSegmentScene segmentScene = ComputeSegmentScene(
    segments: plan.segments,
    draws: plan.draws,
    bounds: plan.bounds,
  );
  final ComputeBinningGrid grid = _gridFor(plan);
  final ComputeRasterResult learned = pipeline.run(
    scene: curves,
    bounds: plan.bounds,
    drawCount: plan.drawCount,
    grid: grid,
    segmentScene: segmentScene,
    coverage: const ComputeCoverageRequest(),
  );
  final ComputeRasterResult ran = pipeline.run(
    scene: curves,
    bounds: plan.bounds,
    drawCount: plan.drawCount,
    grid: grid,
    segmentScene: segmentScene,
    coverage: const ComputeCoverageRequest(),
    budget: learned.budget,
  );
  expect(ran.submissions, 1,
      reason: 'four stages in one command list, once the budgets are known');
  expect(ran.coverage, isNotNull);
  return ran.coverage!;
}

ComputeBinningGrid _gridFor(ComputeTilePlan plan) => ComputeBinningGrid(
      width: plan.width,
      height: plan.height,
      tileSize: plan.tileSize,
    );

/// The flatten stage's input.
///
/// Present because the chain runs all four stages and the flatten stage needs
/// curves, **not** because the coverage kernel reads its output: it does not,
/// and `d3d12_compute_coverage_shader.dart` states why that join does not exist
/// yet. Encoding the same paths keeps the submission the one a frame would make
/// rather than a stripped one.
ComputeCurveUpload _curvesFor(List<Path> paths) {
  final ComputeCurveScene scene = ComputeCurveScene();
  for (final Path path in paths) {
    scene.appendPath(path);
  }
  return scene.upload();
}

ComputeTilePlan _planFor(Path path, {FillRule rule = FillRule.nonZero}) {
  final ComputeTileScene scene = ComputeTileScene();
  scene.appendPath(path, clip: _clip, materialIndex: 0, fillRule: rule);
  return scene.build(width: _width, height: _height, tileSize: _tileSize);
}

Path _rect(double left, double top, double right, double bottom) =>
    (PathBuilder()..addRect(Rect.fromLTRB(left, top, right, bottom))).build();

final class _Scene {
  const _Scene(
    this.name,
    this.paths, {
    required this.tolerance,
    this.overDispatches = false,
    this.rule = FillRule.nonZero,
  });

  final String name;
  final List<Path> paths;

  /// The bound against the CPU reference. Zero where every edge is axis
  /// aligned, one subsample where one is not.
  final int tolerance;

  /// Whether this scene leaves tiles unoccupied, so the chained route really
  /// dispatches more groups than the unchained one.
  final bool overDispatches;

  final FillRule rule;

  ComputeTilePlan plan() {
    final ComputeTileScene scene = ComputeTileScene();
    for (var i = 0; i < paths.length; i++) {
      scene.appendPath(paths[i], clip: _clip, materialIndex: i, fillRule: rule);
    }
    return scene.build(width: _width, height: _height, tileSize: _tileSize);
  }
}

List<_Scene> _scenes() => <_Scene>[
      // The floor: one axis-aligned rectangle, exact on both sides, and the
      // scene where a wrong stride or a wrong column count shows up as a shape
      // in the wrong place.
      _Scene('one rectangle', <Path>[_rect(8, 8, 40, 40)], tolerance: 0),
      // One tile of sixteen occupied, so the chained route dispatches fifteen
      // groups the unchained one does not. See the library comment.
      _Scene('a draw in one tile of sixteen', <Path>[_rect(18, 18, 28, 28)],
          tolerance: 0, overDispatches: true),
      // Two draws sharing tiles: each tile's command names a run of
      // references, and a run read at the wrong offset composes the wrong draw
      // into the wrong output slice. The per-draw layout makes that visible
      // rather than blending it away.
      _Scene(
        'two draws sharing tiles',
        <Path>[_rect(4, 4, 36, 36), _rect(20, 20, 60, 60)],
        tolerance: 0,
      ),
      // Slanted edges: the crossing expression stops collapsing to x0, which
      // is where float32 and float64 can land on opposite sides of a
      // subsample.
      _Scene('a triangle', <Path>[_triangle()], tolerance: _oneSubsample),
      // Curves, and a shape wide enough that whole tile columns are backdrop
      // only - the case that leaves a shape hollow when the backdrop is
      // dropped instead of counted.
      _Scene('an ellipse', <Path>[_ellipse()], tolerance: _oneSubsample),
      // Even-odd, so the kernel's fill-rule branch is taken: a self-crossing
      // shape whose interior differs between the two rules.
      _Scene('an even-odd bowtie', <Path>[_bowtie()],
          tolerance: _oneSubsample, rule: FillRule.evenOdd),
    ];

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

bool _skipped(D3d12Session session) {
  if (session.device != null) return false;
  markTestSkipped(session.skipReason ?? 'no Direct3D 12 device');
  return true;
}

/// The benchmark's scenes, which are not the parity scenes.
///
/// Larger, because the parity scenes are 64x64 with one or two draws and at
/// that size the CPU planner is very nearly free - a table of them would say
/// only that four dispatches cost more than one, which is not in doubt. These
/// go up to where `RASTERIZADOR_COMPUTE_D.md` measured the chain winning.
///
/// **The per-draw coverage layout is what caps them.** One `uint` per pixel per
/// draw is 4 MiB at 256x256 with sixteen draws and 64 MiB at 512x512 with
/// sixty-four, and the 256-draw scene at 1024x1024 that document benchmarks
/// would need a gigabyte. That layout exists so an oracle can compare a draw at
/// a time; a composition path writes one draw into a target-sized texture and
/// has no such ceiling. So the largest row here is not the largest scene the
/// chain can bin - it is the largest whose coverage can be read back per draw.
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

  /// A rounded panel, so the flatten stage has real curves rather than the four
  /// lines a rectangle would give it - the same shape
  /// `d3d12_compute_raster_pipeline_test.dart` benchmarks, so the two files
  /// measure the same geometry.
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
