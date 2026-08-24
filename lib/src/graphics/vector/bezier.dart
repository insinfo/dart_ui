

import 'dart:math' as math;

import '../../geometry/offset.dart';
import '../../geometry/path.dart';
import '../../geometry/rect.dart';
import 'constants.dart';
import 'primitives.dart';
import 'selectable_objects.dart';

// ---------------------------------------------------------------------------
// Evaluation & Derivatives
// ---------------------------------------------------------------------------

/// Evaluates a cubic Bézier curve at parameter [t] ∈ [0.0, 1.0].
Offset evaluateCubic(Offset p0, Offset p1, Offset p2, Offset p3, double t) {
  final u = 1.0 - t;
  final tt = t * t;
  final uu = u * u;
  final uuu = uu * u;
  final ttt = tt * t;

  return Offset(
    uuu * p0.dx + 3.0 * uu * t * p1.dx + 3.0 * u * tt * p2.dx + ttt * p3.dx,
    uuu * p0.dy + 3.0 * uu * t * p1.dy + 3.0 * u * tt * p2.dy + ttt * p3.dy,
  );
}

/// Evaluates the tangent vector (derivative) of a cubic Bézier curve at parameter [t].
Offset evaluateCubicDerivative(
    Offset p0, Offset p1, Offset p2, Offset p3, double t) {
  final u = 1.0 - t;
  return Offset(
    3.0 * u * u * (p1.dx - p0.dx) +
        6.0 * u * t * (p2.dx - p1.dx) +
        3.0 * t * t * (p3.dx - p2.dx),
    3.0 * u * u * (p1.dy - p0.dy) +
        6.0 * u * t * (p2.dy - p1.dy) +
        3.0 * t * t * (p3.dy - p2.dy),
  );
}

/// Evaluates a quadratic Bézier curve at parameter [t] ∈ [0.0, 1.0].
Offset evaluateQuadratic(Offset p0, Offset p1, Offset p2, double t) {
  final u = 1.0 - t;
  return Offset(
    u * u * p0.dx + 2.0 * u * t * p1.dx + t * t * p2.dx,
    u * u * p0.dy + 2.0 * u * t * p1.dy + t * t * p2.dy,
  );
}

// ---------------------------------------------------------------------------
// Subdivision (De Casteljau's algorithm)
// ---------------------------------------------------------------------------

/// Splits a cubic Bézier curve at parameter [t] into two curves.
///
/// Returns `(left, right)` where each curve is represented as `[p0, p1, p2, p3]`.
(List<Offset>, List<Offset>) splitCubic(
    Offset p0, Offset p1, Offset p2, Offset p3, double t) {
  final p01 = Offset.lerp(p0, p1, t);
  final p12 = Offset.lerp(p1, p2, t);
  final p23 = Offset.lerp(p2, p3, t);

  final p012 = Offset.lerp(p01, p12, t);
  final p123 = Offset.lerp(p12, p23, t);

  final p0123 = Offset.lerp(p012, p123, t);

  return (
    [p0, p01, p012, p0123],
    [p0123, p123, p23, p3],
  );
}

/// Splits a quadratic Bézier curve at parameter [t] into two curves.
(List<Offset>, List<Offset>) splitQuadratic(
    Offset p0, Offset p1, Offset p2, double t) {
  final p01 = Offset.lerp(p0, p1, t);
  final p12 = Offset.lerp(p1, p2, t);
  final p012 = Offset.lerp(p01, p12, t);

  return (
    [p0, p01, p012],
    [p012, p12, p2],
  );
}

// ---------------------------------------------------------------------------
// Extrema and Tight Bounds
// ---------------------------------------------------------------------------

/// Finds the parameter values t ∈ (0, 1) where the 1D cubic polynomial derivative is 0.
List<double> cubicExtremaRoots(
    double v0, double v1, double v2, double v3) {
  final a = 3.0 * (-v0 + 3.0 * v1 - 3.0 * v2 + v3);
  final b = 6.0 * (v0 - 2.0 * v1 + v2);
  final c = 3.0 * (v1 - v0);

  final roots = <double>[];

  if (a.abs() < 1e-9) {
    if (b.abs() > 1e-9) {
      final t = -c / b;
      if (t > 0.0 && t < 1.0) roots.add(t);
    }
  } else {
    final disc = b * b - 4.0 * a * c;
    if (disc >= 0) {
      final s = math.sqrt(disc);
      final t1 = (-b + s) / (2.0 * a);
      final t2 = (-b - s) / (2.0 * a);
      if (t1 > 0.0 && t1 < 1.0) roots.add(t1);
      if (t2 > 0.0 && t2 < 1.0) roots.add(t2);
    }
  }

  return roots;
}

/// Computes the exact tight bounding box of a cubic Bézier curve.
Rect cubicTightBounds(Offset p0, Offset p1, Offset p2, Offset p3) {
  var minX = math.min(p0.dx, p3.dx);
  var maxX = math.max(p0.dx, p3.dx);
  var minY = math.min(p0.dy, p3.dy);
  var maxY = math.max(p0.dy, p3.dy);

  for (final t in cubicExtremaRoots(p0.dx, p1.dx, p2.dx, p3.dx)) {
    final x = evaluateCubic(p0, p1, p2, p3, t).dx;
    minX = math.min(minX, x);
    maxX = math.max(maxX, x);
  }

  for (final t in cubicExtremaRoots(p0.dy, p1.dy, p2.dy, p3.dy)) {
    final y = evaluateCubic(p0, p1, p2, p3, t).dy;
    minY = math.min(minY, y);
    maxY = math.max(maxY, y);
  }

  return Rect.fromLTRB(minX, minY, maxX, maxY);
}

// ---------------------------------------------------------------------------
// Flattening (Bézier → Polyline)
// ---------------------------------------------------------------------------

/// Recursively subdivides a cubic Bézier curve into a list of straight points.
void flattenCubic(
  Offset p0,
  Offset p1,
  Offset p2,
  Offset p3,
  List<Offset> output, {
  double tolerance = 0.25,
  int depth = 0,
}) {
  // Flatness check: maximum distance from control points to baseline p0-p3
  final dx = p3.dx - p0.dx;
  final dy = p3.dy - p0.dy;
  final lenSq = dx * dx + dy * dy;

  double d1, d2;
  if (lenSq < 1e-6) {
    d1 = pointsDistance(p0, p1);
    d2 = pointsDistance(p0, p2);
  } else {
    d1 = ((p1.dx - p0.dx) * dy - (p1.dy - p0.dy) * dx).abs() / math.sqrt(lenSq);
    d2 = ((p2.dx - p0.dx) * dy - (p2.dy - p0.dy) * dx).abs() / math.sqrt(lenSq);
  }

  if ((d1 + d2 <= tolerance) || depth >= 10) {
    output.add(p3);
    return;
  }

  final (left, right) = splitCubic(p0, p1, p2, p3, 0.5);
  flattenCubic(left[0], left[1], left[2], left[3], output,
      tolerance: tolerance, depth: depth + 1);
  flattenCubic(right[0], right[1], right[2], right[3], output,
      tolerance: tolerance, depth: depth + 1);
}

// ---------------------------------------------------------------------------
// Conversions: VectorPath <-> Path
// ---------------------------------------------------------------------------

/// Converts a collection of [VectorPath]s (with optional affine [trafo]) to an engine [Path].
Path pathFromVectorPaths(List<VectorPath> vectorPaths, [List<double>? trafo]) {
  final builder = PathBuilder();

  for (final vp in vectorPaths) {
    var start = vp.start;
    if (trafo != null && trafo.isNotEmpty) {
      start = applyTrafoToPoint(start, trafo);
    }
    builder.moveTo(start.dx, start.dy);

    for (final pt in vp.points) {
      if (pt is CurvePoint) {
        var cp1 = pt.control1;
        var cp2 = pt.control2;
        var end = pt.endpoint;
        if (trafo != null && trafo.isNotEmpty) {
          cp1 = applyTrafoToPoint(cp1, trafo);
          cp2 = applyTrafoToPoint(cp2, trafo);
          end = applyTrafoToPoint(end, trafo);
        }
        builder.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, end.dx, end.dy);
      } else if (pt is Offset) {
        var target = pt;
        if (trafo != null && trafo.isNotEmpty) {
          target = applyTrafoToPoint(target, trafo);
        }
        builder.lineTo(target.dx, target.dy);
      }
    }

    if (vp.isClosed) {
      builder.close();
    }
  }

  return builder.build();
}

/// Converts an engine [Path] into a list of [VectorPath] objects.
List<VectorPath> vectorPathsFromPath(Path path) {
  if (path.isEmpty) return [];

  final result = <VectorPath>[];
  VectorPath? currentPath;
  var pointIdx = 0;

  for (var i = 0; i < path.verbCount; i++) {
    final verb = path.verbAt(i);
    switch (verb) {
      case verbMoveTo:
        if (currentPath != null) {
          result.add(currentPath);
        }
        final p = path.pointAt(pointIdx++);
        currentPath = VectorPath(start: p, points: []);
      case verbLineTo:
        final p = path.pointAt(pointIdx++);
        currentPath?.points.add(p);
      case verbQuadraticTo:
        // Elevate quadratic to cubic Bézier
        final cp = path.pointAt(pointIdx++);
        final end = path.pointAt(pointIdx++);
        final start = currentPath?.points.isNotEmpty == true
            ? _extractEndpoint(currentPath!.points.last)
            : (currentPath?.start ?? Offset.zero);

        final cp1 = Offset(
          start.dx + 2.0 / 3.0 * (cp.dx - start.dx),
          start.dy + 2.0 / 3.0 * (cp.dy - start.dy),
        );
        final cp2 = Offset(
          end.dx + 2.0 / 3.0 * (cp.dx - end.dx),
          end.dy + 2.0 / 3.0 * (cp.dy - end.dy),
        );
        currentPath?.points.add(CurvePoint(cp1, cp2, end, NodeType.smooth));
      case verbCubicTo:
        final cp1 = path.pointAt(pointIdx++);
        final cp2 = path.pointAt(pointIdx++);
        final end = path.pointAt(pointIdx++);
        currentPath?.points.add(CurvePoint(cp1, cp2, end, NodeType.smooth));
      case verbClose:
        currentPath?.closure = PathClosure.closed;
        if (currentPath != null) {
          result.add(currentPath);
          currentPath = null;
        }
    }
  }

  if (currentPath != null) {
    result.add(currentPath);
  }

  return result;
}

Offset _extractEndpoint(Object point) {
  if (point is CurvePoint) return point.endpoint;
  if (point is Offset) return point;
  return Offset.zero;
}
