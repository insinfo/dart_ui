/// Insets on the four edges of a box.
///
/// Separate from [Rect] because an inset is not a rectangle: `left` and
/// `right` both grow inward, from opposite sides. Reusing a rectangle for the
/// two would make `right` mean "distance from the origin" in one place and
/// "distance from the far edge" in another, which is exactly the confusion
/// that produces padding applied to the wrong side.
///
/// Directionality is modelled as a *second type*, not as a flag on this one.
/// [EdgeInsets] is physical: its `left` is the left of the screen in every
/// locale, forever. [EdgeInsetsDirectional] is logical: its `start` is the
/// edge the reading order begins at, and it becomes `left` or `right` only
/// when [EdgeInsetsGeometry.resolve] is handed a [TextDirection].
///
/// Two types rather than one because a single type with both pairs makes
/// "does this flip in Arabic?" a runtime question about which fields happen to
/// be non-zero. As two, the answer is in the declaration: an [EdgeInsets]
/// inside a right-to-left subtree does not move, and that is a guarantee, not
/// an accident.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../text/shaper.dart' show TextDirection;

/// Insets that may or may not depend on the reading direction.
///
/// Sealed rather than open: the two members below are the whole space -
/// physical edges, and logical ones - and a third would have to define what
/// resolving means all over again. Callers that accept this type promise to
/// call [resolve] before touching any geometry, which is the point of taking
/// it: a widget parameter typed [EdgeInsetsGeometry] accepts both spellings
/// and cannot use either one without first asking which way the text runs.
sealed class EdgeInsetsGeometry {
  const EdgeInsetsGeometry();

  /// Distance in from the top edge. Vertical edges are never directional -
  /// no writing system this framework lays out flows bottom-to-top - so both
  /// members answer this without resolving anything.
  double get top;

  double get bottom;

  /// Total inset along the x axis. Direction-independent even for the
  /// directional member: swapping two numbers does not change their sum.
  double get horizontal;

  double get vertical;

  bool get isZero;

  /// The physical insets these describe when the text runs [direction].
  ///
  /// Idempotent on [EdgeInsets], which returns itself: resolving something
  /// that was never logical must not be able to move it.
  EdgeInsets resolve(TextDirection direction);
}

/// An immutable set of offsets from the four edges of a box, in logical
/// pixels.
///
/// Negative values are allowed and mean the content is pushed *outward* past
/// the edge. They are not rejected because a negative inset is a legitimate
/// way to bleed a shadow or a highlight outside its box, and the layout
/// operations that could go wrong with one - [BoxConstraints.deflate] - clamp
/// at their own boundary rather than trusting the input.
final class EdgeInsets extends EdgeInsetsGeometry {
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

  @override
  final double top;

  final double right;

  @override
  final double bottom;

  /// Total inset along the x axis. Named for the axis rather than the edges
  /// because every caller wants the sum, never the pair.
  @override
  double get horizontal => left + right;

  @override
  double get vertical => top + bottom;

  /// The displacement of the inner box's origin from the outer box's origin,
  /// which is what a parent writes into its child's offset.
  Offset get topLeft => Offset(left, top);

  @override
  bool get isZero => left == 0 && top == 0 && right == 0 && bottom == 0;

  /// Returns `this`.
  ///
  /// The single most important line in this file. A physical inset placed
  /// inside a right-to-left subtree keeps the edges it was written with; only
  /// [EdgeInsetsDirectional] moves. Anything else would mean a caller who
  /// deliberately spelled `left` could not rely on getting `left`.
  @override
  EdgeInsets resolve(TextDirection direction) => this;

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

/// Insets whose horizontal edges are named by the reading order rather than
/// by the screen: [start] is where a line of text begins, [end] where it ends.
///
/// In a left-to-right locale [start] resolves to `left`; in a right-to-left
/// one it resolves to `right`. That is the whole difference from [EdgeInsets],
/// and it is why a label that wants "16 pixels of breathing room before the
/// text and 4 after" writes it once here instead of writing it twice with a
/// locale test in between.
///
/// The vertical edges are shared with [EdgeInsets] and are spelled the same,
/// because they mean the same thing: no writing direction supported here runs
/// up the screen, so a `top` that flipped would be flipping for nothing.
///
/// This type deliberately has no `left`/`right` getters. Exposing them would
/// require picking a direction before one is known, and the only honest answer
/// at that point is a lie in one of the two locales. Call [resolve] instead;
/// the result is an [EdgeInsets] with real edges on it.
final class EdgeInsetsDirectional extends EdgeInsetsGeometry {
  const EdgeInsetsDirectional(this.start, this.top, this.end, this.bottom);

  const EdgeInsetsDirectional.all(double value)
      : start = value,
        top = value,
        end = value,
        bottom = value;

  const EdgeInsetsDirectional.symmetric({
    double horizontal = 0,
    double vertical = 0,
  })  : start = horizontal,
        top = vertical,
        end = horizontal,
        bottom = vertical;

  const EdgeInsetsDirectional.only({
    this.start = 0,
    this.top = 0,
    this.end = 0,
    this.bottom = 0,
  });

  static const EdgeInsetsDirectional zero = EdgeInsetsDirectional.all(0);

  /// The inset at the edge the text starts from: `left` under
  /// [TextDirection.leftToRight], `right` under [TextDirection.rightToLeft].
  final double start;

  @override
  final double top;

  /// The inset at the edge the text runs toward.
  final double end;

  @override
  final double bottom;

  @override
  double get horizontal => start + end;

  @override
  double get vertical => top + bottom;

  @override
  bool get isZero => start == 0 && top == 0 && end == 0 && bottom == 0;

  @override
  EdgeInsets resolve(TextDirection direction) => switch (direction) {
        TextDirection.leftToRight => EdgeInsets(start, top, end, bottom),
        TextDirection.rightToLeft => EdgeInsets(end, top, start, bottom),
      };

  EdgeInsetsDirectional operator +(EdgeInsetsDirectional other) =>
      EdgeInsetsDirectional(
        start + other.start,
        top + other.top,
        end + other.end,
        bottom + other.bottom,
      );

  EdgeInsetsDirectional operator *(double factor) => EdgeInsetsDirectional(
        start * factor,
        top * factor,
        end * factor,
        bottom * factor,
      );

  @override
  bool operator ==(Object other) =>
      other is EdgeInsetsDirectional &&
      other.start == start &&
      other.top == top &&
      other.end == end &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(start, top, end, bottom);

  @override
  String toString() => 'EdgeInsetsDirectional($start, $top, $end, $bottom)';
}
