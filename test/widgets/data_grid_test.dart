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

      final RenderDataGridRow row = harness.body.childAt(0) as RenderDataGridRow;
      expect(row.childCount, 2);
      // Column 0 starts at 0 and column 1 at 100; cells sit inside their
      // column by half the control padding (4 px on the neutral theme).
      expect(row.childAt(0).offsetFromParent.dx, 4);
      expect(row.childAt(1).offsetFromParent.dx, 104);
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

    test('selection scrolls to stay visible, and End reaches the last row',
        () {
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

      harness.body
          .handleKeyEvent(_key(logicalKeyArrowDown, shift: true));
      harness.frame();
      harness.body
          .handleKeyEvent(_key(logicalKeyArrowDown, shift: true));
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
      expect(harness.selection, <int>{0}, reason: 'a second Ctrl+click removes');
      harness.dispose();
    });
  });

  group('DataGrid header', () {
    test('clicking a sortable column cycles ascending then descending', () {
      final harness = _GridHarness(rowCount: 10);
      harness.frame();

      harness.clickHeader(const Offset(50, 10));
      harness.frame();
      expect(harness.sort, const DataGridSort(0, DataGridSortDirection.ascending));

      harness.clickHeader(const Offset(50, 10));
      harness.frame();
      expect(
          harness.sort, const DataGridSort(0, DataGridSortDirection.descending));

      harness.clickHeader(const Offset(150, 10));
      harness.frame();
      expect(harness.sort, const DataGridSort(1, DataGridSortDirection.ascending));
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
}

final class _GridHarness {
  _GridHarness({
    required this.rowCount,
    this.selectionMode = DataGridSelectionMode.single,
    this.sortable = true,
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
  final ScrollPosition scroll = ScrollPosition();
  late final BuildOwner owner;
  Set<int> selection = <int>{};
  DataGridSort? sort;
  final List<String> resized = <String>[];

  void _mount() => owner.updateRoot(Directionality(
        textDirection: TextDirection.leftToRight,
        child: DataGrid(
          columns: <DataGridColumn>[
            DataGridColumn(title: 'Name', width: 100, sortable: sortable),
            DataGridColumn(title: 'Size', width: 80, sortable: sortable),
          ],
          rowCount: rowCount,
          rowExtent: 20,
          cacheExtent: 0,
          controller: scroll,
          selectionMode: selectionMode,
          selectedRows: selection,
          onSelectionChanged: (Set<int> rows) => selection = rows,
          sort: sort,
          onSortChanged: (DataGridSort next) => sort = next,
          onColumnResized: (int column, double width) =>
              resized.add('$column:$width'),
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

PointerDownEvent _press(Offset position) => PointerDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: position,
      button: PointerButton.primary,
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
