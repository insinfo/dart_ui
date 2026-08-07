import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln('usage: dart run bin/native_host_protocol_smoke.dart HOST');
    exitCode = 64;
    return;
  }

  final process = await Process.start(arguments.single, const [
    '--command-stdin',
  ]);
  final stderrLines = process.stderr.transform(utf8.decoder).join();
  final output = StreamIterator(
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
  );

  Future<void> waitFor(String expected) async {
    while (await output.moveNext().timeout(const Duration(seconds: 10))) {
      final line = output.current;
      stdout.writeln('HOST: $line');
      if (line == expected) return;
    }
    throw StateError('host exited before producing $expected');
  }

  await waitFor('PROTOCOL=1');
  process.stdin.writeln('PING');
  await process.stdin.flush();
  await waitFor('PONG');

  process.stdin.writeln('SET_TITLE dart_ui IPC smoke');
  await process.stdin.flush();
  await waitFor('TITLE_OK');

  process.stdin.writeln('CLOSE');
  await process.stdin.flush();
  await waitFor('CLOSE_OK');
  await process.stdin.close();

  final status = await process.exitCode.timeout(const Duration(seconds: 10));
  await output.cancel();
  final nativeStderr = await stderrLines;
  if (nativeStderr.isNotEmpty) stderr.write(nativeStderr);
  if (status != 0) throw StateError('native host exited with status $status');
  stdout.writeln('DART_IPC_SMOKE=PASS');
}
