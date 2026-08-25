import 'dart:typed_data';
import '../io/byte_reader.dart';
import 'pdf_lexer.dart';
import 'pdf_limits.dart';
import 'pdf_object.dart';
import 'pdf_parser.dart';

/// Tipo de entrada na tabela XRef do PDF.
enum PdfXRefEntryType {
  free, // Tipo 0: Objeto livre
  uncompressed, // Tipo 1: Objeto descompactado no byte offset especificado
  compressed, // Tipo 2: Objeto dentro de um /ObjStm
}

/// Entrada individual na tabela de referências cruzadas.
class PdfXRefEntry {
  final int objNum;
  final int genNum;
  final int offset;
  final int streamObjNum; // Usado para objetos comprimidos (Tipo 2)
  final int indexInStream;
  final PdfXRefEntryType type;

  const PdfXRefEntry({
    required this.objNum,
    required this.genNum,
    required this.offset,
    this.streamObjNum = 0,
    this.indexInStream = 0,
    required this.type,
  });

  @override
  String toString() =>
      'PdfXRefEntry($objNum $genNum -> type: $type, offset: $offset)';
}

/// Tabela de referências cruzadas e gerenciador de resolução de objetos PDF em Puro Dart.
class PdfXRefTable implements PdfResolver {
  final ByteReader reader;
  final Map<int, PdfXRefEntry> _entries = {};
  final Map<int, PdfObject> _objectCache = {};
  final Set<int> _resolvingObjects = <int>{};
  PdfDict? trailer;
  final PdfLimits limits;

  PdfXRefTable(this.reader, {this.limits = const PdfLimits()});

  Map<int, PdfXRefEntry> get entries => _entries;

  /// Adiciona ou atualiza uma entrada de objeto.
  void addEntry(PdfXRefEntry entry) {
    _entries[entry.objNum] = entry;
  }

  /// Retorna a entrada XRef para o ID de objeto informado.
  PdfXRefEntry? getEntry(int objNum) => _entries[objNum];

  /// Carrega toda a estrutura XRef iniciando a partir do fim do arquivo (`startxref`).
  void load() {
    final startXRefOffset = _findStartXRef();
    if (startXRefOffset == -1) {
      _reconstructCorruptXRef();
      _recoverTrailerFromCatalog();
      return;
    }
    try {
      _readXRefChain(startXRefOffset);
      if (trailer == null) {
        throw PdfFormatException(
          'xref chain has no usable trailer',
          offset: startXRefOffset,
        );
      }
    } on PdfFormatException {
      _repair();
    } on RangeError {
      _repair();
    } on StateError {
      _repair();
    }
  }

  void _repair() {
    _entries.clear();
    _objectCache.clear();
    _resolvingObjects.clear();
    trailer = null;
    _reconstructCorruptXRef();
    _recoverTrailerFromCatalog();
  }

  int _findStartXRef() {
    final buffer = reader.buffer;
    final searchLength = buffer.length > 2048 ? 2048 : buffer.length;
    final startIndex = buffer.length - searchLength;

    for (var i = buffer.length - 9; i >= startIndex; i--) {
      if (buffer[i] == 0x73 && // s
          buffer[i + 1] == 0x74 && // t
          buffer[i + 2] == 0x61 && // a
          buffer[i + 3] == 0x72 && // r
          buffer[i + 4] == 0x74 && // t
          buffer[i + 5] == 0x78 && // x
          buffer[i + 6] == 0x72 && // r
          buffer[i + 7] == 0x65 && // e
          buffer[i + 8] == 0x66) {
        // 'startxref' encontrado
        reader.offset = i + 9;
        final lexer = PdfLexer(reader);
        final token = lexer.nextToken();
        if (token.type == PdfTokenType.number && token.numberValue != null) {
          return token.numberValue!.toInt();
        }
      }
    }
    return -1;
  }

  void _readXRefChain(int initialOffset) {
    var currentOffset = initialOffset;
    final visitedOffsets = <int>{};

    while (currentOffset > 0 && currentOffset < reader.length) {
      if (!visitedOffsets.add(currentOffset)) {
        throw PdfFormatException(
          'cyclic /Prev chain at xref offset $currentOffset',
          offset: currentOffset,
        );
      }
      if (visitedOffsets.length > limits.maxXRefSections) {
        throw PdfFormatException(
          'xref chain exceeds ${limits.maxXRefSections} sections',
          offset: currentOffset,
        );
      }
      reader.offset = currentOffset;
      final lexer = PdfLexer(reader);
      final token = lexer.nextToken();

      if (token.isKeyword('xref')) {
        // Tabela XRef clássica em texto
        final hasTrailer = _readClassicXRefTable(lexer);
        if (hasTrailer) {
          final parser = PdfParser(lexer);
          final parsedTrailer = parser.parseObject()?.asDict();
          if (parsedTrailer != null) {
            trailer ??= parsedTrailer;

            final prev = parsedTrailer.getNumber('Prev');
            if (prev != null &&
                prev.toInt() > 0 &&
                prev.toInt() != currentOffset) {
              currentOffset = prev.toInt();
              continue;
            }
          }
        }
        break;
      } else if (token.type == PdfTokenType.number) {
        // XRef Stream comprimido (PDF 1.5+)
        reader.offset = currentOffset;
        final parser = PdfParser(lexer);
        final streamObj = parser.parseObject();
        if (streamObj is PdfStream) {
          trailer ??= streamObj.dict;
          _readXRefStream(streamObj);

          final prev = streamObj.dict.getNumber('Prev');
          if (prev != null &&
              prev.toInt() > 0 &&
              prev.toInt() != currentOffset) {
            currentOffset = prev.toInt();
            continue;
          }
        }
        break;
      } else {
        throw PdfFormatException(
          'startxref does not point to an xref table or stream',
          offset: currentOffset,
        );
      }
    }
  }

  bool _readClassicXRefTable(PdfLexer lexer) {
    while (true) {
      final t1 = lexer.nextToken();
      if (t1.isKeyword('trailer')) {
        return true;
      }
      if (t1.type == PdfTokenType.eof) {
        return false;
      }

      final t2 = lexer.nextToken();
      if (t1.type != PdfTokenType.number || t2.type != PdfTokenType.number) {
        break;
      }

      final startObjNum = t1.numberValue!.toInt();
      final count = t2.numberValue!.toInt();
      if (startObjNum < 0 || count < 0 || count > limits.maxXRefEntries) {
        throw PdfFormatException(
          'invalid xref subsection $startObjNum $count',
          offset: lexer.reader.offset,
        );
      }
      if (_entries.length + count > limits.maxXRefEntries) {
        throw PdfFormatException(
          'xref exceeds ${limits.maxXRefEntries} entries',
          offset: lexer.reader.offset,
        );
      }

      for (var i = 0; i < count; i++) {
        final offsetToken = lexer.nextToken();
        final genToken = lexer.nextToken();
        final flagToken = lexer.nextToken();

        if (offsetToken.type != PdfTokenType.number ||
            genToken.type != PdfTokenType.number) {
          break;
        }

        final offset = offsetToken.numberValue!.toInt();
        final gen = genToken.numberValue!.toInt();
        final isUsed = flagToken.text == 'n';

        final objNum = startObjNum + i;
        if (isUsed && !_entries.containsKey(objNum)) {
          addEntry(PdfXRefEntry(
            objNum: objNum,
            genNum: gen,
            offset: offset,
            type: PdfXRefEntryType.uncompressed,
          ));
        }
      }
    }
    return false;
  }

  void _readXRefStream(PdfStream stream) {
    final dict = stream.dict;
    final size = dict.getNumber('Size')?.toInt() ?? 0;
    final wArray = dict.getArray('W');
    if (wArray == null || wArray.length < 3) return;

    final int w1 = wArray.getNumber(0)?.toInt() ?? 1;
    final int w2 = wArray.getNumber(1)?.toInt() ?? 2;
    final int w3 = wArray.getNumber(2)?.toInt() ?? 1;
    final int entrySize = w1 + w2 + w3;
    if (w1 < 0 || w2 < 0 || w3 < 0 || entrySize <= 0 || entrySize > 24) {
      throw const PdfFormatException('invalid xref stream /W widths');
    }

    final indexArray = dict.getArray('Index');
    final subsections = <(int, int)>[];

    if (indexArray != null && indexArray.length >= 2) {
      for (var i = 0; i + 1 < indexArray.length; i += 2) {
        final start = indexArray.getNumber(i)?.toInt() ?? 0;
        final count = indexArray.getNumber(i + 1)?.toInt() ?? 0;
        subsections.add((start, count));
      }
    } else {
      subsections.add((0, size));
    }

    final bytes = stream.getDecodedBytes(this);
    var byteOffset = 0;

    for (final sub in subsections) {
      final startObjNum = sub.$1;
      final count = sub.$2;
      if (startObjNum < 0 || count < 0 || count > limits.maxXRefEntries) {
        throw const PdfFormatException(
          'invalid xref stream /Index subsection',
        );
      }

      for (var i = 0; i < count; i++) {
        if (byteOffset + entrySize > bytes.length) break;

        var typeField = 1;
        if (w1 > 0) {
          typeField = _readIntFromBytes(bytes, byteOffset, w1);
          byteOffset += w1;
        }

        final field2 = _readIntFromBytes(bytes, byteOffset, w2);
        byteOffset += w2;

        final field3 = _readIntFromBytes(bytes, byteOffset, w3);
        byteOffset += w3;

        final objNum = startObjNum + i;
        if (_entries.containsKey(objNum)) continue;

        if (typeField == 1) {
          // Uncompressed
          addEntry(PdfXRefEntry(
            objNum: objNum,
            genNum: field3,
            offset: field2,
            type: PdfXRefEntryType.uncompressed,
          ));
        } else if (typeField == 2) {
          // Compressed in Object Stream
          addEntry(PdfXRefEntry(
            objNum: objNum,
            genNum: 0,
            offset: 0,
            streamObjNum: field2,
            indexInStream: field3,
            type: PdfXRefEntryType.compressed,
          ));
        }
      }
    }
  }

  int _readIntFromBytes(Uint8List bytes, int offset, int length) {
    var val = 0;
    for (var i = 0; i < length; i++) {
      val = (val << 8) | bytes[offset + i];
    }
    return val;
  }

  void _reconstructCorruptXRef() {
    // Varredura linear em arquivos corrompidos
    final buffer = reader.buffer;
    final len = buffer.length;

    for (var i = 0; i + 4 < len; i++) {
      if (buffer[i] == 0x6F && buffer[i + 1] == 0x62 && buffer[i + 2] == 0x6A) {
        // Encontrou 'obj'
        var p = i - 1;
        while (p >= 0 && PdfLexer.isWhitespace(buffer[p])) {
          p--;
        }
        final genEnd = p + 1;
        while (p >= 0 && !PdfLexer.isWhitespace(buffer[p])) {
          p--;
        }
        final genStr = String.fromCharCodes(buffer.sublist(p + 1, genEnd));
        while (p >= 0 && PdfLexer.isWhitespace(buffer[p])) {
          p--;
        }
        final numEnd = p + 1;
        while (p >= 0 && !PdfLexer.isWhitespace(buffer[p])) {
          p--;
        }
        final numStr = String.fromCharCodes(buffer.sublist(p + 1, numEnd));

        final objNum = int.tryParse(numStr);
        final genNum = int.tryParse(genStr);

        if (objNum != null && genNum != null && !_entries.containsKey(objNum)) {
          if (_entries.length >= limits.maxXRefEntries) {
            throw PdfFormatException(
              'repaired xref exceeds ${limits.maxXRefEntries} entries',
              offset: i,
            );
          }
          addEntry(PdfXRefEntry(
            objNum: objNum,
            genNum: genNum,
            offset: p + 1,
            type: PdfXRefEntryType.uncompressed,
          ));
        }
      }
    }
  }

  void _recoverTrailerFromCatalog() {
    if (trailer?['Root'] != null) return;
    for (final entry in _entries.values) {
      if (entry.type != PdfXRefEntryType.uncompressed) continue;
      try {
        final object = resolveRef(PdfRef(entry.objNum, entry.genNum));
        if (object is PdfDict &&
            object.getName('Type', this)?.name == 'Catalog') {
          trailer = PdfDict(<String, PdfObject>{
            'Root': PdfRef(entry.objNum, entry.genNum),
          });
          return;
        }
      } on Object {
        // Repair is best effort; keep scanning later object candidates.
      }
    }
  }

  @override
  PdfObject? resolveRef(PdfRef ref) {
    if (_objectCache.containsKey(ref.objNum)) {
      return _objectCache[ref.objNum];
    }

    final entry = _entries[ref.objNum];
    if (entry == null) return null;
    if (!_resolvingObjects.add(ref.objNum)) {
      throw PdfFormatException('cyclic object reference ${ref.objNum}');
    }

    try {
      if (entry.type == PdfXRefEntryType.uncompressed) {
        reader.offset = entry.offset;
        final lexer = PdfLexer(reader);
        final parser = PdfParser(lexer, limits: limits);
        final obj = parser.parseObject();
        if (obj != null) {
          _objectCache[ref.objNum] = obj;
        }
        return obj;
      } else if (entry.type == PdfXRefEntryType.compressed) {
        final streamObj = resolveRef(PdfRef(entry.streamObjNum, 0));
        if (streamObj is PdfStream) {
          final decoded = streamObj.getDecodedBytes(this);
          final streamReader = ByteReader(decoded);
          final lexer = PdfLexer(streamReader);
          final parser = PdfParser(lexer, limits: limits);

          final firstOffset = streamObj.dict.getNumber('First')?.toInt() ?? 0;
          final n = streamObj.dict.getNumber('N')?.toInt() ?? 0;
          if (firstOffset < 0 || firstOffset > decoded.length) {
            throw const PdfFormatException('invalid object stream /First');
          }
          if (n < 0 || n > limits.maxObjectStreamEntries) {
            throw PdfFormatException(
              'object stream /N exceeds ${limits.maxObjectStreamEntries}',
            );
          }

          final objMap = <int, int>{};
          for (var i = 0; i < n; i++) {
            final tNum = lexer.nextToken();
            final tOff = lexer.nextToken();
            if (tNum.type != PdfTokenType.number ||
                tOff.type != PdfTokenType.number) {
              break;
            }
            objMap[tNum.numberValue!.toInt()] =
                firstOffset + tOff.numberValue!.toInt();
          }

          final targetOffset = objMap[ref.objNum];
          if (targetOffset != null &&
              targetOffset >= firstOffset &&
              targetOffset <= decoded.length) {
            streamReader.offset = targetOffset;
            final obj = parser.parseObject();
            if (obj != null) {
              _objectCache[ref.objNum] = obj;
            }
            return obj;
          }
        }
      }
      return null;
    } finally {
      _resolvingObjects.remove(ref.objNum);
    }
  }
}
