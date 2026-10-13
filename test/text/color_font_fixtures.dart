/// Colour-bitmap fonts built in memory, for tests that must not depend on
/// Apple Color Emoji or Noto Color Emoji being installed.
///
/// A real fixture font from `test/fonts/` supplies everything a `Typeface`
/// needs to parse - `head`, `cmap`, outlines - and [withTables] grafts an
/// `sbix` or `CBDT`/`CBLC` table built here onto its directory. The pictures
/// are PNGs encoded by the framework's own encoder, so a test can predict
/// every pixel the painter will blit.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/graphics/image/png_encoder.dart';

/// The bytes of `test/fonts/[name]`.
Uint8List fixtureFontBytes(String name) =>
    File('test/fonts/$name').readAsBytesSync();

/// [font] with [extra] added to its table directory - or replacing a table
/// of the same tag.
///
/// The original tables are copied after a new directory, 4-byte aligned.
/// Checksums are written as zero: the parser does not validate them, and the
/// tests that use this are about the tables, not the directory.
Uint8List withTables(Uint8List font, Map<String, Uint8List> extra) {
  final ByteData view = ByteData.sublistView(font);
  final int numTables = view.getUint16(4);
  final Map<String, Uint8List> tables = <String, Uint8List>{};
  for (int i = 0; i < numTables; i++) {
    final int record = 12 + i * 16;
    final String tag = String.fromCharCodes(font, record, record + 4);
    final int offset = view.getUint32(record + 8);
    final int length = view.getUint32(record + 12);
    tables[tag] = Uint8List.sublistView(font, offset, offset + length);
  }
  tables.addAll(extra);
  final List<String> tags = tables.keys.toList()..sort();

  final BytesBuilder out = BytesBuilder();
  final int headerLength = 12 + tags.length * 16;
  final ByteData header = ByteData(headerLength);
  header.setUint32(0, view.getUint32(0));
  header.setUint16(4, tags.length);
  int offset = _align(headerLength);
  for (int i = 0; i < tags.length; i++) {
    final Uint8List data = tables[tags[i]]!;
    final int record = 12 + i * 16;
    for (int c = 0; c < 4; c++) {
      header.setUint8(record + c, tags[i].codeUnitAt(c));
    }
    header.setUint32(record + 8, offset);
    header.setUint32(record + 12, data.length);
    offset = _align(offset + data.length);
  }
  out.add(header.buffer.asUint8List());
  _pad(out);
  for (final String tag in tags) {
    out.add(tables[tag]!);
    _pad(out);
  }
  return out.takeBytes();
}

int _align(int value) => (value + 3) & ~3;

void _pad(BytesBuilder out) {
  while (out.length % 4 != 0) {
    out.addByte(0);
  }
}

/// A [width] by [height] PNG of one opaque colour, `0xAARRGGBB`.
Uint8List solidPng(int width, int height, int argb) {
  final Uint8List rgba = Uint8List(width * height * 4);
  for (int i = 0; i < rgba.length; i += 4) {
    rgba[i] = argb >> 16 & 0xFF;
    rgba[i + 1] = argb >> 8 & 0xFF;
    rgba[i + 2] = argb & 0xFF;
    rgba[i + 3] = argb >> 24 & 0xFF;
  }
  return encodePng(width: width, height: height, pixels: rgba);
}

/// One glyph record of an `sbix` strike.
final class SbixRecord {
  const SbixRecord(this.type, this.data, {this.originX = 0, this.originY = 0});

  /// A record that points at [glyph]'s picture in the same strike.
  SbixRecord.dupe(int glyph)
      : this('dupe', Uint8List.fromList(<int>[glyph >> 8, glyph & 0xFF]));

  final String type;
  final Uint8List data;
  final int originX;
  final int originY;
}

/// An `sbix` table for a face of [glyphCount] glyphs: one strike per entry
/// of [strikes], keyed by ppem, each mapping glyph ids to records. Glyphs a
/// strike does not name get an empty record, which is "no picture".
Uint8List sbixTable({
  required int glyphCount,
  required Map<int, Map<int, SbixRecord>> strikes,
  int flags = 1,
}) {
  final List<Uint8List> built = <Uint8List>[
    for (final MapEntry<int, Map<int, SbixRecord>> strike in strikes.entries)
      _sbixStrike(glyphCount, strike.key, strike.value),
  ];
  final int headerLength = 8 + built.length * 4;
  final ByteData header = ByteData(headerLength)
    ..setUint16(0, 1)
    ..setUint16(2, flags)
    ..setUint32(4, built.length);
  int offset = headerLength;
  for (int i = 0; i < built.length; i++) {
    header.setUint32(8 + i * 4, offset);
    offset += built[i].length;
  }
  final BytesBuilder out = BytesBuilder()..add(header.buffer.asUint8List());
  for (final Uint8List strike in built) {
    out.add(strike);
  }
  return out.takeBytes();
}

Uint8List _sbixStrike(int glyphCount, int ppem, Map<int, SbixRecord> glyphs) {
  final int headerLength = 4 + (glyphCount + 1) * 4;
  final ByteData header = ByteData(headerLength)
    ..setUint16(0, ppem)
    ..setUint16(2, 72);
  final BytesBuilder records = BytesBuilder();
  for (int glyph = 0; glyph <= glyphCount; glyph++) {
    header.setUint32(4 + glyph * 4, headerLength + records.length);
    if (glyph == glyphCount) break;
    final SbixRecord? record = glyphs[glyph];
    if (record == null) continue;
    final ByteData head = ByteData(8)
      ..setInt16(0, record.originX)
      ..setInt16(2, record.originY);
    for (int c = 0; c < 4; c++) {
      head.setUint8(4 + c, record.type.codeUnitAt(c));
    }
    records
      ..add(head.buffer.asUint8List())
      ..add(record.data);
  }
  return (BytesBuilder()
        ..add(header.buffer.asUint8List())
        ..add(records.takeBytes()))
      .takeBytes();
}

/// One glyph of a `CBDT` strike: its PNG and its metrics.
final class CbdtGlyph {
  const CbdtGlyph(
    this.png, {
    required this.width,
    required this.height,
    this.bearingX = 0,
    this.bearingY = 0,
    this.advance = 0,
  });

  final Uint8List png;
  final int width;
  final int height;
  final int bearingX;
  final int bearingY;
  final int advance;
}

/// A `CBLC` and `CBDT` pair with one strike at [ppem] covering
/// [firstGlyph]..[lastGlyph].
///
/// [indexFormat] 1 writes a dense uint32 offset array (what Noto Color Emoji
/// uses) and 4 a sparse glyph/offset list; [imageFormat] 17 writes small
/// metrics and 18 big ones. Glyphs in the range that [glyphs] does not name
/// have an empty record under format 1 and are absent under format 4.
({Uint8List cblc, Uint8List cbdt}) cbdtTables({
  required int ppem,
  required int firstGlyph,
  required int lastGlyph,
  required Map<int, CbdtGlyph> glyphs,
  int indexFormat = 1,
  int imageFormat = 17,
}) {
  // CBDT: a 4-byte header, then the records back to back.
  final BytesBuilder cbdt = BytesBuilder()
    ..add(Uint8List.fromList(<int>[0, 3, 0, 0]));
  const int imageDataOffset = 4;
  final Map<int, int> starts = <int, int>{};
  final Map<int, int> ends = <int, int>{};
  for (int glyph = firstGlyph; glyph <= lastGlyph; glyph++) {
    starts[glyph] = cbdt.length - imageDataOffset;
    final CbdtGlyph? g = glyphs[glyph];
    if (g != null) {
      final ByteData metrics;
      if (imageFormat == 17) {
        metrics = ByteData(5)
          ..setUint8(0, g.height)
          ..setUint8(1, g.width)
          ..setInt8(2, g.bearingX)
          ..setInt8(3, g.bearingY)
          ..setUint8(4, g.advance);
      } else {
        metrics = ByteData(8)
          ..setUint8(0, g.height)
          ..setUint8(1, g.width)
          ..setInt8(2, g.bearingX)
          ..setInt8(3, g.bearingY)
          ..setUint8(4, g.advance);
      }
      cbdt
        ..add(metrics.buffer.asUint8List())
        ..add((ByteData(4)..setUint32(0, g.png.length)).buffer.asUint8List())
        ..add(g.png);
    }
    ends[glyph] = cbdt.length - imageDataOffset;
  }

  // The index subtable.
  final BytesBuilder subtable = BytesBuilder()
    ..add((ByteData(8)
          ..setUint16(0, indexFormat)
          ..setUint16(2, imageFormat)
          ..setUint32(4, imageDataOffset))
        .buffer
        .asUint8List());
  if (indexFormat == 1) {
    for (int glyph = firstGlyph; glyph <= lastGlyph; glyph++) {
      subtable.add(
          (ByteData(4)..setUint32(0, starts[glyph]!)).buffer.asUint8List());
    }
    subtable.add(
        (ByteData(4)..setUint32(0, ends[lastGlyph]!)).buffer.asUint8List());
  } else {
    final List<int> present = <int>[
      for (int glyph = firstGlyph; glyph <= lastGlyph; glyph++)
        if (glyphs.containsKey(glyph)) glyph,
    ];
    subtable
        .add((ByteData(4)..setUint32(0, present.length)).buffer.asUint8List());
    for (final int glyph in present) {
      subtable.add((ByteData(4)
            ..setUint16(0, glyph)
            ..setUint16(2, starts[glyph]!))
          .buffer
          .asUint8List());
    }
    // The sentinel: where the last record ends.
    subtable.add((ByteData(4)
          ..setUint16(0, 0xFFFF)
          ..setUint16(2, ends[lastGlyph]!))
        .buffer
        .asUint8List());
  }

  // CBLC: header, one BitmapSize, one IndexSubTableArray entry, the subtable.
  const int arrayOffset = 8 + 48;
  final ByteData cblcHead = ByteData(arrayOffset + 8)
    ..setUint16(0, 3)
    ..setUint16(2, 0)
    ..setUint32(4, 1)
    ..setUint32(8, arrayOffset)
    ..setUint32(12, 8 + subtable.length)
    ..setUint32(16, 1)
    ..setUint16(8 + 40, firstGlyph)
    ..setUint16(8 + 42, lastGlyph)
    ..setUint8(8 + 44, ppem)
    ..setUint8(8 + 45, ppem)
    ..setUint8(8 + 46, 32)
    ..setUint8(8 + 47, 1)
    ..setUint16(arrayOffset, firstGlyph)
    ..setUint16(arrayOffset + 2, lastGlyph)
    ..setUint32(arrayOffset + 4, 8);
  final Uint8List cblc = (BytesBuilder()
        ..add(cblcHead.buffer.asUint8List())
        ..add(subtable.takeBytes()))
      .takeBytes();
  return (cblc: cblc, cbdt: cbdt.takeBytes());
}

/// Where Apple Color Emoji lives on macOS, or null on any machine without it.
///
/// The machine-dependent tests skip when this is null; the synthetic tables
/// above are what every machine runs.
String? appleColorEmojiPath() {
  const String path = '/System/Library/Fonts/Apple Color Emoji.ttc';
  return File(path).existsSync() ? path : null;
}
