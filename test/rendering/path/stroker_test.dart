import 'dart:math' as math;

import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/rendering/path/scanline_filler.dart';
import 'package:dart_ui/src/rendering/path/stroker.dart';
import 'package:test/test.dart';

import 'support.dart';

/// An open contour through [points].
Path polyline(List<Offset> points) {
  final builder = PathBuilder()..moveTo(points.first.dx, points.first.dy);
  for (var i = 1; i < points.length; i++) {
    builder.lineTo(points[i].dx, points[i].dy);
  }
  return builder.build();
}

/// How many times [verb] appears, which is how the tests count contours
/// (`verbMoveTo`) and prove a shape is curved (`verbCubicTo`).
int countVerb(Path path, int verb) {
  var total = 0;
  for (var i = 0; i < path.verbCount; i++) {
    if (path.verbAt(i) == verb) total++;
  }
  return total;
}

/// Bounds of each contour separately, from a finely flattened copy.
///
/// [Path.bounds] answers for the whole outline, which cannot distinguish the
/// outer ring of a stroked closed shape from the inner one.
List<Rect> contourBounds(Path path) {
  final flat = path.flatten(0.001);
  final result = <Rect>[];
  for (var c = 0; c < flat.contourCount; c++) {
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    for (var i = flat.contourStarts[c]; i < flat.contourStarts[c + 1]; i++) {
      final x = flat.pointX(i);
      final y = flat.pointY(i);
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
    result.add(Rect.fromLTRB(minX, minY, maxX, maxY));
  }
  return result;
}

void expectRectCloseTo(Rect actual, Rect expected, double tolerance) {
  expect(actual.left, closeTo(expected.left, tolerance), reason: '$actual');
  expect(actual.top, closeTo(expected.top, tolerance), reason: '$actual');
  expect(actual.right, closeTo(expected.right, tolerance), reason: '$actual');
  expect(actual.bottom, closeTo(expected.bottom, tolerance), reason: '$actual');
}

void expectAllFinite(Path path) {
  for (var i = 0; i < path.pointCount; i++) {
    expect(path.pointX(i).isFinite, isTrue, reason: 'point $i x');
    expect(path.pointY(i).isFinite, isTrue, reason: 'point $i y');
  }
}

SpanRecorder rasterize(Path path, Rect clip) {
  final recorder = SpanRecorder();
  ScanlineFiller().fill(path, clip, recorder);
  expectSpanContract(recorder, clip);
  return recorder;
}

/// Shortest distance from ([px], [py]) to the polyline through [points].
///
/// The independent reference for the coverage cross-check: with round caps and
/// round joins the stroke of a contour is exactly the set of points within half
/// the width of it, and this computes that set without touching any of the
/// stroker's arithmetic - no normals, no offsets, no joins.
double distanceToPolyline(List<Offset> points, double px, double py) {
  var best = double.infinity;
  for (var i = 0; i + 1 < points.length; i++) {
    final a = points[i];
    final b = points[i + 1];
    final dx = b.dx - a.dx;
    final dy = b.dy - a.dy;
    final lengthSquared = dx * dx + dy * dy;
    var t = 0.0;
    if (lengthSquared > 0) {
      t = ((px - a.dx) * dx + (py - a.dy) * dy) / lengthSquared;
      if (t < 0) t = 0;
      if (t > 1) t = 1;
    }
    final ex = px - (a.dx + t * dx);
    final ey = py - (a.dy + t * dy);
    final distance = math.sqrt(ex * ex + ey * ey);
    if (distance < best) best = distance;
  }
  return best;
}

/// Compares a rasterised stroke against the distance field of its centreline.
///
/// Pixels whose centre is within [band] of the boundary are skipped: there the
/// answer is a partial coverage that depends on the exact area of a curved
/// region inside a pixel, which the reference does not compute. Everywhere
/// else the two must agree completely - fully covered inside, untouched
/// outside.
void expectCoverageMatchesDistanceField(
  SpanRecorder recorder,
  List<Offset> centreline,
  double radius,
  Rect clip, {
  double band = 1.0,
}) {
  var checked = 0;
  for (var y = clip.top.floor(); y < clip.bottom.ceil(); y++) {
    for (var x = clip.left.floor(); x < clip.right.ceil(); x++) {
      final distance = distanceToPolyline(centreline, x + 0.5, y + 0.5);
      if ((distance - radius).abs() <= band) continue;
      checked++;
      if (distance < radius) {
        expect(
          recorder.at(x, y),
          255,
          reason: 'pixel ($x, $y) is $distance from the centreline, inside a '
              'stroke of radius $radius, and should be solid\n'
              '${recorder.render(clip.right.ceil(), clip.bottom.ceil())}',
        );
      } else {
        expect(
          recorder.at(x, y),
          0,
          reason: 'pixel ($x, $y) is $distance from the centreline, outside a '
              'stroke of radius $radius, and should be untouched\n'
              '${recorder.render(clip.right.ceil(), clip.bottom.ceil())}',
        );
      }
    }
  }
  expect(checked, greaterThan(100), reason: 'the cross-check tested nothing');
}

void main() {
  late PathStroker stroker;

  setUp(() => stroker = PathStroker());

  group('caps on a straight line', () {
    final line = polyline(<Offset>[const Offset(0, 0), const Offset(100, 0)]);

    test('butt stops exactly at the endpoints', () {
      final outline = stroker.stroke(line, const StrokeStyle(width: 10));

      expect(outline.bounds, const Rect.fromLTRB(0, -5, 100, 5));
      expect(countVerb(outline, verbMoveTo), 1, reason: 'one contour');
      expect(countVerb(outline, verbClose), 1);
      expect(countVerb(outline, verbCubicTo), 0, reason: 'nothing is curved');
      expect(countVerb(outline, verbQuadraticTo), 0);
    });

    test('square extends by half the width at each end', () {
      final outline = stroker.stroke(
        line,
        const StrokeStyle(width: 10, cap: StrokeCap.square),
      );

      expect(outline.bounds, const Rect.fromLTRB(-5, -5, 105, 5));
      expect(countVerb(outline, verbCubicTo), 0);
    });

    test('round extends by half the width and curves', () {
      final outline = stroker.stroke(
        line,
        const StrokeStyle(width: 10, cap: StrokeCap.round),
      );

      // The cap arcs are cubics, so their extremes carry the same 0.027% of
      // the radius that `PathBuilder.addOval` documents.
      expectRectCloseTo(
        outline.bounds,
        const Rect.fromLTRB(-5, -5, 105, 5),
        0.01,
      );
      expect(countVerb(outline, verbCubicTo), greaterThan(0));
      expect(countVerb(outline, verbMoveTo), 1);
    });

    test('a vertical line is stroked identically to a horizontal one', () {
      final vertical = polyline(
        <Offset>[const Offset(0, 0), const Offset(0, 100)],
      );

      final outline = stroker.stroke(vertical, const StrokeStyle(width: 10));

      expect(outline.bounds, const Rect.fromLTRB(-5, 0, 5, 100));
    });
  });

  group('closed contours', () {
    final square = Path.rect(const Rect.fromLTRB(0, 0, 100, 100));

    test('a square strokes to an outer and an inner contour', () {
      final outline = stroker.stroke(square, const StrokeStyle(width: 10));

      expect(countVerb(outline, verbMoveTo), 2, reason: 'outer and inner');
      expect(countVerb(outline, verbClose), 2);
      // Miter joins on right angles: the outer corners are square, so the
      // outline reaches exactly half a width beyond the shape on every side.
      expect(outline.bounds, const Rect.fromLTRB(-5, -5, 105, 105));

      final rings = contourBounds(outline);
      expectRectCloseTo(rings[0], const Rect.fromLTRB(-5, -5, 105, 105), 1e-4);
    });

    test('the hole is the shape inset by half the width', () {
      const clip = Rect.fromLTRB(0, 0, 101, 101);
      final outline = stroker.stroke(square, const StrokeStyle(width: 10));

      final recorder = rasterize(outline, clip);

      expect(recorder.at(50, 50), 0, reason: 'the middle is a hole');
      expect(recorder.at(6, 50), 0, reason: 'just inside the inner edge');
      expect(recorder.at(4, 50), 255, reason: 'just outside the inner edge');
      expect(recorder.at(2, 2), 255, reason: 'the corner is stroked');
      expect(recorder.at(4, 97), 255, reason: 'the corner is stroked');
      expect(recorder.at(7, 94), 0, reason: 'diagonally inside the corner');
    });

    test(
        'a stroked circle has bounds at the radius plus and minus half the '
        'width', () {
      final circle =
          (PathBuilder()..addOval(const Rect.fromLTRB(0, 0, 200, 200))).build();

      final outline = stroker.stroke(circle, const StrokeStyle(width: 20));

      expect(countVerb(outline, verbMoveTo), 2);
      final rings = contourBounds(outline);
      expectRectCloseTo(
          rings[0], const Rect.fromLTRB(-10, -10, 210, 210), 0.05);
      expectRectCloseTo(rings[1], const Rect.fromLTRB(10, 10, 190, 190), 0.05);
    });

    test(
        'a stroked circle keeps its outline half a width from the '
        'centreline everywhere', () {
      final circle =
          (PathBuilder()..addOval(const Rect.fromLTRB(0, 0, 200, 200))).build();

      final outline = stroker.stroke(circle, const StrokeStyle(width: 20));

      // Every point of the outline must sit on one of the two concentric
      // circles, which is a far stronger statement than the bounding box: a
      // control leg solved wrongly bulges between the extremes without moving
      // them.
      final flat = outline.flatten(0.001);
      for (var i = 0; i < flat.pointCount; i++) {
        final dx = flat.pointX(i) - 100;
        final dy = flat.pointY(i) - 100;
        final radius = math.sqrt(dx * dx + dy * dy);
        final nearest = (radius - 110).abs() < (radius - 90).abs() ? 110 : 90;
        expect(
          radius,
          closeTo(nearest.toDouble(), 0.06),
          reason: 'point $i strayed off both offset circles',
        );
      }
    });
  });

  group('joins', () {
    // A narrow V: two arms meeting at (100, 0) with an interior angle of
    // 2 * atan(10 / 100). Sharp enough that the miter runs to ten times the
    // half width, which is what makes the limit observable.
    final v = polyline(<Offset>[
      const Offset(0, -10),
      const Offset(100, 0),
      const Offset(0, 10),
    ]);
    final miterRatio = math.sqrt(10000 + 100) / 10;
    final tipX = 100 + 5 * miterRatio;
    final bevelX = 100 + 5 * 10 / math.sqrt(10100);

    test('a high miter limit produces the spike, at the computed tip', () {
      final outline = stroker.stroke(
        v,
        const StrokeStyle(width: 10, miterLimit: 20),
      );

      expect(miterRatio, greaterThan(10), reason: 'the fixture is sharp');
      expect(outline.bounds.right, closeTo(tipX, 0.01));
      // The tip is a real vertex on the axis of symmetry, not just an extreme.
      var found = false;
      for (var i = 0; i < outline.pointCount; i++) {
        if ((outline.pointX(i) - tipX).abs() < 0.01 &&
            outline.pointY(i).abs() < 0.01) {
          found = true;
        }
      }
      expect(found, isTrue, reason: 'no vertex at the miter tip');
    });

    test('a low miter limit falls back to bevel and grows no spike', () {
      final outline = stroker.stroke(
        v,
        const StrokeStyle(width: 10, miterLimit: 4),
      );

      expect(outline.bounds.right, closeTo(bevelX, 0.01));
      expect(
        outline.bounds.right,
        lessThan(tipX - 40),
        reason: 'the spike survived the limit',
      );
    });

    test('the miter limit is applied at the documented ratio', () {
      // The fixture needs 10.0499 times the half width. A limit a hair above
      // that must miter and a hair below it must bevel; getting the comparison
      // inverted or off by the square root would not show up at limit 4.
      final justOver = stroker.stroke(
        v,
        StrokeStyle(width: 10, miterLimit: miterRatio + 0.01),
      );
      final justUnder = stroker.stroke(
        v,
        StrokeStyle(width: 10, miterLimit: miterRatio - 0.01),
      );

      expect(justOver.bounds.right, closeTo(tipX, 0.01));
      expect(justUnder.bounds.right, closeTo(bevelX, 0.01));
    });

    test('a bevel join is a straight cut and a round join is an arc', () {
      final bevel = stroker.stroke(
        v,
        const StrokeStyle(width: 10, join: StrokeJoin.bevel),
      );
      final round = stroker.stroke(
        v,
        const StrokeStyle(width: 10, join: StrokeJoin.round),
      );

      expect(countVerb(bevel, verbCubicTo), 0);
      expect(bevel.bounds.right, closeTo(bevelX, 0.01));
      expect(countVerb(round, verbCubicTo), greaterThan(0));
      // The round join reaches exactly half a width past the corner, where the
      // bevel cuts the corner off well short of it.
      expect(round.bounds.right, closeTo(105, 0.01));
    });

    test('a round join and a round cap both curve', () {
      final outline = stroker.stroke(
        v,
        const StrokeStyle(
          width: 10,
          cap: StrokeCap.round,
          join: StrokeJoin.round,
        ),
      );

      expect(countVerb(outline, verbCubicTo), greaterThan(4));
      expect(countVerb(outline, verbMoveTo), 1);
    });
  });

  group('degenerate input', () {
    test('a zero width strokes to nothing', () {
      final line = polyline(<Offset>[const Offset(0, 0), const Offset(10, 0)]);

      expect(stroker.stroke(line, const StrokeStyle(width: 0)).isEmpty, isTrue);
      expect(
          stroker.stroke(line, const StrokeStyle(width: -4)).isEmpty, isTrue);
      expect(
        stroker.stroke(line, const StrokeStyle(width: double.nan)).isEmpty,
        isTrue,
      );
      expect(
        stroker.stroke(line, const StrokeStyle(width: double.infinity)).isEmpty,
        isTrue,
      );
    });

    test('a lone moveTo draws a dot, a square or nothing', () {
      final dot = (PathBuilder()..moveTo(10, 10)).build();

      expect(stroker.stroke(dot, const StrokeStyle(width: 10)).isEmpty, isTrue);

      final square = stroker.stroke(
        dot,
        const StrokeStyle(width: 10, cap: StrokeCap.square),
      );
      expect(square.bounds, const Rect.fromLTRB(5, 5, 15, 15));
      expect(countVerb(square, verbCubicTo), 0);

      final round = stroker.stroke(
        dot,
        const StrokeStyle(width: 10, cap: StrokeCap.round),
      );
      expectRectCloseTo(round.bounds, const Rect.fromLTRB(5, 5, 15, 15), 0.01);
      expect(countVerb(round, verbCubicTo), greaterThanOrEqualTo(4));
      expect(countVerb(round, verbMoveTo), 1);
    });

    test('the round dot is a circle all the way round', () {
      // Bounds only pin an arc where it touches its extremes, and those land
      // on the joins between the cubics that make it up - which are exact for
      // any control-leg length at all. Every point has to be on the circle,
      // which is what actually tests the `4/3 tan(sweep / 4)` legs.
      final dot = (PathBuilder()..moveTo(10, 10)).build();

      final outline = stroker.stroke(
        dot,
        const StrokeStyle(width: 10, cap: StrokeCap.round),
      );

      final flat = outline.flatten(0.0005);
      expect(flat.pointCount, greaterThan(50));
      for (var i = 0; i < flat.pointCount; i++) {
        final dx = flat.pointX(i) - 10;
        final dy = flat.pointY(i) - 10;
        expect(
          math.sqrt(dx * dx + dy * dy),
          closeTo(5, 0.02),
          reason: 'point $i is off the circle',
        );
      }
    });

    test('a contour that goes nowhere is the same dot', () {
      final still = (PathBuilder()
            ..moveTo(10, 10)
            ..lineTo(10, 10)
            ..lineTo(10, 10))
          .build();

      expect(
        stroker.stroke(still, const StrokeStyle(width: 10)).isEmpty,
        isTrue,
      );
      expect(
        stroker
            .stroke(still, const StrokeStyle(width: 10, cap: StrokeCap.round))
            .bounds
            .left,
        closeTo(5, 0.01),
      );
    });

    test('a repeated point mid-contour changes nothing that is rasterised', () {
      const clip = Rect.fromLTRB(0, 0, 110, 20);
      final plain =
          polyline(<Offset>[const Offset(5, 10), const Offset(105, 10)]);
      final repeated = polyline(<Offset>[
        const Offset(5, 10),
        const Offset(50, 10),
        const Offset(50, 10),
        const Offset(105, 10),
      ]);

      final a = stroker.stroke(plain, const StrokeStyle(width: 10));
      final b = stroker.stroke(repeated, const StrokeStyle(width: 10));

      expectAllFinite(b);
      expect(b.bounds, a.bounds);
      expect(rasterize(b, clip).spans, rasterize(a, clip).spans);
    });

    test('a contour that doubles back is stroked, not erased', () {
      const clip = Rect.fromLTRB(0, 0, 110, 20);
      final there = polyline(
        <Offset>[const Offset(5, 10), const Offset(100, 10)],
      );
      final andBack = polyline(<Offset>[
        const Offset(5, 10),
        const Offset(100, 10),
        const Offset(5, 10),
      ]);

      final outline = stroker.stroke(andBack, const StrokeStyle(width: 10));

      expectAllFinite(outline);
      expect(outline.bounds, const Rect.fromLTRB(5, 5, 100, 15));
      // Traced twice, so it fills at winding two - which is why the outline is
      // specified as non-zero and not even-odd.
      expect(
        rasterize(outline, clip).spans,
        rasterize(stroker.stroke(there, const StrokeStyle(width: 10)), clip)
            .spans,
      );
    });

    test('a doubled-back end with a round join is capped by the arc', () {
      final andBack = polyline(<Offset>[
        const Offset(5, 10),
        const Offset(100, 10),
        const Offset(5, 10),
      ]);

      final outline = stroker.stroke(
        andBack,
        const StrokeStyle(width: 10, join: StrokeJoin.round),
      );

      // The fold is a half turn, so the round join is a half circle around it
      // and the outline reaches half a width past the far end.
      expect(outline.bounds.right, closeTo(105, 0.01));
    });

    test('very large coordinates stay finite and in proportion', () {
      final huge = polyline(<Offset>[
        const Offset(1e6, 1e6),
        const Offset(3e6, 1e6),
      ]);

      final outline = stroker.stroke(
        huge,
        const StrokeStyle(width: 1e4, cap: StrokeCap.square),
      );

      expectAllFinite(outline);
      expectRectCloseTo(
        outline.bounds,
        const Rect.fromLTRB(1e6 - 5e3, 1e6 - 5e3, 3e6 + 5e3, 1e6 + 5e3),
        1.0,
      );
    });

    test('a cubic whose control points all coincide is skipped', () {
      final path = (PathBuilder()
            ..moveTo(10, 10)
            ..cubicTo(10, 10, 10, 10, 10, 10)
            ..lineTo(50, 10))
          .build();

      final outline = stroker.stroke(path, const StrokeStyle(width: 10));

      expectAllFinite(outline);
      expect(outline.bounds, const Rect.fromLTRB(10, 5, 50, 15));
    });

    test('a cubic with a doubled start control point keeps its tangent', () {
      // The commonest degenerate curve there is: the first control point on
      // top of the start point. The start tangent has to come from the next
      // one instead of from a zero difference.
      final path = (PathBuilder()
            ..moveTo(10, 10)
            ..cubicTo(10, 10, 40, 10, 40, 40))
          .build();

      final outline = stroker.stroke(path, const StrokeStyle(width: 10));

      expectAllFinite(outline);
      // The start is horizontal, so the outline opens exactly half a width
      // above and below (10, 10) and nowhere further left.
      expect(outline.bounds.left, closeTo(10, 0.01));
      expect(outline.bounds.top, closeTo(5, 0.01));
    });
  });

  group('coverage cross-check', () {
    // Round caps and round joins make the stroke exactly the set of points
    // within half the width of the centreline, so a distance field is an
    // independent answer sharing no arithmetic with the stroker.
    const style = StrokeStyle(
      width: 9,
      cap: StrokeCap.round,
      join: StrokeJoin.round,
    );

    test('an L-shaped centreline', () {
      const clip = Rect.fromLTRB(0, 0, 36, 36);
      final centreline = <Offset>[
        const Offset(8, 8),
        const Offset(28, 8),
        const Offset(28, 28),
      ];

      final outline = stroker.stroke(polyline(centreline), style);

      expectCoverageMatchesDistanceField(
        rasterize(outline, clip),
        centreline,
        4.5,
        clip,
      );
    });

    test('a centreline that turns back on itself sharply', () {
      // The corner the inner trim cannot take: the second arm is shorter than
      // the trim its join needs, so this exercises the bevel fallback as well
      // as a nearly doubled-back outer join.
      const clip = Rect.fromLTRB(0, 0, 40, 30);
      final centreline = <Offset>[
        const Offset(6, 15),
        const Offset(32, 12),
        const Offset(14, 18),
      ];

      final outline = stroker.stroke(polyline(centreline), style);

      expectCoverageMatchesDistanceField(
        rasterize(outline, clip),
        centreline,
        4.5,
        clip,
      );
    });

    test('a closed square, both rings at once', () {
      const clip = Rect.fromLTRB(0, 0, 40, 40);
      final centreline = <Offset>[
        const Offset(10, 10),
        const Offset(30, 10),
        const Offset(30, 30),
        const Offset(10, 30),
        const Offset(10, 10),
      ];

      final outline = stroker.stroke(
        Path.rect(const Rect.fromLTRB(10, 10, 30, 30)),
        style,
      );

      expectCoverageMatchesDistanceField(
        rasterize(outline, clip),
        centreline,
        4.5,
        clip,
      );
    });

    test('a zigzag whose segments are shorter than the pen', () {
      // Every inner join here needs a trim longer than the segment it would
      // eat, and every outer join is nearly a full reversal. This is where an
      // outline built from local decisions can wind backwards and punch a hole
      // through the middle of a solid stroke.
      const clip = Rect.fromLTRB(0, 0, 40, 30);
      final centreline = <Offset>[
        for (var i = 0; i < 12; i++) Offset(8 + i * 2.0, i.isEven ? 12 : 16),
      ];

      final outline = stroker.stroke(polyline(centreline), style);

      expectCoverageMatchesDistanceField(
        rasterize(outline, clip),
        centreline,
        4.5,
        clip,
      );
    });

    test('a closed square narrower than the pen, whose hole collapses', () {
      // Half the width exceeds half the square, so the inner offsets pass each
      // other completely and there is no hole left. An inner ring that still
      // encloses something would show up as a hole in the middle of a blob.
      const clip = Rect.fromLTRB(0, 0, 40, 40);
      final centreline = <Offset>[
        const Offset(16, 16),
        const Offset(24, 16),
        const Offset(24, 24),
        const Offset(16, 24),
        const Offset(16, 16),
      ];

      final outline = stroker.stroke(
        Path.rect(const Rect.fromLTRB(16, 16, 24, 24)),
        style,
      );

      expectCoverageMatchesDistanceField(
        rasterize(outline, clip),
        centreline,
        4.5,
        clip,
      );
    });

    test('two curves meeting at a corner', () {
      // Joins between curved edges, where the inner trim runs back along a
      // tangent that the edge itself curves away from.
      // Every bend here is gentler than the pen can follow, so the only thing
      // under test is the join: a curve whose radius of curvature drops below
      // half the width is the separate limitation the library comment states.
      const clip = Rect.fromLTRB(0, 0, 44, 40);
      final path = (PathBuilder()
            ..moveTo(8, 10)
            ..cubicTo(18, 6, 28, 10, 32, 18)
            ..cubicTo(28, 26, 18, 30, 8, 26))
          .build();
      final centreline = <Offset>[
        for (var i = 0; i <= 1500; i++)
          _cubicPoint(
            const Offset(8, 10),
            const Offset(18, 6),
            const Offset(28, 10),
            const Offset(32, 18),
            i / 1500,
          ),
        for (var i = 0; i <= 1500; i++)
          _cubicPoint(
            const Offset(32, 18),
            const Offset(28, 26),
            const Offset(18, 30),
            const Offset(8, 26),
            i / 1500,
          ),
      ];

      final outline = stroker.stroke(path, style);

      expectCoverageMatchesDistanceField(
        rasterize(outline, clip),
        centreline,
        4.5,
        clip,
        band: 1.2,
      );
    });

    test('a cubic centreline', () {
      const clip = Rect.fromLTRB(0, 0, 40, 40);
      final path = (PathBuilder()
            ..moveTo(6, 34)
            ..cubicTo(6, 4, 34, 36, 34, 8))
          .build();
      // The reference for a curve is the curve itself, sampled far more
      // finely than the outline is: 2000 chords put the polyline within a
      // thousandth of a pixel of the true centreline.
      final centreline = <Offset>[
        for (var i = 0; i <= 2000; i++) _cubicAt(i / 2000),
      ];

      final outline = stroker.stroke(path, style);

      expectCoverageMatchesDistanceField(
        rasterize(outline, clip),
        centreline,
        4.5,
        clip,
        band: 1.2,
      );
    });
  });

  group('curve offsets', () {
    test('a quarter arc offsets to a quarter arc of the offset radius', () {
      // The one curve whose offset is exactly a curve of the same kind, so any
      // error in the control-leg solve shows up as a radius that drifts along
      // the arc rather than as a shape that is merely a bit off.
      final quarter = (PathBuilder()
            ..moveTo(100, 0)
            ..cubicTo(100, 55.22847498307933, 55.22847498307933, 100, 0, 100))
          .build();

      final outline = stroker.stroke(quarter, const StrokeStyle(width: 20));

      final flat = outline.flatten(0.001);
      for (var i = 0; i < flat.pointCount; i++) {
        final radius = math.sqrt(
          flat.pointX(i) * flat.pointX(i) + flat.pointY(i) * flat.pointY(i),
        );
        // The butt caps run straight between the two arcs, so only points at
        // one of the two radii or on a cap are legal; the caps are radial, so
        // every point on them is between the radii too.
        expect(radius, greaterThan(89.9));
        expect(radius, lessThan(110.1));
      }
    });

    test('halving the tolerance does not move the outline', () {
      // The subdivision budget controls how many pieces the offset is built
      // from, and pieces that disagree at their shared endpoints would show up
      // as an outline that shifts when the budget changes.
      final curve = (PathBuilder()
            ..moveTo(10, 60)
            ..cubicTo(30, 0, 70, 120, 90, 60))
          .build();
      const style = StrokeStyle(width: 16);

      final coarse = stroker.stroke(curve, style, tolerance: 0.2);
      final fine = stroker.stroke(curve, style, tolerance: 0.005);

      expect(fine.verbCount, greaterThan(coarse.verbCount));
      expectRectCloseTo(fine.bounds, coarse.bounds, 0.05);
    });
  });

  group('reuse', () {
    test('a stroker stops growing its buffers once warm', () {
      final path = (PathBuilder()
            ..addRoundedRect(const Rect.fromLTRB(0, 0, 60, 40), 8, 8))
          .build();
      const style = StrokeStyle(
        width: 6,
        cap: StrokeCap.round,
        join: StrokeJoin.round,
      );

      for (var i = 0; i < 4; i++) {
        stroker.stroke(path, style);
      }
      final warm = stroker.bufferGrowths;
      for (var i = 0; i < 20; i++) {
        stroker.stroke(path, style);
      }

      expect(stroker.bufferGrowths, warm);
    });
  });
}

/// A cubic evaluated straight from its definition, for the references the
/// curved cross-checks sample.
Offset _cubicPoint(Offset p0, Offset p1, Offset p2, Offset p3, double t) {
  final u = 1 - t;
  double at(double a, double b, double c, double d) =>
      u * u * u * a + 3 * u * u * t * b + 3 * u * t * t * c + t * t * t * d;
  return Offset(
    at(p0.dx, p1.dx, p2.dx, p3.dx),
    at(p0.dy, p1.dy, p2.dy, p3.dy),
  );
}

/// The fixture cubic of the single-curve cross-check.
Offset _cubicAt(double t) => _cubicPoint(
      const Offset(6, 34),
      const Offset(6, 4),
      const Offset(34, 36),
      const Offset(34, 8),
      t,
    );
