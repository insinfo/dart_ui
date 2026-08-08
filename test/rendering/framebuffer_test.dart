import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('Framebuffer', () {
    test('allocate packs rows tightly', () {
      final buffer = Framebuffer.allocate(width: 7, height: 3);

      expect(buffer.bytesPerRow, 28);
      expect(buffer.pixels.length, 84);
    });

    test('wrap keeps the stride it was given', () {
      // An IOSurface reports its own bytesPerRow and it is routinely larger
      // than width * 4. Recomputing it is the bug this field exists to make
      // impossible.
      final pixels = Uint8List(4 * 64);
      final buffer = Framebuffer.wrap(
        pixels,
        width: 10,
        height: 4,
        bytesPerRow: 64,
      );

      expect(buffer.bytesPerRow, 64);
      expect(buffer.offsetOf(0, 1), 64);
      expect(buffer.offsetOf(2, 1), 72);
    });

    test('rejects a stride narrower than the row', () {
      expect(
        () => Framebuffer(
          width: 10,
          height: 2,
          bytesPerRow: 20,
          format: PixelFormat.bgra8888Premultiplied,
          pixels: Uint8List(40),
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('rejects a buffer too small for its own geometry', () {
      expect(
        () => Framebuffer(
          width: 4,
          height: 4,
          bytesPerRow: 16,
          format: PixelFormat.bgra8888Premultiplied,
          pixels: Uint8List(16 * 3),
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('clear writes every pixel and no padding', () {
      final pixels = Uint8List(32 * 2);
      Framebuffer.wrap(
        pixels,
        width: 4,
        height: 2,
        bytesPerRow: 32,
      ).clear(1, 2, 3, 255);

      // Row 0 payload.
      expect(pixels.sublist(0, 4), <int>[1, 2, 3, 255]);
      expect(pixels.sublist(12, 16), <int>[1, 2, 3, 255]);
      // The 16 padding bytes after it must be untouched.
      expect(pixels.sublist(16, 32), everyElement(0));
      // Row 1 payload starts at the stride, not at width * 4.
      expect(pixels.sublist(32, 36), <int>[1, 2, 3, 255]);
    });

    test('toPackedBytes drops the padding so goldens compare cleanly', () {
      final pixels = Uint8List(32 * 2);
      final buffer = Framebuffer.wrap(
        pixels,
        width: 4,
        height: 2,
        bytesPerRow: 32,
      )..clear(9, 8, 7, 255);

      final packed = buffer.toPackedBytes();

      expect(packed.length, 4 * 2 * 4);
      expect(packed.sublist(16, 20), <int>[9, 8, 7, 255]);
    });
  });

  group('clear fast path', () {
    test('the word path and the byte path agree, byte for byte', () {
      // clear() takes a 32-bit store when the rows are aligned and falls back
      // to four 8-bit stores when they are not. Those two must be
      // indistinguishable in the output, or a padded surface would render
      // differently from a packed one.
      final aligned = Framebuffer.allocate(width: 5, height: 3)
        ..clear(1, 2, 3, 4);

      // An unaligned view of the same geometry forces the byte loop.
      final backing = Uint8List(5 * 3 * 4 + 1);
      final unaligned = Framebuffer.wrap(
        Uint8List.sublistView(backing, 1),
        width: 5,
        height: 3,
        bytesPerRow: 20,
      )..clear(1, 2, 3, 4);

      expect(unaligned.toPackedBytes(), aligned.toPackedBytes());
    });

    test('the fast path still leaves the padding alone', () {
      final pixels = Uint8List(32 * 2);
      Framebuffer.wrap(
        pixels,
        width: 4,
        height: 2,
        bytesPerRow: 32,
      ).clear(0xAA, 0xBB, 0xCC, 0xDD);

      expect(pixels.sublist(0, 4), <int>[0xAA, 0xBB, 0xCC, 0xDD]);
      // Sixteen bytes of stride padding after a sixteen-byte row.
      expect(pixels.sublist(16, 32), everyElement(0));
      expect(pixels.sublist(32, 36), <int>[0xAA, 0xBB, 0xCC, 0xDD]);
    });

    test('channel order survives the pack', () {
      final buffer = Framebuffer.allocate(width: 2, height: 1)
        ..clear(0x11, 0x22, 0x33, 0x44);

      // Byte 0 of the pixel must still be the first argument, whatever the
      // word packing does internally.
      expect(buffer.pixels.sublist(0, 4), <int>[0x11, 0x22, 0x33, 0x44]);
    });
  });

  group('PixelFormat', () {
    test('both variants are four bytes', () {
      for (final format in PixelFormat.values) {
        expect(format.bytesPerPixel, 4);
      }
    });
  });
}
