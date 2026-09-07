/// Boxes, spheres and rings, built in code, because the cast has to be free.
///
/// ## Why the game is not made of loaded models
///
/// `MeshScene` draws exactly one [Mesh3D], and a [MeshPrimitive] holds its
/// vertices **already in scene space** — there is no per-draw transform and no
/// instance list anywhere in the render path. So a level with a character, four
/// enemies and eighteen rings in it is one mesh whose moving parts are rebuilt
/// every frame, and the cost of a frame is the cost of rebuilding them.
///
/// That single fact decided the whole art direction. The GPU pipelines cache
/// their vertex buffers keyed on [MeshPrimitive] *identity*
/// (`d3d11_mesh_pipeline.dart`), so a primitive rebuilt every frame is a
/// primitive re-uploaded every frame. A 25,000-vertex character is 600 KB of
/// bus traffic per frame at 60 Hz — 36 MB/s for one actor — and the D3D11
/// renderer's own comment names 200 MB/s as the traffic its cache exists to
/// stop. Loading Mixamo's 167,742-vertex skinned figure and posing it in Dart
/// would have been three times that again before a single triangle was drawn.
///
/// A cast built here is a few hundred vertices per actor — the whole visible
/// world came to 1,694 triangles, of which 890 are rebuilt each frame. It costs
/// nothing to upload, it cannot fail to load, and — the part that matters most
/// — it can be *posed*, which is what the motion state machine exists to ask
/// for. A rigid loaded model can be turned and translated but it cannot swing a
/// leg, and a game whose character never changes shape is a sprite on a
/// billboard. The README has the measurements and the assets that were weighed
/// and refused.
///
/// ## Winding
///
/// Counter-clockwise seen from outside is the front face, which is what both
/// the CPU rasteriser and the two GPU pipelines expect. Every face here is
/// wound by [addQuad] from a tangent pair chosen so that `t × b == n`, so the
/// winding is decided in one place instead of being re-derived per face — the
/// failure that convention prevents is a single box face culled away, which
/// reads as a hole in the character rather than as a winding bug.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_ui/src/graphics/mesh/mesh3d.dart';

/// A rotation about Z, which is the only rotation a side-scroller's actors
/// need: the game's plane is X across and Y up, so a limb swings about Z.
///
/// Built through [Matrix4.rotationFromQuaternion] rather than by writing the
/// nine entries out, because the quaternion form is already tested and a
/// hand-written rotation matrix with one sign wrong produces a limb that swings
/// the correct amount in the wrong direction — visible, but only just.
Matrix4 rotationZ(double radians) => Matrix4.rotationFromQuaternion(
      0,
      0,
      math.sin(radians / 2),
      math.cos(radians / 2),
    );

/// A rotation about Y: a ring spinning on the spot, a head turning.
Matrix4 rotationY(double radians) => Matrix4.rotationFromQuaternion(
      0,
      math.sin(radians / 2),
      0,
      math.cos(radians / 2),
    );

/// Accumulates triangles under a transform stack, then hands over a primitive.
///
/// One builder is one primitive is one material, so an actor in three colours
/// is three builders. That is not a limitation worth working around: a
/// primitive is the unit the GPU caches and the unit the rasteriser sorts, and
/// merging colours into one primitive would mean a vertex colour attribute,
/// which `MeshPrimitive` does not have.
final class MeshBuilder {
  MeshBuilder(this.material);

  final MeshMaterial material;

  final List<double> _positions = <double>[];
  final List<double> _normals = <double>[];
  final List<int> _indices = <int>[];

  /// The transform every vertex is baked through, innermost last.
  ///
  /// A stack and not a single matrix because a leg is a hip rotation inside a
  /// body translation inside a facing flip, and composing those at each call
  /// site is how one of them ends up applied twice.
  final List<Matrix4> _stack = <Matrix4>[Matrix4.identity()];

  bool get isEmpty => _indices.isEmpty;

  int get vertexCount => _positions.length ~/ 3;

  int get triangleCount => _indices.length ~/ 3;

  Matrix4 get _current => _stack.last;

  /// Pushes [transform], composed *inside* whatever is already on the stack.
  void push(Matrix4 transform) => _stack.add(_current.multiply(transform));

  void pop() {
    if (_stack.length <= 1) {
      throw StateError('popped the identity off the transform stack');
    }
    _stack.removeLast();
  }

  /// Runs [body] with [transform] pushed, and pops it however [body] leaves.
  void withTransform(Matrix4 transform, void Function() body) {
    push(transform);
    try {
      body();
    } finally {
      pop();
    }
  }

  /// Empties the builder so the next frame can be built into it.
  ///
  /// The stack is reset too, and not only the geometry: a frame abandoned
  /// between a [push] and its [pop] would otherwise leave a stale transform
  /// under everything the next frame draws, and the symptom — the whole cast
  /// offset by one actor's position — points at the posing code rather than at
  /// the frame that failed.
  void clear() {
    _positions.clear();
    _normals.clear();
    _indices.clear();
    _stack
      ..clear()
      ..add(Matrix4.identity());
  }

  /// Bakes one vertex through the current transform.
  ///
  /// The matrix is applied by hand over its column-major storage rather than
  /// through [Matrix4.transformPoint] and [Matrix4.transformDirection], and the
  /// reason is allocation and not arithmetic: those two return a `Vector3`
  /// each, `.normalized` returns a third, and this runs for every vertex of
  /// every actor of every frame. Building the cast through them measured 475 µs
  /// a frame for seven hundred vertices — a twentieth of a 100 Hz frame spent
  /// producing garbage for the collector. The maths below is the same maths.
  int addVertex(Vector3 position, Vector3 normal) {
    final int index = _positions.length ~/ 3;
    final Float64List m = _current.storage;
    final double px = position.x;
    final double py = position.y;
    final double pz = position.z;
    _positions
      ..add(m[0] * px + m[4] * py + m[8] * pz + m[12])
      ..add(m[1] * px + m[5] * py + m[9] * pz + m[13])
      ..add(m[2] * px + m[6] * py + m[10] * pz + m[14]);

    // The direction and not the point, so the translation is not applied to a
    // normal. Renormalised because a non-uniform scale — which is exactly what
    // squashing a stomped enemy is — leaves it short or long, and an
    // unnormalised normal shades as though the surface were darker.
    final double nx = m[0] * normal.x + m[4] * normal.y + m[8] * normal.z;
    final double ny = m[1] * normal.x + m[5] * normal.y + m[9] * normal.z;
    final double nz = m[2] * normal.x + m[6] * normal.y + m[10] * normal.z;
    final double length = math.sqrt(nx * nx + ny * ny + nz * nz);
    final double scale = length == 0 ? 0 : 1 / length;
    _normals
      ..add(nx * scale)
      ..add(ny * scale)
      ..add(nz * scale);
    return index;
  }

  void addTriangle(int a, int b, int c) {
    _indices
      ..add(a)
      ..add(b)
      ..add(c);
  }

  /// One quad from a corner and two edges, wound counter-clockwise as seen
  /// from `t × b`, which must be [n].
  void addQuad(Vector3 origin, Vector3 t, Vector3 b, Vector3 n) {
    final int v0 = addVertex(origin, n);
    final int v1 = addVertex(origin + t, n);
    final int v2 = addVertex(origin + t + b, n);
    final int v3 = addVertex(origin + b, n);
    addTriangle(v0, v1, v2);
    addTriangle(v0, v2, v3);
  }

  /// An axis-aligned box between two corners, in the current transform.
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

  /// A box from its centre and half extents, which is how a body is carried.
  void addBoxCentred(Vector3 centre, Vector3 half) => addBox(
        Vector3(centre.x - half.x, centre.y - half.y, centre.z - half.z),
        Vector3(centre.x + half.x, centre.y + half.y, centre.z + half.z),
      );

  /// A latitude-longitude sphere, wound counter-clockwise from outside.
  ///
  /// [stackFrom] and [stackTo] cut it into a dome or a bowl without a second
  /// primitive: an enemy's canopy is the top half of one of these, and
  /// generating the hidden half would double its triangles to draw nothing.
  void addSphere(
    Vector3 centre,
    double radius,
    int slices,
    int stacks, {
    int stackFrom = 0,
    int? stackTo,
  }) {
    final int last = stackTo ?? stacks;
    final int base = _positions.length ~/ 3;
    for (var i = stackFrom; i <= last; i++) {
      final double phi = math.pi * i / stacks;
      for (var j = 0; j <= slices; j++) {
        final double theta = 2 * math.pi * j / slices;
        final Vector3 unit = Vector3(
          math.sin(phi) * math.sin(theta),
          math.cos(phi),
          math.sin(phi) * math.cos(theta),
        );
        addVertex(centre + unit * radius, unit);
      }
    }
    for (var i = 0; i < last - stackFrom; i++) {
      for (var j = 0; j < slices; j++) {
        final int a = base + i * (slices + 1) + j;
        final int b = a + slices + 1;
        addTriangle(a, b, b + 1);
        addTriangle(a, b + 1, a + 1);
      }
    }
  }

  /// A torus in the XY plane — a ring, seen face-on by this game's camera.
  ///
  /// The axis is Z and not Y, because a ring standing up in the level is what
  /// the player runs into. It is spun about Y by the caller, which is what
  /// makes it flash edge-on once a revolution.
  void addRing(
    Vector3 centre,
    double majorRadius,
    double minorRadius,
    int majorSegments,
    int minorSegments,
  ) {
    final int base = _positions.length ~/ 3;
    for (var i = 0; i <= majorSegments; i++) {
      final double u = 2 * math.pi * i / majorSegments;
      final double cu = math.cos(u);
      final double su = math.sin(u);
      for (var j = 0; j <= minorSegments; j++) {
        final double v = 2 * math.pi * j / minorSegments;
        final double cv = math.cos(v);
        final double sv = math.sin(v);
        final Vector3 normal = Vector3(cu * cv, su * cv, sv);
        addVertex(
          Vector3(
            centre.x + cu * (majorRadius + minorRadius * cv),
            centre.y + su * (majorRadius + minorRadius * cv),
            centre.z + minorRadius * sv,
          ),
          normal,
        );
      }
    }
    final int stride = minorSegments + 1;
    for (var i = 0; i < majorSegments; i++) {
      for (var j = 0; j < minorSegments; j++) {
        final int a = base + i * stride + j;
        final int b = a + stride;
        addTriangle(a, b, b + 1);
        addTriangle(a, b + 1, a + 1);
      }
    }
  }

  /// A four-sided spike from a square base to a point: a hedgehog's quills, a
  /// spring's cone, the goal flag's finial.
  void addSpike(Vector3 base, Vector3 tip, double halfBase) {
    final Vector3 axis = tip - base;
    final double length = axis.length;
    if (length == 0) return;
    final Vector3 forward = axis * (1 / length);
    // Any vector not parallel to the axis works as the seed; Z is chosen
    // because no spike in this game points along it.
    final Vector3 seed =
        forward.z.abs() > 0.9 ? const Vector3(1, 0, 0) : const Vector3(0, 0, 1);
    final Vector3 right = seed.cross(forward).normalized;
    final Vector3 up = forward.cross(right);
    final List<Vector3> corners = <Vector3>[
      base + right * halfBase + up * halfBase,
      base - right * halfBase + up * halfBase,
      base - right * halfBase - up * halfBase,
      base + right * halfBase - up * halfBase,
    ];
    for (var i = 0; i < 4; i++) {
      final Vector3 a = corners[i];
      final Vector3 b = corners[(i + 1) % 4];
      final Vector3 normal = (b - a).cross(tip - a).normalized;
      final int ia = addVertex(a, normal);
      final int ib = addVertex(b, normal);
      final int it = addVertex(tip, normal);
      addTriangle(ia, ib, it);
    }
    final Vector3 down = forward * -1;
    final int c0 = addVertex(corners[0], down);
    final int c1 = addVertex(corners[1], down);
    final int c2 = addVertex(corners[2], down);
    final int c3 = addVertex(corners[3], down);
    addTriangle(c0, c2, c1);
    addTriangle(c0, c3, c2);
  }

  /// The primitive, or null when nothing was added.
  ///
  /// Null rather than an empty primitive: a zero-triangle primitive still
  /// occupies a cache slot in both GPU pipelines and still costs a buffer
  /// creation, and a scene that culls most of its actors would otherwise hand
  /// the renderer a dozen of them every frame.
  MeshPrimitive? build() {
    if (_indices.isEmpty) return null;
    return MeshPrimitive(
      positions: Float32List.fromList(_positions),
      normals: Float32List.fromList(_normals),
      indices: Uint32List.fromList(_indices),
      material: material,
    );
  }
}
