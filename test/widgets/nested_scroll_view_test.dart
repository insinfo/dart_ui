/// `NestedScrollView`: the header collapses before the body scrolls, and the
/// body scrolls back to its top before the header expands.
///
/// The window is 200x200. The header is pinned, 60 tall shrinking to 20, so
/// the body is 180 tall and the outer view scrolls by 40.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('geometry', () {
    test('the body fills the viewport below the collapsed pinned header', () {
      final harness = _Harness(_view());
      expect(harness.outer.maxScrollExtent, 40);
      expect(harness.body.geometry.scrollExtent, 180);
      expect(harness.body.child!.size, const Size(200, 180));
      expect(harness.offsetOf(harness.body), 60);
      expect(harness.inner.viewportExtent, 180);

      harness.outer.jumpTo(40);
      harness.frame();
      expect(harness.header.geometry.paintExtent, 20,
          reason: 'pinned at its minimum');
      expect(harness.offsetOf(harness.body), 20);
      expect(harness.body.geometry.paintExtent, 180,
          reason: 'the rest of the viewport, nothing under the header');
      harness.dispose();
    });

    test('a scroll-away header leaves the whole viewport to the body', () {
      final harness = _Harness(_view(pinned: false));
      expect(harness.body.geometry.scrollExtent, 200);
      expect(harness.outer.maxScrollExtent, 60);
      harness.dispose();
    });
  });

  group('wheel', () {
    test('collapses the header before the list moves, then scrolls the list',
        () {
      final harness = _Harness(_view());
      harness.pointer(_wheel(const Offset(100, 150), 30));
      harness.frame();
      expect(harness.outer.pixels, 30);
      expect(harness.inner.pixels, 0, reason: 'the header goes first');

      harness.pointer(_wheel(const Offset(100, 150), 30));
      harness.frame();
      expect(harness.outer.pixels, 40, reason: 'collapsed');
      expect(harness.inner.pixels, 20, reason: 'the remainder');

      harness.pointer(_wheel(const Offset(100, 150), 100));
      harness.frame();
      expect(harness.outer.pixels, 40);
      expect(harness.inner.pixels, 120);
      harness.dispose();
    });

    test('scrolls the list to its top before expanding the header', () {
      final harness = _Harness(_view());
      harness.pointer(_wheel(const Offset(100, 150), 140));
      harness.frame();
      expect(harness.outer.pixels, 40);
      expect(harness.inner.pixels, 100);

      harness.pointer(_wheel(const Offset(100, 150), -80));
      harness.frame();
      expect(harness.inner.pixels, 20);
      expect(harness.outer.pixels, 40, reason: 'still collapsed');

      harness.pointer(_wheel(const Offset(100, 150), -50));
      harness.frame();
      expect(harness.inner.pixels, 0);
      expect(harness.outer.pixels, 10, reason: 'the remainder expands it');
      harness.dispose();
    });

    test('over the header, the same distribution', () {
      final harness = _Harness(_view());
      harness.pointer(_wheel(const Offset(100, 10), 70));
      harness.frame();
      expect(harness.outer.pixels, 40);
      expect(harness.inner.pixels, 30);
      harness.dispose();
    });

    test('floating headers come back before the list scrolls up', () {
      final harness =
          _Harness(_view(pinned: false, floating: true, float: true));
      harness.pointer(_wheel(const Offset(100, 150), 160));
      harness.frame();
      expect(harness.outer.pixels, 60);
      expect(harness.inner.pixels, 100);

      harness.pointer(_wheel(const Offset(100, 150), -30));
      harness.frame();
      expect(harness.outer.pixels, 30, reason: 'the header floats in first');
      expect(harness.inner.pixels, 100);
      expect(harness.header.geometry.paintExtent, 30);
      harness.dispose();
    });
  });

  group('drag', () {
    test('a drag up collapses the header, then moves the list', () {
      final harness = _Harness(_view());
      // A mouse crosses its slop at 4px: the first 8px move starts the drag,
      // and each later one moves the content by 8px.
      harness.pointer(_down(const Offset(100, 190)));
      for (int step = 1; step <= 7; step++) {
        harness.pointer(_move(Offset(100, 190 - step * 8), millis: step * 8));
        harness.frame();
      }
      expect(harness.outer.pixels, 40);
      expect(harness.inner.pixels, 8);

      // And back down: the list first, then the header.
      for (int step = 1; step <= 3; step++) {
        harness.pointer(
          _move(Offset(100, 134 + step * 8), millis: 56 + step * 8),
        );
        harness.frame();
      }
      expect(harness.inner.pixels, 0);
      expect(harness.outer.pixels, 24);
      harness.pointer(_up(const Offset(100, 158), millis: 300));
      harness.dispose();
    });

    test('a fling carries on into the list once the header is collapsed', () {
      final dispatcher = ManualDispatcher();
      final harness = _Harness(_view(dispatcher: dispatcher));
      // Sixteen pixels every eight milliseconds: 2000 px/s upwards, released
      // with the header 32px into its 40px collapse.
      harness.pointer(_down(const Offset(100, 190)));
      for (int step = 1; step <= 3; step++) {
        harness.pointer(_move(Offset(100, 190 - step * 16), millis: step * 8));
      }
      harness.pointer(_up(const Offset(100, 142), millis: 24));
      expect(harness.outer.pixels, 32);
      expect(harness.inner.pixels, 0);
      dispatcher.advance(const Duration(seconds: 5));
      harness.frame();
      expect(harness.outer.pixels, 40);
      expect(harness.inner.pixels, greaterThan(300));
      harness.dispose();
    });
  });

  group('keyboard', () {
    test('the arrow keys collapse the header, then scroll the list', () {
      final harness = _Harness(_view());
      harness.pointer(_down(const Offset(100, 150)));
      harness.pointer(_up(const Offset(100, 150)));
      harness.frame();
      harness.key(logicalKeyArrowDown);
      harness.frame();
      expect(harness.outer.pixels, 40);
      expect(harness.inner.pixels, 8);
      harness.dispose();
    });
  });

  group('innerBoxIsScrolled', () {
    test('flips when the body scrolls away from its top and back', () {
      final List<bool> seen = <bool>[];
      final harness = _Harness(_view(onHeaders: seen.add));
      expect(seen.last, isFalse);

      harness.pointer(_wheel(const Offset(100, 150), 40));
      harness.frame();
      expect(seen.last, isFalse, reason: 'only the header has moved');

      harness.pointer(_wheel(const Offset(100, 150), 10));
      harness.frame();
      expect(seen.last, isTrue);
      final int builds = seen.length;

      harness.pointer(_wheel(const Offset(100, 150), 10));
      harness.frame();
      expect(seen.length, builds, reason: 'no rebuild while it stays true');

      harness.pointer(_wheel(const Offset(100, 150), -30));
      harness.frame();
      expect(seen.last, isFalse);
      harness.dispose();
    });
  });

  group('laziness', () {
    test('a long inner list builds only the rows on screen', () {
      final Set<int> built = <int>{};
      final harness = _Harness(_view(itemCount: 100000, onBuild: built.add));
      // 180px of body at 20px a row: nine rows, plus the one whose top edge
      // touches the bottom of the body, which ListView counts as reached.
      expect(built, <int>{for (int i = 0; i <= 9; i++) i});

      built.clear();
      harness.pointer(_wheel(const Offset(100, 150), 40 + 20000));
      harness.frame();
      expect(harness.inner.pixels, 20000);
      expect(built, <int>{for (int i = 1000; i <= 1009; i++) i});
      harness.dispose();
    });
  });

  test('a disposed view releases the positions it coordinated', () {
    final ScrollPosition outer = ScrollPosition();
    final harness = _Harness(_view(controller: outer));
    final ScrollPosition inner = harness.inner;
    expect(outer.coordinator, isNotNull);
    expect(inner.coordinator, isNotNull);
    harness.mount(const SizedBox());
    expect(outer.coordinator, isNull);
    expect(inner.coordinator, isNull);
    harness.dispose();
  });
}

Widget _view({
  bool pinned = true,
  bool floating = false,
  bool float = false,
  int itemCount = 1000,
  ScrollPosition? controller,
  UiDispatcher? dispatcher,
  void Function(bool innerBoxIsScrolled)? onHeaders,
  void Function(int index)? onBuild,
}) =>
    NestedScrollView(
      controller: controller,
      floatHeaderSlivers: float,
      dispatcher: dispatcher,
      headerSliverBuilder: (BuildContext context, bool innerBoxIsScrolled) {
        onHeaders?.call(innerBoxIsScrolled);
        return <Widget>[
          SliverPersistentHeader(
            pinned: pinned,
            floating: floating,
            delegate: const _Header(),
          ),
        ];
      },
      body: ListView.builder(
        itemCount: itemCount,
        itemExtent: 20,
        scrollbar: ScrollbarVisibility.never,
        dispatcher: dispatcher,
        itemBuilder: (BuildContext context, int index) {
          onBuild?.call(index);
          return const SizedBox(height: 20);
        },
      ),
    );

final class _Header extends SliverPersistentHeaderDelegate {
  const _Header();

  @override
  double get minExtent => 20;

  @override
  double get maxExtent => 60;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) =>
      const SizedBox(
        height: double.infinity,
        child: ColoredBox(color: Color(0xFF3366CC)),
      );

  @override
  bool shouldRebuild(_Header oldDelegate) => false;
}

final class _Harness {
  _Harness(Widget widget, {Size size = const Size(200, 200)}) {
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

  bool pointer(PointerEvent event) => owner.dispatchPointerEvent(event);

  bool key(int logicalKey) => owner.dispatchKeyEvent(KeyDownEvent(
        windowId: _window,
        generation: 1,
        timestamp: Duration.zero,
        physicalKey: logicalKey,
        logicalKey: logicalKey,
      ));

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

  ScrollPosition get outer => find<RenderCustomScrollViewport>().position;

  RenderNestedScrollBody get body => find<RenderNestedScrollBody>();

  ScrollPosition get inner => body.coordinator.innerPositions.single;

  RenderSliverPersistentHeader get header =>
      find<RenderSliverPersistentHeader>();

  double offsetOf(RenderBox sliver) => sliver.offsetFromParent.dy;

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

PointerScrollEvent _wheel(Offset at, double delta) => PointerScrollEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
      scrollDelta: Offset(0, delta),
      scrollDeltaUnit: ScrollDeltaUnit.pixels,
    );
