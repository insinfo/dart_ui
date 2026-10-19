/// Real HWND checks for integrated tabs and the retained system frame.
library;

import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:dart_ui/src/backends/win32/win32_api.dart';
import 'package:dart_ui/src/backends/win32/win32_backend.dart';
import 'package:dart_ui/src/backends/win32/win32_constants.dart';
import 'package:dart_ui/src/backends/win32/win32_structs.dart';
import 'package:dart_ui/src/backends/win32/win32_window.dart';
import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/platform/input_events.dart';
import 'package:dart_ui/src/platform/native_window.dart';
import 'package:dart_ui/src/platform/window_events.dart';
import 'package:test/test.dart';

void main() {
  group('hidden Win32 title bar', () {
    late Win32WindowingBackend backend;
    late Win32Window window;
    late Win32Api api;

    setUp(() async {
      backend = Win32WindowingBackend();
      await backend.initialize();
      api = Win32Api.load().api!;
      window = await backend.createWindow(const WindowOptions(
        title: 'integrated title bar',
        titleBar: WindowTitleBar.hidden,
        size: Size(640, 400),
        minimumSize: Size(300, 200),
      )) as Win32Window;
    });
    tearDown(() async {
      window.close();
      await backend.shutdown();
    });

    int hit(Offset local) {
      final screen = window.clientToScreen(local);
      final x = (screen.dx * window.renderScale).round();
      final y = (screen.dy * window.renderScale).round();
      return window.handleMessage(
          window.handle, wmNchittest, 0, (x & 0xffff) | ((y & 0xffff) << 16));
    }

    test('caption removed, client bounds exact, caption hit targets retained',
        () async {
      expect(window.isTitleBarHidden, isTrue);
      expect(window.clientSize, const Size(640, 400));
      final rect = api.allocator<Win32Rect>();
      try {
        expect(api.getWindowRect(window.handle, rect), isNot(0));
        final origin = window.clientToScreen(Offset.zero);
        expect((origin.dy * window.renderScale - rect.ref.top).round(), 1);
      } finally {
        api.allocator.free(rect);
      }
      final buttons = window.systemButtons.value;
      expect(buttons.isEmpty, isFalse);
      expect(buttons.left, greaterThan(window.clientSize.width / 2));
      expect(hit(Offset(buttons.right - 15, buttons.center.dy)), 20);
      expect(hit(Offset(buttons.right - 69, buttons.center.dy)), 9);
      expect(hit(Offset(buttons.right - 115, buttons.center.dy)), 8);
      expect(window.beginMove(), isFalse); // No held primary press to quote.
      expect(hit(const Offset(120, 20)), htClient);
      expect(hit(const Offset(320, 1)), 12); // HTTOP
    });

    test('painted caption presses reach widgets and release native capture',
        () async {
      final events = <PlatformWindowEvent>[];
      final subscription = window.events.listen(events.add);
      addTearDown(subscription.cancel);
      final buttons = window.systemButtons.value;
      for (final hitCode in [8, 9, 20]) {
        final local = Offset(
            buttons.left +
                (hitCode == 8
                    ? 23
                    : hitCode == 9
                        ? 69
                        : 115),
            buttons.center.dy);
        final screen = window.clientToScreen(local);
        int pack(double x, double y) =>
            ((x * window.renderScale).round() & 0xffff) |
            (((y * window.renderScale).round() & 0xffff) << 16);
        events.clear();
        api.postMessageW(
            window.handle, 0x00A1, hitCode, pack(screen.dx, screen.dy));
        // Capture changes the normal release into a client mouse message.
        api.postMessageW(
            window.handle, wmLbuttonup, 0, pack(local.dx, local.dy));
        backend.pumpEvents();
        await Future<void>.delayed(Duration.zero);
        expect(events.whereType<WindowNonClientPressEvent>(), hasLength(1));
        final down = events.whereType<PointerDownEvent>().single;
        expect(
            down.logicalPosition.dx, closeTo(local.dx, 1 / window.renderScale));
        expect(
            down.logicalPosition.dy, closeTo(local.dy, 1 / window.renderScale));
        expect(events.whereType<PointerUpEvent>(), hasLength(1));
        expect(api.getCapture(), 0,
            reason: 'a caption press cannot retain the mouse');
        expect(window.state, WindowState.normal,
            reason:
                'the widget command, not an invisible system caption, owns activation');
      }
    });

    test(
        'caption cursor is an arrow and does not replace the client text cursor',
        () {
      final user = DynamicLibrary.open('user32.dll');
      final current =
          user.lookupFunction<IntPtr Function(), int Function()>('GetCursor');
      final classCursor = user.lookupFunction<IntPtr Function(IntPtr, Int32),
          int Function(int, int)>('GetClassLongPtrW');
      expect(classCursor(window.handle, -12), isNot(0),
          reason: 'native messages need a class cursor fallback');
      final arrow = window.cursorHandle;
      window.setCursor(SystemCursor.text);
      final text = window.cursorHandle;
      for (final code in [8, 9, 20]) {
        expect(
            window.handleMessage(window.handle, wmSetcursor, window.handle,
                code | (wmMousemove << 16)),
            1);
        expect(current(), arrow);
        expect(window.cursorHandle, text,
            reason: 'the client cursor request is retained');
      }
      window.handleMessage(window.handle, wmSetcursor, window.handle,
          htClient | (wmMousemove << 16));
      expect(current(), text);
    });

    test('maximise, restore, owned dialog closure preserve owner geometry',
        () async {
      window.toggleMaximized();
      expect(window.state, WindowState.maximised);
      final before = window.clientSize;
      final origin = window.clientToScreen(Offset.zero);
      final dialog = await backend.createWindow(WindowOptions(
        owner: window,
        kind: WindowKind.dialog,
        size: const Size(300, 200),
      ));
      dialog.close();
      window.activate();
      expect(window.state, WindowState.maximised);
      expect(window.clientSize, before);
      expect(window.clientToScreen(Offset.zero), origin);
      expect(hit(const Offset(120, 1)), htClient);
      window.toggleMaximized();
      expect(window.state, WindowState.normal);
      expect(window.clientSize, const Size(640, 400));
    });

    test('fullscreen removes button reservation and restores it afterwards',
        () {
      window.requestState(WindowState.fullscreen);
      // A full-screen client has no system controls over its content.
      expect(window.systemButtons.value, Rect.zero);
      window.requestState(WindowState.normal);
      expect(window.systemButtons.value.isEmpty, isFalse);
      expect(window.clientSize, const Size(640, 400));
    });
  }, skip: Platform.isWindows ? false : 'needs DWM on a real Windows desktop');
}
