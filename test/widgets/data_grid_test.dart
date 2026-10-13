import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('DataGrid virtualization', () {
    test('a huge grid realizes a bounded window of rows', () {
      final harness = _GridHarness(rowCount: 100000);
      harness.frame();

      expect(harness.body.virtualization.itemCount, 100000);
      expect(harness.body.childCount, lessThan(20));
      expect(harness.body.childCount, greaterThan(3));
      harness.dispose();
    });

    test('a wheel event scrolls the rows', () {
      final harness = _GridHarness(rowCount: 1000);
      harness.frame();

      harness.body.handlePointerEvent(const PointerScrollEvent(
        windowId: NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: Offset(10, 40),
        scrollDelta: Offset(0, 3),
        scrollDeltaUnit: ScrollDeltaUnit.lines,
      ));

      expect(harness.scroll.pixels, 3 * defaultLineExtent);
      harness.dispose();
    });

    test('cells are laid out at the column offsets', () {
      final harness = _GridHarness(rowCount: 10);
      harness.frame();

      final RenderDataGridRow row =
          harness.body.childAt(0) as RenderDataGridRow;
      expect(row.childCount, 2);
      // Column 0 starts at 0 and column 1 at 100; cells sit inside their
      // column by the theme's full control padding (12 px on the neutral
      // theme). It was half of it, which is how a grid cell ended up with
      // less air around its text than every other control in the window - the
      // "half padding" idiom was a fourth spacing value that no token named.
      const double padding = 12.0;
      expect(padding, ThemeData.neutralLight.effectiveControlPadding);
      expect(row.childAt(0).offsetFromParent.dx, padding);
      expect(row.childAt(1).offsetFromParent.dx, 100 + padding);
      harness.dispose();
    });
  });

  group('DataGrid column edges', () {
    test('an edge shows the resize arrow; a double click fits the column', () {
      final harness = _GridHarness(rowCount: 3);
      harness.frame();
      PointerMoveEvent at(double x) => PointerMoveEvent(
            windowId: const NativeWindowId(1),
            generation: 1,
            timestamp: Duration.zero,
            pointerId: 0,
            kind: PointerKind.mouse,
            logicalPosition: Offset(x, 10),
          );
      expect(harness.header.cursorFor(at(100)), SystemCursor.resizeHorizontal);
      expect(harness.header.cursorFor(at(50)), isNull);
      harness.header.handlePointerEvent(_press(const Offset(101, 10)));
      harness.header
          .handlePointerEvent(_press(const Offset(101, 10), clicks: 2));
      harness.frame();
      expect(harness.resized, contains('0:150.0'));
      harness.dispose();
    });
  });

  group('DataGrid as a file list', () {
    test('a double click or Enter opens the row', () {
      final harness = _GridHarness(rowCount: 10);
      harness.frame();
      final Offset row2 = harness.bodyPoint(10, 2 * 20 + 5);
      harness.body.handlePointerEvent(_press(row2));
      harness.body.handlePointerEvent(_press(row2, clicks: 2));
      harness.frame();
      expect(harness.selection, <int>{2});
      expect(harness.activated, <int>[2]);
      harness.body.handleKeyEvent(_key(logicalKeyArrowDown));
      harness.frame();
      harness.body.handleKeyEvent(_key(logicalKeyEnter));
      expect(harness.activated, <int>[2, 3]);
      harness.dispose();
    });

    test('a right click keeps a selection it lands in, takes one it misses',
        () {
      final harness = _GridHarness(
          rowCount: 10, selectionMode: DataGridSelectionMode.multiple)
        ..selection = <int>{1, 2, 3};
      harness.frame();
      harness.body.handlePointerEvent(_press(harness.bodyPoint(10, 2 * 20 + 5),
          button: PointerButton.secondary));
      harness.frame();
      expect(harness.selection, <int>{1, 2, 3},
          reason: 'the menu acts on the whole selection');
      expect(harness.secondary, <int?>[2]);

      harness.body.handlePointerEvent(_press(harness.bodyPoint(10, 5 * 20 + 5),
          button: PointerButton.secondary));
      harness.frame();
      expect(harness.selection, <int>{5});
      harness.dispose();
    });

    test('a click below the last row drops the selection', () {
      final harness = _GridHarness(rowCount: 2)..selection = <int>{1};
      harness.frame();
      harness.body.handlePointerEvent(_press(harness.bodyPoint(10, 100)));
      harness.frame();
      expect(harness.selection, isEmpty);
      harness.body.handlePointerEvent(
          _press(harness.bodyPoint(10, 100), button: PointerButton.secondary));
      expect(harness.secondary, <int?>[null],
          reason: 'empty space: the background menu');
      harness.dispose();
    });
  });

  group('DataGrid keyboard', () {
    test('the first Down selects the first row, later ones walk', () {
      final harness = _GridHarness(rowCount: 100);
      harness.frame();

      harness.body.handleKeyEvent(_key(logicalKeyArrowDown));
      harness.frame();
      expect(harness.selection, <int>{0});

      harness.body.handleKeyEvent(_key(logicalKeyArrowDown));
      harness.frame();
      expect(harness.selection, <int>{1});
      harness.dispose();
    });

    test('selection scrolls to stay visible, and End reaches the last row', () {
      final harness = _GridHarness(rowCount: 100);
      harness.frame();

      harness.body.handleKeyEvent(_key(logicalKeyEnd));
      harness.frame();
      expect(harness.selection, <int>{99});
      expect(harness.scroll.atEnd, isTrue);

      harness.body.handleKeyEvent(_key(logicalKeyHome));
      harness.frame();
      expect(harness.selection, <int>{0});
      expect(harness.scroll.pixels, 0);
      harness.dispose();
    });

    test('Shift+Down extends a range in multiple mode', () {
      final harness = _GridHarness(
        rowCount: 100,
        selectionMode: DataGridSelectionMode.multiple,
      );
      harness.frame();

      harness.body.handlePointerEvent(_press(harness.bodyPoint(50, 30)));
      harness.frame();
      expect(harness.selection, <int>{1});

      harness.body.handleKeyEvent(_key(logicalKeyArrowDown, shift: true));
      harness.frame();
      harness.body.handleKeyEvent(_key(logicalKeyArrowDown, shift: true));
      harness.frame();

      expect(harness.selection, <int>{1, 2, 3});
      harness.dispose();
    });

    test('Ctrl+A selects every row in multiple mode', () {
      final harness = _GridHarness(
        rowCount: 8,
        selectionMode: DataGridSelectionMode.multiple,
      );
      harness.frame();

      harness.body.handleKeyEvent(_key(0x41, control: true));
      harness.frame();

      expect(harness.selection, <int>{0, 1, 2, 3, 4, 5, 6, 7});
      harness.dispose();
    });
  });

  group('DataGrid pointer selection', () {
    test('a click selects the row under it', () {
      final harness = _GridHarness(rowCount: 100);
      harness.frame();

      // Rows are 20 px: y 45 inside the body is row 2.
      harness.body.handlePointerEvent(_press(harness.bodyPoint(50, 45)));
      harness.frame();

      expect(harness.selection, <int>{2});
      harness.dispose();
    });

    test('Ctrl+click toggles membership in multiple mode', () {
      final harness = _GridHarness(
        rowCount: 100,
        selectionMode: DataGridSelectionMode.multiple,
      );
      harness.frame();

      harness.body.handlePointerEvent(_press(harness.bodyPoint(50, 10)));
      harness.frame();
      expect(harness.selection, <int>{0});

      // The grid learns modifier state from key transitions, so press Ctrl.
      harness.body.handleKeyEvent(_key(0x11, control: true));
      harness.body.handlePointerEvent(_press(harness.bodyPoint(50, 45)));
      harness.frame();
      expect(harness.selection, <int>{0, 2});

      harness.body.handlePointerEvent(_press(harness.bodyPoint(50, 45)));
      harness.frame();
      expect(harness.selection, <int>{0},
          reason: 'a second Ctrl+click removes');
      harness.dispose();
    });
  });

  group('DataGrid header', () {
    test('clicking a sortable column cycles ascending then descending', () {
      final harness = _GridHarness(rowCount: 10);
      harness.frame();

      harness.clickHeader(const Offset(50, 10));
      harness.frame();
      expect(
          harness.sort, const DataGridSort(0, DataGridSortDirection.ascending));

      harness.clickHeader(const Offset(50, 10));
      harness.frame();
      expect(harness.sort,
          const DataGridSort(0, DataGridSortDirection.descending));

      harness.clickHeader(const Offset(150, 10));
      harness.frame();
      expect(
          harness.sort, const DataGridSort(1, DataGridSortDirection.ascending));
      harness.dispose();
    });

    test('an unsortable column ignores the click', () {
      final harness = _GridHarness(rowCount: 10, sortable: false);
      harness.frame();

      harness.clickHeader(const Offset(50, 10));
      harness.frame();

      expect(harness.sort, isNull);
      harness.dispose();
    });

    test('dragging the boundary resizes the column ahead of it', () {
      final harness = _GridHarness(rowCount: 10);
      harness.frame();

      harness.header.handlePointerEvent(_press(const Offset(100, 10)));
      harness.header.handlePointerEvent(_move(const Offset(130, 10)));
      harness.header.handlePointerEvent(_release(const Offset(130, 10)));
      harness.frame();

      expect(harness.header.widths[0], 130);
      expect(harness.resized, contains('0:130.0'));
      // A resize is not a sort, even though press and release both landed on
      // the header.
      expect(harness.sort, isNull);
      harness.dispose();
    });

    test('a resize cannot shrink below the column minimum', () {
      final harness = _GridHarness(rowCount: 10);
      harness.frame();

      harness.header.handlePointerEvent(_press(const Offset(100, 10)));
      harness.header.handlePointerEvent(_move(const Offset(5, 10)));
      harness.header.handlePointerEvent(_release(const Offset(5, 10)));
      harness.frame();

      expect(harness.header.widths[0], 40);
      harness.dispose();
    });
  });

  group('DataGrid semantics', () {
    test('the body reports the full row count and the selection', () {
      final harness = _GridHarness(rowCount: 1000);
      harness.frame();
      harness.body.handlePointerEvent(_press(harness.bodyPoint(50, 10)));
      harness.frame();

      final SemanticsSnapshot snapshot =
          SemanticsOwner().build(harness.owner.renderRoot);
      final SemanticsNode bodyNode = snapshot.nodes.firstWhere(
        (SemanticsNode node) =>
            node.role == SemanticsRole.list && node.value == '1000 rows',
      );
      expect(bodyNode.hint, '1 of 1000 selected');

      final SemanticsNode headerNode = snapshot.nodes.firstWhere(
        (SemanticsNode node) => node.value == '2 columns',
      );
      expect(headerNode.label, 'Name, Size');

      final SemanticsNode row = snapshot.nodes.firstWhere(
        (SemanticsNode node) => node.value == 'row 1',
      );
      expect(row.states, contains(SemanticsState.selected));
      harness.dispose();
    });
  });
  group('DataGrid sideways', () {
    PointerScrollEvent wheel(double dx, double dy) => PointerScrollEvent(
          windowId: const NativeWindowId(1),
          generation: 1,
          timestamp: Duration.zero,
          pointerId: 0,
          kind: PointerKind.mouse,
          logicalPosition: const Offset(10, 40),
          scrollDelta: Offset(dx, dy),
          scrollDeltaUnit: ScrollDeltaUnit.pixels,
        );

    test('columns that fit do not scroll', () {
      final harness = _GridHarness(rowCount: 3);
      harness.frame();
      expect(harness.sideways.maxScrollExtent, 0);
      expect(harness.body.handleKeyEvent(_key(logicalKeyArrowRight)), isFalse,
          reason: 'Right is free for whoever wants it');
      harness.dispose();
    });

    test('wider columns scroll the rows and the titles together', () {
      final harness =
          _GridHarness(rowCount: 3, widths: const <double>[150, 150]);
      harness.frame();
      expect(harness.sideways.maxScrollExtent, 300 - 220);
      final RenderDataGridRow row =
          harness.body.childAt(0) as RenderDataGridRow;
      expect(row.size.width, 300, reason: 'rows as wide as the columns');

      harness.body.handlePointerEvent(wheel(30, 0));
      harness.frame();
      expect(harness.sideways.pixels, 30);
      expect(row.offsetFromParent.dx, -30);
      expect(harness.header.columnStart(1), 150 - 30);

      // Shift turns the wheel sideways and leaves the rows where they are.
      harness.body.handleKeyEvent(_key(0x10, shift: true));
      harness.body.handlePointerEvent(wheel(0, 20));
      harness.frame();
      expect(harness.sideways.pixels, 50);
      expect(harness.scroll.pixels, 0);
      harness.dispose();
    });

    test('Left and Right scroll; the header resizes the column it shows', () {
      final harness =
          _GridHarness(rowCount: 3, widths: const <double>[150, 150]);
      harness.frame();
      expect(harness.body.handleKeyEvent(_key(logicalKeyArrowRight)), isTrue);
      harness.frame();
      final double step = harness.sideways.pixels;
      expect(step, greaterThan(0));
      harness.body.handleKeyEvent(_key(logicalKeyArrowLeft));
      harness.frame();
      expect(harness.sideways.pixels, 0);

      harness.sideways.jumpTo(50);
      harness.frame();
      // Name's right edge is at 150 - 50 on screen.
      harness.header.handlePointerEvent(_press(const Offset(100, 10)));
      harness.header.handlePointerEvent(_move(const Offset(120, 10)));
      harness.header.handlePointerEvent(_release(const Offset(120, 10)));
      harness.frame();
      expect(harness.header.widths[0], 170);
      harness.dispose();
    });

    test('right to left, the rows start at the right edge', () {
      final harness = _GridHarness(
          rowCount: 3,
          widths: const <double>[150, 150],
          direction: TextDirection.rightToLeft);
      harness.frame();
      final RenderDataGridRow row =
          harness.body.childAt(0) as RenderDataGridRow;
      expect(row.offsetFromParent.dx, 220 - 300);
      expect(harness.header.columnStart(0), 220 - 150);
      harness.sideways.jumpTo(80);
      harness.frame();
      expect(row.offsetFromParent.dx, 0);
      expect(harness.header.columnStart(1), 0);
      harness.dispose();
    });
  });
}

final class _GridHarness {
  _GridHarness({
    required this.rowCount,
    this.selectionMode = DataGridSelectionMode.single,
    this.sortable = true,
    this.widths = const <double>[100, 80],
    this.direction = TextDirection.leftToRight,
  }) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        // 28 px of header on the neutral theme plus six 20-px rows.
        rootConstraints: BoxConstraints.tight(const Size(220, 148)),
      ),
    );
    _mount();
  }

  final int rowCount;
  final DataGridSelectionMode selectionMode;
  final bool sortable;
  final List<double> widths;
  final TextDirection direction;
  final ScrollPosition scroll = ScrollPosition();
  final ScrollPosition sideways = ScrollPosition(axis: ScrollAxis.horizontal);
  late final BuildOwner owner;
  Set<int> selection = <int>{};
  DataGridSort? sort;
  final List<String> resized = <String>[];
  final List<int> activated = <int>[];
  final List<int?> secondary = <int?>[];

  void _mount() => owner.updateRoot(Directionality(
        textDirection: direction,
        child: DataGrid(
          columns: <DataGridColumn>[
            DataGridColumn(title: 'Name', width: widths[0], sortable: sortable),
            DataGridColumn(title: 'Size', width: widths[1], sortable: sortable),
          ],
          rowCount: rowCount,
          rowExtent: 20,
          cacheExtent: 0,
          controller: scroll,
          horizontalController: sideways,
          selectionMode: selectionMode,
          selectedRows: selection,
          onSelectionChanged: (Set<int> rows) => selection = rows,
          sort: sort,
          onSortChanged: (DataGridSort next) => sort = next,
          onColumnResized: (int column, double width) =>
              resized.add('$column:$width'),
          onRowActivated: activated.add,
          columnFitWidth: (int column) => 150,
          onSecondaryPress: secondary.add,
          cellBuilder: (BuildContext context, int row, int column) =>
              Text('r$row c$column'),
        ),
      ));

  void frame({int maxPasses = 8}) {
    for (int pass = 0; pass < maxPasses; pass++) {
      _mount();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
    throw StateError('the grid never settled');
  }

  T _find<T extends RenderBox>() {
    T? found;
    void walk(RenderBox node) {
      if (found != null) return;
      if (node is T) {
        found = node;
        return;
      }
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found!;
  }

  RenderDataGridHeader get header => _find<RenderDataGridHeader>();

  RenderDataGridBody get body => _find<RenderDataGridBody>();

  /// A full click on the header: press and release at [position], which is
  /// what a sort takes - activation is release-inside, like every control.
  void clickHeader(Offset position) {
    header.handlePointerEvent(_press(position));
    header.handlePointerEvent(_release(position));
  }

  /// Translates a point in the *body's* space to the root space pointer
  /// events arrive in: the body sits below the 28-px header.
  Offset bodyPoint(double dx, double dy) => Offset(dx, dy + 28);

  void dispose() => owner.dispose();
}

KeyDownEvent _key(int logicalKey, {bool shift = false, bool control = false}) =>
    KeyDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      physicalKey: logicalKey,
      logicalKey: logicalKey,
      modifiers: <KeyModifier>{
        if (shift) KeyModifier.shift,
        if (control) KeyModifier.control,
      },
    );

PointerDownEvent _press(Offset position,
        {PointerButton button = PointerButton.primary, int clicks = 1}) =>
    PointerDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: position,
      button: button,
      clickCount: clicks,
    );

PointerMoveEvent _move(Offset position) => PointerMoveEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: position,
    );

PointerUpEvent _release(Offset position) => PointerUpEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: position,
      button: PointerButton.primary,
    );
