import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:poc_20_macos_three_backends/poc_20_macos_three_backends.dart';

// ---------------------------------------------------------------------------
// The benchmark measured how long a present COSTS. This measures something
// different and more important: whether the compositor keeps up, and what
// happens to a frame that is still being written when it does not.
//
// A single shared surface has a tear hazard that a per-frame timing number
// cannot show. Dart writes into the same pages the WindowServer is scanning
// out, so a frame can be composited half-updated. The cost of a present being
// 80us says nothing about that - the write and the scan-out are simply not
// synchronised.
//
// Three things get measured here:
//
//   1. Sustained rate. Present as fast as the host will acknowledge and see
//      what the round trip settles at. Not a frame budget - just the ceiling.
//   2. Paced rate. Present on a 60Hz schedule and check the host keeps up
//      without the queue growing, which is the case a real application is in.
//   3. Tearing exposure. Write a full-surface colour, present, and immediately
//      write a DIFFERENT colour without presenting. With one buffer the
//      compositor may scan out the second colour for a frame nobody asked it
//      to show. This does not assert a pixel - proving a tear from inside the
//      process is not possible - it reports the size of the window in which
//      one can happen.
//
// The output is the evidence for whether double buffering is needed, rather
// than an assumption that it is.
// ---------------------------------------------------------------------------

class _Host {
  _Host(this.process);

  final Process process;
  final List<String> lines = <String>[];
  int _cursor = 0;

  static Future<_Host> start(String binary) async {
    final process = await Process.start(binary, const ['--command-stdin']);
    final host = _Host(process);
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(host.lines.add);
    unawaited(process.stderr.transform(utf8.decoder).forEach(stderr.write));
    return host;
  }

  Future<void> send(String command) async {
    process.stdin.writeln(command);
    await process.stdin.flush();
  }

  Future<String?> waitFor(
    bool Function(String line) match, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      while (_cursor < lines.length) {
        final line = lines[_cursor++];
        if (match(line)) return line;
      }
      await Future<void>.delayed(const Duration(microseconds: 200));
    }
    return null;
  }
}

int _percentile(List<int> values, int percent) {
  if (values.isEmpty) return 0;
  final sorted = List<int>.from(values)..sort();
  return sorted[((sorted.length - 1) * percent / 100).round()];
}

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) {
    stderr.writeln('usage: vsync_probe <host-binary> [frames]');
    exitCode = 64;
    return;
  }
  final frames = arguments.length > 1 ? int.parse(arguments[1]) : 120;

  final surface = IOSurfaceFrame.create(width: 1920, height: 1080);
  final host = await _Host.start(arguments.first);
  if (await host.waitFor((l) => l.startsWith('WINDOW_ID=')) == null) {
    stderr.writeln('host did not start');
    exitCode = 1;
    return;
  }
  await host.send('SURFACE ${surface.id}');
  if (await host.waitFor((l) => l.startsWith('SURFACE_OK')) == null) {
    stderr.writeln('host could not attach the surface');
    exitCode = 1;
    return;
  }

  var sequence = 0;

  Future<int?> presentOnce() async {
    sequence++;
    final watch = Stopwatch()..start();
    await host.send('PRESENT $sequence');
    final ok = await host.waitFor((l) => l.startsWith('PRESENT_OK $sequence '));
    watch.stop();
    return ok == null ? null : watch.elapsedMicroseconds;
  }

  // --- 1. sustained ----------------------------------------------------------
  final sustained = <int>[];
  final sustainedWatch = Stopwatch()..start();
  for (var i = 0; i < frames; i++) {
    surface.fillBgra(0x20 + (i % 200), 0x80, 0x40);
    final elapsed = await presentOnce();
    if (elapsed == null) break;
    sustained.add(elapsed);
  }
  sustainedWatch.stop();

  final sustainedFps = sustained.isEmpty
      ? 0.0
      : sustained.length * 1000000 / sustainedWatch.elapsedMicroseconds;
  print('VSYNC_SUSTAINED_FRAMES=${sustained.length}');
  print('VSYNC_SUSTAINED_MEDIAN_US=${_percentile(sustained, 50)}');
  print('VSYNC_SUSTAINED_P95_US=${_percentile(sustained, 95)}');
  print('VSYNC_SUSTAINED_FPS=${sustainedFps.toStringAsFixed(1)}');

  // --- 2. paced at 60Hz ------------------------------------------------------
  //
  // The question is not how fast a present can go, it is whether a frame's
  // work still fits when one arrives every 16.67ms. A late frame here means
  // the budget is already spent before any application code runs.
  const budget = Duration(microseconds: 16667);
  final pacedPresent = <int>[];
  final pacedFill = <int>[];
  final pacedTotal = <int>[];
  var late = 0;
  for (var i = 0; i < frames; i++) {
    final frameStart = Stopwatch()..start();
    final fillWatch = Stopwatch()..start();
    surface.fillBgra(0x40, 0x20 + (i % 200), 0x80);
    fillWatch.stop();
    final elapsed = await presentOnce();
    if (elapsed == null) break;
    pacedFill.add(fillWatch.elapsedMicroseconds);
    pacedPresent.add(elapsed);
    pacedTotal.add(frameStart.elapsedMicroseconds);
    final remaining = budget - frameStart.elapsed;
    if (remaining.isNegative) {
      late++;
    } else {
      await Future<void>.delayed(remaining);
    }
  }
  print('VSYNC_PACED_FRAMES=${pacedPresent.length}');
  // Reported separately on purpose. The present alone is a small fraction of
  // the budget, and quoting only that would make the frame look far cheaper
  // than it is: filling the surface costs an order of magnitude more, and it
  // is the part that has to fit.
  print('VSYNC_PACED_FILL_MEDIAN_US=${_percentile(pacedFill, 50)}');
  print('VSYNC_PACED_PRESENT_MEDIAN_US=${_percentile(pacedPresent, 50)}');
  print('VSYNC_PACED_TOTAL_MEDIAN_US=${_percentile(pacedTotal, 50)}');
  print('VSYNC_PACED_LATE=$late');
  print('VSYNC_PACED_BUDGET_SHARE='
      '${(_percentile(pacedTotal, 50) * 100 / budget.inMicroseconds).toStringAsFixed(2)}%');

  // --- 3. the tear window ----------------------------------------------------
  //
  // How long after a present does the process keep the right to scribble on
  // pixels the compositor may still be reading? With one buffer, all of it.
  final tearWindow = <int>[];
  for (var i = 0; i < 30; i++) {
    surface.fillBgra(0x00, 0x00, 0xFF);
    await presentOnce();
    final watch = Stopwatch()..start();
    // A full-surface overwrite with no present: exactly the write that can
    // land mid-scan-out.
    surface.fillBgra(0xFF, 0xFF, 0x00);
    watch.stop();
    tearWindow.add(watch.elapsedMicroseconds);
  }
  print('VSYNC_UNSYNCED_WRITE_MEDIAN_US=${_percentile(tearWindow, 50)}');
  print('VSYNC_TEAR_HAZARD=${tearWindow.isEmpty ? "unknown" : "present"}');

  await host.send('CLOSE');
  await host.waitFor((l) => l == 'CLOSE_OK');
  await host.process.exitCode.timeout(const Duration(seconds: 10),
      onTimeout: () {
    host.process.kill();
    return -1;
  });
  surface.dispose();

  // Nothing here is a pass/fail gate: this probe exists to size a problem, not
  // to guard one. It fails only if the host stopped answering, because then
  // the numbers describe nothing.
  if (sustained.isEmpty || pacedTotal.isEmpty) {
    stderr.writeln('the host stopped acknowledging presents');
    exitCode = 1;
  }
}
