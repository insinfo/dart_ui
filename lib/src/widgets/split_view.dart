/// A split view: two panels and a divider the user can drag between them.
///
/// The whole control is one arithmetic problem stated three ways - by a drag,
/// by an arrow key, and by the window being resized - and it has exactly one
/// answer, [RenderSplitView.resolveFirstExtent]. Everything that can move the
/// divider goes through it, which is what makes the guarantees below hold for
/// all three:
///
///   * neither panel is ever smaller than its minimum, and never negative. A
///     drag past the end *stops*; it does not invert the panels, and it does
///     not hand a render box a negative width to constrain;
///   * when the two minima do not fit at all - a window narrower than
///     `minFirst + minSecond + thickness` - the first panel gives way rather
///     than the layout throwing. Something has to lose, and the honest failure
///     is a squeezed panel rather than an exception in the middle of a resize;
///   * the divider is a real control: it takes focus, it has a keyboard, and it
///     reports itself to a screen reader as a slider, which is what it is.
///
/// ## Box
///
/// A split view fills the box it is given and divides it, so the axis it
/// splits along must be bounded. An unbounded main axis falls back to the
/// minimum constraint rather than growing without limit, which shows up as a
/// collapsed splitter instead of an exception thrown three layers away.
///
/// ## Direction
///
/// The first panel is on the reading direction's start side, so it is on the
/// *right* in a right-to-left locale, and dragging the divider left there makes
/// the first panel bigger. A splitter that ignored direction would put the
/// navigation pane of a right-to-left application on the wrong edge and then
/// resize it backwards.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/display_list.dart';
import '../layout/box_constraints.dart';
import '../layout/render_box.dart';
import '../layout/render_flex.dart' show Axis;
import '../platform/input_events.dart';
import '../semantics/semantics.dart';
import '../text/shaper.dart' show TextDirection;
import 'control.dart';
import 'directionality.dart';
import 'element.dart';
import 'focus.dart';
import 'focus_scope.dart';
import 'theme.dart';
import 'widget.dart';

/// Two panels with a draggable divider between them.
///
/// The position may be left to the widget (the common case - it starts at
/// [initialFraction] and remembers what the user dragged) or driven from
/// outside by passing [firstExtent], which makes it a controlled control like
/// every other value-bearing widget here.
final class SplitView extends StatefulWidget {
  const SplitView({
    super.key,
    required this.first,
    required this.second,
    this.axis = Axis.horizontal,
    this.firstExtent,
    this.initialFraction = 0.5,
    this.onResized,
    this.minFirst = 40.0,
    this.minSecond = 40.0,
    this.dividerThickness = 6.0,
    this.keyboardStep = 10.0,
  });

  final Widget first;
  final Widget second;

  /// Which way the panels are stacked. [Axis.horizontal] puts them side by
  /// side with a vertical divider.
  final Axis axis;

  /// The first panel's extent in logical pixels, or null to let the widget
  /// own it.
  final double? firstExtent;

  /// Where the divider starts when nothing has moved it yet.
  final double initialFraction;

  /// Called with the resolved - already clamped - extent whenever the user
  /// moves the divider.
  final void Function(double firstExtent)? onResized;

  final double minFirst;
  final double minSecond;
  final double dividerThickness;

  /// How far one arrow key moves the divider.
  final double keyboardStep;

  @override
  State<SplitView> createState() => _SplitViewState();
}

final class _SplitViewState extends State<SplitView> {
  late final FocusNode _focusNode = FocusNode(debugLabel: 'SplitViewDivider');
  double? _requested;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _onResized(double extent) {
    // Stored even when the caller is driving the position: a controlled
    // SplitView whose owner ignores the callback would otherwise drag as if
    // nothing had happened, and the *next* value the owner does send would
    // arrive on top of a stale one.
    setState(() => _requested = extent);
    widget.onResized?.call(extent);
  }

  @override
  Widget build(BuildContext context) => _SplitViewWidget(
        axis: widget.axis,
        textDirection: Directionality.of(context),
        requestedExtent: widget.firstExtent ?? _requested,
        initialFraction: widget.initialFraction,
        minFirst: widget.minFirst,
        minSecond: widget.minSecond,
        thickness: widget.dividerThickness,
        theme: Theme.of(context),
        children: <Widget>[
          widget.first,
          FocusAttachment(
            node: _focusNode,
            child: _SplitDividerWidget(
              axis: widget.axis,
              textDirection: Directionality.of(context),
              theme: Theme.of(context),
              focusNode: _focusNode,
              step: widget.keyboardStep,
              onResized: _onResized,
            ),
          ),
          widget.second,
        ],
      );
}

final class _SplitViewWidget extends MultiChildRenderObjectWidget {
  const _SplitViewWidget({
    required this.axis,
    required this.textDirection,
    required this.requestedExtent,
    required this.initialFraction,
    required this.minFirst,
    required this.minSecond,
    required this.thickness,
    required this.theme,
    required super.children,
  });

  final Axis axis;
  final TextDirection textDirection;
  final double? requestedExtent;
  final double initialFraction;
  final double minFirst;
  final double minSecond;
  final double thickness;
  final ThemeData theme;

  @override
  RenderSplitView createRenderObject(BuildContext context) => RenderSplitView()
    ..axis = axis
    ..textDirection = textDirection
    ..requestedExtent = requestedExtent
    ..initialFraction = initialFraction
    ..minFirst = minFirst
    ..minSecond = minSecond
    ..thickness = thickness
    ..theme = theme;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderSplitView object,
  ) {
    object
      ..axis = axis
      ..textDirection = textDirection
      ..requestedExtent = requestedExtent
      ..initialFraction = initialFraction
      ..minFirst = minFirst
      ..minSecond = minSecond
      ..thickness = thickness
      ..theme = theme;
  }
}

/// Lays out panel, divider, panel - and owns the clamping arithmetic.
final class RenderSplitView extends RenderBoxContainer<BoxParentData>
    with ControlBehavior {
  Axis _axis = Axis.horizontal;
  TextDirection _textDirection = TextDirection.leftToRight;
  double? _requestedExtent;
  double _initialFraction = 0.5;
  double _minFirst = 0;
  double _minSecond = 0;
  double _thickness = 6;
  double _firstExtent = 0;

  Axis get axis => _axis;

  set axis(Axis value) {
    if (value == _axis) return;
    _axis = value;
    markNeedsLayout();
  }

  TextDirection get textDirection => _textDirection;

  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  double? get requestedExtent => _requestedExtent;

  set requestedExtent(double? value) {
    if (value == _requestedExtent) return;
    _requestedExtent = value;
    markNeedsLayout();
  }

  double get initialFraction => _initialFraction;

  set initialFraction(double value) {
    if (value == _initialFraction) return;
    _initialFraction = value;
    markNeedsLayout();
  }

  double get minFirst => _minFirst;

  set minFirst(double value) {
    if (value == _minFirst) return;
    _minFirst = value;
    markNeedsLayout();
  }

  double get minSecond => _minSecond;

  set minSecond(double value) {
    if (value == _minSecond) return;
    _minSecond = value;
    markNeedsLayout();
  }

  double get thickness => _thickness;

  set thickness(double value) {
    if (value == _thickness) return;
    _thickness = value;
    markNeedsLayout();
  }

  /// The extent the first panel actually got, after clamping.
  double get firstExtent => _firstExtent;

  /// The extent the second panel actually got.
  double get secondExtent {
    final double total = _totalExtent;
    return (total - _thickness - _firstExtent).clamp(0.0, total);
  }

  double get _totalExtent {
    if (!hasSize) return 0;
    return _axis == Axis.horizontal ? size.width : size.height;
  }

  /// The largest the first panel may be, given the second one's minimum.
  ///
  /// Never below zero, and never below [minFirst] unless the box itself is too
  /// small to hold both minima - the "something has to lose" case in the
  /// library comment.
  double maxFirstExtent(double total) {
    final double room = total - _thickness - _minSecond;
    return room.clamp(0.0, total > _thickness ? total - _thickness : 0.0);
  }

  /// The one place a divider position is decided.
  ///
  /// [requested] is null before anything has moved the divider, which is when
  /// [initialFraction] applies.
  double resolveFirstExtent(double total, double? requested) {
    final double desired = requested ?? total * _initialFraction;
    final double upper = maxFirstExtent(total);
    final double lower = _minFirst.clamp(0.0, upper);
    if (desired.isNaN) return lower;
    return desired.clamp(lower, upper);
  }

  /// [extent] clamped into the range the current geometry allows.
  double clampExtent(double extent) => resolveFirstExtent(_totalExtent, extent);

  @override
  bool get focusOnPointerDown => false;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! BoxParentData) child.parentData = BoxParentData();
  }

  @override
  void performLayout() {
    final double width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : constraints.minWidth;
    final double height = constraints.hasBoundedHeight
        ? constraints.maxHeight
        : constraints.minHeight;
    size = constraints.constrain(Size(width, height));
    if (childCount < 3) {
      _firstExtent = 0;
      return;
    }

    final bool horizontal = _axis == Axis.horizontal;
    final double total = horizontal ? size.width : size.height;
    final double cross = horizontal ? size.height : size.width;
    _firstExtent = resolveFirstExtent(total, _requestedExtent);
    final double second =
        (total - _thickness - _firstExtent).clamp(0.0, double.infinity);

    void place(RenderBox child, double start, double extent) {
      child.layout(
        horizontal
            ? BoxConstraints.tight(Size(extent, cross))
            : BoxConstraints.tight(Size(cross, extent)),
        parentUsesSize: true,
      );
      // The first panel sits on the start side, which is the right-hand side
      // when the text runs right to left.
      final double offset = horizontal && _textDirection.isRightToLeft
          ? total - start - extent
          : start;
      child.parentData!.offset =
          horizontal ? Offset(offset, 0) : Offset(0, offset);
    }

    place(childAt(0), 0, _firstExtent);
    place(childAt(1), _firstExtent, _thickness);
    place(childAt(2), _firstExtent + _thickness, second);
  }

  /// Where the divider is, in this node's coordinates.
  Rect get dividerRect {
    if (childCount < 3) return const Rect.fromLTWH(0, 0, 0, 0);
    final RenderBox divider = childAt(1);
    final Offset offset = divider.offsetFromParent;
    return Rect.fromLTWH(
      offset.dx,
      offset.dy,
      divider.size.width,
      divider.size.height,
    );
  }

  @override
  SemanticsConfiguration describeSemantics() => const SemanticsConfiguration(
        role: SemanticsRole.generic,
      );
}

// ---------------------------------------------------------------------------
// The divider
// ---------------------------------------------------------------------------

final class _SplitDividerWidget extends RenderObjectWidget {
  const _SplitDividerWidget({
    required this.axis,
    required this.textDirection,
    required this.theme,
    required this.focusNode,
    required this.step,
    required this.onResized,
  });

  final Axis axis;
  final TextDirection textDirection;
  final ThemeData theme;
  final FocusNode focusNode;
  final double step;
  final void Function(double extent) onResized;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderSplitDivider createRenderObject(BuildContext context) =>
      RenderSplitDivider()
        ..axis = axis
        ..textDirection = textDirection
        ..step = step
        ..onResized = onResized
        ..theme = theme
        ..focusNode = focusNode;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderSplitDivider object,
  ) {
    object
      ..axis = axis
      ..textDirection = textDirection
      ..step = step
      ..onResized = onResized
      ..theme = theme
      ..focusNode = focusNode;
  }
}

/// The grab handle: a drag, a keyboard, and a slider to a screen reader.
final class RenderSplitDivider extends RenderBox with ControlBehavior {
  Axis axis = Axis.horizontal;
  TextDirection textDirection = TextDirection.leftToRight;
  double step = 10;
  void Function(double extent)? onResized;

  double? _dragOrigin;
  double _extentAtDragStart = 0;

  /// The split this divider belongs to, or null while it is being moved
  /// between trees.
  RenderSplitView? get split {
    final RenderBox? parent = this.parent;
    return parent is RenderSplitView ? parent : null;
  }

  /// Whether a drag is in progress. A test asserts on it because "the divider
  /// is being dragged" and "the divider happens to be under the pointer" are
  /// different states with the same appearance.
  bool get isDragging => _dragOrigin != null;

  @override
  void performLayout() => size = constraints.constrain(constraints.biggest);

  @override
  bool hitTestSelf(Offset position) => true;

  double _coordinate(Offset position) =>
      axis == Axis.horizontal ? position.dx : position.dy;

  /// A pointer movement of [delta] logical pixels, as a *change in the first
  /// panel's extent*.
  ///
  /// The sign flips for a right-to-left horizontal split, where the first
  /// panel is on the right: dragging the divider leftward makes it bigger.
  double _asExtentDelta(double delta) =>
      axis == Axis.horizontal && textDirection.isRightToLeft ? -delta : delta;

  @override
  void handlePointerEvent(PointerEvent event) {
    super.handlePointerEvent(event);
    if (!enabled) return;
    final RenderSplitView? split = this.split;
    if (split == null) return;
    switch (event) {
      case PointerDownEvent(button: PointerButton.primary):
        _dragOrigin = _coordinate(event.logicalPosition);
        _extentAtDragStart = split.firstExtent;
      case PointerMoveEvent():
        final double? origin = _dragOrigin;
        if (origin == null) return;
        final double delta =
            _asExtentDelta(_coordinate(event.logicalPosition) - origin);
        onResized?.call(split.clampExtent(_extentAtDragStart + delta));
      case PointerUpEvent():
      case PointerCancelEvent():
        _dragOrigin = null;
      case PointerDownEvent():
      case PointerScrollEvent():
    }
  }

  @override
  bool handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent || !enabled) return false;
    final RenderSplitView? split = this.split;
    if (split == null) return false;
    final bool horizontal = axis == Axis.horizontal;
    final double current = split.firstExtent;
    final double total = horizontal ? split.size.width : split.size.height;
    switch (event.logicalKey) {
      case logicalKeyArrowRight when horizontal:
        _apply(split, current + _asExtentDelta(step));
        return true;
      case logicalKeyArrowLeft when horizontal:
        _apply(split, current - _asExtentDelta(step));
        return true;
      case logicalKeyArrowDown when !horizontal:
        _apply(split, current + step);
        return true;
      case logicalKeyArrowUp when !horizontal:
        _apply(split, current - step);
        return true;
      case logicalKeyHome:
        _apply(split, 0);
        return true;
      case logicalKeyEnd:
        _apply(split, total);
        return true;
    }
    return false;
  }

  void _apply(RenderSplitView split, double extent) =>
      onResized?.call(split.clampExtent(extent));

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      size.width,
      size.height,
    );
    // At rest the divider is one hairline down the middle of its grab strip,
    // not a filled slab: 6 px of grey between two panels is the sash of a 1995
    // window manager, and the strip still has to be 6 px wide to be aimable.
    final bool active = isPressed || isDragging || isHovered;
    if (active) {
      paintRoundedFill(
        list,
        rect,
        isPressed || isDragging ? theme.accent : theme.accentHovered,
        rect.width < rect.height ? rect.width / 2 : rect.height / 2,
      );
    } else {
      final bool vertical = rect.height >= rect.width;
      paintFill(
        list,
        vertical
            ? Rect.fromLTWH(
                (rect.left + rect.width / 2 - 0.5).roundToDouble(),
                rect.top,
                1,
                rect.height,
              )
            : Rect.fromLTWH(
                rect.left,
                (rect.top + rect.height / 2 - 0.5).roundToDouble(),
                rect.width,
                1,
              ),
        theme.border,
      );
    }
    paintFocusRing(list, rect, radius: theme.cornerRadiusSmall);
  }

  @override
  SemanticsConfiguration describeSemantics() {
    final RenderSplitView? split = this.split;
    final double extent = split?.firstExtent ?? 0;
    final double total =
        split == null ? 0 : (extent + (split.thickness) + split.secondExtent);
    return SemanticsConfiguration(
      // A splitter *is* a slider: one value, a range, and increment and
      // decrement. Announcing it as anything else would leave a screen-reader
      // user with a control they cannot operate.
      role: SemanticsRole.slider,
      label: 'split position',
      value: '${extent.round()} of ${total.round()}',
      increasedValue: split == null
          ? null
          : '${split.clampExtent(extent + step).round()} of ${total.round()}',
      decreasedValue: split == null
          ? null
          : '${split.clampExtent(extent - step).round()} of ${total.round()}',
      states: <SemanticsState>{
        if (hasFocus) SemanticsState.focused,
        if (!enabled) SemanticsState.disabled,
      },
      actions: const <SemanticsAction>{
        SemanticsAction.focus,
        SemanticsAction.increment,
        SemanticsAction.decrement,
      },
    );
  }
}
