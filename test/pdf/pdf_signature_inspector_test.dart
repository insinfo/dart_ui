import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/pdf.dart';
import 'package:test/test.dart';

import 'signing_fixture.dart';

void main() {
  group('PdfSignatureInspector', () {
    test('extracts CMS, digest and exact full-document coverage', () async {
      final signed = await _sign(_document());
      final signatures = const PdfSignatureInspector().inspect(signed);

      expect(signatures, hasLength(1));
      final signature = signatures.single;
      expect(signature.cms, isNotEmpty);
      expect(signature.cms.first, 0x30);
      expect(signature.documentDigest, hasLength(32));
      expect(signature.coversWholeDocument, isTrue);
      expect(signature.contentsStart, signature.byteRange[1]);
      expect(signature.contentsEnd, signature.byteRange[2]);
    });

    test('distinguishes the covered revision after co-signing', () async {
      final first = await _sign(_document());
      final second = await _sign(first);
      final signatures = const PdfSignatureInspector().inspect(second);

      expect(signatures, hasLength(2));
      expect(signatures.first.coversWholeDocument, isFalse);
      expect(signatures.last.coversWholeDocument, isTrue);
    });

    test('rejects a ByteRange that does not delimit Contents', () async {
      final signed = await _sign(_document());
      final text = String.fromCharCodes(signed);
      final marker = RegExp(r'/ByteRange\s*\[\s*0\s+(\d+)').firstMatch(text)!;
      final offset = int.parse(marker.group(1)!);
      signed[offset] = 0x5b;

      expect(
        () => const PdfSignatureInspector().inspect(signed),
        throwsFormatException,
      );
    });
  });
}

Uint8List _document() {
  final builder = PdfDocumentBuilder(title: 'Inspeção de assinatura');
  builder.addPage().drawText('Documento', const Offset(40, 60));
  return builder.build();
}

Future<Uint8List> _sign(Uint8List bytes) {
  final certificate = signingTestCertificate();
  return PdfSigner(
    document: PdfDocument.fromBytes(bytes),
    signerName: 'Teste ICP-Brasil',
    signingTime: DateTime.utc(2005, 1, 2, 3, 4, 5),
  ).sign(
    reservedSignatureBytes: 4096,
    externalSigner: PdfCallbackSigner(
      certificateChain: <Uint8List>[certificate],
      signCallback: (input) async =>
          Uint8List.fromList(List<int>.filled(256, 0x5a)),
    ),
  );
}
