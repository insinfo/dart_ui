import 'dart:typed_data';

import 'package:dart_ui/cdr.dart';
import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/pdf.dart';
import 'package:test/test.dart';

void main() {
  group('Widgets UI Tests', () {
    test('PdfView constrói corretamente com documento real', () {
      // PDF vazio simulado (apenas para teste de instanciação do PdfDocument)
      final dummyPdfBytes = Uint8List.fromList([
        0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x37, 0x0A, // %PDF-1.7
        0x78, 0x72, 0x65, 0x66, 0x0A, 0x30, 0x20, 0x30, 0x0A, // xref 0 0
        0x74, 0x72, 0x61, 0x69, 0x6C, 0x65, 0x72, 0x0A, // trailer
        0x3C, 0x3C, 0x3E, 0x3E, 0x0A, // <<>>
        0x73, 0x74, 0x61, 0x72, 0x74, 0x78, 0x72, 0x65, 0x66, 0x0A, // startxref
        0x39, 0x0A, // 9
        0x25, 0x25, 0x45, 0x4F, 0x46, 0x0A // %%EOF
      ]);

      final realDoc = PdfDocument.fromBytes(dummyPdfBytes);
      final pdfView = PdfView(
        document: realDoc,
        scrollDirection: Axis.vertical,
      );

      expect(pdfView.document, equals(realDoc));
      expect(pdfView.scrollDirection, equals(Axis.vertical));

      final owner = _mount(pdfView);
      addTearDown(owner.dispose);
      expect(owner.hasScheduledBuilds, isFalse);
    });

    test('CdrView constrói corretamente com documento real', () {
      final cdrDoc = CdrDocument.fromBytes(Uint8List.fromList([
        0x52, 0x49, 0x46, 0x46, // 'RIFF'
        0x00, 0x00, 0x00, 0x00, // Size (0)
        0x43, 0x44, 0x52, 0x36, // 'CDR6'
        0x76, 0x72, 0x73, 0x6E // 'vrsn' (just to bypass minimum size)
      ]));

      final cdrView = CdrView(
        document: cdrDoc,
        enablePanZoom: true,
      );

      expect(cdrView.document, equals(cdrDoc));
      expect(cdrView.enablePanZoom, isTrue);
      expect(cdrView.backgroundColor, equals(0xFFFFFFFF));

      final owner = _mount(cdrView);
      addTearDown(owner.dispose);
      expect(owner.hasScheduledBuilds, isFalse);
    });
  });
}

BuildOwner _mount(Widget root) {
  final pipeline = PipelineOwner(
    rootConstraints: BoxConstraints.tight(const Size(1024, 768)),
  );
  final owner = BuildOwner(pipelineOwner: pipeline)..updateRoot(root);
  pipeline.flushLayout();
  if (owner.hasScheduledBuilds) {
    owner.buildScope();
    pipeline.flushLayout();
  }
  return owner;
}
