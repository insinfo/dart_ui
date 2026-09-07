/// Turning a parsed [LottieAnimation] into display-list commands at a point in
/// time.
///
/// The split from `lottie_model.dart` is what makes a player cheap: the model
/// is parsed once and asked for values, and this file walks it once per frame
/// emitting geometry. Nothing here reads JSON and nothing here keeps state
/// between frames except the path cache, which is a pure optimisation and can
/// be turned off without changing a pixel.
///
/// ## The transform order, which is the thing to get right
///
/// After Effects composes a transform as: translate to the position, rotate,
/// skew, scale, and *then* translate by minus the anchor point. Applying the
/// anchor first — which reads more naturally, and is what a first attempt
/// does — rotates every layer about the composition origin instead of about
/// its own anchor. The result looks like a coordinate-system bug anywhere else
/// in the pipeline, which is why it is spelled out in [transformMatrix] rather
/// than left to be inferred from the multiplication order.
///
/// ## Why fills and strokes are collected before anything is drawn
///
/// A Lottie group is not a paint-as-you-go list. Its paint operations apply to
/// **every path in the group**, wherever they appear in it, and a group may
/// hold several paths and several fills. So a group is walked twice: once to
/// collect its geometry and its paint, then once to emit. Drawing each path as
/// it is met — the obvious single pass — paints only the shapes that happened
/// to be listed after their fill.
library;

import 'dart:math' as math;

import '../../geometry/offset.dart';
import '../../geometry/path.dart';
import '../../geometry/rect.dart';
import '../../geometry/transform2d.dart';
import '../display_list.dart';
import '../display_list_geometry.dart';
import '../display_list_opcodes.dart';
import 'lottie_model.dart';

/// The matrix for [transform] at [frame].
///
/// See the note at the top of this file: the anchor translation is applied
/// last, which in `multiply` order means it is the right-most factor.
Transform2D transformMatrix(LottieTransform transform, double frame) {
  final Offset position = transform.position.valueAt(frame);
  final Offset anchor = transform.anchor.valueAt(frame);
  final Offset scale = transform.scale.valueAt(frame);
  final double rotation = degreesToRadians(transform.rotation.valueAt(frame));

  Transform2D matrix = Transform2D.translation(position.dx, position.dy);
  if (rotation != 0) {
    matrix = matrix.multiply(Transform2D.rotation(rotation));
  }
  final LottieProperty<double>? skew = transform.skew;
  if (skew != null) {
    final double amount = skew.valueAt(frame);
    if (amount != 0) {
      final double axis =
          degreesToRadians(transform.skewAxis?.valueAt(frame) ?? 0);
      matrix = matrix.multiply(_skewMatrix(amount, axis));
    }
  }
  if (scale.dx != 100 || scale.dy != 100) {
    matrix =
        matrix.multiply(Transform2D.scaling(scale.dx / 100, scale.dy / 100));
  }
  if (anchor != Offset.zero) {
    matrix = matrix.multiply(Transform2D.translation(-anchor.dx, -anchor.dy));
  }
  return matrix;
}

/// A shear of [degrees] along an axis rotated by [axisRadians].
///
/// Built as rotate, shear, rotate back rather than as a single closed form,
/// because the closed form is four products that are easy to transpose and
/// impossible to read; skew is rare enough in exported files that the extra
/// two multiplications cost nothing measurable.
Transform2D _skewMatrix(double degrees, double axisRadians) {
  final double shear = math.tan(degreesToRadians(-degrees));
  final Transform2D toAxis = Transform2D.rotation(-axisRadians);
  final Transform2D back = Transform2D.rotation(axisRadians);
  return back
      .multiply(const Transform2D(1, 0, 0, 1, 0, 0).withShear(shear))
      .multiply(toAxis);
}

extension on Transform2D {
  /// This matrix with a horizontal shear applied.
  Transform2D withShear(double shear) =>
      Transform2D(a, b, c + a * shear, d + b * shear, tx, ty);
}

/// Builds the [Path] for one Lottie contour at [frame].
///
/// The tangents in [LottieShapeData] are **relative to their own vertex**, and
/// this is the single place that conversion happens. Doing it here rather than
/// at parse time keeps interpolation between two shape keyframes in the space
/// the exporter wrote them in, which is what makes a morph look like the one
/// the animator drew.
Path buildShapePath(LottieShapeData data) {
  final int count = data.vertices.length;
  if (count == 0) return Path.empty;
  final PathBuilder builder = PathBuilder();
  final Offset first = data.vertices[0];
  builder.moveTo(first.dx, first.dy);

  for (var i = 1; i < count; i++) {
    final Offset from = data.vertices[i - 1];
    final Offset to = data.vertices[i];
    final Offset out = data.outTangents[i - 1];
    final Offset into = data.inTangents[i];
    builder.cubicTo(
      from.dx + out.dx,
      from.dy + out.dy,
      to.dx + into.dx,
      to.dy + into.dy,
      to.dx,
      to.dy,
    );
  }

  if (data.closed && count > 1) {
    final Offset from = data.vertices[count - 1];
    final Offset out = data.outTangents[count - 1];
    final Offset into = data.inTangents[0];
    builder.cubicTo(
      from.dx + out.dx,
      from.dy + out.dy,
      first.dx + into.dx,
      first.dy + into.dy,
      first.dx,
      first.dy,
    );
    builder.close();
  }
  return builder.build();
}

/// An ellipse as four cubic segments.
///
/// The magic constant is `4/3 * (sqrt(2) - 1)`, the control-point distance that
/// makes a cubic match a quarter circle to within about one part in a thousand.
/// It is written out rather than taken from a helper because the exact value is
/// what makes a Lottie circle land on the same pixels as the reference player's.
Path buildEllipsePath(Offset center, Offset size) {
  const double kappa = 0.5522847498307933;
  final double rx = size.dx / 2;
  final double ry = size.dy / 2;
  final double ox = rx * kappa;
  final double oy = ry * kappa;
  final double cx = center.dx;
  final double cy = center.dy;

  return (PathBuilder()
        // Starting at the top and going clockwise, which is the direction
        // Lottie's own `el` uses; starting elsewhere draws the same ellipse
        // but reverses the winding, and the non-zero fill rule can see that.
        ..moveTo(cx, cy - ry)
        ..cubicTo(cx + ox, cy - ry, cx + rx, cy - oy, cx + rx, cy)
        ..cubicTo(cx + rx, cy + oy, cx + ox, cy + ry, cx, cy + ry)
        ..cubicTo(cx - ox, cy + ry, cx - rx, cy + oy, cx - rx, cy)
        ..cubicTo(cx - rx, cy - oy, cx - ox, cy - ry, cx, cy - ry)
        ..close())
      .build();
}

/// A rectangle, with [radius] rounded corners.
Path buildRectPath(Offset center, Offset size, double radius) {
  final Rect rect = Rect.fromLTWH(
    center.dx - size.dx / 2,
    center.dy - size.dy / 2,
    size.dx,
    size.dy,
  );
  if (radius <= 0) return Path.rect(rect);

  const double kappa = 0.5522847498307933;
  final double limit = math.min(size.dx, size.dy) / 2;
  final double r = radius > limit ? limit : radius;
  final double o = r * kappa;
  return (PathBuilder()
        ..moveTo(rect.right, rect.top + r)
        ..cubicTo(rect.right, rect.top + r - o, rect.right - r + o, rect.top,
            rect.right - r, rect.top)
        ..lineTo(rect.left + r, rect.top)
        ..cubicTo(rect.left + r - o, rect.top, rect.left, rect.top + r - o,
            rect.left, rect.top + r)
        ..lineTo(rect.left, rect.bottom - r)
        ..cubicTo(rect.left, rect.bottom - r + o, rect.left + r - o,
            rect.bottom, rect.left + r, rect.bottom)
        ..lineTo(rect.right - r, rect.bottom)
        ..cubicTo(rect.right - r + o, rect.bottom, rect.right,
            rect.bottom - r + o, rect.right, rect.bottom - r)
        ..close())
      .build();
}

/// What one frame cost to build, for a player that wants to show it.
final class LottiePaintStats {
  const LottiePaintStats({
    required this.layersDrawn,
    required this.pathsDrawn,
    required this.fills,
    required this.strokes,
  });

  static const LottiePaintStats zero =
      LottiePaintStats(layersDrawn: 0, pathsDrawn: 0, fills: 0, strokes: 0);

  /// Layers visible at this frame. Layers outside their in/out points cost a
  /// comparison and nothing else.
  final int layersDrawn;

  /// Distinct [Path] objects submitted. A path drawn with both a fill and a
  /// stroke counts once here and once in each of the two below, which is what
  /// makes the three numbers add up the way a reader expects.
  final int pathsDrawn;

  final int fills;
  final int strokes;

  @override
  String toString() => 'LottiePaintStats($layersDrawn layers, $pathsDrawn '
      'paths, $fills fills, $strokes strokes)';
}

/// Draws a [LottieAnimation] into a [DisplayList].
///
/// One painter per animation, reused across frames. It holds no per-frame state
/// beyond [stats]; what it does hold is a cache of the paths built for shapes
/// that never change, which is the difference between rebuilding every bezier
/// sixty times a second and rebuilding only the ones that actually move.
final class LottiePainter {
  LottiePainter(this.animation, {this.cacheStaticPaths = true});

  final LottieAnimation animation;

  /// Whether to remember the [Path] of a shape whose data is constant.
  ///
  /// On by default and switchable so a benchmark can measure what it is worth
  /// rather than assert it. Turning it off must not change a single pixel; a
  /// test asserts exactly that, because a cache that changes the output is a
  /// correctness bug wearing a performance costume.
  final bool cacheStaticPaths;

  final Map<LottieShapePath, Path> _staticPaths = <LottieShapePath, Path>{};

  LottiePaintStats _stats = LottiePaintStats.zero;

  /// What the last [paint] cost.
  LottiePaintStats get stats => _stats;

  /// Draws the animation at [frame] into [list], fitted into [bounds].
  ///
  /// The animation is scaled uniformly and centred, the way every Lottie player
  /// does it: a composition authored square and shown in a wide box should not
  /// stretch. [fit] of 1 fills the box on its tighter axis.
  void paint(
    DisplayList list,
    Rect bounds,
    double frame, {
    double fit = 1,
  }) {
    var layers = 0;
    var paths = 0;
    var fills = 0;
    var strokes = 0;

    final double scale = animation.width <= 0 || animation.height <= 0
        ? 1
        : math.min(bounds.width / animation.width,
                bounds.height / animation.height) *
            fit;
    final double dx =
        bounds.left + (bounds.width - animation.width * scale) / 2;
    final double dy =
        bounds.top + (bounds.height - animation.height * scale) / 2;

    list
      ..save()
      ..clipRect(bounds.left, bounds.top, bounds.right, bounds.bottom)
      ..transform2D(Transform2D.translation(dx, dy))
      ..transform2D(Transform2D.scaling(scale, scale));

    final _Counters counters = _Counters();
    _paintLayers(list, animation.layers, frame, 1, counters, <String>{});
    list.restore();

    layers = counters.layers;
    paths = counters.paths;
    fills = counters.fills;
    strokes = counters.strokes;
    _stats = LottiePaintStats(
      layersDrawn: layers,
      pathsDrawn: paths,
      fills: fills,
      strokes: strokes,
    );
  }

  void _paintLayers(
    DisplayList list,
    List<LottieLayer> layers,
    double frame,
    double inheritedOpacity,
    _Counters counters,
    Set<String> precompStack,
  ) {
    for (final LottieLayer layer in layers) {
      if (!layer.isVisibleAt(frame)) continue;
      final double opacity =
          inheritedOpacity * layer.transform.opacityAt(frame);
      // Fully transparent is not the same as invisible-and-free: the subtree
      // still has to be skipped rather than drawn with an alpha of zero, or a
      // faded-out precomp costs as much as a visible one.
      if (opacity <= 0.001) continue;

      counters.layers++;
      list.save();
      _applyParentChain(list, layers, layer, frame);
      list.transform2D(transformMatrix(layer.transform, frame));

      switch (layer.type) {
        case LottieLayerType.shape:
          _paintShapes(
              list, layer.shapes, layer.layerFrame(frame), opacity, counters);
        case LottieLayerType.precomp:
          _paintPrecomp(list, layer, frame, opacity, counters, precompStack);
        case LottieLayerType.solid:
          _paintSolid(list, layer, opacity, counters);
        case LottieLayerType.nullLayer:
          // A null layer draws nothing and exists to be a parent. Its
          // transform has already been applied above, which is the whole
          // reason it is walked at all.
          break;
        case LottieLayerType.image:
        case LottieLayerType.text:
          // The parser drops these, so reaching here means the model was built
          // by something else. Nothing to draw and nothing to say.
          break;
      }
      list.restore();
    }
  }

  /// Applies the transforms of [layer]'s parent chain, outermost first.
  ///
  /// Walked from the layer up and then applied in reverse, because a parent's
  /// transform has to be concatenated *before* the child's and the chain is
  /// only navigable in the other direction. The visited set is not paranoia: a
  /// file with a parent cycle is malformed but is a file somebody can hand to a
  /// player, and without the guard it recurses until the stack goes.
  void _applyParentChain(
    DisplayList list,
    List<LottieLayer> siblings,
    LottieLayer layer,
    double frame,
  ) {
    int? parentIndex = layer.parent;
    if (parentIndex == null) return;
    final List<LottieTransform> chain = <LottieTransform>[];
    final Set<int> seen = <int>{layer.index};
    while (parentIndex != null && seen.add(parentIndex)) {
      LottieLayer? parent;
      for (final LottieLayer candidate in siblings) {
        if (candidate.index == parentIndex) {
          parent = candidate;
          break;
        }
      }
      if (parent == null) break;
      chain.add(parent.transform);
      parentIndex = parent.parent;
    }
    for (var i = chain.length - 1; i >= 0; i--) {
      list.transform2D(transformMatrix(chain[i], frame));
    }
  }

  void _paintPrecomp(
    DisplayList list,
    LottieLayer layer,
    double frame,
    double opacity,
    _Counters counters,
    Set<String> stack,
  ) {
    final String? id = layer.refId;
    if (id == null) return;
    final LottiePrecomp? precomp = animation.precomps[id];
    if (precomp == null) return;
    // A precomp that contains itself is malformed and is a file a player can
    // be handed. Refusing the second entry draws the first level and stops,
    // which is visibly wrong and does not take the process with it.
    if (!stack.add(id)) return;
    _paintLayers(
      list,
      precomp.layers,
      layer.layerFrame(frame),
      opacity,
      counters,
      stack,
    );
    stack.remove(id);
  }

  void _paintSolid(
    DisplayList list,
    LottieLayer layer,
    double opacity,
    _Counters counters,
  ) {
    final LottieColor? color = layer.solidColor;
    if (color == null || layer.solidWidth <= 0 || layer.solidHeight <= 0) {
      return;
    }
    counters.paths++;
    counters.fills++;
    list.drawRect(
      0,
      0,
      layer.solidWidth,
      layer.solidHeight,
      list.addPaint(colorArgb: color.toArgb(opacity)),
    );
  }

  /// Draws one list of shape elements.
  ///
  /// Two passes over the same list, which is the shape of the format rather
  /// than an inefficiency: paint applies to every path in the group regardless
  /// of order, so the fills and strokes have to be known before the first path
  /// is emitted. See the note at the top of this file.
  void _paintShapes(
    DisplayList list,
    List<LottieShapeElement> shapes,
    double frame,
    double opacity,
    _Counters counters,
  ) {
    final List<Path> geometry = <Path>[];
    final List<LottieShapeFill> fills = <LottieShapeFill>[];
    final List<LottieShapeStroke> strokes = <LottieShapeStroke>[];
    final List<LottieShapeGroup> groups = <LottieShapeGroup>[];
    LottieShapeTransform? transform;

    for (final LottieShapeElement shape in shapes) {
      switch (shape) {
        case LottieShapePath():
          final Path path = _pathFor(shape, frame);
          if (path.verbCount > 0) geometry.add(path);
        case LottieShapeEllipse():
          geometry.add(
            buildEllipsePath(
              shape.center.valueAt(frame),
              shape.size.valueAt(frame),
            ),
          );
        case LottieShapeRect():
          geometry.add(
            buildRectPath(
              shape.center.valueAt(frame),
              shape.size.valueAt(frame),
              shape.radius.valueAt(frame),
            ),
          );
        case LottieShapeFill():
          fills.add(shape);
        case LottieShapeStroke():
          strokes.add(shape);
        case LottieShapeGroup():
          groups.add(shape);
        case LottieShapeTransform():
          transform = shape;
      }
    }

    final double groupOpacity = transform == null
        ? opacity
        : opacity * transform.transform.opacityAt(frame);
    if (groupOpacity <= 0.001) return;

    list.save();
    if (transform != null) {
      list.transform2D(transformMatrix(transform.transform, frame));
    }

    // Nested groups first: in Lottie a group's own paint does not reach into a
    // child group, which has its own, and drawing children after this group's
    // paint would put them on top of it. The file's order is preserved by
    // drawing them before this level's geometry only when this level has none,
    // and after when it does - which is what the reference player does and
    // what makes a group used purely as a container behave like one.
    if (geometry.isEmpty) {
      for (final LottieShapeGroup group in groups) {
        _paintShapes(list, group.children, frame, groupOpacity, counters);
      }
    }

    for (final Path path in geometry) {
      final int pathId = list.addPath(path);
      counters.paths++;
      for (final LottieShapeFill fill in fills) {
        counters.fills++;
        list.drawPath(
          pathId,
          list.addPaint(
            colorArgb: fill.color.valueAt(frame).toArgb(
                  groupOpacity * (fill.opacity.valueAt(frame) / 100),
                ),
            fillRule: fill.evenOdd ? pathFillRuleEvenOdd : pathFillRuleNonZero,
          ),
        );
      }
      for (final LottieShapeStroke stroke in strokes) {
        final double width = stroke.width.valueAt(frame);
        if (width <= 0) continue;
        counters.strokes++;
        list.drawPath(
          pathId,
          list.addPaint(
            colorArgb: stroke.color.valueAt(frame).toArgb(
                  groupOpacity * (stroke.opacity.valueAt(frame) / 100),
                ),
            style: paintStyleStroke,
            strokeWidth: width,
          ),
        );
      }
    }

    if (geometry.isNotEmpty) {
      for (final LottieShapeGroup group in groups) {
        _paintShapes(list, group.children, frame, groupOpacity, counters);
      }
    }
    list.restore();
  }

  Path _pathFor(LottieShapePath shape, double frame) {
    if (!cacheStaticPaths || shape.data.isAnimated) {
      return buildShapePath(shape.data.valueAt(frame));
    }
    return _staticPaths.putIfAbsent(
      shape,
      () => buildShapePath(shape.data.valueAt(frame)),
    );
  }

  /// Forgets the cached paths. For a player that swapped animations.
  void clearCache() => _staticPaths.clear();
}

/// Mutable tallies for one [LottiePainter.paint].
///
/// A small object rather than four `int` parameters threaded through six
/// recursive calls, which is how the counts silently stop being counted.
final class _Counters {
  int layers = 0;
  int paths = 0;
  int fills = 0;
  int strokes = 0;
}
