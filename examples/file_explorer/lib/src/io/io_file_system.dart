/// The disk, through `dart:io` and the framework's shell, trash and watcher
/// - the adapter the window runs the engine on.
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_ui/dart_ui.dart' show FileWatcher, Shell, Trash;

import '../engine/file_system.dart';

/// [FileSystem] on the machine's own disks.
final class IoFileSystem implements FileSystem {
  IoFileSystem();

  static final bool _windows = Platform.isWindows;

  @override
  String get separator => _windows ? r'\' : '/';

  @override
  bool get caseInsensitive => _windows || Platform.isMacOS;

  /// Whether [path] is a root: `/`, or a drive such as `C:\`.
  bool _isRoot(String path) =>
      path == '/' || (_windows && RegExp(r'^[A-Za-z]:\\?$').hasMatch(path));

  String _normal(String path) {
    if (_isRoot(path)) return _windows ? '${path.substring(0, 2)}\\' : '/';
    final String sep = separator;
    return path.length > 1 && path.endsWith(sep)
        ? path.substring(0, path.length - 1)
        : path;
  }

  @override
  String join(String directory, String name) {
    final String dir = _normal(directory);
    return dir.endsWith(separator) ? '$dir$name' : '$dir$separator$name';
  }

  @override
  String? parentOf(String path) {
    final String p = _normal(path);
    if (_isRoot(p)) return null;
    final int slash = p.lastIndexOf(separator);
    if (slash < 0) return null;
    final String parent = p.substring(0, slash);
    if (parent.isEmpty) return '/';
    return _isRoot(parent) ? _normal(parent) : parent;
  }

  @override
  String nameOf(String path) {
    final String p = _normal(path);
    if (_isRoot(p)) return p;
    return p.substring(p.lastIndexOf(separator) + 1);
  }

  @override
  List<String> ancestry(String path) {
    final List<String> out = <String>[];
    for (String? p = _normal(path); p != null; p = parentOf(p)) {
      out.insert(0, p);
    }
    return out;
  }

  Future<FileEntry?> _entryOf(FileSystemEntity entity) async {
    try {
      final FileStat stat = await entity.stat();
      if (stat.type == FileSystemEntityType.notFound) return null;
      final String name = nameOf(entity.path);
      final bool folder = stat.type == FileSystemEntityType.directory;
      return FileEntry(
        path: entity.path,
        name: name,
        isDirectory: folder,
        size: folder ? null : stat.size,
        modified: stat.modified,
        created: stat.changed,
        isHidden:
            name.startsWith('.') || kSystemNames.contains(name.toLowerCase()),
        isSystem: kSystemNames.contains(name.toLowerCase()),
      );
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<List<FileEntry>> list(String directory) async {
    final List<FileSystemEntity> found;
    try {
      found = await Directory(directory).list(followLinks: false).toList();
    } on FileSystemException catch (error) {
      throw FileSystemError(error.osError?.message ?? error.message, directory);
    }
    final List<FileEntry?> entries = await Future.wait(
        <Future<FileEntry?>>[for (final e in found) _entryOf(e)]);
    return <FileEntry>[
      for (final FileEntry? entry in entries)
        if (entry != null) entry,
    ];
  }

  @override
  Future<FileEntry?> stat(String path) => _entryOf(
      FileSystemEntity.isDirectorySync(path) ? Directory(path) : File(path));

  Future<T> _guard<T>(String path, Future<T> Function() run) async {
    try {
      return await run();
    } on FileSystemException catch (error) {
      throw FileSystemError(error.osError?.message ?? error.message, path);
    }
  }

  Future<void> _requireFree(String path) async {
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw FileSystemError('An item with this name already exists', path);
    }
  }

  @override
  Future<void> createFolder(String path) => _guard(path, () async {
        await _requireFree(path);
        await Directory(path).create();
      });

  @override
  Future<void> createFile(String path) => _guard(path, () async {
        await _requireFree(path);
        await File(path).create(exclusive: true);
      });

  @override
  Future<String> rename(String path, String newName) => _guard(path, () async {
        if (newName.trim().isEmpty ||
            newName.contains('/') ||
            (_windows && RegExp(r'[\\:*?"<>|]').hasMatch(newName))) {
          throw FileSystemError('A file name cannot contain that', newName);
        }
        final String target = join(parentOf(path)!, newName);
        if (target == path) return path;
        // A change of case only is a rename on a case-insensitive disk, not
        // a collision with itself.
        if (target.toLowerCase() != path.toLowerCase()) {
          await _requireFree(target);
        }
        final FileSystemEntity entity = FileSystemEntity.isDirectorySync(path)
            ? Directory(path)
            : File(path);
        return (await entity.rename(target)).path;
      });

  @override
  Future<void> copy(String path, String target) => _guard(path, () async {
        await _requireFree(target);
        if (FileSystemEntity.isDirectorySync(path)) {
          if (target.startsWith('$path$separator')) {
            throw FileSystemError('Cannot copy a folder into itself', target);
          }
          await Directory(target).create();
          await for (final FileSystemEntity child
              in Directory(path).list(followLinks: false)) {
            await copy(child.path, join(target, nameOf(child.path)));
          }
        } else {
          await File(path).copy(target);
        }
      });

  @override
  Future<void> move(String path, String target) => _guard(path, () async {
        await _requireFree(target);
        final bool folder = FileSystemEntity.isDirectorySync(path);
        try {
          await (folder ? Directory(path) : File(path)).rename(target);
        } on FileSystemException {
          // Another volume: rename cannot cross it, so copy and remove.
          await copy(path, target);
          await (folder ? Directory(path) : File(path)).delete(recursive: true);
        }
      });

  @override
  Future<void> trash(String path) => Trash.moveToTrash(path);

  @override
  Future<void> open(String path) => Shell.openPath(path);

  @override
  Future<void> reveal(String path) => Shell.revealInFileManager(path);

  @override
  Stream<void>? watch(String directory) {
    if (!FileWatcher.isSupported) return null;
    try {
      return FileWatcher.watch(directory).map((_) {});
    } on Object {
      return null;
    }
  }

  @override
  Future<List<Volume>> volumes() async {
    final List<Volume> out = <Volume>[];
    if (_windows) {
      for (var c = 'A'.codeUnitAt(0); c <= 'Z'.codeUnitAt(0); c++) {
        final String root = '${String.fromCharCode(c)}:\\';
        if (Directory(root).existsSync()) {
          out.add(Volume(
            path: root,
            label: c == 'C'.codeUnitAt(0)
                ? 'Local Disk (${root.substring(0, 2)})'
                : 'Drive (${root.substring(0, 2)})',
            removable: c < 'C'.codeUnitAt(0),
          ));
        }
      }
      return out;
    }
    out.add(Volume(
        path: '/', label: Platform.isMacOS ? 'Macintosh HD' : 'File System'));
    final List<String> mountDirs = Platform.isMacOS
        ? const <String>['/Volumes']
        : <String>[
            '/media/${Platform.environment['USER'] ?? ''}',
            '/run/media/${Platform.environment['USER'] ?? ''}',
            '/mnt',
          ];
    for (final String dir in mountDirs) {
      try {
        for (final FileSystemEntity entity in Directory(dir).listSync()) {
          if (entity is! Directory) continue;
          final FileSystemEntity resolved =
              Link(entity.path).existsSync() ? Link(entity.path) : entity;
          // macOS lists the boot volume under /Volumes as a link to /.
          if (resolved is Link) continue;
          out.add(Volume(
            path: entity.path,
            label: nameOf(entity.path),
            removable: true,
          ));
        }
      } on FileSystemException {
        continue;
      }
    }
    return out;
  }
}
