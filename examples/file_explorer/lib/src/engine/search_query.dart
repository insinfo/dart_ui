/// A portable name/property query, independent of Windows Search indexing.
library;

import 'file_system.dart';
import 'file_types.dart';

final class SearchQuery {
  SearchQuery(String query) : _groups = _parse(query);
  final List<List<bool Function(FileEntry)>> _groups;

  bool matches(FileEntry entry) =>
      _groups.any((terms) => terms.every((term) => term(entry)));

  static List<List<bool Function(FileEntry)>> _parse(String query) {
    if (query.codeUnits.where((c) => c == 34).length.isOdd) {
      throw const FormatException('Unterminated quoted search');
    }
    final groups = <List<bool Function(FileEntry)>>[[]];
    var negateNext = false;
    for (final match in RegExp(r'(?:[^\s"]|"[^"]*")+').allMatches(query)) {
      var token = match.group(0)!;
      if (token.toUpperCase() == 'OR') {
        if (groups.last.isEmpty) {
          throw const FormatException('Missing term before OR');
        }
        groups.add([]);
        continue;
      }
      if (token.toUpperCase() == 'AND') continue;
      if (token.toUpperCase() == 'NOT') {
        negateNext = true;
        continue;
      }
      final negative = negateNext || token.startsWith('-');
      negateNext = false;
      if (token.startsWith('-')) token = token.substring(1);
      token = token.replaceAll('"', '');
      final split = token.indexOf(':');
      final key = split > 0 ? token.substring(0, split).toLowerCase() : 'name';
      final value = split > 0 ? token.substring(split + 1) : token;
      final term = _term(key, value);
      groups.last.add(negative ? (e) => !term(e) : term);
    }
    if (negateNext || groups.last.isEmpty) {
      throw const FormatException('Incomplete search');
    }
    return groups;
  }

  static bool Function(FileEntry) _term(String key, String value) {
    final text = value.toLowerCase();
    switch (key) {
      case 'name':
        if (text.contains('*') || text.contains('?')) {
          final pattern = RegExp(
              '^${text.split('').map((c) => c == '*' ? '.*' : c == '?' ? '.' : RegExp.escape(c)).join()}\$',
              caseSensitive: false);
          return (e) => pattern.hasMatch(e.name);
        }
        return (e) => e.name.toLowerCase().contains(text);
      case 'ext':
        final extension = text.replaceFirst(RegExp(r'^\*?\.'), '');
        return (e) => e.extension == extension;
      case 'kind':
        const kinds = {
          'folder',
          'file',
          'image',
          'document',
          'audio',
          'video',
          'archive'
        };
        if (!kinds.contains(text)) {
          throw FormatException('Unknown kind: $value');
        }
        return (e) => switch (text) {
              'folder' => e.isDirectory,
              'file' => !e.isDirectory,
              'image' => kindOf(e) == FileKind.image,
              'audio' => kindOf(e) == FileKind.audio,
              'video' => kindOf(e) == FileKind.video,
              'archive' => kindOf(e) == FileKind.archive,
              _ => !e.isDirectory &&
                  {'txt', 'md', 'pdf', 'doc', 'docx', 'odt', 'rtf'}
                      .contains(e.extension),
            };
      case 'size':
        final parts = RegExp(
                r'^(>=|<=|>|<|=)?(\d+(?:\.\d+)?)(b|kb|mb|gb|kib|mib|gib)?$',
                caseSensitive: false)
            .firstMatch(value);
        if (parts == null) throw FormatException('Invalid size: $value');
        final unit = parts.group(3)?.toLowerCase() ?? 'b';
        final factor = switch (unit) {
          'kb' => 1000,
          'mb' => 1000000,
          'gb' => 1000000000,
          'kib' => 1024,
          'mib' => 1048576,
          'gib' => 1073741824,
          _ => 1
        };
        final bytes = double.parse(parts.group(2)!) * factor;
        return (e) =>
            !e.isDirectory &&
            e.size != null &&
            _compare(e.size!, bytes, parts.group(1) ?? '=');
      case 'modified':
      case 'created':
        final parts =
            RegExp(r'^(>=|<=|>|<|=)?(\d{4}-\d{2}-\d{2})$').firstMatch(value);
        if (parts == null) throw FormatException('Use an ISO date: $value');
        final date = DateTime.tryParse(parts.group(2)!);
        if (date == null ||
            date.toIso8601String().substring(0, 10) != parts.group(2)) {
          throw FormatException('Invalid date: $value');
        }
        return (e) {
          final stamp = key == 'modified' ? e.modified : e.created;
          if (stamp == null) return false;
          final day = DateTime(stamp.year, stamp.month, stamp.day);
          return _compare(day.millisecondsSinceEpoch,
              date.millisecondsSinceEpoch, parts.group(1) ?? '=');
        };
      default:
        throw FormatException('Unknown search filter: $key');
    }
  }

  static bool _compare(num a, num b, String op) => switch (op) {
        '>' => a > b,
        '<' => a < b,
        '>=' => a >= b,
        '<=' => a <= b,
        _ => a == b,
      };
}
