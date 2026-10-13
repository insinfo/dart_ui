import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  test('an encoded PNG decodes to the same pixels', () {
    const int width = 7;
    const int height = 5;
    final Uint8List rgba = Uint8List(width * height * 4);
    for (var i = 0; i < width * height; i++) {
      rgba[i * 4] = i * 7 & 0xFF;
      rgba[i * 4 + 1] = i * 13 & 0xFF;
      rgba[i * 4 + 2] = i * 29 & 0xFF;
      // Opaque: a decoder premultiplies, and opaque pixels are the same
      // either way.
      rgba[i * 4 + 3] = 255;
    }
    final Uint8List png = encodePng(width: width, height: height, pixels: rgba);
    expect(png.sublist(0, 8), <int>[137, 80, 78, 71, 13, 10, 26, 10]);
    final decoded = decodePng(png, order: ImageChannelOrder.rgba);
    expect(decoded.width, width);
    expect(decoded.height, height);
    expect(decoded.pixels, rgba);
  });

  test('BGRA input is reordered to RGBA', () {
    final Uint8List bgra = Uint8List.fromList(<int>[1, 2, 3, 255]);
    final decoded = decodePng(
        encodePng(width: 1, height: 1, pixels: bgra, bgra: true),
        order: ImageChannelOrder.rgba);
    expect(decoded.pixels, <int>[3, 2, 1, 255]);
  });
}
