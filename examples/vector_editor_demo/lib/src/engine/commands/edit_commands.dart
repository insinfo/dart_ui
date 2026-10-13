/// Edit: undo and redo, the clipboard, duplicate, select all and none.
library;

import 'package:dart_ui/commands.dart';
import 'package:dart_ui/vector.dart';

import '../editor_model.dart';
import 'command_context.dart';

List<CommandSpec> editCommands(EditorContext context) {
  final EditorModel model = context.model;
  final bool mac = platformEditingConvention == EditingConvention.mac;
  return <CommandSpec>[
    CommandSpec(
      id: 'edit.undo',
      label: 'Undo',
      currentLabel: (_) {
        final String? last =
            model.hasDocument ? model.active.api.undoDescription : null;
        return last == null ? 'Undo' : 'Undo $last';
      },
      shortcut: const KeyGesture(logicalKeyZ, command: true),
      when: (CommandArgs args) =>
          context.needsDocument(args) ??
          (model.active.api.canUndo ? null : 'there is nothing to undo'),
      run: (_) => model.undo(),
    ),
    CommandSpec(
      id: 'edit.redo',
      label: 'Redo',
      currentLabel: (_) {
        final String? next =
            model.hasDocument ? model.active.api.redoDescription : null;
        return next == null ? 'Redo' : 'Redo $next';
      },
      shortcut: const KeyGesture(logicalKeyZ, command: true, shift: true),
      when: (CommandArgs args) =>
          context.needsDocument(args) ??
          (model.active.api.canRedo ? null : 'there is nothing to redo'),
      run: (_) => model.redo(),
    ),
    CommandSpec(
      id: 'edit.cut',
      label: 'Cut',
      shortcut: const KeyGesture(logicalKeyX, command: true),
      when: context.needsSelection,
      run: (_) => model.cutSelection(),
    ),
    CommandSpec(
      id: 'edit.copy',
      label: 'Copy',
      shortcut: const KeyGesture(logicalKeyC, command: true),
      when: context.needsSelection,
      run: (_) => model.copySelection(),
    ),
    CommandSpec(
      id: 'edit.paste',
      label: 'Paste',
      shortcut: const KeyGesture(logicalKeyV, command: true),
      when: (CommandArgs args) =>
          context.needsDocument(args) ??
          (model.canPaste ? null : 'nothing has been copied'),
      run: (_) => model.paste(),
    ),
    CommandSpec(
      id: 'edit.delete',
      label: 'Delete',
      // The Mac's "delete" key is Backspace; its forward delete works too.
      shortcut: mac
          ? const KeyGesture(logicalKeyBackspace)
          : const KeyGesture(logicalKeyDelete),
      alsoShortcuts: mac
          ? const <KeyGesture>[KeyGesture(logicalKeyDelete)]
          : const <KeyGesture>[],
      // With the Shape tool and nodes picked, Delete removes the nodes
      // (path.deleteNodes), not the curve they belong to.
      when: (CommandArgs args) =>
          context.needsSelection(args) ??
          (model.tool == ToolMode.shaper && model.selection.nodes.hasNodes
              ? 'nodes are picked; Delete removes them'
              : null),
      run: (_) => model.deleteSelection(),
    ),
    CommandSpec(
      id: 'edit.duplicate',
      label: 'Duplicate',
      shortcut: const KeyGesture(logicalKeyD, command: true),
      when: context.needsSelection,
      run: (_) => model.duplicateSelection(),
    ),
    CommandSpec(
      id: 'edit.selectAll',
      label: 'Select All',
      shortcut: const KeyGesture(logicalKeyA, command: true),
      when: context.needsDocument,
      run: (_) {
        model.selectAll();
        return <String, Object?>{'selected': model.selection.count};
      },
    ),
    CommandSpec(
      id: 'edit.deselect',
      label: 'Deselect',
      shortcut: const KeyGesture(logicalKeyA, command: true, shift: true),
      alsoShortcuts: const <KeyGesture>[KeyGesture(logicalKeyEscape)],
      when: context.needsSelection,
      run: (_) => model.deselect(),
    ),
  ];
}
