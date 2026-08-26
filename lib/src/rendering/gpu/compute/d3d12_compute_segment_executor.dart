/// Backend-neutral half of the GPU segment-binning stage.
///
/// The chain, the refusals and the bump-allocator retry live here for the
/// reason `d3d12_compute_flatten_executor.dart` states: they are policy over
/// numbers, and policy that lives in an FFI file is policy no test can reach
/// without a GPU.
///
/// ## This is the stage that makes the comparison honest
///
/// `RASTERIZADOR_COMPUTE_D.md` recorded, twice, that the CPU column of every
/// benchmark did **strictly more** work than the GPU column: `ComputeTilePlan`
/// carries `referenceSegments`, `tileSegments` and `referenceBackdrops`, and
/// nothing on the device produced them. This produces them, from the same
/// inputs, to the same bytes. After it, `ComputeTileScene.build` and the GPU
/// chain compute the same function and the timing is a comparison rather than
/// a handicap.
///
/// It is also what the coverage stage actually reads.
/// `D3d12ComputeTileDriver` consumes `scene.segments` and
/// `scene.referenceBackdrops`; with those on the device, chaining coverage no
/// longer means routing the middle of the pipeline back through the CPU.
///
/// ## Why the reference count is a budget here
///
/// Every kernel is indexed by reference, and the reference count is a result of
/// the coarse stage. A chained submission cannot read it without the fence the
/// chain exists to remove, so the dispatch is sized by the same bump-allocator
/// budget the coarse stage ran with; `d3d12_compute_segment_shader.dart` argues
/// why slots past the real count change no output. The unchained shape passes
/// the exact count, which is just a budget that happens to be tight.
library;

import 'dart:typed_data';

import '../vector/compute_tile_scene.dart';
import 'compute_scan.dart';
import 'd3d12_compute_segment_shader.dart';

/// Why a scene's segments could not be binned on the GPU.
enum ComputeSegmentBinningRejection {
  /// More reference slots than a two-level scan can prefix-sum, or than one
  /// sort dispatch can address.
  referenceCountExceedsScan,

  /// More draws than one dispatch dimension can address.
  drawCountExceedsDispatch,

  /// One draw has more segments, or the grid more rows, than one dispatch
  /// dimension can address.
  segmentCountExceedsDispatch,

  /// The scene needs more per-tile segment references than the ceiling allows.
  tileSegmentBudgetExceeded,

  /// A budget or a dispatch size overflows 32-bit indexing.
  integerOverflow,
}

final class ComputeSegmentBinningError extends StateError {
  ComputeSegmentBinningError(this.rejection, String detail)
      : super('${rejection.name}: $detail');

  final ComputeSegmentBinningRejection rejection;
}

/// The scene arrays the stage reads that are not the coarse stage's output.
///
/// All three are `ComputeTilePlan`'s own, unmodified: a caller hands over what
/// it already uploaded rather than a re-encoding, so a difference in the result
/// cannot be a difference in the input.
final class ComputeSegmentScene {
  const ComputeSegmentScene({
    required this.segments,
    required this.draws,
    required this.bounds,
  });

  /// `x0, y0, x1, y1` per segment.
  final Float32List segments;

  /// `firstSegment, segmentCount, material, fillRule` per draw.
  final Uint32List draws;

  /// `left, top, right, bottom` per draw.
  final Float32List bounds;

  int get drawCount => draws.length ~/ kComputeTileDrawStride;

  /// The widest draw, in segments: the x extent of the ragged dispatch.
  int get maxDrawSegments {
    var widest = 0;
    for (var draw = 0; draw < drawCount; draw++) {
      final int count = draws[draw * kComputeTileDrawStride + 1];
      if (count > widest) widest = count;
    }
    return widest;
  }
}

/// The four stage buffers a pass reads back.
final class ComputeSegmentBinningReadback {
  const ComputeSegmentBinningReadback({
    required this.referenceSegments,
    required this.tileSegments,
    required this.backdrops,
    required this.offsets,
  });

  /// `firstSegment, segmentCount` per reference slot.
  final Uint32List referenceSegments;

  /// Segment indices, reference-major, `tileSegmentBudget` entries long
  /// whether or not the scene filled it.
  final Uint32List tileSegments;

  /// `winding, parity` per reference slot, as raw words.
  final Int32List backdrops;

  /// The exclusive scan of the per-reference counts, grand total last: the
  /// exact number of segment references the scene needs.
  final Uint32List offsets;
}

/// How many thread groups each dispatch of the chain needs.
final class ComputeSegmentBinningDispatch {
  const ComputeSegmentBinningDispatch({
    required this.drawCount,
    required this.segmentGroups,
    required this.rowGroups,
    required this.referenceSlots,
    required this.referenceGroups,
    required this.blockCount,
    required this.applyGroups,
    required this.tileCount,
    required this.tileSegmentBudget,
    required this.sortPerThread,
  });

  /// Groups on y for the two ragged kernels: one per draw.
  final int drawCount;

  /// Groups on x for them: the widest draw, in segment groups.
  final int segmentGroups;

  /// Groups on x for the backdrop scan: the grid's rows.
  final int rowGroups;

  /// Reference slots the chain covers - a budget, not a count.
  final int referenceSlots;

  /// Groups for the kernels indexed by reference slot.
  final int referenceGroups;

  /// Groups for the block scan, and the number of block sums the single-group
  /// kernel scans.
  final int blockCount;

  /// Groups for the scan's apply pass, which covers `referenceSlots + 1`.
  final int applyGroups;

  /// Tiles in the grid, which sizes the borrowed tile index.
  final int tileCount;

  final int tileSegmentBudget;

  /// Whether the rank sort runs one thread per reference rather than one group.
  ///
  /// True is the production answer; see
  /// `d3d12_compute_segment_shader.dart` on why a reference's run is short
  /// enough that a group per reference is mostly guard-and-retire. False stays
  /// reachable so the difference is a measurement.
  final bool sortPerThread;
}

/// Narrow, fakeable surface over one segment-binning pass.
abstract interface class ComputeSegmentBinningDriver {
  /// Compiles the kernels and builds the root signature and pipeline states.
  /// Returns a non-zero token, or zero on refusal.
  int createSegmentPipeline();

  void disposeSegmentPipeline(int pipeline);

  /// Uploads the scene, seeds the borrowed tile index with [bins] and
  /// [references], records the chain with a barrier between each dispatch, and
  /// reads four buffers back.
  ComputeSegmentBinningReadback runSegmentPass({
    required int pipeline,
    required ComputeSegmentScene scene,
    required Uint32List bins,
    required Uint32List references,
    required Uint32List rootConstants,
    required ComputeSegmentBinningDispatch dispatch,
  });

  /// Forgets objects invalidated by device removal without releasing them.
  void discardNativeResources();
}

/// One scene's segments, binned.
final class ComputeSegmentBinningResult {
  const ComputeSegmentBinningResult({
    required this.referenceSegments,
    required this.tileSegments,
    required this.backdrops,
    required this.tileSegmentCount,
    required this.passes,
    required this.tileSegmentBudget,
  });

  /// `firstSegment, segmentCount` per reference -
  /// `ComputeTilePlan.referenceSegments`.
  final Uint32List referenceSegments;

  /// Segment indices, reference-major and segment-ordered within a reference,
  /// trimmed to [tileSegmentCount] - `ComputeTilePlan.tileSegments`.
  final Uint32List tileSegments;

  /// `winding, parity` per reference -
  /// `ComputeTilePlan.referenceBackdrops`.
  final Int32List backdrops;

  final int tileSegmentCount;

  /// 1 when the first budget held, 2 when it overflowed and was grown.
  final int passes;

  /// The budget the successful pass ran with.
  final int tileSegmentBudget;
}

/// Runs the segment-binning kernels and owns the overflow retry.
final class ComputeSegmentBinningExecutor {
  ComputeSegmentBinningExecutor(
    this._driver, {
    this.maxTileSegments = 1 << 26,
    this.minimumTileSegmentBudget = 4096,
    this.sortPerThread = true,
  }) {
    if (maxTileSegments <= 0) {
      throw RangeError.value(
          maxTileSegments, 'maxTileSegments', 'must be positive');
    }
    if (minimumTileSegmentBudget <= 0) {
      throw RangeError.value(
        minimumTileSegmentBudget,
        'minimumTileSegmentBudget',
        'must be positive',
      );
    }
  }

  /// The ceiling on the per-tile segment buffer, in entries.
  ///
  /// 64 Mi is the same number `ComputeTileScene.build` defaults
  /// `maxTileSegmentReferences` to, so a scene the CPU planner accepts is one
  /// this stage accepts, and a scene it refuses is refused here by name.
  final int maxTileSegments;

  /// The budget used when [binSegments] is given none.
  final int minimumTileSegmentBudget;

  /// Forwarded to [ComputeSegmentBinningDispatch.sortPerThread].
  final bool sortPerThread;

  final ComputeSegmentBinningDriver _driver;

  int _pipeline = 0;
  bool _disposed = false;

  bool get isInitialized => _pipeline != 0;
  bool get isDisposed => _disposed;

  void initialize() {
    _throwIfDisposed();
    if (isInitialized) return;
    validateComputeSegmentShaderContract();
    _pipeline = _driver.createSegmentPipeline();
    if (_pipeline == 0) {
      throw StateError('the GPU segment-binning pipeline was refused');
    }
  }

  /// Bins [scene]'s segments into the tiles the coarse stage assigned.
  ///
  /// [bins] and [references] are that stage's output - `ComputeTilePlan.bins`
  /// and `ComputeTilePlan.references`, or the same two arrays as a
  /// `ComputeBinningResult` produced them.
  ComputeSegmentBinningResult binSegments({
    required ComputeSegmentScene scene,
    required Uint32List bins,
    required Uint32List references,
    required ComputeSegmentBinningGrid grid,
    int tileSegmentBudget = 0,
  }) {
    _throwIfDisposed();
    if (!isInitialized) {
      throw StateError('initialize the segment executor before binSegments');
    }
    final int drawCount = scene.drawCount;
    final int tileCount = grid.tileCount;
    if (bins.length != tileCount * kComputeTileBinStride) {
      throw ArgumentError(
        'a $tileCount tile grid needs ${tileCount * kComputeTileBinStride} '
        'bin words, got ${bins.length}',
      );
    }
    if (scene.bounds.length < drawCount * kComputeTileBoundsStride) {
      throw ArgumentError(
        'a scene of $drawCount draws needs '
        '${drawCount * kComputeTileBoundsStride} bound floats, got '
        '${scene.bounds.length}',
      );
    }
    if (drawCount == 0 || references.isEmpty) {
      return ComputeSegmentBinningResult(
        referenceSegments:
            Uint32List(references.length * kComputeTileReferenceSegmentStride),
        tileSegments: Uint32List(0),
        backdrops: Int32List(references.length * kComputeTileBackdropStride),
        tileSegmentCount: 0,
        passes: 0,
        tileSegmentBudget: 0,
      );
    }
    if (tileSegmentBudget <= 0) tileSegmentBudget = minimumTileSegmentBudget;
    if (tileSegmentBudget > maxTileSegments) {
      tileSegmentBudget = maxTileSegments;
    }

    final int referenceCount = references.length;
    ComputeSegmentBinningReadback readback = _run(
      scene,
      bins,
      references,
      grid,
      referenceSlots: referenceCount,
      tileSegmentBudget: tileSegmentBudget,
    );
    var total = readback.offsets[referenceCount];
    var passes = 1;
    if (total > tileSegmentBudget) {
      if (total > maxTileSegments) {
        throw ComputeSegmentBinningError(
          ComputeSegmentBinningRejection.tileSegmentBudgetExceeded,
          'the scene needs $total per-tile segment references, over the '
          'configured ceiling of $maxTileSegments',
        );
      }
      tileSegmentBudget = total;
      readback = _run(
        scene,
        bins,
        references,
        grid,
        referenceSlots: referenceCount,
        tileSegmentBudget: tileSegmentBudget,
      );
      passes = 2;
      final int again = readback.offsets[referenceCount];
      if (again != total) {
        // The counting pass is a pure function of the scene and the tile
        // index, so the same inputs twice have to produce the same total. A
        // different one means the stage buffers were not reset, or the
        // readback raced the dispatch.
        throw StateError(
          'the segment pass counted $total references and then $again for the '
          'same scene; the stage buffers are not being reset between passes',
        );
      }
      total = again;
    }

    return ComputeSegmentBinningResult(
      referenceSegments: Uint32List.sublistView(
        readback.referenceSegments,
        0,
        referenceCount * kComputeTileReferenceSegmentStride,
      ),
      tileSegments: Uint32List.sublistView(readback.tileSegments, 0, total),
      backdrops: Int32List.sublistView(
        readback.backdrops,
        0,
        referenceCount * kComputeTileBackdropStride,
      ),
      tileSegmentCount: total,
      passes: passes,
      tileSegmentBudget: tileSegmentBudget,
    );
  }

  ComputeSegmentBinningReadback _run(
    ComputeSegmentScene scene,
    Uint32List bins,
    Uint32List references,
    ComputeSegmentBinningGrid grid, {
    required int referenceSlots,
    required int tileSegmentBudget,
  }) {
    final ComputeSegmentBinningDispatch dispatch = dispatchFor(
      drawCount: scene.drawCount,
      maxDrawSegments: scene.maxDrawSegments,
      rows: grid.rows,
      tileCount: grid.tileCount,
      referenceSlots: referenceSlots,
      tileSegmentBudget: tileSegmentBudget,
      sortPerThread: sortPerThread,
    );
    final ComputeSegmentBinningReadback readback = _driver.runSegmentPass(
      pipeline: _pipeline,
      scene: scene,
      bins: bins,
      references: references,
      rootConstants: rootConstantsFor(grid: grid, dispatch: dispatch),
      dispatch: dispatch,
    );
    if (readback.offsets.length != referenceSlots + 1) {
      throw StateError(
        'the segment driver returned ${readback.offsets.length} offsets where '
        '${referenceSlots + 1} were dispatched',
      );
    }
    if (readback.tileSegments.length != tileSegmentBudget) {
      throw StateError(
        'the segment driver returned ${readback.tileSegments.length} segment '
        'slots where $tileSegmentBudget were dispatched',
      );
    }
    return readback;
  }

  /// The root constants one pass runs with, derived once so the two callers -
  /// this executor and the chained pipeline - cannot disagree.
  static Uint32List rootConstantsFor({
    required ComputeSegmentBinningGrid grid,
    required ComputeSegmentBinningDispatch dispatch,
  }) {
    final Uint32List constants = Uint32List(kComputeSegmentRootConstantCount);
    constants[ComputeSegmentRootConstant.drawCount] = dispatch.drawCount;
    constants[ComputeSegmentRootConstant.columns] = grid.columns;
    constants[ComputeSegmentRootConstant.rows] = grid.rows;
    constants[ComputeSegmentRootConstant.tileCount] = grid.tileCount;
    constants[ComputeSegmentRootConstant.tileSize] = grid.tileSize;
    constants[ComputeSegmentRootConstant.width] = grid.width;
    constants[ComputeSegmentRootConstant.height] = grid.height;
    constants[ComputeSegmentRootConstant.referenceSlots] =
        dispatch.referenceSlots;
    constants[ComputeSegmentRootConstant.blockCount] = dispatch.blockCount;
    constants[ComputeSegmentRootConstant.maxTileSegments] =
        dispatch.tileSegmentBudget;
    constants[ComputeSegmentRootConstant.reserved0] = 0;
    constants[ComputeSegmentRootConstant.reserved1] = 0;
    return constants;
  }

  /// The group counts one pass needs, derived once so the eight dispatches
  /// cannot disagree.
  static ComputeSegmentBinningDispatch dispatchFor({
    required int drawCount,
    required int maxDrawSegments,
    required int rows,
    required int tileCount,
    required int referenceSlots,
    required int tileSegmentBudget,
    bool sortPerThread = true,
  }) {
    if (drawCount <= 0 || rows <= 0 || tileCount <= 0) {
      throw ArgumentError('a segment pass needs draws, rows and tiles');
    }
    if (referenceSlots <= 0 || tileSegmentBudget <= 0) {
      throw ArgumentError('a segment pass needs reference slots and a budget');
    }
    if (referenceSlots > kComputeSegmentMaxReferences ||
        referenceSlots > kComputeMaxDispatchGroups) {
      throw ComputeSegmentBinningError(
        ComputeSegmentBinningRejection.referenceCountExceedsScan,
        'the scene needs $referenceSlots reference slots; the two-level scan '
        'handles $kComputeSegmentMaxReferences and one sort dispatch addresses '
        '$kComputeMaxDispatchGroups',
      );
    }
    if (drawCount > kComputeMaxDispatchGroups) {
      throw ComputeSegmentBinningError(
        ComputeSegmentBinningRejection.drawCountExceedsDispatch,
        'a scene of $drawCount draws needs more than '
        '$kComputeMaxDispatchGroups thread groups on the draw axis',
      );
    }
    final int segmentGroups = computeScanGroups(maxDrawSegments);
    final int rowGroups = computeScanGroups(rows);
    if (segmentGroups > kComputeMaxDispatchGroups ||
        rowGroups > kComputeMaxDispatchGroups) {
      throw ComputeSegmentBinningError(
        ComputeSegmentBinningRejection.segmentCountExceedsDispatch,
        'the widest draw has $maxDrawSegments segments over $rows tile rows; '
        'one dispatch dimension addresses $kComputeMaxDispatchGroups groups',
      );
    }
    if (tileSegmentBudget > 0x7FFFFFFF ~/ 4) {
      throw ComputeSegmentBinningError(
        ComputeSegmentBinningRejection.integerOverflow,
        'a segment budget of $tileSegmentBudget overflows 32-bit indexing',
      );
    }
    return ComputeSegmentBinningDispatch(
      drawCount: drawCount,
      // A draw with no segments still needs a dispatch that covers zero
      // threads without being skipped by the chain's `groups <= 0` guard, and
      // one group whose threads all fail the guard is the cheapest way to say
      // so.
      segmentGroups: segmentGroups == 0 ? 1 : segmentGroups,
      rowGroups: rowGroups,
      referenceSlots: referenceSlots,
      referenceGroups: computeScanGroups(referenceSlots),
      blockCount: computeScanGroups(referenceSlots),
      applyGroups: computeScanGroups(referenceSlots + 1),
      tileCount: tileCount,
      tileSegmentBudget: tileSegmentBudget,
      sortPerThread: sortPerThread,
    );
  }

  void dispose() {
    if (_disposed) return;
    if (_pipeline != 0) _driver.disposeSegmentPipeline(_pipeline);
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
      throw StateError('the GPU segment-binning executor is disposed');
    }
  }
}

/// The tile grid one segment pass covers.
///
/// The same four numbers `ComputeBinningGrid` carries, restated rather than
/// imported so this stage does not depend on the coarse stage's executor: the
/// two are chained in production and independent in the parity tests, and a
/// shared type would hide which of them a bug came from.
final class ComputeSegmentBinningGrid {
  ComputeSegmentBinningGrid({
    required this.width,
    required this.height,
    required this.tileSize,
  })  : columns = (width + tileSize - 1) ~/ tileSize,
        rows = (height + tileSize - 1) ~/ tileSize {
    if (width <= 0 || height <= 0 || tileSize <= 0) {
      throw ArgumentError('a tile grid needs a positive size');
    }
  }

  final int width;
  final int height;
  final int tileSize;
  final int columns;
  final int rows;

  int get tileCount => columns * rows;
}
