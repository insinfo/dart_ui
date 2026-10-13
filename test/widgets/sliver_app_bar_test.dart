/// `SliverAppBar` and `FlexibleSpaceBar`, as numbers.
///
/// Every assertion is an extent, an offset, a scale or an opacity: how tall
/// the bar is after a scroll, where the toolbar's pieces sit, how far the
/// flexible title has shrunk.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('extent', () {
    test('expanded at offset 0, shrinking as the list scrolls', () {
      final harness = _Harness(_view(const SliverAppBar(expandedHeight: 150)));
      final RenderSliverPersistentHeader header = harness.header;
      expect(header.childExtent, 150);
      expect(header.geometry.paintExtent, 150);
      expect(harness.offsetOf(harness.list), 150);

      harness.jumpTo(40);
      expect(header.childExtent, 110);
      expect(harness.settings.currentExtent, 110);
      expect(harness.settings.minExtent, 48, reason: 'the theme toolbar');
      expect(harness.settings.maxExtent, 150);
      expect(harness.offsetOf(harness.list), 110);
      harness.dispose();
    });

    test('the extents follow toolbar, bottom, collapsed and expanded heights',
        () {
      final harness = _Harness(_view(const SliverAppBar(
        toolbarHeight: 40,
        bottom: SizedBox(),
        bottomHeight: 30,
      )));
      expect(harness.header.minExtent, 70);
      expect(harness.header.maxExtent, 70, reason: 'no expandedHeight');
      harness.dispose();

      final collapsed = _Harness(_view(const SliverAppBar(
        toolbarHeight: 40,
        collapsedHeight: 60,
        expandedHeight: 50,
      )));
      expect(collapsed.header.minExtent, 60);
      expect(collapsed.header.maxExtent, 60, reason: 'never below the minimum');
      collapsed.dispose();
    });

    test('a pinned bar stays at its minimum while content scrolls under', () {
      final harness = _Harness(_view(const SliverAppBar(
        pinned: true,
        expandedHeight: 150,
      )));
      final RenderSliverPersistentHeader header = harness.header;
      expect(harness.settings.isScrolledUnder, isFalse);

      harness.jumpTo(500);
      expect(header.childExtent, 48);
      expect(header.geometry.paintExtent, 48);
      expect(harness.offsetOf(header), 0);
      expect(harness.offsetOf(harness.list), 0, reason: 'scrolls underneath');
      expect(harness.settings.toolbarOpacity, 1);
      expect(harness.settings.isScrolledUnder, isTrue);
      // The elevated look: a hairline in the theme's border colour.
      expect(
        harness.coloredBoxes,
        contains(ThemeData.neutralLight.border),
      );
      harness.dispose();
    });

    test('a bar that is not pinned scrolls away and fades its toolbar', () {
      final harness = _Harness(_view(const SliverAppBar(
        expandedHeight: 150,
        title: SizedBox(width: 10, height: 10),
      )));
      final RenderSliverPersistentHeader header = harness.header;

      harness.jumpTo(126);
      // 24px left on screen: the child keeps its 48px minimum and slides up.
      expect(header.geometry.paintExtent, 24);
      expect(header.child!.offsetFromParent.dy, -24);
      expect(harness.settings.toolbarOpacity, closeTo(0.5, 1e-9));
      expect(harness.find<RenderOpacity>().opacity, closeTo(0.5, 1e-9));

      harness.jumpTo(500);
      expect(header.geometry.paintExtent, 0);
      expect(harness.offsetOf(harness.list), 0);
      harness.dispose();
    });

    test('a floating bar comes back on a small scroll up', () {
      final harness = _Harness(_view(const SliverAppBar(
        floating: true,
        expandedHeight: 100,
      )));
      final RenderSliverPersistentHeader header = harness.header;

      harness.jumpTo(600);
      expect(header.geometry.paintExtent, 0);

      harness.jumpTo(580);
      expect(header.geometry.paintExtent, 20);
      expect(harness.offsetOf(header), 0);
      expect(harness.settings.isScrolledUnder, isTrue, reason: 'over content');

      harness.jumpTo(450);
      expect(header.geometry.paintExtent, 100, reason: 'fully revealed');

      harness.jumpTo(470);
      expect(header.geometry.paintExtent, 80, reason: 'scrolling on hides it');
      harness.dispose();
    });
  });

  group('toolbar', () {
    test('leading, title and actions in a row', () {
      final harness = _Harness(_view(const SliverAppBar(
        leading:
            SizedBox(key: ValueKey<String>('leading'), width: 24, height: 24),
        title: SizedBox(key: ValueKey<String>('title'), width: 60, height: 20),
        actions: <Widget>[
          SizedBox(key: ValueKey<String>('a1'), width: 30, height: 30),
          SizedBox(key: ValueKey<String>('a2'), width: 30, height: 30),
        ],
      )));
      // A 48x48 leading slot with the widget centred in it.
      expect(harness.rectOf('leading'), const Rect.fromLTWH(12, 12, 24, 24));
      // Title after the slot plus titleSpacing, centred vertically.
      expect(harness.rectOf('title'), const Rect.fromLTWH(48 + 16, 14, 60, 20));
      // Actions at the end, the theme's 8px gap before the edge.
      expect(
          harness.rectOf('a2'), const Rect.fromLTWH(300 - 8 - 30, 9, 30, 30));
      expect(
          harness.rectOf('a1'), const Rect.fromLTWH(300 - 8 - 60, 9, 30, 30));
      harness.dispose();
    });

    test('centerTitle centres the title in the whole bar', () {
      final harness = _Harness(_view(const SliverAppBar(
        centerTitle: true,
        leading: SizedBox(width: 24, height: 24),
        title: SizedBox(key: ValueKey<String>('title'), width: 60, height: 20),
        actions: <Widget>[SizedBox(width: 90, height: 30)],
      )));
      // Centred in 300, not in what leading and actions leave over.
      expect(harness.rectOf('title').left, 120);
      harness.dispose();
    });

    test('a centred title too wide to centre is pushed off the actions', () {
      final harness = _Harness(_view(const SliverAppBar(
        centerTitle: true,
        title: SizedBox(key: ValueKey<String>('title'), width: 160, height: 20),
        actions: <Widget>[SizedBox(width: 90, height: 30)],
      )));
      // Centred would end at 230; the actions start at 300 - 8 - 90 = 202,
      // and the title keeps titleSpacing clear of them.
      expect(harness.rectOf('title').right, 202 - 16);
      harness.dispose();
    });

    test('the bottom widget sits at the bottom, the toolbar at the top', () {
      final harness = _Harness(_view(const SliverAppBar(
        pinned: true,
        expandedHeight: 160,
        title: SizedBox(key: ValueKey<String>('title'), width: 60, height: 20),
        bottom:
            SizedBox(key: ValueKey<String>('bottom'), height: double.infinity),
        bottomHeight: 32,
      )));
      expect(harness.rectOf('title').top, 14);
      expect(harness.rectOf('bottom'), const Rect.fromLTWH(0, 128, 300, 32));

      harness.jumpTo(500);
      expect(harness.header.childExtent, 80);
      expect(harness.rectOf('title').top, 14);
      expect(harness.rectOf('bottom'), const Rect.fromLTWH(0, 48, 300, 32));
      harness.dispose();
    });

    test('colours come from the theme unless given', () {
      final harness = _Harness(_view(const SliverAppBar(
        title: Text('Title'),
      )));
      expect(
        harness.coloredBoxes.first,
        ThemeData.neutralLight.surfaceAlternate,
      );
      expect(harness.titleText.color, ThemeData.neutralLight.foreground);
      harness.dispose();

      final custom = _Harness(_view(const SliverAppBar(
        backgroundColor: Color(0xFF203040),
        foregroundColor: Color(0xFFFFFFFF),
        title: Text('Title'),
      )));
      expect(custom.coloredBoxes.first, const Color(0xFF203040));
      expect(custom.titleText.color, const Color(0xFFFFFFFF));
      custom.dispose();
    });

    test('a new delegate with equal fields does not rebuild the bar', () {
      final harness = _Harness(_view(const SliverAppBar(expandedHeight: 100)));
      final SliverPersistentHeaderElement element =
          harness.elementOf<SliverPersistentHeaderElement>();
      final int builds = element.buildCount;
      harness.mount(_view(const SliverAppBar(expandedHeight: 100)));
      expect(element.buildCount, builds);
      harness.mount(_view(const SliverAppBar(expandedHeight: 120)));
      expect(element.buildCount, greaterThan(builds));
      expect(harness.header.childExtent, 120);
      harness.dispose();
    });
  });

  group('flexible space', () {
    const Widget title =
        SizedBox(key: ValueKey<String>('flexTitle'), width: 80, height: 20);

    test('the title scales from 1.5 to 1 and moves into the toolbar', () {
      final harness = _Harness(_view(const SliverAppBar(
        pinned: true,
        expandedHeight: 200,
        flexibleSpace: FlexibleSpaceBar(title: title),
      )));
      final RenderTransform transform = harness.find<RenderTransform>();

      expect(transform.transform.a, closeTo(1.5, 1e-9));
      final Rect expanded = harness.visualRectOf('flexTitle', transform);
      expect(expanded.left, closeTo(16, 1e-9));
      expect(expanded.width, closeTo(120, 1e-9));
      expect(expanded.height, closeTo(30, 1e-9));
      // Its bottom stays where the collapsed title's bottom will be, plus the
      // part of the bar that has not collapsed yet.
      final double bottomPadding = 200 - expanded.bottom;

      harness.jumpTo(76);
      // Halfway: 200 -> 124 of the 152px collapse.
      expect(transform.transform.a, closeTo(1.25, 1e-9));
      final Rect half = harness.visualRectOf('flexTitle', transform);
      expect(half.bottom, closeTo(124 - bottomPadding, 1e-9));
      expect(half.width, closeTo(100, 1e-9));

      harness.jumpTo(400);
      expect(transform.transform.a, closeTo(1, 1e-9));
      final Rect collapsed = harness.visualRectOf('flexTitle', transform);
      expect(collapsed.size, const Size(80, 20));
      expect(collapsed.left, 16);
      // Centred in the 48px toolbar, to the pixel the line height allows.
      expect(collapsed.center.dy, closeTo(24, 1));
      harness.dispose();
    });

    test('a leading widget pushes the title past its slot', () {
      final harness = _Harness(_view(const SliverAppBar(
        pinned: true,
        expandedHeight: 200,
        leading: SizedBox(width: 24, height: 24),
        flexibleSpace: FlexibleSpaceBar(title: title),
      )));
      harness.jumpTo(400);
      final RenderTransform transform = harness.find<RenderTransform>();
      expect(harness.visualRectOf('flexTitle', transform).left, 48 + 16);
      harness.dispose();
    });

    test('a centred title stays centred while it scales', () {
      final harness = _Harness(_view(const SliverAppBar(
        pinned: true,
        expandedHeight: 200,
        flexibleSpace: FlexibleSpaceBar(centerTitle: true, title: title),
      )));
      final RenderTransform transform = harness.find<RenderTransform>();
      expect(harness.visualRectOf('flexTitle', transform).center.dx, 150);
      harness.jumpTo(76);
      expect(harness.visualRectOf('flexTitle', transform).center.dx, 150);
      harness.dispose();
    });

    test('the background parallaxes and fades out as the bar collapses', () {
      final harness = _Harness(_view(const SliverAppBar(
        pinned: true,
        expandedHeight: 200,
        flexibleSpace: FlexibleSpaceBar(
          background: SizedBox(
            key: ValueKey<String>('background'),
            height: double.infinity,
          ),
        ),
      )));
      expect(harness.rectOf('background'), const Rect.fromLTWH(0, 0, 300, 200));

      harness.jumpTo(76);
      // Half collapsed: a quarter of the 152px collapse, halved.
      expect(harness.rectOf('background').top, -19);
      expect(harness.rectOf('background').height, 200);

      harness.jumpTo(140);
      // Fading over the last 48px of the collapse: 12px from the end.
      expect(harness.find<RenderOpacity>().opacity, closeTo(0.25, 1e-9));

      harness.jumpTo(400);
      expect(harness.findAll<RenderOpacity>(), isEmpty);
      expect(
        () => harness.rectOf('background'),
        throwsStateError,
        reason: 'not built once invisible',
      );
      harness.dispose();
    });

    test('settings follow the bar', () {
      final harness = _Harness(_view(const SliverAppBar(
        expandedHeight: 120,
        leading: SizedBox(),
        flexibleSpace: FlexibleSpaceBar(title: title),
      )));
      final FlexibleSpaceBarSettings settings = harness.settings;
      expect(settings.hasLeading, isTrue);
      expect(settings.toolbarHeight, 48);
      expect(settings.currentExtent, 120);
      harness.jumpTo(30);
      expect(harness.settings.currentExtent, 90);
      harness.dispose();
    });
  });
}

Widget _view(Widget appBar) => Theme(
      data: ThemeData.neutralLight,
      child: Directionality(
        textDirection: TextDirection.leftToRight,
        child: CustomScrollView(
          scrollbar: ScrollbarVisibility.never,
          slivers: <Widget>[
            appBar,
            SliverFixedExtentList.builder(
              itemExtent: 20,
              itemCount: 100,
              itemBuilder: (BuildContext context, int index) =>
                  const SizedBox(),
            ),
          ],
        ),
      ),
    );

final class _Harness {
  _Harness(Widget widget, {Size size = const Size(300, 400)}) {
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

  void jumpTo(double offset) {
    position.jumpTo(offset);
    frame();
  }

  List<T> findAll<T extends RenderBox>() {
    final List<T> found = <T>[];
    void walk(RenderBox node) {
      if (node is T) found.add(node);
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found;
  }

  T find<T extends RenderBox>() {
    final List<T> found = findAll<T>();
    if (found.isEmpty) throw StateError('no $T in the tree');
    return found.first;
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

  /// The render box of the widget keyed `ValueKey(key)`.
  RenderBox renderOf(String key) {
    RenderBox? found;
    void walk(Element element) {
      if (found != null) return;
      if (element.widget.key == ValueKey<String>(key) &&
          element is RenderObjectElement) {
        found = element.renderObject;
        return;
      }
      element.visitChildren(walk);
    }

    walk(owner.rootElement!);
    if (found == null) throw StateError('no $key in the tree');
    return found!;
  }

  /// Where the keyed box is laid out, in window coordinates.
  Rect rectOf(String key) {
    final RenderBox box = renderOf(key);
    final Offset at = box.globalOffset;
    return Rect.fromLTWH(at.dx, at.dy, box.size.width, box.size.height);
  }

  /// Where the keyed box is *drawn*: its layout rect pushed through
  /// [transform]'s scale about its pivot. `globalOffset` walks offsets only.
  Rect visualRectOf(String key, RenderTransform transform) {
    final Rect laidOut = rectOf(key);
    final Offset origin = transform.globalOffset;
    final Alignment alignment = transform.alignment ?? Alignment.topLeft;
    final Offset pivot = Offset(
      origin.dx + (alignment.x + 1) / 2 * transform.size.width,
      origin.dy + (alignment.y + 1) / 2 * transform.size.height,
    );
    final double s = transform.transform.a;
    return Rect.fromLTRB(
      pivot.dx + (laidOut.left - pivot.dx) * s,
      pivot.dy + (laidOut.top - pivot.dy) * s,
      pivot.dx + (laidOut.right - pivot.dx) * s,
      pivot.dy + (laidOut.bottom - pivot.dy) * s,
    );
  }

  /// The colours of every `ColoredBox` in paint order.
  List<Color> get coloredBoxes => <Color>[
        for (final RenderColoredBox box in findAll<RenderColoredBox>())
          box.color,
      ];

  RenderText get titleText => find<RenderText>();

  RenderCustomScrollViewport get viewport => find<RenderCustomScrollViewport>();

  ScrollPosition get position => viewport.position;

  RenderSliverPersistentHeader get header =>
      find<RenderSliverPersistentHeader>();

  RenderSliverList get list => find<RenderSliverList>();

  FlexibleSpaceBarSettings get settings {
    FlexibleSpaceBarSettings? found;
    void walk(Element element) {
      if (found != null) return;
      final Widget widget = element.widget;
      if (widget is FlexibleSpaceBarSettings) {
        found = widget;
        return;
      }
      element.visitChildren(walk);
    }

    walk(owner.rootElement!);
    if (found == null) throw StateError('no FlexibleSpaceBarSettings');
    return found!;
  }

  double offsetOf(RenderBox sliver) => sliver.offsetFromParent.dy;

  void dispose() => owner.dispose();
}
