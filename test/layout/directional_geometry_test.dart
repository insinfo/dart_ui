/// Logical edges resolving to physical ones.
///
/// The claim under test is narrow and easy to get backwards: a *directional*
/// inset or alignment swaps its horizontal pair in a right-to-left locale, and
/// a plain one never does, no matter what it is nested inside. Every assertion
/// here is a number, because "it flipped" and "it flipped the wrong way" are
/// indistinguishable from a boolean.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  const TextDirection ltr = TextDirection.leftToRight;
  const TextDirection rtl = TextDirection.rightToLeft;

  group('EdgeInsetsDirectional', () {
    const EdgeInsetsDirectional insets = EdgeInsetsDirectional.only(
      start: 16,
      top: 4,
      end: 8,
      bottom: 2,
    );

    test('start becomes left under left-to-right', () {
      expect(
        insets.resolve(ltr),
        const EdgeInsets.only(left: 16, top: 4, right: 8, bottom: 2),
      );
    });

    test('start becomes right under right-to-left', () {
      expect(
        insets.resolve(rtl),
        const EdgeInsets.only(left: 8, top: 4, right: 16, bottom: 2),
      );
    });

    test('the vertical edges never move', () {
      expect(insets.resolve(ltr).top, 4);
      expect(insets.resolve(rtl).top, 4);
      expect(insets.resolve(ltr).bottom, 2);
      expect(insets.resolve(rtl).bottom, 2);
    });

    test('the axis totals are the same in both directions', () {
      // Swapping two numbers cannot change their sum, and a layout that
      // deflates by `horizontal` must therefore be direction-independent.
      expect(insets.horizontal, 24);
      expect(insets.resolve(ltr).horizontal, 24);
      expect(insets.resolve(rtl).horizontal, 24);
      expect(insets.vertical, 6);
    });

    test('resolving twice through the same direction is stable', () {
      // resolve() returns an EdgeInsets, which resolves to itself: a value
      // that has already been made physical cannot be flipped a second time
      // by a right-to-left ancestor further up.
      final EdgeInsets once = insets.resolve(rtl);
      expect(once.resolve(rtl), once);
      expect(once.resolve(ltr), once);
    });

    test('the inner origin lands on the resolved leading edge', () {
      const EdgeInsetsDirectional lead = EdgeInsetsDirectional.only(start: 16);
      expect(lead.resolve(ltr).topLeft, const Offset(16, 0));
      // Under right-to-left the 16 is on the right, so the child's own origin
      // is flush with the left edge.
      expect(lead.resolve(rtl).topLeft, Offset.zero);
    });

    test('deflateRect trims the resolved side', () {
      const Rect box = Rect.fromLTRB(0, 0, 100, 50);
      expect(
        const EdgeInsetsDirectional.only(start: 10, end: 4)
            .resolve(ltr)
            .deflateRect(box),
        const Rect.fromLTRB(10, 0, 96, 50),
      );
      expect(
        const EdgeInsetsDirectional.only(start: 10, end: 4)
            .resolve(rtl)
            .deflateRect(box),
        const Rect.fromLTRB(4, 0, 90, 50),
      );
    });

    test('symmetric and all are direction-proof by construction', () {
      const EdgeInsetsDirectional even = EdgeInsetsDirectional.all(5);
      expect(even.resolve(ltr), even.resolve(rtl));
      expect(even.resolve(rtl), const EdgeInsets.all(5));
      const EdgeInsetsDirectional sym =
          EdgeInsetsDirectional.symmetric(horizontal: 7, vertical: 3);
      expect(sym.resolve(ltr), sym.resolve(rtl));
    });

    test('addition and scaling stay in logical space', () {
      const EdgeInsetsDirectional a = EdgeInsetsDirectional.only(start: 4);
      const EdgeInsetsDirectional b = EdgeInsetsDirectional.only(end: 6);
      expect((a + b).resolve(ltr), const EdgeInsets.only(left: 4, right: 6));
      expect((a + b).resolve(rtl), const EdgeInsets.only(left: 6, right: 4));
      expect(
        (insets * 2).resolve(ltr),
        const EdgeInsets.only(left: 32, top: 8, right: 16, bottom: 4),
      );
    });

    test('zero, isZero, equality and toString', () {
      expect(EdgeInsetsDirectional.zero.isZero, isTrue);
      expect(EdgeInsetsDirectional.zero.resolve(rtl), EdgeInsets.zero);
      expect(insets.isZero, isFalse);
      expect(insets, const EdgeInsetsDirectional(16, 4, 8, 2));
      expect(
        insets.hashCode,
        const EdgeInsetsDirectional(16, 4, 8, 2).hashCode,
      );
      expect(insets.toString(), 'EdgeInsetsDirectional(16.0, 4.0, 8.0, 2.0)');
    });

    test('is not equal to the EdgeInsets it resolves to', () {
      // The two carry different promises; conflating them is how a logical
      // value ends up stored where a physical one was expected.
      expect(
        const EdgeInsetsDirectional.only(start: 16) ==
            const EdgeInsets.only(left: 16),
        isFalse,
      );
    });
  });

  group('EdgeInsets is never directional', () {
    const EdgeInsets physical = EdgeInsets.only(left: 16, right: 4);

    test('resolve returns the identical instance in both directions', () {
      // The strongest form of the guarantee: not merely equal, the same
      // object, so there is no arithmetic left that could go the other way.
      expect(identical(physical.resolve(ltr), physical), isTrue);
      expect(identical(physical.resolve(rtl), physical), isTrue);
    });

    test('left stays left when a right-to-left value is resolved beside it',
        () {
      // The pairing that goes wrong in practice: both spellings in one layout,
      // resolved with the same direction. Only one of them moves.
      const EdgeInsetsDirectional logical =
          EdgeInsetsDirectional.only(start: 16, end: 4);
      expect(physical.resolve(rtl).left, 16);
      expect(logical.resolve(rtl).left, 4);
    });

    test('RenderPadding under a right-to-left resolution keeps physical edges',
        () {
      // Numeric, through the real padding node: the child's origin is 16 in
      // from the left because the inset said `left`, and no direction changes
      // that.
      final FixedBox child = FixedBox(const Size(10, 10));
      final RenderPadding padding =
          RenderPadding(padding: physical.resolve(rtl), child: child);
      final PipelineOwner owner = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(100, 50)),
      )..root = padding;
      owner.flushLayout();

      expect(child.offsetFromParent, const Offset(16, 0));
    });

    test('the same numbers spelled logically do move', () {
      final FixedBox child = FixedBox(const Size(10, 10));
      final RenderPadding padding = RenderPadding(
        padding:
            const EdgeInsetsDirectional.only(start: 16, end: 4).resolve(rtl),
        child: child,
      );
      final PipelineOwner owner = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(100, 50)),
      )..root = padding;
      owner.flushLayout();

      // start:16 landed on the right, so the left inset is the end's 4.
      expect(child.offsetFromParent, const Offset(4, 0));
    });
  });

  group('AlignmentDirectional', () {
    test('the named corners resolve to their physical twins', () {
      expect(
          AlignmentDirectional.centerStart.resolve(ltr), Alignment.centerLeft);
      expect(
        AlignmentDirectional.centerStart.resolve(rtl),
        Alignment.centerRight,
      );
      expect(AlignmentDirectional.topEnd.resolve(ltr), Alignment.topRight);
      expect(AlignmentDirectional.topEnd.resolve(rtl), Alignment.topLeft);
      expect(
          AlignmentDirectional.bottomStart.resolve(rtl), Alignment.bottomRight);
    });

    test('the vertical axis is untouched', () {
      expect(AlignmentDirectional.topStart.resolve(rtl).y, -1);
      expect(AlignmentDirectional.bottomEnd.resolve(rtl).y, 1);
      expect(AlignmentDirectional.topCenter.resolve(rtl), Alignment.topCenter);
    });

    test('centre resolves to centre either way', () {
      expect(AlignmentDirectional.center.resolve(ltr), Alignment.center);
      expect(AlignmentDirectional.center.resolve(rtl), Alignment.center);
    });

    test('offsetFor is mirrored exactly', () {
      const Size child = Size(20, 10);
      const Size parent = Size(100, 50);
      expect(
        AlignmentDirectional.centerStart.resolve(ltr).offsetFor(child, parent),
        const Offset(0, 20),
      );
      expect(
        AlignmentDirectional.centerStart.resolve(rtl).offsetFor(child, parent),
        const Offset(80, 20),
      );
    });

    test('Alignment never resolves away from its physical edge', () {
      expect(identical(Alignment.centerLeft.resolve(rtl), Alignment.centerLeft),
          isTrue);
      expect(
        Alignment.centerLeft.resolve(rtl).offsetFor(
              const Size(20, 10),
              const Size(100, 50),
            ),
        const Offset(0, 20),
      );
    });

    test('extrapolation past the edge survives the flip', () {
      // A slide-in written as start:-2 comes in from the leading edge in both
      // locales, which is the reason the type refuses to clamp.
      expect(AlignmentDirectional(-2, 0).resolve(ltr), Alignment(-2, 0));
      expect(AlignmentDirectional(-2, 0).resolve(rtl), Alignment(2, 0));
    });

    test('lerp commutes with resolve, because negation is linear', () {
      final AlignmentDirectional mid = AlignmentDirectional.lerp(
        AlignmentDirectional.centerStart,
        AlignmentDirectional.centerEnd,
        0.25,
      );
      expect(mid.start, -0.5);
      expect(
          mid.resolve(rtl),
          Alignment.lerp(
            AlignmentDirectional.centerStart.resolve(rtl),
            AlignmentDirectional.centerEnd.resolve(rtl),
            0.25,
          ));
    });

    test('NaN is rejected on the logical axis too', () {
      expect(() => AlignmentDirectional(double.nan, 0), throwsArgumentError);
      expect(() => AlignmentDirectional(0, double.nan), throwsArgumentError);
    });

    test('equality, hashCode and toString', () {
      expect(AlignmentDirectional(-1, 0), AlignmentDirectional.centerStart);
      expect(
        AlignmentDirectional(-1, 0).hashCode,
        AlignmentDirectional.centerStart.hashCode,
      );
      expect(
        AlignmentDirectional.centerStart.toString(),
        'AlignmentDirectional(-1.0, 0.0)',
      );
      // Distinct from the Alignment it resolves to, same as the insets.
      expect(AlignmentDirectional(-1, 0) == Alignment.centerLeft, isFalse);
    });

    test('RenderAlign places a child at the resolved edge', () {
      final FixedBox child = FixedBox(const Size(20, 10));
      final RenderAlign align = RenderAlign(
        alignment: AlignmentDirectional.centerStart.resolve(rtl),
        child: child,
      );
      final PipelineOwner owner = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(100, 50)),
      )..root = align;
      owner.flushLayout();

      expect(child.offsetFromParent, const Offset(80, 20));
    });
  });
}
