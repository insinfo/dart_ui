/// The chained entry point: flatten and binning in one submission.
///
/// `d3d12_compute_flatten_executor.dart` and `d3d12_compute_binning_executor.dart`
/// each run one stage, end it in a fence and map the result. That is the oracle
/// shape and it is what proved both stages correct. It is also why neither is a
/// win yet: measured on an Intel UHD at feature level 12_1, a binning pass costs
/// about 0.8 ms almost regardless of the scene, against 0.14-0.5 ms for the CPU
/// planner doing strictly more work. A pipeline that pays that per stage cannot
/// win no matter how fast the kernels are.
///
/// This is the second entry point the two executors' comments promised: the same
/// two stages, recorded into **one** command list, submitted once. Nothing here
/// names Direct3D, for the reason the other two executors state - the policy is
/// backend-independent, and policy that lives in an FFI file is policy no test
/// can reach without a GPU.
///
/// ## What "no fence in the middle" buys, and what it does not
///
/// Two things are being conflated when a pass is called slow, and they cost
/// differently:
///
///   * the **submission** - closing the list, `ExecuteCommandLists`, the
///     allocator reset the next `begin` performs, and the driver work behind
///     all three;
///   * the **fence wait** - the CPU blocking on an event until the GPU has
///     retired the list, plus the readback map.
///
/// Chaining removes one of each per stage folded in. [ComputeRasterPipeline.run]
/// still waits once, because a caller that asked to read something has to.
/// [ComputeRasterPipeline.submit] does not wait at all, and the gap between the
/// two is the measurement that says which of the two costs dominates - rather
/// than an optimisation aimed at whichever one was guessed.
///
/// ## What is chained, and what the third stage changed
///
/// The first version of this file chained two stages that were *independent*,
/// not producer and consumer: coarse binning reads per-draw bounds, flatten
/// writes segments, and neither reads the other. That measured the cost of the
/// submission boundary honestly and nothing else, because the stage that would
/// have consumed anything - the per-tile segment binning that
/// `ComputeTileScene._binSegments` did on the CPU - did not exist on the
/// device.
///
/// It exists now, and it is the first genuine producer/consumer link here: it
/// reads the tile index and the tile references the coarse stage wrote, in the
/// same command list, with no readback between them. `D3d12ComputeAlias` is
/// how - the consumer binds the producer's buffer by address rather than being
/// handed a copy. With it, `ComputeTilePlan`'s three per-reference arrays come
/// off the device, which is both what the coverage shader reads and what makes
/// the CPU column of the benchmark stop doing strictly more work than the GPU
/// column.
///
/// The segment stage is optional here, and that is deliberate rather than
/// transitional: the two-stage shape is the measurement the previous version of
/// `RASTERIZADOR_COMPUTE_D.md` published, and a benchmark that can no longer
/// produce the old row cannot show what the new one changed.
///
/// ## The flatten join, and why it is a mode rather than the only shape
///
/// Until it existed the flatten stage was a dead end *inside this chain*: it
/// wrote segments nobody read, while the segment stage was handed a
/// `ComputeTilePlan`'s segments and its `firstSegment`/`segmentCount` table
/// from the CPU. [ComputeFlattenJunction] is the other wiring - the segment and
/// coverage stages bind the flatten pass's segment buffer and the draw table
/// `csDrawTable` builds from its scan, and the CPU uploads no segment at all.
///
/// Both shapes stay reachable because they are the two sides of the parity
/// argument. The seeded shape is what four stages of oracles already prove; the
/// joined shape is what a frame would run, and the only way to say it is right
/// is to rasterise the same scene both ways and compare pixels. They cannot be
/// mixed: the two flatteners number their segments differently - see
/// `compute_curve_scene.dart` on the closing edge of a degenerate contour - so
/// a segment index resolved through the other half's table names an edge that
/// exists and belongs to another draw.
///
/// ## What the joined shape cannot know, and how it bounds it instead
///
/// The segment stage's ragged dispatch is as wide as the widest draw, in
/// segments. In the seeded shape that is a property of an array the CPU holds.
/// In the joined shape it is a *result of the scan*, and reading it is the
/// fence this pipeline exists to remove - so the dispatch runs over a bound and
/// [ComputeRasterBudget.drawSegments] is that bound, carried frame to frame
/// like every other budget here. A bound that is too small is not an error the
/// kernel can raise: its guard is `local >= segmentCount`, so the segments past
/// it are silently not binned. [ComputeRasterPipeline.run] therefore checks the
/// widest draw against the bound it dispatched with, out of the scan it read
/// back, and resubmits; [ComputeRasterPipeline.submit] demands the number
/// up front for the same reason it demands the other three.
///
/// ## The retry cannot be chained, and that is a real constraint
///
/// Both single-stage executors grow their bump-allocated buffer once when the
/// first budget was too small, and both need the total the pass computed to do
/// it - which is on the device until somebody waits. [ComputeRasterPipeline.run]
/// can still do it, at the cost of a second submission. [ComputeRasterPipeline.submit]
/// cannot, so it demands explicit budgets: a frame path carries the previous
/// frame's totals forward, which is what [ComputeRasterBudget] is for.
library;

import 'dart:typed_data';

import '../vector/compute_tile_scene.dart';
import 'compute_curve_scene.dart';
import 'compute_scan.dart';
import 'd3d12_compute_binning_executor.dart';
import 'd3d12_compute_binning_shader.dart';
import 'd3d12_compute_coverage_executor.dart';
import 'd3d12_compute_coverage_shader.dart';
import 'd3d12_compute_flatten_executor.dart';
import 'd3d12_compute_flatten_shader.dart';
import 'd3d12_compute_segment_executor.dart';
import 'd3d12_compute_segment_shader.dart';

/// The buffers a chained pass reads back, when it reads anything.
final class ComputeRasterReadback {
  const ComputeRasterReadback({
    required this.flatten,
    required this.binning,
    this.segments,
    this.coverage,
  });

  final ComputeFlattenReadback flatten;
  final ComputeBinningReadback binning;

  /// Null when the submission did not include the segment stage.
  final ComputeSegmentBinningReadback? segments;

  /// Null when the submission did not include the coverage stage.
  ///
  /// Not trustworthy on its own: a submission whose reference or tile-segment
  /// budget overflowed still rasterises, because the kernel bounds its borrowed
  /// indices rather than refusing, and what it rasterises from a truncated tile
  /// index is garbage. [ComputeRasterPipeline] is what knows whether the
  /// budgets held, and it drops this when they did not.
  final ComputeCoverageResult? coverage;
}

/// The bump-allocator budgets one chained submission runs with.
///
/// Carried forward frame to frame: a scene that flattened to `n` segments last
/// frame very nearly needs `n` this frame, and a budget that is already right
/// is a submission that does not have to be repeated.
final class ComputeRasterBudget {
  const ComputeRasterBudget({
    required this.segments,
    required this.references,
    this.tileSegments = 0,
    this.drawSegments = 0,
  });

  const ComputeRasterBudget.unknown()
      : segments = 0,
        references = 0,
        tileSegments = 0,
        drawSegments = 0;

  /// Segments the flatten stage may write. Non-positive means "no idea".
  final int segments;

  /// Tile references the binning stage may write. Non-positive means the same.
  final int references;

  /// Per-tile segment references the segment stage may write. Non-positive
  /// means the same, and is what a two-stage submission always carries.
  final int tileSegments;

  /// Segments in the widest draw, which is how wide the segment stage's ragged
  /// dispatch has to be.
  ///
  /// Only the joined shape needs it; the seeded one reads the number off the
  /// array it was handed. Non-positive means "no idea", and the joined shape
  /// then falls back to the segment budget - a bound that always holds, because
  /// one draw cannot flatten to more segments than the whole scene, at the cost
  /// of dispatching groups whose threads all retire at the guard.
  final int drawSegments;

  bool get isKnown => segments > 0 && references > 0;

  /// Whether the third budget is known too, which a submission that reads
  /// nothing back and includes the segment stage requires.
  bool get isKnownWithSegments => isKnown && tileSegments > 0;
}

/// Ask the segment and coverage stages to read the flatten stage's output.
///
/// A value rather than a bare `bool` because it carries the one number that
/// wiring needs and a boolean could not: how many draws the scene has, which is
/// what `csDrawTable` writes an entry each for and what the two consumers index
/// by. It has to be the curve scene's own path count and not a
/// `ComputeTilePlan`'s draw count - those differ whenever the planner drops a
/// draw whose flattened box came out empty, and a draw index off by one reads
/// another draw's segment range.
final class ComputeFlattenJunction {
  const ComputeFlattenJunction({required this.drawCount});

  final int drawCount;
}

/// Narrow, fakeable surface over one chained submission.
abstract interface class ComputeRasterDriver {
  /// Builds both stages' root signatures and pipeline states. Returns a
  /// non-zero token, or zero on refusal.
  int createRasterPipeline();

  void disposeRasterPipeline(int pipeline);

  /// Records the flatten chain, the coarse-binning chain and - when
  /// [segmentScene] is given - the segment-binning chain into one command list,
  /// in that order, and submits it **once**.
  ///
  /// The segment chain must read the coarse stage's tile index and references
  /// from that stage's own buffers, without a copy: it is the consumer, and a
  /// copy would need a fence. The coverage chain, when [coverageDispatch] is
  /// given, comes after both and reads five buffers across the two of them the
  /// same way; it requires [segmentScene], because three of the five are that
  /// stage's output.
  ///
  /// Returns the stages' buffers when [readBack] is true, and null when it is
  /// false - in which case the submission does not wait on a fence either, and
  /// nothing this call produced may be read until [finish].
  ComputeRasterReadback? runRasterPass({
    required int pipeline,
    required ComputeCurveUpload scene,
    required Uint32List flattenConstants,
    required ComputeFlattenDispatch flattenDispatch,
    required Float32List bounds,
    required Uint32List binningConstants,
    required ComputeBinningDispatch binningDispatch,
    required bool readBack,
    ComputeSegmentScene? segmentScene,
    bool joinFlatten = false,
    Uint32List? segmentConstants,
    ComputeSegmentBinningDispatch? segmentDispatch,
    ComputeCoverageDispatch? coverageDispatch,
  });

  /// Command lists this driver has submitted.
  ///
  /// The number a chained pipeline exists to reduce, and the one a test can
  /// assert on without a profiler: two stages, one submission.
  int get submissions;

  /// How many of those submissions ended in a fence wait.
  int get waits;

  /// Waits for every outstanding submission.
  bool finish();

  /// Forgets objects invalidated by device removal without releasing them.
  void discardNativeResources();
}

/// One scene, flattened and binned in a single submission.
final class ComputeRasterResult {
  const ComputeRasterResult({
    required this.flatten,
    required this.binning,
    required this.budget,
    required this.submissions,
    this.segments,
    this.coverage,
  });

  /// Null when the pass did not read back, or did not run the coverage stage.
  ///
  /// Present only when every budget held for the submission that produced it:
  /// a coverage buffer rasterised from a truncated tile index is garbage, and
  /// returning it would let a caller compare garbage against an oracle and
  /// report a parity failure for a budget problem.
  final ComputeCoverageResult? coverage;

  /// Null when the pass did not read back, or did not run the segment stage.
  final ComputeSegmentBinningResult? segments;

  /// Null when the pass did not read back.
  final ComputeFlattenResult? flatten;

  /// Null when the pass did not read back.
  final ComputeBinningResult? binning;

  /// The budgets that held. Feed this to the next frame.
  final ComputeRasterBudget budget;

  /// Command lists this call submitted: 1, or 2 when a budget had to grow.
  final int submissions;
}

/// Runs the flatten and binning chains in one command list.
final class ComputeRasterPipeline {
  ComputeRasterPipeline(
    this._driver, {
    this.maxSegments = 1 << 22,
    this.maxReferences = 1 << 24,
    this.maxTileSegments = 1 << 26,
    this.minimumSegmentBudget = 4096,
    this.minimumReferenceBudget = 4096,
    this.minimumTileSegmentBudget = 4096,
    this.maxCoverageElements = 1 << 26,
    this.sortPerThread = true,
  });

  /// The ceiling on the segment buffer, in segments - the number
  /// [ComputeFlattenExecutor.maxSegments] defaults to, for the same reason.
  final int maxSegments;

  /// The ceiling on the reference buffer, in references.
  final int maxReferences;

  /// The ceiling on the per-tile segment buffer, in entries - the number
  /// [ComputeSegmentBinningExecutor.maxTileSegments] defaults to.
  final int maxTileSegments;

  final int minimumSegmentBudget;
  final int minimumReferenceBudget;
  final int minimumTileSegmentBudget;

  /// The ceiling on the coverage buffer, in `uint`s - the number
  /// `ComputeTileD3d12Executor.maxCoverageElements` defaults to, for the same
  /// reason: the layout is one word per pixel *per draw*, so a modest scene
  /// asks for a diagnostic-sized buffer and a large one asks for an impossible
  /// one. Refused by name rather than by the driver.
  final int maxCoverageElements;

  /// Forwarded to [ComputeSegmentBinningDispatch.sortPerThread]. True is the
  /// production answer; false is the shape the benchmark compares it against.
  final bool sortPerThread;

  final ComputeRasterDriver _driver;

  int _pipeline = 0;
  bool _disposed = false;

  bool get isInitialized => _pipeline != 0;
  bool get isDisposed => _disposed;

  /// Command lists submitted since the driver was created.
  int get submissions => _driver.submissions;

  /// How many of those waited on a fence.
  int get waits => _driver.waits;

  void initialize() {
    _throwIfDisposed();
    if (isInitialized) return;
    validateComputeFlattenShaderContract();
    validateComputeBinningShaderContract();
    validateComputeSegmentShaderContract();
    validateComputeCoverageShaderContract();
    _pipeline = _driver.createRasterPipeline();
    if (_pipeline == 0) {
      throw StateError('the GPU raster pipeline was refused');
    }
  }

  /// Flattens [scene], bins [bounds], and - when [segmentScene] is given -
  /// bins that scene's segments into the tiles the second stage assigned, all
  /// in one submission, and reads it all back.
  ///
  /// A budget that turns out too small costs another submission, exactly as the
  /// single-stage executors cost a second pass: every total a stage reports is
  /// exact whether or not its writes landed. [ComputeRasterResult.budget] is
  /// the set that held.
  ComputeRasterResult run({
    required ComputeCurveUpload scene,
    required Float32List bounds,
    required int drawCount,
    required ComputeBinningGrid grid,
    ComputeSegmentScene? segmentScene,
    ComputeFlattenJunction? junction,
    ComputeCoverageRequest? coverage,
    ComputeRasterBudget budget = const ComputeRasterBudget.unknown(),
  }) =>
      _run(
        scene: scene,
        bounds: bounds,
        drawCount: drawCount,
        grid: grid,
        segmentScene: segmentScene,
        junction: junction,
        coverage: coverage,
        budget: budget,
        readBack: true,
      );

  /// Submits the same chains without waiting and without reading anything.
  ///
  /// [budget] must name every total the submission needs: nothing comes back,
  /// so nothing can be retried. Call [finish] before touching anything the
  /// submission wrote, or before stopping a clock.
  ComputeRasterResult submit({
    required ComputeCurveUpload scene,
    required Float32List bounds,
    required int drawCount,
    required ComputeBinningGrid grid,
    ComputeSegmentScene? segmentScene,
    ComputeFlattenJunction? junction,
    ComputeCoverageRequest? coverage,
    required ComputeRasterBudget budget,
  }) {
    final bool runsSegments = segmentScene != null || junction != null;
    final bool known =
        runsSegments ? budget.isKnownWithSegments : budget.isKnown;
    if (!known) {
      throw ArgumentError(
        'a submission that reads nothing back cannot grow a budget; name every '
        'total, or use run() once to learn them',
      );
    }
    if (junction != null && budget.drawSegments <= 0) {
      // The fallback the joined shape uses when this is absent is the segment
      // budget, which is safe but dispatches groups per draw that all retire at
      // the guard. A submission that reads nothing back cannot discover that it
      // over-dispatched either, so the number is required rather than guessed.
      throw ArgumentError(
        'a joined submission that reads nothing back has to name the widest '
        'draw in segments; run() once to learn it',
      );
    }
    return _run(
      scene: scene,
      bounds: bounds,
      drawCount: drawCount,
      grid: grid,
      segmentScene: segmentScene,
      junction: junction,
      coverage: coverage,
      budget: budget,
      readBack: false,
    );
  }

  /// Waits for every outstanding submission.
  bool finish() {
    _throwIfDisposed();
    return _driver.finish();
  }

  ComputeRasterResult _run({
    required ComputeCurveUpload scene,
    required Float32List bounds,
    required int drawCount,
    required ComputeBinningGrid grid,
    required ComputeSegmentScene? segmentScene,
    required ComputeFlattenJunction? junction,
    required ComputeCoverageRequest? coverage,
    required ComputeRasterBudget budget,
    required bool readBack,
  }) {
    _throwIfDisposed();
    if (!isInitialized) {
      throw StateError('initialize the raster pipeline before run');
    }
    if (scene.curveCount <= 0) {
      throw ArgumentError('a chained pass needs at least one curve');
    }
    if (drawCount <= 0) {
      throw ArgumentError('a chained pass needs at least one draw');
    }
    if (segmentScene != null && junction != null) {
      throw ArgumentError(
        'the segment table comes from the flatten stage or from a plan, never '
        'from both',
      );
    }
    if (junction != null && junction.drawCount != scene.pathCount) {
      throw ArgumentError(
        'the joined shape indexes the draw table csDrawTable writes, which has '
        '${scene.pathCount} entries, not ${junction.drawCount}',
      );
    }
    if (junction != null && junction.drawCount != drawCount) {
      throw ArgumentError(
        'the coarse stage bins $drawCount draws and the joined segment stage '
        'reads ${junction.drawCount}; the two index the same references',
      );
    }
    final bool runSegments = segmentScene != null || junction != null;
    if (coverage != null && !runSegments) {
      throw ArgumentError(
        'the coverage stage reads the three per-reference arrays the segment '
        'stage produces; ask for both or neither',
      );
    }
    if (bounds.length < drawCount * 4) {
      throw ArgumentError(
        'a scene of $drawCount draws needs ${drawCount * 4} bound floats, got '
        '${bounds.length}',
      );
    }
    if (scene.curveCount > kComputeFlattenMaxCurves ||
        scene.curveCount > kComputeMaxDispatchGroups) {
      throw ComputeFlattenError(
        ComputeFlattenRejection.curveCountExceedsScan,
        'the scene has ${scene.curveCount} curves; the two-level scan handles '
        '$kComputeFlattenMaxCurves and the emit dispatch - one group per '
        'curve - addresses $kComputeMaxDispatchGroups',
      );
    }
    final int tileCount = grid.tileCount;
    if (tileCount > kComputeBinningMaxTiles ||
        tileCount > kComputeMaxDispatchGroups) {
      throw ComputeBinningError(
        ComputeBinningRejection.tileCountExceedsScan,
        'the grid has $tileCount tiles; the two-level scan handles '
        '$kComputeBinningMaxTiles and one sort dispatch addresses '
        '$kComputeMaxDispatchGroups',
      );
    }

    var segmentBudget = budget.segments > 0
        ? (budget.segments > maxSegments ? maxSegments : budget.segments)
        : minimumSegmentBudget;
    var referenceBudget = budget.references > 0
        ? (budget.references > maxReferences
            ? maxReferences
            : budget.references)
        : minimumReferenceBudget;
    var tileSegmentBudget = budget.tileSegments > 0
        ? (budget.tileSegments > maxTileSegments
            ? maxTileSegments
            : budget.tileSegments)
        : minimumTileSegmentBudget;
    // The scene's own segment budget is the bound that always holds: one draw
    // cannot flatten to more segments than every draw together.
    var drawSegmentBudget = budget.drawSegments > 0
        ? (budget.drawSegments > segmentBudget
            ? segmentBudget
            : budget.drawSegments)
        : segmentBudget;

    if (!readBack) {
      _submit(
        scene: scene,
        bounds: bounds,
        drawCount: drawCount,
        grid: grid,
        segmentScene: segmentScene,
        junction: junction,
        coverage: coverage,
        segmentBudget: segmentBudget,
        referenceBudget: referenceBudget,
        tileSegmentBudget: tileSegmentBudget,
        drawSegmentBudget: drawSegmentBudget,
        readBack: false,
      );
      return ComputeRasterResult(
        flatten: null,
        binning: null,
        segments: null,
        budget: ComputeRasterBudget(
          segments: segmentBudget,
          references: referenceBudget,
          tileSegments: runSegments ? tileSegmentBudget : 0,
          drawSegments: junction == null ? 0 : drawSegmentBudget,
        ),
        submissions: 1,
      );
    }

    // Up to three submissions, and the third is only reachable with the
    // segment stage in the chain. The reason is a dependency, not a doubt: the
    // segment stage reads the *coarse* stage's references, so a reference
    // budget that overflowed makes its own total meaningless. Growing the
    // reference budget is what makes the segment total trustworthy, and only
    // then can it be too small in its own right. Every total is exact once its
    // inputs are, so the loop cannot cycle.
    ComputeRasterReadback read;
    var submissions = 0;
    var segments = 0;
    var references = 0;
    var tileSegments = 0;
    var widestDraw = 0;
    var previousValid = false;
    for (;;) {
      final ComputeRasterReadback current = _submit(
        scene: scene,
        bounds: bounds,
        drawCount: drawCount,
        grid: grid,
        segmentScene: segmentScene,
        junction: junction,
        coverage: coverage,
        segmentBudget: segmentBudget,
        referenceBudget: referenceBudget,
        tileSegmentBudget: tileSegmentBudget,
        drawSegmentBudget: drawSegmentBudget,
        readBack: true,
      )!;
      submissions++;
      final int nextSegments = current.flatten.offsets[scene.curveCount];
      final int nextReferences =
          _totalReferences(current.binning.bins, tileCount);
      final int nextTileSegments =
          current.segments?.offsets[referenceBudget] ?? 0;
      // Out of the scan, not out of the stage that consumed it: the scan is
      // exact whether or not the emit or the segment dispatch had room, which
      // is what makes one readback enough to size the next submission.
      final int nextWidestDraw =
          junction == null ? 0 : widestDrawOf(scene, current.flatten.offsets);

      if (submissions > 1) {
        // Every one of these is a pure function of the scene, so the same
        // scene twice has to report the same numbers. A difference means the
        // stage buffers were not reset, or a readback raced its dispatch. The
        // segment total is only comparable when the previous submission's
        // reference budget held, because otherwise its input was wrong.
        if (nextSegments != segments || nextReferences != references) {
          throw StateError(
            'the chained pass reported ($segments, $references) and then '
            '($nextSegments, $nextReferences) for the same scene; the stage '
            'buffers are not being reset between submissions',
          );
        }
        if (nextWidestDraw != widestDraw && submissions > 1 && widestDraw > 0) {
          throw StateError(
            'the chained pass reported a widest draw of $widestDraw segments '
            'and then $nextWidestDraw for the same scene; the stage buffers '
            'are not being reset between submissions',
          );
        }
        if (previousValid && nextTileSegments != tileSegments) {
          throw StateError(
            'the chained pass reported $tileSegments segment references and '
            'then $nextTileSegments for the same scene; the stage buffers are '
            'not being reset between submissions',
          );
        }
      }
      // A dispatch too narrow for the widest draw drops that draw's tail
      // segments at the kernel's own guard, so the segment stage's total is
      // meaningless for the same reason an overflowed reference budget makes
      // it meaningless.
      previousValid = nextReferences <= referenceBudget &&
          nextWidestDraw <= drawSegmentBudget;
      segments = nextSegments;
      references = nextReferences;
      tileSegments = nextTileSegments;
      widestDraw = nextWidestDraw;
      read = current;

      final bool grewSegments = segments > segmentBudget;
      final bool grewReferences = references > referenceBudget;
      final bool grewDrawSegments = widestDraw > drawSegmentBudget;
      final bool grewTileSegments =
          runSegments && previousValid && tileSegments > tileSegmentBudget;
      if (!grewSegments &&
          !grewReferences &&
          !grewDrawSegments &&
          !grewTileSegments) {
        break;
      }

      if (segments > maxSegments) {
        throw ComputeFlattenError(
          ComputeFlattenRejection.segmentBudgetExceeded,
          'the scene flattens to $segments segments, over the configured '
          'ceiling of $maxSegments',
        );
      }
      if (references > maxReferences) {
        throw ComputeBinningError(
          ComputeBinningRejection.referenceBudgetExceeded,
          'the scene needs $references tile references, over the configured '
          'ceiling of $maxReferences',
        );
      }
      if (previousValid && tileSegments > maxTileSegments) {
        throw ComputeSegmentBinningError(
          ComputeSegmentBinningRejection.tileSegmentBudgetExceeded,
          'the scene needs $tileSegments per-tile segment references, over the '
          'configured ceiling of $maxTileSegments',
        );
      }
      if (submissions >= 3) {
        throw StateError(
          'the chained pass did not converge on a budget in three submissions '
          'for a scene of $segments segments, $references references and '
          '$tileSegments segment references',
        );
      }
      if (grewSegments) segmentBudget = segments;
      if (grewReferences) referenceBudget = references;
      if (grewDrawSegments) drawSegmentBudget = widestDraw;
      if (grewTileSegments) tileSegmentBudget = tileSegments;
    }

    final int commandCount = read.binning.offsets[tileCount];
    if (commandCount > tileCount) {
      throw StateError(
        'the chained pass reported $commandCount commands over a grid of '
        '$tileCount tiles',
      );
    }

    final ComputeSegmentBinningReadback? segmentBack = read.segments;
    return ComputeRasterResult(
      flatten: ComputeFlattenResult(
        counts: read.flatten.counts,
        offsets: read.flatten.offsets,
        segments:
            Float32List.sublistView(read.flatten.segments, 0, segments * 4),
        totalSegments: segments,
        passes: submissions,
        segmentBudget: segmentBudget,
        drawTable: read.flatten.draws,
      ),
      binning: ComputeBinningResult(
        bins: read.binning.bins,
        references:
            Uint32List.sublistView(read.binning.references, 0, references),
        commands:
            Uint32List.sublistView(read.binning.commands, 0, commandCount * 3),
        referenceCount: references,
        commandCount: commandCount,
        passes: submissions,
        referenceBudget: referenceBudget,
      ),
      // The segment stage was dispatched over `referenceBudget` slots, not
      // over `references`: the count is a GPU result and a chained submission
      // cannot read it. The slots past the count are zero and are trimmed off
      // here, which is the only place that knows both numbers.
      segments: segmentBack == null
          ? null
          : ComputeSegmentBinningResult(
              referenceSegments: Uint32List.sublistView(
                segmentBack.referenceSegments,
                0,
                references * kComputeTileReferenceSegmentStride,
              ),
              tileSegments: Uint32List.sublistView(
                  segmentBack.tileSegments, 0, tileSegments),
              backdrops: Int32List.sublistView(
                segmentBack.backdrops,
                0,
                references * kComputeTileBackdropStride,
              ),
              tileSegmentCount: tileSegments,
              passes: submissions,
              tileSegmentBudget: tileSegmentBudget,
            ),
      // `read` is the submission the loop broke on, which is the one where
      // every budget held. An earlier submission's coverage was rasterised from
      // a tile index its own stage had truncated, and handing that to a caller
      // would turn a budget miss into a parity failure.
      coverage: read.coverage,
      budget: ComputeRasterBudget(
        segments: segmentBudget,
        references: referenceBudget,
        tileSegments: runSegments ? 0 + tileSegmentBudget : 0,
        drawSegments: junction == null ? 0 : drawSegmentBudget,
      ),
      submissions: submissions,
    );
  }

  /// Segments in the widest draw, from the curve scene's path table and the
  /// flatten stage's own scan.
  ///
  /// The number the joined shape's ragged dispatch has to cover. Public because
  /// it is also what a test asserts the dispatch against: the kernel's guard
  /// makes a too-narrow dispatch silent, so the only way to know it was wide
  /// enough is to compute the answer separately and compare.
  static int widestDrawOf(ComputeCurveUpload scene, Uint32List offsets) {
    var widest = 0;
    for (var draw = 0; draw < scene.pathCount; draw++) {
      final int base = draw * kComputeCurvePathStride;
      var first = scene.paths[base];
      var last = first + scene.paths[base + 1];
      if (first > scene.curveCount) first = scene.curveCount;
      if (last > scene.curveCount) last = scene.curveCount;
      final int span = offsets[last] - offsets[first];
      if (span > widest) widest = span;
    }
    return widest;
  }

  ComputeRasterReadback? _submit({
    required ComputeCurveUpload scene,
    required Float32List bounds,
    required int drawCount,
    required ComputeBinningGrid grid,
    required ComputeSegmentScene? segmentScene,
    required ComputeFlattenJunction? junction,
    required ComputeCoverageRequest? coverage,
    required int segmentBudget,
    required int referenceBudget,
    required int tileSegmentBudget,
    required int drawSegmentBudget,
    required bool readBack,
  }) {
    final ComputeFlattenDispatch flattenDispatch =
        ComputeFlattenExecutor.dispatchFor(
      curveCount: scene.curveCount,
      segmentBudget: segmentBudget,
      // Zero outside the joined shape, which is a stage the pass skips: a
      // submission nobody joins has no consumer for the table and paying for
      // it would change the benchmark rows this file exists to compare.
      pathCount: junction == null ? 0 : scene.pathCount,
    );
    final ComputeBinningDispatch binningDispatch =
        ComputeBinningExecutor.dispatchFor(
      drawCount: drawCount,
      tileCount: grid.tileCount,
      referenceBudget: referenceBudget,
    );

    final Uint32List flattenConstants =
        Uint32List(kComputeFlattenRootConstantCount);
    flattenConstants[ComputeFlattenRootConstant.curveCount] = scene.curveCount;
    flattenConstants[ComputeFlattenRootConstant.blockCount] =
        flattenDispatch.blockCount;
    flattenConstants[ComputeFlattenRootConstant.maxSegments] = segmentBudget;
    flattenConstants[ComputeFlattenRootConstant.pathCount] =
        flattenDispatch.pathCount;

    final Uint32List binningConstants =
        Uint32List(kComputeBinningRootConstantCount);
    binningConstants[ComputeBinningRootConstant.drawCount] = drawCount;
    binningConstants[ComputeBinningRootConstant.columns] = grid.columns;
    binningConstants[ComputeBinningRootConstant.rows] = grid.rows;
    binningConstants[ComputeBinningRootConstant.tileCount] = grid.tileCount;
    binningConstants[ComputeBinningRootConstant.blockCount] =
        binningDispatch.blockCount;
    binningConstants[ComputeBinningRootConstant.tileSize] = grid.tileSize;
    binningConstants[ComputeBinningRootConstant.width] = grid.width;
    binningConstants[ComputeBinningRootConstant.height] = grid.height;
    binningConstants[ComputeBinningRootConstant.maxReferences] =
        referenceBudget;
    binningConstants[ComputeBinningRootConstant.reserved] = 0;

    ComputeSegmentBinningDispatch? segmentDispatch;
    Uint32List? segmentConstants;
    if (segmentScene != null || junction != null) {
      final ComputeSegmentBinningGrid segmentGrid = ComputeSegmentBinningGrid(
        width: grid.width,
        height: grid.height,
        tileSize: grid.tileSize,
      );
      // The reference *budget*, not the reference count: the count is on the
      // device until somebody waits, which is the fence this chain removes.
      // `d3d12_compute_segment_shader.dart` argues why the extra slots change
      // no output.
      segmentDispatch = ComputeSegmentBinningExecutor.dispatchFor(
        drawCount: segmentScene?.drawCount ?? junction!.drawCount,
        // A bound in the joined shape and a count in the seeded one; see the
        // library comment on why the widest draw is not knowable here.
        maxDrawSegments: segmentScene?.maxDrawSegments ?? drawSegmentBudget,
        rows: grid.rows,
        tileCount: grid.tileCount,
        referenceSlots: referenceBudget,
        tileSegmentBudget: tileSegmentBudget,
        sortPerThread: sortPerThread,
      );
      segmentConstants = ComputeSegmentBinningExecutor.rootConstantsFor(
        grid: segmentGrid,
        dispatch: segmentDispatch,
      );
    }

    ComputeCoverageDispatch? coverageDispatch;
    if (coverage != null && segmentDispatch != null) {
      // Every argument is CPU-known, which is what makes the stage chainable.
      // Two of them are *budgets* and not counts, for the reason the segment
      // stage states: the reference and tile-segment totals are on the device
      // until somebody waits, and the kernel bounds its borrowed indices by
      // these so an overflowed submission produces garbage instead of touching
      // memory that is not there.
      coverageDispatch = ComputeCoverageDispatch.of(
        width: grid.width,
        height: grid.height,
        tileSize: grid.tileSize,
        columns: grid.columns,
        drawCount: segmentDispatch.drawCount,
        // One group per tile rather than per occupied tile: the occupancy total
        // is the coarse stage's output, and reading it is the fence the chain
        // removes. A command slot past the real count is zero and writes
        // nothing - `d3d12_compute_coverage_shader.dart` argues why.
        commandSlots: grid.tileCount,
        referenceSlots: referenceBudget,
        tileSegmentSlots: tileSegmentBudget,
        sampleGrid: coverage.sampleGrid,
        maxCoverageElements: maxCoverageElements,
      );
    }

    return _driver.runRasterPass(
      pipeline: _pipeline,
      scene: scene,
      flattenConstants: flattenConstants,
      flattenDispatch: flattenDispatch,
      bounds: bounds,
      binningConstants: binningConstants,
      binningDispatch: binningDispatch,
      segmentScene: segmentScene,
      joinFlatten: junction != null,
      segmentConstants: segmentConstants,
      segmentDispatch: segmentDispatch,
      coverageDispatch: coverageDispatch,
      readBack: readBack,
    );
  }

  /// The reference total, recovered from the last tile's bin - the argument
  /// [ComputeBinningExecutor] makes about why no extra buffer carries it.
  static int _totalReferences(Uint32List bins, int tileCount) => tileCount == 0
      ? 0
      : bins[(tileCount - 1) * 2] + bins[(tileCount - 1) * 2 + 1];

  void dispose() {
    if (_disposed) return;
    if (_pipeline != 0) _driver.disposeRasterPipeline(_pipeline);
    _pipeline = 0;
    _disposed = true;
  }

  /// Forgets driver objects destroyed by a reset and permits reinitialisation.
  void discardNativeResources() {
    _throwIfDisposed();
    _driver.discardNativeResources();
    _pipeline = 0;
  }

  /// Disposes after device removal, where releasing an object is undefined.
  void disposeAfterDeviceLoss() {
    if (_disposed) return;
    discardNativeResources();
    _disposed = true;
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('the GPU raster pipeline is disposed');
    }
  }
}
