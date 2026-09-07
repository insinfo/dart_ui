/// The chase camera: its lag, its lead, and the one agreement that must hold
/// between it and the kart.
///
/// The last of those is the important one and is easy to miss. `vehicle.dart`
/// defines the kart's `right` as the **right of the picture**, and derives it
/// from where the camera sits. If that derivation is wrong the game is not
/// subtly off - the left arrow key steers right - and no test of the physics
/// alone can see it, because the physics is self-consistent either way. So the
/// first test here takes the camera's *own* answer, out of [MeshCamera], and
/// holds it against the kart's.
library;

import 'dart:math' as math;

import 'package:dart_ui/src/graphics/mesh/mesh3d.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_rasterizer.dart';
import 'package:test/test.dart';

import '../../../examples/kart_racer/game/chase_camera.dart';
import '../../../examples/kart_racer/game/vehicle.dart';

const double dt = 1 / 120;

KartBody kartAt(double heading, {double speed = 0, double yawRate = 0}) =>
    KartBody(x: 0, z: 0, heading: heading)
      ..forwardSpeed = speed
      ..yawRate = yawRate;

void main() {
  group('the frame the whole game is built on', () {
    test("the kart's `right` is the camera's `rightAxis`", () {
      for (double heading = -3; heading <= 3; heading += 0.41) {
        final KartBody kart = kartAt(heading);
        final ChaseCamera camera = ChaseCamera()..snapTo(kart);
        final Vector3 right = camera.camera.rightAxis;
        expect(right.x, closeTo(kart.rightX, 1e-9),
            reason: 'at heading $heading');
        expect(right.y, closeTo(0, 1e-9));
        expect(right.z, closeTo(kart.rightZ, 1e-9));
      }
    });

    test('the camera looks along the kart, from behind and above it', () {
      final KartBody kart = kartAt(0.9);
      final ChaseCamera camera = ChaseCamera()..snapTo(kart);
      final MeshCamera view = camera.camera;
      // `backAxis` points from the target toward the eye, so the eye is behind
      // the nose. A camera in front of the kart shows the player the barrier
      // they are about to hit and nothing else.
      final Vector3 back = view.backAxis;
      expect(back.x * kart.forwardX + back.z * kart.forwardZ, lessThan(0));
      expect(view.eye.y, greaterThan(1));
    });
  });

  group('lag', () {
    test('the camera does not snap to a change of heading', () {
      final KartBody kart = kartAt(0);
      final ChaseCamera camera = ChaseCamera()..snapTo(kart);
      final double before = camera.yaw;
      kart.heading = 1.0;
      camera.follow(kart, dt);
      // Moved, but nowhere near the whole way. A camera bolted rigidly behind
      // the kart rotates the *world* around a stationary kart, and forty
      // seconds of that is genuinely nauseating.
      expect(camera.yaw, greaterThan(before));
      expect(camera.yaw - before, lessThan(0.1));
    });

    test('it covers about 63% of a step change in one time constant', () {
      // The definition of an exponential time constant, and the reason the
      // smoothing is written as `1 - exp(-dt/tau)` rather than as a constant
      // per step.
      final ChaseCamera settings = ChaseCamera();
      final KartBody kart = kartAt(0);
      final ChaseCamera camera = ChaseCamera()..snapTo(kart);
      final double start = camera.yaw;
      kart.heading = 1.0;
      final int steps = (settings.yawTau / dt).round();
      for (int i = 0; i < steps; i++) {
        camera.follow(kart, dt);
      }
      final double covered = (camera.yaw - start) / 1.0;
      expect(covered, closeTo(1 - math.exp(-1), 0.02));
    });

    test('and gets there eventually', () {
      final KartBody kart = kartAt(0);
      final ChaseCamera camera = ChaseCamera()..snapTo(kart);
      kart.heading = 1.0;
      for (int i = 0; i < 600; i++) {
        camera.follow(kart, dt);
      }
      expect(camera.yaw, closeTo(1.0 + math.pi, 1e-3));
    });

    test('the same wall-clock time gives the same camera at any step rate', () {
      // The bug this exists to stop is invisible on the machine it was written
      // on: a fixed fraction per step makes the camera stiffer the faster the
      // machine, so the game *looks* different on better hardware.
      double after(double step, double seconds) {
        final KartBody kart = kartAt(0);
        final ChaseCamera camera = ChaseCamera()..snapTo(kart);
        kart.heading = 1.0;
        for (int i = 0; i < (seconds / step).round(); i++) {
          camera.follow(kart, step);
        }
        return camera.yaw;
      }

      final double at120 = after(1 / 120, 0.5);
      final double at30 = after(1 / 30, 0.5);
      expect(at30, closeTo(at120, 0.01));
    });

    test('it takes the short way round the wrap', () {
      // Either side of pi is a small difference, not a whole turn. Without
      // `wrapAngle` the camera whips round the long way exactly once per lap,
      // at whatever point on the circuit the heading happens to cross.
      final KartBody kart = kartAt(math.pi - 0.05);
      final ChaseCamera camera = ChaseCamera()..snapTo(kart);
      final double before = camera.yaw;
      kart.heading = -math.pi + 0.05;
      double travelled = 0;
      double previous = before;
      for (int i = 0; i < 240; i++) {
        camera.follow(kart, dt);
        travelled += (camera.yaw - previous).abs();
        previous = camera.yaw;
      }
      expect(travelled, lessThan(0.5));
    });
  });

  group('lead', () {
    test('a turning kart is followed from further round the corner', () {
      // Two karts pointing the same way; one is turning. The camera behind the
      // turning one aims where it is going, which is what stops the apex of
      // every corner being off the side of the screen at the moment the player
      // has to aim at it.
      final KartBody straight = kartAt(0, speed: 20);
      final KartBody turning = kartAt(0, speed: 20, yawRate: 1.2);
      final ChaseCamera a = ChaseCamera()..snapTo(straight);
      final ChaseCamera b = ChaseCamera()..snapTo(turning);
      for (int i = 0; i < 60; i++) {
        a.follow(straight, dt);
        b.follow(turning, dt);
      }
      expect(b.yaw, greaterThan(a.yaw + 0.05));
    });

    test('the lead is clamped, so a spin does not whip the camera round', () {
      final KartBody spinning = kartAt(0, speed: 12, yawRate: 40);
      final ChaseCamera camera = ChaseCamera()..snapTo(spinning);
      for (int i = 0; i < 200; i++) {
        camera.follow(spinning, dt);
      }
      // The camera settles a bounded distance from the kart's own heading
      // rather than being dragged several turns away from it.
      expect(wrapAngle(camera.yaw - (spinning.heading + math.pi)).abs(),
          lessThan(0.7));
    });
  });

  group('the target', () {
    test('is above the road, not on it', () {
      final KartBody kart = kartAt(0);
      final ChaseCamera camera = ChaseCamera()..snapTo(kart);
      expect(camera.target.y, greaterThan(0.5));
    });

    test('leads further ahead the faster the kart is going', () {
      double aheadAt(double speed) {
        final KartBody kart = kartAt(0, speed: speed);
        final ChaseCamera camera = ChaseCamera()..snapTo(kart);
        for (int i = 0; i < 240; i++) {
          camera.follow(kart, dt);
        }
        return camera.target.z - kart.z;
      }

      expect(aheadAt(25), greaterThan(aheadAt(4) + 1));
    });

    test('follows the kart when it moves', () {
      final KartBody kart = kartAt(0, speed: 20);
      final ChaseCamera camera = ChaseCamera()..snapTo(kart);
      for (int i = 0; i < 240; i++) {
        kart.step(const KartInput(throttle: 1), dt);
        camera.follow(kart, dt);
      }
      // Within a couple of metres of the look-ahead, and not left at the
      // start line.
      expect(camera.target.z, greaterThan(kart.z));
      expect(camera.target.z - kart.z, lessThan(camera.lookAhead + 2));
    });

    test('the eye pulls back at speed', () {
      double distanceAt(double speed) {
        final KartBody kart = kartAt(0, speed: speed);
        final ChaseCamera camera = ChaseCamera()..snapTo(kart);
        for (int i = 0; i < 240; i++) {
          camera.follow(kart, dt);
        }
        return camera.camera.distance;
      }

      expect(distanceAt(26), greaterThan(distanceAt(2) + 2));
    });
  });

  test('the first follow seeds instead of flying in from the origin', () {
    // Without the seeding the camera starts at `Vector3.zero` pointing north
    // and spends the first second of every race flying in, which reads as the
    // track loading.
    final KartBody kart = KartBody(x: 120, z: -80, heading: 2.0);
    final ChaseCamera camera = ChaseCamera();
    camera.follow(kart, dt);
    expect(camera.target.x, closeTo(kart.x + kart.forwardX * 1.75, 0.6));
    expect(camera.yaw, closeTo(kart.heading + math.pi, 1e-12));
  });

  test('a zero step moves nothing', () {
    final KartBody kart = kartAt(1.0, speed: 10);
    final ChaseCamera camera = ChaseCamera()..snapTo(kart);
    final double yaw = camera.yaw;
    final Vector3 target = camera.target;
    camera.follow(kart, 0);
    expect(camera.yaw, yaw);
    expect(camera.target.x, target.x);
  });
}
