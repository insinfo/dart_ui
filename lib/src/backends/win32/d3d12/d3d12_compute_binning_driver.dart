/// Production Direct3D 12 adapter for the GPU tile-binning stage.
///
/// [D3d12ComputePass] owns everything generic - the root signature, the
/// pipeline states, the UAV barrier between links, the zero-fill, the
/// grow-and-reuse of the default-heap buffers, the sectioned readback and the
/// fence wait. What is left here is the chain itself, and the chain is the
/// interesting part: **the three scan kernels are dispatched twice**, once over
/// the per-tile draw counts to build the CSR index and once over the per-tile
/// occupancy flags to compact the commands. `d3d12_compute_binning_shader.dart`
/// explains why the same three buffers can serve both.
library;

import 'dart:typed_data';

import '../../../rendering/gpu/compute/d3d12_compute_binning_executor.dart';
import '../../../rendering/gpu/compute/d3d12_compute_binning_shader.dart';
import 'd3d12_compute_pass.dart';
import 'd3d12_device.dart';

/// The token [D3d12ComputeBinningDriver.createBinningPipeline] returns.
const int _kBinningPipelineToken = 1;

/// Read-write slots, in the order the root signature declares them.
const int kD3d12BinningCountsSlot = 0;
const int kD3d12BinningOffsetsSlot = 1;
const int kD3d12BinningBlockSumsSlot = 2;
const int kD3d12BinningScratchSlot = 3;
const int kD3d12BinningReferencesSlot = 4;
const int kD3d12BinningBinsSlot = 5;
const int kD3d12BinningCommandsSlot = 6;

const int _kCountsSlot = kD3d12BinningCountsSlot;
const int _kOffsetsSlot = kD3d12BinningOffsetsSlot;
const int _kBlockSumsSlot = kD3d12BinningBlockSumsSlot;
const int _kScratchSlot = kD3d12BinningScratchSlot;
const int _kReferencesSlot = kD3d12BinningReferencesSlot;
const int _kBinsSlot = kD3d12BinningBinsSlot;
const int _kCommandsSlot = kD3d12BinningCommandsSlot;

/// The binning stage's pass, its buffer sizes and its kernel chain, once.
///
/// See `D3d12FlattenPass`: the chained pipeline records the same stage into a
/// shared command list, and a second copy of a twelve-link chain is a second
/// place for a dispatch size to be wrong.
abstract final class D3d12BinningPass {
  static D3d12ComputePass create(D3d12RenderDevice device,
          {bool deviceZeroFill = true}) =>
      D3d12ComputePass(
        device,
        label: 'binning',
        source: kComputeBinningShader,
        entryPoints: kComputeBinningEntryPoints,
        rootConstantCount: kComputeBinningRootConstantCount,
        srvCount: kComputeBinningLastSrvSlot - kComputeBinningFirstSrvSlot + 1,
        uavCount: kComputeBinningLastUavSlot - kComputeBinningFirstUavSlot + 1,
        target: kComputeBinningTarget,
        // The tile range is `floor(bounds.left / tileSize)`, and a division an
        // optimiser is free to reassociate can land on the other side of an
        // integer - which changes the length of every later tile's run.
        compileFlags: kD3d12CompileIeeeStrictness,
        deviceZeroFill: deviceZeroFill,
      );

  /// The read-write buffer sizes, in slot order.
  static List<int> uavBytes(ComputeBinningDispatch dispatch) {
    final int tileCount = dispatch.tileCount;
    final int referenceBytes = dispatch.referenceBudget * 4;
    return <int>[
      tileCount * 4,
      (tileCount + 1) * 4,
      (dispatch.blockCount + 1) * 4,
      referenceBytes,
      referenceBytes,
      tileCount * 8,
      tileCount * 12,
    ];
  }

  /// The twelve-link chain, including the three scan kernels dispatched twice.
  static List<D3d12ComputeStage> stages(ComputeBinningDispatch dispatch) =>
      <D3d12ComputeStage>[
        // Count the draws each tile touches, then turn the counts into a CSR
        // index with the first scan.
        D3d12ComputeStage(ComputeBinningKernel.tileCounts, dispatch.drawGroups),
        D3d12ComputeStage(ComputeBinningKernel.scanBlocks, dispatch.blockCount),
        const D3d12ComputeStage(ComputeBinningKernel.scanBlockSums, 1),
        D3d12ComputeStage(ComputeBinningKernel.scanApply, dispatch.applyGroups),
        D3d12ComputeStage(ComputeBinningKernel.buildBins, dispatch.tileGroups),
        // Place the references in whatever order the atomics hand out, then
        // sort each tile's run so the result does not depend on that order.
        D3d12ComputeStage(ComputeBinningKernel.scatter, dispatch.drawGroups),
        D3d12ComputeStage(ComputeBinningKernel.sort, dispatch.tileCount),
        // The second scan: over occupancy, to compact the command list.
        D3d12ComputeStage(ComputeBinningKernel.flags, dispatch.tileGroups),
        D3d12ComputeStage(ComputeBinningKernel.scanBlocks, dispatch.blockCount),
        const D3d12ComputeStage(ComputeBinningKernel.scanBlockSums, 1),
        D3d12ComputeStage(ComputeBinningKernel.scanApply, dispatch.applyGroups),
        D3d12ComputeStage(ComputeBinningKernel.commands, dispatch.tileGroups),
      ];

  /// Asserts the shader's slot constants against the pass's slot numbering.
  static void assertSlotContract() =>
      D3d12ComputeBinningDriver._assertSlotContract();
}

/// Maps [ComputeBinningDriver] onto a [D3d12RenderDevice].
final class D3d12ComputeBinningDriver implements ComputeBinningDriver {
  D3d12ComputeBinningDriver(D3d12RenderDevice device)
      : _pass = D3d12BinningPass.create(device);

  final D3d12ComputePass _pass;

  bool get isBuilt => _pass.isBuilt;

  @override
  int createBinningPipeline() {
    _assertSlotContract();
    _pass.build();
    return _kBinningPipelineToken;
  }

  @override
  void disposeBinningPipeline(int pipeline) {
    if (pipeline != _kBinningPipelineToken) return;
    _pass.release();
  }

  @override
  void discardNativeResources() => _pass.discard();

  @override
  ComputeBinningReadback runBinningPass({
    required int pipeline,
    required Float32List bounds,
    required Uint32List rootConstants,
    required ComputeBinningDispatch dispatch,
  }) {
    if (pipeline != _kBinningPipelineToken || !_pass.isBuilt) {
      throw StateError('the binning pipeline does not belong to this driver');
    }
    if (dispatch.drawGroups <= 0 || dispatch.tileCount <= 0) {
      throw ArgumentError('a binning pass needs draws and tiles');
    }

    final int tileCount = dispatch.tileCount;

    final List<Uint8List> back = _pass.run(
      rootConstants: rootConstants,
      uploads: <TypedData>[bounds],
      uavBytes: D3d12BinningPass.uavBytes(dispatch),
      stages: D3d12BinningPass.stages(dispatch),
      reads: <int>[
        _kBinsSlot,
        _kReferencesSlot,
        _kCommandsSlot,
        _kOffsetsSlot,
      ],
    );

    return ComputeBinningReadback(
      bins: Uint32List.view(back[0].buffer, 0, tileCount * 2),
      references: Uint32List.view(back[1].buffer, 0, dispatch.referenceBudget),
      commands: Uint32List.view(back[2].buffer, 0, tileCount * 3),
      offsets: Uint32List.view(back[3].buffer, 0, tileCount + 1),
    );
  }

  void dispose() => _pass.dispose();

  /// Disposes after device removal, where releasing an object is undefined.
  void disposeAfterDeviceLoss() => _pass.disposeAfterDeviceLoss();

  /// The shader's slot constants, restated as the pass's slot numbering.
  static void _assertSlotContract() {
    if (kComputeBinningRootConstantsSlot != 0 ||
        kComputeBinningFirstSrvSlot != 1 ||
        kComputeBinningFirstUavSlot != kComputeBinningLastSrvSlot + 1 ||
        kComputeBinningLastUavSlot + 1 != kComputeBinningRootParameterCount) {
      throw StateError(
        'the binning root-parameter numbering is not constants, SRVs, UAVs',
      );
    }
    const List<(int, int)> slots = <(int, int)>[
      (kComputeBinningCountsSlot, _kCountsSlot),
      (kComputeBinningOffsetsSlot, _kOffsetsSlot),
      (kComputeBinningBlockSumsSlot, _kBlockSumsSlot),
      (kComputeBinningScratchSlot, _kScratchSlot),
      (kComputeBinningReferencesSlot, _kReferencesSlot),
      (kComputeBinningBinsSlot, _kBinsSlot),
      (kComputeBinningCommandsSlot, _kCommandsSlot),
    ];
    for (final (int root, int uav) in slots) {
      if (root - kComputeBinningFirstUavSlot != uav) {
        throw StateError('the binning read-write slots are out of order');
      }
    }
  }
}
