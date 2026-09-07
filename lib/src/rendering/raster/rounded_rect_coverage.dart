/// Exact-enough coverage for a uniform-radius rounded rectangle, without a
/// path.
///
/// The sibling of `coverage.dart`. That file answers "how much of this pixel
/// does an axis-aligned *rectangle* cover?" by a separable area computation
/// that is exact; this one answers the same question for a rectangle with one
/// circular radius on all four corners, by evaluating the shape's signed
/// distance field at the pixel centre and taking `0.5 - d`.
///
/// ## Why this exists when `ScanlineFiller` already fills the shape
///
/// It is **more accurate**, which is the opposite of what a fast path is
/// usually for. The filler is handed a `Path`, so the corner arcs have already
/// been flattened into a polyline at `kDefaultFlattenTolerance` - a quarter of
/// a device pixel - and every chord of that polyline lies *inside* the arc it
/// replaces. The error therefore has a direction: the filler draws every
/// rounded corner slightly too sharp, on every rounded rectangle this
/// framework has ever drawn. Measured against a 400x400 point sample of the
/// exact circle on the corner of a radius-12 rounded rectangle, the flattened
/// polygon is out by up to **0.164** of a pixel's area and the closed form by
/// **0.035** - 4.7x closer, and the polygon's error always in the same sense.
/// The measurement lives in `gl_analytic_primitive_test.dart`
/// (`_theClosedFormIsTheAccurateOne`) and is repeated against this file in
/// `test/rendering/raster/rounded_rect_coverage_test.dart`.
///
/// `0.5 - d` is not itself exact: it is the area of the half-plane whose
/// boundary passes the pixel centre at distance `d`, so it is exact wherever
/// the boundary crossing a pixel is straight - the four edges, which is most
/// of the outline - and an approximation of O(1/radius) on the arcs. That
/// residual is what the 0.035 above measures, and it shrinks as the corner
/// gets rounder.
///
/// ## Why it is also cheaper
///
/// The filler walks the whole bounding box accumulating a signed area per
/// scanline from the flattened edge list, so a 220x44 button costs one
/// polyline of some 60 segments plus 9 680 cells of accumulation. Here a
/// scanline needs the field at the pixels inside the two corner boxes only -
/// `2 * (radius + 1)` of them - because on the rest of the row the field
/// reduces to a function of one coordinate, whose crossings of `-0.5` and
/// `+0.5` are solved in closed form and emitted as one solid run and two
/// constant fringes.
///
/// ## What it does not do, and where that is decided
///
/// Per-corner radii, elliptical corners and rotation are not here at all: this
/// function takes one radius. The decision about which shapes qualify is not
/// taken here either - `AnalyticPrimitiveRecognizer` takes it, and both this
/// renderer and the GPU one ask it, so the two cannot drift about what a 40px
/// radius on a 50px edge means.
library;

import 'dart:math' as math;

import '../../geometry/rect.dart';
import '../path/coverage_span_sink.dart';

/// Emits the coverage of the rounded rectangle [box] with corner [radius] to
/// [sink], as spans, in increasing `y`.
///
/// [radius] must be positive and no larger than half of either side - which is
/// what `AnalyticPrimitiveRecognizer.recogniseRoundedRect` guarantees after it
/// has applied the overrun rule. A zero radius is *not* handled here on
/// purpose: the field says a pixel centred on a square corner is half covered
/// where the truth is a quarter, so a caller with no radius has to use the
/// separable rectangle coverage in `coverage.dart` instead.
///
/// [clip] is expanded outward to whole pixels, exactly as `ScanlineFiller`
/// expands it and for the same reason: this function can only decline to
/// report a pixel, and cutting one in half is the clip stack's job.
void fillRoundedRectSpans(
  CoverageSpanSink sink, {
  required Rect box,
  required double radius,
  required Rect clip,
}) {
  final int clipLeft = clip.left.floor();
  final int clipTop = clip.top.floor();
  final int clipRight = clip.right.ceil();
  final int clipBottom = clip.bottom.ceil();
  if (clipRight <= clipLeft || clipBottom <= clipTop) return;

  final double hx = (box.right - box.left) * 0.5;
  final double hy = (box.bottom - box.top) * 0.5;
  if (!(hx > 0) || !(hy > 0) || !(radius > 0)) return;
  final double cx = (box.left + box.right) * 0.5;
  final double cy = (box.top + box.bottom) * 0.5;

  // Coverage reaches half a pixel outside the box and no further, so a pixel
  // whose centre is more than that away contributes nothing.
  var yStart = (box.top - 0.5).floor();
  var yEnd = (box.bottom + 0.5).ceil();
  if (yStart < clipTop) yStart = clipTop;
  if (yEnd > clipBottom) yEnd = clipBottom;

  // Half the width of the band down the middle of the shape that no arc
  // touches. Non-negative because the overrun rule has already clamped the
  // radius to half the shorter side.
  final double midHalf = hx - radius;

  for (var y = yStart; y < yEnd; y++) {
    // The field, restricted to this row, is a function of |x - cx| alone, and
    // a non-decreasing one. Two numbers describe the whole row: the half-width
    // at which it crosses -0.5, inside which every pixel is wholly covered,
    // and the half-width at which it crosses +0.5, outside which no pixel is
    // covered at all. Everything between the two is evaluated per pixel.
    final double dy = ((y + 0.5) - cy).abs();
    // The distance to the nearest horizontal edge - which is what the field
    // *is* everywhere in the middle band, whichever side of the arc line the
    // row falls on.
    final double edgeY = dy - hy;
    if (edgeY >= 0.5) continue;
    final double qy = edgeY + radius;

    final double outerHalf;
    final double solidHalf;
    if (qy > 0) {
      // The row crosses the two corner arcs. Beyond `midHalf` the field is the
      // distance to the corner circle's centre less its radius, so a level `t`
      // is crossed where the horizontal leg of that distance is
      // `sqrt((t + radius)^2 - qy^2)`.
      outerHalf = midHalf + _leg(0.5 + radius, qy);
      solidHalf = edgeY > -0.5 ? -1.0 : midHalf + _leg(radius - 0.5, qy);
    } else {
      // The row is in the straight middle band: the field is `|x - cx| - hx`
      // on the flanks, so the crossings are the box edges moved out by `t`.
      outerHalf = hx + 0.5;
      solidHalf = edgeY > -0.5 ? -1.0 : hx - 0.5;
    }

    // Tight, not generous: `xStart` is the first pixel whose centre is at or
    // inside the outer crossing and `xEnd` one past the last, so no pixel is
    // evaluated only to be found empty.
    var xStart = (cx - outerHalf - 0.5).ceil();
    var xEnd = (cx + outerHalf - 0.5).ceil();
    if (xStart < clipLeft) xStart = clipLeft;
    if (xEnd > clipRight) xEnd = clipRight;
    if (xEnd <= xStart) continue;

    if (solidHalf >= 0) {
      var solidStart = (cx - solidHalf - 0.5).ceil();
      var solidEnd = (cx + solidHalf - 0.5).floor() + 1;
      if (solidStart < xStart) solidStart = xStart;
      if (solidEnd > xEnd) solidEnd = xEnd;
      if (solidEnd > solidStart) {
        _emitRange(sink, y, xStart, solidStart, cx, hx, qy, radius);
        sink.span(y, solidStart, solidEnd, 255);
        _emitRange(sink, y, solidEnd, xEnd, cx, hx, qy, radius);
        continue;
      }
    }
    _emitRange(sink, y, xStart, xEnd, cx, hx, qy, radius);
  }
}

/// The horizontal leg of a right triangle with hypotenuse [hypotenuse] and
/// vertical leg [vertical], or zero when the triangle does not close.
///
/// Zero rather than a negative or a NaN: the caller has already established
/// that the level being solved for is reached somewhere on the row, so a
/// non-closing triangle means it is reached exactly at the arc's start.
double _leg(double hypotenuse, double vertical) {
  final double square = hypotenuse * hypotenuse - vertical * vertical;
  return square > 0 ? math.sqrt(square) : 0;
}

/// Evaluates `[xStart, xEnd)` on row [y] one pixel at a time, coalescing equal
/// coverages into one span.
///
/// The coalescing is not a micro-optimisation. A row that grazes the top or
/// bottom edge has no wholly covered pixel anywhere, so it arrives here in one
/// piece - and across the straight part of such a row the field is constant,
/// which makes it a single span instead of one `fillRect` per pixel.
void _emitRange(
  CoverageSpanSink sink,
  int y,
  int xStart,
  int xEnd,
  double cx,
  double hx,
  double qy,
  double radius,
) {
  var runStart = xStart;
  var runCoverage = -1;
  for (var x = xStart; x < xEnd; x++) {
    // `AnalyticPrimitive.fieldAt` for the uniform-radius rounded box, with the
    // row's half already folded out: fold the pixel into the first quadrant,
    // pull the box in by the radius, and read the distance to that inset box.
    final double qx = ((x + 0.5) - cx).abs() - hx + radius;
    final double field;
    if (qx > 0) {
      field = qy > 0 ? math.sqrt(qx * qx + qy * qy) - radius : qx - radius;
    } else {
      field = qy > 0 ? qy - radius : (qx > qy ? qx : qy) - radius;
    }
    final double coverage = 0.5 - field;
    final int level;
    if (coverage <= 0) {
      level = 0;
    } else if (coverage >= 1) {
      level = 255;
    } else {
      // Round to nearest, the same rule `ScanlineFiller._coverageByte` and
      // `mul255` use, so a run that comes out fully covered here composites
      // identically to the equivalent rectangle fill.
      final int byte = (coverage * 255.0 + 0.5).toInt();
      level = byte > 255 ? 255 : byte;
    }
    if (level == runCoverage) continue;
    if (runCoverage > 0) sink.span(y, runStart, x, runCoverage);
    runStart = x;
    runCoverage = level;
  }
  if (runCoverage > 0) sink.span(y, runStart, xEnd, runCoverage);
}
