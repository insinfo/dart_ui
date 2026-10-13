// Adapted from Flutter, packages/flutter/lib/src/material/material.dart and
// constants.dart.
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// The `Material` surface: colour, shape, elevation and the text style
/// everything on it inherits.
library;

import '../geometry/offset.dart';
import '../geometry/rrect.dart' show Radius;
import '../graphics/color.dart' hide Colors;
import '../layout/border_radius.dart';
import '../layout/borders.dart';
import '../layout/canvas.dart' show Clip;
import '../layout/decoration.dart';
import '../layout/edge_insets.dart';
import '../widgets/basic.dart' show DefaultTextStyle;
import '../widgets/clip_widgets.dart';
import '../widgets/popup_menu.dart' show kMinInteractiveDimension;
import '../widgets/proxy.dart';
import '../widgets/theme.dart' show TextStyle;
import '../widgets/widget.dart';
import 'theme.dart';
import 'theme_data.dart';

/// The height of a toolbar: Flutter's `kToolbarHeight` (56; Material 3's
/// `AppBar` is 64 by its own default).
const double kToolbarHeight = 56.0;

/// The height of a [BottomNavigationBar].
const double kBottomNavigationBarHeight = 56.0;

/// The height of a [TabBar] with text only.
const double kTextTabBarHeight = kMinInteractiveDimension;

/// How long a theme change animates.
const Duration kThemeChangeDuration = Duration(milliseconds: 200);

/// How long a Material state change animates.
const Duration kThemeAnimationDuration = Duration(milliseconds: 200);

/// The radius of an ink splash with no box to fill.
const double kRadialReactionRadius = 20.0;

/// How long a radial reaction animates.
const Duration kRadialReactionDuration = Duration(milliseconds: 100);

/// The alpha of a radial reaction.
const int kRadialReactionAlpha = 0x1F;

/// How long a tab change animates.
const Duration kTabScrollDuration = Duration(milliseconds: 300);

/// The padding around a tab's label.
const EdgeInsets kTabLabelPadding = EdgeInsets.symmetric(horizontal: 16.0);

/// The padding of a [Material] list item, and the gutter of most layouts.
const EdgeInsets kMaterialListPadding = EdgeInsets.symmetric(vertical: 8.0);

/// The kinds of [Material], each with its own default shape and colour.
enum MaterialType {
  /// A rectangle in the theme's canvas colour.
  canvas,

  /// A rounded rectangle in the theme's card colour.
  card,

  /// A circle; for floating action buttons.
  circle,

  /// A rounded rectangle; for buttons.
  button,

  /// Nothing drawn: ink and text style only.
  transparency,
}

/// The corner radii of each [MaterialType] - Flutter's `kMaterialEdges`.
const Map<MaterialType, BorderRadius?> kMaterialEdges =
    <MaterialType, BorderRadius?>{
  MaterialType.canvas: null,
  MaterialType.card: BorderRadius.all(Radius.circular(2.0)),
  MaterialType.circle: null,
  MaterialType.button: BorderRadius.all(Radius.circular(2.0)),
  MaterialType.transparency: null,
};

/// The shadows of a surface raised by [elevation] logical pixels.
///
/// Material 3's two-layer shadow - a tight key light and a wide ambient one -
/// interpolated between its five elevation levels (1, 3, 6, 8 and 12). Flutter
/// draws the same with the engine's elevation shadow; this is the box shadow
/// that matches it.
List<BoxShadow> materialShadows(double elevation, Color shadowColor) {
  if (elevation <= 0 || shadowColor.alpha == 0) return const <BoxShadow>[];
  // (elevation, key y, key blur, ambient y, ambient blur, ambient spread)
  const List<List<double>> levels = <List<double>>[
    <double>[0, 0, 0, 0, 0, 0],
    <double>[1, 1, 2, 1, 3, 1],
    <double>[3, 1, 2, 2, 6, 2],
    <double>[6, 1, 3, 4, 8, 3],
    <double>[8, 2, 3, 6, 10, 4],
    <double>[12, 4, 4, 8, 12, 6],
    <double>[24, 8, 8, 16, 24, 12],
  ];
  final double e = elevation.clamp(0.0, 24.0);
  int i = 1;
  while (i < levels.length - 1 && levels[i][0] < e) {
    i++;
  }
  final List<double> a = levels[i - 1];
  final List<double> b = levels[i];
  final double t = b[0] == a[0] ? 1.0 : (e - a[0]) / (b[0] - a[0]);
  double at(int k) => a[k] + (b[k] - a[k]) * t;
  final int alpha = shadowColor.alpha;
  return <BoxShadow>[
    BoxShadow(
      color: shadowColor.withAlpha((alpha * 0.30).round()),
      offset: Offset(0, at(1)),
      blurRadius: at(2),
    ),
    BoxShadow(
      color: shadowColor.withAlpha((alpha * 0.15).round()),
      offset: Offset(0, at(3)),
      blurRadius: at(4),
      spreadRadius: at(5),
    ),
  ];
}

/// A piece of Material - Flutter's `Material`.
///
/// Paints its [color] in its [shape], casts the shadow of its [elevation],
/// clips its child when [clipBehavior] says so, and sets the
/// [DefaultTextStyle] (the theme's `bodyMedium`, or [textStyle]) for
/// everything on it.
///
/// Differences from Flutter:
///
///   * ink (`InkWell`, `InkResponse`) is painted by the ink widget itself,
///     under its child, rather than on the nearest `Material`; the look is the
///     same as long as nothing opaque sits between the two, which in Flutter
///     would hide the ink as well;
///   * a change of [color], [elevation] or [shape] does not animate
///     ([animationDuration] is accepted and ignored);
///   * [surfaceTintColor] tints by elevation as Material 3 did before Flutter
///     3.22 only when it is given; by default (null) there is no tint, which
///     is what Flutter's Material 3 components do today.
class Material extends StatelessWidget {
  const Material({
    super.key,
    this.type = MaterialType.canvas,
    this.elevation = 0.0,
    this.color,
    this.shadowColor,
    this.surfaceTintColor,
    this.textStyle,
    this.borderRadius,
    this.shape,
    this.borderOnForeground = true,
    this.clipBehavior = Clip.none,
    this.animationDuration = kThemeChangeDuration,
    this.child,
  }) : assert(!(shape != null && borderRadius != null),
            'give the shape or the borderRadius, not both');

  final MaterialType type;
  final double elevation;
  final Color? color;
  final Color? shadowColor;
  final Color? surfaceTintColor;
  final TextStyle? textStyle;
  final BorderRadiusGeometry? borderRadius;
  final ShapeBorder? shape;
  final bool borderOnForeground;
  final Clip clipBehavior;
  final Duration animationDuration;
  final Widget? child;

  /// The splash radius of an ink response with no radius of its own.
  static const double defaultSplashRadius = 35.0;

  ShapeBorder _shape() {
    final ShapeBorder? given = shape;
    if (given != null) return given;
    final BorderRadiusGeometry? radius = borderRadius;
    if (radius != null) return RoundedRectangleBorder(borderRadius: radius);
    return switch (type) {
      MaterialType.circle => const CircleBorder(),
      MaterialType.canvas ||
      MaterialType.transparency =>
        const RoundedRectangleBorder(),
      MaterialType.card || MaterialType.button => RoundedRectangleBorder(
          borderRadius: kMaterialEdges[type]!,
        ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    Color? background = color ??
        switch (type) {
          MaterialType.canvas => theme.canvasColor,
          MaterialType.card => theme.cardColor,
          MaterialType.transparency => null,
          MaterialType.circle || MaterialType.button => null,
        };
    final Color? tint = surfaceTintColor;
    if (background != null && tint != null && elevation > 0) {
      background = Color.alphaBlend(
          tint.withOpacity(_tintOpacity(elevation)), background);
    }
    Widget? contents = child;
    if (contents != null) {
      contents = DefaultTextStyle(
        style:
            (theme.textTheme.bodyMedium ?? const TextStyle()).merge(textStyle),
        child: contents,
      );
    }
    final ShapeBorder shape = _shape();
    if (type == MaterialType.transparency) {
      return clipBehavior == Clip.none || contents == null
          ? contents ?? const _Nothing()
          : ClipPath.shape(
              shape: shape, clipBehavior: clipBehavior, child: contents);
    }
    if (contents != null && clipBehavior != Clip.none) {
      contents = ClipPath.shape(
          shape: shape, clipBehavior: clipBehavior, child: contents);
    }
    // The outline goes over the content when [borderOnForeground], so a
    // child that fills the shape does not hide it.
    final ShapeBorder fillShape;
    final ShapeBorder? outline;
    if (borderOnForeground &&
        shape is OutlinedBorder &&
        shape.side.isVisible &&
        contents != null) {
      fillShape = shape.copyWith(side: BorderSide.none);
      outline = shape;
    } else {
      fillShape = shape;
      outline = null;
    }
    Widget result = DecoratedBox(
      decoration: ShapeDecoration(
        color: background,
        shape: fillShape,
        shadows: materialShadows(elevation, shadowColor ?? theme.shadowColor),
      ),
      child: contents,
    );
    if (outline != null) {
      result = DecoratedBox(
        decoration: ShapeDecoration(shape: outline),
        position: DecorationPosition.foreground,
        child: result,
      );
    }
    return result;
  }

  static double _tintOpacity(double elevation) {
    // Material 3's tint by elevation level.
    if (elevation < 1) return 0.0;
    if (elevation < 3) return 0.05 + (elevation - 1) / 2 * 0.03;
    if (elevation < 6) return 0.08 + (elevation - 3) / 3 * 0.03;
    if (elevation < 8) return 0.11 + (elevation - 6) / 2 * 0.01;
    if (elevation < 12) return 0.12 + (elevation - 8) / 4 * 0.02;
    return 0.14;
  }
}

final class _Nothing extends StatelessWidget {
  const _Nothing();

  @override
  Widget build(BuildContext context) => const DecoratedBox(
        decoration: BoxDecoration(),
      );
}
