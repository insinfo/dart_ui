/// Backend-neutral scene encoding and deterministic tile binning for a future
/// compute path rasterizer.
///
/// This is deliberately a preparation contract, not a GPU capability. It
/// flattens paths into reusable line-segment buffers, records ordered draws,
/// and builds a CSR-style tile index. No backend advertises compute support and
/// no API binding consumes these buffers yet.
///
/// A real Vello-like implementation still needs parallel curve flattening,
/// per-tile winding/area accumulation, prefix scans, fine rasterization,
/// material shading, barriers, and backend-specific resource/dispatch code.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../../../geometry/path.dart';
import '../../../geometry/rect.dart';
import '../../../geometry/transform2d.dart';
import '../../path/fill_rule.dart';

const int kComputeTileSegmentStride = 4;
const int kComputeTileDrawStride = 4;
const int kComputeTileBoundsStride = 4;
const int kComputeTileBinStride = 2;
const int kComputeTileCommandStride = 3;

/// `firstSegment, segmentCount` per tile/draw reference.
const int kComputeTileReferenceSegmentStride = 2;

/// `winding, parity` per tile/draw reference. See [ComputeTilePlan] on why a
/// backdrop needs both numbers and not just the signed one.
const int kComputeTileBackdropStride = 2;

const int _maxUint32 = 0xFFFFFFFF;

/// How a clip rectangle is turned into the region a draw may cover.
///
/// The framework has one answer for this everywhere else, and it is not the
/// obvious one: `ScanlineFiller` - and therefore the CPU rasteriser, the dense
/// mask atlas and the sparse strip encoder - **expands its clip outward to
/// whole pixels** before filling. A clip edge at x = 10.5 clips at x = 10.
///
/// So [outwardWholePixel] is the default, because a route that clipped exactly
/// would disagree with every other route in the renderer on every fractional
/// clip edge - which is not "better antialiasing", it is a different picture
/// for the same display list. [exact] keeps the geometric rectangle for a
/// caller that is not comparing against those routes.
enum ComputeTileClipRounding {
  /// Round outward to whole pixels, matching `ScanlineFiller`.
  outwardWholePixel,

  /// Use the rectangle as given.
  exact,
}

/// Why scene encoding or binning was refused.
enum ComputeTileRejection {
  nonFiniteGeometry,
  segmentLimitExceeded,
  pathLimitExceeded,
  sceneSegmentLimitExceeded,
  tileLimitExceeded,
  tileReferenceLimitExceeded,
  tileSegmentLimitExceeded,
  integerOverflow,
}

final class ComputeTilePlanError extends StateError {
  ComputeTilePlanError(this.rejection, String detail)
      : super('${rejection.name}: $detail');

  final ComputeTileRejection rejection;
}

/// Backend-independent work and upload footprint exposed to a future planner.
final class ComputeTilePlanMetrics {
  const ComputeTilePlanMetrics({
    required this.drawCount,
    required this.segmentCount,
    required this.tileCount,
    required this.occupiedTileCount,
    required this.referenceCount,
    required this.tileSegmentReferenceCount,
    required this.uploadBytes,
  });

  final int drawCount;
  final int segmentCount;
  final int tileCount;
  final int occupiedTileCount;
  final int referenceCount;

  /// Total entries across every tile/draw segment list.
  ///
  /// The number that decides whether binning paid: a fine raster costs
  /// `pixels * samples * (this / referenceCount)` edge tests instead of
  /// `pixels * samples * segmentCount`.
  final int tileSegmentReferenceCount;

  /// Exact bytes across segment, draw, bounds, bin, reference and command
  /// buffers. This is a planning estimate until a backend defines alignment
  /// and staging requirements.
  final int uploadBytes;
}

/// Immutable device-space line segments reusable by multiple scene draws.
///
/// Every segment is `x0, y0, x1, y1`. Open contours are closed implicitly,
/// matching fill semantics. Zero-length edges are discarded. The stored
/// float32 values are the source of truth used both by the future compute
/// shader and by the CPU reference implementation.
final class ComputePathEncoding {
  ComputePathEncoding._(Float32List segments, this.bounds)
      : _segments = segments;

  factory ComputePathEncoding.fromPath(
    Path path, {
    Transform2D transform = Transform2D.identity,
    double flattenTolerance = kDefaultFlattenTolerance,
    int maxSegments = 1 << 20,
  }) {
    if (maxSegments <= 0 || maxSegments > _maxUint32) {
      throw RangeError.range(maxSegments, 1, _maxUint32, 'maxSegments');
    }
    if (!flattenTolerance.isFinite || flattenTolerance <= 0) {
      throw ArgumentError.value(
        flattenTolerance,
        'flattenTolerance',
        'must be finite and > 0',
      );
    }
    for (final double value in <double>[
      transform.a,
      transform.b,
      transform.c,
      transform.d,
      transform.tx,
      transform.ty,
    ]) {
      if (!value.isFinite) {
        throw ComputeTilePlanError(
          ComputeTileRejection.nonFiniteGeometry,
          'the path transform contains a non-finite coefficient',
        );
      }
    }
    for (var point = 0; point < path.pointCount; point++) {
      if (!path.pointX(point).isFinite || !path.pointY(point).isFinite) {
        throw ComputeTilePlanError(
          ComputeTileRejection.nonFiniteGeometry,
          'the source path contains a non-finite float32 coordinate',
        );
      }
    }

    final _ComputeSegmentSink sink = _ComputeSegmentSink(maxSegments);
    path.flattenTo(
      sink,
      tolerance: flattenTolerance,
      transform: transform,
    );
    return sink.finish();
  }

  final Float32List _segments;
  late final Float32List segments = _segments.asUnmodifiableView();
  final Rect bounds;

  int get segmentCount => _segments.length ~/ kComputeTileSegmentStride;
  bool get isEmpty => segmentCount == 0;

  double segmentX0(int segment) => _field(segment, 0);
  double segmentY0(int segment) => _field(segment, 1);
  double segmentX1(int segment) => _field(segment, 2);
  double segmentY1(int segment) => _field(segment, 3);

  double _field(int segment, int field) {
    if (segment < 0 || segment >= segmentCount) {
      throw RangeError.index(segment, _segments, 'segment');
    }
    return _segments[segment * kComputeTileSegmentStride + field];
  }
}

/// Reusable ordered scene. Appends retain encodings, not caller-owned paths.
final class ComputeTileScene {
  ComputeTileScene({
    this.maxPaths = 1 << 20,
    this.maxSegmentsPerPath = 1 << 20,
    this.maxUniqueSegments = 1 << 24,
  }) {
    _checkLimit(maxPaths, 'maxPaths');
    _checkLimit(maxSegmentsPerPath, 'maxSegmentsPerPath');
    _checkLimit(maxUniqueSegments, 'maxUniqueSegments');
  }

  final int maxPaths;
  final int maxSegmentsPerPath;
  final int maxUniqueSegments;
  final List<_ComputeTileDraw> _draws = <_ComputeTileDraw>[];
  final Set<ComputePathEncoding> _uniqueEncodings =
      Set<ComputePathEncoding>.identity();
  int _uniqueSegmentCount = 0;

  int get drawCount => _draws.length;
  int get uniqueEncodingCount => _uniqueEncodings.length;
  int get uniqueSegmentCount => _uniqueSegmentCount;

  /// Flattens and appends one path. Failure leaves the scene unchanged.
  int appendPath(
    Path path, {
    required Rect clip,
    required int materialIndex,
    required FillRule fillRule,
    Transform2D transform = Transform2D.identity,
    double flattenTolerance = kDefaultFlattenTolerance,
    ComputeTileClipRounding clipRounding =
        ComputeTileClipRounding.outwardWholePixel,
  }) {
    final ComputePathEncoding encoding = ComputePathEncoding.fromPath(
      path,
      transform: transform,
      flattenTolerance: flattenTolerance,
      maxSegments: maxSegmentsPerPath,
    );
    return appendEncoding(
      encoding,
      clip: clip,
      materialIndex: materialIndex,
      fillRule: fillRule,
      clipRounding: clipRounding,
    );
  }

  /// Appends a previously encoded path without flattening it again.
  ///
  /// The same encoding may be used by several materials or clips. Its segment
  /// range appears once in the resulting plan and every draw references it.
  int appendEncoding(
    ComputePathEncoding encoding, {
    required Rect clip,
    required int materialIndex,
    required FillRule fillRule,
    ComputeTileClipRounding clipRounding =
        ComputeTileClipRounding.outwardWholePixel,
  }) {
    if (materialIndex < 0 || materialIndex > _maxUint32) {
      throw RangeError.range(
        materialIndex,
        0,
        _maxUint32,
        'materialIndex',
      );
    }
    _validateRect(clip, 'clip');
    if (encoding.isEmpty || clip.isEmpty) return -1;
    final Rect effectiveClip =
        clipRounding == ComputeTileClipRounding.outwardWholePixel
            ? Rect.fromLTRB(
                clip.left.floorToDouble(),
                clip.top.floorToDouble(),
                clip.right.ceilToDouble(),
                clip.bottom.ceilToDouble(),
              )
            : clip;
    final Rect bounds = encoding.bounds.intersect(effectiveClip);
    if (bounds.isEmpty) return -1;
    if (_draws.length >= maxPaths) {
      throw ComputeTilePlanError(
        ComputeTileRejection.pathLimitExceeded,
        'the scene exceeds its configured limit of $maxPaths draws',
      );
    }
    final bool isNew = !_uniqueEncodings.contains(encoding);
    if (isNew &&
        encoding.segmentCount > maxUniqueSegments - _uniqueSegmentCount) {
      throw ComputeTilePlanError(
        ComputeTileRejection.sceneSegmentLimitExceeded,
        'unique scene segments exceed the configured limit of '
        '$maxUniqueSegments',
      );
    }

    // All validation precedes both mutations, so a refusal is transactional.
    final int draw = _draws.length;
    if (isNew) {
      _uniqueEncodings.add(encoding);
      _uniqueSegmentCount += encoding.segmentCount;
    }
    _draws.add(_ComputeTileDraw(encoding, bounds, materialIndex, fillRule));
    return draw;
  }

  /// Builds exact-sized typed buffers without changing this reusable scene.
  ComputeTilePlan build({
    required int width,
    required int height,
    int tileSize = 16,
    int maxTiles = 1 << 20,
    int maxTileReferences = 1 << 24,
    int maxTileSegmentReferences = 1 << 26,
  }) {
    _checkPositiveAxis(width, 'width');
    _checkPositiveAxis(height, 'height');
    _checkLimit(tileSize, 'tileSize');
    _checkLimit(maxTiles, 'maxTiles');
    _checkLimit(maxTileReferences, 'maxTileReferences');
    _checkLimit(maxTileSegmentReferences, 'maxTileSegmentReferences');
    final int columns = (width + tileSize - 1) ~/ tileSize;
    final int rows = (height + tileSize - 1) ~/ tileSize;
    if (columns > _maxUint32 ~/ rows) {
      throw ComputeTilePlanError(
        ComputeTileRejection.integerOverflow,
        'tile grid dimensions overflow uint32 indexing',
      );
    }
    final int tileCount = columns * rows;
    if (tileCount > maxTiles) {
      throw ComputeTilePlanError(
        ComputeTileRejection.tileLimitExceeded,
        'tile grid has $tileCount tiles, configured maximum is $maxTiles',
      );
    }

    final _ComputeSceneBuffers sceneBuffers = _encodeSceneBuffers();
    final Uint32List counts = Uint32List(tileCount);
    final Rect surface =
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
    var referenceCount = 0;
    for (var draw = 0; draw < _draws.length; draw++) {
      final Rect bounds = _draws[draw].bounds.intersect(surface);
      if (bounds.isEmpty) continue;
      final _TileRange range = _tileRange(bounds, columns, rows, tileSize);
      final int added = range.width * range.height;
      if (added > maxTileReferences - referenceCount) {
        throw ComputeTilePlanError(
          ComputeTileRejection.tileReferenceLimitExceeded,
          'tile references exceed the configured limit of $maxTileReferences',
        );
      }
      referenceCount += added;
      for (var y = range.top; y < range.bottom; y++) {
        for (var x = range.left; x < range.right; x++) {
          counts[y * columns + x]++;
        }
      }
    }

    final Uint32List bins = Uint32List(tileCount * kComputeTileBinStride);
    var first = 0;
    var occupied = 0;
    for (var tile = 0; tile < tileCount; tile++) {
      final int count = counts[tile];
      final int base = tile * kComputeTileBinStride;
      bins[base] = first;
      bins[base + 1] = count;
      first += count;
      if (count != 0) occupied++;
    }
    final Uint32List references = Uint32List(referenceCount);
    final Uint32List cursors = Uint32List(tileCount);
    for (var tile = 0; tile < tileCount; tile++) {
      cursors[tile] = bins[tile * kComputeTileBinStride];
    }
    // Draw-major insertion makes every tile's references stable and ordered.
    for (var draw = 0; draw < _draws.length; draw++) {
      final Rect bounds = _draws[draw].bounds.intersect(surface);
      if (bounds.isEmpty) continue;
      final _TileRange range = _tileRange(bounds, columns, rows, tileSize);
      for (var y = range.top; y < range.bottom; y++) {
        for (var x = range.left; x < range.right; x++) {
          final int tile = y * columns + x;
          references[cursors[tile]++] = draw;
        }
      }
    }
    final Uint32List commands =
        Uint32List(occupied * kComputeTileCommandStride);
    var command = 0;
    for (var tile = 0; tile < tileCount; tile++) {
      final int base = tile * kComputeTileBinStride;
      final int count = bins[base + 1];
      if (count == 0) continue;
      final int commandBase = command++ * kComputeTileCommandStride;
      commands[commandBase] = tile;
      commands[commandBase + 1] = bins[base];
      commands[commandBase + 2] = count;
    }

    final _ComputeSegmentBins segmentBins = _binSegments(
      height: height,
      tileSize: tileSize,
      columns: columns,
      rows: rows,
      tileCount: tileCount,
      bins: bins,
      referenceCount: referenceCount,
      segments: sceneBuffers.segments,
      draws: sceneBuffers.draws,
      surface: surface,
      maxTileSegmentReferences: maxTileSegmentReferences,
    );

    return ComputeTilePlan._(
      width: width,
      height: height,
      tileSize: tileSize,
      columns: columns,
      rows: rows,
      segments: sceneBuffers.segments,
      draws: sceneBuffers.draws,
      bounds: sceneBuffers.bounds,
      bins: bins,
      references: references,
      commands: commands,
      referenceSegments: segmentBins.referenceSegments,
      tileSegments: segmentBins.tileSegments,
      referenceBackdrops: segmentBins.backdrops,
    );
  }

  /// Splits every draw's segments into a per-tile list plus a per-tile
  /// **backdrop**, so a fine raster iterates the segments that can matter to a
  /// tile instead of all of a path's.
  ///
  /// ## The decomposition, and why it is exact rather than conservative
  ///
  /// `ComputeTileCpuReference.contains` counts signed crossings strictly to the
  /// **right** of the sample. Fix a tile `T = [x0, x1) x [y0, y1)` and a sample
  /// `(x, y)` inside it, and partition the draw's segments by their x extent:
  ///
  ///   * `sxMax <= x0` - entirely left of the tile. Its crossing is at
  ///     `crossingX <= sxMax <= x0 <= x`, so it can never satisfy
  ///     `crossingX > x`. **Contributes nothing, for every sample in the
  ///     tile.** Dropped.
  ///   * `sxMin >= x1` - entirely right of the tile. Its crossing is at
  ///     `crossingX >= sxMin >= x1 > x`, so it *always* satisfies
  ///     `crossingX > x`. Its contribution depends only on whether it spans
  ///     `y`, not on `x`.
  ///   * anything else - has to be evaluated per sample. Binned.
  ///
  /// The second group is where naive culling goes wrong: dropping those
  /// segments loses the winding they contribute, and a large shape fills
  /// incorrectly. Vello handles it with a per-tile *backdrop* accumulated along
  /// each tile row, and the same idea works here with one refinement that makes
  /// it exact rather than approximate: a right-of-tile segment is folded into
  /// the constant backdrop **only when it spans the tile's whole y range**
  /// (`syMin <= rowTop && syMax >= rowBottom`). One that spans only part of it
  /// would make the backdrop depend on `y`, so it is binned into the tile and
  /// evaluated exactly instead. The three cases stay mutually exclusive and
  /// exhaustive, so the sum is the number the brute-force loop computes - which
  /// `ComputeTileCpuReference.rasterizeDrawUsingSegmentBins` asserts sample by
  /// sample rather than taking on trust.
  ///
  /// The backdrop carries **two** numbers because the two fill rules need
  /// different ones: non-zero needs the signed winding, even-odd needs the
  /// parity of the *count*, and a signed sum of zero can hide either an even or
  /// an odd number of crossings.
  ///
  /// Backdrops are accumulated with a difference array per tile row and one
  /// prefix sum, which is what keeps this proportional to the tiles each
  /// segment touches instead of to every tile of the draw.
  _ComputeSegmentBins _binSegments({
    required int height,
    required int tileSize,
    required int columns,
    required int rows,
    required int tileCount,
    required Uint32List bins,
    required int referenceCount,
    required Float32List segments,
    required Uint32List draws,
    required Rect surface,
    required int maxTileSegmentReferences,
  }) {
    final Uint32List counts = Uint32List(referenceCount);
    final Int32List backdrops =
        Int32List(referenceCount * kComputeTileBackdropStride);
    final Int32List windingDiff = Int32List(columns + 1);
    final Int32List parityDiff = Int32List(columns + 1);
    final Uint32List cursors = Uint32List(tileCount);

    void resetCursors() {
      for (var tile = 0; tile < tileCount; tile++) {
        cursors[tile] = bins[tile * kComputeTileBinStride];
      }
    }

    // Two walks: one to count and compute every backdrop, one to fill. A
    // growable arena would need one, but the result is an exact-sized buffer a
    // backend uploads without interpretation, like every other array here.
    var total = 0;
    resetCursors();
    _walkBins(
      columns: columns,
      rows: rows,
      height: height,
      tileSize: tileSize,
      surface: surface,
      segments: segments,
      draws: draws,
      windingDiff: windingDiff,
      parityDiff: parityDiff,
      cursors: cursors,
      onBinned: (int reference, int segment) {
        counts[reference]++;
        total++;
        if (total > maxTileSegmentReferences) {
          throw ComputeTilePlanError(
            ComputeTileRejection.tileSegmentLimitExceeded,
            'per-tile segment references exceed the configured limit of '
            '$maxTileSegmentReferences',
          );
        }
      },
      onBackdrop: (int reference, int winding, int parity) {
        backdrops[reference * kComputeTileBackdropStride] = winding;
        backdrops[reference * kComputeTileBackdropStride + 1] = parity;
      },
    );

    final Uint32List referenceSegments =
        Uint32List(referenceCount * kComputeTileReferenceSegmentStride);
    final Uint32List fill = Uint32List(referenceCount);
    var offset = 0;
    for (var reference = 0; reference < referenceCount; reference++) {
      final int base = reference * kComputeTileReferenceSegmentStride;
      referenceSegments[base] = offset;
      referenceSegments[base + 1] = counts[reference];
      fill[reference] = offset;
      offset += counts[reference];
    }

    final Uint32List tileSegments = Uint32List(offset);
    resetCursors();
    _walkBins(
      columns: columns,
      rows: rows,
      height: height,
      tileSize: tileSize,
      surface: surface,
      segments: segments,
      draws: draws,
      windingDiff: windingDiff,
      parityDiff: parityDiff,
      cursors: cursors,
      onBinned: (int reference, int segment) {
        tileSegments[fill[reference]++] = segment;
      },
      onBackdrop: (int reference, int winding, int parity) {},
    );

    return _ComputeSegmentBins(referenceSegments, tileSegments, backdrops);
  }

  /// One draw-major walk over every (tile, draw) reference.
  ///
  /// Shared by both passes so they cannot visit tiles in different orders: the
  /// reference index of a (tile, draw) pair is `cursors[tile]` at the moment
  /// the walk reaches it, exactly as the reference array itself was filled, and
  /// two walks that disagreed would silently attribute one tile's segments to
  /// another.
  void _walkBins({
    required int columns,
    required int rows,
    required int height,
    required int tileSize,
    required Rect surface,
    required Float32List segments,
    required Uint32List draws,
    required Int32List windingDiff,
    required Int32List parityDiff,
    required Uint32List cursors,
    required void Function(int reference, int segment) onBinned,
    required void Function(int reference, int winding, int parity) onBackdrop,
  }) {
    for (var draw = 0; draw < _draws.length; draw++) {
      final Rect bounds = _draws[draw].bounds.intersect(surface);
      if (bounds.isEmpty) continue;
      final _TileRange range = _tileRange(bounds, columns, rows, tileSize);
      if (range.width <= 0 || range.height <= 0) continue;
      final int first = draws[draw * kComputeTileDrawStride];
      final int end = first + draws[draw * kComputeTileDrawStride + 1];

      for (var row = range.top; row < range.bottom; row++) {
        final double rowTop = (row * tileSize).toDouble();
        final double rowBottom =
            math.min((row + 1) * tileSize, height).toDouble();
        windingDiff.fillRange(range.left, range.right + 1, 0);
        parityDiff.fillRange(range.left, range.right + 1, 0);

        for (var segment = first; segment < end; segment++) {
          final int base = segment * kComputeTileSegmentStride;
          final double x0 = segments[base];
          final double y0 = segments[base + 1];
          final double x1 = segments[base + 2];
          final double y1 = segments[base + 3];
          // A horizontal edge is neither upward nor downward for any sample, so
          // it belongs to no tile and to no backdrop.
          if (y0 == y1) continue;
          final bool upward = y1 > y0;
          final double syMin = upward ? y0 : y1;
          final double syMax = upward ? y1 : y0;
          if (syMax <= rowTop || syMin >= rowBottom) continue;

          final double sxMin = x0 < x1 ? x0 : x1;
          final double sxMax = x0 < x1 ? x1 : x0;
          // `low` is the first column whose right edge is past sxMin and `high`
          // the last whose left edge is before sxMax: exactly the columns the
          // segment's x extent overlaps. Columns past `high` are to the
          // segment's right and can never see its crossing, so they are dropped
          // whatever else is true.
          final int low = (sxMin / tileSize).floor();
          final int high = (sxMax / tileSize).ceil() - 1;

          // Does the segment cover this whole tile row? That is what decides
          // whether the columns to its *left* may treat it as a constant.
          final bool spansRow = syMin <= rowTop && syMax >= rowBottom;
          if (spansRow) {
            // Constant for every sample in those tiles: accumulate it into the
            // backdrop instead of binning the segment into each of them.
            final int stop = low < range.right ? low : range.right;
            if (stop > range.left) {
              final int delta = upward ? 1 : -1;
              windingDiff[range.left] += delta;
              windingDiff[stop] -= delta;
              parityDiff[range.left] += 1;
              parityDiff[stop] -= 1;
            }
          }

          // Binned columns. A segment that spans the row contributes only where
          // its x extent overlaps; one that does **not** span the row cannot be
          // folded into a constant, because whether it crosses depends on the
          // sample's y - so every tile to its left inside the draw has to
          // evaluate it. That is the whole difference between this and a naive
          // intersection cull, and it is why a partially-spanning edge is the
          // only thing that costs more than its own tiles.
          final int overlapLeft = low > range.left ? low : range.left;
          final int binLeft = spansRow ? overlapLeft : range.left;
          final int binRight = high < range.right - 1 ? high : range.right - 1;
          for (var column = binLeft; column <= binRight; column++) {
            onBinned(cursors[row * columns + column], segment);
          }
        }

        var winding = 0;
        var parity = 0;
        for (var column = range.left; column < range.right; column++) {
          winding += windingDiff[column];
          parity += parityDiff[column];
          final int tile = row * columns + column;
          onBackdrop(cursors[tile]++, winding, parity & 1);
        }
      }
    }
  }

  void reset() {
    _draws.clear();
    _uniqueEncodings.clear();
    _uniqueSegmentCount = 0;
  }

  _ComputeSceneBuffers _encodeSceneBuffers() {
    final Float32List segments =
        Float32List(_uniqueSegmentCount * kComputeTileSegmentStride);
    final Uint32List draws = Uint32List(_draws.length * kComputeTileDrawStride);
    final Float32List bounds =
        Float32List(_draws.length * kComputeTileBoundsStride);
    final Map<ComputePathEncoding, int> firstSegments =
        Map<ComputePathEncoding, int>.identity();
    var segmentOffset = 0;
    for (final _ComputeTileDraw draw in _draws) {
      if (!firstSegments.containsKey(draw.encoding)) {
        firstSegments[draw.encoding] = segmentOffset;
        segments.setRange(
          segmentOffset * kComputeTileSegmentStride,
          (segmentOffset + draw.encoding.segmentCount) *
              kComputeTileSegmentStride,
          draw.encoding._segments,
        );
        segmentOffset += draw.encoding.segmentCount;
      }
    }
    for (var draw = 0; draw < _draws.length; draw++) {
      final _ComputeTileDraw value = _draws[draw];
      final int drawBase = draw * kComputeTileDrawStride;
      draws[drawBase] = firstSegments[value.encoding]!;
      draws[drawBase + 1] = value.encoding.segmentCount;
      draws[drawBase + 2] = value.materialIndex;
      draws[drawBase + 3] = value.fillRule.index;
      final int boundsBase = draw * kComputeTileBoundsStride;
      bounds[boundsBase] = value.bounds.left;
      bounds[boundsBase + 1] = value.bounds.top;
      bounds[boundsBase + 2] = value.bounds.right;
      bounds[boundsBase + 3] = value.bounds.bottom;
    }
    return _ComputeSceneBuffers(segments, draws, bounds);
  }

  static _TileRange _tileRange(
    Rect bounds,
    int columns,
    int rows,
    int tileSize,
  ) {
    final int left = (bounds.left / tileSize).floor().clamp(0, columns);
    final int top = (bounds.top / tileSize).floor().clamp(0, rows);
    final int right = (bounds.right / tileSize).ceil().clamp(0, columns);
    final int bottom = (bounds.bottom / tileSize).ceil().clamp(0, rows);
    return _TileRange(left, top, right, bottom);
  }

  static void _checkPositiveAxis(int value, String name) {
    if (value <= 0 || value > 0x7FFFFFFF) {
      throw RangeError.range(value, 1, 0x7FFFFFFF, name);
    }
  }

  static void _checkLimit(int value, String name) {
    if (value <= 0 || value > _maxUint32) {
      throw RangeError.range(value, 1, _maxUint32, name);
    }
  }

  static void _validateRect(Rect rect, String name) {
    for (final double value in <double>[
      rect.left,
      rect.top,
      rect.right,
      rect.bottom,
    ]) {
      final Float32List narrowed = Float32List(1)..[0] = value;
      if (!value.isFinite || !narrowed[0].isFinite) {
        throw ComputeTilePlanError(
          ComputeTileRejection.nonFiniteGeometry,
          '$name contains a coordinate not representable as float32',
        );
      }
    }
  }
}

/// Exact-sized buffers a future backend can upload without interpretation.
final class ComputeTilePlan {
  ComputeTilePlan._({
    required this.width,
    required this.height,
    required this.tileSize,
    required this.columns,
    required this.rows,
    required Float32List segments,
    required Uint32List draws,
    required Float32List bounds,
    required Uint32List bins,
    required Uint32List references,
    required Uint32List commands,
    required Uint32List referenceSegments,
    required Uint32List tileSegments,
    required Int32List referenceBackdrops,
  })  : _segments = segments,
        _draws = draws,
        _bounds = bounds,
        _bins = bins,
        _references = references,
        _commands = commands,
        _referenceSegments = referenceSegments,
        _tileSegments = tileSegments,
        _referenceBackdrops = referenceBackdrops;

  final int width;
  final int height;
  final int tileSize;
  final int columns;
  final int rows;
  final Float32List _segments;
  final Uint32List _draws;
  final Float32List _bounds;
  final Uint32List _bins;
  final Uint32List _references;
  final Uint32List _commands;
  final Uint32List _referenceSegments;
  final Uint32List _tileSegments;
  final Int32List _referenceBackdrops;

  late final Float32List segments = _segments.asUnmodifiableView();
  late final Uint32List draws = _draws.asUnmodifiableView();
  late final Float32List bounds = _bounds.asUnmodifiableView();
  late final Uint32List bins = _bins.asUnmodifiableView();
  late final Uint32List references = _references.asUnmodifiableView();
  late final Uint32List commands = _commands.asUnmodifiableView();

  /// `firstSegment, segmentCount` into [tileSegments], per reference.
  late final Uint32List referenceSegments =
      _referenceSegments.asUnmodifiableView();

  /// Segment indices, reference-major: the segments that can affect a sample
  /// inside one tile of one draw. See `ComputeTileScene._binSegments`.
  late final Uint32List tileSegments = _tileSegments.asUnmodifiableView();

  /// `winding, parity` per reference: the crossings that are *constant* over
  /// the whole tile because they lie entirely to its right and span its whole
  /// height. A fine raster starts its accumulator here.
  late final Int32List referenceBackdrops =
      _referenceBackdrops.asUnmodifiableView();

  int get segmentCount => _segments.length ~/ kComputeTileSegmentStride;
  int get drawCount => _draws.length ~/ kComputeTileDrawStride;
  int get tileCount => columns * rows;
  int get referenceCount => _references.length;
  int get commandCount => _commands.length ~/ kComputeTileCommandStride;

  /// Total entries across every tile/draw segment list.
  int get tileSegmentReferenceCount => _tileSegments.length;

  /// Mean segments a fine raster visits per sample, against [segmentCount]
  /// without binning. The number the cost of approach D is proportional to.
  double get meanSegmentsPerReference =>
      referenceCount == 0 ? 0 : _tileSegments.length / referenceCount;

  int referenceFirstSegment(int reference) => _referenceSegment(reference, 0);
  int referenceSegmentCount(int reference) => _referenceSegment(reference, 1);

  /// The [index]th segment binned into [reference], as an index into
  /// [segments].
  int referenceSegment(int reference, int index) {
    final int count = referenceSegmentCount(reference);
    if (index < 0 || index >= count) {
      throw RangeError.range(index, 0, count - 1, 'index');
    }
    return _tileSegments[referenceFirstSegment(reference) + index];
  }

  int referenceBackdropWinding(int reference) => _backdrop(reference, 0);
  int referenceBackdropParity(int reference) => _backdrop(reference, 1);

  int _referenceSegment(int reference, int field) {
    _checkReference(reference);
    return _referenceSegments[
        reference * kComputeTileReferenceSegmentStride + field];
  }

  int _backdrop(int reference, int field) {
    _checkReference(reference);
    return _referenceBackdrops[reference * kComputeTileBackdropStride + field];
  }

  void _checkReference(int reference) {
    if (reference < 0 || reference >= referenceCount) {
      throw RangeError.range(reference, 0, referenceCount - 1, 'reference');
    }
  }

  ComputeTilePlanMetrics get metrics => ComputeTilePlanMetrics(
        drawCount: drawCount,
        segmentCount: segmentCount,
        tileCount: tileCount,
        occupiedTileCount: commandCount,
        referenceCount: referenceCount,
        tileSegmentReferenceCount: _tileSegments.length,
        uploadBytes: _segments.lengthInBytes +
            _draws.lengthInBytes +
            _bounds.lengthInBytes +
            _bins.lengthInBytes +
            _references.lengthInBytes +
            _commands.lengthInBytes +
            _referenceSegments.lengthInBytes +
            _tileSegments.lengthInBytes +
            _referenceBackdrops.lengthInBytes,
      );

  double segmentX0(int segment) => _segment(segment, 0);
  double segmentY0(int segment) => _segment(segment, 1);
  double segmentX1(int segment) => _segment(segment, 2);
  double segmentY1(int segment) => _segment(segment, 3);

  int drawFirstSegment(int draw) => _draw(draw, 0);
  int drawSegmentCount(int draw) => _draw(draw, 1);
  int drawMaterial(int draw) => _draw(draw, 2);
  FillRule drawFillRule(int draw) => FillRule.values[_draw(draw, 3)];

  Rect drawBounds(int draw) {
    _checkDraw(draw);
    final int base = draw * kComputeTileBoundsStride;
    return Rect.fromLTRB(
      _bounds[base],
      _bounds[base + 1],
      _bounds[base + 2],
      _bounds[base + 3],
    );
  }

  int tileFirstReference(int tile) => _bin(tile, 0);
  int tileReferenceCount(int tile) => _bin(tile, 1);

  int tileDraw(int tile, int reference) {
    final int count = tileReferenceCount(tile);
    if (reference < 0 || reference >= count) {
      throw RangeError.range(reference, 0, count - 1, 'reference');
    }
    return _references[tileFirstReference(tile) + reference];
  }

  int commandTile(int command) => _command(command, 0);
  int commandFirstReference(int command) => _command(command, 1);
  int commandReferenceCount(int command) => _command(command, 2);

  Rect tileBounds(int tile) {
    _checkTile(tile);
    final int x = tile % columns;
    final int y = tile ~/ columns;
    return Rect.fromLTRB(
      (x * tileSize).toDouble(),
      (y * tileSize).toDouble(),
      math.min((x + 1) * tileSize, width).toDouble(),
      math.min((y + 1) * tileSize, height).toDouble(),
    );
  }

  double _segment(int segment, int field) {
    if (segment < 0 || segment >= segmentCount) {
      throw RangeError.index(segment, _segments, 'segment');
    }
    return _segments[segment * kComputeTileSegmentStride + field];
  }

  int _draw(int draw, int field) {
    _checkDraw(draw);
    return _draws[draw * kComputeTileDrawStride + field];
  }

  int _bin(int tile, int field) {
    _checkTile(tile);
    return _bins[tile * kComputeTileBinStride + field];
  }

  int _command(int command, int field) {
    if (command < 0 || command >= commandCount) {
      throw RangeError.index(command, _commands, 'command');
    }
    return _commands[command * kComputeTileCommandStride + field];
  }

  void _checkDraw(int draw) {
    if (draw < 0 || draw >= drawCount) {
      throw RangeError.index(draw, _draws, 'draw');
    }
  }

  void _checkTile(int tile) {
    if (tile < 0 || tile >= tileCount) {
      throw RangeError.index(tile, _bins, 'tile');
    }
  }
}

final class _ComputeSegmentSink implements PolylineSink {
  _ComputeSegmentSink(this.maxSegments);

  final int maxSegments;
  final List<double> _values = <double>[];
  bool _active = false;
  bool _hasEdge = false;
  double _startX = 0;
  double _startY = 0;
  double _currentX = 0;
  double _currentY = 0;

  @override
  void moveTo(double x, double y) {
    _finishContour();
    _validatePoint(x, y);
    _active = true;
    _hasEdge = false;
    _startX = _currentX = x;
    _startY = _currentY = y;
  }

  @override
  void lineTo(double x, double y) {
    _validatePoint(x, y);
    if (!_active) {
      moveTo(x, y);
      return;
    }
    if (x != _currentX || y != _currentY) {
      _add(_currentX, _currentY, x, y);
      _hasEdge = true;
    }
    _currentX = x;
    _currentY = y;
  }

  @override
  void close() => _finishContour();

  ComputePathEncoding finish() {
    _finishContour();
    final Float32List segments = Float32List.fromList(_values);
    if (segments.any((double value) => !value.isFinite)) {
      throw ComputeTilePlanError(
        ComputeTileRejection.nonFiniteGeometry,
        'flattened coordinates overflow float32 storage',
      );
    }
    if (segments.isEmpty) {
      return ComputePathEncoding._(segments, Rect.zero);
    }
    var left = double.infinity;
    var top = double.infinity;
    var right = double.negativeInfinity;
    var bottom = double.negativeInfinity;
    for (var i = 0; i < segments.length; i += 2) {
      left = math.min(left, segments[i]);
      top = math.min(top, segments[i + 1]);
      right = math.max(right, segments[i]);
      bottom = math.max(bottom, segments[i + 1]);
    }
    return ComputePathEncoding._(
      segments,
      Rect.fromLTRB(left, top, right, bottom),
    );
  }

  void _finishContour() {
    if (!_active) return;
    if (_hasEdge && (_currentX != _startX || _currentY != _startY)) {
      _add(_currentX, _currentY, _startX, _startY);
    }
    _active = false;
    _hasEdge = false;
  }

  void _add(double x0, double y0, double x1, double y1) {
    if (_values.length ~/ kComputeTileSegmentStride >= maxSegments) {
      throw ComputeTilePlanError(
        ComputeTileRejection.segmentLimitExceeded,
        'one encoded path exceeds the configured limit of $maxSegments '
        'segments',
      );
    }
    _values.addAll(<double>[x0, y0, x1, y1]);
  }

  static void _validatePoint(double x, double y) {
    if (!x.isFinite || !y.isFinite) {
      throw ComputeTilePlanError(
        ComputeTileRejection.nonFiniteGeometry,
        'flattening produced a non-finite device coordinate',
      );
    }
  }
}

final class _ComputeTileDraw {
  const _ComputeTileDraw(
    this.encoding,
    this.bounds,
    this.materialIndex,
    this.fillRule,
  );

  final ComputePathEncoding encoding;
  final Rect bounds;
  final int materialIndex;
  final FillRule fillRule;
}

/// The three arrays [ComputeTileScene._binSegments] produces.
final class _ComputeSegmentBins {
  const _ComputeSegmentBins(
    this.referenceSegments,
    this.tileSegments,
    this.backdrops,
  );

  final Uint32List referenceSegments;
  final Uint32List tileSegments;
  final Int32List backdrops;
}

final class _ComputeSceneBuffers {
  const _ComputeSceneBuffers(this.segments, this.draws, this.bounds);

  final Float32List segments;
  final Uint32List draws;
  final Float32List bounds;
}

final class _TileRange {
  const _TileRange(this.left, this.top, this.right, this.bottom);

  final int left;
  final int top;
  final int right;
  final int bottom;
  int get width => right - left;
  int get height => bottom - top;
}
