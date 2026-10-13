/// File: new, open, save, export, print, close - and quitting.
library;

import 'dart:io';

import 'package:dart_ui/commands.dart';

import '../editor_files.dart';
import '../editor_model.dart';
import 'command_context.dart';

const CommandParam _path = CommandParam(
  'path',
  CommandParamType.string,
  description: 'a file to read or write without asking',
);

List<CommandSpec> fileCommands(EditorContext context) {
  final EditorModel model = context.model;

  Map<String, Object?> write(String path, String format) {
    writeDrawing(model.active, path, format);
    model.refresh('Wrote $path');
    return <String, Object?>{'path': path, 'format': format};
  }

  return <CommandSpec>[
    CommandSpec(
      id: 'file.new',
      label: 'New',
      description: 'A new, empty drawing in a tab of its own.',
      shortcut: const KeyGesture(logicalKeyN, command: true),
      run: (_) {
        model.newDocument();
        return <String, Object?>{'index': model.activeIndex};
      },
    ),
    CommandSpec(
      id: 'file.open',
      label: 'Open...',
      description:
          'Opens an SVG or CorelDRAW drawing; asks which without a path.',
      shortcut: const KeyGesture(logicalKeyO, command: true),
      params: const <CommandParam>[_path],
      run: (CommandArgs args) {
        if (!args.has('path')) {
          context.host.pickAndOpen();
          return null;
        }
        final String path = args.string('path');
        final File file = File(path);
        if (!file.existsSync()) throw CommandError('no file at $path');
        model.addDocument(DocumentSession(
          document: readDrawing(path, file.readAsBytesSync()),
          name: basenameOf(path),
          filePath: path,
        ));
        return <String, Object?>{
          'index': model.activeIndex,
          'name': model.active.name,
        };
      },
    ),
    CommandSpec(
      id: 'file.save',
      label: 'Save',
      description: 'Writes the drawing over its SVG file, or asks where.',
      shortcut: const KeyGesture(logicalKeyS, command: true),
      params: const <CommandParam>[_path],
      when: context.needsDocument,
      run: (CommandArgs args) {
        final String? existing = model.active.filePath;
        final String? path = args.has('path')
            ? args.string('path')
            : (existing != null && formatOf(existing) == 'svg'
                ? existing
                : null);
        if (path == null) {
          // A drawing opened from a CDR is saved as SVG under a new name:
          // writing over the original would lose what the CDR writer
          // cannot keep.
          context.host.pickAndSave('svg');
          return null;
        }
        return write(path, 'svg');
      },
    ),
    CommandSpec(
      id: 'file.saveAs',
      label: 'Save As...',
      shortcut: const KeyGesture(logicalKeyS, command: true, shift: true),
      params: const <CommandParam>[_path],
      when: context.needsDocument,
      run: (CommandArgs args) {
        if (!args.has('path')) {
          context.host.pickAndSave('svg');
          return null;
        }
        return write(args.string('path'), 'svg');
      },
    ),
    CommandSpec(
      id: 'file.export',
      label: 'Export...',
      description: 'Writes the drawing as SVG, PDF or CDR.',
      params: const <CommandParam>[
        CommandParam('format', CommandParamType.string,
            description: "svg, pdf or cdr; the path's extension by default"),
        _path,
      ],
      when: context.needsDocument,
      run: (CommandArgs args) {
        final String? path = args.has('path') ? args.string('path') : null;
        final String format = args.has('format')
            ? args.string('format')
            : (path == null ? 'svg' : formatOf(path));
        if (!kWritableFormats.contains(format)) {
          throw CommandError('cannot export $format; the formats are '
              '${kWritableFormats.join(', ')}');
        }
        if (path == null) {
          context.host.pickAndSave(format);
          return null;
        }
        return write(path, format);
      },
    ),
    CommandSpec(
      id: 'file.print',
      label: 'Print...',
      description: 'Writes a PDF to print from.',
      shortcut: const KeyGesture(logicalKeyP, command: true),
      when: context.needsDocument,
      run: (_) {
        context.host.pickAndSave('pdf');
        return null;
      },
    ),
    CommandSpec(
      id: 'file.close',
      label: 'Close',
      shortcut: const KeyGesture(logicalKeyW, command: true),
      params: const <CommandParam>[
        CommandParam('index', CommandParamType.integer,
            description: 'the tab; the active one by default'),
      ],
      when: context.needsDocument,
      run: (CommandArgs args) {
        context.host.closeDocument(args.integer('index', model.activeIndex));
        return null;
      },
    ),
    CommandSpec(
      id: 'app.quit',
      label: 'Exit',
      // Each platform's own: Cmd+Q on a Mac, Alt+F4 on a PC.
      shortcut: platformEditingConvention == EditingConvention.mac
          ? const KeyGesture(logicalKeyQ, command: true)
          : const KeyGesture(logicalKeyF4, alt: true),
      run: (_) {
        context.host.quit();
        return null;
      },
    ),
  ];
}
