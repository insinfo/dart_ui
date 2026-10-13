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
  late TextEditingController controller;
  late RenderTextField field;
  final List<String> submitted = <String>[];

  setUp(() {
    submitted.clear();
    controller = TextEditingController('C:\\Users');
    field = RenderTextField(
      controller: controller,
      label: 'Address',
      obscure: false,
      readOnly: false,
    );
  });

  test('Enter confirms the value when someone listens', () {
    field.onSubmitted = submitted.add;
    expect(field.handleKeyEvent(_down(logicalKeyEnter)), isTrue);
    expect(submitted, <String>['C:\\Users']);
  });

  test('with no listener Enter is left to the window', () {
    expect(field.handleKeyEvent(_down(logicalKeyEnter)), isFalse);
  });

  test('Shift+Enter and Alt+Enter are not a submit', () {
    field.onSubmitted = submitted.add;
    field
      ..handleKeyEvent(
          _down(logicalKeyEnter, modifiers: const {KeyModifier.shift}))
      ..handleKeyEvent(
          _down(logicalKeyEnter, modifiers: const {KeyModifier.alt}));
    expect(submitted, isEmpty);
  });
}
