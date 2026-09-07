/// What the road does to a kart: grip off the racing surface, and a wall that
/// stops it.
///
/// Split from both [KartBody] and [TrackPath] because it belongs to neither.
/// The kart knows nothing about where it is; the track knows nothing about
/// what is driving on it. This is the one place that holds both, which is also
/// what makes it the one place a test can hand a known overlap and check the
/// resolved position to the millimetre - see `track_limits_test.dart`.
library;

import 'dart:math' as math;

import 'track.dart';
import 'vehicle.dart';

/// What the surface under a kart does to it this step.
final class SurfaceResponse {
  const SurfaceResponse({
    required this.gripScale,
    required this.powerScale,
    required this.onRoad,
  });

  static const SurfaceResponse road =
      SurfaceResponse(gripScale: 1, powerScale: 1, onRoad: true);

  /// Multiplies both the tyre grip and the steering lock.
  final double gripScale;

  /// Multiplies engine power and top speed.
  final double powerScale;

  final bool onRoad;
}

/// The result of pushing a kart back inside the walls.
final class WallImpact {
  const WallImpact({required this.hit, required this.closingSpeed});

  static const WallImpact none = WallImpact(hit: false, closingSpeed: 0);

  final bool hit;

  /// How fast the kart was travelling *into* the wall, m/s. Zero for a kart
  /// merely resting against it, which is what stops a kart parked in the
  /// barrier from firing an impact every step.
  final double closingSpeed;
}

/// How wide the kart is treated as being, metres.
///
/// A circle and not the 1.6 x 1.0 rectangle the kart is drawn as. The
/// rectangle would need the kart's heading in the overlap test, and the
/// visible difference - being able to squeeze diagonally into a gap the kart
/// does not fit through square - does not exist on a track with no gaps. What
/// the circle costs is that a kart pointing along the wall is held 20 cm
/// further out than it looks; that is the trade, and it is why the radius is
/// closer to the half-width than the half-length.
const double kKartRadius = 0.72;

/// Grip and power for a kart whose centre is [lateral] metres off the
/// centreline.
///
/// The drop is a ramp and not a step. A cliff at the white line makes the kart
/// snap sideways the instant a wheel touches the grass, which reads as the
/// physics glitching rather than as a mistake the player made; the ramp gives
/// the half-metre of warning that lets a player save it.
SurfaceResponse surfaceAt(TrackPath track, double lateral) {
  final double over = lateral.abs() - track.halfWidth;
  if (over <= 0) return SurfaceResponse.road;
  final double t = math.min(1, over / 1.2);
  return SurfaceResponse(
    gripScale: 1 - 0.55 * t,
    powerScale: 1 - 0.45 * t,
    onRoad: false,
  );
}

/// Pushes [kart] back inside the walls and takes the crash out of its
/// velocity.
///
/// Position first, then velocity, and in that order for a reason: resolving
/// the velocity of a kart still overlapping the wall lets it be pushed back in
/// on the next step by whatever it is leaning on, and the kart buzzes along
/// the barrier at the step rate.
///
/// The velocity response splits the world velocity into the wall's normal and
/// its tangent:
///
///   * the **normal** component is reflected and multiplied by
///     [restitution] - well below one, because a kart that bounced off a
///     barrier like a billiard ball would cross the track and hit the other
///     one;
///   * the **tangential** component is scrubbed in proportion to how hard the
///     kart arrived. A glancing brush along the barrier keeps almost all of
///     the speed, which is what makes a wall a mistake and not a race-ending
///     stop; hitting it square takes nearly everything.
///
/// The yaw rate is damped as well. Without it a kart that clips a barrier
/// mid-corner keeps the rotation it had, pivots into the wall and grinds along
/// it nose-first, which looks exactly like the collision not working.
WallImpact resolveTrackLimits(
  KartBody kart,
  TrackPath track,
  TrackProjection projection, {
  double restitution = 0.22,
  double wallFriction = 0.75,
}) {
  final double limit = track.wallOffset - kKartRadius;
  final double lateral = projection.lateral;
  if (lateral.abs() <= limit) return WallImpact.none;

  final TrackSample frame = projection.sample;
  final double side = lateral.isNegative ? -1.0 : 1.0;
  final double overlap = lateral.abs() - limit;

  kart.x -= frame.normalX * side * overlap;
  kart.z -= frame.normalZ * side * overlap;

  final double vx = kart.worldVelocityX;
  final double vz = kart.worldVelocityZ;
  // Signed along the outward normal on this side, so positive is "into the
  // wall" whichever wall it is.
  final double closing = (vx * frame.normalX + vz * frame.normalZ) * side;
  if (closing <= 0) {
    // Resting against it, or already leaving. The position was still clamped
    // above - a kart pushed into the barrier by another kart has to come out -
    // but nothing is taken from a velocity that is already going the right
    // way.
    return WallImpact.none;
  }

  final double tangential = vx * frame.tangentX + vz * frame.tangentZ;
  final double scrub = 1 - wallFriction * math.min(1.0, closing / 12);
  final double nextNormal = -closing * restitution * side;
  final double nextTangential = tangential * scrub;

  kart.setWorldVelocity(
    frame.normalX * nextNormal + frame.tangentX * nextTangential,
    frame.normalZ * nextNormal + frame.tangentZ * nextTangential,
  );
  kart.yawRate *= 0.45;
  return WallImpact(hit: true, closingSpeed: closing);
}
