/// The Objects panel: the page's layers and what is on each, CorelDRAW's
/// Objects docker and Graphite's Layers panel.
///
/// Front-most first, the way every layers panel reads: the top row is what
/// is drawn last. A layer row carries its eye and lock; clicking it makes it
/// the layer new objects go on. An object row selects that object - with
/// Shift, adds it - and shows what kind of object it is.
library;

import 'package:dart_ui/dart_ui.dart';

import 'editor_model.dart';

/// The row height every row shares: the theme's row, plus room for the
/// swatch and the eye and lock buttons.
double _rowHeight(ThemeData theme) => theme.effectiveRowHeight + 2;

class ObjectsPanel extends StatelessWidget {
  const ObjectsPanel({super.key, required this.model});

  final EditorModel model;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!model.hasDocument) return const SizedBox();
    final session = model.active;
    final layers = session.layers.reversed.toList();
    final active = session.layer;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: ScrollViewer(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final layer in layers) ...<Widget>[
                  _LayerRow(
                    model: model,
                    layer: layer,
                    active: identical(layer, active),
                  ),
                  for (final object
                      in layer.children.reversed.whereType<SelectableObject>())
                    _ObjectRow(
                      model: model,
                      object: object,
                      enabled: layer.isVisible && layer.isEditable,
                    ),
                ],
              ],
            ),
          ),
        ),
        SizedBox(
          height: 1,
          child: ColoredBox(color: theme.border),
        ),
        SizedBox(
          height: theme.effectiveControlHeight + 4,
          child: Row(
            children: <Widget>[
              const SizedBox(width: 4),
              _IconButton(
                icon: PhosphorIcons.plus,
                tooltip: 'New layer',
                onTap: model.addLayer,
              ),
              _IconButton(
                icon: PhosphorIcons.arrowUp,
                tooltip: 'Raise layer',
                onTap: () => model.moveLayer(active, up: true),
              ),
              _IconButton(
                icon: PhosphorIcons.arrowDown,
                tooltip: 'Lower layer',
                onTap: () => model.moveLayer(active, up: false),
              ),
              const Spacer(),
              _IconButton(
                icon: PhosphorIcons.trash,
                tooltip: session.layers.length > 1
                    ? 'Delete layer and its objects'
                    : 'The last layer cannot be deleted',
                onTap: session.layers.length > 1
                    ? () => model.deleteLayer(active)
                    : null,
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ],
    );
  }
}

class _LayerRow extends StatelessWidget {
  const _LayerRow({
    required this.model,
    required this.layer,
    required this.active,
  });

  final EditorModel model;
  final VectorLayer layer;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = layer.children.whereType<SelectableObject>().length;
    return GestureDetector(
      behavior: GestureHitTestBehavior.opaque,
      onTap: () => model.activateLayer(layer),
      child: SizedBox(
        height: _rowHeight(theme),
        child: ColoredBox(
          color: active ? theme.surfaceRaised : theme.surfaceAlternate,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              SizedBox(
                width: 3,
                height: _rowHeight(theme),
                child: ColoredBox(
                    color: active ? theme.accent : const Color(0x00000000)),
              ),
              _IconButton(
                icon: layer.isVisible
                    ? PhosphorIcons.eye
                    : PhosphorIcons.eyeSlash,
                tooltip: layer.isVisible ? 'Hide layer' : 'Show layer',
                dim: !layer.isVisible,
                onTap: () => model.setLayerVisible(layer, !layer.isVisible),
              ),
              _IconButton(
                icon: layer.isEditable
                    ? PhosphorIcons.lockSimpleOpen
                    : PhosphorIcons.lockSimple,
                tooltip: layer.isEditable ? 'Lock layer' : 'Unlock layer',
                dim: layer.isEditable,
                onTap: () => model.setLayerLocked(layer, layer.isEditable),
              ),
              const SizedBox(width: 4),
              const Icon(PhosphorIcons.stack),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  layer.name,
                  style: theme.textTheme.bodySmall,
                  color: active ? theme.foreground : theme.foregroundSecondary,
                  maxLines: 1,
                ),
              ),
              Text(
                '$count',
                style: theme.textTheme.labelSmall,
                color: theme.foregroundSecondary,
              ),
              // Clear of the scrollbar.
              const SizedBox(width: 14),
            ],
          ),
        ),
      ),
    );
  }
}

class _ObjectRow extends StatelessWidget {
  const _ObjectRow({
    required this.model,
    required this.object,
    required this.enabled,
  });

  final EditorModel model;
  final SelectableObject object;
  final bool enabled;

  static (IconData, String) describe(SelectableObject object) =>
      switch (object) {
        VectorRectangle() => (PhosphorIcons.square, 'Rectangle'),
        VectorCircle() => (PhosphorIcons.circle, 'Ellipse'),
        VectorPolygon(:final cornersNum) => (
            PhosphorIcons.polygon,
            'Polygon, $cornersNum corners'
          ),
        VectorCurve() => (PhosphorIcons.bezierCurve, 'Curve'),
        VectorText(:final textContent) => (
            PhosphorIcons.textT,
            textContent.length > 24
                ? '${textContent.substring(0, 24)}…'
                : textContent
          ),
        VectorGroup(:final children) => (
            PhosphorIcons.selection,
            'Group of ${children.length}'
          ),
        _ => (PhosphorIcons.circle, object.className),
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = model.selection.contains(object);
    final (icon, label) = describe(object);
    final fill = object.style.fill;
    return GestureDetector(
      behavior: GestureHitTestBehavior.opaque,
      onTap: enabled
          ? () => model.pickObject(
                object,
                toggle: model.selection.hasSelection && _shiftHeld(context),
              )
          : null,
      child: SizedBox(
        height: _rowHeight(theme),
        child: ColoredBox(
          color: selected ? theme.selection : const Color(0x00000000),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              const SizedBox(width: 30),
              // The object's own colour, the closest thing to a thumbnail a
              // row this small can hold.
              SizedBox(
                width: 12,
                height: 12,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: fill.isNone ? null : fill.color,
                    border: BoxBorder(
                      color: object.style.stroke.isNone
                          ? theme.borderStrong
                          : object.style.stroke.color,
                      width: 1,
                    ),
                    radius: 2,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Icon(icon),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodySmall,
                  color: enabled ? theme.foreground : theme.disabledForeground,
                  maxLines: 1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static bool _shiftHeld(BuildContext context) {
    final owner = context is Element ? context.owner : null;
    return owner?.heldModifiers.contains(KeyModifier.shift) ?? false;
  }
}

class _IconButton extends StatelessWidget {
  const _IconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.dim = false,
  });

  final IconData icon;
  final String tooltip;
  final void Function()? onTap;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        behavior: GestureHitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: theme.effectiveRowHeight,
          height: theme.effectiveRowHeight,
          child: Center(
            child: Icon(
              icon,
              color: onTap == null || dim
                  ? theme.disabledForeground
                  : theme.foregroundSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
