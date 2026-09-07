library;

import 'dart:ffi';
import 'dart:io';

import '../ffi/native_memory.dart';
import 'file_picker_types.dart';
import 'file_picker_windows_com.dart';
import 'file_picker_windows_modal.dart';

const int _ofnNoChangeDir = 0x00000008;
const int _ofnPathMustExist = 0x00000800;
const int _ofnFileMustExist = 0x00001000;
const int _ofnExplorer = 0x00080000;
const int _ofnOverwritePrompt = 0x00000002;
const int _maxWindowsPathUnits = 32768;

final class _OpenFileNameW extends Struct {
  @Uint32()
  external int lStructSize;

  @IntPtr()
  external int hwndOwner;

  @IntPtr()
  external int hInstance;

  external Pointer<Uint16> lpstrFilter;
  external Pointer<Uint16> lpstrCustomFilter;

  @Uint32()
  external int nMaxCustFilter;

  @Uint32()
  external int nFilterIndex;

  external Pointer<Uint16> lpstrFile;

  @Uint32()
  external int nMaxFile;

  external Pointer<Uint16> lpstrFileTitle;

  @Uint32()
  external int nMaxFileTitle;

  external Pointer<Uint16> lpstrInitialDir;
  external Pointer<Uint16> lpstrTitle;

  @Uint32()
  external int flags;

  @Uint16()
  external int nFileOffset;

  @Uint16()
  external int nFileExtension;

  external Pointer<Uint16> lpstrDefExt;

  @IntPtr()
  external int lCustData;

  external Pointer<Void> lpfnHook;
  external Pointer<Uint16> lpTemplateName;
  external Pointer<Void> pvReserved;

  @Uint32()
  external int dwReserved;

  @Uint32()
  external int flagsEx;
}

typedef _GetOpenFileNameWNative = Int32 Function(
  Pointer<_OpenFileNameW> value,
);
typedef _GetOpenFileNameWDart = int Function(
  Pointer<_OpenFileNameW> value,
);
typedef _GetSaveFileNameWNative = Int32 Function(
  Pointer<_OpenFileNameW> value,
);
typedef _GetSaveFileNameWDart = int Function(
  Pointer<_OpenFileNameW> value,
);
typedef _CommDlgExtendedErrorNative = Uint32 Function();
typedef _CommDlgExtendedErrorDart = int Function();

Future<PickedFile?> openFile({
  required String title,
  required List<FilePickerFilter> filters,
  required int ownerWindowHandle,
}) async {
  final String? path;
  if (Platform.isWindows) {
    path = await _openWindows(
      title: title,
      filters: filters,
      ownerWindowHandle: ownerWindowHandle,
    );
  } else if (Platform.isMacOS) {
    path = await _openMacOS(title: title, filters: filters);
  } else if (Platform.isLinux) {
    path = await _openLinux(title: title, filters: filters);
  } else {
    throw FilePickerException(
      operation: 'openFile',
      platform: Platform.operatingSystem,
      reason: 'no desktop file-picker backend is available',
    );
  }
  if (path == null) return null;
  try {
    final File file = File(path);
    return PickedFile(
      name: _baseName(path),
      path: path,
      bytes: await file.readAsBytes(),
    );
  } on Object catch (error) {
    throw FilePickerException(
      operation: 'read selected file',
      platform: Platform.operatingSystem,
      reason: '$error',
    );
  }
}

/// The Common Item Dialog first, the 2000-era one only if it is not there.
///
/// `IFileOpenDialog` is what every shipping application opens: it has the
/// navigation pane, the places the user pinned in Explorer, the search box and
/// per-type filters that are a real list instead of a NUL-separated string.
/// `GetOpenFileNameW` has none of that, and the difference is visible to the
/// user the moment they look for a pinned folder that simply is not there.
///
/// The legacy path below is **kept, not replaced**: a session where
/// `CoCreateInstance` refuses - a locked-down desktop, a Windows older than
/// Vista, a broken shell registration - still gets a working open dialog
/// rather than an exception about a COM class it never asked for.
Future<String?> _openWindows({
  required String title,
  required List<FilePickerFilter> filters,
  required int ownerWindowHandle,
}) async {
  final WindowsFileDialogResult result = await showWindowsFileDialogAsync(
    save: false,
    title: title,
    filters: filters,
    ownerWindowHandle: ownerWindowHandle,
  );
  switch (result.status) {
    case WindowsFileDialogStatus.selected:
      return result.path;
    case WindowsFileDialogStatus.cancelled:
      return null;
    case WindowsFileDialogStatus.failed:
      throw FilePickerException(
        operation: 'IFileOpenDialog',
        platform: 'windows',
        errorCode: result.hresult,
        reason: result.detail ?? 'the Common Item Dialog failed',
      );
    case WindowsFileDialogStatus.unavailable:
      // No dialog was shown, so nothing is in flight and the gate below opens
      // its own. The double disable/enable of the owner window is two style-bit
      // writes on a path that only a machine without the Common Item Dialog
      // ever takes.
      return runWindowsModalOffThread<String?>(
        ownerWindowHandle: ownerWindowHandle,
        debugName: 'windows-legacy-open-dialog',
        body: () => _openWindowsLegacy(
          title: title,
          filters: filters,
          ownerWindowHandle: ownerWindowHandle,
        ),
      );
  }
}

/// `GetOpenFileNameW`, the fallback for a machine with no Common Item Dialog.
///
/// It blocks its caller in a nested modal loop exactly as `IFileDialog::Show`
/// does, so it gets exactly the same treatment: the only caller runs it through
/// [runWindowsModalOffThread]. Leaving this one on the main isolate would have
/// meant the freeze came back on every machine that falls back.
String? _openWindowsLegacy({
  required String title,
  required List<FilePickerFilter> filters,
  required int ownerWindowHandle,
}) {
  final DynamicLibrary library;
  try {
    library = DynamicLibrary.open('comdlg32.dll');
  } on Object catch (error) {
    throw FilePickerException(
      operation: 'load comdlg32.dll',
      platform: 'windows',
      reason: '$error',
    );
  }
  final _GetOpenFileNameWDart getOpenFileName =
      library.lookupFunction<_GetOpenFileNameWNative, _GetOpenFileNameWDart>(
          'GetOpenFileNameW');
  final _CommDlgExtendedErrorDart extendedError = library.lookupFunction<
      _CommDlgExtendedErrorNative,
      _CommDlgExtendedErrorDart>('CommDlgExtendedError');

  return using((NativeArena arena) {
    final Pointer<_OpenFileNameW> descriptor = arena<_OpenFileNameW>();
    final Pointer<Uint16> fileBuffer = arena<Uint16>(_maxWindowsPathUnits);
    final List<FilePickerFilter> effective = filters.isEmpty
        ? const <FilePickerFilter>[
            FilePickerFilter(label: 'All files', extensions: <String>['*']),
          ]
        : filters;
    descriptor.ref
      ..lStructSize = sizeOf<_OpenFileNameW>()
      ..hwndOwner = ownerWindowHandle
      ..lpstrFilter = arena.allocateUtf16(_windowsFilter(effective))
      ..nFilterIndex = 1
      ..lpstrFile = fileBuffer
      ..nMaxFile = _maxWindowsPathUnits
      ..lpstrTitle = arena.allocateUtf16(title)
      ..flags = _ofnExplorer |
          _ofnFileMustExist |
          _ofnPathMustExist |
          _ofnNoChangeDir;

    if (getOpenFileName(descriptor) != 0) {
      return readNativeUtf16(fileBuffer, limit: _maxWindowsPathUnits);
    }
    final int code = extendedError();
    if (code == 0) return null;
    throw FilePickerException(
      operation: 'GetOpenFileNameW',
      platform: 'windows',
      errorCode: code,
      reason: 'the common file dialog reported an extended error',
    );
  });
}

/// Asks the platform where to write a file. See `FilePicker.saveFile`.
Future<String?> saveFile({
  required String title,
  required String suggestedName,
  required List<FilePickerFilter> filters,
  required String? defaultExtension,
  required int ownerWindowHandle,
}) async {
  if (Platform.isWindows) {
    return _saveWindows(
      title: title,
      suggestedName: suggestedName,
      filters: filters,
      defaultExtension: defaultExtension,
      ownerWindowHandle: ownerWindowHandle,
    );
  }
  if (Platform.isMacOS) {
    return _saveMacOS(title: title, suggestedName: suggestedName);
  }
  if (Platform.isLinux) {
    return _saveLinux(
      title: title,
      suggestedName: suggestedName,
      filters: filters,
    );
  }
  throw FilePickerException(
    operation: 'saveFile',
    platform: Platform.operatingSystem,
    reason: 'no desktop file-picker backend is available',
  );
}

/// `IFileSaveDialog` first, `GetSaveFileNameW` only if COM refused.
///
/// The modern dialog splits what the legacy one conflated. `GetSaveFileNameW`
/// took one buffer that was both the starting directory and the suggested
/// name, so a caller that passed `C:\docs\drawing.svg` got both effects at
/// once; `IFileSaveDialog` has `SetFolder` and `SetFileName`, and the split is
/// done here so the shipped behaviour of `saveFile` does not change.
Future<String?> _saveWindows({
  required String title,
  required String suggestedName,
  required List<FilePickerFilter> filters,
  required String? defaultExtension,
  required int ownerWindowHandle,
}) async {
  final ({String? directory, String name}) seed =
      splitSuggestedPath(suggestedName);
  final WindowsFileDialogResult result = await showWindowsFileDialogAsync(
    save: true,
    title: title,
    filters: filters,
    suggestedName: seed.name,
    defaultExtension: defaultExtension,
    initialDirectory: seed.directory,
    ownerWindowHandle: ownerWindowHandle,
  );
  switch (result.status) {
    case WindowsFileDialogStatus.selected:
      return result.path;
    case WindowsFileDialogStatus.cancelled:
      return null;
    case WindowsFileDialogStatus.failed:
      throw FilePickerException(
        operation: 'IFileSaveDialog',
        platform: 'windows',
        errorCode: result.hresult,
        reason: result.detail ?? 'the Common Item Dialog failed',
      );
    case WindowsFileDialogStatus.unavailable:
      return runWindowsModalOffThread<String?>(
        ownerWindowHandle: ownerWindowHandle,
        debugName: 'windows-legacy-save-dialog',
        body: () => _saveWindowsLegacy(
          title: title,
          suggestedName: suggestedName,
          filters: filters,
          defaultExtension: defaultExtension,
          ownerWindowHandle: ownerWindowHandle,
        ),
      );
  }
}

/// A suggested name split into the folder to start in and the name to type in.
///
/// Public for the test that asserts it: the split is the one place where a
/// caller passing an absolute path can lose its directory, and the failure -
/// a save dialog that opens in Documents instead of next to the file the user
/// opened - is invisible in a headless run.
({String? directory, String name}) splitSuggestedPath(String suggestedName) {
  final int separator = suggestedName.lastIndexOf(RegExp(r'[\\/]'));
  if (separator < 0) {
    return (directory: null, name: suggestedName);
  }
  return (
    directory: suggestedName.substring(0, separator + 1),
    name: suggestedName.substring(separator + 1),
  );
}

/// `GetSaveFileNameW`, the fallback for a machine with no Common Item Dialog.
///
/// Modal and blocking like its open counterpart, and run off the main isolate
/// for the same reason - see [_openWindowsLegacy].
String? _saveWindowsLegacy({
  required String title,
  required String suggestedName,
  required List<FilePickerFilter> filters,
  required String? defaultExtension,
  required int ownerWindowHandle,
}) {
  final DynamicLibrary library;
  try {
    library = DynamicLibrary.open('comdlg32.dll');
  } on Object catch (error) {
    throw FilePickerException(
      operation: 'load comdlg32.dll',
      platform: 'windows',
      reason: '$error',
    );
  }
  final _GetSaveFileNameWDart getSaveFileName =
      library.lookupFunction<_GetSaveFileNameWNative, _GetSaveFileNameWDart>(
          'GetSaveFileNameW');
  final _CommDlgExtendedErrorDart extendedError = library.lookupFunction<
      _CommDlgExtendedErrorNative,
      _CommDlgExtendedErrorDart>('CommDlgExtendedError');

  return using((NativeArena arena) {
    final Pointer<_OpenFileNameW> descriptor = arena<_OpenFileNameW>();
    final Pointer<Uint16> fileBuffer = arena<Uint16>(_maxWindowsPathUnits);
    // The dialog opens with whatever `lpstrFile` already holds, so the
    // suggested name is written into the buffer rather than passed separately.
    final List<int> seed = suggestedName.codeUnits;
    for (var i = 0; i < seed.length && i < _maxWindowsPathUnits - 1; i++) {
      fileBuffer[i] = seed[i];
    }
    fileBuffer[seed.length.clamp(0, _maxWindowsPathUnits - 1)] = 0;

    final List<FilePickerFilter> effective = filters.isEmpty
        ? const <FilePickerFilter>[
            FilePickerFilter(label: 'All files', extensions: <String>['*']),
          ]
        : filters;
    descriptor.ref
      ..lStructSize = sizeOf<_OpenFileNameW>()
      ..hwndOwner = ownerWindowHandle
      ..lpstrFilter = arena.allocateUtf16(_windowsFilter(effective))
      ..nFilterIndex = 1
      ..lpstrFile = fileBuffer
      ..nMaxFile = _maxWindowsPathUnits
      ..lpstrTitle = arena.allocateUtf16(title)
      ..lpstrDefExt = defaultExtension == null
          ? nullptr
          : arena.allocateUtf16(
              defaultExtension.startsWith('.')
                  ? defaultExtension.substring(1)
                  : defaultExtension,
            )
      // OFN_OVERWRITEPROMPT is the one flag that must not be omitted: without
      // it the dialog silently returns a path that already exists and the
      // caller destroys the user's file with no warning at all.
      ..flags = _ofnExplorer |
          _ofnOverwritePrompt |
          _ofnPathMustExist |
          _ofnNoChangeDir;

    if (getSaveFileName(descriptor) != 0) {
      return readNativeUtf16(fileBuffer, limit: _maxWindowsPathUnits);
    }
    final int code = extendedError();
    if (code == 0) return null;
    throw FilePickerException(
      operation: 'GetSaveFileNameW',
      platform: 'windows',
      errorCode: code,
      reason: 'the common file dialog reported an extended error',
    );
  });
}

Future<String?> _saveMacOS({
  required String title,
  required String suggestedName,
}) async {
  final String escapedTitle =
      title.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  final String escapedName =
      suggestedName.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  final String nameClause =
      escapedName.isEmpty ? '' : ' default name "$escapedName"';
  final String script =
      'POSIX path of (choose file name with prompt "$escapedTitle"$nameClause)';
  final ProcessResult result =
      await Process.run('/usr/bin/osascript', <String>['-e', script]);
  if (result.exitCode == 0) return '${result.stdout}'.trim();
  if ('${result.stderr}'.toLowerCase().contains('user canceled')) return null;
  throw FilePickerException(
    operation: 'NSSavePanel via osascript',
    platform: 'macos',
    errorCode: result.exitCode,
    reason: '${result.stderr}'.trim(),
  );
}

Future<String?> _saveLinux({
  required String title,
  required String suggestedName,
  required List<FilePickerFilter> filters,
}) async {
  final List<_LinuxPickerCommand> commands = <_LinuxPickerCommand>[
    _LinuxPickerCommand(
      executable: 'zenity',
      arguments: <String>[
        '--file-selection',
        '--save',
        '--confirm-overwrite',
        '--title=$title',
        if (suggestedName.isNotEmpty) '--filename=$suggestedName',
        for (final FilePickerFilter filter in filters)
          '--file-filter=${filter.label} | ${filter.wildcardPattern}',
      ],
    ),
    _LinuxPickerCommand(
      executable: 'kdialog',
      arguments: <String>[
        '--getsavefilename',
        suggestedName,
        filters
            .map((FilePickerFilter filter) =>
                '${filter.wildcardPattern}|${filter.label}')
            .join('\n'),
        '--title',
        title,
      ],
    ),
    _LinuxPickerCommand(
      executable: 'yad',
      arguments: <String>['--file-selection', '--save', '--title=$title'],
    ),
  ];
  final List<String> unavailable = <String>[];
  for (final _LinuxPickerCommand command in commands) {
    try {
      final ProcessResult result =
          await Process.run(command.executable, command.arguments);
      if (result.exitCode == 0) return '${result.stdout}'.trim();
      if (result.exitCode == 1) return null;
      throw FilePickerException(
        operation: command.executable,
        platform: 'linux',
        errorCode: result.exitCode,
        reason: '${result.stderr}'.trim(),
      );
    } on ProcessException {
      unavailable.add(command.executable);
    }
  }
  throw FilePickerException(
    operation: 'saveFile',
    platform: 'linux',
    reason: 'no supported desktop chooser is installed '
        '(${unavailable.join(', ')} were not found)',
  );
}

String _windowsFilter(List<FilePickerFilter> filters) {
  final StringBuffer result = StringBuffer();
  for (final FilePickerFilter filter in filters) {
    result
      ..write(filter.label)
      ..writeCharCode(0)
      ..write(filter.wildcardPattern)
      ..writeCharCode(0);
  }
  result.writeCharCode(0);
  return result.toString();
}

Future<String?> _openMacOS({
  required String title,
  required List<FilePickerFilter> filters,
}) async {
  final String escapedTitle =
      title.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  final List<String> extensions = <String>[
    for (final FilePickerFilter filter in filters)
      for (final String extension in filter.extensions)
        if (extension != '*') extension.replaceFirst('.', ''),
  ];
  final String typeClause = extensions.isEmpty
      ? ''
      : ' of type {${extensions.map((String value) => '"$value"').join(', ')}}';
  final String script = 'POSIX path of (choose file with prompt '
      '"$escapedTitle"$typeClause)';
  final ProcessResult result =
      await Process.run('/usr/bin/osascript', <String>['-e', script]);
  if (result.exitCode == 0) return '${result.stdout}'.trim();
  if ('${result.stderr}'.toLowerCase().contains('user canceled')) return null;
  throw FilePickerException(
    operation: 'NSOpenPanel via osascript',
    platform: 'macos',
    errorCode: result.exitCode,
    reason: '${result.stderr}'.trim(),
  );
}

Future<String?> _openLinux({
  required String title,
  required List<FilePickerFilter> filters,
}) async {
  final List<_LinuxPickerCommand> commands = <_LinuxPickerCommand>[
    _LinuxPickerCommand(
      executable: 'zenity',
      arguments: <String>[
        '--file-selection',
        '--title=$title',
        for (final FilePickerFilter filter in filters)
          '--file-filter=${filter.label} | ${filter.wildcardPattern}',
      ],
    ),
    _LinuxPickerCommand(
      executable: 'kdialog',
      arguments: <String>[
        '--getopenfilename',
        '',
        filters
            .map((FilePickerFilter filter) =>
                '${filter.wildcardPattern}|${filter.label}')
            .join('\n'),
        '--title',
        title,
      ],
    ),
    _LinuxPickerCommand(
      executable: 'yad',
      arguments: <String>['--file-selection', '--title=$title'],
    ),
  ];
  final List<String> unavailable = <String>[];
  for (final _LinuxPickerCommand command in commands) {
    try {
      final ProcessResult result =
          await Process.run(command.executable, command.arguments);
      if (result.exitCode == 0) return '${result.stdout}'.trim();
      if (result.exitCode == 1) return null;
      throw FilePickerException(
        operation: command.executable,
        platform: 'linux',
        errorCode: result.exitCode,
        reason: '${result.stderr}'.trim(),
      );
    } on ProcessException {
      unavailable.add(command.executable);
    }
  }
  throw FilePickerException(
    operation: 'openFile',
    platform: 'linux',
    reason: 'no supported desktop chooser is installed '
        '(${unavailable.join(', ')} were not found)',
  );
}

String _baseName(String path) => path.replaceAll('\\', '/').split('/').last;

final class _LinuxPickerCommand {
  const _LinuxPickerCommand({
    required this.executable,
    required this.arguments,
  });

  final String executable;
  final List<String> arguments;
}
