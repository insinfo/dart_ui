/// Collections, menus, the combo box, the expander and the scrollbar
/// performing the actions they declare.
///
/// `semantics_actions_test.dart` covers the controls that go through
/// `ControlBehavior` alone - button, toggle, slider, text field. The controls
/// here declared actions that `ControlBehavior` answers with an empty
/// `activate()` or a flat `false`: a list row whose `activate` selected
/// nothing and reported success, a tree that published `expanded` with no way
/// to open it, a menu that declared `dismiss` with nothing to call. Each group
/// asserts the action does what the equivalent click or key does, *and* that
/// the refusal cases answer false rather than a success that changed nothing.
///
/// Everything here is in-process and platform-independent; the Windows end
/// of the same path is `test/backends/win32/uia/`.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() {
    expect(
      FontRegistry.instance.useFontFile('test/fonts/Roboto-Regular.ttf'),
      isTrue,
    );
  });
  tearDownAll(FontRegistry.instance.reset);

  group('a list box', () {
    test('activate on a row selects it and scrolls it into view', () {
      final _ListHarness harness = _ListHarness(itemCount: 50)..frame();
      final RenderListItem row = harness.rowAt(3);

      expect(
          row.describeSemantics().actions, contains(SemanticsAction.activate));
      expect(row.performSemanticsAction(SemanticsAction.activate), isTrue);
      expect(harness.selected, 3);
      harness.dispose();
    });

    test('scrollDown pages the list, and scrollUp at the top is refused', () {
      final _ListHarness harness = _ListHarness(itemCount: 50)..frame();
      final RenderListBox list = harness.list;

      expect(
        list.describeSemantics().actions,
        containsAll(<SemanticsAction>[
          SemanticsAction.scrollUp,
          SemanticsAction.scrollDown,
        ]),
      );
      expect(list.performSemanticsAction(SemanticsAction.scrollUp), isFalse);
      expect(harness.scroll.pixels, 0);

      expect(list.performSemanticsAction(SemanticsAction.scrollDown), isTrue);
      expect(harness.scroll.pixels, greaterThan(0));
      harness.dispose();
    });

    test('activate on a row of a short list that cannot scroll still selects',
        () {
      final _ListHarness harness = _ListHarness(itemCount: 3)..frame();

      expect(
        harness.rowAt(1).performSemanticsAction(SemanticsAction.activate),
        isTrue,
      );
      expect(harness.selected, 1);
      expect(
        harness.list.performSemanticsAction(SemanticsAction.scrollDown),
        isFalse,
        reason: 'nothing to scroll, so nothing scrolled',
      );
      harness.dispose();
    });
  });

  group('a tree view', () {
    test('activate selects the row, as a click on its label does', () {
      final _TreeHarness harness = _TreeHarness()..frame();

      expect(
        harness.rowLabelled('README').performSemanticsAction(
              SemanticsAction.activate,
            ),
        isTrue,
      );
      expect(harness.selected, 'README');
      harness.dispose();
    });

    test('showMenu expands and dismiss collapses, through onToggle', () {
      final _TreeHarness harness = _TreeHarness()..frame();
      final RenderTreeItem src = harness.rowLabelled('src');

      // Collapsed: only the expand direction is on offer.
      expect(
          src.describeSemantics().actions, contains(SemanticsAction.showMenu));
      expect(
        src.describeSemantics().actions,
        isNot(contains(SemanticsAction.dismiss)),
      );
      expect(src.performSemanticsAction(SemanticsAction.dismiss), isFalse);

      expect(src.performSemanticsAction(SemanticsAction.showMenu), isTrue);
      expect(harness.expanded, contains('src'));
      harness.frame();
      expect(harness.realizedLabels, <String>['src', 'a', 'b', 'README']);

      final RenderTreeItem opened = harness.rowLabelled('src');
      expect(
        opened.describeSemantics().states,
        contains(SemanticsState.expanded),
      );
      expect(
        opened.describeSemantics().actions,
        contains(SemanticsAction.dismiss),
      );
      expect(opened.performSemanticsAction(SemanticsAction.showMenu), isFalse);
      expect(opened.performSemanticsAction(SemanticsAction.dismiss), isTrue);
      expect(harness.expanded, isNot(contains('src')));
      harness.dispose();
    });

    test('a leaf declares neither direction and refuses both', () {
      final _TreeHarness harness = _TreeHarness()..frame();
      final RenderTreeItem leaf = harness.rowLabelled('README');

      expect(
        leaf.describeSemantics().actions,
        <SemanticsAction>{SemanticsAction.activate},
      );
      expect(leaf.performSemanticsAction(SemanticsAction.showMenu), isFalse);
      expect(leaf.performSemanticsAction(SemanticsAction.dismiss), isFalse);
      harness.dispose();
    });

    test('a disabled row declares nothing and refuses everything', () {
      final _TreeHarness harness = _TreeHarness(nodes: <TreeNode>[
        const TreeNode(
          label: 'locked',
          enabled: false,
          children: <TreeNode>[TreeNode(label: 'x')],
        ),
      ])
        ..frame();
      final RenderTreeItem locked = harness.rowLabelled('locked');

      expect(locked.describeSemantics().actions, isEmpty);
      expect(locked.performSemanticsAction(SemanticsAction.activate), isFalse);
      expect(locked.performSemanticsAction(SemanticsAction.showMenu), isFalse);
      expect(harness.selected, isNull);
      expect(harness.expanded, isEmpty);
      harness.dispose();
    });

    test('scrollDown pages the tree', () {
      final _TreeHarness harness = _TreeHarness(
        nodes: <TreeNode>[
          for (int i = 0; i < 40; i++) TreeNode(label: 'row $i'),
        ],
        height: 100,
      )..frame();

      expect(
        harness.tree.performSemanticsAction(SemanticsAction.scrollUp),
        isFalse,
      );
      expect(
        harness.tree.performSemanticsAction(SemanticsAction.scrollDown),
        isTrue,
      );
      expect(harness.scroll.pixels, greaterThan(0));
      harness.dispose();
    });
  });

  group('a data grid', () {
    test('activate on a row is a plain click: it becomes the selection', () {
      final _GridHarness harness = _GridHarness(rowCount: 20)..frame();

      expect(
        harness.rowAt(2).performSemanticsAction(SemanticsAction.activate),
        isTrue,
      );
      expect(harness.selection, <int>{2});
      harness.frame();
      expect(
        harness.rowAt(2).describeSemantics().states,
        contains(SemanticsState.selected),
      );
      harness.dispose();
    });

    test('in multiple mode a second activate replaces, as a bare click does',
        () {
      final _GridHarness harness = _GridHarness(
        rowCount: 20,
        selectionMode: DataGridSelectionMode.multiple,
      )..frame();

      harness.rowAt(1).performSemanticsAction(SemanticsAction.activate);
      harness.frame();
      harness.rowAt(4).performSemanticsAction(SemanticsAction.activate);
      expect(harness.selection, <int>{4});
      harness.dispose();
    });

    test('scrollDown pages the body', () {
      final _GridHarness harness = _GridHarness(rowCount: 40)..frame();

      expect(
        harness.body.performSemanticsAction(SemanticsAction.scrollUp),
        isFalse,
      );
      expect(
        harness.body.performSemanticsAction(SemanticsAction.scrollDown),
        isTrue,
      );
      expect(harness.scroll.pixels, greaterThan(0));
      harness.dispose();
    });
  });

  group('a menu', () {
    test('declares dismiss only when it has somewhere to send it', () {
      final BuildOwner owner = _owner();
      owner.updateRoot(const Menu(items: <MenuItem>[MenuItem(label: 'One')]));
      owner.pipelineOwner.drawFrame(DisplayList());
      final RenderMenu fixed = owner.renderRoot! as RenderMenu;

      expect(
        fixed.describeSemantics().actions,
        isNot(contains(SemanticsAction.dismiss)),
      );
      expect(fixed.performSemanticsAction(SemanticsAction.dismiss), isFalse);
      owner.dispose();
    });

    test('dismiss and Escape both reach onDismiss', () {
      var dismissed = 0;
      final BuildOwner owner = _owner();
      owner.updateRoot(Menu(
        items: const <MenuItem>[MenuItem(label: 'One')],
        onDismiss: () => dismissed++,
      ));
      owner.pipelineOwner.drawFrame(DisplayList());
      final RenderMenu menu = owner.renderRoot! as RenderMenu;

      expect(
          menu.describeSemantics().actions, contains(SemanticsAction.dismiss));
      expect(menu.performSemanticsAction(SemanticsAction.dismiss), isTrue);
      expect(dismissed, 1);

      expect(menu.handleKeyEvent(_key(logicalKeyEscape)), isTrue);
      expect(dismissed, 2);
      owner.dispose();
    });

    test('activate with nothing highlighted is refused, not reported done', () {
      final List<String> chosen = <String>[];
      final BuildOwner owner = _owner();
      owner.updateRoot(Menu(items: <MenuItem>[
        MenuItem(label: 'One', onSelected: () => chosen.add('One')),
      ]));
      owner.pipelineOwner.drawFrame(DisplayList());
      final RenderMenu menu = owner.renderRoot! as RenderMenu;

      expect(menu.performSemanticsAction(SemanticsAction.activate), isFalse);
      expect(chosen, isEmpty);

      menu.handleKeyEvent(_key(logicalKeyArrowDown));
      expect(menu.performSemanticsAction(SemanticsAction.activate), isTrue);
      expect(chosen, <String>['One']);
      owner.dispose();
    });
  });

  group('a context menu', () {
    test('focus on an item moves the keyboard cursor onto it', () {
      final _ContextMenuHarness harness = _ContextMenuHarness()
        ..frame()
        ..rightClick(const Offset(40, 30))
        ..frame();
      expect(harness.highlightedLabel, isNull);

      final RenderContextMenuItem duplicate = harness.itemLabelled('Duplicate');
      expect(
        duplicate.describeSemantics().actions,
        contains(SemanticsAction.focus),
      );
      expect(duplicate.performSemanticsAction(SemanticsAction.focus), isTrue);
      expect(harness.highlightedLabel, 'Duplicate');
      harness.dispose();
    });

    test('activate on a disabled item is refused, on an enabled one runs it',
        () {
      final _ContextMenuHarness harness = _ContextMenuHarness()
        ..frame()
        ..rightClick(const Offset(40, 30))
        ..frame();

      final RenderContextMenuItem delete = harness.itemLabelled('Delete');
      expect(
        delete.describeSemantics().actions,
        isNot(contains(SemanticsAction.activate)),
      );
      expect(delete.performSemanticsAction(SemanticsAction.activate), isFalse);
      expect(harness.chosen, isEmpty);

      final RenderContextMenuItem refresh = harness.itemLabelled('Refresh');
      expect(refresh.performSemanticsAction(SemanticsAction.activate), isTrue);
      expect(harness.chosen, <String>['Refresh']);
      harness.dispose();
    });

    test('dismiss on the surface closes the menu', () {
      final _ContextMenuHarness harness = _ContextMenuHarness()
        ..frame()
        ..rightClick(const Offset(40, 30))
        ..frame();
      final RenderContextMenuSurface surface = harness.surface!;

      expect(surface.describeSemantics().actions,
          contains(SemanticsAction.dismiss));
      expect(surface.performSemanticsAction(SemanticsAction.dismiss), isTrue);
      harness.frame();
      expect(harness.surface, isNull);
      harness.dispose();
    });

    test('activate on the surface with no highlight is refused', () {
      final _ContextMenuHarness harness = _ContextMenuHarness()
        ..frame()
        ..rightClick(const Offset(40, 30))
        ..frame();
      final RenderContextMenuSurface surface = harness.surface!;

      expect(surface.performSemanticsAction(SemanticsAction.activate), isFalse);
      expect(harness.chosen, isEmpty);
      harness.dispose();
    });
  });

  group('a combo box', () {
    test('showMenu opens, is refused while open, and dismiss closes', () {
      final _ComboHarness harness = _ComboHarness()..frame();
      final RenderComboBoxField field = harness.field;

      expect(field.describeSemantics().actions,
          contains(SemanticsAction.showMenu));
      expect(
        field.describeSemantics().actions,
        isNot(contains(SemanticsAction.dismiss)),
      );
      expect(field.performSemanticsAction(SemanticsAction.dismiss), isFalse);

      expect(field.performSemanticsAction(SemanticsAction.showMenu), isTrue);
      harness.frame();
      expect(harness.overlay.isOpen, isTrue);
      expect(harness.field.isOpen, isTrue);
      expect(
        harness.field.describeSemantics().states,
        contains(SemanticsState.expanded),
      );
      expect(
        harness.field.describeSemantics().actions,
        contains(SemanticsAction.dismiss),
      );
      expect(
        harness.field.performSemanticsAction(SemanticsAction.showMenu),
        isFalse,
        reason: 'already open: Expand on an expanded control changes nothing',
      );

      expect(
        harness.field.performSemanticsAction(SemanticsAction.dismiss),
        isTrue,
      );
      harness.frame();
      expect(harness.overlay.isOpen, isFalse);
      expect(harness.field.isOpen, isFalse);
      expect(harness.changes, isEmpty, reason: 'dismiss commits nothing');
      harness.dispose();
    });

    test('a disabled combo box declares nothing and refuses showMenu', () {
      final _ComboHarness harness = _ComboHarness(enabled: false)..frame();

      expect(harness.field.describeSemantics().actions, isEmpty);
      expect(
        harness.field.performSemanticsAction(SemanticsAction.showMenu),
        isFalse,
      );
      expect(harness.overlay.isOpen, isFalse);
      harness.dispose();
    });
  });

  group('an expander', () {
    test('showMenu expands and dismiss collapses, each refused when moot', () {
      final List<bool> changes = <bool>[];
      final BuildOwner owner = _owner(size: const Size(200, 120));
      owner.updateRoot(Directionality(
        textDirection: TextDirection.leftToRight,
        child: Expander(
          header: 'Details',
          expanded: false,
          onExpandedChanged: changes.add,
          content: const SizedBox(width: 10, height: 10),
        ),
      ));
      owner.pipelineOwner.drawFrame(DisplayList());
      final RenderExpanderHeader header = _find<RenderExpanderHeader>(owner);

      expect(header.describeSemantics().actions,
          contains(SemanticsAction.showMenu));
      expect(
        header.describeSemantics().actions,
        isNot(contains(SemanticsAction.dismiss)),
      );
      expect(header.performSemanticsAction(SemanticsAction.dismiss), isFalse);
      expect(header.performSemanticsAction(SemanticsAction.showMenu), isTrue);
      expect(changes, <bool>[true]);

      owner.updateRoot(Directionality(
        textDirection: TextDirection.leftToRight,
        child: Expander(
          header: 'Details',
          expanded: true,
          onExpandedChanged: changes.add,
          content: const SizedBox(width: 10, height: 10),
        ),
      ));
      owner.pipelineOwner.drawFrame(DisplayList());
      final RenderExpanderHeader open = _find<RenderExpanderHeader>(owner);
      expect(
          open.describeSemantics().actions, contains(SemanticsAction.dismiss));
      expect(open.performSemanticsAction(SemanticsAction.showMenu), isFalse);
      expect(open.performSemanticsAction(SemanticsAction.dismiss), isTrue);
      expect(changes, <bool>[true, false]);
      owner.dispose();
    });

    test('an expander without a callback is disabled and declares nothing', () {
      final BuildOwner owner = _owner(size: const Size(200, 120));
      owner.updateRoot(const Directionality(
        textDirection: TextDirection.leftToRight,
        child: Expander(
          header: 'Details',
          expanded: false,
          content: SizedBox(width: 10, height: 10),
        ),
      ));
      owner.pipelineOwner.drawFrame(DisplayList());
      final RenderExpanderHeader header = _find<RenderExpanderHeader>(owner);

      expect(header.describeSemantics().actions, isEmpty);
      expect(header.performSemanticsAction(SemanticsAction.showMenu), isFalse);
      owner.dispose();
    });
  });

  group('a scrollbar', () {
    test('a vertical bar pages on scrollDown and refuses at the ends', () {
      final ScrollPosition position =
          ScrollPosition(viewportExtent: 100, contentExtent: 400);
      final BuildOwner owner = _owner(size: const Size(200, 100));
      owner.updateRoot(Scrollbar(
        position: position,
        child: const SizedBox(width: 200, height: 100),
      ));
      owner.pipelineOwner.drawFrame(DisplayList());
      final RenderScrollbar bar = _find<RenderScrollbar>(owner);

      expect(
        bar.describeSemantics().actions,
        <SemanticsAction>{SemanticsAction.scrollUp, SemanticsAction.scrollDown},
      );
      expect(bar.performSemanticsAction(SemanticsAction.scrollUp), isFalse);
      expect(bar.performSemanticsAction(SemanticsAction.scrollDown), isTrue);
      expect(position.pixels, greaterThan(0));
      expect(
        bar.performSemanticsAction(SemanticsAction.scrollRight),
        isFalse,
        reason: 'the other axis is not this bar\'s to move',
      );
      owner.dispose();
    });

    test('a horizontal bar declares left/right and pages on scrollRight', () {
      final ScrollPosition position = ScrollPosition(
        axis: ScrollAxis.horizontal,
        viewportExtent: 200,
        contentExtent: 800,
      );
      final BuildOwner owner = _owner(size: const Size(200, 100));
      owner.updateRoot(Scrollbar(
        position: position,
        child: const SizedBox(width: 200, height: 100),
      ));
      owner.pipelineOwner.drawFrame(DisplayList());
      final RenderScrollbar bar = _find<RenderScrollbar>(owner);

      expect(
        bar.describeSemantics().actions,
        <SemanticsAction>{
          SemanticsAction.scrollLeft,
          SemanticsAction.scrollRight,
        },
      );
      expect(bar.performSemanticsAction(SemanticsAction.scrollDown), isFalse);
      expect(bar.performSemanticsAction(SemanticsAction.scrollRight), isTrue);
      expect(position.pixels, greaterThan(0));
      owner.dispose();
    });
  });

  group('the owner routes to these through the ids it published', () {
    test('a list row by id', () {
      final _ListHarness harness = _ListHarness(itemCount: 10)..frame();
      final SemanticsSnapshot tree = harness.owner.buildSemantics();
      final SemanticsNode row = tree.nodes.firstWhere((SemanticsNode node) =>
          node.role == SemanticsRole.listItem && node.value == '5');

      expect(
        harness.owner.semanticsOwner
            .performAction(row.id, SemanticsAction.activate),
        isTrue,
      );
      expect(harness.selected, 4);
      harness.dispose();
    });

    test('an undeclared direction on a tree row is refused by the owner', () {
      final _TreeHarness harness = _TreeHarness()..frame();
      final SemanticsSnapshot tree = harness.owner.buildSemantics();
      final SemanticsNode src = tree.nodes.firstWhere((SemanticsNode node) =>
          node.role == SemanticsRole.listItem && node.label == 'src');

      expect(
        harness.owner.semanticsOwner
            .performAction(src.id, SemanticsAction.dismiss),
        isFalse,
        reason: 'collapsed: dismiss was not in the snapshot the client read',
      );
      expect(
        harness.owner.semanticsOwner
            .performAction(src.id, SemanticsAction.showMenu),
        isTrue,
      );
      expect(harness.expanded, contains('src'));
      harness.dispose();
    });
  });
}

BuildOwner _owner({Size size = const Size(200, 60)}) => BuildOwner(
      pipelineOwner: PipelineOwner(rootConstraints: BoxConstraints.tight(size)),
    );

KeyDownEvent _key(int logicalKey) => KeyDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      physicalKey: logicalKey,
      logicalKey: logicalKey,
    );

/// The first render object of type [T] under the root.
T _find<T extends RenderBox>(BuildOwner owner) {
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
  return found ?? (throw StateError('no $T in the tree'));
}

/// Every render object of type [T] under the root, in tree order.
List<T> _findAll<T extends RenderBox>(BuildOwner owner) {
  final List<T> found = <T>[];
  void walk(RenderBox node) {
    if (node is T) found.add(node);
    node.visitChildren(walk);
  }

  walk(owner.renderRoot!);
  return found;
}

final class _ListHarness {
  _ListHarness({required this.itemCount}) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(200, 100)),
      ),
    );
  }

  final int itemCount;
  final ScrollPosition scroll = ScrollPosition();
  late final BuildOwner owner;
  int? selected;

  void _mount() => owner.updateRoot(ListBox(
        itemCount: itemCount,
        itemExtent: 20,
        cacheExtent: 0,
        controller: scroll,
        selectedIndex: selected,
        onSelected: (int index) => selected = index,
        itemBuilder: (BuildContext context, int index) => Text('ITEM $index'),
      ));

  void frame({int maxPasses = 8}) {
    for (int pass = 0; pass < maxPasses; pass++) {
      _mount();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
    throw StateError('the list never settled');
  }

  RenderListBox get list => _find<RenderListBox>(owner);

  RenderListItem rowAt(int index) => _findAll<RenderListItem>(owner)
      .firstWhere((RenderListItem row) => row.index == index);

  void dispose() => owner.dispose();
}

final class _TreeHarness {
  _TreeHarness({List<TreeNode>? nodes, double height = 400})
      : nodes = nodes ?? _defaultNodes {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(Size(200, height)),
      ),
    );
  }

  static const List<TreeNode> _defaultNodes = <TreeNode>[
    TreeNode(label: 'src', children: <TreeNode>[
      TreeNode(label: 'a'),
      TreeNode(label: 'b'),
    ]),
    TreeNode(label: 'README'),
  ];

  final List<TreeNode> nodes;
  final Set<Object> expanded = <Object>{};
  Object? selected;
  final ScrollPosition scroll = ScrollPosition();
  late final BuildOwner owner;

  void _mount() => owner.updateRoot(Directionality(
        textDirection: TextDirection.leftToRight,
        child: TreeView(
          nodes: nodes,
          rowExtent: 20,
          cacheExtent: 0,
          controller: scroll,
          expandedIds: expanded,
          selectedId: selected,
          onToggle: (TreeNode node, bool expand) {
            if (expand) {
              expanded.add(node.identity);
            } else {
              expanded.remove(node.identity);
            }
          },
          onSelected: (TreeNode node) => selected = node.identity,
        ),
      ));

  void frame({int maxPasses = 8}) {
    for (int pass = 0; pass < maxPasses; pass++) {
      _mount();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
    throw StateError('the tree never settled');
  }

  RenderTreeView get tree => _find<RenderTreeView>(owner);

  List<String> get realizedLabels => <String>[
        for (final RenderTreeItem row in _findAll<RenderTreeItem>(owner))
          row.label,
      ];

  RenderTreeItem rowLabelled(String label) => _findAll<RenderTreeItem>(owner)
      .firstWhere((RenderTreeItem row) => row.label == label);

  void dispose() => owner.dispose();
}

final class _GridHarness {
  _GridHarness({
    required this.rowCount,
    this.selectionMode = DataGridSelectionMode.single,
  }) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        // 28 px of header on the neutral theme plus six 20-px rows.
        rootConstraints: BoxConstraints.tight(const Size(220, 148)),
      ),
    );
  }

  final int rowCount;
  final DataGridSelectionMode selectionMode;
  final ScrollPosition scroll = ScrollPosition();
  late final BuildOwner owner;
  Set<int> selection = <int>{};

  void _mount() => owner.updateRoot(Directionality(
        textDirection: TextDirection.leftToRight,
        child: DataGrid(
          columns: const <DataGridColumn>[
            DataGridColumn(title: 'Name', width: 100),
            DataGridColumn(title: 'Size', width: 80),
          ],
          rowCount: rowCount,
          rowExtent: 20,
          cacheExtent: 0,
          controller: scroll,
          selectionMode: selectionMode,
          selectedRows: selection,
          onSelectionChanged: (Set<int> rows) => selection = rows,
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

  RenderDataGridBody get body => _find<RenderDataGridBody>(owner);

  RenderDataGridRow rowAt(int index) => _findAll<RenderDataGridRow>(owner)
      .firstWhere((RenderDataGridRow row) => row.index == index);

  void dispose() => owner.dispose();
}

final class _ContextMenuHarness {
  _ContextMenuHarness() {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(300, 200)),
      ),
    );
    owner.updateRoot(_root());
  }

  late final BuildOwner owner;
  final ContextMenuController controller = ContextMenuController();
  final List<String> chosen = <String>[];

  Widget _root() => ContextMenuScope(
        controller: controller,
        child: ContextMenuRegion(
          itemsBuilder: () => <MenuItem>[
            MenuItem(label: 'Refresh', onSelected: () => chosen.add('Refresh')),
            MenuItem(
              label: 'Duplicate',
              onSelected: () => chosen.add('Duplicate'),
            ),
            const MenuItem.separator(),
            MenuItem(
              label: 'Delete',
              enabled: false,
              disabledReason: 'nothing here is selected',
              onSelected: () => chosen.add('Delete'),
            ),
          ],
          child: Column(
            children: <Widget>[
              Button(label: 'Behind', onPressed: () {}),
            ],
          ),
        ),
      );

  void frame({int maxPasses = 8}) {
    for (int pass = 0; pass < maxPasses; pass++) {
      owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
    throw StateError('the tree never settled');
  }

  void rightClick(Offset position) {
    owner.dispatchPointerEvent(PointerDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: position,
      button: PointerButton.secondary,
    ));
    owner.dispatchPointerEvent(PointerUpEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: position,
      button: PointerButton.secondary,
    ));
  }

  RenderContextMenuSurface? get surface {
    final List<RenderContextMenuSurface> found =
        _findAll<RenderContextMenuSurface>(owner);
    return found.isEmpty ? null : found.first;
  }

  RenderContextMenuItem itemLabelled(String label) =>
      _findAll<RenderContextMenuItem>(owner).firstWhere(
        (RenderContextMenuItem item) => item.item.label == label,
      );

  String? get highlightedLabel => surface?.highlightedItem?.item.label;

  void dispose() => owner.dispose();
}

final class _ComboHarness {
  _ComboHarness({this.enabled = true}) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(300, 200)),
      ),
    );
  }

  final bool enabled;
  late final BuildOwner owner;
  final ComboBoxOverlay overlay = ComboBoxOverlay();
  final List<String> changes = <String>[];
  String? value = 'br';

  Widget _root() => Directionality(
        textDirection: TextDirection.leftToRight,
        child: ComboBoxScope(
          overlay: overlay,
          child: Column(
            children: <Widget>[
              SizedBox(
                width: 120,
                child: ComboBox<String>(
                  items: const <ComboBoxItem<String>>[
                    ComboBoxItem<String>(value: 'br', label: 'Brazil'),
                    ComboBoxItem<String>(value: 'pt', label: 'Portugal'),
                    ComboBoxItem<String>(value: 'ar', label: 'Argentina'),
                  ],
                  value: value,
                  label: 'Country',
                  itemExtent: 22,
                  onChanged: enabled
                      ? (String next) {
                          changes.add(next);
                          value = next;
                        }
                      : null,
                ),
              ),
            ],
          ),
        ),
      );

  void frame({int maxPasses = 8}) {
    for (int pass = 0; pass < maxPasses; pass++) {
      owner.updateRoot(_root());
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
    throw StateError('the tree never settled');
  }

  RenderComboBoxField get field => _find<RenderComboBoxField>(owner);

  void dispose() => owner.dispose();
}
