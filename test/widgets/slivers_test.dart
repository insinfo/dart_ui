/// `CustomScrollView` and the slivers, as numbers.
///
/// Every assertion here is a pixel offset, an index or a count: where each
/// sliver's box sits after a scroll, which rows exist, how far a header has
/// shrunk. "It scrolled" is not an assertion this file makes.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('layout arithmetic', () {
    test('a box adapter followed by a fixed-extent list', () {
      final harness = _Harness(
        CustomScrollView(
          scrollbar: ScrollbarVisibility.never,
          slivers: <Widget>[
            const SliverToBoxAdapter(child: SizedBox(height: 50)),
            SliverFixedExtentList.builder(
              itemExtent: 20,
              itemCount: 100,
              itemBuilder: (BuildContext context, int index) =>
                  const SizedBox(),
            ),
          ],
        ),
      );

      final List<RenderSliver> slivers = harness.viewport.slivers;
      expect(harness.offsetOf(slivers[0]), 0);
      expect(slivers[0].geometry.paintExtent, 50);
      expect(harness.offsetOf(slivers[1]), 50);
      expect(slivers[1].geometry.paintExtent, 50);
      // 50px of list on screen: rows 0, 1 and 2 (which starts at 40).
      expect(harness.list.realizedIndices, <int>[0, 1, 2]);
      expect(harness.rowOffsets, <double>[0, 20, 40]);
      expect(harness.position.contentExtent, 2050);
      expect(harness.position.maxScrollExtent, 1950);

      harness.position.jumpTo(30);
      harness.frame();
      // The adapter has scrolled 30px into itself: its box is the 20px still
      // visible, and its child sits 30px above that box.
      expect(harness.offsetOf(slivers[0]), 0);
      expect(slivers[0].geometry.paintExtent, 20);
      expect(
        (slivers[0] as RenderSliverToBoxAdapter).child!.offsetFromParent.dy,
        -30,
      );
      expect(harness.offsetOf(slivers[1]), 20);
      expect(harness.list.realizedIndices, <int>[0, 1, 2, 3]);

      harness.position.jumpTo(1000);
      harness.frame();
      // 1000px is 50px of adapter and 950px of list: row 47 starts at 940,
      // so it is 10px above the top edge.
      expect(slivers[0].geometry.paintExtent, 0);
      expect(harness.offsetOf(slivers[1]), 0);
      expect(harness.list.realizedIndices.first, 47);
      expect(harness.rowOffsets.first, -10);
      harness.dispose();
    });

    test('padding insets the sliver on both axes and in scroll space', () {
      final harness = _Harness(
        CustomScrollView(
          scrollbar: ScrollbarVisibility.never,
          slivers: <Widget>[
            SliverPadding(
              padding: const EdgeInsets(10, 20, 15, 30),
              sliver: SliverFixedExtentList.builder(
                itemExtent: 20,
                itemCount: 3,
                itemBuilder: (BuildContext context, int index) =>
                    const SizedBox(),
              ),
            ),
          ],
        ),
      );

      final RenderSliverPadding padding = harness.find<RenderSliverPadding>();
      expect(padding.geometry.scrollExtent, 20 + 60 + 30);
      expect(harness.list.offsetFromParent, const Offset(10, 20));
      expect(harness.list.size.width, 200 - 25);
      expect(harness.list.childAtIndex(0)!.size, const Size(175, 20));
      expect(harness.position.maxScrollExtent, 10);

      harness.position.jumpTo(10);
      harness.frame();
      // Ten pixels of the twenty-pixel leading inset have scrolled away.
      expect(harness.list.offsetFromParent, const Offset(10, 10));
      harness.dispose();
    });

    test('fill-remaining with no scroll body takes what is left', () {
      final harness = _Harness(
        const CustomScrollView(
          scrollbar: ScrollbarVisibility.never,
          slivers: <Widget>[
            SliverToBoxAdapter(child: SizedBox(height: 30)),
            SliverFillRemaining(
              hasScrollBody: false,
              child: SizedBox(height: 10),
            ),
          ],
        ),
      );

      final RenderSliverFillRemaining fill =
          harness.find<RenderSliverFillRemaining>();
      expect(harness.offsetOf(fill), 30);
      expect(fill.child!.size, const Size(200, 70));
      expect(harness.position.maxScrollExtent, 0, reason: 'nothing to scroll');
      harness.dispose();
    });

    test('fill-remaining grows to a child taller than what is left', () {
      final harness = _Harness(
        const CustomScrollView(
          scrollbar: ScrollbarVisibility.never,
          slivers: <Widget>[
            SliverToBoxAdapter(child: SizedBox(height: 30)),
            SliverFillRemaining(
              hasScrollBody: false,
              child: SizedBox(height: 150),
            ),
          ],
        ),
      );

      final RenderSliverFillRemaining fill =
          harness.find<RenderSliverFillRemaining>();
      expect(fill.geometry.scrollExtent, 150);
      expect(harness.position.maxScrollExtent, 80);
      harness.dispose();
    });

    test('a reversed view starts at the bottom', () {
      final harness = _Harness(
        CustomScrollView(
          reverse: true,
          scrollbar: ScrollbarVisibility.never,
          slivers: <Widget>[
            SliverFixedExtentList.builder(
              itemExtent: 20,
              itemCount: 100,
              itemBuilder: (BuildContext context, int index) =>
                  const SizedBox(),
            ),
          ],
        ),
      );

      // Row 0 is the bottom row; row 4 is at the top edge.
      expect(harness.globalRowTop(0), 80);
      expect(harness.globalRowTop(4), 0);

      harness.position.jumpTo(10);
      harness.frame();
      expect(harness.globalRowTop(0), 90, reason: 'scrolled down by 10px');
      harness.dispose();
    });

    test('a horizontal view lays rows out left to right', () {
      final harness = _Harness(
        CustomScrollView(
          axis: ScrollAxis.horizontal,
          scrollbar: ScrollbarVisibility.never,
          slivers: <Widget>[
            SliverFixedExtentList.builder(
              itemExtent: 50,
              itemCount: 10,
              itemBuilder: (BuildContext context, int index) =>
                  const SizedBox(),
            ),
          ],
        ),
      );

      expect(harness.list.realizedIndices, <int>[0, 1, 2, 3]);
      expect(
          harness.list.childAtIndex(1)!.offsetFromParent, const Offset(50, 0));
      expect(harness.list.childAtIndex(1)!.size, const Size(50, 100));
      expect(harness.position.maxScrollExtent, 300);
      harness.dispose();
    });
  });

  group('grids', () {
    test('a fixed column count places every cell', () {
      final harness = _Harness(
        CustomScrollView(
          scrollbar: ScrollbarVisibility.never,
          slivers: <Widget>[
            SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                mainAxisExtent: 50,
                mainAxisSpacing: 10,
              ),
              itemCount: 30,
              itemBuilder: (BuildContext context, int index) =>
                  const SizedBox(),
            ),
          ],
        ),
      );

      final RenderSliverGrid grid = harness.find<RenderSliverGrid>();
      // Rows at 0 and 60 reach into the 100px viewport; the row at 120 does
      // not.
      expect(grid.realizedIndices, <int>[0, 1, 2, 3, 4, 5, 6, 7]);
      expect(grid.childAtIndex(5)!.offsetFromParent, const Offset(50, 60));
      expect(grid.childAtIndex(5)!.size, const Size(50, 50));
      // Eight rows, the last without trailing spacing.
      expect(grid.geometry.scrollExtent, 8 * 60 - 10);

      harness.position.jumpTo(130);
      harness.frame();
      expect(grid.realizedIndices.first, 8, reason: 'row 2 starts at 120');
      expect(grid.childAtIndex(8)!.offsetFromParent, const Offset(0, -10));
      harness.dispose();
    });

    test('a maximum cell extent rounds the column count up', () {
      final harness = _Harness(
        CustomScrollView(
          scrollbar: ScrollbarVisibility.never,
          slivers: <Widget>[
            SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 60,
                crossAxisSpacing: 0,
              ),
              itemCount: 12,
              itemBuilder: (BuildContext context, int index) =>
                  const SizedBox(),
            ),
          ],
        ),
      );

      final RenderSliverGrid grid = harness.find<RenderSliverGrid>();
      expect(grid.gridLayout!.crossAxisCount, 4);
      expect(grid.childAtIndex(3)!.size, const Size(50, 50));
      expect(grid.childAtIndex(3)!.offsetFromParent, const Offset(150, 0));
      expect(grid.childAtIndex(4)!.offsetFromParent, const Offset(0, 50));
      harness.dispose();
    });

    test('SliverGrid.count builds only the visible rows of its list', () {
      int built = 0;
      final harness = _Harness(
        CustomScrollView(
          scrollbar: ScrollbarVisibility.never,
          slivers: <Widget>[
            SliverGrid.count(
              crossAxisCount: 2,
              children: <Widget>[
                for (int i = 0; i < 1000; i++)
                  Builder(builder: (BuildContext context) {
                    built++;
                    return const SizedBox();
                  }),
              ],
            ),
          ],
        ),
      );

      // Two 100px columns, so 100px rows: one row in the viewport.
      expect(harness.find<RenderSliverGrid>().realizedIndices, <int>[0, 1]);
      expect(built, 2);
      harness.dispose();
    });
  });

  group('laziness', () {
    test('a hundred thousand rows realize one screenful', () {
      final List<int> built = <int>[];
      final harness = _Harness(
        CustomScrollView(
          scrollbar: ScrollbarVisibility.never,
          slivers: <Widget>[
            SliverList.builder(
              itemCount: 100000,
              itemBuilder: (BuildContext context, int index) {
                built.add(index);
                return const SizedBox(height: 25);
              },
            ),
          ],
        ),
      );

      // Rows are 25px against a 40px estimate: the first pass realizes the
      // three rows the estimate predicts, measures them, and extends to the
      // four that actually fill 100px. Nothing is built twice.
      expect(harness.list.realizedIndices, <int>[0, 1, 2, 3]);
      expect(built, <int>[0, 1, 2, 3]);
      expect(harness.element.itemBuildCount, 4);
      // The total is four measured rows plus 99996 estimated ones.
      expect(harness.position.contentExtent, 4 * 25 + 99996 * 40);

      built.clear();
      harness.position.jumpTo(2000000);
      harness.frame();
      expect(harness.list.realizedCount, lessThanOrEqualTo(6));
      expect(built.length, lessThanOrEqualTo(8));
      expect(harness.element.realizedIndices, harness.list.realizedIndices);
      harness.dispose();
    });

    test('a scroll by less than a row builds nothing', () {
      final harness = _Harness(
        CustomScrollView(
          scrollbar: ScrollbarVisibility.never,
          slivers: <Widget>[
            SliverFixedExtentList.builder(
              itemExtent: 20,
              itemCount: 1000,
              itemBuilder: (BuildContext context, int index) =>
                  const SizedBox(),
            ),
          ],
        ),
      );

      // At 25 rows 1..6 reach the viewport (row 6 starts at 120), and at 35
      // the same rows still do.
      harness.position.jumpTo(25);
      harness.frame();
      final int before = harness.element.itemBuildCount;
      final RenderBox row = harness.list.childAtIndex(3)!;
      harness.position.jumpTo(35);
      harness.frame();
      expect(harness.element.itemBuildCount, before);
      expect(harness.list.childAtIndex(3), same(row));
      harness.dispose();
    });

    test('a declared cache extent realizes the declared margin', () {
      final harness = _Harness(
        CustomScrollView(
          cacheExtent: 40,
          scrollbar: ScrollbarVisibility.never,
          slivers: <Widget>[
            SliverFixedExtentList.builder(
              itemExtent: 20,
              itemCount: 1000,
              itemBuilder: (BuildContext context, int index) =>
                  const SizedBox(),
            ),
          ],
        ),
      );

      harness.position.jumpTo(200);
      harness.frame();
      // 200..300 visible, 40px of cache either side: rows 8..16.
      expect(harness.list.realizedIndices.first, 8);
      expect(harness.list.realizedIndices.last, 16);
      expect(harness.rowOffsets.first, -40);
      harness.dispose();
    });

    test('a list that shrinks drops the rows past its new end', () {
      Widget list(int count) => CustomScrollView(
            scrollbar: ScrollbarVisibility.never,
            slivers: <Widget>[
              SliverFixedExtentList.builder(
                itemExtent: 20,
                itemCount: count,
                itemBuilder: (BuildContext context, int index) =>
                    const SizedBox(),
              ),
            ],
          );
      final harness = _Harness(list(1000));
      harness.position.jumpTo(19900);
      harness.frame();

      harness.mount(list(20));
      expect(harness.position.maxScrollExtent, 300);
      expect(harness.position.pixels, 300);
      expect(harness.list.realizedIndices.last, 19);
      harness.dispose();
    });
  });

  group('rebuilds', () {
    test('a new delegate rebuilds the realized rows and nothing else', () {
      final List<String> built = <String>[];
      Widget view(String tag, int count) => CustomScrollView(
            scrollbar: ScrollbarVisibility.never,
            slivers: <Widget>[
              SliverFixedExtentList.builder(
                itemExtent: 20,
                itemCount: count,
                itemBuilder: (BuildContext context, int index) {
                  built.add('$tag$index');
                  return const SizedBox();
                },
              ),
            ],
          );
      final harness = _Harness(view('a', 100));
      expect(built, <String>['a0', 'a1', 'a2', 'a3', 'a4']);
      final RenderBox kept = harness.list.childAtIndex(1)!;

      built.clear();
      harness.mount(view('b', 3));
      // The three rows that still exist are rebuilt from the new builder, in
      // place; the two past the new end are dropped without being built.
      expect(built, <String>['b0', 'b1', 'b2']);
      expect(harness.list.realizedIndices, <int>[0, 1, 2]);
      expect(harness.list.childAtIndex(1), same(kept));
      expect(harness.position.maxScrollExtent, 0);
      harness.dispose();
    });

    test('a header delegate that asks to rebuild is rebuilt', () {
      Widget view(Color color) => CustomScrollView(
            scrollbar: ScrollbarVisibility.never,
            slivers: <Widget>[
              SliverPersistentHeader(delegate: _Header(color: color)),
            ],
          );
      final harness = _Harness(view(const Color(0xFF000001)));
      final SliverPersistentHeaderElement element =
          harness.elementOf<SliverPersistentHeaderElement>();
      final int builds = element.buildCount;

      harness.mount(view(const Color(0xFF000001)));
      expect(element.buildCount, builds, reason: 'same colour, no rebuild');

      harness.mount(view(const Color(0xFF000002)));
      expect(element.buildCount, builds + 1);
      harness.dispose();
    });
  });

  group('variable row heights', () {
    test('rows land where their measured heights put them', () {
      final harness = _Harness(
        CustomScrollView(
          scrollbar: ScrollbarVisibility.never,
          slivers: <Widget>[
            SliverList.builder(
              itemCount: 10,
              estimatedItemExtent: 20,
              itemBuilder: (BuildContext context, int index) =>
                  SizedBox(height: index.isEven ? 10 : 30),
            ),
          ],
        ),
      );

      expect(harness.list.realizedIndices, <int>[0, 1, 2, 3, 4, 5]);
      expect(harness.rowOffsets, <double>[0, 10, 40, 50, 80, 90]);
      // Rows 6..9 are still the 20px estimate.
      expect(harness.position.contentExtent, 120 + 4 * 20);

      harness.position.jumpTo(harness.position.maxScrollExtent);
      harness.frame();
      harness.position.jumpTo(harness.position.maxScrollExtent);
      harness.frame();
      expect(harness.position.contentExtent, 200, reason: 'all measured');
      expect(harness.list.realizedIndices.last, 9);
      expect(
        harness.rowOffsets.last + 30,
        100,
        reason: 'the last row is flush with the bottom',
      );
      harness.dispose();
    });

    test('scrolling up into estimated rows keeps the visible row still', () {
      // Every row is 60px against a 20px estimate. Jumping far down lands in
      // rows that were never measured; scrolling back up measures the rows
      // above, which pushes everything below them three times further down
      // than estimated. Without a correction the screen would jump.
      final harness = _Harness(
        CustomScrollView(
          scrollbar: ScrollbarVisibility.never,
          slivers: <Widget>[
            SliverList.builder(
              itemCount: 1000,
              estimatedItemExtent: 20,
              itemBuilder: (BuildContext context, int index) =>
                  const SizedBox(height: 60),
            ),
          ],
        ),
      );

      harness.position.jumpTo(10000);
      harness.frame();
      final int anchor = harness.list.realizedIndices.first;
      final double anchorTop = harness.globalRowTop(anchor);
      expect(harness.viewport.lastLayoutCorrections, 0);

      // Scroll up by 30px: the row above the anchor comes into view and is
      // measured at 60 instead of 20.
      harness.position.applyDelta(-30);
      harness.frame();
      expect(harness.viewport.lastLayoutCorrections, greaterThan(0));
      expect(
        harness.globalRowTop(anchor),
        anchorTop + 30,
        reason: 'the anchor moved by the scroll and by nothing else',
      );
      harness.dispose();
    });
  });

  group('persistent headers', () {
    test('a pinned header shrinks to its minimum and stays', () {
      final harness = _Harness(
        CustomScrollView(
          scrollbar: ScrollbarVisibility.never,
          slivers: <Widget>[
            const SliverPersistentHeader(
              pinned: true,
              delegate: _Header(color: Color(0xFF336699)),
            ),
            SliverFixedExtentList.builder(
              itemExtent: 20,
              itemCount: 100,
              itemBuilder: (BuildContext context, int index) =>
                  const ColoredBox(color: Color(0xFFEEEEEE)),
            ),
          ],
        ),
      );

      final RenderSliverPersistentHeader header =
          harness.find<RenderSliverPersistentHeader>();
      expect(header.childExtent, 60);
      expect(harness.offsetOf(harness.list), 60);

      harness.position.jumpTo(30);
      harness.frame();
      expect(header.shrinkOffset, 30);
      expect(header.childExtent, 30);
      expect(harness.offsetOf(header), 0);
      expect(harness.offsetOf(harness.list), 30);

      harness.position.jumpTo(500);
      harness.frame();
      // Shrunk to the minimum, still at the top, and the list - whose layout
      // starts at the top, under the header - is painted beneath it.
      expect(header.childExtent, 20);
      expect(header.geometry.paintExtent, 20);
      expect(header.geometry.layoutExtent, 0);
      expect(harness.offsetOf(header), 0);
      expect(harness.offsetOf(harness.list), 0);
      // A press on the header reaches the header, not the row under it.
      expect(
        harness.hitPath(const Offset(100, 10)),
        allOf(contains(same(header)), isNot(contains(same(harness.list)))),
      );
      expect(
        harness.hitPath(const Offset(100, 50)),
        allOf(contains(same(harness.list)), isNot(contains(same(header)))),
      );
      harness.dispose();
    });

    test('a pinned header at its minimum does not rebuild while scrolling', () {
      final harness = _Harness(
        CustomScrollView(
          scrollbar: ScrollbarVisibility.never,
          slivers: <Widget>[
            const SliverPersistentHeader(pinned: true, delegate: _Header()),
            SliverFixedExtentList.builder(
              itemExtent: 20,
              itemCount: 100,
              itemBuilder: (BuildContext context, int index) =>
                  const SizedBox(),
            ),
          ],
        ),
      );
      harness.position.jumpTo(500);
      harness.frame();
      final SliverPersistentHeaderElement element =
          harness.elementOf<SliverPersistentHeaderElement>();
      final int builds = element.buildCount;
      harness.position.jumpTo(800);
      harness.frame();
      expect(element.buildCount, builds);
      harness.dispose();
    });

    test('a scrolling header leaves with the content', () {
      final harness = _Harness(
        CustomScrollView(
          scrollbar: ScrollbarVisibility.never,
          slivers: <Widget>[
            const SliverPersistentHeader(delegate: _Header()),
            SliverFixedExtentList.builder(
              itemExtent: 20,
              itemCount: 100,
              itemBuilder: (BuildContext context, int index) =>
                  const SizedBox(),
            ),
          ],
        ),
      );
      final RenderSliverPersistentHeader header =
          harness.find<RenderSliverPersistentHeader>();

      harness.position.jumpTo(50);
      harness.frame();
      // Shrunk past its 20px minimum: 10px painted, the 20px child sliding
      // out of the top.
      expect(header.geometry.paintExtent, 10);
      expect(header.child!.offsetFromParent.dy, -10);
      expect(harness.offsetOf(harness.list), 10);

      harness.position.jumpTo(100);
      harness.frame();
      expect(header.geometry.paintExtent, 0);
      harness.dispose();
    });

    test('a floating header comes back on the first scroll up', () {
      final harness = _Harness(
        CustomScrollView(
          scrollbar: ScrollbarVisibility.never,
          slivers: <Widget>[
            const SliverPersistentHeader(floating: true, delegate: _Header()),
            SliverFixedExtentList.builder(
              itemExtent: 20,
              itemCount: 100,
              itemBuilder: (BuildContext context, int index) =>
                  const SizedBox(),
            ),
          ],
        ),
      );
      final RenderSliverPersistentHeader header =
          harness.find<RenderSliverPersistentHeader>();

      harness.position.jumpTo(500);
      harness.frame();
      expect(header.geometry.paintExtent, 0);

      harness.position.jumpTo(485);
      harness.frame();
      // Fifteen pixels back up shows fifteen pixels of header, far from the
      // top of the content.
      expect(header.geometry.paintExtent, 15);
      expect(harness.offsetOf(header), 0);

      harness.position.jumpTo(400);
      harness.frame();
      expect(header.geometry.paintExtent, 60, reason: 'fully revealed');

      harness.position.jumpTo(420);
      harness.frame();
      expect(header.geometry.paintExtent, 40, reason: 'scrolling on hides it');
      harness.dispose();
    });
  });

  group('input', () {
    test('the wheel scrolls through the signal resolver', () {
      final harness = _Harness(_rows(100));
      harness.pointer(_wheel(const Offset(100, 50), 45));
      harness.frame();
      expect(harness.position.pixels, 45);
      expect(harness.list.realizedIndices.first, 2);
      harness.dispose();
    });

    test('the wheel runs the other way in a reversed view', () {
      final harness = _Harness(_rows(100, reverse: true));
      harness.pointer(_wheel(const Offset(100, 50), -45));
      harness.frame();
      expect(harness.position.pixels, 45, reason: 'wheel up shows older rows');
      harness.dispose();
    });

    test('a controller jumps, and the view follows', () {
      final ScrollPosition controller = ScrollPosition();
      final harness = _Harness(_rows(100, controller: controller));
      controller.jumpTo(300);
      harness.frame();
      expect(harness.list.realizedIndices, <int>[15, 16, 17, 18, 19]);
      expect(harness.rowOffsets.first, 0);
      harness.dispose();
    });

    test('a click focuses the view and the keys page it', () {
      final harness = _Harness(_rows(100));
      harness.pointer(_down(const Offset(100, 50)));
      harness.pointer(_up(const Offset(100, 50)));
      harness.frame();
      expect(harness.viewport.hasFocus, isTrue);

      harness.key(logicalKeyPageDown);
      harness.frame();
      expect(harness.position.pixels, 100 - defaultLineExtent);

      harness.key(logicalKeyEnd);
      harness.frame();
      expect(harness.position.pixels, harness.position.maxScrollExtent);

      harness.key(logicalKeyHome);
      harness.frame();
      expect(harness.position.pixels, 0);
      harness.dispose();
    });

    test('a scrollbar describes the whole content', () {
      final harness = _Harness(
        CustomScrollView(
          slivers: <Widget>[
            SliverFixedExtentList.builder(
              itemExtent: 20,
              itemCount: 100,
              itemBuilder: (BuildContext context, int index) =>
                  const SizedBox(),
            ),
          ],
        ),
      );
      final RenderScrollbar bar = harness.find<RenderScrollbar>();
      expect(bar.thumbMetrics, isNotNull);
      expect(bar.thumbMetrics!.start, 0);
      harness.dispose();
    });

    test('a reversed scrollbar starts at the bottom of its track', () {
      final harness = _Harness(
        CustomScrollView(
          reverse: true,
          slivers: <Widget>[
            SliverFixedExtentList.builder(
              itemExtent: 20,
              itemCount: 100,
              itemBuilder: (BuildContext context, int index) =>
                  const SizedBox(),
            ),
          ],
        ),
      );
      final RenderScrollbar bar = harness.find<RenderScrollbar>();
      final ({double start, double extent}) metrics = bar.thumbMetrics!;
      expect(
        metrics.start + metrics.extent,
        closeTo(bar.usableTrackExtent, 1e-9),
      );
      harness.dispose();
    });
  });

  group('accessibility', () {
    test('the viewport is a list that counts every lazy item', () {
      final harness = _Harness(
        CustomScrollView(
          scrollbar: ScrollbarVisibility.never,
          slivers: <Widget>[
            const SliverToBoxAdapter(child: SizedBox(height: 10)),
            SliverList.builder(
              itemCount: 100000,
              itemBuilder: (BuildContext context, int index) =>
                  const SizedBox(height: 20),
            ),
            SliverPadding(
              padding: const EdgeInsets.all(4),
              sliver: SliverGrid.count(
                crossAxisCount: 2,
                children: const <Widget>[SizedBox(), SizedBox(), SizedBox()],
              ),
            ),
          ],
        ),
      );
      final SemanticsConfiguration config =
          harness.viewport.describeSemantics();
      expect(config.role, SemanticsRole.list);
      expect(config.value, '100003 items');
      expect(config.actions, contains(SemanticsAction.scrollDown));
      expect(config.actions, isNot(contains(SemanticsAction.scrollUp)));

      expect(
        harness.viewport.performSemanticsAction(SemanticsAction.scrollDown),
        isTrue,
      );
      harness.frame();
      expect(harness.position.pixels, 100 - defaultLineExtent);
      harness.dispose();
    });
  });

  group('misuse', () {
    test('a box straight in the slivers is a named error', () {
      Object? thrown;
      try {
        final harness = _Harness(
          const CustomScrollView(
            scrollbar: ScrollbarVisibility.never,
            slivers: <Widget>[SizedBox(height: 10)],
          ),
        );
        harness.dispose();
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<SliverProtocolError>());
    });
  });
}

Widget _rows(int count, {bool reverse = false, ScrollPosition? controller}) =>
    CustomScrollView(
      reverse: reverse,
      controller: controller,
      scrollbar: ScrollbarVisibility.never,
      slivers: <Widget>[
        SliverFixedExtentList.builder(
          itemExtent: 20,
          itemCount: count,
          itemBuilder: (BuildContext context, int index) => const SizedBox(),
        ),
      ],
    );

final class _Header extends SliverPersistentHeaderDelegate {
  const _Header({this.color});

  /// Paints, and so takes hits, when set.
  final Color? color;

  @override
  double get minExtent => 20;

  @override
  double get maxExtent => 60;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) =>
      SizedBox(
        height: double.infinity,
        child: color == null ? null : ColoredBox(color: color!),
      );

  @override
  bool shouldRebuild(_Header oldDelegate) => oldDelegate.color != color;
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

  T elementOf<T extends Element>() {
    T? found;
    void walk(Element element) {
      if (found != null) return;
      if (element is T) {
        found = element;
        return;
      }
      element.visitChildren(walk);
    }

    walk(owner.rootElement!);
    if (found == null) throw StateError('no $T in the tree');
    return found!;
  }

  RenderCustomScrollViewport get viewport => find<RenderCustomScrollViewport>();

  ScrollPosition get position => viewport.position;

  RenderSliverList get list => find<RenderSliverList>();

  SliverMultiBoxAdaptorElement get element =>
      elementOf<SliverMultiBoxAdaptorElement>();

  /// A sliver's box offset along the vertical axis, inside the viewport.
  double offsetOf(RenderBox sliver) => sliver.offsetFromParent.dy;

  /// Each realized row's offset inside the list sliver's box.
  List<double> get rowOffsets => <double>[
        for (final RenderBox row in list.realizedChildren)
          row.offsetFromParent.dy,
      ];

  /// Where row [index]'s top edge is in the window.
  double globalRowTop(int index) => list.childAtIndex(index)!.globalOffset.dy;

  List<RenderBox> hitPath(Offset at) {
    final HitTestPath path = HitTestPath();
    owner.renderRoot!.hitTest(at, path: path);
    return <RenderBox>[for (int i = 0; i < path.length; i++) path[i]];
  }

  void dispose() => owner.dispose();
}

const NativeWindowId _window = NativeWindowId(1);

PointerDownEvent _down(Offset at) => PointerDownEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
      button: PointerButton.primary,
    );

PointerUpEvent _up(Offset at) => PointerUpEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration.zero,
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
