/// The pure half of the sparse WebGPU path, checked with no browser and no GPU.
///
/// `wgsl_sparse_shaders.dart` was split from the driver for exactly the reason
/// `wgsl_shaders.dart` was split from `webgpu_backend.dart`: the facts that
/// decide whether a frame is *correct* - which entry point a pipeline names,
/// which byte a gradient's focus lands on, whether the instance layout still
/// agrees with the encoder that fills it - are all pure, and CI has neither a
/// browser nor a GPU.
///
/// What this file cannot check is whether the WGSL compiles. Only a browser's
/// own compiler can say, and `webgpu_sparse_device_test.dart` asks it.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/geometry/transform2d.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/graphics/gradient.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_sparse_strips.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_gradient.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_texture.dart';
import 'package:dart_ui/src/rendering/gpu/webgpu/wgsl_sparse_shaders.dart';
import 'package:dart_ui/src/rendering/replay/display_list_player.dart';
import 'package:test/test.dart';

void main() {
  group('the sparse shader module', () {
    test('declares the vertex entry point and all four fragment ones', () {
      expect(
        kWgslSparseShaderModuleSource,
        contains('fn $kWgslSparseVertexEntryPoint('),
      );
      for (final String entryPoint in kWgslSparseFragmentEntryPoints) {
        expect(
          kWgslSparseShaderModuleSource,
          contains('fn $entryPoint('),
          reason: 'a pipeline names this entry point in its descriptor, and '
              'WebGPU validates the name against the module - asynchronously, '
              'which is why the check belongs here',
        );
      }
    });

    test('validates its own Dart-side contract', () {
      expect(validateWgslSparseShaderContract, returnsNormally);
    });

    test('has no yFlip, by design rather than omission', () {
      // The GL sparse shader carries uYFlip because GL's framebuffer origin is
      // the bottom-left corner. WebGPU's is the top-left one, so the single
      // projection is right for a canvas and a layer alike; a uniform named
      // anything like yFlip reappearing here means someone ported the GLSL
      // afresh and reintroduced a flip that would draw every layer upside
      // down. Comments are stripped first: the source is encouraged to
      // *explain* the absent flip, and only code can reintroduce one.
      final String code = kWgslSparseShaderModuleSource
          .split('\n')
          .where((String line) => !line.trimLeft().startsWith('//'))
          .join('\n');
      expect(code.toLowerCase(), isNot(contains('yflip')));
    });

    test('reflects with floor rather than WGSL\'s truncating remainder', () {
      // GLSL's mod(x, 2) follows the sign of the divisor and WGSL's % follows
      // the sign of the dividend, so a negative gradient parameter would
      // mirror the ramp about the wrong end. The expression is written out on
      // purpose and a `%` creeping back in is the regression this pins.
      expect(
        kWgslSparseShaderModuleSource,
        contains('parameter - 2.0 * floor(parameter * 0.5)'),
      );
    });

    test('premultiplies the LUT before coverage, as the GLSL does', () {
      expect(
        kWgslSparseShaderModuleSource,
        contains('vec4f(straight.rgb * straight.a, straight.a)'),
      );
      expect(
        kWgslSparseShaderModuleSource,
        contains('sparseCoverage(in.atlasTexel)'),
      );
    });

    test('reads the atlas with textureLoad at floored texel coordinates', () {
      // Not textureSample: device rectangles and atlas placements are integer
      // aligned, and a filtered tap would blend a neighbouring strip's
      // coverage into this one's edge.
      expect(
        kWgslSparseShaderModuleSource,
        contains('textureLoad(uAlphaAtlas, vec2i(floor(atlasTexel)), 0).r'),
      );
    });
  });

  group('the fragment entry-point table', () {
    test('is total over the submission encoder\'s own constants', () {
      expect(
        wgslSparseFragmentEntryPoint(
          coverageMode: kSparseGlModeSolid,
          paintMode: kSparseGlPaintSolid,
        ),
        'fs_sparse_solid_fill',
      );
      expect(
        wgslSparseFragmentEntryPoint(
          coverageMode: kSparseGlModeAlpha,
          paintMode: kSparseGlPaintSolid,
        ),
        'fs_sparse_solid_strip',
      );
      expect(
        wgslSparseFragmentEntryPoint(
          coverageMode: kSparseGlModeSolid,
          paintMode: kSparseGlPaintGradient,
        ),
        'fs_sparse_gradient_fill',
      );
      expect(
        wgslSparseFragmentEntryPoint(
          coverageMode: kSparseGlModeAlpha,
          paintMode: kSparseGlPaintGradient,
        ),
        'fs_sparse_gradient_strip',
      );
    });

    test('names every entry point the module declares, and no other', () {
      final Set<String> mapped = <String>{
        for (final int coverage in <int>[
          kSparseGlModeSolid,
          kSparseGlModeAlpha,
        ])
          for (final int paint in <int>[
            kSparseGlPaintSolid,
            kSparseGlPaintGradient,
          ])
            wgslSparseFragmentEntryPoint(
              coverageMode: coverage,
              paintMode: paint,
            ),
      };
      expect(mapped, kWgslSparseFragmentEntryPoints.toSet());
    });

    test('refuses an unknown mode rather than defaulting to a solid fill', () {
      expect(
        () => wgslSparseFragmentEntryPoint(coverageMode: 7, paintMode: 0),
        throwsArgumentError,
      );
      expect(
        () => wgslSparseFragmentEntryPoint(coverageMode: 0, paintMode: 7),
        throwsArgumentError,
      );
    });
  });

  group('the instance layout', () {
    test('is the shared encoder\'s layout, not a second one', () {
      // These are aliases on purpose: the bytes come out of
      // SparseGlSubmission, and a WebGPU vertex layout that disagreed with it
      // would read a width where an atlas origin lives.
      expect(kWebGpuSparseInstanceStrideBytes, kSparseGlInstanceStrideBytes);
      expect(kWebGpuSparseQuadRectOffsetBytes, kSparseGlQuadRectOffsetBytes);
      expect(
        kWebGpuSparseAtlasOriginOffsetBytes,
        kSparseGlAtlasOriginOffsetBytes,
      );
      expect(kWebGpuSparseQuadRectLocation, kSparseGlAttributeQuadRect);
      expect(kWebGpuSparseAtlasOriginLocation, kSparseGlAttributeAtlasOrigin);
    });

    test('is six floats: a device rectangle then an atlas origin', () {
      expect(kWebGpuSparseInstanceStrideBytes, 24);
      expect(kWebGpuSparseQuadRectOffsetBytes, 0);
      expect(kWebGpuSparseAtlasOriginOffsetBytes, 16);
      expect(kWebGpuSparseVertexCount, 4,
          reason: 'four corners of a quad as a triangle strip');
    });
  });

  group('the uniform slice', () {
    test('is laid out the way WGSL lays out its struct', () {
      // Seven 16-byte-aligned vectors ending at 96, two i32 after them,
      // rounded up to the struct's own alignment. A Dart writer that drifted
      // from this would put a gradient's focus where its radius belongs and
      // draw a plausible, wrong picture.
      expect(WebGpuSparseUniformOffset.viewport, 0);
      expect(WebGpuSparseUniformOffset.gradientLookup, 8);
      expect(WebGpuSparseUniformOffset.color, 16);
      expect(WebGpuSparseUniformOffset.targetToLocal0, 32);
      expect(WebGpuSparseUniformOffset.targetToLocal1, 48);
      expect(WebGpuSparseUniformOffset.gradientGeometry0, 64);
      expect(WebGpuSparseUniformOffset.gradientGeometry1, 80);
      expect(WebGpuSparseUniformOffset.gradientKind, 96);
      expect(WebGpuSparseUniformOffset.gradientSpread, 100);
      expect(kWebGpuSparseUniformSliceSize, 112);
    });

    test('stride satisfies the specification\'s dynamic-offset alignment', () {
      expect(kWebGpuSparseUniformSliceStride % 256, 0);
      expect(
        kWebGpuSparseUniformSliceSize,
        lessThanOrEqualTo(kWebGpuSparseUniformSliceStride),
      );
    });
  });

  group('writing a solid material\'s slice', () {
    test('writes the viewport and the premultiplied colour', () {
      final ByteData slice = ByteData(kWebGpuSparseUniformSliceSize);
      writeWebGpuSparseUniformSlice(
        slice,
        0,
        viewportWidth: 640,
        viewportHeight: 480,
        red: 0.25,
        green: 0.125,
        blue: 0,
        alpha: 0.5,
      );
      expect(_float(slice, WebGpuSparseUniformOffset.viewport), 640);
      expect(_float(slice, WebGpuSparseUniformOffset.viewport + 4), 480);
      expect(_float(slice, WebGpuSparseUniformOffset.color), 0.25);
      expect(_float(slice, WebGpuSparseUniformOffset.color + 4), 0.125);
      expect(_float(slice, WebGpuSparseUniformOffset.color + 8), 0);
      expect(_float(slice, WebGpuSparseUniformOffset.color + 12), 0.5);
    });

    test('zeroes the gradient half of a reused arena', () {
      // The staging arena is retained across frames, so a solid material that
      // left a previous gradient's focus in place would hand the next
      // gradient-shaped bug to whoever read it.
      final ByteData slice = ByteData(kWebGpuSparseUniformSliceSize);
      for (var i = 0; i < kWebGpuSparseUniformSliceSize; i += 4) {
        slice.setInt32(i, 0x7F7F7F7F, Endian.little);
      }
      writeWebGpuSparseUniformSlice(
        slice,
        0,
        viewportWidth: 4,
        viewportHeight: 4,
        red: 0,
        green: 0,
        blue: 0,
        alpha: 0,
      );
      for (var offset = WebGpuSparseUniformOffset.gradientLookup;
          offset < WebGpuSparseUniformOffset.color;
          offset += 4) {
        expect(_float(slice, offset), 0);
      }
      for (var offset = WebGpuSparseUniformOffset.targetToLocal0;
          offset < WebGpuSparseUniformOffset.gradientKind;
          offset += 4) {
        expect(_float(slice, offset), 0);
      }
      expect(slice.getInt32(WebGpuSparseUniformOffset.gradientKind,
          Endian.little), 0);
      expect(slice.getInt32(WebGpuSparseUniformOffset.gradientSpread,
          Endian.little), 0);
    });

    test('refuses a viewport that cannot project anything', () {
      final ByteData slice = ByteData(kWebGpuSparseUniformSliceSize);
      expect(
        () => writeWebGpuSparseUniformSlice(
          slice,
          0,
          viewportWidth: 0,
          viewportHeight: 4,
          red: 0,
          green: 0,
          blue: 0,
          alpha: 0,
        ),
        throwsArgumentError,
      );
    });

    test('refuses an offset that would run past the arena', () {
      final ByteData slice = ByteData(kWebGpuSparseUniformSliceSize);
      expect(
        () => writeWebGpuSparseUniformSlice(
          slice,
          8,
          viewportWidth: 4,
          viewportHeight: 4,
          red: 0,
          green: 0,
          blue: 0,
          alpha: 0,
        ),
        throwsRangeError,
      );
    });
  });

  group('writing a gradient material\'s slice', () {
    test('carries the LUT lookup, the transform rows and the geometry', () {
      final LinearGradient gradient = LinearGradient(
        startX: 1,
        startY: 2,
        endX: 9,
        endY: 2,
        stops: const <GradientStop>[
          GradientStop(0, 0xFF000000),
          GradientStop(1, 0xFFFFFFFF),
        ],
        spread: GradientSpread.reflect,
      );
      final _GradientAllocator allocator = _GradientAllocator();
      final GpuGradientBinding binding =
          GpuGradientCache(allocator: allocator, lutSize: 8).resolve(gradient);
      final GpuGradientShaderParameters parameters =
          GpuGradientShaderParameters.fromPaint(ReplayPaint(
        argbColor: 0,
        style: paintStyleFill,
        strokeWidth: 0,
        blendMode: blendModeSrcOver,
        antiAlias: true,
        gradient: gradient,
        shaderTransform: const Transform2D.translation(2, 3),
      ));

      final ByteData slice = ByteData(kWebGpuSparseUniformSliceStride);
      writeWebGpuSparseUniformSlice(
        slice,
        0,
        viewportWidth: 32,
        viewportHeight: 16,
        red: 0,
        green: 0,
        blue: 0,
        alpha: 0,
        gradientBinding: binding,
        gradientParameters: parameters,
      );

      expect(
        _float(slice, WebGpuSparseUniformOffset.gradientLookup),
        closeTo(binding.lookupScale, 1e-6),
      );
      expect(
        _float(slice, WebGpuSparseUniformOffset.gradientLookup + 4),
        closeTo(binding.lookupBias, 1e-6),
      );

      // Row 0 is (a, c, tx) and row 1 is (b, d, ty), so a dot with (x, y, 1)
      // is the affine map - the same packing `GlApiSparseDriver` performs.
      final Float32List scalars = parameters.scalars;
      const int transform = GpuGradientUniformOffset.targetToLocal;
      expect(_float(slice, WebGpuSparseUniformOffset.targetToLocal0),
          scalars[transform]);
      expect(_float(slice, WebGpuSparseUniformOffset.targetToLocal0 + 4),
          scalars[transform + 2]);
      expect(_float(slice, WebGpuSparseUniformOffset.targetToLocal0 + 8),
          scalars[transform + 4]);
      expect(_float(slice, WebGpuSparseUniformOffset.targetToLocal1),
          scalars[transform + 1]);
      expect(_float(slice, WebGpuSparseUniformOffset.targetToLocal1 + 4),
          scalars[transform + 3]);
      expect(_float(slice, WebGpuSparseUniformOffset.targetToLocal1 + 8),
          scalars[transform + 5]);

      const int geometry = GpuGradientUniformOffset.geometry;
      for (var i = 0; i < 4; i++) {
        expect(
          _float(slice, WebGpuSparseUniformOffset.gradientGeometry0 + i * 4),
          scalars[geometry + i],
        );
        expect(
          _float(slice, WebGpuSparseUniformOffset.gradientGeometry1 + i * 4),
          scalars[geometry + 4 + i],
        );
      }

      expect(
        slice.getInt32(WebGpuSparseUniformOffset.gradientKind, Endian.little),
        kWebGpuSparseGradientKindLinear,
      );
      expect(
        slice.getInt32(WebGpuSparseUniformOffset.gradientSpread, Endian.little),
        GradientSpread.reflect.index,
      );
    });

    test('refuses a binding and parameters describing different gradients', () {
      final LinearGradient lutGradient = LinearGradient(
        startX: 0,
        startY: 0,
        endX: 1,
        endY: 0,
        stops: const <GradientStop>[
          GradientStop(0, 0xFF000000),
          GradientStop(1, 0xFFFFFFFF),
        ],
      );
      final LinearGradient other = LinearGradient(
        startX: 0,
        startY: 0,
        endX: 8,
        endY: 0,
        stops: const <GradientStop>[
          GradientStop(0, 0xFFFF0000),
          GradientStop(1, 0xFF0000FF),
        ],
      );
      final GpuGradientBinding binding =
          GpuGradientCache(allocator: _GradientAllocator())
              .resolve(lutGradient);
      final GpuGradientShaderParameters parameters =
          GpuGradientShaderParameters.fromPaint(ReplayPaint(
        argbColor: 0,
        style: paintStyleFill,
        strokeWidth: 0,
        blendMode: blendModeSrcOver,
        antiAlias: true,
        gradient: other,
      ));
      expect(
        () => writeWebGpuSparseUniformSlice(
          ByteData(kWebGpuSparseUniformSliceSize),
          0,
          viewportWidth: 4,
          viewportHeight: 4,
          red: 0,
          green: 0,
          blue: 0,
          alpha: 0,
          gradientBinding: binding,
          gradientParameters: parameters,
        ),
        throwsArgumentError,
      );
    });

    test('refuses half a gradient', () {
      final GpuGradientBinding binding =
          GpuGradientCache(allocator: _GradientAllocator()).resolve(
        LinearGradient(
          startX: 0,
          startY: 0,
          endX: 1,
          endY: 0,
          stops: const <GradientStop>[
            GradientStop(0, 0xFF000000),
            GradientStop(1, 0xFFFFFFFF),
          ],
        ),
      );
      expect(
        () => writeWebGpuSparseUniformSlice(
          ByteData(kWebGpuSparseUniformSliceSize),
          0,
          viewportWidth: 4,
          viewportHeight: 4,
          red: 0,
          green: 0,
          blue: 0,
          alpha: 0,
          gradientBinding: binding,
        ),
        throwsArgumentError,
      );
    });
  });
}

double _float(ByteData slice, int offset) =>
    slice.getFloat32(offset, Endian.little);

final class _GradientTexture implements GpuTextureHandle {
  _GradientTexture(this.id, this.width, this.height, this.format, this.filter);

  @override
  final int id;
  @override
  final int width;
  @override
  final int height;
  @override
  final GpuTextureFormat format;
  @override
  final GpuTextureFilter filter;
  bool valid = true;

  @override
  bool get isValid => valid;
}

final class _GradientAllocator implements GpuTextureAllocator {
  /// The one id every LUT this allocator hands out carries, so a test can
  /// name it in an expectation without reaching into the binding.
  final int textureId = 40;
  int uploads = 0;

  @override
  GpuTextureHandle createTexture({
    required int width,
    required int height,
    required GpuTextureFormat format,
    GpuTextureFilter filter = GpuTextureFilter.nearest,
  }) =>
      _GradientTexture(textureId, width, height, format, filter);

  @override
  void uploadRegion(
    GpuTextureHandle texture, {
    required int x,
    required int y,
    required int width,
    required int height,
    required Uint8List pixels,
    required int bytesPerRow,
  }) {
    uploads++;
  }

  @override
  void releaseTexture(GpuTextureHandle texture) {
    (texture as _GradientTexture).valid = false;
  }
}
