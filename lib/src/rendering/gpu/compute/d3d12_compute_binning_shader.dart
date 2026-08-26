/// The HLSL compute kernels that bin draws into tiles on the GPU.
///
/// The second of the stages POC-23 named - "flatten, binning, cobertura,
/// ordenação e composição na GPU". `ComputeTileScene.build` does this on the
/// CPU today and its output is the specification: a CSR tile index
/// (`bins`), the draw indices each tile references in **increasing draw
/// order** (`references`), and one command per *occupied* tile in tile order
/// (`commands`). The kernels below produce those three arrays, byte for byte.
///
/// ## Ordering is the whole difficulty, and atomics alone do not give it
///
/// Counting how many draws touch a tile is easy and order-free: an
/// `InterlockedAdd` per (draw, tile) yields the same sum whichever order the
/// groups run in. **Placing** them is not. The consumer needs each tile's
/// references sorted by draw index - the coverage shader composites a tile's
/// draws in the order it reads them, so a tile whose references arrive in
/// thread-retirement order paints the wrong shape on top - and an
/// `InterlockedAdd` cursor hands out slots in exactly that order.
///
/// Three ways out were considered:
///
///   * **One group per tile, scanning every draw.** Deterministic by
///     construction, but `O(tiles * draws)`, which is the wrong complexity for
///     the scene where D is supposed to win.
///   * **A stable counting sort.** Stability is sequential per key; there is no
///     stable parallel scatter without a per-key rank, which is the thing being
///     computed.
///   * **Atomic scatter, then rank-sort each tile's run.** What this does. The
///     scatter is `O(references)` and its *order* does not matter because the
///     next kernel replaces it: draw indices within one tile are distinct, so
///     each element's rank is the count of smaller elements, every rank is
///     unique, and the result is the sorted run regardless of what the atomics
///     produced. `csSortReferences` is `O(n^2)` in a tile's run length, which is
///     the number of draws overlapping one tile - small in any scene that is
///     not pathological, and stated here rather than discovered later.
///
/// ## The two scans are the same three kernels, dispatched twice
///
/// A tile index needs two prefix sums: one over per-tile draw counts, to get
/// `bins`, and one over per-tile *occupancy flags*, to compact the occupied
/// tiles into `commands`. They run over the same `uCounts`/`uOffsets`/
/// `uBlockSums` triple, because by the time the flags are needed `uCounts` has
/// already been consumed - `csBuildBins` copies what it needs into `uBins` and
/// then repurposes `uCounts` as the scatter cursor, and `csTileFlags`
/// overwrites it again.
///
/// Reusing three buffers instead of declaring six is not a micro-optimisation:
/// each is a root descriptor, and every additional stage buffer is another
/// resource whose zero-fill, barrier and lifetime have to be right.
///
/// ## The floor and ceiling of a tile index are computed exactly
///
/// `ComputeTileScene._tileRange` computes `(bounds.left / tileSize).floor()` in
/// float64 over coordinates that are exactly float32. The obvious
/// transcription - the same division in float32 - can land on the other side of
/// an integer, and a tile range that is one column wide on one side and two on
/// the other does not shift a pixel: it changes the *length* of every later
/// tile's reference run. So [_kTileRangeHelpers] divides and then corrects with
/// two exact comparisons, which makes both sides compute the true mathematical
/// floor and ceiling rather than agreeing by luck.
///
/// ## Overflow is data, exactly as in the flatten stage
///
/// `uMaxReferences` bounds the reference buffer. A scatter past it writes
/// nothing and `csSortReferences` skips a run that does not fit, so an overflow
/// cannot forge a reference. The *count* is unaffected - the atomics still
/// increment - so `uBins` carries the exact total, the executor reads it back,
/// grows the buffer and resubmits.
library;

import 'compute_scan.dart';

/// Threads per group.
const int kComputeBinningGroupSize = kComputeScanGroupSize;

/// The most tiles the two-level scan can index.
const int kComputeBinningMaxTiles = kComputeScanMaxElements;

/// The generated scan kernels, named apart from the ones written here.
const ComputeScanEntryPoints kComputeBinningScanEntryPoints =
    ComputeScanEntryPoints('csBinning');

/// Root-constant offsets, in 32-bit words.
abstract final class ComputeBinningRootConstant {
  static const int drawCount = 0;
  static const int columns = 1;
  static const int rows = 2;
  static const int tileCount = 3;
  static const int blockCount = 4;
  static const int tileSize = 5;
  static const int width = 6;
  static const int height = 7;
  static const int maxReferences = 8;
  static const int reserved = 9;
}

const int kComputeBinningRootConstantCount = 10;

/// Root-signature parameter indices: constants, one read-only buffer, seven
/// read-write ones.
const int kComputeBinningRootConstantsSlot = 0;
const int kComputeBinningBoundsSlot = 1;
const int kComputeBinningCountsSlot = 2;
const int kComputeBinningOffsetsSlot = 3;
const int kComputeBinningBlockSumsSlot = 4;
const int kComputeBinningScratchSlot = 5;
const int kComputeBinningReferencesSlot = 6;
const int kComputeBinningBinsSlot = 7;
const int kComputeBinningCommandsSlot = 8;
const int kComputeBinningRootParameterCount = 9;

const int kComputeBinningFirstSrvSlot = kComputeBinningBoundsSlot;
const int kComputeBinningLastSrvSlot = kComputeBinningBoundsSlot;
const int kComputeBinningFirstUavSlot = kComputeBinningCountsSlot;
const int kComputeBinningLastUavSlot = kComputeBinningCommandsSlot;

/// Entry point names, passed to `D3DCompile` as ASCII.
const String kComputeBinningTileCountsEntryPoint = 'csTileCounts';
const String kComputeBinningBuildBinsEntryPoint = 'csBuildBins';
const String kComputeBinningScatterEntryPoint = 'csScatterReferences';
const String kComputeBinningSortEntryPoint = 'csSortReferences';
const String kComputeBinningFlagsEntryPoint = 'csTileFlags';
const String kComputeBinningCommandsEntryPoint = 'csEmitCommands';

/// Every compiled entry point. The dispatch *order* is not this list: the scan
/// kernels are dispatched twice, and `d3d12_compute_binning_executor.dart`
/// owns the chain.
final List<String> kComputeBinningEntryPoints = <String>[
  kComputeBinningTileCountsEntryPoint,
  ...kComputeBinningScanEntryPoints.all,
  kComputeBinningBuildBinsEntryPoint,
  kComputeBinningScatterEntryPoint,
  kComputeBinningSortEntryPoint,
  kComputeBinningFlagsEntryPoint,
  kComputeBinningCommandsEntryPoint,
];

/// Indices into [kComputeBinningEntryPoints], for the dispatch chain.
abstract final class ComputeBinningKernel {
  static const int tileCounts = 0;
  static const int scanBlocks = 1;
  static const int scanBlockSums = 2;
  static const int scanApply = 3;
  static const int buildBins = 4;
  static const int scatter = 5;
  static const int sort = 6;
  static const int flags = 7;
  static const int commands = 8;
}

/// Compilation target. `cs_5_0`, for the reason
/// `d3d12_compute_tile_shader.dart` states.
const String kComputeBinningTarget = 'cs_5_0';

/// Exact floor and ceiling of `value / tileSize` for a non-negative `value`.
///
/// See the library comment on why the correction is not paranoia. Both products
/// are exact: a tile index times a tile size stays far below `2^24`, which is
/// where float32 stops representing integers exactly.
const String _kTileRangeHelpers = '''
int floorTile(float value, uint tileSize) {
  float ts = float(tileSize);
  float q = floor(value / ts);
  if (q * ts > value) q -= 1.0;
  if ((q + 1.0) * ts <= value) q += 1.0;
  return (int)q;
}

int ceilTile(float value, uint tileSize) {
  float ts = float(tileSize);
  float q = ceil(value / ts);
  if ((q - 1.0) * ts >= value) q -= 1.0;
  if (q * ts < value) q += 1.0;
  return (int)q;
}
''';

/// Every binning kernel, in one compilation unit.
final String kComputeBinningShader = '''
cbuffer BinningConstants : register(b0) {
  uint uDrawCount;
  uint uColumns;
  uint uRows;
  uint uTileCount;
  uint uBlockCount;
  uint uTileSize;
  uint uWidth;
  uint uHeight;
  uint uMaxReferences;
  uint uReserved;
};

// left, top, right, bottom per draw - ComputeTilePlan.bounds, verbatim.
StructuredBuffer<float4> uBounds : register(t0);

// Draws per tile, then the scatter cursor, then the occupancy flag. Three
// lives for one buffer; see the library comment.
RWStructuredBuffer<uint>  uCounts     : register(u0);
RWStructuredBuffer<uint>  uOffsets    : register(u1);
RWStructuredBuffer<uint>  uBlockSums  : register(u2);
// Draw indices in whatever order the atomics handed out slots.
RWStructuredBuffer<uint>  uScratch    : register(u3);
// The same indices, each tile's run sorted.
RWStructuredBuffer<uint>  uReferences : register(u4);
// firstReference, referenceCount per tile.
RWStructuredBuffer<uint2> uBins       : register(u5);
// tile, firstReference, referenceCount per occupied tile.
RWStructuredBuffer<uint3> uCommands   : register(u6);

$_kTileRangeHelpers

// The half-open tile rectangle a draw can put ink in, or false when it can put
// none. Transcribes ComputeTileScene.build's intersection with the surface and
// ComputeTileScene._tileRange's clamp, in that order.
bool tileRangeOf(uint draw, out int4 range) {
  range = int4(0, 0, 0, 0);
  float4 b = uBounds[draw];
  float l = max(b.x, 0.0);
  float t = max(b.y, 0.0);
  float r = min(b.z, float(uWidth));
  float bo = min(b.w, float(uHeight));
  if (r <= l || bo <= t) return false;
  int left   = clamp(floorTile(l,  uTileSize), 0, (int)uColumns);
  int top    = clamp(floorTile(t,  uTileSize), 0, (int)uRows);
  int right  = clamp(ceilTile(r,   uTileSize), 0, (int)uColumns);
  int bottom = clamp(ceilTile(bo,  uTileSize), 0, (int)uRows);
  if (right <= left || bottom <= top) return false;
  range = int4(left, top, right, bottom);
  return true;
}

[numthreads($kComputeBinningGroupSize, 1, 1)]
void csTileCounts(uint3 id : SV_DispatchThreadID) {
  uint draw = id.x;
  if (draw >= uDrawCount) return;
  int4 range;
  if (!tileRangeOf(draw, range)) return;
  // One thread per draw rather than per (draw, tile): the total work is the
  // reference count either way, and a draw whose tile range is the whole grid
  // is the load-imbalance case this trades away. Splitting by tile row is the
  // fix when a scene shows it.
  [loop]
  for (int y = range.y; y < range.w; y++) {
    [loop]
    for (int x = range.x; x < range.z; x++) {
      uint ignored;
      InterlockedAdd(uCounts[y * (int)uColumns + x], 1, ignored);
    }
  }
}

${scanKernels(
  entryPoints: kComputeBinningScanEntryPoints,
  elementCount: 'uTileCount',
  blockCount: 'uBlockCount',
)}

[numthreads($kComputeBinningGroupSize, 1, 1)]
void csBuildBins(uint3 id : SV_DispatchThreadID) {
  uint tile = id.x;
  if (tile >= uTileCount) return;
  uint first = uOffsets[tile];
  uBins[tile] = uint2(first, uCounts[tile]);
  // uCounts becomes the scatter cursor, starting where this tile's run does.
  // Reading it and overwriting it in the same thread is safe; no other thread
  // touches this element.
  uCounts[tile] = first;
}

[numthreads($kComputeBinningGroupSize, 1, 1)]
void csScatterReferences(uint3 id : SV_DispatchThreadID) {
  uint draw = id.x;
  if (draw >= uDrawCount) return;
  int4 range;
  if (!tileRangeOf(draw, range)) return;
  [loop]
  for (int y = range.y; y < range.w; y++) {
    [loop]
    for (int x = range.x; x < range.z; x++) {
      uint slot;
      InterlockedAdd(uCounts[y * (int)uColumns + x], 1, slot);
      // Past the budget: write nothing. The cursor still advanced, so uBins
      // carries the exact total and the executor detects the overflow.
      if (slot < uMaxReferences) uScratch[slot] = draw;
    }
  }
}

[numthreads($kComputeBinningGroupSize, 1, 1)]
void csSortReferences(uint3 group : SV_GroupID,
                      uint3 thread : SV_GroupThreadID) {
  uint tile = group.x;
  if (tile >= uTileCount) return;
  uint2 bin = uBins[tile];
  uint first = bin.x;
  uint count = bin.y;
  if (count == 0) return;
  // An overflowed run holds slots that were never written; sorting it would
  // produce a plausible wrong answer. The executor is about to run again with
  // a bigger buffer, so leave it.
  if (first + count > uMaxReferences) return;
  // Rank sort. A draw appears at most once in a tile, so the ranks are a
  // permutation and no two threads write the same slot - which is what lets
  // this be a scatter with no synchronisation at all.
  [loop]
  for (uint index = thread.x; index < count;
       index += $kComputeBinningGroupSize) {
    uint value = uScratch[first + index];
    uint rank = 0;
    [loop]
    for (uint other = 0; other < count; other++) {
      if (uScratch[first + other] < value) rank++;
    }
    uReferences[first + rank] = value;
  }
}

[numthreads($kComputeBinningGroupSize, 1, 1)]
void csTileFlags(uint3 id : SV_DispatchThreadID) {
  uint tile = id.x;
  if (tile >= uTileCount) return;
  uCounts[tile] = (uBins[tile].y != 0) ? 1 : 0;
}

[numthreads($kComputeBinningGroupSize, 1, 1)]
void csEmitCommands(uint3 id : SV_DispatchThreadID) {
  uint tile = id.x;
  if (tile >= uTileCount) return;
  uint2 bin = uBins[tile];
  if (bin.y == 0) return;
  // uOffsets now holds the exclusive scan of the occupancy flags, so this is
  // the tile's index among occupied tiles - which is exactly the position
  // ComputeTileScene.build gives its command.
  uCommands[uOffsets[tile]] = uint3(tile, bin.x, bin.y);
}
''';

/// Checks the Dart-side constant contract against the source.
void validateComputeBinningShaderContract() {
  const List<String> names = <String>[
    'uDrawCount',
    'uColumns',
    'uRows',
    'uTileCount',
    'uBlockCount',
    'uTileSize',
    'uWidth',
    'uHeight',
    'uMaxReferences',
    'uReserved',
  ];
  if (names.length != kComputeBinningRootConstantCount) {
    throw StateError(
      'kComputeBinningRootConstantCount does not match the declared block',
    );
  }
  for (final String name in names) {
    if (!kComputeBinningShader.contains('  uint $name;')) {
      throw StateError('missing binning root constant: $name');
    }
  }
  for (final String register in <String>[
    't0',
    'u0',
    'u1',
    'u2',
    'u3',
    'u4',
    'u5',
    'u6',
  ]) {
    if (!kComputeBinningShader.contains('register($register)')) {
      throw StateError('missing binning resource register: $register');
    }
  }
  for (final String entryPoint in kComputeBinningEntryPoints) {
    if (!kComputeBinningShader.contains('void $entryPoint(')) {
      throw StateError('missing binning entry point: $entryPoint');
    }
  }
  validateComputeScanContract(
    kComputeBinningShader,
    kComputeBinningScanEntryPoints,
  );
  if (kComputeBinningEntryPoints.length != ComputeBinningKernel.commands + 1) {
    throw StateError('the binning kernel indices do not cover the entry list');
  }
  const List<int> indices = <int>[
    ComputeBinningKernel.tileCounts,
    ComputeBinningKernel.scanBlocks,
    ComputeBinningKernel.scanBlockSums,
    ComputeBinningKernel.scanApply,
    ComputeBinningKernel.buildBins,
    ComputeBinningKernel.scatter,
    ComputeBinningKernel.sort,
    ComputeBinningKernel.flags,
    ComputeBinningKernel.commands,
  ];
  for (var i = 0; i < indices.length; i++) {
    if (indices[i] != i) {
      throw StateError('the binning kernel indices are out of order');
    }
  }
}
