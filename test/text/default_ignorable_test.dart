/// Default-ignorable characters draw as nothing when the face has no glyph.
///
/// Roboto, the fixture, maps none of `U+FE0F`, `U+200D`, `U+200C`, `U+2060`
/// or `U+E0100` - which is the ordinary case for an interface face, and the
/// case that used to draw a `.notdef` box beside every ❤️.
library;

import 'dart:io';

import 'package:dart_ui/src/text/cmap.dart';
import 'package:dart_ui/src/text/default_ignorable.dart';
import 'package:dart_ui/src/text/shaper.dart';
import 'package:dart_ui/src/text/typeface.dart';
import 'package:test/test.dart';

void main() {
  final Typeface roboto =
      Typeface.parse(File('test/fonts/Roboto-Regular.ttf').readAsBytesSync());
  final ScaledTypeface font = roboto.atSize(20);
  final int space = roboto.glyphForCodePoint(0x20);

  const List<int> ignorables = <int>[
    0xFE0F, // VS16
    0xFE00, // VS1
    0xE0100, // VS17
    0x200D, // ZWJ
    0x200C, // ZWNJ
    0x2060, // WORD JOINER
    0x202E, // RLO
    0xE0041, // TAG LATIN CAPITAL LETTER A
  ];

  test('the property matches the Unicode list at its edges', () {
    for (final int codePoint in <int>[
      ...ignorables,
      0x00AD,
      0x034F,
      0x180B,
      0x180F,
      0x200B,
      0x206F,
      0xFEFF,
      0xE01EF,
      0xE0FFF,
    ]) {
      expect(isDefaultIgnorable(codePoint), isTrue,
          reason: 'U+${codePoint.toRadixString(16)}');
    }
    for (final int codePoint in <int>[
      0x20,
      0x41,
      0xAC,
      0x2010,
      0x2070,
      0xFE10,
      0x1F600,
      0x1F3FD,
      0xE1000,
    ]) {
      expect(isDefaultIgnorable(codePoint), isFalse,
          reason: 'U+${codePoint.toRadixString(16)}');
    }
    expect(isVariationSelector(0xFE0F), isTrue);
    expect(isVariationSelector(0xE0100), isTrue);
    expect(isVariationSelector(0x200D), isFalse);
  });

  test('the fixture really lacks them, or this file proves nothing', () {
    for (final int codePoint in ignorables) {
      expect(roboto.glyphForCodePoint(codePoint), notdefGlyph);
    }
    expect(space, isNot(notdefGlyph));
  });

  for (final Shaper shaper in <Shaper>[
    OpenTypeShaper(applyKerning: false),
    LatinShaper(applyKerning: false),
  ]) {
    group('${shaper.runtimeType}', () {
      test('each shapes to an invisible, zero-width glyph - never .notdef', () {
        final double plain = shaper.shape('xy', font).width;
        for (final int codePoint in ignorables) {
          final String text = 'x${String.fromCharCode(codePoint)}y';
          final GlyphRun run = shaper.shape(text, font);
          final List<int> glyphs = <int>[
            for (int i = 0; i < run.length; i++) run.glyphIds[i],
          ];
          expect(glyphs, isNot(contains(notdefGlyph)),
              reason: 'U+${codePoint.toRadixString(16)}');
          expect(run.width, closeTo(plain, 1e-6),
              reason: 'U+${codePoint.toRadixString(16)} has no advance');
          // The control keeps a glyph - the space - so its cluster exists and
          // a caret can step over it.
          expect(glyphs, <int>[
            roboto.glyphForCodePoint(0x78),
            space,
            roboto.glyphForCodePoint(0x79),
          ]);
          expect(run.xOf(2), closeTo(run.xOf(1), 1e-6));
        }
      });

      test('a symbol with a selector the face lacks is just the symbol', () {
        // U+00A9, which Roboto has, standing in for the heart of ❤️: the
        // selector asks for an emoji presentation the face cannot give, so the
        // text presentation is drawn and nothing else.
        final GlyphRun bare = shaper.shape('\u00A9', font);
        final GlyphRun selected = shaper.shape('\u00A9\uFE0F', font);
        expect(bare.glyphIds[0], isNot(notdefGlyph));
        expect(selected.glyphIds[0], bare.glyphIds[0]);
        expect(selected.width, closeTo(bare.width, 1e-6));
        expect(selected.glyphIds[1], space);
      });
    });
  }

  test('a hidden ZWNJ still keeps a ligature from forming across it', () {
    final OpenTypeShaper shaper = OpenTypeShaper();
    // Roboto ligates "fi"; the joiner exists to prevent exactly that.
    expect(shaper.shape('fi', font).length, 1);
    final GlyphRun run = shaper.shape('f\u200Ci', font);
    expect(run.length, 3);
    expect(run.glyphIds[1], space);
    expect(run.glyphIds[0], roboto.glyphForCodePoint(0x66));
  });

  test('an unshaped measure agrees with the shapers', () {
    expect(
      font.measure('x\u{FE0F}\u{200D}y'),
      closeTo(font.measure('xy'), 1e-9),
    );
  });

  test('coverage does not count them', () {
    expect(roboto.covers('a\u{FE0F}b\u{200D}c'), isTrue);
    expect(roboto.covers('a\u{1F600}'), isFalse);
  });
}
