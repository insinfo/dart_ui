/// Closed-form shapes whose coverage a fragment shader can evaluate exactly.
///
/// This is strategy 6 of `doc/architecture/ACELERACAO_GPU_VETORIAL.md` -
/// `GpuPathStrategy.analyticPrimitive` - expressed as data that no graphics
/// API appears in. A backend that can execute it reads the six numbers below
/// into a vertex; a backend that cannot ignores the whole file and its draws
/// keep going through the dense coverage atlas.
///
/// ## Why a shape here costs nothing and the same shape as a path costs area
///
/// The dense route answers "how much of this pixel does the shape cover?" by
/// running a scanline filler over the shape's whole bounding box, uploading
/// the result as alpha8 and sampling it back. For a 220x44 button that is
/// 9 680 bytes of CPU rasterisation, 9 680 bytes of upload and one atlas
/// entry, repeated for every distinct size and sub-pixel offset on screen.
///
/// For the four shapes in [AnalyticPrimitiveKind] the same question has a
/// closed-form answer: the signed distance from the pixel centre to the
/// shape's boundary is an arithmetic expression of the shape's parameters, and
/// the coverage of a pixel straddling a straight edge is exactly
/// `0.5 - distance`. So the shape becomes six floats on a vertex, no
/// rasterisation, no upload and no atlas entry - and, because it needs no
/// texture, it merges into the batch the solid rectangles are already in
/// rather than opening a new one.
///
/// ## What this deliberately does not cover
///
/// Every refusal below returns a *named* reason and the draw continues to the
/// dense atlas, which is the parity route. The three that a UI actually meets:
///
///   * **elliptical corner radii** (x radius != y radius on a corner). The
///     four-parameter slot on a vertex holds one radius per corner, and
///     stretching the field to make a corner elliptical would need a second
///     four. Impeller refuses the same case for the same reason and collapses
///     the pair with `min()` before its rrect fast path - see
///     `solid_rrect_blur_contents.cc:158` - which we do not do, because
///     silently drawing a rounder corner than asked for is a wrong picture
///     rather than a slower one.
///   * **a rounded rectangle under rotation.** [AnalyticPrimitiveKind.rounded]
///     is axis aligned in target space. A rotated *sharp* rectangle is
///     covered, as [AnalyticPrimitiveKind.orientedBox], because an oriented
///     box needs an axis and a rounded one would need an axis *and* the four
///     radii, which is two floats more than a vertex has.
///   * **strokes.** A stroked outline arrives here already converted to its
///     fill outline by `PathStroker`, and recovering "this is an annulus"
///     from that polygon is a recogniser of a different size.
library;

import 'dart:math' as math;

import '../../../geometry/path.dart';
import '../../../geometry/rect.dart';
import '../../../geometry/transform2d.dart';

/// The closed forms a fragment shader in this renderer can evaluate.
///
/// The integer values are part of the shader contract: they are written into
/// the vertex and compared in GLSL/HLSL/WGSL, so they may be added to but not
/// renumbered. Zero is reserved for "not an analytic primitive", which is what
/// every vertex the older three pipelines write carries.
enum AnalyticPrimitiveKind {
  /// Axis-aligned rectangle with one circular radius per corner.
  ///
  /// Covers the plain rectangle (all four radii zero), the uniform rounded
  /// rectangle, the per-corner rounded rectangle, the pill (radius equal to
  /// half the short side) and the circle (a square with radius equal to half
  /// its side). That is nearly the whole of a user interface.
  rounded(1),

  /// Axis-aligned ellipse, given as centre and the two radii.
  ///
  /// Separate from [rounded] rather than expressed as a square with elliptical
  /// corners, because the exact field of an ellipse is not the field of a
  /// rounded box and a circle drawn by the wrong one is visibly not a circle.
  ellipse(2),

  /// Rectangle of arbitrary orientation, given as centre, half-axis and half
  /// thickness. Butt ends.
  ///
  /// This is what a rotated rectangle and a butt-capped thick line both are.
  orientedBox(3),

  /// [orientedBox] with semicircular ends: a thick line with round caps.
  capsule(4);

  const AnalyticPrimitiveKind(this.shaderCode);

  /// The value written into the vertex and switched on in the shader.
  final int shaderCode;
}

/// One recognised primitive, in the coordinate space it was recognised in.
///
/// **Mutable and reused.** A [GpuRasterSink] owns exactly one of these and the
/// recogniser fills it in place, because the whole claim of this route is that
/// a rounded rectangle costs nothing but a quad - and an object allocated per
/// rounded rectangle per frame would be the same garbage that
/// `gpu_vertex_buffer.dart` exists to avoid, reintroduced one layer up.
///
/// A caller must read the fields before the next [recognise] call. Nothing
/// retains one.
final class AnalyticPrimitive {
  AnalyticPrimitive();

  /// Null until a recognition has succeeded.
  AnalyticPrimitiveKind? kind;

  /// Why the last recognition failed, or null when it succeeded.
  ///
  /// Always a compile-time constant string. The reason is reported by the sink
  /// and read by tests, and a message built by interpolation would allocate on
  /// exactly the path that must not allocate.
  String? refusal;

  /// The shape's exact rectangle: the box for [AnalyticPrimitiveKind.rounded],
  /// the bounding box for the other three. Never snapped.
  double left = 0;
  double top = 0;
  double right = 0;
  double bottom = 0;

  /// The four shader parameters, whose meaning depends on [kind]:
  ///
  /// | kind | p0 | p1 | p2 | p3 |
  /// |---|---|---|---|---|
  /// | [AnalyticPrimitiveKind.rounded] | radius top-left | top-right | bottom-right | bottom-left |
  /// | [AnalyticPrimitiveKind.ellipse] | centre x | centre y | radius x | radius y |
  /// | [AnalyticPrimitiveKind.orientedBox] | centre x | centre y | half-axis x | half-axis y |
  /// | [AnalyticPrimitiveKind.capsule] | centre x | centre y | half-axis x | half-axis y |
  ///
  /// The radii order is the display list's `opDrawRRect` order, so the values
  /// travel from the opcode to the shader without ever being reordered.
  double p0 = 0;
  double p1 = 0;
  double p2 = 0;
  double p3 = 0;

  /// Half the thickness across the axis, for the two oriented kinds. Unused
  /// and zero for the other two.
  double aux = 0;

  /// How far outside [left]..[bottom] the shape can put non-zero coverage.
  ///
  /// Half a pixel of antialiasing fringe, rounded up to a whole pixel so the
  /// quad snaps to the grid. For the oriented kinds the parameters describe a
  /// shape that may stick out of a bounding box computed before the thickness
  /// was known, so this is where that is paid for instead.
  static const double fringe = 1;

  /// The device-space bounds the shape can write to, including [fringe].
  Rect get paintedBounds => Rect.fromLTRB(
        left - fringe,
        top - fringe,
        right + fringe,
        bottom + fringe,
      );

  void _fail(String reason) {
    kind = null;
    refusal = reason;
  }

  void _succeed(AnalyticPrimitiveKind value) {
    kind = value;
    refusal = null;
  }

  /// The signed distance field the shader evaluates, in shape units.
  ///
  /// The reference implementation of the GLSL in `gl_shaders.dart`, kept here
  /// so a parity test can compare the two without a GPU and so the shader can
  /// be checked against arithmetic that is readable. It is *not* used to draw
  /// anything.
  double fieldAt(double x, double y) {
    switch (kind!) {
      case AnalyticPrimitiveKind.rounded:
        final double cx = (left + right) * 0.5;
        final double cy = (top + bottom) * 0.5;
        final double hx = (right - left) * 0.5;
        final double hy = (bottom - top) * 0.5;
        final double px = x - cx;
        final double py = y - cy;
        final double r = px > 0 ? (py > 0 ? p2 : p1) : (py > 0 ? p3 : p0);
        final double qx = px.abs() - hx + r;
        final double qy = py.abs() - hy + r;
        final double outside = math.sqrt(
          math.max(qx, 0.0) * math.max(qx, 0.0) +
              math.max(qy, 0.0) * math.max(qy, 0.0),
        );
        return math.min(math.max(qx, qy), 0.0) + outside - r;
      case AnalyticPrimitiveKind.ellipse:
        final double ex = (x - p0) / p2;
        final double ey = (y - p1) / p3;
        return math.sqrt(ex * ex + ey * ey) - 1.0;
      case AnalyticPrimitiveKind.orientedBox:
      case AnalyticPrimitiveKind.capsule:
        final double dx = x - p0;
        final double dy = y - p1;
        final double halfLength = math.sqrt(p2 * p2 + p3 * p3);
        if (halfLength == 0) return double.infinity;
        final double ux = p2 / halfLength;
        final double uy = p3 / halfLength;
        final double along = (dx * ux + dy * uy).abs() - halfLength;
        final double across = (dx * uy - dy * ux).abs();
        if (kind == AnalyticPrimitiveKind.capsule) {
          final double outLength = math.max(along, 0.0);
          return math.sqrt(outLength * outLength + across * across) - aux;
        }
        final double acrossOut = across - aux;
        final double outside = math.sqrt(
          math.max(along, 0.0) * math.max(along, 0.0) +
              math.max(acrossOut, 0.0) * math.max(acrossOut, 0.0),
        );
        return math.min(math.max(along, acrossOut), 0.0) + outside;
    }
  }

  /// Coverage of the pixel whose centre is ([x], [y]), the way the shader
  /// computes it once the field has been normalised by its screen gradient.
  ///
  /// Only correct for a shape in device units, which is the only space this
  /// renderer builds one in; a caller in another space has to divide by the
  /// gradient itself, which is what the fragment shader does with `dFdx`.
  double coverageAt(double x, double y) {
    final double d = fieldAt(x, y);
    if (!d.isFinite) return 0;
    final double coverage = 0.5 - d;
    if (coverage <= 0) return 0;
    if (coverage >= 1) return 1;
    return coverage;
  }
}

/// Turns real draw arguments into an [AnalyticPrimitive], or names why not.
///
/// Stateless and const: every result is written into the caller's slot, so two
/// sinks sharing one recogniser cannot interfere.
final class AnalyticPrimitiveRecognizer {
  const AnalyticPrimitiveRecognizer();

  /// Recognises the rounded rectangle `fillDeviceRRect` receives.
  ///
  /// [deviceRadii] is the display list's eight-value `opDrawRRect` block -
  /// x before y, top-left, top-right, bottom-right, bottom-left - already
  /// scaled into device units by the player.
  ///
  /// The overrun rule here has to be **the same one** `PathBuilder`
  /// applies, not merely a similar one: the dense route draws the path the
  /// builder produces, so any disagreement about how a 40px radius on a 50px
  /// edge is clamped is a shape that changes when the selector changes its
  /// mind. See `PathBuilder.addRoundedRectPerCorner` for the rule and the
  /// argument for one global factor.
  bool recogniseRoundedRect(
    AnalyticPrimitive out,
    Rect deviceRect,
    List<double> deviceRadii, [
    int offset = 0,
  ]) {
    final double width = deviceRect.width;
    final double height = deviceRect.height;
    if (!(width > 0) || !(height > 0)) {
      out._fail('an empty or inverted rectangle has nothing to draw');
      return false;
    }
    if (!deviceRect.left.isFinite ||
        !deviceRect.top.isFinite ||
        !deviceRect.right.isFinite ||
        !deviceRect.bottom.isFinite) {
      out._fail('a non-finite rectangle cannot be evaluated in a shader');
      return false;
    }

    final double limit = width > height ? width : height;
    var tlx = _sanitiseRadius(deviceRadii[offset], limit);
    var tly = _sanitiseRadius(deviceRadii[offset + 1], limit);
    var trx = _sanitiseRadius(deviceRadii[offset + 2], limit);
    var try_ = _sanitiseRadius(deviceRadii[offset + 3], limit);
    var brx = _sanitiseRadius(deviceRadii[offset + 4], limit);
    var bry = _sanitiseRadius(deviceRadii[offset + 5], limit);
    var blx = _sanitiseRadius(deviceRadii[offset + 6], limit);
    var bly = _sanitiseRadius(deviceRadii[offset + 7], limit);

    // A corner with a zero on either axis is a right angle, squared before
    // the overrun rule so it does not consume any of the edge it sits on.
    if (tlx == 0 || tly == 0) {
      tlx = 0;
      tly = 0;
    }
    if (trx == 0 || try_ == 0) {
      trx = 0;
      try_ = 0;
    }
    if (brx == 0 || bry == 0) {
      brx = 0;
      bry = 0;
    }
    if (blx == 0 || bly == 0) {
      blx = 0;
      bly = 0;
    }

    var scale = 1.0;
    scale = _edgeScale(scale, width, tlx + trx);
    scale = _edgeScale(scale, width, blx + brx);
    scale = _edgeScale(scale, height, tly + bly);
    scale = _edgeScale(scale, height, try_ + bry);
    if (scale < 1) {
      tlx *= scale;
      tly *= scale;
      trx *= scale;
      try_ *= scale;
      brx *= scale;
      bry *= scale;
      blx *= scale;
      bly *= scale;
    }

    // The one shape the four-parameter slot cannot hold. Refused rather than
    // approximated: see the library comment.
    if (tlx != tly || trx != try_ || brx != bry || blx != bly) {
      out._fail('a corner whose two radii differ is an elliptical corner, and '
          'the vertex carries one radius per corner');
      return false;
    }

    out
      ..left = deviceRect.left
      ..top = deviceRect.top
      ..right = deviceRect.right
      ..bottom = deviceRect.bottom
      ..p0 = tlx
      ..p1 = trx
      ..p2 = brx
      ..p3 = blx
      ..aux = 0
      .._succeed(AnalyticPrimitiveKind.rounded);
    return true;
  }

  /// Recognises the axis-aligned rectangle `fillDeviceRect` receives, as the
  /// zero-radius case of [recogniseRoundedRect].
  bool recogniseRect(AnalyticPrimitive out, Rect deviceRect) {
    if (deviceRect.isEmpty ||
        !deviceRect.left.isFinite ||
        !deviceRect.top.isFinite ||
        !deviceRect.right.isFinite ||
        !deviceRect.bottom.isFinite) {
      out._fail('an empty or non-finite rectangle has nothing to draw');
      return false;
    }
    out
      ..left = deviceRect.left
      ..top = deviceRect.top
      ..right = deviceRect.right
      ..bottom = deviceRect.bottom
      ..p0 = 0
      ..p1 = 0
      ..p2 = 0
      ..p3 = 0
      ..aux = 0
      .._succeed(AnalyticPrimitiveKind.rounded);
    return true;
  }

  /// Recognises a path that is exactly one of the closed forms.
  ///
  /// Only the two shapes `PathBuilder` emits with a fixed verb stream are
  /// tried - `addRect` and `addOval` - because those are the two a caller can
  /// produce without meaning to describe something else, and because the
  /// rounded rectangle already has a direct entry point above that never
  /// builds a path at all.
  ///
  /// [localToTarget] may rotate: a rectangle under a rotation becomes an
  /// [AnalyticPrimitiveKind.orientedBox], which is a shape the field handles
  /// natively. It may not skew a rectangle into a non-rectangle, and it may
  /// not rotate an ellipse, both of which are refused by name.
  bool recognisePath(
    AnalyticPrimitive out,
    Path path,
    Transform2D localToTarget,
  ) {
    if (!_finite(localToTarget)) {
      out._fail('a non-finite transform cannot be evaluated in a shader');
      return false;
    }
    if (_isRectPath(path)) {
      return _rectUnder(out, path, localToTarget);
    }
    if (_isOvalPath(path)) {
      return _ovalUnder(out, path, localToTarget);
    }
    out._fail('the path is not a rectangle or an ellipse');
    return false;
  }

  /// A thick straight line, as its two endpoints and a device thickness.
  ///
  /// Reached from a caller that still has the segment - not from the stroked
  /// outline, which has already lost which of its four edges were the caps.
  bool recogniseSegment(
    AnalyticPrimitive out, {
    required double x0,
    required double y0,
    required double x1,
    required double y1,
    required double thickness,
    bool roundCaps = false,
  }) {
    if (!x0.isFinite ||
        !y0.isFinite ||
        !x1.isFinite ||
        !y1.isFinite ||
        !thickness.isFinite) {
      out._fail('a non-finite segment cannot be evaluated in a shader');
      return false;
    }
    if (!(thickness > 0)) {
      out._fail('a segment with no thickness covers no pixel');
      return false;
    }
    final double halfAxisX = (x1 - x0) * 0.5;
    final double halfAxisY = (y1 - y0) * 0.5;
    if (halfAxisX == 0 && halfAxisY == 0) {
      // Degenerate on purpose rather than by accident: a zero-length round
      // capped segment is a dot, and a zero-length butt capped one is empty.
      if (!roundCaps) {
        out._fail('a zero-length segment with butt caps covers no pixel');
        return false;
      }
    }
    final double half = thickness * 0.5;
    final double centreX = (x0 + x1) * 0.5;
    final double centreY = (y0 + y1) * 0.5;
    // Bounds of the capsule/box, which the endpoints alone do not give: the
    // thickness sticks out sideways, and a round cap sticks out lengthwise.
    final double extentX = halfAxisX.abs() + half;
    final double extentY = halfAxisY.abs() + half;
    out
      ..left = centreX - extentX
      ..top = centreY - extentY
      ..right = centreX + extentX
      ..bottom = centreY + extentY
      ..p0 = centreX
      ..p1 = centreY
      ..p2 = halfAxisX
      ..p3 = halfAxisY
      ..aux = half
      .._succeed(roundCaps
          ? AnalyticPrimitiveKind.capsule
          : AnalyticPrimitiveKind.orientedBox);
    return true;
  }

  bool _rectUnder(AnalyticPrimitive out, Path path, Transform2D t) {
    final Rect local = path.bounds;
    if (local.isEmpty) {
      out._fail('an empty rectangle has nothing to draw');
      return false;
    }
    final bool axisAligned = (t.b == 0 && t.c == 0) || (t.a == 0 && t.d == 0);
    if (axisAligned) {
      final Rect device = t.transformRect(local);
      return recogniseRect(out, device);
    }
    // A rotation, possibly with a uniform or non-uniform scale, is still a
    // rectangle - an oriented one. A skew is not, and the test for it is that
    // the two transformed edge vectors stay perpendicular.
    final double ex = t.a * local.width;
    final double ey = t.b * local.width;
    final double fx = t.c * local.height;
    final double fy = t.d * local.height;
    final double lengthE = math.sqrt(ex * ex + ey * ey);
    final double lengthF = math.sqrt(fx * fx + fy * fy);
    if (lengthE == 0 || lengthF == 0) {
      out._fail('a collapsed rectangle covers no pixel');
      return false;
    }
    final double cosine = (ex * fx + ey * fy) / (lengthE * lengthF);
    if (cosine.abs() > 1e-6) {
      out._fail('a skewed rectangle is a parallelogram, which the oriented '
          'box field does not describe');
      return false;
    }
    // The long axis is the box's axis; the short one is its thickness. Either
    // assignment describes the same shape, so the longer is chosen to keep the
    // half-axis away from zero.
    final double centreX =
        t.a * local.left + t.c * local.top + t.tx + (ex + fx) * 0.5;
    final double centreY =
        t.b * local.left + t.d * local.top + t.ty + (ey + fy) * 0.5;
    final bool eIsLonger = lengthE >= lengthF;
    final double axisX = (eIsLonger ? ex : fx) * 0.5;
    final double axisY = (eIsLonger ? ey : fy) * 0.5;
    final double half = (eIsLonger ? lengthF : lengthE) * 0.5;
    final double extentX = axisX.abs() + half;
    final double extentY = axisY.abs() + half;
    out
      ..left = centreX - extentX
      ..top = centreY - extentY
      ..right = centreX + extentX
      ..bottom = centreY + extentY
      ..p0 = centreX
      ..p1 = centreY
      ..p2 = axisX
      ..p3 = axisY
      ..aux = half
      .._succeed(AnalyticPrimitiveKind.orientedBox);
    return true;
  }

  bool _ovalUnder(AnalyticPrimitive out, Path path, Transform2D t) {
    if (!(t.b == 0 && t.c == 0)) {
      out._fail('an ellipse under rotation or skew needs an axis the vertex '
          'has no room for');
      return false;
    }
    final Rect device = t.transformRect(path.bounds);
    final double rx = device.width * 0.5;
    final double ry = device.height * 0.5;
    if (!(rx > 0) || !(ry > 0)) {
      out._fail('an ellipse with a zero radius covers no pixel');
      return false;
    }
    out
      ..left = device.left
      ..top = device.top
      ..right = device.right
      ..bottom = device.bottom
      ..p0 = device.left + rx
      ..p1 = device.top + ry
      ..p2 = rx
      ..p3 = ry
      ..aux = 0
      .._succeed(AnalyticPrimitiveKind.ellipse);
    return true;
  }
}

bool _finite(Transform2D t) =>
    t.a.isFinite &&
    t.b.isFinite &&
    t.c.isFinite &&
    t.d.isFinite &&
    t.tx.isFinite &&
    t.ty.isFinite;

/// The verb stream `PathBuilder.addRect` emits, and nothing else.
bool _isRectPath(Path path) {
  if (path.verbCount != 5 || path.pointCount != 4) return false;
  if (path.verbAt(0) != verbMoveTo ||
      path.verbAt(1) != verbLineTo ||
      path.verbAt(2) != verbLineTo ||
      path.verbAt(3) != verbLineTo ||
      path.verbAt(4) != verbClose) {
    return false;
  }
  final double x0 = path.pointX(0);
  final double y0 = path.pointY(0);
  final double x1 = path.pointX(1);
  final double y1 = path.pointY(1);
  final double x2 = path.pointX(2);
  final double y2 = path.pointY(2);
  final double x3 = path.pointX(3);
  final double y3 = path.pointY(3);
  // Axis aligned in the path's *own* space, which is what makes the four
  // points a rectangle rather than an arbitrary quadrilateral. Its image under
  // the transform may be rotated; that is the caller's problem, not this one's.
  return y0 == y1 && x1 == x2 && y2 == y3 && x3 == x0;
}

/// The verb stream `PathBuilder.addOval` emits, checked against the ellipse
/// its own bounding box would produce.
///
/// The control points are compared rather than trusted, because four cubics
/// closing back on their start is also what a hand-built blob looks like. The
/// tolerance is relative to the radius: `_kappa` is stored as a `double` and
/// the points went through a `Float32List` on the way into the path, so an
/// exact comparison would refuse every oval the builder ever made.
bool _isOvalPath(Path path) {
  if (path.verbCount != 6 || path.pointCount != 13) return false;
  if (path.verbAt(0) != verbMoveTo ||
      path.verbAt(1) != verbCubicTo ||
      path.verbAt(2) != verbCubicTo ||
      path.verbAt(3) != verbCubicTo ||
      path.verbAt(4) != verbCubicTo ||
      path.verbAt(5) != verbClose) {
    return false;
  }
  final Rect b = path.bounds;
  final double rx = b.width * 0.5;
  final double ry = b.height * 0.5;
  if (!(rx > 0) || !(ry > 0)) return false;
  final double cx = b.left + rx;
  final double cy = b.top + ry;
  final double kx = rx * _kappa;
  final double ky = ry * _kappa;
  final double tolerance = 1e-4 * (rx > ry ? rx : ry) + 1e-4;

  bool at(int index, double x, double y) =>
      (path.pointX(index) - x).abs() <= tolerance &&
      (path.pointY(index) - y).abs() <= tolerance;

  return at(0, cx, b.top) &&
      at(1, cx + kx, b.top) &&
      at(2, b.right, cy - ky) &&
      at(3, b.right, cy) &&
      at(4, b.right, cy + ky) &&
      at(5, cx + kx, b.bottom) &&
      at(6, cx, b.bottom) &&
      at(7, cx - kx, b.bottom) &&
      at(8, b.left, cy + ky) &&
      at(9, b.left, cy) &&
      at(10, b.left, cy - ky) &&
      at(11, cx - kx, b.top) &&
      at(12, cx, b.top);
}

/// The circular-arc cubic constant `PathBuilder` uses. Duplicated rather than
/// exported, because exporting it would make a private construction detail of
/// the builder part of its API for the sake of one comparison.
const double _kappa = 0.5522847498307933;

double _sanitiseRadius(double value, double limit) {
  if (value.isNaN) return 0;
  if (!value.isFinite) return limit;
  return value <= 0 ? 0 : value;
}

double _edgeScale(double scale, double edge, double sum) {
  if (sum <= edge) return scale;
  final double candidate = edge / sum;
  return candidate < scale ? candidate : scale;
}
