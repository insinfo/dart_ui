/// The operating system's well-known directories, by name.
///
/// "Where do documents go" is a question only the platform can answer:
/// Windows lets the user relocate every known folder and records the answer
/// behind `SHGetKnownFolderPath`, Linux records it in environment variables
/// and `~/.config/user-dirs.dirs`, and macOS fixes the layout under `$HOME`
/// by convention. Guessing `$HOME/Documents` is right until the first user
/// who moved their Documents to another drive, which is exactly the user the
/// platform API exists for.
///
/// Every accessor is synchronous: each platform answers from memory, a
/// registry call or one small file read, and none of them talks to another
/// process. Browsers have no filesystem to name, so on the web every lookup
/// throws [StandardPathsException].
library;

import 'standard_paths_platform_stub.dart'
    if (dart.library.io) 'standard_paths_platform_io.dart' as platform;
import 'standard_paths_types.dart';

export 'standard_paths_types.dart';

/// Well-known per-user directories, resolved the way the platform resolves
/// them.
///
/// Accessors throw [StandardPathsException] when the platform cannot answer -
/// a folder the user deleted, a headless Linux with no `$HOME`, a browser.
/// They never invent a path that was not derived from the platform's own
/// configuration.
abstract final class StandardPaths {
  /// The directory for [folder], as an absolute path without a trailing
  /// separator.
  static String resolve(StandardFolder folder) => platform.resolve(folder);

  static String get home => resolve(StandardFolder.home);
  static String get documents => resolve(StandardFolder.documents);
  static String get downloads => resolve(StandardFolder.downloads);
  static String get pictures => resolve(StandardFolder.pictures);
  static String get music => resolve(StandardFolder.music);
  static String get videos => resolve(StandardFolder.videos);
  static String get desktop => resolve(StandardFolder.desktop);

  /// Roaming configuration/data root; append your application's name.
  static String get appData => resolve(StandardFolder.appData);

  /// Machine-local data root; append your application's name.
  static String get appDataLocal => resolve(StandardFolder.appDataLocal);

  /// Cache root; append your application's name.
  static String get cache => resolve(StandardFolder.cache);

  static String get temp => resolve(StandardFolder.temp);

  /// The full path of the running executable.
  static String get executable => resolve(StandardFolder.executable);
}
