/// Backend-neutral half of the chained coverage stage.
///
/// The sizes, the refusals and the root-constant layout live here for the
/// reason `d3d12_compute_flatten_executor.dart` states: they are policy over
/// numbers, and policy that lives in an FFI file is policy no test can reach
/// without a GPU. Nothing here names Direct3D.
///
/// ## There is no standalone driver interface, and that is the point
///
/// The other three stages each have one, because each was proved on its own
/// against a CPU oracle before anything consumed it. This stage already has a
/// proved standalone form - `ComputeTileD3d12Executor`, which uploads a whole
/// `ComputeTilePlan` and reads coverage back - and duplicating it would create
/// a second unchained coverage path with the same oracle and no consumer.
///
/// What did not exist is coverage that reads the *pipeline's* output instead of
/// the CPU planner's, and that shape is only meaningful inside a chain: its
/// five binned inputs are another pass's buffers, which is not something a
/// standalone submission can be handed. So this file describes the dispatch and
/// [ComputeRasterPipeline] owns the submission, and the parity test compares
/// the two coverage paths against each other and against the CPU reference.
///
/// There is no scene type here either, and for a stronger reason than economy:
/// the coverage kernel indexes `segments` through the very `tileSegments` the
/// segment stage built out of that same array, so the two stages must be handed
/// the *identical* `ComputeSegmentScene`. A second type would make binding a
/// different-but-similar array a compiling mistake that reads the wrong edges
/// instead of failing.
library;

import 'dart:typed_data';

import 'd3d12_compute_coverage_shader.dart';

/// Why a scene's coverage could not be rasterised in a chained submission.
enum ComputeCoverageRejection {
  /// The plan's tile edge exceeds the thread group.
  tileSizeExceedsThreadGroup,

  /// The supersampling grid is outside the range the CPU oracle accepts, so a
  /// dispatch could not be compared with anything.
  sampleGridOutOfRange,

  /// The coverage buffer this scene would need exceeds the configured budget.
  coverageBudgetExceeded,

  /// More command slots than one dispatch dimension can address.
  commandSlotsExceedDispatch,

  /// A size or an index overflows 32-bit arithmetic.
  integerOverflow,
}

final class ComputeCoverageError extends StateError {
  ComputeCoverageError(this.rejection, String detail)
      : super('${rejection.name}: $detail');

  final ComputeCoverageRejection rejection;
}

/// One dispatch of the chained coverage kernel, fully sized.
///
/// Every field is a CPU-known number, which is what makes the stage chainable:
/// a submission that reads nothing back can still size its output buffer and
/// its dispatch, because the surface, the tiling and the draw count all come
/// from the caller rather than from a previous stage's counters.
final class ComputeCoverageDispatch {
  const ComputeCoverageDispatch._({
    required this.width,
    required this.height,
    required this.tileSize,
    required this.columns,
    required this.drawCount,
    required this.sampleGrid,
    required this.commandSlots,
    required this.referenceSlots,
    required this.tileSegmentSlots,
    required this.pixelsPerDraw,
    required this.coverageElements,
  });

  final int width;
  final int height;
  final int tileSize;
  final int columns;
  final int drawCount;
  final int sampleGrid;

  /// Thread groups dispatched: one per command slot.
  ///
  /// The number of *occupied* tiles is the coarse stage's occupancy total, and
  /// a chained submission cannot read it. A caller inside the chain passes the
  /// tile count; the slots past the real command count are zero and write
  /// nothing, which `d3d12_compute_coverage_shader.dart` argues and the parity
  /// test measures by running both sizes.
  final int commandSlots;

  /// How many reference slots the borrowed per-reference buffers hold - the
  /// coarse stage's reference budget, not its reference count.
  ///
  /// The kernel drops a reference at or past this, and the reason is the one
  /// `d3d12_compute_coverage_shader.dart` argues at length: every buffer in the
  /// chain is a root descriptor, a root descriptor carries no size, and an
  /// overflowed budget therefore turns an out-of-range index into a real memory
  /// access rather than a discarded write.
  final int referenceSlots;

  /// How many entries the borrowed tile-segment buffer holds - the segment
  /// stage's budget, bounding the same way.
  final int tileSegmentSlots;

  final int pixelsPerDraw;

  /// `drawCount * pixelsPerDraw` `uint`s: the buffer the kernel writes.
  final int coverageElements;

  /// Sizes a dispatch, or refuses by name.
  ///
  /// [maxCoverageElements] is the ceiling on the output buffer. The default is
  /// `ComputeTileD3d12Executor.maxCoverageElements`, for the same reason: this
  /// layout is one `uint` per pixel *per draw*, which is a diagnostic buffer
  /// and not a frame resource, and a scene that would allocate half a gigabyte
  /// is refused by name rather than by the driver in a way nobody can
  /// attribute.
  factory ComputeCoverageDispatch.of({
    required int width,
    required int height,
    required int tileSize,
    required int columns,
    required int drawCount,
    required int commandSlots,
    required int referenceSlots,
    required int tileSegmentSlots,
    int sampleGrid = 4,
    int maxCoverageElements = 1 << 26,
  }) {
    if (sampleGrid <= 0 || sampleGrid > 16) {
      throw ComputeCoverageError(
        ComputeCoverageRejection.sampleGridOutOfRange,
        'sampleGrid $sampleGrid is outside 1..16, the range the CPU reference '
        'accepts; a dispatch outside it could not be compared with anything',
      );
    }
    if (tileSize <= 0 || tileSize > kComputeCoverageMaxTileSize) {
      throw ComputeCoverageError(
        ComputeCoverageRejection.tileSizeExceedsThreadGroup,
        'the scene tiles at $tileSize pixels and one thread group covers '
        '$kComputeCoverageMaxTileSize',
      );
    }
    if (commandSlots < 0 || commandSlots > kComputeCoverageMaxDispatchGroups) {
      throw ComputeCoverageError(
        ComputeCoverageRejection.commandSlotsExceedDispatch,
        'the dispatch covers $commandSlots command slots and one dimension '
        'addresses $kComputeCoverageMaxDispatchGroups',
      );
    }
    if (width <= 0 || height <= 0 || drawCount <= 0 || columns <= 0) {
      throw ArgumentError(
        'a coverage dispatch needs a surface, a column count and a draw',
      );
    }
    if (referenceSlots <= 0 || tileSegmentSlots <= 0) {
      throw ArgumentError(
        'a coverage dispatch needs the budgets of the two buffers it borrows; '
        'zero would drop every reference and rasterise an empty surface',
      );
    }
    if (width > 0x7FFFFFFF ~/ height) {
      throw ComputeCoverageError(
        ComputeCoverageRejection.integerOverflow,
        'a ${width}x$height surface overflows 32-bit pixel indexing',
      );
    }
    final int pixelsPerDraw = width * height;
    if (pixelsPerDraw > 0x7FFFFFFF ~/ drawCount) {
      throw ComputeCoverageError(
        ComputeCoverageRejection.integerOverflow,
        'the coverage buffer index for $drawCount draws over ${width}x$height '
        'pixels overflows 32-bit indexing',
      );
    }
    final int coverageElements = drawCount * pixelsPerDraw;
    if (coverageElements > maxCoverageElements) {
      throw ComputeCoverageError(
        ComputeCoverageRejection.coverageBudgetExceeded,
        'the scene needs $coverageElements coverage elements, over the '
        'configured budget of $maxCoverageElements',
      );
    }
    return ComputeCoverageDispatch._(
      width: width,
      height: height,
      tileSize: tileSize,
      columns: columns,
      drawCount: drawCount,
      sampleGrid: sampleGrid,
      commandSlots: commandSlots,
      referenceSlots: referenceSlots,
      tileSegmentSlots: tileSegmentSlots,
      pixelsPerDraw: pixelsPerDraw,
      coverageElements: coverageElements,
    );
  }

  /// The root constants, in the layout [ComputeCoverageRootConstant] names.
  ///
  /// `uCommandCount` is [commandSlots] and not the occupied-tile count: the
  /// kernel's first guard is `command >= uCommandCount`, and setting it below
  /// the dispatch size would retire groups the caller sized deliberately while
  /// setting it above would read past the command buffer.
  Uint32List rootConstants() {
    final Uint32List constants = Uint32List(kComputeCoverageRootConstantCount);
    constants[ComputeCoverageRootConstant.width] = width;
    constants[ComputeCoverageRootConstant.height] = height;
    constants[ComputeCoverageRootConstant.tileSize] = tileSize;
    constants[ComputeCoverageRootConstant.columns] = columns;
    constants[ComputeCoverageRootConstant.sampleGrid] = sampleGrid;
    constants[ComputeCoverageRootConstant.pixelsPerDraw] = pixelsPerDraw;
    constants[ComputeCoverageRootConstant.commandCount] = commandSlots;
    constants[ComputeCoverageRootConstant.drawCount] = drawCount;
    constants[ComputeCoverageRootConstant.selectedDraw] = 0;
    constants[ComputeCoverageRootConstant.referenceSlots] = referenceSlots;
    constants[ComputeCoverageRootConstant.tileSegmentSlots] = tileSegmentSlots;
    return constants;
  }
}

/// What a caller asks for when it wants the coverage stage in the chain.
///
/// A value type with one field rather than a bare `int sampleGrid` with a
/// sentinel: the stage is optional, and "off" has to be distinguishable from
/// "on with the default grid" without anyone remembering which integer means
/// which.
final class ComputeCoverageRequest {
  const ComputeCoverageRequest({this.sampleGrid = 4});

  /// The supersampling grid, squared. Matches `ComputeTileCpuReference`'s
  /// parameter of the same name so the two can be compared directly.
  final int sampleGrid;
}

/// Groups one dispatch dimension can address, restated here so a refusal names
/// this stage rather than a constant from another one.
const int kComputeCoverageMaxDispatchGroups = 65535;

/// One chained dispatch's coverage, in the layout the CPU oracle rasterises to.
///
/// The same layout `ComputeTileCoverage` carries, and deliberately a separate
/// type: that one is produced by a submission that uploaded a whole
/// `ComputeTilePlan`, this one by a submission that produced six of the plan's
/// nine arrays itself. A test that compares them is comparing two routes, and
/// two routes returning the same type would make it easy to compare a value
/// with itself.
final class ComputeCoverageResult {
  const ComputeCoverageResult({
    required this.width,
    required this.height,
    required this.drawCount,
    required this.sampleGrid,
    required this.commandSlots,
    required Uint32List values,
  }) : _values = values;

  final int width;
  final int height;
  final int drawCount;
  final int sampleGrid;

  /// Thread groups the submission dispatched.
  final int commandSlots;

  final Uint32List _values;

  int get pixelsPerDraw => width * height;

  /// The raw buffer, for a byte-for-byte comparison against another run.
  Uint32List get values => _values;

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
      // Above 255 cannot come out of the kernel's quantisation. It can only
      // mean the buffer was read at the wrong offset, was never written, or -
      // the failure this stage is uniquely exposed to - that an aliased slot
      // was bound to the wrong producer's buffer. Truncating would hide all
      // three.
      if (value > 255) {
        throw StateError(
          'chained coverage element ${base + i} is $value, which is not a '
          'coverage byte; a readback offset or an aliased binding is wrong',
        );
      }
      image[i] = value;
    }
    return image;
  }
}
