import 'dart:typed_data';

import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/raster/rasterizer.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('fillRect', () {
    test('fills the requested pixels and nothing else', () {
      final target = Framebuffer.allocate(width: 4, height: 4);
      CpuRasterizer(target).fillRect(
        const Rect.fromLTRB(1, 1, 3, 3),
        0xffff0000,
      );

      expect(pixelAt(target, 1, 1), <int>[0, 0, 255, 255]);
      expect(pixelAt(target, 2, 2), <int>[0, 0, 255, 255]);
      expect(pixelAt(target, 0, 0), <int>[0, 0, 0, 0]);
      expect(pixelAt(target, 3, 3), <int>[0, 0, 0, 0]);
      expect(pixelAt(target, 3, 1), <int>[0, 0, 0, 0]);
    });

    test('is half-open, so abutting rectangles do not overlap', () {
      // Two fills sharing the edge at x = 2. If the right edge were inclusive
      // the second fill would repaint column 1, and the first would have
      // painted column 2 before it.
      final target = Framebuffer.allocate(width: 4, height: 1);
      CpuRasterizer(target)
        ..fillRect(const Rect.fromLTRB(0, 0, 2, 1), 0xff0000ff)
        ..fillRect(const Rect.fromLTRB(2, 0, 4, 1), 0xff00ff00);

      expect(pixelAt(target, 0, 0), <int>[255, 0, 0, 255]);
      expect(pixelAt(target, 1, 0), <int>[255, 0, 0, 255]);
      expect(pixelAt(target, 2, 0), <int>[0, 255, 0, 255]);
      expect(pixelAt(target, 3, 0), <int>[0, 255, 0, 255]);
    });

    test('rounds fractional edges to the nearest pixel', () {
      final target = Framebuffer.allocate(width: 6, height: 1);
      CpuRasterizer(target).fillRect(
        const Rect.fromLTRB(1.4, 0, 4.6, 1),
        0xff000000,
      );

      expect(pixelAt(target, 0, 0)[3], 0);
      expect(pixelAt(target, 1, 0)[3], 255);
      expect(pixelAt(target, 4, 0)[3], 255);
      expect(pixelAt(target, 5, 0)[3], 0);
    });

    test('a sub-pixel rectangle that rounds away writes nothing', () {
      final target = Framebuffer.allocate(width: 4, height: 4);
      final before = target.toPackedBytes();

      CpuRasterizer(target).fillRect(
        const Rect.fromLTRB(1.1, 1.1, 1.3, 1.3),
        0xffffffff,
      );

      expect(target.toPackedBytes(), before);
    });

    test('a fully transparent colour is a no-op', () {
      final target = Framebuffer.allocate(width: 4, height: 4);
      CpuRasterizer(target).fillRect(
        const Rect.fromLTRB(0, 0, 4, 4),
        0xff123456,
      );
      final before = target.toPackedBytes();

      CpuRasterizer(target).fillRect(
        const Rect.fromLTRB(0, 0, 4, 4),
        0x00ffffff,
      );

      expect(target.toPackedBytes(), before);
    });

    test('premultiplies the colour before compositing', () {
      // 50% white over opaque black: the colour channels land on 128 and the
      // destination stays opaque. A rasteriser that forgot to premultiply
      // would write 255 here.
      final target = Framebuffer.allocate(width: 1, height: 1);
      final raster = CpuRasterizer(target)
        ..fillRect(const Rect.fromLTRB(0, 0, 1, 1), 0xff000000)
        ..fillRect(const Rect.fromLTRB(0, 0, 1, 1), 0x80ffffff);

      expect(raster.target.pixels, <int>[128, 128, 128, 255]);
    });

    test('opaque white and opaque black round-trip through a fill', () {
      final target = Framebuffer.allocate(width: 2, height: 2);
      final raster = CpuRasterizer(target)
        ..fillRect(const Rect.fromLTRB(0, 0, 2, 2), 0xffffffff);
      expect(target.toPackedBytes(), everyElement(255));

      raster.fillRect(const Rect.fromLTRB(0, 0, 2, 2), 0xff000000);
      expect(pixelAt(target, 0, 0), <int>[0, 0, 0, 255]);
      expect(pixelAt(target, 1, 1), <int>[0, 0, 0, 255]);
    });
  });

  group('clipping against the surface', () {
    test('a rectangle hanging off every edge writes only inside', () {
      final target = padded(4, 3);
      CpuRasterizer(target).fillRect(
        const Rect.fromLTRB(-100, -100, 100, 100),
        0xff00ff00,
      );

      for (var y = 0; y < 3; y++) {
        for (var x = 0; x < 4; x++) {
          expect(pixelAt(target, x, y), <int>[0, 255, 0, 255]);
        }
      }
      expect(paddingBytes(target), everyElement(padByte));
    });

    test('a rectangle entirely outside writes nothing', () {
      final target = padded(4, 3);
      final before = Uint8List.fromList(target.pixels);
      final raster = CpuRasterizer(target)
        ..fillRect(const Rect.fromLTRB(100, 100, 200, 200), 0xffffffff)
        ..fillRect(const Rect.fromLTRB(-50, -50, -1, -1), 0xffffffff)
        ..fillRect(const Rect.fromLTRB(-50, 0, 0, 3), 0xffffffff)
        ..fillRect(const Rect.fromLTRB(4, 0, 40, 3), 0xffffffff);

      expect(raster.target.pixels, before);
    });

    test('only the on-surface part of a straddling rectangle is drawn', () {
      final target = padded(4, 2);
      CpuRasterizer(target).fillRect(
        const Rect.fromLTRB(2, -5, 10, 1),
        0xff0000ff,
      );

      expect(pixelAt(target, 1, 0)[3], 0);
      expect(pixelAt(target, 2, 0), <int>[255, 0, 0, 255]);
      expect(pixelAt(target, 3, 0), <int>[255, 0, 0, 255]);
      expect(pixelAt(target, 2, 1)[3], 0);
      expect(paddingBytes(target), everyElement(padByte));
    });
  });

  group('clipping against the clip stack', () {
    test('a fill is confined to the current clip', () {
      final target = Framebuffer.allocate(width: 6, height: 6);
      CpuRasterizer(target)
        ..clipRect(const Rect.fromLTRB(2, 2, 4, 4))
        ..fillRect(const Rect.fromLTRB(0, 0, 6, 6), 0xffffffff);

      expect(pixelAt(target, 2, 2)[3], 255);
      expect(pixelAt(target, 3, 3)[3], 255);
      expect(pixelAt(target, 1, 1)[3], 0);
      expect(pixelAt(target, 4, 4)[3], 0);
    });

    test('clipping to R then filling R produces exactly R', () {
      // The fill and the clip must round identically; if they disagree this
      // loses an edge row or column.
      final target = Framebuffer.allocate(width: 8, height: 8);
      const rect = Rect.fromLTRB(1.5, 2.5, 6.5, 5.5);
      CpuRasterizer(target)
        ..clipRect(rect)
        ..fillRect(rect, 0xff112233);

      // Both edges round to the same pixels: x spans [2, 7) and y spans
      // [3, 6), so 5 columns by 3 rows and not a pixel less.
      var painted = 0;
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          if (pixelAt(target, x, y)[3] != 0) painted++;
        }
      }
      expect(painted, 5 * 3);
      expect(pixelAt(target, 2, 3)[3], 255);
      expect(pixelAt(target, 6, 5)[3], 255);
      expect(pixelAt(target, 1, 3)[3], 0);
      expect(pixelAt(target, 7, 5)[3], 0);
    });

    test('restore reopens the region the nested clip closed', () {
      final target = Framebuffer.allocate(width: 4, height: 1);
      final raster = CpuRasterizer(target)
        ..save()
        ..clipRect(const Rect.fromLTRB(0, 0, 1, 1))
        ..fillRect(const Rect.fromLTRB(0, 0, 4, 1), 0xff0000ff)
        ..restore()
        ..fillRect(const Rect.fromLTRB(3, 0, 4, 1), 0xff00ff00);

      expect(raster.clip.current, const Rect.fromLTRB(0, 0, 4, 1));
      expect(pixelAt(target, 0, 0), <int>[255, 0, 0, 255]);
      expect(pixelAt(target, 1, 0)[3], 0);
      expect(pixelAt(target, 3, 0), <int>[0, 255, 0, 255]);
    });

    test('an empty clip suppresses the draw entirely', () {
      final target = Framebuffer.allocate(width: 4, height: 4);
      final before = target.toPackedBytes();

      CpuRasterizer(target)
        ..clipRect(const Rect.fromLTRB(0, 0, 1, 1))
        ..clipRect(const Rect.fromLTRB(3, 3, 4, 4))
        ..fillRect(const Rect.fromLTRB(0, 0, 4, 4), 0xffffffff);

      expect(target.toPackedBytes(), before);
    });
  });

  group('stride', () {
    test('a full-surface fill never touches the row padding', () {
      final target = padded(5, 4, padding: 16);
      CpuRasterizer(target).fillRect(
        const Rect.fromLTRB(0, 0, 5, 4),
        0xffffffff,
      );

      expect(paddingBytes(target), everyElement(padByte));
      expect(paddingBytes(target), hasLength(16 * 4));
    });

    test('a translucent fill never touches the row padding', () {
      // The blend path reads before it writes, so a stride mistake here would
      // also feed sentinel bytes back into the visible pixels.
      final target = padded(5, 4, padding: 8);
      CpuRasterizer(target)
        ..fillRect(const Rect.fromLTRB(0, 0, 5, 4), 0xff000000)
        ..fillRect(const Rect.fromLTRB(0, 0, 5, 4), 0x80ffffff);

      expect(paddingBytes(target), everyElement(padByte));
      expect(pixelAt(target, 4, 0), <int>[128, 128, 128, 255]);
      expect(pixelAt(target, 4, 3), <int>[128, 128, 128, 255]);
    });

    test('rows land at bytesPerRow apart, not width * 4', () {
      final target = padded(3, 3, padding: 4);
      CpuRasterizer(target).fillRect(
        const Rect.fromLTRB(0, 1, 3, 2),
        0xff00ff00,
      );

      // Row 1 begins at bytesPerRow, which is 16 rather than 12 here. A
      // rasteriser that recomputed the stride would have written into row 0.
      expect(target.pixels.sublist(0, 12), everyElement(0));
      expect(target.pixels.sublist(16, 28), <int>[
        0, 255, 0, 255, //
        0, 255, 0, 255, //
        0, 255, 0, 255, //
      ]);
      expect(paddingBytes(target), everyElement(padByte));
    });

    test('toPackedBytes of a padded surface matches the unpadded one', () {
      final packed = Framebuffer.allocate(width: 4, height: 3);
      final strided = padded(4, 3, padding: 20);
      const rect = Rect.fromLTRB(1, 0, 3, 2);

      CpuRasterizer(packed).fillRect(rect, 0xc0336699);
      CpuRasterizer(strided).fillRect(rect, 0xc0336699);

      expect(strided.toPackedBytes(), packed.toPackedBytes());
      expect(paddingBytes(strided), everyElement(padByte));
    });
  });

  group('pixel format', () {
    test('BGRA and RGBA differ only by a red/blue swap', () {
      final bgra = Framebuffer.allocate(width: 2, height: 2);
      final rgba = Framebuffer.allocate(
        width: 2,
        height: 2,
        format: PixelFormat.rgba8888Premultiplied,
      );
      const rect = Rect.fromLTRB(0, 0, 2, 2);
      const colour = 0xff102030;

      CpuRasterizer(bgra).fillRect(rect, colour);
      CpuRasterizer(rgba).fillRect(rect, colour);

      expect(pixelAt(bgra, 0, 0), <int>[0x30, 0x20, 0x10, 255]);
      expect(pixelAt(rgba, 0, 0), <int>[0x10, 0x20, 0x30, 255]);

      final swapped = pixelAt(rgba, 1, 1);
      expect(pixelAt(bgra, 1, 1), <int>[
        swapped[2],
        swapped[1],
        swapped[0],
        swapped[3],
      ]);
    });

    test('blending respects the format on both surfaces', () {
      final bgra = Framebuffer.allocate(width: 1, height: 1);
      final rgba = Framebuffer.allocate(
        width: 1,
        height: 1,
        format: PixelFormat.rgba8888Premultiplied,
      );
      const rect = Rect.fromLTRB(0, 0, 1, 1);

      for (final target in <Framebuffer>[bgra, rgba]) {
        CpuRasterizer(target)
          ..fillRect(rect, 0xff000000)
          ..fillRect(rect, 0x80ff0000);
      }

      // Premultiplied 50% red over opaque black is (128, 0, 0) with alpha 255,
      // written red-last on BGRA and red-first on RGBA.
      expect(bgra.pixels, <int>[0, 0, 128, 255]);
      expect(rgba.pixels, <int>[128, 0, 0, 255]);
    });
  });
}
