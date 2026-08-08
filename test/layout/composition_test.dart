/// Nodes composed the way a real tree composes them.
///
/// Each node is simple enough that its own test proves little; what has to
/// hold is that a padding inside an alignment inside a row produces the rect a
/// reader would predict by hand.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  PipelineOwner laidOut(RenderBox root, Size size) {
    final owner = PipelineOwner(rootConstraints: BoxConstraints.tight(size));
    owner.root = root;
    owner.flushLayout();
    return owner;
  }

  /// The child's rect in the coordinate space of [ancestor].
  Rect rectIn(RenderBox ancestor, RenderBox child) {
    double dx = 0;
    double dy = 0;
    for (RenderBox? node = child;
        node != null && node != ancestor;
        node = node.parent) {
      dx += node.offsetFromParent.dx;
      dy += node.offsetFromParent.dy;
    }
    return Rect.fromLTWH(dx, dy, child.size.width, child.size.height);
  }

  group('padding', () {
    test('insets the child and reports child plus padding', () {
      final child = FillBox();
      final padding = RenderPadding(
        padding: const EdgeInsets(4, 8, 16, 32),
        child: child,
      );

      laidOut(padding, const Size(100, 100));

      expect(child.size, const Size(80, 60));
      expect(child.offsetFromParent, const Offset(4, 8));
      expect(padding.size, const Size(100, 100));
    });

    test('shrink-wraps a smaller child under loose constraints', () {
      final child = FixedBox(const Size(10, 10));
      final padding =
          RenderPadding(padding: const EdgeInsets.all(5), child: child);
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.loose(const Size(100, 100)),
      );
      owner.root = padding;

      owner.flushLayout();

      expect(padding.size, const Size(20, 20));
    });

    test('padding larger than the box leaves the child nothing', () {
      final child = FillBox();
      final padding =
          RenderPadding(padding: const EdgeInsets.all(40), child: child);

      laidOut(padding, const Size(50, 50));

      expect(child.size, Size.zero);
      expect(padding.size, const Size(50, 50));
    });
  });

  group('padding and align compose', () {
    test('a centred fixed box inside a padded box lands where it should', () {
      // 200x100 outer, 10/20 padding, a 40x30 box centred in what is left.
      final leaf = FixedBox(const Size(40, 30));
      final align = RenderAlign(alignment: Alignment.center, child: leaf);
      final padding = RenderPadding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 20),
        child: align,
      );

      laidOut(padding, const Size(200, 100));

      // Padding leaves 180x60 starting at (10, 20). Align fills it, and the
      // 40x30 leaf centres in it: (180-40)/2 = 70 across, (60-30)/2 = 15 down.
      expect(align.size, const Size(180, 60));
      expect(rectIn(padding, leaf), const Rect.fromLTRB(80, 35, 120, 65));
    });

    test('alignment to a corner needs no arithmetic to predict', () {
      final leaf = FixedBox(const Size(40, 30));
      final padding = RenderPadding(
        padding: const EdgeInsets.all(10),
        child: RenderAlign(alignment: Alignment.bottomRight, child: leaf),
      );

      laidOut(padding, const Size(200, 100));

      expect(rectIn(padding, leaf), const Rect.fromLTRB(150, 60, 190, 90));
    });

    test('align shrink-wraps on an unbounded axis instead of taking all', () {
      final leaf = FixedBox(const Size(40, 30));
      final align = RenderAlign(child: leaf);
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints(maxHeight: 100),
      );
      owner.root = align;

      owner.flushLayout();

      expect(align.size, const Size(40, 100));
    });

    test('a width factor makes the box a multiple of its child', () {
      final leaf = FixedBox(const Size(40, 30));
      final align = RenderAlign(widthFactor: 2, child: leaf);
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.loose(const Size(200, 100)),
      );
      owner.root = align;

      owner.flushLayout();

      expect(align.size.width, 80);
      expect(leaf.offsetFromParent.dx, 20);
    });

    test('a negative factor is refused', () {
      expect(
        () => RenderAlign(widthFactor: -1),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('constrained box', () {
    test('narrows what the child is offered', () {
      final child = FillBox();
      final box = RenderConstrainedBox(
        additionalConstraints: BoxConstraints(maxWidth: 30),
        child: child,
      );
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints(minHeight: 100, maxHeight: 100),
      );
      owner.root = box;

      owner.flushLayout();

      expect(child.size, const Size(30, 100));
      expect(box.size, const Size(30, 100));
    });

    test('a tight parent leaves nothing to narrow', () {
      final child = FillBox();
      final box = RenderConstrainedBox(
        additionalConstraints: BoxConstraints(maxWidth: 30),
        child: child,
      );

      laidOut(box, const Size(100, 100));

      // enforce() clamps into the outer range, so under tight constraints the
      // additional ones have no room to act. Worth pinning down: it is the
      // most common surprise this node produces.
      expect(box.size, const Size(100, 100));
    });

    test('the parent wins when the request does not fit', () {
      final child = FillBox();
      final box = RenderConstrainedBox(
        additionalConstraints: BoxConstraints.tight(const Size(400, 400)),
        child: child,
      );

      laidOut(box, const Size(100, 100));

      // Not an overflow and not an exception: a constraint node expresses a
      // preference about the space it was given.
      expect(box.size, const Size(100, 100));
    });

    test('with no child it is a spacer at its own minimum', () {
      final box = RenderConstrainedBox(
        additionalConstraints: BoxConstraints(minWidth: 20, minHeight: 8),
      );
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.loose(const Size(100, 100)),
      );
      owner.root = box;

      owner.flushLayout();

      expect(box.size, const Size(20, 8));
    });
  });

  group('a row of padded, aligned children', () {
    test('composes into the rects a reader would predict', () {
      final left = FixedBox(const Size(20, 20));
      final right = FixedBox(const Size(20, 20));
      final row = RenderFlex(crossAxisAlignment: CrossAxisAlignment.stretch)
        ..add(
          RenderPadding(
            padding: const EdgeInsets.all(5),
            child: RenderAlign(alignment: Alignment.topLeft, child: left),
          ),
          flex: 1,
        )
        ..add(
          RenderPadding(
            padding: const EdgeInsets.all(5),
            child: RenderAlign(alignment: Alignment.center, child: right),
          ),
          flex: 1,
        );

      laidOut(row, const Size(200, 60));

      // Each half is 100 wide and 60 tall; padding leaves 90x50 at (5, 5).
      expect(rectIn(row, left), const Rect.fromLTRB(5, 5, 25, 25));
      // The right half starts at x = 100; its 20x20 box centres in 90x50.
      expect(rectIn(row, right), const Rect.fromLTRB(140, 20, 160, 40));
    });
  });

  group('stack', () {
    test('sizes to its largest non-positioned child and aligns the rest', () {
      final big = FixedBox(const Size(60, 40));
      final small = FixedBox(const Size(20, 10));
      final stack = RenderStack(alignment: Alignment.center)
        ..add(big)
        ..add(small);
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.loose(const Size(200, 200)),
      );
      owner.root = stack;

      owner.flushLayout();

      expect(stack.size, const Size(60, 40));
      expect(big.offsetFromParent, Offset.zero);
      expect(small.offsetFromParent, const Offset(20, 15));
    });

    test('expand forces every non-positioned child to fill', () {
      final child = FixedBox(const Size(10, 10));
      final stack = RenderStack(fit: StackFit.expand)..add(child);

      laidOut(stack, const Size(100, 50));

      expect(child.size, const Size(100, 50));
    });

    test('a child pinned to two edges is stretched between them', () {
      final child = FillBox();
      final stack = RenderStack()..add(child);
      stack.position(child, left: 10, right: 20, top: 5, height: 15);

      laidOut(stack, const Size(100, 50));

      expect(child.size, const Size(70, 15));
      expect(child.offsetFromParent, const Offset(10, 5));
    });

    test('one edge plus the alignment places the other axis', () {
      final child = FixedBox(const Size(20, 10));
      final stack = RenderStack(alignment: Alignment.center)..add(child);
      stack.position(child, bottom: 4);

      laidOut(stack, const Size(100, 50));

      // Pinned 4 from the bottom, centred horizontally.
      expect(child.offsetFromParent, const Offset(40, 36));
    });

    test('positioned children do not decide the size', () {
      final child = FixedBox(const Size(10, 10));
      final stack = RenderStack()..add(child);
      stack.position(child, left: 500, top: 500);
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.loose(const Size(80, 80)),
      );
      owner.root = stack;

      owner.flushLayout();

      // No non-positioned child, so the stack fills what it is allowed rather
      // than growing to contain something that could never settle.
      expect(stack.size, const Size(80, 80));
      expect(child.offsetFromParent, const Offset(500, 500));
    });
  });
}
