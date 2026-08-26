import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('TreeView structure', () {
    test('collapsed nodes contribute no rows', () {
      final harness = _TreeHarness(nodes: _fileTree());
      harness.frame();

      // Only the three roots are visible while nothing is expanded.
      expect(harness.realizedLabels, <String>['src', 'assets', 'README']);
      harness.dispose();
    });

    test('expanding a node reveals its children in place', () {
      final harness = _TreeHarness(nodes: _fileTree());
      harness.expanded.add('src');
      harness.frame();

      expect(harness.realizedLabels,
          <String>['src', 'widgets', 'rendering', 'assets', 'README']);

      harness.expanded.add('widgets');
      harness.frame();
      expect(harness.realizedLabels, <String>[
        'src',
        'widgets',
        'tree_view.dart',
        'data_grid.dart',
        'rendering',
        'assets',
        'README',
      ]);
      harness.dispose();
    });

    test('a huge flat tree realizes a bounded window of rows', () {
      final harness = _TreeHarness(
        nodes: <TreeNode>[
          for (int i = 0; i < 100000; i++) TreeNode(label: 'node $i'),
        ],
        height: 100,
      );
      harness.frame();

      expect(harness.tree.virtualization.itemCount, 100000);
      expect(harness.tree.childCount, lessThan(20));
      expect(harness.tree.childCount, greaterThan(3));
      harness.dispose();
    });

    test('a wheel event scrolls the tree', () {
      final harness = _TreeHarness(
        nodes: <TreeNode>[
          for (int i = 0; i < 1000; i++) TreeNode(label: 'node $i'),
        ],
        height: 100,
      );
      harness.frame();

      harness.tree.handlePointerEvent(const PointerScrollEvent(
        windowId: NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: Offset(10, 10),
        scrollDelta: Offset(0, 3),
        scrollDeltaUnit: ScrollDeltaUnit.lines,
      ));

      expect(harness.scroll.pixels, 3 * defaultLineExtent);
      harness.dispose();
    });
  });

  group('TreeView keyboard', () {
    test('arrows move the selection and keep it visible', () {
      final harness = _TreeHarness(
        nodes: <TreeNode>[
          for (int i = 0; i < 100; i++) TreeNode(label: 'node $i'),
        ],
        height: 100,
      );
      harness.frame();

      for (int i = 0; i < 8; i++) {
        harness.tree.handleKeyEvent(_key(logicalKeyArrowDown));
        harness.frame();
      }

      expect(harness.selected, 'node 7');
      // The viewport shows five 20-px rows, so row 7 required a scroll.
      expect(harness.scroll.pixels, greaterThan(0));
      harness.dispose();
    });

    test('right expands, right again enters, left collapses toward the root',
        () {
      final harness = _TreeHarness(nodes: _fileTree());
      harness.frame();
      harness.tree.handleKeyEvent(_key(logicalKeyHome));
      harness.frame();
      expect(harness.selected, 'src');

      harness.tree.handleKeyEvent(_key(logicalKeyArrowRight));
      harness.frame();
      expect(harness.expanded, contains('src'));

      harness.tree.handleKeyEvent(_key(logicalKeyArrowRight));
      harness.frame();
      expect(harness.selected, 'widgets', reason: 'right enters the children');

      harness.tree.handleKeyEvent(_key(logicalKeyArrowLeft));
      harness.frame();
      expect(harness.selected, 'src', reason: 'left on a leaf goes to parent');

      harness.tree.handleKeyEvent(_key(logicalKeyArrowLeft));
      harness.frame();
      expect(harness.expanded, isNot(contains('src')),
          reason: 'left on an expanded node collapses it');
      harness.dispose();
    });

    test('Home and End jump to the first and last visible row', () {
      final harness = _TreeHarness(nodes: _fileTree());
      harness.expanded.addAll(<Object>['src', 'widgets']);
      harness.frame();

      harness.tree.handleKeyEvent(_key(logicalKeyEnd));
      harness.frame();
      expect(harness.selected, 'README');

      harness.tree.handleKeyEvent(_key(logicalKeyHome));
      harness.frame();
      expect(harness.selected, 'src');
      harness.dispose();
    });

    test('the keypad asterisk expands every sibling of the current row', () {
      final harness = _TreeHarness(nodes: _fileTree());
      harness.frame();
      harness.tree.handleKeyEvent(_key(logicalKeyHome));
      harness.frame();

      harness.tree.handleKeyEvent(_key(logicalKeyNumpadMultiply));
      harness.frame();

      // 'src' and 'assets' are expandable roots; 'README' is a leaf.
      expect(harness.expanded, containsAll(<Object>['src', 'assets']));
      harness.dispose();
    });

    test('Enter toggles an expandable row', () {
      final harness = _TreeHarness(nodes: _fileTree());
      harness.frame();
      harness.tree.handleKeyEvent(_key(logicalKeyHome));
      harness.frame();

      harness.tree.handleKeyEvent(_key(logicalKeyEnter));
      harness.frame();
      expect(harness.expanded, contains('src'));

      harness.tree.handleKeyEvent(_key(logicalKeyEnter));
      harness.frame();
      expect(harness.expanded, isNot(contains('src')));
      harness.dispose();
    });
  });

  group('TreeView pointer', () {
    test('a press on the toggle gutter expands without selecting', () {
      final harness = _TreeHarness(nodes: _fileTree());
      harness.frame();

      // Row 0 is 'src' at depth 0: its toggle gutter is x 0..16.
      harness.tree.handlePointerEvent(_press(const Offset(8, 10)));
      harness.frame();

      expect(harness.expanded, contains('src'));
      expect(harness.selected, isNull);
      harness.dispose();
    });

    test('a press on the label selects without toggling', () {
      final harness = _TreeHarness(nodes: _fileTree());
      harness.frame();

      harness.tree.handlePointerEvent(_press(const Offset(60, 10)));
      harness.frame();

      expect(harness.selected, 'src');
      expect(harness.expanded, isEmpty);
      harness.dispose();
    });
  });

  group('TreeView lazy loading', () {
    test('expanding a childless expandable node asks the owner for children',
        () {
      final harness = _TreeHarness(nodes: <TreeNode>[
        const TreeNode(label: 'remote', hasChildren: true),
      ]);
      harness.frame();
      expect(harness.realizedLabels, <String>['remote']);

      harness.tree.handleKeyEvent(_key(logicalKeyHome));
      harness.frame();
      harness.tree.handleKeyEvent(_key(logicalKeyArrowRight));
      // The owner loads the children in response to the toggle, then
      // rebuilds - the handshake the widget documents.
      harness.nodes = <TreeNode>[
        const TreeNode(label: 'remote', hasChildren: true, children: <TreeNode>[
          TreeNode(label: 'loaded 1'),
          TreeNode(label: 'loaded 2'),
        ]),
      ];
      harness.frame();

      expect(harness.expanded, contains('remote'));
      expect(
          harness.realizedLabels, <String>['remote', 'loaded 1', 'loaded 2']);
      harness.dispose();
    });
  });

  group('TreeView semantics', () {
    test('the tree reports the full row count and rows report their level', () {
      final harness = _TreeHarness(nodes: _fileTree());
      harness.expanded.add('src');
      harness.selected = 'widgets';
      harness.frame();

      final SemanticsSnapshot snapshot =
          SemanticsOwner().build(harness.owner.renderRoot);
      final SemanticsNode treeNode = snapshot.nodes.firstWhere(
        (SemanticsNode node) => node.role == SemanticsRole.list,
      );
      expect(treeNode.value, '5 items');

      final SemanticsNode widgetsRow = snapshot.nodes.firstWhere(
        (SemanticsNode node) => node.label == 'widgets',
      );
      expect(widgetsRow.role, SemanticsRole.listItem);
      expect(widgetsRow.value, 'level 2');
      expect(widgetsRow.states, contains(SemanticsState.selected));

      final SemanticsNode srcRow = snapshot.nodes.firstWhere(
        (SemanticsNode node) => node.label == 'src',
      );
      expect(srcRow.states, contains(SemanticsState.expanded));
      harness.dispose();
    });
  });
}

/// A small file-explorer shaped tree: two expandable roots and a leaf.
List<TreeNode> _fileTree() => const <TreeNode>[
      TreeNode(label: 'src', children: <TreeNode>[
        TreeNode(label: 'widgets', children: <TreeNode>[
          TreeNode(label: 'tree_view.dart'),
          TreeNode(label: 'data_grid.dart'),
        ]),
        TreeNode(label: 'rendering'),
      ]),
      TreeNode(label: 'assets', children: <TreeNode>[
        TreeNode(label: 'icon.png'),
      ]),
      TreeNode(label: 'README'),
    ];

final class _TreeHarness {
  /// [height] defaults to room for twenty rows, so structure tests see every
  /// row of a small tree; virtualization tests pass a short viewport.
  _TreeHarness({required this.nodes, double height = 400}) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(Size(200, height)),
      ),
    );
    _mount();
  }

  List<TreeNode> nodes;
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

  RenderTreeView get tree {
    RenderTreeView? found;
    void walk(RenderBox node) {
      if (found != null) return;
      if (node is RenderTreeView) {
        found = node;
        return;
      }
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found!;
  }

  List<String> get realizedLabels => <String>[
        for (int i = 0; i < tree.childCount; i++)
          (tree.childAt(i) as RenderTreeItem).label,
      ];

  void dispose() => owner.dispose();
}

KeyDownEvent _key(int logicalKey) => KeyDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      physicalKey: logicalKey,
      logicalKey: logicalKey,
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
