/// Widget that places an already decoded [VideoFrame] in the widget tree.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/display_list.dart';
import '../graphics/display_list_geometry.dart';
import '../graphics/video/video_frame.dart';
import '../layout/alignment.dart';
import '../layout/box_constraints.dart';
import '../layout/render_box.dart';
import 'element.dart';
import 'image.dart' show BoxFit, FittedSizes, applyBoxFit;
import 'widget.dart';

final class VideoFrameView extends RenderObjectWidget {
  const VideoFrameView(
    this.frame, {
    super.key,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
  });

  final VideoFrame frame;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Alignment alignment;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderVideoFrame createRenderObject(BuildContext context) => RenderVideoFrame(
        frame,
        width: width,
        height: height,
        fit: fit,
        alignment: alignment,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderVideoFrame renderObject,
  ) {
    renderObject
      ..frame = frame
      ..width = width
      ..height = height
      ..fit = fit
      ..alignment = alignment;
  }
}

final class RenderVideoFrame extends RenderBox {
  RenderVideoFrame(
    VideoFrame frame, {
    double? width,
    double? height,
    BoxFit fit = BoxFit.contain,
    Alignment alignment = Alignment.center,
  })  : _frame = frame,
        _width = width,
        _height = height,
        _fit = fit,
        _alignment = alignment;

  VideoFrame _frame;
  double? _width;
  double? _height;
  BoxFit _fit;
  Alignment _alignment;

  VideoFrame get frame => _frame;
  set frame(VideoFrame value) {
    if (value == _frame) return;
    final bool sizeChanged =
        value.width != _frame.width || value.height != _frame.height;
    _frame = value;
    sizeChanged ? markNeedsLayout() : markNeedsPaint();
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

  Size get _sourceSize =>
      Size(_frame.width.toDouble(), _frame.height.toDouble());

  /// The box this frame asks for before its parent's constraints are applied.
  Size get _naturalSize => Size(
        _width ?? _frame.width.toDouble(),
        _height ?? _frame.height.toDouble(),
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

  /// The part of the frame sampled by the current fit, in frame pixels.
  Rect get sourceRect {
    final FittedSizes fitted = applyBoxFit(_fit, _sourceSize, size);
    return _alignment.inscribe(
      fitted.source,
      Rect.fromLTWH(0, 0, _sourceSize.width, _sourceSize.height),
    );
  }

  /// Where the fitted frame lands, in this render object's coordinates.
  Rect get destinationRect {
    final FittedSizes fitted = applyBoxFit(_fit, _sourceSize, size);
    return _alignment.inscribe(
      fitted.destination,
      Rect.fromLTWH(0, 0, size.width, size.height),
    );
  }

  @override
  void paint(DisplayList list, Offset offset) {
    if (size.isEmpty) return;
    final FittedSizes fitted = applyBoxFit(_fit, _sourceSize, size);
    if (fitted.source.isEmpty || fitted.destination.isEmpty) return;
    final Rect source = _alignment.inscribe(
      fitted.source,
      Rect.fromLTWH(0, 0, _sourceSize.width, _sourceSize.height),
    );
    final Rect box =
        Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height);
    final Rect destination = _alignment.inscribe(fitted.destination, box);
    final int paintId = list.addPaint(colorArgb: 0xFFFFFFFF);
    list
      ..save()
      ..clipRectangle(box)
      ..drawImage(
        list.addImage(_frame),
        source.left,
        source.top,
        source.right,
        source.bottom,
        destination.left,
        destination.top,
        destination.right,
        destination.bottom,
        paintId,
      )
      ..restore();
  }
}
