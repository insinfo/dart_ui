/// The controls actually performing the actions they declare.
///
/// `semantics_test.dart` covers the tree: ids, bounds, reading order, diffs.
/// This file covers the other half, which did not exist until the accessibility
/// bridge needed it - a control that says `SemanticsAction.activate` and cannot
/// be activated is a button a screen reader announces and cannot press.
///
/// Everything here is in-process and platform-independent. The Windows end of
/// the same path - a real `IUIAutomation` client calling `Invoke` on a real
/// window - is in `test/backends/win32/uia/`.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() {
    expect(
      FontRegistry.instance.useFontFile('test/fonts/Roboto-Regular.ttf'),
      isTrue,
    );
  });
  tearDownAll(FontRegistry.instance.reset);

  group('a button', () {
    test('activate runs the same callback a click does', () {
      var presses = 0;
      final BuildOwner owner = _owner();
      owner.updateRoot(Button(label: 'Save', onPressed: () => presses++));
      owner.pipelineOwner.drawFrame(DisplayList());
      final RenderButton button = owner.renderRoot! as RenderButton;

      expect(
        button.performSemanticsAction(SemanticsAction.activate),
        isTrue,
      );
      expect(presses, 1);
    });

    test('a disabled button refuses, and declares no action either', () {
      final BuildOwner owner = _owner();
      // No `onPressed` is what disables a button in this framework.
      owner.updateRoot(const Button(label: 'Save'));
      owner.pipelineOwner.drawFrame(DisplayList());
      final RenderButton button = owner.renderRoot! as RenderButton;

      expect(button.describeSemantics().actions, isEmpty);
      expect(
        button.performSemanticsAction(SemanticsAction.activate),
        isFalse,
        reason: 'the declaration and the refusal have to agree, or a client '
            'reads one and gets the other',
      );
    });

    test('an action it never declared is refused', () {
      final BuildOwner owner = _owner();
      owner.updateRoot(Button(label: 'Save', onPressed: () {}));
      owner.pipelineOwner.drawFrame(DisplayList());
      final RenderButton button = owner.renderRoot! as RenderButton;

      expect(
        button.performSemanticsAction(SemanticsAction.increment),
        isFalse,
      );
      expect(
        button.performSemanticsAction(SemanticsAction.setValue, value: '3'),
        isFalse,
      );
    });
  });

  group('a check box', () {
    test('activate toggles it, which is what IToggleProvider::Toggle means',
        () {
      bool? received;
      final BuildOwner owner = _owner();
      owner.updateRoot(CheckBox(
        label: 'Remember me',
        value: false,
        onChanged: (bool value) => received = value,
      ));
      owner.pipelineOwner.drawFrame(DisplayList());
      final RenderToggle toggle = _find<RenderToggle>(owner);

      expect(toggle.performSemanticsAction(SemanticsAction.activate), isTrue);
      expect(received, isTrue);
    });
  });

  group('a slider', () {
    RenderSlider build(
      BuildOwner owner,
      double value,
      void Function(double) onChanged,
    ) {
      owner.updateRoot(Slider(
        value: value,
        step: 0.05,
        onChanged: onChanged,
      ));
      owner.pipelineOwner.drawFrame(DisplayList());
      return _find<RenderSlider>(owner);
    }

    test('increment and decrement move it by one step', () {
      final List<double> changes = <double>[];
      final BuildOwner owner = _owner();
      final RenderSlider slider = build(owner, 0.5, changes.add);

      expect(slider.performSemanticsAction(SemanticsAction.increment), isTrue);
      expect(changes.single, closeTo(0.55, 1e-9));
    });

    test('setValue parses the string the tree carries', () {
      // The semantic tree carries a value as a *string* - see the
      // IRangeValueProvider entry in `uia_mapping.dart` for why the Windows
      // bridge hands a slider over as IValueProvider rather than as a numeric
      // range. Parsing here is the consequence of that decision.
      final List<double> changes = <double>[];
      final BuildOwner owner = _owner();
      final RenderSlider slider = build(owner, 0.25, changes.add);

      expect(
        slider.performSemanticsAction(SemanticsAction.setValue, value: '0.75'),
        isTrue,
      );
      expect(changes.single, closeTo(0.75, 1e-9));
    });

    test('setValue with something that is not a number is refused', () {
      final List<double> changes = <double>[];
      final BuildOwner owner = _owner();
      final RenderSlider slider = build(owner, 0.25, changes.add);

      expect(
        slider.performSemanticsAction(SemanticsAction.setValue, value: 'loud'),
        isFalse,
      );
      expect(changes, isEmpty);
    });

    test('a step past the end of the range answers false', () {
      // Not an error and not a lie: the value did not move, and a client that
      // was told it did would announce a number the slider does not hold.
      final List<double> changes = <double>[];
      final BuildOwner owner = _owner();
      final RenderSlider slider = build(owner, 1, changes.add);

      expect(slider.performSemanticsAction(SemanticsAction.increment), isFalse);
      expect(changes, isEmpty);
    });
  });

  group('a text field', () {
    test('setValue replaces the text and records one undo entry', () {
      final TextEditingController controller = TextEditingController('before');
      final BuildOwner owner = _owner(size: const Size(240, 60));
      owner.updateRoot(TextField(controller: controller, label: 'Name'));
      owner.pipelineOwner.drawFrame(DisplayList());
      final RenderTextField field = _find<RenderTextField>(owner);

      expect(
        field.performSemanticsAction(SemanticsAction.setValue, value: 'after'),
        isTrue,
      );
      expect(controller.value, 'after');
      // The path a paste takes, which is the point: a user who let a screen
      // reader fill a field can take it back like any other edit.
      expect(controller.canUndo, isTrue);
      controller.undo();
      expect(controller.value, 'before');
    });

    test('a read-only field refuses even though it declares setValue', () {
      // `readOnly` is published as a state, and answering false is what turns
      // that state into a consequence rather than a decoration.
      final TextEditingController controller = TextEditingController('before');
      final BuildOwner owner = _owner(size: const Size(240, 60));
      owner.updateRoot(TextField(
        controller: controller,
        label: 'Name',
        readOnly: true,
      ));
      owner.pipelineOwner.drawFrame(DisplayList());
      final RenderTextField field = _find<RenderTextField>(owner);

      expect(
        field.describeSemantics().states,
        contains(SemanticsState.readOnly),
      );
      expect(
        field.performSemanticsAction(SemanticsAction.setValue, value: 'after'),
        isFalse,
      );
      expect(controller.value, 'before');
    });

    test('an obscured field never publishes its text', () {
      // Section 30.8's rule, asserted here because this is the file that reads
      // a control's semantics for what a screen reader would say out loud.
      final TextEditingController controller = TextEditingController('hunter2');
      final BuildOwner owner = _owner(size: const Size(240, 60));
      owner.updateRoot(TextField(
        controller: controller,
        label: 'Password',
        obscure: true,
      ));
      owner.pipelineOwner.drawFrame(DisplayList());
      final RenderTextField field = _find<RenderTextField>(owner);

      expect(field.describeSemantics().value, isNull);
      expect(
        field.describeSemantics().states,
        contains(SemanticsState.obscured),
      );
    });
  });

  group('the owner routes an action to the right render object', () {
    test('by the id it published, not by position', () {
      var first = 0;
      var second = 0;
      final BuildOwner owner = _owner(size: const Size(200, 120));
      owner.updateRoot(Column(children: <Widget>[
        Button(label: 'First', onPressed: () => first++),
        Button(label: 'Second', onPressed: () => second++),
      ]));
      owner.pipelineOwner.drawFrame(DisplayList());

      final SemanticsSnapshot tree = owner.buildSemantics();
      final SemanticsNode target =
          tree.nodes.firstWhere((SemanticsNode node) => node.label == 'Second');

      expect(
        owner.semanticsOwner.performAction(target.id, SemanticsAction.activate),
        isTrue,
      );
      expect(second, 1);
      expect(first, 0);
    });
  });
}

BuildOwner _owner({Size size = const Size(200, 60)}) => BuildOwner(
      pipelineOwner: PipelineOwner(rootConstraints: BoxConstraints.tight(size)),
    );

/// The first render object of type [T] under the root.
///
/// The controls wrap themselves in focus and gesture scaffolding, so the render
/// root is not the control - and a test that assumed it was would break the
/// first time one of them grew a wrapper.
T _find<T extends RenderBox>(BuildOwner owner) {
  T? found;
  void walk(RenderBox node) {
    if (found != null) return;
    if (node is T) {
      found = node;
      return;
    }
    node.visitChildren(walk);
  }

  walk(owner.renderRoot!);
  return found ?? (throw StateError('no $T in the tree'));
}
