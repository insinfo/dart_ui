// A column drag must cost the columns it moves, not the whole grid.
//
// Measured in the file explorer before this was so: every pointer event of a
// drag rebuilt the grid - the application's cellBuilder ran for every realized
// cell - and re-laid out every row. These tests pin the two halves of the fix:
// no cell is rebuilt, and a cell whose column kept its width is not laid out
// again.
import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  test('dragging a column edge rebuilds no cell', () {
    final _Harness h = _Harness();
    final int builtBefore = h.built;
    h.drag(from: 100, to: 140);
    expect(h.header.widths.first, 140);
    expect(h.built, builtBefore, reason: 'cellBuilder ran during the drag');
    h.dispose();
  });

  test('only the cells of the resized column are laid out again', () {
    final _Harness h = _Harness();
    final Map<int, int> before = Map<int, int>.of(h.layouts);
    h.drag(from: 100, to: 130);
    for (final int column in <int>[0, 1, 2]) {
      final int delta = (h.layouts[column] ?? 0) - (before[column] ?? 0);
      if (column == 0) {
        expect(delta, greaterThan(0), reason: 'the resized column relays out');
      } else {
        expect(delta, 0,
            reason: 'column $column kept its width and was laid out again');
      }
    }
    // And the cells after it moved with the edge.
    final RenderDataGridRow row = h.firstRow;
    expect(row.widths.first, 130);
    h.dispose();
  });

  test('a rebuild with unchanged widths does not relay the rows out', () {
    final _Harness h = _Harness();
    final RenderDataGridRow row = h.firstRow;
    h.owner.updateRoot(h.grid());
    h.owner.buildScope();
    expect(row.needsLayout, isFalse);
    h.dispose();
  });
}

final class _Harness {
  _Harness() {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(400, 148)),
      ),
    );
    owner.updateRoot(grid());
    frame();
  }

  late final BuildOwner owner;
  int built = 0;
  final Map<int, int> layouts = <int, int>{};

  Widget grid() => Directionality(
        textDirection: TextDirection.leftToRight,
        child: DataGrid(
          columns: const <DataGridColumn>[
            DataGridColumn(title: 'A', width: 100),
            DataGridColumn(title: 'B', width: 100),
            DataGridColumn(title: 'C', width: 100),
          ],
          rowCount: 50,
          rowExtent: 20,
          cacheExtent: 0,
          cellBuilder: (BuildContext context, int row, int column) {
            built++;
            return _CountingCell(column, layouts);
          },
        ),
      );

  /// Builds and lays out until the grid has settled - its first pass uses an
  /// estimated viewport and asks for a second.
  void frame() {
    for (int pass = 0; pass < 8; pass++) {
      owner.buildScope();
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
  RenderDataGridRow get firstRow => _find<RenderDataGridRow>();

  void drag({required double from, required double to}) {
    header.handlePointerEvent(_pointer(_Kind.down, from));
    for (double x = from + 5; x <= to; x += 5) {
      header.handlePointerEvent(_pointer(_Kind.move, x));
      frame();
    }
    header.handlePointerEvent(_pointer(_Kind.up, to));
    frame();
  }

  void dispose() => owner.dispose();
}

enum _Kind { down, move, up }

PointerEvent _pointer(_Kind kind, double x) {
  final Offset position = Offset(x, 10);
  return switch (kind) {
    _Kind.down => PointerDownEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: position,
        button: PointerButton.primary,
        clickCount: 1,
      ),
    _Kind.move => PointerMoveEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: position,
      ),
    _Kind.up => PointerUpEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: position,
        button: PointerButton.primary,
      ),
  };
}

/// A cell that counts its layouts per column.
final class _CountingCell extends SingleChildRenderObjectWidget {
  const _CountingCell(this.column, this.layouts);

  final int column;
  final Map<int, int> layouts;

  @override
  RenderBox createRenderObject(BuildContext context) =>
      _RenderCountingCell(column, layouts);

  @override
  void updateRenderObject(BuildContext context, covariant RenderBox object) {}
}

final class _RenderCountingCell extends RenderBox {
  _RenderCountingCell(this.column, this.layouts);

  final int column;
  final Map<int, int> layouts;

  @override
  void performLayout() {
    layouts[column] = (layouts[column] ?? 0) + 1;
    size = constraints.constrain(const Size(10, 10));
  }
}
