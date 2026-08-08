/// The scanline path filler: a path in, coverage spans out.
///
/// ## Coverage is area, not samples
///
/// Every pixel this reports carries an *exact* area coverage: the fraction of
/// the pixel's square that lies inside the path, computed analytically, not
/// estimated by sampling. There is no supersampling grid here - no 4x, no 16x,
/// no sample count to tune - and therefore none of the banding a sample grid
/// produces on a nearly horizontal edge, where N samples can only ever express
/// N+1 levels of grey.
///
/// The method is the signed-area accumulation used by FreeType's smooth
/// rasteriser and by font-rs. For one scanline the filler keeps an
/// accumulation buffer with one slot per pixel. Each edge crossing the
/// scanline deposits its *signed area contribution* into the slots it passes
/// through - a trapezoid split across pixel columns, weighted by the edge's
/// direction and by how much of the scanline's height it spans. A running sum
/// across the buffer then yields, at every pixel, the winding number of the
/// path there expressed as a fraction: exactly 1.0 deep inside a
/// clockwise-wound shape, exactly 0.0 outside, and the covered fraction on a
/// boundary pixel. The fill rule is applied to that number and it becomes an
/// alpha.
///
/// This is worth being precise about, because the accumulation is exact only
/// where at most one edge passes through a pixel. Where two edges of the same
/// path cross *inside a single pixel* - the tip of a very thin wedge, the
/// centre of a star drawn at 8 px - the running sum adds their contributions
/// instead of intersecting their half-planes, and the result can be off by a
/// fraction of that one pixel. That is the same approximation every
/// production area rasteriser makes short of full analytic clipping, it is
/// bounded by one pixel of area, and it is stated here rather than discovered.
///
/// ## The compositor consumes it unchanged
///
/// Coverage leaves as a byte in 1..255, which is what `mul255` multiplies a
/// paint's alpha by. Nothing about it is specific to path filling: an
/// antialiased rectangle producing a coverage byte per pixel and this filler
/// producing one per span feed the identical blend. See [CoverageSpanSink].
///
/// ## What this does not do
///
/// * **Strokes.** This fills. A stroked path has to be converted to the
///   outline of its pen sweep first, and nothing in this framework does that
///   yet - see `Path`. A caller holding a stroke-styled paint must not send it
///   here expecting a line; it would get the region the outline encloses.
/// * **Clipping to anything but a rectangle.** The clip is a rectangle, in
///   the same integer device pixels the rest of the renderer uses. Path
///   clipping is the natural next user of this file - a clip mask is this
///   filler's spans stored per row instead of blended - but it is not here.
library;

import 'dart:typed_data';

import '../../geometry/path.dart';
import '../../geometry/rect.dart';
import '../../geometry/transform2d.dart';
import 'coverage_span_sink.dart';
import 'fill_rule.dart';

/// Turns paths into coverage spans, reusing its buffers across fills.
///
/// One instance per rasterising thread, kept alive across frames. Everything
/// it needs - the edge list, the active-edge list, the per-row accumulator -
/// is a field that grows to the largest path it has seen and is then reused,
/// so a steady-state frame allocates nothing here. [bufferGrowths] is the
/// observable proof of that, and a test asserts it stops increasing.
final class ScanlineFiller {
  ScanlineFiller();

  /// Doubles per edge: `x0, y0, x1, y1, dxdy`, always with `y0 < y1`.
  ///
  /// Doubles rather than the float32 the path stores its points in. The
  /// accumulation sums many small products per scanline, and float32 loses
  /// enough of them that a fully covered interior pixel can come out at 254
  /// instead of 255 - a visible seam between a shape and the rectangle fill
  /// next to it. The memory is 40 bytes per edge and it is transient.
  static const int _edgeStride = 5;

  Float64List _edges = Float64List(128 * _edgeStride);

  /// +1 for an edge that runs downward in the original path, -1 for one that
  /// runs upward. Stored apart from the coordinates because it is the only
  /// thing that survives the swap that makes `y0 < y1`, and it is what carries
  /// the winding direction the non-zero rule needs.
  Int8List _edgeDirections = Int8List(128);

  /// Singly linked lists of edges, keyed by the scanline they become active
  /// on. Cheaper than sorting: bucketing is one pass and no comparator, and
  /// the sweep needs edges grouped by starting row, not fully ordered.
  Int32List _edgeNext = Int32List(128);
  Int32List _buckets = Int32List(0);

  /// Edges overlapping the row being processed. Compacted in place each row.
  Int32List _active = Int32List(128);

  /// One slot per pixel of the clip's width, plus two: an edge clamped to the
  /// right clip boundary writes one past the last pixel, and the narrow-column
  /// case writes one past that.
  Float64List _accumulator = Float64List(0);

  late final _EdgeCollector _collector = _EdgeCollector(this);

  int _edgeCount = 0;
  int _growths = 0;

  // Clip and vertical extent of the fill in progress. Fields rather than
  // arguments because the edge collector is called back from inside
  // Path.flattenTo and would otherwise have to carry them.
  int _clipLeft = 0;
  int _clipRight = 0;
  double _clipTop = 0;
  double _clipBottom = 0;
  double _minY = double.infinity;
  double _maxY = double.negativeInfinity;

  /// How many times a backing buffer has been reallocated since construction.
  /// Across steady-state frames this must stop increasing.
  int get bufferGrowths => _growths;

  /// Edges the current buffer can hold.
  int get edgeCapacity => _edges.length ~/ _edgeStride;

  /// Pixels per scanline the accumulator can hold, ignoring its two slack
  /// slots.
  int get accumulatorCapacity =>
      _accumulator.isEmpty ? 0 : _accumulator.length - 2;

  /// Fills [path] and reports the covered pixels to [sink].
  ///
  /// [path] is in its own coordinate space and [transform] maps it to device
  /// pixels; the transform is applied while the path is flattened, so no
  /// transformed copy of the path is ever allocated and [tolerance] is in
  /// device pixels. [clip] is a device-space rectangle, expanded outward to
  /// whole pixels - a caller with a fractional clip that has to be exact must
  /// intersect it into the path itself, because the clip here can only remove
  /// whole pixels.
  ///
  /// A path whose device bounds miss the clip returns before flattening
  /// anything, so an offscreen shape costs one rectangle test.
  void fill(
    Path path,
    Rect clip,
    CoverageSpanSink sink, {
    FillRule rule = FillRule.nonZero,
    Transform2D transform = Transform2D.identity,
    double tolerance = kDefaultFlattenTolerance,
  }) {
    final clipLeft = clip.left.floor();
    final clipTop = clip.top.floor();
    final clipRight = clip.right.ceil();
    final clipBottom = clip.bottom.ceil();
    if (clipRight <= clipLeft || clipBottom <= clipTop) return;

    final device = transform.transformRect(path.bounds);
    if (device.right <= clipLeft ||
        device.left >= clipRight ||
        device.bottom <= clipTop ||
        device.top >= clipBottom) {
      return;
    }

    _clipLeft = clipLeft;
    _clipRight = clipRight;
    _clipTop = clipTop.toDouble();
    _clipBottom = clipBottom.toDouble();
    _edgeCount = 0;
    _minY = double.infinity;
    _maxY = double.negativeInfinity;

    _collector.begin();
    path.flattenTo(_collector, tolerance: tolerance, transform: transform);
    _collector.finish();
    if (_edgeCount == 0) return;

    var yStart = _minY.floor();
    if (yStart < clipTop) yStart = clipTop;
    var yEnd = _maxY.ceil();
    if (yEnd > clipBottom) yEnd = clipBottom;
    if (yEnd <= yStart) return;

    final width = clipRight - clipLeft;
    _ensureAccumulator(width + 2);
    _ensureBuckets(yEnd - yStart);
    _ensureActive(_edgeCount);

    for (var i = 0; i < yEnd - yStart; i++) {
      _buckets[i] = -1;
    }
    for (var e = 0; e < _edgeCount; e++) {
      var row = _edges[e * _edgeStride + 1].floor();
      if (row < yStart) row = yStart;
      if (row >= yEnd) continue;
      final bucket = row - yStart;
      _edgeNext[e] = _buckets[bucket];
      _buckets[bucket] = e;
    }

    _sweep(yStart, yEnd, width, rule, sink);
  }

  /// Walks the rows, maintaining the active edge list and emitting spans.
  void _sweep(
    int yStart,
    int yEnd,
    int width,
    FillRule rule,
    CoverageSpanSink sink,
  ) {
    // Hoisted out of the per-pixel loop: the rule cannot change mid fill, and
    // an enum comparison per pixel is a branch the coverage maths does not
    // need.
    final evenOdd = rule == FillRule.evenOdd;
    final clipLeftDouble = _clipLeft.toDouble();
    final clipRightDouble = _clipRight.toDouble();
    var activeCount = 0;

    for (var y = yStart; y < yEnd; y++) {
      for (var e = _buckets[y - yStart]; e != -1; e = _edgeNext[e]) {
        _active[activeCount++] = e;
      }

      final rowTop = y.toDouble();
      final rowBottom = rowTop + 1;
      // Written and read as the range of accumulator slots this row touched,
      // so both the span scan and the clearing pass stay proportional to the
      // path's width instead of the surface's.
      var touchedLow = width + 2;
      var touchedHigh = 0;
      var write = 0;

      for (var i = 0; i < activeCount; i++) {
        final e = _active[i];
        final base = e * _edgeStride;
        final edgeBottom = _edges[base + 3];
        // Expired edges are dropped by simply not copying them forward, which
        // keeps the list compact without a removal pass.
        if (edgeBottom <= rowTop) continue;
        _active[write++] = e;

        final edgeTop = _edges[base + 1];
        if (edgeTop >= rowBottom) continue;

        final yTop = edgeTop > rowTop ? edgeTop : rowTop;
        final yBottom = edgeBottom < rowBottom ? edgeBottom : rowBottom;
        if (yBottom <= yTop) continue;

        final x0 = _edges[base];
        final slope = _edges[base + 4];
        var xa = x0 + (yTop - edgeTop) * slope;
        var xb = x0 + (yBottom - edgeTop) * slope;
        // Clamping x to the clip is not the same as dropping what is outside
        // it: an edge to the left of the clip still winds around every pixel
        // in the row, so it becomes a vertical edge on the clip boundary and
        // deposits its whole contribution in the first slot. Dropping it
        // instead would leave the interior of the shape unfilled.
        if (xa < clipLeftDouble) xa = clipLeftDouble;
        if (xa > clipRightDouble) xa = clipRightDouble;
        if (xb < clipLeftDouble) xb = clipLeftDouble;
        if (xb > clipRightDouble) xb = clipRightDouble;

        final height = (yBottom - yTop) * _edgeDirections[e];
        final low = xa < xb ? xa - clipLeftDouble : xb - clipLeftDouble;
        final high = xa < xb ? xb - clipLeftDouble : xa - clipLeftDouble;
        final lowIndex = low.floor();
        final highIndex = high.ceil();
        _deposit(low, high, lowIndex, highIndex, height);

        if (lowIndex < touchedLow) touchedLow = lowIndex;
        final written =
            (highIndex > lowIndex + 1 ? highIndex : lowIndex + 1) + 1;
        if (written > touchedHigh) touchedHigh = written;
      }
      activeCount = write;

      if (touchedLow >= touchedHigh) continue;
      _emitRow(y, touchedLow, touchedHigh, width, evenOdd, sink);
    }
  }

  /// Spreads one edge's signed area over the accumulator slots it crosses.
  ///
  /// [low] and [high] are the segment's x range within this scanline,
  /// relative to the left clip edge, and [height] is the signed fraction of
  /// the scanline it spans. The area of a pixel column that falls to the left
  /// of the edge is what gets deposited; the running sum in [_emitRow] turns
  /// those deltas back into absolute coverage.
  void _deposit(
    double low,
    double high,
    int lowIndex,
    int highIndex,
    double height,
  ) {
    if (highIndex <= lowIndex + 1) {
      // The segment stays within one pixel column. Its area is the column's
      // width minus the mean x, which is exact for a straight segment.
      final mean = 0.5 * (low + high) - lowIndex;
      _accumulator[lowIndex] += height * (1.0 - mean);
      _accumulator[lowIndex + 1] += height * mean;
      return;
    }

    // The segment spans several columns. The area to the right of the edge
    // grows quadratically over the first and last partial columns and
    // linearly over the whole ones between, which is what these terms are.
    final inverseRun = 1.0 / (high - low);
    final firstFraction = 1.0 - (low - lowIndex);
    final firstArea = 0.5 * inverseRun * firstFraction * firstFraction;
    final lastFraction = high - highIndex + 1.0;
    final lastArea = 0.5 * inverseRun * lastFraction * lastFraction;

    _accumulator[lowIndex] += height * firstArea;
    if (highIndex == lowIndex + 2) {
      _accumulator[lowIndex + 1] += height * (1.0 - firstArea - lastArea);
    } else {
      final secondArea = inverseRun * (1.5 - (low - lowIndex));
      _accumulator[lowIndex + 1] += height * (secondArea - firstArea);
      for (var x = lowIndex + 2; x < highIndex - 1; x++) {
        _accumulator[x] += height * inverseRun;
      }
      final beforeLast = secondArea + (highIndex - lowIndex - 3) * inverseRun;
      _accumulator[highIndex - 1] += height * (1.0 - beforeLast - lastArea);
    }
    _accumulator[highIndex] += height * lastArea;
  }

  /// Turns one row of accumulated area into spans, clearing as it goes.
  ///
  /// Clearing inside the same walk is why there is no per-row memset: only
  /// the slots this row wrote are visited, and they are zeroed on the way
  /// past, so the next row starts clean without anybody touching the rest of
  /// the buffer.
  void _emitRow(
    int y,
    int touchedLow,
    int touchedHigh,
    int width,
    bool evenOdd,
    CoverageSpanSink sink,
  ) {
    final scanEnd = touchedHigh < width ? touchedHigh : width;
    var sum = 0.0;
    var runCoverage = 0;
    var runStart = touchedLow;

    for (var i = touchedLow; i < scanEnd; i++) {
      sum += _accumulator[i];
      _accumulator[i] = 0.0;
      final coverage = _coverage(sum, evenOdd);
      if (coverage != runCoverage) {
        if (runCoverage != 0) {
          sink.span(y, _clipLeft + runStart, _clipLeft + i, runCoverage);
        }
        runCoverage = coverage;
        runStart = i;
      }
    }
    if (runCoverage != 0) {
      // A run still open at the clip's right edge is a shape that continues
      // past it; the span ends at the clip and the rest was never ours.
      sink.span(y, _clipLeft + runStart, _clipLeft + scanEnd, runCoverage);
    }
    for (var i = scanEnd; i < touchedHigh; i++) {
      _accumulator[i] = 0.0;
    }
  }

  /// The fill rule applied to a fractional winding number, as an alpha byte.
  ///
  /// Both rules start from the magnitude: a contour wound anticlockwise
  /// produces -1 and is every bit as inside as +1. Non-zero then clamps,
  /// which is what makes two overlapping shapes merge instead of adding up to
  /// something more than opaque. Even-odd folds the value into a triangle
  /// wave, so winding 2 lands back on 0 - the hole - and the fold is
  /// continuous, which keeps the boundary of that hole antialiased rather
  /// than stepping between 255 and 0.
  ///
  /// The `+ 0.5` and truncation round to nearest, matching what `mul255`
  /// does, so a coverage of exactly 1.0 is 255 and composites identically to
  /// an unantialiased fill of the same pixel.
  static int _coverage(double windings, bool evenOdd) {
    var value = windings < 0 ? -windings : windings;
    if (evenOdd) {
      value = value % 2.0;
      if (value > 1.0) value = 2.0 - value;
    } else if (value > 1.0) {
      value = 1.0;
    }
    // Also the NaN guard: a comparison against NaN is false, so a poisoned
    // accumulator produces transparent pixels instead of a wild byte.
    if (!(value > 0)) return 0;
    final byte = (value * 255.0 + 0.5).toInt();
    return byte > 255 ? 255 : byte;
  }

  /// Records one flattened segment as an edge.
  ///
  /// Called back from `Path.flattenTo` through [_EdgeCollector].
  void _addEdge(double x0, double y0, double x1, double y1) {
    // A horizontal edge is dropped outright. This is the degenerate case that
    // breaks naive scanline code, which counts it as a crossing on the row it
    // sits on and fills a spurious run to the next edge. It contributes no
    // winding - a ray crosses it zero times, and its area contribution is
    // literally zero height - so dropping it is not a shortcut but the
    // definition. The shape survives because the segments on either side
    // still meet the row.
    if (y0 == y1) return;
    if (!x0.isFinite || !y0.isFinite || !x1.isFinite || !y1.isFinite) return;

    final double topX;
    final double topY;
    final double bottomX;
    final double bottomY;
    final int direction;
    if (y0 < y1) {
      topX = x0;
      topY = y0;
      bottomX = x1;
      bottomY = y1;
      direction = 1;
    } else {
      topX = x1;
      topY = y1;
      bottomX = x0;
      bottomY = y0;
      direction = -1;
    }
    // Vertical culling is a plain drop, unlike the horizontal clamping in the
    // sweep: an edge entirely above or below the drawn rows changes the
    // winding of no pixel in them.
    if (bottomY <= _clipTop || topY >= _clipBottom) return;

    if (_edgeCount * _edgeStride == _edges.length) _growEdges();
    final base = _edgeCount * _edgeStride;
    _edges[base] = topX;
    _edges[base + 1] = topY;
    _edges[base + 2] = bottomX;
    _edges[base + 3] = bottomY;
    _edges[base + 4] = (bottomX - topX) / (bottomY - topY);
    _edgeDirections[_edgeCount] = direction;
    _edgeCount++;

    if (topY < _minY) _minY = topY;
    if (bottomY > _maxY) _maxY = bottomY;
  }

  void _growEdges() {
    final count = _edges.length ~/ _edgeStride;
    final grown = count * 2;
    _edges = Float64List(grown * _edgeStride)
      ..setRange(0, _edges.length, _edges);
    _edgeDirections = Int8List(grown)..setRange(0, count, _edgeDirections);
    _edgeNext = Int32List(grown)..setRange(0, count, _edgeNext);
    _growths++;
  }

  void _ensureActive(int count) {
    if (_active.length >= count) return;
    _active = Int32List(count);
    _growths++;
  }

  void _ensureBuckets(int rows) {
    if (_buckets.length >= rows) return;
    _buckets = Int32List(rows);
    _growths++;
  }

  void _ensureAccumulator(int slots) {
    if (_accumulator.length >= slots) return;
    _accumulator = Float64List(slots);
    _growths++;
  }
}

/// Turns the flattened path's contours into edges in the filler's buffer.
///
/// Every contour is closed, whether the path said so or not: an unclosed
/// outline has no inside, and silently filling it as if the last point joined
/// the first is what every filler does and what a caller means. A stroker
/// would have to respect the difference, which is why `FlattenedPath` reports
/// it and this does not.
final class _EdgeCollector implements PolylineSink {
  _EdgeCollector(this._filler);

  final ScanlineFiller _filler;

  double _startX = 0;
  double _startY = 0;
  double _currentX = 0;
  double _currentY = 0;
  bool _open = false;

  void begin() {
    _open = false;
    _startX = 0;
    _startY = 0;
    _currentX = 0;
    _currentY = 0;
  }

  @override
  void moveTo(double x, double y) {
    if (_open) _filler._addEdge(_currentX, _currentY, _startX, _startY);
    _startX = x;
    _startY = y;
    _currentX = x;
    _currentY = y;
    _open = true;
  }

  @override
  void lineTo(double x, double y) {
    if (!_open) {
      _startX = _currentX;
      _startY = _currentY;
      _open = true;
    }
    _filler._addEdge(_currentX, _currentY, x, y);
    _currentX = x;
    _currentY = y;
  }

  @override
  void close() {
    if (!_open) return;
    _filler._addEdge(_currentX, _currentY, _startX, _startY);
    _currentX = _startX;
    _currentY = _startY;
    _open = false;
  }

  /// Closes whatever contour the path ended in the middle of.
  void finish() {
    close();
  }
}
