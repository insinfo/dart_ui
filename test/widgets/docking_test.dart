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

  group('dragging a panel', () {
    late DockingLayout layout;
    late BuildOwner owner;
    late PipelineOwner pipeline;
    DockingItem? floated;
    var pointer = 0;

    void frame() {
      owner.buildScope();
      pipeline.drawFrame(DisplayList());
    }

    void drag(List<Offset> path) {
      owner.dispatchPointerEvent(PointerDownEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        pointerId: pointer,
        kind: PointerKind.mouse,
        logicalPosition: path.first,
        button: PointerButton.primary,
      ));
      for (final Offset at in path.skip(1)) {
        owner.dispatchPointerEvent(PointerMoveEvent(
          windowId: const NativeWindowId(1),
          generation: 1,
          timestamp: Duration.zero,
          pointerId: pointer,
          kind: PointerKind.mouse,
          logicalPosition: at,
        ));
        frame();
      }
      owner.dispatchPointerEvent(PointerUpEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        pointerId: pointer,
        kind: PointerKind.mouse,
        logicalPosition: path.last,
        button: PointerButton.primary,
      ));
      pointer++;
      frame();
    }

    setUp(() {
      FrameworkFonts.install();
      floated = null;
      layout = DockingLayout(
        root: DockingRow(<DockingArea>[
          DockingTabs(<DockingItem>[_item('files'), _item('search')]),
          _item('document'),
        ]),
      );
      pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(800, 500)),
      );
      owner = BuildOwner(pipelineOwner: pipeline);
      owner.updateRoot(Theme(
        data: ThemeData.neutralLight,
        child: Directionality(
          textDirection: TextDirection.leftToRight,
          child: Docking(
            layout: layout,
            onItemFloat: (DockingItem item, Offset at) {
              floated = item;
              layout.removeItem(item: item);
            },
          ),
        ),
      ));
      frame();
    });

    tearDown(() => owner.dispose());

    // The first tab of the group on the left, inside its header strip.
    const Offset tab = Offset(20, 12);

    test('dropped on the right half of another area, it goes beside it', () {
      drag(<Offset>[
        tab,
        const Offset(60, 40),
        const Offset(600, 250),
        const Offset(740, 250),
      ]);
      expect(layout.hierarchy(nameInfo: true), 'R(ISEARCH,IDOCUMENT,IFILES)');
    });

    test('dropped in the middle of an area, it joins it as a tab', () {
      drag(<Offset>[tab, const Offset(60, 40), const Offset(600, 250)]);
      expect(
          layout.hierarchy(nameInfo: true), 'R(ISEARCH,T(IDOCUMENT,IFILES))');
    });

    test('dropped on the edge of the whole layout, it spans it', () {
      drag(<Offset>[tab, const Offset(60, 200), const Offset(400, 490)]);
      expect(
          layout.hierarchy(nameInfo: true), 'C(R(ISEARCH,IDOCUMENT),IFILES)');
    });

    test('dropped outside, it floats', () {
      drag(<Offset>[tab, const Offset(60, 200), const Offset(-60, 200)]);
      expect(floated?.id, 'files');
      expect(layout.findDockingItem('files'), isNull);
    });

    test('a click on a tab is not a drag', () {
      drag(<Offset>[tab, const Offset(22, 13)]);
      expect(
          layout.hierarchy(nameInfo: true), 'R(T(IFILES,ISEARCH),IDOCUMENT)');
    });

    test('a floated item goes back where it was', () {
      final DockingItem files = layout.findDockingItem('files')!;
      final placement = layout.placementOf(files);
      layout.removeItem(item: files);
      layout.restoreItem(files, placement);
      expect(
          layout.hierarchy(nameInfo: true), 'R(T(ISEARCH,IFILES),IDOCUMENT)');
    });
  });
}
