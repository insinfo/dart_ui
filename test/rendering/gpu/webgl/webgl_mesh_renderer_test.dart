@TestOn('browser')

library;

import 'dart:typed_data';

import 'package:dart_ui/src/graphics/mesh/mesh3d.dart';
import 'package:dart_ui/src/rendering/gpu/webgl/webgl_mesh_renderer.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_rasterizer.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_scene.dart';
import 'package:test/test.dart';

import 'webgl_session.dart';

void main() {
  final WebGlSession session = WebGlSession.open();
  tearDownAll(session.close);

  test('flat textured geometry uploads once and draws through WebGL2', () {
    if (session.device == null) {
      markTestSkipped(session.skipReason ?? 'no WebGL2 device');
      return;
    }
    final WebGlMeshRendererAttempt attempt =
        WebGlMeshRenderer.create(session.device!);
    final WebGlMeshRenderer renderer = attempt.renderer!;
    final target = session.target(32, 32);
    final MeshTexture texture = MeshTexture(
      width: 2,
      height: 2,
      pixels: Uint32List.fromList(<int>[
        0xFFFF0000,
        0xFF00FF00,
        0xFF0000FF,
        0xFFFFFFFF,
      ]),
    );
    final MeshPrimitive primitive = MeshPrimitive(
      positions: Float32List.fromList(<double>[
        -1,
        -1,
        0,
        1,
        -1,
        0,
        1,
        1,
        0,
        -1,
        1,
        0,
      ]),
      indices: Uint32List.fromList(<int>[0, 1, 2, 0, 2, 3]),
      uvs: Float32List.fromList(<double>[0, 0, 1, 0, 1, 1, 0, 1]),
      material: MeshMaterial(
        colorArgb: 0xFFFFFFFF,
        doubleSided: true,
        baseColorTexture: texture,
      ),
    );
    final Mesh3D mesh = Mesh3D(
      name: 'textured quad',
      format: 'test',
      primitives: <MeshPrimitive>[primitive],
    );
    final MeshScene scene = MeshScene(
      mesh: mesh,
      camera: MeshCamera.frame(primitive.computeBounds(), yaw: 0, pitch: 0),
      shading: MeshShading.flat,
    );

    expect(renderer.drawScene(target, scene).drawn, 2);
    expect(renderer.bufferUploadCount, 2);
    expect(renderer.drawScene(target, scene).drawn, 2);
    expect(renderer.bufferUploadCount, 2,
        reason: 'the second frame must reuse the de-indexed geometry');

    renderer
      ..discardMesh(mesh)
      ..dispose();
    target.dispose();
  });
}
