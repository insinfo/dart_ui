/// Production Direct3D 12 adapter for the GPU segment-binning stage.
///
/// [D3d12ComputePass] owns everything generic - the root signature, the
/// pipeline states, the UAV barrier between links, the zero-fill, the
/// grow-and-reuse of the default-heap buffers, the sectioned readback and the
/// fence wait. What is left here is the chain, the buffer sizes, and the one
/// thing this stage has that the two before it do not: **two of its read-write
/// slots are inputs**.
///
/// `uBins` and `uReferences` are the coarse stage's output. In the chained
/// pipeline they are that pass's buffers, bound by address with
/// [D3d12ComputeAlias] and never copied; in the unchained oracle shape they are
/// this pass's own buffers, seeded from a `ComputeTilePlan`. [sources] is the
/// one function that spells the difference, so the two shapes dispatch
/// literally the same kernels over the same registers.
library;

import 'dart:typed_data';

import '../../../rendering/gpu/compute/d3d12_compute_segment_executor.dart';
import '../../../rendering/gpu/compute/d3d12_compute_segment_shader.dart';
import 'd3d12_compute_pass.dart';
import 'd3d12_device.dart';

/// The token [D3d12ComputeSegmentDriver.createSegmentPipeline] returns.
const int _kSegmentPipelineToken = 1;

/// Read-write slots, in the order the root signature declares them.
const int kD3d12SegmentBinsSlot = 0;
const int kD3d12SegmentReferencesSlot = 1;
const int kD3d12SegmentCountsSlot = 2;
const int kD3d12SegmentOffsetsSlot = 3;
const int kD3d12SegmentBlockSumsSlot = 4;
const int kD3d12SegmentScratchSlot = 5;
const int kD3d12SegmentTileSegmentsSlot = 6;
const int kD3d12SegmentRefSegmentsSlot = 7;
const int kD3d12SegmentBackdropsSlot = 8;

/// The segment stage's pass, its buffer sizes and its kernel chain, once.
///
/// See `D3d12FlattenPass`: the chained pipeline records the same stage into a
/// shared command list, and a second copy of an eight-link chain is a second
/// place for a dispatch size to be wrong.
abstract final class D3d12SegmentPass {
  static D3d12ComputePass create(D3d12RenderDevice device,
          {bool deviceZeroFill = true}) =>
      D3d12ComputePass(
        device,
        label: 'segments',
        source: kComputeSegmentShader,
        entryPoints: kComputeSegmentEntryPoints,
        rootConstantCount: kComputeSegmentRootConstantCount,
        srvCount: kComputeSegmentLastSrvSlot - kComputeSegmentFirstSrvSlot + 1,
        uavCount: kComputeSegmentLastUavSlot - kComputeSegmentFirstUavSlot + 1,
        target: kComputeSegmentTarget,
        // The column range of a segment is `floor(sxMin / tileSize)`, and a
        // division an optimiser is free to reassociate can land on the other
        // side of an integer - which changes the length of a reference's run
        // and, unlike a coordinate, cannot be off by a rounding.
        compileFlags: kD3d12CompileIeeeStrictness,
        deviceZeroFill: deviceZeroFill,
      );

  /// The read-only uploads, in slot order.
  static List<TypedData> uploads(ComputeSegmentScene scene) => <TypedData>[
        scene.segments,
        scene.draws,
        scene.bounds,
      ];

  /// The read-write buffer sizes, in slot order.
  ///
  /// The two borrowed slots are sized for the unchained shape, where they are
  /// this pass's own buffers holding a seeded copy. An aliased run ignores
  /// them: [D3d12ComputePass] neither allocates nor zeroes a slot whose source
  /// is a [D3d12ComputeAlias].
  static List<int> uavBytes(ComputeSegmentBinningDispatch dispatch) {
    final int slots = dispatch.referenceSlots;
    final int segmentBytes = dispatch.tileSegmentBudget * 4;
    return <int>[
      dispatch.tileCount * 8,
      slots * 4,
      slots * 4,
      (slots + 1) * 4,
      (dispatch.blockCount + 1) * 4,
      segmentBytes,
      segmentBytes,
      slots * 8,
      slots * 8,
    ];
  }

  /// Where each read-write slot's contents come from.
  ///
  /// [bins] and [references] seed the two borrowed slots from the CPU;
  /// [aliasBins] and [aliasReferences] bind them to another pass's buffers
  /// instead. Exactly one of each pair is given.
  static List<Object?> sources({
    Uint32List? bins,
    Uint32List? references,
    D3d12ComputeAlias? aliasBins,
    D3d12ComputeAlias? aliasReferences,
  }) =>
      <Object?>[
        aliasBins ?? bins,
        aliasReferences ?? references,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
      ];

  /// The eight-link chain.
  static List<D3d12ComputeStage> stages(
    ComputeSegmentBinningDispatch dispatch,
  ) =>
      <D3d12ComputeStage>[
        // One thread per (draw, segment): count the references each segment
        // lands in and accumulate the backdrop difference array.
        D3d12ComputeStage(
          ComputeSegmentKernel.counts,
          dispatch.segmentGroups,
          groupsY: dispatch.drawCount,
        ),
        // Turn the counts into a CSR index over the reference slots.
        D3d12ComputeStage(ComputeSegmentKernel.scanBlocks, dispatch.blockCount),
        const D3d12ComputeStage(ComputeSegmentKernel.scanBlockSums, 1),
        D3d12ComputeStage(ComputeSegmentKernel.scanApply, dispatch.applyGroups),
        D3d12ComputeStage(ComputeSegmentKernel.build, dispatch.referenceGroups),
        // Place the segments in whatever order the atomics hand out, then sort
        // each run so the result does not depend on that order.
        D3d12ComputeStage(
          ComputeSegmentKernel.scatter,
          dispatch.segmentGroups,
          groupsY: dispatch.drawCount,
        ),
        if (dispatch.sortPerThread)
          D3d12ComputeStage(
              ComputeSegmentKernel.sort, dispatch.referenceGroups)
        else
          D3d12ComputeStage(
              ComputeSegmentKernel.sortWide, dispatch.referenceSlots),
        // One thread per (draw, tile row): prefix-sum the difference array the
        // first kernel left in the backdrop buffer.
        D3d12ComputeStage(
          ComputeSegmentKernel.backdrop,
          dispatch.rowGroups,
          groupsY: dispatch.drawCount,
        ),
      ];

  /// The slots a caller reads back, in the order
  /// [ComputeSegmentBinningReadback] names them.
  static const List<int> reads = <int>[
    kD3d12SegmentRefSegmentsSlot,
    kD3d12SegmentTileSegmentsSlot,
    kD3d12SegmentBackdropsSlot,
    kD3d12SegmentOffsetsSlot,
  ];

  /// Assembles a readback from the four buffers [reads] names.
  static ComputeSegmentBinningReadback readbackOf(
    List<Uint8List> back,
    ComputeSegmentBinningDispatch dispatch,
  ) {
    final int slots = dispatch.referenceSlots;
    return ComputeSegmentBinningReadback(
      referenceSegments: Uint32List.view(back[0].buffer, 0, slots * 2),
      tileSegments:
          Uint32List.view(back[1].buffer, 0, dispatch.tileSegmentBudget),
      backdrops: Int32List.view(back[2].buffer, 0, slots * 2),
      offsets: Uint32List.view(back[3].buffer, 0, slots + 1),
    );
  }

  /// Asserts the shader's slot constants against the pass's slot numbering.
  static void assertSlotContract() =>
      D3d12ComputeSegmentDriver._assertSlotContract();
}

/// Maps [ComputeSegmentBinningDriver] onto a [D3d12RenderDevice].
final class D3d12ComputeSegmentDriver implements ComputeSegmentBinningDriver {
  D3d12ComputeSegmentDriver(D3d12RenderDevice device)
      : _pass = D3d12SegmentPass.create(device);

  /// The shader's own name for the group-per-reference sort, for a caller that
  /// wants to name what it is measuring.
  static const String wideSortEntryPoint = kComputeSegmentSortWideEntryPoint;

  final D3d12ComputePass _pass;

  bool get isBuilt => _pass.isBuilt;

  @override
  int createSegmentPipeline() {
    _assertSlotContract();
    _pass.build();
    return _kSegmentPipelineToken;
  }

  @override
  void disposeSegmentPipeline(int pipeline) {
    if (pipeline != _kSegmentPipelineToken) return;
    _pass.release();
  }

  @override
  void discardNativeResources() => _pass.discard();

  @override
  ComputeSegmentBinningReadback runSegmentPass({
    required int pipeline,
    required ComputeSegmentScene scene,
    required Uint32List bins,
    required Uint32List references,
    required Uint32List rootConstants,
    required ComputeSegmentBinningDispatch dispatch,
  }) {
    if (pipeline != _kSegmentPipelineToken || !_pass.isBuilt) {
      throw StateError('the segment pipeline does not belong to this driver');
    }
    if (dispatch.drawCount <= 0 || dispatch.referenceSlots <= 0) {
      throw ArgumentError('a segment pass needs draws and reference slots');
    }

    final List<Uint8List> back = _pass.run(
      rootConstants: rootConstants,
      uploads: D3d12SegmentPass.uploads(scene),
      uavBytes: D3d12SegmentPass.uavBytes(dispatch),
      stages: D3d12SegmentPass.stages(dispatch),
      reads: D3d12SegmentPass.reads,
      uavSources: D3d12SegmentPass.sources(bins: bins, references: references),
    );
    return D3d12SegmentPass.readbackOf(back, dispatch);
  }

  void dispose() => _pass.dispose();

  /// Disposes after device removal, where releasing an object is undefined.
  void disposeAfterDeviceLoss() => _pass.disposeAfterDeviceLoss();

  /// The shader's slot constants, restated as the pass's slot numbering.
  static void _assertSlotContract() {
    validateComputeSegmentShaderContract();
    const List<(int, int)> slots = <(int, int)>[
      (kComputeSegmentBinsSlot, kD3d12SegmentBinsSlot),
      (kComputeSegmentReferencesSlot, kD3d12SegmentReferencesSlot),
      (kComputeSegmentCountsSlot, kD3d12SegmentCountsSlot),
      (kComputeSegmentOffsetsSlot, kD3d12SegmentOffsetsSlot),
      (kComputeSegmentBlockSumsSlot, kD3d12SegmentBlockSumsSlot),
      (kComputeSegmentScratchSlot, kD3d12SegmentScratchSlot),
      (kComputeSegmentTileSegmentsSlot, kD3d12SegmentTileSegmentsSlot),
      (kComputeSegmentRefSegmentsSlot, kD3d12SegmentRefSegmentsSlot),
      (kComputeSegmentBackdropsSlot, kD3d12SegmentBackdropsSlot),
    ];
    for (final (int root, int uav) in slots) {
      if (root - kComputeSegmentFirstUavSlot != uav) {
        throw StateError('the segment read-write slots are out of order');
      }
    }
  }
}
