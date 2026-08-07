/// POC-19 probe — isolates the two costs inside one loop iteration.
///
/// Separates "how long did the native wait actually block" from "how long did
/// `await Future.delayed(Duration.zero)` take", because the main benchmark
/// only reports their sum and the two behave very differently.
///
/// `--with-dart-timer` keeps a 60Hz `Timer.periodic` alive during the probe.
/// That is the one difference between this probe and the main benchmark, and
/// it turns out to change how long a short native wait actually blocks.
///
/// Usage:
///   dart run bin/yield_probe.dart
///   dart run bin/yield_probe.dart --high-res-timer
///   dart run bin/yield_probe.dart --high-res-timer --with-dart-timer
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:poc_19_event_loop_metrics/poc_19_event_loop_metrics.dart';
import 'package:poc_19_event_loop_metrics/src/win32_bindings.dart';

Future<void> main(List<String> args) async {
  if (!Platform.isWindows) {
    stderr.writeln('POC-19 measures the Win32 loop; run it on Windows.');
    exitCode = 1;
    return;
  }

  final highRes = args.contains('--high-res-timer');
  final withDartTimer = args.contains('--with-dart-timer');
  if (highRes) {
    timeBeginPeriod(1);
  }

  var ticks = 0;
  final dartTimer = withDartTimer
      ? Timer.periodic(const Duration(microseconds: 16667), (_) => ticks++)
      : null;

  print('POC-19 yield probe${highRes ? ' | timeBeginPeriod(1)' : ''}'
      '${withDartTimer ? ' | 60Hz Timer.periodic active' : ''}');
  print('a 1ms native wait measures ${measureWaitQuantumUs()}us');
  print('');
  print('${'requested'.padRight(12)}'
      '${'wait p50'.padLeft(11)}'
      '${'wait p95'.padLeft(11)}'
      '${'yield p50'.padLeft(11)}'
      '${'yield p95'.padLeft(11)}'
      '${'yield max'.padLeft(11)}');

  for (final waitMs in <int>[0, 1, 4, 16, 50]) {
    final waitCost = <int>[];
    final yieldCost = <int>[];
    for (var i = 0; i < 80; i++) {
      final beforeWait = Clock.nowUs();
      msgWaitForMultipleObjectsEx(
        0,
        nullptr,
        waitMs,
        qsAllInput,
        mwmoInputAvailable,
      );
      final afterWait = Clock.nowUs();
      await Future<void>.delayed(Duration.zero);
      final afterYield = Clock.nowUs();
      waitCost.add(afterWait - beforeWait);
      yieldCost.add(afterYield - afterWait);
    }
    final wait = Stats.fromMicros(waitCost);
    final yielded = Stats.fromMicros(yieldCost);
    print('${'${waitMs}ms'.padRight(12)}'
        '${_us(wait.p50Us).padLeft(11)}'
        '${_us(wait.p95Us).padLeft(11)}'
        '${_us(yielded.p50Us).padLeft(11)}'
        '${_us(yielded.p95Us).padLeft(11)}'
        '${_us(yielded.maxUs).padLeft(11)}');
  }

  dartTimer?.cancel();
  if (withDartTimer) {
    print('');
    print('Dart timer fired $ticks times during the probe.');
  }
  if (highRes) {
    timeEndPeriod(1);
  }
}

String _us(int micros) =>
    micros >= 1000 ? '${(micros / 1000).toStringAsFixed(2)}ms' : '${micros}us';
