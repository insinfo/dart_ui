/// Stroke property controls for the vector editor context panel.
///
library;


import '../../graphics/color.dart';
import '../../graphics/vector/constants.dart';
import '../../graphics/vector/style.dart';
import '../../layout/edge_insets.dart';
import '../basic.dart';
import '../gesture_detector.dart';
import '../widget.dart';

/// Predefined stroke widths.
const List<double> kStrokeWidths = [0.0, 0.5, 1.0, 2.0, 3.0, 4.0, 8.0];

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
    return Row(
      children: [
        const Text('Stroke: ', color: Color(0xFF616161), fontSize: 11),
        const SizedBox(width: 4),
        // Preset width buttons
        ...kStrokeWidths.map((w) => _WidthButton(
              width: w,
              selected: (stroke.width - w).abs() < 0.1,
              onTap: () => onChanged?.call(stroke.copyWith(width: w)),
            )),
        const SizedBox(width: 8),
        // Cap buttons: Butt, Round, Square
        _OptionButton(
          label: 'Butt',
          selected: stroke.cap == LineCap.butt,
          onTap: () => onChanged?.call(stroke.copyWith(cap: LineCap.butt)),
        ),
        const SizedBox(width: 2),
        _OptionButton(
          label: 'Round',
          selected: stroke.cap == LineCap.round,
          onTap: () => onChanged?.call(stroke.copyWith(cap: LineCap.round)),
        ),
        const SizedBox(width: 2),
        _OptionButton(
          label: 'Square',
          selected: stroke.cap == LineCap.square,
          onTap: () => onChanged?.call(stroke.copyWith(cap: LineCap.square)),
        ),
      ],
    );
  }
}

class _WidthButton extends StatelessWidget {
  const _WidthButton({
    required this.width,
    required this.selected,
    required this.onTap,
  });

  final double width;
  final bool selected;
  final void Function() onTap;

  @override
  Widget build(BuildContext context) {
    final label = width == 0.0 ? 'None' : '${width.toStringAsFixed(1)}pt';
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1.0),
        child: ColoredBox(
          color: selected ? const Color(0xFF2196F3) : const Color(0xFFE0E0E0),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 2.0),
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

class _OptionButton extends StatelessWidget {
  const _OptionButton({
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
        padding: const EdgeInsets.symmetric(horizontal: 1.0),
        child: ColoredBox(
          color: selected ? const Color(0xFF2196F3) : const Color(0xFFE0E0E0),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 2.0),
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
