/// The barriers and the grass, driven with overlaps chosen by hand.
///
/// A straight fixture rather than the shipped circuit, deliberately: on a
/// straight the wall's normal is a constant, so "the kart was 40 cm into the
/// barrier and came out exactly 40 cm" is a number this file can write down.
/// On a corner the same assertion would be a tolerance, and a tolerance hides
/// exactly the kind of error - a normal that points the wrong way on one side
/// - that this code gets wrong.
library;

import 'dart:math' as math;

import 'package:test/test.dart';

import '../../../examples/kart_racer/game/track.dart';
import '../../../examples/kart_racer/game/track_limits.dart';
import '../../../examples/kart_racer/game/vehicle.dart';

/// A long thin loop whose left-hand side is a straight along +Z at x = 0.
///
/// Four points would be a diamond with corners everywhere; this puts a hundred
/// metres of genuinely straight road at the start.
TrackPath straightish() => TrackPath.fromControlPoints(
      const <(double, double)>[
        (0, -60),
        (0, -20),
        (0, 20),
        (0, 60),
        (40, 100),
        (80, 60),
        (80, 20),
        (80, -20),
        (80, -60),
        (40, -100),
      ],
      halfWidth: 5.6,
      wallThickness: 0.7,
      smoothingPasses: 0,
    );

void main() {
  final TrackPath track = straightish();
  // The middle of the long straight, where the frame is known: the tangent is
  // +Z and the normal - the right of travel - is -X.
  final TrackProjection middle = track.project(0, 0);

  test('the fixture is the straight this file assumes it is', () {
    expect(middle.sample.tangentZ, closeTo(1, 1e-6));
    expect(middle.sample.normalX, closeTo(-1, 1e-6));
    expect(middle.lateral, closeTo(0, 1e-6));
  });

  group('the surface', () {
    test('is road inside the white line', () {
      expect(surfaceAt(track, 0).onRoad, isTrue);
      expect(surfaceAt(track, 5.5).gripScale, 1);
      expect(surfaceAt(track, -5.5).powerScale, 1);
    });

    test('is a ramp and not a cliff at the edge', () {
      // A step change makes the kart snap sideways the instant a wheel touches
      // the grass, which reads as the physics glitching rather than as a
      // mistake the player made.
      final SurfaceResponse just = surfaceAt(track, track.halfWidth + 0.2);
      final SurfaceResponse deep = surfaceAt(track, track.halfWidth + 3);
      expect(just.onRoad, isFalse);
      expect(just.gripScale, greaterThan(0.85));
      expect(deep.gripScale, lessThan(just.gripScale));
      // And it bottoms out rather than reaching zero: a kart with no grip at
      // all cannot be steered back onto the road.
      expect(deep.gripScale, greaterThan(0.3));
      expect(deep.powerScale, greaterThan(0.3));
    });

    test('is symmetric', () {
      expect(surfaceAt(track, 8).gripScale, surfaceAt(track, -8).gripScale);
    });
  });

  group('the barrier', () {
    /// A kart [lateral] metres off the centreline heading straight down the
    /// road at [speed], drifting sideways at [sideways].
    KartBody kartAt(double lateral, {double speed = 0, double sideways = 0}) {
      final TrackSample frame = track.frameAt(middle.distance);
      final KartBody kart = KartBody(
        x: frame.x + frame.normalX * lateral,
        z: frame.z + frame.normalZ * lateral,
        heading: math.atan2(frame.tangentX, frame.tangentZ),
      )
        ..forwardSpeed = speed
        ..lateralSpeed = sideways;
      return kart;
    }

    test('a kart on the road is not touched', () {
      final KartBody kart = kartAt(4, speed: 20, sideways: 3);
      final double x = kart.x;
      final double z = kart.z;
      final WallImpact impact =
          resolveTrackLimits(kart, track, track.project(kart.x, kart.z));
      expect(impact.hit, isFalse);
      expect(kart.x, x);
      expect(kart.z, z);
      expect(kart.forwardSpeed, 20);
      expect(kart.lateralSpeed, 3);
    });

    test('a known overlap is pushed out by exactly that much', () {
      // The limit is where the *centre* of a kart of radius `kKartRadius` may
      // be: the barrier offset less the radius.
      final double limit = track.wallOffset - kKartRadius;
      const double overlap = 0.4;
      final KartBody kart = kartAt(limit + overlap, speed: 10, sideways: 4);
      final WallImpact impact =
          resolveTrackLimits(kart, track, track.project(kart.x, kart.z));
      expect(impact.hit, isTrue);
      final TrackProjection after = track.project(kart.x, kart.z);
      expect(after.lateral, closeTo(limit, 1e-6));
    });

    test('the same on the other side, which is where a sign error shows', () {
      final double limit = track.wallOffset - kKartRadius;
      final KartBody kart = kartAt(-(limit + 0.4), speed: 10, sideways: -4);
      resolveTrackLimits(kart, track, track.project(kart.x, kart.z));
      final TrackProjection after = track.project(kart.x, kart.z);
      // Negative, not positive: a response that used the normal without the
      // side would push this kart across the road into the other barrier.
      expect(after.lateral, closeTo(-limit, 1e-6));
    });

    test('the velocity into the wall is reversed and mostly absorbed', () {
      final double limit = track.wallOffset - kKartRadius;
      final KartBody kart = kartAt(limit + 0.3, speed: 0, sideways: 6);
      final TrackSample frame = track.frameAt(middle.distance);
      final WallImpact impact =
          resolveTrackLimits(kart, track, track.project(kart.x, kart.z));
      expect(impact.hit, isTrue);
      expect(impact.closingSpeed, closeTo(6, 1e-6));
      final double outward = kart.worldVelocityX * frame.normalX +
          kart.worldVelocityZ * frame.normalZ;
      // Coming away from the wall now, and at a fraction of what it arrived
      // with. A restitution near one would bounce the kart across the road
      // into the opposite barrier.
      expect(outward, lessThan(0));
      expect(outward.abs(), lessThan(6 * 0.4));
    });

    test('a glancing brush keeps most of the speed; a square hit does not', () {
      final double limit = track.wallOffset - kKartRadius;
      final KartBody glancing = kartAt(limit + 0.05, speed: 24, sideways: 1);
      final KartBody square = kartAt(limit + 0.05, speed: 24, sideways: 14);
      resolveTrackLimits(
          glancing, track, track.project(glancing.x, glancing.z));
      resolveTrackLimits(square, track, track.project(square.x, square.z));
      // This is what makes a barrier a mistake rather than a race-ending stop.
      expect(glancing.forwardSpeed, greaterThan(20));
      expect(square.forwardSpeed, lessThan(12));
    });

    test('a kart resting against the barrier is not hit every step', () {
      // Position is still clamped - a kart pushed into the barrier has to come
      // out - but nothing is taken from a velocity already going the right
      // way, or a parked kart would fire an impact at the step rate and be
      // held there by its own response.
      final double limit = track.wallOffset - kKartRadius;
      final KartBody kart = kartAt(limit + 0.2, speed: 8, sideways: -0.5);
      final WallImpact impact =
          resolveTrackLimits(kart, track, track.project(kart.x, kart.z));
      expect(impact.hit, isFalse);
      expect(kart.forwardSpeed, 8);
      final TrackProjection after = track.project(kart.x, kart.z);
      expect(after.lateral, closeTo(limit, 1e-6));
    });

    test('the yaw is damped, so a clipped kart does not grind along nose-in',
        () {
      final double limit = track.wallOffset - kKartRadius;
      final KartBody kart = kartAt(limit + 0.3, speed: 18, sideways: 5)
        ..yawRate = 1.4;
      resolveTrackLimits(kart, track, track.project(kart.x, kart.z));
      expect(kart.yawRate.abs(), lessThan(1.4 * 0.6));
    });

    test('a kart cannot be driven through the barrier over many steps', () {
      // The property that matters in a race, as opposed to one contact: full
      // throttle and full lock straight at the wall for four seconds must not
      // put the kart outside it once.
      final KartBody kart = kartAt(0, speed: 6);
      int? hint;
      double worst = 0;
      for (int i = 0; i < 480; i++) {
        kart.step(const KartInput(throttle: 1, steer: 1), 1 / 120);
        final TrackProjection where = track.project(kart.x, kart.z, hint: hint);
        hint = where.sampleIndex;
        resolveTrackLimits(kart, track, where);
        final TrackProjection after = track.project(kart.x, kart.z, hint: hint);
        worst = math.max(worst, after.lateral.abs());
      }
      expect(worst, lessThan(track.wallOffset - kKartRadius + 1e-3));
    });
  });
}
