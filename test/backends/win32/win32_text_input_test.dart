/// `WM_CHAR` is where typed text comes from, and the only place it comes from.
///
/// The bug this file exists to prevent came from the other direction: the
/// framework built characters out of `WM_KEYDOWN`'s virtual key code, so the
/// numeric keypad typed `abc` and no accented character could be typed at all.
/// `WM_CHAR` is Windows handing over the result of the layout, Shift, CapsLock,
/// NumLock, AltGr and any pending dead key - work this process cannot redo and
/// must not try to.
///
/// These cases drive the real `WndProc` switch of a real window: a message goes
/// in and the window's event stream is asserted, so a regression that stopped
/// handling `WM_CHAR`, or started handling `WM_SYSCHAR`, fails here.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/win32/win32_backend.dart';
import 'package:dart_ui/src/backends/win32/win32_constants.dart';
import 'package:dart_ui/src/backends/win32/win32_window.dart';
import 'package:test/test.dart';

/// GRINNING FACE: U+1F600, delivered as two `WM_CHAR` messages.
const int _emojiHigh = 0xD83D;
const int _emojiLow = 0xDE00;

void main() {
  group('WM_CHAR becomes text', () {
    late Win32WindowingBackend backend;
    late Win32Window window;
    late List<PlatformWindowEvent> events;
    late StreamSubscription<PlatformWindowEvent> subscription;

    setUp(() async {
      backend = Win32WindowingBackend();
      await backend.initialize();
      window = await backend.createWindow(
        const WindowOptions(
          title: 'text input',
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
    Future<List<TextInputEvent>> send(
      int message,
      int wParam, [
      int lParam = 0,
    ]) async {
      events.clear();
      window.handleMessage(window.handle, message, wParam, lParam);
      await Future<void>.delayed(Duration.zero);
      return events.whereType<TextInputEvent>().toList();
    }

    test('an ASCII character arrives as itself, in the case sent', () async {
      expect((await send(wmChar, 0x61)).single.text, 'a');
      expect(
        (await send(wmChar, 0x41)).single.text,
        'A',
        reason: 'Windows applied Shift; this process did not have to guess',
      );
    });

    test('a character no US key carries still arrives', () async {
      // 'ç' (U+00E7) and '€' (U+20AC): a Brazilian layout and an AltGr chord.
      expect((await send(wmChar, 0xE7)).single.text, 'ç');
      expect((await send(wmChar, 0x20AC)).single.text, '€');
    });

    test('an astral character is one event built from two messages', () async {
      expect(
        await send(wmChar, _emojiHigh),
        isEmpty,
        reason: 'emitting the high surrogate alone would deliver half a '
            'character, and TextEditingValue refuses that offset',
      );

      final List<TextInputEvent> completed = await send(wmChar, _emojiLow);
      expect(completed.single.text, '\u{1F600}');
      expect(completed.single.text.length, 2);
      expect(completed.single.text.runes.length, 1);
    });

    test('control characters are filtered, not inserted', () async {
      // WM_CHAR really is sent for these: Backspace, Tab, Enter, Escape. They
      // reached the framework already, as key events.
      for (final int unit in <int>[0x08, 0x09, 0x0D, 0x1B]) {
        expect(await send(wmChar, unit), isEmpty, reason: 'code unit $unit');
      }
      // Ctrl+A is WM_CHAR 0x01. Inserting it would put U+0001 in the document
      // every time somebody pressed Select All.
      expect(await send(wmChar, 0x01), isEmpty);
      expect(await send(wmChar, 0x7F), isEmpty, reason: 'Ctrl+Backspace');
    });

    test('WM_SYSCHAR and WM_DEADCHAR are not text', () async {
      // Alt+F is a menu mnemonic; the accent half of a dead key sequence is
      // not a character either - its composed form arrives as its own WM_CHAR.
      expect(await send(wmSyschar, 0x66), isEmpty);
      expect(await send(wmDeadchar, 0xB4), isEmpty);
      expect(await send(wmSysdeadchar, 0xB4), isEmpty);
    });

    test('a key event produces no text, whatever its virtual key', () async {
      // VK_NUMPAD1/2/3 with NumLock on: the reported bug, at the source. The
      // window reports the key and nothing else; the characters (if the layout
      // makes any) arrive as their own WM_CHAR messages.
      for (final int virtualKey in <int>[0x61, 0x62, 0x63]) {
        final List<TextInputEvent> text = await send(wmKeydown, virtualKey);
        expect(text, isEmpty);
        expect(events.whereType<KeyDownEvent>().single.logicalKey, virtualKey);
      }
    });

    test('losing the keyboard forgets a half-delivered character', () async {
      await send(wmChar, _emojiHigh);

      // WM_ACTIVATE with WA_INACTIVE: the low half is going to another window.
      await send(wmActivate, waInactive);

      expect(
        await send(wmChar, _emojiLow),
        isEmpty,
        reason: 'the orphaned lead must not fuse onto the next character',
      );
    });
  }, skip: Platform.isWindows ? false : 'needs a real Win32 window');
}
