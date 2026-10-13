/// Files: open, new, rename, delete, the clipboard, Copy as path,
/// Properties, pin to Quick access.
library;

import 'dart:async';

import 'package:dart_ui/commands.dart';

import '../explorer_model.dart';
import '../file_system.dart';
import '../location.dart';
import 'command_context.dart';

List<CommandSpec> fileCommands(ExplorerContext context) {
  final ExplorerModel model = context.model;
  final bool mac = platformEditingConvention == EditingConvention.mac;
  return <CommandSpec>[
    CommandSpec(
      id: 'file.open',
      label: 'Open',
      description: 'Opens the selected folders here and the files in their '
          'applications.',
      when: context.needsSelection,
      run: (_) {
        final List<FileEntry> picked = model.selectedEntries;
        final List<FileEntry> folders =
            picked.where((FileEntry e) => e.isDirectory).toList();
        for (final FileEntry file in picked.where((e) => !e.isDirectory)) {
          unawaited(model.open(file));
        }
        // One folder opens here; more open in tabs of their own.
        if (folders.length == 1) {
          unawaited(model.open(folders.single));
        } else {
          for (final FileEntry folder in folders) {
            unawaited(model.newTab(FolderLocation(folder.path)));
          }
        }
        return null;
      },
    ),
    CommandSpec(
      id: 'file.openInNewTab',
      label: 'Open in new tab',
      when: (CommandArgs args) =>
          context.needsSelection(args) ??
          (model.selectedEntries.any((FileEntry e) => e.isDirectory)
              ? null
              : 'select a folder'),
      run: (_) {
        for (final FileEntry folder
            in model.selectedEntries.where((e) => e.isDirectory)) {
          unawaited(model.newTab(FolderLocation(folder.path)));
        }
        return null;
      },
    ),
    CommandSpec(
      id: 'file.newFolder',
      label: 'Folder',
      description: 'Makes a new folder here and starts renaming it.',
      shortcut: const KeyGesture(logicalKeyN, command: true, shift: true),
      when: context.needsFolder,
      run: (_) => unawaited(model.newFolder()),
    ),
    CommandSpec(
      id: 'file.newTextDocument',
      label: 'Text Document',
      when: context.needsFolder,
      run: (_) => unawaited(model.newTextDocument()),
    ),
    CommandSpec(
      id: 'file.rename',
      label: 'Rename',
      shortcut: const KeyGesture(logicalKeyF2),
      params: const <CommandParam>[
        CommandParam('name', CommandParamType.string,
            description: 'the new name; without it the item is renamed in '
                'place'),
      ],
      when: (CommandArgs args) =>
          context.needsSelection(args) ??
          (model.canCreateHere ? null : 'not in a folder'),
      run: (CommandArgs args) {
        if (!args.has('name')) {
          model.beginRename();
          return null;
        }
        final List<FileEntry> picked = model.selectedEntries;
        if (picked.length != 1) throw const CommandError('select one item');
        unawaited(model.rename(picked.single.path, args.string('name')));
        return null;
      },
    ),
    CommandSpec(
      id: 'file.delete',
      label: 'Delete',
      description: 'Sends the selection to the trash.',
      shortcut: mac
          ? const KeyGesture(logicalKeyBackspace, command: true)
          : const KeyGesture(logicalKeyDelete),
      alsoShortcuts: const <KeyGesture>[
        KeyGesture(logicalKeyD, command: true),
      ],
      when: (CommandArgs args) =>
          context.needsSelection(args) ??
          (model.canCreateHere || model.tab.location is SearchLocation
              ? null
              : 'not in a folder'),
      run: (_) => unawaited(model.deleteSelection()),
    ),
    CommandSpec(
      id: 'file.cut',
      label: 'Cut',
      shortcut: const KeyGesture(logicalKeyX, command: true),
      when: context.needsSelection,
      run: (_) => model.cutSelection(),
    ),
    CommandSpec(
      id: 'file.copy',
      label: 'Copy',
      shortcut: const KeyGesture(logicalKeyC, command: true),
      when: context.needsSelection,
      run: (_) => model.copySelection(),
    ),
    CommandSpec(
      id: 'file.paste',
      label: 'Paste',
      shortcut: const KeyGesture(logicalKeyV, command: true),
      when: (CommandArgs args) =>
          context.needsFolder(args) ??
          (model.clipboard == null ? 'nothing has been cut or copied' : null),
      run: (_) => unawaited(model.paste()),
    ),
    CommandSpec(
      id: 'file.copyPath',
      label: 'Copy as path',
      shortcut: const KeyGesture(logicalKeyC, command: true, shift: true),
      when: context.needsSelection,
      run: (_) {
        context.host.copyText(model.selectionAsPaths);
        return model.selectionAsPaths;
      },
    ),
    CommandSpec(
      id: 'file.properties',
      label: 'Properties',
      shortcut: const KeyGesture(logicalKeyEnter, alt: true),
      when: context.needsSelection,
      run: (_) => context.host.showProperties(model.selectedEntries),
    ),
    CommandSpec(
      id: 'file.reveal',
      label: 'Show in the system file manager',
      when: context.needsOneSelected,
      run: (_) => unawaited(model.fs.reveal(model.selectedEntries.single.path)),
    ),
    CommandSpec(
      id: 'file.pin',
      label: 'Pin to Quick access',
      when: (CommandArgs args) =>
          context.needsOneSelected(args) ??
          (!model.selectedEntries.single.isDirectory
              ? 'only folders can be pinned'
              : model.pinned.contains(model.selectedEntries.single.path)
                  ? 'already pinned'
                  : null),
      run: (_) => model.pin(model.selectedEntries.single.path),
    ),
    CommandSpec(
      id: 'file.unpin',
      label: 'Unpin from Quick access',
      params: const <CommandParam>[
        CommandParam('path', CommandParamType.string, required: true),
      ],
      run: (CommandArgs args) => model.unpin(args.string('path')),
    ),
  ];
}
