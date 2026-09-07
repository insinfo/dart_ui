// ignore_for_file: avoid_relative_lib_imports

import 'dart:async';
import 'dart:io';

import 'package:dart_ui/dart_ui.dart';

import 'native_host/lib/native_messaging.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.contains('--list')) {
    final provider = WindowsCertificateProvider();
    try {
      final identities = await provider.listIdentities();
      final icpBrasil = identities.where(
        (identity) => identity.certificate.subjectName
            .toUpperCase()
            .contains('ICP-BRASIL'),
      );
      for (final identity in icpBrasil) {
        stdout.writeln('${identity.certificate.icpBrasilDisplayName} | '
            '${identity.certificate.maskedIcpBrasilCpf} | '
            '${identity.metadata['provider']}');
      }
      if (icpBrasil.isEmpty) {
        throw StateError('nenhum certificado ICP-Brasil encontrado');
      }
    } finally {
      provider.close();
    }
    return;
  }
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
