/// The generic context menu: opening, dismissal, keyboard, placement,
/// semantics.
///
/// Every assertion here is about a *consequence* rather than about a flag. "The
/// menu is open" is asserted as items existing in the render tree; "the click
/// outside did not reach what was underneath" is asserted as the button behind
/// it not having fired; "the menu was repositioned" is asserted as the rect the
/// positioner produced. A test that only read `controller.isOpen` would pass
/// against a menu that never painted.
///
/// The font is pinned for the reason every widget test in this directory pins
/// it: item widths come from a shaped label, so an unpinned face would make
/// every placement coordinate machine-dependent.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

const int _keyD = 0x44;
const int _keyR = 0x52;

void main() {
  setUpAll(() {
    expect(
      FontRegistry.instance.useFontFile('test/fonts/Roboto-Regular.ttf'),
      isTrue,
    );
  });
  tearDownAll(FontRegistry.instance.reset);

  group('opening and dismissal', () {
    test('a secondary press inside a region opens the menu at the pointer', () {
      final _Harness harness = _Harness()..frame();
      expect(harness.surface, isNull, reason: 'nothing is showing yet');

      harness
        ..rightClick(const Offset(40, 30))
        ..frame();

      expect(harness.surface, isNotNull);
      expect(harness.labels, <String>['Refresh', 'Duplicate', 'Delete']);
      // Top-left corner at the pointer: nothing had to be adjusted this far
      // from any edge.
      final PopupPlacement placement = harness.controller.placement!;
      expect(placement.rect.left, 40);
      expect(placement.rect.top, 30);
      expect(placement.isUnadjusted, isTrue);
      harness.dispose();
    });

    test('a primary press opens nothing', () {
      final _Harness harness = _Harness()
        ..frame()
        ..primaryDown(const Offset(40, 30))
        ..frame();

      expect(harness.surface, isNull);
      expect(harness.controller.isOpen, isFalse);
      harness.dispose();
    });

    test('Escape closes it', () {
      final _Harness harness = _Harness()
        ..frame()
        ..rightClick(const Offset(40, 30))
        ..frame();
      expect(harness.surface, isNotNull);

      harness
        ..pressKey(logicalKeyEscape)
        ..frame();

      expect(harness.surface, isNull);
      expect(harness.controller.isOpen, isFalse);
      harness.dispose();
    });

    test('a click outside closes it and does not reach what is behind', () {
      final _Harness harness = _Harness()
        ..frame()
        ..rightClick(const Offset(140, 120))
        ..frame();
      expect(harness.surface, isNotNull);

      // Straight at the button, which is at the top-left of the content and a
      // long way from the menu.
      harness
        ..primaryDown(const Offset(20, 10))
        ..primaryUp(const Offset(20, 10))
        ..frame();

      expect(harness.surface, isNull, reason: 'the press dismissed the menu');
      expect(
        harness.buttonPresses,
        0,
        reason: 'the dismissing press must not also press the button under it; '
            'that is the whole point of the menu holding a grab',
      );
      harness.dispose();
    });

    test('a press inside the menu does not dismiss it', () {
      final _Harness harness = _Harness()
        ..frame()
        ..rightClick(const Offset(40, 30))
        ..frame();
      final Rect menu = harness.controller.placement!.rect;

      harness
        ..primaryDown(Offset(menu.left + 4, menu.top + 2))
        ..frame();

      expect(harness.surface, isNotNull);
      harness.dispose();
    });

    test('losing focus closes it', () {
      final _Harness harness = _Harness()
        ..frame()
        ..rightClick(const Offset(40, 30))
        ..frame();
      expect(harness.surface, isNotNull);

      // Something else in the window takes the keyboard - a Tab, a click into
      // another control, an application focusing a field.
      harness.button.focusNode!.requestFocus();
      harness.frame();

      expect(harness.surface, isNull);
      harness.dispose();
    });

    test('the menu takes focus and gives it back to the opener', () {
      final _Harness harness = _Harness()..frame();
      harness.button.focusNode!.requestFocus();
      final FocusNode opener = harness.owner.focusManager.primaryFocus!;

      harness
        ..rightClick(const Offset(40, 30))
        ..frame();
      expect(
        harness.owner.focusManager.primaryFocus,
        isNot(same(opener)),
        reason: 'the menu holds the keyboard while it is up',
      );
      expect(harness.owner.focusedTarget, same(harness.surface));

      harness
        ..pressKey(logicalKeyEscape)
        ..frame();

      expect(harness.owner.focusManager.primaryFocus, same(opener));
      harness.dispose();
    });

    test('opening a second menu closes the first, once', () {
      final _Harness harness = _Harness()..frame();
      int closings = 0;
      harness.controller.open(
        globalPosition: const Offset(10, 10),
        itemsBuilder: () => const <MenuItem>[MenuItem(label: 'One')],
        onClosed: () => closings++,
      );
      harness.frame();

      harness.controller.open(
        globalPosition: const Offset(20, 20),
        itemsBuilder: () => const <MenuItem>[MenuItem(label: 'Two')],
      );
      harness.frame();

      expect(closings, 1);
      expect(harness.labels, <String>['Two']);
      harness.dispose();
    });

    test('an overlay outside an inner dark theme uses the opener theme', () {
      final _Harness harness = _Harness(innerTheme: ThemeData.materialDark)
        ..frame()
        ..rightClick(const Offset(40, 30))
        ..frame();

      expect(harness.controller.theme, ThemeData.materialDark);
      expect(harness.surface!.theme, ThemeData.materialDark);
      expect(
        harness.itemRenders.first.theme.colorScheme.brightness,
        Brightness.dark,
      );
      harness.dispose();
    });
  });

  group('placement against the work area', () {
    test('a menu near the bottom edge flips above the pointer', () {
      final _Harness harness = _Harness()..frame();
      // Two rows from the bottom of a 200px-tall layer: the menu cannot fit
      // below, so it opens upward and its *bottom* lands on the pointer.
      harness
        ..rightClick(const Offset(40, 195))
        ..frame();

      final PopupPlacement placement = harness.controller.placement!;
      expect(placement.flippedY, isTrue);
      expect(placement.rect.bottom, 195);
      expect(placement.rect.top, greaterThanOrEqualTo(0));
      harness.dispose();
    });

    test('a menu near the right edge flips to the left of the pointer', () {
      final _Harness harness = _Harness()
        ..frame()
        ..rightClick(const Offset(298, 20))
        ..frame();

      final PopupPlacement placement = harness.controller.placement!;
      expect(placement.flippedX, isTrue);
      expect(placement.rect.right, 298);
      expect(placement.rect.left, greaterThanOrEqualTo(0));
      harness.dispose();
    });

    test('a corner press is pulled fully inside the work area', () {
      final _Harness harness = _Harness()
        ..frame()
        ..rightClick(const Offset(299, 199))
        ..frame();

      final Rect rect = harness.controller.placement!.rect;
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(300));
      expect(rect.bottom, lessThanOrEqualTo(200));
      harness.dispose();
    });

    test('the work area is the layer, not the screen', () {
      // The property the library comment turns on: an in-tree menu is placed
      // against the window it is drawn in, because pixels outside it do not
      // exist. Asserted as the presentation saying so.
      expect(
        const InTreeContextMenuPresentation().escapesOwnerWindow,
        isFalse,
      );
    });
  });

  group('keyboard navigation', () {
    test('Down walks every item, separators skipped, and wraps', () {
      final _Harness harness = _Harness()
        ..frame()
        ..rightClick(const Offset(40, 30))
        ..frame();
      final RenderContextMenuSurface surface = harness.surface!;
      expect(surface.highlightedIndex, -1, reason: 'nothing preselected');

      harness.pressKey(logicalKeyArrowDown);
      expect(harness.highlightedLabel, 'Refresh');
      harness.pressKey(logicalKeyArrowDown);
      expect(harness.highlightedLabel, 'Duplicate');
      // Index 2 is the separator; the next press must land on Delete.
      harness.pressKey(logicalKeyArrowDown);
      expect(harness.highlightedLabel, 'Delete');
      harness.pressKey(logicalKeyArrowDown);
      expect(harness.highlightedLabel, 'Refresh', reason: 'it wrapped');
      harness.dispose();
    });

    test('Up from nothing starts at the last item', () {
      final _Harness harness = _Harness()
        ..frame()
        ..rightClick(const Offset(40, 30))
        ..frame()
        ..pressKey(logicalKeyArrowUp);

      expect(harness.highlightedLabel, 'Delete');
      harness.dispose();
    });

    test('Home and End go to the first and last item', () {
      final _Harness harness = _Harness()
        ..frame()
        ..rightClick(const Offset(40, 30))
        ..frame()
        ..pressKey(logicalKeyEnd);
      expect(harness.highlightedLabel, 'Delete');

      harness.pressKey(logicalKeyHome);
      expect(harness.highlightedLabel, 'Refresh');
      harness.dispose();
    });

    test('arrows do land on a disabled item, and Enter refuses it', () {
      final _Harness harness = _Harness()
        ..frame()
        ..rightClick(const Offset(40, 30))
        ..frame()
        ..pressKey(logicalKeyEnd);

      expect(harness.highlightedLabel, 'Delete');
      expect(harness.highlightedItem!.item.enabled, isFalse);

      harness
        ..pressKey(logicalKeyEnter)
        ..frame();

      expect(harness.chosen, isEmpty, reason: 'a disabled item is inert');
      expect(
        harness.surface,
        isNotNull,
        reason: 'and a refused activation does not close the menu either',
      );
      harness.dispose();
    });

    test('with visitsDisabledItems false the arrows skip it', () {
      final _Harness harness = _Harness(visitsDisabledItems: false)
        ..frame()
        ..rightClick(const Offset(40, 30))
        ..frame()
        ..pressKey(logicalKeyArrowDown);
      expect(harness.highlightedLabel, 'Refresh');

      harness.pressKey(logicalKeyArrowDown);
      expect(harness.highlightedLabel, 'Duplicate');
      harness.pressKey(logicalKeyArrowDown);
      expect(
        harness.highlightedLabel,
        'Refresh',
        reason: 'Delete is disabled and the walk wrapped straight past it',
      );
      harness.dispose();
    });

    test('Enter activates the highlighted item and closes the menu', () {
      final _Harness harness = _Harness()
        ..frame()
        ..rightClick(const Offset(40, 30))
        ..frame()
        ..pressKey(logicalKeyArrowDown)
        ..pressKey(logicalKeyEnter)
        ..frame();

      expect(harness.chosen, <String>['Refresh']);
      expect(harness.surface, isNull);
      harness.dispose();
    });

    test('an initial letter jumps to that item', () {
      final _Harness harness = _Harness()
        ..frame()
        ..rightClick(const Offset(40, 30))
        ..frame()
        ..pressKey(_keyD);

      expect(harness.highlightedLabel, 'Duplicate');
      expect(
        harness.chosen,
        isEmpty,
        reason: 'type-ahead moves the cursor; it does not run the command, '
            'because a typo in a menu must not fire one',
      );

      harness
        ..pressKey(_keyR)
        ..frame();
      expect(harness.highlightedLabel, 'Refresh');
      harness.dispose();
    });

    test('an initial letter never lands on a disabled item', () {
      final _Harness harness = _Harness()
        ..frame()
        ..rightClick(const Offset(40, 30))
        ..frame()
        // D matches both Duplicate and Delete; Delete is disabled, so the
        // second press must stay on Duplicate rather than cycling onto it.
        ..pressKey(_keyD);
      expect(harness.highlightedLabel, 'Duplicate');

      harness.pressKey(_keyD);
      expect(harness.highlightedLabel, 'Duplicate');
      harness.dispose();
    });

    test('Left and Right are declined, so a submenu key stays free', () {
      final _Harness harness = _Harness()
        ..frame()
        ..rightClick(const Offset(40, 30))
        ..frame()
        ..pressKey(logicalKeyArrowDown);

      expect(harness.dispatchKey(logicalKeyArrowRight), isFalse);
      expect(harness.dispatchKey(logicalKeyArrowLeft), isFalse);
      expect(harness.highlightedLabel, 'Refresh', reason: 'nothing moved');
      harness.dispose();
    });
  });

  group('the pointer', () {
    test('hovering an item moves the keyboard cursor to it', () {
      final _Harness harness = _Harness()
        ..frame()
        ..rightClick(const Offset(40, 30))
        ..frame();
      final Rect menu = harness.controller.placement!.rect;

      // The second row: one item height down from the top border.
      harness.move(Offset(
        menu.left + 6,
        menu.top + RenderContextMenuItem.itemHeight + 2,
      ));

      expect(harness.highlightedLabel, 'Duplicate');
      harness.dispose();
    });

    test('clicking an item runs it and closes the menu', () {
      final _Harness harness = _Harness()
        ..frame()
        ..rightClick(const Offset(40, 30))
        ..frame();
      final Rect menu = harness.controller.placement!.rect;
      final Offset row = Offset(menu.left + 6, menu.top + 4);

      harness
        ..primaryDown(row)
        ..primaryUp(row)
        ..frame();

      expect(harness.chosen, <String>['Refresh']);
      expect(harness.surface, isNull);
      harness.dispose();
    });

    test('clicking a disabled item does nothing at all', () {
      final _Harness harness = _Harness()
        ..frame()
        ..rightClick(const Offset(40, 30))
        ..frame();
      final Rect menu = harness.controller.placement!.rect;
      // Third row down: item, item, separator, item.
      final Offset row = Offset(
        menu.left + 6,
        menu.top +
            RenderContextMenuItem.itemHeight * 2 +
            RenderContextMenuSeparator.separatorHeight +
            4,
      );

      harness
        ..primaryDown(row)
        ..primaryUp(row)
        ..frame();

      expect(harness.chosen, isEmpty);
      expect(harness.surface, isNotNull, reason: 'and the menu stays up');
      harness.dispose();
    });
  });

  group('semantics', () {
    test('the popup is a menu and every command is a menu item', () {
      final _Harness harness = _Harness()
        ..frame()
        ..rightClick(const Offset(40, 30))
        ..frame();

      final List<SemanticsNode> nodes = harness.owner.buildSemantics().nodes;
      final SemanticsNode menu = nodes.firstWhere(
        (SemanticsNode node) => node.role == SemanticsRole.menu,
      );
      expect(menu.value, '3 items');
      expect(menu.states, contains(SemanticsState.modal));
      expect(menu.actions, contains(SemanticsAction.dismiss));

      final List<SemanticsNode> items = menu.children
          .where((SemanticsNode node) => node.role == SemanticsRole.menuItem)
          .toList();
      expect(
        items.map((SemanticsNode node) => node.label),
        <String>['Refresh', 'Duplicate', 'Delete'],
      );
      expect(
        menu.children.length,
        3,
        reason: 'the separator contributes no node: it has nothing to announce',
      );
      harness.dispose();
    });

    test('a disabled item announces the reason it cannot be used', () {
      final _Harness harness = _Harness()
        ..frame()
        ..rightClick(const Offset(40, 30))
        ..frame();

      final SemanticsNode delete = harness.semanticsFor('Delete');
      expect(delete.states, contains(SemanticsState.disabled));
      expect(delete.hint, 'nothing here is selected');
      expect(
        delete.actions,
        isNot(contains(SemanticsAction.activate)),
        reason: 'it is readable, and it is not activatable',
      );
      expect(
        delete.actions,
        contains(SemanticsAction.focus),
        reason: 'but it can still be reached, which is how the hint is read',
      );
      harness.dispose();
    });

    test('an enabled item carries activate and no reason', () {
      final _Harness harness = _Harness()
        ..frame()
        ..rightClick(const Offset(40, 30))
        ..frame();

      final SemanticsNode refresh = harness.semanticsFor('Refresh');
      expect(refresh.states, isNot(contains(SemanticsState.disabled)));
      expect(refresh.actions, contains(SemanticsAction.activate));
      expect(refresh.hint, isNull);
      expect(refresh.value, 'F5', reason: 'the accelerator is announced');
      harness.dispose();
    });

    test('the keyboard cursor is reported as focus on the row it is on', () {
      final _Harness harness = _Harness()
        ..frame()
        ..rightClick(const Offset(40, 30))
        ..frame()
        ..pressKey(logicalKeyArrowDown)
        ..pressKey(logicalKeyArrowDown);

      expect(
        harness.semanticsFor('Duplicate').states,
        contains(SemanticsState.focused),
      );
      expect(
        harness.semanticsFor('Refresh').states,
        isNot(contains(SemanticsState.focused)),
      );
      harness.dispose();
    });

    test('nothing is left in the tree once the menu closes', () {
      final _Harness harness = _Harness()
        ..frame()
        ..rightClick(const Offset(40, 30))
        ..frame()
        ..pressKey(logicalKeyEscape)
        ..frame();

      final Set<SemanticsRole> roles = harness.owner
          .buildSemantics()
          .nodes
          .map((SemanticsNode node) => node.role)
          .toSet();
      expect(roles, isNot(contains(SemanticsRole.menu)));
      expect(roles, isNot(contains(SemanticsRole.menuItem)));
      harness.dispose();
    });
  });

  group('a scope that is not there', () {
    test('ContextMenuScope.of names the missing wrapper', () {
      final BuildOwner owner = BuildOwner(
        pipelineOwner: PipelineOwner(
          rootConstraints: BoxConstraints.tight(const Size(100, 100)),
        ),
      );
      Object? caught;
      owner.updateRoot(_Probe(onBuild: (BuildContext context) {
        try {
          ContextMenuScope.of(context);
        } on Object catch (error) {
          caught = error;
        }
      }));

      expect(caught, isA<StateError>());
      expect('$caught', contains('ContextMenuScope'));
      owner.dispose();
    });

    test('maybeOf answers null instead, for a caller that can do without', () {
      final BuildOwner owner = BuildOwner(
        pipelineOwner: PipelineOwner(
          rootConstraints: BoxConstraints.tight(const Size(100, 100)),
        ),
      );
      ContextMenuController? found = ContextMenuController();
      owner.updateRoot(_Probe(
        onBuild: (BuildContext context) =>
            found = ContextMenuScope.maybeOf(context),
      ));

      expect(found, isNull);
      owner.dispose();
    });
  });
}

/// A widget that runs a callback during build and draws nothing.
final class _Probe extends StatelessWidget {
  const _Probe({required this.onBuild});

  final void Function(BuildContext context) onBuild;

  @override
  Widget build(BuildContext context) {
    onBuild(context);
    return const SizedBox(width: 10, height: 10);
  }
}

/// A 300x200 window holding a button and a right-clickable region.
final class _Harness {
  _Harness({bool visitsDisabledItems = true, ThemeData? innerTheme})
      : _visitsDisabledItems = visitsDisabledItems,
        _innerTheme = innerTheme ?? ThemeData.neutralLight {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(300, 200)),
      ),
    );
    owner.updateRoot(_root());
  }

  final bool _visitsDisabledItems;
  final ThemeData _innerTheme;
  late final BuildOwner owner;
  final ContextMenuController controller = ContextMenuController();
  final List<String> chosen = <String>[];
  int buttonPresses = 0;

  Widget _root() => ContextMenuScope(
        controller: controller,
        child: Theme(
          data: _innerTheme,
          child: ContextMenuRegion(
            itemsBuilder: () => <MenuItem>[
              MenuItem(
                label: 'Refresh',
                shortcut: 'F5',
                onSelected: () => chosen.add('Refresh'),
              ),
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
                Button(label: 'Behind', onPressed: () => buttonPresses++),
              ],
            ),
          ),
        ),
      );

  void frame({int maxPasses = 8}) {
    for (int pass = 0; pass < maxPasses; pass++) {
      owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      // The surface is rebuilt every pass, so its navigation policy is applied
      // here rather than in the tree: `visitsDisabledItems` is a property of
      // the menu widget, and this harness drives the controller directly.
      surface?.visitsDisabledItems = _visitsDisabledItems;
      if (!owner.hasScheduledBuilds) return;
    }
    throw StateError('the tree never settled');
  }

  RenderContextMenuSurface? get surface => _find<RenderContextMenuSurface>();

  RenderButton get button => _find<RenderButton>()!;

  List<RenderContextMenuItem> get itemRenders {
    final RenderContextMenuSurface? menu = surface;
    if (menu == null) return const <RenderContextMenuItem>[];
    return <RenderContextMenuItem>[
      for (final RenderBox child in menu.children)
        if (child is RenderContextMenuItem) child,
    ];
  }

  List<String> get labels => <String>[
        for (final RenderContextMenuItem item in itemRenders) item.item.label,
      ];

  RenderContextMenuItem? get highlightedItem => surface?.highlightedItem;

  String? get highlightedLabel => highlightedItem?.item.label;

  SemanticsNode semanticsFor(String label) =>
      owner.buildSemantics().nodes.firstWhere((SemanticsNode node) =>
          node.role == SemanticsRole.menuItem && node.label == label);

  T? _find<T extends RenderBox>() {
    T? found;
    void walk(RenderBox node) {
      if (node is T) found ??= node;
      node.visitChildren(walk);
    }

    final RenderBox? root = owner.renderRoot;
    if (root != null) walk(root);
    return found;
  }

  /// A whole right click: press and release.
  ///
  /// Both halves, because the release is what ends the pointer capture the
  /// press took. A test that only pressed would have every later move and
  /// click routed to whatever the press captured rather than to what is under
  /// the pointer - which is correct behaviour, and would make the *test* lie.
  void rightClick(Offset position) {
    _down(position, PointerButton.secondary);
    _up(position, PointerButton.secondary);
  }

  void primaryDown(Offset position) => _down(position, PointerButton.primary);

  void _down(Offset position, PointerButton button) =>
      owner.dispatchPointerEvent(PointerDownEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: position,
        button: button,
      ));

  void primaryUp(Offset position) => _up(position, PointerButton.primary);

  void _up(Offset position, PointerButton button) =>
      owner.dispatchPointerEvent(PointerUpEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: position,
        button: button,
      ));

  void move(Offset position) => owner.dispatchPointerEvent(PointerMoveEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: position,
      ));

  /// Sends a key and runs the frame that follows it, as a real window does.
  void pressKey(int logicalKey, {bool shift = false}) {
    dispatchKey(logicalKey, shift: shift);
    frame();
  }

  /// Sends a key and reports whether the tree claimed it.
  bool dispatchKey(int logicalKey, {bool shift = false}) =>
      owner.dispatchKeyEvent(KeyDownEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        physicalKey: logicalKey,
        logicalKey: logicalKey,
        modifiers: shift
            ? const <KeyModifier>{KeyModifier.shift}
            : const <KeyModifier>{},
      ));

  void dispose() => owner.dispose();
}
