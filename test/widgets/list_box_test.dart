import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('ListVirtualization', () {
    test('uniform extents answer offsets and indices in constant time', () {
      final virtualization = ListVirtualization(
        itemCount: 10000,
        estimatedExtent: 20,
      );

      expect(virtualization.totalExtent, 200000);
      expect(virtualization.offsetOf(500), 10000);
      expect(virtualization.indexAt(10005), 500);
      expect(virtualization.extentOf(0), 20);
    });

    test('the realized window is the visible one plus the cache', () {
      final virtualization = ListVirtualization(
        itemCount: 10000,
        estimatedExtent: 20,
        cacheExtent: 40,
      );

      final RealizedRange range = virtualization.rangeFor(
        scrollOffset: 1000,
        viewportExtent: 100,
      );

      expect(range.firstVisible, 50);
      expect(range.lastVisible, 55);
      expect(range.firstRealized, 48, reason: 'two items of leading cache');
      expect(range.lastRealized, 57, reason: 'two items of trailing cache');
      expect(range.leadingExtent, 960);
      expect(range.realizedCount, 10);
    });

    test('the cache is clipped at the ends rather than going negative', () {
      final virtualization = ListVirtualization(
        itemCount: 100,
        estimatedExtent: 20,
        cacheExtent: 200,
      );

      final RealizedRange top = virtualization.rangeFor(
        scrollOffset: 0,
        viewportExtent: 100,
      );
      expect(top.firstRealized, 0);
      expect(top.leadingExtent, 0);

      final RealizedRange bottom = virtualization.rangeFor(
        scrollOffset: virtualization.totalExtent,
        viewportExtent: 100,
      );
      expect(bottom.lastRealized, 99);
    });

    test('an empty list realizes nothing', () {
      final virtualization =
          ListVirtualization(itemCount: 0, estimatedExtent: 20);

      final RealizedRange range = virtualization.rangeFor(
        scrollOffset: 0,
        viewportExtent: 100,
      );
      expect(range.realizedCount, 0);
      expect(virtualization.totalExtent, 0);
    });

    test('variable extents are indexed by prefix sums', () {
      final virtualization = ListVirtualization(
        itemCount: 4,
        estimatedExtent: 10,
        extents: <double>[10, 40, 5, 25],
      );

      expect(virtualization.hasVariableExtents, isTrue);
      expect(virtualization.totalExtent, 80);
      expect(virtualization.offsetOf(2), 50);
      expect(virtualization.extentOf(1), 40);
      expect(virtualization.indexAt(0), 0);
      expect(virtualization.indexAt(49), 1);
      expect(virtualization.indexAt(52), 2);
      expect(virtualization.indexAt(60), 3);
    });

    test('an extent list of the wrong length is refused', () {
      expect(
        () => ListVirtualization(
          itemCount: 3,
          estimatedExtent: 10,
          extents: <double>[10, 20],
        ),
        throwsArgumentError,
      );
    });

    test('revealing scrolls by exactly one item, not to the centre', () {
      final virtualization = ListVirtualization(
        itemCount: 1000,
        estimatedExtent: 20,
      );

      // Item 6 starts at 120 and ends at 140; the viewport shows 0..100.
      expect(
        virtualization.scrollToReveal(6, scrollOffset: 0, viewportExtent: 100),
        40,
      );
      expect(
        virtualization.scrollToReveal(2, scrollOffset: 0, viewportExtent: 100),
        isNull,
        reason: 'already visible',
      );
      expect(
        virtualization.scrollToReveal(1, scrollOffset: 60, viewportExtent: 100),
        20,
        reason: 'scrolling back shows the top of the item',
      );
    });
  });

  group('ListBox in a tree', () {
    test('a huge list realizes a bounded window of render objects', () {
      final harness = _ListHarness(itemCount: 100000);
      harness.frame();

      final RenderListBox list = harness.list;
      expect(list.virtualization.itemCount, 100000);
      expect(list.childCount, lessThan(20));
      expect(list.childCount, greaterThan(3));
      harness.dispose();
    });

    test('an item keeps its element across a scroll, thanks to its key', () {
      final harness = _ListHarness(itemCount: 1000);
      harness.frame();

      final RenderListItem before = harness.itemWithIndex(5);
      harness.scroll.jumpTo(20);
      harness.frame();
      final RenderListItem after = harness.itemWithIndex(5);

      // Same render object: item 5 moved by one row, it was not rebuilt.
      expect(after, same(before));
      harness.dispose();
    });

    test('scrolling far away recycles every realized item', () {
      final harness = _ListHarness(itemCount: 1000);
      harness.frame();
      final Set<int> before = harness.realizedIndices;

      harness.scroll.jumpTo(10000);
      harness.frame();

      expect(harness.realizedIndices.intersection(before), isEmpty);
      harness.dispose();
    });

    test('the scroll position describes the whole list, not the window', () {
      final harness = _ListHarness(itemCount: 1000);
      harness.frame();

      // The row height is the theme's now rather than a private 20: naming it
      // here keeps the assertion exact without freezing a copy of the density
      // scale into the test.
      expect(
        harness.scroll.contentExtent,
        1000 * ThemeData.neutralLight.effectiveRowHeight,
      );
      expect(harness.scroll.canScroll, isTrue);
      harness.dispose();
    });

    test('row content reserves equal padding on both horizontal edges', () {
      final harness = _ListHarness(itemCount: 4);
      harness.frame();

      final RenderListItem row = harness.itemWithIndex(0);
      final RenderBox content = row.child!;
      final double padding = ThemeData.neutralLight.effectiveControlPadding;

      expect(content.parentData!.offset.dx, padding);
      expect(content.size.width, row.size.width - padding * 2);
      expect(
        content.parentData!.offset.dx + content.size.width,
        lessThanOrEqualTo(row.size.width - padding),
      );
      harness.dispose();
    });

    test('a wheel event scrolls the list', () {
      final harness = _ListHarness(itemCount: 1000);
      harness.frame();

      harness.owner.dispatchPointerEvent(const PointerScrollEvent(
        windowId: NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: Offset(10, 10),
        scrollDelta: Offset(0, 3),
        scrollDeltaUnit: ScrollDeltaUnit.lines,
      ));

      expect(harness.scroll.pixels, 3 * defaultLineExtent);
      harness.dispose();
    });

    test('clicking a partially visible row reveals the whole selection', () {
      final harness = _ListHarness(itemCount: 1000);
      harness.frame();
      final double extent = ThemeData.neutralLight.effectiveRowHeight;
      final int partialIndex = (100 / extent).floor();

      harness.list.handlePointerEvent(PointerDownEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        pointerId: 1,
        kind: PointerKind.mouse,
        logicalPosition: Offset(10, partialIndex * extent + 1),
        button: PointerButton.primary,
      ));
      harness.frame();

      expect(harness.selected, partialIndex);
      expect(harness.scroll.pixels, greaterThan(0));
      expect(
        (partialIndex + 1) * extent,
        lessThanOrEqualTo(harness.scroll.pixels + 100),
      );
      harness.dispose();
    });

    test('arrow keys select and keep the selection visible', () {
      final harness = _ListHarness(itemCount: 1000);
      harness.frame();

      for (int i = 0; i < 12; i++) {
        harness.list.handleKeyEvent(_key(logicalKeyArrowDown));
        harness.frame();
      }

      expect(harness.selected, 12);
      // The viewport is 100 px and rows are 20 px, so item 12 is below the
      // fold until the list scrolls to it.
      expect(harness.scroll.pixels, greaterThan(0));
      harness.dispose();
    });

    test('End jumps to the last item and Home back to the first', () {
      final harness = _ListHarness(itemCount: 1000);
      harness.frame();

      harness.list.handleKeyEvent(_key(logicalKeyEnd));
      harness.frame();
      expect(harness.selected, 999);
      expect(harness.scroll.atEnd, isTrue);

      harness.list.handleKeyEvent(_key(logicalKeyHome));
      harness.frame();
      expect(harness.selected, 0);
      expect(harness.scroll.pixels, 0);
      harness.dispose();
    });
  });
}

final class _ListHarness {
  _ListHarness({required this.itemCount}) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(160, 100)),
      ),
    );
    _mount();
  }

  final int itemCount;
  final ScrollPosition scroll = ScrollPosition();
  late final BuildOwner owner;
  int selected = 0;

  void _mount() => owner.updateRoot(ListBox(
        itemCount: itemCount,
        controller: scroll,
        selectedIndex: selected,
        onSelected: (int index) => selected = index,
        itemBuilder: (BuildContext context, int index) => Text('ITEM $index'),
      ));

  void frame({int maxPasses = 8}) {
    for (int pass = 0; pass < maxPasses; pass++) {
      _mount();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
    throw StateError('the list never settled');
  }

  RenderListBox get list {
    RenderListBox? found;
    void walk(RenderBox node) {
      if (found != null) return;
      if (node is RenderListBox) {
        found = node;
        return;
      }
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found!;
  }

  Set<int> get realizedIndices => <int>{
        for (int i = 0; i < list.childCount; i++)
          (list.childAt(i) as RenderListItem).index,
      };

  RenderListItem itemWithIndex(int index) {
    for (int i = 0; i < list.childCount; i++) {
      final RenderListItem item = list.childAt(i) as RenderListItem;
      if (item.index == index) return item;
    }
    throw StateError('item $index is not realized');
  }

  void dispose() => owner.dispose();
}

KeyDownEvent _key(int logicalKey) => KeyDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      physicalKey: logicalKey,
      logicalKey: logicalKey,
    );
