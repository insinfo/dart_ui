
import '../../geometry/offset.dart';
import 'bezier.dart';
import 'constants.dart';
import 'primitives.dart';
import 'style.dart';

/// Generates a filled outline path corresponding to stroking [sourcePath]
/// with the given [stroke] descriptor.
List<VectorPath> strokeToOutline(VectorPath sourcePath, StrokeDescriptor stroke) {
  if (stroke.isNone || sourcePath.points.isEmpty) return [];

  final halfWidth = stroke.width / 2.0;

  // 1. Flatten the input path into a discrete polyline
  final polyline = <Offset>[sourcePath.start];
  var current = sourcePath.start;

  for (final pt in sourcePath.points) {
    if (pt is CurvePoint) {
      flattenCubic(current, pt.control1, pt.control2, pt.endpoint, polyline);
      current = pt.endpoint;
    } else if (pt is Offset) {
      polyline.add(pt);
      current = pt;
    }
  }

  if (polyline.length < 2) return [];

  final isClosed = sourcePath.isClosed;
  final n = polyline.length;

  // 2. Compute normal vectors along each segment
  final leftSide = <Offset>[];
  final rightSide = <Offset>[];

  for (var i = 0; i < n; i++) {
    Offset prevPt;
    Offset currPt = polyline[i];
    Offset nextPt;

    if (i == 0) {
      if (isClosed) {
        prevPt = polyline[n - 2];
      } else {
        prevPt = currPt;
      }
      nextPt = polyline[1];
    } else if (i == n - 1) {
      prevPt = polyline[n - 2];
      if (isClosed) {
        nextPt = polyline[1];
      } else {
        nextPt = currPt;
      }
    } else {
      prevPt = polyline[i - 1];
      nextPt = polyline[i + 1];
    }

    // Normal to outgoing segment
    final dOut = nextPt - currPt;
    final lenOut = dOut.distance;
    final nOut = lenOut > 1e-6
        ? Offset(-dOut.dy / lenOut, dOut.dx / lenOut)
        : Offset.zero;

    // Normal to incoming segment
    final dIn = currPt - prevPt;
    final lenIn = dIn.distance;
    final nIn = lenIn > 1e-6
        ? Offset(-dIn.dy / lenIn, dIn.dx / lenIn)
        : Offset.zero;

    Offset avgNormal;
    if (i == 0 && !isClosed) {
      avgNormal = nOut;
    } else if (i == n - 1 && !isClosed) {
      avgNormal = nIn;
    } else {
      avgNormal = Offset(nIn.dx + nOut.dx, nIn.dy + nOut.dy);
      final avgLen = avgNormal.distance;
      if (avgLen > 1e-6) {
        avgNormal = avgNormal / avgLen;
      } else {
        avgNormal = nOut;
      }
    }

    leftSide.add(currPt + avgNormal * halfWidth);
    rightSide.add(currPt - avgNormal * halfWidth);
  }

  // 3. Assemble the closed outline
  final resultPoints = <Object>[];

  // Forward along the left side
  for (var i = 1; i < leftSide.length; i++) {
    resultPoints.add(leftSide[i]);
  }

  // End cap (if open)
  if (!isClosed) {
    _addCap(polyline.last, leftSide.last, rightSide.last, stroke.cap, resultPoints);
  }

  // Backward along the right side
  for (var i = rightSide.length - 1; i >= 0; i--) {
    resultPoints.add(rightSide[i]);
  }

  // Start cap (if open)
  if (!isClosed) {
    _addCap(polyline.first, rightSide.first, leftSide.first, stroke.cap, resultPoints);
  }

  return [
    VectorPath(
      start: leftSide.first,
      points: resultPoints,
      closure: PathClosure.closed,
    ),
  ];
}

void _addCap(Offset center, Offset from, Offset to, LineCap cap, List<Object> out) {
  switch (cap) {
    case LineCap.butt:
      out.add(to);
    case LineCap.square:
      final d = from - to;
      final halfW = d.distance / 2.0;
      final tangent = Offset(-d.dy / (2.0 * halfW), d.dx / (2.0 * halfW)) * halfW;
      out.add(from + tangent);
      out.add(to + tangent);
      out.add(to);
    case LineCap.round:
      final mid = Offset((from.dx + to.dx) / 2.0, (from.dy + to.dy) / 2.0);
      final d = from - to;
      final halfW = d.distance / 2.0;
      if (halfW > 1e-6) {
        final normal = Offset(-d.dy, d.dx) / (2.0 * halfW) * halfW;
        final arcMid = mid + normal;
        out.add(arcMid);
      }
      out.add(to);
  }
}
