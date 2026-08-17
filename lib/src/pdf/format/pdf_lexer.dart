import 'dart:typed_data';
import '../io/byte_reader.dart';

/// Tipos de tokens fundamentais retornados pelo [PdfLexer].
enum PdfTokenType {
  keyword,
  name,
  number,
  string,
  hexString,
  delimiter,
  eof,
}

/// Representação de um token léxico do PDF.
class PdfToken {
  final PdfTokenType type;
  final String text;
  final num? numberValue;
  final Uint8List? stringBytes;

  const PdfToken({
    required this.type,
    required this.text,
    this.numberValue,
    this.stringBytes,
  });

  bool isKeyword(String kw) => type == PdfTokenType.keyword && text == kw;
  bool isDelimiter(String d) => type == PdfTokenType.delimiter && text == d;

  @override
  String toString() => 'PdfToken($type, $text)';
}

/// Tokenizador léxico de alta performance para PDF 1.7 / 2.0 (ISO 32000).
class PdfLexer {
  final ByteReader reader;

  PdfLexer(this.reader);

  /// Retorna `true` se o byte for espaço em branco PDF.
  static bool isWhitespace(int b) {
    return b == 0x00 ||
        b == 0x09 ||
        b == 0x0A ||
        b == 0x0C ||
        b == 0x0D ||
        b == 0x20;
  }

  /// Retorna `true` se o byte for um delimitador estrutural PDF.
  static bool isDelimiter(int b) {
    return b == 0x28 || // (
        b == 0x29 || // )
        b == 0x3C || // <
        b == 0x3E || // >
        b == 0x5B || // [
        b == 0x5D || // ]
        b == 0x7B || // {
        b == 0x7D || // }
        b == 0x2F || // /
        b == 0x25; // %
  }

  /// Avança ignorando espaços em branco e comentários iniciados por `%`.
  void skipWhitespaceAndComments() {
    while (!reader.isEOF) {
      final b = reader.peekUint8();
      if (b == -1) break;

      if (isWhitespace(b)) {
        reader.readUint8();
      } else if (b == 0x25) {
        // Comentário '%' -> ignora até o fim da linha
        reader.readUint8();
        while (!reader.isEOF) {
          final c = reader.readUint8();
          if (c == 0x0A || c == 0x0D) break;
        }
      } else {
        break;
      }
    }
  }

  /// Lê o próximo token léxico do fluxo.
  PdfToken nextToken() {
    skipWhitespaceAndComments();
    if (reader.isEOF) {
      return const PdfToken(type: PdfTokenType.eof, text: '');
    }

    final b = reader.peekUint8();

    // 1. Dicionário `<<` ou Hex String `<...>`
    if (b == 0x3C) {
      // '<'
      reader.readUint8();
      if (reader.peekUint8() == 0x3C) {
        reader.readUint8();
        return const PdfToken(type: PdfTokenType.delimiter, text: '<<');
      }
      return _readHexString();
    }

    // 2. Fechamento de Dicionário `>>` ou `>`
    if (b == 0x3E) {
      // '>'
      reader.readUint8();
      if (reader.peekUint8() == 0x3E) {
        reader.readUint8();
        return const PdfToken(type: PdfTokenType.delimiter, text: '>>');
      }
      return const PdfToken(type: PdfTokenType.delimiter, text: '>');
    }

    // 3. Array `[` ou `]`
    if (b == 0x5B) {
      reader.readUint8();
      return const PdfToken(type: PdfTokenType.delimiter, text: '[');
    }
    if (b == 0x5D) {
      reader.readUint8();
      return const PdfToken(type: PdfTokenType.delimiter, text: ']');
    }

    // 4. String Literal `(...)`
    if (b == 0x28) {
      return _readLiteralString();
    }

    // 5. Nome `/Name`
    if (b == 0x2F) {
      return _readName();
    }

    // 6. Palavras-chave, Números ou Booleanos
    return _readRegularToken();
  }

  PdfToken _readName() {
    reader.readUint8(); // Consome '/'
    final chars = <int>[];

    while (!reader.isEOF) {
      final b = reader.peekUint8();
      if (b == -1 || isWhitespace(b) || isDelimiter(b)) break;
      reader.readUint8();

      if (b == 0x23 && reader.remaining >= 2) {
        // Sequência hexadecimal `#XX` em nomes
        final h1 = reader.readUint8();
        final h2 = reader.readUint8();
        final hexStr = String.fromCharCodes([h1, h2]);
        final val = int.tryParse(hexStr, radix: 16);
        if (val != null) {
          chars.add(val);
          continue;
        }
      }
      chars.add(b);
    }

    final nameText = String.fromCharCodes(chars);
    return PdfToken(type: PdfTokenType.name, text: nameText);
  }

  PdfToken _readLiteralString() {
    reader.readUint8(); // Consome '('
    final bytes = <int>[];
    var depth = 1;

    while (!reader.isEOF) {
      final b = reader.readUint8();

      if (b == 0x5C) {
        // Escape '\'
        if (reader.isEOF) break;
        final next = reader.readUint8();
        switch (next) {
          case 0x6E: // \n
            bytes.add(0x0A);
            break;
          case 0x72: // \r
            bytes.add(0x0D);
            break;
          case 0x74: // \t
            bytes.add(0x09);
            break;
          case 0x62: // \b
            bytes.add(0x08);
            break;
          case 0x66: // \f
            bytes.add(0x0C);
            break;
          case 0x28: // \(
            bytes.add(0x28);
            break;
          case 0x29: // \)
            bytes.add(0x29);
            break;
          case 0x5C: // \\
            bytes.add(0x5C);
            break;
          default:
            if (next >= 0x30 && next <= 0x37) {
              // Octal \ddd
              var octal = next - 0x30;
              for (var i = 0; i < 2 && !reader.isEOF; i++) {
                final peek = reader.peekUint8();
                if (peek >= 0x30 && peek <= 0x37) {
                  octal = (octal << 3) | (reader.readUint8() - 0x30);
                } else {
                  break;
                }
              }
              bytes.add(octal & 0xFF);
            } else {
              bytes.add(next);
            }
        }
      } else if (b == 0x28) {
        // Aninhamento '('
        depth++;
        bytes.add(b);
      } else if (b == 0x29) {
        // Fechamento ')'
        depth--;
        if (depth == 0) break;
        bytes.add(b);
      } else {
        bytes.add(b);
      }
    }

    final byteData = Uint8List.fromList(bytes);
    return PdfToken(
      type: PdfTokenType.string,
      text: String.fromCharCodes(bytes),
      stringBytes: byteData,
    );
  }

  PdfToken _readHexString() {
    final hexChars = <int>[];
    while (!reader.isEOF) {
      final b = reader.readUint8();
      if (b == 0x3E) break; // '>'
      if (isWhitespace(b)) continue;
      hexChars.add(b);
    }

    final rawBytes = <int>[];
    for (var i = 0; i < hexChars.length; i += 2) {
      final h1 = String.fromCharCode(hexChars[i]);
      final h2 = (i + 1 < hexChars.length)
          ? String.fromCharCode(hexChars[i + 1])
          : '0';
      final byteVal = int.tryParse('$h1$h2', radix: 16) ?? 0;
      rawBytes.add(byteVal);
    }

    final byteData = Uint8List.fromList(rawBytes);
    return PdfToken(
      type: PdfTokenType.hexString,
      text: String.fromCharCodes(hexChars),
      stringBytes: byteData,
    );
  }

  PdfToken _readRegularToken() {
    final chars = <int>[];
    while (!reader.isEOF) {
      final b = reader.peekUint8();
      if (b == -1 || isWhitespace(b) || isDelimiter(b)) break;
      chars.add(reader.readUint8());
    }

    final text = String.fromCharCodes(chars);

    // Verifica se é número
    final numVal = num.tryParse(text);
    if (numVal != null) {
      return PdfToken(
        type: PdfTokenType.number,
        text: text,
        numberValue: numVal,
      );
    }

    return PdfToken(type: PdfTokenType.keyword, text: text);
  }
}
