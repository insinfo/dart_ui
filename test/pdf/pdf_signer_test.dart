import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/pdf.dart';
import 'package:test/test.dart';

import 'signing_fixture.dart';

void main() {
  group('assinatura PDF incremental', () {
    test('prepara campo AcroForm conectado à página e ByteRange exato', () {
      final original = _document();
      final document = PdfDocument.fromBytes(original);
      final signer = _signer(document);
      final prepared = signer.prepare(reservedSignatureBytes: 4096);

      final text = latin1.decode(prepared.bytes, allowInvalid: true);
      expect(text, contains('/SubFilter /ETSI.CAdES.detached'));
      expect(text, contains('/FT /Sig'));
      expect(text, contains('/AcroForm'));
      expect(text, contains('/AP'));
      expect(prepared.documentDigest.length, 32);
      expect(prepared.byteRange[1], prepared.contentsHexOffset - 1);
      expect(
        prepared.byteRange[2],
        prepared.contentsHexOffset + prepared.reservedSignatureBytes * 2 + 1,
      );

      final reopened = PdfDocument.fromBytes(prepared.bytes);
      expect(reopened.pageCount, 1);
      final form = reopened.catalog?.getDict('AcroForm', reopened.xref);
      expect(form?.getArray('Fields', reopened.xref)?.length, 1);
      expect(reopened.getPage(1).dict.getArray('Annots', reopened.xref)?.length,
          1);
    });

    test('assina por callback externo e incorpora CMS sem mudar offsets',
        () async {
      Uint8List? signedInput;
      final certificate = signingTestCertificate();
      final signer = _signer(PdfDocument.fromBytes(_document()));
      final result = await signer.sign(
        reservedSignatureBytes: 4096,
        externalSigner: PdfCallbackSigner(
          certificateChain: <Uint8List>[certificate],
          signCallback: (data) async {
            signedInput = Uint8List.fromList(data);
            return Uint8List.fromList(List<int>.filled(256, 0x5a));
          },
        ),
      );

      expect(signedInput, isNotNull);
      expect(signedInput!.first, 0x31);
      final text = latin1.decode(result, allowInvalid: true);
      expect(text, contains('/ByteRange [0 '));
      expect(text, isNot(contains('/Contents <${'0' * 128}')));
      expect(PdfDocument.fromBytes(result).pageCount, 1);
    });

    test('não fabrica assinatura para perfil de timestamp/LTV', () {
      final signer = PdfSigner(
        document: PdfDocument.fromBytes(_document()),
        signerName: 'Teste',
        standard: PdfSignatureStandard.padesBT,
        signingTime: DateTime.utc(2005),
      );
      expect(signer.prepare, throwsA(isA<PdfSignatureException>()));
    });

    test('coassinatura incremental preserva o primeiro campo', () async {
      final certificate = signingTestCertificate();
      PdfCallbackSigner externalSigner() => PdfCallbackSigner(
            certificateChain: <Uint8List>[certificate],
            signCallback: (data) async =>
                Uint8List.fromList(List<int>.filled(256, data.last)),
          );

      final first = await _signer(PdfDocument.fromBytes(_document())).sign(
        externalSigner: externalSigner(),
        reservedSignatureBytes: 4096,
      );
      final second = await _signer(PdfDocument.fromBytes(first)).sign(
        externalSigner: externalSigner(),
        reservedSignatureBytes: 4096,
      );
      final reopened = PdfDocument.fromBytes(second);
      final fields = reopened.catalog
          ?.getDict('AcroForm', reopened.xref)
          ?.getArray('Fields', reopened.xref);
      expect(fields?.length, 2);
      expect(
        reopened.getPage(1).dict.getArray('Annots', reopened.xref)?.length,
        2,
      );
      expect(
        RegExp(r'/SubFilter /ETSI.CAdES.detached')
            .allMatches(latin1.decode(second, allowInvalid: true))
            .length,
        2,
      );
    });
  });
}

Uint8List _document() {
  final builder = PdfDocumentBuilder(title: 'Contrato');
  builder.addPage().drawText(
        'Contrato para assinatura',
        const Offset(50, 80),
        fontSize: 16,
      );
  return builder.build();
}

PdfSigner _signer(PdfDocument document) {
  final signer = PdfSigner(
    document: document,
    signerName: 'Autoridade Certificadora Raiz Brasileira',
    reason: 'Aprovação',
    location: 'Brasília, Brasil',
    signingTime: DateTime.utc(2005, 1, 2, 3, 4, 5),
  );
  signer.setVisualAppearance(
    PdfSignatureAppearance(
      pageNumber: 1,
      rect: const Rect.fromLTWH(300, 650, 240, 72),
      signerName: 'Autoridade Certificadora Raiz Brasileira',
      reason: 'Aprovação',
      signingTime: DateTime.utc(2005, 1, 2, 3, 4, 5),
    ),
  );
  return signer;
}
