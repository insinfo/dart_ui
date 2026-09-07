library;

import 'dart:typed_data';

import 'package:dart_ui/src/graphics/mesh/mesh3d.dart';
import 'package:dart_ui/src/rendering/gpu/metal/metal_mesh_shaders.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_rasterizer.dart';
import 'package:test/test.dart';

void main() {
  test('ARGB texture words are explicitly packed as RGBA bytes', () {
    final MeshTexture texture = MeshTexture(
        width: 2,
        height: 1,
        pixels: Uint32List.fromList(<int>[0x11223344, 0xFFA0B0C0]));
    expect(packMetalMeshTexturePixels(texture),
        <int>[0x22, 0x33, 0x44, 0x11, 0xA0, 0xB0, 0xC0, 0xFF]);
  });

  test('smooth packing preserves the indexed vertex stream', () {
    final MeshPrimitive primitive = _triangle();
    final Float32List packed =
        packMetalMeshVertices(primitive, MeshShading.smooth);
    expect(packed.length, 3 * kMetalMeshFloatsPerVertex);
    expect(packed.sublist(0, 3), <double>[0, 0, 0]);
    expect(packed.sublist(3, 6), <double>[0, 0, 1]);
    expect(packed.sublist(6, 8), <double>[0, 0]);
  });

  test('flat packing de-indexes and writes one face normal', () {
    final Float32List packed =
        packMetalMeshVertices(_triangle(), MeshShading.flat);
    expect(packed.length, 3 * kMetalMeshFloatsPerVertex);
    for (var vertex = 0; vertex < 3; vertex++) {
      expect(packed.sublist(vertex * 8 + 3, vertex * 8 + 6), <double>[0, 0, 1]);
    }
  });

  test('MSL layout and all shading switches remain explicit', () {
    expect(kMetalMeshVertexStride, 32);
    expect(kMetalMeshUniformBytes, 112);
    expect(kMetalMeshShaderSource, contains('float4x4 mvp'));
    expect(kMetalMeshShaderSource, contains('scene.options.y == 0.0'));
    expect(kMetalMeshShaderSource, contains('[[front_facing]]'));
    expect(kMetalMeshShaderSource, contains('address::repeat'));
  });
}

MeshPrimitive _triangle() => MeshPrimitive(
      positions: Float32List.fromList(<double>[0, 0, 0, 1, 0, 0, 0, 1, 0]),
      normals: Float32List.fromList(<double>[0, 0, 1, 0, 0, 1, 0, 0, 1]),
      uvs: Float32List.fromList(<double>[0, 0, 1, 0, 0, 1]),
      indices: Uint32List.fromList(<int>[0, 1, 2]),
    );
