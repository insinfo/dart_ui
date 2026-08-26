/// The chained pipeline: the same stages, one submission, and what that costs.
///
/// `d3d12_compute_flatten_parity_test.dart` and
/// `d3d12_compute_binning_parity_test.dart` proved the two stages correct in
/// their oracle shape - one command list each, one fence each, everything read
/// back. This file is about the *other* shape, and it has two jobs.
///
/// ## One: chaining must not change a single byte
///
/// A chained submission records the same kernels over the same buffers into a
/// shared list. If that is true, its output is bit-identical to the unchained
/// output, which is itself bit-identical to the CPU planner. So the assertion
/// is equality with no tolerance - against the unchained executors *and*
/// against `ComputeTileScene.build`. A tolerance here would forgive precisely
/// the bug this file exists to catch: a missing barrier between two passes that
/// happen to share the device, which shows up as a rare wrong byte and never as
/// a near-miss.
///
/// ## Two: the number
///
/// `RASTERIZADOR_COMPUTE_D.md` recorded the honest finding that neither stage
/// was a win, because a pass costs ~0.8 ms of fence-and-readback almost
/// regardless of the scene, against 0.14-0.5 ms for the CPU planner doing more
/// work. Three shapes are timed here, on the same scenes, in one run, so the
/// comparison is against the same machine in the same thermal state:
///
///   1. **unchained** - `ComputeFlattenExecutor.flatten` then
///      `ComputeBinningExecutor.bin`: two command lists, two fences, two maps.
///      This is the number the document recorded.
///   2. **chained, read back** - one command list, one fence, one map.
///      The difference from (1) is one submission and one fence.
///   3. **chained, no readback** - one command list, no copies, no fence at
///      all, timed over a run of submissions and closed with a single
///      `finish()`. The difference from (2) is the fence and the map.
///
/// (2) minus (3) is what waiting costs. (1) minus (2) is what the extra
/// submission costs. Those two numbers are the point of the file: an
/// optimisation aimed at the wrong one of them would be aimed at nothing.
///
/// ## Three: what is left after the fence is gone
///
/// (3) is not free either, and the second measurement finds out why by varying
/// the one thing that changes bytes without changing work - the bump-allocator
/// budgets. Every dispatch size is derived from curve, draw and tile counts and
/// never from a budget, so quadrupling the budgets records exactly the same
/// seventeen dispatches over four times the memory. Whatever that costs extra
/// is per byte, and the per-byte cost turned out to be the **zero-fill**: a
/// memset into write-combined upload memory, at roughly 1 GB/s. It is measured
/// against the device-local zero source that replaced it, both shapes in the
/// same run, because `D3d12ComputePass.deviceZeroFill` keeps the old one
/// selectable for exactly this comparison.
///
/// The timings print rather than assert. A threshold on wall-clock time in a
/// test suite is a threshold that fails on somebody else's laptop, and the
/// claim being made is a comparison between shapes measured together, not an
/// absolute. What *is* asserted is the structural fact the timing is supposed
/// to explain: three stages cost one submission, not three.
///
/// ## Four: the comparison stops being a handicap
///
/// Every table above was measured with a CPU column doing **strictly more**
/// work than the GPU column: `ComputeTileScene.build` produces the per-tile
/// segment lists and the backdrops, and nothing on the device did. The segment
/// stage does now, so the last group here runs the same three shapes with it
/// chained in, and the two tables are printed in the same run on the same
/// machine. The difference between them is the price of the work the earlier
/// tables were not charging the GPU for.
library;

import 'package:dart_ui/src/backends/win32/d3d12/d3d12_compute_binning_driver.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_compute_flatten_driver.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_compute_raster_driver.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_compute_segment_driver.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/rendering/gpu/compute/compute_curve_scene.dart';
import 'package:dart_ui/src/rendering/gpu/compute/compute_raster_pipeline.dart';
import 'package:dart_ui/src/rendering/gpu/compute/d3d12_compute_binning_executor.dart';
import 'package:dart_ui/src/rendering/gpu/compute/d3d12_compute_flatten_executor.dart';
import 'package:dart_ui/src/rendering/gpu/compute/d3d12_compute_segment_executor.dart';
import 'package:dart_ui/src/rendering/gpu/vector/compute_tile_scene.dart';
import 'package:dart_ui/src/rendering/path/fill_rule.dart';
import 'package:test/test.dart';

import '../../../backends/win32/d3d12/d3d12_session.dart';

void main() {
  final D3d12Session session = D3d12Session.open();
  D3d12ComputeRasterDriver? rasterDriver;
  ComputeRasterPipeline? pipeline;
  D3d12ComputeRasterDriver? uploadZeroDriver;
  ComputeRasterPipeline? uploadZeroPipeline;
  D3d12ComputeFlattenDriver? flattenDriver;
  ComputeFlattenExecutor? flatten;
  D3d12ComputeBinningDriver? binningDriver;
  ComputeBinningExecutor? binning;
  D3d12ComputeSegmentDriver? segmentDriver;
  ComputeSegmentBinningExecutor? segmentBinning;

  tearDownAll(() {
    pipeline?.dispose();
    rasterDriver?.dispose();
    uploadZeroPipeline?.dispose();
    uploadZeroDriver?.dispose();
    flatten?.dispose();
    flattenDriver?.dispose();
    binning?.dispose();
    binningDriver?.dispose();
    segmentBinning?.dispose();
    segmentDriver?.dispose();
    session.close();
  });

  ComputeRasterPipeline? openPipeline() {
    if (session.device == null) return null;
    if (pipeline != null) return pipeline;
    final D3d12ComputeRasterDriver made =
        D3d12ComputeRasterDriver(session.device!);
    rasterDriver = made;
    return pipeline = ComputeRasterPipeline(made)..initialize();
  }

  /// The same pipeline with the old per-run CPU memset into upload memory.
  ComputeRasterPipeline openUploadZeroPipeline() {
    if (uploadZeroPipeline != null) return uploadZeroPipeline!;
    final D3d12ComputeRasterDriver made =
        D3d12ComputeRasterDriver(session.device!, deviceZeroFill: false);
    uploadZeroDriver = made;
    return uploadZeroPipeline = ComputeRasterPipeline(made)..initialize();
  }

  ComputeFlattenExecutor openFlatten() {
    if (flatten != null) return flatten!;
    final D3d12ComputeFlattenDriver made =
        D3d12ComputeFlattenDriver(session.device!);
    flattenDriver = made;
    return flatten = ComputeFlattenExecutor(made)..initialize();
  }

  ComputeBinningExecutor openBinning() {
    if (binning != null) return binning!;
    final D3d12ComputeBinningDriver made =
        D3d12ComputeBinningDriver(session.device!);
    binningDriver = made;
    return binning = ComputeBinningExecutor(made)..initialize();
  }

  ComputeSegmentBinningExecutor openSegments() {
    if (segmentBinning != null) return segmentBinning!;
    final D3d12ComputeSegmentDriver made =
        D3d12ComputeSegmentDriver(session.device!);
    segmentDriver = made;
    return segmentBinning = ComputeSegmentBinningExecutor(made)..initialize();
  }

  group('the chained pipeline builds on this device', () {
    test('all three stages compile into one driver', () {
      if (_skipped(session)) return;
      final ComputeRasterPipeline built = openPipeline()!;
      expect(built.isInitialized, isTrue);
      expect(rasterDriver!.isBuilt, isTrue);
    });
  });

  group('the segment stage chains onto the coarse stage it consumes', () {
    for (final _Scene scene in _scenes()) {
      test('${scene.name}: byte for byte against the CPU planner', () {
        if (_skipped(session)) return;
        // This is the one link in the pipeline that is a real
        // producer/consumer: the segment stage reads the tile index and the
        // references the coarse stage wrote, in the same command list, bound
        // by address. If a barrier were missing, or if the alias pointed at
        // the wrong buffer, the arrays below would be wrong - and they are the
        // arrays the coverage shader reads, so wrong here means a wrong
        // picture rather than a slow one.
        final ComputeRasterPipeline built = openPipeline()!;
        final ComputeTilePlan plan = scene.plan();
        final ComputeCurveUpload curves = scene.curves();
        final ComputeSegmentScene segmentScene = _segmentScene(plan);
        final ComputeBinningGrid grid = ComputeBinningGrid(
          width: plan.width,
          height: plan.height,
          tileSize: plan.tileSize,
        );

        final ComputeRasterResult learned = built.run(
          scene: curves,
          bounds: plan.bounds,
          drawCount: plan.drawCount,
          grid: grid,
          segmentScene: segmentScene,
        );
        final int before = built.submissions;
        final ComputeRasterResult chained = built.run(
          scene: curves,
          bounds: plan.bounds,
          drawCount: plan.drawCount,
          grid: grid,
          segmentScene: segmentScene,
          budget: learned.budget,
        );
        expect(built.submissions - before, 1,
            reason: 'three stages, one command list');
        expect(chained.submissions, 1);

        expect(chained.segments, isNotNull);
        expect(chained.segments!.referenceSegments, plan.referenceSegments,
            reason: 'the CSR segment index must match the CPU planner exactly');
        expect(chained.segments!.tileSegmentCount, plan.tileSegments.length);
        expect(chained.segments!.tileSegments, plan.tileSegments);
        expect(chained.segments!.backdrops, plan.referenceBackdrops);

        // And against the unchained stage, which the parity file proved
        // against the same oracle: chaining must not change a byte.
        final ComputeSegmentBinningResult unchained =
            openSegments().binSegments(
          scene: segmentScene,
          bins: plan.bins,
          references: plan.references,
          grid: ComputeSegmentBinningGrid(
            width: plan.width,
            height: plan.height,
            tileSize: plan.tileSize,
          ),
        );
        expect(chained.segments!.referenceSegments, unchained.referenceSegments,
            reason: 'the same kernels over the same buffers, one list or two');
        expect(chained.segments!.tileSegments, unchained.tileSegments);
        expect(chained.segments!.backdrops, unchained.backdrops);
      });
    }

    test('a fire-and-forget three-stage submission refuses an unknown budget',
        () {
      if (_skipped(session)) return;
      final ComputeRasterPipeline built = openPipeline()!;
      final ComputeTilePlan plan = _scenes().first.plan();
      // The two-stage shape needs two totals; the three-stage shape needs
      // three, and a budget that names only two is refused rather than
      // guessed at.
      expect(
        () => built.submit(
          scene: _scenes().first.curves(),
          bounds: plan.bounds,
          drawCount: plan.drawCount,
          grid: ComputeBinningGrid(
            width: plan.width,
            height: plan.height,
            tileSize: plan.tileSize,
          ),
          segmentScene: _segmentScene(plan),
          budget: const ComputeRasterBudget(segments: 64, references: 64),
        ),
        throwsArgumentError,
      );
    });
  });

  group('chaining changes nothing but the number of submissions', () {
    for (final _Scene scene in _scenes()) {
      test('${scene.name}: byte for byte against the unchained executors', () {
        if (_skipped(session)) return;
        final ComputeRasterPipeline built = openPipeline()!;
        final ComputeTilePlan plan = scene.plan();
        final ComputeCurveUpload curves = scene.curves();
        final ComputeBinningGrid grid = ComputeBinningGrid(
          width: plan.width,
          height: plan.height,
          tileSize: plan.tileSize,
        );

        // The first call may pay a retry: the default budget is a guess, and
        // the largest scene here genuinely needs more references than it.
        final ComputeRasterResult learned = built.run(
          scene: curves,
          bounds: plan.bounds,
          drawCount: plan.drawCount,
          grid: grid,
        );
        final int before = built.submissions;
        final ComputeRasterResult chained = built.run(
          scene: curves,
          bounds: plan.bounds,
          drawCount: plan.drawCount,
          grid: grid,
          budget: learned.budget,
        );
        // The structural claim, asserted rather than timed: two stages, one
        // command list. A second submission here would mean the chain fell
        // back to running the passes separately, and every timing below would
        // be measuring the old shape under a new name.
        expect(built.submissions - before, chained.submissions);
        expect(chained.submissions, 1,
            reason: 'the budgets came from the previous run, so they are exact '
                'and no retry is needed');

        final ComputeFlattenResult unchainedFlatten =
            openFlatten().flatten(curves);
        final ComputeBinningResult unchainedBinning = openBinning().bin(
          bounds: plan.bounds,
          drawCount: plan.drawCount,
          grid: grid,
        );

        expect(chained.flatten!.totalSegments, unchainedFlatten.totalSegments);
        expect(chained.flatten!.counts, unchainedFlatten.counts);
        expect(chained.flatten!.offsets, unchainedFlatten.offsets);
        expect(chained.flatten!.segments, unchainedFlatten.segments,
            reason: 'the same kernels over the same buffers must produce the '
                'same floats; a difference here is a missing barrier, not '
                'rounding');

        expect(chained.binning!.bins, unchainedBinning.bins);
        expect(chained.binning!.references, unchainedBinning.references);
        expect(chained.binning!.commands, unchainedBinning.commands);

        // And against the CPU planner the unchained stage was proved against,
        // so the chain is compared with the oracle and not only with its
        // sibling.
        expect(chained.binning!.bins, plan.bins);
        expect(chained.binning!.references, plan.references);
        expect(chained.binning!.commands, plan.commands);
      });
    }

    test('a budget that overflows costs a second submission and lands exactly',
        () {
      if (_skipped(session)) return;
      final ComputeRasterPipeline built = openPipeline()!;
      final _Scene scene = _scenes().last;
      final ComputeTilePlan plan = scene.plan();
      final ComputeCurveUpload curves = scene.curves();
      final ComputeBinningGrid grid = ComputeBinningGrid(
        width: plan.width,
        height: plan.height,
        tileSize: plan.tileSize,
      );

      final int before = built.submissions;
      final ComputeRasterResult grown = built.run(
        scene: curves,
        bounds: plan.bounds,
        drawCount: plan.drawCount,
        grid: grid,
        budget: const ComputeRasterBudget(segments: 8, references: 8),
      );
      expect(grown.submissions, 2,
          reason: 'both budgets are far too small, and both grow in the same '
              'retry rather than one submission each');
      expect(built.submissions - before, 2);
      expect(grown.binning!.references, plan.references);
      expect(grown.budget.segments, grown.flatten!.totalSegments);
      expect(grown.budget.references, plan.references.length);

      // Carried forward, the same scene costs one submission.
      final ComputeRasterResult again = built.run(
        scene: curves,
        bounds: plan.bounds,
        drawCount: plan.drawCount,
        grid: grid,
        budget: grown.budget,
      );
      expect(again.submissions, 1);
      expect(again.binning!.references, plan.references);
      expect(again.flatten!.segments, grown.flatten!.segments);
    });

    test('a submission that reads nothing back refuses an unknown budget', () {
      if (_skipped(session)) return;
      final ComputeRasterPipeline built = openPipeline()!;
      final ComputeTilePlan plan = _scenes().first.plan();
      expect(
        () => built.submit(
          scene: _scenes().first.curves(),
          bounds: plan.bounds,
          drawCount: plan.drawCount,
          grid: ComputeBinningGrid(
            width: plan.width,
            height: plan.height,
            tileSize: plan.tileSize,
          ),
          budget: const ComputeRasterBudget.unknown(),
        ),
        throwsArgumentError,
      );
    });

    test(
        'a fire-and-forget submission produces the same bytes once it is '
        'waited for', () {
      if (_skipped(session)) return;
      // The point of `submit` is that nothing is read, so the only thing that
      // can be asserted about it directly is that it does not corrupt the next
      // read. Submit, finish, then run the same scene and compare with the
      // oracle: a chain that left a buffer in the wrong state, or that skipped
      // a barrier because nothing waited, shows up here.
      final ComputeRasterPipeline built = openPipeline()!;
      final _Scene scene = _scenes()[1];
      final ComputeTilePlan plan = scene.plan();
      final ComputeCurveUpload curves = scene.curves();
      final ComputeBinningGrid grid = ComputeBinningGrid(
        width: plan.width,
        height: plan.height,
        tileSize: plan.tileSize,
      );
      final ComputeRasterResult warm = built.run(
        scene: curves,
        bounds: plan.bounds,
        drawCount: plan.drawCount,
        grid: grid,
      );
      final int before = built.waits;
      for (var i = 0; i < 4; i++) {
        built.submit(
          scene: curves,
          bounds: plan.bounds,
          drawCount: plan.drawCount,
          grid: grid,
          budget: warm.budget,
        );
      }
      expect(built.waits, before,
          reason: 'four submissions and not one fence wait');
      expect(built.finish(), isTrue);

      final ComputeRasterResult after = built.run(
        scene: curves,
        bounds: plan.bounds,
        drawCount: plan.drawCount,
        grid: grid,
        budget: warm.budget,
      );
      expect(after.binning!.bins, plan.bins);
      expect(after.binning!.references, plan.references);
      expect(after.flatten!.segments, warm.flatten!.segments);
    });
  });

  group('what the submission boundary costs', () {
    test('the same scenes in three shapes, against the CPU planner', () {
      if (_skipped(session)) return;
      final ComputeRasterPipeline built = openPipeline()!;
      final ComputeFlattenExecutor flat = openFlatten();
      final ComputeBinningExecutor bin = openBinning();

      final StringBuffer table = StringBuffer()
        ..writeln()
        ..writeln('| scene | draws | tiles | refs | segs | CPU build | '
            'unchained 2 passes | chained + read | chained, no read |')
        ..writeln('|---|---:|---:|---:|---:|---:|---:|---:|---:|');

      for (final _Scene scene in _scenes()) {
        final ComputeTilePlan plan = scene.plan();
        final ComputeCurveUpload curves = scene.curves();
        final ComputeBinningGrid grid = ComputeBinningGrid(
          width: plan.width,
          height: plan.height,
          tileSize: plan.tileSize,
        );

        // Warm every shape once: the first run of each grows its buffers, and
        // growing waits for idle. Measuring that would be measuring an
        // allocation, not a submission.
        final ComputeRasterResult warm = built.run(
          scene: curves,
          bounds: plan.bounds,
          drawCount: plan.drawCount,
          grid: grid,
        );
        final ComputeRasterBudget budget = warm.budget;
        flat.flatten(curves, segmentBudget: budget.segments);
        bin.bin(
          bounds: plan.bounds,
          drawCount: plan.drawCount,
          grid: grid,
          referenceBudget: budget.references,
        );
        scene.build();

        final double cpu = _time(_kIterations, () => scene.build());
        final double unchained = _time(_kIterations, () {
          flat.flatten(curves, segmentBudget: budget.segments);
          bin.bin(
            bounds: plan.bounds,
            drawCount: plan.drawCount,
            grid: grid,
            referenceBudget: budget.references,
          );
        });
        final double chained = _time(_kIterations, () {
          built.run(
            scene: curves,
            bounds: plan.bounds,
            drawCount: plan.drawCount,
            grid: grid,
            budget: budget,
          );
        });
        // One fence for the whole run, not one per iteration: the CPU is
        // allowed to be two submissions ahead, so this is the throughput a
        // frame path would see rather than the latency of one round trip.
        final int submissionsBefore = built.submissions;
        const int expectedSubmissions = _kIterations * _kBatches;
        final double streamed = _time(_kIterations, () {
          built.submit(
            scene: curves,
            bounds: plan.bounds,
            drawCount: plan.drawCount,
            grid: grid,
            budget: budget,
          );
        }, finish: built.finish);
        expect(built.submissions - submissionsBefore, expectedSubmissions,
            reason: 'one command list per iteration, not two');

        table.writeln('| ${scene.name} | ${plan.drawCount} | '
            '${plan.tileCount} | ${plan.references.length} | '
            '${warm.flatten!.totalSegments} | ${_us(cpu)} | '
            '${_us(unchained)} | ${_us(chained)} | ${_us(streamed)} |');
      }

      // ignore: avoid_print
      print(table.toString());
    });

    test('the same scenes with the segment stage chained in', () {
      if (_skipped(session)) return;
      // The honest table. Every column here computes the same function:
      // `ComputeTileScene.build` produces bins, references, commands, the
      // per-reference segment lists and the backdrops, and so does the GPU
      // chain. The previous table's GPU columns did not produce the last two,
      // which is why that comparison was a handicap and this one is not.
      //
      // The GPU columns still do *more* than the CPU column, not less: they
      // also flatten the curves, which `build()` does not - `appendPath` did
      // that before the clock started. That direction is the safe one to be
      // wrong in.
      final ComputeRasterPipeline built = openPipeline()!;
      final ComputeFlattenExecutor flat = openFlatten();
      final ComputeBinningExecutor bin = openBinning();
      final ComputeSegmentBinningExecutor seg = openSegments();

      final StringBuffer table = StringBuffer()
        ..writeln()
        ..writeln('| scene | draws | tiles | refs | tile segs | CPU build | '
            'unchained 3 passes | chained + read | chained, no read |')
        ..writeln('|---|---:|---:|---:|---:|---:|---:|---:|---:|');

      for (final _Scene scene in _scenes()) {
        final ComputeTilePlan plan = scene.plan();
        final ComputeCurveUpload curves = scene.curves();
        final ComputeSegmentScene segmentScene = _segmentScene(plan);
        final ComputeBinningGrid grid = ComputeBinningGrid(
          width: plan.width,
          height: plan.height,
          tileSize: plan.tileSize,
        );
        final ComputeSegmentBinningGrid segmentGrid = ComputeSegmentBinningGrid(
          width: plan.width,
          height: plan.height,
          tileSize: plan.tileSize,
        );

        // Warm every shape once: the first run of each grows its buffers, and
        // growing waits for idle.
        final ComputeRasterResult warm = built.run(
          scene: curves,
          bounds: plan.bounds,
          drawCount: plan.drawCount,
          grid: grid,
          segmentScene: segmentScene,
        );
        final ComputeRasterBudget budget = warm.budget;
        flat.flatten(curves, segmentBudget: budget.segments);
        bin.bin(
          bounds: plan.bounds,
          drawCount: plan.drawCount,
          grid: grid,
          referenceBudget: budget.references,
        );
        seg.binSegments(
          scene: segmentScene,
          bins: plan.bins,
          references: plan.references,
          grid: segmentGrid,
          tileSegmentBudget: budget.tileSegments,
        );
        scene.build();

        final double cpu = _time(_kIterations, () => scene.build());
        final double unchained = _time(_kIterations, () {
          flat.flatten(curves, segmentBudget: budget.segments);
          bin.bin(
            bounds: plan.bounds,
            drawCount: plan.drawCount,
            grid: grid,
            referenceBudget: budget.references,
          );
          seg.binSegments(
            scene: segmentScene,
            bins: plan.bins,
            references: plan.references,
            grid: segmentGrid,
            tileSegmentBudget: budget.tileSegments,
          );
        });
        final double chained = _time(_kIterations, () {
          built.run(
            scene: curves,
            bounds: plan.bounds,
            drawCount: plan.drawCount,
            grid: grid,
            segmentScene: segmentScene,
            budget: budget,
          );
        });
        final int submissionsBefore = built.submissions;
        const int expectedSubmissions = _kIterations * _kBatches;
        final double streamed = _time(_kIterations, () {
          built.submit(
            scene: curves,
            bounds: plan.bounds,
            drawCount: plan.drawCount,
            grid: grid,
            segmentScene: segmentScene,
            budget: budget,
          );
        }, finish: built.finish);
        expect(built.submissions - submissionsBefore, expectedSubmissions,
            reason: 'one command list per iteration, not three');

        table.writeln('| ${scene.name} | ${plan.drawCount} | '
            '${plan.tileCount} | ${plan.references.length} | '
            '${plan.tileSegments.length} | ${_us(cpu)} | '
            '${_us(unchained)} | ${_us(chained)} | ${_us(streamed)} |');
      }

      // ignore: avoid_print
      print(table.toString());
    });

    test('what is left of a submission is the zero-fill', () {
      if (_skipped(session)) return;
      // The residual cost of a submission that waits for nothing is not the
      // seventeen dispatches: it is proportional to the *bytes* of the stage
      // buffers, and the stage buffers are zeroed before every run. Two axes,
      // measured together:
      //
      //   * **1x against 4x buffers** - the same scene with four times the
      //     budgets. Every group count is derived from curve, draw and tile
      //     counts, never from a budget, so the dispatches are identical and
      //     only the bytes differ.
      //   * **device against upload** - the zero-fill copying from a
      //     default-heap buffer of zeros, against a fresh upload allocation the
      //     CPU memsets every run. Upload memory is write-combined.
      //
      // If the residual were dispatch-recording cost, all four cells would
      // agree. They do not, and the shape of the disagreement names the cause.
      final ComputeRasterPipeline fast = openPipeline()!;
      final ComputeRasterPipeline slow = openUploadZeroPipeline();

      final StringBuffer table = StringBuffer()
        ..writeln()
        ..writeln('| scene | zero-fill | 1x buffers | 4x buffers | per byte |')
        ..writeln('|---|---|---:|---:|---:|');

      for (final _Scene scene in _scenes()) {
        final ComputeTilePlan plan = scene.plan();
        final ComputeCurveUpload curves = scene.curves();
        final ComputeBinningGrid grid = ComputeBinningGrid(
          width: plan.width,
          height: plan.height,
          tileSize: plan.tileSize,
        );
        final ComputeRasterResult warm = fast.run(
          scene: curves,
          bounds: plan.bounds,
          drawCount: plan.drawCount,
          grid: grid,
        );
        final ComputeRasterBudget lean = warm.budget;
        final ComputeRasterBudget fat = ComputeRasterBudget(
          segments: lean.segments * 4,
          references: lean.references * 4,
        );
        final int leanBytes = _budgetBytes(lean);
        final int fatBytes = _budgetBytes(fat);

        for (final (String name, ComputeRasterPipeline built)
            in <(String, ComputeRasterPipeline)>[
          ('device', fast),
          ('upload', slow),
        ]) {
          // Warm each budget once per pipeline: the first run at a budget grows
          // the buffers, and growing waits for idle.
          built.run(
            scene: curves,
            bounds: plan.bounds,
            drawCount: plan.drawCount,
            grid: grid,
            budget: lean,
          );
          final double atLean = _time(_kIterations, () {
            built.submit(
              scene: curves,
              bounds: plan.bounds,
              drawCount: plan.drawCount,
              grid: grid,
              budget: lean,
            );
          }, finish: built.finish);
          built.run(
            scene: curves,
            bounds: plan.bounds,
            drawCount: plan.drawCount,
            grid: grid,
            budget: fat,
          );
          final double atFat = _time(_kIterations, () {
            built.submit(
              scene: curves,
              bounds: plan.bounds,
              drawCount: plan.drawCount,
              grid: grid,
              budget: fat,
            );
          }, finish: built.finish);
          final double perByte =
              (atFat - atLean) / (fatBytes - leanBytes) * (1 << 20);
          table.writeln('| ${scene.name} | $name | ${_us(atLean)} | '
              '${_us(atFat)} | ${perByte.toStringAsFixed(2)} us/MB |');
        }
      }

      // ignore: avoid_print
      print(table.toString());
    });
  });
}

/// Iterations per batch, and batches per measurement.
///
/// The reported number is the **minimum** batch mean, not the overall mean.
/// The first version of this file reported the mean and the same row moved by a
/// factor of seven between two runs a minute apart - an integrated GPU shares
/// its power budget with the cores, and this machine has other work on it. A
/// minimum is the closest thing to "what this costs when nothing is in the
/// way", it cannot be *below* the true cost, and interference can only make a
/// batch worse - so a comparison of minima is a comparison of the shapes rather
/// than of who got scheduled.
const int _kIterations = 8;
const int _kBatches = 4;

double _time(int iterations, void Function() body, {bool Function()? finish}) {
  var best = double.infinity;
  for (var batch = 0; batch < _kBatches; batch++) {
    final Stopwatch clock = Stopwatch()..start();
    for (var i = 0; i < iterations; i++) {
      body();
    }
    // Inside the timed region: a run of submissions that is never waited for
    // has not been paid for yet, and stopping the clock before the fence would
    // report the cost of queuing rather than of doing.
    if (finish != null) finish();
    clock.stop();
    final double mean = clock.elapsedMicroseconds / iterations;
    if (mean < best) best = mean;
  }
  return best;
}

String _us(double microseconds) => '${microseconds.toStringAsFixed(0)} us';

/// The stage bytes that depend on the budgets, and only those.
///
/// Everything else a submission zeroes - the per-tile counts, offsets, bins and
/// commands - is a function of the grid and is identical between the two
/// budgets being compared, so it cancels in the difference. The segment buffer
/// is four floats per segment, and the reference budget sizes two buffers: the
/// references and the scatter scratch beside them.
int _budgetBytes(ComputeRasterBudget budget) =>
    budget.segments * 16 + budget.references * 8;

/// A plan's own three scene arrays, in the shape the segment stage takes them.
///
/// Unmodified on purpose: the stage is fed exactly what the CPU planner binned,
/// so a difference in the output cannot be a difference in the input.
ComputeSegmentScene _segmentScene(ComputeTilePlan plan) => ComputeSegmentScene(
      segments: plan.segments,
      draws: plan.draws,
      bounds: plan.bounds,
    );

bool _skipped(D3d12Session session) {
  if (session.device != null) return false;
  markTestSkipped(session.skipReason ?? 'no Direct3D 12 device');
  return true;
}

final class _Scene {
  _Scene(this.name, this.draws, this.size, this.tileSize);

  final String name;
  final int draws;
  final int size;
  final int tileSize;

  /// The CPU plan - the oracle, and the CPU column of the table. Rebuilt every
  /// call on purpose: it is what is being timed.
  ComputeTilePlan plan() => build();

  ComputeTilePlan build() {
    final ComputeTileScene scene = ComputeTileScene();
    final Rect clip = Rect.fromLTRB(0, 0, size.toDouble(), size.toDouble());
    for (var i = 0; i < draws; i++) {
      scene.appendPath(
        _path(i),
        clip: clip,
        materialIndex: i,
        fillRule: FillRule.nonZero,
      );
    }
    return scene.build(width: size, height: size, tileSize: tileSize);
  }

  /// The same paths as curves, for the flatten stage.
  ComputeCurveUpload curves() {
    final ComputeCurveScene scene = ComputeCurveScene();
    for (var i = 0; i < draws; i++) {
      scene.appendPath(_path(i));
    }
    return scene.upload();
  }

  /// A rounded panel, so the flatten stage has real curves rather than only
  /// the four lines a rectangle would give it.
  Path _path(int i) {
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

/// The three sizes `RASTERIZADOR_COMPUTE_D.md` recorded, so the numbers in this
/// file and the numbers in that document are the same experiment.
List<_Scene> _scenes() => <_Scene>[
      _Scene('8 draws, 256x256', 8, 256, 16),
      _Scene('64 draws, 512x512', 64, 512, 16),
      _Scene('256 draws, 1024x1024', 256, 1024, 16),
    ];
