/// Nodes that wrap one child and change something about it without changing
/// its geometry.
///
/// The display list has carried `save`, `saveLayer`, `restore`, `transform`,
/// `clipRect` and `drawRRect` since section 9.6, and until this file existed
/// nothing in the render tree emitted any of them. A panel could not fade, an
/// expander chevron could not turn, a card could not have a rounded edge, and a
/// subtree could not be hidden or made inert. The opcodes were reachable only
/// by hand-writing a display list, which is to say: not from a widget.
///
/// ## Why one base class
///
/// Every node here answers the same three questions the same way - it is
/// exactly as big as its child, it puts that child at its own origin, and it
/// forwards a hit to it - and differs only in what it emits around
/// [RenderBox.paint] or whether it forwards the hit at all. There are about
/// twenty-five such effects in a finished toolkit. Written separately they are
/// twenty-five copies of the same six-line `performLayout`, and the day the
/// layout protocol grows a rule is the day twenty-five files have to agree
/// about it again. [RenderProxyBox] holds that shared answer once; a subclass
/// below is usually a `paint` override and nothing else.
///
/// The design is Flutter's `RenderProxyBox` and the class it names; the code is
/// not, and could not be - the geometry here is [Transform2D] rather than a 4x4
/// matrix, there is no layer tree to attach to, and the licence differs.
///
/// ## What is deliberately not here
///
/// * **A layer tree.** [RenderRepaintBoundary] is a marker with no cache behind
///   it; see its own comment, which says so at length rather than implying a
///   saving that does not exist.
/// * **Rounded *clipping*.** [RenderClipRRect] cannot round the corners it
///   paints, because no rasterizer in this repository implements `opClipPath`
///   and the three available blend modes cannot express a mask. Its comment
///   names the missing stage; its hit test is exactly rounded regardless.
/// * **Shadows.** [BoxDecoration] carries a colour, a border and a corner
///   radius, and no shadow. A shadow is a blur, and there is no blur: it is a
///   separable convolution over a mask, which is the same missing mask stage
///   `opClipPath` needs.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../geometry/transform2d.dart';
import '../graphics/color.dart';
import '../graphics/content_hint.dart';
import '../graphics/display_list.dart';
import '../graphics/display_list_geometry.dart';
import '../graphics/display_list_opcodes.dart';
import 'alignment.dart';
import 'render_box.dart';

/// A node that is exactly its child, plus one effect.
///
/// [performLayout] is the whole of the shared contract: the child is laid out
/// under this node's own constraints and this node reports the size that came
/// back. Nothing is loosened, nothing is added, the child is left at the origin
/// - so a proxy is invisible to layout, and inserting one never moves anything.
///
/// The rest is inherited from [RenderSingleChildBox] and is already right:
/// intrinsics delegate, the baseline delegates and is shifted by the child's
/// offset (zero here), [RenderBox.paint] paints the child, and
/// [RenderBox.hitTestChildren] forwards the hit. A subclass that only draws
/// around its child therefore overrides `paint` and nothing else.
///
/// Childless is a real state, not an error: a `ClipRect()` with nothing in it
/// is a legal (if pointless) tree, and it collapses to [BoxConstraints.smallest]
/// rather than filling space it has no content for. That is the opposite of
/// [RenderColoredBox]'s rule, and for a reason - a colour with no child is
/// still something to look at, a clip with no child is not.
abstract class RenderProxyBox extends RenderSingleChildBox {
  RenderProxyBox({super.child});

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    // The child's size already satisfies these constraints, so no constrain()
    // call is needed and adding one would only hide a child that ignored them.
    size = child.size;
  }
}

// ---------------------------------------------------------------------------
// Opacity
// ---------------------------------------------------------------------------

/// Draws its child into an offscreen layer and composites it at [opacity].
///
/// ## The two ends of the range are not "just" fast paths
///
/// At `1.0` no layer is pushed at all. That is not an optimisation to be
/// measured and possibly reverted: a layer is an offscreen buffer the size of
/// this box, allocated, drawn into, and blended back. Paying for one to
/// multiply every channel by 1 is a cost with no output, and an `Opacity`
/// wrapped permanently around a panel - which is what a fade animation leaves
/// behind when it finishes - would keep paying it for the life of the window.
/// The identity is also exact rather than approximate, and
/// `test/rendering/cpu_layers_test.dart` already holds the rasterizer to it, so
/// skipping the layer here cannot change a single pixel.
///
/// At `0.0` nothing is emitted, because there is nothing to see. The child is
/// still laid out and still occupies its space, which is what separates this
/// from [RenderVisibility].
///
/// ## A fully transparent child still takes the pointer
///
/// This is the surprising one, and it is deliberate. Opacity is a *paint*
/// property; whether something is interactive is a separate decision, made by
/// [RenderIgnorePointer] and [RenderAbsorbPointer]. If a hit stopped at alpha 0
/// then a fade-out would change behaviour partway through - a button would go
/// dead at some unspecified frame near the end of its animation, and a fade-in
/// would come alive before the user could see what they were about to press.
/// Worse, the frame it happens on depends on rounding: `opacity` is quantised
/// to an 8-bit alpha here, so `0.001` and `0.0` are the same byte and would be
/// different behaviours.
///
/// [RenderColoredBox] already made exactly this call for exactly this reason,
/// and two nodes in one tree disagreeing about what alpha means to a pointer
/// would be worse than either answer. A caller who wants the other behaviour
/// spells it out: `IgnorePointer(ignoring: opacity == 0, child: Opacity(...))`.
///
/// ## Declared limit: the layer is bounded by this box
///
/// The layer's bounds are this node's own box. A child that paints outside the
/// box it was given - a shadow, a badge hanging off a corner - is clipped by
/// the fade even though it is not clipped without one. Fixing that needs a
/// paint-bounds union over the subtree, which no node in this tree computes
/// yet; when one does, this is the single line that changes.
final class RenderOpacity extends RenderProxyBox {
  RenderOpacity({double opacity = 1.0, super.child})
      : _opacity = _checked(opacity),
        _alpha = _alphaFor(opacity);

  double _opacity;
  int _alpha;

  /// 0 is invisible, 1 is untouched. Values outside that range are rejected
  /// rather than clamped: `1.5` is a caller who thinks opacity brightens, and
  /// clamping would hide the misunderstanding behind a picture that happens to
  /// look right.
  double get opacity => _opacity;

  set opacity(double value) {
    if (value == _opacity) return;
    _opacity = _checked(value);
    _alpha = _alphaFor(value);
    markNeedsPaint();
  }

  /// The 8-bit alpha this opacity quantises to, which is what actually reaches
  /// the paint table. Exposed because "did this emit a layer" is a question
  /// about this number and not about the double.
  int get alpha => _alpha;

  static double _checked(double value) {
    if (!(value >= 0.0 && value <= 1.0)) {
      throw ArgumentError.value(
        value,
        'opacity',
        'must be in 0..1; a NaN or out-of-range opacity quantises to a '
            'meaningless alpha and the picture would be wrong somewhere else',
      );
    }
    return value;
  }

  static int _alphaFor(double value) => (value * 255).round().clamp(0, 255);

  @override
  void paint(DisplayList list, Offset offset) {
    final RenderBox? child = this.child;
    if (child == null || _alpha == 0) return;
    if (_alpha == 255) {
      paintChild(list, child, offset);
      return;
    }
    // White with the layer's alpha: the paint's colour is not drawn, only its
    // alpha and blend mode are read when the layer is composited back.
    final int paintId = list.addPaint(colorArgb: (_alpha << 24) | 0x00FFFFFF);
    list.saveLayer(
      offset.dx,
      offset.dy,
      offset.dx + size.width,
      offset.dy + size.height,
      paintId,
    );
    paintChild(list, child, offset);
    list.restore();
  }
}

// ---------------------------------------------------------------------------
// Transform
// ---------------------------------------------------------------------------

/// Applies an affine transform to its child at paint time.
///
/// Layout is untouched: this node is the size its child asked for, in the
/// unrotated space, and a rotated child therefore does not push its siblings
/// around. That is the point - a chevron that turns 90 degrees when a panel
/// expands must not relayout the row it sits in.
///
/// ## Where the transform is applied from
///
/// [transform] is expressed about this box's own origin. [origin] moves that
/// point by a fixed displacement and [alignment] moves it to a fraction of the
/// box, so `alignment: Alignment.center` is how "turn about your own middle" is
/// spelled without knowing the size. Both compose the same way a conjugation
/// does - translate to the pivot, transform, translate back - and
/// [effectiveTransform] is that product.
///
/// ## Hit testing goes through the inverse, and a singular matrix refuses
///
/// A pointer arrives in this node's space and the child lives in the
/// pre-transform space, so the point is carried backwards by
/// `effectiveTransform.invert()`. [Transform2D.invert] tests `det == 0`
/// exactly, with no epsilon, and returns null rather than throwing - read its
/// comment for why an epsilon cannot be chosen here. Null is not an edge case
/// to paper over: a determinant of zero means the plane has collapsed onto a
/// line, the child occupies no area, and *no* point is inside it. Dividing by
/// that determinant anyway would produce infinities and NaN, and `NaN < width`
/// is false in a way that reads as "just outside" - so the hit would be
/// refused, correctly, by accident, having first poisoned every coordinate on
/// the way. This class refuses it on purpose instead, and paints nothing in the
/// same case.
///
/// ## The bounds check is skipped
///
/// [RenderBox.hitTest] normally rejects a point outside the box before it looks
/// at children. Here it would compare an untransformed box against a
/// transformed child, which is not a comparison of anything: a child rotated
/// 45 degrees sticks out of its own box at the corners and is missing from it
/// at the edges, and the box is the wrong shape either way. So this node tests
/// the child directly, and the child's own bounds - carried back through the
/// inverse - are the only bound that applies. Flutter's `RenderTransform` skips
/// the check for the same reason.
final class RenderTransform extends RenderProxyBox {
  RenderTransform({
    Transform2D transform = Transform2D.identity,
    Offset? origin,
    Alignment? alignment,
    this.transformHitTests = true,
    super.child,
  })  : _transform = transform,
        _origin = origin,
        _alignment = alignment;

  Transform2D _transform;
  Offset? _origin;
  Alignment? _alignment;

  /// Whether a pointer is carried into the child's pre-transform space.
  ///
  /// False leaves hit testing where the child was laid out rather than where it
  /// was drawn, which is what a purely decorative transform wants - a control
  /// that wobbles on press should still be pressable at the place the user
  /// aimed at.
  ///
  /// A plain field: nothing caches it, and hit testing reads it at the moment
  /// an event arrives, so there is no dirty mark for a setter to raise.
  bool transformHitTests;

  Transform2D get transform => _transform;

  set transform(Transform2D value) {
    if (value == _transform) return;
    _transform = value;
    // Geometry is unchanged by construction: this node reports its child's
    // size whatever the matrix says, so a transform change can never move a
    // sibling and never needs layout.
    markNeedsPaint();
  }

  /// A fixed displacement of the pivot from this box's top-left corner.
  Offset? get origin => _origin;

  set origin(Offset? value) {
    if (value == _origin) return;
    _origin = value;
    markNeedsPaint();
  }

  /// The pivot as a fraction of the box, resolved against the current [size].
  Alignment? get alignment => _alignment;

  set alignment(Alignment? value) {
    if (value == _alignment) return;
    _alignment = value;
    markNeedsPaint();
  }

  /// The pivot in this box's own coordinates, or null when there is none.
  Offset? get _pivot {
    final Offset? origin = _origin;
    final Alignment? alignment = _alignment;
    if (alignment == null) return origin;
    final Offset aligned = alignment.withinSize(size);
    return origin == null ? aligned : origin + aligned;
  }

  /// [transform], conjugated by the pivot. Requires a size when [alignment] is
  /// set, so it is only meaningful after layout.
  Transform2D get effectiveTransform {
    final Offset? pivot = _pivot;
    if (pivot == null || (pivot.dx == 0 && pivot.dy == 0)) return _transform;
    return Transform2D.translation(pivot.dx, pivot.dy)
        .multiply(_transform)
        .multiply(Transform2D.translation(-pivot.dx, -pivot.dy));
  }

  @override
  RenderBox? hitTest(Offset position, {HitTestPath? path}) {
    // No bounds check, and no hitTestSelf: this node paints nothing of its own,
    // so there is nothing here to absorb a pointer that missed the child.
    final RenderBox? hit = hitTestChildren(position, path: path);
    if (hit == null) return null;
    path?.add(this);
    return hit;
  }

  @override
  RenderBox? hitTestChildren(Offset position, {HitTestPath? path}) {
    if (!transformHitTests) {
      return super.hitTestChildren(position, path: path);
    }
    final Transform2D? inverse = effectiveTransform.invert();
    if (inverse == null) return null;
    return super.hitTestChildren(
      inverse.transformOffset(position),
      path: path,
    );
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final RenderBox? child = this.child;
    if (child == null) return;
    final Transform2D local = effectiveTransform;
    if (local.isIdentity) {
      paintChild(list, child, offset);
      return;
    }
    if (local.isTranslationOnly) {
      // A translation is expressible as an offset, and an offset costs neither
      // a save/restore pair nor a matrix concatenation in the rasterizer. This
      // is the common case: every slide, nudge and scroll-by transform.
      paintChild(
        list,
        child,
        Offset(offset.dx + local.tx, offset.dy + local.ty),
      );
      return;
    }
    final double determinant = local.determinant;
    if (determinant == 0 || !determinant.isFinite) {
      // Collapsed onto a line or a point. Emitting it would hand the
      // rasterizer a degenerate matrix to divide by; there is nothing to see
      // either way.
      return;
    }
    // The display list's transform is concatenated in device space, but
    // `local` is about this box's origin - and the box is at `offset`. So the
    // matrix that actually goes out is `local` conjugated by that offset, and
    // the child is still painted at `offset` as though nothing had happened.
    list
      ..save()
      ..transform2D(
        Transform2D.translation(offset.dx, offset.dy)
            .multiply(local)
            .multiply(Transform2D.translation(-offset.dx, -offset.dy)),
      );
    paintChild(list, child, offset);
    list.restore();
  }
}

// ---------------------------------------------------------------------------
// Clipping
// ---------------------------------------------------------------------------

/// Clips its child to this node's own box.
///
/// Hit testing needs no override: [RenderBox.hitTest] already rejects a point
/// outside [RenderBox.size] before it reaches the child, and here that
/// rectangle *is* the clip. The two agree by construction rather than by two
/// implementations happening to match, which is the failure this note exists to
/// rule out - a control clipped out of view that still swallows clicks is the
/// classic form of it.
final class RenderClipRect extends RenderProxyBox {
  RenderClipRect({super.child});

  @override
  void paint(DisplayList list, Offset offset) {
    final RenderBox? child = this.child;
    if (child == null) return;
    final Size size = this.size;
    // An empty clip admits nothing. Emitting the pair anyway would be correct
    // and would still cost a save/restore per frame on a collapsed panel.
    if (size.isEmpty) return;
    list
      ..save()
      ..clipRectangle(
        Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height),
      );
    paintChild(list, child, offset);
    list.restore();
  }
}

/// Clips its child to this node's box with rounded corners.
///
/// ## The corners are rounded for a pointer and square for a pixel, today
///
/// This has to be said plainly rather than discovered. The wire format has
/// `opClipPath` and this node could emit a rounded-rectangle path into it - but
/// **no rasterizer in this repository implements that opcode**:
/// `DisplayListPlayer` throws `unsupported` on it, and its message names what
/// is missing, a clip *mask* stage. The three blend modes that do exist
/// (`srcOver`, `src`, `plus`) cannot stand in for one: masking a layer needs a
/// destination-in, and there isn't one.
///
/// So the choice was between emitting an opcode that crashes every backend and
/// emitting the rectangular clip that works. This emits the rectangle. The four
/// corner wedges - the area between the rounded outline and the square box -
/// are **not** clipped in paint, and a child that draws into them will be seen
/// there. The day a mask stage lands, [paint] becomes a `clipPath` call and the
/// characterisation test that pins this down must be deleted.
///
/// Hit testing is exactly rounded regardless, because that costs nothing: the
/// corner test below is arithmetic, not rasterization. The two therefore
/// disagree at four small wedges, which is the honest state of affairs and is
/// better than a hit region that is wrong in the same places as the paint.
///
/// ## Declared absent: elliptical and per-corner radii
///
/// One circular [radius] for all four corners. `PathBuilder` already models the
/// per-corner, two-axis case and `opDrawRRect` already carries eight radii, so
/// widening this is a mechanical change - it is left undone because nothing
/// needs it yet and an unused parameter is a thing to get wrong.
final class RenderClipRRect extends RenderProxyBox {
  RenderClipRRect({double radius = 0.0, super.child})
      : _radius = _checkedRadius(radius);

  double _radius;

  /// The circular corner radius, in this node's own coordinates. Clamped at use
  /// time to half the shorter side, so an over-large radius produces a stadium
  /// rather than a self-crossing outline.
  double get radius => _radius;

  set radius(double value) {
    if (value == _radius) return;
    _radius = _checkedRadius(value);
    markNeedsPaint();
  }

  static double _checkedRadius(double value) {
    if (!(value >= 0.0) || !value.isFinite) {
      throw ArgumentError.value(
        value,
        'radius',
        'must be finite and non-negative',
      );
    }
    return value;
  }

  /// The radius actually used, after clamping to what the box can hold.
  double get effectiveRadius {
    final Size size = this.size;
    final double limit =
        (size.width < size.height ? size.width : size.height) / 2;
    return _radius < limit ? _radius : (limit > 0 ? limit : 0);
  }

  /// Whether [position] is inside the rounded outline.
  ///
  /// Only the corner quadrants can reject: a point in the middle cross of the
  /// box is inside whatever the radius is, so the two range tests below are
  /// both the fast path and the whole of the non-corner case.
  bool _insideRounded(Offset position) {
    final Size size = this.size;
    if (!size.contains(position)) return false;
    final double r = effectiveRadius;
    if (r <= 0) return true;
    final double dx = position.dx < r
        ? r - position.dx
        : (position.dx > size.width - r ? position.dx - (size.width - r) : 0.0);
    if (dx == 0) return true;
    final double dy = position.dy < r
        ? r - position.dy
        : (position.dy > size.height - r
            ? position.dy - (size.height - r)
            : 0.0);
    if (dy == 0) return true;
    return dx * dx + dy * dy <= r * r;
  }

  @override
  RenderBox? hitTest(Offset position, {HitTestPath? path}) {
    if (!_insideRounded(position)) return null;
    return super.hitTest(position, path: path);
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final RenderBox? child = this.child;
    if (child == null) return;
    final Size size = this.size;
    if (size.isEmpty) return;
    // Rectangular. See the class comment: the corner wedges are the declared
    // gap, and they are a missing rasterizer stage rather than a missing
    // decision here.
    list
      ..save()
      ..clipRectangle(
        Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height),
      );
    paintChild(list, child, offset);
    list.restore();
  }
}

// ---------------------------------------------------------------------------
// Decoration
// ---------------------------------------------------------------------------

/// A line drawn around the inside edge of a box.
///
/// Inside, not centred: the stroker in `rendering/path/stroker.dart` centres a
/// stroke on its path, so [RenderDecoratedBox] insets the outline by half the
/// width before emitting it. A border that straddled the edge would grow the
/// visible box by half its width, and two adjacent bordered boxes would overlap
/// by a full one.
final class BoxBorder {
  const BoxBorder({required this.color, required this.width});

  final Color color;

  final double width;

  @override
  bool operator ==(Object other) =>
      other is BoxBorder && other.color == color && other.width == width;

  @override
  int get hashCode => Object.hash(color, width);

  @override
  String toString() => 'BoxBorder(color: $color, width: $width)';
}

/// What [RenderDecoratedBox] paints: a fill, a border, and a corner radius.
///
/// ## Declared absent: shadows and gradients
///
/// Neither is an omission of intent. A drop shadow is an offset, blurred copy
/// of the shape's mask, and there is no blur anywhere in this repository - it
/// needs the same mask stage `opClipPath` is waiting on, plus a separable
/// convolution over it. A gradient needs a paint that is a function of position
/// rather than one 32-bit colour, which is a change to the display list's paint
/// table and therefore to the wire format. Both are named here so that the
/// absence is a decision on the record instead of something a caller discovers
/// by finding no parameter for it.
final class BoxDecoration {
  const BoxDecoration({this.color, this.border, this.radius = 0.0});

  /// The fill, or null for no fill at all. Null and a fully
  /// transparent colour are the same picture and different commands: null emits
  /// nothing, `0x00000000` emits a draw the rasterizer then blends to nothing.
  final Color? color;

  final BoxBorder? border;

  /// Circular corner radius for both the fill and the border. Unlike
  /// [RenderClipRRect]'s, this one is honoured in paint - `opDrawRRect` is
  /// implemented, `opClipPath` is not.
  final double radius;

  /// Whether this decoration would emit anything at all.
  bool get isEmpty => color == null && (border == null || !(border!.width > 0));

  @override
  bool operator ==(Object other) =>
      other is BoxDecoration &&
      other.color == color &&
      other.border == border &&
      other.radius == radius;

  @override
  int get hashCode => Object.hash(color, border, radius);

  @override
  String toString() =>
      'BoxDecoration(color: $color, border: $border, radius: $radius)';
}

/// Paints a [BoxDecoration] behind its child.
///
/// Behind, always: a decoration is a background, and a foreground variant would
/// be a second node rather than a flag, because "which side of the child" is
/// the only thing that would differ and a flag that changes paint order is how
/// a border ends up under the content that is supposed to sit inside it.
final class RenderDecoratedBox extends RenderProxyBox {
  RenderDecoratedBox({
    BoxDecoration decoration = const BoxDecoration(),
    super.child,
  }) : _decoration = decoration;

  BoxDecoration _decoration;

  BoxDecoration get decoration => _decoration;

  set decoration(BoxDecoration value) {
    if (value == _decoration) return;
    _decoration = value;
    // A decoration cannot move anything: the radius and the border width are
    // both drawn inside the box layout already settled on.
    markNeedsPaint();
  }

  /// A painted surface takes the pointer; an empty decoration does not.
  ///
  /// [RenderColoredBox] answers true unconditionally, and says why: a
  /// transparent colour is still a surface, and a node that went inert as its
  /// alpha reached zero would make a fade change behaviour halfway through.
  /// That reasoning is adopted here for every decoration that draws *something*
  /// - including a fully transparent one. It does not extend to a decoration
  /// with no fill and no border, which emits no command at all and is
  /// indistinguishable from a bare proxy; swallowing a pointer on behalf of
  /// nothing would make `DecoratedBox()` a pointer trap.
  @override
  bool hitTestSelf(Offset position) => !_decoration.isEmpty;

  @override
  void paint(DisplayList list, Offset offset) {
    final BoxDecoration decoration = _decoration;
    final Size size = this.size;
    if (!size.isEmpty && !decoration.isEmpty) {
      final Rect bounds =
          Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height);
      final double limit =
          (size.width < size.height ? size.width : size.height) / 2;
      final double radius =
          decoration.radius < limit ? decoration.radius : limit;

      final Color? fill = decoration.color;
      if (fill != null) {
        final int paintId = list.addPaint(colorArgb: fill.value);
        if (radius > 0) {
          list.drawRRectUniform(
            bounds.left,
            bounds.top,
            bounds.right,
            bounds.bottom,
            radius,
            radius,
            paintId,
          );
        } else {
          list.drawRectangle(bounds, paintId);
        }
      }

      final BoxBorder? border = decoration.border;
      if (border != null && border.width > 0) {
        // Half a stroke width inward, so the outline lands entirely inside the
        // box. See BoxBorder for why that is not the rasterizer's default.
        final double inset = border.width / 2;
        final Rect stroked = bounds.deflate(inset);
        if (!stroked.isEmpty) {
          final int paintId = list.addPaint(
            colorArgb: border.color.value,
            style: paintStyleStroke,
            strokeWidth: border.width,
          );
          // The centreline of an inset stroke follows a smaller rounded
          // rectangle, and its corner radius shrinks with it - keeping the
          // outer radius here would draw a border that bulges away from the
          // fill it is supposed to trace.
          final double innerRadius = radius - inset;
          if (innerRadius > 0) {
            list.drawRRectUniform(
              stroked.left,
              stroked.top,
              stroked.right,
              stroked.bottom,
              innerRadius,
              innerRadius,
              paintId,
            );
          } else {
            list.drawRectangle(stroked, paintId);
          }
        }
      }
    }
    super.paint(list, offset);
  }
}

// ---------------------------------------------------------------------------
// Positioning
// ---------------------------------------------------------------------------

/// Fills the space it is given and puts its child in the middle of it.
///
/// This is [RenderAlign] with the alignment fixed at the centre, and it is
/// spelled separately for one reason: it is the single most common wrapper in
/// any tree, and a dedicated node makes `Center` a name in the render tree
/// rather than a configuration to read out of a field. The arithmetic is not
/// duplicated - it goes through [Alignment.center] like every other alignment
/// in this layer, so there is exactly one definition of where a centred box
/// goes. Anything other than the centre, or any size factor, is [RenderAlign]'s
/// job and this class deliberately cannot express it.
///
/// The sizing rule is [RenderAlign]'s, and it is worth restating: a bounded
/// axis is filled, because there is no point centring inside a box that
/// shrink-wraps its child and so has no leftover space; an unbounded axis
/// shrink-wraps, because "as large as possible" is infinite there and infinity
/// is not a size.
final class RenderCenter extends RenderProxyBox {
  RenderCenter({super.child});

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    final bool fillWidth = constraints.hasBoundedWidth;
    final bool fillHeight = constraints.hasBoundedHeight;
    if (child == null) {
      size = constraints.constrain(
        Size(
          fillWidth ? double.infinity : 0.0,
          fillHeight ? double.infinity : 0.0,
        ),
      );
      return;
    }
    child.layout(constraints.loosen(), parentUsesSize: true);
    final Size childSize = child.size;
    size = constraints.constrain(
      Size(
        fillWidth ? double.infinity : childSize.width,
        fillHeight ? double.infinity : childSize.height,
      ),
    );
    child.parentData!.offset = Alignment.center.offsetFor(childSize, size);
  }
}

// ---------------------------------------------------------------------------
// Pointer control
// ---------------------------------------------------------------------------

/// Disappears from hit testing, letting whatever is behind it be hit instead.
///
/// The difference from [RenderAbsorbPointer] is invisible to a test that only
/// checks the child was not hit, and is the whole of what these two nodes are
/// for. This one returns null from [hitTest], so the container walking its
/// children front-to-back carries on to the *next* one and a sibling underneath
/// receives the event. That is what "ignore" means: the subtree is not there as
/// far as the pointer is concerned.
///
/// Painting and layout are untouched - an ignored subtree is still fully
/// visible, which is the case a disabled-looking-but-not-hidden overlay wants.
final class RenderIgnorePointer extends RenderProxyBox {
  RenderIgnorePointer({this.ignoring = true, super.child});

  /// A plain field, deliberately: hit testing reads it at the moment an event
  /// arrives, so there is nothing cached anywhere for a setter to invalidate.
  /// Marking a repaint here would redraw the whole frame for a change that
  /// cannot alter one pixel.
  bool ignoring;

  @override
  RenderBox? hitTest(Offset position, {HitTestPath? path}) =>
      ignoring ? null : super.hitTest(position, path: path);
}

/// Takes the hit itself and gives nothing to its child.
///
/// The mirror of [RenderIgnorePointer]: the event stops *here*. The container
/// walking front-to-back gets a non-null answer and stops looking, so a sibling
/// underneath receives nothing. That is what a modal barrier, a busy overlay or
/// a disabled control needs - not "let it through to the thing behind" but
/// "this region is spoken for".
///
/// It works by answering [RenderBox.hitTestSelf] instead of forwarding to the
/// child, which also means the node itself is what lands in the [HitTestPath];
/// a dispatcher offering the event along that path finds an absorber that
/// handles nothing, and the event is consumed by arriving nowhere.
final class RenderAbsorbPointer extends RenderProxyBox {
  RenderAbsorbPointer({this.absorbing = true, super.child});

  /// A plain field, for the reason [RenderIgnorePointer.ignoring] is one.
  bool absorbing;

  @override
  bool hitTestSelf(Offset position) => absorbing;

  @override
  RenderBox? hitTestChildren(Offset position, {HitTestPath? path}) =>
      absorbing ? null : super.hitTestChildren(position, path: path);
}

// ---------------------------------------------------------------------------
// Boundaries and visibility
// ---------------------------------------------------------------------------

/// Marks a subtree as a place where repainting *could* stop.
///
/// ## There is no cache behind this, and this comment exists to say so
///
/// A repaint boundary in a finished toolkit owns a retained layer: its subtree
/// is rasterised once into a texture, and a later frame that dirtied nothing
/// inside it re-composites that texture instead of re-walking the subtree. None
/// of that machinery exists here. [PipelineOwner.flushPaint] calls `paint` on
/// the root and walks the entire tree into a fresh display list, every frame,
/// and this node does not interrupt it - [paint] below forwards to the child
/// unconditionally.
///
/// So wrapping something in a `RepaintBoundary` today buys **nothing**. It is
/// not a smaller win than the real thing, it is zero, and claiming otherwise
/// would be worse than not having the class: a boundary that is believed to
/// work is a boundary nobody profiles.
///
/// What it is good for is being placed correctly *now*, so that the day a layer
/// tree lands the tree already says where the seams are, and [paintCount] is
/// the number that makes the arrival observable - it counts paints of this
/// subtree and today grows once per frame forever. A caching implementation is
/// exactly the change that makes it stop growing, which is a test that can be
/// written before the feature and will fail until it works.
final class RenderRepaintBoundary extends RenderProxyBox {
  RenderRepaintBoundary({super.child});

  int _paintCount = 0;

  /// How many times this subtree has been walked into a display list.
  ///
  /// Today: once per frame, unconditionally. See the class comment.
  int get paintCount => _paintCount;

  /// True, and consulted by nothing. The marker half of the class.
  bool get isRepaintBoundary => true;

  @override
  void paint(DisplayList list, Offset offset) {
    _paintCount++;
    super.paint(list, offset);
  }
}

/// Declares what its subtree *is*, for the renderer's per-draw selector.
///
/// The counterpart of [RenderRepaintBoundary] in placement and its opposite in
/// substance: that one is a marker with nothing behind it, this one carries a
/// value that reaches the rasteriser. Both are invisible to layout, both wrap
/// exactly one child, and both are about where you put them.
///
/// ## What it emits, and what it deliberately does not
///
/// It pushes a [ContentHint] onto the display list's hint side table around
/// its child's paint and pops it afterwards. It emits **no command**: the op
/// and float streams of a hinted subtree are word-for-word the streams of the
/// same subtree unhinted, which is the mechanical form of the promise that a
/// hint cannot change the picture. See `DisplayList.pushContentHint` for why
/// that is a side table and not an opcode.
///
/// An empty hint short-circuits entirely - no push, no pop, no span - so
/// wrapping a subtree in a `ContentHint()` that declares nothing costs one
/// comparison per paint and leaves no trace in the encoded list.
///
/// ## Nesting
///
/// Per field, through [ContentHint.inheritFrom]. A canvas declared
/// [ContentMotionHint.transforming] containing a widget that declares only
/// [RenderQualityHint.preferSpeed] leaves the inner subtree transforming *and*
/// speed-preferring, rather than silently dropping the motion its parent
/// declared. The nearest enclosing declaration of each field wins.
final class RenderContentHint extends RenderProxyBox {
  RenderContentHint({ContentHint hint = ContentHint.none, super.child})
      : _hint = hint;

  ContentHint _hint;

  /// The advice this subtree declares. [ContentHint.none] declares nothing and
  /// makes this node a plain proxy.
  ContentHint get hint => _hint;

  set hint(ContentHint value) {
    if (_hint == value) return;
    _hint = value;
    // Paint only. A hint changes what the rasteriser is told, never what is
    // measured, so marking layout dirty here would make an animation's
    // start and end reflow the window for nothing.
    markNeedsPaint();
  }

  @override
  void paint(DisplayList list, Offset offset) {
    if (_hint.isEmpty) {
      super.paint(list, offset);
      return;
    }
    list.pushContentHint(_hint);
    super.paint(list, offset);
    list.popContentHint();
  }
}

/// Shows or hides its child, optionally keeping the space it occupied.
///
/// Three states, not two:
///
///   * `visible` - an ordinary proxy;
///   * hidden with [maintainSize] - laid out and measured exactly as if it were
///     visible, painted not at all, and hit by nothing. The space stays, so a
///     row does not reflow when one of its items disappears and the layout does
///     not jump when it comes back;
///   * hidden without [maintainSize] - the child is still laid out, but this
///     node reports [BoxConstraints.smallest] and so occupies nothing.
///
/// ## Why the child is laid out even when it takes no space
///
/// The alternative - skipping [RenderBox.layout] entirely - leaves a child with
/// no size at all, and every later question about it (a baseline, an intrinsic,
/// a debug dump) throws rather than answering. Laying it out under a tight zero
/// constraint instead is worse: a flex or a grid handed a zero box reports an
/// overflow that no user asked for and that nothing on screen corresponds to.
/// So the child is laid out under the real constraints and simply not counted,
/// with `parentUsesSize: false` - which is not a formality, it makes the hidden
/// subtree its own relayout boundary and stops its dirt at the boundary while
/// it is out of view.
///
/// The cost is honest and stated: hiding a subtree does not stop it doing
/// layout work. It stops it painting and it stops it receiving input.
///
/// ## Declared absent: keeping interactivity while hidden
///
/// Flutter's `Visibility` has a `maintainInteractivity` flag. There is no
/// equivalent here, on purpose - a control the user cannot see and can still
/// click is an accessibility defect, not a feature, and the one legitimate use
/// (keeping focus somewhere during a transition) belongs to the focus tree
/// rather than to a paint-time switch.
final class RenderVisibility extends RenderProxyBox {
  RenderVisibility({
    bool visible = true,
    bool maintainSize = true,
    super.child,
  })  : _visible = visible,
        _maintainSize = maintainSize;

  bool _visible;
  bool _maintainSize;

  bool get visible => _visible;

  set visible(bool value) {
    if (value == _visible) return;
    _visible = value;
    // With the size maintained nothing geometric changed and a repaint is
    // enough; without it, this node's own size just changed and every ancestor
    // up to the relayout boundary has to hear about it.
    if (_maintainSize) {
      markNeedsPaint();
    } else {
      markNeedsLayout();
    }
  }

  /// Whether a hidden child still occupies the space it would have taken.
  bool get maintainSize => _maintainSize;

  set maintainSize(bool value) {
    if (value == _maintainSize) return;
    _maintainSize = value;
    // Unconditional, including while visible: the flag decides what the *next*
    // hide does, and a node that changed sizing rules without relaying out
    // would apply the old rule for one more frame.
    markNeedsLayout();
  }

  @override
  void performLayout() {
    if (_visible || _maintainSize) {
      super.performLayout();
      return;
    }
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints, parentUsesSize: false);
    size = constraints.smallest;
  }

  @override
  RenderBox? hitTest(Offset position, {HitTestPath? path}) =>
      _visible ? super.hitTest(position, path: path) : null;

  @override
  void paint(DisplayList list, Offset offset) {
    if (!_visible) return;
    super.paint(list, offset);
  }
}
