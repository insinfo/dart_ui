/// Scroll views, end to end, on a virtual clock.
///
/// Every number here is a number: which indices were built, where they landed
/// in pixels, how far a fling travelled. Nothing reads a real clock - the
/// momentum runs on a [ManualDispatcher] whose time moves only when a test says
/// so - and nothing asserts "it scrolled a bit".
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('ListView.builder', () {
    test('a hundred thousand items build one screenful', () {
      final List<int> built = <int>[];
      final harness = _Harness(
        ListView.builder(
          itemCount: 100000,
          itemExtent: 20,
          scrollbar: ScrollbarVisibility.never,
          itemBuilder: (BuildContext context, int index) {
            built.add(index);
            return const SizedBox(height: 20);
          },
        ),
      );

      // The window is measured, not guessed: the first build runs against an
      // assumed viewport of eight items because no layout has happened yet,
      // and the second - the only other one - runs against the 100px the
      // viewport turned out to be. Fifteen calls for a hundred thousand items.
      expect(built.length, 15);
      expect(built.toSet(), <int>{0, 1, 2, 3, 4, 5, 6, 7, 8});
      expect(harness.list.childCount, 6, reason: '100px of 20px rows');
      expect(harness.position.contentExtent, 2000000);
      expect(harness.position.maxScrollExtent, 1999900);
      harness.dispose();
    });

    test('scrolling builds the newly visible items and nothing else', () {
      final List<int> built = <int>[];
      final harness = _Harness(
        ListView.builder(
          itemCount: 100000,
          itemExtent: 20,
          scrollbar: ScrollbarVisibility.never,
          itemBuilder: (BuildContext context, int index) {
            built.add(index);
            return const SizedBox(height: 20);
          },
        ),
      );

      built.clear();
      harness.position.jumpTo(400);
      harness.frame();

      expect(built, <int>[20, 21, 22, 23, 24, 25]);
      expect(harness.realizedIndices, <int>[20, 21, 22, 23, 24, 25]);
      // The window is at content offset 400 and the viewport starts there, so
      // the first row sits exactly at the top edge.
      expect(harness.itemOffsets, <double>[0, 20, 40, 60, 80, 100]);
      harness.dispose();
    });

    test('a declared cache extent realizes the declared margin', () {
      final harness = _Harness(
        ListView.builder(
          itemCount: 1000,
          itemExtent: 20,
          cacheExtent: 40,
          scrollbar: ScrollbarVisibility.never,
          itemBuilder: (BuildContext context, int index) =>
              const SizedBox(height: 20),
        ),
      );

      harness.position.jumpTo(200);
      harness.frame();

      // 200..300 is visible; 40px of cache each side adds two rows either end.
      expect(harness.realizedIndices.first, 8);
      expect(harness.realizedIndices.last, 17);
      // The leading cache is above the viewport, hence a negative offset.
      expect(harness.itemOffsets.first, -40);
      harness.dispose();
    });

    test('an item keeps its render object across a scroll', () {
      final harness = _Harness(
        ListView.builder(
          itemCount: 1000,
          itemExtent: 20,
          scrollbar: ScrollbarVisibility.never,
          itemBuilder: (BuildContext context, int index) =>
              const SizedBox(height: 20),
        ),
      );

      final RenderBox before = harness.list.childAt(2);
      harness.position.jumpTo(20);
      harness.frame();

      // Item 2 is now the second child rather than the third, and it is the
      // same render object: the key found it, it was not rebuilt.
      expect(harness.realizedIndices.first, 1);
      expect(harness.list.childAt(1), same(before));
      harness.dispose();
    });

    test('an eagerly built list still realizes only the window', () {
      final harness = _Harness(
        ListView(
          itemExtent: 20,
          scrollbar: ScrollbarVisibility.never,
          children: <Widget>[
            for (int i = 0; i < 500; i++) const SizedBox(height: 20),
          ],
        ),
      );

      expect(harness.list.childCount, 6);
      expect(harness.position.contentExtent, 10000);
      harness.dispose();
    });
  });

  group('variable item extents', () {
    test('items land where their measured extents put them', () {
      // Alternating 10 and 30, which no uniform arithmetic can reproduce.
      final harness = _Harness(
        ListView.builder(
          itemCount: 10,
          estimatedItemExtent: 20,
          scrollbar: ScrollbarVisibility.never,
          itemBuilder: (BuildContext context, int index) =>
              SizedBox(height: index.isEven ? 10 : 30),
        ),
      );

      expect(harness.realizedIndices, <int>[0, 1, 2, 3, 4, 5]);
      expect(harness.itemOffsets, <double>[0, 10, 40, 50, 80, 90]);
      // Items 0..8 were built once, on the assumed viewport of the first pass,
      // and their extents were kept. Item 9 has never existed, so it is still
      // the 20px estimate rather than its real 30 - which is exactly the
      // approximation a virtualized list of unmeasured items has to make.
      expect(harness.position.contentExtent, 190);

      // Scrolling to it measures it, and the total corrects itself: the list
      // gets 10px longer and the end moves 10px further away.
      harness.position.jumpTo(harness.position.maxScrollExtent);
      harness.frame();
      expect(harness.position.contentExtent, 200);
      expect(harness.position.maxScrollExtent, 100);

      harness.position.jumpTo(100);
      harness.frame();
      expect(harness.realizedIndices.last, 9);
      expect(harness.itemOffsets.last + 30, 100, reason: 'flush at the end');
      harness.dispose();
    });

    test('the window after a scroll comes from the measurements', () {
      final harness = _Harness(
        ListView.builder(
          itemCount: 10,
          estimatedItemExtent: 20,
          scrollbar: ScrollbarVisibility.never,
          itemBuilder: (BuildContext context, int index) =>
              SizedBox(height: index.isEven ? 10 : 30),
        ),
      );

      harness.position.jumpTo(50);
      harness.frame();

      // A uniform list of 20px rows would have started this window at item 2.
      // The real item at offset 50 is item 3, and it starts exactly there.
      expect(harness.realizedIndices.first, 3);
      expect(harness.itemOffsets.first, 0);
      harness.dispose();
    });
  });

  group('a list that shrinks', () {
    test('pulls the offset back to the new end instead of leaving a void', () {
      final harness = _Harness(_countedList(1000));
      harness.position.jumpTo(19900);
      harness.frame();
      expect(harness.position.pixels, 19900);
      expect(harness.position.atEnd, isTrue);

      harness.mount(_countedList(20));

      // 20 items of 20px in a 100px viewport is 300px of scrollable extent,
      // and the offset was nineteen thousand.
      expect(harness.position.maxScrollExtent, 300);
      expect(harness.position.pixels, 300);
      expect(harness.realizedIndices.last, 19, reason: 'the real last item');
      // The last row's bottom edge is the viewport's bottom edge: the list is
      // scrolled to the end, not into empty space past it.
      expect(harness.itemOffsets.last + 20, 100);
      harness.dispose();
    });
  });

  group('the wheel', () {
    test('scrolls in lines and in pixels', () {
      final harness = _Harness(_countedList(1000));

      harness.pointer(_wheel(const Offset(10, 50), 3, lines: true));
      expect(harness.position.pixels, 3 * defaultLineExtent);

      harness.pointer(_wheel(const Offset(10, 50), 25));
      expect(harness.position.pixels, 3 * defaultLineExtent + 25);
      harness.dispose();
    });

    test('only the innermost list under the cursor consumes a notch', () {
      final ScrollPosition inner = ScrollPosition();
      final ScrollPosition outer = ScrollPosition();
      final harness = _Harness(
        SingleChildScrollView(
          controller: outer,
          scrollbar: ScrollbarVisibility.never,
          child: Column(
            children: <Widget>[
              SizedBox(
                height: 40,
                child: ListView.builder(
                  itemCount: 100,
                  itemExtent: 20,
                  controller: inner,
                  scrollbar: ScrollbarVisibility.never,
                  itemBuilder: (BuildContext context, int index) =>
                      const SizedBox(height: 20),
                ),
              ),
              const SizedBox(height: 400),
            ],
          ),
        ),
      );

      harness.pointer(_wheel(const Offset(10, 20), 30));

      expect(inner.pixels, 30, reason: 'the inner list took the whole notch');
      expect(outer.pixels, 0, reason: 'and the outer one saw none of it');
      harness.dispose();
    });

    test('an inner list at its end hands the remainder outwards', () {
      final ScrollPosition inner = ScrollPosition();
      final ScrollPosition outer = ScrollPosition();
      final harness = _Harness(
        SingleChildScrollView(
          controller: outer,
          scrollbar: ScrollbarVisibility.never,
          child: Column(
            children: <Widget>[
              SizedBox(
                height: 40,
                child: ListView.builder(
                  itemCount: 4,
                  itemExtent: 20,
                  controller: inner,
                  scrollbar: ScrollbarVisibility.never,
                  itemBuilder: (BuildContext context, int index) =>
                      const SizedBox(height: 20),
                ),
              ),
              const SizedBox(height: 400),
            ],
          ),
        ),
      );

      // 80px of content in a 40px window: the inner list can move 40px.
      expect(inner.maxScrollExtent, 40);
      harness.pointer(_wheel(const Offset(10, 20), 100));

      expect(inner.pixels, 40, reason: 'the inner list is at its end');
      expect(outer.pixels, 60, reason: 'and the leftover 60 went outwards');
      harness.dispose();
    });
  });

  group('drag and fling', () {
    test('mouse drag can be reserved for selection without disabling wheel',
        () {
      final harness = _Harness(ListView.builder(
        itemCount: 100,
        itemExtent: 20,
        mouseDragEnabled: false,
        scrollbar: ScrollbarVisibility.never,
        itemBuilder: (BuildContext context, int index) =>
            const SizedBox(height: 20),
      ));

      harness.pointer(_down(const Offset(10, 90)));
      harness.pointer(_move(const Offset(10, 30), millis: 20));
      harness.pointer(_up(const Offset(10, 30), millis: 30));
      expect(harness.position.pixels, 0);

      harness.pointer(_wheel(const Offset(10, 50), 40));
      expect(harness.position.pixels, 40);
      harness.dispose();
    });

    test('a drag moves the content by the distance dragged past the slop', () {
      final harness = _Harness(_countedList(1000));

      // A mouse crosses its slop at 4px, so the first 8px move starts the drag
      // and the four after it are what moves the list.
      harness.pointer(_down(const Offset(10, 90)));
      for (int step = 1; step <= 5; step++) {
        harness.pointer(
          _move(Offset(10, 90 - step * 8), millis: step * 8),
        );
      }

      expect(harness.position.pixels, 32, reason: 'four moves of 8px');
      harness.dispose();
    });

    test('a fling at a known velocity travels the expected distance', () {
      final dispatcher = ManualDispatcher();
      final harness = _Harness(_countedList(100000, dispatcher: dispatcher));

      // Eight pixels every eight milliseconds is exactly 1000 px/s upwards.
      harness.pointer(_down(const Offset(10, 90)));
      for (int step = 1; step <= 6; step++) {
        harness.pointer(_move(Offset(10, 90 - step * 8), millis: step * 8));
      }
      final double atRelease = harness.position.pixels;
      harness.pointer(_up(const Offset(10, 34), millis: 56));

      // The velocity reached ScrollPosition.fling, which is the thing that had
      // never happened before: the tracker's least-squares fit recovers the
      // 1000 px/s exactly, and the sign is flipped because dragging a finger
      // up scrolls a list down.
      expect(harness.position.velocity, closeTo(1000, 1));
      expect(harness.momentum.isRunning, isTrue);

      dispatcher.advance(const Duration(seconds: 5));

      // 16ms steps at 0.94 friction, stopping below 8 px/s: 79 steps, and
      // 16 px * (1 - 0.94^79) / 0.06 = 264.66 px.
      expect(harness.momentum.ticks, 79);
      expect(harness.position.pixels - atRelease, closeTo(264.66, 0.5));
      expect(harness.momentum.isRunning, isFalse);
      expect(harness.position.velocity, 0);
      harness.dispose();
    });

    test('a fling stops dead at the end of the content', () {
      final dispatcher = ManualDispatcher();
      final harness = _Harness(_countedList(10, dispatcher: dispatcher));

      harness.pointer(_down(const Offset(10, 90)));
      for (int step = 1; step <= 6; step++) {
        harness.pointer(_move(Offset(10, 90 - step * 8), millis: step * 8));
      }
      harness.pointer(_up(const Offset(10, 34), millis: 56));
      dispatcher.advance(const Duration(seconds: 5));

      expect(harness.position.pixels, harness.position.maxScrollExtent);
      expect(dispatcher.pendingTimerCount, 0, reason: 'no timer left running');
      harness.dispose();
    });

    test('a new drag stops the fling it interrupts', () {
      final dispatcher = ManualDispatcher();
      final harness = _Harness(_countedList(100000, dispatcher: dispatcher));

      harness.pointer(_down(const Offset(10, 90)));
      for (int step = 1; step <= 6; step++) {
        harness.pointer(_move(Offset(10, 90 - step * 8), millis: step * 8));
      }
      harness.pointer(_up(const Offset(10, 34), millis: 56));
      dispatcher.advance(const Duration(milliseconds: 100));
      expect(harness.momentum.isRunning, isTrue);
      final double caught = harness.position.pixels;

      harness.pointer(_down(const Offset(10, 90), millis: 200));
      harness.pointer(_move(const Offset(10, 82), millis: 208));
      dispatcher.advance(const Duration(seconds: 5));

      expect(harness.momentum.isRunning, isFalse);
      expect(harness.position.pixels, caught, reason: 'the finger caught it');
      harness.dispose();
    });
  });

  group('SingleChildScrollView', () {
    test('translates a child taller than its viewport', () {
      final ScrollPosition position = ScrollPosition();
      final harness = _Harness(
        SingleChildScrollView(
          controller: position,
          scrollbar: ScrollbarVisibility.never,
          child: const SizedBox(height: 400),
        ),
      );

      expect(position.contentExtent, 400);
      expect(position.maxScrollExtent, 300);

      position.jumpTo(120);
      harness.frame();

      final RenderViewport viewport = harness.find<RenderViewport>();
      expect(viewport.child!.parentData!.offset, const Offset(0, -120));
      harness.dispose();
    });

    test('does not scroll a child that fits', () {
      final ScrollPosition position = ScrollPosition();
      final harness = _Harness(
        SingleChildScrollView(
          controller: position,
          scrollbar: ScrollbarVisibility.never,
          child: const SizedBox(height: 40),
        ),
      );

      harness.pointer(_wheel(const Offset(10, 50), 100));

      expect(position.canScroll, isFalse);
      expect(position.pixels, 0);
      harness.dispose();
    });
  });

  group('GridView.builder', () {
    test('virtualizes by row and pads the last one', () {
      final List<int> built = <int>[];
      final harness = _Harness(
        GridView.builder(
          itemCount: 10003,
          crossAxisCount: 4,
          rowExtent: 50,
          scrollbar: ScrollbarVisibility.never,
          itemBuilder: (BuildContext context, int index) {
            built.add(index);
            return const SizedBox();
          },
        ),
      );

      // 10003 items in rows of four is 2501 rows; two rows fit in 100px.
      expect(harness.position.contentExtent, 2501 * 50);
      // Two rows fill the 100px viewport, and the third begins exactly at its
      // bottom edge - the realized window is inclusive of that boundary item.
      expect(harness.list.childCount, 3);
      expect(built.toSet().length, lessThan(40));
      expect(built.where((int index) => index >= 10003), isEmpty);
      harness.dispose();
    });
  });
}

/// A list of [count] fixed-height rows with no scrollbar in the way.
Widget _countedList(int count, {UiDispatcher? dispatcher}) => ListView.builder(
      itemCount: count,
      itemExtent: 20,
      dispatcher: dispatcher,
      scrollbar: ScrollbarVisibility.never,
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
  DisplayList display = DisplayList();

  void mount(Widget widget) {
    owner.updateRoot(widget);
    frame();
  }

  /// Builds and lays out until nothing more is scheduled.
  ///
  /// More than one pass is normal and is the design: a virtualized list cannot
  /// know its viewport until it has been laid out, and cannot know an item's
  /// extent until that item exists.
  void frame({int maxPasses = 12}) {
    for (int pass = 0; pass < maxPasses; pass++) {
      if (owner.hasScheduledBuilds) owner.buildScope();
      display = DisplayList();
      owner.pipelineOwner.drawFrame(display);
      if (!owner.hasScheduledBuilds) return;
    }
    throw StateError('the scroll view never settled');
  }

  bool pointer(PointerEvent event) => owner.dispatchPointerEvent(event);

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

  ScrollMomentum get momentum => find<RenderScrollGestures>().momentum!;

  List<int> get realizedIndices {
    final RealizedRange range = list.range;
    return <int>[
      for (int i = 0; i < list.childCount; i++) range.firstRealized + i,
    ];
  }

  List<double> get itemOffsets => <double>[
        for (int i = 0; i < list.childCount; i++)
          list.childAt(i).parentData!.offset.dy,
      ];

  void dispose() => owner.dispose();
}

const NativeWindowId _window = NativeWindowId(1);

PointerDownEvent _down(Offset at, {int millis = 0}) => PointerDownEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration(milliseconds: millis),
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
      button: PointerButton.primary,
    );

PointerMoveEvent _move(Offset at, {int millis = 0}) => PointerMoveEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration(milliseconds: millis),
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
    );

PointerUpEvent _up(Offset at, {int millis = 0}) => PointerUpEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration(milliseconds: millis),
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
      button: PointerButton.primary,
    );

PointerScrollEvent _wheel(Offset at, double delta, {bool lines = false}) =>
    PointerScrollEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
      scrollDelta: Offset(0, delta),
      scrollDeltaUnit: lines ? ScrollDeltaUnit.lines : ScrollDeltaUnit.pixels,
    );
