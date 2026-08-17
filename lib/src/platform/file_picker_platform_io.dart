library;

import 'dart:ffi';
import 'dart:io';

import '../ffi/native_memory.dart';
import 'file_picker_types.dart';

const int _ofnNoChangeDir = 0x00000008;
const int _ofnPathMustExist = 0x00000800;
const int _ofnFileMustExist = 0x00001000;
const int _ofnExplorer = 0x00080000;
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
typedef _CommDlgExtendedErrorNative = Uint32 Function();
typedef _CommDlgExtendedErrorDart = int Function();

Future<PickedFile?> openFile({
  required String title,
  required List<FilePickerFilter> filters,
  required int ownerWindowHandle,
}) async {
  final String? path;
  if (Platform.isWindows) {
    path = _openWindows(
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

String? _openWindows({
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
