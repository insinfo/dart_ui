import '../format/pdf_object.dart';
import 'pdf_font.dart';

/// Implementação da fonte Type1, que contém suporte embutido às 14 fontes padrão
/// (Helvetica, Times, Courier, Symbol, ZapfDingbats).
class PdfType1Font extends PdfFont {
  PdfType1Font(super.fontDict) {
    _initStandardMetrics();
  }

  // Tabela simplificada de larguras padrão (em 1/1000 em) para Helvetica
  final Map<int, double> _standardWidths = {};

  void _initStandardMetrics() {
    if (baseFont.contains('Helvetica')) {
      // Valores heurísticos rápidos de largura (normalmente lidos do arquivo .afm)
      _standardWidths.addAll({
        32: 278, // espaço
        65: 667, // A
        66: 667, // B
        97: 556, // a
        98: 556, // b
        // ... etc
      });
    }
  }

  @override
  int charCodeToUnicode(int charCode) {
    // Tratamento para WinAnsiEncoding / MacRomanEncoding
    final encoding = fontDict.getResolved('Encoding');
    if (encoding is PdfName) {
      if (encoding.name == 'WinAnsiEncoding') {
        // Conversões específicas de latin-1
        if (charCode >= 0 && charCode <= 255) {
          return charCode; // Simplificação provisória
        }
      }
    } else if (encoding is PdfDict) {
      // Encoding customizado através de /Differences
    }

    // Por padrão (se não for Symbol/Dingbats)
    return charCode;
  }

  @override
  double getCharWidth(int charCode) {
    // 1. Tentar ler do array /Widths do PDF
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

    // 2. Tentar das métricas embutidas da Type1
    if (_standardWidths.containsKey(charCode)) {
      return _standardWidths[charCode]!;
    }

    // 3. Fallback
    return missingWidth > 0 ? missingWidth : 600.0;
  }
}
