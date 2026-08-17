import '../../graphics/display_list.dart';
import '../../geometry/rect.dart';

/// Constrói a aparência visual da assinatura (Appearance Stream /AP /N).
class PdfSignatureAppearanceBuilder {
  final DisplayList _dl = DisplayList();

  PdfSignatureAppearanceBuilder();

  /// Desenha a aparência da assinatura usando primitivas do dart_ui.
  void drawText(String text, Rect bounds) {
    // Simulando o desenho de texto no DisplayList
    // (A integração real usaria drawParagraph ou drawGlyphRun)
    _dl.save();
    _dl.drawRect(
        bounds.left, bounds.top, bounds.right, bounds.bottom, 0); // Fundo

    // Simula a escrita de texto
    // _dl.drawText(...)

    _dl.restore();
  }

  /// Retorna o DisplayList que pode ser convertido em um Content Stream PDF
  /// pelo PdfCanvasRecorder e injetado na anotação /Annot /Widget da assinatura.
  DisplayList build() {
    return _dl;
  }
}
