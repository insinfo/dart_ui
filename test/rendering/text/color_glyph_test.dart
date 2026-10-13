/// Colour glyphs, from the font table to the framebuffer, and the fallback
/// that brings an emoji face into a run in the first place.
///
/// The colour face is built in memory: DejaVu Sans, which maps U+1F600 to an
/// ordinary outline, with an `sbix` table grafted on that gives that glyph a
/// solid red picture. So "an image was drawn and the outline was not" is a
/// question about red pixels, and the answer is the same on every machine.
/// One test at the end uses the machine's real emoji face and is skipped
/// where there is none.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/graphics/display_list_reader.dart';
import 'package:dart_ui/src/platform/system_fonts.dart';
import 'package:dart_ui/src/rendering/cpu_renderer.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:dart_ui/src/rendering/text/color_glyph_cache.dart';
import 'package:dart_ui/src/rendering/text/font_registry.dart';
import 'package:dart_ui/src/rendering/text/text_painter.dart';
import 'package:dart_ui/src/text/cmap.dart';
import 'package:dart_ui/src/text/font_fallback.dart';
import 'package:dart_ui/src/text/paragraph.dart';
import 'package:dart_ui/src/text/shaper.dart';
import 'package:dart_ui/src/text/typeface.dart';
import 'package:test/test.dart';

import '../../text/color_font_fixtures.dart';

const int _grin = 0x1F600;

/// DejaVu Sans with a 16 ppem `sbix` strike: a 16x16 red square for 😀 and
/// for ©, standing on the baseline.
Typeface _colourFace() {
  final Uint8List dejaVu = fixtureFontBytes('DejaVuSans.ttf');
  final Typeface plain = Typeface.parse(dejaVu);
  final Uint8List red = solidPng(16, 16, 0xFFFF0000);
  return Typeface.parse(withTables(dejaVu, <String, Uint8List>{
    'sbix': sbixTable(glyphCount: plain.glyphCount, strikes: {
      16: <int, SbixRecord>{
        plain.glyphForCodePoint(_grin): SbixRecord('png ', red),
        plain.glyphForCodePoint(0xA9): SbixRecord('png ', red),
      },
    }),
  }));
}

Typeface _roboto() => Typeface.parse(fixtureFontBytes('Roboto-Regular.ttf'));

/// A fallback that always offers [face], and records what it was asked.
final class _Stub implements FontFallback {
  _Stub(this.face);

  final Typeface face;
  final List<(int, bool)> asked = <(int, bool)>[];

  @override
  Typeface? fallbackFace(
    int codePoint,
    Typeface primary, {
    bool emojiPresentation = false,
  }) {
    asked.add((codePoint, emojiPresentation));
    return face.coversCodePoint(codePoint) ? face : null;
  }
}

/// The ops [list] holds: images by destination, glyph ids of every run.
({List<List<double>> images, List<int> glyphs}) _ops(DisplayList list) {
  final List<List<double>> images = <List<double>>[];
  final List<int> glyphs = <int>[];
  final DisplayListReader reader = DisplayListReader(list);
  while (reader.moveNext()) {
    if (reader.opcode == opDrawImage) {
      images.add(<double>[
        for (int i = 4; i < 8; i++) reader.floatAt(i),
      ]);
    } else if (reader.opcode == opDrawGlyphRun) {
      for (int i = 0; i < reader.glyphCount; i++) {
        glyphs.add(reader.glyphIdAt(i));
      }
    }
  }
  return (images: images, glyphs: glyphs);
}

Future<Framebuffer> _render(DisplayList list, Size size) async {
  final RenderDevice device = await const CpuRendererBackend().createDevice();
  final MemoryRenderTarget target = device.createTarget(
    MemorySurfaceDescriptor(
      pixelWidth: size.width.toInt(),
      pixelHeight: size.height.toInt(),
    ),
  ) as MemoryRenderTarget;
  final result = await target.renderDisplayList(list, clearColor: 0xFFFFFFFF);
  expect(result.isSuccess, isTrue, reason: 'render failed: $result');
  return target.framebuffer;
}

/// (r, g, b) at ([x], [y]), whichever order the buffer stores.
(int, int, int) _rgb(Framebuffer buffer, int x, int y) {
  final int i = buffer.offsetOf(x, y);
  final Uint8List p = buffer.pixels;
  return buffer.format == PixelFormat.bgra8888Premultiplied
      ? (p[i + 2], p[i + 1], p[i])
      : (p[i], p[i + 1], p[i + 2]);
}

void main() {
  final Typeface colour = _colourFace();
  final int grinGlyph = colour.glyphForCodePoint(_grin);

  group('painting', () {
    test('a glyph with a picture becomes an image, not an outline', () async {
      final TextPainter painter = TextPainter(colorGlyphs: ColorGlyphCache());
      final ScaledTypeface font = colour.atSize(16);
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFF000000, antiAlias: true);

      final GlyphRun run =
          painter.paint(list, 'A\u{1F600}', font, const Offset(10, 30), paint);
      final ({List<List<double>> images, List<int> glyphs}) ops = _ops(list);

      // The "A" is an outline; the smiley is a picture and only a picture.
      expect(ops.glyphs, <int>[colour.glyphForCodePoint(0x41)]);
      expect(ops.images, hasLength(1));
      // At its pen position, standing on the baseline, 16 px at 16 ppem.
      final double pen = 10 + run.xOf(1);
      expect(ops.images.single, <double>[
        pen.roundToDouble(),
        14,
        pen.roundToDouble() + 16,
        30,
      ]);

      final Framebuffer pixels = await _render(list, const Size(80, 40));
      final int x = pen.round() + 8;
      expect(_rgb(pixels, x, 22), (255, 0, 0), reason: 'the picture');
      expect(_rgb(pixels, x, 35), (255, 255, 255), reason: 'below baseline');
    });

    test('the picture is scaled to the text size, from the nearest strike', () {
      final ColorGlyphCache cache = ColorGlyphCache();
      final ColorGlyphImage half = cache.lookup(colour, grinGlyph, 8)!;
      expect((half.width, half.height), (8, 8));
      expect(half.left, 0);
      expect(half.top, -8, reason: 'its bottom edge on the baseline');

      final ColorGlyphImage double_ = cache.lookup(colour, grinGlyph, 32)!;
      expect((double_.width, double_.height), (32, 32));

      // A glyph with no picture is drawn from its outline.
      expect(cache.lookup(colour, colour.glyphForCodePoint(0x41), 16), isNull);
    });

    test('a picture is decoded once, however often it is drawn', () {
      final ColorGlyphCache cache = ColorGlyphCache();
      final TextPainter painter = TextPainter(colorGlyphs: cache);
      final ScaledTypeface font = colour.atSize(16);
      for (int frame = 0; frame < 5; frame++) {
        final DisplayList list = DisplayList();
        painter.paint(list, '\u{1F600}\u{1F600}', font, Offset.zero, 0);
        expect(_ops(list).images, hasLength(2));
      }
      // And a second size reuses the decode: the strike is the picture.
      final ColorGlyphImage? first = cache.lookup(colour, grinGlyph, 16);
      cache.lookup(colour, grinGlyph, 12);
      expect(cache.decodeCount, 1);
      expect(identical(cache.lookup(colour, grinGlyph, 16), first), isTrue,
          reason: 'one Framebuffer per entry, so a GPU uploads it once');
    });
  });

  group('paragraph fallback', () {
    test('a character the face lacks is shaped in the fallback face', () {
      final Typeface roboto = _roboto();
      expect(roboto.coversCodePoint(_grin), isFalse);
      final _Stub stub = _Stub(colour);
      final TextPainter painter =
          TextPainter(fallback: stub, colorGlyphs: ColorGlyphCache());
      final ScaledTypeface font = roboto.atSize(16);

      final Paragraph paragraph = painter.layout('a\u{1F600}b', font);
      final List<GlyphSpan> spans = paragraph.lines.single.spans;
      expect(spans, hasLength(3), reason: 'split where the face changes');
      expect(spans[1].glyphs.font.typeface, same(colour));
      expect(spans[0].glyphs.font.typeface, same(roboto));
      expect(stub.asked, <(int, bool)>[(_grin, false)]);

      // Measured into the line with the span's face: a fallback does not
      // make the line taller.
      expect(paragraph.height, painter.layout('ab', font).height);

      final DisplayList list = DisplayList();
      painter.paintParagraph(list, paragraph, Offset.zero, 0);
      final ({List<List<double>> images, List<int> glyphs}) ops = _ops(list);
      expect(ops.images, hasLength(1));
      expect(ops.glyphs, isNot(contains(notdefGlyph)));
    });

    test('U+FE0F asks for the emoji face even when the span has the glyph', () {
      final Typeface roboto = _roboto();
      expect(roboto.coversCodePoint(0xA9), isTrue);
      final _Stub stub = _Stub(colour);
      final TextPainter painter = TextPainter(fallback: stub);
      final ScaledTypeface font = roboto.atSize(16);

      // Without the selector, the span's own (c) stands and nobody is asked.
      final Paragraph plain = painter.layout('a\u00A9', font);
      expect(plain.lines.single.spans, hasLength(1));
      expect(stub.asked, isEmpty);

      final Paragraph emoji = painter.layout('a\u00A9\uFE0F', font);
      expect(stub.asked, <(int, bool)>[(0xA9, true)]);
      final GlyphSpan last = emoji.lines.single.spans.last;
      expect(last.glyphs.font.typeface, same(colour));
      expect(last.start, 1);
      expect(last.end, 3, reason: 'the selector stays with its base');
    });

    test('no fallback means the old behaviour, and no cluster is split', () {
      final Typeface roboto = _roboto();
      final Paragraph paragraph =
          TextPainter().layout('a\u{1F600}b', roboto.atSize(16));
      expect(paragraph.lines.single.spans, hasLength(1));
      expect(TextPainter().needsFallback('a\u{1F600}', roboto.atSize(16)),
          isFalse);
      expect(
        TextPainter(fallback: _Stub(colour))
            .needsFallback('a\u{1F600}', roboto.atSize(16)),
        isTrue,
      );
      expect(
        TextPainter(fallback: _Stub(colour))
            .needsFallback('a\u200Db', roboto.atSize(16)),
        isFalse,
        reason: 'an ignorable the face lacks needs nothing',
      );
    });
  });

  group('the registry', () {
    /// A registry that sees only the fixtures, with Roboto for the interface
    /// and the colour face registered as this platform's emoji family.
    FontRegistry registry() {
      final FontRegistry registry = FontRegistry(
        search: () => null,
        index: SystemFontIndex.build(
          files: const <SystemFontFile>[
            SystemFontFile(
              path: 'test/fonts/Roboto-Regular.ttf',
              fileName: 'Roboto-Regular.ttf',
            ),
          ],
          reader: readSystemFontFaces,
        ),
      )..useTypeface(_roboto(), source: 'roboto');
      registry.registerTypeface(
        colour,
        family: FontRegistry.emojiFamilies().first,
        source: 'colour',
      );
      return registry;
    }

    test('an emoji falls back to the emoji family, and is drawable', () {
      final FontRegistry fonts = registry();
      final Typeface roboto = fonts.uiTypeface!;

      expect(fonts.fallbackFace(_grin, roboto), same(colour));
      expect(fonts.resolveCodePoint(_grin).face, same(colour));
      // The selector reaches the emoji face even for a character Roboto has.
      expect(
        fonts.fallbackFace(0xA9, roboto, emojiPresentation: true),
        same(colour),
      );
      expect(fonts.fallbackFace(0xA9, roboto), isNull);

      final EmojiResolution grin = fonts.resolveEmoji('\u{1F600}');
      expect(grin.face, same(colour));
      expect(grin.colourTable, 'sbix');
      expect(grin.drawable, isTrue);
      expect(grin.limitation ?? '', isNot(contains('does not implement')));
    });
  });

  group('the machine', () {
    test('real emoji draw as pictures with no box anywhere', () {
      final FontRegistry fonts = FontRegistry(search: () => null)
        ..useTypeface(_roboto(), source: 'roboto');
      if (fonts.systemFonts.isEmpty) {
        markTestSkipped('no readable font on this machine');
        return;
      }
      final EmojiResolution probe = fonts.resolveEmoji('\u{1F600}');
      if (probe.face?.colorBitmaps == null) {
        markTestSkipped('no sbix or CBDT emoji face on this machine');
        return;
      }

      final TextPainter painter =
          TextPainter(fallback: fonts, colorGlyphs: ColorGlyphCache());
      final ScaledTypeface font = fonts.uiFont(24)!;
      // Smiley, party popper, heart + VS16, thumbs-up + skin tone.
      final Paragraph paragraph = painter.layout(
        'Hello \u{1F600} \u{1F389} \u2764\uFE0F \u{1F44D}\u{1F3FD} done',
        font,
      );
      final DisplayList list = DisplayList();
      painter.paintParagraph(list, paragraph, Offset.zero, 0);
      final ({List<List<double>> images, List<int> glyphs}) ops = _ops(list);

      // Five pictures: the skin tone is not ligated (no `morx` here), so it
      // is its own swatch after the thumb - but a picture, not a box.
      expect(ops.images, hasLength(5));
      expect(ops.glyphs, isNot(contains(notdefGlyph)));
    });
  });
}
