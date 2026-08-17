import 'dart:convert';
import 'dart:typed_data';
import 'package:dart_ui/pdf.dart';
import 'package:test/test.dart';

void main() {
  group('PdfDocument', () {
    test('carrega documento PDF sintético completo com XRef clássico', () {
      // PDF sintético de 1 página
      const pdfText = '%PDF-1.4\n'
          '1 0 obj\n'
          '<< /Type /Catalog /Pages 2 0 R >>\n'
          'endobj\n'
          '2 0 obj\n'
          '<< /Type /Pages /Kids [3 0 R] /Count 1 >>\n'
          'endobj\n'
          '3 0 obj\n'
          '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>\n'
          'endobj\n'
          '4 0 obj\n'
          '<< /Length 23 >>\n'
          'stream\n'
          'BT /F1 12 Tf (Hi) Tj ET\n'
          'endstream\n'
          'endobj\n'
          'xref\n'
          '0 5\n'
          '0000000000 65535 f \n'
          '0000000009 00000 n \n'
          '0000000058 00000 n \n'
          '0000000115 00000 n \n'
          '0000000202 00000 n \n'
          'trailer\n'
          '<< /Size 5 /Root 1 0 R /Info << /Title (Documento Teste) /Author (Dart UI Engine) >> >>\n'
          'startxref\n'
          '275\n'
          '%%EOF';

      final bytes = Uint8List.fromList(utf8.encode(pdfText));
      final doc = PdfDocument.fromBytes(bytes);

      expect(doc.pageCount, 1);
      expect(doc.title, 'Documento Teste');
      expect(doc.author, 'Dart UI Engine');

      final page = doc.getPage(1);
      expect(page.pageNumber, 1);
      expect(page.width, 612.0);
      expect(page.height, 792.0);

      final contents = page.getContentsBytes();
      expect(utf8.decode(contents).trim(), 'BT /F1 12 Tf (Hi) Tj ET');
    });
  });
}
