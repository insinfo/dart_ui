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
  // The arrival timestamp is taken INSIDE the stdout listener, and the waiting
  // is done on a completer rather than a polling loop. Polling would put its
  // own scheduling granularity straight into the host -> Dart leg, which is
  // precisely the number this benchmark exists to produce.
  Completer<({String line, int ticks})>? pending;
  final drained = host.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
    final ticks = machNow();
    lines.add(line);
    final waiter = pending;
    if (line.startsWith('INPUT=') && waiter != null && !waiter.isCompleted) {
      waiter.complete((line: line, ticks: ticks));
    }
  }).asFuture<void>();
  unawaited(host.stderr.transform(utf8.decoder).forEach(stderr.write));

  while (!lines.contains('PROTOCOL=3')) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  print('MACH_TIMEBASE=$machTimebaseDescription');

  final input = SyntheticInput();
  final samples = <_Sample>[];
  var delivered = 0;
  var lost = 0;

  for (var i = 0; i < events; i++) {
    final waiter = Completer<({String line, int ticks})>();
    pending = waiter;
    // Cycle the key code so a duplicated line is visible rather than silently
    // counted twice.
    final posted = input.postKeyStamped(host.pid, keyCode: i % 50);
    if (!posted.posted) {
      lost++;
      continue;
    }
    final arrival = await waiter.future.timeout(const Duration(seconds: 5),
        onTimeout: () => (line: '', ticks: 0));
    pending = null;
    if (arrival.line.isEmpty) {
      lost++;
      continue;
    }
    final fields = arrival.line.substring('INPUT='.length).split(':');
    final hostTicks = fields.length < 5 ? null : int.tryParse(fields[4]);
    if (hostTicks == null) {
      lost++;
      continue;
    }
    delivered++;
    samples.add(_Sample(
      machTicksToMicroseconds(hostTicks - posted.ticks),
      machTicksToMicroseconds(arrival.ticks - hostTicks),
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
