/// Tabs: a strip of headers over one panel of content.
///
/// The control a preferences window is made of, and the one whose keyboard
/// contract is most often got wrong. Three properties are worth stating before
/// the code, because each is a bug when it is missing:
///
///   * **The strip is one tab stop, not one per tab.** Tab moves *into* the
///     strip and then out of it again; the arrow keys move between the headers.
///     A strip of eight tabs that answered Tab eight times would put seven
///     stops between a user and the next control, which is the difference
///     between a keyboard-usable window and a keyboard-hostile one. This falls
///     out of the design here: the strip owns one [FocusNode] and the headers
///     own none.
///   * **Only the selected panel exists.** The unselected tabs' content is not
///     built, so it holds no focus nodes, no scroll positions and no state that
///     could be reached by Tab from a panel the user cannot see.
///   * **A removed tab hands its selection to a neighbour.** See
///     [_TabsState.didUpdateWidget]: the selection follows the *identity* of the
///     tab that had it, and falls back to the nearest surviving index when that
///     tab is gone. An index left pointing past the end is how a tab control
///     ends up showing nothing at all.
///
/// ## Box
///
/// [Tabs] fills the box it is given: the strip takes its own height and the
/// panel takes the rest, so it needs a *bounded* height - it is a page, and a
/// page inside a scrolling column of unbounded height has no "rest" to take.
///
/// ## Direction
///
/// Headers are laid out from the reading direction's start edge, so the first
/// tab is on the right in a right-to-left locale, and the arrow keys follow the
/// *visual* order: right-arrow moves to whatever is drawn to the right. The
/// indicator slides between the two positions it is actually drawn at, which is
/// why it needs no direction of its own.
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
import 'style.dart';
import 'theme.dart';
import 'widget.dart';

/// One tab: a header and the panel it shows.
final class TabItem {
  const TabItem({
    required this.label,
    required this.content,
    this.id,
    this.enabled = true,
  });

  final String label;

  /// Built only while this tab is the selected one.
  final Widget content;

  /// What this tab *is*, across rebuilds in which the list changed.
  ///
  /// Defaults to the label. It is what makes "the tab before the selected one
  /// was closed" keep the same panel open instead of sliding the selection onto
  /// whatever moved into that index.
  final Object? id;

  final bool enabled;

  Object get identity => id ?? label;
}

/// A strip of tab headers over the selected tab's content.
///
/// Controlled: the widget shows [selectedIndex] and reports intent through
/// [onSelected].
final class Tabs extends StatefulWidget {
  const Tabs({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    this.onSelected,
    this.clock,
    this.indicatorDuration = const Duration(milliseconds: 150),
  });

  final List<TabItem> tabs;

  /// Which tab is showing. Out-of-range values are clamped onto a real tab and
  /// reported back through [onSelected]; see [_TabsState.didUpdateWidget].
  final int selectedIndex;

  final void Function(int index)? onSelected;

  /// The clock the indicator's slide is driven by.
  ///
  /// Null means no animation at all: the indicator jumps to the selected tab.
  /// There is no ambient clock to fall back on and none will be invented here -
  /// `animation/clock.dart` explains why a framework that reads the wall clock
  /// stops being testable.
  final AnimationClock? clock;

  final Duration indicatorDuration;

  @override
  State<Tabs> createState() => _TabsState();
}

final class _TabsState extends State<Tabs> {
  late final FocusNode _focusNode = FocusNode(debugLabel: 'Tabs');
  AnimationController? _controller;

  /// Where the indicator is sliding *from*, as a tab index.
  int _from = -1;

  @override
  void initState() {
    super.initState();
    final AnimationClock? clock = widget.clock;
    if (clock != null) {
      _controller = AnimationController(
        clock: clock,
        duration: widget.indicatorDuration,
        initialValue: 1,
      )..addListener(_onTick);
    }
    _from = _effectiveIndex;
  }

  @override
  void didUpdateWidget(Tabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    _reconcileSelection(oldWidget);
    if (_effectiveIndexOf(oldWidget) != _effectiveIndex) {
      _from = _effectiveIndexOf(oldWidget);
      final AnimationController? controller = _controller;
      if (controller != null) controller.forward(from: 0);
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

  /// Keeps the selection on a real tab when the *list* changed underneath it.
  ///
  /// Three cases, in the order they are decided:
  ///
  ///  1. the caller moved the selection itself - nothing to reconcile, because
  ///     an index the caller just chose is the one it wants;
  ///  2. the selected tab still exists, at whatever index - the selection
  ///     follows it, so closing the *first* tab while the second is open leaves
  ///     the second one open rather than switching to it by index;
  ///  3. the selected tab is gone - the nearest surviving index takes it, which
  ///     is the neighbour that moved into its place, or the new last tab when
  ///     the removed one was at the end.
  void _reconcileSelection(Tabs oldWidget) {
    if (widget.selectedIndex != oldWidget.selectedIndex) return;
    if (identical(widget.tabs, oldWidget.tabs)) return;
    // Nothing left to select, and nothing to report: a caller told there is no
    // valid index would have to invent one.
    if (widget.tabs.isEmpty) return;
    final int previous = _effectiveIndexOf(oldWidget);
    if (previous < 0) return;
    final Object identity = oldWidget.tabs[previous].identity;
    final int moved = widget.tabs.indexWhere(
      (TabItem tab) => tab.identity == identity,
    );
    final int target =
        moved >= 0 ? moved : previous.clamp(0, widget.tabs.length - 1);
    if (target == widget.selectedIndex) return;
    // Reported rather than merely rendered: the caller owns the index, and a
    // control that quietly showed a different tab from the one its owner
    // believes is selected is a bug that surfaces on the next rebuild.
    widget.onSelected?.call(target);
  }

  int _effectiveIndexOf(Tabs configuration) {
    if (configuration.tabs.isEmpty) return -1;
    return configuration.selectedIndex.clamp(0, configuration.tabs.length - 1);
  }

  int get _effectiveIndex => _effectiveIndexOf(widget);

  double get _progress {
    if (widget.tabs.isEmpty) return 1;
    final AnimationController? controller = _controller;
    if (controller == null) return 1;
    if (Theme.of(context).reducedMotion) return 1;
    return Curves.easeOut.transform(controller.value);
  }

  void _select(int index) {
    if (index < 0 || index >= widget.tabs.length) return;
    if (!widget.tabs[index].enabled) return;
    if (index == _effectiveIndex) return;
    widget.onSelected?.call(index);
  }

  /// Moves the selection [delta] tabs, skipping disabled ones and stopping at
  /// the ends.
  ///
  /// Stopping rather than wrapping: a tab strip is a row of pages, and wrapping
  /// from the last page to the first on one more arrow press is a jump the user
  /// did not ask for. (A menu wraps; a menu is a list of commands.)
  void _move(int delta) {
    int index = _effectiveIndex;
    for (int step = 0; step < widget.tabs.length; step++) {
      index += delta;
      if (index < 0 || index >= widget.tabs.length) return;
      if (widget.tabs[index].enabled) {
        _select(index);
        return;
      }
    }
  }

  void _moveToEnd(int direction) {
    if (direction > 0) {
      for (int i = widget.tabs.length - 1; i >= 0; i--) {
        if (widget.tabs[i].enabled) return _select(i);
      }
      return;
    }
    for (int i = 0; i < widget.tabs.length; i++) {
      if (widget.tabs[i].enabled) return _select(i);
    }
  }

  bool _handleKey(KeyEvent event, TextDirection direction) {
    if (event is! KeyDownEvent) return false;
    final bool rtl = direction.isRightToLeft;
    switch (event.logicalKey) {
      case logicalKeyArrowRight:
        _move(rtl ? -1 : 1);
        return true;
      case logicalKeyArrowLeft:
        _move(rtl ? 1 : -1);
        return true;
      case logicalKeyArrowDown:
        _move(1);
        return true;
      case logicalKeyArrowUp:
        _move(-1);
        return true;
      case logicalKeyHome:
        _moveToEnd(-1);
        return true;
      case logicalKeyEnd:
        _moveToEnd(1);
        return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final TextDirection direction = Directionality.of(context);
    final int selected = _effectiveIndex;
    final Widget strip = FocusAttachment(
      node: _focusNode,
      child: _TabStripWidget(
        theme: Theme.of(context),
        focusNode: _focusNode,
        textDirection: direction,
        selectedIndex: selected,
        previousIndex: _from,
        progress: _progress,
        onKeyEvent: (KeyEvent event) => _handleKey(event, direction),
        children: <Widget>[
          for (int i = 0; i < widget.tabs.length; i++)
            _TabHeaderWidget(
              key: ValueKey<Object>(widget.tabs[i].identity),
              label: widget.tabs[i].label,
              index: i,
              count: widget.tabs.length,
              selected: i == selected,
              enabled: widget.tabs[i].enabled && widget.onSelected != null,
              theme: Theme.of(context),
              onActivate: () {
                _focusNode.requestFocus(FocusChangeReason.pointer);
                _select(i);
              },
            ),
        ],
      ),
    );
    return Column(
      children: <Widget>[
        strip,
        Expanded(
          child: _TabPanelWidget(
            label: selected < 0 ? null : widget.tabs[selected].label,
            // Keyed by the tab's identity so switching tabs replaces the panel
            // instead of updating it: two tabs' contents are unrelated trees,
            // and reconciling one onto the other would hand the new panel the
            // old one's state.
            child: selected < 0
                ? const SizedBox()
                : _TabPanelContent(
                    key: ValueKey<Object>(widget.tabs[selected].identity),
                    child: widget.tabs[selected].content,
                  ),
          ),
        ),
      ],
    );
  }
}

/// Identity for the selected panel. A [StatelessWidget] purely so the key can
/// live on something that survives being handed a different child.
final class _TabPanelContent extends StatelessWidget {
  const _TabPanelContent({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

// ---------------------------------------------------------------------------
// The strip
// ---------------------------------------------------------------------------

final class _TabStripWidget extends MultiChildRenderObjectWidget {
  const _TabStripWidget({
    required this.theme,
    required this.focusNode,
    required this.textDirection,
    required this.selectedIndex,
    required this.previousIndex,
    required this.progress,
    required this.onKeyEvent,
    required super.children,
  });

  final ThemeData theme;
  final FocusNode focusNode;
  final TextDirection textDirection;
  final int selectedIndex;
  final int previousIndex;
  final double progress;
  final bool Function(KeyEvent event) onKeyEvent;

  @override
  RenderTabStrip createRenderObject(BuildContext context) => RenderTabStrip()
    ..textDirection = textDirection
    ..selectedIndex = selectedIndex
    ..previousIndex = previousIndex
    ..progress = progress
    ..onKeyEvent = onKeyEvent
    ..theme = theme
    ..focusNode = focusNode;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderTabStrip object,
  ) {
    object
      ..textDirection = textDirection
      ..selectedIndex = selectedIndex
      ..previousIndex = previousIndex
      ..progress = progress
      ..onKeyEvent = onKeyEvent
      ..theme = theme
      ..focusNode = focusNode;
  }
}

/// Lays the headers out in reading order and slides the indicator between them.
final class RenderTabStrip extends RenderBoxContainer<BoxParentData>
    with ControlBehavior {
  TextDirection _textDirection = TextDirection.leftToRight;
  int _selectedIndex = -1;
  int _previousIndex = -1;
  double _progress = 1;
  bool Function(KeyEvent event)? onKeyEvent;
  Rect _indicatorRect = const Rect.fromLTWH(0, 0, 0, 0);

  TextDirection get textDirection => _textDirection;

  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  int get selectedIndex => _selectedIndex;

  set selectedIndex(int value) {
    if (value == _selectedIndex) return;
    _selectedIndex = value;
    markNeedsLayout();
  }

  int get previousIndex => _previousIndex;

  set previousIndex(int value) {
    if (value == _previousIndex) return;
    _previousIndex = value;
    markNeedsLayout();
  }

  double get progress => _progress;

  set progress(double value) {
    if (value == _progress) return;
    _progress = value;
    markNeedsLayout();
  }

  /// Where the indicator is this frame, in this strip's coordinates.
  ///
  /// Exposed because "the indicator slid" is only meaningful as a position: a
  /// test that asserted an animation *value* would pass against an indicator
  /// painted in the wrong place.
  Rect get indicatorRect => _indicatorRect;

  /// The bar's thickness. Two pixels, on exact coordinates.
  static const double indicatorThickness = 2;

  @override
  bool get focusOnPointerDown => false;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! BoxParentData) child.parentData = BoxParentData();
  }

  @override
  void performLayout() {
    final double height = theme.effectiveControlHeight + indicatorThickness;
    final double width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : constraints.minWidth;
    size = constraints.constrain(Size(width, height));

    final BoxConstraints headerConstraints = BoxConstraints(
      maxWidth: size.width,
      minHeight: theme.effectiveControlHeight,
      maxHeight: theme.effectiveControlHeight,
    );
    double cursor = 0;
    for (int i = 0; i < childCount; i++) {
      final RenderBox child = childAt(i);
      child.layout(headerConstraints, parentUsesSize: true);
      // Right-to-left puts the first tab against the right edge and grows
      // leftward, which is what "start" means in that locale.
      final double x = _textDirection.isRightToLeft
          ? size.width - cursor - child.size.width
          : cursor;
      child.parentData!.offset = Offset(x, 0);
      cursor += child.size.width;
    }
    _indicatorRect = _computeIndicator();
  }

  Rect _rectOf(int index) {
    if (index < 0 || index >= childCount) {
      return const Rect.fromLTWH(0, 0, 0, 0);
    }
    final RenderBox child = childAt(index);
    final Offset offset = child.offsetFromParent;
    return Rect.fromLTWH(
      offset.dx,
      size.height - indicatorThickness,
      child.size.width,
      indicatorThickness,
    );
  }

  /// The indicator interpolated between where it was and where it is going.
  ///
  /// Interpolating the *rect* rather than translating one is what makes the bar
  /// stretch as it travels between headers of different widths - which is the
  /// visual difference between a bar that slides and one that teleports with a
  /// fixed size.
  Rect _computeIndicator() {
    final Rect target = _rectOf(_selectedIndex);
    if (_progress >= 1 || _previousIndex == _selectedIndex) return target;
    final Rect from = _rectOf(_previousIndex);
    if (from.width == 0) return target;
    double lerp(double a, double b) => a + (b - a) * _progress;
    return Rect.fromLTWH(
      lerp(from.left, target.left),
      target.top,
      lerp(from.width, target.width),
      indicatorThickness,
    );
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  bool handleKeyEvent(KeyEvent event) => onKeyEvent?.call(event) ?? false;

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      size.width,
      size.height,
    );
    paintFill(list, rect, theme.surfaceAlternate);
    // The rule the tabs sit on, drawn under them so the strip has an edge even
    // where no tab is selected.
    paintFill(
      list,
      Rect.fromLTWH(rect.left, rect.bottom - 1, rect.width, 1),
      theme.border,
    );
    super.paint(list, offset);
    if (_indicatorRect.width > 0) {
      // The indicator is a rounded bar inset from the header's edges, not a
      // full-width slab: a slab under a tab is the 1995 drawing, and the inset
      // is what makes the indicator read as belonging to the label above it.
      final Rect bar = _indicatorRect.shift(offset);
      paintRoundedFill(
        list,
        Rect.fromLTWH(
          bar.left + Spacing.md,
          bar.top,
          (bar.width - Spacing.md * 2).clamp(0.0, double.infinity),
          bar.height,
        ),
        enabled ? theme.accent : theme.disabledForeground,
        bar.height / 2,
      );
    }
    // The focus ring goes around the *selected header*, not the whole strip:
    // the strip is one tab stop, and the thing the user is about to act on with
    // an arrow key is that header.
    if (isFocusVisible && _selectedIndex >= 0 && _selectedIndex < childCount) {
      final RenderBox child = childAt(_selectedIndex);
      final Offset childOffset = child.offsetFromParent;
      paintFocusRing(
        list,
        Rect.fromLTWH(
          offset.dx + childOffset.dx,
          offset.dy + childOffset.dy,
          child.size.width,
          child.size.height,
        ),
      );
    }
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        // `list` and `listItem`: `semantics.dart` has no `tabList`/`tab` role
        // and this file does not get to add one - the vocabulary belongs to
        // that file. A list of selectable items with exactly one selected is
        // what every platform bridge maps a tab strip onto anyway.
        role: SemanticsRole.list,
        value: '$childCount tabs',
        hint: _selectedIndex < 0
            ? null
            : 'tab ${_selectedIndex + 1} of $childCount',
        states: <SemanticsState>{
          if (hasFocus) SemanticsState.focused,
          if (!enabled) SemanticsState.disabled,
        },
        actions: const <SemanticsAction>{SemanticsAction.focus},
      );
}

// ---------------------------------------------------------------------------
// One header
// ---------------------------------------------------------------------------

final class _TabHeaderWidget extends RenderObjectWidget {
  const _TabHeaderWidget({
    super.key,
    required this.label,
    required this.index,
    required this.count,
    required this.selected,
    required this.enabled,
    required this.theme,
    required this.onActivate,
  });

  final String label;
  final int index;
  final int count;
  final bool selected;
  final bool enabled;
  final ThemeData theme;
  final void Function() onActivate;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderTabHeader createRenderObject(BuildContext context) => RenderTabHeader(
        label: label,
        index: index,
      )
        ..count = count
        ..selected = selected
        ..onActivate = onActivate
        ..theme = theme
        ..enabled = enabled;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderTabHeader object,
  ) {
    object
      ..label = label
      ..index = index
      ..count = count
      ..selected = selected
      ..onActivate = onActivate
      ..theme = theme
      ..enabled = enabled;
  }
}

/// One header. Focusable by pointer only - the strip owns the keyboard.
final class RenderTabHeader extends RenderBox with ControlBehavior {
  RenderTabHeader({required String label, required int index})
      : _label = label,
        _index = index;

  String _label;
  int _index;
  int count = 0;
  bool _selected = false;
  void Function()? onActivate;

  String get label => _label;

  set label(String value) {
    if (value == _label) return;
    _label = value;
    markNeedsLayout();
  }

  int get index => _index;

  set index(int value) {
    if (value == _index) return;
    _index = value;
    markNeedsPaint();
  }

  bool get selected => _selected;

  set selected(bool value) {
    if (value == _selected) return;
    _selected = value;
    markNeedsPaint();
  }

  @override
  Set<PseudoClass> get controlStates => <PseudoClass>{
        if (_selected) PseudoClass.selected,
      };

  @override
  bool get focusOnPointerDown => false;

  @override
  void activate() => onActivate?.call();

  @override
  void performLayout() => size = constraints.constrain(labelledSize(_label));

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
    if (isHovered && enabled && !_selected) {
      paintRoundedFill(
        list,
        Rect.fromLTWH(
            rect.left + 2, rect.top + 2, rect.width - 4, rect.height - 4),
        theme.hoverSurface,
        theme.cornerRadiusSmall,
      );
    }
    paintCenteredLabel(
      list,
      _label,
      rect,
      !enabled
          ? theme.disabledForeground
          : _selected
              ? theme.accent
              : theme.foregroundSecondary,
    );
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.listItem,
        label: _label,
        value: '${_index + 1}',
        hint: count == 0 ? null : 'tab ${_index + 1} of $count',
        states: <SemanticsState>{
          if (_selected) SemanticsState.selected,
          if (!enabled) SemanticsState.disabled,
        },
        actions: enabled
            ? const <SemanticsAction>{SemanticsAction.activate}
            : const <SemanticsAction>{},
        mergesDescendants: true,
      );
}

// ---------------------------------------------------------------------------
// The panel
// ---------------------------------------------------------------------------

final class _TabPanelWidget extends SingleChildRenderObjectWidget {
  const _TabPanelWidget({required this.label, required Widget child})
      : super(child: child);

  final String? label;

  @override
  RenderTabPanel createRenderObject(BuildContext context) =>
      RenderTabPanel()..label = label;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderTabPanel object,
  ) {
    object.label = label;
  }
}

/// The selected tab's content, and the semantic node that names it.
final class RenderTabPanel extends RenderSingleChildBox
    implements SemanticsProvider {
  String? _label;

  String? get label => _label;

  set label(String? value) {
    if (value == _label) return;
    _label = value;
    markNeedsPaint();
  }

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.constrain(Size.zero);
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    child.parentData!.offset = Offset.zero;
    size = constraints.constrain(child.size);
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.generic,
        label: _label,
      );
}
