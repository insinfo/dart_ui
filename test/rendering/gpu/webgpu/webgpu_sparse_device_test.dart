@TestOn('browser')

/// The experimental sparse-strip pipeline on a real WebGPU device.
///
/// One question dominates this file, and only a browser can answer it: does the
/// WGSL in `wgsl_sparse_shaders.dart` **compile**, and are the pipelines built
/// from it - four entry points, an instance-stepped vertex buffer, a dynamic
/// uniform offset, a three-binding texture group - accepted by a real WebGPU
/// implementation? WebGPU validates asynchronously, so the answer never arrives
/// as a thrown exception: a bad module or a mismatched bind group surfaces on
/// the device's `uncapturederror` channel a microtask later. Every test here
/// therefore submits, yields, and then asks
/// [WebGpuRenderDevice.lastError] - which is the only way this class of bug is
/// visible at all.
///
/// There is no readback assertion, and that is the backend's design showing
/// rather than an omission: the WebGPU backend has no offscreen readback
/// target, so "these pixels are right" is asserted by the WebGL2 sparse suite
/// next door, which draws the same [SparseStripDrawPlan] through the same
/// encoder into a framebuffer it can read.
///
/// See `webgpu_session.dart` for the skip contract. The short form:
/// `@TestOn('browser')` keeps this out of CI's plain `dart test`, and inside a
/// browser every test names why it skipped when WebGPU is absent - which is
/// itself the configuration the production fallback to WebGL2 exists for.
library;

import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/graphics/gradient.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_gradient.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strip_draw_plan.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strips.dart';
import 'package:dart_ui/src/rendering/gpu/webgpu/webgpu_backend.dart';
import 'package:dart_ui/src/rendering/gpu/webgpu/webgpu_interop.dart';
import 'package:dart_ui/src/rendering/gpu/webgpu/webgpu_sparse_executor.dart';
import 'package:dart_ui/src/rendering/replay/display_list_player.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

import 'webgpu_session.dart';

void main() {
  late WebGpuSession session;

  setUpAll(() async {
    session = await WebGpuSession.open(enableExperimentalSparseStrips: true);
  });
  tearDownAll(() => session.close());

  bool ready() {
    final String? reason = session.skipReason;
    if (reason == null) return true;
    printOnFailure('skipped: $reason');
    markTestSkipped('no WebGPU device: $reason');
    return false;
  }

  /// A render target in the device's own format, which is what the sparse
  /// pipelines are built for.
  GPUTextureView target(int width, int height) {
    final WebGpuRenderDevice device = session.device!;
    return device.gpuDevice
        .createTexture(GPUTextureDescriptor(
          size: GPUExtent3DDict(width: width, height: height),
          format: device.surfaceFormat,
          usage: web.$GPUTextureUsage.RENDER_ATTACHMENT |
              web.$GPUTextureUsage.TEXTURE_BINDING,
        ))
        .createView();
  }

  /// Lets WebGPU's asynchronous validation reach `uncapturederror`.
  ///
  /// A plain microtask is not enough: the error event is dispatched from the
  /// device's own timeline, so the wait has to give the event loop a turn.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));

  group('the opt-in', () {
    test('is on for a device adopted with the flag', () {
      if (!ready()) return;
      expect(session.device!.experimentalSparseStripsEnabled, isTrue);
    });

    test('is off - and refuses - for a device adopted without it', () async {
      final WebGpuSession plain = await WebGpuSession.open();
      try {
        if (plain.skipReason != null) {
          printOnFailure('skipped: ${plain.skipReason}');
          markTestSkipped('no WebGPU device: ${plain.skipReason}');
          return;
        }
        expect(plain.device!.experimentalSparseStripsEnabled, isFalse);
        expect(
          () => plain.device!.submitSparseStrips(
            SparseStripDrawPlan()
              ..append(StripBuffer()..addFill(0, 0, 1), materialIndex: 0),
            materials: <SparseWebGpuMaterial>[_white()],
            viewportWidth: 4,
            viewportHeight: 4,
            target: plain.device!.gpuDevice
                .createTexture(GPUTextureDescriptor(
                  size: GPUExtent3DDict(width: 4, height: 4),
                  format: plain.device!.surfaceFormat,
                  usage: web.$GPUTextureUsage.RENDER_ATTACHMENT,
                ))
                .createView(),
          ),
          throwsStateError,
        );
      } finally {
        plain.close();
      }
    });
  });

  group('a real device', () {
    test('accepts the module and both solid pipelines', () async {
      if (!ready()) return;
      final StripBuffer source = StripBuffer()..addFill(1, 0, 3);
      final int alpha = source.reserveAlphas(4 * kStripHeight);
      source.alphas.fillRange(alpha, alpha + 4 * kStripHeight, 128);
      source.addStrip(4, 0, 4, alpha);
      final SparseStripDrawPlan plan = SparseStripDrawPlan()
        ..append(source, materialIndex: 0);

      final WebGpuSparseExecutionStats stats =
          session.device!.submitSparseStrips(
        plan,
        materials: <SparseWebGpuMaterial>[_white()],
        viewportWidth: 16,
        viewportHeight: kStripHeight,
        target: target(16, kStripHeight),
        clearColor: 0x00000000,
      );
      expect(stats.drawCalls, 2);
      expect(stats.instances, 2);
      expect(stats.alphaUploads, 1);
      expect(stats.uniformSlices, 1);

      await settle();
      // The whole point of this file. A WGSL parse error, a vertex layout the
      // module disagrees with, a bind group missing an entry - all of them land
      // here and nowhere else.
      expect(session.device!.lastError, isNull,
          reason: 'WebGPU reported a validation error for the sparse pipeline');
    });

    test('accepts both blend modes as separate pipelines', () async {
      if (!ready()) return;
      final SparseStripDrawPlan plan = SparseStripDrawPlan()
        ..append(StripBuffer()..addFill(0, 0, 2), materialIndex: 0)
        ..append(StripBuffer()..addFill(2, 0, 2), materialIndex: 1);

      session.device!.submitSparseStrips(
        plan,
        materials: <SparseWebGpuMaterial>[
          _white(),
          SparseWebGpuMaterial(
            red: 0,
            green: 0,
            blue: 1,
            alpha: 1,
            blendMode: blendModePlus,
          ),
        ],
        viewportWidth: 8,
        viewportHeight: kStripHeight,
        target: target(8, kStripHeight),
        clearColor: 0x00000000,
      );

      await settle();
      expect(session.device!.lastError, isNull);
    });

    test('accepts a gradient material and its shared LUT', () async {
      if (!ready()) return;
      final LinearGradient gradient = LinearGradient(
        startX: 0,
        startY: 0,
        endX: 8,
        endY: 0,
        stops: const <GradientStop>[
          GradientStop(0, 0xFF000000),
          GradientStop(1, 0xFFFFFFFF),
        ],
        spread: GradientSpread.reflect,
      );
      final GpuGradientCache cache =
          GpuGradientCache(allocator: session.device!);
      final GpuGradientBinding binding = cache.resolve(gradient);
      final GpuGradientShaderParameters parameters =
          GpuGradientShaderParameters.fromPaint(ReplayPaint(
        argbColor: 0,
        style: paintStyleFill,
        strokeWidth: 0,
        blendMode: blendModeSrcOver,
        antiAlias: true,
        gradient: gradient,
      ));

      session.device!.submitSparseStrips(
        SparseStripDrawPlan()
          ..append(StripBuffer()..addFill(0, 0, 8), materialIndex: 0),
        materials: <SparseWebGpuMaterial>[
          SparseWebGpuMaterial.gradient(
            gradientBinding: binding,
            gradientParameters: parameters,
            blendMode: blendModeSrcOver,
          ),
        ],
        viewportWidth: 8,
        viewportHeight: kStripHeight,
        target: target(8, kStripHeight),
        clearColor: 0x00000000,
      );

      await settle();
      // The gradient pipelines are the ones that sample two textures through
      // one bind group; a LUT view registered under the wrong id or a sampler
      // missing from the layout shows up right here.
      expect(session.device!.lastError, isNull);
      cache.clear();
    });

    test('draws two frames without recreating its buffers', () async {
      if (!ready()) return;
      final SparseStripDrawPlan plan = SparseStripDrawPlan()
        ..append(StripBuffer()..addFill(0, 0, 4), materialIndex: 0);
      final GPUTextureView view = target(8, kStripHeight);
      for (var frame = 0; frame < 2; frame++) {
        session.device!.submitSparseStrips(
          plan,
          materials: <SparseWebGpuMaterial>[_white()],
          viewportWidth: 8,
          viewportHeight: kStripHeight,
          target: view,
          // The second frame loads rather than clears, which is what an
          // alternative executor drawing into an already-composed frame does.
          clearColor: frame == 0 ? 0x00000000 : null,
        );
      }
      await settle();
      expect(session.device!.lastError, isNull);
    });
  });

  group('a refusal', () {
    test('never reaches the device', () async {
      if (!ready()) return;
      expect(
        () => session.device!.submitSparseStrips(
          SparseStripDrawPlan()
            ..append(StripBuffer()..addFill(0, 0, 1), materialIndex: 4),
          materials: <SparseWebGpuMaterial>[_white()],
          viewportWidth: 8,
          viewportHeight: kStripHeight,
          target: target(8, kStripHeight),
        ),
        throwsRangeError,
      );
      await settle();
      // Transactional: nothing was encoded, so there is nothing for WebGPU to
      // complain about and the caller may fall back to the dense atlas.
      expect(session.device!.lastError, isNull);
    });

    test('a non-positive viewport is refused before the pass', () async {
      if (!ready()) return;
      expect(
        () => session.device!.submitSparseStrips(
          SparseStripDrawPlan(),
          materials: const <SparseWebGpuMaterial>[],
          viewportWidth: 0,
          viewportHeight: 4,
          target: target(8, kStripHeight),
        ),
        throwsArgumentError,
      );
      await settle();
      expect(session.device!.lastError, isNull);
    });
  });
}

/// Opaque white, premultiplied, source-over.
SparseWebGpuMaterial _white() => SparseWebGpuMaterial(
      red: 1,
      green: 1,
      blue: 1,
      alpha: 1,
      blendMode: blendModeSrcOver,
    );
