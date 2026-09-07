/// A ZIP reader, for the graphics formats that are ZIP containers underneath.
///
/// Three of them already are: CorelDRAW `.cdr` from X4 onwards, dotLottie
/// (`.lottie`), and — should it ever land here — anything else that wraps XML
/// or JSON in a package. The reader lives in `graphics` rather than beside the
/// first format that needed it because `graphics` is the lowest layer that can
/// hold it: `inflate` is already here, and the layering rule lets `cdr` and the
/// document formats above depend on this while nothing here depends on them.
///
/// ## Why the central directory and not a walk of local headers
///
/// The obvious reader walks local file headers from the front. It works on most
/// archives and fails on a whole class of real ones: when bit 3 of the general
/// purpose flags is set, the compressed size in the local header is **zero**
/// and the real value follows the data in a descriptor the reader has not
/// reached yet. Streamed writers set it routinely, and a front-to-back walk
/// stops dead at the first such entry — with no error, having returned the
/// entries it happened to reach.
///
/// The central directory at the end of the file always carries the true sizes,
/// so it is read first and the local headers are used only to find where each
/// entry's data begins. The forward walk stays as a fallback for an archive
/// whose directory is missing or damaged, and [ZipArchive.usedCentralDirectory]
/// reports which path ran, because "some entries are missing" and "this archive
/// is truncated" are different problems and should not look alike.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../image/inflate.dart';

/// One file inside a ZIP container, already decompressed.
final class ZipEntry {
  const ZipEntry({
    required this.name,
    required this.compressionMethod,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.data,
  });

  /// The path as written in the archive, with `/` separators.
  final String name;

  /// 0 for stored, 8 for deflate. Anything else was left compressed and [data]
  /// is the raw bytes; see [ZipArchive.unsupportedMethods].
  final int compressionMethod;

  final int compressedSize;
  final int uncompressedSize;

  /// The decompressed contents.
  final Uint8List data;

  /// The contents as UTF-8 text.
  ///
  /// Malformed sequences become replacement characters rather than throwing:
  /// the callers are format parsers that report their own errors with context,
  /// and a decode failure three frames down says only that some byte somewhere
  /// was not text.
  String readAsString() => utf8.decode(data, allowMalformed: true);

  @override
  String toString() =>
      'ZipEntry($name, $uncompressedSize bytes, method $compressionMethod)';
}

/// A parsed ZIP container.
final class ZipArchive {
  ZipArchive._(this.usedCentralDirectory);

  final Map<String, ZipEntry> _entries = <String, ZipEntry>{};

  /// Whether the entries came from the central directory (the reliable path)
  /// or from a forward walk of local headers (the fallback).
  final bool usedCentralDirectory;

  /// Compression methods encountered and not implemented, if any. An entry with
  /// one of these is present but its `data` is still compressed.
  final Set<int> unsupportedMethods = <int>{};

  Map<String, ZipEntry> get entries => Map<String, ZipEntry>.unmodifiable(
        _entries,
      );

  ZipEntry? operator [](String name) => _entries[name];

  bool contains(String name) => _entries.containsKey(name);

  /// Entry names, in the order the archive lists them.
  Iterable<String> get names => _entries.keys;

  /// Reads [bytes] as a ZIP container.
  ///
  /// Never throws on a malformed archive: what it cannot read it leaves out,
  /// and [usedCentralDirectory] plus an empty result is how a caller tells
  /// "this is not a ZIP" from "this ZIP has nothing I wanted".
  static ZipArchive parse(Uint8List bytes) {
    final int eocd = _findEndOfCentralDirectory(bytes);
    if (eocd >= 0) {
      final ZipArchive? fromDirectory = _parseCentralDirectory(bytes, eocd);
      if (fromDirectory != null && fromDirectory._entries.isNotEmpty) {
        return fromDirectory;
      }
    }
    return _parseLocalHeaders(bytes);
  }

  /// Scans backwards for the end-of-central-directory signature.
  ///
  /// Backwards because the record is last, and bounded to the last 64 KiB plus
  /// the record itself because that is the largest a ZIP comment can be — an
  /// unbounded scan of a large archive for a four-byte pattern that also occurs
  /// inside compressed data is both slower and more likely to find a false
  /// positive.
  static int _findEndOfCentralDirectory(Uint8List bytes) {
    const int minimumRecord = 22;
    if (bytes.length < minimumRecord) return -1;
    final int earliest = bytes.length - minimumRecord - 0xFFFF < 0
        ? 0
        : bytes.length - minimumRecord - 0xFFFF;
    for (var at = bytes.length - minimumRecord; at >= earliest; at--) {
      if (_uint32(bytes, at) == 0x06054B50) return at;
    }
    return -1;
  }

  static ZipArchive? _parseCentralDirectory(Uint8List bytes, int eocd) {
    final archive = ZipArchive._(true);
    final int count = _uint16(bytes, eocd + 10);
    var at = _uint32(bytes, eocd + 16);
    if (at < 0 || at >= bytes.length) return null;

    for (var i = 0; i < count; i++) {
      if (at + 46 > bytes.length) return null;
      if (_uint32(bytes, at) != 0x02014B50) return null;
      final int method = _uint16(bytes, at + 10);
      final int compressedSize = _uint32(bytes, at + 20);
      final int uncompressedSize = _uint32(bytes, at + 24);
      final int nameLength = _uint16(bytes, at + 28);
      final int extraLength = _uint16(bytes, at + 30);
      final int commentLength = _uint16(bytes, at + 32);
      final int localHeader = _uint32(bytes, at + 42);
      final String name =
          _name(bytes, at + 46, nameLength, _uint16(bytes, at + 8));
      at += 46 + nameLength + extraLength + commentLength;

      // A directory entry: no data, and a trailing slash is how ZIP says so.
      if (name.endsWith('/')) continue;

      final int? dataStart = _dataStart(bytes, localHeader);
      if (dataStart == null) continue;
      if (dataStart + compressedSize > bytes.length) continue;

      archive._add(
        name: name,
        method: method,
        compressed: Uint8List.sublistView(
          bytes,
          dataStart,
          dataStart + compressedSize,
        ),
        compressedSize: compressedSize,
        uncompressedSize: uncompressedSize,
      );
    }
    return archive;
  }

  /// Where an entry's data begins, given the offset of its local header.
  ///
  /// The name and extra-field lengths in the *local* header may differ from the
  /// central directory's, which is why they are read again here rather than
  /// reused: an archive that pads the local extra field and not the central one
  /// is legal, and trusting the central lengths would land in the middle of the
  /// compressed stream.
  static int? _dataStart(Uint8List bytes, int localHeader) {
    if (localHeader < 0 || localHeader + 30 > bytes.length) return null;
    if (_uint32(bytes, localHeader) != 0x04034B50) return null;
    final int nameLength = _uint16(bytes, localHeader + 26);
    final int extraLength = _uint16(bytes, localHeader + 28);
    return localHeader + 30 + nameLength + extraLength;
  }

  static ZipArchive _parseLocalHeaders(Uint8List bytes) {
    final archive = ZipArchive._(false);
    var at = 0;
    while (at + 30 <= bytes.length) {
      if (_uint32(bytes, at) != 0x04034B50) break;
      final int flags = _uint16(bytes, at + 6);
      final int method = _uint16(bytes, at + 8);
      final int compressedSize = _uint32(bytes, at + 18);
      final int uncompressedSize = _uint32(bytes, at + 22);
      final int nameLength = _uint16(bytes, at + 26);
      final int extraLength = _uint16(bytes, at + 28);
      final String name = _name(bytes, at + 30, nameLength, flags);
      final int dataStart = at + 30 + nameLength + extraLength;

      // Bit 3: the sizes are in a descriptor after the data and the ones here
      // are zero. Without the central directory there is nothing to look them
      // up in, so the walk stops rather than guessing where the entry ends.
      if ((flags & 0x08) != 0 && compressedSize == 0) break;
      if (dataStart + compressedSize > bytes.length) break;

      if (compressedSize > 0 && !name.endsWith('/')) {
        archive._add(
          name: name,
          method: method,
          compressed: Uint8List.sublistView(
            bytes,
            dataStart,
            dataStart + compressedSize,
          ),
          compressedSize: compressedSize,
          uncompressedSize: uncompressedSize,
        );
      }
      at = dataStart + compressedSize;
    }
    return archive;
  }

  void _add({
    required String name,
    required int method,
    required Uint8List compressed,
    required int compressedSize,
    required int uncompressedSize,
  }) {
    Uint8List data;
    switch (method) {
      case 0:
        data = compressed;
      case 8:
        try {
          data = inflate(
            compressed,
            maxOutputBytes: 128 * 1024 * 1024,
            budget: 'zip_entry',
          );
        } on Object {
          // A single corrupt member should not lose the archive. The raw bytes
          // are kept so a caller that recognises the format can still try.
          data = compressed;
        }
      default:
        unsupportedMethods.add(method);
        data = compressed;
    }
    _entries[name] = ZipEntry(
      name: name,
      compressionMethod: method,
      compressedSize: compressedSize,
      uncompressedSize: uncompressedSize,
      data: data,
    );
  }

  /// Decodes an entry name.
  ///
  /// Bit 11 of the flags says the name is UTF-8. Without it the specification
  /// says code page 437, but every modern writer emits UTF-8 anyway, so UTF-8
  /// is tried first and the byte-per-character reading is the fallback for when
  /// it is genuinely not.
  static String _name(Uint8List bytes, int at, int length, int flags) {
    if (at + length > bytes.length) return '';
    final Uint8List raw = Uint8List.sublistView(bytes, at, at + length);
    if ((flags & 0x800) != 0) return utf8.decode(raw, allowMalformed: true);
    try {
      return utf8.decode(raw);
    } on FormatException {
      return String.fromCharCodes(raw);
    }
  }

  static int _uint16(Uint8List b, int at) =>
      at + 2 > b.length ? 0 : b[at] | (b[at + 1] << 8);

  static int _uint32(Uint8List b, int at) => at + 4 > b.length
      ? 0
      : b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (b[at + 3] << 24);

  @override
  String toString() => 'ZipArchive(${_entries.length} entries, '
      '${usedCentralDirectory ? 'central directory' : 'local headers'})';
}
