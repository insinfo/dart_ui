/// A hierarchical, virtualized tree.
///
/// The control a file explorer is made of, and one whose keyboard contract is
/// written down in every accessibility guide because so many implementations
/// get it wrong. The contract implemented here:
///
///   * **The tree is one tab stop.** Tab moves into the tree and out of it;
///     the arrow keys move between rows. The tree owns one [FocusNode] and the
///     rows own none - the same design as `tabs.dart` and `list_box.dart`.
///   * **Right expands, left collapses.** On a collapsed expandable row the
///     right arrow expands it; on an expanded row it moves to the first child;
///     on a leaf it does nothing. The left arrow collapses an expanded row and
///     otherwise moves to the parent. In a right-to-left locale the two swap,
///     because "expand" reads toward the content.
///   * **Asterisk expands the level.** The keypad `*` expands every expandable
///     sibling of the current row, which is the WAI-ARIA tree idiom for "open
///     this whole level at once".
///   * **Home/End** jump to the first and last *visible* row.
///
/// ## Virtualization
///
/// Only the rows a scroll offset makes visible are realized, through the same
/// [ListVirtualization] planner `list_box.dart` uses: the tree flattens its
/// expanded nodes into a row list and virtualizes that. A tree of a hundred
/// thousand collapsed roots therefore costs a few dozen render objects, and
/// the semantic tree still reports the *full* row count.
///
/// ## Lazy loading
///
/// The tree is controlled: [TreeView.expandedIds] says which nodes are open
/// and [TreeView.onToggle] reports intent. A node whose children are not yet
/// known sets [TreeNode.hasChildren] to true with an empty child list; the
/// expand still fires [TreeView.onToggle], and the owner loads the children
/// and rebuilds. Nothing here waits: an expanded node with no children simply
/// has no child rows until the data arrives, which is what keeps the tree free
/// of spinners it cannot draw deterministically.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/display_list.dart';
import '../layout/box_constraints.dart';
import '../layout/render_box.dart';
import '../layout/render_viewport.dart';
import '../platform/input_events.dart';
import '../text/shaper.dart' show TextDirection;
import 'control.dart';
import 'directionality.dart';
import 'element.dart';
import 'focus.dart';
import 'focus_scope.dart';
import 'semantics.dart';
import 'style.dart';
import 'theme.dart';
import 'virtualization.dart';
import 'widget.dart';

/// The keypad multiply key, which the tree contract spells `*`.
const int logicalKeyNumpadMultiply = 0x6A;

/// One node of the tree: a label, its children, and whether more exist.
final class TreeNode {
  const TreeNode({
    required this.label,
    this.id,
    this.children = const <TreeNode>[],
    this.hasChildren,
    this.enabled = true,
  });

  final String label;

  /// What this node *is*, across rebuilds in which the list changed. Defaults
  /// to the label, exactly as [TabItem.id] does.
  final Object? id;

  final List<TreeNode> children;

  /// Whether this node can expand. Null - the usual case - means "look at
  /// [children]"; an explicit true on a node with an empty child list is the
  /// lazy-loading handshake described in the library doc.
  final bool? hasChildren;

  final bool enabled;

  Object get identity => id ?? label;

  bool get isExpandable => hasChildren ?? children.isNotEmpty;
}

/// A hierarchical, virtualized, selectable tree.
///
/// Controlled: the widget shows [expandedIds] and [selectedId], and reports
/// intent through [onToggle] and [onSelected].
final class TreeView extends StatefulWidget {
  const TreeView({
    super.key,
    required this.nodes,
    this.expandedIds = const <Object>{},
    this.onToggle,
    this.selectedId,
    this.onSelected,
    this.rowExtent = 24.0,
    this.cacheExtent = 48.0,
    this.controller,
  });

  final List<TreeNode> nodes;

  /// The identities of the nodes currently expanded.
  final Set<Object> expandedIds;

  /// Called when the user asks to open or close [TreeNode]. The owner updates
  /// [expandedIds] - and, for a lazy node, loads its children - and rebuilds.
  final void Function(TreeNode node, bool expanded)? onToggle;

  /// The identity of the selected node, or null for no selection.
  final Object? selectedId;

  final void Function(TreeNode node)? onSelected;

  final double rowExtent;
  final double cacheExtent;
  final ScrollPosition? controller;

  @override
  State<TreeView> createState() => _TreeViewState();
}

/// One flattened, visible row: the node plus where it sits in the hierarchy.
final class _FlatRow {
  const _FlatRow({
    required this.node,
    required this.depth,
    required this.parentIndex,
  });

  final TreeNode node;
  final int depth;

  /// Index of the parent's row in the flattened list, or -1 for a root.
  final int parentIndex;
}

final class _TreeViewState extends State<TreeView> {
  late final ScrollPosition _position = widget.controller ?? ScrollPosition();
  late final FocusNode _focusNode = FocusNode(debugLabel: 'TreeView');
  double _viewportExtent = 0;
  List<_FlatRow> _rows = const <_FlatRow>[];

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
    if (mounted) setState(() {});
  }

  /// Depth-first over the expanded part of the tree only: a collapsed node's
  /// descendants contribute no rows, which is what makes the flattened list
  /// the exact thing to virtualize.
  List<_FlatRow> _flatten() {
    final List<_FlatRow> rows = <_FlatRow>[];
    void visit(List<TreeNode> nodes, int depth, int parentIndex) {
      for (final TreeNode node in nodes) {
        rows.add(_FlatRow(node: node, depth: depth, parentIndex: parentIndex));
        if (node.isExpandable && widget.expandedIds.contains(node.identity)) {
          visit(node.children, depth + 1, rows.length - 1);
        }
      }
    }

    visit(widget.nodes, 0, -1);
    return rows;
  }

  int get _selectedIndex {
    final Object? selected = widget.selectedId;
    if (selected == null) return -1;
    for (int i = 0; i < _rows.length; i++) {
      if (_rows[i].node.identity == selected) return i;
    }
    return -1;
  }

  void _select(int index) {
    if (index < 0 || index >= _rows.length) return;
    final TreeNode node = _rows[index].node;
    if (!node.enabled) return;
    if (node.identity != widget.selectedId) widget.onSelected?.call(node);
    _reveal(index);
  }

  /// Keyboard selection must bring the row into view, or a screen reader
  /// announces a selection that remains invisible on screen.
  void _reveal(int index) {
    final double? target = _virtualization.scrollToReveal(
      index,
      scrollOffset: _position.pixels,
      viewportExtent:
          _viewportExtent > 0 ? _viewportExtent : widget.rowExtent * 8,
    );
    if (target != null) _position.jumpTo(target);
  }

  void _toggle(int index, bool expanded) {
    if (index < 0 || index >= _rows.length) return;
    final TreeNode node = _rows[index].node;
    if (!node.isExpandable || !node.enabled) return;
    final bool isExpanded = widget.expandedIds.contains(node.identity);
    if (isExpanded == expanded) return;
    widget.onToggle?.call(node, expanded);
  }

  /// The `*` idiom: every expandable sibling of the current row opens, the
  /// current row included. Siblings are the children of the same parent, or
  /// the roots for a top-level row.
  void _expandSiblings(int index) {
    final _FlatRow row = _rows[index];
    final List<TreeNode> siblings = row.parentIndex < 0
        ? widget.nodes
        : _rows[row.parentIndex].node.children;
    for (final TreeNode sibling in siblings) {
      if (sibling.isExpandable &&
          sibling.enabled &&
          !widget.expandedIds.contains(sibling.identity)) {
        widget.onToggle?.call(sibling, true);
      }
    }
  }

  bool _handleKey(KeyEvent event, TextDirection direction) {
    if (event is! KeyDownEvent) return false;
    if (_rows.isEmpty) return false;
    final int current = _selectedIndex;
    final bool rtl = direction.isRightToLeft;
    // In a right-to-left locale the arrows swap so that "toward the content"
    // still expands, which is what the hand expects there.
    final int expandKey = rtl ? logicalKeyArrowLeft : logicalKeyArrowRight;
    final int collapseKey = rtl ? logicalKeyArrowRight : logicalKeyArrowLeft;
    final int key = event.logicalKey;
    if (key == logicalKeyArrowDown) {
      _select(current + 1 >= _rows.length ? _rows.length - 1 : current + 1);
      return true;
    }
    if (key == logicalKeyArrowUp) {
      _select(current <= 0 ? 0 : current - 1);
      return true;
    }
    if (key == logicalKeyHome) {
      _select(0);
      return true;
    }
    if (key == logicalKeyEnd) {
      _select(_rows.length - 1);
      return true;
    }
    if (current < 0) return false;
    final _FlatRow row = _rows[current];
    final bool expanded = widget.expandedIds.contains(row.node.identity);
    if (key == expandKey) {
      if (row.node.isExpandable && !expanded) {
        _toggle(current, true);
      } else if (expanded && current + 1 < _rows.length) {
        // The first child is the next row exactly when the node is expanded.
        if (_rows[current + 1].parentIndex == current) _select(current + 1);
      }
      return true;
    }
    if (key == collapseKey) {
      if (row.node.isExpandable && expanded) {
        _toggle(current, false);
      } else if (row.parentIndex >= 0) {
        _select(row.parentIndex);
      }
      return true;
    }
    if (key == logicalKeyNumpadMultiply) {
      _expandSiblings(current);
      return true;
    }
    if (key == logicalKeyEnter || key == logicalKeySpace) {
      if (row.node.isExpandable) _toggle(current, !expanded);
      return true;
    }
    return false;
  }

  /// A press at [dx] inside row [index]. The toggle gutter belongs to the
  /// expand glyph; everywhere else selects. Decided here rather than in the
  /// row's render object because the gutter's position depends on the depth
  /// and the reading direction, both of which this state already knows.
  void _handleRowPress(
    int index,
    double dx,
    double width,
    TextDirection direction,
  ) {
    if (index < 0 || index >= _rows.length) return;
    final _FlatRow row = _rows[index];
    final double indent = row.depth * RenderTreeItem.indentPerLevel;
    final bool rtl = direction.isRightToLeft;
    final double toggleStart =
        rtl ? width - indent - RenderTreeItem.toggleExtent : indent;
    final double toggleEnd = toggleStart + RenderTreeItem.toggleExtent;
    if (row.node.isExpandable && dx >= toggleStart && dx < toggleEnd) {
      _toggle(index, !widget.expandedIds.contains(row.node.identity));
    } else {
      _select(index);
    }
  }

  ListVirtualization get _virtualization => ListVirtualization(
        itemCount: _rows.length,
        estimatedExtent: widget.rowExtent,
        cacheExtent: widget.cacheExtent,
      );

  @override
  Widget build(BuildContext context) {
    final TextDirection direction = Directionality.of(context);
    _rows = _flatten();
    final ListVirtualization virtualization = _virtualization;
    final double viewport =
        _viewportExtent > 0 ? _viewportExtent : widget.rowExtent * 8;
    final RealizedRange range = virtualization.rangeFor(
      scrollOffset: _position.pixels,
      viewportExtent: viewport,
    );
    return FocusAttachment(
      node: _focusNode,
      child: _TreeViewRenderWidget(
        position: _position,
        focusNode: _focusNode,
        theme: Theme.of(context),
        virtualization: virtualization,
        range: range,
        selectedIndex: _selectedIndex,
        onKeyEvent: (KeyEvent event) => _handleKey(event, direction),
        onRowPressed: (int index, double dx, double width) =>
            _handleRowPress(index, dx, width, direction),
        onViewportExtent: (double extent) {
          if (extent == _viewportExtent) return;
          _viewportExtent = extent;
          if (mounted) setState(() {});
        },
        children: <Widget>[
          for (int index = range.firstRealized;
              index <= range.lastRealized && index < _rows.length;
              index++)
            _TreeItemWidget(
              // Keyed by node identity so an expand above a row updates the
              // row's element instead of rebuilding it as a stranger.
              key: ValueKey<Object>(_rows[index].node.identity),
              label: _rows[index].node.label,
              depth: _rows[index].depth,
              index: index,
              extent: widget.rowExtent,
              expandable: _rows[index].node.isExpandable,
              expanded:
                  widget.expandedIds.contains(_rows[index].node.identity),
              selected: index == _selectedIndex,
              enabled: _rows[index].node.enabled,
              textDirection: direction,
              theme: Theme.of(context),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// One row
// ---------------------------------------------------------------------------

final class _TreeItemWidget extends RenderObjectWidget {
  const _TreeItemWidget({
    super.key,
    required this.label,
    required this.depth,
    required this.index,
    required this.extent,
    required this.expandable,
    required this.expanded,
    required this.selected,
    required this.enabled,
    required this.textDirection,
    required this.theme,
  });

  final String label;
  final int depth;
  final int index;
  final double extent;
  final bool expandable;
  final bool expanded;
  final bool selected;
  final bool enabled;
  final TextDirection textDirection;
  final ThemeData theme;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderTreeItem createRenderObject(BuildContext context) => RenderTreeItem()
    ..label = label
    ..level = depth
    ..index = index
    ..extent = extent
    ..expandable = expandable
    ..expanded = expanded
    ..selected = selected
    ..textDirection = textDirection
    ..theme = theme
    ..enabled = enabled;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderTreeItem object,
  ) {
    object
      ..label = label
      ..level = depth
      ..index = index
      ..extent = extent
      ..expandable = expandable
      ..expanded = expanded
      ..selected = selected
      ..textDirection = textDirection
      ..theme = theme
      ..enabled = enabled;
  }
}

/// One realized tree row: indent, toggle glyph, label.
final class RenderTreeItem extends RenderBox with ControlBehavior {
  /// Horizontal pixels one level of depth is worth.
  static const double indentPerLevel = 16;

  /// The gutter the expand glyph owns, whether or not one is drawn: keeping
  /// leaves aligned with their expandable siblings is what makes depth
  /// readable at a glance.
  static const double toggleExtent = 16;

  /// The side of the plus/minus box. Odd, so its centre lines land on pixels.
  static const double _glyphExtent = 9;

  String _label = '';
  int _level = 0;
  int _index = 0;
  double _extent = 24;
  bool _expandable = false;
  bool _expanded = false;
  bool _selected = false;
  TextDirection _textDirection = TextDirection.leftToRight;

  String get label => _label;

  set label(String value) {
    if (value == _label) return;
    _label = value;
    markNeedsPaint();
  }

  /// The hierarchy depth, 0 for a root row. Named `level` because [RenderBox]
  /// already owns `depth` for the render tree's own bookkeeping.
  int get level => _level;

  set level(int value) {
    if (value == _level) return;
    _level = value;
    markNeedsPaint();
  }

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

  bool get expandable => _expandable;

  set expandable(bool value) {
    if (value == _expandable) return;
    _expandable = value;
    markNeedsPaint();
  }

  bool get expanded => _expanded;

  set expanded(bool value) {
    if (value == _expanded) return;
    _expanded = value;
    markNeedsPaint();
  }

  bool get selected => _selected;

  set selected(bool value) {
    if (value == _selected) return;
    _selected = value;
    markNeedsPaint();
  }

  TextDirection get textDirection => _textDirection;

  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsPaint();
  }

  @override
  bool get focusOnPointerDown => false;

  @override
  Set<PseudoClass> get controlStates => <PseudoClass>{
        if (_selected) PseudoClass.selected,
        if (_expandable && _expanded) PseudoClass.expanded,
      };

  @override
  void performLayout() {
    final double width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : constraints.minWidth;
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
    } else if (isHovered && enabled) {
      paintFill(list, rect, theme.surface);
    }
    final bool rtl = _textDirection.isRightToLeft;
    final double indent = _level * indentPerLevel;
    final double toggleStart =
        rtl ? size.width - indent - toggleExtent : indent;
    if (_expandable) {
      _paintToggle(
        list,
        Rect.fromLTWH(offset.dx + toggleStart, offset.dy, toggleExtent,
            size.height),
      );
    }
    final double labelStart = indent + toggleExtent + 2;
    final double labelWidth =
        (size.width - labelStart - 4).clamp(0.0, double.infinity);
    final Size box = measureLabel(_label);
    final double labelX = rtl
        ? (offset.dx + size.width - labelStart - box.width)
            .clamp(offset.dx + 4, double.infinity)
        : offset.dx + labelStart;
    final double labelY =
        (offset.dy + (size.height - box.height) / 2).roundToDouble();
    paintLabel(
      list,
      _label,
      Offset(labelX.roundToDouble(), labelY),
      enabled ? theme.foreground : theme.disabledForeground,
      maxWidth: labelWidth,
    );
  }

  /// The classic plus/minus box: a bordered square with a horizontal bar, and
  /// a vertical bar while collapsed. Pure rectangles on whole pixels, so a
  /// golden test compares geometry rather than antialiasing.
  void _paintToggle(DisplayList list, Rect gutter) {
    final double left =
        (gutter.left + (gutter.width - _glyphExtent) / 2).roundToDouble();
    final double top =
        (gutter.top + (gutter.height - _glyphExtent) / 2).roundToDouble();
    final Rect box = Rect.fromLTWH(left, top, _glyphExtent, _glyphExtent);
    paintFill(list, box, theme.surfaceAlternate);
    paintBorder(list, box, theme.border);
    final double mid = (_glyphExtent / 2).floorToDouble();
    paintFill(
      list,
      Rect.fromLTWH(box.left + 2, box.top + mid, _glyphExtent - 4, 1),
      enabled ? theme.foreground : theme.disabledForeground,
    );
    if (!_expanded) {
      paintFill(
        list,
        Rect.fromLTWH(box.left + mid, box.top + 2, 1, _glyphExtent - 4),
        enabled ? theme.foreground : theme.disabledForeground,
      );
    }
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.listItem,
        label: _label,
        // The depth as a value: "level 2" is what a screen reader announces
        // to make hierarchy audible, since indentation is invisible to it.
        value: 'level ${_level + 1}',
        states: <SemanticsState>{
          if (_selected) SemanticsState.selected,
          if (_expandable && _expanded) SemanticsState.expanded,
          if (!enabled) SemanticsState.disabled,
        },
        actions: enabled
            ? const <SemanticsAction>{SemanticsAction.activate}
            : const <SemanticsAction>{},
        mergesDescendants: true,
      );
}

// ---------------------------------------------------------------------------
// The tree container
// ---------------------------------------------------------------------------

final class _TreeViewRenderWidget extends MultiChildRenderObjectWidget {
  const _TreeViewRenderWidget({
    required this.position,
    required this.focusNode,
    required this.theme,
    required this.virtualization,
    required this.range,
    required this.selectedIndex,
    required this.onKeyEvent,
    required this.onRowPressed,
    required this.onViewportExtent,
    required super.children,
  });

  final ScrollPosition position;
  final FocusNode focusNode;
  final ThemeData theme;
  final ListVirtualization virtualization;
  final RealizedRange range;
  final int selectedIndex;
  final bool Function(KeyEvent event) onKeyEvent;
  final void Function(int index, double dx, double width) onRowPressed;
  final void Function(double extent) onViewportExtent;

  @override
  RenderTreeView createRenderObject(BuildContext context) => RenderTreeView(
        position: position,
        virtualization: virtualization,
        range: range,
        selectedIndex: selectedIndex,
        onKeyEvent: onKeyEvent,
        onRowPressed: onRowPressed,
        onViewportExtent: onViewportExtent,
      )
        ..theme = theme
        ..focusNode = focusNode;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderTreeView object,
  ) {
    object
      ..position = position
      ..virtualization = virtualization
      ..range = range
      ..selectedIndex = selectedIndex
      ..onKeyEvent = onKeyEvent
      ..onRowPressed = onRowPressed
      ..onViewportExtent = onViewportExtent
      ..theme = theme
      ..focusNode = focusNode;
  }
}

/// Lays out the realized rows and reports the full tree to accessibility.
final class RenderTreeView extends RenderBoxContainer<BoxParentData>
    with ControlBehavior {
  RenderTreeView({
    required ScrollPosition position,
    required ListVirtualization virtualization,
    required RealizedRange range,
    required this.selectedIndex,
    required this.onKeyEvent,
    required this.onRowPressed,
    required this.onViewportExtent,
  })  : _position = position,
        _virtualization = virtualization,
        _range = range {
    _position.addListener(_onScrolled);
  }

  ScrollPosition _position;
  ListVirtualization _virtualization;
  RealizedRange _range;
  int selectedIndex;
  bool Function(KeyEvent event) onKeyEvent;
  void Function(int index, double dx, double width) onRowPressed;
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
      final Offset local = globalToLocal(event.logicalPosition);
      final double contentY = local.dy + _position.pixels;
      final int index = _virtualization.indexAt(contentY);
      if (index >= 0 && index < _virtualization.itemCount) {
        onRowPressed(index, local.dx, size.width);
      }
    }
  }

  @override
  bool handleKeyEvent(KeyEvent event) => onKeyEvent(event);

  void _onScrolled(ScrollPosition position) => markNeedsLayout();

  @override
  void detach() {
    _position.removeListener(_onScrolled);
    super.detach();
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.list,
        // The full flattened count, not the realized one: assistive clients
        // must hear "item 3 of 10000" for rows that mostly do not exist.
        value: '${_virtualization.itemCount} items',
        hint: selectedIndex < 0
            ? null
            : 'item ${selectedIndex + 1} of ${_virtualization.itemCount}',
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
