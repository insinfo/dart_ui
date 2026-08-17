import 'dart:typed_data';
import '../../geometry/path.dart';
import '../../pdf/io/byte_reader.dart';

/// Tipo de nó de curva do CorelDRAW.
enum CdrNodeType {
  moveTo,
  lineTo,
  cubicTo,
}

/// Nó vetorial individual com coordenadas e flags de controle do CorelDRAW.
class CdrNode {
  final CdrNodeType type;
  final double x;
  final double y;
  final double? cx1;
  final double? cy1;
  final double? cx2;
  final double? cy2;
  final bool isClosed;
  final bool isSmooth;
  final bool isCusp;
  final bool isSymmetrical;

  const CdrNode({
    required this.type,
    required this.x,
    required this.y,
    this.cx1,
    this.cy1,
    this.cx2,
    this.cy2,
    this.isClosed = false,
    this.isSmooth = false,
    this.isCusp = false,
    this.isSymmetrical = false,
  });

  @override
  String toString() => 'CdrNode($type, at: ($x, $y), closed: $isClosed)';
}

/// Reconstrutor de caminhos vetoriais do CorelDRAW (chunks `crve` / `path`) em Puro Dart.
class CdrPath {
  final List<CdrNode> nodes;

  const CdrPath(this.nodes);

  /// Converte a sequência de nós do CorelDRAW em um [Path] nativo do `dart_ui`.
  Path toPath(
      {double scaleX = 1.0,
      double scaleY = 1.0,
      double offsetX = 0.0,
      double offsetY = 0.0}) {
    final builder = PathBuilder();

    for (final node in nodes) {
      final x = node.x * scaleX + offsetX;
      final y = node.y * scaleY + offsetY;

      switch (node.type) {
        case CdrNodeType.moveTo:
          builder.moveTo(x, y);
          break;
        case CdrNodeType.lineTo:
          builder.lineTo(x, y);
          break;
        case CdrNodeType.cubicTo:
          final cx1 = (node.cx1 ?? node.x) * scaleX + offsetX;
          final cy1 = (node.cy1 ?? node.y) * scaleY + offsetY;
          final cx2 = (node.cx2 ?? node.x) * scaleX + offsetX;
          final cy2 = (node.cy2 ?? node.y) * scaleY + offsetY;
          builder.cubicTo(cx1, cy1, cx2, cy2, x, y);
          break;
      }

      if (node.isClosed) {
        builder.close();
      }
    }

    return builder.build();
  }

  /// Decodifica um chunk de curva binário `crve` do CorelDRAW.
  static CdrPath parseCrveChunk(Uint8List data, {int version = 6}) {
    final nodes = <CdrNode>[];
    if (data.length < 4) return CdrPath(nodes);

    final reader = ByteReader(data);
    final pointCount = reader.readUint16LE();

    for (var i = 0; i < pointCount && reader.remaining >= 12; i++) {
      final nodeTypeFlag = reader.readUint8();
      final nodePropsFlag = reader.readUint8();
      reader.skip(2); // Alinhamento / reserva

      final x =
          reader.readFloat32BE(); // Coordenada X (ou inteira fixa em v3..v5)
      final y = reader.readFloat32BE(); // Coordenada Y

      final isMoveTo = (nodeTypeFlag & 0x01) != 0 || i == 0;
      final isCubic = (nodeTypeFlag & 0x02) != 0;
      final isClosed = (nodeTypeFlag & 0x04) != 0;

      final isSmooth = (nodePropsFlag & 0x01) != 0;
      final isCusp = (nodePropsFlag & 0x02) != 0;
      final isSymmetrical = (nodePropsFlag & 0x04) != 0;

      if (isMoveTo) {
        nodes.add(CdrNode(
          type: CdrNodeType.moveTo,
          x: x,
          y: y,
          isClosed: isClosed,
          isSmooth: isSmooth,
          isCusp: isCusp,
          isSymmetrical: isSymmetrical,
        ));
      } else if (isCubic && reader.remaining >= 16) {
        final cx1 = reader.readFloat32BE();
        final cy1 = reader.readFloat32BE();
        final cx2 = reader.readFloat32BE();
        final cy2 = reader.readFloat32BE();
        nodes.add(CdrNode(
          type: CdrNodeType.cubicTo,
          x: x,
          y: y,
          cx1: cx1,
          cy1: cy1,
          cx2: cx2,
          cy2: cy2,
          isClosed: isClosed,
          isSmooth: isSmooth,
          isCusp: isCusp,
          isSymmetrical: isSymmetrical,
        ));
      } else {
        nodes.add(CdrNode(
          type: CdrNodeType.lineTo,
          x: x,
          y: y,
          isClosed: isClosed,
          isSmooth: isSmooth,
          isCusp: isCusp,
          isSymmetrical: isSymmetrical,
        ));
      }
    }

    return CdrPath(nodes);
  }
}
