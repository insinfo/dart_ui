/// The shared vocabulary of [StandardPaths]: which folders exist, how a
/// failure is reported, and the XDG parsing that is pure string work.
///
/// The parsing lives here rather than in the `io` implementation because it
/// has no `dart:io` in it at all: `~/.config/user-dirs.dirs` is a text format,
/// and a text format is testable on any platform, including the Windows
/// machine this framework is developed on. The `io` file feeds it real file
/// contents; a test feeds it strings.
library;

/// A well-known directory the operating system names for the current user.
enum StandardFolder {
  /// The user's home directory - `%USERPROFILE%`, `$HOME`.
  home,

  /// Documents.
  documents,

  /// Downloads.
  downloads,

  /// Pictures.
  pictures,

  /// Music.
  music,

  /// Videos - `Movies` on macOS, which is a naming difference and not a
  /// semantic one.
  videos,

  /// The desktop directory.
  desktop,

  /// Where an application stores per-user configuration and data that should
  /// follow the user: `%APPDATA%` (Roaming) on Windows, `$XDG_CONFIG_HOME`
  /// (default `~/.config`) on Linux, `~/Library/Application Support` on
  /// macOS. Callers append their own application name.
  appData,

  /// Per-user data that stays on this machine: `%LOCALAPPDATA%` on Windows,
  /// `$XDG_DATA_HOME` (default `~/.local/share`) on Linux, and the same
  /// `~/Library/Application Support` on macOS, which draws no such
  /// distinction.
  appDataLocal,

  /// Where an application caches things it can regenerate: `%LOCALAPPDATA%`
  /// on Windows (the platform has no dedicated cache root),
  /// `$XDG_CACHE_HOME` (default `~/.cache`) on Linux, `~/Library/Caches` on
  /// macOS. Callers append their own application name.
  cache,

  /// The system temporary directory.
  temp,

  /// The running executable itself - `Platform.resolvedExecutable` - so a
  /// program can find files shipped next to it.
  executable,
}

/// A standard-path lookup that could not be answered.
final class StandardPathsException implements Exception {
  const StandardPathsException({
    required this.folder,
    required this.reason,
    this.platform,
    this.errorCode,
  });

  final StandardFolder folder;
  final String reason;
  final String? platform;
  final int? errorCode;

  @override
  String toString() => 'StandardPathsException: ${folder.name} unavailable'
      '${platform == null ? '' : ' on $platform'}'
      '${errorCode == null ? '' : ' (code $errorCode)'} - $reason';
}

/// Parses the body of `~/.config/user-dirs.dirs` into folder assignments.
///
/// The format is fixed by xdg-user-dirs: shell-like assignments of the form
/// `XDG_DOWNLOAD_DIR="$HOME/Downloads"`, where the value is always quoted and
/// either starts with `$HOME/` or is an absolute path. Anything else in the
/// file - comments, blank lines, malformed lines - is skipped rather than
/// rejected, because this is a best-effort configuration file that desktop
/// environments rewrite and users hand-edit.
///
/// Returns a map from the `XDG_*_DIR` key to the *expanded* absolute path.
/// A value that expands to [home] itself means the user disabled that folder
/// (that is the convention xdg-user-dirs documents), and is omitted.
Map<String, String> parseXdgUserDirs(String content, {required String home}) {
  final Map<String, String> result = <String, String>{};
  final RegExp assignment =
      RegExp(r'^\s*(XDG_[A-Z]+_DIR)\s*=\s*"([^"]*)"\s*$');
  for (final String line in content.split('\n')) {
    final RegExpMatch? match = assignment.firstMatch(line);
    if (match == null) continue;
    final String key = match.group(1)!;
    String value = match.group(2)!;
    if (value.startsWith(r'$HOME/')) {
      value = '$home/${value.substring(6)}';
    } else if (value == r'$HOME' || value == r'$HOME/') {
      value = home;
    } else if (!value.startsWith('/')) {
      // Neither $HOME-relative nor absolute: not a shape the spec allows.
      continue;
    }
    // Strip a trailing slash so callers compare and join uniformly.
    if (value.length > 1 && value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    if (value == home) continue; // Disabled by the user, per the convention.
    result[key] = value;
  }
  return result;
}

/// The `XDG_*_DIR` key for [folder], or null for folders the user-dirs file
/// does not describe.
String? xdgUserDirKey(StandardFolder folder) => switch (folder) {
      StandardFolder.documents => 'XDG_DOCUMENTS_DIR',
      StandardFolder.downloads => 'XDG_DOWNLOAD_DIR',
      StandardFolder.pictures => 'XDG_PICTURES_DIR',
      StandardFolder.music => 'XDG_MUSIC_DIR',
      StandardFolder.videos => 'XDG_VIDEOS_DIR',
      StandardFolder.desktop => 'XDG_DESKTOP_DIR',
      _ => null,
    };
