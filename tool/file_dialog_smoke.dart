/// Exercises the Windows Common Item Dialog - `IFileOpenDialog` and
/// `IFileSaveDialog` - and prints every HRESULT by name.
///
/// **By default it opens nothing.** It creates both dialog objects, queries
/// `IFileDialog` on them, runs the whole configuration sequence
/// (`SetTitle`, `SetFileTypes`, `SetFileTypeIndex`, `GetOptions`/`SetOptions`,
/// `SetFileName`, `SetDefaultExtension`, `SetFolder`), releases everything and
/// exits. That covers every mistake this code can make on its own - a mistyped
/// CLSID, a vtable slot off by one, a filter table whose two `LPCWSTR`s are
/// swapped, an extension the shell rejects - and none of it steals the focus of
/// whoever is at the keyboard.
///
/// `--interactive` is the opt-in that actually shows the dialogs. It is
/// deliberately not the default and must not be run by an agent or from CI: it
/// is modal, it takes the foreground, and it waits for a human. Run it yourself
/// when you want to check the four things no HRESULT can tell you:
///
///   1. the dialog has the left-hand navigation pane with **your pinned
///      places** - the whole reason for replacing `GetOpenFileNameW`;
///   2. the file-type combo has the rows the caller asked for, spelled the way
///      the caller spelled them;
///   3. Ctrl-clicking two files in the multiple-selection step returns two
///      paths, not one;
///   4. the save step returns a path ending in `.svg` when you accept the
///      suggested name without typing an extension, and asks before
///      overwriting an existing file.
///
/// Usage:
///
///     dart run tool/file_dialog_smoke.dart
///     dart run tool/file_dialog_smoke.dart --interactive
///     dart run tool/file_dialog_smoke.dart --interactive open save
///     dart run tool/file_dialog_smoke.dart --directory=C:\some\folder
library;

import 'dart:io';

import 'package:dart_ui/src/ffi/com.dart';
import 'package:dart_ui/src/platform/file_picker_types.dart';
import 'package:dart_ui/src/platform/file_picker_windows_com.dart';

const List<FilePickerFilter> _filters = <FilePickerFilter>[
  FilePickerFilter(
    label: 'Vector drawings (*.svg;*.cdr)',
    extensions: <String>['svg', 'cdr'],
  ),
  FilePickerFilter(label: 'PDF (*.pdf)', extensions: <String>['pdf']),
  FilePickerFilter(label: 'All files', extensions: <String>['*']),
];

void main(List<String> arguments) {
  if (!Platform.isWindows) {
    stdout.writeln('The Common Item Dialog is a Windows API; nothing to do on '
        '${Platform.operatingSystem}.');
    exit(0);
  }

  final bool interactive = arguments.contains('--interactive');
  final Set<String> steps =
      arguments.where((String value) => !value.startsWith('--')).toSet();
  bool wants(String step) => steps.isEmpty || steps.contains(step);
  final String? directory = arguments
      .firstWhere((String value) => value.startsWith('--directory='),
          orElse: () => '')
      .split('=')
      .elementAtOrNull(1);
  final String startIn = directory ??
      (Platform.environment['USERPROFILE'] == null
          ? ''
          : '${Platform.environment['USERPROFILE']}\\Documents');

  final int failures = _probe(startIn);
  if (!interactive) {
    stdout.writeln('\nNo dialog was shown. Pass --interactive to open them, '
        'and read the checklist at the top of this file for what to look at '
        'while they are open - none of it is provable from an HRESULT.');
    exit(failures == 0 ? 0 : 1);
  }

  stdout.writeln('\n--interactive: the next dialogs take the foreground and '
      'wait for you. Cancel any you do not want; a cancel is a valid outcome.');
  if (wants('open')) {
    _interactiveStep(
      'open, single selection',
      () => showWindowsFileDialog(
        save: false,
        title: 'Smoke: open one file',
        filters: _filters,
        initialDirectory: directory,
      ),
    );
  }
  if (wants('multi')) {
    _interactiveStep(
      'open, multiple selection - Ctrl-click two files',
      () => showWindowsFileDialog(
        save: false,
        title: 'Smoke: open several files',
        filters: _filters,
        allowMultiple: true,
        initialDirectory: directory,
      ),
    );
  }
  if (wants('save')) {
    _interactiveStep(
      'save, suggested name "drawing" and default extension svg',
      () => showWindowsFileDialog(
        save: true,
        title: 'Smoke: save a drawing',
        filters: _filters,
        suggestedName: 'drawing',
        defaultExtension: 'svg',
        initialDirectory: startIn.isEmpty ? null : startIn,
      ),
    );
  }
  exit(failures == 0 ? 0 : 1);
}

/// Creates, configures and releases both dialogs without showing either.
///
/// Returns how many calls failed, so the exit code says whether the COM path is
/// intact on this machine without anybody having to read the list.
int _probe(String startIn) {
  int failures = 0;
  for (final bool save in <bool>[false, true]) {
    final String which = save ? 'IFileSaveDialog' : 'IFileOpenDialog';
    stdout.writeln('\n=== $which, created and configured, never shown ===');
    final List<WindowsFileDialogStep> trace = probeWindowsFileDialog(
      save: save,
      title: 'Smoke: $which',
      filters: _filters,
      suggestedName: save ? 'drawing' : '',
      defaultExtension: save ? 'svg' : null,
      allowMultiple: !save,
      initialDirectory: startIn.isEmpty ? null : startIn,
    );
    for (final WindowsFileDialogStep step in trace) {
      final bool ok = succeeded(step.hresult);
      final String verdict;
      if (ok) {
        verdict = 'ok  ';
      } else if (step.required) {
        failures++;
        verdict = 'FAIL';
      } else {
        // A refusal that is expected: QueryInterface(IID_IFileDialog) is one.
        verdict = 'note';
      }
      stdout.writeln('  $verdict  ${step.call} '
          '-> ${hresultName(step.hresult)}');
    }
    if (trace.isEmpty) {
      failures++;
      stdout.writeln('  FAIL  nothing ran at all');
    }
  }
  stdout.writeln('\n$failures failing call(s). Every object created above was '
      'released before this line printed.');
  return failures;
}

void _interactiveStep(String name, WindowsFileDialogResult Function() run) {
  stdout.writeln('\n=== $name ===');
  final Stopwatch clock = Stopwatch()..start();
  final WindowsFileDialogResult result = run();
  clock.stop();
  stdout
    ..writeln('status   : ${result.status.name}')
    ..writeln('hresult  : ${hresultName(result.hresult)}');
  if (result.detail != null) stdout.writeln('detail   : ${result.detail}');
  stdout.writeln('paths    : ${result.paths.length}');
  for (final String path in result.paths) {
    final File file = File(path);
    final String size =
        file.existsSync() ? '${file.lengthSync()} bytes' : 'does not exist yet';
    stdout.writeln('           $path ($size)');
  }
  stdout.writeln('elapsed  : ${clock.elapsedMilliseconds} ms');
  if (result.shouldFallBackToLegacy) {
    stdout.writeln('NOTE: the modern dialog was unavailable, so FilePicker '
        'would have run GetOpenFileNameW here.');
  }
}
