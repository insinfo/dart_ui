library;

import 'dart:ffi';
import 'dart:io';

import '../ffi/native_memory.dart';
import 'standard_paths_types.dart';

String resolve(StandardFolder folder) {
  // Two folders are platform-neutral: dart:io already asked the OS.
  switch (folder) {
    case StandardFolder.temp:
      return _stripTrailingSeparator(Directory.systemTemp.path);
    case StandardFolder.executable:
      return Platform.resolvedExecutable;
    default:
      break;
  }
  if (Platform.isWindows) return _resolveWindows(folder);
  if (Platform.isMacOS) {
    return macStandardPath(folder, home: _requireHome(folder));
  }
  if (Platform.isLinux) {
    return linuxStandardPath(
      folder,
      environment: Platform.environment,
      readUserDirs: _readLinuxUserDirs,
    );
  }
  throw StandardPathsException(
    folder: folder,
    platform: Platform.operatingSystem,
    reason: 'no standard-paths backend exists for this operating system',
  );
}

String _requireHome(StandardFolder folder) {
  final String? home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) {
    throw StandardPathsException(
      folder: folder,
      platform: Platform.operatingSystem,
      reason: r'$HOME is not set',
    );
  }
  return _stripTrailingSeparator(home);
}

String _stripTrailingSeparator(String path) {
  var result = path;
  while (result.length > 1 &&
      (result.endsWith('/') ||
          (result.endsWith(r'\') && !result.endsWith(r':\')))) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}

// ---------------------------------------------------------------------------
// macOS: fixed conventions under $HOME.
//
// NSSearchPathForDirectoriesInDomains would be the platform's own answer, but
// it lives behind the Objective-C runtime, which this framework does not
// bind. The layout below has been documented and stable since Mac OS X 10.0,
// and - unlike Windows - the folders are not user-relocatable through any
// supported UI, so the convention *is* the platform answer.
// ---------------------------------------------------------------------------

/// The macOS path for [folder] under [home]. Pure, so it is testable on any
/// machine.
String macStandardPath(StandardFolder folder, {required String home}) =>
    switch (folder) {
      StandardFolder.home => home,
      StandardFolder.documents => '$home/Documents',
      StandardFolder.downloads => '$home/Downloads',
      StandardFolder.pictures => '$home/Pictures',
      StandardFolder.music => '$home/Music',
      StandardFolder.videos => '$home/Movies',
      StandardFolder.desktop => '$home/Desktop',
      StandardFolder.appData ||
      StandardFolder.appDataLocal =>
        '$home/Library/Application Support',
      StandardFolder.cache => '$home/Library/Caches',
      // temp and executable are answered before dispatch; reaching here is a
      // caller using this helper directly, and the honest answer is a throw.
      StandardFolder.temp || StandardFolder.executable =>
        throw StandardPathsException(
          folder: folder,
          platform: 'macos',
          reason: 'answered by dart:io, not by home-relative convention',
        ),
    };

// ---------------------------------------------------------------------------
// Linux: XDG base directories plus xdg-user-dirs.
// ---------------------------------------------------------------------------

/// The Linux path for [folder], resolved from [environment] and - for the
/// media folders - from the `user-dirs.dirs` content [readUserDirs] provides.
///
/// [readUserDirs] is a function rather than a string so the file is only read
/// for the folders that need it, and so a test can inject content without a
/// filesystem.
String linuxStandardPath(
  StandardFolder folder, {
  required Map<String, String> environment,
  required String? Function(String configHome) readUserDirs,
}) {
  final String? home = environment['HOME'];
  if (home == null || home.isEmpty) {
    throw StandardPathsException(
      folder: folder,
      platform: 'linux',
      reason: r'$HOME is not set',
    );
  }
  final String homePath = _stripTrailingSeparator(home);

  String xdgBase(String variable, String fallback) {
    final String? value = environment[variable];
    if (value != null && value.startsWith('/')) {
      return _stripTrailingSeparator(value);
    }
    return '$homePath/$fallback';
  }

  switch (folder) {
    case StandardFolder.home:
      return homePath;
    case StandardFolder.appData:
      return xdgBase('XDG_CONFIG_HOME', '.config');
    case StandardFolder.appDataLocal:
      return xdgBase('XDG_DATA_HOME', '.local/share');
    case StandardFolder.cache:
      return xdgBase('XDG_CACHE_HOME', '.cache');
    default:
      break;
  }

  // Media folders: an explicit XDG_*_DIR environment variable wins, then the
  // user-dirs.dirs file, then the well-known default name under $HOME.
  final String key = xdgUserDirKey(folder)!;
  final String? fromEnvironment = environment[key];
  if (fromEnvironment != null && fromEnvironment.startsWith('/')) {
    return _stripTrailingSeparator(fromEnvironment);
  }
  final String configHome = xdgBase('XDG_CONFIG_HOME', '.config');
  final String? content = readUserDirs(configHome);
  if (content != null) {
    final String? configured =
        parseXdgUserDirs(content, home: homePath)[key];
    if (configured != null) return configured;
  }
  final String defaultName = switch (folder) {
    StandardFolder.documents => 'Documents',
    StandardFolder.downloads => 'Downloads',
    StandardFolder.pictures => 'Pictures',
    StandardFolder.music => 'Music',
    StandardFolder.videos => 'Videos',
    _ => 'Desktop',
  };
  return '$homePath/$defaultName';
}

String? _readLinuxUserDirs(String configHome) {
  try {
    final File file = File('$configHome/user-dirs.dirs');
    if (!file.existsSync()) return null;
    return file.readAsStringSync();
  } on FileSystemException {
    return null; // Unreadable is the same as absent: fall back to defaults.
  }
}

// ---------------------------------------------------------------------------
// Windows: SHGetKnownFolderPath, because every known folder is relocatable
// and the registry-backed answer is the only true one. Environment variables
// are the fallback when shell32 cannot be loaded, which on a real Windows
// means something is deeply wrong - but a degraded answer with a name beats
// an unexplained crash.
// ---------------------------------------------------------------------------

final class _Guid extends Struct {
  @Uint32()
  external int data1;

  @Uint16()
  external int data2;

  @Uint16()
  external int data3;

  @Array<Uint8>(8)
  external Array<Uint8> data4;
}

typedef _SHGetKnownFolderPathNative = Int32 Function(
  Pointer<_Guid> id,
  Uint32 flags,
  IntPtr token,
  Pointer<Pointer<Uint16>> path,
);
typedef _SHGetKnownFolderPathDart = int Function(
  Pointer<_Guid> id,
  int flags,
  int token,
  Pointer<Pointer<Uint16>> path,
);
typedef _CoTaskMemFreeNative = Void Function(Pointer<Void> block);
typedef _CoTaskMemFreeDart = void Function(Pointer<Void> block);

/// The KNOWNFOLDERID GUIDs this file asks for, in canonical string form.
///
/// These are ABI constants fixed by the Windows SDK (KnownFolders.h); they
/// are the same on every Windows since Vista.
const Map<StandardFolder, String> _windowsFolderIds =
    <StandardFolder, String>{
  StandardFolder.home: '5E6C858F-0E22-4760-9AFE-EA3317B67173', // Profile
  StandardFolder.documents: 'FDD39AD0-238F-46AF-ADB4-6C85480369C7',
  StandardFolder.downloads: '374DE290-123F-4565-9164-39C4925E467B',
  StandardFolder.pictures: '33E28130-4E1E-4676-835A-98395C3BC3BB',
  StandardFolder.music: '4BD8D571-6D19-48D3-BE97-422220080E43',
  StandardFolder.videos: '18989B1D-99B5-455B-841C-AB7C74E4DDFC',
  StandardFolder.desktop: 'B4BFCC3A-DB2C-424C-B029-7FE99A87C641',
  StandardFolder.appData: '3EB685DB-65F9-4CF6-A03A-E3EF65729F3D', // Roaming
  StandardFolder.appDataLocal: 'F1B32785-6FBA-4FCF-9D55-7B8E7F157091',
  // Windows has no dedicated per-user cache root; LocalAppData is where
  // every application (and the platform's own INetCache) puts caches.
  StandardFolder.cache: 'F1B32785-6FBA-4FCF-9D55-7B8E7F157091',
};

_SHGetKnownFolderPathDart? _shGetKnownFolderPath;
_CoTaskMemFreeDart? _coTaskMemFree;
bool _windowsBindAttempted = false;

void _bindWindows() {
  if (_windowsBindAttempted) return;
  _windowsBindAttempted = true;
  try {
    final DynamicLibrary shell32 = DynamicLibrary.open('shell32.dll');
    final DynamicLibrary ole32 = DynamicLibrary.open('ole32.dll');
    _shGetKnownFolderPath = shell32.lookupFunction<
        _SHGetKnownFolderPathNative,
        _SHGetKnownFolderPathDart>('SHGetKnownFolderPath');
    _coTaskMemFree = ole32.lookupFunction<_CoTaskMemFreeNative,
        _CoTaskMemFreeDart>('CoTaskMemFree');
  } on Object {
    _shGetKnownFolderPath = null;
    _coTaskMemFree = null;
  }
}

void _writeGuid(Pointer<_Guid> target, String canonical) {
  final List<String> parts = canonical.split('-');
  target.ref
    ..data1 = int.parse(parts[0], radix: 16)
    ..data2 = int.parse(parts[1], radix: 16)
    ..data3 = int.parse(parts[2], radix: 16);
  final String tail = parts[3] + parts[4];
  for (var i = 0; i < 8; i++) {
    target.ref.data4[i] =
        int.parse(tail.substring(i * 2, i * 2 + 2), radix: 16);
  }
}

String _resolveWindows(StandardFolder folder) {
  _bindWindows();
  final _SHGetKnownFolderPathDart? lookup = _shGetKnownFolderPath;
  final _CoTaskMemFreeDart? release = _coTaskMemFree;
  if (lookup != null && release != null) {
    final String id = _windowsFolderIds[folder]!;
    final String? path = using((NativeArena arena) {
      final Pointer<_Guid> guid = arena<_Guid>();
      _writeGuid(guid, id);
      final Pointer<Pointer<Uint16>> out = arena<Pointer<Uint16>>();
      final int hresult = lookup(guid, 0, 0, out);
      final Pointer<Uint16> buffer = out.value;
      if (hresult != 0) {
        // The returned buffer must be freed even on failure, per the API's
        // own documentation.
        if (buffer != nullptr) release(buffer.cast<Void>());
        return null;
      }
      try {
        return readNativeUtf16(buffer, limit: 32768);
      } finally {
        release(buffer.cast<Void>());
      }
    });
    if (path != null && path.isNotEmpty) {
      return _stripTrailingSeparator(path);
    }
  }
  return _windowsEnvironmentFallback(folder);
}

/// The environment-variable approximation, used only when shell32 failed.
///
/// `USERPROFILE`, `APPDATA` and `LOCALAPPDATA` are set by the platform for
/// every interactive session; the media folders are approximated by their
/// default names, which is exactly the guess `SHGetKnownFolderPath` exists to
/// avoid - hence fallback, not first choice.
String _windowsEnvironmentFallback(StandardFolder folder) {
  final Map<String, String> environment = Platform.environment;
  String require(String name) {
    final String? value = environment[name];
    if (value == null || value.isEmpty) {
      throw StandardPathsException(
        folder: folder,
        platform: 'windows',
        reason: 'SHGetKnownFolderPath is unavailable and %$name% is not set',
      );
    }
    return _stripTrailingSeparator(value);
  }

  switch (folder) {
    case StandardFolder.home:
      return require('USERPROFILE');
    case StandardFolder.appData:
      return require('APPDATA');
    case StandardFolder.appDataLocal:
    case StandardFolder.cache:
      return require('LOCALAPPDATA');
    case StandardFolder.documents:
      return '${require('USERPROFILE')}\\Documents';
    case StandardFolder.downloads:
      return '${require('USERPROFILE')}\\Downloads';
    case StandardFolder.pictures:
      return '${require('USERPROFILE')}\\Pictures';
    case StandardFolder.music:
      return '${require('USERPROFILE')}\\Music';
    case StandardFolder.videos:
      return '${require('USERPROFILE')}\\Videos';
    case StandardFolder.desktop:
      return '${require('USERPROFILE')}\\Desktop';
    case StandardFolder.temp:
    case StandardFolder.executable:
      throw StandardPathsException(
        folder: folder,
        platform: 'windows',
        reason: 'answered by dart:io before platform dispatch',
      );
  }
}
