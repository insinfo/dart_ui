/// Form, FormField, TextFormField and the Flutter parameters of TextField:
/// typing through formatters, onChanged, Enter and the input action, the
/// decoration's label, error and counter.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/widgets/input_decorator.dart'
    show RenderInputDecorator;
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

TextInputEvent _typed(String text) => TextInputEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      text: text,
    );

void main() {
  setUpAll(FrameworkFonts.install);
  tearDownAll(FontRegistry.instance.reset);

  late BuildOwner owner;
  late FakeClipboard clipboard;

  void frame() {
    for (var i = 0; i < 8; i++) {
      owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
  }

  void mount(Widget child) {
    clipboard = FakeClipboard();
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
          rootConstraints: BoxConstraints.tight(const Size(500, 600))),
    )..updateRoot(Theme(
        data: ThemeData.neutralLight,
        child: ClipboardScope(
          clipboard: clipboard,
          child: Directionality(
            textDirection: TextDirection.leftToRight,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 320, child: child),
            ),
          ),
        ),
      ));
    frame();
  }

  tearDown(() => owner.dispose());

  List<T> all<T extends RenderBox>() {
    final List<T> found = <T>[];
    void walk(RenderBox node) {
      if (node is T) found.add(node);
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found;
  }

  /// Focuses [field] and types [text] into it, one character at a time.
  void type(RenderTextField field, String text) {
    field.focusNode!.requestFocus();
    for (final int rune in text.runes) {
      field.handleTextInput(_typed(String.fromCharCode(rune)));
    }
    frame();
  }

  group('TextField with Flutter parameters', () {
    test('without a controller it keeps its own, and onChanged reports typing',
        () {
      final List<String> changes = <String>[];
      mount(TextField(onChanged: changes.add));
      final RenderTextField field = all<RenderTextField>().single;
      type(field, 'ab');
      expect(field.controller.text, 'ab');
      expect(changes, <String>['a', 'ab']);
    });

    test('onChanged does not fire for a change the program makes', () {
      final TextEditingController controller = TextEditingController();
      final List<String> changes = <String>[];
      mount(TextField(controller: controller, onChanged: changes.add));
      controller
        ..text = 'set by code'
        ..selection = const TextSelection.collapsed(11);
      frame();
      expect(changes, isEmpty);
      final RenderTextField field = all<RenderTextField>().single;
      field.focusNode!.requestFocus();
      field.handleKeyEvent(_down(logicalKeyBackspace));
      expect(changes, <String>['set by cod'], reason: 'Backspace is the user');
    });

    test('input formatters rewrite typing, and listeners hear one change', () {
      final TextEditingController controller = TextEditingController();
      final List<String> heard = <String>[];
      controller.addListener(heard.add);
      mount(TextField(
        controller: controller,
        inputFormatters: <TextInputFormatter>[
          FilteringTextInputFormatter.digitsOnly,
        ],
      ));
      type(all<RenderTextField>().single, '1a2');
      expect(controller.text, '12');
      expect(heard, isNot(contains('1a')),
          reason: 'the rejected text is never seen');
    });

    test('formatters apply to a paste too', () async {
      final TextEditingController controller = TextEditingController();
      mount(TextField(
        controller: controller,
        inputFormatters: <TextInputFormatter>[
          FilteringTextInputFormatter.digitsOnly,
        ],
      ));
      clipboard.seedText('tel: 555-1234');
      final RenderTextField field = all<RenderTextField>().single;
      field.focusNode!.requestFocus();
      field.handleKeyEvent(_down(0x56, modifiers: <KeyModifier>{
        platformEditingConvention.commandModifier,
      }));
      await field.clipboardSettled;
      expect(controller.text, '5551234');
    });

    test('maxLength stops typing and fills the counter', () {
      final TextEditingController controller = TextEditingController();
      mount(TextField(
        controller: controller,
        maxLength: 3,
        decoration: const InputDecoration(labelText: 'Code'),
      ));
      type(all<RenderTextField>().single, 'abcdef');
      expect(controller.text, 'abc');
      expect(
        all<RenderText>().map((RenderText t) => t.text),
        contains('3/3'),
      );
    });

    test('an unenforced maxLength lets the text grow and shows the error', () {
      final TextEditingController controller = TextEditingController('abcd');
      mount(TextField(
        controller: controller,
        maxLength: 3,
        maxLengthEnforcement: MaxLengthEnforcement.none,
        decoration: const InputDecoration(),
      ));
      final RenderInputDecorator decorator = all<RenderInputDecorator>().single;
      expect(decorator.decoration.hasError, isTrue);
      expect(decorator.effectiveBorder.borderSide.color,
          ThemeData.neutralLight.colorScheme.error);
    });

    test('Enter with textInputAction.next moves focus to the next field', () {
      final List<String> submitted = <String>[];
      mount(Column(children: <Widget>[
        TextField(
          textInputAction: TextInputAction.next,
          onSubmitted: submitted.add,
        ),
        const TextField(textInputAction: TextInputAction.done),
      ]));
      final List<RenderTextField> fields = all<RenderTextField>();
      type(fields[0], 'x');
      expect(fields[0].handleKeyEvent(_down(logicalKeyEnter)), isTrue);
      frame();
      expect(fields[1].hasFocus, isTrue);
      expect(submitted, <String>['x'], reason: 'onSubmitted after the move');
      // done gives focus up.
      fields[1].handleKeyEvent(_down(logicalKeyEnter));
      frame();
      expect(fields[1].hasFocus, isFalse);
      expect(fields[0].hasFocus, isFalse);
    });

    test('previous moves back; onEditingComplete replaces the move', () {
      int completed = 0;
      mount(Column(children: <Widget>[
        const TextField(),
        TextField(
          textInputAction: TextInputAction.previous,
          onEditingComplete: () => completed++,
        ),
        const TextField(textInputAction: TextInputAction.previous),
      ]));
      final List<RenderTextField> fields = all<RenderTextField>();
      fields[2].focusNode!.requestFocus();
      fields[2].handleKeyEvent(_down(logicalKeyEnter));
      expect(fields[1].hasFocus, isTrue);
      fields[1].handleKeyEvent(_down(logicalKeyEnter));
      expect(completed, 1);
      expect(fields[1].hasFocus, isTrue, reason: 'the callback replaced it');
    });

    test('Enter in a field with no action and no callback is not claimed', () {
      mount(const TextField());
      final RenderTextField field = all<RenderTextField>().single;
      field.focusNode!.requestFocus();
      expect(field.handleKeyEvent(_down(logicalKeyEnter)), isFalse,
          reason: "a dialog's default button still hears it");
      expect(field.hasFocus, isTrue);
    });

    test('keyboardType and textCapitalization reach the input method', () {
      mount(const TextField(
        keyboardType: TextInputType.emailAddress,
        textCapitalization: TextCapitalization.sentences,
      ));
      final TextInputConfiguration config =
          all<RenderTextField>().single.textInputConfiguration;
      expect(config.purpose, ImeContentPurpose.email);
      expect(config.hints, contains(ImeContentHint.autoCapitalization));
    });

    test('the label rests inside an empty field and floats on focus', () {
      mount(const TextField(
        decoration: InputDecoration(
          labelText: 'Name',
          hintText: 'Full name',
          border: OutlineInputBorder(),
        ),
      ));
      final RenderInputDecorator decorator = all<RenderInputDecorator>().single;
      final RenderTextField field = all<RenderTextField>().single;
      expect(decorator.labelIsFloating, isFalse);
      expect(field.label, 'Name', reason: 'the resting label is in the field');
      field.focusNode!.requestFocus();
      frame();
      expect(decorator.labelIsFloating, isTrue);
      expect(field.label, 'Full name', reason: 'the hint once it floats');
      expect(decorator.effectiveBorder.borderSide.color,
          ThemeData.neutralLight.accent);
      expect(decorator.effectiveBorder.borderSide.width, 2);
    });

    test('helper text below, replaced by the error', () {
      mount(const TextField(
        decoration: InputDecoration(
          helperText: 'Help',
          errorText: 'Wrong',
        ),
      ));
      final List<String> texts =
          all<RenderText>().map((RenderText t) => t.text).toList();
      expect(texts, contains('Wrong'));
      expect(texts, isNot(contains('Help')));
      expect(all<RenderTextField>().single.describeSemantics().states,
          contains(SemanticsState.invalid));
    });

    test('a per-state border keeps its own colour', () {
      const Color red = Color(0xFFFF0000);
      mount(const TextField(
        decoration: InputDecoration(
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: red),
          ),
          border: OutlineInputBorder(),
        ),
      ));
      expect(
          all<RenderInputDecorator>().single.effectiveBorder.borderSide.color,
          red);
    });

    test('a field without a decoration renders as it always has', () {
      mount(TextField(controller: TextEditingController('x')));
      expect(all<RenderInputDecorator>(), isEmpty);
      expect(all<RenderTextField>().single.decorated, isTrue);
    });
  });

  group('Form', () {
    test('validate shows every error, save hands over every value', () {
      final GlobalKey<FormState> key = GlobalKey<FormState>();
      final Map<String, String?> saved = <String, String?>{};
      mount(Form(
        key: key,
        child: Column(children: <Widget>[
          TextFormField(
            initialValue: '',
            validator: (String? v) => (v ?? '').isEmpty ? 'Required' : null,
            onSaved: (String? v) => saved['name'] = v,
          ),
          TextFormField(
            initialValue: 'ok@example.com',
            validator: (String? v) => v!.contains('@') ? null : 'Bad e-mail',
            onSaved: (String? v) => saved['mail'] = v,
          ),
        ]),
      ));
      expect(all<RenderText>().map((RenderText t) => t.text),
          isNot(contains('Required')),
          reason: 'nothing is validated before it is asked for');
      expect(key.currentState!.validate(), isFalse);
      frame();
      expect(all<RenderText>().map((RenderText t) => t.text),
          contains('Required'));
      type(all<RenderTextField>().first, 'Isaque');
      expect(key.currentState!.validate(), isTrue);
      frame();
      expect(all<RenderText>().map((RenderText t) => t.text),
          isNot(contains('Required')));
      key.currentState!.save();
      expect(saved, <String, String?>{
        'name': 'Isaque',
        'mail': 'ok@example.com',
      });
    });

    test('validateGranularly returns the invalid fields', () {
      final GlobalKey<FormState> key = GlobalKey<FormState>();
      mount(Form(
        key: key,
        child: Column(children: <Widget>[
          TextFormField(validator: (String? v) => 'always bad'),
          TextFormField(validator: (String? v) => null),
        ]),
      ));
      final Set<FormFieldState<Object?>> invalid =
          key.currentState!.validateGranularly();
      expect(invalid, hasLength(1));
      expect(invalid.single.errorText, 'always bad');
    });

    test('reset puts the text back and clears the errors', () {
      final GlobalKey<FormState> key = GlobalKey<FormState>();
      mount(Form(
        key: key,
        child: TextFormField(
          initialValue: 'start',
          validator: (String? v) => v == 'start' ? null : 'Changed',
        ),
      ));
      final RenderTextField field = all<RenderTextField>().single;
      type(field, '!');
      key.currentState!.validate();
      frame();
      expect(key.currentState!.fields.single.hasError, isTrue);
      key.currentState!.reset();
      frame();
      expect(field.controller.text, 'start');
      expect(key.currentState!.fields.single.hasError, isFalse);
    });

    test('onUserInteraction validates once the user has typed', () {
      int changes = 0;
      mount(Form(
        autovalidateMode: AutovalidateMode.onUserInteraction,
        onChanged: () => changes++,
        child: TextFormField(
          validator: (String? v) => (v ?? '').length < 3 ? 'Too short' : null,
        ),
      ));
      final RenderTextField field = all<RenderTextField>().single;
      expect(all<RenderText>().map((RenderText t) => t.text),
          isNot(contains('Too short')));
      type(field, 'ab');
      expect(changes, 2);
      expect(all<RenderText>().map((RenderText t) => t.text),
          contains('Too short'));
      type(field, 'c');
      expect(all<RenderText>().map((RenderText t) => t.text),
          isNot(contains('Too short')));
    });

    test('always validates from the first frame', () {
      mount(Form(
        autovalidateMode: AutovalidateMode.always,
        child: TextFormField(validator: (String? v) => 'Needed'),
      ));
      expect(
          all<RenderText>().map((RenderText t) => t.text), contains('Needed'));
    });

    test('onUnfocus validates when focus leaves the field', () {
      mount(Form(
        autovalidateMode: AutovalidateMode.onUnfocus,
        child: Column(children: <Widget>[
          TextFormField(validator: (String? v) => 'Left empty'),
          TextFormField(),
        ]),
      ));
      final List<RenderTextField> fields = all<RenderTextField>();
      fields[0].focusNode!.requestFocus();
      frame();
      expect(all<RenderText>().map((RenderText t) => t.text),
          isNot(contains('Left empty')));
      fields[1].focusNode!.requestFocus();
      frame();
      expect(all<RenderText>().map((RenderText t) => t.text),
          contains('Left empty'));
    });

    test('a FormField of any type: didChange, value and isValid', () {
      final GlobalKey<FormFieldState<int>> key =
          GlobalKey<FormFieldState<int>>();
      mount(Form(
        child: FormField<int>(
          key: key,
          initialValue: 1,
          validator: (int? v) => v! > 2 ? 'Too big' : null,
          builder: (FormFieldState<int> field) =>
              Text('value ${field.value} ${field.errorText ?? ''}'),
        ),
      ));
      final FormFieldState<int> state = key.currentState!;
      expect(state.value, 1);
      expect(state.isValid, isTrue);
      state.didChange(5);
      expect(state.hasInteractedByUser, isTrue);
      expect(state.isValid, isFalse);
      expect(state.validate(), isFalse);
      frame();
      expect(all<RenderText>().single.text, 'value 5 Too big');
      state.reset();
      frame();
      expect(state.value, 1);
      expect(state.hasError, isFalse);
    });

    test('forceErrorText shows whatever the validator says', () {
      mount(Form(
        child: TextFormField(
          forceErrorText: 'From the server',
          validator: (String? v) => null,
        ),
      ));
      expect(all<RenderText>().map((RenderText t) => t.text),
          contains('From the server'));
    });

    test('Form.of throws a StateError outside a form', () {
      late BuildContext captured;
      mount(_Capture((BuildContext context) => captured = context));
      expect(Form.maybeOf(captured), isNull);
      expect(() => Form.of(captured), throwsStateError);
    });

    test('TextFormField refuses a controller and an initialValue together', () {
      expect(
        () => TextFormField(
          controller: TextEditingController(),
          initialValue: 'x',
        ),
        throwsArgumentError,
      );
    });

    test('a controller given to TextFormField is its value', () {
      final GlobalKey<FormState> key = GlobalKey<FormState>();
      final TextEditingController controller = TextEditingController('abc');
      String? saved;
      mount(Form(
        key: key,
        child: TextFormField(
          controller: controller,
          onSaved: (String? v) => saved = v,
        ),
      ));
      controller.text = 'changed by code';
      frame();
      key.currentState!.save();
      expect(saved, 'changed by code');
    });
  });
}

final class _Capture extends StatelessWidget {
  const _Capture(this.onBuild);

  final void Function(BuildContext context) onBuild;

  @override
  Widget build(BuildContext context) {
    onBuild(context);
    return const SizedBox();
  }
}
