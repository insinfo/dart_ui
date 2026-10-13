/// The clip render nodes with Flutter's shape: [RenderClipRect],
/// [RenderClipRRect], [RenderClipOval] and [RenderClipPath], each with a
/// [CustomClipper] and a [Clip] behaviour.
///
/// ## Rounded corners are clipped in paint now
///
/// No rasterizer implements `opClipPath`, so a rounded rectangle, an oval or
/// a path cannot be a native clip. They are painted the way
/// `Canvas.clipPath` paints them (see `canvas.dart`): the child goes into an
/// isolated layer the size of the clip's bounds, and a mask drawn with the
/// bounded `dstOut`/`dstIn` blend modes erases what lies outside the shape.
/// The cost is an offscreen buffer per clip while it is on screen;
/// [Clip.none] and a [RenderClipRRect] whose corners are all square avoid it,
/// and [RenderClipRect] never pays it. Direct2D and the DOM backend refuse
/// the masking modes by name, as they do for `ShaderMask`.
///
/// ## Hit testing follows the shape
///
/// A pointer outside the clip is not delivered to the child, for every shape
/// and whether or not a [CustomClipper] is set. Flutter rejects outside the
/// shape for [RenderClipOval] always, but for a rounded rectangle only when a
/// clipper is given; this framework has always rejected the corners of a
/// [RenderClipRRect], and keeps doing so.
library;

import '../geometry/offset.dart';
import '../geometry/path.dart';
import '../geometry/rect.dart';
import '../geometry/rrect.dart';
import '../geometry/size.dart';
import '../graphics/display_list.dart';
import '../graphics/display_list_geometry.dart';
import '../text/shaper.dart' show TextDirection;
import 'border_radius.dart';
import 'canvas.dart';
import 'custom_painter.dart';
import 'pipeline.dart';
import 'render_box.dart';
import 'render_proxy_box.dart' show RenderProxyBox;

/// The machinery the four clip nodes share: a clipper, a behaviour, and a
/// cached clip that is recomputed when the size or the clipper changes.
abstract class _RenderCustomClip<T> extends RenderProxyBox {
  _RenderCustomClip({
    CustomClipper<T>? clipper,
    Clip clipBehavior = Clip.antiAlias,
    super.child,
  })  : _clipper = clipper,
        _clipBehavior = clipBehavior;

  CustomClipper<T>? _clipper;
  Clip _clipBehavior;
  T? _clip;
  Size? _clipSize;

  /// Computes the clip; null means the default for the node's shape.
  CustomClipper<T>? get clipper => _clipper;

  set clipper(CustomClipper<T>? value) {
    if (identical(value, _clipper)) return;
    final CustomClipper<T>? old = _clipper;
    _clipper = value;
    if (value == null ||
        old == null ||
        value.runtimeType != old.runtimeType ||
        value.shouldReclip(old)) {
      _markNeedsClip();
    }
    if (owner != null) {
      old?.removeListener(_markNeedsClip);
      value?.addListener(_markNeedsClip);
    }
  }

  /// How the clip is applied; [Clip.none] paints the child unclipped.
  Clip get clipBehavior => _clipBehavior;

  set clipBehavior(Clip value) {
    if (value == _clipBehavior) return;
    _clipBehavior = value;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _clipper?.addListener(_markNeedsClip);
  }

  @override
  void detach() {
    _clipper?.removeListener(_markNeedsClip);
    super.detach();
  }

  void _markNeedsClip() {
    _clip = null;
    markNeedsPaint();
  }

  T get _defaultClip;

  /// The clip for the current size, in local coordinates.
  T get currentClip {
    final Size size = this.size;
    if (_clip == null || _clipSize != size) {
      _clipSize = size;
      _clip = _clipper?.getClip(size) ?? _defaultClip;
    }
    return _clip as T;
  }

  bool _inside(T clip, Offset position);

  @override
  RenderBox? hitTest(Offset position, {HitTestPath? path}) {
    if (!hasSize || !_inside(currentClip, position)) return null;
    return super.hitTest(position, path: path);
  }

  /// Paints the child inside an isolated layer over [bounds] and erases what
  /// lies outside [shape]. Shared by the three non-rectangular nodes.
  void _paintMasked(DisplayList list, Offset offset, Path shape, Rect bounds,
      {required bool complement}) {
    final RenderBox? child = this.child;
    if (child == null) return;
    if (bounds.isEmpty) return;
    list.saveLayer(bounds.left, bounds.top, bounds.right, bounds.bottom,
        list.addPaint(colorArgb: 0xFFFFFFFF, isolatedLayer: true));
    paintChild(list, child, offset);
    writeClipMask(list, shape, bounds,
        antiAlias: _clipBehavior != Clip.hardEdge, complement: complement);
    list.restore();
  }
}

/// Clips its child to a rectangle - the box, or what [clipper] returns.
///
/// Flutter's `RenderClipRect`; the default [clipBehavior] is
/// [Clip.hardEdge], as there. A native rectangle clip, so it costs no layer.
final class RenderClipRect extends _RenderCustomClip<Rect> {
  RenderClipRect({
    super.child,
    super.clipper,
    super.clipBehavior = Clip.hardEdge,
  });

  @override
  Rect get _defaultClip => Rect.fromLTWH(0, 0, size.width, size.height);

  @override
  bool _inside(Rect clip, Offset position) =>
      _clipper == null || clip.contains(position);

  @override
  void paint(DisplayList list, Offset offset) {
    final RenderBox? child = this.child;
    if (child == null) return;
    // An empty clip admits nothing. Emitting the pair anyway would be correct
    // and would still cost a save/restore per frame on a collapsed panel.
    if (size.isEmpty) return;
    if (_clipBehavior == Clip.none) {
      paintChild(list, child, offset);
      return;
    }
    list
      ..save()
      ..clipRectangle(currentClip.shift(offset));
    paintChild(list, child, offset);
    list.restore();
  }
}

/// Clips its child to a rounded rectangle - Flutter's `RenderClipRRect`.
///
/// The corners are [borderRadius] (resolved with [textDirection]), or the
/// framework's original circular [radius] when [borderRadius] is zero, or
/// whatever [clipper] returns. They are clipped in paint (see the library
/// comment) and for the pointer.
final class RenderClipRRect extends _RenderCustomClip<RRect> {
  RenderClipRRect({
    double radius = 0.0,
    BorderRadiusGeometry borderRadius = BorderRadius.zero,
    super.clipper,
    super.clipBehavior = Clip.antiAlias,
    TextDirection? textDirection,
    super.child,
  })  : _radius = _checkedRadius(radius),
        _borderRadius = borderRadius,
        _textDirection = textDirection;

  double _radius;
  BorderRadiusGeometry _borderRadius;
  TextDirection? _textDirection;

  /// The framework's original circular radius, used when [borderRadius] is
  /// zero. Clamped at use time to half the shorter side, so an over-large
  /// radius produces a stadium rather than a self-crossing outline.
  double get radius => _radius;

  set radius(double value) {
    if (value == _radius) return;
    _radius = _checkedRadius(value);
    _markNeedsClip();
  }

  /// Flutter's per-corner radii.
  BorderRadiusGeometry get borderRadius => _borderRadius;

  set borderRadius(BorderRadiusGeometry value) {
    if (value == _borderRadius) return;
    _borderRadius = value;
    _markNeedsClip();
  }

  TextDirection? get textDirection => _textDirection;

  set textDirection(TextDirection? value) {
    if (value == _textDirection) return;
    _textDirection = value;
    _markNeedsClip();
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

  /// The [radius] actually used, after clamping to what the box can hold.
  double get effectiveRadius {
    final double limit =
        (size.width < size.height ? size.width : size.height) / 2;
    return _radius < limit ? _radius : (limit > 0 ? limit : 0);
  }

  @override
  RRect get _defaultClip {
    final Rect box = Rect.fromLTWH(0, 0, size.width, size.height);
    final BorderRadius resolved = _borderRadius.resolve(_textDirection);
    if (resolved == BorderRadius.zero && _radius > 0) {
      return RRect.fromRectAndRadius(box, Radius.circular(_radius));
    }
    return resolved.toRRect(box);
  }

  @override
  bool _inside(RRect clip, Offset position) {
    // RRect.contains excludes the right and bottom edges; a box includes
    // them everywhere else in this framework, so the edges are tested first.
    if (clip.isRect) {
      return position.dx >= clip.left &&
          position.dx <= clip.right &&
          position.dy >= clip.top &&
          position.dy <= clip.bottom;
    }
    return clip.contains(position);
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final RenderBox? child = this.child;
    if (child == null) return;
    if (size.isEmpty) return;
    if (_clipBehavior == Clip.none) {
      paintChild(list, child, offset);
      return;
    }
    final RRect clip = currentClip.shift(offset);
    if (clip.isRect) {
      list
        ..save()
        ..clipRectangle(clip.outerRect);
      paintChild(list, child, offset);
      list.restore();
      return;
    }
    _paintMasked(list, offset, Path()..addRRect(clip), clip.outerRect,
        complement: true);
  }
}

/// Clips its child to the oval inscribed in the box (or in what [clipper]
/// returns) - Flutter's `RenderClipOval`.
final class RenderClipOval extends _RenderCustomClip<Rect> {
  RenderClipOval({
    super.child,
    super.clipper,
    super.clipBehavior = Clip.antiAlias,
  });

  @override
  Rect get _defaultClip => Rect.fromLTWH(0, 0, size.width, size.height);

  @override
  bool _inside(Rect clip, Offset position) {
    if (clip.isEmpty) return false;
    final Offset center = clip.center;
    final double dx = (position.dx - center.dx) / clip.width;
    final double dy = (position.dy - center.dy) / clip.height;
    return dx * dx + dy * dy <= 0.25;
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final RenderBox? child = this.child;
    if (child == null) return;
    if (size.isEmpty) return;
    if (_clipBehavior == Clip.none) {
      paintChild(list, child, offset);
      return;
    }
    final Rect oval = currentClip.shift(offset);
    _paintMasked(list, offset, Path()..addOval(oval), oval, complement: true);
  }
}

/// Clips its child to a [Path] - Flutter's `RenderClipPath`.
///
/// Without a [clipper] the path is the box. A non-zero path that may overlap
/// itself is masked with a second layer, which costs a second buffer; an
/// even-odd path needs only one. See `writeClipMask`.
final class RenderClipPath extends _RenderCustomClip<Path> {
  RenderClipPath({
    super.child,
    super.clipper,
    super.clipBehavior = Clip.antiAlias,
  });

  @override
  Path get _defaultClip =>
      Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));

  @override
  bool _inside(Path clip, Offset position) =>
      _clipper == null || clip.contains(position);

  @override
  void paint(DisplayList list, Offset offset) {
    final RenderBox? child = this.child;
    if (child == null) return;
    if (size.isEmpty) return;
    if (_clipBehavior == Clip.none) {
      paintChild(list, child, offset);
      return;
    }
    if (_clipper == null) {
      list
        ..save()
        ..clipRectangle(
            Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height));
      paintChild(list, child, offset);
      list.restore();
      return;
    }
    final Path shape = currentClip.shift(offset);
    _paintMasked(list, offset, shape, shape.bounds,
        complement: shape.fillType == PathFillType.evenOdd);
  }
}
