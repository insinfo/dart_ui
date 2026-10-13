/// The scroll views with Flutter's parameters: `reverse`, `padding`,
/// `shrinkWrap`, `ListView.separated` and `GridView`'s constructors.
///
/// Each one is checked by where the items land, in pixels, because that is
/// what a migrated screen either gets right or visibly gets wrong.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('ListView', () {
    test('reverse starts at the bottom and grows upwards', () {
      final harness = _Harness(
        ListView.builder(
          reverse: true,
          itemCount: 100,
          itemExtent: 20,
          scrollbar: ScrollbarVisibility.never,
          itemBuilder: (BuildContext context, int index) =>
              SizedBox(key: ValueKey<int>(index), height: 20),
        ),
      );
      // Item 0's bottom edge is the viewport's bottom edge.
      expect(harness.topOf(0), 80);
      expect(harness.topOf(1), 60);

      // A notch that would scroll an ordinary list down is, here, a notch
      // towards offset zero, where the list already is.
      harness.pointer(_wheel(const Offset(50, 50), 20));
      expect(harness.topOf(0), 80);
      expect(harness.position.pixels, 0);
      harness.pointer(_wheel(const Offset(50, 50), -20));
      expect(harness.position.pixels, 20);
      // Item 0 went below the bottom edge and is no longer built.
      expect(harness.topOf(1), 80);
      harness.dispose();
    });

    test('padding scrolls with the items', () {
      final ScrollController controller = ScrollController();
      final harness = _Harness(
        ListView.builder(
          controller: controller,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 30),
          itemCount: 10,
          itemExtent: 20,
          scrollbar: ScrollbarVisibility.never,
          itemBuilder: (BuildContext context, int index) =>
              SizedBox(key: ValueKey<int>(index), height: 20),
        ),
      );
      expect(harness.topOf(0), 30);
      expect(harness.leftOf(0), 10);
      expect(harness.widthOf(0), 180);
      // 30 + 200 + 30 of content in a 100px viewport.
      expect(controller.position.maxScrollExtent, 160);
      controller.jumpTo(160);
      harness.frame();
      expect(harness.topOf(9) + 20, 70, reason: '30px of padding below');
      harness.dispose();
    });

    test('shrinkWrap sizes the list to its items inside a column', () {
      final harness = _Harness(
        Column(
          children: <Widget>[
            ListView.builder(
              shrinkWrap: true,
              itemCount: 3,
              itemExtent: 20,
              scrollbar: ScrollbarVisibility.never,
              itemBuilder: (BuildContext context, int index) =>
                  SizedBox(key: ValueKey<int>(index), height: 20),
            ),
            const SizedBox(key: ValueKey<String>('after'), height: 10),
          ],
        ),
      );
      expect(harness.find<RenderCustomScrollViewport>().size.height, 60);
      expect(harness.topOfKey(const ValueKey<String>('after')), 60);
      harness.dispose();
    });

    test('shrinkWrap still scrolls when the items do not fit', () {
      final harness = _Harness(
        ListView.builder(
          shrinkWrap: true,
          itemCount: 30,
          itemExtent: 20,
          scrollbar: ScrollbarVisibility.never,
          itemBuilder: (BuildContext context, int index) =>
              const SizedBox(height: 20),
        ),
      );
      expect(harness.find<RenderCustomScrollViewport>().size.height, 100);
      expect(harness.position.maxScrollExtent, 500);
      harness.dispose();
    });

    test('separated puts a separator between each two items', () {
      final List<String> built = <String>[];
      final harness = _Harness(
        ListView.separated(
          itemCount: 3,
          scrollbar: ScrollbarVisibility.never,
          itemBuilder: (BuildContext context, int index) {
            built.add('item $index');
            return const SizedBox(height: 20);
          },
          separatorBuilder: (BuildContext context, int index) {
            built.add('separator $index');
            return const SizedBox(height: 2);
          },
        ),
      );
      expect(built.toSet(), <String>{
        'item 0',
        'separator 0',
        'item 1',
        'separator 1',
        'item 2',
      });
      expect(harness.position.contentExtent, 64);
      harness.dispose();
    });

    test('a builder that returns null leaves an empty slot', () {
      final harness = _Harness(
        ListView.builder(
          itemCount: 3,
          itemExtent: 20,
          scrollbar: ScrollbarVisibility.never,
          itemBuilder: (BuildContext context, int index) =>
              index == 1 ? null : const SizedBox(height: 20),
        ),
      );
      expect(harness.position.contentExtent, 60);
      harness.dispose();
    });
  });

  group('CustomScrollView', () {
    test('shrinkWrap in a column takes the slivers\' extent', () {
      final harness = _Harness(
        Column(
          children: <Widget>[
            CustomScrollView(
              shrinkWrap: true,
              scrollbar: ScrollbarVisibility.never,
              slivers: <Widget>[
                const SliverToBoxAdapter(child: SizedBox(height: 15)),
                SliverFixedExtentList.builder(
                  itemExtent: 10,
                  itemCount: 4,
                  itemBuilder: (BuildContext context, int index) =>
                      const SizedBox(height: 10),
                ),
              ],
            ),
          ],
        ),
      );
      expect(harness.find<RenderCustomScrollViewport>().size.height, 55);
      expect(harness.position.maxScrollExtent, 0);
      harness.dispose();
    });
  });

  group('SingleChildScrollView', () {
    test('reverse shows the end of the child first', () {
      final harness = _Harness(
        const SingleChildScrollView(
          reverse: true,
          scrollbar: ScrollbarVisibility.never,
          child: SizedBox(key: ValueKey<String>('child'), height: 300),
        ),
      );
      expect(harness.topOfKey(const ValueKey<String>('child')), -200);
      harness.position.jumpTo(200);
      harness.frame();
      expect(harness.topOfKey(const ValueKey<String>('child')), 0);
      harness.dispose();
    });

    test('padding goes around the child, inside the scroll', () {
      final harness = _Harness(
        const SingleChildScrollView(
          padding: EdgeInsets.all(8),
          scrollbar: ScrollbarVisibility.never,
          child: SizedBox(key: ValueKey<String>('child'), height: 300),
        ),
      );
      expect(harness.topOfKey(const ValueKey<String>('child')), 8);
      expect(harness.position.maxScrollExtent, 216);
      harness.dispose();
    });

    test('along an unbounded axis it is as tall as its child', () {
      final harness = _Harness(
        const Column(
          children: <Widget>[
            SingleChildScrollView(
              scrollbar: ScrollbarVisibility.never,
              child: SizedBox(height: 40),
            ),
            SizedBox(key: ValueKey<String>('after'), height: 10),
          ],
        ),
      );
      expect(harness.topOfKey(const ValueKey<String>('after')), 40);
      harness.dispose();
    });
  });

  group('GridView', () {
    test('count lays out a fixed number of square columns', () {
      final harness = _Harness(
        GridView.count(
          crossAxisCount: 4,
          scrollbar: ScrollbarVisibility.never,
          children: <Widget>[
            for (int i = 0; i < 10; i++) SizedBox(key: ValueKey<int>(i)),
          ],
        ),
      );
      // 200px across four columns: 50px cells, square.
      expect(harness.leftOf(1), 50);
      expect(harness.topOf(4), 50);
      expect(harness.widthOf(0), 50);
      expect(harness.position.maxScrollExtent, 50, reason: '3 rows of 50');
      harness.dispose();
    });

    test('extent fits as many columns as the maximum allows', () {
      final harness = _Harness(
        GridView.extent(
          maxCrossAxisExtent: 70,
          childAspectRatio: 2,
          mainAxisSpacing: 4,
          scrollbar: ScrollbarVisibility.never,
          children: <Widget>[
            for (int i = 0; i < 10; i++) SizedBox(key: ValueKey<int>(i)),
          ],
        ),
      );
      // ceil(200 / 70) = 3 columns of 66.67px, half as tall, 4px apart.
      expect(harness.widthOf(0), closeTo(200 / 3, 1e-9));
      expect(harness.topOf(3), closeTo(200 / 3 / 2 + 4, 1e-9));
      harness.dispose();
    });

    test('builder with a delegate builds only the visible cells', () {
      final List<int> built = <int>[];
      final harness = _Harness(
        GridView.builder(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            childAspectRatio: 4,
          ),
          itemCount: 10000,
          padding: const EdgeInsets.all(10),
          scrollbar: ScrollbarVisibility.never,
          itemBuilder: (BuildContext context, int index) {
            built.add(index);
            return SizedBox(key: ValueKey<int>(index));
          },
        ),
      );
      // 90px cells, 22.5px rows, 10px of padding: four rows in 100px.
      expect(built.length, lessThanOrEqualTo(10));
      expect(harness.topOf(0), 10);
      expect(harness.leftOf(1), 100);
      harness.dispose();
    });

    test('the older crossAxisCount/rowExtent form still works', () {
      final harness = _Harness(
        GridView.builder(
          crossAxisCount: 4,
          rowExtent: 30,
          itemCount: 10,
          scrollbar: ScrollbarVisibility.never,
          itemBuilder: (BuildContext context, int index) =>
              SizedBox(key: ValueKey<int>(index)),
        ),
      );
      expect(harness.position.contentExtent, 90);
      expect(harness.leftOf(5), 50);
      harness.dispose();
    });

    test('a builder with neither form is an ArgumentError, not a crash', () {
      expect(
        () => const GridView.builder(itemCount: 1, itemBuilder: _none)
            .build(_FakeContext()),
        throwsArgumentError,
      );
    });
  });
}

Widget? _none(BuildContext context, int index) => null;

final class _FakeContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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

  ScrollPosition get position => find<RenderScrollGestures>().position;

  RenderBox _boxOf(Key key) {
    RenderBox? found;
    void walk(Element element) {
      if (found != null) return;
      if (element.widget.key == key) {
        Element? at = element;
        while (at != null && at is! RenderObjectElement) {
          Element? child;
          at.visitChildren((Element c) => child ??= c);
          at = child;
        }
        found = (at as RenderObjectElement?)?.renderObject;
        return;
      }
      element.visitChildren(walk);
    }

    walk(owner.rootElement!);
    if (found == null) throw StateError('no $key in the tree');
    return found!;
  }

  double topOfKey(Key key) => _boxOf(key).globalOffset.dy;

  double topOf(int index) => topOfKey(ValueKey<int>(index));

  double leftOf(int index) => _boxOf(ValueKey<int>(index)).globalOffset.dx;

  double widthOf(int index) => _boxOf(ValueKey<int>(index)).size.width;

  void dispose() => owner.dispose();
}

const NativeWindowId _window = NativeWindowId(1);

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
