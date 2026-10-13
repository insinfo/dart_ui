// Portions of this file are adapted from Flutter's `painting/decoration.dart`,
// `painting/box_decoration.dart`, `painting/box_shadow.dart`,
// `painting/shape_decoration.dart` and `painting/gradient.dart`:
//
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Decorations with Flutter's names: [Decoration], [BoxDecoration],
/// [ShapeDecoration], [BoxShadow] and [Shadow], [SweepGradient], and the
/// render node that paints them, [RenderDecoratedBox].
///
/// ## The framework's own `radius:`
///
/// [BoxDecoration] predates Flutter compatibility and had one circular
/// corner radius, `radius:`. It still works and means what it meant; Flutter's
/// `borderRadius:` takes precedence when both are given.
///
/// ## Shadows are layered, not blurred
///
/// No renderer here has a blur. A [BoxShadow] is painted as a stack of
/// translucent rounded rectangles - inflated and deflated copies of the
/// shadow's shape - whose accumulated alpha follows the Gaussian's integral
/// across the edge (`paintBlurredRRect` in `canvas.dart`). For a box, a
/// stadium or a circle that is close to Flutter's picture; for an arbitrary
/// [ShapeBorder] the same falloff is built from strokes of the outline. Only
/// [BlurStyle.normal] is drawn as itself; the other styles are drawn as
/// normal.
///
/// ## Differences from Flutter
///
///   * No `image:` (`DecorationImage` does not exist here).
///   * `gradient:` takes a [ShaderProvider]: [SweepGradient] today, because
///     Flutter's `LinearGradient`/`RadialGradient` names belong to the display
///     list's absolute-coordinate gradients in this framework.
///   * An empty [BoxDecoration] (nothing to paint) takes no pointer; see
///     [RenderDecoratedBox.hitTestSelf].
///   * `BoxShape.circle` with a `borderRadius` is not an error: the radius is
///     ignored.
///   * There is no `createBoxPainter`/`BoxPainter`: decorations paint with
///     [Decoration.paintInto].
library;

import 'dart:math' as math;

import '../geometry/offset.dart';
import '../geometry/path.dart';
import '../geometry/rect.dart';
import '../geometry/rrect.dart';
import '../geometry/size.dart';
import '../graphics/color.dart';
import '../graphics/display_list.dart';
import '../graphics/shader.dart';
import '../text/shaper.dart' show TextDirection;
import 'alignment.dart';
import 'border_radius.dart';
import 'borders.dart';
import 'canvas.dart';
import 'edge_insets.dart';
import 'render_proxy_box.dart' show RenderProxyBox;

double _lerpDouble(double a, double b, double t) => a + (b - a) * t;

// ---------------------------------------------------------------------------
// Shadows
// ---------------------------------------------------------------------------

/// A single shadow - Flutter's `dart:ui` `Shadow`.
class Shadow {
  const Shadow({
    this.color = const Color(0xFF000000),
    this.offset = Offset.zero,
    this.blurRadius = 0.0,
  }) : assert(blurRadius >= 0.0);

  final Color color;

  /// The displacement of the shadow from the shape.
  final Offset offset;

  /// The blur radius; the standard deviation is [blurSigma].
  final double blurRadius;

  /// Flutter's conversion from a blur radius to a standard deviation.
  static double convertRadiusToSigma(double radius) =>
      radius > 0 ? radius * 0.57735 + 0.5 : 0;

  double get blurSigma => convertRadiusToSigma(blurRadius);

  /// A paint of the shadow's colour. There is no mask filter here; the blur
  /// is drawn by layering, see the library comment.
  Paint toPaint() => Paint()..color = color;

  Shadow scale(double factor) => Shadow(
        color: color,
        offset: offset * factor,
        blurRadius: blurRadius * factor,
      );

  static Shadow? lerp(Shadow? a, Shadow? b, double t) {
    if (identical(a, b)) return a;
    if (a == null) return b!.scale(t);
    if (b == null) return a.scale(1.0 - t);
    return Shadow(
      color: Color.lerp(a.color, b.color, t)!,
      offset: Offset.lerp(a.offset, b.offset, t)!,
      blurRadius: math.max(0.0, _lerpDouble(a.blurRadius, b.blurRadius, t)),
    );
  }

  static List<Shadow>? lerpList(List<Shadow>? a, List<Shadow>? b, double t) {
    if (identical(a, b)) return a;
    a ??= <Shadow>[];
    b ??= <Shadow>[];
    final int common = math.min(a.length, b.length);
    return <Shadow>[
      for (var i = 0; i < common; i++) Shadow.lerp(a[i], b[i], t)!,
      for (var i = common; i < a.length; i++) a[i].scale(1.0 - t),
      for (var i = common; i < b.length; i++) b[i].scale(t),
    ];
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Shadow &&
          other.runtimeType == runtimeType &&
          other.color == color &&
          other.offset == offset &&
          other.blurRadius == blurRadius;

  @override
  int get hashCode => Object.hash(color, offset, blurRadius);

  @override
  String toString() => 'Shadow($color, $offset, $blurRadius)';
}

/// A shadow cast by a box - Flutter's `BoxShadow`.
///
/// Drawn by layering rather than blurring; see the library comment.
class BoxShadow extends Shadow {
  const BoxShadow({
    super.color,
    super.offset,
    super.blurRadius,
    this.spreadRadius = 0.0,
    this.blurStyle = BlurStyle.normal,
  });

  /// How far the box is grown before blurring.
  final double spreadRadius;

  /// Only [BlurStyle.normal] is honoured; see the library comment.
  final BlurStyle blurStyle;

  @override
  BoxShadow scale(double factor) => BoxShadow(
        color: color,
        offset: offset * factor,
        blurRadius: blurRadius * factor,
        spreadRadius: spreadRadius * factor,
        blurStyle: blurStyle,
      );

  BoxShadow copyWith({
    Color? color,
    Offset? offset,
    double? blurRadius,
    double? spreadRadius,
    BlurStyle? blurStyle,
  }) =>
      BoxShadow(
        color: color ?? this.color,
        offset: offset ?? this.offset,
        blurRadius: blurRadius ?? this.blurRadius,
        spreadRadius: spreadRadius ?? this.spreadRadius,
        blurStyle: blurStyle ?? this.blurStyle,
      );

  static BoxShadow? lerp(BoxShadow? a, BoxShadow? b, double t) {
    if (identical(a, b)) return a;
    if (a == null) return b!.scale(t);
    if (b == null) return a.scale(1.0 - t);
    return BoxShadow(
      color: Color.lerp(a.color, b.color, t)!,
      offset: Offset.lerp(a.offset, b.offset, t)!,
      blurRadius: math.max(0.0, _lerpDouble(a.blurRadius, b.blurRadius, t)),
      spreadRadius: _lerpDouble(a.spreadRadius, b.spreadRadius, t),
      blurStyle: a.blurStyle == BlurStyle.normal ? b.blurStyle : a.blurStyle,
    );
  }

  static List<BoxShadow>? lerpList(
      List<BoxShadow>? a, List<BoxShadow>? b, double t) {
    if (identical(a, b)) return a;
    a ??= <BoxShadow>[];
    b ??= <BoxShadow>[];
    final int common = math.min(a.length, b.length);
    return <BoxShadow>[
      for (var i = 0; i < common; i++) BoxShadow.lerp(a[i], b[i], t)!,
      for (var i = common; i < a.length; i++) a[i].scale(1.0 - t),
      for (var i = common; i < b.length; i++) b[i].scale(t),
    ];
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BoxShadow &&
          other.color == color &&
          other.offset == offset &&
          other.blurRadius == blurRadius &&
          other.spreadRadius == spreadRadius &&
          other.blurStyle == blurStyle;

  @override
  int get hashCode =>
      Object.hash(color, offset, blurRadius, spreadRadius, blurStyle);

  @override
  String toString() => 'BoxShadow($color, $offset, $blurRadius, $spreadRadius, '
      '${blurStyle.name})';
}

// ---------------------------------------------------------------------------
// Sweep gradient
// ---------------------------------------------------------------------------

/// A gradient swept around a centre - Flutter's `SweepGradient`.
///
/// [center] is an alignment in the box the gradient fills; angles are in
/// radians, clockwise from the positive x axis. The display list has no sweep
/// kind, so it is painted by decomposition into one-degree wedges - see
/// [SweepShader]. There is no `transform:`.
class SweepGradient implements ShaderProvider {
  const SweepGradient({
    this.center = Alignment.center,
    this.startAngle = 0.0,
    this.endAngle = math.pi * 2,
    required this.colors,
    this.stops,
    this.tileMode = TileMode.clamp,
  });

  final AlignmentGeometry center;
  final double startAngle;
  final double endAngle;
  final List<Color> colors;
  final List<double>? stops;
  final TileMode tileMode;

  @override
  Shader createShader(Rect rect, {TextDirection? textDirection}) {
    final Alignment a =
        center.resolve(textDirection ?? TextDirection.leftToRight);
    return SweepShader(
      center: Offset(rect.left + rect.width * (a.x + 1) / 2,
          rect.top + rect.height * (a.y + 1) / 2),
      startAngle: startAngle,
      endAngle: endAngle,
      colors: colors,
      stops: stops,
      tileMode: tileMode,
    );
  }

  /// This gradient with every colour's opacity multiplied by [factor].
  SweepGradient scale(double factor) => SweepGradient(
        center: center,
        startAngle: startAngle,
        endAngle: endAngle,
        colors: <Color>[
          for (final Color c in colors)
            c.withAlpha((c.alpha * factor).round().clamp(0, 255)),
        ],
        stops: stops,
        tileMode: tileMode,
      );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! SweepGradient ||
        other.center != center ||
        other.startAngle != startAngle ||
        other.endAngle != endAngle ||
        other.tileMode != tileMode ||
        other.colors.length != colors.length ||
        (other.stops == null) != (stops == null)) {
      return false;
    }
    for (var i = 0; i < colors.length; i++) {
      if (other.colors[i] != colors[i]) return false;
      if (stops != null && other.stops![i] != stops![i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(center, startAngle, endAngle, tileMode,
      Object.hashAll(colors), stops == null ? null : Object.hashAll(stops!));

  @override
  String toString() => 'SweepGradient($center, $startAngle..$endAngle, '
      '$colors${stops == null ? '' : ', $stops'}, ${tileMode.name})';
}

// ---------------------------------------------------------------------------
// Decoration
// ---------------------------------------------------------------------------

/// A description of a box decoration - Flutter's `Decoration`.
abstract class Decoration {
  const Decoration();

  /// The space the decoration's border takes, which `Container` adds to its
  /// padding.
  EdgeInsetsGeometry get padding => EdgeInsets.zero;

  /// Whether painting is expensive enough to be worth caching.
  bool get isComplex => false;

  Decoration? lerpFrom(Decoration? a, double t) => null;

  Decoration? lerpTo(Decoration? b, double t) => null;

  /// Interpolates [a] and [b], snapping at the midpoint when neither knows
  /// how to interpolate to the other.
  static Decoration? lerp(Decoration? a, Decoration? b, double t) {
    if (identical(a, b)) return a;
    if (a == null) return b!.lerpFrom(null, t) ?? b;
    if (b == null) return a.lerpTo(null, t) ?? a;
    if (t == 0.0) return a;
    if (t == 1.0) return b;
    return b.lerpFrom(a, t) ?? a.lerpTo(b, t) ?? (t < 0.5 ? a : b);
  }

  /// Whether [position] (in the box's coordinates) hits the decoration.
  bool hitTest(Size size, Offset position, {TextDirection? textDirection}) =>
      true;

  /// Paints the decoration into [rect]. The framework's equivalent of
  /// Flutter's `createBoxPainter(...).paint(...)`.
  void paintInto(Canvas canvas, Rect rect, {TextDirection? textDirection});
}

/// Paints [shadows] for a rounded rectangle or, failing that, any outline.
void _paintShadows(
  DisplayList list,
  List<BoxShadow> shadows,
  Rect rect,
  RRect? Function(Rect bounds) asRRect,
  Path Function(Rect bounds) asPath,
) {
  for (final BoxShadow shadow in shadows) {
    final Rect bounds = rect.shift(shadow.offset).inflate(shadow.spreadRadius);
    final RRect? rrect = asRRect(bounds);
    if (rrect != null) {
      paintBlurredRRect(list, rrect, shadow.color, shadow.blurSigma);
    } else {
      paintBlurredPath(list, asPath(bounds), shadow.color, shadow.blurSigma);
    }
  }
}

/// An immutable description of how to paint a box - Flutter's
/// `BoxDecoration`.
///
/// Paint order, as in Flutter: [boxShadow], then the fill, then [border].
/// The fill is [gradient] when there is one and [color] otherwise - with both,
/// Flutter paints only the gradient, and so does this.
class BoxDecoration extends Decoration {
  const BoxDecoration({
    this.color,
    this.border,
    this.borderRadius,
    this.boxShadow,
    this.gradient,
    this.backgroundBlendMode,
    this.shape = BoxShape.rectangle,
    this.radius = 0.0,
  });

  /// The fill, or null for none.
  final Color? color;

  /// A border drawn over the fill.
  final BoxBorder? border;

  /// Corner radii for a [BoxShape.rectangle]. Takes precedence over
  /// [radius].
  final BorderRadiusGeometry? borderRadius;

  /// Shadows cast by the box, painted under it.
  final List<BoxShadow>? boxShadow;

  /// A gradient fill, painted instead of [color].
  final ShaderProvider? gradient;

  /// The blend mode of the fill.
  final BlendMode? backgroundBlendMode;

  final BoxShape shape;

  /// The framework's original circular corner radius, used when
  /// [borderRadius] is null. Clamped at paint time to what the box can hold.
  final double radius;

  /// The corner radii in force, resolved for [textDirection]; null for
  /// square corners.
  BorderRadius? effectiveBorderRadius(TextDirection? textDirection) {
    final BorderRadiusGeometry? geometry = borderRadius;
    if (geometry != null) {
      final BorderRadius resolved = geometry.resolve(textDirection);
      return resolved == BorderRadius.zero ? null : resolved;
    }
    if (radius > 0) return BorderRadius.circular(radius);
    return null;
  }

  bool get _borderVisible {
    final BoxBorder? b = border;
    if (b == null) return false;
    return switch (b) {
      Border() => b.top.style != BorderStyle.none ||
          b.right.style != BorderStyle.none ||
          b.bottom.style != BorderStyle.none ||
          b.left.style != BorderStyle.none,
      BorderDirectional() => b.top.style != BorderStyle.none ||
          b.start.style != BorderStyle.none ||
          b.end.style != BorderStyle.none ||
          b.bottom.style != BorderStyle.none,
      _ => b.width > 0,
    };
  }

  /// Whether this decoration would paint nothing at all.
  bool get isEmpty =>
      color == null &&
      gradient == null &&
      (boxShadow == null || boxShadow!.isEmpty) &&
      !_borderVisible;

  @override
  EdgeInsetsGeometry get padding => border?.dimensions ?? EdgeInsets.zero;

  @override
  bool get isComplex => boxShadow != null && boxShadow!.isNotEmpty;

  BoxDecoration copyWith({
    Color? color,
    BoxBorder? border,
    BorderRadiusGeometry? borderRadius,
    List<BoxShadow>? boxShadow,
    ShaderProvider? gradient,
    BlendMode? backgroundBlendMode,
    BoxShape? shape,
    double? radius,
  }) =>
      BoxDecoration(
        color: color ?? this.color,
        border: border ?? this.border,
        borderRadius: borderRadius ?? this.borderRadius,
        boxShadow: boxShadow ?? this.boxShadow,
        gradient: gradient ?? this.gradient,
        backgroundBlendMode: backgroundBlendMode ?? this.backgroundBlendMode,
        shape: shape ?? this.shape,
        radius: radius ?? this.radius,
      );

  /// This decoration faded towards nothing by [factor] (1 is unchanged).
  BoxDecoration scale(double factor) => BoxDecoration(
        color: Color.lerp(null, color, factor),
        border: BoxBorder.lerp(null, border, factor),
        borderRadius: borderRadius == null ? null : borderRadius! * factor,
        boxShadow: BoxShadow.lerpList(null, boxShadow, factor),
        gradient: gradient is SweepGradient
            ? (gradient! as SweepGradient).scale(factor)
            : gradient,
        backgroundBlendMode: backgroundBlendMode,
        shape: shape,
        radius: radius * factor,
      );

  @override
  BoxDecoration? lerpFrom(Decoration? a, double t) {
    if (a == null) return scale(t);
    if (a is BoxDecoration) return BoxDecoration.lerp(a, this, t);
    return super.lerpFrom(a, t) as BoxDecoration?;
  }

  @override
  BoxDecoration? lerpTo(Decoration? b, double t) {
    if (b == null) return scale(1.0 - t);
    if (b is BoxDecoration) return BoxDecoration.lerp(this, b, t);
    return super.lerpTo(b, t) as BoxDecoration?;
  }

  /// Interpolates every property; [shape], [gradient] and
  /// [backgroundBlendMode] snap at the midpoint.
  static BoxDecoration? lerp(BoxDecoration? a, BoxDecoration? b, double t) {
    if (identical(a, b)) return a;
    if (a == null) return b!.scale(t);
    if (b == null) return a.scale(1.0 - t);
    if (t == 0.0) return a;
    if (t == 1.0) return b;
    return BoxDecoration(
      color: Color.lerp(a.color, b.color, t),
      border: BoxBorder.lerp(a.border, b.border, t),
      borderRadius:
          BorderRadiusGeometry.lerp(a.borderRadius, b.borderRadius, t),
      boxShadow: BoxShadow.lerpList(a.boxShadow, b.boxShadow, t),
      gradient: t < 0.5 ? a.gradient : b.gradient,
      backgroundBlendMode:
          t < 0.5 ? a.backgroundBlendMode : b.backgroundBlendMode,
      shape: t < 0.5 ? a.shape : b.shape,
      radius: _lerpDouble(a.radius, b.radius, t),
    );
  }

  @override
  bool hitTest(Size size, Offset position, {TextDirection? textDirection}) {
    final Rect box = Rect.fromLTWH(0, 0, size.width, size.height);
    switch (shape) {
      case BoxShape.rectangle:
        final BorderRadius? r = effectiveBorderRadius(textDirection);
        if (r == null) return true;
        return r.toRRect(box).contains(position);
      case BoxShape.circle:
        return (position - box.center).distance <=
            math.min(size.width, size.height) / 2.0;
    }
  }

  @override
  void paintInto(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    final BorderRadius? r =
        shape == BoxShape.circle ? null : effectiveBorderRadius(textDirection);

    RRect shapeIn(Rect bounds) => switch (shape) {
          BoxShape.circle => () {
              final double half =
                  math.min(bounds.width.abs(), bounds.height.abs()) / 2;
              final Offset c = bounds.center;
              return RRect.fromLTRBXY(c.dx - half, c.dy - half, c.dx + half,
                  c.dy + half, half, half);
            }(),
          BoxShape.rectangle =>
            r?.toRRect(bounds) ?? RRect.fromRectAndRadius(bounds, Radius.zero),
        };

    final List<BoxShadow>? shadows = boxShadow;
    if (shadows != null && shadows.isNotEmpty) {
      _paintShadows(canvas.displayList, shadows, rect, shapeIn,
          (Rect b) => Path()..addRRect(shapeIn(b)));
    }

    if (color != null || gradient != null) {
      final Paint paint = Paint()..color = color ?? const Color(0xFF000000);
      if (gradient != null) {
        paint
          ..color = const Color(0xFF000000)
          ..shader = gradient!.createShader(rect, textDirection: textDirection);
      }
      if (backgroundBlendMode != null) paint.blendMode = backgroundBlendMode!;
      final RRect fill = shapeIn(rect);
      if (fill.isRect) {
        canvas.drawRect(rect, paint);
      } else {
        canvas.drawRRect(fill, paint);
      }
    }

    final BoxBorder? b = border;
    if (b != null) {
      final BorderSide top = b.top;
      // A uniform inside border on rounded corners is drawn as one stroked
      // rounded rectangle along its centre line - the framework's original
      // picture, and Flutter's too wherever the inner corner keeps a radius.
      if (shape == BoxShape.rectangle &&
          r != null &&
          b.isUniform &&
          top.style == BorderStyle.solid &&
          top.width > 0 &&
          top.strokeAlign == BorderSide.strokeAlignInside) {
        final RRect outer = r.toRRect(rect).scaleRadii();
        final double half = top.width / 2;
        if (outer.tlRadiusX >= half &&
            outer.tlRadiusY >= half &&
            outer.trRadiusX >= half &&
            outer.trRadiusY >= half &&
            outer.brRadiusX >= half &&
            outer.brRadiusY >= half &&
            outer.blRadiusX >= half &&
            outer.blRadiusY >= half) {
          canvas.drawRRect(outer.deflate(half), top.toPaint());
          return;
        }
      }
      b.paint(canvas, rect,
          textDirection: textDirection, shape: shape, borderRadius: r);
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! BoxDecoration ||
        other.runtimeType != runtimeType ||
        other.color != color ||
        other.border != border ||
        other.borderRadius != borderRadius ||
        other.gradient != gradient ||
        other.backgroundBlendMode != backgroundBlendMode ||
        other.shape != shape ||
        other.radius != radius) {
      return false;
    }
    final List<BoxShadow>? a = boxShadow;
    final List<BoxShadow>? b = other.boxShadow;
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        color,
        border,
        borderRadius,
        boxShadow == null ? null : Object.hashAll(boxShadow!),
        gradient,
        backgroundBlendMode,
        shape,
        radius,
      );

  @override
  String toString() {
    final List<String> parts = <String>[
      if (color != null) 'color: $color',
      if (border != null) 'border: $border',
      if (borderRadius != null) 'borderRadius: $borderRadius',
      if (radius != 0) 'radius: $radius',
      if (boxShadow != null) 'boxShadow: $boxShadow',
      if (gradient != null) 'gradient: $gradient',
      if (backgroundBlendMode != null)
        'backgroundBlendMode: ${backgroundBlendMode!.name}',
      if (shape != BoxShape.rectangle) 'shape: ${shape.name}',
    ];
    return 'BoxDecoration(${parts.join(', ')})';
  }
}

/// A decoration painted by a [ShapeBorder] - Flutter's `ShapeDecoration`.
class ShapeDecoration extends Decoration {
  const ShapeDecoration({
    this.color,
    this.gradient,
    this.shadows,
    required this.shape,
  });

  /// The same picture as [source], expressed as a shape.
  factory ShapeDecoration.fromBoxDecoration(BoxDecoration source) {
    final ShapeBorder shape;
    final BoxBorder? border = source.border;
    switch (source.shape) {
      case BoxShape.circle:
        shape = border == null
            ? const CircleBorder()
            : CircleBorder(side: border.top);
      case BoxShape.rectangle:
        final BorderRadiusGeometry? radius = source.borderRadius ??
            (source.radius > 0 ? BorderRadius.circular(source.radius) : null);
        if (radius != null) {
          shape = RoundedRectangleBorder(
            side: border?.top ?? BorderSide.none,
            borderRadius: radius,
          );
        } else {
          shape = border ?? const Border();
        }
    }
    return ShapeDecoration(
      color: source.color,
      gradient: source.gradient,
      shadows: source.boxShadow,
      shape: shape,
    );
  }

  final Color? color;

  final ShaderProvider? gradient;

  final List<BoxShadow>? shadows;

  final ShapeBorder shape;

  @override
  EdgeInsetsGeometry get padding => shape.dimensions;

  @override
  bool get isComplex => shadows != null && shadows!.isNotEmpty;

  ShapeDecoration scale(double factor) => ShapeDecoration(
        color: Color.lerp(null, color, factor),
        gradient: gradient is SweepGradient
            ? (gradient! as SweepGradient).scale(factor)
            : gradient,
        shadows: BoxShadow.lerpList(null, shadows, factor),
        shape: shape.scale(factor),
      );

  @override
  Decoration? lerpFrom(Decoration? a, double t) {
    if (a == null) return scale(t);
    if (a is BoxDecoration) {
      return ShapeDecoration.lerp(
          ShapeDecoration.fromBoxDecoration(a), this, t);
    }
    if (a is ShapeDecoration) return ShapeDecoration.lerp(a, this, t);
    return super.lerpFrom(a, t);
  }

  @override
  Decoration? lerpTo(Decoration? b, double t) {
    if (b == null) return scale(1.0 - t);
    if (b is BoxDecoration) {
      return ShapeDecoration.lerp(
          this, ShapeDecoration.fromBoxDecoration(b), t);
    }
    if (b is ShapeDecoration) return ShapeDecoration.lerp(this, b, t);
    return super.lerpTo(b, t);
  }

  static ShapeDecoration? lerp(
      ShapeDecoration? a, ShapeDecoration? b, double t) {
    if (identical(a, b)) return a;
    if (a == null) return b!.scale(t);
    if (b == null) return a.scale(1.0 - t);
    if (t == 0.0) return a;
    if (t == 1.0) return b;
    return ShapeDecoration(
      color: Color.lerp(a.color, b.color, t),
      gradient: t < 0.5 ? a.gradient : b.gradient,
      shadows: BoxShadow.lerpList(a.shadows, b.shadows, t),
      shape: ShapeBorder.lerp(a.shape, b.shape, t)!,
    );
  }

  @override
  bool hitTest(Size size, Offset position, {TextDirection? textDirection}) =>
      shape
          .getOuterPath(Rect.fromLTWH(0, 0, size.width, size.height),
              textDirection: textDirection)
          .contains(position);

  /// The shape as a rounded rectangle, when it is one.
  RRect? _asRRect(Rect bounds, TextDirection? textDirection) {
    final ShapeBorder s = shape;
    return switch (s) {
      RoundedRectangleBorder() =>
        s.borderRadius.resolve(textDirection).toRRect(bounds),
      StadiumBorder() => RRect.fromRectAndRadius(
          bounds,
          Radius.circular(
              math.min(bounds.width.abs(), bounds.height.abs()) / 2)),
      CircleBorder(eccentricity: 0.0) => () {
          final double half =
              math.min(bounds.width.abs(), bounds.height.abs()) / 2;
          final Offset c = bounds.center;
          return RRect.fromLTRBXY(
              c.dx - half, c.dy - half, c.dx + half, c.dy + half, half, half);
        }(),
      Border() => RRect.fromRectAndRadius(bounds, Radius.zero),
      _ => null,
    };
  }

  @override
  void paintInto(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    final List<BoxShadow>? s = shadows;
    if (s != null && s.isNotEmpty) {
      _paintShadows(
        canvas.displayList,
        s,
        rect,
        (Rect b) => _asRRect(b, textDirection),
        (Rect b) => shape.getOuterPath(b, textDirection: textDirection),
      );
    }
    if (color != null || gradient != null) {
      final Paint paint = Paint()..color = color ?? const Color(0xFF000000);
      if (gradient != null) {
        paint
          ..color = const Color(0xFF000000)
          ..shader = gradient!.createShader(rect, textDirection: textDirection);
      }
      if (shape.preferPaintInterior) {
        shape.paintInterior(canvas, rect, paint, textDirection: textDirection);
      } else {
        canvas.drawPath(
            shape.getOuterPath(rect, textDirection: textDirection), paint);
      }
    }
    shape.paint(canvas, rect, textDirection: textDirection);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ShapeDecoration ||
        other.color != color ||
        other.gradient != gradient ||
        other.shape != shape) {
      return false;
    }
    final List<BoxShadow>? a = shadows;
    final List<BoxShadow>? b = other.shadows;
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(color, gradient, shape,
      shadows == null ? null : Object.hashAll(shadows!));

  @override
  String toString() => 'ShapeDecoration(${<String>[
        if (color != null) 'color: $color',
        if (gradient != null) 'gradient: $gradient',
        if (shadows != null) 'shadows: $shadows',
        'shape: $shape',
      ].join(', ')})';
}

// ---------------------------------------------------------------------------
// Render node
// ---------------------------------------------------------------------------

/// Where a decoration is painted relative to the child - Flutter's
/// `DecorationPosition`.
enum DecorationPosition {
  /// Behind the child.
  background,

  /// In front of the child.
  foreground,
}

/// Paints a [Decoration] behind (or in front of) its child.
final class RenderDecoratedBox extends RenderProxyBox {
  RenderDecoratedBox({
    Decoration decoration = const BoxDecoration(),
    DecorationPosition position = DecorationPosition.background,
    TextDirection? textDirection,
    super.child,
  })  : _decoration = decoration,
        _position = position,
        _textDirection = textDirection;

  Decoration _decoration;
  DecorationPosition _position;
  TextDirection? _textDirection;

  Decoration get decoration => _decoration;

  set decoration(Decoration value) {
    if (value == _decoration) return;
    _decoration = value;
    // A decoration cannot move anything: it is drawn inside the box layout
    // already settled on.
    markNeedsPaint();
  }

  DecorationPosition get position => _position;

  set position(DecorationPosition value) {
    if (value == _position) return;
    _position = value;
    markNeedsPaint();
  }

  /// Resolves directional radii and borders; null reads left to right.
  TextDirection? get textDirection => _textDirection;

  set textDirection(TextDirection? value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsPaint();
  }

  /// The decoration's own hit test - a rounded or circular decoration is hit
  /// only inside its shape, as in Flutter.
  ///
  /// One deliberate difference: a [BoxDecoration] that paints nothing takes
  /// no pointer, so a bare `DecoratedBox()` cannot become a pointer trap. A
  /// fully transparent fill still does - a surface that is drawn is a
  /// surface, and going inert as its alpha reaches zero would make a fade
  /// change behaviour halfway through.
  @override
  bool hitTestSelf(Offset position) {
    final Decoration d = _decoration;
    if (d is BoxDecoration && d.isEmpty) return false;
    return d.hitTest(size, position, textDirection: _textDirection);
  }

  void _paintDecoration(DisplayList list, Offset offset) {
    final Decoration d = _decoration;
    if (d is BoxDecoration && d.isEmpty) return;
    final Canvas canvas = Canvas.forDisplayList(list);
    d.paintInto(
      canvas,
      Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height),
      textDirection: _textDirection,
    );
    canvas.close();
  }

  @override
  void paint(DisplayList list, Offset offset) {
    if (size.isEmpty) {
      super.paint(list, offset);
      return;
    }
    if (_position == DecorationPosition.background) {
      _paintDecoration(list, offset);
    }
    super.paint(list, offset);
    if (_position == DecorationPosition.foreground) {
      _paintDecoration(list, offset);
    }
  }
}
