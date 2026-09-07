/// An opponent that drives, rather than one that is moved.
///
/// It produces a [KartInput] and nothing else. That constraint is the whole
/// design: the opponent is handed the same [KartBody.step] the player's kart
/// gets, so it has the same top speed, the same understeer at the exit of turn
/// 2 and the same handbrake, and a player who watches it can learn the track
/// from it. The alternative - moving the opponent along the spline at a
/// scripted speed - is much less code and is immediately obvious from the
/// cockpit, because the opponent takes corners in a way no input can produce
/// and never makes a mistake.
///
/// ## How it decides
///
/// Two independent questions, which is how every waypoint driver worth reading
/// is built (this is the shape `bonfire`'s and `flame`'s steering behaviours
/// arrive at too, minus the arrival/avoidance blending they need for a crowd):
///
///   * **where to point**: at the racing line a look-ahead in front, where the
///     look-ahead grows with speed. A fixed look-ahead is the classic failure
///     - short enough to take the hairpin and the driver weaves down the
///     straight chasing a point three metres in front of its nose;
///   * **how fast to be going**: from the tightest curvature within braking
///     distance. `v = sqrt(a / k)` is the speed at which a corner of curvature
///     `k` needs exactly `a` of lateral acceleration, and `a` is the one knob
///     that makes an opponent fast or slow without making it *drive*
///     differently.
library;

import 'dart:math' as math;

import 'track.dart';
import 'vehicle.dart';

/// A driver that follows the racing line.
final class WaypointDriver {
  WaypointDriver({
    required this.track,
    this.lineOffset = 0,
    this.corneringAcceleration = 12.0,
    this.speedLimit = 26.0,
    this.steerGain = 2.1,
  });

  final TrackPath track;

  /// Metres to the right of the centreline this driver aims for. Two karts
  /// with the same offset arrive at the same apex at the same moment and spend
  /// the race grinding along each other.
  final double lineOffset;

  /// Lateral acceleration the driver believes it has, m/s². The skill dial:
  /// higher corners faster and later.
  final double corneringAcceleration;

  /// The straight-line speed it will ask for, m/s.
  final double speedLimit;

  final double steerGain;

  /// The steering error of the last decision, radians. Exposed because "the
  /// opponent is pointing 40° off the line" is the symptom of every bug in
  /// here and is invisible from the outside otherwise.
  double lastHeadingError = 0;

  /// The input for this step.
  KartInput drive(KartBody kart, TrackProjection projection) {
    final double speed = kart.speed;

    // Where to point. The look-ahead is roughly the distance covered in a
    // third of a second, floored so that a stationary kart still has
    // somewhere to aim.
    final double lookAhead = 6.0 + speed * 0.42;
    final TrackSample aim = track.frameAt(projection.distance + lookAhead);
    final double aimX = aim.x + aim.normalX * lineOffset;
    final double aimZ = aim.z + aim.normalZ * lineOffset;
    // `atan2(x, z)` and not `atan2(z, x)`: heading zero faces +Z, so the
    // angle is measured from the z axis toward x. Writing the usual
    // `atan2(y, x)` here gives a driver that is correct only where the track
    // happens to run diagonally, which is just often enough to look like a
    // tuning problem.
    final double wanted = math.atan2(aimX - kart.x, aimZ - kart.z);
    final double error = wrapAngle(wanted - kart.heading);
    lastHeadingError = error;
    // Negated for the same reason `KartBody.step` negates: a positive steer is
    // the right of the picture, and heading grows toward the left.
    final double steer = (-error * steerGain).clamp(-1.0, 1.0);

    // How fast to be going. The window is the distance it takes to shed speed
    // at roughly the brake's authority, so the driver starts braking for the
    // hairpin from the back straight rather than at the board.
    final double window = 12 + speed * speed / 24;
    double tightest = 0;
    final double spacing = track.sampleSpacing;
    for (double ahead = 0; ahead < window; ahead += spacing * 2) {
      final double k =
          track.frameAt(projection.distance + ahead).curvature.abs();
      if (k > tightest) tightest = k;
    }
    final double cornerSpeed = tightest < 1e-4
        ? speedLimit
        : math.min(speedLimit, math.sqrt(corneringAcceleration / tightest));

    double throttle = 0;
    double brake = 0;
    if (speed < cornerSpeed - 0.5) {
      throttle = 1;
    } else if (speed > cornerSpeed + 1.5) {
      brake = math.min(1, (speed - cornerSpeed) / 6);
    } else {
      throttle = 0.35;
    }

    // Off the line by more than the road is wide means it is in the wall or
    // spun. Straightening out beats carrying on toward an apex it cannot
    // reach, and without this an opponent that clips a barrier stays pinned to
    // it for the rest of the race.
    if (projection.lateral.abs() > track.halfWidth + 0.5) {
      throttle = math.min(throttle, 0.6);
    }

    // The handbrake earns a mini-turbo, and only where a mini-turbo is
    // available: a long enough corner, taken fast enough. Held at random it
    // would just make the opponent slower, which is worse than not using it.
    final bool drift = steer.abs() > 0.55 &&
        speed > kart.tuning.driftMinSpeed + 2 &&
        tightest > 0.02;

    return KartInput(
      throttle: throttle,
      brake: brake,
      steer: steer,
      drift: drift,
    );
  }
}
