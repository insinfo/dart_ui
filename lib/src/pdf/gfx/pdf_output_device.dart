import 'dart:typed_data';
import '../../geometry/path.dart';
import '../../geometry/rect.dart';
import '../format/pdf_object.dart';
import 'pdf_gfx_state.dart';
import 'pdf_matrix.dart';

/// Interface abstrata de saída gráfica para o interpretador PDF (equivalente ao OutputDev do Poppler).
abstract class PdfOutputDevice {
  /// Salva o estado gráfico no destino.
  void saveState();

  /// Restaura o estado gráfico anterior no destino.
  void restoreState();

  /// Concatena a matriz de transformação afim corrente.
  void transform(PdfMatrix matrix);

  /// Aplica região de recorte com base no [path] e modo [evenOdd].
  void clip(Path path, {bool evenOdd = false});

  /// Preenche o caminho vetorial [path] com o estilo e cor de preenchimento definidos em [state].
  void fillPath(Path path, PdfGfxState state, {bool evenOdd = false});

  /// Traça o contorno do caminho vetorial [path] com a espessura e cor definidas em [state].
  void strokePath(Path path, PdfGfxState state);

  /// Preenche e traça o caminho simultaneamente.
  void fillAndStrokePath(Path path, PdfGfxState state, {bool evenOdd = false}) {
    fillPath(path, state, evenOdd: evenOdd);
    strokePath(path, state);
  }

  /// Desenha uma imagem raster (XObject de imagem) no retângulo de destino [dstRect].
  void drawImage(
    Uint8List imageBytes,
    int width,
    int height,
    Rect dstRect,
    PdfGfxState state, {
    PdfDict? imageDictionary,
  });

  /// Desenha um glifo ou texto posicionado.
  void drawText(String text, PdfGfxState state, PdfMatrix textMatrix);
}

/// Implementação padrão em memória que grava chamadas em operações vetoriais.
class PdfMemoryOutputDevice extends PdfOutputDevice {
  final List<String> commands = [];
  final List<Path> paths = [];

  @override
  void saveState() => commands.add('save');

  @override
  void restoreState() => commands.add('restore');

  @override
  void transform(PdfMatrix matrix) => commands.add('transform($matrix)');

  @override
  void clip(Path path, {bool evenOdd = false}) {
    paths.add(path);
    commands.add('clip(evenOdd: $evenOdd)');
  }

  @override
  void fillPath(Path path, PdfGfxState state, {bool evenOdd = false}) {
    paths.add(path);
    commands.add(
        'fill(color: 0x${state.fillColor.toRadixString(16)}, evenOdd: $evenOdd)');
  }

  @override
  void strokePath(Path path, PdfGfxState state) {
    paths.add(path);
    commands.add(
        'stroke(color: 0x${state.strokeColor.toRadixString(16)}, width: ${state.lineWidth})');
  }

  @override
  void drawImage(
    Uint8List imageBytes,
    int width,
    int height,
    Rect dstRect,
    PdfGfxState state, {
    PdfDict? imageDictionary,
  }) {
    commands.add('drawImage(${width}x$height, rect: $dstRect)');
  }

  @override
  void drawText(String text, PdfGfxState state, PdfMatrix textMatrix) {
    commands.add(
        'drawText("$text", font: ${state.fontName}, size: ${state.fontSize})');
  }
}
