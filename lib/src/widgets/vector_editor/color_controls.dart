/// The colour palette strip, and the swatch it is made of.
///
/// The strip used to be twenty-four hard-cornered rectangles butted against
/// each other with a one-pixel inset, which is the drawing of a colour *ramp*
/// and not of a row of controls: nothing in it moved under the pointer, nothing
/// said which colour the selection already had, nothing could be reached from
/// the keyboard, and the corners disagreed with every other small control in
/// the window. A swatch is a control. It gets the small radius the design
/// system gives "check box, chip, swatch, botão de ícone", the neutral state
/// ramp (`hoverSurface` / `pressedSurface`), the accent wash that marks a
/// *selected* neutral control, and a focus ring.
///
/// **One tab stop, not twenty-four.** The strip owns a single [FocusNode] and
/// hands it to whichever swatch has the keyboard, exactly the way [Tabs] does
/// with its headers: Tab moves into the palette and out again, and the arrow
/// keys walk it. Twenty-four tab stops between a user and the next control is
/// the difference between a keyboard-usable window and a keyboard-hostile one.
library;

import '../../geometry/offset.dart';
import '../../geometry/rect.dart';
import '../../geometry/size.dart';
import '../../graphics/color.dart';
import '../../graphics/display_list.dart';
import '../../layout/edge_insets.dart';
import '../../layout/render_box.dart';
import '../../layout/render_flex.dart';
import '../../platform/input_events.dart';
import '../../semantics/semantics.dart';
import '../basic.dart';
import '../control.dart';
import '../controls.dart' show Tooltip;
import '../element.dart';
import '../focus.dart';
import '../focus_scope.dart';
import '../proxy.dart';
import '../style.dart';
import '../theme.dart';
import '../widget.dart';

/// Predefined standard palette colours (classic CorelDRAW default palette).
const List<Color> kStandardPalette = [
  Color(0xFF000000), // Black
  Color(0xFF424242), // Dark Grey
  Color(0xFF757575), // Grey
  Color(0xFFBDBDBD), // Light Grey
  Color(0xFFEEEEEE), // Very Light Grey
  Color(0xFFFFFFFF), // White
  Color(0xFFD32F2F), // Red
  Color(0xFFE91E63), // Pink
  Color(0xFF9C27B0), // Purple
  Color(0xFF673AB7), // Deep Purple
  Color(0xFF3F51B5), // Indigo
  Color(0xFF2196F3), // Blue
  Color(0xFF03A9F4), // Light Blue
  Color(0xFF00BCD4), // Cyan
  Color(0xFF009688), // Teal
  Color(0xFF4CAF50), // Green
  Color(0xFF8BC34A), // Light Green
  Color(0xFFCDDC39), // Lime
  Color(0xFFFFEB3B), // Yellow
  Color(0xFFFFC107), // Amber
  Color(0xFFFF9800), // Orange
  Color(0xFFFF5722), // Deep Orange
  Color(0xFF795548), // Brown
];

/// Horizontal swatch palette bar widget placed at the bottom of the editor.
///
/// The two buttons are the two a real editor binds: **left-click fills, right
/// click strokes**. sK1 does exactly this, and so does CorelDRAW; a palette
/// that only filled would make setting an outline colour a trip through a
/// dialog. From the keyboard, Enter or Space fills and the arrows move.
class ColorPaletteBar extends StatefulWidget {
  const ColorPaletteBar({
    super.key,
    this.palette = kStandardPalette,
    this.onColorSelected,
    this.onStrokeColorSelected,
    this.swatchSize = 16.0,
    this.height,
    this.selectedFill,
    this.selectedStroke,
  });

  final List<Color> palette;

  /// Left click: apply as fill. `null` colour means "no fill".
  final void Function(Color? color)? onColorSelected;

  /// Right click: apply as stroke. `null` colour means "no stroke".
  final void Function(Color? color)? onStrokeColorSelected;

  final double swatchSize;

  /// Overall bar height; defaults to the swatch plus the plate around it.
  final double? height;

  /// The selection's current fill, so the palette can mark it.
  ///
  /// A palette that never says which of its twenty-four cells the selected
  /// object already has is a palette you have to guess at. `null` means the
  /// selection has no fill, which is the empty cell.
  final Color? selectedFill;

  /// The selection's current outline, marked with a thinner ring.
  final Color? selectedStroke;

  @override
  State<ColorPaletteBar> createState() => _ColorPaletteBarState();
}

class _ColorPaletteBarState extends State<ColorPaletteBar> {
  late final FocusNode _focusNode = FocusNode(debugLabel: 'ColorPaletteBar');

  /// Which cell holds the strip's focus. 0 is the "no colour" cell.
  int _focused = 0;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  int get _count => widget.palette.length + 1;

  /// The colour of cell [index], with 0 meaning "none".
  Color? _colorAt(int index) => index == 0 ? null : widget.palette[index - 1];

  void _move(int delta) {
    final int next = (_focused + delta).clamp(0, _count - 1);
    if (next == _focused) return;
    setState(() => _focused = next);
  }

  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    switch (event.logicalKey) {
      case logicalKeyArrowRight:
        _move(1);
        return true;
      case logicalKeyArrowLeft:
        _move(-1);
        return true;
      case logicalKeyHome:
        _move(-_count);
        return true;
      case logicalKeyEnd:
        _move(_count);
        return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The plate a swatch's hover and selection wash are painted on: the chip
    // plus one grid step either side, so the row reads as a row of controls
    // rather than as one continuous ramp of colour.
    final double cell = widget.swatchSize + Spacing.xs;
    return FocusAttachment(
      node: _focusNode,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.surfaceAlternate,
          border: BoxBorder(color: theme.border, width: 1),
        ),
        child: SizedBox(
          height: widget.height ?? cell + Spacing.sm,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.xs,
              vertical: Spacing.xs,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                for (var index = 0; index < _count; index++)
                  Tooltip(
                    message: index == 0
                        ? 'Empty pattern - click to clear the fill, '
                            'right-click to clear the outline'
                        : _describe(widget.palette[index - 1]),
                    child: _SwatchWidget(
                      key: ValueKey<int>(index),
                      color: _colorAt(index),
                      cell: cell,
                      chip: widget.swatchSize,
                      theme: theme,
                      isFill: _isFill(index),
                      isStroke: _isStroke(index),
                      // Only the focused cell is handed the strip's node, so the
                      // strip stays one tab stop and the ring lands on the cell
                      // the arrows moved to.
                      focusNode: index == _focused ? _focusNode : null,
                      onKeyEvent: _handleKey,
                      onFill: () {
                        setState(() => _focused = index);
                        widget.onColorSelected?.call(_colorAt(index));
                      },
                      onStroke: () {
                        setState(() => _focused = index);
                        widget.onStrokeColorSelected?.call(_colorAt(index));
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool _isFill(int index) {
    final Color? colour = _colorAt(index);
    if (index == 0) return widget.selectedFill == null && _hasSelection;
    return colour == widget.selectedFill;
  }

  bool _isStroke(int index) {
    final Color? colour = _colorAt(index);
    if (index == 0) return false;
    return colour == widget.selectedStroke;
  }

  /// Whether the palette has been told anything about the selection at all.
  ///
  /// Without this the empty cell would be marked "current" in every window
  /// that never passes a fill, which is worse than marking nothing.
  bool get _hasSelection =>
      widget.selectedFill != null || widget.selectedStroke != null;

  static String _describe(Color color) {
    final hex = color.value.toRadixString(16).padLeft(8, '0').substring(2);
    return '#${hex.toUpperCase()} - click to fill, right-click to outline';
  }
}

final class _SwatchWidget extends RenderObjectWidget {
  const _SwatchWidget({
    super.key,
    required this.color,
    required this.cell,
    required this.chip,
    required this.theme,
    required this.isFill,
    required this.isStroke,
    required this.focusNode,
    required this.onKeyEvent,
    required this.onFill,
    required this.onStroke,
  });

  final Color? color;
  final double cell;
  final double chip;
  final ThemeData theme;
  final bool isFill;
  final bool isStroke;
  final FocusNode? focusNode;
  final bool Function(KeyEvent event) onKeyEvent;
  final void Function() onFill;
  final void Function() onStroke;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderColorSwatch createRenderObject(BuildContext context) =>
      RenderColorSwatch(
        color: color,
        cell: cell,
        chip: chip,
        isFill: isFill,
        isStroke: isStroke,
      )
        ..theme = theme
        ..focusNode = focusNode
        ..onKeyEvent = onKeyEvent
        ..onFill = onFill
        ..onStroke = onStroke;

  @override
  void updateRenderObject(
      BuildContext context, covariant RenderColorSwatch renderObject) {
    renderObject
      ..color = color
      ..cell = cell
      ..chip = chip
      ..isFill = isFill
      ..isStroke = isStroke
      ..theme = theme
      ..focusNode = focusNode
      ..onKeyEvent = onKeyEvent
      ..onFill = onFill
      ..onStroke = onStroke;
  }
}

/// One palette cell: a colour chip on a plate that carries its states.
///
/// The plate is what hover, press and "this is the selection's colour" are
/// painted on, and it is why the chip itself never changes colour: a swatch
/// whose *fill* lightened under the pointer would be lying about the colour it
/// is offering.
final class RenderColorSwatch extends RenderBox with ControlBehavior {
  RenderColorSwatch({
    required Color? color,
    required double cell,
    required double chip,
    required bool isFill,
    required bool isStroke,
  })  : _color = color,
        _cell = cell,
        _chip = chip,
        _isFill = isFill,
        _isStroke = isStroke;

  /// `null` is the "no colour" cell.
  Color? _color;
  set color(Color? value) {
    if (_color == value) return;
    _color = value;
    markNeedsPaint();
  }

  double _cell;
  set cell(double value) {
    if (_cell == value) return;
    _cell = value;
    markNeedsLayout();
  }

  double _chip;
  set chip(double value) {
    if (_chip == value) return;
    _chip = value;
    markNeedsPaint();
  }

  bool _isFill;
  set isFill(bool value) {
    if (_isFill == value) return;
    _isFill = value;
    markNeedsPaint();
  }

  bool _isStroke;
  set isStroke(bool value) {
    if (_isStroke == value) return;
    _isStroke = value;
    markNeedsPaint();
  }

  bool Function(KeyEvent event)? onKeyEvent;
  void Function()? onFill;
  void Function()? onStroke;

  @override
  Set<PseudoClass> get controlStates => <PseudoClass>{
        if (_isFill || _isStroke) PseudoClass.selected,
      };

  @override
  void activate() => onFill?.call();

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void performLayout() => size = constraints.constrain(Size(_cell, _cell));

  /// The secondary button sets the *outline*, which [ControlBehavior] knows
  /// nothing about - it arbitrates the primary button only, by design. The
  /// release is enough: a right-press that travels off the swatch is not a
  /// gesture anything in this window offers.
  @override
  void handlePointerEvent(PointerEvent event) {
    if (event is PointerUpEvent && event.button == PointerButton.secondary) {
      if (enabled && containsGlobalPoint(event.logicalPosition)) {
        onStroke?.call();
      }
      return;
    }
    super.handlePointerEvent(event);
  }

  @override
  bool handleKeyEvent(KeyEvent event) {
    if (onKeyEvent?.call(event) ?? false) return true;
    return super.handleKeyEvent(event);
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect plate =
        Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height);
    final double radius = theme.cornerRadiusSmall;

    // The neutral ramp, unchanged from every other neutral control: nothing at
    // rest, `hoverSurface` under the pointer, `pressedSurface` while held, and
    // the accent wash when this is the colour the selection already carries.
    final Color? plateColor = neutralSurfaceColor(selected: _isFill);
    if (plateColor != null) paintRoundedFill(list, plate, plateColor, radius);

    // The outline marker is a ring rather than a wash, so a swatch that is both
    // the fill and the outline still shows both.
    if (_isStroke) {
      paintRoundedBorder(list, plate.deflate(0.5), theme.accent, radius,
          width: 1);
    }

    final Rect chipRect = Rect.fromLTWH(
      (plate.center.dx - _chip / 2).roundToDouble(),
      (plate.center.dy - _chip / 2).roundToDouble(),
      _chip,
      _chip,
    );
    final Color? swatch = _color;
    paintRoundedFill(
      list,
      chipRect,
      swatch ?? theme.surfaceAlternate,
      radius,
    );
    // Always an outline, and always `borderStrong`: white is a colour in this
    // palette, and an unbordered white chip on a white bar is not a chip.
    paintRoundedBorder(list, chipRect, theme.borderStrong, radius, width: 1);

    if (swatch == null) {
      // The "no colour" cell, drawn rather than typed. It used to be the
      // letter `x` at 9 px in a hard-coded red, which is a glyph standing in
      // for a mark - and a glyph the interface face is not guaranteed to
      // centre.
      final double inset = _chip * 0.26;
      paintPolylineMark(
        list,
        <Offset>[
          Offset(chipRect.left + inset, chipRect.top + inset),
          Offset(chipRect.right - inset, chipRect.bottom - inset),
        ],
        1.5,
        theme.colorScheme.error,
      );
      paintPolylineMark(
        list,
        <Offset>[
          Offset(chipRect.right - inset, chipRect.top + inset),
          Offset(chipRect.left + inset, chipRect.bottom - inset),
        ],
        1.5,
        theme.colorScheme.error,
      );
    }

    paintFocusRing(list, plate, radius: radius);
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.button,
        label: _color == null
            ? 'No colour'
            : '#${_color!.value.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}',
        states: <SemanticsState>{
          if (_isFill || _isStroke) SemanticsState.selected,
        },
      );
}
