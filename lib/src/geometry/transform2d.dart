/// A 2D affine transform stored as six doubles instead of a 4x4 matrix.
///
/// This is a deliberate, documented deviation from the roadmap. Section 9.6
/// sketches the display list with `Matrix4` on `TransformCommand`, but section
/// 4.2 puts 3D in "escopo posterior", and every transform a 2D user interface
/// actually performs - translation, scale, rotation, skew, and any
/// composition of them - is affine. A 4x4 matrix spends 16 doubles to carry
/// six meaningful numbers, and the ten that are always 0 or 1 still get
/// multiplied on every concatenation, on a path that runs per node per frame.
///
/// The trade is narrow and reversible: this type cannot express perspective
/// or a Z axis. When 3D enters scope, a `Matrix4` can be added alongside it
/// and this type keeps serving the 2D fast path, the same way a general
/// transform and a translation-only fast path coexist here - see
/// [Transform2D.isTranslationOnly]. What must not happen is this type
/// silently growing a fake third dimension.
///
/// The stored matrix is
///
///     | a  c  tx |
///     | b  d  ty |
///     | 0  0  1  |
///
/// applied to column vectors, so a point maps as
/// `(x, y) -> (a*x + c*y + tx, b*x + d*y + ty)`.
library;

import 'dart:math' as math;

import 'offset.dart';
import 'rect.dart';

/// An immutable affine transform of the plane.
final class Transform2D {
  const Transform2D(this.a, this.b, this.c, this.d, this.tx, this.ty);

  static const Transform2D identity = Transform2D(1, 0, 0, 1, 0, 0);

  const Transform2D.translation(double dx, double dy)
    : this(1, 0, 0, 1, dx, dy);

  const Transform2D.scaling(double sx, double sy) : this(sx, 0, 0, sy, 0, 0);

  /// The standard mathematical rotation, which turns the x axis toward the y
  /// axis. Window systems give us a y-down space, so a positive angle appears
  /// clockwise on screen - worth stating because the same formula is
  /// described as counter-clockwise everywhere y points up.
  factory Transform2D.rotation(double radians) {
    final cos = math.cos(radians);
    final sin = math.sin(radians);
    return Transform2D(cos, sin, -sin, cos, 0, 0);
  }

  /// Builds scale, then rotation, then translation in one step - the order a
  /// UI node's own transform properties are understood in.
  ///
  /// The six products are written out rather than built from two [multiply]
  /// calls: the intermediate transforms would be allocated and immediately
  /// discarded, and half their multiplications are against known zeros.
  factory Transform2D.compose({
    Offset translation = Offset.zero,
    double rotation = 0,
    double scaleX = 1,
    double scaleY = 1,
  }) {
    final cos = math.cos(rotation);
    final sin = math.sin(rotation);
    return Transform2D(
      cos * scaleX,
      sin * scaleX,
      -sin * scaleY,
      cos * scaleY,
      translation.dx,
      translation.dy,
    );
  }

  final double a;
  final double b;
  final double c;
  final double d;
  final double tx;
  final double ty;

  /// Concatenation, with **this applied after [other]**: the result maps a
  /// point the way `this.transformOffset(other.transformOffset(p))` would.
  ///
  /// That is matrix `this * other`, and it is the order that reads correctly
  /// when walking a tree downward - `parentToWorld.multiply(childToParent)`
  /// yields child-to-world. The opposite convention is a common source of
  /// transforms that look right until rotation and translation are mixed, so
  /// the argument order is worth checking at every call site.
  Transform2D multiply(Transform2D other) => Transform2D(
    a * other.a + c * other.b,
    b * other.a + d * other.b,
    a * other.c + c * other.d,
    b * other.c + d * other.d,
    a * other.tx + c * other.ty + tx,
    b * other.tx + d * other.ty + ty,
  );

  Offset transformOffset(Offset offset) => Offset(
    a * offset.dx + c * offset.dy + tx,
    b * offset.dx + d * offset.dy + ty,
  );

  /// The axis-aligned bounding box of the transformed rectangle.
  ///
  /// Under rotation or skew the image of a rectangle is not a rectangle, so
  /// this necessarily grows the area; it is the right answer for culling and
  /// dirty regions, and the wrong one to use as a clip if the exact
  /// quadrilateral matters.
  ///
  /// The four corners are mapped as bare doubles instead of through
  /// [transformOffset], because this runs per node per frame and the four
  /// intermediate [Offset]s would be garbage the moment the extremes are
  /// taken.
  Rect transformRect(Rect rect) {
    final x1 = a * rect.left + c * rect.top + tx;
    final y1 = b * rect.left + d * rect.top + ty;
    final x2 = a * rect.right + c * rect.top + tx;
    final y2 = b * rect.right + d * rect.top + ty;
    final x3 = a * rect.right + c * rect.bottom + tx;
    final y3 = b * rect.right + d * rect.bottom + ty;
    final x4 = a * rect.left + c * rect.bottom + tx;
    final y4 = b * rect.left + d * rect.bottom + ty;
    return Rect.fromLTRB(
      math.min(math.min(x1, x2), math.min(x3, x4)),
      math.min(math.min(y1, y2), math.min(y3, y4)),
      math.max(math.max(x1, x2), math.max(x3, x4)),
      math.max(math.max(y1, y2), math.max(y3, y4)),
    );
  }

  /// The signed area scale factor. Zero means the plane collapses onto a line
  /// or a point, which is exactly when [invert] cannot answer.
  double get determinant => a * d - b * c;

  /// The inverse, or `null` when this transform is singular.
  ///
  /// Null rather than an exception because a collapsed transform is a normal
  /// runtime state, not a programming error: a node scaled to zero mid
  /// animation, or a widget hidden by `scaleX: 0`, is still hit-tested and
  /// still asked to convert coordinates. Throwing would wrap every one of
  /// those call sites in a try/catch to express "the point cannot be inside
  /// something with no area", which `null` already says.
  ///
  /// The test is exact rather than epsilon-based. A meaningful epsilon
  /// depends on the coordinate magnitudes the caller works in, which this
  /// type cannot know; a near-singular transform therefore inverts to very
  /// large - but finite and correct - coefficients. Non-finite determinants
  /// are rejected too, since an infinite or NaN coefficient anywhere makes
  /// every output NaN.
  Transform2D? invert() {
    final det = determinant;
    if (det == 0 || !det.isFinite) return null;
    return Transform2D(
      d / det,
      -b / det,
      -c / det,
      a / det,
      (c * ty - d * tx) / det,
      (b * tx - a * ty) / det,
    );
  }

  bool get isIdentity =>
      a == 1 && b == 0 && c == 0 && d == 1 && tx == 0 && ty == 0;

  /// Whether the linear part is the identity, so that transforming a point is
  /// two additions and transforming a rectangle needs no bounding box.
  bool get isTranslationOnly => a == 1 && b == 0 && c == 0 && d == 1;

  @override
  bool operator ==(Object other) =>
      other is Transform2D &&
      other.a == a &&
      other.b == b &&
      other.c == c &&
      other.d == d &&
      other.tx == tx &&
      other.ty == ty;

  @override
  int get hashCode => Object.hash(a, b, c, d, tx, ty);

  @override
  String toString() => 'Transform2D($a, $b, $c, $d, $tx, $ty)';
}
