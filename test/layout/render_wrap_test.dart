/// Wrapping runs: where the break falls, and where the children land.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  RenderWrap laidOut(RenderWrap wrap, BoxConstraints constraints) {
    final owner = PipelineOwner(rootConstraints: constraints)..root = wrap;
    owner.flushLayout();
    return wrap;
  }

  RenderWrap chips(
    int count,
    Size size, {
    double spacing = 0,
    double runSpacing = 0,
    MainAxisAlignment alignment = MainAxisAlignment.start,
    WrapCrossAlignment crossAxisAlignment = WrapCrossAlignment.start,
  }) {
    final wrap = RenderWrap(
      spacing: spacing,
      runSpacing: runSpacing,
      alignment: alignment,
      crossAxisAlignment: crossAxisAlignment,
    );
    for (int i = 0; i < count; i++) {
      wrap.add(MeasuredBox(size));
    }
    return wrap;
  }

  group('where the break falls', () {
    test('a line that exactly fits does not break', () {
      // 40 + 10 + 40 + 10 + 40 is 140 on the nose.
      final wrap = chips(3, const Size(40, 20), spacing: 10);

      laidOut(wrap, BoxConstraints.loose(const Size(140, 500)));

      expect(wrap.runCount, 1);
      expect(wrap.childAt(2).offsetFromParent, const Offset(100, 0));
      expect(wrap.size, const Size(140, 20));
    });

    test('one pixel less and the last child starts a new run', () {
      final wrap = chips(3, const Size(40, 20), spacing: 10);

      laidOut(wrap, BoxConstraints.loose(const Size(139, 500)));

      expect(wrap.runCount, 2);
      expect(wrap.childAt(1).offsetFromParent, const Offset(50, 0));
      expect(wrap.childAt(2).offsetFromParent, const Offset(0, 20));
      expect(wrap.size, const Size(139, 40));
    });

    test('run spacing goes between runs and not after the last', () {
      final wrap = chips(3, const Size(40, 20), spacing: 10, runSpacing: 5);

      laidOut(wrap, BoxConstraints.loose(const Size(100, 500)));

      expect(wrap.runCount, 2);
      expect(wrap.childAt(0).offsetFromParent, Offset.zero);
      expect(wrap.childAt(1).offsetFromParent, const Offset(50, 0));
      expect(wrap.childAt(2).offsetFromParent, const Offset(0, 25));
      expect(wrap.size, const Size(100, 45));
    });

    test('an unbounded main axis never breaks', () {
      final wrap = chips(4, const Size(40, 20), spacing: 10);

      laidOut(wrap, BoxConstraints());

      expect(wrap.runCount, 1);
      expect(wrap.size, const Size(190, 20));
      expect(wrap.childAt(3).offsetFromParent.dx, 150);
    });
  });

  group('a child bigger than the line', () {
    test('gets a run to itself and is squeezed to the line width', () {
      final wrap = RenderWrap()
        ..add(MeasuredBox(const Size(60, 20)))
        ..add(MeasuredBox(const Size(200, 20)));

      laidOut(wrap, BoxConstraints.loose(const Size(100, 500)));

      expect(wrap.runCount, 2);
      expect(wrap.childAt(1).size, const Size(100, 20));
      expect(wrap.childAt(1).offsetFromParent, const Offset(0, 20));
      // The main axis cannot overflow: the child was constrained to the line.
      expect(wrap.overflow, 0);
    });

    test('as the only child it is still one run', () {
      final wrap = RenderWrap()..add(MeasuredBox(const Size(500, 20)));

      laidOut(wrap, BoxConstraints.loose(const Size(100, 500)));

      expect(wrap.runCount, 1);
      expect(wrap.childAt(0).offsetFromParent, Offset.zero);
    });
  });

  group('alignment', () {
    test('centre shares out the slack left in each run', () {
      final wrap = chips(
        3,
        const Size(40, 20),
        alignment: MainAxisAlignment.center,
      );

      laidOut(wrap, BoxConstraints.tightFor(width: 100));

      // Two chips of 40 fit in 100 with 20 to spare, so each run starts at 10.
      expect(wrap.runCount, 2);
      expect(wrap.childAt(0).offsetFromParent.dx, 10);
      expect(wrap.childAt(1).offsetFromParent.dx, 50);
      // The second run holds one chip and has 60 to spare.
      expect(wrap.childAt(2).offsetFromParent.dx, 30);
    });

    test('spaceBetween pushes the ends of a run apart', () {
      final wrap = chips(
        2,
        const Size(40, 20),
        alignment: MainAxisAlignment.spaceBetween,
      );

      laidOut(wrap, BoxConstraints.tightFor(width: 100));

      expect(wrap.childAt(0).offsetFromParent.dx, 0);
      expect(wrap.childAt(1).offsetFromParent.dx, 60);
    });

    test('the cross alignment places a short child inside its run', () {
      final short = MeasuredBox(const Size(20, 10));
      final wrap = RenderWrap(crossAxisAlignment: WrapCrossAlignment.center)
        ..add(MeasuredBox(const Size(20, 30)))
        ..add(short);

      laidOut(wrap, BoxConstraints.loose(const Size(100, 500)));

      expect(wrap.runCount, 1);
      expect(short.offsetFromParent.dy, 10);
    });
  });

  group('overflow', () {
    test('runs that do not fit are recorded, not clipped', () {
      final wrap = chips(4, const Size(40, 20));

      laidOut(wrap, BoxConstraints.tight(const Size(80, 30)));

      // Two runs of 20 need 40; the box allows 30.
      expect(wrap.runCount, 2);
      expect(wrap.size, const Size(80, 30));
      expect(wrap.overflow, 10);
      expect(wrap.hasOverflow, isTrue);
      expect(wrap.childAt(2).offsetFromParent, const Offset(0, 20));
    });
  });

  group('vertical', () {
    test('breaks on height and stacks runs sideways', () {
      final wrap = RenderWrap(direction: Axis.vertical, spacing: 5);
      for (int i = 0; i < 3; i++) {
        wrap.add(MeasuredBox(const Size(20, 30)));
      }

      laidOut(wrap, BoxConstraints.loose(const Size(500, 70)));

      // 30 + 5 + 30 fits in 70; the third does not.
      expect(wrap.runCount, 2);
      expect(wrap.childAt(1).offsetFromParent, const Offset(0, 35));
      expect(wrap.childAt(2).offsetFromParent, const Offset(20, 0));
    });
  });

  group('as a measurable child', () {
    test('its widest single child is its minimum, everything is its maximum',
        () {
      final wrap = RenderWrap(spacing: 6)
        ..add(MeasuredBox(const Size(30, 10)))
        ..add(MeasuredBox(const Size(50, 10)));

      expect(wrap.getMinIntrinsicWidth(double.infinity), 50);
      expect(wrap.getMaxIntrinsicWidth(double.infinity), 86);
    });
  });

  test('an empty wrap collapses', () {
    final wrap = RenderWrap();

    laidOut(wrap, BoxConstraints.loose(const Size(100, 100)));

    expect(wrap.size, Size.zero);
    expect(wrap.runCount, 0);
  });

  test('a negative gap is refused', () {
    expect(() => RenderWrap(spacing: -1), throwsArgumentError);
    expect(() => RenderWrap(runSpacing: double.nan), throwsArgumentError);
  });
}
