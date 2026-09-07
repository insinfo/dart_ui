/// The route from a key to the character, driven through the real widget tree.
///
/// The physics has its own tests and they cannot reach this. The bug they
/// cannot catch is the one every game of this shape actually ships with: a
/// perfectly correct simulation that nothing is telling to move, because the
/// key never arrived — the widget never took focus, or the handler filtered out
/// the key-up, or the ticker was registered and never fired. Every case here
/// dispatches real `KeyDownEvent`s and `KeyUpEvent`s at the mounted game and
/// then asks the *world* where the character ended up, never the input code,
/// which is exactly the layer the bug is not in.
///
/// It also drives a real frame, which means the scene is assembled and
/// rasterised on every tick below. That is deliberate: it is the only automatic
/// check that the mesh builders produce geometry at all, and a character built
/// out of zero triangles is invisible and completely silent.
///
/// What none of it can prove is whether the game *feels* right. That needs
/// hands on a keyboard.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

import '../../../examples/side_scroller_game/game/follow_camera.dart';
import '../../../examples/side_scroller_game/game/motion_state.dart';
import '../../../examples/side_scroller_game/game/world.dart';
import '../../../examples/side_scroller_game/main.dart';

/// Small on purpose: every frame below rasterises the scene on the CPU,
/// because a test has no GPU surface, and the cost of that is per pixel.
const Size kWindowSize = Size(420, 280);

const int kKeyA = 0x41;
const int kKeyD = 0x44;
const int kKeyR = 0x52;

void main() {
  setUpAll(FrameworkFonts.install);
  tearDownAll(FontRegistry.instance.reset);

  test('holding right runs, and letting go stops', () {
    final _Harness harness = _Harness();
    final double start = harness.world.player.x;

    harness.keyDown(logicalKeyArrowRight);
    harness.run(60);
    expect(harness.world.player.x, greaterThan(start + 2),
        reason: 'a held key must keep arriving, frame after frame');
    expect(harness.world.player.facing, 1);
    expect(harness.world.player.motion.state, MotionState.run);

    harness.keyUp(logicalKeyArrowRight);
    harness.run(60);
    // Ground friction is 52 units per second per second, so eight units a
    // second is gone well inside a second.
    expect(harness.world.player.velocityX, 0);
    expect(harness.world.player.motion.state, MotionState.idle);
    harness.dispose();
  });

  test('A and D drive it as well as the arrows, and turn the character', () {
    final _Harness harness = _Harness();
    harness.keyDown(kKeyD);
    harness.run(40);
    harness.keyUp(kKeyD);
    final double turnedAt = harness.world.player.x;

    harness.keyDown(kKeyA);
    harness.run(60);
    expect(harness.world.player.facing, -1);
    expect(harness.world.player.x, lessThan(turnedAt));
    harness.dispose();
  });

  test('space jumps, and a longer hold jumps higher', () {
    double apex({required int holdFrames}) {
      final _Harness harness = _Harness();
      // Settled on the floor first: the spawn is above it, so a jump on the
      // first frame is a jump taken in mid-air and goes nowhere.
      harness.run(40);
      final double floor = harness.world.player.y;
      harness.keyDown(logicalKeySpace);
      var highest = floor;
      for (var i = 0; i < 60; i++) {
        if (i == holdFrames) harness.keyUp(logicalKeySpace);
        harness.run(1);
        if (harness.world.player.y > highest) highest = harness.world.player.y;
      }
      harness.dispose();
      return highest - floor;
    }

    final double tapped = apex(holdFrames: 1);
    final double held = apex(holdFrames: 30);
    expect(tapped, greaterThan(0.4), reason: 'a tap must still jump');
    expect(held, greaterThan(tapped + 1.2));
  });

  test('the camera follows, with a dead zone and a lead', () {
    final _Harness harness = _Harness();
    final double before = harness.camera.x;

    harness.keyDown(logicalKeyArrowRight);
    harness.run(120);

    expect(harness.camera.x, greaterThan(before));
    // The character stays *behind* the camera's aim while running right, which
    // is what the lead is: the screen shows where they are going.
    expect(harness.camera.x, greaterThan(harness.world.player.x));
    expect(harness.camera.appliedLead, greaterThan(0));
    harness.dispose();
  });

  test('escape pauses the world and escape again releases it', () {
    final _Harness harness = _Harness();
    harness.keyDown(logicalKeyArrowRight);
    harness.run(40);

    harness.key(logicalKeyEscape);
    final double paused = harness.world.player.x;
    harness.run(60);
    expect(harness.world.player.x, paused,
        reason: 'nothing moves while paused');

    harness.key(logicalKeyEscape);
    harness.run(40);
    expect(harness.world.player.x, greaterThan(paused));
    harness.dispose();
  });

  test('R starts a new run, not a resumed one', () {
    final _Harness harness = _Harness();
    harness.keyDown(logicalKeyArrowRight);
    harness.run(120);
    final GameWorld before = harness.world;
    expect(before.player.x, greaterThan(6));

    harness.key(kKeyR);
    harness.run(1);
    expect(harness.world, isNot(same(before)));
    expect(harness.world.player.x, closeTo(harness.world.level.spawnX, 0.6));
    expect(harness.world.score, 0);
    expect(harness.world.lives, 3);
    // And the key that was held before the restart is not still held after it,
    // which is the difference between restarting and being shoved.
    expect(harness.world.player.velocityX, 0);
    harness.dispose();
  });

  test('a run collects rings and scores them', () {
    final _Harness harness = _Harness();
    harness.keyDown(logicalKeyArrowRight);
    harness.run(200);
    expect(harness.world.ringsCollected, greaterThan(0));
    expect(harness.world.score, harness.world.ringsCollected * 10);
    harness.dispose();
  });

  test('every frame assembles geometry for the character', () {
    // The check that the cast is drawn at all. A pose that built nothing would
    // leave the game running perfectly with an invisible character, and
    // nothing else here would notice.
    final _Harness harness = _Harness();
    harness.keyDown(logicalKeyArrowRight);
    harness.run(30);

    expect(harness.session.sceneStats.dynamicVertices, greaterThan(200));
    expect(harness.session.sceneStats.dynamicTriangles, greaterThan(200));
    expect(harness.session.sceneStats.primitives, greaterThan(8));
    expect(harness.session.drawPath, 'CPU rasteriza',
        reason: 'a test has no GPU surface, and must fall back rather than '
            'draw nothing');
    expect(harness.session.triangles, greaterThan(500));
    harness.dispose();
  });

  test('the HUD rebuild lands outside the frame and the tree still settles',
      () async {
    // The trap this whole design is arranged around: a ticker runs inside the
    // frame, so a `setState` from one dirties the build the frame is settling
    // and the loop never converges. `_Harness.frame` throws in exactly that
    // case, so ticking through a ring pickup — which is what changes the HUD —
    // and then letting the pending timers run is the test.
    final _Harness harness = _Harness();
    harness.keyDown(logicalKeyArrowRight);
    for (var i = 0; i < 12; i++) {
      harness.run(20);
      // Lets the `Timer.run` the tick scheduled actually fire, which is where
      // the rebuild happens.
      await Future<void>.delayed(Duration.zero);
      harness.frame();
    }
    expect(harness.world.ringsCollected, greaterThan(0),
        reason: 'the HUD must have had something to rebuild for');
    harness.dispose();
  });
}

final class _Harness {
  _Harness() {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(kWindowSize),
      ),
    );
    owner.updateRoot(
      AnimationScope(
        clock: clock,
        child: SideScrollerGame(session: session),
      ),
    );
    frame();
  }

  late final BuildOwner owner;
  final AnimationClock clock = AnimationClock();
  final GameSession session = GameSession();

  GameWorld get world => session.world!;

  /// The camera the game is driving, asked for its position rather than told.
  FollowCamera get camera => session.camera!;

  int _micros = 0;

  /// One frame of the loop: the clock first, then the tree.
  ///
  /// 16 ms of simulated wall time, which the world's accumulator turns into one
  /// or two of its own 10 ms steps.
  void run([int frames = 1]) {
    for (var i = 0; i < frames; i++) {
      clock.tick(Duration(microseconds: _micros += 16000));
      frame();
    }
  }

  void frame({int maxPasses = 8}) {
    for (var pass = 0; pass < maxPasses; pass++) {
      owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
    throw StateError('the game never settled in $maxPasses passes');
  }

  void keyDown(int logicalKey) {
    owner.dispatchKeyEvent(KeyDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration(microseconds: _micros),
      physicalKey: logicalKey,
      logicalKey: logicalKey,
    ));
  }

  void keyUp(int logicalKey) {
    owner.dispatchKeyEvent(KeyUpEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration(microseconds: _micros),
      physicalKey: logicalKey,
      logicalKey: logicalKey,
    ));
  }

  /// A press and a release, for the keys that act on the edge.
  void key(int logicalKey) {
    keyDown(logicalKey);
    keyUp(logicalKey);
    frame();
  }

  void dispose() => owner.dispose();
}
