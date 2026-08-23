/// The HLSL compute shaders that execute [ComputeTilePlan] on the GPU.
///
/// This is the first native executor for approach D in this framework, and the
/// thing worth stating first is what it does **not** do. It is not Vello: there
/// is no parallel flattening, no per-tile winding accumulation, no prefix scan,
/// no fine-raster/coarse-raster split. Flattening and binning already happened
/// on the CPU, in `compute_tile_scene.dart`, and these shaders consume their
/// output.
///
/// What they do is the step that had no GPU implementation at all: **turn the
/// binned scene into coverage**, on the device, from exactly the bytes
/// `ComputeTilePlan` already produces.
///
/// ## Two entry points, one algorithm
///
/// The coverage loop is written once, in [_shared], and two entry points differ
/// only in where they put the answer:
///
///   * [kD3d12ComputeTileBufferShader] / `csTileCoverage` writes one `uint` per
///     pixel **per draw** into a structured buffer. That is the layout
///     `ComputeTileCpuReference.rasterizeDraw` produces, which is what makes
///     the oracle comparison a direct one. It is a diagnostic: it is read back
///     on the CPU, so the pass that uses it waits for the GPU.
///   * [kD3d12ComputeTileTextureShader] / `csTileCoverageTexture` writes the
///     coverage of **one** draw - the one named by `uSelectedDraw` - into a
///     target-sized `RWTexture2D<float>`. That is the composition path: the
///     texture is then read by the sparse pipeline's pixel shader as if it were
///     an alpha page, and never leaves the GPU.
///
/// They are two separate compilation units rather than two entry points in one
/// source because both bind `u0`, and a single source declaring two resources
/// at the same register is a conflict the compiler refuses whether or not both
/// are reachable.
///
/// ## Why the composition texture is `R32_FLOAT` and holds `alpha / 255`
///
/// The format is the one Direct3D 12 guarantees for a typed UAV store on every
/// device - see `dxgiFormatR32Float`. The *value* is the coverage byte divided
/// by 255 rather than the byte itself, and that is not cosmetic: the composite
/// samples this texture through the same `Texture2D.Load(...).r` the sparse
/// pixel shader uses on an `R8_UNORM` alpha page, and `R8_UNORM` normalises to
/// exactly `byte / 255`. Writing the same number here is what makes the two
/// routes' composition arithmetic identical rather than merely similar.
///
/// ## Why the CPU reference is the specification, line for line
///
/// `ComputeTileCpuReference` evaluates ray crossings against the encoded
/// float32 segments and supersamples on a fixed grid. That is a deliberately
/// slow, deliberately independent oracle, and it is the only thing that can say
/// whether these shaders are right. So the loop is a transcription of it:
///
///   * the same bounds rejection, half-open on the right and bottom;
///   * the same `y0 <= y && y1 > y` / `y1 <= y && y0 > y` edge classification,
///     which is what makes a horizontal edge contribute nothing and a vertex
///     shared by two edges count once;
///   * the same `crossingX <= x` rejection, so a crossing exactly at the
///     sample is outside on both sides;
///   * the same `(covered * 255 + samples / 2) / samples` quantisation, in
///     integers, so the rounding cannot differ.
///
/// **The one thing that cannot be transcribed is the precision.** Dart computes
/// `x0 + (y - y0) * (x1 - x0) / (y1 - y0)` in float64 over float32 inputs; a
/// shader computes it in float32. For an axis-aligned edge the expression
/// collapses to `x0` and both are exact, which is why the rectangle scenes in
/// the parity test are compared at zero. For a slanted edge the two can land on
/// opposite sides of a sample when the crossing is within a float32 ulp of it,
/// which moves one subsample and therefore up to `255 / (sampleGrid *
/// sampleGrid)` levels on that one pixel. The parity test states the measured
/// number rather than assuming this bound.
///
/// ## Supersampled, not analytic - and that is a visible difference
///
/// Approach A and the sparse route both take their coverage from
/// `ScanlineFiller`, which computes **exact** pixel area. This shader
/// supersamples on a `sampleGrid * sampleGrid` grid. On an antialiased edge the
/// two disagree by up to roughly one subsample, so promoting a draw to D
/// changes its edge pixels compared with the dense atlas. That is a property of
/// the algorithm and not of this port; it is measured in
/// `d3d12_compute_composite_parity_test.dart` and recorded in
/// `doc/architecture/ACELERACAO_GPU_VETORIAL.md`.
///
/// ## The dispatch, and why one group is one tile
///
/// `ComputeTilePlan` already emits one command per *occupied* tile, in tile
/// order, each naming a contiguous run of draw references. That is exactly a
/// thread-group work item: `Dispatch(commandCount, 1, 1)` skips every empty
/// tile without an indirect argument buffer, a culling pass or an append
/// buffer, and the group's threads are the tile's pixels.
///
/// ## Segments are binned per tile, and the backdrop is why that is safe
///
/// The first version of this shader looped **every segment of the draw** for
/// every subsample, which measured out as the most expensive route in the
/// renderer: a rounded panel cost roughly 29 million edge tests. The plan now
/// carries a per-tile segment list and a per-tile *backdrop*, and the loop
/// reads only the list.
///
/// The backdrop is the part that is easy to get wrong. A segment lying entirely
/// to a tile's right is never *in* the tile, but every sample in that tile
/// still crosses it - so culling by intersection alone leaves wide shapes
/// hollow. `ComputeTileScene._binSegments` states the three-way split that
/// makes the decomposition exact instead of approximate, and
/// `compute_tile_segment_bins_test.dart` checks it sample by sample on the CPU,
/// with no GPU involved, before this shader ever runs.
///
/// A group is 16x16 because that is [kD3d12ComputeTileMaxTileSize] pixels, and
/// the tile size is a *runtime* value in the plan: threads outside the plan's
/// tile size return immediately, and the executor refuses a plan whose tile
/// size exceeds the group. Indirect dispatch buys nothing here - the command
/// count is known on the CPU that built the plan, so there is no GPU-side count
/// to read back - and it is the right tool only once binning itself moves to
/// the GPU.
library;

/// Thread group size, and therefore the largest tile edge these shaders accept.
const int kD3d12ComputeTileMaxTileSize = 16;

/// Root-constant offsets, in 32-bit words. Every entry is a `uint`, so the
/// packing is one word each with no straddling to consider.
abstract final class D3d12ComputeTileRootConstant {
  static const int width = 0;
  static const int height = 1;
  static const int tileSize = 2;
  static const int columns = 3;
  static const int sampleGrid = 4;
  static const int pixelsPerDraw = 5;
  static const int commandCount = 6;
  static const int drawCount = 7;

  /// Which draw the *texture* entry point writes. Ignored by the buffer entry
  /// point, which writes every draw into its own slice.
  static const int selectedDraw = 8;
}

/// How many 32-bit values the compute root constants occupy.
const int kD3d12ComputeTileRootConstantCount = 9;

/// Root-signature parameter indices. Six read-only scene buffers and one
/// output. The scene buffers are root descriptors - see `d3d12_structs.dart` on
/// why - while the output is a root descriptor for the buffer path and a
/// one-descriptor table for the texture path, because a root descriptor can
/// only address a buffer.
const int kD3d12ComputeTileRootConstantsSlot = 0;
const int kD3d12ComputeTileSegmentsSlot = 1;
const int kD3d12ComputeTileDrawsSlot = 2;
const int kD3d12ComputeTileBoundsSlot = 3;
const int kD3d12ComputeTileBinsSlot = 4;
const int kD3d12ComputeTileReferencesSlot = 5;
const int kD3d12ComputeTileCommandsSlot = 6;
const int kD3d12ComputeTileReferenceSegmentsSlot = 7;
const int kD3d12ComputeTileTileSegmentsSlot = 8;
const int kD3d12ComputeTileBackdropsSlot = 9;
const int kD3d12ComputeTileCoverageSlot = 10;
const int kD3d12ComputeTileRootParameterCount = 11;

/// The first and last shader-resource slot, so a root signature can bind them
/// in one loop and a reader can see there is no gap.
const int kD3d12ComputeTileFirstSrvSlot = kD3d12ComputeTileSegmentsSlot;
const int kD3d12ComputeTileLastSrvSlot = kD3d12ComputeTileBackdropsSlot;

/// The value `FillRule.evenOdd.index` has on the wire, as the shaders test it.
const int kD3d12ComputeTileEvenOdd = 1;

/// The constants, the scene buffers and the coverage loop, shared by both
/// entry points so they cannot drift apart.
const String _shared = '''
cbuffer TileConstants : register(b0) {
  uint uWidth;
  uint uHeight;
  uint uTileSize;
  uint uColumns;
  uint uSampleGrid;
  uint uPixelsPerDraw;
  uint uCommandCount;
  uint uDrawCount;
  uint uSelectedDraw;
};

// The six buffers are exactly ComputeTilePlan's arrays, uploaded verbatim:
// segments are x0,y0,x1,y1; draws are firstSegment,segmentCount,material,
// fillRule; bounds are left,top,right,bottom; bins are firstReference,count
// per tile; references are draw indices; commands are tile,firstReference,
// count per occupied tile.
StructuredBuffer<float4> uSegments   : register(t0);
StructuredBuffer<uint4>  uDraws      : register(t1);
StructuredBuffer<float4> uBounds     : register(t2);
StructuredBuffer<uint2>  uBins       : register(t3);
StructuredBuffer<uint>   uReferences : register(t4);
StructuredBuffer<uint3>  uCommands   : register(t5);

// The per-tile segment lists and backdrops. Without these the loop below reads
// every segment of the draw for every subsample, which is what made approach D
// the most expensive route in the renderer - see the library comment.
StructuredBuffer<uint2>  uReferenceSegments : register(t6);
StructuredBuffer<uint>   uTileSegments      : register(t7);
StructuredBuffer<int2>   uBackdrops         : register(t8);

// ComputeTileCpuReference.containsUsingSegmentBins, transcribed. See the
// library comment of d3d12_compute_tile_shader.dart for the three comparisons
// that are load bearing and for the one thing - float32 versus float64 - that
// cannot be.
//
// The accumulator does not start at zero: it starts at the tile's backdrop,
// which is the winding contributed by every segment that lies entirely to the
// tile's right and spans its whole height. Those segments are not in the list,
// and dropping them instead of counting them is what would leave a wide shape
// hollow. `ComputeTileScene._binSegments` proves the split is exact and
// `compute_tile_segment_bins_test.dart` measures it sample by sample.
bool containsPoint(uint draw, uint reference, float2 probe) {
  float4 bounds = uBounds[draw];
  if (probe.x < bounds.x || probe.x >= bounds.z ||
      probe.y < bounds.y || probe.y >= bounds.w) {
    return false;
  }
  int2 backdrop = uBackdrops[reference];
  uint2 span = uReferenceSegments[reference];
  int winding = backdrop.x;
  bool parity = backdrop.y != 0;
  for (uint index = 0; index < span.y; index++) {
    float4 edge = uSegments[uTileSegments[span.x + index]];
    bool upward = (edge.y <= probe.y) && (edge.w > probe.y);
    bool downward = (edge.w <= probe.y) && (edge.y > probe.y);
    if (!upward && !downward) continue;
    float crossingX =
        edge.x + (probe.y - edge.y) * (edge.z - edge.x) / (edge.w - edge.y);
    if (crossingX <= probe.x) continue;
    parity = !parity;
    winding += upward ? 1 : -1;
  }
  return uDraws[draw].w == $kD3d12ComputeTileEvenOdd
      ? parity
      : (winding != 0);
}

// ComputeTileCpuReference.coverageAtPixel, transcribed: a regular grid of
// subpixel centres, counted, then quantised with integer rounding so that no
// float division is left for a driver to round the other way.
uint coverageAtPixel(uint draw, uint reference, uint pixelX, uint pixelY) {
  uint samples = uSampleGrid * uSampleGrid;
  uint covered = 0;
  for (uint sampleY = 0; sampleY < uSampleGrid; sampleY++) {
    float y = float(pixelY) + (float(sampleY) + 0.5) / float(uSampleGrid);
    for (uint sampleX = 0; sampleX < uSampleGrid; sampleX++) {
      float x = float(pixelX) + (float(sampleX) + 0.5) / float(uSampleGrid);
      if (containsPoint(draw, reference, float2(x, y))) covered++;
    }
  }
  return (covered * 255 + samples / 2) / samples;
}

// Decodes one thread's work item, or returns false when it has none. Written
// once because the two entry points have to agree about which pixel a thread
// owns, and a divergence there would be invisible in one of them.
bool tileWorkItem(uint3 group, uint3 thread, out uint3 work, out uint2 pixel) {
  work = uint3(0, 0, 0);
  pixel = uint2(0, 0);
  uint command = group.x;
  if (command >= uCommandCount) return false;
  // A plan whose tile size is smaller than the group retires the extra threads
  // here rather than clamping, so a tile edge is never sampled twice.
  if (thread.x >= uTileSize || thread.y >= uTileSize) return false;
  work = uCommands[command];
  uint tile = work.x;
  pixel = uint2((tile % uColumns) * uTileSize + thread.x,
                (tile / uColumns) * uTileSize + thread.y);
  return pixel.x < uWidth && pixel.y < uHeight;
}
''';

/// The diagnostic entry point: one `uint` per pixel per draw, read back on the
/// CPU and compared with the oracle. Target `cs_5_0`.
const String kD3d12ComputeTileBufferShader = '''
$_shared

RWStructuredBuffer<uint> uCoverage : register(u0);

[numthreads($kD3d12ComputeTileMaxTileSize, $kD3d12ComputeTileMaxTileSize, 1)]
void csTileCoverage(uint3 group : SV_GroupID, uint3 thread : SV_GroupThreadID) {
  uint3 work;
  uint2 pixel;
  if (!tileWorkItem(group, thread, work, pixel)) return;

  uint firstReference = work.y;
  uint referenceCount = work.z;
  for (uint index = 0; index < referenceCount; index++) {
    uint reference = firstReference + index;
    uint draw = uReferences[reference];
    if (draw >= uDrawCount) continue;
    uCoverage[draw * uPixelsPerDraw + pixel.y * uWidth + pixel.x] =
        coverageAtPixel(draw, reference, pixel.x, pixel.y);
  }
}
''';

/// The composition entry point: one draw's coverage into a target-sized
/// texture, normalised the way an `R8_UNORM` alpha page would be. Target
/// `cs_5_0`.
const String kD3d12ComputeTileTextureShader = '''
$_shared

RWTexture2D<float> uCoverageTexture : register(u0);

[numthreads($kD3d12ComputeTileMaxTileSize, $kD3d12ComputeTileMaxTileSize, 1)]
void csTileCoverageTexture(
    uint3 group : SV_GroupID,
    uint3 thread : SV_GroupThreadID) {
  uint3 work;
  uint2 pixel;
  if (!tileWorkItem(group, thread, work, pixel)) return;

  // Only the selected draw. A tile that also references other draws writes
  // nothing for them, so the composite of one draw can never pick up another's
  // coverage - which is what keeps the ordered dense/vector interleave honest
  // when two promoted paths overlap.
  uint firstReference = work.y;
  uint referenceCount = work.z;
  for (uint index = 0; index < referenceCount; index++) {
    uint reference = firstReference + index;
    if (uReferences[reference] != uSelectedDraw) continue;
    // byte / 255, exactly what an R8_UNORM alpha page normalises to. See the
    // library comment.
    uCoverageTexture[pixel] = float(
        coverageAtPixel(uSelectedDraw, reference, pixel.x, pixel.y)) / 255.0;
    return;
  }
}
''';

/// Entry point names, passed to `D3DCompile` as ASCII.
const String kD3d12ComputeTileBufferEntryPoint = 'csTileCoverage';
const String kD3d12ComputeTileTextureEntryPoint = 'csTileCoverageTexture';

/// Compilation target.
///
/// `cs_5_0` rather than `cs_5_1` or Shader Model 6: 5.1 exists for descriptor
/// indexing and unbounded resource arrays, neither of which these shaders use,
/// and Shader Model 6 needs `dxcompiler.dll`, which - unlike
/// `d3dcompiler_47.dll` - does not ship with Windows. See the library comment
/// of `d3d12_library.dart` on why a pure-Dart framework compiles at device
/// creation rather than embedding bytecode; that argument only holds for the
/// compiler the operating system already has.
const String kD3d12ComputeTileTarget = 'cs_5_0';

/// Checks the Dart-side constant contract against both sources.
void validateD3d12ComputeTileShaderContract() {
  const List<String> names = <String>[
    'uWidth',
    'uHeight',
    'uTileSize',
    'uColumns',
    'uSampleGrid',
    'uPixelsPerDraw',
    'uCommandCount',
    'uDrawCount',
    'uSelectedDraw',
  ];
  if (names.length != kD3d12ComputeTileRootConstantCount) {
    throw StateError(
      'kD3d12ComputeTileRootConstantCount does not match the declared block',
    );
  }
  for (final String name in names) {
    if (!_shared.contains('  uint $name;')) {
      throw StateError('missing compute-tile root constant: $name');
    }
  }
  for (final String register in <String>[
    't0',
    't1',
    't2',
    't3',
    't4',
    't5',
    't6',
    't7',
    't8',
  ]) {
    if (!_shared.contains('register($register)')) {
      throw StateError('missing compute-tile resource register: $register');
    }
  }
  for (final (String, String) entry in <(String, String)>[
    (kD3d12ComputeTileBufferShader, kD3d12ComputeTileBufferEntryPoint),
    (kD3d12ComputeTileTextureShader, kD3d12ComputeTileTextureEntryPoint),
  ]) {
    if (!entry.$1.contains('void ${entry.$2}(')) {
      throw StateError('missing compute-tile entry point: ${entry.$2}');
    }
    if (!entry.$1.contains('register(u0)')) {
      throw StateError('${entry.$2} declares no output at u0');
    }
  }
}
