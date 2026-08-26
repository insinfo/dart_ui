/// The real-time frame loop's policy, against a clock the test moves by hand.
///
/// ## Why this suite exists before the loop is wired
///
/// Nothing in `lib/` builds a [FrameLoopController] yet - `Application.run`
/// still draws only what invalidation asks for - and `frame_loop.dart` says so
/// in its own library comment. A design that is carried unwired and unexercised
/// is a design nobody can trust when the day comes to turn it on: the first
/// person to wire it would be debugging the loop and the policy at once. So the
/// policy is pinned here, at the seam a caller would use, and the file's claims
/// become checkable statements rather than prose.
///
/// The claim that matters most is the **coexistence guarantee**:
/// [FrameLoopMode.onDemand] must answer "no frame is due" forever, so that
/// wiring the controller into an event-driven application changes nothing at
/// all about it. Everything else in this file is a feature; that one is a
/// promise, and it is the first group below.
library;

import 'package:dart_ui/src/app/frame_loop.dart';
import 'package:dart_ui/src/foundation/frame_time.dart';
import 'package:test/test.dart';

const Duration _interval = Duration(milliseconds: 10);

void main() {
  group('on-demand mode is inert', () {
    test('no frame is ever due, however much time passes', () {
      final ManualClock clock = ManualClock();
      final FrameLoopController loop = FrameLoopController(clock: clock);

      expect(loop.mode, FrameLoopMode.onDemand, reason: 'the default');
      expect(loop.isContinuous, isFalse);
      expect(loop.isFrameDue, isFalse);

      clock.advance(const Duration(seconds: 10));

      expect(loop.isFrameDue, isFalse);
      expect(
        loop.timeUntilNextFrame,
        Duration.zero,
        reason: 'there is no next frame to wait for, and the caller is told '
            'so by a value it must not use as a wait',
      );
    });

    test('an on-demand frame is recorded but never counted as late', () {
      final ManualClock clock = ManualClock();
      final FrameLoopController loop = FrameLoopController(clock: clock);

      clock.advance(const Duration(seconds: 3));
      loop.beginFrame();
      clock.advance(const Duration(milliseconds: 4));
      loop.endFrame(presented: true);

      expect(loop.statistics.framesProduced, 1);
      expect(loop.statistics.framesPresented, 1);
      expect(loop.statistics.lateFrames, 0);
      expect(loop.statistics.framesDropped, 0);
    });
  });

  group('continuous mode paces frames', () {
    FrameLoopController continuous(ManualClock clock, {int catchUp = 1}) =>
        FrameLoopController(
          clock: clock,
          options: FrameLoopOptions(
            mode: FrameLoopMode.continuous,
            frameInterval: _interval,
            maxCatchUpFrames: catchUp,
          ),
        );

    test('a frame comes due exactly one interval after the last one', () {
      final ManualClock clock = ManualClock();
      final FrameLoopController loop = continuous(clock);

      expect(loop.isFrameDue, isTrue, reason: 'the first frame is due at once');
      loop.beginFrame();
      loop.endFrame(presented: true);

      expect(loop.isFrameDue, isFalse);
      expect(loop.timeUntilNextFrame, _interval);

      clock.advance(_interval);
      expect(loop.isFrameDue, isTrue);
    });

    test('a stall drops the deadlines it went past, minus the catch-up', () {
      final ManualClock clock = ManualClock();
      final FrameLoopController loop = continuous(clock);

      loop
        ..beginFrame()
        ..endFrame(presented: true);
      // Five whole intervals with no frame drawn for any of them.
      clock.advance(_interval * 5);
      loop
        ..beginFrame()
        ..endFrame(presented: true);

      expect(loop.statistics.lateFrames, 1);
      expect(loop.statistics.worstLateness, _interval * 4);
      expect(
        loop.statistics.framesDropped,
        3,
        reason: 'four deadlines went by with nothing drawn for them - the '
            'fifth is the one this frame is drawing - and one of the four is '
            'made up by the catch-up allowance',
      );
      expect(
        loop.isFrameDue,
        isTrue,
        reason: 'the made-up frame is due immediately, which is what a '
            'catch-up allowance of one means',
      );
    });

    test('no catch-up allowance means every missed deadline is a drop', () {
      final ManualClock clock = ManualClock();
      final FrameLoopController loop = continuous(clock, catchUp: 0);

      loop
        ..beginFrame()
        ..endFrame(presented: true);
      clock.advance(_interval * 5);
      loop
        ..beginFrame()
        ..endFrame(presented: true);

      expect(
        loop.statistics.framesDropped,
        4,
        reason: 'the same four, with nothing made up',
      );
      expect(loop.isFrameDue, isFalse);
    });

    test('switching into continuous rebases the schedule to now', () {
      final ManualClock clock = ManualClock();
      final FrameLoopController loop = continuous(clock);

      loop
        ..beginFrame()
        ..endFrame(presented: true);
      loop.setMode(FrameLoopMode.onDemand);
      // A minute of on-demand work would leave a stale deadline a minute in
      // the past, and resuming against it would count 6000 dropped frames.
      clock.advance(const Duration(minutes: 1));
      loop.setMode(FrameLoopMode.continuous);

      expect(loop.isFrameDue, isTrue);
      loop
        ..beginFrame()
        ..endFrame(presented: true);
      expect(loop.statistics.framesDropped, 0);
    });

    test('a new interval takes effect on the next frame, not the old one', () {
      final ManualClock clock = ManualClock();
      final FrameLoopController loop = continuous(clock);

      loop
        ..beginFrame()
        ..endFrame(presented: true);
      loop.setFrameInterval(const Duration(milliseconds: 40));

      expect(loop.frameInterval, const Duration(milliseconds: 40));
      expect(loop.timeUntilNextFrame, const Duration(milliseconds: 40));
    });
  });

  group('the pacing record', () {
    test('separates the CPU half of a frame from the present half', () {
      final ManualClock clock = ManualClock();
      final FrameLoopController loop = FrameLoopController(clock: clock);

      loop.beginFrame();
      clock.advance(const Duration(milliseconds: 4));
      loop.markCpuComplete();
      clock.advance(const Duration(milliseconds: 12));
      loop.endFrame(presented: true);

      final FramePacingSample sample = loop.statistics.last!;
      expect(sample.cpu, const Duration(milliseconds: 4));
      expect(sample.present, const Duration(milliseconds: 12));
      expect(sample.total, const Duration(milliseconds: 16));
      expect(sample.presented, isTrue);
    });

    test('a frame that did not present still costs what it cost', () {
      final ManualClock clock = ManualClock();
      final FrameLoopController loop = FrameLoopController(clock: clock);

      loop.beginFrame();
      clock.advance(const Duration(milliseconds: 7));
      loop.endFrame(presented: false);

      expect(loop.statistics.framesProduced, 1);
      expect(loop.statistics.framesPresented, 0);
      expect(loop.statistics.last!.presented, isFalse);
      expect(loop.statistics.last!.total, const Duration(milliseconds: 7));
    });

    test('an abandoned frame leaves no trace in the record', () {
      final ManualClock clock = ManualClock();
      final FrameLoopController loop = FrameLoopController(clock: clock);

      loop.beginFrame();
      clock.advance(const Duration(milliseconds: 3));
      loop.abandonFrame();

      expect(loop.isFrameInFlight, isFalse);
      expect(loop.statistics.count, 0);
      expect(loop.statistics.last, isNull);
    });

    test('input-to-frame latency measures the pump-then-draw order', () {
      final ManualClock clock = ManualClock();
      final FrameLoopController loop = FrameLoopController(clock: clock);

      loop.notePumpComplete();
      clock.advance(const Duration(microseconds: 250));
      loop.beginFrame();
      loop.endFrame(presented: true);

      expect(
        loop.statistics.inputToFrameLatency,
        const Duration(microseconds: 250),
      );
    });

    test('the ring keeps the newest samples and no more than its capacity', () {
      final ManualClock clock = ManualClock();
      final FrameLoopController loop = FrameLoopController(
        clock: clock,
        options: const FrameLoopOptions(pacingCapacity: 3),
      );

      for (var i = 0; i < 5; i++) {
        loop.beginFrame();
        clock.advance(const Duration(milliseconds: 1));
        loop.endFrame(presented: true);
      }

      expect(loop.statistics.count, 3);
      expect(loop.statistics.framesProduced, 5);
      expect(
        <int>[
          for (int i = 0; i < 3; i++) loop.statistics.sampleAt(i).frameNumber
        ],
        <int>[3, 4, 5],
      );
    });
  });

  group('the frame protocol is enforced rather than assumed', () {
    test('two beginFrames without an endFrame is a named error', () {
      final FrameLoopController loop = FrameLoopController();
      loop.beginFrame();
      expect(loop.beginFrame, throwsStateError);
    });

    test('endFrame and markCpuComplete outside a frame are named errors', () {
      final FrameLoopController loop = FrameLoopController();
      expect(() => loop.endFrame(presented: true), throwsStateError);
      expect(loop.markCpuComplete, throwsStateError);
    });

    test('a zero interval is refused rather than spun on', () {
      expect(
        () => FrameLoopController(
          options: const FrameLoopOptions(frameInterval: Duration.zero),
        ),
        throwsArgumentError,
      );
      expect(
        () => FrameLoopController().setFrameInterval(Duration.zero),
        throwsArgumentError,
      );
    });
  });

  group('the fixed-step accumulator', () {
    test('runs whole steps and reports the leftover as an interpolation', () {
      final FixedStepAccumulator sim = FixedStepAccumulator(
        step: const Duration(milliseconds: 10),
      );

      expect(sim.advance(const Duration(milliseconds: 25)), 2);
      expect(sim.stepsTaken, 2);
      expect(sim.pending, const Duration(milliseconds: 5));
      expect(sim.alpha, closeTo(0.5, 1e-9));
    });

    test('a first frame with no elapsed time runs no step', () {
      final FixedStepAccumulator sim = FixedStepAccumulator(
        step: const Duration(milliseconds: 10),
      );

      expect(sim.advance(Duration.zero), 0);
      expect(sim.alpha, 0);
    });

    test('a stall is clamped and the abandoned time is reported', () {
      final FixedStepAccumulator sim = FixedStepAccumulator(
        step: const Duration(milliseconds: 10),
        maxStepsPerFrame: 3,
      );

      expect(sim.advance(const Duration(milliseconds: 100)), 3);
      expect(
        sim.dropped,
        isNot(Duration.zero),
        reason: 'the spiral of death is prevented by dropping simulated time, '
            'and dropping it silently would turn a slow world into a mystery',
      );
    });

    test('time cannot run backwards', () {
      final FixedStepAccumulator sim = FixedStepAccumulator(
        step: const Duration(milliseconds: 10),
      );
      expect(
        () => sim.advance(const Duration(milliseconds: -1)),
        throwsArgumentError,
      );
    });

    test('the controller builds one only when a step was asked for', () {
      expect(FrameLoopController().simulation, isNull);
      expect(
        FrameLoopController(
          options: const FrameLoopOptions(
            fixedTimeStep: Duration(milliseconds: 10),
          ),
        ).simulation,
        isNotNull,
      );
    });

    test('the controller advances it and publishes alpha as interpolation', () {
      final ManualClock clock = ManualClock();
      final FrameLoopController loop = FrameLoopController(
        clock: clock,
        options: const FrameLoopOptions(
          mode: FrameLoopMode.continuous,
          frameInterval: _interval,
          fixedTimeStep: Duration(milliseconds: 10),
        ),
      );

      loop
        ..beginFrame()
        ..endFrame(presented: true);
      clock.advance(const Duration(milliseconds: 15));
      final FrameTime time = loop.beginFrame();

      expect(loop.simulation!.stepsTaken, 1);
      expect(time.interpolation, closeTo(0.5, 1e-9));
      expect(time.delta, const Duration(milliseconds: 15));
      expect(time.frameNumber, 2);
    });
  });
}
