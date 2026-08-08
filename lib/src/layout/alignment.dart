/// Where a smaller box sits inside a larger one.
///
/// Expressed as a fraction of the *leftover* space rather than as an absolute
/// offset, which is what makes one value work at every size: `-1` pins to the
/// leading edge, `0` centres, `1` pins to the trailing edge, and nothing has
/// to be recomputed when either box changes.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';

/// A point in a box, in a coordinate system where the box spans -1 to 1 on
/// both axes.
///
/// Values outside -1..1 are permitted and extrapolate: `Alignment(-2, 0)`
/// places the child a full leftover-width to the left of the leading edge,
/// which is how a slide-in transition is expressed as a single animated
/// alignment. Clamping would make that animation stick at the edge, so this
/// type follows the same rule as `Offset.lerp` and refuses to clamp what the
/// caller may be extrapolating on purpose. Only NaN is rejected, because it
/// silently poisons every offset derived from it.
///
/// Directionality is not modelled: `x == -1` is the physical left edge, not
/// the leading edge of the reading order. Right-to-left support belongs with
/// the layer that carries the locale; see `edge_insets.dart` for the same
/// deferral.
final class Alignment {
  Alignment(this.x, this.y) {
    if (x.isNaN || y.isNaN) {
      throw ArgumentError(
        'Alignment($x, $y) is NaN. Every offset computed from it would be '
        'NaN too, and a box positioned at NaN simply disappears.',
      );
    }
  }

  /// Built without the NaN check, for the constants below. Private so the
  /// check cannot be skipped by accident.
  const Alignment._(this.x, this.y);

  static const Alignment topLeft = Alignment._(-1, -1);
  static const Alignment topCenter = Alignment._(0, -1);
  static const Alignment topRight = Alignment._(1, -1);
  static const Alignment centerLeft = Alignment._(-1, 0);
  static const Alignment center = Alignment._(0, 0);
  static const Alignment centerRight = Alignment._(1, 0);
  static const Alignment bottomLeft = Alignment._(-1, 1);
  static const Alignment bottomCenter = Alignment._(0, 1);
  static const Alignment bottomRight = Alignment._(1, 1);

  /// -1 is the left edge, 1 the right edge.
  final double x;

  /// -1 is the top edge, 1 the bottom edge.
  final double y;

  /// Where a [child]-sized box goes inside a [parent]-sized box, as a
  /// displacement from the parent's origin.
  ///
  /// This is the form layout uses, so it is the one that avoids building a
  /// [Rect] only to read its corner.
  Offset offsetFor(Size child, Size parent) => Offset(
        (parent.width - child.width) / 2 * (1 + x),
        (parent.height - child.height) / 2 * (1 + y),
      );

  /// The point this alignment names inside a box of [size], measured from the
  /// box's own origin. `center` gives the centre, `bottomRight` the far
  /// corner.
  Offset withinSize(Size size) =>
      Offset(size.width / 2 * (1 + x), size.height / 2 * (1 + y));

  /// A [size]-sized rectangle placed inside [rect].
  Rect inscribe(Size size, Rect rect) {
    final Offset offset = offsetFor(size, rect.size);
    return Rect.fromLTWH(
      rect.left + offset.dx,
      rect.top + offset.dy,
      size.width,
      size.height,
    );
  }

  static Alignment lerp(Alignment a, Alignment b, double t) {
    final double inverse = 1.0 - t;
    return Alignment(a.x * inverse + b.x * t, a.y * inverse + b.y * t);
  }

  @override
  bool operator ==(Object other) =>
      other is Alignment && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'Alignment($x, $y)';
}
