/// Editing a DataGrid cell: F2 or a double click opens a field on the cell's
/// text, Enter and a click elsewhere keep it, Tab moves along the row,
/// Escape drops it - and the owner, not the grid, stores what was typed.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

KeyDownEvent _key(int key, {bool shift = false}) => KeyDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      physicalKey: key,
      logicalKey: key,
      modifiers: <KeyModifier>{if (shift) KeyModifier.shift},
    );

PointerDownEvent _press(Offset at, {int clicks = 1}) => PointerDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
      button: PointerButton.primary,
      clickCount: clicks,
    );

PointerUpEvent _release(Offset at) => PointerUpEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
      button: PointerButton.primary,
    );

void main() {
  setUpAll(FrameworkFonts.install);
  tearDownAll(FontRegistry.instance.reset);

  late BuildOwner owner;
  late List<List<String>> data;
  late List<String> edits;
  late List<int> activated;

  Widget grid() => Directionality(
        textDirection: TextDirection.leftToRight,
        child: DataGrid(
          columns: const <DataGridColumn>[
            DataGridColumn(title: 'Name', width: 120, editable: true),
            DataGridColumn(title: 'Size', width: 80),
            DataGridColumn(title: 'Note', width: 120, editable: true),
          ],
          rowCount: data.length,
          rowExtent: 28,
          cellText: (int row, int column) => data[row][column],
          onCellEdited: (int row, int column, String text) {
            edits.add('$row:$column=$text');
            data[row][column] = text;
          },
          onRowActivated: activated.add,
          cellBuilder: (BuildContext context, int row, int column) =>
              Text(data[row][column]),
        ),
      );

  void frame() {
    for (var i = 0; i < 8; i++) {
      owner.updateRoot(grid());
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
  }

  T? find<T extends RenderBox>() {
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
    return found;
  }

  RenderTextField? editor() => find<RenderTextField>();

  void type(String text) =>
      owner.dispatchTextInputEvent(FakeTextInput().typeText(text));

  /// A double click on cell ([row], [column]): the header is a control high.
  void doubleClick(int row, double x) {
    final double y = find<RenderDataGridHeader>()!.size.height + row * 28 + 14;
    final Offset at = Offset(x, y);
    owner
      ..dispatchPointerEvent(_press(at))
      ..dispatchPointerEvent(_release(at))
      ..dispatchPointerEvent(_press(at, clicks: 2))
      ..dispatchPointerEvent(_release(at));
    frame();
  }

  setUp(() {
    data = <List<String>>[
      <String>['alpha.txt', '1 KB', ''],
      <String>['beta.txt', '2 KB', 'draft'],
    ];
    edits = <String>[];
    activated = <int>[];
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(400, 200)),
      ),
    );
    frame();
    find<RenderDataGridBody>()!.focusNode!.requestFocus();
    owner.dispatchKeyEvent(_key(logicalKeyArrowDown)); // row 0
    frame();
  });

  tearDown(() => owner.dispose());

  test('F2 opens the first editable cell with its text selected; Enter keeps',
      () {
    expect(owner.dispatchKeyEvent(_key(logicalKeyF2)), isTrue);
    frame();
    final RenderTextField field = editor()!;
    expect(field.hasFocus, isTrue, reason: 'the keyboard went to the editor');
    type('gamma.txt');
    frame();
    owner.dispatchKeyEvent(_key(logicalKeyEnter));
    frame();
    expect(edits, <String>['0:0=gamma.txt'], reason: 'typing replaced all');
    expect(editor(), isNull, reason: 'closed');
    expect(find<RenderDataGridBody>()!.hasFocus, isTrue,
        reason: 'the rows have the keyboard again');
    expect(activated, isEmpty, reason: 'Enter kept the edit, no more');
  });

  test('Escape drops the edit', () {
    owner.dispatchKeyEvent(_key(logicalKeyF2));
    frame();
    type('nope');
    owner.dispatchKeyEvent(_key(logicalKeyEscape));
    frame();
    expect(editor(), isNull);
    expect(edits, isEmpty);
    expect(data[0][0], 'alpha.txt');
  });

  test('Tab keeps and moves to the next editable cell, past the others', () {
    owner.dispatchKeyEvent(_key(logicalKeyF2));
    frame();
    type('a2');
    owner.dispatchKeyEvent(_key(logicalKeyTab));
    frame();
    expect(edits, <String>['0:0=a2']);
    expect(editor(), isNotNull, reason: 'now on Note, not Size');
    type('memo');
    owner.dispatchKeyEvent(_key(logicalKeyTab, shift: true));
    frame();
    expect(edits, <String>['0:0=a2', '0:2=memo']);
    owner.dispatchKeyEvent(_key(logicalKeyEscape));
    frame();
    expect(editor(), isNull);
  });

  test('a double click edits an editable cell, activates the row elsewhere',
      () {
    doubleClick(1, 120 + 80 + 20); // Note
    expect(editor(), isNotNull);
    expect(activated, isEmpty);
    owner.dispatchKeyEvent(_key(logicalKeyEscape));
    frame();
    doubleClick(1, 120 + 20); // Size: not editable
    expect(editor(), isNull);
    expect(activated, <int>[1]);
  });

  test('an unchanged edit reports nothing; a click elsewhere keeps a change',
      () {
    owner.dispatchKeyEvent(_key(logicalKeyF2));
    frame();
    owner.dispatchKeyEvent(_key(logicalKeyEnter));
    frame();
    expect(edits, isEmpty);

    owner.dispatchKeyEvent(_key(logicalKeyF2));
    frame();
    type('kept');
    find<RenderDataGridBody>()!.focusNode!.requestFocus();
    frame();
    expect(edits, <String>['0:0=kept']);
    expect(editor(), isNull);
  });
}
