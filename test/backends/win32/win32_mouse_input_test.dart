/// The second press of a double click is a message of its own, and it is the
/// only place that press exists.
///
/// The bug this file exists to prevent: the window class is registered with
/// `CS_DBLCLKS`, which makes Windows send `WM_LBUTTONDBLCLK` **instead of** a
/// second `WM_LBUTTONDOWN`. Nothing handled that message, so the framework saw
/// one press where the user made two, and a double click could never select a
/// word - however correct the counting in `RenderTextField` was.
///
/// It survived a full widget suite because every test of that counting
/// synthesized two `PointerDownEvent`s by hand, which is precisely the event
/// the backend was failing to produce. So these cases drive the real `WndProc`
/// switch of a real window: a message goes in and the window's event stream is
/// asserted, which is the only level at which "the backend never produced it"
/// is a statement a test can make.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/win32/win32_backend.dart';
import 'package:dart_ui/src/backends/win32/win32_constants.dart';
import 'package:dart_ui/src/backends/win32/win32_window.dart';
import 'package:test/test.dart';

/// `lParam` of a mouse message: y in the high word, x in the low word.
int _at(int x, int y) => ((y & 0xFFFF) << 16) | (x & 0xFFFF);

void main() {
  group('mouse messages become pointer events', () {
    late Win32WindowingBackend backend;
    late Win32Window window;
    late List<PlatformWindowEvent> events;
    late StreamSubscription<PlatformWindowEvent> subscription;

    setUp(() async {
      backend = Win32WindowingBackend();
      await backend.initialize();
      window = await backend.createWindow(
        const WindowOptions(
          title: 'mouse input',
          size: Size(120, 80),
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

    /// Sends [message] through the real message handler and lets the broadcast
    /// stream deliver whatever it produced.
    Future<List<PointerEvent>> send(int message, [int lParam = 0]) async {
      events.clear();
      window.handleMessage(window.handle, message, 0, lParam);
      await Future<void>.delayed(Duration.zero);
      return events.whereType<PointerEvent>().toList();
    }

    test('a double click is two presses, not one', () async {
      // The reported bug, at the source. Windows sends the down for the first
      // press and WM_LBUTTONDBLCLK for the second; if the second produces
      // nothing, no consumer can ever count to two.
      final List<PointerEvent> first = await send(wmLbuttondown, _at(30, 12));
      expect(first.whereType<PointerDownEvent>(), hasLength(1));

      final List<PointerEvent> second =
          await send(wmLbuttondblclk, _at(30, 12));
      expect(
        second.whereType<PointerDownEvent>(),
        hasLength(1),
        reason: 'WM_LBUTTONDBLCLK replaces the second WM_LBUTTONDOWN; a window '
            'that ignores it loses the press entirely',
      );
    });

    test('the second press carries the count Windows made', () async {
      await send(wmLbuttondown, _at(30, 12));
      final PointerDownEvent down = (await send(wmLbuttondblclk, _at(30, 12)))
          .whereType<PointerDownEvent>()
          .single;

      expect(down.clickCount, 2);
      expect(down.button, PointerButton.primary);
      // The position still comes from lParam, not from the last move.
      expect(down.logicalPosition.dx, closeTo(30 / window.renderScale, 0.001));
      expect(down.logicalPosition.dy, closeTo(12 / window.renderScale, 0.001));
    });

    test('an ordinary press reports a count of one', () async {
      final PointerDownEvent down = (await send(wmLbuttondown, _at(4, 4)))
          .whereType<PointerDownEvent>()
          .single;

      expect(down.clickCount, 1);
    });

    test('the right and middle buttons double click too', () async {
      final PointerDownEvent right = (await send(wmRbuttondblclk, _at(8, 8)))
          .whereType<PointerDownEvent>()
          .single;
      expect(right.button, PointerButton.secondary);
      expect(right.clickCount, 2);

      final PointerDownEvent middle = (await send(wmMbuttondblclk, _at(8, 8)))
          .whereType<PointerDownEvent>()
          .single;
      expect(middle.button, PointerButton.middle);
      expect(middle.clickCount, 2);
    });

    test('the middle button reports its ordinary press and release', () async {
      // Handled for the same reason the double click is: a WM_MBUTTONDBLCLK
      // that produced a press whose WM_MBUTTONDOWN never did would be a stream
      // where the second click of a pair exists and the first does not.
      expect(
        (await send(wmMbuttondown, _at(9, 9)))
            .whereType<PointerDownEvent>()
            .single
            .button,
        PointerButton.middle,
      );
      expect(
        (await send(wmMbuttonup, _at(9, 9)))
            .whereType<PointerUpEvent>()
            .single
            .button,
        PointerButton.middle,
      );
    });

    test('a double click still releases, so nothing stays captured', () async {
      await send(wmLbuttondown, _at(30, 12));
      await send(wmLbuttonup, _at(30, 12));
      await send(wmLbuttondblclk, _at(30, 12));

      final List<PointerEvent> up = await send(wmLbuttonup, _at(30, 12));
      expect(up.whereType<PointerUpEvent>(), hasLength(1));
      expect(
        (await send(wmCapturechanged)).whereType<PointerCancelEvent>(),
        isEmpty,
        reason: 'the press begun by the DBLCLK was released normally, so no '
            'cancel is owed',
      );
    });
  }, skip: Platform.isWindows ? false : 'needs a real Win32 window');
}
