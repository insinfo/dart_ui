/// The shared vocabulary of [Trash], and the freedesktop bookkeeping that is
/// pure string work.
///
/// The `.trashinfo` format, the percent-encoding its `Path=` key requires and
/// the collision-avoidance naming are all specified text manipulation, so
/// they live here where any machine can test them; the `io` implementation
/// contributes only the file moves.
library;

/// A move-to-trash that did not happen.
final class TrashException implements Exception {
  const TrashException({
    required this.path,
    required this.reason,
    this.platform,
    this.errorCode,
  });

  final String path;
  final String reason;
  final String? platform;
  final int? errorCode;

  @override
  String toString() => 'TrashException: could not trash $path'
      '${platform == null ? '' : ' on $platform'}'
      '${errorCode == null ? '' : ' (code $errorCode)'} - $reason';
}

/// Percent-encodes [path] the way the freedesktop trash spec requires for
/// the `Path=` key: RFC 2396 escaping applied per octet of the UTF-8 form,
/// with `/` kept literal because it is the separator being described.
String encodeTrashPath(String path) {
  const String keep =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
      r"-_.!~*'()/";
  final StringBuffer out = StringBuffer();
  final List<int> bytes = _utf8Bytes(path);
  for (final int byte in bytes) {
    final String char = String.fromCharCode(byte);
    if (byte < 0x80 && keep.contains(char)) {
      out.write(char);
    } else {
      out.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return out.toString();
}

List<int> _utf8Bytes(String value) {
  // Hand-rolled rather than dart:convert so this file stays importable from
  // the narrowest of targets; UTF-8 of a Dart string is a dozen lines.
  final List<int> bytes = <int>[];
  for (final int rune in value.runes) {
    if (rune < 0x80) {
      bytes.add(rune);
    } else if (rune < 0x800) {
      bytes
        ..add(0xC0 | (rune >> 6))
        ..add(0x80 | (rune & 0x3F));
    } else if (rune < 0x10000) {
      bytes
        ..add(0xE0 | (rune >> 12))
        ..add(0x80 | ((rune >> 6) & 0x3F))
        ..add(0x80 | (rune & 0x3F));
    } else {
      bytes
        ..add(0xF0 | (rune >> 18))
        ..add(0x80 | ((rune >> 12) & 0x3F))
        ..add(0x80 | ((rune >> 6) & 0x3F))
        ..add(0x80 | (rune & 0x3F));
    }
  }
  return bytes;
}

/// [moment] as the trash spec's `DeletionDate` value: local time in
/// `YYYY-MM-DDThh:mm:ss`, no zone suffix.
String formatTrashDeletionDate(DateTime moment) {
  final DateTime local = moment.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year.toString().padLeft(4, '0')}-${two(local.month)}-'
      '${two(local.day)}T${two(local.hour)}:${two(local.minute)}:'
      '${two(local.second)}';
}

/// The complete content of a `.trashinfo` file for [originalPath] deleted at
/// [deletedAt].
String buildTrashInfo({
  required String originalPath,
  required DateTime deletedAt,
}) =>
    '[Trash Info]\n'
    'Path=${encodeTrashPath(originalPath)}\n'
    'DeletionDate=${formatTrashDeletionDate(deletedAt)}\n';

/// A name near [name] that [exists] answers false for, counting upward in
/// the style the platform's own trash uses.
///
/// Freedesktop implementations insert a counter before the extension
/// (`report.2.pdf`); the Finder appends one after the stem (`report 2.pdf`).
/// [separator] chooses which: `'.'` produces the former, `' '` the latter.
String disambiguateTrashName(
  String name,
  bool Function(String candidate) exists, {
  String separator = '.',
}) {
  if (!exists(name)) return name;
  final int dot = name.startsWith('.') ? -1 : name.lastIndexOf('.');
  final String stem = dot <= 0 ? name : name.substring(0, dot);
  final String extension = dot <= 0 ? '' : name.substring(dot);
  for (var counter = 2;; counter++) {
    final String candidate = '$stem$separator$counter$extension';
    if (!exists(candidate)) return candidate;
  }
}
