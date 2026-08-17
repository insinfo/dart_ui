import '../../geometry/path.dart';
import 'pdf_matrix.dart';

/// Estilo de tampa de linha (Line Cap) do PDF.
enum PdfLineCap {
  butt, // 0
  round, // 1
  projectingSquare, // 2
}

/// Estilo de junção de linha (Line Join) do PDF.
enum PdfLineJoin {
  miter, // 0
  round, // 1
  bevel, // 2
}

/// Modo de renderização de texto do PDF (ISO 32000).
enum PdfTextRenderMode {
  fill, // 0
  stroke, // 1
  fillAndStroke, // 2
  invisible, // 3
  fillAndClip, // 4
  strokeAndClip, // 5
  fillStrokeAndClip, // 6
  clip, // 7
}

/// Estado gráfico completo do PDF (`PdfGfxState`) mantido na pilha de estados (`q` / `Q`).
class PdfGfxState {
  /// Matriz de transformação corrente (CTM - Current Transformation Matrix).
  PdfMatrix ctm;

  /// Cor de traçado (Stroking color em ARGB 32 bits).
  int strokeColor;

  /// Cor de preenchimento (Non-stroking color em ARGB 32 bits).
  int fillColor;

  /// Espessura da linha (em unidades do espaço de usuário).
  double lineWidth;

  /// Estilo de tampa da linha.
  PdfLineCap lineCap;

  /// Estilo de junção de cantos.
  PdfLineJoin lineJoin;

  /// Limite de miter para junções pontiagudas.
  double miterLimit;

  /// Padrão de traço tracejado (dashes e phase).
  List<double> dashPattern;
  double dashPhase;

  /// Opacidade de traçado (0.0 a 1.0, chave `/CA`).
  double strokeAlpha;

  /// Opacidade de preenchimento (0.0 a 1.0, chave `/ca`).
  double fillAlpha;

  // --- Estado de Texto ---
  /// Matriz de texto corrente (`Tm`).
  PdfMatrix textMatrix;

  /// Matriz de linha de texto corrente (`Tlm`).
  PdfMatrix textLineMatrix;

  /// Nome ou referência da fonte ativa.
  String? fontName;

  /// Tamanho da fonte ativa em pontos tipográficos.
  double fontSize;

  /// Espaçamento entre caracteres (`Tc`).
  double charSpacing;

  /// Espaçamento entre palavras (`Tw`).
  double wordSpacing;

  /// Escala horizontal do texto em porcentagem (`Tz`, 100 = normal).
  double horizontalScaling;

  /// Espaçamento entrelinhas (`TL` / Leading).
  double leading;

  /// Modo de renderização do texto.
  PdfTextRenderMode textRenderMode;

  /// Elevação do texto (`Ts` / Rise).
  double textRise;

  /// Caminho de recorte acumulado (Clipping path).
  Path? clipPath;

  PdfGfxState({
    this.ctm = PdfMatrix.identity,
    this.strokeColor = 0xFF000000,
    this.fillColor = 0xFF000000,
    this.lineWidth = 1.0,
    this.lineCap = PdfLineCap.butt,
    this.lineJoin = PdfLineJoin.miter,
    this.miterLimit = 10.0,
    this.dashPattern = const [],
    this.dashPhase = 0.0,
    this.strokeAlpha = 1.0,
    this.fillAlpha = 1.0,
    this.textMatrix = PdfMatrix.identity,
    this.textLineMatrix = PdfMatrix.identity,
    this.fontName,
    this.fontSize = 12.0,
    this.charSpacing = 0.0,
    this.wordSpacing = 0.0,
    this.horizontalScaling = 100.0,
    this.leading = 0.0,
    this.textRenderMode = PdfTextRenderMode.fill,
    this.textRise = 0.0,
    this.clipPath,
  });

  /// Clona o estado gráfico atual para empilhar em `q`.
  PdfGfxState clone() {
    return PdfGfxState(
      ctm: ctm,
      strokeColor: strokeColor,
      fillColor: fillColor,
      lineWidth: lineWidth,
      lineCap: lineCap,
      lineJoin: lineJoin,
      miterLimit: miterLimit,
      dashPattern: List<double>.from(dashPattern),
      dashPhase: dashPhase,
      strokeAlpha: strokeAlpha,
      fillAlpha: fillAlpha,
      textMatrix: textMatrix,
      textLineMatrix: textLineMatrix,
      fontName: fontName,
      fontSize: fontSize,
      charSpacing: charSpacing,
      wordSpacing: wordSpacing,
      horizontalScaling: horizontalScaling,
      leading: leading,
      textRenderMode: textRenderMode,
      textRise: textRise,
      clipPath: clipPath,
    );
  }
}
