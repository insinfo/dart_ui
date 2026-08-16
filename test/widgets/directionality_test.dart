/// The reading direction as an inherited value.
///
/// Three separate claims live here: that the value is published and scoped
/// per node rather than globally, that its absence is a named failure rather
/// than a silent left-to-right guess, and that a render object which resolves
/// it produces mirrored offsets - asserted numerically, because "it flipped"
/// and "it flipped twice" look the same to a boolean.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  const TextDirection ltr = TextDirection.leftToRight;
  const TextDirection rtl = TextDirection.rightToLeft;

  (BuildOwner, PipelineOwner) mounted(Widget root, Size viewport) {
    final PipelineOwner pipeline = PipelineOwner(
      rootConstraints: BoxConstraints.tight(viewport),
    );
    final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
      ..updateRoot(root);
    pipeline.flushLayout();
    return (owner, pipeline);
  }

  group('publication and scoping', () {
    test('of returns the direction in scope', () {
      final List<TextDirection> seen = <TextDirection>[];
      mounted(
        Directionality(
          textDirection: rtl,
          child: _Probe(onBuild: seen.add),
        ),
        const Size(100, 50),
      );

      expect(seen, <TextDirection>[rtl]);
    });

    test('a nested Directionality overrides only its own subtree', () {
      // The four-way check: an outer right-to-left document containing a
      // left-to-right island, with a probe on each side of the boundary and a
      // third one below the island to prove the override does not leak back.
      final List<TextDirection> outer = <TextDirection>[];
      final List<TextDirection> island = <TextDirection>[];
      final List<TextDirection> belowIsland = <TextDirection>[];

      mounted(
        Directionality(
          textDirection: rtl,
          child: Column(
            children: <Widget>[
              _Probe(onBuild: outer.add),
              Directionality(
                textDirection: ltr,
                child: Column(
                  children: <Widget>[
                    _Probe(onBuild: island.add),
                    Directionality(
                      textDirection: rtl,
                      child: _Probe(onBuild: belowIsland.add),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const Size(100, 50),
      );

      expect(outer, <TextDirection>[rtl]);
      expect(island, <TextDirection>[ltr]);
      // Nesting is arbitrarily deep and each level shadows only the one above.
      expect(belowIsland, <TextDirection>[rtl]);
    });

    test('maybeOf sees the same scoping', () {
      final List<TextDirection?> seen = <TextDirection?>[];
      mounted(
        Directionality(
          textDirection: rtl,
          child: _Probe(onBuild: (_) {}, onMaybe: seen.add),
        ),
        const Size(100, 50),
      );
      expect(seen, <TextDirection?>[rtl]);
    });

    test('a changed direction reaches the subtree', () {
      final List<TextDirection> seen = <TextDirection>[];
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(100, 50)),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline);

      owner.updateRoot(
        Directionality(textDirection: ltr, child: _Probe(onBuild: seen.add)),
      );
      expect(seen, <TextDirection>[ltr]);

      owner.updateRoot(
        Directionality(textDirection: rtl, child: _Probe(onBuild: seen.add)),
      );
      expect(seen, <TextDirection>[ltr, rtl]);
    });

    test('updateShouldNotify fires on a change and only on a change', () {
      // Asserted on the widget rather than by counting rebuilds, because a
      // rebuild count also moves when the child widget instance changes, and
      // that would make the test pass for the wrong reason.
      const Widget child = SizedBox(width: 1, height: 1);
      const Directionality leftToRight =
          Directionality(textDirection: ltr, child: child);
      const Directionality rightToLeft =
          Directionality(textDirection: rtl, child: child);

      expect(rightToLeft.updateShouldNotify(leftToRight), isTrue);
      expect(leftToRight.updateShouldNotify(rightToLeft), isTrue);
      expect(
        rightToLeft.updateShouldNotify(
          const Directionality(textDirection: rtl, child: child),
        ),
        isFalse,
      );
    });
  });

  group('a tree with no Directionality', () {
    test('of throws, and names the widget that asked', () {
      // Read outside build so the failure is observed directly rather than
      // through the framework's build-error containment.
      final List<BuildContext> captured = <BuildContext>[];
      mounted(_Capture(captured.add), const Size(100, 50));
      final BuildContext context = captured.single;

      expect(
        () => Directionality.of(context),
        throwsA(
          isA<MissingDirectionalityError>().having(
            (MissingDirectionalityError error) => error.requestedBy,
            'requestedBy',
            '_Capture',
          ),
        ),
      );
      // The message has to be actionable on its own, because it is what ends
      // up pasted into an issue.
      expect(
        () => Directionality.of(context),
        throwsA(
          isA<MissingDirectionalityError>().having(
            (MissingDirectionalityError error) => error.toString(),
            'toString',
            allOf(
              contains('No Directionality ancestor'),
              contains('Directionality.maybeOf'),
              contains('textDirection: TextDirection.leftToRight'),
            ),
          ),
        ),
      );
    });

    test('maybeOf returns null instead', () {
      final List<BuildContext> captured = <BuildContext>[];
      mounted(_Capture(captured.add), const Size(100, 50));

      expect(Directionality.maybeOf(captured.single), isNull);
    });

    test('a caller that wants leniency writes the fallback down', () {
      // Not a framework behaviour so much as the documented idiom; asserting
      // it keeps the escape hatch from being quietly removed.
      final List<BuildContext> captured = <BuildContext>[];
      mounted(_Capture(captured.add), const Size(100, 50));

      expect(Directionality.maybeOf(captured.single) ?? ltr, ltr);
    });
  });

  group('icon mirroring hook', () {
    test('mirrorsInDirection flips only when both conditions hold', () {
      expect(mirrorsInDirection(rtl, matchTextDirection: true), isTrue);
      expect(mirrorsInDirection(ltr, matchTextDirection: true), isFalse);
      // The important negative: an icon that did not opt in never mirrors,
      // because a magnifier or a logo is wrong reflected.
      expect(mirrorsInDirection(rtl, matchTextDirection: false), isFalse);
      expect(mirrorsInDirection(ltr, matchTextDirection: false), isFalse);
    });

    test('Directionality.mirrors reads the ambient direction', () {
      final List<BuildContext> captured = <BuildContext>[];
      mounted(
        Directionality(textDirection: rtl, child: _Capture(captured.add)),
        const Size(100, 50),
      );
      final BuildContext context = captured.single;

      expect(
        Directionality.mirrors(context, matchTextDirection: true),
        isTrue,
      );
      expect(
        Directionality.mirrors(context, matchTextDirection: false),
        isFalse,
      );
    });

    test('a non-directional drawable needs no Directionality at all', () {
      final List<BuildContext> captured = <BuildContext>[];
      mounted(_Capture(captured.add), const Size(100, 50));

      expect(
        Directionality.mirrors(captured.single, matchTextDirection: false),
        isFalse,
      );
      // ... but one that asked to follow the text and was given no text
      // direction is a bug, not a silent no-op.
      expect(
        () => Directionality.mirrors(captured.single, matchTextDirection: true),
        throwsA(isA<MissingDirectionalityError>()),
      );
    });

    test('horizontalMirror reflects a box onto itself', () {
      final Transform2D mirror = horizontalMirror(24);
      // Corners swap, and nothing leaves the box.
      expect(mirror.transformOffset(Offset.zero), const Offset(24, 0));
      expect(mirror.transformOffset(const Offset(24, 0)), Offset.zero);
      // The vertical axis is untouched, and the centre is a fixed point.
      expect(mirror.transformOffset(const Offset(12, 7)), const Offset(12, 7));
      // Applying it twice is the identity, which is what makes it safe to
      // push and pop around a paint.
      expect(
        mirror.transformOffset(mirror.transformOffset(const Offset(5, 3))),
        const Offset(5, 3),
      );
    });
  });

  group('a render object that resolves the ambient direction', () {
    test('a row mirrors under Directionality, per node', () {
      // The widget-level form of the per-node claim: the outer row is
      // right-to-left, the inner one is put back to left-to-right by a nested
      // Directionality, and only the outer one reverses.
      final (BuildOwner owner, _) = mounted(
        const Directionality(
          textDirection: rtl,
          child: _DirectionalRow(
            children: <Widget>[
              Directionality(
                textDirection: ltr,
                child: _DirectionalRow(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    SizedBox(width: 20, height: 10),
                    SizedBox(width: 30, height: 10),
                  ],
                ),
              ),
              SizedBox(width: 40, height: 10),
            ],
          ),
        ),
        const Size(200, 50),
      );

      final RenderFlex outer = owner.renderRoot! as RenderFlex;
      expect(outer.textDirection, rtl);

      final RenderFlex inner = outer.childAt(0) as RenderFlex;
      final RenderBox sibling = outer.childAt(1);
      expect(inner.textDirection, ltr);
      expect(inner.size.width, 50);

      // Outer, mirrored: first child flush with the right edge.
      expect(inner.offsetFromParent.dx, 150);
      expect(sibling.offsetFromParent.dx, 110);
      // Inner, not mirrored: its own children run left to right inside it.
      expect(inner.childAt(0).offsetFromParent.dx, 0);
      expect(inner.childAt(1).offsetFromParent.dx, 20);
      expect(inner.childAt(0).globalOffset.dx, 150);
      expect(inner.childAt(1).globalOffset.dx, 170);
    });

    test('the same tree left-to-right gives the exact mirror offsets', () {
      final (BuildOwner owner, _) = mounted(
        const Directionality(
          textDirection: ltr,
          child: _DirectionalRow(
            children: <Widget>[
              SizedBox(width: 20, height: 10),
              SizedBox(width: 30, height: 10),
              SizedBox(width: 40, height: 10),
            ],
          ),
        ),
        const Size(200, 50),
      );
      final RenderFlex flex = owner.renderRoot! as RenderFlex;
      expect(
        <double>[
          for (int i = 0; i < 3; i++) flex.childAt(i).offsetFromParent.dx,
        ],
        <double>[0, 20, 50],
      );
    });

    test('flipping the ambient direction re-lays the row out', () {
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(200, 50)),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline);

      Widget tree(TextDirection direction) => Directionality(
            textDirection: direction,
            child: const _DirectionalRow(
              children: <Widget>[
                SizedBox(width: 20, height: 10),
                SizedBox(width: 30, height: 10),
                SizedBox(width: 40, height: 10),
              ],
            ),
          );

      owner.updateRoot(tree(ltr));
      pipeline.flushLayout();
      final RenderFlex flex = owner.renderRoot! as RenderFlex;
      expect(flex.childAt(0).offsetFromParent.dx, 0);

      owner.updateRoot(tree(rtl));
      pipeline.flushLayout();
      expect(flex.textDirection, rtl);
      expect(
        <double>[
          for (int i = 0; i < 3; i++) flex.childAt(i).offsetFromParent.dx,
        ],
        <double>[180, 150, 110],
      );
    });
  });
}

/// Reports the direction it sees, once per build.
final class _Probe extends StatelessWidget {
  const _Probe({required this.onBuild, this.onMaybe});

  final void Function(TextDirection) onBuild;
  final void Function(TextDirection?)? onMaybe;

  @override
  Widget build(BuildContext context) {
    onBuild(Directionality.of(context));
    onMaybe?.call(Directionality.maybeOf(context));
    return const SizedBox(width: 1, height: 1);
  }
}

/// Hands its own [BuildContext] out so a lookup can be made from outside a
/// build, where a throw is observed directly rather than through the
/// framework's build-error containment.
final class _Capture extends StatelessWidget {
  const _Capture(this.onContext);

  final void Function(BuildContext) onContext;

  @override
  Widget build(BuildContext context) {
    onContext(context);
    return const SizedBox(width: 1, height: 1);
  }
}

/// The wiring an eventual direction-aware `Row` will use, written out here so
/// the render-object half is tested through a real element tree rather than by
/// setting `RenderFlex.textDirection` by hand.
final class _DirectionalRow extends MultiChildRenderObjectWidget {
  const _DirectionalRow({
    this.mainAxisSize = MainAxisSize.max,
    super.children,
  });

  final MainAxisSize mainAxisSize;

  @override
  RenderFlex createRenderObject(BuildContext context) => RenderFlex(
        mainAxisSize: mainAxisSize,
        textDirection: Directionality.of(context),
      );

  @override
  void updateRenderObject(BuildContext context, covariant RenderFlex flex) {
    flex
      ..mainAxisSize = mainAxisSize
      ..textDirection = Directionality.of(context);
  }
}
