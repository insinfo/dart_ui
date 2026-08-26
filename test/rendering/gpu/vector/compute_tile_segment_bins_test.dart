/// The per-tile segment binning, proved against the brute-force oracle.
///
/// Binning is the one optimisation in this pipeline that can be *silently*
/// wrong. Dropping a segment a tile does not touch is obviously safe; the
/// dangerous half is that a segment lying entirely to a tile's right still
/// contributes to the winding of every sample in it, so culling by intersection
/// alone under-fills large shapes - and under-fills them in a way that still
/// looks like a shape. `ComputeTileScene._binSegments` argues the decomposition
/// is exact. This file measures it.
///
/// Every scene below is rasterised twice: once by `contains`, which loops every
/// segment of the draw, and once by `containsUsingSegmentBins`, which starts
/// from the tile's backdrop and loops only the tile's own list. **They must
/// agree byte for byte.** Nothing here needs a GPU, so it is also the part of
/// approach D that a Linux or macOS runner still checks.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/transform2d.dart';
import 'package:dart_ui/src/rendering/gpu/vector/compute_tile_reference.dart';
import 'package:dart_ui/src/rendering/gpu/vector/compute_tile_scene.dart';
import 'package:dart_ui/src/rendering/path/fill_rule.dart';
import 'package:test/test.dart';

void main() {
  group('binned coverage equals brute-force coverage', () {
    test('a rectangle much wider than a tile', () {
      // The scene the whole backdrop mechanism exists for: the interior tiles
      // of a wide shape contain no segment at all, and are filled *only* by the
      // winding the right-hand edge contributes. Cull without a backdrop and
      // this rectangle comes out hollow.
      final ComputeTilePlan plan = _planOf(
        _rect(3, 5, 122, 59),
        width: 128,
        height: 64,
      );
      final _Interior interior = _interiorTile(plan, 0);
      expect(interior.segmentCount, 0,
          reason: 'the scene no longer has an interior tile with no segments, '
              'so it stops testing the backdrop');
      expect(interior.winding.abs(), 1,
          reason: 'an interior tile of a simple rectangle is enclosed by '
              'exactly one edge to its right');
      _expectBinnedParity(plan);
    });

    test('a rectangle with a hole, opposite winding', () {
      // Two contours wound against each other, so an interior tile's backdrop
      // is the *sum* of two edges and lands on zero inside the hole. A backdrop
      // that only counted crossings would fill the hole.
      final PathBuilder builder = PathBuilder();
      _addRect(builder, const Rect.fromLTRB(4, 4, 124, 60), clockwise: true);
      _addRect(builder, const Rect.fromLTRB(30, 18, 98, 46), clockwise: false);
      _expectBinnedParity(_planOf(builder.build(), width: 128, height: 64));
    });

    test('the same geometry under even-odd', () {
      // Even-odd reads the parity of the *count*, which a signed backdrop of
      // zero cannot express - which is why the backdrop carries two numbers.
      final PathBuilder builder = PathBuilder();
      _addRect(builder, const Rect.fromLTRB(4, 4, 124, 60), clockwise: true);
      _addRect(builder, const Rect.fromLTRB(30, 18, 98, 46), clockwise: true);
      final Path path = builder.build();
      _expectBinnedParity(
          _planOf(path, width: 128, height: 64, rule: FillRule.evenOdd));
      _expectBinnedParity(_planOf(path, width: 128, height: 64));
    });

    test('edges that stop inside a tile row', () {
      // The refinement that makes the decomposition exact rather than
      // approximate: a segment to a tile's right that spans only part of the
      // tile's height must be *binned*, not folded into the constant backdrop.
      // This staircase is built so that several segments end mid-row.
      final PathBuilder builder = PathBuilder()..moveTo(6, 6);
      for (var step = 0; step < 6; step++) {
        builder
          ..lineTo(6 + step * 18.0, 6 + step * 9.0)
          ..lineTo(6 + step * 18.0, 6 + step * 9.0 + 7.0);
      }
      builder
        ..lineTo(120, 58)
        ..lineTo(6, 58)
        ..close();
      _expectBinnedParity(_planOf(builder.build(), width: 128, height: 64));
    });

    test('a flattened curve, transformed', () {
      // Hundreds of short segments at arbitrary angles and a transform that
      // makes none of the coordinates land on a tile boundary.
      final PathBuilder builder = PathBuilder()
        ..moveTo(64, 8)
        ..cubicTo(112, 8, 124, 44, 100, 58)
        ..cubicTo(72, 66, 24, 60, 10, 40)
        ..cubicTo(2, 26, 20, 6, 64, 8)
        ..close();
      _expectBinnedParity(
        _planOf(
          builder.build(),
          width: 128,
          height: 64,
          transform: const Transform2D.translation(0.37, -0.21),
        ),
      );
    });

    test('a shape clipped so its segments run past the tile grid', () {
      // The draw's tile range stops at the clip, but the geometry does not, so
      // segments exist to the right of *every* tile the draw owns. They must
      // still reach the backdrop, or the visible part is unfilled.
      _expectBinnedParity(
        _planOf(
          _rect(-40, -20, 200, 100),
          width: 128,
          height: 64,
          clip: const Rect.fromLTRB(16, 8, 96, 56),
        ),
      );
    });

    test('several draws sharing tiles', () {
      final ComputeTileScene scene = ComputeTileScene();
      const Rect clip = Rect.fromLTRB(0, 0, 128, 64);
      scene
        ..appendPath(_rect(2, 2, 90, 40),
            clip: clip, materialIndex: 0, fillRule: FillRule.nonZero)
        ..appendPath(_rect(40, 20, 126, 62),
            clip: clip, materialIndex: 1, fillRule: FillRule.evenOdd)
        ..appendPath(_rect(60, 4, 70, 60),
            clip: clip, materialIndex: 2, fillRule: FillRule.nonZero);
      final ComputeTilePlan plan =
          scene.build(width: 128, height: 64, tileSize: 16);
      expect(plan.drawCount, 3);
      _expectBinnedParity(plan);
    });

    test('a tile size that does not divide the surface', () {
      _expectBinnedParity(
        _planOf(_rect(2.5, 3.5, 47.5, 33.5),
            width: 50, height: 34, tileSize: 16),
      );
    });
  });

  group('what binning buys, and what it costs', () {
    test('an interior-heavy shape visits far fewer segments per tile', () {
      final ComputeTilePlan plan = _planOf(
        _rect(3, 5, 122, 59),
        width: 128,
        height: 64,
      );
      // Without binning a fine raster loops every segment of the draw for every
      // sample. With it, the mean is what actually gets looped.
      expect(plan.meanSegmentsPerReference, lessThan(plan.segmentCount / 2));
      expect(plan.metrics.tileSegmentReferenceCount,
          plan.tileSegmentReferenceCount);
    });

    test('the arrays are exact-sized, immutable and self-consistent', () {
      final ComputeTilePlan plan =
          _planOf(_rect(4, 4, 60, 60), width: 64, height: 64);
      expect(plan.referenceSegments.length,
          plan.referenceCount * kComputeTileReferenceSegmentStride);
      expect(plan.referenceBackdrops.length,
          plan.referenceCount * kComputeTileBackdropStride);
      expect(() => plan.tileSegments[0] = 0, throwsUnsupportedError);
      expect(() => plan.referenceBackdrops[0] = 0, throwsUnsupportedError);

      // The per-reference ranges tile the segment array exactly once, in order.
      var expectedFirst = 0;
      for (var r = 0; r < plan.referenceCount; r++) {
        expect(plan.referenceFirstSegment(r), expectedFirst);
        expectedFirst += plan.referenceSegmentCount(r);
        for (var i = 0; i < plan.referenceSegmentCount(r); i++) {
          expect(plan.referenceSegment(r, i), lessThan(plan.segmentCount));
        }
      }
      expect(expectedFirst, plan.tileSegmentReferenceCount);
      expect(
          plan.metrics.uploadBytes,
          plan.segments.lengthInBytes +
              plan.draws.lengthInBytes +
              plan.bounds.lengthInBytes +
              plan.bins.lengthInBytes +
              plan.references.lengthInBytes +
              plan.commands.lengthInBytes +
              plan.referenceSegments.lengthInBytes +
              plan.tileSegments.lengthInBytes +
              plan.referenceBackdrops.lengthInBytes);
    });

    test('the per-tile segment budget is refused by name', () {
      final ComputeTileScene scene = ComputeTileScene();
      scene.appendPath(
        _rect(3, 5, 122, 59),
        clip: const Rect.fromLTRB(0, 0, 128, 64),
        materialIndex: 0,
        fillRule: FillRule.nonZero,
      );
      expect(
        () => scene.build(
          width: 128,
          height: 64,
          tileSize: 16,
          maxTileSegmentReferences: 1,
        ),
        throwsA(isA<ComputeTilePlanError>().having(
          (ComputeTilePlanError error) => error.rejection,
          'rejection',
          ComputeTileRejection.tileSegmentLimitExceeded,
        )),
      );
    });
  });

  group('the clip rounds outward to whole pixels, like ScanlineFiller', () {
    test('a fractional clip is expanded, not applied exactly', () {
      // The framework's clip semantics, adopted rather than reinvented: every
      // other route takes its clip through `ScanlineFiller`, which expands it
      // outward to whole pixels. A route that clipped exactly would disagree
      // with all of them on every fractional edge.
      final ComputeTilePlan rounded = _planOf(
        _rect(0, 0, 64, 64),
        width: 64,
        height: 64,
        clip: const Rect.fromLTRB(10.5, 12.25, 49.5, 47.75),
      );
      expect(rounded.drawBounds(0), const Rect.fromLTRB(10, 12, 50, 48));

      final ComputeTilePlan exact = _planOf(
        _rect(0, 0, 64, 64),
        width: 64,
        height: 64,
        clip: const Rect.fromLTRB(10.5, 12.25, 49.5, 47.75),
        clipRounding: ComputeTileClipRounding.exact,
      );
      expect(
          exact.drawBounds(0), const Rect.fromLTRB(10.5, 12.25, 49.5, 47.75));
    });

    test('a whole-pixel clip is unchanged by the rounding', () {
      final ComputeTilePlan plan = _planOf(
        _rect(0, 0, 64, 64),
        width: 64,
        height: 64,
        clip: const Rect.fromLTRB(8, 8, 40, 40),
      );
      expect(plan.drawBounds(0), const Rect.fromLTRB(8, 8, 40, 40));
    });
  });
}

// ---------------------------------------------------------------------

void _expectBinnedParity(ComputeTilePlan plan, {int sampleGrid = 4}) {
  final ComputeTileCpuReference reference = ComputeTileCpuReference(plan);
  expect(reference.validateBins(sampleGrid: sampleGrid), isEmpty);
  var inked = 0;
  for (var draw = 0; draw < plan.drawCount; draw++) {
    final Uint8List brute =
        reference.rasterizeDraw(draw, sampleGrid: sampleGrid);
    final Uint8List? binned =
        reference.rasterizeDrawUsingSegmentBins(draw, sampleGrid: sampleGrid);
    expect(binned, isNotNull,
        reason: 'draw $draw covers a tile that does not reference it');
    var differing = 0;
    var maxDeviation = 0;
    var first = '';
    for (var i = 0; i < brute.length; i++) {
      if (brute[i] != 0) inked++;
      final int deviation = (brute[i] - binned![i]).abs();
      if (deviation == 0) continue;
      differing++;
      if (deviation > maxDeviation) maxDeviation = deviation;
      if (first.isEmpty) {
        first = 'first at (${i % plan.width}, ${i ~/ plan.width}): '
            'brute ${brute[i]}, binned ${binned[i]}';
      }
    }
    expect(
      differing,
      0,
      reason: 'draw $draw: binning changed $differing pixels by up to '
          '$maxDeviation levels. Binning is not an approximation - a '
          'difference here is a segment that was culled from a tile it still '
          'contributes winding to. $first',
    );
  }
  expect(inked, greaterThan(0),
      reason: 'the scene covers nothing, so comparing it proves nothing');
}

final class _Interior {
  const _Interior(this.segmentCount, this.winding);

  final int segmentCount;
  final int winding;
}

/// The reference for a tile of [draw] that is strictly inside the shape, so its
/// coverage comes entirely from the backdrop.
_Interior _interiorTile(ComputeTilePlan plan, int draw) {
  var best = const _Interior(-1, 0);
  for (var tile = 0; tile < plan.tileCount; tile++) {
    for (var index = 0; index < plan.tileReferenceCount(tile); index++) {
      if (plan.tileDraw(tile, index) != draw) continue;
      final int reference = plan.tileFirstReference(tile) + index;
      final int count = plan.referenceSegmentCount(reference);
      final int winding = plan.referenceBackdropWinding(reference);
      if (count == 0 && winding != 0) return _Interior(count, winding);
      if (best.segmentCount < 0) best = _Interior(count, winding);
    }
  }
  return best;
}

Path _rect(double left, double top, double right, double bottom) {
  final PathBuilder builder = PathBuilder();
  _addRect(builder, Rect.fromLTRB(left, top, right, bottom), clockwise: true);
  return builder.build();
}

void _addRect(PathBuilder builder, Rect rect, {required bool clockwise}) {
  builder.moveTo(rect.left, rect.top);
  if (clockwise) {
    builder
      ..lineTo(rect.right, rect.top)
      ..lineTo(rect.right, rect.bottom)
      ..lineTo(rect.left, rect.bottom);
  } else {
    builder
      ..lineTo(rect.left, rect.bottom)
      ..lineTo(rect.right, rect.bottom)
      ..lineTo(rect.right, rect.top);
  }
  builder.close();
}

ComputeTilePlan _planOf(
  Path path, {
  required int width,
  required int height,
  int tileSize = 16,
  FillRule rule = FillRule.nonZero,
  Rect? clip,
  Transform2D transform = Transform2D.identity,
  ComputeTileClipRounding clipRounding =
      ComputeTileClipRounding.outwardWholePixel,
}) {
  final ComputeTileScene scene = ComputeTileScene();
  scene.appendPath(
    path,
    clip: clip ?? Rect.fromLTRB(0, 0, width.toDouble(), height.toDouble()),
    materialIndex: 0,
    fillRule: rule,
    transform: transform,
    clipRounding: clipRounding,
  );
  return scene.build(
    width: width,
    height: height,
    tileSize: math.min(tileSize, 16),
  );
}
