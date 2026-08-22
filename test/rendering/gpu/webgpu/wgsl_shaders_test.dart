/// The pure half of the WebGPU backend, checked with no browser and no GPU.
///
/// `wgsl_shaders.dart` was split from the interop precisely so these facts
/// could be pinned on the VM, where CI actually runs: the shader module's
/// entry points, the mapping tables the pipelines are built from, the vertex
/// layout's agreement with the batcher, and the clear-colour channel order.
/// None of these can drift without a frame being subtly wrong on a page, and
/// every one of them is invisible from a passing browser test on a machine
/// whose GPU happens to forgive the mistake.
///
/// What this file cannot check is whether the WGSL *compiles* - only a
/// browser's own compiler can say, and `webgpu_device_test.dart` asks it. The
/// two files together are the same split the WebGL backend gets from
/// `gl_shaders.dart` being importable on the VM while its compilation is
/// checked on a device.
library;

import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_pipeline.dart';
import 'package:dart_ui/src/rendering/gpu/webgpu/wgsl_shaders.dart';
import 'package:test/test.dart';

void main() {
  group('the shader module source', () {
    test('declares the vertex entry point and all three fragment ones', () {
      expect(kWgslShaderModuleSource, contains('fn $kWgslVertexEntryPoint('));
      for (final GpuPipelineKind kind in GpuPipelineKind.values) {
        expect(
          kWgslShaderModuleSource,
          contains('fn ${wgslFragmentEntryPoint(kind)}('),
          reason: 'a pipeline for ${kind.name} names this entry point in its '
              'descriptor, and WebGPU validates the name against the module',
        );
      }
    });

    test('carries the coverage term, which is the antialiasing', () {
      // The same function name gl_shaders.dart uses, on purpose: the term is
      // the translated GLSL, and a module that lost it would draw hard edges
      // that read as a driver difference rather than a missing multiply.
      expect(kWgslShaderModuleSource, contains('fn boxCoverage('));
      expect(kWgslShaderModuleSource, contains('boxCoverage(in.shapeRect'));
    });

    test('has no yFlip, by design rather than omission', () {
      // WebGPU's framebuffer origin is the top-left corner, so the projection
      // that is right for the canvas is right for a layer texture too - the
      // whole argument is in wgsl_shaders.dart. A uniform named anything like
      // yFlip reappearing here means someone ported the GL shader afresh and
      // reintroduced a flip that would draw every layer upside down. The
      // comments are stripped first: the source is allowed - encouraged - to
      // *explain* the absent flip, and only code can reintroduce one.
      final String code = kWgslShaderModuleSource
          .split('\n')
          .where((String line) => !line.trimLeft().startsWith('//'))
          .join('\n');
      expect(code.toLowerCase(), isNot(contains('yflip')));
    });
  });

  group('the blend factor names', () {
    test('cover every factor the renderer has, with WebGPU spellings', () {
      expect(webGpuBlendFactorName(GpuBlendFactor.zero), 'zero');
      expect(webGpuBlendFactorName(GpuBlendFactor.one), 'one');
      expect(
        webGpuBlendFactorName(GpuBlendFactor.oneMinusSrcAlpha),
        'one-minus-src-alpha',
      );
    });

    test('compose with gpuBlendForMode for every display-list mode', () {
      // The pipeline cache builds descriptors from exactly this composition,
      // so this is the whole translation table for a batch's blend state.
      final GpuBlendState srcOver = gpuBlendForMode(blendModeSrcOver);
      expect(webGpuBlendFactorName(srcOver.source), 'one');
      expect(
        webGpuBlendFactorName(srcOver.destination),
        'one-minus-src-alpha',
        reason: 'premultiplied source-over, the compositor\'s default',
      );

      final GpuBlendState src = gpuBlendForMode(blendModeSrc);
      expect(webGpuBlendFactorName(src.source), 'one');
      expect(webGpuBlendFactorName(src.destination), 'zero');

      final GpuBlendState plus = gpuBlendForMode(blendModePlus);
      expect(webGpuBlendFactorName(plus.source), 'one');
      expect(webGpuBlendFactorName(plus.destination), 'one');
    });
  });

  group('the vertex layout', () {
    test('agrees with the batcher about stride and offsets', () {
      // These are derived from the same kGpu* constants the vertex buffer
      // writes with, so a disagreement here means the derivation itself was
      // edited - which is the one way this backend could read a colour out of
      // a position.
      expect(kWebGpuVertexStrideBytes, kGpuFloatsPerVertex * 4);
      expect(kWebGpuPositionOffsetBytes, 0);
      expect(kWebGpuTexCoordOffsetBytes, 8);
      expect(kWebGpuColorOffsetBytes, 16);
      expect(kWebGpuShapeRectOffsetBytes, 32);
    });
  });

  group('the uniform slices', () {
    test('stride satisfies the specification\'s dynamic-offset alignment', () {
      // 256 is minUniformBufferOffsetAlignment's default; every dynamic
      // offset the submit loop passes is a multiple of the stride, so the
      // stride itself must be a multiple of the alignment.
      expect(kWebGpuUniformSliceStride % 256, 0);
      expect(
        kWebGpuUniformSliceSize,
        lessThanOrEqualTo(kWebGpuUniformSliceStride),
      );
      // A vec2f viewport: two 32-bit floats.
      expect(kWebGpuUniformSliceSize, 8);
    });
  });

  group('the clear value', () {
    test('unpacks the packed BGRA int in the channel order GL uses', () {
      // The same extraction WebGlRenderDevice.submit performs before its
      // clearColor call. Getting this wrong renders a red clear blue and
      // nothing else fails.
      final ({double r, double g, double b, double a}) value =
          webGpuClearValue(0xFF010203);
      expect(value.a, 1.0);
      expect(value.r, closeTo(1 / 255, 1e-9));
      expect(value.g, closeTo(2 / 255, 1e-9));
      expect(value.b, closeTo(3 / 255, 1e-9));
    });

    test('a transparent black clears to all zeroes', () {
      final ({double r, double g, double b, double a}) value =
          webGpuClearValue(0x00000000);
      expect(value.r, 0);
      expect(value.g, 0);
      expect(value.b, 0);
      expect(value.a, 0,
          reason: 'a layer pass clears its target to transparency through '
              'exactly this value');
    });
  });
}
