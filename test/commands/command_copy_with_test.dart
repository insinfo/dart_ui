import 'package:dart_ui/commands.dart';
import 'package:test/test.dart';

void main() {
  test('a translated command keeps its id, keys and behaviour', () {
    var runs = 0;
    final CommandSpec cut = CommandSpec(
      id: 'file.cut',
      label: 'Cut',
      shortcut: const KeyGesture(logicalKeyX, command: true),
      when: (_) => null,
      run: (_) => runs++,
    );
    final CommandSpec recortar = cut.copyWith(label: 'Recortar');
    expect(recortar.id, 'file.cut');
    expect(recortar.label, 'Recortar');
    expect(recortar.shortcut, cut.shortcut);
    expect(recortar.isEnabled, isTrue);
    recortar.run(CommandArgs.empty);
    expect(runs, 1);
  });
}
