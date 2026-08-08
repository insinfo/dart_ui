import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:poc_20_macos_three_backends/poc_20_macos_three_backends.dart';

// ---------------------------------------------------------------------------
// The other half of the process-boundary question.
//
// The frame benchmark showed the boundary costs ~0.2% of a frame going OUT.
// Input goes the other way, and the decision to reopen the embedder question
// was written down with "if input needs sub-millisecond end to end" as one of
// the triggers - so that number has to exist.
//
// The trip is split into two legs the same event can be timed across, because
// mach_absolute_time is system-wide:
//
//   inject -> host    SLEventPostToPid, the WindowServer, AppKit's queue.
//                     An embedder would still pay all of this.
//   host -> Dart      the pipe and the scheduling around it.
//                     This is the ONLY part an embedder would remove.
//
// A single end-to-end number cannot tell those apart, and the two are not
// remotely the same size.
// ---------------------------------------------------------------------------

class _Sample {
  const _Sample(this.toHostUs, this.toDartUs);

  final double toHostUs;
  final double toDartUs;

  double get totalUs => toHostUs + toDartUs;
}

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) {
    stderr.writeln('usage: input_latency_benchmark <host-binary> [events]');
    exitCode = 64;
    return;
  }
  final hostBinary = arguments.first;
  final events = arguments.length > 1 ? int.parse(arguments[1]) : 60;

  final host = await Process.start(hostBinary, const ['--command-stdin']);
  final lines = <String>[];
  final drained = host.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(lines.add)
      .asFuture<void>();
  unawaited(host.stderr.transform(utf8.decoder).forEach(stderr.write));

  Future<bool> waitForCount(int count,
      {Duration timeout = const Duration(seconds: 5)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (lines.where((l) => l.startsWith('INPUT=')).length >= count) {
        return true;
      }
      await Future<void>.delayed(const Duration(microseconds: 200));
    }
    return false;
  }

  while (!lines.contains('PROTOCOL=3')) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  print('MACH_TIMEBASE=$machTimebaseDescription');

  final input = SyntheticInput();
  final samples = <_Sample>[];
  var delivered = 0;
  var lost = 0;

  for (var i = 0; i < events; i++) {
    final before = lines.where((l) => l.startsWith('INPUT=')).length;
    // Cycle the key code so a duplicated line is visible rather than silently
    // counted twice.
    final posted = input.postKeyStamped(host.pid, keyCode: i % 50);
    if (!posted.posted) {
      lost++;
      continue;
    }
    if (!await waitForCount(before + 1)) {
      lost++;
      continue;
    }
    final arrivedAt = machNow();
    final line = lines.where((l) => l.startsWith('INPUT=')).elementAt(before);
    final fields = line.substring('INPUT='.length).split(':');
    if (fields.length < 5) {
      lost++;
      continue;
    }
    final hostTicks = int.tryParse(fields[4]);
    if (hostTicks == null) {
      lost++;
      continue;
    }
    delivered++;
    samples.add(_Sample(
      machTicksToMicroseconds(hostTicks - posted.ticks),
      machTicksToMicroseconds(arrivedAt - hostTicks),
    ));
    // Let the queue settle so consecutive events are not coalesced.
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }

  host.stdin.writeln('CLOSE');
  await host.stdin.flush();
  await host.stdin.close();
  await host.exitCode.timeout(const Duration(seconds: 10), onTimeout: () {
    host.kill(ProcessSignal.sigkill);
    return -1;
  });
  await drained;

  print('INPUT_EVENTS_DELIVERED=$delivered INPUT_EVENTS_LOST=$lost');
  if (samples.isEmpty) {
    print('INPUT_LATENCY=none');
    exitCode = 1;
    return;
  }

  void report(String name, List<double> values) {
    final sorted = List<double>.from(values)..sort();
    String at(int percent) =>
        sorted[((sorted.length - 1) * percent / 100).round()]
            .toStringAsFixed(1);
    print('INPUT_LATENCY_$name min_us=${sorted.first.toStringAsFixed(1)} '
        'median_us=${at(50)} p95_us=${at(95)}');
  }

  report('INJECT_TO_HOST', samples.map((s) => s.toHostUs).toList());
  report('HOST_TO_DART', samples.map((s) => s.toDartUs).toList());
  report('END_TO_END', samples.map((s) => s.totalUs).toList());

  final medianBoundary = _median(samples.map((s) => s.toDartUs).toList());
  final medianTotal = _median(samples.map((s) => s.totalUs).toList());
  print('INPUT_BOUNDARY_SHARE='
      '${(medianBoundary * 100 / medianTotal).toStringAsFixed(1)}%');
  // 60 Hz gives 16667 us per frame; anything well under that is not what a
  // user would notice.
  print('INPUT_END_TO_END_FRAME_SHARE='
      '${(medianTotal * 100 / 16667).toStringAsFixed(2)}%');
  print(medianTotal < 1000
      ? 'INPUT_SUB_MILLISECOND=1'
      : 'INPUT_SUB_MILLISECOND=0');
}

double _median(List<double> values) {
  final sorted = List<double>.from(values)..sort();
  return sorted[(sorted.length - 1) ~/ 2];
}
