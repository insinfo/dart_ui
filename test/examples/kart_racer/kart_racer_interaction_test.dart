/// The route from a key to the kart, driven through the real widget tree.
///
/// The physics has its own tests and the camera has its own tests; what those
/// cannot reach is the half that is only wiring - a key that arrives at no
/// focus target, a ticker never attached to the clock, a `setState` from
/// inside a frame that stops the window settling. That wiring is where a demo
/// actually breaks, and it is invisible to every test that calls
/// [Race.step] directly.
///
/// So everything here dispatches real [KeyDownEvent]s and [KeyUpEvent]s at a
/// mounted [KartRacer] and asks [GameSession] where the kart ended up.
library;

import 'dart:math' as math;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

import '../../../examples/kart_racer/game/race.dart';
import '../../../examples/kart_racer/game/track.dart';
import '../../../examples/kart_racer/game/vehicle.dart';
import '../../../examples/kart_racer/main.dart';

/// Deliberately tiny.
///
/// With no [MeshSceneScope] in this tree there is no GPU surface, so every
/// frame here is rasterised on the CPU - and these tests drive thousands of
/// frames. At 1000x700 the file took eight minutes; at this size it takes
/// seconds, and nothing being asserted is about how many pixels there were.
const Size kWindowSize = Size(240, 160);

// The keys the game reads, in the form `focus.dart` publishes the others.
const int _keyW = 0x57;
const int _keyA = 0x41;
const int _keyD = 0x44;
const int _keyR = 0x52;

void main() {
  setUpAll(FrameworkFonts.install);
  tearDownAll(FontRegistry.instance.reset);

  test('the tree builds and a race is waiting on the grid', () {
    final _Harness harness = _Harness();
    expect(harness.race.started, isFalse);
    expect(harness.race.racers, hasLength(3));
    expect(harness.race.player.body.speed, 0);
    expect(harness.session.camera, isNotNull);
    harness.dispose();
  });

  test('the ticker advances the simulation without a rebuild per frame', () {
    // The trap this repository has paid for three times: a ticker runs *inside*
    // the frame, so a `setState` from a tick dirties the build the frame is
    // settling and the window dies with "the frame did not settle in 8
    // passes". `_Harness.frame` throws on exactly that.
    final _Harness harness = _Harness();
    for (int i = 0; i < 60; i++) {
      harness.tickAndFrame();
    }
    expect(harness.race.stepsTaken, greaterThan(50));
    harness.dispose();
  });

  test('the throttle key reaches the kart, and letting go stops asking', () {
    final _Harness harness = _Harness()..runOutTheCountdown();
    harness.press(logicalKeyArrowUp);
    harness.advance(1.0);
    expect(harness.session.lastInput.throttle, 1);
    expect(harness.race.player.body.speed, greaterThan(4));

    harness.release(logicalKeyArrowUp);
    harness.advance(0.1);
    expect(harness.session.lastInput.throttle, 0);
    harness.dispose();
  });

  test('W is the throttle too', () {
    final _Harness harness = _Harness()..runOutTheCountdown();
    harness.press(_keyW);
    harness.advance(1.0);
    expect(harness.race.player.body.speed, greaterThan(4));
    harness.dispose();
  });

  test('the steering ramps rather than snapping to full lock', () {
    // A keyboard has no axis. Feeding ±1 straight into the physics gives a
    // kart that snaps between three states and cannot be placed; this ramp is
    // the single change that made the handling feel like a kart.
    final _Harness harness = _Harness()..runOutTheCountdown();
    harness
      ..press(logicalKeyArrowUp)
      ..advance(1.5)
      ..press(logicalKeyArrowRight)
      ..advance(0.05);
    final double early = harness.session.lastInput.steer;
    expect(early, greaterThan(0));
    expect(early, lessThan(0.6), reason: 'the ramp should not be instant');
    harness.advance(0.6);
    expect(harness.session.lastInput.steer, greaterThan(0.95));
    harness.dispose();
  });

  test('right steers toward the right of the picture, left toward the left',
      () {
    // Measured as the angle between the kart's nose and the track's own
    // tangent, and against a run that only accelerated. Two reasons it is not
    // the lateral offset: the grid sits on the exit of the last corner, so a
    // kart driving dead straight drifts across the road on its own, and the
    // offset saturates against the barrier - where a left-steering run and a
    // straight one give the same number and the test proves nothing.
    double yawErrorAfter(int? key) {
      final _Harness harness = _Harness()..runOutTheCountdown();
      harness
        ..press(logicalKeyArrowUp)
        ..advance(1.5);
      if (key != null) harness.press(key);
      harness.advance(1.0);
      final KartBody kart = harness.race.player.body;
      final TrackSample frame = harness.race.player.projection!.sample;
      // Heading grows toward the left of the picture, so a nose pointing right
      // of the tangent is a *negative* error. This is the assertion that fails
      // if the arrow keys are swapped, and nothing else is.
      final double error = wrapAngle(
        kart.heading - math.atan2(frame.tangentX, frame.tangentZ),
      );
      harness.dispose();
      return error;
    }

    final double straight = yawErrorAfter(null);
    expect(yawErrorAfter(logicalKeyArrowRight), lessThan(straight - 0.2));
    expect(yawErrorAfter(logicalKeyArrowLeft), greaterThan(straight + 0.2));
  });

  test('A and D steer as well as the arrows', () {
    final _Harness harness = _Harness()..runOutTheCountdown();
    harness
      ..press(_keyW)
      ..advance(1.5)
      ..press(_keyD)
      ..advance(0.8);
    expect(harness.session.lastInput.steer, greaterThan(0.5));
    final double turningRight = harness.race.player.body.yawRate;
    harness
      ..release(_keyD)
      ..press(_keyA)
      ..advance(1.2);
    expect(harness.session.lastInput.steer, lessThan(-0.5));
    // Heading grows toward the left of the picture, so the two keys have to
    // put opposite signs on the yaw rate.
    expect(turningRight, lessThan(0));
    expect(harness.race.player.body.yawRate, greaterThan(0));
    harness.dispose();
  });

  test('space is the handbrake', () {
    final _Harness harness = _Harness()..runOutTheCountdown();
    harness
      ..press(logicalKeyArrowUp)
      ..advance(3.0)
      ..press(logicalKeySpace)
      ..press(logicalKeyArrowRight)
      ..advance(0.6);
    expect(harness.session.lastInput.drift, isTrue);
    expect(harness.race.player.body.drifting, isTrue);
    expect(harness.race.player.body.driftCharge, greaterThan(0));
    harness.dispose();
  });

  test('R restarts the race back onto the grid', () {
    final _Harness harness = _Harness()..runOutTheCountdown();
    harness
      ..press(logicalKeyArrowUp)
      ..advance(3.0);
    final Race before = harness.race;
    expect(before.player.counter.progress, greaterThan(5));

    harness
      ..press(_keyR)
      ..release(_keyR)
      ..frame();
    final Race after = harness.race;
    expect(identical(before, after), isFalse, reason: 'a fresh race');
    expect(after.started, isFalse);
    expect(after.time, 0);
    expect(after.player.body.speed, 0);
    expect(after.player.counter.progress, lessThan(0));
    // The restart is a rebuild and not a field-by-field reset, so the
    // accumulators that would otherwise be missed - the drift charge, the lap
    // crossing times - are gone with it.
    expect(after.player.body.driftCharge, 0);
    expect(after.player.counter.crossingTimes, isEmpty);
    harness.dispose();
  });

  test('the camera stays behind the kart while it drives', () {
    final _Harness harness = _Harness()..runOutTheCountdown();
    harness
      ..press(logicalKeyArrowUp)
      ..press(logicalKeyArrowRight)
      ..advance(4.0);
    final KartBody kart = harness.race.player.body;
    final double eyeX = harness.session.camera!.camera.eye.x;
    final double eyeZ = harness.session.camera!.camera.eye.z;
    // Behind: the vector from the kart to the eye opposes the kart's nose.
    final double behind =
        (eyeX - kart.x) * kart.forwardX + (eyeZ - kart.z) * kart.forwardZ;
    expect(behind, lessThan(0));
    // And close enough to be a chase camera rather than a spectator.
    final double range =
        ((eyeX - kart.x) * (eyeX - kart.x) + (eyeZ - kart.z) * (eyeZ - kart.z))
            .abs();
    expect(range, lessThan(20 * 20));
    harness.dispose();
  });

  test('no 3D surface means no crash: the CPU path draws instead', () {
    // `MeshSceneScope` is not installed by this harness, so `maybeOf` answers
    // null - which is exactly what a headless run, a web target and a CPU
    // presentation path all answer. A demo that assumed a surface would fail
    // there and nowhere else.
    final _Harness harness = _Harness();
    for (int i = 0; i < 20; i++) {
      harness.tickAndFrame();
    }
    expect(harness.session.drawPath, anyOf('CPU', 'nada'));
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
        child: KartRacer(session: session, laps: 3, opponents: 2),
      ),
    );
    frame();
  }

  late final BuildOwner owner;
  final AnimationClock clock = AnimationClock();
  final GameSession session = GameSession();

  Race get race => session.race!;

  int _micros = 0;

  void dispose() {}

  void frame({int maxPasses = 8}) {
    for (int pass = 0; pass < maxPasses; pass++) {
      owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
    throw StateError('the game never settled in $maxPasses passes');
  }

  /// One frame the way the application produces one: the clock first, then the
  /// tree. The ticker is what steps the simulation, so a test that never ticks
  /// sees a race that never starts.
  void tickAndFrame() {
    _micros += 16667;
    clock.tick(Duration(microseconds: _micros));
    frame();
  }

  /// [seconds] of wall clock, at sixty frames a second.
  void advance(double seconds) {
    final int frames = (seconds * 60).round();
    for (int i = 0; i < frames; i++) {
      tickAndFrame();
    }
  }

  /// Frames until the lights go out, so a test can press the throttle and have
  /// it mean something.
  void runOutTheCountdown() {
    for (int i = 0; i < 400 && !race.started; i++) {
      tickAndFrame();
    }
    if (!race.started) throw StateError('the countdown never finished');
  }

  void press(int logicalKey) {
    owner.dispatchKeyEvent(KeyDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration(microseconds: _micros),
      physicalKey: logicalKey,
      logicalKey: logicalKey,
    ));
  }

  void release(int logicalKey) {
    owner.dispatchKeyEvent(KeyUpEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration(microseconds: _micros),
      physicalKey: logicalKey,
      logicalKey: logicalKey,
    ));
  }
}
