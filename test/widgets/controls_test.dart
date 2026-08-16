import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  // A control's width comes from the width of its label, which comes from the
  // face it is drawn in. Pinning the face is what stops these assertions from
  // meaning something different on each developer's machine.
  setUpAll(() {
    expect(
      FontRegistry.instance.useFontFile('test/fonts/Roboto-Regular.ttf'),
      isTrue,
    );
  });
  tearDownAll(FontRegistry.instance.reset);

  group('labels are measured with the face they are drawn in', () {
    test('a button is as wide as its shaped label plus padding', () {
      final owner = _owner();
      owner.updateRoot(const Button(label: 'CANCEL'));
      owner.pipelineOwner.drawFrame(DisplayList());
      final button = owner.renderRoot! as RenderButton;

      final ScaledTypeface font =
          FontRegistry.instance.uiFont(ThemeData.neutralLight.fontSize)!;
      final double label = uiTextPainter.measure('CANCEL', font).width;

      expect(label, greaterThan(0));
      expect(
        button.labelledSize('CANCEL').width,
        closeTo(label + ThemeData.neutralLight.controlPadding * 2, 1e-9),
      );
      // A longer label is a wider control: the metric is the text's, not a
      // constant per character.
      expect(
        button.labelledSize('CANCEL MMMM').width,
        greaterThan(button.labelledSize('CANCEL').width),
      );
    });

    test('a caret lands on a proportional character boundary', () {
      final controller = TextEditingController('WILLIAM');
      final owner = _owner();
      owner.updateRoot(TextField(controller: controller));
      owner.pipelineOwner.drawFrame(DisplayList());
      final field = owner.renderRoot! as RenderTextField;

      // 'W' and 'I' are the widest and narrowest letters in most faces, so a
      // caret placed by multiplying an index by a fixed advance lands visibly
      // wrong here - which is the bug this replaced.
      final double afterW = field.labelOffsetOfIndex('WILLIAM', 1);
      final double afterI = field.labelOffsetOfIndex('WILLIAM', 2);
      expect(afterW, greaterThan(0));
      expect(afterI - afterW, lessThan(afterW));

      expect(field.labelOffsetOfIndex('WILLIAM', 0), 0);
      expect(
        field.labelOffsetOfIndex('WILLIAM', 7),
        closeTo(field.measureLabel('WILLIAM').width, 1e-6),
      );
    });

    test('clicking a text field puts the caret at the nearest boundary', () {
      final controller = TextEditingController('WILLIAM');
      final owner = _owner();
      owner.updateRoot(TextField(controller: controller));
      owner.pipelineOwner.drawFrame(DisplayList());
      final field = owner.renderRoot! as RenderTextField;

      // Right of the last glyph is the end, not a clamp artefact; left of the
      // first is the start; and a point just past the middle of a letter is
      // after it, which is what every platform's text field does.
      expect(field.labelIndexAtOffset('WILLIAM', -50), 0);
      expect(field.labelIndexAtOffset('WILLIAM', 10000), 7);
      final double afterW = field.labelOffsetOfIndex('WILLIAM', 1);
      expect(field.labelIndexAtOffset('WILLIAM', afterW - 0.1), 1);
    });
  });

  group('value and text editing state', () {
    test('ValueNotifier coalesces equal values and notifies changes', () {
      final values = <int>[];
      final notifier = ValueNotifier<int>(1)..addListener(values.add);

      notifier
        ..value = 1
        ..value = 2;

      expect(values, <int>[2]);
    });

    test('replacing a selection is one atomic edit', () {
      final controller = TextEditingController('hello world')
        ..setSelection(0, 5);

      controller.replaceSelection('goodbye');

      expect(controller.value, 'goodbye world');
      expect(controller.selectionStart, 7);
      expect(controller.hasSelection, isFalse);
    });

    test('backspace deletes the selection when there is one', () {
      final controller = TextEditingController('abcdef')..setSelection(1, 4);

      controller.deleteBackward();

      expect(controller.value, 'aef');
      expect(controller.selectionEnd, 1);
    });

    test('undo restores text and caret, and a new edit clears redo', () {
      final controller = TextEditingController('a')
        ..moveCaretToEnd()
        ..replaceSelection('b');
      expect(controller.value, 'ab');

      controller.undo();
      expect(controller.value, 'a');
      expect(controller.canRedo, isTrue);

      controller.redo();
      expect(controller.value, 'ab');

      controller
        ..undo()
        ..replaceSelection('z');
      expect(controller.canRedo, isFalse);
    });

    test('a shrinking value clamps a selection past the new end', () {
      final controller = TextEditingController('abcdef')..setSelection(2, 6);

      controller.value = 'ab';

      expect(controller.selectionStart, lessThanOrEqualTo(2));
      expect(controller.selectionEnd, lessThanOrEqualTo(2));
    });
  });

  group('controls in a mounted tree', () {
    test('Button paints, activates by pointer and reports role=button', () {
      var pressed = 0;
      final owner = _owner();
      owner.updateRoot(Button(label: 'OK', onPressed: () => pressed++));
      final list = DisplayList();
      owner.pipelineOwner.drawFrame(list);

      expect(list.commandCount, greaterThan(0));
      owner
        ..dispatchPointerEvent(_pointerDown())
        ..dispatchPointerEvent(_pointerUp());
      expect(pressed, 1);

      final semantics = owner.buildSemantics();
      final node = semantics.nodes.firstWhere(
        (SemanticsNode node) => node.role == SemanticsRole.button,
      );
      expect(node.label, 'OK');
      expect(node.actions, contains(SemanticsAction.activate));
    });

    test('a null callback disables the button and blocks activation', () {
      final owner = _owner();
      owner.updateRoot(const Button(label: 'OK'));
      owner.pipelineOwner.drawFrame(DisplayList());

      final button = owner.renderRoot! as RenderButton;
      expect(button.enabled, isFalse);

      owner
        ..dispatchPointerEvent(_pointerDown())
        ..dispatchPointerEvent(_pointerUp());
      expect(button.isPressed, isFalse);

      final SemanticsNode node = owner.buildSemantics().nodes.firstWhere(
            (SemanticsNode node) => node.role == SemanticsRole.button,
          );
      expect(node.states, contains(SemanticsState.disabled));
      expect(node.actions, isEmpty);
    });

    test('CheckBox toggles and exposes checked state', () {
      var current = false;
      final owner = _owner();
      owner.updateRoot(
        CheckBox(value: current, onChanged: (bool value) => current = value),
      );
      owner.pipelineOwner.drawFrame(DisplayList());

      owner
        ..dispatchPointerEvent(_pointerDown())
        ..dispatchPointerEvent(_pointerUp());
      expect(current, isTrue);

      final SemanticsNode node = owner.buildSemantics().nodes.firstWhere(
            (SemanticsNode node) => node.role == SemanticsRole.checkbox,
          );
      expect(node.value, 'unchecked');
      expect(node.actions, contains(SemanticsAction.activate));
    });

    test('a tri-state CheckBox reports mixed rather than checked', () {
      final owner = _owner();
      owner.updateRoot(
        CheckBox(value: null, tristate: true, onChanged: (bool _) {}),
      );
      owner.pipelineOwner.drawFrame(DisplayList());

      final SemanticsNode node = owner.buildSemantics().nodes.firstWhere(
            (SemanticsNode node) => node.role == SemanticsRole.checkbox,
          );
      expect(node.states, contains(SemanticsState.mixed));
      expect(node.states, isNot(contains(SemanticsState.checked)));
    });

    test('TextField edits by keyboard and moves its caret', () {
      final controller = TextEditingController();
      final owner = _owner();
      final input = FakeTextInput();
      owner.updateRoot(TextField(controller: controller));
      owner.pipelineOwner.drawFrame(DisplayList());

      final field = owner.renderRoot! as RenderTextField;
      owner.requestKeyboardFocus(field);

      // Typing is two events per character, as it is on every platform: the
      // key (which this field claims, so no shortcut steals it) and the text
      // the layout produced from it. This test used to send only the key and
      // expect 'AB', which is the bug - it passed because virtual keys 0x41
      // and 0x42 happen to equal 'A' and 'B' in ASCII.
      owner
        ..dispatchKeyEvent(_key(65))
        ..dispatchTextInputEvent(input.typeText('a'))
        ..dispatchKeyEvent(_key(66))
        ..dispatchTextInputEvent(input.typeText('b'));
      expect(controller.value, 'ab', reason: 'lower case, because no Shift');

      owner.dispatchKeyEvent(_key(logicalKeyArrowLeft));
      expect(controller.selectionEnd, 1);

      owner.dispatchKeyEvent(_key(logicalKeyBackspace));
      expect(controller.value, 'b');
    });

    test('a text field declines Tab so traversal can have it', () {
      final controller = TextEditingController();
      final owner = _owner();
      owner.updateRoot(TextField(controller: controller));
      owner.pipelineOwner.drawFrame(DisplayList());
      final field = owner.renderRoot! as RenderTextField;

      expect(field.handleKeyEvent(_key(logicalKeyTab)), isFalse);
    });

    test('a password field never exposes its value to semantics', () {
      final controller = TextEditingController('secret');
      final owner = _owner();
      owner.updateRoot(PasswordField(controller: controller));
      owner.pipelineOwner.drawFrame(DisplayList());

      final SemanticsNode node = owner.buildSemantics().nodes.firstWhere(
            (SemanticsNode node) => node.role == SemanticsRole.textField,
          );
      expect(node.value, isNull);
      expect(node.states, contains(SemanticsState.obscured));

      final field = owner.renderRoot! as RenderTextField;
      expect(field.displayText, '******');
      expect(field.controller.value, 'secret');
    });

    test('Slider steps by arrow keys and clamps at both ends', () {
      var value = 0.5;
      final owner = _owner();
      owner.updateRoot(
        Slider(value: value, onChanged: (double next) => value = next),
      );
      owner.pipelineOwner.drawFrame(DisplayList());
      final slider = owner.renderRoot! as RenderSlider;

      slider.handleKeyEvent(_key(logicalKeyArrowRight));
      expect(value, closeTo(0.6, 1e-9));

      slider.handleKeyEvent(_key(logicalKeyHome));
      expect(value, 0);

      slider.handleKeyEvent(_key(logicalKeyEnd));
      expect(value, 1);
    });

    test('Menu skips separators and disabled items while navigating', () {
      final selected = <String>[];
      final owner = _owner();
      owner.updateRoot(Menu(items: <MenuItem>[
        MenuItem(label: 'One', onSelected: () => selected.add('One')),
        const MenuItem.separator(),
        const MenuItem(label: 'Off', enabled: false),
        MenuItem(label: 'Two', onSelected: () => selected.add('Two')),
      ]));
      owner.pipelineOwner.drawFrame(DisplayList());
      final menu = owner.renderRoot! as RenderMenu;

      menu.handleKeyEvent(_key(logicalKeyArrowDown));
      expect(menu.highlightedIndex, 0);

      menu.handleKeyEvent(_key(logicalKeyArrowDown));
      expect(menu.highlightedIndex, 3,
          reason: 'separator and disabled skipped');

      menu.handleKeyEvent(_key(logicalKeyEnter));
      expect(selected, <String>['Two']);
    });

    test('Dialog is modal and blocking in semantics', () {
      var dismissed = 0;
      final owner = _owner(size: const Size(300, 200));
      owner.updateRoot(Dialog(
        title: 'Confirm',
        onDismiss: () => dismissed++,
        child: const Button(label: 'Yes'),
      ));
      owner.pipelineOwner.drawFrame(DisplayList());

      final dialog = owner.renderRoot! as RenderDialog;
      expect(dialog.handleKeyEvent(_key(logicalKeyEscape)), isTrue);
      expect(dismissed, 1);

      final SemanticsNode node = owner.buildSemantics().nodes.firstWhere(
            (SemanticsNode node) => node.role == SemanticsRole.dialog,
          );
      expect(node.states, contains(SemanticsState.modal));
      expect(node.actions, contains(SemanticsAction.dismiss));
    });
  });

  group('theme', () {
    test('a control reads the ambient theme through context', () {
      final owner = _owner();
      owner.updateRoot(Theme(
        data: ThemeData.neutralDark,
        child: const Button(label: 'OK'),
      ));
      owner.pipelineOwner.drawFrame(DisplayList());

      final RenderButton button = owner.renderRoot! as RenderButton;
      expect(button.theme.name, 'neutral-dark');
      expect(button.theme.brightness, ThemeBrightness.dark);
    });

    test('a theme swap rebuilds only the dependents', () {
      final owner = _owner();
      owner.updateRoot(Theme(
        data: ThemeData.neutralLight,
        child: const Button(label: 'OK'),
      ));
      owner.pipelineOwner.drawFrame(DisplayList());
      final RenderButton before = owner.renderRoot! as RenderButton;

      owner.updateRoot(Theme(
        data: ThemeData.highContrastDark,
        child: const Button(label: 'OK'),
      ));
      owner.pipelineOwner.drawFrame(DisplayList());

      // The same render object survived: the theme changed, the tree did not.
      expect(owner.renderRoot, same(before));
      expect(before.theme.highContrast, isTrue);
    });

    test('density changes control metrics', () {
      expect(ThemeData.neutralLight.density, ThemeDensity.comfortable);
      expect(ThemeData.neutralLight.effectiveControlHeight, 28.0);
      expect(
        ThemeData.neutralLight
            .copyWith(density: ThemeDensity.compact)
            .effectiveControlHeight,
        closeTo(28.0 * 0.82, 1e-9),
      );
    });
  });
}

BuildOwner _owner({Size size = const Size(200, 60)}) => BuildOwner(
      pipelineOwner: PipelineOwner(rootConstraints: BoxConstraints.tight(size)),
    );

PointerDownEvent _pointerDown() => const PointerDownEvent(
      windowId: NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: Offset(2, 2),
      button: PointerButton.primary,
    );

PointerUpEvent _pointerUp() => const PointerUpEvent(
      windowId: NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: Offset(2, 2),
      button: PointerButton.primary,
    );

KeyDownEvent _key(int logicalKey, {Set<KeyModifier> modifiers = const {}}) =>
    KeyDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      physicalKey: logicalKey,
      logicalKey: logicalKey,
      modifiers: modifiers,
    );
