/// Backend-neutral half of the GPU tile-binning stage.
///
/// The chain, the refusals and the bump-allocator retry live here for the
/// reason `d3d12_compute_flatten_executor.dart` states: they are policy over
/// numbers, and policy that lives in an FFI file is policy no test can reach
/// without a GPU.
///
/// ## The output is `ComputeTilePlan`'s, and that is the point
///
/// `bins`, `references` and `commands` are the three arrays
/// `ComputeTileScene.build` already produces on the CPU and
/// `d3d12_compute_tile_shader.dart` already consumes on the GPU. This stage
/// produces the same three from the same input - the per-draw bounds - so the
/// parity test has an oracle it did not have to invent, and so a scene binned
/// here can be handed to the existing coverage shader unchanged.
///
/// What it does **not** produce yet is the other half of what a fine raster
/// needs: the per-(tile, draw) segment lists and backdrops that
/// `ComputeTileScene._binSegments` computes. That is a separate stage over
/// segments rather than bounds, and it is the next one to move.
library;

import 'dart:typed_data';

import 'compute_scan.dart';
import 'd3d12_compute_binning_shader.dart';

/// Why a scene could not be binned on the GPU.
enum ComputeBinningRejection {
  /// More tiles than a two-level scan can prefix-sum, or than one dispatch
  /// dimension can address.
  tileCountExceedsScan,

  /// More draws than one dispatch dimension can address.
  drawCountExceedsDispatch,

  /// The scene needs more tile references than the configured ceiling allows.
  referenceBudgetExceeded,

  /// The grid, the budget or a dispatch size overflows 32-bit indexing.
  integerOverflow,
}

final class ComputeBinningError extends StateError {
  ComputeBinningError(this.rejection, String detail)
      : super('${rejection.name}: $detail');

  final ComputeBinningRejection rejection;
}

/// The tile grid one pass covers.
final class ComputeBinningGrid {
  ComputeBinningGrid({
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

/// The four stage buffers a pass reads back.
final class ComputeBinningReadback {
  const ComputeBinningReadback({
    required this.bins,
    required this.references,
    required this.commands,
    required this.offsets,
  });

  /// `firstReference, referenceCount` per tile.
  final Uint32List bins;

  /// Draw indices, tile-major, `referenceBudget` entries long whether or not
  /// the scene filled it.
  final Uint32List references;

  /// `tile, firstReference, referenceCount` per occupied tile, `tileCount`
  /// entries long - the most occupied tiles there can be.
  final Uint32List commands;

  /// The exclusive scan of the occupancy flags, grand total last: the number
  /// of commands actually written.
  final Uint32List offsets;
}

/// How many thread groups each dispatch of the chain needs.
final class ComputeBinningDispatch {
  const ComputeBinningDispatch({
    required this.drawGroups,
    required this.tileGroups,
    required this.blockCount,
    required this.applyGroups,
    required this.tileCount,
    required this.referenceBudget,
  });

  /// Groups for the two kernels indexed by draw.
  final int drawGroups;

  /// Groups for the kernels indexed by tile.
  final int tileGroups;

  /// Groups for the block scan, and the number of block sums the single-group
  /// kernel scans.
  final int blockCount;

  /// Groups for the scan's apply pass, which covers `tileCount + 1` elements.
  final int applyGroups;

  /// One sort group per tile; empty tiles retire immediately.
  final int tileCount;

  final int referenceBudget;
}

/// Narrow, fakeable surface over one binning pass.
abstract interface class ComputeBinningDriver {
  /// Compiles the kernels and builds the root signature and pipeline states.
  /// Returns a non-zero token, or zero on refusal.
  int createBinningPipeline();

  void disposeBinningPipeline(int pipeline);

  /// Uploads [bounds], zeroes the stage buffers, records the chain in order
  /// with a barrier between each dispatch, and reads four buffers back.
  ComputeBinningReadback runBinningPass({
    required int pipeline,
    required Float32List bounds,
    required Uint32List rootConstants,
    required ComputeBinningDispatch dispatch,
  });

  /// Forgets objects invalidated by device removal without releasing them.
  void discardNativeResources();
}

/// One scene, binned.
final class ComputeBinningResult {
  const ComputeBinningResult({
    required this.bins,
    required this.references,
    required this.commands,
    required this.referenceCount,
    required this.commandCount,
    required this.passes,
    required this.referenceBudget,
  });

  /// `firstReference, referenceCount` per tile - `ComputeTilePlan.bins`.
  final Uint32List bins;

  /// Draw indices, tile-major and draw-ordered within a tile, trimmed to
  /// [referenceCount] - `ComputeTilePlan.references`.
  final Uint32List references;

  /// `tile, firstReference, referenceCount` per occupied tile, trimmed to
  /// [commandCount] entries - `ComputeTilePlan.commands`.
  final Uint32List commands;

  final int referenceCount;
  final int commandCount;

  /// 1 when the first budget held, 2 when it overflowed and was grown.
  final int passes;

  /// The budget the successful pass ran with.
  final int referenceBudget;
}

/// Runs the binning kernels and owns the overflow retry.
final class ComputeBinningExecutor {
  ComputeBinningExecutor(
    this._driver, {
    this.maxReferences = 1 << 24,
    this.minimumReferenceBudget = 4096,
  }) {
    if (maxReferences <= 0) {
      throw RangeError.value(
          maxReferences, 'maxReferences', 'must be positive');
    }
    if (minimumReferenceBudget <= 0) {
      throw RangeError.value(
        minimumReferenceBudget,
        'minimumReferenceBudget',
        'must be positive',
      );
    }
  }

  /// The ceiling on the reference buffer, in references.
  ///
  /// 16 Mi is 64 MiB, and it is the same number `ComputeTileScene.build`
  /// defaults `maxTileReferences` to - so a scene the CPU planner accepts is one
  /// this stage accepts, and a scene it refuses is refused here by name rather
  /// than by allocation failure.
  final int maxReferences;

  /// The budget used when [bin] is given none.
  final int minimumReferenceBudget;

  final ComputeBinningDriver _driver;

  int _pipeline = 0;
  bool _disposed = false;

  bool get isInitialized => _pipeline != 0;
  bool get isDisposed => _disposed;

  void initialize() {
    _throwIfDisposed();
    if (isInitialized) return;
    validateComputeBinningShaderContract();
    _pipeline = _driver.createBinningPipeline();
    if (_pipeline == 0) {
      throw StateError('the GPU binning pipeline was refused');
    }
  }

  /// Bins [drawCount] draws whose device-space bounds are [bounds], four floats
  /// each, in the layout `ComputeTilePlan.bounds` uses.
  ComputeBinningResult bin({
    required Float32List bounds,
    required int drawCount,
    required ComputeBinningGrid grid,
    int referenceBudget = 0,
  }) {
    _throwIfDisposed();
    if (!isInitialized) {
      throw StateError('initialize the binning executor before bin');
    }
    if (drawCount < 0 || bounds.length < drawCount * 4) {
      throw ArgumentError(
        'a scene of $drawCount draws needs ${drawCount * 4} bound floats, got '
        '${bounds.length}',
      );
    }
    final int tileCount = grid.tileCount;
    if (grid.columns > 0x7FFFFFFF ~/ grid.rows) {
      throw ComputeBinningError(
        ComputeBinningRejection.integerOverflow,
        'a ${grid.columns} by ${grid.rows} tile grid overflows 32-bit indexing',
      );
    }
    if (tileCount > kComputeBinningMaxTiles ||
        tileCount > kComputeMaxDispatchGroups) {
      throw ComputeBinningError(
        ComputeBinningRejection.tileCountExceedsScan,
        'the grid has $tileCount tiles; the two-level scan handles '
        '$kComputeBinningMaxTiles and one sort dispatch addresses '
        '$kComputeMaxDispatchGroups',
      );
    }
    if (computeScanGroups(drawCount) > kComputeMaxDispatchGroups) {
      throw ComputeBinningError(
        ComputeBinningRejection.drawCountExceedsDispatch,
        'a scene of $drawCount draws needs more than '
        '$kComputeMaxDispatchGroups thread groups',
      );
    }
    if (drawCount == 0) {
      return ComputeBinningResult(
        bins: Uint32List(tileCount * 2),
        references: Uint32List(0),
        commands: Uint32List(0),
        referenceCount: 0,
        commandCount: 0,
        passes: 0,
        referenceBudget: 0,
      );
    }
    if (referenceBudget <= 0) referenceBudget = minimumReferenceBudget;
    if (referenceBudget > maxReferences) referenceBudget = maxReferences;

    ComputeBinningReadback readback = _run(bounds, drawCount, grid,
        tileCount: tileCount, referenceBudget: referenceBudget);
    var total = _totalReferences(readback.bins, tileCount);
    var passes = 1;
    if (total > referenceBudget) {
      if (total > maxReferences) {
        throw ComputeBinningError(
          ComputeBinningRejection.referenceBudgetExceeded,
          'the scene needs $total tile references, over the configured ceiling '
          'of $maxReferences',
        );
      }
      referenceBudget = total;
      readback = _run(bounds, drawCount, grid,
          tileCount: tileCount, referenceBudget: referenceBudget);
      passes = 2;
      final int again = _totalReferences(readback.bins, tileCount);
      if (again != total) {
        // The counting pass is a pure function of the bounds, so the same scene
        // twice has to produce the same total. A different one means the stage
        // buffers were not reset, or the readback raced the dispatch.
        throw StateError(
          'the binning pass counted $total references and then $again for the '
          'same scene; the stage buffers are not being reset between passes',
        );
      }
      total = again;
    }

    final int commandCount = readback.offsets[tileCount];
    if (commandCount > tileCount) {
      throw StateError(
        'the binning pass reported $commandCount commands over a grid of '
        '$tileCount tiles',
      );
    }
    return ComputeBinningResult(
      bins: readback.bins,
      references: Uint32List.sublistView(readback.references, 0, total),
      commands: Uint32List.sublistView(readback.commands, 0, commandCount * 3),
      referenceCount: total,
      commandCount: commandCount,
      passes: passes,
      referenceBudget: referenceBudget,
    );
  }

  /// The exclusive scan's grand total, recovered from the last tile's bin.
  ///
  /// `uOffsets` is scanned a second time - over the occupancy flags - so it no
  /// longer holds the reference prefix sum by the time the pass ends. The last
  /// tile's `firstReference + referenceCount` is that total and needs no extra
  /// buffer to carry it.
  static int _totalReferences(Uint32List bins, int tileCount) => tileCount == 0
      ? 0
      : bins[(tileCount - 1) * 2] + bins[(tileCount - 1) * 2 + 1];

  ComputeBinningReadback _run(
    Float32List bounds,
    int drawCount,
    ComputeBinningGrid grid, {
    required int tileCount,
    required int referenceBudget,
  }) {
    final ComputeBinningDispatch dispatch = dispatchFor(
      drawCount: drawCount,
      tileCount: tileCount,
      referenceBudget: referenceBudget,
    );
    final Uint32List constants = Uint32List(kComputeBinningRootConstantCount);
    constants[ComputeBinningRootConstant.drawCount] = drawCount;
    constants[ComputeBinningRootConstant.columns] = grid.columns;
    constants[ComputeBinningRootConstant.rows] = grid.rows;
    constants[ComputeBinningRootConstant.tileCount] = tileCount;
    constants[ComputeBinningRootConstant.blockCount] = dispatch.blockCount;
    constants[ComputeBinningRootConstant.tileSize] = grid.tileSize;
    constants[ComputeBinningRootConstant.width] = grid.width;
    constants[ComputeBinningRootConstant.height] = grid.height;
    constants[ComputeBinningRootConstant.maxReferences] = referenceBudget;
    constants[ComputeBinningRootConstant.reserved] = 0;

    final ComputeBinningReadback readback = _driver.runBinningPass(
      pipeline: _pipeline,
      bounds: bounds,
      rootConstants: constants,
      dispatch: dispatch,
    );
    if (readback.bins.length != tileCount * 2) {
      throw StateError(
        'the binning driver returned ${readback.bins.length ~/ 2} bins where '
        '$tileCount tiles were dispatched',
      );
    }
    if (readback.offsets.length != tileCount + 1) {
      throw StateError(
        'the binning driver returned ${readback.offsets.length} offsets where '
        '${tileCount + 1} were dispatched',
      );
    }
    if (readback.references.length != referenceBudget) {
      throw StateError(
        'the binning driver returned ${readback.references.length} reference '
        'slots where $referenceBudget were dispatched',
      );
    }
    if (readback.commands.length != tileCount * 3) {
      throw StateError(
        'the binning driver returned ${readback.commands.length ~/ 3} command '
        'slots where $tileCount were dispatched',
      );
    }
    return readback;
  }

  /// The group counts one pass needs, derived once so the eleven dispatches
  /// cannot disagree.
  static ComputeBinningDispatch dispatchFor({
    required int drawCount,
    required int tileCount,
    required int referenceBudget,
  }) {
    if (drawCount <= 0 || tileCount <= 0 || referenceBudget <= 0) {
      throw ArgumentError('a binning pass needs draws, tiles and a budget');
    }
    if (referenceBudget > 0x7FFFFFFF ~/ 4) {
      throw ComputeBinningError(
        ComputeBinningRejection.integerOverflow,
        'a reference budget of $referenceBudget overflows 32-bit indexing',
      );
    }
    return ComputeBinningDispatch(
      drawGroups: computeScanGroups(drawCount),
      tileGroups: computeScanGroups(tileCount),
      blockCount: computeScanGroups(tileCount),
      applyGroups: computeScanGroups(tileCount + 1),
      tileCount: tileCount,
      referenceBudget: referenceBudget,
    );
  }

  void dispose() {
    if (_disposed) return;
    if (_pipeline != 0) _driver.disposeBinningPipeline(_pipeline);
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
      throw StateError('the GPU binning executor is disposed');
    }
  }
}
