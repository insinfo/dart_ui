import 'dart:typed_data';
import '../../pdf/io/byte_reader.dart';

/// Representação de um bloco (chunk) individual em um contêiner RIFF.
class RiffChunk {
  final String fourCC;
  final int length;
  final int offset;
  final String? listType;
  final List<RiffChunk> children;
  final Uint8List? data;

  const RiffChunk({
    required this.fourCC,
    required this.length,
    required this.offset,
    this.listType,
    this.children = const [],
    this.data,
  });

  bool get isContainer => fourCC == 'RIFF' || fourCC == 'LIST';

  /// Busca o primeiro filho correspondente a [targetFourCC].
  RiffChunk? findChild(String targetFourCC) {
    for (final child in children) {
      if (child.fourCC == targetFourCC || child.listType == targetFourCC) {
        return child;
      }
      final nested = child.findChild(targetFourCC);
      if (nested != null) return nested;
    }
    return null;
  }

  /// Busca todos os filhos correspondentes a [targetFourCC].
  List<RiffChunk> findChildren(String targetFourCC) {
    final results = <RiffChunk>[];
    for (final child in children) {
      if (child.fourCC == targetFourCC || child.listType == targetFourCC) {
        results.add(child);
      }
      results.addAll(child.findChildren(targetFourCC));
    }
    return results;
  }

  @override
  String toString() =>
      'RiffChunk($fourCC${listType != null ? ':$listType' : ''}, len: $length, children: ${children.length})';
}

/// Analisador sintático de contêineres binários RIFF (CorelDRAW v3 a v13 e CMX).
class RiffReader {
  final ByteReader reader;

  RiffReader(Uint8List buffer) : reader = ByteReader(buffer);

  /// Lê a raiz do contêiner RIFF.
  RiffChunk parse() {
    if (reader.length < 8) {
      throw const FormatException(
          'Arquivo muito pequeno para ser um contêiner RIFF válido.');
    }

    final magic = _readFourCC();
    if (magic != 'RIFF') {
      throw FormatException(
          'Cabeçalho inválido: esperado "RIFF", obtido "$magic".');
    }

    final totalLength = reader.readUint32LE();
    final riffType = _readFourCC();

    final children = _readChildren(reader.offset, totalLength - 4);

    return RiffChunk(
      fourCC: 'RIFF',
      length: totalLength,
      offset: 0,
      listType: riffType,
      children: children,
    );
  }

  List<RiffChunk> _readChildren(int startOffset, int byteLimit) {
    final children = <RiffChunk>[];
    final endOffset = (startOffset + byteLimit <= reader.length)
        ? startOffset + byteLimit
        : reader.length;

    while (reader.offset + 8 <= endOffset) {
      final chunkOffset = reader.offset;
      final fourCC = _readFourCC();
      final length = reader.readUint32LE();

      if (fourCC == 'LIST') {
        final listType = _readFourCC();
        final subLength = length > 4 ? length - 4 : 0;
        final subChildren = _readChildren(reader.offset, subLength);
        children.add(RiffChunk(
          fourCC: 'LIST',
          length: length,
          offset: chunkOffset,
          listType: listType,
          children: subChildren,
        ));
      } else {
        final safeLength = (reader.offset + length <= reader.length)
            ? length
            : (reader.length - reader.offset);
        final data = reader.readBytes(safeLength);
        children.add(RiffChunk(
          fourCC: fourCC,
          length: length,
          offset: chunkOffset,
          data: data,
        ));

        // Alinhamento de palavra de 2 bytes padrão do RIFF
        if (length % 2 != 0 && !reader.isEOF) {
          reader.readUint8();
        }
      }
    }

    return children;
  }

  String _readFourCC() {
    final b1 = reader.readUint8();
    final b2 = reader.readUint8();
    final b3 = reader.readUint8();
    final b4 = reader.readUint8();
    return String.fromCharCodes([b1, b2, b3, b4]);
  }
}
