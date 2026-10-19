/// Which parts of a large shape actually need a coverage mask.
///
/// ## The measurement this answers
///
/// A rounded card the size of a window is drawn every frame: its fill, its
/// one-pixel border, and - for a `ClipRRect` around its content - a
/// complement path that erases the four corners. Each of those is a path
/// whose *bounds* are the whole card, and the GPU sink used to rasterise
/// every one of them as a mask the size of those bounds: split into tiles as
/// large as the 1024x1024 coverage atlas, every tile filling the atlas,
/// evicting every cached icon, flushing the frame in the middle and scanning
/// two and a half million pixels on the CPU - for shapes whose coverage is
/// zero or one everywhere except in four 16 px corners. Measured in the file
/// explorer on a Retina Mac, dragging a column: 46% of the frame's CPU in
/// `_drawMaskTiled`, 27% in the mid-frame flushes it caused, 59 ms of raster
/// per frame.
///
/// ## What is decided here
///
/// The shape's device bounds are cut into small square tiles and each is put
/// in one of two classes:
///
///   * **needs a mask** - a curve, a diagonal or an edge at a fractional
///     device coordinate passes within one pixel of it. Only these are
///     rasterised, and being small they stay resident in the atlas from one
///     frame to the next;
///   * **rectilinear** - every edge that crosses it is horizontal or vertical
///     and lies on whole device pixels (or none crosses it at all). Then each
///     pixel is either wholly inside or wholly outside the shape - the
///     scanline filler's area coverage for such a pixel is exactly 0 or 1 -
///     and the tile is the union of a few rectangles, found by casting a ray
///     from the centre of each cell the edges cut it into. Those are drawn as
///     plain rectangles, which never touch the atlas.
///
/// The second class is not an approximation: it is the same coverage the mask
/// would have held, computed per cell instead of per pixel. The margin of one
/// pixel around every non-rectilinear segment is what makes that safe - the
/// filler's antialiasing reaches at most into the pixels an edge touches, and
/// the flattening tolerance is less than a quarter of a pixel.
library;

import 'dart:typed_data';

import '../../geometry/fill_rule.dart';
import '../../geometry/path.dart';
import '../../geometry/transform2d.dart';

/// The tile side used for shapes too large to be one cached mask.
///
/// Small enough that a curved corner costs a 64x64 mask - 4 KiB of a 1 MiB
/// atlas, resident across frames - and large enough that a full-window shape
/// is a few hundred tiles, each classified in a handful of operations.
const int kMaskTileSide = 64;

/// Pixels rasterised around each masked tile and then thrown away, so the
/// coverage at a tile's own edge is the whole shape's: the filler clips the
/// geometry to its clip rectangle, and the pixel just inside a cut edge loses
/// part of its coverage to its neighbour. Two pixels is one more than the
/// error reaches.
const int kMaskTileMargin = 2;

/// The tile plan for one path, reused from draw to draw so classifying a
/// shape allocates nothing once the buffers have grown.
final class MaskTilePlan implements PolylineSink {
  /// Device-space segments, four doubles each, contours closed.
  Float64List _segments = Float64List(256);
  int _segmentCount = 0;

  /// Per tile: 0 untouched, 1 rectilinear edges inside, 2 needs a mask.
  Uint8List _states = Uint8List(0);

  int _left = 0;
  int _top = 0;
  int _right = 0;
  int _bottom = 0;
  int _tile = kMaskTileSide;
  int _columns = 0;
  int _rows = 0;
  FillRule _rule = FillRule.nonZero;

  double _startX = 0;
  double _startY = 0;
  double _lastX = 0;
  double _lastY = 0;
  bool _open = false;

  /// Scratch for one tile's cell boundaries.
  final List<double> _xs = <double>[];
  final List<double> _ys = <double>[];

  int get columns => _columns;
  int get rows => _rows;

  /// The tile at ([column], [row]) in device pixels, clamped to the plan.
  int tileLeft(int column) => _left + column * _tile;
  int tileTop(int row) => _top + row * _tile;
  int tileRight(int column) {
    final int r = _left + (column + 1) * _tile;
    return r < _right ? r : _right;
  }

  int tileBottom(int row) {
    final int b = _top + (row + 1) * _tile;
    return b < _bottom ? b : _bottom;
  }

  /// Whether the tile has to be rasterised as a mask.
  bool needsMask(int column, int row) => _states[row * _columns + column] == 2;

  /// How many tiles need a mask.
  int get maskedTileCount {
    int count = 0;
    for (int i = 0; i < _columns * _rows; i++) {
      if (_states[i] == 2) count++;
    }
    return count;
  }

  /// Classifies [path] under [transform] over the whole-pixel device
  /// rectangle [left], [top], [right], [bottom], in tiles of [tile] pixels.
  void plan(
    Path path,
    Transform2D transform, {
    required int left,
    required int top,
    required int right,
    required int bottom,
    required FillRule rule,
    int tile = kMaskTileSide,
  }) {
    _left = left;
    _top = top;
    _right = right;
    _bottom = bottom;
    _tile = tile;
    _rule = rule;
    _columns = right > left ? (right - left + tile - 1) ~/ tile : 0;
    _rows = bottom > top ? (bottom - top + tile - 1) ~/ tile : 0;
    final int count = _columns * _rows;
    if (_states.length < count) _states = Uint8List(count);
    _states.fillRange(0, count, 0);
    _segmentCount = 0;
    _open = false;
    path.flattenTo(this, transform: transform);
    _closeContour();
    for (int i = 0; i < _segmentCount; i++) {
      _classify(i);
    }
  }

  // --- PolylineSink ----------------------------------------------------------

  @override
  void moveTo(double x, double y) {
    _closeContour();
    _startX = _lastX = x;
    _startY = _lastY = y;
    _open = true;
  }

  @override
  void lineTo(double x, double y) {
    if (!_open) moveTo(_lastX, _lastY);
    _add(_lastX, _lastY, x, y);
    _lastX = x;
    _lastY = y;
  }

  @override
  void close() => _closeContour();

  /// Filling closes every contour, open or not; so does the winding count.
  void _closeContour() {
    if (!_open) return;
    if (_lastX != _startX || _lastY != _startY) {
      _add(_lastX, _lastY, _startX, _startY);
    }
    _lastX = _startX;
    _lastY = _startY;
    _open = false;
  }

  void _add(double x0, double y0, double x1, double y1) {
    if (x0 == x1 && y0 == y1) return;
    if ((_segmentCount + 1) * 4 > _segments.length) {
      final Float64List grown = Float64List(_segments.length * 2)
        ..setRange(0, _segmentCount * 4, _segments);
      _segments = grown;
    }
    final int o = _segmentCount * 4;
    _segments[o] = x0;
    _segments[o + 1] = y0;
    _segments[o + 2] = x1;
    _segments[o + 3] = y1;
    _segmentCount++;
  }

  // --- classification --------------------------------------------------------

  static bool _whole(double v) => v == v.roundToDouble();

  void _classify(int index) {
    final int o = index * 4;
    final double x0 = _segments[o];
    final double y0 = _segments[o + 1];
    final double x1 = _segments[o + 2];
    final double y1 = _segments[o + 3];
    final bool rectilinear = (x0 == x1 || y0 == y1) &&
        _whole(x0) &&
        _whole(y0) &&
        _whole(x1) &&
        _whole(y1);
    final double minX = x0 < x1 ? x0 : x1;
    final double maxX = x0 < x1 ? x1 : x0;
    final double minY = y0 < y1 ? y0 : y1;
    final double maxY = y0 < y1 ? y1 : y0;
    if (rectilinear) {
      // A whole-pixel edge changes coverage only across itself, so it touches
      // the tiles it passes *through*; lying on a tile's border, it leaves
      // that tile uniform on both sides.
      _mark(minX, minY, maxX, maxY, 1, inclusive: false);
    } else {
      // Antialiasing reaches into every pixel the edge enters, and the
      // flattened polyline is within a quarter pixel of the curve: one pixel
      // of margin covers both.
      _mark(minX - 1, minY - 1, maxX + 1, maxY + 1, 2, inclusive: true);
    }
  }

  void _mark(
    double minX,
    double minY,
    double maxX,
    double maxY,
    int state, {
    required bool inclusive,
  }) {
    if (_columns == 0 || _rows == 0) return;
    int c0 = ((minX - _left) / _tile).floor();
    int c1 = ((maxX - _left) / _tile).floor();
    int r0 = ((minY - _top) / _tile).floor();
    int r1 = ((maxY - _top) / _tile).floor();
    if (c0 < 0) c0 = 0;
    if (r0 < 0) r0 = 0;
    if (c1 >= _columns) c1 = _columns - 1;
    if (r1 >= _rows) r1 = _rows - 1;
    for (int r = r0; r <= r1; r++) {
      final int tTop = tileTop(r);
      final int tBottom = tileBottom(r);
      for (int c = c0; c <= c1; c++) {
        final int tLeft = tileLeft(c);
        final int tRight = tileRight(c);
        final bool overlaps = inclusive
            ? maxX >= tLeft && minX <= tRight && maxY >= tTop && minY <= tBottom
            // Strictly inside in the axis the edge lies across, overlapping
            // in the one it runs along.
            : (minX == maxX
                ? minX > tLeft && minX < tRight && maxY > tTop && minY < tBottom
                : minY > tTop &&
                    minY < tBottom &&
                    maxX > tLeft &&
                    minX < tRight);
        if (!overlaps) continue;
        final int i = r * _columns + c;
        if (_states[i] < state) _states[i] = state;
      }
    }
  }

  /// Whether the device point ([x], [y]) is inside under the plan's rule.
  ///
  /// Only ever asked at the centre of a cell no edge passes within half a
  /// pixel of, so the half-open crossing rule never meets a vertex.
  bool _inside(double x, double y) {
    int winding = 0;
    int crossings = 0;
    final Float64List s = _segments;
    for (int i = 0; i < _segmentCount; i++) {
      final int o = i * 4;
      final double y0 = s[o + 1];
      final double y1 = s[o + 3];
      if ((y0 <= y) == (y1 <= y)) continue;
      final double x0 = s[o];
      final double x1 = s[o + 2];
      final double xAt = x0 + (y - y0) * (x1 - x0) / (y1 - y0);
      if (xAt > x) {
        crossings++;
        winding += y1 > y0 ? 1 : -1;
      }
    }
    return _rule == FillRule.evenOdd ? crossings.isOdd : winding != 0;
  }

  /// Reports the covered rectangles of a tile that does not need a mask,
  /// merged along each row of cells.
  void coveredRects(
    int column,
    int row,
    void Function(int left, int top, int right, int bottom) emit,
  ) {
    final int tLeft = tileLeft(column);
    final int tTop = tileTop(row);
    final int tRight = tileRight(column);
    final int tBottom = tileBottom(row);
    if (_states[row * _columns + column] == 0) {
      if (_inside((tLeft + tRight) / 2, (tTop + tBottom) / 2)) {
        emit(tLeft, tTop, tRight, tBottom);
      }
      return;
    }
    _xs
      ..clear()
      ..add(tLeft.toDouble())
      ..add(tRight.toDouble());
    _ys
      ..clear()
      ..add(tTop.toDouble())
      ..add(tBottom.toDouble());
    final Float64List s = _segments;
    for (int i = 0; i < _segmentCount; i++) {
      final int o = i * 4;
      final double x0 = s[o];
      final double y0 = s[o + 1];
      final double x1 = s[o + 2];
      final double y1 = s[o + 3];
      if (x0 == x1) {
        final double minY = y0 < y1 ? y0 : y1;
        final double maxY = y0 < y1 ? y1 : y0;
        if (x0 > tLeft && x0 < tRight && maxY > tTop && minY < tBottom) {
          _xs.add(x0);
          if (minY > tTop && minY < tBottom) _ys.add(minY);
          if (maxY > tTop && maxY < tBottom) _ys.add(maxY);
        }
      } else if (y0 == y1) {
        final double minX = x0 < x1 ? x0 : x1;
        final double maxX = x0 < x1 ? x1 : x0;
        if (y0 > tTop && y0 < tBottom && maxX > tLeft && minX < tRight) {
          _ys.add(y0);
          if (minX > tLeft && minX < tRight) _xs.add(minX);
          if (maxX > tLeft && maxX < tRight) _xs.add(maxX);
        }
      }
    }
    _xs.sort();
    _ys.sort();
    for (int yi = 0; yi + 1 < _ys.length; yi++) {
      final double cTop = _ys[yi];
      final double cBottom = _ys[yi + 1];
      if (cBottom <= cTop) continue;
      final double cy = (cTop + cBottom) / 2;
      double runStart = -1;
      double runEnd = -1;
      for (int xi = 0; xi + 1 < _xs.length; xi++) {
        final double cLeft = _xs[xi];
        final double cRight = _xs[xi + 1];
        if (cRight <= cLeft) continue;
        if (_inside((cLeft + cRight) / 2, cy)) {
          if (runStart < 0) runStart = cLeft;
          runEnd = cRight;
        } else if (runStart >= 0) {
          emit(runStart.toInt(), cTop.toInt(), runEnd.toInt(), cBottom.toInt());
          runStart = -1;
        }
      }
      if (runStart >= 0) {
        emit(runStart.toInt(), cTop.toInt(), runEnd.toInt(), cBottom.toInt());
      }
    }
  }
}
