import '../../geometry/offset.dart';
import 'bezier.dart';
import 'constants.dart';
import 'primitives.dart';

/// Boolean operation types.
enum BooleanOp {
  union,
  intersection,
  difference,
  exclusion,
}

/// Applies a Boolean operation to two vector shapes represented as [VectorPath]s.
List<VectorPath> applyBooleanOp(
  List<VectorPath> shapeA,
  List<VectorPath> shapeB,
  BooleanOp op,
) {
  // Convert both shapes to polyline polygons for clipping
  final polyA = _flattenShape(shapeA);
  final polyB = _flattenShape(shapeB);

  if (polyA.isEmpty) return op == BooleanOp.union ? shapeB : [];
  if (polyB.isEmpty) {
    return op == BooleanOp.difference || op == BooleanOp.union ? shapeA : [];
  }

  List<List<Offset>> resultPolys;
  switch (op) {
    case BooleanOp.union:
      resultPolys = _clipPolygon(polyA, polyB, _ClipMode.union);
    case BooleanOp.intersection:
      resultPolys = _clipPolygon(polyA, polyB, _ClipMode.intersection);
    case BooleanOp.difference:
      resultPolys = _clipPolygon(polyA, polyB, _ClipMode.difference);
    case BooleanOp.exclusion:
      final diffAB = _clipPolygon(polyA, polyB, _ClipMode.difference);
      final diffBA = _clipPolygon(polyB, polyA, _ClipMode.difference);
      resultPolys = [...diffAB, ...diffBA];
  }

  return resultPolys.map((poly) {
    if (poly.isEmpty) return VectorPath(start: Offset.zero, points: []);
    return VectorPath(
      start: poly.first,
      points: poly.sublist(1),
      closure: PathClosure.closed,
    );
  }).toList();
}

// ---------------------------------------------------------------------------
// Sutherland-Hodgman / Weiler-Atherton Polygon Clipping Implementation
// ---------------------------------------------------------------------------

enum _ClipMode { union, intersection, difference }

List<List<Offset>> _flattenShape(List<VectorPath> shape) {
  final polygons = <List<Offset>>[];
  for (final vp in shape) {
    final poly = <Offset>[vp.start];
    var current = vp.start;
    for (final pt in vp.points) {
      if (pt is CurvePoint) {
        flattenCubic(current, pt.control1, pt.control2, pt.endpoint, poly);
        current = pt.endpoint;
      } else if (pt is Offset) {
        poly.add(pt);
        current = pt;
      }
    }
    if (poly.length >= 3) {
      polygons.add(poly);
    }
  }
  return polygons;
}

List<List<Offset>> _clipPolygon(
  List<List<Offset>> subject,
  List<List<Offset>> clip,
  _ClipMode mode,
) {
  if (subject.isEmpty) return [];
  if (clip.isEmpty) return subject;

  // We perform Sutherland-Hodgman clipping against each edge of the clipping polygon.
  var output = List<List<Offset>>.from(subject);

  for (final clipPoly in clip) {
    final nextOutput = <List<Offset>>[];
    for (final subjPoly in output) {
      var currentPolygon = subjPoly;
      for (var i = 0; i < clipPoly.length; i++) {
        final edgeStart = clipPoly[i];
        final edgeEnd = clipPoly[(i + 1) % clipPoly.length];

        currentPolygon =
            _clipAgainstEdge(currentPolygon, edgeStart, edgeEnd, mode);
        if (currentPolygon.isEmpty) break;
      }
      if (currentPolygon.length >= 3) {
        nextOutput.add(currentPolygon);
      }
    }
    output = nextOutput;
  }

  return output;
}

List<Offset> _clipAgainstEdge(
  List<Offset> polygon,
  Offset edgeStart,
  Offset edgeEnd,
  _ClipMode mode,
) {
  if (polygon.isEmpty) return [];

  final outputList = <Offset>[];
  var prevPoint = polygon.last;

  for (final currPoint in polygon) {
    final currInside = _isInside(currPoint, edgeStart, edgeEnd);
    final prevInside = _isInside(prevPoint, edgeStart, edgeEnd);

    if (currInside) {
      if (!prevInside) {
        outputList.add(
            _computeIntersection(prevPoint, currPoint, edgeStart, edgeEnd));
      }
      outputList.add(currPoint);
    } else if (prevInside) {
      outputList
          .add(_computeIntersection(prevPoint, currPoint, edgeStart, edgeEnd));
    }

    prevPoint = currPoint;
  }

  return outputList;
}

bool _isInside(Offset p, Offset edgeStart, Offset edgeEnd) {
  return (edgeEnd.dx - edgeStart.dx) * (p.dy - edgeStart.dy) -
          (edgeEnd.dy - edgeStart.dy) * (p.dx - edgeStart.dx) >=
      0;
}

Offset _computeIntersection(Offset s, Offset e, Offset cp1, Offset cp2) {
  final dc = Offset(cp1.dx - cp2.dx, cp1.dy - cp2.dy);
  final dp = Offset(s.dx - e.dx, s.dy - e.dy);

  final n1 = cp1.dx * cp2.dy - cp1.dy * cp2.dx;
  final n2 = s.dx * e.dy - s.dy * e.dx;

  final denom = dc.dx * dp.dy - dc.dy * dp.dx;
  if (denom.abs() < 1e-9) return s;

  final x = (n1 * dp.dx - n2 * dc.dx) / denom;
  final y = (n1 * dp.dy - n2 * dc.dy) / denom;

  return Offset(x, y);
}
