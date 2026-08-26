/// Production Direct3D 12 adapter for the chained flatten + binning pipeline.
///
/// The two single-stage drivers next to this one each own a [D3d12ComputePass]
/// and call [D3d12ComputePass.run], which closes a command list and waits on a
/// fence because it ends in a readback the CPU maps. This one owns *both*
/// passes and a [D3d12ComputeChain], and records both kernel chains into one
/// list.
///
/// Nothing about the two stages is restated here. The pass, the buffer sizes
/// and the kernel chain of each come from `D3d12FlattenPass` and
/// `D3d12BinningPass`, which are the same functions the single-stage drivers
/// call - so a chained submission dispatches exactly what an unchained one
/// dispatches, and the parity oracle that proved one proves the other.
///
/// What is genuinely different is the readback list. In the unchained shape
/// every stage reads back everything it produced, because that is what an
/// oracle needs. Here [ComputeRasterDriver.runRasterPass] reads back only when
/// asked, and a `readBack: false` submission copies nothing and waits for
/// nothing - which is the shape a frame path would use, and the shape that
/// separates the cost of submitting from the cost of waiting.
library;

import 'dart:typed_data';

import '../../../rendering/gpu/compute/compute_curve_scene.dart';
import '../../../rendering/gpu/compute/compute_raster_pipeline.dart';
import '../../../rendering/gpu/compute/d3d12_compute_binning_executor.dart';
import '../../../rendering/gpu/compute/d3d12_compute_flatten_executor.dart';
import 'd3d12_compute_binning_driver.dart';
import 'd3d12_compute_flatten_driver.dart';
import 'd3d12_compute_pass.dart';
import 'd3d12_device.dart';

/// The token [D3d12ComputeRasterDriver.createRasterPipeline] returns.
const int _kRasterPipelineToken = 1;

/// Maps [ComputeRasterDriver] onto a [D3d12RenderDevice].
final class D3d12ComputeRasterDriver implements ComputeRasterDriver {
  /// [deviceZeroFill] is [D3d12ComputePass.deviceZeroFill], forwarded to both
  /// stages. Production leaves it true; the benchmark builds a second pipeline
  /// with it false so the two shapes can be measured against each other in one
  /// run rather than across two edits of this file.
  D3d12ComputeRasterDriver(D3d12RenderDevice device,
      {bool deviceZeroFill = true})
      : _flatten =
            D3d12FlattenPass.create(device, deviceZeroFill: deviceZeroFill),
        _binning =
            D3d12BinningPass.create(device, deviceZeroFill: deviceZeroFill),
        _chain = D3d12ComputeChain(device, label: 'raster');

  final D3d12ComputePass _flatten;
  final D3d12ComputePass _binning;
  final D3d12ComputeChain _chain;

  bool get isBuilt => _flatten.isBuilt && _binning.isBuilt;

  @override
  int get submissions => _chain.submissions;

  @override
  int get waits => _chain.waits;

  @override
  bool finish() => _chain.finish();

  @override
  int createRasterPipeline() {
    D3d12FlattenPass.assertSlotContract();
    D3d12BinningPass.assertSlotContract();
    _flatten.build();
    _binning.build();
    return _kRasterPipelineToken;
  }

  @override
  void disposeRasterPipeline(int pipeline) {
    if (pipeline != _kRasterPipelineToken) return;
    _flatten.release();
    _binning.release();
    _chain.release();
  }

  @override
  void discardNativeResources() {
    _flatten.discard();
    _binning.discard();
    _chain.discard();
  }

  @override
  ComputeRasterReadback? runRasterPass({
    required int pipeline,
    required ComputeCurveUpload scene,
    required Uint32List flattenConstants,
    required ComputeFlattenDispatch flattenDispatch,
    required Float32List bounds,
    required Uint32List binningConstants,
    required ComputeBinningDispatch binningDispatch,
    required bool readBack,
  }) {
    if (pipeline != _kRasterPipelineToken || !isBuilt) {
      throw StateError('the raster pipeline does not belong to this driver');
    }
    if (flattenDispatch.curveCount <= 0 ||
        flattenDispatch.segmentBudget <= 0 ||
        binningDispatch.drawGroups <= 0 ||
        binningDispatch.tileCount <= 0) {
      throw ArgumentError(
        'a chained pass needs curves, a segment budget, draws and tiles',
      );
    }

    final List<int> flattenBytes = D3d12FlattenPass.uavBytes(flattenDispatch);
    final List<int> binningBytes = D3d12BinningPass.uavBytes(binningDispatch);

    final List<D3d12ComputeWork> work = <D3d12ComputeWork>[
      D3d12ComputeWork(
        _flatten,
        rootConstants: flattenConstants,
        uploads: D3d12FlattenPass.uploads(scene),
        uavBytes: flattenBytes,
        stages: D3d12FlattenPass.stages(flattenDispatch),
        reads: readBack
            ? const <int>[
                kD3d12FlattenCountsSlot,
                kD3d12FlattenOffsetsSlot,
                kD3d12FlattenSegmentsSlot,
              ]
            : const <int>[],
      ),
      D3d12ComputeWork(
        _binning,
        rootConstants: binningConstants,
        uploads: <TypedData>[bounds],
        uavBytes: binningBytes,
        stages: D3d12BinningPass.stages(binningDispatch),
        reads: readBack
            ? const <int>[
                kD3d12BinningBinsSlot,
                kD3d12BinningReferencesSlot,
                kD3d12BinningCommandsSlot,
                kD3d12BinningOffsetsSlot,
              ]
            : const <int>[],
      ),
    ];

    if (!readBack) {
      // One list, no copies, no fence: nothing is read, so nothing has to have
      // finished. `ComputeRasterPipeline.finish` is where the wait went.
      _chain.submit(work);
      return null;
    }

    final List<List<Uint8List>> back = _chain.run(work);
    final List<Uint8List> flat = back[0];
    final List<Uint8List> bin = back[1];
    final int tileCount = binningDispatch.tileCount;
    return ComputeRasterReadback(
      flatten: ComputeFlattenReadback(
        counts: Uint32List.view(flat[0].buffer, 0, flattenDispatch.curveCount),
        offsets:
            Uint32List.view(flat[1].buffer, 0, flattenDispatch.curveCount + 1),
        segments: Float32List.view(
            flat[2].buffer, 0, flattenDispatch.segmentBudget * 4),
      ),
      binning: ComputeBinningReadback(
        bins: Uint32List.view(bin[0].buffer, 0, tileCount * 2),
        references:
            Uint32List.view(bin[1].buffer, 0, binningDispatch.referenceBudget),
        commands: Uint32List.view(bin[2].buffer, 0, tileCount * 3),
        offsets: Uint32List.view(bin[3].buffer, 0, tileCount + 1),
      ),
    );
  }

  void dispose() {
    _flatten.dispose();
    _binning.dispose();
    _chain.dispose();
  }

  /// Disposes after device removal, where releasing an object is undefined.
  void disposeAfterDeviceLoss() {
    _flatten.disposeAfterDeviceLoss();
    _binning.disposeAfterDeviceLoss();
    _chain.disposeAfterDeviceLoss();
  }
}
