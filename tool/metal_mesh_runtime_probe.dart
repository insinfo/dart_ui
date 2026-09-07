import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/graphics/mesh/mesh3d.dart';
import 'package:dart_ui/src/rendering/gpu/metal/metal_backend.dart';
import 'package:dart_ui/src/rendering/gpu/metal/metal_mesh_renderer.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_rasterizer.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_scene.dart';

Never fail(String message) {
  stderr.writeln('METAL_MESH_RUNTIME=FAIL $message');
  exit(1);
}

Future<void> main() async {
  if (!Platform.isMacOS) fail('requires macOS');
  final MetalRenderDevice device = MetalRenderDevice.open();
  final MetalMemoryTarget target = device.createTarget(
    const MemorySurfaceDescriptor(
      pixelWidth: 192,
      pixelHeight: 192,
      scale: 1,
      format: PixelFormat.rgba8888Premultiplied,
    ),
  ) as MetalMemoryTarget;
  final MetalMeshRenderer renderer = MetalMeshRenderer(device);
  try {
    final Mesh3D mesh = _mesh();
    final MeshCamera camera =
        MeshCamera.frame(mesh.computeBounds(), yaw: 0.35, pitch: 0.25);
    for (final MeshShading shading in MeshShading.values) {
      final MeshRenderStats stats = renderer.drawScene(
          target,
          MeshScene(
              mesh: mesh,
              camera: camera,
              shading: shading,
              backgroundArgb: 0xFF09111B));
      if (stats.drawn != 2) fail('$shading submitted ${stats.drawn} triangles');
      final Framebuffer pixels = target.meshTarget.readPixels();
      var changed = 0;
      for (var i = 0; i < pixels.pixels.length; i += 4) {
        final int r = pixels.pixels[i];
        final int g = pixels.pixels[i + 1];
        final int b = pixels.pixels[i + 2];
        if (r != 0x09 || g != 0x11 || b != 0x1B) changed++;
      }
      if (changed < (shading == MeshShading.wireframe ? 20 : 500)) {
        fail('$shading readback changed only $changed pixels');
      }
      stdout.writeln('SHADING=PASS mode=${shading.name} changed=$changed');
    }
    if (renderer.bufferUploadCount != MeshShading.values.length * 2) {
      fail('geometry cache count changed unexpectedly: '
          '${renderer.bufferUploadCount} uploads');
    }
    renderer.discardMesh(mesh);
    if (renderer.cachedPrimitiveCount != 0 ||
        renderer.cachedTextureCount != 0) {
      fail('discardMesh left geometry or textures cached');
    }
    stdout.writeln('METAL_MESH_RUNTIME=PASS device=${device.deviceName}');
  } on Object catch (error, stack) {
    stderr.writeln(error);
    stderr.writeln(stack);
    fail('exception while drawing/readback');
  } finally {
    renderer.dispose();
    target.dispose();
    device.dispose();
  }
}

Mesh3D _mesh() {
  final MeshTexture checker = MeshTexture(
      width: 2,
      height: 2,
      pixels: Uint32List.fromList(
          <int>[0xFFFF2020, 0xFF20FF20, 0xFF2020FF, 0xFFFFFFFF]));
  return Mesh3D(
    name: 'metal probe quad',
    format: 'generated',
    primitives: <MeshPrimitive>[
      MeshPrimitive(
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
        normals: Float32List.fromList(<double>[
          0,
          0,
          1,
          0,
          0,
          1,
          0,
          0,
          1,
          0,
          0,
          1,
        ]),
        uvs: Float32List.fromList(<double>[0, 0, 2, 0, 2, 2, 0, 2]),
        indices: Uint32List.fromList(<int>[0, 1, 2, 0, 2, 3]),
        material: MeshMaterial(
            colorArgb: 0xFFFFFFFF,
            doubleSided: true,
            baseColorTexture: checker),
      ),
    ],
  );
}
