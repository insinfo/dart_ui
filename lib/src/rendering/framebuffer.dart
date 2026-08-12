/// The pixels a renderer writes into.
///
/// This is the one place the framework commits to a memory layout, and it is
/// deliberately the layout the platforms already want: the macOS work presents
/// BGRA premultiplied straight into an IOSurface, and Win32 DIBs and X11 shm
/// images take the same bytes. Choosing anything else would mean a swizzle per
/// frame on every platform to save a swizzle on none.
library;

import 'dart:typed_data';

import '../geometry/rect.dart';

/// Byte order and alpha handling of a [Framebuffer].
///
/// Premultiplied only. Straight alpha needs a divide per pixel at composite
/// time, and every compositor these three platforms hand pixels to expects
/// premultiplied anyway.
enum PixelFormat {
  /// Blue, green, red, alpha - the order a little-endian 32-bit word gives
  /// CoreGraphics with `kCGBitmapByteOrder32Little`, and what a Win32 DIB and
  /// an XImage expect.
  bgra8888Premultiplied,

  /// Same bytes, opposite channel order. Present because GL and Vulkan
  /// surfaces frequently prefer it, and converting at surface creation is
  /// cheaper than converting per frame.
  rgba8888Premultiplied;

  int get bytesPerPixel => 4;
}

/// A CPU-visible image the renderer owns for the duration of a frame.
///
/// [bytesPerRow] is not always `width * 4`. Shared surfaces round their stride
/// up for alignment - an IOSurface reports its own - so code that walks rows
/// must use this and never recompute it. Every row-walking loop in the
/// rasteriser is a chance to get that wrong, which is why the value travels
/// with the pixels instead of being derived.
final class Framebuffer {
  Framebuffer({
    required this.width,
    required this.height,
    required this.bytesPerRow,
    required this.format,
    required this.pixels,
  })  : assert(width > 0 && height > 0),
        assert(bytesPerRow >= width * 4),
        assert(pixels.length >= bytesPerRow * height);

  /// Allocates a tightly packed framebuffer. For tests and for backends that
  /// present a buffer they do not own.
  factory Framebuffer.allocate({
    required int width,
    required int height,
    PixelFormat format = PixelFormat.bgra8888Premultiplied,
  }) =>
      Framebuffer(
        width: width,
        height: height,
        bytesPerRow: width * 4,
        format: format,
        pixels: Uint8List(width * height * 4),
      );

  /// Wraps memory somebody else owns - an IOSurface's base address, a DIB
  /// section, an shm segment. The framebuffer does not free it.
  factory Framebuffer.wrap(
    Uint8List pixels, {
    required int width,
    required int height,
    required int bytesPerRow,
    PixelFormat format = PixelFormat.bgra8888Premultiplied,
  }) =>
      Framebuffer(
        width: width,
        height: height,
        bytesPerRow: bytesPerRow,
        format: format,
        pixels: pixels,
      );

  final int width;
  final int height;
  final int bytesPerRow;
  final PixelFormat format;
  final Uint8List pixels;

  /// Byte offset of the first channel of the pixel at ([x], [y]).
  ///
  /// No bounds check: this is called once per pixel in the inner loop, and the
  /// callers clip before they get here. Passing coordinates outside the buffer
  /// is a bug in the caller, not a condition to handle.
  int offsetOf(int x, int y) => y * bytesPerRow + x * 4;

  /// Fills the whole buffer with one premultiplied colour.
  ///
  /// One 32-bit store per pixel rather than four 8-bit ones. That is not
  /// premature: the macOS pacing probe measured a byte-wise fill of a 1080p
  /// surface at 7.1ms - 42% of a 60Hz frame, and seventeen times the cost of
  /// presenting it - so the inner loop of a clear is genuinely on the critical
  /// path. See `doc/logs/PRESENT_PACING_2026-08-08.md`.
  ///
  /// The word view is only valid when the buffer's rows are 4-byte aligned,
  /// which a Uint8List does not promise; [Uint32List.view] throws otherwise,
  /// and the byte loop stays as the fallback rather than as dead code.
  void clear(int blue, int green, int red, int alpha) {
    final packed = _packWord(blue, green, red, alpha);
    if (bytesPerRow % 4 == 0 && pixels.offsetInBytes % 4 == 0) {
      final words = Uint32List.view(
        pixels.buffer,
        pixels.offsetInBytes,
        (bytesPerRow ~/ 4) * height,
      );
      final wordsPerRow = bytesPerRow ~/ 4;
      for (var y = 0; y < height; y++) {
        final start = y * wordsPerRow;
        // Only the payload, never the padding: the stride tests assert those
        // bytes stay untouched.
        words.fillRange(start, start + width, packed);
      }
      return;
    }
    for (var y = 0; y < height; y++) {
      var index = y * bytesPerRow;
      for (var x = 0; x < width; x++) {
        pixels[index] = blue;
        pixels[index + 1] = green;
        pixels[index + 2] = red;
        pixels[index + 3] = alpha;
        index += 4;
      }
    }
  }

  /// Replaces only the pixels intersecting [rect], preserving the rest.
  void clearRect(Rect rect, int blue, int green, int red, int alpha) {
    final left = rect.left.floor().clamp(0, width);
    final top = rect.top.floor().clamp(0, height);
    final right = rect.right.ceil().clamp(0, width);
    final bottom = rect.bottom.ceil().clamp(0, height);
    if (right <= left || bottom <= top) return;
    for (var y = top; y < bottom; y++) {
      var index = y * bytesPerRow + left * 4;
      for (var x = left; x < right; x++) {
        if (format == PixelFormat.bgra8888Premultiplied) {
          pixels[index] = blue;
          pixels[index + 1] = green;
          pixels[index + 2] = red;
        } else {
          pixels[index] = red;
          pixels[index + 1] = green;
          pixels[index + 2] = blue;
        }
        pixels[index + 3] = alpha;
        index += 4;
      }
    }
  }

  /// Packs four channel bytes into the word a little-endian store writes back
  /// in memory order. Byte 0 of the pixel ends up in the low bits, which is
  /// what makes this equal to the byte loop above.
  static int _packWord(int b0, int b1, int b2, int b3) =>
      (b3 << 24) | (b2 << 16) | (b1 << 8) | b0;

  /// A copy with rows packed tightly, for comparing against a golden image
  /// without the stride getting in the way.
  Uint8List toPackedBytes() {
    final packed = Uint8List(width * height * 4);
    for (var y = 0; y < height; y++) {
      packed.setRange(
        y * width * 4,
        (y + 1) * width * 4,
        pixels,
        y * bytesPerRow,
      );
    }
    return packed;
  }
}
