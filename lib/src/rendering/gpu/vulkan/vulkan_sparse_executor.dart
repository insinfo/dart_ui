/// Experimental Vulkan lifecycle and executor for sparse-strip submissions.
///
/// The counterpart of `gl_sparse_executor.dart` and `d3d12_sparse_executor.dart`,
/// opt-in for the same reason: it is reached only through an explicit
/// submission method on the target, so the established dense-mask renderer is
/// unchanged while the sparse path gains fake-driver and live-driver coverage.
///
/// Nothing in this file names Vulkan's API. It owns the *policy* - which page
/// image, which material, which order, what to forget after a device loss -
/// and [SparseVulkanDriver] is the narrow, fakeable surface `vulkan_sparse_-`
/// `driver.dart` implements with real `vkCmd*` calls. That split is what lets
/// the ordering rules be tested on a runner with no Vulkan at all, which is
/// most of them.
///
/// ## Why the driver looks like the Direct3D 12 one
///
/// Method for method, and deliberately. The two APIs disagree about almost
/// everything at the call site and agree about everything that matters here:
/// blend is baked into a pipeline object rather than set as state, the draw
/// takes a first-instance rather than a rebased attribute pointer, and the
/// coverage page and the gradient ramp are bound as descriptors rather than as
/// texture units. Where they differ is *inside* the adapter - `setBlendState`
/// and `setSparseMode` record which pipeline the next draw needs instead of
/// binding one, because a Vulkan pipeline is the whole cross product and only
/// the draw knows every coordinate of it.
library;

import 'dart:typed_data';

import '../gpu_gradient.dart';
import '../gpu_pipeline.dart';
import '../gpu_texture.dart';
import '../vector/sparse_strip_draw_plan.dart';
import 'vulkan_sparse_strips.dart';

/// Premultiplied material consumed by one sparse batch.
///
/// Value-identical to `SparseGlMaterial` and `SparseD3d12Material`, including
/// the premultiplication check: a colour channel above its own alpha is not a
/// colour this renderer can composite, and catching it here is what stops it
/// becoming an invisible difference against the CPU rasteriser.
final class SparseVulkanMaterial {
  SparseVulkanMaterial({
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
  SparseVulkanMaterial.gradient({
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

/// Narrow, fakeable surface over the Vulkan calls the executor uses.
///
/// A production adapter maps these onto one open command buffer, one pipeline
/// layout and twelve graphics pipelines. Typed data stays on this side of the
/// seam so host-visible-buffer policy belongs to that adapter and not to the
/// backend-neutral [SparseStripDrawPlan].
///
/// There is no `createBuffer` for the instance data, and the absence is
/// deliberate rather than an omission: geometry read exactly once belongs to
/// the adapter's own frame arena, whose lifetime is already tied to the fence
/// that retires the command buffer. A long-lived vertex buffer here would be a
/// second lifetime to get wrong.
abstract interface class SparseVulkanDriver {
  /// Builds the pipeline layout and the graphics pipelines. Returns a non-zero
  /// token identifying them, or zero on refusal.
  int createSparsePipeline();

  void disposeSparsePipeline(int pipeline);

  /// A page of the alpha8 coverage atlas, as an `R8_UNORM` sampled image with
  /// its descriptor set already written. Zero on refusal.
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

  /// Vulkan bakes blend factors into a `VkPipeline`, so this selects one rather
  /// than setting dynamic state.
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

  /// `vkCmdDraw`. [firstInstance] is the `firstInstance` parameter, which
  /// offsets the per-instance fetch - the API feature that removes the GL
  /// executor's attribute rebasing entirely.
  void drawTriangleStripInstanced({
    required int vertexCount,
    required int instanceCount,
    required int firstInstance,
  });

  void endSparsePass();

  /// Forgets objects invalidated by device loss without destroying them.
  void discardNativeResources();
}

/// Counts work actually sent to [SparseVulkanDriver].
final class SparseVulkanExecutionStats {
  const SparseVulkanExecutionStats({
    required this.drawCalls,
    required this.instances,
    required this.alphaUploads,
    required this.alphaUploadBytes,
  });

  final int drawCalls;
  final int instances;
  final int alphaUploads;
  final int alphaUploadBytes;

  @override
  String toString() => 'SparseVulkanExecutionStats(draws: $drawCalls, '
      'instances: $instances, uploads: $alphaUploads/$alphaUploadBytes B)';
}

/// Owns and executes the experimental sparse Vulkan pipeline.
final class SparseVulkanExecutor {
  SparseVulkanExecutor(
    this._driver, {
    GpuTextureAllocator? textureAllocator,
    SparseVulkanSubmission? submission,
  })  : _textureAllocator = textureAllocator,
        submission = submission ?? SparseVulkanSubmission();

  final SparseVulkanDriver _driver;
  final GpuTextureAllocator? _textureAllocator;
  final SparseVulkanSubmission submission;
  final List<int> _alphaTextures = <int>[];

  int _pipeline = 0;
  int _atlasWidth = 0;
  int _atlasHeight = 0;
  bool _disposed = false;

  bool get isInitialized => _pipeline != 0;
  bool get isDisposed => _disposed;
  int get retainedAlphaPageCount => _alphaTextures.length;

  /// Builds the pipeline layout and the graphics pipelines.
  void initialize() {
    _throwIfDisposed();
    if (isInitialized) return;
    validateVulkanSparseShaderContract();
    _pipeline = _driver.createSparsePipeline();
    if (_pipeline == 0) {
      throw StateError('the sparse Vulkan pipeline was refused');
    }
  }

  /// Encodes and draws [plan]. Nothing is implicitly enabled in the renderer.
  ///
  /// Every material is validated *before* the first driver call that could
  /// change device state, which is what makes a refusal transactional: a
  /// caller that catches the error is looking at a target whose contents and
  /// whose bound state are exactly what they were, and can fall back to the
  /// dense atlas without undoing anything.
  SparseVulkanExecutionStats submit(
    SparseStripDrawPlan plan, {
    required List<SparseVulkanMaterial> materials,
    required int viewportWidth,
    required int viewportHeight,
  }) {
    _throwIfDisposed();
    if (!isInitialized) {
      throw StateError('initialize the sparse Vulkan executor before submit');
    }
    if (viewportWidth <= 0 || viewportHeight <= 0) {
      throw ArgumentError('viewport must be positive');
    }
    submission.encode(plan);
    _validateMaterials(materials);
    if (submission.commandCount == 0) {
      return const SparseVulkanExecutionStats(
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
        final SparseVulkanMaterial material =
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
        if (submission.commandMode(command) == kVulkanSparseModeAlpha) {
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
    return SparseVulkanExecutionStats(
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
    if (_pipeline != 0) _driver.disposeSparsePipeline(_pipeline);
    _pipeline = 0;
    _disposed = true;
  }

  /// Forgets driver objects destroyed by a device loss and permits
  /// reinitialisation.
  void discardNativeResources() {
    _throwIfDisposed();
    _driver.discardNativeResources();
    _alphaTextures.clear();
    _pipeline = 0;
    _atlasWidth = 0;
    _atlasHeight = 0;
  }

  /// Disposes after device loss, where destroying an object is undefined.
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

  void _validateMaterials(List<SparseVulkanMaterial> materials) {
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

  void _validateMaterial(SparseVulkanMaterial value) {
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
        'gradient material LUT does not belong to this Vulkan device or its '
        'native generation is no longer valid',
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
      throw StateError('the sparse Vulkan executor is disposed');
    }
  }
}
