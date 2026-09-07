/// The state machine that decides which clip a character is playing.
///
/// It exists as its own type, with no mesh and no clip in it, because the
/// thing that is actually hard here is not playing an animation — it is
/// deciding *which* one, and that decision is a handful of thresholds whose
/// wrong values are only visible as a character that twitches. A test can
/// state "airborne for one frame while walking down a slope" and assert that
/// the state did not change; a person watching the game cannot.
///
/// ## The two thresholds and the flicker each one prevents
///
///   * [runSpeedThreshold]. A character stopped by a wall still has whatever
///     horizontal speed the input asked for until the collision zeroes it, and
///     a character pushed by a stomp bounce has a tiny residual speed for
///     several frames. Comparing against zero puts it in [MotionState.run]
///     with its feet sliding on the spot.
///   * [airborneGrace]. Walking off the lip of one box onto the next reports
///     `onGround == false` for a single step. Switching to [MotionState.fall]
///     on that step and back on the next produces a one-frame pose change
///     every time the character crosses a seam in the floor, which reads as
///     the character stumbling.
library;

/// What a character is doing, in the vocabulary the animation table is keyed
/// by.
enum MotionState {
  idle,
  run,

  /// Rising. Split from [fall] because the two want different poses and
  /// because "which half of the arc" is exactly what a single `airborne` state
  /// throws away.
  jump,
  fall,

  /// Hit and knocked back, for [MotionStateMachine.hurtDuration].
  hurt,

  /// Out of lives. Terminal: nothing transitions out of it.
  dead,
}

/// Decides a [MotionState] from the body's own facts, once per fixed step.
///
/// Fed the same numbers the physics produced and nothing else — no input, no
/// clip, no time of day. That is what makes it deterministic and what makes a
/// replay of the same physics produce the same animation.
final class MotionStateMachine {
  MotionStateMachine({
    this.runSpeedThreshold = 0.35,
    this.airborneGrace = 0.08,
    this.hurtDuration = 0.7,
  });

  /// Below this horizontal speed a grounded character is idle, not running.
  final double runSpeedThreshold;

  /// How long the machine keeps reporting a grounded state after the ground
  /// disappears.
  final double airborneGrace;

  /// How long [MotionState.hurt] holds before the machine looks at the body
  /// again.
  final double hurtDuration;

  MotionState _state = MotionState.idle;
  double _timeInState = 0;
  double _timeAirborne = 0;

  MotionState get state => _state;

  /// Seconds since the current state was entered. What the clip's playback
  /// time is derived from, so that entering a state restarts its clip.
  double get timeInState => _timeInState;

  /// Advances by [dt] and returns the state after it.
  ///
  /// [hurt] is an *edge*: pass true on the step the character was hit, not for
  /// as long as it is recovering. The machine owns the recovery window,
  /// because sharing that duration between the caller and here is how the
  /// animation and the invulnerability end up disagreeing.
  MotionState update({
    required double dt,
    required bool onGround,
    required double velocityX,
    required double velocityY,
    bool hurt = false,
    bool alive = true,
  }) {
    _timeInState += dt;
    _timeAirborne = onGround ? 0 : _timeAirborne + dt;

    if (!alive) return _enter(MotionState.dead);
    if (_state == MotionState.dead) return _state;

    if (hurt) return _enter(MotionState.hurt);
    if (_state == MotionState.hurt) {
      if (_timeInState < hurtDuration) return _state;
      // Falls through to the ordinary decision below rather than entering a
      // named state, so a character hit in mid-air recovers into `fall` and
      // one hit standing still recovers into `idle`.
    }

    final MotionState wanted;
    if (!onGround && _timeAirborne > airborneGrace) {
      wanted = velocityY > 0 ? MotionState.jump : MotionState.fall;
    } else {
      wanted = velocityX.abs() >= runSpeedThreshold
          ? MotionState.run
          : MotionState.idle;
    }
    return _enter(wanted);
  }

  /// Forces [state], resetting the clip. For a respawn, where the character
  /// must not carry the last frame of its death into its new life.
  void reset([MotionState state = MotionState.idle]) {
    _state = state;
    _timeInState = 0;
    _timeAirborne = 0;
  }

  MotionState _enter(MotionState next) {
    if (next == _state) return _state;
    _state = next;
    _timeInState = 0;
    return _state;
  }
}
