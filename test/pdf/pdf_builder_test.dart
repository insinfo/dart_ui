import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/pdf.dart';
import 'package:test/test.dart';

void main() {
  group('PdfDocumentBuilder (Exportador Vetorial PDF em Puro Dart)', () {
    test('cria documento PDF válido com múltiplas páginas e valida round-trip',
        () {
      final builder = PdfDocumentBuilder(
        title: 'Relatório Financeiro',
        author: 'Sistema Contábil',
      );

      // Página 1
      final p1 = builder.addPage(width: 612.0, height: 792.0);
      p1.drawRect(
        const Rect.fromLTWH(50, 50, 512, 100),
        fillColor: 0xFFE2E8F0,
        strokeColor: 0xFF334155,
        strokeWidth: 2.0,
      );
      p1.drawText(
        'Relatório de Desempenho - ação 2026',
        const Offset(70, 90),
        fontSize: 18.0,
        color: 0xFF1E293B,
      );
      p1.drawCircle(
        const Offset(300, 300),
        50.0,
        fillColor: 0xFF3B82F6,
        strokeColor: 0xFF1D4ED8,
        strokeWidth: 3.0,
      );
      p1.drawLine(
        const Offset(50, 400),
        const Offset(562, 400),
        strokeColor: 0xFFEF4444,
        strokeWidth: 1.5,
      );

      // Página 2
      final p2 = builder.addPage(width: 612.0, height: 792.0);
      p2.drawText(
        'Pagina 2 - Detalhamento Vetorial',
        const Offset(50, 100),
        fontSize: 14.0,
      );

      // Compila o PDF para bytes em memória
      final pdfBytes = builder.build();

      expect(pdfBytes.length, greaterThan(200));
      // Verifica assinatura padrão %PDF
      expect(pdfBytes[0], 0x25); // %
      expect(pdfBytes[1], 0x50); // P
      expect(pdfBytes[2], 0x44); // D
      expect(pdfBytes[3], 0x46); // F

      // Carrega o PDF gerado de volta com o nosso próprio PdfDocument (Round-trip)
      final doc = PdfDocument.fromBytes(pdfBytes);

      expect(doc.pageCount, 2);
      expect(doc.title, 'Relatório Financeiro');
      expect(doc.author, 'Sistema Contábil');

      final page1 = doc.getPage(1);
      expect(page1.width, 612.0);
      expect(page1.height, 792.0);
      expect(
        String.fromCharCodes(page1.getContentsBytes()),
        contains('Relatório de Desempenho - ação 2026'),
      );

      // Renderiza página 1 para memória para garantir que o interpretador consome o PDF gerado
      final memoryDev = page1.renderToMemory();
      expect(memoryDev.commands.length, greaterThan(5));

      final page2 = doc.getPage(2);
      expect(page2.width, 612.0);
      expect(page2.pageNumber, 2);
    });
  });
}
