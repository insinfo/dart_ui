import 'dart:convert';
import 'dart:typed_data';
import '../../geometry/offset.dart';
import '../../geometry/path.dart';
import '../../geometry/rect.dart';
import '../gfx/pdf_matrix.dart';

/// Gravador de comandos vetoriais que compila operações do `dart_ui.Canvas` diretamente para sintaxe PDF (ISO 32000).
class PdfCanvasRecorder {
  final StringBuffer _buffer = StringBuffer();
  final double pageHeight;

  PdfCanvasRecorder({this.pageHeight = 792.0});

  /// Conteúdo do Content Stream gerado em sintaxe PDF.
  String get content => _buffer.toString();

  /// Converte coordenadas de tela (origem no topo-esquerdo) para o sistema PDF (origem na base-esquerda).
  double _pdfY(double y) => pageHeight - y;

  /// Salva o estado gráfico corrente (`q`).
  void save() {
    _buffer.writeln('q');
  }

  /// Restaura o estado gráfico anterior (`Q`).
  void restore() {
    _buffer.writeln('Q');
  }

  /// Concatena uma matriz de transformação afim 2D (`cm`).
  void transform(PdfMatrix m) {
    _buffer.writeln('${m.a} ${m.b} ${m.c} ${m.d} ${m.e} ${m.f} cm');
  }

  /// Define a cor de traço em RGB (`RG`).
  void setStrokeColor(int colorArgb) {
    final r = ((colorArgb >> 16) & 0xFF) / 255.0;
    final g = ((colorArgb >> 8) & 0xFF) / 255.0;
    final b = (colorArgb & 0xFF) / 255.0;
    _buffer.writeln('$r $g $b RG');
  }

  /// Define a cor de preenchimento em RGB (`rg`).
  void setFillColor(int colorArgb) {
    final r = ((colorArgb >> 16) & 0xFF) / 255.0;
    final g = ((colorArgb >> 8) & 0xFF) / 255.0;
    final b = (colorArgb & 0xFF) / 255.0;
    _buffer.writeln('$r $g $b rg');
  }

  /// Define a espessura da linha (`w`).
  void setLineWidth(double width) {
    _buffer.writeln('$width w');
  }

  /// Desenha um retângulo na página.
  void drawRect(Rect rect,
      {int? fillColor, int? strokeColor, double strokeWidth = 1.0}) {
    if (fillColor != null) setFillColor(fillColor);
    if (strokeColor != null) {
      setStrokeColor(strokeColor);
      setLineWidth(strokeWidth);
    }

    final x = rect.left;
    final y = _pdfY(rect.bottom);
    final w = rect.width;
    final h = rect.height;

    _buffer.writeln('$x $y $w $h re');

    if (fillColor != null && strokeColor != null) {
      _buffer.writeln('B');
    } else if (fillColor != null) {
      _buffer.writeln('f');
    } else if (strokeColor != null) {
      _buffer.writeln('S');
    }
  }

  /// Desenha um segmento de linha reta entre [p1] e [p2].
  void drawLine(Offset p1, Offset p2,
      {int strokeColor = 0xFF000000, double strokeWidth = 1.0}) {
    setStrokeColor(strokeColor);
    setLineWidth(strokeWidth);

    _buffer.writeln('${p1.dx} ${_pdfY(p1.dy)} m');
    _buffer.writeln('${p2.dx} ${_pdfY(p2.dy)} l');
    _buffer.writeln('S');
  }

  /// Desenha um círculo aproximado por 4 curvas cúbicas de Bézier com constante kappa.
  void drawCircle(Offset center, double radius,
      {int? fillColor, int? strokeColor, double strokeWidth = 1.0}) {
    const kappa = 0.5522847498307935;
    final ox = radius * kappa;
    final oy = radius * kappa;

    final cx = center.dx;
    final cy = _pdfY(center.dy);

    if (fillColor != null) setFillColor(fillColor);
    if (strokeColor != null) {
      setStrokeColor(strokeColor);
      setLineWidth(strokeWidth);
    }

    _buffer.writeln('${cx + radius} $cy m');
    _buffer.writeln(
        '${cx + radius} ${cy + oy} ${cx + ox} ${cy + radius} $cx ${cy + radius} c');
    _buffer.writeln(
        '${cx - ox} ${cy + radius} ${cx - radius} ${cy + oy} ${cx - radius} $cy c');
    _buffer.writeln(
        '${cx - radius} ${cy - oy} ${cx - ox} ${cy - radius} $cx ${cy - radius} c');
    _buffer.writeln(
        '${cx + ox} ${cy - radius} ${cx + radius} ${cy - oy} ${cx + radius} $cy c');
    _buffer.writeln('h');

    if (fillColor != null && strokeColor != null) {
      _buffer.writeln('B');
    } else if (fillColor != null) {
      _buffer.writeln('f');
    } else if (strokeColor != null) {
      _buffer.writeln('S');
    }
  }

  /// Desenha um [Path] vetorial arbitrário na página.
  void drawPath(Path path,
      {int? fillColor, int? strokeColor, double strokeWidth = 1.0}) {
    if (fillColor != null) setFillColor(fillColor);
    if (strokeColor != null) {
      setStrokeColor(strokeColor);
      setLineWidth(strokeWidth);
    }

    final polySink = _PdfPathPolySink(this);
    path.flattenTo(polySink);

    if (fillColor != null && strokeColor != null) {
      _buffer.writeln('B');
    } else if (fillColor != null) {
      _buffer.writeln('f');
    } else if (strokeColor != null) {
      _buffer.writeln('S');
    }
  }

  /// Desenha um texto posicionado com fonte e tamanho especificados.
  void drawText(String text, Offset position,
      {String fontName = 'F1',
      double fontSize = 12.0,
      int color = 0xFF000000}) {
    setFillColor(color);
    final escapedText = text
        .replaceAll('\\', '\\\\')
        .replaceAll('(', '\\(')
        .replaceAll(')', '\\)');
    final x = position.dx;
    final y = _pdfY(position.dy);

    _buffer.writeln('BT');
    _buffer.writeln('/$fontName $fontSize Tf');
    _buffer.writeln('$x $y Td');
    _buffer.writeln('($escapedText) Tj');
    _buffer.writeln('ET');
  }

  /// Retorna os bytes UTF-8 codificados do Content Stream.
  Uint8List toBytes() => Uint8List.fromList(utf8.encode(_buffer.toString()));
}

class _PdfPathPolySink implements PolylineSink {
  final PdfCanvasRecorder recorder;

  _PdfPathPolySink(this.recorder);

  @override
  void moveTo(double x, double y) {
    recorder._buffer.writeln('$x ${recorder._pdfY(y)} m');
  }

  @override
  void lineTo(double x, double y) {
    recorder._buffer.writeln('$x ${recorder._pdfY(y)} l');
  }

  @override
  void close() {
    recorder._buffer.writeln('h');
  }
}
