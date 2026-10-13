/// The editor's chrome dimensions, from the theme.
library;

import 'package:dart_ui/dart_ui.dart';

/// Every dimension of the editor chrome, in one place, derived from the
/// theme.
///
/// Chrome metrics are the numbers most likely to be copied into three files and
/// then changed in one: the menu bar's height is also the offset a drop-down
/// opens at, and the tool box's width is also where the vertical ruler starts.
/// Naming them here is what keeps those agreements from drifting.
///
/// ## Where the numbers come from
///
/// From the theme's control and row heights, its text size and its icon
/// size - which `ThemeData.adaptedToPlatform` sets to what the desktop's own
/// applications use: 28 px controls and 24 px rows on a Mac, 32 and 28 on
/// Windows. The editor's bands were constants once (a 28 px menu bar, 16 px
/// toolbar icons, 12 px text) and read as a toy beside every other window:
/// a bar is one control or one row plus air, so it grows with them.
final class ChromeMetrics {
  ChromeMetrics.of(ThemeData theme)
      : control = theme.effectiveControlHeight,
        row = theme.effectiveRowHeight,
        text = theme.fontSize,
        icon = theme.iconTheme.size ?? 16;

  /// The theme's control height, row height, text size and icon size.
  final double control;
  final double row;
  final double text;
  final double icon;

  /// The menu bar, and therefore the y a drop-down opens at: one row plus
  /// a hair of air.
  double get menuBarHeight => row + 4;

  /// The icon toolbar under the menu bar: a control-sized button plus 4 px
  /// of air above and below.
  double get toolbarHeight => control + 8;
  double get toolbarIconSize => icon + 2;

  /// The contextual property bar: one control tall plus the same air, so the
  /// combo boxes and spin boxes in it are not wedged against its edges.
  double get contextPanelHeight => control + 8;

  /// The document tab strip.
  double get documentTabsHeight => row + 4;

  /// The vertical tool box down the left edge: square buttons a little
  /// larger than a control - they are aimed at all day - and 4 px either side.
  double get toolboxButtonSize => control + 4;
  double get toolboxWidth => toolboxButtonSize + 8;
  double get toolboxIconSize => icon + 4;

  /// Ruler thickness, and therefore the size of the corner button between the
  /// two rulers: room for a label a size under the text.
  double get rulerThickness => (text + 7).roundToDouble();

  /// The colour palette strip along the bottom.
  double get paletteSwatchSize => row - 6;
  double get paletteHeight => row + 4;

  /// A field in a bar - spin box, combo box, text box: one control tall.
  double get fieldHeight => control;

  /// [designed], a width laid out for 12 px text, at this theme's text size,
  /// so a field still fits its numbers when the type grows.
  double widthFor(double designed) => (designed * text / 12).roundToDouble();

  /// The status bar: one row plus air.
  double get statusBarHeight => row + 4;

  /// The right-hand plugin area.
  static const double pluginPanelWidth = 300;

  /// The title row of each dock section.
  double get dockHeaderHeight => control + 2;

  /// Gaps used inside bars, so a group reads as a group: the 4 px grid,
  /// [barGroupSpacing] one step and [barPadding] two.
  static const double barGroupSpacing = 4;
  static const double barPadding = 8;
}
