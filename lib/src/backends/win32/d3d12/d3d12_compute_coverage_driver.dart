/// Production Direct3D 12 adapter for the chained coverage stage.
///
/// [D3d12ComputePass] owns everything generic - the root signature, the
/// pipeline state, the UAV barrier, the zero-fill, the grow-and-reuse of the
/// default-heap buffers and the sectioned readback. What is left here is the
/// buffer sizes, the one-link chain, and the thing that makes this stage
/// different from the three before it: **five of its six read-write slots are
/// inputs, and every one of them belongs to another pass.**
///
/// The coarse stage owns `references` and `commands`; the segment stage owns
/// `referenceSegments`, `tileSegments` and `backdrops`. In a chained submission
/// all five are still on the device when this kernel runs, so [sources] binds
/// them by address with [D3d12ComputeAlias] and copies nothing. There is no
/// unchained alternative spelling here, unlike `D3d12SegmentPass.sources`: a
/// coverage pass seeded with all five from the CPU is exactly
/// `ComputeTileD3d12Executor`, which already exists, is already proved against
/// `ComputeTileCpuReference`, and is what the parity test compares this
/// against.
///
/// ## The output slot is last, and that is load bearing
///
/// [D3d12ComputePass] zero-fills every slot whose source is not an alias, and
/// skips the ones that are. With the five borrowed slots first and the output
/// last, that rule zeroes exactly the buffer this pass writes and leaves the
/// five it reads alone - which is what the coverage layout needs, because a
/// pixel no tile references is never stored to and has to read back as zero.
library;

import 'dart:typed_data';

import '../../../rendering/gpu/compute/d3d12_compute_coverage_executor.dart';
import '../../../rendering/gpu/compute/d3d12_compute_coverage_shader.dart';
import '../../../rendering/gpu/compute/d3d12_compute_segment_executor.dart';
import 'd3d12_compute_pass.dart';
import 'd3d12_device.dart';

/// Read-write slots, in the order the root signature declares them.
const int kD3d12CoverageReferencesSlot = 0;
const int kD3d12CoverageCommandsSlot = 1;
const int kD3d12CoverageRefSegmentsSlot = 2;
const int kD3d12CoverageTileSegmentsSlot = 3;
const int kD3d12CoverageBackdropsSlot = 4;
const int kD3d12CoverageOutputSlot = 5;

/// The coverage stage's pass, its buffer sizes and its one-link chain.
///
/// See `D3d12FlattenPass`: the chained pipeline records the stage through these
/// functions so there is one place a dispatch size can be wrong.
abstract final class D3d12CoveragePass {
  static D3d12ComputePass create(D3d12RenderDevice device,
          {bool deviceZeroFill = true}) =>
      D3d12ComputePass(
        device,
        label: 'coverage',
        source: kComputeCoverageShader,
        entryPoints: kComputeCoverageEntryPoints,
        rootConstantCount: kComputeCoverageRootConstantCount,
        srvCount:
            kComputeCoverageLastSrvSlot - kComputeCoverageFirstSrvSlot + 1,
        uavCount:
            kComputeCoverageLastUavSlot - kComputeCoverageFirstUavSlot + 1,
        target: kComputeCoverageTarget,
        // Unlike the three stages before it, this one produces no integer that
        // indexes a later buffer: its output is a quantised coverage byte, and
        // the sample loop's arithmetic is the transcription of a CPU oracle
        // that is *also* free to contract. Asking for IEEE strictness would
        // therefore not make the comparison exact - the float32-versus-float64
        // gap that `d3d12_compute_tile_shader.dart` measures dominates it - and
        // would cost the same optimisations the tile shader is allowed, which
        // is the route this one has to be compared against.
        deviceZeroFill: deviceZeroFill,
      );

  /// The read-only uploads, in slot order.
  ///
  /// The same three arrays the segment stage uploads, and it must be the same
  /// object: the kernel indexes [ComputeSegmentScene.segments] through the
  /// `tileSegments` that stage built out of it.
  static List<TypedData> uploads(ComputeSegmentScene scene) => <TypedData>[
        scene.segments,
        scene.draws,
        scene.bounds,
      ];

  /// The read-write buffer sizes, in slot order.
  ///
  /// The five borrowed slots are zero: an aliased slot is neither allocated nor
  /// zeroed by this pass, so a size here would be a number with no consumer
  /// pretending to be a contract. Only the output is sized.
  static List<int> uavBytes(ComputeCoverageDispatch dispatch) => <int>[
        0,
        0,
        0,
        0,
        0,
        dispatch.coverageElements * 4,
      ];

  /// Where each read-write slot's contents come from: five producers' buffers
  /// and this pass's own output.
  static List<Object?> sources({
    required D3d12ComputeAlias references,
    required D3d12ComputeAlias commands,
    required D3d12ComputeAlias referenceSegments,
    required D3d12ComputeAlias tileSegments,
    required D3d12ComputeAlias backdrops,
  }) =>
      <Object?>[
        references,
        commands,
        referenceSegments,
        tileSegments,
        backdrops,
        null,
      ];

  /// The one-link chain: a thread group per command slot, sixteen by sixteen
  /// threads, one thread per pixel of the tile.
  static List<D3d12ComputeStage> stages(ComputeCoverageDispatch dispatch) =>
      <D3d12ComputeStage>[
        D3d12ComputeStage(
          ComputeCoverageKernel.coverage,
          dispatch.commandSlots,
        ),
      ];

  /// The slot a caller reads back.
  static const List<int> reads = <int>[kD3d12CoverageOutputSlot];

  /// Assembles a result from the buffer [reads] names.
  static ComputeCoverageResult resultOf(
    List<Uint8List> back,
    ComputeCoverageDispatch dispatch,
  ) =>
      ComputeCoverageResult(
        width: dispatch.width,
        height: dispatch.height,
        drawCount: dispatch.drawCount,
        sampleGrid: dispatch.sampleGrid,
        commandSlots: dispatch.commandSlots,
        values: Uint32List.view(back[0].buffer, 0, dispatch.coverageElements),
      );

  /// Asserts the shader's slot constants against the pass's slot numbering.
  ///
  /// The same assertion the other three stages carry, and it matters more here:
  /// every read-write slot but the last is bound to another pass's buffer, so a
  /// slot number off by one binds the wrong producer's array and reads
  /// plausible garbage rather than failing.
  static void assertSlotContract() {
    validateComputeCoverageShaderContract();
    const List<(int, int)> slots = <(int, int)>[
      (kComputeCoverageReferencesSlot, kD3d12CoverageReferencesSlot),
      (kComputeCoverageCommandsSlot, kD3d12CoverageCommandsSlot),
      (kComputeCoverageReferenceSegmentsSlot, kD3d12CoverageRefSegmentsSlot),
      (kComputeCoverageTileSegmentsSlot, kD3d12CoverageTileSegmentsSlot),
      (kComputeCoverageBackdropsSlot, kD3d12CoverageBackdropsSlot),
      (kComputeCoverageOutputSlot, kD3d12CoverageOutputSlot),
    ];
    for (final (int root, int uav) in slots) {
      if (root - kComputeCoverageFirstUavSlot != uav) {
        throw StateError('the coverage read-write slots are out of order');
      }
    }
    // The output must be the last slot, or the zero-fill rule this pass depends
    // on - zero what is not aliased - would zero a producer's buffer instead.
    if (kD3d12CoverageOutputSlot !=
        kComputeCoverageLastUavSlot - kComputeCoverageFirstUavSlot) {
      throw StateError('the coverage output is not the last read-write slot');
    }
  }
}
