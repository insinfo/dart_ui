/// Tabs: new, close, next, previous, duplicate, reopen.
library;

import 'dart:async';

import 'package:dart_ui/commands.dart';

import '../explorer_model.dart';
import 'command_context.dart';

List<CommandSpec> tabCommands(ExplorerContext context) {
  final ExplorerModel model = context.model;
  return <CommandSpec>[
    for (final (id, label, left, right) in <(String, String, bool, bool)>[
      ('tab.closeOthers', 'Close other tabs', false, false),
      ('tab.closeLeft', 'Close tabs to the left', true, false),
      ('tab.closeRight', 'Close tabs to the right', false, true),
    ])
      CommandSpec(
          id: id,
          label: label,
          when: (_) => model.tabs.length > 1 ? null : 'there is one tab',
          run: (_) => model.closeOtherTabs(left: left, right: right)),
    CommandSpec(
        id: 'tab.moveLeft',
        label: 'Move tab left',
        when: (_) => model.activeIndex > 0 ? null : 'this is the first tab',
        run: (_) => model.moveTab(model.activeIndex, model.activeIndex - 1)),
    CommandSpec(
        id: 'tab.moveRight',
        label: 'Move tab right',
        when: (_) => model.activeIndex + 1 < model.tabs.length
            ? null
            : 'this is the last tab',
        run: (_) => model.moveTab(model.activeIndex, model.activeIndex + 1)),
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
