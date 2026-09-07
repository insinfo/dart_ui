@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:dart_ui/src/foundation/lifecycle.dart';
import 'package:dart_ui/src/graphics/mesh/mesh3d.dart';
import 'package:dart_ui/src/rendering/gpu/webgpu/webgpu_canvas_target.dart';
import 'package:dart_ui/src/rendering/gpu/webgpu/webgpu_mesh_renderer.dart';
import 'package:dart_ui/src/rendering/gpu/webgpu/webgpu_surface_descriptor.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_rasterizer.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_scene.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

void main() {
  test('renders textured flat and wireframe meshes and releases cache',
      () async {
    final web.HTMLCanvasElement canvas =
        web.document.createElement('canvas') as web.HTMLCanvasElement
          ..width = 32
          ..height = 32;
    final opened = await WebGpuCanvasTarget.open(WebGpuCanvasSurfaceDescriptor(
      canvas: canvas,
      generation: GenerationToken(),
    ));
    if (opened.target == null || opened.device == null) {
      markTestSkipped('no WebGPU adapter: ${opened.failure}');
      return;
    }
    final WebGpuMeshRenderer renderer = WebGpuMeshRenderer(opened.device!);
    final MeshTexture texture = MeshTexture(
      width: 2,
      height: 1,
      pixels: Uint32List.fromList(<int>[0xFFFF0000, 0x800000FF]),
      name: 'ARGB conversion sentinel',
    );
    final Mesh3D flat = _triangle('flat', texture);
    final Mesh3D wire = _triangle('wire', texture);
    final MeshCamera camera = MeshCamera.frame(flat.computeBounds());

    final MeshRenderStats flatStats = renderer.drawScene(
      opened.target!,
      MeshScene(mesh: flat, camera: camera, shading: MeshShading.flat),
    );
    final MeshRenderStats wireStats = renderer.drawScene(
      opened.target!,
      MeshScene(mesh: wire, camera: camera, shading: MeshShading.wireframe),
    );
    expect(flatStats.triangles, 1);
    expect(wireStats.triangles, 1);
    expect(renderer.debugCachedTextureCount, 1,
        reason: 'both primitives share one texture object');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(opened.device!.lastError, isNull);

    renderer.discardMesh(flat);
    expect(renderer.debugCachedTextureCount, 1,
        reason: 'the wire mesh still owns the shared texture');
    renderer.discardMesh(wire);
    expect(renderer.debugCachedTextureCount, 0);
    renderer.dispose();
    opened.target!.dispose();
    opened.device!.dispose();
  });
}

Mesh3D _triangle(String name, MeshTexture texture) => Mesh3D(
      name: name,
      format: 'test',
      primitives: <MeshPrimitive>[
        MeshPrimitive(
          positions:
              Float32List.fromList(<double>[-1, -1, 0, 1, -1, 0, 0, 1, 0]),
          indices: Uint32List.fromList(<int>[0, 1, 2]),
          uvs: Float32List.fromList(<double>[0, 0, 1, 0, 0.5, 1]),
          material: MeshMaterial(baseColorTexture: texture),
        ),
      ],
    );
