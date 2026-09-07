import 'dart:convert';
import 'dart:typed_data';

import '../../graphics/container/zip_archive.dart';

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
///
/// Casca fina sobre [ZipArchive], que mora em `graphics` porque três formatos
/// daqui são ZIP por baixo — `.cdr`, dotLottie e o que vier — e porque
/// `graphics` é a camada mais baixa que pode segurar um: o `inflate` já está
/// lá. Este tipo fica pelo nome, que é o que `cdr_document.dart` usa.
///
/// A troca corrigiu um defeito de verdade junto: o leitor antigo caminhava os
/// *local headers* da frente para trás e parava seco na primeira entrada com o
/// bit 3 das flags ligado, em que o tamanho comprimido no cabeçalho é zero e o
/// verdadeiro vem depois dos dados. Sem erro, devolvendo o que tinha alcançado.
/// O leitor novo lê o diretório central primeiro, que sempre traz os tamanhos.
class ZipCdrArchive {
  ZipCdrArchive._(this._archive);

  final ZipArchive _archive;

  Map<String, ZipCdrEntry> get entries => <String, ZipCdrEntry>{
        for (final ZipEntry entry in _archive.entries.values)
          entry.name: _wrap(entry),
      };

  /// Retorna a entrada pelo nome do caminho (ex: `content/root.dat`).
  ZipCdrEntry? operator [](String name) {
    final ZipEntry? entry = _archive[name];
    return entry == null ? null : _wrap(entry);
  }

  bool contains(String name) => _archive.contains(name);

  /// Abre e analisa o contêiner ZIP a partir dos bytes brutos.
  static ZipCdrArchive parse(Uint8List bytes) =>
      ZipCdrArchive._(ZipArchive.parse(bytes));

  static ZipCdrEntry _wrap(ZipEntry entry) => ZipCdrEntry(
        name: entry.name,
        compressionMethod: entry.compressionMethod,
        compressedSize: entry.compressedSize,
        uncompressedSize: entry.uncompressedSize,
        data: entry.data,
      );
}
