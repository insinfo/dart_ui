/// Production [SparseWebGpuDriver] over a real [GPUDevice].
///
/// The WebGPU counterpart of `gl_sparse_driver.dart`, and the only file of the
/// sparse WebGPU path that imports `dart:js_interop`. Everything above it - the
/// shader module, the uniform layout, the executor, the ordering - is checked
/// on the VM; what is left here is object creation, caching and the six calls a
/// render pass encoder actually receives.
///
/// ## The target is staged, not passed
///
/// [SparseWebGpuDriver.beginSparsePass] takes no attachment, because the
/// executor is VM-testable and a `GPUTextureView` is not a thing it can name.
/// The device seam calls [stageTarget] immediately before
/// `WebGpuSparseExecutor.submit` and the pass picks it up. A submission with no
/// staged target throws before it draws, which is the same refusal shape as
/// every other precondition on this path.
///
/// ## The caches
///
/// Pipelines are keyed by (coverage, paint, blend) - twelve at most - and bind
/// groups by (atlas page, gradient LUT). Both live for the device's life and
/// are dropped together with the module, because both reference it. The group-0
/// bind group is keyed by uniform buffer instead: a grown uniform buffer must
/// invalidate exactly that one group and not the texture cache, which is the
/// same split `webgpu_backend.dart` makes and for the same reason.
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../gpu_pipeline.dart';
import '../gpu_texture.dart';
import '../webgl/webgl_framebuffer_pool.dart' show WebGlObjectTable;
import 'webgpu_backend.dart' show WebGpuSampledTexture;
import 'webgpu_interop.dart';
import 'webgpu_sparse_executor.dart';
import 'wgsl_shaders.dart' show webGpuBlendFactorName, webGpuClearValue;
import 'wgsl_sparse_shaders.dart';

/// One alpha-atlas page: the texture and the view a bind group holds.
final class _SparseAlphaPage {
  _SparseAlphaPage(this.texture, this.view);

  final GPUTexture texture;
  final GPUTextureView view;
}

/// Maps the fakeable sparse contract to a real WebGPU device.
final class WebGpuSparseDriver implements SparseWebGpuDriver {
  WebGpuSparseDriver({
    required GPUDevice device,
    required String targetFormat,
    required WebGlObjectTable<WebGpuSampledTexture> sampledTextures,
  })  : _device = device,
        _targetFormat = targetFormat,
        _sampledTextures = sampledTextures;

  GPUDevice _device;
  final String _targetFormat;
  final WebGlObjectTable<WebGpuSampledTexture> _sampledTextures;

  GPUShaderModule? _module;
  GPUBindGroupLayout? _uniformLayout;
  GPUBindGroupLayout? _textureLayout;
  GPUPipelineLayout? _pipelineLayout;
  GPUSampler? _lutSampler;
  GPUTexture? _dummyAlpha;
  GPUTexture? _dummyLut;
  GPUTextureView? _dummyAlphaView;
  GPUTextureView? _dummyLutView;

  final Map<int, GPUBuffer> _buffers = <int, GPUBuffer>{};
  final Map<int, _SparseAlphaPage> _pages = <int, _SparseAlphaPage>{};
  final Map<int, GPURenderPipeline> _pipelines = <int, GPURenderPipeline>{};

  /// Keyed by [_bindGroupKey]: one group per (atlas page, gradient LUT) pair.
  final Map<int, GPUBindGroup> _bindGroups = <int, GPUBindGroup>{};
  final Map<int, GPUBindGroup> _frameBindGroups = <int, GPUBindGroup>{};

  /// Packs the two texture handles into the integer the executor passes back.
  ///
  /// A handle is a small counter, so twenty bits for the LUT is room for a
  /// million live gradients; the shift is checked by an assertion rather than
  /// trusted, because a silent collision would bind one gradient's ramp to
  /// another's geometry and draw a picture nobody could explain.
  static int _bindGroupKey(int alphaTexture, int gradientLut) {
    if (gradientLut < 0 || gradientLut > 0xFFFFF || alphaTexture < 0) {
      throw RangeError('sparse texture handles outside the packable range: '
          'alpha=$alphaTexture, lut=$gradientLut');
    }
    return alphaTexture * 0x100000 + gradientLut;
  }

  /// Never zero: the executor reads zero as "the device refused".
  int _nextHandle = 1;

  Uint8List _alphaStaging = Uint8List(0);
  GPUTextureView? _stagedTarget;
  int? _stagedClearColor;
  GPUCommandEncoder? _encoder;
  GPURenderPassEncoder? _pass;
  int _currentUniformBuffer = 0;

  /// Whether a pass is open. Only true between begin and end.
  bool get hasOpenPass => _pass != null;

  /// The attachment the next submission renders into.
  ///
  /// [clearColor] is the packed premultiplied BGRA integer the rest of the
  /// renderer carries; null loads the target's existing contents, which is
  /// what an alternative executor drawing *into* an already-composed frame
  /// must do.
  void stageTarget(GPUTextureView view, {int? clearColor}) {
    _stagedTarget = view;
    _stagedClearColor = clearColor;
  }

  /// Points the driver at the device a recovery produced.
  void adoptDevice(GPUDevice device) {
    _device = device;
    discardNativeResources();
  }

  @override
  void createSparseModule(String source) {
    final GPUDevice device = _device;
    _module = device.createShaderModule(
      GPUShaderModuleDescriptor(code: source),
    );
    _uniformLayout = device.createBindGroupLayout(GPUBindGroupLayoutDescriptor(
      entries: <GPUBindGroupLayoutEntry>[
        GPUBindGroupLayoutEntry(
          binding: 0,
          // The vertex stage reads the viewport out of the same slice the
          // fragment stage reads the paint out of, which is why one struct and
          // both stages rather than two buffers.
          visibility:
              web.$GPUShaderStage.VERTEX | web.$GPUShaderStage.FRAGMENT,
          buffer: GPUBufferBindingLayout(
            type: 'uniform',
            hasDynamicOffset: true,
            minBindingSize: kWebGpuSparseUniformSliceSize,
          ),
        ),
      ].toJS,
    ));
    _textureLayout = device.createBindGroupLayout(GPUBindGroupLayoutDescriptor(
      entries: <GPUBindGroupLayoutEntry>[
        GPUBindGroupLayoutEntry(
          binding: 0,
          visibility: web.$GPUShaderStage.FRAGMENT,
          // 'unfilterable-float' would be the honest sample type for a texture
          // only ever read with textureLoad, but r8unorm is filterable and
          // declaring it so keeps this layout usable if a future material ever
          // does sample the atlas.
          texture: GPUTextureBindingLayout(sampleType: 'float'),
        ),
        GPUBindGroupLayoutEntry(
          binding: 1,
          visibility: web.$GPUShaderStage.FRAGMENT,
          texture: GPUTextureBindingLayout(sampleType: 'float'),
        ),
        GPUBindGroupLayoutEntry(
          binding: 2,
          visibility: web.$GPUShaderStage.FRAGMENT,
          sampler: GPUSamplerBindingLayout(type: 'filtering'),
        ),
      ].toJS,
    ));
    _pipelineLayout = device.createPipelineLayout(GPUPipelineLayoutDescriptor(
      bindGroupLayouts:
          <GPUBindGroupLayout>[_uniformLayout!, _textureLayout!].toJS,
    ));
    _lutSampler = device.createSampler(GPUSamplerDescriptor(
      magFilter: 'linear',
      minFilter: 'linear',
      // The LUT is one row of texel centres; a wrapped tap at either end would
      // pull in the opposite stop and invert the ramp's ends.
      addressModeU: 'clamp-to-edge',
      addressModeV: 'clamp-to-edge',
    ));

    // Stand-ins for "this pipeline reads no atlas" and "this pipeline reads no
    // LUT". A solid fill samples neither, but the pipeline layout names group
    // 1 for every pipeline and WebGPU validates what is bound rather than what
    // is read.
    final GPUTexture dummyAlpha = device.createTexture(GPUTextureDescriptor(
      size: GPUExtent3DDict(width: 1, height: 1),
      format: kWebGpuSparseAlphaFormat,
      usage:
          web.$GPUTextureUsage.TEXTURE_BINDING | web.$GPUTextureUsage.COPY_DST,
    ));
    device.queue.writeTexture(
      GPUTexelCopyTextureInfo(
        texture: dummyAlpha,
        origin: GPUOrigin3DDict(x: 0, y: 0),
      ),
      Uint8List.fromList(const <int>[0xFF]).toJS,
      GPUTexelCopyBufferLayout(offset: 0, bytesPerRow: 1, rowsPerImage: 1),
      GPUExtent3DDict(width: 1, height: 1),
    );
    final GPUTexture dummyLut = device.createTexture(GPUTextureDescriptor(
      size: GPUExtent3DDict(width: 1, height: 1),
      format: kWebGpuSparseGradientLutFormat,
      usage:
          web.$GPUTextureUsage.TEXTURE_BINDING | web.$GPUTextureUsage.COPY_DST,
    ));
    device.queue.writeTexture(
      GPUTexelCopyTextureInfo(
        texture: dummyLut,
        origin: GPUOrigin3DDict(x: 0, y: 0),
      ),
      Uint8List.fromList(const <int>[0xFF, 0xFF, 0xFF, 0xFF]).toJS,
      GPUTexelCopyBufferLayout(offset: 0, bytesPerRow: 4, rowsPerImage: 1),
      GPUExtent3DDict(width: 1, height: 1),
    );
    _dummyAlpha = dummyAlpha;
    _dummyLut = dummyLut;
    _dummyAlphaView = dummyAlpha.createView();
    _dummyLutView = dummyLut.createView();
    _pipelines.clear();
    _bindGroups.clear();
    _frameBindGroups.clear();
  }

  @override
  void destroySparseModule() {
    _dummyAlpha?.destroy();
    _dummyLut?.destroy();
    _forgetModule();
  }

  @override
  int createInstanceBuffer(int byteCapacity) {
    if (byteCapacity <= 0) {
      throw ArgumentError.value(byteCapacity, 'byteCapacity', 'must be > 0');
    }
    return _registerBuffer(_device.createBuffer(GPUBufferDescriptor(
      size: byteCapacity,
      usage: web.$GPUBufferUsage.VERTEX | web.$GPUBufferUsage.COPY_DST,
    )));
  }

  @override
  int createUniformBuffer(int sliceCount) {
    if (sliceCount <= 0) {
      throw ArgumentError.value(sliceCount, 'sliceCount', 'must be > 0');
    }
    return _registerBuffer(_device.createBuffer(GPUBufferDescriptor(
      size: sliceCount * kWebGpuSparseUniformSliceStride,
      usage: web.$GPUBufferUsage.UNIFORM | web.$GPUBufferUsage.COPY_DST,
    )));
  }

  @override
  void deleteBuffer(int buffer) {
    final GPUBuffer? object = _buffers.remove(buffer);
    _frameBindGroups.remove(buffer);
    object?.destroy();
  }

  @override
  void writeInstances(int buffer, Float32List instances) {
    if (instances.isEmpty) return;
    _device.queue.writeBuffer(_buffer(buffer), 0, instances.toJS);
  }

  @override
  void writeUniformSlices(int buffer, Uint8List slices, int sliceCount) {
    final int bytes = sliceCount * kWebGpuSparseUniformSliceStride;
    if (bytes <= 0) return;
    if (bytes > slices.lengthInBytes) {
      throw RangeError('the uniform staging holds fewer than $sliceCount '
          'slices');
    }
    _device.queue.writeBuffer(
      _buffer(buffer),
      0,
      Uint8List.sublistView(slices, 0, bytes).toJS,
    );
  }

  @override
  int createAlpha8Texture({required int width, required int height}) {
    final GPUTexture texture = _device.createTexture(GPUTextureDescriptor(
      size: GPUExtent3DDict(width: width, height: height),
      format: kWebGpuSparseAlphaFormat,
      usage:
          web.$GPUTextureUsage.TEXTURE_BINDING | web.$GPUTextureUsage.COPY_DST,
    ));
    final int handle = _nextHandle++;
    _pages[handle] = _SparseAlphaPage(texture, texture.createView());
    return handle;
  }

  @override
  void deleteTexture(int texture) {
    final _SparseAlphaPage? page = _pages.remove(texture);
    if (page == null) return;
    // Every group that referenced this page goes with it, whichever LUT it was
    // paired with; a cached group holding a destroyed view is a validation
    // error on the next draw that binds it.
    _bindGroups.removeWhere(
      (int key, GPUBindGroup _) => key ~/ 0x100000 == texture,
    );
    page.texture.destroy();
  }

  @override
  void uploadAlpha8Region(
    int texture, {
    required int x,
    required int y,
    required int width,
    required int height,
    required Uint8List pixels,
    required int sourceOffset,
    required int sourceBytesPerRow,
  }) {
    if (width <= 0 || height <= 0 || sourceBytesPerRow < width) {
      throw ArgumentError('invalid sparse alpha upload dimensions');
    }
    final int last = sourceOffset + (height - 1) * sourceBytesPerRow + width;
    if (sourceOffset < 0 || last > pixels.length) {
      throw RangeError('sparse alpha upload exceeds its source page');
    }
    final _SparseAlphaPage page = _page(texture);
    // Repacked into contiguous rows rather than handed over with a row stride,
    // which is the same choice `uploadRegion` makes on both web backends: the
    // copy is over the dirty region only.
    final int bytes = width * height;
    final Uint8List staging = _ensureAlphaStaging(bytes);
    for (var row = 0; row < height; row++) {
      staging.setRange(
        row * width,
        (row + 1) * width,
        pixels,
        sourceOffset + row * sourceBytesPerRow,
      );
    }
    _device.queue.writeTexture(
      GPUTexelCopyTextureInfo(
        texture: page.texture,
        origin: GPUOrigin3DDict(x: x, y: y),
      ),
      Uint8List.sublistView(staging, 0, bytes).toJS,
      GPUTexelCopyBufferLayout(
        offset: 0,
        bytesPerRow: width,
        rowsPerImage: height,
      ),
      GPUExtent3DDict(width: width, height: height),
    );
  }

  @override
  int acquirePipeline({
    required int coverageMode,
    required int paintMode,
    required int blendMode,
  }) {
    final int key = (coverageMode << 12) | (paintMode << 8) | blendMode;
    final GPURenderPipeline? cached = _pipelines[key];
    if (cached != null) return key;
    final GPUShaderModule? module = _module;
    if (module == null) {
      throw StateError('the sparse WebGPU module has not been created');
    }
    final GpuBlendState blend = gpuBlendForMode(blendMode);
    final GPUBlendComponent component = GPUBlendComponent(
      srcFactor: webGpuBlendFactorName(blend.source),
      dstFactor: webGpuBlendFactorName(blend.destination),
      operation: 'add',
    );
    _pipelines[key] =
        _device.createRenderPipeline(GPURenderPipelineDescriptor(
      layout: _pipelineLayout!,
      vertex: GPUVertexState(
        module: module,
        entryPoint: kWgslSparseVertexEntryPoint,
        buffers: <GPUVertexBufferLayout>[
          GPUVertexBufferLayout(
            arrayStride: kWebGpuSparseInstanceStrideBytes,
            // The whole point: one record per quad, four vertices per record.
            stepMode: 'instance',
            attributes: <GPUVertexAttribute>[
              GPUVertexAttribute(
                format: 'float32x4',
                offset: kWebGpuSparseQuadRectOffsetBytes,
                shaderLocation: kWebGpuSparseQuadRectLocation,
              ),
              GPUVertexAttribute(
                format: 'float32x2',
                offset: kWebGpuSparseAtlasOriginOffsetBytes,
                shaderLocation: kWebGpuSparseAtlasOriginLocation,
              ),
            ].toJS,
          ),
        ].toJS,
      ),
      fragment: GPUFragmentState(
        module: module,
        entryPoint: wgslSparseFragmentEntryPoint(
          coverageMode: coverageMode,
          paintMode: paintMode,
        ),
        targets: <GPUColorTargetState>[
          GPUColorTargetState(
            format: _targetFormat,
            blend: GPUBlendStateDict(color: component, alpha: component),
          ),
        ].toJS,
      ),
      primitive: GPUPrimitiveState(topology: 'triangle-strip'),
    ));
    return key;
  }

  @override
  int acquireBindGroup({
    required int alphaTexture,
    required int gradientLut,
  }) {
    final int key = _bindGroupKey(alphaTexture, gradientLut);
    if (_bindGroups.containsKey(key)) return key;
    final GPUTextureView alphaView = alphaTexture == kNoTexture
        ? _dummyAlphaView!
        : _page(alphaTexture).view;
    // A LUT whose id no longer resolves is a caller bug on every backend; the
    // stand-in draws unmodulated white rather than failing validation and
    // taking the whole pass with it, which is what `_bindGroupFor` does on the
    // dense path for the same case.
    final GPUTextureView lutView = gradientLut == kNoTexture
        ? _dummyLutView!
        : (_sampledTextures.lookup(gradientLut)?.view ?? _dummyLutView!);
    _bindGroups[key] = _device.createBindGroup(GPUBindGroupDescriptor(
      layout: _textureLayout!,
      entries: <GPUBindGroupEntry>[
        GPUBindGroupEntry(binding: 0, resource: alphaView),
        GPUBindGroupEntry(binding: 1, resource: lutView),
        GPUBindGroupEntry(binding: 2, resource: _lutSampler!),
      ].toJS,
    ));
    return key;
  }

  @override
  void beginSparsePass({
    required int instanceBuffer,
    required int uniformBuffer,
    required int viewportWidth,
    required int viewportHeight,
  }) {
    final GPUTextureView? target = _stagedTarget;
    if (target == null) {
      throw StateError(
        'no sparse WebGPU target was staged; the device seam must call '
        'stageTarget before submitting a plan',
      );
    }
    if (_pass != null) {
      throw StateError('a sparse WebGPU pass is already open');
    }
    final int? clear = _stagedClearColor;
    final ({double r, double g, double b, double a})? clearValue =
        clear == null ? null : webGpuClearValue(clear);
    final GPUCommandEncoder encoder = _device.createCommandEncoder();
    final GPURenderPassEncoder pass =
        encoder.beginRenderPass(GPURenderPassDescriptor(
      colorAttachments: <GPURenderPassColorAttachment>[
        clearValue == null
            ? GPURenderPassColorAttachment(
                view: target,
                loadOp: 'load',
                storeOp: 'store',
              )
            : GPURenderPassColorAttachment(
                view: target,
                loadOp: 'clear',
                storeOp: 'store',
                clearValue: GPUColorDict(
                  r: clearValue.r,
                  g: clearValue.g,
                  b: clearValue.b,
                  a: clearValue.a,
                ),
              ),
      ].toJS,
    ));
    pass
      ..setViewport(0, 0, viewportWidth, viewportHeight, 0, 1)
      ..setVertexBuffer(0, _buffer(instanceBuffer));
    _encoder = encoder;
    _pass = pass;
    _currentUniformBuffer = uniformBuffer;
  }

  @override
  void setPipeline(int pipeline) {
    final GPURenderPipeline? object = _pipelines[pipeline];
    if (object == null) {
      throw StateError('unknown sparse WebGPU pipeline $pipeline');
    }
    _requirePass().setPipeline(object);
  }

  @override
  void setDrawState({
    required int bindGroup,
    required int uniformSliceOffsetBytes,
  }) {
    final GPUBindGroup? group = _bindGroups[bindGroup];
    if (group == null) {
      throw StateError('unknown sparse WebGPU bind group $bindGroup');
    }
    _requirePass()
      ..setBindGroup(
        0,
        _frameBindGroup(_currentUniformBuffer),
        <JSNumber>[uniformSliceOffsetBytes.toJS].toJS,
      )
      ..setBindGroup(1, group);
  }

  @override
  void draw({
    required int vertexCount,
    required int instanceCount,
    required int firstInstance,
  }) =>
      _requirePass().draw(vertexCount, instanceCount, 0, firstInstance);

  @override
  void endSparsePass() {
    final GPURenderPassEncoder? pass = _pass;
    final GPUCommandEncoder? encoder = _encoder;
    _pass = null;
    _encoder = null;
    _currentUniformBuffer = 0;
    if (pass == null || encoder == null) return;
    pass.end();
    _device.queue.submit(<GPUCommandBuffer>[encoder.finish()].toJS);
  }

  @override
  void discardNativeResources() {
    // Device loss already reclaimed every object. Nothing is destroyed here,
    // which on WebGPU is a bookkeeping decision rather than a safety one:
    // destroy() is defined on a lost device, but the handles must not outlive
    // the device that made them or a later frame binds a buffer that can never
    // be written again.
    _buffers.clear();
    _pages.clear();
    _pass = null;
    _encoder = null;
    _stagedTarget = null;
    _stagedClearColor = null;
    _currentUniformBuffer = 0;
    _forgetModule();
  }

  /// Releases the objects this driver owns after the device has finished.
  void disposeResources() {
    for (final GPUBuffer buffer in _buffers.values) {
      buffer.destroy();
    }
    for (final _SparseAlphaPage page in _pages.values) {
      page.texture.destroy();
    }
    _buffers.clear();
    _pages.clear();
    destroySparseModule();
  }

  void _forgetModule() {
    _module = null;
    _uniformLayout = null;
    _textureLayout = null;
    _pipelineLayout = null;
    _lutSampler = null;
    _dummyAlpha = null;
    _dummyLut = null;
    _dummyAlphaView = null;
    _dummyLutView = null;
    _pipelines.clear();
    _bindGroups.clear();
    _frameBindGroups.clear();
  }

  GPUBindGroup _frameBindGroup(int buffer) {
    final GPUBindGroup? cached = _frameBindGroups[buffer];
    if (cached != null) return cached;
    final GPUBindGroup group =
        _device.createBindGroup(GPUBindGroupDescriptor(
      layout: _uniformLayout!,
      entries: <GPUBindGroupEntry>[
        GPUBindGroupEntry(
          binding: 0,
          resource: GPUBufferBinding(
            buffer: _buffer(buffer),
            offset: 0,
            size: kWebGpuSparseUniformSliceSize,
          ),
        ),
      ].toJS,
    ));
    _frameBindGroups[buffer] = group;
    return group;
  }

  int _registerBuffer(GPUBuffer buffer) {
    final int handle = _nextHandle++;
    _buffers[handle] = buffer;
    return handle;
  }

  GPUBuffer _buffer(int handle) {
    final GPUBuffer? object = _buffers[handle];
    if (object == null) {
      throw StateError('unknown sparse WebGPU buffer $handle');
    }
    return object;
  }

  _SparseAlphaPage _page(int handle) {
    final _SparseAlphaPage? page = _pages[handle];
    if (page == null) {
      throw StateError('unknown sparse WebGPU alpha page $handle');
    }
    return page;
  }

  GPURenderPassEncoder _requirePass() {
    final GPURenderPassEncoder? pass = _pass;
    if (pass == null) {
      throw StateError('no sparse WebGPU pass is open');
    }
    return pass;
  }

  Uint8List _ensureAlphaStaging(int bytes) {
    if (bytes <= _alphaStaging.length) return _alphaStaging;
    return _alphaStaging = Uint8List(bytes);
  }
}
