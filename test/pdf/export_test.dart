import 'package:test/test.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/pdf/export/pdf_document_builder.dart';
import 'package:dart_ui/src/pdf/export/display_list_to_pdf.dart';
import 'package:dart_ui/src/graphics/display_list.dart';

void main() {
  group('PDF Export', () {
    test('PdfDocumentBuilder generates a valid PDF with shapes', () {
      final builder = PdfDocumentBuilder();
      final page = builder.addPage(width: 500, height: 500);

      page.drawRect(const Rect.fromLTWH(10, 10, 100, 100),
          fillColor: 0xFFFF0000); // Red
      page.drawRect(const Rect.fromLTWH(120, 10, 100, 100),
          strokeColor: 0xFF00FF00); // Green stroke

      final bytes = builder.build();

      expect(bytes.isNotEmpty, isTrue);

      final pdfString = String.fromCharCodes(bytes);
      expect(pdfString, startsWith('%PDF-1.4'));
      expect(pdfString, contains('1.0 0.0 0.0 rg')); // Red RGB
      expect(pdfString, contains('0.0 1.0 0.0 RG')); // Green RGB
      expect(pdfString, contains('10.0 390.0 100.0 100.0 re'));
      expect(pdfString, endsWith('%%EOF\n'));
    });

    test('DisplayListToPdfWriter writes via DisplayList', () {
      final dl = DisplayList();
      // Dummy test since we do not have full DisplayList replay implementation yet.
      final recorder = DisplayListToPdfWriter.write(dl);
      expect(recorder, isNotNull);
    });
  });
}
