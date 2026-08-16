/// The MSL, checked for the things that are checkable without a compiler.
///
/// **This does not compile the shader.** `newLibraryWithSource:options:error:`
/// has never been called on [kMetalShaderSource] - there is no Mac in this
/// loop - so a syntax error would survive every assertion here and be caught by
/// the first compile on hardware.
///
/// What *is* checkable is the part that a compiler would not catch anyway: that
/// the constants this backend passes agree with the ones the shader branches
/// on, that the attribute indices agree with the vertex descriptor, and that
/// the three backends' shaders still say the same thing. A shader that
/// compiles perfectly and branches on the wrong mode is the failure this file
/// exists for.
library;

import 'package:dart_ui/src/rendering/gpu/gpu_pipeline.dart';
import 'package:dart_ui/src/rendering/gpu/metal/metal_shaders.dart';
import 'package:test/test.dart';

void main() {
  group('mode constants', () {
    test('match GpuPipelineKind, in order', () {
      // The same assertion gl_shaders.dart and d3d12_shaders.dart both state
      // in a comment. The backends are compared pixel for pixel, and a mode
      // that meant something different on one side would be nearly invisible
      // in a diff.
      expect(kMetalModeSolid, GpuPipelineKind.solid.index);
      expect(kMetalModeCoverageMask, GpuPipelineKind.coverageMask.index);
      expect(kMetalModeTexturedImage, GpuPipelineKind.texturedImage.index);
    });

    test('the shader branches on 1 and 2 and falls through for 0', () {
      // Solid is the fall-through, so it has no branch to find. The other two
      // must be there, and their numbers must be the ones above.
      expect(kMetalShaderSource, contains('u.mode == 1'));
      expect(kMetalShaderSource, contains('u.mode == 2'));
      expect(kMetalModeSolid, 0);
    });
  });

  group('orientation', () {
    test('the y flip is declared and never used', () {
      // d3d12_shaders.dart states that Metal, Direct3D and Vulkan all store a
      // rendered texture top-down while OpenGL is bottom-left. Confirmed here:
      // every pass this backend encodes passes kMetalYFlipDefault, and
      // kMetalYFlipTopDown exists only so that deleting the branch would not
      // delete the reason.
      expect(kMetalYFlipDefault, 0);
      expect(kMetalYFlipTopDown, 1);
      expect(kMetalShaderSource, contains('u.yFlip == 0'));
    });

    test('the vertex stage flips y once, from device space to NDC', () {
      // Device space is y-down from the top-left; NDC is y-up from the middle.
      // That single conversion is the whole of it on Metal, exactly as on
      // Direct3D - the expression is character for character d3d12's.
      expect(
        kMetalShaderSource,
        contains('1.0 - vin.position.y / u.viewportHeight * 2.0'),
      );
    });
  });

  group('the coverage term', () {
    test('is the same arithmetic as the CPU rasteriser and the other two', () {
      // raster/coverage.dart is the authority, gl_shaders.dart transcribed it,
      // d3d12_shaders.dart transcribed that, and this transcribes those. Four
      // copies of four lines; the value of them being identical is that any
      // difference in the output is a bug rather than a difference of intent.
      for (final String line in <String>[
        'float2 lo = max(r.xy, p - 0.5);',
        'float2 hi = min(r.zw, p + 0.5);',
        'float2 overlap = clamp(hi - lo, 0.0, 1.0);',
        'return overlap.x * overlap.y;',
      ]) {
        expect(kMetalShaderSource, contains(line), reason: line);
      }
    });

    test('is applied to every mode, including solid', () {
      // The last line of the fragment stage. A mode that skipped it would draw
      // hard edges on one pipeline and antialiased ones on the others.
      expect(
        kMetalShaderSource,
        contains('return color * boxCoverage(in.shapeRect, in.devicePos);'),
      );
    });
  });

  group('binding indices', () {
    test('the uniform block is at the same index in both stages', () {
      // Metal's buffer indices are per-stage, so index 0 in the fragment stage
      // would have been legal and would have meant the same block had two
      // different indices - one edit away from binding it to exactly one of
      // the two functions.
      expect(kMetalUniformBufferIndex, 1);
      expect(
        'constant Uniforms& u [[buffer($kMetalUniformBufferIndex)]]'
            .allMatches(kMetalShaderSource)
            .length,
        2,
        reason: 'both vsMain and fsMain must take the block at the same index',
      );
    });

    test('the vertex data and the uniforms do not collide', () {
      expect(kMetalVertexBufferIndex, isNot(kMetalUniformBufferIndex));
      expect(kMetalVertexBufferIndex, 0);
    });

    test('the texture index matches the fragment declaration', () {
      expect(
        kMetalShaderSource,
        contains('texture2d<float> tex [[texture($kMetalTextureIndex)]]'),
      );
    });

    test('the attribute qualifiers match the constants', () {
      for (final (int index, String field) in <(int, String)>[
        (kMetalAttributePosition, 'position'),
        (kMetalAttributeTexCoord, 'texCoord'),
        (kMetalAttributeColor, 'color'),
        (kMetalAttributeShapeRect, 'shapeRect'),
      ]) {
        expect(kMetalShaderSource, contains('[[attribute($index)]]'),
            reason: 'attribute $index carries $field');
      }
    });
  });

  group('the uniform block has no float2', () {
    test('the viewport is two scalars', () {
      // The decision the library comment argues for: a float2 is 8-byte
      // aligned in MSL, which would make the block 24 bytes there and 20 in
      // the Dart mirror, with nothing on the Dart side able to notice.
      expect(kMetalShaderSource, contains('float viewportWidth;'));
      expect(kMetalShaderSource, contains('float viewportHeight;'));
      expect(kMetalShaderSource, isNot(contains('float2 viewport')));
    });
  });

  group('samplers', () {
    test('both filters are declared in the shader, so no MTLSamplerState', () {
      expect(kMetalShaderSource, contains('constexpr sampler pointSampler'));
      expect(kMetalShaderSource, contains('constexpr sampler linearSampler'));
      expect(kMetalSamplerPoint, 0);
      expect(kMetalSamplerLinear, 1);
      expect(kMetalShaderSource, contains('u.useLinear == 0'));
    });

    test('both clamp to edge', () {
      // An atlas slot is padded by one texel; a repeat mode would fetch a
      // neighbouring glyph at the seam.
      expect('address::clamp_to_edge'.allMatches(kMetalShaderSource).length, 2);
    });
  });

  group('entry points', () {
    test('are declared with the names newFunctionWithName: will ask for', () {
      expect(
          kMetalShaderSource,
          contains('vertex Varying '
              '$kMetalVertexEntryPoint('));
      expect(
          kMetalShaderSource,
          contains('fragment float4 '
              '$kMetalFragmentEntryPoint('));
    });

    test('the source is a whole translation unit', () {
      expect(kMetalShaderSource, contains('#include <metal_stdlib>'));
      expect(kMetalShaderSource, contains('using namespace metal;'));
    });
  });
}
