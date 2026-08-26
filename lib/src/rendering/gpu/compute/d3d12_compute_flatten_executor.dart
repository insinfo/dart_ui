/// Backend-neutral half of the GPU flatten stage.
///
/// Nothing here names Direct3D. [ComputeFlattenDriver] is the narrow, fakeable
/// surface a backend implements, for the reason
/// `test/architecture/layering_test.dart` enforces - and for a second one: the
/// five dispatches, the barriers between them and the overflow retry are
/// backend-independent *policy*, and policy that lives in an FFI file is policy
/// no test can reach without a GPU.
///
/// ## The pass is one call, and the retry is above it
///
/// [ComputeFlattenDriver.runFlattenPass] records all five dispatches, the UAV
/// barriers that order them, and the readback, as one indivisible operation -
/// the same argument `ComputeTileD3d12Driver.runTilePass` makes. What it
/// deliberately does *not* own is the decision to run again with a bigger
/// buffer: the segment total is a number, the budget is a number, and comparing
/// them belongs where it can be tested without a device.
///
/// ## Readback is a diagnostic shape, and it is temporary
///
/// A production pipeline would leave `counts`, `offsets` and `segments` on the
/// GPU and let the binning stage read them there. This returns all three to the
/// CPU because that is the only way to compare them with an oracle, and because
/// the binning stage that would consume them still runs on the CPU today. The
/// seam is drawn so that a future "leave it on the device" entry point is a
/// second method next to this one rather than a rewrite of it.
library;

import 'dart:typed_data';

import 'compute_curve_scene.dart';
import 'compute_scan.dart';
import 'd3d12_compute_flatten_shader.dart';

/// Why a scene could not be flattened on the GPU.
///
/// Named rather than thrown as a bare message, so a selector can treat a
/// refusal as "flatten on the CPU instead" without parsing English.
enum ComputeFlattenRejection {
  /// More curves than a two-level scan can prefix-sum, or than the emit
  /// dispatch - one group per curve - can address. See
  /// [kComputeFlattenMaxCurves] and [kComputeMaxDispatchGroups].
  curveCountExceedsScan,

  /// The scene needs more segments than the configured ceiling allows.
  segmentBudgetExceeded,

  /// The scene, the budget or a dispatch size overflows 32-bit indexing.
  integerOverflow,
}

final class ComputeFlattenError extends StateError {
  ComputeFlattenError(this.rejection, String detail)
      : super('${rejection.name}: $detail');

  final ComputeFlattenRejection rejection;
}

/// The three stage buffers, read back.
final class ComputeFlattenReadback {
  const ComputeFlattenReadback({
    required this.counts,
    required this.offsets,
    required this.segments,
  });

  /// `n` per curve, as `csCurveCounts` wrote it.
  final Uint32List counts;

  /// The exclusive prefix sum, `curveCount + 1` entries, grand total last.
  final Uint32List offsets;

  /// `x0, y0, x1, y1` per segment, `segmentBudget` entries long whether or not
  /// the scene filled it.
  final Float32List segments;
}

/// How many thread groups each of the five dispatches needs.
///
/// A value rather than four parameters because they are derived from one
/// scene and have to stay consistent: a scan whose block count disagrees with
/// the dispatch that produced the blocks reads uninitialised sums.
final class ComputeFlattenDispatch {
  const ComputeFlattenDispatch({
    required this.curveCount,
    required this.blockCount,
    required this.applyGroups,
    required this.segmentBudget,
  });

  /// Curves in the scene. Also the emit dispatch's group count - one group per
  /// curve; see `d3d12_compute_flatten_shader.dart` on why.
  final int curveCount;

  /// Groups for `csCurveCounts` and `csScanBlocks`, and the number of block
  /// sums `csScanBlockSums` scans in its single group.
  final int blockCount;

  /// Groups for `csScanApply`, which covers `curveCount + 1` elements.
  final int applyGroups;

  /// Elements in the segment buffer this pass may write.
  final int segmentBudget;
}

/// Narrow, fakeable surface over one flatten pass.
abstract interface class ComputeFlattenDriver {
  /// Compiles the five kernels and builds the root signature and pipeline
  /// states. Returns a non-zero token, or zero on refusal.
  int createFlattenPipeline();

  void disposeFlattenPipeline(int pipeline);

  /// Uploads [scene], zeroes the stage buffers, records the five dispatches in
  /// order with a barrier between each, and reads the three of them back.
  ComputeFlattenReadback runFlattenPass({
    required int pipeline,
    required ComputeCurveUpload scene,
    required Uint32List rootConstants,
    required ComputeFlattenDispatch dispatch,
  });

  /// Forgets objects invalidated by device removal without releasing them.
  void discardNativeResources();
}

/// One scene, flattened.
final class ComputeFlattenResult {
  const ComputeFlattenResult({
    required this.counts,
    required this.offsets,
    required this.segments,
    required this.totalSegments,
    required this.passes,
    required this.segmentBudget,
  });

  /// `n` per curve.
  final Uint32List counts;

  /// Exclusive prefix sum with the grand total appended.
  final Uint32List offsets;

  /// `x0, y0, x1, y1` per segment, trimmed to [totalSegments].
  final Float32List segments;

  final int totalSegments;

  /// 1 when the first budget held, 2 when it overflowed and was grown.
  ///
  /// Exposed because a caller that flattens the same scene every frame should
  /// carry [segmentBudget] forward and stop paying for the second pass, and a
  /// caller that never sees a 2 has a budget that is too large.
  final int passes;

  /// The budget the successful pass ran with.
  final int segmentBudget;

  bool get isEmpty => totalSegments == 0;
}

/// Runs the flatten kernels and owns the overflow retry.
final class ComputeFlattenExecutor {
  ComputeFlattenExecutor(
    this._driver, {
    this.maxSegments = 1 << 22,
    this.minimumSegmentBudget = 4096,
  }) {
    if (maxSegments <= 0) {
      throw RangeError.value(maxSegments, 'maxSegments', 'must be positive');
    }
    if (minimumSegmentBudget <= 0) {
      throw RangeError.value(
        minimumSegmentBudget,
        'minimumSegmentBudget',
        'must be positive',
      );
    }
  }

  /// The ceiling on the segment buffer, in segments.
  ///
  /// 4 Mi segments is 64 MiB. A scene above it is refused by name rather than
  /// allocating until the driver says no in a way nobody can attribute - the
  /// argument `ComputeTileD3d12Executor.maxCoverageElements` makes.
  final int maxSegments;

  /// The budget used when [flatten] is given none.
  ///
  /// A floor for the *absent* hint and not for the given one: a caller that
  /// names a budget is either carrying last frame's total forward or testing
  /// the overflow path, and silently raising either to a comfortable number is
  /// how the second pass stops being exercised.
  final int minimumSegmentBudget;

  final ComputeFlattenDriver _driver;

  int _pipeline = 0;
  bool _disposed = false;

  bool get isInitialized => _pipeline != 0;
  bool get isDisposed => _disposed;

  void initialize() {
    _throwIfDisposed();
    if (isInitialized) return;
    validateComputeFlattenShaderContract();
    _pipeline = _driver.createFlattenPipeline();
    if (_pipeline == 0) {
      throw StateError('the GPU flatten pipeline was refused');
    }
  }

  /// Flattens [scene], growing the segment buffer once if the first budget was
  /// too small.
  ///
  /// [segmentBudget] is a hint and not a limit: a scene that needs more runs
  /// again with exactly the total the first pass reported. Two passes at most,
  /// because the second budget is not an estimate - the emit kernel's bound
  /// does not change what the scan computes, so the total the first pass
  /// reported is the exact total. A non-positive hint means "no idea", and
  /// takes [minimumSegmentBudget].
  ComputeFlattenResult flatten(
    ComputeCurveUpload scene, {
    int segmentBudget = 0,
  }) {
    _throwIfDisposed();
    if (!isInitialized) {
      throw StateError('initialize the flatten executor before flatten');
    }
    if (scene.curveCount == 0) {
      return ComputeFlattenResult(
        counts: Uint32List(0),
        offsets: Uint32List(1),
        segments: Float32List(0),
        totalSegments: 0,
        passes: 0,
        segmentBudget: 0,
      );
    }
    if (scene.curveCount > kComputeFlattenMaxCurves ||
        scene.curveCount > kComputeMaxDispatchGroups) {
      throw ComputeFlattenError(
        ComputeFlattenRejection.curveCountExceedsScan,
        'the scene has ${scene.curveCount} curves; the two-level scan handles '
        '$kComputeFlattenMaxCurves and the emit dispatch - one group per '
        'curve - addresses $kComputeMaxDispatchGroups. A third scan level and '
        'an indirect dispatch are the two extensions, and neither exists yet',
      );
    }
    if (segmentBudget <= 0) segmentBudget = minimumSegmentBudget;
    if (segmentBudget > maxSegments) segmentBudget = maxSegments;

    ComputeFlattenReadback readback = _run(scene, segmentBudget);
    var total = readback.offsets[scene.curveCount];
    var passes = 1;
    if (total > segmentBudget) {
      if (total > maxSegments) {
        throw ComputeFlattenError(
          ComputeFlattenRejection.segmentBudgetExceeded,
          'the scene flattens to $total segments, over the configured ceiling '
          'of $maxSegments',
        );
      }
      segmentBudget = total;
      readback = _run(scene, segmentBudget);
      passes = 2;
      final int again = readback.offsets[scene.curveCount];
      if (again != total) {
        // The scan is a pure function of the scene, so the same scene twice has
        // to produce the same total. A different one means the buffers were not
        // zeroed, or the readback raced the dispatch.
        throw StateError(
          'the flatten scan reported $total segments and then $again for the '
          'same scene; the stage buffers are not being reset between passes',
        );
      }
      total = again;
    }

    return ComputeFlattenResult(
      counts: readback.counts,
      offsets: readback.offsets,
      segments: Float32List.sublistView(readback.segments, 0, total * 4),
      totalSegments: total,
      passes: passes,
      segmentBudget: segmentBudget,
    );
  }

  ComputeFlattenReadback _run(ComputeCurveUpload scene, int segmentBudget) {
    final ComputeFlattenDispatch dispatch = dispatchFor(
      curveCount: scene.curveCount,
      segmentBudget: segmentBudget,
    );
    final Uint32List constants = Uint32List(kComputeFlattenRootConstantCount);
    constants[ComputeFlattenRootConstant.curveCount] = scene.curveCount;
    constants[ComputeFlattenRootConstant.blockCount] = dispatch.blockCount;
    constants[ComputeFlattenRootConstant.maxSegments] = segmentBudget;
    constants[ComputeFlattenRootConstant.reserved] = 0;

    final ComputeFlattenReadback readback = _driver.runFlattenPass(
      pipeline: _pipeline,
      scene: scene,
      rootConstants: constants,
      dispatch: dispatch,
    );
    if (readback.counts.length != scene.curveCount) {
      throw StateError(
        'the flatten driver returned ${readback.counts.length} counts where '
        '${scene.curveCount} curves were dispatched',
      );
    }
    if (readback.offsets.length != scene.curveCount + 1) {
      throw StateError(
        'the flatten driver returned ${readback.offsets.length} offsets where '
        '${scene.curveCount + 1} were dispatched',
      );
    }
    if (readback.segments.length != segmentBudget * 4) {
      throw StateError(
        'the flatten driver returned ${readback.segments.length ~/ 4} segment '
        'slots where $segmentBudget were dispatched',
      );
    }
    return readback;
  }

  /// The group counts one pass needs, derived once so the five dispatches
  /// cannot disagree.
  static ComputeFlattenDispatch dispatchFor({
    required int curveCount,
    required int segmentBudget,
  }) {
    if (curveCount <= 0) {
      throw RangeError.value(curveCount, 'curveCount', 'must be positive');
    }
    if (segmentBudget <= 0) {
      throw RangeError.value(
        segmentBudget,
        'segmentBudget',
        'must be positive',
      );
    }
    if (segmentBudget > 0x7FFFFFFF ~/ 4) {
      throw ComputeFlattenError(
        ComputeFlattenRejection.integerOverflow,
        'a segment budget of $segmentBudget overflows 32-bit float4 indexing',
      );
    }
    final int blockCount = computeScanGroups(curveCount);
    final int applyGroups = computeScanGroups(curveCount + 1);
    return ComputeFlattenDispatch(
      curveCount: curveCount,
      blockCount: blockCount,
      applyGroups: applyGroups,
      segmentBudget: segmentBudget,
    );
  }

  void dispose() {
    if (_disposed) return;
    if (_pipeline != 0) _driver.disposeFlattenPipeline(_pipeline);
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
      throw StateError('the GPU flatten executor is disposed');
    }
  }
}
