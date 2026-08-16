/// The widget face of `layout/render_proxy_box.dart`.
///
/// Each widget here is a thin, immutable description of one render node, and
/// there is deliberately nothing else in the file: the reasoning about what a
/// fade costs, why a singular transform refuses a hit and what a repaint
/// boundary does not yet buy lives with the nodes, once, where a reader looking
/// at behaviour will be.
///
/// What this file adds is reach. `StyleTransitionRunner` has been able to
/// animate an opacity and a transform since section 28.7 and had nowhere to put
/// the result; these are the consumers. An animated double goes into [Opacity],
/// an animated [Transform2D] into [Transform], and neither widget needs to know
/// a transition produced it.
library;

import '../geometry/offset.dart';
import '../geometry/transform2d.dart';
import '../layout/alignment.dart';
import '../layout/render_proxy_box.dart' as layout;
import 'element.dart';
import 'widget.dart';

export '../layout/render_proxy_box.dart' show BoxBorder, BoxDecoration;

/// Fades its child.
///
/// `1.0` costs nothing - no layer is created - and `0.0` draws nothing while
/// still occupying its space and **still receiving pointers**. That last part
/// is the surprising one and the argument for it is on
/// [layout.RenderOpacity]: opacity is a paint property, and a control that went
/// dead partway through its own fade would do so on a frame decided by
/// rounding. Pair it with [IgnorePointer] when the intent is really "gone".
final class Opacity extends SingleChildRenderObjectWidget {
  const Opacity({super.key, required this.opacity, super.child});

  /// 0 is invisible, 1 is untouched. Outside that range is an error, not a
  /// value to clamp.
  final double opacity;

  @override
  layout.RenderOpacity createRenderObject(BuildContext context) =>
      layout.RenderOpacity(opacity: opacity);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant layout.RenderOpacity renderObject,
  ) {
    renderObject.opacity = opacity;
  }
}

/// Applies an affine transform to its child at paint time only.
///
/// Layout is untouched, so a rotated child never pushes its siblings around -
/// which is the whole reason an expander chevron can turn without reflowing the
/// row it sits in.
final class Transform extends SingleChildRenderObjectWidget {
  const Transform({
    super.key,
    required this.transform,
    this.origin,
    this.alignment,
    this.transformHitTests = true,
    super.child,
  });

  /// Turns the child about [alignment], which defaults to its own centre -
  /// almost always what "rotate this" means, and the one case where taking the
  /// top-left corner instead is visibly wrong.
  factory Transform.rotate({
    Key? key,
    required double angle,
    Alignment alignment = Alignment.center,
    bool transformHitTests = true,
    Widget? child,
  }) =>
      Transform(
        key: key,
        transform: Transform2D.rotation(angle),
        alignment: alignment,
        transformHitTests: transformHitTests,
        child: child,
      );

  /// Scales about [alignment]. A scale of zero on either axis is legal: it is
  /// what the start of a pop-in animation looks like, it paints nothing, and it
  /// refuses hits rather than inverting a singular matrix.
  factory Transform.scale({
    Key? key,
    double? scale,
    double? scaleX,
    double? scaleY,
    Alignment alignment = Alignment.center,
    bool transformHitTests = true,
    Widget? child,
  }) {
    if ((scale == null) == (scaleX == null && scaleY == null)) {
      throw ArgumentError(
        'Transform.scale takes either scale, or scaleX and/or scaleY, and not '
        'both: two sources for one axis is a silent winner',
      );
    }
    return Transform(
      key: key,
      transform: Transform2D.scaling(
        scale ?? scaleX ?? 1.0,
        scale ?? scaleY ?? 1.0,
      ),
      alignment: alignment,
      transformHitTests: transformHitTests,
      child: child,
    );
  }

  /// Moves the child. No alignment, because a translation has no pivot to be
  /// about, and no layer either - the render node folds a translation into the
  /// paint offset instead of emitting a matrix.
  factory Transform.translate({
    Key? key,
    required Offset offset,
    bool transformHitTests = true,
    Widget? child,
  }) =>
      Transform(
        key: key,
        transform: Transform2D.translation(offset.dx, offset.dy),
        transformHitTests: transformHitTests,
        child: child,
      );

  final Transform2D transform;

  /// A fixed displacement of the pivot from the child's top-left corner.
  final Offset? origin;

  /// The pivot as a fraction of the box, resolved against its laid-out size.
  final Alignment? alignment;

  /// False keeps hit testing where the child was laid out rather than where it
  /// was drawn.
  final bool transformHitTests;

  @override
  layout.RenderTransform createRenderObject(BuildContext context) =>
      layout.RenderTransform(
        transform: transform,
        origin: origin,
        alignment: alignment,
        transformHitTests: transformHitTests,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant layout.RenderTransform renderObject,
  ) {
    renderObject
      ..transform = transform
      ..origin = origin
      ..alignment = alignment
      ..transformHitTests = transformHitTests;
  }
}

/// Clips its child to its own box.
///
/// The clip and the hit region are the same rectangle by construction, so a
/// control scrolled out of view cannot keep swallowing clicks.
final class ClipRect extends SingleChildRenderObjectWidget {
  const ClipRect({super.key, super.child});

  @override
  layout.RenderClipRect createRenderObject(BuildContext context) =>
      layout.RenderClipRect();
}

/// Clips its child to its own box with rounded corners.
///
/// **Read [layout.RenderClipRRect] before using this.** The corners round for a
/// pointer and not for a pixel: no rasterizer here implements `opClipPath`, so
/// paint falls back to the rectangular clip and the four corner wedges are not
/// cut. For a rounded *card* - the common case - use [DecoratedBox] with a
/// radius, whose rounding is real, and reach for this only when content
/// genuinely has to be cut to the shape.
final class ClipRRect extends SingleChildRenderObjectWidget {
  const ClipRRect({super.key, this.radius = 0.0, super.child});

  /// Circular radius on all four corners, clamped at use to half the shorter
  /// side.
  final double radius;

  @override
  layout.RenderClipRRect createRenderObject(BuildContext context) =>
      layout.RenderClipRRect(radius: radius);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant layout.RenderClipRRect renderObject,
  ) {
    renderObject.radius = radius;
  }
}

/// Paints a fill, a border and a corner radius behind its child.
///
/// This is the rounded card. Unlike [ClipRRect] the radius is honoured in
/// paint, because `opDrawRRect` is implemented and `opClipPath` is not.
/// Shadows and gradients are declared absent by name on [BoxDecoration].
final class DecoratedBox extends SingleChildRenderObjectWidget {
  const DecoratedBox({
    super.key,
    this.decoration = const layout.BoxDecoration(),
    super.child,
  });

  final layout.BoxDecoration decoration;

  @override
  layout.RenderDecoratedBox createRenderObject(BuildContext context) =>
      layout.RenderDecoratedBox(decoration: decoration);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant layout.RenderDecoratedBox renderObject,
  ) {
    renderObject.decoration = decoration;
  }
}

/// Fills the space it is given and centres its child in it.
///
/// [Align] covers every other alignment and both size factors; this exists
/// because centring is the overwhelmingly common case and deserves a name.
final class Center extends SingleChildRenderObjectWidget {
  const Center({super.key, super.child});

  @override
  layout.RenderCenter createRenderObject(BuildContext context) =>
      layout.RenderCenter();
}

/// Removes its child from hit testing, so whatever is behind it is hit instead.
///
/// The pair to [AbsorbPointer], and the difference only shows up when there is
/// something underneath: this one lets the event through to it.
final class IgnorePointer extends SingleChildRenderObjectWidget {
  const IgnorePointer({super.key, this.ignoring = true, super.child});

  final bool ignoring;

  @override
  layout.RenderIgnorePointer createRenderObject(BuildContext context) =>
      layout.RenderIgnorePointer(ignoring: ignoring);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant layout.RenderIgnorePointer renderObject,
  ) {
    renderObject.ignoring = ignoring;
  }
}

/// Takes the hit itself, giving it neither to its child nor to what is behind.
///
/// A modal barrier, a busy overlay, a disabled control: the region is spoken
/// for. The pair to [IgnorePointer].
final class AbsorbPointer extends SingleChildRenderObjectWidget {
  const AbsorbPointer({super.key, this.absorbing = true, super.child});

  final bool absorbing;

  @override
  layout.RenderAbsorbPointer createRenderObject(BuildContext context) =>
      layout.RenderAbsorbPointer(absorbing: absorbing);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant layout.RenderAbsorbPointer renderObject,
  ) {
    renderObject.absorbing = absorbing;
  }
}

/// Marks where repainting could stop one day.
///
/// It buys nothing today - there is no layer cache anywhere in this repository
/// and `PipelineOwner.flushPaint` re-walks the whole tree every frame. The
/// class comment on [layout.RenderRepaintBoundary] says so at length rather
/// than implying a saving that does not exist. Placing them correctly now is
/// still worth doing, because the placement is the part that is hard to add
/// afterwards.
final class RepaintBoundary extends SingleChildRenderObjectWidget {
  const RepaintBoundary({super.key, super.child});

  @override
  layout.RenderRepaintBoundary createRenderObject(BuildContext context) =>
      layout.RenderRepaintBoundary();
}

/// Shows or hides its child, keeping or releasing the space it occupied.
///
/// Hidden means not painted and not hit, in both modes. `maintainSize: true`
/// keeps the layout still while things appear and disappear; false collapses
/// the node to nothing. Either way the child is still laid out - see
/// [layout.RenderVisibility] for why that is the least bad of the three
/// options.
final class Visibility extends SingleChildRenderObjectWidget {
  const Visibility({
    super.key,
    this.visible = true,
    this.maintainSize = true,
    super.child,
  });

  final bool visible;

  final bool maintainSize;

  @override
  layout.RenderVisibility createRenderObject(BuildContext context) =>
      layout.RenderVisibility(visible: visible, maintainSize: maintainSize);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant layout.RenderVisibility renderObject,
  ) {
    renderObject
      ..maintainSize = maintainSize
      ..visible = visible;
  }
}
