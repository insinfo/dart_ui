/// Records a frame timeline from a running program and says where it went.
///
/// The framework brackets its frame phases with `dart:developer`'s [Timeline]
/// (see `lib/src/diagnostics/frame_timeline.dart`). Those brackets only become
/// numbers if something turns the stream on and pulls the events out, and this
/// is that something. It spawns the program under a VM Service, records for a
/// while, and then does two things with the result:
///
///   * **prints a summary to stdout** - every phase, by total time and by self
///     time - so a regression is a diff in CI output rather than something you
///     have to open a browser to see;
///   * **writes a Chrome Trace Event file** that `ui.perfetto.dev` loads
///     directly, for when the summary says *which* phase and you need to see
///     *which frames*.
///
/// ```
/// dart run tool/frame_timeline_trace.dart --seconds 6 --out build/trace.json \
///     -- examples/video_player_demo/main.dart --autoplay --frames 400 video.mp4
/// ```
///
/// ## The transport
///
/// The recording flags can only be set over the VM Service's **WebSocket**
/// transport, for the reason `tool/vm_service_client.dart` documents at
/// length: `setVMTimelineFlags` takes a JSON array and the HTTP endpoint's
/// query string cannot carry one. That client is shared with
/// `tool/leak_suite/`.
///
/// One more name to get right: the RPC is **`getVMTimeline`**. There is no
/// `getTimeline` in the VM Service protocol - asking for it answers
/// `Unknown method "getTimeline"` on both transports.
///
/// ## What a trace is and is not
///
/// It is a **JIT** measurement, always. `Timeline` is a VM Service facility and
/// an AOT executable has no VM Service, so nothing here can be pointed at the
/// binary a user would run. `tool/startup_cost.dart` measures a 120x gap
/// between the two on start alone, and relative costs inside a frame are not
/// the same either. Every conclusion a trace suggests has to be confirmed
/// against `FrameTiming`, which is a `Stopwatch` and therefore reports from
/// both - the video player prints it under `--stats`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'vm_service_client.dart';

Future<void> main(List<String> arguments) async {
  final _Options options;
  try {
    options = _Options.parse(arguments);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln(_usage);
    exitCode = 64;
    return;
  }
  if (options.help) {
    stdout.writeln(_usage);
    return;
  }

  final _Target target = options.attachUri != null
      ? _Target.attached(options.attachUri!)
      : await _spawn(options);

  int exitStatus = 0;
  try {
    final VmServiceClient service =
        await VmServiceClient.connect(target.serviceUri);
    try {
      await service.call('setVMTimelineFlags', <String, Object?>{
        'recordedStreams': options.streams,
      });
      if (options.warmup > Duration.zero) {
        await Future<void>.delayed(options.warmup);
      }
      // After the warm-up rather than before it: the first frames of this
      // framework include mounting the root and compiling shaders, and leaving
      // them in makes every average a report about start-up.
      await service.call('clearVMTimeline');
      await _sleepOrExit(options.duration, target);
      final Map<String, Object?> timeline =
          await service.call('getVMTimeline') ?? const <String, Object?>{};
      final List<Object?> events =
          (timeline['traceEvents'] as List<Object?>?) ?? const <Object?>[];
      if (events.isEmpty) {
        stderr.writeln(
          'no timeline events came back. The program may have exited before '
          'the recording window opened, or it may be a release AOT build, '
          'where the frame brackets are compiled out on purpose.',
        );
        exitStatus = 1;
      }
      _report(events, options);
      if (options.output != null) {
        final File file = File(options.output!);
        await file.parent.create(recursive: true);
        await file.writeAsString(jsonEncode(events));
        stdout.writeln(
            '\ntrace: ${file.path}  (open at https://ui.perfetto.dev)');
      }
    } finally {
      await service.close();
    }
  } finally {
    await target.shutdown();
  }
  if (exitStatus != 0) exitCode = exitStatus;
}

const String _usage = '''
Usage: dart run tool/frame_timeline_trace.dart [options] -- <program.dart> [args]
       dart run tool/frame_timeline_trace.dart --attach <service-uri> [options]

  --seconds N     How long to record after the warm-up. Default 8.
  --warmup N      Seconds to run before recording starts. Default 25, which
                  is not padding: `dart run` front-end compiles this whole
                  package before `main`, measured at 14-26 s here (see
                  tool/startup_cost.dart). A shorter warm-up records the
                  compile and no frames at all.
  --out PATH      Write a Perfetto-loadable trace here. Default: none.
  --streams A,B   VM timeline streams to record. Default Dart,Embedder,GC.
  --top N         How many phases to list in each table. Default 15.
  --attach URI    Use a VM Service that is already running instead of
                  spawning a program.
  --quiet         Do not echo the program's own stdout.
  --help

Everything after `--` is the program to run and its arguments. A windowed
example must be given a frame budget - `--frames N` - or a `--headless` flag,
so the run ends by itself.''';

final class _Options {
  _Options({
    required this.program,
    required this.programArguments,
    required this.duration,
    required this.warmup,
    required this.output,
    required this.streams,
    required this.top,
    required this.attachUri,
    required this.quiet,
    required this.help,
  });

  final String? program;
  final List<String> programArguments;
  final Duration duration;
  final Duration warmup;
  final String? output;
  final List<String> streams;
  final int top;
  final Uri? attachUri;
  final bool quiet;
  final bool help;

  static _Options parse(List<String> arguments) {
    final int separator = arguments.indexOf('--');
    final List<String> own =
        separator < 0 ? arguments : arguments.sublist(0, separator);
    final List<String> rest =
        separator < 0 ? const <String>[] : arguments.sublist(separator + 1);

    String? value(String name) {
      final int index = own.indexOf(name);
      if (index < 0) return null;
      if (index + 1 >= own.length) {
        throw FormatException('$name needs a value');
      }
      return own[index + 1];
    }

    final String? attach = value('--attach');
    final bool help = own.contains('--help') || own.contains('-h');
    if (!help && attach == null && rest.isEmpty) {
      throw const FormatException(
        'nothing to run: pass `-- <program.dart> [args]`, or --attach <uri>',
      );
    }
    return _Options(
      program: rest.isEmpty ? null : rest.first,
      programArguments: rest.isEmpty ? const <String>[] : rest.sublist(1),
      duration: Duration(
        milliseconds:
            ((double.tryParse(value('--seconds') ?? '8') ?? 8) * 1000).round(),
      ),
      // 25 s, because the first run of this tool recorded a beautiful trace of
      // the Dart front-end compiling the framework and not one frame: `dart
      // run` spends 14-26 s in `CreateIsolateGroupAndSetupHelper` before
      // `main` on this package.
      warmup: Duration(
        milliseconds:
            ((double.tryParse(value('--warmup') ?? '25') ?? 25) * 1000).round(),
      ),
      output: value('--out'),
      streams: (value('--streams') ?? 'Dart,Embedder,GC')
          .split(',')
          .where((String s) => s.isNotEmpty)
          .toList(),
      top: int.tryParse(value('--top') ?? '15') ?? 15,
      attachUri: attach == null ? null : Uri.parse(attach),
      quiet: own.contains('--quiet'),
      help: help,
    );
  }
}

/// The program being measured, whether this tool started it or not.
final class _Target {
  _Target._(this.serviceUri, this._process);

  _Target.attached(Uri serviceUri) : this._(serviceUri, null);

  final Uri serviceUri;
  final Process? _process;

  /// Completes when a spawned program exits on its own - a frame budget
  /// running out, for instance - so a recording window does not outlive it.
  Future<void>? exited;

  Future<void> shutdown() async {
    final Process? process = _process;
    if (process == null) return;
    process.kill();
    await process.exitCode;
  }
}

Future<_Target> _spawn(_Options options) async {
  // Port 0 lets the VM pick a free one; the URI it prints is the answer, which
  // is also why the port is never hard-coded here. Two of these running at
  // once used to fight over 8181.
  final Process process = await Process.start(
    Platform.resolvedExecutable,
    <String>[
      'run',
      '--enable-vm-service=0',
      '--disable-service-auth-codes',
      '--no-serve-devtools',
      options.program!,
      ...options.programArguments,
    ],
  );
  final Completer<Uri> uri = Completer<Uri>();
  final RegExp pattern = RegExp(r'listening on (http\S+)');
  process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
    (String line) {
      final RegExpMatch? match = pattern.firstMatch(line);
      if (match != null && !uri.isCompleted) {
        uri.complete(Uri.parse(match.group(1)!));
        return;
      }
      if (!options.quiet) stdout.writeln('  | $line');
    },
    onDone: () {
      if (!uri.isCompleted) {
        uri.completeError(StateError(
          'the program exited before it printed a VM Service URI',
        ));
      }
    },
  );
  process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((String line) => stderr.writeln('  ! $line'));

  final _Target target = _Target._(await uri.future, process);
  target.exited = process.exitCode.then((int _) {});
  return target;
}

/// Waits [duration], or stops early if the program finished first.
///
/// A frame-budgeted example ends by itself, and waiting the full window after
/// it is gone would ask a dead VM Service for a timeline.
Future<void> _sleepOrExit(Duration duration, _Target target) async {
  final Future<void>? exited = target.exited;
  if (exited == null) {
    await Future<void>.delayed(duration);
    return;
  }
  await Future.any<void>(<Future<void>>[
    Future<void>.delayed(duration),
    exited,
  ]);
}

/// One phase's accumulated cost.
final class _PhaseTotals {
  int count = 0;
  int total = 0;
  int self = 0;
  int worst = 0;
}

/// One open `B` event, waiting for its `E`.
final class _OpenEvent {
  _OpenEvent(this.name, this.start);
  final String name;
  final int start;
  int childTime = 0;
}

/// Folds the raw trace events into per-phase totals and prints two tables.
///
/// Self time is the number that finds a cost: `ui.frame` is always the largest
/// total and never tells anybody anything, because it contains everything
/// else. The phase with the largest *self* time is where the milliseconds
/// actually are.
void _report(List<Object?> events, _Options options) {
  final Map<String, _PhaseTotals> phases = <String, _PhaseTotals>{};
  // Keyed by thread, because the VM interleaves events from several and a
  // single stack would pair a begin on one with an end on another.
  final Map<String, List<_OpenEvent>> stacks = <String, List<_OpenEvent>>{};
  int unmatchedEnds = 0;

  void record(String name, int duration, int childTime) {
    final _PhaseTotals totals = phases.putIfAbsent(name, _PhaseTotals.new);
    totals.count++;
    totals.total += duration;
    totals.self += duration - childTime;
    if (duration > totals.worst) totals.worst = duration;
  }

  for (final Object? raw in events) {
    if (raw is! Map<String, Object?>) continue;
    final Object? phase = raw['ph'];
    final Object? name = raw['name'];
    if (name is! String) continue;
    final String thread = '${raw['pid']}/${raw['tid']}';
    final int timestamp = (raw['ts'] as num?)?.round() ?? 0;
    switch (phase) {
      case 'B':
        (stacks[thread] ??= <_OpenEvent>[]).add(_OpenEvent(name, timestamp));
      case 'E':
        final List<_OpenEvent>? stack = stacks[thread];
        if (stack == null || stack.isEmpty) {
          unmatchedEnds++;
          continue;
        }
        final _OpenEvent open = stack.removeLast();
        final int duration = timestamp - open.start;
        record(open.name, duration, open.childTime);
        if (stack.isNotEmpty) stack.last.childTime += duration;
      case 'X':
        final int duration = (raw['dur'] as num?)?.round() ?? 0;
        record(name, duration, 0);
        final List<_OpenEvent>? stack = stacks[thread];
        if (stack != null && stack.isNotEmpty) stack.last.childTime += duration;
    }
  }

  if (phases.isEmpty) {
    stdout.writeln('no synchronous timeline events in the recording.');
    return;
  }

  final int frames = phases['ui.frame']?.count ?? 0;
  stdout.writeln('');
  stdout.writeln(
    'frames recorded: $frames'
    '${unmatchedEnds > 0 ? '   (unmatched ends: $unmatchedEnds)' : ''}',
  );

  void table(String title, List<MapEntry<String, _PhaseTotals>> rows) {
    stdout.writeln('');
    stdout.writeln(title);
    stdout.writeln(
      '  ${'phase'.padRight(24)}${'count'.padLeft(7)}'
      '${'total ms'.padLeft(11)}${'self ms'.padLeft(10)}'
      '${'self/frame'.padLeft(12)}${'worst ms'.padLeft(10)}',
    );
    for (final MapEntry<String, _PhaseTotals> row in rows.take(options.top)) {
      final _PhaseTotals t = row.value;
      final String perFrame =
          frames == 0 ? '-' : (t.self / 1000 / frames).toStringAsFixed(3);
      stdout.writeln(
        '  ${row.key.padRight(24)}'
        '${t.count.toString().padLeft(7)}'
        '${(t.total / 1000).toStringAsFixed(2).padLeft(11)}'
        '${(t.self / 1000).toStringAsFixed(2).padLeft(10)}'
        '${perFrame.padLeft(12)}'
        '${(t.worst / 1000).toStringAsFixed(2).padLeft(10)}',
      );
    }
  }

  final List<MapEntry<String, _PhaseTotals>> byTotal = phases.entries.toList()
    ..sort(
        (MapEntry<String, _PhaseTotals> a, MapEntry<String, _PhaseTotals> b) =>
            b.value.total.compareTo(a.value.total));
  final List<MapEntry<String, _PhaseTotals>> bySelf = phases.entries.toList()
    ..sort(
        (MapEntry<String, _PhaseTotals> a, MapEntry<String, _PhaseTotals> b) =>
            b.value.self.compareTo(a.value.self));

  table('by total time (a parent contains its children):', byTotal);
  table('by self time (where the milliseconds actually are):', bySelf);
}
