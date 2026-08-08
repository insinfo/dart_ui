import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  /// Lays [flex] out under a tight box of [size] and returns it.
  RenderFlex laidOut(RenderFlex flex, Size size) {
    final owner = PipelineOwner(rootConstraints: BoxConstraints.tight(size));
    owner.root = flex;
    owner.flushLayout();
    return flex;
  }

  Offset offsetOf(RenderBox child) => child.offsetFromParent;

  group('flex division', () {
    test('two equal flex children split the free space', () {
      final a = FillBox();
      final b = FillBox();
      final flex = RenderFlex()
        ..add(a, flex: 1)
        ..add(b, flex: 1);

      laidOut(flex, const Size(100, 20));

      expect(a.size, const Size(50, 20));
      expect(b.size, const Size(50, 20));
      expect(offsetOf(a), Offset.zero);
      expect(offsetOf(b), const Offset(50, 0));
      expect(flex.hasOverflow, isFalse);
    });

    test('unequal factors split it proportionally', () {
      final a = FillBox();
      final b = FillBox();
      final flex = RenderFlex()
        ..add(a, flex: 1)
        ..add(b, flex: 3);

      laidOut(flex, const Size(120, 20));

      expect(a.size.width, 30);
      expect(b.size.width, 90);
      expect(offsetOf(b), const Offset(30, 0));
    });

    test('the last flexible child takes the remainder, so no gap is left', () {
      final a = FillBox();
      final b = FillBox();
      final c = FillBox();
      final flex = RenderFlex()
        ..add(a, flex: 1)
        ..add(b, flex: 1)
        ..add(c, flex: 1);

      // 100 / 3 does not divide evenly; the row must still be exactly full.
      laidOut(flex, const Size(100, 10));

      expect(a.size.width + b.size.width + c.size.width, 100);
      expect(offsetOf(c).dx + c.size.width, 100);
    });

    test('fixed children are measured first and flex takes what is left', () {
      final fixed = FixedBox(const Size(40, 10));
      final flexible = FillBox();
      final flex = RenderFlex()
        ..add(fixed)
        ..add(flexible, flex: 1);

      laidOut(flex, const Size(100, 20));

      expect(fixed.size, const Size(40, 10));
      expect(flexible.size.width, 60);
      expect(offsetOf(flexible), const Offset(40, 0));
    });

    test('a loose fit may be smaller than its share', () {
      final loose = FixedBox(const Size(10, 10));
      final tight = FillBox();
      final flex = RenderFlex()
        ..add(loose, flex: 1, fit: FlexFit.loose)
        ..add(tight, flex: 1);

      laidOut(flex, const Size(100, 20));

      expect(loose.size.width, 10);
      // The surplus is not handed to the sibling: the division stays
      // proportional, and the row is left with a hole rather than a silently
      // reweighted layout.
      expect(tight.size.width, 50);
      expect(flex.hasOverflow, isFalse);
    });

    test('an unbounded main axis makes flexible children natural-sized', () {
      final flexible = FixedBox(const Size(25, 10));
      final flex = RenderFlex()..add(flexible, flex: 1);
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints(maxHeight: 20),
      );
      owner.root = flex;

      owner.flushLayout();

      expect(flexible.size.width, 25);
      expect(flex.size.width, 25);
    });

    test('a negative flex factor is refused', () {
      expect(
        () => RenderFlex().add(FillBox(), flex: -1),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('main axis alignment', () {
    RenderFlex rowOfTwenties(MainAxisAlignment alignment) => RenderFlex(
          mainAxisAlignment: alignment,
        )
          ..add(FixedBox(const Size(20, 10)))
          ..add(FixedBox(const Size(20, 10)));

    test('start leaves the free space at the end', () {
      final flex = laidOut(
        rowOfTwenties(MainAxisAlignment.start),
        const Size(100, 10),
      );

      expect(offsetOf(flex.childAt(0)).dx, 0);
      expect(offsetOf(flex.childAt(1)).dx, 20);
    });

    test('end pushes everything to the trailing edge', () {
      final flex = laidOut(
        rowOfTwenties(MainAxisAlignment.end),
        const Size(100, 10),
      );

      expect(offsetOf(flex.childAt(0)).dx, 60);
      expect(offsetOf(flex.childAt(1)).dx, 80);
    });

    test('center splits the free space evenly at the two ends', () {
      final flex = laidOut(
        rowOfTwenties(MainAxisAlignment.center),
        const Size(100, 10),
      );

      expect(offsetOf(flex.childAt(0)).dx, 30);
      expect(offsetOf(flex.childAt(1)).dx, 50);
    });

    test('spaceBetween puts it all between the children', () {
      final flex = laidOut(
        rowOfTwenties(MainAxisAlignment.spaceBetween),
        const Size(100, 10),
      );

      expect(offsetOf(flex.childAt(0)).dx, 0);
      expect(offsetOf(flex.childAt(1)).dx, 80);
    });

    test('spaceAround gives the ends half a gap each', () {
      final flex = laidOut(
        rowOfTwenties(MainAxisAlignment.spaceAround),
        const Size(100, 10),
      );

      // 60 free / 2 children = 30 per child, half of it at each end.
      expect(offsetOf(flex.childAt(0)).dx, 15);
      expect(offsetOf(flex.childAt(1)).dx, 65);
    });

    test('spaceEvenly gives every gap the same width', () {
      final flex = laidOut(
        rowOfTwenties(MainAxisAlignment.spaceEvenly),
        const Size(100, 10),
      );

      expect(offsetOf(flex.childAt(0)).dx, 20);
      expect(offsetOf(flex.childAt(1)).dx, 60);
    });

    test('mainAxisSize.min shrink-wraps the children', () {
      final flex = RenderFlex(mainAxisSize: MainAxisSize.min)
        ..add(FixedBox(const Size(20, 10)))
        ..add(FixedBox(const Size(30, 10)));
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.loose(const Size(100, 100)),
      );
      owner.root = flex;

      owner.flushLayout();

      expect(flex.size.width, 50);
    });
  });

  group('cross axis alignment', () {
    (RenderFlex, FixedBox) rowWith(CrossAxisAlignment alignment) {
      final child = FixedBox(const Size(30, 20));
      final flex = RenderFlex(crossAxisAlignment: alignment)..add(child);
      laidOut(flex, const Size(100, 50));
      return (flex, child);
    }

    test('start leaves the child its own height at the top', () {
      final (_, child) = rowWith(CrossAxisAlignment.start);

      expect(child.size, const Size(30, 20));
      expect(offsetOf(child).dy, 0);
    });

    test('center offsets by half the leftover', () {
      final (_, child) = rowWith(CrossAxisAlignment.center);

      expect(child.size.height, 20);
      expect(offsetOf(child).dy, 15);
    });

    test('end pins the child to the bottom', () {
      final (_, child) = rowWith(CrossAxisAlignment.end);

      expect(offsetOf(child).dy, 30);
    });

    test('stretch makes the cross axis tight instead of aligning', () {
      final (_, child) = rowWith(CrossAxisAlignment.stretch);

      expect(child.size, const Size(30, 50));
      expect(offsetOf(child).dy, 0);
    });

    test(
        'stretch against an unbounded cross axis says so instead of '
        'guessing', () {
      final flex = RenderFlex(crossAxisAlignment: CrossAxisAlignment.stretch)
        ..add(FixedBox(const Size(10, 10)));
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints(maxWidth: 100),
      );
      owner.root = flex;

      expect(
        () => owner.flushLayout(),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            allOf(contains('stretch'), contains('unbounded')),
          ),
        ),
      );
    });

    test('the flex is as tall as its tallest child', () {
      final flex = RenderFlex()
        ..add(FixedBox(const Size(10, 12)))
        ..add(FixedBox(const Size(10, 31)));
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.loose(const Size(100, 100)),
      );
      owner.root = flex;

      owner.flushLayout();

      expect(flex.size.height, 31);
    });
  });

  group('overflow', () {
    test(
        'children keep their size and position, and the excess is '
        'reported', () {
      final a = FixedBox(const Size(60, 10));
      final b = FixedBox(const Size(60, 10));
      final flex = RenderFlex()
        ..add(a)
        ..add(b);

      laidOut(flex, const Size(100, 10));

      // The node itself never lies to its parent about its size.
      expect(flex.size, const Size(100, 10));
      // The children are not squeezed, not clipped, and not hidden.
      expect(a.size.width, 60);
      expect(b.size.width, 60);
      expect(offsetOf(b).dx, 60);
      // And the amount is available to a debug overlay or a test.
      expect(flex.overflow, 20);
      expect(flex.hasOverflow, isTrue);
    });

    test('an overflowing row starts at the leading edge, not before it', () {
      final flex = RenderFlex(mainAxisAlignment: MainAxisAlignment.center)
        ..add(FixedBox(const Size(80, 10)))
        ..add(FixedBox(const Size(80, 10)));

      laidOut(flex, const Size(100, 10));

      // Free space is clamped at zero: a negative leading offset would hide
      // the beginning of the content instead of the end.
      expect(offsetOf(flex.childAt(0)).dx, 0);
      expect(flex.overflow, 60);
    });

    test('the cross axis cannot overflow: a tall child is squeezed', () {
      final child = FixedBox(const Size(10, 90));
      final flex = RenderFlex()..add(child);

      laidOut(flex, const Size(100, 40));

      // The opposite policy from the main axis, and deliberately so: the cross
      // axis is not a shared budget, so the child's maximum is simply the
      // row's own height and there is nothing left over to report.
      expect(child.size.height, 40);
      expect(flex.overflow, 0);
      expect(flex.hasOverflow, isFalse);
    });
  });

  group('columns', () {
    test('a column divides the vertical axis the same way', () {
      final a = FillBox();
      final b = FixedBox(const Size(10, 30));
      final flex = RenderFlex(direction: Axis.vertical)
        ..add(b)
        ..add(a, flex: 1);

      laidOut(flex, const Size(50, 100));

      expect(b.size.height, 30);
      expect(a.size.height, 70);
      expect(offsetOf(a), const Offset(0, 30));
    });

    test('stretch in a column tightens the width', () {
      final child = FixedBox(const Size(10, 10));
      final flex = RenderFlex(
        direction: Axis.vertical,
        crossAxisAlignment: CrossAxisAlignment.stretch,
      )..add(child);

      laidOut(flex, const Size(50, 100));

      expect(child.size.width, 50);
    });
  });

  group('children', () {
    test('hit testing prefers the child painted last', () {
      final flex = RenderFlex()
        ..add(FixedBox(const Size(50, 10)))
        ..add(FixedBox(const Size(50, 10)));

      laidOut(flex, const Size(100, 10));

      expect(flex.hitTest(const Offset(75, 5)), same(flex.childAt(1)));
      expect(flex.hitTest(const Offset(25, 5)), same(flex.childAt(0)));
    });

    test('removing a child drops it from the tree and dirties layout', () {
      final child = FixedBox(const Size(10, 10));
      final flex = RenderFlex()..add(child);
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(50, 50)),
      );
      owner.root = flex;
      owner.flushLayout();

      flex.remove(child);

      expect(child.parent, isNull);
      expect(flex.childCount, 0);
      expect(owner.needsLayout, isTrue);
    });

    test('setFlex re-divides on the next pass', () {
      final a = FillBox();
      final b = FillBox();
      final flex = RenderFlex()
        ..add(a, flex: 1)
        ..add(b, flex: 1);
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(100, 10)),
      );
      owner.root = flex;
      owner.flushLayout();

      flex.setFlex(a, 4);
      owner.flushLayout();

      expect(a.size.width, 80);
      expect(b.size.width, 20);
    });
  });
}
