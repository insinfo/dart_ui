// Adapted from Flutter, packages/flutter/lib/src/material/app_bar_theme.dart
// and tab_bar_theme.dart.
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// `AppBarTheme` and `TabBarTheme`: the component themes Flutter lets an app
/// write either as data in `ThemeData` or as a widget around a subtree.
library;

import '../graphics/color.dart' hide Colors;
import '../layout/borders.dart';
import '../layout/decoration.dart';
import '../layout/edge_insets.dart';
import '../widgets/basic.dart' show SizedBox;
import '../widgets/theme.dart' show IconThemeData, TextStyle;
import '../widgets/widget.dart';
import 'component_themes.dart';
import 'theme.dart';
import 'widget_state.dart';

/// The app bar's look for a subtree - Flutter's `AppBarTheme`.
///
/// Both of Flutter's spellings work: as data in the theme,
/// `ThemeData(appBarTheme: AppBarTheme(backgroundColor: ...))`, and as a
/// widget around part of the tree, `AppBarTheme(data: ..., child: ...)`.
/// [AppBarTheme.of] reads the nearest one, then the theme's.
class AppBarTheme extends InheritedWidget {
  const AppBarTheme({
    super.key,
    Color? color,
    Color? backgroundColor,
    Color? foregroundColor,
    double? elevation,
    double? scrolledUnderElevation,
    Color? shadowColor,
    Color? surfaceTintColor,
    ShapeBorder? shape,
    IconThemeData? iconTheme,
    IconThemeData? actionsIconTheme,
    bool? centerTitle,
    double? titleSpacing,
    double? leadingWidth,
    double? toolbarHeight,
    TextStyle? toolbarTextStyle,
    TextStyle? titleTextStyle,
    EdgeInsets? actionsPadding,
    AppBarThemeData? data,
    Widget? child,
  })  : _data = data,
        _backgroundColor = backgroundColor ?? color,
        _foregroundColor = foregroundColor,
        _elevation = elevation,
        _scrolledUnderElevation = scrolledUnderElevation,
        _shadowColor = shadowColor,
        _surfaceTintColor = surfaceTintColor,
        _shape = shape,
        _iconTheme = iconTheme,
        _actionsIconTheme = actionsIconTheme,
        _centerTitle = centerTitle,
        _titleSpacing = titleSpacing,
        _leadingWidth = leadingWidth,
        _toolbarHeight = toolbarHeight,
        _toolbarTextStyle = toolbarTextStyle,
        _titleTextStyle = titleTextStyle,
        _actionsPadding = actionsPadding,
        super(child: child ?? const SizedBox());

  final AppBarThemeData? _data;
  final Color? _backgroundColor;
  final Color? _foregroundColor;
  final double? _elevation;
  final double? _scrolledUnderElevation;
  final Color? _shadowColor;
  final Color? _surfaceTintColor;
  final ShapeBorder? _shape;
  final IconThemeData? _iconTheme;
  final IconThemeData? _actionsIconTheme;
  final bool? _centerTitle;
  final double? _titleSpacing;
  final double? _leadingWidth;
  final double? _toolbarHeight;
  final TextStyle? _toolbarTextStyle;
  final TextStyle? _titleTextStyle;
  final EdgeInsets? _actionsPadding;

  /// The values this widget stands for.
  AppBarThemeData get data =>
      _data ??
      AppBarThemeData(
        backgroundColor: _backgroundColor,
        foregroundColor: _foregroundColor,
        elevation: _elevation,
        scrolledUnderElevation: _scrolledUnderElevation,
        shadowColor: _shadowColor,
        surfaceTintColor: _surfaceTintColor,
        shape: _shape,
        iconTheme: _iconTheme,
        actionsIconTheme: _actionsIconTheme,
        centerTitle: _centerTitle,
        titleSpacing: _titleSpacing,
        leadingWidth: _leadingWidth,
        toolbarHeight: _toolbarHeight,
        toolbarTextStyle: _toolbarTextStyle,
        titleTextStyle: _titleTextStyle,
        actionsPadding: _actionsPadding,
      );

  Color? get backgroundColor => data.backgroundColor;
  Color? get foregroundColor => data.foregroundColor;
  double? get elevation => data.elevation;
  bool? get centerTitle => data.centerTitle;
  double? get toolbarHeight => data.toolbarHeight;
  TextStyle? get titleTextStyle => data.titleTextStyle;

  /// The nearest [AppBarTheme]'s values, or the theme's.
  static AppBarThemeData of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppBarTheme>()?.data ??
      Theme.of(context).appBarTheme;

  @override
  bool updateShouldNotify(AppBarTheme oldWidget) => data != oldWidget.data;
}

/// The tab bar's look for a subtree - Flutter's `TabBarTheme`; both
/// spellings, as [AppBarTheme].
class TabBarTheme extends InheritedWidget {
  const TabBarTheme({
    super.key,
    Decoration? indicator,
    Color? indicatorColor,
    TabBarIndicatorSize? indicatorSize,
    Color? dividerColor,
    double? dividerHeight,
    Color? labelColor,
    EdgeInsets? labelPadding,
    TextStyle? labelStyle,
    Color? unselectedLabelColor,
    TextStyle? unselectedLabelStyle,
    WidgetStateProperty<Color?>? overlayColor,
    TabAlignment? tabAlignment,
    TabBarThemeData? data,
    Widget? child,
  })  : _data = data,
        _indicator = indicator,
        _indicatorColor = indicatorColor,
        _indicatorSize = indicatorSize,
        _dividerColor = dividerColor,
        _dividerHeight = dividerHeight,
        _labelColor = labelColor,
        _labelPadding = labelPadding,
        _labelStyle = labelStyle,
        _unselectedLabelColor = unselectedLabelColor,
        _unselectedLabelStyle = unselectedLabelStyle,
        _overlayColor = overlayColor,
        _tabAlignment = tabAlignment,
        super(child: child ?? const SizedBox());

  final TabBarThemeData? _data;
  final Decoration? _indicator;
  final Color? _indicatorColor;
  final TabBarIndicatorSize? _indicatorSize;
  final Color? _dividerColor;
  final double? _dividerHeight;
  final Color? _labelColor;
  final EdgeInsets? _labelPadding;
  final TextStyle? _labelStyle;
  final Color? _unselectedLabelColor;
  final TextStyle? _unselectedLabelStyle;
  final WidgetStateProperty<Color?>? _overlayColor;
  final TabAlignment? _tabAlignment;

  /// The values this widget stands for.
  TabBarThemeData get data =>
      _data ??
      TabBarThemeData(
        indicator: _indicator,
        indicatorColor: _indicatorColor,
        indicatorSize: _indicatorSize,
        dividerColor: _dividerColor,
        dividerHeight: _dividerHeight,
        labelColor: _labelColor,
        labelPadding: _labelPadding,
        labelStyle: _labelStyle,
        unselectedLabelColor: _unselectedLabelColor,
        unselectedLabelStyle: _unselectedLabelStyle,
        overlayColor: _overlayColor,
        tabAlignment: _tabAlignment,
      );

  /// The nearest [TabBarTheme]'s values, or the theme's.
  static TabBarThemeData of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TabBarTheme>()?.data ??
      Theme.of(context).tabBarTheme;

  @override
  bool updateShouldNotify(TabBarTheme oldWidget) => data != oldWidget.data;
}
