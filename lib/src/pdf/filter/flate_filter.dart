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
      if (data.length >= 2 && data[0] == 0x78) {
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
}
