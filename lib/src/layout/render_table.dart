/// A grid of cells in rows and columns whose widths are worked out together:
/// Flutter's `RenderTable`, with its column-width vocabulary.
///
/// A [Row] of [Column]s cannot line up the cells of different rows, and a
/// `DataGrid` is a virtualized, selectable control - too much for a form's
/// labels and fields, a key/value summary or a small comparison. This is the
/// table those want: every row as tall as its tallest cell, every column as
/// wide as its [TableColumnWidth] says, borders and row backgrounds.
///
/// ## Column widths
///
/// Each column asks its [TableColumnWidth] for a minimum and a maximum
/// intrinsic width over its cells, and for a flex factor:
///
///   1. every column starts at its maximum intrinsic width - a
///      [FlexColumnWidth]'s is zero;
///   2. when the table has a bounded width and some columns flex, what is
///      left is shared among them by their factors;
///   3. when the columns are still wider than the table may be, the flexible
///      ones give way first, down to their minimum, and then the rest,
///      in proportion to what each can give.
///
/// The result never asks a cell to be narrower than zero; a table whose
/// columns cannot fit at their minimum overflows like a [RenderFlex] does,
/// visibly, rather than clipping.
library;

import 'dart:math' as math;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/color.dart';
import '../graphics/display_list.dart';
import '../graphics/display_list_geometry.dart';
import '../text/shaper.dart' show TextDirection;
import 'borders.dart' show BorderSide;
import 'box_constraints.dart';
import 'render_box.dart';
import 'render_proxy_box.dart' show BoxDecoration;

// BorderSide moved to borders.dart with the rest of Flutter's border types;
// re-exported so `render_table.dart show BorderSide` keeps resolving.
export 'borders.dart' show BorderSide, BorderStyle;

/// How wide a table column is.
abstract class TableColumnWidth {
  const TableColumnWidth();

  /// The narrowest this column can be with its [cells] still readable.
  double minIntrinsicWidth(List<RenderBox> cells, double containerWidth);

  /// The width this column wants, given room.
  double maxIntrinsicWidth(List<RenderBox> cells, double containerWidth);

  /// The column's share of leftover width, or null for none.
  double? flex(List<RenderBox> cells) => null;
}

/// Exactly [value] logical pixels.
final class FixedColumnWidth extends TableColumnWidth {
  const FixedColumnWidth(this.value);

  final double value;

  @override
  double minIntrinsicWidth(List<RenderBox> cells, double containerWidth) =>
      value;

  @override
  double maxIntrinsicWidth(List<RenderBox> cells, double containerWidth) =>
      value;

  @override
  String toString() => 'FixedColumnWidth($value)';
}

/// [value] of the table's width: 0.5 is half. Zero in a table of unbounded
/// width, where a fraction has nothing to be a fraction of.
final class FractionColumnWidth extends TableColumnWidth {
  const FractionColumnWidth(this.value);

  final double value;

  double _of(double containerWidth) =>
      containerWidth.isFinite ? value * containerWidth : 0;

  @override
  double minIntrinsicWidth(List<RenderBox> cells, double containerWidth) =>
      _of(containerWidth);

  @override
  double maxIntrinsicWidth(List<RenderBox> cells, double containerWidth) =>
      _of(containerWidth);

  @override
  String toString() => 'FractionColumnWidth($value)';
}

/// A share, by [value], of what the other columns leave - the default.
final class FlexColumnWidth extends TableColumnWidth {
  const FlexColumnWidth([this.value = 1.0]);

  final double value;

  @override
  double minIntrinsicWidth(List<RenderBox> cells, double containerWidth) => 0;

  @override
  double maxIntrinsicWidth(List<RenderBox> cells, double containerWidth) => 0;

  @override
  double? flex(List<RenderBox> cells) => value;

  @override
  String toString() => 'FlexColumnWidth($value)';
}

/// As wide as the widest cell wants to be; with [flex], also a share of the
/// leftover width on top of that.
///
/// It measures every cell of the column, so a long table of these costs a
/// pass over all of its cells - the price Flutter documents too.
final class IntrinsicColumnWidth extends TableColumnWidth {
  const IntrinsicColumnWidth({double? flex}) : _flex = flex;

  final double? _flex;

  @override
  double minIntrinsicWidth(List<RenderBox> cells, double containerWidth) {
    double result = 0;
    for (final RenderBox cell in cells) {
      result = math.max(result, cell.getMinIntrinsicWidth(double.infinity));
    }
    return result;
  }

  @override
  double maxIntrinsicWidth(List<RenderBox> cells, double containerWidth) {
    double result = 0;
    for (final RenderBox cell in cells) {
      result = math.max(result, cell.getMaxIntrinsicWidth(double.infinity));
    }
    return result;
  }

  @override
  double? flex(List<RenderBox> cells) => _flex;

  @override
  String toString() => 'IntrinsicColumnWidth(flex: $_flex)';
}

/// The larger of two widths: "at least 100, more if the text needs it".
final class MaxColumnWidth extends TableColumnWidth {
  const MaxColumnWidth(this.a, this.b);

  final TableColumnWidth a;
  final TableColumnWidth b;

  @override
  double minIntrinsicWidth(List<RenderBox> cells, double containerWidth) =>
      math.max(a.minIntrinsicWidth(cells, containerWidth),
          b.minIntrinsicWidth(cells, containerWidth));

  @override
  double maxIntrinsicWidth(List<RenderBox> cells, double containerWidth) =>
      math.max(a.maxIntrinsicWidth(cells, containerWidth),
          b.maxIntrinsicWidth(cells, containerWidth));

  @override
  double? flex(List<RenderBox> cells) {
    final double? fa = a.flex(cells);
    final double? fb = b.flex(cells);
    if (fa == null) return fb;
    if (fb == null) return fa;
    return math.max(fa, fb);
  }
}

/// The smaller of two widths: "a third of the table, but no more than 200".
final class MinColumnWidth extends TableColumnWidth {
  const MinColumnWidth(this.a, this.b);

  final TableColumnWidth a;
  final TableColumnWidth b;

  @override
  double minIntrinsicWidth(List<RenderBox> cells, double containerWidth) =>
      math.min(a.minIntrinsicWidth(cells, containerWidth),
          b.minIntrinsicWidth(cells, containerWidth));

  @override
  double maxIntrinsicWidth(List<RenderBox> cells, double containerWidth) =>
      math.min(a.maxIntrinsicWidth(cells, containerWidth),
          b.maxIntrinsicWidth(cells, containerWidth));

  @override
  double? flex(List<RenderBox> cells) {
    final double? fa = a.flex(cells);
    final double? fb = b.flex(cells);
    if (fa == null) return fb;
    if (fb == null) return fa;
    return math.min(fa, fb);
  }
}

/// Where a cell shorter than its row sits in it.
enum TableCellVerticalAlignment {
  top,
  middle,
  bottom,

  /// Stretched to the row's height: a cell with a background.
  fill,
}

/// The lines a table draws: around it and between its rows and columns.
///
/// Drawn over the cells and centred on the edges between them, as Flutter's
/// is; the outer lines inset by half their width so they stay inside the
/// table's box.
final class TableBorder {
  const TableBorder({
    this.top = BorderSide.none,
    this.right = BorderSide.none,
    this.bottom = BorderSide.none,
    this.left = BorderSide.none,
    this.horizontalInside = BorderSide.none,
    this.verticalInside = BorderSide.none,
  });

  /// The same line everywhere.
  factory TableBorder.all({
    Color color = const Color(0xFF000000),
    double width = 1.0,
  }) {
    final BorderSide side = BorderSide(color: color, width: width);
    return TableBorder(
      top: side,
      right: side,
      bottom: side,
      left: side,
      horizontalInside: side,
      verticalInside: side,
    );
  }

  /// [inside] between the cells, [outside] around them.
  const TableBorder.symmetric({
    BorderSide inside = BorderSide.none,
    BorderSide outside = BorderSide.none,
  })  : top = outside,
        right = outside,
        bottom = outside,
        left = outside,
        horizontalInside = inside,
        verticalInside = inside;

  final BorderSide top;
  final BorderSide right;
  final BorderSide bottom;
  final BorderSide left;
  final BorderSide horizontalInside;
  final BorderSide verticalInside;

  @override
  bool operator ==(Object other) =>
      other is TableBorder &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom &&
      other.left == left &&
      other.horizontalInside == horizontalInside &&
      other.verticalInside == verticalInside;

  @override
  int get hashCode =>
      Object.hash(top, right, bottom, left, horizontalInside, verticalInside);
}

/// What a table cell tells its table.
final class TableCellParentData extends BoxParentData {
  /// Null for the table's default.
  TableCellVerticalAlignment? verticalAlignment;

  @override
  String toString() =>
      'TableCellParentData(offset: $offset, $verticalAlignment)';
}

/// Lays its children out as [columns] cells per row, in row order.
final class RenderTable extends RenderBoxContainer<TableCellParentData> {
  RenderTable({
    int columns = 0,
    Map<int, TableColumnWidth>? columnWidths,
    TableColumnWidth defaultColumnWidth = const FlexColumnWidth(),
    TextDirection textDirection = TextDirection.leftToRight,
    TableBorder? border,
    List<BoxDecoration?> rowDecorations = const <BoxDecoration?>[],
    TableCellVerticalAlignment defaultVerticalAlignment =
        TableCellVerticalAlignment.top,
  })  : _columns = columns,
        _columnWidths = columnWidths ?? const <int, TableColumnWidth>{},
        _defaultColumnWidth = defaultColumnWidth,
        _textDirection = textDirection,
        _border = border,
        _rowDecorations = rowDecorations,
        _defaultVerticalAlignment = defaultVerticalAlignment;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! TableCellParentData) {
      child.parentData = TableCellParentData();
    }
  }

  int get columns => _columns;
  int _columns;

  set columns(int value) {
    if (value == _columns) return;
    _columns = value;
    markNeedsLayout();
  }

  int get rows => _columns == 0 ? 0 : childCount ~/ _columns;

  Map<int, TableColumnWidth> get columnWidths => _columnWidths;
  Map<int, TableColumnWidth> _columnWidths;

  set columnWidths(Map<int, TableColumnWidth>? value) {
    _columnWidths = value ?? const <int, TableColumnWidth>{};
    markNeedsLayout();
  }

  TableColumnWidth get defaultColumnWidth => _defaultColumnWidth;
  TableColumnWidth _defaultColumnWidth;

  set defaultColumnWidth(TableColumnWidth value) {
    if (identical(value, _defaultColumnWidth)) return;
    _defaultColumnWidth = value;
    markNeedsLayout();
  }

  TextDirection get textDirection => _textDirection;
  TextDirection _textDirection;

  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  TableBorder? get border => _border;
  TableBorder? _border;

  set border(TableBorder? value) {
    if (value == _border) return;
    _border = value;
    markNeedsPaint();
  }

  /// Each row's background, by row; shorter than the rows is fine.
  List<BoxDecoration?> get rowDecorations => _rowDecorations;
  List<BoxDecoration?> _rowDecorations;

  set rowDecorations(List<BoxDecoration?> value) {
    _rowDecorations = value;
    markNeedsPaint();
  }

  TableCellVerticalAlignment get defaultVerticalAlignment =>
      _defaultVerticalAlignment;
  TableCellVerticalAlignment _defaultVerticalAlignment;

  set defaultVerticalAlignment(TableCellVerticalAlignment value) {
    if (value == _defaultVerticalAlignment) return;
    _defaultVerticalAlignment = value;
    markNeedsLayout();
  }

  /// The width of each column, as of the last layout.
  List<double> get columnWidthsLaidOut => List<double>.unmodifiable(_widths);
  List<double> _widths = const <double>[];

  /// The top of each row and the bottom of the last, as of the last layout.
  List<double> get rowEdges => List<double>.unmodifiable(_rowTops);
  List<double> _rowTops = const <double>[];

  /// The x of each column's left edge, as of the last layout.
  List<double> _columnLefts = const <double>[];

  RenderBox cellAt(int row, int column) => childAt(row * _columns + column);

  List<RenderBox> _cellsOf(int column) => <RenderBox>[
        for (int row = 0; row < rows; row++) cellAt(row, column),
      ];

  TableColumnWidth _specFor(int column) =>
      _columnWidths[column] ?? _defaultColumnWidth;

  /// The widths [constraints] give, by the steps the library doc lists.
  List<double> _computeWidths(BoxConstraints constraints) {
    final double maxWidth = constraints.maxWidth;
    final List<double> widths = List<double>.filled(_columns, 0);
    final List<double> minWidths = List<double>.filled(_columns, 0);
    final List<double?> flexes = List<double?>.filled(_columns, null);
    double tableWidth = 0;
    double totalFlex = 0;
    for (int c = 0; c < _columns; c++) {
      final TableColumnWidth spec = _specFor(c);
      final List<RenderBox> cells = _cellsOf(c);
      final double min = spec.minIntrinsicWidth(cells, maxWidth);
      final double max = math.max(min, spec.maxIntrinsicWidth(cells, maxWidth));
      widths[c] = max;
      minWidths[c] = min;
      tableWidth += max;
      final double? flex = spec.flex(cells);
      if (flex != null && flex > 0) {
        flexes[c] = flex;
        totalFlex += flex;
      }
    }
    // Share what is left among the flexible columns - to fill the table's
    // bounded width, or to reach its minimum width when that is unbounded.
    final double target = maxWidth.isFinite ? maxWidth : constraints.minWidth;
    if (totalFlex > 0 && tableWidth < target) {
      final double remaining = target - tableWidth;
      for (int c = 0; c < _columns; c++) {
        final double? flex = flexes[c];
        if (flex == null) continue;
        final double share = remaining * flex / totalFlex;
        widths[c] += share;
        tableWidth += share;
      }
    } else if (tableWidth < constraints.minWidth) {
      // No flex: widen every column alike to the minimum.
      final double each = (constraints.minWidth - tableWidth) / _columns;
      for (int c = 0; c < _columns; c++) {
        widths[c] += each;
      }
      tableWidth = constraints.minWidth;
    }
    if (maxWidth.isFinite && tableWidth > maxWidth) {
      // Flexible columns give way first, then everyone, each down to its
      // minimum and in proportion to what it can give.
      for (final bool flexibleOnly in <bool>[true, false]) {
        double excess = tableWidth - maxWidth;
        if (excess <= 0) break;
        double available = 0;
        for (int c = 0; c < _columns; c++) {
          if (flexibleOnly && flexes[c] == null) continue;
          available += widths[c] - minWidths[c];
        }
        if (available <= 0) continue;
        final double take = math.min(excess, available);
        for (int c = 0; c < _columns; c++) {
          if (flexibleOnly && flexes[c] == null) continue;
          final double give = (widths[c] - minWidths[c]) / available * take;
          widths[c] -= give;
          tableWidth -= give;
        }
        excess -= take;
      }
    }
    return widths;
  }

  TableCellVerticalAlignment _alignmentOf(RenderBox cell) =>
      (cell.parentData! as TableCellParentData).verticalAlignment ??
      _defaultVerticalAlignment;

  @override
  void performLayout() {
    if (_columns == 0 || childCount == 0) {
      _widths = const <double>[];
      _rowTops = const <double>[0];
      _columnLefts = const <double>[];
      size = constraints.constrain(Size.zero);
      return;
    }
    final List<double> widths = _computeWidths(constraints);
    final double tableWidth = widths.fold(0.0, (double a, double b) => a + b);
    final double width = constraints.constrainWidth(tableWidth);
    final bool rtl = _textDirection.isRightToLeft;
    final List<double> lefts = List<double>.filled(_columns, 0);
    double x = rtl ? width : 0;
    for (int c = 0; c < _columns; c++) {
      if (rtl) {
        x -= widths[c];
        lefts[c] = x;
      } else {
        lefts[c] = x;
        x += widths[c];
      }
    }
    final List<double> tops = List<double>.filled(rows + 1, 0);
    double y = 0;
    for (int r = 0; r < rows; r++) {
      tops[r] = y;
      double height = 0;
      // Measured first; a filling cell takes the row's height afterwards.
      for (int c = 0; c < _columns; c++) {
        final RenderBox cell = cellAt(r, c);
        if (_alignmentOf(cell) == TableCellVerticalAlignment.fill) continue;
        cell.layout(BoxConstraints.tightFor(width: widths[c]),
            parentUsesSize: true);
        height = math.max(height, cell.size.height);
      }
      for (int c = 0; c < _columns; c++) {
        final RenderBox cell = cellAt(r, c);
        final TableCellVerticalAlignment alignment = _alignmentOf(cell);
        if (alignment == TableCellVerticalAlignment.fill) {
          cell.layout(BoxConstraints.tight(Size(widths[c], height)),
              parentUsesSize: true);
        }
        final double slack = height - cell.size.height;
        final double dy = switch (alignment) {
          TableCellVerticalAlignment.top ||
          TableCellVerticalAlignment.fill =>
            0,
          TableCellVerticalAlignment.middle => (slack / 2).roundToDouble(),
          TableCellVerticalAlignment.bottom => slack,
        };
        cell.parentData!.offset = Offset(lefts[c], y + dy);
      }
      y += height;
    }
    tops[rows] = y;
    _widths = widths;
    _columnLefts = lefts;
    _rowTops = tops;
    size = constraints.constrain(Size(width, y));
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    double total = 0;
    for (int c = 0; c < _columns; c++) {
      total += _specFor(c).minIntrinsicWidth(_cellsOf(c), double.infinity);
    }
    return total;
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    double total = 0;
    for (int c = 0; c < _columns; c++) {
      total += _specFor(c).maxIntrinsicWidth(_cellsOf(c), double.infinity);
    }
    return total;
  }

  @override
  double computeMinIntrinsicHeight(double width) {
    if (_columns == 0) return 0;
    final List<double> widths = _computeWidths(BoxConstraints(maxWidth: width));
    double total = 0;
    for (int r = 0; r < rows; r++) {
      double height = 0;
      for (int c = 0; c < _columns; c++) {
        height =
            math.max(height, cellAt(r, c).getMinIntrinsicHeight(widths[c]));
      }
      total += height;
    }
    return total;
  }

  @override
  double computeMaxIntrinsicHeight(double width) =>
      computeMinIntrinsicHeight(width);

  @override
  void paint(DisplayList list, Offset offset) {
    if (rows == 0) return;
    for (int r = 0; r < rows && r < _rowDecorations.length; r++) {
      final Color? fill = _rowDecorations[r]?.color;
      if (fill == null) continue;
      list.drawRectangle(
        Rect.fromLTRB(offset.dx, offset.dy + _rowTops[r],
            offset.dx + size.width, offset.dy + _rowTops[r + 1]),
        list.addPaint(colorArgb: fill.value),
      );
    }
    super.paint(list, offset);
    final TableBorder? border = _border;
    if (border != null) _paintBorder(list, offset, border);
  }

  void _paintBorder(DisplayList list, Offset offset, TableBorder border) {
    final double left = offset.dx;
    final double top = offset.dy;
    final double right = offset.dx + size.width;
    final double bottom = offset.dy + size.height;
    void line(BorderSide side, double x0, double y0, double x1, double y1) {
      if (!side.isVisible) return;
      list.drawRectangle(Rect.fromLTRB(x0, y0, x1, y1),
          list.addPaint(colorArgb: side.color.value));
    }

    final BorderSide inH = border.horizontalInside;
    for (int r = 1; r < rows; r++) {
      final double y = top + _rowTops[r];
      line(inH, left, y - inH.width / 2, right, y + inH.width / 2);
    }
    final BorderSide inV = border.verticalInside;
    for (int c = 0; c < _columns; c++) {
      // The edge between this column and the one after it in reading order.
      if (c == _columns - 1) break;
      final double x = offset.dx +
          (_textDirection.isRightToLeft
              ? _columnLefts[c]
              : _columnLefts[c] + _widths[c]);
      line(inV, x - inV.width / 2, top, x + inV.width / 2, bottom);
    }
    line(border.top, left, top, right, top + border.top.width);
    line(border.bottom, left, bottom - border.bottom.width, right, bottom);
    line(border.left, left, top, left + border.left.width, bottom);
    line(border.right, right - border.right.width, top, right, bottom);
  }
}
