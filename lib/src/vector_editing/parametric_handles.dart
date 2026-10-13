/// The Shape tool's handles on shapes that are not curves: a rectangle's
/// corners, which round it, and an ellipse's ends, which open it into a pie
/// or an arc - CorelDRAW's way of editing a shape without converting it.
library;

import 'dart:math' as math;

import '../geometry/offset.dart';
import '../graphics/vector/constants.dart';
import '../graphics/vector/primitives.dart';

/// Where the handles of a rectangle or an ellipse are, and what dragging one
/// does. Everything is in document coordinates; the shape's transform is
/// applied here.
abstract final class ParametricHandles {
  /// Whether [shape] has handles of its own: a rectangle or an ellipse.
  static bool supports(Object? shape) =>
      shape is VectorRectangle || shape is VectorCircle;

  /// The handles of [shape], in document coordinates.
  ///
  /// A rectangle has one per corner, on the edge where its rounding starts -
  /// on the corner itself while it is square. An ellipse has one where its
  /// outline starts and, once opened, one where it ends.
  static List<Offset> of(PrimitiveObject shape) => switch (shape) {
        VectorRectangle() => <Offset>[
            for (var i = 0; i < 4; i++)
              _toDocument(shape.trafo, _cornerHandle(shape, i)),
          ],
        VectorCircle() => <Offset>[
            _toDocument(shape.trafo, _onEllipse(shape.angle1)),
            if (_isOpen(shape))
              _toDocument(shape.trafo, _onEllipse(shape.angle2)),
          ],
        _ => const <Offset>[],
      };

  /// The handle of [shape] within [tolerance] of [point], nearest first, or
  /// null.
  static int? at(PrimitiveObject shape, Offset point, double tolerance) {
    final List<Offset> handles = of(shape);
    int? best;
    var bestDistance = tolerance;
    for (var i = 0; i < handles.length; i++) {
      final double d = (handles[i] - point).distance;
      if (d <= bestDistance) {
        bestDistance = d;
        best = i;
      }
    }
    return best;
  }

  /// Drags handle [index] of [shape] to [point].
  ///
  /// A rectangle's corner rounds by how far along its edge the pointer is,
  /// up to half the shorter side: every corner together, or only this one
  /// when [single] - CorelDRAW's corner lock, open. An ellipse's end turns
  /// to the pointer's angle; dragged inside the outline it makes a pie,
  /// outside an arc. On a whole ellipse the other end stays where the
  /// handle was, so the first drag opens it there.
  static void drag(
    PrimitiveObject shape,
    int index,
    Offset point, {
    bool single = false,
  }) {
    final Offset? local = _toLocal(shape.trafo, point);
    if (local == null) return;
    switch (shape) {
      case VectorRectangle():
        _dragCorner(shape, index, local, single: single);
      case VectorCircle():
        _dragEnd(shape, index, local);
      default:
        return;
    }
    shape.update();
  }

  // --- rectangles -------------------------------------------------------------

  /// The corners clockwise from the start point, `corners`' own order, each
  /// with the edge its handle slides along.
  static (Offset corner, Offset along) _corner(VectorRectangle r, int i) {
    final double x = r.startX;
    final double y = r.startY;
    final double w = r.rectWidth;
    final double h = r.rectHeight;
    return switch (i) {
      0 => (Offset(x, y), Offset(0, h.sign)),
      1 => (Offset(x, y + h), Offset(w.sign, 0)),
      2 => (Offset(x + w, y + h), Offset(0, -h.sign)),
      _ => (Offset(x + w, y), Offset(-w.sign, 0)),
    };
  }

  /// Half the shorter side: the most a corner can round, and what 1.0 in
  /// `corners` means.
  static double _maxRadius(VectorRectangle r) =>
      math.min(r.rectWidth.abs(), r.rectHeight.abs()) / 2;

  static Offset _cornerHandle(VectorRectangle r, int i) {
    final (Offset corner, Offset along) = _corner(r, i);
    final double radius = r.corners[i].clamp(0.0, 1.0) * _maxRadius(r);
    return corner + along * radius;
  }

  static void _dragCorner(
    VectorRectangle r,
    int index,
    Offset local, {
    required bool single,
  }) {
    final double max = _maxRadius(r);
    if (max <= 0) return;
    final (Offset corner, Offset along) = _corner(r, index);
    // How far along the edge, whichever edge of the corner the pointer is
    // nearer: the rounding is the same on both.
    final Offset from = local - corner;
    final Offset across = Offset(-along.dy, along.dx);
    final double onEdge = from.dx * along.dx + from.dy * along.dy;
    final double onOther = -(from.dx * across.dx + from.dy * across.dy);
    final double distance = math.max(onEdge, onOther);
    final double value = (distance / max).clamp(0.0, 1.0);
    if (single) {
      r.corners = List<double>.of(r.corners)..[index] = value;
    } else {
      r.corners = <double>[value, value, value, value];
    }
  }

  // --- ellipses ---------------------------------------------------------------

  static bool _isOpen(VectorCircle c) => !(c.angle1 == 0 && c.angle2 == 0);

  static Offset _onEllipse(double angle) =>
      Offset(0.5 + 0.5 * math.cos(angle), 0.5 + 0.5 * math.sin(angle));

  static void _dragEnd(VectorCircle c, int index, Offset local) {
    final Offset from = local - const Offset(0.5, 0.5);
    if (from.distance < 1e-9) return;
    final double angle = _normalized(math.atan2(from.dy, from.dx));
    // Inside the outline a pie, outside an arc, as CorelDRAW decides.
    c.arcType = from.distance <= 0.5 ? ArcType.pieslice : ArcType.arc;
    if (!_isOpen(c)) {
      // The whole ellipse opens where its one handle was.
      c.angle2 = 0;
      c.angle1 = angle;
    } else if (index == 0) {
      c.angle1 = angle;
    } else {
      c.angle2 = angle;
    }
    // Both ends on 0 would read as the whole ellipse again.
    if (c.angle1 == 0 && c.angle2 == 0) c.angle1 = 1e-6;
  }

  static double _normalized(double angle) {
    const double full = 2 * math.pi;
    final double a = angle % full;
    return a < 0 ? a + full : a;
  }

  // --- transforms ---------------------------------------------------------------

  static Offset _toDocument(List<double> t, Offset p) => Offset(
      t[0] * p.dx + t[2] * p.dy + t[4], t[1] * p.dx + t[3] * p.dy + t[5]);

  static Offset? _toLocal(List<double> t, Offset p) {
    final double det = t[0] * t[3] - t[1] * t[2];
    if (det.abs() < 1e-12) return null;
    final double dx = p.dx - t[4];
    final double dy = p.dy - t[5];
    return Offset(
        (t[3] * dx - t[2] * dy) / det, (-t[1] * dx + t[0] * dy) / det);
  }
}
