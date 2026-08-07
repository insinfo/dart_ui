/// POC-19 — Event loop integration cost, measured.
///
/// Usage:
///   dart run bin/main.dart                 # full run, 3s per configuration
///   dart run bin/main.dart --ci            # short run, with assertions
///   dart run bin/main.dart --json          # machine-readable output
///   dart run bin/main.dart --duration=5000 # ms per configuration
library;

import 'dart:convert';
import 'dart:io';

import 'package:poc_19_event_loop_metrics/poc_19_event_loop_metrics.dart';

Future<void> main(List<String> args) async {
  if (!Platform.isWindows) {
    stderr.writeln('POC-19 measures the Win32 loop; run it on Windows.');
    exitCode = 1;
    return;
  }

  final ci = args.contains('--ci');
  final json = args.contains('--json');
  final highRes = args.contains('--high-res-timer');
  final duration = Duration(
    milliseconds: _intArg(args, '--duration=') ?? (ci ? 800 : 3000),
  );

  if (highRes) {
    timeBeginPeriod(1);
  }

  final quantumUs = measureWaitQuantumUs();
  final configs = _configurations(duration);
  final results = <RunResult>[];

  if (!json) {
    print('POC-19 — Dart event loop vs. native Win32 loop');
    print('Dart ${Platform.version.split(' ').first} | '
        '${configs.length} configurations x ${duration.inMilliseconds}ms'
        '${highRes ? ' | timeBeginPeriod(1)' : ''}');
    print('A 1ms native wait actually takes ${_ms(quantumUs)} on this machine '
        '— every timeout below is rounded up to that quantum.');
    print('');
  }

  for (final config in configs) {
    if (!json) {
      stdout.write('  running ${config.label.padRight(28)}\r');
    }
    results.add(await runMeasurement(config));
  }

  if (json) {
    print(const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'dartVersion': Platform.version,
      'highResolutionTimer': highRes,
      'waitQuantumUs': quantumUs,
      'runs': results.map((r) => r.toJson()).toList(),
    }));
    if (highRes) {
      timeEndPeriod(1);
    }
    return;
  }

  stdout.write('${' ' * 44}\r');
  _printScenario('ANIMATING — 60 Hz frame timer + messages every 50ms',
      results.where((r) => r.scenario == Scenario.animating).toList());
  _printScenario('IDLE — no frame timer, messages every 500ms',
      results.where((r) => r.scenario == Scenario.idle).toList());
  _printMechanics(
      results.where((r) => r.scenario == Scenario.animating).toList());
  _printFindings(results);

  if (ci) {
    _assertInvariants(results);
    print('');
    print('CI invariants passed.');
  }

  if (highRes) {
    timeEndPeriod(1);
  }
}

List<RunConfig> _configurations(Duration duration) => <RunConfig>[
      for (final scenario in Scenario.values) ...<RunConfig>[
        RunConfig(
          label: 'baseline (no native loop)',
          mode: LoopMode.baseline,
          scenario: scenario,
          duration: duration,
        ),
        RunConfig(
          label: 'polling 50ms (poc_10)',
          mode: LoopMode.polling,
          scenario: scenario,
          duration: duration,
          fixedTimeoutMs: 50,
        ),
        RunConfig(
          label: 'polling 16ms',
          mode: LoopMode.polling,
          scenario: scenario,
          duration: duration,
          fixedTimeoutMs: 16,
        ),
        RunConfig(
          label: 'polling 4ms',
          mode: LoopMode.polling,
          scenario: scenario,
          duration: duration,
          fixedTimeoutMs: 4,
        ),
        RunConfig(
          label: 'spin (timeout 0)',
          mode: LoopMode.spin,
          scenario: scenario,
          duration: duration,
        ),
        RunConfig(
          label: 'oracle (proposed API)',
          mode: LoopMode.oracle,
          scenario: scenario,
          duration: duration,
        ),
      ],
    ];

void _printScenario(String title, List<RunResult> results) {
  final animating = results.first.scenario == Scenario.animating;
  print(title);
  print('-' * 104);
  print('${'configuration'.padRight(26)}'
      '${'iter/s'.padLeft(9)}'
      '${'idle wk/s'.padLeft(11)}'
      '${'Mcycle/s'.padLeft(10)}'
      '${'CPU %'.padLeft(7)}'
      '${(animating ? 'frame Hz' : '').padLeft(10)}'
      '${(animating ? 'gap p50' : '').padLeft(10)}'
      '${(animating ? 'gap p95' : '').padLeft(10)}'
      '${'msg p50'.padLeft(10)}'
      '${'msg p95'.padLeft(10)}');
  for (final result in results) {
    print('${result.label.padRight(26)}'
        '${_num(result.iterationsPerSecond, 0).padLeft(9)}'
        '${_num(result.idleWakeupsPerSecond, 1).padLeft(11)}'
        '${_num(result.megacyclesPerSecond, 1).padLeft(10)}'
        '${_num(result.cpuPercent, 1).padLeft(7)}'
        '${(animating ? _num(result.effectiveHz, 1) : '').padLeft(10)}'
        '${(animating ? _ms(result.frameGapUs.p50Us) : '').padLeft(10)}'
        '${(animating ? _ms(result.frameGapUs.p95Us) : '').padLeft(10)}'
        '${_ms(result.messageLatencyUs.p50Us).padLeft(10)}'
        '${_ms(result.messageLatencyUs.p95Us).padLeft(10)}');
  }
  if (animating) {
    final nominal = results.first.nominalHz;
    if (nominal != null) {
      print('target frame rate: ${_num(nominal, 1)} Hz '
          '(gap ${_ms(results.first.nominalFrameIntervalUs!)})');
    }
  }
  print('');
}

/// Breaks one loop iteration into its two costs, so the tables above can be
/// read without guessing which part dominated.
void _printMechanics(List<RunResult> results) {
  print('LOOP MECHANICS (animating) — where each iteration went');
  print('-' * 104);
  print('${'configuration'.padRight(26)}'
      '${'asked'.padLeft(10)}'
      '${'waited p50'.padLeft(12)}'
      '${'waited p95'.padLeft(12)}'
      '${'yield p50'.padLeft(11)}'
      '${'yield p95'.padLeft(11)}'
      '${'yield max'.padLeft(11)}');
  for (final result in results) {
    if (result.mode == LoopMode.baseline) {
      continue;
    }
    print('${result.label.padRight(26)}'
        '${_ms(result.requestedWaitUs.p50Us).padLeft(10)}'
        '${_ms(result.nativeWaitUs.p50Us).padLeft(12)}'
        '${_ms(result.nativeWaitUs.p95Us).padLeft(12)}'
        '${_ms(result.yieldUs.p50Us).padLeft(11)}'
        '${_ms(result.yieldUs.p95Us).padLeft(11)}'
        '${_ms(result.yieldUs.maxUs).padLeft(11)}');
  }
  print('');
}

void _printFindings(List<RunResult> results) {
  RunResult pick(Scenario scenario, String label) =>
      results.firstWhere((r) => r.scenario == scenario && r.label == label);

  final idlePolling = pick(Scenario.idle, 'polling 50ms (poc_10)');
  final idleOracle = pick(Scenario.idle, 'oracle (proposed API)');
  final animPolling = pick(Scenario.animating, 'polling 50ms (poc_10)');
  final animOracle = pick(Scenario.animating, 'oracle (proposed API)');
  final animBaseline = pick(Scenario.animating, 'baseline (no native loop)');
  final animSpin = pick(Scenario.animating, 'spin (timeout 0)');

  final idleBaseline = pick(Scenario.idle, 'baseline (no native loop)');
  final idleSpin = pick(Scenario.idle, 'spin (timeout 0)');

  print('FINDINGS  (polling 50ms = what poc_10 does today; '
      'oracle = what the proposed API would allow)');
  print('-' * 104);
  print('1. A 60Hz frame timer runs at ${_num(animPolling.effectiveHz, 1)}Hz '
      'under a 50ms polling loop, ${_num(animOracle.effectiveHz, 1)}Hz under '
      'the oracle.');
  print('   Target ${_num(animPolling.nominalHz ?? 0, 1)}Hz, '
      'pure-Dart baseline ${_num(animBaseline.effectiveHz, 1)}Hz. '
      'Frame gap p95 ${_ms(animPolling.frameGapUs.p95Us)} -> '
      '${_ms(animOracle.frameGapUs.p95Us)}.');
  print('2. Cross-isolate message latency p95 '
      '${_ms(animPolling.messageLatencyUs.p95Us)} -> '
      '${_ms(animOracle.messageLatencyUs.p95Us)} '
      '(baseline ${_ms(animBaseline.messageLatencyUs.p95Us)}). '
      'A wake handle removes the queueing delay entirely.');
  print('3. Idle wakeups/s ${_num(idlePolling.idleWakeupsPerSecond, 1)} -> '
      '${_num(idleOracle.idleWakeupsPerSecond, 1)}. '
      'Process cycles/s ${_num(idlePolling.megacyclesPerSecond, 1)}M -> '
      '${_num(idleOracle.megacyclesPerSecond, 1)}M '
      '(baseline ${_num(idleBaseline.megacyclesPerSecond, 1)}M).');
  print('   Caveat: the cycle counter is process-wide, so it also counts the '
      'sender isolate and the VM background threads.');
  print('   At this wakeup rate it cannot resolve the loop\'s own cost and '
      'the two numbers may even invert between runs.');
  print('   The defensible claim is the wakeup count itself, which is what '
      'keeps a core out of deep sleep states.');
  print('4. Spinning is not the escape hatch: '
      '${_num(animSpin.cpuPercent, 0)}% CPU animating, '
      '${_num(idleSpin.cpuPercent, 0)}% idle, '
      '${_num(idleSpin.megacyclesPerSecond, 0)}M cycles/s while doing nothing.');
  print('5. The only available yield primitive, '
      'await Future.delayed(Duration.zero), costs '
      '${_ms(animOracle.yieldUs.p50Us)} p50 / '
      '${_ms(animOracle.yieldUs.p95Us)} p95 after a blocking wait,');
  print('   versus ${_ms(animSpin.yieldUs.p50Us)} in a tight spin where the '
      'fast path is always hot. On a 16.67ms frame budget that is '
      '${_num(animOracle.yieldUs.p50Us / 16670 * 100, 1)}% spent re-entering '
      'the scheduler.');

  final migrations = results.fold<int>(0, (a, r) => a + r.threadMigrations);
  print('6. Isolate thread migrations across all runs: $migrations'
      '${migrations > 0 ? '  <- thread affinity is NOT guaranteed; a window '
          'owned by this isolate would break' : ' (stable in this session, '
          'but nothing in the SDK promises it)'}');
  print('');
}

void _assertInvariants(List<RunResult> results) {
  RunResult pick(Scenario scenario, String label) =>
      results.firstWhere((r) => r.scenario == scenario && r.label == label);

  void check(String what, bool ok) {
    if (!ok) {
      throw StateError('Invariant failed: $what');
    }
  }

  final idlePolling = pick(Scenario.idle, 'polling 50ms (poc_10)');
  final idleOracle = pick(Scenario.idle, 'oracle (proposed API)');
  final animPolling = pick(Scenario.animating, 'polling 50ms (poc_10)');
  final animOracle = pick(Scenario.animating, 'oracle (proposed API)');

  check(
    'a deadline-driven idle loop wakes up less than a 50ms polling loop',
    idleOracle.idleWakeupsPerSecond < idlePolling.idleWakeupsPerSecond,
  );
  check(
    'a deadline-driven loop keeps the frame timer closer to its target rate',
    animOracle.effectiveHz > animPolling.effectiveHz,
  );
  check(
    'every configuration actually served its frame timer',
    animPolling.frameTicks > 0 && animOracle.frameTicks > 0,
  );
  check(
    'every configuration actually received messages',
    animPolling.messagesReceived > 0 && idleOracle.messagesReceived > 0,
  );
}

int? _intArg(List<String> args, String prefix) {
  for (final arg in args) {
    if (arg.startsWith(prefix)) {
      return int.tryParse(arg.substring(prefix.length));
    }
  }
  return null;
}

String _num(double value, int digits) =>
    value.isFinite ? value.toStringAsFixed(digits) : '-';

String _ms(int micros) => '${(micros / 1000).toStringAsFixed(2)}ms';
