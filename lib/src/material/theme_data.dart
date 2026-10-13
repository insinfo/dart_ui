// Adapted from Flutter, packages/flutter/lib/src/material/theme_data.dart.
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Flutter's Material `ThemeData`, and the map from it onto dart_ui's own
/// theme.
library;

import '../geometry/offset.dart';
import '../graphics/color.dart' hide Colors;
import '../platform/system_settings.dart' show Brightness;
import '../widgets/theme.dart' as dui;
import '../widgets/theme.dart'
    show
        ControlStyle,
        IconThemeData,
        ProgressIndicatorThemeData,
        ScrollbarThemeData,
        TextStyle,
        ThemeDensity;
import 'app_bar_theme.dart';
import 'color_scheme.dart';
import 'colors.dart';
import 'component_themes.dart';
import 'target_platform.dart';
import 'typography.dart';

/// The icon colour of a light theme: Flutter's `kDefaultIconDarkColor`.
const Color kDefaultIconDarkColor = Color(0xDD000000);

/// The icon colour of a dark theme: Flutter's `kDefaultIconLightColor`.
const Color kDefaultIconLightColor = Color(0xFFFFFFFF);

/// Whether controls keep Material's 48 px touch target around a smaller
/// drawing.
enum MaterialTapTargetSize { padded, shrinkWrap }

/// How compact the components are - Flutter's `VisualDensity`.
///
/// [horizontal] and [vertical] run from -4 (densest) to 4; each step is 4
/// logical pixels of a component's height or width.
class VisualDensity {
  const VisualDensity({this.horizontal = 0.0, this.vertical = 0.0})
      : assert(horizontal >= minimumDensity && horizontal <= maximumDensity),
        assert(vertical >= minimumDensity && vertical <= maximumDensity);

  static const double minimumDensity = -4.0;
  static const double maximumDensity = 4.0;

  static const VisualDensity standard = VisualDensity();
  static const VisualDensity comfortable =
      VisualDensity(horizontal: -1.0, vertical: -1.0);
  static const VisualDensity compact =
      VisualDensity(horizontal: -2.0, vertical: -2.0);

  /// Compact on desktops, standard on phones - Flutter's choice.
  static VisualDensity get adaptivePlatformDensity =>
      defaultDensityForPlatform(defaultTargetPlatform);

  static VisualDensity defaultDensityForPlatform(TargetPlatform platform) =>
      switch (platform) {
        TargetPlatform.android ||
        TargetPlatform.iOS ||
        TargetPlatform.fuchsia =>
          standard,
        TargetPlatform.linux ||
        TargetPlatform.macOS ||
        TargetPlatform.windows =>
          compact,
      };

  final double horizontal;
  final double vertical;

  /// How much a component grows (positive) or shrinks, in pixels.
  Offset get baseSizeAdjustment => Offset(horizontal * 4.0, vertical * 4.0);

  VisualDensity copyWith({double? horizontal, double? vertical}) =>
      VisualDensity(
        horizontal: horizontal ?? this.horizontal,
        vertical: vertical ?? this.vertical,
      );

  @override
  bool operator ==(Object other) =>
      other is VisualDensity &&
      other.horizontal == horizontal &&
      other.vertical == vertical;

  @override
  int get hashCode => Object.hash(horizontal, vertical);
}

/// An application's own addition to the theme - Flutter's `ThemeExtension`.
///
/// Read back with `Theme.of(context).extension<MyColors>()`.
abstract class ThemeExtension<T> {
  const ThemeExtension();

  /// The key the extension is stored under: its type.
  Object get type => T;

  ThemeExtension<T> copyWith();

  ThemeExtension<T> lerp(covariant ThemeExtension<T>? other, double t);
}

/// The Material theme - Flutter's `ThemeData`.
///
/// `ThemeData()` is Material 3 with Material's baseline purple scheme;
/// `ThemeData(colorSchemeSeed: Colors.teal)` or `ThemeData(colorScheme:
/// ColorScheme.fromSeed(seedColor: Colors.teal))` builds the scheme from a
/// colour; `ThemeData.dark()` and `brightness: Brightness.dark` give the dark
/// one. The defaults are Flutter's: the colours each field gets when it is
/// not named, the Material 3 type scale, and the component themes empty.
///
/// The commonly used part of Flutter's `ThemeData` is here: the colour
/// fields, `textTheme`/`primaryTextTheme`/`typography`, the icon themes,
/// `platform`, `visualDensity`, `extensions` and the component themes of the
/// app shell (app bar, tabs, navigation bar, rail and drawer, bottom
/// navigation bar, drawer, floating action button, snack bar), plus dart_ui's
/// `progressIndicatorTheme` and `scrollbarTheme`. The components that are not
/// written yet have no theme field yet; each arrives with its component.
///
/// ## Under a Material theme, dart_ui's controls
///
/// [dartUiTheme] is this theme said in dart_ui's own vocabulary: surfaces,
/// borders, accent and text from the [colorScheme], Material 3's shapes
/// (`ControlStyle.material`). The Material `Theme` widget installs both, so a
/// dart_ui control (a `DataGrid`, a `TreeView`) inside a Material app wears
/// the app's colours.
class ThemeData {
  ThemeData._raw({
    required this.useMaterial3,
    required this.brightness,
    required this.colorScheme,
    required this.platform,
    required this.visualDensity,
    required this.materialTapTargetSize,
    required this.extensions,
    required this.applyElevationOverlayColor,
    required this.primaryColor,
    required this.primaryColorLight,
    required this.primaryColorDark,
    required this.canvasColor,
    required this.scaffoldBackgroundColor,
    required this.cardColor,
    required this.dividerColor,
    required this.focusColor,
    required this.hoverColor,
    required this.highlightColor,
    required this.splashColor,
    required this.shadowColor,
    required this.disabledColor,
    required this.hintColor,
    required this.secondaryHeaderColor,
    required this.unselectedWidgetColor,
    required this.dialogBackgroundColor,
    required this.indicatorColor,
    required this.typography,
    required this.textTheme,
    required this.primaryTextTheme,
    required this.iconTheme,
    required this.primaryIconTheme,
    required this.fontFamily,
    required this.appBarTheme,
    required this.bottomNavigationBarTheme,
    required this.drawerTheme,
    required this.floatingActionButtonTheme,
    required this.navigationBarTheme,
    required this.navigationDrawerTheme,
    required this.navigationRailTheme,
    required this.snackBarTheme,
    required this.tabBarTheme,
    required this.progressIndicatorTheme,
    required this.scrollbarTheme,
  });

  factory ThemeData({
    bool? useMaterial3,
    Brightness? brightness,
    ColorScheme? colorScheme,
    Color? colorSchemeSeed,
    MaterialColor? primarySwatch,
    Color? primaryColor,
    Color? primaryColorLight,
    Color? primaryColorDark,
    Color? canvasColor,
    Color? scaffoldBackgroundColor,
    Color? cardColor,
    Color? dividerColor,
    Color? focusColor,
    Color? hoverColor,
    Color? highlightColor,
    Color? splashColor,
    Color? shadowColor,
    Color? disabledColor,
    Color? hintColor,
    Color? secondaryHeaderColor,
    Color? unselectedWidgetColor,
    Color? dialogBackgroundColor,
    Color? indicatorColor,
    String? fontFamily,
    List<String>? fontFamilyFallback,
    String? package,
    TextTheme? textTheme,
    TextTheme? primaryTextTheme,
    Typography? typography,
    IconThemeData? iconTheme,
    IconThemeData? primaryIconTheme,
    TargetPlatform? platform,
    VisualDensity? visualDensity,
    MaterialTapTargetSize? materialTapTargetSize,
    Iterable<ThemeExtension<Object?>>? extensions,
    bool? applyElevationOverlayColor,
    Object? appBarTheme,
    BottomNavigationBarThemeData? bottomNavigationBarTheme,
    DrawerThemeData? drawerTheme,
    FloatingActionButtonThemeData? floatingActionButtonTheme,
    NavigationBarThemeData? navigationBarTheme,
    NavigationDrawerThemeData? navigationDrawerTheme,
    NavigationRailThemeData? navigationRailTheme,
    SnackBarThemeData? snackBarTheme,
    Object? tabBarTheme,
    ProgressIndicatorThemeData? progressIndicatorTheme,
    ScrollbarThemeData? scrollbarTheme,
  }) {
    if (colorSchemeSeed != null && colorScheme != null) {
      throw ArgumentError(
          'ThemeData takes colorScheme or colorSchemeSeed, not both');
    }
    if (colorScheme != null &&
        brightness != null &&
        colorScheme.brightness != brightness) {
      throw ArgumentError(
        'ThemeData.brightness ($brightness) does not match '
        'ColorScheme.brightness (${colorScheme.brightness}); override one '
        'to match the other',
      );
    }
    platform ??= defaultTargetPlatform;
    materialTapTargetSize ??= switch (platform) {
      TargetPlatform.android ||
      TargetPlatform.fuchsia ||
      TargetPlatform.iOS =>
        MaterialTapTargetSize.padded,
      _ => MaterialTapTargetSize.shrinkWrap,
    };
    visualDensity ??= VisualDensity.defaultDensityForPlatform(platform);
    useMaterial3 ??= true;
    final Brightness effectiveBrightness =
        brightness ?? colorScheme?.brightness ?? Brightness.light;
    final bool isDark = effectiveBrightness == Brightness.dark;
    if (colorSchemeSeed != null || useMaterial3) {
      if (colorSchemeSeed != null) {
        colorScheme = ColorScheme.fromSeed(
          seedColor: colorSchemeSeed,
          brightness: effectiveBrightness,
        );
      }
      colorScheme ??= isDark ? _colorSchemeDarkM3 : _colorSchemeLightM3;
      final Color primarySurface =
          isDark ? colorScheme.surface : colorScheme.primary;
      final Color onPrimarySurface =
          isDark ? colorScheme.onSurface : colorScheme.onPrimary;
      primaryColor ??= primarySurface;
      canvasColor ??= colorScheme.surface;
      scaffoldBackgroundColor ??= colorScheme.surface;
      cardColor ??= colorScheme.surface;
      dividerColor ??= colorScheme.outline;
      dialogBackgroundColor ??= colorScheme.surface;
      indicatorColor ??= onPrimarySurface;
      applyElevationOverlayColor ??= brightness == Brightness.dark;
    }
    applyElevationOverlayColor ??= false;
    primarySwatch ??= Colors.blue;
    primaryColor ??= isDark ? Colors.grey[900]! : primarySwatch;
    final bool primaryIsDark =
        estimateBrightnessForColor(primaryColor) == Brightness.dark;
    primaryColorLight ??= isDark ? Colors.grey[500]! : primarySwatch[100]!;
    primaryColorDark ??= isDark ? Colors.black : primarySwatch[700]!;
    focusColor ??= isDark ? const Color(0x1FFFFFFF) : const Color(0x1F000000);
    hoverColor ??= isDark ? const Color(0x0AFFFFFF) : const Color(0x0A000000);
    shadowColor ??= Colors.black;
    canvasColor ??= isDark ? Colors.grey[850]! : Colors.grey[50]!;
    scaffoldBackgroundColor ??= canvasColor;
    cardColor ??= isDark ? Colors.grey[800]! : Colors.white;
    dividerColor ??= isDark ? const Color(0x1FFFFFFF) : const Color(0x1F000000);
    colorScheme ??= ColorScheme.fromSwatch(
      primarySwatch: primarySwatch,
      accentColor: isDark ? Colors.tealAccent[200]! : primarySwatch[500]!,
      cardColor: cardColor,
      backgroundColor: isDark ? Colors.grey[700]! : primarySwatch[200]!,
      errorColor: Colors.red[700],
      brightness: effectiveBrightness,
    );
    unselectedWidgetColor ??= isDark ? Colors.white70 : Colors.black54;
    secondaryHeaderColor ??= isDark ? Colors.grey[700]! : primarySwatch[50]!;
    hintColor ??= isDark ? Colors.white60 : const Color(0x99000000);
    disabledColor ??= isDark ? Colors.white38 : Colors.black38;
    highlightColor ??=
        isDark ? const Color(0x40CCCCCC) : const Color(0x66BCBCBC);
    splashColor ??= isDark ? const Color(0x40CCCCCC) : const Color(0x66C8C8C8);
    typography ??= useMaterial3
        ? Typography.material2021(platform: platform, colorScheme: colorScheme)
        : Typography.material2018(platform: platform);
    TextTheme defaultTextTheme = isDark ? typography.white : typography.black;
    TextTheme defaultPrimaryTextTheme =
        primaryIsDark ? typography.white : typography.black;
    defaultTextTheme = typography.englishLike.merge(defaultTextTheme);
    defaultPrimaryTextTheme =
        typography.englishLike.merge(defaultPrimaryTextTheme);
    if (fontFamily != null) {
      defaultTextTheme = defaultTextTheme.apply(fontFamily: fontFamily);
      defaultPrimaryTextTheme =
          defaultPrimaryTextTheme.apply(fontFamily: fontFamily);
    }
    textTheme = defaultTextTheme.merge(textTheme);
    primaryTextTheme = defaultPrimaryTextTheme.merge(primaryTextTheme);
    iconTheme ??= isDark
        ? const IconThemeData(color: kDefaultIconLightColor, size: 24)
        : const IconThemeData(color: kDefaultIconDarkColor, size: 24);
    primaryIconTheme ??= primaryIsDark
        ? const IconThemeData(color: Colors.white, size: 24)
        : const IconThemeData(color: Colors.black, size: 24);
    dialogBackgroundColor ??= isDark ? Colors.grey[800]! : Colors.white;
    indicatorColor ??= colorScheme.secondary == primaryColor
        ? Colors.white
        : colorScheme.secondary;
    return ThemeData._raw(
      useMaterial3: useMaterial3,
      brightness: colorScheme.brightness,
      colorScheme: colorScheme,
      platform: platform,
      visualDensity: visualDensity,
      materialTapTargetSize: materialTapTargetSize,
      extensions: <Object, ThemeExtension<Object?>>{
        for (final ThemeExtension<Object?> e
            in extensions ?? const <ThemeExtension<Object?>>[])
          e.type: e,
      },
      applyElevationOverlayColor: applyElevationOverlayColor,
      primaryColor: primaryColor,
      primaryColorLight: primaryColorLight,
      primaryColorDark: primaryColorDark,
      canvasColor: canvasColor,
      scaffoldBackgroundColor: scaffoldBackgroundColor,
      cardColor: cardColor,
      dividerColor: dividerColor,
      focusColor: focusColor,
      hoverColor: hoverColor,
      highlightColor: highlightColor,
      splashColor: splashColor,
      shadowColor: shadowColor,
      disabledColor: disabledColor,
      hintColor: hintColor,
      secondaryHeaderColor: secondaryHeaderColor,
      unselectedWidgetColor: unselectedWidgetColor,
      dialogBackgroundColor: dialogBackgroundColor,
      indicatorColor: indicatorColor,
      typography: typography,
      textTheme: textTheme,
      primaryTextTheme: primaryTextTheme,
      iconTheme: iconTheme,
      primaryIconTheme: primaryIconTheme,
      fontFamily: fontFamily,
      appBarTheme: _appBarData(appBarTheme),
      bottomNavigationBarTheme:
          bottomNavigationBarTheme ?? const BottomNavigationBarThemeData(),
      drawerTheme: drawerTheme ?? const DrawerThemeData(),
      floatingActionButtonTheme:
          floatingActionButtonTheme ?? const FloatingActionButtonThemeData(),
      navigationBarTheme: navigationBarTheme ?? const NavigationBarThemeData(),
      navigationDrawerTheme:
          navigationDrawerTheme ?? const NavigationDrawerThemeData(),
      navigationRailTheme:
          navigationRailTheme ?? const NavigationRailThemeData(),
      snackBarTheme: snackBarTheme ?? const SnackBarThemeData(),
      tabBarTheme: _tabBarData(tabBarTheme),
      progressIndicatorTheme:
          progressIndicatorTheme ?? const ProgressIndicatorThemeData(),
      scrollbarTheme: scrollbarTheme ?? const ScrollbarThemeData(),
    );
  }

  /// The theme for [colorScheme], with the type scale coloured from it.
  factory ThemeData.from({
    required ColorScheme colorScheme,
    TextTheme? textTheme,
    bool? useMaterial3,
  }) =>
      ThemeData(
        colorScheme: colorScheme,
        brightness: colorScheme.brightness,
        textTheme: textTheme,
        useMaterial3: useMaterial3,
      );

  /// Material 3's light baseline.
  factory ThemeData.light({bool? useMaterial3}) =>
      ThemeData(brightness: Brightness.light, useMaterial3: useMaterial3);

  /// Material 3's dark baseline.
  factory ThemeData.dark({bool? useMaterial3}) =>
      ThemeData(brightness: Brightness.dark, useMaterial3: useMaterial3);

  /// The theme `Theme.of` returns with no `Theme` above: [ThemeData.light].
  factory ThemeData.fallback({bool? useMaterial3}) =>
      useMaterial3 == false ? ThemeData.light(useMaterial3: false) : _fallback;

  static final ThemeData _fallback = ThemeData.light();

  static AppBarThemeData _appBarData(Object? theme) => switch (theme) {
        null => const AppBarThemeData(),
        AppBarThemeData() => theme,
        AppBarTheme() => theme.data,
        _ => throw ArgumentError(
            'appBarTheme must be an AppBarThemeData or an AppBarTheme'),
      };

  static TabBarThemeData _tabBarData(Object? theme) => switch (theme) {
        null => const TabBarThemeData(),
        TabBarThemeData() => theme,
        TabBarTheme() => theme.data,
        _ => throw ArgumentError(
            'tabBarTheme must be a TabBarThemeData or a TabBarTheme'),
      };

  /// Whether text on [color] should be light (dark colour) or dark - Flutter's
  /// threshold, which leans towards light text more than WCAG's.
  static Brightness estimateBrightnessForColor(Color color) {
    final double l = color.computeLuminance();
    return (l + 0.05) * (l + 0.05) > 0.15 ? Brightness.light : Brightness.dark;
  }

  final bool useMaterial3;
  final Brightness brightness;
  final ColorScheme colorScheme;
  final TargetPlatform platform;
  final VisualDensity visualDensity;
  final MaterialTapTargetSize materialTapTargetSize;
  final Map<Object, ThemeExtension<Object?>> extensions;
  final bool applyElevationOverlayColor;

  final Color primaryColor;
  final Color primaryColorLight;
  final Color primaryColorDark;
  final Color canvasColor;
  final Color scaffoldBackgroundColor;
  final Color cardColor;
  final Color dividerColor;
  final Color focusColor;
  final Color hoverColor;
  final Color highlightColor;
  final Color splashColor;
  final Color shadowColor;
  final Color disabledColor;
  final Color hintColor;
  final Color secondaryHeaderColor;
  final Color unselectedWidgetColor;
  final Color dialogBackgroundColor;
  final Color indicatorColor;

  final Typography typography;
  final TextTheme textTheme;
  final TextTheme primaryTextTheme;
  final IconThemeData iconTheme;
  final IconThemeData primaryIconTheme;

  /// The face the theme was built with, or null for the interface face.
  final String? fontFamily;

  final AppBarThemeData appBarTheme;
  final BottomNavigationBarThemeData bottomNavigationBarTheme;
  final DrawerThemeData drawerTheme;
  final FloatingActionButtonThemeData floatingActionButtonTheme;
  final NavigationBarThemeData navigationBarTheme;
  final NavigationDrawerThemeData navigationDrawerTheme;
  final NavigationRailThemeData navigationRailTheme;
  final SnackBarThemeData snackBarTheme;
  final TabBarThemeData tabBarTheme;
  final ProgressIndicatorThemeData progressIndicatorTheme;
  final ScrollbarThemeData scrollbarTheme;

  /// The extension of type [T], or null.
  T? extension<T>() => extensions[T] as T?;

  /// This theme in dart_ui's own vocabulary; see the class comment.
  late final dui.ThemeData dartUiTheme = _toDartUi();

  dui.ThemeData _toDartUi() {
    final ColorScheme cs = colorScheme;
    final bool dark = brightness == Brightness.dark;
    Color over(Color base, Color layer, double opacity) =>
        Color.alphaBlend(layer.withOpacity(opacity), base);
    final double vertical = visualDensity.vertical;
    final ThemeDensity density = vertical <= -2
        ? ThemeDensity.compact
        : vertical >= 2
            ? ThemeDensity.comfortable
            : ThemeDensity.standard;
    final TextStyle body = textTheme.bodyMedium ?? const TextStyle();
    return dui.ThemeData(
      name: dark ? 'material-app-dark' : 'material-app-light',
      brightness: brightness,
      controlStyle: ControlStyle.material,
      accent: cs.primary,
      accentHovered: over(cs.primary, cs.onPrimary, 0.08),
      accentPressed: over(cs.primary, cs.onPrimary, 0.12),
      accentSubtle: cs.secondaryContainer,
      surfaceBase: scaffoldBackgroundColor,
      surfaceSunken: dark ? cs.surfaceContainerLowest : cs.surfaceDim,
      surface: cs.surface,
      surfaceAlternate: cs.surfaceContainerLow,
      surfaceRaised: cs.surfaceContainer,
      borderSubtle: cs.outlineVariant,
      border: cs.outlineVariant,
      borderStrong: cs.outline,
      foreground: cs.onSurface,
      foregroundSecondary: cs.onSurfaceVariant,
      disabledForeground: over(cs.surface, cs.onSurface, 0.38),
      disabledSurface: over(cs.surface, cs.onSurface, 0.12),
      hoverSurface: over(cs.surface, cs.onSurface, 0.08),
      pressedSurface: over(cs.surface, cs.onSurface, 0.12),
      focusRing: cs.primary,
      selection: cs.primaryContainer,
      onSelection: cs.onPrimaryContainer,
      colorScheme: dui.ColorScheme(
        brightness: brightness,
        primary: cs.primary,
        onPrimary: cs.onPrimary,
        surface: cs.surface,
        onSurface: cs.onSurface,
        surfaceContainer: cs.surfaceContainer,
        outline: cs.outline,
        error: cs.error,
        onError: cs.onError,
      ),
      textTheme: dui.TextTheme(
        base: body.fontSize ?? 14,
        fontFamily: fontFamily ?? body.fontFamily,
      ),
      iconTheme: IconThemeData(
        color: iconTheme.color ?? cs.onSurfaceVariant,
        size: iconTheme.size ?? 24,
      ),
      progressIndicatorTheme: progressIndicatorTheme,
      scrollbarTheme: scrollbarTheme,
      useMaterial3: useMaterial3,
      density: density,
      cornerRadius: useMaterial3 ? 12 : 4,
      controlHeight: 40,
      controlPadding: 24,
    );
  }

  ThemeData copyWith({
    bool? useMaterial3,
    Brightness? brightness,
    ColorScheme? colorScheme,
    TargetPlatform? platform,
    VisualDensity? visualDensity,
    MaterialTapTargetSize? materialTapTargetSize,
    Iterable<ThemeExtension<Object?>>? extensions,
    bool? applyElevationOverlayColor,
    Color? primaryColor,
    Color? primaryColorLight,
    Color? primaryColorDark,
    Color? canvasColor,
    Color? scaffoldBackgroundColor,
    Color? cardColor,
    Color? dividerColor,
    Color? focusColor,
    Color? hoverColor,
    Color? highlightColor,
    Color? splashColor,
    Color? shadowColor,
    Color? disabledColor,
    Color? hintColor,
    Color? secondaryHeaderColor,
    Color? unselectedWidgetColor,
    Color? dialogBackgroundColor,
    Color? indicatorColor,
    Typography? typography,
    TextTheme? textTheme,
    TextTheme? primaryTextTheme,
    IconThemeData? iconTheme,
    IconThemeData? primaryIconTheme,
    Object? appBarTheme,
    BottomNavigationBarThemeData? bottomNavigationBarTheme,
    DrawerThemeData? drawerTheme,
    FloatingActionButtonThemeData? floatingActionButtonTheme,
    NavigationBarThemeData? navigationBarTheme,
    NavigationDrawerThemeData? navigationDrawerTheme,
    NavigationRailThemeData? navigationRailTheme,
    SnackBarThemeData? snackBarTheme,
    Object? tabBarTheme,
    ProgressIndicatorThemeData? progressIndicatorTheme,
    ScrollbarThemeData? scrollbarTheme,
  }) {
    final ColorScheme scheme = colorScheme ??
        (brightness != null && brightness != this.brightness
            ? this.colorScheme.copyWith(brightness: brightness)
            : this.colorScheme);
    return ThemeData._raw(
      useMaterial3: useMaterial3 ?? this.useMaterial3,
      brightness: brightness ?? scheme.brightness,
      colorScheme: scheme,
      platform: platform ?? this.platform,
      visualDensity: visualDensity ?? this.visualDensity,
      materialTapTargetSize:
          materialTapTargetSize ?? this.materialTapTargetSize,
      extensions: extensions == null
          ? this.extensions
          : <Object, ThemeExtension<Object?>>{
              for (final ThemeExtension<Object?> e in extensions) e.type: e,
            },
      applyElevationOverlayColor:
          applyElevationOverlayColor ?? this.applyElevationOverlayColor,
      primaryColor: primaryColor ?? this.primaryColor,
      primaryColorLight: primaryColorLight ?? this.primaryColorLight,
      primaryColorDark: primaryColorDark ?? this.primaryColorDark,
      canvasColor: canvasColor ?? this.canvasColor,
      scaffoldBackgroundColor:
          scaffoldBackgroundColor ?? this.scaffoldBackgroundColor,
      cardColor: cardColor ?? this.cardColor,
      dividerColor: dividerColor ?? this.dividerColor,
      focusColor: focusColor ?? this.focusColor,
      hoverColor: hoverColor ?? this.hoverColor,
      highlightColor: highlightColor ?? this.highlightColor,
      splashColor: splashColor ?? this.splashColor,
      shadowColor: shadowColor ?? this.shadowColor,
      disabledColor: disabledColor ?? this.disabledColor,
      hintColor: hintColor ?? this.hintColor,
      secondaryHeaderColor: secondaryHeaderColor ?? this.secondaryHeaderColor,
      unselectedWidgetColor:
          unselectedWidgetColor ?? this.unselectedWidgetColor,
      dialogBackgroundColor:
          dialogBackgroundColor ?? this.dialogBackgroundColor,
      indicatorColor: indicatorColor ?? this.indicatorColor,
      typography: typography ?? this.typography,
      textTheme: textTheme ?? this.textTheme,
      primaryTextTheme: primaryTextTheme ?? this.primaryTextTheme,
      iconTheme: iconTheme ?? this.iconTheme,
      primaryIconTheme: primaryIconTheme ?? this.primaryIconTheme,
      fontFamily: fontFamily,
      appBarTheme:
          appBarTheme == null ? this.appBarTheme : _appBarData(appBarTheme),
      bottomNavigationBarTheme:
          bottomNavigationBarTheme ?? this.bottomNavigationBarTheme,
      drawerTheme: drawerTheme ?? this.drawerTheme,
      floatingActionButtonTheme:
          floatingActionButtonTheme ?? this.floatingActionButtonTheme,
      navigationBarTheme: navigationBarTheme ?? this.navigationBarTheme,
      navigationDrawerTheme:
          navigationDrawerTheme ?? this.navigationDrawerTheme,
      navigationRailTheme: navigationRailTheme ?? this.navigationRailTheme,
      snackBarTheme: snackBarTheme ?? this.snackBarTheme,
      tabBarTheme:
          tabBarTheme == null ? this.tabBarTheme : _tabBarData(tabBarTheme),
      progressIndicatorTheme:
          progressIndicatorTheme ?? this.progressIndicatorTheme,
      scrollbarTheme: scrollbarTheme ?? this.scrollbarTheme,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ThemeData &&
      other.useMaterial3 == useMaterial3 &&
      other.brightness == brightness &&
      other.colorScheme == colorScheme &&
      other.platform == platform &&
      other.visualDensity == visualDensity &&
      other.scaffoldBackgroundColor == scaffoldBackgroundColor &&
      other.canvasColor == canvasColor &&
      other.primaryColor == primaryColor &&
      other.textTheme == textTheme &&
      other.iconTheme.color == iconTheme.color &&
      other.iconTheme.size == iconTheme.size &&
      other.appBarTheme == appBarTheme &&
      other.tabBarTheme == tabBarTheme &&
      other.navigationBarTheme == navigationBarTheme &&
      other.navigationRailTheme == navigationRailTheme &&
      other.bottomNavigationBarTheme == bottomNavigationBarTheme &&
      other.drawerTheme == drawerTheme &&
      other.floatingActionButtonTheme == floatingActionButtonTheme &&
      other.snackBarTheme == snackBarTheme &&
      other.splashColor == splashColor &&
      other.hoverColor == hoverColor &&
      other.focusColor == focusColor &&
      other.highlightColor == highlightColor &&
      other.fontFamily == fontFamily &&
      _sameExtensions(other.extensions, extensions);

  static bool _sameExtensions(Map<Object, ThemeExtension<Object?>> a,
      Map<Object, ThemeExtension<Object?>> b) {
    if (a.length != b.length) return false;
    for (final MapEntry<Object, ThemeExtension<Object?>> e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        useMaterial3,
        brightness,
        colorScheme,
        platform,
        visualDensity,
        scaffoldBackgroundColor,
        textTheme,
        appBarTheme,
        fontFamily,
      );
}

const ColorScheme _colorSchemeLightM3 = ColorScheme(
  brightness: Brightness.light,
  primary: Color(0xFF6750A4),
  onPrimary: Color(0xFFFFFFFF),
  primaryContainer: Color(0xFFEADDFF),
  onPrimaryContainer: Color(0xFF4F378B),
  primaryFixed: Color(0xFFEADDFF),
  primaryFixedDim: Color(0xFFD0BCFF),
  onPrimaryFixed: Color(0xFF21005D),
  onPrimaryFixedVariant: Color(0xFF4F378B),
  secondary: Color(0xFF625B71),
  onSecondary: Color(0xFFFFFFFF),
  secondaryContainer: Color(0xFFE8DEF8),
  onSecondaryContainer: Color(0xFF4A4458),
  secondaryFixed: Color(0xFFE8DEF8),
  secondaryFixedDim: Color(0xFFCCC2DC),
  onSecondaryFixed: Color(0xFF1D192B),
  onSecondaryFixedVariant: Color(0xFF4A4458),
  tertiary: Color(0xFF7D5260),
  onTertiary: Color(0xFFFFFFFF),
  tertiaryContainer: Color(0xFFFFD8E4),
  onTertiaryContainer: Color(0xFF633B48),
  tertiaryFixed: Color(0xFFFFD8E4),
  tertiaryFixedDim: Color(0xFFEFB8C8),
  onTertiaryFixed: Color(0xFF31111D),
  onTertiaryFixedVariant: Color(0xFF633B48),
  error: Color(0xFFB3261E),
  onError: Color(0xFFFFFFFF),
  errorContainer: Color(0xFFF9DEDC),
  onErrorContainer: Color(0xFF8C1D18),
  background: Color(0xFFFEF7FF),
  onBackground: Color(0xFF1D1B20),
  surface: Color(0xFFFEF7FF),
  surfaceBright: Color(0xFFFEF7FF),
  surfaceContainerLowest: Color(0xFFFFFFFF),
  surfaceContainerLow: Color(0xFFF7F2FA),
  surfaceContainer: Color(0xFFF3EDF7),
  surfaceContainerHigh: Color(0xFFECE6F0),
  surfaceContainerHighest: Color(0xFFE6E0E9),
  surfaceDim: Color(0xFFDED8E1),
  onSurface: Color(0xFF1D1B20),
  surfaceVariant: Color(0xFFE7E0EC),
  onSurfaceVariant: Color(0xFF49454F),
  outline: Color(0xFF79747E),
  outlineVariant: Color(0xFFCAC4D0),
  shadow: Color(0xFF000000),
  scrim: Color(0xFF000000),
  inverseSurface: Color(0xFF322F35),
  onInverseSurface: Color(0xFFF5EFF7),
  inversePrimary: Color(0xFFD0BCFF),
  surfaceTint: Color(0xFF6750A4),
);

const ColorScheme _colorSchemeDarkM3 = ColorScheme(
  brightness: Brightness.dark,
  primary: Color(0xFFD0BCFF),
  onPrimary: Color(0xFF381E72),
  primaryContainer: Color(0xFF4F378B),
  onPrimaryContainer: Color(0xFFEADDFF),
  primaryFixed: Color(0xFFEADDFF),
  primaryFixedDim: Color(0xFFD0BCFF),
  onPrimaryFixed: Color(0xFF21005D),
  onPrimaryFixedVariant: Color(0xFF4F378B),
  secondary: Color(0xFFCCC2DC),
  onSecondary: Color(0xFF332D41),
  secondaryContainer: Color(0xFF4A4458),
  onSecondaryContainer: Color(0xFFE8DEF8),
  secondaryFixed: Color(0xFFE8DEF8),
  secondaryFixedDim: Color(0xFFCCC2DC),
  onSecondaryFixed: Color(0xFF1D192B),
  onSecondaryFixedVariant: Color(0xFF4A4458),
  tertiary: Color(0xFFEFB8C8),
  onTertiary: Color(0xFF492532),
  tertiaryContainer: Color(0xFF633B48),
  onTertiaryContainer: Color(0xFFFFD8E4),
  tertiaryFixed: Color(0xFFFFD8E4),
  tertiaryFixedDim: Color(0xFFEFB8C8),
  onTertiaryFixed: Color(0xFF31111D),
  onTertiaryFixedVariant: Color(0xFF633B48),
  error: Color(0xFFF2B8B5),
  onError: Color(0xFF601410),
  errorContainer: Color(0xFF8C1D18),
  onErrorContainer: Color(0xFFF9DEDC),
  background: Color(0xFF141218),
  onBackground: Color(0xFFE6E0E9),
  surface: Color(0xFF141218),
  surfaceBright: Color(0xFF3B383E),
  surfaceContainerLowest: Color(0xFF0F0D13),
  surfaceContainerLow: Color(0xFF1D1B20),
  surfaceContainer: Color(0xFF211F26),
  surfaceContainerHigh: Color(0xFF2B2930),
  surfaceContainerHighest: Color(0xFF36343B),
  surfaceDim: Color(0xFF141218),
  onSurface: Color(0xFFE6E0E9),
  surfaceVariant: Color(0xFF49454F),
  onSurfaceVariant: Color(0xFFCAC4D0),
  outline: Color(0xFF938F99),
  outlineVariant: Color(0xFF49454F),
  shadow: Color(0xFF000000),
  scrim: Color(0xFF000000),
  inverseSurface: Color(0xFFE6E0E9),
  onInverseSurface: Color(0xFF322F35),
  inversePrimary: Color(0xFF6750A4),
  surfaceTint: Color(0xFFD0BCFF),
);
