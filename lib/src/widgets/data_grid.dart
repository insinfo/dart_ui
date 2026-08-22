/// A virtualized data grid: columns, sortable headers, resizable widths,
/// row selection.
///
/// The shape is the one every desktop toolkit converges on:
///
///   * **columns are configuration, cells are widgets.** A [DataGridColumn]
///     says what a column is called and how wide it starts; the cell content
///     comes from [DataGrid.cellBuilder], called only for realized rows -
///     which is what lets a grid of a hundred thousand rows exist at all. Row
///     virtualization reuses [ListVirtualization], the same planner
///     `list_box.dart` scrolls with.
///   * **the grid is controlled.** Sort state and selection live with the
///     caller; the grid reports intent through [DataGrid.onSortChanged] and
///     [DataGrid.onSelectionChanged]. Sorting *the data* is the caller's job:
///     the grid cannot know whether column 2 holds strings, dates or money,
///     and a control that guessed would sort one of them wrong.
///   * **the body is one tab stop.** Arrow keys move the row cursor,
///     Shift extends the selection in [DataGridSelectionMode.multiple],
///     Ctrl+A selects everything, Home/End and PageUp/PageDown do what they
///     say. The header is pointer-only, as it is on every platform.
///
/// Column resizing is a drag on the boundary between two headers; the grip is
/// a few pixels wide on either side. Widths are held by the grid's state,
/// keyed by column identity so a rebuild with the same columns keeps the
/// widths the user dragged, and reported through [DataGrid.onColumnResized]
/// for callers that persist them.
///
/// Horizontal overflow is clipped rather than scrolled in this first version;
/// the vertical axis is where a grid's size lives.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/display_list.dart';
import '../graphics/display_list_geometry.dart';
import '../layout/box_constraints.dart';
import '../layout/render_box.dart';
import '../layout/render_flex.dart';
import '../layout/render_viewport.dart';
import '../platform/input_events.dart';
import '../text/shaper.dart' show TextDirection;
import 'basic.dart';
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

/// One column: a title and its metrics. Content comes from the grid's
/// [DataGrid.cellBuilder].
final class DataGridColumn {
  const DataGridColumn({
    required this.title,
    this.id,
    this.width = 120.0,
    this.minWidth = 40.0,
    this.resizable = true,
    this.sortable = true,
  });

  final String title;

  /// What this column *is*, across rebuilds in which the list changed.
  /// Defaults to the title.
  final Object? id;

  /// The starting width; the user's drags override it from then on.
  final double width;

  final double minWidth;
  final bool resizable;
  final bool sortable;

  Object get identity => id ?? title;
}

enum DataGridSortDirection { ascending, descending }

/// Which column the data is sorted by, and which way.
final class DataGridSort {
  const DataGridSort(this.columnIndex, this.direction);

  final int columnIndex;
  final DataGridSortDirection direction;

  @override
  bool operator ==(Object other) =>
      other is DataGridSort &&
      other.columnIndex == columnIndex &&
      other.direction == direction;

  @override
  int get hashCode => Object.hash(columnIndex, direction);
}

enum DataGridSelectionMode { none, single, multiple }

/// A virtualized table of rows and columns.
final class DataGrid extends StatefulWidget {
  const DataGrid({
    super.key,
    required this.columns,
    required this.rowCount,
    required this.cellBuilder,
    this.rowExtent = 24.0,
    this.cacheExtent = 48.0,
    this.sort,
    this.onSortChanged,
    this.selectionMode = DataGridSelectionMode.single,
    this.selectedRows = const <int>{},
    this.onSelectionChanged,
    this.onColumnResized,
    this.controller,
  });

  final List<DataGridColumn> columns;
  final int rowCount;

  /// Called only for realized cells: a few dozen rows regardless of
  /// [rowCount].
  final Widget Function(BuildContext context, int row, int column) cellBuilder;

  final double rowExtent;
  final double cacheExtent;

  /// The current sort, or null for unsorted. The grid draws the arrow; the
  /// caller sorts the data.
  final DataGridSort? sort;

  final void Function(DataGridSort sort)? onSortChanged;

  final DataGridSelectionMode selectionMode;
  final Set<int> selectedRows;
  final void Function(Set<int> rows)? onSelectionChanged;

  /// Reports a width the user dragged, for callers that persist layout.
  final void Function(int columnIndex, double width)? onColumnResized;

  final ScrollPosition? controller;

  @override
  State<DataGrid> createState() => _DataGridState();
}

final class _DataGridState extends State<DataGrid> {
  late final ScrollPosition _position = widget.controller ?? ScrollPosition();
  late final FocusNode _focusNode = FocusNode(debugLabel: 'DataGrid');
  double _viewportExtent = 0;

  /// Widths the user has dragged, keyed by column identity so they survive a
  /// rebuild that reorders or extends the column list.
  final Map<Object, double> _draggedWidths = <Object, double>{};

  /// The row the keyboard is on. Selection follows it per the mode.
  int _cursor = 0;

  /// Where a Shift-extended range grows from.
  int _anchor = 0;

  @override
  void initState() {
    super.initState();
    _position.addListener(_onScrolled);
    if (widget.selectedRows.isNotEmpty) {
      _cursor = widget.selectedRows.reduce((int a, int b) => a < b ? a : b);
      _anchor = _cursor;
    }
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

  List<double> get _widths => <double>[
        for (final DataGridColumn column in widget.columns)
          _draggedWidths[column.identity] ?? column.width,
      ];

  void _resizeColumn(int index, double width) {
    final DataGridColumn column = widget.columns[index];
    final double clamped = width < column.minWidth ? column.minWidth : width;
    if ((_draggedWidths[column.identity] ?? column.width) == clamped) return;
    setState(() => _draggedWidths[column.identity] = clamped);
    widget.onColumnResized?.call(index, clamped);
  }

  void _requestSort(int index) {
    if (!widget.columns[index].sortable) return;
    final DataGridSort? current = widget.sort;
    // Clicking a new column sorts ascending; clicking the sorted column flips
    // it. That is the cycle every file manager taught everyone.
    final DataGridSortDirection direction = current?.columnIndex == index &&
            current?.direction == DataGridSortDirection.ascending
        ? DataGridSortDirection.descending
        : DataGridSortDirection.ascending;
    widget.onSortChanged?.call(DataGridSort(index, direction));
  }

  void _emitSelection(Set<int> rows) {
    widget.onSelectionChanged?.call(rows);
  }

  /// Selection after the cursor moved to [target] with [extend] (Shift held).
  void _moveCursor(int target, {bool extend = false}) {
    if (widget.rowCount == 0) return;
    final int clamped = target.clamp(0, widget.rowCount - 1);
    _cursor = clamped;
    switch (widget.selectionMode) {
      case DataGridSelectionMode.none:
        break;
      case DataGridSelectionMode.single:
        _anchor = clamped;
        _emitSelection(<int>{clamped});
      case DataGridSelectionMode.multiple:
        if (extend) {
          _emitSelection(_range(_anchor, clamped));
        } else {
          _anchor = clamped;
          _emitSelection(<int>{clamped});
        }
    }
    _reveal(clamped);
    if (mounted) setState(() {});
  }

  Set<int> _range(int a, int b) => <int>{
        for (int i = a < b ? a : b; i <= (a > b ? a : b); i++) i,
      };

  void _reveal(int index) {
    final double? target = _virtualization.scrollToReveal(
      index,
      scrollOffset: _position.pixels,
      viewportExtent:
          _viewportExtent > 0 ? _viewportExtent : widget.rowExtent * 8,
    );
    if (target != null) _position.jumpTo(target);
  }

  void _handleRowPress(int index, Set<KeyModifier> modifiers) {
    _cursor = index;
    switch (widget.selectionMode) {
      case DataGridSelectionMode.none:
        break;
      case DataGridSelectionMode.single:
        _anchor = index;
        _emitSelection(<int>{index});
      case DataGridSelectionMode.multiple:
        if (modifiers.contains(KeyModifier.shift)) {
          _emitSelection(_range(_anchor, index));
        } else if (modifiers.contains(KeyModifier.control)) {
          final Set<int> next = <int>{...widget.selectedRows};
          if (!next.remove(index)) next.add(index);
          _anchor = index;
          _emitSelection(next);
        } else {
          _anchor = index;
          _emitSelection(<int>{index});
        }
    }
    if (mounted) setState(() {});
  }

  int get _rowsPerPage {
    final double viewport =
        _viewportExtent > 0 ? _viewportExtent : widget.rowExtent * 8;
    return (viewport / widget.rowExtent).floor().clamp(1, 1 << 20);
  }

  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent || widget.rowCount == 0) return false;
    final bool shift = event.modifiers.contains(KeyModifier.shift);
    final bool control = event.modifiers.contains(KeyModifier.control);
    // With nothing selected the first arrow press lands on the cursor row
    // itself rather than stepping past it - the first Down from a fresh grid
    // must select the first row, not the second.
    final bool fresh = widget.selectedRows.isEmpty &&
        widget.selectionMode != DataGridSelectionMode.none;
    switch (event.logicalKey) {
      case logicalKeyArrowDown:
        _moveCursor(fresh ? _cursor : _cursor + 1, extend: shift);
        return true;
      case logicalKeyArrowUp:
        _moveCursor(fresh ? _cursor : _cursor - 1, extend: shift);
        return true;
      case logicalKeyHome:
        _moveCursor(0, extend: shift);
        return true;
      case logicalKeyEnd:
        _moveCursor(widget.rowCount - 1, extend: shift);
        return true;
      case logicalKeyPageDown:
        _moveCursor(_cursor + _rowsPerPage, extend: shift);
        return true;
      case logicalKeyPageUp:
        _moveCursor(_cursor - _rowsPerPage, extend: shift);
        return true;
      case logicalKeySpace:
        if (widget.selectionMode == DataGridSelectionMode.multiple && control) {
          final Set<int> next = <int>{...widget.selectedRows};
          if (!next.remove(_cursor)) next.add(_cursor);
          _emitSelection(next);
          return true;
        }
        _moveCursor(_cursor);
        return true;
      case 0x41: // A
        if (control &&
            widget.selectionMode == DataGridSelectionMode.multiple) {
          _emitSelection(_range(0, widget.rowCount - 1));
          return true;
        }
        return false;
      default:
        return false;
    }
  }

  ListVirtualization get _virtualization => ListVirtualization(
        itemCount: widget.rowCount,
        estimatedExtent: widget.rowExtent,
        cacheExtent: widget.cacheExtent,
      );

  @override
  Widget build(BuildContext context) {
    final TextDirection direction = Directionality.of(context);
    final ThemeData theme = Theme.of(context);
    final List<double> widths = _widths;
    final ListVirtualization virtualization = _virtualization;
    final double viewport =
        _viewportExtent > 0 ? _viewportExtent : widget.rowExtent * 8;
    final RealizedRange range = virtualization.rangeFor(
      scrollOffset: _position.pixels,
      viewportExtent: viewport,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _DataGridHeaderWidget(
          columns: widget.columns,
          widths: widths,
          sort: widget.sort,
          textDirection: direction,
          theme: theme,
          onSortRequest: _requestSort,
          onResize: _resizeColumn,
        ),
        Expanded(
          child: FocusAttachment(
            node: _focusNode,
            child: _DataGridBodyWidget(
              position: _position,
              focusNode: _focusNode,
              theme: theme,
              virtualization: virtualization,
              range: range,
              selectedCount: widget.selectedRows.length,
              cursor: _cursor,
              onKeyEvent: _handleKey,
              onRowPressed: _handleRowPress,
              onViewportExtent: (double extent) {
                if (extent == _viewportExtent) return;
                _viewportExtent = extent;
                if (mounted) setState(() {});
              },
              children: <Widget>[
                for (int row = range.firstRealized;
                    row <= range.lastRealized && row < widget.rowCount;
                    row++)
                  _DataGridRowWidget(
                    key: ValueKey<int>(row),
                    index: row,
                    extent: widget.rowExtent,
                    widths: widths,
                    selected: widget.selectedRows.contains(row),
                    textDirection: direction,
                    theme: theme,
                    children: <Widget>[
                      for (int column = 0;
                          column < widget.columns.length;
                          column++)
                        widget.cellBuilder(context, row, column),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// The header
// ---------------------------------------------------------------------------

final class _DataGridHeaderWidget extends RenderObjectWidget {
  const _DataGridHeaderWidget({
    required this.columns,
    required this.widths,
    required this.sort,
    required this.textDirection,
    required this.theme,
    required this.onSortRequest,
    required this.onResize,
  });

  final List<DataGridColumn> columns;
  final List<double> widths;
  final DataGridSort? sort;
  final TextDirection textDirection;
  final ThemeData theme;
  final void Function(int column) onSortRequest;
  final void Function(int column, double width) onResize;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderDataGridHeader createRenderObject(BuildContext context) =>
      RenderDataGridHeader()
        ..columns = columns
        ..widths = widths
        ..sort = sort
        ..textDirection = textDirection
        ..onSortRequest = onSortRequest
        ..onResize = onResize
        ..theme = theme;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderDataGridHeader object,
  ) {
    object
      ..columns = columns
      ..widths = widths
      ..sort = sort
      ..textDirection = textDirection
      ..onSortRequest = onSortRequest
      ..onResize = onResize
      ..theme = theme;
  }
}

/// The header row: titles, sort arrow, resize grips.
final class RenderDataGridHeader extends RenderBox with ControlBehavior {
  /// Half-width of the resize grip either side of a column boundary.
  static const double gripExtent = 4;

  List<DataGridColumn> _columns = const <DataGridColumn>[];
  List<double> _widths = const <double>[];
  DataGridSort? _sort;
  TextDirection _textDirection = TextDirection.leftToRight;
  void Function(int column)? onSortRequest;
  void Function(int column, double width)? onResize;

  List<DataGridColumn> get columns => _columns;

  set columns(List<DataGridColumn> value) {
    if (identical(value, _columns)) return;
    _columns = value;
    markNeedsLayout();
  }

  List<double> get widths => _widths;

  set widths(List<double> value) {
    _widths = value;
    markNeedsLayout();
  }

  DataGridSort? get sort => _sort;

  set sort(DataGridSort? value) {
    if (value == _sort) return;
    _sort = value;
    markNeedsPaint();
  }

  TextDirection get textDirection => _textDirection;

  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  @override
  bool get focusOnPointerDown => false;

  /// The x of column [index]'s start edge, in this header's coordinates.
  double columnStart(int index) {
    double cumulative = 0;
    for (int i = 0; i < index && i < _widths.length; i++) {
      cumulative += _widths[i];
    }
    if (!_textDirection.isRightToLeft) return cumulative;
    final double width =
        index < _widths.length ? _widths[index] : 0;
    return size.width - cumulative - width;
  }

  /// The column whose *boundary* grip contains [dx], or -1.
  ///
  /// The boundary after column i belongs to column i's resize: dragging the
  /// line between "Name" and "Size" resizes "Name", on every platform.
  int _gripAt(double dx) {
    double cumulative = 0;
    for (int i = 0; i < _widths.length; i++) {
      cumulative += _widths[i];
      final double edge = _textDirection.isRightToLeft
          ? size.width - cumulative
          : cumulative;
      if ((dx - edge).abs() <= gripExtent) {
        return _columns[i].resizable ? i : -1;
      }
    }
    return -1;
  }

  /// The column containing [dx], or -1.
  int _columnAt(double dx) {
    double cumulative = 0;
    for (int i = 0; i < _widths.length; i++) {
      final double start = _textDirection.isRightToLeft
          ? size.width - cumulative - _widths[i]
          : cumulative;
      if (dx >= start && dx < start + _widths[i]) return i;
      cumulative += _widths[i];
    }
    return -1;
  }

  int _resizingColumn = -1;
  double _resizeStartX = 0;
  double _resizeStartWidth = 0;
  int _pressedColumn = -1;

  @override
  void handlePointerEvent(PointerEvent event) {
    super.handlePointerEvent(event);
    if (!enabled) return;
    switch (event) {
      case PointerDownEvent(button: PointerButton.primary):
        final Offset local = globalToLocal(event.logicalPosition);
        final int grip = _gripAt(local.dx);
        if (grip >= 0) {
          _resizingColumn = grip;
          _resizeStartX = local.dx;
          _resizeStartWidth = _widths[grip];
          _pressedColumn = -1;
        } else {
          _resizingColumn = -1;
          _pressedColumn = _columnAt(local.dx);
        }
      case PointerMoveEvent():
        if (_resizingColumn < 0) return;
        final Offset local = globalToLocal(event.logicalPosition);
        // In RTL a column grows toward the left, so the drag sign flips.
        final double delta = _textDirection.isRightToLeft
            ? _resizeStartX - local.dx
            : local.dx - _resizeStartX;
        onResize?.call(_resizingColumn, _resizeStartWidth + delta);
      case PointerUpEvent():
        _resizingColumn = -1;
      case PointerCancelEvent():
        _resizingColumn = -1;
        _pressedColumn = -1;
      default:
        break;
    }
  }

  /// Fired by the release-inside path of [ControlBehavior]: a completed click
  /// that was not a resize asks for a sort.
  @override
  void activate() {
    final int column = _pressedColumn;
    _pressedColumn = -1;
    if (column >= 0 && column < _columns.length &&
        _columns[column].sortable) {
      onSortRequest?.call(column);
    }
  }

  @override
  void performLayout() {
    final double width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : constraints.minWidth;
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
    paintFill(list, rect, theme.surface);
    list.save();
    list.clipRect(rect.left, rect.top, rect.right, rect.bottom);
    final double padding = theme.effectiveControlPadding / 2;
    for (int i = 0; i < _columns.length && i < _widths.length; i++) {
      final double start = columnStart(i);
      final double columnWidth = _widths[i];
      final bool sorted = _sort?.columnIndex == i;
      final double arrowSpace = sorted ? 12 : 0;
      paintLabel(
        list,
        _columns[i].title,
        Offset(
          (offset.dx + start + padding).roundToDouble(),
          (offset.dy + (size.height - labelLineHeight) / 2).roundToDouble(),
        ),
        theme.foreground,
        maxWidth: (columnWidth - padding * 2 - arrowSpace)
            .clamp(0.0, double.infinity),
      );
      if (sorted) {
        _paintSortArrow(
          list,
          Offset(
            offset.dx + start + columnWidth - padding - 8,
            offset.dy + size.height / 2,
          ),
          _sort!.direction,
        );
      }
      // The boundary line doubles as the visual for the resize grip.
      final double edge = _textDirection.isRightToLeft ? start : start +
          columnWidth;
      paintFill(
        list,
        Rect.fromLTWH(offset.dx + edge - 1, rect.top + 3, 1, size.height - 6),
        theme.border,
      );
    }
    list.restore();
    paintBorder(list, rect, theme.border);
  }

  /// A pixel-art triangle: stacked one-pixel rows, exact on whole pixels.
  void _paintSortArrow(
    DisplayList list,
    Offset center,
    DataGridSortDirection direction,
  ) {
    const int rows = 4;
    for (int i = 0; i < rows; i++) {
      final int halfWidth =
          direction == DataGridSortDirection.ascending ? i : rows - 1 - i;
      final double y = (center.dy - rows / 2 + i).roundToDouble();
      list.drawRectangle(
        Rect.fromLTWH(
          (center.dx - halfWidth).roundToDouble(),
          y,
          halfWidth * 2 + 1,
          1,
        ),
        list.addPaint(colorArgb: theme.foreground.value, antiAlias: false),
      );
    }
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.list,
        label: <String>[
          for (final DataGridColumn column in _columns) column.title,
        ].join(', '),
        value: '${_columns.length} columns',
        hint: _sort == null
            ? null
            : 'sorted by ${_columns[_sort!.columnIndex].title} '
                '${_sort!.direction.name}',
        mergesDescendants: true,
      );
}

// ---------------------------------------------------------------------------
// One row
// ---------------------------------------------------------------------------

final class _DataGridRowWidget extends MultiChildRenderObjectWidget {
  const _DataGridRowWidget({
    super.key,
    required this.index,
    required this.extent,
    required this.widths,
    required this.selected,
    required this.textDirection,
    required this.theme,
    required super.children,
  });

  final int index;
  final double extent;
  final List<double> widths;
  final bool selected;
  final TextDirection textDirection;
  final ThemeData theme;

  @override
  RenderDataGridRow createRenderObject(BuildContext context) =>
      RenderDataGridRow()
        ..index = index
        ..extent = extent
        ..widths = widths
        ..selected = selected
        ..textDirection = textDirection
        ..theme = theme;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderDataGridRow object,
  ) {
    object
      ..index = index
      ..extent = extent
      ..widths = widths
      ..selected = selected
      ..textDirection = textDirection
      ..theme = theme;
  }
}

/// One realized row: its cells at the column offsets.
final class RenderDataGridRow extends RenderBoxContainer<BoxParentData>
    with ControlBehavior {
  int _index = 0;
  double _extent = 24;
  List<double> _widths = const <double>[];
  bool _selected = false;
  TextDirection _textDirection = TextDirection.leftToRight;

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

  List<double> get widths => _widths;

  set widths(List<double> value) {
    _widths = value;
    markNeedsLayout();
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
    markNeedsLayout();
  }

  @override
  bool get focusOnPointerDown => false;

  @override
  Set<PseudoClass> get controlStates => <PseudoClass>{
        if (_selected) PseudoClass.selected,
      };

  @override
  void performLayout() {
    final double width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : constraints.minWidth;
    size = constraints.constrain(Size(width, _extent));
    final double padding = theme.effectiveControlPadding / 2;
    double cumulative = 0;
    for (int i = 0; i < childCount; i++) {
      final double columnWidth = i < _widths.length ? _widths[i] : 0;
      final RenderBox child = childAt(i);
      final double cellWidth =
          (columnWidth - padding * 2).clamp(0.0, double.infinity);
      child.layout(
        BoxConstraints(maxWidth: cellWidth, maxHeight: _extent),
        parentUsesSize: true,
      );
      final double start = _textDirection.isRightToLeft
          ? size.width - cumulative - columnWidth
          : cumulative;
      child.parentData!.offset = Offset(
        start + padding,
        ((_extent - child.size.height) / 2).clamp(0.0, _extent),
      );
      cumulative += columnWidth;
    }
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
    } else if (_index.isOdd) {
      // Zebra from the *row index*, not the realized position, so the
      // stripes do not flicker as the grid scrolls.
      paintFill(list, rect, theme.surface);
    }
    super.paint(list, offset);
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.listItem,
        value: 'row ${_index + 1}',
        states: <SemanticsState>{
          if (_selected) SemanticsState.selected,
        },
        actions: const <SemanticsAction>{SemanticsAction.activate},
      );
}

// ---------------------------------------------------------------------------
// The body
// ---------------------------------------------------------------------------

final class _DataGridBodyWidget extends MultiChildRenderObjectWidget {
  const _DataGridBodyWidget({
    required this.position,
    required this.focusNode,
    required this.theme,
    required this.virtualization,
    required this.range,
    required this.selectedCount,
    required this.cursor,
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
  final int selectedCount;
  final int cursor;
  final bool Function(KeyEvent event) onKeyEvent;
  final void Function(int index, Set<KeyModifier> modifiers) onRowPressed;
  final void Function(double extent) onViewportExtent;

  @override
  RenderDataGridBody createRenderObject(BuildContext context) =>
      RenderDataGridBody(
        position: position,
        virtualization: virtualization,
        range: range,
        selectedCount: selectedCount,
        cursor: cursor,
        onKeyEvent: onKeyEvent,
        onRowPressed: onRowPressed,
        onViewportExtent: onViewportExtent,
      )
        ..theme = theme
        ..focusNode = focusNode;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderDataGridBody object,
  ) {
    object
      ..position = position
      ..virtualization = virtualization
      ..range = range
      ..selectedCount = selectedCount
      ..cursor = cursor
      ..onKeyEvent = onKeyEvent
      ..onRowPressed = onRowPressed
      ..onViewportExtent = onViewportExtent
      ..theme = theme
      ..focusNode = focusNode;
  }
}

/// Lays out the realized rows and reports the full grid to accessibility.
final class RenderDataGridBody extends RenderBoxContainer<BoxParentData>
    with ControlBehavior {
  RenderDataGridBody({
    required ScrollPosition position,
    required ListVirtualization virtualization,
    required RealizedRange range,
    required this.selectedCount,
    required this.cursor,
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
  int selectedCount;
  int cursor;
  bool Function(KeyEvent event) onKeyEvent;
  void Function(int index, Set<KeyModifier> modifiers) onRowPressed;
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

    double cursorY = _range.leadingExtent - _position.pixels;
    for (int i = 0; i < childCount; i++) {
      final RenderBox child = childAt(i);
      child.layout(
        BoxConstraints(minWidth: width, maxWidth: width),
        parentUsesSize: true,
      );
      child.parentData!.offset = Offset(0, cursorY);
      cursorY += child.size.height;
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
      final double contentY =
          globalToLocal(event.logicalPosition).dy + _position.pixels;
      final int index = _virtualization.indexAt(contentY);
      if (index >= 0 && index < _virtualization.itemCount) {
        onRowPressed(index, _modifiers);
      }
    }
  }

  /// The modifiers reported by the most recent key transition.
  ///
  /// The same workaround `text_field.dart` documents at length:
  /// [PointerEvent] in this framework carries no modifier set, so
  /// Ctrl/Shift+click reads the state the last key transition reported. It is
  /// wrong only when the modifier was already held before the grid ever saw a
  /// key event; the real fix is a modifier set on [PointerEvent].
  Set<KeyModifier> _modifiers = const <KeyModifier>{};

  @override
  bool handleKeyEvent(KeyEvent event) {
    // Every transition, press *and* release, so a Ctrl+click reads current
    // state rather than the state at the last KeyDown.
    _modifiers = event.modifiers;
    return onKeyEvent(event);
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
        value: '${_virtualization.itemCount} rows',
        hint: selectedCount == 0
            ? null
            : '$selectedCount of ${_virtualization.itemCount} selected',
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
