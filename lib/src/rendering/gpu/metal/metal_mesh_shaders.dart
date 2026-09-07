library;

import 'dart:typed_data';

import '../../../graphics/mesh/mesh3d.dart';
import '../../mesh/mesh_rasterizer.dart';

const int kMetalMeshFloatsPerVertex = 8;
const int kMetalMeshVertexStride = 32;
const int kMetalMeshUniformBytes = 112;

Uint8List packMetalMeshTexturePixels(MeshTexture texture) {
  final Uint8List rgba = Uint8List(texture.width * texture.height * 4);
  for (var i = 0; i < texture.width * texture.height; i++) {
    final int argb = texture.pixels[i];
    final int at = i * 4;
    rgba[at] = (argb >> 16) & 255;
    rgba[at + 1] = (argb >> 8) & 255;
    rgba[at + 2] = argb & 255;
    rgba[at + 3] = (argb >> 24) & 255;
  }
  return rgba;
}

Float32List packMetalMeshVertices(
    MeshPrimitive primitive, MeshShading shading) {
  if (shading == MeshShading.flat) {
    final Float32List out = Float32List(primitive.indices.length * 8);
    for (var i = 0; i + 2 < primitive.indices.length; i += 3) {
      final int ai = primitive.indices[i] * 3;
      final int bi = primitive.indices[i + 1] * 3;
      final int ci = primitive.indices[i + 2] * 3;
      final Vector3 a = Vector3(primitive.positions[ai],
          primitive.positions[ai + 1], primitive.positions[ai + 2]);
      final Vector3 b = Vector3(primitive.positions[bi],
          primitive.positions[bi + 1], primitive.positions[bi + 2]);
      final Vector3 c = Vector3(primitive.positions[ci],
          primitive.positions[ci + 1], primitive.positions[ci + 2]);
      final Vector3 normal = (b - a).cross(c - a).normalized;
      for (var corner = 0; corner < 3; corner++) {
        final int vertex = primitive.indices[i + corner];
        final int position = vertex * 3;
        final int uv = vertex * 2;
        final int at = (i + corner) * 8;
        out[at] = primitive.positions[position];
        out[at + 1] = primitive.positions[position + 1];
        out[at + 2] = primitive.positions[position + 2];
        out[at + 3] = normal.x;
        out[at + 4] = normal.y;
        out[at + 5] = normal.z;
        out[at + 6] = primitive.uvs == null ? 0 : primitive.uvs![uv];
        out[at + 7] = primitive.uvs == null ? 0 : primitive.uvs![uv + 1];
      }
    }
    return out;
  }
  final Float32List normals =
      primitive.normals ?? primitive.computeSmoothNormals();
  final Float32List out = Float32List(primitive.vertexCount * 8);
  for (var vertex = 0; vertex < primitive.vertexCount; vertex++) {
    final int p = vertex * 3;
    final int uv = vertex * 2;
    final int at = vertex * 8;
    out[at] = primitive.positions[p];
    out[at + 1] = primitive.positions[p + 1];
    out[at + 2] = primitive.positions[p + 2];
    out[at + 3] = normals[p];
    out[at + 4] = normals[p + 1];
    out[at + 5] = normals[p + 2];
    out[at + 6] = primitive.uvs == null ? 0 : primitive.uvs![uv];
    out[at + 7] = primitive.uvs == null ? 0 : primitive.uvs![uv + 1];
  }
  return out;
}

const String kMetalMeshShaderSource = r'''
#include <metal_stdlib>
using namespace metal;
struct Scene { float4x4 mvp; float4 color; float4 light; float4 options; };
struct Input { float3 position [[attribute(0)]]; float3 normal [[attribute(1)]]; float2 uv [[attribute(2)]]; };
struct Output { float4 position [[position]]; float3 normal; float2 uv; };
vertex Output meshVs(Input input [[stage_in]], constant Scene& scene [[buffer(1)]]) {
  Output output; output.position = scene.mvp * float4(input.position, 1.0);
  output.position.z = (output.position.z + output.position.w) * 0.5;
  output.normal = input.normal; output.uv = input.uv; return output;
}
fragment float4 meshFs(Output input [[stage_in]], bool front [[front_facing]],
                       constant Scene& scene [[buffer(1)]],
                       texture2d<float> texture [[texture(0)]]) {
  constexpr sampler baseSampler(coord::normalized, filter::nearest,
                                address::repeat);
  float4 material = scene.color * texture.sample(baseSampler, input.uv);
  if (scene.options.y == 0.0) return material;
  float3 normal = normalize(input.normal);
  if (!front) normal = -normal;
  float lambert = max(0.0, -dot(normal, scene.light.xyz));
  float fill = max(0.0, dot(normal, scene.light.xyz)) * 0.25;
  float intensity = clamp(scene.options.x + lambert * 0.85 + fill, 0.0, 1.2);
  return float4(material.rgb * intensity, material.a);
}
''';
