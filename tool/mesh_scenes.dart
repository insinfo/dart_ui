/// The model both mesh probes draw, and the metric both of them report.
///
/// Shared between `tool/gl_mesh_probe.dart` and
/// `test/rendering/gpu/gl/gl_mesh_pipeline_test.dart` on purpose. The scene is
/// not decoration: every shape in it exists to make one specific pipeline
/// mistake visible, and a test and a probe that measured *different* scenes
/// could disagree about whether the pipeline works without either being wrong.
/// The tolerance argument in [compareMeshImages] is the same case: it has to
/// live in one place or it becomes two different arguments.
///
/// ## Why comparing a 3D render pixel-for-pixel needs an argument
///
/// The 2D differential suite (`test/differential/cpu_gpu_parity_test.dart`)
/// declares a tolerance of **zero** on every scene, and it is right to: both
/// backends rasterise the same coverage with the same `ScanlineFiller` and
/// differ only in where they round. Nothing in that argument survives here.
///
/// A triangle rasteriser makes a *coverage* decision per pixel, and the two
/// make it differently by construction:
///
///   * GL snaps every vertex to a fixed-point sub-pixel grid before it
///     rasterises - the spec requires at least four fractional bits and most
///     hardware uses eight - while `MeshRasterizer._drawProjected` evaluates
///     float edge functions at pixel centres. A vertex that lands 1/512 of a
///     pixel from a boundary can fall on either side of it.
///   * GL applies a fill rule that draws a pixel on a shared edge exactly
///     once. The CPU test is inclusive on both sides (`e0 > 0 || ...` with a
///     `continue`), so it draws such a pixel twice and lets the depth test
///     decide. Both are correct for opaque geometry and they resolve ties
///     differently.
///
/// So a boundary pixel can be background in one image and lit surface in the
/// other, which is a difference of a hundred levels with nothing wrong. What
/// *is* bounded is where those pixels can be: on a boundary. So the comparison
/// is split in two, and only one half has a tight tolerance:
///
///   * [MeshImageDiff.interiorDeviation] is measured only over pixels whose
///     3x3 neighbourhood in the CPU image spans at most
///     [_interiorFlatness] levels. There the picture is locally smooth, a
///     one-pixel coverage disagreement can move the value by at most that
///     much, and everything above it is a real disagreement about *shading* -
///     which is the thing this pipeline is supposed to have got exactly right.
///   * [MeshImageDiff.edgeRatio] is the differing pixels over the pixels that
///     sit on a discontinuity in the CPU image. It says the differences are
///     confined to boundaries rather than spread over surfaces. A ratio near
///     or below one is the claim; a ratio well above one means something is
///     wrong in the interior and is hiding behind the edge budget.
///
/// Neither number is a knob to widen until a test passes. If the interior
/// deviation moves, one of the two shading paths changed.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_ui/src/graphics/mesh/mesh3d.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_rasterizer.dart';

/// How flat a 3x3 neighbourhood has to be for its centre to count as interior.
///
/// Two levels, not eight. The looser the threshold the more of a silhouette
/// leaks into the interior set, and the interior number is the only one with a
/// tight bound on it - so it is kept tight enough that a pixel inside it
/// really is on a smooth surface.
const int _interiorFlatness = 2;

/// The scene, built rather than loaded.
///
/// A file would make the probe depend on a model nobody else has. Every shape
/// here is chosen for a failure it exposes:
///
///   * **Two closed boxes that overlap on screen**, the far one listed
///     *after* the near one. Without a depth test the far box paints over the
///     near one, which is what `--sabotage=depth` produces and what a surface
///     with no depth bits produces silently.
///   * **Both boxes single-sided and closed.** Reverse the winding and every
///     front face is culled and every back face drawn: the boxes turn inside
///     out. That is what `--sabotage=winding` produces, and it is the failure
///     that reads as a normals bug.
///   * **A sphere with true per-vertex normals**, which is the only shape here
///     whose normal varies *within* a triangle. It is what measures the one
///     genuine shading difference between the two paths: GL interpolates a
///     varying with perspective correction and `MeshRasterizer` interpolates
///     normals affinely, on purpose ("a shading gradient a fraction of a
///     percent off is invisible where a sliding checkerboard is not").
///   * **A double-sided floor with a checkerboard whose `u` runs 0..2.5**,
///     which is the only shape that tests `GL_REPEAT` - the fractional end
///     also means the tile does not land on a texel boundary, so a wrap
///     implemented with a clamp shows immediately. Seen at a grazing angle, so
///     it also tests perspective-correct `u/w` against affine texturing.
///   * The floor is under everything, so **the depth test decides most of the
///     frame**, not the draw order.
Mesh3D buildProbeScene() {
  final _Builder near = _Builder(0xFFCC4433);
  near.addBox(
    const Vector3(-1.15, -0.45, 0.55),
    const Vector3(-0.15, 0.55, 1.55),
  );
  final _Builder far = _Builder(0xFF3366CC);
  far.addBox(
    const Vector3(0.05, -0.45, -1.45),
    const Vector3(1.25, 0.75, -0.25),
  );
  final _Builder sphere = _Builder(0xFFE8C860);
  sphere.addSphere(const Vector3(0, 1.05, 0), 0.62, 20, 14);
  final _Builder floor = _Builder(0xFFFFFFFF);
  floor.addFloor(-0.45, 2.4, 2.5);

  return Mesh3D(
    name: 'probe-scene',
    format: 'built-in',
    primitives: <MeshPrimitive>[
      // The near box first and the far box second, so submission order and
      // depth order disagree.
      near.build(),
      far.build(),
      sphere.build(),
      floor.build(
        material: MeshMaterial(
          name: 'floor',
          // White, so the texture arrives unmodulated: glTF multiplies the map
          // by the factor, and a tinted factor here would hide a wrong
          // multiply behind a colour nobody could check.
          colorArgb: 0xFFFFFFFF,
          doubleSided: true,
          baseColorTexture: buildCheckerTexture(),
        ),
      ),
    ],
  );
}

/// The camera the built-in scene is framed with.
///
/// Fixed rather than derived from the bounds, because the whole point of the
/// scene is which shape occludes which and a camera that moved when a shape
/// was added would quietly change the test.
const MeshCamera probeSceneCamera = MeshCamera(
  target: Vector3(0, 0.1, 0),
  distance: 5.2,
  yaw: 0.62,
  pitch: 0.34,
  near: 0.05,
  far: 40,
);

/// An 8x8 checkerboard, which is what makes a wrap mode visible.
MeshTexture buildCheckerTexture() {
  const int size = 8;
  final Uint32List pixels = Uint32List(size * size);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final bool light = ((x ~/ 2) + (y ~/ 2)).isEven;
      pixels[y * size + x] = light ? 0xFFE8E8E8 : 0xFF303840;
    }
  }
  return MeshTexture(
    width: size,
    height: size,
    pixels: pixels,
    name: 'checker',
  );
}

// ---------------------------------------------------------------------------
// The comparison
// ---------------------------------------------------------------------------

/// What separated two renders of the same scene. See the library comment.
final class MeshImageDiff {
  const MeshImageDiff({
    required this.maxDeviation,
    required this.interiorDeviation,
    required this.interiorPixels,
    required this.edgePixels,
    required this.differingPixels,
    required this.totalPixels,
    required this.report,
  });

  /// The largest per-channel difference anywhere, boundary pixels included.
  /// Expected to be large and *not* a tolerance - see the library comment.
  final int maxDeviation;

  /// The largest per-channel difference over locally smooth pixels. The number
  /// with a tight bound on it.
  final int interiorDeviation;

  final int interiorPixels;

  /// Pixels sitting on a discontinuity in the reference image.
  final int edgePixels;

  final int differingPixels;
  final int totalPixels;

  /// The first few disagreements, both sides shown.
  final String report;

  double get differingFraction =>
      totalPixels == 0 ? 0 : differingPixels / totalPixels;

  /// Differing pixels over discontinuity pixels. At most about one means the
  /// differences are confined to boundaries, which is the claim.
  double get edgeRatio => edgePixels == 0 ? 0 : differingPixels / edgePixels;

  @override
  String toString() => 'interior $interiorDeviation over $interiorPixels px, '
      'max $maxDeviation, $differingPixels/$totalPixels differing, '
      'edge ratio ${edgeRatio.toStringAsFixed(2)}';
}

/// Compares [reference] - the CPU render - against [candidate].
///
/// Both must be the same size and both must hold BGRA bytes, which is what
/// `MeshRasterizer` writes and what `GlMeshOffscreenSurface.readInto` swizzles
/// into for a [PixelFormat.bgra8888Premultiplied] destination.
MeshImageDiff compareMeshImages(Framebuffer reference, Framebuffer candidate) {
  if (reference.width != candidate.width ||
      reference.height != candidate.height) {
    throw ArgumentError('the two images are different sizes');
  }
  final int width = reference.width;
  final int height = reference.height;
  var maxDeviation = 0;
  var interiorDeviation = 0;
  var interiorPixels = 0;
  var edgePixels = 0;
  var differing = 0;
  final lines = <String>[];

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final int a = reference.offsetOf(x, y);
      final int b = candidate.offsetOf(x, y);
      var deviation = 0;
      for (var channel = 0; channel < 3; channel++) {
        final int delta =
            (reference.pixels[a + channel] - candidate.pixels[b + channel])
                .abs();
        if (delta > deviation) deviation = delta;
      }
      final int flatness = _localRange(reference, x, y);
      // The border ring is treated as an edge: its neighbourhood is not fully
      // sampled, so calling it smooth would be an assumption rather than a
      // measurement.
      final bool interior = flatness <= _interiorFlatness &&
          x > 0 &&
          y > 0 &&
          x < width - 1 &&
          y < height - 1;
      if (interior) {
        interiorPixels++;
        if (deviation > interiorDeviation) {
          interiorDeviation = deviation;
          if (lines.length < 12 && deviation > 0) {
            lines.add('interior ($x, $y): cpu '
                '${_bgr(reference, a)} gpu ${_bgr(candidate, b)}');
          }
        }
      } else {
        edgePixels++;
      }
      if (deviation > maxDeviation) maxDeviation = deviation;
      if (deviation != 0) differing++;
    }
  }

  return MeshImageDiff(
    maxDeviation: maxDeviation,
    interiorDeviation: interiorDeviation,
    interiorPixels: interiorPixels,
    edgePixels: edgePixels,
    differingPixels: differing,
    totalPixels: width * height,
    report: lines.join('\n'),
  );
}

String _bgr(Framebuffer buffer, int at) =>
    '(${buffer.pixels[at + 2]}, ${buffer.pixels[at + 1]}, '
    '${buffer.pixels[at]})';

/// The largest per-channel spread across the 3x3 neighbourhood of ([x], [y]).
int _localRange(Framebuffer buffer, int x, int y) {
  var range = 0;
  final int centre = buffer.offsetOf(x, y);
  for (var dy = -1; dy <= 1; dy++) {
    final int ny = y + dy;
    if (ny < 0 || ny >= buffer.height) continue;
    for (var dx = -1; dx <= 1; dx++) {
      final int nx = x + dx;
      if (nx < 0 || nx >= buffer.width) continue;
      final int at = buffer.offsetOf(nx, ny);
      for (var channel = 0; channel < 3; channel++) {
        final int delta =
            (buffer.pixels[centre + channel] - buffer.pixels[at + channel])
                .abs();
        if (delta > range) range = delta;
      }
    }
  }
  return range;
}

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------

/// Accumulates triangles with explicit normals.
///
/// Normals are written rather than left to [MeshPrimitive.computeSmoothNormals]
/// for the boxes and the floor, because an averaged normal at a box corner
/// would round the corner's shading and the box is here to have hard facets.
final class _Builder {
  _Builder(this.colorArgb);

  final int colorArgb;
  final List<double> positions = <double>[];
  final List<double> normals = <double>[];
  final List<double> uvs = <double>[];
  final List<int> indices = <int>[];

  int addVertex(Vector3 position, Vector3 normal, double u, double v) {
    final int index = positions.length ~/ 3;
    positions.addAll(<double>[position.x, position.y, position.z]);
    normals.addAll(<double>[normal.x, normal.y, normal.z]);
    uvs.addAll(<double>[u, v]);
    return index;
  }

  void addTriangle(int a, int b, int c) => indices.addAll(<int>[a, b, c]);

  /// One quad, wound counter-clockwise as seen from `t x b`.
  ///
  /// The tangent pair is passed rather than derived so that every face's
  /// winding is decided in one place: `t x b == n` is checked by the caller's
  /// choice of vectors, and a face wound the other way would be culled and
  /// leave a hole that looks like a missing triangle.
  void addQuad(Vector3 origin, Vector3 t, Vector3 b, Vector3 n,
      {double uScale = 1, double vScale = 1}) {
    final int v0 = addVertex(origin, n, 0, 0);
    final int v1 = addVertex(origin + t, n, uScale, 0);
    final int v2 = addVertex(origin + t + b, n, uScale, vScale);
    final int v3 = addVertex(origin + b, n, 0, vScale);
    addTriangle(v0, v1, v2);
    addTriangle(v0, v2, v3);
  }

  void addBox(Vector3 min, Vector3 max) {
    final double x0 = min.x;
    final double y0 = min.y;
    final double z0 = min.z;
    final double x1 = max.x;
    final double y1 = max.y;
    final double z1 = max.z;
    final double dx = x1 - x0;
    final double dy = y1 - y0;
    final double dz = z1 - z0;
    addQuad(Vector3(x1, y0, z1), Vector3(0, 0, -dz), Vector3(0, dy, 0),
        const Vector3(1, 0, 0));
    addQuad(Vector3(x0, y0, z0), Vector3(0, 0, dz), Vector3(0, dy, 0),
        const Vector3(-1, 0, 0));
    addQuad(Vector3(x0, y1, z1), Vector3(dx, 0, 0), Vector3(0, 0, -dz),
        const Vector3(0, 1, 0));
    addQuad(Vector3(x0, y0, z0), Vector3(dx, 0, 0), Vector3(0, 0, dz),
        const Vector3(0, -1, 0));
    addQuad(Vector3(x0, y0, z1), Vector3(dx, 0, 0), Vector3(0, dy, 0),
        const Vector3(0, 0, 1));
    addQuad(Vector3(x1, y0, z0), Vector3(-dx, 0, 0), Vector3(0, dy, 0),
        const Vector3(0, 0, -1));
  }

  /// A latitude-longitude sphere, wound counter-clockwise from outside.
  ///
  /// The winding is derived rather than guessed: with `p(phi, theta)` as
  /// `(sin phi sin theta, cos phi, sin phi cos theta)`, the cross product of
  /// the two partial derivatives is `sin phi * p`, which points outwards. So
  /// the quad `(phi, theta) -> (phi+1, theta) -> (phi+1, theta+1) ->
  /// (phi, theta+1)` is counter-clockwise seen from outside.
  void addSphere(Vector3 centre, double radius, int slices, int stacks) {
    final int base = positions.length ~/ 3;
    for (var i = 0; i <= stacks; i++) {
      final double phi = math.pi * i / stacks;
      for (var j = 0; j <= slices; j++) {
        final double theta = 2 * math.pi * j / slices;
        final Vector3 unit = Vector3(
          math.sin(phi) * math.sin(theta),
          math.cos(phi),
          math.sin(phi) * math.cos(theta),
        );
        addVertex(centre + unit * radius, unit, j / slices, i / stacks);
      }
    }
    for (var i = 0; i < stacks; i++) {
      for (var j = 0; j < slices; j++) {
        final int a = base + i * (slices + 1) + j;
        final int b = a + slices + 1;
        addTriangle(a, b, b + 1);
        addTriangle(a, b + 1, a + 1);
      }
    }
  }

  void addFloor(double y, double half, double uvRepeat) {
    addQuad(
      Vector3(-half, y, half),
      Vector3(2 * half, 0, 0),
      Vector3(0, 0, -2 * half),
      const Vector3(0, 1, 0),
      uScale: uvRepeat,
      vScale: uvRepeat,
    );
  }

  MeshPrimitive build({MeshMaterial? material}) => MeshPrimitive(
        positions: Float32List.fromList(positions),
        normals: Float32List.fromList(normals),
        uvs: Float32List.fromList(uvs),
        indices: Uint32List.fromList(indices),
        material: material ?? MeshMaterial(colorArgb: colorArgb),
      );
}
