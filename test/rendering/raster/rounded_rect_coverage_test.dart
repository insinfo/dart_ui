/// The CPU's closed-form rounded rectangle, against the exact circle.
///
/// This file exists because matching the GPU is not enough. The two backends
/// now evaluate the same field, so a mistake made in `fillRoundedRectSpans` -
/// a half-pixel offset, a corner solved on the wrong side, a coverage rounded
/// the wrong way - could agree with the shader perfectly and still be wrong
/// about the shape the display list asked for. The reference below is a
/// 400x400 point sample of the exact rounded rectangle, computed by a loop
/// that no rasteriser in this repository is derived from, so it cannot
/// flatter either of them.
///
/// The band it is held to is the one `gl_analytic_primitive_test.dart`
/// measured for the closed form on the same shape: **0.035 of a pixel's
/// area**, which is the `0.5 - d` half-plane approximation being what it says
/// it is on a circular arc. The route this replaces - the corner arc
/// flattened to a polyline and filled - measured 0.164 on the same pixels,
/// and the comparison is repeated here so the improvement is asserted rather
/// than remembered.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/rendering/gpu/vector/analytic_primitive.dart';
import 'package:dart_ui/src/rendering/path/coverage_span_sink.dart';
import 'package:dart_ui/src/rendering/path/scanline_filler.dart';
import 'package:dart_ui/src/rendering/raster/rounded_rect_coverage.dart';
import 'package:test/test.dart';

void main() {
  group('the closed form against a supersampled circle', () {
    test('tracks the exact shape to within 0.035 of a pixel on the corner', () {
      // The same shape and the same corner quadrant `gl_analytic_primitive_
      // test.dart` measures the shader on, so the two numbers are comparable
      // and a regression in either file is visible against the other.
      const Rect box = Rect.fromLTRB(6, 20, 58, 44);
      const double radius = 12;
      final _CoverageImage image = _closedForm(box, radius, 64, 64);

      var worst = 0.0;
      for (var y = 19; y < 33; y++) {
        for (var x = 5; x < 19; x++) {
          final double truth = _sampledCoverage(x, y, box, radius);
          final double error = (image.at(x, y) - truth).abs();
          if (error > worst) worst = error;
        }
      }
      printOnFailure('worst error on the corner: $worst');
      expect(worst, lessThan(0.04),
          reason: 'the span generator should track the true circle as closely '
              'as the field it is derived from; if it does not, the spans are '
              'wrong rather than merely approximate');
    });

    test('and does so about five times more closely than the filler did', () {
      // The claim the whole change rests on, asserted rather than quoted: the
      // route being replaced is further from the exact circle than the one
      // replacing it, and in a consistent direction. If the flattened polygon
      // ever became this accurate the honest response would be to remeasure
      // the tolerances everywhere else, not to widen this.
      const Rect box = Rect.fromLTRB(6, 20, 58, 44);
      const double radius = 12;
      final _CoverageImage closed = _closedForm(box, radius, 64, 64);
      final _CoverageImage flattened = _flattened(box, radius, 64, 64);

      var worstClosed = 0.0;
      var worstFlattened = 0.0;
      var flattenedTooSharp = 0;
      var flattenedTooRound = 0;
      for (var y = 19; y < 33; y++) {
        for (var x = 5; x < 19; x++) {
          final double truth = _sampledCoverage(x, y, box, radius);
          final double a = closed.at(x, y) - truth;
          final double d = flattened.at(x, y) - truth;
          if (a.abs() > worstClosed) worstClosed = a.abs();
          if (d.abs() > worstFlattened) worstFlattened = d.abs();
          // A chord cuts inside the arc it replaces, so where the two differ
          // the polygon covers *less* than the truth.
          if (d < -0.005) flattenedTooSharp++;
          if (d > 0.005) flattenedTooRound++;
        }
      }
      printOnFailure('closed form $worstClosed, flattened $worstFlattened, '
          'too sharp on $flattenedTooSharp pixels, too round on '
          '$flattenedTooRound');
      expect(worstFlattened, greaterThan(worstClosed * 3));
      expect(flattenedTooSharp, greaterThan(0));
      expect(flattenedTooRound, 0,
          reason: 'the flattening error has a direction - every chord lies '
              'inside its arc - and a polygon that came out too round would '
              'mean the flattener, not the closed form, had changed');
    });

    test('a one-pixel radius is where the half-plane approximation is widest',
        () {
      // The radius at which `0.5 - d` is least like an area, stated so the
      // band is a measurement and not an assumption. It is still under a
      // tenth of a pixel, which is why the route is taken at every radius
      // rather than only at generous ones.
      const Rect box = Rect.fromLTRB(4, 4, 20, 16);
      const double radius = 1;
      final _CoverageImage image = _closedForm(box, radius, 24, 20);
      var worst = 0.0;
      for (var y = 3; y < 17; y++) {
        for (var x = 3; x < 21; x++) {
          final double truth = _sampledCoverage(x, y, box, radius);
          final double error = (image.at(x, y) - truth).abs();
          if (error > worst) worst = error;
        }
      }
      printOnFailure('worst error at radius 1: $worst');
      expect(worst, lessThan(0.1));
    });

    test('the straight edges and the interior are exact, not approximate', () {
      // Away from the arcs the boundary crossing a pixel is a straight line,
      // where `0.5 - d` is the covered area rather than an estimate of it.
      // A fractional edge is used on purpose: an integer one would pass for a
      // generator that had rounded the box to whole pixels.
      const Rect box = Rect.fromLTRB(4.25, 6.5, 19.75, 15.5);
      const double radius = 3;
      final _CoverageImage image = _closedForm(box, radius, 24, 22);
      for (var y = 10; y < 12; y++) {
        for (var x = 3; x < 21; x++) {
          final double truth = _sampledCoverage(x, y, box, radius);
          expect(image.at(x, y), closeTo(truth, 0.004),
              reason: 'row $y column $x is on a straight edge or inside');
        }
      }
    });
  });

  group('the spans themselves', () {
    test('obey the sink contract: ordered, disjoint, never zero, clipped', () {
      // The filler's contract, which a second producer of spans has to keep
      // as well: a sink written against it - `_CoverageToRasterizer` is one -
      // is entitled to skip every check this test performs.
      final recorder = _SpanRecorder();
      fillRoundedRectSpans(
        recorder,
        box: const Rect.fromLTRB(2.5, 3.25, 29.5, 21.75),
        radius: 7,
        clip: const Rect.fromLTRB(4, 5, 26, 20),
      );
      expect(recorder.spans, isNotEmpty);
      var lastY = -1;
      var lastEnd = 0;
      for (final _Span span in recorder.spans) {
        expect(span.y, greaterThanOrEqualTo(lastY));
        if (span.y != lastY) {
          lastY = span.y;
          lastEnd = -1 << 30;
        }
        expect(span.xStart, greaterThanOrEqualTo(lastEnd),
            reason: 'spans on row ${span.y} overlap or run backwards');
        expect(span.xEnd, greaterThan(span.xStart));
        expect(span.coverage, inInclusiveRange(1, 255));
        expect(span.xStart, greaterThanOrEqualTo(4));
        expect(span.xEnd, lessThanOrEqualTo(26));
        expect(span.y, inInclusiveRange(5, 19));
        lastEnd = span.xEnd;
      }
    });

    test('reaches half a pixel outside the box and no further', () {
      // The fringe the quad on the GPU is snapped out for. A generator that
      // stopped at the box would cut the outer half of every antialiased edge
      // and one that ran further would waste a row and a column per shape.
      final recorder = _SpanRecorder();
      fillRoundedRectSpans(
        recorder,
        box: const Rect.fromLTRB(6, 6, 26, 20),
        radius: 5,
        clip: const Rect.fromLTRB(0, 0, 32, 32),
      );
      final Set<int> rows = recorder.spans.map((s) => s.y).toSet();
      // The box's own rows, and not the ones a half pixel could never reach.
      expect(rows.reduce(math.min), 6);
      expect(rows.reduce(math.max), 19);
      var minX = 1 << 30;
      var maxX = 0;
      for (final _Span span in recorder.spans) {
        minX = math.min(minX, span.xStart);
        maxX = math.max(maxX, span.xEnd);
      }
      expect(minX, 6);
      expect(maxX, 26);
    });

    test('a run of equal coverage is one span, not one per pixel', () {
      // Coalescing is load-bearing rather than cosmetic: the sink turns each
      // span into one `fillRect`, so a straight edge reported pixel by pixel
      // would cost a call per pixel for a row whose coverage never changes.
      final recorder = _SpanRecorder();
      fillRoundedRectSpans(
        recorder,
        box: const Rect.fromLTRB(4, 4.5, 60, 40.5),
        radius: 6,
        clip: const Rect.fromLTRB(0, 0, 64, 48),
      );
      // Row 4 grazes the top edge: half covered all the way across the
      // straight part, so the middle of it is a single span.
      final List<_Span> row = recorder.spans.where((s) => s.y == 4).toList();
      final _Span widest =
          row.reduce((a, b) => b.xEnd - b.xStart > a.xEnd - a.xStart ? b : a);
      expect(widest.xEnd - widest.xStart, greaterThan(40));
    });

    test('an empty clip and a degenerate box produce nothing', () {
      final recorder = _SpanRecorder();
      fillRoundedRectSpans(
        recorder,
        box: const Rect.fromLTRB(4, 4, 20, 20),
        radius: 4,
        clip: const Rect.fromLTRB(30, 30, 30, 30),
      );
      fillRoundedRectSpans(
        recorder,
        box: const Rect.fromLTRB(4, 4, 4, 20),
        radius: 4,
        clip: const Rect.fromLTRB(0, 0, 32, 32),
      );
      expect(recorder.spans, isEmpty);
    });
  });

  group('against the field the shader evaluates', () {
    test('every pixel of a pill is the byte AnalyticPrimitive computes', () {
      // Not a restatement of the implementation: `AnalyticPrimitive.fieldAt`
      // is the reference the GLSL was transcribed from, so this is the
      // assertion that the CPU's row-by-row shortcuts - a solved crossing for
      // the solid run, a constant for the straight fringes, the field only
      // inside the corner boxes - never disagree with evaluating the field at
      // every pixel. Parity with the GPU rests on it.
      const Rect box = Rect.fromLTRB(6.25, 20.5, 58, 44);
      const double radius = 11.75;
      final analytic = AnalyticPrimitive();
      expect(
        const AnalyticPrimitiveRecognizer()
            .recogniseRoundedRect(analytic, box, _uniformRadii(radius)),
        isTrue,
      );

      final _CoverageImage image = _closedForm(box, radius, 64, 64);
      for (var y = 0; y < 64; y++) {
        for (var x = 0; x < 64; x++) {
          final double exact = analytic.coverageAt(x + 0.5, y + 0.5);
          final int expected = _byte(exact);
          expect(image.byteAt(x, y), expected,
              reason: 'pixel ($x, $y): spans say ${image.byteAt(x, y)}, the '
                  'field says $expected');
        }
      }
    });

    test('a circle, a pill and an overrun radius all agree with the field', () {
      // The three shapes the recogniser folds into the same kind: a square
      // with radius half its side, a box with radius half its short side, and
      // a radius the overrun rule has to clamp. Each puts the row solver in a
      // different regime - no straight band at all, none vertically, and a
      // radius that arrived larger than the box.
      final cases = <(Rect, double)>[
        (const Rect.fromLTRB(16, 16, 48, 48), 16),
        (const Rect.fromLTRB(6, 20, 58, 44), 12),
        (const Rect.fromLTRB(6, 20, 58, 44), 40),
      ];
      for (final (Rect box, double asked) in cases) {
        final analytic = AnalyticPrimitive();
        const AnalyticPrimitiveRecognizer()
            .recogniseRoundedRect(analytic, box, _uniformRadii(asked));
        final double clamped = analytic.p0;
        final _CoverageImage image = _closedForm(box, clamped, 64, 64);
        for (var y = 0; y < 64; y++) {
          for (var x = 0; x < 64; x++) {
            expect(
                image.byteAt(x, y), _byte(analytic.coverageAt(x + .5, y + .5)),
                reason: 'box $box radius $asked at ($x, $y)');
          }
        }
      }
    });
  });
}

// ---------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------

Float32List _uniformRadii(double r) =>
    Float32List.fromList(<double>[r, r, r, r, r, r, r, r]);

/// The byte the span generator is expected to round a coverage to: nearest,
/// the same rule `ScanlineFiller` and `mul255` use.
int _byte(double coverage) {
  if (coverage <= 0) return 0;
  if (coverage >= 1) return 255;
  final int value = (coverage * 255.0 + 0.5).toInt();
  return value > 255 ? 255 : value;
}

_CoverageImage _closedForm(Rect box, double radius, int width, int height) {
  final image = _CoverageImage(width, height);
  fillRoundedRectSpans(
    image,
    box: box,
    radius: radius,
    clip: Rect.fromLTRB(0, 0, width.toDouble(), height.toDouble()),
  );
  return image;
}

_CoverageImage _flattened(Rect box, double radius, int width, int height) {
  final image = _CoverageImage(width, height);
  ScanlineFiller().fill(
    (PathBuilder()..addRoundedRect(box, radius, radius)).build(),
    Rect.fromLTRB(0, 0, width.toDouble(), height.toDouble()),
    image,
  );
  return image;
}

/// The exact rounded rectangle, point sampled. Slow and obviously correct,
/// which is the whole reason it is here. The twin of the function in
/// `gl_analytic_primitive_test.dart`, deliberately duplicated: a shared helper
/// would let one edit move both this file's reference and that one's.
double _sampledCoverage(int px, int py, Rect box, double radius) {
  const int n = 400;
  var inside = 0;
  for (var i = 0; i < n; i++) {
    final double x = px + (i + 0.5) / n;
    for (var j = 0; j < n; j++) {
      final double y = py + (j + 0.5) / n;
      if (x < box.left || x > box.right || y < box.top || y > box.bottom) {
        continue;
      }
      final double dx = x < box.left + radius
          ? box.left + radius - x
          : x - (box.right - radius);
      final double dy = y < box.top + radius
          ? box.top + radius - y
          : y - (box.bottom - radius);
      final double ox = dx > 0 ? dx : 0;
      final double oy = dy > 0 ? dy : 0;
      if (ox * ox + oy * oy <= radius * radius) inside++;
    }
  }
  return inside / (n * n);
}

final class _CoverageImage implements CoverageSpanSink {
  _CoverageImage(this.width, this.height) : _pixels = Uint8List(width * height);

  final int width;
  final int height;
  final Uint8List _pixels;

  @override
  void span(int y, int xStart, int xEnd, int coverage) {
    if (y < 0 || y >= height) return;
    for (var x = xStart; x < xEnd; x++) {
      if (x < 0 || x >= width) continue;
      _pixels[y * width + x] = coverage;
    }
  }

  int byteAt(int x, int y) => _pixels[y * width + x];

  double at(int x, int y) => _pixels[y * width + x] / 255.0;
}

final class _Span {
  _Span(this.y, this.xStart, this.xEnd, this.coverage);
  final int y;
  final int xStart;
  final int xEnd;
  final int coverage;
}

final class _SpanRecorder implements CoverageSpanSink {
  final List<_Span> spans = <_Span>[];

  @override
  void span(int y, int xStart, int xEnd, int coverage) =>
      spans.add(_Span(y, xStart, xEnd, coverage));
}
