library;

/// The local-display subset deliberately shared by all three POC clients.
final class X11DisplayTarget {
  const X11DisplayTarget._({
    required this.original,
    required this.displayNumber,
    required this.screenNumber,
  });

  factory X11DisplayTarget.parse(String value) {
    final match = RegExp(r'^(?:([^:]*):)?([0-9]+)(?:\.([0-9]+))?$')
        .firstMatch(value.trim());
    if (match == null) {
      throw FormatException('unsupported DISPLAY syntax', value);
    }
    final host = match.group(1) ?? '';
    if (host.isNotEmpty && host != 'unix' && !host.endsWith('/unix')) {
      throw UnsupportedError(
        'POC-21 intentionally compares local Unix-domain transports; '
        'DISPLAY host "$host" would require a TCP benchmark.',
      );
    }
    return X11DisplayTarget._(
      original: value,
      displayNumber: int.parse(match.group(2)!),
      screenNumber: int.parse(match.group(3) ?? '0'),
    );
  }

  final String original;
  final int displayNumber;
  final int screenNumber;

  String get unixSocketPath => '/tmp/.X11-unix/X$displayNumber';

  @override
  String toString() => '$original ($unixSocketPath, screen $screenNumber)';
}
