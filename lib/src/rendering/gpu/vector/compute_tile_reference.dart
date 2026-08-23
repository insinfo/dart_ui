/// Slow CPU oracle for [ComputeTilePlan].
///
/// This is intentionally independent of the production scanline rasterizer.
/// It evaluates the encoded float32 segments directly with ray crossings and
/// fixed-grid supersampling. Tests use it to prove that binning never omits a
/// draw from a tile containing non-zero reference coverage. It is not intended
/// for frame rendering and is not evidence that a GPU compute backend exists.
library;

import 'dart:typed_data';

import '../../path/fill_rule.dart';
import 'compute_tile_scene.dart';

final class ComputeTileCpuReference {
  const ComputeTileCpuReference(this.plan);

  final ComputeTilePlan plan;

  /// Whether one target-space point is inside [draw].
  bool contains(int draw, double x, double y) {
    final bounds = plan.drawBounds(draw);
    if (x < bounds.left ||
        x >= bounds.right ||
        y < bounds.top ||
        y >= bounds.bottom) {
      return false;
    }
    var winding = 0;
    var parity = false;
    final int first = plan.drawFirstSegment(draw);
    final int end = first + plan.drawSegmentCount(draw);
    for (var segment = first; segment < end; segment++) {
      final double x0 = plan.segmentX0(segment);
      final double y0 = plan.segmentY0(segment);
      final double x1 = plan.segmentX1(segment);
      final double y1 = plan.segmentY1(segment);
      final bool upward = y0 <= y && y1 > y;
      final bool downward = y1 <= y && y0 > y;
      if (!upward && !downward) continue;
      final double crossingX = x0 + (y - y0) * (x1 - x0) / (y1 - y0);
      if (crossingX <= x) continue;
      parity = !parity;
      winding += upward ? 1 : -1;
    }
    return plan.drawFillRule(draw) == FillRule.evenOdd ? parity : winding != 0;
  }

  /// Reference 0..255 coverage for one pixel using [sampleGrid] squared
  /// regularly spaced samples at subpixel centres.
  int coverageAtPixel(
    int draw,
    int pixelX,
    int pixelY, {
    int sampleGrid = 4,
  }) {
    _validateSampleGrid(sampleGrid);
    var covered = 0;
    for (var sampleY = 0; sampleY < sampleGrid; sampleY++) {
      final double y = pixelY + (sampleY + 0.5) / sampleGrid;
      for (var sampleX = 0; sampleX < sampleGrid; sampleX++) {
        final double x = pixelX + (sampleX + 0.5) / sampleGrid;
        if (contains(draw, x, y)) covered++;
      }
    }
    final int samples = sampleGrid * sampleGrid;
    return (covered * 255 + samples ~/ 2) ~/ samples;
  }

  /// Whether one target-space point is inside [draw], using only the segments
  /// binned into [reference] plus that reference's backdrop.
  ///
  /// The bin-based twin of [contains], and the reason it exists is that the two
  /// **must** agree: [contains] is the definition, and this is the shape the
  /// GPU can afford. `ComputeTileScene._binSegments` argues that the
  /// decomposition is exact; [rasterizeDrawUsingSegmentBins] turns that
  /// argument into a measurement over every sample of a scene.
  ///
  /// [reference] must be the index of the ([draw], tile) pair whose tile
  /// contains the point. Passing another one is meaningless rather than
  /// merely wrong, so it is checked.
  bool containsUsingSegmentBins(
    int draw,
    int reference,
    double x,
    double y,
  ) {
    final bounds = plan.drawBounds(draw);
    if (x < bounds.left ||
        x >= bounds.right ||
        y < bounds.top ||
        y >= bounds.bottom) {
      return false;
    }
    var winding = plan.referenceBackdropWinding(reference);
    var parity = plan.referenceBackdropParity(reference) != 0;
    final int count = plan.referenceSegmentCount(reference);
    for (var index = 0; index < count; index++) {
      final int segment = plan.referenceSegment(reference, index);
      final double x0 = plan.segmentX0(segment);
      final double y0 = plan.segmentY0(segment);
      final double x1 = plan.segmentX1(segment);
      final double y1 = plan.segmentY1(segment);
      final bool upward = y0 <= y && y1 > y;
      final bool downward = y1 <= y && y0 > y;
      if (!upward && !downward) continue;
      final double crossingX = x0 + (y - y0) * (x1 - x0) / (y1 - y0);
      if (crossingX <= x) continue;
      parity = !parity;
      winding += upward ? 1 : -1;
    }
    return plan.drawFillRule(draw) == FillRule.evenOdd ? parity : winding != 0;
  }

  /// Rasterizes one draw the way a binned fine raster would.
  ///
  /// Byte for byte identical to [rasterizeDraw] on every scene the binning
  /// accepts - that equality is the whole point, and asserting it is cheaper
  /// and far more precise than inspecting a picture.
  ///
  /// Returns null when [draw] is absent from a tile it covers, which would mean
  /// the *draw* binning is broken rather than the segment binning; that case is
  /// reported by [validateBins] and must not be silently rasterised around.
  Uint8List? rasterizeDrawUsingSegmentBins(int draw, {int sampleGrid = 4}) {
    _validateSampleGrid(sampleGrid);
    final Uint8List result = Uint8List(plan.width * plan.height);
    final bounds = plan.drawBounds(draw);
    final int left = bounds.left.floor().clamp(0, plan.width);
    final int top = bounds.top.floor().clamp(0, plan.height);
    final int right = bounds.right.ceil().clamp(0, plan.width);
    final int bottom = bounds.bottom.ceil().clamp(0, plan.height);
    final int samples = sampleGrid * sampleGrid;
    for (var pixelY = top; pixelY < bottom; pixelY++) {
      for (var pixelX = left; pixelX < right; pixelX++) {
        final int tile =
            (pixelY ~/ plan.tileSize) * plan.columns + pixelX ~/ plan.tileSize;
        final int? reference = _referenceOf(tile, draw);
        if (reference == null) return null;
        var covered = 0;
        for (var sampleY = 0; sampleY < sampleGrid; sampleY++) {
          final double y = pixelY + (sampleY + 0.5) / sampleGrid;
          for (var sampleX = 0; sampleX < sampleGrid; sampleX++) {
            final double x = pixelX + (sampleX + 0.5) / sampleGrid;
            if (containsUsingSegmentBins(draw, reference, x, y)) covered++;
          }
        }
        result[pixelY * plan.width + pixelX] =
            (covered * 255 + samples ~/ 2) ~/ samples;
      }
    }
    return result;
  }

  /// The reference index of ([tile], [draw]), or null when the tile does not
  /// name that draw.
  int? _referenceOf(int tile, int draw) {
    final int count = plan.tileReferenceCount(tile);
    for (var index = 0; index < count; index++) {
      if (plan.tileDraw(tile, index) == draw) {
        return plan.tileFirstReference(tile) + index;
      }
    }
    return null;
  }

  /// Rasterizes one draw to a tightly packed `width * height` alpha image.
  Uint8List rasterizeDraw(int draw, {int sampleGrid = 4}) {
    _validateSampleGrid(sampleGrid);
    final Uint8List result = Uint8List(plan.width * plan.height);
    final bounds = plan.drawBounds(draw);
    final int left = bounds.left.floor().clamp(0, plan.width);
    final int top = bounds.top.floor().clamp(0, plan.height);
    final int right = bounds.right.ceil().clamp(0, plan.width);
    final int bottom = bounds.bottom.ceil().clamp(0, plan.height);
    for (var y = top; y < bottom; y++) {
      for (var x = left; x < right; x++) {
        result[y * plan.width + x] =
            coverageAtPixel(draw, x, y, sampleGrid: sampleGrid);
      }
    }
    return result;
  }

  /// Returns contract violations found by independently rasterizing all draws.
  ///
  /// Besides missing coverage, this checks bounds, draw ordering inside each
  /// bin, command/header agreement, and duplicate draw references.
  List<String> validateBins({int sampleGrid = 4}) {
    _validateSampleGrid(sampleGrid);
    final List<String> errors = <String>[];
    for (var tile = 0; tile < plan.tileCount; tile++) {
      var previous = -1;
      final Set<int> seen = <int>{};
      for (var reference = 0;
          reference < plan.tileReferenceCount(tile);
          reference++) {
        final int draw = plan.tileDraw(tile, reference);
        if (draw < 0 || draw >= plan.drawCount) {
          errors.add('tile $tile references invalid draw $draw');
          continue;
        }
        if (draw <= previous) {
          errors.add('tile $tile draw references are not strictly ordered');
        }
        if (!seen.add(draw)) {
          errors.add('tile $tile references draw $draw more than once');
        }
        if (!plan.tileBounds(tile).intersects(plan.drawBounds(draw))) {
          errors.add('tile $tile references non-intersecting draw $draw');
        }
        previous = draw;
      }
    }
    var expectedCommand = 0;
    for (var command = 0; command < plan.commandCount; command++) {
      final int tile = plan.commandTile(command);
      while (expectedCommand < plan.tileCount &&
          plan.tileReferenceCount(expectedCommand) == 0) {
        expectedCommand++;
      }
      if (tile != expectedCommand) {
        errors.add(
          'command $command names tile $tile, expected occupied tile '
          '$expectedCommand',
        );
      }
      if (plan.commandFirstReference(command) !=
              plan.tileFirstReference(tile) ||
          plan.commandReferenceCount(command) !=
              plan.tileReferenceCount(tile) ||
          plan.tileReferenceCount(tile) == 0) {
        errors.add('command $command disagrees with tile $tile header');
      }
      expectedCommand++;
    }
    while (expectedCommand < plan.tileCount &&
        plan.tileReferenceCount(expectedCommand) == 0) {
      expectedCommand++;
    }
    if (expectedCommand != plan.tileCount) {
      errors.add('occupied tile $expectedCommand has no command');
    }
    for (var draw = 0; draw < plan.drawCount; draw++) {
      final Uint8List coverage = rasterizeDraw(draw, sampleGrid: sampleGrid);
      for (var y = 0; y < plan.height; y++) {
        for (var x = 0; x < plan.width; x++) {
          if (coverage[y * plan.width + x] == 0) continue;
          final int tile =
              (y ~/ plan.tileSize) * plan.columns + x ~/ plan.tileSize;
          var found = false;
          for (var reference = 0;
              reference < plan.tileReferenceCount(tile);
              reference++) {
            if (plan.tileDraw(tile, reference) == draw) {
              found = true;
              break;
            }
          }
          if (!found) {
            errors.add(
              'draw $draw covers pixel ($x, $y) but is absent from tile $tile',
            );
          }
        }
      }
    }
    return errors;
  }

  static void _validateSampleGrid(int sampleGrid) {
    if (sampleGrid <= 0 || sampleGrid > 16) {
      throw RangeError.range(sampleGrid, 1, 16, 'sampleGrid');
    }
  }
}
