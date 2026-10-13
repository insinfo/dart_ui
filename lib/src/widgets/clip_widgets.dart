/// [ClipOval] and [ClipPath], with Flutter's names and parameters.
///
/// `ClipRect` and `ClipRRect` live in `proxy.dart` with the rest of the
/// single-child proxies. All four paint through the clip nodes of
/// `layout/render_clip.dart`, which explains how a non-rectangular clip is
/// drawn without a clip-path rasterizer, and what it costs.
library;

import '../geometry/path.dart';
import '../geometry/rect.dart';
import '../layout/borders.dart';
import '../layout/canvas.dart' show Clip;
import '../layout/custom_painter.dart';
import '../layout/render_clip.dart';
import 'directionality.dart';
import 'element.dart';
import 'layout_builder.dart' show Builder;
import 'widget.dart';

/// Clips its child to the oval inscribed in its box, or in the rectangle
/// [clipper] returns - Flutter's `ClipOval`.
final class ClipOval extends SingleChildRenderObjectWidget {
  const ClipOval({
    super.key,
    this.clipper,
    this.clipBehavior = Clip.antiAlias,
    super.child,
  });

  final CustomClipper<Rect>? clipper;

  /// [Clip.none] paints the child unclipped; [Clip.hardEdge] cuts aliased.
  final Clip clipBehavior;

  @override
  RenderClipOval createRenderObject(BuildContext context) =>
      RenderClipOval(clipper: clipper, clipBehavior: clipBehavior);

  @override
  void updateRenderObject(
      BuildContext context, covariant RenderClipOval renderObject) {
    renderObject
      ..clipper = clipper
      ..clipBehavior = clipBehavior;
  }
}

/// Clips its child to the [Path] [clipper] returns - Flutter's `ClipPath`.
///
/// Without a clipper it clips to its box. [ClipPath.shape] clips to a
/// [ShapeBorder]'s outer path.
final class ClipPath extends SingleChildRenderObjectWidget {
  const ClipPath({
    super.key,
    this.clipper,
    this.clipBehavior = Clip.antiAlias,
    super.child,
  });

  /// Clips to [shape]'s outer path, resolved with the ambient
  /// [Directionality].
  static Widget shape({
    Key? key,
    required ShapeBorder shape,
    Clip clipBehavior = Clip.antiAlias,
    Widget? child,
  }) =>
      Builder(
        key: key,
        builder: (BuildContext context) => ClipPath(
          clipper: ShapeBorderClipper(
            shape: shape,
            textDirection: Directionality.maybeOf(context),
          ),
          clipBehavior: clipBehavior,
          child: child,
        ),
      );

  final CustomClipper<Path>? clipper;

  /// [Clip.none] paints the child unclipped; [Clip.hardEdge] cuts aliased.
  final Clip clipBehavior;

  @override
  RenderClipPath createRenderObject(BuildContext context) =>
      RenderClipPath(clipper: clipper, clipBehavior: clipBehavior);

  @override
  void updateRenderObject(
      BuildContext context, covariant RenderClipPath renderObject) {
    renderObject
      ..clipper = clipper
      ..clipBehavior = clipBehavior;
  }
}
