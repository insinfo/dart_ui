import '../../geometry/offset.dart';
import 'cdr_fill.dart';

/// Um nó da malha (Mesh Node).
class CdrMeshNode {
  final Offset point;
  final int colorArgb; // Cor no nó

  const CdrMeshNode(this.point, this.colorArgb);
}

/// Preenchimento de Malha Gradiente do CorelDRAW (Mesh Fill).
/// O CorelDRAW suporta malhas de Bézier 2D onde cada nó possui uma cor independente,
/// e a renderização interpola essas cores via Coons patch ou interpolação bilinear.
class CdrMeshFill extends CdrFill {
  final int numRows;
  final int numCols;
  final List<CdrMeshNode> nodes;

  CdrMeshFill(this.numRows, this.numCols, this.nodes) {
    assert(nodes.length == (numRows + 1) * (numCols + 1),
        'Tamanho inválido de nós da malha');
  }

  /// Retorna as posições dos vértices (sem dependência de ui.Vertices) para uso
  /// no renderizador base do projeto.
  List<Offset> getPositions() {
    return nodes.map((n) => n.point).toList();
  }
}
