import 'package:dart_ui/vector.dart';
import 'package:test/test.dart';

/// A closed square 0..100 drawn the way the pen closes a path: the last
/// point repeats the start.
VectorCurve square() => VectorCurve(paths: <VectorPath>[
      VectorPath(
        start: Offset.zero,
        points: <Object>[
          const Offset(100, 0),
          const Offset(100, 100),
          const Offset(0, 100),
          Offset.zero,
        ],
        closure: PathClosure.closed,
      ),
    ])
      ..update();

/// An open wave: a line, then a curve.
VectorCurve wave() => VectorCurve(paths: <VectorPath>[
      VectorPath(
        start: Offset.zero,
        points: <Object>[
          const Offset(100, 0),
          const CurvePoint(Offset(150, -50), Offset(250, 50), Offset(300, 0)),
        ],
      ),
    ])
      ..update();

void main() {
  test('a closed path repeating its start counts that node once', () {
    final VectorCurve curve = square();
    expect(NodeEditing.nodeCount(curve.paths.single), 4);
    expect(NodeEditing.nodesOf(curve).length, 4);
  });

  test('moving the start of a closed path moves its closing point too', () {
    final VectorCurve curve = square();
    NodeEditing.moveNodes(
        curve, const <PathNode>[PathNode(0, 0)], const Offset(-10, -10));
    final VectorPath path = curve.paths.single;
    expect(path.start, const Offset(-10, -10));
    expect(path.points.last, const Offset(-10, -10));
    expect(curve.cacheBbox.left, closeTo(-10, 0.01));
  });

  test('moving a node carries both of its handles', () {
    final VectorCurve curve = wave();
    NodeEditing.moveNodes(
        curve, const <PathNode>[PathNode(0, 1)], const Offset(0, 20));
    final CurvePoint bend = curve.paths.single.points[1] as CurvePoint;
    expect(curve.paths.single.points[0], const Offset(100, 20));
    expect(bend.control1, const Offset(150, -30),
        reason: 'the leaving handle moves with its node');
    expect(bend.control2, const Offset(250, 50),
        reason: "the far node's handle stays");
  });

  test('inserting a node keeps the curve exactly where it was', () {
    final VectorCurve curve = wave();
    final PathNode added =
        NodeEditing.insertNode(curve, const SegmentHit(0, 1, 0.5));
    expect(added, const PathNode(0, 2));
    final VectorPath path = curve.paths.single;
    expect(path.points, hasLength(3));
    // The midpoint of the original cubic is (200, 0).
    expect(NodeEditing.nodePoint(path, 2).dx, closeTo(200, 1e-9));
    expect(NodeEditing.nodePoint(path, 2).dy, closeTo(0, 1e-9));
    expect(NodeEditing.nodePoint(path, 3), const Offset(300, 0));
  });

  test('deleting a middle node joins its two segments', () {
    final VectorCurve curve = wave();
    expect(NodeEditing.deleteNodes(curve, const <PathNode>[PathNode(0, 1)]),
        isTrue);
    final VectorPath path = curve.paths.single;
    expect(path.points, hasLength(1));
    final CurvePoint merged = path.points.single as CurvePoint;
    expect(merged.endpoint, const Offset(300, 0));
    expect(merged.control2, const Offset(250, 50));
  });

  test('deleting until one node is left removes the path', () {
    final VectorCurve curve = wave();
    expect(
        NodeEditing.deleteNodes(
            curve, const <PathNode>[PathNode(0, 1), PathNode(0, 2)]),
        isFalse);
    expect(curve.paths, isEmpty);
  });

  test('to line and to curve swap the segment arriving at a node', () {
    final VectorCurve curve = wave();
    NodeEditing.toLine(curve, const <PathNode>[PathNode(0, 2)]);
    expect(curve.paths.single.points[1], const Offset(300, 0));
    NodeEditing.toCurve(curve, const <PathNode>[PathNode(0, 1)]);
    final CurvePoint first = curve.paths.single.points[0] as CurvePoint;
    expect(first.control1.dx, closeTo(100 / 3, 1e-9));
    expect(first.endpoint, const Offset(100, 0));
  });

  test('a symmetrical node mirrors its handles, and keeps them mirrored', () {
    final VectorCurve curve = VectorCurve(paths: <VectorPath>[
      VectorPath(start: Offset.zero, points: <Object>[
        const CurvePoint(Offset(30, -30), Offset(80, -20), Offset(100, 0)),
        const CurvePoint(Offset(130, 40), Offset(170, 0), Offset(200, 0)),
      ]),
    ])
      ..update();
    NodeEditing.setType(
        curve, const <PathNode>[PathNode(0, 1)], NodeType.symmetrical);
    final CurvePoint leaving = curve.paths.single.points[1] as CurvePoint;
    expect(leaving.control1, const Offset(120, 20));

    NodeEditing.moveHandle(
      curve,
      const NodeHandleRef(PathNode(0, 1), NodeHandleSide.incoming),
      const Offset(100, -40),
    );
    final CurvePoint after = curve.paths.single.points[1] as CurvePoint;
    expect(after.control1.dx, closeTo(100, 1e-9));
    expect(after.control1.dy, closeTo(40, 1e-9));
  });

  test('breaking a closed path opens it at the node; joining closes it', () {
    final VectorCurve curve = square();
    final List<PathNode> ends =
        NodeEditing.breakAt(curve, const PathNode(0, 2));
    final VectorPath open = curve.paths.single;
    expect(open.isOpen, isTrue);
    expect(open.start, const Offset(100, 100));
    expect(NodeEditing.endOf(open.points.last), const Offset(100, 100));
    expect(ends, hasLength(2));

    expect(NodeEditing.join(curve, ends.first, ends.last), isTrue);
    expect(curve.paths.single.isClosed, isTrue);
  });

  test('joining the ends of two paths makes one', () {
    final VectorCurve curve = VectorCurve(paths: <VectorPath>[
      VectorPath(start: Offset.zero, points: <Object>[const Offset(50, 0)]),
      VectorPath(
          start: const Offset(100, 0), points: <Object>[const Offset(150, 0)]),
    ])
      ..update();
    expect(NodeEditing.join(curve, const PathNode(0, 1), const PathNode(1, 0)),
        isTrue);
    final VectorPath path = curve.paths.single;
    expect(path.start, Offset.zero);
    expect(NodeEditing.nodeCount(path), 4);
    expect(NodeEditing.endOf(path.points.last), const Offset(150, 0));
  });

  test('reversing twice gives the path back', () {
    final VectorPath path = wave().paths.single;
    final VectorPath back = NodeEditing.reversed(NodeEditing.reversed(path));
    expect(back.start, path.start);
    expect(back.points.length, path.points.length);
    final CurvePoint a = path.points[1] as CurvePoint;
    final CurvePoint b = back.points[1] as CurvePoint;
    expect(b.control1, a.control1);
    expect(b.control2, a.control2);
  });

  test('hit tests work in the curve\'s own coordinates', () {
    final VectorCurve curve = square()..trafo = <double>[2, 0, 0, 2, 10, 10];
    final Offset? local = NodeEditing.toLocal(curve, const Offset(210, 10));
    expect(local, const Offset(100, 0));
    expect(NodeEditing.nodeAt(curve, local!, 1), const PathNode(0, 1));
    final SegmentHit? hit =
        NodeEditing.segmentAt(curve, const Offset(50, 1), 2);
    expect(hit?.segment, 0);
    expect(hit!.t, closeTo(0.5, 0.05));
  });

  test('a selection keeps only nodes that still exist', () {
    final VectorCurve curve = wave();
    final NodeSelection selection = NodeSelection()
      ..edit(curve)
      ..selectAll();
    expect(selection.nodes, hasLength(3));
    NodeEditing.deleteNodes(curve, const <PathNode>[PathNode(0, 1)]);
    selection.prune();
    expect(selection.nodes, hasLength(2));
  });
}
