import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_ui/src/pdf/font/pdf_cmap.dart';
import 'package:dart_ui/src/pdf/font/pdf_type1_font.dart';
import 'package:dart_ui/src/pdf/format/pdf_object.dart';
import 'package:test/test.dart';

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
      expect(font.getCharWidth(73), equals(278.0));
      expect(font.getCharWidth(87), equals(944.0));
      expect(font.getCharWidth(0xE3), equals(556.0));
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

    test('PdfCMap parses ToUnicode code spaces, chars and ranges', () {
      final cmap = PdfCMap.parse(
        Uint8List.fromList(
          latin1.encode('''
            1 begincodespacerange
            <0000> <FFFF>
            endcodespacerange
            2 beginbfchar
            <0001> <0041>
            <0002> <00E7>
            endbfchar
            1 beginbfrange
            <0010> <0012> <0061>
            endbfrange
          '''),
        ),
      );

      expect(
        cmap.decode(Uint8List.fromList(<int>[0, 1, 0, 2, 0, 0x10, 0, 0x12])),
        'Açac',
      );
    });
  });
}
