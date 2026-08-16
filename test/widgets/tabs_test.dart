/// Tabs: one tab stop for the whole strip, arrow-key navigation, a selection
/// that survives its tab being removed, a sliding indicator on a virtual clock,
/// semantics and right-to-left.
///
/// The indicator is asserted as a *rect*, never as an animation value: a bar
/// interpolated correctly and painted in the wrong place is exactly the bug an
/// assertion on `controller.value` cannot see.
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

  group('structure and focus', () {
    test('the whole strip is one tab stop, not one per tab', () {
      final _Harness harness = _Harness()..frame();

      final List<FocusNode> ring = harness.owner.focusManager.traversalRing();

      // Before and after: two buttons and the strip. Eight tabs would be eight
      // stops if the headers were focusable, which is the bug this asserts is
      // absent.
      expect(ring, hasLength(3));
      expect(ring[1].debugLabel, 'Tabs');
      harness.dispose();
    });

    test('only the selected panel is built, so Tab cannot reach a hidden one',
        () {
      final _Harness harness = _Harness()..frame();

      expect(harness.panelLabels, <String>['general body']);

      harness
        ..select(1)
        ..frame();
      expect(harness.panelLabels, <String>['network body']);
      harness.dispose();
    });

    test('a click selects a tab and moves focus onto the strip', () {
      final _Harness harness = _Harness()..frame();

      harness
        ..click(harness.headerRect(2).center)
        ..frame();

      expect(harness.selectedIndex, 2);
      expect(harness.strip.hasFocus, isTrue);
      expect(harness.strip.isFocusVisible, isFalse,
          reason: 'a mouse click shows no focus ring');
      harness.dispose();
    });
  });

  group('keyboard', () {
    test('the arrows walk the strip and stop at the ends', () {
      final _Harness harness = _Harness()
        ..frame()
        ..focusStrip();

      harness.pressKey(logicalKeyArrowRight);
      expect(harness.selectedIndex, 1);
      harness.pressKey(logicalKeyArrowRight);
      expect(harness.selectedIndex, 2);

      // Stops rather than wrapping: a tab strip is a row of pages, and the
      // last page does not lead back to the first.
      harness.pressKey(logicalKeyArrowRight);
      expect(harness.selectedIndex, 2);

      harness.pressKey(logicalKeyArrowLeft);
      expect(harness.selectedIndex, 1);
      harness.pressKey(logicalKeyHome);
      expect(harness.selectedIndex, 0);
      harness.pressKey(logicalKeyEnd);
      expect(harness.selectedIndex, 2);
      harness.dispose();
    });

    test('a disabled tab is stepped over, not landed on', () {
      final _Harness harness = _Harness(disabled: <int>{1})
        ..frame()
        ..focusStrip();

      harness.pressKey(logicalKeyArrowRight);

      expect(harness.selectedIndex, 2);
      harness.dispose();
    });

    test('Tab leaves the strip in one step', () {
      final _Harness harness = _Harness()
        ..frame()
        ..focusStrip();
      expect(harness.strip.hasFocus, isTrue);

      harness
        ..dispatchKey(logicalKeyTab)
        ..frame();

      expect(harness.strip.hasFocus, isFalse);
      expect(harness.selectedIndex, 0, reason: 'leaving is not choosing');
      harness.dispose();
    });
  });

  group('a tab that disappears', () {
    test('the selection follows its tab when an earlier one is removed', () {
      final _Harness harness = _Harness()
        ..select(2)
        ..frame();
      expect(harness.selectedLabel, 'Advanced');

      harness
        ..remove('General')
        ..frame();

      // Index 1 now, because the tab that was selected moved down one - the
      // panel on screen is still the one the user was reading.
      expect(harness.selectedIndex, 1);
      expect(harness.selectedLabel, 'Advanced');
      expect(harness.panelLabels, <String>['advanced body']);
      harness.dispose();
    });

    test('removing the selected tab hands the selection to a neighbour', () {
      final _Harness harness = _Harness()
        ..select(1)
        ..frame();

      harness
        ..remove('Network')
        ..frame();

      expect(harness.selectedIndex, 1);
      expect(harness.selectedLabel, 'Advanced',
          reason: 'the tab that moved into the gap takes the selection');
      expect(harness.headerLabels, <String>['General', 'Advanced']);
      harness.dispose();
    });

    test('removing the last tab while it is selected steps backwards', () {
      final _Harness harness = _Harness()
        ..select(2)
        ..frame();

      harness
        ..remove('Advanced')
        ..frame();

      expect(harness.selectedIndex, 1);
      expect(harness.selectedLabel, 'Network');
      expect(harness.panelLabels, <String>['network body']);
      harness.dispose();
    });

    test('an out-of-range index is corrected rather than rendered', () {
      final _Harness harness = _Harness()
        ..select(2)
        ..frame()
        ..removeAll()
        ..frame();

      expect(harness.headerLabels, isEmpty);
      expect(harness.strip.indicatorRect.width, 0,
          reason: 'no tab, no indicator - and no crash on an index of 2');
      harness.dispose();
    });
  });

  group('the indicator', () {
    test('with no clock it lands on the selected tab immediately', () {
      final _Harness harness = _Harness()..frame();
      expect(harness.strip.indicatorRect.left, harness.headerRect(0).left);
      expect(harness.strip.indicatorRect.width, harness.headerRect(0).width);

      harness
        ..select(2)
        ..frame();

      expect(harness.strip.indicatorRect.left, harness.headerRect(2).left);
      expect(harness.strip.indicatorRect.width, harness.headerRect(2).width);
      harness.dispose();
    });

    test('with a clock it slides, and the slide is exactly the duration', () {
      final AnimationClock clock = AnimationClock();
      final ManualDispatcher dispatcher = ManualDispatcher();
      final _Harness harness = _Harness(clock: clock)..frame();

      final double start = harness.headerRect(0).left;
      final double end = harness.headerRect(2).left;
      expect(end, greaterThan(start));

      harness
        ..select(2)
        ..frame();
      // The first tick only gives the controller its origin - a ticker
      // registered mid-frame has no baseline, and `animation/clock.dart` is
      // explicit that it must not invent one from the clock's own history.
      clock.tick(dispatcher.elapsed);
      harness.frame();
      expect(harness.strip.indicatorRect.left, start,
          reason: 'no time has passed, so nothing has moved yet');

      dispatcher.advance(const Duration(milliseconds: 75));
      clock.tick(dispatcher.elapsed);
      harness.frame();
      final double midway = harness.strip.indicatorRect.left;
      expect(midway, greaterThan(start));
      expect(midway, lessThan(end));
      expect(
          harness.strip.indicatorRect.width, isNot(harness.headerRect(2).width),
          reason: 'the bar stretches between two headers of different widths');

      dispatcher.advance(const Duration(milliseconds: 75));
      clock.tick(dispatcher.elapsed);
      harness.frame();

      // 150ms of animation on a clock that has been advanced by exactly 150.
      expect(harness.strip.indicatorRect.left, end);
      expect(harness.strip.indicatorRect.width, harness.headerRect(2).width);
      harness.dispose();
    });

    test('a reduced-motion theme skips the slide entirely', () {
      final AnimationClock clock = AnimationClock();
      final _Harness harness = _Harness(clock: clock, reducedMotion: true)
        ..frame();

      harness
        ..select(2)
        ..frame();

      expect(harness.strip.indicatorRect.left, harness.headerRect(2).left,
          reason: 'motion the user asked not to see is not shown at all');
      harness.dispose();
    });
  });

  group('semantics', () {
    test('the strip is a list and the headers are its selectable items', () {
      final _Harness harness = _Harness()
        ..select(1)
        ..frame();

      final SemanticsSnapshot snapshot = harness.owner.buildSemantics();
      final SemanticsNode strip = snapshot.nodes.firstWhere(
        (SemanticsNode node) => node.role == SemanticsRole.list,
      );
      expect(strip.value, '3 tabs');
      expect(strip.hint, 'tab 2 of 3');

      final List<SemanticsNode> headers = snapshot.nodes
          .where((SemanticsNode node) => node.role == SemanticsRole.listItem)
          .toList();
      expect(headers.map((SemanticsNode node) => node.label),
          <String>['General', 'Network', 'Advanced']);
      expect(
        headers
            .where((SemanticsNode node) =>
                node.states.contains(SemanticsState.selected))
            .map((SemanticsNode node) => node.label),
        <String>['Network'],
      );
      expect(headers[1].actions, contains(SemanticsAction.activate));
      harness.dispose();
    });

    test('a focused strip says so, and a disabled tab says so', () {
      final _Harness harness = _Harness(disabled: <int>{2})
        ..frame()
        ..focusStrip();

      final SemanticsSnapshot snapshot = harness.owner.buildSemantics();
      expect(
        snapshot.nodes
            .firstWhere((SemanticsNode node) => node.role == SemanticsRole.list)
            .states,
        contains(SemanticsState.focused),
      );
      expect(
        snapshot.nodes
            .firstWhere((SemanticsNode node) => node.label == 'Advanced')
            .states,
        contains(SemanticsState.disabled),
      );
      harness.dispose();
    });
  });

  group('right to left', () {
    test('the first tab is on the right and the arrows follow the eye', () {
      final _Harness harness = _Harness(
        direction: TextDirection.rightToLeft,
      )
        ..frame()
        ..focusStrip();

      final Rect first = harness.headerRect(0);
      final Rect second = harness.headerRect(1);
      expect(first.right, harness.stripRect.right,
          reason: 'the first tab sits against the start edge, which is right');
      expect(second.right, first.left, reason: 'the strip grows leftward');

      // Left is "the next one" here, because the next one is drawn to the left.
      harness.pressKey(logicalKeyArrowLeft);
      expect(harness.selectedIndex, 1);
      harness.pressKey(logicalKeyArrowRight);
      expect(harness.selectedIndex, 0);
      harness.dispose();
    });

    test('the indicator sits under the tab it belongs to in both directions',
        () {
      for (final TextDirection direction in TextDirection.values) {
        final _Harness harness = _Harness(direction: direction)
          ..select(1)
          ..frame();

        expect(harness.strip.indicatorRect.left, harness.headerRect(1).left);
        expect(harness.strip.indicatorRect.width, harness.headerRect(1).width);
        expect(
          harness.strip.indicatorRect.top,
          harness.stripRect.height - 2,
          reason: 'the bar is on the bottom edge of the strip',
        );
        harness.dispose();
      }
    });
  });
}

final class _Harness {
  _Harness({
    this.direction = TextDirection.leftToRight,
    this.disabled = const <int>{},
    this.clock,
    this.reducedMotion = false,
  }) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(320, 200)),
      ),
    );
    owner.updateRoot(_root());
  }

  final TextDirection direction;
  final Set<int> disabled;
  final AnimationClock? clock;
  final bool reducedMotion;

  late final BuildOwner owner;
  int selectedIndex = 0;
  int presses = 0;
  bool _rootIsStale = false;
  final List<int> selections = <int>[];
  List<String> labels = <String>['General', 'Network', 'Advanced'];

  static const Map<String, String> _bodies = <String, String>{
    'General': 'general body',
    'Network': 'network body',
    'Advanced': 'advanced body',
  };

  String get selectedLabel => labels[selectedIndex];

  Widget _root() => Directionality(
        textDirection: direction,
        child: Theme(
          data: ThemeData.neutralLight.copyWith(reducedMotion: reducedMotion),
          child: Column(
            children: <Widget>[
              Button(label: 'Before', onPressed: () => presses++),
              SizedBox(
                height: 120,
                child: Tabs(
                  tabs: <TabItem>[
                    for (int i = 0; i < labels.length; i++)
                      TabItem(
                        label: labels[i],
                        enabled: !disabled.contains(i),
                        content: Text(_bodies[labels[i]]!),
                      ),
                  ],
                  selectedIndex: selectedIndex,
                  clock: clock,
                  onSelected: (int index) {
                    selections.add(index);
                    selectedIndex = index;
                    // Marked rather than rebuilt on the spot: this callback can
                    // arrive from inside a build - a tab list that lost the
                    // selected tab reconciles during `didUpdateWidget` - and
                    // rebuilding the root from there is reentrant. An
                    // application would call `setState`, which is the same
                    // "do it on the next pass" contract.
                    _rootIsStale = true;
                  },
                ),
              ),
              Button(label: 'After', onPressed: () => presses++),
            ],
          ),
        ),
      );

  void frame({int maxPasses = 8}) {
    for (int pass = 0; pass < maxPasses; pass++) {
      if (_rootIsStale) {
        _rootIsStale = false;
        owner.updateRoot(_root());
      }
      owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds && !_rootIsStale) return;
    }
    throw StateError('the tree never settled');
  }

  void select(int index) {
    selectedIndex = index;
    _rootIsStale = true;
  }

  void remove(String label) {
    labels = <String>[
      for (final String name in labels)
        if (name != label) name,
    ];
    _rootIsStale = true;
  }

  void removeAll() {
    labels = <String>[];
    _rootIsStale = true;
  }

  RenderTabStrip get strip => _all<RenderTabStrip>().single;

  List<RenderTabHeader> get headers => _all<RenderTabHeader>();

  List<String> get headerLabels =>
      <String>[for (final RenderTabHeader header in headers) header.label];

  List<String> get panelLabels => <String>[
        for (final RenderTabPanel panel in _all<RenderTabPanel>())
          for (final RenderText text in _within<RenderText>(panel)) text.text,
      ];

  Rect get stripRect => _globalRect(strip);

  Rect headerRect(int index) => Rect.fromLTWH(
        headers[index].offsetFromParent.dx,
        headers[index].offsetFromParent.dy,
        headers[index].size.width,
        headers[index].size.height,
      );

  Rect _globalRect(RenderBox box) {
    final Offset topLeft = box.localToGlobal(Offset.zero);
    return Rect.fromLTWH(
      topLeft.dx,
      topLeft.dy,
      box.size.width,
      box.size.height,
    );
  }

  void focusStrip() {
    strip.focusNode!.requestFocus(FocusChangeReason.traversal);
    frame();
  }

  /// Clicks a point given in the *strip's* coordinates.
  void click(Offset positionInStrip) {
    final Offset global = strip.localToGlobal(positionInStrip);
    _pointer(global, down: true);
    _pointer(global, down: false);
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

  void pressKey(int logicalKey) {
    dispatchKey(logicalKey);
    frame();
  }

  bool dispatchKey(int logicalKey) => owner.dispatchKeyEvent(KeyDownEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        physicalKey: logicalKey,
        logicalKey: logicalKey,
      ));

  List<T> _all<T extends RenderBox>() {
    final RenderBox? root = owner.renderRoot;
    return root == null ? <T>[] : _within<T>(root);
  }

  List<T> _within<T extends RenderBox>(RenderBox from) {
    final List<T> found = <T>[];
    void walk(RenderBox node) {
      if (node is T) found.add(node);
      node.visitChildren(walk);
    }

    walk(from);
    return found;
  }

  void dispose() => owner.dispose();
}
