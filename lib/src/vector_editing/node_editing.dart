/// Editing a curve's nodes: what CorelDRAW's Shape tool (F10) does, as
/// operations on paths with no widget in them.
///
/// A node is where two segments meet - a path's start, or a segment's end.
/// A closed path repeats its start as its last point (that is how the pen
/// closes one), and the two are one node here: moving it moves both.
///
/// Everything works in the curve's **own** coordinates: a curve's points
/// live under its `trafo`, and the caller maps a document point in with
/// [NodeEditing.toLocal] before asking, so a rotated or scaled curve edits
/// like any other.
library;

import 'dart:math' as math;

import '../geometry/offset.dart';
import '../graphics/vector/constants.dart';
import '../graphics/vector/primitives.dart';
import '../graphics/vector/selectable_objects.dart' show applyTrafoToPoint;

/// Node [index] of path [path]: 0 is the path's start, `i` the end of
/// segment `i - 1`.
final class PathNode {
  const PathNode(this.path, this.index);

  final int path;
  final int index;

  @override
  bool operator ==(Object other) =>
      other is PathNode && other.path == path && other.index == index;

  @override
  int get hashCode => Object.hash(path, index);

  @override
  String toString() => 'PathNode($path, $index)';
}

/// Which of a node's two Bézier handles.
enum NodeHandleSide {
  /// The handle of the segment arriving at the node (its `control2`).
  incoming,

  /// The handle of the segment leaving it (its `control1`).
  outgoing,
}

/// One handle of one node.
final class NodeHandleRef {
  const NodeHandleRef(this.node, this.side);

  final PathNode node;
  final NodeHandleSide side;

  @override
  bool operator ==(Object other) =>
      other is NodeHandleRef && other.node == node && other.side == side;

  @override
  int get hashCode => Object.hash(node, side);
}

/// A point on a segment: segment [segment] of path [path], at parameter [t].
final class SegmentHit {
  const SegmentHit(this.path, this.segment, this.t);

  final int path;
  final int segment;
  final double t;
}

/// The curve whose nodes are being edited, and which of them are selected.
final class NodeSelection {
  VectorCurve? _curve;
  final Set<PathNode> _nodes = <PathNode>{};

  VectorCurve? get curve => _curve;
  Set<PathNode> get nodes => Set<PathNode>.unmodifiable(_nodes);
  bool get hasNodes => _nodes.isNotEmpty;

  /// Edits [curve], with no node selected; null stops editing.
  void edit(VectorCurve? curve) {
    if (identical(curve, _curve)) return;
    _curve = curve;
    _nodes.clear();
  }

  void clearNodes() => _nodes.clear();

  void select(Iterable<PathNode> nodes, {bool additive = false}) {
    if (!additive) _nodes.clear();
    _nodes.addAll(nodes);
  }

  void toggle(PathNode node) {
    if (!_nodes.remove(node)) _nodes.add(node);
  }

  /// Every node of the curve.
  void selectAll() {
    final VectorCurve? curve = _curve;
    if (curve == null) return;
    _nodes
      ..clear()
      ..addAll(NodeEditing.nodesOf(curve));
  }

  /// Drops nodes that no longer exist after an edit changed the paths.
  void prune() {
    final VectorCurve? curve = _curve;
    if (curve == null) {
      _nodes.clear();
      return;
    }
    _nodes.removeWhere((PathNode node) =>
        node.path >= curve.paths.length ||
        node.index >= NodeEditing.nodeCount(curve.paths[node.path]));
  }
}

/// The node operations. Each one changes the curve's paths and calls
/// `curve.update()`; recording an undo step is the caller's business.
abstract final class NodeEditing {
  static const double _epsilon = 1e-9;

  // --- reading ----------------------------------------------------------------

  static Offset endOf(Object point) =>
      point is CurvePoint ? point.endpoint : point as Offset;

  /// Whether [path] repeats its start as its last point - a closed path as
  /// the pen and the shapes draw one.
  static bool closesOnStart(VectorPath path) =>
      path.isClosed &&
      path.points.isNotEmpty &&
      (endOf(path.points.last) - path.start).distance < 1e-6;

  static int nodeCount(VectorPath path) =>
      path.points.length + 1 - (closesOnStart(path) ? 1 : 0);

  static Offset nodePoint(VectorPath path, int index) =>
      index == 0 ? path.start : endOf(path.points[index - 1]);

  /// Every node of [curve].
  static Iterable<PathNode> nodesOf(VectorCurve curve) sync* {
    for (var p = 0; p < curve.paths.length; p++) {
      for (var i = 0; i < nodeCount(curve.paths[p]); i++) {
        yield PathNode(p, i);
      }
    }
  }

  /// The index of the segment arriving at node [index], or -1.
  static int _incomingSegment(VectorPath path, int index) {
    if (index > 0) return index - 1;
    return closesOnStart(path) ? path.points.length - 1 : -1;
  }

  /// The index of the segment leaving node [index], or -1.
  static int _outgoingSegment(VectorPath path, int index) =>
      index < path.points.length ? index : -1;

  /// [node]'s handle on [side], or null when that segment is a line or does
  /// not exist.
  static Offset? handle(VectorCurve curve, NodeHandleRef ref) {
    final VectorPath path = curve.paths[ref.node.path];
    if (ref.side == NodeHandleSide.incoming) {
      final int s = _incomingSegment(path, ref.node.index);
      final Object? point = s < 0 ? null : path.points[s];
      return point is CurvePoint ? point.control2 : null;
    }
    final int s = _outgoingSegment(path, ref.node.index);
    final Object? point = s < 0 ? null : path.points[s];
    return point is CurvePoint ? point.control1 : null;
  }

  /// The type of [node]: what the segment arriving at it says.
  static NodeType typeOf(VectorCurve curve, PathNode node) {
    final VectorPath path = curve.paths[node.path];
    final int s = _incomingSegment(path, node.index);
    final Object? point = s < 0 ? null : path.points[s];
    return point is CurvePoint ? point.nodeType : NodeType.cusp;
  }

  // --- coordinates ------------------------------------------------------------

  /// [document] in [curve]'s own coordinates, or null when its transform
  /// cannot be inverted (a curve squashed to a line).
  static Offset? toLocal(VectorCurve curve, Offset document) {
    final List<double> t = curve.trafo;
    final double det = t[0] * t[3] - t[1] * t[2];
    if (det.abs() < _epsilon) return null;
    final double dx = document.dx - t[4];
    final double dy = document.dy - t[5];
    return Offset(
        (t[3] * dx - t[2] * dy) / det, (-t[1] * dx + t[0] * dy) / det);
  }

  static Offset toDocument(VectorCurve curve, Offset local) =>
      applyTrafoToPoint(local, curve.trafo);

  /// How many local units one document unit is - for a tolerance given in
  /// document units.
  static double localScale(VectorCurve curve) {
    final List<double> t = curve.trafo;
    final double det = (t[0] * t[3] - t[1] * t[2]).abs();
    return det < _epsilon ? 1 : 1 / math.sqrt(det);
  }

  // --- hit testing (local coordinates) ----------------------------------------

  static PathNode? nodeAt(VectorCurve curve, Offset local, double tolerance) {
    PathNode? best;
    var bestDistance = tolerance;
    for (final PathNode node in nodesOf(curve)) {
      final double d =
          (nodePoint(curve.paths[node.path], node.index) - local).distance;
      if (d <= bestDistance) {
        bestDistance = d;
        best = node;
      }
    }
    return best;
  }

  /// A handle of one of [visibleFor] near [local] - only a selected node's
  /// handles are drawn, so only they can be grabbed.
  static NodeHandleRef? handleAt(
    VectorCurve curve,
    Iterable<PathNode> visibleFor,
    Offset local,
    double tolerance,
  ) {
    NodeHandleRef? best;
    var bestDistance = tolerance;
    for (final PathNode node in visibleFor) {
      for (final NodeHandleSide side in NodeHandleSide.values) {
        final NodeHandleRef ref = NodeHandleRef(node, side);
        final Offset? at = handle(curve, ref);
        if (at == null) continue;
        final double d = (at - local).distance;
        if (d <= bestDistance) {
          bestDistance = d;
          best = ref;
        }
      }
    }
    return best;
  }

  /// The nearest point on a segment within [tolerance] of [local].
  static SegmentHit? segmentAt(
      VectorCurve curve, Offset local, double tolerance) {
    SegmentHit? best;
    var bestDistance = tolerance;
    for (var p = 0; p < curve.paths.length; p++) {
      final VectorPath path = curve.paths[p];
      for (var s = 0; s < path.points.length; s++) {
        final Offset from = nodePoint(path, s);
        final Object to = path.points[s];
        const int steps = 32;
        for (var k = 0; k <= steps; k++) {
          final double t = k / steps;
          final double d = (_pointOn(from, to, t) - local).distance;
          if (d <= bestDistance) {
            bestDistance = d;
            best = SegmentHit(p, s, t);
          }
        }
      }
    }
    return best;
  }

  static Offset _pointOn(Offset from, Object to, double t) {
    if (to is CurvePoint) {
      final double u = 1 - t;
      return from * (u * u * u) +
          to.control1 * (3 * u * u * t) +
          to.control2 * (3 * u * t * t) +
          to.endpoint * (t * t * t);
    }
    final Offset end = to as Offset;
    return from + (end - from) * t;
  }

  // --- moving -----------------------------------------------------------------

  /// Moves [nodes] by [delta] (local units), carrying their handles.
  static void moveNodes(
      VectorCurve curve, Iterable<PathNode> nodes, Offset delta) {
    for (final PathNode node in nodes) {
      final VectorPath path = curve.paths[node.path];
      final int index = node.index;
      if (index == 0) {
        // Asked before the start moves: afterwards the closing point no
        // longer sits on it.
        final bool closing = closesOnStart(path);
        path.start += delta;
        if (closing) _moveEnd(path, path.points.length - 1, delta);
      } else {
        _moveEnd(path, index - 1, delta);
      }
      final int out = _outgoingSegment(path, index);
      if (out >= 0) {
        final Object point = path.points[out];
        if (point is CurvePoint) {
          path.points[out] = point.copyWith(control1: point.control1 + delta);
        }
      }
    }
    curve.update();
  }

  /// Bends segment [hit] so the point at its parameter moves by [delta]
  /// (local units) and its ends stay - dragging a segment with the Shape
  /// tool. A straight segment becomes a curve first.
  ///
  /// The two handles share the move by how near the grabbed point is to
  /// each end (Inkscape's weighting): grabbed near the start, the first
  /// handle does almost all of it. Applied to the handles of the segment as
  /// it was at the press, a drag is exact for any delta: the grabbed point
  /// lands under the pointer.
  static void dragSegment(VectorCurve curve, SegmentHit hit, Offset delta) {
    if (delta == Offset.zero) return;
    final VectorPath path = curve.paths[hit.path];
    final int s = hit.segment;
    final Offset from = nodePoint(path, s);
    final Object point = path.points[s];
    final CurvePoint segment = point is CurvePoint
        ? point
        : CurvePoint(_lerp(from, point as Offset, 1 / 3),
            _lerp(from, point, 2 / 3), point);
    final double t = hit.t.clamp(1e-3, 1 - 1e-3);
    final double weight;
    if (t <= 1 / 6) {
      weight = 0;
    } else if (t <= .5) {
      weight = math.pow((6 * t - 1) / 2, 3) / 2;
    } else if (t <= 5 / 6) {
      weight = (1 - math.pow((6 * (1 - t) - 1) / 2, 3)) / 2 + .5;
    } else {
      weight = 1;
    }
    final double u = 1 - t;
    path.points[s] = segment.copyWith(
      control1: segment.control1 + delta * ((1 - weight) / (3 * t * u * u)),
      control2: segment.control2 + delta * (weight / (3 * t * t * u)),
    );
    curve.update();
  }

  /// Moves the end of segment [s] and its arriving handle.
  static void _moveEnd(VectorPath path, int s, Offset delta) {
    if (s < 0) return;
    final Object point = path.points[s];
    path.points[s] = point is CurvePoint
        ? point.copyWith(
            control2: point.control2 + delta,
            endpoint: point.endpoint + delta,
          )
        : (point as Offset) + delta;
  }

  /// Puts [ref] at [local]; a smooth node turns its other handle to stay in
  /// line, a symmetrical one mirrors it.
  static void moveHandle(VectorCurve curve, NodeHandleRef ref, Offset local) {
    final VectorPath path = curve.paths[ref.node.path];
    final Offset node = nodePoint(path, ref.node.index);
    final int incoming = _incomingSegment(path, ref.node.index);
    final int outgoing = _outgoingSegment(path, ref.node.index);
    final int own = ref.side == NodeHandleSide.incoming ? incoming : outgoing;
    if (own < 0) return;
    final Object point = path.points[own];
    if (point is! CurvePoint) return;
    path.points[own] = ref.side == NodeHandleSide.incoming
        ? point.copyWith(control2: local)
        : point.copyWith(control1: local);

    final NodeType type = typeOf(curve, ref.node);
    final int other = ref.side == NodeHandleSide.incoming ? outgoing : incoming;
    if (type != NodeType.cusp && other >= 0) {
      final Object opposite = path.points[other];
      if (opposite is CurvePoint) {
        final Offset away = node - local;
        final double length = away.distance;
        if (length > _epsilon) {
          final Offset current = ref.side == NodeHandleSide.incoming
              ? opposite.control1
              : opposite.control2;
          final double keep =
              type == NodeType.symmetrical ? length : (current - node).distance;
          final Offset mirrored = node + away * (keep / length);
          path.points[other] = ref.side == NodeHandleSide.incoming
              ? opposite.copyWith(control1: mirrored)
              : opposite.copyWith(control2: mirrored);
        }
      }
    }
    curve.update();
  }

  // --- adding and removing ----------------------------------------------------

  /// Splits segment [hit] at its parameter, de Casteljau's way, so the
  /// curve keeps its shape exactly. Returns the new node.
  static PathNode insertNode(VectorCurve curve, SegmentHit hit) {
    final VectorPath path = curve.paths[hit.path];
    final Offset from = nodePoint(path, hit.segment);
    final Object to = path.points[hit.segment];
    final double t = hit.t.clamp(0.0, 1.0);
    if (to is CurvePoint) {
      final Offset p01 = _lerp(from, to.control1, t);
      final Offset p12 = _lerp(to.control1, to.control2, t);
      final Offset p23 = _lerp(to.control2, to.endpoint, t);
      final Offset p012 = _lerp(p01, p12, t);
      final Offset p123 = _lerp(p12, p23, t);
      final Offset mid = _lerp(p012, p123, t);
      path.points
        ..[hit.segment] = CurvePoint(p01, p012, mid, NodeType.smooth)
        ..insert(
            hit.segment + 1, CurvePoint(p123, p23, to.endpoint, to.nodeType));
    } else {
      final Offset end = to as Offset;
      path.points.insert(hit.segment, _lerp(from, end, t));
    }
    curve.update();
    return PathNode(hit.path, hit.segment + 1);
  }

  static Offset _lerp(Offset a, Offset b, double t) => a + (b - a) * t;

  /// Removes [nodes], joining the segments on either side of each. A path
  /// left with fewer than two nodes is removed. Returns false when nothing
  /// of the curve is left - the caller deletes the object.
  static bool deleteNodes(VectorCurve curve, Iterable<PathNode> nodes) {
    final List<PathNode> ordered = nodes.toList()
      ..sort((PathNode a, PathNode b) => a.path != b.path
          ? b.path.compareTo(a.path)
          : b.index.compareTo(a.index));
    for (final PathNode node in ordered) {
      if (node.path >= curve.paths.length) continue;
      final VectorPath path = curve.paths[node.path];
      if (node.index >= nodeCount(path)) continue;
      _deleteNode(path, node.index);
    }
    curve.paths.removeWhere(
        (VectorPath path) => nodeCount(path) < (path.isClosed ? 3 : 2));
    curve.update();
    return curve.paths.isNotEmpty;
  }

  static void _deleteNode(VectorPath path, int index) {
    final bool closed = closesOnStart(path);
    if (index == 0) {
      if (path.points.isEmpty) return;
      final Object first = path.points.removeAt(0);
      path.start = endOf(first);
      if (closed && path.points.isNotEmpty) {
        // The closing segment now ends at the new start.
        final Object last = path.points.last;
        path.points[path.points.length - 1] = last is CurvePoint
            ? last.copyWith(endpoint: path.start)
            : path.start;
      }
      return;
    }
    final int arriving = index - 1;
    if (index >= path.points.length) {
      // The last node of an open path: its segment goes.
      path.points.removeAt(arriving);
      return;
    }
    final Object a = path.points[arriving];
    final Object b = path.points[index];
    final Object merged = (a is CurvePoint || b is CurvePoint)
        ? CurvePoint(
            a is CurvePoint ? a.control1 : nodePoint(path, arriving),
            b is CurvePoint ? b.control2 : endOf(b),
            endOf(b),
            b is CurvePoint ? b.nodeType : NodeType.cusp,
          )
        : endOf(b);
    path.points
      ..[arriving] = merged
      ..removeAt(index);
  }

  // --- segment and node types -------------------------------------------------

  /// The segments arriving at [nodes] become straight lines.
  static void toLine(VectorCurve curve, Iterable<PathNode> nodes) {
    for (final PathNode node in nodes) {
      final VectorPath path = curve.paths[node.path];
      final int s = _incomingSegment(path, node.index);
      if (s < 0) continue;
      path.points[s] = endOf(path.points[s]);
    }
    curve.update();
  }

  /// The segments arriving at [nodes] become curves, their handles a third
  /// of the way along, so the shape does not move until they are dragged.
  static void toCurve(VectorCurve curve, Iterable<PathNode> nodes) {
    for (final PathNode node in nodes) {
      final VectorPath path = curve.paths[node.path];
      final int s = _incomingSegment(path, node.index);
      if (s < 0) continue;
      final Object point = path.points[s];
      if (point is CurvePoint) continue;
      final Offset from = nodePoint(path, s);
      final Offset end = point as Offset;
      path.points[s] =
          CurvePoint(_lerp(from, end, 1 / 3), _lerp(from, end, 2 / 3), end);
    }
    curve.update();
  }

  /// Makes [nodes] cusp, smooth or symmetrical; smooth and symmetrical line
  /// the leaving handle up with the arriving one.
  static void setType(
      VectorCurve curve, Iterable<PathNode> nodes, NodeType type) {
    for (final PathNode node in nodes) {
      final VectorPath path = curve.paths[node.path];
      final int incoming = _incomingSegment(path, node.index);
      if (incoming < 0) continue;
      final Object arriving = path.points[incoming];
      if (arriving is! CurvePoint) continue;
      path.points[incoming] = arriving.copyWith(nodeType: type);
      if (type == NodeType.cusp) continue;
      final int outgoing = _outgoingSegment(path, node.index);
      if (outgoing < 0) continue;
      final Object leaving = path.points[outgoing];
      if (leaving is! CurvePoint) continue;
      final Offset at = nodePoint(path, node.index);
      final Offset away = at - arriving.control2;
      final double length = away.distance;
      if (length < _epsilon) continue;
      final double keep = type == NodeType.symmetrical
          ? length
          : (leaving.control1 - at).distance;
      path.points[outgoing] =
          leaving.copyWith(control1: at + away * (keep / length));
    }
    curve.update();
  }

  // --- structure --------------------------------------------------------------

  /// Breaks the path at [node]: an open path becomes two, a closed path
  /// opens there. Returns the nodes at the break - the ends to join again.
  static List<PathNode> breakAt(VectorCurve curve, PathNode node) {
    final VectorPath path = curve.paths[node.path];
    final int index = node.index;
    if (path.isClosed) {
      final bool repeats = closesOnStart(path);
      final List<Object> segments = List<Object>.of(path.points);
      if (!repeats) segments.add(path.start);
      // Rotate so the path starts and ends at [node].
      final Offset at = nodePoint(path, index);
      final List<Object> rotated = <Object>[
        ...segments.sublist(index),
        ...segments.sublist(0, index),
      ];
      path
        ..start = at
        ..points = rotated
        ..closure = PathClosure.opened;
      curve.update();
      return <PathNode>[
        PathNode(node.path, 0),
        PathNode(node.path, rotated.length),
      ];
    }
    if (index == 0 || index >= path.points.length) return <PathNode>[node];
    final VectorPath tail = VectorPath(
      start: nodePoint(path, index),
      points: path.points.sublist(index),
    );
    path.points = path.points.sublist(0, index);
    curve.paths.insert(node.path + 1, tail);
    curve.update();
    return <PathNode>[
      PathNode(node.path, index),
      PathNode(node.path + 1, 0),
    ];
  }

  static bool _isEnd(VectorCurve curve, PathNode node) {
    final VectorPath path = curve.paths[node.path];
    return path.isOpen && (node.index == 0 || node.index == path.points.length);
  }

  /// Joins two end nodes of open paths: the two ends of one path close it,
  /// the ends of two paths make them one, with a straight segment between
  /// them when they are apart. False when [a] and [b] are not both ends.
  static bool join(VectorCurve curve, PathNode a, PathNode b) {
    if (!_isEnd(curve, a) || !_isEnd(curve, b) || a == b) return false;
    if (a.path == b.path) {
      final VectorPath path = curve.paths[a.path];
      if ((endOf(path.points.last) - path.start).distance > 1e-6) {
        path.points.add(path.start);
      }
      path.closure = PathClosure.closed;
      curve.update();
      return true;
    }
    // Make [first] end at a and [second] start at b, then append.
    VectorPath first = curve.paths[a.path];
    VectorPath second = curve.paths[b.path];
    if (a.index == 0) first = reversed(first);
    if (b.index != 0) second = reversed(second);
    final Offset joint =
        endOf(first.points.isEmpty ? first.start : first.points.last);
    final List<Object> points = <Object>[
      ...first.points,
      if ((second.start - joint).distance > 1e-6) second.start,
      ...second.points,
    ];
    final VectorPath merged = VectorPath(start: first.start, points: points);
    final int keep = math.min(a.path, b.path);
    final int drop = math.max(a.path, b.path);
    curve.paths
      ..[keep] = merged
      ..removeAt(drop);
    curve.update();
    return true;
  }

  /// [path] drawn the other way.
  static VectorPath reversed(VectorPath path) {
    final List<Offset> nodes = <Offset>[
      path.start,
      for (final Object point in path.points) endOf(point),
    ];
    final List<Object> points = <Object>[];
    for (var s = path.points.length - 1; s >= 0; s--) {
      final Object point = path.points[s];
      final Offset end = nodes[s];
      points.add(point is CurvePoint
          ? CurvePoint(point.control2, point.control1, end, point.nodeType)
          : end);
    }
    return VectorPath(
      start: nodes.last,
      points: points,
      closure: path.closure,
    );
  }

  /// Reverses every path that holds one of [nodes] (all when empty).
  static void reverse(VectorCurve curve, Iterable<PathNode> nodes) {
    final Set<int> which = <int>{for (final PathNode n in nodes) n.path};
    for (var p = 0; p < curve.paths.length; p++) {
      if (which.isEmpty || which.contains(p)) {
        curve.paths[p] = reversed(curve.paths[p]);
      }
    }
    curve.update();
  }

  /// Closes every open path that holds one of [nodes] (all when empty).
  static void close(VectorCurve curve, Iterable<PathNode> nodes) {
    final Set<int> which = <int>{for (final PathNode n in nodes) n.path};
    for (var p = 0; p < curve.paths.length; p++) {
      final VectorPath path = curve.paths[p];
      if (path.isClosed || (which.isNotEmpty && !which.contains(p))) continue;
      if (path.points.isEmpty) continue;
      if ((endOf(path.points.last) - path.start).distance > 1e-6) {
        path.points.add(path.start);
      }
      path.closure = PathClosure.closed;
    }
    curve.update();
  }
}
