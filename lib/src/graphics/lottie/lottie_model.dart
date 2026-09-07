/// The shape of a Lottie animation once it has been parsed, and the arithmetic
/// that turns it into values at a point in time.
///
/// Lottie is After Effects animation serialised as JSON. Nothing here reads
/// JSON — `lottie_parser.dart` does that — and nothing here draws, which
/// `lottie_painter.dart` does. This file is the middle: immutable data plus the
/// interpolation, so that both of the others can be tested against it and it
/// can be tested against hand-computed numbers.
///
/// ## Why the split matters for performance
///
/// A player redraws sixty times a second and the document does not change. If
/// evaluation and parsing were the same pass, every frame would re-read a
/// hundred kilobytes of JSON. Parse once into [LottieAnimation]; ask it for
/// values at a time as often as you like.
///
/// ## What is here and what is refused
///
/// The subset is the one the sample files in `test/data` use, which is also the
/// subset that covers most shape-layer animation: shape layers, precomps, null
/// layers, groups, bezier paths, ellipses, fills, strokes and transforms, with
/// keyframes on all of them. Text, images, masks, track mattes, trim paths,
/// gradients, repeaters, merge paths and 3D are **not** implemented, and the
/// parser refuses them by name rather than dropping them. A Lottie file that
/// renders as a blank rectangle with no error is the worst possible outcome and
/// is what naming them avoids.
library;

import 'dart:math' as math;

import '../../geometry/offset.dart';

/// A property whose value may change over time.
///
/// Two shapes, because Lottie has two: a constant (`"a": 0`) and a list of
/// keyframes (`"a": 1`). They are one type rather than two so that a caller
/// never has to ask which it got — [valueAt] answers either way, and a constant
/// costs one branch.
sealed class LottieProperty<T> {
  const LottieProperty();

  /// The value at [frame], in composition frames.
  T valueAt(double frame);

  /// Whether this property can ever change. Used to skip work, never to change
  /// an answer.
  bool get isAnimated;
}

/// A property that never changes.
final class LottieConstant<T> extends LottieProperty<T> {
  const LottieConstant(this.value);

  final T value;

  @override
  T valueAt(double frame) => value;

  @override
  bool get isAnimated => false;

  @override
  String toString() => 'LottieConstant($value)';
}

/// One keyframe: the value at [frame], and how to get from it to the next one.
///
/// [easeOut] and [easeIn] are the two control points of a cubic bezier from
/// (0,0) to (1,1) that reshapes time across **this** segment — the one that
/// starts here. Both live on the same keyframe in the file format, which reads
/// oddly (`i` sounds like it belongs to the segment arriving) and is why the
/// names here say out-then-in rather than repeating `o` and `i`.
///
/// Getting this wrong is the single most visible parser bug: linear
/// interpolation everywhere makes a bouncing character move like a metronome,
/// and nothing about the output looks broken enough to point at the cause.
final class LottieKeyframe<T> {
  const LottieKeyframe({
    required this.frame,
    required this.value,
    required this.endValue,
    this.easeOut,
    this.easeIn,
    this.hold = false,
    this.spatialOut,
    this.spatialIn,
  });

  /// Composition frame this keyframe sits on.
  final double frame;

  /// Value at [frame].
  final T value;

  /// Value at the next keyframe's frame.
  ///
  /// Lottie writes this as `e` on the keyframe itself in older exports and
  /// omits it in newer ones, where the next keyframe's `s` is the end. The
  /// parser resolves that difference so nothing downstream has to, which is why
  /// this is non-null here and optional in the file.
  final T endValue;

  /// First control point of the timing curve, or null for linear.
  final Offset? easeOut;

  /// Second control point of the timing curve, or null for linear.
  final Offset? easeIn;

  /// Whether the value jumps at the next keyframe instead of interpolating.
  final bool hold;

  /// Out tangent of the motion path, relative to [value]. Position only.
  final Offset? spatialOut;

  /// In tangent of the motion path, relative to [endValue]. Position only.
  final Offset? spatialIn;

  /// Whether this segment's motion follows a curve rather than a straight line.
  bool get isSpatial =>
      (spatialOut != null && spatialOut != Offset.zero) ||
      (spatialIn != null && spatialIn != Offset.zero);
}

/// A property driven by keyframes.
///
/// [lerp] is supplied by the caller rather than being a method on `T`, because
/// the values Lottie animates are `double`, [Offset], colours and bezier paths,
/// and only one of those is a type this repository owns.
final class LottieAnimatedProperty<T> extends LottieProperty<T> {
  LottieAnimatedProperty({
    required List<LottieKeyframe<T>> keyframes,
    required T Function(T a, T b, double t) lerp,
  })  : _keyframes = List<LottieKeyframe<T>>.unmodifiable(keyframes),
        _lerp = lerp {
    if (keyframes.isEmpty) {
      throw ArgumentError.value(
        keyframes,
        'keyframes',
        'an animated property needs at least one keyframe; a property with '
            'none is a constant and should be a LottieConstant',
      );
    }
  }

  final List<LottieKeyframe<T>> _keyframes;
  final T Function(T a, T b, double t) _lerp;

  /// The keyframes, in ascending frame order.
  List<LottieKeyframe<T>> get keyframes => _keyframes;

  /// The index found last time, so a player scanning forward one frame at a
  /// time does not binary-search a hundred keyframes per property per frame.
  ///
  /// A cache and never a source of truth: [valueAt] falls back to a search
  /// whenever the hint does not fit, so a caller is free to jump backwards, to
  /// scrub, or to evaluate two times out of order.
  int _hint = 0;

  @override
  bool get isAnimated => true;

  @override
  T valueAt(double frame) {
    final int last = _keyframes.length - 1;
    if (frame <= _keyframes.first.frame) return _keyframes.first.value;
    if (frame >= _keyframes[last].frame) return _keyframes[last].value;

    final int index = _segmentFor(frame);
    final LottieKeyframe<T> key = _keyframes[index];
    final double span = _keyframes[index + 1].frame - key.frame;
    if (span <= 0 || key.hold) return key.value;

    final double linear = (frame - key.frame) / span;
    final double eased = _ease(key, linear);
    return _lerp(key.value, key.endValue, eased);
  }

  /// The keyframe whose segment contains [frame].
  int _segmentFor(double frame) {
    // The hint first: the overwhelmingly common call is "the same segment as
    // last time, or the next one".
    final int hint = _hint;
    if (hint < _keyframes.length - 1 &&
        frame >= _keyframes[hint].frame &&
        frame < _keyframes[hint + 1].frame) {
      return hint;
    }
    var low = 0;
    var high = _keyframes.length - 1;
    while (low < high - 1) {
      final int mid = (low + high) >> 1;
      if (_keyframes[mid].frame <= frame) {
        low = mid;
      } else {
        high = mid;
      }
    }
    return _hint = low;
  }

  static double _ease(LottieKeyframe<Object?> key, double t) {
    final Offset? out = key.easeOut;
    final Offset? into = key.easeIn;
    if (out == null || into == null) return t;
    return solveTimingBezier(out, into, t);
  }
}

/// Solves the cubic bezier through (0,0), [out], [into], (1,1) for `y` at `x`.
///
/// The curve is a *reparameterisation of time*, so it is not enough to evaluate
/// the bezier at parameter `t`: `x` is itself a cubic in `t` and has to be
/// inverted first. Newton-Raphson from a good guess converges in three or four
/// steps for the shapes an animation tool produces; the bisection fallback is
/// there for the pathological ones, where the derivative near a control point
/// at exactly 0 or 1 is zero and Newton stalls.
///
/// Public because the parser validates against it and the tests check it
/// against values computed by hand.
double solveTimingBezier(Offset out, Offset into, double x) {
  if (x <= 0) return 0;
  if (x >= 1) return 1;
  // A curve whose control points lie on the diagonal is the identity, and it
  // is common enough in exported files to be worth not iterating over.
  if (out.dx == out.dy && into.dx == into.dy) return x;

  double curve(double a, double b, double t) {
    final double mt = 1 - t;
    return 3 * mt * mt * t * a + 3 * mt * t * t * b + t * t * t;
  }

  double slope(double a, double b, double t) {
    final double mt = 1 - t;
    return 3 * mt * mt * a + 6 * mt * t * (b - a) + 3 * t * t * (1 - b);
  }

  var t = x;
  for (var i = 0; i < 8; i++) {
    final double error = curve(out.dx, into.dx, t) - x;
    if (error.abs() < 1e-7) return curve(out.dy, into.dy, t);
    final double derivative = slope(out.dx, into.dx, t);
    if (derivative.abs() < 1e-7) break;
    t -= error / derivative;
  }

  // Bisection, which cannot stall. Twenty halvings of [0,1] is a resolution of
  // one part in a million, far finer than a pixel at any sane composition size.
  var low = 0.0;
  var high = 1.0;
  t = x;
  for (var i = 0; i < 20; i++) {
    final double at = curve(out.dx, into.dx, t);
    if ((at - x).abs() < 1e-7) break;
    if (at < x) {
      low = t;
    } else {
      high = t;
    }
    t = (low + high) / 2;
  }
  return curve(out.dy, into.dy, t);
}

/// One closed or open bezier contour, in the form Lottie stores it.
///
/// [inTangents] and [outTangents] are **relative to their own vertex**, which
/// is the most common thing to get wrong when reading this format: they look
/// like absolute control points and are not. The conversion to absolute happens
/// exactly once, in the painter, and this type keeps the file's own convention
/// so that interpolation between two shapes is the interpolation the exporter
/// intended.
final class LottieShapeData {
  const LottieShapeData({
    required this.vertices,
    required this.inTangents,
    required this.outTangents,
    required this.closed,
  });

  static const LottieShapeData empty = LottieShapeData(
    vertices: <Offset>[],
    inTangents: <Offset>[],
    outTangents: <Offset>[],
    closed: false,
  );

  final List<Offset> vertices;
  final List<Offset> inTangents;
  final List<Offset> outTangents;
  final bool closed;

  bool get isEmpty => vertices.isEmpty;

  /// Straight-line blend of two shapes with the same vertex count.
  ///
  /// A shape keyframe pair with different counts cannot be blended and is not
  /// supposed to exist: After Effects keeps the vertex count fixed across a
  /// shape's keyframes precisely so this works. When one turns up anyway the
  /// answer is the nearer end rather than an exception, because a single
  /// malformed shape should not take the whole animation down.
  static LottieShapeData lerp(LottieShapeData a, LottieShapeData b, double t) {
    if (t <= 0) return a;
    if (t >= 1) return b;
    final int count = a.vertices.length;
    if (count != b.vertices.length) return t < 0.5 ? a : b;
    return LottieShapeData(
      vertices: _lerpPoints(a.vertices, b.vertices, t),
      inTangents: _lerpPoints(a.inTangents, b.inTangents, t),
      outTangents: _lerpPoints(a.outTangents, b.outTangents, t),
      closed: t < 0.5 ? a.closed : b.closed,
    );
  }

  static List<Offset> _lerpPoints(List<Offset> a, List<Offset> b, double t) {
    final int count = a.length < b.length ? a.length : b.length;
    return <Offset>[
      for (var i = 0; i < count; i++)
        Offset(
          a[i].dx + (b[i].dx - a[i].dx) * t,
          a[i].dy + (b[i].dy - a[i].dy) * t,
        ),
    ];
  }
}

/// Straight-line blend of two doubles.
double lerpDouble(double a, double b, double t) => a + (b - a) * t;

/// Straight-line blend of two points.
Offset lerpOffset(Offset a, Offset b, double t) =>
    Offset(a.dx + (b.dx - a.dx) * t, a.dy + (b.dy - a.dy) * t);

/// Blends a position keyframe along its motion path.
///
/// Lottie position keyframes carry two extra tangents, `to` and `ti`, which
/// make the path between two positions a cubic rather than a straight line —
/// an object arcing rather than sliding. The tangents are relative to their own
/// endpoints, like everything else in this format.
Offset evaluateSpatial(LottieKeyframe<Offset> key, double t) {
  final Offset start = key.value;
  final Offset end = key.endValue;
  final Offset out = key.spatialOut ?? Offset.zero;
  final Offset into = key.spatialIn ?? Offset.zero;
  final double mt = 1 - t;
  final double a = mt * mt * mt;
  final double b = 3 * mt * mt * t;
  final double c = 3 * mt * t * t;
  final double d = t * t * t;
  final Offset c1 = Offset(start.dx + out.dx, start.dy + out.dy);
  final Offset c2 = Offset(end.dx + into.dx, end.dy + into.dy);
  return Offset(
    a * start.dx + b * c1.dx + c * c2.dx + d * end.dx,
    a * start.dy + b * c1.dy + c * c2.dy + d * end.dy,
  );
}

/// A position property, which is the one place Lottie can curve the path
/// between two values rather than only the timing.
final class LottiePosition extends LottieProperty<Offset> {
  LottiePosition(this._inner);

  final LottieProperty<Offset> _inner;

  @override
  bool get isAnimated => _inner.isAnimated;

  @override
  Offset valueAt(double frame) {
    final LottieProperty<Offset> inner = _inner;
    if (inner is! LottieAnimatedProperty<Offset>) return inner.valueAt(frame);
    final List<LottieKeyframe<Offset>> keys = inner.keyframes;
    if (frame <= keys.first.frame) return keys.first.value;
    if (frame >= keys.last.frame) return keys.last.value;
    // Straight to the segment: the spatial tangents live on the keyframe and
    // the generic path would have thrown them away by the time it lerped.
    var index = 0;
    for (var i = 0; i < keys.length - 1; i++) {
      if (frame >= keys[i].frame && frame < keys[i + 1].frame) {
        index = i;
        break;
      }
    }
    final LottieKeyframe<Offset> key = keys[index];
    final double span = keys[index + 1].frame - key.frame;
    if (span <= 0 || key.hold) return key.value;
    final double linear = (frame - key.frame) / span;
    final Offset? out = key.easeOut;
    final Offset? into = key.easeIn;
    final double eased = out == null || into == null
        ? linear
        : solveTimingBezier(out, into, linear);
    if (!key.isSpatial) return lerpOffset(key.value, key.endValue, eased);
    return evaluateSpatial(key, eased);
  }
}

/// A colour as Lottie stores it: three or four channels in 0..1.
///
/// Kept as doubles rather than converted at parse time because colour is
/// interpolated in that space; rounding to bytes first would band a slow fade.
final class LottieColor {
  const LottieColor(this.r, this.g, this.b, this.a);

  static const LottieColor black = LottieColor(0, 0, 0, 1);

  final double r;
  final double g;
  final double b;
  final double a;

  static LottieColor lerp(LottieColor a, LottieColor b, double t) =>
      LottieColor(
        a.r + (b.r - a.r) * t,
        a.g + (b.g - a.g) * t,
        a.b + (b.b - a.b) * t,
        a.a + (b.a - a.a) * t,
      );

  /// Packed 0xAARRGGBB, with [opacity] in 0..1 folded in.
  ///
  /// Lottie carries the shape's opacity separately from the colour's alpha and
  /// both apply, so multiplying here is not a convenience: keeping them apart
  /// would make every caller remember to do it.
  int toArgb(double opacity) {
    int channel(double value) => (value.clamp(0.0, 1.0) * 255).round();
    return (channel(a * opacity) << 24) |
        (channel(r) << 16) |
        (channel(g) << 8) |
        channel(b);
  }

  @override
  String toString() => 'LottieColor($r, $g, $b, $a)';
}

/// A layer or group transform.
///
/// The order the parts combine in is After Effects' and not the order the JSON
/// lists them: translate to the position, rotate, scale, then move the anchor
/// point to the origin. Applying anchor first — which reads more naturally and
/// is what a first attempt does — rotates the layer about the composition
/// origin instead of about its own anchor, and every rotation in the file is
/// then wrong in a way that looks like a coordinate bug somewhere else.
final class LottieTransform {
  const LottieTransform({
    required this.anchor,
    required this.position,
    required this.scale,
    required this.rotation,
    required this.opacity,
    this.skew,
    this.skewAxis,
  });

  static final LottieTransform identity = LottieTransform(
    anchor: const LottieConstant<Offset>(Offset.zero),
    position: LottiePosition(const LottieConstant<Offset>(Offset.zero)),
    scale: const LottieConstant<Offset>(Offset(100, 100)),
    rotation: const LottieConstant<double>(0),
    opacity: const LottieConstant<double>(100),
  );

  final LottieProperty<Offset> anchor;
  final LottieProperty<Offset> position;

  /// Percent, so 100 means unscaled. Lottie's own unit, kept rather than
  /// divided at parse time so a value read back matches the file.
  final LottieProperty<Offset> scale;

  /// Degrees, clockwise.
  final LottieProperty<double> rotation;

  /// Percent, so 100 means opaque.
  final LottieProperty<double> opacity;

  /// Degrees of skew, and the axis it is applied along. Both null when the
  /// exporter wrote no skew, which is the overwhelming majority of files.
  final LottieProperty<double>? skew;
  final LottieProperty<double>? skewAxis;

  double opacityAt(double frame) =>
      (opacity.valueAt(frame) / 100).clamp(0.0, 1.0);
}

/// What a shape element is.
enum LottieShapeKind {
  group,
  path,
  ellipse,
  rectangle,
  fill,
  stroke,
  transform,
}

/// One entry in a shape layer's list.
sealed class LottieShapeElement {
  const LottieShapeElement(this.name);

  final String name;

  LottieShapeKind get kind;
}

/// A `gr`: a nested list with its own transform, which is the last element.
final class LottieShapeGroup extends LottieShapeElement {
  const LottieShapeGroup(super.name, this.children);

  final List<LottieShapeElement> children;

  @override
  LottieShapeKind get kind => LottieShapeKind.group;
}

/// A `sh`: an animatable bezier contour.
final class LottieShapePath extends LottieShapeElement {
  const LottieShapePath(super.name, this.data, {this.direction = 1});

  final LottieProperty<LottieShapeData> data;

  /// 1 or 3, the winding direction the exporter recorded. Kept because the
  /// even-odd rule is unaffected by it but the non-zero rule is not.
  final int direction;

  @override
  LottieShapeKind get kind => LottieShapeKind.path;
}

/// An `el`: a centre and a diameter, both animatable.
final class LottieShapeEllipse extends LottieShapeElement {
  const LottieShapeEllipse(super.name, this.center, this.size);

  final LottieProperty<Offset> center;

  /// Full width and height, not radii. Lottie calls it `s` for size and means
  /// the diameter; halving it at parse time would make a value read back
  /// disagree with the file.
  final LottieProperty<Offset> size;

  @override
  LottieShapeKind get kind => LottieShapeKind.ellipse;
}

/// An `rc`: a rounded rectangle.
final class LottieShapeRect extends LottieShapeElement {
  const LottieShapeRect(super.name, this.center, this.size, this.radius);

  final LottieProperty<Offset> center;
  final LottieProperty<Offset> size;
  final LottieProperty<double> radius;

  @override
  LottieShapeKind get kind => LottieShapeKind.rectangle;
}

/// An `fl`.
final class LottieShapeFill extends LottieShapeElement {
  const LottieShapeFill(
    super.name,
    this.color,
    this.opacity, {
    this.evenOdd = false,
  });

  final LottieProperty<LottieColor> color;

  /// Percent.
  final LottieProperty<double> opacity;

  /// Lottie's `r`: 1 is non-zero, 2 is even-odd.
  final bool evenOdd;

  @override
  LottieShapeKind get kind => LottieShapeKind.fill;
}

/// An `st`.
final class LottieShapeStroke extends LottieShapeElement {
  const LottieShapeStroke(
    super.name,
    this.color,
    this.opacity,
    this.width, {
    this.lineCap = 2,
    this.lineJoin = 2,
  });

  final LottieProperty<LottieColor> color;
  final LottieProperty<double> opacity;
  final LottieProperty<double> width;

  /// Lottie's `lc`: 1 butt, 2 round, 3 square.
  final int lineCap;

  /// Lottie's `lj`: 1 miter, 2 round, 3 bevel.
  final int lineJoin;

  @override
  LottieShapeKind get kind => LottieShapeKind.stroke;
}

/// A `tr` inside a group.
final class LottieShapeTransform extends LottieShapeElement {
  const LottieShapeTransform(super.name, this.transform);

  final LottieTransform transform;

  @override
  LottieShapeKind get kind => LottieShapeKind.transform;
}

/// What kind of layer this is. The numbers are Lottie's own `ty`.
enum LottieLayerType {
  precomp(0),
  solid(1),
  image(2),
  nullLayer(3),
  shape(4),
  text(5);

  const LottieLayerType(this.code);

  final int code;

  static LottieLayerType? fromCode(int code) {
    for (final LottieLayerType type in values) {
      if (type.code == code) return type;
    }
    return null;
  }
}

/// One layer.
final class LottieLayer {
  const LottieLayer({
    required this.index,
    required this.name,
    required this.type,
    required this.transform,
    required this.inPoint,
    required this.outPoint,
    required this.startTime,
    required this.timeStretch,
    this.parent,
    this.shapes = const <LottieShapeElement>[],
    this.refId,
    this.solidColor,
    this.solidWidth = 0,
    this.solidHeight = 0,
    this.hidden = false,
  });

  /// Lottie's `ind`, which is what [parent] refers to.
  final int index;
  final String name;
  final LottieLayerType type;
  final LottieTransform transform;

  /// First and last composition frame this layer is visible on, from `ip`/`op`.
  final double inPoint;
  final double outPoint;

  /// `st`: the frame the layer's own timeline starts at, which is what shifts
  /// a precomp's content relative to the composition around it.
  final double startTime;

  /// `sr`: a multiplier on the layer's own time. 1 is normal speed.
  final double timeStretch;

  /// `parent`: the `ind` of the layer whose transform this one sits under.
  final int? parent;

  /// Shape elements, for [LottieLayerType.shape].
  final List<LottieShapeElement> shapes;

  /// `refId`, for [LottieLayerType.precomp].
  final String? refId;

  final LottieColor? solidColor;
  final double solidWidth;
  final double solidHeight;

  /// `hd`: hidden in the authoring tool, and therefore not drawn.
  final bool hidden;

  /// Whether this layer draws anything at composition frame [frame].
  bool isVisibleAt(double frame) =>
      !hidden && frame >= inPoint && frame < outPoint;

  /// Converts a composition frame to this layer's own frame.
  ///
  /// The stretch divides and the start time subtracts, in that order, which is
  /// the order After Effects applies them; doing it the other way shifts a
  /// stretched precomp by `startTime * (timeStretch - 1)` frames, an error that
  /// only shows up on files that use both.
  double layerFrame(double frame) {
    final double stretch = timeStretch == 0 ? 1 : timeStretch;
    return (frame - startTime) / stretch;
  }
}

/// A precomposition: a named list of layers another layer can play.
final class LottiePrecomp {
  const LottiePrecomp({
    required this.id,
    required this.layers,
    this.frameRate,
  });

  final String id;
  final List<LottieLayer> layers;

  /// A precomp may declare its own frame rate; when it does not it runs on the
  /// composition's.
  final double? frameRate;
}

/// A parsed Lottie animation, ready to be evaluated at any time.
final class LottieAnimation {
  const LottieAnimation({
    required this.version,
    required this.name,
    required this.frameRate,
    required this.inPoint,
    required this.outPoint,
    required this.width,
    required this.height,
    required this.layers,
    required this.precomps,
    required this.unsupported,
  });

  /// The `v` field, an exporter version like `5.12.1`.
  final String version;
  final String name;

  /// Frames per second the composition was authored at.
  final double frameRate;

  /// First and last frame, from `ip` and `op`.
  final double inPoint;
  final double outPoint;

  /// Composition size in its own coordinates. Everything in the file is in
  /// these; scaling to a widget happens at paint time.
  final double width;
  final double height;

  final List<LottieLayer> layers;
  final Map<String, LottiePrecomp> precomps;

  /// Features present in the file that this implementation does not draw, each
  /// named once.
  ///
  /// **Not an error, and not silence either.** A file using a track matte still
  /// plays, with the matte ignored; what would be unacceptable is for the
  /// difference to be invisible. A player shows this list, and the sample-file
  /// tests assert it is empty for the files that are supposed to be fully
  /// covered.
  final Set<String> unsupported;

  /// How many frames the animation lasts.
  double get durationInFrames => outPoint - inPoint;

  /// How long the animation lasts.
  Duration get duration => Duration(
        microseconds:
            (durationInFrames / frameRate * Duration.microsecondsPerSecond)
                .round(),
      );

  /// The composition frame at [elapsed], looping.
  ///
  /// Looping here rather than in the player because the modulo has to be taken
  /// against [durationInFrames] and then offset by [inPoint], and doing that at
  /// the call site is how an animation ends up playing one frame short or
  /// stuttering at the wrap.
  double frameAt(Duration elapsed, {bool loop = true}) {
    final double frames =
        elapsed.inMicroseconds / Duration.microsecondsPerSecond * frameRate;
    if (!loop) {
      return (inPoint + frames).clamp(inPoint, outPoint);
    }
    final double span = durationInFrames;
    if (span <= 0) return inPoint;
    final double wrapped = frames % span;
    return inPoint + (wrapped < 0 ? wrapped + span : wrapped);
  }

  @override
  String toString() => 'LottieAnimation($name, v$version, '
      '${width.toInt()}x${height.toInt()}, ${frameRate.toStringAsFixed(0)} fps, '
      '${layers.length} layers, ${precomps.length} precomps'
      '${unsupported.isEmpty ? '' : ', unsupported: ${unsupported.join(', ')}'})';
}

/// Degrees to radians, which the transform maths wants and the file never has.
double degreesToRadians(double degrees) => degrees * math.pi / 180;
