import 'dart:math' as math;
import '../../geometry/offset.dart';
import '../../geometry/rect.dart';
import '../../geometry/transform2d.dart';
import 'constants.dart';
import 'document_object.dart';
import 'style.dart';

// ---------------------------------------------------------------------------
// SelectableObject — base for anything the user can click
// ---------------------------------------------------------------------------

/// Abstract parent for objects the user can select, move, and transform.
abstract class SelectableObject extends DocumentObject {
  SelectableObject({
    super.parent,
    super.children,
    List<double>? trafo,
    VectorStyle? style,
  })  : trafo = trafo ?? List.of(kNormalTrafo),
        style = style ?? VectorStyle.empty;

  /// The 6-element affine transform `[a, b, c, d, tx, ty]`.
  ///
  /// Applied as:
  /// ```
  /// x' = a*x + c*y + tx
  /// y' = b*x + d*y + ty
  /// ```
  List<double> trafo;

  /// Visual style (fill + stroke + text).
  VectorStyle style;

  @override
  bool get isSelectable => true;

  /// Converts this object to a curve representation (if applicable).
  /// Returns `null` if conversion is not supported.
  DocumentObject? toCurve() => null;

  /// Applies [newTrafo] **in document space**, on top of the current one.
  ///
  /// The order of the multiplication is the whole contract here, and getting
  /// it backwards is what made dragging the sample star fly off the page.
  ///
  /// [multiplyTrafo] composes as `A(B(point))`, so `multiplyTrafo(trafo,
  /// newTrafo)` would apply `newTrafo` to the object's **local** coordinates -
  /// before its own transform, and therefore scaled by it. A star whose
  /// `trafo` is `[90, 0, 0, 90, cx, cy]` moved ninety points for every point
  /// the pointer travelled, and left the viewport on the first drag.
  ///
  /// The caller always means document space: a move is "by this many points on
  /// the page", a resize is "about this anchor on the page". So the new
  /// transform is applied *after* the object's own, which is
  /// `multiplyTrafo(newTrafo, trafo)`. That is also exactly what sK1 does -
  /// `libgeom.multiply_trafo` wraps `cairo.Matrix.multiply`, whose result
  /// applies the *first* argument first, so sK1's
  /// `multiply_trafo(self.trafo, trafo)` and this call mean the same thing
  /// under two opposite argument conventions.
  void applyTrafo(List<double> newTrafo) {
    trafo = multiplyTrafo(newTrafo, trafo);
    updateBbox();
  }

  /// Gets a snapshot of the current transform state for undo.
  TrafoSnapshot getTrafoSnapshot() => TrafoSnapshot(
        object: this,
        trafo: List.of(trafo),
        bbox: cacheBbox,
      );

  /// Restores transform state from [snapshot].
  void setTrafoSnapshot(TrafoSnapshot snapshot) {
    trafo = List.of(snapshot.trafo);
    cacheBbox = snapshot.bbox;
  }

  @override
  void copyFields(DocumentObject target) {
    super.copyFields(target);
    if (target is SelectableObject) {
      target.trafo = List.of(trafo);
      target.style = style.copyWith();
    }
  }

  /// Convert the 6-element trafo to a [Transform2D].
  Transform2D get transform2D =>
      Transform2D(trafo[0], trafo[1], trafo[2], trafo[3], trafo[4], trafo[5]);
}

/// Snapshot of an object's transform state (for undo/redo).
class TrafoSnapshot {
  const TrafoSnapshot({
    required this.object,
    required this.trafo,
    required this.bbox,
  });
  final SelectableObject object;
  final List<double> trafo;
  final Rect bbox;
}

// ---------------------------------------------------------------------------
// Group
// ---------------------------------------------------------------------------

/// A group of selectable objects that move and transform together.
class VectorGroup extends SelectableObject {
  VectorGroup({
    super.parent,
    super.children,
    super.trafo,
    super.style,
  });

  @override
  bool get isGroup => true;

  @override
  void applyTrafo(List<double> newTrafo) {
    for (final child in children) {
      if (child is SelectableObject) {
        child.applyTrafo(newTrafo);
      }
    }
    updateBbox();
  }

  @override
  void updateBbox() {
    if (children.isEmpty) {
      cacheBbox = Rect.zero;
      return;
    }
    var bbox = children.first.cacheBbox;
    for (var i = 1; i < children.length; i++) {
      bbox = _unionRect(bbox, children[i].cacheBbox);
    }
    cacheBbox = bbox;
  }

  @override
  void update() {
    for (final child in children) {
      child.update();
    }
    updateBbox();
  }

  @override
  TrafoSnapshot getTrafoSnapshot() {
    final childSnapshots = <TrafoSnapshot>[];
    for (final child in children) {
      if (child is SelectableObject) {
        childSnapshots.add(child.getTrafoSnapshot());
      }
    }
    return GroupTrafoSnapshot(
      object: this,
      trafo: List.of(trafo),
      bbox: cacheBbox,
      childSnapshots: childSnapshots,
    );
  }

  @override
  void setTrafoSnapshot(TrafoSnapshot snapshot) {
    super.setTrafoSnapshot(snapshot);
    if (snapshot is GroupTrafoSnapshot) {
      for (final childSnap in snapshot.childSnapshots) {
        childSnap.object.setTrafoSnapshot(childSnap);
      }
    }
  }

  @override
  DocumentObject createEmpty() => VectorGroup();

  @override
  String toString() => 'VectorGroup(${children.length} children)';
}

/// Extended snapshot that also stores child transforms.
class GroupTrafoSnapshot extends TrafoSnapshot {
  const GroupTrafoSnapshot({
    required super.object,
    required super.trafo,
    required super.bbox,
    required this.childSnapshots,
  });
  final List<TrafoSnapshot> childSnapshots;
}

// ---------------------------------------------------------------------------
// Text-on-path group
// ---------------------------------------------------------------------------

/// A group where text flows along a reference path.
///
/// The first child is the path; subsequent children are text objects.
/// Each text child has associated data: `(basePoint, align, sideFlag)`.
class TPGroup extends VectorGroup {
  TPGroup({
    super.parent,
    super.children,
    super.trafo,
    super.style,
    List<TPChildData?>? childrenData,
  }) : childrenData = childrenData ?? [];

  /// Per-child positioning data (first entry is `null` for the path).
  List<TPChildData?> childrenData;

  @override
  bool get isTPGroup => true;
  @override
  bool get isGroup => true;

  @override
  DocumentObject createEmpty() => TPGroup();

  @override
  void copyFields(DocumentObject target) {
    super.copyFields(target);
    if (target is TPGroup) {
      target.childrenData =
          childrenData.map((d) => d?.copyWith()).toList();
    }
  }

  @override
  String toString() => 'TPGroup(${children.length} children)';
}

/// Positioning data for a text-on-path child.
class TPChildData {
  const TPChildData({
    this.basePoint = 0.0,
    this.alignment = TextAlign.left,
    this.otherSide = false,
  });

  /// Position along the path, 0.0 → 1.0.
  final double basePoint;

  /// Text alignment relative to [basePoint].
  final TextAlign alignment;

  /// If true, text is placed on the opposite side of the path.
  final bool otherSide;

  TPChildData copyWith({
    double? basePoint,
    TextAlign? alignment,
    bool? otherSide,
  }) =>
      TPChildData(
        basePoint: basePoint ?? this.basePoint,
        alignment: alignment ?? this.alignment,
        otherSide: otherSide ?? this.otherSide,
      );
}

// ---------------------------------------------------------------------------
// Container (clipping group)
// ---------------------------------------------------------------------------

/// A group where the first child acts as a clipping container for the rest.
class VectorContainer extends VectorGroup {
  VectorContainer({
    super.parent,
    super.children,
    super.trafo,
    super.style,
  });

  @override
  bool get isContainer => true;
  @override
  bool get isGroup => true;

  /// The first child is the clipping shape.
  DocumentObject? get clipShape =>
      children.isNotEmpty ? children.first : null;

  @override
  void updateBbox() {
    if (children.isNotEmpty) {
      cacheBbox = children.first.cacheBbox;
    } else {
      cacheBbox = Rect.zero;
    }
  }

  @override
  DocumentObject createEmpty() => VectorContainer();

  @override
  String toString() => 'VectorContainer(${children.length} children)';
}

// ---------------------------------------------------------------------------
// Affine helpers
// ---------------------------------------------------------------------------

/// Multiplies two 6-element affine transforms.
///
/// If A = `[a0, a1, a2, a3, a4, a5]` and B = `[b0, b1, b2, b3, b4, b5]`,
/// the result is `A * B` applied as `A(B(point))`.
List<double> multiplyTrafo(List<double> a, List<double> b) {
  return [
    a[0] * b[0] + a[2] * b[1],
    a[1] * b[0] + a[3] * b[1],
    a[0] * b[2] + a[2] * b[3],
    a[1] * b[2] + a[3] * b[3],
    a[0] * b[4] + a[2] * b[5] + a[4],
    a[1] * b[4] + a[3] * b[5] + a[5],
  ];
}

/// Applies a 6-element affine transform to a point.
Offset applyTrafoToPoint(Offset point, List<double> trafo) {
  return Offset(
    trafo[0] * point.dx + trafo[2] * point.dy + trafo[4],
    trafo[1] * point.dx + trafo[3] * point.dy + trafo[5],
  );
}

/// Applies a 6-element affine transform to a list of points.
List<Offset> applyTrafoToPoints(List<Offset> points, List<double> trafo) {
  return points.map((p) => applyTrafoToPoint(p, trafo)).toList();
}

/// Returns a rotation trafo for the given angle (radians).
List<double> trafoRotate(double angle) {
  final cos = math.cos(angle);
  final sin = math.sin(angle);
  return [cos, sin, -sin, cos, 0.0, 0.0];
}

/// Returns the distance between two points.
double pointsDistance(Offset a, Offset b) {
  final dx = b.dx - a.dx;
  final dy = b.dy - a.dy;
  return math.sqrt(dx * dx + dy * dy);
}

/// Returns the angle in radians from point [a] to point [b].
double getPointAngle(Offset a, Offset b) {
  return math.atan2(b.dy - a.dy, b.dx - a.dx);
}

Rect _unionRect(Rect a, Rect b) {
  if (a == Rect.zero) return b;
  if (b == Rect.zero) return a;
  return Rect.fromLTRB(
    a.left < b.left ? a.left : b.left,
    a.top < b.top ? a.top : b.top,
    a.right > b.right ? a.right : b.right,
    a.bottom > b.bottom ? a.bottom : b.bottom,
  );
}
