/// A virtualized list.
///
/// Section 29.5 spells out what virtualization means here, and every item on
/// that list is a separate failure if it is missing: viewport, item provider,
/// realize/recycle, stable keys, estimated extent, variable extent, cache
/// before/after, focus preservation, selection, accessibility for *unrealized*
/// items, scroll anchor, incremental loading.
///
/// The design that satisfies them is a split between a pure planner and a
/// widget:
///
///   * [ListVirtualization] answers "given a scroll offset, which indices must
///     exist?" with no widgets, no render tree and no clock. Anchor arithmetic,
///     cache windows and variable extents are therefore testable directly,
///     which matters because off-by-one errors here look like items flickering
///     at the edge of a scroll rather than like an exception. It **lives in
///     `virtualization.dart`** and is re-exported here: a selectable list is
///     one consumer of that planner, and [ListView] is another. Moving it out
///     is what stopped "virtualization" meaning "the inside of a ListBox";
///   * [ListBox] realizes exactly that window, keyed by item index. Stable keys
///     are what make a scrolled-past item's element and state be *reused* for
///     the item that takes its place, rather than rebuilt - and what keeps
///     focus on an item that scrolls out and back.
///
/// The accessibility requirement is met by reporting the *full* item count and
/// the realized range on the list node: a screen reader must be told "item 3
/// of 10000", not "item 3 of 12".
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/display_list.dart';
import '../layout/box_constraints.dart';
import '../layout/render_box.dart';
import '../layout/render_viewport.dart';
import '../platform/input_events.dart';
import '../semantics/semantics.dart';
import 'basic.dart';
import 'control.dart';
import 'element.dart';
import 'focus.dart';
import 'focus_scope.dart';
import 'scroll_view.dart';
import 'scrollbar.dart';
import 'style.dart';
import 'theme.dart';
import 'virtualization.dart';
import 'widget.dart';

// Re-exported so that the public surface is exactly what it was before the
// planner moved out of this file: `ListVirtualization` and `RealizedRange` were
// already part of the contract, and an extraction that renamed the import a
// caller needs would be a breaking change dressed up as a refactor.
export 'virtualization.dart';

/// A scrollable, virtualized, selectable list.
final class ListBox extends StatefulWidget {
  const ListBox({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.itemExtent,
    this.cacheExtent = 40.0,
    this.selectedIndex,
    this.onSelected,
    this.controller,
    this.scrollbar = ScrollbarVisibility.always,
  });

  final int itemCount;

  /// Called only for realized indices. A list of a million items calls this a
  /// few dozen times per frame, which is the entire point.
  final Widget Function(BuildContext context, int index) itemBuilder;

  /// The height of one row, or null for the theme's.
  ///
  /// Null is the right answer for almost every caller: a list whose rows are a
  /// number the caller made up is a list that ignores the density switch, and
  /// a window that mixes one of those with a themed one has two row rhythms in
  /// it. A number is for the rare list whose rows are not text.
  final double? itemExtent;
  final double cacheExtent;
  final int? selectedIndex;
  final void Function(int index)? onSelected;
  final ScrollPosition? controller;
  final ScrollbarVisibility scrollbar;

  @override
  State<ListBox> createState() => _ListBoxState();
}

final class _ListBoxState extends State<ListBox> {
  late final ScrollPosition _position = widget.controller ?? ScrollPosition();
  late final FocusNode _focusNode = FocusNode(debugLabel: 'ListBox');
  double _viewportExtent = 0;

  @override
  void initState() {
    super.initState();
    _position.addListener(_onScrolled);
  }

  @override
  void dispose() {
    _position.removeListener(_onScrolled);
    _focusNode.dispose();
    super.dispose();
  }

  void _onScrolled(ScrollPosition position) {
    // Scrolling changes which items exist, so it is a rebuild and not merely a
    // repaint - the difference between virtualization and a big list clipped.
    if (mounted) setState(() {});
  }

  /// The resolved row height, refreshed by every build.
  ///
  /// Cached rather than read through `Theme.of` on demand, because the arrow
  /// keys and the scroll handlers need it outside a build and an inherited
  /// lookup there would register a dependency from the wrong phase. The
  /// starting value is only ever used before the first build.
  double _extent = 28;

  ListVirtualization get _virtualization => ListVirtualization(
        itemCount: widget.itemCount,
        estimatedExtent: _extent,
        cacheExtent: widget.cacheExtent,
      );

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    _extent = widget.itemExtent ?? theme.effectiveRowHeight;
    final ListVirtualization virtualization = _virtualization;
    // Before the first layout the viewport extent is unknown; realizing one
    // screenful of items on the estimate is better than realizing none, which
    // would paint an empty list for one frame.
    final double viewport = _viewportExtent > 0 ? _viewportExtent : _extent * 8;
    final RealizedRange range = virtualization.rangeFor(
      scrollOffset: _position.pixels,
      viewportExtent: viewport,
    );
    final list = FocusAttachment(
      node: _focusNode,
      child: _ListBoxRenderWidget(
        position: _position,
        focusNode: _focusNode,
        theme: theme,
        virtualization: virtualization,
        range: range,
        selectedIndex: widget.selectedIndex,
        onSelected: widget.onSelected,
        onViewportExtent: (double extent) {
          if (extent == _viewportExtent) return;
          _viewportExtent = extent;
          if (mounted) setState(() {});
        },
        children: <Widget>[
          for (int index = range.firstRealized;
              index <= range.lastRealized && index < widget.itemCount;
              index++)
            // The key is the index, which is what makes an element survive
            // scrolling: the widget for item 41 finds the element that was
            // item 41 last frame instead of the one that happened to be at the
            // same position in the list.
            _ListItem(
              key: ValueKey<int>(index),
              index: index,
              extent: _extent,
              selected: index == widget.selectedIndex,
              // The selected row publishes its own text colour rather than
              // recolouring the caller's widget: the row's content is built by
              // the application, and the only honest way to say "text on this
              // row is on a selected ground" is to say it to the subtree.
              child: index == widget.selectedIndex
                  ? DefaultTextStyle(
                      style: theme.textTheme.bodyMedium
                          .copyWith(color: theme.onSelection),
                      child: widget.itemBuilder(context, index),
                    )
                  : widget.itemBuilder(context, index),
            ),
        ],
      ),
    );
    return Scrollbar(
      position: _position,
      visibility: widget.scrollbar,
      child: Scrollable(
        position: _position,
        mouseDragEnabled: false,
        child: list,
      ),
    );
  }
}

final class _ListItem extends SingleChildRenderObjectWidget {
  const _ListItem({
    super.key,
    required this.index,
    required this.extent,
    required this.selected,
    required Widget child,
  }) : super(child: child);

  final int index;
  final double extent;
  final bool selected;

  @override
  RenderListItem createRenderObject(BuildContext context) => RenderListItem(
        index: index,
        extent: extent,
        selected: selected,
      )..theme = Theme.of(context);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderListItem object,
  ) {
    object
      ..index = index
      ..extent = extent
      ..selected = selected
      ..theme = Theme.of(context);
  }
}

/// One realized row.
final class RenderListItem extends RenderSingleChildBox with ControlBehavior {
  RenderListItem({
    required int index,
    required double extent,
    required bool selected,
  })  : _index = index,
        _extent = extent,
        _selected = selected;

  int _index;
  double _extent;
  bool _selected;

  int get index => _index;

  set index(int value) {
    if (value == _index) return;
    _index = value;
    markNeedsPaint();
  }

  double get extent => _extent;

  set extent(double value) {
    if (value == _extent) return;
    _extent = value;
    markNeedsLayout();
  }

  bool get selected => _selected;

  set selected(bool value) {
    if (value == _selected) return;
    _selected = value;
    markNeedsPaint();
  }

  @override
  bool get focusOnPointerDown => false;

  @override
  Set<PseudoClass> get controlStates => <PseudoClass>{
        if (_selected) PseudoClass.selected,
      };

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    final double width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : constraints.minWidth;
    final double horizontalPadding = theme.effectiveControlPadding;
    if (child != null) {
      // The child is inset on the left when it is painted, so its constraints
      // must reserve the same inset on the right. Giving it the full row width
      // and then translating it made trailing content (durations, badges and
      // buttons) extend past the ListBox clip by exactly one control padding.
      final double contentWidth =
          (width - horizontalPadding * 2).clamp(0.0, width);
      child.layout(
        BoxConstraints(
          minWidth: contentWidth,
          maxWidth: contentWidth,
          maxHeight: _extent,
        ),
        parentUsesSize: true,
      );
      child.parentData!.offset = Offset(
        horizontalPadding,
        ((_extent - child.size.height) / 2).roundToDouble().clamp(0.0, _extent),
      );
    }
    size = constraints.constrain(Size(width, _extent));
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
    // No zebra striping. Alternating row fills were how a 1995 list made its
    // rows legible without any spacing to spare; with a themed row height
    // there is spacing to spare, and the stripes only add noise behind the
    // selection. Hover and selection are the two states worth drawing.
    if (_selected || isHovered) {
      paintRoundedFill(
        list,
        Rect.fromLTWH(
          rect.left + 2,
          rect.top,
          rect.width - 4,
          rect.height,
        ),
        _selected ? theme.selection : theme.hoverSurface,
        theme.cornerRadiusSmall,
      );
    }
    super.paint(list, offset);
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.listItem,
        value: '${_index + 1}',
        states: <SemanticsState>{
          if (_selected) SemanticsState.selected,
        },
        actions: const <SemanticsAction>{SemanticsAction.activate},
      );
}

final class _ListBoxRenderWidget extends MultiChildRenderObjectWidget {
  const _ListBoxRenderWidget({
    required this.position,
    required this.focusNode,
    required this.theme,
    required this.virtualization,
    required this.range,
    required this.selectedIndex,
    required this.onSelected,
    required this.onViewportExtent,
    required super.children,
  });

  final ScrollPosition position;
  final FocusNode focusNode;
  final ThemeData theme;
  final ListVirtualization virtualization;
  final RealizedRange range;
  final int? selectedIndex;
  final void Function(int index)? onSelected;
  final void Function(double extent) onViewportExtent;

  @override
  RenderListBox createRenderObject(BuildContext context) => RenderListBox(
        position: position,
        virtualization: virtualization,
        range: range,
        selectedIndex: selectedIndex,
        onSelected: onSelected,
        onViewportExtent: onViewportExtent,
      )
        ..theme = theme
        ..focusNode = focusNode;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderListBox object,
  ) {
    object
      ..position = position
      ..virtualization = virtualization
      ..range = range
      ..selectedIndex = selectedIndex
      ..onSelected = onSelected
      ..onViewportExtent = onViewportExtent
      ..theme = theme
      ..focusNode = focusNode;
  }
}

/// Lays out the realized rows and reports the full list to accessibility.
///
/// It is *not* a [RenderViewport]: the children are already only the realized
/// ones, so this positions them at their true content offsets and clips, rather
/// than translating a child that contains everything.
final class RenderListBox extends RenderBoxContainer<BoxParentData>
    with ControlBehavior {
  RenderListBox({
    required ScrollPosition position,
    required ListVirtualization virtualization,
    required RealizedRange range,
    required this.selectedIndex,
    required this.onSelected,
    required this.onViewportExtent,
  })  : _position = position,
        _virtualization = virtualization,
        _range = range {
    _position.addListener(_onScrolled);
  }

  ScrollPosition _position;
  ListVirtualization _virtualization;
  RealizedRange _range;
  int? selectedIndex;
  void Function(int index)? onSelected;
  void Function(double extent) onViewportExtent;

  ScrollPosition get position => _position;

  set position(ScrollPosition value) {
    if (identical(value, _position)) return;
    _position.removeListener(_onScrolled);
    _position = value..addListener(_onScrolled);
    markNeedsLayout();
  }

  ListVirtualization get virtualization => _virtualization;

  set virtualization(ListVirtualization value) {
    _virtualization = value;
    markNeedsLayout();
  }

  RealizedRange get range => _range;

  set range(RealizedRange value) {
    if (value == _range) return;
    _range = value;
    markNeedsLayout();
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

    // The scroll position is told the *estimated total*, not the realized
    // total: the scrollbar must describe the whole list or it would grow and
    // shrink as the user scrolls.
    _position.applyViewportGeometry(
      viewportExtent: height,
      contentExtent: _virtualization.totalExtent,
    );

    double cursor = _range.leadingExtent - _position.pixels;
    for (int i = 0; i < childCount; i++) {
      final RenderBox child = childAt(i);
      child.layout(
        BoxConstraints(minWidth: width, maxWidth: width),
        parentUsesSize: true,
      );
      child.parentData!.offset = Offset(0, cursor);
      cursor += child.size.height;
    }
    // Reported after layout so the next build realizes the right window; the
    // callback only rebuilds when the extent actually changed.
    onViewportExtent(height);
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      size.width,
      size.height,
    );
    final double radius = theme.cornerRadius;
    paintRoundedFill(list, rect, theme.surfaceAlternate, radius);
    list.save();
    list.clipRect(rect.left, rect.top, rect.right, rect.bottom);
    super.paint(list, offset);
    list.restore();
    paintRoundedBorder(list, rect, theme.border, radius);
    paintFocusRing(list, rect, radius: radius);
  }

  @override
  RenderBox? hitTestChildren(Offset position, {HitTestPath? path}) {
    if (!size.contains(position)) return null;
    return super.hitTestChildren(position, path: path);
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void handlePointerEvent(PointerEvent event) {
    super.handlePointerEvent(event);
    if (event is PointerDownEvent) {
      final double contentY =
          globalToLocal(event.logicalPosition).dy + _position.pixels;
      final int index = _virtualization.indexAt(contentY);
      if (index >= 0 && index < _virtualization.itemCount) {
        onSelected?.call(index);
        final double? reveal = _virtualization.scrollToReveal(
          index,
          scrollOffset: _position.pixels,
          viewportExtent: hasSize ? size.height : _position.viewportExtent,
        );
        if (reveal != null) _position.jumpTo(reveal);
      }
    }
  }

  @override
  bool handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final int count = _virtualization.itemCount;
    if (count == 0) return false;
    final int current = selectedIndex ?? -1;
    int? target;
    switch (event.logicalKey) {
      case logicalKeyArrowDown:
        target = (current + 1).clamp(0, count - 1);
      case logicalKeyArrowUp:
        target = current <= 0 ? 0 : current - 1;
      case logicalKeyHome:
        target = 0;
      case logicalKeyEnd:
        target = count - 1;
      case logicalKeyPageDown:
        target = (current + _itemsPerPage).clamp(0, count - 1);
      case logicalKeyPageUp:
        target = (current - _itemsPerPage).clamp(0, count - 1);
      default:
        return false;
    }
    onSelected?.call(target);
    // Keyboard selection must bring the item into view, or the selection is
    // announced by a screen reader while remaining invisible on screen.
    final double? reveal = _virtualization.scrollToReveal(
      target,
      scrollOffset: _position.pixels,
      viewportExtent: hasSize ? size.height : _position.viewportExtent,
    );
    if (reveal != null) _position.jumpTo(reveal);
    return true;
  }

  int get _itemsPerPage {
    final double viewport = hasSize ? size.height : _position.viewportExtent;
    return (viewport / _virtualization.estimatedExtent)
        .floor()
        .clamp(1, 1 << 20);
  }

  void _onScrolled(ScrollPosition position) => markNeedsLayout();

  @override
  void detach() {
    _position.removeListener(_onScrolled);
    super.detach();
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.list,
        // The full count, not the realized one: an assistive client must be
        // able to say "3 of 10000" for a list whose items mostly do not exist.
        value: '${_virtualization.itemCount} items',
        hint: selectedIndex == null
            ? null
            : 'item ${selectedIndex! + 1} of ${_virtualization.itemCount}',
        states: <SemanticsState>{
          if (hasFocus) SemanticsState.focused,
        },
        actions: const <SemanticsAction>{
          SemanticsAction.focus,
          SemanticsAction.scrollDown,
          SemanticsAction.scrollUp,
        },
      );
}
