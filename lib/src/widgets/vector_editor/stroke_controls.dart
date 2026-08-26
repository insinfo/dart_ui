/// Stroke property controls for the vector editor context panel.
///
library;

import '../../graphics/vector/constants.dart';
import '../../graphics/vector/style.dart';
import '../../layout/edge_insets.dart';
import '../../layout/render_wrap.dart';
import '../basic.dart';
import '../gesture_detector.dart';
import '../proxy.dart';
import '../theme.dart';
import '../widget.dart';

/// Predefined stroke widths.
const List<double> kStrokeWidths = [0.0, 0.5, 1.0, 2.0, 3.0, 4.0, 8.0];

/// The chips lay out in a [Wrap], not a [Row].
///
/// Seven preset widths and a label do not fit across a 260 px panel, and a
/// [Row] answers that by drawing them off the edge: three of the presets were
/// simply not reachable in the docked panel, and nothing said so. Wrapping is
/// what a bar of chips is for.
/// Interactive stroke property editor widget.
class StrokeControls extends StatelessWidget {
  const StrokeControls({
    super.key,
    required this.stroke,
    this.onChanged,
  });

  final StrokeDescriptor stroke;
  final void Function(StrokeDescriptor stroke)? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: Spacing.xs,
      runSpacing: Spacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          'Stroke:',
          style: theme.textTheme.labelSmall,
          color: theme.foregroundSecondary,
        ),
        for (final w in kStrokeWidths)
          _StyleChip(
            label: w == 0.0 ? 'None' : '${w.toStringAsFixed(1)}pt',
            selected: (stroke.width - w).abs() < 0.1,
            onTap: () => onChanged?.call(stroke.copyWith(width: w)),
          ),
        for (final (String label, LineCap cap) in <(String, LineCap)>[
          ('Butt', LineCap.butt),
          ('Round', LineCap.round),
          ('Square', LineCap.square),
        ])
          _StyleChip(
            label: label,
            selected: stroke.cap == cap,
            onTap: () => onChanged?.call(stroke.copyWith(cap: cap)),
          ),
      ],
    );
  }
}

/// A small labelled toggle: the shape a row of mutually exclusive style
/// choices takes on a property bar.
///
/// It used to be a flat `#E0E0E0` rectangle that turned `#2196F3` when
/// selected, with 10 px white text on it - a control that agreed with nothing
/// else in the window and shouted louder than any of it. Now it is the
/// framework's neutral ramp with the accent *wash* for "selected", which is the
/// design system's own rule for a marked-but-not-primary control, and the small
/// radius it gives a chip.
class _StyleChip extends StatelessWidget {
  const _StyleChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final void Function() onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.hair),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: selected ? theme.accentSubtle : null,
            border: BoxBorder(
              color: selected ? theme.accent : theme.border,
              width: 1,
            ),
            radius: theme.cornerRadiusSmall,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.sm,
              vertical: Spacing.xs,
            ),
            child: Text(
              label,
              style: theme.textTheme.labelSmall,
              color: selected ? theme.accent : theme.foregroundSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
