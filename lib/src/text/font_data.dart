/// Reading font bytes without trusting them.
///
/// A font file is untrusted input. It arrives from a user's disk, from a
/// download, or from a document, and section 30.8 of the roadmap is explicit
/// that the parser must survive invalid offsets. The threat is not exotic: a
/// truncated `glyf`, a `loca` whose last entry points past the table, or a
/// composite glyph that references itself are all things that occur in fonts
/// found in the wild, without anybody being malicious.
///
/// So every read goes through [FontReader], which fails with a typed
/// [FontFormatException] naming what it was reading and where. The alternative
/// - letting `ByteData` throw `RangeError` - loses the context that makes a
/// bug report actionable, and worse, invites a `try`/`catch` that swallows the
/// difference between "this font is broken" and "this parser is broken".
library;

import 'dart:typed_data';

/// A font file that failed to parse, with enough context to find out why.
final class FontFormatException implements Exception {
  const FontFormatException(this.message, {this.offset, this.table});

  final String message;

  /// Byte offset in the file where the problem was found, when known.
  final int? offset;

  /// The four-character table tag being read, when the failure happened
  /// inside one.
  final String? table;

  @override
  String toString() {
    final StringBuffer buffer = StringBuffer('FontFormatException: $message');
    if (table != null) buffer.write(' in table "$table"');
    if (offset != null) buffer.write(' at byte $offset');
    return buffer.toString();
  }
}

/// The bytes of one font file.
///
/// Held as a single [Uint8List] with a [ByteData] view over it, and never
/// copied: a 6000-glyph font is a few megabytes, and every table is a range
/// inside this one allocation. Sharing it between [FontReader]s is the whole
/// point - a reader is a cursor, not an owner.
final class FontData {
  FontData(this.bytes) : _view = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData _view;

  int get length => bytes.length;

  /// A reader positioned at [offset].
  FontReader readerAt(int offset, {String? table}) =>
      FontReader(this, offset, table: table);

  /// Whether `[offset, offset + length)` is inside the file.
  bool contains(int offset, int length) =>
      offset >= 0 && length >= 0 && offset + length <= bytes.length;
}

/// A bounds-checked, big-endian cursor over [FontData].
///
/// Big-endian because sfnt is: the format predates the x86 monoculture and
/// every multi-byte field in it is network order. Every accessor here checks
/// before it reads, which costs a comparison per field and buys the property
/// that no malformed font can ever produce a `RangeError` from deep inside a
/// table parser.
final class FontReader {
  FontReader(this.data, this._offset, {this.table}) {
    if (_offset < 0 || _offset > data.length) {
      throw FontFormatException(
        'reader created outside the file (${data.length} bytes)',
        offset: _offset,
        table: table,
      );
    }
  }

  final FontData data;

  /// The table this reader is reading, for error messages only.
  final String? table;

  int _offset;

  int get offset => _offset;

  set offset(int value) {
    _require(value, 0, 'seek');
    _offset = value;
  }

  /// Moves forward by [count] bytes.
  void skip(int count) => offset = _offset + count;

  int readUint8() {
    _require(_offset, 1, 'uint8');
    return data.bytes[_offset++];
  }

  int readInt8() {
    final int value = readUint8();
    return value >= 0x80 ? value - 0x100 : value;
  }

  int readUint16() {
    _require(_offset, 2, 'uint16');
    final int value = data._view.getUint16(_offset);
    _offset += 2;
    return value;
  }

  int readInt16() {
    _require(_offset, 2, 'int16');
    final int value = data._view.getInt16(_offset);
    _offset += 2;
    return value;
  }

  int readUint32() {
    _require(_offset, 4, 'uint32');
    final int value = data._view.getUint32(_offset);
    _offset += 4;
    return value;
  }

  int readInt32() {
    _require(_offset, 4, 'int32');
    final int value = data._view.getInt32(_offset);
    _offset += 4;
    return value;
  }

  /// A 2.14 fixed-point number, the format composite glyph transforms use.
  ///
  /// Range is -2 to just under 2, which is why a component may be mirrored and
  /// doubled but not scaled arbitrarily. Dividing by 16384 rather than
  /// multiplying by a decimal keeps it exact: every F2Dot14 value is
  /// representable in binary floating point.
  double readF2Dot14() => readInt16() / 16384.0;

  /// A 16.16 fixed-point number, used by `head.version` and friends.
  double readFixed() => readInt32() / 65536.0;

  /// A four-character tag, read as ASCII.
  ///
  /// Tags are compared as strings rather than packed ints because the packed
  /// form makes every error message unreadable, and tag comparison happens
  /// once per table rather than once per glyph.
  String readTag() {
    _require(_offset, 4, 'tag');
    final String tag = String.fromCharCodes(
      data.bytes.sublist(_offset, _offset + 4),
    );
    _offset += 4;
    return tag;
  }

  /// A borrowed view of [count] bytes; advances past them.
  ///
  /// A view, not a copy: instruction streams and glyph data are read once and
  /// discarded, and copying them would double the cost of loading a font for
  /// no benefit.
  Uint8List readBytes(int count) {
    _require(_offset, count, 'bytes[$count]');
    final Uint8List view = Uint8List.sublistView(
      data.bytes,
      _offset,
      _offset + count,
    );
    _offset += count;
    return view;
  }

  /// Reads [count] big-endian uint16s into a fresh list.
  Uint16List readUint16List(int count) {
    _require(_offset, count * 2, 'uint16[$count]');
    final Uint16List result = Uint16List(count);
    for (int i = 0; i < count; i++) {
      result[i] = data._view.getUint16(_offset + i * 2);
    }
    _offset += count * 2;
    return result;
  }

  void _require(int at, int length, String what) {
    if (at < 0 || length < 0 || at + length > data.length) {
      throw FontFormatException(
        'reading $what would run past the end of the font '
        '(${data.length} bytes)',
        offset: at,
        table: table,
      );
    }
  }
}
