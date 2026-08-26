/// Opt-in retained OpenGL execution for CPU-tessellated path meshes.
///
/// This is deliberately separate from display-list replay. Callers resolve a
/// backend-neutral [TessellatedPathMesh] and explicitly submit it; the
/// executor retains one VBO/IBO pair per stable tessellation cache key.
library;

import '../../../geometry/rect.dart';
import '../../../geometry/transform2d.dart';
import '../../../graphics/display_list_opcodes.dart';
import '../gpu_pipeline.dart';
import '../vector/cpu_tessellation.dart';

/// Premultiplied solid paint for a retained tessellated mesh.
final class TessellatedGlMaterial {
  TessellatedGlMaterial({
    required this.red,
    required this.green,
    required this.blue,
    required this.alpha,
    this.blendMode = blendModeSrcOver,
  }) {
    for (final (String, double) channel in <(String, double)>[
      ('red', red),
      ('green', green),
      ('blue', blue),
      ('alpha', alpha),
    ]) {
      if (!channel.$2.isFinite || channel.$2 < 0 || channel.$2 > 1) {
        throw ArgumentError.value(channel.$2, channel.$1, 'must be 0..1');
      }
    }
    if (red > alpha || green > alpha || blue > alpha) {
      throw ArgumentError('colour channels must be premultiplied by alpha');
    }
    gpuBlendForMode(blendMode);
  }

  final double red;
  final double green;
  final double blue;
  final double alpha;
  final int blendMode;
}

/// Opaque driver-owned VBO/IBO pair.
final class TessellatedGlMeshHandle {
  const TessellatedGlMeshHandle({
    required this.vertexBuffer,
    required this.indexBuffer,
    required this.indexCount,
    this.retainedBytes = 0,
  });

  final int vertexBuffer;
  final int indexBuffer;
  final int indexCount;

  /// Vertex plus index bytes resident on the GPU for this mesh.
  ///
  /// Carried on the handle rather than recomputed from the source mesh so the
  /// inventory can price what it is holding without keeping the CPU mesh
  /// alive to ask.
  final int retainedBytes;
}

/// Fakeable GL operations required by approach B.
abstract interface class TessellatedGlDriver {
  void createResources({
    required String vertexSource,
    required String fragmentSource,
  });

  void deleteResources();

  TessellatedGlMeshHandle uploadMesh(TessellatedPathMesh mesh);

  void deleteMesh(TessellatedGlMeshHandle mesh);

  void beginTessellatedPass({
    required int viewportWidth,
    required int viewportHeight,
    required int yFlip,
  });

  void setBlendState(GpuBlendState blend);

  void setPremultipliedColor(
    double red,
    double green,
    double blue,
    double alpha,
  );

  void setLocalToTarget(Transform2D transform);

  /// Applies a target-space rectangular clip, or disables scissoring for null.
  void setClip(Rect? clip);

  void drawMesh(TessellatedGlMeshHandle mesh);

  void endTessellatedPass();

  /// Forgets names invalidated by context loss without deleting them.
  void discardNativeResources();
}

final class TessellatedGlExecutionStats {
  const TessellatedGlExecutionStats({
    required this.drawCalls,
    required this.triangles,
    required this.uploadedMeshes,
    required this.uploadedBytes,
    this.evictedMeshes = 0,
  });

  final int drawCalls;
  final int triangles;
  final int uploadedMeshes;
  final int uploadedBytes;

  /// Retained meshes released to stay inside the executor's budget.
  final int evictedMeshes;
}

/// Default GPU budget for retained meshes: 8 MiB.
///
/// Twice the CPU cache's, because a mesh only reaches the GPU once it has been
/// drawn at least once, and because a buffer that is evicted here has to be
/// re-uploaded rather than re-tessellated - the cheaper of the two costs.
const int kDefaultRetainedMeshBytes = 8 * 1024 * 1024;

/// Owns the optional program and retained VBO/IBO inventory.
///
/// ## The inventory is bounded, least-recently-used first
///
/// A retained mesh is a GPU allocation that nothing else will ever free: the
/// executor is the only object that holds the buffer names, and the cache key
/// is path content, so a subtree whose geometry changes every frame uploads a
/// new pair every frame and abandons the last. That is the failure this bound
/// exists for, and it is not hypothetical - it is the ordinary behaviour of
/// any path built from live data.
///
/// The budget is in bytes rather than entries because the entries differ by
/// three orders of magnitude: an icon is a few hundred bytes and a map outline
/// is megabytes, and a count that is generous for one is a leak for the other.
/// Eviction happens at [submit], which is the only moment a new mesh arrives
/// and the only moment the GL context is known to be current.
final class TessellatedGlExecutor {
  TessellatedGlExecutor(
    this._driver, {
    this.maxRetainedBytes = kDefaultRetainedMeshBytes,
  }) : assert(maxRetainedBytes > 0);

  final TessellatedGlDriver _driver;

  /// Vertex and index bytes this executor holds on the GPU before evicting.
  final int maxRetainedBytes;

  /// Key to buffers, in least-recently-used order.
  ///
  /// A `Map`'s insertion order is its iteration order in Dart, so a hit
  /// removes and re-inserts and the first key is always the coldest.
  final Map<TessellatedPathCacheKey, TessellatedGlMeshHandle> _meshes =
      <TessellatedPathCacheKey, TessellatedGlMeshHandle>{};
  int _retainedBytes = 0;
  int _evictionCount = 0;
  bool _initialized = false;
  bool _disposed = false;

  bool get isInitialized => _initialized;
  bool get isDisposed => _disposed;
  int get retainedMeshCount => _meshes.length;

  /// Vertex and index bytes currently resident on the GPU.
  int get retainedBytes => _retainedBytes;

  /// Meshes released to stay inside [maxRetainedBytes] since construction.
  int get evictionCount => _evictionCount;

  void initialize({required bool desktop}) {
    _throwIfDisposed();
    if (_initialized) return;
    _driver.createResources(
      vertexSource: _vertexShader(desktop: desktop),
      fragmentSource: _fragmentShader(desktop: desktop),
    );
    _initialized = true;
  }

  TessellatedGlExecutionStats submit(
    TessellatedPathMesh mesh, {
    required TessellatedGlMaterial material,
    required int viewportWidth,
    required int viewportHeight,
    int yFlip = 0,
    Transform2D localToTarget = Transform2D.identity,
    Rect? clip,
  }) {
    _throwIfDisposed();
    if (!_initialized) {
      throw StateError('initialize the tessellated GL executor before submit');
    }
    if (viewportWidth <= 0 || viewportHeight <= 0) {
      throw ArgumentError('viewport must be positive');
    }
    if (yFlip != 0 && yFlip != 1) {
      throw ArgumentError.value(yFlip, 'yFlip', 'must be 0 or 1');
    }
    _validateTransform(localToTarget);
    _validateClip(clip);
    if (mesh.vertices.length.isOdd || mesh.indices.length % 3 != 0) {
      throw ArgumentError('tessellated mesh storage is malformed');
    }
    if (mesh.indices.isEmpty) {
      return const TessellatedGlExecutionStats(
        drawCalls: 0,
        triangles: 0,
        uploadedMeshes: 0,
        uploadedBytes: 0,
      );
    }

    TessellatedGlMeshHandle? handle = _meshes.remove(mesh.cacheKey);
    var uploadedMeshes = 0;
    var uploadedBytes = 0;
    var evictedMeshes = 0;
    if (handle == null) {
      final int vertexCount = mesh.vertices.length ~/ 2;
      if (vertexCount == 0 ||
          mesh.vertices.any((double value) => !value.isFinite) ||
          mesh.indices.any((int index) => index >= vertexCount)) {
        throw ArgumentError('tessellated mesh contains invalid vertices');
      }
      uploadedBytes = mesh.vertices.lengthInBytes + mesh.indices.lengthInBytes;
      handle = _driver.uploadMesh(mesh);
      if (handle.vertexBuffer == 0 ||
          handle.indexBuffer == 0 ||
          handle.indexCount != mesh.indices.length) {
        _driver.deleteMesh(handle);
        throw StateError('the tessellated GL driver returned an invalid mesh');
      }
      // The driver may or may not have priced the upload; the bytes the mesh
      // actually carries are authoritative either way, and a handle reporting
      // zero would make the budget unenforceable.
      if (handle.retainedBytes != uploadedBytes) {
        handle = TessellatedGlMeshHandle(
          vertexBuffer: handle.vertexBuffer,
          indexBuffer: handle.indexBuffer,
          indexCount: handle.indexCount,
          retainedBytes: uploadedBytes,
        );
      }
      uploadedMeshes = 1;
      _retainedBytes += uploadedBytes;
    }
    // Re-inserted after the lookup so a hit counts as the most recent use.
    _meshes[mesh.cacheKey] = handle;
    evictedMeshes = _evictToBudget(keep: mesh.cacheKey);

    _driver.beginTessellatedPass(
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
      yFlip: yFlip,
    );
    try {
      _driver
        ..setBlendState(gpuBlendForMode(material.blendMode))
        ..setPremultipliedColor(
          material.red,
          material.green,
          material.blue,
          material.alpha,
        )
        ..setLocalToTarget(localToTarget)
        ..setClip(clip)
        ..drawMesh(handle);
    } finally {
      _driver.endTessellatedPass();
    }
    return TessellatedGlExecutionStats(
      drawCalls: 1,
      triangles: handle.indexCount ~/ 3,
      uploadedMeshes: uploadedMeshes,
      uploadedBytes: uploadedBytes,
      evictedMeshes: evictedMeshes,
    );
  }

  /// Deletes coldest-first until the budget holds, and returns how many went.
  ///
  /// [keep] is the mesh this submission is about to draw, and is never
  /// evicted: releasing the buffers a `drawMesh` is one line away from binding
  /// would be a use-after-free, and one frame over budget is not.
  int _evictToBudget({required TessellatedPathCacheKey keep}) {
    var evicted = 0;
    while (_retainedBytes > maxRetainedBytes && _meshes.length > 1) {
      final TessellatedPathCacheKey coldest = _meshes.keys.first;
      if (coldest == keep) break;
      final TessellatedGlMeshHandle stale = _meshes.remove(coldest)!;
      _retainedBytes -= stale.retainedBytes;
      _driver.deleteMesh(stale);
      _evictionCount++;
      evicted++;
    }
    return evicted;
  }

  /// Releases one retained GPU mesh while leaving the CPU cache untouched.
  bool releaseMesh(TessellatedPathCacheKey key) {
    _throwIfDisposed();
    final TessellatedGlMeshHandle? mesh = _meshes.remove(key);
    if (mesh == null) return false;
    _retainedBytes -= mesh.retainedBytes;
    _driver.deleteMesh(mesh);
    return true;
  }

  void clearRetainedMeshes() {
    _throwIfDisposed();
    for (final TessellatedGlMeshHandle mesh in _meshes.values) {
      _driver.deleteMesh(mesh);
    }
    _meshes.clear();
    _retainedBytes = 0;
  }

  void discardNativeResources() {
    _throwIfDisposed();
    if (_initialized) _driver.discardNativeResources();
    _meshes.clear();
    _retainedBytes = 0;
    _initialized = false;
  }

  void dispose() {
    if (_disposed) return;
    if (_initialized) {
      clearRetainedMeshes();
      _driver.deleteResources();
    }
    _initialized = false;
    _disposed = true;
  }

  void disposeAfterDeviceLoss() {
    if (_disposed) return;
    if (_initialized) _driver.discardNativeResources();
    _meshes.clear();
    _retainedBytes = 0;
    _initialized = false;
    _disposed = true;
  }

  static void _validateTransform(Transform2D transform) {
    if (<double>[
      transform.a,
      transform.b,
      transform.c,
      transform.d,
      transform.tx,
      transform.ty,
    ].any((double value) => !value.isFinite)) {
      throw ArgumentError.value(transform, 'localToTarget', 'must be finite');
    }
  }

  static void _validateClip(Rect? clip) {
    if (clip == null) return;
    if (<double>[clip.left, clip.top, clip.right, clip.bottom]
        .any((double value) => !value.isFinite)) {
      throw ArgumentError.value(clip, 'clip', 'must be finite');
    }
  }

  void _throwIfDisposed() {
    if (_disposed) throw StateError('the tessellated GL executor is disposed');
  }
}

String _vertexShader({required bool desktop}) => '''
${desktop ? '#version 330 core' : '#version 300 es\nprecision highp float;'}
layout(location = 0) in vec2 aPosition;
uniform vec2 uViewport;
uniform int uYFlip;
uniform vec4 uLocalToTarget0;
uniform vec4 uLocalToTarget1;
void main() {
  vec3 local = vec3(aPosition, 1.0);
  vec2 target = vec2(
    dot(uLocalToTarget0.xyz, local),
    dot(uLocalToTarget1.xyz, local));
  vec2 ndc = target / uViewport * 2.0 - 1.0;
  if (uYFlip == 0) ndc.y = -ndc.y;
  gl_Position = vec4(ndc, 0.0, 1.0);
}
''';

String _fragmentShader({required bool desktop}) => '''
${desktop ? '#version 330 core' : '#version 300 es\nprecision mediump float;'}
uniform vec4 uColor;
out vec4 fragColor;
void main() { fragColor = uColor; }
''';
