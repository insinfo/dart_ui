/// Flutter's `ScrollController` over the framework's `ScrollPosition`.
///
/// What a migrated app does with a controller - read the offset, jump,
/// animate, listen for "near the end", share it, swap it - each checked to
/// the pixel on a virtual clock. And what the framework's own code has always
/// done - pass a `ScrollPosition` as `controller:` - still works beside it.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('ScrollController', () {
    test('attaches to a list, and starts it at initialScrollOffset', () {
      final ScrollController controller =
          ScrollController(initialScrollOffset: 200);
      expect(controller.hasClients, isFalse);
      expect(() => controller.position, throwsStateError);

      final harness = _Harness(_list(controller: controller));

      expect(controller.hasClients, isTrue);
      expect(controller.positions, hasLength(1));
      expect(controller.offset, 200);
      expect(controller.position.maxScrollExtent, 19900);
      expect(harness.realizedIndices.first, 10, reason: '200px of 20px rows');
      expect(controller.position, same(harness.position));
      harness.dispose();
    });

    test('jumpTo moves the list and notifies the controller', () {
      final ScrollController controller = ScrollController();
      final harness = _Harness(_list(controller: controller));
      int notified = 0;
      controller.addListener(() => notified++);

      controller.jumpTo(400);
      harness.frame();

      expect(controller.offset, 400);
      expect(harness.realizedIndices.first, 20);
      expect(notified, greaterThan(0));
      harness.dispose();
    });

    test('a load-more listener reads extentAfter from the position', () {
      final ScrollController controller = ScrollController();
      final harness = _Harness(_list(controller: controller, count: 50));
      final List<double> remaining = <double>[];
      controller.addListener(() {
        remaining.add(controller.position.extentAfter);
      });

      controller.jumpTo(800);

      // 50 rows of 20px in a 100px viewport: 900px of range, 100 left.
      expect(remaining.last, 100);
      expect(controller.position.extentBefore, 800);
      expect(controller.position.extentInside, 100);
      expect(controller.position.viewportDimension, 100);
      expect(controller.position.minScrollExtent, 0);
      harness.dispose();
    });

    test('animateTo runs on the view\'s clock and completes at the target',
        () async {
      final ManualDispatcher dispatcher = ManualDispatcher();
      final ScrollController controller = ScrollController();
      final harness = _Harness(
        _list(controller: controller, dispatcher: dispatcher),
      );
      bool done = false;
      controller
          .animateTo(
            1000,
            duration: const Duration(milliseconds: 200),
            curve: Curves.linear,
          )
          .then((_) => done = true);

      // Six 16ms steps fit in 100ms: 96/200 of the way, exactly.
      dispatcher.advance(const Duration(milliseconds: 100));
      expect(controller.offset, 480);
      expect(controller.position.isScrolling, isTrue);
      await pumpEventQueue();
      expect(done, isFalse);

      dispatcher.advance(const Duration(milliseconds: 200));
      await pumpEventQueue();
      expect(controller.offset, 1000);
      expect(done, isTrue);
      expect(controller.position.isScrolling, isFalse);
      expect(dispatcher.pendingTimerCount, 0);
      harness.frame();
      expect(harness.realizedIndices.first, 50);
      harness.dispose();
    });

    test('animateTo clamps its target to the scroll range', () async {
      final ManualDispatcher dispatcher = ManualDispatcher();
      final ScrollController controller = ScrollController();
      final harness = _Harness(
        _list(controller: controller, dispatcher: dispatcher, count: 10),
      );
      final Future<void> done = controller.animateTo(
        5000,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      );
      dispatcher.advance(const Duration(milliseconds: 200));
      await done;
      expect(controller.offset, 100, reason: '10 rows of 20px in 100px');
      harness.dispose();
    });

    test('a drag interrupts animateTo, and its future still completes',
        () async {
      final ManualDispatcher dispatcher = ManualDispatcher();
      final ScrollController controller = ScrollController();
      final harness = _Harness(
        _list(controller: controller, dispatcher: dispatcher),
      );
      bool done = false;
      controller
          .animateTo(
            2000,
            duration: const Duration(seconds: 1),
            curve: Curves.linear,
          )
          .then((_) => done = true);
      dispatcher.advance(const Duration(milliseconds: 160));
      final double caught = controller.offset;
      expect(caught, 320);

      harness.pointer(_down(const Offset(10, 50)));
      harness.pointer(_move(const Offset(10, 30), millis: 10));
      dispatcher.advance(const Duration(seconds: 2));
      await pumpEventQueue();

      expect(done, isTrue);
      // The drag pulled 20px past the slop-free start: the animation did not
      // move the list any further once the finger was down.
      expect(controller.offset, lessThan(caught + 40));
      harness.dispose();
    });

    test('without a clock animateTo jumps', () async {
      final ScrollController controller = ScrollController();
      final harness = _Harness(_list(controller: controller));
      await controller.animateTo(
        300,
        duration: const Duration(milliseconds: 300),
        curve: Curves.ease,
      );
      expect(controller.offset, 300);
      harness.dispose();
    });

    test('a controller shared by two views has two positions', () {
      final ScrollController controller = ScrollController();
      final harness = _Harness(
        Row(
          children: <Widget>[
            Expanded(child: _list(controller: controller)),
            Expanded(child: _list(controller: controller)),
          ],
        ),
      );
      expect(controller.positions, hasLength(2));
      expect(() => controller.position, throwsStateError);
      controller.jumpTo(60);
      for (final ScrollPosition position in controller.positions) {
        expect(position.pixels, 60);
      }
      harness.dispose();
    });

    test('a view that goes away detaches, and onAttach/onDetach say so', () {
      final List<String> log = <String>[];
      final ScrollController controller = ScrollController(
        onAttach: (ScrollPosition position) => log.add('attach'),
        onDetach: (ScrollPosition position) => log.add('detach'),
      );
      final harness = _Harness(_list(controller: controller));
      expect(log, <String>['attach']);

      harness.mount(const SizedBox());
      expect(controller.hasClients, isFalse);
      expect(log, <String>['attach', 'detach']);
      harness.dispose();
    });

    test('swapping controllers moves the view to the new one', () {
      final ScrollController first = ScrollController();
      final ScrollController second = ScrollController(
        initialScrollOffset: 100,
      );
      final harness = _Harness(_list(controller: first));
      first.jumpTo(40);

      harness.mount(_list(controller: second));

      expect(first.hasClients, isFalse);
      expect(second.hasClients, isTrue);
      // As in Flutter, the new position absorbs the one it replaces: the
      // view stays where it was, and initialScrollOffset is for a view that
      // had no position before.
      expect(second.offset, 40);
      harness.dispose();
    });

    test('changing the axis keeps the offset (keepScrollOffset)', () {
      final ScrollController controller = ScrollController();
      final harness = _Harness(
        _list(controller: controller, axis: Axis.vertical),
        size: const Size(100, 100),
      );
      controller.jumpTo(240);

      harness.mount(_list(controller: controller, axis: Axis.horizontal));

      expect(controller.position.axis, Axis.horizontal);
      expect(controller.offset, 240);
      harness.dispose();
    });

    test('dispose stops listening to the positions', () {
      final ScrollController controller = ScrollController();
      final harness = _Harness(_list(controller: controller));
      final ScrollPosition position = controller.position;
      harness.mount(const SizedBox());
      controller.dispose();
      expect(() => position.jumpTo(10), returnsNormally);
      harness.dispose();
    });
  });

  group('the dart_ui ScrollPosition, as before', () {
    test('is still accepted as a controller, and its axis wins', () {
      final ScrollPosition position = ScrollPosition(axis: Axis.horizontal);
      final harness = _Harness(
        ListView.builder(
          controller: position,
          itemCount: 100,
          itemExtent: 20,
          scrollbar: ScrollbarVisibility.never,
          itemBuilder: (BuildContext context, int index) =>
              const SizedBox(width: 20),
        ),
      );
      expect(harness.position, same(position));
      expect(position.axis, Axis.horizontal);
      expect(position.maxScrollExtent, 1800);
      harness.dispose();
    });

    test('takes Flutter\'s void Function() listener and its own form', () {
      final ScrollPosition position = ScrollPosition(contentExtent: 1000);
      position.applyViewportGeometry(viewportExtent: 100, contentExtent: 1000);
      int flutter = 0;
      final List<double> own = <double>[];
      void flutterListener() => flutter++;
      position.addListener(flutterListener);
      position.addListener((ScrollPosition p) => own.add(p.pixels));

      position.jumpTo(50);
      expect(flutter, 1);
      expect(own, <double>[50]);

      position.removeListener(flutterListener);
      position.jumpTo(60);
      expect(flutter, 1);
      expect(() => position.addListener((int x) {}), throwsArgumentError);
    });

    test('is a ScrollMetrics, and a snapshot does not follow it', () {
      final ScrollPosition position = ScrollPosition();
      expect(position.hasContentDimensions, isFalse);
      position.applyViewportGeometry(viewportExtent: 100, contentExtent: 400);
      position.jumpTo(120);

      final ScrollMetrics snapshot = position.copyWith();
      position.jumpTo(10);

      expect(snapshot.pixels, 120);
      expect(snapshot.maxScrollExtent, 300);
      expect(snapshot.extentAfter, 180);
      expect(snapshot.axis, Axis.vertical);
      expect(snapshot.axisDirection, AxisDirection.down);
      expect(snapshot.outOfRange, isFalse);
      expect(position.pixels, 10);
    });

    test('a reversed view reports AxisDirection.up', () {
      final ScrollController controller = ScrollController();
      final harness = _Harness(
        ListView.builder(
          controller: controller,
          reverse: true,
          itemCount: 100,
          itemExtent: 20,
          scrollbar: ScrollbarVisibility.never,
          itemBuilder: (BuildContext context, int index) =>
              const SizedBox(height: 20),
        ),
      );
      expect(controller.position.axisDirection, AxisDirection.up);
      harness.dispose();
    });
  });

  group('scrollDirection', () {
    test('is the same value as axis on every scroll view', () {
      expect(
        ListView(scrollDirection: Axis.horizontal).axis,
        ScrollAxis.horizontal,
      );
      expect(
        const CustomScrollView(scrollDirection: Axis.horizontal).axis,
        ScrollAxis.horizontal,
      );
      expect(
        const SingleChildScrollView(scrollDirection: Axis.horizontal)
            .scrollDirection,
        Axis.horizontal,
      );
      expect(
        GridView.count(crossAxisCount: 2, scrollDirection: Axis.horizontal)
            .axis,
        Axis.horizontal,
      );
      // The name given wins over the default of the other.
      expect(
        ListView(axis: ScrollAxis.horizontal).scrollDirection,
        Axis.horizontal,
      );
    });

    test('a horizontal list scrolls under a horizontal wheel', () {
      final ScrollController controller = ScrollController();
      final harness = _Harness(
        ListView.builder(
          controller: controller,
          scrollDirection: Axis.horizontal,
          itemCount: 100,
          itemExtent: 20,
          scrollbar: ScrollbarVisibility.never,
          itemBuilder: (BuildContext context, int index) =>
              const SizedBox(width: 20),
        ),
      );
      harness.pointer(_wheel(const Offset(50, 50), const Offset(30, 0)));
      expect(controller.offset, 30);
      // A vertical notch is not this list's: nothing moves.
      harness.pointer(_wheel(const Offset(50, 50), const Offset(0, 30)));
      expect(controller.offset, 30);
      harness.dispose();
    });
  });
}

Widget _list({
  ScrollPositionSource? controller,
  UiDispatcher? dispatcher,
  int count = 1000,
  Axis axis = Axis.vertical,
}) =>
    ListView.builder(
      controller: controller,
      dispatcher: dispatcher,
      scrollDirection: axis,
      itemCount: count,
      itemExtent: 20,
      scrollbar: ScrollbarVisibility.never,
      itemBuilder: (BuildContext context, int index) =>
          const SizedBox(width: 20, height: 20),
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

  RenderVirtualList get list => find<RenderVirtualList>();

  ScrollPosition get position => find<RenderScrollGestures>().position;

  List<int> get realizedIndices {
    final RealizedRange range = list.range;
    return <int>[
      for (int i = 0; i < list.childCount; i++) range.firstRealized + i,
    ];
  }

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

PointerScrollEvent _wheel(Offset at, Offset delta) => PointerScrollEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
      scrollDelta: delta,
      scrollDeltaUnit: ScrollDeltaUnit.pixels,
    );
