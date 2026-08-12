/// Glyph outlines through the framework's own rasterizer.
///
/// The assertions here are mostly about *geometry* rather than about exact
/// pixels: a coverage value depends on the antialiasing arithmetic, which has
/// its own tests, while "is the glyph the right way up, the right size, and in
/// the right place relative to the baseline" is what this layer decides and
/// what silently breaks when a sign is wrong.
///
/// `tool/show_glyph.dart` prints these masks as ASCII art, which is the way to
/// find out whether a failure is a real regression or a better rendering.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/rendering/text/glyph_raster.dart';
import 'package:dart_ui/src/text/typeface.dart';
import 'package:test/test.dart';

Typeface _face(String name) =>
    Typeface.parse(File('test/fonts/$name').readAsBytesSync());

void main() {
  late Typeface roboto;
  late Typeface ahem;
  late GlyphRasterizer rasterizer;

  setUp(() {
    roboto = _face('Roboto-Regular.ttf');
    ahem = _face('ahem.ttf');
    rasterizer = GlyphRasterizer();
  });

  group('geometry', () {
    test('a glyph rasterizes to a mask of plausible size', () {
      final ScaledTypeface font = roboto.atSize(24);
      final GlyphMask mask =
          rasterizer.render(font, roboto.glyphForCodePoint(0x41)); // 'A'

      expect(mask.isEmpty, isFalse);
      // A 24 px capital is around 17 px tall; the bound is loose because it is
      // asserting "a plausible glyph", not a particular font's design.
      expect(mask.height, inInclusiveRange(12, 26));
      expect(mask.width, inInclusiveRange(8, 26));
    });

    test('the mask sits above the baseline, which is what negative top means',
        () {
      final ScaledTypeface font = roboto.atSize(24);
      final GlyphMask capital =
          rasterizer.render(font, roboto.glyphForCodePoint(0x41)); // 'A'

      // The pen sits on the baseline and y grows downward, so a capital's mask
      // begins above it. A positive top here would mean the glyph was flipped
      // and text would render upside down.
      expect(capital.top, lessThan(0));
      expect(capital.top + capital.height, lessThanOrEqualTo(1),
          reason: "'A' does not descend below the baseline");
    });

    test('a descender crosses the baseline and an x-height letter does not',
        () {
      final ScaledTypeface font = roboto.atSize(24);
      final GlyphMask g =
          rasterizer.render(font, roboto.glyphForCodePoint(0x67)); // 'g'
      final GlyphMask x =
          rasterizer.render(font, roboto.glyphForCodePoint(0x78)); // 'x'

      expect(g.top + g.height, greaterThan(1), reason: "'g' descends");
      expect(x.top + x.height, lessThanOrEqualTo(1), reason: "'x' does not");
      expect(g.height, greaterThan(x.height));
    });

    test('doubling the size roughly doubles the mask', () {
      final GlyphMask small =
          rasterizer.render(roboto.atSize(20), roboto.glyphForCodePoint(0x48));
      final GlyphMask large =
          rasterizer.render(roboto.atSize(40), roboto.glyphForCodePoint(0x48));

      expect(large.height, closeTo(small.height * 2, 2));
      expect(large.width, closeTo(small.width * 2, 2));
    });

    test('a glyph with no outline produces an empty mask', () {
      final GlyphMask space = rasterizer.render(
        roboto.atSize(24),
        roboto.glyphForCodePoint(0x20),
      );

      expect(space.isEmpty, isTrue);
      expect(space.coverageAt(0, 0), 0);
    });

    test('a composite glyph rasterizes its accent too', () {
      final ScaledTypeface font = roboto.atSize(28);
      final GlyphMask a =
          rasterizer.render(font, roboto.glyphForCodePoint(0x61)); // 'a'
      final GlyphMask accented =
          rasterizer.render(font, roboto.glyphForCodePoint(0xE1)); // 'á'

      // The accent adds height above the letter, so the mask starts higher up.
      expect(accented.height, greaterThan(a.height));
      expect(accented.top, lessThan(a.top));

      // And there must be ink up there, not just an enlarged empty box.
      int inkInTopRows = 0;
      for (int y = 0; y < a.top - accented.top; y++) {
        for (int x = 0; x < accented.width; x++) {
          if (accented.coverageAt(x, y) > 0) inkInTopRows++;
        }
      }
      expect(inkInTopRows, greaterThan(0), reason: 'the accent has no pixels');
    });
  });

  group('coverage', () {
    test("Ahem's solid box is solid, and exactly one em", () {
      // The fixture that makes an exact assertion possible: every Ahem glyph
      // is a filled rectangle, so the interior must be fully covered and the
      // extents must be the em box to the pixel.
      final ScaledTypeface font = ahem.atSize(40);
      final GlyphMask mask =
          rasterizer.render(font, ahem.glyphForCodePoint(0x58)); // 'X'

      expect(mask.width, 40);
      expect(mask.height, 40, reason: '0.8 em above plus 0.2 em below');
      expect(mask.top, -32, reason: 'the box rises 0.8 of 40 px');

      // Interior fully covered. Edges are excluded because an exact-area
      // rasterizer legitimately reports partial coverage on a boundary pixel.
      for (int y = 1; y < mask.height - 1; y++) {
        for (int x = 1; x < mask.width - 1; x++) {
          expect(mask.coverageAt(x, y), 255,
              reason: 'interior pixel ($x, $y) is not solid');
        }
      }
    });

    test('coverage is antialiased rather than binary', () {
      final GlyphMask mask = rasterizer.render(
        roboto.atSize(24),
        roboto.glyphForCodePoint(0x4F), // 'O', all curves
      );

      final Set<int> values = <int>{};
      for (int i = 0; i < mask.coverage.length; i++) {
        values.add(mask.coverage[i]);
      }
      // A binary rasterizer produces two values. An exact-area one produces a
      // ramp, and that ramp is the whole reason text is legible at 24 px.
      expect(values.length, greaterThan(8));
      expect(values, contains(255));
      expect(values.any((int v) => v > 0 && v < 255), isTrue);
    });

    test('every mask byte is inside the mask', () {
      // The span sink writes with fillRange, so an off-by-one in the row
      // arithmetic would corrupt a neighbouring row rather than throw.
      final ScaledTypeface font = roboto.atSize(18);
      for (final int code in <int>[0x41, 0x67, 0x4F, 0xE1, 0x40]) {
        final GlyphMask mask =
            rasterizer.render(font, roboto.glyphForCodePoint(code));
        expect(mask.coverage.length, mask.width * mask.height);
      }
    });
  });

  group('subpixel positioning', () {
    test('a fractional offset changes the pixels', () {
      final ScaledTypeface font = roboto.atSize(16);
      final int glyph = roboto.glyphForCodePoint(0x69); // 'i', a bare stem

      final GlyphMask atZero = rasterizer.render(font, glyph);
      final GlyphMask atHalf =
          rasterizer.render(font, glyph, subpixelOffsetX: 0.5);

      // If these were identical, every glyph would be snapping to the pixel
      // grid and a run of text would show uneven letter spacing.
      expect(
        _coverageOf(atZero) == _coverageOf(atHalf) &&
            atZero.left == atHalf.left,
        isFalse,
      );
    });

    test('a whole-pixel offset just moves the mask', () {
      final ScaledTypeface font = roboto.atSize(16);
      final int glyph = roboto.glyphForCodePoint(0x48);

      final GlyphMask atZero = rasterizer.render(font, glyph);
      final GlyphMask atOne =
          rasterizer.render(font, glyph, subpixelOffsetX: 1);

      expect(atOne.left, atZero.left + 1);
      expect(atOne.width, atZero.width);
      expect(_coverageOf(atOne), _coverageOf(atZero));
    });
  });

  test('rasterizing a large face never throws', () {
    // The blunt sweep: every glyph of a 6000-glyph face at a small size, where
    // rounding is tightest and a degenerate contour is most likely to bite.
    final Typeface dejaVu = _face('DejaVuSans.ttf');
    final ScaledTypeface font = dejaVu.atSize(11);
    int drawn = 0;

    for (int glyph = 0; glyph < dejaVu.glyphCount; glyph++) {
      final GlyphMask mask = rasterizer.render(font, glyph);
      if (!mask.isEmpty) drawn++;
    }

    expect(drawn, greaterThan(5000));
  });
}

String _coverageOf(GlyphMask mask) {
  final Uint8List bytes = mask.coverage;
  final StringBuffer buffer = StringBuffer();
  for (int i = 0; i < bytes.length; i++) {
    buffer.write(bytes[i].toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}
