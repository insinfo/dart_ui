import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

DockingItem _item(String id) => DockingItem(
      id: id,
      name: id.toUpperCase(),
      widget: const SizedBox(),
    );

void main() {
  test('indexes and describes a nested docking hierarchy', () {
    final a = _item('a');
    final b = _item('b');
    final c = _item('c');
    final layout = DockingLayout(
      root: DockingRow(<DockingArea>[
        DockingTabs(<DockingItem>[a, b]),
        c,
      ]),
    );

    expect(layout.hierarchy(nameInfo: true), 'R(T(IA,IB),IC)');
    expect(
        layout.layoutAreas().map((area) => area.index), <int>[1, 2, 3, 4, 5]);
    expect(b.parent, isA<DockingTabs>());
    expect(b.level, 2);
    expect(b.path, 'RTI');
    expect(layout.findDockingItem('b'), same(b));
  });

  test('adds, moves and collapses areas without leaving stale parents', () {
    final a = _item('a');
    final b = _item('b');
    final c = _item('c');
    final layout = DockingLayout(root: a);

    layout.addItemOn(
      newItem: b,
      targetArea: a,
      dropPosition: DropPosition.center,
    );
    expect(layout.root, isA<DockingTabs>());
    expect((layout.root! as DockingTabs).children, <DockingArea>[a, b]);

    layout.addItemOn(
      newItem: c,
      targetArea: b,
      dropPosition: DropPosition.right,
    );
    expect(layout.hierarchy(), 'R(T(I,I),I)');

    layout.moveItem(
      draggedItem: a,
      targetArea: c,
      dropPosition: DropPosition.center,
    );
    expect(layout.hierarchy(), 'R(I,T(I,I))');
    expect(a.layoutId, layout.id);
    expect(a.parent, isA<DockingTabs>());

    layout.removeItem(item: b);
    expect(layout.hierarchy(), 'T(I,I)');
    expect(b.disposed, isTrue);
  });

  test('selection, maximize and restore each notify listeners', () {
    final a = _item('a');
    final b = _item('b');
    final tabs = DockingTabs(<DockingItem>[a, b]);
    final layout = DockingLayout(root: tabs);
    var revisions = 0;
    layout.addListener((_) => revisions++);

    layout.selectItem(b);
    expect(tabs.selectedIndex, 1);
    layout.maximizeDockingItem(b);
    expect(layout.maximizedArea, same(b));
    expect(b.maximized, isTrue);
    layout.restore();
    expect(layout.maximizedArea, isNull);
    expect(revisions, 3);
  });

  test('builds split panes and tabs into a bounded render tree', () {
    final layout = DockingLayout(
      root: DockingRow(<DockingArea>[
        DockingTabs(<DockingItem>[_item('files'), _item('search')]),
        _item('document'),
      ]),
    );
    final pipeline = PipelineOwner(
      rootConstraints: BoxConstraints.tight(const Size(800, 500)),
    );
    final owner = BuildOwner(pipelineOwner: pipeline);
    addTearDown(owner.dispose);

    owner.updateRoot(
      Theme(
        data: ThemeData.neutralLight,
        child: Directionality(
          textDirection: TextDirection.leftToRight,
          child: Docking(layout: layout),
        ),
      ),
    );
    owner.buildScope();
    pipeline.flushLayout();

    expect(owner.renderRoot!.size, const Size(800, 500));
  });
}
