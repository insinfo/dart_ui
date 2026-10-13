/// How far the view zooms, and by how much a step goes.
library;

/// Zoom limits and the step a zoom button takes.
abstract final class ZoomMetrics {
  static const double minimum = 0.02;
  static const double maximum = 64.0;
  static const double step = 1.25;

  /// Margin left around the page when fitting it to the window.
  static const double fitMargin = 24.0;
}
