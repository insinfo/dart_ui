/// The blend table and the vertex layout constants.
///
/// Both are small enough to look obviously right and are exactly the kind of
/// thing that is wrong: a blend factor pair that silently defaults draws a
/// picture that looks like a paint bug, and a layout offset that overlaps
/// draws garbage colours.
library;

import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_pipeline.dart';
import 'package:test/test.dart';

void main() {
  group('gpuBlendForMode', () {
    test('source-over is the premultiplied pair blend.dart implements', () {
      expect(
        gpuBlendForMode(blendModeSrcOver),
        const GpuBlendState(
            GpuBlendFactor.one, GpuBlendFactor.oneMinusSrcAlpha),
      );
    });

    test('src replaces and plus adds', () {
      expect(
        gpuBlendForMode(blendModeSrc),
        const GpuBlendState(GpuBlendFactor.one, GpuBlendFactor.zero),
      );
      expect(
        gpuBlendForMode(blendModePlus),
        const GpuBlendState(GpuBlendFactor.one, GpuBlendFactor.one),
      );
    });

    test('an unknown mode throws instead of defaulting to source-over', () {
      // The measurable-parity rule from section 23.7: a mode that quietly
      // becomes srcOver makes CPU/GPU comparison meaningless, because the two
      // sides are no longer being asked for the same thing.
      expect(() => gpuBlendForMode(3), throwsArgumentError);
      expect(() => gpuBlendForMode(-1), throwsArgumentError);
      expect(() => gpuBlendForMode(99), throwsArgumentError);
    });

    test('the error names the mode it refused', () {
      Object? caught;
      try {
        gpuBlendForMode(42);
      } on ArgumentError catch (error) {
        caught = error;
      }
      expect('$caught', contains('42'));
    });
  });

  group('GpuBlendState', () {
    test('compares by value, so a batch can hold one without allocating', () {
      const a = GpuBlendState(GpuBlendFactor.one, GpuBlendFactor.zero);
      const b = GpuBlendState(GpuBlendFactor.one, GpuBlendFactor.zero);
      const c = GpuBlendState(GpuBlendFactor.zero, GpuBlendFactor.one);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('the vertex layout', () {
    test('the four attributes tile the vertex without overlapping', () {
      // position(2) + texCoord(2) + colour(4) + shapeRect(4) = 12 floats, and
      // the backend hands these offsets straight to glVertexAttribPointer.
      const sizes = <int>[2, 2, 4, 4];
      const offsets = <int>[
        kGpuPositionOffset,
        kGpuTexCoordOffset,
        kGpuColorOffset,
        kGpuShapeRectOffset,
      ];

      var expected = 0;
      for (var i = 0; i < offsets.length; i++) {
        expect(offsets[i], expected, reason: 'attribute $i is misplaced');
        expected += sizes[i];
      }
      expect(kGpuFloatsPerVertex, expected);
    });

    test('a quad is four vertices and two triangles', () {
      expect(kGpuVerticesPerQuad, 4);
      expect(kGpuIndicesPerQuad, 6);
    });
  });
}
