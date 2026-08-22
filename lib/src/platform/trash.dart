/// Moving files to the trash instead of destroying them.
///
/// Deleting is the one destructive operation a UI performs on the user's own
/// data, and every desktop platform agrees on the remedy: the file goes
/// somewhere recoverable. What differs is everything else - Windows has the
/// Recycle Bin behind a shell API, Linux has a specified directory layout
/// (the freedesktop trash spec), and macOS has `~/.Trash` with no public API
/// at all outside the Objective-C runtime. This port exposes the shared verb
/// and pushes the differences into the platform files.
///
/// What is deliberately *not* promised: restoring, listing, or emptying the
/// trash. Restore-from-trash is a file-manager feature on every platform, and
/// the platforms' own UIs do it better than a framework could.
library;

import 'trash_platform_stub.dart'
    if (dart.library.io) 'trash_platform_io.dart' as platform;
import 'trash_types.dart';

export 'trash_types.dart';

/// The platform's recoverable-delete.
abstract final class Trash {
  /// Moves the file or directory at [path] to the platform trash.
  ///
  /// [path] must name something that exists. On success the entry is no
  /// longer at [path] and is recoverable through the platform's own UI; on
  /// failure a [TrashException] says why and the entry is untouched.
  static Future<void> moveToTrash(String path) => platform.moveToTrash(path);
}
