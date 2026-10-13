/// The two-dimensional vector every other geometric type is built from.
///
/// One type carries both meanings a UI needs - a point in a coordinate space
/// and a displacement between two points - because the arithmetic is the same
/// and a separate `Point`/`Vector` pair would force conversions at every
/// layout and hit-test boundary without catching a single real bug.
library;

import 'dart:math' as math;

import 'rect.dart';
import 'size.dart';

/// What [Offset] and [Size] share - Flutter's `OffsetBase`: two doubles that
/// can be compared component by component and tested for infinity.
///
/// An interface rather than Flutter's abstract base class with private
/// fields, because here the two types live in separate libraries. The only
/// implementations are [Offset] and [Size]; a comparison against anything
/// else is an [ArgumentError].
abstract interface class OffsetBase {
  /// Whether either component is [double.infinity].
  bool get isInfinite;

  /// Whether both components are finite: neither infinite nor NaN.
  bool get isFinite;

  /// Whether both components are less than [other]'s.
  bool operator <(OffsetBase other);

  /// Whether both components are less than or equal to [other]'s.
  bool operator <=(OffsetBase other);

  /// Whether both components are greater than [other]'s.
  bool operator >(OffsetBase other);

  /// Whether both components are greater than or equal to [other]'s.
  bool operator >=(OffsetBase other);
}

/// The two components of [value], an [Offset] or a [Size].
(double, double) _components(OffsetBase value) => switch (value) {
      Offset(:final double dx, :final double dy) => (dx, dy),
      Size(:final double width, :final double height) => (width, height),
      _ => throw ArgumentError.value(
          value, 'other', 'must be an Offset or a Size'),
    };

/// An immutable `(dx, dy)` pair in logical pixels.
///
/// Values are unconstrained: infinities appear in unbounded layout
/// constraints and NaN appears when a caller divides by zero. Neither is
/// rejected here, because clamping at the leaf type would hide the arithmetic
/// that produced it from the layer that can actually explain it.
final class Offset implements OffsetBase {
  const Offset(this.dx, this.dy);

  /// The offset [distance] long at [direction] radians clockwise from the
  /// positive x axis - y grows downward, as on screen.
  factory Offset.fromDirection(double direction, [double distance = 1.0]) =>
      Offset(distance * math.cos(direction), distance * math.sin(direction));

  /// The origin, and the additive identity.
  static const Offset zero = Offset(0, 0);

  /// Both components infinite: "no position yet", as Flutter uses it.
  static const Offset infinite = Offset(double.infinity, double.infinity);

  final double dx;
  final double dy;

  @override
  bool get isInfinite => dx >= double.infinity || dy >= double.infinity;

  @override
  bool get isFinite => dx.isFinite && dy.isFinite;

  /// The angle from the positive x axis, in radians from -pi to pi -
  /// clockwise is positive, since y grows downward.
  double get direction => math.atan2(dy, dx);

  /// Cheaper than [distance] and enough for any comparison or radius test,
  /// since squaring preserves ordering for non-negative magnitudes.
  double get distanceSquared => dx * dx + dy * dy;

  double get distance => math.sqrt(distanceSquared);

  Offset operator +(Offset other) => Offset(dx + other.dx, dy + other.dy);

  Offset operator -(Offset other) => Offset(dx - other.dx, dy - other.dy);

  Offset operator -() => Offset(-dx, -dy);

  Offset operator *(double factor) => Offset(dx * factor, dy * factor);

  Offset operator /(double divisor) => Offset(dx / divisor, dy / divisor);

  /// Integer division of each component, as doubles.
  Offset operator ~/(double operand) =>
      Offset((dx ~/ operand).toDouble(), (dy ~/ operand).toDouble());

  /// The remainder of each component.
  Offset operator %(double operand) => Offset(dx % operand, dy % operand);

  /// The rectangle with this offset as its top-left corner and [other] as
  /// its size.
  Rect operator &(Size other) =>
      Rect.fromLTWH(dx, dy, other.width, other.height);

  /// Each component multiplied by its own factor.
  Offset scale(double scaleX, double scaleY) =>
      Offset(dx * scaleX, dy * scaleY);

  /// This offset moved by ([translateX], [translateY]).
  Offset translate(double translateX, double translateY) =>
      Offset(dx + translateX, dy + translateY);

  @override
  bool operator <(OffsetBase other) {
    final (double x, double y) = _components(other);
    return dx < x && dy < y;
  }

  @override
  bool operator <=(OffsetBase other) {
    final (double x, double y) = _components(other);
    return dx <= x && dy <= y;
  }

  @override
  bool operator >(OffsetBase other) {
    final (double x, double y) = _components(other);
    return dx > x && dy > y;
  }

  @override
  bool operator >=(OffsetBase other) {
    final (double x, double y) = _components(other);
    return dx >= x && dy >= y;
  }

  /// Linear interpolation, weighting both ends rather than the shorter
  /// `a + (b - a) * t`.
  ///
  /// The weighted form is exact at `t == 0` and `t == 1`, so an animation
  /// that runs to completion lands on its declared target instead of a value
  /// one ulp away from it. `t` is not clamped: extrapolation is what spring
  /// and overshoot curves need.
  ///
  /// Flutter's signature: a null end stands for [zero], and two nulls give
  /// null. With two offsets the result is never null, so `!` is safe.
  static Offset? lerp(Offset? a, Offset? b, double t) {
    if (b == null) return a == null ? null : a * (1.0 - t);
    if (a == null) return b * t;
    final inverse = 1.0 - t;
    return Offset(a.dx * inverse + b.dx * t, a.dy * inverse + b.dy * t);
  }

  /// Compares components with `==`, so this inherits IEEE-754 semantics:
  /// `-0.0` equals `0.0`, and an offset holding NaN is not equal to itself.
  /// Deliberate - an equality that disagreed with the underlying doubles
  /// would make cached-bounds comparisons behave differently from the
  /// arithmetic that produced them.
  @override
  bool operator ==(Object other) =>
      other is Offset && other.dx == dx && other.dy == dy;

  @override
  int get hashCode => Object.hash(dx, dy);

  @override
  String toString() => 'Offset($dx, $dy)';
}
