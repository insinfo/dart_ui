/// The HLSL and the constants that have to agree with it.
///
/// ## Why this one does not skip off Windows
///
/// Every other Direct3D 12 test in this change skips with a declared reason on
/// the Linux and macOS runners, because it needs a device and a test that
/// fails there fails the gate. This file needs nothing: `d3d12_shaders.dart`
/// has no imports at all, holds only strings and integers, and is compiled by
/// the driver at device creation - never here. Running it everywhere is what
/// makes the *agreement* below - between a pipeline enum in portable code and
/// a constant a shader branches on - checked on the machine with no GPU, which
/// is the only machine where a mismatch would otherwise go unnoticed until a
/// Windows run.
///
/// What it cannot check is that the HLSL compiles. That needs
/// `d3dcompiler_47.dll` and happens in
/// `test/backends/win32/d3d12/d3d12_device_test.dart`, where a device that
/// opened at all is proof that both stages compiled and three pipeline state
/// objects were built from them.
library;

import 'package:dart_ui/src/rendering/gpu/d3d12/d3d12_shaders.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_pipeline.dart';
import 'package:test/test.dart';

void main() {
  group('the mode constants agree with the portable pipeline enum', () {
    test('each mode is its GpuPipelineKind index', () {
      // The shader branches on an integer the backend derives from
      // [GpuPipelineKind]. If the enum grows a member in the middle, every
      // mode after it shifts and the pixel shader silently draws the wrong
      // thing - a coverage mask sampled as an image, say, which produces a
      // picture rather than an error.
      expect(kD3d12ModeSolid, GpuPipelineKind.solid.index);
      expect(kD3d12ModeCoverageMask, GpuPipelineKind.coverageMask.index);
      expect(kD3d12ModeTexturedImage, GpuPipelineKind.texturedImage.index);
    });

    test('a new pipeline kind would be caught here', () {
      // The guard that makes the test above non-vacuous: three kinds, and a
      // fourth needs a branch in the pixel shader and a constant beside it.
      expect(GpuPipelineKind.values.length, 3);
    });
  });

  group('the root constants match what the shader declares', () {
    test('five 32-bit values, packed as the cbuffer packs them', () {
      // float2 uViewport takes dwords 0 and 1, then three scalars at 2, 3 and
      // 4. HLSL only forbids a scalar *straddling* a 16-byte boundary and none
      // of these does, so the layout is exactly the five dwords
      // SetGraphicsRoot32BitConstants sends. A sixth value would have to be
      // added to both the count and the cbuffer, in that order.
      expect(kD3d12RootConstantCount, 5);
      expect(kD3d12VertexShader, contains('float2 uViewport;'));
      expect(kD3d12VertexShader, contains('uint uMode;'));
      expect(kD3d12VertexShader, contains('uint uYFlip;'));
      expect(kD3d12VertexShader, contains('uint uUseLinear;'));
      // The two stages share one declaration block, so the pixel shader must
      // see the same names at the same offsets.
      expect(kD3d12PixelShader, contains('float2 uViewport;'));
      expect(kD3d12PixelShader, contains('uint uUseLinear;'));
    });

    test('the two root parameter slots are distinct and start at zero', () {
      expect(kD3d12RootConstantsSlot, 0);
      expect(kD3d12RootTextureSlot, 1);
    });
  });

  group('the input layout matches the vertex declaration', () {
    test('four semantics, with TEXCOORD used twice at different indices', () {
      // Direct3D spells with a semantic *index* what GLSL spells with a second
      // attribute name. A shape rectangle bound to TEXCOORD0 would silently
      // become the texture coordinate, and every mask would sample the wrong
      // texel while still producing a plausible picture.
      expect(kD3d12SemanticNames.length, 4);
      expect(kD3d12SemanticIndices.length, kD3d12SemanticNames.length);
      expect(kD3d12SemanticNames, <String>[
        'POSITION',
        'TEXCOORD',
        'COLOR',
        'TEXCOORD',
      ]);
      expect(kD3d12SemanticIndices, <int>[0, 0, 0, 1]);

      // The same four, as the vertex input structure spells them. HLSL writes
      // the index as a suffix and omits it only where the declaration does -
      // POSITION carries none in the shader, so it is matched without one.
      expect(kD3d12VertexShader, contains(': POSITION'));
      expect(kD3d12VertexShader, contains(': TEXCOORD0'));
      expect(kD3d12VertexShader, contains(': COLOR0'));
      expect(kD3d12VertexShader, contains(': TEXCOORD1'));
    });

    test('the layout is the one gpu_pipeline.dart fixes', () {
      // The offsets the input element descriptions are built from. A vertex
      // that grew a field would have to change here, in the shader and in the
      // portable layout together.
      expect(kGpuFloatsPerVertex, 12);
      expect(kGpuPositionOffset, 0);
      expect(kGpuTexCoordOffset, 2);
      expect(kGpuColorOffset, 4);
      expect(kGpuShapeRectOffset, 8);
    });
  });

  group('the orientation convention is declared and unused', () {
    test('the flip is a branch that Direct3D never takes', () {
      // Direct3D writes render-target row 0 at the top and its scissor is
      // y-down from the same corner, so a layer target and a presented surface
      // want the same orientation and nothing is ever flipped. The constant
      // exists so the *reason* is recorded; see the library comment of
      // d3d12_shaders.dart.
      expect(kD3d12YFlipDefault, 0);
      expect(kD3d12YFlipTopDown, 1);
      expect(kD3d12VertexShader, contains('uYFlip == 0 ? ndcY : -ndcY'));
    });

    test('the coverage term is the same arithmetic as the GLSL', () {
      // Not a string comparison against the GLSL - the two dialects spell the
      // same operations differently - but the four steps have to be there, in
      // this order, or the analytic antialiasing is not analytic.
      expect(kD3d12PixelShader, contains('float2 lo = max(r.xy, p - 0.5);'));
      expect(kD3d12PixelShader, contains('float2 hi = min(r.zw, p + 0.5);'));
      expect(kD3d12PixelShader,
          contains('float2 overlap = clamp(hi - lo, 0.0, 1.0);'));
      expect(kD3d12PixelShader, contains('return overlap.x * overlap.y;'));
      // And it multiplies the final colour, in every mode.
      expect(
          kD3d12PixelShader,
          contains(
              'return color * boxCoverage(input.shapeRect, input.devicePos);'));
    });
  });

  group('the compilation targets are the ones every device guarantees', () {
    test('shader model 5.0 for both stages', () {
      // 5.1 needs a higher feature level for some of its features and buys
      // this renderer nothing; 5.0 is guaranteed by every device that answers
      // D3D12CreateDevice at all.
      expect(kD3d12VertexTarget, 'vs_5_0');
      expect(kD3d12PixelTarget, 'ps_5_0');
      expect(kD3d12VertexShader, contains('$kD3d12VertexEntryPoint('));
      expect(kD3d12PixelShader, contains('$kD3d12PixelEntryPoint('));
    });

    test('the samplers are declared in the order the root signature builds',
        () {
      // s0 is point and s1 is linear, and uUseLinear picks between them. The
      // order is part of the ABI between this file and the static samplers in
      // D3d12RenderDevice; swapping them would make every coverage atlas blur
      // and every scaled image blocky, with no error anywhere.
      expect(kD3d12SamplerPoint, 0);
      expect(kD3d12SamplerLinear, 1);
      expect(kD3d12PixelShader, contains('uPoint : register(s0)'));
      expect(kD3d12PixelShader, contains('uLinear : register(s1)'));
      expect(kD3d12PixelShader, contains('uTexture : register(t0)'));
    });
  });
}
