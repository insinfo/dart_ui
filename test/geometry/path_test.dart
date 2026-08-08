import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/transform2d.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:test/test.dart';

/// Collects the flattened stream verbatim, so a test can look at contour
/// structure and not only at points.
final class _Recorder implements PolylineSink {
  final List<Offset> points = <Offset>[];
  final List<String> calls = <String>[];

  @override
  void moveTo(double x, double y) {
    calls.add('move');
    points.add(Offset(x, y));
  }

  @override
  void lineTo(double x, double y) {
    calls.add('line');
    points.add(Offset(x, y));
  }

  @override
  void close() => calls.add('close');
}

/// The point on a quadratic Bezier at [t], evaluated independently of the
/// implementation under test.
Offset _quadraticAt(Offset p0, Offset p1, Offset p2, double t) {
  final u = 1 - t;
  return Offset(
    u * u * p0.dx + 2 * u * t * p1.dx + t * t * p2.dx,
    u * u * p0.dy + 2 * u * t * p1.dy + t * t * p2.dy,
  );
}

Offset _cubicAt(Offset p0, Offset p1, Offset p2, Offset p3, double t) {
  final u = 1 - t;
  return Offset(
    u * u * u * p0.dx +
        3 * u * u * t * p1.dx +
        3 * u * t * t * p2.dx +
        t * t * t * p3.dx,
    u * u * u * p0.dy +
        3 * u * u * t * p1.dy +
        3 * u * t * t * p2.dy +
        t * t * t * p3.dy,
  );
}

/// Distance from [point] to the polyline through [polyline].
///
/// The flattening contract is about the distance from the true curve to the
/// *polyline*, not to the nearest emitted vertex - a chord can be within
/// tolerance while its midpoint is far from either end.
double _distanceToPolyline(Offset point, List<Offset> polyline) {
  var best = double.infinity;
  for (var i = 0; i + 1 < polyline.length; i++) {
    final d = _distanceToSegment(point, polyline[i], polyline[i + 1]);
    if (d < best) best = d;
  }
  return best;
}

double _distanceToSegment(Offset p, Offset a, Offset b) {
  final vx = b.dx - a.dx;
  final vy = b.dy - a.dy;
  final lengthSquared = vx * vx + vy * vy;
  if (lengthSquared == 0) return (p - a).distance;
  var t = ((p.dx - a.dx) * vx + (p.dy - a.dy) * vy) / lengthSquared;
  if (t < 0) t = 0;
  if (t > 1) t = 1;
  return (p - Offset(a.dx + t * vx, a.dy + t * vy)).distance;
}

void main() {
  group('builder', () {
    test('stores verbs and points in the order they were written', () {
      final path = (PathBuilder()
            ..moveTo(1, 2)
            ..lineTo(3, 4)
            ..quadraticBezierTo(5, 6, 7, 8)
            ..cubicTo(9, 10, 11, 12, 13, 14)
            ..close())
          .build();

      expect(path.verbCount, 5);
      expect(
        <int>[for (var i = 0; i < path.verbCount; i++) path.verbAt(i)],
        <int>[verbMoveTo, verbLineTo, verbQuadraticTo, verbCubicTo, verbClose],
      );
      expect(path.pointCount, 7);
      expect(path.pointAt(0), const Offset(1, 2));
      expect(path.pointAt(6), const Offset(13, 14));
      expect(pointsPerVerb(verbClose), 0);
      expect(() => pointsPerVerb(99), throwsArgumentError);
    });

    test('a segment with no contour open starts one at the origin', () {
      final path = (PathBuilder()..lineTo(10, 10)).build();

      expect(path.verbAt(0), verbMoveTo);
      expect(path.pointAt(0), Offset.zero);
      expect(path.verbAt(1), verbLineTo);
    });

    test('a segment after close resumes at the closed contour start', () {
      final path = (PathBuilder()
            ..moveTo(5, 5)
            ..lineTo(9, 5)
            ..close()
            ..lineTo(9, 9))
          .build();

      // move, line, close, then the implicit move back to (5, 5), then line.
      expect(path.verbCount, 5);
      expect(path.verbAt(3), verbMoveTo);
      expect(path.pointAt(2), const Offset(5, 5));
    });

    test('close with nothing open emits nothing', () {
      final path = (PathBuilder()
            ..close()
            ..close())
          .build();

      expect(path.isEmpty, isTrue);
      expect(path.bounds, Rect.zero);
      expect(Path.empty.isEmpty, isTrue);
    });

    test('reset keeps the buffers, so rebuilding stops allocating', () {
      final builder = PathBuilder();
      for (var i = 0; i < 4; i++) {
        builder
          ..reset()
          ..addRect(const Rect.fromLTRB(0, 0, 10, 10));
      }
      final growths = builder.bufferGrowths;

      for (var i = 0; i < 100; i++) {
        builder
          ..reset()
          ..addRect(const Rect.fromLTRB(0, 0, 10, 10));
        builder.build();
      }

      expect(builder.bufferGrowths, growths);
      expect(builder.verbCount, 5);
    });

    test('build copies, so the builder may keep going afterwards', () {
      final builder = PathBuilder()..addRect(const Rect.fromLTRB(0, 0, 4, 4));
      final first = builder.build();
      builder.addRect(const Rect.fromLTRB(0, 0, 40, 40));
      final second = builder.build();

      expect(first.bounds, const Rect.fromLTRB(0, 0, 4, 4));
      expect(second.bounds, const Rect.fromLTRB(0, 0, 40, 40));
      expect(first.verbCount, 5);
      expect(second.verbCount, 10);
    });
  });

  group('bounds', () {
    test('are tight on a quadratic, not the control polygon', () {
      // The control point sits at y = 100 but the curve only reaches y = 50.
      final path = (PathBuilder()
            ..moveTo(0, 0)
            ..quadraticBezierTo(50, 100, 100, 0))
          .build();

      expect(path.bounds.top, 0);
      expect(path.bounds.bottom, closeTo(50, 1e-6));
      expect(path.bounds.left, 0);
      expect(path.bounds.right, 100);
    });

    test('are tight on a cubic with both turns inside the segment', () {
      // A vertical S: the extremes are interior, and the control points
      // overstate them by a third.
      final path = (PathBuilder()
            ..moveTo(0, 0)
            ..cubicTo(0, 120, 100, -120, 100, 0))
          .build();

      expect(path.bounds.bottom, closeTo(34.641, 0.01));
      expect(path.bounds.top, closeTo(-34.641, 0.01));
    });

    test('cover every point of a rectangle and an oval', () {
      const rect = Rect.fromLTRB(10, 20, 30, 60);

      expect(Path.rect(rect).bounds, rect);
      final oval = Path.oval(rect).bounds;
      expect(oval.left, closeTo(10, 1e-4));
      expect(oval.top, closeTo(20, 1e-4));
      expect(oval.right, closeTo(30, 1e-4));
      expect(oval.bottom, closeTo(60, 1e-4));
    });
  });

  group('transform', () {
    test('identity gives back the same instance', () {
      final path = Path.rect(const Rect.fromLTRB(0, 0, 10, 10));

      expect(identical(path.transform(Transform2D.identity), path), isTrue);
    });

    test('maps points and recomputes bounds from the mapped geometry', () {
      final path = Path.rect(const Rect.fromLTRB(0, 0, 10, 10));
      final moved = path.transform(
        const Transform2D(2, 0, 0, 2, 5, 5),
      );

      expect(moved.pointAt(0), const Offset(5, 5));
      expect(moved.pointAt(2), const Offset(25, 25));
      expect(moved.bounds, const Rect.fromLTRB(5, 5, 25, 25));
      // The original is untouched: the verb stream is shared but immutable.
      expect(path.bounds, const Rect.fromLTRB(0, 0, 10, 10));
    });

    test('rotated bounds are tighter than the rotated bounding box', () {
      final path = Path.rect(const Rect.fromLTRB(-10, -1, 10, 1));
      final rotated = path.transform(Transform2D.rotation(math.pi / 4));

      // The bounding box of the rotated *box* would be about 15.6 wide; the
      // bounding box of the rotated shape is about 7.8.
      expect(rotated.bounds.width, closeTo(math.sqrt2 * 11, 1e-4));
      expect(
        Transform2D.rotation(math.pi / 4).transformRect(path.bounds).width,
        greaterThan(rotated.bounds.width),
      );
    });
  });

  group('equality', () {
    test('is by content, and the display list interns on it', () {
      final a = Path.rect(const Rect.fromLTRB(1, 2, 3, 4));
      final b = Path.rect(const Rect.fromLTRB(1, 2, 3, 4));
      final c = Path.rect(const Rect.fromLTRB(1, 2, 3, 5));

      expect(a == b, isTrue);
      expect(identical(a, b), isFalse);
      expect(a.hashCode, b.hashCode);
      expect(a == c, isFalse);

      final list = DisplayList();
      expect(list.addPath(a), 0);
      expect(list.addPath(b), 0, reason: 'equal paths intern to one resource');
      expect(list.addPath(c), 1);
      expect(list.pathCount, 2);
    });

    test('a negated zero is the same point as a zero', () {
      final a = (PathBuilder()
            ..moveTo(0, 0)
            ..lineTo(1, 1))
          .build();
      final b = (PathBuilder()
            ..moveTo(-0.0, -0.0)
            ..lineTo(1, 1))
          .build();

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('paths differing only in verb order are not equal', () {
      final a = (PathBuilder()
            ..moveTo(0, 0)
            ..lineTo(1, 0)
            ..lineTo(1, 1))
          .build();
      final b = (PathBuilder()
            ..moveTo(0, 0)
            ..lineTo(1, 1)
            ..lineTo(1, 0))
          .build();

      expect(a == b, isFalse);
    });
  });

  group('flatten', () {
    test('a quadratic stays within tolerance of the true curve', () {
      const p0 = Offset(0, 0);
      const p1 = Offset(50, 100);
      const p2 = Offset(100, 0);
      const tolerance = 0.25;
      final path = (PathBuilder()
            ..moveTo(p0.dx, p0.dy)
            ..quadraticBezierTo(p1.dx, p1.dy, p2.dx, p2.dy))
          .build();

      final flat = path.flatten(tolerance);
      final polyline = <Offset>[
        for (var i = 0; i < flat.pointCount; i++) flat.pointAt(i),
      ];

      expect(polyline.first, p0);
      expect(polyline.last, p2, reason: 'the end point is emitted exactly');
      for (var i = 0; i <= 64; i++) {
        final t = i / 64;
        final onCurve = _quadraticAt(p0, p1, p2, t);
        expect(
          _distanceToPolyline(onCurve, polyline),
          lessThanOrEqualTo(tolerance),
          reason: 'deviation at t = $t',
        );
      }
    });

    test('a cubic stays within tolerance of the true curve', () {
      const p0 = Offset(0, 0);
      const p1 = Offset(0, 120);
      const p2 = Offset(120, -40);
      const p3 = Offset(100, 60);
      const tolerance = 0.1;
      final path = (PathBuilder()
            ..moveTo(p0.dx, p0.dy)
            ..cubicTo(p1.dx, p1.dy, p2.dx, p2.dy, p3.dx, p3.dy))
          .build();

      final flat = path.flatten(tolerance);
      final polyline = <Offset>[
        for (var i = 0; i < flat.pointCount; i++) flat.pointAt(i),
      ];

      expect(polyline.last, p3);
      for (var i = 0; i <= 128; i++) {
        final t = i / 128;
        final onCurve = _cubicAt(p0, p1, p2, p3, t);
        expect(
          _distanceToPolyline(onCurve, polyline),
          lessThanOrEqualTo(tolerance),
          reason: 'deviation at t = $t',
        );
      }
    });

    test('a looser tolerance buys fewer segments', () {
      final path = (PathBuilder()
            ..moveTo(0, 0)
            ..quadraticBezierTo(50, 100, 100, 0))
          .build();

      final fine = path.flatten(0.05).pointCount;
      final coarse = path.flatten(1).pointCount;

      expect(coarse, lessThan(fine));
      // The count follows 1/sqrt(tolerance), so a 20x looser tolerance is
      // about 4.5x fewer segments - asserted loosely, since the point is the
      // relationship and not the constant.
      expect(fine / coarse, greaterThan(3));
    });

    test('tolerance is measured after the transform, in device pixels', () {
      final path = (PathBuilder()
            ..moveTo(0, 0)
            ..quadraticBezierTo(50, 100, 100, 0))
          .build();

      final plain = path.flatten(0.25).pointCount;
      final magnified = path
          .flatten(0.25, transform: const Transform2D.scaling(9, 9))
          .pointCount;

      // Three times the segments for nine times the size: the deviation of a
      // uniform sampling falls as the square of the count.
      expect(magnified, greaterThan(plain * 2));
      expect(magnified, lessThan(plain * 4));
    });

    test('reports contours and whether each was closed', () {
      final path = (PathBuilder()
            ..addRect(const Rect.fromLTRB(0, 0, 10, 10))
            ..moveTo(20, 20)
            ..lineTo(30, 20))
          .build();

      final flat = path.flatten(0.25);

      expect(flat.contourCount, 2);
      expect(flat.contourClosed, <int>[1, 0]);
      expect(flat.contourStarts.last, flat.pointCount);
      expect(
        flat.contourStarts[1] - flat.contourStarts[0],
        4,
        reason: 'a closed contour does not repeat its start point; the '
            'closed flag is what says the last point joins the first',
      );
    });

    test('flattenTo reports the contour structure, not just points', () {
      final recorder = _Recorder();
      Path.rect(const Rect.fromLTRB(0, 0, 2, 2)).flattenTo(recorder);

      expect(recorder.calls, <String>[
        'move',
        'line',
        'line',
        'line',
        'close',
      ]);
      expect(recorder.points.first, Offset.zero);
    });

    test('a curve flattened at a huge scale is capped, not unbounded', () {
      final path = (PathBuilder()
            ..moveTo(0, 0)
            ..cubicTo(0, 1e9, 1e9, 0, 1e9, 1e9))
          .build();

      // One curve can never contribute more than the documented cap.
      expect(path.flatten(0.25).pointCount, kMaxSegmentsPerCurve + 1);
    });
  });

  group('rounded shapes', () {
    test('an oval approximates its circle to better than 0.1%', () {
      const radius = 100.0;
      final path = Path.oval(
        const Rect.fromLTRB(-radius, -radius, radius, radius),
      );

      final flat = path.flatten(0.01);
      for (var i = 0; i < flat.pointCount; i++) {
        final p = flat.pointAt(i);
        expect(
          p.distance,
          closeTo(radius, radius * 0.001),
          reason: 'point $i is off the circle',
        );
      }
    });

    test('over-large uniform radii are reduced, and stay inside the box', () {
      const rect = Rect.fromLTRB(0, 0, 20, 10);
      final path = (PathBuilder()..addRoundedRect(rect, 1000, 1000)).build();

      // The shorter side decides: 10 / (1000 + 1000) is the smallest factor,
      // and it applies to the x radii too.
      expect(_effectiveRadii(path), <double>[5, 5, 5, 5, 5, 5, 5, 5]);
      expect(path.bounds.left, closeTo(0, 1e-4));
      expect(path.bounds.top, closeTo(0, 1e-4));
      expect(path.bounds.right, closeTo(20, 1e-4));
      expect(path.bounds.bottom, closeTo(10, 1e-4));
    });

    test('a zero radius degrades to a plain rectangle', () {
      const rect = Rect.fromLTRB(0, 0, 20, 10);
      final rounded = (PathBuilder()..addRoundedRect(rect, 0, 4)).build();

      expect(rounded.verbCount, Path.rect(rect).verbCount);
      expect(rounded, Path.rect(rect));
    });
  });

  group('per-corner rounded rectangles', () {
    const box = Rect.fromLTRB(0, 0, 100, 100);

    test('each corner keeps its own two radii', () {
      final path = _perCorner(box, 2, 3, 4, 5, 6, 7, 8, 9);

      expect(
        _effectiveRadii(path),
        <double>[2, 3, 4, 5, 6, 7, 8, 9],
        reason: 'nothing overruns a 100 x 100 box, so nothing is scaled',
      );
      // Sampled where it shows: just inside each corner of the bounding box,
      // which the corner's own curve either cuts off or does not.
      expect(_contains(path, const Offset(0.5, 0.5)), isFalse);
      expect(_contains(path, const Offset(99.5, 99.5)), isFalse);
      // The same offset from a corner is inside the shallow one and outside
      // the deep one, which is what "independent" has to mean.
      expect(_contains(path, const Offset(2.2, 0.2)), isTrue);
      expect(_contains(path, const Offset(97.8, 99.8)), isFalse);
      expect(_contains(path, const Offset(50, 50)), isTrue);
      expect(_contains(path, const Offset(0.5, 50)), isTrue);
    });

    test('adjacent radii overrunning an edge scale by one shared factor', () {
      // Top edge: 40 + 40 on 50 gives 0.625, the smallest of the four. Every
      // radius is multiplied by it - including the bottom corners, whose own
      // edge had room to spare.
      const rect = Rect.fromLTRB(0, 0, 50, 60);
      final path = _perCorner(rect, 40, 10, 40, 10, 5, 5, 5, 5);

      expect(_effectiveRadii(path), <double>[
        25, 6.25, // top-left
        25, 6.25, // top-right
        3.125, 3.125, // bottom-right, shrunk although its edge fitted
        3.125, 3.125, // bottom-left
      ]);
      // The proportions the caller asked for survive: 40 : 5 before, 25 :
      // 3.125 after, the same 8 : 1.
      expect(25 / 3.125, 40 / 5);
      expect(path.bounds, const Rect.fromLTRB(0, 0, 50, 60));
      expect(path.verbAt(path.verbCount - 1), verbClose);
    });

    test('the smallest factor over the four edges is the one applied', () {
      // The top edge fits easily (10 + 10 on 50) while the left edge does not
      // (20 + 20 on 20). The vertical overrun still halves the horizontal
      // radii, because one corner's two radii cannot scale apart without
      // changing the shape of its curve.
      const rect = Rect.fromLTRB(0, 0, 50, 20);
      final path = _perCorner(rect, 10, 20, 10, 20, 10, 20, 10, 20);

      expect(
        _effectiveRadii(path),
        <double>[5, 10, 5, 10, 5, 10, 5, 10],
      );
      expect(path.bounds, rect);
    });

    test('a zero radius is a right angle, not a curve of no size', () {
      // Square top-left, rounded everywhere else.
      final path = _perCorner(box, 0, 0, 20, 20, 20, 20, 20, 20);

      // No cubic at the square corner: three rounded corners, so three.
      var cubics = 0;
      for (var i = 0; i < path.verbCount; i++) {
        if (path.verbAt(i) == verbCubicTo) cubics++;
      }
      expect(cubics, 3);

      // The corner point itself is on the outline, and the pixel-sized
      // neighbourhood of it is inside - both of which fail for a corner that
      // has been rounded even slightly.
      expect(_contains(path, const Offset(0.05, 0.05)), isTrue);
      expect(_contains(path, const Offset(1, 1)), isTrue);
      expect(_contains(path, const Offset(99, 1)), isFalse);
    });

    test('a corner with one axis zero is square on both', () {
      // Half a radius cannot describe a corner: the curve would have no
      // extent on one axis and the shape would depend on which axis it was.
      final square = _perCorner(box, 20, 0, 0, 0, 0, 0, 0, 0);

      expect(square, Path.rect(box));
    });

    test('every radius zero is exactly the rectangle', () {
      final none = _perCorner(box, 0, 0, 0, 0, 0, 0, 0, 0);

      expect(none, Path.rect(box));
      expect(none.verbCount, 5, reason: 'no zero-length closing segment');
    });

    test('negative and NaN radii are treated as square corners', () {
      final path = _perCorner(box, -5, -5, double.nan, 10, 0, 0, 0, 0);

      expect(path, Path.rect(box));
    });

    test('an infinite radius rounds as far as the box allows', () {
      const rect = Rect.fromLTRB(0, 0, 40, 20);
      final infinite = (PathBuilder()
            ..addRoundedRect(rect, double.infinity, double.infinity))
          .build();
      // Infinity is read as the longer side, 40, and then reduced by the
      // tightest edge - the same shape a very large finite radius gets, which
      // is the property that matters: "as round as possible" must not be a
      // different shape from "very round".
      final huge = (PathBuilder()..addRoundedRect(rect, 4000, 4000)).build();

      expect(
        _effectiveRadii(infinite),
        <double>[10, 10, 10, 10, 10, 10, 10, 10],
      );
      expect(_effectiveRadii(huge), _effectiveRadii(infinite));
    });

    test('the uniform entry point is exactly the per-corner one', () {
      // The regression guard on the forwarding: same points, same verbs, so
      // the same interned resource.
      for (final radii in <List<double>>[
        <double>[8, 8],
        <double>[12, 4],
        <double>[0, 6],
        <double>[1000, 1000],
      ]) {
        const rect = Rect.fromLTRB(3, 5, 43, 25);
        final uniform =
            (PathBuilder()..addRoundedRect(rect, radii[0], radii[1])).build();
        final perCorner = _perCorner(
          rect,
          radii[0],
          radii[1],
          radii[0],
          radii[1],
          radii[0],
          radii[1],
          radii[0],
          radii[1],
        );

        expect(uniform, perCorner, reason: 'radii $radii');
        expect(uniform.hashCode, perCorner.hashCode);
      }
    });

    test('bounds stay tight on the rectangle after clamping', () {
      for (final path in <Path>[
        _perCorner(box, 2, 3, 4, 5, 6, 7, 8, 9),
        _perCorner(box, 90, 90, 90, 90, 90, 90, 90, 90),
        _perCorner(box, 0, 0, 50, 50, 0, 0, 50, 50),
      ]) {
        expect(path.bounds.left, closeTo(0, 1e-4));
        expect(path.bounds.top, closeTo(0, 1e-4));
        expect(path.bounds.right, closeTo(100, 1e-4));
        expect(path.bounds.bottom, closeTo(100, 1e-4));
      }
    });

    test('addRoundedRectRadii reads the display list order', () {
      final radii = Float32List.fromList(<double>[2, 3, 4, 5, 6, 7, 8, 9]);
      final fromList = (PathBuilder()..addRoundedRectRadii(box, radii)).build();

      expect(fromList, _perCorner(box, 2, 3, 4, 5, 6, 7, 8, 9));

      // And it reads from an offset, since a caller may hold a longer buffer.
      final padded = Float32List.fromList(
        <double>[0, 0, 2, 3, 4, 5, 6, 7, 8, 9],
      );
      expect(
        (PathBuilder()..addRoundedRectRadii(box, padded, 2)).build(),
        fromList,
      );
      expect(
        () => (PathBuilder()..addRoundedRectRadii(box, radii, 1)).build(),
        throwsRangeError,
      );
    });

    test('an empty rectangle has no corners to round', () {
      const empty = Rect.fromLTRB(10, 10, 10, 20);

      expect(_perCorner(empty, 4, 4, 4, 4, 4, 4, 4, 4), Path.rect(empty));
    });
  });
}

Path _perCorner(
  Rect rect,
  double tlx,
  double tly,
  double trx,
  double try_,
  double brx,
  double bry,
  double blx,
  double bly,
) =>
    (PathBuilder()
          ..addRoundedRectPerCorner(
            rect,
            topLeftX: tlx,
            topLeftY: tly,
            topRightX: trx,
            topRightY: try_,
            bottomRightX: brx,
            bottomRightY: bry,
            bottomLeftX: blx,
            bottomLeftY: bly,
          ))
        .build();

/// The eight radii a rounded rectangle actually ended up with, read back out
/// of its points in the display list's order.
///
/// Only valid when all four corners are rounded, which is asserted: the verb
/// stream is then fixed, and every tangent point is at a known index. Reading
/// the geometry back rather than exposing the clamped values keeps the
/// assertion about the shape that was emitted.
List<double> _effectiveRadii(Path path) {
  expect(path.verbCount, 10, reason: 'expected four rounded corners');
  final bounds = path.bounds;
  return <double>[
    path.pointX(0) - bounds.left,
    path.pointY(13) - bounds.top,
    bounds.right - path.pointX(1),
    path.pointY(4) - bounds.top,
    bounds.right - path.pointX(8),
    bounds.bottom - path.pointY(5),
    path.pointX(9) - bounds.left,
    bounds.bottom - path.pointY(12),
  ];
}

/// Whether [point] is inside [path] under the non-zero rule, decided on the
/// flattened outline.
///
/// A test-local answer on purpose: the framework has no point-in-path yet, and
/// a containment test written here shares no arithmetic with the builder it is
/// checking.
bool _contains(Path path, Offset point) {
  final flat = path.flatten(0.01);
  var winding = 0;
  for (var c = 0; c + 1 < flat.contourStarts.length; c++) {
    final start = flat.contourStarts[c];
    final end = flat.contourStarts[c + 1];
    for (var i = start; i < end; i++) {
      final a = flat.pointAt(i);
      final b = flat.pointAt(i + 1 < end ? i + 1 : start);
      if (a.dy <= point.dy) {
        if (b.dy > point.dy && _isLeft(a, b, point) > 0) winding++;
      } else if (b.dy <= point.dy && _isLeft(a, b, point) < 0) {
        winding--;
      }
    }
  }
  return winding != 0;
}

double _isLeft(Offset a, Offset b, Offset p) =>
    (b.dx - a.dx) * (p.dy - a.dy) - (p.dx - a.dx) * (b.dy - a.dy);
