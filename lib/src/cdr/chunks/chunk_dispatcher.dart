import 'dart:typed_data';
import 'chunk_fourcc.dart';

/// Define o cabeçalho base de um bloco (Chunk) extraído de um arquivo CDR.
class CdrChunk {
  final int id;
  final int size;
  final int offset;

  CdrChunk(this.id, this.size, this.offset);

  String get idString => CdrFourCC.asString(id);

  @override
  String toString() => 'CdrChunk($idString, size: $size bytes)';
}

/// O Despachante itera por um array de bytes do CorelDRAW extraindo
/// a árvore hierárquica (ou lista plana) de chunks usando o formato RIFF.
class CdrChunkDispatcher {
  final ByteData data;

  CdrChunkDispatcher(this.data);

  /// Itera sobre os blocos filhos e aciona o [onChunk] para cada um encontrado.
  /// Para blocos `LIST` (que contêm filhos), invoca [onList].
  void dispatch(
    int offset,
    int length, {
    required void Function(CdrChunk chunk, ByteData payload) onChunk,
    required void Function(int listType, int listOffset, int listLength) onList,
  }) {
    int current = offset;
    final end = offset + length;

    while (current + 8 <= end) {
      final chunkId = data.getUint32(current, Endian.little);
      final chunkSize = data.getUint32(current + 4, Endian.little);

      // O tamanho reportado no RIFF geralmente precisa ser alinhado a word (par).
      final alignedSize = (chunkSize + 1) & ~1;

      if (current + 8 + alignedSize > end) {
        break; // Arquivo truncado ou erro de parsing
      }

      if (chunkId == CdrFourCC.list) {
        // Bloco LIST tem um FourCC extra de 4 bytes indicando o tipo (ex: 'page', 'grp ')
        if (chunkSize >= 4) {
          final listType = data.getUint32(current + 8, Endian.little);
          onList(listType, current + 12, chunkSize - 4);
        }
      } else {
        // Chunk de dados primitivos
        final payload = ByteData.view(
            data.buffer, data.offsetInBytes + current + 8, chunkSize);
        onChunk(CdrChunk(chunkId, chunkSize, current), payload);
      }

      current += 8 + alignedSize;
    }
  }
}
