/// Easing curves: the pure, deterministic half of the animation system.
///
/// Section 32.1 lists `curve` as one of the animation types the framework must
/// offer. Everything in this file is a `const`-constructible, side-effect-free
/// mapping from a normalized progress `t` to a normalized output. That purity
/// is the whole point:
///
///   * a curve can be shared by every control in the tree without a per-owner
///     instance, so declaring one costs nothing per frame (section 6.5);
///   * a golden test can assert an exact number at `t = 0.5`, because the same
///     input can never produce two outputs;
///   * a curve never reads a clock, so it cannot be the reason a test is
///     intermittent.
///
/// **Declared limit:** a [Curve] maps progress to progress. It knows nothing
/// about time, duration, or the value being animated. Anything that needs a
/// clock lives in `clock.dart`; anything that needs a value type lives in
/// `animation.dart`. Curves that overshoot (output outside `[0, 1]`) are legal
/// and expected - an elastic ease is exactly that - so nothing here clamps the
/// *output*. The *input* is clamped, because a curve asked for `t = 1.4` is
/// always a caller arithmetic bug and answering it would hide the bug.
library;

/// A mapping from normalized progress to normalized progress.
///
/// Subclasses implement [transformInternal] and inherit the domain check in
/// [transform]. That split exists so the contract - `t` in `[0, 1]`, and `0`
/// and `1` map to themselves - is enforced in exactly one place and cannot be
/// forgotten by a new curve.
abstract base class Curve {
  const Curve();

  /// The curve's output at [t].
  ///
  /// [t] must be in `[0, 1]`. A value outside that range throws rather than
  /// being clamped: the caller computed it from an elapsed time and a
  /// duration, and a progress of `1.4` means that arithmetic is wrong. Section
  /// 6.6 asks for explicit failure, and clamping here would move the symptom
  /// to a place that cannot explain it.
  ///
  /// The endpoints are answered without consulting the subclass, so every
  /// curve in the framework satisfies `transform(0) == 0` and
  /// `transform(1) == 1` exactly, with no floating-point residue. Animations
  /// therefore land *on* their declared target, not one ulp away from it.
  double transform(double t) {
    if (!(t >= 0.0 && t <= 1.0)) {
      throw ArgumentError.value(
        t,
        't',
        'curve progress must be in [0, 1]; got a value outside the domain, '
            'which means the elapsed/duration ratio that produced it is wrong',
      );
    }
    if (t == 0.0) return 0.0;
    if (t == 1.0) return 1.0;
    return transformInternal(t);
  }

  /// The curve's output for `t` strictly inside `(0, 1)`.
  ///
  /// Implementations may assume the domain check already happened and that
  /// the endpoints were already answered.
  double transformInternal(double t);

  /// This curve, run backwards: `1 - transform(1 - t)`.
  ///
  /// The standard way to turn an "ease in" into an "ease out" without writing
  /// a second set of control points that can drift out of sync with the first.
  Curve get flipped => FlippedCurve(this);
}

/// The identity curve. `transform(t) == t`.
final class LinearCurve extends Curve {
  const LinearCurve();

  @override
  double transformInternal(double t) => t;

  @override
  String toString() => 'Curves.linear';
}

/// A cubic Bézier easing curve, in the shape CSS and every design tool use.
///
/// The curve runs from `(0, 0)` to `(1, 1)` with control points `(a, b)` and
/// `(c, d)`. Only `a` and `c` - the *x* coordinates - are constrained to
/// `[0, 1]`; that constraint is what makes the curve a function of `x` at all,
/// because an x-control point outside the unit interval lets the curve fold
/// back on itself and a given progress would then have several outputs. `b`
/// and `d` are unconstrained, which is how overshoot ("back", "anticipate")
/// curves are expressed.
///
/// ## The solver, and its declared limits
///
/// A cubic Bézier is defined parametrically - `x(u)` and `y(u)` for a
/// parameter `u` - but an animation asks the opposite question: *given x,
/// what is y?* There is no closed form, so [transformInternal] inverts `x(u)`
/// numerically.
///
/// The method is **bisection**, not Newton-Raphson. Newton converges faster on
/// average but needs a derivative that can vanish (a curve with `a == 0` has
/// `x'(0) == 0`), and its iteration count then depends on the control points -
/// which would make the *cost* of a curve data-dependent and the *result*
/// harder to reason about. Bisection halves the bracket every step
/// unconditionally, so the error after `n` steps is exactly `2^-n` regardless
/// of the curve. `x(u)` is monotonically non-decreasing on `[0, 1]` for legal
/// control points, which is the precondition bisection needs.
///
/// * tolerance: [solverTolerance] = `1e-9` on the *x* coordinate;
/// * iteration cap: [maxSolverIterations] = `48`.
///
/// `2^-48` is about `3.6e-15`, comfortably past the tolerance, so the cap can
/// never be reached by a curve with legal control points. It is a hard stop,
/// not a budget: if it ever trips, the invariant this class validates in its
/// constructor has been violated some other way, and it throws rather than
/// returning a silently wrong number.
final class Cubic extends Curve {
  const Cubic(this.a, this.b, this.c, this.d);

  /// x of the first control point. Must be in `[0, 1]`.
  final double a;

  /// y of the first control point. Unconstrained; values outside `[0, 1]`
  /// produce undershoot or overshoot.
  final double b;

  /// x of the second control point. Must be in `[0, 1]`.
  final double c;

  /// y of the second control point. Unconstrained.
  final double d;

  /// The accepted error on the *x* coordinate when inverting `x(u)`.
  static const double solverTolerance = 1e-9;

  /// The hard stop on bisection steps. Unreachable for legal control points;
  /// see the class documentation.
  static const int maxSolverIterations = 48;

  @override
  double transformInternal(double t) {
    _validate();
    double start = 0.0;
    double end = 1.0;
    for (int iteration = 0; iteration < maxSolverIterations; iteration++) {
      final double midpoint = (start + end) / 2;
      final double estimate = _evaluate(a, c, midpoint);
      final double error = t - estimate;
      if (error.abs() < solverTolerance) return _evaluate(b, d, midpoint);
      if (error > 0) {
        start = midpoint;
      } else {
        end = midpoint;
      }
    }
    throw StateError(
      'Cubic($a, $b, $c, $d) failed to invert x after $maxSolverIterations '
      'bisection steps. That is impossible for control points with x in '
      '[0, 1], so the control points are illegal.',
    );
  }

  /// Checked lazily rather than in the constructor so the class stays `const`.
  ///
  /// A `const Cubic` in a theme is created at compile time and must cost
  /// nothing; the check therefore happens the first time the curve is actually
  /// asked for a value, which is still long before anything is drawn with it.
  void _validate() {
    if (!(a >= 0.0 && a <= 1.0) || !(c >= 0.0 && c <= 1.0)) {
      throw ArgumentError(
        'Cubic control point x coordinates must be in [0, 1]; got a=$a, c=$c. '
        'Outside that range the curve is not a function of progress and a '
        'single t would have several outputs.',
      );
    }
  }

  /// One coordinate of the Bézier at parameter [u], in Horner form so the
  /// evaluation is three multiplies and no temporaries.
  ///
  /// The endpoints are fixed at 0 and 1, so only the two control values vary:
  /// `B(u) = 3(1-u)^2 u * p1 + 3(1-u) u^2 * p2 + u^3`.
  static double _evaluate(double p1, double p2, double u) {
    final double inverse = 1.0 - u;
    return 3 * inverse * inverse * u * p1 +
        3 * inverse * u * u * p2 +
        u * u * u;
  }

  @override
  String toString() => 'Cubic($a, $b, $c, $d)';
}

/// A hard switch: `0` below [threshold], `1` at and above it.
///
/// Not an easing curve at all, and that is the point - it is how a discrete
/// property (a visibility, an icon swap) rides the same animation machinery as
/// a continuous one instead of needing a parallel timer.
final class Threshold extends Curve {
  const Threshold(this.threshold);

  final double threshold;

  @override
  double transformInternal(double t) => t < threshold ? 0.0 : 1.0;

  @override
  String toString() => 'Threshold($threshold)';
}

/// A staircase of [steps] equal jumps.
///
/// Matches the CSS `steps()` timing function. [jumpAtStart] chooses which end
/// of each tread the jump happens on: `false` (the default, CSS `jump-end`)
/// holds the starting value for the first tread; `true` (CSS `jump-start`)
/// jumps immediately and holds the final value for the last tread.
///
/// **Declared limit:** because [Curve.transform] answers the endpoints itself,
/// `transform(1)` is `1` for both variants. That is the useful behaviour - an
/// animation must finish on its target - even though a strict `jump-end`
/// staircase would report `(steps - 1) / steps` there.
final class StepCurve extends Curve {
  const StepCurve(this.steps, {this.jumpAtStart = false});

  final int steps;
  final bool jumpAtStart;

  @override
  double transformInternal(double t) {
    if (steps < 1) {
      throw ArgumentError.value(steps, 'steps', 'must be at least 1');
    }
    final double scaled = t * steps;
    final double index =
        jumpAtStart ? scaled.ceilToDouble() : scaled.floorToDouble();
    return index / steps;
  }

  @override
  String toString() => 'StepCurve($steps, jumpAtStart: $jumpAtStart)';
}

/// [curve] run backwards: `1 - curve.transform(1 - t)`.
///
/// Composition rather than a second table of control points, so an "ease out"
/// cannot drift away from the "ease in" it was supposed to mirror.
final class FlippedCurve extends Curve {
  const FlippedCurve(this.curve);

  final Curve curve;

  @override
  double transformInternal(double t) => 1.0 - curve.transform(1.0 - t);

  @override
  String toString() => 'FlippedCurve($curve)';
}

/// Runs [curve] over the sub-range `[begin, end]` of the parent progress,
/// holding `0` before it and `1` after it.
///
/// This is how a staggered sequence is expressed with **one** controller
/// instead of one per participant, which is what section 32.2 means by
/// "animation asks for a frame, it does not create a timer per property".
final class Interval extends Curve {
  const Interval(this.begin, this.end, {this.curve = Curves.linear});

  final double begin;
  final double end;
  final Curve curve;

  @override
  double transformInternal(double t) {
    if (!(begin >= 0.0 && begin <= 1.0) || !(end >= 0.0 && end <= 1.0)) {
      throw ArgumentError(
        'Interval bounds must be in [0, 1]; got begin=$begin, end=$end',
      );
    }
    if (end <= begin) {
      throw ArgumentError(
        'Interval end must be strictly after begin; got begin=$begin, '
        'end=$end. A zero-width interval has no defined progress inside it.',
      );
    }
    if (t <= begin) return 0.0;
    if (t >= end) return 1.0;
    return curve.transform((t - begin) / (end - begin));
  }

  @override
  String toString() => 'Interval($begin, $end, curve: $curve)';
}

/// The standard curve presets.
///
/// The four `ease*` control points are the CSS/Material values, reproduced
/// here as numbers rather than imported from anywhere: they are the published
/// definition of the timing function, and a framework that spells them
/// differently surprises everyone who has ever written a transition.
abstract final class Curves {
  /// Constant rate. The honest default when nothing better is known, and the
  /// only curve for which the midpoint is exactly `0.5`.
  static const Curve linear = LinearCurve();

  /// CSS `ease`. Accelerates quickly, decelerates gently. The browser default.
  static const Curve ease = Cubic(0.25, 0.1, 0.25, 1.0);

  /// CSS `ease-in`. Starts at rest; good for something leaving the screen.
  static const Curve easeIn = Cubic(0.42, 0.0, 1.0, 1.0);

  /// CSS `ease-out`. Ends at rest; good for something arriving, and the right
  /// default for a hover or press transition because the control settles.
  static const Curve easeOut = Cubic(0.0, 0.0, 0.58, 1.0);

  /// CSS `ease-in-out`. Symmetric, and therefore exactly `0.5` at `t = 0.5`.
  static const Curve easeInOut = Cubic(0.42, 0.0, 0.58, 1.0);

  /// The asymmetric "arrive fast, settle slow" curve used for material
  /// motion. Distinct from [easeInOut] in that it is *not* symmetric.
  static const Curve fastOutSlowIn = Cubic(0.4, 0.0, 0.2, 1.0);

  /// Starts at full speed and slows to a stop. The curve for a fling that is
  /// being brought to rest by something other than friction.
  static const Curve decelerate = Cubic(0.0, 0.0, 0.2, 1.0);

  /// A switch that flips at the halfway point.
  static const Curve stepMiddle = Threshold(0.5);
}
