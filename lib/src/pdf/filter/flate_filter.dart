import 'dart:typed_data';
import '../../graphics/image/inflate.dart';
import 'pdf_filter.dart';

/// Decodificador `/FlateDecode` (Zlib/Deflate - RFC 1950/1951) em Puro Dart.
class FlateFilter implements PdfFilter {
  const FlateFilter();

  @override
  Uint8List decode(Uint8List data, [DecodeParms parms = const DecodeParms()]) {
    if (data.isEmpty) return Uint8List(0);

    Uint8List decompressed;
    try {
      if (_hasZlibHeader(data)) {
        // Zlib stream com cabeçalho (RFC 1950)
        decompressed = inflateZlib(
          data,
          maxOutputBytes: 128 * 1024 * 1024, // 128 MiB de teto seguro
          budget: 'pdf_flate_stream',
        );
      } else {
        // Raw DEFLATE (RFC 1951)
        decompressed = inflate(
          data,
          maxOutputBytes: 128 * 1024 * 1024,
          budget: 'pdf_flate_stream',
        );
      }
    } catch (zlibError) {
      // Fallback para raw inflate se o zlib falhar
      try {
        decompressed = inflate(
          data,
          maxOutputBytes: 128 * 1024 * 1024,
          budget: 'pdf_flate_stream',
        );
      } catch (rawError) {
        throw PdfFilterException(
          'invalid or over-budget Flate stream',
          '$zlibError; raw fallback: $rawError',
        );
      }
    }

    return DecodeParms.applyPredictor(decompressed, parms);
  }

  static bool _hasZlibHeader(Uint8List data) {
    if (data.length < 2) return false;
    final cmf = data[0];
    final flg = data[1];
    // RFC 1950: CM=8 (DEFLATE), CINFO<=7 and CMF*256+FLG divisible by 31.
    return (cmf & 0x0f) == 8 && (cmf >> 4) <= 7 && ((cmf << 8) | flg) % 31 == 0;
  }
}
