import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  late CommandRegistry registry;
  var ready = false;
  var runs = 0;

  setUp(() {
    ready = false;
    runs = 0;
    registry = CommandRegistry()
      ..register(CommandSpec(
        id: 'thing.do',
        label: 'Do the thing',
        shortcut: const KeyGesture(logicalKeyD, alt: true),
        when: (_) => ready ? null : 'nothing to do it to',
        run: (_) => runs++,
      ));
  });

  test('a command that can run shows its label and shortcut', () {
    ready = true;
    final String keys = const KeyGesture(logicalKeyD, alt: true).label();
    expect(CommandIconButton.tooltipOf(registry, 'thing.do'),
        'Do the thing ($keys)');
  });

  test('one that cannot says why', () {
    expect(CommandIconButton.tooltipOf(registry, 'thing.do'),
        'Do the thing - nothing to do it to');
  });

  test('a label given by the caller wins', () {
    ready = true;
    expect(
        CommandIconButton.tooltipOf(registry, 'thing.do', label: 'Go')
            .startsWith('Go ('),
        isTrue);
  });

  test('an unknown command is named, not a crash', () {
    expect(CommandIconButton.tooltipOf(registry, 'no.such'), 'no.such');
  });
}
