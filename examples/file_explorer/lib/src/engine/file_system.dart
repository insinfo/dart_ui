/// The file system the explorer works on - an interface, so the engine is
/// tested against a [MemoryFileSystem] and runs against the disk through
/// `IoFileSystem`, and nothing above it imports `dart:io`.
library;

import 'dart:async';

/// One file or folder, as a listing reports it.
final class FileEntry {
  const FileEntry({
    required this.path,
    required this.name,
    required this.isDirectory,
    this.size,
    this.modified,
    this.created,
    this.accessed,
    this.changed,
    this.permissions,
    this.nativeAttributes,
    this.isReadOnly,
    this.isSymbolicLink = false,
    this.linkTarget,
    this.isHidden = false,
    this.isSystem = false,
  });

  final String path;
  final String name;
  final bool isDirectory;

  /// Bytes; null for a folder, whose size is not known without walking it.
  final int? size;
  final DateTime? modified;
  final DateTime? created;
  final DateTime? accessed;
  final DateTime? changed;
  final String? permissions;
  final int? nativeAttributes;
  final bool? isReadOnly;
  final bool isSymbolicLink;
  final String? linkTarget;

  /// Parent path without requiring file-system I/O, including drive roots.
  String get folderPath {
    final slash = path.lastIndexOf('/');
    final backslash = path.lastIndexOf(r'\');
    final index = slash > backslash ? slash : backslash;
    if (index < 0) return '';
    if (index == 0 || (index == 2 && path[1] == ':')) {
      return path.substring(0, index + 1);
    }
    return path.substring(0, index);
  }

  /// A dot file, or one the system marks hidden.
  final bool isHidden;

  /// A file the operating system keeps for itself - `desktop.ini`,
  /// `$RECYCLE.BIN`, `.DS_Store` - shown only when protected files are.
  final bool isSystem;

  /// The part after the last dot, lower case, without it; empty for none
  /// and for a folder.
  String get extension {
    if (isDirectory) return '';
    final int dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  /// The name without its extension - what a rename selects.
  String get stem {
    final String ext = extension;
    return ext.isEmpty ? name : name.substring(0, name.length - ext.length - 1);
  }

  @override
  bool operator ==(Object other) => other is FileEntry && other.path == path;

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() => 'FileEntry($path${isDirectory ? '/' : ''})';
}

/// A drive or a mounted volume - This PC's list.
final class Volume {
  const Volume({
    required this.path,
    required this.label,
    this.totalBytes,
    this.freeBytes,
    this.removable = false,
  });

  final String path;
  final String label;
  final int? totalBytes;
  final int? freeBytes;
  final bool removable;
}

/// A file operation the system refused, with the path it was about.
final class FileSystemError implements Exception {
  const FileSystemError(this.message, [this.path]);

  final String message;
  final String? path;

  @override
  String toString() => path == null ? message : '$message: $path';
}

/// What the explorer needs of a file system.
abstract interface class FileSystem {
  /// `/`, or `\` on Windows.
  String get separator;

  /// Whether paths compare without regard to case (Windows, a Mac's usual
  /// volume).
  bool get caseInsensitive;

  /// [name] inside the folder [directory].
  String join(String directory, String name);

  /// The folder [path] is in, or null for a root.
  String? parentOf(String path);

  /// The last part of [path]; a root's own name for a root.
  String nameOf(String path);

  /// [path] and its ancestors, root first - the address bar's steps.
  List<String> ancestry(String path);

  /// The folder's entries, unsorted. Throws [FileSystemError] for a folder
  /// that cannot be read.
  Future<List<FileEntry>> list(String directory);

  /// The entry at [path], or null when there is none.
  Future<FileEntry?> stat(String path);

  Future<void> createFolder(String path);

  Future<void> createFile(String path);

  /// Renames [path] in place; returns the new path.
  Future<String> rename(String path, String newName);

  /// Copies [path] (a file or a whole folder) to [target].
  Future<void> copy(String path, String target);

  /// Moves [path] to [target].
  Future<void> move(String path, String target);

  /// Sends [path] to the system's trash - never deletes it outright.
  Future<void> trash(String path);

  /// Opens [path] with the application the system associates with it.
  Future<void> open(String path);

  /// Shows [path] in the system's own file manager.
  Future<void> reveal(String path);

  /// Changes inside [directory], or null where nothing can be watched.
  Stream<void>? watch(String directory);

  /// The drives and mounted volumes.
  Future<List<Volume>> volumes();
}

/// Optional bounded text preview; null means binary or unsupported content.
abstract interface class ArchiveFileSystem {
  Future<void> createArchive(List<String> paths, String target);
  Future<void> extractArchive(String path, String target);
}

abstract interface class TextPreviewFileSystem {
  Future<String?> readTextPreview(String path);
}

/// Names Windows and macOS keep for themselves, hidden even from a view
/// that shows hidden items unless protected files are shown too.
const Set<String> kSystemNames = <String>{
  'desktop.ini',
  'thumbs.db',
  r'$recycle.bin',
  'system volume information',
  'pagefile.sys',
  'hiberfil.sys',
  'swapfile.sys',
  '.ds_store',
  '.localized',
  '.spotlight-v100',
  '.fseventsd',
  '.trashes',
};

/// Names the copy of [name] the way Windows does when one is already there:
/// `report - Copy.txt`, then `report - Copy (2).txt` - with [copy] in the
/// user's language, `report - Copia.txt` in Portuguese.
String copyName(String name, bool Function(String candidate) taken,
    {bool isDirectory = false, String copy = 'Copy'}) {
  final int dot = isDirectory ? -1 : name.lastIndexOf('.');
  final String stem = dot > 0 ? name.substring(0, dot) : name;
  final String ext = dot > 0 ? name.substring(dot) : '';
  if (!taken(name)) return name;
  var candidate = '$stem - $copy$ext';
  for (var n = 2; taken(candidate); n++) {
    candidate = '$stem - $copy ($n)$ext';
  }
  return candidate;
}

/// The first free name of [base], `base (2)`, `base (3)`... - what New
/// folder is called.
String freshName(String base, bool Function(String candidate) taken,
    {String extension = ''}) {
  var candidate = '$base$extension';
  for (var n = 2; taken(candidate); n++) {
    candidate = '$base ($n)$extension';
  }
  return candidate;
}

/// A file system held in memory, with `/` paths: what the tests run the
/// engine against, and a sandbox for a demo with no disk.
final class MemoryFileSystem implements FileSystem {
  MemoryFileSystem({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now {
    _nodes['/'] = _Node.folder(_clock());
  }

  final DateTime Function() _clock;
  final Map<String, _Node> _nodes = <String, _Node>{};
  final StreamController<String> _changes =
      StreamController<String>.broadcast(sync: true);

  /// Paths opened and revealed, in order - what a test asserts on.
  final List<String> opened = <String>[];
  final List<String> revealed = <String>[];

  /// Paths sent to the trash, in order.
  final List<String> trashed = <String>[];

  /// The volumes [volumes] reports.
  List<Volume> mounted = const <Volume>[
    Volume(
        path: '/', label: 'Disk', totalBytes: 512 << 30, freeBytes: 200 << 30),
  ];

  @override
  String get separator => '/';

  @override
  bool get caseInsensitive => false;

  /// Makes every folder of [path], like `mkdir -p`.
  void addFolder(String path, {DateTime? modified}) {
    final String? parent = parentOf(path);
    if (parent != null && !_nodes.containsKey(parent)) addFolder(parent);
    _nodes.putIfAbsent(path, () => _Node.folder(modified ?? _clock()));
  }

  /// Adds a file of [size] bytes at [path], making its folders.
  void addFile(String path, {int size = 0, DateTime? modified}) {
    final String? parent = parentOf(path);
    if (parent != null) addFolder(parent);
    _nodes[path] = _Node.file(size, modified ?? _clock());
  }

  bool contains(String path) => _nodes.containsKey(path);

  @override
  String join(String directory, String name) =>
      directory.endsWith('/') ? '$directory$name' : '$directory/$name';

  @override
  String? parentOf(String path) {
    if (path == '/') return null;
    final int slash = path.lastIndexOf('/');
    return slash <= 0 ? '/' : path.substring(0, slash);
  }

  @override
  String nameOf(String path) =>
      path == '/' ? '/' : path.substring(path.lastIndexOf('/') + 1);

  @override
  List<String> ancestry(String path) {
    final List<String> out = <String>[];
    for (String? p = path; p != null; p = parentOf(p)) {
      out.insert(0, p);
    }
    return out;
  }

  FileEntry _entry(String path, _Node node) => FileEntry(
        path: path,
        name: nameOf(path),
        isDirectory: node.isDirectory,
        size: node.isDirectory ? null : node.size,
        modified: node.modified,
        created: node.modified,
        isHidden: nameOf(path).startsWith('.'),
        isSystem: kSystemNames.contains(nameOf(path).toLowerCase()),
      );

  @override
  Future<List<FileEntry>> list(String directory) async {
    final _Node? node = _nodes[directory];
    if (node == null || !node.isDirectory) {
      throw FileSystemError('No such folder', directory);
    }
    return <FileEntry>[
      for (final MapEntry<String, _Node> e in _nodes.entries)
        if (e.key != directory && parentOf(e.key) == directory)
          _entry(e.key, e.value),
    ];
  }

  @override
  Future<FileEntry?> stat(String path) async {
    final _Node? node = _nodes[path];
    return node == null ? null : _entry(path, node);
  }

  void _requireFree(String path) {
    if (_nodes.containsKey(path)) {
      throw FileSystemError('Already exists', path);
    }
    final String? parent = parentOf(path);
    if (parent == null || !(_nodes[parent]?.isDirectory ?? false)) {
      throw FileSystemError('No such folder', parent);
    }
  }

  void _changed(String path) => _changes.add(parentOf(path) ?? path);

  @override
  Future<void> createFolder(String path) async {
    _requireFree(path);
    _nodes[path] = _Node.folder(_clock());
    _changed(path);
  }

  @override
  Future<void> createFile(String path) async {
    _requireFree(path);
    _nodes[path] = _Node.file(0, _clock());
    _changed(path);
  }

  /// [path] and everything under it.
  List<String> _subtree(String path) => <String>[
        for (final String p in _nodes.keys)
          if (p == path || p.startsWith('$path/')) p,
      ];

  @override
  Future<String> rename(String path, String newName) async {
    if (newName.isEmpty || newName.contains('/')) {
      throw FileSystemError('Not a valid name', newName);
    }
    final String target = join(parentOf(path)!, newName);
    if (target == path) return path;
    _requireFree(target);
    await move(path, target);
    return target;
  }

  @override
  Future<void> copy(String path, String target) async {
    if (!_nodes.containsKey(path)) throw FileSystemError('No such item', path);
    if (target == path || target.startsWith('$path/')) {
      throw FileSystemError('Cannot copy a folder into itself', target);
    }
    _requireFree(target);
    for (final String p in _subtree(path)) {
      _nodes[target + p.substring(path.length)] = _nodes[p]!.copy();
    }
    _changed(target);
  }

  @override
  Future<void> move(String path, String target) async {
    if (!_nodes.containsKey(path)) throw FileSystemError('No such item', path);
    if (target.startsWith('$path/')) {
      throw FileSystemError('Cannot move a folder into itself', target);
    }
    _requireFree(target);
    for (final String p in _subtree(path)) {
      _nodes[target + p.substring(path.length)] = _nodes.remove(p)!;
    }
    _changed(path);
    _changed(target);
  }

  @override
  Future<void> trash(String path) async {
    if (!_nodes.containsKey(path)) throw FileSystemError('No such item', path);
    for (final String p in _subtree(path)) {
      _nodes.remove(p);
    }
    trashed.add(path);
    _changed(path);
  }

  @override
  Future<void> open(String path) async => opened.add(path);

  @override
  Future<void> reveal(String path) async => revealed.add(path);

  @override
  Stream<void>? watch(String directory) =>
      _changes.stream.where((String changed) => changed == directory);

  @override
  Future<List<Volume>> volumes() async => mounted;
}

final class _Node {
  _Node.folder(this.modified)
      : isDirectory = true,
        size = 0;

  _Node.file(this.size, this.modified) : isDirectory = false;

  final bool isDirectory;
  final int size;
  final DateTime modified;

  _Node copy() =>
      isDirectory ? _Node.folder(modified) : _Node.file(size, modified);
}
