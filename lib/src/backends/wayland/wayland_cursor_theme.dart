/// Finding the user's cursor theme on disk, and naming its cursors.
///
/// Two problems, both of which the freedesktop icon-theme spec answers and
/// neither of which Wayland does:
///
///   * **Where the theme lives.** `XCURSOR_PATH` when set, otherwise
///     `$XDG_DATA_HOME/icons`, `~/.icons`, `~/.local/share/icons` and the
///     system directories, each holding `<theme>/cursors/<name>`.
///   * **What the cursor is called.** The framework asks for
///     [SystemCursor.text]; a theme calls it `xterm`, or `ibeam`, or
///     `text`, depending on its age and origin. Every candidate is tried in
///     order, which is what a cursor library does and what makes the same
///     [SystemCursor] work on Adwaita, Breeze and a decade-old X11 theme.
///
/// The filesystem is injected so the whole resolution is testable on a host
/// with no themes at all - which is every Windows CI machine this repository
/// runs on.
library;

import '../../platform/native_window.dart';

/// The names one [SystemCursor] can appear under, most standard first.
///
/// Drawn from the X11 cursor font names, the CSS names modern themes ship, and
/// the freedesktop cursor-name conventions. A theme that has none of them
/// leaves that cursor unavailable, which the caller reports rather than
/// silently drawing an arrow.
const Map<SystemCursor, List<String>> waylandCursorNames =
    <SystemCursor, List<String>>{
  SystemCursor.arrow: <String>['default', 'left_ptr', 'arrow', 'top_left_arrow'],
  SystemCursor.text: <String>['text', 'xterm', 'ibeam'],
  SystemCursor.hand: <String>['pointer', 'hand2', 'hand1', 'pointing_hand'],
  SystemCursor.resizeHorizontal: <String>[
    'ew-resize',
    'sb_h_double_arrow',
    'h_double_arrow',
    'col-resize',
  ],
  SystemCursor.resizeVertical: <String>[
    'ns-resize',
    'sb_v_double_arrow',
    'v_double_arrow',
    'row-resize',
  ],
  SystemCursor.resizeDiagonalDown: <String>[
    'nwse-resize',
    'size_fdiag',
    'bottom_right_corner',
    'top_left_corner',
  ],
  SystemCursor.resizeDiagonalUp: <String>[
    'nesw-resize',
    'size_bdiag',
    'bottom_left_corner',
    'top_right_corner',
  ],
  SystemCursor.wait: <String>['wait', 'watch', 'progress'],
  SystemCursor.crosshair: <String>['crosshair', 'cross', 'tcross'],
  SystemCursor.notAllowed: <String>[
    'not-allowed',
    'no-drop',
    'forbidden',
    'crossed_circle',
  ],
};

/// The parts of a filesystem this resolver needs, so tests need no disk.
abstract interface class CursorFileSystem {
  bool fileExists(String path);

  /// The file's bytes, or null when it could not be read.
  List<int>? readFile(String path);
}

/// The theme and size the environment asked for, and where to look.
final class WaylandCursorThemeResolution {
  const WaylandCursorThemeResolution({
    required this.themeName,
    required this.size,
    required this.searchPaths,
  });

  /// `XCURSOR_THEME`, or the freedesktop default when unset.
  final String themeName;

  /// `XCURSOR_SIZE`, or 24 - the size almost every desktop ships with.
  final int size;

  /// Directories holding theme folders, in priority order.
  final List<String> searchPaths;

  @override
  String toString() => 'WaylandCursorThemeResolution($themeName @ $size, '
      '${searchPaths.length} search paths)';
}

/// Reads the theme name, size and search path out of [environment].
///
/// No filesystem access: this is the "what was asked for" half, kept separate
/// from "what exists" so a diagnostic can report both.
WaylandCursorThemeResolution resolveWaylandCursorTheme(
  Map<String, String> environment,
) {
  String? read(String name) {
    final value = environment[name];
    if (value == null || value.trim().isEmpty) return null;
    return value.trim();
  }

  final theme = read('XCURSOR_THEME') ?? 'default';
  final size = int.tryParse(read('XCURSOR_SIZE') ?? '') ?? 24;
  final home = read('HOME');

  final paths = <String>[];
  void add(String path) {
    if (path.isEmpty || paths.contains(path)) return;
    paths.add(path);
  }

  // XCURSOR_PATH overrides everything, exactly as libXcursor treats it.
  final explicit = read('XCURSOR_PATH');
  if (explicit != null) {
    for (final entry in explicit.split(':')) {
      if (entry.trim().isNotEmpty) add(entry.trim());
    }
    return WaylandCursorThemeResolution(
      themeName: theme,
      size: size < 1 ? 24 : size,
      searchPaths: List<String>.unmodifiable(paths),
    );
  }

  final dataHome = read('XDG_DATA_HOME');
  if (dataHome != null) {
    add('$dataHome/icons');
  } else if (home != null) {
    add('$home/.local/share/icons');
  }
  if (home != null) add('$home/.icons');
  final dataDirs = read('XDG_DATA_DIRS');
  if (dataDirs != null) {
    for (final entry in dataDirs.split(':')) {
      if (entry.trim().isNotEmpty) add('${entry.trim()}/icons');
    }
  }
  add('/usr/share/icons');
  add('/usr/local/share/icons');
  add('/usr/share/pixmaps');

  return WaylandCursorThemeResolution(
    themeName: theme,
    size: size < 1 ? 24 : size,
    searchPaths: List<String>.unmodifiable(paths),
  );
}

/// Locates the file for one cursor, trying every name a theme may use.
///
/// Returns null when no candidate exists anywhere on the path, which is a
/// perfectly ordinary answer: `not-allowed` is missing from plenty of themes.
/// The caller then falls back to the arrow, or to no cursor at all, and says
/// which happened.
String? findWaylandCursorFile({
  required CursorFileSystem fileSystem,
  required WaylandCursorThemeResolution resolution,
  required SystemCursor cursor,
  List<String> extraThemes = const <String>['Adwaita', 'default'],
}) {
  final names = waylandCursorNames[cursor] ?? const <String>[];
  final themes = <String>[
    resolution.themeName,
    // The inherit chain is not parsed (that needs index.theme); the two
    // themes every distribution ships stand in for it, which is the
    // documented limitation.
    ...extraThemes.where((String t) => t != resolution.themeName),
  ];
  for (final theme in themes) {
    for (final directory in resolution.searchPaths) {
      for (final name in names) {
        final path = '$directory/$theme/cursors/$name';
        if (fileSystem.fileExists(path)) return path;
      }
    }
  }
  return null;
}
