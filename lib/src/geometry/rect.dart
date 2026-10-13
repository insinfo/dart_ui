/// Axis-aligned rectangles, stored as edges rather than origin plus extent.
///
/// Clipping, culling and dirty-region merging are all edge comparisons, and
/// storing left/top/right/bottom means those hot paths never recompute
/// `left + width`. The origin-and-size view is still available through
/// [Rect.topLeft] and [Rect.size], which is the cheaper direction to convert.
library;

import 'dart:math' as math;

import 'offset.dart';
import 'size.dart';

/// An immutable axis-aligned rectangle in logical pixels.
///
/// Nothing here normalises an inverted rectangle (one with `right < left`).
/// [isEmpty] reports it, and the operations that could produce one - notably
/// [deflate] - say so in their own documentation. Silently swapping the edges
/// would turn a layout bug into a rectangle that merely looks wrong later.
final class Rect {
  const Rect.fromLTRB(this.left, this.top, this.right, this.bottom);

  const Rect.fromLTWH(double left, double top, double width, double height)
      : this.fromLTRB(left, top, left + width, top + height);

  /// The smallest rectangle enclosing both corners, in any order.
  Rect.fromPoints(Offset a, Offset b)
      : this.fromLTRB(
          math.min(a.dx, b.dx),
          math.min(a.dy, b.dy),
          math.max(a.dx, b.dx),
          math.max(a.dy, b.dy),
        );

  /// The square that encloses the circle of [radius] around [center].
  Rect.fromCircle({required Offset center, required double radius})
      : this.fromCenter(
          center: center,
          width: radius * 2,
          height: radius * 2,
        );

  Rect.fromCenter({
    required Offset center,
    required double width,
    required double height,
  }) : this.fromLTRB(
          center.dx - width / 2,
          center.dy - height / 2,
          center.dx + width / 2,
          center.dy + height / 2,
        );

  /// The canonical empty rectangle, and the answer [intersect] gives when two
  /// rectangles do not overlap.
  static const Rect zero = Rect.fromLTRB(0, 0, 0, 0);

  static const double _giantScalar = 1.0E+9;

  /// A rectangle that covers everything a layer could draw - Flutter's: a
  /// finite stand-in for "unbounded", so arithmetic on it stays finite.
  static const Rect largest =
      Rect.fromLTRB(-_giantScalar, -_giantScalar, _giantScalar, _giantScalar);

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;

  double get height => bottom - top;

  Offset get topLeft => Offset(left, top);

  Offset get topCenter => Offset(left + width / 2, top);

  Offset get topRight => Offset(right, top);

  Offset get centerLeft => Offset(left, top + height / 2);

  Offset get center => Offset(left + width / 2, top + height / 2);

  Offset get centerRight => Offset(right, top + height / 2);

  Offset get bottomLeft => Offset(left, bottom);

  Offset get bottomCenter => Offset(left + width / 2, bottom);

  Offset get bottomRight => Offset(right, bottom);

  Size get size => Size(width, height);

  /// The lesser of the width and height magnitudes.
  double get shortestSide => math.min(width.abs(), height.abs());

  /// The greater of the width and height magnitudes.
  double get longestSide => math.max(width.abs(), height.abs());

  bool get isEmpty => right <= left || bottom <= top;

  /// Whether any edge is NaN.
  bool get hasNaN => left.isNaN || top.isNaN || right.isNaN || bottom.isNaN;

  /// Whether any edge is infinite.
  bool get isInfinite =>
      left >= double.infinity ||
      top >= double.infinity ||
      right >= double.infinity ||
      bottom >= double.infinity;

  /// Whether every edge is finite.
  bool get isFinite =>
      left.isFinite && top.isFinite && right.isFinite && bottom.isFinite;

  /// Half-open on the right and bottom edges, so that tiled rectangles never
  /// both claim the pixel on a shared boundary and a hit test can only ever
  /// land in one of them.
  bool contains(Offset offset) =>
      offset.dx >= left &&
      offset.dx < right &&
      offset.dy >= top &&
      offset.dy < bottom;

  /// Whether the two rectangles share any area.
  ///
  /// Strict comparisons, matching [contains]: rectangles that merely touch
  /// along an edge share no pixel and so do not intersect.
  bool intersects(Rect other) =>
      left < other.right &&
      other.left < right &&
      top < other.bottom &&
      other.top < bottom;

  /// Flutter's name for [intersects].
  bool overlaps(Rect other) => intersects(other);

  /// The overlapping area, or [Rect.zero] when there is none.
  ///
  /// **Differs from Flutter**, whose `intersect` returns the inverted
  /// rectangle (the max of the lefts against the min of the rights) when the
  /// two do not overlap. Both answer [isEmpty] true there, which is the test
  /// a caller should make; the reason for the canonical zero follows.
  ///
  /// Two alternatives were rejected. Returning `null` would push a null check
  /// into every clip and culling site for a case that already has a perfectly
  /// good representation - "nothing to draw" is exactly what an empty
  /// rectangle means, and `Rect?` spreads through the signatures above it.
  /// Returning the raw inverted rectangle (max of the lefts against min of
  /// the rights, as some toolkits do) is worse: `width` and `height` come out
  /// negative and any caller that forgets to test [isEmpty] first computes
  /// with them.
  ///
  /// So callers must test [isEmpty] on the result - or ask [intersects]
  /// beforehand - rather than comparing against a sentinel. The position of a
  /// zero-area overlap is discarded, which is why the answer is the canonical
  /// [Rect.zero] and not a degenerate rectangle at the boundary.
  Rect intersect(Rect other) {
    final l = math.max(left, other.left);
    final t = math.max(top, other.top);
    final r = math.min(right, other.right);
    final b = math.min(bottom, other.bottom);
    if (r <= l || b <= t) return zero;
    return Rect.fromLTRB(l, t, r, b);
  }

  /// The smallest rectangle enclosing both.
  ///
  /// An empty operand is skipped instead of being enclosed. Without that, the
  /// [Rect.zero] returned by a failed [intersect] would drag every subsequent
  /// union back to the origin and inflate dirty regions across the whole
  /// surface.
  Rect union(Rect other) {
    if (other.isEmpty) return this;
    if (isEmpty) return other;
    return Rect.fromLTRB(
      math.min(left, other.left),
      math.min(top, other.top),
      math.max(right, other.right),
      math.max(bottom, other.bottom),
    );
  }

  /// The smallest rectangle enclosing both, as Flutter computes it: plain
  /// minimum and maximum of the edges, an empty operand included - unlike
  /// [union], which skips an empty one.
  Rect expandToInclude(Rect other) => Rect.fromLTRB(
        math.min(left, other.left),
        math.min(top, other.top),
        math.max(right, other.right),
        math.max(bottom, other.bottom),
      );

  /// Grows every edge outward by [delta], as a stroke or shadow extent does.
  Rect inflate(double delta) =>
      Rect.fromLTRB(left - delta, top - delta, right + delta, bottom + delta);

  /// Shrinks every edge inward by [delta].
  ///
  /// Deflating by more than half the width or height inverts the rectangle
  /// rather than clamping it to zero, so an inset larger than its box stays
  /// visible to [isEmpty] instead of being rounded away into a valid-looking
  /// empty box.
  Rect deflate(double delta) => inflate(-delta);

  Rect shift(Offset offset) => translate(offset.dx, offset.dy);

  Rect translate(double dx, double dy) =>
      Rect.fromLTRB(left + dx, top + dy, right + dx, bottom + dy);

  /// Interpolates edge by edge. See [Offset.lerp] for why both ends are
  /// weighted.
  ///
  /// Edges rather than centre-and-size, so that interpolating between two
  /// rectangles that share an edge keeps that edge exactly fixed.
  ///
  /// Flutter's signature: a null end stands for a zero rectangle at the
  /// origin, two nulls give null, and two rectangles never give null.
  static Rect? lerp(Rect? a, Rect? b, double t) {
    if (a == null && b == null) return null;
    a ??= zero;
    b ??= zero;
    final inverse = 1.0 - t;
    return Rect.fromLTRB(
      a.left * inverse + b.left * t,
      a.top * inverse + b.top * t,
      a.right * inverse + b.right * t,
      a.bottom * inverse + b.bottom * t,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Rect &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() => 'Rect.fromLTRB($left, $top, $right, $bottom)';
}
