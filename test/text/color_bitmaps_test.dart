/// `sbix` and `CBDT`/`CBLC`: the colour pictures emoji faces keep their
/// artwork in.
///
/// Every rule is proved on tables built in memory and grafted onto Roboto
/// (see `color_font_fixtures.dart`), so it runs the same on every machine.
/// One group reads the real Apple Color Emoji and is skipped wherever that
/// file does not exist.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/graphics/image/png.dart';
import 'package:dart_ui/src/text/color_bitmaps.dart';
import 'package:dart_ui/src/text/typeface.dart';
import 'package:test/test.dart';

import 'color_font_fixtures.dart';

void main() {
  final Uint8List roboto = fixtureFontBytes('Roboto-Regular.ttf');
  final int glyphCount = Typeface.parse(roboto).glyphCount;

  group('sbix', () {
    final Uint8List red = solidPng(4, 4, 0xFFFF0000);
    final Uint8List blue = solidPng(8, 8, 0xFF0000FF);
    final Uint8List green = solidPng(16, 16, 0xFF00FF00);

    // Glyph 10 has a picture in every strike; 11 only in the 64 strike;
    // 12 is a dupe of 10; 13 is a mask, which is not an image.
    Typeface face() => Typeface.parse(withTables(roboto, <String, Uint8List>{
          'sbix': sbixTable(glyphCount: glyphCount, strikes: {
            16: <int, SbixRecord>{
              10: SbixRecord('png ', red, originX: 1, originY: -2),
              12: SbixRecord.dupe(10),
              13: SbixRecord('mask', Uint8List(4)),
            },
            32: <int, SbixRecord>{
              10: SbixRecord('png ', blue, originX: 2, originY: -4),
            },
            64: <int, SbixRecord>{
              10: SbixRecord('png ', green, originX: 4, originY: -8),
              11: SbixRecord('png ', green),
            },
          }),
        }));

    test('the header and strikes are read, lazily, from the typeface', () {
      final Typeface typeface = face();
      expect(typeface.hasColorBitmaps, isTrue);
      final ColorBitmapTable table = typeface.colorBitmaps!;
      expect(table.tag, 'sbix');
      expect(table.strikeSizes, <int>[16, 32, 64]);
      expect((table as SbixTable).strikePpi, <int>[72, 72, 72]);
      expect(table.drawsOutlines, isFalse);

      // A face with no colour table answers without reading anything.
      final Typeface plain = Typeface.parse(roboto);
      expect(plain.hasColorBitmaps, isFalse);
      expect(plain.colorBitmaps, isNull);
      expect(plain.colorBitmapOf(10, 16), isNull);
    });

    test('the smallest strike at least as large as the size is chosen', () {
      final Typeface typeface = face();
      ColorBitmapGlyph at(double size) => typeface.colorBitmapOf(10, size)!;

      expect(at(12).ppem, 16);
      expect(at(16).ppem, 16);
      expect(at(17).ppem, 32);
      expect(at(32).ppem, 32);
      expect(at(40).ppem, 64);
      // Nothing large enough: the largest there is.
      expect(at(200).ppem, 64);
    });

    test('a record carries its picture and its origin, as stored', () {
      final ColorBitmapGlyph glyph = face().colorBitmapOf(10, 30)!;
      expect(glyph.glyphId, 10);
      expect(glyph.strikeIndex, 1);
      expect(glyph.format, 'png ');
      expect(glyph.left, 2);
      expect(glyph.bottom, -4);
      expect(glyph.width, isNull, reason: 'sbix states no size');
      expect(glyph.data, blue);
      final decoded = decodePng(glyph.data);
      expect((decoded.width, decoded.height), (8, 8));
    });

    test('a glyph missing from the preferred strike is found in another', () {
      // Glyph 11 is only in the 64 strike, and 16 px prefers 16.
      final ColorBitmapGlyph glyph = face().colorBitmapOf(11, 16)!;
      expect(glyph.ppem, 64);
      expect(face().colorBitmapOf(20, 16), isNull, reason: 'in no strike');
    });

    test('dupe is followed; mask and out-of-range glyphs are no picture', () {
      final Typeface typeface = face();
      final ColorBitmapGlyph dupe = typeface.colorBitmapOf(12, 16)!;
      expect(dupe.glyphId, 10, reason: 'the record that holds the bytes');
      expect(dupe.data, red);
      expect(dupe.left, 1);
      expect(dupe.bottom, -2);

      expect(typeface.colorBitmapOf(13, 16), isNull);
      expect(typeface.colorBitmapOf(-1, 16), isNull);
      expect(typeface.colorBitmapOf(glyphCount + 5, 16), isNull);
    });

    test('a dupe that points at itself ends rather than looping', () {
      final Typeface typeface =
          Typeface.parse(withTables(roboto, <String, Uint8List>{
        'sbix': sbixTable(glyphCount: glyphCount, strikes: {
          16: <int, SbixRecord>{10: SbixRecord.dupe(10)},
        }),
      }));
      expect(typeface.colorBitmapOf(10, 16), isNull);
    });

    test('a malformed header degrades to no pictures, and says why', () {
      // Claims a million strikes in twelve bytes.
      final Uint8List broken = Uint8List(12);
      ByteData.sublistView(broken)
        ..setUint16(0, 1)
        ..setUint16(2, 1)
        ..setUint32(4, 1000000);
      final Typeface typeface =
          Typeface.parse(withTables(roboto, <String, Uint8List>{
        'sbix': broken,
      }));
      expect(typeface.hasColorBitmaps, isTrue);
      expect(typeface.colorBitmaps, isNull);
      expect(typeface.colorBitmapIssue, contains('strikes'));
      expect(typeface.colorBitmapOf(10, 16), isNull);
    });
  });

  group('CBDT/CBLC', () {
    final Uint8List red = solidPng(6, 5, 0xFFFF0000);
    final Uint8List blue = solidPng(3, 7, 0xFF0000FF);

    Typeface face({int indexFormat = 1, int imageFormat = 17}) {
      final ({Uint8List cblc, Uint8List cbdt}) tables = cbdtTables(
        ppem: 20,
        firstGlyph: 5,
        lastGlyph: 9,
        indexFormat: indexFormat,
        imageFormat: imageFormat,
        glyphs: <int, CbdtGlyph>{
          6: CbdtGlyph(red, width: 6, height: 5, bearingX: 1, bearingY: 4),
          8: CbdtGlyph(blue, width: 3, height: 7, bearingX: -1, bearingY: 9),
        },
      );
      return Typeface.parse(withTables(roboto, <String, Uint8List>{
        'CBLC': tables.cblc,
        'CBDT': tables.cbdt,
      }));
    }

    for (final (int index, int image) formats in <(int, int)>[
      (1, 17),
      (4, 18),
    ]) {
      test('index format ${formats.$1}, image format ${formats.$2}', () {
        final Typeface typeface =
            face(indexFormat: formats.$1, imageFormat: formats.$2);
        final ColorBitmapTable table = typeface.colorBitmaps!;
        expect(table.tag, 'CBDT');
        expect(table.strikeSizes, <int>[20]);

        final ColorBitmapGlyph six = typeface.colorBitmapOf(6, 16)!;
        expect(six.data, red);
        expect(six.ppem, 20);
        expect((six.width, six.height), (6, 5));
        expect(six.left, 1);
        // bearingY is the top edge above the baseline; the shared convention
        // is the bottom edge, so 4 - 5.
        expect(six.bottom, -1);

        final ColorBitmapGlyph eight = typeface.colorBitmapOf(8, 30)!;
        expect(eight.data, blue);
        expect(eight.left, -1);
        expect(eight.bottom, 2);

        // In the strike's range but with no record, and outside the range.
        expect(typeface.colorBitmapOf(7, 20), isNull);
        expect(typeface.colorBitmapOf(4, 20), isNull);
        expect(typeface.colorBitmapOf(10, 20), isNull);
      });
    }
  });

  group('Apple Color Emoji', () {
    final String? path = appleColorEmojiPath();
    final Typeface? face =
        path == null ? null : Typeface.parse(File(path).readAsBytesSync());
    final String? skip = face == null ? 'Apple Color Emoji not found' : null;

    test('its strikes are read, and \u{1F600} has a PNG at the text size', () {
      final Typeface emoji = face!;
      final ColorBitmapTable table = emoji.colorBitmaps!;
      expect(table.tag, 'sbix');
      expect(table.strikeSizes, contains(160));

      final int grin = emoji.glyphForCodePoint(0x1F600);
      final ColorBitmapGlyph picture = emoji.colorBitmapOf(grin, 24)!;
      expect(picture.format, 'png ');
      expect(picture.ppem, greaterThanOrEqualTo(24));
      // Every smaller strike is too small: this is the least scaling there is.
      expect(
        table.strikeSizes.where((int s) => s >= 24 && s < picture.ppem),
        isEmpty,
      );
      final decoded = decodePng(picture.data);
      expect(decoded.width, greaterThan(0));
      expect(decoded.height, greaterThan(0));
    }, skip: skip);

    test('the joiner and the selector have no picture', () {
      final Typeface emoji = face!;
      for (final int codePoint in <int>[0xFE0F, 0x200D]) {
        final int glyph = emoji.glyphForCodePoint(codePoint);
        expect(emoji.colorBitmapOf(glyph, 24), isNull);
      }
    }, skip: skip);
  });
}
