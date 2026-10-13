/// Edit: undo and redo, the clipboard, duplicate, select all and none.
library;

import 'dart:typed_data';

import 'package:dart_ui/commands.dart';
import 'package:dart_ui/vector.dart';

import '../editor_host.dart';
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
      run: (_) {
        model.copySelection();
        // And as a picture on the system clipboard, for other applications;
        // pasting here keeps using the objects themselves.
        final Object host = context.host;
        if (host is EditorClipboardHost) host.copyPicture(model.copiedObjects);
        return null;
      },
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
      id: 'edit.pasteSpecial',
      label: 'Paste Special...',
      description: 'Pastes in a chosen format: the objects copied here, or '
          'the image or the text on the system clipboard - text that is an '
          'SVG drawing comes in as its objects. Asks which without a format.',
      shortcut: const KeyGesture(logicalKeyV, command: true, shift: true),
      params: const <CommandParam>[
        CommandParam('format', CommandParamType.string,
            description: 'objects, image or text'),
      ],
      when: context.needsDocument,
      run: (CommandArgs args) async {
        final Object host = context.host;
        final EditorClipboardHost? system =
            host is EditorClipboardHost ? host : null;
        if (!args.has('format')) {
          final Set<String> formats = <String>{
            if (model.canPaste) 'objects',
            ...?await system?.clipboardFormats(),
          };
          if (formats.isEmpty) {
            throw const CommandError('the clipboard is empty');
          }
          if (system == null) {
            throw CommandError('give a format: ${formats.join(', ')}');
          }
          system.choosePasteFormat(formats.toList());
          return null;
        }
        final String format =
            oneOf(args, 'format', const <String>['objects', 'image', 'text']);
        switch (format) {
          case 'objects':
            if (!model.canPaste) {
              throw const CommandError('nothing has been copied here');
            }
            model.paste();
          case 'image':
            final Uint8List? png = await system?.clipboardImage();
            if (png == null || !model.pasteImage(png)) {
              throw const CommandError('there is no image on the clipboard');
            }
          case 'text':
            final String? text = await system?.clipboardText();
            if (text == null || text.isEmpty) {
              throw const CommandError('there is no text on the clipboard');
            }
            model.pasteText(text);
        }
        return null;
      },
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
      description: 'Everything on the page, or only one kind of object.',
      params: const <CommandParam>[
        CommandParam('type', CommandParamType.string,
            description: 'objects (the default), text, curves, rectangles, '
                'ellipses, polygons or groups'),
      ],
      shortcut: const KeyGesture(logicalKeyA, command: true),
      when: context.needsDocument,
      run: (CommandArgs args) {
        if (!args.has('type')) {
          model.selectAll();
          return <String, Object?>{'selected': model.selection.count};
        }
        final String type = oneOf(args, 'type', const <String>[
          'objects',
          'text',
          'curves',
          'rectangles',
          'ellipses',
          'polygons',
          'groups',
        ]);
        return <String, Object?>{'selected': model.selectAllOfType(type)};
      },
    ),
    CommandSpec(
      id: 'edit.findReplace',
      label: 'Find and Replace...',
      shortcut: const KeyGesture(logicalKeyH, command: true),
      when: context.needsDocument,
      run: (_) {
        context.host.findReplace();
        return null;
      },
    ),
    CommandSpec(
      id: 'edit.replaceText',
      label: 'Replace Text',
      description: 'Replaces a string in every text object on the page, as '
          'one undo step - Find and Replace for text.',
      params: const <CommandParam>[
        CommandParam('find', CommandParamType.string, required: true),
        CommandParam('replace', CommandParamType.string, required: true),
        CommandParam('matchCase', CommandParamType.boolean,
            description: 'true by default'),
      ],
      when: context.needsDocument,
      run: (CommandArgs args) => <String, Object?>{
        'replaced': model.replaceText(
          args['find']! as String,
          args['replace']! as String,
          matchCase: !args.has('matchCase') || args['matchCase'] == true,
        ),
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
