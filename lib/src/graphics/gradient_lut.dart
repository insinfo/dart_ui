/// Deterministic colour lookup tables shared by CPU and GPU gradient paths.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'gradient.dart';

/// Default number of texels in a gradient ramp.
///
/// 256 keeps the common upload to one KiB while providing one entry per
/// 8-bit channel step. Sampling linearly between entries mirrors a GPU alpha8
/// or RGBA8 texture configured with linear filtering.
const int kDefaultGradientLutSize = 256;

/// An immutable straight-alpha sRGB ramp suitable for CPU sampling or upload
/// as a one-dimensional GPU texture.
///
/// Entries use the public `0xAARRGGBB` convention. They deliberately remain
/// straight-alpha: interpolation happens before premultiplication on every
/// backend, while conversion to a framebuffer or blend attachment happens at
/// the final pixel boundary.
final class GradientLut {
  GradientLut(
    Gradient gradient, {
    int size = kDefaultGradientLutSize,
  })  : spread = gradient.spread,
        _colorsArgb = Uint32List(size) {
    if (size < 2) {
      throw ArgumentError.value(size, 'size', 'must contain at least 2 texels');
    }
    final last = size - 1;
    for (var i = 0; i < size; i++) {
      _colorsArgb[i] = _sampleStops(gradient, i / last);
    }
  }

  final GradientSpread spread;
  final Uint32List _colorsArgb;

  /// Read-only straight-alpha `0xAARRGGBB` texels.
  late final Uint32List colorsArgb = _colorsArgb.asUnmodifiableView();

  int get size => _colorsArgb.length;

  /// Samples the ramp with the same spread and linear-filtering rules a GPU
  /// texture uses.
  int sampleArgb(double parameter) {
    final double t = _spreadParameter(parameter, spread);
    final double position = t * (_colorsArgb.length - 1);
    final int left = position.floor().clamp(0, _colorsArgb.length - 1);
    final int right = math.min(left + 1, _colorsArgb.length - 1);
    if (left == right) return _colorsArgb[left];
    return _lerpArgb(_colorsArgb[left], _colorsArgb[right], position - left);
  }
}

double _spreadParameter(double value, GradientSpread spread) {
  if (value.isNaN) return 0;
  switch (spread) {
    case GradientSpread.pad:
      if (value == double.negativeInfinity) return 0;
      if (value == double.infinity) return 1;
      return value.clamp(0.0, 1.0);
    case GradientSpread.repeat:
      if (!value.isFinite) return 0;
      return value - value.floorToDouble();
    case GradientSpread.reflect:
      if (!value.isFinite) return 0;
      var repeated = value % 2;
      if (repeated < 0) repeated += 2;
      return repeated <= 1 ? repeated : 2 - repeated;
  }
}

int _sampleStops(Gradient gradient, double t) {
  final offsets = gradient.stopOffsets;
  final colors = gradient.stopColors;
  if (t < offsets.first) return colors.first;

  // Upper-bound search. At a duplicated offset the last stop at that offset
  // wins, producing a deterministic hard edge rather than a division by zero.
  var low = 0;
  var high = offsets.length;
  while (low < high) {
    final middle = (low + high) >> 1;
    if (offsets[middle] <= t) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  final int left = low - 1;
  if (left >= colors.length - 1) return colors.last;
  final int right = left + 1;
  final double width = offsets[right] - offsets[left];
  if (width <= 0) return colors[right];
  return _lerpArgb(colors[left], colors[right], (t - offsets[left]) / width);
}

int _lerpArgb(int start, int end, double t) {
  int channel(int shift) {
    final int a = (start >> shift) & 0xFF;
    final int b = (end >> shift) & 0xFF;
    return (a + (b - a) * t).round().clamp(0, 255);
  }

  return (channel(24) << 24) |
      (channel(16) << 16) |
      (channel(8) << 8) |
      channel(0);
}
