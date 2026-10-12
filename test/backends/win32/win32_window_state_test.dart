/// [WindowStateControl] on a real HWND.
///
/// `ShowWindow` and `SetWindowPos` send `WM_SIZE` straight into the window
/// procedure on this thread, so every assertion below is about state the
/// window has already been told - no turn of the event loop, no sleep.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:dart_ui/src/backends/win32/win32_backend.dart';
import 'package:dart_ui/src/backends/win32/win32_window.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/platform/native_window.dart';
import 'package:dart_ui/src/platform/window_events.dart';
import 'package:test/test.dart';

void main() {
  group('requestState on a real Win32 window', () {
    late Win32WindowingBackend backend;
    late Win32Window window;
    late List<WindowState> reported;
    late StreamSubscription<PlatformWindowEvent> subscription;

    setUp(() async {
      backend = Win32WindowingBackend();
      await backend.initialize();
      window = await backend.createWindow(const WindowOptions(
        title: 'window state',
        size: Size(300, 200),
      )) as Win32Window;
      reported = <WindowState>[];
      subscription = window.events.listen((PlatformWindowEvent event) {
        if (event is WindowStateChangedEvent) reported.add(event.state);
      });
    });

    tearDown(() async {
      await subscription.cancel();
      window.close();
      await backend.shutdown();
    });

    test('maximise, minimise and restore go through ShowWindow', () async {
      expect(window.requestState(WindowState.maximised), isTrue);
      expect(window.state, WindowState.maximised);
      expect(window.requestState(WindowState.minimised), isTrue);
      expect(window.state, WindowState.minimised);
      expect(window.requestState(WindowState.normal), isTrue);
      expect(window.state, WindowState.normal);
      expect(window.clientSize.width, closeTo(300, 1));

      await Future<void>.delayed(Duration.zero);
      // Windows restores a window minimised from maximised to maximised
      // first; normal is the second step, and both are reported.
      expect(reported, <WindowState>[
        WindowState.maximised,
        WindowState.minimised,
        WindowState.maximised,
        WindowState.normal,
      ]);
    });

    test('fullscreen covers the monitor and leaving it restores the window',
        () async {
      final screen = backend.screenForWindowHandle(window.handle);
      expect(screen, isNotNull);

      expect(window.requestState(WindowState.fullscreen), isTrue);
      expect(window.state, WindowState.fullscreen);
      expect(window.clientSize.width, closeTo(screen!.bounds.width, 1));
      expect(window.clientSize.height, closeTo(screen.bounds.height, 1));
      // Asking twice is not a second save of the rectangle to return to.
      expect(window.requestState(WindowState.fullscreen), isTrue);

      expect(window.requestState(WindowState.normal), isTrue);
      expect(window.state, WindowState.normal);
      expect(window.clientSize.width, closeTo(300, 1));
      expect(window.clientSize.height, closeTo(200, 1));

      await Future<void>.delayed(Duration.zero);
      expect(reported, <WindowState>[
        WindowState.fullscreen,
        WindowState.normal,
      ]);
    });

    test('a maximised window goes back to maximised after fullscreen', () {
      window.requestState(WindowState.maximised);
      window.requestState(WindowState.fullscreen);
      expect(window.state, WindowState.fullscreen);
      window.requestState(WindowState.maximised);
      expect(window.state, WindowState.maximised);
    });

    test('a popup refuses', () async {
      final popup = await backend.createWindow(WindowOptions(
        size: const Size(100, 60),
        kind: WindowKind.popup,
        owner: window,
        visible: false,
      )) as Win32Window;
      addTearDown(popup.close);
      expect(popup.requestState(WindowState.maximised), isFalse);
      expect(popup.state, WindowState.normal);
    });
  }, skip: Platform.isWindows ? false : 'needs a real Win32 window');
}
