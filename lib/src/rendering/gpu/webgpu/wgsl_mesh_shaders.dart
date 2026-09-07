/// Pure constants and packing rules for the WebGPU mesh pipeline.
library;

import 'dart:typed_data';

import '../../../graphics/mesh/mesh3d.dart';
import '../../mesh/mesh_rasterizer.dart';

const int kWebGpuMeshFloatsPerVertex = 8;
const int kWebGpuMeshVertexStride = kWebGpuMeshFloatsPerVertex * 4;
const int kWebGpuMeshUniformBytes = 112;

/// Converts the mesh's canonical `0xAARRGGBB` words to WebGPU `rgba8unorm`.
Uint8List packWebGpuTexturePixels(MeshTexture texture) {
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

/// Interleaves position, normal and UV data. Missing normals are generated.
Float32List packWebGpuMeshVertices(
  MeshPrimitive primitive,
  MeshShading shading,
) {
  if (shading == MeshShading.flat) {
    final Float32List out = Float32List(primitive.indices.length * 8);
    for (var i = 0; i < primitive.indices.length; i += 3) {
      final int ai = primitive.indices[i] * 3;
      final int bi = primitive.indices[i + 1] * 3;
      final int ci = primitive.indices[i + 2] * 3;
      final Vector3 a = Vector3(primitive.positions[ai],
          primitive.positions[ai + 1], primitive.positions[ai + 2]);
      final Vector3 b = Vector3(primitive.positions[bi],
          primitive.positions[bi + 1], primitive.positions[bi + 2]);
      final Vector3 c = Vector3(primitive.positions[ci],
          primitive.positions[ci + 1], primitive.positions[ci + 2]);
      final Vector3 n = (b - a).cross(c - a).normalized;
      for (var corner = 0; corner < 3; corner++) {
        final int vertex = primitive.indices[i + corner];
        final int p = vertex * 3;
        final int t = vertex * 2;
        final int o = (i + corner) * 8;
        out[o] = primitive.positions[p];
        out[o + 1] = primitive.positions[p + 1];
        out[o + 2] = primitive.positions[p + 2];
        out[o + 3] = n.x;
        out[o + 4] = n.y;
        out[o + 5] = n.z;
        out[o + 6] = primitive.uvs == null ? 0 : primitive.uvs![t];
        out[o + 7] = primitive.uvs == null ? 0 : primitive.uvs![t + 1];
      }
    }
    return out;
  }
  final Float32List normals =
      primitive.normals ?? primitive.computeSmoothNormals();
  final Float32List? uvs = primitive.uvs;
  final Float32List out = Float32List(primitive.vertexCount * 8);
  for (var vertex = 0; vertex < primitive.vertexCount; vertex++) {
    final int p = vertex * 3;
    final int t = vertex * 2;
    final int o = vertex * 8;
    out[o] = primitive.positions[p];
    out[o + 1] = primitive.positions[p + 1];
    out[o + 2] = primitive.positions[p + 2];
    out[o + 3] = normals[p];
    out[o + 4] = normals[p + 1];
    out[o + 5] = normals[p + 2];
    out[o + 6] = uvs == null ? 0 : uvs[t];
    out[o + 7] = uvs == null ? 0 : uvs[t + 1];
  }
  return out;
}

const String kWgslMeshShaderSource = '''
struct Scene {
  mvp: mat4x4f,
  color: vec4f,
  light: vec4f,
  options: vec4f,
}
@group(0) @binding(0) var<uniform> scene: Scene;
@group(0) @binding(1) var base_sampler: sampler;
@group(0) @binding(2) var base_texture: texture_2d<f32>;

struct Input {
  @location(0) position: vec3f,
  @location(1) normal: vec3f,
  @location(2) uv: vec2f,
}
struct Output {
  @builtin(position) position: vec4f,
  @location(0) normal: vec3f,
  @location(1) uv: vec2f,
}
@vertex fn vs_main(input: Input) -> Output {
  var output: Output;
  output.position = scene.mvp * vec4f(input.position, 1.0);
  output.normal = input.normal;
  output.uv = input.uv;
  return output;
}
@fragment fn fs_main(input: Output, @builtin(front_facing) front: bool)
    -> @location(0) vec4f {
  let material = scene.color * textureSample(base_texture, base_sampler, input.uv);
  if (scene.options.y == 0.0) { return material; }
  var normal = normalize(input.normal);
  if (!front) { normal = -normal; }
  let lambert = max(0.0, -dot(normal, scene.light.xyz));
  let fill = max(0.0, dot(normal, scene.light.xyz)) * 0.25;
  let intensity = clamp(scene.options.x + lambert * 0.85 + fill, 0.0, 1.2);
  return vec4f(material.rgb * intensity, material.a);
}
''';
