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
      _standardWidths.addAll(_helveticaWidths);
    } else if (baseFont.contains('Courier')) {
      for (var code = 0; code <= 255; code++) {
        _standardWidths[code] = 600;
      }
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

/// Width from the built-in metrics of a PDF standard Type 1 font.
///
/// Standard-14 fonts are valid without a `/Widths` array. Helvetica is by far
/// the most common instance (including PDFs emitted by browsers and report
/// generators), while Courier is fixed-width by definition. Returning null
/// lets the caller use a descriptor or a subtype-specific fallback for fonts
/// outside this built-in set.
double? standardType1GlyphWidth(String baseFont, int charCode) {
  if (baseFont.contains('Helvetica')) return _helveticaWidths[charCode];
  if (baseFont.contains('Courier')) return 600;
  return null;
}

const Map<int, double> _helveticaWidths = <int, double>{
  32: 278,
  33: 278,
  34: 355,
  35: 556,
  36: 556,
  37: 889,
  38: 667,
  39: 191,
  40: 333,
  41: 333,
  42: 389,
  43: 584,
  44: 278,
  45: 333,
  46: 278,
  47: 278,
  48: 556,
  49: 556,
  50: 556,
  51: 556,
  52: 556,
  53: 556,
  54: 556,
  55: 556,
  56: 556,
  57: 556,
  58: 278,
  59: 278,
  60: 584,
  61: 584,
  62: 584,
  63: 556,
  64: 1015,
  65: 667,
  66: 667,
  67: 722,
  68: 722,
  69: 667,
  70: 611,
  71: 778,
  72: 722,
  73: 278,
  74: 500,
  75: 667,
  76: 556,
  77: 833,
  78: 722,
  79: 778,
  80: 667,
  81: 778,
  82: 722,
  83: 667,
  84: 611,
  85: 722,
  86: 667,
  87: 944,
  88: 667,
  89: 667,
  90: 611,
  91: 278,
  92: 278,
  93: 278,
  94: 469,
  95: 556,
  96: 222,
  97: 556,
  98: 556,
  99: 500,
  100: 556,
  101: 556,
  102: 278,
  103: 556,
  104: 556,
  105: 222,
  106: 222,
  107: 500,
  108: 222,
  109: 833,
  110: 556,
  111: 556,
  112: 556,
  113: 556,
  114: 333,
  115: 500,
  116: 278,
  117: 556,
  118: 500,
  119: 722,
  120: 500,
  121: 500,
  122: 500,
  123: 334,
  124: 260,
  125: 334,
  126: 584,
  // WinAnsi letters use the width of their unaccented base glyph.
  0xC0: 667,
  0xC1: 667,
  0xC2: 667,
  0xC3: 667,
  0xC4: 667,
  0xC5: 667,
  0xC6: 1000,
  0xC7: 722,
  0xC8: 667,
  0xC9: 667,
  0xCA: 667,
  0xCB: 667,
  0xCC: 278,
  0xCD: 278,
  0xCE: 278,
  0xCF: 278,
  0xD0: 722,
  0xD1: 722,
  0xD2: 778,
  0xD3: 778,
  0xD4: 778,
  0xD5: 778,
  0xD6: 778,
  0xD7: 584,
  0xD8: 778,
  0xD9: 722,
  0xDA: 722,
  0xDB: 722,
  0xDC: 722,
  0xDD: 667,
  0xDE: 667,
  0xDF: 611,
  0xE0: 556,
  0xE1: 556,
  0xE2: 556,
  0xE3: 556,
  0xE4: 556,
  0xE5: 556,
  0xE6: 889,
  0xE7: 500,
  0xE8: 556,
  0xE9: 556,
  0xEA: 556,
  0xEB: 556,
  0xEC: 222,
  0xED: 222,
  0xEE: 222,
  0xEF: 222,
  0xF0: 556,
  0xF1: 556,
  0xF2: 556,
  0xF3: 556,
  0xF4: 556,
  0xF5: 556,
  0xF6: 556,
  0xF7: 584,
  0xF8: 611,
  0xF9: 556,
  0xFA: 556,
  0xFB: 556,
  0xFC: 556,
  0xFD: 500,
  0xFE: 556,
  0xFF: 500,
};
