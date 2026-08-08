/// Insets on the four edges of a box.
///
/// Separate from [Rect] because an inset is not a rectangle: `left` and
/// `right` both grow inward, from opposite sides. Reusing a rectangle for the
/// two would make `right` mean "distance from the origin" in one place and
/// "distance from the far edge" in another, which is exactly the confusion
/// that produces padding applied to the wrong side.
///
/// Directionality is deliberately absent. There is no `start`/`end` pair and
/// no text-direction resolution yet, so a right-to-left locale currently gets
/// the same physical edges as a left-to-right one. That is a documented gap,
/// not an oversight: resolving it needs a directionality value threaded
/// through layout, which belongs with the widget layer that will carry the
/// locale.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';

/// An immutable set of offsets from the four edges of a box, in logical
/// pixels.
///
/// Negative values are allowed and mean the content is pushed *outward* past
/// the edge. They are not rejected because a negative inset is a legitimate
/// way to bleed a shadow or a highlight outside its box, and the layout
/// operations that could go wrong with one - [BoxConstraints.deflate] - clamp
/// at their own boundary rather than trusting the input.
final class EdgeInsets {
  const EdgeInsets(this.left, this.top, this.right, this.bottom);

  const EdgeInsets.all(double value)
      : left = value,
        top = value,
        right = value,
        bottom = value;

  const EdgeInsets.symmetric({double horizontal = 0, double vertical = 0})
      : left = horizontal,
        top = vertical,
        right = horizontal,
        bottom = vertical;

  const EdgeInsets.only({
    this.left = 0,
    this.top = 0,
    this.right = 0,
    this.bottom = 0,
  });

  static const EdgeInsets zero = EdgeInsets.all(0);

  final double left;
  final double top;
  final double right;
  final double bottom;

  /// Total inset along the x axis. Named for the axis rather than the edges
  /// because every caller wants the sum, never the pair.
  double get horizontal => left + right;

  double get vertical => top + bottom;

  /// The displacement of the inner box's origin from the outer box's origin,
  /// which is what a parent writes into its child's offset.
  Offset get topLeft => Offset(left, top);

  bool get isZero => left == 0 && top == 0 && right == 0 && bottom == 0;

  /// Shrinks [rect] by these insets.
  ///
  /// Inherits [Rect]'s refusal to normalise: insets wider than the rectangle
  /// produce an inverted rectangle that [Rect.isEmpty] reports, instead of a
  /// valid-looking empty one that hides where the area went.
  Rect deflateRect(Rect rect) => Rect.fromLTRB(
        rect.left + left,
        rect.top + top,
        rect.right - right,
        rect.bottom - bottom,
      );

  Rect inflateRect(Rect rect) => Rect.fromLTRB(
        rect.left - left,
        rect.top - top,
        rect.right + right,
        rect.bottom + bottom,
      );

  /// The size a box must be to hold [size] plus these insets - the answer a
  /// padding node gives its parent.
  Size inflateSize(Size size) =>
      Size(size.width + horizontal, size.height + vertical);

  /// The space left for content inside [size].
  ///
  /// Clamped at zero on both axes, unlike [deflateRect]. A size is handed
  /// straight to a child as a constraint, and a negative extent there is not a
  /// diagnosis anybody reads - it is a constraint no size can satisfy.
  Size deflateSize(Size size) => Size(
        size.width - horizontal < 0 ? 0 : size.width - horizontal,
        size.height - vertical < 0 ? 0 : size.height - vertical,
      );

  EdgeInsets operator +(EdgeInsets other) => EdgeInsets(
        left + other.left,
        top + other.top,
        right + other.right,
        bottom + other.bottom,
      );

  EdgeInsets operator *(double factor) => EdgeInsets(
        left * factor,
        top * factor,
        right * factor,
        bottom * factor,
      );

  @override
  bool operator ==(Object other) =>
      other is EdgeInsets &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() => 'EdgeInsets($left, $top, $right, $bottom)';
}
