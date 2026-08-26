/// Production Direct3D 12 adapter for the GPU flatten stage.
///
/// Everything a compute chain needs from Direct3D - the root signature, the
/// five pipeline states, the UAV barrier between links, the zero-fill, the
/// grow-and-reuse of the default-heap buffers, the sectioned readback and the
/// fence wait - is in [D3d12ComputePass]. What is left here is the mapping
/// between that and [ComputeFlattenDriver]: which buffer is which slot, how big
/// each one is for this dispatch, and which of them come back.
///
/// The layout is fixed by `d3d12_compute_flatten_shader.dart` and restated in
/// terms of the pass's slot numbering, which is the one place the two could
/// drift apart - so the constants are asserted against each other in
/// [D3d12ComputeFlattenDriver.createFlattenPipeline] rather than trusted.
library;

import 'dart:typed_data';

import '../../../rendering/gpu/compute/compute_curve_scene.dart';
import '../../../rendering/gpu/compute/d3d12_compute_flatten_executor.dart';
import '../../../rendering/gpu/compute/d3d12_compute_flatten_shader.dart';
import 'd3d12_compute_pass.dart';
import 'd3d12_device.dart';

/// The token [D3d12ComputeFlattenDriver.createFlattenPipeline] returns.
const int _kFlattenPipelineToken = 1;

/// Read-write slots, in the order the root signature declares them.
const int kD3d12FlattenCountsSlot = 0;
const int kD3d12FlattenOffsetsSlot = 1;
const int kD3d12FlattenBlockSumsSlot = 2;
const int kD3d12FlattenSegmentsSlot = 3;

const int _kCountsSlot = kD3d12FlattenCountsSlot;
const int _kOffsetsSlot = kD3d12FlattenOffsetsSlot;
const int _kBlockSumsSlot = kD3d12FlattenBlockSumsSlot;
const int _kSegmentsSlot = kD3d12FlattenSegmentsSlot;

/// The flatten stage's pass, its buffer sizes and its kernel chain, stated once.
///
/// Three functions rather than three literals inside [runFlattenPass], because
/// the chained pipeline records the *same* stage into a shared command list. A
/// second copy of the chain there would be a second place for a dispatch size
/// to be wrong, and the two would disagree only under load.
abstract final class D3d12FlattenPass {
  static D3d12ComputePass create(D3d12RenderDevice device,
          {bool deviceZeroFill = true}) =>
      D3d12ComputePass(
        device,
        label: 'flatten',
        source: kComputeFlattenShader,
        entryPoints: kComputeFlattenEntryPoints,
        rootConstantCount: kComputeFlattenRootConstantCount,
        srvCount: kComputeFlattenLastSrvSlot - kComputeFlattenFirstSrvSlot + 1,
        uavCount: kComputeFlattenLastUavSlot - kComputeFlattenFirstUavSlot + 1,
        target: kComputeFlattenTarget,
        // The flatten stage's first output is an integer segment count derived
        // from `ceil(sqrt(...))`; see the constant.
        compileFlags: kD3d12CompileIeeeStrictness,
        deviceZeroFill: deviceZeroFill,
      );

  /// The read-write buffer sizes, in slot order.
  static List<int> uavBytes(ComputeFlattenDispatch dispatch) => <int>[
        dispatch.curveCount * 4,
        (dispatch.curveCount + 1) * 4,
        (dispatch.blockCount + 1) * 4,
        dispatch.segmentBudget * 16,
      ];

  /// The three read-only buffers, in slot order.
  static List<TypedData> uploads(ComputeCurveUpload scene) => <TypedData>[
        scene.curves,
        scene.curvePoints,
        scene.transforms,
      ];

  /// The chain. Every arrow between two of these is a write one kernel makes
  /// and the next reads, so every arrow is a barrier - which the pass records
  /// after each stage.
  static List<D3d12ComputeStage> stages(ComputeFlattenDispatch dispatch) =>
      <D3d12ComputeStage>[
        D3d12ComputeStage(0, dispatch.blockCount), // csCurveCounts
        D3d12ComputeStage(1, dispatch.blockCount), // csScanBlocks
        const D3d12ComputeStage(2, 1), // csScanBlockSums
        D3d12ComputeStage(3, dispatch.applyGroups), // csScanApply
        D3d12ComputeStage(4, dispatch.curveCount), // csEmitSegments
      ];

  /// Asserts the shader's slot constants against the pass's slot numbering.
  static void assertSlotContract() =>
      D3d12ComputeFlattenDriver._assertSlotContract();
}

/// Maps [ComputeFlattenDriver] onto a [D3d12RenderDevice].
final class D3d12ComputeFlattenDriver implements ComputeFlattenDriver {
  D3d12ComputeFlattenDriver(D3d12RenderDevice device)
      : _pass = D3d12FlattenPass.create(device);

  final D3d12ComputePass _pass;

  bool get isBuilt => _pass.isBuilt;

  @override
  int createFlattenPipeline() {
    _assertSlotContract();
    _pass.build();
    return _kFlattenPipelineToken;
  }

  @override
  void disposeFlattenPipeline(int pipeline) {
    if (pipeline != _kFlattenPipelineToken) return;
    _pass.release();
  }

  @override
  void discardNativeResources() => _pass.discard();

  @override
  ComputeFlattenReadback runFlattenPass({
    required int pipeline,
    required ComputeCurveUpload scene,
    required Uint32List rootConstants,
    required ComputeFlattenDispatch dispatch,
  }) {
    if (pipeline != _kFlattenPipelineToken || !_pass.isBuilt) {
      throw StateError('the flatten pipeline does not belong to this driver');
    }
    if (dispatch.curveCount <= 0 || dispatch.segmentBudget <= 0) {
      throw ArgumentError('a flatten pass needs curves and a segment budget');
    }

    final List<Uint8List> back = _pass.run(
      rootConstants: rootConstants,
      uploads: D3d12FlattenPass.uploads(scene),
      uavBytes: D3d12FlattenPass.uavBytes(dispatch),
      stages: D3d12FlattenPass.stages(dispatch),
      reads: <int>[_kCountsSlot, _kOffsetsSlot, _kSegmentsSlot],
    );

    return ComputeFlattenReadback(
      counts: Uint32List.view(back[0].buffer, 0, dispatch.curveCount),
      offsets: Uint32List.view(back[1].buffer, 0, dispatch.curveCount + 1),
      segments: Float32List.view(back[2].buffer, 0, dispatch.segmentBudget * 4),
    );
  }

  void dispose() => _pass.dispose();

  /// Disposes after device removal, where releasing an object is undefined.
  void disposeAfterDeviceLoss() => _pass.disposeAfterDeviceLoss();

  /// The shader's slot constants, restated as the pass's slot numbering.
  ///
  /// [D3d12ComputePass] numbers root parameters `0` for the constants, then the
  /// SRVs, then the UAVs. The shader header numbers them the same way, and this
  /// is the assertion that says so out loud instead of leaving two independent
  /// orderings to agree by habit.
  static void _assertSlotContract() {
    if (kComputeFlattenRootConstantsSlot != 0 ||
        kComputeFlattenFirstSrvSlot != 1 ||
        kComputeFlattenFirstUavSlot != kComputeFlattenLastSrvSlot + 1 ||
        kComputeFlattenLastUavSlot + 1 != kComputeFlattenRootParameterCount) {
      throw StateError(
        'the flatten root-parameter numbering is not constants, SRVs, UAVs',
      );
    }
    if (kComputeFlattenCountsSlot - kComputeFlattenFirstUavSlot !=
            _kCountsSlot ||
        kComputeFlattenOffsetsSlot - kComputeFlattenFirstUavSlot !=
            _kOffsetsSlot ||
        kComputeFlattenBlockSumsSlot - kComputeFlattenFirstUavSlot !=
            _kBlockSumsSlot ||
        kComputeFlattenSegmentsSlot - kComputeFlattenFirstUavSlot !=
            _kSegmentsSlot) {
      throw StateError('the flatten read-write slots are out of order');
    }
  }
}
