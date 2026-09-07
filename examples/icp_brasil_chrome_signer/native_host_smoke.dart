// ignore_for_file: avoid_relative_lib_imports

import 'dart:async';
import 'dart:io';

import 'native_host/lib/native_messaging.dart';

Future<void> main() async {
  final directory = File(Platform.script.toFilePath()).parent;
  final executable = File(
    '${directory.path}${Platform.pathSeparator}native_host'
    '${Platform.pathSeparator}dist${Platform.pathSeparator}'
    'dart_ui_icp_signer.exe',
  );
  if (!executable.existsSync()) {
    throw StateError('execute build.ps1 antes do smoke test');
  }
  final process = await Process.start(executable.path, const <String>[]);
  final reply = NativeMessageReader(process.stdout).messages().first.timeout(
        const Duration(seconds: 10),
      );
  process.stdin.add(const NativeMessageCodec().encode(<String, Object?>{
    'id': 'native-smoke',
    'origin': 'http://localhost',
    'operation': 'status',
  }));
  await process.stdin.flush();
  final message = await reply;
  if (message['ok'] != true) {
    throw StateError('host respondeu com erro: $message');
  }
  stdout.writeln('OK: host nativo respondeu: ${message['result']}');
  await process.stdin.close();
  await process.exitCode.timeout(const Duration(seconds: 5));
}
