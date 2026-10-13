/// Selection by index or by point - what an automation client or a script
/// uses where a person clicks.
library;

import 'package:dart_ui/commands.dart';
import 'package:dart_ui/vector.dart';

import '../editor_model.dart';
import 'command_context.dart';

List<CommandSpec> selectionCommands(EditorContext context) {
  final EditorModel model = context.model;
  return <CommandSpec>[
    CommandSpec(
      id: 'selection.select',
      label: 'Select object',
      description: 'Selects object [index] of the active layer, bottom '
          'first; with add, adds it.',
      params: const <CommandParam>[
        CommandParam('index', CommandParamType.integer, required: true),
        CommandParam('add', CommandParamType.boolean),
      ],
      when: context.needsDocument,
      run: (CommandArgs args) {
        final List<SelectableObject> objects = context.layerObjects;
        final int index = args.integer('index');
        if (index < 0 || index >= objects.length) {
          throw CommandError('the active layer has ${objects.length} '
              'objects; $index is not one');
        }
        model.pickObject(objects[index], toggle: args.flag('add'));
        return <String, Object?>{'selected': model.selection.count};
      },
    ),
    CommandSpec(
      id: 'selection.at',
      label: 'Select at point',
      description: 'Selects the topmost object at x, y (document units), or '
          'clears the selection.',
      params: const <CommandParam>[
        CommandParam('x', CommandParamType.number, required: true),
        CommandParam('y', CommandParamType.number, required: true),
      ],
      when: context.needsDocument,
      run: (CommandArgs args) {
        final DocumentSession session = model.active;
        final SelectableObject? hit = session.selection.hitTest(
          Offset(args.number('x'), args.number('y')),
          session.page,
          tolerance: 2,
        );
        if (hit == null) {
          model.deselect();
          return <String, Object?>{'selected': 0};
        }
        model.pickObject(hit);
        return <String, Object?>{
          'selected': 1,
          'index': context.layerObjects.indexOf(hit),
        };
      },
    ),
  ];
}
