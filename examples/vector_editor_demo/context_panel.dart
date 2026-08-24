/// The contextual property bar - sK1's `ctxpanel.py`.
///
/// The bar shows one row of *plugins*, chosen by the same decision sK1 makes:
/// no selection shows the page and unit plugins; a selection shows position,
/// size, rotation and mirroring; a single primitive adds a plugin for its own
/// type. The mapping lives in [contextPluginsFor] so the rule is one function
/// rather than a chain of `if`s spread through a build method.
library;

import 'package:dart_ui/dart_ui.dart';

import 'editor_model.dart';
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
}

/// Which plugins belong on the bar right now.
///
/// Ported from `ctxpanel.py:get_mode()` plus the plugin sets in
/// `context/__init__.py`, minus the plugins this editor has no model for
/// (bitmaps, text markup, gradient editing).
List<ContextPlugin> contextPluginsFor(EditorModel model) {
  if (!model.hasDocument) return const <ContextPlugin>[];

  // sK1 prepends the polygon config plugin whenever the canvas is in polygon
  // mode, whatever else is showing.
  final prefix = model.tool == ToolMode.polygon
      ? <ContextPlugin>[ContextPlugin.polygonConfig]
      : const <ContextPlugin>[];

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
  const ContextPanel({super.key, required this.model});

  final EditorModel model;

  @override
  Widget build(BuildContext context) {
    final plugins = contextPluginsFor(model);
    return Toolbar(
      height: ChromeMetrics.contextPanelHeight,
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
        ContextPlugin.rotate => _RotatePlugin(model: model),
        ContextPlugin.mirror => _MirrorPlugin(model: model),
        ContextPlugin.order => _OrderPlugin(model: model),
        ContextPlugin.rectangle => _RectanglePlugin(model: model),
        ContextPlugin.circle => _CirclePlugin(model: model),
        ContextPlugin.polygon => _PolygonPlugin(model: model),
        ContextPlugin.polygonConfig => _PolygonConfigPlugin(model: model),
        ContextPlugin.text => _TextPlugin(model: model),
        ContextPlugin.group => _GroupPlugin(model: model),
        ContextPlugin.combine => _CombinePlugin(model: model),
      };
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
        width: width,
        height: 22,
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

  @override
  Widget build(BuildContext context) {
    final page = model.active.page;
    final format = page.pageFormat;
    final unit = model.units;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        SizedBox(
          width: 92,
          height: 22,
          child: ComboBox<String>(
            label: 'Page format',
            value: format.name,
            items: <ComboBoxItem<String>>[
              const ComboBoxItem<String>(value: _custom, label: _custom),
              for (final size in PageFormats.all)
                ComboBoxItem<String>(value: size.name, label: size.name),
            ],
            onChanged: (String name) {
              final size = PageFormats.byName(name);
              if (size == null) return;
              page.pageFormat = format.copyWith(size: size);
              model.touch('Page format $name');
            },
          ),
        ),
        const SizedBox(width: 4),
        _Field(
          value: fromPoints(format.width, unit),
          decimals: 1,
          min: 1,
          onChanged: (_) => model.refresh(
            'Page size follows the chosen format; pick Custom to type one',
          ),
        ),
        const _Label('x'),
        _Field(
          value: fromPoints(format.height, unit),
          decimals: 1,
          min: 1,
          onChanged: (_) => model.refresh(
            'Page size follows the chosen format; pick Custom to type one',
          ),
        ),
        const SizedBox(width: 4),
        _BarButton(
          icon: PhosphorIcons.rows,
          tooltip: 'Portrait',
          selected: format.orientation == PageOrientation.portrait,
          onTap: () {
            page.pageFormat =
                format.copyWith(orientation: PageOrientation.portrait);
            model.touch('Portrait');
          },
        ),
        _BarButton(
          icon: PhosphorIcons.columns,
          tooltip: 'Landscape',
          selected: format.orientation == PageOrientation.landscape,
          onTap: () {
            page.pageFormat =
                format.copyWith(orientation: PageOrientation.landscape);
            model.touch('Landscape');
          },
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
          const Icon(PhosphorIcons.ruler, size: 14),
          const SizedBox(width: 4),
          SizedBox(
            width: 74,
            height: 22,
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
        const Icon(PhosphorIcons.arrowsOut, size: 14),
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
  const _RotatePlugin({required this.model});

  final EditorModel model;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          const Icon(PhosphorIcons.arrowClockwise, size: 14),
          const SizedBox(width: 4),
          // Applies the angle as a *delta* and returns to zero, because the
          // model stores a matrix rather than an angle: showing a running total
          // would mean inventing one the document does not have.
          _Field(
            value: 0,
            width: 56,
            min: -360,
            max: 360,
            onChanged: model.rotateSelection,
          ),
          const _Label('deg'),
          _BarButton(
            icon: PhosphorIcons.arrowCounterClockwise,
            tooltip: 'Rotate left 90 degrees',
            onTap: () => model.rotateSelection(-90),
          ),
          _BarButton(
            icon: PhosphorIcons.arrowClockwise,
            tooltip: 'Rotate right 90 degrees',
            onTap: () => model.rotateSelection(90),
          ),
        ],
      );
}

/// Mirroring - sK1's MirrorPlugin.
class _MirrorPlugin extends StatelessWidget {
  const _MirrorPlugin({required this.model});

  final EditorModel model;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          _BarButton(
            icon: PhosphorIcons.arrowsOutLineHorizontal,
            tooltip: 'Flip horizontal',
            onTap: () => model.flipSelection(horizontal: true),
          ),
          _BarButton(
            icon: PhosphorIcons.arrowsOutLineVertical,
            tooltip: 'Flip vertical',
            onTap: () => model.flipSelection(horizontal: false),
          ),
        ],
      );
}

/// Z order - sK1's OrderPlugin, in its bottom-to-top button order.
class _OrderPlugin extends StatelessWidget {
  const _OrderPlugin({required this.model});

  final EditorModel model;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          _BarButton(
            icon: PhosphorIcons.alignBottom,
            tooltip: 'Move to Bottom',
            onTap: () => model.reorder(up: false, toEnd: true),
          ),
          _BarButton(
            icon: PhosphorIcons.arrowDown,
            tooltip: 'Move Down',
            onTap: () => model.reorder(up: false, toEnd: false),
          ),
          _BarButton(
            icon: PhosphorIcons.arrowUp,
            tooltip: 'Move Up',
            onTap: () => model.reorder(up: true, toEnd: false),
          ),
          _BarButton(
            icon: PhosphorIcons.alignTop,
            tooltip: 'Move to Top',
            onTap: () => model.reorder(up: true, toEnd: true),
          ),
        ],
      );
}

/// Corner rounding - sK1's RectanglePlugin.
class _RectanglePlugin extends StatelessWidget {
  const _RectanglePlugin({required this.model});

  final EditorModel model;

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
          onChanged: (value) {
            final corner = (value / 100).clamp(0.0, 1.0);
            rectangle.corners = <double>[corner, corner, corner, corner];
            rectangle.update();
            model.touch('Corner radius ${value.round()}%');
          },
        ),
        const _Label('%'),
      ],
    );
  }
}

/// Arc / chord / pie - sK1's CirclePlugin.
class _CirclePlugin extends StatelessWidget {
  const _CirclePlugin({required this.model});

  final EditorModel model;

  @override
  Widget build(BuildContext context) {
    final circle = model.singleSelection as VectorCircle;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        for (final type in ArcType.values)
          _BarButton(
            icon: switch (type) {
              ArcType.arc => PhosphorIcons.circleNotch,
              ArcType.chord => PhosphorIcons.circleHalf,
              ArcType.pieslice => PhosphorIcons.circleHalfTilt,
            },
            tooltip: switch (type) {
              ArcType.arc => 'Arc',
              ArcType.chord => 'Chord',
              ArcType.pieslice => 'Pie slice',
            },
            selected: circle.arcType == type,
            onTap: () {
              circle.arcType = type;
              circle.update();
              model.touch('Ellipse: ${type.name}');
            },
          ),
      ],
    );
  }
}

/// Corner count of the selected polygon - sK1's PolygonPlugin.
class _PolygonPlugin extends StatelessWidget {
  const _PolygonPlugin({required this.model});

  final EditorModel model;

  @override
  Widget build(BuildContext context) {
    final polygon = model.singleSelection as VectorPolygon;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        const Icon(PhosphorIcons.polygon, size: 14),
        const SizedBox(width: 4),
        _Field(
          value: polygon.cornersNum.toDouble(),
          width: 52,
          decimals: 0,
          min: 3,
          max: 1000,
          onChanged: (value) {
            polygon.cornersNum = value.round().clamp(3, 1000);
            polygon.update();
            model.touch('${polygon.cornersNum} corners');
          },
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
  const _TextPlugin({required this.model});

  final EditorModel model;

  @override
  State<_TextPlugin> createState() => _TextPluginState();
}

class _TextPluginState extends State<_TextPlugin> {
  late final TextEditingController _controller =
      TextEditingController(_object.textContent)..addListener(_push);

  VectorText get _object => widget.model.singleSelection! as VectorText;

  /// The object the controller was seeded from, so a different selection
  /// reseeds rather than renaming the previous one.
  VectorText? _seeded;

  void _push(String _) {
    final object = widget.model.singleSelection;
    if (object is! VectorText) return;
    if (object.textContent == _controller.value) return;
    object.textContent = _controller.value;
    object.update();
    widget.model.touch('Text changed');
  }

  @override
  void dispose() {
    _controller.removeListener(_push);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = _object;
    if (!identical(_seeded, text)) {
      _seeded = text;
      if (_controller.value != text.textContent) {
        _controller.value = text.textContent;
      }
    }
    final style = text.style.textStyle;
    final model = widget.model;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        SizedBox(
          width: 150,
          height: 22,
          child: TextField(controller: _controller, label: 'Text content'),
        ),
        const SizedBox(width: 4),
        _Field(
          value: style.fontSize,
          width: 50,
          decimals: 0,
          min: 4,
          max: 400,
          onChanged: (value) {
            model.active.api.setObjectStyle(
              text,
              text.style.copyWith(
                textStyle: style.copyWith(fontSize: value),
              ),
            );
            model.touch('Font size ${value.round()}');
          },
        ),
        const _Label('pt'),
      ],
    );
  }
}

/// Group / ungroup - sK1's GroupPlugin.
class _GroupPlugin extends StatelessWidget {
  const _GroupPlugin({required this.model});

  final EditorModel model;

  @override
  Widget build(BuildContext context) {
    final canGroup = model.selection.count >= 2;
    final canUngroup = model.singleSelection is VectorGroup;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        _BarButton(
          icon: PhosphorIcons.stack,
          tooltip: canGroup ? 'Group (Ctrl+G)' : 'Group - select two objects',
          onTap: canGroup ? model.group : null,
        ),
        _BarButton(
          icon: PhosphorIcons.circlesThree,
          tooltip: canUngroup
              ? 'Ungroup (Ctrl+U)'
              : 'Ungroup - select exactly one group',
          onTap: canUngroup ? model.ungroup : null,
        ),
      ],
    );
  }
}

/// Combine / break apart - sK1's CombinePlugin. Both refuse for now, with the
/// reason in the tooltip rather than a button that does nothing.
class _CombinePlugin extends StatelessWidget {
  const _CombinePlugin({required this.model});

  final EditorModel model;

  @override
  Widget build(BuildContext context) => const Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          _BarButton(
            icon: PhosphorIcons.circlesFour,
            tooltip: 'Combine - path booleans are not implemented yet',
            onTap: null,
          ),
          _BarButton(
            icon: PhosphorIcons.circleDashed,
            tooltip: 'Break apart - path booleans are not implemented yet',
            onTap: null,
          ),
        ],
      );
}
