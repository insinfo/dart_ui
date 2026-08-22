/// Gradient paints: the value types a display-list producer describes a
/// linear or radial ramp with.
///
/// ## Where a gradient lives in the wire format
///
/// A paint record stays two words and one float - see `DisplayList.addPaint` -
/// and a gradient does not widen it. The flag word gains a *shader kind* in
/// bits 4..5 and, for a non-solid kind, a gradient id in bits 16..31 that
/// indexes the display list's gradient table. The table itself holds these
/// objects, interned by value exactly as paints are: two draws describing the
/// same ramp share one id, and the solid-colour path pays one null check and
/// nothing else.
///
/// Objects rather than flat arrays, deliberately: paints are flat because the
/// encoder writes thousands per frame on the hottest path there is, while a
/// frame has a handful of gradients and each is interned once. This is the
/// same trade the path, image and font tables already made.
///
/// ## Coordinate space
///
/// Gradient geometry is written in the same coordinate space as the command
/// that uses the paint - the space `drawRect` coordinates are in before the
/// replay transform. The player maps it to device space with the transform in
/// force at each draw, so a gradient translated or scaled with its shape
/// stays glued to it. Under skew or non-uniform scale a radial gradient's
/// circle is approximated by scaling its radius with the average axis length,
/// the same class of approximation the replay layer documents for rounded
/// rectangle radii.
///
/// ## Interpolation, stated once for every backend
///
/// Colours are interpolated **channel-wise on the straight (non-premultiplied)
/// sRGB values**, then premultiplied at the edge that needs it. That is what
/// the CPU shader computes, what a GPU `mix()` of straight colours computes,
/// and what Direct2D's `D2D1_GAMMA_2_2` collection specifies - the encoded
/// values are interpolated as they are, with no linearisation. With opaque
/// stops every backend agrees to rounding; with translucent stops Direct2D
/// may interpolate premultiplied and differ in the low bits, which the
/// differential tolerance absorbs and this comment records.
library;

import 'dart:typed_data';

/// How a gradient continues outside the 0..1 range of its stops.
enum GradientSpread {
  /// The edge stop extends forever. `D2D1_EXTEND_MODE_CLAMP`.
  pad,

  /// The ramp tiles: t wraps modulo 1. `D2D1_EXTEND_MODE_WRAP`.
  repeat,

  /// The ramp mirrors on every repetition. `D2D1_EXTEND_MODE_MIRROR`.
  reflect,
}

/// Shader kind values stored in bits 4..5 of a paint's flag word.
const int shaderKindSolid = 0;
const int shaderKindLinear = 1;
const int shaderKindRadial = 2;

/// The most gradients one display list can intern: the paint flag word gives
/// the id 16 bits. A frame that reaches this is generating gradients in a
/// loop, and the error names the limit rather than wrapping the id.
const int kMaxGradientsPerList = 0x10000;

/// One colour stop: an offset in 0..1 and a straight-alpha `0xAARRGGBB`.
final class GradientStop {
  const GradientStop(this.offset, this.colorArgb);

  final double offset;
  final int colorArgb;

  @override
  bool operator ==(Object other) =>
      other is GradientStop &&
      other.offset == offset &&
      other.colorArgb == colorArgb;

  @override
  int get hashCode => Object.hash(offset, colorArgb);

  @override
  String toString() =>
      '($offset: 0x${colorArgb.toRadixString(16).padLeft(8, '0')})';
}

/// A gradient paint description, interned by value in the display list.
///
/// Immutable; the stop lists are copied into typed arrays at construction so
/// a renderer can read them without touching caller-owned lists, and so the
/// value equality the intern table relies on is over exactly the stored
/// (float32-narrowed) values - the same rule paint dedup follows.
///
/// When a paint carries a gradient, the paint's own colour is **not
/// sampled**: the stop colours carry the alpha. This is stated here once and
/// every backend follows it, which is what keeps a differential test able to
/// compare them.
sealed class Gradient {
  Gradient._(List<GradientStop> stops, this.spread)
      : _stopOffsets = Float32List(stops.length),
        _stopColors = Uint32List(stops.length) {
    if (stops.length < 2) {
      throw ArgumentError.value(
          stops.length, 'stops', 'a gradient needs at least two stops');
    }
    var previous = double.negativeInfinity;
    for (var i = 0; i < stops.length; i++) {
      final double offset = stops[i].offset;
      if (offset.isNaN || offset < 0 || offset > 1) {
        throw ArgumentError.value(
            offset, 'stops', 'stop offsets must be in 0..1');
      }
      if (offset < previous) {
        throw ArgumentError.value(
            offset, 'stops', 'stop offsets must be non-decreasing');
      }
      previous = offset;
      _stopOffsets[i] = offset;
      _stopColors[i] = stops[i].colorArgb & 0xFFFFFFFF;
    }
  }

  final GradientSpread spread;

  /// Stop offsets, narrowed to float32 - the stored truth equality runs over.
  final Float32List _stopOffsets;

  /// Read-only view; mutating caller-owned stops can never invalidate the
  /// display list's value-interning map.
  late final Float32List stopOffsets = _stopOffsets.asUnmodifiableView();

  /// Straight-alpha `0xAARRGGBB` per stop.
  final Uint32List _stopColors;

  /// Read-only view of the stored straight-alpha colours.
  late final Uint32List stopColors = _stopColors.asUnmodifiableView();

  int get stopCount => stopOffsets.length;

  /// The wire value for bits 4..5 of the paint flag word.
  int get shaderKind;

  /// The geometry as the renderers consume it; length and meaning depend on
  /// the subtype. Exposed so replay code reads one shape instead of two.
  List<double> get geometry;

  bool _sameStops(Gradient other) {
    if (other.spread != spread) return false;
    if (other.stopOffsets.length != stopOffsets.length) return false;
    for (var i = 0; i < stopOffsets.length; i++) {
      if (other.stopOffsets[i] != stopOffsets[i]) return false;
      if (other.stopColors[i] != stopColors[i]) return false;
    }
    return true;
  }

  int _stopsHash() {
    var hash = spread.index;
    for (var i = 0; i < stopOffsets.length; i++) {
      hash = Object.hash(hash, stopOffsets[i], stopColors[i]);
    }
    return hash;
  }

  String _describeStops() {
    final buffer = StringBuffer();
    for (var i = 0; i < stopOffsets.length; i++) {
      if (i > 0) buffer.write(', ');
      buffer.write(GradientStop(stopOffsets[i], stopColors[i]));
    }
    return buffer.toString();
  }
}

/// A linear ramp from ([startX], [startY]) to ([endX], [endY]).
final class LinearGradient extends Gradient {
  LinearGradient({
    required double startX,
    required double startY,
    required double endX,
    required double endY,
    required List<GradientStop> stops,
    GradientSpread spread = GradientSpread.pad,
  })  : _geometry = Float32List(4),
        super._(stops, spread) {
    if (!startX.isFinite ||
        !startY.isFinite ||
        !endX.isFinite ||
        !endY.isFinite) {
      throw ArgumentError('linear gradient coordinates must be finite');
    }
    _geometry[0] = startX;
    _geometry[1] = startY;
    _geometry[2] = endX;
    _geometry[3] = endY;
  }

  final Float32List _geometry;
  late final Float32List _geometryView = _geometry.asUnmodifiableView();

  double get startX => _geometry[0];
  double get startY => _geometry[1];
  double get endX => _geometry[2];
  double get endY => _geometry[3];

  @override
  int get shaderKind => shaderKindLinear;

  @override
  List<double> get geometry => _geometryView;

  @override
  bool operator ==(Object other) =>
      other is LinearGradient &&
      other._geometry[0] == _geometry[0] &&
      other._geometry[1] == _geometry[1] &&
      other._geometry[2] == _geometry[2] &&
      other._geometry[3] == _geometry[3] &&
      other._sameStops(this);

  @override
  int get hashCode =>
      Object.hash(LinearGradient, startX, startY, endX, endY, _stopsHash());

  @override
  String toString() => 'LinearGradient(($startX, $startY) -> ($endX, $endY), '
      '${spread.name}, [${_describeStops()}])';
}

/// A radial ramp out of ([centerX], [centerY]) to [radius].
///
/// [focusX]/[focusY] optionally place the t = 0 point off-centre, the
/// `gradientOriginOffset` of Direct2D and the focal point of an SVG radial
/// gradient. They default to the centre.
final class RadialGradient extends Gradient {
  RadialGradient({
    required double centerX,
    required double centerY,
    required double radius,
    double? focusX,
    double? focusY,
    required List<GradientStop> stops,
    GradientSpread spread = GradientSpread.pad,
  })  : _geometry = Float32List(5),
        super._(stops, spread) {
    final resolvedFocusX = focusX ?? centerX;
    final resolvedFocusY = focusY ?? centerY;
    if (!centerX.isFinite ||
        !centerY.isFinite ||
        !resolvedFocusX.isFinite ||
        !resolvedFocusY.isFinite) {
      throw ArgumentError('radial gradient coordinates must be finite');
    }
    if (!radius.isFinite || radius <= 0) {
      throw ArgumentError.value(radius, 'radius', 'must be finite and > 0');
    }
    _geometry[0] = centerX;
    _geometry[1] = centerY;
    _geometry[2] = radius;
    _geometry[3] = resolvedFocusX;
    _geometry[4] = resolvedFocusY;
  }

  final Float32List _geometry;
  late final Float32List _geometryView = _geometry.asUnmodifiableView();

  double get centerX => _geometry[0];
  double get centerY => _geometry[1];
  double get radius => _geometry[2];
  double get focusX => _geometry[3];
  double get focusY => _geometry[4];

  bool get hasFocus => focusX != centerX || focusY != centerY;

  @override
  int get shaderKind => shaderKindRadial;

  @override
  List<double> get geometry => _geometryView;

  @override
  bool operator ==(Object other) =>
      other is RadialGradient &&
      other._geometry[0] == _geometry[0] &&
      other._geometry[1] == _geometry[1] &&
      other._geometry[2] == _geometry[2] &&
      other._geometry[3] == _geometry[3] &&
      other._geometry[4] == _geometry[4] &&
      other._sameStops(this);

  @override
  int get hashCode => Object.hash(
      RadialGradient, centerX, centerY, radius, focusX, focusY, _stopsHash());

  @override
  String toString() => 'RadialGradient(($centerX, $centerY) r $radius'
      '${hasFocus ? ', focus ($focusX, $focusY)' : ''}, '
      '${spread.name}, [${_describeStops()}])';
}
