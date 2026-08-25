import 'package:dart_ui/src/graphics/video/av_sync.dart';
import 'package:test/test.dart';

/// One 30 fps frame slot, the rate every realistic sequence below uses.
const Duration _frame30 = Duration(microseconds: 33333);

/// Default thresholds, restated so a change to the defaults fails loudly here
/// instead of silently weakening every expectation.
const Duration _tolerance = Duration(milliseconds: 20);
const Duration _dropAfter = Duration(milliseconds: 60);
const Duration _maxWait = Duration(milliseconds: 250);

void main() {
  group('AvSynchronizer defaults', () {
    test('documented thresholds are the ones the policy actually uses', () {
      final sync = AvSynchronizer();

      expect(sync.syncTolerance, _tolerance);
      expect(sync.dropThreshold, _dropAfter);
      expect(sync.maxWaitDelay, _maxWait);
      expect(sync.maxConsecutiveDrops, 2);
      expect(sync.minDropImprovement, Duration.zero);
      expect(sync.consecutiveDrops, 0);
    });

    test('a fresh synchronizer reports empty statistics', () {
      final AvSyncStats stats = AvSynchronizer().stats;

      expect(stats.presented, AvSyncStats.empty.presented);
      expect(stats.dropped, AvSyncStats.empty.dropped);
      expect(stats.waited, AvSyncStats.empty.waited);
      expect(stats.driftSamples, 0);
      expect(stats.averageDrift, Duration.zero);
      expect(stats.minDrift, Duration.zero);
      expect(stats.maxDrift, Duration.zero);
      expect(stats.maxAbsoluteDrift, Duration.zero);
    });

    test('every threshold is validated at construction', () {
      expect(
        () => AvSynchronizer(syncTolerance: const Duration(milliseconds: -1)),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => AvSynchronizer(dropThreshold: const Duration(milliseconds: -1)),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => AvSynchronizer(
          minDropImprovement: const Duration(microseconds: -1),
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => AvSynchronizer(maxWaitDelay: Duration.zero),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => AvSynchronizer(maxConsecutiveDrops: -1),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('AvSynchronizer tolerance window', () {
    test('a perfectly aligned frame is presented with zero drift', () {
      final sync = AvSynchronizer();

      final AvSyncDecision decision = sync.evaluate(
        framePts: const Duration(seconds: 4),
        clock: const Duration(seconds: 4),
        frameDuration: _frame30,
      );

      expect(
        decision,
        const AvSyncDecision(
          action: AvSyncAction.present,
          drift: Duration.zero,
        ),
      );
      expect(decision.isPresent, isTrue);
      expect(decision.delay, Duration.zero);
    });

    test('drift exactly at either tolerance edge still presents', () {
      final sync = AvSynchronizer();

      final AvSyncDecision early = sync.evaluate(
        framePts: const Duration(seconds: 1) + _tolerance,
        clock: const Duration(seconds: 1),
        frameDuration: _frame30,
      );
      final AvSyncDecision late = sync.evaluate(
        framePts: const Duration(seconds: 1) - _tolerance,
        clock: const Duration(seconds: 1),
        frameDuration: _frame30,
      );

      expect(early.action, AvSyncAction.present);
      expect(early.drift, _tolerance);
      expect(early.delay, Duration.zero);
      expect(late.action, AvSyncAction.present);
      expect(late.drift, -_tolerance);
      expect(sync.stats.presented, 2);
      expect(sync.stats.waited, 0);
    });

    test('one microsecond past the edge is the first wait', () {
      final sync = AvSynchronizer();

      final AvSyncDecision decision = sync.evaluate(
        framePts: _tolerance + const Duration(microseconds: 1),
        clock: Duration.zero,
        frameDuration: _frame30,
      );

      expect(decision.action, AvSyncAction.wait);
      expect(decision.delay, const Duration(microseconds: 20001));
      expect(decision.drift, const Duration(microseconds: 20001));
    });

    test('small jitter inside the window never turns into a micro-wait', () {
      final sync = AvSynchronizer();

      for (var microseconds = -19999;
          microseconds <= 19999;
          microseconds += 7) {
        final AvSyncDecision decision = sync.evaluate(
          framePts: Duration(microseconds: 2000000 + microseconds),
          clock: const Duration(seconds: 2),
          frameDuration: _frame30,
        );
        expect(decision.action, AvSyncAction.present);
        expect(decision.delay, Duration.zero);
      }

      expect(sync.stats.waited, 0);
      expect(sync.stats.dropped, 0);
      expect(sync.stats.presented, greaterThan(5000));
    });
  });

  group('AvSynchronizer early frames', () {
    test('an early frame waits for exactly its own drift', () {
      final sync = AvSynchronizer();

      final AvSyncDecision decision = sync.evaluate(
        framePts: const Duration(milliseconds: 1100),
        clock: const Duration(seconds: 1),
        frameDuration: _frame30,
      );

      expect(decision.action, AvSyncAction.wait);
      expect(decision.drift, const Duration(milliseconds: 100));
      expect(decision.delay, const Duration(milliseconds: 100));
      expect(sync.stats.waited, 1);
      // A wait consumes nothing, so it must not enter the drift samples.
      expect(sync.stats.driftSamples, 0);
      expect(sync.stats.averageDrift, Duration.zero);
    });

    test('waiting out a drift ends in a present, not another wait', () {
      final sync = AvSynchronizer();
      const Duration pts = Duration(milliseconds: 1100);
      var clock = const Duration(seconds: 1);

      final AvSyncDecision first =
          sync.evaluate(framePts: pts, clock: clock, frameDuration: _frame30);
      clock += first.delay;
      final AvSyncDecision second =
          sync.evaluate(framePts: pts, clock: clock, frameDuration: _frame30);

      expect(first.action, AvSyncAction.wait);
      expect(second.action, AvSyncAction.present);
      expect(second.drift, Duration.zero);
    });

    test('a clock that jumped backwards cannot produce an absurd delay', () {
      final sync = AvSynchronizer();

      final AvSyncDecision decision = sync.evaluate(
        framePts: const Duration(minutes: 12),
        clock: const Duration(seconds: 3),
        frameDuration: _frame30,
      );

      expect(decision.action, AvSyncAction.wait);
      expect(decision.drift,
          const Duration(minutes: 12) - const Duration(seconds: 3));
      expect(decision.delay, _maxWait);
    });

    test('a frozen clock keeps re-offering bounded waits and never drops', () {
      final sync = AvSynchronizer();

      for (var i = 0; i < 40; i++) {
        final AvSyncDecision decision = sync.evaluate(
          framePts: const Duration(seconds: 30),
          clock: const Duration(seconds: 20),
          frameDuration: _frame30,
        );
        expect(decision.action, AvSyncAction.wait);
        expect(decision.delay, _maxWait);
        expect(decision.drift, const Duration(seconds: 10));
      }

      expect(sync.stats.waited, 40);
      expect(sync.stats.presented, 0);
      expect(sync.stats.dropped, 0);
    });
  });

  group('AvSynchronizer late frames', () {
    test('a frame late beyond the drop threshold is dropped', () {
      final sync = AvSynchronizer();

      final AvSyncDecision decision = sync.evaluate(
        framePts: const Duration(seconds: 5),
        clock: const Duration(seconds: 5) + const Duration(milliseconds: 200),
        frameDuration: _frame30,
      );

      expect(decision.action, AvSyncAction.drop);
      expect(decision.drift, const Duration(milliseconds: -200));
      expect(decision.delay, Duration.zero);
      expect(sync.consecutiveDrops, 1);
    });

    test('late but not late enough is presented rather than skipped', () {
      final sync = AvSynchronizer();

      for (final Duration lateness in <Duration>[
        const Duration(milliseconds: 21),
        const Duration(milliseconds: 45),
        _dropAfter,
      ]) {
        final AvSyncDecision decision = sync.evaluate(
          framePts: const Duration(seconds: 5),
          clock: const Duration(seconds: 5) + lateness,
          frameDuration: _frame30,
        );
        expect(decision.action, AvSyncAction.present, reason: '$lateness');
        expect(decision.drift, -lateness);
      }

      final AvSyncDecision justPast = sync.evaluate(
        framePts: const Duration(seconds: 5),
        clock: const Duration(seconds: 5) +
            _dropAfter +
            const Duration(microseconds: 1),
        frameDuration: _frame30,
      );
      expect(justPast.action, AvSyncAction.drop);
    });

    test('the drop threshold never falls below one frame duration', () {
      final sync = AvSynchronizer();
      const Duration slowFrame = Duration(milliseconds: 500);

      expect(sync.dropThresholdFor(slowFrame), slowFrame);
      expect(sync.dropThresholdFor(_frame30), _dropAfter);
      expect(sync.dropThresholdFor(Duration.zero), _dropAfter);

      // Skipping a 2 fps frame moves video forward half a second, so a
      // 200 ms lateness must not be corrected by dropping.
      expect(
        sync
            .evaluate(
              framePts: const Duration(seconds: 8),
              clock: const Duration(milliseconds: 8200),
              frameDuration: slowFrame,
            )
            .action,
        AvSyncAction.present,
      );
      expect(
        sync
            .evaluate(
              framePts: const Duration(seconds: 8),
              clock: const Duration(milliseconds: 8600),
              frameDuration: slowFrame,
            )
            .action,
        AvSyncAction.drop,
      );
    });

    test('a zero-duration frame falls back to the configured threshold', () {
      final sync = AvSynchronizer();

      final AvSyncDecision presented = sync.evaluate(
        framePts: Duration.zero,
        clock: _dropAfter,
        frameDuration: Duration.zero,
      );
      final AvSyncDecision dropped = sync.evaluate(
        framePts: Duration.zero,
        clock: _dropAfter + const Duration(milliseconds: 1),
        frameDuration: Duration.zero,
      );
      final AvSyncDecision waited = sync.evaluate(
        framePts: const Duration(milliseconds: 100),
        clock: Duration.zero,
        frameDuration: Duration.zero,
      );

      expect(presented.action, AvSyncAction.present);
      expect(dropped.action, AvSyncAction.drop);
      expect(waited.action, AvSyncAction.wait);
      expect(waited.delay, const Duration(milliseconds: 100));
    });

    test('negative timestamps and clocks keep signed arithmetic exact', () {
      final sync = AvSynchronizer();

      expect(
        sync
            .evaluate(
              framePts: const Duration(milliseconds: -50),
              clock: const Duration(milliseconds: 100),
              frameDuration: _frame30,
            )
            .drift,
        const Duration(milliseconds: -150),
      );
      expect(
        sync
            .evaluate(
              framePts: const Duration(milliseconds: -50),
              clock: const Duration(milliseconds: -500),
              frameDuration: _frame30,
            )
            .drift,
        const Duration(milliseconds: 450),
      );
      expect(
        sync
            .evaluate(
              framePts: const Duration(milliseconds: -500),
              clock: const Duration(milliseconds: -500),
              frameDuration: _frame30,
            )
            .action,
        AvSyncAction.present,
      );
      expect(sync.stats.minDrift, const Duration(milliseconds: -150));
      expect(sync.stats.maxDrift, Duration.zero);
    });
  });

  group('AvSynchronizer drop-spiral guards', () {
    test('drops in a row are capped even while dropping keeps helping', () {
      final sync = AvSynchronizer();
      const Duration clock = Duration(seconds: 10);
      final actions = <AvSyncAction>[];

      // Video is nine seconds behind and catching up frame by frame: every
      // drop strictly improves drift, so only the hard cap can stop the run.
      for (var i = 0; i < 9; i++) {
        actions.add(
          sync
              .evaluate(
                framePts: const Duration(seconds: 1) + _frame30 * i,
                clock: clock,
                frameDuration: _frame30,
              )
              .action,
        );
      }

      expect(actions, <AvSyncAction>[
        AvSyncAction.drop,
        AvSyncAction.drop,
        AvSyncAction.present,
        AvSyncAction.drop,
        AvSyncAction.drop,
        AvSyncAction.present,
        AvSyncAction.drop,
        AvSyncAction.drop,
        AvSyncAction.present,
      ]);
      expect(sync.stats.presented, 3);
      expect(sync.stats.dropped, 6);
    });

    test('a lower cap shortens the run and zero disables dropping', () {
      final single = AvSynchronizer(maxConsecutiveDrops: 1);
      final never = AvSynchronizer(maxConsecutiveDrops: 0);
      const Duration clock = Duration(seconds: 10);
      final singleActions = <AvSyncAction>[];
      final neverActions = <AvSyncAction>[];

      for (var i = 0; i < 6; i++) {
        final Duration pts = const Duration(seconds: 1) + _frame30 * i;
        singleActions.add(
          single
              .evaluate(framePts: pts, clock: clock, frameDuration: _frame30)
              .action,
        );
        neverActions.add(
          never
              .evaluate(framePts: pts, clock: clock, frameDuration: _frame30)
              .action,
        );
      }

      expect(singleActions, <AvSyncAction>[
        AvSyncAction.drop,
        AvSyncAction.present,
        AvSyncAction.drop,
        AvSyncAction.present,
        AvSyncAction.drop,
        AvSyncAction.present,
      ]);
      expect(neverActions, everyElement(AvSyncAction.present));
      expect(never.stats.dropped, 0);
    });

    test('dropping stops as soon as the drift stops improving', () {
      final sync = AvSynchronizer();
      // The machine loses 67 ms of ground per frame: dropping cannot help.
      var clock = const Duration(milliseconds: 200);
      final actions = <AvSyncAction>[];

      for (var i = 0; i < 8; i++) {
        actions.add(
          sync
              .evaluate(
                framePts: _frame30 * i,
                clock: clock,
                frameDuration: _frame30,
              )
              .action,
        );
        clock += const Duration(milliseconds: 100);
      }

      expect(actions.first, AvSyncAction.drop);
      expect(
        actions.where((action) => action == AvSyncAction.present).length,
        greaterThanOrEqualTo(4),
      );
      expect(_longestDropRun(actions), 1);
    });

    test('minDropImprovement can demand a minimum gain per drop', () {
      final sync = AvSynchronizer(
        minDropImprovement: const Duration(milliseconds: 20),
      );
      const Duration clock = Duration(seconds: 10);

      // Each frame recovers only 10 ms, below the 20 ms the policy demands.
      final AvSyncDecision first = sync.evaluate(
        framePts: const Duration(seconds: 1),
        clock: clock,
        frameDuration: _frame30,
      );
      final AvSyncDecision second = sync.evaluate(
        framePts: const Duration(milliseconds: 1010),
        clock: clock,
        frameDuration: _frame30,
      );
      final AvSyncDecision third = sync.evaluate(
        framePts: const Duration(milliseconds: 1500),
        clock: clock,
        frameDuration: _frame30,
      );

      expect(first.action, AvSyncAction.drop);
      expect(second.action, AvSyncAction.present);
      expect(third.action, AvSyncAction.drop);
    });
  });

  group('AvSynchronizer reset', () {
    test('reset clears statistics and the drop bookkeeping', () {
      final sync = AvSynchronizer();
      sync.evaluate(
        framePts: Duration.zero,
        clock: const Duration(milliseconds: 500),
        frameDuration: _frame30,
      );
      sync.evaluate(
        framePts: const Duration(milliseconds: 900),
        clock: Duration.zero,
        frameDuration: _frame30,
      );
      expect(sync.stats.dropped, 1);
      expect(sync.stats.waited, 1);
      expect(sync.consecutiveDrops, 1);

      sync.reset();

      final AvSyncStats stats = sync.stats;
      expect(stats.presented, 0);
      expect(stats.dropped, 0);
      expect(stats.waited, 0);
      expect(stats.driftSamples, 0);
      expect(stats.averageDrift, Duration.zero);
      expect(stats.minDrift, Duration.zero);
      expect(stats.maxDrift, Duration.zero);
      expect(stats.maxAbsoluteDrift, Duration.zero);
      expect(sync.consecutiveDrops, 0);
    });

    test('after a seek the PTS jump is not read as drift', () {
      final sync = AvSynchronizer();
      // Playing near the start.
      sync.evaluate(
        framePts: _frame30,
        clock: _frame30,
        frameDuration: _frame30,
      );

      // Seek to ten minutes: both the clock and the timestamps jump together.
      sync.reset();
      const Duration target = Duration(minutes: 10);
      final AvSyncDecision first = sync.evaluate(
        framePts: target,
        clock: target,
        frameDuration: _frame30,
      );

      expect(first.action, AvSyncAction.present);
      expect(first.drift, Duration.zero);
      expect(sync.stats.driftSamples, 1);
      expect(sync.stats.maxAbsoluteDrift, Duration.zero);
    });

    test('reset makes the next late frame eligible to drop again', () {
      final sync = AvSynchronizer();
      const Duration clock = Duration(seconds: 10);

      sync.evaluate(
        framePts: const Duration(seconds: 1),
        clock: clock,
        frameDuration: _frame30,
      );
      sync.evaluate(
        framePts: const Duration(milliseconds: 1100),
        clock: clock,
        frameDuration: _frame30,
      );
      expect(sync.consecutiveDrops, 2);

      sync.reset();

      final AvSyncDecision afterReset = sync.evaluate(
        framePts: const Duration(milliseconds: 1200),
        clock: clock,
        frameDuration: _frame30,
      );
      expect(afterReset.action, AvSyncAction.drop);
      expect(sync.consecutiveDrops, 1);
    });
  });

  group('AvSyncStats', () {
    test('counters and drift extremes describe the consumed frames', () {
      final sync = AvSynchronizer();
      const Duration clock = Duration(seconds: 10);

      // +0 ms, -100 ms and -40 ms drift, plus one wait that is not sampled.
      sync.evaluate(framePts: clock, clock: clock, frameDuration: _frame30);
      sync.evaluate(
        framePts: const Duration(milliseconds: 9900),
        clock: clock,
        frameDuration: _frame30,
      );
      sync.evaluate(
        framePts: const Duration(milliseconds: 9960),
        clock: clock,
        frameDuration: _frame30,
      );
      sync.evaluate(
        framePts: const Duration(milliseconds: 10500),
        clock: clock,
        frameDuration: _frame30,
      );

      final AvSyncStats stats = sync.stats;
      expect(stats.presented, 2);
      expect(stats.dropped, 1);
      expect(stats.waited, 1);
      expect(stats.driftSamples, 3);
      expect(stats.minDrift, const Duration(milliseconds: -100));
      expect(stats.maxDrift, Duration.zero);
      expect(stats.maxAbsoluteDrift, const Duration(milliseconds: 100));
      expect(
        stats.averageDrift,
        const Duration(microseconds: (0 - 100000 - 40000) ~/ 3),
      );
      expect(stats.toString(), contains('presented: 2'));
    });

    test('decisions compare by value and describe themselves', () {
      const a = AvSyncDecision(
        action: AvSyncAction.wait,
        drift: Duration(milliseconds: 40),
        delay: Duration(milliseconds: 40),
      );
      const b = AvSyncDecision(
        action: AvSyncAction.wait,
        drift: Duration(milliseconds: 40),
        delay: Duration(milliseconds: 40),
      );
      const c = AvSyncDecision(
        action: AvSyncAction.drop,
        drift: Duration(milliseconds: -400),
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
      expect(a.isWait, isTrue);
      expect(c.isDrop, isTrue);
      expect(c.isPresent, isFalse);
      expect(a.toString(), contains('wait'));
    });
  });

  group('AvSynchronizer over a realistic sequence', () {
    test('100 frames with the clock running 2% fast stay locked', () {
      final _LoopOutcome outcome = _runPlayerLoop(
        frameCount: 100,
        clockRate: 1.02,
      );

      expect(outcome.stats.presented, 100);
      expect(outcome.stats.dropped, 0);
      expect(outcome.stats.waited, greaterThan(90));
      expect(outcome.stats.maxAbsoluteDrift, lessThanOrEqualTo(_tolerance));
      expect(outcome.maxEvaluationsPerFrame, lessThanOrEqualTo(2));
    });

    test('100 frames with the clock running 2% slow stay locked', () {
      final _LoopOutcome outcome = _runPlayerLoop(
        frameCount: 100,
        clockRate: 0.98,
      );

      expect(outcome.stats.presented, 100);
      expect(outcome.stats.dropped, 0);
      expect(outcome.stats.waited, greaterThan(90));
      expect(outcome.stats.maxAbsoluteDrift, lessThanOrEqualTo(_tolerance));
      expect(outcome.maxEvaluationsPerFrame, lessThanOrEqualTo(2));
    });

    test('a 300 ms stall is absorbed by a bounded burst of drops', () {
      final _LoopOutcome outcome = _runPlayerLoop(
        frameCount: 100,
        stalls: const <int, Duration>{50: Duration(milliseconds: 300)},
      );

      expect(outcome.stats.dropped, inInclusiveRange(1, 14));
      expect(outcome.stats.presented + outcome.stats.dropped, 100);
      expect(outcome.stats.presented, greaterThanOrEqualTo(86));
      expect(_longestDropRun(outcome.actions), lessThanOrEqualTo(2));
      expect(
          outcome.stats.minDrift, lessThan(const Duration(milliseconds: -100)));
      // Lock is regained well before the sequence ends.
      for (final Duration drift in outcome.presentedDrifts.skip(70)) {
        expect(drift.abs(), lessThanOrEqualTo(_tolerance));
      }
    });

    test('a machine too slow for the stream keeps showing frames', () {
      // 40 ms of decoding per 33.3 ms frame: the video can never catch up.
      final _LoopOutcome outcome = _runPlayerLoop(
        frameCount: 100,
        decodeCost: const Duration(milliseconds: 40),
      );

      expect(outcome.stats.dropped, greaterThan(0));
      expect(
        outcome.stats.presented,
        greaterThanOrEqualTo(33),
        reason: 'at least one frame in three must reach the screen',
      );
      expect(_longestDropRun(outcome.actions), lessThanOrEqualTo(2));
      // The guard holds just as well deep into the sequence, where drift has
      // grown without bound: the image keeps moving instead of freezing while
      // drops chase a clock they can never reach.
      expect(
        outcome.actions.sublist(80).where((a) => a == AvSyncAction.present),
        isNotEmpty,
      );
      expect(outcome.stats.waited, 0);
    });
  });
}

int _longestDropRun(List<AvSyncAction> actions) {
  var longest = 0;
  var current = 0;
  for (final AvSyncAction action in actions) {
    if (action == AvSyncAction.drop) {
      current++;
      if (current > longest) longest = current;
    } else {
      current = 0;
    }
  }
  return longest;
}

/// Result of driving [AvSynchronizer] through a simulated playback loop.
final class _LoopOutcome {
  const _LoopOutcome({
    required this.actions,
    required this.presentedDrifts,
    required this.maxEvaluationsPerFrame,
    required this.stats,
  });

  /// The terminal decision taken for each decoded frame, in order.
  final List<AvSyncAction> actions;

  /// Drift measured on each frame that was actually drawn.
  final List<Duration> presentedDrifts;

  /// Worst number of [AvSynchronizer.evaluate] calls a single frame needed:
  /// the guard against a wait that never resolves.
  final int maxEvaluationsPerFrame;

  final AvSyncStats stats;
}

/// Runs a player loop with a synthetic master clock.
///
/// Wall time advances by [decodeCost] for every decoded frame — dropped frames
/// still cost decoding — and by the delay of every wait. The master clock reads
/// `wall * clockRate`, so [clockRate] above one models audio running faster
/// than the video timeline and below one models it running slower. [stalls]
/// injects extra wall time before a given frame index, the way a garbage
/// collection or a disk hiccup would.
_LoopOutcome _runPlayerLoop({
  required int frameCount,
  double clockRate = 1.0,
  Duration decodeCost = const Duration(milliseconds: 1),
  Duration frameDuration = _frame30,
  Map<int, Duration> stalls = const <int, Duration>{},
}) {
  final sync = AvSynchronizer();
  final actions = <AvSyncAction>[];
  final presentedDrifts = <Duration>[];
  var wallMicroseconds = 0;
  var maxEvaluations = 0;

  for (var index = 0; index < frameCount; index++) {
    wallMicroseconds += decodeCost.inMicroseconds;
    wallMicroseconds += (stalls[index] ?? Duration.zero).inMicroseconds;
    final Duration framePts = frameDuration * index;

    var evaluations = 0;
    while (true) {
      evaluations++;
      if (evaluations > 64) {
        fail('frame $index never resolved: the wait loop is not converging');
      }
      final AvSyncDecision decision = sync.evaluate(
        framePts: framePts,
        clock: Duration(microseconds: (wallMicroseconds * clockRate).round()),
        frameDuration: frameDuration,
      );
      expect(decision.delay, lessThanOrEqualTo(_maxWait));
      if (decision.action == AvSyncAction.wait) {
        wallMicroseconds += decision.delay.inMicroseconds;
        continue;
      }
      actions.add(decision.action);
      if (decision.action == AvSyncAction.present) {
        presentedDrifts.add(decision.drift);
      }
      break;
    }
    if (evaluations > maxEvaluations) maxEvaluations = evaluations;
  }

  return _LoopOutcome(
    actions: actions,
    presentedDrifts: presentedDrifts,
    maxEvaluationsPerFrame: maxEvaluations,
    stats: sync.stats,
  );
}
