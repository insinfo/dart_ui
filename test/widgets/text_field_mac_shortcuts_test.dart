/// The Mac's editing chords, and that each convention leaves the other alone.
///
/// The macOS backend reports Command as [KeyModifier.meta] and Option as
/// [KeyModifier.alt] - what was held, not what it means - and the text field
/// decides the meaning from [EditingConvention]. The PC chords are asserted,
/// with the PC convention pinned, in `text_editing_test.dart` and
/// `text_field_clipboard_test.dart`; this file pins the Mac's.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

const int _keyA = 0x41;
const int _keyC = 0x43;
const int _keyV = 0x56;
const int _keyX = 0x58;
const int _keyZ = 0x5A;

void main() {
  setUpAll(() {
    expect(
      FontRegistry.instance.useFontFile('test/fonts/Roboto-Regular.ttf'),
      isTrue,
    );
  });
  tearDownAll(FontRegistry.instance.reset);

  group('on a Mac', () {
    setUp(() => debugEditingConventionOverride = EditingConvention.mac);
    tearDown(() => debugEditingConventionOverride = null);

    test('Cmd+A, Cmd+C and Cmd+V copy and paste', () async {
      final FakeClipboard clipboard = FakeClipboard();
      final _Field field = _Field(clipboard, 'hello world')
        ..press(_keyA, command: true)
        ..press(_keyC, command: true);
      await field.settled;
      expect(clipboard.text, 'hello world');

      field
        ..press(logicalKeyEnd)
        ..press(_keyV, command: true);
      await field.settled;
      expect(field.controller.value, 'hello worldhello world');
    });

    test('Cmd+X cuts', () async {
      final FakeClipboard clipboard = FakeClipboard();
      final _Field field = _Field(clipboard, 'cut me')
        ..press(_keyA, command: true)
        ..press(_keyX, command: true);
      await field.settled;
      expect(clipboard.text, 'cut me');
      expect(field.controller.value, isEmpty);
    });

    test('Cmd+Z undoes and Cmd+Shift+Z redoes', () {
      final _Field field = _Field(FakeClipboard(), 'abc')
        ..press(logicalKeyEnd)
        ..press(logicalKeyBackspace);
      expect(field.controller.value, 'ab');

      field.press(_keyZ, command: true);
      expect(field.controller.value, 'abc');

      field.press(_keyZ, command: true, shift: true);
      expect(field.controller.value, 'ab');
    });

    test('Control is not Command: Ctrl+C copies nothing', () async {
      // On a Mac, Control chords belong to the system and to Emacs-style
      // movement; Ctrl+C is not copy there.
      final FakeClipboard clipboard = FakeClipboard();
      final _Field field = _Field(clipboard, 'secret')
        ..press(_keyA, command: true)
        ..press(_keyC, control: true);
      await field.settled;
      expect(clipboard.text, isNull);
    });

    test('Option+Left and Option+Right move by word', () {
      final _Field field = _Field(FakeClipboard(), 'one two three')
        ..press(logicalKeyEnd)
        ..press(logicalKeyArrowLeft, option: true);
      expect(field.controller.selectionEnd, 'one two '.length);

      field.press(logicalKeyArrowLeft, option: true, shift: true);
      expect(field.controller.selectionStart, 'one two '.length,
          reason: 'Shift extends from where the caret was');
      expect(field.controller.selectionEnd, 'one '.length);
    });

    test('Option+Delete deletes a word', () {
      final _Field field = _Field(FakeClipboard(), 'one two')
        ..press(logicalKeyEnd)
        ..press(logicalKeyBackspace, option: true);
      expect(field.controller.value, 'one ');
    });

    test('Cmd+Left and Cmd+Right go to the edges', () {
      final _Field field = _Field(FakeClipboard(), 'one two')
        ..press(logicalKeyEnd)
        ..press(logicalKeyArrowLeft, command: true);
      expect(field.controller.selectionEnd, 0);

      field.press(logicalKeyArrowRight, command: true, shift: true);
      expect(field.controller.selectionStart, 0);
      expect(field.controller.selectionEnd, 'one two'.length);
    });

    test('Cmd+Delete deletes to the start, or only the selection', () {
      final _Field field = _Field(FakeClipboard(), 'one two')
        ..press(logicalKeyEnd)
        ..press(logicalKeyArrowLeft, option: true)
        ..press(logicalKeyBackspace, command: true);
      expect(field.controller.value, 'two');

      field
        ..press(_keyA, command: true)
        ..press(logicalKeyBackspace, command: true);
      expect(field.controller.value, isEmpty);
    });

    test('Option with a letter is left for the text it types', () {
      // Option+E is the acute dead key on a Mac keyboard: the field must not
      // claim it as a shortcut, or the accent never arrives.
      final _Field field = _Field(FakeClipboard(), '');
      expect(field.pressReturning(0x45, option: true), isTrue,
          reason: 'claimed as a key that may produce text, like any letter');
      expect(field.controller.value, isEmpty,
          reason: 'and nothing inserted from the key itself');
    });
  });

  group('on a PC, the Mac chords mean nothing', () {
    setUp(() => debugEditingConventionOverride = EditingConvention.pc);
    tearDown(() => debugEditingConventionOverride = null);

    test('Cmd+C (the Windows key) copies nothing', () async {
      final FakeClipboard clipboard = FakeClipboard();
      final _Field field = _Field(clipboard, 'text')
        ..press(_keyA, control: true)
        ..press(_keyC, command: true);
      await field.settled;
      expect(clipboard.text, isNull);
    });

    test('Alt+Left does not move by word', () {
      final _Field field = _Field(FakeClipboard(), 'one two')
        ..press(logicalKeyEnd)
        ..press(logicalKeyArrowLeft, option: true);
      expect(field.controller.selectionEnd, 'one two'.length - 1,
          reason: 'a plain arrow: Alt is not the word modifier here');
    });
  });

  test('the widget parameter wins over the platform', () async {
    debugEditingConventionOverride = EditingConvention.pc;
    addTearDown(() => debugEditingConventionOverride = null);
    final FakeClipboard clipboard = FakeClipboard();
    final _Field field =
        _Field(clipboard, 'pinned', convention: EditingConvention.mac)
          ..press(_keyA, command: true)
          ..press(_keyC, command: true);
    await field.settled;
    expect(clipboard.text, 'pinned');
  });
}

final class _Field {
  _Field(Clipboard clipboard, String text, {EditingConvention? convention})
      : controller = TextEditingController(text) {
    owner.updateRoot(
      ClipboardScope(
        clipboard: clipboard,
        child: TextField(controller: controller, editingConvention: convention),
      ),
    );
    owner.pipelineOwner.drawFrame(DisplayList());
    render = owner.renderRoot! as RenderTextField;
    render.focusNode!.requestFocus();
  }

  final BuildOwner owner = BuildOwner(
    pipelineOwner: PipelineOwner(
      rootConstraints: BoxConstraints.tight(const Size(240, 60)),
    ),
  );
  final TextEditingController controller;
  late final RenderTextField render;

  Future<void> get settled => render.clipboardSettled;

  void press(
    int logicalKey, {
    bool command = false,
    bool control = false,
    bool option = false,
    bool shift = false,
  }) =>
      pressReturning(logicalKey,
          command: command, control: control, option: option, shift: shift);

  bool pressReturning(
    int logicalKey, {
    bool command = false,
    bool control = false,
    bool option = false,
    bool shift = false,
  }) =>
      render.handleKeyEvent(KeyDownEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        physicalKey: logicalKey,
        logicalKey: logicalKey,
        modifiers: <KeyModifier>{
          if (command) KeyModifier.meta,
          if (control) KeyModifier.control,
          if (option) KeyModifier.alt,
          if (shift) KeyModifier.shift,
        },
      ));
}
