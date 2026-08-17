import '../format/pdf_object.dart';

/// Classe base abstrata para todas as fontes PDF (Type1, TrueType, Type3, CIDFont).
abstract class PdfFont {
  final PdfDict fontDict;
  final String baseFont;

  // FontDescriptor details
  double ascent = 0.0;
  double descent = 0.0;
  double capHeight = 0.0;
  double missingWidth = 0.0;
  PdfDict? fontDescriptor;

  PdfFont(this.fontDict)
      : baseFont = fontDict.getName('BaseFont')?.name ?? 'Unknown' {
    _parseDescriptor();
  }

  void _parseDescriptor() {
    final fd = fontDict.getDict('FontDescriptor');
    if (fd != null) {
      fontDescriptor = fd;
      ascent = fd.getNumber('Ascent')?.toDouble() ?? 0.0;
      descent = fd.getNumber('Descent')?.toDouble() ?? 0.0;
      capHeight = fd.getNumber('CapHeight')?.toDouble() ?? 0.0;
      missingWidth = fd.getNumber('MissingWidth')?.toDouble() ?? 0.0;
    }
  }

  /// Converte um código de caractere lido do fluxo PDF em um código Unicode.
  int charCodeToUnicode(int charCode);

  /// Retorna a largura do caractere (em 1/1000 de unidade de texto).
  double getCharWidth(int charCode);
}
