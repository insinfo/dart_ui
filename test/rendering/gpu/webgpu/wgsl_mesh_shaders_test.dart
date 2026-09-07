import 'dart:typed_data';

import 'package:dart_ui/src/graphics/mesh/mesh3d.dart';
import 'package:dart_ui/src/rendering/gpu/webgpu/wgsl_mesh_shaders.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_rasterizer.dart';
import 'package:test/test.dart';

void main() {
  test('mesh texture words are uploaded as RGBA bytes', () {
    final MeshTexture texture = MeshTexture(
      width: 2,
      height: 1,
      pixels: Uint32List.fromList(<int>[0x7F123456, 0xFFABCDEF]),
    );
    expect(packWebGpuTexturePixels(texture),
        <int>[0x12, 0x34, 0x56, 0x7F, 0xAB, 0xCD, 0xEF, 0xFF]);
  });

  test('mesh vertex layout interleaves generated normals and default UVs', () {
    final MeshPrimitive primitive = MeshPrimitive(
      positions: Float32List.fromList(<double>[0, 0, 0, 1, 0, 0, 0, 1, 0]),
      indices: Uint32List.fromList(<int>[0, 1, 2]),
    );
    final Float32List packed =
        packWebGpuMeshVertices(primitive, MeshShading.smooth);
    expect(packed.length, 3 * kWebGpuMeshFloatsPerVertex);
    expect(packed.sublist(0, 8), <double>[0, 0, 0, 0, 0, 1, 0, 0]);
    expect(kWebGpuMeshVertexStride, 32);
  });

  test('WGSL declares depth-ready vertex and lit fragment entry points', () {
    expect(kWgslMeshShaderSource, contains('@vertex fn vs_main'));
    expect(kWgslMeshShaderSource, contains('@fragment fn fs_main'));
    expect(kWgslMeshShaderSource, contains('@builtin(front_facing)'));
    expect(kWgslMeshShaderSource, contains('@binding(1) var base_sampler'));
    expect(kWgslMeshShaderSource, contains('@binding(2) var base_texture'));
    expect(kWgslMeshShaderSource, contains('textureSample('));
    expect(kWebGpuMeshUniformBytes % 16, 0);
  });
}
