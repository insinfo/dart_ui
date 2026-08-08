import 'dart:math' as math;

import 'package:dart_ui/src/rendering/raster/coverage.dart';
import 'package:test/test.dart';

/// Total coverage a span deposits across every pixel it touches.
int totalCoverage(double start, double end) {
  var total = 0;
  for (var i = firstCoveredPixel(start); i < coveredPixelEnd(end); i++) {
    total += spanCoverage(start, end, i);
  }
  return total;
}

void main() {
  group('spanCoverage', () {
    test('a pixel entirely inside is exactly 255', () {
      // Exactly, not approximately: the rasteriser routes coverage-255 pixels
      // down the hard-edged fast path, so anything less here would silently
      // put the interior of every antialiased shape on the slow path and make
      // it a shade too dark.
      expect(spanCoverage(1.0, 5.0, 2), 255);
      expect(spanCoverage(1.25, 5.75, 2), 255);
      expect(spanCoverage(1.25, 5.75, 3), 255);
      expect(spanCoverage(-3.5, 9.5, 0), 255);
    });

    test('a pixel entirely outside is 0', () {
      expect(spanCoverage(2.0, 5.0, 0), 0);
      expect(spanCoverage(2.0, 5.0, 7), 0);
      expect(spanCoverage(2.25, 5.75, 1), 0);
    });

    test('is half-open, matching Rect', () {
      // A span ending exactly at 3.0 does not put ink in the pixel [3, 4).
      expect(spanCoverage(1.0, 3.0, 3), 0);
      expect(spanCoverage(1.0, 3.0, 2), 255);
      // And one starting exactly at 3.0 covers that pixel fully.
      expect(spanCoverage(3.0, 6.0, 3), 255);
      expect(spanCoverage(3.0, 6.0, 2), 0);
    });

    test('a half-covered pixel splits 127/128, and that is on purpose', () {
      // 255 is odd, so a span that lands exactly on a pixel centre cannot
      // split symmetrically AND still sum to a whole pixel. Conservation wins;
      // see the note in coverage.dart.
      expect(spanCoverage(0.5, 1.5, 0), 127);
      expect(spanCoverage(0.5, 1.5, 1), 128);
      expect(spanCoverage(0.5, 1.5, 0) + spanCoverage(0.5, 1.5, 1), 255);
    });

    test('a quarter and three quarters', () {
      expect(spanCoverage(0.25, 1.25, 0), 191);
      expect(spanCoverage(0.25, 1.25, 1), 64);
      expect(spanCoverage(0.25, 1.25, 0) + spanCoverage(0.25, 1.25, 1), 255);
    });

    test('a sub-pixel span covers only its own fraction', () {
      // Width 0.2 of one pixel: 255 * 0.2 = 51.
      expect(spanCoverage(1.2, 1.4, 1), 51);
      expect(spanCoverage(1.2, 1.4, 0), 0);
      expect(spanCoverage(1.2, 1.4, 2), 0);
    });

    test('a sliver thinner than half a quantisation step rounds to 0', () {
      // The rasteriser must not blend at all here; a write with alpha 0 is
      // still a write. This is the input that produces that case.
      expect(spanCoverage(1.999, 2.5, 1), 0);
    });

    test('never leaves the byte range', () {
      final random = math.Random(20260808);
      for (var trial = 0; trial < 20000; trial++) {
        final start = random.nextDouble() * 30 - 10;
        final end = start + random.nextDouble() * 8;
        for (var i = firstCoveredPixel(start); i < coveredPixelEnd(end); i++) {
          expect(spanCoverage(start, end, i), inInclusiveRange(0, 255));
        }
      }
    });
  });

  group('conservation', () {
    test('an integer-width span deposits exactly 255 per pixel of width', () {
      // The property that catches coverage bugs: however the span is offset,
      // the ink it lays down is the same. A scheme that rounds each pixel's
      // width independently fails this by a unit at every edge.
      final random = math.Random(7);
      for (var trial = 0; trial < 5000; trial++) {
        final start = random.nextDouble() * 20;
        for (final width in <int>[1, 2, 3, 7]) {
          expect(
            totalCoverage(start, start + width),
            255 * width,
            reason: 'start $start width $width',
          );
        }
      }
    });

    test('an arbitrary span is within a rounding unit of its true area', () {
      final random = math.Random(99);
      for (var trial = 0; trial < 20000; trial++) {
        final start = random.nextDouble() * 20 - 5;
        final width = random.nextDouble() * 9;
        final total = totalCoverage(start, start + width);
        expect((total - 255 * width).abs(), lessThanOrEqualTo(1.0));
      }
    });

    test('splitting a span at a pixel boundary loses nothing', () {
      // Two abutting rectangles must between them cover the shared column
      // exactly once. This is the seam case.
      expect(totalCoverage(0.0, 1.5) + totalCoverage(1.5, 3.0), 255 * 3);
      expect(totalCoverage(0.3, 2.0) + totalCoverage(2.0, 4.7), 255 * 4 + 102);
    });
  });

  group('translation', () {
    test('shifting by a whole pixel shifts the coverage pattern exactly', () {
      // Quantisation is anchored to the surface origin, so this is a claim
      // worth checking: a shape must not shimmer as it moves by whole pixels.
      for (var shift = 0; shift < 60; shift++) {
        expect(spanCoverage(0.5 + shift, 3.5 + shift, shift), 127);
        expect(spanCoverage(0.5 + shift, 3.5 + shift, 1 + shift), 255);
        expect(spanCoverage(0.5 + shift, 3.5 + shift, 3 + shift), 128);
      }
    });
  });

  group('iteration bounds', () {
    test('cover every pixel the span touches and no more', () {
      expect(firstCoveredPixel(3.0), 3);
      expect(firstCoveredPixel(3.2), 3);
      expect(firstCoveredPixel(-0.2), -1);
      expect(coveredPixelEnd(3.0), 3);
      expect(coveredPixelEnd(3.2), 4);
      // Generous rather than rounded: an edge at 10.2 still inks column 10,
      // which the fill's round-to-nearest bound would have dropped.
      expect(coveredPixelEnd(10.2), 11);
    });
  });
}
