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
  });

  final int vertexBuffer;
  final int indexBuffer;
  final int indexCount;
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
  });

  final int drawCalls;
  final int triangles;
  final int uploadedMeshes;
  final int uploadedBytes;
}

/// Owns the optional program and retained VBO/IBO inventory.
final class TessellatedGlExecutor {
  TessellatedGlExecutor(this._driver);

  final TessellatedGlDriver _driver;
  final Map<TessellatedPathCacheKey, TessellatedGlMeshHandle> _meshes =
      <TessellatedPathCacheKey, TessellatedGlMeshHandle>{};
  bool _initialized = false;
  bool _disposed = false;

  bool get isInitialized => _initialized;
  bool get isDisposed => _disposed;
  int get retainedMeshCount => _meshes.length;

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

    TessellatedGlMeshHandle? handle = _meshes[mesh.cacheKey];
    var uploadedMeshes = 0;
    var uploadedBytes = 0;
    if (handle == null) {
      final int vertexCount = mesh.vertices.length ~/ 2;
      if (vertexCount == 0 ||
          mesh.vertices.any((double value) => !value.isFinite) ||
          mesh.indices.any((int index) => index >= vertexCount)) {
        throw ArgumentError('tessellated mesh contains invalid vertices');
      }
      handle = _driver.uploadMesh(mesh);
      if (handle.vertexBuffer == 0 ||
          handle.indexBuffer == 0 ||
          handle.indexCount != mesh.indices.length) {
        _driver.deleteMesh(handle);
        throw StateError('the tessellated GL driver returned an invalid mesh');
      }
      _meshes[mesh.cacheKey] = handle;
      uploadedMeshes = 1;
      uploadedBytes = mesh.vertices.lengthInBytes + mesh.indices.lengthInBytes;
    }

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
    );
  }

  /// Releases one retained GPU mesh while leaving the CPU cache untouched.
  bool releaseMesh(TessellatedPathCacheKey key) {
    _throwIfDisposed();
    final TessellatedGlMeshHandle? mesh = _meshes.remove(key);
    if (mesh == null) return false;
    _driver.deleteMesh(mesh);
    return true;
  }

  void clearRetainedMeshes() {
    _throwIfDisposed();
    for (final TessellatedGlMeshHandle mesh in _meshes.values) {
      _driver.deleteMesh(mesh);
    }
    _meshes.clear();
  }

  void discardNativeResources() {
    _throwIfDisposed();
    if (_initialized) _driver.discardNativeResources();
    _meshes.clear();
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
