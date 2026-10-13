/// Tabs: new, close, next, previous, duplicate, reopen.
library;

import 'dart:async';

import 'package:dart_ui/commands.dart';

import '../explorer_model.dart';
import 'command_context.dart';

List<CommandSpec> tabCommands(ExplorerContext context) {
  final ExplorerModel model = context.model;
  return <CommandSpec>[
    CommandSpec(
      id: 'tab.new',
      label: 'New tab',
      shortcut: const KeyGesture(logicalKeyT, command: true),
      run: (_) => unawaited(model.newTab()),
    ),
    CommandSpec(
      id: 'tab.close',
      label: 'Close tab',
      shortcut: const KeyGesture(logicalKeyW, command: true),
      alsoShortcuts: const <KeyGesture>[
        KeyGesture(logicalKeyF4, command: true),
      ],
      params: const <CommandParam>[
        CommandParam('index', CommandParamType.integer,
            description: 'the active tab when left out'),
      ],
      run: (CommandArgs args) {
        final int index = args.integer('index', model.activeIndex);
        if (index < 0 || index >= model.tabs.length) {
          throw CommandError('there is no tab $index');
        }
        // The last tab closes the window, as in Explorer.
        if (!model.closeTab(index)) context.host.closeWindow();
        return null;
      },
    ),
    CommandSpec(
      id: 'tab.select',
      label: 'Switch to tab',
      params: const <CommandParam>[
        CommandParam('index', CommandParamType.integer, required: true),
      ],
      run: (CommandArgs args) => model.selectTab(args.integer('index')),
    ),
    CommandSpec(
      id: 'tab.next',
      label: 'Next tab',
      shortcut: const KeyGesture(logicalKeyTab, control: true),
      when: (_) => model.tabs.length > 1 ? null : 'there is one tab',
      run: (_) => model.selectTab((model.activeIndex + 1) % model.tabs.length),
    ),
    CommandSpec(
      id: 'tab.previous',
      label: 'Previous tab',
      shortcut: const KeyGesture(logicalKeyTab, control: true, shift: true),
      when: (_) => model.tabs.length > 1 ? null : 'there is one tab',
      run: (_) => model.selectTab(
          (model.activeIndex - 1 + model.tabs.length) % model.tabs.length),
    ),
    CommandSpec(
      id: 'tab.duplicate',
      label: 'Duplicate tab',
      shortcut: const KeyGesture(logicalKeyK, command: true, shift: true),
      run: (_) => unawaited(model.duplicateTab()),
    ),
    CommandSpec(
      id: 'tab.reopen',
      label: 'Reopen closed tab',
      shortcut: const KeyGesture(logicalKeyT, command: true, shift: true),
      when: (_) => model.closedTabs.isEmpty ? 'no tab has been closed' : null,
      run: (_) => unawaited(model.reopenClosedTab()),
    ),
  ];
}
