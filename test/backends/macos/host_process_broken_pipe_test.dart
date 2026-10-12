/// A host that dies between two writes must not take the application with it.
///
/// Writing to a child's stdin after the child exited fails *asynchronously*:
/// [MacosHostProcess.send] returns true, and the broken pipe arrives later on
/// the sink's `done`. With nobody listening there, it was an unhandled
/// exception - on the macos-14 runner, in the middle of a popup's surface
/// handoff to a spare host that had died - and the whole program exited for a
/// host death the supervisor exists to survive.
///
/// The host here is a shell script that speaks just enough of the protocol to
/// finish the handshake and then exits, so the test needs no AppKit and runs
/// on the Linux leg too. Not on Windows, which has no `sh`.
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_ui/src/backends/macos/host_process.dart';
import 'package:dart_ui/src/backends/macos/host_protocol.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:test/test.dart';

void main() {
  test('writes to a host that exited are diagnosed, not thrown', () async {
    final Directory scratch =
        await Directory.systemTemp.createTemp('dart_ui_dead_host');
    addTearDown(() => scratch.delete(recursive: true));
    final File host = File('${scratch.path}/host.sh')..writeAsStringSync('''
#!/bin/sh
echo MAIN_THREAD=1
echo WINDOW_ID=7
echo PROTOCOL=4
echo PROTOCOL_FEATURES=surface-port,window-events,clipboard
echo HOST_PID=\$\$
read line
exit 0
''');
    await Process.run('chmod', <String>['+x', host.path]);

    final diagnostics = <BackendDiagnostic>[];
    final MacosHostProcess? process = await MacosHostProcess.start(
      MacosHostSpawnOptions(
        binaryPath: host.path,
        logicalWidth: 10,
        logicalHeight: 10,
        handshakeTimeout: const Duration(seconds: 5),
      ),
      _Sink(),
      diagnostics.add,
    );
    expect(process, isNotNull, reason: 'the handshake should complete');

    // Killed synchronously and written to at once, with no event-loop turn
    // in between: Dart has not seen the exit yet, so every send() queues its
    // bytes and returns true, and the pipe breaks under them on the flush.
    // That is the order the supervisor's surface handoff produced on the
    // runner.
    Process.killPid(process!.pid, ProcessSignal.sigkill);
    for (var i = 0; i < 50; i++) {
      process.send(HostCommands.surfacePool(2));
    }
    expect(await process.exitStatus, isNot(0));
    await Future<void>.delayed(const Duration(milliseconds: 200));

    // Still answering, and refusing by return value rather than by throwing.
    // The broken pipes themselves are the assertion: had one escaped as an
    // unhandled error, the test zone would have failed this test with it.
    expect(process.send(HostCommands.ping()), isFalse);
  }, skip: Platform.isWindows ? 'needs sh' : null);
}

final class _Sink with HostMessageSinkAdapter {}
