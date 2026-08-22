/// Handing things to the operating system's own openers.
///
/// Three operations, all of the shape "the user clicked something that is not
/// ours to render": a URL goes to the default browser, a file goes to
/// whatever application the user associated with it, and "show me this file"
/// goes to the file manager with the file selected. Each is fire-and-forget -
/// the launched application belongs to the user, not to this process, so
/// success means "the platform accepted the request", never "the document
/// finished opening".
///
/// On the web only [Shell.openUrl] exists (a new browser tab); the other two
/// throw [ShellException], because a browser has no file manager to reveal
/// anything in.
library;

import 'shell_platform_stub.dart'
    if (dart.library.io) 'shell_platform_io.dart'
    if (dart.library.js_interop) 'shell_platform_web.dart' as platform;
import 'shell_types.dart';

export 'shell_types.dart';

/// Opening URLs, files and folders with the user's own default applications.
abstract final class Shell {
  /// Opens [url] in the default browser (or the handler registered for its
  /// scheme - `mailto:` opens the mail client).
  ///
  /// [url] must be absolute; a bare program name or relative path throws
  /// [ShellException] rather than being handed to the platform, where at
  /// least one target would happily execute it.
  static Future<void> openUrl(String url) => platform.openUrl(url);

  /// Opens the file or directory at [path] with its default application.
  ///
  /// The path must exist; a missing path is a [ShellException] here rather
  /// than a silent no-op or a platform error dialog.
  static Future<void> openPath(String path) => platform.openPath(path);

  /// Opens the platform's file manager with [path] selected.
  static Future<void> revealInFileManager(String path) =>
      platform.revealInFileManager(path);
}
