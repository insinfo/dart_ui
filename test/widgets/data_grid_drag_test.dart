/// Rows dragged out of a DataGrid, and drops onto its rows.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

final class _FakeWindow implements NativeWindow {
  @override
  NativeWindowId get id => const NativeWindowId(1);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

DragSessionEvent _over(Offset position) => DragSessionEvent(
      windowId: const NativeWindowId(1),
      position: position,
      data: MemoryDragData.filePaths(<String>['/tmp/a.txt']),
      allowedActions: const <DragAction>{DragAction.copy, DragAction.move},
    );

void main() {
  late BuildOwner owner;
  late FakeDragDrop backend;
  late List<Set<int>> dragged;
  late List<int?> dropped;
  int pointer = 0;

  void mount(Set<int> selected) {
    owner.updateRoot(DragDropScope(
      dragAndDrop: backend,
      window: _FakeWindow(),
      child: Directionality(
        textDirection: TextDirection.leftToRight,
        child: DataGrid(
          columns: const <DataGridColumn>[
            DataGridColumn(id: 'name', title: 'Name', width: 200),
          ],
          rowCount: 5,
          selectionMode: DataGridSelectionMode.multiple,
          selectedRows: selected,
          cellBuilder: (BuildContext context, int row, int column) =>
              Text('row $row'),
          rowDragData: (Set<int> rows) {
            dragged.add(rows);
            return MemoryDragData.text(rows.join(','));
          },
          // Rows 0 and 1 are "folders" and take drops into them; over the
          // other rows the drop is into the list itself. Row 0 refuses
          // copies, to show a refusal.
          rowAcceptsDrops: (int row) => row < 2,
          rowDropResponse: (int? row, DropDetails details) =>
              row == 0 && details.session.modifiers.isNotEmpty
                  ? const DropResponse.reject()
                  : const DropResponse(
                      acceptedFormat: DragFormats.uriList,
                      action: DragAction.move,
                    ),
          onRowDrop: (int? row, DropDetails details) async {
            dropped.add(row);
            return DragAction.move;
          },
        ),
      ),
    ));
  }

  void frame() {
    for (var i = 0; i < 8; i++) {
      owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
  }

  List<RenderDataGridRow> rows() {
    final List<RenderDataGridRow> found = <RenderDataGridRow>[];
    void walk(RenderBox node) {
      if (node is RenderDataGridRow) found.add(node);
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found..sort((a, b) => a.index.compareTo(b.index));
  }

  Offset centreOf(int row) {
    final RenderDataGridRow r = rows()[row];
    return r.localToGlobal(Offset(40, r.size.height / 2));
  }

  void press(Offset at) => owner.dispatchPointerEvent(PointerDownEvent(
        windowId: const NativeWindowId(1),
        generation: 0,
        timestamp: Duration.zero,
        pointerId: ++pointer,
        kind: PointerKind.mouse,
        logicalPosition: at,
        button: PointerButton.primary,
      ));

  void move(Offset to) => owner.dispatchPointerEvent(PointerMoveEvent(
        windowId: const NativeWindowId(1),
        generation: 0,
        timestamp: Duration.zero,
        pointerId: pointer,
        kind: PointerKind.mouse,
        logicalPosition: to,
      ));

  setUp(() {
    backend = FakeDragDrop();
    dragged = <Set<int>>[];
    dropped = <int?>[];
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(400, 400)),
      ),
    );
  });

  tearDown(() => owner.dispose());

  test('dragging a selected row carries the whole selection', () async {
    mount(<int>{1, 2});
    frame();
    final Offset start = centreOf(2);
    press(start);
    move(start + const Offset(30, 30));
    await Future<void>.delayed(Duration.zero);
    expect(dragged, <Set<int>>[
      <int>{1, 2}
    ]);
    expect(backend.requests.single.allowedActions,
        <DragAction>{DragAction.copy, DragAction.move});
  });

  test('a row outside the selection drags alone', () async {
    mount(<int>{1, 2});
    frame();
    final Offset start = centreOf(4);
    press(start);
    move(start + const Offset(30, 30));
    await Future<void>.delayed(Duration.zero);
    expect(dragged, <Set<int>>[
      <int>{4}
    ]);
  });

  test('the empty space below the rows drags nothing', () async {
    mount(<int>{1, 2});
    frame();
    final Offset below = centreOf(4) + const Offset(0, 120);
    press(below);
    move(below + const Offset(30, 30));
    await Future<void>.delayed(Duration.zero);
    expect(dragged, isEmpty);
    expect(backend.requests, isEmpty);
  });

  test('a drop lands on the row under it, which is lit while it hovers',
      () async {
    mount(const <int>{});
    frame();
    expect(owner.dispatchDragUpdate(_over(centreOf(1))).isAccepted, isTrue);
    frame();
    expect(rows()[1].dropTarget, isTrue);
    expect(rows()[0].dropTarget, isFalse);

    expect(owner.dispatchDragUpdate(_over(centreOf(3))).isAccepted, isTrue,
        reason: 'a file row is the list itself');
    frame();
    expect(rows().where((RenderDataGridRow r) => r.dropTarget), isEmpty,
        reason: 'and lights nothing');

    expect(
        owner
            .dispatchDragUpdate(DragSessionEvent(
              windowId: const NativeWindowId(1),
              position: centreOf(0),
              data: MemoryDragData.filePaths(<String>['/tmp/a.txt']),
              allowedActions: const <DragAction>{DragAction.copy},
              modifiers: const <KeyModifier>{KeyModifier.control},
            ))
            .isAccepted,
        isFalse,
        reason: 'row 0 refuses this one');
    frame();
    expect(rows()[0].dropTarget, isFalse, reason: 'a refusal lights nothing');

    owner.dispatchDragUpdate(_over(centreOf(0)));
    expect(await owner.dispatchDrop(_over(centreOf(0))), DragAction.move);
    frame();
    expect(dropped, <int?>[0]);
    expect(rows().where((RenderDataGridRow r) => r.dropTarget), isEmpty,
        reason: 'the light goes out with the drop');

    final Offset below = centreOf(4) + const Offset(0, 120);
    owner.dispatchDragUpdate(_over(below));
    expect(await owner.dispatchDrop(_over(below)), DragAction.move);
    expect(dropped.last, isNull, reason: 'below the rows is the list itself');
    owner.dispatchDragUpdate(_over(centreOf(3)));
    await owner.dispatchDrop(_over(centreOf(3)));
    expect(dropped.last, isNull, reason: 'and so is a file row');
  });
}
