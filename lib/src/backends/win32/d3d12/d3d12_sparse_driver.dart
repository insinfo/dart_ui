/// Production Direct3D 12 adapter for the opt-in sparse-strip executor.
///
/// The counterpart of `gl_sparse_driver.dart`: it maps the narrow, fakeable
/// [SparseD3d12Driver] contract onto a real root signature, three pipeline
/// state objects and the device's open command list.
///
/// ## What this object owns, and what it borrows
///
/// **Owns:** the sparse root signature, one pipeline state object per blend
/// mode, the two shader blobs and its own per-frame scratch. Keeping that
/// inventory separate from the dense renderer's is what makes the feature
/// genuinely opt-in rather than another branch inside every dense draw.
///
/// **Borrows, and must not duplicate:** the command list, the frame ring's
/// upload arena, the shader-visible descriptor heap and the textures in it.
/// `SetDescriptorHeaps` may name one CBV/SRV/UAV heap at a time, so an executor
/// that brought its own would unbind the mask and glyph atlases the dense path
/// is about to sample.
///
/// ## The instance data lives in the frame's upload arena
///
/// There is no long-lived vertex buffer. Instances are read exactly once, by
/// the draws recorded in the same command list that reads them, and the frame
/// ring already owns a lifetime that ends when the fence releases that list.
/// A retained default-heap buffer would be a second lifetime to keep in step
/// with the first, in exchange for accelerating a read that happens once.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../../../foundation/diagnostics.dart';
import '../../../graphics/display_list_opcodes.dart';
import '../../../rendering/gpu/d3d12/d3d12_sparse_executor.dart';
import '../../../rendering/gpu/d3d12/d3d12_sparse_strips.dart';
import '../../../rendering/gpu/gpu_gradient.dart';
import '../../../rendering/gpu/gpu_pipeline.dart';
import '../../../rendering/gpu/gpu_texture.dart';
import 'd3d12_arena.dart';
import 'd3d12_com.dart';
import 'd3d12_device.dart';
import 'd3d12_frame_ring.dart';
import 'd3d12_interfaces.dart';
import 'd3d12_library.dart';
import 'd3d12_structs.dart';

/// The token [createSparsePipeline] returns. One, because there is exactly one
/// sparse pipeline per device; the integer exists so the executor can tell
/// "built" from "not built" without holding a native pointer.
const int _kSparsePipelineToken = 1;

/// Maps the sparse contract onto a [D3d12RenderDevice].
final class D3d12SparseDriver implements SparseD3d12Driver {
  D3d12SparseDriver(this._device);

  final D3d12RenderDevice _device;

  Pointer<Void> _rootSignature = nullptr;
  final Map<int, Pointer<Void>> _pipelines = <int, Pointer<Void>>{};
  D3dBlob? _vertexBlob;
  D3dBlob? _pixelBlob;

  /// Alpha pages by descriptor index, so [deleteTexture] can hand the device
  /// back the handle it issued rather than an integer it would have to search
  /// for.
  final Map<int, D3d12Texture> _pages = <int, D3d12Texture>{};

  bool _disposed = false;
  bool _inPass = false;
  int _boundBlendKey = -1;

  // Per-pass scratch, allocated once. A frame performs no native allocation.
  late final Pointer<Uint32> _rootConstants = _device.library.allocator
      .allocate<Uint32>(4 * kD3d12SparseRootConstantCount);
  late final Pointer<D3d12Viewport> _viewport = _device.library.allocator
      .allocate<D3d12Viewport>(sizeOf<D3d12Viewport>());
  late final Pointer<D3d12Rect> _scissor =
      _device.library.allocator.allocate<D3d12Rect>(sizeOf<D3d12Rect>());
  late final Pointer<D3d12VertexBufferView> _vertexView = _device
      .library.allocator
      .allocate<D3d12VertexBufferView>(sizeOf<D3d12VertexBufferView>());
  late final Pointer<Pointer<Void>> _heapSlot = _device.library.allocator
      .allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());

  bool get isBuilt => _rootSignature != nullptr;

  @override
  int createSparsePipeline() {
    _throwIfDisposed();
    if (isBuilt) return _kSparsePipelineToken;
    return D3d12Arena.using(_device.library.allocator, (D3d12Arena arena) {
      final BackendDiagnostic? rootFailure = _createRootSignature(arena);
      if (rootFailure != null) {
        throw StateError('$rootFailure');
      }
      final Object vertex = _device.compileShader(
        arena,
        kD3d12SparseVertexShader,
        kD3d12SparseVertexEntryPoint,
        kD3d12SparseVertexTarget,
      );
      if (vertex is BackendDiagnostic) {
        _releaseRootSignature();
        throw StateError('$vertex');
      }
      final Object pixel = _device.compileShader(
        arena,
        kD3d12SparsePixelShader,
        kD3d12SparsePixelEntryPoint,
        kD3d12SparsePixelTarget,
      );
      if (pixel is BackendDiagnostic) {
        (vertex as D3dBlob).release();
        _releaseRootSignature();
        throw StateError('$pixel');
      }
      _vertexBlob = vertex as D3dBlob;
      _pixelBlob = pixel as D3dBlob;

      // One pipeline state object per blend mode, built up front. Direct3D 12
      // has no dynamic blend state, and building one mid-frame would stall on a
      // driver compile at the worst possible moment.
      for (final int mode in <int>[
        blendModeSrcOver,
        blendModeSrc,
        blendModePlus,
      ]) {
        final GpuBlendState blend = gpuBlendForMode(mode);
        final Object pso = _createPipelineState(arena, blend);
        if (pso is BackendDiagnostic) {
          _releaseNativeObjects();
          throw StateError('$pso');
        }
        _pipelines[_blendKey(blend)] = pso as Pointer<Void>;
      }
      return _kSparsePipelineToken;
    });
  }

  @override
  void disposeSparsePipeline(int pipeline) {
    if (pipeline != _kSparsePipelineToken) return;
    _releaseNativeObjects();
  }

  @override
  int createAlpha8Texture({required int width, required int height}) {
    _throwIfDisposed();
    final D3d12Texture texture = _device.createTexture(
      width: width,
      height: height,
      format: GpuTextureFormat.alpha8,
      // One texel per coverage byte by construction, and the pixel shader
      // reads it with an integer Load, so the filter is never consulted. It is
      // still declared nearest so that a future sampled read cannot silently
      // blur coverage the CPU rasteriser produced exactly.
      filter: GpuTextureFilter.nearest,
    );
    _pages[texture.id] = texture;
    return texture.id;
  }

  @override
  void deleteTexture(int texture) {
    final D3d12Texture? page = _pages.remove(texture);
    if (page != null) _device.releaseTexture(page);
  }

  @override
  void uploadInstances(Float32List instances) {
    _throwIfDisposed();
    final int bytes = instances.lengthInBytes;
    if (bytes == 0) {
      _vertexView.ref
        ..bufferLocation = 0
        ..sizeInBytes = 0
        ..strideInBytes = kD3d12SparseInstanceStrideBytes;
      return;
    }
    final D3d12UploadRange? range =
        _device.frames.reserveUpload(bytes, alignment: 256);
    if (range == null) {
      throw StateError(
        'the sparse instance array did not fit in an upload buffer '
        '($bytes bytes)',
      );
    }
    range.cpu
        .cast<Float>()
        .asTypedList(instances.length)
        .setRange(0, instances.length, instances);
    _vertexView.ref
      ..bufferLocation = range.gpuAddress
      ..sizeInBytes = bytes
      ..strideInBytes = kD3d12SparseInstanceStrideBytes;
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
    final D3d12Texture? page = _pages[texture];
    if (page == null) {
      throw StateError('alpha page $texture does not belong to this driver');
    }
    _device.uploadRegion(
      page,
      x: x,
      y: y,
      width: width,
      height: height,
      pixels: Uint8List.sublistView(pixels, sourceOffset),
      bytesPerRow: sourceBytesPerRow,
    );
  }

  @override
  void beginSparsePass({
    required int pipeline,
    required int viewportWidth,
    required int viewportHeight,
  }) {
    _throwIfDisposed();
    if (pipeline != _kSparsePipelineToken || !isBuilt) {
      throw StateError('the sparse pipeline does not belong to this driver');
    }
    if (!_device.frames.isRecording) {
      throw StateError('no Direct3D 12 command list is open for a sparse pass');
    }
    // The alpha pages were written through the copy queue path and are still
    // in COPY_DEST; the gradient ramp may be too. One bulk transition, before
    // the draws, for the reason the device gives: a barrier per draw is what
    // makes a naive Direct3D 12 port slower than the Direct3D 11 it replaced.
    _device.prepareTexturesForSampling();

    final D3d12GraphicsCommandList list = _device.frames.list;
    _viewport.ref
      ..topLeftX = 0
      ..topLeftY = 0
      ..width = viewportWidth.toDouble()
      ..height = viewportHeight.toDouble()
      ..minDepth = 0
      ..maxDepth = 1;
    // A full-surface scissor, explicitly. The dense pass sets one per batch and
    // Direct3D 12 keeps it on the command list, so a sparse pass that did not
    // reset it would be clipped by whatever the last dense batch happened to
    // want - a bug that only appears in a frame containing both.
    _scissor.ref
      ..left = 0
      ..top = 0
      ..right = viewportWidth
      ..bottom = viewportHeight;
    _heapSlot.value = _device.shaderVisibleHeap;

    list
      ..setGraphicsRootSignature(list.pointer, _rootSignature)
      ..setDescriptorHeaps(list.pointer, 1, _heapSlot)
      ..rsSetViewports(list.pointer, 1, _viewport)
      ..rsSetScissorRects(list.pointer, 1, _scissor)
      ..iaSetPrimitiveTopology(list.pointer, d3dPrimitiveTopologyTriangleStrip)
      ..iaSetVertexBuffers(list.pointer, 0, 1, _vertexView);

    // Both descriptor tables are declared by the root signature, so both must
    // name a real descriptor even in a solid, non-gradient draw. Descriptor
    // zero is the device's 1x1 placeholder; an unset table is exactly the
    // "uninitialised descriptor" the debug layer reports.
    final int placeholder = _device.gpuDescriptorHandleFor(0);
    list
      ..setGraphicsRootDescriptorTable(
          list.pointer, kD3d12SparseRootAlphaAtlasSlot, placeholder)
      ..setGraphicsRootDescriptorTable(
          list.pointer, kD3d12SparseRootGradientLutSlot, placeholder);

    for (var i = 0; i < kD3d12SparseRootConstantCount; i++) {
      _rootConstants[i] = 0;
    }
    final Pointer<Float> floats = _rootConstants.cast<Float>();
    floats[D3d12SparseRootConstant.viewport] = viewportWidth.toDouble();
    floats[D3d12SparseRootConstant.viewport + 1] = viewportHeight.toDouble();
    _boundBlendKey = -1;
    _inPass = true;
  }

  @override
  void setBlendState(GpuBlendState blend) {
    _requirePass();
    final int key = _blendKey(blend);
    if (key == _boundBlendKey) return;
    final Pointer<Void>? pso = _pipelines[key];
    if (pso == null) {
      throw StateError(
        'no sparse pipeline state for blend factors ${blend.source.name} / '
        '${blend.destination.name}; a factor pair added to gpu_pipeline.dart '
        'needs one built in D3d12SparseDriver.createSparsePipeline',
      );
    }
    _boundBlendKey = key;
    _device.frames.list.setPipelineState(_device.frames.list.pointer, pso);
  }

  @override
  void setPremultipliedColor(
    double red,
    double green,
    double blue,
    double alpha,
  ) {
    _requirePass();
    final Pointer<Float> floats = _rootConstants.cast<Float>();
    floats[D3d12SparseRootConstant.color] = red;
    floats[D3d12SparseRootConstant.color + 1] = green;
    floats[D3d12SparseRootConstant.color + 2] = blue;
    floats[D3d12SparseRootConstant.color + 3] = alpha;
  }

  @override
  void useSolidPaint() {
    _requirePass();
    _rootConstants[D3d12SparseRootConstant.paintMode] = kD3d12SparsePaintSolid;
  }

  @override
  void useGradientPaint(
    GpuGradientBinding binding,
    GpuGradientShaderParameters parameters,
  ) {
    _requirePass();
    final Float32List scalars = parameters.scalars;
    const int transform = GpuGradientUniformOffset.targetToLocal;
    const int geometry = GpuGradientUniformOffset.geometry;
    final Pointer<Float> floats = _rootConstants.cast<Float>();

    _rootConstants[D3d12SparseRootConstant.paintMode] =
        kD3d12SparsePaintGradient;
    _rootConstants[D3d12SparseRootConstant.gradientKind] =
        scalars[GpuGradientUniformOffset.kind].toInt();
    _rootConstants[D3d12SparseRootConstant.gradientSpread] =
        binding.spread.index;
    floats[D3d12SparseRootConstant.gradientLookup] = binding.lookupScale;
    floats[D3d12SparseRootConstant.gradientLookup + 1] = binding.lookupBias;

    // The same packing the GL adapter uses: row 0 of the target-to-local
    // affine transform in the first float4, row 1 in the second, with the
    // translation in `.z` so the shader's dot product against (x, y, 1) is the
    // whole mapping.
    floats[D3d12SparseRootConstant.targetToLocal0] = scalars[transform];
    floats[D3d12SparseRootConstant.targetToLocal0 + 1] = scalars[transform + 2];
    floats[D3d12SparseRootConstant.targetToLocal0 + 2] = scalars[transform + 4];
    floats[D3d12SparseRootConstant.targetToLocal0 + 3] = 0;
    floats[D3d12SparseRootConstant.targetToLocal1] = scalars[transform + 1];
    floats[D3d12SparseRootConstant.targetToLocal1 + 1] = scalars[transform + 3];
    floats[D3d12SparseRootConstant.targetToLocal1 + 2] = scalars[transform + 5];
    floats[D3d12SparseRootConstant.targetToLocal1 + 3] = 0;
    for (var i = 0; i < 4; i++) {
      floats[D3d12SparseRootConstant.gradientGeometry0 + i] =
          scalars[geometry + i];
      floats[D3d12SparseRootConstant.gradientGeometry1 + i] =
          scalars[geometry + 4 + i];
    }

    final D3d12GraphicsCommandList list = _device.frames.list;
    list.setGraphicsRootDescriptorTable(
      list.pointer,
      kD3d12SparseRootGradientLutSlot,
      _device.gpuDescriptorHandleFor(binding.texture.id),
    );
  }

  @override
  void setSparseMode(int mode) {
    _requirePass();
    _rootConstants[D3d12SparseRootConstant.mode] = mode;
  }

  @override
  void bindAlpha8Texture(int texture) {
    _requirePass();
    final D3d12GraphicsCommandList list = _device.frames.list;
    list.setGraphicsRootDescriptorTable(
      list.pointer,
      kD3d12SparseRootAlphaAtlasSlot,
      _device.gpuDescriptorHandleFor(texture),
    );
  }

  @override
  void drawTriangleStripInstanced({
    required int vertexCount,
    required int instanceCount,
    required int firstInstance,
  }) {
    _requirePass();
    if (instanceCount <= 0) return;
    final D3d12GraphicsCommandList list = _device.frames.list;
    // Root constants are per-draw state in Direct3D 12 rather than a program
    // uniform. Re-sending the whole block costs less than tracking which half
    // of it the previous draw left alone would.
    list
      ..setGraphicsRoot32BitConstants(
        list.pointer,
        kD3d12SparseRootConstantsSlot,
        kD3d12SparseRootConstantCount,
        _rootConstants.cast<Void>(),
        0,
      )
      ..drawInstanced(
        list.pointer,
        vertexCount,
        instanceCount,
        0,
        firstInstance,
      );
  }

  @override
  void endSparsePass() {
    _inPass = false;
    _boundBlendKey = -1;
  }

  @override
  void discardNativeResources() {
    // Device removal already destroyed these. Never send a release through a
    // removed device: the pointer may have been recycled for new state.
    _rootSignature = nullptr;
    _pipelines.clear();
    _vertexBlob = null;
    _pixelBlob = null;
    _pages.clear();
    _inPass = false;
    _boundBlendKey = -1;
  }

  /// Releases the native objects and then the host-side scratch.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _releaseNativeObjects();
    _device.library.allocator
      ..free(_rootConstants)
      ..free(_viewport)
      ..free(_scissor)
      ..free(_vertexView)
      ..free(_heapSlot);
  }

  /// Disposes after device removal, where releasing an object is undefined.
  void disposeAfterDeviceLoss() {
    if (_disposed) return;
    discardNativeResources();
    dispose();
  }

  // -------------------------------------------------------------------
  // Creation
  // -------------------------------------------------------------------

  BackendDiagnostic? _createRootSignature(D3d12Arena arena) {
    final Pointer<D3d12DescriptorRange> ranges =
        arena<D3d12DescriptorRange>(sizeOf<D3d12DescriptorRange>() * 2);
    for (var i = 0; i < 2; i++) {
      ranges[i]
        ..rangeType = d3d12DescriptorRangeTypeSrv
        ..numDescriptors = 1
        ..baseShaderRegister = i
        ..registerSpace = 0
        ..offsetInDescriptorsFromTableStart = 0;
    }

    final Pointer<D3d12RootParameter> parameters = arena<D3d12RootParameter>(
        sizeOf<D3d12RootParameter>() * kD3d12SparseRootParameterCount);
    parameters[kD3d12SparseRootConstantsSlot]
      ..parameterType = d3d12RootParameterTypeConstants
      ..field8 = 0 // ShaderRegister: b0
      ..fieldC = 0 // RegisterSpace
      ..field10 = kD3d12SparseRootConstantCount // Num32BitValues
      ..shaderVisibility = d3d12ShaderVisibilityAll;
    parameters[kD3d12SparseRootAlphaAtlasSlot]
      ..parameterType = d3d12RootParameterTypeDescriptorTable
      ..field8 = 1 // NumDescriptorRanges
      ..field10 = ranges.address // pDescriptorRanges -> t0
      ..shaderVisibility = d3d12ShaderVisibilityPixel;
    parameters[kD3d12SparseRootGradientLutSlot]
      ..parameterType = d3d12RootParameterTypeDescriptorTable
      ..field8 = 1
      ..field10 = (ranges + 1).address // -> t1
      ..shaderVisibility = d3d12ShaderVisibilityPixel;

    final Pointer<D3d12StaticSamplerDesc> sampler =
        arena<D3d12StaticSamplerDesc>(sizeOf<D3d12StaticSamplerDesc>());
    // One sampler, linear and clamped, and it is only ever used on the
    // gradient ramp: the alpha page is read with an integer Load, exactly as
    // the GL shader uses texelFetch, so no filter can round a coverage byte.
    sampler.ref
      ..filter = d3d12FilterMinMagMipLinear
      ..addressU = d3d12TextureAddressModeClamp
      ..addressV = d3d12TextureAddressModeClamp
      ..addressW = d3d12TextureAddressModeClamp
      ..mipLodBias = 0
      ..maxAnisotropy = 1
      ..comparisonFunc = d3d12ComparisonFuncAlways
      ..borderColor = d3d12StaticBorderColorTransparentBlack
      ..minLod = 0
      ..maxLod = 0
      ..shaderRegister = 0
      ..registerSpace = 0
      ..shaderVisibility = d3d12ShaderVisibilityPixel;

    final Pointer<D3d12RootSignatureDesc> desc =
        arena<D3d12RootSignatureDesc>(sizeOf<D3d12RootSignatureDesc>());
    desc.ref
      ..numParameters = kD3d12SparseRootParameterCount
      ..parameters = parameters
      ..numStaticSamplers = 1
      ..staticSamplers = sampler
      ..flags = d3d12RootSignatureFlagAllowInputAssemblerInputLayout;

    final Pointer<Pointer<Void>> blobOut = arena.allocatePointers(1);
    final Pointer<Pointer<Void>> errorOut = arena.allocatePointers(1);
    final int hr = _device.library.serializeRootSignature(
      desc.cast<Void>(),
      d3dRootSignatureVersion10,
      blobOut,
      errorOut,
    );
    if (comFailed(hr)) {
      final String detail = errorOut.value == nullptr
          ? hresultText(hr)
          : '${hresultText(hr)}: ${D3dBlob(errorOut.value).text}';
      if (errorOut.value != nullptr) ComObject(errorOut.value).release();
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the sparse root signature could not be serialised',
        detail: detail,
      );
    }
    final D3dBlob blob = D3dBlob(blobOut.value);
    final Pointer<Guid> iid = arena<Guid>(sizeOf<Guid>());
    writeGuid(iid, D3d12Iids.rootSignature);
    final Pointer<Pointer<Void>> out = arena.allocatePointers(1);
    final int createHr = _device.nativeDevice.createRootSignature(
      _device.nativeDevice.pointer,
      0,
      blob.data,
      blob.length,
      iid,
      out,
    );
    blob.release();
    if (comFailed(createHr)) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'CreateRootSignature refused the sparse layout',
        detail: hresultText(createHr),
      );
    }
    _rootSignature = out.value;
    return null;
  }

  /// Returns a `Pointer<Void>` on success, a [BackendDiagnostic] on failure.
  Object _createPipelineState(D3d12Arena arena, GpuBlendState blend) {
    final int source = _blendFactor(blend.source);
    final int destination = _blendFactor(blend.destination);

    final Pointer<D3d12InputElementDesc> elements =
        arena<D3d12InputElementDesc>(sizeOf<D3d12InputElementDesc>() * 2);
    for (var i = 0; i < kD3d12SparseInputElements.length; i++) {
      final D3d12SparseInputElement element = kD3d12SparseInputElements[i];
      elements[i]
        ..semanticName = arena.allocateAscii(element.semanticName)
        ..semanticIndex = element.semanticIndex
        ..format = element.components == 4
            ? dxgiFormatR32G32B32A32Float
            : dxgiFormatR32G32Float
        ..inputSlot = 0
        ..alignedByteOffset = element.offsetBytes
        ..inputSlotClass = d3d12InputPerInstanceData
        ..instanceDataStepRate = element.instanceDataStepRate;
    }

    final Pointer<D3d12GraphicsPipelineStateDesc> desc =
        arena<D3d12GraphicsPipelineStateDesc>(
            sizeOf<D3d12GraphicsPipelineStateDesc>());
    desc.ref
      ..rootSignature = _rootSignature
      ..sampleMask = 0xFFFFFFFF
      ..ibStripCutValue = d3d12IndexBufferStripCutDisabled
      ..primitiveTopologyType = d3d12PrimitiveTopologyTypeTriangle
      ..numRenderTargets = 1
      ..dsvFormat = dxgiFormatUnknown
      ..nodeMask = 0
      ..flags = d3d12PipelineStateFlagNone;
    desc.ref.vs
      ..shaderBytecode = _vertexBlob!.data
      ..bytecodeLength = _vertexBlob!.length;
    desc.ref.ps
      ..shaderBytecode = _pixelBlob!.data
      ..bytecodeLength = _pixelBlob!.length;
    desc.ref.rtvFormats[0] = kD3d12SurfaceFormat;
    desc.ref.sampleDesc
      ..count = 1
      ..quality = 0;
    desc.ref.inputLayout
      ..inputElementDescs = elements
      ..numElements = kD3d12SparseInputElements.length;
    desc.ref.blendState
      ..alphaToCoverageEnable = 0
      ..independentBlendEnable = 0;
    desc.ref.blendState.renderTarget[0]
      ..blendEnable = 1
      ..logicOpEnable = 0
      ..srcBlend = source
      ..destBlend = destination
      // One pair of factors for colour and alpha alike, exactly as
      // `glBlendFunc` applies one pair to both. A separate alpha equation here
      // would make this executor composite differently from the GL one on the
      // first translucent surface.
      ..srcBlendAlpha = source
      ..destBlendAlpha = destination
      ..blendOp = d3d12BlendOpAdd
      ..blendOpAlpha = d3d12BlendOpAdd
      ..logicOp = d3d12LogicOpNoop
      ..renderTargetWriteMask = d3d12ColorWriteEnableAll;
    desc.ref.rasterizerState
      ..fillMode = d3d12FillModeSolid
      ..cullMode = d3d12CullModeNone
      ..frontCounterClockwise = 0
      ..depthBias = 0
      ..depthBiasClamp = 0
      ..slopeScaledDepthBias = 0
      ..depthClipEnable = 1
      ..multisampleEnable = 0
      ..antialiasedLineEnable = 0
      ..forcedSampleCount = 0
      ..conservativeRaster = d3d12ConservativeRasterOff;
    desc.ref.depthStencilState
      ..depthEnable = 0
      ..depthWriteMask = d3d12DepthWriteMaskZero
      ..depthFunc = d3d12ComparisonFuncAlways
      ..stencilEnable = 0
      ..stencilReadMask = 0
      ..stencilWriteMask = 0;
    for (final D3d12DepthStencilOpDesc face in <D3d12DepthStencilOpDesc>[
      desc.ref.depthStencilState.frontFace,
      desc.ref.depthStencilState.backFace,
    ]) {
      face
        ..stencilFailOp = d3d12StencilOpKeep
        ..stencilDepthFailOp = d3d12StencilOpKeep
        ..stencilPassOp = d3d12StencilOpKeep
        ..stencilFunc = d3d12ComparisonFuncAlways;
    }

    final Pointer<Guid> iid = arena<Guid>(sizeOf<Guid>());
    writeGuid(iid, D3d12Iids.pipelineState);
    final Pointer<Pointer<Void>> out = arena.allocatePointers(1);
    final int hr = _device.nativeDevice.createGraphicsPipelineState(
      _device.nativeDevice.pointer,
      desc,
      iid,
      out,
    );
    if (comFailed(hr)) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the sparse pipeline state for ${blend.source.name} / '
            '${blend.destination.name} was refused',
        detail: hresultText(hr),
      );
    }
    return out.value;
  }

  void _releaseRootSignature() {
    if (_rootSignature == nullptr) return;
    releaseCom(_rootSignature);
    _rootSignature = nullptr;
  }

  void _releaseNativeObjects() {
    for (final Pointer<Void> pso in _pipelines.values) {
      ComObject(pso).release();
    }
    _pipelines.clear();
    _releaseRootSignature();
    _vertexBlob?.release();
    _pixelBlob?.release();
    _vertexBlob = null;
    _pixelBlob = null;
    for (final D3d12Texture page in _pages.values.toList()) {
      _device.releaseTexture(page);
    }
    _pages.clear();
  }

  static int _blendKey(GpuBlendState blend) =>
      (blend.source.index << 4) | blend.destination.index;

  static int _blendFactor(GpuBlendFactor factor) => switch (factor) {
        GpuBlendFactor.zero => d3d12BlendZero,
        GpuBlendFactor.one => d3d12BlendOne,
        GpuBlendFactor.oneMinusSrcAlpha => d3d12BlendInvSrcAlpha,
      };

  void _requirePass() {
    if (!_inPass) throw StateError('no sparse Direct3D 12 pass is open');
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('the sparse Direct3D 12 driver is disposed');
    }
  }
}
