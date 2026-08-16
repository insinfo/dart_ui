/// A flex that knows which way the text runs.
///
/// The interesting claims are all about *which* axis moves and which does not,
/// so every test here compares a right-to-left layout against the exact
/// left-to-right numbers it should mirror. A test that only asserted "the
/// first child is not at zero" would pass for a layout that reversed the
/// children *and* the alignment, which is the classic double-flip bug.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  const TextDirection ltr = TextDirection.leftToRight;
  const TextDirection rtl = TextDirection.rightToLeft;

  RenderFlex laidOut(RenderFlex flex, Size size) {
    final PipelineOwner owner = PipelineOwner(
      rootConstraints: BoxConstraints.tight(size),
    )..root = flex;
    owner.flushLayout();
    return flex;
  }

  /// A row of the three fixed children used by most tests below, plus handles
  /// on them so their offsets can be read back.
  (RenderFlex, List<FixedBox>) row({
    required TextDirection? textDirection,
    MainAxisAlignment mainAxisAlignment = MainAxisAlignment.start,
    CrossAxisAlignment crossAxisAlignment = CrossAxisAlignment.start,
    List<Size> sizes = const <Size>[
      Size(20, 10),
      Size(30, 10),
      Size(40, 10),
    ],
  }) {
    final List<FixedBox> children = <FixedBox>[
      for (final Size size in sizes) FixedBox(size),
    ];
    final RenderFlex flex = RenderFlex(
      mainAxisAlignment: mainAxisAlignment,
      crossAxisAlignment: crossAxisAlignment,
      textDirection: textDirection,
    );
    for (final FixedBox child in children) {
      flex.add(child);
    }
    return (flex, children);
  }

  List<double> xs(List<FixedBox> children) => <double>[
        for (final FixedBox child in children) child.offsetFromParent.dx
      ];

  List<double> ys(List<FixedBox> children) => <double>[
        for (final FixedBox child in children) child.offsetFromParent.dy
      ];

  group('a row mirrors its main axis', () {
    test('start puts the first child against the right edge', () {
      final (RenderFlex leftToRight, List<FixedBox> a) =
          row(textDirection: ltr);
      final (RenderFlex rightToLeft, List<FixedBox> b) =
          row(textDirection: rtl);
      laidOut(leftToRight, const Size(200, 50));
      laidOut(rightToLeft, const Size(200, 50));

      expect(xs(a), <double>[0, 20, 50]);
      // 200 - x - width, child by child: the exact mirror image.
      expect(xs(b), <double>[180, 150, 110]);
      // ... asserted again as the relation itself, so a future change to the
      // sizes above cannot quietly weaken the claim.
      for (int i = 0; i < a.length; i++) {
        expect(
          b[i].offsetFromParent.dx,
          200 - a[i].offsetFromParent.dx - a[i].size.width,
        );
      }
    });

    test('the children still touch, in the opposite order', () {
      final (RenderFlex flex, List<FixedBox> children) =
          row(textDirection: rtl);
      laidOut(flex, const Size(200, 50));

      // Right edge of the last child meets the left edge of the one before it.
      expect(children[2].offsetFromParent.dx + 40, 150);
      expect(children[1].offsetFromParent.dx + 30, 180);
      expect(children[0].offsetFromParent.dx + 20, 200);
    });

    test('end packs against the left edge', () {
      // The reversal that is easiest to get wrong: in right-to-left, `end` is
      // the left, so an end-aligned row hugs x = 0.
      final (RenderFlex flex, List<FixedBox> children) = row(
        textDirection: rtl,
        mainAxisAlignment: MainAxisAlignment.end,
      );
      laidOut(flex, const Size(200, 50));

      expect(xs(children), <double>[70, 40, 0]);
    });

    test('center is mirrored but still centred', () {
      final (RenderFlex flex, List<FixedBox> children) = row(
        textDirection: rtl,
        mainAxisAlignment: MainAxisAlignment.center,
      );
      laidOut(flex, const Size(200, 50));

      // (200 - 90) / 2 = 55 of slack on each side, children reversed inside.
      expect(xs(children), <double>[125, 95, 55]);
      expect(children[2].offsetFromParent.dx, 55);
      expect(children[0].offsetFromParent.dx + 20, 145);
    });

    test('spaceBetween keeps equal gaps and reverses the order', () {
      final (RenderFlex leftToRight, List<FixedBox> a) = row(
        textDirection: ltr,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
      );
      final (RenderFlex rightToLeft, List<FixedBox> b) = row(
        textDirection: rtl,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
      );
      laidOut(leftToRight, const Size(200, 50));
      laidOut(rightToLeft, const Size(200, 50));

      // 200 - 90 = 110 of slack over two gaps: 55 each, in both directions.
      expect(xs(a), <double>[0, 75, 160]);
      expect(xs(b), <double>[180, 95, 0]);

      double gap(List<FixedBox> children, int leftIndex, int rightIndex) =>
          children[rightIndex].offsetFromParent.dx -
          (children[leftIndex].offsetFromParent.dx +
              children[leftIndex].size.width);

      expect(gap(a, 0, 1), 55);
      expect(gap(a, 1, 2), 55);
      // Reversed on screen, so the pairs are read the other way round.
      expect(gap(b, 2, 1), 55);
      expect(gap(b, 1, 0), 55);

      // Both ends are still flush.
      expect(a.first.offsetFromParent.dx, 0);
      expect(a.last.offsetFromParent.dx + a.last.size.width, 200);
      expect(b.last.offsetFromParent.dx, 0);
      expect(b.first.offsetFromParent.dx + b.first.size.width, 200);
    });

    test('spaceEvenly and spaceAround mirror without changing their gaps', () {
      for (final MainAxisAlignment alignment in <MainAxisAlignment>[
        MainAxisAlignment.spaceEvenly,
        MainAxisAlignment.spaceAround,
      ]) {
        final (RenderFlex leftToRight, List<FixedBox> a) =
            row(textDirection: ltr, mainAxisAlignment: alignment);
        final (RenderFlex rightToLeft, List<FixedBox> b) =
            row(textDirection: rtl, mainAxisAlignment: alignment);
        laidOut(leftToRight, const Size(200, 50));
        laidOut(rightToLeft, const Size(200, 50));

        for (int i = 0; i < a.length; i++) {
          expect(
            b[i].offsetFromParent.dx,
            200 - a[i].offsetFromParent.dx - a[i].size.width,
            reason: '$alignment child $i',
          );
        }
      }
      // The concrete numbers for spaceEvenly, so this is not purely relative:
      // 110 / 4 = 27.5 at each of the four positions.
      final (RenderFlex flex, List<FixedBox> children) = row(
        textDirection: rtl,
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      );
      laidOut(flex, const Size(200, 50));
      expect(xs(children), <double>[152.5, 95, 27.5]);
    });

    test('a null direction lays out exactly as left-to-right', () {
      final (RenderFlex unset, List<FixedBox> a) = row(textDirection: null);
      final (RenderFlex explicit, List<FixedBox> b) = row(textDirection: ltr);
      laidOut(unset, const Size(200, 50));
      laidOut(explicit, const Size(200, 50));

      expect(unset.textDirection, isNull);
      expect(xs(a), xs(b));
      expect(xs(a), <double>[0, 20, 50]);
    });

    test('changing the direction re-lays the row out', () {
      final (RenderFlex flex, List<FixedBox> children) =
          row(textDirection: ltr);
      final PipelineOwner owner = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(200, 50)),
      )..root = flex;
      owner.flushLayout();
      expect(xs(children), <double>[0, 20, 50]);

      flex.textDirection = rtl;
      owner.flushLayout();
      expect(xs(children), <double>[180, 150, 110]);

      // Setting the same value again is not a layout.
      final int before = children.first.layoutCount;
      flex.textDirection = rtl;
      owner.flushLayout();
      expect(children.first.layoutCount, before);
    });
  });

  group('what a row does not mirror', () {
    test('the cross axis is vertical and stays put', () {
      // Both alignments, both directions, four identical vertical answers.
      for (final CrossAxisAlignment cross in <CrossAxisAlignment>[
        CrossAxisAlignment.start,
        CrossAxisAlignment.end,
      ]) {
        final (RenderFlex leftToRight, List<FixedBox> a) = row(
          textDirection: ltr,
          crossAxisAlignment: cross,
          sizes: const <Size>[Size(20, 10), Size(30, 20)],
        );
        final (RenderFlex rightToLeft, List<FixedBox> b) = row(
          textDirection: rtl,
          crossAxisAlignment: cross,
          sizes: const <Size>[Size(20, 10), Size(30, 20)],
        );
        laidOut(leftToRight, const Size(200, 50));
        laidOut(rightToLeft, const Size(200, 50));
        expect(ys(a), ys(b), reason: '$cross');
      }
      final (RenderFlex flex, List<FixedBox> children) = row(
        textDirection: rtl,
        crossAxisAlignment: CrossAxisAlignment.end,
        sizes: const <Size>[Size(20, 10), Size(30, 20)],
      );
      laidOut(flex, const Size(200, 50));
      expect(ys(children), <double>[40, 30]);
    });

    test('sizes, flex division and mainAxisSize are direction-free', () {
      RenderFlex build(TextDirection direction) {
        final RenderFlex flex = RenderFlex(textDirection: direction)
          ..add(FixedBox(const Size(20, 10)));
        flex.add(FillBox(), flex: 1);
        return flex;
      }

      final RenderFlex leftToRight = laidOut(
        build(ltr),
        const Size(100, 50),
      );
      final RenderFlex rightToLeft = laidOut(
        build(rtl),
        const Size(100, 50),
      );

      expect(leftToRight.childAt(1).size.width, 80);
      expect(rightToLeft.childAt(1).size.width, 80);
      expect(leftToRight.size, rightToLeft.size);
      // The flexible child took the 80 that was left, on the left-hand side.
      expect(rightToLeft.childAt(0).offsetFromParent.dx, 80);
      expect(rightToLeft.childAt(1).offsetFromParent.dx, 0);
    });

    test('overflow is reported identically and spills off the other edge', () {
      final (RenderFlex leftToRight, List<FixedBox> a) = row(
        textDirection: ltr,
        sizes: const <Size>[Size(100, 10), Size(150, 10)],
      );
      final (RenderFlex rightToLeft, List<FixedBox> b) = row(
        textDirection: rtl,
        sizes: const <Size>[Size(100, 10), Size(150, 10)],
      );
      laidOut(leftToRight, const Size(200, 50));
      laidOut(rightToLeft, const Size(200, 50));

      expect(leftToRight.overflow, 50);
      expect(rightToLeft.overflow, 50);
      expect(xs(a), <double>[0, 100]);
      // The first child still starts at the leading edge, which is now the
      // right, and the overflow runs off the left instead of the right.
      expect(xs(b), <double>[100, -50]);
    });

    test('the intrinsic queries ignore the direction', () {
      // MeasuredBox rather than FixedBox: only it answers intrinsic questions,
      // and a row of boxes that all answer zero would agree in both
      // directions for the wrong reason.
      RenderFlex build(TextDirection direction) =>
          RenderFlex(textDirection: direction)
            ..add(MeasuredBox(const Size(20, 10)))
            ..add(MeasuredBox(const Size(30, 10)))
            ..add(MeasuredBox(const Size(40, 10)));

      final RenderFlex leftToRight = build(ltr);
      final RenderFlex rightToLeft = build(rtl);
      expect(rightToLeft.getMaxIntrinsicWidth(50), 90);
      expect(
        rightToLeft.getMaxIntrinsicWidth(50),
        leftToRight.getMaxIntrinsicWidth(50),
      );
      expect(
        rightToLeft.getMaxIntrinsicHeight(200),
        leftToRight.getMaxIntrinsicHeight(200),
      );
    });

    test('baseline alignment is vertical and survives the mirror', () {
      RenderFlex build(TextDirection direction) => RenderFlex(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textDirection: direction,
          )
            ..add(BaselineBox(const Size(20, 30), 24))
            ..add(BaselineBox(const Size(30, 20), 10));

      final RenderFlex leftToRight = laidOut(build(ltr), const Size(200, 50));
      final RenderFlex rightToLeft = laidOut(build(rtl), const Size(200, 50));

      // Deepest baseline is 24, so the second child drops by 24 - 10 = 14.
      expect(leftToRight.childAt(0).offsetFromParent.dy, 0);
      expect(leftToRight.childAt(1).offsetFromParent.dy, 14);
      expect(rightToLeft.childAt(0).offsetFromParent.dy, 0);
      expect(rightToLeft.childAt(1).offsetFromParent.dy, 14);
      // ... while the main axis did mirror.
      expect(rightToLeft.childAt(0).offsetFromParent.dx, 180);
      expect(rightToLeft.childAt(1).offsetFromParent.dx, 150);
    });
  });

  group('a column does not reverse, but its cross axis resolves', () {
    (RenderFlex, List<FixedBox>) column({
      required TextDirection? textDirection,
      CrossAxisAlignment crossAxisAlignment = CrossAxisAlignment.start,
      MainAxisAlignment mainAxisAlignment = MainAxisAlignment.start,
    }) {
      final List<FixedBox> children = <FixedBox>[
        FixedBox(const Size(20, 10)),
        FixedBox(const Size(40, 10)),
      ];
      final RenderFlex flex = RenderFlex(
        direction: Axis.vertical,
        crossAxisAlignment: crossAxisAlignment,
        mainAxisAlignment: mainAxisAlignment,
        textDirection: textDirection,
      );
      for (final FixedBox child in children) {
        flex.add(child);
      }
      return (flex, children);
    }

    test('the main axis is untouched: first child stays at the top', () {
      final (RenderFlex flex, List<FixedBox> children) = column(
        textDirection: rtl,
        mainAxisAlignment: MainAxisAlignment.start,
      );
      laidOut(flex, const Size(100, 200));

      expect(ys(children), <double>[0, 10]);
    });

    test('MainAxisAlignment.end is still the bottom in right-to-left', () {
      final (RenderFlex flex, List<FixedBox> children) = column(
        textDirection: rtl,
        mainAxisAlignment: MainAxisAlignment.end,
      );
      laidOut(flex, const Size(100, 200));

      expect(ys(children), <double>[180, 190]);
    });

    test('crossAxisAlignment.start becomes the right edge', () {
      final (RenderFlex leftToRight, List<FixedBox> a) =
          column(textDirection: ltr);
      final (RenderFlex rightToLeft, List<FixedBox> b) =
          column(textDirection: rtl);
      laidOut(leftToRight, const Size(100, 200));
      laidOut(rightToLeft, const Size(100, 200));

      expect(xs(a), <double>[0, 0]);
      // 100 - 20 and 100 - 40: each child's own trailing edge on the right.
      expect(xs(b), <double>[80, 60]);
      expect(b[0].offsetFromParent.dx + 20, 100);
      expect(b[1].offsetFromParent.dx + 40, 100);
    });

    test('crossAxisAlignment.end becomes the left edge', () {
      final (RenderFlex flex, List<FixedBox> children) = column(
        textDirection: rtl,
        crossAxisAlignment: CrossAxisAlignment.end,
      );
      laidOut(flex, const Size(100, 200));

      expect(xs(children), <double>[0, 0]);
    });

    test('center and stretch are symmetric, so nothing moves', () {
      final (RenderFlex centredLtr, List<FixedBox> a) = column(
        textDirection: ltr,
        crossAxisAlignment: CrossAxisAlignment.center,
      );
      final (RenderFlex centredRtl, List<FixedBox> b) = column(
        textDirection: rtl,
        crossAxisAlignment: CrossAxisAlignment.center,
      );
      laidOut(centredLtr, const Size(100, 200));
      laidOut(centredRtl, const Size(100, 200));
      expect(xs(a), <double>[40, 30]);
      expect(xs(b), <double>[40, 30]);

      final (RenderFlex stretchedRtl, List<FixedBox> c) = column(
        textDirection: rtl,
        crossAxisAlignment: CrossAxisAlignment.stretch,
      );
      laidOut(stretchedRtl, const Size(100, 200));
      expect(xs(c), <double>[0, 0]);
      expect(c.first.size.width, 100);
    });
  });

  group('the mirror is per node', () {
    test('a left-to-right row inside a right-to-left row is not reversed', () {
      // The nesting a `Directionality` produces in the widget tree, expressed
      // directly on the render nodes: each flex resolves its own direction and
      // neither consults the other.
      final FixedBox innerA = FixedBox(const Size(20, 10));
      final FixedBox innerB = FixedBox(const Size(30, 10));
      final RenderFlex inner = RenderFlex(
        mainAxisSize: MainAxisSize.min,
        textDirection: ltr,
      )
        ..add(innerA)
        ..add(innerB);

      final FixedBox sibling = FixedBox(const Size(40, 10));
      final RenderFlex outer = RenderFlex(textDirection: rtl)
        ..add(inner)
        ..add(sibling);

      laidOut(outer, const Size(200, 50));

      // The outer row mirrored: the inner row is first, so it is on the right.
      expect(inner.size.width, 50);
      expect(inner.offsetFromParent.dx, 150);
      expect(sibling.offsetFromParent.dx, 110);
      // The inner row did not: its own children run left to right inside it.
      expect(innerA.offsetFromParent.dx, 0);
      expect(innerB.offsetFromParent.dx, 20);
      // And in the outer coordinate space that is still 150 and 170.
      expect(innerA.globalOffset.dx, 150);
      expect(innerB.globalOffset.dx, 170);
    });

    test('a right-to-left row inside a left-to-right row reverses only itself',
        () {
      final FixedBox innerA = FixedBox(const Size(20, 10));
      final FixedBox innerB = FixedBox(const Size(30, 10));
      final RenderFlex inner = RenderFlex(
        mainAxisSize: MainAxisSize.min,
        textDirection: rtl,
      )
        ..add(innerA)
        ..add(innerB);

      final FixedBox sibling = FixedBox(const Size(40, 10));
      final RenderFlex outer = RenderFlex(textDirection: ltr)
        ..add(inner)
        ..add(sibling);

      laidOut(outer, const Size(200, 50));

      expect(inner.offsetFromParent.dx, 0);
      expect(sibling.offsetFromParent.dx, 50);
      // Inside the 50-wide inner row, the first child is on the right.
      expect(innerA.offsetFromParent.dx, 30);
      expect(innerB.offsetFromParent.dx, 0);
      expect(innerA.globalOffset.dx, 30);
    });
  });
}
