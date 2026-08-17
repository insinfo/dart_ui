/// Modelo de cor do CorelDRAW.
enum CdrColorModel {
  rgb,
  cmyk,
  pantone,
  hls,
  gray,
}

/// Cor resolvida do CorelDRAW com conversão para ARGB de 32 bits.
class CdrColor {
  final CdrColorModel model;
  final int colorArgb;
  final String? pantoneName;

  const CdrColor({
    required this.model,
    required this.colorArgb,
    this.pantoneName,
  });

  const CdrColor.rgb(int r, int g, int b, [int a = 255])
      : model = CdrColorModel.rgb,
        colorArgb = (a << 24) | (r << 16) | (g << 8) | b,
        pantoneName = null;

  factory CdrColor.cmyk(double c, double m, double y, double k,
      [double a = 1.0]) {
    final r = (255 * (1 - c) * (1 - k)).round().clamp(0, 255);
    final g = (255 * (1 - m) * (1 - k)).round().clamp(0, 255);
    final b = (255 * (1 - y) * (1 - k)).round().clamp(0, 255);
    final alpha = (a * 255).round().clamp(0, 255);
    return CdrColor(
      model: CdrColorModel.cmyk,
      colorArgb: (alpha << 24) | (r << 16) | (g << 8) | b,
    );
  }

  static const CdrColor black = CdrColor.rgb(0, 0, 0);
  static const CdrColor white = CdrColor.rgb(255, 255, 255);
  static const CdrColor transparent =
      CdrColor(model: CdrColorModel.rgb, colorArgb: 0x00000000);
}

/// Tipo de preenchimento do CorelDRAW.
enum CdrFillType {
  none,
  solid,
  linearGradient,
  radialGradient,
  conicalGradient,
  mesh,
  bitmapPattern,
}

/// Estilo de preenchimento vetorial do CorelDRAW.
class CdrFill {
  final CdrFillType type;
  final CdrColor solidColor;
  final List<CdrColor> gradientColors;
  final List<double> gradientStops;
  final double angle;

  const CdrFill({
    required this.type,
    this.solidColor = CdrColor.black,
    this.gradientColors = const [],
    this.gradientStops = const [],
    this.angle = 0.0,
  });

  const CdrFill.solid(CdrColor color)
      : type = CdrFillType.solid,
        solidColor = color,
        gradientColors = const [],
        gradientStops = const [],
        angle = 0.0;

  const CdrFill.none()
      : type = CdrFillType.none,
        solidColor = CdrColor.transparent,
        gradientColors = const [],
        gradientStops = const [],
        angle = 0.0;
}

/// Estilo de contorno (outline) do CorelDRAW.
class CdrOutline {
  final CdrColor color;
  final double width;
  final bool isBehindFill;

  const CdrOutline({
    this.color = CdrColor.black,
    this.width = 1.0,
    this.isBehindFill = false,
  });
}
