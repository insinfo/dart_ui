/// A TextField of several lines: wrapping, its own height, Enter as a new
/// line, the arrows across lines, Home and End on the line, a paste that
/// keeps its breaks, and scrolling to the caret.
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
  late TextEditingController controller;

  void frame() {
    for (var i = 0; i < 8; i++) {
      owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
  }

  RenderTextField mount({
    String text = '',
    int? maxLines = 4,
    int? minLines,
    double width = 160,
    void Function(String)? onSubmitted,
  }) {
    controller = TextEditingController(text);
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
          rootConstraints: BoxConstraints.tight(const Size(400, 400))),
    )..updateRoot(Directionality(
        textDirection: TextDirection.leftToRight,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: TextField(
              controller: controller,
              maxLines: maxLines,
              minLines: minLines,
              onSubmitted: onSubmitted,
            ),
          ),
        ),
      ));
    frame();
    RenderTextField? found;
    void walk(RenderBox node) {
      if (node is RenderTextField) found = node;
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found!;
  }

  tearDown(() => owner.dispose());

  test('a single-line field stays one control high', () {
    final RenderTextField field = mount(text: 'one', maxLines: 1);
    final RenderTextField area = mount(text: 'one', maxLines: 3);
    expect(area.size.height, closeTo(field.size.height, 1),
        reason: 'one line of an area looks like a field');
  });

  test('the area grows with its lines, from minLines up to maxLines', () {
    final RenderTextField area = mount(minLines: 2);
    final double two = area.size.height;
    controller.value = 'a\nb\nc';
    frame();
    final double three = area.size.height;
    expect(three, greaterThan(two));
    controller.value = 'a\nb\nc\nd\ne\nf';
    frame();
    final double capped = area.size.height;
    expect(capped, greaterThan(three));
    controller.value = 'a\nb\nc\nd\ne\nf\ng\nh';
    frame();
    expect(area.size.height, capped, reason: 'four lines, then it scrolls');
  });

  test('long words and sentences wrap to the width', () {
    final RenderTextField area = mount(
        text: 'The quick brown fox jumps over the lazy dog, twice over.',
        maxLines: null,
        width: 120);
    expect(area.paragraph!.lines.length, greaterThan(2));
  });

  test('Enter is a new line; Ctrl or Cmd+Enter submits', () {
    final List<String> sent = <String>[];
    final RenderTextField area = mount(text: 'ab', onSubmitted: sent.add);
    controller.collapseTo(1);
    expect(area.handleKeyEvent(_down(logicalKeyEnter)), isTrue);
    expect(controller.value, 'a\nb');
    expect(sent, isEmpty);
    area.handleKeyEvent(_down(logicalKeyEnter, modifiers: <KeyModifier>{
      platformEditingConvention.commandModifier,
    }));
    expect(sent, <String>['a\nb']);
  });

  test('Up and Down keep the column across a shorter line', () {
    final RenderTextField area = mount(text: 'abcdef\nab\nabcdef');
    controller.collapseTo(5); // after "abcde"
    area.handleKeyEvent(_down(logicalKeyArrowDown));
    expect(controller.selectionEnd, 9, reason: 'the end of "ab"');
    area.handleKeyEvent(_down(logicalKeyArrowDown));
    expect(controller.selectionEnd, 15,
        reason: 'back to the column: "abcde|f"');
    area.handleKeyEvent(_down(logicalKeyArrowUp));
    area.handleKeyEvent(_down(logicalKeyArrowUp));
    expect(controller.selectionEnd, 5);
    area.handleKeyEvent(_down(logicalKeyArrowUp));
    expect(controller.selectionEnd, 0, reason: 'past the first line: start');
    area.handleKeyEvent(_down(logicalKeyArrowDown,
        modifiers: const <KeyModifier>{KeyModifier.shift}));
    expect(controller.selectionStart, 0);
    expect(controller.selectionEnd, greaterThan(6), reason: 'extended down');
  });

  test('Home and End stay on the line; a hard break stays after End', () {
    final RenderTextField area = mount(text: 'first\nsecond');
    controller.collapseTo(8); // inside "second"
    area.handleKeyEvent(_down(logicalKeyHome));
    expect(controller.selectionEnd, 6);
    controller.collapseTo(2);
    area.handleKeyEvent(_down(logicalKeyEnd));
    expect(controller.selectionEnd, 5, reason: 'before the newline');
  });

  test('a paste keeps its line breaks, CRLF as one', () {
    final RenderTextField area = mount();
    expect(PastedText.forMultiline('a\r\nb\rc\td'), 'a\nb\nc\td');
    expect(area.isMultiline, isTrue);
  });

  test('a click on the second line puts the caret there', () {
    final RenderTextField area = mount(text: 'top\nbottom');
    final Rect second = area.paragraph!.lines[1].bounds;
    final Offset at = area.localToGlobal(Offset(
        theme(area).effectiveControlPadding + second.right - 1,
        area.size.height / 2 + second.height / 2));
    owner
      ..dispatchPointerEvent(PointerDownEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        pointerId: 1,
        kind: PointerKind.mouse,
        logicalPosition: at,
        button: PointerButton.primary,
      ))
      ..dispatchPointerEvent(PointerUpEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        pointerId: 1,
        kind: PointerKind.mouse,
        logicalPosition: at,
        button: PointerButton.primary,
      ));
    expect(controller.selectionEnd, greaterThan(4),
        reason: 'on "bottom", not "top"');
  });
}

ThemeData theme(RenderTextField field) => field.theme;
