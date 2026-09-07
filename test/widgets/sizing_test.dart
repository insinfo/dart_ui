/// The sizing boxes, and the one number each of them decides.
///
/// Every test here is a size or an offset, because that is the whole of what
/// these widgets do and the only thing they can be wrong about. The cases that
/// earned their place are the ones where the obvious implementation is subtly
/// different: a `LimitedBox` that also limits a *bounded* axis, an
/// `OverflowBox` whose own size follows its child, an `IntrinsicWidth` that
/// asks its child for a height at the wrong width.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  (BuildOwner, PipelineOwner) mounted(Widget root, Size viewport) {
    final PipelineOwner pipeline = PipelineOwner(
      rootConstraints: BoxConstraints.tight(viewport),
    );
    final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
      ..updateRoot(root);
    pipeline.flushLayout();
    return (owner, pipeline);
  }

  /// The single node of type [T] under [owner]'s render root.
  T find<T extends RenderBox>(BuildOwner owner) {
    final List<T> found = <T>[];
    void walk(RenderBox node) {
      if (node is T) found.add(node);
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found.single;
  }

  group('ConstrainedBox', () {
    test('the parent wins when the two disagree', () {
      // Under an `Align`, so the incoming constraints are loose. A tight
      // parent would win on both axes and the test would prove nothing about
      // the height.
      final (BuildOwner owner, _) = mounted(
        Align(
          child: ConstrainedBox(
            constraints: BoxConstraints.tightFor(width: 400, height: 20),
            child: const ColoredBox(color: Color(0xFF112233)),
          ),
        ),
        const Size(200, 100),
      );

      expect(find<RenderColoredBox>(owner).size, const Size(200, 20),
          reason: '400 clamped into the parent 200, and the height honoured');
      owner.dispose();
    });
  });

  group('FractionallySizedBox', () {
    test('the child is a fraction of the space, and it is centred', () {
      final (BuildOwner owner, _) = mounted(
        const FractionallySizedBox(
          widthFactor: 0.5,
          heightFactor: 0.25,
          child: ColoredBox(color: Color(0xFF112233)),
        ),
        const Size(200, 100),
      );

      final RenderColoredBox child = find<RenderColoredBox>(owner);
      expect(child.size, const Size(100, 25));
      expect(child.offsetFromParent, const Offset(50, 37.5));
      owner.dispose();
    });

    test('a factor above 1 lets the child exceed the box', () {
      final (BuildOwner owner, _) = mounted(
        const FractionallySizedBox(
          widthFactor: 2,
          child: ColoredBox(color: Color(0xFF112233)),
        ),
        const Size(200, 100),
      );

      final RenderFractionallySizedBox box =
          find<RenderFractionallySizedBox>(owner);
      expect(find<RenderColoredBox>(owner).size.width, 400);
      expect(box.size.width, 200,
          reason: 'the box still reports what its own parent allowed');
      owner.dispose();
    });

    test('a factor on an unbounded axis is a named error', () {
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(200, 100)),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
        ..updateRoot(
          const Column(
            children: <Widget>[
              FractionallySizedBox(
                heightFactor: 0.5,
                child: ColoredBox(color: Color(0xFF112233)),
              ),
            ],
          ),
        );

      expect(
        pipeline.flushLayout,
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message,
            'message',
            contains('unbounded height'),
          ),
        ),
      );
      owner.dispose();
    });
  });

  group('IntrinsicWidth', () {
    test('the child is pinned to its own max-content width', () {
      final (BuildOwner owner, _) = mounted(
        const Align(
          child: IntrinsicWidth(
            child: _Content(minWidth: 30, maxWidth: 70, height: 10),
          ),
        ),
        const Size(200, 100),
      );

      expect(find<_RenderContent>(owner).size, const Size(70, 10),
          reason: 'the widest the content wants to be, not the widest allowed');
      owner.dispose();
    });

    test('stepWidth rounds the answer up to a multiple', () {
      final (BuildOwner owner, _) = mounted(
        const Align(
          child: IntrinsicWidth(
            stepWidth: 25,
            child: _Content(minWidth: 30, maxWidth: 70, height: 10),
          ),
        ),
        const Size(200, 100),
      );

      expect(find<_RenderContent>(owner).size.width, 75);
      owner.dispose();
    });

    test('an already tight width skips the query entirely', () {
      final (BuildOwner owner, _) = mounted(
        const IntrinsicWidth(
          child: _Content(minWidth: 30, maxWidth: 70, height: 10),
        ),
        const Size(200, 100),
      );

      final _RenderContent content = find<_RenderContent>(owner);
      expect(content.size.width, 200);
      expect(content.intrinsicQueries, 0,
          reason: 'the answer is already decided, and an intrinsic query walks '
              'the whole subtree to produce a number nobody would read');
      owner.dispose();
    });
  });

  group('IntrinsicHeight', () {
    test('both children take the height of the taller one', () {
      final (BuildOwner owner, _) = mounted(
        const Align(
          child: IntrinsicHeight(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SizedBox(width: 20, height: 10),
                SizedBox(width: 20, height: 40),
              ],
            ),
          ),
        ),
        const Size(200, 100),
      );

      final RenderFlex row = find<RenderFlex>(owner);
      expect(row.size.height, 40);
      expect(row.childAt(0).size.height, 40,
          reason: 'the short one was stretched to the tall one');
      owner.dispose();
    });
  });

  group('LimitedBox', () {
    test('it does nothing at all on an axis the parent already bounded', () {
      final (BuildOwner owner, _) = mounted(
        const LimitedBox(
          maxHeight: 10,
          child: ColoredBox(color: Color(0xFF112233)),
        ),
        const Size(200, 100),
      );

      expect(find<RenderColoredBox>(owner).size, const Size(200, 100),
          reason:
              'the surprise the class comment warns about: inside a bounded '
              'parent a LimitedBox is inert');
      owner.dispose();
    });

    test('it caps the axis the parent left unbounded', () {
      final (BuildOwner owner, _) = mounted(
        const Column(
          children: <Widget>[
            LimitedBox(
              maxHeight: 10,
              child: ColoredBox(color: Color(0xFF112233)),
            ),
          ],
        ),
        const Size(200, 100),
      );

      expect(find<RenderColoredBox>(owner).size.height, 10,
          reason: 'without the cap the coloured box collapses to zero on an '
              'unbounded axis, which is the whole reason this widget exists');
      owner.dispose();
    });
  });

  group('OverflowBox', () {
    test('the child gets its own constraints and the box keeps the parent\'s',
        () {
      final (BuildOwner owner, _) = mounted(
        const Align(
          child: SizedBox(
            width: 50,
            height: 50,
            child: OverflowBox(
              minWidth: 120,
              maxWidth: 120,
              child: ColoredBox(color: Color(0xFF112233)),
            ),
          ),
        ),
        const Size(200, 100),
      );

      expect(find<RenderColoredBox>(owner).size, const Size(120, 50));
      expect(find<RenderOverflowBox>(owner).size, const Size(50, 50));
      expect(
          find<RenderColoredBox>(owner).offsetFromParent, const Offset(-35, 0),
          reason:
              'centred, so a child wider than the box hangs off both sides');
      owner.dispose();
    });
  });

  group('SizedOverflowBox', () {
    test('it claims one size and measures the child against another', () {
      final (BuildOwner owner, _) = mounted(
        const Align(
          child: SizedOverflowBox(
            size: Size(40, 40),
            alignment: Alignment.centerLeft,
            child: SizedBox(width: 150, height: 20),
          ),
        ),
        const Size(200, 100),
      );

      final RenderSizedOverflowBox box = find<RenderSizedOverflowBox>(owner);
      expect(box.size, const Size(40, 40));
      expect(find<RenderConstrainedBox>(owner).size, const Size(150, 20),
          reason: 'measured against the grandparent\'s 200, not against the 40 '
              'this box asked for');
      expect(find<RenderConstrainedBox>(owner).offsetFromParent,
          const Offset(0, 10));
      owner.dispose();
    });
  });

  group('Baseline', () {
    test('the child is pushed down so its baseline lands on the number', () {
      final (BuildOwner owner, _) = mounted(
        const Align(
          child: Baseline(
            baseline: 30,
            baselineType: TextBaseline.alphabetic,
            // No text, so the node reports its own bottom edge as its
            // baseline - 12 here - and has to fall 18 to reach 30.
            child: SizedBox(width: 20, height: 12),
          ),
        ),
        const Size(200, 100),
      );

      final RenderBaseline box = find<RenderBaseline>(owner);
      expect(box.child!.offsetFromParent, const Offset(0, 18));
      expect(box.size, const Size(20, 30),
          reason: 'the box grows downward to hold the shifted child');
      owner.dispose();
    });

    test('a child already below the line is not pulled above the top edge', () {
      final (BuildOwner owner, _) = mounted(
        const Align(
          child: Baseline(
            baseline: 5,
            baselineType: TextBaseline.alphabetic,
            child: SizedBox(width: 20, height: 12),
          ),
        ),
        const Size(200, 100),
      );

      final RenderBaseline box = find<RenderBaseline>(owner);
      expect(box.child!.offsetFromParent, Offset.zero);
      expect(box.size, const Size(20, 12));
      owner.dispose();
    });
  });
}

/// A leaf with a declared min and max content width, so an intrinsic query has
/// something to return that is not simply its size.
final class _Content extends SingleChildRenderObjectWidget {
  const _Content({
    required this.minWidth,
    required this.maxWidth,
    required this.height,
  });

  final double minWidth;
  final double maxWidth;
  final double height;

  @override
  _RenderContent createRenderObject(BuildContext context) => _RenderContent(
        minContentWidth: minWidth,
        maxContentWidth: maxWidth,
        contentHeight: height,
      );
}

final class _RenderContent extends RenderBox {
  _RenderContent({
    required this.minContentWidth,
    required this.maxContentWidth,
    required this.contentHeight,
  });

  final double minContentWidth;
  final double maxContentWidth;
  final double contentHeight;

  /// Counts the questions, so "was this even asked" is observable.
  int intrinsicQueries = 0;

  @override
  double computeMinIntrinsicWidth(double height) {
    intrinsicQueries++;
    return minContentWidth;
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    intrinsicQueries++;
    return maxContentWidth;
  }

  @override
  double computeMinIntrinsicHeight(double width) {
    intrinsicQueries++;
    return contentHeight;
  }

  @override
  double computeMaxIntrinsicHeight(double width) {
    intrinsicQueries++;
    return contentHeight;
  }

  @override
  void performLayout() {
    size = constraints.constrain(Size(maxContentWidth, contentHeight));
  }
}
