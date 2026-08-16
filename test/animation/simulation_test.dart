/// Springs and friction, checked against their closed-form solutions.
///
/// Because the simulations are analytic, they can be sampled at arbitrary
/// times in arbitrary order - which is exactly what these tests do, and which
/// a step-integrated implementation could not survive.
library;

import 'dart:math' as math;

import 'package:dart_ui/src/animation/simulation.dart';
import 'package:test/test.dart';

Duration _seconds(double value) =>
    Duration(microseconds: (value * 1000000).round());

SpringSimulation _spring(double ratio, {double velocity = 0.0}) =>
    SpringSimulation(
      spring: SpringDescription.withDampingRatio(
        stiffness: 100.0,
        ratio: ratio,
      ),
      start: 0.0,
      end: 1.0,
      velocity: velocity,
    );

void main() {
  group('SpringDescription', () {
    test('the damping ratio round-trips through the coefficient', () {
      final SpringDescription critical =
          SpringDescription.withDampingRatio(mass: 1, stiffness: 100, ratio: 1);
      expect(critical.damping, 20.0);
      expect(critical.dampingRatio, 1.0);
      expect(critical.naturalFrequency, 10.0);

      final SpringDescription bouncy = SpringDescription.withDampingRatio(
          mass: 2, stiffness: 200, ratio: 0.25);
      expect(bouncy.dampingRatio, closeTo(0.25, 1e-12));
    });

    test('nonsense constants are rejected', () {
      expect(() => SpringDescription.withDampingRatio(mass: 0),
          throwsArgumentError);
      expect(() => SpringDescription.withDampingRatio(stiffness: -1),
          throwsArgumentError);
      expect(() => SpringDescription.withDampingRatio(ratio: -0.5),
          throwsArgumentError);
      expect(
        () => SpringSimulation(
          spring: const SpringDescription(mass: 0, stiffness: 100, damping: 10),
          start: 0,
          end: 1,
        ),
        throwsArgumentError,
      );
    });
  });

  group('the three damping regimes', () {
    test('ratio 1 is recognised as critical despite floating point', () {
      // The discriminant is computed, so exact equality with zero is a
      // measure-zero event; the class uses a relative epsilon so that a spring
      // asked for ratio 1 actually gets the critical branch.
      expect(_spring(1.0).type, SpringType.criticallyDamped);
      expect(_spring(0.5).type, SpringType.underDamped);
      expect(_spring(2.0).type, SpringType.overDamped);
    });
  });

  group('a critically damped spring', () {
    final SpringSimulation spring = _spring(1.0);

    test('starts where it was told to, at rest', () {
      expect(spring.x(Duration.zero), 0.0);
      expect(spring.dx(Duration.zero), 0.0);
    });

    test('matches the analytic solution exactly', () {
      // m=1, k=100, c=20 gives r = -10, and with x(0) = -1 and x'(0) = 0 the
      // solution is x(t) = 1 - (1 + 10t) e^{-10t}.
      for (final double t in <double>[0.05, 0.1, 0.25, 0.5, 1.0, 2.0]) {
        final double expected = 1 - (1 + 10 * t) * math.exp(-10 * t);
        expect(spring.x(_seconds(t)), closeTo(expected, 1e-12),
            reason: 'position at t=$t');
        // x'(t) = 100 t e^{-10t}
        expect(
            spring.dx(_seconds(t)), closeTo(100 * t * math.exp(-10 * t), 1e-12),
            reason: 'velocity at t=$t');
      }
    });

    test('never oscillates: monotone, and never past the target', () {
      double previous = spring.x(Duration.zero);
      for (int i = 1; i <= 2000; i++) {
        final double value = spring.x(_seconds(i / 500));
        expect(value, greaterThanOrEqualTo(previous - 1e-15),
            reason: 'went backwards at step $i');
        expect(value, lessThanOrEqualTo(1.0),
            reason: 'overshot the target at step $i');
        previous = value;
      }
    });

    test('converges to the analytic limit', () {
      expect(spring.x(const Duration(seconds: 10)), closeTo(1.0, 1e-12));
      expect(spring.dx(const Duration(seconds: 10)), closeTo(0.0, 1e-12));
      expect(spring.end, 1.0);
    });

    test('isDone follows both thresholds, not just one', () {
      // At t = 1 s the position is already within a thousandth (5.0e-4) but
      // the velocity is not (4.5e-3), so it is not done. By t = 1.2 s both
      // hold.
      expect((spring.x(_seconds(1.0)) - 1.0).abs(), lessThan(1e-3));
      expect(spring.dx(_seconds(1.0)).abs(), greaterThan(1e-3));
      expect(spring.isDone(_seconds(1.0)), isFalse);
      expect(spring.isDone(_seconds(1.2)), isTrue);
      expect(spring.isDone(Duration.zero), isFalse);
    });

    test('an initial velocity is honoured', () {
      final SpringSimulation kicked = _spring(1.0, velocity: 5.0);
      expect(kicked.x(Duration.zero), 0.0);
      expect(kicked.dx(Duration.zero), closeTo(5.0, 1e-12));
    });
  });

  group('an under-damped spring', () {
    final SpringSimulation spring = _spring(0.2);

    test('overshoots and crosses the target', () {
      double maximum = double.negativeInfinity;
      bool crossed = false;
      for (int i = 0; i <= 3000; i++) {
        final double value = spring.x(_seconds(i / 500));
        if (value > 1.0) crossed = true;
        if (value > maximum) maximum = value;
      }
      expect(crossed, isTrue, reason: 'an under-damped spring must overshoot');
      expect(maximum, greaterThan(1.0));
    });

    test('still converges, and the decay envelope bounds it', () {
      // The amplitude cannot exceed e^{r t} times the initial amplitude, with
      // r = -c/(2m). That is the analytic envelope, and violating it would
      // mean the solution is gaining energy.
      final double r = -spring.spring.damping / (2 * spring.spring.mass);
      for (int i = 1; i <= 500; i++) {
        final double t = i / 100;
        final double envelope = math.exp(r * t) * 2.0;
        expect((spring.x(_seconds(t)) - 1.0).abs(),
            lessThanOrEqualTo(envelope + 1e-12),
            reason: 'left the decay envelope at t=$t');
      }
      expect(spring.x(const Duration(seconds: 30)), closeTo(1.0, 1e-12));
      expect(spring.isDone(const Duration(seconds: 30)), isTrue);
    });
  });

  group('an over-damped spring', () {
    final SpringSimulation spring = _spring(2.0);

    test('approaches without ever crossing', () {
      double previous = spring.x(Duration.zero);
      for (int i = 1; i <= 3000; i++) {
        final double value = spring.x(_seconds(i / 200));
        expect(value, lessThanOrEqualTo(1.0));
        expect(value, greaterThanOrEqualTo(previous - 1e-15));
        previous = value;
      }
      expect(spring.x(const Duration(seconds: 30)), closeTo(1.0, 1e-12));
    });

    test('is slower to settle than the critically damped one', () {
      // The defining property of critical damping: nothing reaches the target
      // faster without overshooting.
      final double critical = 1.0 - _spring(1.0).x(_seconds(0.3));
      final double over = 1.0 - spring.x(_seconds(0.3));
      expect(over, greaterThan(critical));
    });
  });

  group('the closed form is frame-rate independent', () {
    test('sampling in one jump equals sampling in many small steps', () {
      final SpringSimulation spring = _spring(0.4, velocity: 3.0);
      final double direct = spring.x(_seconds(0.5));
      // Same instant, reached by evaluating a hundred intermediate points
      // first. A stepped integrator would give a different answer here; an
      // analytic one cannot.
      for (int i = 0; i < 100; i++) {
        spring.x(_seconds(i / 200));
      }
      expect(spring.x(_seconds(0.5)), direct);
    });

    test('out-of-order evaluation is legal', () {
      final SpringSimulation spring = _spring(1.0);
      final double late_ = spring.x(_seconds(2.0));
      final double early = spring.x(_seconds(0.1));
      expect(spring.x(_seconds(2.0)), late_);
      expect(spring.x(_seconds(0.1)), early);
    });
  });

  group('FrictionSimulation', () {
    final FrictionSimulation fling = FrictionSimulation(
      drag: 0.5,
      position: 0.0,
      velocity: 100.0,
    );

    test('starts at the position and the velocity it was given', () {
      expect(fling.x(Duration.zero), 0.0);
      expect(fling.dx(Duration.zero), 100.0);
    });

    test('velocity decays by the drag factor every second', () {
      expect(fling.dx(const Duration(seconds: 1)), closeTo(50.0, 1e-12));
      expect(fling.dx(const Duration(seconds: 2)), closeTo(25.0, 1e-12));
      expect(fling.dx(const Duration(seconds: 3)), closeTo(12.5, 1e-12));
    });

    test('position follows the integral of that decay', () {
      // x(t) = v0 (drag^t - 1) / ln(drag)
      for (final double t in <double>[0.25, 1.0, 2.5]) {
        final double expected = 100.0 * (math.pow(0.5, t) - 1) / math.log(0.5);
        expect(fling.x(_seconds(t)), closeTo(expected, 1e-9), reason: 't=$t');
      }
    });

    test('the landing point is finite and is approached', () {
      final double expected = -100.0 / math.log(0.5);
      expect(fling.finalX, closeTo(expected, 1e-12));
      expect(fling.x(const Duration(seconds: 60)), closeTo(fling.finalX, 1e-9));
    });

    test('timeAtX inverts the position analytically', () {
      final Duration? at = fling.timeAtX(fling.x(_seconds(1.5)));
      expect(at, isNotNull);
      expect(at!.inMicroseconds, closeTo(1500000, 2));
      expect(fling.timeAtX(0.0), Duration.zero);
      // Past the landing point the fling never gets there.
      expect(fling.timeAtX(fling.finalX + 1), isNull);
    });

    test('is done when the speed drops below the tolerance', () {
      expect(fling.isDone(Duration.zero), isFalse);
      expect(fling.isDone(const Duration(seconds: 10)), isFalse);
      expect(fling.isDone(const Duration(seconds: 20)), isTrue);
    });

    test('a drag outside (0, 1) is rejected rather than clamped', () {
      expect(
        () => FrictionSimulation(drag: 1.0, position: 0, velocity: 1),
        throwsArgumentError,
      );
      expect(
        () => FrictionSimulation(drag: 0.0, position: 0, velocity: 1),
        throwsArgumentError,
      );
      expect(
        () => FrictionSimulation(drag: -0.5, position: 0, velocity: 1),
        throwsArgumentError,
      );
    });
  });
}
