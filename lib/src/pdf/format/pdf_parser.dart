import 'dart:typed_data';
import 'pdf_lexer.dart';
import 'pdf_object.dart';

/// Analisador sintático de objetos PDF diretos e indiretos em Puro Dart.
class PdfParser {
  final PdfLexer lexer;
  final List<PdfToken> _tokenBuffer = [];

  PdfParser(this.lexer);

  PdfToken peekToken() {
    if (_tokenBuffer.isEmpty) {
      _tokenBuffer.add(lexer.nextToken());
    }
    return _tokenBuffer.first;
  }

  PdfToken nextToken() {
    if (_tokenBuffer.isNotEmpty) {
      return _tokenBuffer.removeAt(0);
    }
    return lexer.nextToken();
  }

  /// Lê o próximo objeto PDF do fluxo.
  PdfObject? parseObject() {
    final token = nextToken();
    if (token.type == PdfTokenType.eof) return null;

    // 1. Dicionário `<< ... >>`
    if (token.isDelimiter('<<')) {
      final dict = parseDictionary();

      // Verifica se é seguido imediatamente por um `stream`
      final peek = peekToken();
      if (peek.isKeyword('stream')) {
        return parseStream(dict);
      }
      return dict;
    }

    // 2. Array `[ ... ]`
    if (token.isDelimiter('[')) {
      return parseArray();
    }

    // 3. String literal
    if (token.type == PdfTokenType.string) {
      return PdfString(token.stringBytes ?? Uint8List(0), isHex: false);
    }

    // 4. Hex string
    if (token.type == PdfTokenType.hexString) {
      return PdfString(token.stringBytes ?? Uint8List(0), isHex: true);
    }

    // 5. Nome `/Name`
    if (token.type == PdfTokenType.name) {
      return PdfName(token.text);
    }

    // 6. Número ou Referência Indireta `id gen R`
    if (token.type == PdfTokenType.number) {
      final num1 = token.numberValue!;

      // Se for inteiro, pode ser o início de uma referência indireta `10 0 R`
      if (num1 is int) {
        final peek1 = peekToken();
        if (peek1.type == PdfTokenType.number && peek1.numberValue is int) {
          final t2 = nextToken();
          final peek2 = peekToken();
          if (peek2.isKeyword('R')) {
            nextToken(); // Consome 'R'
            return PdfRef(num1, t2.numberValue!.toInt());
          } else if (peek2.isKeyword('obj')) {
            // Início de declaração de objeto `id gen obj`
            nextToken(); // Consome 'obj'
            final innerObj = parseObject();
            final endObjToken = nextToken();
            if (!endObjToken.isKeyword('endobj')) {
              // Tolerante a PDFs com endobj ausente
            }
            return innerObj;
          } else {
            // Coloca os tokens de volta no buffer se não for R nem obj
            _tokenBuffer.insert(0, t2);
          }
        }
      }

      return PdfNumber(num1);
    }

    // 7. Booleanos e Null
    if (token.isKeyword('true')) return const PdfBoolean(true);
    if (token.isKeyword('false')) return const PdfBoolean(false);
    if (token.isKeyword('null')) return const PdfNull();

    return null;
  }

  /// Analisa um dicionário `<< /Key Val ... >>`.
  PdfDict parseDictionary() {
    final dict = PdfDict();

    while (true) {
      final token = nextToken();
      if (token.type == PdfTokenType.eof || token.isDelimiter('>>')) {
        break;
      }

      if (token.type == PdfTokenType.name) {
        final key = token.text;
        final value = parseObject();
        if (value != null) {
          dict[key] = value;
        }
      }
    }

    return dict;
  }

  /// Analisa um array `[ elem1 elem2 ... ]`.
  PdfArray parseArray() {
    final elements = <PdfObject>[];

    while (true) {
      final peek = peekToken();
      if (peek.type == PdfTokenType.eof || peek.isDelimiter(']')) {
        nextToken(); // Consome ']'
        break;
      }

      final obj = parseObject();
      if (obj != null) {
        elements.add(obj);
      }
    }

    return PdfArray(elements);
  }

  /// Analisa um objeto de fluxo binário `stream ... endstream`.
  PdfStream parseStream(PdfDict dict) {
    nextToken(); // Consome 'stream'

    // O operador 'stream' deve ser seguido por CRLF ou LF
    final reader = lexer.reader;
    if (!reader.isEOF) {
      final b = reader.peekUint8();
      if (b == 0x0D) {
        reader.readUint8();
        if (!reader.isEOF && reader.peekUint8() == 0x0A) {
          reader.readUint8();
        }
      } else if (b == 0x0A) {
        reader.readUint8();
      }
    }

    // Comprimento declarado em /Length (se for número direto)
    final lengthObj = dict['Length'];
    int? declaredLength;
    if (lengthObj is PdfNumber) {
      declaredLength = lengthObj.asInt;
    }

    Uint8List streamBytes;
    if (declaredLength != null &&
        declaredLength >= 0 &&
        declaredLength <= reader.remaining) {
      streamBytes = reader.readBytes(declaredLength);

      // Consome até encontrar 'endstream'
      while (!reader.isEOF) {
        final token = lexer.nextToken();
        if (token.isKeyword('endstream') || token.type == PdfTokenType.eof) {
          break;
        }
      }
    } else {
      // Varredura linear segura até encontrar os bytes 'endstream'
      final raw = <int>[];
      while (!reader.isEOF) {
        if (reader.remaining >= 9) {
          final p0 = reader.buffer[reader.offset];
          final p1 = reader.buffer[reader.offset + 1];
          final p2 = reader.buffer[reader.offset + 2];
          final p3 = reader.buffer[reader.offset + 3];
          final p4 = reader.buffer[reader.offset + 4];
          final p5 = reader.buffer[reader.offset + 5];
          final p6 = reader.buffer[reader.offset + 6];
          final p7 = reader.buffer[reader.offset + 7];
          final p8 = reader.buffer[reader.offset + 8];

          if (p0 == 0x65 &&
              p1 == 0x6E &&
              p2 == 0x64 &&
              p3 == 0x73 &&
              p4 == 0x74 &&
              p5 == 0x72 &&
              p6 == 0x65 &&
              p7 == 0x61 &&
              p8 == 0x6D) {
            // 'endstream' encontrado
            reader.skip(9);
            break;
          }
        }
        raw.add(reader.readUint8());
      }
      // Remove quebras de linha residuais no final do stream
      while (raw.isNotEmpty &&
          (raw.last == 0x0A || raw.last == 0x0D || raw.last == 0x20)) {
        raw.removeLast();
      }
      streamBytes = Uint8List.fromList(raw);
    }

    return PdfStream(dict, streamBytes);
  }
}
