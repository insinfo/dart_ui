import 'dart:convert';
import 'dart:typed_data';
import '../../graphics/image/inflate.dart';
import '../../pdf/io/byte_reader.dart';

/// Arquivo individual contido em um pacote CorelDRAW moderno baseado em ZIP (CDR X4 a 2024).
class ZipCdrEntry {
  final String name;
  final int compressionMethod; // 0 = Stored, 8 = Deflated
  final int compressedSize;
  final int uncompressedSize;
  final Uint8List data;

  const ZipCdrEntry({
    required this.name,
    required this.compressionMethod,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.data,
  });

  String readAsString() => utf8.decode(data, allowMalformed: true);

  @override
  String toString() => 'ZipCdrEntry($name, size: $uncompressedSize bytes)';
}

/// Leitor e extrator de contêineres ZIP em Puro Dart para arquivos CorelDRAW (.cdr).
class ZipCdrArchive {
  final Map<String, ZipCdrEntry> _entries = {};

  Map<String, ZipCdrEntry> get entries => _entries;

  /// Retorna a entrada pelo nome do caminho (ex: `content/root.dat`, `content/riffData.dat`).
  ZipCdrEntry? operator [](String name) => _entries[name];

  bool contains(String name) => _entries.containsKey(name);

  /// Abre e analisa o contêiner ZIP a partir dos bytes brutos.
  static ZipCdrArchive parse(Uint8List bytes) {
    final archive = ZipCdrArchive();
    final reader = ByteReader(bytes);

    while (reader.remaining >= 30) {
      final sig = reader.readUint32LE();
      if (sig != 0x04034B50) {
        // Não é mais uma assinatura de Local File Header (PK\x03\x04)
        break;
      }

      reader.skip(2); // Version needed
      final flags = reader.readUint16LE();
      final method = reader.readUint16LE();
      reader.skip(4); // Mod time & date
      reader.skip(4); // CRC32
      final compSize = reader.readUint32LE();
      final uncompSize = reader.readUint32LE();
      final fileNameLen = reader.readUint16LE();
      final extraFieldLen = reader.readUint16LE();

      final fileNameBytes = reader.readBytes(fileNameLen);
      final fileName = String.fromCharCodes(fileNameBytes);

      reader.skip(extraFieldLen);

      if (compSize > 0 && reader.remaining >= compSize) {
        final compData = reader.readBytes(compSize);
        Uint8List decompressed;

        if (method == 0) {
          // Stored (sem compressão)
          decompressed = compData;
        } else if (method == 8) {
          // DEFLATE
          try {
            decompressed = inflate(
              compData,
              maxOutputBytes: 128 * 1024 * 1024,
              budget: 'zip_cdr_entry',
            );
          } catch (_) {
            decompressed = compData;
          }
        } else {
          decompressed = compData;
        }

        archive._entries[fileName] = ZipCdrEntry(
          name: fileName,
          compressionMethod: method,
          compressedSize: compSize,
          uncompressedSize: uncompSize,
          data: decompressed,
        );
      } else {
        // Entrada de diretório ou tamanho desconhecido no local header
        if ((flags & 0x08) != 0) {
          // Data descriptor segue os dados
          break;
        }
      }
    }

    return archive;
  }
}
