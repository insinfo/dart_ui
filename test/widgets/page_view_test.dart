/// `PageView` and `PageController`, as Flutter defines them, on a virtual
/// clock: where pages are laid out, where a drag, a fling, the wheel and the
/// keys bring the view to rest, and what the controller reports on the way.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('layout', () {
    test('pages fill the viewport, side by side', () {
      final PageController controller = PageController();
      final harness = _Harness(_pages(controller: controller));

      expect(controller.position.maxScrollExtent, 400, reason: '3 x 200 - 200');
      expect(controller.page, 0);
      expect(harness.pageLeft(0), 0);
      expect(harness.pageWidth(0), 200);
      harness.dispose();
    });

    test('initialPage is where the view opens', () {
      final PageController controller = PageController(initialPage: 2);
      final harness = _Harness(_pages(controller: controller));
      expect(controller.offset, 400);
      expect(controller.page, 2);
      expect(harness.pageLeft(2), 0);
      harness.dispose();
    });

    test('viewportFraction centres a narrower page between its neighbours', () {
      final PageController controller = PageController(
        viewportFraction: 0.8,
        initialPage: 1,
      );
      final harness = _Harness(_pages(controller: controller));

      // 160px pages, 20px of padding at each end: page 1 at offset 160.
      expect(controller.offset, 160);
      expect(harness.pageWidth(1), 160);
      expect(harness.pageLeft(1), 20);
      expect(harness.pageLeft(0), 20 - 160);
      expect(controller.position.maxScrollExtent, 320);
      harness.dispose();
    });

    test('a resize keeps the page, not the offset', () {
      final PageController controller = PageController(initialPage: 2);
      final harness = _Harness(
        Center(
            child: SizedBox(
                width: 200,
                height: 100,
                child: _pages(
                  controller: controller,
                ))),
        size: const Size(400, 100),
      );
      expect(controller.offset, 400);

      harness.mount(Center(
          child: SizedBox(
              width: 300,
              height: 100,
              child: _pages(
                controller: controller,
              ))));
      expect(controller.offset, 600);
      expect(controller.page, 2);
      harness.dispose();
    });

    test('a vertical view stacks its pages', () {
      final PageController controller = PageController();
      final harness = _Harness(
        _pages(controller: controller, direction: Axis.vertical),
      );
      expect(controller.position.axis, Axis.vertical);
      expect(controller.position.maxScrollExtent, 200, reason: '3 x 100 - 100');
      harness.dispose();
    });

    test('a builder builds only the pages on screen, endless or not', () {
      final List<int> built = <int>[];
      final PageController controller = PageController(initialPage: 1000);
      final harness = _Harness(
        PageView.builder(
          controller: controller,
          itemBuilder: (BuildContext context, int index) {
            built.add(index);
            return SizedBox(key: ValueKey<int>(index));
          },
        ),
      );
      expect(built.toSet(), <int>{1000});
      expect(controller.page, 1000);
      harness.dispose();
    });
  });

  group('snapping', () {
    test('a slow drag released short of halfway springs back', () {
      final ManualDispatcher dispatcher = ManualDispatcher();
      final PageController controller = PageController();
      final harness = _Harness(
        _pages(controller: controller, dispatcher: dispatcher),
      );

      harness.slowDrag(from: 150, to: 90);
      expect(controller.offset, greaterThan(0));

      dispatcher.advance(const Duration(seconds: 2));
      expect(controller.offset, 0);
      expect(controller.page, 0);
      harness.dispose();
    });

    test('a slow drag released past halfway turns the page', () {
      final ManualDispatcher dispatcher = ManualDispatcher();
      final PageController controller = PageController();
      final List<int> changes = <int>[];
      final harness = _Harness(
        _pages(
          controller: controller,
          dispatcher: dispatcher,
          onPageChanged: changes.add,
        ),
      );

      harness.slowDrag(from: 190, to: 50);
      dispatcher.advance(const Duration(seconds: 2));

      expect(controller.offset, 200);
      expect(controller.page, 1);
      expect(changes, <int>[1], reason: 'once, when it crossed halfway');
      harness.dispose();
    });

    test('a fling turns the page even when short of halfway', () {
      final ManualDispatcher dispatcher = ManualDispatcher();
      final PageController controller = PageController();
      final harness = _Harness(
        _pages(controller: controller, dispatcher: dispatcher),
      );

      harness.pointer(_down(const Offset(150, 50)));
      for (int step = 1; step <= 6; step++) {
        harness.pointer(_move(Offset(150 - step * 8, 50), millis: step * 8));
      }
      harness.pointer(_up(const Offset(102, 50), millis: 56));
      expect(controller.offset, lessThan(100));
      dispatcher.advance(const Duration(seconds: 2));

      expect(controller.offset, 200);
      harness.dispose();
    });

    test('without pageSnapping the view rests where it is let go', () {
      final PageController controller = PageController();
      final harness = _Harness(
        _pages(controller: controller, snapping: false),
      );
      harness.slowDrag(from: 150, to: 90);
      expect(controller.offset, closeTo(60, 20));
      expect(controller.offset % 200, isNot(0));
      harness.dispose();
    });

    test('a NeverScrollable page view does not move under a drag', () {
      final PageController controller = PageController();
      final harness = _Harness(
        _pages(
          controller: controller,
          physics: const NeverScrollableScrollPhysics(),
        ),
      );
      harness.slowDrag(from: 190, to: 20);
      harness.pointer(_wheel(const Offset(100, 50), const Offset(30, 0)));
      expect(controller.offset, 0);
      controller.jumpToPage(2);
      expect(controller.offset, 400);
      harness.dispose();
    });
  });

  group('wheel and keys', () {
    test('a wheel notch turns one page; notches in flight add up', () {
      final ManualDispatcher dispatcher = ManualDispatcher();
      final PageController controller = PageController();
      final harness = _Harness(
        _pages(controller: controller, dispatcher: dispatcher, count: 5),
      );

      harness.pointer(_wheel(const Offset(100, 50), const Offset(10, 0)));
      dispatcher.advance(const Duration(milliseconds: 100));
      expect(controller.offset, greaterThan(0));
      expect(controller.offset, lessThan(200));
      // Mid-turn: this one counts from page 1, where the turn is heading.
      harness.pointer(_wheel(const Offset(100, 50), const Offset(10, 0)));
      dispatcher.advance(const Duration(seconds: 1));
      expect(controller.offset, 400);

      harness.pointer(_wheel(const Offset(100, 50), const Offset(-10, 0)));
      dispatcher.advance(const Duration(seconds: 1));
      expect(controller.page, 1);
      harness.dispose();
    });

    test('a notch past the last page is left to the view around it', () {
      final ScrollPosition outer = ScrollPosition(axis: Axis.horizontal);
      final PageController controller = PageController(initialPage: 2);
      final harness = _Harness(
        SingleChildScrollView(
          controller: outer,
          axis: ScrollAxis.horizontal,
          scrollbar: ScrollbarVisibility.never,
          child: Row(
            children: <Widget>[
              SizedBox(width: 200, child: _pages(controller: controller)),
              const SizedBox(width: 300),
            ],
          ),
        ),
      );
      harness.pointer(_wheel(const Offset(100, 50), const Offset(30, 0)));
      expect(controller.offset, 400);
      expect(outer.pixels, 30);
      harness.dispose();
    });

    test('with focus, the arrows and Page keys turn pages', () {
      final PageController controller = PageController();
      final harness = _Harness(_pages(controller: controller, count: 4));

      expect(harness.key(logicalKeyArrowRight), isFalse, reason: 'unfocused');
      harness.pointer(_mouseDown(const Offset(100, 50)));
      harness.pointer(_mouseUp(const Offset(100, 50)));

      expect(harness.key(logicalKeyArrowRight), isTrue);
      expect(controller.offset, 200, reason: 'no clock: the turn jumps');
      harness.key(logicalKeyPageDown);
      expect(controller.page, 2);
      harness.key(logicalKeyArrowLeft);
      expect(controller.page, 1);
      harness.key(logicalKeyEnd);
      expect(controller.page, 3);
      expect(harness.key(logicalKeyArrowRight), isFalse, reason: 'last page');
      harness.key(logicalKeyHome);
      expect(controller.page, 0);
      expect(harness.key(logicalKeyArrowDown), isFalse, reason: 'other axis');
      harness.dispose();
    });

    test('a reversed view turns forward with the left arrow', () {
      final PageController controller = PageController();
      final harness = _Harness(
        _pages(controller: controller, reverse: true),
      );
      harness.pointer(_mouseDown(const Offset(100, 50)));
      harness.pointer(_mouseUp(const Offset(100, 50)));
      harness.key(logicalKeyArrowLeft);
      expect(controller.page, 1);
      expect(harness.pageLeft(1), 0);
      harness.dispose();
    });
  });

  group('PageController', () {
    test('jumpToPage, animateToPage, nextPage and previousPage', () async {
      final ManualDispatcher dispatcher = ManualDispatcher();
      final PageController controller = PageController();
      final List<int> changes = <int>[];
      final harness = _Harness(
        _pages(
          controller: controller,
          dispatcher: dispatcher,
          count: 5,
          onPageChanged: changes.add,
        ),
      );

      controller.jumpToPage(3);
      expect(controller.offset, 600);

      final Future<void> back = controller.animateToPage(
        1,
        duration: const Duration(milliseconds: 160),
        curve: Curves.linear,
      );
      dispatcher.advance(const Duration(milliseconds: 80));
      expect(controller.page, closeTo(2, 1e-9), reason: 'halfway, 5 frames');
      dispatcher.advance(const Duration(milliseconds: 200));
      await back;
      expect(controller.page, 1);

      final Future<void> next = controller.nextPage(
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeInOut,
      );
      dispatcher.advance(const Duration(milliseconds: 200));
      await next;
      expect(controller.page, 2);

      final Future<void> previous = controller.previousPage(
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeInOut,
      );
      dispatcher.advance(const Duration(milliseconds: 200));
      await previous;
      expect(controller.page, 1);
      expect(changes, <int>[3, 2, 1, 2, 1]);
      harness.dispose();
    });

    test('rejects a viewportFraction that is not a fraction', () {
      expect(() => PageController(viewportFraction: 0), throwsArgumentError);
      expect(() => PageController(initialPage: -1), throwsArgumentError);
    });

    test('the page physics springs to the nearest page', () {
      final PageController controller = PageController();
      final harness = _Harness(_pages(controller: controller));
      final ScrollPosition position = controller.position;
      position.jumpTo(230);
      const PageScrollPhysics physics = PageScrollPhysics(
        parent: ClampingScrollPhysics(),
      );
      final Simulation? back = physics.createBallisticSimulation(position, 0);
      expect(back, isA<SpringSimulation>());
      expect((back! as SpringSimulation).end, 200);
      final Simulation? on = physics.createBallisticSimulation(position, 500);
      expect((on! as SpringSimulation).end, 400);
      expect(physics.allowImplicitScrolling, isFalse);
      harness.dispose();
    });
  });
}

Widget _pages({
  PageController? controller,
  UiDispatcher? dispatcher,
  int count = 3,
  Axis direction = Axis.horizontal,
  bool reverse = false,
  bool snapping = true,
  ScrollPhysics? physics,
  void Function(int)? onPageChanged,
}) =>
    PageView(
      controller: controller,
      dispatcher: dispatcher,
      scrollDirection: direction,
      reverse: reverse,
      pageSnapping: snapping,
      physics: physics,
      onPageChanged: onPageChanged,
      children: <Widget>[
        for (int i = 0; i < count; i++) SizedBox(key: ValueKey<int>(i)),
      ],
    );

final class _Harness {
  _Harness(Widget widget, {Size size = const Size(200, 100)}) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(rootConstraints: BoxConstraints.tight(size)),
    );
    mount(widget);
  }

  late final BuildOwner owner;
  int _clock = 1000;

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

  /// A horizontal drag slow enough that it ends with no fling: the finger
  /// rests before it lifts.
  void slowDrag({required double from, required double to}) {
    final int start = _clock;
    pointer(_down(Offset(from, 50), millis: start));
    const int steps = 6;
    for (int i = 1; i <= steps; i++) {
      pointer(_move(
        Offset(from + (to - from) * i / steps, 50),
        millis: start + i * 100,
      ));
    }
    pointer(_up(Offset(to, 50), millis: start + steps * 100 + 900));
    _clock = start + 5000;
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

  RenderBox _page(int index) => find<RenderSliverList>().childAtIndex(index)!;

  /// Where page [index]'s left edge is inside the page view.
  double pageLeft(int index) =>
      _page(index).globalOffset.dx -
      find<RenderCustomScrollViewport>().globalOffset.dx;

  double pageWidth(int index) => _page(index).size.width;

  void dispose() => owner.dispose();
}

const NativeWindowId _window = NativeWindowId(1);

PointerDownEvent _down(Offset at, {int millis = 0}) => PointerDownEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration(milliseconds: millis),
      pointerId: 0,
      kind: PointerKind.touch,
      logicalPosition: at,
      button: PointerButton.primary,
    );

PointerMoveEvent _move(Offset at, {int millis = 0}) => PointerMoveEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration(milliseconds: millis),
      pointerId: 0,
      kind: PointerKind.touch,
      logicalPosition: at,
    );

PointerUpEvent _up(Offset at, {int millis = 0}) => PointerUpEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration(milliseconds: millis),
      pointerId: 0,
      kind: PointerKind.touch,
      logicalPosition: at,
      button: PointerButton.primary,
    );

PointerDownEvent _mouseDown(Offset at) => PointerDownEvent(
      windowId: _window,
      generation: 1,
      timestamp: const Duration(seconds: 100),
      pointerId: 1,
      kind: PointerKind.mouse,
      logicalPosition: at,
      button: PointerButton.primary,
    );

PointerUpEvent _mouseUp(Offset at) => PointerUpEvent(
      windowId: _window,
      generation: 1,
      timestamp: const Duration(seconds: 100),
      pointerId: 1,
      kind: PointerKind.mouse,
      logicalPosition: at,
      button: PointerButton.primary,
    );

PointerScrollEvent _wheel(Offset at, Offset delta) => PointerScrollEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 2,
      kind: PointerKind.mouse,
      logicalPosition: at,
      scrollDelta: delta,
      scrollDeltaUnit: ScrollDeltaUnit.pixels,
    );
