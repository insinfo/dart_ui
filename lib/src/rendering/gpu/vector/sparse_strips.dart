/// Sparse coverage strips: a path's antialiasing reduced to its boundary.
///
/// ## What a strip is, and what problem it removes
///
/// The mask-atlas route (`gpu_mask_atlas.dart`) rasterises the *whole clipped
/// bounding box* of a path into alpha8 texels: a 300x300 rounded card costs
/// 90 000 texels of staging, upload and atlas residency, of which all but a
/// thin ring are either 0 or 255 - two values a shader could have produced
/// without a texture. The cost is proportional to **area**.
///
/// A sparse strip representation keeps only the pixels where coverage is
/// *interesting* - the antialiased boundary - and describes everything else as
/// runs: fully-covered runs become solid quads with no texture at all, and
/// empty runs become nothing. The cost is proportional to **perimeter**, which
/// for UI shapes is one to two orders of magnitude smaller. This is the core
/// idea of Vello's sparse-strip renderers (`vello_cpu` / `vello_hybrid`,
/// Apache-2.0/MIT); the representation here is a Dart reimplementation of that
/// *concept* - strips of [kStripHeight] rows carrying alpha texels, separated
/// by sparse fill runs - not a port of the Rust code. See
/// `THIRD_PARTY_NOTICES.md`.
///
/// ## Where the coverage itself comes from
///
/// From [ScanlineFiller], deliberately. Vello computes coverage with its own
/// tile pipeline (flatten -> 4x4 tiles -> per-column accumulation); this
/// framework already owns an exact analytic coverage rasteriser that the CPU
/// renderer, the mask atlas and every parity test share, and *one*
/// implementation of coverage is the property that makes CPU/GPU comparison a
/// measurement instead of a coincidence. So phase 1 keeps the filler as the
/// single source of coverage truth and changes only the *representation* of
/// its output: spans in, strips + fills out, byte-identical when
/// reconstructed - a test asserts exactly that. Replacing the filler with a
/// Vello-style tile pipeline (multithreadable, SIMD-friendly) is a phase-2
/// swap behind this same output format, and is discussed in
/// `doc/architecture/ACELERACAO_GPU_VETORIAL.md`.
///
/// ## The output format, stated tightly
///
/// A [StripBuffer] holds three arrays:
///
///   * **strips** - each is `x, y, width, alphaOffset`, with `y` a multiple of
///     [kStripHeight]. Its coverage lives at `alphaOffset` in [StripBuffer.alphas]:
///     `width * kStripHeight` bytes, row-major, top row first - the layout an
///     alpha8 texture upload wants.
///   * **fills** - each is `x, y, width`: a run of columns whose
///     [kStripHeight] rows are all fully covered. No texels; a solid quad.
///   * **alphas** - the strips' texels, strip-major.
///
/// Runs never overlap, cover every non-zero-coverage column exactly once, and
/// within one strip row appear left to right; strip rows appear top to bottom.
/// Coverage bytes mean what [CoverageSpanSink] says they mean: the value
/// `mul255` folds into the paint's alpha, so a reconstruction of this buffer
/// is comparable byte for byte against the filler's own spans.
library;

import 'dart:typed_data';

import '../../../geometry/path.dart';
import '../../../geometry/rect.dart';
import '../../../geometry/transform2d.dart';
import '../../path/coverage_span_sink.dart';
import '../../path/fill_rule.dart';
import '../../path/scanline_filler.dart';

/// Rows per strip. Four, matching Vello's `Tile::HEIGHT`/`STRIP_HEIGHT`: tall
/// enough that a strip quad amortises its vertex cost over four scanlines,
/// short enough that a nearly-horizontal edge does not drag whole rows of
/// interior pixels into the "boundary" class.
const int kStripHeight = 4;

/// Ints per strip record in [StripBuffer.strips]: `x, y, width, alphaOffset`.
const int kStripStride = 4;

/// Ints per fill record in [StripBuffer.fills]: `x, y, width`.
const int kFillStride = 3;

/// A zero- or full-coverage run shorter than this, sitting between two
/// boundary runs, is folded into the surrounding strip instead of splitting
/// it. Splitting costs two quads and a state-compatible-but-separate record;
/// four columns of redundant texels cost 16 bytes. The exact value is a
/// heuristic, not a contract, and the reconstruction test does not depend on
/// it - both encodings reconstruct identically.
const int kRunMergeThreshold = 4;

/// The sparse-strip encoding of one filled path. Reused across fills by
/// [SparseStripGenerator]; a caller must copy what it keeps.
final class StripBuffer {
  /// `kStripStride` ints per strip. Only the first [stripCount] records are
  /// meaningful; the array is pooled and keeps its high-water length.
  Int32List strips = Int32List(64 * kStripStride);
  int stripCount = 0;

  /// `kFillStride` ints per fill run.
  Int32List fills = Int32List(64 * kFillStride);
  int fillCount = 0;

  /// Strip texels, strip-major, `width * kStripHeight` bytes each, row-major.
  Uint8List alphas = Uint8List(1024);
  int alphaCount = 0;

  /// Number of draw quads a straightforward GPU consumer emits: one for
  /// every alpha strip and one for every fully covered fill run.
  int get quadCount => stripCount + fillCount;

  /// Bytes of meaningful packed data, excluding retained arena capacity.
  /// This is the number used to compare the sparse representation with a
  /// dense alpha8 mask of `bounds.width * bounds.height` bytes.
  int get encodedByteLength =>
      stripCount * kStripStride * 4 + fillCount * kFillStride * 4 + alphaCount;

  void reset() {
    stripCount = 0;
    fillCount = 0;
    alphaCount = 0;
  }

  int stripX(int i) => strips[i * kStripStride];
  int stripY(int i) => strips[i * kStripStride + 1];
  int stripWidth(int i) => strips[i * kStripStride + 2];
  int stripAlphaOffset(int i) => strips[i * kStripStride + 3];

  int fillX(int i) => fills[i * kFillStride];
  int fillY(int i) => fills[i * kFillStride + 1];
  int fillWidth(int i) => fills[i * kFillStride + 2];

  /// Coverage of strip [i] at column [column] (0-based within the strip) and
  /// row [row] (0..kStripHeight-1). For tests and debugging; the composer
  /// reads [alphas] in bulk.
  int stripAlpha(int i, int column, int row) =>
      alphas[stripAlphaOffset(i) + row * stripWidth(i) + column];

  void addStrip(int x, int y, int width, int alphaOffset) {
    final int base = stripCount * kStripStride;
    if (base + kStripStride > strips.length) {
      final Int32List grown = Int32List(strips.length * 2);
      grown.setRange(0, base, strips);
      strips = grown;
    }
    strips[base] = x;
    strips[base + 1] = y;
    strips[base + 2] = width;
    strips[base + 3] = alphaOffset;
    stripCount++;
  }

  void addFill(int x, int y, int width) {
    final int base = fillCount * kFillStride;
    if (base + kFillStride > fills.length) {
      final Int32List grown = Int32List(fills.length * 2);
      grown.setRange(0, base, fills);
      fills = grown;
    }
    fills[base] = x;
    fills[base + 1] = y;
    fills[base + 2] = width;
    fillCount++;
  }

  /// Reserves [count] alpha bytes and returns their offset.
  int reserveAlphas(int count) {
    final int offset = alphaCount;
    if (offset + count > alphas.length) {
      var length = alphas.length * 2;
      while (offset + count > length) {
        length *= 2;
      }
      final Uint8List grown = Uint8List(length);
      grown.setRange(0, offset, alphas);
      alphas = grown;
    }
    alphaCount = offset + count;
    return offset;
  }
}

/// Converts a path into a [StripBuffer], one fill at a time.
///
/// One instance per thread, kept across frames: the filler, the row staging
/// and the output buffer all grow to the busiest fill and are then reused.
final class SparseStripGenerator {
  SparseStripGenerator();

  final ScanlineFiller _filler = ScanlineFiller();
  final StripBuffer _buffer = StripBuffer();
  late final _StripRowSink _sink = _StripRowSink(this);

  /// Staging for the strip row being accumulated: `kStripHeight` rows of
  /// `_width` coverage bytes each, indexed `row * _width + (x - _clipLeft)`.
  Uint8List _rows = Uint8List(0);

  /// Per-column class for the flush pass: `_classZero`, `_classSolid` or
  /// `_classPartial`. Reused.
  Uint8List _classes = Uint8List(0);

  int _clipLeft = 0;
  int _width = 0;

  /// Top scanline of the strip row in `_rows`, always a multiple of
  /// [kStripHeight]; -1 when nothing is staged.
  int _stagedTop = -1;

  /// Columns of `_rows` that any span has touched since the last flush, so
  /// clearing is proportional to the shape and not the clip.
  int _touchedLeft = 0;
  int _touchedRight = 0;

  static const int _classZero = 0;
  static const int _classSolid = 1;
  static const int _classPartial = 2;

  /// Fills [path] and returns its sparse-strip encoding.
  ///
  /// Same contract as [ScanlineFiller.fill], because it *is* that fill with a
  /// different sink: [clip] is expanded outward to whole pixels, [transform]
  /// is applied during flattening, [tolerance] is in device pixels. The
  /// returned buffer is owned by this generator and valid until the next call.
  StripBuffer fill(
    Path path,
    Rect clip, {
    FillRule rule = FillRule.nonZero,
    Transform2D transform = Transform2D.identity,
    double tolerance = kDefaultFlattenTolerance,
  }) {
    _buffer.reset();
    _clipLeft = clip.left.floor();
    final int clipRight = clip.right.ceil();
    _width = clipRight - _clipLeft;
    if (_width <= 0) return _buffer;
    if (_rows.length < _width * kStripHeight) {
      _rows = Uint8List(_width * kStripHeight);
      _classes = Uint8List(_width);
    }
    _stagedTop = -1;
    _touchedLeft = _width;
    _touchedRight = 0;

    _filler.fill(
      path,
      clip,
      _sink,
      rule: rule,
      transform: transform,
      tolerance: tolerance,
    );
    _flushStripRow();
    return _buffer;
  }

  /// One span from the filler. Spans arrive with `y` non-decreasing, so strip
  /// rows complete in order and one staging buffer suffices.
  void _span(int y, int xStart, int xEnd, int coverage) {
    final int top = y & ~(kStripHeight - 1);
    if (top != _stagedTop) {
      _flushStripRow();
      _stagedTop = top;
    }
    final int row = y - top;
    final int from = row * _width + (xStart - _clipLeft);
    _rows.fillRange(from, from + (xEnd - xStart), coverage);
    final int left = xStart - _clipLeft;
    final int right = xEnd - _clipLeft;
    if (left < _touchedLeft) _touchedLeft = left;
    if (right > _touchedRight) _touchedRight = right;
  }

  /// Classifies the staged columns and emits strips and fills.
  void _flushStripRow() {
    if (_stagedTop < 0 || _touchedRight <= _touchedLeft) {
      _stagedTop = -1;
      return;
    }
    final int left = _touchedLeft;
    final int right = _touchedRight;
    final int w = _width;

    // Pass 1: classify each touched column.
    for (var x = left; x < right; x++) {
      final int a0 = _rows[x];
      final int a1 = _rows[w + x];
      final int a2 = _rows[2 * w + x];
      final int a3 = _rows[3 * w + x];
      if (a0 == 0 && a1 == 0 && a2 == 0 && a3 == 0) {
        _classes[x] = _classZero;
      } else if (a0 == 255 && a1 == 255 && a2 == 255 && a3 == 255) {
        _classes[x] = _classSolid;
      } else {
        _classes[x] = _classPartial;
      }
    }

    // Pass 2: fold short interior zero/solid runs into the surrounding
    // boundary, so a star's centre does not shatter into dozens of one-column
    // strips. Runs at the row's ends are never folded - a strip must not grow
    // past the ink.
    var runStart = left;
    while (runStart < right) {
      final int cls = _classes[runStart];
      var runEnd = runStart + 1;
      while (runEnd < right && _classes[runEnd] == cls) {
        runEnd++;
      }
      if (cls != _classPartial &&
          runEnd - runStart < kRunMergeThreshold &&
          runStart > left &&
          runEnd < right &&
          _classes[runStart - 1] == _classPartial &&
          _classes[runEnd] == _classPartial) {
        _classes.fillRange(runStart, runEnd, _classPartial);
      }
      runStart = runEnd;
    }

    // Pass 3: emit maximal runs.
    runStart = left;
    while (runStart < right) {
      final int cls = _classes[runStart];
      var runEnd = runStart + 1;
      while (runEnd < right && _classes[runEnd] == cls) {
        runEnd++;
      }
      final int runWidth = runEnd - runStart;
      switch (cls) {
        case _classSolid:
          _buffer.addFill(_clipLeft + runStart, _stagedTop, runWidth);
        case _classPartial:
          final int offset = _buffer.reserveAlphas(runWidth * kStripHeight);
          final Uint8List alphas = _buffer.alphas;
          for (var row = 0; row < kStripHeight; row++) {
            alphas.setRange(
              offset + row * runWidth,
              offset + (row + 1) * runWidth,
              _rows,
              row * w + runStart,
            );
          }
          _buffer.addStrip(_clipLeft + runStart, _stagedTop, runWidth, offset);
        default:
          break; // zero coverage: nothing to represent.
      }
      runStart = runEnd;
    }

    // Clear only what was written.
    for (var row = 0; row < kStripHeight; row++) {
      _rows.fillRange(row * w + left, row * w + right, 0);
    }
    _touchedLeft = _width;
    _touchedRight = 0;
    _stagedTop = -1;
  }
}

/// The [CoverageSpanSink] face of the generator, kept as a separate object so
/// the generator's public API cannot be mistaken for a sink and fed spans from
/// somewhere else mid-fill.
final class _StripRowSink implements CoverageSpanSink {
  _StripRowSink(this._generator);

  final SparseStripGenerator _generator;

  @override
  void span(int y, int xStart, int xEnd, int coverage) =>
      _generator._span(y, xStart, xEnd, coverage);
}
