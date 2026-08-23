/// The native strip rasteriser against the one the framework already trusts.
///
/// `NativeStripRasterizer` computes coverage from geometry directly, where
/// `SparseStripGenerator` re-encodes what `ScanlineFiller` produced. They must
/// agree, and this compares them by reconstructing a dense coverage bitmap
/// from each and diffing every pixel - because a strip representation can be
/// structured differently (different strip boundaries, different fill runs)
/// and still mean exactly the same picture. Comparing structures would fail on
/// differences that are not differences.
///
/// The scenes are adversarial on purpose. The parts of this algorithm that are
/// easy to get subtly wrong are: a vertical line sitting exactly on a pixel
/// boundary (`0 * inf` is NaN, and the tie has to break left), the winding bit
/// on a line entering a tile row, holes wound against their outer contour,
/// even-odd folding, and geometry larger than the clip.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/transform2d.dart';
import 'package:dart_ui/src/rendering/gpu/vector/native_strip_rasterizer.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strips.dart';
import 'package:dart_ui/src/rendering/path/fill_rule.dart';
import 'package:test/test.dart';

void main() {
  const Rect clip = Rect.fromLTRB(0, 0, 64, 64);

  /// Renders [path] both ways and reports the worst per-pixel disagreement.
  _Diff compare(
    Path path, {
    Rect clip = const Rect.fromLTRB(0, 0, 64, 64),
    FillRule rule = FillRule.nonZero,
    Transform2D transform = Transform2D.identity,
  }) {
    final Uint8List reference = _flatten(
      SparseStripGenerator().fill(path, clip, rule: rule, transform: transform),
      clip,
    );
    final Uint8List actual = _flatten(
      NativeStripRasterizer()
          .fill(path, clip, rule: rule, transform: transform),
      clip,
    );
    return _Diff.between(reference, actual, clip);
  }

  group('agrees with the scanline rasteriser', () {
    test('a pixel-aligned rectangle', () {
      // The floor: every edge on a pixel boundary, so every pixel is 0 or 255
      // and any disagreement is structural rather than a rounding difference.
      expect(compare(_rect(8, 8, 40, 40)).maxDeviation, 0);
    });

    test('a rectangle with fractional edges', () {
      // Now every boundary pixel carries a fraction, which is the analytic
      // area the two rasterisers compute by completely different routes.
      final _Diff diff = compare(_rect(8.25, 6.5, 39.75, 41.125));
      expect(diff.maxDeviation, lessThanOrEqualTo(1), reason: diff.report);
    });

    test('a diagonal', () {
      final _Diff diff = compare((PathBuilder()
            ..moveTo(6.5, 6.5)
            ..lineTo(52.25, 20.75)
            ..lineTo(20.5, 55.5)
            ..close())
          .build());
      expect(diff.maxDeviation, lessThanOrEqualTo(1), reason: diff.report);
    });

    test('a vertical line exactly on a pixel boundary', () {
      // The NaN case, and the one the port had to handle by hand: a vertical
      // line makes the slope infinite, `0 * inf` is NaN for the edge it sits
      // on, and the convention is that the line belongs to the pixel on whose
      // *left* edge it lies. Rust gets this from x86 `max` semantics; Dart
      // comparisons are all false against NaN, so it is an explicit test.
      final _Diff diff = compare(_rect(16, 8, 32, 40));
      expect(diff.maxDeviation, 0, reason: diff.report);
    });

    test('a vertical line on a tile boundary', () {
      // The same, but where the pixel edge is also a *tile* edge, so the
      // winding has to cross a location boundary correctly.
      final _Diff diff = compare(_rect(12, 4, 28, 44));
      expect(diff.maxDeviation, 0, reason: diff.report);
    });

    test('a curve', () {
      final PathBuilder builder = PathBuilder()
        ..moveTo(8, 32)
        ..cubicTo(8, 8, 56, 8, 56, 32)
        ..cubicTo(56, 56, 8, 56, 8, 32)
        ..close();
      final _Diff diff = compare(builder.build());
      expect(diff.maxDeviation, lessThanOrEqualTo(1), reason: diff.report);
    });

    test('a hole wound against its outer contour', () {
      final _Diff diff = compare(_holePath());
      expect(diff.maxDeviation, lessThanOrEqualTo(1), reason: diff.report);
    });

    test('the same shape under even-odd', () {
      final _Diff diff = compare(_holePath(), rule: FillRule.evenOdd);
      expect(diff.maxDeviation, lessThanOrEqualTo(1), reason: diff.report);
    });

    test('overlapping contours wound the same way', () {
      // Where non-zero and even-odd disagree: the overlap is ink under
      // non-zero and a hole under even-odd, so the winding has to survive
      // being greater than one.
      final PathBuilder builder = PathBuilder();
      _addRect(builder, 6.5, 6.5, 36.5, 36.5, clockwise: true);
      _addRect(builder, 24.5, 24.5, 54.5, 54.5, clockwise: true);
      final Path path = builder.build();
      expect(compare(path).maxDeviation, lessThanOrEqualTo(1));
      expect(compare(path, rule: FillRule.evenOdd).maxDeviation,
          lessThanOrEqualTo(1));
    });

    test('a shape larger than the clip', () {
      // Every edge is off-screen, so the interior has to be filled entirely
      // from carried winding with no boundary tiles inside the viewport at all.
      final _Diff diff = compare(_rect(-40, -40, 120, 120));
      expect(diff.maxDeviation, 0, reason: diff.report);
    });

    test('a shape that starts left of the clip', () {
      // Only the left edge is outside. This is the case the port replaced
      // Vello's culled-winding bookkeeping with clamping, so it is the one
      // that would break if the clamp were wrong.
      final _Diff diff = compare(_rect(-20.5, 10.25, 40.75, 50.5));
      expect(diff.maxDeviation, lessThanOrEqualTo(1), reason: diff.report);
    });

    test('a shape entirely right of the clip contributes nothing', () {
      expect(compare(_rect(80, 8, 120, 40)).maxDeviation, 0);
    });

    test('a degenerate shape', () {
      expect(compare(_rect(20, 20, 20, 40)).maxDeviation, 0);
      expect(compare(_rect(20, 20, 40, 20)).maxDeviation, 0);
    });

    test('a transform is applied, not ignored', () {
      final _Diff diff = compare(
        _rect(4, 4, 20, 20),
        transform: const Transform2D(2, 0, 0, 2, 6.5, 5.25),
      );
      expect(diff.maxDeviation, lessThanOrEqualTo(1), reason: diff.report);
      expect(diff.inkedPixels, greaterThan(0),
          reason: 'a transform that produced nothing would compare equal');
    });

    test('a fractional clip is expanded the same way', () {
      // The framework expands a clip outward to whole pixels. A route that
      // applied the exact rectangle would disagree with every other route,
      // which is the divergence found earlier on the compute path.
      final _Diff diff = compare(
        _rect(4, 4, 60, 60),
        clip: const Rect.fromLTRB(8.25, 6.5, 47.75, 44.125),
      );
      expect(diff.maxDeviation, lessThanOrEqualTo(1), reason: diff.report);
    });

    test('many small shapes in one path', () {
      // Edge density rather than area: the case the strip architecture is
      // supposed to be good at, and the one with the most location boundaries
      // per pixel.
      final PathBuilder builder = PathBuilder();
      for (var i = 0; i < 24; i++) {
        final double x = 2.0 + (i % 6) * 10.25;
        final double y = 2.0 + (i ~/ 6) * 10.5;
        _addRect(builder, x, y, x + 7.5, y + 7.75, clockwise: i.isEven);
      }
      final _Diff diff = compare(builder.build());
      expect(diff.maxDeviation, lessThanOrEqualTo(1), reason: diff.report);
    });

    test('a star, which is dense in edges and self-intersecting', () {
      final _Diff diff = compare(_star(points: 11, skip: 4));
      expect(diff.maxDeviation, lessThanOrEqualTo(1), reason: diff.report);
      expect(
          compare(_star(points: 11, skip: 4), rule: FillRule.evenOdd)
              .maxDeviation,
          lessThanOrEqualTo(1));
    });
  });

  group('the buffers stabilise', () {
    test('a repeated fill stops growing them', () {
      // The steady-state claim: a frame that draws what the last frame drew
      // must not reallocate. Without it the rasteriser would be allocating on
      // the hot path, which is the cost it exists to remove.
      final rasterizer = NativeStripRasterizer();
      final Path path = _star(points: 9, skip: 4);
      for (var i = 0; i < 3; i++) {
        rasterizer.fill(path, clip);
      }
      final int settled = rasterizer.bufferGrowths;
      for (var i = 0; i < 10; i++) {
        rasterizer.fill(path, clip);
      }
      expect(rasterizer.bufferGrowths, settled);
    });
  });
}

// ---------------------------------------------------------------------
// Scenes
// ---------------------------------------------------------------------

Path _rect(double left, double top, double right, double bottom) {
  final PathBuilder builder = PathBuilder();
  _addRect(builder, left, top, right, bottom, clockwise: true);
  return builder.build();
}

void _addRect(
  PathBuilder builder,
  double left,
  double top,
  double right,
  double bottom, {
  required bool clockwise,
}) {
  builder.moveTo(left, top);
  if (clockwise) {
    builder
      ..lineTo(right, top)
      ..lineTo(right, bottom)
      ..lineTo(left, bottom);
  } else {
    builder
      ..lineTo(left, bottom)
      ..lineTo(right, bottom)
      ..lineTo(right, top);
  }
  builder.close();
}

Path _holePath() {
  final PathBuilder builder = PathBuilder();
  _addRect(builder, 6.5, 6.5, 56.5, 56.5, clockwise: true);
  _addRect(builder, 20.25, 20.25, 42.75, 42.75, clockwise: false);
  return builder.build();
}

/// A star polygon, which is both edge-dense and self-intersecting.
Path _star({required int points, required int skip}) {
  final PathBuilder builder = PathBuilder();
  const double cx = 32;
  const double cy = 32;
  const double r = 27.5;
  for (var i = 0; i <= points; i++) {
    final double angle = (i * skip) * 2 * 3.141592653589793 / points;
    final double x = cx + r * _cos(angle);
    final double y = cy + r * _sin(angle);
    if (i == 0) {
      builder.moveTo(x, y);
    } else {
      builder.lineTo(x, y);
    }
  }
  builder.close();
  return builder.build();
}

double _cos(double a) => _sin(a + 1.5707963267948966);

double _sin(double a) {
  // A tiny deterministic sine so the scene does not depend on dart:math's
  // platform-specific rounding, which would make the benchmark scenes differ
  // between runs of the same code on different machines.
  var x = a % 6.283185307179586;
  if (x > 3.141592653589793) x -= 6.283185307179586;
  final double x2 = x * x;
  return x *
      (1 -
          x2 / 6 +
          x2 * x2 / 120 -
          x2 * x2 * x2 / 5040 +
          x2 * x2 * x2 * x2 / 362880);
}

// ---------------------------------------------------------------------
// Comparison
// ---------------------------------------------------------------------

/// Expands a strip buffer into one coverage byte per pixel of [clip].
Uint8List _flatten(StripBuffer strips, Rect clip) {
  final int left = clip.left.floor();
  final int top = clip.top.floor();
  final int width = clip.right.ceil() - left;
  final int height = clip.bottom.ceil() - top;
  final Uint8List pixels = Uint8List(width * height);

  for (var i = 0; i < strips.stripCount; i++) {
    final int x = strips.stripX(i) - left;
    final int y = strips.stripY(i) - top;
    final int stripWidth = strips.stripWidth(i);
    for (var row = 0; row < kStripHeight; row++) {
      final int py = y + row;
      if (py < 0 || py >= height) continue;
      for (var column = 0; column < stripWidth; column++) {
        final int px = x + column;
        if (px < 0 || px >= width) continue;
        pixels[py * width + px] = strips.stripAlpha(i, column, row);
      }
    }
  }
  for (var i = 0; i < strips.fillCount; i++) {
    final int x = strips.fillX(i) - left;
    final int y = strips.fillY(i) - top;
    final int fillWidth = strips.fillWidth(i);
    for (var row = 0; row < kStripHeight; row++) {
      final int py = y + row;
      if (py < 0 || py >= height) continue;
      for (var column = 0; column < fillWidth; column++) {
        final int px = x + column;
        if (px < 0 || px >= width) continue;
        pixels[py * width + px] = 255;
      }
    }
  }
  return pixels;
}

final class _Diff {
  const _Diff(this.maxDeviation, this.differing, this.inkedPixels, this.report);

  final int maxDeviation;
  final int differing;

  /// Non-zero pixels in the reference. A scene that drew nothing would compare
  /// equal and prove nothing.
  final int inkedPixels;

  final String report;

  static _Diff between(Uint8List reference, Uint8List actual, Rect clip) {
    final int width = clip.right.ceil() - clip.left.floor();
    var maxDeviation = 0;
    var differing = 0;
    var inked = 0;
    final List<String> lines = <String>[];
    for (var i = 0; i < reference.length; i++) {
      if (reference[i] != 0) inked++;
      final int deviation = (reference[i] - actual[i]).abs();
      if (deviation == 0) continue;
      differing++;
      if (deviation > maxDeviation) maxDeviation = deviation;
      if (lines.length < 16) {
        lines.add('(${i % width}, ${i ~/ width}): '
            'scanline ${reference[i]}, native ${actual[i]}');
      }
    }
    return _Diff(
      maxDeviation,
      differing,
      inked,
      'up to $maxDeviation levels over $differing pixels '
      '($inked inked)\n${lines.join('\n')}',
    );
  }
}
