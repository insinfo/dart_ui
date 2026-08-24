/// Theme contract for docking headers, tabs and split dividers.
library;

import '../../graphics/color.dart';
import '../theme.dart';
import '../widget.dart';

final class DockingThemeData {
  const DockingThemeData({
    required this.backgroundColor,
    required this.headerColor,
    required this.activeHeaderColor,
    required this.borderColor,
    required this.foregroundColor,
    required this.inactiveForegroundColor,
    required this.accentColor,
    this.headerHeight = 36,
    this.dividerThickness = 6,
    this.cornerRadius = 6,
  });

  /// Docking chrome built from a [ThemeData].
  ///
  /// The header height and the divider follow the theme's density now: a
  /// compact application whose panel headers stayed 36 px tall had one band of
  /// chrome that ignored the density switch, and it showed.
  factory DockingThemeData.fromTheme(ThemeData theme) => DockingThemeData(
        headerHeight: theme.effectiveControlHeight,
        dividerThickness: theme.effectiveGap,
        cornerRadius: theme.cornerRadius,
        backgroundColor: theme.surface,
        headerColor: theme.surfaceAlternate,
        activeHeaderColor: theme.surface,
        borderColor: theme.border,
        foregroundColor: theme.foreground,
        inactiveForegroundColor: theme.foregroundSecondary,
        accentColor: theme.accent,
      );

  final Color backgroundColor;
  final Color headerColor;
  final Color activeHeaderColor;
  final Color borderColor;
  final Color foregroundColor;
  final Color inactiveForegroundColor;
  final Color accentColor;
  final double headerHeight;
  final double dividerThickness;
  final double cornerRadius;

  DockingThemeData copyWith({
    Color? backgroundColor,
    Color? headerColor,
    Color? activeHeaderColor,
    Color? borderColor,
    Color? foregroundColor,
    Color? inactiveForegroundColor,
    Color? accentColor,
    double? headerHeight,
    double? dividerThickness,
    double? cornerRadius,
  }) =>
      DockingThemeData(
        backgroundColor: backgroundColor ?? this.backgroundColor,
        headerColor: headerColor ?? this.headerColor,
        activeHeaderColor: activeHeaderColor ?? this.activeHeaderColor,
        borderColor: borderColor ?? this.borderColor,
        foregroundColor: foregroundColor ?? this.foregroundColor,
        inactiveForegroundColor:
            inactiveForegroundColor ?? this.inactiveForegroundColor,
        accentColor: accentColor ?? this.accentColor,
        headerHeight: headerHeight ?? this.headerHeight,
        dividerThickness: dividerThickness ?? this.dividerThickness,
        cornerRadius: cornerRadius ?? this.cornerRadius,
      );
}

final class DockingTheme extends InheritedWidget {
  const DockingTheme({
    super.key,
    required this.data,
    required super.child,
  });

  final DockingThemeData data;

  static DockingThemeData of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DockingTheme>()?.data ??
      DockingThemeData.fromTheme(Theme.of(context));

  @override
  bool updateShouldNotify(DockingTheme oldWidget) => data != oldWidget.data;
}
