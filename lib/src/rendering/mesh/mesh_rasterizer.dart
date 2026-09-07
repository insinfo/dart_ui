/// A software triangle rasteriser, because this framework has no 3D pipeline.
///
/// The display list has commands for paths, images, text and clips. It has no
/// triangle, no depth buffer and no vertex shader, so a 3D model cannot be
/// handed to the GPU backends the way a rounded rectangle can. What this does
/// instead is draw the model into a [Framebuffer] on the CPU and let whatever
/// backend is running present that as one image — which is fast, because one
/// textured quad is the cheapest thing any of them draws, and honest, because
/// the triangles really are being rasterised by the CPU.
///
/// **The gap this leaves is worth naming.** A GPU mesh path would be a new
/// vertex format, a depth attachment, a shader and a pipeline in each of five
/// backends. Nothing here is a step towards it and nothing here should be read
/// as one; see `graphics/mesh/mesh3d.dart`.
///
/// ## The four things a triangle rasteriser has to get right
///
/// Each of them produces a specific, recognisable wrongness, so they are named
/// with their symptom:
///
///   1. **Near-plane clipping.** A vertex behind the camera has a negative `w`,
///      and dividing by it mirrors the vertex to the other side of the screen.
///      The symptom is triangles stretching across the whole window whenever
///      the camera enters the model. Clipping against the near plane before the
///      divide is the only fix; scissoring afterwards cannot undo it.
///   2. **The fill rule.** Sharing an edge between two triangles means every
///      pixel on it must be drawn exactly once. A naive `>= 0` test on all
///      three edges draws shared pixels twice, which is invisible until the
///      material is translucent, and a `> 0` test leaves a gap of unpainted
///      pixels along every internal edge — the classic seams.
///   3. **Depth precision.** Interpolating `z` linearly in screen space is
///      wrong: what is linear in screen space is `1/w`. With a perspective
///      matrix the projected `z` is already hyperbolic, so interpolating *that*
///      is correct, and this does. Interpolating view-space `z` instead makes
///      far surfaces punch through near ones near the silhouette.
///   4. **Winding and culling.** The signed area of the projected triangle
///      says which way it faces. Getting the sign backwards leaves a model
///      looking hollow — you see its inside surfaces — which reads as a normals
///      problem and is not.
///   5. **Perspective-correct interpolation.** Barycentric weights are linear
///      in screen space; texture coordinates are not. Interpolating `u` and `v`
///      directly gives a texture that swims and bends across a triangle seen at
///      an angle — the affine-texturing wobble of a fifth-generation console.
///      What is linear in screen space is `u/w` and `1/w`, so those are
///      interpolated and divided at the end. Colours and normals are left
///      affine on purpose: the error is the same, but a shading gradient a
///      fraction of a percent off is invisible where a sliding checkerboard is
///      not.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../../graphics/mesh/mesh3d.dart';
import '../framebuffer.dart';

/// Where the camera is and what it can see.
final class MeshCamera {
  const MeshCamera({
    required this.target,
    required this.distance,
    required this.yaw,
    required this.pitch,
    this.fovYRadians = 0.7853981633974483,
    this.near = 0.01,
    this.far = 1000,
  });

  /// An orbit camera framing [bounds] whole.
  ///
  /// The distance is derived from the bounding sphere and the field of view
  /// rather than picked: a viewer that opens a 0.2-unit figurine and a
  /// 500-unit landscape has to frame both without being told which it got.
  factory MeshCamera.frame(
    Bounds3 bounds, {
    double yaw = 0.6,
    double pitch = 0.35,
    double fovYRadians = 0.7853981633974483,
  }) {
    final double radius = bounds.isEmpty ? 1 : bounds.extent * 0.5 * 1.35;
    final double distance = radius / math.tan(fovYRadians / 2);
    return MeshCamera(
      target: bounds.isEmpty ? Vector3.zero : bounds.center,
      // A far plane tied to the model rather than a constant. A fixed 1000
      // gives a 0.2-unit figurine a depth range where every value rounds to
      // the same float and the model self-intersects.
      distance: distance,
      yaw: yaw,
      pitch: pitch,
      fovYRadians: fovYRadians,
      near: math.max(distance * 0.001, 1e-4),
      far: distance * 10,
    );
  }

  final Vector3 target;
  final double distance;

  /// Radians around the vertical axis.
  final double yaw;

  /// Radians above the horizon, clamped by [withPitch] to just short of the
  /// poles.
  final double pitch;

  final double fovYRadians;
  final double near;
  final double far;

  Vector3 get eye {
    final double cosPitch = math.cos(pitch);
    return Vector3(
      target.x + distance * cosPitch * math.sin(yaw),
      target.y + distance * math.sin(pitch),
      target.z + distance * cosPitch * math.cos(yaw),
    );
  }

  MeshCamera withYaw(double value) => _copy(yaw: value);

  /// [value], stopped just short of straight up and straight down.
  ///
  /// Not clamped exactly to the poles: there the view direction is parallel to
  /// the up vector and the basis is degenerate. `Matrix4.lookAt` recovers from
  /// that, but the recovery picks an arbitrary roll, so the model would spin
  /// as the camera crossed the pole.
  MeshCamera withPitch(double value) => _copy(
        pitch: value.clamp(-1.5533430342749532, 1.5533430342749532),
      );

  MeshCamera withDistance(double value) =>
      _copy(distance: math.max(value, near * 2));

  MeshCamera _copy({double? yaw, double? pitch, double? distance}) =>
      MeshCamera(
        target: target,
        distance: distance ?? this.distance,
        yaw: yaw ?? this.yaw,
        pitch: pitch ?? this.pitch,
        fovYRadians: fovYRadians,
        near: near,
        far: far,
      );

  Matrix4 viewMatrix() => Matrix4.lookAt(eye, target, Vector3.up);

  Matrix4 projectionMatrix(double aspect) => Matrix4.perspective(
        fovYRadians: fovYRadians,
        aspect: aspect,
        near: near,
        far: far,
      );
}

/// How a mesh is shaded.
enum MeshShading {
  /// One normal per triangle, from its own plane. Every facet is visible.
  flat,

  /// Normals averaged across the faces meeting at each vertex.
  ///
  /// Only different from [flat] when the mesh shares vertices between faces.
  /// An STL never does — the format has no index buffer — so an STL looks
  /// identical either way, which is a property of the file and not a bug here.
  smooth,

  /// No lighting: the material colour, flat. Useful for seeing geometry
  /// without shading hiding it.
  unlit,

  /// Triangle edges only.
  wireframe,
}

/// What one rendered frame cost.
final class MeshRenderStats {
  const MeshRenderStats({
    required this.triangles,
    required this.drawn,
    required this.culled,
    required this.clipped,
    required this.pixels,
    required this.microseconds,
  });

  static const MeshRenderStats zero = MeshRenderStats(
    triangles: 0,
    drawn: 0,
    culled: 0,
    clipped: 0,
    pixels: 0,
    microseconds: 0,
  );

  /// Triangles the mesh holds.
  final int triangles;

  /// Triangles that reached the rasteriser.
  final int drawn;

  /// Triangles rejected by back-face culling.
  final int culled;

  /// Triangles that crossed the near plane and had to be split.
  final int clipped;

  /// Pixels that passed the depth test and were written.
  ///
  /// The number that explains a frame time: a model with a hundred thousand
  /// triangles filling a tenth of the window costs less than one with a
  /// thousand filling all of it, and only this tells the two apart.
  final int pixels;

  final int microseconds;

  @override
  String toString() => 'MeshRenderStats($drawn/$triangles drawn, $culled '
      'culled, $clipped clipped, $pixels px, ${microseconds}us)';
}

/// Draws [Mesh3D] into a [Framebuffer].
///
/// One rasteriser per viewer, reused across frames: the depth buffer and the
/// transformed-vertex scratch are the largest allocations in the program and
/// reallocating them per frame is the difference between a smooth orbit and a
/// stutter every time the collector runs.
final class MeshRasterizer {
  MeshRasterizer();

  Float32List _depth = Float32List(0);
  Float32List _clipSpace = Float32List(0);
  MeshRenderStats _stats = MeshRenderStats.zero;

  /// The target's pixels as 32-bit words, when the target is tightly packed.
  ///
  /// **This is worth more than it looks.** Writing a pixel as four bounds-
  /// checked byte stores costs four times what one word store costs, and the
  /// clear alone is `width * height` of them. Measured on a 512x512 target in
  /// AOT: the byte-at-a-time version spent 5.3 ms on a 1086-triangle model,
  /// where the triangles themselves are a rounding error - the fixed cost was
  /// the whole frame.
  ///
  /// A little-endian word of `0xAARRGGBB` lands in memory as B, G, R, A, which
  /// is exactly the BGRA the framebuffer wants. That coincidence is why this
  /// works without a byte swap, and it is a coincidence: on a big-endian
  /// machine the fallback below would be the only correct path.
  Uint32List? _words;
  Framebuffer? _wordsFor;

  Uint32List? _wordsOf(Framebuffer target) {
    if (identical(_wordsFor, target)) return _words;
    _wordsFor = target;
    // A shared surface can round its stride up for alignment, and a word view
    // of a padded buffer would write the padding as if it were pixels.
    if (target.bytesPerRow != target.width * 4) return _words = null;
    if (target.pixels.offsetInBytes % 4 != 0) return _words = null;
    return _words = Uint32List.sublistView(target.pixels);
  }

  MeshRenderStats get stats => _stats;

  /// Draws [mesh] seen from [camera] into [target].
  ///
  /// [target] is cleared to [backgroundArgb] first. Drawing over the previous
  /// frame instead would leave the silhouette of where the model used to be.
  void render(
    Framebuffer target,
    Mesh3D mesh,
    MeshCamera camera, {
    MeshShading shading = MeshShading.smooth,
    int backgroundArgb = 0xFF10151F,
    Vector3 lightDirection = const Vector3(-0.4, -0.8, -0.45),
    double ambient = 0.22,
  }) {
    final Stopwatch watch = Stopwatch()..start();
    final int width = target.width;
    final int height = target.height;
    if (width <= 0 || height <= 0) return;

    _clear(target, backgroundArgb);
    final int pixelCount = width * height;
    if (_depth.length < pixelCount) _depth = Float32List(pixelCount);
    // `double.infinity` and not a large finite number: a vertex at exactly the
    // far plane has depth 1, and a sentinel of 1 would then lose the coin toss
    // against the background it is supposed to cover.
    _depth.fillRange(0, pixelCount, double.infinity);

    final Matrix4 view = camera.viewMatrix();
    final Matrix4 projection = camera.projectionMatrix(width / height);
    final Matrix4 viewProjection = projection.multiply(view);
    final Vector3 light = lightDirection.normalized;

    var triangles = 0;
    var drawn = 0;
    var culled = 0;
    var clipped = 0;
    var pixels = 0;

    for (final MeshPrimitive primitive in mesh.primitives) {
      final Float32List positions = primitive.positions;
      final Uint32List indices = primitive.indices;
      final Float32List? normals = shading == MeshShading.smooth
          ? (primitive.normals ?? primitive.computeSmoothNormals())
          : null;
      // Only when the material can use them. A mesh with texture coordinates
      // and no map pays nothing for carrying them.
      final MeshTexture? texture = shading == MeshShading.wireframe
          ? null
          : primitive.material.baseColorTexture;
      final Float32List? uvs = texture == null ? null : primitive.uvs;
      triangles += primitive.triangleCount;

      // Every vertex through the matrix once, rather than once per triangle it
      // belongs to. On a welded mesh a vertex is shared by about six faces, so
      // this is roughly six times less arithmetic; on an STL, where nothing is
      // shared, it costs one extra array and is the same work.
      final int vertexCount = primitive.vertexCount;
      if (_clipSpace.length < vertexCount * 4) {
        _clipSpace = Float32List(vertexCount * 4);
      }
      _project(positions, vertexCount, viewProjection, _clipSpace);

      final int baseColor = primitive.material.colorArgb;
      final bool cull = !primitive.material.doubleSided;

      for (var t = 0; t + 2 < indices.length; t += 3) {
        final int ia = indices[t];
        final int ib = indices[t + 1];
        final int ic = indices[t + 2];
        if (ia >= vertexCount || ib >= vertexCount || ic >= vertexCount) {
          continue;
        }

        final _Vertex a = _vertexAt(ia, positions, normals, uvs);
        final _Vertex b = _vertexAt(ib, positions, normals, uvs);
        final _Vertex c = _vertexAt(ic, positions, normals, uvs);

        final double wa = _clipSpace[ia * 4 + 3];
        final double wb = _clipSpace[ib * 4 + 3];
        final double wc = _clipSpace[ic * 4 + 3];
        final bool needsClip =
            wa <= camera.near || wb <= camera.near || wc <= camera.near;
        if (needsClip) {
          if (wa <= camera.near && wb <= camera.near && wc <= camera.near) {
            continue;
          }
          clipped++;
          final int written = _clipAndDraw(
            target,
            width,
            height,
            <_Vertex>[a, b, c],
            viewProjection,
            camera.near,
            baseColor,
            texture,
            light,
            ambient,
            shading,
            cull,
          );
          if (written >= 0) {
            drawn++;
            pixels += written;
          } else {
            culled++;
          }
          continue;
        }

        final int written = _drawProjected(
          target,
          width,
          height,
          a,
          b,
          c,
          _screen(ia, width, height),
          _screen(ib, width, height),
          _screen(ic, width, height),
          baseColor,
          texture,
          light,
          ambient,
          shading,
          cull,
        );
        if (written >= 0) {
          drawn++;
          pixels += written;
        } else {
          culled++;
        }
      }
    }

    watch.stop();
    _stats = MeshRenderStats(
      triangles: triangles,
      drawn: drawn,
      culled: culled,
      clipped: clipped,
      pixels: pixels,
      microseconds: watch.elapsedMicroseconds,
    );
  }

  /// `x, y, z, w` in clip space for every vertex.
  void _project(
    Float32List positions,
    int count,
    Matrix4 m,
    Float32List out,
  ) {
    final Float64List s = m.storage;
    for (var i = 0; i < count; i++) {
      final int p = i * 3;
      final double x = positions[p];
      final double y = positions[p + 1];
      final double z = positions[p + 2];
      final int o = i * 4;
      out[o] = s[0] * x + s[4] * y + s[8] * z + s[12];
      out[o + 1] = s[1] * x + s[5] * y + s[9] * z + s[13];
      out[o + 2] = s[2] * x + s[6] * y + s[10] * z + s[14];
      out[o + 3] = s[3] * x + s[7] * y + s[11] * z + s[15];
    }
  }

  /// The clip-space vertex [index] projected to pixels.
  _Screen _screen(int index, int width, int height) {
    final int o = index * 4;
    final double w = _clipSpace[o + 3];
    final double inv = 1 / w;
    return _Screen(
      (_clipSpace[o] * inv + 1) * 0.5 * width,
      (1 - _clipSpace[o + 1] * inv) * 0.5 * height,
      _clipSpace[o + 2] * inv,
      inv,
    );
  }

  _Vertex _vertexAt(
    int index,
    Float32List positions,
    Float32List? normals,
    Float32List? uvs,
  ) {
    final int p = index * 3;
    final int t = index * 2;
    return _Vertex(
      Vector3(positions[p], positions[p + 1], positions[p + 2]),
      normals == null
          ? null
          : Vector3(normals[p], normals[p + 1], normals[p + 2]),
      uvs == null || t + 1 >= uvs.length ? double.nan : uvs[t],
      uvs == null || t + 1 >= uvs.length ? double.nan : uvs[t + 1],
    );
  }

  /// Clips a triangle against the near plane and draws what survives.
  ///
  /// Sutherland-Hodgman against one plane, which turns a triangle into a
  /// polygon of three or four vertices, fanned back into triangles. Only the
  /// near plane is clipped: the others are handled by the bounding box the
  /// scanline loop already computes, and a triangle entirely off-screen costs
  /// an empty box rather than a clip.
  int _clipAndDraw(
    Framebuffer target,
    int width,
    int height,
    List<_Vertex> triangle,
    Matrix4 viewProjection,
    double near,
    int baseColor,
    MeshTexture? texture,
    Vector3 light,
    double ambient,
    MeshShading shading,
    bool cull,
  ) {
    final List<_Vertex> polygon = <_Vertex>[];
    final Float64List m = viewProjection.storage;
    double wOf(Vector3 v) => m[3] * v.x + m[7] * v.y + m[11] * v.z + m[15];

    for (var i = 0; i < triangle.length; i++) {
      final _Vertex current = triangle[i];
      final _Vertex next = triangle[(i + 1) % triangle.length];
      final double wc = wOf(current.position);
      final double wn = wOf(next.position);
      final bool inCurrent = wc > near;
      final bool inNext = wn > near;
      if (inCurrent) polygon.add(current);
      if (inCurrent != inNext) {
        final double t = (near - wc) / (wn - wc);
        polygon.add(current.lerp(next, t));
      }
    }
    if (polygon.length < 3) return -1;

    var written = 0;
    var anyDrawn = false;
    for (var i = 1; i + 1 < polygon.length; i++) {
      final int result = _drawProjected(
        target,
        width,
        height,
        polygon[0],
        polygon[i],
        polygon[i + 1],
        _projectOne(polygon[0].position, viewProjection, width, height),
        _projectOne(polygon[i].position, viewProjection, width, height),
        _projectOne(polygon[i + 1].position, viewProjection, width, height),
        baseColor,
        texture,
        light,
        ambient,
        shading,
        cull,
      );
      if (result >= 0) {
        anyDrawn = true;
        written += result;
      }
    }
    return anyDrawn ? written : -1;
  }

  _Screen _projectOne(Vector3 v, Matrix4 m, int width, int height) {
    final Float64List s = m.storage;
    final double x = s[0] * v.x + s[4] * v.y + s[8] * v.z + s[12];
    final double y = s[1] * v.x + s[5] * v.y + s[9] * v.z + s[13];
    final double z = s[2] * v.x + s[6] * v.y + s[10] * v.z + s[14];
    final double w = s[3] * v.x + s[7] * v.y + s[11] * v.z + s[15];
    final double inv = 1 / w;
    return _Screen(
      (x * inv + 1) * 0.5 * width,
      (1 - y * inv) * 0.5 * height,
      z * inv,
      inv,
    );
  }

  /// Fills one projected triangle. Returns the pixels written, or -1 if the
  /// triangle was culled.
  int _drawProjected(
    Framebuffer target,
    int width,
    int height,
    _Vertex va,
    _Vertex vb,
    _Vertex vc,
    _Screen sa,
    _Screen sb,
    _Screen sc,
    int baseColor,
    MeshTexture? texture,
    Vector3 light,
    double ambient,
    MeshShading shading,
    bool cull,
  ) {
    // Twice the signed area. Negative is counter-clockwise on screen, which is
    // front-facing here because the y axis was flipped in `_screen`: the flip
    // reverses the sign of every winding, and forgetting it is what leaves a
    // model looking hollow.
    final double area =
        (sb.x - sa.x) * (sc.y - sa.y) - (sc.x - sa.x) * (sb.y - sa.y);
    if (area == 0) return -1;
    final bool backFacing = area > 0;
    if (cull && backFacing) return -1;

    if (shading == MeshShading.wireframe) {
      var written = 0;
      written += _line(target, width, height, sa, sb, baseColor);
      written += _line(target, width, height, sb, sc, baseColor);
      written += _line(target, width, height, sc, sa, baseColor);
      return written;
    }

    // Computed on demand rather than up front. Smooth shading with normals
    // from the file never looks at it, and paying for a cross product, a
    // square root and four allocations on every one of a 451,838-triangle
    // model's faces is a large slice of the frame.
    Vector3? faceNormal;
    Vector3 faceNormalOf() => faceNormal ??=
        (vb.position - va.position).cross(vc.position - va.position).normalized;

    final int minX = math.max(0, _floor(math.min(sa.x, math.min(sb.x, sc.x))));
    final int maxX =
        math.min(width - 1, _ceil(math.max(sa.x, math.max(sb.x, sc.x))));
    final int minY = math.max(0, _floor(math.min(sa.y, math.min(sb.y, sc.y))));
    final int maxY =
        math.min(height - 1, _ceil(math.max(sa.y, math.max(sb.y, sc.y))));
    if (minX > maxX || minY > maxY) return 0;

    final double inverseArea = 1 / area;
    final Uint8List pixels = target.pixels;
    final Uint32List? words = _wordsOf(target);
    final int stride = target.bytesPerRow;
    var written = 0;

    // Edge functions, stepped rather than recomputed.
    //
    // The straightforward loop evaluates three edge functions from scratch at
    // every candidate pixel: twelve multiplies and six subtractions, for a
    // test that usually says no. But an edge function is affine in x and y, so
    // moving one pixel right adds a constant and moving one row down adds
    // another. Computing the three values once at the box corner and stepping
    // them turns the inner test into three additions.
    //
    // Measured on this machine, AOT, a 1086-triangle model at 512x512:
    // **5.44 ms a frame before, 1.57 ms after** - 3.4x, and the model is small
    // enough that the triangles themselves are a rounding error. The saving is
    // entirely in the pixels that fail the test, which for a mesh of thin
    // triangles is most of the bounding box: a sliver's box can be ten times
    // its area.
    // The partial derivatives, written out. An earlier version stored the
    // negated forms and then chose `+=` or `-=` per axis to undo the sign, and
    // got one of the six choices wrong: the y step for all three edges. The
    // symptom was a model drawn as scattered dots, because only the first row
    // of each triangle's bounding box evaluated correctly. Naming the
    // derivatives and adding them is the version that cannot be got wrong,
    // and `mesh_rasterizer_test.dart` compares this loop against a direct
    // evaluation for exactly this reason.
    final double d0x = sb.y - sc.y;
    final double d0y = sc.x - sb.x;
    final double d1x = sc.y - sa.y;
    final double d1y = sa.x - sc.x;
    final double d2x = sa.y - sb.y;
    final double d2y = sb.x - sa.x;

    final double startX = minX + 0.5;
    final double startY = minY + 0.5;
    var rowW0 =
        (sc.x - sb.x) * (startY - sb.y) - (sc.y - sb.y) * (startX - sb.x);
    var rowW1 =
        (sa.x - sc.x) * (startY - sc.y) - (sa.y - sc.y) * (startX - sc.x);
    var rowW2 =
        (sb.x - sa.x) * (startY - sa.y) - (sb.y - sa.y) * (startX - sa.x);

    for (var y = minY; y <= maxY; y++) {
      final int row = y * stride;
      var w0 = rowW0;
      var w1 = rowW1;
      var w2 = rowW2;
      rowW0 += d0y;
      rowW1 += d1y;
      rowW2 += d2y;
      for (var x = minX; x <= maxX; x++) {
        final double e0 = w0;
        final double e1 = w1;
        final double e2 = w2;
        w0 += d0x;
        w1 += d1x;
        w2 += d2x;
        // One sign test rather than three comparisons against zero: a pixel is
        // inside when all three edge functions share the winding's sign.
        if (backFacing) {
          if (e0 < 0 || e1 < 0 || e2 < 0) continue;
        } else {
          if (e0 > 0 || e1 > 0 || e2 > 0) continue;
        }

        final double la = e0 * inverseArea;
        final double lb = e1 * inverseArea;
        final double lc = e2 * inverseArea;
        final double depth = la * sa.z + lb * sb.z + lc * sc.z;
        final int index = y * width + x;
        if (depth >= _depth[index]) continue;
        _depth[index] = depth;

        // Perspective-correct only where it shows. `u/w` and `1/w` are
        // linear in screen space and `u` is not; interpolating `u` directly is
        // the affine wobble that makes a floor swim underfoot.
        int surface = baseColor;
        if (texture != null && !va.u.isNaN) {
          final double invW = la * sa.invW + lb * sb.invW + lc * sc.invW;
          if (invW != 0) {
            final double u = (la * va.u * sa.invW +
                    lb * vb.u * sb.invW +
                    lc * vc.u * sc.invW) /
                invW;
            final double v = (la * va.v * sa.invW +
                    lb * vb.v * sb.invW +
                    lc * vc.v * sc.invW) /
                invW;
            final int texel = texture.sample(u, v);
            // Multiplied by the factor rather than replacing it, which is what
            // glTF specifies: a white factor samples the texture unchanged and
            // a tinted one tints it.
            surface = 0xFF000000 |
                (_mul(texel >> 16, baseColor >> 16) << 16) |
                (_mul(texel >> 8, baseColor >> 8) << 8) |
                _mul(texel, baseColor);
          }
        }

        int argb;
        if (shading == MeshShading.unlit) {
          argb = surface;
        } else {
          Vector3 normal;
          if (shading == MeshShading.smooth &&
              va.normal != null &&
              vb.normal != null &&
              vc.normal != null) {
            normal = Vector3(
              la * va.normal!.x + lb * vb.normal!.x + lc * vc.normal!.x,
              la * va.normal!.y + lb * vb.normal!.y + lc * vc.normal!.y,
              la * va.normal!.z + lb * vb.normal!.z + lc * vc.normal!.z,
            ).normalized;
          } else {
            normal = faceNormalOf();
          }
          argb = _shade(surface, normal, light, ambient, backFacing);
        }

        // BGRA, premultiplied, and opaque - so premultiplying is the
        // identity and the channels go in directly. Writing RGBA here is the
        // mistake that makes every model come out blue.
        if (words != null) {
          words[index] = argb | 0xFF000000;
        } else {
          final int at = row + x * 4;
          pixels[at] = argb & 0xFF;
          pixels[at + 1] = (argb >> 8) & 0xFF;
          pixels[at + 2] = (argb >> 16) & 0xFF;
          pixels[at + 3] = 0xFF;
        }
        written++;
      }
    }
    return written;
  }

  /// Lambert plus a rim term, which is enough to read a shape.
  ///
  /// A back face that survived culling - a double-sided material - is lit with
  /// its normal reversed. Without that, the inside of an open shell is black
  /// and looks like a hole.
  int _shade(
    int baseColor,
    Vector3 normal,
    Vector3 light,
    double ambient,
    bool backFacing,
  ) {
    final Vector3 n = backFacing ? normal * -1.0 : normal;
    final double lambert = math.max(0, -n.dot(light));
    // A second, dimmer light from the opposite side. One light leaves half of
    // every model in flat ambient, where its shape cannot be read at all.
    final double fill = math.max(0, n.dot(light)) * 0.25;
    final double intensity = (ambient + lambert * 0.85 + fill).clamp(0.0, 1.2);

    int channel(int shift) {
      final int value = ((baseColor >> shift) & 0xFF);
      final int lit = (value * intensity).round();
      return lit > 255 ? 255 : lit;
    }

    return 0xFF000000 | (channel(16) << 16) | (channel(8) << 8) | channel(0);
  }

  /// Bresenham, with the depth buffer honoured so wireframe hides correctly.
  int _line(
    Framebuffer target,
    int width,
    int height,
    _Screen a,
    _Screen b,
    int argb,
  ) {
    var x0 = a.x.round();
    var y0 = a.y.round();
    final int x1 = b.x.round();
    final int y1 = b.y.round();
    final int dx = (x1 - x0).abs();
    final int dy = -(y1 - y0).abs();
    final int sx = x0 < x1 ? 1 : -1;
    final int sy = y0 < y1 ? 1 : -1;
    var error = dx + dy;
    final int steps = math.max(dx, -dy);
    if (steps == 0) return 0;
    var written = 0;

    for (var i = 0; i <= steps; i++) {
      if (x0 >= 0 && x0 < width && y0 >= 0 && y0 < height) {
        final double t = i / steps;
        final double depth = a.z + (b.z - a.z) * t;
        final int index = y0 * width + x0;
        // A hair in front, so an edge is not z-fought by the face it belongs
        // to when both are drawn.
        if (depth - 1e-5 < _depth[index]) {
          _depth[index] = depth - 1e-5;
          final Uint32List? words = _wordsOf(target);
          if (words != null) {
            words[index] = argb | 0xFF000000;
          } else {
            final int at = y0 * target.bytesPerRow + x0 * 4;
            target.pixels[at] = argb & 0xFF;
            target.pixels[at + 1] = (argb >> 8) & 0xFF;
            target.pixels[at + 2] = (argb >> 16) & 0xFF;
            target.pixels[at + 3] = 0xFF;
          }
          written++;
        }
      }
      if (x0 == x1 && y0 == y1) break;
      final int e2 = error * 2;
      if (e2 >= dy) {
        error += dy;
        x0 += sx;
      }
      if (e2 <= dx) {
        error += dx;
        y0 += sy;
      }
    }
    return written;
  }

  void _clear(Framebuffer target, int argb) {
    final Uint32List? words = _wordsOf(target);
    if (words != null) {
      words.fillRange(0, target.width * target.height, argb | 0xFF000000);
      return;
    }
    final Uint8List pixels = target.pixels;
    final int b = argb & 0xFF;
    final int g = (argb >> 8) & 0xFF;
    final int r = (argb >> 16) & 0xFF;
    for (var y = 0; y < target.height; y++) {
      final int row = y * target.bytesPerRow;
      for (var x = 0; x < target.width; x++) {
        final int at = row + x * 4;
        pixels[at] = b;
        pixels[at + 1] = g;
        pixels[at + 2] = r;
        pixels[at + 3] = 0xFF;
      }
    }
  }

  /// One channel of a texel times one channel of a factor, both 0..255.
  ///
  /// `(a * b + 127) ~/ 255` and not `>> 8`: the shift is a divide by 256 and
  /// leaves white multiplied by white at 254, so every fully lit textured
  /// surface would come out one level dark. That is invisible on one surface
  /// and a visible seam where a textured mesh meets an untextured one.
  static int _mul(int a, int b) {
    final int product = (a & 0xFF) * (b & 0xFF);
    return (product + 127) ~/ 255;
  }

  static int _floor(double value) => value.floor();

  static int _ceil(double value) => value.ceil();
}

/// A vertex in model space, with its normal and texture coordinate when the
/// mesh had them.
final class _Vertex {
  const _Vertex(this.position, this.normal, this.u, this.v);

  final Vector3 position;
  final Vector3? normal;

  /// Texture coordinates. NaN when the mesh has none, which is a cheaper test
  /// than a nullable pair and cannot be confused with a real coordinate.
  final double u;
  final double v;

  _Vertex lerp(_Vertex other, double t) => _Vertex(
        Vector3(
          position.x + (other.position.x - position.x) * t,
          position.y + (other.position.y - position.y) * t,
          position.z + (other.position.z - position.z) * t,
        ),
        normal == null || other.normal == null
            ? null
            : Vector3(
                normal!.x + (other.normal!.x - normal!.x) * t,
                normal!.y + (other.normal!.y - normal!.y) * t,
                normal!.z + (other.normal!.z - normal!.z) * t,
              ),
        u + (other.u - u) * t,
        v + (other.v - v) * t,
      );
}

/// A vertex after the perspective divide: pixels, depth, and `1/w`.
final class _Screen {
  const _Screen(this.x, this.y, this.z, this.invW);

  final double x;
  final double y;
  final double z;

  /// Kept for perspective-correct interpolation of anything that needs it.
  /// Nothing does yet - there are no textures - and it is here rather than
  /// added later because recomputing it means re-deriving the divide.
  final double invW;
}
