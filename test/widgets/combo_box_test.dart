/// The combo box: opening, keyboard, commit versus cancel, placement under a
/// resize, semantics and right-to-left.
///
/// Every assertion is about a consequence rather than about a flag. "The
/// drop-down is open" is asserted as list rows existing in the render tree and
/// a placement rect the positioner produced; "Escape restored" is asserted as
/// `onChanged` never having fired *and* the highlight being back on the
/// selected row. A test that read `overlay.isOpen` alone would pass against a
/// popup that never painted.
///
/// The font is pinned for the reason every widget test here pins it: the
/// field's width comes from a shaped label, so an unpinned face would make
/// every coordinate machine-dependent.
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

  group('the closed field', () {
    test('shows the selected item, and the placeholder when there is none', () {
      final _Harness harness = _Harness(value: 'br')..frame();
      expect(harness.field.label, 'Brazil');

      harness
        ..value = null
        ..rebuild();
      expect(harness.field.label, 'select one');
      harness.dispose();
    });

    test('a disabled combo box neither opens nor takes the keyboard', () {
      final _Harness harness = _Harness(value: 'br', enabled: false)..frame();

      harness
        ..click(harness.fieldRect.center)
        ..frame();

      expect(harness.isOpen, isFalse);
      expect(harness.dispatchKey(logicalKeyF4), isFalse);
      expect(harness.changes, isEmpty);
      harness.dispose();
    });

    test('a ComboBox with no scope above it names the missing scope', () {
      final BuildOwner owner = BuildOwner(
        pipelineOwner: PipelineOwner(
          rootConstraints: BoxConstraints.tight(const Size(200, 80)),
        ),
      );

      expect(
        () => owner.updateRoot(
          const Directionality(
            textDirection: TextDirection.leftToRight,
            child:
                ComboBox<String>(items: <ComboBoxItem<String>>[], value: null),
          ),
        ),
        throwsA(isA<MissingComboBoxScopeError>()),
      );
      owner.dispose();
    });
  });

  group('opening and dismissal', () {
    test('a click opens the drop-down under the field', () {
      final _Harness harness = _Harness(value: 'br')..frame();
      expect(harness.isOpen, isFalse);

      harness
        ..click(harness.fieldRect.center)
        ..frame();

      expect(harness.isOpen, isTrue);
      expect(harness.itemLabels,
          <String>['Argentina', 'Brazil', 'Chile', 'Denmark', 'Egypt']);
      final PopupPlacement placement = harness.placement!;
      expect(placement.rect.top, harness.fieldRect.bottom,
          reason: 'the drop-down hangs from the bottom of the field');
      expect(placement.rect.left, harness.fieldRect.left);
      expect(placement.isUnadjusted, isTrue);
      harness.dispose();
    });

    test('F4, Alt+Down and Space open it; F4 and Escape close it', () {
      final _Harness harness = _Harness(value: 'br')
        ..frame()
        ..focusField();

      for (final void Function() open in <void Function()>[
        () => harness.pressKey(logicalKeyF4),
        () => harness.pressKey(logicalKeyArrowDown,
            modifiers: const <KeyModifier>{KeyModifier.alt}),
        () => harness.pressKey(logicalKeySpace),
      ]) {
        open();
        expect(harness.isOpen, isTrue);
        harness.pressKey(logicalKeyEscape);
        expect(harness.isOpen, isFalse);
      }

      harness.pressKey(logicalKeyF4);
      expect(harness.isOpen, isTrue);
      harness.pressKey(logicalKeyF4);
      expect(harness.isOpen, isFalse);
      expect(harness.changes, isEmpty, reason: 'opening is not choosing');
      harness.dispose();
    });

    test('a click outside closes it and does not reach what is behind', () {
      final _Harness harness = _Harness(value: 'br')..frame();
      harness
        ..click(harness.fieldRect.center)
        ..frame();
      expect(harness.isOpen, isTrue);

      harness
        ..click(harness.buttonRect.center)
        ..frame();

      expect(harness.isOpen, isFalse);
      expect(harness.buttonPresses, 0,
          reason: 'the dismissing click is consumed by the overlay');
      expect(harness.changes, isEmpty);
      harness.dispose();
    });

    test('focus leaving closes the drop-down without committing', () {
      final _Harness harness = _Harness(value: 'br')
        ..frame()
        ..focusField()
        ..pressKey(logicalKeyF4);
      expect(harness.isOpen, isTrue);

      harness
        ..pressKey(logicalKeyArrowDown)
        ..dispatchKey(logicalKeyTab)
        ..frame();

      expect(harness.isOpen, isFalse);
      expect(harness.changes, isEmpty);
      harness.dispose();
    });
  });

  group('highlight is not selection', () {
    test('arrows move the highlight and Enter commits it, exactly once', () {
      final _Harness harness = _Harness(value: 'br')
        ..frame()
        ..focusField()
        ..pressKey(logicalKeyF4);

      expect(harness.highlightedIndex, 1, reason: 'opens on the current value');
      harness.pressKey(logicalKeyArrowDown);
      expect(harness.highlightedIndex, 2);
      expect(harness.changes, isEmpty,
          reason: 'a highlight is not a choice; onChanged must stay silent');

      harness.pressKey(logicalKeyEnter);

      expect(harness.changes, <String>['cl']);
      expect(harness.isOpen, isFalse);
      expect(harness.field.label, 'Chile');
      harness.dispose();
    });

    test('Escape restores the value and the highlight, and commits nothing',
        () {
      final _Harness harness = _Harness(value: 'br')
        ..frame()
        ..focusField()
        ..pressKey(logicalKeyF4)
        ..pressKey(logicalKeyArrowDown)
        ..pressKey(logicalKeyArrowDown);
      expect(harness.highlightedIndex, 3);

      harness.pressKey(logicalKeyEscape);

      expect(harness.changes, isEmpty);
      expect(harness.value, 'br');
      expect(harness.field.label, 'Brazil');
      expect(harness.isOpen, isFalse);

      // Reopening starts from the value again rather than from the row Escape
      // was pressed on: a cancelled highlight that survived would be committed
      // by the next Enter.
      harness.pressKey(logicalKeyF4);
      expect(harness.highlightedIndex, 1);
      harness.dispose();
    });

    test('a click outside also restores the highlight', () {
      final _Harness harness = _Harness(value: 'br')
        ..frame()
        ..focusField()
        ..pressKey(logicalKeyF4)
        ..pressKey(logicalKeyArrowDown);
      harness
        ..click(_Harness.emptySpace)
        ..frame()
        ..pressKey(logicalKeyF4);

      expect(harness.highlightedIndex, 1);
      expect(harness.changes, isEmpty);
      harness.dispose();
    });

    test('clicking a row commits it, closes, and gives focus back', () {
      final _Harness harness = _Harness(value: 'br')..frame();
      harness
        ..click(harness.fieldRect.center)
        ..frame()
        ..click(harness.rowRect(3).center)
        ..frame();

      expect(harness.changes, <String>['dk']);
      expect(harness.isOpen, isFalse);
      expect(harness.field.hasFocus, isTrue,
          reason:
              'focus must not be left inside a popup that no longer exists');
      harness.dispose();
    });

    test('a closed combo box steps through its list with the arrows', () {
      final _Harness harness = _Harness(value: 'br')
        ..frame()
        ..focusField();

      harness.pressKey(logicalKeyArrowDown);
      expect(harness.changes, <String>['cl'],
          reason: 'a closed combo box is a spinner over its list');
      expect(harness.isOpen, isFalse);

      harness.pressKey(logicalKeyArrowUp);
      expect(harness.changes, <String>['cl', 'br']);
      harness.dispose();
    });

    test('Home and End reach the ends, and disabled rows are skipped', () {
      final _Harness harness = _Harness(value: 'br', disabled: <int>{2})
        ..frame()
        ..focusField()
        ..pressKey(logicalKeyF4);

      harness.pressKey(logicalKeyArrowDown);
      expect(harness.highlightedIndex, 3, reason: 'Chile is disabled');

      harness.pressKey(logicalKeyHome);
      expect(harness.highlightedIndex, 0);
      harness.pressKey(logicalKeyEnd);
      expect(harness.highlightedIndex, 4);

      harness.pressKey(logicalKeyEnter);
      expect(harness.changes, <String>['eg']);
      harness.dispose();
    });

    test('a click on a disabled row neither commits nor closes', () {
      final _Harness harness = _Harness(value: 'br', disabled: <int>{2})
        ..frame();
      harness
        ..click(harness.fieldRect.center)
        ..frame()
        ..click(harness.rowRect(2).center)
        ..frame();

      expect(harness.changes, isEmpty);
      expect(harness.isOpen, isTrue);
      harness.dispose();
    });

    test('typing a letter searches, and repeating it cycles the matches', () {
      final _Harness harness = _Harness(value: 'ar')
        ..frame()
        ..focusField()
        ..pressKey(logicalKeyF4);

      harness.type('d');
      expect(harness.highlightedIndex, 3);

      // Two items start with the same letter once the list is walked from the
      // top again: the search wraps rather than stopping at the end.
      harness.type('a');
      expect(harness.highlightedIndex, 0);
      expect(harness.changes, isEmpty, reason: 'searching is not choosing');

      harness.pressKey(logicalKeyEscape);
      harness.type('c');
      expect(harness.changes, <String>['cl'],
          reason: 'a closed combo box commits what the search found');
      harness.dispose();
    });

    test('keyboard navigation scrolls the drop-down to the highlight', () {
      final _Harness harness = _Harness.long()
        ..frame()
        ..focusField()
        ..pressKey(logicalKeyF4);
      expect(harness.scroll.pixels, 0);

      harness.pressKey(logicalKeyEnd);

      expect(harness.highlightedIndex, 19);
      expect(harness.scroll.pixels, greaterThan(0),
          reason: 'a highlight the user cannot see is not a highlight');
      // Stated as "the whole content minus one window" rather than as a
      // literal: the window is the pop-up's height, and that is now the rows
      // plus the pop-up's own vertical padding rather than the rows plus a
      // two-pixel border. A literal here would be a copy of that padding.
      expect(
        harness.scroll.pixels,
        harness.scroll.contentExtent - harness.scroll.viewportExtent,
        reason: 'exactly enough to bring the last of twenty rows into view, '
            'and no further: the list clamps at its own end',
      );
      expect(harness.scroll.contentExtent, 20 * 22,
          reason: 'twenty rows of the extent this harness asked for');
      harness.dispose();
    });
  });

  group('placement while the window changes', () {
    test('a resize re-places the popup instead of orphaning it', () {
      // Three visible rows, so that flipping the popup above the field is
      // actually an improvement: a drop-down taller than the space on either
      // side of its anchor overflows both ways, and the positioner rejects a
      // flip that only moves the clipping.
      final _Harness harness = _Harness(
        value: 'br',
        size: const Size(300, 400),
        maxVisibleItems: 3,
        topInset: 200,
      )..frame();
      harness
        ..click(harness.fieldRect.center)
        ..frame();

      final PopupPlacement before = harness.placement!;
      expect(before.flippedY, isFalse);
      expect(before.rect.top, harness.fieldRect.bottom);

      // The window shrinks until there is no room below the field. The popup
      // must move; a popup left where it was would be hanging off the bottom of
      // a window that no longer extends that far.
      harness
        ..resize(const Size(300, 300))
        ..frame();

      final PopupPlacement after = harness.placement!;
      expect(after.flippedY, isTrue);
      expect(after.rect.bottom, harness.fieldRect.top);
      expect(after.rect.top, greaterThanOrEqualTo(0.0));
      expect(after.rect.bottom, lessThanOrEqualTo(300.0),
          reason: 'the popup stays inside the work area it was re-placed in');
      expect(harness.isOpen, isTrue);

      // Growing the window again puts it back below the field: the placement is
      // recomputed from the current geometry every frame, not remembered.
      harness
        ..resize(const Size(300, 400))
        ..frame();
      expect(harness.placement!.flippedY, isFalse);
      expect(harness.placement!.rect.top, harness.fieldRect.bottom);
      harness.dispose();
    });

    test('a narrow window slides a wide drop-down back inside', () {
      final _Harness harness = _Harness(
        value: 'br',
        size: const Size(400, 400),
        inset: 150,
        popupWidth: 200,
      )..frame();
      harness
        ..click(harness.fieldRect.center)
        ..frame();
      expect(harness.placement!.slidX, isFalse, reason: 'it fits at 400 wide');

      harness
        ..resize(const Size(300, 400))
        ..frame();

      final PopupPlacement placement = harness.placement!;
      expect(placement.slidX, isTrue);
      expect(placement.rect.left, greaterThanOrEqualTo(0.0));
      expect(placement.rect.right, lessThanOrEqualTo(300.0));
      expect(placement.rect.width, 200, reason: 'sliding preserves the size');
      harness.dispose();
    });
  });

  group('semantics', () {
    test('the field is a button with a value, and expands', () {
      final _Harness harness = _Harness(value: 'br')..frame();

      SemanticsNode node() => harness.owner
          .buildSemantics()
          .nodes
          .firstWhere((SemanticsNode n) => n.value == 'Brazil');

      expect(node().role, SemanticsRole.button);
      expect(node().label, 'Country');
      expect(node().hint, 'item 2 of 5');
      expect(node().states, isNot(contains(SemanticsState.expanded)));
      expect(node().actions, contains(SemanticsAction.showMenu));

      harness
        ..click(harness.fieldRect.center)
        ..frame();

      expect(node().states, contains(SemanticsState.expanded));
      harness.dispose();
    });

    test('the drop-down publishes a list with every item counted', () {
      final _Harness harness = _Harness.long()..frame();
      harness
        ..click(harness.fieldRect.center)
        ..frame();

      final SemanticsNode list = harness.owner
          .buildSemantics()
          .nodes
          .firstWhere((SemanticsNode n) => n.role == SemanticsRole.list);

      expect(list.value, '20 items',
          reason: 'the full count, not the realized one');
      final List<SemanticsNode> selected = harness.owner
          .buildSemantics()
          .nodes
          .where((SemanticsNode n) =>
              n.role == SemanticsRole.listItem &&
              n.states.contains(SemanticsState.selected))
          .toList();
      expect(selected, hasLength(1),
          reason: 'exactly one row is the highlight');
      harness.dispose();
    });

    test('a disabled field says so and offers no actions', () {
      final _Harness harness = _Harness(value: 'br', enabled: false)..frame();

      final SemanticsNode node = harness.owner
          .buildSemantics()
          .nodes
          .firstWhere((SemanticsNode n) => n.value == 'Brazil');

      expect(node.states, contains(SemanticsState.disabled));
      expect(node.actions, isEmpty);
      harness.dispose();
    });
  });

  group('right to left', () {
    test('the drop-down hangs from the field start edge, which is the right',
        () {
      final _Harness rtl = _Harness(
        value: 'br',
        direction: TextDirection.rightToLeft,
        popupWidth: 200,
      )..frame();
      rtl
        ..click(rtl.fieldRect.center)
        ..frame();

      // The field is 120 wide and the popup 200: aligning them on the left
      // would be indistinguishable from aligning them on the right if the two
      // were the same width, which is why this popup is deliberately wider.
      expect(rtl.placement!.rect.right, rtl.fieldRect.right);
      expect(rtl.placement!.rect.left, lessThan(rtl.fieldRect.left));
      rtl.dispose();

      final _Harness ltr = _Harness(value: 'br', popupWidth: 200)..frame();
      ltr
        ..click(ltr.fieldRect.center)
        ..frame();

      expect(ltr.placement!.rect.left, ltr.fieldRect.left);
      expect(ltr.placement!.rect.right, greaterThan(ltr.fieldRect.right));
      ltr.dispose();
    });

    test('the keyboard means the same thing in both directions', () {
      final _Harness rtl = _Harness(
        value: 'br',
        direction: TextDirection.rightToLeft,
      )
        ..frame()
        ..focusField()
        ..pressKey(logicalKeyF4)
        ..pressKey(logicalKeyArrowDown);

      // Down is later in the list in every locale: a list runs down the screen
      // and mirroring it would be a different control, not a translated one.
      expect(rtl.highlightedIndex, 2);
      rtl
        ..pressKey(logicalKeyEnter)
        ..frame();
      expect(rtl.changes, <String>['cl']);
      rtl.dispose();
    });
  });
}

const List<String> _codes = <String>['ar', 'br', 'cl', 'dk', 'eg'];
const List<String> _names = <String>[
  'Argentina',
  'Brazil',
  'Chile',
  'Denmark',
  'Egypt',
];

final class _Harness {
  _Harness({
    this.value,
    this.enabled = true,
    this.direction = TextDirection.leftToRight,
    this.size = const Size(300, 200),
    this.popupWidth,
    this.disabled = const <int>{},
    this.itemCount = 5,
    this.maxVisibleItems = 8,
    this.inset = 0,
    this.topInset = 12,
  }) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(rootConstraints: BoxConstraints.tight(size)),
    );
    owner.updateRoot(_root());
  }

  /// Twenty rows in a four-row window: the shape that makes scrolling and the
  /// "3 of 20" announcement observable.
  factory _Harness.long() => _Harness(
        value: 'item 0',
        itemCount: 20,
        maxVisibleItems: 4,
        size: const Size(300, 400),
      );

  /// A point in the window that no drop-down ever covers: the popup hangs
  /// below a field that is near the top, and is 120 wide at most.
  static const Offset emptySpace = Offset(250, 190);

  String? value;
  final bool enabled;
  final TextDirection direction;
  Size size;
  final double? popupWidth;
  final Set<int> disabled;
  final int itemCount;
  final int maxVisibleItems;

  /// How far the field sits from the window's start edge. Zero puts it against
  /// the edge, where a popup can no longer slide anywhere.
  final double inset;

  /// How far down the window the field sits. A field near the top has no room
  /// above it, so a drop-down that does not fit below cannot flip either.
  final double topInset;

  late final BuildOwner owner;
  final ComboBoxOverlay overlay = ComboBoxOverlay();
  final List<String> changes = <String>[];
  int buttonPresses = 0;

  List<ComboBoxItem<String>> get _items => <ComboBoxItem<String>>[
        for (int i = 0; i < itemCount; i++)
          ComboBoxItem<String>(
            value: itemCount == 5 ? _codes[i] : 'item $i',
            label: itemCount == 5 ? _names[i] : 'Item $i',
            enabled: !disabled.contains(i),
          ),
      ];

  Widget _root() => Directionality(
        textDirection: direction,
        child: ComboBoxScope(
          overlay: overlay,
          child: Column(
            children: <Widget>[
              // Above the field, deliberately: the drop-down hangs *below* the
              // field, so a button placed after it would be underneath the
              // popup and "the click outside did not reach it" would be
              // asserting the wrong thing.
              Button(label: 'Behind', onPressed: () => buttonPresses++),
              SizedBox(height: topInset),
              Row(children: <Widget>[
                SizedBox(width: inset),
                SizedBox(
                  width: 120,
                  child: ComboBox<String>(
                    items: _items,
                    value: value,
                    label: 'Country',
                    placeholder: 'select one',
                    itemExtent: 22,
                    maxVisibleItems: maxVisibleItems,
                    popupWidth: popupWidth,
                    onChanged: enabled
                        ? (String next) {
                            changes.add(next);
                            value = next;
                            owner.updateRoot(_root());
                          }
                        : null,
                  ),
                ),
              ]),
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

  /// Rebuilds the tree from the harness's current fields, the way an
  /// application rebuilds after its own state changed.
  void rebuild() {
    owner.updateRoot(_root());
    frame();
  }

  void resize(Size next) {
    size = next;
    owner.pipelineOwner.rootConstraints = BoxConstraints.tight(next);
  }

  bool get isOpen => overlay.isOpen;

  PopupPlacement? get placement => overlay.placement;

  RenderComboBoxField get field => _find<RenderComboBoxField>()!;

  RenderButton get button => _find<RenderButton>()!;

  ScrollPosition get scroll => _find<RenderListBox>()!.position;

  Rect get fieldRect => _globalRect(field);

  Rect get buttonRect => _globalRect(button);

  Rect rowRect(int index) => _globalRect(
        _all<RenderListItem>().firstWhere(
          (RenderListItem item) => item.index == index,
        ),
      );

  List<String> get itemLabels => <String>[
        for (final RenderListItem item in _sortedRows())
          if (itemCount == 5) _names[item.index] else 'Item ${item.index}',
      ];

  int? get highlightedIndex {
    for (final RenderListItem item in _all<RenderListItem>()) {
      if (item.selected) return item.index;
    }
    return null;
  }

  List<RenderListItem> _sortedRows() => _all<RenderListItem>()
    ..sort((RenderListItem a, RenderListItem b) => a.index.compareTo(b.index));

  Rect _globalRect(RenderBox box) {
    final Offset topLeft = box.localToGlobal(Offset.zero);
    return Rect.fromLTWH(
      topLeft.dx,
      topLeft.dy,
      box.size.width,
      box.size.height,
    );
  }

  /// Gives the field the keyboard the way a user would: by clicking it and
  /// letting the click's own popup be dismissed again.
  void focusField() {
    field.focusNode!.requestFocus();
    frame();
  }

  void click(Offset position) {
    _pointer(position, down: true);
    _pointer(position, down: false);
  }

  void _pointer(Offset position, {required bool down}) =>
      owner.dispatchPointerEvent(down
          ? PointerDownEvent(
              windowId: const NativeWindowId(1),
              generation: 1,
              timestamp: Duration.zero,
              pointerId: 0,
              kind: PointerKind.mouse,
              logicalPosition: position,
              button: PointerButton.primary,
            )
          : PointerUpEvent(
              windowId: const NativeWindowId(1),
              generation: 1,
              timestamp: Duration.zero,
              pointerId: 0,
              kind: PointerKind.mouse,
              logicalPosition: position,
              button: PointerButton.primary,
            ));

  void pressKey(
    int logicalKey, {
    Set<KeyModifier> modifiers = const <KeyModifier>{},
  }) {
    dispatchKey(logicalKey, modifiers: modifiers);
    frame();
  }

  bool dispatchKey(
    int logicalKey, {
    Set<KeyModifier> modifiers = const <KeyModifier>{},
  }) =>
      owner.dispatchKeyEvent(KeyDownEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        physicalKey: logicalKey,
        logicalKey: logicalKey,
        modifiers: modifiers,
      ));

  /// Type-ahead arrives as *text*, which is the route a real keyboard layout
  /// produces and the only one that works outside a US keyboard.
  void type(String text) {
    owner.dispatchTextInputEvent(TextInputEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      text: text,
    ));
    frame();
  }

  T? _find<T extends RenderBox>() {
    final List<T> found = _all<T>();
    return found.isEmpty ? null : found.first;
  }

  List<T> _all<T extends RenderBox>() {
    final List<T> found = <T>[];
    void walk(RenderBox node) {
      if (node is T) found.add(node);
      node.visitChildren(walk);
    }

    final RenderBox? root = owner.renderRoot;
    if (root != null) walk(root);
    return found;
  }

  void dispose() => owner.dispose();
}
