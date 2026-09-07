/// The Direct3D 12 mesh pipeline: triangles, a depth buffer and two shaders.
///
/// `rendering/mesh/mesh_scene.dart` holds the contract and
/// `rendering/gpu/d3d11/d3d11_mesh_pipeline.dart` is the implementation this
/// one is shaped after, deliberately: the same caches, the same two pieces of
/// state that have to agree with the CPU rasteriser, the same
/// [MeshRenderStats]. Its library comment argues the winding and the depth
/// test at length and that argument is *not* repeated here, because it is the
/// same argument - `MeshRasterizer._drawProjected` calls a positive
/// screen-space signed area back-facing, y points down, so a counter-clockwise
/// triangle in render-target space is the front face and `LESS` against a
/// buffer cleared to 1 is the CPU's `<` against a buffer cleared to infinity.
///
/// What follows is only what Direct3D 12 makes different, and every one of
/// them is a way this file could be wrong while the Direct3D 11 one is right.
///
/// ## 1. There is no immediate context, so a draw needs an open command list
///
/// Direct3D 11's `drawScene` submits the moment it is called. Here the draws
/// are *recorded*, and the list they are recorded onto belongs to
/// [D3d12FrameRing]. So [drawScene] records into the list the target already
/// opened in `beginFrame` when there is one, and opens and closes a list of
/// its own when there is not - which is what makes a bare
/// `renderer.drawScene(target, scene)` outside a frame still draw something
/// rather than silently do nothing. `MeshRenderStats.microseconds` is
/// therefore **recording** time and not submission time; the zeros
/// `gpuMeshStats` writes already say a GPU frame and a CPU frame are two
/// different measurements, and this is the third.
///
/// ## 2. The back buffer is in `PRESENT` state when a mesh frame reaches it
///
/// `D3d12WindowTarget.present` records `PRESENT` -> `RENDER_TARGET`, the
/// draws, and `RENDER_TARGET` -> `PRESENT`. A mesh pass runs *before* that
/// pair, while the buffer is still in `PRESENT`, so this file records its own
/// pair around its own draws and leaves the buffer exactly as it found it.
/// Getting that wrong is not a crash and not a wrong picture on this machine:
/// it is a barrier whose `before` state does not match, which is undefined
/// behaviour that one driver tolerates and the next corrupts, and which only
/// the debug layer reports. The offscreen target needs none of it - its colour
/// texture is created `renderTarget: true` and never leaves `RENDER_TARGET`.
///
/// ## 3. The depth state is baked into the pipeline state object
///
/// Direct3D 11 has an `ID3D11DepthStencilState` that a frame binds and
/// unbinds. Direct3D 12 has neither: depth enable, the comparison, the cull
/// mode, the fill mode and the winding are all fields of
/// `D3D12_GRAPHICS_PIPELINE_STATE_DESC`. So the cross product of them is a
/// cross product of *objects*, built lazily and keyed by [_pipelineKey], and
/// the "leave the depth test off on the way out" that the Direct3D 11 file
/// ends with has no counterpart - there is nothing bound to leave behind.
/// What does have to be undone is the **depth-stencil view**: a 2D pass that
/// inherited it would depth-test every batch against the plane the model
/// wrote, so [drawInto] rebinds the render target alone before it returns.
/// `D3d12RenderDevice.submit` binds its own, which makes that belt and braces
/// - and the belt is what the window probe is there to check.
///
/// ## 4. The constants ride in the command list
///
/// Forty dwords of root constants and no constant buffer at all: a root
/// signature holds 64 dwords, the ten `float4` registers of the mesh program
/// are forty of them and the texture table is one more. That removes an
/// `ID3D12Resource`, its upload block and the question of when the GPU has
/// finished reading last frame's copy of it. See [kD3d12MeshRootConstantCount].
///
/// ## 5. An immutable buffer has to be copied into, not created full
///
/// Direct3D 11 creates a `D3D11_USAGE_IMMUTABLE` buffer with its data in one
/// call. Direct3D 12 has no such thing: a `DEFAULT`-heap buffer is written by
/// a `CopyBufferRegion` from an `UPLOAD`-heap one, on a command list, and the
/// upload buffer must stay alive until the **GPU** has finished with it. So
/// [_retired] holds each staging buffer with the fence value that releases it
/// and [_sweepRetired] frees them at the top of the next frame. Releasing one
/// straight after the `CopyBufferRegion` call would free memory a command list
/// still in flight is reading, and the symptom is a model with holes in it on
/// one machine and nothing at all on another.
///
/// ## What is shared with the 2D path, and what is not
///
/// The device, the shader-visible descriptor heap and the texture allocator
/// are shared - a mesh texture is a `D3d12Texture` like any other, which is
/// what lets `SetDescriptorHeaps` name one heap and still reach it. The root
/// signature, the pipeline states, the sampler and the depth buffer are this
/// file's own, for the reason `D3d11MeshRenderer` gives: a second set of
/// objects is cheaper than a shared set with a mode switch that some path
/// forgets to set. The 2D static samplers are `CLAMP` and a mesh needs
/// `WRAP`, which alone settles it.
library;

import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../../foundation/diagnostics.dart';
import '../../../geometry/rect.dart';
import '../../../graphics/mesh/mesh3d.dart';
import '../../../rendering/gpu/gpu_texture.dart';
import '../../../rendering/mesh/mesh_rasterizer.dart';
import '../../../rendering/mesh/mesh_scene.dart';
import '../../../rendering/renderer.dart';
import 'd3d12_arena.dart';
import 'd3d12_com.dart';
import 'd3d12_device.dart';
import 'd3d12_interfaces.dart';
import 'd3d12_library.dart';
import 'd3d12_mesh_shaders.dart';
import 'd3d12_offscreen_target.dart';
import 'd3d12_structs.dart';
import 'd3d12_window_target.dart';

// ---------------------------------------------------------------------------
// The constants this file needs and `d3d12_structs.dart` has no other user for
// ---------------------------------------------------------------------------
//
// Declared here rather than added there for one reason: nothing else in this
// backend has a depth buffer, so a depth-stencil constant in the shared file
// would be a constant with no call site, and the next reader would have to
// find out whether it was dead or merely early. They move there the day a
// second file needs one.

/// `D3D12_DESCRIPTOR_HEAP_TYPE_DSV`.
const int _heapTypeDsv = 3;

/// `D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL`.
const int _resourceFlagAllowDepthStencil = 0x2;

/// `D3D12_RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER` and `_INDEX_BUFFER`.
///
/// A buffer that is read as both is declared as both; this one is read as one
/// or the other, and naming the exact state is what lets the runtime keep the
/// caches it would have to flush for a conservative one.
const int _resourceStateVertexBuffer = 0x1;
const int _resourceStateIndexBuffer = 0x2;

/// `D3D12_RESOURCE_STATE_DEPTH_WRITE`.
const int _resourceStateDepthWrite = 0x10;

/// `D3D12_CLEAR_FLAG_DEPTH`. Stencil is never cleared: the depth format below
/// has none.
const int _clearFlagDepth = 0x1;

/// `DXGI_FORMAT_D32_FLOAT` and `DXGI_FORMAT_R32G32B32_FLOAT`.
///
/// `D32_FLOAT` rather than the `D24_UNORM_S8_UINT` the Direct3D 11 pipeline
/// allocates, and the difference is not a preference: that file says its
/// choice is forced by a layer pool whose depth buffers are already `D24S8`,
/// and this backend has no layer pool and no stencil user at all. `D32_FLOAT`
/// is required of every Direct3D 12 device as a depth-stencil format, it needs
/// no stencil plane, and over the `[0, 1]` range the vertex stage produces it
/// resolves finer than 24 fixed bits everywhere the near plane matters.
const int _formatD32Float = 40;
const int _formatR32G32B32Float = 6;

/// `D3D12_DSV_DIMENSION_TEXTURE2D`.
const int _dsvDimensionTexture2d = 3;

/// `D3D12_DEPTH_WRITE_MASK_ALL`.
const int _depthWriteMaskAll = 1;

/// `D3D12_COMPARISON_FUNC_LESS` and `_GREATER`.
const int _comparisonLess = 2;
const int _comparisonGreater = 5;

/// `D3D12_FILL_MODE_WIREFRAME` and `D3D12_CULL_MODE_BACK`.
const int _fillModeWireframe = 2;
const int _cullModeBack = 3;

/// `D3D12_TEXTURE_ADDRESS_MODE_WRAP`.
///
/// The mesh sampler wraps where the 2D one clamps, which is the whole reason
/// this pipeline cannot borrow the device's root signature: a static sampler
/// is part of that object and cannot be changed per draw.
const int _textureAddressWrap = 1;

/// `D3D12_DEPTH_STENCIL_VIEW_DESC`. Twenty-four bytes: three enums and the
/// widest arm of the union, `Texture2DArray`.
final class _D3d12DepthStencilViewDesc extends Struct {
  @Uint32()
  external int format;
  @Uint32()
  external int viewDimension;
  @Uint32()
  external int flags;
  @Uint32()
  external int mipSlice;
  @Uint32()
  external int firstArraySlice;
  @Uint32()
  external int arraySize;
}

/// `D3D12_CLEAR_VALUE` with its depth-stencil arm filled in.
///
/// Optional to `CreateCommittedResource` and passed anyway. Two reasons, and
/// the second is why it is not merely tidiness: the debug layer warns about a
/// depth resource created without one - and
/// `test/backends/win32/d3d12/d3d12_barrier_test.dart` runs with the debug
/// layer on - and a driver that cannot see the clear value up front cannot use
/// its fast depth clear, which is the one clear this pipeline does every
/// frame.
final class _D3d12ClearValue extends Struct {
  @Uint32()
  external int format;
  @Float()
  external double depth;
  @Uint8()
  external int stencil;
  @Uint8()
  external int pad0;
  @Uint16()
  external int pad1;
  @Uint32()
  external int pad2;
  @Uint32()
  external int pad3;
  @Uint32()
  external int pad4;
}

/// How the depth test compares, so a test can break it on purpose.
///
/// The twin of `D3d11MeshDepthTest`, and it exists for the same reason: a
/// parity test that cannot fail proves nothing, and the two ways this pipeline
/// can be wrong without crashing are the depth comparison and the winding.
enum D3d12MeshDepthTest {
  /// Nearer fragments win: the correct one, and `MeshRasterizer`'s rule.
  less,

  /// Farther fragments win, which draws the model inside out through itself.
  greater,

  /// No depth test at all: whatever was recorded last is on top.
  always,
}

/// Draws a [MeshScene] with Direct3D 12.
///
/// One per device. It owns GPU objects, so it must be disposed before the
/// device it was built from.
///
/// ## Device loss
///
/// Unlike `D3d11MeshRenderer` this registers nothing with the device, and the
/// reason is that `D3d12RenderDevice` has no registration seam:
/// `markLost` forgets the experimental executors by name and there is no
/// `registerTarget`. So a device that is lost while this renderer is alive
/// leaves every object here belonging to a removed device, and the guard is
/// [drawInto]'s `_device.isLost` check, which refuses to record anything and
/// returns [MeshRenderStats.zero] - the same answer the contract already
/// requires for a target belonging to another backend. **A recovered device
/// needs a new renderer.** That is a real limitation and it is stated rather
/// than hidden: adding a recovery seam to this backend is a change to
/// `d3d12_device.dart`, not to this file.
final class D3d12MeshRenderer implements MeshSceneRenderer {
  D3d12MeshRenderer._(this._device);

  /// Builds the pipeline for [device], or returns the [BackendDiagnostic] that
  /// says what the driver refused.
  ///
  /// A diagnostic and not a throw, matching `D3d11MeshRenderer.create`: a
  /// caller that cannot get a mesh pipeline wants to fall back to the CPU
  /// rasteriser with a reason to print, not to lose its window.
  static Object create(D3d12RenderDevice device) {
    final renderer = D3d12MeshRenderer._(device);
    final BackendDiagnostic? failure = renderer._build();
    if (failure != null) {
      renderer.dispose();
      return failure;
    }
    return renderer;
  }

  final D3d12RenderDevice _device;

  Pointer<Void> _rootSignature = nullptr;
  D3dBlob? _vertexBlob;
  D3dBlob? _pixelBlob;

  /// Pipeline state objects by [_pipelineKey].
  final Map<int, Pointer<Void>> _pipelines = <int, Pointer<Void>>{};

  /// The depth buffer, its view heap, and the size it was allocated for.
  D3d12DescriptorHeap? _dsvHeap;
  Pointer<Void> _depthResource = nullptr;
  int _dsvHandle = 0;
  int _depthWidth = 0;
  int _depthHeight = 0;

  final Map<_MeshBufferKey, _MeshBuffers> _buffers =
      <_MeshBufferKey, _MeshBuffers>{};
  final Map<MeshTexture, D3d12Texture> _textures =
      <MeshTexture, D3d12Texture>{};
  final List<_RetiredUpload> _retired = <_RetiredUpload>[];
  int _bufferBytes = 0;
  int _clock = 0;
  bool _disposed = false;

  /// Long-lived native scratch, so a frame performs no native allocation.
  late final Pointer<Uint64> _handleSlot =
      _device.library.allocator.allocate<Uint64>(sizeOf<Uint64>());
  late final Pointer<IntPtr> _rtvSlot =
      _device.library.allocator.allocate<IntPtr>(sizeOf<IntPtr>());
  late final Pointer<IntPtr> _dsvSlot =
      _device.library.allocator.allocate<IntPtr>(sizeOf<IntPtr>());
  late final Pointer<D3d12Viewport> _viewport = _device.library.allocator
      .allocate<D3d12Viewport>(sizeOf<D3d12Viewport>());
  late final Pointer<D3d12Rect> _scissor =
      _device.library.allocator.allocate<D3d12Rect>(sizeOf<D3d12Rect>());
  late final Pointer<Float> _clearColor =
      _device.library.allocator.allocate<Float>(sizeOf<Float>() * 4);
  late final Pointer<Uint32> _constants = _device.library.allocator
      .allocate<Uint32>(sizeOf<Uint32>() * kD3d12MeshRootConstantCount);
  late final Pointer<D3d12VertexBufferView> _vertexView = _device
      .library.allocator
      .allocate<D3d12VertexBufferView>(sizeOf<D3d12VertexBufferView>());
  late final Pointer<D3d12IndexBufferView> _indexView = _device
      .library.allocator
      .allocate<D3d12IndexBufferView>(sizeOf<D3d12IndexBufferView>());
  late final Pointer<Pointer<Void>> _heapSlot = _device.library.allocator
      .allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());
  late final Pointer<D3d12Range> _noRead =
      _device.library.allocator.allocate<D3d12Range>(sizeOf<D3d12Range>());

  /// `ID3D12Device::CreateDepthStencilView`, vtable slot 21.
  ///
  /// Bound here and not in `d3d12_interfaces.dart` for the reason the
  /// constants above give: this is the only depth buffer in the backend. The
  /// slot is counted the way that file counts every other - 18 is
  /// `CreateShaderResourceView`, 19 `CreateUnorderedAccessView`, 20
  /// `CreateRenderTargetView`, so 21 is this - and a wrong number here is a
  /// wrong function call rather than an error.
  late final void Function(
    Pointer<Void>,
    Pointer<Void>,
    Pointer<_D3d12DepthStencilViewDesc>,
    int,
  ) _createDepthStencilView = comMethod<
          Void Function(
              Pointer<Void>,
              Pointer<Void>,
              Pointer<_D3d12DepthStencilViewDesc>,
              IntPtr)>(_device.nativeDevice.pointer, 21)
      .asFunction();

  /// `ID3D12GraphicsCommandList::ClearDepthStencilView`, vtable slot 47.
  ///
  /// One before `ClearRenderTargetView`, which `d3d12_interfaces.dart` binds
  /// at 48.
  late final void Function(
    Pointer<Void>,
    int,
    int,
    double,
    int,
    int,
    Pointer<D3d12Rect>,
  ) _clearDepthStencilView = comMethod<
          Void Function(Pointer<Void>, IntPtr, Uint32, Float, Uint8, Uint32,
              Pointer<D3d12Rect>)>(_device.frames.list.pointer, 47)
      .asFunction();

  /// Bytes of cached vertex and index buffers before the least recently drawn
  /// primitive is evicted.
  ///
  /// 384 MiB, the same budget and the same argument as the Direct3D 11
  /// pipeline's: one 451 838-triangle model smooth-shaded and the same model
  /// flat-shaded, with room for a second model beside them.
  int bufferBudgetBytes = 384 * 1024 * 1024;

  /// How the depth test compares. Correct at [D3d12MeshDepthTest.less].
  ///
  /// Public so the parity test can prove its own tolerance can fail. Nothing
  /// in a frame writes it.
  D3d12MeshDepthTest depthTest = D3d12MeshDepthTest.less;

  /// Whether a counter-clockwise triangle in render-target space is the front
  /// face. True is correct.
  ///
  /// Public for the same reason [depthTest] is: flipping it is the sabotage
  /// that leaves a closed model hollow.
  bool frontCounterClockwise = true;

  /// Buffers currently resident, for a test that asserts an upload happened
  /// once rather than per frame.
  int get cachedPrimitiveCount => _buffers.length;

  /// Bytes of vertex and index data resident on the device.
  int get cachedBufferBytes => _bufferBytes;

  /// `CreateCommittedResource` calls this renderer has made for geometry.
  ///
  /// The number that says the cache works. A viewer orbiting one model for a
  /// hundred frames must leave this at twice the primitive count.
  int get bufferUploadCount => _bufferUploadCount;
  int _bufferUploadCount = 0;

  bool get isDisposed => _disposed;

  // -------------------------------------------------------------------
  // Construction
  // -------------------------------------------------------------------

  BackendDiagnostic? _build() {
    return D3d12Arena.using(_device.library.allocator, (D3d12Arena arena) {
      final BackendDiagnostic? root = _createRootSignature(arena);
      if (root != null) return root;
      final Object vertex = _device.compileShader(arena, kD3d12MeshShaderSource,
          kD3d12MeshVertexEntryPoint, kD3d12MeshVertexTarget);
      if (vertex is BackendDiagnostic) return vertex;
      final Object pixel = _device.compileShader(arena, kD3d12MeshShaderSource,
          kD3d12MeshPixelEntryPoint, kD3d12MeshPixelTarget);
      if (pixel is BackendDiagnostic) {
        (vertex as D3dBlob).release();
        return pixel;
      }
      _vertexBlob = vertex as D3dBlob;
      _pixelBlob = pixel as D3dBlob;

      final Pointer<Guid> iid = arena<Guid>(sizeOf<Guid>());
      writeGuid(iid, D3d12Iids.descriptorHeap);
      final Pointer<D3d12DescriptorHeapDesc> heapDesc =
          arena<D3d12DescriptorHeapDesc>(sizeOf<D3d12DescriptorHeapDesc>());
      heapDesc.ref
        ..type = _heapTypeDsv
        // One. The pipeline has one depth buffer and reallocates it in place
        // when the target grows, so a heap with room for more would be room
        // nothing can reach.
        ..numDescriptors = 1
        // Not shader-visible: a depth-stencil view is only ever an
        // output-merger binding, and a DSV heap that asked to be
        // shader-visible is rejected outright.
        ..flags = 0
        ..nodeMask = 0;
      final Pointer<Pointer<Void>> out = arena.allocatePointers(1);
      final int hr = _device.nativeDevice.createDescriptorHeap(
          _device.nativeDevice.pointer, heapDesc, iid, out);
      if (comFailed(hr)) {
        return BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'the mesh depth-stencil view heap could not be created',
          detail: hresultText(hr),
        );
      }
      _dsvHeap = D3d12DescriptorHeap(out.value, _handleSlot);
      _dsvHandle = _dsvHeap!.cpuHandleStart;

      // The pipeline state for the default draw, built now rather than on the
      // first frame. A driver compiles a PSO the moment it is created, and the
      // one thing a 3D viewer must not do is stall for a shader compile
      // between `beginFrame` and `present`.
      final Object warm = _pipelineFor(
        cull: true,
        wireframe: false,
        test: D3d12MeshDepthTest.less,
        frontCcw: true,
      );
      if (warm is BackendDiagnostic) return warm;
      return null;
    });
  }

  BackendDiagnostic? _createRootSignature(D3d12Arena arena) {
    final Pointer<D3d12DescriptorRange> range =
        arena<D3d12DescriptorRange>(sizeOf<D3d12DescriptorRange>());
    range.ref
      ..rangeType = d3d12DescriptorRangeTypeSrv
      ..numDescriptors = 1
      ..baseShaderRegister = 0
      ..registerSpace = 0
      ..offsetInDescriptorsFromTableStart = 0;

    final Pointer<D3d12RootParameter> parameters =
        arena<D3d12RootParameter>(sizeOf<D3d12RootParameter>() * 2);
    parameters[kD3d12MeshRootConstantsSlot]
      ..parameterType = d3d12RootParameterTypeConstants
      ..field8 = 0 // ShaderRegister: b0
      ..fieldC = 0 // RegisterSpace
      ..field10 = kD3d12MeshRootConstantCount
      // Both stages: the vertex stage reads the matrix and the normal matrix,
      // the pixel stage reads the light, the colour and the options.
      ..shaderVisibility = d3d12ShaderVisibilityAll;
    parameters[kD3d12MeshRootTextureSlot]
      ..parameterType = d3d12RootParameterTypeDescriptorTable
      ..field8 = 1 // NumDescriptorRanges
      ..field10 = range.address
      ..shaderVisibility = d3d12ShaderVisibilityPixel;

    final Pointer<D3d12StaticSamplerDesc> sampler =
        arena<D3d12StaticSamplerDesc>(sizeOf<D3d12StaticSamplerDesc>());
    // Point filtering and `WRAP`, because that is what [MeshTexture] does. A
    // linear tap here would be a *better* picture that no parity test could
    // accept, and clamping smears the edge texel across a model that tiles.
    sampler.ref
      ..filter = d3d12FilterMinMagMipPoint
      ..addressU = _textureAddressWrap
      ..addressV = _textureAddressWrap
      ..addressW = _textureAddressWrap
      ..mipLodBias = 0
      ..maxAnisotropy = 1
      ..comparisonFunc = d3d12ComparisonFuncAlways
      ..borderColor = d3d12StaticBorderColorTransparentBlack
      ..minLod = 0
      // Zero and not FLT_MAX: every mesh texture is uploaded with one mip
      // level, so there is no level above zero for the sampler to select.
      ..maxLod = 0
      ..shaderRegister = 0
      ..registerSpace = 0
      ..shaderVisibility = d3d12ShaderVisibilityPixel;

    final Pointer<D3d12RootSignatureDesc> desc =
        arena<D3d12RootSignatureDesc>(sizeOf<D3d12RootSignatureDesc>());
    desc.ref
      ..numParameters = 2
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
        message: 'the mesh root signature could not be serialised',
        detail: detail,
      );
    }
    final D3dBlob blob = D3dBlob(blobOut.value);
    final Pointer<Guid> iid = arena<Guid>(sizeOf<Guid>());
    writeGuid(iid, D3d12Iids.rootSignature);
    final Pointer<Pointer<Void>> out = arena.allocatePointers(1);
    final int createHr = _device.nativeDevice.createRootSignature(
        _device.nativeDevice.pointer, 0, blob.data, blob.length, iid, out);
    blob.release();
    if (comFailed(createHr)) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'CreateRootSignature refused the mesh signature',
        detail: hresultText(createHr),
      );
    }
    _rootSignature = out.value;
    return null;
  }

  /// The five bits of state a pipeline state object bakes in.
  ///
  /// The winding is part of the key so that flipping [frontCounterClockwise]
  /// mid-run builds a second object rather than returning the first one and
  /// silently ignoring the change - which would make the sabotage test pass by
  /// doing nothing.
  static int _pipelineKey({
    required bool cull,
    required bool wireframe,
    required D3d12MeshDepthTest test,
    required bool frontCcw,
  }) =>
      (cull ? 1 : 0) |
      (wireframe ? 2 : 0) |
      (frontCcw ? 4 : 0) |
      (test.index << 3);

  /// Returns a `Pointer<Void>` on success, a [BackendDiagnostic] on failure.
  Object _pipelineFor({
    required bool cull,
    required bool wireframe,
    required D3d12MeshDepthTest test,
    required bool frontCcw,
  }) {
    final int key = _pipelineKey(
        cull: cull, wireframe: wireframe, test: test, frontCcw: frontCcw);
    final Pointer<Void>? cached = _pipelines[key];
    if (cached != null) return cached;
    final Object built =
        D3d12Arena.using(_device.library.allocator, (D3d12Arena arena) {
      final Pointer<D3d12InputElementDesc> elements =
          arena<D3d12InputElementDesc>(sizeOf<D3d12InputElementDesc>() * 3);
      const List<int> formats = <int>[
        _formatR32G32B32Float,
        _formatR32G32B32Float,
        dxgiFormatR32G32Float,
      ];
      const List<int> offsets = <int>[
        kD3d12MeshPositionOffset,
        kD3d12MeshNormalOffset,
        kD3d12MeshTexCoordOffset,
      ];
      for (var i = 0; i < 3; i++) {
        elements[i]
          ..semanticName = arena.allocateAscii(kD3d12MeshSemanticNames[i])
          ..semanticIndex = kD3d12MeshSemanticIndices[i]
          ..format = formats[i]
          ..inputSlot = 0
          ..alignedByteOffset = offsets[i]
          ..inputSlotClass = d3d12InputPerVertexData
          ..instanceDataStepRate = 0;
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
        ..dsvFormat = _formatD32Float
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
        ..numElements = 3;
      desc.ref.blendState
        ..alphaToCoverageEnable = 0
        ..independentBlendEnable = 0;
      // Blending off, all four channels written. Not a matter of taste:
      // `MeshRasterizer` writes `argb | 0xFF000000` at every pixel that passes
      // the depth test, so the model is opaque by construction, and blending
      // it over a 2D pass would be invisible on a cleared target and very
      // visible on one with an interface already on it.
      desc.ref.blendState.renderTarget[0]
        ..blendEnable = 0
        ..logicOpEnable = 0
        ..srcBlend = d3d12BlendOne
        ..destBlend = d3d12BlendZero
        ..srcBlendAlpha = d3d12BlendOne
        ..destBlendAlpha = d3d12BlendZero
        ..blendOp = d3d12BlendOpAdd
        ..blendOpAlpha = d3d12BlendOpAdd
        ..logicOp = d3d12LogicOpNoop
        ..renderTargetWriteMask = d3d12ColorWriteEnableAll;
      desc.ref.rasterizerState
        ..fillMode = wireframe ? _fillModeWireframe : d3d12FillModeSolid
        ..cullMode = cull ? _cullModeBack : d3d12CullModeNone
        ..frontCounterClockwise = frontCcw ? 1 : 0
        ..depthBias = 0
        ..depthBiasClamp = 0
        ..slopeScaledDepthBias = 0
        // The near plane. `MeshRasterizer` clips its polygons against
        // `w > near` by hand; here the hardware does it, at the same plane,
        // because the vertex stage's depth remap put `w = near` at `z = 0`.
        ..depthClipEnable = 1
        ..multisampleEnable = 0
        ..antialiasedLineEnable = 0
        ..forcedSampleCount = 0
        ..conservativeRaster = d3d12ConservativeRasterOff;
      desc.ref.depthStencilState
        ..depthEnable = test == D3d12MeshDepthTest.always ? 0 : 1
        ..depthWriteMask = _depthWriteMaskAll
        ..depthFunc = switch (test) {
          D3d12MeshDepthTest.less => _comparisonLess,
          D3d12MeshDepthTest.greater => _comparisonGreater,
          D3d12MeshDepthTest.always => d3d12ComparisonFuncAlways,
        }
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
          _device.nativeDevice.pointer, desc, iid, out);
      if (comFailed(hr)) {
        return BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'the mesh pipeline state for key $key was refused',
          detail: hresultText(hr),
        );
      }
      return out.value;
    });
    if (built is BackendDiagnostic) return built;
    _pipelines[key] = built as Pointer<Void>;
    return built;
  }

  // -------------------------------------------------------------------
  // Drawing
  // -------------------------------------------------------------------

  @override
  MeshRenderStats drawScene(
    RenderTarget target,
    MeshScene scene, {
    Rect? viewport,
  }) {
    _throwIfDisposed();
    if (_device.isLost) return MeshRenderStats.zero;
    // The one place this file knows about concrete target types, and it is
    // unavoidable: `MeshSceneRenderer` promises to take a [RenderTarget] so
    // that the other backends can implement the same method, which means each
    // backend has to recognise its own.
    return switch (target) {
      D3d12WindowTarget() when identical(target.device, _device) => drawInto(
          target.currentRenderTargetView,
          targetWidth: target.surface.pixelWidth,
          targetHeight: target.surface.pixelHeight,
          scene: scene,
          viewport: viewport,
          // The swap chain's buffer arrives in `PRESENT` and `present` will
          // move it out of `PRESENT` again, so this pass has to put it back.
          presentingResource: target.currentBackBuffer,
        ),
      D3d12OffscreenTarget() when identical(target.device, _device) => drawInto(
          target.colorRenderTargetView,
          targetWidth: target.surface.pixelWidth,
          targetHeight: target.surface.pixelHeight,
          scene: scene,
          viewport: viewport,
        ),
      _ => MeshRenderStats.zero,
    };
  }

  /// The Direct3D 12 entry point behind [drawScene], for a caller that already
  /// holds a render-target-view handle.
  ///
  /// Separate from [drawScene] because the interface cannot name a descriptor
  /// handle. [drawScene] is the one an application uses.
  ///
  /// [presentingResource] is the swap chain buffer to move `PRESENT` ->
  /// `RENDER_TARGET` and back around the draws, or `nullptr` for a target
  /// whose colour surface is already in `RENDER_TARGET`.
  MeshRenderStats drawInto(
    int renderTargetView, {
    required int targetWidth,
    required int targetHeight,
    required MeshScene scene,
    Rect? viewport,
    Pointer<Void>? presentingResource,
  }) {
    _throwIfDisposed();
    if (renderTargetView == 0 ||
        targetWidth <= 0 ||
        targetHeight <= 0 ||
        _device.isLost ||
        _rootSignature == nullptr) {
      return MeshRenderStats.zero;
    }
    final Rect box = viewport ??
        Rect.fromLTWH(0, 0, targetWidth.toDouble(), targetHeight.toDouble());
    if (box.width <= 0 || box.height <= 0) return MeshRenderStats.zero;
    final Pointer<Void> presenting = presentingResource ?? nullptr;

    final Stopwatch watch = Stopwatch()..start();
    _sweepRetired();

    // A frame that is already recording gets the draws for free. A caller
    // outside a frame - a probe measuring the pipeline on its own - gets a
    // list of its own, closed and waited on before this returns, because there
    // is no later point at which somebody would flush it.
    final bool opened = !_device.frames.isRecording;
    if (opened && _device.frames.begin() == null) {
      _device.markLost('a command list could not be opened for a mesh frame');
      return MeshRenderStats.zero;
    }
    final D3d12GraphicsCommandList list = _device.frames.list;
    var triangles = 0;
    try {
      if (!_ensureDepth(targetWidth, targetHeight)) return MeshRenderStats.zero;
      if (presenting != nullptr) {
        _device.transitionResource(presenting, d3d12ResourceStatePresent,
            d3d12ResourceStateRenderTarget);
      }

      _rtvSlot.value = renderTargetView;
      _dsvSlot.value = _dsvHandle;
      list.omSetRenderTargets(list.pointer, 1, _rtvSlot, 0, _dsvSlot);
      _clearDepthStencilView(
          list.pointer, _dsvHandle, _clearFlagDepth, 1, 0, 0, nullptr);

      final int? background = scene.backgroundArgb;
      if (background != null) {
        // The whole view, not the viewport. `ClearRenderTargetView` takes a
        // rectangle list and is given none, which is the same semantics
        // `MeshRasterizer.render` has - it clears the framebuffer it was
        // given - and the same rule `MeshScene.backgroundArgb` states.
        _clearColor[0] = ((background >> 16) & 0xFF) / 255.0;
        _clearColor[1] = ((background >> 8) & 0xFF) / 255.0;
        _clearColor[2] = (background & 0xFF) / 255.0;
        _clearColor[3] = ((background >> 24) & 0xFF) / 255.0;
        list.clearRenderTargetView(
            list.pointer, renderTargetView, _clearColor, 0, nullptr);
      }

      _viewport.ref
        ..topLeftX = box.left
        ..topLeftY = box.top
        ..width = box.width
        ..height = box.height
        ..minDepth = 0
        ..maxDepth = 1;
      _scissor.ref
        ..left = box.left.floor().clamp(0, targetWidth)
        ..top = box.top.floor().clamp(0, targetHeight)
        ..right = box.right.ceil().clamp(0, targetWidth)
        ..bottom = box.bottom.ceil().clamp(0, targetHeight);
      _heapSlot.value = _device.shaderVisibleHeap;
      list
        ..rsSetViewports(list.pointer, 1, _viewport)
        ..rsSetScissorRects(list.pointer, 1, _scissor)
        ..setGraphicsRootSignature(list.pointer, _rootSignature)
        ..iaSetPrimitiveTopology(list.pointer, d3dPrimitiveTopologyTriangleList)
        ..setDescriptorHeaps(list.pointer, 1, _heapSlot);

      final Matrix4 viewProjection = scene.camera
          .projectionMatrix(box.width / box.height)
          .multiply(scene.camera.viewMatrix());
      final Vector3 light = scene.lightDirection.normalized;
      final bool lit = scene.shading != MeshShading.unlit &&
          scene.shading != MeshShading.wireframe;
      final bool wireframe = scene.shading == MeshShading.wireframe;

      // Once, before the draws, and not per primitive: a texture is sampled by
      // many draws and a barrier per draw would serialise the GPU between
      // them. Idempotent, so a mesh with no textures pays nothing.
      _device.prepareTexturesForSampling();

      for (final MeshPrimitive primitive in scene.mesh.primitives) {
        triangles += primitive.triangleCount;
        final _MeshBuffers? buffers = _buffersFor(primitive, scene.shading);
        if (buffers == null) continue;
        final MeshTexture? texture = wireframe
            ? null
            : (primitive.uvs == null
                ? null
                : primitive.material.baseColorTexture);
        final D3d12Texture? uploaded =
            texture == null ? null : _textureFor(texture);
        final Object pipeline = _pipelineFor(
          cull: !primitive.material.doubleSided,
          wireframe: wireframe,
          test: depthTest,
          frontCcw: frontCounterClockwise,
        );
        if (pipeline is BackendDiagnostic) continue;
        _writeConstants(
          viewProjection,
          light,
          scene.ambient,
          primitive.material.colorArgb,
          lit: lit,
          textured: uploaded != null,
        );
        _vertexView.ref
          ..bufferLocation = buffers.vertexAddress
          ..sizeInBytes = buffers.vertexBytes
          ..strideInBytes = kD3d12MeshVertexStrideBytes;
        _indexView.ref
          ..bufferLocation = buffers.indexAddress
          ..sizeInBytes = buffers.indexBytes
          ..format = dxgiFormatR32Uint;
        list
          ..setPipelineState(list.pointer, pipeline as Pointer<Void>)
          ..setGraphicsRoot32BitConstants(
              list.pointer,
              kD3d12MeshRootConstantsSlot,
              kD3d12MeshRootConstantCount,
              _constants.cast<Void>(),
              0)
          // The placeholder at descriptor 0 when there is no texture: a root
          // descriptor table left pointing at an uninitialised descriptor is
          // what the debug layer reports and what a driver may treat as
          // anything at all.
          ..setGraphicsRootDescriptorTable(
              list.pointer,
              kD3d12MeshRootTextureSlot,
              _device.gpuDescriptorHandleFor(uploaded?.id ?? 0))
          ..iaSetVertexBuffers(list.pointer, 0, 1, _vertexView)
          ..iaSetIndexBuffer(list.pointer, _indexView)
          ..drawIndexedInstanced(list.pointer, buffers.indexCount, 1, 0, 0, 0);
      }

      // The depth-stencil view, off. A 2D pass that inherited it would
      // depth-test every batch against the plane the model wrote and the
      // interface would disappear where the model was; the depth *state* needs
      // no undoing here because Direct3D 12 bakes it into the pipeline object
      // and the 2D path sets its own.
      list.omSetRenderTargets(list.pointer, 1, _rtvSlot, 0, nullptr);
      if (presenting != nullptr) {
        _device.transitionResource(presenting, d3d12ResourceStateRenderTarget,
            d3d12ResourceStatePresent);
      }
    } finally {
      if (opened && !_device.frames.end(waitForCompletion: true)) {
        _device.markLost('the mesh command list could not be executed');
      }
    }

    watch.stop();
    return gpuMeshStats(
      triangles: triangles,
      microseconds: watch.elapsedMicroseconds,
    );
  }

  /// Writes the forty root-constant dwords.
  ///
  /// The transpose is the whole reason this is not a `setAll`: [Matrix4] stores
  /// column-major, like glTF and OpenGL, and the shader declares the matrix
  /// `row_major`, so register `i` is row `i` and `row i, column j` lives at
  /// `storage[j * 4 + i]`. Getting it wrong is a model transformed by the
  /// transpose of the intended matrix, which for a view-projection is not a
  /// recognisable transform at all - the model simply is not on screen.
  void _writeConstants(
    Matrix4 viewProjection,
    Vector3 light,
    double ambient,
    int colorArgb, {
    required bool lit,
    required bool textured,
  }) {
    final Float64List m = viewProjection.storage;
    final Pointer<Float> values = _constants.cast<Float>();
    for (var row = 0; row < 4; row++) {
      for (var column = 0; column < 4; column++) {
        values[row * 4 + column] = m[column * 4 + row];
      }
    }
    // The identity normal matrix. `MeshRasterizer` shades against model-space
    // normals and a model-space light - there is no model matrix in a
    // [MeshScene] - so anything else here would be a transform the CPU path
    // does not apply, and the two would diverge over the whole model rather
    // than at a silhouette.
    for (var row = 0; row < 3; row++) {
      for (var column = 0; column < 4; column++) {
        values[16 + row * 4 + column] = row == column ? 1 : 0;
      }
    }
    values[28] = light.x;
    values[29] = light.y;
    values[30] = light.z;
    values[31] = ambient;
    // 0..255 and not 0..1: the shader works in the CPU rasteriser's channel
    // space throughout and divides once at the return.
    values[32] = ((colorArgb >> 16) & 0xFF).toDouble();
    values[33] = ((colorArgb >> 8) & 0xFF).toDouble();
    values[34] = (colorArgb & 0xFF).toDouble();
    values[35] = 255;
    values[36] = lit ? 1 : 0;
    values[37] = textured ? 1 : 0;
    values[38] = 0;
    values[39] = 0;
  }

  /// Allocates the depth buffer, or reallocates it to cover the target.
  ///
  /// Matched to the *target* rather than to the viewport: Direct3D requires
  /// every view bound to the output-merger to be at least as large as the
  /// render target, so a depth buffer sized to a sub-rectangle viewport would
  /// be rejected outright.
  bool _ensureDepth(int width, int height) {
    if (_depthResource != nullptr &&
        _depthWidth == width &&
        _depthHeight == height) {
      return true;
    }
    if (_depthResource != nullptr) {
      // The old buffer may still be read by a frame in flight. Waiting is the
      // same precondition `ResizeBuffers` has and there is no cheaper answer:
      // a resize happens when a window changes size, not per frame.
      _device.frames.waitIdle();
      ComObject(_depthResource).release();
      _depthResource = nullptr;
    }
    _depthWidth = 0;
    _depthHeight = 0;

    final Pointer<Void>? resource =
        D3d12Arena.using(_device.library.allocator, (D3d12Arena arena) {
      final Pointer<D3d12HeapProperties> heap =
          arena<D3d12HeapProperties>(sizeOf<D3d12HeapProperties>());
      heap.ref
        ..type = d3d12HeapTypeDefault
        ..cpuPageProperty = 0
        ..memoryPoolPreference = 0
        ..creationNodeMask = 1
        ..visibleNodeMask = 1;
      final Pointer<D3d12ResourceDesc> desc =
          arena<D3d12ResourceDesc>(sizeOf<D3d12ResourceDesc>());
      desc.ref
        ..dimension = d3d12ResourceDimensionTexture2d
        ..alignment = 0
        ..width = width
        ..height = height
        ..depthOrArraySize = 1
        ..mipLevels = 1
        ..format = _formatD32Float
        ..layout = d3d12TextureLayoutUnknown
        ..flags = _resourceFlagAllowDepthStencil;
      desc.ref.sampleDesc
        ..count = 1
        ..quality = 0;
      final Pointer<_D3d12ClearValue> clear =
          arena<_D3d12ClearValue>(sizeOf<_D3d12ClearValue>());
      clear.ref
        ..format = _formatD32Float
        ..depth = 1
        ..stencil = 0;
      final Pointer<Guid> iid = arena<Guid>(sizeOf<Guid>());
      writeGuid(iid, D3d12Iids.resource);
      final Pointer<Pointer<Void>> out = arena.allocatePointers(1);
      final int hr = _device.nativeDevice.createCommittedResource(
        _device.nativeDevice.pointer,
        heap,
        0,
        desc,
        // Created straight into `DEPTH_WRITE` and never transitioned: nothing
        // in this backend samples the depth buffer, so it has exactly one
        // state for its whole life.
        _resourceStateDepthWrite,
        clear.cast<Void>(),
        iid,
        out,
      );
      return comFailed(hr) ? null : out.value;
    });
    if (resource == null) return false;

    D3d12Arena.using(_device.library.allocator, (D3d12Arena arena) {
      final Pointer<_D3d12DepthStencilViewDesc> view =
          arena<_D3d12DepthStencilViewDesc>(
              sizeOf<_D3d12DepthStencilViewDesc>());
      view.ref
        ..format = _formatD32Float
        ..viewDimension = _dsvDimensionTexture2d
        // Flags: 0, read/write, because the depth test writes.
        ..flags = 0
        ..mipSlice = 0;
      _createDepthStencilView(
          _device.nativeDevice.pointer, resource, view, _dsvHandle);
    });
    _depthResource = resource;
    _depthWidth = width;
    _depthHeight = height;
    return true;
  }

  // -------------------------------------------------------------------
  // Geometry and texture caches
  // -------------------------------------------------------------------

  @override
  void discardMesh(Mesh3D mesh) {
    for (final MeshPrimitive primitive in mesh.primitives) {
      for (final _MeshNormalSource source in _MeshNormalSource.values) {
        final _MeshBuffers? entry =
            _buffers.remove(_MeshBufferKey(primitive, source));
        if (entry == null) continue;
        _bufferBytes -= entry.bytes;
        _release(entry);
      }
      final MeshTexture? texture = primitive.material.baseColorTexture;
      if (texture == null) continue;
      final D3d12Texture? uploaded = _textures.remove(texture);
      if (uploaded != null) _device.releaseTexture(uploaded);
    }
  }

  _MeshBuffers? _buffersFor(MeshPrimitive primitive, MeshShading shading) {
    final _MeshNormalSource source = shading == MeshShading.flat
        ? _MeshNormalSource.perFace
        : _MeshNormalSource.perVertex;
    final key = _MeshBufferKey(primitive, source);
    final _MeshBuffers? cached = _buffers[key];
    if (cached != null) {
      cached.lastUsed = ++_clock;
      return cached;
    }
    final _MeshBuffers? built = source == _MeshNormalSource.perFace
        ? _buildFlat(primitive)
        : _buildIndexed(primitive);
    if (built == null) return null;
    built.lastUsed = ++_clock;
    _buffers[key] = built;
    _bufferBytes += built.bytes;
    _evictIfOverBudget(key);
    return built;
  }

  /// The ordinary path: one vertex per vertex, the file's own index buffer.
  _MeshBuffers? _buildIndexed(MeshPrimitive primitive) {
    final int vertexCount = primitive.vertexCount;
    final Uint32List indices = primitive.indices;
    if (vertexCount == 0 || indices.length < 3) return null;
    // `primitive.normals ?? computeSmoothNormals()` is exactly what
    // `MeshRasterizer.render` does for smooth shading, and the fallback is not
    // optional: a mesh with no normals shaded with a zero normal is uniformly
    // ambient, which looks like a flat-lit model rather than like missing data.
    final Float32List normals =
        primitive.normals ?? primitive.computeSmoothNormals();
    final Float32List? uvs = primitive.uvs;
    final Float32List positions = primitive.positions;
    final Float32List vertices =
        Float32List(vertexCount * (kD3d12MeshVertexStrideBytes ~/ 4));
    for (var i = 0; i < vertexCount; i++) {
      final int out = i * 8;
      final int p = i * 3;
      vertices[out] = positions[p];
      vertices[out + 1] = positions[p + 1];
      vertices[out + 2] = positions[p + 2];
      if (p + 2 < normals.length) {
        vertices[out + 3] = normals[p];
        vertices[out + 4] = normals[p + 1];
        vertices[out + 5] = normals[p + 2];
      }
      final int t = i * 2;
      if (uvs != null && t + 1 < uvs.length) {
        vertices[out + 6] = uvs[t];
        vertices[out + 7] = uvs[t + 1];
      }
    }
    // Indices past the end of the vertex array are dropped rather than clamped,
    // which is what `MeshRasterizer` does with its `ia >= vertexCount` guard. A
    // clamp would draw a triangle the CPU never drew - a stray fan back to
    // vertex zero, which is a visible spike out of the model.
    final Uint32List safe = _filterIndices(indices, vertexCount);
    if (safe.isEmpty) return null;
    return _createBuffers(vertices, safe);
  }

  /// The flat-shading path: de-indexed, three vertices per triangle, each
  /// carrying its own face's normal.
  ///
  /// A face normal is not a property of a vertex, so there is no way to express
  /// flat shading through a shared vertex buffer. The cross product is
  /// `(b - a) x (c - a)` normalised, character for character
  /// `MeshRasterizer._drawProjected`'s `faceNormalOf`.
  _MeshBuffers? _buildFlat(MeshPrimitive primitive) {
    final Float32List positions = primitive.positions;
    final Uint32List indices = primitive.indices;
    final Float32List? uvs = primitive.uvs;
    final int vertexCount = primitive.vertexCount;
    final int triangles = indices.length ~/ 3;
    if (triangles == 0) return null;
    final Float32List vertices = Float32List(triangles * 3 * 8);
    final Uint32List out = Uint32List(triangles * 3);
    var written = 0;
    for (var t = 0; t + 2 < indices.length; t += 3) {
      final int ia = indices[t];
      final int ib = indices[t + 1];
      final int ic = indices[t + 2];
      if (ia >= vertexCount || ib >= vertexCount || ic >= vertexCount) continue;
      final int pa = ia * 3;
      final int pb = ib * 3;
      final int pc = ic * 3;
      final double ax = positions[pb] - positions[pa];
      final double ay = positions[pb + 1] - positions[pa + 1];
      final double az = positions[pb + 2] - positions[pa + 2];
      final double bx = positions[pc] - positions[pa];
      final double by = positions[pc + 1] - positions[pa + 1];
      final double bz = positions[pc + 2] - positions[pa + 2];
      var nx = ay * bz - az * by;
      var ny = az * bx - ax * bz;
      var nz = ax * by - ay * bx;
      final double length = math.sqrt(nx * nx + ny * ny + nz * nz);
      // A zero vector normalises to zero rather than to NaN, the rule
      // `Vector3.normalized` states: degenerate triangles are common in
      // exported models and a NaN normal poisons the shading of everything
      // that shares it.
      if (length != 0) {
        nx /= length;
        ny /= length;
        nz /= length;
      }
      for (final int index in <int>[ia, ib, ic]) {
        final int at = written * 8;
        final int p = index * 3;
        vertices[at] = positions[p];
        vertices[at + 1] = positions[p + 1];
        vertices[at + 2] = positions[p + 2];
        vertices[at + 3] = nx;
        vertices[at + 4] = ny;
        vertices[at + 5] = nz;
        final int uv = index * 2;
        if (uvs != null && uv + 1 < uvs.length) {
          vertices[at + 6] = uvs[uv];
          vertices[at + 7] = uvs[uv + 1];
        }
        out[written] = written;
        written++;
      }
    }
    if (written == 0) return null;
    return _createBuffers(
      Float32List.sublistView(vertices, 0, written * 8),
      Uint32List.sublistView(out, 0, written),
    );
  }

  static Uint32List _filterIndices(Uint32List indices, int vertexCount) {
    var bad = 0;
    for (var t = 0; t + 2 < indices.length; t += 3) {
      if (indices[t] >= vertexCount ||
          indices[t + 1] >= vertexCount ||
          indices[t + 2] >= vertexCount) {
        bad++;
      }
    }
    final int triangles = indices.length ~/ 3;
    if (bad == 0) {
      // The common case, and the one worth not copying for: a well-formed model
      // is every model a loader in this repository produces, and 5.4 MB of
      // memcpy per primitive to prove it is not free.
      return triangles * 3 == indices.length
          ? indices
          : Uint32List.sublistView(indices, 0, triangles * 3);
    }
    final Uint32List out = Uint32List((triangles - bad) * 3);
    var at = 0;
    for (var t = 0; t + 2 < indices.length; t += 3) {
      if (indices[t] >= vertexCount ||
          indices[t + 1] >= vertexCount ||
          indices[t + 2] >= vertexCount) {
        continue;
      }
      out[at++] = indices[t];
      out[at++] = indices[t + 1];
      out[at++] = indices[t + 2];
    }
    return out;
  }

  _MeshBuffers? _createBuffers(Float32List vertices, Uint32List indices) {
    final Pointer<Void>? vertexBuffer = _uploadedBuffer(
        vertices, vertices.lengthInBytes, _resourceStateVertexBuffer);
    if (vertexBuffer == nullptr || vertexBuffer == null) return null;
    final Pointer<Void>? indexBuffer = _uploadedBuffer(
        indices, indices.lengthInBytes, _resourceStateIndexBuffer);
    if (indexBuffer == nullptr || indexBuffer == null) {
      ComObject(vertexBuffer).release();
      return null;
    }
    return _MeshBuffers(
      vertex: vertexBuffer,
      index: indexBuffer,
      vertexAddress: D3d12Resource(vertexBuffer).gpuVirtualAddress,
      indexAddress: D3d12Resource(indexBuffer).gpuVirtualAddress,
      vertexBytes: vertices.lengthInBytes,
      indexBytes: indices.lengthInBytes,
      indexCount: indices.length,
      bytes: vertices.lengthInBytes + indices.lengthInBytes,
    );
  }

  /// A `DEFAULT`-heap buffer holding [bytes] from [source], left in [finalState].
  ///
  /// The two-step is what Direct3D 12 requires and Direct3D 11's
  /// `D3D11_USAGE_IMMUTABLE` hides: the CPU can only write an `UPLOAD`-heap
  /// resource, and the GPU reads geometry fastest out of a `DEFAULT`-heap one,
  /// so the bytes go into the first and a `CopyBufferRegion` moves them into
  /// the second. The staging buffer is retired behind the fence rather than
  /// released here - see [_retired] and the library comment.
  ///
  /// Records onto the command list the caller already opened. Every call site
  /// is inside [drawInto]'s `opened`/`end` bracket, so there always is one.
  Pointer<Void>? _uploadedBuffer(TypedData source, int bytes, int finalState) {
    if (bytes <= 0 || !_device.frames.isRecording) return null;
    final Pointer<Void>? destination = _committedBuffer(
        bytes, d3d12HeapTypeDefault, d3d12ResourceStateCopyDest);
    if (destination == null) return null;
    final Pointer<Void>? staging = _committedBuffer(
        bytes, d3d12HeapTypeUpload, d3d12ResourceStateGenericRead);
    if (staging == null) {
      ComObject(destination).release();
      return null;
    }
    final D3d12Resource stagingResource = D3d12Resource(staging);
    final Pointer<Pointer<Void>> mapped = _device.library.allocator
        .allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());
    try {
      // A zero-length read range says the CPU will not read this memory, which
      // on a discrete adapter is what lets the driver leave it write-combined.
      _noRead.ref
        ..begin = 0
        ..end = 0;
      if (comFailed(stagingResource.map(_noRead, mapped))) {
        stagingResource.release();
        ComObject(destination).release();
        return null;
      }
      mapped.value
          .cast<Uint8>()
          .asTypedList(bytes)
          .setAll(0, source.buffer.asUint8List(source.offsetInBytes, bytes));
      // The written range is the whole buffer, which is what tells a
      // write-combined mapping to flush before the GPU reads it.
      _noRead.ref
        ..begin = 0
        ..end = bytes;
      stagingResource.unmap(_noRead);
    } finally {
      _device.library.allocator.free(mapped);
    }

    final D3d12GraphicsCommandList list = _device.frames.list;
    list.copyBufferRegion(list.pointer, destination, 0, staging, 0, bytes);
    _device.transitionResource(
        destination, d3d12ResourceStateCopyDest, finalState);
    // The value this list will be signalled with. `end` increments
    // `signalledValue` and hands it to the queue *behind* the work, so the
    // staging buffer is free exactly when the fence has reached it. A list
    // that is abandoned instead never reaches this value from its own frame,
    // and the next frame that does end reaches it - which is still after the
    // copy that never ran.
    _retired.add(_RetiredUpload(staging, _device.frames.signalledValue + 1));
    _bufferUploadCount++;
    return destination;
  }

  Pointer<Void>? _committedBuffer(int bytes, int heapType, int initialState) =>
      D3d12Arena.using(_device.library.allocator, (D3d12Arena arena) {
        final Pointer<D3d12HeapProperties> heap =
            arena<D3d12HeapProperties>(sizeOf<D3d12HeapProperties>());
        heap.ref
          ..type = heapType
          ..cpuPageProperty = 0
          ..memoryPoolPreference = 0
          ..creationNodeMask = 1
          ..visibleNodeMask = 1;
        final Pointer<D3d12ResourceDesc> desc =
            arena<D3d12ResourceDesc>(sizeOf<D3d12ResourceDesc>());
        desc.ref
          ..dimension = d3d12ResourceDimensionBuffer
          ..alignment = 0
          ..width = bytes
          ..height = 1
          ..depthOrArraySize = 1
          ..mipLevels = 1
          ..format = dxgiFormatUnknown
          ..layout = d3d12TextureLayoutRowMajor
          ..flags = d3d12ResourceFlagNone;
        desc.ref.sampleDesc
          ..count = 1
          ..quality = 0;
        final Pointer<Guid> iid = arena<Guid>(sizeOf<Guid>());
        writeGuid(iid, D3d12Iids.resource);
        final Pointer<Pointer<Void>> out = arena.allocatePointers(1);
        final int hr = _device.nativeDevice.createCommittedResource(
          _device.nativeDevice.pointer,
          heap,
          0,
          desc,
          initialState,
          nullptr,
          iid,
          out,
        );
        return comFailed(hr) ? null : out.value;
      });

  /// Releases every staging buffer the GPU has finished reading.
  void _sweepRetired() {
    if (_retired.isEmpty) return;
    final int completed = _device.frames.completedValue;
    _retired.removeWhere((_RetiredUpload entry) {
      if (entry.fenceValue > completed) return false;
      ComObject(entry.resource).release();
      return true;
    });
  }

  void _evictIfOverBudget(_MeshBufferKey keep) {
    while (_bufferBytes > bufferBudgetBytes && _buffers.length > 1) {
      _MeshBufferKey? oldest;
      var oldestUse = 1 << 62;
      for (final MapEntry<_MeshBufferKey, _MeshBuffers> entry
          in _buffers.entries) {
        if (entry.key == keep) continue;
        if (entry.value.lastUsed >= oldestUse) continue;
        oldestUse = entry.value.lastUsed;
        oldest = entry.key;
      }
      if (oldest == null) return;
      final _MeshBuffers evicted = _buffers.remove(oldest)!;
      _bufferBytes -= evicted.bytes;
      _release(evicted);
    }
  }

  /// Releases a cache entry's buffers once the GPU has finished with them.
  ///
  /// Through [_retired] and not straight away, and for the same reason a
  /// staging buffer goes through it: a frame recorded a draw out of these
  /// buffers at most two frames ago and may still be executing it. The
  /// Direct3D 11 pipeline can `Release` immediately because the runtime tracks
  /// that lifetime for it; here nothing does.
  void _release(_MeshBuffers entry) {
    final int at = _device.frames.signalledValue + 1;
    _retired
      ..add(_RetiredUpload(entry.vertex, at))
      ..add(_RetiredUpload(entry.index, at));
  }

  /// Uploads [texture] once, as `B8G8R8A8_UNORM`.
  ///
  /// The format is the interesting part. [MeshTexture] stores `0xAARRGGBB`
  /// words, and a little-endian word of that lands in memory as B, G, R, A -
  /// which is exactly what `B8G8R8A8_UNORM` reads. Declaring `R8G8B8A8_UNORM`
  /// and uploading the same words would swap red and blue on every textured
  /// model.
  ///
  /// The device's own allocator, so the descriptor lands in the one
  /// shader-visible heap `SetDescriptorHeaps` can name.
  D3d12Texture? _textureFor(MeshTexture texture) {
    final D3d12Texture? cached = _textures[texture];
    if (cached != null) return cached;
    if (texture.width <= 0 || texture.height <= 0) return null;
    final D3d12Texture uploaded;
    try {
      uploaded = _device.createTexture(
        width: texture.width,
        height: texture.height,
        format: GpuTextureFormat.bgra8888Premultiplied,
        filter: GpuTextureFilter.nearest,
      );
    } on Object {
      // A device out of descriptors or out of memory draws the model
      // untextured rather than losing the frame; the material's base colour is
      // still right and the shape is still there.
      return null;
    }
    final int bytes = texture.width * texture.height * 4;
    // A byte view of the words, and `buffer.asUint8List` rather than
    // `Uint8List.sublistView`: the latter's range is in *elements* of the list
    // it views, so asking it for `width * height * 4` of a `Uint32List` asks
    // for four times the texture.
    final Uint8List source = texture.pixels.buffer.asUint8List(
      texture.pixels.offsetInBytes,
      math.min(bytes, texture.pixels.lengthInBytes),
    );
    final Uint8List whole = source.length == bytes
        ? source
        : (Uint8List(bytes)..setRange(0, source.length, source));
    _device.uploadRegion(
      uploaded,
      x: 0,
      y: 0,
      width: texture.width,
      height: texture.height,
      pixels: whole,
      bytesPerRow: texture.width * 4,
    );
    _textures[texture] = uploaded;
    return uploaded;
  }

  // -------------------------------------------------------------------
  // Teardown
  // -------------------------------------------------------------------

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('this D3d12MeshRenderer has been disposed');
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // Every release below frees memory a command list may still be reading, so
    // the GPU has to be idle first. This is the same precondition
    // `ResizeBuffers` has and the same one `D3d12RenderDevice.dispose` honours.
    if (!_device.isLost) _device.frames.waitIdle();
    for (final _MeshBuffers entry in _buffers.values) {
      ComObject(entry.vertex).release();
      ComObject(entry.index).release();
    }
    _buffers.clear();
    _bufferBytes = 0;
    for (final _RetiredUpload entry in _retired) {
      ComObject(entry.resource).release();
    }
    _retired.clear();
    for (final D3d12Texture entry in _textures.values) {
      _device.releaseTexture(entry);
    }
    _textures.clear();
    for (final Pointer<Void> pipeline in _pipelines.values) {
      ComObject(pipeline).release();
    }
    _pipelines.clear();
    if (_depthResource != nullptr) {
      ComObject(_depthResource).release();
      _depthResource = nullptr;
    }
    _dsvHeap?.release();
    _dsvHeap = null;
    if (_rootSignature != nullptr) {
      ComObject(_rootSignature).release();
      _rootSignature = nullptr;
    }
    _vertexBlob?.release();
    _pixelBlob?.release();
    _vertexBlob = null;
    _pixelBlob = null;
    _device.library.allocator
      ..free(_handleSlot)
      ..free(_rtvSlot)
      ..free(_dsvSlot)
      ..free(_viewport)
      ..free(_scissor)
      ..free(_clearColor)
      ..free(_constants)
      ..free(_vertexView)
      ..free(_indexView)
      ..free(_heapSlot)
      ..free(_noRead);
  }
}

/// A staging or geometry buffer and the fence value that makes releasing it
/// legal.
final class _RetiredUpload {
  const _RetiredUpload(this.resource, this.fenceValue);

  final Pointer<Void> resource;
  final int fenceValue;
}

/// Which normals a cached vertex stream carries.
enum _MeshNormalSource {
  /// The file's normals, or smooth ones derived from the faces.
  perVertex,

  /// One normal per triangle, which needs a de-indexed stream.
  perFace,
}

/// Identity of a primitive plus the normals its stream was built with.
final class _MeshBufferKey {
  const _MeshBufferKey(this.primitive, this.source);

  final MeshPrimitive primitive;
  final _MeshNormalSource source;

  @override
  bool operator ==(Object other) =>
      other is _MeshBufferKey &&
      identical(other.primitive, primitive) &&
      other.source == source;

  @override
  int get hashCode => Object.hash(identityHashCode(primitive), source);
}

final class _MeshBuffers {
  _MeshBuffers({
    required this.vertex,
    required this.index,
    required this.vertexAddress,
    required this.indexAddress,
    required this.vertexBytes,
    required this.indexBytes,
    required this.indexCount,
    required this.bytes,
  });

  final Pointer<Void> vertex;
  final Pointer<Void> index;

  /// The virtual addresses, read once at creation. `GetGPUVirtualAddress` is a
  /// vtable call and a buffer's address never changes, so reading it per draw
  /// would be a COM round trip per primitive per frame for a constant.
  final int vertexAddress;
  final int indexAddress;
  final int vertexBytes;
  final int indexBytes;
  final int indexCount;
  final int bytes;

  /// The renderer's monotonic draw counter when this was last used, which is
  /// what makes the eviction least-recently-used rather than arbitrary.
  int lastUsed = 0;
}
