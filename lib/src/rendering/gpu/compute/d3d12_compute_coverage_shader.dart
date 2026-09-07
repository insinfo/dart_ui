/// The coverage kernel, declared so it can be chained after the segment stage.
///
/// `d3d12_compute_tile_shader.dart` already rasterises a binned scene into
/// coverage on the device, and this file is **not** a second algorithm: the
/// loop below is that file's `containsPoint`, `coverageAtPixel` and
/// `tileWorkItem`, transcribed with the same three load-bearing comparisons and
/// the same integer quantisation. What differs is only where the scene comes
/// from, and that difference is the whole reason this file exists.
///
/// ## Why a second declaration of the same loop, and not the same source
///
/// The tile shader binds all nine scene arrays as `StructuredBuffer` at
/// `t0..t8`, because its caller uploads all nine: `D3d12ComputeTileDriver` takes
/// a `ComputeTilePlan` the CPU built, which means `ComputeTileScene.build` -
/// flatten, coarse binning, segment binning and backdrops - ran on the CPU
/// before the GPU saw anything. That is the shape measured in
/// `RASTERIZADOR_COMPUTE_D.md`, and it is why coverage was never part of the
/// chained pipeline: chaining it would have meant routing the middle of the
/// pipeline back through the CPU, which is the fence the chain exists to
/// remove.
///
/// The chained pipeline produces five of the arrays this loop reads on the
/// device - `references` and `commands` from the coarse stage,
/// `referenceSegments`, `tileSegments` and `referenceBackdrops` from the
/// segment stage - and they are still there when this kernel runs. A consumer
/// reads a producer's buffer through `D3d12ComputeAlias`, and an alias binds a
/// **read-write** root descriptor: a root SRV would require
/// `NON_PIXEL_SHADER_RESOURCE`, and these buffers live in `UNORDERED_ACCESS`
/// from creation to release. So the five move from `t` registers to `u`
/// registers, declared `RWStructuredBuffer` and never written, exactly as
/// `d3d12_compute_segment_shader.dart` declares the two it borrows. A register
/// change is not expressible by sharing a source string, so the loop is
/// transcribed - and `d3d12_compute_coverage_parity_test.dart` compares this
/// kernel's output with the tile shader's, pixel for pixel, instead of
/// asserting the transcription is faithful.
///
/// ## Where `segments` and `draws` come from, and why it is a choice
///
/// One of two places, and never one of each. In a joined submission they are
/// the flatten stage's own segment buffer and the table `csDrawTable` builds
/// out of its scan; otherwise they are a `ComputeTilePlan`'s two arrays,
/// uploaded. `bounds` is always uploaded, because it is the control polygon's
/// box and the CPU has it without flattening anything.
///
/// This used to be an upload and only an upload, and the reason it was is worth
/// keeping: the two flatteners **number their segments differently**.
/// `ComputeCurveScene.appendPath` decides the closing edge of a contour before
/// anything is flattened and keeps the degenerate records, `ComputeTileScene`'s
/// sink decides it after and drops them, so the same path gets a different
/// segment count from each - the same picture, a different index. Binding one
/// half's buffer to the other half's table reads edges that exist and belong to
/// another draw, which is a wrong picture and not a failure, so the driver
/// refuses the mixture by argument.
///
/// What is removed is the expensive half. `ComputeTileScene.build` spends most
/// of its time in `_binSegments` - the benchmark in
/// `d3d12_compute_raster_pipeline_test.dart` measures the segment stage at
/// about 1.25 ms of a 1.76 ms chain, against 3.3 ms for the CPU planner doing
/// the same pair - and with this stage chained none of that has to happen on
/// the CPU or come back over the bus before coverage can run.
///
/// ## The dispatch covers tiles, not commands, and that is exact
///
/// The tile shader dispatches `plan.commandCount` groups, one per *occupied*
/// tile. A chained submission does not know that number: it is the last entry
/// of the coarse stage's occupancy scan, and reading it is the fence being
/// removed. So the caller dispatches over a count it does know - the tile count
/// - and sets `uCommandCount` to it.
///
/// The extra groups write nothing, and that is a property of the buffer rather
/// than luck. `D3d12ComputePass` zero-fills every buffer it owns before every
/// run, and the coarse stage's command kernel writes only the compacted prefix,
/// so a command slot past the real count reads as `(0, 0, 0)`: tile 0, an empty
/// reference run, a loop that does not execute. Over-dispatching costs empty
/// thread groups and changes no pixel, which the parity test checks by running
/// one scene at both dispatch sizes and comparing the buffers. `ExecuteIndirect`
/// is what would make it exact rather than merely correct, and is item 3 of
/// `RASTERIZADOR_COMPUTE_D.md`.
///
/// ## Every borrowed index is bounded, and that is not defensive style
///
/// The tile shader indexes a `ComputeTilePlan`, whose arrays are exact: a
/// reference index is in range because the CPU counted the references before
/// sizing the array. This kernel indexes the pipeline's **bump-allocated**
/// buffers, and the pipeline's entire retry policy rests on a budget being
/// allowed to turn out too small - `bins` keeps the exact counts either way,
/// which is what makes the retry work, so a tile's run can name references past
/// the end of a reference buffer that only held the budget.
///
/// `RASTERIZADOR_COMPUTE_D.md` records what that costs, because it happened:
/// **every buffer here is a root descriptor, and a root descriptor carries no
/// size.** There is no bounds check to discard the access the way a descriptor
/// table would, so an out-of-range index is a real memory access - and it
/// removed the device before it was understood. `uReferenceSlots` and
/// `uTileSegmentSlots` therefore bound the two borrowed index spaces, and a
/// reference or a segment run reaching past them is dropped. The coverage of
/// such a submission is garbage, which is right: the pipeline is about to
/// notice the overflow, grow the budgets and resubmit. What the guard buys is
/// that it survives to do so.
library;

/// Thread group size, and therefore the largest tile edge this kernel accepts.
///
/// The same 16 as `kD3d12ComputeTileMaxTileSize`, and deliberately a separate
/// constant: the two kernels have to agree, and the parity test asserts that
/// they do rather than letting one file's edit silently redefine the other's
/// dispatch.
const int kComputeCoverageMaxTileSize = 16;

/// Root-constant offsets, in 32-bit words.
///
/// The first nine are `D3d12ComputeTileRootConstant`'s block word for word,
/// [ComputeCoverageRootConstant.selectedDraw] included even though this kernel
/// never reads it: a parity test builds one constant block and feeds it to both
/// kernels, and a shorter prefix here would make every comparison depend on two
/// encoders agreeing - which is the bug the comparison exists to find.
///
/// The last two have no counterpart there and could not have one. See the guard
/// section of the library comment.
abstract final class ComputeCoverageRootConstant {
  static const int width = 0;
  static const int height = 1;
  static const int tileSize = 2;
  static const int columns = 3;
  static const int sampleGrid = 4;
  static const int pixelsPerDraw = 5;
  static const int commandCount = 6;
  static const int drawCount = 7;

  /// Unread here. Declared so the prefix matches the tile shader's.
  static const int selectedDraw = 8;

  /// How many reference slots the borrowed per-reference buffers hold.
  static const int referenceSlots = 9;

  /// How many entries the borrowed tile-segment buffer holds.
  static const int tileSegmentSlots = 10;
}

/// How many 32-bit values the coverage root constants occupy.
const int kComputeCoverageRootConstantCount = 11;

/// Read-only slots, as root-signature parameter indices.
const int kComputeCoverageBoundsSlot = 1;

/// Read-write slots, as root-signature parameter indices. The first seven are
/// other passes' buffers; the last is this stage's own output.
///
/// `segments` and `draws` moved here from the read-only side when the flatten
/// join was made: they are the flatten stage's output in a chained submission
/// and a `ComputeTilePlan`'s two arrays otherwise, and a root SRV cannot name
/// a buffer that lives in `UNORDERED_ACCESS`. `D3d12ComputeAlias` states the
/// argument once for every slot of this shape.
///
/// The coarse stage's `bins` is deliberately absent. The tile shader binds it
/// and never indexes it either - the run of references a tile owns is already
/// in that tile's command - and carrying a binding no kernel reads would claim
/// a dependency this stage does not have.
const int kComputeCoverageSegmentsSlot = 2;
const int kComputeCoverageDrawsSlot = 3;
const int kComputeCoverageReferencesSlot = 4;
const int kComputeCoverageCommandsSlot = 5;
const int kComputeCoverageReferenceSegmentsSlot = 6;
const int kComputeCoverageTileSegmentsSlot = 7;
const int kComputeCoverageBackdropsSlot = 8;
const int kComputeCoverageOutputSlot = 9;

const int kComputeCoverageFirstSrvSlot = kComputeCoverageBoundsSlot;
const int kComputeCoverageLastSrvSlot = kComputeCoverageBoundsSlot;
const int kComputeCoverageFirstUavSlot = kComputeCoverageSegmentsSlot;
const int kComputeCoverageLastUavSlot = kComputeCoverageOutputSlot;

/// The value `FillRule.evenOdd.index` has on the wire, as the kernel tests it.
const int kComputeCoverageEvenOdd = 1;

/// Index of the single entry point in [kComputeCoverageEntryPoints].
abstract final class ComputeCoverageKernel {
  static const int coverage = 0;
}

const String kComputeCoverageEntryPoint = 'csChainedCoverage';

const List<String> kComputeCoverageEntryPoints = <String>[
  kComputeCoverageEntryPoint,
];

/// Compilation target. `cs_5_0`, for the reason
/// `d3d12_compute_tile_shader.dart` states: Shader Model 6 needs
/// `dxcompiler.dll`, which does not ship with Windows.
const String kComputeCoverageTarget = 'cs_5_0';

/// The kernel.
const String kComputeCoverageShader = '''
cbuffer CoverageConstants : register(b0) {
  uint uWidth;
  uint uHeight;
  uint uTileSize;
  uint uColumns;
  uint uSampleGrid;
  uint uPixelsPerDraw;
  uint uCommandCount;
  uint uDrawCount;
  uint uSelectedDraw;
  uint uReferenceSlots;
  uint uTileSegmentSlots;
};

// Uploaded: the per-draw box, which the CPU has without flattening anything.
StructuredBuffer<float4> uBounds   : register(t0);

// The producers' buffers, bound by address. Declared read-write because that is
// what a root UAV descriptor is, and never written: a store into one would
// corrupt the stage that is still the source of truth for it.
//
// The first two are the flatten stage's when the chain joins it and a
// ComputeTilePlan's when it does not. They must come from the *same* half:
// uTileSegments indexes uSegments through the ranges in uDraws, and the two
// flatteners number their segments differently.
RWStructuredBuffer<float4> uSegments : register(u0);
RWStructuredBuffer<uint4>  uDraws    : register(u1);

RWStructuredBuffer<uint>  uReferences        : register(u2);
RWStructuredBuffer<uint3> uCommands          : register(u3);
RWStructuredBuffer<uint2> uReferenceSegments : register(u4);
RWStructuredBuffer<uint>  uTileSegments      : register(u5);
RWStructuredBuffer<int2>  uBackdrops         : register(u6);

RWStructuredBuffer<uint> uCoverage : register(u7);

// ComputeTileCpuReference.containsUsingSegmentBins, transcribed - the same
// transcription d3d12_compute_tile_shader.dart carries, whose library comment
// argues each of the three comparisons. Restated here only because the resource
// registers differ.
//
// The accumulator starts at the reference's backdrop rather than at zero: a
// segment lying entirely to the tile's right is in no tile's list yet crosses
// every sample in the tile, and dropping instead of counting those is what
// leaves a wide shape hollow.
//
// The caller has already checked reference < uReferenceSlots. The run is
// clamped here as well, because a reference that is itself in range can still
// name a run that starts or ends past an overflowed tile-segment budget.
bool containsPoint(uint draw, uint reference, float2 probe) {
  float4 bounds = uBounds[draw];
  if (probe.x < bounds.x || probe.x >= bounds.z ||
      probe.y < bounds.y || probe.y >= bounds.w) {
    return false;
  }
  int2 backdrop = uBackdrops[reference];
  uint2 span = uReferenceSegments[reference];
  uint first = min(span.x, uTileSegmentSlots);
  uint last = min(span.x + span.y, uTileSegmentSlots);
  int winding = backdrop.x;
  bool parity = backdrop.y != 0;
  for (uint cursor = first; cursor < last; cursor++) {
    float4 edge = uSegments[uTileSegments[cursor]];
    bool upward = (edge.y <= probe.y) && (edge.w > probe.y);
    bool downward = (edge.w <= probe.y) && (edge.y > probe.y);
    if (!upward && !downward) continue;
    float crossingX =
        edge.x + (probe.y - edge.y) * (edge.z - edge.x) / (edge.w - edge.y);
    if (crossingX <= probe.x) continue;
    parity = !parity;
    winding += upward ? 1 : -1;
  }
  return uDraws[draw].w == $kComputeCoverageEvenOdd ? parity : (winding != 0);
}

// ComputeTileCpuReference.coverageAtPixel: a regular grid of subpixel centres,
// counted, then quantised in integers so no float division is left for a driver
// to round the other way.
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

[numthreads($kComputeCoverageMaxTileSize, $kComputeCoverageMaxTileSize, 1)]
void csChainedCoverage(uint3 group : SV_GroupID,
                       uint3 thread : SV_GroupThreadID) {
  uint command = group.x;
  if (command >= uCommandCount) return;
  // A scene whose tile size is smaller than the group retires the extra threads
  // rather than clamping them, so a tile edge is never sampled twice.
  if (thread.x >= uTileSize || thread.y >= uTileSize) return;

  // A command slot past the real command count is zero, which names tile 0 with
  // an empty reference run: the loop below does not execute and nothing is
  // written. That is what makes dispatching over tiles instead of over commands
  // exact - see the library comment.
  uint3 work = uCommands[command];
  uint tile = work.x;
  uint2 pixel = uint2((tile % uColumns) * uTileSize + thread.x,
                      (tile / uColumns) * uTileSize + thread.y);
  if (pixel.x >= uWidth || pixel.y >= uHeight) return;

  uint firstReference = work.y;
  uint referenceCount = work.z;
  for (uint index = 0; index < referenceCount; index++) {
    uint reference = firstReference + index;
    // The bound the library comment argues: an overflowed reference budget
    // leaves this past the end of buffers that carry no size of their own.
    if (reference >= uReferenceSlots) break;
    uint draw = uReferences[reference];
    if (draw >= uDrawCount) continue;
    uCoverage[draw * uPixelsPerDraw + pixel.y * uWidth + pixel.x] =
        coverageAtPixel(draw, reference, pixel.x, pixel.y);
  }
}
''';

/// Checks the Dart-side constant contract against the source.
///
/// Runs before the pass is built, so a constant that drifted from the HLSL is a
/// named refusal at pipeline creation rather than a wrong pixel at the first
/// dispatch - the same contract the other three stages assert.
void validateComputeCoverageShaderContract() {
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
    'uReferenceSlots',
    'uTileSegmentSlots',
  ];
  if (names.length != kComputeCoverageRootConstantCount) {
    throw StateError(
      'kComputeCoverageRootConstantCount does not match the declared block',
    );
  }
  for (final String name in names) {
    if (!kComputeCoverageShader.contains('  uint $name;')) {
      throw StateError('missing coverage root constant: $name');
    }
  }
  for (var slot = kComputeCoverageFirstSrvSlot;
      slot <= kComputeCoverageLastSrvSlot;
      slot++) {
    final String register = 't${slot - kComputeCoverageFirstSrvSlot}';
    if (!kComputeCoverageShader.contains('register($register)')) {
      throw StateError('missing coverage resource register: $register');
    }
  }
  for (var slot = kComputeCoverageFirstUavSlot;
      slot <= kComputeCoverageLastUavSlot;
      slot++) {
    final String register = 'u${slot - kComputeCoverageFirstUavSlot}';
    if (!kComputeCoverageShader.contains('register($register)')) {
      throw StateError('missing coverage resource register: $register');
    }
  }
  if (!kComputeCoverageShader.contains('void $kComputeCoverageEntryPoint(')) {
    throw StateError(
      'missing coverage entry point: $kComputeCoverageEntryPoint',
    );
  }
  // Only the output slot may be stored to. The other five are another pass's
  // buffers bound by address, and a store into one corrupts the stage that owns
  // it - which would surface not here but as a wrong tile list later in the
  // same submission. The assertion is over the text because the compiler will
  // not make it: a `RWStructuredBuffer` is writable whether or not it should be.
  for (final String borrowed in <String>[
    'uSegments',
    'uDraws',
    'uReferences',
    'uCommands',
    'uReferenceSegments',
    'uTileSegments',
    'uBackdrops',
  ]) {
    if (RegExp('$borrowed\\[[^\\]]*\\]\\s*(=[^=]|\\+=|-=)')
        .hasMatch(kComputeCoverageShader)) {
      throw StateError(
        'the coverage kernel stores into $borrowed, which belongs to the pass '
        'it was chained after',
      );
    }
  }
  // The guard the library comment argues, asserted rather than trusted: without
  // it an overflowed budget is a real out-of-range memory access, because a
  // root descriptor carries no size.
  if (!kComputeCoverageShader.contains('reference >= uReferenceSlots')) {
    throw StateError('the coverage kernel does not bound its reference index');
  }
  if (!kComputeCoverageShader
      .contains('min(span.x + span.y, uTileSegmentSlots)')) {
    throw StateError('the coverage kernel does not bound its segment run');
  }
}
