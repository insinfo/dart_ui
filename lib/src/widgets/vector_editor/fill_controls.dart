/// Fill style controls for the vector editor context panel.
///
library;


import '../../graphics/color.dart';
import '../../graphics/vector/constants.dart';
import '../../graphics/vector/style.dart';
import '../../layout/edge_insets.dart';
import '../basic.dart';
import '../gesture_detector.dart';
import '../widget.dart';

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
    return Row(
      children: [
        const Text('Fill: ', color: Color(0xFF616161), fontSize: 11),
        const SizedBox(width: 4),
        // Type buttons: None, Solid, Linear, Radial
        _TypeButton(
          label: 'None',
          selected: fill.fillType == FillType.none,
          onTap: () => onChanged?.call(FillDescriptor.none),
        ),
        const SizedBox(width: 2),
        _TypeButton(
          label: 'Solid',
          selected: fill.fillType == FillType.solid,
          onTap: () => onChanged?.call(
            fill.copyWith(fillType: FillType.solid),
          ),
        ),
        const SizedBox(width: 2),
        _TypeButton(
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
        const SizedBox(width: 2),
        _TypeButton(
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

class _TypeButton extends StatelessWidget {
  const _TypeButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final void Function() onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2.0),
        child: ColoredBox(
          color: selected ? const Color(0xFF2196F3) : const Color(0xFFE0E0E0),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6.0, vertical: 2.0),
            child: Text(
              label,
              color: selected ? const Color(0xFFFFFFFF) : const Color(0xFF424242),
              fontSize: 10,
            ),
          ),
        ),
      ),
    );
  }
}
