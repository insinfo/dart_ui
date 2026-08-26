/// An expander: a header that opens and closes a panel underneath it.
///
/// Small control, two properties that are easy to get wrong and both of them
/// visible to a user who never sees the animation:
///
///   * **Collapsed content does not exist.** Not hidden, not zero-height, not
///     clipped away - not built. A panel whose widgets are still in the tree
///     keeps its focus nodes in the traversal ring, and Tab then moves the
///     keyboard into a control nobody can see. That is an accessibility defect
///     rather than a cosmetic one: the user has no way to know where focus
///     went, and no way to get it back except by tabbing blindly onward.
///   * **The reveal clips; it does not re-lay-out.** The content is laid out at
///     its full height on every frame of the animation and the *box around it*
///     grows, so nothing reflows as the panel opens. Animating the height the
///     content is given instead would re-wrap every paragraph in it sixty times
///     a second, and text would visibly jump as the last line found room.
///
/// The clip is [ClipRect] from `proxy.dart` rather than a second implementation
/// of clipping: the body sizes itself to a fraction of its child, and a clip
/// that cuts to *its own box* is then exactly the right tool - it also makes
/// the hidden half unhittable, because [ClipRect] clips paint and hit testing
/// to the same rectangle.
library;

import '../animation/animation.dart';
import '../animation/clock.dart';
import '../animation/curves.dart';
import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/display_list.dart';
import '../layout/box_constraints.dart';
import '../layout/render_box.dart';
import '../platform/input_events.dart';
import '../semantics/semantics.dart';
import '../text/shaper.dart' show TextDirection;
import 'basic.dart';
import 'control.dart';
import 'directionality.dart';
import 'element.dart';
import 'focus.dart';
import 'focus_scope.dart';
import 'proxy.dart';
import 'style.dart';
import 'theme.dart';
import 'widget.dart';

/// A header that reveals a panel.
///
/// Controlled: it shows [expanded] and reports intent through
/// [onExpandedChanged], so a group of expanders that must behave like an
/// accordion is a caller's `setState` rather than a mode inside this widget.
final class Expander extends StatefulWidget {
  const Expander({
    super.key,
    required this.header,
    required this.content,
    required this.expanded,
    this.onExpandedChanged,
    this.clock,
    this.duration = const Duration(milliseconds: 200),
    this.contentIndent = 16.0,
  });

  /// The header's text. It is also the accessible name.
  final String header;

  /// Built only while the panel is open or closing.
  final Widget content;

  final bool expanded;

  /// Called with the state the user asked for. Null disables the control.
  final void Function(bool expanded)? onExpandedChanged;

  /// The clock the reveal is driven by; null means it snaps open and shut.
  ///
  /// There is no ambient clock to fall back on, by design - see
  /// `animation/clock.dart`.
  final AnimationClock? clock;

  final Duration duration;

  /// How far the content is inset from the reading direction's start edge, so
  /// it reads as belonging to the header above it.
  final double contentIndent;

  @override
  State<Expander> createState() => _ExpanderState();
}

final class _ExpanderState extends State<Expander> {
  late final FocusNode _focusNode = FocusNode(debugLabel: 'Expander');
  AnimationController? _controller;

  @override
  void initState() {
    super.initState();
    final AnimationClock? clock = widget.clock;
    if (clock != null) {
      _controller = AnimationController(
        clock: clock,
        duration: widget.duration,
        initialValue: widget.expanded ? 1 : 0,
      )..addListener(_onTick);
    }
  }

  @override
  void didUpdateWidget(Expander oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded == oldWidget.expanded) return;
    final AnimationController? controller = _controller;
    if (controller == null) return;
    if (widget.expanded) {
      controller.forward();
    } else {
      controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller
      ?..removeListener(_onTick)
      ..dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  /// How much of the panel is showing, 0 to 1.
  double get _factor {
    final AnimationController? controller = _controller;
    if (controller == null || Theme.of(context).reducedMotion) {
      return widget.expanded ? 1 : 0;
    }
    return Curves.easeInOut.transform(controller.value);
  }

  void _toggle() => widget.onExpandedChanged?.call(!widget.expanded);

  bool _handleKey(KeyEvent event, TextDirection direction) {
    if (event is! KeyDownEvent) return false;
    final bool rtl = direction.isRightToLeft;
    // The arrow that points *away* from the header's start edge opens it, which
    // is right in a left-to-right locale and left in a right-to-left one. A
    // control that opened on the physical right key in every locale would be
    // asking a right-to-left user to press "collapse" to expand.
    final int open = rtl ? logicalKeyArrowLeft : logicalKeyArrowRight;
    final int close = rtl ? logicalKeyArrowRight : logicalKeyArrowLeft;
    if (event.logicalKey == open) {
      if (!widget.expanded) widget.onExpandedChanged?.call(true);
      return true;
    }
    if (event.logicalKey == close) {
      if (widget.expanded) widget.onExpandedChanged?.call(false);
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final TextDirection direction = Directionality.of(context);
    final double factor = _factor;
    return Column(
      children: <Widget>[
        FocusAttachment(
          node: _focusNode,
          child: _ExpanderHeaderWidget(
            label: widget.header,
            expanded: widget.expanded,
            theme: Theme.of(context),
            focusNode: _focusNode,
            textDirection: direction,
            enabled: widget.onExpandedChanged != null,
            onActivate: _toggle,
            onKeyEvent: (KeyEvent event) => _handleKey(event, direction),
          ),
        ),
        // Nothing at all when the panel is shut: see the library comment. The
        // `factor > 0` test is what makes that true at the *end* of a collapse
        // animation as well as before it starts.
        if (factor > 0)
          ClipRect(
            child: _ExpanderBodyWidget(
              factor: factor,
              indent: widget.contentIndent,
              textDirection: direction,
              child: widget.content,
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// The header
// ---------------------------------------------------------------------------

final class _ExpanderHeaderWidget extends RenderObjectWidget {
  const _ExpanderHeaderWidget({
    required this.label,
    required this.expanded,
    required this.theme,
    required this.focusNode,
    required this.textDirection,
    required this.enabled,
    required this.onActivate,
    required this.onKeyEvent,
  });

  final String label;
  final bool expanded;
  final ThemeData theme;
  final FocusNode focusNode;
  final TextDirection textDirection;
  final bool enabled;
  final void Function() onActivate;
  final bool Function(KeyEvent event) onKeyEvent;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderExpanderHeader createRenderObject(BuildContext context) =>
      RenderExpanderHeader(label: label)
        ..expanded = expanded
        ..textDirection = textDirection
        ..onActivate = onActivate
        ..onKeyEvent = onKeyEvent
        ..theme = theme
        ..focusNode = focusNode
        ..enabled = enabled;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderExpanderHeader object,
  ) {
    object
      ..label = label
      ..expanded = expanded
      ..textDirection = textDirection
      ..onActivate = onActivate
      ..onKeyEvent = onKeyEvent
      ..theme = theme
      ..focusNode = focusNode
      ..enabled = enabled;
  }
}

/// The clickable header: a chevron that turns, and a label.
final class RenderExpanderHeader extends RenderBox with ControlBehavior {
  RenderExpanderHeader({required String label}) : _label = label;

  String _label;
  bool _expanded = false;
  TextDirection _textDirection = TextDirection.leftToRight;
  void Function()? onActivate;
  bool Function(KeyEvent event)? onKeyEvent;

  String get label => _label;

  set label(String value) {
    if (value == _label) return;
    _label = value;
    markNeedsLayout();
  }

  bool get expanded => _expanded;

  set expanded(bool value) {
    if (value == _expanded) return;
    _expanded = value;
    markNeedsPaint();
  }

  TextDirection get textDirection => _textDirection;

  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsPaint();
  }

  /// The width of the disclosure chevron's column.
  ///
  /// The same fraction the combo box uses, so the two chevrons in one window
  /// are the same drawing at the same size.
  double get chevronExtent =>
      (theme.effectiveControlHeight * 0.66).roundToDouble();

  @override
  Set<PseudoClass> get controlStates => <PseudoClass>{
        if (_expanded) PseudoClass.expanded,
      };

  @override
  void activate() => onActivate?.call();

  @override
  bool handleKeyEvent(KeyEvent event) {
    if (!enabled) return false;
    // The arrows first, then Space and Enter through [ControlBehavior]: an
    // expander answers both, and the two must not be two implementations of
    // "toggle".
    if (onKeyEvent?.call(event) ?? false) return true;
    return super.handleKeyEvent(event);
  }

  @override
  void performLayout() {
    final double width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : labelledSize(_label, extraWidth: chevronExtent).width;
    size = constraints.constrain(Size(width, theme.effectiveControlHeight));
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      size.width,
      size.height,
    );
    if (isPressed || isHovered) {
      paintRoundedFill(
        list,
        rect,
        isPressed ? theme.pressedSurface : theme.hoverSurface,
        theme.cornerRadius,
      );
    }
    final double padding = theme.effectiveControlPadding;
    final bool rtl = _textDirection.isRightToLeft;
    _paintChevron(
      list,
      Rect.fromLTWH(
        rtl ? rect.right - padding - chevronExtent : rect.left + padding,
        rect.top,
        chevronExtent,
        rect.height,
      ),
    );
    final Size box = measureLabel(_label);
    final double textStart = padding * 2 + chevronExtent;
    paintLabel(
      list,
      _label,
      Offset(
        rtl
            ? (rect.right - textStart - box.width).roundToDouble()
            : (rect.left + textStart).roundToDouble(),
        labelTopIn(rect),
      ),
      foregroundColor(),
      maxWidth: (rect.width - textStart - padding).clamp(0.0, double.infinity),
    );
    paintFocusRing(list, rect, radius: theme.cornerRadius);
  }

  /// A disclosure chevron: pointing along the reading direction when shut, and
  /// downward when open.
  ///
  /// Two mitred strokes rather than the solid triangle this drew before. The
  /// triangle is the mark a 1995 tree control used, and at 8 px it is a blob.
  void _paintChevron(DisplayList list, Rect box) {
    final double centreX = (box.left + box.width / 2).roundToDouble();
    final double centreY = (box.top + box.height / 2).roundToDouble();
    const double span = 3.5;
    final bool rtl = _textDirection.isRightToLeft;
    paintPolylineMark(
      list,
      _expanded
          ? <Offset>[
              Offset(centreX - span, centreY - span / 2),
              Offset(centreX, centreY + span / 2),
              Offset(centreX + span, centreY - span / 2),
            ]
          : rtl
              ? <Offset>[
                  Offset(centreX + span / 2, centreY - span),
                  Offset(centreX - span / 2, centreY),
                  Offset(centreX + span / 2, centreY + span),
                ]
              : <Offset>[
                  Offset(centreX - span / 2, centreY - span),
                  Offset(centreX + span / 2, centreY),
                  Offset(centreX - span / 2, centreY + span),
                ],
      1.5,
      enabled ? theme.foregroundSecondary : theme.disabledForeground,
    );
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.button,
        label: _label,
        states: <SemanticsState>{
          if (_expanded) SemanticsState.expanded,
          if (hasFocus) SemanticsState.focused,
          if (!enabled) SemanticsState.disabled,
        },
        actions: enabled
            ? const <SemanticsAction>{
                SemanticsAction.activate,
                SemanticsAction.focus,
              }
            : const <SemanticsAction>{},
        mergesDescendants: true,
      );
}

// ---------------------------------------------------------------------------
// The body
// ---------------------------------------------------------------------------

final class _ExpanderBodyWidget extends SingleChildRenderObjectWidget {
  const _ExpanderBodyWidget({
    required this.factor,
    required this.indent,
    required this.textDirection,
    required Widget child,
  }) : super(child: child);

  final double factor;
  final double indent;
  final TextDirection textDirection;

  @override
  RenderExpanderBody createRenderObject(BuildContext context) =>
      RenderExpanderBody(factor: factor)
        ..indent = indent
        ..textDirection = textDirection;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderExpanderBody object,
  ) {
    object
      ..factor = factor
      ..indent = indent
      ..textDirection = textDirection;
  }
}

/// A box that is a fraction of its child's height.
///
/// The child is laid out once, at its full height, and this node simply reports
/// less of it. Everything else - the clipping, the hit region - follows from
/// the [ClipRect] wrapped around it.
final class RenderExpanderBody extends RenderSingleChildBox {
  RenderExpanderBody({required double factor}) : _factor = factor;

  double _factor;
  double _indent = 0;
  TextDirection _textDirection = TextDirection.leftToRight;

  double get factor => _factor;

  set factor(double value) {
    if (value == _factor) return;
    _factor = value;
    markNeedsLayout();
  }

  double get indent => _indent;

  set indent(double value) {
    if (value == _indent) return;
    _indent = value;
    markNeedsLayout();
  }

  TextDirection get textDirection => _textDirection;

  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  /// The height the content actually has, whatever fraction of it is showing.
  double get contentHeight => child?.size.height ?? 0;

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.constrain(Size.zero);
      return;
    }
    final double width =
        (constraints.maxWidth.isFinite ? constraints.maxWidth : 0) - _indent;
    child.layout(
      BoxConstraints(
        minWidth: width.clamp(0.0, double.infinity),
        maxWidth: width.clamp(0.0, double.infinity),
      ),
      parentUsesSize: true,
    );
    child.parentData!.offset = Offset(
      _textDirection.isRightToLeft ? 0 : _indent,
      0,
    );
    size = constraints.constrain(
      Size(
        child.size.width + _indent,
        (child.size.height * _factor).clamp(0.0, child.size.height),
      ),
    );
  }
}
