/// The HLSL compute kernels that flatten curves into line segments on the GPU.
///
/// This is the stage the POC-23 report named first among the four still missing
/// from approach D - "flatten, binning, cobertura, ordenação e composição na
/// GPU". Coverage already runs on the device
/// (`d3d12_compute_tile_shader.dart`); flattening did not, and until now every
/// segment the coverage shader read had been produced by `Path.flattenTo` on
/// the CPU.
///
/// ## Five entry points, and why the middle three are a prefix sum
///
/// A curve does not know where its segments go. Curve `k` writes at
/// `sum(counts[0..k))`, and that sum is not available to the thread that needs
/// it - which is the reason a GPU rasterizer of this shape is built around a
/// scan and not around an append buffer. An append buffer would work and would
/// be shorter; it would also make the segment order depend on the order thread
/// groups happened to retire, and a buffer whose contents differ between two
/// runs of the same scene cannot be compared with a CPU oracle at all.
///
/// So the order is fixed by construction:
///
///   1. `csCurveCounts` - one thread per curve, writes `n` into `uCounts`.
///   2-4. the three kernels `compute_scan.dart` generates, which turn `uCounts`
///      into an exclusive prefix sum in `uOffsets` with the grand total at
///      `uOffsets[curveCount]`.
///   5. `csEmitSegments` - one group per curve, one thread per segment.
///
/// The scan is generated rather than written here because the binning stage
/// needs the same three kernels over different data, and two copies of a
/// barrier discipline is two chances to get it wrong. Its two-level ceiling -
/// [kComputeFlattenMaxCurves] - is a *stated* limit the executor refuses past
/// by name, not an oversight.
///
/// ## Why the emit dispatch is one group per curve
///
/// The natural shape is one thread per *segment*, which is what Vello does -
/// but the number of segments is a GPU-side result, so the CPU cannot size that
/// dispatch without reading it back, and reading it back means a fence wait in
/// the middle of the pass. `ExecuteIndirect` is the right answer and this
/// backend does not bind it yet.
///
/// One group per curve needs no count the CPU does not already have: the curve
/// count is in the scene. A group's 256 threads stride over that curve's
/// segments, so a curve of 1000 segments takes four iterations and a curve of
/// one segment retires 255 threads immediately. That wastes lanes on scenes
/// made of short curves and is the honest cost of not having indirect dispatch.
///
/// ## The segment budget is a bump allocator, and overflow is data
///
/// The output buffer has to be sized before the total is known. Rather than
/// guess and hope, `uMaxSegments` is a hard bound the emit kernel respects:
/// a segment whose slot is past it is **not written**, and nothing is clamped
/// into the last slot, so an overflow cannot forge a segment. The total lands
/// in `uOffsets[curveCount]` regardless of the budget, so the executor reads it
/// back, sees that it exceeded the bound, grows the buffer and resubmits. That
/// is how Vello's bump allocator behaves and it is the only shape that avoids
/// either a CPU pre-pass or a silently truncated scene.
///
/// ## The specification, and where it lives
///
/// `compute_curve_scene.dart` states the flatten rule: the segment count
/// formula, direct evaluation at `t = j / n`, exact endpoints, and the
/// deliberate decision to keep zero-length segments. `ComputeFlattenReference`
/// computes it in Dart with float32 rounding after every operation. The code
/// below is written to match that Dart expression by expression - the same
/// association, the same `m0 > m1 ? m0 : m1` rather than `max`, the same
/// `(p0 - 2 p1) + p2` grouping - because the parity test compares **integers**
/// first: a segment count that differs by one does not move a pixel, it moves
/// every later segment in the buffer.
///
/// What still cannot be transcribed is contraction: a compiler may turn
/// `a * b + c` into a single operation with one rounding, and no HLSL flag
/// forbids it. That is why the parity test measures the coordinate deviation
/// instead of asserting zero, and why `ComputeFlattenReference.
/// segmentCountMargin` reports how far each curve sits from the integer
/// boundary where such a contraction could change a count.
library;

import 'compute_scan.dart';

/// Threads per group. The scan's radix, and the emit kernel's group size.
const int kComputeFlattenGroupSize = kComputeScanGroupSize;

/// The most curves the two-level scan in `compute_scan.dart` can handle.
const int kComputeFlattenMaxCurves = kComputeScanMaxElements;

/// The three generated scan kernels, named apart from the two written here.
const ComputeScanEntryPoints kComputeFlattenScanEntryPoints =
    ComputeScanEntryPoints('csFlatten');

/// Upper bound on the segments one curve flattens into.
///
/// The same number `kMaxSegmentsPerCurve` fixes in `geometry/path.dart`,
/// restated here because the shader cannot import it and a silent divergence
/// would change every count on curves past the bound.
const int kComputeFlattenMaxSegmentsPerCurve = 1024;

/// Root-constant offsets, in 32-bit words.
abstract final class ComputeFlattenRootConstant {
  static const int curveCount = 0;
  static const int blockCount = 1;
  static const int maxSegments = 2;
  static const int reserved = 3;
}

const int kComputeFlattenRootConstantCount = 4;

/// Root-signature parameter indices: root constants, three read-only scene
/// buffers, four read-write stage buffers.
const int kComputeFlattenRootConstantsSlot = 0;
const int kComputeFlattenCurvesSlot = 1;
const int kComputeFlattenCurvePointsSlot = 2;
const int kComputeFlattenTransformsSlot = 3;
const int kComputeFlattenCountsSlot = 4;
const int kComputeFlattenOffsetsSlot = 5;
const int kComputeFlattenBlockSumsSlot = 6;
const int kComputeFlattenSegmentsSlot = 7;
const int kComputeFlattenRootParameterCount = 8;

const int kComputeFlattenFirstSrvSlot = kComputeFlattenCurvesSlot;
const int kComputeFlattenLastSrvSlot = kComputeFlattenTransformsSlot;
const int kComputeFlattenFirstUavSlot = kComputeFlattenCountsSlot;
const int kComputeFlattenLastUavSlot = kComputeFlattenSegmentsSlot;

/// Entry point names, passed to `D3DCompile` as ASCII.
const String kComputeFlattenCountsEntryPoint = 'csCurveCounts';
const String kComputeFlattenEmitEntryPoint = 'csEmitSegments';

/// Every entry point, in dispatch order.
final List<String> kComputeFlattenEntryPoints = <String>[
  kComputeFlattenCountsEntryPoint,
  ...kComputeFlattenScanEntryPoints.all,
  kComputeFlattenEmitEntryPoint,
];

/// Compilation target.
///
/// `cs_5_0` for the reason `d3d12_compute_tile_shader.dart` states: Shader
/// Model 6 needs `dxcompiler.dll`, which does not ship with Windows, and
/// nothing here uses a 5.1 feature.
const String kComputeFlattenTarget = 'cs_5_0';

/// All five kernels, in one compilation unit.
///
/// One source rather than five because every resource sits at a distinct
/// register, so there is no conflict to avoid - unlike the coverage shaders,
/// which had to be split because both wanted `u0`. One source also means one
/// copy of the arithmetic that has to agree with Dart expression by
/// expression.
final String kComputeFlattenShader = '''
cbuffer FlattenConstants : register(b0) {
  uint uCurveCount;
  uint uBlockCount;
  uint uMaxSegments;
  uint uReserved;
};

// kind, path, 0, 0 per curve.
StructuredBuffer<uint4>  uCurves       : register(t0);
// x0,y0,x1,y1 then x2,y2,x3,y3 per curve, in source space.
StructuredBuffer<float4> uCurvePoints  : register(t1);
// a,b,c,d then tx,ty,tolerance,0 per path.
StructuredBuffer<float4> uTransforms   : register(t2);

RWStructuredBuffer<uint>   uCounts    : register(u0);
RWStructuredBuffer<uint>   uOffsets   : register(u1);
RWStructuredBuffer<uint>   uBlockSums : register(u2);
RWStructuredBuffer<float4> uSegments  : register(u3);

static const uint kLine = 0;
static const uint kQuadratic = 1;
static const uint kCubic = 2;
static const uint kMaxSegmentsPerCurve = $kComputeFlattenMaxSegmentsPerCurve;

// The path's affine map, applied to a source-space control point.
//
// Applied here rather than on the CPU because it is O(control points) of
// exactly the arithmetic this kernel already does, and because the segment
// count has to be chosen in *device* space - a magnified path needs more
// segments, not a faceted outline. Matches ComputeFlattenReference._transform.
float2 xform(uint path, float2 p) {
  float4 m = uTransforms[path * 2];
  float4 o = uTransforms[path * 2 + 1];
  return float2(m.x * p.x + m.z * p.y + o.x,
                m.y * p.x + m.w * p.y + o.y);
}

float toleranceOf(uint path) {
  return uTransforms[path * 2 + 1].z;
}

// a - 2 b + c, grouped exactly as ComputeFlattenReference._second groups it.
float2 secondDifference(float2 a, float2 b, float2 c) {
  return (a - 2.0 * b) + c;
}

// clamp(ceil(sqrt(ratio)), 1, kMaxSegmentsPerCurve), with the same two ends
// ComputeFlattenReference._segmentsForRatio takes: a ratio that is not > 0 -
// which includes NaN - is one segment, and an infinite ratio is the ceiling.
uint segmentsForRatio(float ratio) {
  if (!(ratio > 0.0)) return 1;
  if (isinf(ratio)) return kMaxSegmentsPerCurve;
  float n = ceil(sqrt(ratio));
  if (n < 1.0) return 1;
  if (n > float(kMaxSegmentsPerCurve)) return kMaxSegmentsPerCurve;
  return (uint)n;
}

uint curveSegmentCount(uint curve) {
  uint4 header = uCurves[curve];
  uint kind = header.x;
  if (kind == kLine) return 1;
  uint path = header.y;
  float tol = toleranceOf(path);
  float4 pa = uCurvePoints[curve * 2];
  float4 pb = uCurvePoints[curve * 2 + 1];
  float2 p0 = xform(path, pa.xy);
  float2 p1 = xform(path, pa.zw);
  float2 p2 = xform(path, pb.xy);
  if (kind == kQuadratic) {
    float2 dd = secondDifference(p0, p1, p2);
    float deviation = sqrt(dd.x * dd.x + dd.y * dd.y);
    return segmentsForRatio(deviation / (4.0 * tol));
  }
  float2 p3 = xform(path, pb.zw);
  float2 d0 = secondDifference(p0, p1, p2);
  float2 d1 = secondDifference(p1, p2, p3);
  float m0 = d0.x * d0.x + d0.y * d0.y;
  float m1 = d1.x * d1.x + d1.y * d1.y;
  // Not max(): the reference writes the conditional, and the two differ on NaN.
  float deviation = sqrt(m0 > m1 ? m0 : m1);
  return segmentsForRatio(3.0 * deviation / (4.0 * tol));
}

// The point at parameter index/total on a curve.
//
// The two endpoints are the encoded ones and not an evaluation at t = 0 or
// t = 1: those agree mathematically and can differ in the last bit, and a
// contour that closes to within one bit is a contour with a crack in it. It is
// also what makes segment j's end equal segment j+1's start exactly, since both
// threads evaluate the same expression at the same t.
float2 evalCurve(uint curve, uint index, uint total) {
  uint4 header = uCurves[curve];
  uint kind = header.x;
  uint path = header.y;
  float4 pa = uCurvePoints[curve * 2];
  float4 pb = uCurvePoints[curve * 2 + 1];
  float2 p0 = xform(path, pa.xy);
  float2 p3 = xform(path, pb.zw);
  if (index == 0) return p0;
  if (index >= total) return p3;
  if (kind == kLine) return p3;

  float t = float(index) / float(total);
  float u = 1.0 - t;
  float2 p1 = xform(path, pa.zw);
  float2 p2 = xform(path, pb.xy);
  if (kind == kQuadratic) {
    float uu = u * u;
    float ut2 = (2.0 * u) * t;
    float tt = t * t;
    return (uu * p0 + ut2 * p1) + tt * p2;
  }
  float uu = u * u;
  float uuu = uu * u;
  float tt = t * t;
  float ttt = tt * t;
  float uut3 = (3.0 * uu) * t;
  float utt3 = (3.0 * u) * tt;
  return ((uuu * p0 + uut3 * p1) + utt3 * p2) + ttt * p3;
}

[numthreads($kComputeFlattenGroupSize, 1, 1)]
void csCurveCounts(uint3 id : SV_DispatchThreadID) {
  uint curve = id.x;
  if (curve >= uCurveCount) return;
  uCounts[curve] = curveSegmentCount(curve);
}

${scanKernels(
  entryPoints: kComputeFlattenScanEntryPoints,
  elementCount: 'uCurveCount',
  blockCount: 'uBlockCount',
)}

[numthreads($kComputeFlattenGroupSize, 1, 1)]
void csEmitSegments(uint3 group : SV_GroupID, uint3 thread : SV_GroupThreadID) {
  uint curve = group.x;
  if (curve >= uCurveCount) return;
  uint total = uCounts[curve];
  uint first = uOffsets[curve];
  [loop]
  for (uint index = thread.x; index < total;
       index += $kComputeFlattenGroupSize) {
    uint slot = first + index;
    // Past the budget: write nothing. Clamping into the last slot would forge
    // a segment, and the executor detects the overflow from the total instead.
    if (slot >= uMaxSegments) continue;
    float2 a = evalCurve(curve, index, total);
    float2 b = evalCurve(curve, index + 1, total);
    uSegments[slot] = float4(a.x, a.y, b.x, b.y);
  }
}
''';

/// Checks the Dart-side constant contract against the source.
///
/// The same shape `validateD3d12ComputeTileShaderContract` has, and for the
/// same reason: a root constant renamed on one side of the seam and not the
/// other compiles, binds and produces a wrong picture.
void validateComputeFlattenShaderContract() {
  const List<String> names = <String>[
    'uCurveCount',
    'uBlockCount',
    'uMaxSegments',
    'uReserved',
  ];
  if (names.length != kComputeFlattenRootConstantCount) {
    throw StateError(
      'kComputeFlattenRootConstantCount does not match the declared block',
    );
  }
  for (final String name in names) {
    if (!kComputeFlattenShader.contains('  uint $name;')) {
      throw StateError('missing flatten root constant: $name');
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
  ]) {
    if (!kComputeFlattenShader.contains('register($register)')) {
      throw StateError('missing flatten resource register: $register');
    }
  }
  for (final String entryPoint in kComputeFlattenEntryPoints) {
    if (!kComputeFlattenShader.contains('void $entryPoint(')) {
      throw StateError('missing flatten entry point: $entryPoint');
    }
  }
  if (kComputeFlattenMaxCurves !=
      kComputeFlattenGroupSize * kComputeFlattenGroupSize) {
    throw StateError(
        'the two-level scan ceiling is not the group size squared');
  }
}
