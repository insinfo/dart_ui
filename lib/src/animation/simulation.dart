/// Physical simulations: springs and friction, solved in closed form.
///
/// Section 32.1 lists `spring` next to `duration` and `curve`. A spring is
/// different in kind from the other two: it has no duration, because when it
/// ends depends on where it started and how fast it was moving. That is
/// exactly why it feels right for anything a finger let go of - the motion
/// continues from the gesture instead of restarting from a fixed curve.
///
/// ## Why closed form and not step integration
///
/// The usual implementation integrates `F = -kx - cv` with Euler or RK4 once
/// per frame. This file does not, and the reason is the same one that runs
/// through the whole repository: **a frame-rate-dependent result is a
/// non-deterministic result.** A stepped integrator gives a different answer
/// at 60 Hz than at 144 Hz, a different answer again when one frame is late,
/// and a *provably* different answer under a virtual clock than under a real
/// one. Tests would have to assert tolerances wide enough to hide real bugs.
///
/// The damped harmonic oscillator has an exact analytic solution in all three
/// damping regimes, so [SpringSimulation] evaluates `x(t)` directly from `t`.
/// The consequences are worth stating:
///
///   * `x(t)` is independent of how the frame times were spaced. Advancing a
///     virtual clock by 100 ms in one step and in ten steps give bit-identical
///     values;
///   * seeking is free - a simulation can be evaluated at any `t`, forwards or
///     backwards, without replaying;
///   * numerical energy drift, the failure mode where an Euler-integrated
///     spring slowly gains amplitude and never settles, cannot happen because
///     nothing accumulates.
///
/// The cost is that only *linear* systems can be expressed this way. A spring
/// whose stiffness changes mid-flight, or one with a non-linear damper, is out
/// of scope for this file and would need a different mechanism. Declared, not
/// worked around.
library;

import 'dart:math' as math;

/// How close is close enough to call a simulation finished.
///
/// Two independent thresholds, because either one alone is wrong: a spring at
/// its rest position moving fast is not done, and a spring barely moving but
/// far from rest is not done either.
final class Tolerance {
  const Tolerance({
    this.distance = 1e-3,
    this.velocity = 1e-3,
  });

  /// Distance, in logical pixels, below which position error is invisible.
  /// One thousandth of a pixel is far past any display's ability to show it.
  final double distance;

  /// Speed, in logical pixels per second, below which motion is invisible.
  final double velocity;

  static const Tolerance defaultTolerance = Tolerance();

  @override
  String toString() => 'Tolerance(distance: $distance, velocity: $velocity)';
}

/// The contract every physical animation satisfies.
///
/// Time is a [Duration] rather than a bare `double`, so a caller can never mix
/// seconds and milliseconds - a mistake that produces a spring which looks
/// merely "too fast" and is therefore debugged by tuning constants instead of
/// by fixing the unit. The implementations convert once, internally, to
/// seconds, which is the unit the physics is written in.
///
/// [x] and [dx] must be pure functions of [time]: calling them twice with the
/// same argument must give the same answer, and calling them out of order must
/// be legal. That is what makes a simulation seekable.
abstract interface class Simulation {
  /// Position at [time].
  double x(Duration time);

  /// Velocity at [time], in units per second.
  double dx(Duration time);

  /// Whether the simulation has settled within its tolerance by [time].
  bool isDone(Duration time);
}

/// Seconds, as the physics wants them.
double _seconds(Duration time) => time.inMicroseconds / 1000000.0;

/// The constants of a damped harmonic oscillator.
///
/// Expressed as mass/stiffness/damping rather than as "bounciness" and
/// "speed", because those are the terms the closed-form solution is written
/// in and a designer-facing parameterization can always be layered on top -
/// see [SpringDescription.withDampingRatio], which is that layer.
final class SpringDescription {
  const SpringDescription({
    required this.mass,
    required this.stiffness,
    required this.damping,
  });

  /// Builds a spring from the ratio that actually describes how it *feels*.
  ///
  /// The damping ratio is the dimensionless number the regimes are defined
  /// by: below 1 the spring oscillates, exactly 1 is the fastest approach
  /// without overshoot, above 1 it crawls in. Designers reach for this;
  /// nobody has an intuition for a damping coefficient in kg/s.
  factory SpringDescription.withDampingRatio({
    double mass = 1.0,
    double stiffness = 100.0,
    double ratio = 1.0,
  }) {
    if (!(mass > 0)) {
      throw ArgumentError.value(mass, 'mass', 'must be strictly positive');
    }
    if (!(stiffness > 0)) {
      throw ArgumentError.value(
          stiffness, 'stiffness', 'must be strictly positive');
    }
    if (ratio < 0) {
      throw ArgumentError.value(ratio, 'ratio', 'must not be negative');
    }
    return SpringDescription(
      mass: mass,
      stiffness: stiffness,
      damping: ratio * 2.0 * math.sqrt(mass * stiffness),
    );
  }

  final double mass;
  final double stiffness;
  final double damping;

  /// `zeta = c / (2 * sqrt(m * k))`. Exactly 1 is critical damping.
  double get dampingRatio => damping / (2.0 * math.sqrt(mass * stiffness));

  /// The undamped natural frequency, in radians per second.
  double get naturalFrequency => math.sqrt(stiffness / mass);

  /// A snappy default: critically damped, so it never overshoots.
  static final SpringDescription snappy =
      SpringDescription.withDampingRatio(stiffness: 500.0);

  @override
  String toString() => 'SpringDescription(mass: $mass, stiffness: $stiffness, '
      'damping: $damping, ratio: $dampingRatio)';
}

/// Which analytic branch a spring is on.
enum SpringType {
  /// `zeta < 1`. Oscillates around the target, amplitude decaying.
  underDamped,

  /// `zeta == 1`. Reaches the target as fast as possible without crossing it.
  criticallyDamped,

  /// `zeta > 1`. Approaches without crossing, more slowly than critical.
  overDamped,
}

/// A damped harmonic oscillator, evaluated in closed form.
///
/// Solves `m x'' + c x' + k x = 0` for the displacement `x = position - end`,
/// with initial conditions `x(0) = start - end` and `x'(0) = velocity`. The
/// discriminant `c^2 - 4mk` selects the branch:
///
/// | branch | roots | solution |
/// |---|---|---|
/// | over-damped (`> 0`) | real, distinct `r1, r2` | `c1 e^{r1 t} + c2 e^{r2 t}` |
/// | critically damped (`== 0`) | real, repeated `r` | `(c1 + c2 t) e^{r t}` |
/// | under-damped (`< 0`) | complex `r ± i w` | `e^{r t}(c1 cos wt + c2 sin wt)` |
///
/// **Declared limit on the "critically damped" branch.** Exact equality of a
/// computed discriminant to zero is a measure-zero event in floating point, so
/// this class treats `|c^2 - 4mk|` below a relative epsilon as critical. Left
/// strict, a spring built with `ratio: 1.0` would land on the under- or
/// over-damped branch depending on rounding, and the "critically damped
/// springs never overshoot" property - the one everybody relies on - would
/// hold only most of the time. The epsilon is relative to `4mk` so it scales
/// with the constants rather than assuming their magnitude.
final class SpringSimulation implements Simulation {
  SpringSimulation({
    required SpringDescription spring,
    required double start,
    required double end,
    double velocity = 0.0,
    this.tolerance = Tolerance.defaultTolerance,
  })  : _end = end,
        _spring = spring {
    final double m = spring.mass;
    final double k = spring.stiffness;
    final double c = spring.damping;
    if (!(m > 0)) {
      throw ArgumentError.value(m, 'mass', 'must be strictly positive');
    }
    if (!(k > 0)) {
      throw ArgumentError.value(k, 'stiffness', 'must be strictly positive');
    }
    if (c < 0) {
      throw ArgumentError.value(c, 'damping', 'must not be negative');
    }

    final double displacement = start - end;
    final double discriminant = c * c - 4 * m * k;
    // Relative, not absolute: see the class documentation.
    final double criticalEpsilon = 4 * m * k * 1e-12;

    if (discriminant.abs() <= criticalEpsilon) {
      type = SpringType.criticallyDamped;
      final double r = -c / (2 * m);
      _r1 = r;
      _r2 = r;
      _c1 = displacement;
      _c2 = velocity - r * displacement;
    } else if (discriminant > 0) {
      type = SpringType.overDamped;
      final double root = math.sqrt(discriminant);
      final double r1 = (-c - root) / (2 * m);
      final double r2 = (-c + root) / (2 * m);
      _r1 = r1;
      _r2 = r2;
      _c2 = (velocity - r1 * displacement) / (r2 - r1);
      _c1 = displacement - _c2;
    } else {
      type = SpringType.underDamped;
      final double w = math.sqrt(4 * m * k - c * c) / (2 * m);
      final double r = -c / (2 * m);
      _r1 = r;
      _r2 = w;
      _c1 = displacement;
      _c2 = (velocity - r * displacement) / w;
    }
  }

  final SpringDescription _spring;
  final double _end;
  final Tolerance tolerance;

  /// Which analytic branch this spring took.
  late final SpringType type;

  // For the over-damped branch these are the two real roots; for the other two
  // branches `_r1` is the common exponential rate and `_r2` is the angular
  // frequency (under-damped) or a copy of `_r1` (critical).
  late final double _r1;
  late final double _r2;
  late final double _c1;
  late final double _c2;

  /// The constants this simulation was built from.
  SpringDescription get spring => _spring;

  /// The resting position the spring converges to.
  double get end => _end;

  @override
  double x(Duration time) => _end + _displacement(_seconds(time));

  @override
  double dx(Duration time) => _velocity(_seconds(time));

  @override
  bool isDone(Duration time) {
    final double t = _seconds(time);
    return _displacement(t).abs() < tolerance.distance &&
        _velocity(t).abs() < tolerance.velocity;
  }

  double _displacement(double t) {
    switch (type) {
      case SpringType.criticallyDamped:
        return (_c1 + _c2 * t) * math.exp(_r1 * t);
      case SpringType.overDamped:
        return _c1 * math.exp(_r1 * t) + _c2 * math.exp(_r2 * t);
      case SpringType.underDamped:
        return math.exp(_r1 * t) *
            (_c1 * math.cos(_r2 * t) + _c2 * math.sin(_r2 * t));
    }
  }

  double _velocity(double t) {
    switch (type) {
      case SpringType.criticallyDamped:
        final double e = math.exp(_r1 * t);
        return _c2 * e + _r1 * (_c1 + _c2 * t) * e;
      case SpringType.overDamped:
        return _c1 * _r1 * math.exp(_r1 * t) + _c2 * _r2 * math.exp(_r2 * t);
      case SpringType.underDamped:
        final double e = math.exp(_r1 * t);
        final double cosine = math.cos(_r2 * t);
        final double sine = math.sin(_r2 * t);
        return e * (-_c1 * _r2 * sine + _c2 * _r2 * cosine) +
            _r1 * e * (_c1 * cosine + _c2 * sine);
    }
  }

  @override
  String toString() => 'SpringSimulation(${type.name}, end: $_end)';
}

/// Exponential deceleration: what a flung scroll view does after the finger
/// leaves.
///
/// Models `v(t) = v0 * drag^t`, which is the continuous form of "lose a fixed
/// *fraction* of speed per unit time". Integrating gives
/// `x(t) = x0 + v0 * (drag^t - 1) / ln(drag)`, so the whole simulation is two
/// exponentials and no state - the same closed-form argument as
/// [SpringSimulation], and the reason a fling looks identical whether the
/// frames arrived evenly or not.
///
/// [drag] is per second and must be strictly inside `(0, 1)`: at 1 the motion
/// never stops and `ln(drag)` is zero, at 0 it stops instantly and the
/// logarithm diverges. Both are rejected rather than clamped, because either
/// value in a scroll physics constant is a typo, not an intent.
///
/// **Declared limit:** friction here is a pure function of velocity. It has no
/// concept of a boundary, so a fling that would leave the scrollable's extent
/// is this simulation's caller's problem, not this simulation's - clamping
/// inside would silently turn a scroll overshoot into a hard stop with no way
/// for the caller to add a bounce.
final class FrictionSimulation implements Simulation {
  FrictionSimulation({
    required this.drag,
    required double position,
    required double velocity,
    this.tolerance = Tolerance.defaultTolerance,
  })  : _position = position,
        _velocity = velocity {
    if (!(drag > 0.0 && drag < 1.0)) {
      throw ArgumentError.value(
        drag,
        'drag',
        'must be strictly inside (0, 1); at 1 the fling never stops and at 0 '
            'the logarithm that integrates it diverges',
      );
    }
    _dragLog = math.log(drag);
  }

  /// The fraction of velocity surviving one second.
  final double drag;
  final Tolerance tolerance;

  final double _position;
  final double _velocity;
  late final double _dragLog;

  /// Where the fling comes to rest, in the limit. Finite because the integral
  /// of a decaying exponential converges - which is why a fling has a
  /// predictable landing point and can be snapped to one.
  double get finalX => _position - _velocity / _dragLog;

  @override
  double x(Duration time) {
    final double t = _seconds(time);
    return _position +
        _velocity * math.pow(drag, t) / _dragLog -
        _velocity / _dragLog;
  }

  @override
  double dx(Duration time) => _velocity * math.pow(drag, _seconds(time));

  /// Done when the speed drops below the tolerance. Position is not tested:
  /// a fling has no target to be near, only a speed to fall under.
  @override
  bool isDone(Duration time) => dx(time).abs() < tolerance.velocity;

  /// The time at which the fling passes [position], or null when it never
  /// does because it settles short of it.
  ///
  /// Inverting `x(t)` analytically, again rather than stepping until it is
  /// close: a scroll that snaps to an item needs the exact instant, and a
  /// stepped search would give a different one at a different frame rate.
  Duration? timeAtX(double position) {
    if (position == _position) return Duration.zero;
    if (_velocity == 0.0) return null;
    final double ratio = 1.0 + (position - _position) * _dragLog / _velocity;
    if (ratio <= 0.0) return null;
    final double seconds = math.log(ratio) / _dragLog;
    if (seconds < 0.0) return null;
    return Duration(microseconds: (seconds * 1000000.0).round());
  }

  @override
  String toString() => 'FrictionSimulation(drag: $drag, velocity: $_velocity, '
      'finalX: $finalX)';
}
