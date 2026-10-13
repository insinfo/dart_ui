// Adapted from Flutter, packages/flutter/lib/src/material/*_theme.dart.
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// The component themes of the app shell: app bar, tabs, navigation bars and
/// rails, drawers, the floating action button and snack bars.
///
/// Each is Flutter's `*ThemeData`: every field nullable, null meaning "the
/// component's Material 3 default". `ThemeData` holds one of each; a widget
/// reads its own field first, then the theme's, then the default.
///
/// A new component (a button, a card) adds its theme the same way: a class
/// here or in its own file, a field and a `copyWith` argument on
/// `ThemeData`, and the widget resolving `widget -> theme -> default`.
library;

import '../geometry/size.dart';
import '../graphics/color.dart' hide Colors;
import '../layout/borders.dart';
import '../layout/box_constraints.dart';
import '../layout/decoration.dart';
import '../layout/edge_insets.dart';
import '../widgets/theme.dart' show IconThemeData, TextStyle;
import 'widget_state.dart';

/// How a [TabBar]'s indicator is sized: the whole tab or its label.
enum TabBarIndicatorSize { tab, label }

/// How a scrollable [TabBar]'s tabs are placed.
enum TabAlignment { start, startOffset, fill, center }

/// When a [NavigationBar] shows its destinations' labels.
enum NavigationDestinationLabelBehavior {
  alwaysShow,
  alwaysHide,
  onlyShowSelected
}

/// How a [NavigationRail] shows its labels.
enum NavigationRailLabelType { none, selected, all }

/// Whether a [BottomNavigationBar]'s items keep their width when selected.
enum BottomNavigationBarType { fixed, shifting }

/// Whether a [SnackBar] spans the bottom edge or floats above it.
enum SnackBarBehavior { fixed, floating }

/// The look of every [AppBar] under a theme - Flutter's `AppBarThemeData`.
class AppBarThemeData {
  const AppBarThemeData({
    this.backgroundColor,
    this.foregroundColor,
    this.elevation,
    this.scrolledUnderElevation,
    this.shadowColor,
    this.surfaceTintColor,
    this.shape,
    this.iconTheme,
    this.actionsIconTheme,
    this.centerTitle,
    this.titleSpacing,
    this.leadingWidth,
    this.toolbarHeight,
    this.toolbarTextStyle,
    this.titleTextStyle,
    this.actionsPadding,
  });

  final Color? backgroundColor;
  final Color? foregroundColor;
  final double? elevation;
  final double? scrolledUnderElevation;
  final Color? shadowColor;
  final Color? surfaceTintColor;
  final ShapeBorder? shape;
  final IconThemeData? iconTheme;
  final IconThemeData? actionsIconTheme;
  final bool? centerTitle;
  final double? titleSpacing;
  final double? leadingWidth;
  final double? toolbarHeight;
  final TextStyle? toolbarTextStyle;
  final TextStyle? titleTextStyle;
  final EdgeInsets? actionsPadding;

  AppBarThemeData copyWith({
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
  }) =>
      AppBarThemeData(
        backgroundColor: backgroundColor ?? this.backgroundColor,
        foregroundColor: foregroundColor ?? this.foregroundColor,
        elevation: elevation ?? this.elevation,
        scrolledUnderElevation:
            scrolledUnderElevation ?? this.scrolledUnderElevation,
        shadowColor: shadowColor ?? this.shadowColor,
        surfaceTintColor: surfaceTintColor ?? this.surfaceTintColor,
        shape: shape ?? this.shape,
        iconTheme: iconTheme ?? this.iconTheme,
        actionsIconTheme: actionsIconTheme ?? this.actionsIconTheme,
        centerTitle: centerTitle ?? this.centerTitle,
        titleSpacing: titleSpacing ?? this.titleSpacing,
        leadingWidth: leadingWidth ?? this.leadingWidth,
        toolbarHeight: toolbarHeight ?? this.toolbarHeight,
        toolbarTextStyle: toolbarTextStyle ?? this.toolbarTextStyle,
        titleTextStyle: titleTextStyle ?? this.titleTextStyle,
        actionsPadding: actionsPadding ?? this.actionsPadding,
      );

  @override
  bool operator ==(Object other) =>
      other is AppBarThemeData &&
      other.backgroundColor == backgroundColor &&
      other.foregroundColor == foregroundColor &&
      other.elevation == elevation &&
      other.scrolledUnderElevation == scrolledUnderElevation &&
      other.shadowColor == shadowColor &&
      other.surfaceTintColor == surfaceTintColor &&
      other.shape == shape &&
      other.iconTheme == iconTheme &&
      other.actionsIconTheme == actionsIconTheme &&
      other.centerTitle == centerTitle &&
      other.titleSpacing == titleSpacing &&
      other.leadingWidth == leadingWidth &&
      other.toolbarHeight == toolbarHeight &&
      other.toolbarTextStyle == toolbarTextStyle &&
      other.titleTextStyle == titleTextStyle &&
      other.actionsPadding == actionsPadding;

  @override
  int get hashCode => Object.hashAll(<Object?>[
        backgroundColor,
        foregroundColor,
        elevation,
        scrolledUnderElevation,
        shadowColor,
        surfaceTintColor,
        shape,
        iconTheme,
        actionsIconTheme,
        centerTitle,
        titleSpacing,
        leadingWidth,
        toolbarHeight,
        toolbarTextStyle,
        titleTextStyle,
        actionsPadding
      ]);
}

/// The look of every [TabBar] under a theme - Flutter's `TabBarThemeData`.
class TabBarThemeData {
  const TabBarThemeData({
    this.indicator,
    this.indicatorColor,
    this.indicatorSize,
    this.dividerColor,
    this.dividerHeight,
    this.labelColor,
    this.labelPadding,
    this.labelStyle,
    this.unselectedLabelColor,
    this.unselectedLabelStyle,
    this.overlayColor,
    this.tabAlignment,
  });

  final Decoration? indicator;
  final Color? indicatorColor;
  final TabBarIndicatorSize? indicatorSize;
  final Color? dividerColor;
  final double? dividerHeight;
  final Color? labelColor;
  final EdgeInsets? labelPadding;
  final TextStyle? labelStyle;
  final Color? unselectedLabelColor;
  final TextStyle? unselectedLabelStyle;
  final WidgetStateProperty<Color?>? overlayColor;
  final TabAlignment? tabAlignment;

  TabBarThemeData copyWith({
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
  }) =>
      TabBarThemeData(
        indicator: indicator ?? this.indicator,
        indicatorColor: indicatorColor ?? this.indicatorColor,
        indicatorSize: indicatorSize ?? this.indicatorSize,
        dividerColor: dividerColor ?? this.dividerColor,
        dividerHeight: dividerHeight ?? this.dividerHeight,
        labelColor: labelColor ?? this.labelColor,
        labelPadding: labelPadding ?? this.labelPadding,
        labelStyle: labelStyle ?? this.labelStyle,
        unselectedLabelColor: unselectedLabelColor ?? this.unselectedLabelColor,
        unselectedLabelStyle: unselectedLabelStyle ?? this.unselectedLabelStyle,
        overlayColor: overlayColor ?? this.overlayColor,
        tabAlignment: tabAlignment ?? this.tabAlignment,
      );

  @override
  bool operator ==(Object other) =>
      other is TabBarThemeData &&
      other.indicator == indicator &&
      other.indicatorColor == indicatorColor &&
      other.indicatorSize == indicatorSize &&
      other.dividerColor == dividerColor &&
      other.dividerHeight == dividerHeight &&
      other.labelColor == labelColor &&
      other.labelPadding == labelPadding &&
      other.labelStyle == labelStyle &&
      other.unselectedLabelColor == unselectedLabelColor &&
      other.unselectedLabelStyle == unselectedLabelStyle &&
      other.overlayColor == overlayColor &&
      other.tabAlignment == tabAlignment;

  @override
  int get hashCode => Object.hashAll(<Object?>[
        indicator,
        indicatorColor,
        indicatorSize,
        dividerColor,
        dividerHeight,
        labelColor,
        labelPadding,
        labelStyle,
        unselectedLabelColor,
        unselectedLabelStyle,
        overlayColor,
        tabAlignment
      ]);
}

/// The look of every [FloatingActionButton] under a theme.
class FloatingActionButtonThemeData {
  const FloatingActionButtonThemeData({
    this.foregroundColor,
    this.backgroundColor,
    this.focusColor,
    this.hoverColor,
    this.splashColor,
    this.elevation,
    this.focusElevation,
    this.hoverElevation,
    this.disabledElevation,
    this.highlightElevation,
    this.shape,
    this.enableFeedback,
    this.iconSize,
    this.sizeConstraints,
    this.smallSizeConstraints,
    this.largeSizeConstraints,
    this.extendedSizeConstraints,
    this.extendedIconLabelSpacing,
    this.extendedPadding,
    this.extendedTextStyle,
  });

  final Color? foregroundColor;
  final Color? backgroundColor;
  final Color? focusColor;
  final Color? hoverColor;
  final Color? splashColor;
  final double? elevation;
  final double? focusElevation;
  final double? hoverElevation;
  final double? disabledElevation;
  final double? highlightElevation;
  final ShapeBorder? shape;
  final bool? enableFeedback;
  final double? iconSize;
  final BoxConstraints? sizeConstraints;
  final BoxConstraints? smallSizeConstraints;
  final BoxConstraints? largeSizeConstraints;
  final BoxConstraints? extendedSizeConstraints;
  final double? extendedIconLabelSpacing;
  final EdgeInsets? extendedPadding;
  final TextStyle? extendedTextStyle;

  FloatingActionButtonThemeData copyWith({
    Color? foregroundColor,
    Color? backgroundColor,
    Color? focusColor,
    Color? hoverColor,
    Color? splashColor,
    double? elevation,
    double? focusElevation,
    double? hoverElevation,
    double? disabledElevation,
    double? highlightElevation,
    ShapeBorder? shape,
    bool? enableFeedback,
    double? iconSize,
    BoxConstraints? sizeConstraints,
    BoxConstraints? smallSizeConstraints,
    BoxConstraints? largeSizeConstraints,
    BoxConstraints? extendedSizeConstraints,
    double? extendedIconLabelSpacing,
    EdgeInsets? extendedPadding,
    TextStyle? extendedTextStyle,
  }) =>
      FloatingActionButtonThemeData(
        foregroundColor: foregroundColor ?? this.foregroundColor,
        backgroundColor: backgroundColor ?? this.backgroundColor,
        focusColor: focusColor ?? this.focusColor,
        hoverColor: hoverColor ?? this.hoverColor,
        splashColor: splashColor ?? this.splashColor,
        elevation: elevation ?? this.elevation,
        focusElevation: focusElevation ?? this.focusElevation,
        hoverElevation: hoverElevation ?? this.hoverElevation,
        disabledElevation: disabledElevation ?? this.disabledElevation,
        highlightElevation: highlightElevation ?? this.highlightElevation,
        shape: shape ?? this.shape,
        enableFeedback: enableFeedback ?? this.enableFeedback,
        iconSize: iconSize ?? this.iconSize,
        sizeConstraints: sizeConstraints ?? this.sizeConstraints,
        smallSizeConstraints: smallSizeConstraints ?? this.smallSizeConstraints,
        largeSizeConstraints: largeSizeConstraints ?? this.largeSizeConstraints,
        extendedSizeConstraints:
            extendedSizeConstraints ?? this.extendedSizeConstraints,
        extendedIconLabelSpacing:
            extendedIconLabelSpacing ?? this.extendedIconLabelSpacing,
        extendedPadding: extendedPadding ?? this.extendedPadding,
        extendedTextStyle: extendedTextStyle ?? this.extendedTextStyle,
      );

  @override
  bool operator ==(Object other) =>
      other is FloatingActionButtonThemeData &&
      other.foregroundColor == foregroundColor &&
      other.backgroundColor == backgroundColor &&
      other.focusColor == focusColor &&
      other.hoverColor == hoverColor &&
      other.splashColor == splashColor &&
      other.elevation == elevation &&
      other.focusElevation == focusElevation &&
      other.hoverElevation == hoverElevation &&
      other.disabledElevation == disabledElevation &&
      other.highlightElevation == highlightElevation &&
      other.shape == shape &&
      other.enableFeedback == enableFeedback &&
      other.iconSize == iconSize &&
      other.sizeConstraints == sizeConstraints &&
      other.smallSizeConstraints == smallSizeConstraints &&
      other.largeSizeConstraints == largeSizeConstraints &&
      other.extendedSizeConstraints == extendedSizeConstraints &&
      other.extendedIconLabelSpacing == extendedIconLabelSpacing &&
      other.extendedPadding == extendedPadding &&
      other.extendedTextStyle == extendedTextStyle;

  @override
  int get hashCode => Object.hashAll(<Object?>[
        foregroundColor,
        backgroundColor,
        focusColor,
        hoverColor,
        splashColor,
        elevation,
        focusElevation,
        hoverElevation,
        disabledElevation,
        highlightElevation,
        shape,
        enableFeedback,
        iconSize,
        sizeConstraints,
        smallSizeConstraints,
        largeSizeConstraints,
        extendedSizeConstraints,
        extendedIconLabelSpacing,
        extendedPadding,
        extendedTextStyle
      ]);
}

/// The look of every [NavigationBar] under a theme.
class NavigationBarThemeData {
  const NavigationBarThemeData({
    this.height,
    this.backgroundColor,
    this.elevation,
    this.shadowColor,
    this.surfaceTintColor,
    this.indicatorColor,
    this.indicatorShape,
    this.labelTextStyle,
    this.iconTheme,
    this.labelBehavior,
    this.overlayColor,
    this.labelPadding,
  });

  final double? height;
  final Color? backgroundColor;
  final double? elevation;
  final Color? shadowColor;
  final Color? surfaceTintColor;
  final Color? indicatorColor;
  final ShapeBorder? indicatorShape;
  final WidgetStateProperty<TextStyle?>? labelTextStyle;
  final WidgetStateProperty<IconThemeData?>? iconTheme;
  final NavigationDestinationLabelBehavior? labelBehavior;
  final WidgetStateProperty<Color?>? overlayColor;
  final EdgeInsets? labelPadding;

  NavigationBarThemeData copyWith({
    double? height,
    Color? backgroundColor,
    double? elevation,
    Color? shadowColor,
    Color? surfaceTintColor,
    Color? indicatorColor,
    ShapeBorder? indicatorShape,
    WidgetStateProperty<TextStyle?>? labelTextStyle,
    WidgetStateProperty<IconThemeData?>? iconTheme,
    NavigationDestinationLabelBehavior? labelBehavior,
    WidgetStateProperty<Color?>? overlayColor,
    EdgeInsets? labelPadding,
  }) =>
      NavigationBarThemeData(
        height: height ?? this.height,
        backgroundColor: backgroundColor ?? this.backgroundColor,
        elevation: elevation ?? this.elevation,
        shadowColor: shadowColor ?? this.shadowColor,
        surfaceTintColor: surfaceTintColor ?? this.surfaceTintColor,
        indicatorColor: indicatorColor ?? this.indicatorColor,
        indicatorShape: indicatorShape ?? this.indicatorShape,
        labelTextStyle: labelTextStyle ?? this.labelTextStyle,
        iconTheme: iconTheme ?? this.iconTheme,
        labelBehavior: labelBehavior ?? this.labelBehavior,
        overlayColor: overlayColor ?? this.overlayColor,
        labelPadding: labelPadding ?? this.labelPadding,
      );

  @override
  bool operator ==(Object other) =>
      other is NavigationBarThemeData &&
      other.height == height &&
      other.backgroundColor == backgroundColor &&
      other.elevation == elevation &&
      other.shadowColor == shadowColor &&
      other.surfaceTintColor == surfaceTintColor &&
      other.indicatorColor == indicatorColor &&
      other.indicatorShape == indicatorShape &&
      other.labelTextStyle == labelTextStyle &&
      other.iconTheme == iconTheme &&
      other.labelBehavior == labelBehavior &&
      other.overlayColor == overlayColor &&
      other.labelPadding == labelPadding;

  @override
  int get hashCode => Object.hashAll(<Object?>[
        height,
        backgroundColor,
        elevation,
        shadowColor,
        surfaceTintColor,
        indicatorColor,
        indicatorShape,
        labelTextStyle,
        iconTheme,
        labelBehavior,
        overlayColor,
        labelPadding
      ]);
}

/// The look of every [NavigationRail] under a theme.
class NavigationRailThemeData {
  const NavigationRailThemeData({
    this.backgroundColor,
    this.elevation,
    this.unselectedLabelTextStyle,
    this.selectedLabelTextStyle,
    this.unselectedIconTheme,
    this.selectedIconTheme,
    this.groupAlignment,
    this.labelType,
    this.useIndicator,
    this.indicatorColor,
    this.indicatorShape,
    this.minWidth,
    this.minExtendedWidth,
  });

  final Color? backgroundColor;
  final double? elevation;
  final TextStyle? unselectedLabelTextStyle;
  final TextStyle? selectedLabelTextStyle;
  final IconThemeData? unselectedIconTheme;
  final IconThemeData? selectedIconTheme;
  final double? groupAlignment;
  final NavigationRailLabelType? labelType;
  final bool? useIndicator;
  final Color? indicatorColor;
  final ShapeBorder? indicatorShape;
  final double? minWidth;
  final double? minExtendedWidth;

  NavigationRailThemeData copyWith({
    Color? backgroundColor,
    double? elevation,
    TextStyle? unselectedLabelTextStyle,
    TextStyle? selectedLabelTextStyle,
    IconThemeData? unselectedIconTheme,
    IconThemeData? selectedIconTheme,
    double? groupAlignment,
    NavigationRailLabelType? labelType,
    bool? useIndicator,
    Color? indicatorColor,
    ShapeBorder? indicatorShape,
    double? minWidth,
    double? minExtendedWidth,
  }) =>
      NavigationRailThemeData(
        backgroundColor: backgroundColor ?? this.backgroundColor,
        elevation: elevation ?? this.elevation,
        unselectedLabelTextStyle:
            unselectedLabelTextStyle ?? this.unselectedLabelTextStyle,
        selectedLabelTextStyle:
            selectedLabelTextStyle ?? this.selectedLabelTextStyle,
        unselectedIconTheme: unselectedIconTheme ?? this.unselectedIconTheme,
        selectedIconTheme: selectedIconTheme ?? this.selectedIconTheme,
        groupAlignment: groupAlignment ?? this.groupAlignment,
        labelType: labelType ?? this.labelType,
        useIndicator: useIndicator ?? this.useIndicator,
        indicatorColor: indicatorColor ?? this.indicatorColor,
        indicatorShape: indicatorShape ?? this.indicatorShape,
        minWidth: minWidth ?? this.minWidth,
        minExtendedWidth: minExtendedWidth ?? this.minExtendedWidth,
      );

  @override
  bool operator ==(Object other) =>
      other is NavigationRailThemeData &&
      other.backgroundColor == backgroundColor &&
      other.elevation == elevation &&
      other.unselectedLabelTextStyle == unselectedLabelTextStyle &&
      other.selectedLabelTextStyle == selectedLabelTextStyle &&
      other.unselectedIconTheme == unselectedIconTheme &&
      other.selectedIconTheme == selectedIconTheme &&
      other.groupAlignment == groupAlignment &&
      other.labelType == labelType &&
      other.useIndicator == useIndicator &&
      other.indicatorColor == indicatorColor &&
      other.indicatorShape == indicatorShape &&
      other.minWidth == minWidth &&
      other.minExtendedWidth == minExtendedWidth;

  @override
  int get hashCode => Object.hashAll(<Object?>[
        backgroundColor,
        elevation,
        unselectedLabelTextStyle,
        selectedLabelTextStyle,
        unselectedIconTheme,
        selectedIconTheme,
        groupAlignment,
        labelType,
        useIndicator,
        indicatorColor,
        indicatorShape,
        minWidth,
        minExtendedWidth
      ]);
}

/// The look of every [BottomNavigationBar] under a theme.
class BottomNavigationBarThemeData {
  const BottomNavigationBarThemeData({
    this.backgroundColor,
    this.elevation,
    this.selectedIconTheme,
    this.unselectedIconTheme,
    this.selectedItemColor,
    this.unselectedItemColor,
    this.selectedLabelStyle,
    this.unselectedLabelStyle,
    this.showSelectedLabels,
    this.showUnselectedLabels,
    this.type,
    this.enableFeedback,
  });

  final Color? backgroundColor;
  final double? elevation;
  final IconThemeData? selectedIconTheme;
  final IconThemeData? unselectedIconTheme;
  final Color? selectedItemColor;
  final Color? unselectedItemColor;
  final TextStyle? selectedLabelStyle;
  final TextStyle? unselectedLabelStyle;
  final bool? showSelectedLabels;
  final bool? showUnselectedLabels;
  final BottomNavigationBarType? type;
  final bool? enableFeedback;

  BottomNavigationBarThemeData copyWith({
    Color? backgroundColor,
    double? elevation,
    IconThemeData? selectedIconTheme,
    IconThemeData? unselectedIconTheme,
    Color? selectedItemColor,
    Color? unselectedItemColor,
    TextStyle? selectedLabelStyle,
    TextStyle? unselectedLabelStyle,
    bool? showSelectedLabels,
    bool? showUnselectedLabels,
    BottomNavigationBarType? type,
    bool? enableFeedback,
  }) =>
      BottomNavigationBarThemeData(
        backgroundColor: backgroundColor ?? this.backgroundColor,
        elevation: elevation ?? this.elevation,
        selectedIconTheme: selectedIconTheme ?? this.selectedIconTheme,
        unselectedIconTheme: unselectedIconTheme ?? this.unselectedIconTheme,
        selectedItemColor: selectedItemColor ?? this.selectedItemColor,
        unselectedItemColor: unselectedItemColor ?? this.unselectedItemColor,
        selectedLabelStyle: selectedLabelStyle ?? this.selectedLabelStyle,
        unselectedLabelStyle: unselectedLabelStyle ?? this.unselectedLabelStyle,
        showSelectedLabels: showSelectedLabels ?? this.showSelectedLabels,
        showUnselectedLabels: showUnselectedLabels ?? this.showUnselectedLabels,
        type: type ?? this.type,
        enableFeedback: enableFeedback ?? this.enableFeedback,
      );

  @override
  bool operator ==(Object other) =>
      other is BottomNavigationBarThemeData &&
      other.backgroundColor == backgroundColor &&
      other.elevation == elevation &&
      other.selectedIconTheme == selectedIconTheme &&
      other.unselectedIconTheme == unselectedIconTheme &&
      other.selectedItemColor == selectedItemColor &&
      other.unselectedItemColor == unselectedItemColor &&
      other.selectedLabelStyle == selectedLabelStyle &&
      other.unselectedLabelStyle == unselectedLabelStyle &&
      other.showSelectedLabels == showSelectedLabels &&
      other.showUnselectedLabels == showUnselectedLabels &&
      other.type == type &&
      other.enableFeedback == enableFeedback;

  @override
  int get hashCode => Object.hashAll(<Object?>[
        backgroundColor,
        elevation,
        selectedIconTheme,
        unselectedIconTheme,
        selectedItemColor,
        unselectedItemColor,
        selectedLabelStyle,
        unselectedLabelStyle,
        showSelectedLabels,
        showUnselectedLabels,
        type,
        enableFeedback
      ]);
}

/// The look of every [Drawer] under a theme.
class DrawerThemeData {
  const DrawerThemeData({
    this.backgroundColor,
    this.scrimColor,
    this.elevation,
    this.shadowColor,
    this.surfaceTintColor,
    this.shape,
    this.endShape,
    this.width,
  });

  final Color? backgroundColor;
  final Color? scrimColor;
  final double? elevation;
  final Color? shadowColor;
  final Color? surfaceTintColor;
  final ShapeBorder? shape;
  final ShapeBorder? endShape;
  final double? width;

  DrawerThemeData copyWith({
    Color? backgroundColor,
    Color? scrimColor,
    double? elevation,
    Color? shadowColor,
    Color? surfaceTintColor,
    ShapeBorder? shape,
    ShapeBorder? endShape,
    double? width,
  }) =>
      DrawerThemeData(
        backgroundColor: backgroundColor ?? this.backgroundColor,
        scrimColor: scrimColor ?? this.scrimColor,
        elevation: elevation ?? this.elevation,
        shadowColor: shadowColor ?? this.shadowColor,
        surfaceTintColor: surfaceTintColor ?? this.surfaceTintColor,
        shape: shape ?? this.shape,
        endShape: endShape ?? this.endShape,
        width: width ?? this.width,
      );

  @override
  bool operator ==(Object other) =>
      other is DrawerThemeData &&
      other.backgroundColor == backgroundColor &&
      other.scrimColor == scrimColor &&
      other.elevation == elevation &&
      other.shadowColor == shadowColor &&
      other.surfaceTintColor == surfaceTintColor &&
      other.shape == shape &&
      other.endShape == endShape &&
      other.width == width;

  @override
  int get hashCode => Object.hashAll(<Object?>[
        backgroundColor,
        scrimColor,
        elevation,
        shadowColor,
        surfaceTintColor,
        shape,
        endShape,
        width
      ]);
}

/// The look of every [NavigationDrawer] under a theme.
class NavigationDrawerThemeData {
  const NavigationDrawerThemeData({
    this.tileHeight,
    this.backgroundColor,
    this.elevation,
    this.shadowColor,
    this.surfaceTintColor,
    this.indicatorColor,
    this.indicatorShape,
    this.indicatorSize,
    this.labelTextStyle,
    this.iconTheme,
  });

  final double? tileHeight;
  final Color? backgroundColor;
  final double? elevation;
  final Color? shadowColor;
  final Color? surfaceTintColor;
  final Color? indicatorColor;
  final ShapeBorder? indicatorShape;
  final Size? indicatorSize;
  final WidgetStateProperty<TextStyle?>? labelTextStyle;
  final WidgetStateProperty<IconThemeData?>? iconTheme;

  NavigationDrawerThemeData copyWith({
    double? tileHeight,
    Color? backgroundColor,
    double? elevation,
    Color? shadowColor,
    Color? surfaceTintColor,
    Color? indicatorColor,
    ShapeBorder? indicatorShape,
    Size? indicatorSize,
    WidgetStateProperty<TextStyle?>? labelTextStyle,
    WidgetStateProperty<IconThemeData?>? iconTheme,
  }) =>
      NavigationDrawerThemeData(
        tileHeight: tileHeight ?? this.tileHeight,
        backgroundColor: backgroundColor ?? this.backgroundColor,
        elevation: elevation ?? this.elevation,
        shadowColor: shadowColor ?? this.shadowColor,
        surfaceTintColor: surfaceTintColor ?? this.surfaceTintColor,
        indicatorColor: indicatorColor ?? this.indicatorColor,
        indicatorShape: indicatorShape ?? this.indicatorShape,
        indicatorSize: indicatorSize ?? this.indicatorSize,
        labelTextStyle: labelTextStyle ?? this.labelTextStyle,
        iconTheme: iconTheme ?? this.iconTheme,
      );

  @override
  bool operator ==(Object other) =>
      other is NavigationDrawerThemeData &&
      other.tileHeight == tileHeight &&
      other.backgroundColor == backgroundColor &&
      other.elevation == elevation &&
      other.shadowColor == shadowColor &&
      other.surfaceTintColor == surfaceTintColor &&
      other.indicatorColor == indicatorColor &&
      other.indicatorShape == indicatorShape &&
      other.indicatorSize == indicatorSize &&
      other.labelTextStyle == labelTextStyle &&
      other.iconTheme == iconTheme;

  @override
  int get hashCode => Object.hashAll(<Object?>[
        tileHeight,
        backgroundColor,
        elevation,
        shadowColor,
        surfaceTintColor,
        indicatorColor,
        indicatorShape,
        indicatorSize,
        labelTextStyle,
        iconTheme
      ]);
}

/// The look of every [SnackBar] under a theme.
class SnackBarThemeData {
  const SnackBarThemeData({
    this.backgroundColor,
    this.actionTextColor,
    this.disabledActionTextColor,
    this.contentTextStyle,
    this.elevation,
    this.shape,
    this.behavior,
    this.width,
    this.insetPadding,
    this.showCloseIcon,
    this.closeIconColor,
    this.actionOverflowThreshold,
    this.actionBackgroundColor,
    this.disabledActionBackgroundColor,
  });

  final Color? backgroundColor;
  final Color? actionTextColor;
  final Color? disabledActionTextColor;
  final TextStyle? contentTextStyle;
  final double? elevation;
  final ShapeBorder? shape;
  final SnackBarBehavior? behavior;
  final double? width;
  final EdgeInsets? insetPadding;
  final bool? showCloseIcon;
  final Color? closeIconColor;
  final double? actionOverflowThreshold;
  final Color? actionBackgroundColor;
  final Color? disabledActionBackgroundColor;

  SnackBarThemeData copyWith({
    Color? backgroundColor,
    Color? actionTextColor,
    Color? disabledActionTextColor,
    TextStyle? contentTextStyle,
    double? elevation,
    ShapeBorder? shape,
    SnackBarBehavior? behavior,
    double? width,
    EdgeInsets? insetPadding,
    bool? showCloseIcon,
    Color? closeIconColor,
    double? actionOverflowThreshold,
    Color? actionBackgroundColor,
    Color? disabledActionBackgroundColor,
  }) =>
      SnackBarThemeData(
        backgroundColor: backgroundColor ?? this.backgroundColor,
        actionTextColor: actionTextColor ?? this.actionTextColor,
        disabledActionTextColor:
            disabledActionTextColor ?? this.disabledActionTextColor,
        contentTextStyle: contentTextStyle ?? this.contentTextStyle,
        elevation: elevation ?? this.elevation,
        shape: shape ?? this.shape,
        behavior: behavior ?? this.behavior,
        width: width ?? this.width,
        insetPadding: insetPadding ?? this.insetPadding,
        showCloseIcon: showCloseIcon ?? this.showCloseIcon,
        closeIconColor: closeIconColor ?? this.closeIconColor,
        actionOverflowThreshold:
            actionOverflowThreshold ?? this.actionOverflowThreshold,
        actionBackgroundColor:
            actionBackgroundColor ?? this.actionBackgroundColor,
        disabledActionBackgroundColor:
            disabledActionBackgroundColor ?? this.disabledActionBackgroundColor,
      );

  @override
  bool operator ==(Object other) =>
      other is SnackBarThemeData &&
      other.backgroundColor == backgroundColor &&
      other.actionTextColor == actionTextColor &&
      other.disabledActionTextColor == disabledActionTextColor &&
      other.contentTextStyle == contentTextStyle &&
      other.elevation == elevation &&
      other.shape == shape &&
      other.behavior == behavior &&
      other.width == width &&
      other.insetPadding == insetPadding &&
      other.showCloseIcon == showCloseIcon &&
      other.closeIconColor == closeIconColor &&
      other.actionOverflowThreshold == actionOverflowThreshold &&
      other.actionBackgroundColor == actionBackgroundColor &&
      other.disabledActionBackgroundColor == disabledActionBackgroundColor;

  @override
  int get hashCode => Object.hashAll(<Object?>[
        backgroundColor,
        actionTextColor,
        disabledActionTextColor,
        contentTextStyle,
        elevation,
        shape,
        behavior,
        width,
        insetPadding,
        showCloseIcon,
        closeIconColor,
        actionOverflowThreshold,
        actionBackgroundColor,
        disabledActionBackgroundColor
      ]);
}
