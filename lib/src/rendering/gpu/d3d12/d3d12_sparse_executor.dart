/// Experimental Direct3D 12 lifecycle and executor for sparse-strip
/// submissions.
///
/// The counterpart of `gl_sparse_executor.dart`, and opt-in for the same
/// reason: it is reached only through an explicit submission method on the
/// device, so the established dense-mask renderer is unchanged while the sparse
/// path gains fake-driver and live-driver coverage.
///
/// Nothing in this file names Direct3D. It owns the *policy* - which page
/// texture, which material, which order, what to forget after a device reset -
/// and [SparseD3d12Driver] is the narrow, fakeable surface a backend implements
/// with real API calls. That split is what keeps this file in
/// `lib/src/rendering`, where `test/architecture/layering_test.dart` forbids
/// naming `d3d12.dll`.
library;

import 'dart:typed_data';

import '../gpu_gradient.dart';
import '../gpu_pipeline.dart';
import '../gpu_texture.dart';
import '../vector/sparse_strip_draw_plan.dart';
import 'd3d12_sparse_strips.dart';

/// Premultiplied material consumed by one sparse batch.
///
/// Value-identical to `SparseGlMaterial`, including the premultiplication
/// check: a colour channel above its own alpha is not a colour this renderer
/// can composite, and catching it here is what stops it becoming an invisible
/// difference against the CPU rasteriser.
final class SparseD3d12Material {
  SparseD3d12Material({
    required this.red,
    required this.green,
    required this.blue,
    required this.alpha,
    required this.blendMode,
  })  : gradientBinding = null,
        gradientParameters = null {
    _validateColor(red, green, blue, alpha);
    gpuBlendForMode(blendMode);
  }

  /// A gradient material using the cache binding and canonical parameter
  /// layout shared by every GPU backend.
  SparseD3d12Material.gradient({
    required this.gradientBinding,
    required this.gradientParameters,
    required this.blendMode,
  })  : red = 0,
        green = 0,
        blue = 0,
        alpha = 0 {
    if (gradientBinding == null || gradientParameters == null) {
      throw ArgumentError('gradient binding and parameters are required');
    }
    gpuBlendForMode(blendMode);
  }

  static void _validateColor(
    double red,
    double green,
    double blue,
    double alpha,
  ) {
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
  }

  final double red;
  final double green;
  final double blue;
  final double alpha;
  final int blendMode;
  final GpuGradientBinding? gradientBinding;
  final GpuGradientShaderParameters? gradientParameters;

  bool get isGradient => gradientBinding != null;
}

/// Narrow, fakeable surface over the Direct3D 12 calls the executor uses.
///
/// A production adapter maps these onto a command list, a root signature and
/// three pipeline state objects. Typed data stays on this side of the seam so
/// upload-heap policy belongs to that adapter and not to the backend-neutral
/// [SparseStripDrawPlan].
///
/// The instance data has no `createBuffer` counterpart, and that absence is
/// deliberate rather than an omission: Direct3D 12 geometry read exactly once
/// belongs in the frame's upload arena, whose lifetime is already tied to the
/// fence that releases the command allocator. A long-lived vertex buffer here
/// would be a second lifetime to get wrong. See `d3d12_frame_ring.dart`.
abstract interface class SparseD3d12Driver {
  /// Compiles the HLSL and builds the root signature and pipeline states.
  /// Returns a non-zero token identifying them, or zero on refusal.
  int createSparsePipeline();

  void disposeSparsePipeline(int pipeline);

  /// A page of the alpha8 coverage atlas. Zero on refusal.
  int createAlpha8Texture({required int width, required int height});

  void deleteTexture(int texture);

  /// Stages the whole instance array for the frame in progress.
  void uploadInstances(Float32List instances);

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
    required int pipeline,
    required int viewportWidth,
    required int viewportHeight,
  });

  /// Direct3D 12 bakes blend factors into a pipeline state object, so this
  /// selects one rather than setting dynamic state.
  void setBlendState(GpuBlendState blend);

  void setPremultipliedColor(
    double red,
    double green,
    double blue,
    double alpha,
  );

  void useSolidPaint();

  void useGradientPaint(
    GpuGradientBinding binding,
    GpuGradientShaderParameters parameters,
  );

  void setSparseMode(int mode);

  void bindAlpha8Texture(int texture);

  /// `DrawInstanced`. [firstInstance] is `StartInstanceLocation`, which offsets
  /// the per-instance fetch - the API feature that removes the GL executor's
  /// attribute rebasing entirely.
  void drawTriangleStripInstanced({
    required int vertexCount,
    required int instanceCount,
    required int firstInstance,
  });

  void endSparsePass();

  /// Forgets objects invalidated by device removal without releasing them.
  void discardNativeResources();
}

/// Counts work actually sent to [SparseD3d12Driver].
final class SparseD3d12ExecutionStats {
  const SparseD3d12ExecutionStats({
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

/// Owns and executes the experimental sparse Direct3D 12 pipeline.
final class SparseD3d12Executor {
  SparseD3d12Executor(
    this._driver, {
    GpuTextureAllocator? textureAllocator,
    SparseD3d12Submission? submission,
  })  : _textureAllocator = textureAllocator,
        submission = submission ?? SparseD3d12Submission();

  final SparseD3d12Driver _driver;
  final GpuTextureAllocator? _textureAllocator;
  final SparseD3d12Submission submission;
  final List<int> _alphaTextures = <int>[];

  int _pipeline = 0;
  int _atlasWidth = 0;
  int _atlasHeight = 0;
  bool _disposed = false;

  bool get isInitialized => _pipeline != 0;
  bool get isDisposed => _disposed;
  int get retainedAlphaPageCount => _alphaTextures.length;

  /// Builds the root signature and the pipeline states.
  void initialize() {
    _throwIfDisposed();
    if (isInitialized) return;
    validateD3d12SparseShaderContract();
    _pipeline = _driver.createSparsePipeline();
    if (_pipeline == 0) {
      throw StateError('the sparse Direct3D 12 pipeline was refused');
    }
  }

  /// Encodes and draws [plan]. Nothing is implicitly enabled in the renderer.
  SparseD3d12ExecutionStats submit(
    SparseStripDrawPlan plan, {
    required List<SparseD3d12Material> materials,
    required int viewportWidth,
    required int viewportHeight,
  }) {
    _throwIfDisposed();
    if (!isInitialized) {
      throw StateError('initialize the sparse Direct3D 12 executor before '
          'submit');
    }
    if (viewportWidth <= 0 || viewportHeight <= 0) {
      throw ArgumentError('viewport must be positive');
    }
    submission.encode(plan);
    _validateMaterials(materials);
    if (submission.commandCount == 0) {
      return const SparseD3d12ExecutionStats(
        drawCalls: 0,
        instances: 0,
        alphaUploads: 0,
        alphaUploadBytes: 0,
      );
    }

    _ensureAtlasTextures(plan);
    _driver.uploadInstances(submission.instances);
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
      pipeline: _pipeline,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
    );
    try {
      for (var command = 0; command < submission.commandCount; command++) {
        final SparseD3d12Material material =
            materials[submission.commandMaterial(command)];
        _driver.setBlendState(gpuBlendForMode(material.blendMode));
        if (material.isGradient) {
          _driver.useGradientPaint(
            material.gradientBinding!,
            material.gradientParameters!,
          );
        } else {
          _driver
            ..useSolidPaint()
            ..setPremultipliedColor(
              material.red,
              material.green,
              material.blue,
              material.alpha,
            );
        }
        _driver.setSparseMode(submission.commandMode(command));
        if (submission.commandMode(command) == kD3d12SparseModeAlpha) {
          _driver.bindAlpha8Texture(
            _alphaTextures[submission.commandAtlasPage(command)],
          );
        }
        _driver.drawTriangleStripInstanced(
          vertexCount: 4,
          instanceCount: submission.commandInstanceCount(command),
          firstInstance: submission.commandFirstInstance(command),
        );
      }
    } finally {
      // A failed state change or draw must not leave the backend inside an
      // open sparse pass; the caller may recover the device or fall back to
      // the dense path after observing the original error.
      _driver.endSparsePass();
    }

    final SparseStripPlanMetrics metrics = plan.metrics;
    return SparseD3d12ExecutionStats(
      drawCalls: submission.commandCount,
      instances: submission.instanceCount,
      alphaUploads: plan.alphaUploadCount,
      alphaUploadBytes: metrics.alphaUploadBytes,
    );
  }

  /// Composites an externally produced coverage texture as one quad.
  ///
  /// This is the seam approach D lands on, and reusing this pipeline for it is
  /// the whole design rather than a shortcut. A compute dispatch writes
  /// coverage into a target-sized single-channel texture; an alpha instance of
  /// this pipeline is *already* "sample a single-channel texture at a device
  /// pixel and modulate a material by it". Setting `atlasOrigin` to the quad's
  /// device origin makes the interpolated atlas coordinate equal the device
  /// coordinate, so the existing `Load` reads coverage at exactly the pixel
  /// being shaded. No second shader, no second root signature, and - more
  /// importantly - no second copy of the premultiply/blend arithmetic that the
  /// parity tests hold to zero.
  ///
  /// [coverageTexture] is a texture the *caller* owns and has already
  /// transitioned to a shader-readable state; this executor neither creates nor
  /// frees it. The rectangle is in device pixels, half-open, and must be one
  /// the producer guarantees it wrote every pixel of.
  void submitCoverageQuad({
    required int coverageTexture,
    required int left,
    required int top,
    required int right,
    required int bottom,
    required SparseD3d12Material material,
    required int viewportWidth,
    required int viewportHeight,
  }) {
    _throwIfDisposed();
    if (!isInitialized) {
      throw StateError('initialize the sparse Direct3D 12 executor before '
          'compositing a coverage quad');
    }
    if (viewportWidth <= 0 || viewportHeight <= 0) {
      throw ArgumentError('viewport must be positive');
    }
    if (right <= left || bottom <= top) return;
    if (coverageTexture == 0) {
      throw ArgumentError.value(
        coverageTexture,
        'coverageTexture',
        'zero is the placeholder descriptor, which carries no coverage',
      );
    }
    _validateMaterial(material);

    final Float32List instance = Float32List(
      kD3d12SparseInstanceFloatCount,
    );
    instance[0] = left.toDouble();
    instance[1] = top.toDouble();
    instance[2] = (right - left).toDouble();
    instance[3] = (bottom - top).toDouble();
    // The atlas origin *is* the device origin: coverage is target-sized and
    // one texel per pixel, so the two spaces coincide.
    instance[4] = left.toDouble();
    instance[5] = top.toDouble();

    _driver
      ..uploadInstances(instance)
      ..beginSparsePass(
        pipeline: _pipeline,
        viewportWidth: viewportWidth,
        viewportHeight: viewportHeight,
      );
    try {
      _driver.setBlendState(gpuBlendForMode(material.blendMode));
      if (material.isGradient) {
        _driver.useGradientPaint(
          material.gradientBinding!,
          material.gradientParameters!,
        );
      } else {
        _driver
          ..useSolidPaint()
          ..setPremultipliedColor(
            material.red,
            material.green,
            material.blue,
            material.alpha,
          );
      }
      _driver
        ..setSparseMode(kD3d12SparseModeAlpha)
        ..bindAlpha8Texture(coverageTexture)
        ..drawTriangleStripInstanced(
          vertexCount: 4,
          instanceCount: 1,
          firstInstance: 0,
        );
    } finally {
      _driver.endSparsePass();
    }
  }

  void dispose() {
    if (_disposed) return;
    for (final int texture in _alphaTextures) {
      _driver.deleteTexture(texture);
    }
    _alphaTextures.clear();
    if (_pipeline != 0) _driver.disposeSparsePipeline(_pipeline);
    _pipeline = 0;
    _disposed = true;
  }

  /// Forgets driver objects destroyed by a device reset and permits
  /// reinitialisation.
  void discardNativeResources() {
    _throwIfDisposed();
    _driver.discardNativeResources();
    _alphaTextures.clear();
    _pipeline = 0;
    _atlasWidth = 0;
    _atlasHeight = 0;
  }

  /// Disposes after device removal, where releasing an object is undefined.
  void disposeAfterDeviceLoss() {
    if (_disposed) return;
    discardNativeResources();
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
        throw StateError('a sparse alpha page could not be created');
      }
      _alphaTextures.add(texture);
    }
  }

  void _validateMaterials(List<SparseD3d12Material> materials) {
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
      _validateMaterial(materials[material]);
    }
  }

  void _validateMaterial(SparseD3d12Material value) {
    if (!value.isGradient) return;
    final GpuGradientBinding binding = value.gradientBinding!;
    final GpuGradientShaderParameters parameters = value.gradientParameters!;
    if (binding.gradient != parameters.gradient) {
      throw ArgumentError(
        'gradient binding LUT does not match shader parameters',
      );
    }
    final GpuTextureHandle texture = binding.texture;
    final GpuTextureAllocator? textureAllocator = _textureAllocator;
    if (textureAllocator == null || !binding.isUsableBy(textureAllocator)) {
      throw StateError(
        'gradient material LUT does not belong to this Direct3D 12 device '
        'or its native generation is no longer valid',
      );
    }
    if (texture.id == kNoTexture ||
        binding.lutSize < 2 ||
        texture.width != binding.lutSize ||
        texture.height != 1 ||
        texture.format != GpuTextureFormat.rgba8888Straight ||
        texture.filter != GpuTextureFilter.linear) {
      throw StateError(
        'gradient material has an invalid or incompatible LUT texture',
      );
    }
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('the sparse Direct3D 12 executor is disposed');
    }
  }
}
