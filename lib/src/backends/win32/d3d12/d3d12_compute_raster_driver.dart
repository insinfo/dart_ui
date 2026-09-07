/// Production Direct3D 12 adapter for the chained flatten, coarse-binning,
/// segment-binning and coverage pipeline.
///
/// The single-stage drivers next to this one each own a [D3d12ComputePass] and
/// call [D3d12ComputePass.run], which closes a command list and waits on a
/// fence because it ends in a readback the CPU maps. This one owns *all four*
/// passes and a [D3d12ComputeChain], and records every kernel chain into one
/// list.
///
/// Nothing about the stages is restated here. The pass, the buffer sizes and
/// the kernel chain of each come from `D3d12FlattenPass`, `D3d12BinningPass`,
/// `D3d12SegmentPass` and `D3d12CoveragePass`, which are the same functions the
/// single-stage drivers call - so a chained submission dispatches exactly what
/// an unchained one dispatches, and the parity oracle that proved one proves
/// the other.
///
/// What is genuinely different is the readback list. In the unchained shape
/// every stage reads back everything it produced, because that is what an
/// oracle needs. Here [ComputeRasterDriver.runRasterPass] reads back only when
/// asked, and a `readBack: false` submission copies nothing and waits for
/// nothing - which is the shape a frame path would use, and the shape that
/// separates the cost of submitting from the cost of waiting.
///
/// ## The one place a stage reads another stage's buffer
///
/// The segment stage is the pipeline's first real consumer: it needs the tile
/// index and the tile references the coarse stage wrote, and in a single
/// submission those never leave the device. So two of its read-write slots
/// are [D3d12ComputeAlias]es naming the coarse pass's own buffers, and nothing
/// is copied, transitioned or waited on between the two. `D3d12SegmentPass`
/// spells that binding, and the unchained driver next door spells the seeded
/// alternative, so both shapes dispatch the same kernels over the same
/// registers.
///
/// ## And the join that closes the chain on itself
///
/// Two more of its slots are the **flatten** pass's: the segment buffer and the
/// `firstSegment, segmentCount, material, fillRule` table `csDrawTable` builds
/// out of the flatten scan. With `joinFlatten` those are aliases too and all
/// the CPU uploads is one array of boxes; without it they are seeded from a
/// `ComputeTilePlan`, which is the shape every parity oracle here compares
/// against and the shape the benchmark's old rows were measured in.
///
/// The two spellings are the same pair of slots on purpose. Binding one of them
/// from each half is the failure
/// `RELATORIO_POC_23_GPU_2D_STRATEGIES_INTEL_UHD.md` names: a segment index
/// resolved through a table built for a different numbering finds an edge that
/// exists and belongs to another draw, so nothing throws and the picture is
/// wrong. [D3d12ComputeRasterDriver.runRasterPass] refuses the mixture by
/// argument rather than trusting two call sites to stay in step.
///
/// ## The coverage stage closes it, and consumes both producers
///
/// The fourth pass is the first that reads *two* earlier stages: `references`
/// and `commands` from the coarse pass, and `referenceSegments`,
/// `tileSegments` and `backdrops` from the segment pass, all five by alias - and
/// with `joinFlatten` a third, for the segment buffer and the draw table. With
/// it recorded, the binned scene never returns to the CPU on its way to
/// coverage, which is the whole of what `RASTERIZADOR_COMPUTE_D.md` listed as
/// missing for the pipeline.
///
/// It is optional for the same reason the segment stage is: the three-stage
/// shape is the measurement that document published, and a benchmark that can
/// no longer produce the old row cannot show what the new one changed.
library;

import 'dart:typed_data';

import '../../../rendering/gpu/compute/compute_curve_scene.dart';
import '../../../rendering/gpu/compute/compute_raster_pipeline.dart';
import '../../../rendering/gpu/compute/d3d12_compute_binning_executor.dart';
import '../../../rendering/gpu/compute/d3d12_compute_coverage_executor.dart';
import '../../../rendering/gpu/compute/d3d12_compute_flatten_executor.dart';
import '../../../rendering/gpu/compute/d3d12_compute_segment_executor.dart';
import 'd3d12_compute_binning_driver.dart';
import 'd3d12_compute_coverage_driver.dart';
import 'd3d12_compute_flatten_driver.dart';
import 'd3d12_compute_pass.dart';
import 'd3d12_compute_segment_driver.dart';
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
        _segments =
            D3d12SegmentPass.create(device, deviceZeroFill: deviceZeroFill),
        _coverage =
            D3d12CoveragePass.create(device, deviceZeroFill: deviceZeroFill),
        _chain = D3d12ComputeChain(device, label: 'raster');

  final D3d12ComputePass _flatten;
  final D3d12ComputePass _binning;
  final D3d12ComputePass _segments;
  final D3d12ComputePass _coverage;
  final D3d12ComputeChain _chain;

  bool get isBuilt =>
      _flatten.isBuilt &&
      _binning.isBuilt &&
      _segments.isBuilt &&
      _coverage.isBuilt;

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
    D3d12SegmentPass.assertSlotContract();
    D3d12CoveragePass.assertSlotContract();
    _flatten.build();
    _binning.build();
    _segments.build();
    _coverage.build();
    return _kRasterPipelineToken;
  }

  @override
  void disposeRasterPipeline(int pipeline) {
    if (pipeline != _kRasterPipelineToken) return;
    _flatten.release();
    _binning.release();
    _segments.release();
    _coverage.release();
    _chain.release();
  }

  @override
  void discardNativeResources() {
    _flatten.discard();
    _binning.discard();
    _segments.discard();
    _coverage.discard();
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
    ComputeSegmentScene? segmentScene,
    bool joinFlatten = false,
    Uint32List? segmentConstants,
    ComputeSegmentBinningDispatch? segmentDispatch,
    ComputeCoverageDispatch? coverageDispatch,
  }) {
    if (pipeline != _kRasterPipelineToken || !isBuilt) {
      throw StateError('the raster pipeline does not belong to this driver');
    }
    if (joinFlatten && segmentScene != null) {
      throw ArgumentError(
        'the segment table comes from the flatten stage or from a plan, never '
        'from both: a segment index resolved through the other half of the '
        'pipeline names an edge that exists and belongs to another draw',
      );
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
        // The draw table comes back only in the joined shape, and only because
        // it is the one number a caller cannot otherwise check: the segment
        // stage was dispatched over a *bound* on the widest draw, and a bound
        // that turned out too small drops segments through the kernel's own
        // guard without saying so.
        reads: readBack
            ? <int>[
                kD3d12FlattenCountsSlot,
                kD3d12FlattenOffsetsSlot,
                kD3d12FlattenSegmentsSlot,
                if (joinFlatten) kD3d12FlattenDrawsSlot,
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

    final bool runSegments = segmentScene != null || joinFlatten;
    // Null in the seeded shape, where this pass owns both buffers and the
    // sources list carries the plan's arrays instead.
    final D3d12ComputeAlias? aliasSegments = joinFlatten
        ? D3d12ComputeAlias(_flatten, kD3d12FlattenSegmentsSlot)
        : null;
    final D3d12ComputeAlias? aliasDraws = joinFlatten
        ? D3d12ComputeAlias(_flatten, kD3d12FlattenDrawsSlot)
        : null;

    if (runSegments) {
      if (segmentConstants == null || segmentDispatch == null) {
        throw ArgumentError(
          'a chained segment stage needs its own constants and dispatch',
        );
      }
      work.add(
        D3d12ComputeWork(
          _segments,
          rootConstants: segmentConstants,
          uploads: D3d12SegmentPass.uploads(bounds),
          uavBytes:
              D3d12SegmentPass.uavBytes(segmentDispatch, scene: segmentScene),
          stages: D3d12SegmentPass.stages(segmentDispatch),
          // Not a copy of the producers' output: their buffers, by address. A
          // copy would need them to have finished, and a fence is what this
          // pipeline exists to remove.
          uavSources: D3d12SegmentPass.sources(
            scene: segmentScene,
            aliasSegments: aliasSegments,
            aliasDraws: aliasDraws,
            aliasBins: D3d12ComputeAlias(_binning, kD3d12BinningBinsSlot),
            aliasReferences:
                D3d12ComputeAlias(_binning, kD3d12BinningReferencesSlot),
          ),
          reads: readBack ? D3d12SegmentPass.reads : const <int>[],
        ),
      );
    }

    if (coverageDispatch != null) {
      // Guarded rather than assumed: the coverage kernel indexes the segment
      // stage's three per-reference arrays, and without that stage in the list
      // they are this pass's own zeroed buffers - every reference would read an
      // empty run and every pixel would come back zero, which is a plausible
      // answer and therefore the worst kind of wrong.
      if (!runSegments) {
        throw ArgumentError(
          'a chained coverage stage reads what the segment stage produced; '
          'run it with a segment scene or not at all',
        );
      }
      work.add(
        D3d12ComputeWork(
          _coverage,
          rootConstants: coverageDispatch.rootConstants(),
          // The same box array the segment stage was handed, and the same
          // object: the two stages have to agree about which draw covers
          // where.
          uploads: D3d12CoveragePass.uploads(bounds),
          uavBytes:
              D3d12CoveragePass.uavBytes(coverageDispatch, scene: segmentScene),
          stages: D3d12CoveragePass.stages(coverageDispatch),
          // Seven buffers from three earlier passes, by address, or five of
          // them plus the plan's two seeded. Nothing is copied and nothing is
          // waited on: the UAV barrier the chain records between dispatches is
          // the whole of the ordering an aliased read needs.
          uavSources: D3d12CoveragePass.sources(
            scene: segmentScene,
            segments: aliasSegments,
            draws: aliasDraws,
            references:
                D3d12ComputeAlias(_binning, kD3d12BinningReferencesSlot),
            commands: D3d12ComputeAlias(_binning, kD3d12BinningCommandsSlot),
            referenceSegments:
                D3d12ComputeAlias(_segments, kD3d12SegmentRefSegmentsSlot),
            tileSegments:
                D3d12ComputeAlias(_segments, kD3d12SegmentTileSegmentsSlot),
            backdrops: D3d12ComputeAlias(_segments, kD3d12SegmentBackdropsSlot),
          ),
          reads: readBack ? D3d12CoveragePass.reads : const <int>[],
        ),
      );
    }

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
        draws: flat.length > 3
            ? Uint32List.view(flat[3].buffer, 0, flattenDispatch.pathCount * 4)
            : null,
      ),
      binning: ComputeBinningReadback(
        bins: Uint32List.view(bin[0].buffer, 0, tileCount * 2),
        references:
            Uint32List.view(bin[1].buffer, 0, binningDispatch.referenceBudget),
        commands: Uint32List.view(bin[2].buffer, 0, tileCount * 3),
        offsets: Uint32List.view(bin[3].buffer, 0, tileCount + 1),
      ),
      segments: segmentDispatch == null
          ? null
          : D3d12SegmentPass.readbackOf(back[2], segmentDispatch),
      // Positional, like every other index here: the coverage work item is
      // appended last, so it is the last readback whether or not the segment
      // stage was in front of it.
      coverage: coverageDispatch == null
          ? null
          : D3d12CoveragePass.resultOf(back.last, coverageDispatch),
    );
  }

  void dispose() {
    _flatten.dispose();
    _binning.dispose();
    _segments.dispose();
    _coverage.dispose();
    _chain.dispose();
  }

  /// Disposes after device removal, where releasing an object is undefined.
  void disposeAfterDeviceLoss() {
    _flatten.disposeAfterDeviceLoss();
    _binning.disposeAfterDeviceLoss();
    _segments.disposeAfterDeviceLoss();
    _chain.disposeAfterDeviceLoss();
  }
}
