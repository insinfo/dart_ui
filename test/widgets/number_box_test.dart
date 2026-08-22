import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('NumberBox stepping', () {
    test('Up and Down step by one step, PageUp/PageDown by ten', () {
      final harness = _NumberHarness(value: 10, min: 0, max: 100);
      harness.frame();

      harness.box.handleKeyEvent(_key(logicalKeyArrowUp));
      harness.frame();
      expect(harness.value, 11);

      harness.box.handleKeyEvent(_key(logicalKeyArrowDown));
      harness.frame();
      expect(harness.value, 10);

      harness.box.handleKeyEvent(_key(logicalKeyPageUp));
      harness.frame();
      expect(harness.value, 20);

      harness.box.handleKeyEvent(_key(logicalKeyPageDown));
      harness.frame();
      expect(harness.value, 10);
      harness.dispose();
    });

    test('steps clamp at the range ends', () {
      final harness = _NumberHarness(value: 99.5, min: 0, max: 100, step: 2);
      harness.frame();

      harness.box.handleKeyEvent(_key(logicalKeyArrowUp));
      harness.frame();
      expect(harness.value, 100);

      harness.box.handleKeyEvent(_key(logicalKeyArrowUp));
      harness.frame();
      expect(harness.value, 100, reason: 'already at the maximum');
      harness.dispose();
    });

    test('the spin buttons step on press', () {
      final harness = _NumberHarness(value: 5, min: 0, max: 10);
      harness.frame();

      // The spin column is the trailing 18 px; upper half increments.
      final double x = harness.box.size.width - 9;
      harness.box.handlePointerEvent(_press(Offset(x, 5)));
      harness.frame();
      expect(harness.value, 6);

      harness.box.handlePointerEvent(
          _press(Offset(x, harness.box.size.height - 5)));
      harness.frame();
      expect(harness.value, 5);
      harness.dispose();
    });
  });

  group('NumberBox editing', () {
    test('typed digits become the value on Enter', () {
      final harness = _NumberHarness(value: 10, min: 0, max: 100);
      harness.frame();

      harness.box.handleTextInput(_text('42'));
      harness.frame();
      expect(harness.box.text, '42');
      expect(harness.value, 10, reason: 'no commit yet');

      harness.box.handleKeyEvent(_key(logicalKeyEnter));
      harness.frame();
      expect(harness.value, 42);
      harness.dispose();
    });

    test('a comma parses as the decimal separator', () {
      final harness =
          _NumberHarness(value: 1, min: 0, max: 100, decimals: 1);
      harness.frame();

      harness.box.handleTextInput(_text('2,5'));
      harness.box.handleKeyEvent(_key(logicalKeyEnter));
      harness.frame();

      expect(harness.value, 2.5);
      harness.dispose();
    });

    test('a committed value is clamped into the range', () {
      final harness = _NumberHarness(value: 10, min: 0, max: 100);
      harness.frame();

      harness.box.handleTextInput(_text('500'));
      harness.box.handleKeyEvent(_key(logicalKeyEnter));
      harness.frame();

      expect(harness.value, 100);
      harness.dispose();
    });

    test('unparseable text reverts to the last good value', () {
      final harness = _NumberHarness(value: 10, min: 0, max: 100);
      harness.frame();

      harness.box.handleTextInput(_text('--'));
      harness.box.handleKeyEvent(_key(logicalKeyEnter));
      harness.frame();

      expect(harness.value, 10);
      expect(harness.box.text, '10');
      harness.dispose();
    });

    test('Escape abandons the draft', () {
      final harness = _NumberHarness(value: 10, min: 0, max: 100);
      harness.frame();

      harness.box.handleTextInput(_text('99'));
      harness.frame();
      expect(harness.box.text, '99');

      harness.box.handleKeyEvent(_key(logicalKeyEscape));
      harness.frame();
      expect(harness.box.text, '10');
      expect(harness.value, 10);
      harness.dispose();
    });

    test('Backspace edits the draft and letters are refused', () {
      final harness = _NumberHarness(value: 10, min: 0, max: 100);
      harness.frame();

      harness.box.handleTextInput(_text('12'));
      harness.box.handleTextInput(_text('abc'));
      harness.frame();
      expect(harness.box.text, '12', reason: 'letters never enter the draft');

      harness.box.handleKeyEvent(_key(logicalKeyBackspace));
      harness.frame();
      expect(harness.box.text, '1');

      harness.box.handleKeyEvent(_key(logicalKeyEnter));
      harness.frame();
      expect(harness.value, 1);
      harness.dispose();
    });

    test('a step while a draft is open commits the draft first', () {
      final harness = _NumberHarness(value: 10, min: 0, max: 100);
      harness.frame();

      harness.box.handleTextInput(_text('5'));
      harness.box.handleKeyEvent(_key(logicalKeyArrowUp));
      harness.frame();

      expect(harness.value, 6, reason: '5 + one step, not 10 + one step');
      harness.dispose();
    });
  });

  group('NumberBox semantics', () {
    test('reports a text field with increment and decrement', () {
      final harness = _NumberHarness(value: 10, min: 0, max: 100);
      harness.frame();

      final SemanticsSnapshot snapshot =
          SemanticsOwner().build(harness.owner.renderRoot);
      final SemanticsNode node = snapshot.nodes.firstWhere(
        (SemanticsNode n) => n.role == SemanticsRole.textField,
      );
      expect(node.value, '10');
      expect(
        node.actions,
        containsAll(<SemanticsAction>[
          SemanticsAction.increment,
          SemanticsAction.decrement,
        ]),
      );
      harness.dispose();
    });
  });
}

final class _NumberHarness {
  _NumberHarness({
    required this.value,
    required this.min,
    required this.max,
    this.step = 1,
    this.decimals = 0,
  }) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(160, 40)),
      ),
    );
    _mount();
  }

  double value;
  final double min;
  final double max;
  final double step;
  final int decimals;
  late final BuildOwner owner;

  void _mount() => owner.updateRoot(NumberBox(
        value: value,
        min: min,
        max: max,
        step: step,
        decimals: decimals,
        onChanged: (double next) => value = next,
      ));

  void frame({int maxPasses = 8}) {
    for (int pass = 0; pass < maxPasses; pass++) {
      _mount();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
    throw StateError('the number box never settled');
  }

  RenderNumberBox get box {
    RenderNumberBox? found;
    void walk(RenderBox node) {
      if (found != null) return;
      if (node is RenderNumberBox) {
        found = node;
        return;
      }
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found!;
  }

  void dispose() => owner.dispose();
}

KeyDownEvent _key(int logicalKey) => KeyDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      physicalKey: logicalKey,
      logicalKey: logicalKey,
    );

TextInputEvent _text(String text) => TextInputEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      text: text,
    );

PointerDownEvent _press(Offset position) => PointerDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: position,
      button: PointerButton.primary,
    );
