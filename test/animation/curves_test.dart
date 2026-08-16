/// Curves are pure functions, so they are tested as pure functions: exact
/// values at known points, monotonicity over a sweep, and the domain contract.
library;

import 'dart:math' as math;

import 'package:dart_ui/src/animation/curves.dart';
import 'package:test/test.dart';

/// The parametric cubic Bézier the solver is supposed to invert, written out
/// independently so the test does not check the implementation against itself.
double _bezier(double p1, double p2, double u) {
  final double inverse = 1.0 - u;
  return 3 * inverse * inverse * u * p1 + 3 * inverse * u * u * p2 + u * u * u;
}

void main() {
  group('the Curve contract', () {
    const List<Curve> everyCurve = <Curve>[
      Curves.linear,
      Curves.ease,
      Curves.easeIn,
      Curves.easeOut,
      Curves.easeInOut,
      Curves.fastOutSlowIn,
      Curves.decelerate,
      Curves.stepMiddle,
      StepCurve(4),
      StepCurve(4, jumpAtStart: true),
      FlippedCurve(Curves.easeIn),
      Interval(0.25, 0.75, curve: Curves.easeInOut),
    ];

    test('every curve maps the endpoints to themselves, exactly', () {
      for (final Curve curve in everyCurve) {
        expect(curve.transform(0.0), 0.0, reason: '$curve at t=0');
        expect(curve.transform(1.0), 1.0, reason: '$curve at t=1');
      }
    });

    test('progress outside [0, 1] throws instead of being clamped', () {
      for (final Curve curve in everyCurve) {
        expect(() => curve.transform(-0.01), throwsArgumentError);
        expect(() => curve.transform(1.01), throwsArgumentError);
        expect(() => curve.transform(double.nan), throwsArgumentError);
      }
    });

    test('the easing curves are monotonically non-decreasing', () {
      const List<Curve> monotone = <Curve>[
        Curves.linear,
        Curves.ease,
        Curves.easeIn,
        Curves.easeOut,
        Curves.easeInOut,
        Curves.fastOutSlowIn,
        Curves.decelerate,
      ];
      for (final Curve curve in monotone) {
        double previous = curve.transform(0.0);
        for (int i = 1; i <= 200; i++) {
          final double value = curve.transform(i / 200);
          expect(
            value,
            greaterThanOrEqualTo(previous - 1e-12),
            reason: '$curve went backwards at t=${i / 200}',
          );
          previous = value;
        }
      }
    });

    test('a curve is deterministic: the same input gives the same output', () {
      for (final Curve curve in everyCurve) {
        for (final double t in <double>[0.1, 0.37, 0.5, 0.63, 0.9]) {
          expect(curve.transform(t), curve.transform(t));
        }
      }
    });
  });

  group('linear', () {
    test('is the identity', () {
      expect(Curves.linear.transform(0.25), 0.25);
      expect(Curves.linear.transform(0.5), 0.5);
      expect(Curves.linear.transform(0.75), 0.75);
    });
  });

  group('cubic Bézier', () {
    test('inverts its own parametric definition to within tolerance', () {
      // For a set of parameters u, compute the point (x, y) on the curve
      // directly, then ask the curve for y given x. The solver's answer must
      // match, which is the actual claim the solver makes.
      const Cubic curve = Cubic(0.42, 0.0, 0.58, 1.0);
      for (int i = 1; i < 40; i++) {
        final double u = i / 40;
        final double x = _bezier(0.42, 0.58, u);
        final double y = _bezier(0.0, 1.0, u);
        expect(curve.transform(x), closeTo(y, 1e-6), reason: 'at u=$u');
      }
    });

    test('a symmetric cubic is exactly 0.5 at the midpoint', () {
      // Curves.easeInOut is symmetric about (0.5, 0.5), so bisection finds it
      // on the very first step with zero residual. This is the one Bézier
      // value that can be asserted exactly rather than with a tolerance.
      expect(Curves.easeInOut.transform(0.5), 0.5);
    });

    test('the presets bend in the direction their names claim', () {
      expect(Curves.easeIn.transform(0.5), lessThan(0.5));
      expect(Curves.easeOut.transform(0.5), greaterThan(0.5));
      expect(Curves.ease.transform(0.5), greaterThan(0.5));
      expect(Curves.decelerate.transform(0.25), greaterThan(0.25));
      expect(Curves.fastOutSlowIn.transform(0.5), greaterThan(0.5));
    });

    test('ease-in and ease-out are each other flipped', () {
      // Cubic(a, b, c, d) flipped is Cubic(1-c, 1-d, 1-a, 1-b): easeIn is
      // (0.42, 0, 1, 1) and easeOut is (0, 0, 0.58, 1).
      for (int i = 1; i < 20; i++) {
        final double t = i / 20;
        expect(
          Curves.easeIn.flipped.transform(t),
          closeTo(Curves.easeOut.transform(t), 1e-6),
          reason: 'at t=$t',
        );
      }
    });

    test('an x control point outside [0, 1] is rejected on use', () {
      const Cubic illegal = Cubic(1.5, 0.0, 0.5, 1.0);
      expect(() => illegal.transform(0.5), throwsArgumentError);
    });

    test(
        'the solver tolerance and iteration cap are declared, and the cap '
        'is unreachable', () {
      // 2^-48 is well below the tolerance, so bisection always converges
      // first. If this stops being true the StateError in the solver becomes
      // reachable and the class documentation is wrong.
      expect(Cubic.solverTolerance, 1e-9);
      expect(Cubic.maxSolverIterations, 48);
      expect(
        math.pow(2, -Cubic.maxSolverIterations),
        lessThan(Cubic.solverTolerance),
      );
    });
  });

  group('threshold and steps', () {
    test('a threshold flips exactly at its point', () {
      const Curve curve = Threshold(0.5);
      expect(curve.transform(0.4999), 0.0);
      expect(curve.transform(0.5), 1.0);
      expect(curve.transform(0.6), 1.0);
    });

    test('a four-step staircase holds each tread', () {
      const Curve steps = StepCurve(4);
      expect(steps.transform(0.1), 0.0);
      expect(steps.transform(0.24), 0.0);
      expect(steps.transform(0.25), 0.25);
      expect(steps.transform(0.49), 0.25);
      expect(steps.transform(0.5), 0.5);
      expect(steps.transform(0.75), 0.75);
      expect(steps.transform(0.99), 0.75);
    });

    test('jumpAtStart raises the value one tread earlier', () {
      const Curve steps = StepCurve(4, jumpAtStart: true);
      expect(steps.transform(0.01), 0.25);
      expect(steps.transform(0.25), 0.25);
      expect(steps.transform(0.26), 0.5);
    });

    test('zero steps is rejected', () {
      expect(() => const StepCurve(0).transform(0.5), throwsArgumentError);
    });
  });

  group('composition', () {
    test('flipping twice is the original curve', () {
      for (int i = 1; i < 20; i++) {
        final double t = i / 20;
        expect(
          Curves.easeIn.flipped.flipped.transform(t),
          closeTo(Curves.easeIn.transform(t), 1e-9),
        );
      }
    });

    test('an interval holds, runs, then holds', () {
      const Curve interval = Interval(0.25, 0.75);
      expect(interval.transform(0.1), 0.0);
      expect(interval.transform(0.25), 0.0);
      expect(interval.transform(0.5), 0.5);
      expect(interval.transform(0.75), 1.0);
      expect(interval.transform(0.9), 1.0);
    });

    test('an interval applies its inner curve to the local progress', () {
      const Curve interval = Interval(0.5, 1.0, curve: Curves.easeInOut);
      // Halfway through the interval is t = 0.75 globally, and easeInOut is
      // exactly 0.5 at its own midpoint.
      expect(interval.transform(0.75), 0.5);
    });

    test('an inverted or empty interval is rejected', () {
      expect(
          () => const Interval(0.75, 0.25).transform(0.5), throwsArgumentError);
      expect(
          () => const Interval(0.5, 0.5).transform(0.4), throwsArgumentError);
      expect(
          () => const Interval(-0.1, 0.5).transform(0.4), throwsArgumentError);
    });

    test('two intervals stagger without a second controller', () {
      const Curve first = Interval(0.0, 0.5);
      const Curve second = Interval(0.5, 1.0);
      expect(first.transform(0.5), 1.0);
      expect(second.transform(0.5), 0.0);
      expect(first.transform(0.25), 0.5);
      expect(second.transform(0.75), 0.5);
    });
  });
}
