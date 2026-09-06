/// Monitors and popup behaviour, against the real Windows on this machine.
///
/// The arithmetic of `ScreenInfo` is pinned everywhere by
/// `test/platform/screen_info_test.dart`; what only a real driver can answer
/// is whether the FFI bindings are right - whether `MONITORINFOEXW` has the
/// layout Windows writes into, whether `MonitorFromPoint` really takes its
/// POINT by value, whether the second window class was accepted with
/// `CS_DROPSHADOW` on it. A headless test cannot fail for any of those, which
/// is precisely why this file exists.
///
/// Nothing here asserts a resolution, a monitor count or a scale: this suite
/// has to pass on a laptop, on a docking station with three screens and on a
/// CI runner with a virtual display. What it asserts are the invariants that
/// hold on all of them.
library;

import 'dart:ffi';
import 'dart:io' show Platform;

// Deliberately not `package:dart_ui/dart_ui.dart`: nothing here involves a
// widget, and the umbrella would make this fail to load whenever the widget
// layer is mid-edit.
import 'package:dart_ui/src/backends/win32/win32_api.dart';
import 'package:dart_ui/src/backends/win32/win32_backend.dart';
import 'package:dart_ui/src/backends/win32/win32_window.dart';
import 'package:dart_ui/src/backends/win32/win32_window_class.dart';
import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/platform/native_window.dart'; // exports ScreenInfo
import 'package:dart_ui/src/platform/window_events.dart';
import 'package:test/test.dart';

/// `WM_MOUSEACTIVATE`, `MA_NOACTIVATE`, `WM_NCLBUTTONDOWN`, `HTTRANSPARENT`
/// and `HTCAPTION`, spelled out here because the backend keeps them private to
/// the one file that uses them.
const int _wmMouseactivate = 0x0021;
const int _maNoactivate = 3;
const int _wmNchittest = 0x0084;
const int _wmNclbuttondown = 0x00A1;
const int _htTransparent = -1;
const int _htCaption = 2;

/// `lParam` of a hit-test message: y in the high word, x in the low word.
int _at(int x, int y) => ((y & 0xFFFF) << 16) | (x & 0xFFFF);

void main() {
  group('the monitors of this machine', () {
    late Win32WindowingBackend backend;
    late List<ScreenInfo> screens;

    setUp(() async {
      backend = Win32WindowingBackend();
      await backend.initialize();
      screens = backend.screens;
    });

    tearDown(() async {
      await backend.shutdown();
    });

    test('the backend answers the ScreenProvider seam', () {
      expect(backend, isA<ScreenProvider>());
      expect(
        screens,
        isNotEmpty,
        reason: 'an interactive Windows session always has at least one '
            'monitor; an empty list here means EnumDisplayMonitors or the '
            'MONITORINFOEXW layout is wrong, not that the desktop has no '
            'screen',
      );
    });

    test('exactly one screen is primary', () {
      expect(screens.where((ScreenInfo s) => s.isPrimary), hasLength(1));
    });

    test('every work area is inside its own bounds', () {
      for (final ScreenInfo screen in screens) {
        expect(screen.workArea.left, greaterThanOrEqualTo(screen.bounds.left));
        expect(screen.workArea.top, greaterThanOrEqualTo(screen.bounds.top));
        expect(screen.workArea.right, lessThanOrEqualTo(screen.bounds.right));
        expect(screen.workArea.bottom, lessThanOrEqualTo(screen.bounds.bottom));
        expect(screen.workArea.isEmpty, isFalse);
      }
    });

    test('every scale is at least 1 and every screen has a device name', () {
      for (final ScreenInfo screen in screens) {
        // Windows has no sub-96-DPI display setting: a scale below 1 would
        // mean the DPI read failed and fell through to a zero.
        expect(screen.scale, greaterThanOrEqualTo(1));
        expect(screen.bounds.isEmpty, isFalse);
        expect(screen.name, isNotNull);
        expect(screen.name, isNotEmpty);
      }
    });

    test('the primary screen contains its own centre', () {
      final ScreenInfo primary =
          screens.firstWhere((ScreenInfo s) => s.isPrimary);
      expect(backend.screenAt(primary.bounds.center), primary);
    });

    test('a point far outside every monitor still lands on one', () {
      // The case a popup hits at the edge of the desktop, and the reason
      // `screenAt` never answers null while there is a screen.
      expect(backend.screenAt(const Offset(-100000, -100000)), isNotNull);
      expect(backend.screenAt(const Offset(100000, 100000)), isNotNull);
    });

    test('MonitorFromPoint agrees with the enumerated list', () {
      // Exercises the by-value POINT binding, which is the one place a wrong
      // ABI would silently return the primary monitor for every query.
      final ScreenInfo primary =
          screens.firstWhere((ScreenInfo s) => s.isPrimary);
      final ScreenInfo? found = backend.screenAtPhysical(
        (primary.bounds.center.dx * primary.scale).round(),
        (primary.bounds.center.dy * primary.scale).round(),
      );
      expect(found, primary);
    });

    test('reading the list twice gives the same answer', () {
      // Nothing is cached, so this is the assertion that "read it fresh every
      // time" is stable rather than merely uncached.
      expect(backend.screens, screens);
    });

    test('MonitorFromWindow answers for a real window', () async {
      final Win32Window window = await backend.createWindow(
        const WindowOptions(
          title: 'screens',
          size: Size(200, 120),
          visible: false,
        ),
      ) as Win32Window;
      try {
        final ScreenInfo? screen =
            backend.screenForWindowHandle(window.nativeHandle);
        expect(screen, isNotNull);
        expect(screens, contains(screen));
      } finally {
        window.close();
      }
    });

    test('there is no screen before initialize and none after shutdown',
        () async {
      final fresh = Win32WindowingBackend();
      expect(
        fresh.screens,
        isEmpty,
        reason: 'no loaded API means no honest answer; an empty list is the '
            'refusal, not an exception from inside a getter',
      );
      expect(fresh.screenAt(Offset.zero), isNull);
    });
  }, skip: Platform.isWindows ? false : 'needs the real Win32 display API');

  group('popup and tooltip windows', () {
    late Win32WindowingBackend backend;
    late Win32Api api;
    late Win32Window owner;

    setUp(() async {
      backend = Win32WindowingBackend();
      await backend.initialize();
      api = Win32Api.load().api!;
      owner = await backend.createWindow(
        const WindowOptions(
          title: 'popup owner',
          size: Size(320, 240),
          visible: false,
        ),
      ) as Win32Window;
    });

    tearDown(() async {
      await backend.shutdown();
    });

    Future<Win32Window> openPopup(WindowKind kind) async =>
        await backend.createWindow(
          WindowOptions(
            title: 'popup',
            size: const Size(120, 80),
            visible: false,
            owner: owner,
            kind: kind,
          ),
        ) as Win32Window;

    test('a popup is created on a second class that carries CS_DROPSHADOW',
        () async {
      final Win32Window popup = await openPopup(WindowKind.popup);

      expect(backend.popupWindowClassName, isNotNull);
      expect(popup.className, backend.popupWindowClassName);
      expect(
        popup.className,
        isNot(owner.className),
        reason: 'CS_DROPSHADOW is a class style, so sharing the class would '
            'put a drop shadow behind the application window too',
      );

      // Asked of Windows rather than of our own bookkeeping: the point of the
      // second registration is what the OS believes about the class.
      expect(
        api.getClassLongPtrW(popup.nativeHandle, gclStyle) & csDropshadow,
        csDropshadow,
      );
      expect(
        api.getClassLongPtrW(owner.nativeHandle, gclStyle) & csDropshadow,
        0,
        reason: 'the shared class must not have gained a shadow',
      );
    });

    test('a tooltip is created on the shadowed class as well', () async {
      final Win32Window tooltip = await openPopup(WindowKind.tooltip);
      expect(tooltip.className, backend.popupWindowClassName);
    });

    test('WM_MOUSEACTIVATE is refused by a popup and a tooltip', () async {
      for (final WindowKind kind in <WindowKind>[
        WindowKind.popup,
        WindowKind.tooltip,
      ]) {
        final Win32Window popup = await openPopup(kind);
        expect(
          popup.handleMessage(
            popup.nativeHandle,
            _wmMouseactivate,
            owner.nativeHandle,
            _htCaption,
          ),
          _maNoactivate,
          reason: '$kind must not take activation when it is clicked; '
              'WS_EX_NOACTIVATE only covers being shown',
        );
      }
    });

    test('WM_MOUSEACTIVATE is left to Windows for an ordinary window', () {
      expect(
        owner.handleMessage(
          owner.nativeHandle,
          _wmMouseactivate,
          owner.nativeHandle,
          _htCaption,
        ),
        api.defWindowProcW(
          owner.nativeHandle,
          _wmMouseactivate,
          owner.nativeHandle,
          _htCaption,
        ),
        reason: 'claiming this message for every window would stop a click '
            'from focusing the window it lands in',
      );
    });

    test('WM_NCHITTEST is HTTRANSPARENT for a tooltip only', () async {
      final Win32Window tooltip = await openPopup(WindowKind.tooltip);
      final Win32Window popup = await openPopup(WindowKind.popup);
      final Offset centre = tooltip.clientToScreen(const Offset(10, 10));
      final int lParam = _at(
        (centre.dx * tooltip.renderScale).round(),
        (centre.dy * tooltip.renderScale).round(),
      );

      expect(
        tooltip.handleMessage(tooltip.nativeHandle, _wmNchittest, 0, lParam),
        _htTransparent,
        reason: 'a tooltip that swallows a click is a tooltip the user has to '
            'click twice through',
      );

      // A menu is made of things to click, so it must answer normally - and so
      // must an ordinary window, which the message-coverage suite also pins.
      expect(
        popup.handleMessage(popup.nativeHandle, _wmNchittest, 0, lParam),
        isNot(_htTransparent),
      );
      expect(
        owner.handleMessage(owner.nativeHandle, _wmNchittest, 0, lParam),
        api.defWindowProcW(owner.nativeHandle, _wmNchittest, 0, lParam),
      );
    });

    test('WM_NCLBUTTONDOWN is reported and still handed to Windows', () async {
      final List<PlatformWindowEvent> events = <PlatformWindowEvent>[];
      final subscription = owner.events.listen(events.add);
      addTearDown(subscription.cancel);

      final int answer = owner.handleMessage(
        owner.nativeHandle,
        _wmNclbuttondown,
        _htCaption,
        _at(10, 10),
      );
      await Future<void>.delayed(Duration.zero);

      final WindowNonClientPressEvent press =
          events.whereType<WindowNonClientPressEvent>().single;
      expect(press.windowId, owner.id);
      expect(press.generation, owner.generation);
      expect(press.timestamp, isA<Duration>());

      expect(
        answer,
        api.defWindowProcW(
          owner.nativeHandle,
          _wmNclbuttondown,
          _htCaption,
          _at(10, 10),
        ),
        reason: 'swallowing the message would make the title bar undraggable '
            'whenever a menu was open',
      );
    });

    test('shutdown unregisters the popup class as well as the shared one',
        () async {
      final String? popupClassName = backend.popupWindowClassName;
      expect(popupClassName, isNotNull);

      await backend.shutdown();

      // The popup class borrows the base class's WndProc trampoline, so it has
      // to be gone before that trampoline is closed. Asking Windows is the
      // only way to know it actually was.
      final int instance = api.getModuleHandleW(nullptr);
      expect(
        Win32WindowClass.isRegistered(api, popupClassName!, instance),
        isFalse,
        reason: 'a class left registered points at a closed NativeCallable',
      );
    });
  }, skip: Platform.isWindows ? false : 'needs real Win32 windows');
}
