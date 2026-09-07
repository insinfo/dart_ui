/// The arithmetic under the game: collision, the fixed step, the camera and
/// the animation state machine.
///
/// Everything here states a situation in numbers and asserts a number back.
/// None of it opens a window, and that is the point — each of these bugs is
/// *invisible* in a running game. A character that catches on a floor seam for
/// two frames, a camera that creeps by a hundredth of a unit per frame, a jump
/// that is one frame shorter at 144 Hz than at 60: a person watching the game
/// sees "it feels slightly wrong" and cannot say which of the four is
/// responsible. A test that says "the body was overlapping this box by 0.3 and
/// ended up here" can.
///
/// The route from a key to the camera is a different test with a different
/// shape; see `game_shell_test.dart`.
library;

import 'package:test/test.dart';

import '../../../examples/side_scroller_game/game/autopilot.dart';
import '../../../examples/side_scroller_game/game/collision.dart';
import '../../../examples/side_scroller_game/game/follow_camera.dart';
import '../../../examples/side_scroller_game/game/level.dart';
import '../../../examples/side_scroller_game/game/motion_state.dart';
import '../../../examples/side_scroller_game/game/world.dart';

/// A floor from x = -50 to x = 50 whose surface is y = 0.
Aabb _floor() => const Aabb(left: -50, bottom: -4, right: 50, top: 0);

void main() {
  group('moveAndCollide', () {
    test('lands on a floor instead of passing through it', () {
      // The failure this is written against: at 26 units a second and a 10 ms
      // step, a body moves 0.26 in a step — a fifth of its own height. Faster
      // still and an end-of-step overlap test finds nothing at all, because
      // the body was above the floor before the step and below it after.
      final SweepResult result = moveAndCollide(
        x: 0,
        y: 3,
        halfWidth: 0.45,
        halfHeight: 0.85,
        velocityX: 0,
        velocityY: -260,
        dt: 0.1,
        solids: <Aabb>[_floor()],
      );

      expect(result.onGround, isTrue);
      expect(result.y, closeTo(0.85, 1e-3));
      expect(result.velocityY, 0);
    });

    test('walks across the seam between two boxes without catching', () {
      // Two floors that touch exactly. A body resting on top overlaps the
      // second by zero vertically, and an overlap test written with `>=` calls
      // that a collision, resolves it horizontally, and stops the character
      // dead in the middle of flat ground.
      final List<Aabb> floors = <Aabb>[
        const Aabb(left: -10, bottom: -4, right: 0, top: 0),
        const Aabb(left: 0, bottom: -4, right: 10, top: 0),
      ];
      var x = -1.0;
      for (var step = 0; step < 40; step++) {
        final SweepResult result = moveAndCollide(
          x: x,
          y: 0.85,
          halfWidth: 0.45,
          halfHeight: 0.85,
          velocityX: 8.2,
          velocityY: -0.4,
          dt: 0.01,
          solids: floors,
        );
        expect(result.hitWall, isFalse, reason: 'caught on the seam at x=$x');
        expect(result.velocityX, 8.2);
        x = result.x;
      }
      expect(x, greaterThan(2.0));
    });

    test('sliding down a wall keeps falling', () {
      // Resolving both axes from one overlap has to choose one, and the usual
      // choice — the smaller penetration — picks the *vertical* axis when a
      // body slides along a wall while falling. The fall stops and the body
      // hangs there.
      // Started close enough that the step actually reaches the wall: at 6
      // units a second and a 50 ms step the body travels 0.30, so a body
      // starting at the origin stops short of a wall at x = 1 and the test
      // would pass for saying nothing.
      final SweepResult result = moveAndCollide(
        x: 0.4,
        y: 5,
        halfWidth: 0.45,
        halfHeight: 0.85,
        velocityX: 6,
        velocityY: -12,
        dt: 0.05,
        solids: <Aabb>[const Aabb(left: 1, bottom: -20, right: 4, top: 20)],
      );

      expect(result.hitWall, isTrue);
      expect(result.x, closeTo(1 - 0.45, 1e-3));
      expect(result.velocityX, 0);
      expect(result.velocityY, -12, reason: 'the fall must survive the wall');
      expect(result.onGround, isFalse);
      expect(result.y, lessThan(5));
    });

    test('standing still on a floor still reports onGround', () {
      // No vertical motion means the substep loop resolves nothing, so
      // `onGround` would be false while the character visibly stands. The
      // separate probe below the feet is the answer, and this is its test.
      final SweepResult result = moveAndCollide(
        x: 0,
        y: 0.85,
        halfWidth: 0.45,
        halfHeight: 0.85,
        velocityX: 0,
        velocityY: 0,
        dt: 0.01,
        solids: <Aabb>[_floor()],
      );
      expect(result.onGround, isTrue);
    });

    test('standing beside a wall does not report standing on it', () {
      // Without the inset on the ground probe, a body against a wall finds the
      // wall with its own feet and gets a free jump out of every corner.
      final SweepResult result = moveAndCollide(
        x: 0,
        y: 5,
        halfWidth: 0.45,
        halfHeight: 0.85,
        velocityX: 4,
        velocityY: 0,
        dt: 0.05,
        solids: <Aabb>[const Aabb(left: 0.5, bottom: -20, right: 4, top: 20)],
      );
      expect(result.hitWall, isTrue);
      expect(result.onGround, isFalse);
    });

    test('a ceiling stops a rise and leaves the run alone', () {
      final SweepResult result = moveAndCollide(
        x: 0,
        y: 0.5,
        halfWidth: 0.45,
        halfHeight: 0.85,
        velocityX: 8,
        velocityY: 17.5,
        dt: 0.05,
        solids: <Aabb>[const Aabb(left: -20, bottom: 2, right: 20, top: 6)],
      );
      expect(result.hitCeiling, isTrue);
      expect(result.velocityY, 0);
      expect(result.velocityX, 8, reason: 'a bumped head is not a stop');
      expect(result.y, closeTo(2 - 0.85, 1e-3));
    });
  });

  group('the fixed step', () {
    test('a late frame runs the steps it bought and no more', () {
      final GameWorld world = GameWorld(level: buildDemoLevel());

      // 55 ms at a 10 ms step buys five whole steps and leaves 5 ms pending.
      expect(
          world.advance(const Duration(milliseconds: 55), GameInput.none), 5);
      expect(world.accumulator.pending, const Duration(milliseconds: 5));
      expect(world.alpha, closeTo(0.5, 1e-9));
      expect(world.accumulator.dropped, Duration.zero);
    });

    test('a very late frame is clamped and says so', () {
      // The spiral of death: a frame that took a second would owe a hundred
      // steps, running them would take longer than a second, and the next frame
      // would owe more. The accumulator clamps — and *reports* the time it
      // abandoned, because "the simulation could not keep up" is a fact the
      // game has to be able to act on rather than a mystery.
      final GameWorld world = GameWorld(level: buildDemoLevel());
      final int steps =
          world.advance(const Duration(milliseconds: 1000), GameInput.none);

      expect(steps, 6, reason: 'maxStepsPerFrame');
      expect(world.accumulator.dropped.inMilliseconds, 940);
      expect(world.accumulator.pending.inMilliseconds, lessThan(10));
    });

    test('the same simulated time gives the same world at any frame rate', () {
      // This is the whole reason the step is fixed. One world is advanced in
      // 60 Hz frames and the other in 144 Hz frames, over the same two seconds
      // of simulated time and the same held input.
      GameWorld run(Duration frame, int frames) {
        final GameWorld world = GameWorld(level: buildDemoLevel());
        for (var i = 0; i < frames; i++) {
          world.advance(frame, const GameInput(right: true));
        }
        return world;
      }

      // 200 frames of 10 ms against 400 of 5 ms: two seconds either way, and
      // both are inside the six-step-per-frame clamp.
      final GameWorld slow = run(const Duration(milliseconds: 10), 200);
      final GameWorld fast = run(const Duration(milliseconds: 5), 400);

      expect(slow.accumulator.stepsTaken, 200);
      expect(fast.accumulator.stepsTaken, 200);
      expect(fast.player.x, closeTo(slow.player.x, 1e-9));
      expect(fast.player.y, closeTo(slow.player.y, 1e-9));
      expect(fast.ringsCollected, slow.ringsCollected);
    });
  });

  group('FollowCamera', () {
    test('does not move at all while the target is inside the dead zone', () {
      // Exactly, and not "almost". A camera smoothed toward its target creeps:
      // an exponential approach never arrives, so the whole picture drifts
      // under a character that is standing still. That is why the position
      // follows the dead zone and only the *lead* is damped.
      final FollowCamera camera = FollowCamera(
        horizontalDeadZone: 2,
        verticalDeadZone: 3,
      )..snapTo(0, 0);

      for (var i = 0; i < 50; i++) {
        camera.follow(targetX: 1.9, targetY: 2.9, facing: 0, dt: 1 / 60);
      }
      expect(camera.x, 0);
      expect(camera.y, 0);
    });

    test('follows exactly as far as the target left the zone', () {
      final FollowCamera camera = FollowCamera(
        horizontalDeadZone: 2,
        verticalDeadZone: 3,
      )..snapTo(0, 0);

      camera.follow(targetX: 5, targetY: 0, facing: 0, dt: 1 / 60);
      expect(camera.x, closeTo(3, 1e-9));

      camera.follow(targetX: -5, targetY: 0, facing: 0, dt: 1 / 60);
      expect(camera.x, closeTo(-3, 1e-9));
    });

    test('the lead eases rather than snapping when the character turns', () {
      final FollowCamera camera = FollowCamera(
        horizontalDeadZone: 2,
        verticalDeadZone: 3,
        lead: 4,
        leadResponse: 3,
      )..snapTo(0, 0);
      expect(camera.appliedLead, 4);

      // Turning round flips the wanted lead from +4 to -4. Undamped, the aim
      // point would move eight units in one frame and the whole view would
      // snap across.
      camera.follow(targetX: 0, targetY: 0, facing: -1, dt: 1 / 60);
      expect(camera.appliedLead, lessThan(4));
      expect(camera.appliedLead, greaterThan(3.5));

      for (var i = 0; i < 600; i++) {
        camera.follow(targetX: 0, targetY: 0, facing: -1, dt: 1 / 60);
      }
      expect(camera.appliedLead, closeTo(-4, 1e-6));
    });

    test('a jump does not move the camera, a fall does', () {
      // The single biggest difference between a camera that feels right and one
      // that makes people ill.
      final FollowCamera camera = FollowCamera(
        horizontalDeadZone: 2,
        verticalDeadZone: 1,
      )..snapTo(0, 0);

      camera.follow(
          targetX: 0, targetY: 6, facing: 0, dt: 1 / 60, onGround: false);
      expect(camera.y, 0, reason: 'rising while airborne must not pull it');

      camera.follow(
          targetX: 0, targetY: -6, facing: 0, dt: 1 / 60, onGround: false);
      expect(camera.y, closeTo(-5, 1e-9),
          reason: 'a fall always pulls, or the character leaves the screen');

      camera.snapTo(0, 0);
      camera.follow(targetX: 0, targetY: 6, facing: 0, dt: 1 / 60);
      expect(camera.y, closeTo(5, 1e-9),
          reason: 'landing somewhere higher does move the camera');
    });

    test('the clamp keeps the void beyond the level off screen', () {
      final FollowCamera camera = FollowCamera(
        horizontalDeadZone: 1,
        verticalDeadZone: 1,
      )..snapTo(500, -500);
      camera.clampTo(minX: 0, maxX: 100, minY: 2);
      expect(camera.x, 100);
      expect(camera.y, 2);
    });
  });

  group('MotionStateMachine', () {
    test('a single airborne frame does not become a fall', () {
      // Walking off the lip of one box onto the next reports onGround == false
      // for one step. Switching to `fall` and back produces a one-frame pose
      // change every time the character crosses a seam, which reads as the
      // character stumbling.
      final MotionStateMachine machine = MotionStateMachine();
      machine.update(dt: 0.01, onGround: true, velocityX: 8, velocityY: 0);
      expect(machine.state, MotionState.run);

      machine.update(dt: 0.01, onGround: false, velocityX: 8, velocityY: -0.4);
      expect(machine.state, MotionState.run, reason: 'inside the grace window');

      machine.update(dt: 0.01, onGround: true, velocityX: 8, velocityY: 0);
      expect(machine.state, MotionState.run);
    });

    test('past the grace window, rising is jump and falling is fall', () {
      final MotionStateMachine machine = MotionStateMachine();
      for (var i = 0; i < 20; i++) {
        machine.update(dt: 0.01, onGround: false, velocityX: 8, velocityY: 12);
      }
      expect(machine.state, MotionState.jump);

      machine.update(dt: 0.01, onGround: false, velocityX: 8, velocityY: -1);
      expect(machine.state, MotionState.fall);
    });

    test('a residual speed below the threshold is idle, not run', () {
      // A character stopped by a wall keeps whatever speed the input asked for
      // until the collision zeroes it, and a stomp bounce leaves a tiny
      // residual for several frames. Compared against zero, both put the
      // character in `run` with its feet sliding on the spot.
      final MotionStateMachine machine = MotionStateMachine();
      machine.update(dt: 0.01, onGround: true, velocityX: 0.2, velocityY: 0);
      expect(machine.state, MotionState.idle);

      machine.update(dt: 0.01, onGround: true, velocityX: 0.4, velocityY: 0);
      expect(machine.state, MotionState.run);
    });

    test('hurt is an edge and the machine owns the recovery', () {
      final MotionStateMachine machine = MotionStateMachine(hurtDuration: 0.5);
      machine.update(
          dt: 0.01, onGround: true, velocityX: 8, velocityY: 0, hurt: true);
      expect(machine.state, MotionState.hurt);

      // Passing hurt exactly once, as an edge. The machine holds the state
      // itself; sharing the duration with the caller is how the animation and
      // the invulnerability end up disagreeing.
      for (var i = 0; i < 40; i++) {
        machine.update(dt: 0.01, onGround: true, velocityX: 8, velocityY: 0);
      }
      expect(machine.state, MotionState.hurt);

      for (var i = 0; i < 20; i++) {
        machine.update(dt: 0.01, onGround: true, velocityX: 8, velocityY: 0);
      }
      expect(machine.state, MotionState.run,
          reason: 'it recovers into what the body is actually doing');
    });

    test('a character hurt in mid-air recovers into fall, not idle', () {
      final MotionStateMachine machine = MotionStateMachine(hurtDuration: 0.1);
      machine.update(
          dt: 0.01, onGround: false, velocityX: 0, velocityY: -8, hurt: true);
      expect(machine.state, MotionState.hurt);
      for (var i = 0; i < 20; i++) {
        machine.update(dt: 0.01, onGround: false, velocityX: 0, velocityY: -8);
      }
      expect(machine.state, MotionState.fall);
    });

    test('dead is terminal', () {
      final MotionStateMachine machine = MotionStateMachine();
      machine.update(
          dt: 0.01, onGround: true, velocityX: 0, velocityY: 0, alive: false);
      expect(machine.state, MotionState.dead);
      machine.update(dt: 0.01, onGround: true, velocityX: 9, velocityY: 0);
      expect(machine.state, MotionState.dead);

      // Only a respawn gets out of it, and it resets the clip with it.
      machine.reset();
      expect(machine.state, MotionState.idle);
      expect(machine.timeInState, 0);
    });
  });

  group('the world', () {
    test('a jump held goes higher than a jump tapped', () {
      // Variable jump height is the difference between a platformer you can
      // place yourself in and one you aim at the start of every arc.
      double apex({required int holdSteps}) {
        final GameWorld world = GameWorld(level: buildDemoLevel());
        // The level spawns the character a little above the floor so it drops
        // in. Jumping on step zero therefore jumps *nothing*: it is airborne,
        // the coyote window has already expired, and both arcs come out
        // identical — which is how this test first passed for the wrong
        // reason and then failed for the right one.
        while (!world.player.onGround) {
          world.step(GameInput.none);
        }
        final double floor = world.player.y;
        var highest = floor;
        for (var step = 0; step < 140; step++) {
          world.step(GameInput(jump: step < holdSteps));
          if (world.player.y > highest) highest = world.player.y;
        }
        return highest - floor;
      }

      final double tapped = apex(holdSteps: 2);
      final double held = apex(holdSteps: 40);
      expect(held - tapped, greaterThan(1.5));
      // And holding past the cut point buys nothing more.
      expect(apex(holdSteps: 60), closeTo(held, 1e-9));
    });

    test('a stomp kills the enemy and bounces the player', () {
      final Level level = buildDemoLevel();
      final GameWorld world = GameWorld(level: level);
      final Enemy target = world.enemies.first;

      // Dropped straight onto it from above, which is the case the world tells
      // apart from a run into its side by where the player *was* rather than by
      // which overlap is deepest. Placed so that the boxes still overlap after
      // the step moves the player: one step at -6 units a second is 0.06, and
      // the boxes stop overlapping at 1.45 apart.
      world.player
        ..x = target.x
        ..previousX = target.x
        ..y = target.y + 1.40
        ..previousY = target.y + 1.40
        ..velocityX = 0
        ..velocityY = -6;
      world.step(GameInput.none);

      expect(target.alive, isFalse);
      expect(world.enemiesDefeated, 1);
      expect(world.score, 200);
      expect(world.player.velocityY, greaterThan(0), reason: 'the bounce');
      expect(world.lives, 3);
    });

    test('running into an enemy costs a life and grants invulnerability', () {
      final GameWorld world = GameWorld(level: buildDemoLevel());
      final Enemy target = world.enemies.first;
      // Standing on the floor beside it and running in. The player's feet must
      // be *on* the ground and not below it: a body that starts embedded in a
      // floor is pushed out along its direction of travel, which teleported an
      // earlier version of this test four units backwards and out of contact.
      world.player
        ..x = target.x - 0.5
        ..previousX = target.x - 0.5
        ..y = Player.halfHeight
        ..previousY = Player.halfHeight
        ..onGround = true
        ..velocityX = 8.2
        ..velocityY = 0;
      world.step(GameInput.none);

      expect(target.alive, isTrue, reason: 'a side hit is not a stomp');
      expect(world.lives, 2);
      expect(world.player.invulnerable, greaterThan(0));
      expect(world.player.motion.state, MotionState.hurt);

      // And a second contact on the next step is free.
      world.step(GameInput.none);
      expect(world.lives, 2);
    });

    test('falling out of the world respawns at the last checkpoint', () {
      final Level level = buildDemoLevel();
      final GameWorld world = GameWorld(level: level);
      world.player
        ..x = level.checkpoints[1] + 5
        ..y = 1.0;
      world.step(GameInput.none);
      expect(world.respawnX, level.checkpoints[1]);

      world.player.y = level.killY - 1;
      world.step(GameInput.none);
      expect(world.lives, 2);
      expect(world.player.x, level.checkpoints[1]);
    });

    test('the last life ends the run', () {
      final GameWorld world = GameWorld(level: buildDemoLevel());
      for (var i = 0; i < 3; i++) {
        world.player.y = world.level.killY - 1;
        world.step(GameInput.none);
      }
      expect(world.outcome, GameOutcome.gameOver);
      expect(world.lives, 0);
      expect(world.player.motion.state, MotionState.dead);
    });

    test('two levels in one process do not share a floor', () {
      // `Level.boxes` is memoised. As a static it would hand the second level
      // the first one's floors, and the second level's player would fall
      // through everything while standing on geometry it cannot see.
      final Level first = buildDemoLevel();
      final Level second = Level(
        name: 'test',
        solids: <Solid>[Solid(_floor(), SolidKind.ground)],
        rings: const <RingSpawn>[],
        enemies: const <EnemySpawn>[],
        spawnX: 0,
        spawnY: 1,
        checkpoints: const <double>[],
        finishX: 10,
        killY: -20,
        minX: -50,
        maxX: 50,
      );
      expect(first.boxes.length, first.solids.length);
      expect(second.boxes.length, 1);
      expect(second.boxes.first.right, 50);
    });
  });

  group('the autopilot', () {
    test('finishes the level, which is what makes it a regression test', () {
      // The assertion that catches a change to gravity, to the jump cut, to
      // the collision epsilon or to the width of one gap. Any of those can
      // leave a game that runs perfectly and cannot be completed, and none of
      // them is visible in a screenshot.
      final GameWorld world = GameWorld(level: buildDemoLevel());
      final int steps = runAutopilot(world);

      expect(world.outcome, GameOutcome.finished,
          reason: 'the level must stay completable: ${world.describe()}');
      expect(steps, lessThan(3000), reason: 'and completable at speed');
      expect(world.lives, 3, reason: 'without needing a single retry');
      expect(world.enemiesDefeated, world.enemies.length,
          reason: 'every enemy is stompable from a planned jump');
      expect(world.ringsCollected, greaterThan(10));
    });

    test('two runs of the same level agree exactly', () {
      // Determinism, which is what lets the assertions above be equalities
      // rather than ranges. Nothing in the autopilot or the world reads a
      // clock or a random number.
      String run() {
        final GameWorld world = GameWorld(level: buildDemoLevel());
        runAutopilot(world);
        return world.describe();
      }

      expect(run(), run());
    });
  });
}
