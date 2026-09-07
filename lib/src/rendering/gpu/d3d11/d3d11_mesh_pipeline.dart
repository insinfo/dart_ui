/// The Direct3D 11 mesh pipeline: triangles, a depth buffer and two shaders.
///
/// §8.1.1 of the roadmap says the CPU rasterises when the hardware cannot, when
/// the target is off-screen, or when the library user asked for it.
/// `rendering/mesh/mesh_rasterizer.dart` is none of those on this machine, and
/// this file is what makes the 3D viewer stop being an exception to the
/// framework's own rule. `mesh_scene.dart` holds the contract; this holds the
/// one implementation that talks to a driver.
///
/// ## What it does not share with the 2D path, and why
///
/// Nothing except the device. The 2D pipeline's vertex is two positions, a
/// texture coordinate, a colour and a shape rectangle; its shader has no
/// matrix; its rasteriser state disables culling because a user interface has
/// no back faces; and it binds no depth-stencil view at all outside approach C.
/// Every one of those is wrong for a mesh, so this builds its own program,
/// input layout, rasteriser states, depth-stencil states, sampler and constant
/// buffer, exactly as `D3d11VectorPipeline` does for approaches B and C - and
/// for the same reason: a second set of objects is cheaper than a shared set
/// with a mode switch that some path forgets to set.
///
/// **The depth buffer is this pipeline's own.** A swap chain's back buffer
/// carries no depth-stencil view - `d3d11_vector_replay.dart` says so in its
/// library comment - and the `D24S8` the layer pool allocates belongs to a
/// multisampled layer target and is the wrong size and the wrong dimension. So
/// this allocates a single-sample `D24_UNORM_S8_UINT` matched to the colour
/// target, and reallocates it when the target grows.
///
/// ## Two things that must agree with the CPU rasteriser or the picture is
/// visibly wrong
///
/// The shading is in `d3d11_mesh_shaders.dart` with its own three
/// disagreements. What lives here are the two that are *state* rather than
/// code:
///
///   1. **The winding.** `MeshRasterizer._drawProjected` computes twice the
///      signed area in screen space, where y points **down** because `_screen`
///      flipped it, and calls a positive area back-facing. In render-target
///      space with y down, a positive area by that formula is a triangle that
///      reads clockwise on screen, which is what Direct3D calls front-facing
///      with `FrontCounterClockwise = FALSE`. The two conventions are therefore
///      opposite, and this pipeline sets `FrontCounterClockwise = TRUE` so they
///      agree. Getting it backwards culls exactly the triangles the CPU keeps:
///      the model is drawn inside out and looks hollow, which reads as a
///      normals bug and is not. `SV_IsFrontFace` in the pixel stage follows the
///      same flag, so the reversed normal a double-sided back face gets is the
///      same face on both paths.
///   2. **The depth test.** `LESS`, writing enabled, against a buffer cleared
///      to 1. The CPU clears its depth to `double.infinity` and rejects on
///      `>=`, which is the same rule; the one place they differ is a fragment
///      exactly on the far plane, which the CPU keeps and `LESS` against a
///      cleared 1 rejects. `MeshCamera.frame` puts the far plane at ten times
///      the camera distance, so nothing a viewer opens is there.
///
/// ## The caches, and the traffic they exist to stop
///
/// A 451,838-triangle model is 43 MB of vertices and 5.4 MB of indices. Sending
/// that per frame at 60 Hz is about 3 GB/s of bus traffic for geometry that
/// never changed, and it is what a first draft of a GPU mesh path always does.
/// So vertex and index buffers are `D3D11_USAGE_IMMUTABLE`, uploaded once per
/// primitive, keyed by the primitive's identity, and evicted least-recently-used
/// when the total passes [D3d11MeshRenderer.bufferBudgetBytes]. Textures are
/// cached the same way and keyed on the `MeshTexture`.
///
/// The cache key carries the **normal source** as well as the primitive,
/// because `MeshShading.flat` needs a different vertex stream: a face normal is
/// not a property of a vertex, so a flat-shaded mesh is de-indexed - three
/// vertices per triangle, each carrying its own face's normal. That is the one
/// shading mode that costs memory, it is not the default, and the cost is
/// stated here rather than discovered from a 130 MB allocation.
library;

import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../../ffi/com.dart';
import '../../../ffi/native_memory.dart';
import '../../../foundation/diagnostics.dart';
import '../../../geometry/rect.dart';
import '../../../graphics/mesh/mesh3d.dart';
import '../../mesh/mesh_rasterizer.dart';
import '../../mesh/mesh_scene.dart';
import '../../renderer.dart';
import 'd3d11_backend.dart';
import 'd3d11_bindings.dart';
import 'd3d11_mesh_shaders.dart';
import 'd3d11_window_target.dart';

/// How the depth test compares, so a test can break it on purpose.
///
/// A parity test that cannot fail proves nothing, and the two ways this
/// pipeline can be wrong without crashing are the depth comparison and the
/// winding. Both are exposed as switches rather than reached by editing the
/// source, because a test that edits the source is a test nobody runs twice.
enum D3d11MeshDepthTest {
  /// Nearer fragments win: the correct one, and `MeshRasterizer`'s rule.
  less,

  /// Farther fragments win, which draws the model inside out through itself.
  greater,

  /// No depth test at all: whatever was submitted last is on top.
  always,
}

/// Draws a [MeshScene] with Direct3D 11.
///
/// One per device. It owns GPU objects, so it must be disposed before the
/// device it was built from - and it does *not* register itself for device-loss
/// recovery, which is a limitation stated rather than hidden: after a
/// `DXGI_ERROR_DEVICE_REMOVED` every buffer, texture and state object here
/// belongs to a device that no longer exists, and the honest recovery is for
/// the application to dispose this renderer and build another. Wiring it into
/// [D3d11RenderDevice.recoverableResources] needs the device to know a mesh
/// renderer exists, which is precisely the coupling this file avoids.
final class D3d11MeshRenderer implements MeshSceneRenderer {
  D3d11MeshRenderer._(this._device, this._objects);

  /// Builds the pipeline for [device], or returns the [BackendDiagnostic] that
  /// says what the driver refused.
  ///
  /// A diagnostic and not a throw, matching `D3d11VectorPipeline.create`: a
  /// caller that cannot get a mesh pipeline wants to fall back to the CPU
  /// rasteriser with a reason to print, not to lose its window.
  static Object create(D3d11RenderDevice device) {
    final D3dCompileFn? compile = device.api.compile;
    if (compile == null) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.missingLibrary,
        message: 'd3dcompiler_47.dll is not loadable, so there is no mesh '
            'program',
        detail: 'this backend compiles its HLSL at run time; see '
            'D3d11RendererBackend.shaderCompilationPolicy for why',
      );
    }
    final arena = NativeArena();
    final renderer = D3d11MeshRenderer._(device, ComBag());
    try {
      final Object vertex = _compile(
          compile, arena, kD3d11MeshVertexProfile, kD3d11MeshVertexEntryPoint);
      if (vertex is BackendDiagnostic) return vertex;
      final Object pixel = _compile(
          compile, arena, kD3d11MeshPixelProfile, kD3d11MeshPixelEntryPoint);
      if (pixel is BackendDiagnostic) {
        (vertex as D3dBlob).dispose();
        return pixel;
      }
      final vertexBlob = vertex as D3dBlob;
      final pixelBlob = pixel as D3dBlob;
      try {
        final BackendDiagnostic? failure =
            renderer._build(arena, vertexBlob, pixelBlob);
        if (failure != null) {
          renderer.dispose();
          return failure;
        }
      } finally {
        vertexBlob.dispose();
        pixelBlob.dispose();
      }
      return renderer;
    } on Object catch (error) {
      renderer.dispose();
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the Direct3D 11 mesh pipeline could not be built',
        detail: '$error',
      );
    } finally {
      arena.dispose();
    }
  }

  final D3d11RenderDevice _device;
  final ComBag _objects;

  /// Long-lived native scratch, so a frame performs no native allocation. The
  /// rule the rest of this backend already keeps.
  final NativeArena _arena = NativeArena();

  /// 512 bytes for one descriptor at a time, sized by the same argument
  /// `D3d11VectorPipeline._desc` makes: `D3D11_BLEND_DESC` is 264 bytes and a
  /// 256-byte block overruns into whatever the arena handed out next, which
  /// surfaces as a Dart heap crash minutes later in unrelated code.
  late final Pointer<Uint8> _desc = _arena.allocate<Uint8>(512);
  late final Pointer<Pointer<Void>> _out = _arena.allocateOutPointer();
  late final Pointer<Pointer<Void>> _slot = _arena.allocateOutPointer();
  late final Pointer<Uint32> _uint = _arena.allocate<Uint32>(16);
  late final Pointer<Uint32> _uintB = _arena.allocate<Uint32>(16);
  late final Pointer<Float> _float4 = _arena.allocate<Float>(16);
  late final Pointer<Uint8> _constants =
      _arena.allocate<Uint8>(kD3d11MeshConstantBytes);

  ComObject? _vertexShader;
  ComObject? _pixelShader;
  ComObject? _inputLayout;
  ComObject? _constantBuffer;
  ComObject? _sampler;
  ComObject? _blendOpaque;

  /// Rasteriser states by [_rasterizerKey]: fill mode and cull mode.
  final Map<int, ComObject> _rasterizerStates = <int, ComObject>{};

  /// Depth-stencil states by [D3d11MeshDepthTest.index], plus the depth-off
  /// state at [_depthOffKey] that [drawScene] leaves bound on the way out.
  final Map<int, ComObject> _depthStates = <int, ComObject>{};
  static const int _depthOffKey = -1;

  /// The pipeline's own depth buffer, and the size it was allocated for.
  ComObject? _depthTexture;
  ComObject? _depthView;
  int _depthWidth = 0;
  int _depthHeight = 0;

  final Map<_MeshBufferKey, _MeshBuffers> _buffers =
      <_MeshBufferKey, _MeshBuffers>{};
  final Map<MeshTexture, _MeshTextureUpload> _textures =
      <MeshTexture, _MeshTextureUpload>{};
  int _bufferBytes = 0;
  int _clock = 0;
  bool _disposed = false;

  /// Bytes of cached vertex and index buffers before the least recently drawn
  /// primitive is evicted.
  ///
  /// 384 MiB, which is one 451,838-triangle model smooth-shaded (48 MB) and the
  /// same model flat-shaded (130 MB) with room for a second model beside them,
  /// and is well under what any adapter this backend opens on has. It is
  /// settable because a viewer that opens one model at a time wants it smaller
  /// and a scene graph wants it larger, and because a test that wants to prove
  /// eviction happens has to be able to make it happen.
  int bufferBudgetBytes = 384 * 1024 * 1024;

  /// How the depth test compares. Correct at [D3d11MeshDepthTest.less].
  ///
  /// Public so `d3d11_mesh_cpu_parity_test.dart` can prove its own tolerance
  /// can fail. Nothing in a frame writes it.
  D3d11MeshDepthTest depthTest = D3d11MeshDepthTest.less;

  /// Whether a counter-clockwise triangle in render-target space is the front
  /// face. True is correct; see the winding argument in the library comment.
  ///
  /// Public for the same reason [depthTest] is: flipping it is the sabotage
  /// that leaves a closed model hollow, and a parity test that cannot observe
  /// that is not measuring the winding at all.
  bool frontCounterClockwise = true;

  /// Buffers currently resident, for a test that asserts an upload happened
  /// once rather than per frame.
  int get cachedPrimitiveCount => _buffers.length;

  /// Bytes of vertex and index data resident on the device.
  int get cachedBufferBytes => _bufferBytes;

  /// `CreateBuffer` calls this renderer has made for geometry.
  ///
  /// The number that says the cache works. A viewer orbiting one model for a
  /// hundred frames must leave this at the primitive count; a frame that
  /// re-uploads is the 200 MB/s this whole arrangement exists to stop, and it
  /// is invisible in the picture.
  int get bufferUploadCount => _bufferUploadCount;
  int _bufferUploadCount = 0;

  // -------------------------------------------------------------------
  // Construction
  // -------------------------------------------------------------------

  BackendDiagnostic? _build(
    NativeArena arena,
    D3dBlob vertexBlob,
    D3dBlob pixelBlob,
  ) {
    final D3d11Device device = _device.device;
    final int vsHr = hresult(device.createVertexShader(device.pointer,
        vertexBlob.bufferPointer, vertexBlob.bufferSize, nullptr, _out));
    if (failed(vsHr)) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'CreateVertexShader refused the mesh bytecode',
        detail: hresultName(vsHr),
      );
    }
    _vertexShader = _objects
        .keep(ComObject(_out.value, interfaceName: 'ID3D11VertexShader'));

    final int psHr = hresult(device.createPixelShader(device.pointer,
        pixelBlob.bufferPointer, pixelBlob.bufferSize, nullptr, _out));
    if (failed(psHr)) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'CreatePixelShader refused the mesh bytecode',
        detail: hresultName(psHr),
      );
    }
    _pixelShader = _objects
        .keep(ComObject(_out.value, interfaceName: 'ID3D11PixelShader'));

    const List<int> formats = <int>[
      dxgiFormatR32G32B32Float,
      dxgiFormatR32G32B32Float,
      dxgiFormatR32G32Float,
    ];
    const List<int> offsets = <int>[
      kD3d11MeshPositionOffset,
      kD3d11MeshNormalOffset,
      kD3d11MeshTexCoordOffset,
    ];
    final Pointer<Uint8> elements =
        arena.allocate<Uint8>(sizeOfInputElementDesc * formats.length);
    for (var i = 0; i < formats.length; i++) {
      final Pointer<Uint8> element = Pointer<Uint8>.fromAddress(
          elements.address + i * sizeOfInputElementDesc);
      element.cast<IntPtr>()[0] =
          arena.allocateAscii(kD3d11MeshSemanticNames[i]).address;
      final fields = Pointer<Uint32>.fromAddress(element.address + 8);
      fields[0] = kD3d11MeshSemanticIndices[i];
      fields[1] = formats[i];
      fields[2] = 0; // InputSlot
      fields[3] = offsets[i]; // AlignedByteOffset
      fields[4] = d3d11InputPerVertexData;
      fields[5] = 0; // InstanceDataStepRate
    }
    final int layoutHr = hresult(device.createInputLayout(
      device.pointer,
      elements.cast(),
      formats.length,
      vertexBlob.bufferPointer,
      vertexBlob.bufferSize,
      _out,
    ));
    if (failed(layoutHr)) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the mesh input layout does not match the vertex shader',
        detail: '${hresultName(layoutHr)}; the layout is POSITION0 float3, '
            'NORMAL0 float3 and TEXCOORD0 float2 in a '
            '$kD3d11MeshVertexStrideBytes-byte vertex',
      );
    }
    _inputLayout = _objects
        .keep(ComObject(_out.value, interfaceName: 'ID3D11InputLayout'));

    final desc = _desc.cast<Uint32>();
    desc[0] = kD3d11MeshConstantBytes;
    desc[1] = d3d11UsageDefault;
    desc[2] = d3d11BindConstantBuffer;
    desc[3] = 0;
    desc[4] = 0;
    desc[5] = 0;
    final int cbHr = hresult(
        device.createBuffer(device.pointer, _desc.cast(), nullptr, _out));
    if (failed(cbHr)) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the mesh constant buffer could not be created',
        detail: hresultName(cbHr),
      );
    }
    _constantBuffer =
        _objects.keep(ComObject(_out.value, interfaceName: 'ID3D11Buffer'));

    final BackendDiagnostic? sampler = _createSampler();
    if (sampler != null) return sampler;
    return _createBlendState();
  }

  /// Point filtering and `REPEAT`, because that is what [MeshTexture] does.
  ///
  /// Nearest neighbour is a choice the CPU sampler argues for and this has to
  /// copy it whether or not it agrees: a linear tap here would be a *better*
  /// picture that no parity test could accept, and the two paths differing in
  /// filtering is exactly the kind of divergence that gets blamed on the
  /// geometry. Wrapping is `REPEAT` for the reason glTF and OBJ both default to
  /// it - a model that tiles a floor has UVs outside the unit square, and
  /// clamping smears the edge texel across it.
  BackendDiagnostic? _createSampler() {
    final desc = _desc.cast<Uint32>();
    for (var i = 0; i < sizeOfSamplerDesc ~/ 4; i++) {
      desc[i] = 0;
    }
    desc[0] = d3d11FilterMinMagMipPoint;
    desc[1] = d3d11TextureAddressWrap;
    desc[2] = d3d11TextureAddressWrap;
    desc[3] = d3d11TextureAddressWrap;
    _desc.cast<Float>()[4] = 0; // MipLODBias
    desc[5] = 1; // MaxAnisotropy
    desc[6] = d3d11ComparisonNever;
    // BorderColor stays zero; MinLOD 0 at float 11, MaxLOD at float 12.
    // FLT_MAX written as the literal the header uses: `double.infinity` is a
    // different bit pattern and makes CreateSamplerState return E_INVALIDARG.
    _desc.cast<Float>()[12] = 3.402823466e+38;
    final int hr = hresult(_device.device
        .createSamplerState(_device.device.pointer, _desc.cast(), _out));
    if (failed(hr)) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the mesh sampler could not be created',
        detail: hresultName(hr),
      );
    }
    _sampler = _objects
        .keep(ComObject(_out.value, interfaceName: 'ID3D11SamplerState'));
    return null;
  }

  /// Blending off, all four channels written.
  ///
  /// Not a matter of taste and not inherited from the 2D path: `MeshRasterizer`
  /// writes `argb | 0xFF000000` at every pixel that passes the depth test, so
  /// the model is opaque by construction. A device that arrived here with the
  /// 2D source-over state still bound would blend the model against whatever
  /// the 2D pass left, which on a cleared target is invisible and on a target
  /// with an interface on it is not.
  BackendDiagnostic? _createBlendState() {
    final desc = _desc.cast<Uint32>();
    for (var i = 0; i < sizeOfBlendDesc ~/ 4; i++) {
      desc[i] = 0;
    }
    const int rt0 = 8 ~/ 4;
    desc[rt0 + 0] = 0; // BlendEnable
    desc[rt0 + 1] = d3d11BlendOne;
    desc[rt0 + 2] = d3d11BlendZero;
    desc[rt0 + 3] = d3d11BlendOpAdd;
    desc[rt0 + 4] = d3d11BlendOne;
    desc[rt0 + 5] = d3d11BlendZero;
    desc[rt0 + 6] = d3d11BlendOpAdd;
    desc[rt0 + 7] = d3d11ColorWriteEnableAll;
    final int hr = hresult(_device.device
        .createBlendState(_device.device.pointer, _desc.cast(), _out));
    if (failed(hr)) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the opaque blend state for meshes could not be created',
        detail: hresultName(hr),
      );
    }
    _blendOpaque =
        _objects.keep(ComObject(_out.value, interfaceName: 'ID3D11BlendState'));
    return null;
  }

  static Object _compile(
    D3dCompileFn compile,
    NativeArena arena,
    String profile,
    String entryPoint,
  ) {
    final Pointer<Uint8> source = arena.allocateAscii(kD3d11MeshShaderSource);
    final Pointer<Pointer<Void>> code = arena.allocateOutPointer();
    final Pointer<Pointer<Void>> errors = arena.allocateOutPointer();
    final int hr = hresult(compile(
      source,
      kD3d11MeshShaderSource.length,
      arena.allocateAscii('dart_ui_d3d11_mesh.hlsl'),
      nullptr,
      nullptr,
      arena.allocateAscii(entryPoint),
      arena.allocateAscii(profile),
      // Row-major, so the four `float4x4` registers are the matrix's rows and
      // the Dart side can transpose once. See d3d11_shaders.dart,
      // "Disagreement 2", which declared this flag for exactly the day a matrix
      // appeared in a constant buffer.
      d3dCompilePackMatrixRowMajor |
          d3dCompileEnableStrictness |
          d3dCompileOptimizationLevel3,
      0,
      code,
      errors,
    ));
    String message = '';
    if (errors.value != nullptr) {
      final blob = D3dBlob(errors.value);
      message = blob.asText;
      blob.dispose();
    }
    if (failed(hr) || code.value == nullptr) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: '$entryPoint failed to compile as $profile',
        // The compiler's own message, verbatim. Anything less turns a one-line
        // HLSL error into an afternoon.
        detail: '${hresultName(hr)}: $message',
      );
    }
    return D3dBlob(code.value);
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
    final _MeshColorTarget? colour = _colorTargetOf(target);
    if (colour == null || _device.state.isLost) return MeshRenderStats.zero;
    return drawInto(
      colour.view,
      targetWidth: colour.width,
      targetHeight: colour.height,
      scene: scene,
      viewport: viewport,
    );
  }

  /// The Direct3D 11 entry point behind [drawScene], for a caller that already
  /// holds a render-target view.
  ///
  /// Separate from [drawScene] because the interface cannot name a
  /// `Pointer<Void>` and the offscreen probes want to draw into a view they
  /// created themselves. [drawScene] is the one an application uses.
  MeshRenderStats drawInto(
    Pointer<Void> renderTargetView, {
    required int targetWidth,
    required int targetHeight,
    required MeshScene scene,
    Rect? viewport,
  }) {
    _throwIfDisposed();
    if (renderTargetView == nullptr ||
        targetWidth <= 0 ||
        targetHeight <= 0 ||
        _device.state.isLost) {
      return MeshRenderStats.zero;
    }
    final Stopwatch watch = Stopwatch()..start();
    final Rect box = viewport ??
        Rect.fromLTWH(0, 0, targetWidth.toDouble(), targetHeight.toDouble());
    final double width = box.width;
    final double height = box.height;
    if (width <= 0 || height <= 0) return MeshRenderStats.zero;

    if (!_ensureDepth(targetWidth, targetHeight)) return MeshRenderStats.zero;
    final D3d11DeviceContext context = _device.context;
    _slot.value = renderTargetView;
    context
      ..omSetRenderTargets(context.pointer, 1, _slot, _depthView!.pointer)
      ..clearDepthStencilView(
          context.pointer, _depthView!.pointer, d3d11ClearDepth, 1, 0);
    final int? background = scene.backgroundArgb;
    if (background != null) {
      // The whole view, not the viewport. `ClearRenderTargetView` takes no
      // rectangle and ignores the scissor, which is the same semantics
      // `MeshRasterizer.render` has - it clears the framebuffer it was given.
      _float4[0] = ((background >> 16) & 0xFF) / 255.0;
      _float4[1] = ((background >> 8) & 0xFF) / 255.0;
      _float4[2] = (background & 0xFF) / 255.0;
      _float4[3] = ((background >> 24) & 0xFF) / 255.0;
      context.clearRenderTargetView(context.pointer, renderTargetView, _float4);
    }

    final view = _desc.cast<Float>();
    view[0] = box.left;
    view[1] = box.top;
    view[2] = width;
    view[3] = height;
    view[4] = 0; // MinDepth
    view[5] = 1; // MaxDepth
    context.rsSetViewports(context.pointer, 1, _desc.cast());
    final rect = _desc.cast<Int32>();
    rect[0] = box.left.floor().clamp(0, targetWidth);
    rect[1] = box.top.floor().clamp(0, targetHeight);
    rect[2] = box.right.ceil().clamp(0, targetWidth);
    rect[3] = box.bottom.ceil().clamp(0, targetHeight);
    context.rsSetScissorRects(context.pointer, 1, _desc.cast());

    _slot.value = _constantBuffer!.pointer;
    for (var i = 0; i < 4; i++) {
      _float4[i] = 0;
    }
    context
      ..iaSetInputLayout(context.pointer, _inputLayout!.pointer)
      ..iaSetPrimitiveTopology(
          context.pointer, d3d11PrimitiveTopologyTriangleList)
      ..vsSetShader(context.pointer, _vertexShader!.pointer, nullptr, 0)
      ..psSetShader(context.pointer, _pixelShader!.pointer, nullptr, 0)
      ..vsSetConstantBuffers(context.pointer, 0, 1, _slot)
      ..psSetConstantBuffers(context.pointer, 0, 1, _slot)
      ..omSetBlendState(
          context.pointer, _blendOpaque!.pointer, _float4, 0xFFFFFFFF)
      ..omSetDepthStencilState(
          context.pointer, _depthStateFor(depthTest.index).pointer, 0);
    _slot.value = _sampler!.pointer;
    context.psSetSamplers(context.pointer, 0, 1, _slot);

    final Matrix4 viewMatrix = scene.camera.viewMatrix();
    final Matrix4 projection = scene.camera.projectionMatrix(width / height);
    final Matrix4 viewProjection = projection.multiply(viewMatrix);
    final Vector3 light = scene.lightDirection.normalized;
    final bool lit = scene.shading != MeshShading.unlit &&
        scene.shading != MeshShading.wireframe;
    final bool wireframe = scene.shading == MeshShading.wireframe;

    var triangles = 0;
    for (final MeshPrimitive primitive in scene.mesh.primitives) {
      triangles += primitive.triangleCount;
      final _MeshBuffers? buffers = _buffersFor(primitive, scene.shading);
      if (buffers == null) continue;
      final MeshTexture? texture = wireframe
          ? null
          : (primitive.uvs == null
              ? null
              : primitive.material.baseColorTexture);
      final _MeshTextureUpload? uploaded =
          texture == null ? null : _textureFor(texture);
      _writeConstants(
        viewProjection,
        light,
        scene.ambient,
        primitive.material.colorArgb,
        lit: lit,
        textured: uploaded != null,
      );
      _slot.value = uploaded?.view.pointer ?? nullptr;
      context
        ..psSetShaderResources(context.pointer, 0, 1, _slot)
        ..rsSetState(
            context.pointer,
            _rasterizerStateFor(
              cull: !primitive.material.doubleSided,
              wireframe: wireframe,
            ).pointer);
      _slot.value = buffers.vertices.pointer;
      _uint[0] = kD3d11MeshVertexStrideBytes;
      _uintB[0] = 0;
      context
        ..iaSetVertexBuffers(context.pointer, 0, 1, _slot, _uint, _uintB)
        ..iaSetIndexBuffer(
            context.pointer, buffers.indices.pointer, dxgiFormatR32Uint, 0)
        ..drawIndexed(context.pointer, buffers.indexCount, 0, 0);
    }

    // Put the device back the way a 2D pass expects to find it. Two of these
    // are not tidiness: a depth-stencil view left attached would make every
    // following dense batch depth-test against a plane the mesh wrote, and a
    // depth state left at `LESS` would do the same on a device that never binds
    // one - `D3d11RenderDevice._bindPipeline` only binds the depth-off state
    // when the vector routes were built. The symptom is a 2D frame that draws
    // nothing where the model was.
    _slot.value = renderTargetView;
    context.omSetRenderTargets(context.pointer, 1, _slot, nullptr);
    context.omSetDepthStencilState(
        context.pointer, _depthStateFor(_depthOffKey).pointer, 0);
    _slot.value = nullptr;
    context.psSetShaderResources(context.pointer, 0, 1, _slot);

    watch.stop();
    return gpuMeshStats(
      triangles: triangles,
      microseconds: watch.elapsedMicroseconds,
    );
  }

  /// The colour view and pixel size behind [target], or null when this renderer
  /// was handed a target belonging to another backend.
  ///
  /// The one place this file knows about concrete target types, and it is
  /// unavoidable: `MeshSceneRenderer` promises to take a [RenderTarget] so that
  /// the OpenGL twin can implement the same method, which means each backend
  /// has to recognise its own.
  _MeshColorTarget? _colorTargetOf(RenderTarget target) => switch (target) {
        D3d11WindowTarget() => _MeshColorTarget(
            target.surface.swapChain.backBufferView,
            target.surface.pixelWidth,
            target.surface.pixelHeight,
          ),
        D3d11OffscreenTarget() => _MeshColorTarget(
            target.colorRenderTargetView,
            target.surface.pixelWidth,
            target.surface.pixelHeight,
          ),
        _ => null,
      };

  /// Writes the ten constant registers.
  ///
  /// The transpose is the whole reason this is not a `setAll`: [Matrix4] stores
  /// column-major, like glTF and OpenGL, and the shader is compiled with
  /// row-major packing, so register `i` is row `i` and `row i, column j` lives
  /// at `storage[j * 4 + i]`. Getting it wrong is a model transformed by the
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
    final values = _constants.cast<Float>();
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
    final D3d11DeviceContext context = _device.context;
    context.updateSubresource(context.pointer, _constantBuffer!.pointer, 0,
        nullptr, _constants.cast(), 0, 0);
  }

  // -------------------------------------------------------------------
  // State objects
  // -------------------------------------------------------------------

  static int _rasterizerKey({required bool cull, required bool wireframe}) =>
      (cull ? 1 : 0) | (wireframe ? 2 : 0);

  ComObject _rasterizerStateFor({
    required bool cull,
    required bool wireframe,
  }) {
    // The winding flag is part of the key so that flipping
    // [frontCounterClockwise] mid-run builds a second state rather than
    // returning the first one and silently ignoring the change - which would
    // make the sabotage test pass by doing nothing.
    final int key = _rasterizerKey(cull: cull, wireframe: wireframe) |
        (frontCounterClockwise ? 4 : 0);
    final ComObject? cached = _rasterizerStates[key];
    if (cached != null) return cached;
    final rast = _desc.cast<Uint32>();
    rast[0] = wireframe ? d3d11FillWireframe : d3d11FillSolid;
    // BACK, paired with FrontCounterClockwise below. `MeshRasterizer` culls the
    // triangle whose screen-space signed area is positive, which with y down is
    // the clockwise one; declaring counter-clockwise to be the front makes
    // Direct3D's "back" the same set of triangles.
    rast[1] = cull ? d3d11CullBack : d3d11CullNone;
    rast[2] = frontCounterClockwise ? 1 : 0;
    rast[3] = 0; // DepthBias
    _desc.cast<Float>()[4] = 0; // DepthBiasClamp
    _desc.cast<Float>()[5] = 0; // SlopeScaledDepthBias
    // DepthClipEnable, which is the near plane. `MeshRasterizer` clips its
    // polygons against `w > near` by hand; here the hardware does it, at the
    // same plane, because the vertex stage's depth remap put `w = near` at
    // `z = 0`.
    rast[6] = 1;
    rast[7] = 1; // ScissorEnable, so a viewport smaller than the target holds.
    rast[8] = 0; // MultisampleEnable
    rast[9] = 0; // AntialiasedLineEnable
    checkHresult(
      _device.device
          .createRasterizerState(_device.device.pointer, _desc.cast(), _out),
      'ID3D11Device::CreateRasterizerState(mesh)',
    );
    final state = ComObject(_out.value, interfaceName: 'ID3D11RasterizerState');
    _objects.keep(state);
    _rasterizerStates[key] = state;
    return state;
  }

  ComObject _depthStateFor(int key) {
    final ComObject? cached = _depthStates[key];
    if (cached != null) return cached;
    final desc = _desc.cast<Uint32>();
    for (var i = 0; i < sizeOfDepthStencilDesc ~/ 4; i++) {
      desc[i] = 0;
    }
    final bool off = key == _depthOffKey;
    desc[0] = off ? 0 : 1; // DepthEnable
    desc[1] = off ? d3d11DepthWriteMaskZero : d3d11DepthWriteMaskAll;
    desc[2] = off
        ? d3d11ComparisonAlways
        : switch (D3d11MeshDepthTest.values[key]) {
            D3d11MeshDepthTest.less => d3d11ComparisonLess,
            D3d11MeshDepthTest.greater => d3d11ComparisonGreater,
            D3d11MeshDepthTest.always => d3d11ComparisonAlways,
          };
    desc[3] = 0; // StencilEnable
    // The stencil operations still have to name legal enum values or the
    // descriptor is rejected, even with the test disabled.
    desc[5] = d3d11StencilOpKeep;
    desc[6] = d3d11StencilOpKeep;
    desc[7] = d3d11StencilOpKeep;
    desc[8] = d3d11ComparisonAlways;
    desc[9] = d3d11StencilOpKeep;
    desc[10] = d3d11StencilOpKeep;
    desc[11] = d3d11StencilOpKeep;
    desc[12] = d3d11ComparisonAlways;
    checkHresult(
      _device.device
          .createDepthStencilState(_device.device.pointer, _desc.cast(), _out),
      'ID3D11Device::CreateDepthStencilState(mesh)',
    );
    final state =
        ComObject(_out.value, interfaceName: 'ID3D11DepthStencilState');
    _objects.keep(state);
    _depthStates[key] = state;
    return state;
  }

  /// Allocates the depth buffer, or grows it to cover the target.
  ///
  /// Grown and never shrunk, and matched to the *target* rather than to the
  /// viewport: Direct3D requires every view bound to the output-merger to have
  /// the same dimensions, so a depth buffer sized to a sub-rectangle viewport
  /// would be rejected outright.
  bool _ensureDepth(int width, int height) {
    if (_depthView != null && _depthWidth == width && _depthHeight == height) {
      return true;
    }
    _depthView?.dispose();
    _depthTexture?.dispose();
    _depthView = null;
    _depthTexture = null;
    _depthWidth = 0;
    _depthHeight = 0;

    final desc = _desc.cast<Uint32>();
    desc[0] = width;
    desc[1] = height;
    desc[2] = 1; // MipLevels
    desc[3] = 1; // ArraySize
    desc[4] = dxgiFormatD24UnormS8Uint;
    desc[5] = 1; // SampleDesc.Count
    desc[6] = 0; // SampleDesc.Quality
    desc[7] = d3d11UsageDefault;
    desc[8] = d3d11BindDepthStencil;
    desc[9] = 0; // CPUAccessFlags
    desc[10] = 0; // MiscFlags
    final int textureHr = hresult(_device.device
        .createTexture2D(_device.device.pointer, _desc.cast(), nullptr, _out));
    if (failed(textureHr) || _out.value == nullptr) return false;
    final texture = ComObject(_out.value, interfaceName: 'ID3D11Texture2D');

    final dsv = _desc.cast<Uint32>();
    for (var i = 0; i < sizeOfDepthStencilViewDesc ~/ 4; i++) {
      dsv[i] = 0;
    }
    dsv[0] = dxgiFormatD24UnormS8Uint;
    dsv[1] = d3d11DsvDimensionTexture2d;
    dsv[2] = 0; // Flags: read/write, because the depth test writes.
    final int viewHr = hresult(_device.device.createDepthStencilView(
        _device.device.pointer, texture.pointer, _desc.cast(), _out));
    if (failed(viewHr) || _out.value == nullptr) {
      texture.dispose();
      return false;
    }
    _depthTexture = texture;
    _depthView = ComObject(_out.value, interfaceName: 'ID3D11DepthStencilView');
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
        entry.dispose();
      }
      final MeshTexture? texture = primitive.material.baseColorTexture;
      if (texture != null) _textures.remove(texture)?.dispose();
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
        Float32List(vertexCount * (kD3d11MeshVertexStrideBytes ~/ 4));
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
  /// flat shading through a shared vertex buffer. HLSL's `nointerpolation`
  /// would give the provoking vertex's attribute, and the provoking vertex has
  /// no face normal either. Computing it from screen-space derivatives of the
  /// interpolated position is the other option and it recovers the plane's
  /// normal only up to a sign that depends on the winding - a subtlety with no
  /// upside, since this costs memory once and is exact.
  ///
  /// The cross product is `(b - a) x (c - a)` normalised, character for
  /// character `MeshRasterizer._drawProjected`'s `faceNormalOf`.
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
    final ComObject? vertexBuffer = _immutableBuffer(
        vertices, vertices.lengthInBytes, d3d11BindVertexBuffer);
    if (vertexBuffer == null) return null;
    final ComObject? indexBuffer =
        _immutableBuffer(indices, indices.lengthInBytes, d3d11BindIndexBuffer);
    if (indexBuffer == null) {
      vertexBuffer.dispose();
      return null;
    }
    return _MeshBuffers(
      vertices: vertexBuffer,
      indices: indexBuffer,
      indexCount: indices.length,
      bytes: vertices.lengthInBytes + indices.lengthInBytes,
    );
  }

  /// An immutable buffer holding [bytes] from [source].
  ///
  /// `D3D11_USAGE_IMMUTABLE`, which is the whole point of the cache on this
  /// API: the geometry is never written again, so the driver is free to put it
  /// wherever it reads fastest. A dynamic buffer would be re-uploaded and
  /// re-orphaned on every frame that changed nothing.
  ///
  /// The staging block is native memory in an arena of its own, disposed on the
  /// way out. Two reasons, and the second is the one that bites: a
  /// `Float32List` lives on the Dart heap and its address is not stable across
  /// a call that may allocate, and [NativeArena.free] is a documented no-op -
  /// taking the block from the renderer's long-lived arena would hold 43 MB per
  /// upload for the life of the renderer.
  ComObject? _immutableBuffer(TypedData source, int bytes, int bindFlags) {
    if (bytes <= 0) return null;
    final staging0 = NativeArena();
    final Pointer<Uint8> staging = staging0.allocate<Uint8>(bytes);
    try {
      staging
          .asTypedList(bytes)
          .setAll(0, source.buffer.asUint8List(source.offsetInBytes, bytes));
      final desc = _desc.cast<Uint32>();
      desc[0] = bytes;
      desc[1] = d3d11UsageImmutable;
      desc[2] = bindFlags;
      desc[3] = 0;
      desc[4] = 0;
      desc[5] = 0;
      final Pointer<Uint8> initial =
          Pointer<Uint8>.fromAddress(_desc.address + 64);
      initial.cast<IntPtr>()[0] = staging.address;
      Pointer<Uint32>.fromAddress(initial.address + 8)[0] = 0;
      Pointer<Uint32>.fromAddress(initial.address + 12)[0] = 0;
      final int hr = hresult(_device.device.createBuffer(
          _device.device.pointer, _desc.cast(), initial.cast(), _out));
      if (failed(hr) || _out.value == nullptr) return null;
      _bufferUploadCount++;
      return ComObject(_out.value, interfaceName: 'ID3D11Buffer');
    } finally {
      staging0.dispose();
    }
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
      evicted.dispose();
    }
  }

  /// Uploads [texture] once, as `B8G8R8A8_UNORM`.
  ///
  /// The format is the interesting part. [MeshTexture] stores `0xAARRGGBB`
  /// words, and a little-endian word of that lands in memory as B, G, R, A -
  /// which is exactly what `B8G8R8A8_UNORM` reads. Declaring `R8G8B8A8_UNORM`
  /// and uploading the same words would swap red and blue on every textured
  /// model, which is the same coincidence, and the same trap,
  /// `MeshRasterizer._wordsOf` documents for the framebuffer.
  _MeshTextureUpload? _textureFor(MeshTexture texture) {
    final _MeshTextureUpload? cached = _textures[texture];
    if (cached != null) return cached;
    if (texture.width <= 0 || texture.height <= 0) return null;
    final int bytes = texture.width * texture.height * 4;
    // Its own arena, for the reason [_immutableBuffer] gives: a 4096x4096
    // base-colour map is 64 MB, and `NativeArena.free` does nothing.
    final staging0 = NativeArena();
    final Pointer<Uint8> staging = staging0.allocate<Uint8>(bytes);
    try {
      // A byte view of the words, and `buffer.asUint8List` rather than
      // `Uint8List.sublistView`: the latter's range is in *elements* of the
      // list it views, so asking it for `width * height * 4` of a `Uint32List`
      // asks for four times the texture.
      final Uint8List source = texture.pixels.buffer.asUint8List(
        texture.pixels.offsetInBytes,
        math.min(bytes, texture.pixels.lengthInBytes),
      );
      staging.asTypedList(bytes).setRange(0, source.length, source);
      final desc = _desc.cast<Uint32>();
      desc[0] = texture.width;
      desc[1] = texture.height;
      desc[2] = 1; // MipLevels: one, because the sampler is point-filtered and
      desc[3] = 1; // a mip chain would be levels nothing can select.
      desc[4] = dxgiFormatB8G8R8A8Unorm;
      desc[5] = 1;
      desc[6] = 0;
      desc[7] = d3d11UsageImmutable;
      desc[8] = d3d11BindShaderResource;
      desc[9] = 0;
      desc[10] = 0;
      final Pointer<Uint8> initial =
          Pointer<Uint8>.fromAddress(_desc.address + 64);
      initial.cast<IntPtr>()[0] = staging.address;
      Pointer<Uint32>.fromAddress(initial.address + 8)[0] = texture.width * 4;
      Pointer<Uint32>.fromAddress(initial.address + 12)[0] = 0;
      final int hr = hresult(_device.device.createTexture2D(
          _device.device.pointer, _desc.cast(), initial.cast(), _out));
      if (failed(hr) || _out.value == nullptr) return null;
      final image = ComObject(_out.value, interfaceName: 'ID3D11Texture2D');
      final int viewHr = hresult(_device.device.createShaderResourceView(
          _device.device.pointer, image.pointer, nullptr, _out));
      if (failed(viewHr) || _out.value == nullptr) {
        image.dispose();
        return null;
      }
      final upload = _MeshTextureUpload(
        image,
        ComObject(_out.value, interfaceName: 'ID3D11ShaderResourceView'),
      );
      _textures[texture] = upload;
      return upload;
    } finally {
      staging0.dispose();
    }
  }

  // -------------------------------------------------------------------
  // Teardown
  // -------------------------------------------------------------------

  bool get isDisposed => _disposed;

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('this D3d11MeshRenderer has been disposed');
    }
  }

  /// Releases every COM reference this renderer owns.
  ///
  /// Released, not merely forgotten, even after a device loss: `Release` is the
  /// one call that still works on an object whose device was removed, and it is
  /// the only way the refcount reaches zero. The argument is
  /// [D3d11RenderDevice.discardNativeResources]'s at length, and the cached
  /// buffers need it most - they are the largest allocations here and no
  /// `ComBag` outside this class owns them.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final _MeshBuffers entry in _buffers.values) {
      entry.dispose();
    }
    _buffers.clear();
    _bufferBytes = 0;
    for (final _MeshTextureUpload entry in _textures.values) {
      entry.dispose();
    }
    _textures.clear();
    _depthView?.dispose();
    _depthTexture?.dispose();
    _depthView = null;
    _depthTexture = null;
    _rasterizerStates.clear();
    _depthStates.clear();
    _objects.dispose();
    _arena.dispose();
  }
}

/// Where a mesh frame's colour goes.
final class _MeshColorTarget {
  const _MeshColorTarget(this.view, this.width, this.height);

  final Pointer<Void> view;
  final int width;
  final int height;
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
    required this.vertices,
    required this.indices,
    required this.indexCount,
    required this.bytes,
  });

  final ComObject vertices;
  final ComObject indices;
  final int indexCount;
  final int bytes;

  /// The renderer's monotonic draw counter when this was last used, which is
  /// what makes the eviction least-recently-used rather than arbitrary.
  int lastUsed = 0;

  void dispose() {
    vertices.dispose();
    indices.dispose();
  }
}

final class _MeshTextureUpload {
  const _MeshTextureUpload(this.texture, this.view);

  final ComObject texture;
  final ComObject view;

  void dispose() {
    view.dispose();
    texture.dispose();
  }
}
