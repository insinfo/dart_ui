@TestOn('windows')
library;

import 'package:poc_19_event_loop_metrics/poc_19_event_loop_metrics.dart';
import 'package:test/test.dart';

/// Short enough to keep the suite fast, long enough for the 50ms polling loop
/// to complete several iterations.
const Duration _runFor = Duration(milliseconds: 900);

RunConfig _config(LoopMode mode, Scenario scenario, {int? timeoutMs}) =>
    RunConfig(
      label: '$mode/$scenario',
      mode: mode,
      scenario: scenario,
      duration: _runFor,
      fixedTimeoutMs: timeoutMs,
    );

void main() {
  test('the shared clock is monotonic and calibrated', () {
    final first = Clock.nowUs();
    final second = Clock.nowUs();
    expect(second, greaterThanOrEqualTo(first));
    // Two back-to-back QPC reads must not be seconds apart.
    expect(second - first, lessThan(1000000));
  });

  test('a 1ms native wait is reported at the real system quantum', () {
    final quantumUs = measureWaitQuantumUs(samples: 5);
    // Windows rounds up to the timer resolution; anything under 1ms would
    // mean the measurement is not actually waiting.
    expect(quantumUs, greaterThanOrEqualTo(900));
    expect(quantumUs, lessThan(50000));
  });

  test('the polling loop keeps Dart timers and messages alive', () async {
    final result = await runMeasurement(
      _config(LoopMode.polling, Scenario.animating, timeoutMs: 16),
    );
    expect(result.iterations, greaterThan(0));
    expect(result.frameTicks, greaterThan(0),
        reason: 'the frame timer must still fire under a native loop');
    expect(result.messagesReceived, greaterThan(0),
        reason: 'cross-isolate messages must still arrive');
    expect(result.wallMs, greaterThan(_runFor.inMilliseconds * 0.5));
  });

  test('a deadline-driven loop beats fixed polling on frame rate', () async {
    final polling = await runMeasurement(
      _config(LoopMode.polling, Scenario.animating, timeoutMs: 50),
    );
    final oracle =
        await runMeasurement(_config(LoopMode.oracle, Scenario.animating));

    expect(oracle.effectiveHz, greaterThan(polling.effectiveHz),
        reason: 'deriving the timeout from the next deadline is the point');
    expect(
        oracle.messageLatencyUs.p95Us, lessThan(polling.messageLatencyUs.p95Us),
        reason: 'the wake handle should remove the queueing delay');
  });

  test('a deadline-driven loop idles with fewer wakeups', () async {
    final polling = await runMeasurement(
      _config(LoopMode.polling, Scenario.idle, timeoutMs: 50),
    );
    final oracle =
        await runMeasurement(_config(LoopMode.oracle, Scenario.idle));

    expect(polling.idleWakeups, greaterThan(0),
        reason: 'a fixed timeout must wake up with nothing to do');
    expect(oracle.idleWakeups, lessThan(polling.idleWakeups));
  });

  test('baseline runs no native loop but still serves the frame timer',
      () async {
    final result =
        await runMeasurement(_config(LoopMode.baseline, Scenario.animating));
    expect(result.iterations, 0);
    expect(result.frameTicks, greaterThan(0));
    expect(result.nominalHz, closeTo(60, 0.1));
  });

  test('results serialise to JSON', () async {
    final result =
        await runMeasurement(_config(LoopMode.baseline, Scenario.idle));
    final json = result.toJson();
    expect(json['mode'], 'baseline');
    expect(json['scenario'], 'idle');
    expect(json['messageLatencyUs'], isA<Map<String, Object?>>());
  });
}
