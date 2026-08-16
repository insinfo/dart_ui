/// Widget integration for parsed SVG pictures.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../geometry/transform2d.dart';
import '../graphics/display_list.dart';
import '../graphics/display_list_geometry.dart';
import '../graphics/display_list_opcodes.dart';
import '../graphics/svg/svg_picture.dart';
import '../layout/alignment.dart';
import '../layout/box_constraints.dart';
import '../layout/render_box.dart';
import 'element.dart';
import 'image.dart' show BoxFit, FittedSizes, applyBoxFit;
import 'widget.dart';

/// Draws an [SvgPicture] through the ordinary path display-list pipeline.
///
/// CPU, D3D11 and OpenGL therefore consume the same paths; this widget never
/// rasterizes the vector into an intermediate bitmap.
final class Svg extends RenderObjectWidget {
  const Svg(
    this.picture, {
    super.key,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
  });

  factory Svg.string(
    String source, {
    Key? key,
    Object? cacheKey,
    double? width,
    double? height,
    BoxFit fit = BoxFit.contain,
    Alignment alignment = Alignment.center,
    SvgLimits limits = const SvgLimits(),
    int currentColor = 0xFF000000,
  }) {
    final Object effectiveKey = cacheKey ??
        (
          source,
          currentColor,
          limits.maxSourceCharacters,
          limits.maxElements,
          limits.maxPathCharacters,
        );
    return Svg(
      parseSvgCached(
        effectiveKey,
        source,
        limits: limits,
        currentColor: currentColor,
      ),
      key: key,
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
    );
  }

  final SvgPicture picture;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Alignment alignment;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderSvg createRenderObject(BuildContext context) => RenderSvg(
        picture,
        width: width,
        height: height,
        fit: fit,
        alignment: alignment,
      );

  @override
  void updateRenderObject(
      BuildContext context, covariant RenderSvg renderObject) {
    renderObject
      ..picture = picture
      ..width = width
      ..height = height
      ..fit = fit
      ..alignment = alignment;
  }
}

final class RenderSvg extends RenderBox {
  RenderSvg(
    SvgPicture picture, {
    double? width,
    double? height,
    BoxFit fit = BoxFit.contain,
    Alignment alignment = Alignment.center,
  })  : _picture = picture,
        _width = width,
        _height = height,
        _fit = fit,
        _alignment = alignment;

  SvgPicture _picture;
  double? _width;
  double? _height;
  BoxFit _fit;
  Alignment _alignment;

  SvgPicture get picture => _picture;
  set picture(SvgPicture value) {
    if (identical(value, _picture)) return;
    _picture = value;
    markNeedsLayout();
  }

  double? get width => _width;
  set width(double? value) {
    if (value == _width) return;
    _width = value;
    markNeedsLayout();
  }

  double? get height => _height;
  set height(double? value) {
    if (value == _height) return;
    _height = value;
    markNeedsLayout();
  }

  BoxFit get fit => _fit;
  set fit(BoxFit value) {
    if (value == _fit) return;
    _fit = value;
    markNeedsPaint();
  }

  Alignment get alignment => _alignment;
  set alignment(Alignment value) {
    if (value == _alignment) return;
    _alignment = value;
    markNeedsPaint();
  }

  Size get _naturalSize => Size(
        _width ?? _picture.size.width,
        _height ?? _picture.size.height,
      );

  @override
  void performLayout() {
    final BoxConstraints tightened =
        constraints.tighten(width: _width, height: _height);
    size = tightened.constrain(_naturalSize);
  }

  @override
  double computeMinIntrinsicWidth(double height) => _naturalSize.width;
  @override
  double computeMaxIntrinsicWidth(double height) => _naturalSize.width;
  @override
  double computeMinIntrinsicHeight(double width) => _naturalSize.height;
  @override
  double computeMaxIntrinsicHeight(double width) => _naturalSize.height;

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(DisplayList list, Offset offset) {
    if (size.isEmpty || _picture.paths.isEmpty) return;
    final Size sourceSize = Size(
      _picture.viewBox.width,
      _picture.viewBox.height,
    );
    final FittedSizes fitted = applyBoxFit(_fit, sourceSize, size);
    if (fitted.source.isEmpty || fitted.destination.isEmpty) return;

    final Rect source = _alignment.inscribe(
      fitted.source,
      Rect.fromLTWH(0, 0, sourceSize.width, sourceSize.height),
    );
    final Rect box =
        Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height);
    final Rect destination = _alignment.inscribe(fitted.destination, box);
    final double scaleX = destination.width / source.width;
    final double scaleY = destination.height / source.height;
    final Transform2D pictureToDevice = Transform2D(
      scaleX,
      0,
      0,
      scaleY,
      destination.left - (_picture.viewBox.left + source.left) * scaleX,
      destination.top - (_picture.viewBox.top + source.top) * scaleY,
    );

    list
      ..save()
      ..clipRectangle(box)
      ..transform2D(pictureToDevice);
    for (final SvgDrawPath draw in _picture.paths) {
      list
        ..save()
        ..transform2D(draw.transform);
      final int pathId = list.addPath(draw.path);
      final int? fill = draw.fillColor;
      if (fill != null && ((fill >> 24) & 0xFF) != 0) {
        list.drawPath(
          pathId,
          list.addPaint(
            colorArgb: fill,
            antiAlias: true,
            fillRule: draw.fillRule,
          ),
        );
      }
      final int? stroke = draw.strokeColor;
      if (stroke != null &&
          ((stroke >> 24) & 0xFF) != 0 &&
          draw.strokeWidth > 0) {
        list.drawPath(
          pathId,
          list.addPaint(
            colorArgb: stroke,
            style: paintStyleStroke,
            strokeWidth: draw.strokeWidth,
            antiAlias: true,
          ),
        );
      }
      list.restore();
    }
    list.restore();
  }
}
