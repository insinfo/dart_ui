import 'dart:typed_data';
import '../../geometry/rect.dart';
import '../../graphics/vector/document.dart';
import '../container/riff_reader.dart';
import '../container/zip_cdr_archive.dart';
import '../geometry/cdr_path.dart';
import 'cdr_translator.dart';

/// Versão identificada do arquivo CorelDRAW.
enum CdrVersion {
  v3('CorelDRAW 3'),
  v4('CorelDRAW 4'),
  v5('CorelDRAW 5'),
  v6('CorelDRAW 6'),
  v7('CorelDRAW 7'),
  v8('CorelDRAW 8'),
  v9('CorelDRAW 9'),
  v10('CorelDRAW 10'),
  v11('CorelDRAW 11'),
  v12('CorelDRAW 12'),
  v13('CorelDRAW X3 (v13)'),
  v14('CorelDRAW X4 (v14)'),
  v15('CorelDRAW X5 (v15)'),
  v16('CorelDRAW X6 (v16)'),
  v17('CorelDRAW X7 (v17)'),
  v18('CorelDRAW X8 (v18)'),
  v19('CorelDRAW 2017 (v19)'),
  v20('CorelDRAW 2018 (v20)'),
  v21('CorelDRAW 2019 (v21)'),
  v22('CorelDRAW 2020 (v22)'),
  v23('CorelDRAW 2021 (v23)'),
  v24('CorelDRAW 2022 (v24)'),
  v25('CorelDRAW 2023/2024 (v25+)'),
  cmx('Corel Presentation Exchange (CMX)'),
  unknown('CorelDRAW Desconhecido');

  final String displayName;
  const CdrVersion(this.displayName);
}

/// Documento CorelDRAW vetorial unificado para leitura e renderização no `dart_ui`.
class CdrDocument {
  final Uint8List rawBytes;
  final CdrVersion version;
  final List<CdrPath> paths;
  final Rect bounds;

  const CdrDocument._({
    required this.rawBytes,
    required this.version,
    required this.paths,
    required this.bounds,
  });

  /// Abre e analisa um arquivo CorelDRAW (.cdr ou .cmx) a partir de seus bytes em memória.
  factory CdrDocument.fromBytes(Uint8List bytes) {
    if (bytes.length < 8) {
      throw const FormatException(
          'Arquivo CorelDRAW corrompido ou menor que o cabeçalho mínimo.');
    }

    // 1. Verifica se é contêiner ZIP moderno (PK\x03\x04)
    if (bytes[0] == 0x50 &&
        bytes[1] == 0x4B &&
        bytes[2] == 0x03 &&
        bytes[3] == 0x04) {
      return _parseZipCdr(bytes);
    }

    // 2. Verifica se é contêiner binário RIFF clássico
    if (bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46) {
      return _parseRiffCdr(bytes);
    }

    throw const FormatException(
        'Assinatura de arquivo não reconhecida como CorelDRAW (nem RIFF nem ZIP).');
  }

  static CdrDocument _parseZipCdr(Uint8List bytes) {
    final zip = ZipCdrArchive.parse(bytes);
    final paths = <CdrPath>[];

    // Inspeciona chunks de dados vetoriais em 'content/riffData.dat' ou 'content/root.dat'
    final riffEntry = zip['content/riffData.dat'] ?? zip['content/root.dat'];
    if (riffEntry != null) {
      try {
        final riff = RiffReader(riffEntry.data).parse();
        final crveChunks = riff.findChildren('crve');
        for (final chunk in crveChunks) {
          if (chunk.data != null) {
            paths.add(CdrPath.parseCrveChunk(chunk.data!));
          }
        }
      } catch (_) {
        // Fallback tolerante
      }
    }

    return CdrDocument._(
      rawBytes: bytes,
      version: CdrVersion.v25,
      paths: paths,
      bounds: const Rect.fromLTWH(0, 0, 800, 600),
    );
  }

  static CdrDocument _parseRiffCdr(Uint8List bytes) {
    final reader = RiffReader(bytes);
    final root = reader.parse();

    var version = CdrVersion.unknown;
    if (root.listType != null) {
      final type = root.listType!;
      if (type.startsWith('CDR')) {
        final verNumStr = type.substring(3).trim();
        final verNum = int.tryParse(verNumStr);
        if (verNum != null && verNum >= 3 && verNum <= 25) {
          version = CdrVersion.values.firstWhere(
            (v) => v.name == 'v$verNum',
            orElse: () => CdrVersion.unknown,
          );
        } else {
          version = CdrVersion.v6;
        }
      } else if (type.startsWith('CMX')) {
        version = CdrVersion.cmx;
      }
    }

    final paths = <CdrPath>[];
    final crveChunks = root.findChildren('crve');
    for (final chunk in crveChunks) {
      if (chunk.data != null) {
        paths.add(CdrPath.parseCrveChunk(chunk.data!));
      }
    }

    return CdrDocument._(
      rawBytes: bytes,
      version: version,
      paths: paths,
      bounds: const Rect.fromLTWH(0, 0, 800, 600),
    );
  }

  /// Nome legível da versão do CorelDRAW.
  String get versionName => version.displayName;

  /// Converte este documento CorelDRAW para o modelo de documento unificado [VectorDocument].
  VectorDocument toVectorDocument() => CdrTranslator.toVectorDocument(this);

  /// Cria um [CdrDocument] a partir de um [VectorDocument] e codifica em bytes nativos CDR.
  static CdrDocument fromVectorDocument(VectorDocument doc,
      {CdrVersion version = CdrVersion.v6}) {
    final bytes = CdrTranslator.toCdrBytes(doc, version: version);
    return CdrDocument.fromBytes(bytes);
  }

  @override
  String toString() =>
      'CdrDocument(version: $versionName, paths: ${paths.length})';
}
