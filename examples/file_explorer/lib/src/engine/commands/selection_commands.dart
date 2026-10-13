/// Selection: all, none, invert, by name.
library;

import 'package:dart_ui/commands.dart';

import '../explorer_model.dart';
import 'command_context.dart';

List<CommandSpec> selectionCommands(ExplorerContext context) {
  final ExplorerModel model = context.model;
  String? anything(CommandArgs _) =>
      model.tab.visible.isEmpty ? 'this view is empty' : null;
  return <CommandSpec>[
    CommandSpec(
      id: 'select.all',
      label: 'Select all',
      shortcut: const KeyGesture(logicalKeyA, command: true),
      when: anything,
      run: (_) => model.selectAll(),
    ),
    CommandSpec(
      id: 'select.none',
      label: 'Select none',
      when: context.needsSelection,
      run: (_) => model.clearSelection(),
    ),
    CommandSpec(
      id: 'select.invert',
      label: 'Invert selection',
      when: anything,
      run: (_) => model.invertSelection(),
    ),
    CommandSpec(
      id: 'select.byName',
      label: 'Select by name',
      description: 'Selects the next item whose name starts with prefix - '
          'typing in the list.',
      params: const <CommandParam>[
        CommandParam('prefix', CommandParamType.string, required: true),
      ],
      when: anything,
      run: (CommandArgs args) => model.selectByPrefix(args.string('prefix')),
    ),
    CommandSpec(
      id: 'select.paths',
      label: 'Select items',
      params: const <CommandParam>[
        CommandParam('paths', CommandParamType.list, required: true),
      ],
      run: (CommandArgs args) => model.select(<String>[
        for (final Object? p in args.list('paths')) '$p',
      ]),
    ),
  ];
}
