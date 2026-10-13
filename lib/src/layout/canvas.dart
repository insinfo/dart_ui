/// Flutter's drawing API - [Canvas], [Paint], [BlendMode], [Clip] - as a
/// facade over the [DisplayList].
///
/// A Flutter `CustomPainter` receives a `Canvas` and a `Size` and draws with
/// `Paint` objects. Here the same calls encode display-list commands: a
/// [Canvas] is a cursor over one [DisplayList] that tracks the save stack and
/// the current transform, and a [Paint] is turned into an interned paint id at
/// each draw. Nothing is rasterised here, so a painter written for Flutter
/// draws through whichever backend replays the list - CPU or GPU.
///
/// ## How clips that are not rectangles work
///
/// No rasterizer in this repository implements `opClipPath`; the replay state
/// carries one device rectangle. [Canvas.clipRRect] and [Canvas.clipPath] are
/// therefore built from what every backend *does* implement - an isolated
/// `saveLayer` and the bounded masking blend modes `RenderShaderMask` already
/// relies on:
///
///     clipPath(p):  saveLayer(bounds(p), isolated) ; save
///     ...drawing...
///     restore():    restore ; <mask> ; restore
///
/// where `<mask>` is either one `dstOut` draw of "the layer minus the shape"
/// (an even-odd path: exact for a rounded rectangle, an oval or any even-odd
/// path) or, for a non-zero path that may overlap itself, a second layer
/// holding the shape composited with `dstIn`. Anti-aliasing comes from the
/// mask's own coverage, so `doAntiAlias: false` draws the mask aliased.
///
/// The cost is an offscreen buffer per clip (two for a general path) the size
/// of the shape's bounds. Direct2D and the DOM backend refuse the masking
/// modes by name, exactly as they refuse `ShaderMask`.
///
/// A [Canvas.clipRect] under a transform without rotation or skew is a native
/// rectangle clip and costs nothing; under rotation it becomes a path clip.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../geometry/offset.dart';
import '../geometry/path.dart';
import '../geometry/rect.dart';
import '../geometry/rrect.dart';
import '../geometry/stroke.dart';
import '../geometry/transform2d.dart';
import '../graphics/color.dart';
import '../graphics/display_list.dart';
import '../graphics/display_list_opcodes.dart';
import '../graphics/gradient.dart';
import '../graphics/image/decoded_image.dart';
import '../graphics/shader.dart';
import '../rendering/framebuffer.dart';
import '../text/shaper.dart' show TextDirection;

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

/// How a shape is combined with what is already drawn - Flutter's `BlendMode`.
///
/// The display list encodes only the Porter-Duff modes every backend can draw
/// with fixed-function blending: [srcOver], [src], [plus], [srcIn], [dstIn]
/// and [dstOut]. Two more are expressed through those: [clear] is `dstOut`
/// with an opaque source, and [dst] draws nothing. **Every other mode is
/// drawn as [srcOver]** - an app that relies on [multiply] or [screen] gets
/// the shape without the blend rather than a crash. [isSupported] says which
/// is which.
enum BlendMode {
  clear,
  src,
  dst,
  srcOver,
  dstOver,
  srcIn,
  dstIn,
  srcOut,
  dstOut,
  srcATop,
  dstATop,
  xor,
  plus,
  modulate,
  screen,
  overlay,
  darken,
  lighten,
  colorDodge,
  colorBurn,
  hardLight,
  softLight,
  difference,
  exclusion,
  multiply,
  hue,
  saturation,
  color,
  luminosity;

  /// Whether this mode is drawn as itself rather than as [srcOver].
  bool get isSupported =>
      this == dst || this == clear || displayListBlendMode != null;

  /// The display list's `blendMode*` constant for this mode, or null when it
  /// has none. [clear] answers `blendModeDstOut` (drawn with an opaque
  /// source); [dst] answers null and is drawn as nothing.
  int? get displayListBlendMode => switch (this) {
        BlendMode.srcOver => blendModeSrcOver,
        BlendMode.src => blendModeSrc,
        BlendMode.plus => blendModePlus,
        BlendMode.srcIn => blendModeSrcIn,
        BlendMode.dstIn => blendModeDstIn,
        BlendMode.dstOut => blendModeDstOut,
        BlendMode.clear => blendModeDstOut,
        _ => null,
      };
}

/// How a widget clips its content - Flutter's `Clip`.
enum Clip {
  /// No clip at all.
  none,

  /// A clip without anti-aliasing: fast, with jagged curved edges.
  hardEdge,

  /// A clip with anti-aliased edges.
  antiAlias,

  /// [antiAlias] followed by a layer. Every non-rectangular clip here is
  /// already a layer (see the library comment), so this paints exactly like
  /// [antiAlias].
  antiAliasWithSaveLayer,
}

/// Whether a clip keeps the inside or the outside of a shape.
enum ClipOp { difference, intersect }

/// Whether a shape is filled or outlined - Flutter's `PaintingStyle`.
enum PaintingStyle { fill, stroke }

/// How [Canvas.drawPoints] interprets its points.
enum PointMode {
  /// Each point is a dot, shaped by the paint's [StrokeCap].
  points,

  /// Each pair of points is a separate line segment.
  lines,

  /// The points are one connected polyline.
  polygon,
}

/// Blur styles of Flutter's `MaskFilter` and `BoxShadow.blurStyle`.
///
/// Only [normal] is drawn as itself; see `BoxShadow`.
enum BlurStyle { normal, solid, outer, inner }

// ---------------------------------------------------------------------------
// Paint
// ---------------------------------------------------------------------------

/// A description of how to draw - Flutter's `Paint`.
///
/// Mutable, like Flutter's: set the fields, then hand it to a [Canvas] call.
/// The canvas reads it at the call and interns an equivalent display-list
/// paint, so changing a [Paint] afterwards never alters what was drawn.
///
/// ## Differences from Flutter
///
///   * [strokeWidth] `0` is Flutter's hairline; here it is one unit in the
///     canvas's current coordinates, not one device pixel.
///   * [shader] may be a [Gradient] (Flutter's `ui.Gradient.linear`/`radial`)
///     or the shader a `SweepGradient` creates; image shaders do not exist.
///   * There is no `maskFilter`, `colorFilter`, `imageFilter`,
///     `filterQuality` or `invertColors`: the display list has no filters.
final class Paint {
  Paint();

  /// The colour. With a [shader], only its alpha is used, as an opacity.
  Color color = const Color(0xFF000000);

  BlendMode blendMode = BlendMode.srcOver;

  PaintingStyle style = PaintingStyle.fill;

  /// The pen width for [PaintingStyle.stroke]. Zero draws a one-unit line.
  double strokeWidth = 0.0;

  StrokeCap strokeCap = StrokeCap.butt;

  StrokeJoin strokeJoin = StrokeJoin.miter;

  double strokeMiterLimit = kDefaultMiterLimit;

  bool isAntiAlias = true;

  Shader? shader;

  @override
  String toString() => 'Paint($color, ${style.name}'
      '${style == PaintingStyle.stroke ? ' $strokeWidth' : ''}'
      '${blendMode == BlendMode.srcOver ? '' : ', ${blendMode.name}'}'
      '${shader == null ? '' : ', $shader'})';
}

// ---------------------------------------------------------------------------
// Sweep shader
// ---------------------------------------------------------------------------

/// The shader `SweepGradient.createShader` returns: a ramp around [center].
///
/// The display list has no sweep gradient, so [Canvas] paints a shape with
/// this shader by decomposition: the ramp is drawn into an isolated layer as
/// thin solid-coloured wedges (one per degree), and the
/// shape - filled or stroked, as the paint says - is drawn into a second layer
/// composited over them with `dstIn`, which keeps the colours only where the
/// shape is. Adjacent wedges differ by a 360th of the ramp, below what an
/// 8-bit channel shows; they overlap by half a step so no background shows at
/// their seams, and with translucent stop colours that overlap shows as faint
/// radial lines.
final class SweepShader extends Shader {
  SweepShader({
    required this.center,
    required this.startAngle,
    required this.endAngle,
    required List<Color> colors,
    List<double>? stops,
    this.tileMode = TileMode.clamp,
  })  : colors = List<Color>.unmodifiable(colors),
        stops = List<double>.unmodifiable(stops ??
            <double>[
              for (var i = 0; i < colors.length; i++)
                colors.length == 1 ? 0.0 : i / (colors.length - 1),
            ]) {
    if (colors.isEmpty) {
      throw ArgumentError.value(colors, 'colors', 'must not be empty');
    }
    if (this.stops.length != colors.length) {
      throw ArgumentError('"colors" and "stops" must have the same length');
    }
    if (!(endAngle > startAngle)) {
      throw ArgumentError.value(
          endAngle, 'endAngle', 'must be greater than startAngle');
    }
  }

  /// In the coordinates of the shape being drawn.
  final Offset center;
  final double startAngle;
  final double endAngle;
  final List<Color> colors;
  final List<double> stops;
  final TileMode tileMode;

  /// The colour at [angle] radians (clockwise from the positive x axis).
  Color colorAtAngle(double angle) {
    var t = (angle - startAngle) / (endAngle - startAngle);
    switch (tileMode) {
      case TileMode.clamp || TileMode.decal:
        t = t.clamp(0.0, 1.0);
      case TileMode.repeated:
        t = t - t.floorToDouble();
      case TileMode.mirror:
        final double m = t.abs() % 2.0;
        t = m > 1 ? 2 - m : m;
    }
    if (t <= stops.first) return colors.first;
    if (t >= stops.last) return colors.last;
    for (var i = 1; i < stops.length; i++) {
      if (t <= stops[i]) {
        final double span = stops[i] - stops[i - 1];
        final double f = span <= 0 ? 1.0 : (t - stops[i - 1]) / span;
        return Color.lerp(colors[i - 1], colors[i], f)!;
      }
    }
    return colors.last;
  }

  @override
  String toString() => 'SweepShader($center, $startAngle..$endAngle, '
      '$colors)';
}

/// Something that becomes a [Shader] once the box it fills is known - the
/// role Flutter's painting `Gradient` (`createShader`) plays for
/// `BoxDecoration.gradient` and `ShapeDecoration.gradient`.
///
/// Flutter's `LinearGradient` and `RadialGradient` names are taken here by
/// the display list's absolute-coordinate gradients, so today the
/// implementation a decoration accepts is `SweepGradient`.
abstract interface class ShaderProvider {
  /// The shader for [rect], resolving any directional geometry with
  /// [textDirection].
  Shader createShader(Rect rect, {TextDirection? textDirection});
}

// ---------------------------------------------------------------------------
// Picture recording
// ---------------------------------------------------------------------------

/// Records a [Picture] - Flutter's `PictureRecorder`.
final class PictureRecorder {
  PictureRecorder();

  final DisplayList _list = DisplayList();
  Canvas? _canvas;
  bool _ended = false;

  /// Whether a canvas is attached and [endRecording] has not been called.
  bool get isRecording => _canvas != null && !_ended;

  /// Finishes the recording: open saves are restored and pending clips
  /// applied. A second call returns an empty picture, as in Flutter.
  Picture endRecording() {
    if (_ended || _canvas == null) return Picture._(DisplayList());
    _ended = true;
    _canvas!.close();
    return Picture._(_list);
  }
}

/// A recorded sequence of drawing commands - Flutter's `Picture`.
///
/// There is no `toImage`: rasterising needs a renderer, and this layer does
/// not choose one. Replay it with [Canvas.drawPicture], or hand
/// [displayList] to a renderer.
final class Picture {
  Picture._(this.displayList);

  /// The commands, for a renderer or a test.
  final DisplayList displayList;

  bool _disposed = false;

  bool get debugDisposed => _disposed;

  int get approximateBytesUsed =>
      displayList.opLength * 4 + displayList.floatLength * 4;

  void dispose() => _disposed = true;
}

// ---------------------------------------------------------------------------
// Canvas
// ---------------------------------------------------------------------------

const double _kHuge = 1.0e6;

/// One entry of the canvas's save stack.
final class _Frame {
  _Frame(this.transform, this.clipBounds);

  final Transform2D transform;
  final Rect clipBounds;
  List<_PendingMask>? masks;
}

/// A non-rectangular clip waiting for its matching restore.
final class _PendingMask {
  _PendingMask(this.path, this.bounds, this.antiAlias, this.complement);

  final Path path;
  final Rect bounds;
  final bool antiAlias;

  /// One `dstOut` of "bounds minus shape" suffices (the shape is simple or
  /// even-odd); otherwise a `dstIn` layer of the shape is used.
  final bool complement;
}

/// An interface for recording drawing operations - Flutter's `Canvas`.
///
/// Built on a [PictureRecorder] as in Flutter, or directly on a
/// [DisplayList] with [Canvas.forDisplayList], which is what
/// `RenderCustomPaint` does for a `CustomPainter`.
///
/// The commands a canvas writes are self-contained: the first call that
/// changes state (a save, a transform, a clip) opens a `save`, and [close]
/// restores everything, so a painter that clips or transforms and forgets to
/// restore cannot leak that state into its siblings. A canvas that only draws
/// writes nothing but its draws.
///
/// ## Differences from Flutter
///
///   * Non-rectangular clips are layers; see the library comment.
///   * [drawImage] takes a [Framebuffer] or a [DecodedImage], not `ui.Image`.
///   * [transform] and [getTransform] use the 2D affine part of the 4x4
///     matrix; perspective and z are dropped.
///   * No `drawParagraph`, `drawVertices`, `drawAtlas`, `drawRSuperellipse` or
///     `clipRSuperellipse`; text is painted with the framework's
///     `TextPainter` into [displayList].
final class Canvas {
  /// A canvas recording into [recorder], as in Flutter.
  factory Canvas(PictureRecorder recorder, [Rect? cullRect]) {
    if (recorder._canvas != null) {
      throw ArgumentError.value(recorder, 'recorder',
          'already has a canvas; a recorder records one canvas');
    }
    final Canvas canvas = Canvas.forDisplayList(recorder._list, cullRect);
    recorder._canvas = canvas;
    return canvas;
  }

  /// A canvas that appends to [list]. [cullRect], when given, is the area
  /// the caller will show; it only seeds [getLocalClipBounds].
  Canvas.forDisplayList(DisplayList list, [Rect? cullRect])
      : _list = list,
        _clipBounds =
            cullRect ?? const Rect.fromLTRB(-_kHuge, -_kHuge, _kHuge, _kHuge) {
    _frames.add(_Frame(_transform, _clipBounds));
  }

  final DisplayList _list;

  /// The display list this canvas writes to, for the framework's own
  /// painters (text, images) that draw with primitives.
  DisplayList get displayList => _list;

  final List<_Frame> _frames = <_Frame>[];

  Transform2D _transform = Transform2D.identity;

  /// A conservative bound of the clip, in the canvas's own coordinates (the
  /// space before any [translate]/[scale] on this canvas).
  Rect _clipBounds;

  bool _closed = false;

  /// Whether the outermost `save` has been written; see the class comment.
  bool _scoped = false;

  void _ensureScoped() {
    if (_scoped) return;
    _scoped = true;
    _list.save();
  }

  void _checkOpen() {
    if (_closed) {
      throw StateError('this Canvas was closed; record into a new one');
    }
  }

  /// Restores every open save and applies pending clips. Called by the
  /// framework when a painter returns and by [PictureRecorder.endRecording];
  /// further drawing throws a [StateError].
  void close() {
    if (_closed) return;
    restoreToCount(1);
    _popFrame(outermost: true);
    _closed = true;
  }

  // -------------------------------------------------------------------------
  // Save stack
  // -------------------------------------------------------------------------

  /// The number of saves in force, counting the initial state as 1.
  int getSaveCount() => _frames.length;

  /// Saves the transform and clip; [restore] brings them back.
  void save() {
    _checkOpen();
    _ensureScoped();
    _list.save();
    _frames.add(_Frame(_transform, _clipBounds));
  }

  /// Like [save], but drawing until the matching [restore] goes into a layer
  /// composited with [paint]'s opacity and blend mode.
  ///
  /// The layer is always isolated - drawn over transparency - as Skia's is,
  /// so a `BlendMode.clear` or `dstOut` inside erases only what the layer
  /// drew. [bounds], when null, is the whole clip.
  void saveLayer(Rect? bounds, Paint paint) {
    _checkOpen();
    _ensureScoped();
    final Rect b = bounds ?? _localClipBoundsOrHuge();
    final int alpha = paint.color.alpha;
    final int blend = paint.blendMode.displayListBlendMode ?? blendModeSrcOver;
    final int id = _list.addPaint(
      colorArgb: paint.blendMode == BlendMode.clear
          ? 0xFFFFFFFF
          : (alpha << 24) | 0x00FFFFFF,
      blendMode: blend,
      isolatedLayer: true,
    );
    _list.saveLayer(b.left, b.top, b.right, b.bottom, id);
    _frames.add(_Frame(_transform, _clipBounds));
  }

  /// Pops one save. Extra restores are ignored, as in Flutter.
  void restore() {
    _checkOpen();
    if (_frames.length <= 1) return;
    _popFrame();
  }

  /// Restores until [getSaveCount] is [count] (at least 1).
  void restoreToCount(int count) {
    _checkOpen();
    final int target = count < 1 ? 1 : count;
    while (_frames.length > target) {
      _popFrame();
    }
  }

  void _popFrame({bool outermost = false}) {
    final _Frame frame = _frames.removeLast();
    final List<_PendingMask>? masks = frame.masks;
    if (masks != null) {
      for (var i = masks.length - 1; i >= 0; i--) {
        _applyMask(masks[i]);
      }
    }
    if (!outermost || _scoped) _list.restore();
    _transform = frame.transform;
    _clipBounds = frame.clipBounds;
  }

  // -------------------------------------------------------------------------
  // Transform
  // -------------------------------------------------------------------------

  void _concat(Transform2D t) {
    _checkOpen();
    _ensureScoped();
    _list.transform(t.a, t.b, t.c, t.d, t.tx, t.ty);
    _transform = _transform.multiply(t);
  }

  void translate(double dx, double dy) =>
      _concat(Transform2D.translation(dx, dy));

  void scale(double sx, [double? sy]) =>
      _concat(Transform2D.scaling(sx, sy ?? sx));

  void rotate(double radians) => _concat(Transform2D.rotation(radians));

  void skew(double sx, double sy) => _concat(Transform2D(1, sy, sx, 1, 0, 0));

  /// Multiplies the current transform by [matrix4], a column-major 4x4
  /// matrix of which the 2D affine part is used.
  void transform(List<double> matrix4) {
    if (matrix4.length != 16) {
      throw ArgumentError.value(
          matrix4.length, 'matrix4', 'must have 16 entries (column-major)');
    }
    _concat(Transform2D(matrix4[0], matrix4[1], matrix4[4], matrix4[5],
        matrix4[12], matrix4[13]));
  }

  /// The current transform as a column-major 4x4 matrix.
  Float64List getTransform() {
    final Transform2D t = _transform;
    return Float64List.fromList(<double>[
      t.a, t.b, 0, 0, //
      t.c, t.d, 0, 0, //
      0, 0, 1, 0, //
      t.tx, t.ty, 0, 1, //
    ]);
  }

  /// The current transform, in the framework's own type.
  Transform2D get currentTransform => _transform;

  // -------------------------------------------------------------------------
  // Clips
  // -------------------------------------------------------------------------

  /// A conservative bound of the clip in local coordinates.
  Rect getLocalClipBounds() {
    final Transform2D? inverse = _transform.invert();
    if (inverse == null) return Rect.zero;
    return inverse.transformRect(_clipBounds);
  }

  /// A conservative bound of the clip in the canvas's own coordinates.
  Rect getDestinationClipBounds() => _clipBounds;

  Rect _localClipBoundsOrHuge() {
    final Rect local = getLocalClipBounds();
    return local.isEmpty ? Rect.zero : local;
  }

  void _intersectClip(Rect local) {
    _clipBounds = _clipBounds.intersect(_transform.transformRect(local));
  }

  bool get _axisAligned => _transform.b == 0 && _transform.c == 0;

  /// Clips to [rect]. A native rectangle clip when the transform has no
  /// rotation or skew; otherwise, and for [ClipOp.difference], a mask.
  void clipRect(
    Rect rect, {
    ClipOp clipOp = ClipOp.intersect,
    bool doAntiAlias = true,
  }) {
    _checkOpen();
    _ensureScoped();
    if (clipOp == ClipOp.intersect) {
      if (_axisAligned) {
        _list.clipRect(rect.left, rect.top, rect.right, rect.bottom);
        _intersectClip(rect);
        return;
      }
      _pushMask(Path.rect(rect), rect, doAntiAlias, complement: true);
      return;
    }
    // Difference: keep everything but the rectangle.
    final Rect bounds = _localClipBoundsOrHuge();
    final Path keep = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(bounds)
      ..addRect(rect);
    _pushMask(keep, bounds, doAntiAlias, complement: true);
  }

  /// Clips to [rrect], anti-aliased unless [doAntiAlias] is false.
  void clipRRect(RRect rrect, {bool doAntiAlias = true}) {
    _checkOpen();
    if (rrect.isRect) {
      clipRect(rrect.outerRect, doAntiAlias: doAntiAlias);
      return;
    }
    _pushMask(Path()..addRRect(rrect), rrect.outerRect, doAntiAlias,
        complement: true);
  }

  /// Clips to [path] under its [Path.fillType].
  void clipPath(Path path, {bool doAntiAlias = true}) {
    _checkOpen();
    final Path snapshot = Path.from(path);
    _pushMask(snapshot, snapshot.bounds, doAntiAlias,
        complement: snapshot.fillType == PathFillType.evenOdd);
  }

  void _pushMask(Path path, Rect bounds, bool antiAlias,
      {required bool complement}) {
    _ensureScoped();
    final Rect layer = bounds.intersect(_localClipBoundsOrHuge());
    final Rect safe = layer.isEmpty ? Rect.zero : layer;
    _list.saveLayer(safe.left, safe.top, safe.right, safe.bottom,
        _list.addPaint(colorArgb: 0xFFFFFFFF, isolatedLayer: true));
    _list.save();
    (_frames.last.masks ??= <_PendingMask>[])
        .add(_PendingMask(path, safe, antiAlias, complement));
    _intersectClip(safe);
  }

  void _applyMask(_PendingMask mask) {
    // Back to the transform the clip was made under.
    _list.restore();
    writeClipMask(_list, mask.path, mask.bounds,
        antiAlias: mask.antiAlias, complement: mask.complement);
    _list.restore();
  }

  // -------------------------------------------------------------------------
  // Drawing
  // -------------------------------------------------------------------------

  /// Fills the whole clip with [color] in [blendMode].
  void drawColor(Color color, BlendMode blendMode) => drawPaint(Paint()
    ..color = color
    ..blendMode = blendMode);

  /// Fills the whole clip with [paint].
  void drawPaint(Paint paint) {
    final Rect all = _localClipBoundsOrHuge();
    final Paint fill = _copy(paint)..style = PaintingStyle.fill;
    drawRect(all, fill);
  }

  /// A line from [p1] to [p2], always stroked.
  void drawLine(Offset p1, Offset p2, Paint paint) {
    final Path line = Path()
      ..moveTo(p1.dx, p1.dy)
      ..lineTo(p2.dx, p2.dy);
    _drawPathWith(line, _copy(paint)..style = PaintingStyle.stroke);
  }

  /// Under a rotation or skew applied on this canvas the rectangle goes out
  /// as a path: the replay fills a rectangle command as its device bounding
  /// box, which is exact only while the transform keeps axes aligned.
  void drawRect(Rect rect, Paint paint) {
    if (!_axisAligned) {
      _drawPathWith(Path.rect(rect), paint);
      return;
    }
    _draw(paint, () => Path.rect(rect), rect, (int id) {
      _list.drawRect(rect.left, rect.top, rect.right, rect.bottom, id);
    });
  }

  /// A path under rotation or skew, for the reason [drawRect] gives.
  void drawRRect(RRect rrect, Paint paint) {
    final RRect r = rrect.scaleRadii();
    if (!_axisAligned) {
      _drawPathWith(Path()..addRRect(r), paint);
      return;
    }
    _draw(paint, () => Path()..addRRect(r), r.outerRect, (int id) {
      _list.drawRRect(
          r.left,
          r.top,
          r.right,
          r.bottom,
          r.tlRadiusX,
          r.tlRadiusY,
          r.trRadiusX,
          r.trRadiusY,
          r.brRadiusX,
          r.brRadiusY,
          r.blRadiusX,
          r.blRadiusY,
          id);
    });
  }

  /// The area between [outer] and [inner].
  void drawDRRect(RRect outer, RRect inner, Paint paint) {
    final Path ring = Path()
      ..fillType = PathFillType.evenOdd
      ..addRRect(outer)
      ..addRRect(inner);
    drawPath(ring, paint);
  }

  void drawOval(Rect rect, Paint paint) =>
      drawRRect(RRect.fromRectXY(rect, rect.width / 2, rect.height / 2), paint);

  void drawCircle(Offset c, double radius, Paint paint) => drawRRect(
      RRect.fromLTRBXY(c.dx - radius, c.dy - radius, c.dx + radius,
          c.dy + radius, radius, radius),
      paint);

  /// An arc of the oval inscribed in [rect]; with [useCenter], a wedge.
  void drawArc(Rect rect, double startAngle, double sweepAngle, bool useCenter,
      Paint paint) {
    final Path arc = Path();
    if (useCenter) {
      arc
        ..moveTo(rect.center.dx, rect.center.dy)
        ..arcTo(rect, startAngle, sweepAngle, false)
        ..close();
    } else {
      arc.addArc(rect, startAngle, sweepAngle);
    }
    drawPath(arc, paint);
  }

  /// Draws [path] under its [Path.fillType]. The path is copied, so editing
  /// it afterwards does not change what was drawn.
  void drawPath(Path path, Paint paint) =>
      _drawPathWith(Path.from(path), paint);

  void _drawPathWith(Path path, Paint paint) {
    final int fillRule = path.fillType == PathFillType.evenOdd
        ? pathFillRuleEvenOdd
        : pathFillRuleNonZero;
    _draw(paint, () => path, path.bounds, (int id) {
      _list.drawPath(_list.addPath(path), id);
    }, fillRule: fillRule);
  }

  /// Draws [points] as dots, separate lines or a polyline.
  void drawPoints(PointMode pointMode, List<Offset> points, Paint paint) {
    if (points.isEmpty) return;
    final Paint pen = _copy(paint)..style = PaintingStyle.stroke;
    switch (pointMode) {
      case PointMode.points:
        final double w = pen.strokeWidth > 0 ? pen.strokeWidth : 1.0;
        final Paint dot = _copy(paint)..style = PaintingStyle.fill;
        final Path dots = Path();
        for (final Offset p in points) {
          final Rect r = Rect.fromLTRB(
              p.dx - w / 2, p.dy - w / 2, p.dx + w / 2, p.dy + w / 2);
          if (pen.strokeCap == StrokeCap.round) {
            dots.addOval(r);
          } else {
            dots.addRect(r);
          }
        }
        _drawPathWith(dots, dot);
      case PointMode.lines:
        final Path lines = Path();
        for (var i = 0; i + 1 < points.length; i += 2) {
          lines
            ..moveTo(points[i].dx, points[i].dy)
            ..lineTo(points[i + 1].dx, points[i + 1].dy);
        }
        _drawPathWith(lines, pen);
      case PointMode.polygon:
        _drawPathWith(Path()..addPolygon(points, false), pen);
    }
  }

  /// [drawPoints] with the points packed as `x, y` pairs.
  void drawRawPoints(PointMode pointMode, Float32List points, Paint paint) {
    drawPoints(
        pointMode,
        <Offset>[
          for (var i = 0; i + 1 < points.length; i += 2)
            Offset(points[i], points[i + 1]),
        ],
        paint);
  }

  /// Draws [image] - a [Framebuffer] or a [DecodedImage] - with its top-left
  /// corner at [offset]. The paint's alpha is the opacity.
  void drawImage(Object image, Offset offset, Paint paint) {
    final Framebuffer fb = _framebufferOf(image);
    drawImageRect(
      fb,
      Rect.fromLTWH(0, 0, fb.width.toDouble(), fb.height.toDouble()),
      Rect.fromLTWH(
          offset.dx, offset.dy, fb.width.toDouble(), fb.height.toDouble()),
      paint,
    );
  }

  /// Draws the [src] part of [image] into [dst].
  void drawImageRect(Object image, Rect src, Rect dst, Paint paint) {
    _checkOpen();
    final Framebuffer fb = _framebufferOf(image);
    final int id = _list.addPaint(
      colorArgb: (paint.color.alpha << 24) | 0x00FFFFFF,
      blendMode: paint.blendMode.displayListBlendMode ?? blendModeSrcOver,
      antiAlias: paint.isAntiAlias,
    );
    _list.drawImage(_list.addImage(fb), src.left, src.top, src.right,
        src.bottom, dst.left, dst.top, dst.right, dst.bottom, id);
  }

  static Framebuffer _framebufferOf(Object image) {
    if (image is Framebuffer) return image;
    if (image is DecodedImage) {
      return Framebuffer(
        width: image.width,
        height: image.height,
        bytesPerRow: image.bytesPerRow,
        format: switch (image.order) {
          ImageChannelOrder.bgra => PixelFormat.bgra8888Premultiplied,
          ImageChannelOrder.rgba => PixelFormat.rgba8888Premultiplied,
        },
        pixels: image.pixels,
      );
    }
    throw ArgumentError.value(
        image, 'image', 'must be a Framebuffer or a DecodedImage');
  }

  /// Replays [picture] here, under the current transform and clip.
  void drawPicture(Picture picture) {
    _checkOpen();
    if (picture._disposed) {
      throw StateError('the picture was disposed');
    }
    _list.appendFrom(picture.displayList);
  }

  /// An approximate material shadow for [path] at [elevation].
  ///
  /// Flutter's is a light-source model; this is the same layered blur
  /// `BoxShadow` uses, offset down by half the elevation with a sigma of
  /// half the elevation. [transparentOccluder] is ignored.
  void drawShadow(
    Path path,
    Color color,
    double elevation,
    bool transparentOccluder,
  ) {
    _checkOpen();
    if (!(elevation > 0)) return;
    final Path shifted = path.shift(Offset(0, elevation / 2));
    paintBlurredPath(_list, shifted,
        color.withAlpha((color.alpha * 0.5).round()), elevation / 2);
  }

  // -------------------------------------------------------------------------
  // Paint translation
  // -------------------------------------------------------------------------

  static Paint _copy(Paint p) => Paint()
    ..color = p.color
    ..blendMode = p.blendMode
    ..style = p.style
    ..strokeWidth = p.strokeWidth
    ..strokeCap = p.strokeCap
    ..strokeJoin = p.strokeJoin
    ..strokeMiterLimit = p.strokeMiterLimit
    ..isAntiAlias = p.isAntiAlias
    ..shader = p.shader;

  /// Interns [paint] as a display-list paint.
  int paintId(Paint paint, {int fillRule = pathFillRuleNonZero}) {
    final Shader? shader = paint.shader;
    final BlendMode mode = paint.blendMode;
    final int blend = mode.displayListBlendMode ?? blendModeSrcOver;
    var color = paint.color.value;
    if (mode == BlendMode.clear) color = 0xFF000000;
    final bool stroke = paint.style == PaintingStyle.stroke;
    return _list.addPaint(
      colorArgb: color,
      style: stroke ? paintStyleStroke : paintStyleFill,
      strokeWidth:
          stroke ? (paint.strokeWidth > 0 ? paint.strokeWidth : 1.0) : 0.0,
      blendMode: blend,
      antiAlias: paint.isAntiAlias,
      fillRule: fillRule,
      gradient:
          shader is Gradient ? _withAlpha(shader, paint.color.alpha) : null,
      strokeCap: paint.strokeCap,
      strokeJoin: paint.strokeJoin,
      miterLimit: paint.strokeMiterLimit,
    );
  }

  /// A gradient's stops carry its alpha (the paint colour is not sampled),
  /// so the paint's opacity is folded into them.
  static Gradient _withAlpha(Gradient g, int alpha) {
    if (alpha == 255) return g;
    final List<GradientStop> stops = <GradientStop>[
      for (var i = 0; i < g.stopCount; i++)
        GradientStop(
          g.stopOffsets[i],
          ((((g.stopColors[i] >>> 24) * alpha + 127) ~/ 255) << 24) |
              (g.stopColors[i] & 0x00FFFFFF),
        ),
    ];
    return switch (g) {
      LinearGradient() => LinearGradient(
          startX: g.startX,
          startY: g.startY,
          endX: g.endX,
          endY: g.endY,
          stops: stops,
          spread: g.spread),
      RadialGradient() => RadialGradient(
          centerX: g.centerX,
          centerY: g.centerY,
          radius: g.radius,
          focusX: g.focusX,
          focusY: g.focusY,
          stops: stops,
          spread: g.spread),
    };
  }

  void _draw(Paint paint, Path Function() shape, Rect shapeBounds,
      void Function(int paintId) emit,
      {int fillRule = pathFillRuleNonZero}) {
    _checkOpen();
    if (paint.blendMode == BlendMode.dst) return;
    final Shader? shader = paint.shader;
    if (shader is SweepShader) {
      _drawSweep(paint, shader, shape(), shapeBounds, fillRule);
      return;
    }
    if (shader != null && shader is! Gradient) {
      throw ArgumentError.value(shader, 'paint.shader',
          'only a Gradient or a SweepShader can be drawn');
    }
    emit(paintId(paint, fillRule: fillRule));
  }

  void _drawSweep(
      Paint paint, SweepShader shader, Path shape, Rect bounds, int fillRule) {
    final double grow = paint.style == PaintingStyle.stroke
        ? (paint.strokeWidth > 0 ? paint.strokeWidth : 1.0) *
            (paint.strokeJoin == StrokeJoin.miter
                ? paint.strokeMiterLimit
                : 1.0)
        : 0.0;
    final Rect b = bounds.inflate(grow + 1);
    // The colours, in a layer composited with the paint's opacity and mode.
    _list.saveLayer(
      b.left,
      b.top,
      b.right,
      b.bottom,
      _list.addPaint(
        colorArgb: (paint.color.alpha << 24) | 0x00FFFFFF,
        blendMode: paint.blendMode.displayListBlendMode ?? blendModeSrcOver,
        isolatedLayer: true,
      ),
    );
    paintSweepWedges(_list, shader, b);
    // The shape, drawn with the paint's own geometry (fill or stroke) into a
    // second layer composited with dstIn: the colours survive only where the
    // shape is, anti-aliased edge included.
    _list.saveLayer(
      b.left,
      b.top,
      b.right,
      b.bottom,
      _list.addPaint(
          colorArgb: 0xFFFFFFFF,
          blendMode: blendModeDstIn,
          isolatedLayer: true),
    );
    final Paint mask = _copy(paint)
      ..shader = null
      ..blendMode = BlendMode.srcOver
      ..color = const Color(0xFFFFFFFF);
    _list.drawPath(_list.addPath(shape), paintId(mask, fillRule: fillRule));
    _list
      ..restore()
      ..restore();
  }
}

// ---------------------------------------------------------------------------
// Shared helpers for the render objects
// ---------------------------------------------------------------------------

/// Writes the mask that finishes a clip opened with an isolated `saveLayer`
/// over [bounds]: everything in the layer outside [path] is erased.
///
/// With [complement] one `dstOut` draw of "[bounds] minus [path]" does it -
/// exact when [path] is a simple shape or even-odd. Without, the shape goes
/// into a second isolated layer composited with `dstIn`, which is exact for
/// any non-zero path, overlapping contours included.
void writeClipMask(
  DisplayList list,
  Path path,
  Rect bounds, {
  required bool antiAlias,
  required bool complement,
}) {
  if (bounds.isEmpty) return;
  if (complement) {
    final Path both = Path()
      ..addRect(bounds.inflate(1))
      ..addPath(path, Offset.zero)
      ..fillType = PathFillType.evenOdd;
    list.drawPath(
      list.addPath(both),
      list.addPaint(
        colorArgb: 0xFFFFFFFF,
        blendMode: blendModeDstOut,
        antiAlias: antiAlias,
        fillRule: pathFillRuleEvenOdd,
      ),
    );
    return;
  }
  list.saveLayer(
    bounds.left,
    bounds.top,
    bounds.right,
    bounds.bottom,
    list.addPaint(
        colorArgb: 0xFFFFFFFF, blendMode: blendModeDstIn, isolatedLayer: true),
  );
  list.drawPath(
    list.addPath(path),
    list.addPaint(
      colorArgb: 0xFFFFFFFF,
      antiAlias: antiAlias,
      fillRule: path.fillType == PathFillType.evenOdd
          ? pathFillRuleEvenOdd
          : pathFillRuleNonZero,
    ),
  );
  list.restore();
}

/// Covers [bounds] with one-degree wedges of [shader]'s colours around its
/// centre, each drawn in [blendMode]. See [SweepShader].
void paintSweepWedges(
  DisplayList list,
  SweepShader shader,
  Rect bounds, {
  int blendMode = blendModeSrcOver,
}) {
  const int wedges = 360;
  const double step = 2 * math.pi / wedges;
  final Offset c = shader.center;
  var radius = 0.0;
  for (final Offset corner in <Offset>[
    bounds.topLeft,
    Offset(bounds.right, bounds.top),
    bounds.bottomRight,
    Offset(bounds.left, bounds.bottom),
  ]) {
    radius = math.max(radius, (corner - c).distance);
  }
  // The far edge of a wedge is a chord; push it out so the chord, not just
  // its ends, clears the farthest corner.
  final double reach = (radius + 2) / math.cos(step);
  for (var i = 0; i < wedges; i++) {
    final double a0 = i * step - step / 2;
    final double a1 = (i + 1) * step + step / 2;
    final Color color = shader.colorAtAngle((i + 0.5) * step);
    final Path wedge = (PathBuilder()
          ..moveTo(c.dx, c.dy)
          ..lineTo(c.dx + reach * math.cos(a0), c.dy + reach * math.sin(a0))
          ..lineTo(c.dx + reach * math.cos(a1), c.dy + reach * math.sin(a1))
          ..close())
        .build();
    list.drawPath(list.addPath(wedge),
        list.addPaint(colorArgb: color.value, blendMode: blendMode));
  }
}

/// The standard deviation Flutter derives from a blur radius
/// (`BoxShadow.convertRadiusToSigma`).
double convertRadiusToSigma(double radius) =>
    radius > 0 ? radius * 0.57735 + 0.5 : 0;

/// Approximates a Gaussian blur of [rrect] filled with [color].
///
/// There is no blur in any renderer here, so the falloff is built from
/// nested rounded rectangles - inflated and deflated copies of [rrect] - each
/// translucent enough that the stack's accumulated alpha follows the
/// Gaussian's integral across the edge, out to two and a half [sigma] on
/// either side. With anti-aliased edges and steps of about two pixels or
/// less the steps are invisible; very large blurs (sigma above about 25)
/// show faint banding. Zero [sigma] draws the shape sharp.
void paintBlurredRRect(
    DisplayList list, RRect rrect, Color color, double sigma) {
  if (color.alpha == 0 || rrect.isEmpty && !(sigma > 0)) return;
  if (!(sigma > 0)) {
    final RRect r = rrect.scaleRadii();
    list.drawRRect(
        r.left,
        r.top,
        r.right,
        r.bottom,
        r.tlRadiusX,
        r.tlRadiusY,
        r.trRadiusX,
        r.trRadiusY,
        r.brRadiusX,
        r.brRadiusY,
        r.blRadiusX,
        r.blRadiusY,
        list.addPaint(colorArgb: color.value));
    return;
  }
  for (final (double offset, int argb) in _blurLayers(color, sigma)) {
    final RRect r = rrect.inflate(offset);
    if (r.isEmpty) continue;
    final RRect s = r.scaleRadii();
    list.drawRRect(
        s.left,
        s.top,
        s.right,
        s.bottom,
        s.tlRadiusX,
        s.tlRadiusY,
        s.trRadiusX,
        s.trRadiusY,
        s.brRadiusX,
        s.brRadiusY,
        s.blRadiusX,
        s.blRadiusY,
        list.addPaint(colorArgb: argb));
  }
}

/// Approximates a Gaussian blur of an arbitrary [path], with the same
/// layering as [paintBlurredRRect] built from strokes of the outline: a
/// stroke of width `2d` covers everything within `d` of the edge, inside and
/// out, so a stack of them reproduces the falloff on both sides.
void paintBlurredPath(DisplayList list, Path path, Color color, double sigma) {
  if (color.alpha == 0 || path.isEmpty) return;
  final int fillRule = path.fillType == PathFillType.evenOdd
      ? pathFillRuleEvenOdd
      : pathFillRuleNonZero;
  final int pathId = list.addPath(Path.from(path));
  if (!(sigma > 0)) {
    list.drawPath(
        pathId, list.addPaint(colorArgb: color.value, fillRule: fillRule));
    return;
  }
  for (final (double offset, int argb) in _blurLayers(color, sigma)) {
    if (offset > 0) {
      list.drawPath(
          pathId,
          list.addPaint(
            colorArgb: argb,
            style: paintStyleStroke,
            strokeWidth: offset * 2,
            strokeJoin: StrokeJoin.round,
          ));
    } else {
      // The inner half of the ramp: the fill plus the strokes already drawn
      // over-cover the inside, which a blur of a solid shape does anyway.
      list.drawPath(pathId, list.addPaint(colorArgb: argb, fillRule: fillRule));
      return;
    }
  }
}

/// The (inflate, colour) layers of a blurred edge, outermost first.
///
/// With layers at signed distances `e_0 > e_1 > ...` from the edge, a point
/// at distance `d` is covered by every layer with `e_k >= d`, so its alpha is
/// `1 - prod(1 - a_k)`. Solving that for the target `A * Phi(-e_j / sigma)`
/// at each layer gives `a_j = 1 - (1 - T_j) / (1 - T_{j-1})`.
List<(double, int)> _blurLayers(Color color, double sigma) {
  final double reach = 2.5 * sigma;
  final int count = (2 * reach / 1.5).ceil().clamp(4, 40);
  final double a = color.alpha / 255;
  final int rgb = color.value & 0x00FFFFFF;
  final List<(double, int)> layers = <(double, int)>[];
  var previous = 0.0;
  for (var i = 0; i < count; i++) {
    final double e = reach - 2 * reach * i / (count - 1);
    final double target = i == count - 1 ? a : a * _phi(-e / sigma);
    final double alpha = previous >= 1 ? 0 : 1 - (1 - target) / (1 - previous);
    previous = target;
    final int byte = (alpha.clamp(0.0, 1.0) * 255).round();
    if (byte == 0) continue;
    layers.add((e, (byte << 24) | rgb));
  }
  return layers;
}

/// The standard normal cumulative distribution (Abramowitz-Stegun 7.1.26).
double _phi(double x) {
  final double z = x.abs() / math.sqrt2;
  final double t = 1 / (1 + 0.3275911 * z);
  final double erf = 1 -
      (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t -
                      0.284496736) *
                  t +
              0.254829592) *
          t *
          math.exp(-z * z);
  return x >= 0 ? 0.5 * (1 + erf) : 0.5 * (1 - erf);
}
