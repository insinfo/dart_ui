library;

import 'dart:typed_data';

/// A group of file-name extensions presented by a platform file picker.
final class FilePickerFilter {
  const FilePickerFilter({required this.label, required this.extensions});

  final String label;
  final List<String> extensions;

  /// Browser-compatible accept string, for example `.pdf,.xps`.
  String get accept => extensions
      .where((String value) => value != '*')
      .map((String value) => value.startsWith('.') ? value : '.$value')
      .join(',');

  /// Desktop wildcard pattern, for example `*.pdf;*.xps`.
  String get wildcardPattern => extensions.map((String value) {
        if (value == '*') return '*.*';
        final String normalized = value.startsWith('.') ? value : '.$value';
        return '*$normalized';
      }).join(';');
}

/// A file selected by the user.
///
/// [path] is null in browsers, which intentionally do not expose local paths.
/// Callers consume [bytes] on every platform and therefore need no branch.
final class PickedFile {
  const PickedFile({
    required this.name,
    required this.bytes,
    this.path,
  });

  final String name;
  final String? path;
  final Uint8List bytes;

  int get size => bytes.length;
}

/// A file-picker operation that could not be completed.
final class FilePickerException implements Exception {
  const FilePickerException({
    required this.operation,
    required this.reason,
    this.platform,
    this.errorCode,
  });

  final String operation;
  final String reason;
  final String? platform;
  final int? errorCode;

  @override
  String toString() => 'FilePickerException: $operation failed'
      '${platform == null ? '' : ' on $platform'}'
      '${errorCode == null ? '' : ' (code $errorCode)'} - $reason';
}
