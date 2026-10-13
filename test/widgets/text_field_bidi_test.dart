/// Left and Right in a TextField move toward that edge of the screen: through
/// Hebrew backwards in the string, and through mixed text one visible step at
/// a time instead of jumping across a run.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

KeyDownEvent _down(int key, {bool shift = false}) => KeyDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      physicalKey: key,
      logicalKey: key,
      modifiers: <KeyModifier>{if (shift) KeyModifier.shift},
    );

void main() {
  setUpAll(FrameworkFonts.install);
  tearDownAll(FontRegistry.instance.reset);

  late BuildOwner owner;
  late TextEditingController controller;

  RenderTextField mount(String text) {
    controller = TextEditingController(text);
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
          rootConstraints: BoxConstraints.tight(const Size(400, 100))),
    )..updateRoot(Directionality(
        textDirection: TextDirection.leftToRight,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 300, child: TextField(controller: controller)),
        ),
      ));
    owner.buildScope();
    owner.pipelineOwner.drawFrame(DisplayList());
    RenderTextField? found;
    void walk(RenderBox node) {
      if (node is RenderTextField) found = node;
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found!;
  }

  tearDown(() => owner.dispose());

  double caretX(RenderTextField field) => field.paragraph!
      .getCaretRect(
          TextPosition(controller.selectionEnd, affinity: controller.affinity))
      .left;

  test('Left goes forward through Hebrew, toward the left of the screen', () {
    final RenderTextField field = mount('שלום');
    controller.collapseTo(0);
    final double start = caretX(field);
    field.handleKeyEvent(_down(logicalKeyArrowLeft));
    expect(controller.selectionEnd, 1);
    expect(caretX(field), lessThan(start));
    field.handleKeyEvent(_down(logicalKeyArrowRight));
    expect(controller.selectionEnd, 0);
  });

  test('Right through mixed text slides one visible step at a time', () {
    // "abc " then three Hebrew letters, shown reversed, then " def".
    const String text = 'abc אבג def';
    final RenderTextField field = mount(text);
    controller.collapseTo(0);
    final List<int> visited = <int>[0];
    double x = caretX(field);
    for (int press = 0; press < 20; press++) {
      field.handleKeyEvent(_down(logicalKeyArrowRight));
      final double next = caretX(field);
      if (next <= x) break;
      expect(next, greaterThan(x), reason: 'never back on the screen');
      x = next;
      visited.add(controller.selectionEnd);
    }
    expect(visited.last, text.length, reason: 'reached the right end');
    // The Hebrew is crossed against the string: 6 before 5.
    expect(visited.indexOf(6), lessThan(visited.indexOf(5)));
    expect(visited.toSet().containsAll(<int>[1, 2, 3, 5, 6, 8, 9, 10]), isTrue);
  });

  test('Left from the end retraces the same places', () {
    const String text = 'abc אבג def';
    final RenderTextField field = mount(text);
    controller.collapseTo(text.length);
    double x = caretX(field);
    int presses = 0;
    while (presses < 20) {
      field.handleKeyEvent(_down(logicalKeyArrowLeft));
      final double next = caretX(field);
      if (next >= x) break;
      x = next;
      presses++;
    }
    expect(controller.selectionEnd, 0);
    expect(presses, greaterThanOrEqualTo(10));
  });

  test('Shift extends from where it started; a plain arrow collapses', () {
    final RenderTextField field = mount('אבג');
    controller.collapseTo(0);
    field.handleKeyEvent(_down(logicalKeyArrowLeft, shift: true));
    field.handleKeyEvent(_down(logicalKeyArrowLeft, shift: true));
    expect(controller.selectionStart, 0);
    expect(controller.selectionEnd, 2);
    // Right collapses to the selection's right-hand end: offset 0.
    field.handleKeyEvent(_down(logicalKeyArrowRight));
    expect(controller.hasSelection, isFalse);
    expect(controller.selectionEnd, 0);
  });

  test('left-to-right text keeps the plain string step', () {
    final RenderTextField field = mount('hello');
    controller.collapseTo(2);
    field.handleKeyEvent(_down(logicalKeyArrowLeft));
    expect(controller.selectionEnd, 1);
    field.handleKeyEvent(_down(logicalKeyArrowRight, shift: true));
    field.handleKeyEvent(_down(logicalKeyArrowRight, shift: true));
    expect(controller.selectionStart, 1);
    expect(controller.selectionEnd, 3);
  });
}
