/// The camera behind the kart, which is most of what makes a racer readable.
///
/// Two separate things, and a racer needs both:
///
///   * **lag.** The camera never points where the kart points; it moves toward
///     it. A camera rigidly bolted behind the kart makes the *world* rotate
///     around a stationary kart, and forty seconds of that is genuinely
///     nauseating - it is the single most common mistake in a first attempt at
///     a chase camera, and it is why the yaw here is smoothed and not
///     assigned;
///   * **lead.** The camera aims slightly further round the corner than the
///     kart is currently pointing, by extrapolating the yaw rate. Without it
///     the apex of every corner is off the side of the screen at the moment
///     the player has to aim at it, and the track reads as a series of blind
///     turns.
///
/// The two pull in opposite directions on purpose. Lag alone leaves the camera
/// permanently behind the corner; lead alone is as stiff as no camera at all.
///
/// ## Frame-rate independence
///
/// The smoothing is `1 - exp(-dt / tau)` and not a constant per step. A fixed
/// `0.1` per step is a different camera at 60 Hz and at 144 Hz - stiffer the
/// faster the machine - which means the game *looks* different on better
/// hardware and no amount of testing on one machine finds it. Written this
/// way, halving the step and doubling the step count lands within float error
/// of the same place, which is what `chase_camera_test.dart` asserts.
///
/// The camera is stepped by the **fixed simulation step**, not by the frame,
/// so it is exactly as reproducible as the physics.
library;

import 'dart:math' as math;

import 'package:dart_ui/src/graphics/mesh/mesh3d.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_rasterizer.dart';

import 'vehicle.dart';

/// A camera that follows one kart.
final class ChaseCamera {
  ChaseCamera({
    this.distance = 8.2,
    this.height = 3.4,
    this.targetHeight = 1.35,
    this.lookAhead = 5.0,
    this.yawTau = 0.16,
    this.positionTau = 0.06,
    this.leadSeconds = 0.34,
    this.speedPullback = 3.6,
    this.fovYRadians = 1.0472,
  });

  /// How far behind the kart the eye sits at rest, metres.
  final double distance;

  /// How far above the kart the eye sits, metres.
  final double height;

  /// How far above the road the camera looks, metres. Aiming at the road
  /// itself puts the horizon at the top of the screen and the corner the
  /// player is about to take below the bottom of it.
  final double targetHeight;

  /// How far in front of the kart the camera looks, metres, at full speed.
  final double lookAhead;

  /// Seconds for the yaw to cover 63% of a step change.
  final double yawTau;

  /// The same, for the point the camera looks at. Much shorter than [yawTau]:
  /// a target that lagged as much as the yaw would let the kart slide out of
  /// the middle of the picture on every direction change.
  final double positionTau;

  /// How many seconds of yaw rate the camera extrapolates. This is the lead.
  final double leadSeconds;

  /// Extra metres of distance at top speed, which is the cheapest sense of
  /// speed there is.
  final double speedPullback;

  final double fovYRadians;

  double _yaw = 0;
  double _targetX = 0;
  double _targetY = 0;
  double _targetZ = 0;
  double _distance = 0;
  bool _seeded = false;

  double get yaw => _yaw;

  Vector3 get target => Vector3(_targetX, _targetY, _targetZ);

  /// Places the camera exactly where [follow] would settle, with no easing.
  ///
  /// Called once before the first frame. Without it the camera starts at the
  /// origin pointing north and spends the first second of every race flying in
  /// from wherever `Vector3.zero` happens to be, which reads as the track
  /// loading in.
  void snapTo(KartBody kart) {
    _seeded = true;
    _yaw = kart.heading + math.pi;
    _distance = distance;
    _aimAt(kart, 1);
  }

  /// Advances the camera by [dt] seconds behind [kart].
  void follow(KartBody kart, double dt, {double maxSpeed = 27}) {
    if (!_seeded) {
      snapTo(kart);
      return;
    }
    if (dt <= 0) return;

    // The kart's heading a fifth of a second from now, if it keeps turning as
    // it is. Clamped, because a kart spinning after a crash would otherwise
    // whip the camera through several turns while the player is trying to work
    // out which way is forward.
    final double lead = (kart.yawRate * leadSeconds).clamp(-0.55, 0.55);
    final double desiredYaw = kart.heading + lead + math.pi;

    // Toward the shortest arc, which is the whole reason `wrapAngle` exists:
    // the difference between 3.10 and -3.10 radians is 0.08, not 6.2, and a
    // camera that took the long way round would spin once per lap.
    _yaw += wrapAngle(desiredYaw - _yaw) * _alpha(dt, yawTau);

    final double speedRatio = (kart.speed / maxSpeed).clamp(0.0, 1.0);
    final double wanted = distance + speedPullback * speedRatio;
    _distance += (wanted - _distance) * _alpha(dt, yawTau);

    _aimAt(kart, _alpha(dt, positionTau), speedRatio: speedRatio);
  }

  void _aimAt(KartBody kart, double alpha, {double speedRatio = 0}) {
    final double ahead = lookAhead * (0.35 + 0.65 * speedRatio);
    final double wantedX = kart.x + kart.forwardX * ahead;
    final double wantedZ = kart.z + kart.forwardZ * ahead;
    _targetX += (wantedX - _targetX) * alpha;
    _targetY += (targetHeight - _targetY) * alpha;
    _targetZ += (wantedZ - _targetZ) * alpha;
  }

  /// The camera this frame, in the form the mesh renderer takes.
  ///
  /// [MeshCamera] is an orbit camera - a target, a distance, a yaw and a pitch
  /// - and a chase camera is exactly that with the yaw driven by the kart
  /// instead of by a mouse. The pitch is derived from [height] and the current
  /// distance rather than being a separate knob, so pulling back at speed
  /// flattens the view instead of leaving the camera staring at the roof.
  MeshCamera get camera {
    final double pitch = math.atan2(height, _distance);
    final double radius = math.sqrt(height * height + _distance * _distance);
    return MeshCamera(
      target: Vector3(_targetX, _targetY, _targetZ),
      distance: radius,
      yaw: _yaw,
      pitch: pitch,
      fovYRadians: fovYRadians,
      // Fixed, and generous at the far end: the track is 250 m across and a
      // near plane derived from the distance - which is what
      // `MeshCamera.frame` does - would be 8 mm here and spend the whole depth
      // buffer on the first two metres, so the far side of the circuit would
      // z-fight with itself.
      near: 0.25,
      far: 900,
    );
  }

  static double _alpha(double dt, double tau) =>
      tau <= 0 ? 1.0 : 1 - math.exp(-dt / tau);
}
