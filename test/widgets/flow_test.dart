/// Flow: children laid out by a delegate and placed at paint time, each
/// through its own transform, stacked in the order the delegate painted them.
library;

import 'dart:math' as math;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

const Color _red = Color(0xFFFF0000);

/// How many times each delegate hook ran, across delegate instances.
final class _Probe {
  int getSize = 0;
  int constraints = 0;
  int paints = 0;
}

/// A notifier the test can fire and ask about.
final class _Ticker extends ChangeNotifier {
  void tick() => notifyListeners();
  bool get listening => hasListeners;
}

typedef _Painter = void Function(FlowPaintingContext context);

final class _Delegate extends FlowDelegate {
  _Delegate(
    this.painter, {
    this.probe,
    this.size,
    this.childConstraints,
    this.relayout = false,
    this.repaintAgain = false,
    super.repaint,
  });

  final _Painter painter;
  final _Probe? probe;
  final Size? size;
  final BoxConstraints Function(int i, BoxConstraints constraints)?
      childConstraints;
  final bool relayout;
  final bool repaintAgain;

  @override
  Size getSize(BoxConstraints constraints) {
    probe?.getSize++;
    return size ?? super.getSize(constraints);
  }

  /// Loose by default, so a SizedBox child keeps its own size; the real
  /// default (pass-through) has a test of its own.
  @override
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) {
    probe?.constraints++;
    return childConstraints?.call(i, constraints) ??
        BoxConstraints.loose(constraints.biggest);
  }

  @override
  void paintChildren(FlowPaintingContext context) {
    probe?.paints++;
    painter(context);
  }

  @override
  bool shouldRelayout(_Delegate oldDelegate) => relayout;

  @override
  bool shouldRepaint(_Delegate oldDelegate) => repaintAgain;
}

/// Overrides nothing it does not have to.
final class _Plain extends FlowDelegate {
  const _Plain();

  @override
  void paintChildren(FlowPaintingContext context) => context.paintChild(0);

  @override
  bool shouldRepaint(_Plain oldDelegate) => false;
}

Widget _box(double width, [double height = 10]) => SizedBox(
      width: width,
      height: height,
      child: const ColoredBox(color: _red),
    );

List<Widget> _boxes(List<double> widths) =>
    <Widget>[for (final double w in widths) _box(w)];

void main() {
  late PipelineOwner pipeline;
  late BuildOwner owner;

  void mount(Widget root, {Size viewport = const Size(100, 100)}) {
    pipeline = PipelineOwner(rootConstraints: BoxConstraints.tight(viewport));
    owner = BuildOwner(pipelineOwner: pipeline)..updateRoot(root);
    addTearDown(owner.dispose);
  }

  List<DisplayListCommand> frame() {
    final DisplayList list = DisplayList();
    pipeline.drawFrame(list);
    return expandDisplayList(list);
  }

  List<Rect> rects(List<DisplayListCommand> commands) => <Rect>[
        for (final DrawRectCommand c in commands.whereType<DrawRectCommand>())
          Rect.fromLTRB(c.left, c.top, c.right, c.bottom),
      ];

  RenderFlow findFlow() {
    RenderFlow? found;
    void visit(RenderBox node) {
      if (node is RenderFlow) found ??= node;
      node.visitChildren(visit);
    }

    visit(owner.renderRoot!);
    return found!;
  }

  /// Which flow child [position] (in root coordinates) lands on, or null.
  int? hitChild(Offset position) {
    final RenderFlow flow = findFlow();
    final HitTestPath path = HitTestPath();
    if (owner.renderRoot!.hitTest(position, path: path) == null) return null;
    for (int i = 0; i < flow.childCount; i++) {
      if (path.entries.contains(flow.childAt(i))) return i;
    }
    return null;
  }

  group('paint', () {
    test('a translation moves the child without a transform command', () {
      mount(Flow.unwrapped(
        delegate: _Delegate((FlowPaintingContext context) {
          context
            ..paintChild(0, transform: const Transform2D.translation(30, 40))
            ..paintChild(1, transform: const Transform2D.translation(5, 5));
        }),
        children: _boxes(<double>[10, 20]),
      ));

      final List<DisplayListCommand> commands = frame();
      expect(rects(commands), <Rect>[
        const Rect.fromLTRB(30, 40, 40, 50),
        const Rect.fromLTRB(5, 5, 25, 15),
      ]);
      expect(commands.whereType<TransformCommand>(), isEmpty);
    });

    test('anything else goes out as a matrix about the flow origin', () {
      mount(Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.only(left: 10, top: 20),
          child: Flow.unwrapped(
            delegate: _Delegate(
              size: const Size(50, 50),
              (FlowPaintingContext context) => context.paintChild(
                0,
                transform: const Transform2D(2, 0, 0, 3, 4, 5),
              ),
            ),
            children: _boxes(<double>[10]),
          ),
        ),
      ));

      final List<DisplayListCommand> commands = frame();
      final TransformCommand t = commands.whereType<TransformCommand>().single;
      // T(10, 20) * M * T(-10, -20): the flow is at (10, 20) in the frame.
      expect(<double>[t.a, t.b, t.c, t.d, t.tx, t.ty],
          <double>[2, 0, 0, 3, 10 - 20 + 4, 20 - 60 + 5]);
      // The child itself is drawn at the flow's origin, untransformed.
      expect(rects(commands), <Rect>[const Rect.fromLTRB(10, 20, 20, 30)]);
    });

    test('children stack in the order paintChild was called', () {
      mount(Flow.unwrapped(
        delegate: _Delegate((FlowPaintingContext context) {
          context
            ..paintChild(2)
            ..paintChild(0)
            ..paintChild(1);
        }),
        children: _boxes(<double>[10, 20, 30]),
      ));

      final List<double> widths = <double>[
        for (final Rect r in rects(frame())) r.width,
      ];
      expect(widths, <double>[30, 10, 20]);
      expect(findFlow().lastPaintOrder, <int>[2, 0, 1]);
    });

    test('a child left out is not painted', () {
      mount(Flow.unwrapped(
        delegate: _Delegate((FlowPaintingContext c) => c.paintChild(1)),
        children: _boxes(<double>[10, 20, 30]),
      ));

      expect(rects(frame()).map((Rect r) => r.width), <double>[20]);
    });

    test('the flow clips to its own box', () {
      mount(Align(
        alignment: Alignment.topLeft,
        child: Flow.unwrapped(
          delegate: _Delegate(
            size: const Size(40, 30),
            (FlowPaintingContext context) => context.paintChild(
              0,
              transform: const Transform2D.translation(35, 0),
            ),
          ),
          children: _boxes(<double>[10]),
        ),
      ));

      final List<DisplayListCommand> commands = frame();
      final ClipRectCommand clip = commands.whereType<ClipRectCommand>().single;
      expect(
        Rect.fromLTRB(clip.left, clip.top, clip.right, clip.bottom),
        const Rect.fromLTRB(0, 0, 40, 30),
      );
      // Painted across the edge, but a pointer past the clip finds nothing.
      expect(hitChild(const Offset(37, 5)), 0);
      expect(hitChild(const Offset(42, 5)), isNull);
    });

    test('opacity 0 paints nothing but the child still takes the pointer', () {
      mount(Flow.unwrapped(
        delegate: _Delegate((FlowPaintingContext context) {
          context
            ..paintChild(0, opacity: 0)
            ..paintChild(1, transform: const Transform2D.translation(50, 0));
        }),
        children: _boxes(<double>[10, 20]),
      ));

      final List<DisplayListCommand> commands = frame();
      expect(rects(commands).map((Rect r) => r.width), <double>[20]);
      expect(commands.whereType<SaveLayerCommand>(), isEmpty);
      // Flutter's rule, and RenderOpacity's here: a fade does not change what
      // is clickable.
      expect(hitChild(const Offset(5, 5)), 0);
    });

    test('a partial opacity is a layer over the child box', () {
      mount(Flow.unwrapped(
        delegate: _Delegate(
          (FlowPaintingContext context) => context.paintChild(
            0,
            transform: const Transform2D.translation(10, 20),
            opacity: 0.5,
          ),
        ),
        children: _boxes(<double>[30]),
      ));

      final SaveLayerCommand layer =
          frame().whereType<SaveLayerCommand>().single;
      expect(
        Rect.fromLTRB(layer.left, layer.top, layer.right, layer.bottom),
        const Rect.fromLTRB(10, 20, 40, 30),
      );
    });

    test('painting a child twice, or one that does not exist, throws', () {
      mount(Flow.unwrapped(
        delegate: _Delegate((FlowPaintingContext c) => c.paintChild(0)),
        children: _boxes(<double>[10]),
      ));
      final RenderFlow flow = findFlow();
      frame();

      flow.delegate = _Delegate(
        repaintAgain: true,
        (FlowPaintingContext context) => context
          ..paintChild(0)
          ..paintChild(0),
      );
      expect(() => flow.paint(DisplayList(), Offset.zero), throwsStateError);

      flow.delegate = _Delegate(
        repaintAgain: true,
        (FlowPaintingContext context) => context.paintChild(3),
      );
      expect(() => flow.paint(DisplayList(), Offset.zero), throwsRangeError);
    });

    test('the context is dead once paintChildren returns', () {
      FlowPaintingContext? kept;
      mount(Flow.unwrapped(
        delegate: _Delegate((FlowPaintingContext context) => kept = context),
        children: _boxes(<double>[10]),
      ));
      frame();

      expect(() => kept!.paintChild(0), throwsStateError);
    });
  });

  group('hit testing', () {
    test('a child that was not painted cannot be hit', () {
      mount(Flow.unwrapped(
        delegate: _Delegate((FlowPaintingContext context) {
          context
            ..paintChild(0, transform: const Transform2D.translation(50, 50))
            ..paintChild(1, transform: const Transform2D.translation(70, 70));
        }),
        children: _boxes(<double>[10, 10, 10]),
      ));
      frame();

      // Child 2 was laid out at the origin and never painted.
      expect(hitChild(const Offset(2, 2)), isNull);
      expect(hitChild(const Offset(55, 55)), 0);
      expect(hitChild(const Offset(75, 75)), 1);
    });

    test('the topmost painted child wins, whatever its index', () {
      Widget flow(List<int> order) => Flow.unwrapped(
            delegate: _Delegate(
              repaintAgain: true,
              (FlowPaintingContext context) {
                for (final int i in order) {
                  context.paintChild(
                    i,
                    transform: Transform2D.translation(i * 5.0, i * 5.0),
                  );
                }
              },
            ),
            children: _boxes(<double>[10, 10]),
          );

      mount(flow(<int>[0, 1]));
      frame();
      expect(hitChild(const Offset(7, 7)), 1);

      owner.updateRoot(flow(<int>[1, 0]));
      frame();
      expect(hitChild(const Offset(7, 7)), 0);
      // Outside the overlap each is still itself.
      expect(hitChild(const Offset(2, 2)), 0);
      expect(hitChild(const Offset(13, 13)), 1);
    });

    test('a pointer is carried through the inverse of the paint transform', () {
      mount(Flow.unwrapped(
        delegate: _Delegate((FlowPaintingContext context) {
          // Scaled 3x and moved: covers (20, 20)..(50, 50).
          context.paintChild(
            0,
            transform: const Transform2D.translation(20, 20)
                .multiply(const Transform2D.scaling(3, 3)),
          );
          // A quarter turn, then moved right: covers x 60..70, y 0..10.
          context.paintChild(
            1,
            transform: const Transform2D.translation(70, 0)
                .multiply(Transform2D.rotation(math.pi / 2)),
          );
        }),
        children: _boxes(<double>[10, 10]),
      ));
      frame();

      expect(hitChild(const Offset(45, 45)), 0);
      expect(hitChild(const Offset(19, 19)), isNull);
      expect(hitChild(const Offset(65, 5)), 1);
      expect(hitChild(const Offset(72, 5)), isNull);
      expect(hitChild(const Offset(65, 12)), isNull);
    });

    test('a collapsed transform paints nothing and is hit nowhere', () {
      mount(Flow.unwrapped(
        delegate: _Delegate(
          (FlowPaintingContext context) => context.paintChild(
            0,
            transform: const Transform2D.scaling(0, 1),
          ),
        ),
        children: _boxes(<double>[10]),
      ));

      expect(rects(frame()), isEmpty);
      expect(hitChild(Offset.zero), isNull);
    });
  });

  group('the repaint listenable', () {
    test('repaints without relayout', () {
      final _Ticker ticker = _Ticker();
      final _Probe probe = _Probe();
      double dx = 0;
      mount(Flow.unwrapped(
        delegate: _Delegate(
          probe: probe,
          repaint: ticker,
          (FlowPaintingContext context) => context.paintChild(
            0,
            transform: Transform2D.translation(dx, 0),
          ),
        ),
        children: _boxes(<double>[10]),
      ));
      expect(rects(frame()), <Rect>[const Rect.fromLTRB(0, 0, 10, 10)]);
      final int sizes = probe.getSize;
      final int constraints = probe.constraints;
      expect(probe.paints, 1);

      dx = 40;
      ticker.tick();
      final RenderFlow flow = findFlow();
      expect(pipeline.nodesNeedingPaint, <RenderBox>[flow]);
      expect(pipeline.needsLayout, isFalse);

      expect(rects(frame()), <Rect>[const Rect.fromLTRB(40, 0, 50, 10)]);
      expect(probe.paints, 2);
      expect(probe.getSize, sizes, reason: 'no layout ran');
      expect(probe.constraints, constraints, reason: 'no child relaid out');
      // And the pointer follows the paint, not the layout.
      expect(hitChild(const Offset(45, 5)), 0);
      expect(hitChild(const Offset(5, 5)), isNull);
    });

    test('is listened to only while the flow is attached', () {
      final _Ticker ticker = _Ticker();
      mount(Flow.unwrapped(
        delegate: _Delegate(repaint: ticker, (FlowPaintingContext c) {}),
      ));
      expect(ticker.listening, isTrue);

      owner.updateRoot(const SizedBox());
      expect(ticker.listening, isFalse);
    });

    test('a new delegate moves the subscription to its own listenable', () {
      final _Ticker first = _Ticker();
      final _Ticker second = _Ticker();
      mount(Flow.unwrapped(
        delegate: _Delegate(repaint: first, (FlowPaintingContext c) {}),
      ));
      owner.updateRoot(Flow.unwrapped(
        delegate: _Delegate(repaint: second, (FlowPaintingContext c) {}),
      ));

      expect(first.listening, isFalse);
      expect(second.listening, isTrue);
    });
  });

  group('layout', () {
    test('size is the constrained getSize; children get their constraints', () {
      late List<Size?> seen;
      mount(Align(
        alignment: Alignment.topLeft,
        child: Flow.unwrapped(
          delegate: _Delegate(
            size: const Size(60, 500),
            childConstraints: (int i, BoxConstraints constraints) =>
                BoxConstraints.tight(Size(10.0 * (i + 1), 5)),
            (FlowPaintingContext context) {
              seen = <Size?>[
                context.size,
                for (int i = 0; i <= context.childCount; i++)
                  context.getChildSize(i),
              ];
            },
          ),
          children: _boxes(<double>[99, 99]),
        ),
      ));
      frame();

      final RenderFlow flow = findFlow();
      expect(flow.size, const Size(60, 100), reason: 'clamped to 100 high');
      expect(flow.childAt(0).size, const Size(10, 5));
      expect(flow.childAt(1).size, const Size(20, 5));
      expect(seen, <Size?>[
        const Size(60, 100),
        const Size(10, 5),
        const Size(20, 5),
        null,
      ]);
    });

    test('the defaults fill the constraints and pass them to each child', () {
      mount(Flow.unwrapped(
        delegate: const _Plain(),
        children: <Widget>[_box(10)],
      ));
      frame();

      final RenderFlow flow = findFlow();
      expect(flow.size, const Size(100, 100));
      expect(flow.childAt(0).size, const Size(100, 100));
    });

    test('an unbounded axis falls back to the minimum, not infinity', () {
      final RenderFlow flow = RenderFlow(delegate: const _Plain());
      flow.layout(BoxConstraints(maxWidth: 80, minHeight: 7));
      expect(flow.size, const Size(80, 7));
      expect(flow.getMaxIntrinsicWidth(30), 0);
    });

    test('shouldRelayout and shouldRepaint decide what a new delegate dirties',
        () {
      final _Probe probe = _Probe();
      Widget flow({bool relayout = false, bool repaint = false}) =>
          Flow.unwrapped(
            delegate: _Delegate(
              probe: probe,
              relayout: relayout,
              repaintAgain: repaint,
              (FlowPaintingContext c) => c.paintChild(0),
            ),
            children: _boxes(<double>[10]),
          );

      mount(flow());
      frame();
      final RenderFlow node = findFlow();
      int sizes = probe.getSize;
      int paints = probe.paints;

      owner.updateRoot(flow());
      expect(pipeline.needsLayout, isFalse);
      expect(pipeline.nodesNeedingPaint, isEmpty);

      owner.updateRoot(flow(repaint: true));
      expect(pipeline.needsLayout, isFalse);
      expect(pipeline.nodesNeedingPaint, <RenderBox>[node]);
      frame();
      expect(probe.getSize, sizes);
      expect(probe.paints, paints + 1);

      sizes = probe.getSize;
      paints = probe.paints;
      owner.updateRoot(flow(relayout: true));
      expect(pipeline.needsLayout, isTrue);
      frame();
      expect(probe.getSize, greaterThan(sizes));
      expect(probe.paints, paints + 1);
      expect(findFlow(), same(node), reason: 'reconciled, not replaced');
    });
  });

  test('the default constructor puts each child behind a repaint boundary', () {
    mount(Flow(
      delegate: _Delegate((FlowPaintingContext context) {
        context
          ..paintChild(0, transform: const Transform2D.translation(20, 0))
          ..paintChild(1, transform: const Transform2D.translation(0, 30));
      }),
      children: _boxes(<double>[10, 20]),
    ));

    final List<DisplayListCommand> commands = frame();
    final RenderFlow flow = findFlow();
    expect(flow.childAt(0), isA<RenderRepaintBoundary>());
    expect(flow.childAt(1), isA<RenderRepaintBoundary>());
    expect(rects(commands), <Rect>[
      const Rect.fromLTRB(20, 0, 30, 10),
      const Rect.fromLTRB(0, 30, 20, 40),
    ]);
    expect(hitChild(const Offset(25, 5)), 0);
    expect(hitChild(const Offset(5, 35)), 1);
  });
}
