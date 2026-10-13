/// The Ribbon: tabs of command groups, command binding, columns of three,
/// the right-to-left shrinking that makes it a ribbon, the collapsed ribbon's
/// floating panel, and its keyboard.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

const NativeWindowId _window = NativeWindowId(1);

KeyDownEvent _down(int key, {Set<KeyModifier> modifiers = const {}}) =>
    KeyDownEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration.zero,
      physicalKey: key,
      logicalKey: key,
      modifiers: modifiers,
    );

void main() {
  setUpAll(() {
    expect(
      FontRegistry.instance.useFontFile('test/fonts/Roboto-Regular.ttf'),
      isTrue,
    );
  });
  tearDownAll(FontRegistry.instance.reset);

  group('tabs', () {
    test('switching tabs shows that tab\'s groups and only those', () {
      final _Harness h = _Harness()..frame();
      expect(h.control('Cut'), isNotNull);
      expect(h.control('Table'), isNull, reason: 'Insert is not built');

      h
        ..click(h.control('Insert')!)
        ..frame();
      expect(h.changes, <int>[1]);
      expect(h.control('Table'), isNotNull);
      expect(h.control('Cut'), isNull);
      expect(h.control('Insert')!.selected, isTrue);
      expect(h.control('Home')!.selected, isFalse);
      h.dispose();
    });

    test('the strip is a list of tabs with one selected', () {
      final _Harness h = _Harness()..frame();
      final SemanticsConfiguration home =
          h.control('Home')!.describeSemantics();
      expect(home.role, SemanticsRole.listItem);
      expect(home.states, contains(SemanticsState.selected));
      expect(home.hint, 'tab 1 of 2');
      h.dispose();
    });
  });

  group('commands', () {
    test('enabled and checked follow the registry, and a press runs it', () {
      final _Harness h = _Harness()..frame();
      expect(h.control('Cut')!.enabled, isFalse, reason: 'nothing selected');
      expect(h.control('Bold')!.checked, isFalse);

      h
        ..canCut = true
        ..bold = true
        ..rebuild()
        ..frame();
      expect(h.control('Cut')!.enabled, isTrue);
      expect(h.control('Bold')!.checked, isTrue);
      expect(h.control('Bold')!.describeSemantics().role,
          SemanticsRole.toggleButton);

      h
        ..click(h.control('Cut')!)
        ..frame();
      expect(h.cuts, 1);

      h
        ..click(h.control('Bold')!)
        ..rebuild()
        ..frame();
      expect(h.bold, isFalse);
      expect(h.control('Bold')!.checked, isFalse);
      h.dispose();
    });

    test('a disabled command does not run when clicked', () {
      final _Harness h = _Harness()..frame();
      h
        ..click(h.control('Cut')!)
        ..frame();
      expect(h.cuts, 0);
      h.dispose();
    });

    test('a button takes its label from the command', () {
      final _Harness h = _Harness()..frame();
      // `Copy` is declared with a command and no label.
      expect(h.control('Copy'), isNotNull);
      expect(h.texts, contains('Copy'));
      h.dispose();
    });
  });

  group('layout', () {
    test('small buttons stack in columns of three', () {
      final _Harness h = _Harness()..frame();
      final List<Rect> rects = <Rect>[
        for (final String label in <String>['A1', 'A2', 'A3', 'A4', 'A5'])
          h.rectOf(h.control(label)!),
      ];
      expect(rects[1].left, rects[0].left);
      expect(rects[2].left, rects[0].left);
      expect(rects[1].top, greaterThan(rects[0].top));
      expect(rects[2].top, greaterThan(rects[1].top));
      expect(rects[3].left, greaterThan(rects[0].right - 1),
          reason: 'the fourth starts a new column');
      expect(rects[3].top, rects[0].top);
      expect(rects[4].top, rects[1].top);

      final RibbonGroup stack = _Harness.stackGroup;
      expect(
        stack.columnsAt(RibbonGroupSize.large).map((c) => c.length),
        <int>[3, 2],
      );
      h.dispose();
    });

    test('a large button fills a column and breaks a run of small ones', () {
      final List<List<RibbonItem>> columns =
          _Harness.clipboard(CommandRegistry())
              .columnsAt(RibbonGroupSize.large);
      expect(columns.map((c) => c.length), <int>[1, 3]);
      final List<List<RibbonItem>> medium =
          _Harness.clipboard(CommandRegistry())
              .columnsAt(RibbonGroupSize.medium);
      expect(medium.map((c) => c.length), <int>[3, 1],
          reason: 'at medium the large button stacks with the small ones');
    });

    test('groups shrink from the right, a step at a time, to dropdowns', () {
      final _Harness probe = _Harness();
      final List<RibbonGroup> groups = _Harness.homeGroups(probe.registry);
      probe.dispose();
      const ThemeData theme = ThemeData.neutralLight;
      final RibbonMetrics metrics = RibbonMetrics(theme);
      double full(List<RibbonGroupSize> sizes) {
        double width = 0;
        for (var i = 0; i < groups.length; i++) {
          width += groups[i].widthAt(metrics, sizes[i]);
        }
        return width + (groups.length - 1) * RibbonMetrics.separatorWidth;
      }

      final List<RibbonGroupSize> large =
          List<RibbonGroupSize>.filled(groups.length, RibbonGroupSize.large);
      final double wide = full(large);
      expect(Ribbon.groupSizesFor(groups, theme, wide), large);

      // One pixel less: the rightmost group that can get narrower does.
      final List<RibbonGroupSize> tighter =
          Ribbon.groupSizesFor(groups, theme, wide - 1);
      expect(tighter.last, RibbonGroupSize.medium);
      expect(tighter.first, RibbonGroupSize.large);

      // Narrowing never widens anything, and each result fits.
      List<RibbonGroupSize> previous = large;
      final List<List<RibbonGroupSize>> seen = <List<RibbonGroupSize>>[];
      for (double width = wide; width > 40; width -= 7) {
        final List<RibbonGroupSize> sizes =
            Ribbon.groupSizesFor(groups, theme, width);
        for (var i = 0; i < groups.length; i++) {
          expect(sizes[i].index, greaterThanOrEqualTo(previous[i].index),
              reason: 'group $i at $width');
        }
        if (sizes.any((s) => s != RibbonGroupSize.collapsed)) {
          final bool allFloor = sizes.every((s) => s.index >= 2);
          if (!allFloor) expect(full(sizes), lessThanOrEqualTo(width));
        }
        if (seen.isEmpty || !_same(seen.last, sizes)) seen.add(sizes);
        previous = sizes;
      }
      // Large, then medium, then icons only, then dropdowns - each reached.
      expect(seen.any((s) => s.contains(RibbonGroupSize.medium)), isTrue);
      expect(seen.any((s) => s.contains(RibbonGroupSize.small)), isTrue);
      // At the narrowest every group is a dropdown, unless its dropdown
      // would be wider than its icons are.
      for (var i = 0; i < groups.length; i++) {
        expect(
          seen.last[i] == RibbonGroupSize.collapsed ||
              groups[i].widthAt(metrics, RibbonGroupSize.collapsed) >=
                  groups[i].widthAt(metrics, seen.last[i]),
          isTrue,
          reason: 'group $i',
        );
      }
      expect(seen.last, contains(RibbonGroupSize.collapsed));
      // Deterministic: the same width gives the same answer.
      expect(Ribbon.groupSizesFor(groups, theme, 333),
          Ribbon.groupSizesFor(groups, theme, 333));
      // Right to left: when the first group collapses, every group to its
      // right is a dropdown too, or one that a dropdown would not make
      // narrower.
      final List<RibbonGroupSize> firstCollapse =
          seen.firstWhere((s) => s.contains(RibbonGroupSize.collapsed));
      final int first = firstCollapse.indexOf(RibbonGroupSize.collapsed);
      expect(first, greaterThan(0), reason: 'not the leftmost first');
      for (var i = first + 1; i < groups.length; i++) {
        expect(
          firstCollapse[i] == RibbonGroupSize.collapsed ||
              groups[i].widthAt(metrics, RibbonGroupSize.collapsed) >=
                  groups[i].widthAt(metrics, firstCollapse[i]),
          isTrue,
        );
      }
    });

    test('the panel draws each group at the size its width allows', () {
      // Wide: labels everywhere, the large button large.
      final _Harness wide = _Harness()..frame();
      expect(wide.texts, contains('Paste'));
      expect(wide.texts, contains('Find'));
      expect(wide.rectOf(wide.control('Paste')!).height,
          greaterThan(wide.rectOf(wide.control('Replace')!).height * 2),
          reason: 'large');

      // The harness's own commands: labels come from the registry, and the
      // widths with them.
      final List<RibbonGroup> groups = _Harness.homeGroups(wide.registry);
      const ThemeData theme = ThemeData.neutralLight;
      double widthFor(RibbonGroupSize target) {
        for (double w = 1200; w > 10; w -= 1) {
          // The panel's inside: the ribbon's margin and the panel's
          // padding, 8 px a side.
          if (Ribbon.groupSizesFor(groups, theme, w - 16)[2] == target) {
            return w;
          }
        }
        fail('no width reaches $target');
      }

      // Medium: the two large Paragraph buttons become small ones with
      // their labels on one line.
      final _Harness medium = _Harness(width: widthFor(RibbonGroupSize.medium))
        ..frame();
      expect(medium.texts, contains('Bulleted List'));
      expect(medium.rectOf(medium.control('Bulleted List')!).height,
          medium.rectOf(medium.control('Replace')!).height);
      medium.dispose();

      // Icons only: the buttons keep their names for tooltips and assistive
      // technology, and lose the drawn labels.
      final _Harness icons = _Harness(width: widthFor(RibbonGroupSize.small))
        ..frame();
      expect(icons.control('Bulleted List'), isNotNull);
      expect(icons.texts, isNot(contains('Bulleted List')));
      expect(icons.texts, isNot(contains('Bulleted')));
      icons.dispose();

      // A dropdown: the group is one button, and the button opens it.
      final _Harness collapsed =
          _Harness(width: widthFor(RibbonGroupSize.collapsed))..frame();
      expect(collapsed.control('Bulleted List'), isNull);
      final RenderRibbonControl paragraph = collapsed.control('Paragraph')!;
      expect(paragraph.expanded, isFalse);
      collapsed
        ..click(paragraph)
        ..frame();
      expect(collapsed.control('Bulleted List'), isNotNull,
          reason: 'in the popup');
      expect(collapsed.texts, contains('Bulleted'), reason: 'at full size');
      expect(collapsed.control('Paragraph')!.expanded, isTrue);
      collapsed
        ..click(collapsed.control('Bulleted List')!)
        ..frame();
      expect(collapsed.bullets, 1);
      expect(collapsed.control('Bulleted List'), isNull,
          reason: 'running a command puts the popup away');
      collapsed.dispose();
      wide.dispose();
    });
  });

  group('collapsing', () {
    test('Ctrl+F1 collapses to the strip and pins it back', () {
      final _Harness h = _Harness()..frame();
      expect(h.control('Paste'), isNotNull);
      expect(
          h.owner.dispatchKeyEvent(_down(logicalKeyF1,
              modifiers: <KeyModifier>{KeyModifier.control})),
          isTrue);
      h.frame();
      expect(h.collapses, <bool>[true]);
      expect(h.control('Paste'), isNull);
      expect(h.control('Home'), isNotNull, reason: 'the strip stays');

      h.owner.dispatchKeyEvent(
          _down(logicalKeyF1, modifiers: <KeyModifier>{KeyModifier.control}));
      h.frame();
      expect(h.collapses, <bool>[true, false]);
      expect(h.control('Paste'), isNotNull);

      expect(h.owner.dispatchKeyEvent(_down(logicalKeyF1)), isFalse,
          reason: 'F1 alone is Help, not the ribbon');
      h.dispose();
    });

    test('a double click on a tab collapses and pins', () {
      final _Harness h = _Harness()..frame();
      h
        ..click(h.control('Home')!)
        ..click(h.control('Home')!, clickCount: 2)
        ..frame();
      expect(h.collapses, <bool>[true]);
      expect(h.control('Paste'), isNull);
      expect(h.control('Cut'), isNull, reason: 'no popup from the 2nd click');

      h
        ..click(h.control('Home')!)
        ..click(h.control('Home')!, clickCount: 2)
        ..frame();
      expect(h.collapses, <bool>[true, false]);
      expect(h.control('Paste'), isNotNull);
      h.dispose();
    });

    test('collapsed, a tab shows its panel floating; Escape closes it', () {
      final _Harness h = _Harness(collapsed: true)..frame();
      expect(h.control('Cut'), isNull);
      final double stripBottom = h.rectOf(h.control('Home')!).bottom;

      h
        ..click(h.control('Home')!)
        ..frame();
      expect(h.control('Cut'), isNotNull, reason: 'the floating panel');
      expect(
          h.rectOf(h.control('Cut')!).top, greaterThanOrEqualTo(stripBottom));
      expect(h.control('Home')!.selected, isTrue);

      // Another tab switches the floating panel instead of closing it.
      h
        ..click(h.control('Insert')!)
        ..frame();
      expect(h.control('Table'), isNotNull);
      expect(h.control('Cut'), isNull);

      expect(h.owner.dispatchKeyEvent(_down(logicalKeyEscape)), isTrue);
      h.frame();
      expect(h.control('Table'), isNull);
      expect(h.collapses, isEmpty, reason: 'still collapsed');
      h.dispose();
    });

    test('a click outside or a command closes the floating panel', () {
      final _Harness h = _Harness(collapsed: true)..frame();
      h
        ..click(h.control('Home')!)
        ..frame();
      expect(h.control('Find'), isNotNull);
      h
        ..clickAt(const Offset(600, 380))
        ..frame();
      expect(h.control('Find'), isNull);

      h
        ..click(h.control('Home')!)
        ..frame()
        ..click(h.control('Find')!)
        ..frame();
      expect(h.finds, 1);
      expect(h.control('Find'), isNull);

      // The same tab again closes it.
      h
        ..click(h.control('Home')!)
        ..frame()
        ..click(h.control('Home')!)
        ..frame();
      expect(h.control('Find'), isNull);
      h.dispose();
    });

    test('the controller drives both states', () {
      final RibbonController controller = RibbonController();
      final _Harness h = _Harness(controller: controller)..frame();
      controller.selectedIndex = 1;
      h.frame();
      expect(h.control('Table'), isNotNull);
      controller.collapsed = true;
      h.frame();
      expect(h.control('Table'), isNull);
      h
        ..click(h.control('Home')!)
        ..frame();
      expect(controller.selectedIndex, 0);
      expect(h.control('Cut'), isNotNull);
      h.dispose();
    });
  });

  group('keyboard', () {
    test('arrows move between tabs, Tab and Down go into the panel', () {
      final _Harness h = _Harness()..frame();
      final FocusManager focus = h.owner.focusManager;
      expect(focus.traversalRing().first.debugLabel, 'Ribbon tabs',
          reason: 'the strip is the first stop, and one stop');
      focus.moveFocus(TraversalDirection.next);
      h.frame();
      expect(focus.primaryFocus!.debugLabel, 'Ribbon tabs');
      expect(h.control('Home')!.hasFocus, isTrue);

      h.owner.dispatchKeyEvent(_down(logicalKeyArrowRight));
      h.frame();
      expect(h.changes, <int>[1]);
      expect(h.control('Insert')!.hasFocus, isTrue,
          reason: 'focus follows the selected tab');
      h.owner.dispatchKeyEvent(_down(logicalKeyArrowLeft));
      h.frame();
      expect(h.changes, <int>[1, 0]);

      h.owner.dispatchKeyEvent(_down(logicalKeyTab));
      h.frame();
      expect(focus.primaryFocus!.debugLabel, 'Ribbon Paste',
          reason: 'the first control of the panel');
      expect(focus.primaryFocus!.isFocusVisible, isTrue);

      focus.moveFocus(TraversalDirection.previous);
      h.owner.dispatchKeyEvent(_down(logicalKeyArrowDown));
      h.frame();
      expect(focus.primaryFocus!.debugLabel, 'Ribbon Paste');
      h.dispose();
    });

    test('a click on a button leaves the keyboard where it was', () {
      final _Harness h = _Harness()..frame();
      h
        ..canCut = true
        ..rebuild()
        ..frame()
        ..click(h.control('Cut')!)
        ..frame();
      expect(h.cuts, 1);
      expect(h.owner.focusManager.primaryFocus, isNull);
      h.dispose();
    });
  });

  test('light and dark themes paint the panel in their own surface', () {
    for (final ThemeData theme in <ThemeData>[
      ThemeData.neutralLight,
      ThemeData.neutralDark,
    ]) {
      final _Harness h = _Harness(theme: theme)..frame();
      final List<Color?> fills = <Color?>[];
      void walk(RenderBox node) {
        if (node is RenderDecoratedBox) fills.add(node.decoration.color);
        node.visitChildren(walk);
      }

      walk(h.owner.renderRoot!);
      expect(fills, contains(theme.surfaceBase));
      expect(fills, contains(theme.surfaceAlternate));
      h.dispose();
    }
  });
}

bool _same(List<RibbonGroupSize> a, List<RibbonGroupSize> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

final class _Harness {
  _Harness({
    this.width = 1180,
    bool collapsed = false,
    this.controller,
    this.theme = ThemeData.neutralLight,
  }) : _collapsed = collapsed {
    registry = CommandRegistry()
      ..registerAll(<CommandSpec>[
        CommandSpec(id: 'edit.paste', label: 'Paste', run: (_) => null),
        CommandSpec(
          id: 'edit.cut',
          label: 'Cut',
          shortcut: const KeyGesture(0x58, command: true),
          when: (_) => canCut ? null : 'nothing is selected',
          run: (_) => cuts++,
        ),
        CommandSpec(id: 'edit.copy', label: 'Copy', run: (_) => null),
        CommandSpec(
          id: 'format.bold',
          label: 'Bold',
          checked: (_) => bold,
          run: (_) => bold = !bold,
        ),
        CommandSpec(id: 'edit.find', label: 'Find', run: (_) => finds++),
      ]);
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(1200, 400)),
      ),
    );
    owner.updateRoot(_root());
  }

  final double width;
  final RibbonController? controller;
  final ThemeData theme;
  bool _collapsed;
  late final CommandRegistry registry;
  late final BuildOwner owner;
  bool canCut = false;
  bool bold = false;
  int cuts = 0;
  int finds = 0;
  int bullets = 0;
  int selected = 0;
  bool _stale = false;
  final List<int> changes = <int>[];
  final List<bool> collapses = <bool>[];

  static RibbonGroup clipboard(CommandRegistry registry) => RibbonGroup(
        label: 'Clipboard',
        items: <RibbonItem>[
          RibbonButton.large(
              icon: FluentIcons.clipboardPaste,
              registry: registry,
              command: 'edit.paste'),
          RibbonButton(
              icon: FluentIcons.cut, registry: registry, command: 'edit.cut'),
          RibbonButton(
              icon: FluentIcons.copy, registry: registry, command: 'edit.copy'),
          RibbonToggleButton(
              icon: FluentIcons.textBold,
              registry: registry,
              command: 'format.bold'),
        ],
      );

  static final RibbonGroup stackGroup = RibbonGroup(
    label: 'Stack',
    items: <RibbonItem>[
      for (final String label in <String>['A1', 'A2', 'A3', 'A4', 'A5'])
        RibbonButton(icon: FluentIcons.add, label: label, onPressed: () {}),
    ],
  );

  static List<RibbonGroup> homeGroups(CommandRegistry registry,
          [void Function()? onBullets]) =>
      <RibbonGroup>[
        clipboard(registry),
        stackGroup,
        RibbonGroup(
          label: 'Paragraph',
          onDialogLauncher: () {},
          items: <RibbonItem>[
            RibbonButton.large(
                icon: FluentIcons.textBulletList,
                label: 'Bulleted List',
                onPressed: onBullets),
            RibbonButton.large(
                icon: FluentIcons.textNumberListLtr,
                label: 'Numbered List',
                onPressed: () {}),
          ],
        ),
        RibbonGroup(
          label: 'Editing',
          items: <RibbonItem>[
            RibbonButton.large(
                icon: FluentIcons.search,
                registry: registry,
                command: 'edit.find'),
            RibbonButton(
                icon: FluentIcons.arrowSwap,
                label: 'Replace',
                onPressed: () {}),
          ],
        ),
      ];

  Widget _root() => Directionality(
        textDirection: TextDirection.leftToRight,
        child: Theme(
          data: theme,
          child: PopupScope(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: Ribbon(
                  controller: controller,
                  selectedIndex: controller == null ? selected : null,
                  collapsed: controller == null ? _collapsed : null,
                  onTabChanged: (int index) {
                    changes.add(index);
                    selected = index;
                    _stale = true;
                  },
                  onCollapsedChanged: (bool value) {
                    collapses.add(value);
                    _collapsed = value;
                    _stale = true;
                  },
                  tabs: <RibbonTab>[
                    RibbonTab(
                        label: 'Home',
                        groups: homeGroups(registry, () => bullets++)),
                    RibbonTab(label: 'Insert', groups: <RibbonGroup>[
                      RibbonGroup(label: 'Tables', items: <RibbonItem>[
                        RibbonButton.large(
                            icon: FluentIcons.table,
                            label: 'Table',
                            onPressed: () {}),
                      ]),
                    ]),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  /// What an application does after its state changed.
  void rebuild() => _stale = true;

  void frame() {
    for (var pass = 0; pass < 8; pass++) {
      if (_stale) {
        _stale = false;
        owner.updateRoot(_root());
      }
      owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds && !_stale) return;
    }
  }

  RenderRibbonControl? control(String label) {
    RenderRibbonControl? found;
    void walk(RenderBox node) {
      if (found != null) return;
      if (node is RenderRibbonControl && node.semanticsLabel == label) {
        found = node;
        return;
      }
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found;
  }

  List<String> get texts {
    final List<String> found = <String>[];
    void walk(RenderBox node) {
      if (node is RenderText) found.add(node.text);
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found;
  }

  Rect rectOf(RenderBox box) {
    final Offset origin = box.localToGlobal(Offset.zero);
    return Rect.fromLTWH(origin.dx, origin.dy, box.size.width, box.size.height);
  }

  void click(RenderBox box, {int clickCount = 1}) =>
      clickAt(rectOf(box).center, clickCount: clickCount);

  void clickAt(Offset at, {int clickCount = 1}) {
    owner
      ..dispatchPointerEvent(PointerDownEvent(
        windowId: _window,
        generation: 1,
        timestamp: Duration.zero,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: at,
        button: PointerButton.primary,
        clickCount: clickCount,
      ))
      ..dispatchPointerEvent(PointerUpEvent(
        windowId: _window,
        generation: 1,
        timestamp: Duration.zero,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: at,
        button: PointerButton.primary,
      ));
  }

  void dispose() => owner.dispose();
}
