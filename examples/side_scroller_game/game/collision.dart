/// Axis-aligned boxes and the swept resolution a platformer stands on.
///
/// Nothing here knows about this game, about a mesh or about a frame. It is
/// the arithmetic, kept apart from everything else for one reason: a collision
/// bug is invisible in a running game — the character catches on something for
/// two frames and you cannot say whether the floor, the input or the camera
/// did it — and it is trivially visible in a test that states an overlap and
/// asserts where the body ended up. `test/examples/side_scroller_game/` is
/// that test.
///
/// ## The three failures this is written against
///
/// Each is a specific, recognisable wrongness, so each is named with it:
///
///   1. **Falling through the floor.** A body moving faster than its own
///      height in one step is on one side of the floor before the step and the
///      other side after it, and an overlap test run only at the end sees no
///      overlap at all. [moveAndCollide] therefore splits the motion into
///      substeps no longer than half the body, which is the cheap form of
///      swept collision and is exact enough for a platformer. Terminal
///      velocity is the other half of the answer and belongs to the caller.
///   2. **Catching on a seam.** A floor built from two boxes side by side has
///      a vertical joint in it. A body resting exactly on top, walking right,
///      overlaps the second box by zero on the vertical axis — and a test
///      written with `>=` calls that an overlap, resolves it horizontally, and
///      the character stops dead in the middle of flat ground. The test here
///      is strict (`>`) and additionally requires [_epsilon] of real
///      penetration before it does anything.
///   3. **Sticking to a wall.** Resolving both axes from one overlap has to
///      choose an axis, and the usual choice — the smaller penetration — picks
///      the *vertical* one when a body slides along a wall while falling, so
///      the fall stops and the body hangs there. Resolving the axes
///      separately, each against its own motion, cannot make that mistake: the
///      horizontal pass stops the horizontal motion and leaves the fall alone.
library;

import 'dart:math' as math;

/// A rectangle in the game's plane, `y` upward.
///
/// `y` upward and not downward, unlike every 2D coordinate system in this
/// framework's widget layer. The physics has to agree with the *3D* space the
/// game is drawn in — where `+Y` is up, because that is what every model on
/// disk assumes — and a simulation that ran in screen coordinates would need
/// a sign flip at the boundary that somebody would eventually get wrong in one
/// direction only.
final class Aabb {
  const Aabb({
    required this.left,
    required this.bottom,
    required this.right,
    required this.top,
  });

  /// A box from its centre and half extents, which is how a body is carried.
  factory Aabb.centred({
    required double x,
    required double y,
    required double halfWidth,
    required double halfHeight,
  }) =>
      Aabb(
        left: x - halfWidth,
        bottom: y - halfHeight,
        right: x + halfWidth,
        top: y + halfHeight,
      );

  final double left;
  final double bottom;
  final double right;
  final double top;

  double get width => right - left;
  double get height => top - bottom;
  double get centreX => (left + right) / 2;
  double get centreY => (bottom + top) / 2;

  /// Whether the two boxes share area. Touching is **not** overlapping; see
  /// failure 2 in the library documentation.
  bool overlaps(Aabb other) =>
      left < other.right &&
      right > other.left &&
      bottom < other.top &&
      top > other.bottom;

  bool containsPoint(double x, double y) =>
      x >= left && x <= right && y >= bottom && y <= top;

  Aabb translated(double dx, double dy) => Aabb(
        left: left + dx,
        bottom: bottom + dy,
        right: right + dx,
        top: top + dy,
      );

  Aabb inflated(double amount) => Aabb(
        left: left - amount,
        bottom: bottom - amount,
        right: right + amount,
        top: top + amount,
      );

  @override
  String toString() => 'Aabb(${left.toStringAsFixed(2)}, '
      '${bottom.toStringAsFixed(2)}, ${right.toStringAsFixed(2)}, '
      '${top.toStringAsFixed(2)})';
}

/// Where a body ended up and what it hit on the way.
final class SweepResult {
  const SweepResult({
    required this.x,
    required this.y,
    required this.velocityX,
    required this.velocityY,
    required this.onGround,
    required this.hitCeiling,
    required this.hitWall,
  });

  /// The body's centre after the move.
  final double x;
  final double y;

  /// The velocity with the blocked components zeroed. Only the component along
  /// the axis that was blocked: a body that lands while running keeps its
  /// horizontal speed, which is the difference between a platformer and glue.
  final double velocityX;
  final double velocityY;

  /// Standing on something after the move. The flag a jump, an animation state
  /// and coyote time all read.
  final bool onGround;

  final bool hitCeiling;

  /// Blocked horizontally. Separate from [velocityX] being zero, because a
  /// body can be stopped by having no input at all.
  final bool hitWall;
}

/// How much penetration counts as a collision at all.
///
/// A body resting on a floor is at exactly the floor's top, and floating point
/// puts it a fraction above or below from one step to the next. Without a
/// margin the body alternates between "on the ground" and "falling" every
/// frame, and the animation state machine flickers between idle and fall while
/// the character stands still.
const double _epsilon = 1e-6;

/// Moves a body by its velocity for [dt] and pushes it out of [solids].
///
/// The axes are resolved separately, horizontal first, and the motion is
/// substepped so that no substep moves the body further than half its own
/// extent. See the library documentation for why both of those are the design
/// rather than an optimisation.
///
/// [solids] is scanned in full per substep. That is `O(solids × substeps)` and
/// it is deliberate at this scale: a level of a few dozen boxes costs less to
/// scan than a broad phase costs to maintain, and a spatial index that is
/// wrong produces a character that walks through one specific wall.
SweepResult moveAndCollide({
  required double x,
  required double y,
  required double halfWidth,
  required double halfHeight,
  required double velocityX,
  required double velocityY,
  required double dt,
  required List<Aabb> solids,
}) {
  final double totalX = velocityX * dt;
  final double totalY = velocityY * dt;

  // One substep per half-extent of travel, on whichever axis travels further
  // relative to the body. A body 1 unit tall falling 4 units in a step takes
  // eight substeps and cannot be on the far side of a floor at the end of any
  // of them.
  final double spanX =
      halfWidth <= 0 ? double.infinity : totalX.abs() / halfWidth;
  final double spanY =
      halfHeight <= 0 ? double.infinity : totalY.abs() / halfHeight;
  final double span = math.max(spanX, spanY);
  final int substeps =
      span.isFinite ? math.max(1, math.min(64, span.ceil())) : 1;

  double px = x;
  double py = y;
  double vx = velocityX;
  double vy = velocityY;
  var onGround = false;
  var hitCeiling = false;
  var hitWall = false;

  for (var step = 0; step < substeps; step++) {
    px += totalX / substeps;
    final Aabb afterX = Aabb.centred(
        x: px, y: py, halfWidth: halfWidth, halfHeight: halfHeight);
    for (final Aabb solid in solids) {
      if (!_penetrates(afterX, solid)) continue;
      // Pushed back along the direction of travel, not along the shortest
      // exit. The shortest exit from a deep overlap teleports the body to the
      // far side of a thin wall it was walking into.
      if (totalX > 0) {
        px = solid.left - halfWidth - _epsilon;
      } else if (totalX < 0) {
        px = solid.right + halfWidth + _epsilon;
      } else {
        continue;
      }
      vx = 0;
      hitWall = true;
    }

    py += totalY / substeps;
    final Aabb afterY = Aabb.centred(
      x: px,
      y: py,
      halfWidth: halfWidth,
      halfHeight: halfHeight,
    );
    for (final Aabb solid in solids) {
      if (!_penetrates(afterY, solid)) continue;
      if (totalY < 0) {
        py = solid.top + halfHeight + _epsilon;
        onGround = true;
      } else if (totalY > 0) {
        py = solid.bottom - halfHeight - _epsilon;
        hitCeiling = true;
      } else {
        continue;
      }
      vy = 0;
    }
  }

  // Standing still on a floor produces no vertical motion at all, so the loop
  // above never resolves anything and `onGround` would be false — the
  // character would be reported as falling while visibly standing. A separate
  // probe one epsilon below the feet is the answer, and it is why gravity is
  // applied before this rather than after: a resting body still has a downward
  // velocity when it arrives here, so the loop usually does find the floor.
  if (!onGround) {
    final Aabb feet = Aabb(
      left: px - halfWidth + _groundProbeInset,
      bottom: py - halfHeight - _groundProbeDepth,
      right: px + halfWidth - _groundProbeInset,
      top: py - halfHeight,
    );
    for (final Aabb solid in solids) {
      if (feet.overlaps(solid)) {
        onGround = true;
        break;
      }
    }
  }

  return SweepResult(
    x: px,
    y: py,
    velocityX: vx,
    velocityY: vy,
    onGround: onGround,
    hitCeiling: hitCeiling,
    hitWall: hitWall,
  );
}

/// How far below the feet the ground probe reaches.
///
/// Larger than [_epsilon] by a wide margin, because the probe has to survive a
/// body that was pushed one epsilon clear of the floor *and* a floor whose top
/// is not exactly representable. Small enough that it never finds a floor the
/// body is genuinely falling away from at any speed the game produces.
const double _groundProbeDepth = 0.02;

/// How far in from the body's sides the ground probe is taken.
///
/// Without it, a body standing beside a wall finds the wall with its ground
/// probe and reports standing on it, which is how a character gets a free jump
/// out of every corner.
const double _groundProbeInset = 0.02;

/// Whether [body] is inside [solid] by more than the floating-point margin.
bool _penetrates(Aabb body, Aabb solid) =>
    body.left < solid.right - _epsilon &&
    body.right > solid.left + _epsilon &&
    body.bottom < solid.top - _epsilon &&
    body.top > solid.bottom + _epsilon;
