/// The dockable side panels - sK1's `transform_plugin` and `align_plugin`,
/// plus a fill/outline panel built on the framework's own controls.
library;

import 'package:dart_ui/dart_ui.dart';

import 'editor_model.dart';

/// A panel section with a caption, the `LabeledPanel` sK1 stacks its groups in.
class PanelSection extends StatelessWidget {
  const PanelSection({
    super.key,
    required this.caption,
    required this.children,
  });

  final String caption;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(Spacing.sm),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.surface,
          border: BoxBorder(color: theme.border, width: 1),
          // A card, and the design system gives a card the large radius.
          radius: theme.cornerRadiusLarge,
        ),
        child: Padding(
          padding: const EdgeInsets.all(Spacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                caption,
                // `titleSmall` is the panel/group heading role, weight and
                // size together. It was 12 px with a hand-written w600, which
                // is one pixel *under* body text pretending to be a heading.
                style: theme.textTheme.titleSmall,
                color: theme.foreground,
              ),
              const SizedBox(height: Spacing.sm),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

/// A labelled control row of a fixed label column, so a stack of rows lines up.
class PanelRow extends StatelessWidget {
  const PanelRow({super.key, required this.label, required this.child});

  final String label;
  final Widget child;

  static const double labelWidth = 76;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.hair),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          SizedBox(
            width: labelWidth,
            child: Text(
              label,
              style: theme.textTheme.labelSmall,
              color: theme.foregroundSecondary,
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// A line of explanatory text under a panel's controls.
///
/// `labelSmall` in the secondary foreground - the design system's own
/// "legendas, metadados" role. Three copies of this sentence used to declare
/// `fontSize: 11` each, and one of them forgot the colour.
class _PanelNote extends StatelessWidget {
  const _PanelNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.labelSmall,
      color: theme.foregroundSecondary,
      softWrap: true,
    );
  }
}

/// A number field sized for a panel column.
class PanelNumber extends StatelessWidget {
  const PanelNumber({
    super.key,
    required this.value,
    required this.onChanged,
    this.decimals = 1,
    this.min = double.negativeInfinity,
    this.max = double.infinity,
    this.enabled = true,
  });

  final double value;
  final void Function(double value) onChanged;
  final int decimals;
  final double min;
  final double max;
  final bool enabled;

  @override
  Widget build(BuildContext context) => SizedBox(
        // One control tall, which at the editor's compact density is 28 - the
        // same height as the combo boxes on the property bar above.
        height: Theme.of(context).effectiveControlHeight,
        child: NumberBox(
          value: value,
          decimals: decimals,
          min: min,
          max: max,
          enabled: enabled,
          onChanged: onChanged,
        ),
      );
}

// ---------------------------------------------------------------------------
// Transformations
// ---------------------------------------------------------------------------

/// sK1's Transformations panel: a mode switch, the matching controls, Apply.
class TransformPanel extends StatelessWidget {
  const TransformPanel({super.key, required this.model});

  final EditorModel model;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = model.hasSelection;
    return ScrollViewer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: <Widget>[
                for (final mode in TransformMode.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: IconButton(
                      icon: Icon(_iconFor(mode)),
                      iconSize: theme.iconSize,
                      isSelected: model.transformMode == mode,
                      padding: const EdgeInsets.all(Spacing.xs),
                      constraints: BoxConstraints(
                        minWidth: theme.effectiveControlHeight,
                        minHeight: theme.effectiveControlHeight,
                      ),
                      tooltip: mode.label,
                      onPressed: () {
                        model.transformMode = mode;
                        model.refresh(mode.label);
                      },
                    ),
                  ),
              ],
            ),
          ),
          PanelSection(
            caption: model.transformMode.label,
            children: <Widget>[
              ..._controlsFor(model.transformMode, enabled),
              const SizedBox(height: Spacing.sm),
              if (!enabled)
                Text(
                  'Select something to transform.',
                  style: theme.textTheme.labelSmall,
                  color: theme.foregroundSecondary,
                  softWrap: true,
                ),
            ],
          ),
        ],
      ),
    );
  }

  static IconData _iconFor(TransformMode mode) => switch (mode) {
        TransformMode.position => PhosphorIcons.arrowsOutCardinal,
        TransformMode.resize => PhosphorIcons.arrowsOut,
        TransformMode.scale => PhosphorIcons.arrowsInSimple,
        TransformMode.rotate => PhosphorIcons.arrowClockwise,
        TransformMode.shear => PhosphorIcons.arrowsOutLineHorizontal,
      };

  List<Widget> _controlsFor(TransformMode mode, bool enabled) {
    final unit = model.units;
    final bounds =
        model.hasSelection ? model.selection.selectionBounds : Rect.zero;
    switch (mode) {
      case TransformMode.position:
        return <Widget>[
          PanelRow(
            label: 'Horizontal',
            child: PanelNumber(
              value: fromPoints(bounds.left, unit),
              enabled: enabled,
              onChanged: (value) =>
                  model.moveSelectionBy(toPoints(value, unit) - bounds.left, 0),
            ),
          ),
          PanelRow(
            label: 'Vertical',
            child: PanelNumber(
              value: fromPoints(bounds.top, unit),
              enabled: enabled,
              onChanged: (value) =>
                  model.moveSelectionBy(0, toPoints(value, unit) - bounds.top),
            ),
          ),
        ];
      case TransformMode.resize:
        return <Widget>[
          PanelRow(
            label: 'Width',
            child: PanelNumber(
              value: fromPoints(bounds.width, unit),
              min: 0.01,
              enabled: enabled,
              onChanged: (value) =>
                  model.resizeSelectionTo(width: toPoints(value, unit)),
            ),
          ),
          PanelRow(
            label: 'Height',
            child: PanelNumber(
              value: fromPoints(bounds.height, unit),
              min: 0.01,
              enabled: enabled,
              onChanged: (value) =>
                  model.resizeSelectionTo(height: toPoints(value, unit)),
            ),
          ),
        ];
      case TransformMode.scale:
        return <Widget>[
          PanelRow(
            label: 'Scale %',
            child: PanelNumber(
              value: 100,
              decimals: 0,
              min: 1,
              max: 10000,
              enabled: enabled,
              onChanged: (value) => model.resizeSelectionTo(
                width: bounds.width * value / 100,
                height: bounds.height * value / 100,
              ),
            ),
          ),
          Row(
            children: <Widget>[
              Button(
                label: 'Flip horizontal',
                onPressed:
                    enabled ? () => model.flipSelection(horizontal: true) : null,
              ),
              const SizedBox(width: 6),
              Button(
                label: 'Flip vertical',
                onPressed: enabled
                    ? () => model.flipSelection(horizontal: false)
                    : null,
              ),
            ],
          ),
        ];
      case TransformMode.rotate:
        return <Widget>[
          PanelRow(
            label: 'Angle',
            child: PanelNumber(
              value: 0,
              min: -360,
              max: 360,
              enabled: enabled,
              onChanged: model.rotateSelection,
            ),
          ),
          Row(
            children: <Widget>[
              Button(
                label: '-90',
                onPressed: enabled ? () => model.rotateSelection(-90) : null,
              ),
              const SizedBox(width: 6),
              Button(
                label: '+90',
                onPressed: enabled ? () => model.rotateSelection(90) : null,
              ),
            ],
          ),
        ];
      case TransformMode.shear:
        // Shearing needs a matrix editor the document model does not expose
        // yet; saying so beats a control that quietly does nothing.
        return <Widget>[
          PanelRow(
            label: 'Horizontal',
            child: PanelNumber(
              value: 0,
              min: -89,
              max: 89,
              enabled: false,
              onChanged: (_) {},
            ),
          ),
          const SizedBox(height: Spacing.xs),
          const _PanelNote('Shearing is not implemented in the Dart demo yet.'),
        ];
    }
  }
}

// ---------------------------------------------------------------------------
// Align and Distribute
// ---------------------------------------------------------------------------

/// sK1's Align and Distribute panel.
class AlignPanel extends StatelessWidget {
  const AlignPanel({super.key, required this.model});

  final EditorModel model;

  @override
  Widget build(BuildContext context) {
    final selected = model.hasSelection;
    final canDistribute = model.hasDocument && model.selection.count >= 3;
    return ScrollViewer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          PanelSection(
            caption: 'Align',
            children: <Widget>[
              PanelRow(
                label: 'Relative to:',
                child: SizedBox(
                  height: 24,
                  child: ComboBox<AlignReference>(
                    label: 'Align relative to',
                    value: model.alignReference,
                    items: <ComboBoxItem<AlignReference>>[
                      for (final reference in AlignReference.values)
                        ComboBoxItem<AlignReference>(
                          value: reference,
                          label: reference.label,
                        ),
                    ],
                    onChanged: selected
                        ? (AlignReference reference) {
                            model.alignReference = reference;
                            model.refresh('Align to ${reference.label}');
                          }
                        : null,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: <Widget>[
                  _AlignButton(
                    icon: PhosphorIcons.alignLeft,
                    tooltip: 'Align to left side',
                    selected: model.horizontalAlign == HorizontalAlign.left,
                    enabled: selected,
                    onTap: () => _setHorizontal(HorizontalAlign.left),
                  ),
                  _AlignButton(
                    icon: PhosphorIcons.alignCenterVertical,
                    tooltip: 'Align to centre horizontally',
                    selected: model.horizontalAlign == HorizontalAlign.centre,
                    enabled: selected,
                    onTap: () => _setHorizontal(HorizontalAlign.centre),
                  ),
                  _AlignButton(
                    icon: PhosphorIcons.alignRight,
                    tooltip: 'Align to right side',
                    selected: model.horizontalAlign == HorizontalAlign.right,
                    enabled: selected,
                    onTap: () => _setHorizontal(HorizontalAlign.right),
                  ),
                  const SizedBox(width: 8),
                  _AlignButton(
                    icon: PhosphorIcons.alignTop,
                    tooltip: 'Align to top',
                    selected: model.verticalAlign == VerticalAlign.top,
                    enabled: selected,
                    onTap: () => _setVertical(VerticalAlign.top),
                  ),
                  _AlignButton(
                    icon: PhosphorIcons.alignCenterHorizontal,
                    tooltip: 'Align to centre vertically',
                    selected: model.verticalAlign == VerticalAlign.middle,
                    enabled: selected,
                    onTap: () => _setVertical(VerticalAlign.middle),
                  ),
                  _AlignButton(
                    icon: PhosphorIcons.alignBottom,
                    tooltip: 'Align to bottom',
                    selected: model.verticalAlign == VerticalAlign.bottom,
                    enabled: selected,
                    onTap: () => _setVertical(VerticalAlign.bottom),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              CheckBox(
                label: 'Selection as group',
                value: model.alignAsGroup,
                // sK1 only offers this when aligning to the page and more than
                // one object is selected; the same rule, ported.
                onChanged: selected &&
                        model.selection.count > 1 &&
                        model.alignReference == AlignReference.page
                    ? (bool value) {
                        model.alignAsGroup = value;
                        model.refresh();
                      }
                    : null,
              ),
              const SizedBox(height: Spacing.sm),
              Button(
                label: 'Apply',
                onPressed: selected &&
                        (model.horizontalAlign != null ||
                            model.verticalAlign != null)
                    ? model.applyAlign
                    : null,
              ),
              if (!selected) const _PanelNote('Nothing is selected.'),
            ],
          ),
          PanelSection(
            caption: 'Distribute',
            children: <Widget>[
              Row(
                children: <Widget>[
                  _AlignButton(
                    icon: PhosphorIcons.arrowsOutLineHorizontal,
                    tooltip: 'Distribute by centre horizontally',
                    selected: false,
                    enabled: canDistribute,
                    onTap: () => model.applyDistribute(horizontal: true),
                  ),
                  _AlignButton(
                    icon: PhosphorIcons.arrowsOutLineVertical,
                    tooltip: 'Distribute by centre vertically',
                    selected: false,
                    enabled: canDistribute,
                    onTap: () => model.applyDistribute(horizontal: false),
                  ),
                ],
              ),
              if (!canDistribute)
                const _PanelNote(
                    'Distributing needs at least three selected objects.'),
            ],
          ),
        ],
      ),
    );
  }

  void _setHorizontal(HorizontalAlign value) {
    model.horizontalAlign = model.horizontalAlign == value ? null : value;
    model.refresh();
  }

  void _setVertical(VerticalAlign value) {
    model.verticalAlign = model.verticalAlign == value ? null : value;
    model.refresh();
  }
}

class _AlignButton extends StatelessWidget {
  const _AlignButton({
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool selected;
  final bool enabled;
  final void Function() onTap;

  @override
  Widget build(BuildContext context) => IconButton(
        icon: Icon(icon),
        iconSize: 15,
        isSelected: selected,
        padding: const EdgeInsets.all(5),
        constraints: BoxConstraints(minWidth: 26, minHeight: 26),
        tooltip: tooltip,
        onPressed: enabled ? onTap : null,
      );
}

// ---------------------------------------------------------------------------
// Fill and Outline
// ---------------------------------------------------------------------------

/// Fill and outline for the selection, reusing the framework's own controls.
class FillStrokePanel extends StatelessWidget {
  const FillStrokePanel({super.key, required this.model});

  final EditorModel model;

  @override
  Widget build(BuildContext context) => ScrollViewer(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            PanelSection(
              caption: 'Fill',
              children: <Widget>[
                FillControls(
                  fill: model.currentFill,
                  onChanged: (FillDescriptor fill) {
                    model.currentFill = fill;
                    if (model.hasSelection) {
                      model.applyToSelection(
                        (style) => style.copyWith(fill: fill),
                      );
                    } else {
                      model.refresh('Default fill changed');
                    }
                  },
                ),
              ],
            ),
            PanelSection(
              caption: 'Outline',
              children: <Widget>[
                StrokeControls(
                  stroke: model.currentStroke,
                  onChanged: (StrokeDescriptor stroke) {
                    model.currentStroke = stroke;
                    if (model.hasSelection) {
                      model.applyToSelection(
                        (style) => style.copyWith(stroke: stroke),
                      );
                    } else {
                      model.refresh('Default outline changed');
                    }
                  },
                ),
              ],
            ),
          ],
        ),
      );
}
