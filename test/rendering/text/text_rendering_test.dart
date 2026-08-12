/// Text from a display list all the way to bytes in a framebuffer.
///
/// The assertions here are exact, and Ahem is what makes them exact: every
/// glyph in that face is a solid em box, so a run of it rasterizes to a
/// rectangle whose every pixel is fully covered. That turns questions that are
/// otherwise a matter of judgement - "is the glyph in the right place", "did
/// the clip cut the right half", "does a covered pixel composite the same way
/// a fill does" - into equality on integers.
///
/// Roboto appears only where the point is that real outlines, with antialiased
/// fringes, survive the same path.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/transform2d.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/rendering/cpu_renderer.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/raster/rasterizer.dart';
import 'package:dart_ui/src/rendering/text/glyph_cache.dart';
import 'package:dart_ui/src/rendering/text/glyph_raster.dart';
import 'package:dart_ui/src/text/typeface.dart';
import 'package:test/test.dart';

/// The size Ahem is drawn at throughout: its glyphs are then 40x40 boxes that
/// rise 32 px above the baseline and descend 8 below, which is where every
/// geometric constant in the assertions comes from.
const double kEm = 40;

Typeface _face(String name) =>
    Typeface.parse(File('test/fonts/$name').readAsBytesSync());

/// A white surface, so ink of any colour is visible and "untouched" is a
/// single value.
Framebuffer _surface({int width = 96, int height = 96}) =>
    Framebuffer.allocate(width: width, height: height)
      ..clear(255, 255, 255, 255);

/// A display list holding one run of [text] with its origin on the baseline at
/// ([originX], [originY]).
DisplayList _runList(
  ScaledTypeface font,
  String text, {
  required double originX,
  required double originY,
  int colorArgb = 0xFF000000,
  Rect? clip,
  double advance = kEm,
}) {
  final DisplayList list = DisplayList();
  final int paint = list.addPaint(colorArgb: colorArgb);
  if (clip != null) {
    list.clipRect(clip.left, clip.top, clip.right, clip.bottom);
  }
  final List<int> runes = text.runes.toList();
  final Int32List ids = Int32List(runes.length);
  final Float32List offsets = Float32List(runes.length * 2);
  for (int i = 0; i < runes.length; i++) {
    ids[i] = font.typeface.glyphForCodePoint(runes[i]);
    offsets[i * 2] = i * advance;
  }
  list.drawGlyphRun(
    list.addFont(font),
    paint,
    originX,
    originY,
    ids,
    offsets,
    runes.length,
  );
  return list;
}

/// The bounding box of everything that is not the white background, or null.
Rect? _inkBounds(Framebuffer buffer) {
  int left = buffer.width;
  int top = buffer.height;
  int right = -1;
  int bottom = -1;
  for (int y = 0; y < buffer.height; y++) {
    for (int x = 0; x < buffer.width; x++) {
      final int offset = buffer.offsetOf(x, y);
      final bool white = buffer.pixels[offset] == 255 &&
          buffer.pixels[offset + 1] == 255 &&
          buffer.pixels[offset + 2] == 255;
      if (white) continue;
      if (x < left) left = x;
      if (y < top) top = y;
      if (x > right) right = x;
      if (y > bottom) bottom = y;
    }
  }
  if (right < 0) return null;
  return Rect.fromLTRB(
    left.toDouble(),
    top.toDouble(),
    (right + 1).toDouble(),
    (bottom + 1).toDouble(),
  );
}

List<int> _pixelAt(Framebuffer buffer, int x, int y) {
  final int offset = buffer.offsetOf(x, y);
  return buffer.pixels.sublist(offset, offset + 4);
}

/// A mask of uniform [coverage], for the parity and clipping assertions that
/// are about the blit rather than about any particular glyph.
GlyphMask _solidMask(int width, int height, int coverage) => GlyphMask(
      coverage: Uint8List(width * height)
        ..fillRange(0, width * height, coverage),
      width: width,
      height: height,
      left: 0,
      top: 0,
    );

void main() {
  late Typeface ahem;
  late ScaledTypeface font;
  late int boxGlyph;

  setUp(() {
    ahem = _face('ahem.ttf');
    font = ahem.atSize(kEm);
    boxGlyph = ahem.glyphForCodePoint(0x58); // 'X'
  });

  group('a glyph run reaches the framebuffer', () {
    test('ink lands exactly where the run put the pen', () {
      final Framebuffer surface = _surface();
      // Baseline at y = 42, pen at x = 10. Ahem's box spans the full em
      // horizontally and rises 0.8 em, so the ink is [10, 50) x [10, 50).
      rasterizeDisplayList(
        _runList(font, 'X', originX: 10, originY: 42),
        surface,
        glyphCache: GlyphCache(),
      );

      expect(_inkBounds(surface), const Rect.fromLTRB(10, 10, 50, 50));
      // Opaque black everywhere inside, including the corners: Ahem's box is
      // pixel aligned here, so there is no antialiased fringe to excuse a
      // partial pixel.
      for (int y = 10; y < 50; y++) {
        for (int x = 10; x < 50; x++) {
          expect(_pixelAt(surface, x, y), <int>[0, 0, 0, 255],
              reason: 'pixel ($x, $y) inside the box');
        }
      }
      expect(_pixelAt(surface, 9, 30), <int>[255, 255, 255, 255]);
      expect(_pixelAt(surface, 50, 30), <int>[255, 255, 255, 255]);
    });

    test('a second glyph advances by exactly one em', () {
      final Framebuffer surface = _surface(width: 160);
      rasterizeDisplayList(
        _runList(font, 'XX', originX: 10, originY: 42),
        surface,
        glyphCache: GlyphCache(),
      );

      expect(_inkBounds(surface), const Rect.fromLTRB(10, 10, 90, 50));
    });

    test('the same run drawn twice is byte identical', () {
      // Determinism is the property every golden test rests on, and a glyph
      // cache is exactly the kind of shared mutable state that breaks it: a
      // mask reused from a previous draw must composite to the same bytes as
      // the one that was just rasterized.
      final GlyphCache cache = GlyphCache();
      final Framebuffer first = _surface();
      final Framebuffer second = _surface();
      rasterizeDisplayList(
        _runList(font, 'Xy', originX: 12.5, originY: 44),
        first,
        glyphCache: cache,
      );
      rasterizeDisplayList(
        _runList(font, 'Xy', originX: 12.5, originY: 44),
        second,
        glyphCache: cache,
      );

      expect(second.pixels, first.pixels);
      expect(
        cache.hitCount,
        greaterThan(0),
        reason: 'the second draw must have come out of the cache, or this '
            'proves nothing about reuse',
      );
    });

    test('a glyph with no outline draws nothing', () {
      final Framebuffer surface = _surface();
      rasterizeDisplayList(
        _runList(font, ' ', originX: 10, originY: 42),
        surface,
        glyphCache: GlyphCache(),
      );

      expect(_inkBounds(surface), isNull);
    });

    test('a real face draws an antialiased fringe, not a binary one', () {
      final Typeface roboto = _face('Roboto-Regular.ttf');
      final Framebuffer surface = _surface();
      rasterizeDisplayList(
        _runList(roboto.atSize(32), 'O', originX: 12, originY: 50),
        surface,
        glyphCache: GlyphCache(),
      );

      final Set<int> greys = <int>{};
      for (int y = 0; y < surface.height; y++) {
        for (int x = 0; x < surface.width; x++) {
          greys.add(_pixelAt(surface, x, y)[0]);
        }
      }
      expect(greys, contains(0), reason: 'a fully covered pixel');
      expect(greys, contains(255), reason: 'untouched background');
      expect(greys.where((int g) => g > 0 && g < 255).length, greaterThan(8),
          reason: 'the coverage ramp that makes small text legible');
    });
  });

  group('colour', () {
    test('the run takes its colour from the paint and nothing else', () {
      final Framebuffer red = _surface();
      final Framebuffer blue = _surface();
      rasterizeDisplayList(
        _runList(font, 'X', originX: 10, originY: 42, colorArgb: 0xFFFF0000),
        red,
        glyphCache: GlyphCache(),
      );
      rasterizeDisplayList(
        _runList(font, 'X', originX: 10, originY: 42, colorArgb: 0xFF0000FF),
        blue,
        glyphCache: GlyphCache(),
      );

      // Byte 3 is alpha and byte 1 is green in both pixel formats, so shape
      // and coverage live entirely in the bytes that must match. Only the
      // outer two - red and blue, whichever way round the surface stores them
      // - are allowed to differ.
      for (int i = 0; i < red.pixels.length; i += 4) {
        expect(blue.pixels[i + 1], red.pixels[i + 1],
            reason: 'green differs at byte $i, so the shape differs');
        expect(blue.pixels[i + 3], red.pixels[i + 3],
            reason: 'alpha differs at byte $i, so the coverage differs');
      }
      expect(_pixelAt(red, 30, 30), <int>[0, 0, 255, 255]);
      expect(_pixelAt(blue, 30, 30), <int>[255, 0, 0, 255]);
    });

    test('one cached mask serves both colours', () {
      // The reason a glyph is cached as coverage rather than as pixels: the
      // second colour must not cost a rasterization.
      final GlyphCache cache = GlyphCache();
      rasterizeDisplayList(
        _runList(font, 'X', originX: 10, originY: 42, colorArgb: 0xFFFF0000),
        _surface(),
        glyphCache: cache,
      );
      final int afterFirst = cache.missCount;
      rasterizeDisplayList(
        _runList(font, 'X', originX: 10, originY: 42, colorArgb: 0xFF0000FF),
        _surface(),
        glyphCache: cache,
      );

      expect(cache.missCount, afterFirst);
      expect(cache.entryCount, 1);
    });
  });

  group('parity with a hard rect fill', () {
    test('a fully covered glyph pixel composites like a filled rectangle', () {
      // The rounding contract `blend.dart` exists for. If the mask blit folded
      // coverage in with a different rounding, the interior of a stem and a
      // solid fill of the same colour would differ by a least significant bit
      // - invisible alone, and a visible seam where the two meet.
      const int colour = 0x80FF3311;
      final Framebuffer filled = _surface(width: 16, height: 16);
      final Framebuffer masked = _surface(width: 16, height: 16);

      CpuRasterizer(filled).fillRect(const Rect.fromLTRB(3, 4, 11, 12), colour);
      final GlyphMask mask = _solidMask(8, 8, 255);
      CpuRasterizer(masked).blendCoverageMask(
        mask.coverage,
        mask.width,
        mask.height,
        3,
        4,
        colour,
      );

      expect(masked.pixels, filled.pixels);
    });

    test('the same parity holds end to end, through the display list', () {
      final Framebuffer text = _surface();
      final Framebuffer rect = _surface();
      const int colour = 0xC0204080;

      rasterizeDisplayList(
        _runList(font, 'X', originX: 10, originY: 42, colorArgb: colour),
        text,
        glyphCache: GlyphCache(),
      );

      final DisplayList list = DisplayList();
      list.drawRect(10, 10, 50, 50, list.addPaint(colorArgb: colour));
      rasterizeDisplayList(list, rect);

      expect(text.pixels, rect.pixels);
    });

    test('a partial coverage is not the same as a full one', () {
      // Guards the test above from passing vacuously: if the blit ignored the
      // mask, every coverage would match the rect fill.
      final Framebuffer full = _surface(width: 8, height: 8);
      final Framebuffer half = _surface(width: 8, height: 8);
      CpuRasterizer(full).blendCoverageMask(
          _solidMask(4, 4, 255).coverage, 4, 4, 2, 2, 0xFF000000);
      CpuRasterizer(half).blendCoverageMask(
          _solidMask(4, 4, 128).coverage, 4, 4, 2, 2, 0xFF000000);

      expect(half.pixels, isNot(full.pixels));
      expect(_pixelAt(half, 3, 3)[3], 255,
          reason: 'the destination was opaque, so it stays opaque');
      expect(_pixelAt(half, 3, 3)[0], greaterThan(100),
          reason: 'half coverage over white is grey, not black');
    });

    test('zero coverage writes nothing at all', () {
      final Framebuffer surface = _surface(width: 8, height: 8);
      final Uint8List before = Uint8List.fromList(surface.pixels);
      CpuRasterizer(surface).blendCoverageMask(
          _solidMask(4, 4, 0).coverage, 4, 4, 2, 2, 0xFF000000);

      expect(surface.pixels, before);
    });
  });

  group('clipping', () {
    test('a glyph straddling the clip draws only the part inside it', () {
      final Framebuffer surface = _surface();
      rasterizeDisplayList(
        _runList(
          font,
          'X',
          originX: 10,
          originY: 42,
          clip: const Rect.fromLTRB(0, 0, 30, 96),
        ),
        surface,
        glyphCache: GlyphCache(),
      );

      // The box would span [10, 50); the clip ends at 30, so exactly the left
      // half survives and the right half must be untouched white.
      expect(_inkBounds(surface), const Rect.fromLTRB(10, 10, 30, 50));
      expect(_pixelAt(surface, 29, 30), <int>[0, 0, 0, 255]);
      expect(_pixelAt(surface, 30, 30), <int>[255, 255, 255, 255]);
    });

    test('a glyph entirely outside the clip draws nothing', () {
      final Framebuffer surface = _surface();
      rasterizeDisplayList(
        _runList(
          font,
          'X',
          originX: 10,
          originY: 42,
          clip: const Rect.fromLTRB(60, 0, 96, 96),
        ),
        surface,
        glyphCache: GlyphCache(),
      );

      expect(_inkBounds(surface), isNull);
    });

    test('the blit clips against the surface, not just the clip stack', () {
      // A glyph whose mask hangs off the top-left corner. Without the clamp
      // this reads and writes outside the buffer instead of drawing a corner.
      final Framebuffer surface = _surface(width: 8, height: 8);
      CpuRasterizer(surface).blendCoverageMask(
        _solidMask(6, 6, 255).coverage,
        6,
        6,
        -4,
        -4,
        0xFF000000,
      );

      expect(_inkBounds(surface), const Rect.fromLTRB(0, 0, 2, 2));
    });
  });

  group('the glyph cache', () {
    test('a repeated glyph is rasterized once', () {
      final GlyphCache cache = GlyphCache();
      // Ten boxes, one distinct glyph: nine of them must be hits, within the
      // very first frame.
      rasterizeDisplayList(
        _runList(font, 'XXXXXXXXXX', originX: 4, originY: 50),
        _surface(width: 512, height: 96),
        glyphCache: cache,
      );

      expect(cache.missCount, 1);
      expect(cache.hitCount, 9);
      expect(cache.entryCount, 1);
    });

    test('a second identical draw does no rasterization at all', () {
      final GlyphCache cache = GlyphCache();
      final DisplayList list = _runList(font, 'XY', originX: 10, originY: 42);
      rasterizeDisplayList(list, _surface(width: 160), glyphCache: cache);
      final int misses = cache.missCount;
      cache.resetMetrics();

      rasterizeDisplayList(list, _surface(width: 160), glyphCache: cache);

      expect(misses, 2, reason: 'two distinct glyphs on the first frame');
      expect(cache.missCount, 0, reason: 'the second frame rasterized nothing');
      expect(cache.hitCount, 2);
    });

    test('each subpixel bucket is its own entry', () {
      final GlyphCache cache = GlyphCache();
      for (final double x in <double>[10.0, 10.25, 10.5, 10.75]) {
        cache.maskFor(font, boxGlyph, subpixelBucket: glyphSubpixelBucket(x));
      }

      expect(cache.entryCount, kSubpixelBuckets);
      expect(cache.missCount, kSubpixelBuckets);

      // And the same four positions again cost nothing.
      for (final double x in <double>[10.0, 10.25, 10.5, 10.75]) {
        cache.maskFor(font, boxGlyph, subpixelBucket: glyphSubpixelBucket(x));
      }
      expect(cache.missCount, kSubpixelBuckets);
      expect(cache.hitCount, kSubpixelBuckets);
    });

    test('a pen position quantises to a bucket and a whole pixel together', () {
      // The two halves have to agree, or a glyph rounded up to the next pixel
      // would be drawn a pixel left of where it was measured.
      expect(glyphSubpixelBucket(10.0), 0);
      expect(glyphPixelOrigin(10.0), 10);
      expect(glyphSubpixelBucket(10.3), 1);
      expect(glyphPixelOrigin(10.3), 10);
      expect(glyphSubpixelBucket(10.6), 2);
      expect(glyphPixelOrigin(10.6), 10);
      expect(glyphSubpixelBucket(10.9), 0,
          reason: 'rounds up to the next whole pixel');
      expect(glyphPixelOrigin(10.9), 11);
      expect(glyphSubpixelBucket(-0.1), 0);
      expect(glyphPixelOrigin(-0.1), 0);
    });

    test('a different bucket really is a different mask', () {
      // The bucket has to reach the rasterizer, not merely the key: a cache
      // that keyed on the offset and then rasterized at zero would pass every
      // counting assertion above and still snap every glyph to the grid.
      final Typeface roboto = _face('Roboto-Regular.ttf');
      final int stem = roboto.glyphForCodePoint(0x69); // 'i'
      final GlyphCache cache = GlyphCache();
      final GlyphMask atZero = cache.maskFor(roboto.atSize(16), stem);
      final GlyphMask atHalf =
          cache.maskFor(roboto.atSize(16), stem, subpixelBucket: 2);

      expect(atHalf.coverage, isNot(atZero.coverage));
    });

    test('two faces at the same size do not collide', () {
      final GlyphCache cache = GlyphCache();
      final Typeface roboto = _face('Roboto-Regular.ttf');
      final GlyphMask box = cache.maskFor(font, boxGlyph);
      final GlyphMask letter = cache.maskFor(
        roboto.atSize(kEm),
        roboto.glyphForCodePoint(0x58),
      );

      expect(cache.entryCount, 2);
      expect(letter.coverage, isNot(box.coverage));
    });

    test('the same size in different objects is one entry', () {
      // The quantised size is what the key carries, not the identity of the
      // ScaledTypeface - otherwise a caller that builds one per draw, which
      // the type explicitly permits, would never hit.
      final GlyphCache cache = GlyphCache();
      cache.maskFor(ahem.atSize(kEm), boxGlyph);
      cache.maskFor(ahem.atSize(kEm), boxGlyph);

      expect(cache.entryCount, 1);
      expect(cache.hitCount, 1);
    });

    test('sizes closer together than the quantum share an entry', () {
      final GlyphCache cache = GlyphCache();
      cache.maskFor(ahem.atSize(20), boxGlyph);
      cache.maskFor(ahem.atSize(20 + 1 / 256), boxGlyph);
      cache.maskFor(ahem.atSize(20.5), boxGlyph);

      expect(cache.entryCount, 2,
          reason: '1/256 px rounds into the same 1/64 '
              'bucket; half a pixel does not');
    });

    test('eviction is least recently used, under the byte budget', () {
      // Two 40x40 masks fit; the third does not.
      final GlyphCache cache = GlyphCache(byteBudget: 2 * (1600 + 64));
      final int x = ahem.glyphForCodePoint(0x58);
      final int y = ahem.glyphForCodePoint(0x59);
      final int z = ahem.glyphForCodePoint(0x5A);

      cache.maskFor(font, x);
      cache.maskFor(font, y);
      expect(cache.entryCount, 2);
      expect(cache.evictionCount, 0);
      expect(cache.byteCount, lessThanOrEqualTo(cache.byteBudget));

      // Touch x so y becomes the least recently used, then overflow.
      cache.maskFor(font, x);
      cache.maskFor(font, z);

      expect(cache.entryCount, 2);
      expect(cache.evictionCount, 1);
      expect(cache.byteCount, lessThanOrEqualTo(cache.byteBudget));

      cache.resetMetrics();
      cache.maskFor(font, x);
      expect(cache.hitCount, 1,
          reason: 'x was used most recently, so it stayed');
      cache.maskFor(font, y);
      expect(cache.missCount, 1, reason: 'y was the least recently used');
    });

    test('a mask larger than the whole budget bypasses the cache', () {
      final GlyphCache cache = GlyphCache(byteBudget: 128);
      final GlyphMask mask = cache.maskFor(font, boxGlyph);

      expect(mask.isEmpty, isFalse, reason: 'it is still rasterized');
      expect(cache.entryCount, 0,
          reason: 'storing it would evict everything '
              'and then still not fit');
      expect(cache.bypassCount, 1);
    });

    test('invalidating a face drops its masks and bumps the generation', () {
      final GlyphCache cache = GlyphCache();
      final Typeface roboto = _face('Roboto-Regular.ttf');
      cache.maskFor(font, boxGlyph);
      cache.maskFor(roboto.atSize(20), roboto.glyphForCodePoint(0x41));
      final int before = cache.generation;

      cache.invalidate(ahem);

      expect(cache.entryCount, 1, reason: "Roboto's mask is untouched");
      expect(cache.generation, greaterThan(before));
      expect(cache.byteCount, greaterThan(0));

      cache.clear();
      expect(cache.entryCount, 0);
      expect(cache.byteCount, 0);
    });

    test('eviction does not bump the generation', () {
      // Eviction is invisible - the same key rasterizes to the same mask - so
      // anything watching the generation for staleness must not be woken by it.
      final GlyphCache cache = GlyphCache(byteBudget: 1600 + 64);
      final int before = cache.generation;
      cache.maskFor(font, ahem.glyphForCodePoint(0x58));
      cache.maskFor(font, ahem.glyphForCodePoint(0x59));

      expect(cache.evictionCount, 1);
      expect(cache.generation, before);
    });

    test('a bad subpixel bucket is refused rather than silently wrapped', () {
      expect(
        () => GlyphCache().maskFor(font, boxGlyph, subpixelBucket: 4),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('font interning', () {
    test('one face at one size interns to one id', () {
      final DisplayList list = DisplayList();

      expect(list.addFont(font), 0);
      expect(list.addFont(font), 0);
      expect(list.fontCount, 1);
      expect(identical(list.fontAt(0), font), isTrue);
    });

    test('a different size is a different font', () {
      // The whole reason the opcode carries no size: the id is the (face,
      // size) pair, so two sizes cannot share one.
      final DisplayList list = DisplayList();
      final int large = list.addFont(font);
      final int small = list.addFont(ahem.atSize(12));

      expect(small, isNot(large));
      expect(list.fontCount, 2);
    });

    test('reset drops the font table with every other resource', () {
      final DisplayList list = DisplayList()..addFont(font);
      list.reset();

      expect(list.fontCount, 0);
      expect(list.addFont(ahem.atSize(12)), 0);
    });

    test('two sizes in one list draw at their own sizes', () {
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF000000);
      final Int32List ids = Int32List.fromList(<int>[boxGlyph]);
      final Float32List offsets = Float32List(2);
      list.drawGlyphRun(list.addFont(font), paint, 4, 44, ids, offsets, 1);
      list.drawGlyphRun(
        list.addFont(ahem.atSize(10)),
        paint,
        60,
        44,
        ids,
        offsets,
        1,
      );

      final Framebuffer surface = _surface();
      rasterizeDisplayList(list, surface, glyphCache: GlyphCache());

      // Both boxes sit on the baseline at y = 44, rising 0.8 of their em and
      // descending 0.2: the 40 px one spans y 12..52, the 10 px one 36..46.
      expect(_inkBounds(surface), const Rect.fromLTRB(4, 12, 70, 52));
      expect(_pixelAt(surface, 5, 13), <int>[0, 0, 0, 255]);
      expect(_pixelAt(surface, 61, 13), <int>[255, 255, 255, 255],
          reason: 'the small box starts 8 px above the baseline, not 32');
    });
  });

  group('what the CPU renderer refuses', () {
    test('a rotated transform, rather than drawing upright text', () {
      expect(
        () => rasterizeDisplayList(
          _runList(font, 'X', originX: 10, originY: 42),
          _surface(),
          deviceTransform: Transform2D.rotation(0.5),
          glyphCache: GlyphCache(),
        ),
        throwsA(isA<UnsupportedCapabilityError>()),
      );
    });

    test('a stroke-styled paint, rather than filling the outline', () {
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(
        colorArgb: 0xFF000000,
        style: paintStyleStroke,
        strokeWidth: 2,
      );
      list.drawGlyphRun(
        list.addFont(font),
        paint,
        10,
        42,
        Int32List.fromList(<int>[boxGlyph]),
        Float32List(2),
        1,
      );

      expect(
        () => rasterizeDisplayList(list, _surface(), glyphCache: GlyphCache()),
        throwsA(isA<UnsupportedCapabilityError>()),
      );
    });

    test('a font resource that is not a face', () {
      final DisplayList list = DisplayList();
      list.drawGlyphRun(
        list.addFont('not a font'),
        list.addPaint(colorArgb: 0xFF000000),
        10,
        42,
        Int32List.fromList(<int>[boxGlyph]),
        Float32List(2),
        1,
      );

      expect(
        () => rasterizeDisplayList(list, _surface(), glyphCache: GlyphCache()),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('the device transform', () {
    test('a uniform scale rasterizes at the device size, not a scaled mask',
        () {
      final Framebuffer surface = _surface(width: 192, height: 192);
      rasterizeDisplayList(
        _runList(font, 'X', originX: 10, originY: 42),
        surface,
        deviceTransform: const Transform2D(2, 0, 0, 2, 0, 0),
        glyphCache: GlyphCache(),
      );

      // Pen at (20, 84) in device space, an 80 px box rising 64 px.
      expect(_inkBounds(surface), const Rect.fromLTRB(20, 20, 100, 100));
      // Every pixel solid: a mask that had been scaled up from 40 px would
      // have a soft, resampled edge instead.
      for (int x = 20; x < 100; x++) {
        expect(_pixelAt(surface, x, 60), <int>[0, 0, 0, 255]);
      }
    });
  });
}
