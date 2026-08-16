/// The messages the `WndProc` claims, pinned one by one at the `WndProc`.
///
/// Three production bugs in a row had the same shape - `WM_CHAR`,
/// `WM_LBUTTONDBLCLK`, `WM_MBUTTONDOWN` - and it was never the widget above
/// that was wrong. It was a message the backend did not translate, with a
/// consumer already waiting for the event it would have produced. A suite that
/// injects `PointerDownEvent`s by hand cannot see that class of bug at all,
/// because the thing that is missing is precisely the step it skips.
///
/// So this file asserts the *other* half: a message goes into the real
/// `handleMessage` of a real HWND, and what comes out - the LRESULT, or the
/// event on the window's stream - is checked. Every case here also shows what
/// the window would do **without** the handler, by asking `DefWindowProcW` the
/// same question, so that an assertion cannot quietly stop discriminating.
///
/// The full audit, including the messages that are *not* handled and what each
/// one costs, is the "Cobertura de mensagens do Win32" section of
/// `doc/architecture/overview.md`.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io' show Platform;

// Deliberately not `package:dart_ui/dart_ui.dart`: nothing this file asserts
// involves a widget, and importing the umbrella would make a backend test fail
// to load whenever the widget layer is mid-edit.
import 'package:dart_ui/src/backends/win32/win32_api.dart';
import 'package:dart_ui/src/backends/win32/win32_backend.dart';
import 'package:dart_ui/src/backends/win32/win32_constants.dart';
import 'package:dart_ui/src/backends/win32/win32_structs.dart';
import 'package:dart_ui/src/backends/win32/win32_window.dart';
import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/platform/input_events.dart';
import 'package:dart_ui/src/platform/native_window.dart';
import 'package:dart_ui/src/platform/window_events.dart';
import 'package:test/test.dart';

/// `lParam` of a mouse message: y in the high word, x in the low word.
int _at(int x, int y) => ((y & 0xFFFF) << 16) | (x & 0xFFFF);

void main() {
  // Runs everywhere, including Linux and macOS CI, because a wrong number here
  // would make the eventual handler dead code that nothing ever reaches - the
  // failure mode this whole file exists to catch, one level lower down.
  group('the message numbers the audit names', () {
    test('match the SDK', () {
      expect(wmSettingchange, 0x001A);
      expect(wmGetminmaxinfo, 0x0024);
      expect(wmDisplaychange, 0x007E);
      expect(wmNchittest, 0x0084);
      expect(wmUnichar, 0x0109);
      expect(wmSyscommand, 0x0112);
      expect(wmMousewheel, 0x020A);
      expect(wmXbuttondown, 0x020B);
      expect(wmXbuttonup, 0x020C);
      expect(wmXbuttondblclk, 0x020D);
      expect(wmMousehwheel, 0x020E);
      expect(wmEntersizemove, 0x0231);
      expect(wmExitsizemove, 0x0232);
      expect(wmGetdpiscaledsize, 0x02E4);
      expect(wmThemechanged, 0x031A);
    });

    test('and so do the parameters that ride in them', () {
      expect(wheelDelta, 120);
      expect(xbutton1, 0x0001);
      expect(xbutton2, 0x0002);
      expect(mkXbutton1, 0x0020);
      expect(mkXbutton2, 0x0040);
      expect(htClient, 1);
      expect(htCaption, 2);
    });
  });

  group('what the WndProc claims', () {
    late Win32WindowingBackend backend;
    late Win32Window window;
    late Win32Api api;
    late List<PlatformWindowEvent> events;
    late StreamSubscription<PlatformWindowEvent> subscription;

    setUp(() async {
      backend = Win32WindowingBackend();
      await backend.initialize();
      api = Win32Api.load().api!;
      window = await backend.createWindow(
        const WindowOptions(
          title: 'message coverage',
          size: Size(200, 120),
          visible: false,
        ),
      ) as Win32Window;
      events = <PlatformWindowEvent>[];
      subscription = window.events.listen(events.add);
    });

    tearDown(() async {
      await subscription.cancel();
      window.close();
      await backend.shutdown();
    });

    /// The real handler, plus a turn of the event loop so the broadcast stream
    /// has delivered whatever it produced.
    Future<int> send(int message, [int wParam = 0, int lParam = 0]) async {
      events.clear();
      final int result =
          window.handleMessage(window.handle, message, wParam, lParam);
      await Future<void>.delayed(Duration.zero);
      return result;
    }

    /// What this window would answer if the message fell through to the
    /// default arm - which is exactly what "the handler was deleted" looks
    /// like.
    int withoutHandler(int message, [int wParam = 0, int lParam = 0]) =>
        api.defWindowProcW(window.handle, message, wParam, lParam);

    test('WM_ERASEBKGND is claimed, so a resize cannot flash', () async {
      // Returning 1 means "I erased it", and nothing is erased: every pixel of
      // the client area comes from the DIB, so any erase at all would paint
      // over the framebuffer between the erase and the BitBlt.
      //
      // It is one half of a pair. The other half is `hbrBackground = 0` on the
      // class, which is what makes DefWindowProcW harmless *today* - and
      // exactly why this case must stay: it is what keeps the window correct
      // if a class brush is ever reintroduced, and it stops Windows asking
      // again on every paint.
      expect(await send(wmErasebkgnd), 1);
      expect(
        withoutHandler(wmErasebkgnd),
        isNot(1),
        reason: 'DefWindowProcW answers 0 - it did not erase; if it answered 1 '
            'by itself this assertion would be passing for the wrong reason',
      );
    });

    test('WM_SETCURSOR is claimed for the client area only', () async {
      // The class is registered with hCursor = 0 precisely so this message is
      // ours (see Win32WindowClass). Answering it is what stops the pointer
      // from keeping whatever the previous window left on screen.
      expect(await send(wmSetcursor, window.handle, htClient), 1);
      expect(
        withoutHandler(wmSetcursor, window.handle, htClient),
        isNot(1),
        reason: 'without the handler the client area sets no cursor at all',
      );

      // The frame is not ours: the resize arrows on the border and the arrow
      // over the caption are DefWindowProc's, and claiming them would replace
      // them with the client cursor.
      expect(
        await send(wmSetcursor, window.handle, htCaption),
        withoutHandler(wmSetcursor, window.handle, htCaption),
      );
    });

    test('WM_SETCURSOR answers with the cursor setCursor installed', () async {
      final int arrow = window.cursorHandle;
      window.setCursor(SystemCursor.text);

      expect(window.cursorHandle, isNot(arrow));
      expect(
        await send(wmSetcursor, window.handle, htClient),
        1,
        reason: 'a setCursor that only remembered the request would leave the '
            'I-beam to be undone by the next WM_SETCURSOR, which is the '
            'cursor flickering back to an arrow on every mouse move',
      );
    });

    test('an unclaimed message still reaches DefWindowProcW', () async {
      // The default arm is load-bearing, not a formality. WM_NCHITTEST is the
      // clearest witness: DefWindowProc answers it by comparing the point to
      // the window rectangle, and a default arm that returned 0 (HTNOWHERE)
      // instead would make the caption undraggable and the border unresizable
      // while every other message went on working.
      final Pointer<Win32Rect> rect = api.allocator<Win32Rect>();
      try {
        expect(api.getWindowRect(window.handle, rect), isNot(0));
        final int x = (rect.ref.left + rect.ref.right) ~/ 2;
        final int y = (rect.ref.top + rect.ref.bottom) ~/ 2;

        final int hit = await send(wmNchittest, 0, _at(x, y));
        expect(hit, isNot(0), reason: '0 is HTNOWHERE: the point is inside');
        expect(hit, withoutHandler(wmNchittest, 0, _at(x, y)));
      } finally {
        api.allocator.free(rect);
      }
    });

    test('WM_MOUSEWHEEL carries screen coordinates and is converted', () async {
      // The one mouse message whose lParam is *not* client-relative. Reading
      // it like the others puts the scroll at the window's position on the
      // desktop instead of under the pointer, so on a maximised window on a
      // second monitor it lands outside every scrollable there is.
      final Offset screen = window.clientToScreen(const Offset(10, 10));
      final int lParam = _at(
        (screen.dx * window.renderScale).round(),
        (screen.dy * window.renderScale).round(),
      );

      await send(wmMousewheel, wheelDelta << 16, lParam);
      final PointerScrollEvent scroll =
          events.whereType<PointerScrollEvent>().single;

      expect(scroll.logicalPosition.dx, closeTo(10, 1));
      expect(scroll.logicalPosition.dy, closeTo(10, 1));
      expect(scroll.scrollDeltaUnit, ScrollDeltaUnit.lines);
      // One detent is one line. The *sign* is deliberately not asserted here:
      // it is inverted today with respect to X11 and to the Down arrow key,
      // and correcting it belongs to `Win32Window._onPointerScroll`. See the
      // audit section of doc/architecture/overview.md.
      expect(scroll.scrollDelta.dy.abs(), 1.0);
      expect(
        scroll.scrollDelta.dx,
        0.0,
        reason: 'a vertical wheel with no modifier is vertical',
      );
    });

    test('Shift+WM_MOUSEWHEEL is redirected to the horizontal axis', () async {
      // The only path by which a horizontal ScrollViewer receives anything on
      // Windows today, because WM_MOUSEHWHEEL is unhandled.
      await send(wmMousewheel, (wheelDelta << 16) | mkShift, 0);
      final PointerScrollEvent scroll =
          events.whereType<PointerScrollEvent>().single;

      expect(scroll.scrollDelta.dy, 0.0);
      expect(scroll.scrollDelta.dx.abs(), 1.0);
    });

    test('WM_DPICHANGED moves to the rectangle Windows suggested', () async {
      // Ignoring the suggested rectangle is how a window changes physical size
      // when it crosses a monitor boundary: the scale is new and the pixel
      // count is not.
      final Pointer<Win32Rect> before = api.allocator<Win32Rect>();
      final Pointer<Win32Rect> suggested = api.allocator<Win32Rect>();
      try {
        expect(api.getWindowRect(window.handle, before), isNot(0));
        final int left = before.ref.left + 24;
        final int top = before.ref.top + 16;
        final int right = left + (before.ref.right - before.ref.left) + 40;
        final int bottom = top + (before.ref.bottom - before.ref.top) + 30;
        suggested.ref
          ..left = left
          ..top = top
          ..right = right
          ..bottom = bottom;

        // wParam is the new DPI in both words. Reusing the window's current
        // DPI keeps the scale fixed so that only the rectangle is under test.
        final int dpi = window.dpi;
        await send(wmDpichanged, (dpi << 16) | dpi, suggested.address);

        final Pointer<Win32Rect> after = api.allocator<Win32Rect>();
        try {
          expect(api.getWindowRect(window.handle, after), isNot(0));
          expect(after.ref.left, left);
          expect(after.ref.top, top);
          expect(after.ref.right, right);
          expect(after.ref.bottom, bottom);
          expect(
            <int>[after.ref.left, after.ref.right],
            isNot(<int>[before.ref.left, before.ref.right]),
            reason: 'a handler that ignored lParam would leave the window '
                'exactly where it was, and this test would pass on nothing',
          );
        } finally {
          api.allocator.free(after);
        }
      } finally {
        api.allocator
          ..free(before)
          ..free(suggested);
      }
    });
  }, skip: Platform.isWindows ? false : 'needs a real Win32 window');
}
