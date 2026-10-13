/// Table: column widths worked out together, rows as tall as their tallest
/// cell, alignment within a row, right to left, borders and row backgrounds.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(FrameworkFonts.install);
  tearDownAll(FontRegistry.instance.reset);

  late BuildOwner owner;

  RenderTable mount(Widget table, {double width = 300}) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(Size(width, 400)),
      ),
    )..updateRoot(Directionality(
        textDirection: TextDirection.leftToRight,
        child: Align(alignment: Alignment.topLeft, child: table),
      ));
    owner.buildScope();
    owner.pipelineOwner.drawFrame(DisplayList());
    RenderTable? found;
    void walk(RenderBox node) {
      if (node is RenderTable) found = node;
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found!;
  }

  tearDown(() => owner.dispose());

  test('fixed columns keep their width; flexible ones share the rest', () {
    final RenderTable table = mount(const Table(
      columnWidths: <int, TableColumnWidth>{
        0: FixedColumnWidth(60),
        2: FlexColumnWidth(2),
      },
      children: <TableRow>[
        TableRow(children: <Widget>[
          SizedBox(height: 10),
          SizedBox(height: 10),
          SizedBox(height: 10),
        ]),
      ],
    ));
    expect(table.columnWidthsLaidOut, <double>[60, 80, 160]);
    expect(table.size.width, 300);
    expect(table.cellAt(0, 2).offsetFromParent.dx, 140);
  });

  test('an intrinsic column is as wide as its widest cell', () {
    final RenderTable table = mount(const Table(
      columnWidths: <int, TableColumnWidth>{0: IntrinsicColumnWidth()},
      children: <TableRow>[
        TableRow(children: <Widget>[SizedBox(width: 40), SizedBox()]),
        TableRow(children: <Widget>[SizedBox(width: 90), SizedBox()]),
      ],
    ));
    expect(table.columnWidthsLaidOut, <double>[90, 210]);
  });

  test('a fraction is of the table; max and min pick between two', () {
    final RenderTable table = mount(const Table(
      columnWidths: <int, TableColumnWidth>{
        0: FractionColumnWidth(0.25),
        1: MaxColumnWidth(FixedColumnWidth(50), FractionColumnWidth(0.1)),
        2: MinColumnWidth(FixedColumnWidth(50), FractionColumnWidth(0.1)),
      },
      defaultColumnWidth: FixedColumnWidth(10),
      children: <TableRow>[
        TableRow(children: <Widget>[SizedBox(), SizedBox(), SizedBox()]),
      ],
    ));
    expect(table.columnWidthsLaidOut, <double>[75, 50, 30]);
    expect(table.size.width, 155, reason: 'no flex: the columns, no more');
  });

  test('a row is as tall as its tallest cell; cells align within it', () {
    final RenderTable table = mount(const Table(
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: <TableRow>[
        TableRow(children: <Widget>[
          SizedBox(height: 40),
          SizedBox(height: 10),
          TableCell(
            verticalAlignment: TableCellVerticalAlignment.bottom,
            child: SizedBox(height: 10),
          ),
          TableCell(
            verticalAlignment: TableCellVerticalAlignment.fill,
            child: SizedBox(height: 10),
          ),
        ]),
        TableRow(children: <Widget>[
          SizedBox(height: 20),
          SizedBox(height: 20),
          SizedBox(height: 20),
          SizedBox(height: 20),
        ]),
      ],
    ));
    expect(table.rowEdges, <double>[0, 40, 60]);
    expect(table.cellAt(0, 1).offsetFromParent.dy, 15, reason: 'middle');
    expect(table.cellAt(0, 2).offsetFromParent.dy, 30, reason: 'bottom');
    expect(table.cellAt(0, 3).size.height, 40, reason: 'fill');
    expect(table.cellAt(1, 0).offsetFromParent.dy, 40);
    expect(table.size.height, 60);
  });

  test('right to left, the first column is on the right', () {
    final RenderTable table = mount(const Table(
      textDirection: TextDirection.rightToLeft,
      columnWidths: <int, TableColumnWidth>{0: FixedColumnWidth(100)},
      children: <TableRow>[
        TableRow(children: <Widget>[SizedBox(), SizedBox()]),
      ],
    ));
    expect(table.cellAt(0, 0).offsetFromParent.dx, 200);
    expect(table.cellAt(0, 1).offsetFromParent.dx, 0);
  });

  test('too wide, the flexible columns give way first, then the others', () {
    RenderTable table = mount(
      const Table(
        columnWidths: <int, TableColumnWidth>{
          0: FixedColumnWidth(120),
          1: IntrinsicColumnWidth(flex: 1),
        },
        children: <TableRow>[
          TableRow(children: <Widget>[
            SizedBox(),
            Text('alpha beta gamma delta epsilon', softWrap: true),
          ]),
        ],
      ),
      width: 200,
    );
    // The text wants a line and can wrap down to its longest word; the
    // fixed column cannot give at all.
    expect(table.columnWidthsLaidOut, <double>[120, 80]);
    owner.dispose();

    table = mount(
      const Table(
        defaultColumnWidth: IntrinsicColumnWidth(),
        children: <TableRow>[
          TableRow(children: <Widget>[
            Text('one two three four five six seven', softWrap: true),
            Text('eight nine ten eleven twelve thirteen', softWrap: true),
          ]),
        ],
      ),
      width: 200,
    );
    expect(table.columnWidthsLaidOut.reduce((double a, double b) => a + b), 200,
        reason: 'nothing flexes: both shrink');
  });

  test('a short row is padded with empty cells', () {
    final RenderTable table = mount(const Table(
      children: <TableRow>[
        TableRow(children: <Widget>[SizedBox(), SizedBox(), SizedBox()]),
        TableRow(children: <Widget>[SizedBox(height: 12)]),
      ],
    ));
    expect(table.columns, 3);
    expect(table.rows, 2);
    expect(table.childCount, 6);
  });

  test('borders and row backgrounds are painted', () {
    int commands(Widget table) {
      mount(table);
      final DisplayList list = DisplayList();
      owner.pipelineOwner.drawFrame(list);
      final int count = list.commandCount;
      owner.dispose();
      return count;
    }

    TableRow row([BoxDecoration? decoration]) => TableRow(
          decoration: decoration,
          children: const <Widget>[
            SizedBox(height: 10),
            SizedBox(height: 10),
          ],
        );

    final int plain = commands(Table(children: <TableRow>[row(), row()]));
    final int bordered = commands(Table(
      border: TableBorder.all(),
      children: <TableRow>[row(), row()],
    ));
    // Four outside lines, one between the rows, one between the columns.
    expect(bordered - plain, 6);
    final int striped = commands(Table(children: <TableRow>[
      row(const BoxDecoration(color: Color(0xFFEEEEEE))),
      row(),
    ]));
    expect(striped - plain, 1);
    // For tearDown, which disposes the last owner.
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
          rootConstraints: BoxConstraints.tight(const Size(1, 1))),
    );
  });
}
