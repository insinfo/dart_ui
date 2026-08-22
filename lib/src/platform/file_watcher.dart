/// Watching the filesystem for changes, as a thin, named wrapper.
///
/// The Dart VM already binds the three real notification APIs -
/// `ReadDirectoryChangesW` on Windows, inotify on Linux, FSEvents on macOS -
/// behind `Directory.watch` and `File.watch`, and re-implementing any of them
/// over FFI would duplicate exactly the code the VM maintains. So this port
/// adds only what `dart:io` leaves out: a framework-stable vocabulary
/// ([FileChange], [FileChangeKind]) that does not name `dart:io` types in
/// callers, an existence check that fails eagerly with a reason instead of a
/// stream error later, and a stub for targets with no filesystem at all.
///
/// The known platform limits pass through untouched, because hiding them
/// would be lying about delivery guarantees: Linux inotify is per-directory
/// unless [FileWatcher.watch] is asked for `recursive`, which the VM there
/// implements by walking and watching subdirectories; macOS FSEvents may
/// coalesce rapid changes into fewer events; and everywhere a watched path
/// that is deleted ends the stream.
library;

import 'file_watcher_platform_stub.dart'
    if (dart.library.io) 'file_watcher_platform_io.dart' as platform;

/// What happened to a watched path.
enum FileChangeKind { create, modify, delete, move }

/// One filesystem change, in framework vocabulary.
final class FileChange {
  const FileChange({
    required this.path,
    required this.kind,
    this.destination,
  });

  /// The path the event is about. For [FileChangeKind.move], the source.
  final String path;

  final FileChangeKind kind;

  /// Where a [FileChangeKind.move] moved to, when the platform says (Windows
  /// pairs rename events; Linux may not).
  final String? destination;

  @override
  String toString() => 'FileChange(${kind.name}: $path'
      '${destination == null ? '' : ' -> $destination'})';
}

/// A watch that could not be established.
final class FileWatcherException implements Exception {
  const FileWatcherException({required this.path, required this.reason});

  final String path;
  final String reason;

  @override
  String toString() => 'FileWatcherException: cannot watch $path - $reason';
}

/// Filesystem change notifications for files and directories.
abstract final class FileWatcher {
  /// Whether this platform delivers filesystem events at all.
  static bool get isSupported => platform.isSupported();

  /// A broadcast stream of changes under [path], which must exist and may be
  /// a file or a directory.
  ///
  /// [recursive] extends a directory watch to everything below it and is
  /// meaningless for a file. The stream ends when the watched path is
  /// deleted; errors surface as stream errors.
  static Stream<FileChange> watch(String path, {bool recursive = false}) =>
      platform.watch(path, recursive: recursive);
}
