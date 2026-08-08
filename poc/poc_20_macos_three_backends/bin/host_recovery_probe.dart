import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:poc_20_macos_three_backends/poc_20_macos_three_backends.dart';

// ---------------------------------------------------------------------------
// What happens to the Dart side when the host dies?
//
// ADR 0001 chose a worker process partly BECAUSE it isolates crashes, and then
// listed crash detection and restart as a requirement rather than a detail.
// This is that requirement, measured: kill the host mid-session and check
// three things the framework will depend on.
//
//   1. Dart notices. A pipe that has gone quiet and a host that has died look
//      identical until the exit code arrives, so the exit future is the only
//      honest signal - not a read timeout.
//   2. The surface outlives the host. An IOSurface is refcounted by the
//      kernel: the Dart side still holds a reference, so the pixels must
//      survive a host that dropped its own. If they did not, a restart would
//      mean re-uploading every frame.
//   3. A fresh host can attach the SAME surface and present from it. That is
//      what makes recovery cheap: the window is new, the framebuffer is not.
//
// A SIGKILL is used deliberately. SIGTERM would let AppKit tear down politely,
// which is the case that was never in doubt.
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
        .listen((line) {
      host.lines.add(line);
      stdout.writeln('HOST| $line');
    });
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
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    return null;
  }
}

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) {
    stderr.writeln('usage: host_recovery_probe <host-binary>');
    exitCode = 64;
    return;
  }
  final binary = arguments.first;
  var failures = 0;

  void check(bool condition, String failure) {
    if (!condition) {
      failures++;
      print('FAILURE: $failure');
    }
  }

  // The surface belongs to Dart, which is the entire point: the host is a
  // consumer of pixels, not their owner.
  final surface = IOSurfaceFrame.create(width: 480, height: 320);
  surface.fillBgra(0x30, 0x90, 0xE0);
  print('SURFACE_ID=${surface.id}');

  // --- first host ------------------------------------------------------------
  final first = await _Host.start(binary);
  check(
    await first.waitFor((l) => l.startsWith('WINDOW_ID=')) != null,
    'first host never opened a window',
  );
  await first.send('SURFACE ${surface.id}');
  check(
    await first.waitFor((l) => l.startsWith('SURFACE_OK')) != null,
    'first host could not attach the surface',
  );
  await first.send('PRESENT 1');
  check(
    await first.waitFor((l) => l.startsWith('PRESENT_OK 1 ')) != null,
    'first host could not present',
  );

  // --- the crash -------------------------------------------------------------
  final killedAt = DateTime.now();
  first.process.kill(ProcessSignal.sigkill);
  final status = await first.process.exitCode
      .timeout(const Duration(seconds: 10), onTimeout: () => -999);
  final noticedAfter = DateTime.now().difference(killedAt);

  print('HOST_EXIT_STATUS=$status');
  print('CRASH_NOTICED_MS=${noticedAfter.inMilliseconds}');
  // SIGKILL is 9; Dart reports a signal death as -signal on POSIX.
  check(status == -9, 'expected a SIGKILL exit, got $status');
  check(
    noticedAfter.inSeconds < 5,
    'took ${noticedAfter.inSeconds}s to notice the host had died',
  );

  // --- the surface survived --------------------------------------------------
  //
  // Writing into it is the real proof: if the kernel had reclaimed the pages
  // when the host dropped its reference, this would fault rather than return.
  var wroteAfterCrash = true;
  try {
    surface.fillBgra(0xE0, 0x60, 0x20);
  } on Object catch (error) {
    wroteAfterCrash = false;
    print('SURFACE_WRITE_ERROR=$error');
  }
  print('SURFACE_SURVIVED_CRASH=${wroteAfterCrash ? 1 : 0}');
  check(wroteAfterCrash, 'the surface died with the host');

  // --- restart ---------------------------------------------------------------
  final second = await _Host.start(binary);
  final windowLine = await second.waitFor((l) => l.startsWith('WINDOW_ID='));
  check(windowLine != null, 'replacement host never opened a window');
  print('RESTART_WINDOW=${windowLine ?? "none"}');

  await second.send('SURFACE ${surface.id}');
  final reattached = await second.waitFor((l) => l.startsWith('SURFACE_OK'));
  print('SURFACE_REATTACHED=${reattached ?? "none"}');
  check(reattached != null, 'replacement host could not attach the surface');

  await second.send('PRESENT 1');
  final represented =
      await second.waitFor((l) => l.startsWith('PRESENT_OK 1 '));
  print('RESTART_PRESENT=${represented ?? "none"}');
  check(represented != null, 'replacement host could not present');

  await second.send('CLOSE');
  await second.waitFor((l) => l == 'CLOSE_OK');
  final secondStatus = await second.process.exitCode
      .timeout(const Duration(seconds: 10), onTimeout: () => -999);
  check(secondStatus == 0, 'replacement host exited with $secondStatus');

  surface.dispose();

  print(
      failures == 0 ? 'HOST_RECOVERY=PASS' : 'HOST_RECOVERY=FAIL ($failures)');
  if (failures != 0) exitCode = 1;
}
