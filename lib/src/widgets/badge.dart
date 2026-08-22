/// Small visual primitives: [Badge], [Chip], [Avatar], [Card].
///
/// Four controls in one file because they share a nature: little pieces of
/// chrome that mostly paint and barely interact. The one with real behaviour
/// is [Chip] - activatable, deletable, focusable - and it follows the full
/// control contract (`control.dart`); the others are leaves that publish a
/// sensible semantic node and take their colours from the theme.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/color.dart';
import '../graphics/display_list.dart';
import '../graphics/display_list_geometry.dart';
import '../layout/edge_insets.dart';
import '../layout/render_box.dart';
import '../platform/input_events.dart';
import 'control.dart';
import 'element.dart';
import 'focus.dart';
import 'focus_scope.dart';
import 'semantics.dart';
import 'style.dart';
import 'theme.dart';
import 'widget.dart';

// ---------------------------------------------------------------------------
// Badge
// ---------------------------------------------------------------------------

/// A small pill: a count or a status word. Pure display.
final class Badge extends StatelessWidget {
  const Badge({super.key, required this.label, this.color});

  final String label;

  /// The fill; defaults to the theme accent.
  final Color? color;

  @override
  Widget build(BuildContext context) => _BadgeRenderWidget(
        label: label,
        color: color,
        theme: Theme.of(context),
      );
}

final class _BadgeRenderWidget extends RenderObjectWidget {
  const _BadgeRenderWidget({
    required this.label,
    required this.color,
    required this.theme,
  });

  final String label;
  final Color? color;
  final ThemeData theme;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderBadge createRenderObject(BuildContext context) => RenderBadge()
    ..label = label
    ..color = color
    ..theme = theme;

  @override
  void updateRenderObject(BuildContext context, covariant RenderBadge object) {
    object
      ..label = label
      ..color = color
      ..theme = theme;
  }
}

final class RenderBadge extends RenderBox with ControlBehavior {
  String _label = '';
  Color? _color;

  String get label => _label;

  set label(String value) {
    if (value == _label) return;
    _label = value;
    markNeedsLayout();
  }

  Color? get color => _color;

  set color(Color? value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  @override
  bool get focusOnPointerDown => false;

  double get _height => labelLineHeight + 4;

  @override
  void performLayout() => size = constraints.constrain(
        Size(measureLabel(_label).width + _height, _height),
      );

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      size.width,
      size.height,
    );
    final Color fill = _color ?? theme.accent;
    paintRoundedFill(list, rect, fill, rect.height / 2);
    paintCenteredLabel(list, _label, rect, theme.colorScheme.onPrimary);
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.text,
        label: _label,
        mergesDescendants: true,
      );
}

// ---------------------------------------------------------------------------
// Chip
// ---------------------------------------------------------------------------

/// A tag: a rounded label that can be selected and deleted.
///
/// Interactive when [onPressed] or [onDeleted] is given: one tab stop,
/// Enter/Space activates, Delete or Backspace removes. A chip with neither
/// callback is a passive tag and takes no focus.
final class Chip extends StatefulWidget {
  const Chip({
    super.key,
    required this.label,
    this.selected = false,
    this.onPressed,
    this.onDeleted,
  });

  final String label;
  final bool selected;
  final void Function()? onPressed;

  /// Shows the delete glyph and enables Delete/Backspace when non-null.
  final void Function()? onDeleted;

  @override
  State<Chip> createState() => _ChipState();
}

final class _ChipState extends State<Chip> {
  late final FocusNode _focusNode = FocusNode(debugLabel: 'Chip');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FocusAttachment(
        node: _focusNode,
        child: _ChipRenderWidget(
          label: widget.label,
          selected: widget.selected,
          onPressed: widget.onPressed,
          onDeleted: widget.onDeleted,
          theme: Theme.of(context),
          focusNode: _focusNode,
        ),
      );
}

final class _ChipRenderWidget extends RenderObjectWidget {
  const _ChipRenderWidget({
    required this.label,
    required this.selected,
    required this.onPressed,
    required this.onDeleted,
    required this.theme,
    required this.focusNode,
  });

  final String label;
  final bool selected;
  final void Function()? onPressed;
  final void Function()? onDeleted;
  final ThemeData theme;
  final FocusNode focusNode;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderChip createRenderObject(BuildContext context) => RenderChip()
    ..label = label
    ..selected = selected
    ..onPressed = onPressed
    ..onDeleted = onDeleted
    ..theme = theme
    ..focusNode = focusNode
    ..enabled = onPressed != null || onDeleted != null;

  @override
  void updateRenderObject(BuildContext context, covariant RenderChip object) {
    object
      ..label = label
      ..selected = selected
      ..onPressed = onPressed
      ..onDeleted = onDeleted
      ..theme = theme
      ..focusNode = focusNode
      ..enabled = onPressed != null || onDeleted != null;
  }
}

final class RenderChip extends RenderBox with ControlBehavior {
  /// The width the delete glyph owns at the end, when one is shown.
  static const double deleteExtent = 16;

  String _label = '';
  bool _selected = false;
  void Function()? onPressed;
  void Function()? _onDeleted;

  String get label => _label;

  set label(String value) {
    if (value == _label) return;
    _label = value;
    markNeedsLayout();
  }

  bool get selected => _selected;

  set selected(bool value) {
    if (value == _selected) return;
    _selected = value;
    markNeedsPaint();
  }

  void Function()? get onDeleted => _onDeleted;

  set onDeleted(void Function()? value) {
    final bool had = _onDeleted != null;
    _onDeleted = value;
    if (had != (value != null)) markNeedsLayout();
  }

  @override
  Set<PseudoClass> get controlStates => <PseudoClass>{
        if (_selected) PseudoClass.selected,
      };

  double get _height => labelLineHeight + 8;

  double get _deleteWidth => _onDeleted == null ? 0 : deleteExtent;

  Rect get _deleteRect => Rect.fromLTWH(
        size.width - _deleteWidth - 4,
        0,
        _deleteWidth + 4,
        size.height,
      );

  @override
  void performLayout() => size = constraints.constrain(
        Size(measureLabel(_label).width + 16 + _deleteWidth, _height),
      );

  @override
  bool hitTestSelf(Offset position) => true;

  bool _pressOnDelete = false;

  @override
  void handlePointerEvent(PointerEvent event) {
    if (event is PointerDownEvent && event.button == PointerButton.primary) {
      _pressOnDelete = _onDeleted != null &&
          _deleteRect.contains(globalToLocal(event.logicalPosition));
    }
    super.handlePointerEvent(event);
  }

  @override
  void activate() {
    if (_pressOnDelete) {
      _pressOnDelete = false;
      _onDeleted?.call();
    } else {
      onPressed?.call();
    }
  }

  @override
  bool handleKeyEvent(KeyEvent event) {
    if (enabled &&
        event is KeyDownEvent &&
        (event.logicalKey == logicalKeyDelete ||
            event.logicalKey == logicalKeyBackspace) &&
        _onDeleted != null) {
      _onDeleted!.call();
      return true;
    }
    return super.handleKeyEvent(event);
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      size.width,
      size.height,
    );
    final Color fill = _selected
        ? theme.selection
        : isHovered && enabled
            ? theme.surface
            : theme.surfaceAlternate;
    paintRoundedFill(list, rect, fill, rect.height / 2);
    paintRoundedBorder(list, rect, theme.border, rect.height / 2);
    paintCenteredLabel(
      list,
      _label,
      Rect.fromLTWH(rect.left, rect.top, rect.width - _deleteWidth,
          rect.height),
      enabled ? theme.foreground : theme.disabledForeground,
    );
    if (_onDeleted != null) {
      _paintDeleteGlyph(
        list,
        Offset(
          rect.left + rect.width - _deleteWidth / 2 - 4,
          rect.top + rect.height / 2,
        ),
      );
    }
    paintFocusRing(list, rect);
  }

  /// A pixel-art multiplication sign: two diagonals of one-pixel dots.
  void _paintDeleteGlyph(DisplayList list, Offset center) {
    final int paint = list.addPaint(
      colorArgb:
          (enabled ? theme.foregroundSecondary : theme.disabledForeground)
              .value,
      antiAlias: false,
    );
    for (int i = -3; i <= 3; i++) {
      list
        ..drawRectangle(
          Rect.fromLTWH(
            (center.dx + i).roundToDouble(),
            (center.dy + i).roundToDouble(),
            1,
            1,
          ),
          paint,
        )
        ..drawRectangle(
          Rect.fromLTWH(
            (center.dx + i).roundToDouble(),
            (center.dy - i).roundToDouble(),
            1,
            1,
          ),
          paint,
        );
    }
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.button,
        label: _label,
        states: <SemanticsState>{
          if (_selected) SemanticsState.selected,
          if (!enabled) SemanticsState.disabled,
          if (hasFocus) SemanticsState.focused,
        },
        actions: enabled
            ? <SemanticsAction>{
                SemanticsAction.activate,
                if (_onDeleted != null) SemanticsAction.dismiss,
                SemanticsAction.focus,
              }
            : const <SemanticsAction>{},
        mergesDescendants: true,
      );
}

// ---------------------------------------------------------------------------
// Avatar
// ---------------------------------------------------------------------------

/// A circle with initials: the person-shaped placeholder every list of
/// people needs.
final class Avatar extends StatelessWidget {
  const Avatar({
    super.key,
    required this.initials,
    this.size = 32,
    this.color,
    this.semanticsLabel,
  });

  /// One or two characters shown in the circle.
  final String initials;

  final double size;
  final Color? color;

  /// What a screen reader hears; defaults to the initials.
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) => _AvatarRenderWidget(
        initials: initials,
        diameter: size,
        color: color,
        semanticsLabel: semanticsLabel ?? initials,
        theme: Theme.of(context),
      );
}

final class _AvatarRenderWidget extends RenderObjectWidget {
  const _AvatarRenderWidget({
    required this.initials,
    required this.diameter,
    required this.color,
    required this.semanticsLabel,
    required this.theme,
  });

  final String initials;
  final double diameter;
  final Color? color;
  final String semanticsLabel;
  final ThemeData theme;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderAvatar createRenderObject(BuildContext context) => RenderAvatar()
    ..initials = initials
    ..diameter = diameter
    ..color = color
    ..semanticsLabel = semanticsLabel
    ..theme = theme;

  @override
  void updateRenderObject(BuildContext context, covariant RenderAvatar object) {
    object
      ..initials = initials
      ..diameter = diameter
      ..color = color
      ..semanticsLabel = semanticsLabel
      ..theme = theme;
  }
}

final class RenderAvatar extends RenderBox with ControlBehavior {
  String _initials = '';
  double _diameter = 32;
  Color? _color;
  String semanticsLabel = '';

  String get initials => _initials;

  set initials(String value) {
    if (value == _initials) return;
    _initials = value;
    markNeedsPaint();
  }

  double get diameter => _diameter;

  set diameter(double value) {
    if (value == _diameter) return;
    _diameter = value;
    markNeedsLayout();
  }

  Color? get color => _color;

  set color(Color? value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  @override
  bool get focusOnPointerDown => false;

  @override
  void performLayout() =>
      size = constraints.constrain(Size(_diameter, _diameter));

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      size.width,
      size.height,
    );
    // A circle is a rounded rect whose radius is half its side.
    paintRoundedFill(list, rect, _color ?? theme.accent, rect.width / 2);
    paintCenteredLabel(list, _initials, rect, theme.colorScheme.onPrimary);
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.image,
        label: semanticsLabel,
        mergesDescendants: true,
      );
}

// ---------------------------------------------------------------------------
// Card
// ---------------------------------------------------------------------------

/// A rounded, bordered surface for grouping content.
final class Card extends StatelessWidget {
  const Card({super.key, required this.child, this.padding = 12});

  final Widget child;
  final double padding;

  @override
  Widget build(BuildContext context) => _CardRenderWidget(
        padding: padding,
        theme: Theme.of(context),
        child: child,
      );
}

final class _CardRenderWidget extends SingleChildRenderObjectWidget {
  const _CardRenderWidget({
    required this.padding,
    required this.theme,
    required Widget child,
  }) : super(child: child);

  final double padding;
  final ThemeData theme;

  @override
  RenderCard createRenderObject(BuildContext context) => RenderCard()
    ..padding = padding
    ..theme = theme;

  @override
  void updateRenderObject(BuildContext context, covariant RenderCard object) {
    object
      ..padding = padding
      ..theme = theme;
  }
}

final class RenderCard extends RenderSingleChildBox with ControlBehavior {
  double _padding = 12;

  double get padding => _padding;

  set padding(double value) {
    if (value == _padding) return;
    _padding = value;
    markNeedsLayout();
  }

  @override
  bool get focusOnPointerDown => false;

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.constrain(Size(_padding * 2, _padding * 2));
      return;
    }
    child.layout(
      constraints.deflate(EdgeInsets.all(_padding)),
      parentUsesSize: true,
    );
    child.parentData!.offset = Offset(_padding, _padding);
    size = constraints.constrain(Size(
      child.size.width + _padding * 2,
      child.size.height + _padding * 2,
    ));
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      size.width,
      size.height,
    );
    paintRoundedFill(list, rect, theme.surfaceAlternate, theme.cornerRadius);
    paintRoundedBorder(list, rect, theme.border, theme.cornerRadius);
    super.paint(list, offset);
  }

  @override
  SemanticsConfiguration describeSemantics() => const SemanticsConfiguration(
        // A card is grouping, not meaning: it exists so its children read as
        // one cluster, and it says nothing about itself.
        role: SemanticsRole.generic,
      );
}
