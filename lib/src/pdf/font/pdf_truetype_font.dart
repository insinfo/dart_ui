import 'dart:typed_data';
import 'pdf_font.dart';

/// Implementação da fonte TrueType, responsável por ler o arquivo embutido (.ttf)
/// se disponível no dicionário FontDescriptor.
class PdfTrueTypeFont extends PdfFont {
  Uint8List? _fontData;

  PdfTrueTypeFont(super.fontDict) {
    _loadFontData();
  }

  void _loadFontData() {
    if (fontDescriptor == null) return;

    // O stream contendo o binário do arquivo .ttf
    final fontFile = fontDescriptor!.getStream('FontFile2') ??
        fontDescriptor!.getStream('FontFile3');

    if (fontFile != null) {
      _fontData = fontFile.getDecodedBytes();
      // O parser completo da tabela TrueType (cmap, glyf, loca, etc.) seria implementado aqui.
    }
  }

  @override
  int charCodeToUnicode(int charCode) {
    // TrueType normalmente exige tabelas CMap ou o Encoding dictionary (WinAnsiEncoding / MacRomanEncoding)
    // Além da tabela `cmap` interna do arquivo TTF.
    // Provisoriamente:
    return charCode;
  }

  @override
  double getCharWidth(int charCode) {
    // 1. Tentar ler do array /Widths do dicionário do PDF (mais rápido)
    final firstChar = fontDict.getNumber('FirstChar')?.toInt() ?? 0;
    final lastChar = fontDict.getNumber('LastChar')?.toInt() ?? 255;

    if (charCode >= firstChar && charCode <= lastChar) {
      final widthsArray = fontDict.getArray('Widths');
      if (widthsArray != null) {
        final index = charCode - firstChar;
        final w = widthsArray.getNumber(index);
        if (w != null) return w.toDouble();
      }
    }

    // 2. Tentar ler da métrica `hmtx` do arquivo TrueType embutido
    if (_fontData != null) {
      // Retornaria a largura extraída da tabela hmtx
    }

    // 3. Fallback
    return missingWidth > 0 ? missingWidth : 600.0;
  }
}
