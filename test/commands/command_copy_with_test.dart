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

  test(
      'a translated reason: the same commands disabled, saying why in the '
      'language of the label', () {
    final CommandSpec copy = CommandSpec(
      id: 'file.copy',
      label: 'Copy',
      when: (CommandArgs args) =>
          args.has('item') ? null : 'nothing is selected',
      run: (_) => null,
    );
    final CommandSpec copiar = copy.copyWith(
      label: 'Copiar',
      reason: (String english) => english == 'nothing is selected'
          ? 'nenhum item selecionado'
          : english,
    );
    expect(copiar.isEnabled, isFalse);
    expect(copiar.disabledReasonWith(CommandArgs.empty),
        'nenhum item selecionado');
    const CommandArgs picked = CommandArgs(<String, Object?>{'item': 'a'});
    expect(copiar.isEnabledWith(picked), isTrue);
    expect(copiar.disabledReasonWith(picked), isNull);

    // The enabled/disabledReason pair is translated the same way.
    final CommandSpec paste = CommandSpec(
      id: 'file.paste',
      label: 'Paste',
      enabled: (_) => false,
      disabledReason: (_) => 'the clipboard is empty',
      run: (_) => null,
    ).copyWith(reason: (String english) => '<$english>');
    expect(paste.disabledReasonWith(CommandArgs.empty),
        '<the clipboard is empty>');
    expect(copy.copyWith().disabledReasonWith(CommandArgs.empty),
        'nothing is selected',
        reason: 'no translator, the reason as it was');
  });
}
