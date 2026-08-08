import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Lays its child out without asking for its size, then reads it anyway. The
/// exact mistake `RenderBox.size` exists to catch.
final class _PeekingProxy extends RenderSingleChildBox {
  _PeekingProxy({super.child});

  @override
  void performLayout() {
    final RenderBox child = this.child!;
    child.layout(constraints, parentUsesSize: false);
    size = constraints.constrain(child.size);
  }
}

/// The same, but keeping its promise: it never reads the child's size.
///
/// Loose constraints on purpose, so the boundary the test observes can only
/// have come from `parentUsesSize: false` and not from tightness.
final class _HonestProxy extends RenderSingleChildBox {
  _HonestProxy({super.child});

  @override
  void performLayout() {
    child!.layout(constraints.loosen(), parentUsesSize: false);
    size = constraints.largestFinite;
  }
}

/// Assigns nothing, which the layout driver must notice.
final class _ForgetfulBox extends RenderBox {
  @override
  void performLayout() {}
}

/// Reports a size its constraints forbid.
final class _DisobedientBox extends RenderBox {
  @override
  void performLayout() {
    size = const Size(1000, 1000);
  }
}

void main() {
  PipelineOwner ownerWith(RenderBox root, {Size size = const Size(200, 200)}) {
    final owner = PipelineOwner(rootConstraints: BoxConstraints.tight(size));
    owner.root = root;
    return owner;
  }

  group('the layout contract', () {
    test('constraints go down and a size comes up', () {
      final leaf = FixedBox(const Size(20, 10));
      final owner = ownerWith(leaf);

      owner.flushLayout();

      expect(leaf.size, const Size(200, 200));
      expect(leaf.constraints, BoxConstraints.tight(const Size(200, 200)));
      expect(leaf.layoutCount, 1);
    });

    test('reading size before layout says so', () {
      final leaf = FixedBox(const Size(20, 10));

      expect(
        () => leaf.size,
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            contains('layout() has not run'),
          ),
        ),
      );
      expect(() => leaf.constraints, throwsA(isA<StateError>()));
    });

    test('a performLayout that assigns no size is refused', () {
      final owner = ownerWith(_ForgetfulBox());

      expect(
        () => owner.flushLayout(),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            contains('without assigning size'),
          ),
        ),
      );
    });

    test('a size that violates the constraints is refused', () {
      final owner = ownerWith(_DisobedientBox());

      expect(
        () => owner.flushLayout(),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            contains('does not satisfy'),
          ),
        ),
      );
    });

    test('a parent cannot assign its child a size', () {
      final leaf = FixedBox(const Size(20, 10));
      ownerWith(leaf).flushLayout();

      // The setter is only legal from inside the node's own performLayout.
      expect(
        () => leaf.preferredSize = const Size(1, 1),
        returnsNormally,
      );
    });
  });

  group('parentUsesSize', () {
    test('reading a size you did not ask for throws, naming the fix', () {
      final owner = ownerWith(_PeekingProxy(child: FixedBox(const Size(5, 5))));

      expect(
        () => owner.flushLayout(),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            allOf(
              contains('parentUsesSize: false'),
              contains('parentUsesSize: true'),
            ),
          ),
        ),
      );
    });

    test('not reading it is fine, and makes the child a boundary', () {
      final leaf = FixedBox(const Size(5, 5));
      final owner = ownerWith(_HonestProxy(child: leaf));

      owner.flushLayout();

      expect(leaf.isRelayoutBoundary, isTrue);
      // Readable outside layout: the check is about a parent depending on the
      // value while it computes its own geometry, not about privacy.
      expect(leaf.size, const Size(5, 5));
    });

    test('a size read outside layout is always allowed', () {
      final leaf = FixedBox(const Size(5, 5));
      ownerWith(_HonestProxy(child: leaf)).flushLayout();

      expect(leaf.size, const Size(5, 5));
    });
  });

  group('relayout boundary', () {
    // The tree in both tests below is the same except for one thing: whether
    // the middle node passes tight constraints. That single difference is what
    // the whole mechanism turns on.
    (CountingProxy, CountingProxy, FixedBox, PipelineOwner) treeWith({
      required BoxConstraints middleGives,
    }) {
      final leaf = FixedBox(const Size(20, 10));
      final middle = CountingProxy(childConstraints: middleGives, child: leaf);
      final outer = CountingProxy(
        childConstraints: BoxConstraints.loose(const Size(200, 200)),
        child: middle,
      );
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(200, 200)),
      );
      owner.root = outer;
      owner.flushLayout();
      return (outer, middle, leaf, owner);
    }

    test('tight constraints stop the dirt at the subtree', () {
      final (outer, middle, leaf, owner) = treeWith(
        middleGives: BoxConstraints.tight(const Size(100, 50)),
      );

      expect(leaf.isRelayoutBoundary, isTrue);
      expect(middle.relayoutBoundary, same(outer));

      leaf.preferredSize = const Size(30, 30);

      // The claim: nothing above the leaf even knows.
      expect(leaf.needsLayout, isTrue);
      expect(middle.needsLayout, isFalse);
      expect(outer.needsLayout, isFalse);
      expect(owner.nodesNeedingLayout, <RenderBox>[leaf]);

      final int outerBefore = outer.layoutCount;
      final int middleBefore = middle.layoutCount;
      final int leafBefore = leaf.layoutCount;
      owner.flushLayout();

      expect(leaf.layoutCount, leafBefore + 1);
      expect(middle.layoutCount, middleBefore);
      expect(outer.layoutCount, outerBefore);
      // And the subtree still satisfies the constraints it was frozen at.
      expect(leaf.size, const Size(100, 50));
    });

    test('loose constraints let the dirt reach the root', () {
      final (outer, middle, leaf, owner) = treeWith(
        middleGives: BoxConstraints.loose(const Size(100, 50)),
      );

      expect(leaf.isRelayoutBoundary, isFalse);
      expect(leaf.relayoutBoundary, same(outer));

      leaf.preferredSize = const Size(30, 30);

      expect(middle.needsLayout, isTrue);
      expect(outer.needsLayout, isTrue);
      expect(owner.nodesNeedingLayout, <RenderBox>[outer]);

      final int outerBefore = outer.layoutCount;
      owner.flushLayout();

      expect(outer.layoutCount, outerBefore + 1);
      expect(leaf.size, const Size(30, 30));
    });

    test('a boundary relayouts without the root being visited', () {
      final (outer, _, leaf, owner) = treeWith(
        middleGives: BoxConstraints.tight(const Size(100, 50)),
      );

      leaf.preferredSize = const Size(1, 1);
      owner.flushLayout();
      leaf.preferredSize = const Size(2, 2);
      owner.flushLayout();

      expect(outer.layoutCount, 1);
      expect(leaf.layoutCount, 3);
    });

    test('a node that never got a parent is its own boundary', () {
      final leaf = FixedBox(const Size(20, 10));
      ownerWith(leaf).flushLayout();

      expect(leaf.isRelayoutBoundary, isTrue);
    });
  });

  group('tree structure', () {
    test('a node cannot end up in two trees', () {
      final shared = FixedBox(const Size(10, 10));
      RenderPadding(padding: const EdgeInsets.all(1), child: shared);

      expect(
        () => RenderPadding(padding: const EdgeInsets.all(2), child: shared),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            contains('already has a parent'),
          ),
        ),
      );
    });

    test('a node cannot become its own ancestor', () {
      final padding = RenderPadding(padding: EdgeInsets.zero);

      expect(() => padding.child = padding, throwsA(isA<StateError>()));
    });

    test('removing a child clears its parent and its parent data', () {
      final leaf = FixedBox(const Size(10, 10));
      final padding =
          RenderPadding(padding: const EdgeInsets.all(1), child: leaf);

      padding.child = null;

      expect(leaf.parent, isNull);
      expect(leaf.parentData, isNull);
      expect(padding.child, isNull);
    });

    test('a detached child can be re-parented', () {
      final leaf = FixedBox(const Size(10, 10));
      final first = RenderPadding(padding: EdgeInsets.zero, child: leaf);
      first.child = null;

      final second = RenderPadding(padding: EdgeInsets.zero, child: leaf);

      expect(leaf.parent, same(second));
    });

    test('attaching a subtree gives every node the owner and a depth', () {
      final leaf = FixedBox(const Size(10, 10));
      final inner = RenderPadding(padding: EdgeInsets.zero, child: leaf);
      final outer = RenderColoredBox(color: 0xFF000000, child: inner);
      final owner = ownerWith(outer);

      expect(leaf.owner, same(owner));
      expect(outer.depth, 0);
      expect(inner.depth, 1);
      expect(leaf.depth, 2);
    });

    test('a root with a parent is refused', () {
      final leaf = FixedBox(const Size(10, 10));
      RenderPadding(padding: EdgeInsets.zero, child: leaf);

      expect(
        () => PipelineOwner().root = leaf,
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            contains('two different owners'),
          ),
        ),
      );
    });
  });

  group('hit testing', () {
    // A 100x100 blue box, 10px of padding, then an 80x80 red box inside it.
    (RenderColoredBox, RenderPadding, RenderColoredBox) nestedTree() {
      final inner = RenderColoredBox(color: 0xFFFF0000);
      final padding =
          RenderPadding(padding: const EdgeInsets.all(10), child: inner);
      final outer = RenderColoredBox(color: 0xFF0000FF, child: padding);
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(100, 100)),
      );
      owner.root = outer;
      owner.flushLayout();
      return (outer, padding, inner);
    }

    test('returns the deepest node under the point', () {
      final (outer, _, inner) = nestedTree();

      expect(outer.hitTest(const Offset(50, 50)), same(inner));
    });

    test('falls back to an ancestor where the child does not reach', () {
      final (outer, _, _) = nestedTree();

      // Inside the padding, so no child is hit, but the coloured box itself is
      // opaque to pointers.
      expect(outer.hitTest(const Offset(5, 5)), same(outer));
    });

    test('misses outside the bounds', () {
      final (outer, _, _) = nestedTree();

      expect(outer.hitTest(const Offset(150, 50)), isNull);
      expect(outer.hitTest(const Offset(-1, 5)), isNull);
      // Half-open edges, inherited from Size.contains.
      expect(outer.hitTest(const Offset(100, 50)), isNull);
      expect(outer.hitTest(const Offset(99, 99)), isNotNull);
    });

    test('records the chain deepest first', () {
      final (outer, padding, inner) = nestedTree();
      final path = HitTestPath();

      final hit = outer.hitTest(const Offset(50, 50), path: path);

      expect(hit, same(inner));
      expect(path.entries, <RenderBox>[inner, padding, outer]);
    });

    test('a path is reusable, so dispatch need not allocate one per event', () {
      final (outer, _, _) = nestedTree();
      final path = HitTestPath();

      outer.hitTest(const Offset(50, 50), path: path);
      final int first = path.length;
      path.reset();
      outer.hitTest(const Offset(50, 50), path: path);

      expect(path.length, first);
    });

    test('a transparent node does not swallow the pointer', () {
      final padding = RenderPadding(padding: const EdgeInsets.all(10));
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(50, 50)),
      );
      owner.root = padding;
      owner.flushLayout();

      // Nothing is painted here, so nothing is hit.
      expect(padding.hitTest(const Offset(25, 25)), isNull);
    });
  });
}
