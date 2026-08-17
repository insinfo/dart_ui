library;

import 'dart:convert';
import 'dart:typed_data';

/// A PDF character map used by Type 0/CID fonts and `/ToUnicode` streams.
class PdfCMap {
  PdfCMap({this.cmapName = 'Identity-H'});

  factory PdfCMap.parse(Uint8List bytes, {String cmapName = 'ToUnicode'}) {
    final PdfCMap cmap = PdfCMap(cmapName: cmapName);
    final String source = latin1.decode(bytes, allowInvalid: true);

    for (final RegExpMatch block in RegExp(
      r'begincodespacerange([\s\S]*?)endcodespacerange',
    ).allMatches(source)) {
      for (final RegExpMatch pair in RegExp(
        r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>',
      ).allMatches(block.group(1)!)) {
        cmap._sourceByteLengths.add(pair.group(1)!.length ~/ 2);
      }
    }

    for (final RegExpMatch block in RegExp(
      r'beginbfchar([\s\S]*?)endbfchar',
    ).allMatches(source)) {
      for (final RegExpMatch pair in RegExp(
        r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>',
      ).allMatches(block.group(1)!)) {
        cmap.addBfText(
          _hexInt(pair.group(1)!),
          _unicodeHex(pair.group(2)!),
          sourceBytes: pair.group(1)!.length ~/ 2,
        );
      }
    }

    for (final RegExpMatch block in RegExp(
      r'beginbfrange([\s\S]*?)endbfrange',
    ).allMatches(source)) {
      final String body = block.group(1)!;
      for (final String line in const LineSplitter().convert(body)) {
        final RegExpMatch? range = RegExp(
          r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*(.*)',
        ).firstMatch(line);
        if (range == null) continue;
        final int start = _hexInt(range.group(1)!);
        final int end = _hexInt(range.group(2)!);
        final int sourceBytes = range.group(1)!.length ~/ 2;
        final String destination = range.group(3)!.trim();
        if (destination.startsWith('[')) {
          final List<RegExpMatch> values =
              RegExp(r'<([0-9A-Fa-f]+)>').allMatches(destination).toList();
          for (var code = start; code <= end; code++) {
            final int index = code - start;
            if (index >= values.length) break;
            cmap.addBfText(
              code,
              _unicodeHex(values[index].group(1)!),
              sourceBytes: sourceBytes,
            );
          }
          continue;
        }
        final RegExpMatch? first =
            RegExp(r'^<([0-9A-Fa-f]+)>').firstMatch(destination);
        if (first == null) continue;
        final String initial = _unicodeHex(first.group(1)!);
        final List<int> runes = initial.runes.toList();
        if (runes.length == 1) {
          cmap.addBfRange(start, end, runes.single, sourceBytes: sourceBytes);
        } else {
          for (var code = start; code <= end; code++) {
            cmap.addBfText(code, initial, sourceBytes: sourceBytes);
          }
        }
      }
    }
    return cmap;
  }

  final String cmapName;
  final Map<int, String> _cidToText = <int, String>{};
  final List<_CMapRange> _ranges = <_CMapRange>[];
  final Set<int> _sourceByteLengths = <int>{};

  /// Adds one `bfchar` mapping.
  void addBfChar(int srcCode, int dstUnicode) =>
      addBfText(srcCode, String.fromCharCode(dstUnicode));

  void addBfText(int srcCode, String text, {int? sourceBytes}) {
    _cidToText[srcCode] = text;
    if (sourceBytes != null) _sourceByteLengths.add(sourceBytes);
  }

  /// Adds a sequential `bfrange` mapping.
  void addBfRange(
    int srcStart,
    int srcEnd,
    int dstStart, {
    int? sourceBytes,
  }) {
    _ranges.add(_CMapRange(srcStart, srcEnd, dstStart));
    if (sourceBytes != null) _sourceByteLengths.add(sourceBytes);
  }

  String? getText(int cid) {
    final String? exact = _cidToText[cid];
    if (exact != null) return exact;
    for (final _CMapRange range in _ranges) {
      if (cid >= range.srcStart && cid <= range.srcEnd) {
        return String.fromCharCode(range.dstStart + cid - range.srcStart);
      }
    }
    return null;
  }

  int? getUnicode(int cid) => getText(cid)?.runes.firstOrNull;

  /// Decodes a PDF string using the declared code-space widths.
  String decode(Uint8List bytes, {int fallbackCodeBytes = 1}) {
    final List<int> widths = _sourceByteLengths.isEmpty
        ? <int>[fallbackCodeBytes]
        : (_sourceByteLengths.toList()..sort((int a, int b) => b - a));
    final StringBuffer result = StringBuffer();
    var offset = 0;
    while (offset < bytes.length) {
      String? mapped;
      int consumed = 0;
      int fallbackCode = bytes[offset];
      for (final int width in widths) {
        if (offset + width > bytes.length) continue;
        var code = 0;
        for (var i = 0; i < width; i++) {
          code = (code << 8) | bytes[offset + i];
        }
        fallbackCode = code;
        final String? candidate = getText(code);
        if (candidate != null) {
          mapped = candidate;
          consumed = width;
          break;
        }
      }
      consumed = consumed == 0
          ? widths.last.clamp(1, bytes.length - offset)
          : consumed;
      result.write(mapped ?? _safeCodePoint(fallbackCode));
      offset += consumed;
    }
    return result.toString();
  }
}

final class _CMapRange {
  const _CMapRange(this.srcStart, this.srcEnd, this.dstStart);

  final int srcStart;
  final int srcEnd;
  final int dstStart;
}

int _hexInt(String value) => int.parse(value, radix: 16);

String _unicodeHex(String value) {
  String normalized = value.length.isOdd ? '0$value' : value;
  if (normalized.length == 2) normalized = '00$normalized';
  final List<int> units = <int>[];
  for (var i = 0; i + 3 < normalized.length; i += 4) {
    units.add(int.parse(normalized.substring(i, i + 4), radix: 16));
  }
  return String.fromCharCodes(units);
}

String _safeCodePoint(int value) =>
    String.fromCharCode(value >= 0 && value <= 0x10FFFF ? value : 0xFFFD);

extension on Iterable<int> {
  int? get firstOrNull {
    final Iterator<int> iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
