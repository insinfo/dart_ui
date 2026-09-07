/// The three-dimensional types a viewer needs, and nothing more.
///
/// This repository is a 2D UI framework: its display list has commands for
/// paths, images, text and clips, and none for a triangle with depth. So a 3D
/// viewer here is not a matter of handing meshes to the existing GPU backends —
/// there is no pipeline to hand them to. What follows is the geometry and the
/// linear algebra; `mesh_rasterizer.dart` turns it into pixels on the CPU and
/// the result reaches the screen as an image, which is one `drawImage` on
/// whatever backend is running.
///
/// **That is a real limitation and it is stated rather than implied.** The GPU
/// backends draw this viewer's output; they do not draw its triangles. A GPU
/// mesh path would be a new vertex format, a new shader, a depth buffer and a
/// new pipeline in each of five backends, and pretending otherwise by calling
/// the software rasteriser "the renderer" would hide the size of that gap.
///
/// ## Why a mesh is flat arrays and not a list of objects
///
/// The sample models here run to 450,000 triangles. A `List<Triangle>` of that
/// size is 450,000 heap objects, three `Vector3` fields each, and a rasteriser
/// walking it spends its time chasing pointers. Positions, normals and indices
/// are [Float32List] and [Uint32List] for the same reason the display list is:
/// one allocation, sequential access, and no per-element garbage.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// A point or a direction in three dimensions.
///
/// A value type with no mutation: the rasteriser's inner loops work on the flat
/// arrays directly and never construct one of these, so the cost of immutability
/// is paid only where readability is worth more than speed.
final class Vector3 {
  const Vector3(this.x, this.y, this.z);

  static const Vector3 zero = Vector3(0, 0, 0);
  static const Vector3 up = Vector3(0, 1, 0);

  final double x;
  final double y;
  final double z;

  Vector3 operator +(Vector3 other) =>
      Vector3(x + other.x, y + other.y, z + other.z);

  Vector3 operator -(Vector3 other) =>
      Vector3(x - other.x, y - other.y, z - other.z);

  Vector3 operator *(double scalar) =>
      Vector3(x * scalar, y * scalar, z * scalar);

  double dot(Vector3 other) => x * other.x + y * other.y + z * other.z;

  Vector3 cross(Vector3 other) => Vector3(
        y * other.z - z * other.y,
        z * other.x - x * other.z,
        x * other.y - y * other.x,
      );

  double get length => math.sqrt(x * x + y * y + z * z);

  /// This vector scaled to unit length.
  ///
  /// A zero vector normalises to zero rather than to NaN. Degenerate triangles
  /// are common in exported models - a mesh with two coincident vertices is not
  /// malformed enough for any tool to complain - and a NaN normal propagates
  /// into the shading of everything that shares that vertex.
  Vector3 get normalized {
    final double l = length;
    return l == 0 ? zero : Vector3(x / l, y / l, z / l);
  }

  @override
  String toString() => 'Vector3(${x.toStringAsFixed(3)}, '
      '${y.toStringAsFixed(3)}, ${z.toStringAsFixed(3)})';
}

/// An axis-aligned box, which is what a viewer needs to frame a model it has
/// never seen.
final class Bounds3 {
  const Bounds3(this.min, this.max);

  /// The empty box, whose extremes are deliberately inverted so that the first
  /// point added replaces both. Starting at the origin instead would include a
  /// point the model may not contain, and a model far from the origin would be
  /// framed with the origin in shot.
  static const Bounds3 empty = Bounds3(
    Vector3(double.infinity, double.infinity, double.infinity),
    Vector3(-double.infinity, -double.infinity, -double.infinity),
  );

  final Vector3 min;
  final Vector3 max;

  bool get isEmpty => min.x > max.x;

  Vector3 get center => Vector3(
        (min.x + max.x) / 2,
        (min.y + max.y) / 2,
        (min.z + max.z) / 2,
      );

  Vector3 get size => Vector3(max.x - min.x, max.y - min.y, max.z - min.z);

  /// The longest edge, which is what a camera distance is derived from.
  double get extent {
    if (isEmpty) return 0;
    final Vector3 s = size;
    return math.max(s.x, math.max(s.y, s.z));
  }

  Bounds3 include(Vector3 point) => Bounds3(
        Vector3(
          math.min(min.x, point.x),
          math.min(min.y, point.y),
          math.min(min.z, point.z),
        ),
        Vector3(
          math.max(max.x, point.x),
          math.max(max.y, point.y),
          math.max(max.z, point.z),
        ),
      );

  Bounds3 union(Bounds3 other) =>
      other.isEmpty ? this : include(other.min).include(other.max);

  @override
  String toString() => 'Bounds3($min, $max)';
}

/// A 4x4 matrix, column-major.
///
/// **Column-major, like OpenGL and like glTF**, which matters because a glTF
/// node's `matrix` is sixteen numbers in that order and reading them as
/// row-major transposes every model that uses one. The layout is stated here
/// rather than left to be discovered from a model that renders inside out.
final class Matrix4 {
  const Matrix4(this.storage);

  factory Matrix4.identity() => Matrix4(Float64List.fromList(<double>[
        1, 0, 0, 0, //
        0, 1, 0, 0, //
        0, 0, 1, 0, //
        0, 0, 0, 1, //
      ]));

  factory Matrix4.translation(Vector3 t) => Matrix4(Float64List.fromList(
        <double>[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, t.x, t.y, t.z, 1],
      ));

  factory Matrix4.scale(Vector3 s) => Matrix4(Float64List.fromList(
        <double>[s.x, 0, 0, 0, 0, s.y, 0, 0, 0, 0, s.z, 0, 0, 0, 0, 1],
      ));

  /// A rotation from a unit quaternion `(x, y, z, w)`, which is how glTF writes
  /// one.
  factory Matrix4.rotationFromQuaternion(
    double x,
    double y,
    double z,
    double w,
  ) {
    final double x2 = x + x;
    final double y2 = y + y;
    final double z2 = z + z;
    final double xx = x * x2;
    final double xy = x * y2;
    final double xz = x * z2;
    final double yy = y * y2;
    final double yz = y * z2;
    final double zz = z * z2;
    final double wx = w * x2;
    final double wy = w * y2;
    final double wz = w * z2;
    return Matrix4(Float64List.fromList(<double>[
      1 - (yy + zz), xy + wz, xz - wy, 0, //
      xy - wz, 1 - (xx + zz), yz + wx, 0, //
      xz + wy, yz - wx, 1 - (xx + yy), 0, //
      0, 0, 0, 1, //
    ]));
  }

  /// A right-handed look-at view matrix.
  factory Matrix4.lookAt(Vector3 eye, Vector3 target, Vector3 up) {
    final Vector3 forward = (eye - target).normalized;
    Vector3 right = up.cross(forward).normalized;
    // The degenerate case that every orbit camera hits: looking straight down,
    // `up` and `forward` are parallel and their cross product is zero, so the
    // basis collapses and the model vanishes. Choosing any perpendicular axis
    // keeps the view valid; the roll it picks is arbitrary and unnoticeable
    // because the camera is at a pole.
    if (right.length == 0) {
      right = const Vector3(1, 0, 0).cross(forward).normalized;
      if (right.length == 0) right = const Vector3(0, 0, 1);
    }
    final Vector3 trueUp = forward.cross(right);
    return Matrix4(Float64List.fromList(<double>[
      right.x, trueUp.x, forward.x, 0, //
      right.y, trueUp.y, forward.y, 0, //
      right.z, trueUp.z, forward.z, 0, //
      -right.dot(eye), -trueUp.dot(eye), -forward.dot(eye), 1, //
    ]));
  }

  /// A right-handed perspective projection mapping depth into `[-1, 1]`.
  factory Matrix4.perspective({
    required double fovYRadians,
    required double aspect,
    required double near,
    required double far,
  }) {
    final double f = 1 / math.tan(fovYRadians / 2);
    final double range = 1 / (near - far);
    return Matrix4(Float64List.fromList(<double>[
      f / aspect, 0, 0, 0, //
      0, f, 0, 0, //
      0, 0, (far + near) * range, -1, //
      0, 0, 2 * far * near * range, 0, //
    ]));
  }

  /// Sixteen doubles, column-major.
  final Float64List storage;

  double operator [](int index) => storage[index];

  Matrix4 multiply(Matrix4 other) {
    final Float64List a = storage;
    final Float64List b = other.storage;
    final Float64List out = Float64List(16);
    for (var column = 0; column < 4; column++) {
      final int c = column * 4;
      for (var row = 0; row < 4; row++) {
        out[c + row] = a[row] * b[c] +
            a[4 + row] * b[c + 1] +
            a[8 + row] * b[c + 2] +
            a[12 + row] * b[c + 3];
      }
    }
    return Matrix4(out);
  }

  /// Transforms a point, applying the translation.
  Vector3 transformPoint(Vector3 v) {
    final Float64List m = storage;
    return Vector3(
      m[0] * v.x + m[4] * v.y + m[8] * v.z + m[12],
      m[1] * v.x + m[5] * v.y + m[9] * v.z + m[13],
      m[2] * v.x + m[6] * v.y + m[10] * v.z + m[14],
    );
  }

  /// Transforms a direction, ignoring the translation.
  ///
  /// Not the same as [transformPoint] with the translation subtracted
  /// afterwards, and the difference is the whole reason both exist: a normal
  /// carried through a translation is no longer a direction.
  Vector3 transformDirection(Vector3 v) {
    final Float64List m = storage;
    return Vector3(
      m[0] * v.x + m[4] * v.y + m[8] * v.z,
      m[1] * v.x + m[5] * v.y + m[9] * v.z,
      m[2] * v.x + m[6] * v.y + m[10] * v.z,
    );
  }

  /// The full 4x4 inverse, or the identity when the matrix is singular.
  ///
  /// The general inverse rather than the fast "orthonormal plus translation"
  /// one, because the matrices this is asked for are not orthonormal: an FBX
  /// bone's `TransformLink` carries the scale of every joint above it, and a
  /// model exported from 3ds Max in centimetres carries a factor of 2.54 in
  /// three axes at once. Inverting such a matrix by transposing the rotation
  /// block squares the scale instead of removing it, and the mesh comes out
  /// posed but the wrong size.
  ///
  /// The identity for a singular matrix rather than NaNs: a degenerate bone -
  /// a joint scaled to zero on one axis, which exporters do write - would
  /// otherwise poison every vertex weighted to it and take the whole model
  /// with it.
  Matrix4 get inverted {
    final Float64List m = storage;
    final Float64List out = Float64List(16);

    final double a00 = m[0], a01 = m[1], a02 = m[2], a03 = m[3];
    final double a10 = m[4], a11 = m[5], a12 = m[6], a13 = m[7];
    final double a20 = m[8], a21 = m[9], a22 = m[10], a23 = m[11];
    final double a30 = m[12], a31 = m[13], a32 = m[14], a33 = m[15];

    final double b00 = a00 * a11 - a01 * a10;
    final double b01 = a00 * a12 - a02 * a10;
    final double b02 = a00 * a13 - a03 * a10;
    final double b03 = a01 * a12 - a02 * a11;
    final double b04 = a01 * a13 - a03 * a11;
    final double b05 = a02 * a13 - a03 * a12;
    final double b06 = a20 * a31 - a21 * a30;
    final double b07 = a20 * a32 - a22 * a30;
    final double b08 = a20 * a33 - a23 * a30;
    final double b09 = a21 * a32 - a22 * a31;
    final double b10 = a21 * a33 - a23 * a31;
    final double b11 = a22 * a33 - a23 * a32;

    final double det =
        b00 * b11 - b01 * b10 + b02 * b09 + b03 * b08 - b04 * b07 + b05 * b06;
    if (det == 0 || det.isNaN || det.isInfinite) return Matrix4.identity();
    final double d = 1 / det;

    out[0] = (a11 * b11 - a12 * b10 + a13 * b09) * d;
    out[1] = (a02 * b10 - a01 * b11 - a03 * b09) * d;
    out[2] = (a31 * b05 - a32 * b04 + a33 * b03) * d;
    out[3] = (a22 * b04 - a21 * b05 - a23 * b03) * d;
    out[4] = (a12 * b08 - a10 * b11 - a13 * b07) * d;
    out[5] = (a00 * b11 - a02 * b08 + a03 * b07) * d;
    out[6] = (a32 * b02 - a30 * b05 - a33 * b01) * d;
    out[7] = (a20 * b05 - a22 * b02 + a23 * b01) * d;
    out[8] = (a10 * b10 - a11 * b08 + a13 * b06) * d;
    out[9] = (a01 * b08 - a00 * b10 - a03 * b06) * d;
    out[10] = (a30 * b04 - a31 * b02 + a33 * b00) * d;
    out[11] = (a21 * b02 - a20 * b04 - a23 * b00) * d;
    out[12] = (a11 * b07 - a10 * b09 - a12 * b06) * d;
    out[13] = (a00 * b09 - a01 * b07 + a02 * b06) * d;
    out[14] = (a31 * b01 - a30 * b03 - a32 * b00) * d;
    out[15] = (a20 * b03 - a21 * b01 + a22 * b00) * d;
    return Matrix4(out);
  }
}

/// An image a material samples, in the one layout a rasteriser wants.
///
/// **32-bit words and not bytes**, because the inner loop reads one texel per
/// pixel and four bounds-checked byte loads cost four times what one word load
/// costs. The conversion happens once, when the model is loaded.
///
/// Dimensions are kept as they came. Nothing here requires a power of two: the
/// sampler multiplies by `width - 1` rather than masking, which costs the same
/// and works for the 4096x4096 and 1024x683 textures that real models carry.
final class MeshTexture {
  MeshTexture({
    required this.width,
    required this.height,
    required this.pixels,
    this.name = '',
  }) : assert(pixels.length >= width * height);

  final int width;
  final int height;

  /// `0xAARRGGBB` per texel, row-major.
  final Uint32List pixels;

  final String name;

  /// The texel at ([u], [v]), wrapping.
  ///
  /// Nearest neighbour, and that is a choice rather than an omission: bilinear
  /// costs four loads and six multiplies per pixel in a rasteriser that is
  /// already the frame's whole budget, and on a model filling a window at
  /// roughly one texel per pixel it changes almost nothing. Magnified far past
  /// that it would, and [sampleBilinear] is there for a caller who wants to
  /// pay for it.
  ///
  /// Wrapping rather than clamping because that is what `REPEAT` means in
  /// glTF and OBJ alike, and it is the default in both. A model with UVs
  /// outside the unit square is normal - tiling a floor is exactly that - and
  /// clamping would smear the edge texel across it.
  int sample(double u, double v) {
    var x = (u * width).floor() % width;
    var y = (v * height).floor() % height;
    if (x < 0) x += width;
    if (y < 0) y += height;
    return pixels[y * width + x];
  }

  /// The texel at ([u], [v]), interpolated between its four neighbours.
  int sampleBilinear(double u, double v) {
    final double fx = u * width - 0.5;
    final double fy = v * height - 0.5;
    final int x0 = fx.floor();
    final int y0 = fy.floor();
    final double tx = fx - x0;
    final double ty = fy - y0;

    int at(int x, int y) {
      var cx = x % width;
      var cy = y % height;
      if (cx < 0) cx += width;
      if (cy < 0) cy += height;
      return pixels[cy * width + cx];
    }

    final int p00 = at(x0, y0);
    final int p10 = at(x0 + 1, y0);
    final int p01 = at(x0, y0 + 1);
    final int p11 = at(x0 + 1, y0 + 1);

    int channel(int shift) {
      final double top =
          ((p00 >> shift) & 0xFF) * (1 - tx) + ((p10 >> shift) & 0xFF) * tx;
      final double bottom =
          ((p01 >> shift) & 0xFF) * (1 - tx) + ((p11 >> shift) & 0xFF) * tx;
      return (top * (1 - ty) + bottom * ty).round().clamp(0, 255);
    }

    return 0xFF000000 | (channel(16) << 16) | (channel(8) << 8) | channel(0);
  }

  @override
  String toString() => 'MeshTexture($name, ${width}x$height)';
}

/// A material, reduced to what a software rasteriser can honour.
///
/// glTF describes physically based materials with metallic-roughness textures,
/// occlusion maps and emissive maps. This shades with a base colour, an
/// optional base-colour texture and two lights, and records the rest in
/// [Mesh3D.unsupported]. Silently keeping only the colour would make a
/// textured model look like a flat one with no explanation.
final class MeshMaterial {
  const MeshMaterial({
    this.name = '',
    this.colorArgb = 0xFFB4BCC8,
    this.metallic = 0,
    this.roughness = 0.8,
    this.doubleSided = false,
    this.baseColorTexture,
  });

  final String name;

  /// The base-colour map, or null for a flat material.
  ///
  /// Multiplied by [colorArgb] rather than replacing it, which is what glTF
  /// specifies and what makes a white-factor material sample the texture
  /// unchanged.
  final MeshTexture? baseColorTexture;

  /// Base colour, opaque grey by default: a model with no material at all is
  /// still a model, and a default of black would look like a loader failure.
  final int colorArgb;

  final double metallic;
  final double roughness;

  /// Whether back faces are drawn. Culling them is faster and correct for a
  /// closed mesh; an open one - a plane, a shell scanned from one side -
  /// disappears from behind without this.
  final bool doubleSided;
}

/// One drawable run of triangles sharing a material.
final class MeshPrimitive {
  const MeshPrimitive({
    required this.positions,
    required this.indices,
    this.normals,
    this.uvs,
    this.material = const MeshMaterial(),
    this.jointIndices,
    this.jointWeights,
    this.skin = -1,
  });

  /// `x, y, z` per vertex.
  final Float32List positions;

  /// Three indices into [positions] per triangle.
  final Uint32List indices;

  /// `x, y, z` per vertex, or null when the file carried none.
  ///
  /// Null rather than generated at load time, because generating them is a
  /// decision with a visible consequence - smooth versus flat shading - and it
  /// belongs to whoever is drawing, not to whoever is reading the file.
  final Float32List? normals;

  /// `u, v` per vertex, or null when the file carried none.
  ///
  /// Stored with **v as the file wrote it**, and the two formats disagree:
  /// glTF puts the origin at the top left, OBJ and FBX at the bottom left. The
  /// loaders flip so that everything here is glTF's convention, because
  /// flipping in the sampler instead would mean the rasteriser needing to know
  /// where each mesh came from.
  final Float32List? uvs;

  final MeshMaterial material;

  /// Four joint slots per vertex, indices into [MeshSkin.jointNodes], or null
  /// on a primitive that is not skinned.
  ///
  /// Four and not eight. Every real-time skinning implementation stops at four
  /// because the fifth weight on a Mixamo character is typically under 0.01,
  /// and the loader keeps the four largest rather than the first four it meets
  /// - taking the first four is what leaves a shoulder pinned to the spine.
  final Uint16List? jointIndices;

  /// The weight of each of the four slots in [jointIndices], renormalised so
  /// that the four sum to one.
  final Float32List? jointWeights;

  /// Which of [Mesh3D.skins] poses this primitive, or -1 when none does.
  final int skin;

  bool get isSkinned =>
      skin >= 0 && jointIndices != null && jointWeights != null;

  int get vertexCount => positions.length ~/ 3;

  int get triangleCount => indices.length ~/ 3;

  Bounds3 computeBounds() {
    var bounds = Bounds3.empty;
    for (var i = 0; i + 2 < positions.length; i += 3) {
      bounds = bounds.include(
        Vector3(positions[i], positions[i + 1], positions[i + 2]),
      );
    }
    return bounds;
  }

  /// Per-vertex normals averaged from the faces that share each vertex.
  ///
  /// The smooth-shading answer. A model whose vertices are not shared between
  /// faces - which is every STL, by construction - gets the same result as flat
  /// shading, because each vertex belongs to exactly one face. That is correct
  /// and is worth knowing before wondering why an STL never looks smooth.
  Float32List computeSmoothNormals() {
    final Float32List out = Float32List(positions.length);
    for (var t = 0; t + 2 < indices.length; t += 3) {
      final int ia = indices[t] * 3;
      final int ib = indices[t + 1] * 3;
      final int ic = indices[t + 2] * 3;
      final double ax = positions[ib] - positions[ia];
      final double ay = positions[ib + 1] - positions[ia + 1];
      final double az = positions[ib + 2] - positions[ia + 2];
      final double bx = positions[ic] - positions[ia];
      final double by = positions[ic + 1] - positions[ia + 1];
      final double bz = positions[ic + 2] - positions[ia + 2];
      // Not normalised before accumulating, on purpose: the cross product's
      // length is twice the triangle's area, so a big face contributes more
      // than a sliver. Normalising first weights a thousand tiny triangles the
      // same as the one large face they sit beside, and the shading beads.
      final double nx = ay * bz - az * by;
      final double ny = az * bx - ax * bz;
      final double nz = ax * by - ay * bx;
      for (final int base in <int>[ia, ib, ic]) {
        out[base] += nx;
        out[base + 1] += ny;
        out[base + 2] += nz;
      }
    }
    for (var i = 0; i + 2 < out.length; i += 3) {
      final double l = math.sqrt(
          out[i] * out[i] + out[i + 1] * out[i + 1] + out[i + 2] * out[i + 2]);
      if (l == 0) continue;
      out[i] /= l;
      out[i + 1] /= l;
      out[i + 2] /= l;
    }
    return out;
  }
}

/// A loaded model.
final class Mesh3D {
  Mesh3D({
    required this.name,
    required this.format,
    required List<MeshPrimitive> primitives,
    Set<String> unsupported = const <String>{},
    List<MeshNode> nodes = const <MeshNode>[],
    List<MeshSkin> skins = const <MeshSkin>[],
    List<MeshAnimation> animations = const <MeshAnimation>[],
  })  : primitives = List<MeshPrimitive>.unmodifiable(primitives),
        unsupported = Set<String>.unmodifiable(unsupported),
        nodes = List<MeshNode>.unmodifiable(nodes),
        skins = List<MeshSkin>.unmodifiable(skins),
        animations = List<MeshAnimation>.unmodifiable(animations);

  final String name;

  /// The format it came from, for a status line: `obj`, `stl`, `gltf`, `glb`.
  final String format;

  final List<MeshPrimitive> primitives;

  /// Features present in the file that this loader does not represent, each
  /// named once.
  ///
  /// The same contract as the Lottie decoder's, for the same reason: a model
  /// that arrives untextured because the format's textures are not implemented
  /// must not be indistinguishable from a model that has no textures. A viewer
  /// shows this list.
  final Set<String> unsupported;

  /// The transform hierarchy, empty for a format or a file that has none.
  ///
  /// Present only because skinning needs it: [primitives] already hold their
  /// vertices in the scene's space, so nothing here has to be walked to draw
  /// the model in its rest pose. It is the joints' *animated* transforms that
  /// cannot be baked, and a joint's transform is meaningless without its
  /// parents'.
  final List<MeshNode> nodes;

  final List<MeshSkin> skins;

  final List<MeshAnimation> animations;

  int get triangleCount {
    var total = 0;
    for (final MeshPrimitive primitive in primitives) {
      total += primitive.triangleCount;
    }
    return total;
  }

  int get vertexCount {
    var total = 0;
    for (final MeshPrimitive primitive in primitives) {
      total += primitive.vertexCount;
    }
    return total;
  }

  Bounds3 computeBounds() {
    var bounds = Bounds3.empty;
    for (final MeshPrimitive primitive in primitives) {
      bounds = bounds.union(primitive.computeBounds());
    }
    return bounds;
  }

  @override
  String toString() =>
      'Mesh3D($name, $format, ${primitives.length} primitives, '
      '$triangleCount triangles'
      '${unsupported.isEmpty ? '' : ', unsupported: ${unsupported.join(', ')}'})';
}

/// Raised when bytes are not the model format they claimed to be.
final class MeshParseException implements Exception {
  const MeshParseException(this.message, {this.detail});

  final String message;
  final String? detail;

  @override
  String toString() =>
      'MeshParseException: $message${detail == null ? '' : ' ($detail)'}';
}

// ---------------------------------------------------------------------------
// Skinning and animation
// ---------------------------------------------------------------------------

/// One transform in a model's hierarchy.
///
/// The rest pose is kept **decomposed as well as composed**, and that is not
/// redundancy. An animation channel replaces one of translation, rotation or
/// scale and leaves the other two alone, so evaluating a node whose file
/// animates only its rotation needs its rest translation and rest scale as
/// separate numbers. Recovering them from [restLocal] at every frame would be
/// a matrix decomposition per node per frame, and a decomposition cannot tell
/// a negative scale from a rotation, so a mirrored joint would flip.
final class MeshNode {
  const MeshNode({
    required this.name,
    required this.parent,
    required this.restLocal,
    required this.restTranslation,
    required this.restRotation,
    required this.restScale,
  });

  final String name;

  /// Index into [Mesh3D.nodes] of this node's parent, or -1 at a root.
  ///
  /// Every node's parent index is smaller than its own, so a single forward
  /// pass computes world transforms with no recursion and no visited set.
  /// The loaders guarantee that ordering; a cycle in the file is broken there
  /// rather than here.
  final int parent;

  /// The node's transform relative to its parent, in the rest pose.
  final Matrix4 restLocal;

  final Vector3 restTranslation;

  /// The rest rotation as a quaternion `(x, y, z, w)`.
  ///
  /// A quaternion rather than the Euler angles the file wrote, because two
  /// keyframes of Euler angles cannot be blended: 359 degrees to 1 degree
  /// interpolates the long way round through the whole circle.
  final Float32List restRotation;

  final Vector3 restScale;
}

/// The joints a skinned primitive is weighted to, and the bind pose that
/// relates them to its vertices.
final class MeshSkin {
  const MeshSkin({
    required this.name,
    required this.jointNodes,
    required this.inverseBind,
  });

  final String name;

  /// Index into [Mesh3D.nodes] for each joint slot.
  final Int32List jointNodes;

  /// Per joint slot, the matrix taking a vertex from the space the positions
  /// are stored in into that joint's local space.
  ///
  /// The inverse of the joint's world transform at the moment the weights were
  /// painted. Skinning is `jointWorld(t) * inverseBind * v` summed over the
  /// slots, and the two cancel exactly in the rest pose - which is the test
  /// worth running first, because a skin whose rest pose is not the identity
  /// has a bind matrix from the wrong space and will explode as soon as it
  /// is posed.
  final List<Matrix4> inverseBind;

  int get jointCount => jointNodes.length;
}

/// Which of a node's three components a channel drives.
enum MeshChannelPath { translation, rotation, scale }

/// One node's keyframes for one component.
final class MeshAnimationChannel {
  const MeshAnimationChannel({
    required this.node,
    required this.path,
    required this.times,
    required this.values,
  });

  /// Index into [Mesh3D.nodes].
  final int node;

  final MeshChannelPath path;

  /// Key times in seconds, ascending.
  final Float32List times;

  /// Three values per key for translation and scale, four - `x, y, z, w` - for
  /// rotation.
  final Float32List values;

  int get componentCount => path == MeshChannelPath.rotation ? 4 : 3;
}

/// A named set of channels: one FBX take, one glTF animation.
final class MeshAnimation {
  MeshAnimation({
    required this.name,
    required List<MeshAnimationChannel> channels,
    required this.duration,
  }) : channels = List<MeshAnimationChannel>.unmodifiable(channels);

  final String name;
  final List<MeshAnimationChannel> channels;

  /// Seconds from the first key to the last.
  final double duration;
}

/// The local transforms of every node at a time, and the matrices that pose a
/// skin from them.
///
/// Separate from [Mesh3D] because it is per-frame state: a viewer holds one of
/// these and refills it, rather than allocating a list of matrices sixty times
/// a second.
final class MeshPose {
  MeshPose(this.nodes)
      : _local = List<Matrix4>.filled(nodes.length, _identity),
        world = List<Matrix4>.filled(nodes.length, _identity);

  static final Matrix4 _identity = Matrix4.identity();

  final List<MeshNode> nodes;
  final List<Matrix4> _local;

  /// Each node's transform in the model's space, valid after [evaluate].
  final List<Matrix4> world;

  /// Fills [world] with the hierarchy posed by [animation] at [time] seconds.
  ///
  /// A node with no channel keeps its rest transform, which is why a file that
  /// animates six joints of a sixty-joint skeleton poses the other fifty-four
  /// correctly rather than collapsing them onto the origin.
  void evaluate(MeshAnimation? animation, double time) {
    for (var i = 0; i < nodes.length; i++) {
      _local[i] = nodes[i].restLocal;
    }
    if (animation != null) {
      // Gathered per node rather than applied channel by channel: translation,
      // rotation and scale compose into one matrix, so a node whose rotation
      // and scale are both animated must build its matrix once from both. A
      // channel that wrote its own matrix would be overwritten by the next.
      final Map<int, _NodeTrs> touched = <int, _NodeTrs>{};
      for (final MeshAnimationChannel channel in animation.channels) {
        if (channel.node < 0 || channel.node >= nodes.length) continue;
        final MeshNode node = nodes[channel.node];
        final _NodeTrs trs = touched.putIfAbsent(
          channel.node,
          () => _NodeTrs(
            node.restTranslation,
            node.restRotation,
            node.restScale,
          ),
        );
        trs.apply(channel, time);
      }
      touched.forEach((int index, _NodeTrs trs) {
        _local[index] = Matrix4.translation(trs.translation)
            .multiply(Matrix4.rotationFromQuaternion(
              trs.rotation[0],
              trs.rotation[1],
              trs.rotation[2],
              trs.rotation[3],
            ))
            .multiply(Matrix4.scale(trs.scale));
      });
    }
    for (var i = 0; i < nodes.length; i++) {
      final int parent = nodes[i].parent;
      world[i] = parent < 0 ? _local[i] : world[parent].multiply(_local[i]);
    }
  }

  /// `jointWorld * inverseBind` for every slot of [skin], which is what
  /// [skinPositions] multiplies vertices by.
  List<Matrix4> skinningMatrices(MeshSkin skin) {
    final List<Matrix4> out =
        List<Matrix4>.filled(skin.jointCount, _identity, growable: false);
    for (var i = 0; i < skin.jointCount; i++) {
      final int node = skin.jointNodes[i];
      if (node < 0 || node >= world.length) continue;
      out[i] = world[node].multiply(skin.inverseBind[i]);
    }
    return out;
  }
}

/// The translation, rotation and scale of one node while a frame is being
/// gathered.
final class _NodeTrs {
  _NodeTrs(this.translation, Float32List rotation, this.scale)
      : rotation = Float32List.fromList(rotation);

  Vector3 translation;
  Float32List rotation;
  Vector3 scale;

  void apply(MeshAnimationChannel channel, double time) {
    switch (channel.path) {
      case MeshChannelPath.translation:
        translation = _sampleVector(channel, time);
      case MeshChannelPath.scale:
        scale = _sampleVector(channel, time);
      case MeshChannelPath.rotation:
        rotation = _sampleQuaternion(channel, time);
    }
  }
}

/// The index of the key at or before [time], and how far past it [time] lies.
///
/// Binary search rather than a linear scan from zero: a Mixamo take has a key
/// every frame for a hundred joints, and a viewer that scans from the start of
/// every channel on every frame spends its time in this function.
(int, double) _keyframeAt(Float32List times, double time) {
  if (times.isEmpty) return (0, 0);
  if (time <= times[0]) return (0, 0);
  final int last = times.length - 1;
  if (time >= times[last]) return (last, 0);
  var low = 0;
  var high = last;
  while (low + 1 < high) {
    final int mid = (low + high) >> 1;
    if (times[mid] <= time) {
      low = mid;
    } else {
      high = mid;
    }
  }
  final double span = times[low + 1] - times[low];
  return (low, span <= 0 ? 0 : (time - times[low]) / span);
}

Vector3 _sampleVector(MeshAnimationChannel channel, double time) {
  final (int key, double t) = _keyframeAt(channel.times, time);
  final Float32List v = channel.values;
  final int a = key * 3;
  if (t == 0 || a + 5 >= v.length) {
    if (a + 2 >= v.length) return Vector3.zero;
    return Vector3(v[a], v[a + 1], v[a + 2]);
  }
  final int b = a + 3;
  return Vector3(
    v[a] + (v[b] - v[a]) * t,
    v[a + 1] + (v[b + 1] - v[a + 1]) * t,
    v[a + 2] + (v[b + 2] - v[a + 2]) * t,
  );
}

Float32List _sampleQuaternion(MeshAnimationChannel channel, double time) {
  final (int key, double t) = _keyframeAt(channel.times, time);
  final Float32List v = channel.values;
  final int a = key * 4;
  if (a + 3 >= v.length) return Float32List.fromList(<double>[0, 0, 0, 1]);
  if (t == 0 || a + 7 >= v.length) {
    return Float32List.fromList(<double>[v[a], v[a + 1], v[a + 2], v[a + 3]]);
  }
  final int b = a + 4;
  var bx = v[b], by = v[b + 1], bz = v[b + 2], bw = v[b + 3];
  final double ax = v[a], ay = v[a + 1], az = v[a + 2], aw = v[a + 3];
  var dot = ax * bx + ay * by + az * bz + aw * bw;
  // A quaternion and its negation are the same rotation, so the shorter of the
  // two arcs is the one to take. Without this an elbow that crosses the sign
  // boundary between two keys swings the long way round - 358 degrees in one
  // frame - which reads as the limb snapping through the body.
  if (dot < 0) {
    bx = -bx;
    by = -by;
    bz = -bz;
    bw = -bw;
    dot = -dot;
  }
  double wa;
  double wb;
  if (dot > 0.9995) {
    // Nearly parallel: slerp's sine denominator goes to zero and the result is
    // NaN. Linear blending is indistinguishable at this angle.
    wa = 1 - t;
    wb = t;
  } else {
    final double theta = math.acos(dot.clamp(-1.0, 1.0));
    final double sin = math.sin(theta);
    wa = math.sin((1 - t) * theta) / sin;
    wb = math.sin(t * theta) / sin;
  }
  final double x = ax * wa + bx * wb;
  final double y = ay * wa + by * wb;
  final double z = az * wa + bz * wb;
  final double w = aw * wa + bw * wb;
  final double length = math.sqrt(x * x + y * y + z * z + w * w);
  if (length == 0) return Float32List.fromList(<double>[0, 0, 0, 1]);
  return Float32List.fromList(
    <double>[x / length, y / length, z / length, w / length],
  );
}

/// [primitive]'s positions posed by [matrices], one per joint slot.
///
/// Linear blend skinning: the weighted sum of the vertex transformed by each
/// joint it belongs to. It collapses a joint bent past ninety degrees - the
/// candy-wrapper on a twisted forearm - and that is a known property of the
/// method rather than a bug here; dual quaternion skinning is what fixes it
/// and it is not implemented.
///
/// Returns [MeshPrimitive.positions] unchanged when the primitive carries no
/// weights, so a caller can pose a whole model without asking which halves of
/// it are skinned.
Float32List skinPositions(MeshPrimitive primitive, List<Matrix4> matrices) {
  final Uint16List? joints = primitive.jointIndices;
  final Float32List? weights = primitive.jointWeights;
  if (joints == null || weights == null) return primitive.positions;

  final Float32List source = primitive.positions;
  final Float32List out = Float32List(source.length);
  final int vertices = source.length ~/ 3;
  for (var v = 0; v < vertices; v++) {
    final int p = v * 3;
    final double x = source[p];
    final double y = source[p + 1];
    final double z = source[p + 2];
    var ox = 0.0;
    var oy = 0.0;
    var oz = 0.0;
    var total = 0.0;
    for (var slot = 0; slot < 4; slot++) {
      final int at = v * 4 + slot;
      if (at >= weights.length) break;
      final double weight = weights[at];
      if (weight == 0) continue;
      final int joint = joints[at];
      if (joint >= matrices.length) continue;
      final Float64List m = matrices[joint].storage;
      ox += weight * (m[0] * x + m[4] * y + m[8] * z + m[12]);
      oy += weight * (m[1] * x + m[5] * y + m[9] * z + m[13]);
      oz += weight * (m[2] * x + m[6] * y + m[10] * z + m[14]);
      total += weight;
    }
    // A vertex nothing is weighted to stays where it was rather than
    // collapsing to the origin. Exporters leave a few of these on every
    // character - a stray vertex on an eyelash - and one vertex at the origin
    // drags a triangle across the whole model.
    if (total == 0) {
      out[p] = x;
      out[p + 1] = y;
      out[p + 2] = z;
    } else {
      out[p] = ox;
      out[p + 1] = oy;
      out[p + 2] = oz;
    }
  }
  return out;
}
