/// ZIP operations on a worker isolate. Extraction always creates a new folder.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

const _maxFile = 64 * 1024 * 1024;
const _maxTotal = 256 * 1024 * 1024;
const _maxZip = 128 * 1024 * 1024;

Future<void> createZip(List<String> paths, String target) =>
    Isolate.run(() => _create(paths, target));
Future<void> extractZip(String path, String target) =>
    Isolate.run(() => _extract(path, target));

Uint8List _readBounded(String path, int limit) {
  final input = File(path).openSync();
  final contents = BytesBuilder(copy: false);
  try {
    while (true) {
      final remaining = limit - contents.length + 1;
      final chunk = input.readSync(remaining < 65536 ? remaining : 65536);
      if (chunk.isEmpty) return contents.takeBytes();
      contents.add(chunk);
      if (contents.length > limit) {
        throw FileSystemException('ZIP input exceeds its size limit', path);
      }
    }
  } finally {
    input.closeSync();
  }
}

final _crcTable = List<int>.generate(256, (n) {
  for (var i = 0; i < 8; i++) {
    n = n & 1 != 0 ? 0xedb88320 ^ (n >> 1) : n >> 1;
  }
  return n;
});
int _crc(List<int> bytes) {
  var crc = 0xffffffff;
  for (final b in bytes) {
    crc = _crcTable[(crc ^ b) & 255] ^ (crc >> 8);
  }
  return crc ^ 0xffffffff;
}

Uint8List _header(int length, Map<int, int> words, Map<int, int> shorts) {
  final b = ByteData(length);
  words.forEach((at, v) => b.setUint32(at, v, Endian.little));
  shorts.forEach((at, v) => b.setUint16(at, v, Endian.little));
  return b.buffer.asUint8List();
}

void _requireFree(String target) {
  if (FileSystemEntity.typeSync(target, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw FileSystemException('Destination already exists', target);
  }
}

void _create(List<String> paths, String target) {
  _requireFree(target);
  final parent = Directory(File(target).parent.path).resolveSymbolicLinksSync();
  for (final source in paths) {
    if (FileSystemEntity.typeSync(source, followLinks: false) ==
        FileSystemEntityType.directory) {
      final root = Directory(source).resolveSymbolicLinksSync();
      if (parent == root ||
          parent.startsWith('$root${Platform.pathSeparator}')) {
        throw const FormatException(
            'Cannot create a ZIP inside a selected folder');
      }
    }
  }
  final staging =
      Directory(File(target).parent.path).createTempSync('.explorer-zip-');
  final file =
      File('${staging.path}/archive.zip').openSync(mode: FileMode.write);
  final central = BytesBuilder();
  var entries = 0;
  var total = 0;
  final names = <String>{};
  try {
    void add(String path, String name) {
      if (++entries > 10000) {
        throw const FormatException('ZIP limit: 10,000 entries');
      }
      final kind = FileSystemEntity.typeSync(path, followLinks: false);
      if (kind != FileSystemEntityType.file &&
          kind != FileSystemEntityType.directory) {
        throw FileSystemException(
            'ZIP does not follow symbolic links or special files', path);
      }
      final directory = kind == FileSystemEntityType.directory;
      if (directory) name = '$name/';
      if (!names.add(name.toLowerCase())) {
        throw FormatException('Duplicate ZIP path: $name');
      }
      final stat = FileStat.statSync(path);
      if (!directory && stat.size > _maxFile) {
        throw const FormatException('ZIP limit: 64 MiB per file');
      }
      final data = directory ? Uint8List(0) : _readBounded(path, _maxFile);
      total += data.length;
      if (total > _maxTotal) {
        throw const FormatException('ZIP limit: 256 MiB of contents');
      }
      final compressed =
          directory ? <int>[] : ZLibEncoder(raw: true).convert(data);
      final encoded = utf8.encode(name);
      if (encoded.length > 65535) {
        throw const FormatException('ZIP path is too long');
      }
      final crc = _crc(data);
      final date = stat.modified;
      final dosDate = ((date.year.clamp(1980, 2107) - 1980) << 9) |
          (date.month << 5) |
          date.day;
      final dosTime =
          (date.hour << 11) | (date.minute << 5) | (date.second >> 1);
      final offset = file.positionSync();
      file.writeFromSync(_header(30, {
        0: 0x04034b50,
        14: crc,
        18: compressed.length,
        22: data.length
      }, {
        4: 20,
        6: 0x800,
        8: directory ? 0 : 8,
        10: dosTime,
        12: dosDate,
        26: encoded.length
      }));
      file.writeFromSync(encoded);
      file.writeFromSync(compressed);
      central.add(_header(46, {
        0: 0x02014b50,
        16: crc,
        20: compressed.length,
        24: data.length,
        38: directory ? 16 : 0,
        42: offset
      }, {
        4: 20,
        6: 20,
        8: 0x800,
        10: directory ? 0 : 8,
        12: dosTime,
        14: dosDate,
        28: encoded.length
      }));
      central.add(encoded);
      if (file.positionSync() > _maxZip) {
        throw const FormatException('ZIP limit: 128 MiB archive');
      }
      if (directory) {
        for (final child in Directory(path).listSync(followLinks: false)) {
          final leaf = child.uri.pathSegments.where((s) => s.isNotEmpty).last;
          add(child.path, '$name$leaf');
        }
      }
    }

    for (final path in paths) {
      final leaf = Uri.file(path, windows: Platform.isWindows)
          .pathSegments
          .where((s) => s.isNotEmpty)
          .last;
      add(path, leaf);
    }
    final offset = file.positionSync();
    final directory = central.takeBytes();
    file.writeFromSync(directory);
    file.writeFromSync(_header(
        22,
        {0: 0x06054b50, 12: directory.length, 16: offset},
        {8: entries, 10: entries}));
    file.closeSync();
    _requireFree(target);
    File('${staging.path}/archive.zip').renameSync(target);
  } finally {
    try {
      file.closeSync();
    } on Object {/* Already closed after success. */}
    staging.deleteSync(recursive: true);
  }
}

final class _BoundedSink implements Sink<List<int>> {
  _BoundedSink(this.limit);
  final int limit;
  final bytes = BytesBuilder();
  int length = 0;
  @override
  void add(List<int> data) {
    length += data.length;
    if (length > limit) {
      throw const FormatException('ZIP expands beyond its declared size');
    }
    bytes.add(data);
  }

  @override
  void close() {}
}

/// Validate every entry before creating files. No overwrites, links, encrypted
/// entries, ZIP64 or unsupported methods are accepted.
void _extract(String path, String target) {
  _requireFree(target);
  final source = File(path);
  if (source.lengthSync() > _maxZip) {
    throw const FormatException('ZIP limit: 128 MiB archive');
  }
  final bytes = _readBounded(path, _maxZip);
  if (bytes.length > _maxZip) {
    throw const FormatException('ZIP input grew beyond 128 MiB');
  }
  final view = ByteData.sublistView(bytes);
  int u16(int at) => view.getUint16(at, Endian.little);
  int u32(int at) => view.getUint32(at, Endian.little);
  var end = -1;
  for (var at = bytes.length - 22;
      at >= 0 && at >= bytes.length - 65557;
      at--) {
    if (u32(at) == 0x06054b50 && at + 22 + u16(at + 20) == bytes.length) {
      end = at;
      break;
    }
  }
  if (end < 0 ||
      u16(end + 4) != 0 ||
      u16(end + 6) != 0 ||
      u16(end + 8) != u16(end + 10)) {
    throw const FormatException('Not a single-volume ZIP archive');
  }
  final count = u16(end + 10);
  if (count == 65535 || count > 10000) {
    throw const FormatException('Unsupported ZIP entry count');
  }
  var at = u32(end + 16);
  if (at + u32(end + 12) != end) {
    throw const FormatException('Invalid ZIP directory');
  }
  final records = <(String, int, int, int, int, int)>[];
  final names = <String>{};
  var total = 0;
  for (var n = 0; n < count; n++) {
    if (at + 46 > end || u32(at) != 0x02014b50) {
      throw const FormatException('Invalid ZIP entry');
    }
    final flags = u16(at + 8),
        method = u16(at + 10),
        crc = u32(at + 16),
        compressed = u32(at + 20),
        size = u32(at + 24),
        local = u32(at + 42);
    final nameLength = u16(at + 28),
        next = at + 46 + nameLength + u16(at + 30) + u16(at + 32);
    if (next > end ||
        flags & 1 != 0 ||
        ![0, 8].contains(method) ||
        ((u32(at + 38) >> 16) & 0xf000) == 0xa000) {
      throw const FormatException('Encrypted, linked or unsupported ZIP entry');
    }
    final name = utf8
        .decode(bytes.sublist(at + 46, at + 46 + nameLength))
        .replaceAll('\\', '/');
    final segments = name.split('/');
    if (name.isEmpty ||
        name.startsWith('/') ||
        segments.any((s) =>
            s == '..' ||
            s == '.' ||
            s.contains(':') ||
            s.contains('\u0000') ||
            s.endsWith(' ') ||
            s.endsWith('.')) ||
        segments.take(segments.length - 1).any((s) => s.isEmpty)) {
      throw const FormatException('Unsafe ZIP path');
    }
    if (!names.add(name.toLowerCase())) {
      throw const FormatException('Duplicate ZIP path');
    }
    total += size;
    if (size > _maxFile || total > _maxTotal || compressed > _maxZip) {
      throw const FormatException('ZIP extraction limit exceeded');
    }
    if (local + 30 > u32(end + 16) ||
        u32(local) != 0x04034b50 ||
        u16(local + 8) != method ||
        u16(local + 6) & 1 != 0) {
      throw const FormatException('Invalid ZIP local header');
    }
    final start = local + 30 + u16(local + 26) + u16(local + 28);
    if (start + compressed > u32(end + 16)) {
      throw const FormatException('ZIP content overlaps directory');
    }
    records.add((name, start, compressed, size, method, crc));
    at = next;
  }
  if (at != end) throw const FormatException('ZIP directory size mismatch');
  final staging = Directory(Directory(target).parent.path)
      .createTempSync('.explorer-extract-');
  try {
    for (final (name, start, compressed, size, method, crc) in records) {
      final output =
          '${staging.path}/${name.replaceAll('/', Platform.pathSeparator)}';
      if (name.endsWith('/')) {
        Directory(output).createSync(recursive: true);
        continue;
      }
      final encoded = Uint8List.sublistView(bytes, start, start + compressed);
      final sink = _BoundedSink(size);
      if (method == 0) {
        sink.add(encoded);
      } else {
        final decoder = ZLibDecoder(raw: true).startChunkedConversion(sink);
        decoder.add(encoded);
        decoder.close();
      }
      final data = sink.bytes.takeBytes();
      if (data.length != size || _crc(data) != crc) {
        throw const FormatException('ZIP CRC or size mismatch');
      }
      File(output).parent.createSync(recursive: true);
      File(output).writeAsBytesSync(data);
    }
    _requireFree(target);
    staging.renameSync(target);
  } finally {
    if (staging.existsSync()) staging.deleteSync(recursive: true);
  }
}
