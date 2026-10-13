/// `ScrollPhysics`, as a scroll view uses it.
///
/// The arithmetic first (a physics is a pure function of the metrics), then
/// each physics in a real list: who may scroll, how far past an edge, and
/// where the content comes to rest - on a virtual clock, to the pixel.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  ScrollMetrics metrics({
    double pixels = 0,
    double max = 900,
    double viewport = 100,
  }) =>
      FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: max,
        pixels: pixels,
        viewportDimension: viewport,
        axisDirection: AxisDirection.down,
        devicePixelRatio: 1,
      );

  group('the arithmetic', () {
    test('applyTo keeps each physics its own type, down the chain', () {
      final ScrollPhysics chain = const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ).applyTo(const ClampingScrollPhysics());

      expect(chain, isA<BouncingScrollPhysics>());
      expect(chain.parent, isA<AlwaysScrollableScrollPhysics>());
      expect(chain.parent!.parent, isA<ClampingScrollPhysics>());
      expect(chain.parent!.parent!.parent, isNull);
      expect(
        chain.toString(),
        'BouncingScrollPhysics -> AlwaysScrollableScrollPhysics -> '
        'ClampingScrollPhysics',
      );
    });

    test('by default the user may scroll only content that can move', () {
      const ScrollPhysics physics = ScrollPhysics();
      expect(physics.shouldAcceptUserOffset(metrics()), isTrue);
      expect(physics.shouldAcceptUserOffset(metrics(max: 0)), isFalse);
      expect(
        const AlwaysScrollableScrollPhysics()
            .shouldAcceptUserOffset(metrics(max: 0)),
        isTrue,
      );
      expect(
        const NeverScrollableScrollPhysics().shouldAcceptUserOffset(metrics()),
        isFalse,
      );
      // Never anywhere in the chain wins.
      expect(
        const AlwaysScrollableScrollPhysics(
          parent: NeverScrollableScrollPhysics(),
        ).allowUserScrolling,
        isFalse,
      );
    });

    test('clamping turns a move past an edge into an overscroll', () {
      const ClampingScrollPhysics clamping = ClampingScrollPhysics();
      expect(clamping.applyBoundaryConditions(metrics(pixels: 50), 80), 0);
      expect(clamping.applyBoundaryConditions(metrics(pixels: 10), -30), -30);
      expect(clamping.applyBoundaryConditions(metrics(), -5), -5);
      expect(clamping.applyBoundaryConditions(metrics(pixels: 890), 910), 10);
      expect(
        const BouncingScrollPhysics()
            .applyBoundaryConditions(metrics(pixels: 890), 910),
        0,
      );
    });

    test('bouncing resists a drag that is already past the edge', () {
      const BouncingScrollPhysics bouncing = BouncingScrollPhysics();
      // In range, a drag is a drag.
      expect(bouncing.applyPhysicsToUserOffset(metrics(pixels: 50), 10), 10);
      // 20px past the start of a 100px viewport: friction 0.52 * 0.8^2.
      final double resisted =
          bouncing.applyPhysicsToUserOffset(metrics(pixels: -20), 10);
      expect(resisted, closeTo(10 * 0.52 * 0.64, 1e-9));
    });

    test('the clamping fling has the framework\'s own decay', () {
      final ClampingScrollSimulation fling =
          ClampingScrollSimulation(position: 0, velocity: 1000);
      // 16 px in the first 16ms step, then 0.94 of that in the next.
      expect(fling.x(const Duration(milliseconds: 16)), closeTo(16, 1e-9));
      expect(
        fling.x(const Duration(milliseconds: 32)),
        closeTo(16 + 16 * 0.94, 1e-9),
      );
      expect(fling.isDone(const Duration(milliseconds: 16 * 78)), isFalse);
      expect(fling.isDone(const Duration(milliseconds: 16 * 79)), isTrue);
    });

    test('a bouncing fling past the end springs back to it', () {
      final BouncingScrollSimulation fling = BouncingScrollSimulation(
        position: 880,
        velocity: 2000,
        leadingExtent: 0,
        trailingExtent: 900,
        spring: const ScrollPhysics().spring,
      );
      double furthest = 0;
      Duration t = Duration.zero;
      while (!fling.isDone(t) && t < const Duration(seconds: 10)) {
        t += const Duration(milliseconds: 16);
        if (fling.x(t) > furthest) furthest = fling.x(t);
      }
      expect(furthest, greaterThan(900), reason: 'it went past the end');
      expect(fling.restingPosition, 900);
      expect(fling.x(t), closeTo(900, 1));
    });
  });

  group('in a list', () {
    test('NeverScrollable ignores drag, wheel and keys, not jumpTo', () {
      final ScrollController controller = ScrollController();
      final harness = _Harness(
        CustomScrollView(
          controller: controller,
          physics: const NeverScrollableScrollPhysics(),
          scrollbar: ScrollbarVisibility.never,
          slivers: <Widget>[_rows(100)],
        ),
      );

      harness.pointer(_wheel(const Offset(50, 50), 30));
      harness.pointer(_down(const Offset(50, 90)));
      harness.pointer(_move(const Offset(50, 30), millis: 50));
      harness.pointer(_up(const Offset(50, 30), millis: 900));
      harness.pointer(_mouseDown(const Offset(50, 50)));
      harness.key(logicalKeyPageDown);
      expect(controller.offset, 0);

      controller.jumpTo(120);
      expect(controller.offset, 120);
      harness.dispose();
    });

    test('a wheel the inner view may not take reaches the outer one', () {
      final ScrollController outer = ScrollController();
      final ScrollController inner = ScrollController();
      final harness = _Harness(
        CustomScrollView(
          controller: outer,
          scrollbar: ScrollbarVisibility.never,
          slivers: <Widget>[
            SliverToBoxAdapter(
              child: SizedBox(
                height: 60,
                child: ListView.builder(
                  controller: inner,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: 100,
                  itemExtent: 20,
                  scrollbar: ScrollbarVisibility.never,
                  itemBuilder: (BuildContext context, int index) =>
                      const SizedBox(height: 20),
                ),
              ),
            ),
            _rows(100),
          ],
        ),
      );
      harness.pointer(_wheel(const Offset(50, 30), 25));
      expect(inner.offset, 0);
      expect(outer.offset, 25);
      harness.dispose();
    });

    test('a short list takes a drag only with AlwaysScrollable', () {
      for (final bool always in <bool>[false, true]) {
        final List<ScrollNotification> heard = <ScrollNotification>[];
        final harness = _Harness(
          NotificationListener<ScrollNotification>(
            onNotification: (ScrollNotification n) {
              heard.add(n);
              return false;
            },
            child: ListView.builder(
              physics: always
                  ? const AlwaysScrollableScrollPhysics()
                  : const ClampingScrollPhysics(),
              itemCount: 2,
              itemExtent: 20,
              scrollbar: ScrollbarVisibility.never,
              itemBuilder: (BuildContext context, int index) =>
                  const SizedBox(height: 20),
            ),
          ),
        );
        harness.pointer(_down(const Offset(50, 90)));
        harness.pointer(_move(const Offset(50, 30), millis: 50));
        harness.pointer(_up(const Offset(50, 30), millis: 900));
        expect(
          heard.whereType<ScrollStartNotification>(),
          always ? hasLength(1) : isEmpty,
        );
        harness.dispose();
      }
    });

    test('bouncing pulls past the start and springs back on release', () {
      final ManualDispatcher dispatcher = ManualDispatcher();
      final ScrollController controller = ScrollController();
      final harness = _Harness(
        ListView.builder(
          controller: controller,
          dispatcher: dispatcher,
          physics: const BouncingScrollPhysics(),
          itemCount: 100,
          itemExtent: 20,
          scrollbar: ScrollbarVisibility.never,
          itemBuilder: (BuildContext context, int index) =>
              const SizedBox(height: 20),
        ),
      );

      harness.pointer(_down(const Offset(50, 10)));
      harness.pointer(_move(const Offset(50, 40), millis: 100));
      harness.pointer(_move(const Offset(50, 70), millis: 200));
      harness.pointer(_move(const Offset(50, 90), millis: 300));
      final double pulled = controller.offset;
      expect(pulled, lessThan(0), reason: 'held past the start');
      // The rows moved down with it: layout did not clamp the overscroll.
      expect(harness.find<RenderVirtualList>().childAt(0).offsetFromParent.dy,
          -pulled);

      harness.pointer(_up(const Offset(50, 90), millis: 900));
      dispatcher.advance(const Duration(milliseconds: 48));
      expect(controller.offset, greaterThan(pulled));
      expect(controller.offset, lessThan(0));

      dispatcher.advance(const Duration(seconds: 3));
      expect(controller.offset, 0);
      expect(controller.position.isScrolling, isFalse);
      expect(dispatcher.pendingTimerCount, 0);
      harness.dispose();
    });

    test('without a clock a bounce settles at once', () {
      final ScrollController controller = ScrollController();
      final harness = _Harness(
        ListView.builder(
          controller: controller,
          physics: const BouncingScrollPhysics(),
          itemCount: 100,
          itemExtent: 20,
          scrollbar: ScrollbarVisibility.never,
          itemBuilder: (BuildContext context, int index) =>
              const SizedBox(height: 20),
        ),
      );
      harness.pointer(_down(const Offset(50, 10)));
      harness.pointer(_move(const Offset(50, 60), millis: 100));
      harness.pointer(_move(const Offset(50, 90), millis: 200));
      expect(controller.offset, lessThan(0));
      harness.pointer(_up(const Offset(50, 90), millis: 900));
      expect(controller.offset, 0);
      harness.dispose();
    });

    test('an explicit ClampingScrollPhysics flings as the default does', () {
      double flung(ScrollPhysics? physics) {
        final ManualDispatcher dispatcher = ManualDispatcher();
        final ScrollController controller = ScrollController();
        final harness = _Harness(
          ListView.builder(
            controller: controller,
            dispatcher: dispatcher,
            physics: physics,
            itemCount: 100000,
            itemExtent: 20,
            scrollbar: ScrollbarVisibility.never,
            itemBuilder: (BuildContext context, int index) =>
                const SizedBox(height: 20),
          ),
        );
        harness.pointer(_down(const Offset(10, 90), mouse: true));
        for (int step = 1; step <= 6; step++) {
          harness.pointer(
            _move(Offset(10, 90 - step * 8), millis: step * 8, mouse: true),
          );
        }
        harness.pointer(_up(const Offset(10, 42), millis: 56, mouse: true));
        dispatcher.advance(const Duration(seconds: 5));
        final double offset = controller.offset;
        harness.dispose();
        return offset;
      }

      final double byDefault = flung(null);
      expect(flung(const ClampingScrollPhysics()), closeTo(byDefault, 0.5));
    });
  });
}

Widget _rows(int count) => SliverFixedExtentList.builder(
      itemExtent: 20,
      itemCount: count,
      itemBuilder: (BuildContext context, int index) =>
          const SizedBox(height: 20),
    );

final class _Harness {
  _Harness(Widget widget, {Size size = const Size(200, 100)}) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(rootConstraints: BoxConstraints.tight(size)),
    );
    mount(widget);
  }

  late final BuildOwner owner;

  void mount(Widget widget) {
    owner.updateRoot(widget);
    frame();
  }

  void frame({int maxPasses = 12}) {
    for (int pass = 0; pass < maxPasses; pass++) {
      if (owner.hasScheduledBuilds) owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
    throw StateError('the scroll view never settled');
  }

  bool pointer(PointerEvent event) {
    final bool handled = owner.dispatchPointerEvent(event);
    frame();
    return handled;
  }

  bool key(int logicalKey) {
    final bool handled = owner.dispatchKeyEvent(KeyDownEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration.zero,
      physicalKey: logicalKey,
      logicalKey: logicalKey,
    ));
    frame();
    return handled;
  }

  T find<T extends RenderBox>() {
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
    if (found == null) throw StateError('no $T in the tree');
    return found!;
  }

  void dispose() => owner.dispose();
}

const NativeWindowId _window = NativeWindowId(1);

PointerDownEvent _down(Offset at, {int millis = 0, bool mouse = false}) =>
    PointerDownEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration(milliseconds: millis),
      pointerId: 0,
      kind: mouse ? PointerKind.mouse : PointerKind.touch,
      logicalPosition: at,
      button: PointerButton.primary,
    );

PointerDownEvent _mouseDown(Offset at) => PointerDownEvent(
      windowId: _window,
      generation: 1,
      timestamp: const Duration(seconds: 2),
      pointerId: 1,
      kind: PointerKind.mouse,
      logicalPosition: at,
      button: PointerButton.primary,
    );

PointerMoveEvent _move(Offset at, {int millis = 0, bool mouse = false}) =>
    PointerMoveEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration(milliseconds: millis),
      pointerId: 0,
      kind: mouse ? PointerKind.mouse : PointerKind.touch,
      logicalPosition: at,
    );

PointerUpEvent _up(Offset at, {int millis = 0, bool mouse = false}) =>
    PointerUpEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration(milliseconds: millis),
      pointerId: 0,
      kind: mouse ? PointerKind.mouse : PointerKind.touch,
      logicalPosition: at,
      button: PointerButton.primary,
    );

PointerScrollEvent _wheel(Offset at, double dy) => PointerScrollEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
      scrollDelta: Offset(0, dy),
      scrollDeltaUnit: ScrollDeltaUnit.pixels,
    );
