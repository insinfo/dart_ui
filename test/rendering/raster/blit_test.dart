import 'dart:typed_data';

import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/raster/rasterizer.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('drawFramebuffer placement', () {
    test('copies the source pixel for pixel at the destination origin', () {
      final source = coordinateSource(3, 2);
      final target = Framebuffer.allocate(width: 6, height: 5);

      CpuRasterizer(target).drawFramebuffer(
        source,
        const Rect.fromLTRB(2, 1, 5, 3),
      );

      for (var y = 0; y < 2; y++) {
        for (var x = 0; x < 3; x++) {
          expect(
            pixelAt(target, 2 + x, 1 + y),
            <int>[10 + x, 40 + y, 70, 255],
            reason: 'source ($x, $y)',
          );
        }
      }
      expect(pixelAt(target, 1, 1)[3], 0);
      expect(pixelAt(target, 5, 1)[3], 0);
      expect(pixelAt(target, 2, 0)[3], 0);
      expect(pixelAt(target, 2, 3)[3], 0);
    });

    test('a destination smaller than the source crops rather than scales', () {
      final source = coordinateSource(4, 4);
      final target = Framebuffer.allocate(width: 6, height: 6);

      CpuRasterizer(target).drawFramebuffer(
        source,
        const Rect.fromLTRB(0, 0, 2, 2),
      );

      // The top-left 2x2 of the source, at its original scale: a scaling blit
      // would have put the source's last column here instead.
      expect(pixelAt(target, 0, 0), <int>[10, 40, 70, 255]);
      expect(pixelAt(target, 1, 1), <int>[11, 41, 70, 255]);
      expect(pixelAt(target, 2, 0)[3], 0);
      expect(pixelAt(target, 0, 2)[3], 0);
    });

    test('a destination larger than the source leaves the rest alone', () {
      final source = coordinateSource(2, 2);
      final target = Framebuffer.allocate(width: 6, height: 6);

      CpuRasterizer(target).drawFramebuffer(
        source,
        const Rect.fromLTRB(0, 0, 6, 6),
      );

      expect(pixelAt(target, 1, 1), <int>[11, 41, 70, 255]);
      expect(pixelAt(target, 2, 0)[3], 0);
      expect(pixelAt(target, 0, 2)[3], 0);
    });
  });

  group('drawFramebuffer clipping', () {
    test('a blit hanging off the surface writes only inside', () {
      final source = coordinateSource(4, 4);
      final target = padded(3, 3);

      CpuRasterizer(target).drawFramebuffer(
        source,
        const Rect.fromLTRB(-2, -2, 2, 2),
      );

      // The destination origin is (-2, -2), so the visible pixel (0, 0) must
      // come from source (2, 2) - the source has to be walked from an offset,
      // not from its first row.
      expect(pixelAt(target, 0, 0), <int>[12, 42, 70, 255]);
      expect(pixelAt(target, 1, 1), <int>[13, 43, 70, 255]);
      expect(pixelAt(target, 2, 2)[3], 0);
      expect(paddingBytes(target), everyElement(padByte));
    });

    test('a blit entirely outside costs nothing', () {
      final source = coordinateSource(4, 4);
      final target = padded(3, 3);
      final before = Uint8List.fromList(target.pixels);

      CpuRasterizer(target)
        ..drawFramebuffer(source, const Rect.fromLTRB(50, 50, 54, 54))
        ..drawFramebuffer(source, const Rect.fromLTRB(-40, -40, -36, -36))
        ..drawFramebuffer(source, const Rect.fromLTRB(3, 0, 7, 4));

      expect(target.pixels, before);
    });

    test('the clip stack bounds the blit as well as the surface', () {
      final source = coordinateSource(4, 4);
      final target = Framebuffer.allocate(width: 4, height: 4);

      CpuRasterizer(target)
        ..clipRect(const Rect.fromLTRB(1, 1, 3, 3))
        ..drawFramebuffer(source, const Rect.fromLTRB(0, 0, 4, 4));

      expect(pixelAt(target, 0, 0)[3], 0);
      expect(pixelAt(target, 1, 1), <int>[11, 41, 70, 255]);
      expect(pixelAt(target, 2, 2), <int>[12, 42, 70, 255]);
      expect(pixelAt(target, 3, 3)[3], 0);
    });
  });

  group('drawFramebuffer stride', () {
    test('source and destination strides are read independently', () {
      final source = coordinateSource(3, 3, padding: 24);
      final target = padded(3, 3, padding: 8);

      // A blit that used one buffer's stride for the other would read or write
      // shifted rows, and the coordinate-encoded source makes that visible.
      CpuRasterizer(target).drawFramebuffer(
        source,
        const Rect.fromLTRB(0, 0, 3, 3),
      );

      for (var y = 0; y < 3; y++) {
        for (var x = 0; x < 3; x++) {
          expect(pixelAt(target, x, y), <int>[10 + x, 40 + y, 70, 255]);
        }
      }
      expect(paddingBytes(target), everyElement(padByte));
    });

    test('the source row padding is never copied into the destination', () {
      final source = coordinateSource(2, 3, padding: 40);
      final target = Framebuffer.allocate(width: 2, height: 3);

      CpuRasterizer(target).drawFramebuffer(
        source,
        const Rect.fromLTRB(0, 0, 2, 3),
      );

      expect(target.pixels, isNot(contains(padByte)));
      expect(pixelAt(target, 1, 2), <int>[11, 42, 70, 255]);
    });
  });

  group('drawFramebuffer format', () {
    test('a matching format is copied straight through', () {
      final source = coordinateSource(
        2,
        2,
        format: PixelFormat.rgba8888Premultiplied,
      );
      final target = Framebuffer.allocate(
        width: 2,
        height: 2,
        format: PixelFormat.rgba8888Premultiplied,
      );

      CpuRasterizer(target).drawFramebuffer(
        source,
        const Rect.fromLTRB(0, 0, 2, 2),
      );

      expect(target.toPackedBytes(), source.toPackedBytes());
    });

    test('a differing format swaps red and blue and leaves alpha alone', () {
      final source = coordinateSource(
        2,
        2,
        format: PixelFormat.rgba8888Premultiplied,
      );
      final target = Framebuffer.allocate(width: 2, height: 2);

      CpuRasterizer(target).drawFramebuffer(
        source,
        const Rect.fromLTRB(0, 0, 2, 2),
      );

      for (var y = 0; y < 2; y++) {
        for (var x = 0; x < 2; x++) {
          final from = pixelAt(source, x, y);
          expect(pixelAt(target, x, y), <int>[
            from[2],
            from[1],
            from[0],
            from[3],
          ]);
        }
      }
    });

    test('differing format and differing stride together', () {
      final source = coordinateSource(
        3,
        2,
        padding: 12,
        format: PixelFormat.bgra8888Premultiplied,
      );
      final target = padded(
        3,
        2,
        padding: 28,
        format: PixelFormat.rgba8888Premultiplied,
      );
      target.clear(0, 0, 0, 255);

      CpuRasterizer(target).drawFramebuffer(
        source,
        const Rect.fromLTRB(0, 0, 3, 2),
      );

      for (var y = 0; y < 2; y++) {
        for (var x = 0; x < 3; x++) {
          expect(pixelAt(target, x, y), <int>[70, 40 + y, 10 + x, 255]);
        }
      }
      expect(paddingBytes(target), everyElement(padByte));
    });
  });

  group('drawFramebuffer blending', () {
    test('a fully transparent source leaves the destination untouched', () {
      final source = coordinateSource(3, 3, alpha: 0);
      final target = Framebuffer.allocate(width: 3, height: 3);
      CpuRasterizer(target).fillRect(
        const Rect.fromLTRB(0, 0, 3, 3),
        0xff204060,
      );
      final before = target.toPackedBytes();

      CpuRasterizer(target).drawFramebuffer(
        source,
        const Rect.fromLTRB(0, 0, 3, 3),
      );

      expect(target.toPackedBytes(), before);
    });

    test('a half-alpha source composites over the destination', () {
      // Source premultiplied white at alpha 128 over opaque black gives the
      // same 128 grey a fill does, which is the check that the blit and the
      // fill share one compositor.
      final source = Framebuffer.allocate(width: 1, height: 1);
      source.pixels.setAll(0, <int>[128, 128, 128, 128]);
      final target = Framebuffer.allocate(width: 1, height: 1);
      final raster = CpuRasterizer(target)
        ..fillRect(const Rect.fromLTRB(0, 0, 1, 1), 0xff000000)
        ..drawFramebuffer(source, const Rect.fromLTRB(0, 0, 1, 1));

      expect(raster.target.pixels, <int>[128, 128, 128, 255]);
    });

    test('an opaque source replaces whatever was underneath', () {
      final source = coordinateSource(2, 2);
      final target = Framebuffer.allocate(width: 2, height: 2);
      CpuRasterizer(target)
        ..fillRect(const Rect.fromLTRB(0, 0, 2, 2), 0xffffffff)
        ..drawFramebuffer(source, const Rect.fromLTRB(0, 0, 2, 2));

      expect(pixelAt(target, 0, 0), <int>[10, 40, 70, 255]);
    });
  });
}
