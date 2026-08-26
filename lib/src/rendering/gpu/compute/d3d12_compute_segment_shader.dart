/// The HLSL compute kernels that bin *segments* into tiles and accumulate the
/// per-tile backdrops on the GPU.
///
/// The third of the stages POC-23 named, and the one that decides whether
/// strategy D is measured honestly. `d3d12_compute_binning_shader.dart` bins
/// *draws* into tiles from their bounds; this bins the flattened segments of
/// each draw into the tiles that draw already occupies, and computes the
/// constant winding every tile inherits from the segments entirely to its
/// right. Together they are what `ComputeTileScene.build` does, and separately
/// neither of them is.
///
/// The specification is `ComputeTileScene._binSegments`, and its three outputs
/// are reproduced byte for byte:
///
///   * `referenceSegments` - `firstSegment, segmentCount` per (tile, draw)
///     reference, a CSR index into the next array;
///   * `tileSegments` - segment indices, reference-major, in **increasing
///     segment order** inside a reference;
///   * `referenceBackdrops` - `winding, parity` per reference.
///
/// ## The decomposition is the CPU's, transposed
///
/// The CPU walks draw, then tile row, then segment. This walks draw, then
/// segment, then tile row, because the *thread* is a (draw, segment) pair: the
/// segments of one draw are the only axis with enough parallelism to fill a
/// GPU in a scene of a few hundred draws. The two orders visit exactly the same
/// (draw, segment, row) triples, so the same three-way split applies unchanged:
///
///   * a segment left of the tile can never be counted - dropped;
///   * a segment right of the tile that spans the tile's **whole** y range is a
///     constant for every sample in it - folded into the backdrop;
///   * everything else is binned and evaluated per sample.
///
/// `ComputeTileScene._binSegments` proves that split exhaustive and exact; this
/// file does not re-argue it, it transcribes it.
///
/// ## Finding a reference index without a second index buffer
///
/// The CPU knows the reference index of a (tile, draw) pair because it walks
/// draws in order and carries a cursor per tile. A thread has no cursor and no
/// order. What it has is the output of the coarse stage: `uBins[tile]` is the
/// tile's run, and `uReferences` holds that run **sorted by draw index** -
/// which is the property `csSortReferences` exists to guarantee. So the
/// reference index of (tile, draw) is `bins[tile].x` plus the position of
/// `draw` in the run, and a binary search finds it in `log2(runLength)` steps.
///
/// That is deliberately not a second scatter pass building a (tile, draw) to
/// reference map: such a map is `tiles * draws` entries, and the search is over
/// a run whose length is the number of draws overlapping one tile - typically
/// one to a few, and never large in a scene the coarse stage did not already
/// refuse.
///
/// ## The backdrop is a difference array, and the references are its cells
///
/// The CPU accumulates each tile row's backdrop into a `columns + 1` difference
/// array and prefix-sums it once per row. The parallel form cannot keep a
/// per-row array in registers, but it does not need to: **every reference
/// belongs to exactly one (draw, row) pair**, so the difference array *is* the
/// backdrop buffer, indexed by reference. `csSegmentCounts` accumulates
/// `+delta` at the reference of the row's first column and `-delta` at the
/// reference of the column where the run stops, with `InterlockedAdd`, and
/// `csBackdropScan` runs one thread per (draw, row) that prefix-sums the row's
/// references in place. One buffer, no reset, and the same arithmetic.
///
/// The `-delta` at `stop == range.right` is dropped rather than written,
/// because the CPU's accumulation loop stops before that column: writing it
/// would need a `columns + 1`-th reference that does not exist.
///
/// ## Ordering inside a reference, again by rank sort - but one thread, not one
/// group
///
/// The CPU appends a reference's segments in increasing segment index, because
/// its inner loop is over segments. The scatter here is atomic and its order is
/// whatever the hardware did. A segment appears **at most once** in a given
/// (tile, draw) reference - each (segment, row, column) triple is visited once
/// - so the indices in one run are distinct, every rank is unique, and the rank
/// sort turns any scatter order into the CPU's order. It is the same argument,
/// and the same `O(n^2)` in a run's length, that
/// `d3d12_compute_binning_shader.dart` makes for draws.
///
/// What is *not* the same is the shape of the dispatch, and the difference is
/// not small. The coarse stage sorts one **tile's** run with one thread group,
/// and there are as many tiles as the grid has - a few thousand. Here the unit
/// is a (tile, draw) **reference**, and there are far more of them: 26 561 in
/// the 256-draw scene, holding 63 003 segments between them. A run is therefore
/// about *two and a half* elements long on average, and a group of 256 threads
/// dispatched to order two elements is 254 threads that read the guard and
/// retire.
///
/// So [kComputeSegmentSortEntryPoint] is one thread per reference, sorting its
/// whole run serially, and the dispatch is `referenceSlots / 256` groups rather
/// than `referenceSlots`. Total work is unchanged - it is still the sum of
/// `n^2` over the runs - it is only distributed differently, and a pathological
/// run long enough to want 256 threads is a run the mean says does not happen.
/// [kComputeSegmentSortWideEntryPoint] is the group-per-reference form, kept
/// selectable because that claim is a *measurement*, and
/// `d3d12_compute_raster_pipeline_test.dart` makes it in one run rather than
/// asking anyone to believe a comment.
///
/// ## Overflow is data, and *somebody else's* overflow is a bounds check
///
/// `uMaxTileSegments` bounds the segment-reference buffer. A scatter past it
/// writes nothing and `csSortSegments` skips a run that does not fit, so an
/// overflow cannot forge an entry. The *counts* are unaffected - the atomics
/// and the scan advance either way - so `uOffsets[uReferenceSlots]` carries the
/// exact total, the executor reads it, grows and resubmits.
///
/// The second kind of overflow is new here, because this is the first stage
/// that consumes another one's output. When the **coarse** stage overflowed its
/// reference budget, its `uBins` still carry the exact counts - that is what
/// makes its own retry work - so `bins[tile].x + bins[tile].y` can point past
/// the end of a reference buffer that only held the budget. A chained
/// submission cannot know that: the total is on the device.
///
/// Every buffer here is a **root descriptor**, and a root descriptor carries no
/// size. There is no hardware bounds check to discard the write, the way there
/// would be through a descriptor table - an out-of-range index is a real memory
/// access, and on this hardware it removes the device. So `referenceOf` clamps
/// its search to `uReferenceSlots` and returns `uReferenceSlots` when the tile's
/// run starts past the end, and every caller drops a reference that is not
/// strictly below it. The output of such a submission is garbage, which is
/// correct: the pipeline is about to notice the coarse overflow, grow both
/// budgets and resubmit. What the guard buys is that it survives to do so.
///
/// ## `uReferenceSlots` is a budget, not a count, and that is what makes this
/// chainable
///
/// Every kernel here is indexed by reference, and the number of references is a
/// result of the *previous* GPU stage. A chained submission cannot read it -
/// that is the fence being removed. So the dispatch covers a number of
/// reference **slots** the caller chose, which is the same bump-allocator
/// budget the coarse stage ran with. Slots past the real reference count were
/// zero-filled, contribute zero to the scan, sort an empty run and are never
/// named by any `uBins` entry, so the outputs are identical to a dispatch sized
/// exactly - and the unchained oracle shape simply passes the exact count as
/// the budget.
library;

import 'compute_scan.dart';

/// Threads per group.
const int kComputeSegmentGroupSize = kComputeScanGroupSize;

/// The most reference slots the two-level scan can index.
const int kComputeSegmentMaxReferences = kComputeScanMaxElements;

/// The generated scan kernels, named apart from the ones written here.
const ComputeScanEntryPoints kComputeSegmentScanEntryPoints =
    ComputeScanEntryPoints('csSegment');

/// Root-constant offsets, in 32-bit words.
abstract final class ComputeSegmentRootConstant {
  static const int drawCount = 0;
  static const int columns = 1;
  static const int rows = 2;
  static const int tileCount = 3;
  static const int tileSize = 4;
  static const int width = 5;
  static const int height = 6;
  static const int referenceSlots = 7;
  static const int blockCount = 8;
  static const int maxTileSegments = 9;
  static const int reserved0 = 10;
  static const int reserved1 = 11;
}

const int kComputeSegmentRootConstantCount = 12;

/// Root-signature parameter indices: constants, three read-only buffers, nine
/// read-write ones.
const int kComputeSegmentRootConstantsSlot = 0;
const int kComputeSegmentSegmentsSlot = 1;
const int kComputeSegmentDrawsSlot = 2;
const int kComputeSegmentBoundsSlot = 3;
const int kComputeSegmentBinsSlot = 4;
const int kComputeSegmentReferencesSlot = 5;
const int kComputeSegmentCountsSlot = 6;
const int kComputeSegmentOffsetsSlot = 7;
const int kComputeSegmentBlockSumsSlot = 8;
const int kComputeSegmentScratchSlot = 9;
const int kComputeSegmentTileSegmentsSlot = 10;
const int kComputeSegmentRefSegmentsSlot = 11;
const int kComputeSegmentBackdropsSlot = 12;
const int kComputeSegmentRootParameterCount = 13;

const int kComputeSegmentFirstSrvSlot = kComputeSegmentSegmentsSlot;
const int kComputeSegmentLastSrvSlot = kComputeSegmentBoundsSlot;
const int kComputeSegmentFirstUavSlot = kComputeSegmentBinsSlot;
const int kComputeSegmentLastUavSlot = kComputeSegmentBackdropsSlot;

/// Entry point names, passed to `D3DCompile` as ASCII.
const String kComputeSegmentCountsEntryPoint = 'csSegmentCounts';
const String kComputeSegmentBuildEntryPoint = 'csBuildRefSegments';
const String kComputeSegmentScatterEntryPoint = 'csScatterSegments';
const String kComputeSegmentSortEntryPoint = 'csSortSegments';
const String kComputeSegmentSortWideEntryPoint = 'csSortSegmentsWide';
const String kComputeSegmentBackdropEntryPoint = 'csBackdropScan';

/// Every compiled entry point, in the order [ComputeSegmentKernel] indexes
/// them. The dispatch order is the executor's, not this list's.
final List<String> kComputeSegmentEntryPoints = <String>[
  kComputeSegmentCountsEntryPoint,
  ...kComputeSegmentScanEntryPoints.all,
  kComputeSegmentBuildEntryPoint,
  kComputeSegmentScatterEntryPoint,
  kComputeSegmentSortEntryPoint,
  kComputeSegmentBackdropEntryPoint,
  kComputeSegmentSortWideEntryPoint,
];

/// Indices into [kComputeSegmentEntryPoints], for the dispatch chain.
abstract final class ComputeSegmentKernel {
  static const int counts = 0;
  static const int scanBlocks = 1;
  static const int scanBlockSums = 2;
  static const int scanApply = 3;
  static const int build = 4;
  static const int scatter = 5;
  static const int sort = 6;
  static const int backdrop = 7;

  /// The group-per-reference sort, dispatched instead of [sort] when a caller
  /// asks for it. Last in the list so the indices above never move.
  static const int sortWide = 8;
}

/// Compilation target.
const String kComputeSegmentTarget = 'cs_5_0';

/// Exact floor and ceiling of `value / tileSize`.
///
/// Character for character what `d3d12_compute_binning_shader.dart` uses, and
/// for the same reason: a tile index that lands on the other side of an integer
/// does not shift a pixel, it changes the length of a reference's segment run.
/// Unlike the coarse stage's use, `value` here is a *segment* coordinate and
/// may be negative - a path clipped to the surface keeps the geometry that fell
/// outside it - and the correction is a floor, so it is right for both signs.
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

/// Every segment-binning kernel, in one compilation unit.
final String kComputeSegmentShader = '''
cbuffer SegmentConstants : register(b0) {
  uint uDrawCount;
  uint uColumns;
  uint uRows;
  uint uTileCount;
  uint uTileSize;
  uint uWidth;
  uint uHeight;
  uint uReferenceSlots;
  uint uBlockCount;
  uint uMaxTileSegments;
  uint uReserved0;
  uint uReserved1;
};

// x0, y0, x1, y1 per segment - ComputeTilePlan.segments, verbatim.
StructuredBuffer<float4> uSegments : register(t0);
// firstSegment, segmentCount, material, fillRule per draw.
StructuredBuffer<uint4>  uDraws    : register(t1);
// left, top, right, bottom per draw.
StructuredBuffer<float4> uBounds   : register(t2);

// The coarse stage's two outputs. Read-write slots that this stage never
// writes: see D3d12ComputeAlias on why a chained read is a UAV and not an SRV.
RWStructuredBuffer<uint2> uBins       : register(u0);
RWStructuredBuffer<uint>  uReferences : register(u1);

// Segments per reference, then the scatter cursor. Two lives for one buffer,
// exactly as in the coarse stage.
RWStructuredBuffer<uint>  uCounts     : register(u2);
RWStructuredBuffer<uint>  uOffsets    : register(u3);
RWStructuredBuffer<uint>  uBlockSums  : register(u4);
// Segment indices in whatever order the atomics handed out slots.
RWStructuredBuffer<uint>  uScratch    : register(u5);
// The same indices, each reference's run sorted.
RWStructuredBuffer<uint>  uTileSegments : register(u6);
// firstSegment, segmentCount per reference.
RWStructuredBuffer<uint2> uRefSegments  : register(u7);
// winding, parity per reference - two uints, not an int2, because
// InterlockedAdd on a structured-buffer member is not cs_5_0. The winding is
// two's complement and asint recovers it.
RWStructuredBuffer<uint>  uBackdrops    : register(u8);

$_kTileRangeHelpers

// The half-open tile rectangle a draw can put ink in, or false when it can put
// none. Identical to the coarse stage's, because the two stages must agree on
// which draws exist and where: a draw the coarse stage dropped has no
// references, and a draw this one dropped would leave them empty.
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

// The reference index of (tile, draw): the tile's first reference plus the
// position of `draw` in the tile's run. The run is sorted, so this is a binary
// search, and `draw` is always present because the caller only asks about
// tiles inside the draw's own range.
//
// uReferenceSlots is not a formality. When the coarse stage overflowed, its
// bins still hold the exact counts and point past the end of the reference
// buffer; these are root descriptors and have no bounds check, so the clamp is
// what stands between that and a removed device. Out of range answers
// uReferenceSlots, which every caller drops.
uint referenceOf(uint tile, uint draw) {
  uint2 bin = uBins[tile];
  if (bin.x >= uReferenceSlots) return uReferenceSlots;
  uint lo = 0;
  uint hi = min(bin.y, uReferenceSlots - bin.x);
  [loop]
  while (lo < hi) {
    uint mid = lo + ((hi - lo) >> 1);
    if (uReferences[bin.x + mid] < draw) lo = mid + 1; else hi = mid;
  }
  return bin.x + lo;
}

// One (draw, segment) pair, over every tile row the draw occupies.
//
// `counting` picks the pass: the first accumulates the per-reference counts and
// the backdrop difference array, the second consumes the cursor those counts
// became and writes the segment indices. The backdrop is accumulated once, in
// the counting pass only - doing it in both would double every winding.
void walkSegment(uint draw, uint local, bool counting) {
  if (draw >= uDrawCount) return;
  uint4 d = uDraws[draw];
  if (local >= d.y) return;
  int4 range;
  if (!tileRangeOf(draw, range)) return;

  uint segment = d.x + local;
  float4 s = uSegments[segment];
  // A horizontal edge is neither upward nor downward for any sample, so it
  // belongs to no tile and to no backdrop.
  if (s.y == s.w) return;
  bool upward = s.w > s.y;
  float syMin = upward ? s.y : s.w;
  float syMax = upward ? s.w : s.y;
  float sxMin = min(s.x, s.z);
  float sxMax = max(s.x, s.z);
  // `low` is the first column whose right edge is past sxMin and `high` the
  // last whose left edge is before sxMax.
  int low = floorTile(sxMin, uTileSize);
  int high = ceilTile(sxMax, uTileSize) - 1;
  int delta = upward ? 1 : -1;
  int binRight = min(high, range.z - 1);

  [loop]
  for (int row = range.y; row < range.w; row++) {
    float rowTop = float(row * (int)uTileSize);
    float rowBottom = float(min((row + 1) * (int)uTileSize, (int)uHeight));
    if (syMax <= rowTop || syMin >= rowBottom) continue;
    // Does the segment cover this whole tile row? That is what decides whether
    // the columns to its left may treat it as a constant.
    bool spansRow = (syMin <= rowTop) && (syMax >= rowBottom);

    if (counting && spansRow) {
      int stop = min(low, range.z);
      if (stop > range.x) {
        uint ignored;
        uint head = referenceOf((uint)(row * (int)uColumns + range.x), draw);
        if (head < uReferenceSlots) {
          InterlockedAdd(uBackdrops[head * 2], asuint(delta), ignored);
          InterlockedAdd(uBackdrops[head * 2 + 1], 1u, ignored);
        }
        // The CPU writes -delta at column `stop` into a columns+1 array and
        // then sums only up to range.right-1, so a stop at range.right is
        // written and never read. There is no reference to write it into here,
        // and dropping it is the same arithmetic.
        if (stop < range.z) {
          uint tail = referenceOf((uint)(row * (int)uColumns + stop), draw);
          if (tail < uReferenceSlots) {
            InterlockedAdd(uBackdrops[tail * 2], asuint(-delta), ignored);
            InterlockedAdd(uBackdrops[tail * 2 + 1], asuint(-1), ignored);
          }
        }
      }
    }

    // A segment that spans the row contributes only where its x extent
    // overlaps; one that does not span it cannot be folded into a constant,
    // because whether it crosses depends on the sample's y - so every tile to
    // its left inside the draw has to evaluate it.
    int binLeft = spansRow ? max(low, range.x) : range.x;
    [loop]
    for (int col = binLeft; col <= binRight; col++) {
      uint reference = referenceOf((uint)(row * (int)uColumns + col), draw);
      if (reference >= uReferenceSlots) continue;
      uint slot;
      InterlockedAdd(uCounts[reference], 1, slot);
      // In the counting pass uCounts is a count and `slot` is meaningless; in
      // the scatter pass it is this reference's cursor and `slot` is where the
      // segment goes. Past the budget: write nothing. The cursor still
      // advanced, so uOffsets carries the exact total.
      if (!counting && slot < uMaxTileSegments) uScratch[slot] = segment;
    }
  }
}

[numthreads($kComputeSegmentGroupSize, 1, 1)]
void csSegmentCounts(uint3 id : SV_DispatchThreadID) {
  walkSegment(id.y, id.x, true);
}

${scanKernels(
  entryPoints: kComputeSegmentScanEntryPoints,
  elementCount: 'uReferenceSlots',
  blockCount: 'uBlockCount',
)}

[numthreads($kComputeSegmentGroupSize, 1, 1)]
void csBuildRefSegments(uint3 id : SV_DispatchThreadID) {
  uint reference = id.x;
  if (reference >= uReferenceSlots) return;
  uint first = uOffsets[reference];
  uRefSegments[reference] = uint2(first, uCounts[reference]);
  // uCounts becomes the scatter cursor, starting where this run does. Reading
  // and overwriting it in the same thread is safe; no other thread touches it.
  uCounts[reference] = first;
}

[numthreads($kComputeSegmentGroupSize, 1, 1)]
void csScatterSegments(uint3 id : SV_DispatchThreadID) {
  walkSegment(id.y, id.x, false);
}

// One thread per reference, sorting its whole run. See the library comment on
// why this is not one group per reference: a run here averages two or three
// segments, not the dozens a tile's draw run can hold.
[numthreads($kComputeSegmentGroupSize, 1, 1)]
void csSortSegments(uint3 id : SV_DispatchThreadID) {
  uint reference = id.x;
  if (reference >= uReferenceSlots) return;
  uint2 run = uRefSegments[reference];
  if (run.y == 0) return;
  // An overflowed run holds slots that were never written; sorting it would
  // produce a plausible wrong answer. The executor is about to run again with
  // a bigger buffer, so leave it.
  if (run.x + run.y > uMaxTileSegments) return;
  [loop]
  for (uint index = 0; index < run.y; index++) {
    uint value = uScratch[run.x + index];
    uint rank = 0;
    [loop]
    for (uint other = 0; other < run.y; other++) {
      if (uScratch[run.x + other] < value) rank++;
    }
    uTileSegments[run.x + rank] = value;
  }
}

// The same sort, one group per reference: the shape the coarse stage uses.
// Kept so the cost of the choice above can be measured instead of asserted.
[numthreads($kComputeSegmentGroupSize, 1, 1)]
void csSortSegmentsWide(uint3 group : SV_GroupID,
                        uint3 thread : SV_GroupThreadID) {
  uint reference = group.x;
  if (reference >= uReferenceSlots) return;
  uint2 run = uRefSegments[reference];
  if (run.y == 0) return;
  if (run.x + run.y > uMaxTileSegments) return;
  [loop]
  for (uint index = thread.x; index < run.y;
       index += $kComputeSegmentGroupSize) {
    uint value = uScratch[run.x + index];
    uint rank = 0;
    [loop]
    for (uint other = 0; other < run.y; other++) {
      if (uScratch[run.x + other] < value) rank++;
    }
    uTileSegments[run.x + rank] = value;
  }
}

[numthreads($kComputeSegmentGroupSize, 1, 1)]
void csBackdropScan(uint3 id : SV_DispatchThreadID) {
  uint draw = id.y;
  if (draw >= uDrawCount) return;
  int row = (int)id.x;
  int4 range;
  if (!tileRangeOf(draw, range)) return;
  if (row < range.y || row >= range.w) return;
  // Every reference of this (draw, row) belongs to this thread and to no
  // other, so the difference array can be prefix-summed in place with no
  // atomics and no second buffer.
  int winding = 0;
  uint parity = 0;
  [loop]
  for (int col = range.x; col < range.z; col++) {
    uint reference = referenceOf((uint)(row * (int)uColumns + col), draw);
    if (reference >= uReferenceSlots) continue;
    winding += asint(uBackdrops[reference * 2]);
    parity += uBackdrops[reference * 2 + 1];
    uBackdrops[reference * 2] = asuint(winding);
    uBackdrops[reference * 2 + 1] = parity & 1u;
  }
}
''';

/// Checks the Dart-side constant contract against the source.
void validateComputeSegmentShaderContract() {
  const List<String> names = <String>[
    'uDrawCount',
    'uColumns',
    'uRows',
    'uTileCount',
    'uTileSize',
    'uWidth',
    'uHeight',
    'uReferenceSlots',
    'uBlockCount',
    'uMaxTileSegments',
    'uReserved0',
    'uReserved1',
  ];
  if (names.length != kComputeSegmentRootConstantCount) {
    throw StateError(
      'kComputeSegmentRootConstantCount does not match the declared block',
    );
  }
  for (final String name in names) {
    if (!kComputeSegmentShader.contains('  uint $name;')) {
      throw StateError('missing segment root constant: $name');
    }
  }
  for (final String register in <String>[
    't0',
    't1',
    't2',
    'u0',
    'u1',
    'u2',
    'u3',
    'u4',
    'u5',
    'u6',
    'u7',
    'u8',
  ]) {
    if (!kComputeSegmentShader.contains('register($register)')) {
      throw StateError('missing segment resource register: $register');
    }
  }
  for (final String entryPoint in kComputeSegmentEntryPoints) {
    if (!kComputeSegmentShader.contains('void $entryPoint(')) {
      throw StateError('missing segment entry point: $entryPoint');
    }
  }
  validateComputeScanContract(
    kComputeSegmentShader,
    kComputeSegmentScanEntryPoints,
  );
  if (kComputeSegmentEntryPoints.length != ComputeSegmentKernel.sortWide + 1) {
    throw StateError('the segment kernel indices do not cover the entry list');
  }
  const List<int> indices = <int>[
    ComputeSegmentKernel.counts,
    ComputeSegmentKernel.scanBlocks,
    ComputeSegmentKernel.scanBlockSums,
    ComputeSegmentKernel.scanApply,
    ComputeSegmentKernel.build,
    ComputeSegmentKernel.scatter,
    ComputeSegmentKernel.sort,
    ComputeSegmentKernel.backdrop,
    ComputeSegmentKernel.sortWide,
  ];
  for (var i = 0; i < indices.length; i++) {
    if (indices[i] != i) {
      throw StateError('the segment kernel indices are out of order');
    }
  }
  if (kComputeSegmentRootConstantsSlot != 0 ||
      kComputeSegmentFirstSrvSlot != 1 ||
      kComputeSegmentFirstUavSlot != kComputeSegmentLastSrvSlot + 1 ||
      kComputeSegmentLastUavSlot + 1 != kComputeSegmentRootParameterCount) {
    throw StateError(
      'the segment root-parameter numbering is not constants, SRVs, UAVs',
    );
  }
}
