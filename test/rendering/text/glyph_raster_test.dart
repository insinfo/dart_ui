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
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/transform2d.dart';
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

  group('which route a matrix takes', () {
    // [glyphMasksFit] is the single criterion both sinks import. Everything it
    // accepts is drawn by blitting a cached mask; everything it rejects is
    // drawn by filling the outline. A false negative costs a fill; a false
    // positive costs a wrong picture - so these cases are named one by one
    // rather than left to a rule of thumb.

    test('the identity and a plain uniform scale take the mask', () {
      expect(glyphMasksFit(Transform2D.identity), isTrue);
      expect(glyphMasksFit(const Transform2D.scaling(2, 2)), isTrue);
      expect(glyphMasksFit(const Transform2D.scaling(1.5, 1.5)), isTrue);
      // A translation is not part of the criterion at all: the pen carries it,
      // and a whole-pixel blit can be moved anywhere.
      expect(glyphMasksFit(const Transform2D(3, 0, 0, 3, -40.5, 12)), isTrue);
    });

    test('rotation, skew, mirroring and anisotropy take the outline', () {
      expect(glyphMasksFit(Transform2D.rotation(math.pi / 2)), isFalse,
          reason: 'even a quarter turn, which lands back on the pixel grid');
      expect(glyphMasksFit(Transform2D.rotation(0.001)), isFalse);
      expect(glyphMasksFit(const Transform2D(1, 0, 0.4, 1, 0, 0)), isFalse,
          reason: 'a horizontal skew - a synthetic italic');
      expect(glyphMasksFit(const Transform2D.scaling(-1, 1)), isFalse,
          reason: 'a mirror: no positive scale can express it');
      expect(glyphMasksFit(const Transform2D.scaling(1, -1)), isFalse);
      expect(glyphMasksFit(const Transform2D.scaling(2, 3)), isFalse,
          reason: 'there is no single size to rasterise one mask at');
      expect(glyphMasksFit(const Transform2D.scaling(0, 0)), isFalse,
          reason: 'a collapsed matrix has no mask either');
    });

    test('a scale uniform only to within a rounding error still takes the '
        'outline', () {
      // The comparison is exact on purpose. There is no epsilon that is right
      // at 8 px and at 200 px, and the outline route draws the near-uniform
      // case correctly at the cost of a fill - which is the safe direction to
      // be wrong in.
      const double slightlyOff = 1.0000000000000002;
      expect(glyphMasksFit(const Transform2D(1, 0, 0, slightlyOff, 0, 0)),
          isFalse);
    });
  });

  group('the outline transform', () {
    // `glyphOutlineTransform` is the whole of the coordinate change the
    // outline route makes: font units, y up, from the glyph's own origin, to
    // device pixels, y down, under an arbitrary affine matrix. Every one of
    // these tests is a place a sign or a factor going astray produces text
    // that is upside down, mirrored, or the wrong size - and looks like a font
    // bug rather than a matrix one.

    test('under the identity it is scale-and-flip about the pen', () {
      final Transform2D m =
          glyphOutlineTransform(Transform2D.identity, 0.25, 100, 50);

      // The glyph's origin is the pen.
      expect(m.transformOffset(Offset.zero), const Offset(100, 50));
      // A point one em to the right and one em up, in a 1000-upem face at
      // scale 0.25: 250 px right, and 250 px *up*, which is -y on screen.
      expect(m.transformOffset(const Offset(1000, 1000)),
          const Offset(350, -200));
    });

    test('it agrees with the mask route wherever both are defined', () {
      // The claim that makes the split safe: on a matrix [glyphMasksFit]
      // accepts, the general route reduces to exactly the matrix
      // [GlyphRasterizer.render] builds - `scale(s * k, -s * k)` about the
      // pen. If these two ever diverged, a glyph would move as an animated
      // scale crossed the threshold between them.
      const Transform2D uniform = Transform2D.scaling(3, 3);
      final Transform2D general = glyphOutlineTransform(uniform, 0.02, 7, 11);
      const Transform2D mask = Transform2D(0.06, 0, 0, -0.06, 7, 11);

      for (final Offset point in <Offset>[
        Offset.zero,
        const Offset(1000, 0),
        const Offset(0, 700),
        const Offset(-120, 940),
      ]) {
        expect(general.transformOffset(point), mask.transformOffset(point));
      }
    });

    test('a quarter turn sends the glyph up the screen, not across it', () {
      // Transform2D.rotation(pi / 2) maps (x, y) to (-y, x). Composed with the
      // y flip the glyph already carries, a point *above* the baseline - the
      // top of a capital - has to end up to the *right* of the pen.
      final Transform2D m = glyphOutlineTransform(
        Transform2D.rotation(math.pi / 2),
        0.05,
        20,
        20,
      );

      final Offset top = m.transformOffset(const Offset(0, 1000));
      expect(top.dx, closeTo(70, 1e-9),
          reason: 'the cap height turned into a horizontal offset');
      expect(top.dy, closeTo(20, 1e-9));

      final Offset right = m.transformOffset(const Offset(1000, 0));
      expect(right.dx, closeTo(20, 1e-9));
      expect(right.dy, closeTo(70, 1e-9),
          reason: 'the advance turned into a vertical one, downward');
    });

    test('a mirror reverses the winding, which the determinant reports', () {
      // Not a curiosity: a negative determinant means every contour of the
      // glyph runs the other way in device space. Non-zero winding is
      // sign-agnostic and so the glyph still fills - which is why the outline
      // route can use one rule for both - but a rasteriser that assumed a
      // positive orientation would empty the letter and fill its counters.
      final Transform2D upright =
          glyphOutlineTransform(Transform2D.identity, 0.1, 0, 0);
      final Transform2D mirrored =
          glyphOutlineTransform(const Transform2D.scaling(-1, 1), 0.1, 0, 0);

      expect(upright.determinant, lessThan(0),
          reason: 'the y flip alone already reverses it once');
      expect(mirrored.determinant, greaterThan(0),
          reason: 'and the mirror reverses it back');
    });

    test('the pen is the translation and nothing else moves with it', () {
      // The layer shift in `cpu_renderer.dart` subtracts a whole-pixel origin
      // from the pen alone, on the strength of exactly this: a translation
      // cannot touch the linear part.
      final Transform2D at0 = glyphOutlineTransform(
          Transform2D.rotation(0.3), 0.04, 0, 0);
      final Transform2D at100 = glyphOutlineTransform(
          Transform2D.rotation(0.3), 0.04, 100, -60);

      expect(at100.a, at0.a);
      expect(at100.b, at0.b);
      expect(at100.c, at0.c);
      expect(at100.d, at0.d);
      expect(at100.tx, 100);
      expect(at100.ty, -60);
    });

    test('a real glyph lands where the matrix says it should', () {
      // The end-to-end check, on an outline rather than on synthetic points.
      // Ahem's letter is a solid em box from -0.2 em to 0.8 em; a quarter turn
      // must swap the extents of its bounding box about the pen.
      final ScaledTypeface font = ahem.atSize(20);
      final Rect fontUnits =
          ahem.outlineOf(ahem.glyphForCodePoint(0x58)).bounds;

      final Rect upright = glyphOutlineTransform(
        Transform2D.identity,
        font.scale,
        0,
        0,
      ).transformRect(fontUnits);
      final Rect turned = glyphOutlineTransform(
        Transform2D.rotation(math.pi / 2),
        font.scale,
        0,
        0,
      ).transformRect(fontUnits);

      expect(upright.width, closeTo(20, 1e-6));
      expect(upright.height, closeTo(20, 1e-6));
      expect(turned.width, closeTo(upright.height, 1e-6));
      expect(turned.height, closeTo(upright.width, 1e-6));
      // Upright the box rises above the baseline: its top is negative. Turned
      // a quarter turn clockwise on screen, that same edge is now to the
      // right of the pen.
      expect(upright.top, closeTo(-16, 1e-6));
      expect(turned.right, closeTo(16, 1e-6));
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
