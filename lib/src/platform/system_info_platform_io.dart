library;

import 'dart:ffi';
import 'dart:io';

import '../ffi/native_memory.dart';
import 'system_info_types.dart';

SystemInfoData snapshot() {
  final Map<String, String> environment = Platform.environment;
  return SystemInfoData(
    operatingSystem: Platform.operatingSystem,
    operatingSystemVersion: Platform.operatingSystemVersion,
    hostname: Platform.localHostname,
    userName: environment['USERNAME'] ??
        environment['USER'] ??
        environment['LOGNAME'] ??
        '',
    locale: Platform.localeName,
    processorCount: Platform.numberOfProcessors,
  );
}

Future<bool?> isDarkMode() async {
  if (Platform.isWindows) {
    final int? value = readWindowsAppsUseLightTheme();
    return value == null ? null : darkModeFromAppsUseLightTheme(value);
  }
  if (Platform.isMacOS) return _macDarkMode();
  if (Platform.isLinux) return _linuxDarkMode();
  return null;
}

/// The seam a test injects a fake process runner through.
typedef SystemProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

Future<ProcessResult> _runProcess(
  String executable,
  List<String> arguments,
) =>
    Process.run(executable, arguments);

/// macOS: the global default `AppleInterfaceStyle` exists (and reads `Dark`)
/// only while dark mode is on.
Future<bool?> _macDarkMode({SystemProcessRunner run = _runProcess}) async {
  try {
    final ProcessResult result = await run(
      '/usr/bin/defaults',
      const <String>['read', '-g', 'AppleInterfaceStyle'],
    );
    return darkModeFromAppleInterfaceStyle(
      exitCode: result.exitCode,
      stdout: '${result.stdout}',
    );
  } on ProcessException {
    return null;
  }
}

/// Linux: the freedesktop `color-scheme` setting, via gsettings. A desktop
/// without gsettings, or one where the schema is missing, answers null.
Future<bool?> _linuxDarkMode({SystemProcessRunner run = _runProcess}) async {
  try {
    final ProcessResult result = await run(
      'gsettings',
      const <String>['get', 'org.gnome.desktop.interface', 'color-scheme'],
    );
    if (result.exitCode != 0) return null;
    return darkModeFromColorScheme('${result.stdout}');
  } on ProcessException {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Windows: HKCU\...\Themes\Personalize!AppsUseLightTheme, via RegGetValueW.
// A registry read, not a process spawn: the value is what every application
// reading the "app mode" setting consults, and advapi32 is always present.
// ---------------------------------------------------------------------------

typedef _RegGetValueWNative = Int32 Function(
  IntPtr key,
  Pointer<Uint16> subKey,
  Pointer<Uint16> value,
  Uint32 flags,
  Pointer<Uint32> type,
  Pointer<Uint32> data,
  Pointer<Uint32> dataSize,
);
typedef _RegGetValueWDart = int Function(
  int key,
  Pointer<Uint16> subKey,
  Pointer<Uint16> value,
  int flags,
  Pointer<Uint32> type,
  Pointer<Uint32> data,
  Pointer<Uint32> dataSize,
);

const int _hkeyCurrentUser = 0x80000001;
const int _rrfRtRegDword = 0x00010000;

_RegGetValueWDart? _regGetValue;
bool _regBindAttempted = false;

/// The raw `AppsUseLightTheme` DWORD, or null when the value (or advapi32)
/// is unavailable - Windows before 1607 has neither the value nor the
/// setting.
int? readWindowsAppsUseLightTheme() {
  if (!_regBindAttempted) {
    _regBindAttempted = true;
    try {
      _regGetValue = DynamicLibrary.open('advapi32.dll')
          .lookupFunction<_RegGetValueWNative, _RegGetValueWDart>(
              'RegGetValueW');
    } on Object {
      _regGetValue = null;
    }
  }
  final _RegGetValueWDart? read = _regGetValue;
  if (read == null) return null;
  return using((NativeArena arena) {
    final Pointer<Uint32> data = arena<Uint32>();
    final Pointer<Uint32> size = arena<Uint32>();
    size.value = 4;
    final int status = read(
      _hkeyCurrentUser,
      arena.allocateUtf16(
        r'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize',
      ),
      arena.allocateUtf16('AppsUseLightTheme'),
      _rrfRtRegDword,
      nullptr,
      data,
      size,
    );
    return status == 0 ? data.value : null;
  });
}
