import '../../geometry/path.dart';
import '../format/pdf_object.dart';
import 'pdf_color_space.dart';
import 'pdf_function.dart';
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

/// Standard PDF blend modes (ISO 32000-2, 11.3.5).
enum PdfBlendMode {
  normal,
  multiply,
  screen,
  overlay,
  darken,
  lighten,
  colorDodge,
  colorBurn,
  hardLight,
  softLight,
  difference,
  exclusion,
  hue,
  saturation,
  color,
  luminosity,
}

enum PdfSoftMaskSubtype { alpha, luminosity }

/// Parsed soft-mask definition from an ExtGState `/SMask` dictionary.
final class PdfSoftMask {
  const PdfSoftMask({
    required this.subtype,
    required this.group,
    this.backgroundColor = const <double>[],
    this.transferFunction,
  });

  final PdfSoftMaskSubtype subtype;
  final PdfStream group;
  final List<double> backgroundColor;
  final PdfFunction? transferFunction;
}

/// Parameters of a Form XObject transparency group.
final class PdfTransparencyGroup {
  const PdfTransparencyGroup({
    required this.form,
    this.colorSpace,
    this.isolated = false,
    this.knockout = false,
  });

  final PdfStream form;
  final PdfColorSpace? colorSpace;
  final bool isolated;
  final bool knockout;
}

/// Estado gráfico completo do PDF (`PdfGfxState`) mantido na pilha de estados (`q` / `Q`).
class PdfGfxState {
  /// Matriz de transformação corrente (CTM - Current Transformation Matrix).
  PdfMatrix ctm;

  /// Cor de traçado (Stroking color em ARGB 32 bits).
  int strokeColor;

  /// Cor de preenchimento (Non-stroking color em ARGB 32 bits).
  int fillColor;

  /// Active stroking color space, changed by `CS`, `G`, `RG`, and `K`.
  PdfColorSpace strokeColorSpace;

  /// Active non-stroking color space, changed by `cs`, `g`, `rg`, and `k`.
  PdfColorSpace fillColorSpace;

  /// Whether the selected stroking color space can be converted by this engine.
  bool strokeColorSpaceSupported;

  /// Whether the selected non-stroking color space can be converted by this engine.
  bool fillColorSpaceSupported;

  String? strokePatternName;
  String? fillPatternName;
  List<double> strokePatternComponents;
  List<double> fillPatternComponents;

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

  /// Current compositing blend mode.
  PdfBlendMode blendMode;

  /// Original unsupported `/BM` name, when no standard mode could be selected.
  String? unsupportedBlendMode;

  /// Current soft mask, or null for `/SMask /None`.
  PdfSoftMask? softMask;

  /// Diagnostic for a malformed or unsupported `/SMask` entry.
  String? unsupportedSoftMaskReason;

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
    PdfColorSpace? strokeColorSpace,
    PdfColorSpace? fillColorSpace,
    this.strokeColorSpaceSupported = true,
    this.fillColorSpaceSupported = true,
    this.strokePatternName,
    this.fillPatternName,
    this.strokePatternComponents = const <double>[],
    this.fillPatternComponents = const <double>[],
    this.lineWidth = 1.0,
    this.lineCap = PdfLineCap.butt,
    this.lineJoin = PdfLineJoin.miter,
    this.miterLimit = 10.0,
    this.dashPattern = const [],
    this.dashPhase = 0.0,
    this.strokeAlpha = 1.0,
    this.fillAlpha = 1.0,
    this.blendMode = PdfBlendMode.normal,
    this.unsupportedBlendMode,
    this.softMask,
    this.unsupportedSoftMaskReason,
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
  })  : strokeColorSpace = strokeColorSpace ?? PdfDeviceGray(),
        fillColorSpace = fillColorSpace ?? PdfDeviceGray();

  /// Clona o estado gráfico atual para empilhar em `q`.
  PdfGfxState clone() {
    return PdfGfxState(
      ctm: ctm,
      strokeColor: strokeColor,
      fillColor: fillColor,
      strokeColorSpace: strokeColorSpace,
      fillColorSpace: fillColorSpace,
      strokeColorSpaceSupported: strokeColorSpaceSupported,
      fillColorSpaceSupported: fillColorSpaceSupported,
      strokePatternName: strokePatternName,
      fillPatternName: fillPatternName,
      strokePatternComponents: List<double>.from(strokePatternComponents),
      fillPatternComponents: List<double>.from(fillPatternComponents),
      lineWidth: lineWidth,
      lineCap: lineCap,
      lineJoin: lineJoin,
      miterLimit: miterLimit,
      dashPattern: List<double>.from(dashPattern),
      dashPhase: dashPhase,
      strokeAlpha: strokeAlpha,
      fillAlpha: fillAlpha,
      blendMode: blendMode,
      unsupportedBlendMode: unsupportedBlendMode,
      softMask: softMask,
      unsupportedSoftMaskReason: unsupportedSoftMaskReason,
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
