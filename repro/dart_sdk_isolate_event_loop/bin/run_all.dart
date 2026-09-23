/// Runs every probe case in its own subprocess under a watchdog and prints one
/// summary line per case.
///
/// ```
/// dart run bin/run_all.dart [--timeout=15]
/// ```
///
/// A probe that deadlocks cannot report on itself, so each case gets a fresh
/// VM: a case still alive after the timeout is killed and reported as `HANG`,
/// a case killed by a signal as `CRASH`. The runner itself never hangs, which
/// is what lets CI run the deadlock cases at all.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

const List<(String, List<String>)> cases = <(String, List<String>)>[
  ('on_event', <String>['bin/on_event_probe.dart']),
  ('nested_callback', <String>['bin/nested_callback_probe.dart']),
  (
    'group_bound trivial/async',
    <String>['bin/group_bound_trivial_probe.dart', '--wait=async'],
  ),
  (
    'group_bound trivial/blocking',
    <String>['bin/group_bound_trivial_probe.dart', '--wait=blocking'],
  ),
  (
    'group_bound create/async',
    <String>['bin/group_bound_create_probe.dart', '--wait=async'],
  ),
  (
    'group_bound create/blocking',
    <String>['bin/group_bound_create_probe.dart', '--wait=blocking'],
  ),
  (
    'group_bound create+shutdown',
    <String>['bin/group_bound_create_probe.dart', '--wait=async', '--shutdown'],
  ),
];

Future<void> main(List<String> args) async {
  int timeout = 15;
  final List<String> vmFlags = <String>[];
  for (final String arg in args) {
    if (arg.startsWith('--timeout=')) {
      timeout = int.parse(arg.substring(10));
    } else if (arg.startsWith('--vm-flag=')) {
      vmFlags.add(arg.substring(10));
    }
  }
  final Directory root = File.fromUri(Platform.script).parent.parent;
  // Output is streamed as it arrives but also kept, so the verdict can be read
  // from it after the case ends.
  stdout
    ..writeln('SDK: ${Platform.version}')
    ..writeln(
      'OS: ${Platform.operatingSystem} '
      '${Platform.operatingSystemVersion}',
    )
    ..writeln('watchdog: $timeout s per case')
    ..writeln('VM flags: ${vmFlags.isEmpty ? '(none)' : vmFlags.join(' ')}')
    ..writeln();

  final List<String> summary = <String>[];
  for (final (String name, List<String> command) in cases) {
    final List<String> argv = <String>[...vmFlags, 'run', ...command];
    stdout.writeln('===== $name: dart ${argv.join(' ')}');
    final Stopwatch clock = Stopwatch()..start();
    final Process process = await Process.start(
      Platform.resolvedExecutable,
      argv,
      workingDirectory: root.path,
    );
    final StringBuffer output = StringBuffer();
    final Future<void> out = process.stdout.transform(utf8.decoder).forEach((
      String s,
    ) {
      output.write(s);
      stdout.write(s);
    });
    final Future<void> err = process.stderr.transform(utf8.decoder).forEach((
      String s,
    ) {
      output.write(s);
      stderr.write(s);
    });

    final int? code = await process.exitCode
        .then<int?>((int c) => c)
        .timeout(Duration(seconds: timeout), onTimeout: () => null);
    String verdict;
    RegExpMatch? result() =>
        RegExp(r'^RESULT=(.*)$', multiLine: true).firstMatch('$output');
    if (code == null) {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      // A probe that printed its result and then never exited hung in VM
      // shutdown, which is a different finding from hanging in the probe.
      final RegExpMatch? printed = result();
      verdict = printed == null
          ? 'HANG (killed after $timeout s)'
          : 'HANG_AT_EXIT after ${printed.group(1)} (killed after $timeout s)';
    } else {
      await Future.wait(<Future<void>>[out, err]);
      final RegExpMatch? printed = result();
      if (printed != null) {
        verdict = printed.group(1)!;
      } else if ('$output'.contains("Member not found: 'Isolate.") ||
          '$output'.contains("isn't defined for the type 'Isolate'")) {
        verdict =
            'API_REMOVED the probe names Isolate API this SDK no longer '
            'exposes publicly';
      } else if ('$output'.contains('Pass --experimental-shared-data')) {
        verdict =
            'ABORT the VM requires --experimental-shared-data '
            '(exit code $code)';
      } else if (code < 0 || code > 128) {
        verdict = 'CRASH exit code $code';
      } else {
        verdict = 'exit code $code';
      }
    }
    final String line =
        '${name.padRight(30)} ${clock.elapsedMilliseconds.toString().padLeft(6)} ms  $verdict';
    summary.add(line);
    stdout.writeln('-> $line\n');
  }
  stdout
    ..writeln('===== SUMMARY')
    ..writeAll(summary, '\n')
    ..writeln();
}
