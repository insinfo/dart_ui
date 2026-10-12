import 'package:dart_ui/src/backends/macos/host_protocol.dart';
import 'package:dart_ui/src/backends/macos/macos_input.dart';
import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/platform/input_events.dart';
import 'package:dart_ui/src/platform/window_events.dart';
import 'package:dart_ui/src/widgets/focus.dart';
import 'package:test/test.dart';

const int _shift = 1 << 17;
const int _control = 1 << 18;
const int _option = 1 << 19;
const int _command = 1 << 20;
const int _capsLock = 1 << 16;

List<PlatformWindowEvent> _translate(HostInputDetail detail) {
  final events = <PlatformWindowEvent>[];
  translateMacosInput(
    detail,
    windowId: const NativeWindowId(1),
    generation: 3,
    emit: events.add,
  );
  return events;
}

HostInputDetail _detail(
  HostInputKind kind, {
  double x = 0,
  double y = 0,
  int keyCode = 0,
  int button = -1,
  int modifiers = 0,
  int clickCount = 0,
  double deltaX = 0,
  double deltaY = 0,
  int flags = 0,
  int keyChar = 0,
}) =>
    HostInputDetail(
      kind: kind,
      x: x,
      y: y,
      keyCode: keyCode,
      machTime: 0,
      button: button,
      modifierFlags: modifiers,
      clickCount: clickCount,
      deltaX: deltaX,
      deltaY: deltaY,
      flags: flags,
      keyChar: keyChar,
    );

void main() {
  group('the logical key is the Windows VK the widgets compare against', () {
    test('the keys the framework names, by position', () {
      expect(macosLogicalKey(0x7B, 0xF702), logicalKeyArrowLeft);
      expect(macosLogicalKey(0x7C, 0xF703), logicalKeyArrowRight);
      expect(macosLogicalKey(0x7E, 0xF700), logicalKeyArrowUp);
      expect(macosLogicalKey(0x7D, 0xF701), logicalKeyArrowDown);
      expect(macosLogicalKey(0x33, 0x7F), logicalKeyBackspace,
          reason: "the Mac's Delete is the PC's Backspace");
      expect(macosLogicalKey(0x75, 0xF728), logicalKeyDelete,
          reason: 'Forward Delete is the PC Delete');
      expect(macosLogicalKey(0x24, 0x0D), logicalKeyEnter);
      expect(macosLogicalKey(0x30, 0x09), logicalKeyTab);
      expect(macosLogicalKey(0x35, 0x1B), logicalKeyEscape);
      expect(macosLogicalKey(0x31, 0x20), logicalKeySpace);
      expect(macosLogicalKey(0x73, 0xF729), logicalKeyHome);
      expect(macosLogicalKey(0x77, 0xF72B), logicalKeyEnd);
      expect(macosLogicalKey(0x74, 0xF72C), logicalKeyPageUp);
      expect(macosLogicalKey(0x79, 0xF72D), logicalKeyPageDown);
    });

    test('a letter is the letter the layout put there, not the US position',
        () {
      // kVK_ANSI_Q (0x0C) is where AZERTY puts A: Cmd+A must be select all.
      expect(macosLogicalKey(0x0C, 0x61), 0x41);
      expect(macosLogicalKey(0x08, 0x63), 0x43, reason: 'c on a US layout');
      expect(macosLogicalKey(0x08, 0x43), 0x43, reason: 'Shift+c is still C');
    });

    test('a layout character with no VK falls back to the US key there', () {
      // ç on ABNT2 sits where US has ;
      expect(macosLogicalKey(0x29, 0xE7), 0xBA);
      // ñ on Spanish, same position
      expect(macosLogicalKey(0x29, 0xF1), 0xBA);
    });

    test('punctuation the layout produced maps to its OEM VK', () {
      expect(macosLogicalKey(0x2B, 0x2C), 0xBC, reason: ',');
      expect(macosLogicalKey(0x1B, 0x2D), 0xBD, reason: '-');
      expect(macosLogicalKey(0x2C, 0x2F), 0xBF, reason: '/');
    });

    test('the keypad keeps its own VKs and says where it is', () {
      expect(macosLogicalKey(0x53, 0x31), 0x61, reason: 'VK_NUMPAD1');
      expect(macosLogicalKey(0x4C, 0x03), logicalKeyEnter);
      expect(macosKeyLocation(0x53), KeyLocation.numpad);
      expect(macosKeyLocation(0x12), KeyLocation.standard, reason: 'row 1');
    });

    test('modifier keys, on each side', () {
      expect(macosLogicalKey(0x38, 0), 0x10);
      expect(macosLogicalKey(0x3C, 0), 0x10);
      expect(macosKeyLocation(0x38), KeyLocation.left);
      expect(macosKeyLocation(0x3C), KeyLocation.right);
      expect(macosLogicalKey(0x37, 0), 0x5B, reason: 'Command is VK_LWIN');
      expect(macosLogicalKey(0x36, 0), 0x5C);
      expect(macosLogicalKey(0x3A, 0), 0x12, reason: 'Option is VK_MENU');
    });
  });

  test('modifiers say what was held: Command is meta, not control', () {
    expect(macosKeyModifiers(_command), <KeyModifier>{KeyModifier.meta});
    expect(macosKeyModifiers(_control), <KeyModifier>{KeyModifier.control});
    expect(macosKeyModifiers(_option | _shift | _capsLock), <KeyModifier>{
      KeyModifier.alt,
      KeyModifier.shift,
      KeyModifier.capsLock,
    });
    expect(macosKeyModifiers(0), isEmpty);
  });

  group('text', () {
    test('what the layout produced arrives whole', () {
      expect(macosTextInput('w6c='), 'ç');
      expect(macosTextInput('8J+MjQ=='), '🌍',
          reason: 'an astral character is one piece, never half a pair');
    });

    test("AppKit's function-key characters and the controls are not text", () {
      expect(macosTextInput('75yC'), isNull, reason: 'U+F702, the left arrow');
      expect(macosTextInput('fw=='), isNull, reason: 'U+007F, Delete');
      expect(macosTextInput('DQ=='), isNull, reason: 'Return');
      expect(macosTextInput('Gw=='), isNull, reason: 'Escape');
    });

    test('bytes that are not base64 of UTF-8 are dropped, not guessed at', () {
      expect(macosTextInput('%%%'), isNull);
    });
  });

  group('pointer events', () {
    test('a press carries its button, position and the platform click count',
        () {
      final events = _translate(_detail(HostInputKind.pointerDown,
          x: 20, y: 30.5, button: 1, clickCount: 2));
      final down = events.single as PointerDownEvent;
      expect(down.button, PointerButton.secondary);
      expect(down.clickCount, 2);
      expect(down.logicalPosition, const Offset(20, 30.5));
      expect(down.windowId, const NativeWindowId(1));
      expect(down.generation, 3);
    });

    test('a button this framework does not name emits nothing', () {
      expect(
          _translate(_detail(HostInputKind.pointerDown, button: 7)), isEmpty);
    });

    test('the back and forward buttons are named', () {
      expect(macosPointerButton(3), PointerButton.back);
      expect(macosPointerButton(4), PointerButton.forward);
    });

    test("scrolling turns AppKit's content direction into an offset", () {
      final wheel = _translate(_detail(HostInputKind.scroll, deltaY: -3)).single
          as PointerScrollEvent;
      expect(wheel.scrollDelta, const Offset(0, 3));
      expect(wheel.scrollDeltaUnit, ScrollDeltaUnit.lines);

      final trackpad = _translate(
              _detail(HostInputKind.scroll, deltaX: 4, deltaY: 25, flags: 1))
          .single as PointerScrollEvent;
      expect(trackpad.scrollDelta, const Offset(-4, -25));
      expect(trackpad.scrollDeltaUnit, ScrollDeltaUnit.pixels);
    });

    test('a scroll that moves nothing is not an event', () {
      expect(_translate(_detail(HostInputKind.scroll)), isEmpty);
    });
  });

  test('a key event carries both codes, the modifiers and the repeat', () {
    final key = _translate(_detail(HostInputKind.keyDown,
            keyCode: 0x08, keyChar: 0x63, modifiers: _command, flags: 2))
        .single as KeyDownEvent;
    expect(key.physicalKey, 0x08);
    expect(key.logicalKey, 0x43);
    expect(key.modifiers, <KeyModifier>{KeyModifier.meta});
    expect(key.isRepeat, isTrue);
  });

  test('an event kind the framework does not model emits nothing', () {
    expect(_translate(_detail(HostInputKind.other)), isEmpty);
  });
}
