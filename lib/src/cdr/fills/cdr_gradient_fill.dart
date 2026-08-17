import 'cdr_fill.dart';

enum CdrGradientType { linear, radial, conical, square }

class CdrColorStop {
  final double position; // 0.0 to 1.0
  final int colorArgb; // 0xAARRGGBB

  const CdrColorStop(this.position, this.colorArgb);
}

/// Preenchimento de Gradiente do CorelDRAW (Fountain Fill).
class CdrGradientFill extends CdrFill {
  final CdrGradientType type;
  final List<CdrColorStop> stops;
  final double angle; // Ângulo em graus
  final double centerX; // Deslocamento do centro (0.0 a 1.0)
  final double centerY; // Deslocamento do centro (0.0 a 1.0)

  CdrGradientFill({
    required this.type,
    required this.stops,
    this.angle = 0.0,
    this.centerX = 0.5,
    this.centerY = 0.5,
  }) {
    stops.sort((a, b) => a.position.compareTo(b.position));
  }
}
