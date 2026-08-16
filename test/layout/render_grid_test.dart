/// Grid track sizing, placement, spans and gaps - section 25.4.
///
/// Every assertion here is a number. "It did not throw" would pass for a grid
/// that put every child at the origin.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  RenderGrid laidOut(RenderGrid grid, BoxConstraints constraints) {
    final owner = PipelineOwner(rootConstraints: constraints);
    owner.root = grid;
    owner.flushLayout();
    return grid;
  }

  BoxConstraints loose(double width, double height) =>
      BoxConstraints.loose(Size(width, height));

  group('fixed tracks', () {
    test('take exactly their declared extent, whatever is in them', () {
      final a = MeasuredBox(const Size(200, 10));
      final b = MeasuredBox(const Size(2, 14));
      final grid = RenderGrid(
        columns: <GridTrack>[GridTrack.fixed(30), GridTrack.fixed(50)],
      )
        ..add(a)
        ..add(b);

      laidOut(grid, loose(500, 500));

      expect(grid.columnSizes, <double>[30, 50]);
      // One implicit auto row, as tall as the taller cell's content.
      expect(grid.rowSizes, <double>[14]);
      expect(grid.size, const Size(80, 14));
      expect(a.offsetFromParent, Offset.zero);
      expect(b.offsetFromParent, const Offset(30, 0));
      // GridFit.stretch: the cell is a tight constraint.
      expect(a.size, const Size(30, 14));
      expect(b.size, const Size(50, 14));
    });

    test('gaps sit between tracks and not at the ends', () {
      final grid = RenderGrid(
        columns: <GridTrack>[
          GridTrack.fixed(20),
          GridTrack.fixed(20),
          GridTrack.fixed(20),
        ],
        columnGap: 7,
      );
      for (int i = 0; i < 3; i++) {
        grid.add(MeasuredBox(const Size(5, 5)));
      }

      laidOut(grid, loose(500, 500));

      expect(grid.size.width, 20 * 3 + 7 * 2);
      expect(grid.childAt(0).offsetFromParent.dx, 0);
      expect(grid.childAt(1).offsetFromParent.dx, 27);
      expect(grid.childAt(2).offsetFromParent.dx, 54);
    });
  });

  group('fractional tracks', () {
    test('split the leftover space', () {
      final grid = RenderGrid(
        columns: <GridTrack>[GridTrack.fixed(40), GridTrack.fraction()],
      )
        ..add(MeasuredBox(const Size(5, 5)))
        ..add(MeasuredBox(const Size(5, 5)));

      laidOut(grid, BoxConstraints.tightFor(width: 100));

      expect(grid.columnSizes, <double>[40, 60]);
      expect(grid.childAt(1).offsetFromParent.dx, 40);
    });

    test('the last one absorbs a division that does not come out even', () {
      // 100 over three equal shares. The documented policy: every track but the
      // last takes its exact share, the last takes what is left of the budget.
      final grid = RenderGrid(
        columns: <GridTrack>[
          GridTrack.fraction(),
          GridTrack.fraction(),
          GridTrack.fraction(),
        ],
      );
      for (int i = 0; i < 3; i++) {
        grid.add(MeasuredBox(const Size(5, 5)));
      }

      laidOut(grid, BoxConstraints.tightFor(width: 100));

      const double share = 100 / 3;
      expect(grid.columnSizes[0], share);
      expect(grid.columnSizes[1], share);
      expect(grid.columnSizes[2], 100 - (share + share));
      // The point of the policy: the tracks add up to the width exactly, so
      // there is no sliver of background down the right edge.
      expect(
        grid.columnSizes[0] + grid.columnSizes[1] + grid.columnSizes[2],
        100.0,
      );
      expect(grid.size.width, 100.0);
      expect(grid.childAt(0).offsetFromParent.dx, 0.0);
      expect(grid.childAt(1).offsetFromParent.dx, share);
      expect(grid.childAt(2).offsetFromParent.dx, share + share);
    });

    test('weights divide the leftover in proportion', () {
      final grid = RenderGrid(
        columns: <GridTrack>[GridTrack.fraction(3), GridTrack.fraction(1)],
      )
        ..add(MeasuredBox(const Size(5, 5)))
        ..add(MeasuredBox(const Size(5, 5)));

      laidOut(grid, BoxConstraints.tightFor(width: 80));

      expect(grid.columnSizes, <double>[60, 20]);
    });

    test('get nothing to divide on an unbounded axis', () {
      final grid = RenderGrid(
        columns: <GridTrack>[GridTrack.fixed(30), GridTrack.fraction()],
      )
        ..add(MeasuredBox(const Size(5, 5)))
        ..add(MeasuredBox(const Size(5, 5)));

      laidOut(grid, BoxConstraints());

      expect(grid.columnSizes, <double>[30, 0]);
      expect(grid.size.width, 30);
    });
  });

  group('minmax', () {
    test('a floor bigger than its share freezes and the rest re-divide', () {
      final grid = RenderGrid(
        columns: <GridTrack>[
          GridTrack.minmax(GridTrack.fixed(70), GridTrack.fraction()),
          GridTrack.fraction(),
        ],
      )
        ..add(MeasuredBox(const Size(5, 5)))
        ..add(MeasuredBox(const Size(5, 5)));

      laidOut(grid, BoxConstraints.tightFor(width: 100));

      // Not 70 + half of the rest: the floor is a floor, not an addition.
      expect(grid.columnSizes, <double>[70, 30]);
    });

    test('a floor smaller than its share does not distort the division', () {
      final grid = RenderGrid(
        columns: <GridTrack>[
          GridTrack.minmax(GridTrack.fixed(20), GridTrack.fraction()),
          GridTrack.fraction(),
        ],
      )
        ..add(MeasuredBox(const Size(5, 5)))
        ..add(MeasuredBox(const Size(5, 5)));

      laidOut(grid, BoxConstraints.tightFor(width: 100));

      expect(grid.columnSizes, <double>[50, 50]);
    });

    test('the ceiling caps what content can add', () {
      final grid = RenderGrid(
        columns: <GridTrack>[
          GridTrack.minmax(GridTrack.auto, GridTrack.fixed(60)),
        ],
      )..add(MeasuredBox(const Size(90, 10)));

      laidOut(grid, loose(500, 500));

      expect(grid.columnSizes, <double>[60]);
    });

    test('the floor wins over a smaller ceiling', () {
      final grid = RenderGrid(
        columns: <GridTrack>[
          GridTrack.minmax(GridTrack.fixed(200), GridTrack.fixed(100)),
        ],
      )..add(MeasuredBox(const Size(10, 10)));

      laidOut(grid, loose(500, 500));

      expect(grid.columnSizes, <double>[200]);
    });

    test('a fractional minimum is rejected rather than resolved', () {
      expect(
        () => GridTrack.minmax(GridTrack.fraction(), GridTrack.fraction()),
        throwsArgumentError,
      );
    });
  });

  group('auto tracks', () {
    test('are as wide as their widest cell', () {
      final grid = RenderGrid(
        columns: <GridTrack>[GridTrack.auto, GridTrack.auto],
      )
        ..add(MeasuredBox(const Size(37, 10)))
        ..add(MeasuredBox(const Size(12, 10)))
        ..add(MeasuredBox(const Size(15, 10)))
        ..add(MeasuredBox(const Size(41, 10)));

      laidOut(grid, loose(500, 500));

      expect(grid.columnSizes, <double>[37, 41]);
      expect(grid.rowSizes, <double>[10, 10]);
      expect(grid.size, const Size(78, 20));
    });

    test('do not stretch into leftover space', () {
      final grid = RenderGrid(columns: <GridTrack>[GridTrack.auto])
        ..add(MeasuredBox(const Size(25, 10)));

      laidOut(grid, loose(500, 500));

      expect(grid.columnSizes, <double>[25]);
      expect(grid.size.width, 25);
    });

    test('a row is measured at the width its columns settled on', () {
      // The content needs 120 pixels of line. In a 40-wide column that is
      // three lines; the grid must not have measured the row before the column.
      final grid = RenderGrid(columns: <GridTrack>[GridTrack.fixed(40)])
        ..add(ReflowingBox(contentWidth: 120, lineHeight: 8));

      laidOut(grid, loose(500, 500));

      expect(grid.rowSizes, <double>[24]);
      expect(grid.size, const Size(40, 24));
    });
  });

  group('spans', () {
    test('a spanning child widens only the content-sized tracks it crosses',
        () {
      final wide = MeasuredBox(const Size(100, 10));
      final grid = RenderGrid(
        columns: <GridTrack>[GridTrack.auto, GridTrack.auto, GridTrack.auto],
        columnGap: 5,
      )
        ..add(MeasuredBox(const Size(10, 10)))
        ..add(MeasuredBox(const Size(10, 10)))
        ..add(MeasuredBox(const Size(10, 10)))
        ..add(wide);
      grid.place(wide, column: 0, row: 1, columnSpan: 3);

      laidOut(grid, loose(500, 500));

      // Three 10-wide bases cover 30, plus two 5px gaps: 40. The shortfall of
      // 60 is split three ways, so every column becomes 30.
      expect(grid.columnSizes, <double>[30, 30, 30]);
      expect(grid.size.width, 100);
      expect(grid.childAt(1).offsetFromParent.dx, 35);
      expect(grid.childAt(2).offsetFromParent.dx, 70);
      expect(wide.offsetFromParent, const Offset(0, 10));
      expect(wide.size, const Size(100, 10));
    });

    test('a span cannot inflate a fixed track', () {
      final wide = MeasuredBox(const Size(300, 10));
      final grid = RenderGrid(
        columns: <GridTrack>[GridTrack.fixed(20), GridTrack.fixed(30)],
      )..add(wide);
      grid.place(wide, column: 0, row: 0, columnSpan: 2);

      laidOut(grid, loose(500, 500));

      expect(grid.columnSizes, <double>[20, 30]);
      expect(wide.size, const Size(50, 10));
    });

    test('a row span makes the child as tall as the rows it crosses', () {
      final tall = MeasuredBox(const Size(10, 10));
      final grid = RenderGrid(
        columns: <GridTrack>[GridTrack.fixed(20), GridTrack.fixed(20)],
        rows: <GridTrack>[GridTrack.fixed(15), GridTrack.fixed(25)],
        rowGap: 4,
      )..add(tall);
      grid.place(tall, column: 0, row: 0, rowSpan: 2);
      grid
        ..add(MeasuredBox(const Size(10, 10)))
        ..add(MeasuredBox(const Size(10, 10)));

      laidOut(grid, loose(500, 500));

      expect(tall.size, const Size(20, 44));
      expect(grid.size, const Size(40, 44));
      // The auto-placed children took the two free cells in the second column.
      expect(grid.childAt(1).offsetFromParent, const Offset(20, 0));
      expect(grid.childAt(2).offsetFromParent, const Offset(20, 19));
    });
  });

  group('placement', () {
    test('an empty cell still costs its track its size', () {
      final grid = RenderGrid(
        columns: <GridTrack>[
          GridTrack.fixed(20),
          GridTrack.fixed(30),
          GridTrack.fixed(40),
        ],
      )
        ..add(MeasuredBox(const Size(5, 12)))
        ..add(MeasuredBox(const Size(5, 8)));

      laidOut(grid, loose(500, 500));

      expect(grid.size, const Size(90, 12));
      expect(grid.rowCount, 1);
      expect(grid.childAt(1).offsetFromParent.dx, 20);
    });

    test('more children than cells spill into implicit rows', () {
      final grid = RenderGrid(
        columns: <GridTrack>[GridTrack.fixed(10), GridTrack.fixed(10)],
        rows: <GridTrack>[GridTrack.fixed(20)],
      );
      for (int i = 0; i < 5; i++) {
        grid.add(MeasuredBox(const Size(5, 7)));
      }

      laidOut(grid, loose(500, 500));

      // One explicit row of 20 plus two implicit auto rows of 7.
      expect(grid.rowCount, 3);
      expect(grid.rowSizes, <double>[20, 7, 7]);
      expect(grid.size, const Size(20, 34));
      expect(grid.childAt(4).offsetFromParent, const Offset(0, 27));
    });

    test('explicit placement is honoured and auto-placement flows around it',
        () {
      final pinned = MeasuredBox(const Size(5, 5));
      final grid = RenderGrid(
        columns: <GridTrack>[GridTrack.fixed(10), GridTrack.fixed(10)],
      )
        ..add(MeasuredBox(const Size(5, 5)))
        ..add(pinned)
        ..add(MeasuredBox(const Size(5, 5)));
      grid.place(pinned, column: 1, row: 0);

      laidOut(grid, loose(500, 500));

      expect(pinned.offsetFromParent, const Offset(10, 0));
      // The first auto child took (0, 0); the third had to start a new row.
      expect(grid.childAt(0).offsetFromParent, Offset.zero);
      expect(grid.childAt(2).offsetFromParent, const Offset(0, 5));
    });

    test('half a coordinate is rejected', () {
      final grid = RenderGrid(columns: <GridTrack>[GridTrack.fixed(10)]);
      final child = MeasuredBox(const Size(5, 5));
      grid.add(child);

      expect(() => grid.place(child, column: 0), throwsArgumentError);
      expect(() => grid.place(child, row: 0), throwsArgumentError);
    });

    test('a column past the last one is rejected', () {
      final grid = RenderGrid(columns: <GridTrack>[GridTrack.fixed(10)]);
      final child = MeasuredBox(const Size(5, 5));
      grid.add(child);

      expect(
        () => grid.place(child, column: 1, row: 0),
        throwsArgumentError,
      );
    });
  });

  group('fit and alignment', () {
    test('loose lets the child keep its size and aligns it in the cell', () {
      final child = MeasuredBox(const Size(10, 10));
      final grid = RenderGrid(
        columns: <GridTrack>[GridTrack.fixed(50)],
        rows: <GridTrack>[GridTrack.fixed(30)],
        fit: GridFit.loose,
      )..add(child);

      laidOut(grid, loose(500, 500));

      expect(child.size, const Size(10, 10));
      expect(child.offsetFromParent, const Offset(20, 10));
    });

    test('alignment moves the child inside its cell', () {
      final child = MeasuredBox(const Size(10, 10));
      final grid = RenderGrid(
        columns: <GridTrack>[GridTrack.fixed(50)],
        rows: <GridTrack>[GridTrack.fixed(30)],
        fit: GridFit.loose,
        alignment: Alignment.bottomRight,
      )..add(child);

      laidOut(grid, loose(500, 500));

      expect(child.offsetFromParent, const Offset(40, 20));
    });
  });

  group('overflow', () {
    test('sizes to the constraint, keeps the offsets, records the excess', () {
      final grid = RenderGrid(
        columns: <GridTrack>[GridTrack.fixed(80), GridTrack.fixed(80)],
      )
        ..add(MeasuredBox(const Size(5, 5)))
        ..add(MeasuredBox(const Size(5, 5)));

      laidOut(grid, BoxConstraints.tight(const Size(100, 20)));

      expect(grid.size, const Size(100, 20));
      expect(grid.overflow.width, 60);
      expect(grid.hasOverflow, isTrue);
      // Positioned where the tracks put them - past the edge, visibly.
      expect(grid.childAt(1).offsetFromParent.dx, 80);
    });

    test('a grid that fits records nothing', () {
      final grid = RenderGrid(columns: <GridTrack>[GridTrack.fixed(10)])
        ..add(MeasuredBox(const Size(5, 5)));

      laidOut(grid, loose(500, 500));

      expect(grid.hasOverflow, isFalse);
      expect(grid.overflow, Size.zero);
    });
  });

  group('the grid as a measurable child', () {
    test('reports its columns plus its gaps as a max-content width', () {
      final grid = RenderGrid(
        columns: <GridTrack>[GridTrack.auto, GridTrack.auto],
        columnGap: 6,
      )
        ..add(MeasuredBox(const Size(17, 10)))
        ..add(MeasuredBox(const Size(23, 10)));

      expect(grid.getMaxIntrinsicWidth(double.infinity), 46);
    });

    test('reports its rows as a height at a given width', () {
      final grid = RenderGrid(
        columns: <GridTrack>[GridTrack.fixed(40)],
        rowGap: 3,
      )
        ..add(ReflowingBox(contentWidth: 120, lineHeight: 8))
        ..add(ReflowingBox(contentWidth: 40, lineHeight: 8));

      expect(grid.getMaxIntrinsicHeight(double.infinity), 24 + 3 + 8);
    });

    test('a measurement does not disturb what the last layout settled on', () {
      final grid = RenderGrid(
        columns: <GridTrack>[GridTrack.fixed(30), GridTrack.fraction()],
      )
        ..add(MeasuredBox(const Size(5, 5)))
        ..add(MeasuredBox(const Size(5, 5)));

      laidOut(grid, BoxConstraints.tightFor(width: 100));
      expect(grid.columnSizes, <double>[30, 70]);

      grid.getMaxIntrinsicWidth(double.infinity);

      expect(grid.columnSizes, <double>[30, 70]);
    });
  });

  test('a grid with no columns is refused', () {
    expect(
      () => RenderGrid(columns: const <GridTrack>[]),
      throwsArgumentError,
    );
  });
}
