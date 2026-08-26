library;

import 'dart:ffi';
import 'dart:io';

import '../ffi/native_memory.dart';
import 'trash_types.dart';

Future<void> moveToTrash(String path) async {
  final String absolute = File(path).absolute.path;
  if (FileSystemEntity.typeSync(absolute) == FileSystemEntityType.notFound) {
    throw TrashException(
      path: absolute,
      platform: Platform.operatingSystem,
      reason: 'the path does not exist',
    );
  }
  if (Platform.isWindows) {
    _windowsRecycle(absolute);
    return;
  }
  if (Platform.isMacOS) {
    final String? home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      throw TrashException(
        path: absolute,
        platform: 'macos',
        reason: r'$HOME is not set, so ~/.Trash cannot be found',
      );
    }
    await moveToMacTrash(absolute, trashDirectory: '$home/.Trash');
    return;
  }
  if (Platform.isLinux) {
    await moveToFreedesktopTrash(
      absolute,
      trashRoot: linuxTrashRoot(Platform.environment),
    );
    return;
  }
  throw TrashException(
    path: absolute,
    platform: Platform.operatingSystem,
    reason: 'no trash backend exists for this operating system',
  );
}

// ---------------------------------------------------------------------------
// Linux: the freedesktop trash specification, home trash only.
//
// The spec also describes per-volume `.Trash-$uid` directories for files on
// other filesystems; those need the mount table and uid lookups, and the
// spec's own instruction for an implementation without them is explicit: if
// the file cannot be trashed, fail rather than delete. The cross-device
// fallback below (copy, then delete the copy's source) preserves that
// recoverability guarantee by never destroying bytes before a copy exists.
// ---------------------------------------------------------------------------

/// The home trash directory for [environment]: `$XDG_DATA_HOME/Trash`,
/// defaulting to `~/.local/share/Trash`.
String linuxTrashRoot(Map<String, String> environment) {
  final String? dataHome = environment['XDG_DATA_HOME'];
  if (dataHome != null && dataHome.startsWith('/')) {
    return '$dataHome/Trash';
  }
  final String? home = environment['HOME'];
  if (home == null || home.isEmpty) {
    throw const TrashException(
      path: '',
      platform: 'linux',
      reason: r'neither $XDG_DATA_HOME nor $HOME is set',
    );
  }
  return '$home/.local/share/Trash';
}

/// Trashes [absolutePath] into the spec's `files/` + `info/` pair under
/// [trashRoot].
///
/// Separated from the platform dispatch, with the root injectable, because
/// the sequence - reserve a unique name via the `.trashinfo` file, then move -
/// is the part worth testing, and it runs on any filesystem `dart:io` can
/// write to, including a Windows temp directory.
Future<void> moveToFreedesktopTrash(
  String absolutePath, {
  required String trashRoot,
  DateTime? now,
}) async {
  final Directory filesDir = Directory('$trashRoot/files');
  final Directory infoDir = Directory('$trashRoot/info');
  try {
    filesDir.createSync(recursive: true);
    infoDir.createSync(recursive: true);
  } on FileSystemException catch (error) {
    throw TrashException(
      path: absolutePath,
      platform: 'linux',
      reason: 'the trash directory could not be created: ${error.message}',
    );
  }

  final String baseName =
      absolutePath.substring(absolutePath.lastIndexOf('/') + 1);
  // The name must be free in *both* directories, and the spec's own locking
  // trick is to claim it by creating the info file exclusively first: two
  // processes trashing `report.pdf` at once race on the O_EXCL create, not
  // on the move.
  final String wanted = baseName.isEmpty ? 'trashed' : baseName;
  String chosen = wanted;
  File infoFile;
  for (var attempt = 0;; attempt++) {
    chosen = disambiguateTrashName(
      wanted,
      (String candidate) =>
          File('${infoDir.path}/$candidate.trashinfo').existsSync() ||
          FileSystemEntity.typeSync('${filesDir.path}/$candidate') !=
              FileSystemEntityType.notFound,
    );
    infoFile = File('${infoDir.path}/$chosen.trashinfo');
    try {
      // `exclusive` is the O_EXCL of the spec's claiming trick: if another
      // process claimed this name between the exists check and here, the
      // create throws and the loop chooses the next free name.
      infoFile.createSync(exclusive: true);
      infoFile.writeAsStringSync(
        buildTrashInfo(
          originalPath: absolutePath,
          deletedAt: now ?? DateTime.now(),
        ),
        flush: true,
      );
      break;
    } on FileSystemException {
      if (attempt >= 32) {
        throw TrashException(
          path: absolutePath,
          platform: 'linux',
          reason: 'could not claim a unique name in ${infoDir.path}',
        );
      }
    }
  }

  try {
    await _move(absolutePath, '${filesDir.path}/$chosen');
  } on Object catch (error) {
    // The claim is released on failure so a retry does not leak info files.
    try {
      infoFile.deleteSync();
    } on FileSystemException {
      // The original failure is the one worth reporting.
    }
    throw TrashException(
      path: absolutePath,
      platform: 'linux',
      reason: 'the move into the trash failed: $error',
    );
  }
}

// ---------------------------------------------------------------------------
// macOS: ~/.Trash by convention.
//
// The supported API (NSFileManager trashItemAtURL) lives behind the
// Objective-C runtime, which this framework does not bind. Moving into
// ~/.Trash is what the Finder itself does with the file; what is lost
// without the API is only the Finder's "Put Back" bookkeeping.
// ---------------------------------------------------------------------------

/// Moves [absolutePath] into [trashDirectory], renaming on collision the way
/// the Finder does (`name 2.ext`).
Future<void> moveToMacTrash(
  String absolutePath, {
  required String trashDirectory,
}) async {
  final Directory trash = Directory(trashDirectory);
  try {
    trash.createSync(recursive: true);
  } on FileSystemException catch (error) {
    throw TrashException(
      path: absolutePath,
      platform: 'macos',
      reason: '$trashDirectory could not be created: ${error.message}',
    );
  }
  final String baseName =
      absolutePath.substring(absolutePath.lastIndexOf('/') + 1);
  final String chosen = disambiguateTrashName(
    baseName.isEmpty ? 'trashed' : baseName,
    (String candidate) =>
        FileSystemEntity.typeSync('$trashDirectory/$candidate') !=
        FileSystemEntityType.notFound,
    separator: ' ',
  );
  try {
    await _move(absolutePath, '$trashDirectory/$chosen');
  } on Object catch (error) {
    throw TrashException(
      path: absolutePath,
      platform: 'macos',
      reason: 'the move into $trashDirectory failed: $error',
    );
  }
}

/// Renames, falling back to copy-then-delete when source and destination sit
/// on different filesystems (`rename(2)` answers EXDEV there). The copy is
/// complete and flushed before anything is deleted, so failure at any point
/// leaves the original recoverable.
Future<void> _move(String from, String to) async {
  final FileSystemEntityType type =
      FileSystemEntity.typeSync(from, followLinks: false);
  try {
    if (type == FileSystemEntityType.directory) {
      Directory(from).renameSync(to);
    } else if (type == FileSystemEntityType.link) {
      Link(from).renameSync(to);
    } else {
      File(from).renameSync(to);
    }
    return;
  } on FileSystemException {
    // Cross-device, most likely. Fall through to copy + delete.
  }
  if (type == FileSystemEntityType.directory) {
    _copyDirectory(Directory(from), Directory(to));
    Directory(from).deleteSync(recursive: true);
  } else if (type == FileSystemEntityType.link) {
    Link(to).createSync(Link(from).targetSync());
    Link(from).deleteSync();
  } else {
    File(from).copySync(to);
    File(from).deleteSync();
  }
}

void _copyDirectory(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final FileSystemEntity entry
      in from.listSync(recursive: false, followLinks: false)) {
    final String name = entry.path.split(Platform.pathSeparator).last;
    final String target = '${to.path}/$name';
    if (entry is Directory) {
      _copyDirectory(entry, Directory(target));
    } else if (entry is Link) {
      Link(target).createSync(entry.targetSync());
    } else if (entry is File) {
      entry.copySync(target);
    }
  }
}

// ---------------------------------------------------------------------------
// Windows: SHFileOperationW with FOF_ALLOWUNDO, which is the Recycle Bin.
//
// IFileOperation is the newer COM route; it needs CoInitialize, an
// apartment, and a vtable binding, in exchange for per-item progress this
// port does not expose. The one function call below does the same move.
// ---------------------------------------------------------------------------

const int _foDelete = 3;
const int _fofSilent = 0x0004;
const int _fofNoConfirmation = 0x0010;
const int _fofAllowUndo = 0x0040;
const int _fofNoErrorUi = 0x0400;

/// `SHFILEOPSTRUCTW`, in its x64 layout. The x86 build of Windows packs this
/// struct to one byte; the framework targets 64-bit Windows, where the
/// natural alignment below matches the SDK's.
final class _ShFileOpStructW extends Struct {
  @IntPtr()
  external int ownerWindow;

  @Uint32()
  external int operation;

  external Pointer<Uint16> from;
  external Pointer<Uint16> to;

  @Uint16()
  external int flags;

  @Int32()
  external int anyOperationsAborted;

  external Pointer<Void> nameMappings;
  external Pointer<Uint16> progressTitle;
}

typedef _SHFileOperationWNative = Int32 Function(
  Pointer<_ShFileOpStructW> descriptor,
);
typedef _SHFileOperationWDart = int Function(
  Pointer<_ShFileOpStructW> descriptor,
);

_SHFileOperationWDart? _shFileOperation;

void _windowsRecycle(String absolutePath) {
  final _SHFileOperationWDart operate;
  try {
    operate = _shFileOperation ??= DynamicLibrary.open('shell32.dll')
        .lookupFunction<_SHFileOperationWNative, _SHFileOperationWDart>(
            'SHFileOperationW');
  } on Object catch (error) {
    throw TrashException(
      path: absolutePath,
      platform: 'windows',
      reason: 'shell32.dll could not be loaded: $error',
    );
  }
  final ({int code, bool aborted}) outcome = using((NativeArena arena) {
    // pFrom is a *double* NUL-terminated list of paths.
    final List<int> units = <int>[...absolutePath.codeUnits, 0, 0];
    final Pointer<Uint16> from = arena<Uint16>(units.length * 2);
    from.asTypedList(units.length).setAll(0, units);
    final Pointer<_ShFileOpStructW> descriptor = arena<_ShFileOpStructW>();
    descriptor.ref
      ..operation = _foDelete
      ..from = from
      ..flags = _fofAllowUndo | _fofNoConfirmation | _fofSilent | _fofNoErrorUi;
    final int code = operate(descriptor);
    return (code: code, aborted: descriptor.ref.anyOperationsAborted != 0);
  });
  if (outcome.code != 0 || outcome.aborted) {
    throw TrashException(
      path: absolutePath,
      platform: 'windows',
      errorCode: outcome.code,
      reason: outcome.aborted
          ? 'the shell aborted the recycle operation'
          : 'SHFileOperationW reported a failure code',
    );
  }
}
