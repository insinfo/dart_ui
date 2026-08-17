/// The split view: dragging, the minima, the keyboard, semantics and
/// right-to-left.
///
/// The assertions are on extents in pixels rather than on fractions, because
/// the failures this control actually has are pixel failures: a panel with a
/// negative width, two panels that swapped sides, a divider dragged off the
/// end of the window.
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

  group('layout', () {
    test('the panels start at the initial fraction and fill the box', () {
      final _Harness harness = _Harness()..frame();

      expect(harness.split.firstExtent, 150, reason: 'half of 300');
      expect(harness.split.secondExtent, 144, reason: '300 - 150 - 6');
      expect(harness.dividerRect.left, 150);
      expect(harness.dividerRect.width, 6);
      expect(harness.firstRect.left, 0);
      expect(harness.secondRect.right, 300);
      expect(
        harness.firstRect.width +
            harness.dividerRect.width +
            harness.secondRect.width,
        300,
        reason: 'the three of them are exactly the window',
      );
      harness.dispose();
    });

    test('a resize keeps both minima and never produces a negative panel', () {
      final _Harness harness = _Harness()
        ..frame()
        ..dragDividerTo(280)
        ..frame();
      expect(harness.split.firstExtent, 254, reason: '300 - 6 - 40');

      // Now shrink the window under the divider. The stored request is still
      // 254, which no longer fits at all.
      harness
        ..resize(const Size(120, 200))
        ..frame();

      expect(harness.split.firstExtent, 74, reason: '120 - 6 - 40');
      expect(harness.split.secondExtent, 40);
      expect(harness.firstRect.width, greaterThanOrEqualTo(0));
      expect(harness.secondRect.width, greaterThanOrEqualTo(0));

      // Narrower than both minima together: something must give, and it is the
      // first panel, down to zero but never below it.
      harness
        ..resize(const Size(30, 200))
        ..frame();
      expect(harness.split.firstExtent, 0);
      expect(harness.split.secondExtent, 24);
      expect(harness.firstRect.width, 0);
      harness.dispose();
    });
  });

  group('dragging', () {
    test('a drag moves the divider by exactly the pointer delta', () {
      final _Harness harness = _Harness()..frame();

      harness
        ..pressDivider()
        ..dragBy(const Offset(40, 0))
        ..frame();

      expect(harness.split.firstExtent, 190);
      expect(harness.dividerRect.left, 190);
      expect(harness.resizes, <double>[190]);

      harness
        ..dragBy(const Offset(-15, 0))
        ..frame();
      expect(harness.split.firstExtent, 135,
          reason: 'the delta is measured from where the press was, not from '
              'the previous move');
      harness
        ..releaseDivider()
        ..frame();
      expect(harness.divider.isDragging, isFalse);
      harness.dispose();
    });

    test('a drag past the minimum stops, and never inverts the panels', () {
      final _Harness harness = _Harness()..frame();

      harness
        ..pressDivider()
        ..dragBy(const Offset(1000, 0))
        ..frame();

      expect(harness.split.firstExtent, 254);
      expect(harness.split.secondExtent, 40, reason: 'its minimum, exactly');
      expect(harness.firstRect.left, lessThan(harness.secondRect.left),
          reason: 'the first panel is still the first one');

      harness
        ..dragBy(const Offset(-1000, 0))
        ..frame();

      expect(harness.split.firstExtent, 40);
      expect(harness.split.secondExtent, 254);
      expect(harness.firstRect.width, 40);
      expect(harness.secondRect.width, isNot(lessThan(0)));
      expect(harness.resizes.every((double extent) => extent >= 40), isTrue,
          reason: 'every value reported to the owner is already legal');
      harness.dispose();
    });

    test('a vertical split drags on the other axis', () {
      final _Harness harness = _Harness(axis: Axis.vertical)..frame();
      expect(harness.split.firstExtent, 100, reason: 'half of 200');

      harness
        ..pressDivider()
        ..dragBy(const Offset(0, 30))
        ..frame();

      expect(harness.split.firstExtent, 130);
      expect(harness.dividerRect.top, 130);
      expect(harness.firstRect.width, 300, reason: 'panels span the width');
      harness.dispose();
    });
  });

  group('keyboard', () {
    test('the arrows move the divider a step at a time', () {
      final _Harness harness = _Harness()
        ..frame()
        ..focusDivider();

      harness.pressKey(logicalKeyArrowRight);
      expect(harness.split.firstExtent, 160);
      harness.pressKey(logicalKeyArrowLeft);
      harness.pressKey(logicalKeyArrowLeft);
      expect(harness.split.firstExtent, 140);
      harness.dispose();
    });

    test('Home and End go to the minima, not off the end', () {
      final _Harness harness = _Harness()
        ..frame()
        ..focusDivider();

      harness.pressKey(logicalKeyEnd);
      expect(harness.split.firstExtent, 254);
      expect(harness.split.secondExtent, 40);

      harness.pressKey(logicalKeyHome);
      expect(harness.split.firstExtent, 40);
      expect(harness.split.secondExtent, 254);
      harness.dispose();
    });

    test('the divider is one tab stop of its own', () {
      final _Harness harness = _Harness()..frame();

      final List<String?> ring = <String?>[
        for (final FocusNode node in harness.owner.focusManager.traversalRing())
          node.debugLabel,
      ];

      expect(ring, contains('SplitViewDivider'));
      expect(
        ring.where((String? label) => label == 'SplitViewDivider'),
        hasLength(1),
      );
      harness.dispose();
    });
  });

  group('semantics', () {
    test('the divider is a slider with a value and both directions', () {
      final _Harness harness = _Harness()..frame();

      SemanticsNode divider() =>
          harness.owner.buildSemantics().nodes.firstWhere(
              (SemanticsNode node) => node.role == SemanticsRole.slider);

      expect(divider().label, 'split position');
      expect(divider().value, '150 of 300');
      expect(
          divider().actions,
          containsAll(<SemanticsAction>[
            SemanticsAction.increment,
            SemanticsAction.decrement,
          ]));

      harness
        ..focusDivider()
        ..pressKey(logicalKeyArrowRight);
      expect(divider().value, '160 of 300');
      expect(divider().states, contains(SemanticsState.focused));
      harness.dispose();
    });
  });

  group('right to left', () {
    test('the first panel is on the right and grows to the left', () {
      final _Harness harness = _Harness(
        direction: TextDirection.rightToLeft,
      )..frame();

      expect(harness.firstRect.right, 300,
          reason: 'the first panel is on the start side, which is the right');
      expect(harness.secondRect.left, 0);
      expect(harness.dividerRect.left, 144, reason: '300 - 150 - 6');

      // Dragging leftward makes the first panel bigger, because the first
      // panel is the right-hand one.
      harness
        ..pressDivider()
        ..dragBy(const Offset(-40, 0))
        ..frame();

      expect(harness.split.firstExtent, 190);
      expect(harness.firstRect.right, 300);
      expect(harness.firstRect.width, 190);
      harness.dispose();
    });

    test('the arrows follow the same rule as the drag', () {
      final _Harness harness = _Harness(
        direction: TextDirection.rightToLeft,
      )
        ..frame()
        ..focusDivider();

      harness.pressKey(logicalKeyArrowLeft);
      expect(harness.split.firstExtent, 160,
          reason: 'left is "bigger" when the first panel is on the right');
      harness.pressKey(logicalKeyArrowRight);
      expect(harness.split.firstExtent, 150);
      harness.dispose();
    });
  });
}

final class _Harness {
  _Harness({
    this.direction = TextDirection.leftToRight,
    this.axis = Axis.horizontal,
  }) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(rootConstraints: BoxConstraints.tight(size)),
    );
    owner.updateRoot(_root());
  }

  final TextDirection direction;
  final Axis axis;

  Size size = const Size(300, 200);
  late final BuildOwner owner;
  final List<double> resizes = <double>[];
  double? extent;
  Offset _pointerAt = Offset.zero;
  bool _rootIsStale = false;

  Widget _root() => Directionality(
        textDirection: direction,
        child: SplitView(
          axis: axis,
          minFirst: 40,
          minSecond: 40,
          dividerThickness: 6,
          keyboardStep: 10,
          onResized: (double value) {
            resizes.add(value);
            extent = value;
          },
        first: const ColoredBox(color: Color(0xFF102030)),
        second: const ColoredBox(color: Color(0xFF203040)),
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

  void resize(Size next) {
    size = next;
    owner.pipelineOwner.rootConstraints = BoxConstraints.tight(next);
  }

  RenderSplitView get split => _all<RenderSplitView>().single;

  RenderSplitDivider get divider => _all<RenderSplitDivider>().single;

  Rect get dividerRect => split.dividerRect;

  Rect get firstRect => _rectOf(split.childAt(0));

  Rect get secondRect => _rectOf(split.childAt(2));

  Rect _rectOf(RenderBox child) {
    final Offset offset = child.offsetFromParent;
    return Rect.fromLTWH(
      offset.dx,
      offset.dy,
      child.size.width,
      child.size.height,
    );
  }

  void focusDivider() {
    divider.focusNode!.requestFocus(FocusChangeReason.traversal);
    frame();
  }

  /// Presses the divider at its centre, which is where a user grabs it.
  void pressDivider() {
    _pointerAt = divider.localToGlobal(
      Offset(divider.size.width / 2, divider.size.height / 2),
    );
    _dispatch(PointerDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: _pointerAt,
      button: PointerButton.primary,
    ));
  }

  /// Moves the pointer by [delta] from where it was *pressed*.
  void dragBy(Offset delta) => _dispatch(PointerMoveEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: Offset(
          _pointerAt.dx + delta.dx,
          _pointerAt.dy + delta.dy,
        ),
      ));

  void releaseDivider() => _dispatch(PointerUpEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: _pointerAt,
        button: PointerButton.primary,
      ));

  /// A whole grab-and-drop that leaves the divider's start edge at [position]
  /// in the split's own coordinates.
  void dragDividerTo(double position) {
    pressDivider();
    final double delta = position - split.firstExtent;
    dragBy(Offset(direction.isRightToLeft ? -delta : delta, 0));
    releaseDivider();
  }

  void _dispatch(PointerEvent event) => owner.dispatchPointerEvent(event);

  void pressKey(int logicalKey) {
    owner.dispatchKeyEvent(KeyDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      physicalKey: logicalKey,
      logicalKey: logicalKey,
    ));
    frame();
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
