import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/ffi/com.dart';
import 'package:dart_ui/src/platform/file_picker_platform_io.dart';
import 'package:dart_ui/src/platform/file_picker_windows_com.dart';
import 'package:test/test.dart';

void main() {
  test('file filters expose native wildcards and browser accept values', () {
    const FilePickerFilter pdf = FilePickerFilter(
      label: 'PDF documents',
      extensions: <String>['pdf', '.xps'],
    );
    const FilePickerFilter all = FilePickerFilter(
      label: 'All files',
      extensions: <String>['*'],
    );

    expect(pdf.wildcardPattern, '*.pdf;*.xps');
    expect(pdf.accept, '.pdf,.xps');
    expect(all.wildcardPattern, '*.*');
    expect(all.accept, isEmpty);
  });

  test('picked files have one byte-oriented contract on every platform', () {
    final PickedFile file = PickedFile(
      name: 'relatório.pdf',
      path: r'C:\docs\relatório.pdf',
      bytes: Uint8List.fromList(<int>[0x25, 0x50, 0x44, 0x46]),
    );

    expect(file.name, 'relatório.pdf');
    expect(file.path, endsWith('relatório.pdf'));
    expect(file.size, 4);
  });

  // The Windows dialog's identifiers, its classification of an HRESULT and its
  // filter construction are the three halves of it that a machine with no
  // desktop can still be wrong about, and all three fail silently: a
  // transposed digit in a CLSID is E_NOINTERFACE forever, a cancel read as a
  // failure is an exception in the user's face, and a swapped filter pair is a
  // dialog that lists nothing.
  group('windows common item dialog', () {
    test('identifiers keep the spelling their headers use', () {
      // Not a round trip through the same string: these are read off
      // `shobjidl_core.h`, and the assertion exists so that a later edit that
      // transposes a digit fails here rather than on a user's machine.
      expect('$clsidFileOpenDialog', 'dc1c5a9c-e88a-4dde-a5a1-60f82a20aef7');
      expect('$clsidFileSaveDialog', 'c0b4e2f3-ba21-4773-8dba-335ec946eb8b');
      expect('$iidIFileDialog', '42f85136-db7e-439c-85f1-e4075d135fc5');
      expect('$iidIFileOpenDialog', 'd57c7288-d4ad-4768-be02-9d969532d960');
      expect('$iidIFileSaveDialog', '84bccd23-5fde-4cdb-aea4-af64b83d78ab');
      expect('$iidIShellItem', '43826d1e-e718-42ee-bc55-a1e261c37bfe');
      expect('$iidIShellItemArray', 'b63ea76d-1f85-456f-a19c-48159efa858b');
      expect('$iidIModalWindow', 'b4db1657-70d7-485e-8e3e-6fcb5a5c1802');
    });

    test('identifiers reach memory in the layout the C struct has', () {
      // The first three groups are numbers and go in back to front; the last
      // two are bytes and go in as written. Sixteen bytes taken straight from
      // the text would be wrong in three groups out of five.
      expect(
        clsidFileOpenDialog.toBytes(),
        <int>[
          0x9C, 0x5A, 0x1C, 0xDC, //
          0x8A, 0xE8, //
          0xDE, 0x4D, //
          0xA5, 0xA1, 0x60, 0xF8, 0x2A, 0x20, 0xAE, 0xF7,
        ],
      );
      expect(
        iidIShellItem.toBytes(),
        <int>[
          0x1E, 0x6D, 0x82, 0x43, //
          0x18, 0xE7, //
          0xEE, 0x42, //
          0xBC, 0x55, 0xA1, 0xE2, 0x61, 0xC3, 0x7B, 0xFE,
        ],
      );
    });

    test('a cancel is told apart from a failure', () {
      // 0x800704C7 written as a Dart literal is positive, because Dart
      // integers are 64-bit; the signed form is what dart:ffi hands back. Both
      // have to classify the same way or the check stops firing.
      expect(isCancelledHresult(0x800704C7), isTrue);
      expect(isCancelledHresult(-2147023673), isTrue);
      expect(isCancelledHresult(hresultCancelled), isTrue);

      expect(isCancelledHresult(sOk), isFalse);
      expect(isCancelledHresult(eFail), isFalse);
      expect(isCancelledHresult(eNoInterface), isFalse);
      // ERROR_ACCESS_DENIED, one away from ERROR_CANCELLED in the same
      // facility: a range check instead of an equality would swallow it.
      expect(isCancelledHresult(0x80070005), isFalse);
    });

    test('only an unavailable dialog sends the caller to the legacy path', () {
      expect(
        const WindowsFileDialogResult.unavailable('CoCreateInstance refused')
            .shouldFallBackToLegacy,
        isTrue,
      );
      expect(
        const WindowsFileDialogResult.cancelled().shouldFallBackToLegacy,
        isFalse,
      );
      expect(
        const WindowsFileDialogResult(
          status: WindowsFileDialogStatus.selected,
          paths: <String>[r'C:\a.svg'],
        ).shouldFallBackToLegacy,
        isFalse,
      );
      // A failure is reported, not retried on the legacy dialog: the modern
      // one was there and answered, so falling back would hide the answer.
      expect(
        const WindowsFileDialogResult(
          status: WindowsFileDialogStatus.failed,
          hresult: eFail,
        ).shouldFallBackToLegacy,
        isFalse,
      );
    });

    test('a cancelled result carries no path', () {
      const WindowsFileDialogResult cancelled =
          WindowsFileDialogResult.cancelled();
      expect(cancelled.path, isNull);
      expect(cancelled.paths, isEmpty);
      expect(cancelled.hresult, hresultCancelled);
    });

    test('filter rows carry the same patterns the legacy string did', () {
      const List<FilePickerFilter> filters = <FilePickerFilter>[
        FilePickerFilter(
          label: 'Vector drawings',
          extensions: <String>['svg', '.cdr'],
        ),
        FilePickerFilter(label: 'All files', extensions: <String>['*']),
      ];

      expect(windowsFilterSpecs(filters), <({String label, String pattern})>[
        (label: 'Vector drawings', pattern: '*.svg;*.cdr'),
        (label: 'All files', pattern: '*.*'),
      ]);
    });

    test('no filters still means every file, as the legacy path did', () {
      // SetFileTypes with a count of zero leaves the dialog with no type combo
      // at all, which reads to the user as "this application accepts nothing".
      expect(
          windowsFilterSpecs(const <FilePickerFilter>[]),
          <({String label, String pattern})>[
            (label: 'All files', pattern: '*.*'),
          ]);
    });

    test('the default extension loses its dot, as lpstrDefExt required', () {
      expect(normalizedDefaultExtension('.svg'), 'svg');
      expect(normalizedDefaultExtension('svg'), 'svg');
      expect(normalizedDefaultExtension(null), isNull);
      expect(normalizedDefaultExtension(''), isNull);
      // A lone dot would become an empty extension and a file named
      // "drawing." - refused rather than passed on.
      expect(normalizedDefaultExtension('.'), isNull);
    });

    test('a suggested name splits into the folder and the name', () {
      // GetSaveFileNameW took one buffer that meant both; IFileSaveDialog has
      // SetFolder and SetFileName, so the split happens here and a caller that
      // passed an absolute path keeps the directory it was counting on.
      expect(splitSuggestedPath('drawing.svg'),
          (directory: null, name: 'drawing.svg'));
      expect(splitSuggestedPath(r'C:\docs\drawing.svg'),
          (directory: r'C:\docs\', name: 'drawing.svg'));
      expect(splitSuggestedPath('C:/docs/drawing.svg'),
          (directory: 'C:/docs/', name: 'drawing.svg'));
      expect(splitSuggestedPath(r'C:\drawing.svg'),
          (directory: r'C:\', name: 'drawing.svg'));
      expect(splitSuggestedPath(''), (directory: null, name: ''));
    });

    test(
      'both dialogs create, configure and release without showing anything',
      () {
        // The one test that touches COM. It stops short of Show - a modal
        // window in a test run is a hung suite - but it does prove the CLSIDs
        // resolve, the vtable slots land on the methods they name, and the
        // filter table is laid out the way SetFileTypes reads it. A slot off
        // by one answers E_INVALIDARG or worse here.
        for (final bool save in <bool>[false, true]) {
          final List<WindowsFileDialogStep> trace = probeWindowsFileDialog(
            save: save,
            title: 'test',
            filters: const <FilePickerFilter>[
              FilePickerFilter(label: 'SVG', extensions: <String>['svg']),
              FilePickerFilter(label: 'All files', extensions: <String>['*']),
            ],
            suggestedName: save ? 'drawing' : '',
            defaultExtension: save ? '.svg' : null,
            allowMultiple: !save,
            initialDirectory: Directory.current.path,
          );

          final List<WindowsFileDialogStep> broken = <WindowsFileDialogStep>[
            for (final WindowsFileDialogStep step in trace)
              if (step.required && failed(step.hresult)) step,
          ];
          expect(
            broken,
            isEmpty,
            reason: broken
                .map((WindowsFileDialogStep step) =>
                    '${step.call} -> ${hresultName(step.hresult)}')
                .join('\n'),
          );
          expect(
            trace.map((WindowsFileDialogStep step) => step.call),
            contains(startsWith('IFileDialog::SetFileTypes')),
          );
        }
      },
      skip: Platform.isWindows
          ? false
          : 'the Common Item Dialog is a Windows API',
    );
  });
}
