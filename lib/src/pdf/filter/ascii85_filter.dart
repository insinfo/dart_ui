import 'dart:typed_data';
import 'pdf_filter.dart';

/// Decodificador `/ASCII85Decode` para converter texto codificado em base-85 de volta em binário.
class Ascii85Filter implements PdfFilter {
  const Ascii85Filter();

  @override
  Uint8List decode(Uint8List data, [DecodeParms parms = const DecodeParms()]) {
    final out = <int>[];
    var tuple = 0;
    var count = 0;
    var start = 0;

    // Ignora cabeçalho '<~' se presente
    if (data.length >= 2 && data[0] == 0x3C && data[1] == 0x7E) {
      start = 2;
    }

    for (var i = start; i < data.length; i++) {
      final byte = data[i];

      // Marcador de fim '~>'
      if (byte == 0x7E) {
        if (i + 1 < data.length && data[i + 1] == 0x3E) {
          break;
        }
      }

      // Ignora espaços em branco PDF
      if (byte == 0x00 ||
          byte == 0x09 ||
          byte == 0x0A ||
          byte == 0x0C ||
          byte == 0x0D ||
          byte == 0x20) {
        continue;
      }

      if (byte == 0x7A) {
        // 'z' representa 4 bytes de zero
        if (count == 0) {
          out.addAll(const [0, 0, 0, 0]);
          continue;
        } else {
          // 'z' dentro de um grupo é erro sintático
          break;
        }
      }

      if (byte < 33 || byte > 117) {
        continue;
      }

      tuple = (tuple * 85 + (byte - 33)) & 0xFFFFFFFF;
      count++;

      if (count == 5) {
        out.add((tuple >> 24) & 0xFF);
        out.add((tuple >> 16) & 0xFF);
        out.add((tuple >> 8) & 0xFF);
        out.add(tuple & 0xFF);
        tuple = 0;
        count = 0;
      }
    }

    if (count > 0) {
      for (var i = count; i < 5; i++) {
        tuple = (tuple * 85 + 84) & 0xFFFFFFFF; // 84 = 'u' - 33
      }
      for (var i = 0; i < count - 1; i++) {
        out.add((tuple >> (24 - i * 8)) & 0xFF);
      }
    }

    return DecodeParms.applyPredictor(Uint8List.fromList(out), parms);
  }
}
