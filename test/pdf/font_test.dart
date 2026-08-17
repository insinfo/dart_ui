import 'package:test/test.dart';
import 'package:dart_ui/src/pdf/font/pdf_cmap.dart';
import 'package:dart_ui/src/pdf/font/pdf_type1_font.dart';
import 'package:dart_ui/src/pdf/format/pdf_object.dart';

void main() {
  group('PDF Font Subsystem', () {
    test('Type1 Font Width and Encoding Fallback', () {
      final fontDict = PdfDict({
        'Type': const PdfName('Font'),
        'Subtype': const PdfName('Type1'),
        'BaseFont': const PdfName('Helvetica'),
      });

      final font = PdfType1Font(fontDict);

      // Mapeamento direto de um código sem CMap ou Differences
      expect(font.charCodeToUnicode(65), equals(65)); // 'A'

      // Largura da tabela _standardWidths para a 'Helvetica'
      expect(font.getCharWidth(65), equals(667.0));
    });

    test('PdfCMap maps cid to unicode via bfchar and bfrange', () {
      final cmap = PdfCMap();

      // Adiciona mapeamento singular
      cmap.addBfChar(0x0021, 0x0041); // '!' no pdf -> 'A' no unicode

      // Adiciona mapeamento de range: de 0x0030 a 0x0039 -> 0x0030 (0..9)
      cmap.addBfRange(0x0030, 0x0039, 0x0030);

      expect(cmap.getUnicode(0x0021), equals(0x0041));

      // Checa o início e meio do range
      expect(cmap.getUnicode(0x0030), equals(0x0030));
      expect(cmap.getUnicode(0x0035), equals(0x0035));
      expect(cmap.getUnicode(0x0039), equals(0x0039));

      // Um cid inexistente
      expect(cmap.getUnicode(0x0099), isNull);
    });
  });
}
