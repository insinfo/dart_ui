import 'dart:math' as math;

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

    test('rounded rect radii are clamped to half the side', () {
      const rect = Rect.fromLTRB(0, 0, 20, 10);
      final huge =
          (PathBuilder()..addRoundedRect(rect, 1000, 1000)).build().bounds;

      expect(huge.left, closeTo(0, 1e-4));
      expect(huge.top, closeTo(0, 1e-4));
      expect(huge.right, closeTo(20, 1e-4));
      expect(huge.bottom, closeTo(10, 1e-4));
    });

    test('a zero radius degrades to a plain rectangle', () {
      const rect = Rect.fromLTRB(0, 0, 20, 10);
      final rounded = (PathBuilder()..addRoundedRect(rect, 0, 4)).build();

      expect(rounded.verbCount, Path.rect(rect).verbCount);
      expect(rounded, Path.rect(rect));
    });
  });
}
