/// SelectableText: selecting with the mouse and the keyboard, copying, and
/// the menu.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

KeyDownEvent _down(int key, {Set<KeyModifier> modifiers = const {}}) =>
    KeyDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      physicalKey: key,
      logicalKey: key,
      modifiers: modifiers,
    );

void main() {
  setUpAll(FrameworkFonts.install);
  tearDownAll(FontRegistry.instance.reset);

  late BuildOwner owner;
  late FakeClipboard clipboard;
  final Set<KeyModifier> command = <KeyModifier>{
    platformEditingConvention.commandModifier,
  };

  void frame() {
    for (var i = 0; i < 8; i++) {
      owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
  }

  RenderSelectableText mount(Widget child) {
    clipboard = FakeClipboard();
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
          rootConstraints: BoxConstraints.tight(const Size(400, 300))),
    )..updateRoot(ClipboardScope(
        clipboard: clipboard,
        child: Directionality(
          textDirection: TextDirection.leftToRight,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 300, child: child),
          ),
        ),
      ));
    frame();
    RenderSelectableText? found;
    void walk(RenderBox node) {
      if (node is RenderSelectableText) found = node;
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found!;
  }

  tearDown(() => owner.dispose());

  void press(Offset at, {int clickCount = 1, Duration time = Duration.zero}) {
    owner.dispatchPointerEvent(PointerDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: time,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
      button: PointerButton.primary,
      clickCount: clickCount,
    ));
  }

  void release(Offset at, {Duration time = Duration.zero}) =>
      owner.dispatchPointerEvent(PointerUpEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: time,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: at,
        button: PointerButton.primary,
      ));

  void moveTo(Offset at) => owner.dispatchPointerEvent(PointerMoveEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: at,
      ));

  test('a drag selects, and Ctrl+C copies the selection', () async {
    final RenderSelectableText text =
        mount(const SelectableText('hello world'));
    press(const Offset(1, 5));
    moveTo(const Offset(299, 5));
    release(const Offset(299, 5));
    expect(text.selection.start, 0);
    expect(text.selectedText, 'hello world');
    expect(text.hasFocus, isTrue, reason: 'clicking focuses it');
    expect(text.handleKeyEvent(_down(0x43, modifiers: command)), isTrue);
    await text.clipboardSettled;
    expect(clipboard.text, 'hello world');
  });

  test('a double click selects a word, a triple click all of it', () {
    final RenderSelectableText text =
        mount(const SelectableText('hello world'));
    press(const Offset(2, 5), time: const Duration(milliseconds: 10));
    release(const Offset(2, 5), time: const Duration(milliseconds: 20));
    press(const Offset(2, 5),
        clickCount: 2, time: const Duration(milliseconds: 100));
    release(const Offset(2, 5), time: const Duration(milliseconds: 110));
    expect(text.selectedText, 'hello');
    press(const Offset(2, 5), time: const Duration(milliseconds: 200));
    expect(text.selectedText, 'hello world');
  });

  test('the keyboard extends and selects all; an empty copy is refused',
      () async {
    final List<TextSelection> changes = <TextSelection>[];
    final RenderSelectableText text = mount(SelectableText(
      'abc',
      onSelectionChanged: (TextSelection s, SelectionChangedCause? cause) =>
          changes.add(s),
    ));
    text.focusNode!.requestFocus();
    text.handleKeyEvent(_down(0x43, modifiers: command));
    await text.clipboardSettled;
    expect(clipboard.writes, 0, reason: 'nothing selected, nothing written');
    text.handleKeyEvent(_down(logicalKeyArrowRight,
        modifiers: const <KeyModifier>{KeyModifier.shift}));
    expect(text.selectedText, 'a');
    text.handleKeyEvent(_down(logicalKeyEnd,
        modifiers: const <KeyModifier>{KeyModifier.shift}));
    expect(text.selectedText, 'abc');
    text.handleKeyEvent(_down(logicalKeyHome));
    expect(text.selection.isCollapsed, isTrue);
    text.handleKeyEvent(_down(0x41, modifiers: command));
    expect(text.selectedText, 'abc');
    expect(changes, isNotEmpty);
  });

  test('rich text selects over the spans\' plain text', () {
    final RenderSelectableText text = mount(const SelectableText.rich(
      TextSpan(text: 'bold ', children: <InlineSpan>[TextSpan(text: 'plain')]),
    ));
    text.focusNode!.requestFocus();
    text.handleKeyEvent(_down(0x41, modifiers: command));
    expect(text.selectedText, 'bold plain');
  });

  test('the menu offers Copy and Select all', () {
    final RenderSelectableText text = mount(const SelectableText('menu'));
    final List<MenuItem> items = text.buildContextMenuItems();
    expect(items.map((MenuItem i) => i.label), <String>['Copy', 'Select all']);
    expect(items.first.enabled, isFalse, reason: 'nothing selected yet');
    text.select(const TextSelection(baseOffset: 0, extentOffset: 2));
    expect(text.buildContextMenuItems().first.enabled, isTrue);
  });

  test('a screen reader reads the text, as read-only', () {
    final RenderSelectableText text = mount(const SelectableText('read me'));
    final SemanticsConfiguration semantics = text.describeSemantics();
    expect(semantics.role, SemanticsRole.text);
    expect(semantics.label, 'read me');
    expect(semantics.states, contains(SemanticsState.readOnly));
  });
}
