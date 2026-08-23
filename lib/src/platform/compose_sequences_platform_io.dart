library;

import 'dart:io';

import 'compose_sequences.dart';

/// Reads the machine's own Compose table, in X11's own precedence order.
///
/// The order is `libX11`'s and is not negotiable if this framework is to agree
/// with every other application on the desktop:
///
///   1. `$XCOMPOSEFILE`, when it names a readable file;
///   2. `~/.XCompose`, the user's own table;
///   3. `/usr/share/X11/locale/<locale>/Compose`, the locale table, where
///      `<locale>` comes from `$LC_ALL`, `$LC_CTYPE` or `$LANG`.
///
/// The first that exists wins **outright** rather than being merged with the
/// others: a `~/.XCompose` that wants the standard sequences as well says so
/// with `include "%L"`, which is why nearly every one begins with that line and
/// why [ComposeTable.parse] follows includes.
///
/// Returns [ComposeTable.empty] on any platform without these files - Windows,
/// where the OS composes dead keys itself and doing it again here would double
/// every accent, and macOS, whose input methods are a different mechanism
/// entirely.
ComposeTable loadSystemComposeTable({Map<String, String>? environment}) {
  if (!Platform.isLinux) return ComposeTable.empty;
  final Map<String, String> env = environment ?? Platform.environment;
  for (final String path in systemComposeFileCandidates(environment: env)) {
    final String? source = _readFile(path);
    if (source == null) continue;
    return ComposeTable.parse(
      source,
      resolveInclude: (String included) =>
          _readFile(_expandIncludePath(included, env)),
    );
  }
  return ComposeTable.empty;
}

/// The files that would be consulted, in order. Exposed so a diagnostic can
/// say *which* table was read rather than only that one was.
List<String> systemComposeFileCandidates({
  Map<String, String>? environment,
}) {
  final Map<String, String> env = environment ?? Platform.environment;
  final candidates = <String>[];
  final String? explicit = env['XCOMPOSEFILE'];
  if (explicit != null && explicit.isNotEmpty) candidates.add(explicit);
  final String? home = env['HOME'];
  if (home != null && home.isNotEmpty) candidates.add('$home/.XCompose');
  candidates.add(_localeComposePath(env));
  return candidates;
}

/// `%H`, `%L` and `%S`, the three substitutions an `include` may use.
String _expandIncludePath(String path, Map<String, String> environment) {
  if (path.startsWith('%H')) {
    final String home = environment['HOME'] ?? '';
    return '$home${path.substring(2)}';
  }
  if (path.startsWith('%L')) {
    return _localeComposePath(environment) + path.substring(2);
  }
  if (path.startsWith('%S')) {
    return '/usr/share/X11/locale${path.substring(2)}';
  }
  return path;
}

String _localeComposePath(Map<String, String> environment) {
  final String locale = environment['LC_ALL']?.isNotEmpty ?? false
      ? environment['LC_ALL']!
      : environment['LC_CTYPE']?.isNotEmpty ?? false
          ? environment['LC_CTYPE']!
          : environment['LANG'] ?? 'en_US.UTF-8';
  // The directory names under /usr/share/X11/locale spell the charset as
  // `UTF-8`; `.utf8`, which glibc also accepts, has no directory of its own.
  final String normalized =
      locale.replaceAll('.utf8', '.UTF-8').replaceAll('.UTF8', '.UTF-8');
  return '/usr/share/X11/locale/$normalized/Compose';
}

String? _readFile(String path) {
  try {
    final file = File(path);
    if (!file.existsSync()) return null;
    return file.readAsStringSync();
  } on Object {
    // A Compose file that cannot be read is a table that does not exist. There
    // is nothing to report to and nothing a user could do differently.
    return null;
  }
}
