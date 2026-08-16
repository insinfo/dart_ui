/// The Windows clipboard, reached the way an application reaches it.
///
/// The bug: `Win32Clipboard` was written, tested by inspection and wired to
/// nothing. `ApplicationOptions.clipboard` defaulted to null, no example passed
/// one, and so every Ctrl+C and Ctrl+V in a real window failed at an
/// `UnavailableClipboard` - while Ctrl+A, which never leaves the process, kept
/// working and made the field look alive.
///
/// So what is asserted here is the *wiring*: that selecting the win32 backend
/// is enough to have a clipboard, that it is the real one, and that text
/// survives a round trip through `CF_UNICODETEXT` - surrogate pairs included,
/// since a code-unit-counting implementation cuts an emoji in half.
///
/// The system clipboard is process-global and belongs to whoever is at the
/// machine, so its previous contents are read first and put back at the end.
library;

import 'dart:io' show Platform;

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/win32/win32.dart';
import 'package:test/test.dart';

void main() {
  group('the win32 backend provides a clipboard', () {
    late Win32WindowingBackend backend;

    setUp(() async {
      backend = Win32WindowingBackend();
      await backend.initialize();
    });

    tearDown(() async => backend.shutdown());

    test('an initialized backend hands out the real one', () {
      expect(backend.clipboard, isA<Win32Clipboard>());
    });

    test('before initialize it refuses by name rather than crashing', () {
      final Clipboard early = Win32WindowingBackend().clipboard;
      expect(early, isA<UnavailableClipboard>());
      expect((early as UnavailableClipboard).reason, contains('initialized'));
    });

    test('text survives a round trip, emoji and all', () async {
      final Clipboard clipboard = backend.clipboard;
      const String value = 'dart_ui \u{1F600} acentuã̧o';

      String? previous;
      try {
        previous = await clipboard.readText();
      } on ClipboardException catch (error) {
        // The clipboard is a process-global lock and clipboard managers hold
        // it routinely. Skipped rather than failed: a busy clipboard is not a
        // defect in this code, and a retry loop is what the port forbids.
        markTestSkipped('the clipboard is held by another process: $error');
        return;
      }

      try {
        await clipboard.writeText(value);
        expect(await clipboard.readText(), value);
      } finally {
        if (previous != null) await clipboard.writeText(previous);
      }
    });
  }, skip: Platform.isWindows ? false : 'needs Windows');
}
