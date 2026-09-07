/// The kart itself: one rigid body on a flat plane, stepped at a fixed rate.
///
/// ## Why this and not a raycast vehicle
///
/// `rapier` and `cannon-es` both model a car as a rigid body with one raycast
/// per wheel: the ray finds the ground, a spring pushes the chassis up, and
/// friction at the contact point turns the wheel's rotation into a force. That
/// is the right model when the ground has a shape - a ramp, a kerb, a jump -
/// because the suspension is what makes the four contacts disagree.
///
/// This track is flat. Every wheel ray would return the same height, every
/// spring the same force, and the whole suspension solver would collapse to
/// "the kart is on the ground". What survives is the part that actually
/// decides how a kart drives: the tyre model, which is the split between the
/// velocity *along* the kart and the velocity *across* it. So the state here
/// is that split, and the arithmetic below is the bicycle model plus a lateral
/// friction term - which is exactly what the raycast vehicle reduces to on a
/// plane, with none of the machinery that has nothing to do.
///
/// The cost is stated rather than discovered: there is no jump, no banking and
/// no weight transfer. Adding a hill to the track means adding the wheel rays
/// back, and this file is where they would go.
///
/// ## The frame of reference
///
/// The world is right-handed with **+Y up**, the same one `MeshCamera` uses,
/// and the track lies in the XZ plane at y = 0. A heading of zero faces +Z:
///
/// ```
/// forward(h) = ( sin h, 0,  cos h)
/// right(h)   = (-cos h, 0,  sin h)
/// ```
///
/// [right] is **the right of the picture**, not an arbitrary perpendicular,
/// and it is derived rather than guessed: a chase camera sits at
/// `position - forward * distance`, so `MeshCamera.rightAxis` there works out
/// to `up × (-forward)`, which is the vector above. Getting that sign wrong is
/// not a subtle bug - it makes the left arrow key steer right - and
/// `chase_camera_test.dart` holds the two definitions against each other so
/// the agreement cannot rot.
///
/// Note the consequence, because it is counter-intuitive: `forward` rotates
/// *toward the left of the picture* as [heading] increases, so a steer input
/// of +1 ("right", as the player sees it) produces a **negative** heading
/// rate. That negation lives in exactly one place, [step], with this comment
/// above it.
library;

import 'dart:math' as math;

/// What the driver is asking for this step, whether the driver is a person or
/// [WaypointDriver].
///
/// Immutable and shared by both, deliberately: an opponent that reached into
/// the physics directly - setting a yaw rate, teleporting along the racing
/// line - would be racing a different game from the player, and the moment the
/// player caught it the difference would show as an opponent that corners in a
/// way no input can reproduce.
final class KartInput {
  const KartInput({
    this.throttle = 0,
    this.brake = 0,
    this.steer = 0,
    this.drift = false,
  });

  static const KartInput idle = KartInput();

  /// 0 to 1.
  final double throttle;

  /// 0 to 1. Brakes while moving forward, reverses from a near stop.
  final double brake;

  /// -1 (left of the picture) to +1 (right of the picture).
  final double steer;

  /// The handbrake: less rear grip, more steering lock, and a mini-turbo
  /// charging while it is held.
  final bool drift;

  KartInput copyWith({
    double? throttle,
    double? brake,
    double? steer,
    bool? drift,
  }) =>
      KartInput(
        throttle: throttle ?? this.throttle,
        brake: brake ?? this.brake,
        steer: steer ?? this.steer,
        drift: drift ?? this.drift,
      );

  @override
  String toString() => 'KartInput(throttle: $throttle, brake: $brake, '
      'steer: $steer, drift: $drift)';
}

/// Every number that decides how a kart feels, in one place.
///
/// Separated from [KartBody] so that an opponent can be given a slightly
/// slower one without a second physics implementation, and so that tuning is a
/// diff in one class rather than a hunt through the step function.
final class KartTuning {
  const KartTuning({
    this.enginePower = 15.0,
    this.brakePower = 26.0,
    this.reversePower = 9.0,
    this.maxSpeed = 27.0,
    this.maxReverseSpeed = 7.0,
    this.drag = 0.014,
    this.rollingResistance = 0.2,
    this.wheelbase = 1.55,
    this.maxSteerAngle = 0.62,
    this.corneringMargin = 1.25,
    this.yawResponse = 11.0,
    this.grip = 9.0,
    this.maxLateralAcceleration = 14.0,
    this.driftGrip = 1.9,
    this.driftSteerGain = 1.55,
    this.driftMinSpeed = 7.0,
    this.miniTurboCharge = 0.85,
    this.boostDuration = 1.1,
    this.boostFactor = 1.32,
    this.boostPower = 26.0,
  });

  /// Forward acceleration at full throttle, m/s².
  final double enginePower;
  final double brakePower;
  final double reversePower;

  /// Top speed on a clean surface, m/s. 27 m/s is 97 km/h, which reads as fast
  /// with a kart 1.6 m long and a track 11 m wide.
  final double maxSpeed;
  final double maxReverseSpeed;

  /// Quadratic air drag, per metre. This is what makes the top speed an
  /// *approach* rather than a clamp the player can feel snapping on.
  final double drag;

  /// Linear resistance, which is what brings the kart to a stop rather than
  /// leaving it coasting forever at 0.3 m/s.
  final double rollingResistance;

  final double wheelbase;

  /// The steering lock at a standstill, radians.
  final double maxSteerAngle;

  /// How much more corner the steering may ask for than the tyres can give.
  ///
  /// **This is the "steering tightens with speed" term**, and the shape of it
  /// matters more than the number. A fixed lock is unusable: the yaw rate of a
  /// bicycle model is `v · tan δ / L`, so full lock at 27 m/s asks for a
  /// 6.5-metre radius and 112 m/s² of grip that does not exist, and the kart
  /// spends every corner sideways whatever the player does. A *linear* falloff
  /// - the first thing tried here - is barely better, because the grip-limited
  /// radius grows with `v²` and no straight line can follow that: at 18 m/s
  /// the kart was still demanding three times the grip it had, so a
  /// deliberate handbrake drift and an ordinary corner produced the same
  /// slide and the drift button did nothing.
  ///
  /// So the lock is derived from the limit instead: at any speed the widest
  /// the steering will ask for is the radius the tyres can hold, times this
  /// margin. At 1.0 the kart can never be made to slide by steering; at 1.25
  /// it understeers gently at full lock, which is the feedback that says "too
  /// fast for this corner" without taking the car away from the player. Below
  /// about 6 m/s the geometry's own [maxSteerAngle] is the smaller of the two
  /// and the kart parks normally.
  final double corneringMargin;

  /// How fast the yaw rate reaches the value the steering asks for, per
  /// second. A step change here would make the kart pivot instantly, which
  /// looks like a bug even though the path is the same.
  final double yawResponse;

  /// How fast sideways velocity is scrubbed off, per second. High is grippy.
  final double grip;

  /// The most lateral acceleration the tyres can produce, m/s².
  ///
  /// **Without this the kart has no cornering limit at all**, and that is not
  /// a subtlety - it is the difference between a racing game and a cursor.
  /// [grip] alone removes sideways velocity at a rate proportional to how much
  /// there is, so a bicycle model steering a six-metre radius at 25 m/s simply
  /// carves it: the required 100 m/s² is produced without complaint, no corner
  /// is ever too fast, and braking is pointless. Capping the rate at fourteen
  /// - about 1.4 g, which is roughly what a kart on slicks actually has - is
  /// what makes the kart run wide when it is asked for more than it has, and
  /// makes "brake, turn, get on the power" the fast way round.
  ///
  /// It is also the number that makes [KartTuning.steerFalloff] matter: at
  /// full lock and full speed the geometry asks for a 6.5 m radius, the tyres
  /// refuse, and the kart understeers straight on - which is precisely the
  /// feedback a player needs to learn to slow down.
  final double maxLateralAcceleration;

  /// [grip] while the handbrake is held. The whole drift is this one number.
  final double driftGrip;

  /// Extra steering lock while drifting, so the nose can point inside the
  /// corner while the kart travels along it.
  final double driftSteerGain;

  /// Below this speed the handbrake does nothing but slow the kart, because a
  /// drift from a standstill is a pirouette and reads as a broken kart.
  final double driftMinSpeed;

  /// Seconds of drifting that earn a mini-turbo.
  final double miniTurboCharge;
  final double boostDuration;

  /// What the top speed is multiplied by while boosting.
  final double boostFactor;

  /// Extra acceleration while boosting, m/s². The kick, as opposed to the
  /// raised ceiling.
  final double boostPower;
}

/// One kart's state and the step that advances it.
///
/// The velocity is stored in the **kart's own frame** - [forwardSpeed] along
/// the nose and [lateralSpeed] across it - and not in world coordinates. Both
/// are equivalent, and this one is the one where "grip" is a single
/// subtraction from a single field instead of a projection, a scale and a
/// recomposition every step. What it costs is the counter-rotation in [step]:
/// when the kart turns, the *world* velocity does not, so the two body
/// components have to be rotated back by the same angle. Forgetting that
/// rotation is the classic bug in this formulation - the kart's velocity turns
/// with it for free, every corner becomes perfectly gripped, and the drift
/// silently does nothing.
final class KartBody {
  KartBody({
    required this.x,
    required this.z,
    required this.heading,
    this.tuning = const KartTuning(),
  });

  final KartTuning tuning;

  double x;
  double z;

  /// Radians. Zero faces +Z; increasing turns toward the left of the picture.
  double heading;

  /// Velocity along the nose, m/s. Negative is reversing.
  double forwardSpeed = 0;

  /// Velocity across the kart, m/s, positive toward the right of the picture.
  ///
  /// This is the slip. It is what a drift is made of and what the tyres eat.
  double lateralSpeed = 0;

  /// Radians per second, in [heading]'s sense.
  double yawRate = 0;

  /// Seconds of uninterrupted drifting banked toward a mini-turbo.
  double driftCharge = 0;

  /// Seconds of boost left.
  double boostRemaining = 0;

  /// Whether the last step was actually sliding, for the camera and the HUD.
  bool drifting = false;

  /// The steering angle the last step used, radians, for drawing the front
  /// wheels turned. Purely presentational.
  double steerAngle = 0;

  double get forwardX => math.sin(heading);
  double get forwardZ => math.cos(heading);

  /// The right of the *picture*; see the library comment for the derivation.
  double get rightX => -math.cos(heading);
  double get rightZ => math.sin(heading);

  /// Ground speed, m/s: the length of the velocity, not the forward component.
  ///
  /// A drifting kart's [forwardSpeed] drops while it is travelling just as
  /// fast sideways, and a speedometer wired to [forwardSpeed] would show the
  /// kart slowing down every time the player did the fastest thing available.
  double get speed =>
      math.sqrt(forwardSpeed * forwardSpeed + lateralSpeed * lateralSpeed);

  double get worldVelocityX => forwardX * forwardSpeed + rightX * lateralSpeed;
  double get worldVelocityZ => forwardZ * forwardSpeed + rightZ * lateralSpeed;

  /// Replaces the velocity from world components. Used by the wall response,
  /// which reasons in the track's frame and not the kart's.
  void setWorldVelocity(double vx, double vz) {
    forwardSpeed = vx * forwardX + vz * forwardZ;
    lateralSpeed = vx * rightX + vz * rightZ;
  }

  /// Advances by exactly [dt] seconds.
  ///
  /// [gripScale] and [powerScale] are the surface: 1 on the road, lower off
  /// it. They are arguments rather than a field because the surface is the
  /// *track's* answer about where the kart is, and a kart that cached it would
  /// keep the grass's grip for one step after returning to the road - which is
  /// the step the player is counter-steering in.
  void step(
    KartInput input,
    double dt, {
    double gripScale = 1,
    double powerScale = 1,
  }) {
    if (dt <= 0) return;

    // ---- the mini-turbo, resolved before anything reads `drifting` --------
    final bool wantsDrift = input.drift && forwardSpeed > tuning.driftMinSpeed;
    if (wantsDrift) {
      // Only a *steered* drift charges. Holding the handbrake in a straight
      // line is not a technique and rewarding it would make the fastest line
      // "hold every button".
      if (input.steer.abs() > 0.25) driftCharge += dt;
    } else {
      if (driftCharge >= tuning.miniTurboCharge) {
        boostRemaining = tuning.boostDuration;
      }
      driftCharge = 0;
    }
    drifting = wantsDrift;
    if (boostRemaining > 0) boostRemaining = math.max(0, boostRemaining - dt);
    final bool boosting = boostRemaining > 0;

    // ---- longitudinal ----------------------------------------------------
    double drive = input.throttle * tuning.enginePower * powerScale;
    if (boosting) drive += tuning.boostPower;
    if (input.brake > 0) {
      // The brake becomes reverse only once the kart has genuinely stopped.
      // Switching on the sign of the speed alone makes a kart braking hard
      // from 30 m/s flip into reverse for one step as it crosses zero, and the
      // player sees the kart twitch backwards at the end of every stop.
      drive -= input.brake *
          (forwardSpeed > 0.5 ? tuning.brakePower : tuning.reversePower);
    }
    forwardSpeed += drive * dt;
    forwardSpeed -= (tuning.drag * forwardSpeed * forwardSpeed.abs() +
            tuning.rollingResistance * forwardSpeed) *
        dt;
    if (drifting) {
      // A slide scrubs speed. Without this a drift is strictly faster than a
      // clean line everywhere and the only correct way to play is to hold the
      // handbrake from lights to flag.
      forwardSpeed -= forwardSpeed * math.min(1, 0.55 * dt);
    }
    final double ceiling =
        tuning.maxSpeed * powerScale * (boosting ? tuning.boostFactor : 1);
    forwardSpeed = forwardSpeed.clamp(-tuning.maxReverseSpeed, ceiling);

    // ---- steering --------------------------------------------------------
    // The tightest radius the tyres will hold at this speed, and the steering
    // angle that asks for exactly it. See [KartTuning.corneringMargin] for why
    // the lock is derived from the grip rather than faded out linearly.
    final double speed = forwardSpeed.abs();
    final double gripRadius = math.max(
      tuning.wheelbase,
      speed *
          speed /
          (tuning.maxLateralAcceleration *
              tuning.corneringMargin *
              math.max(gripScale, 0.05)),
    );
    final double lock = math.min(
        tuning.maxSteerAngle, math.atan(tuning.wheelbase / gripRadius));
    // The one negation the library comment promised: +1 is the right of the
    // picture, and `forward` rotates toward the left as `heading` grows.
    final double delta =
        -input.steer * lock * (drifting ? tuning.driftSteerGain : 1.0);
    steerAngle = delta;

    // The bicycle model. Multiplied by `forwardSpeed` and not by `speed`, and
    // that is what makes full lock at a standstill do nothing at all: a kart
    // that pivoted on the spot could be aimed anywhere before the lights and
    // would be able to spin its way around a hairpin at walking pace.
    final double targetYawRate =
        forwardSpeed * math.tan(delta) / tuning.wheelbase;
    yawRate += (targetYawRate - yawRate) * math.min(1, tuning.yawResponse * dt);

    final double dh = yawRate * dt;
    heading += dh;

    // The counter-rotation. World velocity is unchanged by the kart turning
    // under it, so the two body components rotate by -dh.
    final double cos = math.cos(dh);
    final double sin = math.sin(dh);
    final double nextForward = forwardSpeed * cos - lateralSpeed * sin;
    final double nextLateral = forwardSpeed * sin + lateralSpeed * cos;
    forwardSpeed = nextForward;
    lateralSpeed = nextLateral;

    // ---- the tyres -------------------------------------------------------
    final double grip = (drifting ? tuning.driftGrip : tuning.grip) * gripScale;
    // Two limits, and the kart is held by whichever bites first. The
    // proportional term is the tyre finding its slip angle; the ceiling is the
    // tyre running out of grip, which is the one that makes a corner have a
    // speed. See [KartTuning.maxLateralAcceleration].
    final double demanded = lateralSpeed.abs() * grip;
    final double available = tuning.maxLateralAcceleration *
        gripScale *
        (drifting ? tuning.driftGrip / tuning.grip : 1.0);
    final double reduction =
        math.min(lateralSpeed.abs(), math.min(demanded, available) * dt);
    lateralSpeed -= lateralSpeed.isNegative ? -reduction : reduction;

    // ---- integrate -------------------------------------------------------
    x += worldVelocityX * dt;
    z += worldVelocityZ * dt;
  }

  @override
  String toString() => 'KartBody(${x.toStringAsFixed(2)}, '
      '${z.toStringAsFixed(2)}, heading ${heading.toStringAsFixed(3)}, '
      '${speed.toStringAsFixed(1)} m/s)';
}

/// [angle] folded into `[-pi, pi)`.
///
/// Shared by the camera and the opponent because both make the same mistake
/// without it: a difference of two headings either side of the wrap reads as
/// almost a full turn, and the camera whips round the long way exactly once
/// per lap while the opponent steers away from the corner it is entering.
double wrapAngle(double angle) {
  const double twoPi = math.pi * 2;
  double wrapped = (angle + math.pi) % twoPi;
  if (wrapped < 0) wrapped += twoPi;
  return wrapped - math.pi;
}
