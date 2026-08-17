import 'dart:typed_data';
import 'package:dart_ui/cdr.dart';
import 'package:dart_ui/pdf.dart';
import 'package:test/test.dart';

void main() {
  group('Conversão e Exportação de CDR para PDF', () {
    test('CdrDocument converte para PDF e valida leitura do PDF gerado', () {
      final builder = BytesBuilder();
      builder.add([0x52, 0x49, 0x46, 0x46]); // 'RIFF'
      builder.add([16, 0, 0, 0]);
      builder.add([0x43, 0x44, 0x52, 0x39]); // 'CDR9' -> CorelDRAW 9
      builder.add([0x74, 0x65, 0x73, 0x74]);
      builder.add([0, 0, 0, 0]);

      final cdrBytes = builder.takeBytes();
      final cdrDoc = CdrDocument.fromBytes(cdrBytes);

      // Exporta CDR para PDF
      final pdfBytes = cdrDoc.exportToPdf();
      expect(pdfBytes, isNotNull);
      expect(pdfBytes.length, greaterThan(100));

      // Valida que o PDF gerado é lido perfeitamente pelo PdfDocument
      final pdfDoc = PdfDocument.fromBytes(pdfBytes);
      expect(pdfDoc.pageCount, 1);
      expect(pdfDoc.title, contains('CorelDRAW'));
    });
  });
}
