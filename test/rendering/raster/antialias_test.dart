import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/raster/blend.dart';
import 'package:dart_ui/src/rendering/raster/rasterizer.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Opaque white, the colour that turns the framebuffer into a coverage
/// readout.
///
/// Premultiplied white scaled by a coverage c is `(c, c, c, c)`, and blending
/// that over opaque black gives `c + mul255(0, 255 - c) = c` in every colour
/// channel and `c + (255 - c) = 255` in alpha. So after [black] and then
/// [white], each colour byte IS that pixel's coverage - no arithmetic in the
/// test to get between the assertion and the thing being asserted.
const int white = 0xffffffff;
const int black = 0xff000000;

/// A surface of [width] x [height] filled with opaque black, and its
/// rasteriser.
(Framebuffer, CpuRasterizer) blackSurface(int width, int height) {
  final target = Framebuffer.allocate(width: width, height: height);
  final raster = CpuRasterizer(target)
    ..fillRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), black);
  return (target, raster);
}

/// The coverage the rasteriser deposited in each column of row [y].
List<int> coverageRow(Framebuffer buffer, int y) => <int>[
      for (var x = 0; x < buffer.width; x++) pixelAt(buffer, x, y)[0],
    ];

/// The coverage the rasteriser deposited in each row of column [x].
List<int> coverageColumn(Framebuffer buffer, int x) => <int>[
      for (var y = 0; y < buffer.height; y++) pixelAt(buffer, x, y)[0],
    ];

void main() {
  group('agreement with the hard-edged fill', () {
    test('a rectangle on integer boundaries is byte-for-byte identical', () {
      // The regression guard. Antialiasing must be invisible to anything that
      // was already pixel aligned, or every existing golden becomes wrong.
      for (final rect in <Rect>[
        const Rect.fromLTRB(0, 0, 6, 5),
        const Rect.fromLTRB(1, 1, 5, 4),
        const Rect.fromLTRB(2, 0, 3, 5),
        const Rect.fromLTRB(-4, -4, 3, 3),
        const Rect.fromLTRB(4, 2, 20, 20),
      ]) {
        final (hard, hardRaster) = blackSurface(6, 5);
        final (soft, softRaster) = blackSurface(6, 5);

        hardRaster.fillRect(rect, 0xc0336699);
        softRaster.fillRectAntiAliased(rect, 0xc0336699);

        expect(
          soft.toPackedBytes(),
          hard.toPackedBytes(),
          reason: '$rect',
        );
      }
    });

    test('integer rectangles agree under an integer clip too', () {
      final (hard, hardRaster) = blackSurface(6, 5);
      final (soft, softRaster) = blackSurface(6, 5);

      hardRaster
        ..clipRect(const Rect.fromLTRB(1, 1, 5, 4))
        ..fillRect(const Rect.fromLTRB(0, 0, 6, 5), white);
      softRaster
        ..clipRect(const Rect.fromLTRB(1, 1, 5, 4))
        ..fillRectAntiAliased(const Rect.fromLTRB(0, 0, 6, 5), white);

      expect(soft.toPackedBytes(), hard.toPackedBytes());
    });

    test('an opaque interior is exactly the source colour', () {
      // Not "close to": the interior of an antialiased shape must not be a
      // shade off, which is what a coverage that peaked at 254 would produce.
      final (target, raster) = blackSurface(5, 4);
      raster.fillRectAntiAliased(
        const Rect.fromLTRB(0.5, 0.5, 4.5, 3.5),
        0xff3366cc,
      );

      // BGRA: blue 0xcc, green 0x66, red 0x33, and opaque.
      for (var y = 1; y <= 2; y++) {
        for (var x = 1; x <= 3; x++) {
          expect(pixelAt(target, x, y), <int>[0xcc, 0x66, 0x33, 255]);
        }
      }
    });
  });

  group('coverage on the boundary', () {
    test('a half-pixel offset splits the boundary columns evenly', () {
      final (target, raster) = blackSurface(4, 1);
      raster.fillRectAntiAliased(const Rect.fromLTRB(0.5, 0, 3.5, 1), white);

      // 127 and 128 rather than 128 and 128: they have to sum to a whole
      // pixel and 255 is odd. See coverage.dart.
      expect(coverageRow(target, 0), <int>[127, 255, 255, 128]);
      expect(coverageRow(target, 0).first + coverageRow(target, 0).last, 255);
    });

    test('a half-pixel offset works the same way vertically', () {
      final (target, raster) = blackSurface(1, 4);
      raster.fillRectAntiAliased(const Rect.fromLTRB(0, 0.5, 1, 3.5), white);

      expect(coverageColumn(target, 0), <int>[127, 255, 255, 128]);
    });

    test('a corner pixel gets the product of the two coverages', () {
      // This is the assertion that the coverage is an area and not a max or a
      // sum of the two edge fractions.
      final (target, raster) = blackSurface(4, 3);
      raster.fillRectAntiAliased(
        const Rect.fromLTRB(0.5, 0.5, 3.5, 2.5),
        white,
      );

      expect(pixelAt(target, 0, 0)[0], mul255(127, 127));
      expect(pixelAt(target, 0, 0)[0], 63);
      // An edge pixel is covered fully in one axis, so it keeps that axis's
      // coverage untouched.
      expect(pixelAt(target, 1, 0)[0], 127);
      expect(pixelAt(target, 0, 1)[0], 127);
      expect(pixelAt(target, 1, 1)[0], 255);
      // The far corner takes the other end of both splits.
      expect(pixelAt(target, 3, 2)[0], mul255(128, 128));
    });

    test('a one-pixel rectangle straddling two columns conserves its ink', () {
      final (target, raster) = blackSurface(4, 1);
      raster.fillRectAntiAliased(const Rect.fromLTRB(1.5, 0, 2.5, 1), white);

      expect(coverageRow(target, 0), <int>[0, 127, 128, 0]);
      expect(127 + 128, 255);
    });

    test('conservation holds at every sub-pixel offset', () {
      // The property that catches almost every coverage bug: a rectangle one
      // pixel wide deposits exactly one pixel of ink, wherever it lands.
      for (var step = 0; step <= 100; step++) {
        final offset = step / 100.0;
        final (target, raster) = blackSurface(4, 1);
        raster.fillRectAntiAliased(
          Rect.fromLTRB(1 + offset, 0, 2 + offset, 1),
          white,
        );

        final row = coverageRow(target, 0);
        expect(
          row.reduce((a, b) => a + b),
          255,
          reason: 'offset $offset gave $row',
        );
      }
    });

    test('a sub-pixel rectangle deposits only its own fraction', () {
      final (target, raster) = blackSurface(4, 1);
      raster.fillRectAntiAliased(const Rect.fromLTRB(1.2, 0, 1.4, 1), white);

      // Width 0.2 of a single column, and nothing spilled into its
      // neighbours - this is the path where the rectangle never reaches an
      // interior span at all.
      expect(coverageRow(target, 0), <int>[0, 51, 0, 0]);
    });

    test('a coverage that rounds to zero writes nothing at all', () {
      // Column 1 is overlapped by 0.001 of a pixel, which quantises to 0. The
      // bytes must come back untouched: blending with alpha 0 is a no-op
      // arithmetically but still a read and a write per pixel, and this is the
      // input that would exercise it on every row of a tall fill.
      final (target, raster) = blackSurface(4, 2);
      raster.fillRect(const Rect.fromLTRB(0, 0, 4, 2), 0xff204060);
      final before = target.toPackedBytes();

      raster.fillRectAntiAliased(const Rect.fromLTRB(1.999, 0, 3, 2), white);

      expect(pixelAt(target, 1, 0), before.sublist(4, 8));
      expect(pixelAt(target, 1, 1), before.sublist(20, 24));
      expect(coverageRow(target, 0), <int>[0x60, 0x60, 255, 0x60]);
    });

    test('a fully transparent colour is a no-op', () {
      final (target, raster) = blackSurface(4, 2);
      final before = target.toPackedBytes();

      raster.fillRectAntiAliased(
        const Rect.fromLTRB(0.5, 0.5, 3.5, 1.5),
        0x00ffffff,
      );

      expect(target.toPackedBytes(), before);
    });

    test('a translucent colour is scaled by coverage, not replaced by it', () {
      // Onto a transparent surface, so the alpha the fill deposits is visible
      // rather than being hidden by an opaque destination. Half-alpha white at
      // half coverage is a quarter of a pixel of white, and it must stay
      // premultiplied - every channel scales, alpha included.
      final target = Framebuffer.allocate(width: 2, height: 1);
      CpuRasterizer(target).fillRectAntiAliased(
        const Rect.fromLTRB(0.5, 0, 1.5, 1),
        0x80ffffff,
      );

      expect(pixelAt(target, 0, 0), <int>[64, 64, 64, 64]);
      expect(mul255(128, 127), 64);
      // The far column takes the other half of the split.
      expect(pixelAt(target, 1, 0), <int>[64, 64, 64, 64]);
    });
  });

  group('clipping', () {
    test('a fractional clip leaves the clipped edge SOFT', () {
      // THE decision this file documents: the clip stack carries the exact
      // edges alongside the rounded ones, so an antialiased fill clipped at
      // 1.5 keeps half of column 1 rather than losing it.
      final (target, raster) = blackSurface(4, 1);
      raster
        ..clipRect(const Rect.fromLTRB(1.5, 0, 4, 1))
        ..fillRectAntiAliased(const Rect.fromLTRB(0, 0, 4, 1), white);

      expect(coverageRow(target, 0), <int>[0, 127, 255, 255]);
    });

    test('the hard fill under the same clip loses that column entirely', () {
      // The contrast that makes the choice visible without running anything:
      // same clip, same rectangle, and the hard-edged fill rounds column 1
      // away because its clip is the integer one.
      final (target, raster) = blackSurface(4, 1);
      raster
        ..clipRect(const Rect.fromLTRB(1.5, 0, 4, 1))
        ..fillRect(const Rect.fromLTRB(0, 0, 4, 1), white);

      expect(coverageRow(target, 0), <int>[0, 0, 255, 255]);
    });

    test('a shape drawn exactly to its own clip stays symmetric', () {
      // The case that motivated carrying the exact clip. With an integer-only
      // clip the left edge would be chopped to 0 while the right stayed at
      // 128, so the same shape would be hard on one side and soft on the
      // other depending only on where layout put it.
      final (target, raster) = blackSurface(7, 1);
      const shape = Rect.fromLTRB(1.5, 0, 5.5, 1);
      raster
        ..clipRect(shape)
        ..fillRectAntiAliased(shape, white);

      final row = coverageRow(target, 0);
      expect(row, <int>[0, 127, 255, 255, 255, 128, 0]);
      expect(row[1] + row[5], 255);
    });

    test('a clip narrower than a pixel still admits an antialiased draw', () {
      // The integer clip is empty here - it admits no whole pixel - while the
      // exact clip is 0.8 of a pixel wide. The two answers are both right for
      // their own question, which is why ClipStack exposes both.
      final (target, raster) = blackSurface(4, 1);
      raster.clipRect(const Rect.fromLTRB(1.6, 0, 2.4, 1));

      expect(raster.clip.isEmpty, isTrue);
      expect(raster.clip.isEmptyExact, isFalse);

      raster.fillRect(const Rect.fromLTRB(0, 0, 4, 1), white);
      expect(coverageRow(target, 0), <int>[0, 0, 0, 0]);

      raster.fillRectAntiAliased(const Rect.fromLTRB(0, 0, 4, 1), white);
      expect(coverageRow(target, 0), <int>[0, 102, 102, 0]);
      expect(102 + 102, 204);
    });

    test('an exactly empty clip suppresses the draw', () {
      final (target, raster) = blackSurface(4, 2);
      final before = target.toPackedBytes();

      raster
        ..clipRect(const Rect.fromLTRB(0, 0, 1, 2))
        ..clipRect(const Rect.fromLTRB(3, 0, 4, 2))
        ..fillRectAntiAliased(const Rect.fromLTRB(0, 0, 4, 2), white);

      expect(raster.clip.isEmptyExact, isTrue);
      expect(target.toPackedBytes(), before);
    });

    test('restore brings the exact clip back, not just the rounded one', () {
      final (target, raster) = blackSurface(4, 1);
      raster
        ..save()
        ..clipRect(const Rect.fromLTRB(2.5, 0, 4, 1))
        ..restore()
        ..fillRectAntiAliased(const Rect.fromLTRB(0.5, 0, 3.5, 1), white);

      expect(coverageRow(target, 0), <int>[127, 255, 255, 128]);
    });

    test('a rectangle entirely outside costs nothing', () {
      final (target, raster) = blackSurface(4, 2);
      final before = target.toPackedBytes();

      raster
        ..fillRectAntiAliased(const Rect.fromLTRB(40.5, 0, 44.5, 2), white)
        ..fillRectAntiAliased(const Rect.fromLTRB(-9.5, 0, -1.5, 2), white)
        ..fillRectAntiAliased(const Rect.fromLTRB(0, 9.5, 4, 12.5), white);

      expect(target.toPackedBytes(), before);
    });

    test('a rectangle hanging off the surface is cut at the edge', () {
      final (target, raster) = blackSurface(4, 1);
      raster.fillRectAntiAliased(
        const Rect.fromLTRB(-20.5, 0, 2.5, 1),
        white,
      );

      // The surface edge is a hard boundary by definition - there is no
      // column -1 to put the other half of the coverage into.
      expect(coverageRow(target, 0), <int>[255, 255, 128, 0]);
    });
  });

  group('stride', () {
    test('an antialiased fill never touches the row padding', () {
      final target = padded(5, 4, padding: 16);
      CpuRasterizer(target)
        ..fillRect(const Rect.fromLTRB(0, 0, 5, 4), black)
        ..fillRectAntiAliased(const Rect.fromLTRB(0.5, 0.5, 4.5, 3.5), white);

      expect(paddingBytes(target), everyElement(padByte));
      expect(paddingBytes(target), hasLength(16 * 4));
      // And the fill really did reach the last column, so the padding survived
      // a write that ended right next to it.
      expect(coverageRow(target, 0), <int>[63, 127, 127, 127, 64]);
      expect(coverageRow(target, 1), <int>[127, 255, 255, 255, 128]);
    });

    test('a full-bleed antialiased fill respects the stride', () {
      final target = padded(3, 3, padding: 4);
      final raster = CpuRasterizer(target)
        ..fillRectAntiAliased(const Rect.fromLTRB(-5.5, -5.5, 9.5, 9.5), white);

      expect(paddingBytes(target), everyElement(padByte));
      expect(raster.target.toPackedBytes(), everyElement(255));
    });
  });

  group('pixel format', () {
    test('coverage scales the premultiplied colour in either byte order', () {
      final bgra = Framebuffer.allocate(width: 2, height: 1);
      final rgba = Framebuffer.allocate(
        width: 2,
        height: 1,
        format: PixelFormat.rgba8888Premultiplied,
      );
      const rect = Rect.fromLTRB(0.5, 0, 1.5, 1);

      for (final target in <Framebuffer>[bgra, rgba]) {
        CpuRasterizer(target)
          ..fillRect(const Rect.fromLTRB(0, 0, 2, 1), black)
          ..fillRectAntiAliased(rect, 0xffff0000);
      }

      // Premultiplied red scaled by coverage 127 is 127 in the red channel
      // only, and red is byte 2 on BGRA and byte 0 on RGBA.
      expect(pixelAt(bgra, 0, 0), <int>[0, 0, 127, 255]);
      expect(pixelAt(rgba, 0, 0), <int>[127, 0, 0, 255]);
      expect(pixelAt(bgra, 1, 0), <int>[0, 0, 128, 255]);
      expect(pixelAt(rgba, 1, 0), <int>[128, 0, 0, 255]);
    });
  });

  group('allocation discipline', () {
    test('repeated antialiased fills reuse the clip storage', () {
      // Section 6.5: no allocation per primitive on the raster path. The clip
      // stack now carries doubles as well as ints, so this drives the growth
      // and reuse of both lists together.
      final (target, raster) = blackSurface(8, 8);
      for (var i = 0; i < 500; i++) {
        final offset = (i % 7) / 7.0;
        raster
          ..save()
          ..clipRect(Rect.fromLTRB(0.5 + offset, 0.5, 7.5, 7.5))
          ..save()
          ..clipRect(const Rect.fromLTRB(1, 1, 7, 7))
          ..fillRectAntiAliased(Rect.fromLTRB(offset, offset, 8, 8), white)
          ..restore()
          ..restore();
      }

      expect(raster.clip.depth, 0);
      expect(raster.clip.current, const Rect.fromLTRB(0, 0, 8, 8));
      expect(raster.clip.currentExact, const Rect.fromLTRB(0, 0, 8, 8));
    });

    test('a reused clip slot still holds the right edges', () {
      // Slots survive a restore and are overwritten by the next save, so the
      // 501st save writes over numbers the 1st save put there. Drawing
      // through the reused stack and comparing against a stack that has never
      // been used is what would catch an index that drifted.
      final (used, usedRaster) = blackSurface(6, 1);
      for (var i = 0; i < 500; i++) {
        usedRaster
          ..save()
          ..clipRect(Rect.fromLTRB(i % 4 + 0.5, 0, 5.5, 1))
          ..restore();
      }
      final (fresh, freshRaster) = blackSurface(6, 1);

      for (final raster in <CpuRasterizer>[usedRaster, freshRaster]) {
        raster
          ..save()
          ..clipRect(const Rect.fromLTRB(1.5, 0, 5, 1))
          ..fillRectAntiAliased(const Rect.fromLTRB(0, 0, 6, 1), white)
          ..restore();
      }

      expect(coverageRow(used, 0), coverageRow(fresh, 0));
      expect(coverageRow(used, 0), <int>[0, 127, 255, 255, 255, 0]);
    });
  });
}
