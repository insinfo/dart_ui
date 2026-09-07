/// The software rasteriser, checked against the arithmetic it optimises.
///
/// The first case here exists because of a bug this file was written after.
/// The inner loop steps three edge functions instead of recomputing them —
/// three additions a pixel rather than twelve multiplies — and an earlier
/// version stored the derivatives negated and then chose `+=` or `-=` per axis
/// to undo the sign. One of the six choices was wrong. The symptom was a model
/// drawn as scattered dots, because only the first row of each triangle's
/// bounding box evaluated correctly, and **nothing threw, nothing was empty and
/// every count looked right**: 5299 triangles drawn, the bounding box correct,
/// the camera correct. Only the pixels were wrong.
///
/// So the incremental loop is compared, pixel for pixel, against a direct
/// evaluation of the same formula. That is the only test that could have caught
/// it, and it is the shape every optimisation of this kind needs.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_ui/src/graphics/mesh/mesh3d.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_rasterizer.dart';
import 'package:test/test.dart';

/// A mesh of one triangle with the given corners, in the z = 0 plane.
Mesh3D _triangle(
  Vector3 a,
  Vector3 b,
  Vector3 c, {
  int colorArgb = 0xFFFFFFFF,
  bool doubleSided = false,
}) =>
    Mesh3D(
      name: 'triangle',
      format: 'test',
      primitives: <MeshPrimitive>[
        MeshPrimitive(
          positions: Float32List.fromList(<double>[
            a.x, a.y, a.z, //
            b.x, b.y, b.z, //
            c.x, c.y, c.z, //
          ]),
          indices: Uint32List.fromList(<int>[0, 1, 2]),
          material: MeshMaterial(
            colorArgb: colorArgb,
            doubleSided: doubleSided,
          ),
        ),
      ],
    );

/// A camera looking straight down -z at the origin, so world x and y map to
/// screen x and y with no rotation. Every expected coordinate below is worked
/// out against this.
MeshCamera _straightOn({double distance = 3}) => MeshCamera(
      target: Vector3.zero,
      distance: distance,
      yaw: 0,
      pitch: 0,
      near: 0.1,
      far: 100,
    );

/// True where the framebuffer is not the background.
List<bool> _coverage(Framebuffer target, int backgroundArgb) {
  final int b = backgroundArgb & 0xFF;
  final int g = (backgroundArgb >> 8) & 0xFF;
  final int r = (backgroundArgb >> 16) & 0xFF;
  return <bool>[
    for (var y = 0; y < target.height; y++)
      for (var x = 0; x < target.width; x++)
        !(target.pixels[y * target.bytesPerRow + x * 4] == b &&
            target.pixels[y * target.bytesPerRow + x * 4 + 1] == g &&
            target.pixels[y * target.bytesPerRow + x * 4 + 2] == r),
  ];
}

/// The same inside test the rasteriser makes, evaluated from scratch.
///
/// Deliberately the slow, obvious form: this is the reference, and its only
/// virtue is that it is impossible to get subtly wrong.
List<bool> _referenceCoverage(
  Framebuffer target,
  Mesh3D mesh,
  MeshCamera camera,
) {
  final int width = target.width;
  final int height = target.height;
  final Matrix4 vp =
      camera.projectionMatrix(width / height).multiply(camera.viewMatrix());
  final MeshPrimitive primitive = mesh.primitives.single;
  final List<double> sx = <double>[];
  final List<double> sy = <double>[];
  for (var v = 0; v < 3; v++) {
    final int p = primitive.indices[v] * 3;
    final Vector3 world = Vector3(
      primitive.positions[p],
      primitive.positions[p + 1],
      primitive.positions[p + 2],
    );
    final Float64List m = vp.storage;
    final double x = m[0] * world.x + m[4] * world.y + m[8] * world.z + m[12];
    final double y = m[1] * world.x + m[5] * world.y + m[9] * world.z + m[13];
    final double w = m[3] * world.x + m[7] * world.y + m[11] * world.z + m[15];
    sx.add((x / w + 1) * 0.5 * width);
    sy.add((1 - y / w) * 0.5 * height);
  }

  final double area =
      (sx[1] - sx[0]) * (sy[2] - sy[0]) - (sx[2] - sx[0]) * (sy[1] - sy[0]);
  final bool backFacing = area > 0;

  return <bool>[
    for (var py = 0; py < height; py++)
      for (var px = 0; px < width; px++)
        () {
          final double x = px + 0.5;
          final double y = py + 0.5;
          final double w0 =
              (sx[2] - sx[1]) * (y - sy[1]) - (sy[2] - sy[1]) * (x - sx[1]);
          final double w1 =
              (sx[0] - sx[2]) * (y - sy[2]) - (sy[0] - sy[2]) * (x - sx[2]);
          final double w2 =
              (sx[1] - sx[0]) * (y - sy[0]) - (sy[1] - sy[0]) * (x - sx[0]);
          if (backFacing) return w0 >= 0 && w1 >= 0 && w2 >= 0;
          return w0 <= 0 && w1 <= 0 && w2 <= 0;
        }(),
  ];
}

void main() {
  const int background = 0xFF000000;

  group('the incremental edge functions', () {
    test('cover exactly what a direct evaluation covers', () {
      // The regression. Under the sign bug this failed on every row but the
      // first, and only here - every count the rasteriser reports was right.
      final MeshRasterizer rasterizer = MeshRasterizer();
      final MeshCamera camera = _straightOn();

      for (final Mesh3D mesh in <Mesh3D>[
        _triangle(
          const Vector3(-1, -1, 0),
          const Vector3(1, -1, 0),
          const Vector3(0, 1, 0),
        ),
        // A sliver, whose bounding box is many times its area: the shape that
        // makes stepping worth doing and the shape it goes wrong on.
        _triangle(
          const Vector3(-1.2, -1, 0),
          const Vector3(1.2, -0.95, 0),
          const Vector3(1.1, -0.9, 0),
        ),
        // Reversed winding, so the other branch of the sign test runs.
        _triangle(
          const Vector3(0, 1, 0),
          const Vector3(1, -1, 0),
          const Vector3(-1, -1, 0),
          doubleSided: true,
        ),
        // Off-centre and partly outside the frame, so the bounding box is
        // clamped on two sides.
        _triangle(
          const Vector3(-3, -0.5, 0),
          const Vector3(0.4, -0.6, 0),
          const Vector3(0.2, 1.9, 0),
          doubleSided: true,
        ),
      ]) {
        final Framebuffer target = Framebuffer.allocate(width: 64, height: 48);
        rasterizer.render(
          target,
          mesh,
          camera,
          shading: MeshShading.unlit,
          backgroundArgb: background,
        );

        final List<bool> got = _coverage(target, background);
        final List<bool> want = _referenceCoverage(target, mesh, camera);
        var differences = 0;
        for (var i = 0; i < got.length; i++) {
          if (got[i] != want[i]) differences++;
        }
        expect(
          differences,
          0,
          reason: 'the stepped loop and the direct formula disagree on '
              '$differences of ${got.length} pixels',
        );
      }
    });

    test('and the sliver really does have a box much larger than itself', () {
      // Guards the case above from becoming vacuous: if this stopped being a
      // sliver, the test would no longer exercise the shape the optimisation
      // exists for.
      final MeshRasterizer rasterizer = MeshRasterizer();
      final Framebuffer target = Framebuffer.allocate(width: 64, height: 48);
      rasterizer.render(
        target,
        _triangle(
          const Vector3(-1.2, -1, 0),
          const Vector3(1.2, -0.95, 0),
          const Vector3(1.1, -0.9, 0),
        ),
        _straightOn(),
        shading: MeshShading.unlit,
        backgroundArgb: background,
      );
      final int covered =
          _coverage(target, background).where((bool b) => b).length;
      expect(covered, greaterThan(0));
      expect(covered, lessThan(64 * 48 ~/ 8));
    });
  });

  group('depth', () {
    test('a nearer triangle hides a farther one whatever the draw order', () {
      // Both orders, because a depth buffer that is not consulted still gets
      // one of the two right - the one where the near triangle happens to be
      // drawn last.
      int colorAt(bool nearFirst) {
        final Mesh3D mesh = Mesh3D(
          name: 'two',
          format: 'test',
          primitives: <MeshPrimitive>[
            for (final bool near
                in nearFirst ? <bool>[true, false] : <bool>[false, true])
              MeshPrimitive(
                positions: Float32List.fromList(<double>[
                  -1, -1, near ? 0.5 : -0.5, //
                  1, -1, near ? 0.5 : -0.5, //
                  0, 1, near ? 0.5 : -0.5, //
                ]),
                indices: Uint32List.fromList(<int>[0, 1, 2]),
                material: MeshMaterial(
                  colorArgb: near ? 0xFFFF0000 : 0xFF0000FF,
                ),
              ),
          ],
        );
        final Framebuffer target = Framebuffer.allocate(width: 32, height: 32);
        MeshRasterizer().render(
          target,
          mesh,
          _straightOn(),
          shading: MeshShading.unlit,
          backgroundArgb: background,
        );
        // The centre of the frame, which both triangles cover.
        final int at = 20 * target.bytesPerRow + 16 * 4;
        return (0xFF << 24) |
            (target.pixels[at + 2] << 16) |
            (target.pixels[at + 1] << 8) |
            target.pixels[at];
      }

      expect(colorAt(true), 0xFFFF0000, reason: 'near drawn first');
      expect(colorAt(false), 0xFFFF0000, reason: 'near drawn last');
    });
  });

  group('facing', () {
    test('a back face is culled and a double-sided one is not', () {
      int coveredFor({required bool doubleSided}) {
        final Framebuffer target = Framebuffer.allocate(width: 48, height: 48);
        MeshRasterizer().render(
          target,
          // Clockwise on screen, which is the back face here.
          _triangle(
            const Vector3(0, 1, 0),
            const Vector3(1, -1, 0),
            const Vector3(-1, -1, 0),
            doubleSided: doubleSided,
          ),
          _straightOn(),
          shading: MeshShading.unlit,
          backgroundArgb: background,
        );
        return _coverage(target, background).where((bool b) => b).length;
      }

      expect(coveredFor(doubleSided: false), 0);
      expect(coveredFor(doubleSided: true), greaterThan(100));
    });

    test('and the front face draws either way', () {
      int coveredFor({required bool doubleSided}) {
        final Framebuffer target = Framebuffer.allocate(width: 48, height: 48);
        MeshRasterizer().render(
          target,
          _triangle(
            const Vector3(-1, -1, 0),
            const Vector3(1, -1, 0),
            const Vector3(0, 1, 0),
            doubleSided: doubleSided,
          ),
          _straightOn(),
          shading: MeshShading.unlit,
          backgroundArgb: background,
        );
        return _coverage(target, background).where((bool b) => b).length;
      }

      expect(coveredFor(doubleSided: false), greaterThan(100));
      expect(
        coveredFor(doubleSided: true),
        coveredFor(doubleSided: false),
        reason: 'culling must not change what a front face covers',
      );
    });
  });

  group('the near plane', () {
    test('a triangle crossing the camera is clipped, not mirrored', () {
      // Without clipping, the vertex behind the camera divides by a negative
      // `w` and lands on the opposite side of the screen, so the triangle
      // stretches across the whole frame. The symptom is unmistakable once you
      // know it and looks like a camera bug until then.
      final Framebuffer target = Framebuffer.allocate(width: 64, height: 64);
      final MeshRasterizer rasterizer = MeshRasterizer();
      rasterizer.render(
        target,
        // One vertex well behind the eye, which sits at z = +3.
        _triangle(
          const Vector3(-1, -1, 0),
          const Vector3(1, -1, 0),
          const Vector3(0, 1, 8),
          doubleSided: true,
        ),
        _straightOn(),
        shading: MeshShading.unlit,
        backgroundArgb: background,
      );

      expect(rasterizer.stats.clipped, 1);
      final int covered =
          _coverage(target, background).where((bool b) => b).length;
      expect(covered, greaterThan(0), reason: 'the part in front still draws');
      expect(
        covered,
        lessThan(64 * 64),
        reason: 'a mirrored vertex fills the frame; a clipped one cannot',
      );
    });

    test('a triangle entirely behind the camera draws nothing', () {
      final Framebuffer target = Framebuffer.allocate(width: 32, height: 32);
      final MeshRasterizer rasterizer = MeshRasterizer();
      rasterizer.render(
        target,
        _triangle(
          const Vector3(-1, -1, 9),
          const Vector3(1, -1, 9),
          const Vector3(0, 1, 9),
          doubleSided: true,
        ),
        _straightOn(),
        shading: MeshShading.unlit,
        backgroundArgb: background,
      );

      expect(_coverage(target, background).where((bool b) => b), isEmpty);
      expect(rasterizer.stats.drawn, 0);
    });
  });

  group('the camera', () {
    test('frames a model whatever its scale', () {
      // A viewer opens a 0.2-unit figurine and a 500-unit landscape without
      // being told which it got, so the framing has to come from the bounds.
      for (final double scale in <double>[0.01, 1, 500]) {
        final Bounds3 bounds = Bounds3(
          Vector3(-scale, -scale, -scale),
          Vector3(scale, scale, scale),
        );
        final MeshCamera camera = MeshCamera.frame(bounds);
        final Framebuffer target = Framebuffer.allocate(width: 64, height: 64);
        MeshRasterizer().render(
          target,
          _triangle(
            Vector3(-scale, -scale, 0),
            Vector3(scale, -scale, 0),
            Vector3(0, scale, 0),
            doubleSided: true,
          ),
          camera,
          shading: MeshShading.unlit,
          backgroundArgb: background,
        );
        final int covered =
            _coverage(target, background).where((bool b) => b).length;
        expect(
          covered,
          greaterThan(200),
          reason: 'at scale $scale the model came out too small to see',
        );
        expect(
          covered,
          lessThan(64 * 64),
          reason: 'at scale $scale the model overflowed the frame',
        );
      }
    });

    test('looking straight down does not collapse the view', () {
      // The pole. `up` and the view direction are parallel there, the basis
      // built from their cross product is degenerate, and an unguarded
      // `lookAt` produces NaNs that make the model vanish.
      const MeshCamera camera = MeshCamera(
        target: Vector3.zero,
        distance: 3,
        yaw: 0,
        pitch: math.pi / 2,
        near: 0.1,
        far: 100,
      );
      final Matrix4 view = camera.viewMatrix();
      for (var i = 0; i < 16; i++) {
        expect(view[i].isNaN, isFalse, reason: 'element $i is NaN');
      }
    });

    test('and the pitch stops short of it', () {
      final MeshCamera camera = MeshCamera.frame(
        const Bounds3(Vector3(-1, -1, -1), Vector3(1, 1, 1)),
      );
      expect(camera.withPitch(10).pitch, lessThan(math.pi / 2));
      expect(camera.withPitch(-10).pitch, greaterThan(-math.pi / 2));
    });
  });

  group('what the statistics claim', () {
    test('drawn plus culled accounts for every triangle', () {
      final Mesh3D mesh = Mesh3D(
        name: 'pair',
        format: 'test',
        primitives: <MeshPrimitive>[
          MeshPrimitive(
            positions: Float32List.fromList(<double>[
              -1, -1, 0, 1, -1, 0, 0, 1, 0, //
              0, 1, 0.2, 1, -1, 0.2, -1, -1, 0.2, //
            ]),
            indices: Uint32List.fromList(<int>[0, 1, 2, 3, 4, 5]),
          ),
        ],
      );
      final MeshRasterizer rasterizer = MeshRasterizer();
      rasterizer.render(
        Framebuffer.allocate(width: 32, height: 32),
        mesh,
        _straightOn(),
        shading: MeshShading.unlit,
        backgroundArgb: background,
      );

      final MeshRenderStats stats = rasterizer.stats;
      expect(stats.triangles, 2);
      expect(stats.drawn + stats.culled, 2);
      expect(stats.drawn, 1, reason: 'one of the two faces away');
    });
  });
}
