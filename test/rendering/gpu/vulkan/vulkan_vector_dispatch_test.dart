/// A real display list reaching the Vulkan sparse executor through the
/// selector, and coming back with the CPU's pixels.
///
/// `vulkan_sparse_parity_test.dart` hands the executor a plan directly, which
/// proves the shaders and the submission. This file proves the part in
/// between: that `GpuRasterSink` proposes the route, that
/// `VulkanVectorPathRecorder` commits a complete command without touching the
/// device, that the ordered walk in `VulkanOffscreenTarget` issues dense
/// batches and promoted paths in display-list order, and that every refusal
/// puts the draw back on the dense atlas with the picture unchanged.
///
/// ## Why the ordering scenes are the point
///
/// A submitter that issued every dense batch and then every vector command
/// would still draw a picture, and on most scenes it would look right. It is
/// wrong only where the two overlap - which is why the scenes below overlap on
/// purpose, and why the assertion is against the CPU rather than against a
/// remembered image.
///
/// On Vulkan the interleave costs render passes: the coverage pages of a
/// promoted draw are copied with `vkCmdCopyBufferToImage`, which cannot be
/// recorded inside a render pass, so each boundary ends the dense pass and
/// opens a loading one after. A frame with nothing promoted still records
/// exactly one pass, and the "production path is untouched" group is what
/// holds that true.
///
/// ## Tolerance
///
/// **Zero on every scene here**, measured on Intel(R) UHD Graphics, Vulkan
/// 1.4.323, driver 0x195bb0. Every scene is solid-paint: the coverage byte the
/// shader reads is the byte `ScanlineFiller` computed, and the dense atlas
/// route this file compares against reads the same byte. A gradient would be
/// the one level `vulkan_sparse_parity_test.dart` declares, and gradients do
/// not reach this route at all - see `vulkan_vector_path_recorder.dart`.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/transform2d.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/graphics/gradient.dart';
import 'package:dart_ui/src/rendering/cpu_renderer.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_path_dispatch.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_path_planning.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_path_strategy.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_backend.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_sparse_executor.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_vector_path_recorder.dart';
import 'package:dart_ui/src/rendering/path/fill_rule.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:dart_ui/src/rendering/replay/display_list_player.dart';
import 'package:test/test.dart';

import 'vulkan_session.dart';

const int _size = 64;
const int _clear = 0xFF000000;

void main() {
  final VulkanSession session = VulkanSession.open(validation: true);
  VulkanRenderDevice? device;
  String? skip = session.skipReason;

  setUpAll(() {
    if (skip != null) return;
    try {
      device = VulkanRenderDevice.adoptInstance(
        session.instance!,
        enableExperimentalSparseStrips: true,
      );
    } on BackendSelectionError catch (error) {
      skip = 'no Vulkan render device: $error';
    }
  });
  tearDownAll(() {
    device?.dispose();
    session.close();
  });

  group('a display list reaches the sparse executor through the selector', () {
    test('a large antialiased path is promoted, and matches the CPU', () async {
      if (_skipped(skip)) return;
      final _Run run = await _render(device!, _thinDiagonal());
      expect(run.executed, GpuPathStrategy.sparseStrips,
          reason: 'the selector chose ${run.candidate} and the recorder '
              'reported ${run.executed}; the scene was chosen because sparse '
              'strips beat the dense mask on it');
      expect(run.recorder.acceptedCount, 1);
      expect(run.stats, isNotNull);
      expect(run.stats!.drawCalls, greaterThan(0));
      _expectParity(run, tolerance: 0);
    });

    test('a promoted path composites under the dense batch after it: 0',
        () async {
      if (_skipped(skip)) return;
      // The ordering assertion, and the reason `_recordOrdered` exists: the
      // rectangle is drawn *after* the path in the display list and overlaps
      // it, so a submitter that issued every dense batch before every vector
      // command would put the path on top - and the picture would still look
      // like a picture.
      final DisplayList list = DisplayList();
      final int ink = list.addPaint(colorArgb: 0xFFCC3311);
      final int cover = list.addPaint(colorArgb: 0xFF1133CC, antiAlias: false);
      list
        ..drawPath(list.addPath(_thinDiagonalPath()), ink)
        ..drawRect(20, 20, 44, 44, cover);

      final _Run run = await _render(device!, list);
      expect(run.executed, GpuPathStrategy.sparseStrips);
      expect(run.recorder.acceptedCount, 1);
      // The overlap really is opaque blue on both sides, which is what makes
      // the order observable at all.
      expect(_rgba(run.cpu, 32, 32), <int>[0x11, 0x33, 0xCC, 0xFF]);
      _expectParity(run, tolerance: 0);
    });

    test('a dense batch before a promoted path stays under it: 0', () async {
      if (_skipped(skip)) return;
      // The mirror image, and the case that catches the other mistake: a
      // clear performed after the first vector command instead of before it,
      // or a dense range issued at the wrong boundary, would erase the
      // rectangle rather than let the path draw over it.
      final DisplayList list = DisplayList();
      final int cover = list.addPaint(colorArgb: 0xFF1133CC, antiAlias: false);
      final int ink = list.addPaint(colorArgb: 0xFFCC3311);
      list
        ..drawRect(20, 20, 44, 44, cover)
        ..drawPath(list.addPath(_thinDiagonalPath()), ink);

      final _Run run = await _render(device!, list);
      expect(run.executed, GpuPathStrategy.sparseStrips);
      expect(run.recorder.acceptedCount, 1);
      _expectParity(run, tolerance: 0);
    });

    test('two promoted paths keep their relative order: 0', () async {
      if (_skipped(skip)) return;
      final DisplayList list = DisplayList();
      final int first = list.addPaint(colorArgb: 0xFFCC3311);
      final int second = list.addPaint(colorArgb: 0xFF11CC33);
      list
        ..drawPath(list.addPath(_thinDiagonalPath()), first)
        ..drawPath(list.addPath(_thinAntiDiagonalPath()), second);

      final _Run run = await _render(device!, list);
      expect(run.recorder.acceptedCount, 2);
      _expectParity(run, tolerance: 0);
    });
  });

  group('a refusal returns the draw to the dense atlas', () {
    test('an aliased fill is never promoted', () async {
      if (_skipped(skip)) return;
      // Sparse coverage is analytic antialiasing, so the capabilities probe
      // reports it unavailable for an aliased draw and the selector never
      // proposes it. The picture must still be the CPU's.
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFFCC3311, antiAlias: false);
      list.drawPath(list.addPath(_thinDiagonalPath()), paint);

      final _Run run = await _render(device!, list);
      expect(run.candidate, isNot(GpuPathStrategy.sparseStrips));
      expect(run.executed, GpuPathStrategy.coverageAtlas);
      expect(run.recorder.acceptedCount, 0);
      _expectParity(run, tolerance: 0);
    });

    test('a gradient paint is refused by the recorder, with no device', () {
      // Not a rendered scene: the recorder is the layer that would otherwise
      // build a sparse material with no LUT behind it, so the refusal is
      // asserted directly and does not need a GPU.
      final VulkanVectorPathRecorder recorder = VulkanVectorPathRecorder();
      expect(
        recorder.tryRecord(_request(
          _thinDiagonalPath(),
          gradient: LinearGradient(
            startX: 0,
            startY: 0,
            endX: 64,
            endY: 64,
            stops: <GradientStop>[
              const GradientStop(0, 0xFF000000),
              const GradientStop(1, 0xFFFFFFFF),
            ],
          ),
        )),
        isFalse,
      );
      expect(recorder.acceptedCount, 0);
      expect(recorder.refusalCount, 1);
      expect(recorder.commandCount, 0);
    });

    test('an out-of-order batch index is refused, with no device', () {
      final VulkanVectorPathRecorder recorder = VulkanVectorPathRecorder();
      expect(recorder.tryRecord(_request(_thinDiagonalPath(), batchIndex: 4)),
          isTrue);
      // Backwards would mean a vector command drawing before dense work that
      // preceded it in the display list.
      expect(recorder.tryRecord(_request(_thinDiagonalPath(), batchIndex: 2)),
          isFalse);
      expect(recorder.commandCount, 1);
      expect(recorder.refusalCount, 1);
    });

    test('a candidate that is not sparse strips is refused, with no device',
        () {
      final VulkanVectorPathRecorder recorder = VulkanVectorPathRecorder();
      // This backend builds no compute pipeline, so approach D has no route
      // here and the recorder says so rather than committing a command nothing
      // can dispatch.
      expect(
        recorder.tryRecord(_request(
          _thinDiagonalPath(),
          strategy: GpuPathStrategy.computeTiles,
        )),
        isFalse,
      );
      expect(recorder.commandCount, 0);
    });

    test('a path with no coverage measures as nothing, with no device', () {
      final VulkanVectorPathRecorder recorder = VulkanVectorPathRecorder();
      // A closed contour with no area encodes no quads at all. The probe
      // answering null is what keeps the selector from costing a route that
      // would then have to be refused, and it is the same null `_encodeSparse`
      // returns when `tryRecord` asks - an empty plan is never committed, so
      // the ordered stream never carries a draw that produces no pixels.
      expect(
        recorder.probeSparseMetrics(
          _degeneratePath(),
          Transform2D.identity,
          const Rect.fromLTRB(0, 0, 64, 64),
          FillRule.nonZero,
        ),
        isNull,
      );
      expect(recorder.commandCount, 0);
      expect(recorder.failureCount, 0,
          reason: 'no coverage is an answer, not an error');
    });
  });

  group('a retained encoding survives the frame', () {
    test('a repeated frame reuses the sparse plan and draws the same',
        () async {
      if (_skipped(skip)) return;
      final VulkanOffscreenTarget target = _targetOn(device!);
      addTearDown(target.dispose);
      final DisplayList list = _thinDiagonal();

      for (var frame = 0; frame < 2; frame++) {
        final PresentResult result =
            await target.renderDisplayList(list, clearColor: _clear);
        expect(result.status, PresentStatus.presented,
            reason: '${result.diagnostic}');
      }
      // Two frames, two accepted commands, one retained encoding: without the
      // cache a static scene would re-rasterise its analytic coverage every
      // frame, which is the exact cost sparse strips exist to remove.
      expect(target.vectorRecorder!.acceptedCount, 2);
      expect(target.vectorRecorder!.sparsePlanCache.hits, greaterThan(0));

      final MemoryRenderTarget cpu = _cpuTarget();
      addTearDown(cpu.dispose);
      await cpu.renderDisplayList(list, clearColor: _clear);
      expect(_maxDeviation(cpu.framebuffer, target.framebuffer), 0);
    });
  });

  group('the production path is untouched', () {
    test('a device opened without the flag has no recorder at all', () async {
      if (_skipped(skip)) return;
      final VulkanRenderDevice plain =
          VulkanRenderDevice.adoptInstance(session.instance!);
      addTearDown(plain.dispose);
      final VulkanOffscreenTarget target = _targetOn(plain);
      addTearDown(target.dispose);
      expect(target.vectorRecorder, isNull);
      expect(target.pathPlanning, isNull);

      // And it still draws the same scene correctly through the dense atlas.
      final MemoryRenderTarget cpu = _cpuTarget();
      addTearDown(cpu.dispose);
      await cpu.renderDisplayList(_thinDiagonal(), clearColor: _clear);
      final PresentResult result =
          await target.renderDisplayList(_thinDiagonal(), clearColor: _clear);
      expect(result.status, PresentStatus.presented,
          reason: '${result.diagnostic}');
      expect(_maxDeviation(cpu.framebuffer, target.framebuffer), 0);
    });
  });

  test('the validation layer said nothing, or said it was absent', () {
    if (_skipped(skip)) return;
    final instance = session.instance!;
    if (!instance.validationEnabled) {
      printOnFailure('VK_LAYER_KHRONOS_validation is not installed on this '
          'machine; the interleaved render passes above ran without it and '
          'every scene still matched the CPU exactly.');
      return;
    }
    expect(instance.problems, isEmpty,
        reason: 'the validation layer objected while the ordered walk ran:\n'
            '${instance.problems.join('\n')}');
  });
}

// ---------------------------------------------------------------------
// Scenes
// ---------------------------------------------------------------------

/// A long, thin, antialiased band across the surface.
///
/// Chosen so the selector really prefers sparse strips rather than being
/// forced: its bounding box is nearly the whole surface, so the dense mask
/// costs the area, while its boundary is two edges and its interior is solid
/// runs - exactly the trade `SparseStripDrawPlan` exists to make.
Path _thinDiagonalPath() => (PathBuilder()
      ..moveTo(2.5, 8.5)
      ..lineTo(61.5, 40.5)
      ..lineTo(61.5, 49.5)
      ..lineTo(2.5, 17.5)
      ..close())
    .build();

Path _thinAntiDiagonalPath() => (PathBuilder()
      ..moveTo(2.5, 55.5)
      ..lineTo(61.5, 23.5)
      ..lineTo(61.5, 32.5)
      ..lineTo(2.5, 46.5)
      ..close())
    .build();

/// A closed contour with no area: three collinear points and back.
Path _degeneratePath() => (PathBuilder()
      ..moveTo(4, 20)
      ..lineTo(40, 20)
      ..lineTo(22, 20)
      ..close())
    .build();

DisplayList _thinDiagonal() {
  final DisplayList list = DisplayList();
  final int paint = list.addPaint(colorArgb: 0xFFCC3311);
  list.drawPath(list.addPath(_thinDiagonalPath()), paint);
  return list;
}

GpuPathDispatchRequest _request(
  Path path, {
  int batchIndex = 0,
  Gradient? gradient,
  GpuPathStrategy strategy = GpuPathStrategy.sparseStrips,
  Rect clip = const Rect.fromLTRB(0, 0, 64, 64),
}) {
  final ReplayPaint paint = ReplayPaint(
    argbColor: 0xFFCC3311,
    style: paintStyleFill,
    strokeWidth: 0,
    blendMode: blendModeSrcOver,
    antiAlias: true,
    gradient: gradient,
  );
  final GpuPathPlanningTelemetry telemetry = GpuPathPlanningTelemetry(
    candidateCapabilities: const GpuPathStrategyCapabilities(
      sparseStrips: true,
      tessellation: true,
      stencil: true,
      compute: true,
    ),
  );
  final GpuPathPlanningProposal? proposal = telemetry.plan(
    label: 'path',
    path: path,
    localToTarget: Transform2D.identity,
    clip: clip,
    fillRule: FillRule.nonZero,
    denseMaskCacheHit: false,
    traits: const GpuPathDrawTraits(antiAlias: true),
  );
  return GpuPathDispatchRequest(
    proposal: _forceStrategy(proposal!, strategy),
    path: path,
    localToTarget: Transform2D.identity,
    clip: clip,
    fillRule: FillRule.nonZero,
    paint: paint,
    batchIndex: batchIndex,
  );
}

/// A proposal whose candidate is [strategy], whatever the selector chose.
///
/// The recorder's contract is about what it does with a candidate it is given,
/// and pinning the candidate here is what lets a refusal be attributed to the
/// recorder rather than to the selector having picked something else that day.
GpuPathPlanningProposal _forceStrategy(
  GpuPathPlanningProposal proposal,
  GpuPathStrategy strategy,
) =>
    proposal.candidate.strategy == strategy
        ? proposal
        : GpuPathPlanningProposal(
            label: proposal.label,
            workload: proposal.workload,
            candidate: GpuPathStrategyDecision(
              strategy,
              'pinned by vulkan_vector_dispatch_test',
            ),
          );

// ---------------------------------------------------------------------
// The run
// ---------------------------------------------------------------------

final class _Run {
  const _Run({
    required this.cpu,
    required this.gpu,
    required this.recorder,
    required this.candidate,
    required this.executed,
    required this.stats,
  });

  final Framebuffer cpu;
  final Framebuffer gpu;
  final VulkanVectorPathRecorder recorder;
  final GpuPathStrategy? candidate;
  final GpuPathStrategy? executed;
  final SparseVulkanExecutionStats? stats;
}

bool _skipped(String? skip) {
  if (skip == null) return false;
  printOnFailure('skipped: $skip');
  markTestSkipped('no Vulkan device: $skip');
  return true;
}

VulkanOffscreenTarget _targetOn(VulkanRenderDevice device) =>
    device.createTarget(const MemorySurfaceDescriptor(
      pixelWidth: _size,
      pixelHeight: _size,
      format: PixelFormat.rgba8888Premultiplied,
    )) as VulkanOffscreenTarget;

MemoryRenderTarget _cpuTarget() =>
    MemoryRenderTarget(const MemorySurfaceDescriptor(
      pixelWidth: _size,
      pixelHeight: _size,
      format: PixelFormat.rgba8888Premultiplied,
    ));

Future<_Run> _render(VulkanRenderDevice device, DisplayList list) async {
  final MemoryRenderTarget cpu = _cpuTarget();
  addTearDown(cpu.dispose);
  await cpu.renderDisplayList(list, clearColor: _clear);

  final VulkanOffscreenTarget gpu = _targetOn(device);
  addTearDown(gpu.dispose);
  final PresentResult result =
      await gpu.renderDisplayList(list, clearColor: _clear);
  expect(result.status, PresentStatus.presented,
      reason: '${result.diagnostic}');

  final GpuPathPlanningEvent? event = gpu.pathPlanning!.lastEvent;
  return _Run(
    cpu: cpu.framebuffer,
    gpu: gpu.framebuffer,
    recorder: gpu.vectorRecorder!,
    candidate: event?.candidate.strategy,
    executed: event?.executedStrategy,
    stats: gpu.lastSparseStats,
  );
}

void _expectParity(_Run run, {required int tolerance}) {
  expect(_isUniform(run.cpu), isFalse,
      reason: 'the scene drew nothing, so comparing it proves nothing');
  final int deviation = _maxDeviation(run.cpu, run.gpu);
  printOnFailure('max deviation $deviation');
  expect(deviation, lessThanOrEqualTo(tolerance),
      reason: 'the CPU and the ordered Vulkan walk disagree by up to '
          '$deviation levels over a declared tolerance of $tolerance');
}

int _maxDeviation(Framebuffer cpu, Framebuffer gpu) {
  expect(gpu.width, cpu.width);
  expect(gpu.height, cpu.height);
  var maxDeviation = 0;
  for (var y = 0; y < cpu.height; y++) {
    for (var x = 0; x < cpu.width; x++) {
      final List<int> a = _rgba(cpu, x, y);
      final List<int> b = _rgba(gpu, x, y);
      for (var channel = 0; channel < 4; channel++) {
        final int difference = (a[channel] - b[channel]).abs();
        if (difference > maxDeviation) maxDeviation = difference;
      }
    }
  }
  return maxDeviation;
}

bool _isUniform(Framebuffer buffer) {
  final List<int> first = _rgba(buffer, 0, 0);
  for (var y = 0; y < buffer.height; y++) {
    for (var x = 0; x < buffer.width; x++) {
      final List<int> pixel = _rgba(buffer, x, y);
      for (var channel = 0; channel < 4; channel++) {
        if (pixel[channel] != first[channel]) return false;
      }
    }
  }
  return true;
}

List<int> _rgba(Framebuffer buffer, int x, int y) {
  final int offset = buffer.offsetOf(x, y);
  final Uint8List bytes = buffer.pixels;
  return switch (buffer.format) {
    PixelFormat.bgra8888Premultiplied => <int>[
        bytes[offset + 2],
        bytes[offset + 1],
        bytes[offset],
        bytes[offset + 3],
      ],
    _ => <int>[
        bytes[offset],
        bytes[offset + 1],
        bytes[offset + 2],
        bytes[offset + 3],
      ],
  };
}
