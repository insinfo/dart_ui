/// CorelDRAW's Object Properties docker (Alt+Enter): everything about the
/// selection in one place - what it is, where it is, how it is filled and
/// outlined, and what its own kind of shape can change.
///
/// Every control runs a command, so a change here is the same undo step a
/// script would make, and a control that cannot apply says why.
library;

import 'dart:math' as math;

import 'package:dart_ui/dart_ui.dart';

import '../engine/editor_model.dart';
import 'panels.dart';

/// The Properties panel.
class PropertiesPanel extends StatelessWidget {
  const PropertiesPanel(
      {super.key, required this.model, required this.registry});

  final EditorModel model;
  final CommandRegistry registry;

  void _run(String command, [Map<String, Object?>? params]) =>
      registry.execute(command, params);

  @override
  Widget build(BuildContext context) {
    if (!model.hasDocument || !model.hasSelection) {
      return const ScrollViewer(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            PanelSection(
              caption: 'Properties',
              children: <Widget>[
                PanelNote('Select an object to see and change its '
                    'properties.'),
              ],
            ),
          ],
        ),
      );
    }
    final List<SelectableObject> objects = model.selection.selectedObjects;
    // CorelDRAW shows the last object selected - the one shaping and
    // alignment treat as the target.
    final SelectableObject target = objects.last;
    final VectorStyle style = target.style;
    return ScrollViewer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _objectSection(objects, target),
          _fillSection(style, target),
          _outlineSection(style),
          ..._kindSections(target),
        ],
      ),
    );
  }

  // --- object -----------------------------------------------------------------

  Widget _objectSection(
      List<SelectableObject> objects, SelectableObject target) {
    final DocUnit unit = model.units;
    final Rect bounds = model.selection.selectionBounds;
    Widget length(String label, double points, void Function(double) set) =>
        PanelRow(
          label: '$label (${unit.label})',
          child: PanelNumber(
            value: fromPoints(points, unit),
            onChanged: (double value) => set(toPoints(value, unit)),
          ),
        );
    return PanelSection(
      caption: 'Object',
      children: <Widget>[
        PanelRow(
          label: 'Kind',
          child: PanelNote(objects.length == 1
              ? describeObject(target)
              : '${objects.length} objects; showing the last selected'),
        ),
        length('X', bounds.left,
            (double x) => _run('object.position', <String, Object?>{'x': x})),
        length('Y', bounds.top,
            (double y) => _run('object.position', <String, Object?>{'y': y})),
        length('Width', bounds.width,
            (double w) => _run('object.resize', <String, Object?>{'width': w})),
        length(
            'Height',
            bounds.height,
            (double h) =>
                _run('object.resize', <String, Object?>{'height': h})),
      ],
    );
  }

  // --- fill -------------------------------------------------------------------

  Widget _fillSection(VectorStyle style, SelectableObject target) {
    final FillDescriptor fill = style.fill;
    final bool none = fill.fillType == FillType.none;
    final bool fountain = fill.fillType == FillType.linearGradient ||
        fill.fillType == FillType.radialGradient;
    final Color from = fill.gradientStops.isNotEmpty
        ? fill.gradientStops.first.color
        : fill.color;
    final Color to = fill.gradientStops.length > 1
        ? fill.gradientStops.last.color
        : const Color(0xFFFFFFFF);
    final String type =
        fill.fillType == FillType.radialGradient ? 'radial' : 'linear';
    final double angle = fill.fillType == FillType.linearGradient
        ? math.atan2(fill.gradientEnd.dy - fill.gradientStart.dy,
                fill.gradientEnd.dx - fill.gradientStart.dx) *
            180 /
            math.pi
        : 0;
    void fountainWith({Color? start, Color? end, String? kind}) =>
        _run('object.fountainFill', <String, Object?>{
          'type': kind ?? type,
          'from': '#${colorToHex(start ?? from)}',
          'to': '#${colorToHex(end ?? to)}',
          'angle': angle,
          if (kind == null) 'live': true,
        });
    return PanelSection(
      caption: 'Fill',
      children: <Widget>[
        // The colour of a uniform fill, or where a fountain starts.
        ColorPicker(
          value: fountain ? from : fill.color,
          planeSize: 150,
          onChanged: (Color color) => fountain
              ? fountainWith(start: color)
              : _run('object.fill', <String, Object?>{
                  'color': '#${colorToHex(color)}',
                  'live': true,
                }),
        ),
        if (fountain) ...<Widget>[
          const SizedBox(height: Spacing.xs),
          const Text('To'),
          ColorPicker(
            value: to,
            planeSize: 150,
            onChanged: (Color color) => fountainWith(end: color),
          ),
        ],
        const SizedBox(height: Spacing.xs),
        Wrap(
          spacing: Spacing.xs,
          runSpacing: Spacing.xs,
          children: <Widget>[
            CommandChip(
              registry: registry,
              command: 'object.fill',
              label: 'Uniform',
              params: <String, Object?>{'color': '#${colorToHex(from)}'},
            ),
            CommandChip(
              registry: registry,
              command: 'object.fountainFill',
              label: 'Linear',
              params: <String, Object?>{
                'type': 'linear',
                'from': '#${colorToHex(from)}',
                'to': '#${colorToHex(to)}',
                'angle': angle,
              },
            ),
            CommandChip(
              registry: registry,
              command: 'object.fountainFill',
              label: 'Radial',
              params: <String, Object?>{
                'type': 'radial',
                'from': '#${colorToHex(from)}',
                'to': '#${colorToHex(to)}',
              },
            ),
            CommandChip(
              registry: registry,
              command: 'object.fill',
              label: none ? 'No fill' : 'Remove fill',
              params: const <String, Object?>{'color': null},
            ),
            if (target is VectorCurve) ...<Widget>[
              CommandChip(
                registry: registry,
                command: 'object.fillRule',
                label: 'Nonzero',
                params: const <String, Object?>{'rule': 'nonZero'},
              ),
              CommandChip(
                registry: registry,
                command: 'object.fillRule',
                label: 'Even-odd',
                params: const <String, Object?>{'rule': 'evenOdd'},
              ),
            ],
          ],
        ),
      ],
    );
  }

  // --- outline ----------------------------------------------------------------

  Widget _outlineSection(VectorStyle style) {
    final StrokeDescriptor stroke = style.stroke;
    Widget chips(String label, String param, List<(String, Object)> values) =>
        PanelRow(
          label: label,
          child: Wrap(
            spacing: Spacing.xs,
            runSpacing: Spacing.xs,
            children: <Widget>[
              for (final (String name, Object value) in values)
                CommandChip(
                  registry: registry,
                  command: 'object.outlineStyle',
                  label: name,
                  params: <String, Object?>{param: value},
                ),
            ],
          ),
        );
    return PanelSection(
      caption: 'Outline',
      children: <Widget>[
        PanelRow(
          label: 'Width (pt)',
          child: PanelNumber(
            value: stroke.width,
            decimals: 2,
            min: 0,
            onChanged: (double width) =>
                _run('object.outlineWidth', <String, Object?>{'width': width}),
          ),
        ),
        ColorPicker(
          value: stroke.color,
          planeSize: 150,
          onChanged: (Color color) => _run('object.outline', <String, Object?>{
            'color': '#${colorToHex(color)}',
            'live': true,
          }),
        ),
        const SizedBox(height: Spacing.xs),
        chips('Caps', 'cap', const <(String, Object)>[
          ('Butt', 'butt'),
          ('Round', 'round'),
          ('Square', 'square'),
        ]),
        chips('Joins', 'join', const <(String, Object)>[
          ('Miter', 'miter'),
          ('Round', 'round'),
          ('Bevel', 'bevel'),
        ]),
        chips('Line', 'dash', const <(String, Object)>[
          ('Solid', <double>[]),
          ('Dash', <double>[6, 3]),
          ('Dot', <double>[1, 2]),
          ('Dash-dot', <double>[6, 3, 1, 3]),
        ]),
      ],
    );
  }

  // --- the kind of object -----------------------------------------------------

  List<Widget> _kindSections(SelectableObject target) => switch (target) {
        VectorRectangle() => <Widget>[
            PanelSection(caption: 'Rectangle', children: <Widget>[
              PanelRow(
                label: 'Corners (%)',
                child: PanelNumber(
                  value: (target.corners.isEmpty ? 0.0 : target.corners.first) *
                      100,
                  decimals: 0,
                  min: 0,
                  max: 100,
                  onChanged: (double v) =>
                      _run('rectangle.round', <String, Object?>{'percent': v}),
                ),
              ),
            ]),
          ],
        VectorCircle() => <Widget>[
            PanelSection(caption: 'Ellipse', children: <Widget>[
              Wrap(
                spacing: Spacing.xs,
                children: <Widget>[
                  for (final (String label, ArcType type)
                      in const <(String, ArcType)>[
                    ('Arc', ArcType.arc),
                    ('Chord', ArcType.chord),
                    ('Pie', ArcType.pieslice),
                  ])
                    CommandChip(
                      registry: registry,
                      command: 'ellipse.type',
                      label: label,
                      params: <String, Object?>{'type': type.name},
                    ),
                ],
              ),
            ]),
          ],
        VectorPolygon() => <Widget>[
            PanelSection(caption: 'Polygon', children: <Widget>[
              PanelRow(
                label: 'Corners',
                child: PanelNumber(
                  value: target.cornersNum.toDouble(),
                  decimals: 0,
                  min: 3,
                  max: 1000,
                  onChanged: (double v) => _run('polygon.corners',
                      <String, Object?>{'corners': v.round()}),
                ),
              ),
            ]),
          ],
        VectorText() => <Widget>[
            PanelSection(caption: 'Text', children: <Widget>[
              _TextContent(registry: registry, text: target),
              PanelRow(
                label: 'Size (pt)',
                child: PanelNumber(
                  value: target.style.textStyle.fontSize,
                  decimals: 0,
                  min: 1,
                  max: 4000,
                  onChanged: (double v) =>
                      _run('text.size', <String, Object?>{'size': v}),
                ),
              ),
            ]),
          ],
        VectorCurve() => <Widget>[
            PanelSection(caption: 'Curve', children: <Widget>[
              PanelNote(_curveSummary(target)),
            ]),
          ],
        _ => const <Widget>[],
      };

  static String _curveSummary(VectorCurve curve) {
    final int paths = curve.paths.length;
    var nodes = 0;
    var closed = 0;
    for (final VectorPath path in curve.paths) {
      nodes += NodeEditing.nodeCount(path);
      if (path.isClosed) closed++;
    }
    return '$paths ${paths == 1 ? 'path' : 'paths'} ($closed closed), '
        '$nodes ${nodes == 1 ? 'node' : 'nodes'}';
  }
}

/// What [object] is, in the words CorelDRAW's status bar uses.
String describeObject(SelectableObject object) => switch (object) {
      VectorRectangle() => 'Rectangle',
      VectorCircle() => 'Ellipse',
      VectorPolygon(:final int cornersNum) => 'Polygon, $cornersNum corners',
      VectorText() => 'Artistic text',
      VectorCurve() => 'Curve',
      VectorGroup() => 'Group',
      _ => 'Object',
    };

/// The text's content, typed through `text.content`.
///
/// Stateful for the controller: rebuilding it per frame would move the
/// caret to the end on every keystroke.
class _TextContent extends StatefulWidget {
  const _TextContent({required this.registry, required this.text});

  final CommandRegistry registry;
  final VectorText text;

  @override
  State<_TextContent> createState() => _TextContentState();
}

class _TextContentState extends State<_TextContent> {
  late final TextEditingController _controller =
      TextEditingController(widget.text.textContent)..addListener(_push);

  void _push(String value) {
    if (value == widget.text.textContent) return;
    widget.registry.execute('text.content', <String, Object?>{'text': value});
  }

  @override
  void didUpdateWidget(_TextContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_controller.value != widget.text.textContent) {
      _controller.value = widget.text.textContent;
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_push);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        height: Theme.of(context).effectiveControlHeight,
        child: TextField(controller: _controller, label: 'Text'),
      );
}
