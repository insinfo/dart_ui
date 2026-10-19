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
/// Columns wider than the grid scroll sideways: the header and the rows move
/// together, a bar appears along the bottom, and Shift+wheel, a trackpad's
/// sideways swipe and Left/Right scroll it - Left/Right because the body's
/// keyboard is a row cursor, with no column to move to.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/display_list.dart';
import '../layout/box_constraints.dart';
import '../layout/pipeline.dart' show PipelineOwner;
import '../layout/render_box.dart';
import '../layout/render_flex.dart';
import '../layout/render_proxy_box.dart' show BoxBorder, BoxDecoration;
import '../layout/render_viewport.dart';
import '../platform/editing_convention.dart';
import '../platform/input_events.dart';
import '../platform/native_window.dart' show SystemCursor;
import '../semantics/semantics.dart';
import '../text/shaper.dart' show TextDirection;
import 'basic.dart';
import 'context_menu_area.dart';
import 'control.dart';
import 'directionality.dart';
import 'drag_drop.dart';
import 'element.dart';
import 'focus.dart';
import 'focus_scope.dart';
import 'pointer_router.dart';
import 'proxy.dart' show DecoratedBox;
import 'scrollbar.dart';
import 'style.dart';
import 'text_field.dart';
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
    this.editable = false,
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

  /// Whether F2 or a double click on the column's cell opens a text editor
  /// on it; see [DataGrid.onCellEdited].
  final bool editable;

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
    this.rowExtent,
    this.cacheExtent = 48.0,
    this.sort,
    this.onSortChanged,
    this.selectionMode = DataGridSelectionMode.single,
    this.selectedRows = const <int>{},
    this.onSelectionChanged,
    this.onColumnResized,
    this.onRowActivated,
    this.activateOnSingleClick = false,
    this.onSecondaryPress,
    this.controller,
    this.horizontalController,
    this.scrollbar = ScrollbarVisibility.always,
    this.cellText,
    this.onCellEdited,
    this.decorated = true,
    this.headerMenu,
    this.columnFitWidth,
    this.rowDragData,
    this.rowDragActions = const <DragAction>{DragAction.copy, DragAction.move},
    this.onRowDragEnd,
    this.rowDropResponse,
    this.onRowDrop,
    this.rowAcceptsDrops,
  });

  final List<DataGridColumn> columns;
  final int rowCount;

  /// Called only for realized cells: a few dozen rows regardless of
  /// [rowCount].
  final Widget Function(BuildContext context, int row, int column) cellBuilder;

  /// The height of one row, or null for the theme's.
  ///
  /// Null is the right answer for almost every caller: a collection whose rows
  /// are a number the caller made up is one that ignores the density switch,
  /// and a window that mixes one of those with a themed one has two row
  /// rhythms in it.
  final double? rowExtent;
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

  /// A row was opened: double-clicked, or Enter pressed on the keyboard's
  /// row - what opens a file in a file manager.
  final void Function(int row)? onRowActivated;

  /// Open rows with one primary click instead of two. Modifier clicks keep
  /// their selection behavior and never activate a row.
  final bool activateOnSingleClick;

  /// A secondary (right) press, with the row under it or null for the empty
  /// space below the rows. The selection has already been settled the way
  /// a file manager settles it - a row that was not selected becomes the
  /// selection, a selected one keeps the whole selection so the menu acts on
  /// all of it, empty space clears it - so a [ContextMenuArea] around the
  /// grid can build its menu from the selection.
  final void Function(int? row)? onSecondaryPress;

  /// The header's right-click menu - which columns to show, "Size all
  /// columns to fit" - or null for none.
  final List<Widget> Function()? headerMenu;

  /// The width column [column] needs to show all of its content, for a
  /// double click on its right edge - or null where that is not known.
  final double? Function(int column)? columnFitWidth;

  final ScrollPosition? controller;

  /// The sideways scroll, for a caller that keeps or drives it.
  final ScrollPosition? horizontalController;

  /// When the scroll bars show; each only while its axis overflows.
  final ScrollbarVisibility scrollbar;

  /// The text an [DataGridColumn.editable] cell's editor starts from - the
  /// value, which the cell's widget may show formatted.
  final String Function(int row, int column)? cellText;

  /// The text an edit of cell ([row], [column]) ended with, when it changed.
  /// The grid is controlled here too: the owner stores the value and
  /// rebuilds.
  ///
  /// An edit opens with F2 on the cursor row (its first editable column) or
  /// a double click on an editable cell, with the text selected. Enter and
  /// a click elsewhere keep it, Tab keeps it and opens the next editable
  /// cell of the row (Shift+Tab the previous), Escape drops it.
  final void Function(int row, int column, String text)? onCellEdited;

  /// What dragging rows out carries - the selection as file paths, as text -
  /// or null when these rows cannot be dragged at all.
  ///
  /// A drag starts from a row, never from the empty space below them: a
  /// press there is the start of nothing. It carries the selection when the
  /// press was on a selected row, and that row alone otherwise, which is
  /// what the press is about to make the selection anyway. Returning null
  /// from the callback cancels the drag.
  ///
  /// The drag is the platform's, so the rows can land in another
  /// application - a file manager's files on the desktop - as well as in
  /// this one.
  final DragData? Function(Set<int> rows)? rowDragData;

  /// What a drag of the rows lets its destination do.
  final Set<DragAction> rowDragActions;

  /// A drag of the rows ended, with what the destination did.
  final void Function(DragAction action)? onRowDragEnd;

  /// Whether a drag over [row] - null below the last row - may be dropped,
  /// and as what; null makes the grid refuse every drop.
  ///
  /// Called on every move of the pointer, so it must be cheap and must not
  /// wait. The row it accepts is drawn as the target: a file manager's
  /// folder row, lit while a file hovers over it.
  final DropResponse Function(int? row, DropDetails details)? rowDropResponse;

  /// Performs a drop on [row] (null below the rows), answering with what was
  /// really done.
  final Future<DragAction> Function(int? row, DropDetails details)? onRowDrop;

  /// Which rows a drop can go *into* - a file manager's folders, not its
  /// files - or null for every row. A drag over a row that cannot take it
  /// is a drag over the list itself: [rowDropResponse] and [onRowDrop] hear
  /// null, and no row is lit.
  final bool Function(int row)? rowAcceptsDrops;

  /// Whether it draws its own surface and outline. False for one placed
  /// on a pane or a card that already has them - a file manager's
  /// details list, a grid inside a rounded card - where a second box
  /// would be a frame inside a frame.
  final bool decorated;

  @override
  State<DataGrid> createState() => _DataGridState();
}

final class _DataGridState extends State<DataGrid> {
  late final ScrollPosition _position = widget.controller ?? ScrollPosition();
  late final ScrollPosition _horizontal = widget.horizontalController ??
      ScrollPosition(axis: ScrollAxis.horizontal);

  /// The row the last primary press landed on, -1 for empty space: where a
  /// drag of the rows starts from.
  int _pressedRow = -1;

  /// The row a drop would land on, drawn as the target; null for none.
  int? _dropRow;
  late final FocusNode _focusNode = FocusNode(debugLabel: 'DataGrid');

  /// The cell being edited, or -1s; the editor's text and keyboard.
  int _editRow = -1;
  int _editColumn = -1;
  String _editOriginal = '';
  TextEditingController? _editor;
  late final FocusNode _editorFocus = FocusNode(debugLabel: 'DataGrid cell')
    ..addListener(_onEditorFocus);
  double _viewportExtent = 0;

  /// Widths the user has dragged, keyed by column identity so they survive a
  /// rebuild that reorders or extends the column list.
  final Map<Object, double> _draggedWidths = <Object, double>{};

  /// The header, the body and every realized row, reached directly by a
  /// column drag. See [_resizeColumn].
  final _LiveColumnWidths _live = _LiveColumnWidths();

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
    _editorFocus.dispose();
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

  Widget _maybeHeaderMenu(Widget header) {
    final List<Widget> Function()? menu = widget.headerMenu;
    if (menu == null) return header;
    return ContextMenuArea(menuChildren: menu, child: header);
  }

  void _resizeColumn(int index, double width) {
    final DataGridColumn column = widget.columns[index];
    final double clamped = width < column.minWidth ? column.minWidth : width;
    if ((_draggedWidths[column.identity] ?? column.width) == clamped) return;
    _draggedWidths[column.identity] = clamped;
    // Not setState. A drag moves one edge per pointer event, and rebuilding
    // the grid for it ran the application's cellBuilder for every realized
    // cell of every row, on every event - the widths are all that changed,
    // and the render objects that use them are told directly. Rows relay out
    // and their cells keep their layout unless their own column's width
    // changed; the next rebuild, for whatever reason, passes the same
    // widths and changes nothing.
    _live.apply(_widths);
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
      viewportExtent: _viewportExtent > 0 ? _viewportExtent : _rowExtent * 8,
    );
    if (target != null) _position.jumpTo(target);
  }

  bool _canEdit(int column) =>
      widget.onCellEdited != null &&
      widget.cellText != null &&
      column >= 0 &&
      column < widget.columns.length &&
      widget.columns[column].editable;

  bool get _editing => _editRow >= 0;

  /// The next editable column after [column] in [step]'s direction, or -1.
  int _nextEditable(int column, int step) {
    for (int c = column + step;
        c >= 0 && c < widget.columns.length;
        c += step) {
      if (_canEdit(c)) return c;
    }
    return -1;
  }

  /// Opens the editor on cell ([row], [column]) with its text selected.
  bool _beginEdit(int row, int column) {
    if (!_canEdit(column) || row < 0 || row >= widget.rowCount) return false;
    if (_editing) _endEdit(commit: true, refocus: false);
    final String text = widget.cellText!(row, column);
    _editor = TextEditingController(text)..setSelection(0, text.length);
    _editOriginal = text;
    _editRow = row;
    _editColumn = column;
    _cursor = row;
    _reveal(row);
    // Taken as the editor mounts, this frame.
    _editorFocus.requestFocus();
    setState(() {});
    return true;
  }

  /// Closes the editor, reporting its text when [commit] and it changed, and
  /// gives the keyboard back to the rows when [refocus].
  void _endEdit({required bool commit, bool refocus = true}) {
    if (!_editing) return;
    final int row = _editRow;
    final int column = _editColumn;
    final String text = _editor!.value;
    // Cleared first: giving the rows the keyboard takes it from the editor,
    // which would land here again.
    _editRow = _editColumn = -1;
    if (refocus) _focusNode.requestFocus();
    if (mounted) setState(() {});
    if (commit && text != _editOriginal) {
      widget.onCellEdited?.call(row, column, text);
    }
  }

  /// A click elsewhere keeps the edit, as in every spreadsheet.
  void _onEditorFocus(FocusNode node) {
    if (_editing && !node.hasFocus) _endEdit(commit: true, refocus: false);
  }

  /// The editor's keys beyond the field's own: Escape drops the edit, Tab
  /// and Shift+Tab keep it and move along the row.
  bool _handleEditorKey(KeyEvent event) {
    if (event is! KeyDownEvent || !_editing) return false;
    switch (event.logicalKey) {
      case logicalKeyEscape:
        _endEdit(commit: false);
        return true;
      case logicalKeyTab:
        final int row = _editRow;
        final int next = _nextEditable(
            _editColumn, event.modifiers.contains(KeyModifier.shift) ? -1 : 1);
        _endEdit(commit: true, refocus: next < 0);
        if (next >= 0) _beginEdit(row, next);
        return true;
      default:
        return false;
    }
  }

  /// A press on the body: [index] is the row, or -1 for the empty space
  /// below the last one.
  void _handlePress(int index, Set<KeyModifier> modifiers,
      {PointerButton button = PointerButton.primary,
      int clickCount = 1,
      int column = -1}) {
    final bool onRow = index >= 0 && index < widget.rowCount;
    if (button == PointerButton.primary) _pressedRow = onRow ? index : -1;
    switch (button) {
      case PointerButton.primary:
        if (!onRow) {
          // Empty space: a plain click drops the selection, as everywhere.
          final bool extending = modifiers.contains(KeyModifier.shift) ||
              modifiers.contains(KeyModifier.control) ||
              modifiers.contains(KeyModifier.meta);
          if (!extending && widget.selectedRows.isNotEmpty) {
            _emitSelection(const <int>{});
          }
          return;
        }
        if (clickCount >= 2 && _beginEdit(index, column)) return;
        if (clickCount >= 2) {
          // The first click of the pair already selected the row.
          widget.onRowActivated?.call(index);
          return;
        }
        _handleRowPress(index, modifiers);
      case PointerButton.secondary:
        if (onRow) {
          if (!widget.selectedRows.contains(index)) {
            _handleRowPress(index, const <KeyModifier>{});
          } else {
            _cursor = index;
          }
        } else if (widget.selectedRows.isNotEmpty) {
          _emitSelection(const <int>{});
        }
        widget.onSecondaryPress?.call(onRow ? index : null);
      case PointerButton.middle:
      case PointerButton.forward:
      case PointerButton.back:
        break;
    }
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
        } else if (modifiers.contains(KeyModifier.control) ||
            modifiers.contains(platformEditingConvention.commandModifier)) {
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
        _viewportExtent > 0 ? _viewportExtent : _rowExtent * 8;
    return (viewport / _rowExtent).floor().clamp(1, 1 << 20);
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
      case logicalKeyF2:
        final int column = _canEdit(0) ? 0 : _nextEditable(0, 1);
        return column >= 0 && _beginEdit(_cursor, column);
      case logicalKeyArrowLeft || logicalKeyArrowRight:
        if (_horizontal.maxScrollExtent <= 0) return false;
        final bool towardEnd = (event.logicalKey == logicalKeyArrowRight) !=
            Directionality.of(context).isRightToLeft;
        _horizontal.applyScrollDelta(towardEnd ? 1 : -1, inLines: true);
        return true;
      case logicalKeyEnter when widget.onRowActivated != null:
        if (_cursor < 0 || _cursor >= widget.rowCount) return false;
        widget.onRowActivated!(_cursor);
        return true;
      case 0x41: // A
        if (control && widget.selectionMode == DataGridSelectionMode.multiple) {
          _emitSelection(_range(0, widget.rowCount - 1));
          return true;
        }
        return false;
      default:
        return false;
    }
  }

  /// The resolved row height, refreshed by every build.
  ///
  /// Cached rather than read through `Theme.of` on demand: the keyboard and
  /// scroll handlers need it outside a build, and an inherited lookup there
  /// would register a dependency from the wrong phase.
  double _rowExtent = 28;

  ListVirtualization get _virtualization => ListVirtualization(
        itemCount: widget.rowCount,
        estimatedExtent: _rowExtent,
        cacheExtent: widget.cacheExtent,
      );

  @override
  Widget build(BuildContext context) {
    final TextDirection direction = Directionality.of(context);
    final ThemeData theme = Theme.of(context);
    _rowExtent = widget.rowExtent ?? theme.effectiveRowHeight;
    final List<double> widths = _widths;
    final ListVirtualization virtualization = _virtualization;
    final double viewport =
        _viewportExtent > 0 ? _viewportExtent : _rowExtent * 8;
    final RealizedRange range = virtualization.rangeFor(
      scrollOffset: _position.pixels,
      viewportExtent: viewport,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _maybeHeaderMenu(_DataGridHeaderWidget(
          live: _live,
          columns: widget.columns,
          widths: widths,
          sort: widget.sort,
          textDirection: direction,
          theme: theme,
          horizontal: _horizontal,
          onSortRequest: _requestSort,
          onResize: _resizeColumn,
          onFit: (int column) {
            final double? width = widget.columnFitWidth?.call(column);
            if (width != null) _resizeColumn(column, width);
          },
        )),
        Expanded(
          child: _withScrollbars(_withDragAndDrop(FocusAttachment(
            node: _focusNode,
            child: _DataGridBodyWidget(
              live: _live,
              decorated: widget.decorated,
              position: _position,
              horizontal: _horizontal,
              contentWidth: widths.fold(0.0, (double a, double b) => a + b),
              textDirection: direction,
              focusNode: _focusNode,
              theme: theme,
              virtualization: virtualization,
              range: range,
              selectedCount: widget.selectedRows.length,
              cursor: _cursor,
              onKeyEvent: _handleKey,
              onRowPressed: _handlePress,
              onRowClicked:
                  widget.activateOnSingleClick ? widget.onRowActivated : null,
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
                    live: _live,
                    index: row,
                    extent: _rowExtent,
                    widths: widths,
                    selected: widget.selectedRows.contains(row),
                    dropTarget: _dropRow == row,
                    textDirection: direction,
                    theme: theme,
                    editingColumn: row == _editRow ? _editColumn : -1,
                    children: <Widget>[
                      for (int column = 0;
                          column < widget.columns.length;
                          column++)
                        if (row == _editRow && column == _editColumn)
                          _CellEditor(
                            controller: _editor!,
                            focusNode: _editorFocus,
                            onSubmitted: (_) => _endEdit(commit: true),
                            onKey: _handleEditorKey,
                          )
                        else
                        // A selected row publishes its text colour to the
                        // cells rather than recolouring them: the cell is the
                        // application's widget, and the row is the only thing
                        // that knows it is sitting on a selected ground.
                        if (widget.selectedRows.contains(row))
                          DefaultTextStyle(
                            style: theme.textTheme.bodyMedium
                                .copyWith(color: theme.onSelection),
                            child: widget.cellBuilder(context, row, column),
                          )
                        else
                          widget.cellBuilder(context, row, column),
                    ],
                  ),
              ],
            ),
          ))),
        ),
      ],
    );
  }

  /// The row a drag at [local] - in the body's space - is over, or null
  /// below the last row.
  int? _rowAtBody(Offset local) {
    final double contentY = local.dy + _position.pixels;
    final ListVirtualization virtualization = _virtualization;
    if (contentY < 0 || contentY >= virtualization.totalExtent) return null;
    final int index = virtualization.indexAt(contentY);
    if (index < 0 || index >= widget.rowCount) return null;
    final bool Function(int)? accepts = widget.rowAcceptsDrops;
    return accepts == null || accepts(index) ? index : null;
  }

  void _setDropRow(int? row) {
    if (row == _dropRow) return;
    setState(() => _dropRow = row);
  }

  DropResponse _dropResponse(DropDetails details) {
    final DropResponse Function(int?, DropDetails)? respond =
        widget.rowDropResponse;
    if (respond == null) return const DropResponse.reject();
    final int? row = _rowAtBody(details.localPosition);
    final DropResponse response = respond(row, details);
    // Lit only when the drop would go *into* the row; a drop accepted on
    // the empty space, or refused, lights nothing.
    _setDropRow(response.isAccepted ? row : null);
    return response;
  }

  /// [body] with a bar for each axis, shown while that axis overflows.
  Widget _withScrollbars(Widget body) => Scrollbar(
        position: _position,
        visibility: widget.scrollbar,
        child: Scrollbar(
          position: _horizontal,
          visibility: widget.scrollbar,
          child: body,
        ),
      );

  /// [body] as a drag source of the rows and a drop target, as configured.
  Widget _withDragAndDrop(Widget body) {
    Widget result = body;
    if (widget.rowDragData != null) {
      result = DragSource(
        data: () {
          final int pressed = _pressedRow;
          if (pressed < 0 || pressed >= widget.rowCount) return null;
          final Set<int> rows = widget.selectedRows.contains(pressed)
              ? widget.selectedRows
              : <int>{pressed};
          return widget.rowDragData!(rows);
        },
        allowedActions: widget.rowDragActions,
        preferredAction: widget.rowDragActions.contains(DragAction.move)
            ? DragAction.move
            : DragAction.copy,
        opaque: true,
        onDragEnd: widget.onRowDragEnd,
        child: result,
      );
    }
    if (widget.rowDropResponse != null) {
      result = DropTarget(
        accepts: _dropResponse,
        onDragLeave: () => _setDropRow(null),
        onDrop: (DropDetails details) async {
          final int? row = _rowAtBody(details.localPosition);
          _setDropRow(null);
          return await widget.onRowDrop?.call(row, details) ?? DragAction.none;
        },
        child: result,
      );
    }
    return result;
  }
}

/// A cell's text editor: a field without its frame - the cell is the frame -
/// that offers the grid the keys it does not take.
final class _CellEditor extends StatefulWidget {
  const _CellEditor({
    required this.controller,
    required this.focusNode,
    required this.onSubmitted,
    required this.onKey,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final void Function(String text) onSubmitted;
  final bool Function(KeyEvent event) onKey;

  @override
  State<_CellEditor> createState() => _CellEditorState();
}

final class _CellEditorState extends State<_CellEditor> {
  BuildOwner? _owner;

  @override
  void initState() {
    super.initState();
    _owner = (context as Element).owner;
    // Escape and Tab reach the window when the field declines them; ahead of
    // a dialog's Escape and of focus traversal's Tab.
    _owner?.addWindowKeyHandler(_key, modalDepth: 1 << 30, first: true);
  }

  @override
  void dispose() {
    _owner?.removeWindowKeyHandler(_key);
    super.dispose();
  }

  bool _key(KeyEvent event) => widget.focusNode.hasFocus && widget.onKey(event);

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.surface,
        border: BoxBorder(color: theme.accent, width: 1),
      ),
      child: TextField(
        controller: widget.controller,
        focusNode: widget.focusNode,
        decorated: false,
        onSubmitted: widget.onSubmitted,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The header
// ---------------------------------------------------------------------------

final class _DataGridHeaderWidget extends RenderObjectWidget {
  const _DataGridHeaderWidget({
    required this.live,
    required this.columns,
    required this.widths,
    required this.sort,
    required this.textDirection,
    required this.theme,
    required this.horizontal,
    required this.onSortRequest,
    required this.onResize,
    required this.onFit,
  });

  final ScrollPosition horizontal;
  final _LiveColumnWidths live;

  final List<DataGridColumn> columns;
  final List<double> widths;
  final DataGridSort? sort;
  final TextDirection textDirection;
  final ThemeData theme;
  final void Function(int column) onSortRequest;
  final void Function(int column, double width) onResize;
  final void Function(int column) onFit;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderDataGridHeader createRenderObject(BuildContext context) =>
      RenderDataGridHeader()
        .._liveWidths = live
        ..columns = columns
        ..widths = widths
        ..sort = sort
        ..textDirection = textDirection
        ..horizontal = horizontal
        ..onSortRequest = onSortRequest
        ..onResize = onResize
        ..onFit = onFit
        ..theme = theme;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderDataGridHeader object,
  ) {
    object
      .._liveWidths = live
      ..columns = columns
      ..widths = widths
      ..sort = sort
      ..textDirection = textDirection
      ..horizontal = horizontal
      ..onSortRequest = onSortRequest
      ..onResize = onResize
      ..onFit = onFit
      ..theme = theme;
  }
}

/// The header row: titles, sort arrow, resize grips.
final class RenderDataGridHeader extends RenderBox
    with ControlBehavior
    implements MouseCursorTarget {
  /// Half-width of the resize grip either side of a column boundary - wide
  /// enough to find without aiming, as File Explorer's is.
  static const double gripExtent = 6;

  /// A column edge shows the resize arrow, so it can be found at all.
  @override
  SystemCursor? cursorFor(PointerEvent event) => (_resizingColumn >= 0 ||
          _gripAt(globalToLocal(event.logicalPosition).dx) >= 0)
      ? SystemCursor.resizeHorizontal
      : null;

  /// A double click on an edge: size the column to its content.
  void Function(int column)? onFit;

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
    if (_sameWidths(value, _widths)) return;
    _widths = value;
    markNeedsLayout();
  }

  _LiveColumnWidths? _live;

  set _liveWidths(_LiveColumnWidths? value) {
    if (identical(value, _live)) return;
    if (owner != null && identical(_live?.header, this)) _live!.header = null;
    _live = value;
    if (owner != null) value?.header = this;
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _live?.header = this;
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

  /// The body's sideways scroll, which the titles follow.
  ScrollPosition? get horizontal => _horizontal;
  ScrollPosition? _horizontal;

  set horizontal(ScrollPosition? value) {
    if (identical(value, _horizontal)) return;
    _horizontal?.removeListener(_onScrolled);
    _horizontal = value?..addListener(_onScrolled);
    markNeedsPaint();
  }

  void _onScrolled(ScrollPosition position) => markNeedsPaint();

  @override
  void detach() {
    _horizontal?.removeListener(_onScrolled);
    if (identical(_live?.header, this)) _live!.header = null;
    super.detach();
  }

  /// How far the columns are moved by the sideways scroll: left in a
  /// left-to-right grid, right in a right-to-left one.
  double get _shift {
    final double pixels = _horizontal?.pixels ?? 0;
    return _textDirection.isRightToLeft ? pixels : -pixels;
  }

  /// The x of column [index]'s start edge, in this header's coordinates.
  double columnStart(int index) {
    double cumulative = 0;
    for (int i = 0; i < index && i < _widths.length; i++) {
      cumulative += _widths[i];
    }
    if (!_textDirection.isRightToLeft) return cumulative + _shift;
    final double width = index < _widths.length ? _widths[index] : 0;
    return size.width - cumulative - width + _shift;
  }

  /// The column whose *boundary* grip contains [dx], or -1.
  ///
  /// The boundary after column i belongs to column i's resize: dragging the
  /// line between "Name" and "Size" resizes "Name", on every platform.
  int _gripAt(double dx) {
    double cumulative = 0;
    for (int i = 0; i < _widths.length; i++) {
      cumulative += _widths[i];
      final double edge = (_textDirection.isRightToLeft
              ? size.width - cumulative
              : cumulative) +
          _shift;
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
      final double start = (_textDirection.isRightToLeft
              ? size.width - cumulative - _widths[i]
              : cumulative) +
          _shift;
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
        if (grip >= 0 && event.clickCount >= 2) {
          _resizingColumn = -1;
          _pressedColumn = -1;
          onFit?.call(grip);
        } else if (grip >= 0) {
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
    if (column >= 0 && column < _columns.length && _columns[column].sortable) {
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
    // The header is a *surface step*, not a box: one fill and one rule along
    // the bottom, so the grid reads as a table with a heading rather than as
    // two stacked frames.
    paintFill(list, rect, theme.surface);
    paintFill(
      list,
      Rect.fromLTWH(rect.left, rect.bottom - 1, rect.width, 1),
      theme.border,
    );
    list.save();
    list.clipRect(rect.left, rect.top, rect.right, rect.bottom);
    final double padding = theme.effectiveControlPadding;
    for (int i = 0; i < _columns.length && i < _widths.length; i++) {
      final double start = columnStart(i);
      final double columnWidth = _widths[i];
      final bool sorted = _sort?.columnIndex == i;
      final double arrowSpace = sorted ? 12 : 0;
      paintLabel(
        list,
        _columns[i].title,
        Offset((offset.dx + start + padding).roundToDouble(), labelTopIn(rect)),
        theme.foregroundSecondary,
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
      // The boundary line doubles as the visual for the resize grip. Drawn in
      // the subtle colour: a column rule is a division *inside* one surface,
      // and at the border colour it competes with the grid's own frame.
      final double edge =
          _textDirection.isRightToLeft ? start : start + columnWidth;
      if (i < _columns.length - 1) {
        paintFill(
          list,
          Rect.fromLTWH(
            offset.dx + edge - 1,
            rect.top + Spacing.xs,
            1,
            size.height - Spacing.sm,
          ),
          theme.border,
        );
      }
    }
    list.restore();
  }

  /// The sort indicator: a chevron, the same mark the combo box and the tree
  /// draw, in the accent so the sorted column is findable at a glance.
  void _paintSortArrow(
    DisplayList list,
    Offset center,
    DataGridSortDirection direction,
  ) {
    const double span = 3;
    final bool up = direction == DataGridSortDirection.ascending;
    final double x = center.dx.roundToDouble();
    final double y = center.dy.roundToDouble();
    paintPolylineMark(
      list,
      <Offset>[
        Offset(x - span, y + (up ? span / 2 : -span / 2)),
        Offset(x, y + (up ? -span / 2 : span / 2)),
        Offset(x + span, y + (up ? span / 2 : -span / 2)),
      ],
      1.5,
      theme.accent,
    );
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
    required this.live,
    required this.index,
    required this.extent,
    required this.widths,
    required this.selected,
    required this.textDirection,
    required this.theme,
    required super.children,
    this.dropTarget = false,
    this.editingColumn = -1,
  });

  final _LiveColumnWidths live;
  final int index;
  final double extent;
  final List<double> widths;
  final bool selected;
  final bool dropTarget;
  final int editingColumn;
  final TextDirection textDirection;
  final ThemeData theme;

  @override
  RenderDataGridRow createRenderObject(BuildContext context) =>
      RenderDataGridRow()
        .._liveWidths = live
        ..index = index
        ..extent = extent
        ..widths = widths
        ..selected = selected
        ..dropTarget = dropTarget
        ..editingColumn = editingColumn
        ..textDirection = textDirection
        ..theme = theme;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderDataGridRow object,
  ) {
    object
      .._liveWidths = live
      ..index = index
      ..extent = extent
      ..widths = widths
      ..selected = selected
      ..dropTarget = dropTarget
      ..editingColumn = editingColumn
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
    if (_sameWidths(value, _widths)) return;
    _widths = value;
    markNeedsLayout();
  }

  _LiveColumnWidths? _live;

  set _liveWidths(_LiveColumnWidths? value) {
    if (identical(value, _live)) return;
    if (owner != null) _live?.rows.remove(this);
    _live = value;
    if (owner != null) value?.rows.add(this);
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _live?.rows.add(this);
  }

  @override
  void detach() {
    _live?.rows.remove(this);
    super.detach();
  }

  bool get selected => _selected;

  set selected(bool value) {
    if (value == _selected) return;
    _selected = value;
    markNeedsPaint();
  }

  /// Whether a drag is over this row and would drop into it.
  bool get dropTarget => _dropTarget;
  bool _dropTarget = false;

  set dropTarget(bool value) {
    if (value == _dropTarget) return;
    _dropTarget = value;
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

  /// The column whose cell is an editor, which fills the whole cell rather
  /// than sitting inside its padding; -1 for none.
  int get editingColumn => _editingColumn;
  int _editingColumn = -1;

  set editingColumn(int value) {
    if (value == _editingColumn) return;
    _editingColumn = value;
    markNeedsLayout();
  }

  /// The column containing [dx], in this row's coordinates, or -1.
  int columnAt(double dx) {
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

  @override
  void performLayout() {
    final double width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : constraints.minWidth;
    size = constraints.constrain(Size(width, _extent));
    final double padding = theme.effectiveControlPadding;
    double cumulative = 0;
    for (int i = 0; i < childCount; i++) {
      final double columnWidth = i < _widths.length ? _widths[i] : 0;
      final RenderBox child = childAt(i);
      final double start = _textDirection.isRightToLeft
          ? size.width - cumulative - columnWidth
          : cumulative;
      cumulative += columnWidth;
      if (i == _editingColumn) {
        child.layout(BoxConstraints.tight(Size(columnWidth, _extent)),
            parentUsesSize: true);
        child.parentData!.offset = Offset(start, 0);
        continue;
      }
      final double cellWidth =
          (columnWidth - padding * 2).clamp(0.0, double.infinity);
      child.layout(
        BoxConstraints(maxWidth: cellWidth, maxHeight: _extent),
        parentUsesSize: true,
      );
      child.parentData!.offset = Offset(
        start + padding,
        ((_extent - child.size.height) / 2).roundToDouble().clamp(0.0, _extent),
      );
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
    // Rows are separated by a hairline rather than by alternating fills. Zebra
    // striping is a 1995 answer to rows too tight to tell apart; with a themed
    // row height the rule is enough, and it survives a selection painted over
    // it.
    if (_selected || (isHovered && enabled)) {
      paintFill(
        list,
        rect,
        _selected ? theme.selection : theme.hoverSurface,
      );
    }
    if (_dropTarget) {
      // The row a drop goes into: the accent, quietly - a fill and an
      // outline - so it reads as "here" over a selection too.
      paintFill(list, rect, theme.accentSubtle);
      paintRoundedBorder(list, rect.deflate(0.5), theme.accent, 2);
    }
    paintFill(
      list,
      Rect.fromLTWH(rect.left, rect.bottom - 1, rect.width, 1),
      theme.borderSubtle,
    );
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

  /// The body this row belongs to, found by walking up.
  RenderDataGridBody? get _body {
    RenderBox? node = parent;
    while (node != null) {
      if (node is RenderDataGridBody) return node;
      node = node.parent;
    }
    return null;
  }

  /// `activate` on a row is a plain click on it - no Shift, no Ctrl - so in
  /// `single` and `multiple` modes it becomes the selection, and in `none`
  /// it moves the cursor and selects nothing, exactly as the click would.
  /// Answered by the body because the row owns neither the selection nor
  /// the cursor; [ControlBehavior]'s empty `activate()` reported success
  /// here and selected nothing.
  @override
  bool performSemanticsAction(SemanticsAction action, {String? value}) {
    if (action == SemanticsAction.activate) {
      final RenderDataGridBody? body = _body;
      if (body == null || !body.enabled) return false;
      body.onRowPressed(_index, const <KeyModifier>{});
      return true;
    }
    return super.performSemanticsAction(action, value: value);
  }
}

// ---------------------------------------------------------------------------
// The body
// ---------------------------------------------------------------------------

final class _DataGridBodyWidget extends MultiChildRenderObjectWidget {
  const _DataGridBodyWidget({
    required this.live,
    required this.decorated,
    required this.position,
    required this.horizontal,
    required this.contentWidth,
    required this.textDirection,
    required this.focusNode,
    required this.theme,
    required this.virtualization,
    required this.range,
    required this.selectedCount,
    required this.cursor,
    required this.onKeyEvent,
    required this.onRowPressed,
    this.onRowClicked,
    required this.onViewportExtent,
    required super.children,
  });

  final _LiveColumnWidths live;
  final bool decorated;
  final ScrollPosition position;
  final ScrollPosition horizontal;
  final double contentWidth;
  final TextDirection textDirection;
  final FocusNode focusNode;
  final ThemeData theme;
  final ListVirtualization virtualization;
  final RealizedRange range;
  final int selectedCount;
  final int cursor;
  final bool Function(KeyEvent event) onKeyEvent;
  final void Function(int index, Set<KeyModifier> modifiers,
      {PointerButton button, int clickCount, int column}) onRowPressed;
  final void Function(double extent) onViewportExtent;
  final void Function(int index)? onRowClicked;

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
        onRowClicked: onRowClicked,
        onViewportExtent: onViewportExtent,
      )
        .._liveWidths = live
        ..decorated = decorated
        ..horizontal = horizontal
        ..contentWidth = contentWidth
        ..textDirection = textDirection
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
      ..onRowClicked = onRowClicked
      ..onViewportExtent = onViewportExtent
      .._liveWidths = live
      ..decorated = decorated
      ..horizontal = horizontal
      ..contentWidth = contentWidth
      ..textDirection = textDirection
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
    this.onRowClicked,
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
  void Function(int index, Set<KeyModifier> modifiers,
      {PointerButton button, int clickCount, int column}) onRowPressed;
  void Function(double extent) onViewportExtent;
  void Function(int index)? onRowClicked;
  Offset? _clickOrigin;
  int _clickRow = -1;

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

  /// The sideways scroll, over [contentWidth].
  ScrollPosition? get horizontal => _horizontal;
  ScrollPosition? _horizontal;

  set horizontal(ScrollPosition? value) {
    if (identical(value, _horizontal)) return;
    _horizontal?.removeListener(_onScrolled);
    _horizontal = value?..addListener(_onScrolled);
    markNeedsLayout();
  }

  /// The columns' total width; rows are never narrower than the body.
  double get contentWidth => _contentWidth;
  double _contentWidth = 0;

  set contentWidth(double value) {
    if (value == _contentWidth) return;
    _contentWidth = value;
    markNeedsLayout();
  }

  _LiveColumnWidths? _live;

  set _liveWidths(_LiveColumnWidths? value) {
    if (identical(value, _live)) return;
    if (owner != null && identical(_live?.body, this)) _live!.body = null;
    _live = value;
    if (owner != null) value?.body = this;
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _live?.body = this;
  }

  TextDirection get textDirection => _textDirection;
  TextDirection _textDirection = TextDirection.leftToRight;

  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
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
    _horizontal?.applyViewportGeometry(
      viewportExtent: width,
      contentExtent: _contentWidth,
    );

    // A row is as wide as the columns, and never narrower than the body; it
    // starts at the reading edge and slides by the sideways scroll.
    final double rowWidth = _contentWidth > width ? _contentWidth : width;
    final double scrolled = _horizontal?.pixels ?? 0;
    final double rowX =
        _textDirection.isRightToLeft ? width - rowWidth + scrolled : -scrolled;
    double cursorY = _range.leadingExtent - _position.pixels;
    for (int i = 0; i < childCount; i++) {
      final RenderBox child = childAt(i);
      child.layout(
        BoxConstraints(minWidth: rowWidth, maxWidth: rowWidth),
        parentUsesSize: true,
      );
      child.parentData!.offset = Offset(rowX, cursorY);
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
    final double radius = theme.cornerRadius;
    if (decorated) paintRoundedFill(list, rect, theme.surfaceAlternate, radius);
    list.save();
    list.clipRect(rect.left, rect.top, rect.right, rect.bottom);
    super.paint(list, offset);
    list.restore();
    if (!decorated) return;
    paintRoundedBorder(list, rect, theme.border, radius);
    paintFocusRing(list, rect, radius: radius);
  }

  /// See [DataGrid.decorated].
  bool get decorated => _decorated;
  bool _decorated = true;

  set decorated(bool value) {
    if (value == _decorated) return;
    _decorated = value;
    markNeedsPaint();
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
    if (event is PointerCancelEvent ||
        event is PointerMoveEvent &&
            _clickOrigin != null &&
            ((event.logicalPosition.dx - _clickOrigin!.dx).abs() > 5 ||
                (event.logicalPosition.dy - _clickOrigin!.dy).abs() > 5)) {
      _clickRow = -1;
      _clickOrigin = null;
    }
    if (event is PointerUpEvent && event.button == PointerButton.primary) {
      final row = _clickRow;
      _clickRow = -1;
      final origin = _clickOrigin;
      _clickOrigin = null;
      final y = globalToLocal(event.logicalPosition).dy + _position.pixels;
      if (row >= 0 &&
          origin != null &&
          _modifiers.isEmpty &&
          containsGlobalPoint(event.logicalPosition) &&
          (event.logicalPosition.dx - origin.dx).abs() <= 5 &&
          (event.logicalPosition.dy - origin.dy).abs() <= 5 &&
          y < _virtualization.totalExtent &&
          _virtualization.indexAt(y) == row) {
        onRowClicked?.call(row);
      }
      return;
    }
    if (event is PointerScrollEvent) {
      final bool lines = event.scrollDeltaUnit == ScrollDeltaUnit.lines;
      final ScrollPosition? horizontal = _horizontal;
      // Shift turns a plain wheel sideways, as in every desktop table; a
      // trackpad's sideways swipe arrives as dx on its own.
      final bool sideways = horizontal != null &&
          event.scrollDelta.dx == 0 &&
          _modifiers.contains(KeyModifier.shift);
      if (sideways) {
        horizontal.applyScrollDelta(event.scrollDelta.dy, inLines: lines);
        return;
      }
      if (horizontal != null && event.scrollDelta.dx != 0) {
        horizontal.applyScrollDelta(event.scrollDelta.dx, inLines: lines);
      }
      if (event.scrollDelta.dy != 0) {
        _position.applyScrollDelta(event.scrollDelta.dy, inLines: lines);
      }
      return;
    }
    if (event is PointerDownEvent) {
      final double contentY =
          globalToLocal(event.logicalPosition).dy + _position.pixels;
      // Past the last row is empty space, not the last row: `indexAt`
      // clamps.
      final int index = contentY >= _virtualization.totalExtent
          ? -1
          : _virtualization.indexAt(contentY);
      final bool onRow = index >= 0 && index < _virtualization.itemCount;
      _clickRow = onRow &&
              event.button == PointerButton.primary &&
              event.clickCount == 1 &&
              _modifiers.isEmpty
          ? index
          : -1;
      _clickOrigin = _clickRow >= 0 ? event.logicalPosition : null;
      onRowPressed(
        onRow ? index : -1,
        _modifiers,
        button: event.button,
        clickCount: event.clickCount,
        column: onRow ? _columnAt(index, event.logicalPosition) : -1,
      );
    }
  }

  /// The column of row [index] under [global], or -1.
  int _columnAt(int index, Offset global) {
    for (int i = 0; i < childCount; i++) {
      final RenderBox child = childAt(i);
      if (child is RenderDataGridRow && child.index == index) {
        return child.columnAt(child.globalToLocal(global).dx);
      }
    }
    return -1;
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

  /// `scrollUp`/`scrollDown` page the body; the answer is whether the
  /// position moved, which at either end it does not.
  @override
  bool performSemanticsAction(SemanticsAction action, {String? value}) {
    if (!enabled) return false;
    switch (action) {
      case SemanticsAction.scrollDown:
      case SemanticsAction.scrollUp:
        final double before = _position.pixels;
        _position.pageBy(action == SemanticsAction.scrollDown ? 1 : -1);
        return _position.pixels != before;
      default:
        return super.performSemanticsAction(action, value: value);
    }
  }

  void _onScrolled(ScrollPosition position) => markNeedsLayout();

  @override
  void detach() {
    _position.removeListener(_onScrolled);
    _horizontal?.removeListener(_onScrolled);
    if (identical(_live?.body, this)) _live!.body = null;
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

/// Whether two width lists hold the same values: a rebuild hands every row a
/// fresh list, and only a different width is a reason to lay out again.
bool _sameWidths(List<double> a, List<double> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The render objects a column drag changes, registered while attached.
///
/// The drag reaches them through this rather than through a rebuild: see
/// `_DataGridState._resizeColumn`.
final class _LiveColumnWidths {
  RenderDataGridHeader? header;
  RenderDataGridBody? body;
  final Set<RenderDataGridRow> rows = <RenderDataGridRow>{};

  void apply(List<double> widths) {
    header?.widths = widths;
    double total = 0;
    for (final double w in widths) {
      total += w;
    }
    body?.contentWidth = total;
    for (final RenderDataGridRow row in rows) {
      row.widths = widths;
    }
  }
}
