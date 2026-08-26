/// Fill style controls for the vector editor context panel.
///
library;

import '../../graphics/color.dart';
import '../../graphics/vector/constants.dart';
import '../../graphics/vector/style.dart';
import '../../layout/edge_insets.dart';
import '../../layout/render_wrap.dart';
import '../basic.dart';
import '../gesture_detector.dart';
import '../proxy.dart';
import '../theme.dart';
import '../widget.dart';

/// The chips lay out in a [Wrap], not a [Row].
///
/// Seven preset widths and a label do not fit across a 260 px panel, and a
/// [Row] answers that by drawing them off the edge: three of the presets were
/// simply not reachable in the docked panel, and nothing said so. Wrapping is
/// what a bar of chips is for.
/// Interactive fill property editor widget.
class FillControls extends StatelessWidget {
  const FillControls({
    super.key,
    required this.fill,
    this.onChanged,
  });

  final FillDescriptor fill;
  final void Function(FillDescriptor fill)? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: Spacing.xs,
      runSpacing: Spacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          'Fill:',
          style: theme.textTheme.labelSmall,
          color: theme.foregroundSecondary,
        ),
        _StyleChip(
          label: 'None',
          selected: fill.fillType == FillType.none,
          onTap: () => onChanged?.call(FillDescriptor.none),
        ),
        _StyleChip(
          label: 'Solid',
          selected: fill.fillType == FillType.solid,
          onTap: () => onChanged?.call(
            fill.copyWith(fillType: FillType.solid),
          ),
        ),
        _StyleChip(
          label: 'Linear',
          selected: fill.fillType == FillType.linearGradient,
          onTap: () => onChanged?.call(
            fill.copyWith(
              fillType: FillType.linearGradient,
              gradientStops: [
                GradientColorStop(0.0, fill.color),
                const GradientColorStop(1.0, Color(0xFFFFFFFF)),
              ],
            ),
          ),
        ),
        _StyleChip(
          label: 'Radial',
          selected: fill.fillType == FillType.radialGradient,
          onTap: () => onChanged?.call(
            fill.copyWith(
              fillType: FillType.radialGradient,
              gradientStops: [
                GradientColorStop(0.0, fill.color),
                const GradientColorStop(1.0, Color(0xFF000000)),
              ],
            ),
          ),
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
