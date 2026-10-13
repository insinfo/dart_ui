/// Navigation: back, forward, up, refresh, the places, the address and
/// search.
library;

import 'dart:async';

import 'package:dart_ui/commands.dart';

import '../explorer_model.dart';
import '../location.dart';
import 'command_context.dart';

List<CommandSpec> navigationCommands(ExplorerContext context) {
  final ExplorerModel model = context.model;
  return <CommandSpec>[
    CommandSpec(
      id: 'nav.back',
      label: 'Back',
      shortcut: const KeyGesture(logicalKeyArrowLeft, alt: true),
      alsoShortcuts: const <KeyGesture>[KeyGesture(logicalKeyBackspace)],
      when: (_) => model.canGoBack ? null : 'there is nowhere to go back to',
      run: (_) => unawaited(model.goBack()),
    ),
    CommandSpec(
      id: 'nav.forward',
      label: 'Forward',
      shortcut: const KeyGesture(logicalKeyArrowRight, alt: true),
      when: (_) =>
          model.canGoForward ? null : 'there is nowhere to go forward to',
      run: (_) => unawaited(model.goForward()),
    ),
    CommandSpec(
      id: 'nav.up',
      label: 'Up',
      shortcut: const KeyGesture(logicalKeyArrowUp, alt: true),
      when: (_) => model.canGoUp ? null : 'this is the top',
      run: (_) => unawaited(model.goUp()),
    ),
    CommandSpec(
      id: 'nav.refresh',
      label: 'Refresh',
      shortcut: const KeyGesture(logicalKeyF5),
      alsoShortcuts: const <KeyGesture>[
        KeyGesture(logicalKeyR, command: true),
      ],
      run: (_) => unawaited(model.refresh()),
    ),
    CommandSpec(
      id: 'nav.home',
      label: 'Home',
      run: (_) => unawaited(model.navigate(const HomeLocation())),
    ),
    CommandSpec(
      id: 'nav.thisPc',
      label: 'This PC',
      run: (_) => unawaited(model.navigate(const ThisPcLocation())),
    ),
    CommandSpec(
      id: 'nav.go',
      label: 'Go to',
      description: 'Opens the folder at path in this tab.',
      params: const <CommandParam>[
        CommandParam('path', CommandParamType.string, required: true),
      ],
      run: (CommandArgs args) =>
          unawaited(model.navigate(FolderLocation(args.string('path')))),
    ),
    CommandSpec(
      id: 'nav.place',
      label: 'Go to a known folder',
      params: const <CommandParam>[
        CommandParam('place', CommandParamType.string,
            required: true,
            description: 'desktop, downloads, documents, pictures, music, '
                'videos or home'),
      ],
      run: (CommandArgs args) {
        final Place place = Place.values.byName(args.string('place'));
        final String? path = model.places[place];
        if (path == null) {
          throw CommandError('this machine has no ${place.name} folder');
        }
        unawaited(model.navigate(FolderLocation(path)));
        return null;
      },
    ),
    CommandSpec(
      id: 'nav.editAddress',
      label: 'Edit address',
      shortcut: const KeyGesture(logicalKeyL, command: true),
      alsoShortcuts: const <KeyGesture>[KeyGesture(logicalKeyD, alt: true)],
      run: (_) => context.host.focusAddress(),
    ),
    CommandSpec(
      id: 'nav.focusSearch',
      label: 'Search',
      shortcut: const KeyGesture(logicalKeyF, command: true),
      alsoShortcuts: const <KeyGesture>[
        KeyGesture(logicalKeyE, command: true),
        KeyGesture(logicalKeyF3),
      ],
      when: (_) => model.currentFolder == null ? 'not in a folder' : null,
      run: (_) => context.host.focusSearch(),
    ),
    CommandSpec(
      id: 'nav.search',
      label: 'Search for',
      description: 'Finds what matches query in this folder and below; an '
          'empty query goes back to the folder.',
      params: const <CommandParam>[
        CommandParam('query', CommandParamType.string, required: true),
      ],
      when: (_) => model.currentFolder == null ? 'not in a folder' : null,
      run: (CommandArgs args) => unawaited(model.search(args.string('query'))),
    ),
  ];
}
