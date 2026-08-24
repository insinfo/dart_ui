import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/pdf.dart';
import 'package:test/test.dart';

void main() {
  final opensslAvailable = _opensslAvailable();

  test(
    'OpenSSL verifica o CMS destacado contra o ByteRange do PDF',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'dart_ui_pdf_sign_',
      );
      try {
        final key = File('${directory.path}${Platform.pathSeparator}key.pem');
        final certificatePem =
            File('${directory.path}${Platform.pathSeparator}certificate.pem');
        final certificateDer =
            File('${directory.path}${Platform.pathSeparator}certificate.der');
        final request = await Process.run('openssl', <String>[
          'req',
          '-x509',
          '-newkey',
          'rsa:2048',
          '-keyout',
          key.path,
          '-out',
          certificatePem.path,
          '-days',
          '2',
          '-nodes',
          '-subj',
          '/CN=dart_ui PDF Signer Test/O=dart_ui',
        ]);
        expect(request.exitCode, 0, reason: request.stderr.toString());
        final convert = await Process.run('openssl', <String>[
          'x509',
          '-in',
          certificatePem.path,
          '-outform',
          'DER',
          '-out',
          certificateDer.path,
        ]);
        expect(convert.exitCode, 0, reason: convert.stderr.toString());
        final certificate = await certificateDer.readAsBytes();

        final builder = PdfDocumentBuilder(title: 'PDF assinado pelo teste');
        builder.addPage().drawText(
              'Documento de interoperabilidade CMS/PAdES',
              const Offset(50, 80),
              fontSize: 15,
            );
        final signer = PdfSigner(
          document: PdfDocument.fromBytes(builder.build()),
          signerName: 'dart_ui PDF Signer Test',
          reason: 'Teste de interoperabilidade',
        );
        final signed = await signer.sign(
          externalSigner: PdfCallbackSigner(
            certificateChain: <Uint8List>[certificate],
            signCallback: (data) async {
              final input = File(
                '${directory.path}${Platform.pathSeparator}attributes.der',
              );
              final output = File(
                '${directory.path}${Platform.pathSeparator}signature.bin',
              );
              await input.writeAsBytes(data);
              final result = await Process.run('openssl', <String>[
                'dgst',
                '-sha256',
                '-sign',
                key.path,
                '-out',
                output.path,
                input.path,
              ]);
              expect(result.exitCode, 0, reason: result.stderr.toString());
              return output.readAsBytes();
            },
          ),
        );

        final extracted = _extractSignature(signed);
        final cmsFile =
            File('${directory.path}${Platform.pathSeparator}signature.der');
        final contentFile =
            File('${directory.path}${Platform.pathSeparator}content.bin');
        await cmsFile.writeAsBytes(extracted.cms);
        await contentFile.writeAsBytes(extracted.content);
        final verify = await Process.run('openssl', <String>[
          'cms',
          '-verify',
          '-binary',
          '-inform',
          'DER',
          '-in',
          cmsFile.path,
          '-content',
          contentFile.path,
          '-noverify',
          '-out',
          Platform.isWindows ? 'NUL' : '/dev/null',
        ]);
        expect(verify.exitCode, 0, reason: verify.stderr.toString());
        expect(PdfDocument.fromBytes(signed).pageCount, 1);
      } finally {
        await directory.delete(recursive: true);
      }
    },
    skip: opensslAvailable ? false : 'OpenSSL não está instalado',
  );
}

bool _opensslAvailable() {
  try {
    return Process.runSync('openssl', const <String>['version']).exitCode == 0;
  } on Object {
    return false;
  }
}

({Uint8List cms, Uint8List content}) _extractSignature(Uint8List pdf) {
  final text = latin1.decode(pdf, allowInvalid: true);
  final byteRangeMatches = RegExp(
    r'/ByteRange\s*\[\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*\]',
  ).allMatches(text);
  final match = byteRangeMatches.last;
  final range = <int>[
    for (var i = 1; i <= 4; i++) int.parse(match.group(i)!),
  ];
  final content = BytesBuilder(copy: false)
    ..add(Uint8List.sublistView(pdf, range[0], range[0] + range[1]))
    ..add(Uint8List.sublistView(pdf, range[2], range[2] + range[3]));

  final contentsMatches =
      RegExp(r'/Contents\s*<([0-9A-Fa-f]+)>').allMatches(text);
  final hex = contentsMatches.last.group(1)!;
  final padded = Uint8List.fromList(<int>[
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
  final cmsLength = _derEncodedLength(padded);
  return (
    cms: Uint8List.sublistView(padded, 0, cmsLength),
    content: content.takeBytes(),
  );
}

int _derEncodedLength(Uint8List bytes) {
  if (bytes.length < 2 || bytes.first != 0x30) {
    throw const FormatException('CMS is not a DER SEQUENCE');
  }
  final first = bytes[1];
  if ((first & 0x80) == 0) return 2 + first;
  final count = first & 0x7f;
  if (count == 0 || 2 + count > bytes.length) {
    throw const FormatException('CMS has an invalid DER length');
  }
  var length = 0;
  for (var i = 0; i < count; i++) {
    length = (length << 8) | bytes[2 + i];
  }
  return 2 + count + length;
}
