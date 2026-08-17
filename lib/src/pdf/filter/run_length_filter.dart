import 'dart:typed_data';
import 'pdf_filter.dart';

/// Decodificador `/RunLengthDecode` (RLE) em Puro Dart.
class RunLengthFilter implements PdfFilter {
  const RunLengthFilter();

  static const int eod = 128;

  @override
  Uint8List decode(Uint8List data, [DecodeParms parms = const DecodeParms()]) {
    final out = <int>[];
    var i = 0;

    while (i < data.length) {
      final lengthByte = data[i++];
      if (lengthByte == eod) break;

      if (lengthByte < 128) {
        // Copia os próximos (lengthByte + 1) bytes literalmente
        final count = lengthByte + 1;
        for (var j = 0; j < count && i < data.length; j++) {
          out.add(data[i++]);
        }
      } else {
        // Repete o próximo byte (257 - lengthByte) vezes
        final count = 257 - lengthByte;
        if (i < data.length) {
          final repeatByte = data[i++];
          for (var j = 0; j < count; j++) {
            out.add(repeatByte);
          }
        }
      }
    }

    return DecodeParms.applyPredictor(Uint8List.fromList(out), parms);
  }
}
