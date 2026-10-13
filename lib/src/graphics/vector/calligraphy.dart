/// The shape a calligraphic pen leaves: a stroke whose width depends on the
/// direction it runs, as a pen with a flat, angled nib draws.
///
/// The exact shape is the Minkowski sum of the path and the nib - an
/// ellipse [StrokeDescriptor.width] across its long axis and
/// `width * nibStretch` across its short one, turned by `nibAngle`. That
/// sum is the union of, for every segment of the flattened path, the quad
/// between the segment's two ends offset each way by the nib's extent
/// across the segment's direction, and the nib itself at every vertex,
/// which fills the joins. Filled with the nonzero rule, overlapping pieces
/// union into the one shape, every piece wound the same way.
library;

import 'dart:math' as math;

import '../../geometry/offset.dart';
import '../../geometry/path.dart';
import 'primitives.dart';
import 'selectable_objects.dart';
import 'style.dart';

/// [paths], placed by [trafo], drawn with [pen]: the filled outline of the
/// calligraphic stroke, in document coordinates.
Path calligraphicOutline(
  List<VectorPath> paths,
  List<double> trafo,
  StrokeDescriptor pen,
) {
  final double a = pen.width / 2;
  final double b = a * pen.nibStretch.clamp(0.01, 1.0);
  final double angle = pen.nibAngle * math.pi / 180;
  // The nib's axes on a y-down page: counterclockwise as drawn.
  final Offset u = Offset(math.cos(angle), -math.sin(angle));
  final Offset v = Offset(math.sin(angle), math.cos(angle));

  /// The nib's extent along unit direction [n] - its support function.
  double extent(Offset n) {
    final double nu = n.dx * u.dx + n.dy * u.dy;
    final double nv = n.dx * v.dx + n.dy * v.dy;
    return math.sqrt(a * a * nu * nu + b * b * nv * nv);
  }

  final PathBuilder builder = PathBuilder();

  /// [points] as one closed polygon, wound counterclockwise on screen.
  void polygon(List<Offset> points) {
    double area = 0;
    for (int i = 0; i < points.length; i++) {
      final Offset p = points[i];
      final Offset q = points[(i + 1) % points.length];
      area += p.dx * q.dy - q.dx * p.dy;
    }
    final Iterable<Offset> ordered = area < 0 ? points.reversed : points;
    bool first = true;
    for (final Offset p in ordered) {
      if (first) {
        builder.moveTo(p.dx, p.dy);
        first = false;
      } else {
        builder.lineTo(p.dx, p.dy);
      }
    }
    builder.close();
  }

  void nib(Offset at) => polygon(<Offset>[
        for (int i = 0; i < 16; i++)
          at +
              u * (a * math.cos(i * math.pi / 8)) +
              v * (b * math.sin(i * math.pi / 8)),
      ]);

  for (final VectorPath path in paths) {
    final List<Offset> line = _flatten(path, trafo);
    if (line.isEmpty) continue;
    for (int i = 0; i < line.length; i++) {
      nib(line[i]);
      if (i == line.length - 1) break;
      final Offset p = line[i];
      final Offset q = line[i + 1];
      final Offset d = q - p;
      final double length = d.distance;
      if (length < 1e-9) continue;
      final Offset n = Offset(-d.dy / length, d.dx / length);
      final Offset h = n * extent(n);
      polygon(<Offset>[p + h, q + h, q - h, p - h]);
    }
  }
  return builder.build();
}

/// [path] as a polyline in document coordinates: curves cut into sixteen
/// straight pieces each, the start repeated at the end of a closed path.
List<Offset> _flatten(VectorPath path, List<double> trafo) {
  Offset doc(Offset p) => applyTrafoToPoint(p, trafo);
  final List<Offset> out = <Offset>[doc(path.start)];
  Offset pen = path.start;
  for (final Object point in path.points) {
    if (point is CurvePoint) {
      for (int i = 1; i <= 16; i++) {
        final double t = i / 16;
        final double s = 1 - t;
        out.add(doc(pen * (s * s * s) +
            point.control1 * (3 * s * s * t) +
            point.control2 * (3 * s * t * t) +
            point.endpoint * (t * t * t)));
      }
      pen = point.endpoint;
    } else if (point is Offset) {
      out.add(doc(point));
      pen = point;
    }
  }
  if (path.isClosed && out.length > 1) out.add(out.first);
  return out;
}
