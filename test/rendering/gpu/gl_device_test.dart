/// The GL backend against a real driver, when there is one.
///
/// Everything else under `test/rendering/gpu` runs on a machine with no GPU,
/// which is the right default and is also the reason this file has to exist:
/// a batcher that batches perfectly and a shader that never compiled produce
/// a suite that is green and a renderer that has never drawn a pixel.
///
/// So this is the end-to-end check - open a device, draw, read the pixels
/// back and compare them against what the display list asked for. It skips
/// rather than fails where no driver answers, because "this CI container has
/// no DRM node" is not a defect in the renderer.
///
/// The Windows path goes through `Win32GlSurface`, which is where the window
/// a WGL context needs is allowed to be named. That import is legal here and
/// illegal in `lib/src/rendering`; `test/architecture/layering_test.dart`
/// enforces the difference.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/backends/win32/win32_gl_surface.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/transform2d.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/graphics/gradient.dart';
import 'package:dart_ui/src/graphics/gradient_lut.dart';
import 'package:dart_ui/src/graphics/image/decoded_image.dart';
import 'package:dart_ui/src/rendering/cpu_renderer.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_backend.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_bindings.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_context.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_framebuffer_pool.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_sparse_executor.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_stencil_cover_executor.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_tessellated_executor.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_vector_path_recorder.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_batcher.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_gradient.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_layer_stack.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_path_strategy.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_pipeline.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_recovery.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_texture.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_vector_command_stream.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_vector_submission_cursor.dart';
import 'package:dart_ui/src/rendering/gpu/vector/cpu_tessellation.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strip_draw_plan.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strips.dart';
import 'package:dart_ui/src/rendering/gpu/vector/stencil_cover_draw_plan.dart';
import 'package:dart_ui/src/rendering/gpu/vector/vector_plan_cache.dart';
import 'package:dart_ui/src/rendering/path/fill_rule.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:dart_ui/src/rendering/replay/display_list_player.dart';
import 'package:test/test.dart';

void main() {
  final session = _GlSession.open();
  final sparseSession = _GlSession.open(
    enableExperimentalSparseStrips: true,
    enableExperimentalStencilCover: true,
    enableExperimentalCpuTessellation: true,
  );

  group('a live GL device', () {
    tearDownAll(session.close);

    test('reports a vendor, a renderer and a version', () {
      final device = session.device!;
      // Empty strings here mean the context was not actually current when
      // glGetString ran, which is the failure that looks like a working
      // renderer until the first draw.
      expect(device.info.deviceDescription, isNotEmpty);
      expect(device.info.driverVersion, isNotEmpty);
      expect(device.capabilities.maxTextureSize, greaterThanOrEqualTo(2048));
      expect(device.experimentalSparseStripsEnabled, isFalse,
          reason: 'the dense renderer must remain the default');
      expect(device.experimentalStencilCoverEnabled, isFalse,
          reason: 'experimental stencil must remain opt-in');
      expect(device.experimentalCpuTessellationEnabled, isFalse,
          reason: 'retained CPU tessellation must remain opt-in');
      printOnFailure('${device.info.deviceDescription} / '
          '${device.info.driverVersion}');
    }, skip: session.skipReason);

    test('resolves every entry point the renderer needs', () {
      // The Windows regression this whole change exists for: opengl32.dll
      // exports OpenGL 1.1, so a table built from the export table alone is
      // missing glCreateShader, glGenBuffers and glGenVertexArrays and the
      // renderer can never start.
      expect(missingGlSymbols(session.context!.procAddress), isEmpty);
    }, skip: session.skipReason);

    test('clears to the requested colour', () async {
      final target = session.target(4, 4);
      final list = DisplayList();
      final result =
          await target.renderDisplayList(list, clearColor: 0xFF204060);

      expect(result.status, PresentStatus.presented);
      expect(_pixel(target.framebuffer, 0, 0), <int>[0x20, 0x40, 0x60, 0xFF]);
      target.dispose();
    }, skip: session.skipReason);

    test('draws an aliased rectangle at exactly the pixels asked for',
        () async {
      final target = session.target(8, 8);
      final list = DisplayList();
      final paint = list.addPaint(colorArgb: 0xFF3366CC, antiAlias: false);
      list.drawRect(2, 1, 6, 4, paint);
      final result =
          await target.renderDisplayList(list, clearColor: 0xFF000000);

      expect(result.status, PresentStatus.presented);
      final framebuffer = target.framebuffer;
      // Inside, on the boundary and outside. An off-by-one in the projection
      // flip moves the whole rectangle by a row and nothing else notices.
      expect(_pixel(framebuffer, 2, 1), <int>[0x33, 0x66, 0xCC, 0xFF]);
      expect(_pixel(framebuffer, 5, 3), <int>[0x33, 0x66, 0xCC, 0xFF]);
      expect(_pixel(framebuffer, 1, 1), <int>[0, 0, 0, 0xFF]);
      expect(_pixel(framebuffer, 6, 1), <int>[0, 0, 0, 0xFF]);
      expect(_pixel(framebuffer, 2, 4), <int>[0, 0, 0, 0xFF]);
      target.dispose();
    }, skip: session.skipReason);

    test('the analytic coverage antialiases a half-pixel edge', () async {
      final target = session.target(8, 8);
      final list = DisplayList();
      final paint = list.addPaint(colorArgb: 0xFFFFFFFF);
      list.drawRect(2.5, 0, 6, 8, paint);
      await target.renderDisplayList(list, clearColor: 0xFF000000);

      // The shader's boxCoverage on a rect whose left edge cuts column 2 in
      // half. A renderer with no coverage term paints that column either
      // fully white or fully black; both are visible as a hard edge.
      final edge = _pixel(target.framebuffer, 2, 4)[0];
      expect(edge, greaterThan(100));
      expect(edge, lessThan(160));
      expect(_pixel(target.framebuffer, 3, 4)[0], 0xFF);
      expect(_pixel(target.framebuffer, 1, 4)[0], 0);
      target.dispose();
    }, skip: session.skipReason);

    test('an antialiased path goes through the mask atlas', () async {
      final target = session.target(16, 16);
      final list = DisplayList();
      final paint = list.addPaint(colorArgb: 0xFFFFFFFF);
      list.drawRRect(2, 2, 14, 14, 4, 4, 4, 4, 4, 4, 4, 4, paint);
      final result =
          await target.renderDisplayList(list, clearColor: 0xFF000000);

      expect(result.status, PresentStatus.presented);
      // The centre is inside the rounded rect and the corner is outside it,
      // which is only true if the alpha8 mask reached the texture.
      expect(_pixel(target.framebuffer, 8, 8)[0], 0xFF);
      expect(_pixel(target.framebuffer, 2, 2)[0], lessThan(0x40));
      target.dispose();
    }, skip: session.skipReason);

    test('a drawn image is uploaded and sampled', () async {
      // The path that threw for every caller until GlImageCache existed: the
      // sink asked for a GpuImageResolver and nothing implemented one.
      final image = Framebuffer.allocate(
        width: 2,
        height: 2,
        format: PixelFormat.rgba8888Premultiplied,
      );
      for (var i = 0; i < 4; i++) {
        image.pixels[i * 4] = 0xFF;
        image.pixels[i * 4 + 1] = 0x00;
        image.pixels[i * 4 + 2] = 0x00;
        image.pixels[i * 4 + 3] = 0xFF;
      }

      final target = session.target(8, 8);
      final list = DisplayList();
      final paint = list.addPaint(colorArgb: 0xFFFFFFFF, antiAlias: false);
      final id = list.addImage(image);
      list.drawImage(id, 0, 0, 2, 2, 0, 0, 8, 8, paint);
      final result =
          await target.renderDisplayList(list, clearColor: 0xFF000000);

      expect(result.status, PresentStatus.presented);
      expect(_pixel(target.framebuffer, 4, 4), <int>[0xFF, 0, 0, 0xFF]);
      expect(target.images.length, 1);
      target.dispose();
    }, skip: session.skipReason);

    test('a texture larger than the device allows is refused, not fatal', () {
      final device = session.device!;
      final tooBig = device.capabilities.maxTextureSize + 1;

      expect(
        () => device.createTexture(
          width: tooBig,
          height: 4,
          format: GpuTextureFormat.rgba8888Premultiplied,
        ),
        throwsA(isA<UnsupportedCapabilityError>()),
      );
      // The point of the check: the device is still alive afterwards. Letting
      // GL_INVALID_VALUE mark the device lost turned "this image is too big"
      // into a renderer that could never draw again.
      expect(device.isLost, isFalse);
      final small = device.createTexture(
        width: 4,
        height: 4,
        format: GpuTextureFormat.rgba8888Premultiplied,
      );
      expect(small.isValid, isTrue);
      device.releaseTexture(small);
    }, skip: session.skipReason);

    test('textures carry the filter they were asked for', () {
      final device = session.device!;
      final mask = device.createTexture(
        width: 8,
        height: 8,
        format: GpuTextureFormat.alpha8,
      );
      final image = device.createTexture(
        width: 8,
        height: 8,
        format: GpuTextureFormat.rgba8888Premultiplied,
        filter: GpuTextureFilter.linear,
      );

      expect(mask.filter, GpuTextureFilter.nearest);
      expect(image.filter, GpuTextureFilter.linear);
      device
        ..releaseTexture(mask)
        ..releaseTexture(image);
    }, skip: session.skipReason);
  });

  group('the opt-in sparse GL component on a live driver', () {
    tearDownAll(sparseSession.close);

    test('compiles, links and owns its native objects', () {
      final GlRenderDevice device = sparseSession.device!;
      expect(device.experimentalSparseStripsEnabled, isTrue);
      expect(device.experimentalStencilCoverEnabled, isTrue);
      expect(device.makeCurrentOrLose(), isTrue);
      expect(
          missingSparseGlSymbols(sparseSession.context!.procAddress), isEmpty);
    }, skip: sparseSession.skipReason);

    test('executes stencil-then-cover when framebuffer zero has stencil', () {
      final GlRenderDevice device = sparseSession.device!;
      final StencilCoverCapabilities capabilities =
          device.queryStencilCoverCapabilities();
      if (capabilities.stencilBits < 1) {
        markTestSkipped('the live default framebuffer has no stencil bits');
        return;
      }
      final StencilCoverDrawPlan plan = StencilCoverDrawPlan()
        ..append(
          Path.rect(const Rect.fromLTRB(0, 0, 8, 8)),
          clip: const Rect.fromLTRB(0, 0, 16, 16),
          materialIndex: 0,
          fillRule: FillRule.evenOdd,
          capabilities: capabilities,
          antiAlias: false,
        );

      final StencilCoverGlExecutionStats stats = device.submitStencilCover(
        plan,
        materials: <StencilGlMaterial>[
          StencilGlMaterial(red: 0.5, green: 0, blue: 0, alpha: 0.5),
        ],
        viewportWidth: 16,
        viewportHeight: 16,
      );

      expect(stats.draws, 1);
      expect(stats.commands, 3);
      expect(stats.accumulationTriangles, 2);
      expect(device.isLost, isFalse);
    }, skip: sparseSession.skipReason);

    test('creates a complete stencil FBO and executes approach C into it', () {
      final GlRenderDevice device = sparseSession.device!;
      if (missingAttachmentFramebufferGlSymbols(
              sparseSession.context!.procAddress)
          .isNotEmpty) {
        markTestSkipped('the live driver lacks attachment framebuffer calls');
        return;
      }
      final GlFramebufferPool pool = GlFramebufferPool(
        factory: GlDeviceFramebufferFactory(
          gl: device.api,
          scratchNames: device.scratchNames,
          makeCurrent: device.makeCurrentOrLose,
        ),
      );
      final GlFramebuffer target = pool.acquireFramebuffer(
        16,
        16,
        attachments: GlFramebufferAttachments.stencil8,
      );
      try {
        final StencilCoverCapabilities capabilities =
            device.queryStencilCoverCapabilities(
          surfaceFramebuffer: target.id,
        );
        expect(capabilities.stencilBits, greaterThanOrEqualTo(8));
        expect(capabilities.sampleCount, 1);
        final StencilCoverDrawPlan plan = StencilCoverDrawPlan()
          ..append(
            Path.rect(const Rect.fromLTRB(2, 2, 14, 14)),
            clip: const Rect.fromLTRB(0, 0, 16, 16),
            materialIndex: 0,
            fillRule: FillRule.nonZero,
            capabilities: capabilities,
            antiAlias: false,
          );
        final StencilCoverGlExecutionStats stats = device.submitStencilCover(
          plan,
          materials: <StencilGlMaterial>[
            StencilGlMaterial(red: 0, green: 0.5, blue: 0, alpha: 0.5),
          ],
          viewportWidth: 16,
          viewportHeight: 16,
          surfaceFramebuffer: target.id,
        );
        expect(stats.coverDraws, 1);
        expect(device.isLost, isFalse);
      } finally {
        pool
          ..releaseLayerTarget(target)
          ..dispose();
      }
    }, skip: sparseSession.skipReason);

    test('creates a complete stencil8+MSAA4 FBO and resolves it', () {
      // The measurement that decides whether approach C can ever be automatic
      // on this machine. `gl_vector_replay.dart` requires four samples before
      // it reports the stencil capability, because a one-sample cover pass
      // differs from the analytic routes by 144 levels; this asks the driver
      // whether four samples with a stencil buffer are actually obtainable,
      // and whether the resolve blit that makes them readable works.
      final GlRenderDevice device = sparseSession.device!;
      if (missingAttachmentFramebufferGlSymbols(
              sparseSession.context!.procAddress)
          .isNotEmpty) {
        markTestSkipped('the live driver lacks attachment framebuffer calls');
        return;
      }
      final GlFramebufferPool pool = GlFramebufferPool(
        factory: GlDeviceFramebufferFactory(
          gl: device.api,
          scratchNames: device.scratchNames,
          makeCurrent: device.makeCurrentOrLose,
        ),
      );
      GlFramebuffer? target;
      try {
        target = pool.acquireFramebuffer(
          16,
          16,
          attachments: GlFramebufferAttachments.stencil8Msaa4,
        );
      } on StateError catch (error) {
        markTestSkipped('this driver refused a 4x stencil target: $error');
        pool.dispose();
        return;
      }
      try {
        expect(target.resolveFramebufferId, isNonZero,
            reason: 'a multisampled target needs a second FBO carrying the '
                'single-sample texture that a composite can sample');
        final StencilCoverCapabilities capabilities =
            device.queryStencilCoverCapabilities(
          surfaceFramebuffer: target.id,
        );
        expect(capabilities.stencilBits, greaterThanOrEqualTo(8));
        expect(capabilities.sampleCount, greaterThanOrEqualTo(4),
            reason: 'the driver has to agree the FBO really is multisampled, '
                'not merely accept the request');
        // The resolve is the half that has no other test: without it the
        // multisampled colour is unreadable by glReadPixels and unsampleable
        // by a composite quad.
        pool.resolveFramebuffer(target);
        expect(device.checkError('msaa resolve'), isFalse,
            reason: '${device.lastError}');
        expect(device.isLost, isFalse);
      } finally {
        pool
          ..releaseLayerTarget(target)
          ..dispose();
      }
    }, skip: sparseSession.skipReason);

    test('stencil capability queries restore binding and reject invalid FBOs',
        () {
      final GlRenderDevice device = sparseSession.device!;
      expect(device.makeCurrentOrLose(), isTrue);
      final GlApi gl = device.api;
      final Pointer<Uint32> slot = device.scratchNames;
      gl.genFramebuffers(1, slot);
      final int incompleteFramebuffer = slot[0];
      expect(incompleteFramebuffer, isNonZero);
      try {
        gl.bindFramebuffer(glDrawFramebuffer, incompleteFramebuffer);
        device.queryStencilCoverCapabilities();
        slot[0] = 0;
        gl.getIntegerv(glDrawFramebufferBinding, slot.cast<Int32>());
        expect(slot[0], incompleteFramebuffer);

        gl.bindFramebuffer(glDrawFramebuffer, 0);
        expect(
          () => device.queryStencilCoverCapabilities(
            surfaceFramebuffer: incompleteFramebuffer,
          ),
          throwsStateError,
        );
        slot[0] = incompleteFramebuffer;
        gl.getIntegerv(glDrawFramebufferBinding, slot.cast<Int32>());
        expect(slot[0], 0);
        expect(
          () => device.queryStencilCoverCapabilities(surfaceFramebuffer: -1),
          throwsArgumentError,
        );
      } finally {
        gl.bindFramebuffer(glDrawFramebuffer, 0);
        slot[0] = incompleteFramebuffer;
        gl.deleteFramebuffers(1, slot);
      }
    }, skip: sparseSession.skipReason);

    test('uploads alpha8 data and issues a real instanced draw', () {
      final GlRenderDevice device = sparseSession.device!;
      final StripBuffer strips = StripBuffer()..addFill(1, 1, 4);
      final int alpha = strips.reserveAlphas(4 * kStripHeight);
      strips.alphas.fillRange(alpha, alpha + 4 * kStripHeight, 128);
      strips.addStrip(2, 4, 4, alpha);
      final SparseStripDrawPlan plan = SparseStripDrawPlan(
        atlasWidth: 8,
        atlasHeight: 8,
      )..append(strips, materialIndex: 0);

      final SparseGlExecutionStats stats = device.submitSparseStrips(
        plan,
        materials: <SparseGlMaterial>[
          SparseGlMaterial(
            red: 0.25,
            green: 0.5,
            blue: 0.75,
            alpha: 1,
            blendMode: blendModeSrcOver,
          ),
        ],
        viewportWidth: 16,
        viewportHeight: 16,
      );

      expect(stats.drawCalls, 2);
      expect(stats.instances, 2);
      expect(stats.alphaUploads, 1);
      expect(device.isLost, isFalse);
    }, skip: sparseSession.skipReason);

    test('binds the canonical gradient LUT and parameters on a real draw', () {
      final GlRenderDevice device = sparseSession.device!;
      final RadialGradient gradient = RadialGradient(
        centerX: 8,
        centerY: 8,
        radius: 8,
        focusX: 6,
        focusY: 8,
        stops: const <GradientStop>[
          GradientStop(0, 0x80FF0000),
          GradientStop(1, 0xFF0000FF),
        ],
        spread: GradientSpread.reflect,
      );
      final GpuGradientCache cache = GpuGradientCache(
        allocator: device,
        lutSize: 16,
      );
      final GpuGradientBinding binding = cache.resolve(gradient);
      final GpuGradientShaderParameters parameters =
          GpuGradientShaderParameters.fromPaint(ReplayPaint(
        argbColor: 0,
        style: paintStyleFill,
        strokeWidth: 0,
        blendMode: blendModeSrcOver,
        antiAlias: true,
        gradient: gradient,
        shaderTransform: const Transform2D.translation(1, 2),
      ));
      final SparseStripDrawPlan plan = SparseStripDrawPlan()
        ..append(StripBuffer()..addFill(0, 0, 16), materialIndex: 0);

      try {
        final SparseGlExecutionStats stats = device.submitSparseStrips(
          plan,
          materials: <SparseGlMaterial>[
            SparseGlMaterial.gradient(
              gradientBinding: binding,
              gradientParameters: parameters,
              blendMode: blendModeSrcOver,
            ),
          ],
          viewportWidth: 16,
          viewportHeight: 16,
        );
        expect(stats.drawCalls, 1);
        expect(device.isLost, isFalse);
      } finally {
        cache.clear();
      }
    }, skip: sparseSession.skipReason);

    test('linear repeat gradient matches reference pixels with alpha', () {
      final GlRenderDevice device = sparseSession.device!;
      final LinearGradient gradient = LinearGradient(
        startX: 0,
        startY: 0,
        endX: 4,
        endY: 0,
        stops: const <GradientStop>[
          GradientStop(0, 0x2020E040),
          GradientStop(0.35, 0xA0E02080),
          GradientStop(1, 0xFF2040E0),
        ],
        spread: GradientSpread.repeat,
      );
      final ReplayPaint gradientPaint = ReplayPaint(
        argbColor: 0,
        style: paintStyleFill,
        strokeWidth: 0,
        blendMode: blendModeSrc,
        antiAlias: true,
        gradient: gradient,
        shaderTransform: const Transform2D.translation(-1, 0),
      );

      _expectSparseGradientParity(
        device,
        gradient,
        gradientPaint,
        targetOriginInDevice: Offset.zero,
        yFlip: 0,
      );
    }, skip: sparseSession.skipReason);

    test('focused radial reflect gradient matches layer-local pixels', () {
      final GlRenderDevice device = sparseSession.device!;
      final RadialGradient gradient = RadialGradient(
        centerX: 6,
        centerY: 4,
        radius: 6,
        focusX: 3,
        focusY: 4,
        stops: const <GradientStop>[
          GradientStop(0, 0x4040FF20),
          GradientStop(0.5, 0xC0FF2040),
          GradientStop(1, 0xFF2040FF),
        ],
        spread: GradientSpread.reflect,
      );
      final ReplayPaint paint = ReplayPaint(
        argbColor: 0,
        style: paintStyleFill,
        strokeWidth: 0,
        blendMode: blendModeSrc,
        antiAlias: true,
        gradient: gradient,
        shaderTransform: const Transform2D.translation(10, 20),
      );

      _expectSparseGradientParity(
        device,
        gradient,
        paint,
        targetOriginInDevice: const Offset(8, 16),
        // Layer targets are rendered top-down in texture memory.
        yFlip: 1,
      );
    }, skip: sparseSession.skipReason);

    test('retained tessellation applies transform and target-space clip',
        () async {
      final GlRenderDevice device = sparseSession.device!;
      expect(device.experimentalCpuTessellationEnabled, isTrue);
      final CpuTessellatedPathCache cache = CpuTessellatedPathCache();
      final TessellatedPathMesh mesh = cache.resolve(
        Path.rect(const Rect.fromLTRB(0, 0, 4, 4)),
      );
      final _SparsePixelSurface surface = _SparsePixelSurface.create(
        device,
        8,
        8,
      );
      try {
        surface.clear();
        final TessellatedGlExecutionStats first = device.submitTessellatedPath(
          mesh,
          material: TessellatedGlMaterial(
            red: 1,
            green: 0,
            blue: 0,
            alpha: 1,
            blendMode: blendModeSrc,
          ),
          viewportWidth: 8,
          viewportHeight: 8,
          localToTarget: const Transform2D.translation(2, 2),
          clip: const Rect.fromLTRB(3, 2, 6, 6),
          surfaceFramebuffer: surface.framebuffer,
        );
        final TessellatedGlExecutionStats second = device.submitTessellatedPath(
          mesh,
          material: TessellatedGlMaterial(
            red: 1,
            green: 0,
            blue: 0,
            alpha: 1,
            blendMode: blendModeSrc,
          ),
          viewportWidth: 8,
          viewportHeight: 8,
          localToTarget: const Transform2D.translation(2, 2),
          clip: const Rect.fromLTRB(3, 2, 6, 6),
          surfaceFramebuffer: surface.framebuffer,
        );
        expect(first.uploadedMeshes, 1);
        expect(first.triangles, 2);
        expect(second.uploadedMeshes, 0,
            reason: 'the second draw must reuse the retained VBO/IBO');

        final Uint8List pixels = surface.readTargetOrder(yFlip: 0);
        expect(_rgba(pixels, 8, 3, 3), <int>[255, 0, 0, 255]);
        expect(_rgba(pixels, 8, 5, 5), <int>[255, 0, 0, 255]);
        expect(_rgba(pixels, 8, 2, 3), <int>[0, 0, 0, 0],
            reason: 'the transformed mesh starts here but clip removes it');
        expect(_rgba(pixels, 8, 6, 3), <int>[0, 0, 0, 0]);

        final Pointer<Int32> binding = surface.heap.allocate<Int32>(4);
        try {
          device.api.getIntegerv(glDrawFramebufferBinding, binding);
          expect(binding[0], surface.framebuffer,
              reason: 'the executor must leave its caller-selected target '
                  'bound');
        } finally {
          surface.heap.release(binding);
        }

        final GlOffscreenTarget dense = sparseSession.target(4, 4);
        try {
          final DisplayList list = DisplayList();
          final int paint =
              list.addPaint(colorArgb: 0xFF20A060, antiAlias: false);
          list.drawRect(0, 0, 4, 4, paint);
          await dense.renderDisplayList(list, clearColor: 0x00000000);
          expect(_pixel(dense.framebuffer, 1, 1), <int>[0x20, 0xA0, 0x60, 255],
              reason: 'dense state must be rebound after the explicit '
                  'tessellated executor changed program/VAO/blend/scissor');
        } finally {
          dense.dispose();
        }
      } finally {
        surface.dispose();
      }
    }, skip: sparseSession.skipReason);

    test('ordered replay interleaves dense, retained B and dense by pixels',
        () {
      final GlRenderDevice device = sparseSession.device!;
      final _SparsePixelSurface surface = _SparsePixelSurface.create(
        device,
        8,
        8,
      );
      final batcher = GpuBatcher()..beginFrame();
      final layers = GpuLayerStack(allocator: _NoLayerAllocator())
        ..beginFrame(surfaceWidth: 8, surfaceHeight: 8);
      final stream =
          GpuVectorCommandStream<ReplayPaint, GlVectorPathPayload>(layers)
            ..resetForFrame();
      const Rect clip = Rect.fromLTRB(0, 0, 8, 8);
      void dense(Rect rect, double red, double green, double blue) {
        batcher
          ..setState(
            pipeline: GpuPipelineKind.solid,
            textureId: 0,
            blendMode: blendModeSrc,
            scissorLeft: 0,
            scissorTop: 0,
            scissorRight: 8,
            scissorBottom: 8,
          )
          ..addQuad(
            left: rect.left,
            top: rect.top,
            right: rect.right,
            bottom: rect.bottom,
            u0: 0,
            v0: 0,
            u1: 0,
            v1: 0,
            red: red,
            green: green,
            blue: blue,
            alpha: 1,
            shapeLeft: rect.left,
            shapeTop: rect.top,
            shapeRight: rect.right,
            shapeBottom: rect.bottom,
          );
      }

      dense(clip, 0, 0, 1);
      batcher.flush();
      final mesh = const CpuPathTessellator().tessellate(
        Path.rect(const Rect.fromLTRB(2, 2, 7, 7)),
      );
      stream.recordVector(
        batchIndex: batcher.batchCount,
        clip: clip,
        material: const ReplayPaint(
          argbColor: 0xFFFF0000,
          style: paintStyleFill,
          strokeWidth: 0,
          blendMode: blendModeSrc,
          antiAlias: false,
        ),
        payload: GlTessellatedPathPayload(
          mesh: mesh,
          localToTarget: Transform2D.identity,
          clip: clip,
        ),
      );
      dense(const Rect.fromLTRB(5, 5, 8, 8), 0, 1, 0);
      stream.finish(totalBatchCount: batcher.batchCount);

      try {
        surface.clear();
        final drawn = device.submitOrderedPaths(
          batcher,
          stream,
          GpuVectorSubmissionCursor(),
          8,
          8,
          null,
          surfaceFramebuffer: surface.framebuffer,
        );
        expect(drawn, isTrue);
        final pixels = surface.readTargetOrder(yFlip: 0);
        expect(_rgba(pixels, 8, 1, 1), <int>[0, 0, 255, 255]);
        expect(_rgba(pixels, 8, 3, 3), <int>[255, 0, 0, 255]);
        expect(_rgba(pixels, 8, 6, 6), <int>[0, 255, 0, 255],
            reason: 'the later dense batch must cover the vector draw');
      } finally {
        surface.dispose();
      }
    }, skip: sparseSession.skipReason);

    test('opt-in display-list replay promotes an aliased path to B', () async {
      final GlOffscreenTarget target = sparseSession.target(16, 16);
      final list = DisplayList();
      final paint = list.addPaint(
        colorArgb: 0xFF4080E0,
        antiAlias: false,
      );
      final path = list.addPath((PathBuilder()
            ..moveTo(2, 2)
            ..lineTo(14, 2)
            ..lineTo(2, 14)
            ..close())
          .build());
      list.drawPath(path, paint);

      try {
        final result =
            await target.renderDisplayList(list, clearColor: 0x00000000);
        expect(result.status, PresentStatus.presented);
        expect(target.experimentalVectorCommandCount, 1);
        expect(target.experimentalVectorAcceptedCount, 1);
        expect(_pixel(target.framebuffer, 3, 3), <int>[0x40, 0x80, 0xE0, 255]);
        expect(_pixel(target.framebuffer, 14, 14), <int>[0, 0, 0, 0]);
      } finally {
        target.dispose();
      }
    }, skip: sparseSession.skipReason);

    test('rebuilds the sparse program and objects after device loss', () {
      final GlRenderDevice device = sparseSession.device!;
      device.state.markLost(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'sparse GL recovery test',
      ));

      final GpuRecoveryReport report =
          GpuRecoveryCoordinator(host: device).recover();

      expect(report.isRecovered, isTrue, reason: '$report');
      expect(device.experimentalSparseStripsEnabled, isTrue);
      expect(device.experimentalStencilCoverEnabled, isTrue);
      expect(device.experimentalCpuTessellationEnabled, isTrue);
      final SparseStripDrawPlan plan = SparseStripDrawPlan()
        ..append(StripBuffer()..addFill(0, 0, 2), materialIndex: 0);
      expect(
        device
            .submitSparseStrips(
              plan,
              materials: <SparseGlMaterial>[
                SparseGlMaterial(
                  red: 1,
                  green: 1,
                  blue: 1,
                  alpha: 1,
                  blendMode: blendModeSrcOver,
                ),
              ],
              viewportWidth: 16,
              viewportHeight: 16,
            )
            .drawCalls,
        1,
      );
      final TessellatedPathMesh mesh = const CpuPathTessellator().tessellate(
        Path.rect(const Rect.fromLTRB(0, 0, 2, 2)),
      );
      expect(
        device
            .submitTessellatedPath(
              mesh,
              material: TessellatedGlMaterial(
                red: 1,
                green: 1,
                blue: 1,
                alpha: 1,
              ),
              viewportWidth: 16,
              viewportHeight: 16,
            )
            .uploadedMeshes,
        1,
        reason: 'device loss must rebuild VBO/IBO lazily from the CPU mesh',
      );
    }, skip: sparseSession.skipReason);
    // bug and a promotion that quietly did not happen is a regression.
    // -------------------------------------------------------------------
    group('attachments reach the pass descriptor', () {
      test('a colour-only device declares colour-only passes', () {
        // Its own device, because the default one is closed by the time this
        // group runs and because the fact under test is precisely that a
        // device with no stencil executor allocates no stencil buffer.
        final _GlSession plain = _GlSession.open();
        if (plain.skipReason != null) {
          markTestSkipped('no GL device: ${plain.skipReason}');
          return;
        }
        final GlOffscreenTarget target = plain.target(8, 8);
        try {
          expect(target.surfaceAttachments, GpuPassAttachments.colorOnly);
          expect(target.surfaceAttachments.hasStencil, isFalse);
        } finally {
          target.dispose();
          plain.close();
        }
      }, skip: sparseSession.skipReason);

      test('an approach-C device creates and declares a stencil8 MSAA target',
          () {
        final GlOffscreenTarget target = sparseSession.target(8, 8);
        try {
          expect(target.surfaceAttachments.hasStencil, isTrue,
              reason: 'the offscreen FBO is created by this backend, so unlike '
                  'framebuffer zero it can be given a stencil buffer');
          expect(target.surfaceAttachments.stencilBits, 8);
          expect(target.surfaceAttachments.sampleCount, greaterThanOrEqualTo(4),
              reason: 'four samples are what makes the stencil capability '
                  'reachable at all; see gl_vector_replay.dart');
          expect(target.surfaceAttachments.sampleCount, 16,
              reason: 'and this driver offers sixteen, which the target takes: '
                  'sample count is the only lever a cover pass has on edge '
                  'quality, and the gap against the analytic routes shrinks '
                  'as 1/N');
          // The declaration has to survive into the pass the layer stack builds,
          // because that is the object a strategy decision actually reads.
          target.beginFrame(const FrameRequest());
          expect(
              target.layers.currentPass.attachments, target.surfaceAttachments);
          // And the driver has to agree that the framebuffer really carries it.
          final StencilCoverCapabilities capabilities =
              sparseSession.device!.queryStencilCoverCapabilities(
            surfaceFramebuffer: target.debugFramebuffer,
          );
          expect(capabilities.stencilBits, greaterThanOrEqualTo(8));
        } finally {
          target.dispose();
        }
      }, skip: sparseSession.skipReason);

      test('a pooled layer target declares colour-only, so C stays out of it',
          () {
        final GlOffscreenTarget target = sparseSession.target(64, 64);
        try {
          target.beginFrame(const FrameRequest());
          target.layers.push(
            deviceBounds: const Rect.fromLTRB(0, 0, 32, 32),
            clip: const Rect.fromLTRB(0, 0, 64, 64),
            alpha: 128,
            blendMode: blendModeSrcOver,
            batchIndex: 0,
          );
          expect(target.layers.currentPass.attachments.hasStencil, isFalse,
              reason: 'GpuLayerStack asks its allocator for colour-only '
                  'targets, and a pass that claimed stencil anyway would let a '
                  'stencil draw run against a framebuffer with none');
          target.layers.pop(batchIndex: 0);
        } finally {
          target.dispose();
        }
      }, skip: sparseSession.skipReason);
    });

    group('the selector promotes automatically and the pixels agree', () {
      test('an aliased path the tessellator refuses becomes stencil-then-cover',
          () async {
        // Two contours - an outer square with a hole - which the conservative
        // CPU tessellator refuses, so approach B is out. Aliased, so sparse
        // strips are out. What is left is C, and the pass now reports both
        // things C needs: a stencil buffer and four samples.
        //
        // Both halves are load-bearing and the sample count is the one that
        // was missing. With the four-sample rule removed, this exact scene
        // through a *single-sample* cover pass differed from the CPU by **144
        // levels over 572 boundary pixels**: a filled path is analytically
        // antialiased on every other route in this renderer - the paint's
        // `antiAlias` flag does not reach path coverage on either the CPU or
        // the dense atlas - so one sample gives a visibly harder edge rather
        // than a rounding disagreement.
        final DisplayList list = _holePathScene(antiAlias: false);
        final _Parity parity = await _parity(sparseSession, list, 160);
        expect(parity.executed, GpuPathStrategy.stencilThenCover,
            reason: 'promotion must be the selector\'s decision, with no '
                'explicit executor call anywhere in this test');
        expect(parity.drewSomething, isTrue);
        // Observed deviation on Intel UHD Graphics: 0, on all 25 600 pixels.
        //
        // Exact, and for a reason that does not generalise - which is why the
        // test below exists. Every edge in this scene is axis-aligned on a
        // half-pixel boundary, so the analytic answer is exactly 0.5 and a
        // 4-sample pattern also resolves to exactly 0.5. The two coincide
        // because the geometry lands on a value both can represent.
        expect(parity.maxDeviation, lessThanOrEqualTo(0),
            reason: parity.report);
      }, skip: sparseSession.skipReason);

      test('stencil-then-cover quantises an off-grid edge, and by how much',
          () async {
        // The honest general measurement, and the reason approach C is a
        // *quality* trade rather than a free win.
        //
        // N samples express N+1 coverage values; analytic coverage is
        // continuous. On edges that land between them - here a diamond whose
        // centre and radius are deliberately off the pixel grid - the two
        // cannot agree, and the gap is bounded by the sample quantisation
        // rather than by any rounding rule.
        //
        // Measured on Intel UHD Graphics, over the same 636 boundary pixels of
        // 25 600 (the interior is exact either way):
        //
        //     4 samples   42 levels
        //     16 samples  18 levels
        //
        // The target takes 16 because the driver offers it, and that number is
        // what this asserts. It shrinks as 1/N and does not reach zero: a
        // cover pass cannot compute analytic coverage, because the stencil
        // test it is masked by is binary and no derivative can be taken of it.
        // Closing the gap entirely needs a ~1px fringe ring tessellated around
        // the contour with a per-vertex distance attribute, which replaces the
        // cover quad at the edge and brings contour offsetting, joins and caps
        // with it - a geometry subsystem, not a shader change.
        //
        // Worth knowing before anyone tries: Impeller does not do that either.
        // Its fills are 4x MSAA with a multisampled stencil attachment, its
        // solid_fill.frag is `frag_color = color`, and `setAntiAlias` is
        // documented there as a no-op because AA is implicit in the MSAA
        // target. This route already matches the reference implementation and
        // exceeds its sample count.
        //
        // Asserted on both sides so that a change in the cover pass's
        // antialiasing shows up here as a number rather than as a slightly
        // different picture nobody measured.
        final DisplayList list =
            _holePathScene(antiAlias: false, diagonal: true);
        final _Parity parity = await _parity(sparseSession, list, 160);
        expect(parity.executed, GpuPathStrategy.stencilThenCover);
        expect(parity.drewSomething, isTrue);
        expect(parity.maxDeviation, lessThanOrEqualTo(18),
            reason: parity.report);
        expect(parity.maxDeviation, greaterThan(0),
            reason: 'if this ever reaches zero the cover pass grew an analytic '
                'fringe, and the comment above is out of date');
        expect(parity.maxDeviation, greaterThan(10),
            reason: 'and if it merely dropped, the sample count changed - '
                'record the new pair in the table above rather than widening '
                'the bound');
        // Bounded, not merely non-zero: a regression that spread the
        // difference over the interior would still pass a maximum-only check.
        expect(parity.differingPixels, lessThan(1000), reason: parity.report);
      }, skip: sparseSession.skipReason);

      test('an antialiased path becomes sparse strips and matches the CPU',
          () async {
        // The same shape antialiased. Approach B has no fringe and this pass is
        // single-sample, C's antialiased form needs four samples and this pass
        // has one - so the only route that can carry a coverage fringe other
        // than the dense atlas is sparse strips, and its measured encoding beats
        // a 16 KiB mask upload.
        final DisplayList list = _holePathScene(antiAlias: true);
        final _Parity parity = await _parity(sparseSession, list, 160);
        expect(parity.executed, GpuPathStrategy.sparseStrips);
        expect(parity.drewSomething, isTrue);
        // Observed deviation on Intel UHD Graphics: 0. Both sides take their
        // coverage from the same `ScanlineFiller`; the sparse encoder only
        // changes how those bytes are *transported* - boundary strips as alpha8
        // texels, interiors as solid quads - and the shader multiplies the same
        // byte the CPU folds through `mul255`.
        expect(parity.maxDeviation, lessThanOrEqualTo(0),
            reason: parity.report);
      }, skip: sparseSession.skipReason);

      test('a small antialiased path keeps the dense atlas', () async {
        // Below the sizes above, the mask is the cheap answer and the selector
        // must say so. This is the test that keeps the promotions honest: if
        // everything were promoted, none of the comparisons above would mean
        // anything.
        final DisplayList list = _holePathScene(antiAlias: true, scale: 0.125);
        final _Parity parity = await _parity(sparseSession, list, 32);
        expect(parity.executed, GpuPathStrategy.coverageAtlas);
        expect(parity.maxDeviation, lessThanOrEqualTo(0),
            reason: parity.report);
      }, skip: sparseSession.skipReason);

      test(
          'a large saveLayer gets stencil and samples, so C promotes inside it',
          () async {
        // A layer target is acquired before anything is recorded into it, so
        // what it carries is a *policy* rather than a deduction - see
        // `GpuLayerStack.layerAttachmentPolicy`. This layer is 152x152, past
        // the 128 px threshold in `glLayerAttachmentsFor`, so it is allocated
        // stencil8 with four samples and the same path that takes route C on
        // the surface takes it here too.
        //
        // The composite that samples this target is drawn in the parent's
        // pass, which is appended after the layer's, so the multisample
        // resolve issued at the end of the layer's pass always feeds it. A
        // missing resolve is invisible in the strategy assertion and very
        // visible in the pixels, which is why both are checked.
        final DisplayList list = _holePathScene(
          antiAlias: false,
          insideLayerAlpha: 0x80,
        );
        final _Parity parity = await _parity(sparseSession, list, 160);
        expect(parity.executed, GpuPathStrategy.stencilThenCover,
            reason: 'the layer target now carries what approach C needs');
        expect(parity.drewSomething, isTrue);
        expect(parity.layerResolves, greaterThan(0),
            reason: 'a multisampled layer target that is never resolved leaves '
                'the composite sampling an unwritten texture');
        // Observed deviation on Intel UHD Graphics: 0. Every edge in this
        // scene is axis-aligned on a half-pixel boundary, which four samples
        // represent exactly - the same coincidence the surface case relies on,
        // and the off-grid test above is what measures the general answer.
        expect(parity.maxDeviation, lessThanOrEqualTo(0),
            reason: parity.report);
      }, skip: sparseSession.skipReason);

      test('a small saveLayer stays colour-only, and its contents fall back',
          () async {
        // The other half of the policy, and the one that keeps it from being
        // pure cost: a badge-sized layer is allocated exactly as before,
        // because the selector would not promote anything inside it anyway -
        // a shape cannot be larger than the layer that clips it, and below
        // 128 px it cannot reach the stencil threshold.
        final DisplayList list = _holePathScene(
          antiAlias: false,
          scale: 0.5,
          insideLayerAlpha: 0x80,
          layerSize: 80,
        );
        final _Parity parity = await _parity(sparseSession, list, 80);
        expect(parity.executed, GpuPathStrategy.coverageAtlas);
        expect(parity.drewSomething, isTrue);
        expect(parity.layerResolves, 0,
            reason:
                'nothing multisampled was allocated, so nothing is blitted');
        expect(parity.maxDeviation, lessThanOrEqualTo(0),
            reason: parity.report);
      }, skip: sparseSession.skipReason);
    });

    group('a fractional clip means the same thing on every route', () {
      test('sparse strips clip exactly as the CPU rasteriser does', () async {
        // The divergence this forbids was found on the compute route: it
        // applied the clip rectangle *exactly*, while `ScanlineFiller` - and
        // therefore the CPU renderer, the dense atlas and the sparse encoder -
        // expands it outward with floor/ceil to whole pixels. The exact cut is
        // arguably the prettier answer and it is the wrong one, because it
        // makes one route disagree with all the others.
        //
        // Sparse cannot diverge here by construction: `SparseStripGenerator`
        // *is* `ScanlineFiller` with a different sink, so it inherits the
        // rounding rather than reimplementing it. That is a claim about the
        // code, and this is the measurement that backs it - every clip edge
        // below is deliberately fractional, and the two sides are compared on
        // all 25 600 pixels.
        //
        // Nothing downstream re-applies the clip either: the sparse executor
        // sets no scissor, because the coverage it draws is already zero
        // outside the expanded rectangle.
        final DisplayList list = _holePathScene(
          antiAlias: true,
          clip: const Rect.fromLTRB(20.5, 12.25, 139.75, 147.5),
        );
        final _Parity parity = await _parity(sparseSession, list, 160);
        expect(parity.executed, GpuPathStrategy.sparseStrips);
        expect(parity.drewSomething, isTrue);
        // Observed deviation on Intel UHD Graphics: 0.
        expect(parity.maxDeviation, lessThanOrEqualTo(0),
            reason: parity.report);
      }, skip: sparseSession.skipReason);

      test('a clip that removes the shape removes it on both sides', () async {
        // The degenerate end of the same rule. An empty intersection has to
        // produce nothing rather than an encoding of nothing, and a route that
        // rounded the clip the other way could keep a sliver here.
        final DisplayList list = _holePathScene(
          antiAlias: true,
          clip: const Rect.fromLTRB(0.5, 0.25, 4.75, 4.5),
        );
        final _Parity parity = await _parity(sparseSession, list, 160);
        expect(parity.maxDeviation, lessThanOrEqualTo(0),
            reason: parity.report);
      }, skip: sparseSession.skipReason);
    });

    group('the promotion criteria that are assertions', () {
      test('a static shape costs the dense atlas one rasterisation', () {
        // The measurement that refused promotion rests on this: the dense
        // route amortises a repeated shape to a quad, so sparse is competing
        // against zero rather than against an upload. If this ever stops being
        // true the head-to-head in `gl_vector_cost_test.dart` is measuring
        // something else and its verdict has to be retaken.
        // Sparse turned off, so this measures the dense route on its own -
        // which is what the head-to-head compares against, and what the
        // repetition model is protecting.
        final _GlSession plain = _GlSession.open(disableSparseStrips: true);
        if (plain.skipReason != null) {
          markTestSkipped('no GL device: ${plain.skipReason}');
          return;
        }
        final GlOffscreenTarget target = plain.target(160, 160);
        try {
          for (var frame = 0; frame < 6; frame++) {
            target.renderDisplayList(
              _holePathScene(antiAlias: true),
              clearColor: 0xFF000000,
            );
          }
          expect(target.maskAtlas.rasterizationCount, 1,
              reason: 'six frames of one shape, one rasterisation');
          expect(target.maskAtlas.cacheHitCount, greaterThanOrEqualTo(5));
          expect(target.maskUploadCount, 1,
              reason: 'and one upload, because nothing else went dirty');
        } finally {
          target.dispose();
          plain.close();
        }
      }, skip: sparseSession.skipReason);

      test('a repeated draw is handed back to the dense atlas', () {
        // The regression test for the starvation fix, and it used to assert
        // the opposite. Before `gpu_path_repetition.dart`, a draw promoted to
        // sparse never reached the atlas, so `denseMaskCacheHit` stayed false
        // for it for ever, the "already resident" branch could never fire, and
        // sparse kept the cheaper route permanently expensive and then beat it
        // - measured at 1.141 ms against 0.865 ms on a static panel.
        //
        // Now the selector asks whether the atlas *would* be caching this draw
        // by now. The first sighting is fresh and may be promoted; a draw that
        // came back is left alone, and the atlas starts hitting.
        final GlOffscreenTarget target = sparseSession.target(160, 160);
        try {
          target.pathRepetition!.reset();
          for (var frame = 0; frame < 6; frame++) {
            target.renderDisplayList(
              _holePathScene(antiAlias: true),
              clearColor: 0xFF000000,
            );
          }
          expect(target.lastExecutedPathStrategy, GpuPathStrategy.coverageAtlas,
              reason: 'by the last frame the repeat belongs to the atlas');
          expect(target.maskAtlas.rasterizationCount, 1,
              reason: 'and the atlas rasterised it once, not once per frame');
          expect(target.maskAtlas.cacheHitCount, greaterThanOrEqualTo(3),
              reason: 'which is the cache that used to be starved');
          expect(target.pathRepetition!.cacheableCount, greaterThan(0));
        } finally {
          target.dispose();
        }
      }, skip: sparseSession.skipReason);

      test('a draw seen for the first time is still free to be promoted', () {
        // The other side of the policy: the fix must not simply disable
        // sparse. A shape that has never been seen has no dense mask to be
        // cheap against, so the cost comparison runs as before.
        final GlOffscreenTarget target = sparseSession.target(160, 160);
        try {
          target.pathRepetition!.reset();
          target.renderDisplayList(
            _holePathScene(antiAlias: true, scale: 0.97),
            clearColor: 0xFF000000,
          );
          expect(target.lastExecutedPathStrategy, GpuPathStrategy.sparseStrips,
              reason: 'first sighting: nothing is cached, so cost decides');
          expect(target.pathRepetition!.freshCount, greaterThan(0));
        } finally {
          target.dispose();
        }
      }, skip: sparseSession.skipReason);

      test('the sparse program is built once, never inside a frame', () {
        // Criterion: no shader compiled in the frame. `initialize` is called
        // when the device opens and after a recovery, and returns early once
        // initialised - so a second call from a frame would be a no-op rather
        // than a compile, and this asserts the executor reports itself ready
        // before any frame has been drawn.
        final GlRenderDevice device = sparseSession.device!;
        expect(device.experimentalSparseStripsEnabled, isTrue,
            reason: 'the executor exists before the first frame');
      }, skip: sparseSession.skipReason);
    });

    group('the sparse plan cache', () {
      test('a static scene encodes once and hits thereafter', () {
        // The claim `vector_plan_cache.dart` makes, measured on this route:
        // a path that does not change costs its analytic rasterisation once.
        // Invisible from the pixels - a cache that missed every time draws the
        // same picture - so it is counted rather than looked at.
        final GlOffscreenTarget target = sparseSession.target(160, 160);
        try {
          final VectorPlanCache<SparseStripDrawPlan>? cache =
              target.sparsePlanCache;
          expect(cache, isNotNull);
          cache!.reset();
          final DisplayList list = _holePathScene(antiAlias: true);

          target.renderDisplayList(list, clearColor: 0xFF000000);
          final int firstMisses = cache.misses;
          expect(firstMisses, greaterThan(0),
              reason: 'the first frame has nothing to hit');
          expect(cache.length, 1);

          // Five more frames of the same scene. The display list is rebuilt
          // each time, so this also pins that the key is by *content*: a
          // rebuilt-but-identical path has to hit, which is exactly what an
          // animation that rebuilds its tree every frame produces.
          for (var frame = 0; frame < 5; frame++) {
            target.renderDisplayList(
              _holePathScene(antiAlias: true),
              clearColor: 0xFF000000,
            );
          }
          expect(cache.misses, firstMisses,
              reason: 'not one further encode: $cache');
          expect(cache.hits, greaterThanOrEqualTo(5));
          expect(cache.length, 1, reason: 'one shape, one entry');
          expect(cache.evictions, 0);
        } finally {
          target.dispose();
        }
      }, skip: sparseSession.skipReason);

      test('a moving shape misses every frame without growing the cache', () {
        // The workload the LRU exists for. The key holds a device-space
        // transform, so a shape that moves produces a new key every frame; the
        // point is not that it hits - it cannot - but that the cache stays
        // bounded instead of retaining an arena per frame for ever.
        final GlOffscreenTarget target = sparseSession.target(160, 160);
        try {
          final VectorPlanCache<SparseStripDrawPlan> cache =
              target.sparsePlanCache!..reset();
          for (var frame = 0; frame < 80; frame++) {
            target.renderDisplayList(
              _holePathScene(antiAlias: true, scale: 1 - frame * 0.002),
              clearColor: 0xFF000000,
            );
          }
          expect(cache.misses, greaterThanOrEqualTo(80),
              reason: 'every frame is new geometry: $cache');
          expect(cache.length, lessThanOrEqualTo(cache.capacity));
          expect(cache.evictions, greaterThan(0),
              reason: 'the bound is what keeps this from being a leak');
        } finally {
          target.dispose();
        }
      }, skip: sparseSession.skipReason);

      test('layers at different origins do not share an entry', () {
        // The one way this recorder's key differs from the Direct3D 12 one:
        // it holds the *target-space* transform and clip, because that is the
        // space the encoding is built in. Two draws of the same shape at the
        // same device position inside differently placed layers must not share
        // an entry, or the second would be drawn at the first's offset.
        final GlOffscreenTarget target = sparseSession.target(160, 160);
        try {
          final VectorPlanCache<SparseStripDrawPlan> cache =
              target.sparsePlanCache!..reset();
          target.renderDisplayList(
            _twoLayeredCopiesScene(),
            clearColor: 0xFF000000,
          );
          expect(cache.length, 2,
              reason: 'one entry per layer origin, not one shared: $cache');
        } finally {
          target.dispose();
        }
      }, skip: sparseSession.skipReason);
    });

    group('gradients reach the sparse shader through ordinary replay', () {
      test('a linear gradient path matches the CPU ramp', () async {
        // The whole gradient path end to end and nothing explicit anywhere: a
        // `DisplayList` with a gradient paint, the player, the sink, the
        // selector, the recorder uploading the ramp through `GpuGradientCache`,
        // and the sparse shader sampling it.
        //
        // The dense atlas cannot draw a gradient at all, so this is also the
        // test that the selector *has* to promote: a fall back to coverage
        // would be a named refusal rather than a flat fill, and the assertion
        // below would see `coverageAtlas` and fail either way.
        final DisplayList list = _gradientScene(_linearGradient());
        final _Parity parity = await _parity(sparseSession, list, 64);
        expect(parity.executed, GpuPathStrategy.sparseStrips);
        expect(parity.drewSomething, isTrue);
        // Observed deviation on Intel UHD Graphics: 1. Both sides read the
        // same 256-entry `GradientLut` and interpolate between neighbours -
        // `GradientLut.sampleArgb` exists to mirror a linearly filtered
        // texture - but the GPU does that interpolation in the sampler's own
        // fixed-point sub-texel weights, so a texel boundary can round the
        // other way. One level is that rounding and nothing else; the same
        // tolerance the Direct3D 12 sparse gradient comparison declares.
        expect(parity.maxDeviation, lessThanOrEqualTo(1),
            reason: parity.report);
      }, skip: sparseSession.skipReason);

      test('a focal radial reflect gradient matches the CPU ramp', () async {
        // The other shader kind and the two spread modes the linear case does
        // not exercise: a focus off the centre, and `reflect`, where the
        // parameter is folded before it addresses the ramp. Getting the fold
        // wrong mirrors the bands instead of repeating them, which a single
        // sampled pixel would not catch and a whole-surface comparison does.
        final DisplayList list = _gradientScene(_radialGradient());
        final _Parity parity = await _parity(sparseSession, list, 64);
        expect(parity.executed, GpuPathStrategy.sparseStrips);
        expect(parity.drewSomething, isTrue);
        // Observed deviation on Intel UHD Graphics: **2**, and the extra level
        // over the linear case is attributable rather than slack. Coverage now
        // comes from `NativeStripRasterizer`, which computes it from geometry
        // instead of re-encoding `ScanlineFiller`'s spans; the two agree to
        // within one level (see `test/rendering/gpu/vector/`), and on a curved
        // edge that level multiplies against the ramp's own level of sampler
        // rounding. Solid scenes are unaffected and stay at 0.
        expect(parity.maxDeviation, lessThanOrEqualTo(2),
            reason: parity.report);
      }, skip: sparseSession.skipReason);

      test('a gradient rectangle takes the path route and matches', () async {
        // A rectangle normally goes down the solid pipeline, which modulates
        // one vertex colour and has nowhere to put a ramp. `GpuRasterSink`
        // sends a gradient rectangle through the mask route instead, so it
        // reaches the sparse encoder like any other shape - and a gradient
        // rectangle is what a real interface actually draws.
        final DisplayList list = _gradientScene(
          _linearGradient(),
          asRectangle: true,
        );
        final _Parity parity = await _parity(sparseSession, list, 64);
        expect(parity.executed, GpuPathStrategy.sparseStrips);
        expect(parity.drewSomething, isTrue);
        // Observed deviation on Intel UHD Graphics: 1.
        expect(parity.maxDeviation, lessThanOrEqualTo(1),
            reason: parity.report);
      }, skip: sparseSession.skipReason);

      test('a gradient inside a saveLayer is evaluated in layer space',
          () async {
        // The ramp is addressed in *target* space, so the layer's whole-pixel
        // origin has to be folded into both matrices. Without it the gradient
        // would be evaluated at device coordinates while its pixels were
        // written at layer-local ones, and the ramp would slide by the layer's
        // position - a shift no single-pixel assertion would pin down.
        final DisplayList list = _gradientScene(
          _linearGradient(),
          insideLayerAlpha: 0x80,
        );
        final _Parity parity = await _parity(sparseSession, list, 64);
        expect(parity.executed, GpuPathStrategy.sparseStrips);
        expect(parity.drewSomething, isTrue);
        // Observed deviation on Intel UHD Graphics: 1.
        expect(parity.maxDeviation, lessThanOrEqualTo(1),
            reason: parity.report);
      }, skip: sparseSession.skipReason);

      test('the ramp is uploaded once and reused across draws', () {
        // A cache that re-uploaded per draw would produce identical pixels and
        // spend the frame budget doing it, so this is invisible from the image
        // and is asserted on the cache itself.
        final GlOffscreenTarget target = sparseSession.target(64, 64);
        try {
          final GpuGradientCache? cache = target.gradientCache;
          expect(cache, isNotNull,
              reason: 'a sparse-capable target owns a gradient cache');
          expect(cache!.length, 0);
          final DisplayList list = _gradientScene(_linearGradient());
          target.renderDisplayList(list, clearColor: 0xFF000000);
          expect(cache.length, 1);
          target.renderDisplayList(list, clearColor: 0xFF000000);
          expect(cache.length, 1,
              reason: 'the same gradient value must resolve to the same '
                  'resident texture rather than uploading a second ramp');
        } finally {
          target.dispose();
        }
      }, skip: sparseSession.skipReason);

      test('a device with no sparse executor refuses a gradient by name', () {
        // The invariant the player's marker interface used to protect, now
        // enforced by the sink so the message can name the backend and say
        // what is missing. A flat fill would read as a paint bug.
        // The kill switch doing the job it exists for: a build with sparse
        // turned off has no route that can sample a ramp, and has to say so by
        // name rather than draw a flat fill.
        final _GlSession plain = _GlSession.open(disableSparseStrips: true);
        if (plain.skipReason != null) {
          markTestSkipped('no GL device: ${plain.skipReason}');
          return;
        }
        final GlOffscreenTarget target = plain.target(64, 64);
        try {
          expect(target.gradientCache, isNull);
          expect(
            () => target.renderDisplayList(
              _gradientScene(_linearGradient()),
              clearColor: 0xFF000000,
            ),
            throwsA(
              isA<UnsupportedCapabilityError>().having(
                (UnsupportedCapabilityError error) => '$error',
                'message',
                allOf(
                  contains('gradient'),
                  contains('flat fill'),
                ),
              ),
            ),
          );
        } finally {
          target.dispose();
          plain.close();
        }
      }, skip: sparseSession.skipReason);
    });
  });
}

Gradient _linearGradient() => LinearGradient(
      startX: 8,
      startY: 8,
      endX: 40,
      endY: 24,
      spread: GradientSpread.repeat,
      stops: const <GradientStop>[
        GradientStop(0, 0xFF102080),
        GradientStop(0.35, 0x80E04020),
        GradientStop(1, 0xFF20C060),
      ],
    );

Gradient _radialGradient() => RadialGradient(
      centerX: 32,
      centerY: 32,
      radius: 20,
      focusX: 24,
      focusY: 26,
      spread: GradientSpread.reflect,
      stops: const <GradientStop>[
        GradientStop(0, 0xFFFFFFFF),
        GradientStop(0.5, 0xA03060C0),
        GradientStop(1, 0xFF201040),
      ],
    );

/// A 64x64 scene whose only ink is one gradient-filled shape.
///
/// Fractional edges on purpose: a gradient with whole-pixel bounds would agree
/// even if one side had lost its coverage fringe.
DisplayList _gradientScene(
  Gradient gradient, {
  bool asRectangle = false,
  int? insideLayerAlpha,
}) {
  final DisplayList list = DisplayList();
  final int paint = list.addPaint(
    // Deliberately a colour nothing should ever show. Both renderers read the
    // ramp's own alpha and ignore this one, so if it appears anywhere the
    // gradient was flattened to its fallback.
    colorArgb: 0xFFFF00FF,
    gradient: gradient,
  );
  void draw() {
    if (asRectangle) {
      list.drawRect(6.5, 6.5, 57.5, 57.5, paint);
      return;
    }
    final PathBuilder builder = PathBuilder()
      ..moveTo(6.5, 6.5)
      ..lineTo(57.5, 14.5)
      ..lineTo(48.5, 57.5)
      ..lineTo(10.5, 44.5)
      ..close();
    list.drawPath(list.addPath(builder.build()), paint);
  }

  if (insideLayerAlpha == null) {
    draw();
    return list;
  }
  final int layerPaint = list.addPaint(
    colorArgb: (insideLayerAlpha << 24) | 0xFFFFFF,
    antiAlias: false,
  );
  list.saveLayer(4, 4, 60, 60, layerPaint);
  draw();
  list.restore();
  return list;
}

/// The scene every automatic-promotion comparison uses.
///
/// An outer contour with an inner one wound against it: a hole under both fill
/// rules, and a topology `CpuPathTessellator` refuses by name - which is what
/// takes approach B out of the running without any flag.
DisplayList _holePathScene({
  required bool antiAlias,
  double scale = 1,
  bool diagonal = false,
  int? insideLayerAlpha,
  double layerSize = 160,
  Rect? clip,
}) {
  final PathBuilder builder = PathBuilder();
  if (diagonal) {
    // The same topology - an outer contour with an inner one wound against it,
    // so the tessellator still refuses it - but with every edge at 45 degrees.
    // This is the scene that tells a *general* answer from a lucky one: on an
    // axis-aligned half-pixel edge a 4x sample pattern happens to land on
    // exactly the analytic coverage, and on a diagonal it cannot.
    void diamond(double cx, double cy, double r, {required bool clockwise}) {
      builder.moveTo(cx, cy - r);
      if (clockwise) {
        builder
          ..lineTo(cx + r, cy)
          ..lineTo(cx, cy + r)
          ..lineTo(cx - r, cy);
      } else {
        builder
          ..lineTo(cx - r, cy)
          ..lineTo(cx, cy + r)
          ..lineTo(cx + r, cy);
      }
      builder.close();
    }

    diamond(80.37, 80.11, 71.23, clockwise: true);
    diamond(80.37, 80.11, 29.71, clockwise: false);
    final DisplayList list = DisplayList();
    final int paint = list.addPaint(
      colorArgb: 0xFF3080C0,
      antiAlias: antiAlias,
    );
    list.drawPath(list.addPath(builder.build()), paint);
    return list;
  }
  void contour(Rect rect, {required bool clockwise}) {
    builder.moveTo(rect.left * scale, rect.top * scale);
    if (clockwise) {
      builder
        ..lineTo(rect.right * scale, rect.top * scale)
        ..lineTo(rect.right * scale, rect.bottom * scale)
        ..lineTo(rect.left * scale, rect.bottom * scale);
    } else {
      builder
        ..lineTo(rect.left * scale, rect.bottom * scale)
        ..lineTo(rect.right * scale, rect.bottom * scale)
        ..lineTo(rect.right * scale, rect.top * scale);
    }
    builder.close();
  }

  // 143x143 device pixels, so the dense mask this shape would need is 20 449
  // bytes - past the 16 KiB threshold at which the selector prefers stencil to
  // rasterising and uploading one. Fractional edges on purpose for the
  // antialiased variants: a comparison between two coverage paths that only
  // ever saw whole pixels would agree even if one of them had no fringe.
  contour(const Rect.fromLTRB(8.5, 8.5, 151.5, 151.5), clockwise: true);
  contour(const Rect.fromLTRB(48, 48, 112, 112), clockwise: false);

  final DisplayList list = DisplayList();
  final int paint = list.addPaint(
    colorArgb: 0xFF3080C0,
    antiAlias: antiAlias,
  );
  final int path = list.addPath(builder.build());
  if (clip != null) {
    // Fractional on every edge on purpose. Both routes take their coverage
    // from one `ScanlineFiller`, which expands a clip *outward* to whole
    // pixels, so a fractional clip must produce identical pixels rather than a
    // tidier exact-rectangle cut on whichever side computes it later.
    list
      ..save()
      ..clipRect(clip.left, clip.top, clip.right, clip.bottom)
      ..drawPath(path, paint)
      ..restore();
    return list;
  }
  if (insideLayerAlpha == null) {
    list.drawPath(path, paint);
    return list;
  }
  final int layerPaint = list.addPaint(
    colorArgb: (insideLayerAlpha << 24) | 0xFFFFFF,
    antiAlias: false,
  );
  list
    ..saveLayer(0, 0, layerSize, layerSize, layerPaint)
    ..drawPath(path, paint)
    ..restore();
  return list;
}

/// One display list down both rasterisers, compared pixel by pixel.
final class _Parity {
  const _Parity({
    required this.maxDeviation,
    required this.differingPixels,
    required this.executed,
    required this.candidate,
    required this.drewSomething,
    required this.report,
    required this.layerResolves,
    this.edgeRow = '',
  });

  /// Multisample resolves the device issued for layer targets while rendering
  /// this scene. Invisible from the pixels when correct; a missing one is not.
  final int layerResolves;

  /// A slice of one boundary row, both sides, for reading an edge by eye.
  final String edgeRow;

  final int maxDeviation;
  final int differingPixels;

  /// The strategy that really produced the GPU pixels, and the one proposed.
  final GpuPathStrategy? executed;
  final GpuPathStrategy? candidate;

  /// False when the scene is blank, which would make any comparison vacuous.
  final bool drewSomething;

  final String report;
}

Future<_Parity> _parity(
  _GlSession session,
  DisplayList list,
  int size,
) async {
  final MemoryRenderTarget cpu = MemoryRenderTarget(MemorySurfaceDescriptor(
    pixelWidth: size,
    pixelHeight: size,
    format: PixelFormat.rgba8888Premultiplied,
  ));
  final GlOffscreenTarget gpu = session.target(size, size);
  final int resolvesBefore = session.device!.layerResolveCount;
  try {
    await cpu.renderDisplayList(list, clearColor: 0xFF000000);
    final PresentResult result =
        await gpu.renderDisplayList(list, clearColor: 0xFF000000);
    expect(result.status, PresentStatus.presented,
        reason: '${result.diagnostic}');

    var maxDeviation = 0;
    var differing = 0;
    var drew = false;
    final List<String> lines = <String>[];
    final List<int> background = _pixel(cpu.framebuffer, 0, 0);
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final List<int> a = _pixel(cpu.framebuffer, x, y);
        final List<int> b = _pixel(gpu.framebuffer, x, y);
        for (var c = 0; c < 4; c++) {
          if (a[c] != background[c]) drew = true;
        }
        var deviation = 0;
        for (var c = 0; c < 4; c++) {
          final int difference = (a[c] - b[c]).abs();
          if (difference > deviation) deviation = difference;
        }
        if (deviation == 0) continue;
        differing++;
        if (deviation > maxDeviation) maxDeviation = deviation;
        if (lines.length < 12) lines.add('($x, $y): cpu $a, gl $b');
      }
    }
    final StringBuffer edge = StringBuffer();
    final int probeY = size ~/ 4;
    for (var x = 0; x < size; x++) {
      final List<int> a = _pixel(cpu.framebuffer, x, probeY);
      final List<int> b = _pixel(gpu.framebuffer, x, probeY);
      if (a[2] == 0 && b[2] == 0) continue;
      edge.write('x=$x cpu=${a[2]} gl=${b[2]} | ');
    }
    return _Parity(
      layerResolves: session.device!.layerResolveCount - resolvesBefore,
      edgeRow: edge.toString(),
      maxDeviation: maxDeviation,
      differingPixels: differing,
      executed: gpu.lastExecutedPathStrategy,
      candidate: gpu.lastCandidatePathStrategy,
      drewSomething: drew,
      report: 'the CPU and OpenGL disagree by up to $maxDeviation levels on '
          '$differing pixels; candidate ${gpu.lastCandidatePathStrategy}, '
          'executed ${gpu.lastExecutedPathStrategy}\n${lines.join('\n')}\n'
          'row $probeY, blue channel: $edge',
    );
  } finally {
    cpu.dispose();
    gpu.dispose();
  }
}

final class _NoLayerAllocator implements GpuLayerTargetAllocator {
  @override
  GpuLayerTarget acquireLayerTarget(int width, int height) =>
      throw StateError('this test does not open layers');

  @override
  void releaseLayerTarget(GpuLayerTarget target) {}
}

/// One GL device for the whole file, or the reason there is none.
///
/// Shared because creating a context costs tens of milliseconds and, on
/// Windows, a window: doing it per test would make the suite's cost depend on
/// how many assertions it contains.
final class _GlSession {
  _GlSession._(this.device, this.context, this.skipReason, this._surface);

  final GlRenderDevice? device;
  final GlContext? context;

  /// Null when the device opened. A string - which `skip:` accepts - when it
  /// did not, so the report names the driver that was missing.
  final String? skipReason;

  final Win32GlSurface? _surface;

  static _GlSession open({
    bool enableExperimentalSparseStrips = false,
    bool disableSparseStrips = false,
    bool enableExperimentalStencilCover = false,
    bool enableExperimentalCpuTessellation = false,
  }) {
    try {
      return Platform.isWindows
          ? _openWindows(
              enableExperimentalSparseStrips,
              disableSparseStrips,
              enableExperimentalStencilCover,
              enableExperimentalCpuTessellation,
            )
          : _openEgl(
              enableExperimentalSparseStrips,
              disableSparseStrips,
              enableExperimentalStencilCover,
              enableExperimentalCpuTessellation,
            );
    } on Object catch (error) {
      return _GlSession._(
          null, null, 'opening a GL device threw: $error', null);
    }
  }

  static _GlSession _openWindows(
    bool enableExperimentalSparseStrips,
    bool disableSparseStrips,
    bool enableExperimentalStencilCover,
    bool enableExperimentalCpuTessellation,
  ) {
    final attempt = Win32GlSurface.hidden();
    final surface = attempt.surface;
    if (surface == null) {
      return _GlSession._(
          null, null, 'no GL surface: ${attempt.diagnostics.join('; ')}', null);
    }
    final contextAttempt = surface.createContext();
    final context = contextAttempt.context;
    if (context == null) {
      surface.dispose();
      return _GlSession._(null, null,
          'no GL context: ${contextAttempt.diagnostics.join('; ')}', null);
    }
    try {
      return _GlSession._(
        GlRendererBackend.adoptContext(
          context,
          surface.glLibrary,
          enableExperimentalSparseStrips: enableExperimentalSparseStrips,
          sparseStrips: disableSparseStrips
              ? GlSparseStripsPolicy.disabled
              : GlSparseStripsPolicy.auto,
          enableExperimentalStencilCover: enableExperimentalStencilCover,
          enableExperimentalCpuTessellation: enableExperimentalCpuTessellation,
        ),
        context,
        null,
        surface,
      );
    } on BackendSelectionError catch (error) {
      surface.dispose();
      return _GlSession._(null, null, 'no GL device: $error', null);
    }
  }

  static _GlSession _openEgl(
    bool enableExperimentalSparseStrips,
    bool disableSparseStrips,
    bool enableExperimentalStencilCover,
    bool enableExperimentalCpuTessellation,
  ) {
    final load = GlLibrary.open();
    if (!load.isLoaded) {
      return _GlSession._(
          null, null, 'no GL library: ${load.attempted.join(', ')}', null);
    }
    final attempt = const GlContextFactory()
        .create(width: 16, height: 16, glLibrary: load.library!);
    final context = attempt.context;
    if (context == null) {
      return _GlSession._(null, null,
          'no EGL context: ${attempt.diagnostics.join('; ')}', null);
    }
    try {
      return _GlSession._(
        GlRendererBackend.adoptContext(
          context,
          load.library!,
          enableExperimentalSparseStrips: enableExperimentalSparseStrips,
          sparseStrips: disableSparseStrips
              ? GlSparseStripsPolicy.disabled
              : GlSparseStripsPolicy.auto,
          enableExperimentalStencilCover: enableExperimentalStencilCover,
          enableExperimentalCpuTessellation: enableExperimentalCpuTessellation,
        ),
        context,
        null,
        null,
      );
    } on BackendSelectionError catch (error) {
      return _GlSession._(null, null, 'no GL device: $error', null);
    }
  }

  GlOffscreenTarget target(int width, int height) =>
      device!.createTarget(MemorySurfaceDescriptor(
        pixelWidth: width,
        pixelHeight: height,
        format: PixelFormat.rgba8888Premultiplied,
      )) as GlOffscreenTarget;

  void close() {
    device?.dispose();
    _surface?.dispose();
  }
}

List<int> _pixel(Framebuffer framebuffer, int x, int y) {
  final offset = y * framebuffer.bytesPerRow + x * 4;
  return <int>[
    framebuffer.pixels[offset],
    framebuffer.pixels[offset + 1],
    framebuffer.pixels[offset + 2],
    framebuffer.pixels[offset + 3],
  ];
}

List<int> _rgba(Uint8List pixels, int width, int x, int y) {
  final int offset = (y * width + x) * 4;
  return pixels.sublist(offset, offset + 4);
}

void _expectSparseGradientParity(
  GlRenderDevice device,
  Gradient gradient,
  ReplayPaint paint, {
  required Offset targetOriginInDevice,
  required int yFlip,
}) {
  const int width = 16;
  const int height = 16;
  const int lutSize = 64;
  final _SparsePixelSurface surface = _SparsePixelSurface.create(
    device,
    width,
    height,
  );
  final GpuGradientCache cache = GpuGradientCache(
    allocator: device,
    lutSize: lutSize,
  );
  try {
    final GpuGradientBinding binding = cache.resolve(gradient);
    final GpuGradientShaderParameters parameters =
        GpuGradientShaderParameters.fromPaint(
      paint,
      targetOriginInDevice: targetOriginInDevice,
    );
    final SparseStripDrawPlan plan = SparseStripDrawPlan();
    for (var y = 0; y < height; y += kStripHeight) {
      plan.append(
        StripBuffer()..addFill(0, y, width),
        materialIndex: 0,
      );
    }
    surface.clear();
    device.submitSparseStrips(
      plan,
      materials: <SparseGlMaterial>[
        SparseGlMaterial.gradient(
          gradientBinding: binding,
          gradientParameters: parameters,
          blendMode: blendModeSrc,
        ),
      ],
      viewportWidth: width,
      viewportHeight: height,
      yFlip: yFlip,
      surfaceFramebuffer: surface.framebuffer,
    );
    final Uint8List actual = surface.readTargetOrder(yFlip: yFlip);
    final GradientLut lut = GradientLut(gradient, size: lutSize);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final int expected = lut.sampleArgb(
          parameters.parameterAtTarget(x + 0.5, y + 0.5),
        );
        final int alpha = expected >> 24 & 0xFF;
        final List<int> channels = <int>[
          premultiplyChannel(expected >> 16 & 0xFF, alpha),
          premultiplyChannel(expected >> 8 & 0xFF, alpha),
          premultiplyChannel(expected & 0xFF, alpha),
          alpha,
        ];
        final int offset = (y * width + x) * 4;
        for (var channel = 0; channel < 4; channel++) {
          final int difference =
              (actual[offset + channel] - channels[channel]).abs();
          if (difference > 2) {
            fail(
              'sparse gradient differs at ($x, $y) channel $channel: '
              'GPU=${actual[offset + channel]}, reference=${channels[channel]}, '
              'delta=$difference, yFlip=$yFlip, origin=$targetOriginInDevice',
            );
          }
        }
      }
    }
  } finally {
    cache.clear();
    surface.dispose();
  }
}

final class _SparsePixelSurface {
  _SparsePixelSurface._(
    this.device,
    this.width,
    this.height,
    this.texture,
    this.framebuffer,
    this.heap,
  );

  factory _SparsePixelSurface.create(
    GlRenderDevice device,
    int width,
    int height,
  ) {
    if (!device.makeCurrentOrLose()) {
      throw StateError('the GL context could not be made current');
    }
    final GlApi gl = device.api;
    final Pointer<Uint32> names = device.scratchNames;
    gl.genTextures(1, names);
    final int texture = names[0];
    gl.bindTexture(glTexture2D, texture);
    gl.texParameteri(glTexture2D, glTextureMinFilter, glNearest);
    gl.texParameteri(glTexture2D, glTextureMagFilter, glNearest);
    gl.texParameteri(glTexture2D, glTextureWrapS, glClampToEdge);
    gl.texParameteri(glTexture2D, glTextureWrapT, glClampToEdge);
    gl.texImage2D(
      glTexture2D,
      0,
      glRgba8,
      width,
      height,
      0,
      glRgba,
      glUnsignedByte,
      nullptr,
    );
    gl.genFramebuffers(1, names);
    final int framebuffer = names[0];
    gl.bindFramebuffer(glFramebuffer, framebuffer);
    gl.framebufferTexture2D(
      glFramebuffer,
      glColorAttachment0,
      glTexture2D,
      texture,
      0,
    );
    final int status = gl.checkFramebufferStatus(glFramebuffer);
    if (status != glFramebufferComplete) {
      names[0] = framebuffer;
      gl.deleteFramebuffers(1, names);
      names[0] = texture;
      gl.deleteTextures(1, names);
      throw StateError(
        'gradient parity framebuffer is incomplete: '
        '0x${status.toRadixString(16)}',
      );
    }
    final NativeHeap? heap = NativeHeap.tryBind(null);
    if (heap == null) {
      names[0] = framebuffer;
      gl.deleteFramebuffers(1, names);
      names[0] = texture;
      gl.deleteTextures(1, names);
      throw StateError('no native heap for gradient parity readback');
    }
    return _SparsePixelSurface._(
      device,
      width,
      height,
      texture,
      framebuffer,
      heap,
    );
  }

  final GlRenderDevice device;
  final int width;
  final int height;
  final int texture;
  final int framebuffer;
  final NativeHeap heap;

  void clear() {
    device.api
      ..bindFramebuffer(glFramebuffer, framebuffer)
      ..disable(glScissorTest)
      ..clearColor(0, 0, 0, 0)
      ..clear(glColorBufferBit);
  }

  Uint8List readTargetOrder({required int yFlip}) {
    final int byteCount = width * height * 4;
    final Pointer<Uint8> native = heap.allocate<Uint8>(byteCount);
    try {
      device.api
        ..bindFramebuffer(glFramebuffer, framebuffer)
        ..pixelStorei(glPackAlignment, 1)
        ..finish()
        ..readPixels(
          0,
          0,
          width,
          height,
          glRgba,
          glUnsignedByte,
          native.cast<Void>(),
        );
      final Uint8List source = native.asTypedList(byteCount);
      final Uint8List result = Uint8List(byteCount);
      for (var targetY = 0; targetY < height; targetY++) {
        final int framebufferY = yFlip == 0 ? height - 1 - targetY : targetY;
        result.setRange(
          targetY * width * 4,
          (targetY + 1) * width * 4,
          source,
          framebufferY * width * 4,
        );
      }
      return result;
    } finally {
      heap.release(native);
    }
  }

  void dispose() {
    if (!device.makeCurrentOrLose()) return;
    final Pointer<Uint32> names = device.scratchNames;
    names[0] = framebuffer;
    device.api.deleteFramebuffers(1, names);
    names[0] = texture;
    device.api.deleteTextures(1, names);
  }
}

/// One shape drawn twice at the same device position, in two layers placed
/// differently.
///
/// The encodings are built in *target* space, so these two draws must not
/// share a cache entry even though their device transforms are identical.
DisplayList _twoLayeredCopiesScene() {
  final PathBuilder builder = PathBuilder()
    ..moveTo(10.5, 10.5)
    ..lineTo(60.5, 14.5)
    ..lineTo(52.5, 62.5)
    ..lineTo(12.5, 54.5)
    ..close();
  final DisplayList list = DisplayList();
  final int paint = list.addPaint(colorArgb: 0xFF3080C0);
  final int path = list.addPath(builder.build());
  final int layerPaint = list.addPaint(colorArgb: 0x80FFFFFF, antiAlias: false);
  // Both layers contain the shape, so both actually draw it; only their
  // whole-pixel origins differ, which is the fact under test.
  for (final double origin in <double>[0, 5]) {
    list
      ..saveLayer(origin, origin, origin + 72, origin + 72, layerPaint)
      ..drawPath(path, paint)
      ..restore();
  }
  return list;
}
