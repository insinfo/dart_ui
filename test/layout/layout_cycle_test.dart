/// Layout cycle detection - section 25.7.
///
/// The property under test is not "it throws". It is that a tree which cannot
/// converge produces a **named** failure in bounded time, with the nodes
/// responsible in it, instead of hanging the frame - which is the failure mode
/// with no message and no stack.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('a pair of nodes dirtying each other', () {
    (PipelineOwner, PingPongBox, PingPongBox) cyclingTree() {
      final a = PingPongBox();
      final b = PingPongBox();
      a.peer = b;
      b.peer = a;
      final host = BoundaryHost()
        ..add(a)
        ..add(b);
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(50, 50)),
      )..root = host;
      return (owner, a, b);
    }

    test('fails by name instead of spinning', () {
      final (PipelineOwner owner, _, _) = cyclingTree();

      expect(owner.flushLayout, throwsA(isA<LayoutCycleError>()));
    });

    test('gives up after exactly the documented number of passes', () {
      final (PipelineOwner owner, _, _) = cyclingTree();

      LayoutCycleError? caught;
      try {
        owner.flushLayout();
      } on LayoutCycleError catch (error) {
        caught = error;
      }

      expect(caught, isNotNull);
      expect(caught!.passes, PipelineOwner.maxLayoutPasses);
    });

    test('the work it did is bounded by that number', () {
      final (PipelineOwner owner, PingPongBox a, PingPongBox b) = cyclingTree();

      try {
        owner.flushLayout();
      } on LayoutCycleError {
        // expected
      }

      // One initial layout each plus at most one per pass. The point is that
      // this is a small number and not an unbounded one.
      expect(
        a.layoutCount + b.layoutCount,
        lessThanOrEqualTo(PipelineOwner.maxLayoutPasses + 2),
      );
    });

    test('names the nodes that kept coming back', () {
      final (PipelineOwner owner, PingPongBox a, PingPongBox b) = cyclingTree();

      LayoutCycleError? caught;
      try {
        owner.flushLayout();
      } on LayoutCycleError catch (error) {
        caught = error;
      }

      expect(caught!.suspects, isNotEmpty);
      for (final RenderBox suspect in caught.suspects) {
        expect(suspect, anyOf(same(a), same(b)));
      }
    });

    test('the diagnostic tree is the ancestor chain and not the whole tree',
        () {
      final (PipelineOwner owner, _, _) = cyclingTree();

      LayoutCycleError? caught;
      try {
        owner.flushLayout();
      } on LayoutCycleError catch (error) {
        caught = error;
      }

      final String tree = caught!.diagnosticTree;
      expect(tree, contains('PingPongBox'));
      expect(tree, contains('BoundaryHost'));
      expect(tree, contains('->'));
      // Reduced: at most one line per suspect plus the heading.
      expect(
        '\n'.allMatches(tree).length,
        lessThanOrEqualTo(caught.suspects.length + 2),
      );
      expect(caught.toString(), contains('LayoutCycleError'));
    });

    test('a settled tree is unaffected by the counter', () {
      final host = BoundaryHost()
        ..add(FixedBox(const Size(10, 10)))
        ..add(FixedBox(const Size(10, 10)));
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(50, 50)),
      )..root = host;

      owner.flushLayout();
      owner.flushLayout();

      expect(owner.needsLayout, isFalse);
    });
  });

  group('an infinite measure', () {
    test('is rejected even though the constraint permits it', () {
      final box = InfiniteBox();
      final owner = PipelineOwner(rootConstraints: BoxConstraints())
        ..root = box;

      expect(owner.flushLayout, throwsA(isA<InfiniteMeasureError>()));
    });

    test('is fine once the axis is bounded', () {
      final box = InfiniteBox();
      final owner = PipelineOwner(
        rootConstraints: BoxConstraints(maxWidth: 40),
      )..root = box;

      owner.flushLayout();

      expect(box.size, const Size(40, 10));
    });

    test('names the node and the size it reported', () {
      final box = InfiniteBox();
      final owner = PipelineOwner(rootConstraints: BoxConstraints())
        ..root = box;

      InfiniteMeasureError? caught;
      try {
        owner.flushLayout();
      } on InfiniteMeasureError catch (error) {
        caught = error;
      }

      expect(caught!.node, same(box));
      expect(caught.reported.width, double.infinity);
      expect(caught.message, contains('InfiniteBox'));
    });
  });

  group('an intrinsic that is not one', () {
    test('a compute that returns infinity is refused', () {
      expect(
        () => _InfiniteIntrinsic().getMaxIntrinsicWidth(double.infinity),
        throwsA(isA<InvalidIntrinsicError>()),
      );
    });

    test('a compute that returns a negative extent is refused', () {
      expect(
        () => _NegativeIntrinsic().getMinIntrinsicHeight(double.infinity),
        throwsA(isA<InvalidIntrinsicError>()),
      );
    });

    test('the error names the question that was asked', () {
      InvalidIntrinsicError? caught;
      try {
        _NegativeIntrinsic().getMinIntrinsicHeight(double.infinity);
      } on InvalidIntrinsicError catch (error) {
        caught = error;
      }

      expect(caught!.dimension, 'minHeight');
      expect(caught.returned, -1);
    });
  });
}

final class _InfiniteIntrinsic extends RenderBox {
  @override
  double computeMaxIntrinsicWidth(double height) => double.infinity;

  @override
  void performLayout() => size = constraints.smallest;
}

final class _NegativeIntrinsic extends RenderBox {
  @override
  double computeMinIntrinsicHeight(double width) => -1;

  @override
  void performLayout() => size = constraints.smallest;
}
