/// An extent, kept distinct from [Offset] on purpose.
///
/// A size and a position are both two doubles, but adding two positions is
/// meaningless while adding a size to a position is not. Keeping them as
/// separate types makes the compiler reject the mistake instead of leaving it
/// to show up as a widget drawn at `(width, height)`.
library;

import 'offset.dart';

/// An immutable `width` x `height` extent in logical pixels.
final class Size {
  const Size(this.width, this.height);

  static const Size zero = Size(0, 0);

  final double width;
  final double height;

  /// True when the extent encloses no area.
  ///
  /// Negative extents are treated as empty rather than normalised away: a
  /// negative size is almost always a layout bug, and silently flipping it to
  /// a positive one would erase the evidence.
  bool get isEmpty => width <= 0 || height <= 0;

  /// Whether [offset] falls inside the rectangle from the origin to this
  /// extent, treating the range as half-open on the right and bottom edges.
  ///
  /// Half-open so that adjacent tiles never both claim the pixel on their
  /// shared edge.
  bool contains(Offset offset) =>
      offset.dx >= 0 &&
      offset.dx < width &&
      offset.dy >= 0 &&
      offset.dy < height;

  /// Width divided by height, with the degenerate case answered by sign
  /// rather than by an exception.
  ///
  /// A zero height turns up while a widget is still unmeasured, which is a
  /// normal frame, not an error. Reporting an infinity of the same sign as
  /// the width lets the caller's own clamping handle it, and keeps a zero
  /// size from producing NaN.
  double get aspectRatio {
    if (height != 0) return width / height;
    if (width > 0) return double.infinity;
    if (width < 0) return double.negativeInfinity;
    return 0;
  }

  Size operator *(double factor) => Size(width * factor, height * factor);

  Size operator /(double divisor) => Size(width / divisor, height / divisor);

  /// See [Offset.lerp] for why both ends are weighted.
  static Size lerp(Size a, Size b, double t) {
    final inverse = 1.0 - t;
    return Size(
      a.width * inverse + b.width * t,
      a.height * inverse + b.height * t,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Size && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'Size($width, $height)';
}
