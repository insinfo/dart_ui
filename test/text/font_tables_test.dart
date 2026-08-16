/// `name`, `OS/2` and `post`, against real fonts and against bytes.
///
/// The real fixtures anchor the parsers to values a human can check against
/// `ttx` output: Roboto has an `OS/2` version 3 and a `post` 3.0 with no names
/// at all, DejaVu has an `OS/2` **version 1** - so its `sxHeight` genuinely
/// does not exist - and a 6253-name `post` 2.0, and Ahem has a `post` 2.0 whose
/// names are custom rather than standard. Between them they cover the branches
/// that differ between fonts.
///
/// What real fonts cannot cover is exercised with tables built byte by byte
/// here: MacRoman names with high bytes, a `name` table in format 1, an `OS/2`
/// that lies about its version, `post` 1.0 and 2.5, and the vertical-metrics
/// rule's two non-default branches. Those paths exist because broken and
/// archaic fonts exist, and a test suite made only of well-formed fonts would
/// never reach them.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/text/cmap.dart';
import 'package:dart_ui/src/text/font_data.dart';
import 'package:dart_ui/src/text/font_tables.dart';
import 'package:dart_ui/src/text/sfnt.dart';
import 'package:test/test.dart';

Uint8List _fontBytes(String name) => File('test/fonts/$name').readAsBytesSync();

SfntFile _file(String name) => SfntFile.parse(FontData(_fontBytes(name)));

SfntFile _roboto() => _file('Roboto-Regular.ttf');

SfntFile _dejaVu() => _file('DejaVuSans.ttf');

SfntFile _ahem() => _file('ahem.ttf');

// ---------------------------------------------------------------------------
// Byte builders. Enough sfnt to make a table parseable, and no more.
// ---------------------------------------------------------------------------

/// A big-endian byte accumulator, so the synthetic tables below read like the
/// specification's field lists rather than like index arithmetic.
final class _Bytes {
  final List<int> _out = <int>[];

  int get length => _out.length;

  void u8(int value) => _out.add(value & 0xFF);

  void i8(int value) => _out.add(value & 0xFF);

  void u16(int value) {
    _out
      ..add((value >> 8) & 0xFF)
      ..add(value & 0xFF);
  }

  void i16(int value) => u16(value & 0xFFFF);

  void u24(int value) {
    _out
      ..add((value >> 16) & 0xFF)
      ..add((value >> 8) & 0xFF)
      ..add(value & 0xFF);
  }

  void u32(int value) {
    _out
      ..add((value >> 24) & 0xFF)
      ..add((value >> 16) & 0xFF)
      ..add((value >> 8) & 0xFF)
      ..add(value & 0xFF);
  }

  void fixed(double value) => u32((value * 65536).round() & 0xFFFFFFFF);

  void ascii(String text) => _out.addAll(text.codeUnits);

  void bytes(List<int> data) => _out.addAll(data);

  /// A length-prefixed Pascal string, the form `post` 2.0 stores names in.
  void pascal(String text) {
    u8(text.length);
    ascii(text);
  }

  /// A UTF-16BE string, the form every Unicode-platform `name` record uses.
  void utf16be(String text) {
    for (final int unit in text.codeUnits) {
      u16(unit);
    }
  }

  List<int> take() => _out;
}

/// Wraps [tables] in a minimal but valid TrueType directory.
Uint8List _buildSfnt(Map<String, List<int>> tables) {
  final List<String> tags = tables.keys.toList()..sort();
  int offset = 12 + 16 * tags.length;
  final Map<String, int> offsets = <String, int>{};
  for (final String tag in tags) {
    offsets[tag] = offset;
    offset += tables[tag]!.length;
    offset = (offset + 3) & ~3; // tables are 4-byte aligned
  }

  final Uint8List out = Uint8List(offset);
  final ByteData view = ByteData.sublistView(out);
  view.setUint32(0, 0x00010000);
  view.setUint16(4, tags.length);
  // searchRange, entrySelector and rangeShift are derivable and the parser
  // skips them, so they stay zero.

  int cursor = 12;
  for (final String tag in tags) {
    for (int i = 0; i < 4; i++) {
      out[cursor + i] = tag.codeUnitAt(i);
    }
    view.setUint32(cursor + 8, offsets[tag]!);
    view.setUint32(cursor + 12, tables[tag]!.length);
    cursor += 16;
    out.setRange(
      offsets[tag]!,
      offsets[tag]! + tables[tag]!.length,
      tables[tag]!,
    );
  }
  return out;
}

SfntFile _synthetic(Map<String, List<int>> tables) =>
    SfntFile.parse(FontData(_buildSfnt(tables)));

/// One synthetic `name` record.
typedef _Name = ({
  int platform,
  int encoding,
  int language,
  int nameId,
  List<int> bytes,
});

_Name _windowsName(int nameId, String text, {int language = 0x0409}) {
  final _Bytes bytes = _Bytes()..utf16be(text);
  return (
    platform: 3,
    encoding: 1,
    language: language,
    nameId: nameId,
    bytes: bytes.take(),
  );
}

List<int> _nameTableBytes(
  List<_Name> names, {
  int format = 0,
  List<String> languageTags = const <String>[],
}) {
  final _Bytes header = _Bytes()
    ..u16(format)
    ..u16(names.length);

  int storageOffset = 6 + names.length * 12;
  if (format == 1) storageOffset += 2 + languageTags.length * 4;
  header.u16(storageOffset);

  // Storage is laid out first so the records can point at it.
  final _Bytes storage = _Bytes();
  final List<int> tagOffsets = <int>[];
  final List<int> tagLengths = <int>[];
  for (final String tag in languageTags) {
    tagOffsets.add(storage.length);
    final _Bytes encoded = _Bytes()..utf16be(tag);
    tagLengths.add(encoded.length);
    storage.bytes(encoded.take());
  }
  final List<int> offsets = <int>[];
  for (final _Name name in names) {
    offsets.add(storage.length);
    storage.bytes(name.bytes);
  }

  for (int i = 0; i < names.length; i++) {
    final _Name name = names[i];
    header
      ..u16(name.platform)
      ..u16(name.encoding)
      ..u16(name.language)
      ..u16(name.nameId)
      ..u16(name.bytes.length)
      ..u16(offsets[i]);
  }

  if (format == 1) {
    header.u16(languageTags.length);
    for (int i = 0; i < languageTags.length; i++) {
      header
        ..u16(tagLengths[i])
        ..u16(tagOffsets[i]);
    }
  }

  return (header..bytes(storage.take())).take();
}

/// An `OS/2` table of the requested physical [version].
///
/// [declaredVersion] overrides only the version *field*, which is how a font
/// that claims more than it carries is reproduced.
List<int> _os2Bytes({
  required int version,
  int? declaredVersion,
  int weightClass = 400,
  int widthClass = 5,
  int fsType = 0,
  int fsSelection = 0,
  int typoAscender = 800,
  int typoDescender = -200,
  int typoLineGap = 100,
  int winAscent = 900,
  int winDescent = 250,
  int sxHeight = 500,
  int capHeight = 700,
  int defaultChar = 0,
  int breakChar = 32,
  int maxContext = 1,
  String vendorId = 'TEST',
  List<int> unicodeRanges = const <int>[0, 0, 0, 0],
  int? truncateTo,
}) {
  final _Bytes b = _Bytes()
    ..u16(declaredVersion ?? version)
    ..i16(1000) // xAvgCharWidth
    ..u16(weightClass)
    ..u16(widthClass)
    ..u16(fsType);
  for (int i = 0; i < 10; i++) {
    b.i16(100 + i); // the sub/superscript and strikeout block
  }
  b
    ..i16(0) // sFamilyClass
    ..bytes(List<int>.filled(10, 2)) // panose
    ..u32(unicodeRanges[0])
    ..u32(unicodeRanges[1])
    ..u32(unicodeRanges[2])
    ..u32(unicodeRanges[3])
    ..ascii(vendorId)
    ..u16(fsSelection)
    ..u16(0x20) // usFirstCharIndex
    ..u16(0xFFFF) // usLastCharIndex
    ..i16(typoAscender)
    ..i16(typoDescender)
    ..i16(typoLineGap)
    ..u16(winAscent)
    ..u16(winDescent);
  if (version >= 1) {
    b
      ..u32(0x00000001)
      ..u32(0);
  }
  if (version >= 2) {
    b
      ..i16(sxHeight)
      ..i16(capHeight)
      ..u16(defaultChar)
      ..u16(breakChar)
      ..u16(maxContext);
  }
  if (version >= 5) {
    b
      ..u16(0)
      ..u16(0xFFFF);
  }
  final List<int> out = b.take();
  return truncateTo == null ? out : out.sublist(0, truncateTo);
}

List<int> _hheaBytes({
  int ascender = 800,
  int descender = -200,
  int lineGap = 0,
  int numberOfHMetrics = 1,
}) {
  final _Bytes b = _Bytes()
    ..u32(0x00010000)
    ..i16(ascender)
    ..i16(descender)
    ..i16(lineGap)
    ..bytes(List<int>.filled(24, 0))
    ..u16(numberOfHMetrics);
  return b.take();
}

List<int> _postHeader(
  double version, {
  double italicAngle = 0,
  int underlinePosition = -100,
  int underlineThickness = 50,
  bool isFixedPitch = false,
}) {
  final _Bytes b = _Bytes()
    ..fixed(version)
    ..fixed(italicAngle)
    ..i16(underlinePosition)
    ..i16(underlineThickness)
    ..u32(isFixedPitch ? 1 : 0)
    ..u32(0)
    ..u32(0)
    ..u32(0)
    ..u32(0);
  return b.take();
}

void main() {
  group('name, on real fonts', () {
    test('Roboto is family "Roboto", subfamily "Regular"', () {
      final NameTable name = NameTable.parse(_roboto())!;

      expect(name.format, 0);
      expect(name.records.length, 26);
      expect(name.family, 'Roboto');
      expect(name.subfamily, 'Regular');
      expect(name.legacyFamily, 'Roboto');
      expect(name.legacySubfamily, 'Regular');
      expect(name.fullName, 'Roboto');
      expect(name.postScriptName, 'Roboto-Regular');
      expect(name.uniqueId, 'Roboto');
      expect(
        name.forNameId(NameId.copyright),
        startsWith('Copyright 2011 Google Inc.'),
      );
      expect(name.forNameId(NameId.designer), 'Google');
      expect(name.forNameId(NameId.version), 'Version 2.137; 2017');
      expect(
        name.forNameId(NameId.licenseUrl),
        'http://www.apache.org/licenses/LICENSE-2.0',
      );
      // Name 8 is simply absent from this font, and absent is null.
      expect(name.forNameId(NameId.manufacturer), isNull);
    });

    test('Roboto carries no name 16/17, so the rule falls back to 1/2', () {
      final NameTable name = NameTable.parse(_roboto())!;

      // The fallback half of the rule, on a font that needs it: the getters
      // answer while the un-fallen-back accessors report the absence.
      expect(name.typographicFamily, isNull);
      expect(name.typographicSubfamily, isNull);
      expect(name.family, 'Roboto');
      expect(name.subfamily, 'Regular');
    });

    test('DejaVu carries 16/17, and its subfamily is "Book" not "Regular"', () {
      final NameTable name = NameTable.parse(_dejaVu())!;

      expect(name.family, 'DejaVu Sans');
      expect(name.subfamily, 'Book');
      expect(name.typographicFamily, 'DejaVu Sans');
      expect(name.typographicSubfamily, 'Book');
      expect(name.postScriptName, 'DejaVuSans');
      expect(name.uniqueId, 'DejaVu Sans');
    });

    test('every record in the three fixtures decodes', () {
      for (final SfntFile file in <SfntFile>[_roboto(), _dejaVu(), _ahem()]) {
        final NameTable name = NameTable.parse(file)!;
        expect(
          name.records.where((NameRecord r) => r.text == null),
          isEmpty,
          reason: 'the fixtures only use Windows/Unicode/MacRoman records',
        );
      }
    });

    test('the Windows en-US record wins over the Macintosh one', () {
      final NameTable name = NameTable.parse(_roboto())!;

      // Both platforms carry name 1 with the same text, so the win is only
      // visible through the record list: both are present, and the chosen
      // spelling is the Windows one.
      final Iterable<NameRecord> family =
          name.records.where((NameRecord r) => r.nameId == NameId.family);
      expect(
          family.map((NameRecord r) => r.platformId), containsAll(<int>[1, 3]));
      expect(name.forNameIdInLanguage(NameId.family, 1, 0), 'Roboto');
      expect(name.forNameIdInLanguage(NameId.family, 3, 0x0409), 'Roboto');
      expect(name.forNameIdInLanguage(NameId.family, 3, 0x0416), isNull);
    });

    test('Ahem has Unicode-platform records too', () {
      final NameTable name = NameTable.parse(_ahem())!;

      expect(name.family, 'Ahem');
      expect(name.subfamily, 'Regular');
      expect(name.uniqueId, 'Version 1.50 Ahem');
      expect(
        name.records.map((NameRecord r) => r.platformId).toSet(),
        <int>{0, 1, 3},
      );
      expect(name.languageTags, isEmpty);
    });

    test('a font without a name table yields null, not an exception', () {
      final SfntFile file = _synthetic(<String, List<int>>{
        'hhea': _hheaBytes(),
      });
      expect(NameTable.parse(file), isNull);
    });
  });

  group('name, on bytes', () {
    test('MacRoman high bytes decode as MacRoman, never as Latin-1', () {
      // 0xA5 is BULLET in MacRoman and YEN SIGN in Latin-1; 0xD5 is RIGHT
      // SINGLE QUOTATION MARK and not O-WITH-TILDE; 0xAA is TRADE MARK SIGN
      // and not FEMININE ORDINAL. Every one of these appears in real font
      // names, which is why the difference is a test and not a comment.
      final List<int> macBytes = <int>[
        0x41, // 'A'
        0xA5, // bullet
        0xD5, // right single quote
        0xAA, // trademark
        0x8E, // e acute
        0xC9, // ellipsis
        0xDB, // euro sign, in the post-1998 revision
        0xF0, // Apple logo, U+F8FF
      ];
      final SfntFile file = _synthetic(<String, List<int>>{
        'name': _nameTableBytes(<_Name>[
          (
            platform: 1,
            encoding: 0,
            language: 0,
            nameId: NameId.family,
            bytes: macBytes,
          ),
        ]),
      });

      final NameTable name = NameTable.parse(file)!;
      // Written with escapes rather than literal characters so that the
      // expectation cannot be silently changed by a source-encoding accident:
      // bullet, right single quote, trade mark, e-acute, ellipsis, euro, and
      // the Apple logo in the private use area.
      expect(
        name.family,
        'A•’™é…€',
      );
      // The Latin-1 misreading, spelled out, so a regression is unmistakable.
      expect(
        name.family,
        isNot('A¥ÕªÉÛð'),
      );
    });

    test('a Mac script other than Roman is left undecoded, not guessed at', () {
      final SfntFile file = _synthetic(<String, List<int>>{
        'name': _nameTableBytes(<_Name>[
          (
            platform: 1,
            encoding: 1, // Japanese
            language: 11,
            nameId: NameId.family,
            bytes: <int>[0x82, 0xA0, 0x82, 0xA2],
          ),
          _windowsName(NameId.family, 'Fallback'),
        ]),
      });

      final NameTable name = NameTable.parse(file)!;
      final NameRecord japanese = name.records.first;
      expect(japanese.platformId, 1);
      expect(japanese.encodingId, 1);
      expect(japanese.text, isNull, reason: 'Shift-JIS is not decoded here');
      // The record is listed, so the caller can see what was skipped, and the
      // lookup still finds the record it can read.
      expect(name.family, 'Fallback');
    });

    test('16/17 beat 1/2 when both are present', () {
      final SfntFile file = _synthetic(<String, List<int>>{
        'name': _nameTableBytes(<_Name>[
          _windowsName(NameId.family, 'Acme Sans Semibold'),
          _windowsName(NameId.subfamily, 'Italic'),
          _windowsName(NameId.typographicFamily, 'Acme Sans'),
          _windowsName(NameId.typographicSubfamily, 'Semibold Italic'),
        ]),
      });

      final NameTable name = NameTable.parse(file)!;
      // This is the case the whole rule exists for: without 16/17 the face
      // lands in a family of its own and the user sees four "Acme Sans"
      // families in a menu instead of one with four styles.
      expect(name.family, 'Acme Sans');
      expect(name.subfamily, 'Semibold Italic');
      expect(name.legacyFamily, 'Acme Sans Semibold');
      expect(name.legacySubfamily, 'Italic');
    });

    test('en-US wins over another English, which wins over another language',
        () {
      final SfntFile file = _synthetic(<String, List<int>>{
        'name': _nameTableBytes(<_Name>[
          _windowsName(NameId.family, 'Familie', language: 0x0407), // de-DE
          _windowsName(NameId.family, 'Family GB', language: 0x0809), // en-GB
          _windowsName(NameId.family, 'Family US'),
        ]),
      });

      final NameTable name = NameTable.parse(file)!;
      expect(name.family, 'Family US');
      expect(name.forNameIdInLanguage(NameId.family, 3, 0x0407), 'Familie');
      expect(name.forNameIdInLanguage(NameId.family, 3, 0x0809), 'Family GB');
    });

    test('format 1 resolves language-tag records', () {
      final SfntFile file = _synthetic(<String, List<int>>{
        'name': _nameTableBytes(
          <_Name>[
            _windowsName(NameId.family, 'Base'),
            _windowsName(NameId.family, 'Tagged', language: 0x8001),
          ],
          format: 1,
          languageTags: <String>['gsw-FR', 'rm-CH'],
        ),
      });

      final NameTable name = NameTable.parse(file)!;
      expect(name.format, 1);
      expect(name.languageTags, <String>['rm-CH']);

      final NameRecord tagged = name.records[1];
      expect(tagged.usesLanguageTag, isTrue);
      expect(tagged.languageId, 0x8001);
      expect(tagged.languageTag, 'rm-CH', reason: '0x8001 is tag index 1');
      expect(tagged.text, 'Tagged');
      // The tagged record scores below en-US, so the plain lookup is unmoved.
      expect(name.family, 'Base');
    });

    test('a format other than 0 or 1 is refused by name', () {
      final List<int> bytes = _nameTableBytes(<_Name>[
        _windowsName(NameId.family, 'X'),
      ]);
      bytes[1] = 2; // rewrite the format field
      final SfntFile file = _synthetic(<String, List<int>>{'name': bytes});

      expect(
        () => NameTable.parse(file),
        throwsA(isA<FontFormatException>().having(
          (FontFormatException e) => e.message,
          'message',
          contains('neither 0 nor 1'),
        )),
      );
    });

    test('records that do not fit the table are refused', () {
      final List<int> bytes = _nameTableBytes(<_Name>[
        _windowsName(NameId.family, 'X'),
      ]);
      bytes[3] = 40; // claim 40 records in a table sized for one
      final SfntFile file = _synthetic(<String, List<int>>{'name': bytes});

      expect(
        () => NameTable.parse(file),
        throwsA(isA<FontFormatException>().having(
          (FontFormatException e) => e.table,
          'table',
          'name',
        )),
      );
    });

    test('a string pointing outside the table loses that string only', () {
      final List<int> bytes = _nameTableBytes(<_Name>[
        _windowsName(NameId.family, 'Kept'),
        _windowsName(NameId.subfamily, 'Lost'),
      ]);
      // The second record's storage offset is the last uint16 of its record.
      const int secondRecordOffsetField = 6 + 12 + 12 - 2;
      bytes[secondRecordOffsetField] = 0xFF;
      bytes[secondRecordOffsetField + 1] = 0xF0;
      final SfntFile file = _synthetic(<String, List<int>>{'name': bytes});

      final NameTable name = NameTable.parse(file)!;
      expect(name.records.length, 1);
      expect(name.family, 'Kept');
      expect(name.subfamily, isNull);
    });

    test('a name outside the BMP survives as surrogate pairs', () {
      final SfntFile file = _synthetic(<String, List<int>>{
        'name': _nameTableBytes(<_Name>[
          _windowsName(NameId.family, 'Emoji \u{1F600} Sans'),
        ]),
      });

      expect(NameTable.parse(file)!.family, 'Emoji \u{1F600} Sans');
    });
  });

  group('OS/2, on real fonts', () {
    test('Roboto is a version 3 regular of weight 400', () {
      final Os2Table os2 = Os2Table.parse(_roboto())!;

      expect(os2.version, 3);
      expect(os2.weightClass, 400);
      expect(os2.widthClass, 5);
      expect(os2.vendorId, 'GOOG');
      expect(os2.fsType, 0);
      expect(os2.isInstallableEmbedding, isTrue);
      expect(os2.fsSelection, 0x40);
      expect(os2.isRegular, isTrue);
      expect(os2.isBold, isFalse);
      expect(os2.isItalic, isFalse);
      expect(os2.isOblique, isFalse);
      expect(os2.useTypographicMetrics, isFalse);
      expect(os2.xAvgCharWidth, 1158);
      expect(os2.firstCharIndex, 0x0000);
      expect(os2.lastCharIndex, 0xFFFD);
    });

    test('Roboto reports all three vertical metric triples, and they differ',
        () {
      final Os2Table os2 = Os2Table.parse(_roboto())!;
      final HheaTable hhea = HheaTable.parse(_roboto());

      expect(<int>[os2.typoAscender, os2.typoDescender, os2.typoLineGap],
          <int>[1536, -512, 102]);
      expect(<int>[os2.winAscent, os2.winDescent], <int>[1946, 512]);
      expect(<int>[hhea.ascender, hhea.descender, hhea.lineGap],
          <int>[1900, -500, 0]);
      // 1900 vs 1536 vs 1946: three answers for the height of one line, which
      // is precisely why VerticalMetrics exists.
      expect(os2.typoAscender, isNot(hhea.ascender));
      expect(os2.winAscent, isNot(hhea.ascender));
    });

    test('Roboto version 3 has the version 2 fields', () {
      final Os2Table os2 = Os2Table.parse(_roboto())!;

      expect(os2.hasVersion2Fields, isTrue);
      expect(os2.sxHeight, 1082);
      expect(os2.capHeight, 1456);
      expect(os2.sxHeightOrNull, 1082);
      expect(os2.capHeightOrNull, 1456);
      expect(os2.defaultChar, 32);
      expect(os2.breakChar, 32);
      expect(os2.maxContext, 3);
      expect(os2.codePageRange1, 0x2000019F);
      expect(os2.codePageRange2, 0);
      expect(os2.lowerOpticalPointSize, isNull);
    });

    test('DejaVu is version 1, so sxHeight does not exist and says so', () {
      final Os2Table os2 = Os2Table.parse(_dejaVu())!;

      expect(os2.version, 1);
      expect(os2.hasVersion2Fields, isFalse);
      expect(os2.sxHeightOrNull, isNull);
      expect(os2.capHeightOrNull, isNull);
      expect(os2.maxContextOrNull, isNull);
      // The throwing accessor is the point: the bytes where sxHeight would sit
      // in a version 2 table belong to whatever table follows this one, and
      // returning them would be a plausible-looking wrong number.
      expect(
        () => os2.sxHeight,
        throwsA(isA<FontFormatException>().having(
          (FontFormatException e) => e.message,
          'message',
          allOf(contains('sxHeight'), contains('version 1')),
        )),
      );
      expect(() => os2.capHeight, throwsA(isA<FontFormatException>()));
      expect(() => os2.defaultChar, throwsA(isA<FontFormatException>()));
      expect(() => os2.breakChar, throwsA(isA<FontFormatException>()));
      expect(() => os2.maxContext, throwsA(isA<FontFormatException>()));
      // Version 1 still has the code page ranges.
      expect(os2.codePageRange1, 0x600001FF);
      expect(os2.codePageRange2, 0xDFFF0000);
    });

    test('DejaVu declares the wide script coverage it actually has', () {
      final Os2Table os2 = Os2Table.parse(_dejaVu())!;
      final CmapTable cmap = CmapTable.parse(_dejaVu());

      expect(os2.ulUnicodeRange1, 0xE7006EFF);
      expect(os2.ulUnicodeRange2, 0xD200FDFF);
      expect(os2.ulUnicodeRange3, 0x0A246029);
      expect(os2.ulUnicodeRange4, 0x0400200C);

      expect(os2.hasUnicodeRangeBit(0), isTrue, reason: 'Basic Latin');
      expect(os2.hasUnicodeRangeBit(7), isTrue, reason: 'Greek');
      expect(os2.hasUnicodeRangeBit(9), isTrue, reason: 'Cyrillic');
      expect(os2.hasUnicodeRangeBit(11), isTrue, reason: 'Hebrew');
      expect(os2.hasUnicodeRangeBit(13), isTrue, reason: 'Arabic');
      expect(os2.hasUnicodeRangeBit(24), isTrue, reason: 'Thai');
      expect(os2.hasUnicodeRangeBit(59), isFalse, reason: 'no CJK ideographs');
      expect(os2.hasUnicodeRangeBit(56), isFalse, reason: 'no Hangul');
      expect(os2.declaredRanges.length, 51);

      // The bit is a filter; the cmap is the truth. Here they agree, which is
      // what makes the filter useful.
      expect(os2.declaresCodePoint(0x0627), isTrue); // arabic alef
      expect(cmap.glyphFor(0x0627), isNot(notdefGlyph));
      expect(os2.declaresCodePoint(0x4E00), isFalse); // CJK
      expect(cmap.glyphFor(0x4E00), notdefGlyph);
    });

    test('Roboto declares no Arabic, and has none', () {
      final Os2Table os2 = Os2Table.parse(_roboto())!;
      final CmapTable cmap = CmapTable.parse(_roboto());

      expect(os2.hasUnicodeRangeBit(13), isFalse);
      expect(os2.declaresCodePoint(0x0627), isFalse);
      expect(cmap.glyphFor(0x0627), notdefGlyph);
      // And the positive control, so the test is not passing by accident.
      expect(os2.declaresCodePoint(0x0041), isTrue);
      expect(cmap.glyphFor(0x0041), 37);
      expect(os2.declaredRanges.length, 21);
    });

    test('Ahem is a version 3 with an x-height equal to its cap height', () {
      final Os2Table os2 = Os2Table.parse(_ahem())!;

      expect(os2.version, 3);
      expect(os2.vendorId, 'W3C');
      expect(os2.weightClass, 400);
      expect(os2.sxHeight, 800);
      expect(os2.capHeight, 800);
      expect(<int>[os2.typoAscender, os2.typoDescender, os2.typoLineGap],
          <int>[800, -200, 0]);
      expect(<int>[os2.winAscent, os2.winDescent], <int>[800, 200]);
      expect(os2.panose.length, 10);
      expect(os2.panose[0], 2);
    });

    test('a font without OS/2 yields null', () {
      expect(
        Os2Table.parse(_synthetic(<String, List<int>>{'hhea': _hheaBytes()})),
        isNull,
      );
    });
  });

  group('OS/2, on bytes', () {
    test('a version 0 table stops at usWinDescent', () {
      final SfntFile file = _synthetic(<String, List<int>>{
        'OS/2': _os2Bytes(version: 0),
      });
      final Os2Table os2 = Os2Table.parse(file)!;

      expect(os2.version, 0);
      expect(os2.winAscent, 900);
      expect(os2.winDescent, 250);
      expect(os2.codePageRange1, isNull);
      expect(os2.codePageRange2, isNull);
      expect(os2.sxHeightOrNull, isNull);
      expect(
        () => os2.sxHeight,
        throwsA(isA<FontFormatException>().having(
          (FontFormatException e) => e.message,
          'message',
          contains('version 0'),
        )),
      );
    });

    test('a table that claims version 2 while being 78 bytes is refused', () {
      // The exact shape of the failure this whole version dance exists to
      // prevent: the reader would otherwise walk 18 bytes past the table and
      // report whatever is there as an x-height.
      final SfntFile file = _synthetic(<String, List<int>>{
        'OS/2': _os2Bytes(version: 0, declaredVersion: 2),
      });

      expect(
        () => Os2Table.parse(file),
        throwsA(isA<FontFormatException>().having(
          (FontFormatException e) => e.message,
          'message',
          allOf(contains('version 2'), contains('96'), contains('78')),
        )),
      );
    });

    test('the 68-byte Apple variant is refused by name', () {
      final SfntFile file = _synthetic(<String, List<int>>{
        'OS/2': _os2Bytes(version: 0, truncateTo: 68),
      });

      expect(
        () => Os2Table.parse(file),
        throwsA(isA<FontFormatException>().having(
          (FontFormatException e) => e.message,
          'message',
          contains('Apple variant'),
        )),
      );
    });

    test('versions 1 through 5 each expose exactly their own fields', () {
      expect(Os2Table.requiredLengthFor(0), 78);
      expect(Os2Table.requiredLengthFor(1), 86);
      expect(Os2Table.requiredLengthFor(2), 96);
      expect(Os2Table.requiredLengthFor(4), 96);
      expect(Os2Table.requiredLengthFor(5), 100);

      for (final int version in <int>[1, 2, 3, 4, 5]) {
        final Os2Table os2 = Os2Table.parse(
          _synthetic(<String, List<int>>{
            'OS/2': _os2Bytes(version: version),
          }),
        )!;
        expect(os2.version, version);
        expect(os2.codePageRange1, 1);
        expect(os2.sxHeightOrNull, version >= 2 ? 500 : isNull);
        expect(os2.capHeightOrNull, version >= 2 ? 700 : isNull);
        expect(os2.upperOpticalPointSize, version >= 5 ? 0xFFFF : isNull);
      }
    });

    test('a version beyond 5 is read as 5 rather than refused', () {
      final Os2Table os2 = Os2Table.parse(
        _synthetic(<String, List<int>>{
          'OS/2': _os2Bytes(version: 5, declaredVersion: 9),
        }),
      )!;
      expect(os2.version, 5);
      expect(os2.sxHeight, 500);
    });

    test('an impossible usWeightClass or usWidthClass is refused', () {
      expect(
        () => Os2Table.parse(_synthetic(<String, List<int>>{
          'OS/2': _os2Bytes(version: 4, weightClass: 0),
        })),
        throwsA(isA<FontFormatException>().having(
          (FontFormatException e) => e.message,
          'message',
          contains('usWeightClass 0'),
        )),
      );
      expect(
        () => Os2Table.parse(_synthetic(<String, List<int>>{
          'OS/2': _os2Bytes(version: 4, weightClass: 1001),
        })),
        throwsA(isA<FontFormatException>()),
      );
      expect(
        () => Os2Table.parse(_synthetic(<String, List<int>>{
          'OS/2': _os2Bytes(version: 4, widthClass: 12),
        })),
        throwsA(isA<FontFormatException>().having(
          (FontFormatException e) => e.message,
          'message',
          contains('usWidthClass 12'),
        )),
      );
    });

    test('every fsSelection bit reads back', () {
      final Os2Table os2 = Os2Table.parse(
        _synthetic(<String, List<int>>{
          'OS/2': _os2Bytes(
            version: 4,
            fsSelection: Os2Table.fsSelectionItalic |
                Os2Table.fsSelectionBold |
                Os2Table.fsSelectionUseTypoMetrics |
                Os2Table.fsSelectionWws |
                Os2Table.fsSelectionOblique,
          ),
        }),
      )!;

      expect(os2.isItalic, isTrue);
      expect(os2.isBold, isTrue);
      expect(os2.isOblique, isTrue);
      expect(os2.isWws, isTrue);
      expect(os2.useTypographicMetrics, isTrue);
      expect(os2.isRegular, isFalse);
    });

    test('fsType embedding bits are decoded individually', () {
      Os2Table withFsType(int value) => Os2Table.parse(
            _synthetic(<String, List<int>>{
              'OS/2': _os2Bytes(version: 4, fsType: value),
            }),
          )!;

      expect(withFsType(0).isInstallableEmbedding, isTrue);
      expect(withFsType(0x0002).isRestrictedLicense, isTrue);
      expect(withFsType(0x0002).isInstallableEmbedding, isFalse);
      expect(withFsType(0x0004).allowsPreviewAndPrintEmbedding, isTrue);
      expect(withFsType(0x0008).allowsEditableEmbedding, isTrue);
      expect(withFsType(0x0100).noSubsetting, isTrue);
      expect(withFsType(0x0200).bitmapEmbeddingOnly, isTrue);
      // The subsetting bit alone leaves the low nibble clear, so the face is
      // still installable - the two fields are independent.
      expect(withFsType(0x0100).isInstallableEmbedding, isTrue);
    });

    test('a vendor id padded with spaces or NULs trims to the same string', () {
      Os2Table withVendor(String tag) => Os2Table.parse(
            _synthetic(<String, List<int>>{
              'OS/2': _os2Bytes(version: 4, vendorId: tag),
            }),
          )!;

      expect(withVendor('MS  ').vendorId, 'MS');
      expect(withVendor('MS  ').vendorId, 'MS');
      expect(withVendor('ADBE').vendorId, 'ADBE');
    });

    test('a Unicode range bit outside 0..127 is refused', () {
      final Os2Table os2 = Os2Table.parse(
        _synthetic(<String, List<int>>{'OS/2': _os2Bytes(version: 4)}),
      )!;
      expect(() => os2.hasUnicodeRangeBit(-1),
          throwsA(isA<FontFormatException>()));
      expect(() => os2.hasUnicodeRangeBit(128),
          throwsA(isA<FontFormatException>()));
    });

    test('each of the four range words addresses its own 32 bits', () {
      final Os2Table os2 = Os2Table.parse(
        _synthetic(<String, List<int>>{
          'OS/2': _os2Bytes(
            version: 4,
            // bit 0, bit 32, bit 64+31 = 95, bit 96+26 = 122.
            unicodeRanges: <int>[0x1, 0x1, 0x80000000, 0x04000000],
          ),
        }),
      )!;

      expect(os2.hasUnicodeRangeBit(0), isTrue);
      expect(os2.hasUnicodeRangeBit(1), isFalse);
      expect(os2.hasUnicodeRangeBit(32), isTrue);
      expect(os2.hasUnicodeRangeBit(31), isFalse);
      expect(os2.hasUnicodeRangeBit(95), isTrue);
      expect(os2.hasUnicodeRangeBit(122), isTrue);
      expect(
        os2.declaredRanges.map((UnicodeRange r) => r.bit),
        <int>[0, 32, 95, 122],
      );
    });
  });

  group('the Unicode range catalogue', () {
    test('covers bits 0 through 122, each exactly once and in order', () {
      expect(Os2Table.unicodeRanges.length, 123);
      for (int i = 0; i < Os2Table.unicodeRanges.length; i++) {
        expect(Os2Table.unicodeRanges[i].bit, i);
        expect(Os2Table.unicodeRanges[i].spans, isNotEmpty);
      }
    });

    test('maps the code points a fallback chain actually asks about', () {
      expect(Os2Table.rangeForCodePoint(0x0041)!.bit, 0); // Basic Latin
      expect(Os2Table.rangeForCodePoint(0x00E9)!.bit, 1); // Latin-1 Supplement
      expect(Os2Table.rangeForCodePoint(0x03B1)!.bit, 7); // Greek
      expect(Os2Table.rangeForCodePoint(0x0430)!.bit, 9); // Cyrillic
      expect(Os2Table.rangeForCodePoint(0x05D0)!.bit, 11); // Hebrew
      expect(Os2Table.rangeForCodePoint(0x0627)!.bit, 13); // Arabic
      expect(Os2Table.rangeForCodePoint(0x0915)!.bit, 15); // Devanagari
      expect(Os2Table.rangeForCodePoint(0x0E01)!.bit, 24); // Thai
      expect(Os2Table.rangeForCodePoint(0x3042)!.bit, 49); // Hiragana
      expect(Os2Table.rangeForCodePoint(0x30A2)!.bit, 50); // Katakana
      expect(Os2Table.rangeForCodePoint(0xAC00)!.bit, 56); // Hangul Syllables
      expect(Os2Table.rangeForCodePoint(0x4E00)!.bit, 59); // CJK
      expect(Os2Table.rangeForCodePoint(0x20000)!.bit, 59); // CJK ext B
      expect(Os2Table.rangeForCodePoint(0xE000)!.bit, 60); // Private Use
      expect(Os2Table.rangeForCodePoint(0xFE0F)!.bit, 91); // Variation sels
      expect(Os2Table.rangeForCodePoint(0x1F031)!.bit, 122); // Domino tiles
    });

    test('a code point in no defined range is null, not bit 0', () {
      // Emoji live at U+1F300..U+1F9FF, which no OS/2 bit was ever assigned -
      // the field stopped tracking Unicode long before emoji arrived. Saying
      // null here is what keeps declaresCodePoint honest.
      expect(Os2Table.rangeForCodePoint(0x1F600), isNull);
      expect(Os2Table.rangeForCodePoint(0x0870), isNull);
    });

    test('the multi-block bits list every one of their blocks', () {
      final UnicodeRange cyrillic = Os2Table.unicodeRanges[9];
      expect(cyrillic.spans.length, 4);
      expect(cyrillic.contains(0x0400), isTrue);
      expect(cyrillic.contains(0xA640), isTrue);
      expect(cyrillic.contains(0x0530), isFalse);

      final UnicodeRange cjk = Os2Table.unicodeRanges[59];
      expect(cjk.spans.length, 7);
      expect(cjk.contains(0x3400), isTrue);
      expect(cjk.contains(0x2A6DF), isTrue);
    });
  });

  group('the vertical metrics rule', () {
    test('hhea wins by default, on all three fixtures', () {
      for (final ({SfntFile file, int ascent, int descent}) fixture
          in <({SfntFile file, int ascent, int descent})>[
        (file: _roboto(), ascent: 1900, descent: -500),
        (file: _dejaVu(), ascent: 1901, descent: -483),
        (file: _ahem(), ascent: 800, descent: -200),
      ]) {
        final VerticalMetrics metrics = VerticalMetrics.resolve(
          hhea: HheaTable.parse(fixture.file),
          os2: Os2Table.parse(fixture.file),
        );
        expect(metrics.source, VerticalMetricsSource.horizontalHeader);
        expect(metrics.ascent, fixture.ascent);
        expect(metrics.descent, fixture.descent);
      }
    });

    test('Roboto lays out 2400 units per line under the default rule', () {
      final VerticalMetrics metrics = VerticalMetrics.resolve(
        hhea: HheaTable.parse(_roboto()),
        os2: Os2Table.parse(_roboto()),
      );
      // 1900 + 500 + 0. Had the typo metrics won it would be 2150, and had the
      // win metrics won, 2458 - a 13% swing in the height of every paragraph.
      expect(metrics.lineHeight, 2400);
    });

    test('USE_TYPO_METRICS moves the whole line box', () {
      final Os2Table os2 = Os2Table.parse(
        _synthetic(<String, List<int>>{
          'OS/2': _os2Bytes(
            version: 4,
            fsSelection: Os2Table.fsSelectionUseTypoMetrics,
            typoAscender: 750,
            typoDescender: -250,
            typoLineGap: 200,
          ),
        }),
      )!;
      final HheaTable hhea = HheaTable.parse(
        _synthetic(<String, List<int>>{'hhea': _hheaBytes()}),
      );

      final VerticalMetrics metrics =
          VerticalMetrics.resolve(hhea: hhea, os2: os2);
      expect(metrics.source, VerticalMetricsSource.typographic);
      expect(metrics.ascent, 750);
      expect(metrics.descent, -250);
      expect(metrics.lineGap, 200);
      expect(metrics.lineHeight, 1200);

      // Same font, bit cleared: hhea wins and the line is 200 units shorter.
      final Os2Table without = Os2Table.parse(
        _synthetic(<String, List<int>>{
          'OS/2': _os2Bytes(version: 4, typoAscender: 750),
        }),
      )!;
      final VerticalMetrics fallback =
          VerticalMetrics.resolve(hhea: hhea, os2: without);
      expect(fallback.source, VerticalMetricsSource.horizontalHeader);
      expect(fallback.lineHeight, 1000);
    });

    test('an empty hhea falls through to the win metrics, negated', () {
      final HheaTable hhea = HheaTable.parse(
        _synthetic(<String, List<int>>{
          'hhea': _hheaBytes(ascender: 0, descender: 0),
        }),
      );
      final Os2Table os2 = Os2Table.parse(
        _synthetic(<String, List<int>>{
          'OS/2': _os2Bytes(version: 4, winAscent: 1100, winDescent: 300),
        }),
      )!;

      final VerticalMetrics metrics =
          VerticalMetrics.resolve(hhea: hhea, os2: os2);
      expect(metrics.source, VerticalMetricsSource.windows);
      expect(metrics.ascent, 1100);
      // usWinDescent is a positive magnitude in the file; every consumer of
      // this type gets a negative descent regardless of which source won.
      expect(metrics.descent, -300);
      expect(metrics.lineGap, 0);
    });

    test('a face with no metrics at all fails rather than laying out flat', () {
      final HheaTable hhea = HheaTable.parse(
        _synthetic(<String, List<int>>{
          'hhea': _hheaBytes(ascender: 0, descender: 0),
        }),
      );

      expect(
        () => VerticalMetrics.resolve(hhea: hhea),
        throwsA(isA<FontFormatException>().having(
          (FontFormatException e) => e.message,
          'message',
          contains('no vertical metrics'),
        )),
      );
      expect(
        () => VerticalMetrics.resolve(
          hhea: hhea,
          os2: Os2Table.parse(_synthetic(<String, List<int>>{
            'OS/2': _os2Bytes(version: 4, winAscent: 0, winDescent: 0),
          })),
        ),
        throwsA(isA<FontFormatException>()),
      );
    });

    test('an hhea with only a descender still counts as stated', () {
      final HheaTable hhea = HheaTable.parse(
        _synthetic(<String, List<int>>{
          'hhea': _hheaBytes(ascender: 0, descender: -250),
        }),
      );
      final VerticalMetrics metrics = VerticalMetrics.resolve(hhea: hhea);
      expect(metrics.source, VerticalMetricsSource.horizontalHeader);
      expect(metrics.ascent, 0);
      expect(metrics.descent, -250);
    });
  });

  group('post, on real fonts', () {
    test('Roboto is version 3.0 and has no glyph names, and says so', () {
      final PostTable post = PostTable.parse(_roboto())!;

      expect(post.version, 3.0);
      expect(post.hasGlyphNames, isFalse);
      expect(post.namedGlyphCount, 0);
      expect(post.italicAngle, 0.0);
      expect(post.underlinePosition, -150);
      expect(post.underlineThickness, 100);
      expect(post.isFixedPitch, isFalse);
      // Null, not '' and not 'glyph37': a synthesised name would look real to
      // a PDF writer and produce a file that renders wrongly elsewhere.
      expect(post.nameOf(0), isNull);
      expect(post.nameOf(37), isNull);
      expect(post.glyphForName('A'), isNull);
      expect(
        () => post.requireNameOf(37),
        throwsA(isA<FontFormatException>().having(
          (FontFormatException e) => e.message,
          'message',
          contains('stores no glyph names at all'),
        )),
      );
    });

    test('DejaVu is version 2.0 with 6253 names', () {
      final PostTable post = PostTable.parse(_dejaVu())!;

      expect(post.version, 2.0);
      expect(post.hasGlyphNames, isTrue);
      expect(post.namedGlyphCount, 6253);
      expect(post.underlinePosition, -40);
      expect(post.underlineThickness, 90);
      expect(post.nameOf(0), '.notdef');
      expect(post.nameOf(1), '.null');
      expect(post.nameOf(2), 'nonmarkingreturn');
      expect(post.nameOf(3), 'space');
      expect(post.nameOf(36), 'A');
      expect(post.requireNameOf(36), 'A');
      // The reverse index, cross-checked against the cmap: both must agree
      // that glyph 36 is the letter A.
      expect(post.glyphForName('A'), 36);
      expect(post.glyphForName('space'), 3);
      expect(post.glyphForName('no such glyph'), isNull);
      expect(CmapTable.parse(_dejaVu()).glyphFor(0x41), 36);
    });

    test('Ahem 2.0 mixes standard names with its own', () {
      final PostTable post = PostTable.parse(_ahem())!;

      expect(post.version, 2.0);
      expect(post.namedGlyphCount, 281);
      expect(post.nameOf(0), '.notdef', reason: 'a standard-order index');
      // These two come from the Pascal string pool rather than the standard
      // 258, which is the branch a font of only standard names never reaches.
      expect(post.nameOf(1), 'NULL');
      expect(post.nameOf(2), 'glyph243');
      expect(post.nameOf(3), 'space');
      expect(post.glyphForName('A'), 35);
      expect(CmapTable.parse(_ahem()).glyphFor(0x41), 35);
    });

    test('a font without post yields null', () {
      expect(
        PostTable.parse(_synthetic(<String, List<int>>{'hhea': _hheaBytes()})),
        isNull,
      );
    });
  });

  group('post, on bytes', () {
    test('the standard 258 are complete, in order, and distinct', () {
      expect(PostTable.macintoshGlyphNames.length, 258);
      expect(PostTable.macintoshGlyphNames.toSet().length, 258);
      expect(PostTable.macintoshGlyphNames[0], '.notdef');
      expect(PostTable.macintoshGlyphNames[1], '.null');
      expect(PostTable.macintoshGlyphNames[2], 'nonmarkingreturn');
      expect(PostTable.macintoshGlyphNames[3], 'space');
      expect(PostTable.macintoshGlyphNames[36], 'A');
      expect(PostTable.macintoshGlyphNames[68], 'a');
      expect(PostTable.macintoshGlyphNames[97], 'asciitilde');
      expect(PostTable.macintoshGlyphNames[98], 'Adieresis');
      expect(PostTable.macintoshGlyphNames[257], 'dcroat');
    });

    test('version 1.0 implies the 258 standard names', () {
      final PostTable post = PostTable.parse(
        _synthetic(<String, List<int>>{'post': _postHeader(1.0)}),
      )!;

      expect(post.version, 1.0);
      expect(post.hasGlyphNames, isTrue);
      expect(post.namedGlyphCount, 258);
      expect(post.nameOf(3), 'space');
      expect(post.nameOf(257), 'dcroat');
      expect(post.nameOf(258), isNull);
      expect(post.glyphForName('dcroat'), 257);
    });

    test('version 2.0 resolves standard indices and the string pool', () {
      final _Bytes b = _Bytes()
        ..bytes(_postHeader(2.0, italicAngle: -12.5, underlinePosition: -75))
        ..u16(5)
        // Glyph 0 and 1 name standard glyphs; 2, 3 and 4 index the pool.
        ..u16(0)
        ..u16(36)
        ..u16(258)
        ..u16(259)
        ..u16(999) // past the pool: the glyph loses its name, the font lives
        ..pascal('uni4E00')
        ..pascal('a.alt');

      final PostTable post = PostTable.parse(
        _synthetic(<String, List<int>>{'post': b.take()}),
      )!;

      expect(post.version, 2.0);
      expect(post.italicAngle, closeTo(-12.5, 1e-9));
      expect(post.underlinePosition, -75);
      expect(post.namedGlyphCount, 5);
      expect(post.nameOf(0), '.notdef');
      expect(post.nameOf(1), 'A');
      expect(post.nameOf(2), 'uni4E00');
      expect(post.nameOf(3), 'a.alt');
      expect(post.nameOf(4), isNull);
      expect(post.glyphForName('uni4E00'), 2);
      expect(post.glyphForName('a.alt'), 3);
      expect(
        () => post.requireNameOf(4),
        throwsA(isA<FontFormatException>().having(
          (FontFormatException e) => e.message,
          'message',
          contains('glyph 4 has no name'),
        )),
      );
    });

    test('version 2.0 that overstates its glyph count is refused', () {
      final _Bytes b = _Bytes()
        ..bytes(_postHeader(2.0))
        ..u16(500) // 1000 bytes of indices in a table that has four
        ..u16(0)
        ..u16(1);

      expect(
        () =>
            PostTable.parse(_synthetic(<String, List<int>>{'post': b.take()})),
        throwsA(isA<FontFormatException>().having(
          (FontFormatException e) => e.message,
          'message',
          contains('500 glyph name indices'),
        )),
      );
    });

    test('version 2.5 applies its signed deltas to the standard order', () {
      final _Bytes b = _Bytes()
        ..bytes(_postHeader(2.5))
        ..u16(4)
        ..i8(0) // glyph 0 -> standard 0
        ..i8(35) // glyph 1 -> standard 36, 'A'
        ..i8(1) // glyph 2 -> standard 3, 'space'
        ..i8(-2); // glyph 3 -> standard 1, '.null'

      final PostTable post = PostTable.parse(
        _synthetic(<String, List<int>>{'post': b.take()}),
      )!;

      expect(post.version, 2.5);
      expect(post.namedGlyphCount, 4);
      expect(post.nameOf(0), '.notdef');
      expect(post.nameOf(1), 'A');
      expect(post.nameOf(2), 'space');
      expect(post.nameOf(3), '.null');
    });

    test('version 3.0 carries the header and nothing else', () {
      final PostTable post = PostTable.parse(
        _synthetic(<String, List<int>>{
          'post': _postHeader(
            3.0,
            italicAngle: -9.0,
            underlinePosition: -200,
            underlineThickness: 40,
            isFixedPitch: true,
          ),
        }),
      )!;

      expect(post.version, 3.0);
      expect(post.isFixedPitch, isTrue);
      expect(post.italicAngle, closeTo(-9.0, 1e-9));
      expect(post.underlinePosition, -200);
      expect(post.underlineThickness, 40);
      expect(post.hasGlyphNames, isFalse);
      expect(post.nameOf(0), isNull);
      expect(() => post.requireNameOf(0), throwsA(isA<FontFormatException>()));
    });

    test('an unknown version is refused rather than read as 3.0', () {
      expect(
        () => PostTable.parse(
          _synthetic(<String, List<int>>{'post': _postHeader(4.0)}),
        ),
        throwsA(isA<FontFormatException>().having(
          (FontFormatException e) => e.message,
          'message',
          contains('not one of 1.0, 2.0, 2.5 or 3.0'),
        )),
      );
    });

    test('a post table shorter than its header is refused', () {
      expect(
        () => PostTable.parse(
          _synthetic(<String, List<int>>{
            'post': _postHeader(3.0).sublist(0, 20),
          }),
        ),
        throwsA(isA<FontFormatException>().having(
          (FontFormatException e) => e.message,
          'message',
          contains('32-byte header'),
        )),
      );
    });
  });
}
