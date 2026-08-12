/// The sfnt container: how a font file says where its tables are.
///
/// "OpenType file" is a container format with four flavours that differ only in
/// their first four bytes: `0x00010000` and `true` for TrueType outlines,
/// `OTTO` for CFF outlines, and `ttcf` for a collection holding several faces
/// in one file. Everything after that header is the same table directory.
///
/// The directory is validated **once, here**, so that no table parser has to
/// wonder whether its own byte range is real. That is a deliberate trade: one
/// pass over ~20 records at load, in exchange for every later parser being
/// allowed to assume its range is inside the file.
library;

import 'font_data.dart';

/// The four sfnt flavours, by the tag that opens the file.
enum SfntFlavour {
  /// `0x00010000` - TrueType outlines in a `glyf` table.
  trueType,

  /// `OTTO` - PostScript outlines in a `CFF ` table.
  ///
  /// A different outline format entirely: cubic charstrings with their own
  /// interpreter, subroutines and hint machinery. Recognised here so the
  /// failure is a clear "not supported yet" rather than a confusing absence of
  /// `glyf`.
  cff,

  /// `ttcf` - a collection of faces sharing tables.
  collection,
}

/// Where one table lives in the file.
final class TableRecord {
  const TableRecord({
    required this.tag,
    required this.checksum,
    required this.offset,
    required this.length,
  });

  final String tag;
  final int checksum;
  final int offset;
  final int length;

  @override
  String toString() => 'TableRecord($tag, $offset+$length)';
}

/// A parsed table directory: the map from tag to byte range.
final class SfntFile {
  SfntFile._({
    required this.data,
    required this.flavour,
    required Map<String, TableRecord> tables,
    required this.faceCount,
    required this.faceIndex,
  }) : _tables = tables;

  final FontData data;
  final SfntFlavour flavour;
  final Map<String, TableRecord> _tables;

  /// How many faces the file holds. One, except for a `ttcf` collection.
  final int faceCount;

  /// Which face this directory describes.
  final int faceIndex;

  Iterable<String> get tableTags => _tables.keys;

  bool hasTable(String tag) => _tables.containsKey(tag);

  TableRecord? tableRecord(String tag) => _tables[tag];

  /// The record for [tag], or a [FontFormatException] naming what is missing.
  ///
  /// Callers that can proceed without a table use [tableRecord] and check for
  /// null; callers that cannot use this, so the error says which table the
  /// font lacks rather than failing later with a null dereference.
  TableRecord requireTable(String tag) {
    final TableRecord? record = _tables[tag];
    if (record == null) {
      throw FontFormatException('required table "$tag" is missing');
    }
    return record;
  }

  /// A reader positioned at the start of [tag].
  FontReader readerFor(String tag) {
    final TableRecord record = requireTable(tag);
    return data.readerAt(record.offset, table: tag);
  }

  /// Parses the directory for one face.
  ///
  /// [faceIndex] selects a face inside a `ttcf` collection and is ignored
  /// otherwise. macOS ships most of its system faces as collections, so this
  /// is not an exotic path.
  static SfntFile parse(FontData data, {int faceIndex = 0}) {
    final FontReader reader = data.readerAt(0);
    final String tag = reader.readTag();

    if (tag == 'ttcf') {
      reader.skip(4); // majorVersion, minorVersion
      final int faceCount = reader.readUint32();
      if (faceIndex < 0 || faceIndex >= faceCount) {
        throw FontFormatException(
          'face $faceIndex requested from a collection of $faceCount',
        );
      }
      reader.skip(faceIndex * 4);
      final int directoryOffset = reader.readUint32();
      return _parseDirectory(
        data,
        directoryOffset,
        faceCount: faceCount,
        faceIndex: faceIndex,
      );
    }

    return _parseDirectory(data, 0, faceCount: 1, faceIndex: 0);
  }

  static SfntFile _parseDirectory(
    FontData data,
    int directoryOffset, {
    required int faceCount,
    required int faceIndex,
  }) {
    final FontReader reader = data.readerAt(directoryOffset);
    final int version = reader.readUint32();
    final SfntFlavour flavour = switch (version) {
      0x00010000 || 0x74727565 => SfntFlavour.trueType, // 'true'
      0x4F54544F => SfntFlavour.cff, // 'OTTO'
      0x74746366 => SfntFlavour.collection, // nested 'ttcf' - malformed
      _ => throw FontFormatException(
          'not an sfnt font: version 0x${version.toRadixString(16)}',
          offset: directoryOffset,
        ),
    };
    if (flavour == SfntFlavour.collection) {
      throw const FontFormatException('a collection may not contain another');
    }

    final int numTables = reader.readUint16();
    reader.skip(6); // searchRange, entrySelector, rangeShift - all derivable

    final Map<String, TableRecord> tables = <String, TableRecord>{};
    for (int i = 0; i < numTables; i++) {
      final String tag = reader.readTag();
      final int checksum = reader.readUint32();
      final int offset = reader.readUint32();
      final int length = reader.readUint32();

      // Validated here, once, so that no table parser has to re-check its own
      // range. A record pointing outside the file is the single most common
      // way a truncated download presents itself.
      if (!data.contains(offset, length)) {
        throw FontFormatException(
          'table "$tag" claims $length bytes at $offset, past the end of the '
          'file (${data.length} bytes)',
          table: tag,
        );
      }
      tables[tag] = TableRecord(
        tag: tag,
        checksum: checksum,
        offset: offset,
        length: length,
      );
    }

    return SfntFile._(
      data: data,
      flavour: flavour,
      tables: tables,
      faceCount: faceCount,
      faceIndex: faceIndex,
    );
  }

  @override
  String toString() => 'SfntFile(${flavour.name}, ${_tables.length} tables, '
      'face ${faceIndex + 1}/$faceCount)';
}
