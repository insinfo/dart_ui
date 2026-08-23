/// Sparse coverage strips produced *directly* from geometry.
///
/// ## Why this exists, and what it replaces
///
/// `SparseStripGenerator` builds strips by running `ScanlineFiller` and
/// re-encoding its spans. That made the representation cheaper to transfer and
/// left the *work* exactly where it was, and the measurement said so: sparse
/// lost to the dense coverage atlas at every surface size from 256² to 2048²,
/// because both routes paid the same analytic rasterisation and sparse then
/// added classification, packing and extra draws on top. It only saved on
/// upload, which on a shared-memory GPU is not the bottleneck. See the
/// promotion verdict in `doc/architecture/ACELERACAO_GPU_VETORIAL.md`.
///
/// In Vello the strips *are* the rasteriser: coverage is computed per 4x4 tile
/// from the line segments themselves, and no scanline pass exists. This is
/// that pipeline, ported to Dart:
///
///   1. **flatten** the path to line segments;
///   2. **tile** each line into the 4x4 tiles it touches, recording for each
///      whether the line crosses that tile's *top* edge;
///   3. **sort** tiles by (y, x, line) so one pass visits each location once;
///   4. **render**: accumulate exact trapezoidal area per pixel, carry the
///      winding rightwards, and emit a strip per run of adjacent tiles with the
///      fully-covered gaps between them as solid fills.
///
/// Ported from `vello_common` (`tile.rs`, `strip.rs`), Apache-2.0 OR MIT. See
/// `THIRD_PARTY_NOTICES.md`.
///
/// ## Deliberate departures from the Rust
///
///   * **No SIMD.** Dart has none. The inner loops run over fixed four-element
///     spans with scalar accumulators, written so the compiler can keep them
///     in registers rather than round-tripping through the typed arrays.
///   * **No culling.** `CulledWindings`, captive rows and the off-viewport
///     winding bookkeeping are omitted; the whole clip rectangle is the bbox
///     and out-of-range tiles are clamped instead of tracked. That costs work
///     only for paths far larger than the surface, and is the first
///     optimisation to add back.
///   * **The container is [StripBuffer], not Vello's wire format.** Vello packs
///     a strip into 8 bytes with its width implied by the next strip's alpha
///     index - which is why its trailing sentinel is mandatory - and stores
///     alphas column-major. [StripBuffer] carries an explicit width and
///     separate fill records, which is what this repository's GPU executors
///     already consume. The algorithm is faithful; only the encoding is local.
///     Alphas are still accumulated column-major per tile, because that is what
///     lets the inner loop append contiguously, and transposed once per strip
///     when the width is finally known.
///   * **Curves come from `Path.flattenTo`.** The parabola-integral
///     subdivision Vello uses is a drop-in replacement for the sink at the
///     bottom of this file. Keeping the framework's flattener for the first
///     version removes one axis of difference from the parity comparison, so a
///     mismatch is a bug in the tiling or the area accumulation rather than in
///     curve subdivision.
library;

import 'dart:typed_data';

import '../../../geometry/path.dart';
import '../../../geometry/rect.dart';
import '../../../geometry/transform2d.dart';
import '../../path/fill_rule.dart';
import 'sparse_strips.dart' show StripBuffer, kStripHeight;

/// Tile width in pixels. Four, with [kStripHeight] as the height, so one tile
/// is sixteen coverage bytes and one strip row is four scanlines.
const int kTileWidth = 4;

/// Turns paths into sparse coverage strips without a scanline pass.
///
/// One instance per thread, reused across fills: every buffer below grows to
/// the largest path it has seen and is then reused, so a steady-state frame
/// allocates nothing here. [bufferGrowths] is the observable proof.
final class NativeStripRasterizer {
  NativeStripRasterizer();

  /// Flattened segments, four floats each: `x0, y0, x1, y1`, already relative
  /// to the clip's top-left corner.
  Float32List _lines = Float32List(256 * 4);
  int _lineCount = 0;

  /// One entry per (line, tile) crossing. [_tileKey] is `(y << 16) | x` so the
  /// radix sort orders by row then column with no comparator; [_tilePayload]
  /// is `(lineIndex << 1) | crossesTopEdge`. Two flat arrays rather than a
  /// list of objects, because the sort moves them and boxing would dominate.
  Uint32List _tileKey = Uint32List(1024);
  Uint32List _tilePayload = Uint32List(1024);
  int _tileCount = 0;

  Uint32List _sortKey = Uint32List(1024);
  Uint32List _sortPayload = Uint32List(1024);

  /// Radix histogram, 16 bits at a time. Allocated once and refilled.
  final Uint32List _counts = Uint32List(1 << 16);

  /// The strip under construction, column-major: [kStripHeight] bytes per
  /// column, appended a tile at a time.
  Uint8List _stripColumns = Uint8List(256 * kStripHeight);
  int _stripColumnCount = 0;

  final StripBuffer _output = StripBuffer();

  /// Per-pixel winding for the location being accumulated, column-major to
  /// match [_stripColumns]: `_locationWinding[column * kStripHeight + row]`.
  final Float32List _locationWinding = Float32List(kTileWidth * kStripHeight);

  /// Winding carried past the right edge of the current location, per
  /// scanline.
  final Float32List _accumulated = Float32List(kStripHeight);

  /// Integer winding carried between locations in a row: how many times a
  /// horizontal ray entering from the left has crossed the path.
  int _windingDelta = 0;

  /// Width of the clip in pixels, which is where [_addLine] folds geometry to.
  double _clipWidth = 0;

  int _growths = 0;

  /// Buffer reallocations since construction. Across steady-state frames this
  /// must stop increasing.
  int get bufferGrowths => _growths;

  int get lineCount => _lineCount;
  int get tileCount => _tileCount;

  /// Rasterises [path] into sparse strips.
  ///
  /// [clip] is expanded outward to whole pixels, exactly as `ScanlineFiller`
  /// does. The framework has one clip semantics and this route inherits it
  /// rather than choosing the tidier exact-rectangle cut - a route that
  /// disagreed with the others about a fractional clip edge would be wrong
  /// even where it looked better. The returned buffer is owned by this
  /// rasteriser and is valid until the next call.
  StripBuffer fill(
    Path path,
    Rect clip, {
    FillRule rule = FillRule.nonZero,
    Transform2D transform = Transform2D.identity,
    double tolerance = kDefaultFlattenTolerance,
  }) {
    _output.reset();
    final int clipLeft = clip.left.floor();
    final int clipTop = clip.top.floor();
    final int clipRight = clip.right.ceil();
    final int clipBottom = clip.bottom.ceil();
    if (clipRight <= clipLeft || clipBottom <= clipTop) return _output;

    // Everything below works with the clip's top-left corner as the origin, so
    // tile indices start at zero; the emitted strips are translated back once,
    // at the end.
    _clipWidth = (clipRight - clipLeft).toDouble();
    _flatten(
        path, transform, clipLeft.toDouble(), clipTop.toDouble(), tolerance);
    if (_lineCount == 0) return _output;

    final int width = clipRight - clipLeft;
    final int height = clipBottom - clipTop;
    _makeTiles(width, height);
    if (_tileCount == 0) return _output;
    _sortTiles(
      (width + kTileWidth - 1) ~/ kTileWidth,
      (height + kStripHeight - 1) ~/ kStripHeight,
    );
    _render(rule, width, clipLeft, clipTop);
    return _output;
  }

  // -------------------------------------------------------------------
  // 1. Flattening
  // -------------------------------------------------------------------

  void _flatten(
    Path path,
    Transform2D transform,
    double originX,
    double originY,
    double tolerance,
  ) {
    _lineCount = 0;
    final _LineSink sink = _LineSink(this, originX, originY);
    path.flattenTo(sink, tolerance: tolerance, transform: transform);
    sink.finish();
  }

  /// Adds one segment, first folding it onto the clip's left edge.
  ///
  /// ## Why the geometry is clipped in x, and why by splitting
  ///
  /// Coverage inside the clip depends on geometry outside it: a horizontal ray
  /// entering a pixel from the left has crossed every edge to that pixel's
  /// left, however far away. Vello keeps that as separate per-row winding
  /// bookkeeping and culls the geometry. This does what `ScanlineFiller`
  /// already documents doing instead - *clamps edges outside the clip onto its
  /// boundary rather than dropping them* - so both rasterisers in this
  /// framework answer the same way by construction.
  ///
  /// Clamping the endpoints alone would be wrong: it moves where the line
  /// crosses each scanline. So a segment straddling the boundary is **split**,
  /// and only the outside part becomes vertical - which winds every pixel to
  /// its right by exactly as much as the real edge did, and covers none of
  /// them, which is what an edge outside the clip does.
  ///
  /// The right edge needs no such care: a crossing to the right of a pixel is
  /// a crossing the ray never reaches, so that part is dropped outright.
  void _addLine(double x0, double y0, double x1, double y1) {
    final double width = _clipWidth;

    // A horizontal segment contributes no winding and no area - the render
    // pass skips it - but it still has to be *tiled*, and dropping it here was
    // a real bug worth naming. The tiler's job is to mark which locations need
    // alpha at all, and a horizontal edge is exactly what marks the row of
    // locations under a shape's flat top. Without it the strip stops at the
    // shape's left edge, the carried per-scanline winding has nowhere to be
    // written, and a rectangle with a fractional top loses every column past
    // the first tile.
    //
    // Its endpoints can be clamped rather than split, because clamping cannot
    // move a crossing that does not exist.
    if (y0 == y1) {
      var left = x0 < x1 ? x0 : x1;
      var right = x0 < x1 ? x1 : x0;
      if (left >= width) return;
      if (right <= 0) return;
      if (left < 0) left = 0;
      if (right > width) right = width;
      _addRawLine(left, y0, right, y1);
      return;
    }

    if (x0 <= 0 && x1 <= 0) {
      _addRawLine(0, y0, 0, y1);
      return;
    }
    if (x0 >= width && x1 >= width) return;

    if ((x0 < 0) != (x1 < 0)) {
      final double t = -x0 / (x1 - x0);
      final double crossing = y0 + t * (y1 - y0);
      if (x0 < 0) {
        _addRawLine(0, y0, 0, crossing);
        _addLine(0, crossing, x1, y1);
      } else {
        _addLine(x0, y0, 0, crossing);
        _addRawLine(0, crossing, 0, y1);
      }
      return;
    }
    if ((x0 > width) != (x1 > width)) {
      final double t = (width - x0) / (x1 - x0);
      final double crossing = y0 + t * (y1 - y0);
      if (x0 > width) {
        _addLine(width, crossing, x1, y1);
      } else {
        _addLine(x0, y0, width, crossing);
      }
      return;
    }
    _addRawLine(x0, y0, x1, y1);
  }

  void _addRawLine(double x0, double y0, double x1, double y1) {
    final int base = _lineCount * 4;
    if (base + 4 > _lines.length) {
      final Float32List grown = Float32List(_lines.length * 2);
      grown.setRange(0, base, _lines);
      _lines = grown;
      _growths++;
    }
    _lines[base] = x0;
    _lines[base + 1] = y0;
    _lines[base + 2] = x1;
    _lines[base + 3] = y1;
    _lineCount++;
  }

  // -------------------------------------------------------------------
  // 2. Tiling
  // -------------------------------------------------------------------

  /// Records, for every line, each 4x4 tile it passes through.
  ///
  /// Besides the location, exactly one bit is stored per crossing: does this
  /// line cross the tile's **top** edge. That bit is the whole coarse winding
  /// contribution - a horizontal ray entering the tile row from the left has
  /// crossed the line exactly when the line passed over the top edge somewhere
  /// to its left - and it is why the render pass never has to look at the
  /// geometry a second time to know the interior winding.
  ///
  /// Vello's tiler also records which of the top/bottom/left/right edges are
  /// crossed. Those bits belong to its MSAA path and the analytic one never
  /// reads them, so they are not computed here.
  void _makeTiles(int width, int height) {
    _tileCount = 0;
    final int tileColumns = (width + kTileWidth - 1) ~/ kTileWidth;
    final int tileRows = (height + kStripHeight - 1) ~/ kStripHeight;
    if (tileColumns <= 0 || tileRows <= 0) return;

    for (var lineIndex = 0; lineIndex < _lineCount; lineIndex++) {
      final int base = lineIndex * 4;
      // Into tile space, where a tile is the unit square.
      final double p0x = _lines[base] / kTileWidth;
      final double p0y = _lines[base + 1] / kStripHeight;
      final double p1x = _lines[base + 2] / kTileWidth;
      final double p1y = _lines[base + 3] / kStripHeight;

      final double topY;
      final double topX;
      final double bottomY;
      final double bottomX;
      if (p0y < p1y) {
        topY = p0y;
        topX = p0x;
        bottomY = p1y;
        bottomX = p1x;
      } else {
        topY = p1y;
        topX = p1x;
        bottomY = p0y;
        bottomX = p0x;
      }
      final double leftX = topX < bottomX ? topX : bottomX;
      final double rightX = topX < bottomX ? bottomX : topX;

      // No culling: clamp instead. A line left of the viewport still winds the
      // rows it spans, and clamping its tiles into column zero reproduces that
      // without the separate winding bookkeeping Vello keeps for the culled
      // case. A line entirely right of the viewport contributes nothing, and
      // clamping it to the last column would be wrong, so it is dropped.
      if (leftX >= tileColumns) continue;

      var yTop = topY.floor();
      if (yTop < 0) yTop = 0;
      if (yTop > tileRows) yTop = tileRows;
      var yBottom = bottomY.ceil();
      if (yBottom < 0) yBottom = 0;
      if (yBottom > tileRows) yBottom = tileRows;
      if (yTop >= yBottom) continue;

      if (topY == bottomY) {
        // Horizontal. One tile row, no winding, but every location it spans
        // needs alpha - see [_addLine].
        final int y = yTop;
        var xStart = leftX.floor();
        if (xStart < 0) xStart = 0;
        if (xStart >= tileColumns) xStart = tileColumns - 1;
        var xEnd = rightX.floor();
        if (xEnd < 0) xEnd = 0;
        if (xEnd >= tileColumns) xEnd = tileColumns - 1;
        for (var x = xStart; x <= xEnd; x++) {
          _addTile(x, y, lineIndex, false);
        }
        continue;
      }

      if (leftX == rightX) {
        // Vertical. One column, and every tile below the first crosses its top
        // edge by construction.
        var x = leftX.floor();
        if (x < 0) x = 0;
        if (x >= tileColumns) x = tileColumns - 1;
        for (var y = yTop; y < yBottom; y++) {
          _addTile(x, y, lineIndex, y > yTop || topY <= y);
        }
        continue;
      }

      final double xSlope = (p1x - p0x) / (p1y - p0y);
      for (var y = yTop; y < yBottom; y++) {
        final double yTopEdge = y.toDouble();
        final double rowTopY = yTopEdge > topY ? yTopEdge : topY;
        final double yBottomEdge = yTopEdge + 1;
        final double rowBottomY = yBottomEdge < bottomY ? yBottomEdge : bottomY;
        final double rowTopX = p0x + (rowTopY - p0y) * xSlope;
        final double rowBottomX = p0x + (rowBottomY - p0y) * xSlope;
        var rowLeft = rowTopX < rowBottomX ? rowTopX : rowBottomX;
        var rowRight = rowTopX < rowBottomX ? rowBottomX : rowTopX;
        if (rowLeft < leftX) rowLeft = leftX;
        if (rowRight > rightX) rowRight = rightX;

        var xStart = rowLeft.floor();
        if (xStart < 0) xStart = 0;
        if (xStart >= tileColumns) xStart = tileColumns - 1;
        var xEnd = rowRight.floor();
        if (xEnd < 0) xEnd = 0;
        if (xEnd >= tileColumns) xEnd = tileColumns - 1;

        // The winding bit belongs to the tile the line *enters the row*
        // through: the leftmost when the line runs down-and-right, the
        // rightmost when it runs down-and-left. A line that starts partway
        // down this row never crosses its top edge and contributes none.
        final bool crossesTop = yTopEdge >= topY;
        final bool downRight = bottomX >= topX;
        for (var x = xStart; x <= xEnd; x++) {
          final bool carries = crossesTop &&
              (xStart == xEnd || (downRight ? x == xStart : x == xEnd));
          _addTile(x, y, lineIndex, carries);
        }
      }
    }
  }

  void _addTile(int x, int y, int lineIndex, bool crossesTop) {
    if (_tileCount == _tileKey.length) {
      final int length = _tileKey.length * 2;
      final Uint32List keys = Uint32List(length);
      final Uint32List payloads = Uint32List(length);
      keys.setRange(0, _tileCount, _tileKey);
      payloads.setRange(0, _tileCount, _tilePayload);
      _tileKey = keys;
      _tilePayload = payloads;
      _sortKey = Uint32List(length);
      _sortPayload = Uint32List(length);
      _growths++;
    }
    _tileKey[_tileCount] = (y << 16) | x;
    _tilePayload[_tileCount] = (lineIndex << 1) | (crossesTop ? 1 : 0);
    _tileCount++;
  }

  // -------------------------------------------------------------------
  // 3. Sorting
  // -------------------------------------------------------------------

  /// Orders tiles by row, then column, keeping line order within a location.
  ///
  /// A least-significant-digit radix sort over the two 16-bit halves of the
  /// key: linear, allocation-free after warmup, and - because each pass is
  /// stable - it leaves the tiles at one location in the order their lines
  /// were emitted, which is what makes a rasterisation reproducible. A
  /// comparator sort would box every element, which is also why the keys and
  /// payloads are flat arrays rather than a list of tile objects.
  void _sortTiles(int tileColumns, int tileRows) {
    // Only the digits that can actually occur are cleared. The histogram has
    // 65 536 slots because the key halves are 16 bits, but a 256-pixel surface
    // uses 64 of them - and clearing the whole thing twice per fill was
    // measured at over a hundred microseconds, which is more than the entire
    // rasterisation of a simple shape. A fixed cost that dwarfs the work is
    // the kind of thing a benchmark blames on the algorithm.
    _radixPass(0, tileColumns);
    _radixPass(16, tileRows);
  }

  void _radixPass(int shift, int digitCount) {
    _counts.fillRange(0, digitCount + 1, 0);
    for (var i = 0; i < _tileCount; i++) {
      _counts[(_tileKey[i] >> shift) & 0xFFFF]++;
    }
    var total = 0;
    for (var digit = 0; digit <= digitCount; digit++) {
      final int count = _counts[digit];
      _counts[digit] = total;
      total += count;
    }
    for (var i = 0; i < _tileCount; i++) {
      final int key = _tileKey[i];
      final int slot = _counts[(key >> shift) & 0xFFFF]++;
      _sortKey[slot] = key;
      _sortPayload[slot] = _tilePayload[i];
    }
    final Uint32List keys = _tileKey;
    final Uint32List payloads = _tilePayload;
    _tileKey = _sortKey;
    _tilePayload = _sortPayload;
    _sortKey = keys;
    _sortPayload = payloads;
  }

  // -------------------------------------------------------------------
  // 4. Rendering
  // -------------------------------------------------------------------

  /// Walks the sorted tiles once, accumulating area and emitting strips.
  void _render(FillRule rule, int width, int clipLeft, int clipTop) {
    final bool evenOdd = rule == FillRule.evenOdd;

    _stripColumnCount = 0;
    _locationWinding.fillRange(0, _locationWinding.length, 0);
    _accumulated.fillRange(0, _accumulated.length, 0);
    _windingDelta = 0;

    var previousKey = _tileKey[0];
    var stripTileX = previousKey & 0xFFFF;
    var stripRow = previousKey >> 16;

    // One extra iteration for the sentinel, which is what flushes the final
    // location and the final strip. Vello needs a sentinel in its output for a
    // different reason - its strips carry no width - but the loop shape is the
    // same: every flush is triggered by *arriving somewhere else*.
    for (var index = 0; index <= _tileCount; index++) {
      final int key = index < _tileCount ? _tileKey[index] : _sentinelKey;
      final int payload = index < _tileCount ? _tilePayload[index] : 0;
      final bool sameLocation = key == previousKey;

      if (!sameLocation) {
        _flushLocation(evenOdd);
      }

      final int row = key >> 16;
      final int tileX = key & 0xFFFF;
      final int previousRow = previousKey >> 16;
      final int previousTileX = previousKey & 0xFFFF;
      final bool adjacent = row == previousRow && previousTileX + 1 == tileX;

      if (!sameLocation && !adjacent) {
        // The run of adjacent tiles ended: emit it, then decide what fills the
        // gap after it.
        final int stripLeft = stripTileX * kTileWidth;
        _emitStrip(
            stripLeft, previousRow * kStripHeight, width, clipLeft, clipTop);
        final int stripEnd = (previousTileX + 1) * kTileWidth;

        if (row != previousRow) {
          // The row ended. Anything still wound runs to the right edge.
          if (_shouldFill(evenOdd)) {
            _emitFill(
                stripEnd, previousRow * kStripHeight, width, clipLeft, clipTop);
          }
          _windingDelta = 0;
          _accumulated.fillRange(0, _accumulated.length, 0);
          _locationWinding.fillRange(0, _locationWinding.length, 0);
        } else {
          // Same row, a gap before the next strip. Vello encodes this as the
          // `fillGap` bit of the *following* strip; here it is a fill record,
          // which is the same fact with the width made explicit.
          if (_shouldFill(evenOdd)) {
            _emitFill(stripEnd, row * kStripHeight, tileX * kTileWidth,
                clipLeft, clipTop);
          }
          // Mathematically unnecessary - the accumulators already hold this -
          // but re-splatting from the integer winding stops float error
          // accumulating across a long row.
          final double delta = _windingDelta.toDouble();
          for (var i = 0; i < kStripHeight; i++) {
            _accumulated[i] = delta;
          }
          for (var i = 0; i < _locationWinding.length; i++) {
            _locationWinding[i] = delta;
          }
        }

        if (index == _tileCount) break;
        stripTileX = tileX;
        stripRow = row;
        _stripColumnCount = 0;
      } else if (index == _tileCount) {
        break;
      }

      previousKey = key;
      _accumulateLine(payload, tileX, row);
    }
    // Referenced so the field is not mistaken for dead state by a reader; the
    // strip's row is carried in `previousKey` through the loop.
    assert(stripRow >= 0);
  }

  /// Whether the interior between here and the next strip is covered.
  bool _shouldFill(bool evenOdd) =>
      evenOdd ? (_windingDelta & 1) != 0 : _windingDelta != 0;

  /// Converts the finished location's winding into four columns of alpha and
  /// resets it to the winding carried past its right edge.
  void _flushLocation(bool evenOdd) {
    final int base = _stripColumnCount * kStripHeight;
    if (base + kTileWidth * kStripHeight > _stripColumns.length) {
      final Uint8List grown = Uint8List(_stripColumns.length * 2);
      grown.setRange(0, base, _stripColumns);
      _stripColumns = grown;
      _growths++;
    }
    for (var column = 0; column < kTileWidth; column++) {
      final int from = column * kStripHeight;
      for (var row = 0; row < kStripHeight; row++) {
        final double area = _locationWinding[from + row];
        final double coverage;
        if (evenOdd) {
          // Fold the winding into a triangle wave: ..., 1 -> 1, 2 -> 0,
          // 3 -> 1, so an even winding is a hole and an odd one is ink.
          final double folded = (area * 0.5 + 0.5).floorToDouble();
          coverage = (area - 2.0 * folded).abs();
        } else {
          coverage = area.abs();
        }
        var alpha = coverage * 255.0 + 0.5;
        if (!(alpha > 0)) alpha = 0;
        if (alpha > 255.0) alpha = 255.0;
        _stripColumns[base + from + row] = alpha.toInt();
      }
    }
    _stripColumnCount += kTileWidth;
    for (var column = 0; column < kTileWidth; column++) {
      final int from = column * kStripHeight;
      for (var row = 0; row < kStripHeight; row++) {
        _locationWinding[from + row] = _accumulated[row];
      }
    }
  }

  /// Writes the accumulated columns out as one strip, transposing them from
  /// the column-major order the inner loop appends in to the row-major order
  /// [StripBuffer] stores.
  void _emitStrip(
    int stripLeft,
    int stripTop,
    int width,
    int clipLeft,
    int clipTop,
  ) {
    if (_stripColumnCount == 0) return;
    var columns = _stripColumnCount;
    if (stripLeft + columns > width) columns = width - stripLeft;
    if (columns <= 0) {
      _stripColumnCount = 0;
      return;
    }
    final int offset = _output.reserveAlphas(columns * kStripHeight);
    final Uint8List alphas = _output.alphas;
    for (var row = 0; row < kStripHeight; row++) {
      final int destination = offset + row * columns;
      for (var column = 0; column < columns; column++) {
        alphas[destination + column] =
            _stripColumns[column * kStripHeight + row];
      }
    }
    _output.addStrip(
      clipLeft + stripLeft,
      clipTop + stripTop,
      columns,
      offset,
    );
    _stripColumnCount = 0;
  }

  void _emitFill(
    int from,
    int top,
    int to,
    int clipLeft,
    int clipTop,
  ) {
    final int end = to > from ? to : from;
    if (end <= from) return;
    _output.addFill(clipLeft + from, clipTop + top, end - from);
  }

  /// Adds one line's exact area contribution to the current location.
  ///
  /// The geometry, stated once: a horizontal ray is shot left to right across
  /// each scanline. Crossing an upward line increments the winding, crossing a
  /// downward one decrements it, and a pixel's coverage is the integral of the
  /// winding across it. Within a pixel the line cuts off a trapezoid against
  /// the pixel's right edge; that area is the pixel's own contribution, and the
  /// line's y-extent within the pixel is carried rightwards in `acc` so every
  /// pixel further right is fully wound by it.
  void _accumulateLine(int payload, int tileX, int row) {
    final int lineIndex = payload >> 1;
    final int base = lineIndex * 4;
    final double tileLeft = (tileX * kTileWidth).toDouble();
    final double tileTop = (row * kStripHeight).toDouble();
    final double p0x = _lines[base] - tileLeft;
    final double p0y = _lines[base + 1] - tileTop;
    final double p1x = _lines[base + 2] - tileLeft;
    final double p1y = _lines[base + 3] - tileTop;
    if (p0y == p1y) return;

    final double sign = p0y > p1y ? 1.0 : -1.0;
    _windingDelta += (payload & 1) != 0 ? sign.toInt() : 0;

    final double topY;
    final double topX;
    final double bottomY;
    final double bottomX;
    if (p0y < p1y) {
      topY = p0y;
      topX = p0x;
      bottomY = p1y;
      bottomX = p1x;
    } else {
      topY = p1y;
      topX = p1x;
      bottomY = p0y;
      bottomX = p0x;
    }

    // Infinite for a vertical line, which is deliberate and is why the NaN
    // guard below exists rather than a branch: the clamping generalises, and
    // only the exactly-collinear case needs saying.
    final double ySlope = (bottomY - topY) / (bottomX - topX);
    final double xSlope = 1.0 / ySlope;
    final double baseYX = topX - topY * xSlope;

    // Only the scanlines the segment actually spans. A line that crosses one
    // row of a tile contributes exactly zero area and zero carried winding to
    // the other three - `h` comes out zero for them - so computing those was
    // sixteen pixels of arithmetic to add nothing. Short segments, which is
    // what a dense path is made of, touch one or two.
    var firstScanline = topY.floor();
    if (firstScanline < 0) firstScanline = 0;
    var lastScanline = bottomY.ceil();
    if (lastScanline > kStripHeight) lastScanline = kStripHeight;

    for (var scanline = firstScanline; scanline < lastScanline; scanline++) {
      final double pixelTop = scanline.toDouble();
      final double pixelBottom = pixelTop + 1.0;
      final double yMin = topY > pixelTop ? topY : pixelTop;
      final double yMax = bottomY < pixelBottom ? bottomY : pixelBottom;
      var acc = 0.0;
      // The first pixel's left edge; every later one is the previous pixel's
      // right edge, carried below.
      var left = (0.0 - topX) * ySlope + topY;
      left = left.isNaN ? yMin : (left > yMin ? left : yMin);
      if (left > yMax) left = yMax;
      var leftX = left * xSlope + baseYX;

      for (var column = 0; column < kTileWidth; column++) {
        final double pixelRight = column + 1.0;

        // Where the line meets this pixel's right edge, clamped into the part
        // of the line inside this scanline. The *left* edge is the previous
        // pixel's right edge, carried rather than recomputed - the two are the
        // same value with the same clamp, so this is five evaluations per
        // scanline instead of eight on the loop that dominates the cost.
        //
        // For a vertical line `ySlope` is infinite, so this comes out at -inf
        // or +inf depending on which side of the line the edge is, and the
        // clamps turn that into "entirely above" or "entirely below" - which
        // is the right answer. The case that needs care is a vertical line
        // exactly *on* a pixel edge: `0 * inf` is NaN, and the convention is
        // that the line belongs to the pixel on whose **left** edge it sits.
        // Rust gets that from `max(NaN, yMin) == yMin` on x86; Dart's
        // comparisons are false for NaN, so it is tested by hand.
        var right = (pixelRight - topX) * ySlope + topY;
        right = right.isNaN ? yMin : (right > yMin ? right : yMin);
        if (right > yMax) right = yMax;
        final double rightX = right * xSlope + baseYX;

        final double height = (right - left).abs();
        _locationWinding[column * kStripHeight + scanline] +=
            height * (pixelRight - 0.5 * (rightX + leftX)) * sign + acc;
        acc += height * sign;

        left = right;
        leftX = rightX;
      }
      _accumulated[scanline] += acc;
    }
  }

  /// A location past every real one, so the last strip is flushed by the same
  /// code that flushes the others.
  static const int _sentinelKey = 0xFFFFFFFF;
}

/// Collects flattened line segments, closing every contour.
final class _LineSink implements PolylineSink {
  _LineSink(this._owner, this._originX, this._originY);

  final NativeStripRasterizer _owner;
  final double _originX;
  final double _originY;

  double _startX = 0;
  double _startY = 0;
  double _currentX = 0;
  double _currentY = 0;
  bool _open = false;

  @override
  void moveTo(double x, double y) {
    finish();
    _startX = x - _originX;
    _startY = y - _originY;
    _currentX = _startX;
    _currentY = _startY;
    _open = true;
  }

  @override
  void lineTo(double x, double y) {
    final double nextX = x - _originX;
    final double nextY = y - _originY;
    _owner._addLine(_currentX, _currentY, nextX, nextY);
    _currentX = nextX;
    _currentY = nextY;
  }

  @override
  void close() {
    if (!_open) return;
    _owner._addLine(_currentX, _currentY, _startX, _startY);
    _currentX = _startX;
    _currentY = _startY;
  }

  /// Closes an unclosed contour, which a fill implies.
  void finish() {
    if (!_open) return;
    if (_currentX != _startX || _currentY != _startY) {
      _owner._addLine(_currentX, _currentY, _startX, _startY);
    }
    _open = false;
  }
}
