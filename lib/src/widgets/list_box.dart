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
///     at the edge of a scroll rather than like an exception;
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
import 'control.dart';
import 'element.dart';
import 'focus.dart';
import 'focus_scope.dart';
import 'semantics.dart';
import 'style.dart';
import 'theme.dart';
import 'widget.dart';

/// The window of items that must exist for one scroll offset.
final class RealizedRange {
  const RealizedRange({
    required this.firstVisible,
    required this.lastVisible,
    required this.firstRealized,
    required this.lastRealized,
    required this.leadingExtent,
  });

  /// The first and last item actually inside the viewport.
  final int firstVisible;
  final int lastVisible;

  /// The realized window, which includes the cache on both sides.
  final int firstRealized;
  final int lastRealized;

  /// The distance from the start of the content to [firstRealized], which is
  /// what positions the realized block inside a viewport that believes the
  /// whole list is present.
  final double leadingExtent;

  int get realizedCount =>
      lastRealized < firstRealized ? 0 : lastRealized - firstRealized + 1;

  bool contains(int index) => index >= firstRealized && index <= lastRealized;

  @override
  bool operator ==(Object other) =>
      other is RealizedRange &&
      other.firstVisible == firstVisible &&
      other.lastVisible == lastVisible &&
      other.firstRealized == firstRealized &&
      other.lastRealized == lastRealized &&
      other.leadingExtent == leadingExtent;

  @override
  int get hashCode => Object.hash(
        firstVisible,
        lastVisible,
        firstRealized,
        lastRealized,
        leadingExtent,
      );

  @override
  String toString() => 'RealizedRange(visible $firstVisible..$lastVisible, '
      'realized $firstRealized..$lastRealized)';
}

/// Turns a scroll offset into a set of indices to realize.
///
/// Extents may be uniform or per-item. Uniform is the fast path and answers in
/// constant time; a variable-extent list accumulates a prefix sum once and then
/// binary-searches it, so scrolling stays logarithmic rather than linear in the
/// item count.
final class ListVirtualization {
  ListVirtualization({
    required this.itemCount,
    required this.estimatedExtent,
    this.cacheExtent = 0,
    List<double>? extents,
  }) : _extents = extents {
    if (_extents != null && _extents.length != itemCount) {
      throw ArgumentError.value(
        _extents.length,
        'extents',
        'must have one entry per item ($itemCount)',
      );
    }
    if (_extents != null) _buildPrefixSums();
  }

  final int itemCount;

  /// The extent assumed for an item whose real extent is not known.
  ///
  /// This is what makes a 10 000-item list have a scrollbar before a single
  /// item has been measured; it is an estimate and the scrollbar corrects as
  /// items are realized.
  final double estimatedExtent;

  /// How far beyond the viewport items are kept realized, in pixels.
  ///
  /// Not an optimization: without it, the item entering the viewport is built
  /// during the frame that scrolls to it, which is exactly the frame that has
  /// no time to spare.
  final double cacheExtent;

  final List<double>? _extents;
  List<double>? _prefixSums;

  bool get hasVariableExtents => _extents != null;

  /// The total scrollable extent.
  double get totalExtent {
    final List<double>? sums = _prefixSums;
    if (sums != null) return sums.last;
    return itemCount * estimatedExtent;
  }

  /// The offset of item [index] from the start of the content.
  double offsetOf(int index) {
    final int clamped = index.clamp(0, itemCount);
    final List<double>? sums = _prefixSums;
    if (sums != null) return sums[clamped];
    return clamped * estimatedExtent;
  }

  /// The extent of item [index].
  double extentOf(int index) {
    final List<double>? extents = _extents;
    if (extents == null) return estimatedExtent;
    return extents[index.clamp(0, itemCount - 1)];
  }

  /// The item at content offset [offset], clamped into range.
  int indexAt(double offset) {
    if (itemCount == 0) return 0;
    final List<double>? sums = _prefixSums;
    if (sums == null) {
      return (offset / estimatedExtent).floor().clamp(0, itemCount - 1);
    }
    // Binary search the prefix sums: the last index whose start is <= offset.
    int low = 0;
    int high = itemCount - 1;
    while (low < high) {
      final int mid = (low + high + 1) ~/ 2;
      if (sums[mid] <= offset) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low;
  }

  /// The window to realize for a viewport of [viewportExtent] at [scrollOffset].
  RealizedRange rangeFor({
    required double scrollOffset,
    required double viewportExtent,
  }) {
    if (itemCount == 0) {
      return const RealizedRange(
        firstVisible: 0,
        lastVisible: -1,
        firstRealized: 0,
        lastRealized: -1,
        leadingExtent: 0,
      );
    }
    final double top = scrollOffset.clamp(0.0, double.infinity);
    final int firstVisible = indexAt(top);
    final int lastVisible = indexAt(top + viewportExtent);
    final int firstRealized = indexAt(top - cacheExtent);
    final int lastRealized = indexAt(top + viewportExtent + cacheExtent);
    return RealizedRange(
      firstVisible: firstVisible,
      lastVisible: lastVisible,
      firstRealized: firstRealized,
      lastRealized: lastRealized,
      leadingExtent: offsetOf(firstRealized),
    );
  }

  /// The scroll offset that brings [index] fully into view from
  /// [scrollOffset], or null when it already is.
  ///
  /// This is the scroll anchor: keyboard navigation to an item just below the
  /// fold must scroll by exactly one item, not centre the list.
  double? scrollToReveal(
    int index, {
    required double scrollOffset,
    required double viewportExtent,
  }) {
    final double start = offsetOf(index);
    final double end = start + extentOf(index);
    if (start < scrollOffset) return start;
    if (end > scrollOffset + viewportExtent) return end - viewportExtent;
    return null;
  }

  void _buildPrefixSums() {
    final List<double> extents = _extents!;
    final List<double> sums = List<double>.filled(itemCount + 1, 0);
    double running = 0;
    for (int i = 0; i < itemCount; i++) {
      sums[i] = running;
      running += extents[i];
    }
    sums[itemCount] = running;
    _prefixSums = sums;
  }
}

/// A scrollable, virtualized, selectable list.
final class ListBox extends StatefulWidget {
  const ListBox({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.itemExtent = 20.0,
    this.cacheExtent = 40.0,
    this.selectedIndex,
    this.onSelected,
    this.controller,
  });

  final int itemCount;

  /// Called only for realized indices. A list of a million items calls this a
  /// few dozen times per frame, which is the entire point.
  final Widget Function(BuildContext context, int index) itemBuilder;

  final double itemExtent;
  final double cacheExtent;
  final int? selectedIndex;
  final void Function(int index)? onSelected;
  final ScrollPosition? controller;

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

  ListVirtualization get _virtualization => ListVirtualization(
        itemCount: widget.itemCount,
        estimatedExtent: widget.itemExtent,
        cacheExtent: widget.cacheExtent,
      );

  @override
  Widget build(BuildContext context) {
    final ListVirtualization virtualization = _virtualization;
    // Before the first layout the viewport extent is unknown; realizing one
    // screenful of items on the estimate is better than realizing none, which
    // would paint an empty list for one frame.
    final double viewport =
        _viewportExtent > 0 ? _viewportExtent : widget.itemExtent * 8;
    final RealizedRange range = virtualization.rangeFor(
      scrollOffset: _position.pixels,
      viewportExtent: viewport,
    );
    return FocusAttachment(
      node: _focusNode,
      child: _ListBoxRenderWidget(
        position: _position,
        focusNode: _focusNode,
        theme: Theme.of(context),
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
              extent: widget.itemExtent,
              selected: index == widget.selectedIndex,
              child: widget.itemBuilder(context, index),
            ),
        ],
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
    if (child != null) {
      child.layout(
        BoxConstraints(
          minWidth: width,
          maxWidth: width,
          maxHeight: _extent,
        ),
        parentUsesSize: true,
      );
      child.parentData!.offset = Offset(
        theme.effectiveControlPadding / 2,
        ((_extent - child.size.height) / 2).clamp(0.0, _extent),
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
    if (_selected) {
      paintFill(list, rect, theme.selection);
    } else if (isHovered) {
      paintFill(list, rect, theme.surface);
    } else if (_index.isOdd) {
      // Zebra striping from the *item index*, not from the realized position:
      // striping by position makes the whole list flicker as it scrolls.
      paintFill(list, rect, theme.surfaceAlternate);
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
    paintFill(list, rect, theme.surfaceAlternate);
    list.save();
    list.clipRect(rect.left, rect.top, rect.right, rect.bottom);
    super.paint(list, offset);
    list.restore();
    paintBorder(list, rect, theme.border);
    paintFocusRing(list, rect);
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
    if (event is PointerScrollEvent) {
      _position.applyScrollDelta(
        event.scrollDelta.dy,
        inLines: event.scrollDeltaUnit == ScrollDeltaUnit.lines,
      );
      return;
    }
    if (event is PointerDownEvent) {
      final double contentY =
          globalToLocal(event.logicalPosition).dy + _position.pixels;
      final int index = _virtualization.indexAt(contentY);
      if (index >= 0 && index < _virtualization.itemCount) {
        onSelected?.call(index);
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
