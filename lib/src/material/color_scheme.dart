// Adapted from Flutter, packages/flutter/lib/src/material/color_scheme.dart.
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Material's colour roles - Flutter's `ColorScheme`.
library;

import 'dart:math' as math;

import '../graphics/color.dart' hide Colors;
import '../platform/system_settings.dart' show Brightness;
import 'colors.dart';
import 'hct.dart';

/// Which palette recipe [ColorScheme.fromSeed] follows.
///
/// [tonalSpot] (the default) and [neutral] follow Material's recipes; the
/// others pick the same palettes' hues and chromas as Material's but without
/// its temperature and "disliked colour" adjustments, so a scheme from them
/// is close to, not equal to, Flutter's.
enum DynamicSchemeVariant {
  tonalSpot,
  fidelity,
  monochrome,
  neutral,
  vibrant,
  expressive,
  content,
  rainbow,
  fruitSalad,
}

/// The colour roles of a Material theme - Flutter's `ColorScheme`, with every
/// role of Material 3 (containers, fixed colours, the surface containers).
///
/// [ColorScheme.fromSeed] builds Material 3's tonal-spot scheme from one
/// colour with the HCT colour space (`hct.dart`): the same recipe and tones
/// as Flutter, so `ColorScheme.fromSeed(seedColor: Colors.deepPurple)` gives
/// the colours a Flutter app shows, to within a unit in a channel. Two
/// differences: `contrastLevel` is accepted and ignored (the standard
/// contrast is used), and the variants other than
/// [DynamicSchemeVariant.tonalSpot] and [DynamicSchemeVariant.neutral] are
/// approximations; see [DynamicSchemeVariant].
///
/// `ColorScheme.light()` and `ColorScheme.dark()` are Flutter's - the
/// Material 2 baseline (purple 0xFF6200EE), not Material 3's. A Material 3
/// app gets its default scheme from `ThemeData()`.
class ColorScheme {
  /// A scheme with every role named; the optional ones fall back to a
  /// related required role, as in Flutter (`primaryContainer` to `primary`).
  const ColorScheme({
    required this.brightness,
    required this.primary,
    required this.onPrimary,
    Color? primaryContainer,
    Color? onPrimaryContainer,
    Color? primaryFixed,
    Color? primaryFixedDim,
    Color? onPrimaryFixed,
    Color? onPrimaryFixedVariant,
    required this.secondary,
    required this.onSecondary,
    Color? secondaryContainer,
    Color? onSecondaryContainer,
    Color? secondaryFixed,
    Color? secondaryFixedDim,
    Color? onSecondaryFixed,
    Color? onSecondaryFixedVariant,
    Color? tertiary,
    Color? onTertiary,
    Color? tertiaryContainer,
    Color? onTertiaryContainer,
    Color? tertiaryFixed,
    Color? tertiaryFixedDim,
    Color? onTertiaryFixed,
    Color? onTertiaryFixedVariant,
    required this.error,
    required this.onError,
    Color? errorContainer,
    Color? onErrorContainer,
    required this.surface,
    required this.onSurface,
    Color? surfaceDim,
    Color? surfaceBright,
    Color? surfaceContainerLowest,
    Color? surfaceContainerLow,
    Color? surfaceContainer,
    Color? surfaceContainerHigh,
    Color? surfaceContainerHighest,
    Color? onSurfaceVariant,
    Color? outline,
    Color? outlineVariant,
    Color? shadow,
    Color? scrim,
    Color? inverseSurface,
    Color? onInverseSurface,
    Color? inversePrimary,
    Color? surfaceTint,
    Color? background,
    Color? onBackground,
    Color? surfaceVariant,
  })  : _primaryContainer = primaryContainer,
        _onPrimaryContainer = onPrimaryContainer,
        _primaryFixed = primaryFixed,
        _primaryFixedDim = primaryFixedDim,
        _onPrimaryFixed = onPrimaryFixed,
        _onPrimaryFixedVariant = onPrimaryFixedVariant,
        _secondaryContainer = secondaryContainer,
        _onSecondaryContainer = onSecondaryContainer,
        _secondaryFixed = secondaryFixed,
        _secondaryFixedDim = secondaryFixedDim,
        _onSecondaryFixed = onSecondaryFixed,
        _onSecondaryFixedVariant = onSecondaryFixedVariant,
        _tertiary = tertiary,
        _onTertiary = onTertiary,
        _tertiaryContainer = tertiaryContainer,
        _onTertiaryContainer = onTertiaryContainer,
        _tertiaryFixed = tertiaryFixed,
        _tertiaryFixedDim = tertiaryFixedDim,
        _onTertiaryFixed = onTertiaryFixed,
        _onTertiaryFixedVariant = onTertiaryFixedVariant,
        _errorContainer = errorContainer,
        _onErrorContainer = onErrorContainer,
        _surfaceDim = surfaceDim,
        _surfaceBright = surfaceBright,
        _surfaceContainerLowest = surfaceContainerLowest,
        _surfaceContainerLow = surfaceContainerLow,
        _surfaceContainer = surfaceContainer,
        _surfaceContainerHigh = surfaceContainerHigh,
        _surfaceContainerHighest = surfaceContainerHighest,
        _onSurfaceVariant = onSurfaceVariant,
        _outline = outline,
        _outlineVariant = outlineVariant,
        _shadow = shadow,
        _scrim = scrim,
        _inverseSurface = inverseSurface,
        _onInverseSurface = onInverseSurface,
        _inversePrimary = inversePrimary,
        _surfaceTint = surfaceTint,
        _background = background,
        _onBackground = onBackground,
        _surfaceVariant = surfaceVariant;

  /// Flutter's Material 2 baseline light scheme (purple 0xFF6200EE). A
  /// Material 3 app gets its colours from `ThemeData()` or [ColorScheme.fromSeed]
  /// instead.
  const ColorScheme.light({
    this.brightness = Brightness.light,
    this.primary = const Color(0xFF6200EE),
    this.onPrimary = const Color(0xFFFFFFFF),
    Color? primaryContainer,
    Color? onPrimaryContainer,
    Color? primaryFixed,
    Color? primaryFixedDim,
    Color? onPrimaryFixed,
    Color? onPrimaryFixedVariant,
    this.secondary = const Color(0xFF03DAC6),
    this.onSecondary = const Color(0xFF000000),
    Color? secondaryContainer,
    Color? onSecondaryContainer,
    Color? secondaryFixed,
    Color? secondaryFixedDim,
    Color? onSecondaryFixed,
    Color? onSecondaryFixedVariant,
    Color? tertiary,
    Color? onTertiary,
    Color? tertiaryContainer,
    Color? onTertiaryContainer,
    Color? tertiaryFixed,
    Color? tertiaryFixedDim,
    Color? onTertiaryFixed,
    Color? onTertiaryFixedVariant,
    this.error = const Color(0xFFB00020),
    this.onError = const Color(0xFFFFFFFF),
    Color? errorContainer,
    Color? onErrorContainer,
    this.surface = const Color(0xFFFFFFFF),
    this.onSurface = const Color(0xFF000000),
    Color? surfaceDim,
    Color? surfaceBright,
    Color? surfaceContainerLowest,
    Color? surfaceContainerLow,
    Color? surfaceContainer,
    Color? surfaceContainerHigh,
    Color? surfaceContainerHighest,
    Color? onSurfaceVariant,
    Color? outline,
    Color? outlineVariant,
    Color? shadow,
    Color? scrim,
    Color? inverseSurface,
    Color? onInverseSurface,
    Color? inversePrimary,
    Color? surfaceTint,
    Color? background = const Color(0xFFFFFFFF),
    Color? onBackground = const Color(0xFF000000),
    Color? surfaceVariant,
  })  : _primaryContainer = primaryContainer,
        _onPrimaryContainer = onPrimaryContainer,
        _primaryFixed = primaryFixed,
        _primaryFixedDim = primaryFixedDim,
        _onPrimaryFixed = onPrimaryFixed,
        _onPrimaryFixedVariant = onPrimaryFixedVariant,
        _secondaryContainer = secondaryContainer,
        _onSecondaryContainer = onSecondaryContainer,
        _secondaryFixed = secondaryFixed,
        _secondaryFixedDim = secondaryFixedDim,
        _onSecondaryFixed = onSecondaryFixed,
        _onSecondaryFixedVariant = onSecondaryFixedVariant,
        _tertiary = tertiary,
        _onTertiary = onTertiary,
        _tertiaryContainer = tertiaryContainer,
        _onTertiaryContainer = onTertiaryContainer,
        _tertiaryFixed = tertiaryFixed,
        _tertiaryFixedDim = tertiaryFixedDim,
        _onTertiaryFixed = onTertiaryFixed,
        _onTertiaryFixedVariant = onTertiaryFixedVariant,
        _errorContainer = errorContainer,
        _onErrorContainer = onErrorContainer,
        _surfaceDim = surfaceDim,
        _surfaceBright = surfaceBright,
        _surfaceContainerLowest = surfaceContainerLowest,
        _surfaceContainerLow = surfaceContainerLow,
        _surfaceContainer = surfaceContainer,
        _surfaceContainerHigh = surfaceContainerHigh,
        _surfaceContainerHighest = surfaceContainerHighest,
        _onSurfaceVariant = onSurfaceVariant,
        _outline = outline,
        _outlineVariant = outlineVariant,
        _shadow = shadow,
        _scrim = scrim,
        _inverseSurface = inverseSurface,
        _onInverseSurface = onInverseSurface,
        _inversePrimary = inversePrimary,
        _surfaceTint = surfaceTint,
        _background = background,
        _onBackground = onBackground,
        _surfaceVariant = surfaceVariant;

  /// Flutter's Material 2 baseline dark scheme.
  const ColorScheme.dark({
    this.brightness = Brightness.dark,
    this.primary = const Color(0xFFBB86FC),
    this.onPrimary = const Color(0xFF000000),
    Color? primaryContainer,
    Color? onPrimaryContainer,
    Color? primaryFixed,
    Color? primaryFixedDim,
    Color? onPrimaryFixed,
    Color? onPrimaryFixedVariant,
    this.secondary = const Color(0xFF03DAC6),
    this.onSecondary = const Color(0xFF000000),
    Color? secondaryContainer,
    Color? onSecondaryContainer,
    Color? secondaryFixed,
    Color? secondaryFixedDim,
    Color? onSecondaryFixed,
    Color? onSecondaryFixedVariant,
    Color? tertiary,
    Color? onTertiary,
    Color? tertiaryContainer,
    Color? onTertiaryContainer,
    Color? tertiaryFixed,
    Color? tertiaryFixedDim,
    Color? onTertiaryFixed,
    Color? onTertiaryFixedVariant,
    this.error = const Color(0xFFCF6679),
    this.onError = const Color(0xFF000000),
    Color? errorContainer,
    Color? onErrorContainer,
    this.surface = const Color(0xFF121212),
    this.onSurface = const Color(0xFFFFFFFF),
    Color? surfaceDim,
    Color? surfaceBright,
    Color? surfaceContainerLowest,
    Color? surfaceContainerLow,
    Color? surfaceContainer,
    Color? surfaceContainerHigh,
    Color? surfaceContainerHighest,
    Color? onSurfaceVariant,
    Color? outline,
    Color? outlineVariant,
    Color? shadow,
    Color? scrim,
    Color? inverseSurface,
    Color? onInverseSurface,
    Color? inversePrimary,
    Color? surfaceTint,
    Color? background = const Color(0xFF121212),
    Color? onBackground = const Color(0xFFFFFFFF),
    Color? surfaceVariant,
  })  : _primaryContainer = primaryContainer,
        _onPrimaryContainer = onPrimaryContainer,
        _primaryFixed = primaryFixed,
        _primaryFixedDim = primaryFixedDim,
        _onPrimaryFixed = onPrimaryFixed,
        _onPrimaryFixedVariant = onPrimaryFixedVariant,
        _secondaryContainer = secondaryContainer,
        _onSecondaryContainer = onSecondaryContainer,
        _secondaryFixed = secondaryFixed,
        _secondaryFixedDim = secondaryFixedDim,
        _onSecondaryFixed = onSecondaryFixed,
        _onSecondaryFixedVariant = onSecondaryFixedVariant,
        _tertiary = tertiary,
        _onTertiary = onTertiary,
        _tertiaryContainer = tertiaryContainer,
        _onTertiaryContainer = onTertiaryContainer,
        _tertiaryFixed = tertiaryFixed,
        _tertiaryFixedDim = tertiaryFixedDim,
        _onTertiaryFixed = onTertiaryFixed,
        _onTertiaryFixedVariant = onTertiaryFixedVariant,
        _errorContainer = errorContainer,
        _onErrorContainer = onErrorContainer,
        _surfaceDim = surfaceDim,
        _surfaceBright = surfaceBright,
        _surfaceContainerLowest = surfaceContainerLowest,
        _surfaceContainerLow = surfaceContainerLow,
        _surfaceContainer = surfaceContainer,
        _surfaceContainerHigh = surfaceContainerHigh,
        _surfaceContainerHighest = surfaceContainerHighest,
        _onSurfaceVariant = onSurfaceVariant,
        _outline = outline,
        _outlineVariant = outlineVariant,
        _shadow = shadow,
        _scrim = scrim,
        _inverseSurface = inverseSurface,
        _onInverseSurface = onInverseSurface,
        _inversePrimary = inversePrimary,
        _surfaceTint = surfaceTint,
        _background = background,
        _onBackground = onBackground,
        _surfaceVariant = surfaceVariant;

  /// Material 3's scheme for [seedColor]: five tonal palettes from its hue,
  /// each role a fixed tone of one of them. Any role passed explicitly wins.
  factory ColorScheme.fromSeed({
    required Color seedColor,
    Brightness brightness = Brightness.light,
    DynamicSchemeVariant dynamicSchemeVariant = DynamicSchemeVariant.tonalSpot,
    double contrastLevel = 0.0,
    Color? primary,
    Color? onPrimary,
    Color? primaryContainer,
    Color? onPrimaryContainer,
    Color? primaryFixed,
    Color? primaryFixedDim,
    Color? onPrimaryFixed,
    Color? onPrimaryFixedVariant,
    Color? secondary,
    Color? onSecondary,
    Color? secondaryContainer,
    Color? onSecondaryContainer,
    Color? secondaryFixed,
    Color? secondaryFixedDim,
    Color? onSecondaryFixed,
    Color? onSecondaryFixedVariant,
    Color? tertiary,
    Color? onTertiary,
    Color? tertiaryContainer,
    Color? onTertiaryContainer,
    Color? tertiaryFixed,
    Color? tertiaryFixedDim,
    Color? onTertiaryFixed,
    Color? onTertiaryFixedVariant,
    Color? error,
    Color? onError,
    Color? errorContainer,
    Color? onErrorContainer,
    Color? surface,
    Color? onSurface,
    Color? surfaceDim,
    Color? surfaceBright,
    Color? surfaceContainerLowest,
    Color? surfaceContainerLow,
    Color? surfaceContainer,
    Color? surfaceContainerHigh,
    Color? surfaceContainerHighest,
    Color? onSurfaceVariant,
    Color? outline,
    Color? outlineVariant,
    Color? shadow,
    Color? scrim,
    Color? inverseSurface,
    Color? onInverseSurface,
    Color? inversePrimary,
    Color? surfaceTint,
    Color? background,
    Color? onBackground,
    Color? surfaceVariant,
  }) {
    if (contrastLevel < -1.0 || contrastLevel > 1.0) {
      throw ArgumentError.value(
          contrastLevel, 'contrastLevel', 'must be between -1.0 and 1.0');
    }
    final Map<String, Color> r =
        _seedRoles(seedColor, brightness, dynamicSchemeVariant);
    return ColorScheme(
      brightness: brightness,
      primary: primary ?? r['primary']!,
      onPrimary: onPrimary ?? r['onPrimary']!,
      primaryContainer: primaryContainer ?? r['primaryContainer']!,
      onPrimaryContainer: onPrimaryContainer ?? r['onPrimaryContainer']!,
      primaryFixed: primaryFixed ?? r['primaryFixed']!,
      primaryFixedDim: primaryFixedDim ?? r['primaryFixedDim']!,
      onPrimaryFixed: onPrimaryFixed ?? r['onPrimaryFixed']!,
      onPrimaryFixedVariant:
          onPrimaryFixedVariant ?? r['onPrimaryFixedVariant']!,
      secondary: secondary ?? r['secondary']!,
      onSecondary: onSecondary ?? r['onSecondary']!,
      secondaryContainer: secondaryContainer ?? r['secondaryContainer']!,
      onSecondaryContainer: onSecondaryContainer ?? r['onSecondaryContainer']!,
      secondaryFixed: secondaryFixed ?? r['secondaryFixed']!,
      secondaryFixedDim: secondaryFixedDim ?? r['secondaryFixedDim']!,
      onSecondaryFixed: onSecondaryFixed ?? r['onSecondaryFixed']!,
      onSecondaryFixedVariant:
          onSecondaryFixedVariant ?? r['onSecondaryFixedVariant']!,
      tertiary: tertiary ?? r['tertiary']!,
      onTertiary: onTertiary ?? r['onTertiary']!,
      tertiaryContainer: tertiaryContainer ?? r['tertiaryContainer']!,
      onTertiaryContainer: onTertiaryContainer ?? r['onTertiaryContainer']!,
      tertiaryFixed: tertiaryFixed ?? r['tertiaryFixed']!,
      tertiaryFixedDim: tertiaryFixedDim ?? r['tertiaryFixedDim']!,
      onTertiaryFixed: onTertiaryFixed ?? r['onTertiaryFixed']!,
      onTertiaryFixedVariant:
          onTertiaryFixedVariant ?? r['onTertiaryFixedVariant']!,
      error: error ?? r['error']!,
      onError: onError ?? r['onError']!,
      errorContainer: errorContainer ?? r['errorContainer']!,
      onErrorContainer: onErrorContainer ?? r['onErrorContainer']!,
      surface: surface ?? r['surface']!,
      onSurface: onSurface ?? r['onSurface']!,
      surfaceDim: surfaceDim ?? r['surfaceDim']!,
      surfaceBright: surfaceBright ?? r['surfaceBright']!,
      surfaceContainerLowest:
          surfaceContainerLowest ?? r['surfaceContainerLowest']!,
      surfaceContainerLow: surfaceContainerLow ?? r['surfaceContainerLow']!,
      surfaceContainer: surfaceContainer ?? r['surfaceContainer']!,
      surfaceContainerHigh: surfaceContainerHigh ?? r['surfaceContainerHigh']!,
      surfaceContainerHighest:
          surfaceContainerHighest ?? r['surfaceContainerHighest']!,
      onSurfaceVariant: onSurfaceVariant ?? r['onSurfaceVariant']!,
      outline: outline ?? r['outline']!,
      outlineVariant: outlineVariant ?? r['outlineVariant']!,
      shadow: shadow ?? r['shadow']!,
      scrim: scrim ?? r['scrim']!,
      inverseSurface: inverseSurface ?? r['inverseSurface']!,
      onInverseSurface: onInverseSurface ?? r['onInverseSurface']!,
      inversePrimary: inversePrimary ?? r['inversePrimary']!,
      surfaceTint: surfaceTint ?? r['surfaceTint']!,
      background: background ?? r['surface']!,
      onBackground: onBackground ?? r['onSurface']!,
      surfaceVariant: surfaceVariant ?? r['surfaceVariant']!,
    );
  }

  /// Flutter's Material 2 scheme from a [MaterialColor] swatch.
  factory ColorScheme.fromSwatch({
    MaterialColor primarySwatch = Colors.blue,
    Color? accentColor,
    Color? cardColor,
    Color? backgroundColor,
    Color? errorColor,
    Brightness brightness = Brightness.light,
  }) {
    final bool isDark = brightness == Brightness.dark;
    final bool primaryIsDark = _isDark(primarySwatch);
    final Color secondary =
        accentColor ?? (isDark ? Colors.tealAccent[200]! : primarySwatch);
    final bool secondaryIsDark = _isDark(secondary);
    const Color white = Colors.white;
    const Color black = Colors.black;
    return ColorScheme(
      brightness: brightness,
      primary: primarySwatch,
      primaryContainer: isDark ? Colors.black : primarySwatch[700]!,
      secondary: secondary,
      secondaryContainer:
          isDark ? Colors.tealAccent[700]! : primarySwatch[700]!,
      surface: cardColor ?? (isDark ? Colors.grey[800]! : Colors.white),
      background:
          backgroundColor ?? (isDark ? Colors.grey[700]! : primarySwatch[200]!),
      error: errorColor ?? Colors.red[700]!,
      onPrimary: primaryIsDark ? white : black,
      onSecondary: secondaryIsDark ? white : black,
      onSurface: isDark ? white : black,
      onBackground: primaryIsDark ? white : black,
      onError: isDark ? black : white,
    );
  }

  static bool _isDark(Color color) {
    final double l = color.computeLuminance();
    return (l + 0.05) * (l + 0.05) <= 0.15;
  }

  static Map<String, Color> _seedRoles(
    Color seed,
    Brightness brightness,
    DynamicSchemeVariant variant,
  ) {
    final Hct source = Hct.fromInt(seed.value);
    final double h = source.hue;
    final double c = source.chroma;
    double rotate(List<double> rotations) {
      const List<double> hues = <double>[
        0,
        41,
        61,
        101,
        131,
        181,
        251,
        301,
        360
      ];
      for (int i = 0; i < hues.length - 1; i++) {
        if (h >= hues[i] && h < hues[i + 1]) {
          return ColorUtils.sanitizeDegrees(h + rotations[i]);
        }
      }
      return h;
    }

    final (
      TonalPalette p,
      TonalPalette s,
      TonalPalette t,
      TonalPalette n,
      TonalPalette nv
    ) = switch (variant) {
      DynamicSchemeVariant.tonalSpot => (
          TonalPalette.of(h, 36),
          TonalPalette.of(h, 16),
          TonalPalette.of(ColorUtils.sanitizeDegrees(h + 60), 24),
          TonalPalette.of(h, 6),
          TonalPalette.of(h, 8),
        ),
      DynamicSchemeVariant.neutral => (
          TonalPalette.of(h, 12),
          TonalPalette.of(h, 8),
          TonalPalette.of(h, 16),
          TonalPalette.of(h, 2),
          TonalPalette.of(h, 2),
        ),
      DynamicSchemeVariant.monochrome => (
          TonalPalette.of(h, 0),
          TonalPalette.of(h, 0),
          TonalPalette.of(h, 0),
          TonalPalette.of(h, 0),
          TonalPalette.of(h, 0),
        ),
      DynamicSchemeVariant.vibrant => (
          TonalPalette.of(h, 200),
          TonalPalette.of(
              rotate(const <double>[18, 15, 10, 12, 15, 18, 15, 12, 12]), 24),
          TonalPalette.of(
              rotate(const <double>[35, 30, 20, 25, 30, 35, 30, 25, 25]), 32),
          TonalPalette.of(h, 10),
          TonalPalette.of(h, 12),
        ),
      DynamicSchemeVariant.expressive => (
          TonalPalette.of(ColorUtils.sanitizeDegrees(h + 240), 40),
          TonalPalette.of(
              rotate(const <double>[45, 95, 45, 20, 45, 90, 45, 45, 45]), 24),
          TonalPalette.of(
              rotate(const <double>[120, 120, 20, 45, 20, 15, 20, 120, 120]),
              32),
          TonalPalette.of(ColorUtils.sanitizeDegrees(h + 15), 8),
          TonalPalette.of(ColorUtils.sanitizeDegrees(h + 15), 12),
        ),
      DynamicSchemeVariant.rainbow => (
          TonalPalette.of(h, 48),
          TonalPalette.of(h, 16),
          TonalPalette.of(ColorUtils.sanitizeDegrees(h + 60), 24),
          TonalPalette.of(h, 0),
          TonalPalette.of(h, 0),
        ),
      DynamicSchemeVariant.fruitSalad => (
          TonalPalette.of(ColorUtils.sanitizeDegrees(h - 50), 48),
          TonalPalette.of(ColorUtils.sanitizeDegrees(h - 50), 36),
          TonalPalette.of(h, 36),
          TonalPalette.of(h, 10),
          TonalPalette.of(h, 16),
        ),
      DynamicSchemeVariant.fidelity || DynamicSchemeVariant.content => (
          TonalPalette.of(h, c),
          TonalPalette.of(h, math.max(c - 32.0, c * 0.5)),
          TonalPalette.of(ColorUtils.sanitizeDegrees(h + 60), c / 2),
          TonalPalette.of(h, c / 8.0),
          TonalPalette.of(h, c / 8.0 + 4.0),
        ),
    };
    final TonalPalette e = TonalPalette.of(25, 84);
    final bool dark = brightness == Brightness.dark;
    Color tone(TonalPalette palette, double light, double darkTone) =>
        Color(palette.tone(dark ? darkTone : light));
    final Map<String, Color> roles = <String, Color>{};
    void accent(String name, TonalPalette palette) {
      final String cap = name[0].toUpperCase() + name.substring(1);
      roles[name] = tone(palette, 40, 80);
      roles['on$cap'] = tone(palette, 100, 20);
      roles['${name}Container'] = tone(palette, 90, 30);
      roles['on${cap}Container'] = tone(palette, 30, 90);
      roles['${name}Fixed'] = tone(palette, 90, 90);
      roles['${name}FixedDim'] = tone(palette, 80, 80);
      roles['on${cap}Fixed'] = tone(palette, 10, 10);
      roles['on${cap}FixedVariant'] = tone(palette, 30, 30);
    }

    accent('primary', p);
    accent('secondary', s);
    accent('tertiary', t);
    roles['error'] = tone(e, 40, 80);
    roles['onError'] = tone(e, 100, 20);
    roles['errorContainer'] = tone(e, 90, 30);
    roles['onErrorContainer'] = tone(e, 30, 90);
    roles['surface'] = tone(n, 98, 6);
    roles['onSurface'] = tone(n, 10, 90);
    roles['surfaceDim'] = tone(n, 87, 6);
    roles['surfaceBright'] = tone(n, 98, 24);
    roles['surfaceContainerLowest'] = tone(n, 100, 4);
    roles['surfaceContainerLow'] = tone(n, 96, 10);
    roles['surfaceContainer'] = tone(n, 94, 12);
    roles['surfaceContainerHigh'] = tone(n, 92, 17);
    roles['surfaceContainerHighest'] = tone(n, 90, 22);
    roles['surfaceVariant'] = tone(nv, 90, 30);
    roles['onSurfaceVariant'] = tone(nv, 30, 80);
    roles['outline'] = tone(nv, 50, 60);
    roles['outlineVariant'] = tone(nv, 80, 30);
    roles['shadow'] = tone(n, 0, 0);
    roles['scrim'] = tone(n, 0, 0);
    roles['inverseSurface'] = tone(n, 20, 90);
    roles['onInverseSurface'] = tone(n, 95, 20);
    roles['inversePrimary'] = tone(p, 80, 40);
    roles['surfaceTint'] = roles['primary']!;
    return roles;
  }

  final Brightness brightness;
  final Color primary;
  final Color onPrimary;
  final Color secondary;
  final Color onSecondary;
  final Color error;
  final Color onError;
  final Color surface;
  final Color onSurface;
  final Color? _primaryContainer;
  final Color? _onPrimaryContainer;
  final Color? _primaryFixed;
  final Color? _primaryFixedDim;
  final Color? _onPrimaryFixed;
  final Color? _onPrimaryFixedVariant;
  final Color? _secondaryContainer;
  final Color? _onSecondaryContainer;
  final Color? _secondaryFixed;
  final Color? _secondaryFixedDim;
  final Color? _onSecondaryFixed;
  final Color? _onSecondaryFixedVariant;
  final Color? _tertiary;
  final Color? _onTertiary;
  final Color? _tertiaryContainer;
  final Color? _onTertiaryContainer;
  final Color? _tertiaryFixed;
  final Color? _tertiaryFixedDim;
  final Color? _onTertiaryFixed;
  final Color? _onTertiaryFixedVariant;
  final Color? _errorContainer;
  final Color? _onErrorContainer;
  final Color? _surfaceDim;
  final Color? _surfaceBright;
  final Color? _surfaceContainerLowest;
  final Color? _surfaceContainerLow;
  final Color? _surfaceContainer;
  final Color? _surfaceContainerHigh;
  final Color? _surfaceContainerHighest;
  final Color? _onSurfaceVariant;
  final Color? _outline;
  final Color? _outlineVariant;
  final Color? _shadow;
  final Color? _scrim;
  final Color? _inverseSurface;
  final Color? _onInverseSurface;
  final Color? _inversePrimary;
  final Color? _surfaceTint;
  final Color? _background;
  final Color? _onBackground;
  final Color? _surfaceVariant;

  Color get primaryContainer => _primaryContainer ?? primary;
  Color get onPrimaryContainer => _onPrimaryContainer ?? onPrimary;
  Color get primaryFixed => _primaryFixed ?? primary;
  Color get primaryFixedDim => _primaryFixedDim ?? primary;
  Color get onPrimaryFixed => _onPrimaryFixed ?? onPrimary;
  Color get onPrimaryFixedVariant => _onPrimaryFixedVariant ?? onPrimary;
  Color get secondaryContainer => _secondaryContainer ?? secondary;
  Color get onSecondaryContainer => _onSecondaryContainer ?? onSecondary;
  Color get secondaryFixed => _secondaryFixed ?? secondary;
  Color get secondaryFixedDim => _secondaryFixedDim ?? secondary;
  Color get onSecondaryFixed => _onSecondaryFixed ?? onSecondary;
  Color get onSecondaryFixedVariant => _onSecondaryFixedVariant ?? onSecondary;
  Color get tertiary => _tertiary ?? secondary;
  Color get onTertiary => _onTertiary ?? onSecondary;
  Color get tertiaryContainer => _tertiaryContainer ?? tertiary;
  Color get onTertiaryContainer => _onTertiaryContainer ?? onTertiary;
  Color get tertiaryFixed => _tertiaryFixed ?? tertiary;
  Color get tertiaryFixedDim => _tertiaryFixedDim ?? tertiary;
  Color get onTertiaryFixed => _onTertiaryFixed ?? onTertiary;
  Color get onTertiaryFixedVariant => _onTertiaryFixedVariant ?? onTertiary;
  Color get errorContainer => _errorContainer ?? error;
  Color get onErrorContainer => _onErrorContainer ?? onError;
  Color get surfaceDim => _surfaceDim ?? surface;
  Color get surfaceBright => _surfaceBright ?? surface;
  Color get surfaceContainerLowest => _surfaceContainerLowest ?? surface;
  Color get surfaceContainerLow => _surfaceContainerLow ?? surface;
  Color get surfaceContainer => _surfaceContainer ?? surface;
  Color get surfaceContainerHigh => _surfaceContainerHigh ?? surface;
  Color get surfaceContainerHighest => _surfaceContainerHighest ?? surface;
  Color get onSurfaceVariant => _onSurfaceVariant ?? onSurface;
  Color get outline => _outline ?? onBackground;
  Color get outlineVariant => _outlineVariant ?? onBackground;
  Color get shadow => _shadow ?? const Color(0xFF000000);
  Color get scrim => _scrim ?? const Color(0xFF000000);
  Color get inverseSurface => _inverseSurface ?? onSurface;
  Color get onInverseSurface => _onInverseSurface ?? surface;
  Color get inversePrimary => _inversePrimary ?? onPrimary;
  Color get surfaceTint => _surfaceTint ?? primary;
  Color get background => _background ?? surface;
  Color get onBackground => _onBackground ?? onSurface;
  Color get surfaceVariant => _surfaceVariant ?? surface;

  ColorScheme copyWith({
    Brightness? brightness,
    Color? primary,
    Color? onPrimary,
    Color? primaryContainer,
    Color? onPrimaryContainer,
    Color? primaryFixed,
    Color? primaryFixedDim,
    Color? onPrimaryFixed,
    Color? onPrimaryFixedVariant,
    Color? secondary,
    Color? onSecondary,
    Color? secondaryContainer,
    Color? onSecondaryContainer,
    Color? secondaryFixed,
    Color? secondaryFixedDim,
    Color? onSecondaryFixed,
    Color? onSecondaryFixedVariant,
    Color? tertiary,
    Color? onTertiary,
    Color? tertiaryContainer,
    Color? onTertiaryContainer,
    Color? tertiaryFixed,
    Color? tertiaryFixedDim,
    Color? onTertiaryFixed,
    Color? onTertiaryFixedVariant,
    Color? error,
    Color? onError,
    Color? errorContainer,
    Color? onErrorContainer,
    Color? surface,
    Color? onSurface,
    Color? surfaceDim,
    Color? surfaceBright,
    Color? surfaceContainerLowest,
    Color? surfaceContainerLow,
    Color? surfaceContainer,
    Color? surfaceContainerHigh,
    Color? surfaceContainerHighest,
    Color? onSurfaceVariant,
    Color? outline,
    Color? outlineVariant,
    Color? shadow,
    Color? scrim,
    Color? inverseSurface,
    Color? onInverseSurface,
    Color? inversePrimary,
    Color? surfaceTint,
    Color? background,
    Color? onBackground,
    Color? surfaceVariant,
  }) =>
      ColorScheme(
        brightness: brightness ?? this.brightness,
        primary: primary ?? this.primary,
        onPrimary: onPrimary ?? this.onPrimary,
        primaryContainer: primaryContainer ?? this.primaryContainer,
        onPrimaryContainer: onPrimaryContainer ?? this.onPrimaryContainer,
        primaryFixed: primaryFixed ?? this.primaryFixed,
        primaryFixedDim: primaryFixedDim ?? this.primaryFixedDim,
        onPrimaryFixed: onPrimaryFixed ?? this.onPrimaryFixed,
        onPrimaryFixedVariant:
            onPrimaryFixedVariant ?? this.onPrimaryFixedVariant,
        secondary: secondary ?? this.secondary,
        onSecondary: onSecondary ?? this.onSecondary,
        secondaryContainer: secondaryContainer ?? this.secondaryContainer,
        onSecondaryContainer: onSecondaryContainer ?? this.onSecondaryContainer,
        secondaryFixed: secondaryFixed ?? this.secondaryFixed,
        secondaryFixedDim: secondaryFixedDim ?? this.secondaryFixedDim,
        onSecondaryFixed: onSecondaryFixed ?? this.onSecondaryFixed,
        onSecondaryFixedVariant:
            onSecondaryFixedVariant ?? this.onSecondaryFixedVariant,
        tertiary: tertiary ?? this.tertiary,
        onTertiary: onTertiary ?? this.onTertiary,
        tertiaryContainer: tertiaryContainer ?? this.tertiaryContainer,
        onTertiaryContainer: onTertiaryContainer ?? this.onTertiaryContainer,
        tertiaryFixed: tertiaryFixed ?? this.tertiaryFixed,
        tertiaryFixedDim: tertiaryFixedDim ?? this.tertiaryFixedDim,
        onTertiaryFixed: onTertiaryFixed ?? this.onTertiaryFixed,
        onTertiaryFixedVariant:
            onTertiaryFixedVariant ?? this.onTertiaryFixedVariant,
        error: error ?? this.error,
        onError: onError ?? this.onError,
        errorContainer: errorContainer ?? this.errorContainer,
        onErrorContainer: onErrorContainer ?? this.onErrorContainer,
        surface: surface ?? this.surface,
        onSurface: onSurface ?? this.onSurface,
        surfaceDim: surfaceDim ?? this.surfaceDim,
        surfaceBright: surfaceBright ?? this.surfaceBright,
        surfaceContainerLowest:
            surfaceContainerLowest ?? this.surfaceContainerLowest,
        surfaceContainerLow: surfaceContainerLow ?? this.surfaceContainerLow,
        surfaceContainer: surfaceContainer ?? this.surfaceContainer,
        surfaceContainerHigh: surfaceContainerHigh ?? this.surfaceContainerHigh,
        surfaceContainerHighest:
            surfaceContainerHighest ?? this.surfaceContainerHighest,
        onSurfaceVariant: onSurfaceVariant ?? this.onSurfaceVariant,
        outline: outline ?? this.outline,
        outlineVariant: outlineVariant ?? this.outlineVariant,
        shadow: shadow ?? this.shadow,
        scrim: scrim ?? this.scrim,
        inverseSurface: inverseSurface ?? this.inverseSurface,
        onInverseSurface: onInverseSurface ?? this.onInverseSurface,
        inversePrimary: inversePrimary ?? this.inversePrimary,
        surfaceTint: surfaceTint ?? this.surfaceTint,
        background: background ?? this.background,
        onBackground: onBackground ?? this.onBackground,
        surfaceVariant: surfaceVariant ?? this.surfaceVariant,
      );

  /// The scheme [t] of the way from [a] to [b], role by role.
  static ColorScheme lerp(ColorScheme a, ColorScheme b, double t) {
    if (identical(a, b)) return a;
    return ColorScheme(
      brightness: t < 0.5 ? a.brightness : b.brightness,
      primary: Color.lerp(a.primary, b.primary, t)!,
      onPrimary: Color.lerp(a.onPrimary, b.onPrimary, t)!,
      primaryContainer: Color.lerp(a.primaryContainer, b.primaryContainer, t)!,
      onPrimaryContainer:
          Color.lerp(a.onPrimaryContainer, b.onPrimaryContainer, t)!,
      primaryFixed: Color.lerp(a.primaryFixed, b.primaryFixed, t)!,
      primaryFixedDim: Color.lerp(a.primaryFixedDim, b.primaryFixedDim, t)!,
      onPrimaryFixed: Color.lerp(a.onPrimaryFixed, b.onPrimaryFixed, t)!,
      onPrimaryFixedVariant:
          Color.lerp(a.onPrimaryFixedVariant, b.onPrimaryFixedVariant, t)!,
      secondary: Color.lerp(a.secondary, b.secondary, t)!,
      onSecondary: Color.lerp(a.onSecondary, b.onSecondary, t)!,
      secondaryContainer:
          Color.lerp(a.secondaryContainer, b.secondaryContainer, t)!,
      onSecondaryContainer:
          Color.lerp(a.onSecondaryContainer, b.onSecondaryContainer, t)!,
      secondaryFixed: Color.lerp(a.secondaryFixed, b.secondaryFixed, t)!,
      secondaryFixedDim:
          Color.lerp(a.secondaryFixedDim, b.secondaryFixedDim, t)!,
      onSecondaryFixed: Color.lerp(a.onSecondaryFixed, b.onSecondaryFixed, t)!,
      onSecondaryFixedVariant:
          Color.lerp(a.onSecondaryFixedVariant, b.onSecondaryFixedVariant, t)!,
      tertiary: Color.lerp(a.tertiary, b.tertiary, t)!,
      onTertiary: Color.lerp(a.onTertiary, b.onTertiary, t)!,
      tertiaryContainer:
          Color.lerp(a.tertiaryContainer, b.tertiaryContainer, t)!,
      onTertiaryContainer:
          Color.lerp(a.onTertiaryContainer, b.onTertiaryContainer, t)!,
      tertiaryFixed: Color.lerp(a.tertiaryFixed, b.tertiaryFixed, t)!,
      tertiaryFixedDim: Color.lerp(a.tertiaryFixedDim, b.tertiaryFixedDim, t)!,
      onTertiaryFixed: Color.lerp(a.onTertiaryFixed, b.onTertiaryFixed, t)!,
      onTertiaryFixedVariant:
          Color.lerp(a.onTertiaryFixedVariant, b.onTertiaryFixedVariant, t)!,
      error: Color.lerp(a.error, b.error, t)!,
      onError: Color.lerp(a.onError, b.onError, t)!,
      errorContainer: Color.lerp(a.errorContainer, b.errorContainer, t)!,
      onErrorContainer: Color.lerp(a.onErrorContainer, b.onErrorContainer, t)!,
      surface: Color.lerp(a.surface, b.surface, t)!,
      onSurface: Color.lerp(a.onSurface, b.onSurface, t)!,
      surfaceDim: Color.lerp(a.surfaceDim, b.surfaceDim, t)!,
      surfaceBright: Color.lerp(a.surfaceBright, b.surfaceBright, t)!,
      surfaceContainerLowest:
          Color.lerp(a.surfaceContainerLowest, b.surfaceContainerLowest, t)!,
      surfaceContainerLow:
          Color.lerp(a.surfaceContainerLow, b.surfaceContainerLow, t)!,
      surfaceContainer: Color.lerp(a.surfaceContainer, b.surfaceContainer, t)!,
      surfaceContainerHigh:
          Color.lerp(a.surfaceContainerHigh, b.surfaceContainerHigh, t)!,
      surfaceContainerHighest:
          Color.lerp(a.surfaceContainerHighest, b.surfaceContainerHighest, t)!,
      onSurfaceVariant: Color.lerp(a.onSurfaceVariant, b.onSurfaceVariant, t)!,
      outline: Color.lerp(a.outline, b.outline, t)!,
      outlineVariant: Color.lerp(a.outlineVariant, b.outlineVariant, t)!,
      shadow: Color.lerp(a.shadow, b.shadow, t)!,
      scrim: Color.lerp(a.scrim, b.scrim, t)!,
      inverseSurface: Color.lerp(a.inverseSurface, b.inverseSurface, t)!,
      onInverseSurface: Color.lerp(a.onInverseSurface, b.onInverseSurface, t)!,
      inversePrimary: Color.lerp(a.inversePrimary, b.inversePrimary, t)!,
      surfaceTint: Color.lerp(a.surfaceTint, b.surfaceTint, t)!,
      background: Color.lerp(a.background, b.background, t)!,
      onBackground: Color.lerp(a.onBackground, b.onBackground, t)!,
      surfaceVariant: Color.lerp(a.surfaceVariant, b.surfaceVariant, t)!,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ColorScheme &&
      other.brightness == brightness &&
      other.primary == primary &&
      other.onPrimary == onPrimary &&
      other.primaryContainer == primaryContainer &&
      other.onPrimaryContainer == onPrimaryContainer &&
      other.primaryFixed == primaryFixed &&
      other.primaryFixedDim == primaryFixedDim &&
      other.onPrimaryFixed == onPrimaryFixed &&
      other.onPrimaryFixedVariant == onPrimaryFixedVariant &&
      other.secondary == secondary &&
      other.onSecondary == onSecondary &&
      other.secondaryContainer == secondaryContainer &&
      other.onSecondaryContainer == onSecondaryContainer &&
      other.secondaryFixed == secondaryFixed &&
      other.secondaryFixedDim == secondaryFixedDim &&
      other.onSecondaryFixed == onSecondaryFixed &&
      other.onSecondaryFixedVariant == onSecondaryFixedVariant &&
      other.tertiary == tertiary &&
      other.onTertiary == onTertiary &&
      other.tertiaryContainer == tertiaryContainer &&
      other.onTertiaryContainer == onTertiaryContainer &&
      other.tertiaryFixed == tertiaryFixed &&
      other.tertiaryFixedDim == tertiaryFixedDim &&
      other.onTertiaryFixed == onTertiaryFixed &&
      other.onTertiaryFixedVariant == onTertiaryFixedVariant &&
      other.error == error &&
      other.onError == onError &&
      other.errorContainer == errorContainer &&
      other.onErrorContainer == onErrorContainer &&
      other.surface == surface &&
      other.onSurface == onSurface &&
      other.surfaceDim == surfaceDim &&
      other.surfaceBright == surfaceBright &&
      other.surfaceContainerLowest == surfaceContainerLowest &&
      other.surfaceContainerLow == surfaceContainerLow &&
      other.surfaceContainer == surfaceContainer &&
      other.surfaceContainerHigh == surfaceContainerHigh &&
      other.surfaceContainerHighest == surfaceContainerHighest &&
      other.onSurfaceVariant == onSurfaceVariant &&
      other.outline == outline &&
      other.outlineVariant == outlineVariant &&
      other.shadow == shadow &&
      other.scrim == scrim &&
      other.inverseSurface == inverseSurface &&
      other.onInverseSurface == onInverseSurface &&
      other.inversePrimary == inversePrimary &&
      other.surfaceTint == surfaceTint &&
      other.background == background &&
      other.onBackground == onBackground &&
      other.surfaceVariant == surfaceVariant;

  @override
  int get hashCode => Object.hashAll(<Object>[
        brightness,
        primary,
        onPrimary,
        primaryContainer,
        onPrimaryContainer,
        primaryFixed,
        primaryFixedDim,
        onPrimaryFixed,
        onPrimaryFixedVariant,
        secondary,
        onSecondary,
        secondaryContainer,
        onSecondaryContainer,
        secondaryFixed,
        secondaryFixedDim,
        onSecondaryFixed,
        onSecondaryFixedVariant,
        tertiary,
        onTertiary,
        tertiaryContainer,
        onTertiaryContainer,
        tertiaryFixed,
        tertiaryFixedDim,
        onTertiaryFixed,
        onTertiaryFixedVariant,
        error,
        onError,
        errorContainer,
        onErrorContainer,
        surface,
        onSurface,
        surfaceDim,
        surfaceBright,
        surfaceContainerLowest,
        surfaceContainerLow,
        surfaceContainer,
        surfaceContainerHigh,
        surfaceContainerHighest,
        onSurfaceVariant,
        outline,
        outlineVariant,
        shadow,
        scrim,
        inverseSurface,
        onInverseSurface,
        inversePrimary,
        surfaceTint,
        background,
        onBackground,
        surfaceVariant
      ]);
}
