/// The contextual property bar - sK1's `ctxpanel.py`.
///
/// The bar shows one row of *plugins*, chosen by the same decision sK1 makes:
/// no selection shows the page and unit plugins; a selection shows position,
/// size, rotation and mirroring; a single primitive adds a plugin for its own
/// type. The mapping lives in [contextPluginsFor] so the rule is one function
/// rather than a chain of `if`s spread through a build method.
library;

import 'package:dart_ui/dart_ui.dart';

import '../engine/editor_model.dart';
import 'command_icons.dart';
import 'metrics.dart';

/// The plugins a context bar can show, named after sK1's.
enum ContextPlugin {
  page,
  units,
  position,
  resize,
  rotate,
  mirror,
  order,
  rectangle,
  circle,
  polygon,
  polygonConfig,
  text,
  group,
  combine,
  nodes,
  freehand,
  zoom,
  line,
}

/// Which plugins belong on the bar right now.
///
/// Ported from `ctxpanel.py:get_mode()` plus the plugin sets in
/// `context/__init__.py`, minus the plugins this editor has no model for
/// (bitmaps, text markup, gradient editing).
List<ContextPlugin> contextPluginsFor(EditorModel model) {
  if (!model.hasDocument) return const <ContextPlugin>[];
  // The Zoom tool's bar is the zoom and nothing else, as in CorelDRAW.
  if (model.tool == ToolMode.zoom) {
    return const <ContextPlugin>[ContextPlugin.zoom];
  }

  // sK1 prepends the polygon config plugin whenever the canvas is in polygon
  // mode, whatever else is showing.
  // The tool's own settings come first, whatever else is showing: sK1
  // prepends the polygon config plugin in polygon mode, and CorelDRAW's
  // Shape tool and Freehand tool bars lead with their own buttons.
  final prefix = switch (model.tool) {
    ToolMode.polygon => <ContextPlugin>[ContextPlugin.polygonConfig],
    ToolMode.freehand => <ContextPlugin>[ContextPlugin.freehand],
    ToolMode.shaper when model.selection.syncNodeCurve() != null =>
      <ContextPlugin>[ContextPlugin.nodes],
    _ => const <ContextPlugin>[],
  };

  if (!model.hasSelection) {
    return <ContextPlugin>[
      ...prefix,
      ContextPlugin.page,
      ContextPlugin.units,
    ];
  }

  if (model.selection.count > 1) {
    return <ContextPlugin>[
      ...prefix,
      ContextPlugin.position,
      ContextPlugin.resize,
      ContextPlugin.combine,
      ContextPlugin.group,
      ContextPlugin.rotate,
      ContextPlugin.mirror,
    ];
  }

  final single = model.singleSelection;
  final typed = switch (single) {
    VectorRectangle() => ContextPlugin.rectangle,
    VectorCircle() => ContextPlugin.circle,
    VectorPolygon() => ContextPlugin.polygon,
    VectorText() => ContextPlugin.text,
    VectorGroup() => ContextPlugin.group,
    VectorCurve() => ContextPlugin.line,
    _ => null,
  };

  return <ContextPlugin>[
    ...prefix,
    ContextPlugin.position,
    ContextPlugin.resize,
    if (typed != null) typed,
    ContextPlugin.rotate,
    ContextPlugin.mirror,
    ContextPlugin.order,
  ];
}

/// The contextual property bar.
class ContextPanel extends StatelessWidget {
  const ContextPanel({super.key, required this.model, required this.registry});

  final EditorModel model;

  /// The buttons that are commands run through here, so their state and
  /// tooltips are the menus'.
  final CommandRegistry registry;

  @override
  Widget build(BuildContext context) {
    final plugins = contextPluginsFor(model);
    return Toolbar(
      height: ChromeMetrics.of(Theme.of(context)).contextPanelHeight,
      padding: const EdgeInsets.symmetric(
        horizontal: ChromeMetrics.barPadding,
        vertical: 2,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          if (plugins.isEmpty)
            const _Label('No document')
          else
            for (var index = 0; index < plugins.length; index++) ...<Widget>[
              if (index > 0) const ToolbarDivider(height: 16, margin: 5),
              _plugin(plugins[index]),
            ],
        ],
      ),
    );
  }

  Widget _plugin(ContextPlugin plugin) => switch (plugin) {
        ContextPlugin.page => _PagePlugin(model: model),
        ContextPlugin.units => _UnitsPlugin(model: model),
        ContextPlugin.position => _PositionPlugin(model: model),
        ContextPlugin.resize => _ResizePlugin(model: model),
        ContextPlugin.rotate => _RotatePlugin(registry: registry),
        ContextPlugin.mirror =>
          _commandButtons(const <(String, IconData, Map<String, Object?>)>[
            (
              'object.flip',
              PhosphorIcons.arrowsOutLineHorizontal,
              <String, Object?>{'direction': 'horizontal'}
            ),
            (
              'object.flip',
              PhosphorIcons.arrowsOutLineVertical,
              <String, Object?>{'direction': 'vertical'}
            ),
          ]),
        ContextPlugin.order =>
          _commandButtons(const <(String, IconData, Map<String, Object?>)>[
            ('object.toBack', PhosphorIcons.alignBottom, <String, Object?>{}),
            ('object.backward', PhosphorIcons.arrowDown, <String, Object?>{}),
            ('object.forward', PhosphorIcons.arrowUp, <String, Object?>{}),
            ('object.toFront', PhosphorIcons.alignTop, <String, Object?>{}),
          ]),
        ContextPlugin.rectangle =>
          _RectanglePlugin(model: model, registry: registry),
        ContextPlugin.circle => _CirclePlugin(registry: registry),
        ContextPlugin.polygon =>
          _PolygonPlugin(model: model, registry: registry),
        ContextPlugin.polygonConfig => _PolygonConfigPlugin(model: model),
        ContextPlugin.text => _TextPlugin(model: model, registry: registry),
        ContextPlugin.group => _commands(const <String>[
            'object.group',
            'object.ungroup',
          ]),
        ContextPlugin.combine => _commands(const <String>[
            'object.combine',
            'object.breakApart',
            'object.weld',
            'object.trim',
            'object.intersect',
          ]),
        ContextPlugin.nodes => _commands(const <String?>[
            'path.addNode',
            'path.deleteNodes',
            null,
            'path.joinNodes',
            'path.breakNode',
            null,
            'path.toLine',
            'path.toCurve',
            null,
            'path.cusp',
            'path.smooth',
            'path.symmetrical',
            null,
            'path.reverse',
            'path.close',
            'path.selectAllNodes',
          ]),
        ContextPlugin.freehand =>
          _FreehandPlugin(model: model, registry: registry),
        ContextPlugin.zoom => _ZoomPlugin(model: model, registry: registry),
        ContextPlugin.line => _LinePlugin(model: model, registry: registry),
      };

  /// A row of command buttons with their own icons and parameters.
  Widget _commandButtons(List<(String, IconData, Map<String, Object?>)> rows) =>
      Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          for (final (String id, IconData icon, Map<String, Object?> params)
              in rows)
            CommandIconButton(
                registry: registry, command: id, icon: icon, params: params),
        ],
      );

  /// A row of command buttons; null is a gap between groups.
  Widget _commands(List<String?> ids) => Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          for (final String? id in ids)
            if (id == null)
              const SizedBox(width: 6)
            else
              CommandIconButton(
                registry: registry,
                command: id,
                icon: commandIcon(id) ?? PhosphorIcons.question,
              ),
        ],
      );
}

// ---------------------------------------------------------------------------
// Shared small parts
// ---------------------------------------------------------------------------

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
      child: Text(
        text,
        style: theme.textTheme.labelSmall,
        color: theme.foregroundSecondary,
      ),
    );
  }
}

/// A number field of a fixed width, so the bar does not resize as digits come
/// and go - which would make every neighbouring control move under the pointer.
class _Field extends StatelessWidget {
  const _Field({
    required this.value,
    required this.onChanged,
    this.width = 62,
    this.decimals = 1,
    this.min = double.negativeInfinity,
    this.max = double.infinity,
  });

  final double value;
  final void Function(double value) onChanged;
  final double width;
  final int decimals;
  final double min;
  final double max;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: ChromeMetrics.of(Theme.of(context)).widthFor(width),
        height: ChromeMetrics.of(Theme.of(context)).fieldHeight,
        child: NumberBox(
          value: value,
          decimals: decimals,
          min: min,
          max: max,
          onChanged: onChanged,
        ),
      );
}

class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.selected = false,
  });

  final IconData icon;
  final String tooltip;
  final void Function()? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) => IconButton(
        icon: Icon(icon),
        iconSize: 14,
        isSelected: selected,
        padding: const EdgeInsets.all(4),
        constraints: BoxConstraints(minWidth: 22, minHeight: 22),
        tooltip: tooltip,
        onPressed: onTap,
      );
}

// ---------------------------------------------------------------------------
// Plugins
// ---------------------------------------------------------------------------

/// Page format, size and orientation - sK1's PagePlugin.
class _PagePlugin extends StatelessWidget {
  const _PagePlugin({required this.model});

  final EditorModel model;

  static const String _custom = 'Custom';

  /// Typing a size makes the page a custom one, in the orientation it shows.
  void _setSize({required double width, required double height}) {
    if (width <= 0 || height <= 0) return;
    final page = model.active.page;
    model.edit(
        'Page size',
        () => page.pageFormat = PageFormat(
              size: PageSize(_custom, width, height),
            ));
  }

  @override
  Widget build(BuildContext context) {
    final page = model.active.page;
    final format = page.pageFormat;
    final unit = model.units;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        SizedBox(
          width: ChromeMetrics.of(Theme.of(context)).widthFor(92),
          height: ChromeMetrics.of(Theme.of(context)).fieldHeight,
          child: ComboBox<String>(
            label: 'Page format',
            value: format.name,
            items: <ComboBoxItem<String>>[
              const ComboBoxItem<String>(value: _custom, label: _custom),
              for (final size in PageFormats.all)
                ComboBoxItem<String>(value: size.name, label: size.name),
            ],
            onChanged: (String name) {
              final size = name == _custom
                  ? PageSize(_custom, format.size.width, format.size.height)
                  : PageFormats.byName(name);
              if (size == null) return;
              model.edit('Page format $name',
                  () => page.pageFormat = format.copyWith(size: size));
            },
          ),
        ),
        const SizedBox(width: 4),
        _Field(
          value: fromPoints(format.width, unit),
          decimals: 1,
          min: 1,
          onChanged: (value) => _setSize(
            width: toPoints(value, unit),
            height: format.height,
          ),
        ),
        const _Label('x'),
        _Field(
          value: fromPoints(format.height, unit),
          decimals: 1,
          min: 1,
          onChanged: (value) => _setSize(
            width: format.width,
            height: toPoints(value, unit),
          ),
        ),
        const SizedBox(width: 4),
        _BarButton(
          icon: PhosphorIcons.rows,
          tooltip: 'Portrait',
          selected: format.orientation == PageOrientation.portrait,
          onTap: () => model.edit(
              'Portrait',
              () => page.pageFormat =
                  format.copyWith(orientation: PageOrientation.portrait)),
        ),
        _BarButton(
          icon: PhosphorIcons.columns,
          tooltip: 'Landscape',
          selected: format.orientation == PageOrientation.landscape,
          onTap: () => model.edit(
              'Landscape',
              () => page.pageFormat =
                  format.copyWith(orientation: PageOrientation.landscape)),
        ),
      ],
    );
  }
}

/// Document units - sK1's UnitsPlugin.
class _UnitsPlugin extends StatelessWidget {
  const _UnitsPlugin({required this.model});

  final EditorModel model;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          const Icon(PhosphorIcons.ruler),
          const SizedBox(width: 4),
          SizedBox(
            width: ChromeMetrics.of(Theme.of(context)).widthFor(74),
            height: ChromeMetrics.of(Theme.of(context)).fieldHeight,
            child: ComboBox<DocUnit>(
              label: 'Document units',
              value: model.units,
              items: <ComboBoxItem<DocUnit>>[
                for (final unit in DocUnit.values)
                  ComboBoxItem<DocUnit>(value: unit, label: unit.label),
              ],
              onChanged: (DocUnit unit) {
                model.units = unit;
                model.refresh('Units: ${unit.label}');
              },
            ),
          ),
        ],
      );
}

/// Selection position - sK1's PositionPlugin.
class _PositionPlugin extends StatelessWidget {
  const _PositionPlugin({required this.model});

  final EditorModel model;

  @override
  Widget build(BuildContext context) {
    final bounds = model.selection.selectionBounds;
    final unit = model.units;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        const _Label('x:'),
        _Field(
          value: fromPoints(bounds.left, unit),
          onChanged: (value) => model.moveSelectionBy(
            toPoints(value, unit) - bounds.left,
            0,
          ),
        ),
        const _Label('y:'),
        _Field(
          value: fromPoints(bounds.top, unit),
          onChanged: (value) => model.moveSelectionBy(
            0,
            toPoints(value, unit) - bounds.top,
          ),
        ),
      ],
    );
  }
}

/// Selection size - sK1's ResizePlugin.
class _ResizePlugin extends StatelessWidget {
  const _ResizePlugin({required this.model});

  final EditorModel model;

  @override
  Widget build(BuildContext context) {
    final bounds = model.selection.selectionBounds;
    final unit = model.units;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        const Icon(PhosphorIcons.arrowsOut),
        const SizedBox(width: 4),
        _Field(
          value: fromPoints(bounds.width, unit),
          min: 0.01,
          onChanged: (value) =>
              model.resizeSelectionTo(width: toPoints(value, unit)),
        ),
        const _Label('x'),
        _Field(
          value: fromPoints(bounds.height, unit),
          min: 0.01,
          onChanged: (value) =>
              model.resizeSelectionTo(height: toPoints(value, unit)),
        ),
      ],
    );
  }
}

/// Rotation - sK1's RotatePlugin.
class _RotatePlugin extends StatelessWidget {
  const _RotatePlugin({required this.registry});

  final CommandRegistry registry;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          const Icon(PhosphorIcons.arrowClockwise),
          const SizedBox(width: 4),
          // Applies the angle as a *delta* and returns to zero, because the
          // model stores a matrix rather than an angle: showing a running total
          // would mean inventing one the document does not have.
          _Field(
            value: 0,
            width: 56,
            min: -360,
            max: 360,
            onChanged: (double degrees) => registry.execute(
                'object.rotate', <String, Object?>{'degrees': degrees}),
          ),
          const _Label('deg'),
          CommandIconButton(
            registry: registry,
            command: 'object.rotate',
            icon: PhosphorIcons.arrowCounterClockwise,
            label: 'Rotate left 90 degrees',
            params: const <String, Object?>{'degrees': -90},
          ),
          CommandIconButton(
            registry: registry,
            command: 'object.rotate',
            icon: PhosphorIcons.arrowClockwise,
            label: 'Rotate right 90 degrees',
            params: const <String, Object?>{'degrees': 90},
          ),
        ],
      );
}

/// Corner rounding - sK1's RectanglePlugin.
class _RectanglePlugin extends StatelessWidget {
  const _RectanglePlugin({required this.model, required this.registry});

  final EditorModel model;
  final CommandRegistry registry;

  @override
  Widget build(BuildContext context) {
    final rectangle = model.singleSelection as VectorRectangle;
    final rounded = rectangle.corners.isEmpty ? 0.0 : rectangle.corners.first;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        const _Label('Round:'),
        _Field(
          value: rounded * 100,
          width: 56,
          decimals: 0,
          min: 0,
          max: 100,
          onChanged: (value) => registry
              .execute('rectangle.round', <String, Object?>{'percent': value}),
        ),
        const _Label('%'),
      ],
    );
  }
}

/// Arc / chord / pie - sK1's CirclePlugin.
class _CirclePlugin extends StatelessWidget {
  const _CirclePlugin({required this.registry});

  final CommandRegistry registry;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          for (final (ArcType type, IconData icon, String label)
              in const <(ArcType, IconData, String)>[
            (ArcType.arc, PhosphorIcons.circleNotch, 'Arc'),
            (ArcType.chord, PhosphorIcons.circleHalf, 'Chord'),
            (ArcType.pieslice, PhosphorIcons.circleHalfTilt, 'Pie slice'),
          ])
            CommandIconButton(
              registry: registry,
              command: 'ellipse.type',
              icon: icon,
              label: label,
              params: <String, Object?>{'type': type.name},
            ),
        ],
      );
}

/// Corner count of the selected polygon - sK1's PolygonPlugin.
class _PolygonPlugin extends StatelessWidget {
  const _PolygonPlugin({required this.model, required this.registry});

  final EditorModel model;
  final CommandRegistry registry;

  @override
  Widget build(BuildContext context) {
    final polygon = model.singleSelection as VectorPolygon;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        const Icon(PhosphorIcons.polygon),
        const SizedBox(width: 4),
        _Field(
          value: polygon.cornersNum.toDouble(),
          width: 52,
          decimals: 0,
          min: 3,
          max: 1000,
          onChanged: (value) => registry.execute('polygon.corners',
              <String, Object?>{'corners': value.round().clamp(3, 1000)}),
        ),
      ],
    );
  }
}

/// Corners for the *next* polygon - sK1's PolygonCfgPlugin.
class _PolygonConfigPlugin extends StatelessWidget {
  const _PolygonConfigPlugin({required this.model});

  final EditorModel model;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          const _Label('New polygon:'),
          _Field(
            value: model.polygonCorners.toDouble(),
            width: 52,
            decimals: 0,
            min: 3,
            max: 1000,
            onChanged: (value) {
              model.polygonCorners = value.round().clamp(3, 1000);
              model.refresh('New polygons: ${model.polygonCorners} corners');
            },
          ),
        ],
      );
}

/// Text content and size - a reduced sK1 TextStylePlugin.
///
/// Stateful only because the field needs a controller that outlives one build;
/// rebuilding it per frame would move the caret to the end on every keystroke.
class _TextPlugin extends StatefulWidget {
  const _TextPlugin({required this.model, required this.registry});

  final EditorModel model;
  final CommandRegistry registry;

  @override
  State<_TextPlugin> createState() => _TextPluginState();
}

class _TextPluginState extends State<_TextPlugin> {
  late final TextEditingController _controller =
      TextEditingController(_object?.textContent ?? '')..addListener(_push);

  /// The selected text, or null for the one build this plugin can get after
  /// the selection changed and before the bar swaps it for another plugin.
  VectorText? get _object => switch (widget.model.singleSelection) {
        final VectorText text => text,
        _ => null,
      };

  /// The object the controller was seeded from, so a different selection
  /// reseeds rather than renaming the previous one.
  VectorText? _seeded;

  void _push(String _) {
    final object = widget.model.singleSelection;
    if (object is! VectorText) return;
    if (object.textContent == _controller.value) return;
    widget.registry
        .execute('text.content', <String, Object?>{'text': _controller.value});
  }

  @override
  void dispose() {
    _controller.removeListener(_push);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = _object;
    if (text == null) return const SizedBox();
    if (!identical(_seeded, text)) {
      _seeded = text;
      if (_controller.value != text.textContent) {
        _controller.value = text.textContent;
      }
    }
    final style = text.style.textStyle;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        SizedBox(
          width: ChromeMetrics.of(Theme.of(context)).widthFor(150),
          height: ChromeMetrics.of(Theme.of(context)).fieldHeight,
          child: TextField(controller: _controller, label: 'Text content'),
        ),
        const SizedBox(width: 4),
        _Field(
          value: style.fontSize,
          width: 50,
          decimals: 0,
          min: 4,
          max: 400,
          onChanged: (value) => widget.registry
              .execute('text.size', <String, Object?>{'size': value}),
        ),
        const _Label('pt'),
      ],
    );
  }
}

/// Freehand smoothing for the next stroke - CorelDRAW's Freehand bar.
class _FreehandPlugin extends StatelessWidget {
  const _FreehandPlugin({required this.model, required this.registry});

  final EditorModel model;
  final CommandRegistry registry;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          const _Label('Smoothing:'),
          _Field(
            value: model.freehandSmoothing,
            width: 52,
            decimals: 0,
            min: 0,
            max: 100,
            onChanged: (double v) => registry.execute(
                'tool.freehandSmoothing', <String, Object?>{'value': v}),
          ),
        ],
      );
}

// ---------------------------------------------------------------------------
// Zoom
// ---------------------------------------------------------------------------

/// The Zoom tool's bar: the levels, then in, out and the fits.
class _ZoomPlugin extends StatelessWidget {
  const _ZoomPlugin({required this.model, required this.registry});

  final EditorModel model;
  final CommandRegistry registry;

  static const List<double> levels = <double>[
    .1, .25, .5, .75, 1, 2, 4, 8, //
  ];

  @override
  Widget build(BuildContext context) {
    final ChromeMetrics metrics = ChromeMetrics.of(Theme.of(context));
    final double zoom = model.active.zoom;
    final int percent = (zoom * 100).round();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        SizedBox(
          width: metrics.widthFor(84),
          height: metrics.fieldHeight,
          child: ComboBox<double>(
            label: 'Zoom levels',
            // The current zoom as a level of its own when it is none of
            // the presets - the box shows what the view is, not a preset
            // it is near.
            value: zoom,
            items: <ComboBoxItem<double>>[
              if (!levels.any((double l) => (l * 100).round() == percent))
                ComboBoxItem<double>(value: zoom, label: '$percent%'),
              for (final double level in levels)
                ComboBoxItem<double>(
                    value: (level * 100).round() == percent ? zoom : level,
                    label: '${(level * 100).round()}%'),
            ],
            onChanged: (double level) {
              if (level != zoom) {
                registry
                    .execute('view.zoomTo', <String, Object?>{'zoom': level});
              }
            },
          ),
        ),
        const SizedBox(width: 6),
        for (final String id in const <String>[
          'view.zoomIn',
          'view.zoomOut',
          'view.zoomSelection',
          'view.zoomPage',
          'view.zoomPageWidth',
          'view.zoomPageHeight',
        ])
          CommandIconButton(
            registry: registry,
            command: id,
            icon: commandIcon(id) ?? PhosphorIcons.magnifyingGlass,
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Line: arrowheads and line style
// ---------------------------------------------------------------------------

/// A curve's bar, CorelDRAW's: the start arrowhead, the line style, the end
/// arrowhead.
class _LinePlugin extends StatelessWidget {
  const _LinePlugin({required this.model, required this.registry});

  final EditorModel model;
  final CommandRegistry registry;

  /// Dashes in widths of the line, so a heavier line gets longer dashes.
  static const Map<String, List<double>> styles = <String, List<double>>{
    'Solid': <double>[],
    'Dash': <double>[4, 2],
    'Dot': <double>[1, 2],
    'Dash dot': <double>[4, 2, 1, 2],
  };

  @override
  Widget build(BuildContext context) {
    final ChromeMetrics metrics = ChromeMetrics.of(Theme.of(context));
    // The selection can change between choosing the plugins and building
    // them - a tool finishing a curve mid-frame.
    final SelectableObject? single = model.singleSelection;
    if (single == null) return const SizedBox();
    final StrokeDescriptor stroke = single.style.stroke;
    final double width = stroke.width <= 0 ? 1 : stroke.width;
    String styleOf(List<double> dashes) {
      for (final MapEntry<String, List<double>> e in styles.entries) {
        if (e.value.length == dashes.length &&
            <bool>[
              for (var i = 0; i < dashes.length; i++)
                (e.value[i] * width - dashes[i]).abs() < 1e-6,
            ].every((bool b) => b)) {
          return e.key;
        }
      }
      return 'Custom';
    }

    final String current = styleOf(stroke.dashPattern);
    Widget arrows(String end, ArrowHead value) => SizedBox(
          width: metrics.widthFor(84),
          height: metrics.fieldHeight,
          child: ComboBox<ArrowHead>(
            label: end == 'start' ? 'Start arrowhead' : 'End arrowhead',
            value: value,
            items: <ComboBoxItem<ArrowHead>>[
              for (final ArrowHead head in ArrowHead.values)
                ComboBoxItem<ArrowHead>(value: head, label: head.label),
            ],
            onChanged: (ArrowHead head) => registry
                .execute('object.arrows', <String, Object?>{end: head.name}),
          ),
        );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        arrows('start', ArrowHead.of(stroke.startArrow)),
        const SizedBox(width: 4),
        SizedBox(
          width: metrics.widthFor(84),
          height: metrics.fieldHeight,
          child: ComboBox<String>(
            label: 'Line style',
            value: current,
            items: <ComboBoxItem<String>>[
              if (current == 'Custom')
                const ComboBoxItem<String>(value: 'Custom', label: 'Custom'),
              for (final String name in styles.keys)
                ComboBoxItem<String>(value: name, label: name),
            ],
            onChanged: (String name) {
              final List<double>? pattern = styles[name];
              if (pattern == null) return;
              registry.execute('object.outlineStyle', <String, Object?>{
                'dash': <double>[for (final double d in pattern) d * width],
              });
            },
          ),
        ),
        const SizedBox(width: 4),
        arrows('end', ArrowHead.of(stroke.endArrow)),
      ],
    );
  }
}
