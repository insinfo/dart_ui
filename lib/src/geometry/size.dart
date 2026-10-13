/// An extent, kept distinct from [Offset] on purpose.
///
/// A size and a position are both two doubles, but adding two positions is
/// meaningless while adding a size to a position is not. Keeping them as
/// separate types makes the compiler reject the mistake instead of leaving it
/// to show up as a widget drawn at `(width, height)`.
library;

import 'dart:math' as math;

import 'offset.dart';

/// An immutable `width` x `height` extent in logical pixels.
final class Size implements OffsetBase {
  const Size(this.width, this.height);

  /// A copy of [source].
  Size.copy(Size source) : this(source.width, source.height);

  /// Both sides [dimension].
  const Size.square(double dimension) : this(dimension, dimension);

  /// [width] wide and infinitely tall.
  const Size.fromWidth(double width) : this(width, double.infinity);

  /// [height] tall and infinitely wide.
  const Size.fromHeight(double height) : this(double.infinity, height);

  /// The square that encloses a circle of [radius].
  const Size.fromRadius(double radius) : this(radius * 2.0, radius * 2.0);

  static const Size zero = Size(0, 0);

  /// Both sides infinite.
  static const Size infinite = Size(double.infinity, double.infinity);

  final double width;
  final double height;

  @override
  bool get isInfinite => width >= double.infinity || height >= double.infinity;

  @override
  bool get isFinite => width.isFinite && height.isFinite;

  /// The lesser of the two magnitudes.
  double get shortestSide => math.min(width.abs(), height.abs());

  /// The greater of the two magnitudes.
  double get longestSide => math.max(width.abs(), height.abs());

  /// Width and height swapped.
  Size get flipped => Size(height, width);

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

  /// Integer division of each side, as doubles.
  Size operator ~/(double operand) =>
      Size((width ~/ operand).toDouble(), (height ~/ operand).toDouble());

  /// The remainder of each side.
  Size operator %(double operand) => Size(width % operand, height % operand);

  /// Flutter's: a [Size] minus a [Size] is the [Offset] between them, and a
  /// [Size] minus an [Offset] is a [Size] shrunk by it.
  OffsetBase operator -(OffsetBase other) => switch (other) {
        Size() => Offset(width - other.width, height - other.height),
        Offset() => Size(width - other.dx, height - other.dy),
        _ => throw ArgumentError.value(
            other, 'other', 'must be an Offset or a Size'),
      };

  /// This size grown by [other].
  Size operator +(Offset other) => Size(width + other.dx, height + other.dy);

  @override
  bool operator <(OffsetBase other) {
    final (double w, double h) = _sides(other);
    return width < w && height < h;
  }

  @override
  bool operator <=(OffsetBase other) {
    final (double w, double h) = _sides(other);
    return width <= w && height <= h;
  }

  @override
  bool operator >(OffsetBase other) {
    final (double w, double h) = _sides(other);
    return width > w && height > h;
  }

  @override
  bool operator >=(OffsetBase other) {
    final (double w, double h) = _sides(other);
    return width >= w && height >= h;
  }

  static (double, double) _sides(OffsetBase other) => switch (other) {
        Size(:final double width, :final double height) => (width, height),
        Offset(:final double dx, :final double dy) => (dx, dy),
        _ => throw ArgumentError.value(
            other, 'other', 'must be an Offset or a Size'),
      };

  /// The corners, edge midpoints and centre of the rectangle of this size
  /// whose top-left corner is [origin].
  Offset topLeft(Offset origin) => origin;

  Offset topCenter(Offset origin) => Offset(origin.dx + width / 2.0, origin.dy);

  Offset topRight(Offset origin) => Offset(origin.dx + width, origin.dy);

  Offset centerLeft(Offset origin) =>
      Offset(origin.dx, origin.dy + height / 2.0);

  Offset center(Offset origin) =>
      Offset(origin.dx + width / 2.0, origin.dy + height / 2.0);

  Offset centerRight(Offset origin) =>
      Offset(origin.dx + width, origin.dy + height / 2.0);

  Offset bottomLeft(Offset origin) => Offset(origin.dx, origin.dy + height);

  Offset bottomCenter(Offset origin) =>
      Offset(origin.dx + width / 2.0, origin.dy + height);

  Offset bottomRight(Offset origin) =>
      Offset(origin.dx + width, origin.dy + height);

  /// See [Offset.lerp] for why both ends are weighted, and for Flutter's null
  /// handling: a null end stands for [zero].
  static Size? lerp(Size? a, Size? b, double t) {
    if (b == null) return a == null ? null : a * (1.0 - t);
    if (a == null) return b * t;
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
