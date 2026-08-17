import '../document/pdf_page.dart';
import '../gfx/pdf_content_interpreter.dart';
import '../gfx/pdf_matrix.dart';
import '../gfx/pdf_output_device.dart';

/// Motor de renderização de páginas PDF para dispositivos gráficos do `dart_ui`.
class PdfPageRenderer {
  final PdfPage page;

  PdfPageRenderer(this.page);

  /// Executa a interpretação gráfica da página enviando os comandos para o [device].
  void render(
    PdfOutputDevice device, {
    double scale = 1.0,
    bool applyPageRotation = true,
  }) {
    device.saveState();

    // Aplica escala global
    if (scale != 1.0) {
      device.transform(PdfMatrix.scale(scale, scale));
    }

    // Aplica rotação da página se houver
    if (applyPageRotation && page.rotation != 0) {
      final rad = page.rotation * 3.141592653589793 / 180.0;
      device.transform(PdfMatrix.rotation(rad));
    }

    final contentsBytes = page.getContentsBytes();
    if (contentsBytes.isNotEmpty) {
      final interpreter = PdfContentInterpreter(
        device: device,
        resources: page.resources,
        resolver: page.resolver,
      );
      interpreter.execute(contentsBytes);
    }

    device.restoreState();
  }

  /// Renderiza a página para um dispositivo em memória e retorna a lista de comandos gravados.
  PdfMemoryOutputDevice renderToMemory({double scale = 1.0}) {
    final dev = PdfMemoryOutputDevice();
    render(dev, scale: scale);
    return dev;
  }
}

/// Extensão ergonômica em [PdfPage] para renderização direta.
extension PdfPageRenderExtension on PdfPage {
  /// Renderiza a página para um [PdfOutputDevice].
  void renderTo(PdfOutputDevice device, {double scale = 1.0}) {
    PdfPageRenderer(this).render(device, scale: scale);
  }

  /// Renderiza a página para memória para inspeção e testes.
  PdfMemoryOutputDevice renderToMemory({double scale = 1.0}) {
    return PdfPageRenderer(this).renderToMemory(scale: scale);
  }
}
