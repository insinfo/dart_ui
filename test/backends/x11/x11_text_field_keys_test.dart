/// X11 key presses, off the wire, into a real text field.
///
/// The two halves were each tested and the pair did not work: the translator
/// was tested to put the keysym in [KeyEvent.logicalKey], and the text field
/// was tested against Windows VKs, so on X11 the arrows, Backspace and Ctrl+C
/// reached a field that matched none of them. Only typing worked, because text
/// travels separately. This file composes the two, so a disagreement between
/// them is a failing test rather than a field that ignores the keyboard.
library;

import 'dart:ffi';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/x11/x11_events.dart';
import 'package:dart_ui/src/backends/x11/x11_keyboard.dart';
import 'package:dart_ui/src/backends/x11/x11_libc.dart';
import 'package:dart_ui/src/backends/x11/x11_protocol.dart';
import 'package:dart_ui/src/ffi/native_memory.dart';
import 'package:dart_ui/src/platform/keysyms.dart';
import 'package:test/test.dart';

/// X keycodes of a US keyboard under xkb: evdev + 8.
const int _keyA = 38;
const int _keyC = 54;
const int _backSpace = 22;
const int _tab = 23;
const int _controlL = 37;
const int _shiftL = 50;
const int _left = 113;
const int _right = 114;

void main() {
  setUpAll(() {
    debugEditingConventionOverride = EditingConvention.pc;
    expect(
      FontRegistry.instance.useFontFile('test/fonts/Roboto-Regular.ttf'),
      isTrue,
    );
  });
  tearDownAll(() {
    debugEditingConventionOverride = null;
    FontRegistry.instance.reset();
  });

  test('the arrows move the caret and Backspace deletes', () {
    final _Field field = _Field('abc')
      ..press(_left)
      ..press(_left);
    expect(field.controller.selectionEnd, 1);

    field.press(_backSpace);
    expect(field.controller.value, 'bc');

    field.press(_right);
    expect(field.controller.selectionEnd, 1);
  });

  test('Ctrl+A and Ctrl+C copy, with the keysym c under Control', () async {
    final FakeClipboard clipboard = FakeClipboard();
    final _Field field = _Field('copy me', clipboard: clipboard)
      ..press(_keyA, state: x11ModControl)
      ..press(_keyC, state: x11ModControl);
    await field.render.clipboardSettled;
    expect(clipboard.text, 'copy me');
  });

  test('Ctrl+Left moves by word', () {
    final _Field field = _Field('one two')..press(_left, state: x11ModControl);
    expect(field.controller.selectionEnd, 'one '.length);
  });

  test('Tab is declined, so focus traversal can have it', () {
    final _Field field = _Field('x');
    expect(field.press(_tab), isFalse);
  });

  test('Shift and Control alone are keys, with their side', () {
    final List<PlatformWindowEvent> shift = _translate(_shiftL, 0);
    final KeyDownEvent down = shift.single as KeyDownEvent;
    expect(down.logicalKey, 0x10);
    expect(down.location, KeyLocation.left);
    expect((_translate(_controlL, 0).single as KeyDownEvent).logicalKey, 0x11);
  });
}

X11KeyboardState _usKeyboard() {
  final Map<int, int> keysyms = <int, int>{
    _keyA: 0x61,
    _keyC: 0x63,
    _backSpace: keysymBackSpace,
    _tab: keysymTab,
    _controlL: keysymControlL,
    _shiftL: keysymShiftL,
    _left: keysymLeft,
    _right: keysymRight,
  };
  const int first = _backSpace;
  const int last = _right;
  return X11KeyboardState(
    keyboard: X11KeyboardMapping.fromLists(
      <List<int>>[
        for (var keycode = first; keycode <= last; keycode++)
          <int>[keysyms[keycode] ?? keysymNoSymbol],
      ],
      firstKeycode: first,
    ),
    modifiers: X11ModifierMapping.fromRows(<List<int>>[
      <int>[_shiftL], // Shift
      <int>[], // Lock
      <int>[_controlL], // Control
      <int>[], // Mod1
      <int>[], // Mod2
      <int>[], // Mod3
      <int>[], // Mod4
      <int>[], // Mod5
    ]),
    source: 'core-keyboard-mapping',
  );
}

/// A real `xcb_key_press_event_t`, decoded the way the pump decodes it and
/// translated the way the window translates it.
List<PlatformWindowEvent> _translate(int keycode, int state) {
  final Pointer<Uint8> event = NativeAllocator.instance.allocate<Uint8>(32);
  try {
    for (var index = 0; index < 32; index++) {
      event[index] = 0;
    }
    event[0] = xcbKeyPress;
    event[1] = keycode;
    writeU32(event, 4, 1000);
    writeU32(event, 12, 0x11223344);
    writeU16(event, 28, state);
    event[30] = 1;
    final X11RawEvent raw = X11RawEvent()..decodeFrom(event);
    final List<PlatformWindowEvent> events = <PlatformWindowEvent>[];
    X11EventTranslator.translateKey(
      raw,
      windowId: const NativeWindowId(1),
      generation: 1,
      keyboard: _usKeyboard(),
      emit: events.add,
    );
    return events;
  } finally {
    NativeAllocator.instance.free(event);
  }
}

final class _Field {
  _Field(String text, {Clipboard? clipboard})
      : controller = TextEditingController(text) {
    owner.updateRoot(ClipboardScope(
      clipboard: clipboard ?? FakeClipboard(),
      child: TextField(controller: controller),
    ));
    owner.pipelineOwner.drawFrame(DisplayList());
    render = owner.renderRoot! as RenderTextField;
    render.focusNode!.requestFocus();
    controller.moveCaretToEnd();
  }

  final BuildOwner owner = BuildOwner(
    pipelineOwner: PipelineOwner(
      rootConstraints: BoxConstraints.tight(const Size(240, 60)),
    ),
  );
  final TextEditingController controller;
  late final RenderTextField render;

  /// Sends the key press as X11 delivers it and returns whether the field
  /// claimed it. The text half, if any, is dropped: this file is about keys.
  bool press(int keycode, {int state = 0}) {
    var claimed = false;
    for (final PlatformWindowEvent event in _translate(keycode, state)) {
      if (event is KeyDownEvent) claimed = render.handleKeyEvent(event);
    }
    return claimed;
  }
}
