/// View: zoom, grid, guides and snapping - and the tool box, as commands.
library;

import 'package:dart_ui/commands.dart';
import 'package:dart_ui/vector.dart';

import '../editor_model.dart';
import '../zoom.dart';
import 'command_context.dart';

/// The tool box: the key picks the tool, and the active one is checked.
const List<(String, String, ToolMode, int)> kToolCommands =
    <(String, String, ToolMode, int)>[
  ('tool.select', 'Pick', ToolMode.select, logicalKeyV),
  ('tool.shape', 'Shape (nodes)', ToolMode.shaper, logicalKeyF10),
  ('tool.zoom', 'Zoom', ToolMode.zoom, logicalKeyZ),
  ('tool.pan', 'Pan', ToolMode.fleur, logicalKeyH),
  ('tool.freehand', 'Freehand', ToolMode.freehand, logicalKeyF5),
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

List<CommandSpec> viewCommands(EditorContext context) {
  final EditorModel model = context.model;

  CommandSpec toggle(String id, String label, bool Function() get,
          void Function(bool) set, String on, String off,
          {KeyGesture? shortcut}) =>
      CommandSpec(
        id: id,
        label: label,
        shortcut: shortcut,
        checked: (_) => get(),
        run: (_) {
          set(!get());
          model.refresh(get() ? on : off);
          return get();
        },
      );

  return <CommandSpec>[
    CommandSpec(
      id: 'view.zoomIn',
      label: 'Zoom in',
      when: context.needsDocument,
      run: (_) => model.zoomBy(ZoomMetrics.step, context.host.viewport),
    ),
    CommandSpec(
      id: 'view.zoomOut',
      label: 'Zoom out',
      when: context.needsDocument,
      run: (_) => model.zoomBy(1 / ZoomMetrics.step, context.host.viewport),
    ),
    CommandSpec(
      id: 'view.zoom100',
      label: 'Zoom 100%',
      shortcut: const KeyGesture(logicalKeyF4, command: true),
      when: context.needsDocument,
      run: (_) => model.zoomAbout(1.0, context.host.viewport),
    ),
    CommandSpec(
      id: 'view.zoomTo',
      label: 'Zoom to',
      params: const <CommandParam>[
        CommandParam('zoom', CommandParamType.number,
            required: true, description: '1 is 100%'),
      ],
      when: context.needsDocument,
      run: (CommandArgs args) =>
          model.zoomAbout(args.number('zoom'), context.host.viewport),
    ),
    CommandSpec(
      id: 'view.zoomPage',
      label: 'Fit zoom to page',
      shortcut: const KeyGesture(logicalKeyF4, shift: true),
      when: context.needsDocument,
      run: (_) =>
          model.zoomToRect(model.active.page.rect, context.host.viewport),
    ),
    CommandSpec(
      id: 'view.zoomSelection',
      label: 'Zoom selected',
      shortcut: const KeyGesture(logicalKeyF4),
      when: context.needsSelection,
      run: (_) => model.zoomToRect(
          model.selection.selectionBounds, context.host.viewport),
    ),
    toggle('view.grid', 'Show grid', () => model.showGrid,
        (bool v) => model.showGrid = v, 'Grid shown', 'Grid hidden'),
    toggle('view.guides', 'Show guides', () => model.showGuides,
        (bool v) => model.showGuides = v, 'Guides shown', 'Guides hidden'),
    toggle(
      'view.snapGrid',
      'Snap to grid',
      () => model.snapToGrid,
      (bool v) {
        model.snapToGrid = v;
        if (model.hasDocument) model.active.snap.snapToGrid = v;
      },
      'Snapping on',
      'Snapping off',
      shortcut: const KeyGesture(logicalKeyG, alt: true),
    ),
    CommandSpec(
      id: 'tool.freehandSmoothing',
      label: 'Freehand smoothing',
      description: 'How far, 0 to 100, the Freehand tool may smooth a stroke.',
      params: const <CommandParam>[
        CommandParam('value', CommandParamType.number, required: true),
      ],
      run: (CommandArgs args) {
        model.freehandSmoothing = args.number('value').clamp(0, 100).toDouble();
        model.refresh('Freehand smoothing ${model.freehandSmoothing.round()}');
        return model.freehandSmoothing;
      },
    ),
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
}
