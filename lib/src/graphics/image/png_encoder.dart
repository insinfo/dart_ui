/// Writes PNG files: 8-bit RGBA, compressed.
library;

import 'dart:typed_data';

import 'deflate.dart';

/// [pixels] (`width * height * 4` bytes, row by row) as a PNG file.
///
/// [bgra] says the bytes are blue, green, red, alpha - a framebuffer's
/// order - rather than red, green, blue, alpha. Alpha is written as given;
/// a premultiplied framebuffer of opaque content is the same either way.
Uint8List encodePng({
  required int width,
  required int height,
  required Uint8List pixels,
  bool bgra = false,
}) {
  if (width <= 0 || height <= 0) {
    throw ArgumentError('a PNG is at least 1x1; got ${width}x$height');
  }
  if (pixels.length < width * height * 4) {
    throw ArgumentError('${width}x$height RGBA needs ${width * height * 4} '
        'bytes; got ${pixels.length}');
  }
  // Every row is a filter-type byte (0, none) and the pixels.
  final int stride = width * 4;
  final Uint8List raw = Uint8List(height * (stride + 1));
  for (var y = 0; y < height; y++) {
    final int row = y * (stride + 1);
    final int source = y * stride;
    if (!bgra) {
      raw.setRange(row + 1, row + 1 + stride, pixels, source);
      continue;
    }
    for (var x = 0; x < stride; x += 4) {
      raw[row + 1 + x] = pixels[source + x + 2];
      raw[row + 2 + x] = pixels[source + x + 1];
      raw[row + 3 + x] = pixels[source + x];
      raw[row + 4 + x] = pixels[source + x + 3];
    }
  }
  final ByteData header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 6); // colour type: truecolour with alpha
  final BytesBuilder out = BytesBuilder(copy: false)
    ..add(const <int>[137, 80, 78, 71, 13, 10, 26, 10]);
  _chunk(out, 'IHDR', header.buffer.asUint8List());
  // The platform's zlib where there is one: a screenshot is not hashed or
  // signed, so speed beats byte-for-byte reproducibility here.
  _chunk(out, 'IDAT', deflateZlib(raw, encoder: DeflateEncoder.native));
  _chunk(out, 'IEND', Uint8List(0));
  return out.takeBytes();
}

void _chunk(BytesBuilder out, String type, Uint8List data) {
  final Uint8List typed = Uint8List.fromList(type.codeUnits);
  final ByteData length = ByteData(4)..setUint32(0, data.length);
  out
    ..add(length.buffer.asUint8List())
    ..add(typed)
    ..add(data);
  int crc = 0xFFFFFFFF;
  crc = _crc(crc, typed);
  crc = _crc(crc, data);
  final ByteData checksum = ByteData(4)..setUint32(0, crc ^ 0xFFFFFFFF);
  out.add(checksum.buffer.asUint8List());
}

final Uint32List _crcTable = () {
  final Uint32List table = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    table[n] = c;
  }
  return table;
}();

int _crc(int crc, Uint8List bytes) {
  var c = crc;
  for (final int byte in bytes) {
    c = _crcTable[(c ^ byte) & 0xFF] ^ (c >> 8);
  }
  return c;
}
