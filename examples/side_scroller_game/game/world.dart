/// The simulation: one fixed step, over and over, and nothing else.
///
/// No mesh, no widget, no clock. It is fed a [GameInput] and a [Duration] and
/// it produces positions. That is what lets `--script` run the whole game with
/// no window at all and print the result, and what lets a test assert that the
/// player who jumps at step 40 clears the gap.
///
/// ## Why the step is fixed and why the accumulator is the framework's
///
/// A game that integrates against the frame delta produces a different world
/// on a 60 Hz laptop and a 144 Hz desktop, and a different one again after any
/// stall — the classic bug this framework already ships the remedy for.
/// [FixedStepAccumulator] in `lib/src/app/frame_loop.dart` is that remedy and
/// it is used here directly rather than reimplemented, including its
/// [FixedStepAccumulator.alpha], which the renderer interpolates by so that a
/// 100 Hz simulation drawn at 60 Hz does not judder.
///
/// **A note on the seam.** `FrameLoopController` builds one of these itself
/// when [FrameLoopOptions.fixedTimeStep] is set, but it calls `advance` and
/// throws away the step count, publishing only `alpha`. An application cannot
/// therefore learn from the framework's own loop *how many* steps to run, so
/// this owns its accumulator and drives it from the animation clock's
/// timestamps. See the report.
library;

import 'package:dart_ui/src/app/frame_loop.dart';
import 'collision.dart';
import 'level.dart';
import 'motion_state.dart';

/// What the player is asking for this step. Three booleans, and deliberately
/// not a key code: `--script` produces these from a tape and the widget
/// produces them from the keyboard, and neither knows about the other.
final class GameInput {
  const GameInput({this.left = false, this.right = false, this.jump = false});

  static const GameInput none = GameInput();

  final bool left;
  final bool right;

  /// Held, not pressed. The edge is derived inside [GameWorld], because
  /// "pressed" is a fact about two consecutive *steps* and the caller does not
  /// know where the step boundaries are.
  final bool jump;

  double get axis => (right ? 1.0 : 0.0) - (left ? 1.0 : 0.0);
}

/// Everything about the player that the renderer and the HUD read.
final class Player {
  Player({required this.x, required this.y})
      : previousX = x,
        previousY = y;

  double x;
  double y;
  double previousX;
  double previousY;
  double velocityX = 0;
  double velocityY = 0;

  /// -1 or +1. Never 0: the character has to be facing *somewhere* to be
  /// drawn, and a facing of zero would collapse the model's rotation matrix.
  double facing = 1;

  bool onGround = false;

  /// Seconds of invulnerability left after a hit. Also what makes the model
  /// blink, which is the only feedback the player gets that the hit landed.
  double invulnerable = 0;

  final MotionStateMachine motion = MotionStateMachine();

  static const double halfWidth = 0.45;
  static const double halfHeight = 0.85;

  Aabb get box => Aabb.centred(
        x: x,
        y: y,
        halfWidth: halfWidth,
        halfHeight: halfHeight,
      );

  /// The drawn position, [alpha] of the way from the previous step to this one.
  double renderX(double alpha) => previousX + (x - previousX) * alpha;

  double renderY(double alpha) => previousY + (y - previousY) * alpha;
}

final class Enemy {
  Enemy(this.spawn)
      : x = spawn.x,
        y = spawn.y,
        previousX = spawn.x,
        previousY = spawn.y,
        direction = 1;

  final EnemySpawn spawn;

  double x;
  double y;
  double previousX;
  double previousY;
  double direction;
  bool alive = true;

  /// Seconds since it was stomped, so the renderer can flatten it on its way
  /// out instead of having it vanish mid-screen.
  double dyingFor = 0;

  static const double halfWidth = 0.85;
  static const double halfHeight = 0.6;

  Aabb get box => Aabb.centred(
        x: x,
        y: y,
        halfWidth: halfWidth,
        halfHeight: halfHeight,
      );

  double renderX(double alpha) => previousX + (x - previousX) * alpha;

  double renderY(double alpha) => previousY + (y - previousY) * alpha;
}

final class Ring {
  Ring(this.spawn);

  final RingSpawn spawn;
  bool taken = false;

  /// Its own spin phase, in seconds, so that a row of rings is not one solid
  /// object turning in lockstep.
  double phase = 0;
}

/// How the run ended, or that it has not.
enum GameOutcome { playing, finished, gameOver }

/// The tuning. All of it in one place and named, because these eleven numbers
/// *are* the feel of the game and hunting them through the step function is
/// how a platformer ends up with two different gravities.
final class GameTuning {
  const GameTuning();

  /// Units per second per second, downward.
  double get gravity => 42.0;

  /// The fastest fall. Without a terminal velocity a long drop reaches a speed
  /// where the collision substepping is the only thing between the player and
  /// the floor, and 64 substeps is the cap.
  double get terminalVelocity => 26.0;

  double get runSpeed => 8.2;
  double get groundAcceleration => 62.0;
  double get airAcceleration => 26.0;
  double get groundFriction => 52.0;
  double get airFriction => 6.0;

  /// Straight up out of a standstill. `sqrt(2 * gravity * height)`: 17.5
  /// against a gravity of 42 clears 3.6 units, which is two of the player's
  /// heights and one and a bit of the staircase's steps.
  double get jumpSpeed => 17.5;

  /// What a rising jump is cut to when the button is released. A variable
  /// jump height is the difference between a platformer you can place yourself
  /// in and one you aim at the start of every arc.
  double get jumpCutSpeed => 5.0;

  /// How long after leaving a ledge a jump still works.
  double get coyoteTime => 0.10;

  /// How long before landing a jump press is remembered.
  double get jumpBuffer => 0.12;

  /// Up out of a stomp. Lower than [jumpSpeed] so that a chain of stomps needs
  /// the button, not just the enemies.
  double get stompBounce => 13.0;

  double get hitInvulnerability => 1.6;
  double get hitKnockbackX => 7.0;
  double get hitKnockbackY => 9.0;

  int get startingLives => 3;
  int get ringScore => 10;
  int get stompScore => 200;
}

/// The whole game, steppable.
final class GameWorld {
  GameWorld({
    required this.level,
    this.tuning = const GameTuning(),
    Duration step = const Duration(milliseconds: 10),
    int maxStepsPerFrame = 6,
  })  : accumulator = FixedStepAccumulator(
          step: step,
          maxStepsPerFrame: maxStepsPerFrame,
        ),
        stepSeconds = step.inMicroseconds / 1e6,
        player = Player(x: level.spawnX, y: level.spawnY),
        enemies = <Enemy>[
          for (final EnemySpawn spawn in level.enemies) Enemy(spawn),
        ],
        rings = <Ring>[for (final RingSpawn spawn in level.rings) Ring(spawn)] {
    lives = tuning.startingLives;
    for (var i = 0; i < rings.length; i++) {
      // Staggered so a row of rings turns like a row of rings and not like one
      // rigid comb.
      rings[i].phase = i * 0.37;
    }
  }

  final Level level;
  final GameTuning tuning;

  /// The framework's accumulator, driven from the animation clock. See the
  /// library documentation for why this class owns one rather than reading the
  /// frame loop's.
  final FixedStepAccumulator accumulator;

  final double stepSeconds;

  final Player player;
  final List<Enemy> enemies;
  final List<Ring> rings;

  int score = 0;
  int lives = 3;
  int ringsCollected = 0;
  int enemiesDefeated = 0;
  GameOutcome outcome = GameOutcome.playing;

  /// Total simulated time, which is the clock every animation is sampled at.
  /// Simulated and not wall-clock, so a replay of the same steps plays the
  /// same poses.
  double elapsed = 0;

  int _checkpoint = -1;
  bool _jumpHeld = false;
  double _coyote = 0;
  double _buffer = 0;

  /// Where the run interpolates from, in `[0, 1)`.
  double get alpha => accumulator.alpha;

  double get respawnX =>
      _checkpoint < 0 ? level.spawnX : level.checkpoints[_checkpoint];

  /// Adds [delta] of real time and runs whatever whole steps it bought.
  ///
  /// Returns the number of steps run, which is what a caller watching for the
  /// spiral of death reads; [FixedStepAccumulator.dropped] is the other half
  /// of that story and is not hidden.
  int advance(Duration delta, GameInput input) =>
      advanceWith(delta, () => input);

  /// The same, asking [input] once per *step* rather than once per frame.
  ///
  /// [advance] holds one input across every step a frame bought, which is
  /// exactly right for a keyboard: a key cannot change between two steps of the
  /// same frame, because nothing ran between them. It is wrong for anything
  /// that *reads the world* to decide, and the autopilot is that: it plans a
  /// jump from where the character is standing now, and reusing that plan for
  /// a second step is a plan made from the wrong position.
  ///
  /// This is not theoretical. The scripted run, which drives [step] directly,
  /// finished the level; the same autopilot driving a window through [advance]
  /// at 104 frames a second against a 100 Hz simulation fell into the first
  /// gap, because its jump-hold counter was counting frames while the world
  /// was counting steps.
  int advanceWith(Duration delta, GameInput Function() input) {
    final int steps = accumulator.advance(delta);
    for (var i = 0; i < steps; i++) {
      step(input());
    }
    return steps;
  }

  /// One fixed step. The only place the world changes.
  void step(GameInput input) {
    final double dt = stepSeconds;
    player.previousX = player.x;
    player.previousY = player.y;
    for (final Enemy enemy in enemies) {
      enemy.previousX = enemy.x;
      enemy.previousY = enemy.y;
    }

    if (outcome != GameOutcome.playing) {
      // The clock keeps running so the death or victory pose keeps animating,
      // but nothing else moves. A world that froze completely would leave the
      // character mid-stride at the finish line.
      elapsed += dt;
      player.motion.update(
        dt: dt,
        onGround: player.onGround,
        velocityX: 0,
        velocityY: 0,
        alive: outcome != GameOutcome.gameOver,
      );
      return;
    }

    elapsed += dt;
    if (player.invulnerable > 0) player.invulnerable -= dt;

    _stepPlayer(input, dt);
    _stepEnemies(dt);
    final bool hurt = _resolveContacts();
    _collectRings();

    player.motion.update(
      dt: dt,
      onGround: player.onGround,
      velocityX: player.velocityX,
      velocityY: player.velocityY,
      hurt: hurt,
      alive: lives > 0,
    );

    for (var i = _checkpoint + 1; i < level.checkpoints.length; i++) {
      if (player.x >= level.checkpoints[i]) _checkpoint = i;
    }

    if (player.y < level.killY) _loseLife(fell: true);
    if (player.x >= level.finishX && outcome == GameOutcome.playing) {
      outcome = GameOutcome.finished;
    }
  }

  void _stepPlayer(GameInput input, double dt) {
    final double axis = input.axis;

    // Horizontal. Accelerating toward a target speed rather than assigning it
    // is what gives the character weight; the friction term is separate so
    // that letting go stops you faster than turning around does.
    final double wanted = axis * tuning.runSpeed;
    final double accel =
        player.onGround ? tuning.groundAcceleration : tuning.airAcceleration;
    if (axis != 0) {
      final double delta = wanted - player.velocityX;
      final double stepChange = accel * dt;
      player.velocityX +=
          delta.abs() <= stepChange ? delta : stepChange * delta.sign;
      player.facing = axis.sign;
    } else {
      final double friction =
          player.onGround ? tuning.groundFriction : tuning.airFriction;
      final double drop = friction * dt;
      player.velocityX = player.velocityX.abs() <= drop
          ? 0
          : player.velocityX - drop * player.velocityX.sign;
    }

    // Jump. The buffer and the coyote window are both timers rather than
    // flags, because both have to survive a variable number of steps: at 100 Hz
    // a 0.12 s buffer is twelve steps and at 30 Hz it is four.
    final bool pressed = input.jump && !_jumpHeld;
    _jumpHeld = input.jump;
    if (pressed) _buffer = tuning.jumpBuffer;
    if (_buffer > 0) _buffer -= dt;
    _coyote = player.onGround ? tuning.coyoteTime : _coyote - dt;

    if (_buffer > 0 && _coyote > 0) {
      player.velocityY = tuning.jumpSpeed;
      player.onGround = false;
      _buffer = 0;
      _coyote = 0;
    } else if (!input.jump && player.velocityY > tuning.jumpCutSpeed) {
      player.velocityY = tuning.jumpCutSpeed;
    }

    player.velocityY -= tuning.gravity * dt;
    if (player.velocityY < -tuning.terminalVelocity) {
      player.velocityY = -tuning.terminalVelocity;
    }

    final SweepResult swept = moveAndCollide(
      x: player.x,
      y: player.y,
      halfWidth: Player.halfWidth,
      halfHeight: Player.halfHeight,
      velocityX: player.velocityX,
      velocityY: player.velocityY,
      dt: dt,
      solids: level.boxes,
    );
    player
      ..x = swept.x
      ..y = swept.y
      ..velocityX = swept.velocityX
      ..velocityY = swept.velocityY
      ..onGround = swept.onGround;
  }

  void _stepEnemies(double dt) {
    for (final Enemy enemy in enemies) {
      if (!enemy.alive) {
        enemy.dyingFor += dt;
        continue;
      }
      enemy.x += enemy.direction * enemy.spawn.speed * dt;
      if (enemy.x <= enemy.spawn.patrolMin) {
        enemy.x = enemy.spawn.patrolMin;
        enemy.direction = 1;
      } else if (enemy.x >= enemy.spawn.patrolMax) {
        enemy.x = enemy.spawn.patrolMax;
        enemy.direction = -1;
      }
    }
  }

  /// Player against enemies. Returns whether the player was hurt this step.
  bool _resolveContacts() {
    final Aabb body = player.box;
    var hurt = false;
    for (final Enemy enemy in enemies) {
      if (!enemy.alive) continue;
      if (!body.overlaps(enemy.box)) continue;

      // A stomp and a hit are told apart by where the player *is* and which
      // way they are going, not by which side the overlap is deepest on. The
      // deepest-side test calls a fast horizontal run into an enemy a stomp,
      // because at 8 units a second the horizontal overlap outgrows the
      // vertical one within a step.
      final bool above = player.previousY - Player.halfHeight >=
          enemy.box.top - _stompForgiveness;
      if (player.velocityY < 0 && above) {
        enemy.alive = false;
        enemiesDefeated++;
        score += tuning.stompScore;
        player.velocityY = tuning.stompBounce;
        // The buffer is cleared so that a jump pressed just before landing on
        // an enemy does not immediately spend itself on the bounce.
        _buffer = 0;
        continue;
      }
      if (player.invulnerable > 0) continue;
      hurt = true;
      player
        ..invulnerable = tuning.hitInvulnerability
        ..velocityX = -player.facing * tuning.hitKnockbackX
        ..velocityY = tuning.hitKnockbackY
        ..onGround = false;
      _loseLife(fell: false);
    }
    return hurt;
  }

  /// How far below an enemy's roof the player's feet may already be and still
  /// count as landing on it.
  ///
  /// Zero would mean a stomp only registers on the exact step the feet cross
  /// the roof, which at any real speed they skip straight past.
  static const double _stompForgiveness = 0.22;

  void _collectRings() {
    final Aabb body = player.box.inflated(0.15);
    for (final Ring ring in rings) {
      if (ring.taken) continue;
      if (!body.containsPoint(ring.spawn.x, ring.spawn.y)) {
        final Aabb ringBox = Aabb.centred(
          x: ring.spawn.x,
          y: ring.spawn.y,
          halfWidth: 0.45,
          halfHeight: 0.45,
        );
        if (!body.overlaps(ringBox)) continue;
      }
      ring.taken = true;
      ringsCollected++;
      score += tuning.ringScore;
    }
  }

  void _loseLife({required bool fell}) {
    lives--;
    if (lives <= 0) {
      lives = 0;
      outcome = GameOutcome.gameOver;
      player.motion.reset(MotionState.dead);
      return;
    }
    if (!fell) return;
    // A fall out of the world is the only case that teleports: a hit leaves
    // the player where they were, knocked back, because respawning from a
    // scratch is the fastest way to make a game feel unfair.
    player
      ..x = respawnX
      ..y = level.spawnY + 1.5
      ..velocityX = 0
      ..velocityY = 0
      ..invulnerable = tuning.hitInvulnerability
      ..onGround = false;
    player.motion.reset();
  }

  /// One line naming everything a scripted run has to be able to check.
  String describe() => 'x=${player.x.toStringAsFixed(3)} '
      'y=${player.y.toStringAsFixed(3)} '
      'vx=${player.velocityX.toStringAsFixed(3)} '
      'vy=${player.velocityY.toStringAsFixed(3)} '
      'onGround=${player.onGround} '
      'state=${player.motion.state.name} '
      'score=$score rings=$ringsCollected/${rings.length} '
      'stomps=$enemiesDefeated lives=$lives '
      'outcome=${outcome.name} '
      'steps=${accumulator.stepsTaken} '
      'dropped=${accumulator.dropped.inMilliseconds}ms';
}
