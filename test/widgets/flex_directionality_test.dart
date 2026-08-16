/// `Row` has to read the ambient `Directionality`, and only a real element
/// tree can prove it.
///
/// `RenderFlex` was taught to mirror and `Directionality` was written, but
/// between them sits one line in `Flex.createRenderObject`. A test that builds
/// a `RenderFlex` by hand and sets `textDirection` on it proves the mirroring
/// and says nothing about whether a `Row` ever asks. These go through
/// `BuildOwner`, so a missing `Directionality.maybeOf` shows up as offsets that
/// did not move.
///
/// The `maybeOf` half matters as much: `Directionality.of` throws by design,
/// so wiring it here would have made every `Row` in a tree without a
/// `Directionality` — which is most of this suite — fail to build. The null
/// travels to `RenderFlex.textDirection`, whose documented policy is that null
/// lays out left-to-right.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('a Row reads the ambient direction', () {
    test('left to right places the first child at the left edge', () {
      expect(_childLefts(TextDirection.leftToRight), <double>[0, 30]);
    });

    test('right to left mirrors it, and the widths are unchanged', () {
      // 200 wide, children 30 and 50: the first child's right edge is the
      // surface's right edge, so its left is 200 - 30 = 170, and the second
      // sits immediately inside it at 170 - 50 = 120.
      expect(_childLefts(TextDirection.rightToLeft), <double>[170, 120]);
    });

    test('no Directionality lays out as left to right, and does not throw', () {
      // The policy under test is the one written on `Flex._directionOf`: a Row
      // does not *decide* a locale, it forwards one. Nothing installed here, so
      // `maybeOf` is null and the render layer's documented null-is-LTR applies.
      expect(_childLefts(null), <double>[0, 30]);
    });

    test('a nested Directionality overrides only its own subtree', () {
      // The outer row is RTL, so its single child - the inner row - is placed
      // against the right edge. The inner row is LTR again, so *its* children
      // run left to right from there. Getting this wrong globally instead of
      // per node gives [170, 120] for the inner pair.
      final owner = _mount(
        const Directionality(
          textDirection: TextDirection.rightToLeft,
          child: Row(
            children: <Widget>[
              Directionality(
                textDirection: TextDirection.leftToRight,
                child: Row(
                  children: <Widget>[
                    SizedBox(width: 30, height: 10),
                    SizedBox(width: 50, height: 10),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
      addTearDown(owner.dispose);

      final RenderFlex outer = _firstFlex(owner);
      final RenderFlex inner = _firstFlex(owner, skip: 1);

      // The inner row measures 80 and is pushed to the right edge of 200.
      expect(_leftOf(outer, 0), 120);
      // And inside it, the children are in reading order from its own origin.
      expect(<double>[_leftOf(inner, 0), _leftOf(inner, 1)], <double>[0, 30]);
    });

    test('flipping the ambient direction re-lays the row out', () {
      // The setter marks needs-layout, so the second frame has to move the
      // children rather than reuse the first frame's offsets.
      final controller = _DirectionController(TextDirection.leftToRight);
      final owner = _mount(_DirectionalHost(controller: controller));
      addTearDown(owner.dispose);

      expect(_leftOf(_firstFlex(owner), 0), 0);

      controller.flip(TextDirection.rightToLeft);
      owner.buildScope();
      owner.pipelineOwner.flushLayout();

      expect(_leftOf(_firstFlex(owner), 0), 170);
    });
  });
}

/// Builds a two-child row under [direction], or under nothing when null.
List<double> _childLefts(TextDirection? direction) {
  const row = Row(
    children: <Widget>[
      SizedBox(width: 30, height: 10),
      SizedBox(width: 50, height: 10),
    ],
  );
  final owner = _mount(
    direction == null
        ? row
        : Directionality(textDirection: direction, child: row),
  );
  addTearDown(owner.dispose);
  final RenderFlex flex = _firstFlex(owner);
  return <double>[_leftOf(flex, 0), _leftOf(flex, 1)];
}

BuildOwner _mount(Widget root) {
  final pipeline = PipelineOwner(
    rootConstraints: BoxConstraints.tight(const Size(200, 100)),
  );
  final owner = BuildOwner(pipelineOwner: pipeline)..updateRoot(root);
  pipeline.flushLayout();
  return owner;
}

/// The [skip]-th `RenderFlex` in the tree, in depth-first order.
RenderFlex _firstFlex(BuildOwner owner, {int skip = 0}) {
  final found = <RenderFlex>[];
  void visit(RenderBox node) {
    if (node is RenderFlex) found.add(node);
    node.visitChildren(visit);
  }

  visit(owner.pipelineOwner.root!);
  return found[skip];
}

double _leftOf(RenderFlex flex, int index) {
  final children = <RenderBox>[];
  flex.visitChildren(children.add);
  return children[index].parentData!.offset.dx;
}

/// Holds the direction so a rebuild can change it.
final class _DirectionController extends ValueNotifier<TextDirection> {
  _DirectionController(super.value);

  void flip(TextDirection next) => value = next;
}

final class _DirectionalHost extends StatefulWidget {
  const _DirectionalHost({required this.controller});

  final _DirectionController controller;

  @override
  State<_DirectionalHost> createState() => _DirectionalHostState();
}

final class _DirectionalHostState extends State<_DirectionalHost> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged(TextDirection _) => setState(() {});

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: widget.controller.value,
        child: const Row(
          children: <Widget>[
            SizedBox(width: 30, height: 10),
            SizedBox(width: 50, height: 10),
          ],
        ),
      );
}
