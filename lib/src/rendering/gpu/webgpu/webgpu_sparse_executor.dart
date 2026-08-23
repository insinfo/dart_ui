/// Experimental WebGPU lifecycle and executor for sparse-strip submissions.
///
/// The WebGPU sibling of `gl_sparse_executor.dart`, and deliberately the same
/// shape: a narrow, fakeable driver interface in terms of integers and typed
/// data, an executor that owns the module, the buffers and the atlas pages, and
/// an explicit submission method the display-list renderer never calls. The
/// established dense atlas path stays the default until a caller opts in while
/// adopting the device.
///
/// ## Why the driver speaks integers
///
/// Not because WebGPU has object names - it has JavaScript objects, like WebGL
/// - but because this file must compile and run **on the VM**. Every rule about
/// ordering that matters here (uploads before draws, materials validated before
/// any state changes, one draw per page run, refusal leaving nothing behind) is
/// a property of the sequence of driver calls, and a fake driver that records
/// that sequence checks all of it on a machine with no browser. The production
/// adapter in `webgpu_sparse_driver.dart` is the only file that imports
/// `dart:js_interop`, and it is thin enough to read in one sitting.
///
/// ## Transactional by construction
///
/// [WebGpuSparseExecutor.submit] encodes the plan and validates every material
/// **before** it writes a buffer, uploads a texel or begins a pass. A refused
/// submission has therefore made no driver call at all, which is what lets the
/// caller fall back to the dense atlas without having disturbed the target's
/// contents, the blend state or the submission order. Once the pass is open,
/// the only escape is `endSparsePass` in a `finally`, so a driver error cannot
/// leave a render pass encoder open and take the queue with it.
library;

import 'dart:typed_data';

import '../gl/gl_sparse_strips.dart';
import '../gpu_gradient.dart';
import '../gpu_pipeline.dart';
import '../gpu_texture.dart';
import '../vector/sparse_strip_draw_plan.dart';
import 'wgsl_sparse_shaders.dart';

/// Premultiplied material consumed by one sparse batch.
///
/// The WebGPU counterpart of `SparseGlMaterial`, with the same two
/// constructors and the same validation, because the values are the same
/// values: a premultiplied colour whose channels cannot exceed its alpha, or a
/// gradient described by the cache binding and the canonical parameter layout
/// every backend shares.
final class SparseWebGpuMaterial {
  SparseWebGpuMaterial({
    required this.red,
    required this.green,
    required this.blue,
    required this.alpha,
    required this.blendMode,
  })  : gradientBinding = null,
        gradientParameters = null {
    _validateColor(red, green, blue, alpha);
    // Resolved here rather than at draw time so a mode with no blend state is
    // refused while the caller's stack can still say which paint produced it.
    gpuBlendForMode(blendMode);
  }

  SparseWebGpuMaterial.gradient({
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

  /// The paint half of a pipeline key, in the shared submission's vocabulary.
  int get paintMode =>
      isGradient ? kSparseGlPaintGradient : kSparseGlPaintSolid;

  /// The LUT this material samples, or [kNoTexture] for a solid colour.
  int get gradientLutTexture => gradientBinding?.texture.id ?? kNoTexture;
}

/// Narrow, fakeable surface over the WebGPU calls the executor makes.
///
/// Every handle is an integer the driver invented, and never zero for a live
/// object, so the executor can treat zero as "the device refused" exactly as
/// the GL executor treats object name zero.
abstract interface class SparseWebGpuDriver {
  /// Compiles the sparse module and creates the layouts, samplers and the
  /// stand-in textures a solid pipeline still has to bind.
  void createSparseModule(String source);

  /// Drops the module, the pipeline cache and the bind-group cache.
  void destroySparseModule();

  int createInstanceBuffer(int byteCapacity);
  int createUniformBuffer(int sliceCount);
  void deleteBuffer(int buffer);

  /// Writes the whole prefix of the instance arena the frame uses.
  void writeInstances(int buffer, Float32List instances);

  /// Writes [sliceCount] uniform slices, [kWebGpuSparseUniformSliceStride]
  /// bytes apart, starting at the head of [buffer].
  void writeUniformSlices(int buffer, Uint8List slices, int sliceCount);

  int createAlpha8Texture({required int width, required int height});
  void deleteTexture(int texture);

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

  /// The pipeline for one (coverage, paint, blend) triple, created once and
  /// cached for the device's life. WebGPU bakes blend into the pipeline, so
  /// this is where a material's blend mode becomes state.
  int acquirePipeline({
    required int coverageMode,
    required int paintMode,
    required int blendMode,
  });

  /// The group-1 bind group for one atlas page and one gradient LUT. Either
  /// may be [kNoTexture], which binds the driver's stand-in.
  int acquireBindGroup({
    required int alphaTexture,
    required int gradientLut,
  });

  void beginSparsePass({
    required int instanceBuffer,
    required int uniformBuffer,
    required int viewportWidth,
    required int viewportHeight,
  });

  void setPipeline(int pipeline);

  void setDrawState({
    required int bindGroup,
    required int uniformSliceOffsetBytes,
  });

  void draw({
    required int vertexCount,
    required int instanceCount,
    required int firstInstance,
  });

  void endSparsePass();

  /// Forgets handles invalidated by device loss without destroying them.
  void discardNativeResources();
}

/// Counts work actually sent to [SparseWebGpuDriver].
final class WebGpuSparseExecutionStats {
  const WebGpuSparseExecutionStats({
    required this.drawCalls,
    required this.instances,
    required this.alphaUploads,
    required this.alphaUploadBytes,
    required this.uniformSlices,
  });

  final int drawCalls;
  final int instances;
  final int alphaUploads;
  final int alphaUploadBytes;

  /// Materials whose uniform slice this submission actually wrote. Unused
  /// materials cost nothing, which matters because a caller may reasonably
  /// hand over the whole frame's palette for a plan that touches two of it.
  final int uniformSlices;
}

/// Owns and executes the experimental sparse WebGPU pipeline.
final class WebGpuSparseExecutor {
  WebGpuSparseExecutor(
    this._driver, {
    GpuTextureAllocator? textureAllocator,
    SparseGlSubmission? submission,
  })  : _textureAllocator = textureAllocator,
        submission = submission ?? SparseGlSubmission();

  final SparseWebGpuDriver _driver;
  final GpuTextureAllocator? _textureAllocator;

  /// The shared instance and command encoder. Named for GL because that is
  /// where it lives; it contains no GL, and reusing it is what keeps the two
  /// backends' submission order identical rather than merely similar.
  final SparseGlSubmission submission;

  final List<int> _alphaTextures = <int>[];

  int _instanceBuffer = 0;
  int _instanceBufferBytes = 0;
  int _uniformBuffer = 0;
  int _uniformSliceCapacity = 0;
  Uint8List _uniformStaging = Uint8List(0);
  ByteData _uniformStagingView = ByteData(0);
  Int32List _materialSliceMark = Int32List(0);
  int _submitCounter = 0;
  int _atlasWidth = 0;
  int _atlasHeight = 0;
  bool _initialized = false;
  bool _disposed = false;

  bool get isInitialized => _initialized;
  bool get isDisposed => _disposed;
  int get retainedAlphaPageCount => _alphaTextures.length;
  int get retainedUniformSliceCapacity => _uniformSliceCapacity;

  /// Compiles the module and allocates the initial buffers.
  void initialize() {
    _throwIfDisposed();
    if (_initialized) return;
    validateWgslSparseShaderContract();
    _driver.createSparseModule(kWgslSparseShaderModuleSource);
    _ensureInstanceCapacity(256 * kWebGpuSparseInstanceStrideBytes);
    _ensureUniformCapacity(8);
    _initialized = true;
  }

  /// Encodes and draws [plan]. Nothing is implicitly enabled in the renderer.
  ///
  /// Every argument and every material is checked before the first driver
  /// call, so a refusal is a thrown error that changed nothing.
  WebGpuSparseExecutionStats submit(
    SparseStripDrawPlan plan, {
    required List<SparseWebGpuMaterial> materials,
    required int viewportWidth,
    required int viewportHeight,
  }) {
    _throwIfDisposed();
    if (!_initialized) {
      throw StateError('initialize the sparse WebGPU executor before submit');
    }
    if (viewportWidth <= 0 || viewportHeight <= 0) {
      throw ArgumentError('viewport must be positive');
    }
    submission.encode(plan);
    _validateMaterials(materials);
    if (submission.commandCount == 0) {
      return const WebGpuSparseExecutionStats(
        drawCalls: 0,
        instances: 0,
        alphaUploads: 0,
        alphaUploadBytes: 0,
        uniformSlices: 0,
      );
    }

    _ensureAtlasTextures(plan);
    _ensureInstanceCapacity(
      submission.instanceCount * kWebGpuSparseInstanceStrideBytes,
    );
    _ensureUniformCapacity(materials.length);
    final int slices = _writeUniformSlices(
      materials,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
    );

    _driver
      ..writeInstances(_instanceBuffer, submission.instances)
      ..writeUniformSlices(_uniformBuffer, _uniformStaging, materials.length);
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
      instanceBuffer: _instanceBuffer,
      uniformBuffer: _uniformBuffer,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
    );
    try {
      for (var command = 0; command < submission.commandCount; command++) {
        final int materialIndex = submission.commandMaterial(command);
        final SparseWebGpuMaterial material = materials[materialIndex];
        final int coverageMode = submission.commandMode(command);
        _driver
          ..setPipeline(_driver.acquirePipeline(
            coverageMode: coverageMode,
            paintMode: material.paintMode,
            blendMode: material.blendMode,
          ))
          ..setDrawState(
            bindGroup: _driver.acquireBindGroup(
              alphaTexture: coverageMode == kSparseGlModeAlpha
                  ? _alphaTextures[submission.commandAtlasPage(command)]
                  : kNoTexture,
              gradientLut: material.gradientLutTexture,
            ),
            uniformSliceOffsetBytes:
                materialIndex * kWebGpuSparseUniformSliceStride,
          )
          ..draw(
            vertexCount: kWebGpuSparseVertexCount,
            instanceCount: submission.commandInstanceCount(command),
            firstInstance: submission.commandFirstInstance(command),
          );
      }
    } finally {
      // A failed pipeline creation or draw must not leave a render pass
      // encoder open: WebGPU refuses every later encoder call on the same
      // command encoder, so the caller could not even fall back this frame.
      _driver.endSparsePass();
    }

    final SparseStripPlanMetrics metrics = plan.metrics;
    return WebGpuSparseExecutionStats(
      drawCalls: submission.commandCount,
      instances: submission.instanceCount,
      alphaUploads: plan.alphaUploadCount,
      alphaUploadBytes: metrics.alphaUploadBytes,
      uniformSlices: slices,
    );
  }

  void dispose() {
    if (_disposed) return;
    for (final int texture in _alphaTextures) {
      _driver.deleteTexture(texture);
    }
    _alphaTextures.clear();
    if (_instanceBuffer != 0) _driver.deleteBuffer(_instanceBuffer);
    if (_uniformBuffer != 0) _driver.deleteBuffer(_uniformBuffer);
    if (_initialized) _driver.destroySparseModule();
    _instanceBuffer = 0;
    _uniformBuffer = 0;
    _instanceBufferBytes = 0;
    _uniformSliceCapacity = 0;
    _initialized = false;
    _disposed = true;
  }

  /// Forgets driver objects destroyed by a device loss and permits a rebuild.
  void discardNativeResources() {
    _throwIfDisposed();
    _driver.discardNativeResources();
    _alphaTextures.clear();
    _instanceBuffer = 0;
    _instanceBufferBytes = 0;
    _uniformBuffer = 0;
    _uniformSliceCapacity = 0;
    _atlasWidth = 0;
    _atlasHeight = 0;
    _initialized = false;
  }

  /// Disposes after a lost device, where destroying objects is pointless.
  void disposeAfterDeviceLoss() {
    if (_disposed) return;
    discardNativeResources();
    _disposed = true;
  }

  /// Writes one slice per material and returns how many it wrote.
  ///
  /// Only materials a command actually names are written. The mark array is a
  /// retained arena stamped with a submission counter rather than a set that
  /// would allocate per frame.
  int _writeUniformSlices(
    List<SparseWebGpuMaterial> materials, {
    required int viewportWidth,
    required int viewportHeight,
  }) {
    final int mark = ++_submitCounter;
    if (_materialSliceMark.length < materials.length) {
      _materialSliceMark = Int32List(materials.length);
    }
    var written = 0;
    for (var command = 0; command < submission.commandCount; command++) {
      final int index = submission.commandMaterial(command);
      if (_materialSliceMark[index] == mark) continue;
      _materialSliceMark[index] = mark;
      final SparseWebGpuMaterial material = materials[index];
      writeWebGpuSparseUniformSlice(
        _uniformStagingView,
        index * kWebGpuSparseUniformSliceStride,
        viewportWidth: viewportWidth,
        viewportHeight: viewportHeight,
        red: material.red,
        green: material.green,
        blue: material.blue,
        alpha: material.alpha,
        gradientBinding: material.gradientBinding,
        gradientParameters: material.gradientParameters,
      );
      written++;
    }
    return written;
  }

  void _ensureInstanceCapacity(int bytes) {
    if (_instanceBuffer != 0 && bytes <= _instanceBufferBytes) return;
    var capacity = _instanceBufferBytes == 0
        ? 256 * kWebGpuSparseInstanceStrideBytes
        : _instanceBufferBytes;
    while (capacity < bytes) {
      capacity *= 2;
    }
    if (_instanceBuffer != 0) _driver.deleteBuffer(_instanceBuffer);
    _instanceBuffer = _driver.createInstanceBuffer(capacity);
    if (_instanceBuffer == 0) {
      _instanceBufferBytes = 0;
      throw StateError('the sparse WebGPU instance buffer was refused');
    }
    _instanceBufferBytes = capacity;
  }

  void _ensureUniformCapacity(int slices) {
    if (_uniformBuffer != 0 && slices <= _uniformSliceCapacity) return;
    var capacity = _uniformSliceCapacity == 0 ? 8 : _uniformSliceCapacity;
    while (capacity < slices) {
      capacity *= 2;
    }
    if (_uniformBuffer != 0) _driver.deleteBuffer(_uniformBuffer);
    _uniformBuffer = _driver.createUniformBuffer(capacity);
    if (_uniformBuffer == 0) {
      _uniformSliceCapacity = 0;
      throw StateError('the sparse WebGPU uniform buffer was refused');
    }
    _uniformSliceCapacity = capacity;
    _uniformStaging = Uint8List(capacity * kWebGpuSparseUniformSliceStride);
    _uniformStagingView = ByteData.sublistView(_uniformStaging);
    // A grown arena has never been stamped, so nothing may claim to be
    // written already.
    _materialSliceMark = Int32List(capacity);
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
        throw StateError('the sparse WebGPU alpha page was refused');
      }
      _alphaTextures.add(texture);
    }
  }

  void _validateMaterials(List<SparseWebGpuMaterial> materials) {
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
      final SparseWebGpuMaterial value = materials[material];
      // Resolved before the pass so an unmappable blend mode is a refusal
      // rather than a pipeline created inside an open encoder.
      gpuBlendForMode(value.blendMode);
      if (!value.isGradient) continue;
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
          'gradient material LUT does not belong to this WebGPU device or its '
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
  }

  void _throwIfDisposed() {
    if (_disposed) throw StateError('the sparse WebGPU executor is disposed');
  }
}
