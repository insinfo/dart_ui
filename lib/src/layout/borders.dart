// Portions of this file are adapted from Flutter's `painting/borders.dart`,
// `painting/box_border.dart`, `painting/rounded_rectangle_border.dart`,
// `painting/circle_border.dart` and `painting/stadium_border.dart`:
//
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Borders with Flutter's names: [BorderSide], [Border],
/// [BorderDirectional], and the [ShapeBorder]s a `ShapeDecoration`,
/// `ClipPath.shape` or a `Card` take - [RoundedRectangleBorder],
/// [CircleBorder], [StadiumBorder].
///
/// They paint through the [Canvas] facade, exactly as Flutter's do, so a
/// border that looks right there looks the same here.
///
/// ## The framework's own `BoxBorder(color:, width:)`
///
/// Before these existed the framework had one border: `BoxBorder` with a
/// colour and a width, drawn inside the box. That constructor still works and
/// means what it meant - a uniform inside border, the same picture as
/// `Border.all(color: c, width: w)` - and it is why [BoxBorder] here is a
/// concrete class with `color` and `width`, where Flutter's is abstract. A
/// Flutter subclass of `BoxBorder` still compiles: every parameter of the
/// constructor is optional.
///
/// ## Differences from Flutter
///
///   * A border whose sides differ in colour cannot have a radius in Flutter
///     (an assertion); here the radius is ignored and the sides are painted
///     as straight trapezoids.
///   * [ShapeBorder.operator +] combines only borders whose [ShapeBorder.add]
///     agrees (two [Border]s, for instance); there is no compound border, so
///     anything else is an [ArgumentError].
///   * There is no `BeveledRectangleBorder`, `ContinuousRectangleBorder`,
///     `StarBorder`, `OvalBorder` or `LinearBorder`.
library;

import 'dart:math' as math;

import '../geometry/offset.dart';
import '../geometry/path.dart';
import '../geometry/rect.dart';
import '../geometry/rrect.dart';
import '../geometry/size.dart';
import '../graphics/color.dart';
import '../text/shaper.dart' show TextDirection;
import 'border_radius.dart';
import 'canvas.dart';
import 'custom_painter.dart';
import 'edge_insets.dart';

double _lerpDouble(double a, double b, double t) => a + (b - a) * t;

double _shortestSide(Rect rect) =>
    math.min(rect.width.abs(), rect.height.abs());

Rect _circleIn(Rect rect) {
  final double r = _shortestSide(rect) / 2;
  final Offset c = rect.center;
  return Rect.fromLTRB(c.dx - r, c.dy - r, c.dx + r, c.dy + r);
}

/// Whether a border side is drawn - Flutter's `BorderStyle`.
enum BorderStyle {
  /// Skip the border.
  none,

  /// Draw the border as a solid line.
  solid,
}

/// The shape a [BoxDecoration] fills - Flutter's `BoxShape`.
enum BoxShape {
  rectangle,

  /// A circle centred in the box, with the box's shorter side as diameter.
  circle,
}

// ---------------------------------------------------------------------------
// BorderSide
// ---------------------------------------------------------------------------

/// A side of a border of a box - Flutter's `BorderSide`.
///
/// Also the line type of `TableBorder`, which predates the rest of this file.
final class BorderSide {
  const BorderSide({
    this.color = const Color(0xFF000000),
    this.width = 1.0,
    this.style = BorderStyle.solid,
    this.strokeAlign = strokeAlignInside,
  });

  /// A hairline black border that is not rendered.
  static const BorderSide none =
      BorderSide(width: 0.0, style: BorderStyle.none);

  /// The border is drawn fully inside the box. The default.
  static const double strokeAlignInside = -1.0;

  /// The border is drawn on the edge, half in and half out.
  static const double strokeAlignCenter = 0.0;

  /// The border is drawn fully outside the box.
  static const double strokeAlignOutside = 1.0;

  final Color color;

  /// The logical width; zero is a hairline.
  final double width;

  final BorderStyle style;

  /// Where the stroke sits relative to the edge, from -1 (inside) to 1
  /// (outside).
  final double strokeAlign;

  /// Whether this side draws anything. A framework convenience: `style` is
  /// not [BorderStyle.none] and the width is positive.
  bool get isVisible => style != BorderStyle.none && width > 0;

  /// How far the stroke reaches inside the edge.
  double get strokeInset => width * (1 - (1 + strokeAlign) / 2);

  /// How far the stroke reaches outside the edge.
  double get strokeOutset => width * (1 + strokeAlign) / 2;

  /// The offset of the stroke's centre line from the edge.
  double get strokeOffset => width * strokeAlign;

  /// Whether [a] and [b] can be combined with [merge].
  static bool canMerge(BorderSide a, BorderSide b) {
    if ((a.style == BorderStyle.none && a.width == 0.0) ||
        (b.style == BorderStyle.none && b.width == 0.0)) {
      return true;
    }
    return a.style == b.style && a.color == b.color;
  }

  /// A side as wide as [a] and [b] together. They must be [canMerge]able.
  static BorderSide merge(BorderSide a, BorderSide b) {
    if (!canMerge(a, b)) {
      throw ArgumentError('BorderSide.merge needs sides of the same style '
          'and colour (or one of them none): $a, $b');
    }
    final bool aIsNone = a.style == BorderStyle.none && a.width == 0.0;
    final bool bIsNone = b.style == BorderStyle.none && b.width == 0.0;
    if (aIsNone && bIsNone) return BorderSide.none;
    if (aIsNone) return b;
    if (bIsNone) return a;
    return BorderSide(
      color: a.color,
      width: a.width + b.width,
      strokeAlign: math.max(a.strokeAlign, b.strokeAlign),
      style: a.style,
    );
  }

  BorderSide copyWith({
    Color? color,
    double? width,
    BorderStyle? style,
    double? strokeAlign,
  }) =>
      BorderSide(
        color: color ?? this.color,
        width: width ?? this.width,
        style: style ?? this.style,
        strokeAlign: strokeAlign ?? this.strokeAlign,
      );

  /// This side with its width scaled by [t]; a non-positive [t] hides it.
  BorderSide scale(double t) => BorderSide(
        color: color,
        width: math.max(0.0, width * t),
        style: t <= 0.0 ? BorderStyle.none : style,
        strokeAlign: strokeAlign,
      );

  /// The paint Flutter strokes this side with.
  Paint toPaint() => switch (style) {
        BorderStyle.solid => Paint()
          ..color = color
          ..strokeWidth = width
          ..style = PaintingStyle.stroke,
        BorderStyle.none => Paint()
          ..color = const Color(0x00000000)
          ..strokeWidth = 0.0
          ..style = PaintingStyle.stroke,
      };

  static BorderSide lerp(BorderSide a, BorderSide b, double t) {
    if (identical(a, b) || t == 0.0) return a;
    if (t == 1.0) return b;
    final double width = _lerpDouble(a.width, b.width, t);
    if (width < 0.0) return BorderSide.none;
    if (a.style == b.style && a.strokeAlign == b.strokeAlign) {
      return BorderSide(
        color: Color.lerp(a.color, b.color, t)!,
        width: width,
        style: a.style,
        strokeAlign: a.strokeAlign,
      );
    }
    final Color colorA =
        a.style == BorderStyle.solid ? a.color : a.color.withAlpha(0);
    final Color colorB =
        b.style == BorderStyle.solid ? b.color : b.color.withAlpha(0);
    return BorderSide(
      color: Color.lerp(colorA, colorB, t)!,
      width: width,
      strokeAlign: _lerpDouble(a.strokeAlign, b.strokeAlign, t),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BorderSide &&
          other.color == color &&
          other.width == width &&
          other.style == style &&
          other.strokeAlign == strokeAlign;

  @override
  int get hashCode => Object.hash(color, width, style, strokeAlign);

  @override
  String toString() {
    if (this == BorderSide.none) return 'BorderSide.none';
    final StringBuffer b = StringBuffer('BorderSide(');
    final List<String> parts = <String>[
      if (color != const Color(0xFF000000)) '$color',
      if (width != 1.0) 'width: ${width.toStringAsFixed(1)}',
      if (style != BorderStyle.solid) '$style',
      if (strokeAlign != strokeAlignInside)
        'strokeAlign: ${strokeAlign.toStringAsFixed(1)}',
    ];
    b
      ..writeAll(parts, ', ')
      ..write(')');
    return b.toString();
  }
}

// ---------------------------------------------------------------------------
// ShapeBorder
// ---------------------------------------------------------------------------

/// Base class for shape outlines - Flutter's `ShapeBorder`.
abstract class ShapeBorder {
  const ShapeBorder();

  /// The widths of the sides, as an inset of the box.
  EdgeInsetsGeometry get dimensions;

  /// This border combined with [other], or null if they do not combine.
  ShapeBorder? add(ShapeBorder other, {bool reversed = false}) => null;

  /// The two borders as one; see the library comment for the limit.
  ShapeBorder operator +(ShapeBorder other) {
    final ShapeBorder? sum = add(other) ?? other.add(this, reversed: true);
    if (sum == null) {
      throw ArgumentError('$this and $other cannot be combined: compound '
          'borders are not supported');
    }
    return sum;
  }

  /// This border with its widths (and radii, for shapes) scaled by [t].
  ShapeBorder scale(double t);

  ShapeBorder? lerpFrom(ShapeBorder? a, double t) {
    if (a == null) return scale(t);
    return null;
  }

  ShapeBorder? lerpTo(ShapeBorder? b, double t) {
    if (b == null) return scale(1.0 - t);
    return null;
  }

  /// Interpolates [a] and [b], snapping at the midpoint when neither knows
  /// how to interpolate to the other.
  static ShapeBorder? lerp(ShapeBorder? a, ShapeBorder? b, double t) {
    if (identical(a, b)) return a;
    final ShapeBorder? result = b?.lerpFrom(a, t) ?? a?.lerpTo(b, t);
    return result ?? (t < 0.5 ? a : b);
  }

  /// The outline of the whole shape, border included.
  Path getOuterPath(Rect rect, {TextDirection? textDirection});

  /// The outline of the area inside the border.
  Path getInnerPath(Rect rect, {TextDirection? textDirection});

  /// Fills the shape with [paint]. [preferPaintInterior] says whether a
  /// subclass does this more cheaply than a path.
  void paintInterior(Canvas canvas, Rect rect, Paint paint,
      {TextDirection? textDirection}) {
    canvas.drawPath(getOuterPath(rect, textDirection: textDirection), paint);
  }

  bool get preferPaintInterior => false;

  /// Paints the border within [rect].
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection});
}

/// A [ShapeBorder] with one [side] - Flutter's `OutlinedBorder`.
abstract class OutlinedBorder extends ShapeBorder {
  const OutlinedBorder({this.side = BorderSide.none});

  final BorderSide side;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side.strokeInset);

  OutlinedBorder copyWith({BorderSide? side});

  @override
  OutlinedBorder scale(double t);

  static OutlinedBorder? lerp(OutlinedBorder? a, OutlinedBorder? b, double t) =>
      ShapeBorder.lerp(a, b, t) as OutlinedBorder?;
}

// ---------------------------------------------------------------------------
// Box borders
// ---------------------------------------------------------------------------

/// The border of a box: [Border] and [BorderDirectional] extend it.
///
/// Constructed directly it is the framework's original border: one [color]
/// and one [width] on all four sides, drawn inside the box - the same as
/// `Border.all(color: color, width: width)`. See the library comment.
class BoxBorder extends ShapeBorder {
  const BoxBorder({
    Color color = const Color(0xFF000000),
    double width = 1.0,
  })  : _color = color,
        _width = width;

  final Color _color;
  final double _width;

  /// The colour of a uniform border: the top side's for a [Border].
  Color get color => _color;

  /// The width of a uniform border: the top side's for a [Border].
  double get width => _width;

  /// This border as four sides, the shape everything paints from.
  Border get _sides => _width > 0
      ? Border.fromBorderSide(BorderSide(color: _color, width: _width))
      : const Border();

  BorderSide get top => _sides.top;

  BorderSide get bottom => _sides.bottom;

  /// Whether every side has the same colour, width, style and alignment.
  bool get isUniform => true;

  @override
  EdgeInsetsGeometry get dimensions => _sides.dimensions;

  @override
  BoxBorder? add(ShapeBorder other, {bool reversed = false}) =>
      _sides.add(other, reversed: reversed);

  @override
  BoxBorder scale(double t) => _sides.scale(t);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      _sides.getInnerPath(rect, textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRect(rect);

  /// Paints the border in [rect], following [shape] and, for a rectangle,
  /// [borderRadius].
  @override
  void paint(
    Canvas canvas,
    Rect rect, {
    TextDirection? textDirection,
    BoxShape shape = BoxShape.rectangle,
    BorderRadius? borderRadius,
  }) =>
      _sides.paint(canvas, rect,
          textDirection: textDirection,
          shape: shape,
          borderRadius: borderRadius);

  /// Interpolates two box borders; [Border] with [Border] interpolates side
  /// by side, anything else snaps at the midpoint.
  static BoxBorder? lerp(BoxBorder? a, BoxBorder? b, double t) {
    if (identical(a, b)) return a;
    final Border? sa = a == null ? null : _asBorder(a);
    final Border? sb = b == null ? null : _asBorder(b);
    if ((a == null || sa != null) && (b == null || sb != null)) {
      return Border.lerp(sa, sb, t);
    }
    return t < 0.5 ? a : b;
  }

  static Border? _asBorder(BoxBorder border) => switch (border) {
        Border() => border,
        BorderDirectional() => null,
        _ => border._sides,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other.runtimeType == runtimeType &&
          other is BoxBorder &&
          other._color == _color &&
          other._width == _width;

  @override
  int get hashCode => Object.hash(_color, _width);

  @override
  String toString() => 'BoxBorder(color: $_color, width: $_width)';

  static void _paintUniformWithRadius(
      Canvas canvas, Rect rect, BorderSide side, BorderRadius borderRadius) {
    final Paint paint = Paint()..color = side.color;
    final RRect borderRect = borderRadius.toRRect(rect);
    if (side.width == 0.0) {
      paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.0;
      canvas.drawRRect(borderRect, paint);
      return;
    }
    canvas.drawDRRect(borderRect.inflate(side.strokeOutset),
        borderRect.deflate(side.strokeInset), paint);
  }

  static void _paintUniformWithCircle(
      Canvas canvas, Rect rect, BorderSide side) {
    final double radius = (_shortestSide(rect) + side.strokeOffset) / 2;
    canvas.drawCircle(rect.center, radius, side.toPaint());
  }

  static void _paintUniformWithRectangle(
      Canvas canvas, Rect rect, BorderSide side) {
    canvas.drawRect(rect.inflate(side.strokeOffset / 2), side.toPaint());
  }

  static RRect _inflateRRect(RRect rect, EdgeInsets insets) =>
      RRect.fromLTRBAndCorners(
        rect.left - insets.left,
        rect.top - insets.top,
        rect.right + insets.right,
        rect.bottom + insets.bottom,
        topLeft: (rect.tlRadius + Radius.elliptical(insets.left, insets.top))
            .clamp(minimum: Radius.zero),
        topRight: (rect.trRadius + Radius.elliptical(insets.right, insets.top))
            .clamp(minimum: Radius.zero),
        bottomRight:
            (rect.brRadius + Radius.elliptical(insets.right, insets.bottom))
                .clamp(minimum: Radius.zero),
        bottomLeft:
            (rect.blRadius + Radius.elliptical(insets.left, insets.bottom))
                .clamp(minimum: Radius.zero),
      );

  static RRect _deflateRRect(RRect rect, EdgeInsets insets) =>
      RRect.fromLTRBAndCorners(
        rect.left + insets.left,
        rect.top + insets.top,
        rect.right - insets.right,
        rect.bottom - insets.bottom,
        topLeft: (rect.tlRadius - Radius.elliptical(insets.left, insets.top))
            .clamp(minimum: Radius.zero),
        topRight: (rect.trRadius - Radius.elliptical(insets.right, insets.top))
            .clamp(minimum: Radius.zero),
        bottomRight:
            (rect.brRadius - Radius.elliptical(insets.right, insets.bottom))
                .clamp(minimum: Radius.zero),
        bottomLeft:
            (rect.blRadius - Radius.elliptical(insets.left, insets.bottom))
                .clamp(minimum: Radius.zero),
      );
}

/// Four sides of a box - Flutter's `Border`.
class Border extends BoxBorder {
  const Border({
    this.top = BorderSide.none,
    this.right = BorderSide.none,
    this.bottom = BorderSide.none,
    this.left = BorderSide.none,
  });

  /// The same [side] on all four sides.
  const Border.fromBorderSide(BorderSide side)
      : top = side,
        right = side,
        bottom = side,
        left = side;

  /// [vertical] on the left and right, [horizontal] on the top and bottom.
  const Border.symmetric({
    BorderSide vertical = BorderSide.none,
    BorderSide horizontal = BorderSide.none,
  })  : left = vertical,
        top = horizontal,
        right = vertical,
        bottom = horizontal;

  /// A uniform border on all four sides.
  factory Border.all({
    Color color = const Color(0xFF000000),
    double width = 1.0,
    BorderStyle style = BorderStyle.solid,
    double strokeAlign = BorderSide.strokeAlignInside,
  }) =>
      Border.fromBorderSide(BorderSide(
          color: color, width: width, style: style, strokeAlign: strokeAlign));

  /// The sides of [a] and [b] merged, side by side.
  static Border merge(Border a, Border b) => Border(
        top: BorderSide.merge(a.top, b.top),
        right: BorderSide.merge(a.right, b.right),
        bottom: BorderSide.merge(a.bottom, b.bottom),
        left: BorderSide.merge(a.left, b.left),
      );

  @override
  final BorderSide top;

  final BorderSide right;

  @override
  final BorderSide bottom;

  final BorderSide left;

  @override
  Border get _sides => this;

  @override
  Color get color => top.color;

  @override
  double get width => top.width;

  @override
  EdgeInsetsGeometry get dimensions {
    if (_widthIsUniform) return EdgeInsets.all(top.strokeInset);
    return EdgeInsets(left.strokeInset, top.strokeInset, right.strokeInset,
        bottom.strokeInset);
  }

  bool get _colorIsUniform =>
      top.color == right.color &&
      top.color == bottom.color &&
      top.color == left.color;

  bool get _widthIsUniform =>
      top.width == right.width &&
      top.width == bottom.width &&
      top.width == left.width;

  bool get _styleIsUniform =>
      top.style == right.style &&
      top.style == bottom.style &&
      top.style == left.style;

  bool get _strokeAlignIsUniform =>
      top.strokeAlign == right.strokeAlign &&
      top.strokeAlign == bottom.strokeAlign &&
      top.strokeAlign == left.strokeAlign;

  bool get _hasHairline =>
      (top.style == BorderStyle.solid && top.width == 0.0) ||
      (right.style == BorderStyle.solid && right.width == 0.0) ||
      (bottom.style == BorderStyle.solid && bottom.width == 0.0) ||
      (left.style == BorderStyle.solid && left.width == 0.0);

  Set<Color> _distinctVisibleColors() => <Color>{
        if (top.style != BorderStyle.none) top.color,
        if (right.style != BorderStyle.none) right.color,
        if (bottom.style != BorderStyle.none) bottom.color,
        if (left.style != BorderStyle.none) left.color,
      };

  @override
  bool get isUniform =>
      _colorIsUniform &&
      _widthIsUniform &&
      _styleIsUniform &&
      _strokeAlignIsUniform;

  @override
  Border? add(ShapeBorder other, {bool reversed = false}) {
    if (other is Border &&
        BorderSide.canMerge(top, other.top) &&
        BorderSide.canMerge(right, other.right) &&
        BorderSide.canMerge(bottom, other.bottom) &&
        BorderSide.canMerge(left, other.left)) {
      return Border.merge(this, other);
    }
    return null;
  }

  @override
  Border scale(double t) => Border(
        top: top.scale(t),
        right: right.scale(t),
        bottom: bottom.scale(t),
        left: left.scale(t),
      );

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) {
    if (a is BoxBorder && a is! BorderDirectional) {
      return Border.lerp(BoxBorder._asBorder(a), this, t);
    }
    return super.lerpFrom(a, t);
  }

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) {
    if (b is BoxBorder && b is! BorderDirectional) {
      return Border.lerp(this, BoxBorder._asBorder(b), t);
    }
    return super.lerpTo(b, t);
  }

  /// Side-by-side interpolation; a null end is no border.
  static Border? lerp(Border? a, Border? b, double t) {
    if (identical(a, b)) return a;
    if (a == null) return b!.scale(t);
    if (b == null) return a.scale(1.0 - t);
    return Border(
      top: BorderSide.lerp(a.top, b.top, t),
      right: BorderSide.lerp(a.right, b.right, t),
      bottom: BorderSide.lerp(a.bottom, b.bottom, t),
      left: BorderSide.lerp(a.left, b.left, t),
    );
  }

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) {
    final EdgeInsets d =
        dimensions.resolve(textDirection ?? TextDirection.leftToRight);
    return Path()..addRect(d.deflateRect(rect));
  }

  @override
  void paint(
    Canvas canvas,
    Rect rect, {
    TextDirection? textDirection,
    BoxShape shape = BoxShape.rectangle,
    BorderRadius? borderRadius,
  }) {
    if (isUniform) {
      if (top.style == BorderStyle.none) return;
      switch (shape) {
        case BoxShape.circle:
          BoxBorder._paintUniformWithCircle(canvas, rect, top);
        case BoxShape.rectangle:
          if (borderRadius != null && borderRadius != BorderRadius.zero) {
            BoxBorder._paintUniformWithRadius(canvas, rect, top, borderRadius);
          } else {
            BoxBorder._paintUniformWithRectangle(canvas, rect, top);
          }
      }
      return;
    }
    if (_styleIsUniform && top.style == BorderStyle.none) return;
    final Set<Color> colors = _distinctVisibleColors();
    if (colors.length == 1 &&
        !_hasHairline &&
        (shape == BoxShape.circle ||
            (borderRadius != null && borderRadius != BorderRadius.zero))) {
      final RRect borderRect = switch (shape) {
        BoxShape.rectangle => (borderRadius ?? BorderRadius.zero).toRRect(rect),
        BoxShape.circle =>
          RRect.fromRectAndRadius(_circleIn(rect), Radius.circular(rect.width)),
      };
      final RRect inner = BoxBorder._deflateRRect(
          borderRect,
          EdgeInsets(left.strokeInset, top.strokeInset, right.strokeInset,
              bottom.strokeInset));
      final RRect outer = BoxBorder._inflateRRect(
          borderRect,
          EdgeInsets(left.strokeOutset, top.strokeOutset, right.strokeOutset,
              bottom.strokeOutset));
      canvas.drawDRRect(outer, inner, Paint()..color = colors.first);
      return;
    }
    paintBorder(canvas, rect,
        top: top, right: right, bottom: bottom, left: left);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other.runtimeType == runtimeType &&
          other is Border &&
          other.top == top &&
          other.right == right &&
          other.bottom == bottom &&
          other.left == left;

  @override
  int get hashCode => Object.hash(top, right, bottom, left);

  @override
  String toString() {
    if (isUniform) return 'Border.all($top)';
    final List<String> parts = <String>[
      if (top != BorderSide.none) 'top: $top',
      if (right != BorderSide.none) 'right: $right',
      if (bottom != BorderSide.none) 'bottom: $bottom',
      if (left != BorderSide.none) 'left: $left',
    ];
    return 'Border(${parts.join(', ')})';
  }
}

/// A border whose horizontal sides follow the reading direction - Flutter's
/// `BorderDirectional`. A null direction reads left to right.
class BorderDirectional extends BoxBorder {
  const BorderDirectional({
    this.top = BorderSide.none,
    this.start = BorderSide.none,
    this.end = BorderSide.none,
    this.bottom = BorderSide.none,
  });

  @override
  final BorderSide top;

  final BorderSide start;

  final BorderSide end;

  @override
  final BorderSide bottom;

  /// The physical border for [direction].
  Border resolve(TextDirection? direction) =>
      direction == TextDirection.rightToLeft
          ? Border(top: top, right: start, bottom: bottom, left: end)
          : Border(top: top, right: end, bottom: bottom, left: start);

  @override
  Border get _sides => resolve(TextDirection.leftToRight);

  @override
  Color get color => top.color;

  @override
  double get width => top.width;

  @override
  bool get isUniform => _sides.isUniform;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsetsDirectional(
      start.strokeInset, top.strokeInset, end.strokeInset, bottom.strokeInset);

  @override
  BorderDirectional scale(double t) => BorderDirectional(
        top: top.scale(t),
        start: start.scale(t),
        end: end.scale(t),
        bottom: bottom.scale(t),
      );

  @override
  BoxBorder? add(ShapeBorder other, {bool reversed = false}) {
    if (other is BorderDirectional &&
        BorderSide.canMerge(top, other.top) &&
        BorderSide.canMerge(start, other.start) &&
        BorderSide.canMerge(end, other.end) &&
        BorderSide.canMerge(bottom, other.bottom)) {
      return BorderDirectional(
        top: BorderSide.merge(top, other.top),
        start: BorderSide.merge(start, other.start),
        end: BorderSide.merge(end, other.end),
        bottom: BorderSide.merge(bottom, other.bottom),
      );
    }
    return null;
  }

  static BorderDirectional? lerp(
      BorderDirectional? a, BorderDirectional? b, double t) {
    if (identical(a, b)) return a;
    if (a == null) return b!.scale(t);
    if (b == null) return a.scale(1.0 - t);
    return BorderDirectional(
      top: BorderSide.lerp(a.top, b.top, t),
      start: BorderSide.lerp(a.start, b.start, t),
      end: BorderSide.lerp(a.end, b.end, t),
      bottom: BorderSide.lerp(a.bottom, b.bottom, t),
    );
  }

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) {
    if (a is BorderDirectional) return BorderDirectional.lerp(a, this, t);
    return super.lerpFrom(a, t);
  }

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) {
    if (b is BorderDirectional) return BorderDirectional.lerp(this, b, t);
    return super.lerpTo(b, t);
  }

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      resolve(textDirection).getInnerPath(rect);

  @override
  void paint(
    Canvas canvas,
    Rect rect, {
    TextDirection? textDirection,
    BoxShape shape = BoxShape.rectangle,
    BorderRadius? borderRadius,
  }) =>
      resolve(textDirection)
          .paint(canvas, rect, shape: shape, borderRadius: borderRadius);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BorderDirectional &&
          other.top == top &&
          other.start == start &&
          other.end == end &&
          other.bottom == bottom;

  @override
  int get hashCode => Object.hash(top, start, end, bottom);

  @override
  String toString() =>
      'BorderDirectional(top: $top, start: $start, end: $end, bottom: $bottom)';
}

/// Paints straight-edged sides as Flutter's `paintBorder` does: each side a
/// trapezoid that meets its neighbours on the diagonal; a zero width is a
/// hairline.
void paintBorder(
  Canvas canvas,
  Rect rect, {
  BorderSide top = BorderSide.none,
  BorderSide right = BorderSide.none,
  BorderSide bottom = BorderSide.none,
  BorderSide left = BorderSide.none,
}) {
  final Paint paint = Paint()..strokeWidth = 0.0;
  void side(BorderSide s, List<double> line, List<double> inner) {
    if (s.style == BorderStyle.none) return;
    paint.color = s.color;
    final Path path = Path()
      ..moveTo(line[0], line[1])
      ..lineTo(line[2], line[3]);
    if (s.width == 0.0) {
      paint.style = PaintingStyle.stroke;
    } else {
      paint.style = PaintingStyle.fill;
      path
        ..lineTo(inner[0], inner[1])
        ..lineTo(inner[2], inner[3]);
    }
    canvas.drawPath(path, paint);
  }

  side(top, <double>[
    rect.left,
    rect.top,
    rect.right,
    rect.top
  ], <double>[
    rect.right - right.width,
    rect.top + top.width,
    rect.left + left.width,
    rect.top + top.width,
  ]);
  side(right, <double>[
    rect.right,
    rect.top,
    rect.right,
    rect.bottom
  ], <double>[
    rect.right - right.width,
    rect.bottom - bottom.width,
    rect.right - right.width,
    rect.top + top.width,
  ]);
  side(bottom, <double>[
    rect.right,
    rect.bottom,
    rect.left,
    rect.bottom
  ], <double>[
    rect.left + left.width,
    rect.bottom - bottom.width,
    rect.right - right.width,
    rect.bottom - bottom.width,
  ]);
  side(left, <double>[
    rect.left,
    rect.bottom,
    rect.left,
    rect.top
  ], <double>[
    rect.left + left.width,
    rect.top + top.width,
    rect.left + left.width,
    rect.bottom - bottom.width,
  ]);
}

// ---------------------------------------------------------------------------
// Shape borders
// ---------------------------------------------------------------------------

/// A rectangle with rounded corners - Flutter's `RoundedRectangleBorder`.
class RoundedRectangleBorder extends OutlinedBorder {
  const RoundedRectangleBorder({
    super.side,
    this.borderRadius = BorderRadius.zero,
  });

  final BorderRadiusGeometry borderRadius;

  RRect _rrect(Rect rect, TextDirection? textDirection) =>
      borderRadius.resolve(textDirection).toRRect(rect);

  @override
  RoundedRectangleBorder scale(double t) => RoundedRectangleBorder(
        side: side.scale(t),
        borderRadius: borderRadius * t,
      );

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) {
    if (a is RoundedRectangleBorder) {
      return RoundedRectangleBorder(
        side: BorderSide.lerp(a.side, side, t),
        borderRadius:
            BorderRadiusGeometry.lerp(a.borderRadius, borderRadius, t)!,
      );
    }
    return super.lerpFrom(a, t);
  }

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) {
    if (b is RoundedRectangleBorder) {
      return RoundedRectangleBorder(
        side: BorderSide.lerp(side, b.side, t),
        borderRadius:
            BorderRadiusGeometry.lerp(borderRadius, b.borderRadius, t)!,
      );
    }
    return super.lerpTo(b, t);
  }

  @override
  RoundedRectangleBorder copyWith({
    BorderSide? side,
    BorderRadiusGeometry? borderRadius,
  }) =>
      RoundedRectangleBorder(
        side: side ?? this.side,
        borderRadius: borderRadius ?? this.borderRadius,
      );

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRRect(_rrect(rect, textDirection).deflate(side.strokeInset));

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRRect(_rrect(rect, textDirection));

  @override
  void paintInterior(Canvas canvas, Rect rect, Paint paint,
      {TextDirection? textDirection}) {
    if (borderRadius == BorderRadius.zero) {
      canvas.drawRect(rect, paint);
    } else {
      canvas.drawRRect(_rrect(rect, textDirection), paint);
    }
  }

  @override
  bool get preferPaintInterior => true;

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none) return;
    final RRect borderRect = _rrect(rect, textDirection);
    if (side.width == 0.0) {
      canvas.drawRRect(borderRect, side.toPaint());
      return;
    }
    canvas.drawDRRect(borderRect.inflate(side.strokeOutset),
        borderRect.deflate(side.strokeInset), Paint()..color = side.color);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other.runtimeType == runtimeType &&
          other is RoundedRectangleBorder &&
          other.side == side &&
          other.borderRadius == borderRadius;

  @override
  int get hashCode => Object.hash(side, borderRadius);

  @override
  String toString() => 'RoundedRectangleBorder($side, $borderRadius)';
}

/// A circle (or, with [eccentricity], an ellipse) centred in the box -
/// Flutter's `CircleBorder`.
class CircleBorder extends OutlinedBorder {
  const CircleBorder({super.side, this.eccentricity = 0.0})
      : assert(eccentricity >= 0.0 && eccentricity <= 1.0);

  /// 0 is a circle on the shorter side; 1 is the ellipse inscribed in the
  /// box.
  final double eccentricity;

  Rect _adjust(Rect rect) {
    final double e = eccentricity.clamp(0.0, 1.0);
    if (e == 1.0) return rect;
    final Rect circle = _circleIn(rect);
    if (e == 0.0) return circle;
    return Rect.lerp(circle, rect, e)!;
  }

  @override
  CircleBorder scale(double t) =>
      CircleBorder(side: side.scale(t), eccentricity: eccentricity);

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) {
    if (a is CircleBorder) {
      return CircleBorder(
        side: BorderSide.lerp(a.side, side, t),
        eccentricity: _lerpDouble(a.eccentricity, eccentricity, t),
      );
    }
    return super.lerpFrom(a, t);
  }

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) {
    if (b is CircleBorder) {
      return CircleBorder(
        side: BorderSide.lerp(side, b.side, t),
        eccentricity: _lerpDouble(eccentricity, b.eccentricity, t),
      );
    }
    return super.lerpTo(b, t);
  }

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addOval(_adjust(rect).deflate(side.strokeInset));

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addOval(_adjust(rect));

  @override
  void paintInterior(Canvas canvas, Rect rect, Paint paint,
      {TextDirection? textDirection}) {
    canvas.drawOval(_adjust(rect), paint);
  }

  @override
  bool get preferPaintInterior => true;

  @override
  CircleBorder copyWith({BorderSide? side, double? eccentricity}) =>
      CircleBorder(
        side: side ?? this.side,
        eccentricity: eccentricity ?? this.eccentricity,
      );

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none) return;
    final Rect oval = _adjust(rect);
    if (side.width == 0.0) {
      canvas.drawOval(oval, side.toPaint());
      return;
    }
    canvas.drawOval(oval.inflate(side.strokeOffset / 2), side.toPaint());
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other.runtimeType == runtimeType &&
          other is CircleBorder &&
          other.side == side &&
          other.eccentricity == eccentricity;

  @override
  int get hashCode => Object.hash(side, eccentricity);

  @override
  String toString() => eccentricity == 0.0
      ? 'CircleBorder($side)'
      : 'CircleBorder($side, eccentricity: $eccentricity)';
}

/// A box with semicircular ends - Flutter's `StadiumBorder`.
class StadiumBorder extends OutlinedBorder {
  const StadiumBorder({super.side});

  RRect _rrect(Rect rect) =>
      RRect.fromRectAndRadius(rect, Radius.circular(_shortestSide(rect) / 2));

  @override
  StadiumBorder scale(double t) => StadiumBorder(side: side.scale(t));

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) {
    if (a is StadiumBorder) {
      return StadiumBorder(side: BorderSide.lerp(a.side, side, t));
    }
    return super.lerpFrom(a, t);
  }

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) {
    if (b is StadiumBorder) {
      return StadiumBorder(side: BorderSide.lerp(side, b.side, t));
    }
    return super.lerpTo(b, t);
  }

  @override
  StadiumBorder copyWith({BorderSide? side}) =>
      StadiumBorder(side: side ?? this.side);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRRect(_rrect(rect).deflate(side.strokeInset));

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRRect(_rrect(rect));

  @override
  void paintInterior(Canvas canvas, Rect rect, Paint paint,
      {TextDirection? textDirection}) {
    canvas.drawRRect(_rrect(rect), paint);
  }

  @override
  bool get preferPaintInterior => true;

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none) return;
    final RRect borderRect = _rrect(rect);
    if (side.width == 0.0) {
      canvas.drawRRect(borderRect, side.toPaint());
      return;
    }
    canvas.drawDRRect(borderRect.inflate(side.strokeOutset),
        borderRect.deflate(side.strokeInset), Paint()..color = side.color);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other.runtimeType == runtimeType &&
          other is StadiumBorder &&
          other.side == side;

  @override
  int get hashCode => side.hashCode;

  @override
  String toString() => 'StadiumBorder($side)';
}

/// A [CustomClipper] that clips to the outer path of a [ShapeBorder] -
/// Flutter's `ShapeBorderClipper`.
class ShapeBorderClipper extends CustomClipper<Path> {
  const ShapeBorderClipper({required this.shape, this.textDirection});

  final ShapeBorder shape;

  final TextDirection? textDirection;

  @override
  Path getClip(Size size) =>
      shape.getOuterPath(Rect.fromLTWH(0, 0, size.width, size.height),
          textDirection: textDirection);

  @override
  bool shouldReclip(CustomClipper<Path> oldClipper) {
    if (oldClipper.runtimeType != ShapeBorderClipper) return true;
    final ShapeBorderClipper old = oldClipper as ShapeBorderClipper;
    return old.shape != shape || old.textDirection != textDirection;
  }
}
