/// The two-dimensional vector every other geometric type is built from.
///
/// One type carries both meanings a UI needs - a point in a coordinate space
/// and a displacement between two points - because the arithmetic is the same
/// and a separate `Point`/`Vector` pair would force conversions at every
/// layout and hit-test boundary without catching a single real bug.
library;

import 'dart:math' as math;

/// An immutable `(dx, dy)` pair in logical pixels.
///
/// Values are unconstrained: infinities appear in unbounded layout
/// constraints and NaN appears when a caller divides by zero. Neither is
/// rejected here, because clamping at the leaf type would hide the arithmetic
/// that produced it from the layer that can actually explain it.
final class Offset {
  const Offset(this.dx, this.dy);

  /// The origin, and the additive identity.
  static const Offset zero = Offset(0, 0);

  final double dx;
  final double dy;

  /// Cheaper than [distance] and enough for any comparison or radius test,
  /// since squaring preserves ordering for non-negative magnitudes.
  double get distanceSquared => dx * dx + dy * dy;

  double get distance => math.sqrt(distanceSquared);

  Offset operator +(Offset other) => Offset(dx + other.dx, dy + other.dy);

  Offset operator -(Offset other) => Offset(dx - other.dx, dy - other.dy);

  Offset operator -() => Offset(-dx, -dy);

  Offset operator *(double factor) => Offset(dx * factor, dy * factor);

  Offset operator /(double divisor) => Offset(dx / divisor, dy / divisor);

  /// Linear interpolation, weighting both ends rather than the shorter
  /// `a + (b - a) * t`.
  ///
  /// The weighted form is exact at `t == 0` and `t == 1`, so an animation
  /// that runs to completion lands on its declared target instead of a value
  /// one ulp away from it. `t` is not clamped: extrapolation is what spring
  /// and overshoot curves need.
  static Offset lerp(Offset a, Offset b, double t) {
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
