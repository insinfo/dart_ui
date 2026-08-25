/// The clock and its join to the frame scheduler.
///
/// The headline assertion of this file is "once per frame - not zero, not
/// twice". Everything runs on [ManualDispatcher]'s virtual clock: nothing here
/// sleeps, and nothing reads `DateTime.now`. If any of these tests ever needed
/// real time, the design would be wrong.
library;

import 'package:dart_ui/src/animation/animation.dart';
import 'package:dart_ui/src/animation/clock.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/layout/pipeline.dart';
import 'package:dart_ui/src/scheduler/frame_scheduler.dart';
import 'package:dart_ui/src/scheduler/manual_dispatcher.dart';
import 'package:test/test.dart';

/// A ticker that only records what it was told, so a test can count.
final class _RecordingTicker implements AnimationTicker {
  _RecordingTicker({this.ticking = true});

  final List<Duration> stamps = <Duration>[];
  bool ticking;

  @override
  bool get isTicking => ticking;

  @override
  void tick(Duration timestamp) => stamps.add(timestamp);
}

const Duration _tenMs = Duration(milliseconds: 10);

FrameScheduler _scheduler({
  ManualDispatcher? dispatcher,
  List<DisplayList>? frames,
}) =>
    FrameScheduler(
      dispatcher: dispatcher ?? ManualDispatcher(),
      frameInterval: _tenMs,
      onFrame: frames?.add ?? (DisplayList _) {},
    );

void main() {
  group('AnimationClock', () {
    test('hands every ticker the same frame timestamp', () {
      final AnimationClock clock = AnimationClock();
      final _RecordingTicker a = _RecordingTicker();
      final _RecordingTicker b = _RecordingTicker();
      clock
        ..addTicker(a)
        ..addTicker(b)
        ..tick(const Duration(milliseconds: 16));

      expect(a.stamps, <Duration>[const Duration(milliseconds: 16)]);
      expect(b.stamps, <Duration>[const Duration(milliseconds: 16)]);
      expect(clock.timestamp, const Duration(milliseconds: 16));
      expect(clock.tickCount, 1);
    });

    test('a backwards timestamp throws rather than being clamped', () {
      final AnimationClock clock = AnimationClock()
        ..tick(const Duration(milliseconds: 20));
      expect(
        () => clock.tick(const Duration(milliseconds: 19)),
        throwsArgumentError,
      );
      // An equal timestamp is legal: a frame can be produced without time
      // having moved, and every ticker treats it as a zero-length step.
      clock.tick(const Duration(milliseconds: 20));
      expect(clock.tickCount, 2);
    });

    test('registering the same ticker twice is rejected', () {
      final AnimationClock clock = AnimationClock();
      final _RecordingTicker ticker = _RecordingTicker();
      clock.addTicker(ticker);
      expect(() => clock.addTicker(ticker), throwsStateError);
      expect(clock.tickerCount, 1);
    });

    test('a ticker removed from inside a tick does not skip its neighbour', () {
      final AnimationClock clock = AnimationClock();
      final _RecordingTicker second = _RecordingTicker();
      final _RecordingTicker third = _RecordingTicker();
      // The first ticker unregisters the second while the walk is in
      // progress. A list mutated underneath the walk would step over `third`.
      clock
        ..addTicker(_ReentrantTicker(() => clock.removeTicker(second)))
        ..addTicker(second)
        ..addTicker(third);

      clock.tick(Duration.zero);
      expect(second.stamps, hasLength(1),
          reason: 'the removal is deferred to the end of the frame');
      expect(third.stamps, hasLength(1), reason: 'the neighbour still ran');
      expect(clock.tickerCount, 2);

      clock.tick(_tenMs);
      expect(second.stamps, hasLength(1));
      expect(third.stamps, hasLength(2));
    });

    test('hasActiveTickers reflects what the tickers say', () {
      final AnimationClock clock = AnimationClock();
      final _RecordingTicker idle = _RecordingTicker(ticking: false);
      clock.addTicker(idle);
      expect(clock.hasActiveTickers, isFalse);
      idle.ticking = true;
      expect(clock.hasActiveTickers, isTrue);
    });

    test('a nested tick is refused', () {
      final AnimationClock clock = AnimationClock();
      clock.addTicker(_ReentrantTicker(() => clock.tick(_tenMs)));
      expect(() => clock.tick(Duration.zero), throwsStateError);
    });
  });

  group('FrameScheduler frame callbacks', () {
    test('run before the pipeline draws, with the frame timestamp', () {
      final List<String> order = <String>[];
      final PipelineOwner owner = PipelineOwner();
      final FrameScheduler scheduler = FrameScheduler(
        dispatcher: ManualDispatcher(),
        pipelineOwner: owner,
        frameInterval: _tenMs,
        onFrame: (DisplayList _) => order.add('painted'),
      );
      Duration? seen;
      scheduler.addFrameCallback((Duration timestamp) {
        order.add('callback');
        seen = timestamp;
      });

      scheduler
        ..scheduleFrame()
        ..pump();

      expect(order, <String>['callback', 'painted']);
      expect(seen, Duration.zero);
      expect(scheduler.frameNumber, 1);
    });

    test('the existing coalescing contract is untouched', () {
      final List<DisplayList> frames = <DisplayList>[];
      final FrameScheduler scheduler = _scheduler(frames: frames);
      scheduler
        ..scheduleFrame()
        ..scheduleFrame();
      expect(scheduler.hasScheduledFrame, isTrue);
      scheduler.pump();
      expect(frames, hasLength(1));
      expect(scheduler.hasScheduledFrame, isFalse);
    });

    test('a failing callback is reported and later callbacks still run', () {
      final List<String> order = <String>[];
      final List<(FramePipelinePhase, Object)> errors =
          <(FramePipelinePhase, Object)>[];
      final FrameScheduler scheduler = FrameScheduler(
        onFrame: (_) => order.add('painted'),
        onError: (phase, error, _) => errors.add((phase, error)),
      );
      scheduler
        ..addFrameCallback((_) {
          order.add('first');
          throw StateError('broken animation');
        })
        ..addFrameCallback((_) => order.add('second'))
        ..scheduleFrame()
        ..pump();

      expect(order, <String>['first', 'second', 'painted']);
      expect(errors, hasLength(1));
      expect(errors.single.$1, FramePipelinePhase.callbacks);
      expect(errors.single.$2, isA<StateError>());
    });

    test('registering the same callback twice is rejected', () {
      final FrameScheduler scheduler = _scheduler();
      void callback(Duration _) {}
      scheduler.addFrameCallback(callback);
      expect(() => scheduler.addFrameCallback(callback), throwsStateError);
      expect(scheduler.frameCallbackCount, 1);
      expect(scheduler.removeFrameCallback(callback), isTrue);
      expect(scheduler.removeFrameCallback(callback), isFalse);
    });

    test('scheduleNextFrame arms exactly one timer per interval', () {
      final ManualDispatcher dispatcher = ManualDispatcher();
      final List<DisplayList> frames = <DisplayList>[];
      final FrameScheduler scheduler =
          _scheduler(dispatcher: dispatcher, frames: frames);

      scheduler
        ..scheduleNextFrame()
        ..scheduleNextFrame();
      expect(dispatcher.pendingTimerCount, 1);

      scheduler.advance(_tenMs);
      expect(frames, hasLength(1));
      expect(scheduler.frameTimestamp, _tenMs);
      // Nothing re-armed it, so time may pass with no further frames.
      scheduler.advance(const Duration(seconds: 1));
      expect(frames, hasLength(1));
    });

    test('a dirty mark raised inside a frame callback does not add a frame',
        () {
      // The callback phase runs before drawFrame, so this frame will already
      // pick the mark up. Scheduling another would double-advance every
      // animation.
      final PipelineOwner owner = PipelineOwner();
      final List<DisplayList> frames = <DisplayList>[];
      final FrameScheduler scheduler = FrameScheduler(
        dispatcher: ManualDispatcher(),
        pipelineOwner: owner,
        frameInterval: _tenMs,
        onFrame: frames.add,
      );
      scheduler.addFrameCallback((Duration _) => owner.requestVisualUpdate());

      scheduler
        ..scheduleFrame()
        ..pump();

      expect(frames, hasLength(1));
      expect(scheduler.frameNumber, 1);
    });
  });

  group('an attached clock advances animations once per frame', () {
    test('exactly one tick per frame over a long window', () {
      final ManualDispatcher dispatcher = ManualDispatcher();
      final List<DisplayList> frames = <DisplayList>[];
      final FrameScheduler scheduler =
          _scheduler(dispatcher: dispatcher, frames: frames);
      final AnimationClock clock = AnimationClock()..attachTo(scheduler);
      final AnimationController controller = AnimationController(
        clock: clock,
        duration: const Duration(milliseconds: 100),
      );
      int notifications = 0;
      controller
        ..addListener(() => notifications++)
        ..forward();

      scheduler.advance(const Duration(milliseconds: 100));

      // Ten 10 ms frames. The first only establishes the controller's
      // baseline, so nine of them actually move the value.
      expect(scheduler.frameNumber, 10);
      expect(clock.tickCount, 10);
      expect(frames, hasLength(10));
      expect(notifications, 9);
      expect(controller.value, 0.9);
    });

    test('the loop stops itself when the animation finishes', () {
      final FrameScheduler scheduler = _scheduler();
      final AnimationClock clock = AnimationClock()..attachTo(scheduler);
      final AnimationController controller = AnimationController(
        clock: clock,
        duration: const Duration(milliseconds: 100),
      )..forward();

      scheduler.advance(const Duration(milliseconds: 110));
      expect(controller.value, 1.0);
      expect(controller.status, AnimationStatus.completed);
      expect(scheduler.frameNumber, 11);

      // A whole simulated second later, still eleven frames: an idle
      // animation must not keep the loop hot.
      scheduler.advance(const Duration(seconds: 1));
      expect(scheduler.frameNumber, 11);
      expect(clock.tickCount, 11);
    });

    test('two animations share one frame stream', () {
      final ManualDispatcher dispatcher = ManualDispatcher();
      final FrameScheduler scheduler = _scheduler(dispatcher: dispatcher);
      final AnimationClock clock = AnimationClock()..attachTo(scheduler);
      final AnimationController first = AnimationController(
        clock: clock,
        duration: const Duration(milliseconds: 50),
      )..forward();
      final AnimationController second = AnimationController(
        clock: clock,
        duration: const Duration(milliseconds: 100),
      )..forward();

      // Section 32.2: an animation asks for a frame, it does not create a
      // timer per property. Two controllers, one armed timer.
      expect(dispatcher.pendingTimerCount, 1);

      scheduler.advance(const Duration(milliseconds: 60));
      expect(scheduler.frameNumber, 6);
      expect(first.value, 1.0);
      expect(second.value, 0.5);
      // The finished one stops asking; the other keeps the loop alive.
      expect(dispatcher.pendingTimerCount, 1);
    });

    test('detaching stops the clock being fed', () {
      final FrameScheduler scheduler = _scheduler();
      final AnimationClock clock = AnimationClock()..attachTo(scheduler);
      AnimationController(
        clock: clock,
        duration: const Duration(milliseconds: 100),
      ).forward();

      scheduler.advance(const Duration(milliseconds: 30));
      final int ticks = clock.tickCount;
      expect(ticks, 3);

      clock.detach();
      scheduler.advance(const Duration(milliseconds: 100));
      expect(clock.tickCount, ticks);
      expect(scheduler.frameCallbackCount, 0);
    });

    test('attaching twice is rejected', () {
      final FrameScheduler scheduler = _scheduler();
      final AnimationClock clock = AnimationClock()..attachTo(scheduler);
      expect(() => clock.attachTo(scheduler), throwsStateError);
    });
  });
}

/// A ticker that calls back into the clock, to prove re-entrancy is refused.
final class _ReentrantTicker implements AnimationTicker {
  _ReentrantTicker(this.action);

  final void Function() action;

  @override
  bool get isTicking => true;

  @override
  void tick(Duration timestamp) => action();
}
