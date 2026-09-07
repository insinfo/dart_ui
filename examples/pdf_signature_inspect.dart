import 'dart:convert';
import 'dart:io';

import 'package:dart_ui/pdf.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln(
        'Uso: dart run examples/pdf_signature_inspect.dart arquivo.pdf');
    exitCode = 64;
    return;
  }

  final file = File(arguments.single);
  if (!file.existsSync()) {
    stderr.writeln('Arquivo não encontrado: ${file.path}');
    exitCode = 66;
    return;
  }

  final signatures = const PdfSignatureInspector().inspect(
    await file.readAsBytes(),
  );
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert(<String, Object>{
      'file': file.absolute.path,
      'signatures': <Map<String, Object>>[
        for (var index = 0; index < signatures.length; index++)
          <String, Object>{
            'index': index + 1,
            'byteRange': signatures[index].byteRange,
            'cmsBytes': signatures[index].cms.length,
            'documentDigestSha256': base64Encode(
              signatures[index].documentDigest,
            ),
            'coversWholeDocument': signatures[index].coversWholeDocument,
          },
      ],
    }),
  );
}
