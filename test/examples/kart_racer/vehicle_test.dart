/// The kart's arithmetic, step by step.
///
/// Everything here drives [KartBody.step] with a *known* input for a *known*
/// number of fixed steps and checks where it ended up, because that is the one
/// part of a racing game a test can be certain about. What no test in this
/// directory can tell anybody is whether the result is fun to drive; that
/// needs a hand on the arrow keys and is called out in the report.
library;

import 'dart:math' as math;

import 'package:test/test.dart';

import '../../../examples/kart_racer/game/vehicle.dart';

/// The simulation's step, spelled out rather than imported, so that a change
/// to the game's tick shows up here as a failing number instead of silently
/// re-scaling every expectation below.
const double dt = 1 / 120;

KartBody run(
  KartInput input,
  int steps, {
  KartBody? from,
  double gripScale = 1,
  double powerScale = 1,
}) {
  final KartBody kart = from ?? KartBody(x: 0, z: 0, heading: 0);
  for (int i = 0; i < steps; i++) {
    kart.step(input, dt, gripScale: gripScale, powerScale: powerScale);
  }
  return kart;
}

void main() {
  group('acceleration', () {
    test('a constant throttle reaches a terminal speed and stays there', () {
      const KartTuning tuning = KartTuning();
      final KartBody kart = run(const KartInput(throttle: 1), 1200);
      // Terminal speed solves `power = drag*v^2 + rolling*v`, which for the
      // shipped tuning is 26.4 m/s. Asserted against the closed form rather
      // than against a recorded number, so that retuning the engine moves the
      // expectation with it instead of breaking this test.
      final double a = tuning.drag;
      final double b = tuning.rollingResistance;
      final double c = -tuning.enginePower;
      final double terminal = (-b + math.sqrt(b * b - 4 * a * c)) / (2 * a);
      // A fifth of a metre per second of tolerance: the closed form is the
      // continuous answer and this is Euler at 120 Hz, which settles a little
      // short of it.
      expect(kart.forwardSpeed, closeTo(terminal, 0.2));
      expect(kart.lateralSpeed, 0);
      expect(kart.yawRate, 0);
      // Straight: heading untouched and the whole distance along +Z.
      expect(kart.heading, 0);
      expect(kart.x, 0);
      expect(kart.z, greaterThan(150));
    });

    test('the first second is the engine, not the drag', () {
      final KartBody kart = run(const KartInput(throttle: 1), 120);
      // 15 m/s² for a second, less what drag and rolling took: comfortably
      // between two thirds and all of the naive figure.
      expect(kart.forwardSpeed, greaterThan(10));
      expect(kart.forwardSpeed, lessThan(15));
    });

    test('the brake does not fling the kart backwards through zero', () {
      final KartBody kart = run(const KartInput(throttle: 1), 600);
      expect(kart.forwardSpeed, greaterThan(20));
      // The step the kart first stops on is the one that matters. A brake that
      // switched to reverse power on the sign of the speed would apply a full
      // 26 m/s² backwards on it, and the kart twitches backwards at the end of
      // every stop.
      double crossing = double.nan;
      for (int i = 0; i < 600; i++) {
        kart.step(const KartInput(brake: 1), dt);
        if (kart.forwardSpeed <= 0) {
          crossing = kart.forwardSpeed;
          break;
        }
      }
      expect(crossing, isNot(isNaN), reason: 'the brake never stopped it');
      expect(crossing, greaterThan(-0.3));
      // Held from a standstill it *is* reverse, which is the other half of the
      // same control.
      run(const KartInput(brake: 1), 240, from: kart);
      expect(kart.forwardSpeed, lessThan(-3));
    });

    test('grass takes both power and top speed', () {
      final KartBody road = run(const KartInput(throttle: 1), 400);
      final KartBody grass =
          run(const KartInput(throttle: 1), 400, powerScale: 0.6);
      expect(grass.forwardSpeed, lessThan(road.forwardSpeed * 0.75));
    });
  });

  group('steering', () {
    test('full lock at a standstill does not move the kart at all', () {
      final KartBody kart = run(const KartInput(steer: 1), 600);
      // Exactly, not approximately. The yaw rate the bicycle model asks for is
      // `v · tan δ / L`, and `v` is zero, so nothing can accumulate - which is
      // what stops a player aiming the kart anywhere they like before the
      // lights and spinning round a hairpin at walking pace.
      expect(kart.heading, 0);
      expect(kart.yawRate, 0);
      expect(kart.x, 0);
      expect(kart.z, 0);
    });

    test('a positive steer turns toward the right of the picture', () {
      final KartBody kart = run(const KartInput(throttle: 1), 240);
      final double beforeX = kart.x;
      run(const KartInput(throttle: 1, steer: 1), 180, from: kart);
      // The right of the picture is `(-cos h, sin h)`, which at a heading of
      // zero is -X. A kart steered right must therefore end up at a *smaller*
      // x than it started. This is the sign that, wrong, makes the left arrow
      // key steer right; see the derivation in `vehicle.dart`.
      expect(kart.x, lessThan(beforeX - 1));
      expect(kart.heading, lessThan(0));
    });

    test('steering is symmetric', () {
      final KartBody right = run(const KartInput(throttle: 1, steer: 0.5), 400);
      final KartBody left = run(const KartInput(throttle: 1, steer: -0.5), 400);
      expect(left.x, closeTo(-right.x, 1e-9));
      expect(left.z, closeTo(right.z, 1e-9));
      expect(left.heading, closeTo(-right.heading, 1e-12));
    });

    test('the lock at full deflection never asks for grip that is not there',
        () {
      // The steering assist, stated as the property it exists to have: at any
      // speed, full lock asks for a corner the tyres can hold to within
      // `corneringMargin`. Checked on the *angle the step used*, not on where
      // the kart ended up, because the two are only the same while the kart is
      // not already sliding.
      const KartTuning tuning = KartTuning();
      double? previousRadius;
      for (final double speed in <double>[8, 12, 18, 24, 27]) {
        final KartBody kart = KartBody(x: 0, z: 0, heading: 0)
          ..forwardSpeed = speed;
        kart.step(const KartInput(steer: 1), dt);
        final double radius =
            tuning.wheelbase / math.tan(kart.steerAngle.abs());
        final double demanded = speed * speed / radius;
        expect(
          demanded,
          lessThan(
              tuning.maxLateralAcceleration * tuning.corneringMargin + 0.5),
          reason: 'full lock at $speed m/s demands $demanded m/s²',
        );
        // And it genuinely tightens: every faster case turns a wider circle.
        if (previousRadius != null) {
          expect(radius, greaterThan(previousRadius));
        }
        previousRadius = radius;
      }
    });

    test('below walking pace the lock is the geometry, not the grip', () {
      const KartTuning tuning = KartTuning();
      final KartBody kart = KartBody(x: 0, z: 0, heading: 0)..forwardSpeed = 2;
      kart.step(const KartInput(steer: 1), dt);
      expect(kart.steerAngle.abs(), closeTo(tuning.maxSteerAngle, 1e-9));
    });
  });

  group('the tyres', () {
    test('grip removes sideways velocity', () {
      final KartBody kart = KartBody(x: 0, z: 0, heading: 0)
        ..forwardSpeed = 10
        ..lateralSpeed = 6;
      run(KartInput.idle, 120, from: kart);
      expect(kart.lateralSpeed.abs(), lessThan(0.5));
    });

    test('there is a cornering limit, so a corner has a speed', () {
      // The whole point of `maxLateralAcceleration`. A kart at 25 m/s asked
      // for a tight radius cannot have it: it slides, which is what makes
      // braking worth doing.
      const KartTuning tuning = KartTuning();
      final KartBody kart = KartBody(x: 0, z: 0, heading: 0)
        ..forwardSpeed = 25
        ..lateralSpeed = 8;
      final double before = kart.lateralSpeed;
      kart.step(KartInput.idle, dt);
      final double removed = (before - kart.lateralSpeed) / dt;
      expect(removed, lessThanOrEqualTo(tuning.maxLateralAcceleration + 1e-9));
      // And the limit is what bit, not the proportional term: 8 m/s of slip
      // times a grip of 9 would be 72 m/s².
      expect(removed, closeTo(tuning.maxLateralAcceleration, 1e-9));
    });

    test('the handbrake is what makes the kart slide', () {
      KartBody sliding() => KartBody(x: 0, z: 0, heading: 0)
        ..forwardSpeed = 18
        ..lateralSpeed = 5;
      final KartBody gripped = sliding();
      final KartBody drifting = sliding();
      run(const KartInput(throttle: 1, steer: 0.6), 60, from: gripped);
      run(
        const KartInput(throttle: 1, steer: 0.6, drift: true),
        60,
        from: drifting,
      );
      double slipAngle(KartBody kart) =>
          math.atan2(kart.lateralSpeed.abs(), kart.forwardSpeed.abs());
      expect(slipAngle(drifting), greaterThan(slipAngle(gripped) * 1.8));
      expect(drifting.drifting, isTrue);
      expect(gripped.drifting, isFalse);
    });

    test('a held drift earns a boost, and only when it is released', () {
      const KartTuning tuning = KartTuning();
      final KartBody kart = KartBody(x: 0, z: 0, heading: 0)..forwardSpeed = 18;
      run(const KartInput(throttle: 1, steer: 0.6, drift: true), 150,
          from: kart);
      expect(kart.driftCharge, greaterThan(tuning.miniTurboCharge));
      expect(kart.boostRemaining, 0, reason: 'not while it is still held');
      kart.step(const KartInput(throttle: 1), dt);
      expect(kart.boostRemaining, closeTo(tuning.boostDuration - dt, 1e-9));
      expect(kart.driftCharge, 0);
    });

    test('a drift held straight earns nothing', () {
      final KartBody kart = KartBody(x: 0, z: 0, heading: 0)..forwardSpeed = 18;
      run(const KartInput(throttle: 1, drift: true), 200, from: kart);
      kart.step(const KartInput(throttle: 1), dt);
      expect(kart.boostRemaining, 0);
    });

    test('the handbrake below the threshold is not a drift', () {
      final KartBody kart = KartBody(x: 0, z: 0, heading: 0)..forwardSpeed = 3;
      kart.step(const KartInput(steer: 1, drift: true), dt);
      expect(kart.drifting, isFalse);
    });
  });

  group('the frame of reference', () {
    test('forward and right are perpendicular unit vectors everywhere', () {
      for (double heading = -4; heading < 4; heading += 0.37) {
        final KartBody kart = KartBody(x: 0, z: 0, heading: heading);
        expect(
          kart.forwardX * kart.forwardX + kart.forwardZ * kart.forwardZ,
          closeTo(1, 1e-12),
        );
        expect(
          kart.forwardX * kart.rightX + kart.forwardZ * kart.rightZ,
          closeTo(0, 1e-12),
        );
      }
    });

    test('world velocity survives a round trip through the body frame', () {
      final KartBody kart = KartBody(x: 0, z: 0, heading: 1.1)
        ..setWorldVelocity(4.5, -7.25);
      expect(kart.worldVelocityX, closeTo(4.5, 1e-12));
      expect(kart.worldVelocityZ, closeTo(-7.25, 1e-12));
    });

    test('turning does not turn the velocity with it', () {
      // The counter-rotation in `step`. Without it the kart's momentum follows
      // its nose for free, every corner is perfectly gripped, and the drift
      // silently does nothing.
      // The tyres are switched off in the *tuning*, so that only the rotation
      // acts. Doing it with `gripScale: 0` instead would also switch off the
      // steering, which is derived from the grip.
      final KartBody kart = KartBody(
        x: 0,
        z: 0,
        heading: 0,
        tuning: const KartTuning(grip: 0),
      )..forwardSpeed = 20;
      final double before =
          math.atan2(kart.worldVelocityX, kart.worldVelocityZ);
      kart.step(const KartInput(steer: 1), dt);
      expect(kart.heading, isNot(0));
      // The *direction* of travel, not its length: drag shortens the vector in
      // the same step and is not what this is about.
      expect(
        math.atan2(kart.worldVelocityX, kart.worldVelocityZ),
        closeTo(before, 1e-12),
      );
      // And the kart is now pointing somewhere its momentum is not, which is
      // the slip a tyre model exists to eat.
      expect(kart.lateralSpeed.abs(), greaterThan(0));
    });
  });

  group('wrapAngle', () {
    test('folds into [-pi, pi)', () {
      expect(wrapAngle(0), 0);
      expect(wrapAngle(math.pi * 2), closeTo(0, 1e-12));
      expect(wrapAngle(math.pi * 3).abs(), closeTo(math.pi, 1e-12));
      expect(wrapAngle(-math.pi * 3).abs(), closeTo(math.pi, 1e-12));
      // The case the camera and the opponent both need: either side of the
      // wrap is a small difference, not a whole turn.
      expect(wrapAngle(3.10 - -3.10), closeTo(-0.0831853, 1e-6));
    });
  });

  test('a zero or negative step changes nothing', () {
    final KartBody kart = KartBody(x: 3, z: 4, heading: 0.5)..forwardSpeed = 12;
    kart.step(const KartInput(throttle: 1), 0);
    expect(kart.forwardSpeed, 12);
    kart.step(const KartInput(throttle: 1), -1);
    expect(kart.forwardSpeed, 12);
    expect(kart.x, 3);
  });
}
