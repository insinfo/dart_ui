/// Rows of cells whose columns line up: Flutter's `Table`, `TableRow` and
/// `TableCell`. See `layout/render_table.dart` for how column widths are
/// worked out.
///
/// ```dart
/// Table(
///   columnWidths: const <int, TableColumnWidth>{0: IntrinsicColumnWidth()},
///   border: TableBorder.symmetric(inside: BorderSide(color: line)),
///   children: <TableRow>[
///     TableRow(children: <Widget>[Text('Name'), TextField(controller: name)]),
///     TableRow(children: <Widget>[Text('E-mail'), TextField(controller: mail)]),
///   ],
/// )
/// ```
library;

import '../layout/render_proxy_box.dart' show BoxDecoration;
import '../layout/render_table.dart';
import '../text/shaper.dart' show TextDirection;
import 'basic.dart' show SizedBox;
import 'directionality.dart';
import 'element.dart';
import 'widget.dart';

/// One row of a [Table]: its cells, left to right in reading order, and an
/// optional background.
final class TableRow {
  const TableRow({this.key, this.decoration, this.children = const <Widget>[]});

  final Key? key;

  /// Painted behind the row's cells; only its colour is used.
  final BoxDecoration? decoration;

  final List<Widget> children;
}

/// A table of [children] rows.
///
/// A row shorter than the longest is padded with empty cells, where Flutter
/// would assert: a missing cell is a typo, not a reason to lose the table.
final class Table extends StatelessWidget {
  const Table({
    super.key,
    this.children = const <TableRow>[],
    this.columnWidths,
    this.defaultColumnWidth = const FlexColumnWidth(),
    this.textDirection,
    this.border,
    this.defaultVerticalAlignment = TableCellVerticalAlignment.top,
  });

  final List<TableRow> children;

  /// Widths by column index; the rest take [defaultColumnWidth].
  final Map<int, TableColumnWidth>? columnWidths;
  final TableColumnWidth defaultColumnWidth;

  /// Which way the columns run; the ambient [Directionality] when null.
  final TextDirection? textDirection;

  final TableBorder? border;
  final TableCellVerticalAlignment defaultVerticalAlignment;

  @override
  Widget build(BuildContext context) {
    int columns = 0;
    for (final TableRow row in children) {
      if (row.children.length > columns) columns = row.children.length;
    }
    return _TableRenderWidget(
      columns: columns,
      columnWidths: columnWidths,
      defaultColumnWidth: defaultColumnWidth,
      textDirection: textDirection ??
          Directionality.maybeOf(context) ??
          TextDirection.leftToRight,
      border: border,
      rowDecorations: <BoxDecoration?>[
        for (final TableRow row in children) row.decoration,
      ],
      defaultVerticalAlignment: defaultVerticalAlignment,
      children: <Widget>[
        for (final TableRow row in children) ...<Widget>[
          ...row.children,
          for (int i = row.children.length; i < columns; i++) const SizedBox(),
        ],
      ],
    );
  }
}

final class _TableRenderWidget extends MultiChildRenderObjectWidget {
  const _TableRenderWidget({
    required this.columns,
    required this.columnWidths,
    required this.defaultColumnWidth,
    required this.textDirection,
    required this.border,
    required this.rowDecorations,
    required this.defaultVerticalAlignment,
    required super.children,
  });

  final int columns;
  final Map<int, TableColumnWidth>? columnWidths;
  final TableColumnWidth defaultColumnWidth;
  final TextDirection textDirection;
  final TableBorder? border;
  final List<BoxDecoration?> rowDecorations;
  final TableCellVerticalAlignment defaultVerticalAlignment;

  @override
  RenderTable createRenderObject(BuildContext context) => RenderTable(
        columns: columns,
        columnWidths: columnWidths,
        defaultColumnWidth: defaultColumnWidth,
        textDirection: textDirection,
        border: border,
        rowDecorations: rowDecorations,
        defaultVerticalAlignment: defaultVerticalAlignment,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderTable renderObject,
  ) {
    renderObject
      ..columns = columns
      ..columnWidths = columnWidths
      ..defaultColumnWidth = defaultColumnWidth
      ..textDirection = textDirection
      ..border = border
      ..rowDecorations = rowDecorations
      ..defaultVerticalAlignment = defaultVerticalAlignment;
  }
}

/// Sets how one cell sits in a row taller than it.
final class TableCell extends ParentDataWidget<TableCellParentData> {
  const TableCell({super.key, this.verticalAlignment, required super.child});

  /// Null for the table's default.
  final TableCellVerticalAlignment? verticalAlignment;

  @override
  Type get typicalAncestorWidget => Table;

  @override
  bool applyParentData(TableCellParentData parentData) {
    if (parentData.verticalAlignment == verticalAlignment) return false;
    parentData.verticalAlignment = verticalAlignment;
    return true;
  }
}
