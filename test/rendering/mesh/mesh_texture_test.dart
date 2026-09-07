/// Texturing, and the one property that is easy to get wrong and hard to see:
/// perspective correction.
///
/// Barycentric weights are linear in screen space. Texture coordinates are not.
/// Interpolating `u` and `v` directly across a triangle seen at an angle gives
/// the affine wobble of a fifth-generation console — and on a single triangle
/// it looks merely soft, not wrong. Where it becomes unmistakable is a **quad
/// split into two triangles**: each interpolates its own half affinely, the two
/// halves disagree along the shared diagonal, and a seam appears there.
///
/// So that is what the first case measures. It needs no reference renderer and
/// no golden image: it asks whether the texture is continuous across a
/// diagonal that the geometry says is flat.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/graphics/mesh/mesh3d.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_rasterizer.dart';
import 'package:test/test.dart';

/// A texture whose red channel is a horizontal ramp and green a vertical one.
///
/// A ramp rather than a checkerboard: a checkerboard makes a seam obvious to an
/// eye and a ramp makes it *measurable*, because the value at a pixel is a
/// linear function of the coordinate the interpolation is supposed to produce.
MeshTexture _ramp({int size = 256}) {
  final Uint32List pixels = Uint32List(size * size);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final int r = x * 255 ~/ (size - 1);
      final int g = y * 255 ~/ (size - 1);
      pixels[y * size + x] = 0xFF000000 | (r << 16) | (g << 8);
    }
  }
  return MeshTexture(width: size, height: size, pixels: pixels, name: 'ramp');
}

/// A unit quad in the z = 0 plane, split into two triangles along the diagonal
/// from its bottom-left to its top-right corner.
Mesh3D _quad({required MeshTexture texture, double halfSize = 1}) => Mesh3D(
      name: 'quad',
      format: 'test',
      primitives: <MeshPrimitive>[
        MeshPrimitive(
          positions: Float32List.fromList(<double>[
            -halfSize, -halfSize, 0, //
            halfSize, -halfSize, 0, //
            halfSize, halfSize, 0, //
            -halfSize, halfSize, 0, //
          ]),
          // glTF UV convention: v grows downward, so the top-left corner of the
          // image is at (0, 0) and the bottom-left vertex takes v = 1.
          uvs: Float32List.fromList(<double>[
            0, 1, //
            1, 1, //
            1, 0, //
            0, 0, //
          ]),
          indices: Uint32List.fromList(<int>[0, 1, 2, 0, 2, 3]),
          material: MeshMaterial(
            // White, so the sampled texel reaches the framebuffer unchanged.
            // The default material colour is a grey, and forgetting it is what
            // made the first version of the perspective case below read a
            // tinted value and conclude the interpolation was affine when it
            // was not.
            colorArgb: 0xFFFFFFFF,
            doubleSided: true,
            baseColorTexture: texture,
          ),
        ),
      ],
    );

int _pixelAt(Framebuffer target, int x, int y) {
  final int at = y * target.bytesPerRow + x * 4;
  return (target.pixels[at + 2] << 16) |
      (target.pixels[at + 1] << 8) |
      target.pixels[at];
}

void main() {
  const int background = 0xFF101010;

  group('perspective correction', () {
    // The first version of this group scanned for a discontinuity along the
    // quad's shared diagonal and asserted it was small. It passed - and it
    // **also passed with the correction removed**, which makes it worse than
    // no test: the affine error on this geometry is a handful of levels, well
    // under any threshold that ordinary ramp stepping leaves room for. It was
    // replaced rather than tuned, because a threshold chosen to make a
    // sabotage fail is a threshold chosen to fit the answer.
    //
    // What follows measures the thing itself. Across a tilted quad, affine
    // interpolation puts `u = 0.5` at the **screen** midpoint of the two edges;
    // perspective correction puts it where the surface's own midpoint
    // projects, which under foreshortening is a long way from that. The two
    // predictions are computed here from the camera, and the render is asked
    // which one it agrees with.

    const MeshCamera camera = MeshCamera(
      target: Vector3.zero,
      distance: 2.2,
      yaw: 1.15,
      pitch: 0,
      near: 0.05,
      far: 50,
    );
    const int size = 256;

    /// Where [point] lands on the screen, in pixels.
    double screenXOf(Vector3 point) {
      final Matrix4 vp =
          camera.projectionMatrix(1).multiply(camera.viewMatrix());
      final Float64List m = vp.storage;
      final double x = m[0] * point.x + m[4] * point.y + m[8] * point.z + m[12];
      final double w =
          m[3] * point.x + m[7] * point.y + m[11] * point.z + m[15];
      return (x / w + 1) * 0.5 * size;
    }

    /// The screen x where the red ramp crosses [target], on the centre row.
    double? crossingOf(Framebuffer frame, int target) {
      final int y = size ~/ 2;
      for (var x = 1; x < size; x++) {
        final int left = _pixelAt(frame, x - 1, y);
        final int right = _pixelAt(frame, x, y);
        if (left == (background & 0xFFFFFF)) continue;
        if (right == (background & 0xFFFFFF)) continue;
        final int a = (left >> 16) & 0xFF;
        final int b = (right >> 16) & 0xFF;
        if ((a - target) * (b - target) <= 0 && a != b) {
          return x - 1 + (target - a) / (b - a);
        }
      }
      return null;
    }

    test(
        'u = 0.5 lands where the surface midpoint projects, not at the '
        'screen midpoint', () {
      final Framebuffer frame = Framebuffer.allocate(width: size, height: size);
      MeshRasterizer().render(
        frame,
        _quad(texture: _ramp()),
        camera,
        shading: MeshShading.unlit,
        backgroundArgb: background,
      );

      // The quad spans x = -1 to x = 1 with u = 0 to u = 1. Its midpoint in
      // *object* space is the origin; the midpoint in *screen* space is the
      // average of the two edges' projections. Under this tilt they differ.
      final double perspective = screenXOf(Vector3.zero);
      final double affine = (screenXOf(const Vector3(-1, 0, 0)) +
              screenXOf(const Vector3(1, 0, 0))) /
          2;

      expect(
        (perspective - affine).abs(),
        greaterThan(6),
        reason: 'the tilt has to be strong enough that the two predictions '
            'are distinguishable, or this case proves nothing',
      );

      final double? crossing = crossingOf(frame, 128);
      expect(crossing, isNotNull, reason: 'the ramp must cross its midpoint');
      expect(
        (crossing! - perspective).abs(),
        lessThan((crossing - affine).abs()),
        reason: 'u = 0.5 landed at $crossing, which is nearer the affine '
            'prediction $affine than the perspective-correct one $perspective',
      );
      expect(
        (crossing - perspective).abs(),
        lessThan(3),
        reason: 'within a few pixels of where the surface midpoint projects',
      );
    });
  });

  group('sampling', () {
    test('a texture is sampled rather than the flat material colour', () {
      final Framebuffer target = Framebuffer.allocate(width: 64, height: 64);
      MeshRasterizer().render(
        target,
        _quad(texture: _ramp()),
        const MeshCamera(
          target: Vector3.zero,
          distance: 2.6,
          yaw: 0,
          pitch: 0,
          near: 0.05,
          far: 50,
        ),
        shading: MeshShading.unlit,
        backgroundArgb: background,
      );

      final Set<int> colours = <int>{};
      for (var y = 0; y < 64; y++) {
        for (var x = 0; x < 64; x++) {
          final int pixel = _pixelAt(target, x, y);
          if (pixel != (background & 0xFFFFFF)) colours.add(pixel);
        }
      }
      expect(
        colours.length,
        greaterThan(100),
        reason: 'an unlit flat material produces exactly one colour; a ramp '
            'texture must produce many',
      );
    });

    test('the material colour multiplies the texture rather than hiding it',
        () {
      // glTF's rule, and the one that makes a white factor a no-op. A material
      // that replaced the texture would make every tinted model flat.
      int redAt(int factor) {
        final Framebuffer target = Framebuffer.allocate(width: 32, height: 32);
        MeshRasterizer().render(
          target,
          Mesh3D(
            name: 'tint',
            format: 'test',
            primitives: <MeshPrimitive>[
              MeshPrimitive(
                positions: Float32List.fromList(<double>[
                  -1, -1, 0, 1, -1, 0, 1, 1, 0, //
                  -1, -1, 0, 1, 1, 0, -1, 1, 0, //
                ]),
                // Just inside the right edge and not exactly on it: `u = 1`
                // wraps to texel 0 by the definition of REPEAT, which is
                // correct and is not what this case is about.
                uvs: Float32List.fromList(<double>[
                  0.999, 0, 0.999, 0, 0.999, 0, //
                  0.999, 0, 0.999, 0, 0.999, 0, //
                ]),
                indices: Uint32List.fromList(<int>[0, 1, 2, 3, 4, 5]),
                material: MeshMaterial(
                  colorArgb: factor,
                  doubleSided: true,
                  baseColorTexture: _ramp(),
                ),
              ),
            ],
          ),
          const MeshCamera(
            target: Vector3.zero,
            distance: 2.6,
            yaw: 0,
            pitch: 0,
            near: 0.05,
            far: 50,
          ),
          shading: MeshShading.unlit,
          backgroundArgb: background,
        );
        return (_pixelAt(target, 16, 16) >> 16) & 0xFF;
      }

      // The sampled texel is the ramp's rightmost column: red 255.
      expect(redAt(0xFFFFFFFF), 255, reason: 'a white factor is a no-op');
      expect(redAt(0xFF808080), closeTo(128, 2), reason: 'half tints to half');
      expect(redAt(0xFF000000), 0, reason: 'black multiplies to black');
    });

    test('sampling wraps rather than clamping', () {
      // `REPEAT` is the default in glTF and in OBJ. A model tiling a floor has
      // UVs well outside the unit square, and clamping would smear one edge
      // texel across all of it.
      final MeshTexture texture = _ramp(size: 4);
      expect(texture.sample(0.1, 0.1), texture.sample(1.1, 1.1));
      expect(texture.sample(0.1, 0.1), texture.sample(-0.9, -0.9));
    });

    test('a white texel times a white factor stays white', () {
      // The rounding trap: `(a * b) >> 8` is a divide by 256 and leaves
      // 255 x 255 at 254, so every fully lit textured surface would come out
      // one level dark - invisible alone and a visible seam where a textured
      // mesh meets an untextured one.
      final Uint32List white = Uint32List.fromList(<int>[0xFFFFFFFF]);
      final MeshTexture texture =
          MeshTexture(width: 1, height: 1, pixels: white);
      final Framebuffer target = Framebuffer.allocate(width: 16, height: 16);
      MeshRasterizer().render(
        target,
        Mesh3D(
          name: 'white',
          format: 'test',
          primitives: <MeshPrimitive>[
            MeshPrimitive(
              positions: Float32List.fromList(<double>[
                -1, -1, 0, 1, -1, 0, 1, 1, 0, //
                -1, -1, 0, 1, 1, 0, -1, 1, 0, //
              ]),
              uvs: Float32List.fromList(
                <double>[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
              ),
              indices: Uint32List.fromList(<int>[0, 1, 2, 3, 4, 5]),
              material: MeshMaterial(
                // White, deliberately: the default material colour is a grey,
                // and leaving it would make this measure the multiply rather
                // than the rounding it is about.
                colorArgb: 0xFFFFFFFF,
                doubleSided: true,
                baseColorTexture: texture,
              ),
            ),
          ],
        ),
        const MeshCamera(
          target: Vector3.zero,
          distance: 2.6,
          yaw: 0,
          pitch: 0,
          near: 0.05,
          far: 50,
        ),
        shading: MeshShading.unlit,
        backgroundArgb: background,
      );

      expect(_pixelAt(target, 8, 8), 0xFFFFFF);
    });
  });
}
