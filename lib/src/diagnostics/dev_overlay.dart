/// The developer overlay: frame cost, drawn on top of the frame it measured.
///
/// Section 37.1 asks for an overlay that shows what the frame cost without
/// needing a second window, a profiler, or a build flag. Two properties decide
/// whether it is usable:
///
///   * it must **not perturb what it measures**. The overlay records timings
///     handed to it and appends its own commands after the scene is built, so
///     it adds display-list commands but no layout, no build and no allocation
///     per frame beyond a fixed ring buffer;
///   * it must show the **distribution**, not the last frame. One slow frame in
///     sixty is invisible in an average and obvious in a bar chart, and one
///     slow frame in sixty is exactly what a dropped-frame complaint is.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../graphics/display_list.dart';
import '../graphics/display_list_geometry.dart';
import '../rendering/text/font_registry.dart';
import '../text/typeface.dart';

/// One frame's timings, in microseconds.
final class FrameTiming {
  const FrameTiming({
    this.build = 0,
    this.layout = 0,
    this.paint = 0,
    this.raster = 0,
  });

  final int build;
  final int layout;
  final int paint;
  final int raster;

  int get total => build + layout + paint + raster;

  @override
  String toString() => 'FrameTiming(${total}us)';
}

/// A fixed-size ring of recent frames.
///
/// Fixed size because a diagnostic that grows without bound is a leak that only
/// shows up in the long-running sessions where diagnostics matter most.
final class FrameStatistics {
  FrameStatistics({this.capacity = 120});

  final int capacity;
  final List<FrameTiming> _frames = <FrameTiming>[];
  int _next = 0;

  List<FrameTiming> get frames => List<FrameTiming>.unmodifiable(_frames);

  int get count => _frames.length;

  void record(FrameTiming timing) {
    if (_frames.length < capacity) {
      _frames.add(timing);
      return;
    }
    _frames[_next] = timing;
    _next = (_next + 1) % capacity;
  }

  void clear() {
    _frames.clear();
    _next = 0;
  }

  /// Mean total frame time in microseconds, or 0 when nothing is recorded.
  double get averageTotal {
    if (_frames.isEmpty) return 0;
    int sum = 0;
    for (final FrameTiming frame in _frames) {
      sum += frame.total;
    }
    return sum / _frames.length;
  }

  int get worstTotal {
    int worst = 0;
    for (final FrameTiming frame in _frames) {
      if (frame.total > worst) worst = frame.total;
    }
    return worst;
  }

  /// The [percentile]th percentile of total frame time, 0 to 100.
  ///
  /// The p99 is the number that corresponds to what a user notices; a mean of
  /// 8 ms with a p99 of 40 ms is a janky application that looks fine on paper.
  ///
  /// Nearest-rank, so "p99" means what it is read to mean: at most 1% of
  /// recorded frames were worse than this. The percent-of-range convention
  /// would report the *second* worst frame in a hundred as the p99 and hide
  /// the single dropped frame that prompted the question.
  int percentileTotal(double percentile) {
    if (_frames.isEmpty) return 0;
    final List<int> totals = <int>[
      for (final FrameTiming frame in _frames) frame.total,
    ]..sort();
    final int rank = (percentile / 100 * totals.length).ceil();
    return totals[(rank - 1).clamp(0, totals.length - 1)];
  }

  /// Frames slower than [budget], the count a "dropped frames" report means.
  int framesOverBudget(Duration budget) {
    final int limit = budget.inMicroseconds;
    int over = 0;
    for (final FrameTiming frame in _frames) {
      if (frame.total > limit) over++;
    }
    return over;
  }
}

/// Draws the overlay into a display list.
final class DevOverlay {
  DevOverlay({
    this.statistics,
    this.budget = const Duration(microseconds: 16667),
    this.showChart = true,
  });

  final FrameStatistics? statistics;

  /// The per-frame budget a bar is measured against; 16.667 ms is 60 Hz.
  final Duration budget;

  final bool showChart;

  /// Smaller than interface text: the overlay sits on top of the application
  /// and covering it is a worse failure than being slightly hard to read.
  static const double _fontSize = 10.0;

  /// The line spacing used when no font was found, and the reason the overlay
  /// still lays out then: the numbers are missing, but the panel and the chart
  /// keep the shape a reader expects.
  static const double _fallbackLineHeight = 12.0;

  static const double _chartHeight = 32.0;
  static const double _barWidth = 2.0;

  /// Appends the overlay at the top-left of [bounds].
  ///
  /// Called after the scene, so it draws over it. It saves and restores, so a
  /// caller's clip and transform survive - an overlay that leaked a transform
  /// would corrupt the next frame rather than its own.
  void paint(DisplayList list, Rect bounds, {String? extraLine}) {
    final FrameStatistics? stats = statistics;
    if (stats == null || stats.count == 0) return;

    final ScaledTypeface? face = FontRegistry.instance.uiFont(_fontSize);
    final double lineHeight = face?.lineHeight ?? _fallbackLineHeight;

    final double width = showChart
        ? (stats.count * _barWidth + 8).clamp(120.0, bounds.width)
        : 120.0;
    final double height = lineHeight * (extraLine == null ? 3 : 4) +
        (showChart ? _chartHeight : 0) +
        8;

    list.save();
    list.clipRectangle(bounds);

    final int background =
        list.addPaint(colorArgb: 0xC0000000, antiAlias: false);
    list.drawRectangle(
      Rect.fromLTWH(bounds.left, bounds.top, width, height),
      background,
    );

    final int text = list.addPaint(colorArgb: 0xFFE0E0E0, antiAlias: true);
    double y = bounds.top + 3;
    void line(String value) {
      if (face != null) {
        uiTextPainter.paintInBox(
          list,
          value,
          face,
          Offset(bounds.left + 4, y),
          text,
        );
      }
      y += lineHeight;
    }

    line('AVG ${_ms(stats.averageTotal.round())}MS');
    line('P99 ${_ms(stats.percentileTotal(99))}MS');
    line('OVER ${stats.framesOverBudget(budget)}/${stats.count}');
    if (extraLine != null) line(extraLine);

    if (showChart) _paintChart(list, bounds, width, y, stats);

    list.restore();
  }

  void _paintChart(
    DisplayList list,
    Rect bounds,
    double width,
    double top,
    FrameStatistics stats,
  ) {
    final int limit = budget.inMicroseconds;
    // The scale is the budget, not the worst frame: a chart normalized to its
    // own maximum makes every session look equally bad and hides the only
    // number that matters, which is "over or under".
    final double scale = _chartHeight / (limit * 2);
    final int good = list.addPaint(colorArgb: 0xFF3FBF5F, antiAlias: false);
    final int bad = list.addPaint(colorArgb: 0xFFE04030, antiAlias: false);
    final int budgetLine =
        list.addPaint(colorArgb: 0x80FFFFFF, antiAlias: false);

    final double baseline = top + _chartHeight;
    list.drawRectangle(
      Rect.fromLTWH(
        bounds.left + 4,
        baseline - limit * scale,
        width - 8,
        1,
      ),
      budgetLine,
    );

    final List<FrameTiming> frames = stats.frames;
    for (int i = 0; i < frames.length; i++) {
      final int total = frames[i].total;
      final double barHeight = (total * scale).clamp(1.0, _chartHeight);
      list.drawRectangle(
        Rect.fromLTWH(
          bounds.left + 4 + i * _barWidth,
          baseline - barHeight,
          _barWidth - 0.5,
          barHeight,
        ),
        total > limit ? bad : good,
      );
    }
  }

  static String _ms(int microseconds) =>
      (microseconds / 1000).toStringAsFixed(1);
}
