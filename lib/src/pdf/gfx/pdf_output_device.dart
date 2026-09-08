import 'dart:typed_data';
import '../../geometry/path.dart';
import '../../geometry/rect.dart';
import '../format/pdf_object.dart';
import 'pdf_gfx_state.dart';
import 'pdf_matrix.dart';
import 'pdf_shading.dart';

/// Interface abstrata de saída gráfica para o interpretador PDF (equivalente ao OutputDev do Poppler).
abstract class PdfOutputDevice {
  /// Paints a shading resource through the active clipping region.
  void drawShading(PdfShading shading, PdfGfxState state) {
    final triangles = shading.tessellate(null);
    if (triangles == null) return;
    for (final triangle in triangles) {
      drawShadingTriangle(shading, triangle, state);
    }
  }

  /// Paints one mesh triangle whose three vertices carry independent colors.
  ///
  /// Raster/GPU devices should override this to interpolate the vertex colors.
  /// The portable fallback uses their average, so even minimal vector devices
  /// render the geometry instead of silently dropping mesh shadings.
  void drawShadingTriangle(
    PdfShading shading,
    PdfShadingTriangle triangle,
    PdfGfxState state,
  ) {
    final path = (PathBuilder()
          ..moveTo(triangle.a.x, triangle.a.y)
          ..lineTo(triangle.b.x, triangle.b.y)
          ..lineTo(triangle.c.x, triangle.c.y)
          ..close())
        .build();
    final components = <double>[
      for (var i = 0; i < triangle.a.components.length; i++)
        (triangle.a.components[i] +
                triangle.b.components[i] +
                triangle.c.components[i]) /
            3,
    ];
    final triangleState = state.clone()
      ..fillColor = shading.colorForComponents(components);
    fillPath(path, triangleState);
  }

  /// Salva o estado gráfico no destino.
  void saveState();

  /// Restaura o estado gráfico anterior no destino.
  void restoreState();

  /// Concatena a matriz de transformação afim corrente.
  void transform(PdfMatrix matrix);

  /// Aplica região de recorte com base no [path] e modo [evenOdd].
  void clip(Path path, {bool evenOdd = false});

  /// Clips to the area painted by stroking [path]. Minimal devices may use
  /// the path itself; raster devices should expand it with the active pen.
  void clipStrokePath(Path path, PdfGfxState state) => clip(path);

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
  ///
  /// [advance] is the exact horizontal displacement calculated from the PDF
  /// font metrics, character spacing and horizontal scaling. Output devices
  /// that only paint may ignore it; text-aware devices use it to preserve the
  /// selectable/searchable geometry without measuring a substitute UI font.
  /// [characterAdvances] contains cumulative positions, begins at zero and has
  /// `text.length + 1` entries. It lets selection use real per-glyph geometry
  /// instead of dividing a proportional-font run into equal-width characters.
  void drawText(
    String text,
    PdfGfxState state,
    PdfMatrix textMatrix, {
    double? advance,
    List<double>? characterAdvances,
  });
}

/// Implementação padrão em memória que grava chamadas em operações vetoriais.
class PdfMemoryOutputDevice extends PdfOutputDevice {
  final List<String> commands = [];
  final List<Path> paths = [];

  @override
  void drawShading(PdfShading shading, PdfGfxState state) {
    commands.add('drawShading(type: ${shading.type})');
    super.drawShading(shading, state);
  }

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
  void clipStrokePath(Path path, PdfGfxState state) {
    paths.add(path);
    commands.add('clipStroke(width: ${state.lineWidth})');
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
  void drawText(
    String text,
    PdfGfxState state,
    PdfMatrix textMatrix, {
    double? advance,
    List<double>? characterAdvances,
  }) {
    commands.add(
      'drawText("$text", font: ${state.fontName}, size: ${state.fontSize}, '
      'mode: ${state.textRenderMode.name})',
    );
  }
}
