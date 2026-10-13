// Adapted from Flutter, packages/flutter/lib/src/material/text_theme.dart and
// typography.dart.
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Material's type scale - Flutter's `TextTheme` and `Typography`.
library;

import '../graphics/color.dart' hide Colors;
import '../platform/system_settings.dart' show Brightness;
import '../text/text_decoration.dart';
import '../widgets/theme.dart' show FontWeight, TextStyle;
import 'color_scheme.dart';
import 'target_platform.dart';

/// The fifteen roles of Material 3's type scale - Flutter's `TextTheme`.
///
/// Every role is nullable, as in Flutter: a `TextTheme()` names nothing, and
/// the theme fills the gaps from [Typography] when it is built, so
/// `Theme.of(context).textTheme.headlineMedium` is never null in an app.
///
/// In `package:dart_ui/material.dart` this replaces dart_ui's own
/// `TextTheme`, a derived seven-step scale for desktop controls; the Material
/// theme maps itself onto that one so dart_ui's controls inside a Material
/// app take its body size and face.
class TextTheme {
  const TextTheme({
    this.displayLarge,
    this.displayMedium,
    this.displaySmall,
    this.headlineLarge,
    this.headlineMedium,
    this.headlineSmall,
    this.titleLarge,
    this.titleMedium,
    this.titleSmall,
    this.bodyLarge,
    this.bodyMedium,
    this.bodySmall,
    this.labelLarge,
    this.labelMedium,
    this.labelSmall,
  });

  final TextStyle? displayLarge;
  final TextStyle? displayMedium;
  final TextStyle? displaySmall;
  final TextStyle? headlineLarge;
  final TextStyle? headlineMedium;
  final TextStyle? headlineSmall;
  final TextStyle? titleLarge;
  final TextStyle? titleMedium;
  final TextStyle? titleSmall;
  final TextStyle? bodyLarge;
  final TextStyle? bodyMedium;
  final TextStyle? bodySmall;
  final TextStyle? labelLarge;
  final TextStyle? labelMedium;
  final TextStyle? labelSmall;

  List<TextStyle?> get _styles => <TextStyle?>[
        displayLarge,
        displayMedium,
        displaySmall,
        headlineLarge,
        headlineMedium,
        headlineSmall,
        titleLarge,
        titleMedium,
        titleSmall,
        bodyLarge,
        bodyMedium,
        bodySmall,
        labelLarge,
        labelMedium,
        labelSmall,
      ];

  static TextTheme _fromList(List<TextStyle?> s) => TextTheme(
        displayLarge: s[0],
        displayMedium: s[1],
        displaySmall: s[2],
        headlineLarge: s[3],
        headlineMedium: s[4],
        headlineSmall: s[5],
        titleLarge: s[6],
        titleMedium: s[7],
        titleSmall: s[8],
        bodyLarge: s[9],
        bodyMedium: s[10],
        bodySmall: s[11],
        labelLarge: s[12],
        labelMedium: s[13],
        labelSmall: s[14],
      );

  TextTheme copyWith({
    TextStyle? displayLarge,
    TextStyle? displayMedium,
    TextStyle? displaySmall,
    TextStyle? headlineLarge,
    TextStyle? headlineMedium,
    TextStyle? headlineSmall,
    TextStyle? titleLarge,
    TextStyle? titleMedium,
    TextStyle? titleSmall,
    TextStyle? bodyLarge,
    TextStyle? bodyMedium,
    TextStyle? bodySmall,
    TextStyle? labelLarge,
    TextStyle? labelMedium,
    TextStyle? labelSmall,
  }) =>
      TextTheme(
        displayLarge: displayLarge ?? this.displayLarge,
        displayMedium: displayMedium ?? this.displayMedium,
        displaySmall: displaySmall ?? this.displaySmall,
        headlineLarge: headlineLarge ?? this.headlineLarge,
        headlineMedium: headlineMedium ?? this.headlineMedium,
        headlineSmall: headlineSmall ?? this.headlineSmall,
        titleLarge: titleLarge ?? this.titleLarge,
        titleMedium: titleMedium ?? this.titleMedium,
        titleSmall: titleSmall ?? this.titleSmall,
        bodyLarge: bodyLarge ?? this.bodyLarge,
        bodyMedium: bodyMedium ?? this.bodyMedium,
        bodySmall: bodySmall ?? this.bodySmall,
        labelLarge: labelLarge ?? this.labelLarge,
        labelMedium: labelMedium ?? this.labelMedium,
        labelSmall: labelSmall ?? this.labelSmall,
      );

  /// Each role of [other] merged over the same role here: what [other]
  /// names wins, what it leaves null is kept.
  TextTheme merge(TextTheme? other) {
    if (other == null) return this;
    final List<TextStyle?> mine = _styles;
    final List<TextStyle?> theirs = other._styles;
    return _fromList(<TextStyle?>[
      for (int i = 0; i < mine.length; i++)
        mine[i]?.merge(theirs[i]) ?? theirs[i],
    ]);
  }

  /// Every role with the same change applied: a face, a size scale, colours.
  ///
  /// [displayColor] colours the display and headline roles, [bodyColor] the
  /// title, body and label roles, as in Flutter. `fontFamilyFallback` and
  /// `package` are accepted and ignored: fonts here are registered by family
  /// name.
  TextTheme apply({
    String? fontFamily,
    List<String>? fontFamilyFallback,
    String? package,
    double fontSizeFactor = 1.0,
    double fontSizeDelta = 0.0,
    double letterSpacingFactor = 1.0,
    double letterSpacingDelta = 0.0,
    double wordSpacingFactor = 1.0,
    double wordSpacingDelta = 0.0,
    double heightFactor = 1.0,
    double heightDelta = 0.0,
    Color? displayColor,
    Color? bodyColor,
    TextDecoration? decoration,
    Color? decorationColor,
    TextDecorationStyle? decorationStyle,
  }) {
    TextStyle? one(TextStyle? s, Color? color) {
      if (s == null) return null;
      final double? size = s.fontSize;
      final double? spacing = s.letterSpacing;
      final double? words = s.wordSpacing;
      final double? height = s.height;
      return s.copyWith(
        color: color,
        fontFamily: fontFamily,
        fontSize: size == null ? null : size * fontSizeFactor + fontSizeDelta,
        letterSpacing: spacing == null
            ? null
            : spacing * letterSpacingFactor + letterSpacingDelta,
        wordSpacing:
            words == null ? null : words * wordSpacingFactor + wordSpacingDelta,
        height: height == null ? null : height * heightFactor + heightDelta,
        decoration: decoration,
        decorationColor: decorationColor,
        decorationStyle: decorationStyle,
      );
    }

    final List<TextStyle?> s = _styles;
    return _fromList(<TextStyle?>[
      for (int i = 0; i < s.length; i++)
        one(s[i], i < 6 ? displayColor : bodyColor),
    ]);
  }

  /// The theme [t] of the way from [a] to [b]; a role switches at the middle.
  static TextTheme lerp(TextTheme? a, TextTheme? b, double t) {
    if (identical(a, b) && a != null) return a;
    return (t < 0.5 ? a : b) ?? const TextTheme();
  }

  @override
  bool operator ==(Object other) {
    if (other is! TextTheme) return false;
    final List<TextStyle?> mine = _styles;
    final List<TextStyle?> theirs = other._styles;
    for (int i = 0; i < mine.length; i++) {
      if (mine[i] != theirs[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_styles);
}

/// Which family of type scales a [TextTheme] belongs to.
enum ScriptCategory { englishLike, dense, tall }

/// The type scales a theme is built from - Flutter's `Typography`.
///
/// [black] and [white] carry the colours (dark text for light themes and
/// light text for dark ones); [englishLike], [dense] and [tall] the sizes
/// and weights. `ThemeData` merges the colour theme for its brightness over
/// the size theme.
///
/// Faces are not chosen per platform as Flutter does (Roboto, San Francisco,
/// Segoe UI): every role uses the framework's interface face unless the theme
/// names a `fontFamily`, so text metrics are the same on every host.
class Typography {
  const Typography._(
      this.black, this.white, this.englishLike, this.dense, this.tall);

  /// Material 3's type scale, coloured from [colorScheme].
  factory Typography.material2021({
    TargetPlatform? platform = TargetPlatform.android,
    ColorScheme colorScheme = const ColorScheme.light(),
    TextTheme? black,
    TextTheme? white,
    TextTheme? englishLike,
    TextTheme? dense,
    TextTheme? tall,
  }) {
    final Color dark = colorScheme.brightness == Brightness.light
        ? colorScheme.onSurface
        : colorScheme.surface;
    final Color light = colorScheme.brightness == Brightness.light
        ? colorScheme.surface
        : colorScheme.onSurface;
    return Typography._(
      (black ?? blackMountainView)
          .apply(displayColor: dark, bodyColor: dark, decorationColor: dark),
      (white ?? whiteMountainView)
          .apply(displayColor: light, bodyColor: light, decorationColor: light),
      englishLike ?? englishLike2021,
      dense ?? dense2021,
      tall ?? tall2021,
    );
  }

  /// Material 2's 2018 scale. Kept for apps that set `useMaterial3: false`;
  /// the sizes are 2018's, the roles named with 2021's names, as in Flutter.
  factory Typography.material2018({
    TargetPlatform? platform = TargetPlatform.android,
    TextTheme? black,
    TextTheme? white,
    TextTheme? englishLike,
    TextTheme? dense,
    TextTheme? tall,
  }) =>
      Typography._(
        black ?? blackMountainView,
        white ?? whiteMountainView,
        englishLike ?? englishLike2018,
        dense ?? dense2021,
        tall ?? tall2021,
      );

  final TextTheme black;
  final TextTheme white;
  final TextTheme englishLike;
  final TextTheme dense;
  final TextTheme tall;

  /// The size theme for [category].
  TextTheme geometryThemeFor(ScriptCategory category) => switch (category) {
        ScriptCategory.englishLike => englishLike,
        ScriptCategory.dense => dense,
        ScriptCategory.tall => tall,
      };

  Typography copyWith({
    TextTheme? black,
    TextTheme? white,
    TextTheme? englishLike,
    TextTheme? dense,
    TextTheme? tall,
  }) =>
      Typography._(
        black ?? this.black,
        white ?? this.white,
        englishLike ?? this.englishLike,
        dense ?? this.dense,
        tall ?? this.tall,
      );

  static const Color _black87 = Color(0xDD000000);
  static const Color _black54 = Color(0x8A000000);
  static const Color _white = Color(0xFFFFFFFF);
  static const Color _white70 = Color(0xB3FFFFFF);

  /// Dark text, for light themes.
  static const TextTheme blackMountainView = TextTheme(
    displayLarge: TextStyle(color: _black54),
    displayMedium: TextStyle(color: _black54),
    displaySmall: TextStyle(color: _black54),
    headlineLarge: TextStyle(color: _black54),
    headlineMedium: TextStyle(color: _black54),
    headlineSmall: TextStyle(color: _black87),
    titleLarge: TextStyle(color: _black87),
    titleMedium: TextStyle(color: _black87),
    titleSmall: TextStyle(color: Color(0xFF000000)),
    bodyLarge: TextStyle(color: _black87),
    bodyMedium: TextStyle(color: _black87),
    bodySmall: TextStyle(color: _black54),
    labelLarge: TextStyle(color: _black87),
    labelMedium: TextStyle(color: Color(0xFF000000)),
    labelSmall: TextStyle(color: Color(0xFF000000)),
  );

  /// Light text, for dark themes.
  static const TextTheme whiteMountainView = TextTheme(
    displayLarge: TextStyle(color: _white70),
    displayMedium: TextStyle(color: _white70),
    displaySmall: TextStyle(color: _white70),
    headlineLarge: TextStyle(color: _white70),
    headlineMedium: TextStyle(color: _white70),
    headlineSmall: TextStyle(color: _white),
    titleLarge: TextStyle(color: _white),
    titleMedium: TextStyle(color: _white),
    titleSmall: TextStyle(color: _white),
    bodyLarge: TextStyle(color: _white),
    bodyMedium: TextStyle(color: _white),
    bodySmall: TextStyle(color: _white70),
    labelLarge: TextStyle(color: _white),
    labelMedium: TextStyle(color: _white),
    labelSmall: TextStyle(color: _white),
  );

  /// Flutter's names for the same colour themes on other platforms; the
  /// faces are not platform-specific here, so they are the same themes.
  static const TextTheme blackCupertino = blackMountainView;
  static const TextTheme whiteCupertino = whiteMountainView;
  static const TextTheme blackHelsinki = blackMountainView;
  static const TextTheme whiteHelsinki = whiteMountainView;
  static const TextTheme blackRedmond = blackMountainView;
  static const TextTheme whiteRedmond = whiteMountainView;
  static const TextTheme blackRedwoodCity = blackMountainView;
  static const TextTheme whiteRedwoodCity = whiteMountainView;

  static TextStyle _scale(
          double size, double line, FontWeight weight, double letterSpacing) =>
      TextStyle(
        fontSize: size,
        height: line / size,
        fontWeight: weight,
        letterSpacing: letterSpacing,
      );

  /// Material 3's sizes, line heights, weights and tracking.
  static final TextTheme englishLike2021 = TextTheme(
    displayLarge: _scale(57, 64, FontWeight.w400, -0.25),
    displayMedium: _scale(45, 52, FontWeight.w400, 0),
    displaySmall: _scale(36, 44, FontWeight.w400, 0),
    headlineLarge: _scale(32, 40, FontWeight.w400, 0),
    headlineMedium: _scale(28, 36, FontWeight.w400, 0),
    headlineSmall: _scale(24, 32, FontWeight.w400, 0),
    titleLarge: _scale(22, 28, FontWeight.w400, 0),
    titleMedium: _scale(16, 24, FontWeight.w500, 0.15),
    titleSmall: _scale(14, 20, FontWeight.w500, 0.1),
    labelLarge: _scale(14, 20, FontWeight.w500, 0.1),
    labelMedium: _scale(12, 16, FontWeight.w500, 0.5),
    labelSmall: _scale(11, 16, FontWeight.w500, 0.5),
    bodyLarge: _scale(16, 24, FontWeight.w400, 0.5),
    bodyMedium: _scale(14, 20, FontWeight.w400, 0.25),
    bodySmall: _scale(12, 16, FontWeight.w400, 0.4),
  );

  /// The same scale for dense scripts (Chinese, Japanese, Korean).
  static final TextTheme dense2021 = englishLike2021;

  /// The same scale for tall scripts (Thai, Devanagari, ...).
  static final TextTheme tall2021 = englishLike2021;

  /// Material 2's 2018 sizes.
  static final TextTheme englishLike2018 = TextTheme(
    displayLarge: _scale(96, 112, FontWeight.w300, -1.5),
    displayMedium: _scale(60, 72, FontWeight.w300, -0.5),
    displaySmall: _scale(48, 56, FontWeight.w400, 0),
    headlineLarge: _scale(40, 48, FontWeight.w400, 0.25),
    headlineMedium: _scale(34, 40, FontWeight.w400, 0.25),
    headlineSmall: _scale(24, 32, FontWeight.w400, 0),
    titleLarge: _scale(20, 28, FontWeight.w500, 0.15),
    titleMedium: _scale(16, 24, FontWeight.w400, 0.15),
    titleSmall: _scale(14, 20, FontWeight.w500, 0.1),
    bodyLarge: _scale(16, 24, FontWeight.w400, 0.5),
    bodyMedium: _scale(14, 20, FontWeight.w400, 0.25),
    bodySmall: _scale(12, 16, FontWeight.w400, 0.4),
    labelLarge: _scale(14, 16, FontWeight.w500, 1.25),
    labelMedium: _scale(11, 16, FontWeight.w400, 1.5),
    labelSmall: _scale(10, 16, FontWeight.w400, 1.5),
  );
}
