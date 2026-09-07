import 'dart:io';

import '../lib/native_messaging.dart';
import '../lib/signer_service.dart';

Future<void> main() async {
  final service = SignerService();
  try {
    await for (final request in NativeMessageReader(stdin).messages()) {
      await writeNativeMessage(stdout, await service.handle(request));
    }
  } catch (error) {
    await writeNativeMessage(stdout, <String, Object?>{
      'id': '',
      'ok': false,
      'error': <String, Object?>{
        'code': 'PROTOCOL_ERROR',
        'message': error.toString(),
      },
    });
  } finally {
    service.close();
  }
}
// ignore_for_file: avoid_relative_lib_imports
