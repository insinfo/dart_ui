/// The exclusive prefix sum every stage of a compute rasterizer is built on,
/// in HLSL and in Dart.
///
/// ## Why a scan is the load-bearing primitive
///
/// A GPU rasterizer of this shape produces variable-length output from
/// fixed-length input over and over: a curve becomes `n` segments, a draw
/// becomes `k` tile references, a tile grid becomes a list of *occupied* tiles.
/// In every one of those, the thread that produces element `i` has to know
/// where element `i` goes, and that position is a sum over everything before
/// it - which no single thread has.
///
/// An append buffer would sidestep it. It would also make the output order
/// depend on which thread group happened to retire first, and a buffer whose
/// contents differ between two runs of the same scene cannot be compared with
/// a CPU oracle at all. The scan is what buys determinism, and determinism is
/// what makes the rest of approach D checkable.
///
/// ## Two levels, and that is a stated ceiling
///
/// [scanKernels] emits the textbook two-level scan: a block-local Hillis-Steele
/// scan of [kComputeScanGroupSize] elements per group, one group that scans the
/// per-block totals, and a pass that adds each block's offset back. One group
/// scans at most [kComputeScanGroupSize] block sums, so the whole thing handles
/// [kComputeScanMaxElements] elements and no more. A third level is the
/// extension; inventing it before a scene needs it would be inventing its
/// requirements too. Every caller refuses a larger input **by name** instead of
/// producing a wrong prefix sum.
///
/// ## One text, two consumers
///
/// The kernels are generated rather than written twice because the flatten and
/// binning stages scan different things and would otherwise carry two copies of
/// the same barrier discipline - and a barrier bug in one copy is a race that
/// produces a plausible wrong answer in only one of the two stages.
///
/// The generated code assumes three read-write buffers named `uCounts`,
/// `uOffsets` and `uBlockSums`, and one uniform naming the element count. A
/// caller declares all four; [scanKernels] writes only the arithmetic - and
/// therefore emits `gScan` and `scanShared` under fixed names, so one
/// compilation unit gets one generated scan. A pass that needs to scan two
/// different things runs the same three kernels twice over the same buffers;
/// `d3d12_compute_binning_shader.dart` does exactly that.
library;

import 'dart:typed_data';

/// Threads per group, and therefore the scan's radix.
///
/// 256 rather than 1024: a Hillis-Steele scan does `log2(n)` barriers over
/// groupshared memory, and the Intel UHD in `RELATORIO_POC_23` reports 32 KiB
/// of shared memory per group, so the array costs 1 KiB and leaves room for a
/// future fused stage.
const int kComputeScanGroupSize = 256;

/// The most elements a two-level scan can handle.
const int kComputeScanMaxElements =
    kComputeScanGroupSize * kComputeScanGroupSize;

/// Thread groups needed to cover [elements] at [kComputeScanGroupSize] each.
int computeScanGroups(int elements) =>
    (elements + kComputeScanGroupSize - 1) ~/ kComputeScanGroupSize;

/// `D3D12_CS_DISPATCH_MAX_THREAD_GROUPS_PER_DIMENSION`.
///
/// Here rather than in a backend file because it binds the *stages*, not the
/// API: several of them dispatch one group per element - one per curve, one per
/// tile - so it is a second ceiling next to [kComputeScanMaxElements], and it is
/// one lower. A stage that exceeded it would be told by the runtime, at the
/// dispatch, with no way to attribute it to a scene; every executor here refuses
/// by name instead. Vulkan's `maxComputeWorkGroupCount` is at least this on any
/// device that could run these kernels, so a port inherits the same number.
const int kComputeMaxDispatchGroups = 65535;

/// The names of the three kernels [scanKernels] emits, in dispatch order.
final class ComputeScanEntryPoints {
  const ComputeScanEntryPoints(this.prefix);

  /// Prepended to each name, so two scans in one compilation unit do not
  /// collide.
  final String prefix;

  String get blocks => '${prefix}ScanBlocks';
  String get blockSums => '${prefix}ScanBlockSums';
  String get apply => '${prefix}ScanApply';

  List<String> get all => <String>[blocks, blockSums, apply];
}

/// The three scan kernels, over `uCounts` into `uOffsets`.
///
/// [elementCount] is the name of the uniform holding how many elements to scan;
/// [blockCount] names how many blocks that is. `uOffsets` must hold
/// `elementCount + 1` entries: the last one receives the grand total, so a
/// consumer reads element `i`'s count as `offsets[i + 1] - offsets[i]` with no
/// special case at the end. `uBlockSums` must hold `blockCount + 1`.
String scanKernels({
  required ComputeScanEntryPoints entryPoints,
  required String elementCount,
  required String blockCount,
}) =>
    '''
groupshared uint gScan[$kComputeScanGroupSize];

// An inclusive Hillis-Steele scan of gScan, left where every thread can read
// its own element. Two barriers per step because the read and the write touch
// the same array: without the first, a fast lane overwrites a slot a slow one
// has not read yet - a race that produces a plausible wrong answer.
void scanShared(uint lane) {
  [loop]
  for (uint offset = 1; offset < $kComputeScanGroupSize; offset <<= 1) {
    uint addend = (lane >= offset) ? gScan[lane - offset] : 0;
    GroupMemoryBarrierWithGroupSync();
    gScan[lane] += addend;
    GroupMemoryBarrierWithGroupSync();
  }
}

[numthreads($kComputeScanGroupSize, 1, 1)]
void ${entryPoints.blocks}(uint3 group : SV_GroupID,
                           uint3 thread : SV_GroupThreadID) {
  uint lane = thread.x;
  uint index = group.x * $kComputeScanGroupSize + lane;
  uint value = (index < $elementCount) ? uCounts[index] : 0;
  gScan[lane] = value;
  GroupMemoryBarrierWithGroupSync();
  scanShared(lane);
  uint inclusive = gScan[lane];
  if (index < $elementCount) uOffsets[index] = inclusive - value;
  if (lane == $kComputeScanGroupSize - 1) uBlockSums[group.x] = inclusive;
}

[numthreads($kComputeScanGroupSize, 1, 1)]
void ${entryPoints.blockSums}(uint3 thread : SV_GroupThreadID) {
  uint lane = thread.x;
  uint value = (lane < $blockCount) ? uBlockSums[lane] : 0;
  gScan[lane] = value;
  GroupMemoryBarrierWithGroupSync();
  scanShared(lane);
  uint inclusive = gScan[lane];
  // Every read of uBlockSums happened before the first barrier, so writing it
  // back here cannot be seen by a lane that has not read its own element.
  if (lane < $blockCount) uBlockSums[lane] = inclusive - value;
  if (lane == $blockCount - 1) uBlockSums[$blockCount] = inclusive;
}

[numthreads($kComputeScanGroupSize, 1, 1)]
void ${entryPoints.apply}(uint3 id : SV_DispatchThreadID) {
  uint index = id.x;
  if (index > $elementCount) return;
  if (index == $elementCount) {
    uOffsets[index] = uBlockSums[$blockCount];
    return;
  }
  uOffsets[index] += uBlockSums[index / $kComputeScanGroupSize];
}
''';

/// The exclusive prefix sum, with the grand total appended.
///
/// The definition [scanKernels] implements, in the form a test compares
/// against: `result.length == counts.length + 1`, `result[0] == 0`, and
/// `result[i + 1] - result[i] == counts[i]`.
Uint32List computeExclusiveScan(Uint32List counts) {
  final Uint32List result = Uint32List(counts.length + 1);
  var running = 0;
  for (var i = 0; i < counts.length; i++) {
    result[i] = running;
    running += counts[i];
  }
  result[counts.length] = running;
  return result;
}

/// Checks that a generated scan declares what a caller has to bind.
void validateComputeScanContract(String source, ComputeScanEntryPoints names) {
  for (final String entryPoint in names.all) {
    if (!source.contains('void $entryPoint(')) {
      throw StateError('missing scan entry point: $entryPoint');
    }
  }
  for (final String buffer in <String>['uCounts', 'uOffsets', 'uBlockSums']) {
    if (!source.contains(buffer)) {
      throw StateError('the scan needs a buffer named $buffer');
    }
  }
  if (kComputeScanMaxElements !=
      kComputeScanGroupSize * kComputeScanGroupSize) {
    throw StateError(
        'the two-level scan ceiling is not the group size squared');
  }
}
