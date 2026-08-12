/// Finding the fonts already installed on the machine.
///
/// A UI framework cannot ship a font. Fonts are separately licensed - the ones
/// on a Windows machine are proprietary and cannot be redistributed - and even
/// where licensing allows it, bundling one means shipping megabytes to draw
/// text in a face the user did not choose. So the framework finds what is
/// installed.
///
/// This deliberately does **not** use DirectWrite, fontconfig or Core Text.
/// Each of those is a native dependency with its own initialisation, its own
/// failure modes and its own per-platform API, in exchange for a list of file
/// paths that a directory listing already provides. Reading the `name` table
/// out of the files themselves is one code path for all three platforms, needs
/// nothing installed, and is testable on any machine with a fonts folder.
///
/// What this file returns is **paths and bytes**, never parsed faces. That is
/// what keeps it in the platform layer: it knows about directories and
/// operating systems, and nothing about OpenType.
library;

import 'dart:io';
import 'dart:typed_data';

/// A font file found on this machine.
final class SystemFontFile {
  const SystemFontFile({required this.path, required this.fileName});

  final String path;

  /// The file's own name, which is the only thing known about a font before
  /// its `name` table is read. Useful for the heuristics below and useless for
  /// anything else - a file called `arial.ttf` is not required to contain
  /// Arial.
  final String fileName;

  /// Whether this looks like a font collection, which holds several faces.
  bool get isCollection =>
      fileName.toLowerCase().endsWith('.ttc') ||
      fileName.toLowerCase().endsWith('.otc');

  Uint8List readBytes() => File(path).readAsBytesSync();

  @override
  String toString() => 'SystemFontFile($fileName)';
}

/// Enumerates installed font files.
final class SystemFonts {
  const SystemFonts();

  /// Extensions worth opening. `.fon` and `.pfb` are bitmap and Type 1 fonts
  /// that this framework cannot parse, so listing them would only produce
  /// failures later.
  static const Set<String> _extensions = <String>{
    '.ttf',
    '.otf',
    '.ttc',
    '.otc',
  };

  /// The directories this platform keeps fonts in, most specific first.
  ///
  /// User directories come before system ones so that a font the user
  /// installed shadows a system font of the same name, which is what every
  /// platform's own resolution does.
  static List<String> fontDirectories() {
    final Map<String, String> env = Platform.environment;
    if (Platform.isWindows) {
      return <String>[
        if (env['LOCALAPPDATA'] != null)
          '${env['LOCALAPPDATA']}\\Microsoft\\Windows\\Fonts',
        '${env['WINDIR'] ?? 'C:\\Windows'}\\Fonts',
      ];
    }
    if (Platform.isMacOS) {
      final String? home = env['HOME'];
      return <String>[
        if (home != null) '$home/Library/Fonts',
        '/Library/Fonts',
        // Since Catalina most system faces live here rather than in Fonts
        // itself, and they are overwhelmingly .ttc collections.
        '/System/Library/Fonts/Supplemental',
        '/System/Library/Fonts',
      ];
    }
    final String? home = env['HOME'];
    return <String>[
      if (home != null) '$home/.local/share/fonts',
      if (home != null) '$home/.fonts',
      '/usr/local/share/fonts',
      '/usr/share/fonts',
    ];
  }

  /// Every font file found, in directory precedence order.
  ///
  /// Never throws: a directory that does not exist, or that this process may
  /// not read, is skipped. Font enumeration failing should degrade text, not
  /// prevent an application from starting.
  List<SystemFontFile> list({int maxFiles = 4096}) {
    final List<SystemFontFile> found = <SystemFontFile>[];
    for (final String directory in fontDirectories()) {
      if (found.length >= maxFiles) break;
      _collect(Directory(directory), found, maxFiles);
    }
    return found;
  }

  void _collect(Directory directory, List<SystemFontFile> into, int maxFiles) {
    if (!directory.existsSync()) return;
    final List<FileSystemEntity> entries;
    try {
      // Recursive because Linux distributions nest by foundry and by family,
      // and macOS nests too. Windows does not, and pays nothing for it.
      entries = directory.listSync(recursive: true, followLinks: false);
    } on FileSystemException {
      return; // Unreadable directory: skip it rather than fail enumeration.
    }
    for (final FileSystemEntity entry in entries) {
      if (into.length >= maxFiles) return;
      if (entry is! File) continue;
      final String name = entry.path.split(Platform.pathSeparator).last;
      final int dot = name.lastIndexOf('.');
      if (dot < 0) continue;
      if (!_extensions.contains(name.substring(dot).toLowerCase())) continue;
      into.add(SystemFontFile(path: entry.path, fileName: name));
    }
  }

  /// The first font file whose name matches one of [preferred], or any font.
  ///
  /// Matching is on the *file* name, which is a heuristic and is marked as one:
  /// the authoritative family name lives in the font's `name` table, and a
  /// caller that needs the real name parses the file. This exists so that a
  /// framework with no font configured can still draw something legible on
  /// each platform rather than nothing at all.
  SystemFontFile? findPreferred({List<String>? preferred}) {
    final List<SystemFontFile> files = list();
    if (files.isEmpty) return null;

    final List<String> wanted = preferred ?? defaultUiFontNames();
    for (final String candidate in wanted) {
      final String needle = candidate.toLowerCase();
      for (final SystemFontFile file in files) {
        // Collections are skipped here: picking a face out of one needs the
        // caller to choose an index, and a default should not make that choice
        // silently.
        if (file.isCollection) continue;
        if (file.fileName.toLowerCase() == needle) return file;
      }
    }
    for (final SystemFontFile file in files) {
      if (!file.isCollection) return file;
    }
    return null;
  }

  /// File names of each platform's usual interface font, best first.
  ///
  /// These are the faces the platform itself draws its own UI in, so text
  /// rendered with them looks native by default. They are also all
  /// TrueType-outline fonts, which is what the parser reads today.
  static List<String> defaultUiFontNames() {
    if (Platform.isWindows) {
      return <String>['segoeui.ttf', 'tahoma.ttf', 'arial.ttf', 'verdana.ttf'];
    }
    if (Platform.isMacOS) {
      return <String>['SFNSText.ttf', 'Helvetica.ttf', 'Geneva.ttf'];
    }
    return <String>[
      'DejaVuSans.ttf',
      'LiberationSans-Regular.ttf',
      'NotoSans-Regular.ttf',
      'Ubuntu-R.ttf',
    ];
  }
}
