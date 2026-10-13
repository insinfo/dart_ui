/// Every document command of the editor, in one registry.
///
/// "Everything is a command": what a menu item, a toolbar button, a shortcut,
/// a context-menu row, a test or an automation client does to a drawing is
/// one of these, reached by id through [CommandRegistry.execute]. The window
/// adds its own (theme, panels) beside them; nothing here knows a widget.
///
/// Ids are dotted by area - `file.*`, `edit.*`, `object.*`, `selection.*`,
/// `shape.*`, `view.*`, `tool.*`, `layer.*`, `document.*`, `app.*`,
/// `help.*` - and the parameters each takes are declared, so an unknown or
/// mistyped one is refused before anything runs.
library;

import 'dart:io';

import 'package:dart_ui/dart_ui.dart';

import 'editor_files.dart';
import 'editor_host.dart';
import 'editor_model.dart';
import 'zoom.dart';

/// The tool box, as commands: the key picks the tool, and the active one is
/// the checked one.
const List<(String, String, ToolMode, int)> kToolCommands =
    <(String, String, ToolMode, int)>[
  ('tool.select', 'Pick', ToolMode.select, logicalKeyV),
  ('tool.zoom', 'Zoom', ToolMode.zoom, logicalKeyZ),
  ('tool.pan', 'Pan', ToolMode.fleur, logicalKeyH),
  ('tool.pen', 'Pen (Bezier)', ToolMode.curve, logicalKeyB),
  ('tool.rectangle', 'Rectangle', ToolMode.rectangle, logicalKeyF6),
  ('tool.ellipse', 'Ellipse', ToolMode.circle, logicalKeyF7),
  ('tool.polygon', 'Polygon', ToolMode.polygon, logicalKeyY),
  ('tool.text', 'Text', ToolMode.text, logicalKeyF8),
];

/// The command that picks [tool].
String toolCommandOf(ToolMode tool) => kToolCommands
    .firstWhere((t) => t.$3 == tool, orElse: () => kToolCommands.first)
    .$1;

/// Registers the editor's document commands on [registry], against [model],
/// with [host] for what needs a dialog or the window.
void registerEditorCommands(
  CommandRegistry registry,
  EditorModel model,
  EditorHost host,
) {
  registry.transaction = (String label, Object? Function() body) =>
      model.hasDocument ? model.active.api.history.group(label, body) : body();
  registry.registerAll(_EditorCommands(model, host).all);
}

const String _noDocument = 'no document is open';
const String _noSelection = 'nothing is selected';

bool get _mac => platformEditingConvention == EditingConvention.mac;

final class _EditorCommands {
  _EditorCommands(this.model, this.host);

  final EditorModel model;
  final EditorHost host;

  // --- predicates -----------------------------------------------------------

  bool _document(CommandArgs _) => model.hasDocument;
  String _documentReason(CommandArgs _) => _noDocument;

  bool _selected(CommandArgs _) => model.hasSelection;
  String _selectedReason(CommandArgs _) =>
      model.hasDocument ? _noSelection : _noDocument;

  int get _count => model.hasDocument ? model.selection.count : 0;

  /// A command that needs a document.
  CommandSpec _onDocument({
    required String id,
    required String label,
    required Object? Function(CommandArgs args) run,
    String description = '',
    IconData? icon,
    KeyGesture? shortcut,
    List<CommandParam> params = const <CommandParam>[],
  }) =>
      CommandSpec(
        id: id,
        label: label,
        description: description,
        icon: icon,
        shortcut: shortcut,
        params: params,
        enabled: _document,
        disabledReason: _documentReason,
        run: run,
      );

  /// A command that needs a selection.
  CommandSpec _onSelection({
    required String id,
    required String label,
    required Object? Function(CommandArgs args) run,
    String description = '',
    IconData? icon,
    KeyGesture? shortcut,
    List<KeyGesture> alsoShortcuts = const <KeyGesture>[],
    List<CommandParam> params = const <CommandParam>[],
  }) =>
      CommandSpec(
        id: id,
        label: label,
        description: description,
        icon: icon,
        shortcut: shortcut,
        alsoShortcuts: alsoShortcuts,
        params: params,
        enabled: _selected,
        disabledReason: _selectedReason,
        run: run,
      );

  static const CommandParam _path = CommandParam(
    'path',
    CommandParamType.string,
    description: 'a file to read or write without asking',
  );

  List<CommandSpec> get all => <CommandSpec>[
        ..._file,
        ..._edit,
        ..._object,
        ..._selection,
        ..._shapes,
        ..._view,
        ..._tools,
        ..._layers,
        ..._documents,
        CommandSpec(
          id: 'help.about',
          label: 'About this editor',
          run: (_) {
            model.refresh('Vector Editor - 100% pure Dart');
            return null;
          },
        ),
      ];

  // --- file -----------------------------------------------------------------

  List<CommandSpec> get _file => <CommandSpec>[
        CommandSpec(
          id: 'file.new',
          label: 'New',
          description: 'A new, empty drawing in a tab of its own.',
          icon: PhosphorIcons.filePlus,
          shortcut: const KeyGesture(logicalKeyN, command: true),
          run: (_) {
            model.newDocument();
            return <String, Object?>{'index': model.activeIndex};
          },
        ),
        CommandSpec(
          id: 'file.open',
          label: 'Open...',
          description: 'Opens an SVG or CorelDRAW drawing; asks which '
              'without a path.',
          icon: PhosphorIcons.folderOpen,
          shortcut: const KeyGesture(logicalKeyO, command: true),
          params: const <CommandParam>[_path],
          run: (CommandArgs args) {
            if (!args.has('path')) {
              host.pickAndOpen();
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
        _onDocument(
          id: 'file.save',
          label: 'Save',
          description: 'Writes the drawing over its SVG file, or asks where.',
          icon: PhosphorIcons.floppyDisk,
          shortcut: const KeyGesture(logicalKeyS, command: true),
          params: const <CommandParam>[_path],
          run: (CommandArgs args) {
            final String? existing = model.active.filePath;
            final String? path = args.has('path')
                ? args.string('path')
                : (existing != null && formatOf(existing) == 'svg'
                    ? existing
                    : null);
            if (path == null) {
              // A drawing opened from a CDR is saved as SVG under a new
              // name: writing over the original would lose what the CDR
              // writer cannot keep.
              host.pickAndSave('svg');
              return null;
            }
            return _write(path, 'svg');
          },
        ),
        _onDocument(
          id: 'file.saveAs',
          label: 'Save As...',
          shortcut: const KeyGesture(logicalKeyS, command: true, shift: true),
          params: const <CommandParam>[_path],
          run: (CommandArgs args) {
            if (!args.has('path')) {
              host.pickAndSave('svg');
              return null;
            }
            return _write(args.string('path'), 'svg');
          },
        ),
        _onDocument(
          id: 'file.export',
          label: 'Export...',
          description: 'Writes the drawing as SVG, PDF or CDR.',
          icon: PhosphorIcons.exportIcon,
          params: const <CommandParam>[
            CommandParam('format', CommandParamType.string,
                description: 'svg, pdf or cdr; the path\'s extension '
                    'by default'),
            _path,
          ],
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
              host.pickAndSave(format);
              return null;
            }
            return _write(path, format);
          },
        ),
        _onDocument(
          id: 'file.print',
          label: 'Print...',
          description: 'Writes a PDF to print from.',
          icon: PhosphorIcons.printer,
          shortcut: const KeyGesture(logicalKeyP, command: true),
          run: (_) {
            host.pickAndSave('pdf');
            return null;
          },
        ),
        _onDocument(
          id: 'file.close',
          label: 'Close',
          shortcut: const KeyGesture(logicalKeyW, command: true),
          params: const <CommandParam>[
            CommandParam('index', CommandParamType.integer,
                description: 'the tab; the active one by default'),
          ],
          run: (CommandArgs args) {
            host.closeDocument(args.integer('index', model.activeIndex));
            return null;
          },
        ),
        CommandSpec(
          id: 'app.quit',
          label: 'Exit',
          // Each platform's own: Cmd+Q on a Mac, Alt+F4 on a PC.
          shortcut: _mac
              ? const KeyGesture(logicalKeyQ, command: true)
              : const KeyGesture(logicalKeyF4, alt: true),
          run: (_) {
            host.quit();
            return null;
          },
        ),
      ];

  Map<String, Object?> _write(String path, String format) {
    writeDrawing(model.active, path, format);
    model.refresh('Wrote $path');
    return <String, Object?>{'path': path, 'format': format};
  }

  // --- edit -----------------------------------------------------------------

  List<CommandSpec> get _edit => <CommandSpec>[
        CommandSpec(
          id: 'edit.undo',
          label: 'Undo',
          currentLabel: (_) {
            final String? last =
                model.hasDocument ? model.active.api.undoDescription : null;
            return last == null ? 'Undo' : 'Undo $last';
          },
          icon: PhosphorIcons.arrowCounterClockwise,
          shortcut: const KeyGesture(logicalKeyZ, command: true),
          enabled: (_) => model.hasDocument && model.active.api.canUndo,
          disabledReason: (_) => 'there is nothing to undo',
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
          icon: PhosphorIcons.arrowClockwise,
          shortcut: const KeyGesture(logicalKeyZ, command: true, shift: true),
          enabled: (_) => model.hasDocument && model.active.api.canRedo,
          disabledReason: (_) => 'there is nothing to redo',
          run: (_) => model.redo(),
        ),
        _onSelection(
          id: 'edit.cut',
          label: 'Cut',
          icon: PhosphorIcons.scissors,
          shortcut: const KeyGesture(logicalKeyX, command: true),
          run: (_) => model.cutSelection(),
        ),
        _onSelection(
          id: 'edit.copy',
          label: 'Copy',
          icon: PhosphorIcons.copy,
          shortcut: const KeyGesture(logicalKeyC, command: true),
          run: (_) => model.copySelection(),
        ),
        CommandSpec(
          id: 'edit.paste',
          label: 'Paste',
          icon: PhosphorIcons.clipboardText,
          shortcut: const KeyGesture(logicalKeyV, command: true),
          enabled: (_) => model.canPaste,
          disabledReason: (_) => 'nothing has been copied',
          run: (_) => model.paste(),
        ),
        _onSelection(
          id: 'edit.delete',
          label: 'Delete',
          icon: PhosphorIcons.trash,
          // The Mac's "delete" key is Backspace; its forward delete works too.
          shortcut: _mac
              ? const KeyGesture(logicalKeyBackspace)
              : const KeyGesture(logicalKeyDelete),
          alsoShortcuts: _mac
              ? const <KeyGesture>[KeyGesture(logicalKeyDelete)]
              : const <KeyGesture>[],
          run: (_) => model.deleteSelection(),
        ),
        _onSelection(
          id: 'edit.duplicate',
          label: 'Duplicate',
          shortcut: const KeyGesture(logicalKeyD, command: true),
          run: (_) => model.duplicateSelection(),
        ),
        _onDocument(
          id: 'edit.selectAll',
          label: 'Select All',
          icon: PhosphorIcons.selectionAll,
          shortcut: const KeyGesture(logicalKeyA, command: true),
          run: (_) {
            model.selectAll();
            return <String, Object?>{'selected': model.selection.count};
          },
        ),
        _onSelection(
          id: 'edit.deselect',
          label: 'Deselect',
          shortcut: const KeyGesture(logicalKeyA, command: true, shift: true),
          run: (_) => model.deselect(),
        ),
      ];

  // --- object -----------------------------------------------------------------

  List<CommandSpec> get _object => <CommandSpec>[
        CommandSpec(
          id: 'object.group',
          label: 'Group',
          shortcut: const KeyGesture(logicalKeyG, command: true),
          enabled: (_) => _count >= 2,
          disabledReason: (_) => 'at least 2 objects must be selected; '
              '$_count ${_count == 1 ? 'is' : 'are'}',
          run: (_) => model.group(),
        ),
        CommandSpec(
          id: 'object.ungroup',
          label: 'Ungroup',
          shortcut: const KeyGesture(logicalKeyU, command: true),
          enabled: (_) => model.singleSelection is VectorGroup,
          disabledReason: (_) => 'select exactly one group to ungroup',
          run: (_) => model.ungroup(),
        ),
        CommandSpec(
          id: 'object.toCurves',
          label: 'Convert to curves',
          description: 'Replaces shapes and texts by curves with the same '
              'outline.',
          icon: PhosphorIcons.bezierCurve,
          // CorelDRAW's Ctrl+Q; on a Mac that chord is Quit.
          shortcut: _mac ? null : const KeyGesture(logicalKeyQ, command: true),
          enabled: (_) => model.hasDocument && model.canConvertToCurves,
          disabledReason: (_) => 'select a shape or a text',
          run: (_) => model.convertSelectionToCurves(),
        ),
        _onSelection(
          id: 'object.toFront',
          label: 'To Front',
          shortcut:
              const KeyGesture(logicalKeyPageUp, command: true, shift: true),
          run: (_) => model.reorder(up: true, toEnd: true),
        ),
        _onSelection(
          id: 'object.forward',
          label: 'Forward One',
          shortcut: const KeyGesture(logicalKeyPageUp, command: true),
          run: (_) => model.reorder(up: true, toEnd: false),
        ),
        _onSelection(
          id: 'object.backward',
          label: 'Back One',
          shortcut: const KeyGesture(logicalKeyPageDown, command: true),
          run: (_) => model.reorder(up: false, toEnd: false),
        ),
        _onSelection(
          id: 'object.toBack',
          label: 'To Back',
          shortcut:
              const KeyGesture(logicalKeyPageDown, command: true, shift: true),
          run: (_) => model.reorder(up: false, toEnd: true),
        ),
        _onSelection(
          id: 'object.rotate',
          label: 'Rotate',
          params: const <CommandParam>[
            CommandParam('degrees', CommandParamType.number,
                required: true,
                description: 'clockwise; negative turns the other way'),
          ],
          run: (CommandArgs args) =>
              model.rotateSelection(args.number('degrees')),
        ),
        _onSelection(
          id: 'object.flip',
          label: 'Flip',
          params: const <CommandParam>[
            CommandParam('direction', CommandParamType.string,
                required: true, description: 'horizontal or vertical'),
          ],
          run: (CommandArgs args) {
            final String direction = args.string('direction');
            if (direction != 'horizontal' && direction != 'vertical') {
              throw const CommandError('`direction` is horizontal or vertical');
            }
            model.flipSelection(horizontal: direction == 'horizontal');
            return null;
          },
        ),
        _onSelection(
          id: 'object.move',
          label: 'Move',
          description: 'Moves the selection by dx, dy document units.',
          params: const <CommandParam>[
            CommandParam('dx', CommandParamType.number),
            CommandParam('dy', CommandParamType.number),
          ],
          run: (CommandArgs args) =>
              model.moveSelectionBy(args.number('dx', 0), args.number('dy', 0)),
        ),
        _onSelection(
          id: 'object.nudge',
          label: 'Nudge',
          description: 'The arrow keys: one nudge, ten (big) or a tenth '
              '(small).',
          params: const <CommandParam>[
            CommandParam('dx', CommandParamType.integer),
            CommandParam('dy', CommandParamType.integer),
            CommandParam('step', CommandParamType.string,
                description: 'normal, big or small'),
          ],
          run: (CommandArgs args) {
            final String step = args.string('step', 'normal');
            model.nudge(
              args.integer('dx', 0),
              args.integer('dy', 0),
              big: step == 'big',
              small: step == 'small',
            );
            return null;
          },
        ),
        _onSelection(
          id: 'object.resize',
          label: 'Resize',
          params: const <CommandParam>[
            CommandParam('width', CommandParamType.number),
            CommandParam('height', CommandParamType.number),
          ],
          run: (CommandArgs args) => model.resizeSelectionTo(
            width: args.has('width') ? args.number('width') : null,
            height: args.has('height') ? args.number('height') : null,
          ),
        ),
        CommandSpec(
          id: 'object.fill',
          label: 'Fill colour',
          description: 'The selection\'s fill, or the next shapes\' when '
              'nothing is selected; null for none.',
          params: const <CommandParam>[
            CommandParam('color', CommandParamType.any,
                required: true, description: '"#rrggbb", "#aarrggbb" or null'),
          ],
          enabled: _document,
          disabledReason: _documentReason,
          run: (CommandArgs args) => model.setFill(_color(args['color'])),
        ),
        CommandSpec(
          id: 'object.outline',
          label: 'Outline colour',
          params: const <CommandParam>[
            CommandParam('color', CommandParamType.any,
                required: true, description: '"#rrggbb", "#aarrggbb" or null'),
          ],
          enabled: _document,
          disabledReason: _documentReason,
          run: (CommandArgs args) => model.setStroke(_color(args['color'])),
        ),
        _onSelection(
          id: 'object.align',
          label: 'Align',
          description: 'Aligns the selection with the Align panel\'s '
              'settings.',
          run: (_) => model.applyAlign(),
        ),
      ];

  static Color? _color(Object? value) {
    if (value == null) return null;
    if (value is! String) {
      throw const CommandError('`color` is "#rrggbb", "#aarrggbb" or null');
    }
    final String hex = value.startsWith('#') ? value.substring(1) : value;
    final int? parsed = int.tryParse(hex, radix: 16);
    if (parsed == null || (hex.length != 6 && hex.length != 8)) {
      throw CommandError('`color` "$value" is not #rrggbb or #aarrggbb');
    }
    return Color(hex.length == 6 ? 0xFF000000 | parsed : parsed);
  }

  // --- selection --------------------------------------------------------------

  List<SelectableObject> get _layerObjects =>
      model.active.layer.children.whereType<SelectableObject>().toList();

  List<CommandSpec> get _selection => <CommandSpec>[
        _onDocument(
          id: 'selection.select',
          label: 'Select object',
          description: 'Selects object [index] of the active layer, bottom '
              'first; with add, adds it.',
          params: const <CommandParam>[
            CommandParam('index', CommandParamType.integer, required: true),
            CommandParam('add', CommandParamType.boolean),
          ],
          run: (CommandArgs args) {
            final List<SelectableObject> objects = _layerObjects;
            final int index = args.integer('index');
            if (index < 0 || index >= objects.length) {
              throw CommandError('the active layer has ${objects.length} '
                  'objects; $index is not one');
            }
            model.pickObject(objects[index], toggle: args.flag('add'));
            return <String, Object?>{'selected': model.selection.count};
          },
        ),
        _onDocument(
          id: 'selection.at',
          label: 'Select at point',
          description: 'Selects the topmost object at x, y (document units), '
              'or clears the selection.',
          params: const <CommandParam>[
            CommandParam('x', CommandParamType.number, required: true),
            CommandParam('y', CommandParamType.number, required: true),
          ],
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
              'index': _layerObjects.indexOf(hit),
            };
          },
        ),
      ];

  // --- shapes -----------------------------------------------------------------

  static const List<CommandParam> _box = <CommandParam>[
    CommandParam('x', CommandParamType.number, required: true),
    CommandParam('y', CommandParamType.number, required: true),
    CommandParam('width', CommandParamType.number, required: true),
    CommandParam('height', CommandParamType.number, required: true),
  ];

  /// Adds [object] to the active layer as one undo step, wearing the
  /// current fill and outline, and selects it.
  Map<String, Object?> _create(SelectableObject object) {
    final DocumentSession session = model.active;
    final VectorLayer layer = session.layer;
    if (!layer.isEditable || !layer.isVisible) {
      throw CommandError('${layer.name} is locked or hidden');
    }
    session.api.methods.addObject(layer, object);
    model.objectCreated(object);
    session.selection.select(object);
    return <String, Object?>{'index': _layerObjects.indexOf(object)};
  }

  static void _positive(CommandArgs args) {
    if (args.number('width') <= 0 || args.number('height') <= 0) {
      throw const CommandError('`width` and `height` must be above zero');
    }
  }

  List<CommandSpec> get _shapes => <CommandSpec>[
        _onDocument(
          id: 'shape.rectangle',
          label: 'Rectangle',
          description: 'A rectangle at x, y (top-left), in document units.',
          params: _box,
          run: (CommandArgs args) {
            _positive(args);
            return _create(model.active.api.methods.createRectangle(
              x: args.number('x'),
              y: args.number('y'),
              width: args.number('width'),
              height: args.number('height'),
            ));
          },
        ),
        _onDocument(
          id: 'shape.ellipse',
          label: 'Ellipse',
          description: 'The ellipse inside the box at x, y.',
          params: _box,
          run: (CommandArgs args) {
            _positive(args);
            final double rx = args.number('width') / 2;
            final double ry = args.number('height') / 2;
            return _create(model.active.api.methods.createCircle(
              cx: args.number('x') + rx,
              cy: args.number('y') + ry,
              rx: rx,
              ry: ry,
            ));
          },
        ),
        _onDocument(
          id: 'shape.polygon',
          label: 'Polygon',
          description: 'A regular polygon centred at cx, cy.',
          params: const <CommandParam>[
            CommandParam('cx', CommandParamType.number, required: true),
            CommandParam('cy', CommandParamType.number, required: true),
            CommandParam('radius', CommandParamType.number, required: true),
            CommandParam('corners', CommandParamType.integer),
          ],
          run: (CommandArgs args) {
            final int corners = args.integer('corners', model.polygonCorners);
            if (corners < 3 || corners > 1000) {
              throw const CommandError('`corners` is from 3 to 1000');
            }
            return _create(model.active.api.methods.createPolygon(
              cx: args.number('cx'),
              cy: args.number('cy'),
              radius: args.number('radius'),
              cornersNum: corners,
            ));
          },
        ),
        _onDocument(
          id: 'shape.text',
          label: 'Text',
          description: 'Artistic text with its baseline starting at x, y.',
          params: const <CommandParam>[
            CommandParam('x', CommandParamType.number, required: true),
            CommandParam('y', CommandParamType.number, required: true),
            CommandParam('text', CommandParamType.string, required: true),
            CommandParam('size', CommandParamType.number,
                description: 'points; 18 by default'),
          ],
          run: (CommandArgs args) {
            final VectorText text = model.active.api.methods.createText(
              text: args.string('text'),
              x: args.number('x'),
              y: args.number('y'),
            );
            text.style = text.style.copyWith(
              textStyle: text.style.textStyle
                  .copyWith(fontSize: args.number('size', 18)),
            );
            text.update();
            return _create(text);
          },
        ),
      ];

  // --- view -------------------------------------------------------------------

  List<CommandSpec> get _view => <CommandSpec>[
        _onDocument(
          id: 'view.zoomIn',
          label: 'Zoom in',
          icon: PhosphorIcons.magnifyingGlassPlus,
          run: (_) => model.zoomBy(ZoomMetrics.step, host.viewport),
        ),
        _onDocument(
          id: 'view.zoomOut',
          label: 'Zoom out',
          icon: PhosphorIcons.magnifyingGlassMinus,
          run: (_) => model.zoomBy(1 / ZoomMetrics.step, host.viewport),
        ),
        _onDocument(
          id: 'view.zoom100',
          label: 'Zoom 100%',
          icon: PhosphorIcons.magnifyingGlass,
          shortcut: const KeyGesture(logicalKeyF4, command: true),
          run: (_) => model.zoomAbout(1.0, host.viewport),
        ),
        _onDocument(
          id: 'view.zoomTo',
          label: 'Zoom to',
          params: const <CommandParam>[
            CommandParam('zoom', CommandParamType.number,
                required: true, description: '1 is 100%'),
          ],
          run: (CommandArgs args) =>
              model.zoomAbout(args.number('zoom'), host.viewport),
        ),
        _onDocument(
          id: 'view.zoomPage',
          label: 'Fit zoom to page',
          icon: PhosphorIcons.frameCorners,
          shortcut: const KeyGesture(logicalKeyF4, shift: true),
          run: (_) => model.zoomToRect(model.active.page.rect, host.viewport),
        ),
        _onSelection(
          id: 'view.zoomSelection',
          label: 'Zoom selected',
          icon: PhosphorIcons.crosshair,
          shortcut: const KeyGesture(logicalKeyF4),
          run: (_) =>
              model.zoomToRect(model.selection.selectionBounds, host.viewport),
        ),
        CommandSpec(
          id: 'view.grid',
          label: 'Show grid',
          checked: (_) => model.showGrid,
          run: (_) {
            model.showGrid = !model.showGrid;
            model.refresh(model.showGrid ? 'Grid shown' : 'Grid hidden');
            return model.showGrid;
          },
        ),
        CommandSpec(
          id: 'view.guides',
          label: 'Show guides',
          checked: (_) => model.showGuides,
          run: (_) {
            model.showGuides = !model.showGuides;
            model.refresh(model.showGuides ? 'Guides shown' : 'Guides hidden');
            return model.showGuides;
          },
        ),
        CommandSpec(
          id: 'view.snapGrid',
          label: 'Snap to grid',
          shortcut: const KeyGesture(logicalKeyG, alt: true),
          checked: (_) => model.snapToGrid,
          run: (_) {
            model.snapToGrid = !model.snapToGrid;
            if (model.hasDocument) {
              model.active.snap.snapToGrid = model.snapToGrid;
            }
            model.refresh(model.snapToGrid ? 'Snapping on' : 'Snapping off');
            return model.snapToGrid;
          },
        ),
      ];

  // --- tools ------------------------------------------------------------------

  List<CommandSpec> get _tools => <CommandSpec>[
        for (final (String id, String label, ToolMode mode, int key)
            in kToolCommands)
          CommandSpec(
            id: id,
            label: label,
            shortcut: KeyGesture(key),
            checked: (_) => model.tool == mode,
            run: (_) {
              model.tool = mode;
              model.refresh('Tool: $label');
              return null;
            },
          ),
      ];

  // --- layers -----------------------------------------------------------------

  static const CommandParam _layerIndex = CommandParam(
    'index',
    CommandParamType.integer,
    description: 'the layer, bottom first; the active one by default',
  );

  VectorLayer _layer(CommandArgs args) {
    final List<VectorLayer> layers = model.active.layers;
    if (!args.has('index')) return model.active.layer;
    final int index = args.integer('index');
    if (index < 0 || index >= layers.length) {
      throw CommandError('the page has ${layers.length} layers; '
          '$index is not one');
    }
    return layers[index];
  }

  /// [args]' layer, or null when the index does not name one - for the
  /// state getters, which must not throw.
  VectorLayer? _layerOrNull(CommandArgs args) {
    try {
      return model.hasDocument ? _layer(args) : null;
    } on CommandError {
      return null;
    }
  }

  CommandSpec _onLayer({
    required String id,
    required String label,
    required Object? Function(VectorLayer layer, CommandArgs args) run,
    IconData? icon,
    bool Function(VectorLayer layer)? when,
    String? whyNot,
    bool Function(VectorLayer layer)? checked,
    List<CommandParam> extra = const <CommandParam>[],
  }) =>
      CommandSpec(
        id: id,
        label: label,
        icon: icon,
        params: <CommandParam>[_layerIndex, ...extra],
        enabled: (CommandArgs args) {
          final VectorLayer? layer = _layerOrNull(args);
          return layer != null && (when?.call(layer) ?? true);
        },
        disabledReason: (CommandArgs args) => !model.hasDocument
            ? _noDocument
            : _layerOrNull(args) == null
                ? 'no such layer'
                : (whyNot ?? 'not available'),
        checked: checked == null
            ? null
            : (CommandArgs args) {
                final VectorLayer? layer = _layerOrNull(args);
                return layer != null && checked(layer);
              },
        run: (CommandArgs args) => run(_layer(args), args),
      );

  List<CommandSpec> get _layers => <CommandSpec>[
        _onDocument(
          id: 'layer.new',
          label: 'New layer',
          icon: PhosphorIcons.plus,
          run: (_) {
            model.addLayer();
            return <String, Object?>{
              'index': model.active.layers.indexOf(model.active.layer),
            };
          },
        ),
        _onLayer(
          id: 'layer.activate',
          label: 'Make active layer',
          checked: (VectorLayer layer) => identical(layer, model.active.layer),
          run: (VectorLayer layer, _) => model.activateLayer(layer),
        ),
        _onLayer(
          id: 'layer.visible',
          label: 'Visible',
          checked: (VectorLayer layer) => layer.isVisible,
          extra: const <CommandParam>[
            CommandParam('visible', CommandParamType.boolean,
                description: 'toggles when left out'),
          ],
          run: (VectorLayer layer, CommandArgs args) {
            model.setLayerVisible(
                layer, args.flag('visible', !layer.isVisible));
            return layer.isVisible;
          },
        ),
        _onLayer(
          id: 'layer.lock',
          label: 'Locked',
          checked: (VectorLayer layer) => !layer.isEditable,
          extra: const <CommandParam>[
            CommandParam('locked', CommandParamType.boolean,
                description: 'toggles when left out'),
          ],
          run: (VectorLayer layer, CommandArgs args) {
            model.setLayerLocked(layer, args.flag('locked', layer.isEditable));
            return !layer.isEditable;
          },
        ),
        _onLayer(
          id: 'layer.raise',
          label: 'Raise layer',
          icon: PhosphorIcons.arrowUp,
          when: (VectorLayer layer) =>
              model.active.layers.indexOf(layer) <
              model.active.layers.length - 1,
          whyNot: 'already the top layer',
          run: (VectorLayer layer, _) => model.moveLayer(layer, up: true),
        ),
        _onLayer(
          id: 'layer.lower',
          label: 'Lower layer',
          icon: PhosphorIcons.arrowDown,
          when: (VectorLayer layer) => model.active.layers.indexOf(layer) > 0,
          whyNot: 'already the bottom layer',
          run: (VectorLayer layer, _) => model.moveLayer(layer, up: false),
        ),
        _onLayer(
          id: 'layer.rename',
          label: 'Rename layer',
          extra: const <CommandParam>[
            CommandParam('name', CommandParamType.string, required: true),
          ],
          run: (VectorLayer layer, CommandArgs args) =>
              model.renameLayer(layer, args.string('name')),
        ),
        _onLayer(
          id: 'layer.delete',
          label: 'Delete layer',
          icon: PhosphorIcons.trash,
          when: (_) => model.active.layers.length > 1,
          whyNot: 'the last layer cannot be deleted',
          run: (VectorLayer layer, _) => model.deleteLayer(layer),
        ),
      ];

  // --- documents --------------------------------------------------------------

  List<CommandSpec> get _documents => <CommandSpec>[
        CommandSpec(
          id: 'document.select',
          label: 'Switch to tab',
          params: const <CommandParam>[
            CommandParam('index', CommandParamType.integer, required: true),
          ],
          enabled: _document,
          disabledReason: _documentReason,
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
      ];
}
