/// A player that is not a person: the scripted input `--script` runs and the
/// tests assert against.
///
/// ## Why this and not a tape of button presses
///
/// The obvious way to script a run is to record which buttons are held at which
/// times and play it back. It is also useless as a regression test, because it
/// is a test of the *tape*: move one platform and the tape walks into a wall,
/// and the failure says nothing about whether the game still works. Worse, a
/// tape passes for the wrong reason all the time — a jump timed to the frame
/// clears a gap that a slightly slower character would fall into, and the test
/// goes green on a change that broke the run for a human.
///
/// This reads the world and decides instead. It is still perfectly
/// deterministic — the same world produces the same input every time, with no
/// clock and no randomness in it — so a test can assert an exact final state.
/// But what it asserts is that *the level is completable*: that the gaps are
/// jumpable at the speed the tuning produces, that the staircase's steps are
/// within one jump of each other, and that the collision does not catch the
/// character on a seam. Those are the things that actually break.
///
/// ## It plans the jump rather than guessing it
///
/// The first version held every jump for the same length and died in the first
/// gap: a full-height jump from the lip travels 6.8 units, which clears the
/// 3.2-unit gap and then *overshoots the whole staircase*, landing in the
/// 1.8-unit slot between two of its steps. A platformer's jump is variable for
/// exactly this reason, and an autopilot that does not use the variation cannot
/// play the level a human can.
///
/// So [_planJump] projects the arc for each candidate hold length — the same
/// arithmetic the world's own step uses, with the collision reduced to "which
/// floor does this cross on the way down" — and takes the shortest jump that
/// lands somewhere solid past the gap. That is a dozen microseconds a few dozen
/// times per run, and it removes every hand-tuned distance from this file.
///
/// It is also the attract mode: `--frames=N --demo` shows the game playing
/// itself, which is how a change is looked at without a hand on the keyboard.
///
/// ## What it cannot do
///
/// It is not good at the game. It runs right, it plans its jumps, and it takes
/// hits it could have avoided. A human playing well finishes with more rings
/// and fewer deaths, and that gap is the point: the autopilot proves the level
/// is *possible*, not that it is fun.
library;

import 'dart:math' as math;

import 'collision.dart';
import 'level.dart';
import 'world.dart';

/// Decides a [GameInput] from a [GameWorld], once per fixed step.
final class Autopilot {
  Autopilot(this.level, {this.tuning = const GameTuning()});

  final Level level;
  final GameTuning tuning;

  /// Steps of jump still to be held.
  ///
  /// A jump is a hold and not a press, because the world cuts a rising jump the
  /// moment the button is released ([GameTuning.jumpCutSpeed]). A one-step
  /// press therefore produces the *smallest* jump the game can make, which
  /// clears none of this level's gaps — and the failure looks exactly like
  /// gravity being too strong.
  int _hold = 0;

  /// Steps before another jump may be started.
  ///
  /// Without it the autopilot re-decides the same jump on the step it lands,
  /// and bounces on the spot in front of a gap forever: the reason to jump is
  /// still true and it is once again on the ground.
  int _cooldown = 0;

  /// The longest hold worth trying, in steps of the world's 10 ms tick.
  ///
  /// 32 steps is 0.32 s, just past the point where gravity has brought a
  /// 17.5-unit jump below the 5.0-unit cut speed. Holding longer buys nothing
  /// at all, which is why the search stops here rather than at some round
  /// number.
  static const int maxHoldSteps = 32;

  /// The shortest hold worth trying. Below this the jump is a hop that clears
  /// nothing, and offering it to the search only wastes projections.
  static const int minHoldSteps = 8;

  static const int jumpCooldownSteps = 12;

  /// The input for this step.
  GameInput decide(GameWorld world) {
    if (world.outcome != GameOutcome.playing) return GameInput.none;

    if (_cooldown > 0) _cooldown--;
    if (_hold > 0) {
      _hold--;
      return const GameInput(right: true, jump: true);
    }

    if (world.player.onGround && _cooldown == 0) {
      final int steps = _jumpFor(world);
      if (steps > 0) {
        _hold = steps - 1;
        _cooldown = jumpCooldownSteps + steps;
        return const GameInput(right: true, jump: true);
      }
    }
    return const GameInput(right: true);
  }

  /// How long to hold a jump started now, or zero for no jump.
  int _jumpFor(GameWorld world) {
    final Player player = world.player;
    final double feet = player.y - Player.halfHeight;

    // An enemy first. It is the only reason to jump that wants a *shorter*
    // hop, and deciding it after the gap check would send a full jump straight
    // over the enemy's head — which is legal, and which never stomps anything.
    for (final Enemy enemy in world.enemies) {
      if (!enemy.alive) continue;
      final double ahead = enemy.x - player.x;
      if (ahead < 0.8 || ahead > 5.0) continue;
      if ((enemy.y - player.y).abs() > 2.2) continue;
      final int hop = _planStomp(world, enemy);
      if (hop > 0) return hop;
    }

    // A gap, which here means "no floor at or just below the feet". A step up
    // is the same question with the answer on the other side: the floor ahead
    // is above the feet, so it is not found, so a jump is planned — and the
    // planner works out how long to hold to reach it.
    final double lip = player.x + Player.halfWidth + 0.22;
    if (!_standableAt(lip, feet) || !_standableAt(lip + 0.5, feet)) {
      final int planned = _planJump(world, from: lip);
      if (planned > 0) return planned;
      // Nothing lands. Jumping anyway is still better than walking off the
      // edge: it is the difference between reaching the checkpoint and not.
      return maxHoldSteps;
    }

    // Pressing right and going nowhere. The recovery that stops one tuning
    // change turning the whole run into a character grinding into a step it can
    // no longer make, with the test reporting only that it timed out.
    if (player.velocityX.abs() < 0.4 && world.elapsed > 0.6) {
      return maxHoldSteps;
    }

    return 0;
  }

  /// The shortest hold whose arc lands on solid ground past [from].
  int _planJump(GameWorld world, {required double from}) {
    for (var hold = minHoldSteps; hold <= maxHoldSteps; hold += 2) {
      final _Landing? landing = _project(world, hold);
      if (landing == null) continue;
      // Past the lip by more than the body's own width, so a landing on the
      // sliver of floor the character is already standing on does not count as
      // having crossed anything.
      if (landing.x < from + Player.halfWidth) continue;
      // And with room to stand once it gets there. Without this the search
      // takes the shortest jump that reaches the far lip *by six centimetres*,
      // which is a landing the character survives only if nothing at all
      // differs between the projection and the run.
      if (!_standableAt(landing.x + 0.7, landing.y + 0.1)) continue;
      return hold;
    }
    return 0;
  }

  /// The shortest hold that comes down on top of [enemy], or zero.
  ///
  /// The enemy is projected forward along its own patrol at the same time, so
  /// this is a real interception rather than an aim at where it used to be. A
  /// badnik walking toward the player at 2.3 units a second covers most of its
  /// own width during the fall.
  int _planStomp(GameWorld world, Enemy enemy) {
    for (var hold = minHoldSteps; hold <= 24; hold += 2) {
      final _Landing? landing = _project(world, hold, chasing: enemy);
      if (landing != null && landing.stomped) return hold;
    }
    return 0;
  }

  /// Where a jump held for [holdSteps] first meets a floor, or null.
  ///
  /// The same integration the world's own step runs, minus everything that
  /// cannot change the answer: no ring pickup, no wall resolution, and the
  /// floor test reduced to "did the feet cross a surface on the way down". A
  /// planner that duplicated the full step would be a second copy of the
  /// physics to keep in sync, and a planner that used a closed-form parabola
  /// would silently disagree with it the first time the tuning changed.
  _Landing? _project(GameWorld world, int holdSteps, {Enemy? chasing}) {
    final double dt = world.stepSeconds;
    double x = world.player.x;
    double y = world.player.y;
    double vx = world.player.velocityX;
    double vy = tuning.jumpSpeed;
    double enemyX = chasing?.x ?? 0;
    double enemyDirection = chasing?.direction ?? 0;
    var stomped = false;

    for (var i = 0; i < 260; i++) {
      final double previousFeet = y - Player.halfHeight;

      final double wanted = tuning.runSpeed;
      final double change = tuning.airAcceleration * dt;
      final double delta = wanted - vx;
      vx += delta.abs() <= change ? delta : change * delta.sign;

      if (i >= holdSteps && vy > tuning.jumpCutSpeed) vy = tuning.jumpCutSpeed;
      vy = math.max(vy - tuning.gravity * dt, -tuning.terminalVelocity);
      x += vx * dt;
      y += vy * dt;

      if (chasing != null) {
        enemyX += enemyDirection * chasing.spawn.speed * dt;
        if (enemyX <= chasing.spawn.patrolMin) {
          enemyX = chasing.spawn.patrolMin;
          enemyDirection = 1;
        } else if (enemyX >= chasing.spawn.patrolMax) {
          enemyX = chasing.spawn.patrolMax;
          enemyDirection = -1;
        }
        // The world's own stomp test: falling, and the feet were above the
        // enemy's roof at the start of the step.
        if (!stomped &&
            vy < 0 &&
            (x - enemyX).abs() < Player.halfWidth + Enemy.halfWidth &&
            (y - chasing.y).abs() < Player.halfHeight + Enemy.halfHeight &&
            previousFeet >= chasing.y + Enemy.halfHeight - 0.22) {
          stomped = true;
          return _Landing(x, y, stomped: true);
        }
      }

      if (vy >= 0) continue;
      final double feet = y - Player.halfHeight;
      for (final Aabb box in level.boxes) {
        if (x < box.left - Player.halfWidth) continue;
        if (x > box.right + Player.halfWidth) continue;
        if (previousFeet < box.top - 1e-6 || feet > box.top) continue;
        return _Landing(x, box.top, stomped: stomped);
      }
      if (y < level.killY) return null;
    }
    return null;
  }

  /// Whether a body whose feet are at [feet] could stand at [x] without
  /// falling — that is, whether there is a surface at or just below the feet.
  ///
  /// "Just below" and not "exactly at": walking down a shallow step the floor
  /// ahead is a little lower, and a test for exactly level calls every descent
  /// a pit. A surface *above* the feet is not standable, which is what makes a
  /// step up ask the planner the same question a gap does.
  bool _standableAt(double x, double feet) {
    for (final Aabb box in level.boxes) {
      if (x < box.left || x > box.right) continue;
      final double drop = feet - box.top;
      if (drop >= -0.05 && drop <= 1.2) return true;
    }
    return false;
  }
}

final class _Landing {
  const _Landing(this.x, this.y, {this.stomped = false});

  final double x;
  final double y;

  /// Whether the arc met an enemy's roof before it met a floor.
  final bool stomped;
}

/// Runs [world] under an [Autopilot] until it ends or [maxSteps] is reached.
///
/// Steps the world directly rather than through its accumulator, because a
/// scripted run has no clock: feeding it wall-clock deltas would make the
/// result depend on how fast the machine running the test is, which is the one
/// property this whole arrangement exists to remove.
///
/// Returns the number of steps run.
int runAutopilot(GameWorld world, {int maxSteps = 6000}) {
  final Autopilot pilot = Autopilot(world.level, tuning: world.tuning);
  for (var step = 0; step < maxSteps; step++) {
    if (world.outcome != GameOutcome.playing) return step;
    world.step(pilot.decide(world));
  }
  return maxSteps;
}
