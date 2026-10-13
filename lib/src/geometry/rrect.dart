// Portions of this file are adapted from Flutter's `dart:ui` (`geometry.dart`):
//
// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// [Radius] and [RRect], with Flutter's names, constructors and semantics.
///
/// These are the value types a Flutter app hands to `BorderRadius`,
/// `ClipRRect`, `Canvas.drawRRect` and `CustomClipper<RRect>`. The display
/// list still takes twelve primitive doubles for a rounded rectangle
/// (`DisplayList.drawRRect`), on purpose: an [RRect] is what a caller *thinks*
/// in, and the encoder is where it is unpacked.
///
/// ## Differences from Flutter
///
/// * Negative radii are rejected by an `assert`, as in Flutter, because the
///   constructors are `const`; in release a negative radius is drawn as a
///   right angle by `PathBuilder`, never as a self-crossing outline.
/// * There is no `RSuperellipse`.
library;

import 'dart:math' as math;

import 'offset.dart';
import 'rect.dart';

double _lerp(double a, double b, double t) => a * (1.0 - t) + b * t;

double _clamp(double x, double min, double max) =>
    x < min ? min : (x > max ? max : (x.isNaN ? max : x));

/// A radius for either circular or elliptical shapes.
final class Radius {
  /// Constructs a circular radius. [x] and [y] will have the same radius value.
  const Radius.circular(double radius) : this.elliptical(radius, radius);

  /// Constructs an elliptical radius with the given radii.
  const Radius.elliptical(this.x, this.y);

  /// The radius value on the horizontal axis.
  final double x;

  /// The radius value on the vertical axis.
  final double y;

  /// A radius with [x] and [y] values set to zero.
  static const Radius zero = Radius.circular(0.0);

  /// Returns this [Radius], with values clamped to the given min and max
  /// [Radius] values.
  Radius clamp({Radius? minimum, Radius? maximum}) {
    minimum ??= const Radius.circular(-double.infinity);
    maximum ??= const Radius.circular(double.infinity);
    return Radius.elliptical(
      _clamp(x, minimum.x, maximum.x),
      _clamp(y, minimum.y, maximum.y),
    );
  }

  /// Returns this [Radius], with values clamped to the given min and max
  /// values in each dimension.
  Radius clampValues({
    double? minimumX,
    double? minimumY,
    double? maximumX,
    double? maximumY,
  }) {
    return Radius.elliptical(
      _clamp(x, minimumX ?? -double.infinity, maximumX ?? double.infinity),
      _clamp(y, minimumY ?? -double.infinity, maximumY ?? double.infinity),
    );
  }

  Radius operator -() => Radius.elliptical(-x, -y);

  Radius operator -(Radius other) =>
      Radius.elliptical(x - other.x, y - other.y);

  Radius operator +(Radius other) =>
      Radius.elliptical(x + other.x, y + other.y);

  Radius operator *(double operand) =>
      Radius.elliptical(x * operand, y * operand);

  Radius operator /(double operand) =>
      Radius.elliptical(x / operand, y / operand);

  Radius operator ~/(double operand) =>
      Radius.elliptical((x ~/ operand).toDouble(), (y ~/ operand).toDouble());

  Radius operator %(double operand) =>
      Radius.elliptical(x % operand, y % operand);

  /// Linearly interpolate between two radii. A null end is [Radius.zero].
  static Radius? lerp(Radius? a, Radius? b, double t) {
    if (b == null) {
      if (a == null) return null;
      final double k = 1.0 - t;
      return Radius.elliptical(a.x * k, a.y * k);
    }
    if (a == null) return Radius.elliptical(b.x * t, b.y * t);
    return Radius.elliptical(_lerp(a.x, b.x, t), _lerp(a.y, b.y, t));
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Radius && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => x == y
      ? 'Radius.circular(${x.toStringAsFixed(1)})'
      : 'Radius.elliptical(${x.toStringAsFixed(1)}, ${y.toStringAsFixed(1)})';
}

/// An immutable rounded rectangle with custom radii for all four corners.
final class RRect {
  /// A rounded rectangle from its edges and the same radii along its
  /// horizontal axis and its vertical axis.
  const RRect.fromLTRBXY(
    double left,
    double top,
    double right,
    double bottom,
    double radiusX,
    double radiusY,
  ) : this._raw(
          top: top,
          left: left,
          right: right,
          bottom: bottom,
          tlRadiusX: radiusX,
          tlRadiusY: radiusY,
          trRadiusX: radiusX,
          trRadiusY: radiusY,
          blRadiusX: radiusX,
          blRadiusY: radiusY,
          brRadiusX: radiusX,
          brRadiusY: radiusY,
        );

  /// A rounded rectangle from its edges and the same radius in each corner.
  RRect.fromLTRBR(
    double left,
    double top,
    double right,
    double bottom,
    Radius radius,
  ) : this.fromLTRBXY(left, top, right, bottom, radius.x, radius.y);

  /// A rounded rectangle from its bounding box and the same radii along its
  /// horizontal axis and its vertical axis.
  RRect.fromRectXY(Rect rect, double radiusX, double radiusY)
      : this.fromLTRBXY(
          rect.left,
          rect.top,
          rect.right,
          rect.bottom,
          radiusX,
          radiusY,
        );

  /// A rounded rectangle from its bounding box and a radius that is the same
  /// in each corner.
  RRect.fromRectAndRadius(Rect rect, Radius radius)
      : this.fromLTRBXY(
          rect.left,
          rect.top,
          rect.right,
          rect.bottom,
          radius.x,
          radius.y,
        );

  /// A rounded rectangle from its edges and one radius per corner. The
  /// corners default to [Radius.zero], a right angle.
  RRect.fromLTRBAndCorners(
    double left,
    double top,
    double right,
    double bottom, {
    Radius topLeft = Radius.zero,
    Radius topRight = Radius.zero,
    Radius bottomRight = Radius.zero,
    Radius bottomLeft = Radius.zero,
  }) : this._raw(
          top: top,
          left: left,
          right: right,
          bottom: bottom,
          tlRadiusX: topLeft.x,
          tlRadiusY: topLeft.y,
          trRadiusX: topRight.x,
          trRadiusY: topRight.y,
          blRadiusX: bottomLeft.x,
          blRadiusY: bottomLeft.y,
          brRadiusX: bottomRight.x,
          brRadiusY: bottomRight.y,
        );

  /// A rounded rectangle from its bounding box and one radius per corner.
  RRect.fromRectAndCorners(
    Rect rect, {
    Radius topLeft = Radius.zero,
    Radius topRight = Radius.zero,
    Radius bottomRight = Radius.zero,
    Radius bottomLeft = Radius.zero,
  }) : this.fromLTRBAndCorners(
          rect.left,
          rect.top,
          rect.right,
          rect.bottom,
          topLeft: topLeft,
          topRight: topRight,
          bottomRight: bottomRight,
          bottomLeft: bottomLeft,
        );

  const RRect._raw({
    this.left = 0.0,
    this.top = 0.0,
    this.right = 0.0,
    this.bottom = 0.0,
    this.tlRadiusX = 0.0,
    this.tlRadiusY = 0.0,
    this.trRadiusX = 0.0,
    this.trRadiusY = 0.0,
    this.brRadiusX = 0.0,
    this.brRadiusY = 0.0,
    this.blRadiusX = 0.0,
    this.blRadiusY = 0.0,
  })  : assert(tlRadiusX >= 0),
        assert(tlRadiusY >= 0),
        assert(trRadiusX >= 0),
        assert(trRadiusY >= 0),
        assert(brRadiusX >= 0),
        assert(brRadiusY >= 0),
        assert(blRadiusX >= 0),
        assert(blRadiusY >= 0);

  /// A rounded rectangle with all the values set to zero.
  static const RRect zero = RRect._raw();

  final double left;
  final double top;
  final double right;
  final double bottom;
  final double tlRadiusX;
  final double tlRadiusY;
  final double trRadiusX;
  final double trRadiusY;
  final double brRadiusX;
  final double brRadiusY;
  final double blRadiusX;
  final double blRadiusY;

  Radius get tlRadius => Radius.elliptical(tlRadiusX, tlRadiusY);
  Radius get trRadius => Radius.elliptical(trRadiusX, trRadiusY);
  Radius get brRadius => Radius.elliptical(brRadiusX, brRadiusY);
  Radius get blRadius => Radius.elliptical(blRadiusX, blRadiusY);

  RRect _copy({
    required double left,
    required double top,
    required double right,
    required double bottom,
    required double tlRadiusX,
    required double tlRadiusY,
    required double trRadiusX,
    required double trRadiusY,
    required double brRadiusX,
    required double brRadiusY,
    required double blRadiusX,
    required double blRadiusY,
  }) =>
      RRect._raw(
        left: left,
        top: top,
        right: right,
        bottom: bottom,
        tlRadiusX: tlRadiusX,
        tlRadiusY: tlRadiusY,
        trRadiusX: trRadiusX,
        trRadiusY: trRadiusY,
        brRadiusX: brRadiusX,
        brRadiusY: brRadiusY,
        blRadiusX: blRadiusX,
        blRadiusY: blRadiusY,
      );

  /// A copy translated by [offset].
  RRect shift(Offset offset) => _copy(
        left: left + offset.dx,
        top: top + offset.dy,
        right: right + offset.dx,
        bottom: bottom + offset.dy,
        tlRadiusX: tlRadiusX,
        tlRadiusY: tlRadiusY,
        trRadiusX: trRadiusX,
        trRadiusY: trRadiusY,
        brRadiusX: brRadiusX,
        brRadiusY: brRadiusY,
        blRadiusX: blRadiusX,
        blRadiusY: blRadiusY,
      );

  /// A copy with edges and radii moved outwards by [delta]. Radii stop at
  /// zero rather than going negative.
  RRect inflate(double delta) => _copy(
        left: left - delta,
        top: top - delta,
        right: right + delta,
        bottom: bottom + delta,
        tlRadiusX: math.max(0, tlRadiusX + delta),
        tlRadiusY: math.max(0, tlRadiusY + delta),
        trRadiusX: math.max(0, trRadiusX + delta),
        trRadiusY: math.max(0, trRadiusY + delta),
        brRadiusX: math.max(0, brRadiusX + delta),
        brRadiusY: math.max(0, brRadiusY + delta),
        blRadiusX: math.max(0, blRadiusX + delta),
        blRadiusY: math.max(0, blRadiusY + delta),
      );

  /// A copy with edges and radii moved inwards by [delta].
  RRect deflate(double delta) => inflate(-delta);

  double get width => right - left;

  double get height => bottom - top;

  /// The bounding box, without the rounding.
  Rect get outerRect => Rect.fromLTRB(left, top, right, bottom);

  /// The rectangle bounded by the middle of each corner's curve: everything
  /// inside it is inside the rounded rectangle whatever the radii.
  Rect get safeInnerRect {
    const double kInsetFactor = 0.29289321881; // 1 - cos(pi / 4)
    final double leftRadius = math.max(blRadiusX, tlRadiusX);
    final double topRadius = math.max(tlRadiusY, trRadiusY);
    final double rightRadius = math.max(trRadiusX, brRadiusX);
    final double bottomRadius = math.max(brRadiusY, blRadiusY);
    return Rect.fromLTRB(
      left + leftRadius * kInsetFactor,
      top + topRadius * kInsetFactor,
      right - rightRadius * kInsetFactor,
      bottom - bottomRadius * kInsetFactor,
    );
  }

  /// The rectangle formed by the inner-most centres of the corner ellipses.
  Rect get middleRect {
    final double leftRadius = math.max(blRadiusX, tlRadiusX);
    final double topRadius = math.max(tlRadiusY, trRadiusY);
    final double rightRadius = math.max(trRadiusX, brRadiusX);
    final double bottomRadius = math.max(brRadiusY, blRadiusY);
    return Rect.fromLTRB(
      left + leftRadius,
      top + topRadius,
      right - rightRadius,
      bottom - bottomRadius,
    );
  }

  /// The biggest full-width rectangle inside the rounded rectangle.
  Rect get wideMiddleRect {
    final double topRadius = math.max(tlRadiusY, trRadiusY);
    final double bottomRadius = math.max(brRadiusY, blRadiusY);
    return Rect.fromLTRB(left, top + topRadius, right, bottom - bottomRadius);
  }

  /// The biggest full-height rectangle inside the rounded rectangle.
  Rect get tallMiddleRect {
    final double leftRadius = math.max(blRadiusX, tlRadiusX);
    final double rightRadius = math.max(trRadiusX, brRadiusX);
    return Rect.fromLTRB(left + leftRadius, top, right - rightRadius, bottom);
  }

  /// Whether this encloses no area. Negative areas are empty.
  bool get isEmpty => left >= right || top >= bottom;

  bool get isFinite =>
      left.isFinite && top.isFinite && right.isFinite && bottom.isFinite;

  /// Whether every corner is a right angle.
  bool get isRect =>
      (tlRadiusX == 0.0 || tlRadiusY == 0.0) &&
      (trRadiusX == 0.0 || trRadiusY == 0.0) &&
      (blRadiusX == 0.0 || blRadiusY == 0.0) &&
      (brRadiusX == 0.0 || brRadiusY == 0.0);

  /// Whether a side has no straight section.
  bool get isStadium =>
      tlRadius == trRadius &&
      trRadius == brRadius &&
      brRadius == blRadius &&
      (width <= 2.0 * tlRadiusX || height <= 2.0 * tlRadiusY);

  /// Whether no side has a straight section.
  bool get isEllipse =>
      tlRadius == trRadius &&
      trRadius == brRadius &&
      brRadius == blRadius &&
      width <= 2.0 * tlRadiusX &&
      height <= 2.0 * tlRadiusY;

  bool get isCircle => width == height && isEllipse;

  double get shortestSide => math.min(width.abs(), height.abs());

  double get longestSide => math.max(width.abs(), height.abs());

  bool get hasNaN =>
      left.isNaN ||
      top.isNaN ||
      right.isNaN ||
      bottom.isNaN ||
      trRadiusX.isNaN ||
      trRadiusY.isNaN ||
      tlRadiusX.isNaN ||
      tlRadiusY.isNaN ||
      brRadiusX.isNaN ||
      brRadiusY.isNaN ||
      blRadiusX.isNaN ||
      blRadiusY.isNaN;

  Offset get center => Offset(left + width / 2.0, top + height / 2.0);

  static double _getMin(
      double min, double radius1, double radius2, double limit) {
    final double sum = radius1 + radius2;
    if (sum > limit && sum != 0.0) return math.min(min, limit / sum);
    return min;
  }

  /// Scales all radii by one factor so that on each side their sum does not
  /// exceed the side - the CSS rule, which is also what `PathBuilder` and
  /// every rasterizer here apply when drawing.
  RRect scaleRadii() {
    var scale = 1.0;
    scale = _getMin(scale, blRadiusY, tlRadiusY, height);
    scale = _getMin(scale, tlRadiusX, trRadiusX, width);
    scale = _getMin(scale, trRadiusY, brRadiusY, height);
    scale = _getMin(scale, brRadiusX, blRadiusX, width);
    if (scale >= 1.0) return this;
    return _copy(
      left: left,
      top: top,
      right: right,
      bottom: bottom,
      tlRadiusX: tlRadiusX * scale,
      tlRadiusY: tlRadiusY * scale,
      trRadiusX: trRadiusX * scale,
      trRadiusY: trRadiusY * scale,
      brRadiusX: brRadiusX * scale,
      brRadiusY: brRadiusY * scale,
      blRadiusX: blRadiusX * scale,
      blRadiusY: blRadiusY * scale,
    );
  }

  /// Whether [point] lies inside the rounded rectangle.
  ///
  /// Right and bottom edges are exclusive, as in Flutter. Radii that overrun
  /// their side are scaled down first, by [scaleRadii].
  bool contains(Offset point) {
    if (point.dx < left ||
        point.dx >= right ||
        point.dy < top ||
        point.dy >= bottom) {
      return false;
    }
    final RRect scaled = scaleRadii();
    double x;
    double y;
    double radiusX;
    double radiusY;
    if (point.dx < left + scaled.tlRadiusX &&
        point.dy < top + scaled.tlRadiusY) {
      x = point.dx - left - scaled.tlRadiusX;
      y = point.dy - top - scaled.tlRadiusY;
      radiusX = scaled.tlRadiusX;
      radiusY = scaled.tlRadiusY;
    } else if (point.dx > right - scaled.trRadiusX &&
        point.dy < top + scaled.trRadiusY) {
      x = point.dx - right + scaled.trRadiusX;
      y = point.dy - top - scaled.trRadiusY;
      radiusX = scaled.trRadiusX;
      radiusY = scaled.trRadiusY;
    } else if (point.dx > right - scaled.brRadiusX &&
        point.dy > bottom - scaled.brRadiusY) {
      x = point.dx - right + scaled.brRadiusX;
      y = point.dy - bottom + scaled.brRadiusY;
      radiusX = scaled.brRadiusX;
      radiusY = scaled.brRadiusY;
    } else if (point.dx < left + scaled.blRadiusX &&
        point.dy > bottom - scaled.blRadiusY) {
      x = point.dx - left - scaled.blRadiusX;
      y = point.dy - bottom + scaled.blRadiusY;
      radiusX = scaled.blRadiusX;
      radiusY = scaled.blRadiusY;
    } else {
      return true;
    }
    x = x / radiusX;
    y = y / radiusY;
    return x * x + y * y <= 1.0;
  }

  /// Linearly interpolate between two rounded rectangles. A null end is
  /// [RRect.zero].
  static RRect? lerp(RRect? a, RRect? b, double t) {
    if (a == null) {
      if (b == null) return null;
      return b._lerpTo(null, 1 - t);
    }
    return a._lerpTo(b, t);
  }

  RRect _lerpTo(RRect? b, double t) {
    if (b == null) {
      final double k = 1.0 - t;
      return _copy(
        left: left * k,
        top: top * k,
        right: right * k,
        bottom: bottom * k,
        tlRadiusX: math.max(0, tlRadiusX * k),
        tlRadiusY: math.max(0, tlRadiusY * k),
        trRadiusX: math.max(0, trRadiusX * k),
        trRadiusY: math.max(0, trRadiusY * k),
        brRadiusX: math.max(0, brRadiusX * k),
        brRadiusY: math.max(0, brRadiusY * k),
        blRadiusX: math.max(0, blRadiusX * k),
        blRadiusY: math.max(0, blRadiusY * k),
      );
    }
    return _copy(
      left: _lerp(left, b.left, t),
      top: _lerp(top, b.top, t),
      right: _lerp(right, b.right, t),
      bottom: _lerp(bottom, b.bottom, t),
      tlRadiusX: math.max(0, _lerp(tlRadiusX, b.tlRadiusX, t)),
      tlRadiusY: math.max(0, _lerp(tlRadiusY, b.tlRadiusY, t)),
      trRadiusX: math.max(0, _lerp(trRadiusX, b.trRadiusX, t)),
      trRadiusY: math.max(0, _lerp(trRadiusY, b.trRadiusY, t)),
      brRadiusX: math.max(0, _lerp(brRadiusX, b.brRadiusX, t)),
      brRadiusY: math.max(0, _lerp(brRadiusY, b.brRadiusY, t)),
      blRadiusX: math.max(0, _lerp(blRadiusX, b.blRadiusX, t)),
      blRadiusY: math.max(0, _lerp(blRadiusY, b.blRadiusY, t)),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RRect &&
          other.left == left &&
          other.top == top &&
          other.right == right &&
          other.bottom == bottom &&
          other.tlRadiusX == tlRadiusX &&
          other.tlRadiusY == tlRadiusY &&
          other.trRadiusX == trRadiusX &&
          other.trRadiusY == trRadiusY &&
          other.blRadiusX == blRadiusX &&
          other.blRadiusY == blRadiusY &&
          other.brRadiusX == brRadiusX &&
          other.brRadiusY == brRadiusY;

  @override
  int get hashCode => Object.hash(
        left,
        top,
        right,
        bottom,
        tlRadiusX,
        tlRadiusY,
        trRadiusX,
        trRadiusY,
        blRadiusX,
        blRadiusY,
        brRadiusX,
        brRadiusY,
      );

  @override
  String toString() {
    final String rect = '${left.toStringAsFixed(1)}, '
        '${top.toStringAsFixed(1)}, '
        '${right.toStringAsFixed(1)}, '
        '${bottom.toStringAsFixed(1)}';
    if (tlRadius == trRadius && trRadius == brRadius && brRadius == blRadius) {
      if (tlRadius.x == tlRadius.y) {
        return 'RRect.fromLTRBR($rect, ${tlRadius.x.toStringAsFixed(1)})';
      }
      return 'RRect.fromLTRBXY($rect, ${tlRadius.x.toStringAsFixed(1)}, '
          '${tlRadius.y.toStringAsFixed(1)})';
    }
    return 'RRect.fromLTRBAndCorners($rect, topLeft: $tlRadius, '
        'topRight: $trRadius, bottomRight: $brRadius, '
        'bottomLeft: $blRadius)';
  }
}
