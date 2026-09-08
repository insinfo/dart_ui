import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/pdf.dart';
import 'package:test/test.dart';

import 'signing_fixture.dart';

void main() {
  group('PdfIncrementalWriter', () {
    test('updates metadata while preserving every original byte', () {
      final original = _document();
      final updated = PdfIncrementalWriter(PdfDocument.fromBytes(original))
          .updateMetadata(<String, String?>{
        'Title': 'Revisão incremental',
        'Author': 'dart_ui',
      });

      expect(Uint8List.sublistView(updated, 0, original.length), original);
      expect(updated.length, greaterThan(original.length));
      final reopened = PdfDocument.fromBytes(updated);
      expect(reopened.title, 'Revisão incremental');
      expect(reopened.author, 'dart_ui');
      final appended = latin1.decode(
        Uint8List.sublistView(updated, original.length),
        allowInvalid: true,
      );
      expect(appended, contains('/Prev '));
      expect(RegExp(r'startxref').allMatches(latin1.decode(updated)).length, 2);
    });

    test('removes one metadata entry without dropping the others', () {
      final original = PdfDocumentBuilder(title: 'Título', author: 'Autor')
        ..addPage();
      final updated = PdfIncrementalWriter(
        PdfDocument.fromBytes(original.build()),
      ).updateMetadata(<String, String?>{'Title': null});

      final reopened = PdfDocument.fromBytes(updated);
      expect(reopened.title, isNull);
      expect(reopened.author, 'Autor');
    });

    test('adds an annotation and an indirect appearance stream', () {
      final original = _document();
      final updated = PdfIncrementalWriter(PdfDocument.fromBytes(original))
          .addAnnotation(PdfFreeTextAnnotation(
        rect: const Rect.fromLTWH(40, 100, 180, 32),
        text: 'Revisão aprovada',
      ));

      expect(Uint8List.sublistView(updated, 0, original.length), original);
      final reopened = PdfDocument.fromBytes(updated);
      final annots = reopened.getPage(1).dict.getArray('Annots', reopened.xref);
      expect(annots, isNotNull);
      expect(annots!.length, 1);
      final annotation = annots.getResolved(0, reopened.xref) as PdfDict;
      expect(annotation.getString('Subtype', reopened.xref), 'FreeText');
      expect(
          annotation.getString('Contents', reopened.xref), 'Revisão aprovada');
      final appearance = annotation
          .getDict('AP', reopened.xref)
          ?.getResolved('N', reopened.xref);
      expect(appearance, isA<PdfStream>());
      expect((appearance as PdfStream).rawBytes, isNotEmpty);
    });

    test('rejects a signed document unless explicitly authorized', () async {
      final signed = await _signedDocument();
      final document = PdfDocument.fromBytes(signed);

      expect(
        () => PdfIncrementalWriter(document)
            .updateMetadata(<String, String?>{'Title': 'Alterado'}),
        throwsA(isA<PdfIncrementalUpdateException>()),
      );

      final updated = PdfIncrementalWriter(
        document,
        allowSignedDocumentUpdate: true,
      ).updateMetadata(<String, String?>{'Title': 'Alterado'});
      expect(Uint8List.sublistView(updated, 0, signed.length), signed);
      final signatures = const PdfSignatureInspector().inspect(updated);
      expect(signatures, hasLength(1));
      expect(signatures.single.coversWholeDocument, isFalse);
      expect(PdfDocument.fromBytes(updated).title, 'Alterado');
    });
  });
}

Uint8List _document() {
  final builder = PdfDocumentBuilder(title: 'Original', author: 'Autor');
  builder.addPage().drawText(
        'Documento',
        const Offset(40, 40),
      );
  return builder.build();
}

Future<Uint8List> _signedDocument() {
  final certificate = signingTestCertificate();
  return PdfSigner(
    document: PdfDocument.fromBytes(_document()),
    signerName: 'Teste',
    signingTime: DateTime.utc(2005),
  ).sign(
    reservedSignatureBytes: 4096,
    externalSigner: PdfCallbackSigner(
      certificateChain: <Uint8List>[certificate],
      signCallback: (data) async =>
          Uint8List.fromList(List<int>.filled(256, data.last)),
    ),
  );
}
