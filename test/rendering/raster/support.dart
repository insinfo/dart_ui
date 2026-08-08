/// Shared fixtures for the rasteriser tests.
///
/// Not named `*_test.dart` so the runner does not try to execute it.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/rendering/framebuffer.dart';

/// Sentinel written into every byte of a fixture buffer that the rasteriser is
/// expected not to touch - notably the row padding of a strided surface.
const int padByte = 0xAB;

/// A framebuffer whose row padding holds [padByte] and whose pixels start
/// transparent black.
///
/// The split is what makes the stride assertions sharp: an untouched pixel
/// reads as zero exactly like it would in a packed buffer, so a test can tell
/// "nothing was drawn here" from "something was drawn into the padding".
Framebuffer padded(
  int width,
  int height, {
  int padding = 12,
  PixelFormat format = PixelFormat.bgra8888Premultiplied,
}) {
  final bytesPerRow = width * 4 + padding;
  final pixels = Uint8List(bytesPerRow * height)
    ..fillRange(0, bytesPerRow * height, padByte);
  return Framebuffer.wrap(
    pixels,
    width: width,
    height: height,
    bytesPerRow: bytesPerRow,
    format: format,
  )..clear(0, 0, 0, 0);
}

/// A source image whose pixel at (x, y) is uniquely identifiable.
///
/// Channel 0 carries x and channel 1 carries y, so a blit that reads the wrong
/// row or column - or that walks the source with the destination's stride -
/// produces a wrong number rather than a plausible-looking colour.
Framebuffer coordinateSource(
  int width,
  int height, {
  int padding = 0,
  int alpha = 255,
  PixelFormat format = PixelFormat.bgra8888Premultiplied,
}) {
  final bytesPerRow = width * 4 + padding;
  final pixels = Uint8List(bytesPerRow * height)
    ..fillRange(0, bytesPerRow * height, padByte);
  for (var y = 0; y < height; y++) {
    var offset = y * bytesPerRow;
    for (var x = 0; x < width; x++) {
      pixels[offset] = 10 + x;
      pixels[offset + 1] = 40 + y;
      pixels[offset + 2] = 70;
      pixels[offset + 3] = alpha;
      offset += 4;
    }
  }
  return Framebuffer.wrap(
    pixels,
    width: width,
    height: height,
    bytesPerRow: bytesPerRow,
    format: format,
  );
}

/// The four bytes of the pixel at ([x], [y]), in memory order.
List<int> pixelAt(Framebuffer buffer, int x, int y) {
  final offset = buffer.offsetOf(x, y);
  return buffer.pixels.sublist(offset, offset + 4);
}

/// Every byte of every row that lies past the last pixel of that row.
List<int> paddingBytes(Framebuffer buffer) {
  final bytes = <int>[];
  for (var y = 0; y < buffer.height; y++) {
    final rowStart = y * buffer.bytesPerRow;
    bytes.addAll(
      buffer.pixels.sublist(
        rowStart + buffer.width * 4,
        rowStart + buffer.bytesPerRow,
      ),
    );
  }
  return bytes;
}
