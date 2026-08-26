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
  });

  final ComputeFlattenReadback flatten;
  final ComputeBinningReadback binning;

  /// Null when the submission did not include the segment stage.
  final ComputeSegmentBinningReadback? segments;
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
  });

  const ComputeRasterBudget.unknown()
      : segments = 0,
        references = 0,
        tileSegments = 0;

  /// Segments the flatten stage may write. Non-positive means "no idea".
  final int segments;

  /// Tile references the binning stage may write. Non-positive means the same.
  final int references;

  /// Per-tile segment references the segment stage may write. Non-positive
  /// means the same, and is what a two-stage submission always carries.
  final int tileSegments;

  bool get isKnown => segments > 0 && references > 0;

  /// Whether the third budget is known too, which a submission that reads
  /// nothing back and includes the segment stage requires.
  bool get isKnownWithSegments => isKnown && tileSegments > 0;
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
  /// The segment chain must come last and must read the coarse stage's tile
  /// index and references from that stage's own buffers, without a copy: it is
  /// the consumer, and a copy would need a fence.
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
    Uint32List? segmentConstants,
    ComputeSegmentBinningDispatch? segmentDispatch,
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
  });

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
    ComputeRasterBudget budget = const ComputeRasterBudget.unknown(),
  }) =>
      _run(
        scene: scene,
        bounds: bounds,
        drawCount: drawCount,
        grid: grid,
        segmentScene: segmentScene,
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
    required ComputeRasterBudget budget,
  }) {
    final bool known =
        segmentScene == null ? budget.isKnown : budget.isKnownWithSegments;
    if (!known) {
      throw ArgumentError(
        'a submission that reads nothing back cannot grow a budget; name every '
        'total, or use run() once to learn them',
      );
    }
    return _run(
      scene: scene,
      bounds: bounds,
      drawCount: drawCount,
      grid: grid,
      segmentScene: segmentScene,
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

    if (!readBack) {
      _submit(
        scene: scene,
        bounds: bounds,
        drawCount: drawCount,
        grid: grid,
        segmentScene: segmentScene,
        segmentBudget: segmentBudget,
        referenceBudget: referenceBudget,
        tileSegmentBudget: tileSegmentBudget,
        readBack: false,
      );
      return ComputeRasterResult(
        flatten: null,
        binning: null,
        segments: null,
        budget: ComputeRasterBudget(
          segments: segmentBudget,
          references: referenceBudget,
          tileSegments: segmentScene == null ? 0 : tileSegmentBudget,
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
    var previousValid = false;
    for (;;) {
      final ComputeRasterReadback current = _submit(
        scene: scene,
        bounds: bounds,
        drawCount: drawCount,
        grid: grid,
        segmentScene: segmentScene,
        segmentBudget: segmentBudget,
        referenceBudget: referenceBudget,
        tileSegmentBudget: tileSegmentBudget,
        readBack: true,
      )!;
      submissions++;
      final int nextSegments = current.flatten.offsets[scene.curveCount];
      final int nextReferences =
          _totalReferences(current.binning.bins, tileCount);
      final int nextTileSegments =
          current.segments?.offsets[referenceBudget] ?? 0;

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
        if (previousValid && nextTileSegments != tileSegments) {
          throw StateError(
            'the chained pass reported $tileSegments segment references and '
            'then $nextTileSegments for the same scene; the stage buffers are '
            'not being reset between submissions',
          );
        }
      }
      previousValid = nextReferences <= referenceBudget;
      segments = nextSegments;
      references = nextReferences;
      tileSegments = nextTileSegments;
      read = current;

      final bool grewSegments = segments > segmentBudget;
      final bool grewReferences = references > referenceBudget;
      final bool grewTileSegments = segmentScene != null &&
          previousValid &&
          tileSegments > tileSegmentBudget;
      if (!grewSegments && !grewReferences && !grewTileSegments) break;

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
      budget: ComputeRasterBudget(
        segments: segmentBudget,
        references: referenceBudget,
        tileSegments: segmentScene == null ? 0 : tileSegmentBudget,
      ),
      submissions: submissions,
    );
  }

  ComputeRasterReadback? _submit({
    required ComputeCurveUpload scene,
    required Float32List bounds,
    required int drawCount,
    required ComputeBinningGrid grid,
    required ComputeSegmentScene? segmentScene,
    required int segmentBudget,
    required int referenceBudget,
    required int tileSegmentBudget,
    required bool readBack,
  }) {
    final ComputeFlattenDispatch flattenDispatch =
        ComputeFlattenExecutor.dispatchFor(
      curveCount: scene.curveCount,
      segmentBudget: segmentBudget,
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
    flattenConstants[ComputeFlattenRootConstant.reserved] = 0;

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
    if (segmentScene != null) {
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
        drawCount: segmentScene.drawCount,
        maxDrawSegments: segmentScene.maxDrawSegments,
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

    return _driver.runRasterPass(
      pipeline: _pipeline,
      scene: scene,
      flattenConstants: flattenConstants,
      flattenDispatch: flattenDispatch,
      bounds: bounds,
      binningConstants: binningConstants,
      binningDispatch: binningDispatch,
      segmentScene: segmentScene,
      segmentConstants: segmentConstants,
      segmentDispatch: segmentDispatch,
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
