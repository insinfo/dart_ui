import 'dart:math' as math;
import '../../geometry/path.dart';

/// Define o tipo do nó vetorial do CorelDRAW.
enum CdrNodeType {
  /// Ponto que une linhas ou curvas sem restrição angular (cúspide/bico)
  cusp,

  /// Ponto que une curvas garantindo transição suave (C1 contínuo)
  smooth,

  /// Ponto que une curvas garantindo transição suave e simétrica (mesmo tamanho de alavancas)
  symmetrical
}

/// Avaliador e reconstrutor de curvas a partir de coordenadas comprimidas
/// extraídas do chunk `crve` (Curvas) do CorelDRAW.
class CdrBezierEvaluator {
  /// Converte dois pontos de controle e os nós ancorados em um comando cúbico de Bézier.
  /// No CorelDRAW legados, o formato armazena os nós (âncoras) e os pontos de controle (alavancas).
  static void cubicTo(PathBuilder builder, double x1, double y1, double x2,
      double y2, double x3, double y3) {
    builder.cubicTo(x1, y1, x2, y2, x3, y3);
  }

  /// Restaura o ponto de controle simétrico com base na alavanca anterior.
  static List<double> computeSymmetricalControlPoint(
      double anchorX, double anchorY, double prevCx, double prevCy) {
    final dx = anchorX - prevCx;
    final dy = anchorY - prevCy;
    return [anchorX + dx, anchorY + dy];
  }

  /// Restaura o ponto de controle suave garantindo a mesma angulação,
  /// mas preservando o tamanho original da nova alavanca (se conhecido).
  static List<double> computeSmoothControlPoint(double anchorX, double anchorY,
      double prevCx, double prevCy, double nextLength) {
    final dx = anchorX - prevCx;
    final dy = anchorY - prevCy;
    final len = math.sqrt(dx * dx + dy * dy);

    if (len == 0.0) {
      return [anchorX, anchorY];
    }

    final nx = dx / len;
    final ny = dy / len;

    return [anchorX + (nx * nextLength), anchorY + (ny * nextLength)];
  }
}
