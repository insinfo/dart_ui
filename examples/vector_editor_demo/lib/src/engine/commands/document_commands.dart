/// Documents (tabs) and help.
library;

import 'package:dart_ui/commands.dart';

import '../editor_model.dart';
import 'command_context.dart';

List<CommandSpec> documentCommands(EditorContext context) {
  final EditorModel model = context.model;
  return <CommandSpec>[
    CommandSpec(
      id: 'document.select',
      label: 'Switch to tab',
      params: const <CommandParam>[
        CommandParam('index', CommandParamType.integer, required: true),
      ],
      when: context.needsDocument,
      run: (CommandArgs args) {
        final int index = args.integer('index');
        if (index < 0 || index >= model.documents.length) {
          throw CommandError('there are ${model.documents.length} tabs; '
              '$index is not one');
        }
        model.selectDocument(index);
        return null;
      },
    ),
    CommandSpec(
      id: 'help.about',
      label: 'About this editor',
      run: (_) {
        model.refresh('Vector Editor - 100% pure Dart');
        return null;
      },
    ),
  ];
}
