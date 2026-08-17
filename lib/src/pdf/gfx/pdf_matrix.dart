import 'dart:math' as math;
import '../../geometry/offset.dart';

/// Matriz de transformação afim 2D 3x3 no espaço de coordenadas do PDF [a, b, c, d, e, f].
///
/// | a  b  0 |
/// | c  d  0 |
/// | e  f  1 |
class PdfMatrix {
  final double a;
  final double b;
  final double c;
  final double d;
  final double e;
  final double f;

  const PdfMatrix(this.a, this.b, this.c, this.d, this.e, this.f);

  /// Matriz identidade [1, 0, 0, 1, 0, 0].
  static const PdfMatrix identity = PdfMatrix(1.0, 0.0, 0.0, 1.0, 0.0, 0.0);

  /// Cria uma matriz de translação.
  factory PdfMatrix.translation(double tx, double ty) {
    return PdfMatrix(1.0, 0.0, 0.0, 1.0, tx, ty);
  }

  /// Cria uma matriz de escala.
  factory PdfMatrix.scale(double sx, double sy) {
    return PdfMatrix(sx, 0.0, 0.0, sy, 0.0, 0.0);
  }

  /// Cria uma matriz de rotação em radianos.
  factory PdfMatrix.rotation(double angleRadians) {
    final cosA = math.cos(angleRadians);
    final sinA = math.sin(angleRadians);
    return PdfMatrix(cosA, sinA, -sinA, cosA, 0.0, 0.0);
  }

  /// Multiplicação de matrizes afins (this * other).
  PdfMatrix multiply(PdfMatrix other) {
    return PdfMatrix(
      a * other.a + b * other.c,
      a * other.b + b * other.d,
      c * other.a + d * other.c,
      c * other.b + d * other.d,
      e * other.a + f * other.c + other.e,
      e * other.b + f * other.d + other.f,
    );
  }

  /// Transforma um ponto 2D (x, y).
  Offset transformPoint(double x, double y) {
    return Offset(
      a * x + c * y + e,
      b * x + d * y + f,
    );
  }

  /// Determinante da matriz 2D.
  double get determinant => a * d - b * c;

  /// Inverte a matriz afim. Retorna `null` se for singular.
  PdfMatrix? invert() {
    final det = determinant;
    if (det.abs() < 1e-12) return null;

    final invDet = 1.0 / det;
    return PdfMatrix(
      d * invDet,
      -b * invDet,
      -c * invDet,
      a * invDet,
      (c * f - d * e) * invDet,
      (b * e - a * f) * invDet,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PdfMatrix &&
          a == other.a &&
          b == other.b &&
          c == other.c &&
          d == other.d &&
          e == other.e &&
          f == other.f;

  @override
  int get hashCode => Object.hash(a, b, c, d, e, f);

  @override
  String toString() => 'PdfMatrix([$a, $b, $c, $d, $e, $f])';
}
