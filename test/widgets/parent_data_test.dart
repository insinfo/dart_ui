/// Per-child layout configuration: the parent-data widgets and the element
/// plumbing that carries them to a render object.
///
/// The assertions here are sizes and offsets, not "it did not throw". A flex
/// factor that reaches the render tree but divides the space differently from
/// what was asked for is the failure mode worth catching, and only arithmetic
/// catches it.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

/// A leaf that counts how many times it was actually laid out.
///
/// The question a parent-data rebuild has to answer is "did anything have to be
/// re-measured", and the honest way to ask it is to count.
final class _CountingBox extends RenderBox {
  _CountingBox(this.probe);

  final _Probe probe;

  @override
  void performLayout() {
    probe.layouts++;
    size = constraints.constrain(const Size(10, 10));
  }
}

final class _Probe {
  int layouts = 0;
}

final class _Counted extends SingleChildRenderObjectWidget {
  const _Counted(this.probe);

  final _Probe probe;

  @override
  _CountingBox createRenderObject(BuildContext context) => _CountingBox(probe);
}

/// A host whose build can be swapped from the outside, so a test can rebuild
/// one subtree without touching the root widget.
final class _Host extends StatefulWidget {
  const _Host(this.body);

  final Widget Function() body;

  static _HostState? current;

  @override
  State<_Host> createState() => _HostState();
}

final class _HostState extends State<_Host> {
  @override
  void initState() {
    super.initState();
    _Host.current = this;
  }

  void rebuild() => setState(() {});

  @override
  Widget build(BuildContext context) => widget.body();
}

void main() {
  setUpAll(() {
    expect(
      FontRegistry.instance.useFontFile('test/fonts/Roboto-Regular.ttf'),
      isTrue,
    );
  });
  tearDownAll(FontRegistry.instance.reset);

  (BuildOwner, PipelineOwner) mounted(Widget root, Size viewport) {
    final PipelineOwner pipeline = PipelineOwner(
      rootConstraints: BoxConstraints.tight(viewport),
    );
    final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
      ..updateRoot(root);
    pipeline.flushLayout();
    return (owner, pipeline);
  }

  RenderFlex flexOf(BuildOwner owner) => owner.renderRoot! as RenderFlex;

  group('Expanded and Flexible', () {
    test('one Expanded takes exactly what the fixed child left', () {
      final (BuildOwner owner, _) = mounted(
        const Row(
          children: <Widget>[
            Expanded(child: SizedBox(height: 10)),
            SizedBox(width: 60, height: 10),
          ],
        ),
        const Size(200, 50),
      );

      final RenderFlex row = flexOf(owner);
      expect(row.childCount, 2);
      // 200 - 60 = 140, and the tight fit means "exactly", not "up to".
      expect(row.childAt(0).size, const Size(140, 10));
      expect(row.childAt(0).offsetFromParent, Offset.zero);
      expect(row.childAt(1).size, const Size(60, 10));
      expect(row.childAt(1).offsetFromParent, const Offset(140, 0));
    });

    test('two Expanded children split the remainder by weight', () {
      final (BuildOwner owner, _) = mounted(
        const Row(
          children: <Widget>[
            Expanded(child: SizedBox(height: 10)),
            Expanded(flex: 3, child: SizedBox(height: 10)),
          ],
        ),
        const Size(200, 50),
      );

      final RenderFlex row = flexOf(owner);
      // 200 split 1:3.
      expect(row.childAt(0).size.width, 50);
      expect(row.childAt(1).size.width, 150);
      expect(row.childAt(1).offsetFromParent.dx, 50);
    });

    test('weights still divide what is left after an inflexible child', () {
      final (BuildOwner owner, _) = mounted(
        const Row(
          children: <Widget>[
            SizedBox(width: 40, height: 10),
            Expanded(flex: 2, child: SizedBox(height: 10)),
            Expanded(child: SizedBox(height: 10)),
          ],
        ),
        const Size(220, 50),
      );

      final RenderFlex row = flexOf(owner);
      // 220 - 40 = 180, split 2:1.
      expect(row.childAt(1).size.width, 120);
      expect(row.childAt(2).size.width, 60);
      expect(row.childAt(1).offsetFromParent.dx, 40);
      expect(row.childAt(2).offsetFromParent.dx, 160);
    });

    test('a Column divides the vertical axis the same way', () {
      final (BuildOwner owner, _) = mounted(
        const Column(
          children: <Widget>[
            SizedBox(width: 10, height: 20),
            Expanded(child: SizedBox(width: 10)),
          ],
        ),
        const Size(50, 100),
      );

      final RenderFlex column = flexOf(owner);
      expect(column.childAt(1).size.height, 80);
      expect(column.childAt(1).offsetFromParent.dy, 20);
    });

    test('FlexFit.loose caps the share, FlexFit.tight fills it', () {
      final (BuildOwner looseOwner, _) = mounted(
        const Row(
          children: <Widget>[
            Flexible(child: SizedBox(width: 20, height: 10)),
            SizedBox(width: 60, height: 10),
          ],
        ),
        const Size(200, 50),
      );
      final RenderFlex loose = flexOf(looseOwner);
      // The share is 140, but a loose child keeps its natural 20 and the
      // leftover 120 simply stays empty.
      expect(loose.childAt(0).size.width, 20);
      expect(loose.childAt(1).offsetFromParent.dx, 20);

      final (BuildOwner tightOwner, _) = mounted(
        const Row(
          children: <Widget>[
            Flexible(
              fit: FlexFit.tight,
              child: SizedBox(width: 20, height: 10),
            ),
            SizedBox(width: 60, height: 10),
          ],
        ),
        const Size(200, 50),
      );
      final RenderFlex tight = flexOf(tightOwner);
      expect(tight.childAt(0).size.width, 140);
      expect(tight.childAt(1).offsetFromParent.dx, 140);
    });

    test('Expanded is a Flexible whose fit is tight', () {
      const Expanded expanded = Expanded(child: SizedBox());
      expect(expanded, isA<Flexible>());
      expect(expanded.fit, FlexFit.tight);
      expect(expanded.flex, 1);
      expect(const Flexible(child: SizedBox()).fit, FlexFit.loose);
    });

    test('the flex factor lands in the render node parent data', () {
      final (BuildOwner owner, _) = mounted(
        const Row(
          children: <Widget>[
            Expanded(flex: 7, child: SizedBox(height: 10)),
          ],
        ),
        const Size(200, 50),
      );

      final RenderFlex row = flexOf(owner);
      final FlexParentData data = row.childParentData(row.childAt(0));
      expect(data.flex, 7);
      expect(data.fit, FlexFit.tight);
    });
  });

  group('Spacer', () {
    test('pushes the following children to the far end', () {
      final (BuildOwner owner, _) = mounted(
        const Row(
          children: <Widget>[
            SizedBox(width: 20, height: 10),
            Spacer(),
            SizedBox(width: 30, height: 10),
          ],
        ),
        const Size(200, 50),
      );

      final RenderFlex row = flexOf(owner);
      // 200 - 20 - 30 = 150 of empty space, all of it in the middle.
      expect(row.childAt(1).size, const Size(150, 0));
      expect(row.childAt(0).offsetFromParent.dx, 0);
      expect(row.childAt(1).offsetFromParent.dx, 20);
      expect(row.childAt(2).offsetFromParent.dx, 170);
    });

    test('two spacers divide the gap by their own weights', () {
      final (BuildOwner owner, _) = mounted(
        const Row(
          children: <Widget>[
            Spacer(flex: 2),
            SizedBox(width: 20, height: 10),
            Spacer(),
          ],
        ),
        const Size(200, 50),
      );

      final RenderFlex row = flexOf(owner);
      // 180 free, split 2:1.
      expect(row.childAt(0).size.width, 120);
      expect(row.childAt(2).size.width, 60);
      expect(row.childAt(1).offsetFromParent.dx, 120);
      expect(row.childAt(2).offsetFromParent.dx, 140);
    });
  });

  group('Positioned', () {
    RenderStack stackOf(BuildOwner owner) => owner.renderRoot! as RenderStack;

    test('pins a child to each of the four corners', () {
      final (BuildOwner owner, _) = mounted(
        const Stack(
          children: <Widget>[
            Positioned(
              left: 5,
              top: 7,
              child: SizedBox(width: 10, height: 10),
            ),
            Positioned(
              right: 5,
              top: 7,
              child: SizedBox(width: 10, height: 10),
            ),
            Positioned(
              left: 5,
              bottom: 7,
              child: SizedBox(width: 10, height: 10),
            ),
            Positioned(
              right: 5,
              bottom: 7,
              child: SizedBox(width: 10, height: 10),
            ),
          ],
        ),
        const Size(100, 80),
      );

      final RenderStack stack = stackOf(owner);
      expect(stack.size, const Size(100, 80));
      expect(stack.childAt(0).offsetFromParent, const Offset(5, 7));
      expect(stack.childAt(1).offsetFromParent, const Offset(85, 7));
      expect(stack.childAt(2).offsetFromParent, const Offset(5, 63));
      expect(stack.childAt(3).offsetFromParent, const Offset(85, 63));
    });

    test('left and right together stretch the child between them', () {
      final (BuildOwner owner, _) = mounted(
        const Stack(
          children: <Widget>[
            Positioned(
              left: 10,
              right: 20,
              top: 4,
              child: SizedBox(height: 12),
            ),
          ],
        ),
        const Size(100, 80),
      );

      final RenderStack stack = stackOf(owner);
      // 100 - 10 - 20 = 70, decided by the stack, not by the child.
      expect(stack.childAt(0).size, const Size(70, 12));
      expect(stack.childAt(0).offsetFromParent, const Offset(10, 4));
    });

    test('top and bottom together stretch the other axis', () {
      final (BuildOwner owner, _) = mounted(
        const Stack(
          children: <Widget>[
            Positioned(
              left: 3,
              top: 8,
              bottom: 12,
              child: SizedBox(width: 15),
            ),
          ],
        ),
        const Size(100, 80),
      );

      final RenderStack stack = stackOf(owner);
      expect(stack.childAt(0).size, const Size(15, 60));
      expect(stack.childAt(0).offsetFromParent, const Offset(3, 8));
    });

    test('Positioned.fill covers the whole stack', () {
      final (BuildOwner owner, _) = mounted(
        const Stack(
          children: <Widget>[
            Positioned.fill(child: SizedBox()),
          ],
        ),
        const Size(100, 80),
      );

      final RenderStack stack = stackOf(owner);
      expect(stack.childAt(0).size, const Size(100, 80));
      expect(stack.childAt(0).offsetFromParent, Offset.zero);
    });

    test('a positioned child does not decide the stack size', () {
      // Under an Align, so the stack is offered loose constraints and is free
      // to shrink-wrap - which is the only situation in which "positioned
      // children do not count towards the size" is observable.
      final (BuildOwner owner, _) = mounted(
        const Align(
          child: Stack(
            children: <Widget>[
              SizedBox(width: 30, height: 20),
              Positioned(
                left: 0,
                top: 0,
                child: SizedBox(width: 90, height: 70),
              ),
            ],
          ),
        ),
        const Size(100, 80),
      );

      final RenderStack stack =
          (owner.renderRoot! as RenderSingleChildBox).child! as RenderStack;
      // The 90x70 positioned child is ignored; the stack is 30x20 and the
      // child overflows it deliberately.
      expect(stack.size, const Size(30, 20));
      expect(stack.childAt(1).size, const Size(90, 70));
    });

    test('an unpositioned sibling still follows the stack alignment', () {
      final (BuildOwner owner, _) = mounted(
        const Stack(
          alignment: Alignment.center,
          children: <Widget>[
            SizedBox(width: 20, height: 10),
            Positioned(
              right: 0,
              bottom: 0,
              child: SizedBox(width: 20, height: 10),
            ),
          ],
        ),
        const Size(100, 80),
      );

      final RenderStack stack = stackOf(owner);
      expect(stack.childAt(0).offsetFromParent, const Offset(40, 35));
      expect(stack.childAt(1).offsetFromParent, const Offset(80, 70));
    });
  });

  group('misplaced parent data is a named error', () {
    test('an Expanded under a Stack names both widgets', () {
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(100, 80)),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline);

      Object? thrown;
      try {
        owner.updateRoot(
          const Stack(
            children: <Widget>[
              Expanded(child: SizedBox(width: 10, height: 10)),
            ],
          ),
        );
      } catch (error) {
        thrown = error;
      }

      expect(thrown, isA<ParentDataError>());
      final ParentDataError error = thrown! as ParentDataError;
      expect(error.parentDataWidget, Expanded);
      expect(error.expectedAncestor, Flex);
      expect(error.expectedParentData, FlexParentData);
      expect(error.actualAncestor, Stack);
      expect(error.actualParentData, StackParentData);
      expect(error.widgetPath, contains('Expanded'));
      // The message has to name both ends of the mistake: which widget, and
      // what it actually ended up under.
      expect(error.message, contains('Expanded'));
      expect(error.message, contains('Stack'));
      expect(error.message, contains('Flex'));
      expect(error.toString(), startsWith('ParentDataError: '));
    });

    test('a Positioned under a Row names both widgets', () {
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(100, 80)),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline);

      expect(
        () => owner.updateRoot(
          const Row(
            children: <Widget>[
              Positioned(left: 4, child: SizedBox(width: 10, height: 10)),
            ],
          ),
        ),
        throwsA(
          isA<ParentDataError>()
              .having((ParentDataError e) => e.parentDataWidget, 'widget',
                  Positioned)
              .having((ParentDataError e) => e.actualAncestor, 'ancestor', Row)
              .having(
                  (ParentDataError e) => e.expectedAncestor, 'expected', Stack),
        ),
      );
    });

    test('an Expanded with no render ancestor at all says so', () {
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(100, 80)),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline);

      expect(
        () => owner.updateRoot(
          const Expanded(child: SizedBox(width: 10, height: 10)),
        ),
        throwsA(
          isA<ParentDataError>()
              .having(
                  (ParentDataError e) => e.actualAncestor, 'ancestor', isNull)
              .having((ParentDataError e) => e.message, 'message',
                  contains('no render ancestor at all')),
        ),
      );
    });

    test('a component widget between the two is transparent', () {
      // The Expanded is not a direct child of the Row here; a Spacer-like
      // wrapper stands between them. Finding the render ancestor has to skip
      // it, exactly as attaching a render object does.
      final (BuildOwner owner, _) = mounted(
        Row(
          children: <Widget>[
            _Host(() => const Expanded(child: SizedBox(height: 10))),
            const SizedBox(width: 60, height: 10),
          ],
        ),
        const Size(200, 50),
      );

      final RenderFlex row = flexOf(owner);
      expect(row.childAt(0).size.width, 140);
    });
  });

  group('parent data across rebuilds', () {
    test('an unchanged flex factor costs no relayout', () {
      final _Probe probe = _Probe();
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(200, 50)),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline);
      owner.updateRoot(
        Row(
          children: <Widget>[
            _Host(() => Expanded(child: _Counted(probe))),
            const SizedBox(width: 60, height: 10),
          ],
        ),
      );
      pipeline.flushLayout();

      final RenderFlex row = flexOf(owner);
      expect(row.childAt(0).size.width, 140);
      final int afterFirstLayout = probe.layouts;
      expect(afterFirstLayout, 1);
      expect(pipeline.nodesNeedingLayout, isEmpty);
      expect(row.needsLayout, isFalse);

      // A rebuild that re-declares the same flex: the parent data is written
      // again, finds it identical, and must not dirty the row.
      _Host.current!.rebuild();
      owner.buildScope();

      expect(pipeline.nodesNeedingLayout, isEmpty);
      expect(pipeline.needsLayout, isFalse);
      expect(row.needsLayout, isFalse);
      expect(probe.layouts, afterFirstLayout);
      expect(row.childParentData(row.childAt(0)).flex, 1);
    });

    test('a changed flex factor dirties the flex, not the child', () {
      final _Probe probe = _Probe();
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(200, 50)),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline);

      Widget build(int flex) => Row(
            children: <Widget>[
              Expanded(flex: flex, child: _Counted(probe)),
              const Expanded(child: SizedBox(height: 10)),
            ],
          );

      owner.updateRoot(build(1));
      pipeline.flushLayout();
      final RenderFlex row = flexOf(owner);
      expect(row.childAt(0).size.width, 100);
      expect(probe.layouts, 1);
      expect(pipeline.nodesNeedingLayout, isEmpty);

      owner.updateRoot(build(3));

      // Exactly one node was scheduled, and it is the row - not the child that
      // owns the parent data, which is a relayout boundary and would have
      // swallowed the mark.
      expect(pipeline.nodesNeedingLayout.length, 1);
      expect(pipeline.nodesNeedingLayout.single, same(row));

      pipeline.flushLayout();
      expect(row.childAt(0).size.width, 150);
      expect(probe.layouts, 2);
    });

    test('swapping the child under a stable Expanded keeps the flex', () {
      // The Expanded is never rebuilt here: only the widget inside it changes,
      // which means a brand new render object with default parent data appears
      // under a parent-data widget that has no idea it happened.
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(200, 50)),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline);
      bool swapped = false;

      owner.updateRoot(
        Row(
          children: <Widget>[
            Expanded(
              flex: 3,
              child: _Host(
                () => swapped
              ? const ColoredBox(color: Color(0xFF000000))
                    : const SizedBox(height: 10),
              ),
            ),
            const Expanded(child: SizedBox(height: 10)),
          ],
        ),
      );
      pipeline.flushLayout();
      final RenderFlex row = flexOf(owner);
      expect(row.childAt(0).size.width, 150);
      final RenderBox before = row.childAt(0);

      swapped = true;
      _Host.current!.rebuild();
      owner.buildScope();
      pipeline.flushLayout();

      expect(row.childAt(0), isNot(same(before)));
      expect(row.childParentData(row.childAt(0)).flex, 3);
      expect(row.childAt(0).size.width, 150);
    });

    test('dropping the Expanded returns the child to its natural size', () {
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(200, 50)),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline);

      Widget build({required bool expanded}) => Row(
            children: <Widget>[
              if (expanded)
                const Expanded(child: SizedBox(width: 20, height: 10))
              else
                const SizedBox(width: 20, height: 10),
              const SizedBox(width: 60, height: 10),
            ],
          );

      owner.updateRoot(build(expanded: true));
      pipeline.flushLayout();
      expect(flexOf(owner).childAt(0).size.width, 140);

      owner.updateRoot(build(expanded: false));
      pipeline.flushLayout();
      expect(flexOf(owner).childAt(0).size.width, 20);
      expect(flexOf(owner).childParentData(flexOf(owner).childAt(0)).flex, 0);
    });
  });
}
