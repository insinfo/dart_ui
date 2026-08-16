/// Intrinsic measurement - section 25.6.
///
/// Three claims are under test: the answers are right, they are computed once,
/// and the cache dies with the layout it described. The third is the one that
/// matters: a cache that answers correctly but outlives its content produces a
/// stale layout silently, which is worse than no cache at all.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  const double inf = double.infinity;

  group('leaves', () {
    test('a plain RenderBox wants nothing', () {
      final box = FixedBox(const Size(40, 20));

      expect(box.getMinIntrinsicWidth(inf), 0);
      expect(box.getMaxIntrinsicWidth(inf), 0);
      expect(box.getMinIntrinsicHeight(inf), 0);
      expect(box.getMaxIntrinsicHeight(inf), 0);
    });

    test('a measured leaf reports its content on all four questions', () {
      final box = MeasuredBox(const Size(40, 20));

      expect(box.getMinIntrinsicWidth(inf), 40);
      expect(box.getMaxIntrinsicWidth(inf), 40);
      expect(box.getMinIntrinsicHeight(inf), 20);
      expect(box.getMaxIntrinsicHeight(inf), 20);
    });

    test('a reflowing leaf answers a height that depends on the width', () {
      final box = ReflowingBox(contentWidth: 120, lineHeight: 8);

      expect(box.getMaxIntrinsicWidth(inf), 120);
      expect(box.getMaxIntrinsicHeight(120), 8);
      expect(box.getMaxIntrinsicHeight(60), 16);
      expect(box.getMaxIntrinsicHeight(40), 24);
    });
  });

  group('wrappers', () {
    test('padding adds its insets on both axes', () {
      final padding = RenderPadding(
        padding: const EdgeInsets(4, 2, 6, 8),
        child: MeasuredBox(const Size(40, 20)),
      );

      expect(padding.getMaxIntrinsicWidth(inf), 50);
      expect(padding.getMaxIntrinsicHeight(inf), 30);
    });

    test('padding shrinks the cross extent it passes to the child', () {
      // 40 minus 10 of horizontal padding leaves 30, at which the 120 wide
      // content needs four lines.
      final padding = RenderPadding(
        padding: const EdgeInsets.symmetric(horizontal: 5),
        child: ReflowingBox(contentWidth: 120, lineHeight: 8),
      );

      expect(padding.getMaxIntrinsicHeight(40), 32);
    });

    test('a constrained box clamps its child\'s answer', () {
      final box = RenderConstrainedBox(
        additionalConstraints: BoxConstraints(maxWidth: 25),
        child: MeasuredBox(const Size(40, 20)),
      );

      expect(box.getMaxIntrinsicWidth(inf), 25);
      expect(box.getMaxIntrinsicHeight(inf), 20);
    });

    test('a fixed-size box answers without consulting its child', () {
      final child = MeasuredBox(const Size(40, 20));
      final box = RenderConstrainedBox(
        additionalConstraints: BoxConstraints.tightFor(width: 33),
        child: child,
      );

      expect(box.getMaxIntrinsicWidth(inf), 33);
    });

    test('align multiplies by its factor', () {
      final align = RenderAlign(
        widthFactor: 2,
        child: MeasuredBox(const Size(40, 20)),
      );

      expect(align.getMaxIntrinsicWidth(inf), 80);
      expect(align.getMaxIntrinsicHeight(inf), 20);
    });

    test('an aspect ratio answers from the ratio alone', () {
      final ratio = RenderAspectRatio(
        aspectRatio: 16 / 9,
        child: MeasuredBox(const Size(1, 1)),
      );

      expect(ratio.getMaxIntrinsicWidth(90), 160);
      expect(ratio.getMinIntrinsicWidth(90), 160);
      expect(ratio.getMaxIntrinsicHeight(160), 90);
      expect(ratio.getMinIntrinsicHeight(160), 90);
    });

    test('a viewport hides its content\'s extent on the scroll axis', () {
      final viewport = RenderViewport(
        position: ScrollPosition(),
        child: MeasuredBox(const Size(40, 900)),
      );

      expect(viewport.getMaxIntrinsicWidth(inf), 40);
      expect(viewport.getMaxIntrinsicHeight(inf), 0);
    });

    test('a stack is as big as its largest non-positioned child', () {
      final positioned = MeasuredBox(const Size(500, 500));
      final stack = RenderStack()
        ..add(MeasuredBox(const Size(30, 10)))
        ..add(MeasuredBox(const Size(12, 40)))
        ..add(positioned);
      stack.position(positioned, left: 0, top: 0);

      expect(stack.getMaxIntrinsicWidth(inf), 30);
      expect(stack.getMaxIntrinsicHeight(inf), 40);
    });
  });

  group('flex', () {
    test('a row adds its inflexible children up', () {
      final row = RenderFlex()
        ..add(MeasuredBox(const Size(30, 10)))
        ..add(MeasuredBox(const Size(20, 40)));

      expect(row.getMaxIntrinsicWidth(inf), 50);
      expect(row.getMaxIntrinsicHeight(inf), 40);
    });

    test('a column takes the widest and adds the heights', () {
      final column = RenderFlex(direction: Axis.vertical)
        ..add(MeasuredBox(const Size(30, 10)))
        ..add(MeasuredBox(const Size(20, 40)));

      expect(column.getMaxIntrinsicWidth(inf), 30);
      expect(column.getMaxIntrinsicHeight(inf), 50);
    });

    test('flexible children are sized from one shared rate', () {
      // The greediest child wants 30 at a flex of 1, so the rate is 30 and the
      // row needs 30 * 3 to satisfy everyone at that rate.
      final row = RenderFlex()
        ..add(MeasuredBox(const Size(30, 10)), flex: 1)
        ..add(MeasuredBox(const Size(20, 10)), flex: 2);

      expect(row.getMaxIntrinsicWidth(inf), 90);
    });

    test('a nested flex composes', () {
      final inner = RenderFlex(direction: Axis.vertical)
        ..add(MeasuredBox(const Size(30, 10)))
        ..add(MeasuredBox(const Size(20, 40)));
      final outer = RenderFlex()
        ..add(MeasuredBox(const Size(15, 5)))
        ..add(inner);

      expect(outer.getMaxIntrinsicWidth(inf), 45);
      expect(outer.getMaxIntrinsicHeight(inf), 50);
    });

    test('a row measures a child\'s height at the main extent it would get',
        () {
      // 120 pixels of content in a row 60 wide is two lines, not one.
      final row = RenderFlex()
        ..add(ReflowingBox(contentWidth: 120, lineHeight: 8));

      expect(row.getMaxIntrinsicHeight(60), 8);
      expect(row.getMaxIntrinsicHeight(inf), 8);
    });
  });

  group('the cache', () {
    test('answers a repeated question once', () {
      final box = MeasuredBox(const Size(40, 20));

      for (int i = 0; i < 5; i++) {
        expect(box.getMaxIntrinsicWidth(inf), 40);
      }

      expect(box.intrinsicComputeCount, 1);
    });

    test('keys on the question and its argument, not on one or the other', () {
      final box = MeasuredBox(const Size(40, 20));

      box
        ..getMaxIntrinsicWidth(inf)
        ..getMaxIntrinsicWidth(inf)
        ..getMinIntrinsicWidth(inf)
        ..getMaxIntrinsicWidth(100)
        ..getMaxIntrinsicWidth(100);

      // Three distinct (question, argument) pairs, three computations.
      expect(box.intrinsicComputeCount, 3);
    });

    test('spares a shared subtree from being re-walked once per asker', () {
      final shared = MeasuredBox(const Size(40, 20));
      final row = RenderFlex()..add(shared);

      // Five columns of a grid all asking the same row the same question is
      // exactly the shape that would go exponential without this.
      for (int i = 0; i < 5; i++) {
        expect(row.getMaxIntrinsicWidth(inf), 40);
      }

      expect(shared.intrinsicComputeCount, 1);
    });

    test('is dropped when the node is dirtied, and answers the new value', () {
      final box = MeasuredBox(const Size(40, 20));

      expect(box.getMaxIntrinsicWidth(inf), 40);
      expect(box.intrinsicComputeCount, 1);

      box.preferredSize = const Size(70, 20);

      expect(box.getMaxIntrinsicWidth(inf), 70);
      expect(box.intrinsicComputeCount, 2);
    });

    test('an ancestor\'s cached answer dies with its child\'s', () {
      final box = MeasuredBox(const Size(40, 20));
      final row = RenderFlex()..add(box);
      final padding =
          RenderPadding(padding: const EdgeInsets.all(5), child: row);

      expect(padding.getMaxIntrinsicWidth(inf), 50);

      box.preferredSize = const Size(70, 20);

      expect(padding.getMaxIntrinsicWidth(inf), 80);
    });

    test('the invalidation crosses a relayout boundary', () {
      // The child is laid out under tight constraints, which makes it its own
      // relayout boundary: layout dirt stops there. An *intrinsic* dependency
      // does not, because the parent's content width still comes from below.
      final box = MeasuredBox(const Size(40, 20));
      final proxy = CountingProxy(
        childConstraints: BoxConstraints.tight(const Size(40, 20)),
        child: box,
      );
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(200, 200)),
      )..root = proxy;
      owner.flushLayout();

      expect(box.isRelayoutBoundary, isTrue);
      expect(proxy.getMaxIntrinsicWidth(inf), 40);

      box.preferredSize = const Size(70, 20);

      expect(proxy.getMaxIntrinsicWidth(inf), 70);
    });

    test('a layout drops the answers that described the previous one', () {
      final box = MeasuredBox(const Size(40, 20));
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(200, 200)),
      )..root = box;

      expect(box.getMaxIntrinsicWidth(inf), 40);
      expect(box.intrinsicComputeCount, 1);

      owner.flushLayout();

      expect(box.getMaxIntrinsicWidth(inf), 40);
      expect(box.intrinsicComputeCount, 2);
    });
  });

  group('the rules', () {
    test('an intrinsic query may not lay anything out', () {
      final node = IllegalIntrinsic(child: MeasuredBox(const Size(10, 10)));

      expect(
        () => node.getMaxIntrinsicWidth(inf),
        throwsA(isA<LayoutDuringIntrinsicError>()),
      );
    });

    test('the ban lifts once the query is over', () {
      final node = IllegalIntrinsic(child: MeasuredBox(const Size(10, 10)));
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(50, 50)),
      )..root = node;

      expect(
        () => node.getMaxIntrinsicWidth(inf),
        throwsA(isA<LayoutDuringIntrinsicError>()),
      );
      // The depth counter is unwound in a finally, so a caught violation does
      // not poison every later layout in the process.
      owner.flushLayout();
      expect(node.size, const Size(50, 50));
    });

    test('a NaN cross extent is refused rather than propagated', () {
      final box = MeasuredBox(const Size(40, 20));

      expect(() => box.getMaxIntrinsicHeight(double.nan), throwsArgumentError);
    });
  });

  group('text', () {
    test('a single line will not claim it can be narrower than it draws', () {
      final text = RenderText('a reasonably long label', fontSize: 14);
      final natural = text.getMaxIntrinsicWidth(inf);

      expect(natural, greaterThan(0));
      // No wrapping, so there is no narrower width at which the whole string
      // still fits. Claiming otherwise would have a grid column size itself to
      // a "longest word" this node then overruns.
      expect(text.getMinIntrinsicWidth(inf), natural);
      expect(text.getMinIntrinsicHeight(inf), text.getMaxIntrinsicHeight(inf));
    });

    test('the intrinsic width is the width layout settles on', () {
      final text = RenderText('measure me', fontSize: 14);
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.loose(const Size(1000, 1000)),
      )..root = text;
      owner.flushLayout();

      expect(text.size.width, text.getMaxIntrinsicWidth(inf));
      expect(text.size.height, text.getMaxIntrinsicHeight(inf));
    });

    test('empty text asks for no width', () {
      expect(RenderText('', fontSize: 14).getMaxIntrinsicWidth(inf), 0);
    });
  });
}
