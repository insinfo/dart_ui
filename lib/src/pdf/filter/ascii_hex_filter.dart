import 'dart:typed_data';
import 'pdf_filter.dart';

/// Decodificador `/ASCIIHexDecode` para converter texto hexadecimal em binário.
class AsciiHexFilter implements PdfFilter {
  const AsciiHexFilter();

  @override
  Uint8List decode(Uint8List data, [DecodeParms parms = const DecodeParms()]) {
    final out = <int>[];
    var firstNibble = -1;

    for (var i = 0; i < data.length; i++) {
      final byte = data[i];

      // '>' indica fim do fluxo
      if (byte == 0x3E) break;

      // Ignora espaços em branco
      if (byte == 0x00 ||
          byte == 0x09 ||
          byte == 0x0A ||
          byte == 0x0C ||
          byte == 0x0D ||
          byte == 0x20) {
        continue;
      }

      int nibble;
      if (byte >= 0x30 && byte <= 0x39) {
        nibble = byte - 0x30;
      } else if (byte >= 0x41 && byte <= 0x46) {
        nibble = byte - 0x41 + 10;
      } else if (byte >= 0x61 && byte <= 0x66) {
        nibble = byte - 0x61 + 10;
      } else {
        continue;
      }

      if (firstNibble == -1) {
        firstNibble = nibble;
      } else {
        out.add((firstNibble << 4) | nibble);
        firstNibble = -1;
      }
    }

    if (firstNibble != -1) {
      out.add(firstNibble << 4);
    }

    return DecodeParms.applyPredictor(Uint8List.fromList(out), parms);
  }
}
