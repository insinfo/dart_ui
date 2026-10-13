/// A polygon of n corners is an n-gon - its midpoints on its sides - and a
/// smaller midpoint coefficient makes a star.
library;

import 'dart:math' as math;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  List<Offset> outline(VectorPolygon polygon) {
    final VectorPath path = polygon.getInitialPaths().single;
    return <Offset>[path.start, ...path.points.cast<Offset>()];
  }

  /// Whether [b] lies on the segment from [a] to [c].
  bool between(Offset a, Offset b, Offset c) {
    final double cross =
        (b.dx - a.dx) * (c.dy - a.dy) - (b.dy - a.dy) * (c.dx - a.dx);
    return cross.abs() < 1e-9;
  }

  test('six corners make a hexagon, not a twelve-sided shape', () {
    final List<Offset> points = outline(VectorPolygon(cornersNum: 6));
    expect(points, hasLength(12), reason: 'corners and midpoints');
    for (int i = 1; i < 12; i += 2) {
      expect(between(points[i - 1], points[i], points[(i + 1) % 12]), isTrue,
          reason: 'midpoint $i on its side');
    }
  });

  test('corners are evenly spaced on the circle, turned by angle1', () {
    final List<Offset> points =
        outline(VectorPolygon(cornersNum: 5, angle1: 0.3));
    for (int i = 0; i < 5; i++) {
      final Offset corner = points[i * 2] - const Offset(0.5, 0.5);
      expect(corner.distance, closeTo(0.5, 1e-9));
      final double angle = math.atan2(corner.dy, corner.dx);
      final double expected = math.pi / 2 + 0.3 + i * 2 * math.pi / 5;
      expect(math.cos(angle - expected), closeTo(1, 1e-9), reason: 'corner $i');
    }
  });

  test('a midpoint coefficient below one is a star', () {
    final List<Offset> points =
        outline(VectorPolygon(cornersNum: 5, coef2: 0.5));
    final double inner = (points[1] - const Offset(0.5, 0.5)).distance;
    expect(inner, closeTo(0.5 * 0.5 * math.cos(math.pi / 5), 1e-9));
  });
}
