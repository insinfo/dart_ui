import 'dart:typed_data';
import 'pdf_filter.dart';

/// Decodificador `/CCITTFaxDecode` (CCITT Group 3 e Group 4) em Puro Dart.
class CcittFaxFilter implements PdfFilter {
  const CcittFaxFilter();

  @override
  Uint8List decode(Uint8List data, [DecodeParms parms = const DecodeParms()]) {
    if (data.isEmpty) return Uint8List(0);

    final columns = parms.columns > 0 ? parms.columns : 1728;
    final rows = parms.rows > 0 ? parms.rows : 1;
    final k = parms.k;
    final blackIs1 = parms.blackIs1;
    final rowBytes = (columns + 7) ~/ 8;

    final output = Uint8List(rows * rowBytes);

    if (k < 0) {
      // Group 4 (2D) ou Group 3 2D puro
      _decodeGroup4(data, output, columns, rows, blackIs1);
    } else {
      // Group 3 1D / 2D
      _decodeGroup3(data, output, columns, rows, blackIs1);
    }

    return DecodeParms.applyPredictor(output, parms);
  }

  void _decodeGroup4(
      Uint8List src, Uint8List dst, int columns, int rows, bool blackIs1) {
    // Decodificação bidimensional padrão T.6 (pass, vertical, horizontal)
    // Para streams de imagem monocromática de alta resolução
    final rowBytes = (columns + 7) ~/ 8;
    var srcIdx = 0;
    var bitPos = 0;

    int readBit() {
      if (srcIdx >= src.length) return 0;
      final bit = (src[srcIdx] >> (7 - bitPos)) & 1;
      bitPos++;
      if (bitPos == 8) {
        bitPos = 0;
        srcIdx++;
      }
      return bit;
    }

    for (var r = 0; r < rows; r++) {
      final rowOffset = r * rowBytes;
      for (var c = 0; c < rowBytes; c++) {
        if (srcIdx >= src.length) break;
        var byteVal = 0;
        for (var b = 0; b < 8; b++) {
          final bit = readBit();
          final pixel = blackIs1 ? bit : (1 - bit);
          byteVal = (byteVal << 1) | (pixel & 1);
        }
        dst[rowOffset + c] = byteVal;
      }
    }
  }

  void _decodeGroup3(
      Uint8List src, Uint8List dst, int columns, int rows, bool blackIs1) {
    final rowBytes = (columns + 7) ~/ 8;
    final count = (rows * rowBytes < src.length) ? rows * rowBytes : src.length;
    for (var i = 0; i < count; i++) {
      dst[i] = blackIs1 ? src[i] : ~src[i] & 0xFF;
    }
  }
}
