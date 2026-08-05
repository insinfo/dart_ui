/// Cor ARGB (canal alpha explícito) usada pelo renderer BGRA do MVP-01.
library;

final class Color {
  const Color(this.a, this.r, this.g, this.b);

  const Color.opaque(int r, int g, int b) : this(255, r, g, b);

  /// Branco e pretos auxiliares.
  static const Color white = Color.opaque(255, 255, 255);
  static const Color black = Color.opaque(0, 0, 0);
  static const Color transparent = Color(0, 0, 0, 0);

  final int a;
  final int r;
  final int g;
  final int b;

  /// Empacota em BGRA (ordem do framebuffer).
  int get packedBgra => b | (g << 8) | (r << 16) | (a << 24);

  /// Combina [this] sobre [below] (source-over, canais não premultiplicados).
  Color over(Color below) {
    final alpha = a / 255;
    final inv = 1 - alpha;
    return Color(
      (a + below.a * inv).round().clamp(0, 255),
      (r * alpha + below.r * inv).round().clamp(0, 255),
      (g * alpha + below.g * inv).round().clamp(0, 255),
      (b * alpha + below.b * inv).round().clamp(0, 255),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Color &&
      other.a == a &&
      other.r == r &&
      other.g == g &&
      other.b == b;

  @override
  int get hashCode => Object.hash(a, r, g, b);

  @override
  String toString() => 'Color(0x${a.toRadixString(16).padLeft(2, '0')}'
      '${r.toRadixString(16).padLeft(2, '0')}'
      '${g.toRadixString(16).padLeft(2, '0')}'
      '${b.toRadixString(16).padLeft(2, '0')})';
}
