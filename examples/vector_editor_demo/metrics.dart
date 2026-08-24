/// Every fixed dimension of the editor chrome, in one place.
///
/// Chrome metrics are the numbers most likely to be copied into three files and
/// then changed in one: the menu bar's height is also the offset a drop-down
/// opens at, and the tool box's width is also where the vertical ruler starts.
/// Naming them here is what keeps those agreements from drifting.
///
/// ## The grid
///
/// Every number here is a multiple of 4, and every height is one of the
/// framework's own: `ThemeData.effectiveControlHeight` at the compact density
/// is 28, `effectiveRowHeight` is 24, and the editor's bands are built from
/// those two plus the 4 px spacing scale in `doc/architecture/SISTEMA_DE_DESIGN.md`.
/// The editor picks `ThemeData.fluentLight`, which is the compact theme, so a
/// bar declared 28 px tall here is exactly as tall as the combo box that sits
/// in it - which is the whole reason the numbers are not free-hand any more.
/// The values they replaced (24, 30, 26, 22, 18, 15) were each right on their
/// own and agreed with nothing.
library;

/// Heights of the horizontal bands, top to bottom.
abstract final class ChromeMetrics {
  /// The menu bar, and therefore the y a drop-down opens at.
  ///
  /// One row height plus a hair of air. A menu bar shorter than a row of text
  /// is the single loudest "this is Windows 95" signal in the window: it was
  /// 24 px, which left three pixels above a 12 px label.
  static const double menuBarHeight = 28;

  /// One menu header's width per character of its label, plus the padding.
  ///
  /// Fixed rather than measured because the drop-down has to know where the
  /// header it belongs to starts, and asking the text engine from a widget's
  /// build would mean shaping every header twice per frame.
  static const double menuHeaderCharacterWidth = 7.0;
  static const double menuHeaderPadding = 12.0;

  /// The icon toolbar under the menu bar.
  ///
  /// A 28 px button (one control) plus 4 px of air above and below.
  static const double toolbarHeight = 36;
  static const double toolbarIconSize = 16;

  /// The contextual property bar. One control tall plus the same air, so the
  /// combo boxes and spin boxes in it are not wedged against its edges.
  static const double contextPanelHeight = 36;

  /// The document tab strip.
  static const double documentTabsHeight = 28;

  /// The vertical tool box down the left edge.
  ///
  /// 32 = a 28 px button plus 2 px either side. The button is one control tall
  /// and square, so the tool palette is on the same rhythm as the toolbar.
  static const double toolboxWidth = 32;
  static const double toolboxButtonSize = 28;
  static const double toolboxIconSize = 16;

  /// Ruler thickness, and therefore the size of the corner button between the
  /// two rulers.
  static const double rulerThickness = 20;

  /// The colour palette strip along the bottom.
  static const double paletteSwatchSize = 16;
  static const double paletteHeight = 28;

  /// The status bar. One row plus air; it holds 11 px text and a few icons.
  static const double statusBarHeight = 28;

  /// The right-hand plugin area: the collapsed tab strip, and the panel body
  /// that opens beside it.
  static const double collapsedTabStripWidth = 28;
  static const double pluginPanelWidth = 260;

  /// Gaps used inside bars, so a group reads as a group.
  ///
  /// The 4 px grid: [barGroupSpacing] is one step and [barPadding] two.
  static const double barGroupSpacing = 4;
  static const double barPadding = 8;
}

/// Zoom limits and the step a zoom button takes.
abstract final class ZoomMetrics {
  static const double minimum = 0.02;
  static const double maximum = 64.0;
  static const double step = 1.25;

  /// Margin left around the page when fitting it to the window.
  static const double fitMargin = 24.0;
}
