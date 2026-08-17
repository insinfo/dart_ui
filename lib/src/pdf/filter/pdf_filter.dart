import 'dart:typed_data';

/// Parâmetros de decodificação passados pelo dicionário `/DecodeParms` no PDF.
class DecodeParms {
  /// Algoritmo preditor (1 = Nenhum, 2 = TIFF Predictor 2, 10..15 = PNG Predictor).
  final int predictor;

  /// Número de componentes de cor por amostra (ex: 1 para Gray, 3 para RGB, 4 para CMYK).
  final int colors;

  /// Número de bits por componente de cor (1, 2, 4, 8, 16).
  final int bitsPerComponent;

  /// Número de amostras por linha horizontal.
  final int columns;

  /// Flag para LZW indicando se o incremento de largura de código ocorre 1 código antes.
  final int earlyChange;

  /// Parâmetros para CCITT Fax
  final int k;
  final bool endOfLine;
  final bool encodedByteAlign;
  final int rows;
  final bool endOfBlock;
  final bool blackIs1;

  const DecodeParms({
    this.predictor = 1,
    this.colors = 1,
    this.bitsPerComponent = 8,
    this.columns = 1,
    this.earlyChange = 1,
    this.k = 0,
    this.endOfLine = false,
    this.encodedByteAlign = false,
    this.rows = 0,
    this.endOfBlock = true,
    this.blackIs1 = false,
  });

  /// Reconstrói dados descompactados aplicando os preditores PNG (RFC 2083) ou TIFF 2.
  static Uint8List applyPredictor(Uint8List data, DecodeParms parms) {
    final predictor = parms.predictor;
    if (predictor <= 1) {
      return data;
    }

    final colors = parms.colors;
    final bitsPerComponent = parms.bitsPerComponent;
    final columns = parms.columns;
    final bytesPerPixel = ((colors * bitsPerComponent + 7) ~/ 8);
    final rowBytes = ((columns * colors * bitsPerComponent + 7) ~/ 8);

    if (predictor == 2) {
      // TIFF Predictor 2: Diferença horizontal
      final output = Uint8List.fromList(data);
      final numRows = data.length ~/ rowBytes;
      for (var r = 0; r < numRows; r++) {
        final rowStart = r * rowBytes;
        for (var c = bytesPerPixel; c < rowBytes; c++) {
          output[rowStart + c] =
              (output[rowStart + c] + output[rowStart + c - bytesPerPixel]) &
                  0xFF;
        }
      }
      return output;
    }

    if (predictor >= 10 && predictor <= 15) {
      // Preditor PNG: Cada linha possui 1 byte de tipo de filtro antes dos dados da linha.
      final rowLengthWithTag = rowBytes + 1;
      final numRows = data.length ~/ rowLengthWithTag;
      final output = Uint8List(numRows * rowBytes);

      var srcOffset = 0;
      var dstOffset = 0;
      Uint8List? prevRow;

      for (var r = 0; r < numRows; r++) {
        if (srcOffset >= data.length) break;
        final filterType = data[srcOffset++];
        final currentRow = Uint8List(rowBytes);

        for (var i = 0; i < rowBytes; i++) {
          final x = data[srcOffset++];
          final a = (i >= bytesPerPixel) ? currentRow[i - bytesPerPixel] : 0;
          final b = (prevRow != null) ? prevRow[i] : 0;
          final c = (prevRow != null && i >= bytesPerPixel)
              ? prevRow[i - bytesPerPixel]
              : 0;

          int val = 0;
          switch (filterType) {
            case 0: // None
              val = x;
              break;
            case 1: // Sub
              val = (x + a) & 0xFF;
              break;
            case 2: // Up
              val = (x + b) & 0xFF;
              break;
            case 3: // Average
              val = (x + ((a + b) >> 1)) & 0xFF;
              break;
            case 4: // Paeth
              val = (x + _paethPredictor(a, b, c)) & 0xFF;
              break;
            default:
              val = x;
          }
          currentRow[i] = val;
          output[dstOffset++] = val;
        }
        prevRow = currentRow;
      }
      return output;
    }

    return data;
  }

  static int _paethPredictor(int a, int b, int c) {
    final p = a + b - c;
    final pa = (p - a).abs();
    final pb = (p - b).abs();
    final pc = (p - c).abs();
    if (pa <= pb && pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
  }
}

/// Interface base para decodificadores de fluxos PDF em Puro Dart.
abstract class PdfFilter {
  /// Decodifica [data] utilizando os parâmetros opcionais [parms].
  Uint8List decode(Uint8List data, [DecodeParms parms = const DecodeParms()]);
}
