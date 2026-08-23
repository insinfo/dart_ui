/// Experimental OpenGL lifecycle and executor for sparse-strip submissions.
///
/// It is intentionally not wired into [GlRenderDevice] yet. The executor is
/// complete enough to own a program, instance VBO and alpha8 texture pages,
/// but is reached only by an explicit caller. That keeps the established
/// dense-mask renderer unchanged while the sparse path gains fake-driver and
/// live-driver coverage.
library;

import 'dart:typed_data';

import '../gpu_pipeline.dart';
import '../vector/sparse_strip_draw_plan.dart';
import 'gl_sparse_strips.dart';

/// Premultiplied material consumed by one sparse batch.
final class SparseGlMaterial {
  SparseGlMaterial({
    required this.red,
    required this.green,
    required this.blue,
    required this.alpha,
    required this.blendMode,
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

/// Narrow, fakeable surface over the GL calls the experimental executor uses.
///
/// A production adapter maps these one-for-one to [GlApi]. Typed data remains
/// here so staging allocation policy belongs to that adapter, not to the
/// backend-neutral [SparseStripDrawPlan].
abstract interface class SparseGlDriver {
  int createSparseProgram({
    required String vertexSource,
    required String fragmentSource,
  });

  void deleteProgram(int program);
  int createInstanceBuffer();
  void deleteBuffer(int buffer);

  int createAlpha8Texture({required int width, required int height});
  void deleteTexture(int texture);

  void uploadInstances(int buffer, Float32List instances);

  void uploadAlpha8Region(
    int texture, {
    required int x,
    required int y,
    required int width,
    required int height,
    required Uint8List pixels,
    required int sourceOffset,
    required int sourceBytesPerRow,
  });

  void beginSparsePass({
    required int program,
    required int instanceBuffer,
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

  void setSparseMode(int mode);
  void bindAlpha8Texture(int texture);

  void setInstanceAttribute({
    required int location,
    required int components,
    required int strideBytes,
    required int offsetBytes,
    required int divisor,
  });

  void drawTriangleStripInstanced({
    required int vertexCount,
    required int instanceCount,
  });

  void endSparsePass();
}

/// Counts work actually sent to [SparseGlDriver].
final class SparseGlExecutionStats {
  const SparseGlExecutionStats({
    required this.drawCalls,
    required this.instances,
    required this.alphaUploads,
    required this.alphaUploadBytes,
  });

  final int drawCalls;
  final int instances;
  final int alphaUploads;
  final int alphaUploadBytes;
}

/// Owns and executes the experimental sparse GL pipeline.
final class SparseGlExecutor {
  SparseGlExecutor(this._driver, {SparseGlSubmission? submission})
      : submission = submission ?? SparseGlSubmission();

  final SparseGlDriver _driver;
  final SparseGlSubmission submission;
  final List<int> _alphaTextures = <int>[];

  int _program = 0;
  int _instanceBuffer = 0;
  int _atlasWidth = 0;
  int _atlasHeight = 0;
  bool _disposed = false;

  bool get isInitialized => _program != 0;
  bool get isDisposed => _disposed;
  int get retainedAlphaPageCount => _alphaTextures.length;

  /// Compiles the dialect selected by the context and allocates the VBO.
  void initialize({required bool desktop}) {
    _throwIfDisposed();
    if (isInitialized) return;
    validateSparseGlShaderContract();
    _program = _driver.createSparseProgram(
      vertexSource: sparseGlVertexShaderSource(desktop: desktop),
      fragmentSource: sparseGlFragmentShaderSource(desktop: desktop),
    );
    if (_program == 0) {
      throw StateError('the sparse GL program returned object name zero');
    }
    _instanceBuffer = _driver.createInstanceBuffer();
    if (_instanceBuffer == 0) {
      _driver.deleteProgram(_program);
      _program = 0;
      throw StateError(
          'the sparse GL instance buffer returned object name zero');
    }
  }

  /// Encodes and draws [plan]. Nothing is implicitly enabled in the renderer.
  SparseGlExecutionStats submit(
    SparseStripDrawPlan plan, {
    required List<SparseGlMaterial> materials,
    required int viewportWidth,
    required int viewportHeight,
    required int yFlip,
  }) {
    _throwIfDisposed();
    if (!isInitialized) {
      throw StateError('initialize the sparse GL executor before submit');
    }
    if (viewportWidth <= 0 || viewportHeight <= 0) {
      throw ArgumentError('viewport must be positive');
    }
    if (yFlip != 0 && yFlip != 1) {
      throw ArgumentError.value(yFlip, 'yFlip', 'must be 0 or 1');
    }
    submission.encode(plan);
    _validateMaterials(materials);
    if (submission.commandCount == 0) {
      return const SparseGlExecutionStats(
        drawCalls: 0,
        instances: 0,
        alphaUploads: 0,
        alphaUploadBytes: 0,
      );
    }

    _ensureAtlasTextures(plan);
    _driver.uploadInstances(_instanceBuffer, submission.instances);
    for (var upload = 0; upload < plan.alphaUploadCount; upload++) {
      final int page = plan.alphaUploadPage(upload);
      final int x = plan.alphaUploadX(upload);
      final int y = plan.alphaUploadY(upload);
      _driver.uploadAlpha8Region(
        _alphaTextures[page],
        x: x,
        y: y,
        width: plan.alphaUploadWidth(upload),
        height: plan.alphaUploadHeight(upload),
        pixels: plan.alphaPagePixels(page),
        sourceOffset: y * plan.atlasWidth + x,
        sourceBytesPerRow: plan.atlasWidth,
      );
    }

    _driver.beginSparsePass(
      program: _program,
      instanceBuffer: _instanceBuffer,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
      yFlip: yFlip,
    );
    try {
      for (var command = 0; command < submission.commandCount; command++) {
        final SparseGlMaterial material =
            materials[submission.commandMaterial(command)];
        _driver
          ..setBlendState(gpuBlendForMode(material.blendMode))
          ..setPremultipliedColor(
            material.red,
            material.green,
            material.blue,
            material.alpha,
          )
          ..setSparseMode(submission.commandMode(command));
        if (submission.commandMode(command) == kSparseGlModeAlpha) {
          _driver.bindAlpha8Texture(
            _alphaTextures[submission.commandAtlasPage(command)],
          );
        }
        for (final SparseGlAttribute attribute in kSparseGlAttributes) {
          _driver.setInstanceAttribute(
            location: attribute.location,
            components: attribute.components,
            strideBytes: attribute.strideBytes,
            offsetBytes:
                submission.commandAttributeOffsetBytes(command, attribute),
            divisor: attribute.divisor,
          );
        }
        _driver.drawTriangleStripInstanced(
          vertexCount: 4,
          instanceCount: submission.commandInstanceCount(command),
        );
      }
    } finally {
      // A failed shader state change or draw must not leave the backend in an
      // open sparse pass; the caller may recover the device or fall back to
      // the dense path after observing the original error.
      _driver.endSparsePass();
    }

    final SparseStripPlanMetrics metrics = plan.metrics;
    return SparseGlExecutionStats(
      drawCalls: submission.commandCount,
      instances: submission.instanceCount,
      alphaUploads: plan.alphaUploadCount,
      alphaUploadBytes: metrics.alphaUploadBytes,
    );
  }

  void dispose() {
    if (_disposed) return;
    for (final int texture in _alphaTextures) {
      _driver.deleteTexture(texture);
    }
    _alphaTextures.clear();
    if (_instanceBuffer != 0) _driver.deleteBuffer(_instanceBuffer);
    if (_program != 0) _driver.deleteProgram(_program);
    _instanceBuffer = 0;
    _program = 0;
    _disposed = true;
  }

  void _ensureAtlasTextures(SparseStripDrawPlan plan) {
    if ((_atlasWidth != 0 && _atlasWidth != plan.atlasWidth) ||
        (_atlasHeight != 0 && _atlasHeight != plan.atlasHeight)) {
      for (final int texture in _alphaTextures) {
        _driver.deleteTexture(texture);
      }
      _alphaTextures.clear();
    }
    _atlasWidth = plan.atlasWidth;
    _atlasHeight = plan.atlasHeight;
    while (_alphaTextures.length < plan.alphaPageCount) {
      final int texture = _driver.createAlpha8Texture(
        width: plan.atlasWidth,
        height: plan.atlasHeight,
      );
      if (texture == 0) {
        throw StateError(
            'the sparse GL alpha texture returned object name zero');
      }
      _alphaTextures.add(texture);
    }
  }

  void _validateMaterials(List<SparseGlMaterial> materials) {
    for (var command = 0; command < submission.commandCount; command++) {
      final int material = submission.commandMaterial(command);
      if (material < 0 || material >= materials.length) {
        throw RangeError.range(
          material,
          0,
          materials.length - 1,
          'materialIndex',
        );
      }
    }
  }

  void _throwIfDisposed() {
    if (_disposed) throw StateError('the sparse GL executor is disposed');
  }
}
