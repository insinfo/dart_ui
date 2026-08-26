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
/// ## What is not chained, and why it is honest to say so
///
/// The two stages are *independent*, not producer and consumer. Coarse binning
/// reads per-draw bounds; flatten writes segments. The stage that would consume
/// the flattened segments is the per-tile segment binning that
/// `ComputeTileScene._binSegments` still does on the CPU, and it is not written
/// yet. So this measures the cost of the submission boundary honestly, and it
/// does **not** yet mean a scene goes from curves to coverage without leaving
/// the device.
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

import 'compute_curve_scene.dart';
import 'compute_scan.dart';
import 'd3d12_compute_binning_executor.dart';
import 'd3d12_compute_binning_shader.dart';
import 'd3d12_compute_flatten_executor.dart';
import 'd3d12_compute_flatten_shader.dart';

/// The two buffers a chained pass reads back, when it reads anything.
final class ComputeRasterReadback {
  const ComputeRasterReadback({required this.flatten, required this.binning});

  final ComputeFlattenReadback flatten;
  final ComputeBinningReadback binning;
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
  });

  const ComputeRasterBudget.unknown()
      : segments = 0,
        references = 0;

  /// Segments the flatten stage may write. Non-positive means "no idea".
  final int segments;

  /// Tile references the binning stage may write. Non-positive means the same.
  final int references;

  bool get isKnown => segments > 0 && references > 0;
}

/// Narrow, fakeable surface over one chained submission.
abstract interface class ComputeRasterDriver {
  /// Builds both stages' root signatures and pipeline states. Returns a
  /// non-zero token, or zero on refusal.
  int createRasterPipeline();

  void disposeRasterPipeline(int pipeline);

  /// Records the flatten chain and the binning chain into one command list, in
  /// that order, and submits it **once**.
  ///
  /// Returns the two stages' buffers when [readBack] is true, and null when it
  /// is false - in which case the submission does not wait on a fence either,
  /// and nothing this call produced may be read until [finish].
  ComputeRasterReadback? runRasterPass({
    required int pipeline,
    required ComputeCurveUpload scene,
    required Uint32List flattenConstants,
    required ComputeFlattenDispatch flattenDispatch,
    required Float32List bounds,
    required Uint32List binningConstants,
    required ComputeBinningDispatch binningDispatch,
    required bool readBack,
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
  });

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
    this.minimumSegmentBudget = 4096,
    this.minimumReferenceBudget = 4096,
  });

  /// The ceiling on the segment buffer, in segments - the number
  /// [ComputeFlattenExecutor.maxSegments] defaults to, for the same reason.
  final int maxSegments;

  /// The ceiling on the reference buffer, in references.
  final int maxReferences;

  final int minimumSegmentBudget;
  final int minimumReferenceBudget;

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
    _pipeline = _driver.createRasterPipeline();
    if (_pipeline == 0) {
      throw StateError('the GPU raster pipeline was refused');
    }
  }

  /// Flattens [scene] and bins [bounds] in one submission, and reads both back.
  ///
  /// A budget that turns out too small costs a *second* submission, exactly as
  /// the single-stage executors cost a second pass - the totals both stages
  /// report are exact, so one retry is always enough. [ComputeRasterResult.budget]
  /// is the pair that held.
  ComputeRasterResult run({
    required ComputeCurveUpload scene,
    required Float32List bounds,
    required int drawCount,
    required ComputeBinningGrid grid,
    ComputeRasterBudget budget = const ComputeRasterBudget.unknown(),
  }) =>
      _run(
        scene: scene,
        bounds: bounds,
        drawCount: drawCount,
        grid: grid,
        budget: budget,
        readBack: true,
      );

  /// Submits the same two chains without waiting and without reading anything.
  ///
  /// [budget] must name both totals: nothing comes back, so nothing can be
  /// retried. Call [finish] before touching anything the submission wrote, or
  /// before stopping a clock.
  ComputeRasterResult submit({
    required ComputeCurveUpload scene,
    required Float32List bounds,
    required int drawCount,
    required ComputeBinningGrid grid,
    required ComputeRasterBudget budget,
  }) {
    if (!budget.isKnown) {
      throw ArgumentError(
        'a submission that reads nothing back cannot grow a budget; name both '
        'totals, or use run() once to learn them',
      );
    }
    return _run(
      scene: scene,
      bounds: bounds,
      drawCount: drawCount,
      grid: grid,
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

    ComputeRasterReadback? back = _submit(
      scene: scene,
      bounds: bounds,
      drawCount: drawCount,
      grid: grid,
      segmentBudget: segmentBudget,
      referenceBudget: referenceBudget,
      readBack: readBack,
    );
    var submissions = 1;

    if (!readBack) {
      return ComputeRasterResult(
        flatten: null,
        binning: null,
        budget: ComputeRasterBudget(
          segments: segmentBudget,
          references: referenceBudget,
        ),
        submissions: submissions,
      );
    }

    ComputeRasterReadback read = back!;
    var segments = read.flatten.offsets[scene.curveCount];
    var references = _totalReferences(read.binning.bins, tileCount);
    if (segments > segmentBudget || references > referenceBudget) {
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
      // Both totals are exact whether or not the write landed - the atomics and
      // the scan advance either way - so one retry is always enough, and both
      // budgets are grown in the same retry rather than one submission each.
      if (segments > segmentBudget) segmentBudget = segments;
      if (references > referenceBudget) referenceBudget = references;
      back = _submit(
        scene: scene,
        bounds: bounds,
        drawCount: drawCount,
        grid: grid,
        segmentBudget: segmentBudget,
        referenceBudget: referenceBudget,
        readBack: true,
      );
      submissions = 2;
      read = back!;
      final int againSegments = read.flatten.offsets[scene.curveCount];
      final int againReferences =
          _totalReferences(read.binning.bins, tileCount);
      if (againSegments != segments || againReferences != references) {
        throw StateError(
          'the chained pass reported ($segments, $references) and then '
          '($againSegments, $againReferences) for the same scene; the stage '
          'buffers are not being reset between submissions',
        );
      }
      segments = againSegments;
      references = againReferences;
    }

    final int commandCount = read.binning.offsets[tileCount];
    if (commandCount > tileCount) {
      throw StateError(
        'the chained pass reported $commandCount commands over a grid of '
        '$tileCount tiles',
      );
    }

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
      budget: ComputeRasterBudget(
        segments: segmentBudget,
        references: referenceBudget,
      ),
      submissions: submissions,
    );
  }

  ComputeRasterReadback? _submit({
    required ComputeCurveUpload scene,
    required Float32List bounds,
    required int drawCount,
    required ComputeBinningGrid grid,
    required int segmentBudget,
    required int referenceBudget,
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

    return _driver.runRasterPass(
      pipeline: _pipeline,
      scene: scene,
      flattenConstants: flattenConstants,
      flattenDispatch: flattenDispatch,
      bounds: bounds,
      binningConstants: binningConstants,
      binningDispatch: binningDispatch,
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
