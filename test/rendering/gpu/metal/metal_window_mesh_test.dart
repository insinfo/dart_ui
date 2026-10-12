/// A 3D scene drawn into a window's `IOSurface`, read back from the surface.
///
/// Until 12/10/2026 `MetalMeshRenderer` drew into a memory target only, and
/// the macOS presentation path declared no mesh factory - so every 3D view in
/// a Metal window fell back to the CPU rasteriser. The window's surface is
/// `BGRA8Unorm` and a Metal pipeline state is compiled for one colour format,
/// so this test is mostly about the byte order: a red quad on a blue sky must
/// come out of the surface as B,G,R,A = 0,0,255,255 and 255,0,0,255, not
/// swapped.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/backends/macos/io_surface.dart';
import 'package:dart_ui/src/backends/macos/surface_pool.dart';
import 'package:dart_ui/src/graphics/mesh/mesh3d.dart';
import 'package:dart_ui/src/rendering/gpu/metal/metal_backend.dart';
import 'package:dart_ui/src/rendering/gpu/metal/metal_mesh_renderer.dart';
import 'package:dart_ui/src/rendering/gpu/metal/metal_window_target.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_rasterizer.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_scene.dart';
import 'package:test/test.dart';

const String _needsMac =
    'needs a Mac: this opens an MTLDevice and draws into an IOSurface';

void main() {
  test('a scene lands in the back slot in BGRA order', () {
    final List<MacosIOSurface> surfaces = <MacosIOSurface>[
      MacosIOSurface.create(width: 64, height: 48, global: false),
      MacosIOSurface.create(width: 64, height: 48, global: false),
    ];
    final MacosSurfacePool pool = MacosSurfacePool(surfaces);
    final MetalRenderDevice device = MetalRenderDevice.open();
    final MetalWindowTarget target =
        device.createTarget(pool.describe(1.0)) as MetalWindowTarget;
    final MetalMeshRenderer renderer = device.createMeshRenderer();
    try {
      final Mesh3D mesh = _quad();
      final MeshRenderStats stats = renderer.drawScene(
        target,
        MeshScene(
          mesh: mesh,
          camera: MeshCamera.frame(mesh.computeBounds()),
          shading: MeshShading.unlit,
          backgroundArgb: 0xFF0000FF,
        ),
      );
      expect(stats.drawn, 2);

      late Uint8List centre;
      late Uint8List corner;
      surfaces[pool.backSlot].withPixels((Uint8List pixels) {
        final int stride = surfaces[pool.backSlot].bytesPerRow;
        int at(int x, int y) => y * stride + x * 4;
        centre = Uint8List.fromList(pixels.sublist(at(32, 24), at(32, 24) + 4));
        corner = Uint8List.fromList(pixels.sublist(at(0, 0), at(0, 0) + 4));
      });
      expect(centre, <int>[0, 0, 255, 255], reason: 'the quad, red, as BGRA');
      expect(corner, <int>[255, 0, 0, 255], reason: 'the sky, blue, as BGRA');
    } finally {
      renderer.dispose();
      target.dispose();
      device.dispose();
      pool.dispose();
    }
  }, skip: Platform.isMacOS ? null : _needsMac);
}

/// A red square filling the middle of the view, facing the camera.
Mesh3D _quad() => Mesh3D(
      name: 'window mesh quad',
      format: 'generated',
      primitives: <MeshPrimitive>[
        MeshPrimitive(
          positions: Float32List.fromList(<double>[
            -1, -1, 0, //
            1, -1, 0, //
            1, 1, 0, //
            -1, 1, 0, //
          ]),
          normals: Float32List.fromList(<double>[
            0, 0, 1, //
            0, 0, 1, //
            0, 0, 1, //
            0, 0, 1, //
          ]),
          indices: Uint32List.fromList(<int>[0, 1, 2, 0, 2, 3]),
          material: const MeshMaterial(
            colorArgb: 0xFFFF0000,
            doubleSided: true,
          ),
        ),
      ],
    );
