/// The camera a side-scroller needs, which is not an orbit camera.
///
/// [OrbitCameraController] beside [MeshCamera] is the right control scheme for
/// a viewer and the wrong one for a game: it is driven by a pointer and it
/// turns about a fixed point. What a side-scroller wants is a camera that
/// *follows* — and the difference between one that feels right and one that
/// makes people put the controller down is three details, all of them here:
///
///   1. **A dead zone.** A camera locked to the character moves whenever the
///      character does, so the whole screen shifts under every small hop and
///      every step. Inside the dead zone the camera does not move at all, and
///      the character walks about within a still picture — which is what
///      Sonic, Mario and Metal Slug all do.
///   2. **Lead.** The camera aims ahead of the direction of travel, so that
///      running right shows more of what is to the right. Without it you are
///      always looking at where you have been, and the first thing you meet at
///      speed is whatever was just off the edge of the screen.
///   3. **Damping on the lead, not on the position.** The lead is what has to
///      ease, because it flips sign the instant the character turns around and
///      an undamped flip snaps the whole view across. The position then
///      follows the dead zone exactly, which keeps the guarantee that a
///      character inside the zone moves the camera by nothing at all — a
///      guarantee that a smoothed position quietly breaks, because an
///      exponential approach never quite arrives and the camera creeps.
///
/// Vertical is treated differently from horizontal on purpose: see
/// [verticalDeadZone] and [groundedOnly].
library;

import 'dart:math' as math;

/// A dead-zone follow camera in the game's plane.
///
/// Owns two numbers and updates them from the target's. It does not know what
/// a [MeshCamera] is; the composer builds one from [x] and [y]. That is what
/// lets this be tested by stating positions and reading positions.
final class FollowCamera {
  FollowCamera({
    required this.horizontalDeadZone,
    required this.verticalDeadZone,
    this.lead = 0,
    this.leadResponse = 3.0,
    this.groundedOnly = true,
    double x = 0,
    double y = 0,
  })  : _x = x,
        _y = y;

  /// Half the width of the still box, in world units. The character can move
  /// this far either side of the camera before it follows.
  final double horizontalDeadZone;

  /// Half the height of the still box.
  ///
  /// Larger than [horizontalDeadZone] in practice, because a jump is a large,
  /// brief vertical excursion that the camera should ignore entirely. A
  /// vertical dead zone the size of the horizontal one turns every jump into a
  /// camera move.
  final double verticalDeadZone;

  /// How far ahead of the character the camera aims at full speed.
  final double lead;

  /// How fast the lead reaches its target, in reciprocal seconds. The lead
  /// covers `1 - e^-1` — about 63% — of the remaining distance in
  /// `1 / leadResponse` seconds.
  final double leadResponse;

  /// Whether the vertical follow waits for the character to be on the ground.
  ///
  /// True by default, and it is the single biggest difference between a camera
  /// that feels right and one that makes people ill: with it, a jump moves the
  /// character up the screen and the camera holds still. Without it, the
  /// camera rises with every jump and the ground bobs, which is the "seasick"
  /// complaint about home-made platformers. The camera still follows a *fall*
  /// off a ledge, because the alternative is losing the character off the
  /// bottom of the screen.
  final bool groundedOnly;

  double _x;
  double _y;
  double _lead = 0;

  double get x => _x;
  double get y => _y;

  /// The lead currently applied, signed. Exposed for the test that asserts the
  /// lead eases rather than snapping.
  double get appliedLead => _lead;

  /// Places the camera exactly, with no easing. For a spawn or a respawn,
  /// where a camera that eased in from the last death would show a second of
  /// the wrong part of the level.
  void snapTo(double targetX, double targetY, {double facing = 1}) {
    _lead = lead * facing.sign;
    _x = targetX + _lead;
    _y = targetY;
  }

  /// Advances the camera by [dt] toward the character at ([targetX],
  /// [targetY]) travelling in direction [facing] (-1, 0 or +1).
  void follow({
    required double targetX,
    required double targetY,
    required double facing,
    required double dt,
    bool onGround = true,
  }) {
    // A zero facing — the character standing still — holds the lead where it
    // is rather than pulling it back to centre. Recentring on every stop makes
    // the camera drift back and forth through the whole lead distance each
    // time the player pauses, which is more distracting than the lead itself.
    if (facing != 0) {
      final double wanted = lead * facing.sign;
      // Exponential approach, framed in dt so that the same easing happens at
      // any step size. `1 - exp(-k dt)` and not `k * dt`: the linear form
      // overshoots and oscillates once `k * dt` passes 1, which a long frame
      // reaches.
      _lead += (wanted - _lead) * (1 - math.exp(-leadResponse * dt));
    }

    final double aimX = targetX + _lead;
    if (aimX > _x + horizontalDeadZone) {
      _x = aimX - horizontalDeadZone;
    } else if (aimX < _x - horizontalDeadZone) {
      _x = aimX + horizontalDeadZone;
    }

    // Falling always pulls the camera; rising only does when the character is
    // on the ground, which means "has landed somewhere higher".
    final bool verticalFollows = !groundedOnly || onGround;
    if (targetY < _y - verticalDeadZone) {
      _y = targetY + verticalDeadZone;
    } else if (verticalFollows && targetY > _y + verticalDeadZone) {
      _y = targetY - verticalDeadZone;
    }
  }

  /// Keeps the camera inside the level, so that the view never shows the void
  /// beyond its ends.
  ///
  /// Applied after [follow] rather than inside it: clamping the aim point
  /// instead would fight the dead zone at the edges, holding the camera one
  /// dead zone short of the wall and then jerking it when the character turned
  /// around.
  void clampTo({
    required double minX,
    required double maxX,
    required double minY,
  }) {
    if (maxX >= minX) _x = _x.clamp(minX, maxX);
    if (_y < minY) _y = minY;
  }
}
