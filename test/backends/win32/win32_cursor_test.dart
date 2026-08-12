/// A real window must own a real cursor from the moment it exists.
///
/// The window class is registered with `hCursor = 0` on purpose, so that
/// `WM_SETCURSOR` belongs to the framework rather than to Windows. That choice
/// has a consequence that is easy to miss and very visible when it bites: a
/// window that never sets a cursor answers `WM_SETCURSOR` with nothing, and
/// `DefWindowProc` has no class cursor to fall back on. The pointer then keeps
/// whatever the *previous* window left on screen - the horizontal resize arrow
/// from dragging a border, or the app-starting spinner - and the application
/// looks hung while it is in fact idle.
///
/// So the invariant is: `cursorHandle` is non-zero before the window is ever
/// shown, not after the first `setCursor` call.
library;

import 'dart:io' show Platform;

import 'package:dart_ui/src/backends/win32/win32_backend.dart';
import 'package:dart_ui/src/backends/win32/win32_window.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/platform/native_window.dart';
import 'package:test/test.dart';

void main() {
  group('cursor', () {
    late Win32WindowingBackend backend;

    setUp(() async {
      backend = Win32WindowingBackend();
      await backend.initialize();
    });

    tearDown(() async => backend.shutdown());

    test('a new window already has an arrow, before anyone sets one', () async {
      final window = await backend.createWindow(
        const WindowOptions(title: 'cursor test', size: Size(120, 80)),
      ) as Win32Window;

      expect(window.cursor, SystemCursor.arrow);
      expect(
        window.cursorHandle,
        isNot(0),
        reason: 'a zero handle makes WM_SETCURSOR a no-op and leaves whatever '
            'cursor the previous window was showing',
      );

      window.close();
    });

    test('setCursor replaces the handle and remembers the request', () async {
      final window = await backend.createWindow(
        const WindowOptions(title: 'cursor test', size: Size(120, 80)),
      ) as Win32Window;
      final int arrow = window.cursorHandle;

      window.setCursor(SystemCursor.text);

      expect(window.cursor, SystemCursor.text);
      expect(window.cursorHandle, isNot(0));
      expect(window.cursorHandle, isNot(arrow));

      window.close();
    });

    test('system cursors are shared, so the same one loads once', () async {
      final first = await backend.createWindow(
        const WindowOptions(title: 'a', size: Size(120, 80)),
      ) as Win32Window;
      final second = await backend.createWindow(
        const WindowOptions(title: 'b', size: Size(120, 80)),
      ) as Win32Window;

      // LoadCursorW returns a shared OS object; two windows asking for the
      // arrow must not end up with two handles to destroy.
      expect(second.cursorHandle, first.cursorHandle);

      first.close();
      second.close();
    });
  }, skip: Platform.isWindows ? false : 'needs a real Win32 window');
}
