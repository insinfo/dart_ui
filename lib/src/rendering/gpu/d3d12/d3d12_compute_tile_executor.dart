/// Backend-neutral half of the Direct3D 12 compute-tile executor.
///
/// [ComputeTilePlan] was written as a preparation contract with no consumer.
/// This file is the first one, and it deliberately consumes the plan's typed
/// arrays *verbatim*: `segments`, `draws`, `bounds`, `bins`, `references` and
/// `commands` go to the GPU as the bytes they already are.
///
/// That is a result worth recording rather than a coincidence. The encoding was
/// designed without a device in the room, and it turned out to need **no
/// change** to be executable: every array is already exact-sized, already
/// float32 or uint32, already in a stride a `StructuredBuffer` can declare, and
/// the CSR bins already carry the one thing a dispatch needs - a command per
/// occupied tile, in order, naming a contiguous run of draw references. The
/// only additions this change makes are on this side of the seam: the tile-size
/// ceiling a thread group imposes, and the coverage buffer's layout.
///
/// Nothing here names Direct3D. [ComputeTileD3d12Driver] is the narrow,
/// fakeable surface a backend implements, for the reason
/// `test/architecture/layering_test.dart` enforces.
library;

import 'dart:typed_data';

import '../vector/compute_tile_scene.dart';
import 'd3d12_compute_tile_shader.dart';

/// Why a plan could not be dispatched.
///
/// Named rather than thrown as a bare message, so a selector can treat a
/// refusal as "fall back to the atlas" without parsing English.
enum ComputeTileD3d12Rejection {
  /// The plan's tile edge exceeds the thread group.
  tileSizeExceedsThreadGroup,

  /// The supersampling grid is outside the range the CPU oracle accepts, so a
  /// dispatch could not be compared with anything.
  sampleGridOutOfRange,

  /// The coverage buffer this plan would need exceeds the configured budget.
  coverageBudgetExceeded,

  /// The scene is larger than the shader's 32-bit indexing allows.
  integerOverflow,
}

final class ComputeTileD3d12Error extends StateError {
  ComputeTileD3d12Error(this.rejection, String detail)
      : super('${rejection.name}: $detail');

  final ComputeTileD3d12Rejection rejection;
}

/// The six read-only scene buffers, exactly as [ComputeTilePlan] holds them.
final class ComputeTileSceneUpload {
  const ComputeTileSceneUpload({
    required this.segments,
    required this.draws,
    required this.bounds,
    required this.bins,
    required this.references,
    required this.commands,
    required this.referenceSegments,
    required this.tileSegments,
    required this.referenceBackdrops,
  });

  /// `x0, y0, x1, y1` per segment. Bound as `StructuredBuffer<float4>`.
  final Float32List segments;

  /// `firstSegment, segmentCount, material, fillRule` per draw.
  final Uint32List draws;

  /// `left, top, right, bottom` per draw.
  final Float32List bounds;

  /// `firstReference, referenceCount` per tile.
  final Uint32List bins;

  /// Draw indices, tile-major, in draw order within each tile.
  final Uint32List references;

  /// `tile, firstReference, referenceCount` per occupied tile.
  final Uint32List commands;

  /// `firstSegment, segmentCount` into [tileSegments], per reference.
  final Uint32List referenceSegments;

  /// The segments a fine raster has to evaluate for one tile of one draw.
  final Uint32List tileSegments;

  /// `winding, parity` per reference: the crossings that are constant across
  /// the tile because they lie entirely to its right. The accumulator starts
  /// here rather than at zero - see `ComputeTileScene._binSegments`.
  final Int32List referenceBackdrops;
}

/// Narrow, fakeable surface over the Direct3D 12 compute calls.
///
/// [runTilePass] is one call and not six, and the reason is the readback:
/// reading a UAV on the CPU means closing the command list, executing it and
/// waiting on a fence, so the upload, the dispatch and the copy are one
/// indivisible operation whether or not the interface admits it. Splitting them
/// would invite a caller to interleave something between an upload and the
/// dispatch that reads it, which is precisely the bug the frame ring exists to
/// prevent.
///
/// A production shading path would not call this at all: it would leave the
/// coverage on the GPU and consume it in a following pass. That path does not
/// exist yet, and inventing an interface for it before it does would be
/// inventing its requirements too.
abstract interface class ComputeTileD3d12Driver {
  /// Compiles the compute shader and builds the root signature and pipeline
  /// state. Returns a non-zero token, or zero on refusal.
  int createComputePipeline();

  void disposeComputePipeline(int pipeline);

  /// Uploads [scene], zeroes a coverage buffer of [coverageElements] `uint`s,
  /// dispatches [groupCount] thread groups with [rootConstants], and returns
  /// the coverage buffer read back.
  Uint32List runTilePass({
    required int pipeline,
    required ComputeTileSceneUpload scene,
    required Uint32List rootConstants,
    required int coverageElements,
    required int groupCount,
  });

  /// Uploads [scene] and dispatches one draw's coverage into the storage
  /// texture named by [coverageDescriptorIndex].
  ///
  /// The composition counterpart of [runTilePass], and everything that differs
  /// between them is a consequence of one fact: this writes a texture the GPU
  /// itself will read next, so there is no readback, no fence wait, and no
  /// command list of its own. It records into the list the caller already has
  /// open, which is what lets the coverage land between the same dense batches
  /// the ordered submitter puts it between.
  ///
  /// The **caller owns the texture's resource state**: this records bindings
  /// and a dispatch and nothing else. Moving a storage texture between "written
  /// by compute" and "read by a pixel shader" is a barrier on a resource this
  /// seam only knows by descriptor index, and splitting that responsibility in
  /// two is how a missing barrier becomes nobody's job.
  void dispatchDrawIntoCoverageTexture({
    required int pipeline,
    required ComputeTileSceneUpload scene,
    required Uint32List rootConstants,
    required int groupCount,
    required int coverageDescriptorIndex,
  });

  /// Forgets objects invalidated by device removal without releasing them.
  void discardNativeResources();
}

/// The whole-pixel rectangle a composite pass must cover, and may not exceed.
///
/// Half-open on the right and bottom, in device pixels, already clamped to the
/// surface. See [ComputeTileD3d12Executor.dispatchDrawCoverage] for why the
/// upper bound is as load bearing as the lower one.
final class ComputeTileCompositeRect {
  const ComputeTileCompositeRect._(this.left, this.top, this.right, this.bottom);

  final int left;
  final int top;
  final int right;
  final int bottom;

  int get width => right - left;
  int get height => bottom - top;

  @override
  String toString() => 'ComputeTileCompositeRect($left, $top, $right, $bottom)';
}

/// One dispatch's coverage, in the layout the CPU oracle rasterises to.
final class ComputeTileCoverage {
  ComputeTileCoverage._({
    required this.width,
    required this.height,
    required this.drawCount,
    required this.sampleGrid,
    required this.groupCount,
    required Uint32List values,
  }) : _values = values;

  final int width;
  final int height;
  final int drawCount;
  final int sampleGrid;

  /// Thread groups dispatched, which is the plan's occupied tile count.
  final int groupCount;

  final Uint32List _values;

  int get pixelsPerDraw => width * height;

  /// Coverage 0..255 of [draw] at ([x], [y]).
  int coverageAt(int draw, int x, int y) {
    if (draw < 0 || draw >= drawCount) {
      throw RangeError.range(draw, 0, drawCount - 1, 'draw');
    }
    if (x < 0 || x >= width) throw RangeError.range(x, 0, width - 1, 'x');
    if (y < 0 || y >= height) throw RangeError.range(y, 0, height - 1, 'y');
    return _values[draw * pixelsPerDraw + y * width + x];
  }

  /// [draw]'s coverage as a tightly packed `width * height` alpha image, which
  /// is what `ComputeTileCpuReference.rasterizeDraw` returns.
  Uint8List rasterizedDraw(int draw) {
    if (draw < 0 || draw >= drawCount) {
      throw RangeError.range(draw, 0, drawCount - 1, 'draw');
    }
    final Uint8List image = Uint8List(pixelsPerDraw);
    final int base = draw * pixelsPerDraw;
    for (var i = 0; i < pixelsPerDraw; i++) {
      final int value = _values[base + i];
      // A value above 255 cannot come out of the shader's quantisation; it can
      // only mean the buffer was read at the wrong offset or was never written.
      // Truncating it silently would hide exactly that.
      if (value > 255) {
        throw StateError(
          'compute coverage element ${base + i} is $value, which is not a '
          'coverage byte; the readback offset or the buffer size is wrong',
        );
      }
      image[i] = value;
    }
    return image;
  }
}

/// Owns and executes the experimental compute-tile Direct3D 12 pipeline.
final class ComputeTileD3d12Executor {
  ComputeTileD3d12Executor(
    this._driver, {
    this.maxCoverageElements = 1 << 26,
  });

  /// The ceiling on `drawCount * width * height`.
  ///
  /// 64 Mi elements is 256 MiB, which is a diagnostic buffer and not a frame
  /// resource - see the layout note in `d3d12_compute_tile_shader.dart`. A plan
  /// above it is refused by name rather than allocating until the driver says
  /// no in a way nobody can attribute.
  final int maxCoverageElements;

  final ComputeTileD3d12Driver _driver;

  int _pipeline = 0;
  bool _disposed = false;

  bool get isInitialized => _pipeline != 0;
  bool get isDisposed => _disposed;

  void initialize() {
    _throwIfDisposed();
    if (isInitialized) return;
    validateD3d12ComputeTileShaderContract();
    _pipeline = _driver.createComputePipeline();
    if (_pipeline == 0) {
      throw StateError('the compute-tile Direct3D 12 pipeline was refused');
    }
  }

  /// Dispatches [plan] and reads its coverage back.
  ///
  /// [sampleGrid] is the supersampling grid, squared, and matches
  /// `ComputeTileCpuReference`'s parameter of the same name so the two can be
  /// compared directly.
  ComputeTileCoverage submit(ComputeTilePlan plan, {int sampleGrid = 4}) {
    _throwIfDisposed();
    if (!isInitialized) {
      throw StateError('initialize the compute-tile executor before submit');
    }
    _validateDispatchable(plan, sampleGrid);

    final int pixelsPerDraw = plan.width * plan.height;
    if (plan.drawCount != 0 && pixelsPerDraw > 0x7FFFFFFF ~/ plan.drawCount) {
      throw ComputeTileD3d12Error(
        ComputeTileD3d12Rejection.integerOverflow,
        'the coverage buffer index for ${plan.drawCount} draws over '
        '${plan.width}x${plan.height} pixels overflows 32-bit indexing',
      );
    }
    final int coverageElements = plan.drawCount * pixelsPerDraw;
    if (coverageElements > maxCoverageElements) {
      throw ComputeTileD3d12Error(
        ComputeTileD3d12Rejection.coverageBudgetExceeded,
        'the plan needs $coverageElements coverage elements, over the '
        'configured budget of $maxCoverageElements',
      );
    }

    final Uint32List rootConstants = _rootConstantsFor(plan, sampleGrid, 0);

    if (coverageElements == 0 || plan.commandCount == 0) {
      // An empty scene is not an error and must not reach the device: a
      // dispatch of zero groups is legal but a zero-byte UAV is not.
      return ComputeTileCoverage._(
        width: plan.width,
        height: plan.height,
        drawCount: plan.drawCount,
        sampleGrid: sampleGrid,
        groupCount: 0,
        values: Uint32List(coverageElements),
      );
    }

    final Uint32List values = _driver.runTilePass(
      pipeline: _pipeline,
      scene: _uploadFor(plan),
      rootConstants: rootConstants,
      coverageElements: coverageElements,
      groupCount: plan.commandCount,
    );
    if (values.length != coverageElements) {
      throw StateError(
        'the compute-tile driver returned ${values.length} coverage elements '
        'where $coverageElements were dispatched',
      );
    }
    return ComputeTileCoverage._(
      width: plan.width,
      height: plan.height,
      drawCount: plan.drawCount,
      sampleGrid: sampleGrid,
      groupCount: plan.commandCount,
      values: values,
    );
  }

  /// Dispatches the coverage of one [draw] into a storage texture, for a
  /// composite pass that follows it in the same command list.
  ///
  /// Returns the pixel rectangle the composite must cover, in device pixels and
  /// clamped to the surface, or null when the draw covers nothing. That
  /// rectangle is load bearing rather than a convenience: **every pixel inside
  /// it was written by this dispatch, and nothing outside it may be read.**
  /// The binning guarantees the first half - a tile that overlaps the draw's
  /// bounds references the draw, and the dispatch writes every pixel of every
  /// referencing tile - and the caller honours the second by drawing exactly
  /// this quad, which is what makes clearing the texture between draws
  /// unnecessary.
  ComputeTileCompositeRect? dispatchDrawCoverage(
    ComputeTilePlan plan, {
    required int draw,
    required int coverageDescriptorIndex,
    int sampleGrid = 4,
  }) {
    _throwIfDisposed();
    if (!isInitialized) {
      throw StateError('initialize the compute-tile executor before dispatch');
    }
    _validateDispatchable(plan, sampleGrid);
    if (draw < 0 || draw >= plan.drawCount) {
      throw RangeError.range(draw, 0, plan.drawCount - 1, 'draw');
    }
    if (plan.commandCount == 0) return null;

    final ComputeTileCompositeRect? rect = _compositeRect(plan, draw);
    if (rect == null) return null;

    _driver.dispatchDrawIntoCoverageTexture(
      pipeline: _pipeline,
      scene: _uploadFor(plan),
      rootConstants: _rootConstantsFor(plan, sampleGrid, draw),
      groupCount: plan.commandCount,
      coverageDescriptorIndex: coverageDescriptorIndex,
    );
    return rect;
  }

  /// The whole-pixel rectangle [draw] can put ink in, clamped to the surface.
  static ComputeTileCompositeRect? _compositeRect(
    ComputeTilePlan plan,
    int draw,
  ) {
    final bounds = plan.drawBounds(draw);
    if (!bounds.left.isFinite ||
        !bounds.top.isFinite ||
        !bounds.right.isFinite ||
        !bounds.bottom.isFinite) {
      return null;
    }
    final int left = bounds.left.floor().clamp(0, plan.width);
    final int top = bounds.top.floor().clamp(0, plan.height);
    final int right = bounds.right.ceil().clamp(0, plan.width);
    final int bottom = bounds.bottom.ceil().clamp(0, plan.height);
    if (right <= left || bottom <= top) return null;
    return ComputeTileCompositeRect._(left, top, right, bottom);
  }

  ComputeTileSceneUpload _uploadFor(ComputeTilePlan plan) =>
      ComputeTileSceneUpload(
        segments: plan.segments,
        draws: plan.draws,
        bounds: plan.bounds,
        bins: plan.bins,
        references: plan.references,
        commands: plan.commands,
        referenceSegments: plan.referenceSegments,
        tileSegments: plan.tileSegments,
        referenceBackdrops: plan.referenceBackdrops,
      );

  static Uint32List _rootConstantsFor(
    ComputeTilePlan plan,
    int sampleGrid,
    int selectedDraw,
  ) {
    final Uint32List constants =
        Uint32List(kD3d12ComputeTileRootConstantCount);
    constants[D3d12ComputeTileRootConstant.width] = plan.width;
    constants[D3d12ComputeTileRootConstant.height] = plan.height;
    constants[D3d12ComputeTileRootConstant.tileSize] = plan.tileSize;
    constants[D3d12ComputeTileRootConstant.columns] = plan.columns;
    constants[D3d12ComputeTileRootConstant.sampleGrid] = sampleGrid;
    constants[D3d12ComputeTileRootConstant.pixelsPerDraw] =
        plan.width * plan.height;
    constants[D3d12ComputeTileRootConstant.commandCount] = plan.commandCount;
    constants[D3d12ComputeTileRootConstant.drawCount] = plan.drawCount;
    constants[D3d12ComputeTileRootConstant.selectedDraw] = selectedDraw;
    return constants;
  }

  void _validateDispatchable(ComputeTilePlan plan, int sampleGrid) {
    if (sampleGrid <= 0 || sampleGrid > 16) {
      throw ComputeTileD3d12Error(
        ComputeTileD3d12Rejection.sampleGridOutOfRange,
        'sampleGrid $sampleGrid is outside 1..16, the range the CPU reference '
        'accepts; a dispatch outside it could not be compared with anything',
      );
    }
    if (plan.tileSize > kD3d12ComputeTileMaxTileSize) {
      throw ComputeTileD3d12Error(
        ComputeTileD3d12Rejection.tileSizeExceedsThreadGroup,
        'the plan tiles at ${plan.tileSize} pixels and one thread group covers '
        '$kD3d12ComputeTileMaxTileSize; rebuild the plan with a smaller tile '
        'or dispatch several groups per tile',
      );
    }
  }

  void dispose() {
    if (_disposed) return;
    if (_pipeline != 0) _driver.disposeComputePipeline(_pipeline);
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
      throw StateError('the compute-tile Direct3D 12 executor is disposed');
    }
  }
}
