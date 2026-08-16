/// `cmap` subtable selection, format 13, and format 14 variation sequences.
///
/// The three fixtures pin down subtable *selection*, which is the decision that
/// matters most and the one a synthetic font cannot exercise honestly: Roboto
/// and DejaVu both offer a Windows UCS-4 subtable and must be read through it,
/// while Ahem offers only the BMP one. None of the three has a format 13 or a
/// format 14 subtable - almost no font does, which is exactly why those two
/// formats are tested against bytes assembled here.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/text/cmap.dart';
import 'package:dart_ui/src/text/font_data.dart';
import 'package:dart_ui/src/text/sfnt.dart';
import 'package:test/test.dart';

Uint8List _fontBytes(String name) => File('test/fonts/$name').readAsBytesSync();

SfntFile _file(String name) => SfntFile.parse(FontData(_fontBytes(name)));

// ---------------------------------------------------------------------------
// Byte builders.
// ---------------------------------------------------------------------------

final class _Bytes {
  final List<int> _out = <int>[];

  int get length => _out.length;

  void u8(int value) => _out.add(value & 0xFF);

  void u16(int value) {
    _out
      ..add((value >> 8) & 0xFF)
      ..add(value & 0xFF);
  }

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

  void bytes(List<int> data) => _out.addAll(data);

  List<int> take() => _out;
}

Uint8List _buildSfnt(Map<String, List<int>> tables) {
  final List<String> tags = tables.keys.toList()..sort();
  int offset = 12 + 16 * tags.length;
  final Map<String, int> offsets = <String, int>{};
  for (final String tag in tags) {
    offsets[tag] = offset;
    offset += tables[tag]!.length;
    offset = (offset + 3) & ~3;
  }

  final Uint8List out = Uint8List(offset);
  final ByteData view = ByteData.sublistView(out);
  view.setUint32(0, 0x00010000);
  view.setUint16(4, tags.length);

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

/// One `(startCode, endCode, value)` triple, as formats 12 and 13 store them.
typedef _Group = ({int start, int end, int value});

/// A format 12 or 13 subtable. The two have identical bytes; only the meaning
/// of the third field differs, which is what makes reading one as the other so
/// quietly wrong.
List<int> _groupedSubtable(int format, List<_Group> groups) {
  final _Bytes b = _Bytes()
    ..u16(format)
    ..u16(0) // reserved
    ..u32(16 + groups.length * 12) // length
    ..u32(0) // language
    ..u32(groups.length);
  for (final _Group group in groups) {
    b
      ..u32(group.start)
      ..u32(group.end)
      ..u32(group.value);
  }
  return b.take();
}

/// What one variation selector declares.
typedef _Selector = ({
  int selector,
  List<({int first, int additional})> defaults,
  List<({int code, int glyph})> nonDefaults,
});

List<int> _format14Subtable(List<_Selector> selectors) {
  // The record array is fixed-size, so the two payload tables of every
  // selector can be laid out after it and their offsets computed up front.
  final int recordsEnd = 10 + selectors.length * 11;

  final _Bytes payload = _Bytes();
  final List<int> defaultOffsets = <int>[];
  final List<int> nonDefaultOffsets = <int>[];
  for (final _Selector selector in selectors) {
    if (selector.defaults.isEmpty) {
      defaultOffsets.add(0);
    } else {
      defaultOffsets.add(recordsEnd + payload.length);
      payload.u32(selector.defaults.length);
      for (final ({int first, int additional}) range in selector.defaults) {
        payload
          ..u24(range.first)
          ..u8(range.additional);
      }
    }
    if (selector.nonDefaults.isEmpty) {
      nonDefaultOffsets.add(0);
    } else {
      nonDefaultOffsets.add(recordsEnd + payload.length);
      payload.u32(selector.nonDefaults.length);
      for (final ({int code, int glyph}) mapping in selector.nonDefaults) {
        payload
          ..u24(mapping.code)
          ..u16(mapping.glyph);
      }
    }
  }

  final _Bytes b = _Bytes()
    ..u16(14)
    ..u32(recordsEnd + payload.length)
    ..u32(selectors.length);
  for (int i = 0; i < selectors.length; i++) {
    b
      ..u24(selectors[i].selector)
      ..u32(defaultOffsets[i])
      ..u32(nonDefaultOffsets[i]);
  }
  return (b..bytes(payload.take())).take();
}

/// A `cmap` table holding [subtables], each keyed by its platform/encoding.
List<int> _cmapTable(
  List<({int platform, int encoding, List<int> data})> subtables,
) {
  int offset = 4 + subtables.length * 8;
  final List<int> offsets = <int>[];
  for (final ({int platform, int encoding, List<int> data}) subtable
      in subtables) {
    offsets.add(offset);
    offset += subtable.data.length;
  }

  final _Bytes b = _Bytes()
    ..u16(0) // version
    ..u16(subtables.length);
  for (int i = 0; i < subtables.length; i++) {
    b
      ..u16(subtables[i].platform)
      ..u16(subtables[i].encoding)
      ..u32(offsets[i]);
  }
  for (final ({int platform, int encoding, List<int> data}) subtable
      in subtables) {
    b.bytes(subtable.data);
  }
  return b.take();
}

CmapTable _parseCmap(
  List<({int platform, int encoding, List<int> data})> subtables,
) =>
    CmapTable.parse(
      SfntFile.parse(
        FontData(
            _buildSfnt(<String, List<int>>{'cmap': _cmapTable(subtables)})),
      ),
    );

/// A base map used by the format 14 tests: a heart, a grinning face and a CJK
/// ideograph, each with a distinct glyph.
List<int> _baseSubtable() => _groupedSubtable(12, <_Group>[
      (start: 0x2764, end: 0x2764, value: 5),
      (start: 0x845B, end: 0x845B, value: 9),
      (start: 0x1F600, end: 0x1F600, value: 7),
    ]);

void main() {
  group('subtable selection is unchanged by the new formats', () {
    test('Roboto and DejaVu are read through Windows UCS-4', () {
      for (final String font in <String>[
        'Roboto-Regular.ttf',
        'DejaVuSans.ttf',
      ]) {
        final CmapTable cmap = CmapTable.parse(_file(font));
        expect(cmap.encoding, (platform: 3, encoding: 10));
      }
    });

    test('Ahem has only the BMP subtable', () {
      final CmapTable cmap = CmapTable.parse(_file('ahem.ttf'));
      expect(cmap.encoding, (platform: 3, encoding: 1));
      expect(cmap.glyphFor(0x41), 35);
    });

    test('no fixture has a variation selector subtable', () {
      for (final String font in <String>[
        'Roboto-Regular.ttf',
        'DejaVuSans.ttf',
        'ahem.ttf',
      ]) {
        final CmapTable cmap = CmapTable.parse(_file(font));
        expect(cmap.variationSelectors, isNull, reason: font);
        // And the query still answers, cheaply and without a null dereference.
        expect(cmap.glyphForVariation(0x2764, variationSelectorEmoji), isNull);
      }
    });
  });

  group('format 13', () {
    test('every code point in a group maps to the same glyph', () {
      final CmapTable cmap = _parseCmap(
        <({int platform, int encoding, List<int> data})>[
          (
            platform: 3,
            encoding: 10,
            data: _groupedSubtable(13, <_Group>[
              (start: 0x0900, end: 0x097F, value: 4), // all Devanagari -> 4
              (start: 0x0E00, end: 0x0E7F, value: 5), // all Thai -> 5
            ]),
          ),
        ],
      );

      expect(cmap.glyphFor(0x0900), 4);
      expect(cmap.glyphFor(0x0915), 4);
      expect(cmap.glyphFor(0x097F), 4);
      expect(cmap.glyphFor(0x0E01), 5);
      expect(cmap.glyphFor(0x0E7F), 5);
      expect(cmap.glyphFor(0x0980), notdefGlyph);
      expect(cmap.glyphFor(0x0041), notdefGlyph);
    });

    test('it is not format 12, and the difference is visible', () {
      const List<_Group> groups = <_Group>[
        (start: 0x0900, end: 0x0903, value: 4),
      ];
      final CmapTable asThirteen = _parseCmap(
        <({int platform, int encoding, List<int> data})>[
          (platform: 3, encoding: 10, data: _groupedSubtable(13, groups)),
        ],
      );
      final CmapTable asTwelve = _parseCmap(
        <({int platform, int encoding, List<int> data})>[
          (platform: 3, encoding: 10, data: _groupedSubtable(12, groups)),
        ],
      );

      // Identical bytes but for the format field, and a different answer for
      // every code point after the first. Reading a last-resort font as
      // format 12 would draw four different glyphs where the font asked for
      // one, with no error anywhere.
      expect(asThirteen.glyphFor(0x0903), 4);
      expect(asTwelve.glyphFor(0x0903), 7);
    });

    test('it enumerates its coverage', () {
      final CmapTable cmap = _parseCmap(
        <({int platform, int encoding, List<int> data})>[
          (
            platform: 3,
            encoding: 10,
            data: _groupedSubtable(13, <_Group>[
              (start: 0x30, end: 0x34, value: 3),
            ]),
          ),
        ],
      );

      expect(
        cmap.characterMap.codePoints.toList(),
        <int>[0x30, 0x31, 0x32, 0x33, 0x34],
      );
    });

    test('an implausible group count is refused', () {
      final _Bytes b = _Bytes()
        ..u16(13)
        ..u16(0)
        ..u32(16)
        ..u32(0)
        ..u32(0x200000);

      expect(
        () => _parseCmap(<({int platform, int encoding, List<int> data})>[
          (platform: 3, encoding: 10, data: b.take()),
        ]),
        throwsA(isA<FontFormatException>().having(
          (FontFormatException e) => e.message,
          'message',
          contains('format 13 claims'),
        )),
      );
    });
  });

  group('format 14 variation sequences', () {
    CmapTable withVariations() => _parseCmap(
          <({int platform, int encoding, List<int> data})>[
            (platform: 3, encoding: 10, data: _baseSubtable()),
            (
              platform: 0,
              encoding: 5,
              data: _format14Subtable(<_Selector>[
                // VS15: the heart has a text presentation, and it is the glyph
                // the ordinary cmap already gives - a default UVS record.
                (
                  selector: variationSelectorText,
                  defaults: <({int first, int additional})>[
                    (first: 0x2764, additional: 0),
                  ],
                  nonDefaults: <({int code, int glyph})>[],
                ),
                // VS16: the heart has an emoji presentation with its own glyph.
                (
                  selector: variationSelectorEmoji,
                  defaults: <({int first, int additional})>[],
                  nonDefaults: <({int code, int glyph})>[
                    (code: 0x2764, glyph: 6),
                  ],
                ),
                // An ideographic variation selector, with both kinds at once.
                (
                  selector: 0xE0100,
                  defaults: <({int first, int additional})>[
                    (first: 0x4E00, additional: 3), // U+4E00..U+4E03
                  ],
                  nonDefaults: <({int code, int glyph})>[
                    (code: 0x845B, glyph: 10),
                  ],
                ),
              ]),
            ),
          ],
        );

    test('the subtable is found and does not displace the character map', () {
      final CmapTable cmap = withVariations();

      expect(cmap.encoding, (platform: 3, encoding: 10));
      expect(cmap.glyphFor(0x2764), 5);
      expect(cmap.variationSelectors, isNotNull);
      expect(cmap.variationSelectors!.selectorCount, 3);
      expect(
        cmap.variationSelectors!.selectors,
        <int>[variationSelectorText, variationSelectorEmoji, 0xE0100],
      );
      expect(
          cmap.variationSelectors!.hasSelector(variationSelectorText), isTrue);
      expect(cmap.variationSelectors!.hasSelector(0xFE0D), isFalse);
    });

    test('a default UVS resolves to the ordinary cmap glyph', () {
      final CmapTable cmap = withVariations();
      final VariationSelectorMap map = cmap.variationSelectors!;

      expect(map.isDefaultVariation(0x2764, variationSelectorText), isTrue);
      expect(map.nonDefaultGlyph(0x2764, variationSelectorText), isNull);
      expect(map.covers(0x2764, variationSelectorText), isTrue);
      // The sequence resolves to glyph 5 - the plain heart - because that is
      // what "default" means. It must not resolve to null, which would tell a
      // caller the font has no text presentation when it explicitly says it
      // does.
      expect(cmap.glyphForVariation(0x2764, variationSelectorText), 5);
      expect(cmap.glyphForVariation(0x2764, variationSelectorText),
          cmap.glyphFor(0x2764));
    });

    test('a non-default UVS resolves to its own glyph', () {
      final CmapTable cmap = withVariations();
      final VariationSelectorMap map = cmap.variationSelectors!;

      expect(map.nonDefaultGlyph(0x2764, variationSelectorEmoji), 6);
      expect(map.isDefaultVariation(0x2764, variationSelectorEmoji), isFalse);
      // 6, not 5: the whole reason U+2764 U+FE0F is not U+2764.
      expect(cmap.glyphForVariation(0x2764, variationSelectorEmoji), 6);
      expect(cmap.glyphFor(0x2764), 5);
    });

    test('an uncovered pair is null, and stays distinct from a default', () {
      final CmapTable cmap = withVariations();
      final VariationSelectorMap map = cmap.variationSelectors!;

      // The grinning face is in the cmap but the font says nothing about its
      // presentation, so the sequence is unsupported even though the base
      // character is not.
      expect(cmap.glyphFor(0x1F600), 7);
      expect(map.covers(0x1F600, variationSelectorText), isFalse);
      expect(cmap.glyphForVariation(0x1F600, variationSelectorText), isNull);
      // An unknown selector entirely.
      expect(cmap.glyphForVariation(0x2764, 0xFE0D), isNull);
      // A base character the font does not have at all.
      expect(cmap.glyphForVariation(0x1F601, variationSelectorEmoji), isNull);
    });

    test('a default range covers its additionalCount successors', () {
      final VariationSelectorMap map = withVariations().variationSelectors!;

      // additionalCount 3 means four code points, U+4E00 through U+4E03 - the
      // off-by-one this field invites.
      expect(map.isDefaultVariation(0x4E00, 0xE0100), isTrue);
      expect(map.isDefaultVariation(0x4E03, 0xE0100), isTrue);
      expect(map.isDefaultVariation(0x4E04, 0xE0100), isFalse);
      expect(map.isDefaultVariation(0x4DFF, 0xE0100), isFalse);
    });

    test('one selector may carry both kinds of record', () {
      final CmapTable cmap = withVariations();

      expect(cmap.glyphForVariation(0x845B, 0xE0100), 10);
      expect(cmap.glyphFor(0x845B), 9, reason: 'the unvaried form differs');
      expect(cmap.glyphForVariation(0x4E00, 0xE0100), isNull,
          reason: 'a default UVS over a base the cmap does not have');
    });

    test('a default UVS over a character the cmap lacks resolves to null', () {
      // The font asserts "my ordinary mapping is right for this pair" while
      // having no ordinary mapping - a contradiction that must not surface as
      // glyph 0, which a caller would draw as a box.
      final CmapTable cmap = withVariations();
      expect(
          cmap.variationSelectors!.isDefaultVariation(0x4E01, 0xE0100), isTrue);
      expect(cmap.glyphFor(0x4E01), notdefGlyph);
      expect(cmap.glyphForVariation(0x4E01, 0xE0100), isNull);
    });

    test('a font with no format 14 subtable answers null without allocating',
        () {
      final CmapTable cmap = _parseCmap(
        <({int platform, int encoding, List<int> data})>[
          (platform: 3, encoding: 10, data: _baseSubtable()),
        ],
      );

      expect(cmap.variationSelectors, isNull);
      expect(cmap.glyphForVariation(0x2764, variationSelectorEmoji), isNull);
    });

    test('selectors out of ascending order are refused', () {
      final List<int> data = _format14Subtable(<_Selector>[
        (
          selector: variationSelectorEmoji,
          defaults: <({int first, int additional})>[],
          nonDefaults: <({int code, int glyph})>[(code: 0x2764, glyph: 6)],
        ),
        (
          selector: variationSelectorText,
          defaults: <({int first, int additional})>[],
          nonDefaults: <({int code, int glyph})>[(code: 0x2764, glyph: 5)],
        ),
      ]);

      expect(
        () => _parseCmap(<({int platform, int encoding, List<int> data})>[
          (platform: 3, encoding: 10, data: _baseSubtable()),
          (platform: 0, encoding: 5, data: data),
        ]),
        throwsA(isA<FontFormatException>().having(
          (FontFormatException e) => e.message,
          'message',
          contains('not in ascending order'),
        )),
      );
    });

    test('non-default mappings out of order are refused', () {
      final List<int> data = _format14Subtable(<_Selector>[
        (
          selector: variationSelectorEmoji,
          defaults: <({int first, int additional})>[],
          nonDefaults: <({int code, int glyph})>[
            (code: 0x2764, glyph: 6),
            (code: 0x2660, glyph: 8), // descending: the bisection would break
          ],
        ),
      ]);

      expect(
        () => _parseCmap(<({int platform, int encoding, List<int> data})>[
          (platform: 3, encoding: 10, data: _baseSubtable()),
          (platform: 0, encoding: 5, data: data),
        ]),
        throwsA(isA<FontFormatException>().having(
          (FontFormatException e) => e.message,
          'message',
          contains('non-default UVS mappings'),
        )),
      );
    });

    test('default ranges out of order are refused', () {
      final List<int> data = _format14Subtable(<_Selector>[
        (
          selector: variationSelectorText,
          defaults: <({int first, int additional})>[
            (first: 0x2764, additional: 0),
            (first: 0x2660, additional: 0),
          ],
          nonDefaults: <({int code, int glyph})>[],
        ),
      ]);

      expect(
        () => _parseCmap(<({int platform, int encoding, List<int> data})>[
          (platform: 3, encoding: 10, data: _baseSubtable()),
          (platform: 0, encoding: 5, data: data),
        ]),
        throwsA(isA<FontFormatException>().having(
          (FontFormatException e) => e.message,
          'message',
          contains('default UVS ranges'),
        )),
      );
    });

    test('a subtable at 0/5 that is not format 14 is ignored, not fatal', () {
      // The one real failure mode: a font that advertises the encoding and
      // points it at something else. Losing variation sequences is acceptable;
      // losing the whole face over them is not.
      final CmapTable cmap = _parseCmap(
        <({int platform, int encoding, List<int> data})>[
          (platform: 3, encoding: 10, data: _baseSubtable()),
          (
            platform: 0,
            encoding: 5,
            data: _groupedSubtable(12, <_Group>[
              (start: 0x41, end: 0x41, value: 1),
            ]),
          ),
        ],
      );

      expect(cmap.variationSelectors, isNull);
      expect(cmap.glyphFor(0x2764), 5);
    });

    test('a table declaring no selector records yields null', () {
      final CmapTable cmap = _parseCmap(
        <({int platform, int encoding, List<int> data})>[
          (platform: 3, encoding: 10, data: _baseSubtable()),
          (platform: 0, encoding: 5, data: _format14Subtable(<_Selector>[])),
        ],
      );

      expect(cmap.variationSelectors, isNull);
    });

    test('an implausible selector count is refused', () {
      final _Bytes b = _Bytes()
        ..u16(14)
        ..u32(10)
        ..u32(0x2000);

      expect(
        () => _parseCmap(<({int platform, int encoding, List<int> data})>[
          (platform: 3, encoding: 10, data: _baseSubtable()),
          (platform: 0, encoding: 5, data: b.take()),
        ]),
        throwsA(isA<FontFormatException>().having(
          (FontFormatException e) => e.message,
          'message',
          contains('more than the selector space holds'),
        )),
      );
    });
  });
}
