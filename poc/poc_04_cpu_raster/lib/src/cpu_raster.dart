import 'dart:typed_data';

/// Rectangle in physical pixels. Right and bottom coordinates are exclusive.
final class DirtyRect {
  const DirtyRect(this.left, this.top, this.right, this.bottom);

  final int left;
  final int top;
  final int right;
  final int bottom;

  bool get isEmpty => right <= left || bottom <= top;

  DirtyRect intersect(int width, int height) => DirtyRect(
        left.clamp(0, width),
        top.clamp(0, height),
        right.clamp(0, width),
        bottom.clamp(0, height),
      );
}

/// A reusable top-down BGRA8888 pixel buffer with premultiplied alpha.
///
/// Its byte order maps directly to a Windows top-down 32-bit DIB on little
/// endian systems and is also the common 32-bit format for X11/CG bitmap paths.
final class BgraPremultipliedBuffer {
  BgraPremultipliedBuffer(this.width, this.height)
      : data = Uint8List(width * height * bytesPerPixel);

  static const int bytesPerPixel = 4;

  final int width;
  final int height;
  final Uint8List data;

  int get stride => width * bytesPerPixel;

  /// Fills [rect], clipping it to this buffer. Colors must be premultiplied.
  void fillRect(DirtyRect rect, int b, int g, int r, int a) {
    final clipped = rect.intersect(width, height);
    if (clipped.isEmpty) return;
    fillRectRaw(
        clipped.left, clipped.top, clipped.right, clipped.bottom, b, g, r, a);
  }

  /// Allocation-free variant used by the steady-state render loop.
  void fillRectRaw(
      int left, int top, int right, int bottom, int b, int g, int r, int a) {
    final pixels = data;
    final x0 = left.clamp(0, width);
    final y0 = top.clamp(0, height);
    final x1 = right.clamp(0, width);
    final y1 = bottom.clamp(0, height);
    if (x1 <= x0 || y1 <= y0) return;
    for (var y = y0; y < y1; y++) {
      var offset = y * stride + x0 * bytesPerPixel;
      final end = y * stride + x1 * bytesPerPixel;
      while (offset < end) {
        pixels[offset] = b;
        pixels[offset + 1] = g;
        pixels[offset + 2] = r;
        pixels[offset + 3] = a;
        offset += bytesPerPixel;
      }
    }
  }

  /// Composites a premultiplied BGRA color using source-over blending.
  void blendRect(DirtyRect rect, int b, int g, int r, int a) {
    if (a == 255) {
      fillRect(rect, b, g, r, a);
      return;
    }
    if (a == 0) return;

    final clipped = rect.intersect(width, height);
    if (clipped.isEmpty) return;
    blendRectRaw(
        clipped.left, clipped.top, clipped.right, clipped.bottom, b, g, r, a);
  }

  /// Allocation-free source-over blend for the render loop.
  void blendRectRaw(
      int left, int top, int right, int bottom, int b, int g, int r, int a) {
    if (a == 255) {
      fillRectRaw(left, top, right, bottom, b, g, r, a);
      return;
    }
    if (a == 0) return;
    final x0 = left.clamp(0, width);
    final y0 = top.clamp(0, height);
    final x1 = right.clamp(0, width);
    final y1 = bottom.clamp(0, height);
    if (x1 <= x0 || y1 <= y0) return;
    final inverseAlpha = 255 - a;
    final pixels = data;
    for (var y = y0; y < y1; y++) {
      var offset = y * stride + x0 * bytesPerPixel;
      final end = y * stride + x1 * bytesPerPixel;
      while (offset < end) {
        pixels[offset] = b + ((pixels[offset] * inverseAlpha + 127) ~/ 255);
        pixels[offset + 1] =
            g + ((pixels[offset + 1] * inverseAlpha + 127) ~/ 255);
        pixels[offset + 2] =
            r + ((pixels[offset + 2] * inverseAlpha + 127) ~/ 255);
        pixels[offset + 3] =
            a + ((pixels[offset + 3] * inverseAlpha + 127) ~/ 255);
        offset += bytesPerPixel;
      }
    }
  }
}

/// Deterministic scene held as scalar constants, avoiding per-frame objects.
final class BenchmarkScene {
  BenchmarkScene(this.width, this.height)
      : buffer = BgraPremultipliedBuffer(width, height);

  final int width;
  final int height;
  final BgraPremultipliedBuffer buffer;

  /// Renders 10 opaque cards plus translucent overlays into the reusable buffer.
  void render(int frame) {
    final bgBlue = 28 + (frame & 7);
    buffer.fillRectRaw(0, 0, width, height, bgBlue, 22, 16, 255);

    const cardWidth = 110;
    const cardHeight = 72;
    for (var i = 0; i < 10; i++) {
      final x = 28 + (i % 5) * 148;
      final y = 42 + (i ~/ 5) * 112;
      final b = 55 + i * 12;
      final g = 75 + i * 9;
      final r = 35 + i * 14;
      buffer.fillRectRaw(x, y, x + cardWidth, y + cardHeight, b, g, r, 255);
      buffer.blendRectRaw(
          x + 10, y + 10, x + cardWidth - 10, y + 24, 40, 70, 120, 128);
    }

    _drawText();

    // Moving dirty region exercises partial redraw without allocating a frame.
    final x = (frame * 7) % (width + 40) - 40;
    buffer.blendRectRaw(x, height - 56, x + 40, height - 16, 0, 150, 255, 192);
  }

  void _drawText() {
    // Seven rows of 5-bit glyphs spelling "CPU RASTER"; no object allocation.
    const glyphs = <int>[
      14,
      17,
      16,
      16,
      16,
      17,
      14,
      30,
      17,
      17,
      30,
      16,
      16,
      16,
      17,
      17,
      17,
      17,
      17,
      17,
      14,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      30,
      17,
      17,
      30,
      20,
      18,
      17,
      14,
      17,
      17,
      31,
      17,
      17,
      17,
      15,
      16,
      16,
      14,
      1,
      1,
      30,
      31,
      4,
      4,
      4,
      4,
      4,
      4,
      31,
      16,
      16,
      30,
      16,
      16,
      31,
      30,
      17,
      17,
      30,
      16,
      16,
      16
    ];
    const letters = 10;
    final y = height - 36;
    for (var letter = 0; letter < letters; letter++) {
      final x = 28 + letter * 6;
      for (var row = 0; row < 7; row++) {
        final bits = glyphs[letter * 7 + row];
        for (var column = 0; column < 5; column++) {
          if ((bits & (1 << (4 - column))) != 0) {
            buffer.fillRectRaw(x + column, y + row, x + column + 1, y + row + 1,
                235, 220, 220, 255);
          }
        }
      }
    }
  }
}
