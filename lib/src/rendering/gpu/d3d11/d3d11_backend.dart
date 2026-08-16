/// The Direct3D 11 backend: the second concrete filling of the GPU
/// abstraction, and the first one with a real device-loss story.
///
/// `gl_backend.dart` is the model and this file implements the same three
/// contracts from `renderer.dart` against the same device-independent
/// machinery - [GpuRasterSink], [GpuBatcher], [GpuMaskAtlas], [GpuGlyphAtlas]
/// and [GpuLayerStack] are shared verbatim, which is the whole point of them
/// being device-independent. What differs is written down where it differs; the
/// arguments that are identical are not repeated, and the reader who wants
/// them will find them in the GL file.
///
/// The three real differences:
///
///   * **Orientation.** D3D11's render-target origin is the top-left corner,
///     so the `uYFlip` uniform that GL needs does not exist here and
///     `GpuRenderPass.rendersTopDown` is ignored. See `d3d11_shaders.dart`,
///     which states all four consequences.
///   * **Device loss is real.** `DXGI_ERROR_DEVICE_REMOVED` and
///     `DXGI_ERROR_DEVICE_RESET` happen on this API for reasons that are not
///     bugs - a driver update, a TDR, a laptop switching GPUs. GL has the
///     condition in theory and almost never in practice. See
///     [D3d11RenderDevice.checkDeviceRemoved] and the honest statement of what
///     recovery still needs.
///   * **Shaders are compiled at run time**, from the HLSL in
///     `d3d11_shaders.dart`, by `d3dcompiler_47.dll`. The decision and its
///     cost are argued in [D3d11RendererBackend.shaderCompilationPolicy].
///
/// ## Two targets, and only one of them reads pixels back
///
/// Exactly as in GL: [D3d11OffscreenTarget] renders into a texture and copies
/// it to a staging texture the CPU can map, which is what a golden test and an
/// image export need and what section 23 of the roadmap forbids per frame in
/// production. `D3d11WindowTarget`, in `d3d11_window_target.dart`, renders into
/// a swap chain's back buffer and presents it, with no readback.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import '../../../ffi/com.dart';
import '../../../ffi/native_memory.dart';
import '../../../foundation/diagnostics.dart';
import '../../../foundation/lifecycle.dart';
import '../../../geometry/rect.dart';
import '../../../geometry/transform2d.dart';
import '../../../graphics/display_list.dart';
import '../../../graphics/display_list_reader.dart';
import '../../../text/typeface.dart';
import '../../framebuffer.dart';
import '../../renderer.dart';
import '../../replay/display_list_player.dart';
import '../gpu_batcher.dart';
import '../gpu_device_state.dart';
import '../gpu_glyph_atlas.dart';
import '../gpu_layer_stack.dart';
import '../gpu_mask_atlas.dart';
import '../gpu_pipeline.dart';
import '../gpu_raster_sink.dart';
import '../gpu_recovery.dart';
import '../gpu_texture.dart';
import 'd3d11_bindings.dart';
import 'd3d11_shaders.dart';
import 'd3d11_surface_descriptor.dart';
import 'd3d11_window_target.dart';

/// A texture owned by a [D3d11RenderDevice].
///
/// [id] is a small integer this device hands out, not a driver handle. The
/// batcher compares texture identity as an `int` (see [GpuBatcher.setState]),
/// and a 64-bit COM pointer does not fit that contract on a 32-bit build and
/// would be an odd thing to compare on any. The device keeps the map from id
/// back to the shader-resource view it has to bind.
final class D3d11Texture implements GpuTextureHandle {
  D3d11Texture._(
    this.id,
    this.width,
    this.height,
    this.format,
    this.filter,
    this.texture,
    this.view,
    this._state,
  ) : _bornAtLossCount = _state.lossCount;

  @override
  final int id;

  @override
  final int width;

  @override
  final int height;

  @override
  final GpuTextureFormat format;

  @override
  final GpuTextureFilter filter;

  /// `ID3D11Texture2D`.
  final ComObject texture;

  /// `ID3D11ShaderResourceView` over [texture].
  final ComObject view;

  final GpuDeviceState _state;
  bool _released = false;

  /// [GpuDeviceState.lossCount] when this texture was created.
  ///
  /// Without it, a recovered device would declare every pre-loss texture valid
  /// again the instant `isLost` went back to false - and those COM pointers
  /// belong to an `ID3D11Device` that no longer exists. `lossCount` never goes
  /// down, so comparing it is the check that survives a recovery. See
  /// `GlTexture` for the same field and the same argument.
  final int _bornAtLossCount;

  /// A texture dies with its device and stays dead across a recovery: the
  /// driver freed the resource, and the pointer that survives points at memory
  /// that is no longer a texture.
  @override
  bool get isValid =>
      !_released && !_state.isLost && _state.lossCount == _bornAtLossCount;

  @override
  String toString() =>
      'D3d11Texture($id, ${width}x$height, ${format.name}, ${filter.name})';
}

/// One offscreen target a layer renders into.
final class D3d11LayerTarget implements GpuLayerTarget {
  D3d11LayerTarget._(
      this.id, this.width, this.height, this.texture, this.renderTarget);

  @override
  final int id;

  @override
  final int width;

  @override
  final int height;

  /// The colour texture, in the device's texture-id space, so a composite quad
  /// batches against it like any other texture.
  final D3d11Texture texture;

  @override
  int get textureId => texture.id;

  /// `ID3D11RenderTargetView` over [texture].
  final ComObject renderTarget;

  @override
  String toString() => 'D3d11LayerTarget($id, ${width}x$height)';
}

/// Where layers get their targets, and where they go back to.
///
/// Rounded up to a power of two, at least 64, so a scrolling list whose layers
/// change size by a pixel a frame reuses one target instead of allocating a new
/// one per frame. That is the same trade `gl_framebuffer_pool.dart` makes and
/// for the same reason: an allocator that hands out exactly the requested
/// pixels never reuses anything.
final class D3d11LayerPool implements GpuLayerTargetAllocator {
  D3d11LayerPool(this._device);

  final D3d11RenderDevice _device;
  final Map<int, List<D3d11LayerTarget>> _idle =
      <int, List<D3d11LayerTarget>>{};
  final List<D3d11LayerTarget> _live = <D3d11LayerTarget>[];
  int _created = 0;

  /// How many targets this pool has ever created. A test asserts that the same
  /// layer drawn on ten frames created one - reuse is invisible from the
  /// pixels and very visible in the frame time.
  int get createdCount => _created;

  /// How many targets are held, idle or in flight.
  int get length => _live.length + _idle.values.fold(0, (a, b) => a + b.length);

  static int _round(int value) {
    var size = 64;
    while (size < value) {
      size <<= 1;
    }
    return size;
  }

  @override
  GpuLayerTarget acquireLayerTarget(int width, int height) {
    final int w = _round(width);
    final int h = _round(height);
    final int key = w * 65536 + h;
    final List<D3d11LayerTarget>? free = _idle[key];
    if (free != null && free.isNotEmpty) {
      final target = free.removeLast();
      _live.add(target);
      return target;
    }
    _created++;
    final target = _device._createLayerTarget(w, h);
    _live.add(target);
    return target;
  }

  @override
  void releaseLayerTarget(GpuLayerTarget target) {
    final resolved = target as D3d11LayerTarget;
    _live.remove(resolved);
    _idle
        .putIfAbsent(resolved.width * 65536 + resolved.height,
            () => <D3d11LayerTarget>[])
        .add(resolved);
  }

  /// Destroys every target. Called when the owning target is disposed, after
  /// the layer stack has handed everything back.
  void dispose() {
    for (final list in _idle.values) {
      for (final target in list) {
        _device._destroyLayerTarget(target);
      }
    }
    for (final target in _live) {
      _device._destroyLayerTarget(target);
    }
    _idle.clear();
    _live.clear();
  }
}

/// The redundant-state filter, carried across passes. See `_DrawState` in
/// `gl_backend.dart` for why this is an object and not three locals.
final class _DrawState {
  int textureId = -1;
  int mode = -1;
  int blendMode = -1;
  int filter = -1;

  void reset() {
    textureId = -1;
    mode = -1;
    blendMode = -1;
    filter = -1;
  }
}

/// An open D3D11 device plus the pipeline objects every target shares.
/// A target that can put its GPU resources back after a device loss.
///
/// The D3D11 twin of `GlRecoverableTarget`, and it exists for the same reason:
/// [D3d11WindowTarget] lives in another library, so the device holds its
/// targets through an interface rather than by type.
abstract interface class D3d11RecoverableTarget {
  Iterable<GpuRecoverableResource> recoverableResources();
}

final class D3d11RenderDevice
    with DisposableMixin
    implements RenderDevice, GpuTextureAllocator, GpuRecoveryHost {
  D3d11RenderDevice._({
    required D3d11Api api,
    required this.device,
    required this.context,
    required RendererInfo info,
    required int featureLevel,
  })  : _api = api,
        _info = info,
        _featureLevel = featureLevel;

  final D3d11Api _api;

  /// `ID3D11Device`. Public because a target in another file creates its own
  /// resources with it; see `gl_backend.dart`'s library comment for the whole
  /// argument about promoting device-to-target plumbing rather than using
  /// `part`.
  ///
  /// **Not final, and not cacheable.** [recreateDevice] replaces it with a
  /// genuinely new `ID3D11Device` after a loss - which is the difference
  /// between this backend and the GL one, where a context belongs to the
  /// platform and only its objects can be rebuilt. A caller that stored this
  /// pointer across a frame is holding a device that may have been released;
  /// read it fresh every time, as every method in this file does.
  D3d11Device device;

  /// The immediate context. Every draw in this backend goes through it, and it
  /// is single-threaded by construction: `D3D11CreateDevice` was not asked for
  /// `SINGLETHREADED`, but nothing here touches it from a second isolate.
  ///
  /// Replaced with [device] on a recovery, and carrying the same warning.
  D3d11DeviceContext context;

  RendererInfo _info;
  int _featureLevel;
  final GpuDeviceState _state = GpuDeviceState();

  /// Long-lived native scratch, allocated once so that a frame performs no
  /// native allocation at all. Released in reverse order on dispose.
  final NativeArena _arena = NativeArena();

  /// Every COM reference this device owns, released last-acquired-first.
  ///
  /// Replaced rather than reused on a recovery: a [ComBag] is a
  /// `DisposableMixin` and refuses `keep` once disposed, so releasing the dead
  /// device's objects means the next `_initialise` needs a fresh bag.
  ComBag _objects = ComBag();

  ComObject? _vertexShader;
  ComObject? _pixelShader;
  ComObject? _inputLayout;
  ComObject? _rasterizerState;
  ComObject? _samplerPoint;
  ComObject? _samplerLinear;
  ComObject? _constantBuffer;
  ComObject? _vertexBuffer;
  ComObject? _indexBuffer;
  int _vertexBufferBytes = 0;
  int _indexBufferBytes = 0;

  final Map<int, ComObject> _blendStates = <int, ComObject>{};
  final Map<int, D3d11Texture> _texturesById = <int, D3d11Texture>{};
  int _nextTextureId = 1;
  int _nextLayerId = 1;

  /// The DXGI factory that makes swap chains, fetched on first use.
  ///
  /// Lazily, because an offscreen-only process never needs one and walking
  /// device -> IDXGIDevice -> adapter -> factory costs three COM calls and
  /// three references.
  DxgiFactory2? _factory;

  // Scratch buffers, all sized at construction. Each is documented with what
  // native structure it holds, because a byte offset with no name is how a
  // descriptor gets filled in the wrong field.
  late final Pointer<Uint8> _scratchDesc = _arena.allocate<Uint8>(512);
  late final Pointer<Uint8> _scratchDesc2 = _arena.allocate<Uint8>(512);
  late final Pointer<Pointer<Void>> _out = _arena.allocateOutPointer();
  late final Pointer<Pointer<Void>> _slotA = _arena.allocateOutPointer();
  late final Pointer<Pointer<Void>> _slotB = _arena.allocateOutPointer();
  late final Pointer<Float> _float4 = _arena.allocate<Float>(16);
  late final Pointer<Uint32> _uint4 = _arena.allocate<Uint32>(16);
  late final Pointer<Uint32> _uint4b = _arena.allocate<Uint32>(16);
  late final Pointer<Uint8> _constants = _arena.allocate<Uint8>(16);
  Pointer<Uint8> _staging = nullptr;
  int _stagingBytes = 0;

  GpuDeviceState get state => _state;

  D3d11Api get api => _api;

  int get featureLevel => _featureLevel;

  @override
  RendererInfo get info => _info;

  @override
  bool get isLost => _state.isLost;

  /// What this device can do, answered field by field.
  ///
  /// Partial present is false: `Present` with a dirty-rectangle list needs
  /// `IDXGISwapChain1::Present1` and a swap effect that preserves the back
  /// buffer, and this backend uses neither yet - claiming it would make a
  /// caller skip a redraw whose pixels were never sent. MSAA is false because
  /// nothing here creates a multisampled target and the antialiasing is
  /// analytic (see `gpu_mask_atlas.dart`); compute is false because the
  /// bindings deliberately stop before compute shaders. External textures are
  /// false: nothing yet opens a shared resource.
  ///
  /// Text is drawn, and no boolean here says so - the same gap `gl_backend`
  /// documents. The probe report says it in prose.
  @override
  RendererCapabilities get capabilities => RendererCapabilities(
        supportsPartialPresent: false,
        supportsMsaa: false,
        supportsCompute: false,
        supportsExternalTextures: false,
        supportsLinearColor: false,
        maxTextureSize: _featureLevel >= d3dFeatureLevel11_0 ? 16384 : 8192,
        formats: const <PixelFormat>{
          PixelFormat.rgba8888Premultiplied,
          PixelFormat.bgra8888Premultiplied,
        },
      );

  /// Builds the target that matches [surface], or names what is missing.
  ///
  /// Two descriptors, two classes, for the reason `gl_backend.dart` gives: they
  /// present in opposite ways, and quietly building an offscreen target for an
  /// unrecognised descriptor would render every frame perfectly and show none
  /// of them.
  @override
  RenderTarget createTarget(NativeSurfaceDescriptor surface) {
    throwIfDisposed();
    if (surface is MemorySurfaceDescriptor) {
      return D3d11OffscreenTarget(this, surface);
    }
    if (surface is D3d11WindowSurfaceDescriptor) {
      return D3d11WindowTarget(this, surface);
    }
    throw UnsupportedCapabilityError(
      backendName: D3d11RendererBackend.backendName,
      capability: Capability.gpuPresentation,
      detail: 'this device builds an offscreen target from a '
          'MemorySurfaceDescriptor and a windowed target from a '
          'D3d11WindowSurfaceDescriptor; it was handed a ${surface.kind} '
          '(${surface.runtimeType}), which it has no way to present to. A '
          'window descriptor is built by the platform code that owns the '
          'window - lib/src/backends/win32/d3d11/win32_d3d11_surface.dart',
    );
  }

  // -------------------------------------------------------------------
  // Swap chains
  // -------------------------------------------------------------------

  /// The DXGI factory this device's adapter belongs to.
  ///
  /// Walked from the device rather than created with `CreateDXGIFactory1`,
  /// because a swap chain must be made by the factory that owns the adapter the
  /// device runs on. Creating a fresh factory works on a single-GPU machine and
  /// fails on a laptop with two, which is the machine least likely to be the
  /// one you are testing on.
  ///
  /// Returns null with a diagnostic when any step refuses.
  DxgiFactory2? dxgiFactory({List<BackendDiagnostic>? diagnostics}) {
    final cached = _factory;
    if (cached != null) return cached;
    final ComObject? dxgiDevice =
        device.queryInterface(iidIdxgiDevice, interfaceName: 'IDXGIDevice');
    if (dxgiDevice == null) {
      diagnostics?.add(const BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the D3D11 device does not implement IDXGIDevice',
      ));
      return null;
    }
    final wrapped = DxgiDevice(dxgiDevice.pointer);
    try {
      final int hr = hresult(wrapped.getAdapter(wrapped.pointer, _out));
      if (failed(hr) || _out.value == nullptr) {
        diagnostics?.add(BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'IDXGIDevice::GetAdapter failed',
          detail: hresultName(hr),
        ));
        return null;
      }
      final adapter = DxgiAdapter(_out.value);
      try {
        final Pointer<Uint8> iid = iidIdxgiFactory2.allocateIn(_arena);
        final int parent =
            hresult(adapter.getParent(adapter.pointer, iid, _out));
        if (failed(parent) || _out.value == nullptr) {
          diagnostics?.add(BackendDiagnostic(
            kind: DiagnosticKind.incompatibleVersion,
            message: 'this adapter has no IDXGIFactory2',
            detail: '${hresultName(parent)}; IDXGIFactory2 is DXGI 1.2, which '
                'is Windows 8 and later. A Windows 7 machine would need '
                'IDXGIFactory::CreateSwapChain and a bitblt swap effect',
          ));
          return null;
        }
        final factory = DxgiFactory2(_out.value);
        _objects.keep(factory);
        return _factory = factory;
      } finally {
        adapter.dispose();
      }
    } finally {
      dxgiDevice.dispose();
    }
  }

  // -------------------------------------------------------------------
  // Textures
  // -------------------------------------------------------------------

  @override
  D3d11Texture createTexture({
    required int width,
    required int height,
    required GpuTextureFormat format,
    GpuTextureFilter filter = GpuTextureFilter.nearest,
  }) {
    throwIfDisposed();
    if (width <= 0 || height <= 0) {
      throw ArgumentError('a texture must have a positive size, got '
          '${width}x$height');
    }
    final int limit = capabilities.maxTextureSize;
    if (width > limit || height > limit) {
      throw UnsupportedCapabilityError(
        backendName: D3d11RendererBackend.backendName,
        capability: Capability.gpuPresentation,
        detail: 'a ${width}x$height texture exceeds this feature level\'s '
            'limit of $limit; the caller must tile the image or scale it down',
      );
    }
    return _createTexture(
      width: width,
      height: height,
      format: format,
      filter: filter,
      bindFlags: d3d11BindShaderResource,
    );
  }

  D3d11Texture _createTexture({
    required int width,
    required int height,
    required GpuTextureFormat format,
    required GpuTextureFilter filter,
    required int bindFlags,
  }) {
    _writeTexture2DDesc(
      _scratchDesc,
      width: width,
      height: height,
      format: format == GpuTextureFormat.alpha8
          ? dxgiFormatR8Unorm
          : dxgiFormatR8G8B8A8Unorm,
      usage: d3d11UsageDefault,
      bindFlags: bindFlags,
      cpuAccess: 0,
    );
    checkHresult(
      device.createTexture2D(
          device.pointer, _scratchDesc.cast(), nullptr, _out),
      'ID3D11Device::CreateTexture2D(${width}x$height, ${format.name})',
    );
    final texture = ComObject(_out.value, interfaceName: 'ID3D11Texture2D');
    ComObject? view;
    if (bindFlags & d3d11BindShaderResource != 0) {
      checkHresult(
        device.createShaderResourceView(
            device.pointer, texture.pointer, nullptr, _out),
        'ID3D11Device::CreateShaderResourceView',
      );
      view = ComObject(_out.value, interfaceName: 'ID3D11ShaderResourceView');
    }
    final result = D3d11Texture._(
      _nextTextureId++,
      width,
      height,
      format,
      filter,
      texture,
      view ?? texture,
      _state,
    );
    _texturesById[result.id] = result;
    return result;
  }

  /// Fills a `D3D11_TEXTURE2D_DESC` at [target].
  void _writeTexture2DDesc(
    Pointer<Uint8> target, {
    required int width,
    required int height,
    required int format,
    required int usage,
    required int bindFlags,
    required int cpuAccess,
  }) {
    final view = target.cast<Uint32>();
    view[0] = width;
    view[1] = height;
    view[2] = 1; // MipLevels
    view[3] = 1; // ArraySize
    view[4] = format;
    view[5] = 1; // SampleDesc.Count
    view[6] = 0; // SampleDesc.Quality
    view[7] = usage;
    view[8] = bindFlags;
    view[9] = cpuAccess;
    view[10] = 0; // MiscFlags
  }

  @override
  void uploadRegion(
    covariant D3d11Texture texture, {
    required int x,
    required int y,
    required int width,
    required int height,
    required Uint8List pixels,
    required int bytesPerRow,
  }) {
    if (width <= 0 || height <= 0 || _state.isLost) return;
    final int rowBytes = width * texture.format.bytesPerPixel;
    final int bytes = rowBytes * height;
    final Pointer<Uint8> staging = _ensureStaging(bytes);
    final view = staging.asTypedList(bytes);
    for (var row = 0; row < height; row++) {
      view.setRange(
        row * rowBytes,
        row * rowBytes + rowBytes,
        pixels,
        row * bytesPerRow,
      );
    }
    // A D3D11_BOX, which UpdateSubresource needs because the destination is a
    // sub-rectangle. The back and front planes are 0 and 1 for a 2D texture;
    // leaving back at 0 makes the box empty and the upload a silent no-op.
    final box = _scratchDesc.cast<Uint32>();
    box[0] = x;
    box[1] = y;
    box[2] = 0;
    box[3] = x + width;
    box[4] = y + height;
    box[5] = 1;
    context.updateSubresource(
      context.pointer,
      texture.texture.pointer,
      0,
      _scratchDesc.cast(),
      staging.cast(),
      rowBytes,
      bytes,
    );
  }

  @override
  void releaseTexture(covariant D3d11Texture texture) {
    if (texture._released || isDisposed) return;
    texture._released = true;
    _texturesById.remove(texture.id);
    if (!identical(texture.view, texture.texture)) texture.view.dispose();
    texture.texture.dispose();
  }

  // -------------------------------------------------------------------
  // Frame submission
  // -------------------------------------------------------------------

  /// Issues a batch list into [surfaceRenderTarget], switching targets where
  /// [layers] says to.
  ///
  /// Device-to-target plumbing, public because targets live in other files.
  /// The contract is the same as `GlRenderDevice.submit` argument for argument
  /// - including [firstBatch], which is what makes a mid-frame atlas flush
  /// possible and what stops a batch being drawn (and therefore blended) twice.
  ///
  /// The one thing that is *not* the same: no y-flip. Every pass renders
  /// top-down because a D3D11 render target is stored top-down, so
  /// [GpuRenderPass.rendersTopDown] is deliberately not read and a scissor
  /// rectangle is used exactly as the batcher computed it. See
  /// `d3d11_shaders.dart`.
  ///
  /// Returns false when the device was lost on the way.
  bool submit(
    GpuBatcher batcher,
    int surfaceWidth,
    int surfaceHeight,
    int? clearColor,
    Pointer<Void> surfaceRenderTarget, {
    GpuLayerStack? layers,
    int firstBatch = 0,
  }) {
    // Step 1 of a recovery closed the door: no draw may reach the driver while
    // the device is being replaced, and the render-target pointer the caller is
    // holding belongs to the device that died.
    if (_submissionsStopped) {
      _blockedSubmissionCount++;
      return false;
    }
    if (_state.isLost) return false;

    _bindRenderTarget(surfaceRenderTarget);
    _setViewport(surfaceWidth, surfaceHeight);

    if (clearColor != null) {
      // Packed the way FrameRequest documents it - premultiplied BGRA in a
      // 32-bit int, which is A in the top byte then R, G, B - and
      // ClearRenderTargetView wants straight floats in RGBA order.
      _float4[0] = ((clearColor >> 16) & 0xFF) / 255.0;
      _float4[1] = ((clearColor >> 8) & 0xFF) / 255.0;
      _float4[2] = (clearColor & 0xFF) / 255.0;
      _float4[3] = ((clearColor >> 24) & 0xFF) / 255.0;
      context.clearRenderTargetView(
          context.pointer, surfaceRenderTarget, _float4);
    }

    final int batchCount = batcher.batchCount;
    if (batchCount <= firstBatch) return !_state.isLost;

    if (!_uploadGeometry(batcher)) return false;
    _bindPipeline();

    final _DrawState state = _drawState..reset();
    final int passCount = layers?.passCount ?? 0;
    if (passCount == 0) {
      _drawBatches(
          batcher, firstBatch, batchCount, surfaceWidth, surfaceHeight, state);
    } else {
      for (var p = 0; p < passCount; p++) {
        final GpuRenderPass pass = layers!.passAt(p);
        final int end = layers.passEnd(p, batchCount);
        if (end <= firstBatch) continue;
        final int start =
            pass.firstBatch < firstBatch ? firstBatch : pass.firstBatch;
        final bool clears = pass.clearsTarget && start == pass.firstBatch;
        // An empty pass that clears is not a contradiction and must not be
        // skipped; see gl_backend.dart's submit for the case.
        if (end <= start && !clears) continue;

        final GpuLayerTarget? target = pass.target;
        final Pointer<Void> rtv = target == null
            ? surfaceRenderTarget
            : (target as D3d11LayerTarget).renderTarget.pointer;
        _bindRenderTarget(rtv);
        _setViewport(pass.viewportWidth, pass.viewportHeight);

        if (clears) {
          // A layer composites what it drew over transparency, and the whole
          // target - including the slack a pooled target has past the layer's
          // own size - has to lose the previous tenant's pixels.
          // ClearRenderTargetView ignores the scissor rectangle, which is one
          // fewer thing to get wrong than glClear, which obeys it.
          for (var i = 0; i < 4; i++) {
            _float4[i] = 0;
          }
          context.clearRenderTargetView(context.pointer, rtv, _float4);
        }
        if (end <= start) continue;

        _drawBatches(batcher, start, end, pass.viewportWidth,
            pass.viewportHeight, state);
      }
      // The caller bound its own target before calling and is entitled to find
      // it bound afterwards - it reads pixels back or presents it next.
      _bindRenderTarget(surfaceRenderTarget);
    }

    return !_state.isLost;
  }

  final _DrawState _drawState = _DrawState();

  void _drawBatches(
    GpuBatcher batcher,
    int first,
    int last,
    int viewportWidth,
    int viewportHeight,
    _DrawState state,
  ) {
    for (var i = first; i < last; i++) {
      final GpuBatch batch = batcher.batchAt(i);
      var left = batch.scissorLeft;
      var top = batch.scissorTop;
      var right = batch.scissorRight;
      var bottom = batch.scissorBottom;
      if (left < 0) left = 0;
      if (top < 0) top = 0;
      if (right > viewportWidth) right = viewportWidth;
      if (bottom > viewportHeight) bottom = viewportHeight;
      if (right <= left || bottom <= top) continue;

      // No y flip. D3D11's scissor origin is the top-left corner, which is
      // device space's origin too; GL needs `viewportHeight - bottom` here
      // only because its origin is at the bottom.
      final rect = _scratchDesc.cast<Int32>();
      rect[0] = left;
      rect[1] = top;
      rect[2] = right;
      rect[3] = bottom;
      context.rsSetScissorRects(context.pointer, 1, _scratchDesc.cast());

      if (batch.blendMode != state.blendMode) {
        state.blendMode = batch.blendMode;
        final ComObject blend = _blendStateFor(batch.blendMode);
        for (var c = 0; c < 4; c++) {
          _float4[c] = 0;
        }
        context.omSetBlendState(
            context.pointer, blend.pointer, _float4, 0xFFFFFFFF);
      }

      final int mode = switch (batch.pipeline) {
        GpuPipelineKind.solid => kD3dModeSolid,
        GpuPipelineKind.coverageMask => kD3dModeCoverageMask,
        GpuPipelineKind.texturedImage => kD3dModeTexturedImage,
      };
      if (mode != state.mode || _constantsMode != mode) {
        state.mode = mode;
        _writeConstants(viewportWidth, viewportHeight, mode);
      }

      if (batch.textureId != state.textureId) {
        state.textureId = batch.textureId;
        final D3d11Texture? texture = _texturesById[batch.textureId];
        _slotA.value = texture?.view.pointer ?? nullptr;
        context.psSetShaderResources(context.pointer, 0, 1, _slotA);
        final int filter =
            texture == null || texture.filter == GpuTextureFilter.nearest
                ? 0
                : 1;
        if (filter != state.filter) {
          state.filter = filter;
          _slotB.value =
              (filter == 0 ? _samplerPoint! : _samplerLinear!).pointer;
          context.psSetSamplers(context.pointer, 0, 1, _slotB);
        }
      }

      context.drawIndexed(
          context.pointer, batch.indexCount, batch.indexOffset, 0);
    }
  }

  /// The viewport the constants were last written with, so a pass that changes
  /// only the mode does not resend the size and vice versa.
  int _constantsWidth = -1;
  int _constantsHeight = -1;
  int _constantsMode = -1;

  void _writeConstants(int width, int height, int mode) {
    _constantsWidth = width;
    _constantsHeight = height;
    _constantsMode = mode;
    _constants.cast<Float>()[0] = width.toDouble();
    _constants.cast<Float>()[1] = height.toDouble();
    _constants.cast<Uint32>()[2] = mode;
    _constants.cast<Uint32>()[3] = 0;
    context.updateSubresource(context.pointer, _constantBuffer!.pointer, 0,
        nullptr, _constants.cast(), 0, 0);
  }

  void _setViewport(int width, int height) {
    final view = _scratchDesc2.cast<Float>();
    view[0] = 0;
    view[1] = 0;
    view[2] = width.toDouble();
    view[3] = height.toDouble();
    view[4] = 0;
    view[5] = 1;
    context.rsSetViewports(context.pointer, 1, _scratchDesc2.cast());
    if (_constantsWidth != width || _constantsHeight != height) {
      _writeConstants(width, height, _constantsMode < 0 ? 0 : _constantsMode);
    }
  }

  void _bindRenderTarget(Pointer<Void> rtv) {
    _slotA.value = rtv;
    context.omSetRenderTargets(context.pointer, 1, _slotA, nullptr);
  }

  /// Unbinds every render target and shader resource.
  ///
  /// Not tidiness: `ResizeBuffers` refuses with `DXGI_ERROR_INVALID_CALL`
  /// while the context still references a back buffer, and the context holds a
  /// reference to whatever is bound even though no Dart object does. The
  /// window target calls this before it releases its view.
  void unbindTargets() {
    _slotA.value = nullptr;
    context
      ..omSetRenderTargets(context.pointer, 1, _slotA, nullptr)
      ..psSetShaderResources(context.pointer, 0, 1, _slotA);
    _drawState.reset();
  }

  void _bindPipeline() {
    _slotA.value = _vertexBuffer!.pointer;
    _uint4[0] = kGpuFloatsPerVertex * 4;
    _uint4b[0] = 0;
    context
      ..iaSetInputLayout(context.pointer, _inputLayout!.pointer)
      ..iaSetVertexBuffers(context.pointer, 0, 1, _slotA, _uint4, _uint4b)
      ..iaSetIndexBuffer(
          context.pointer, _indexBuffer!.pointer, dxgiFormatR32Uint, 0)
      ..iaSetPrimitiveTopology(
          context.pointer, d3d11PrimitiveTopologyTriangleList)
      ..vsSetShader(context.pointer, _vertexShader!.pointer, nullptr, 0)
      ..psSetShader(context.pointer, _pixelShader!.pointer, nullptr, 0)
      ..rsSetState(context.pointer, _rasterizerState!.pointer);
    _slotB.value = _constantBuffer!.pointer;
    context
      ..vsSetConstantBuffers(context.pointer, 0, 1, _slotB)
      ..psSetConstantBuffers(context.pointer, 0, 1, _slotB);
    _slotB.value = _samplerPoint!.pointer;
    context.psSetSamplers(context.pointer, 0, 1, _slotB);
  }

  bool _uploadGeometry(GpuBatcher batcher) {
    final buffer = batcher.buffer;
    final int floatCount = buffer.vertexCount * kGpuFloatsPerVertex;
    final int vertexBytes = floatCount * 4;
    final int indexCount = buffer.indexCount;
    final int indexBytes = indexCount * 4;
    if (!_ensureVertexBuffer(vertexBytes)) return false;
    if (!_ensureIndexBuffer(indexBytes)) return false;

    // MAP_WRITE_DISCARD, which is the whole reason these buffers are DYNAMIC:
    // it hands back a fresh block of driver memory and lets the GPU keep
    // reading the previous frame's, so a per-frame upload never stalls the
    // pipeline. MAP_WRITE on a dynamic buffer is not even legal.
    final Pointer<Uint8> mappedVertices =
        _mapWrite(_vertexBuffer!, 'the vertex buffer');
    if (mappedVertices == nullptr) return false;
    mappedVertices
        .cast<Float>()
        .asTypedList(floatCount)
        .setRange(0, floatCount, buffer.vertexStorage);
    context.unmap(context.pointer, _vertexBuffer!.pointer, 0);

    final Pointer<Uint8> mappedIndices =
        _mapWrite(_indexBuffer!, 'the index buffer');
    if (mappedIndices == nullptr) return false;
    mappedIndices
        .cast<Uint32>()
        .asTypedList(indexCount)
        .setRange(0, indexCount, buffer.indexStorage);
    context.unmap(context.pointer, _indexBuffer!.pointer, 0);
    return true;
  }

  Pointer<Uint8> _mapWrite(ComObject resource, String what) {
    final Pointer<Uint8> mapped = _scratchDesc2;
    final int hr = hresult(context.map(context.pointer, resource.pointer, 0,
        d3d11MapWriteDiscard, 0, mapped.cast()));
    if (failed(hr)) {
      _markLostIfRemoved(hr, 'mapping $what');
      return nullptr;
    }
    return Pointer<Uint8>.fromAddress(mapped.cast<IntPtr>()[0]);
  }

  bool _ensureVertexBuffer(int bytes) {
    if (_vertexBuffer != null && bytes <= _vertexBufferBytes) return true;
    _vertexBuffer?.dispose();
    _vertexBufferBytes = bytes < 4096 ? 4096 : bytes * 2;
    _vertexBuffer =
        _createDynamicBuffer(_vertexBufferBytes, d3d11BindVertexBuffer);
    return _vertexBuffer != null;
  }

  bool _ensureIndexBuffer(int bytes) {
    if (_indexBuffer != null && bytes <= _indexBufferBytes) return true;
    _indexBuffer?.dispose();
    _indexBufferBytes = bytes < 4096 ? 4096 : bytes * 2;
    _indexBuffer =
        _createDynamicBuffer(_indexBufferBytes, d3d11BindIndexBuffer);
    return _indexBuffer != null;
  }

  ComObject? _createDynamicBuffer(int bytes, int bindFlags) {
    final desc = _scratchDesc.cast<Uint32>();
    desc[0] = bytes;
    desc[1] = d3d11UsageDynamic;
    desc[2] = bindFlags;
    desc[3] = d3d11CpuAccessWrite;
    desc[4] = 0;
    desc[5] = 0;
    final int hr = hresult(device.createBuffer(
        device.pointer, _scratchDesc.cast(), nullptr, _out));
    if (failed(hr)) {
      _markLostIfRemoved(hr, 'creating a $bytes-byte dynamic buffer');
      return null;
    }
    return ComObject(_out.value, interfaceName: 'ID3D11Buffer');
  }

  ComObject _blendStateFor(int blendMode) {
    final cached = _blendStates[blendMode];
    if (cached != null) return cached;
    final GpuBlendState blend = gpuBlendForMode(blendMode);
    final desc = _scratchDesc.cast<Uint32>();
    for (var i = 0; i < sizeOfBlendDesc ~/ 4; i++) {
      desc[i] = 0;
    }
    // AlphaToCoverageEnable = 0, IndependentBlendEnable = 0, then
    // RenderTarget[0] at byte 8.
    const int rt0 = 8 ~/ 4;
    desc[rt0 + 0] = 1; // BlendEnable
    desc[rt0 + 1] = _blendFactor(blend.source);
    desc[rt0 + 2] = _blendFactor(blend.destination);
    desc[rt0 + 3] = d3d11BlendOpAdd;
    // Alpha uses the same factors as colour, which is what glBlendFunc means:
    // GL's two-argument form sets both, and the premultiplied source-over of
    // blend.dart is dst = src + dst * (1 - a) in all four channels.
    desc[rt0 + 4] = _blendFactor(blend.source);
    desc[rt0 + 5] = _blendFactor(blend.destination);
    desc[rt0 + 6] = d3d11BlendOpAdd;
    desc[rt0 + 7] = d3d11ColorWriteEnableAll;
    checkHresult(
      device.createBlendState(device.pointer, _scratchDesc.cast(), _out),
      'ID3D11Device::CreateBlendState',
    );
    final state = ComObject(_out.value, interfaceName: 'ID3D11BlendState');
    _objects.keep(state);
    _blendStates[blendMode] = state;
    return state;
  }

  static int _blendFactor(GpuBlendFactor factor) => switch (factor) {
        GpuBlendFactor.zero => d3d11BlendZero,
        GpuBlendFactor.one => d3d11BlendOne,
        GpuBlendFactor.oneMinusSrcAlpha => d3d11BlendInvSrcAlpha,
      };

  Pointer<Uint8> _ensureStaging(int bytes) {
    if (bytes <= _stagingBytes) return _staging;
    if (_staging != nullptr) {
      // The arena frees it on dispose either way; growing simply leaks the old
      // block until then, which for a staging buffer that doubles is bounded
      // by twice the largest upload.
    }
    _stagingBytes = bytes * 2;
    return _staging = _arena.allocate<Uint8>(_stagingBytes);
  }

  // -------------------------------------------------------------------
  // Device loss
  // -------------------------------------------------------------------

  /// Whether [hr] means the device is gone, and records it if so.
  ///
  /// The distinction this makes is the one the API makes. `DEVICE_REMOVED`,
  /// `DEVICE_HUNG`, `DEVICE_RESET` and `DRIVER_INTERNAL_ERROR` leave every
  /// resource this device created invalid; every other failure is about the
  /// call and leaves the device usable, exactly like the `GL_OUT_OF_MEMORY`
  /// versus everything-else split in `gl_backend.dart`. Treating all of them as
  /// loss turns one oversized texture into a renderer that can never draw
  /// again, which is a worse failure than the one it reports.
  bool _markLostIfRemoved(int hr, String what) {
    final int code = hresult(hr);
    if (code != dxgiErrorDeviceRemoved &&
        code != dxgiErrorDeviceReset &&
        code != dxgiErrorDeviceHung &&
        code != dxgiErrorDriverInternalError) {
      return false;
    }
    _state.markLost(BackendDiagnostic(
      kind: DiagnosticKind.connectionFailed,
      message: 'the D3D11 device was lost during $what',
      detail: '${hresultName(code)}; GetDeviceRemovedReason says '
          '${hresultName(device.getDeviceRemovedReason(device.pointer))}',
    ));
    return true;
  }

  /// Asks the driver whether the device is still there, and records a loss.
  ///
  /// `GetDeviceRemovedReason` is the only reliable question: once a device is
  /// removed every other call fails with a code describing *that call*, so a
  /// caller reading only the immediate HRESULT sees a stream of unrelated
  /// errors. Called after a present and after a failed map.
  ///
  /// ## What happens after this returns true
  ///
  /// Detection and recovery are separate on purpose, and this method is only
  /// the first. It records the loss: `isLost` goes true, in-flight frames
  /// present as [PresentStatus.deviceLost], and every [D3d11Texture] answers
  /// `isValid == false` - permanently, because the check is against the loss
  /// *generation* and not against the current state.
  ///
  /// Nothing here recovers. The owner drives that through
  /// `GpuRecoveryCoordinator` in `gpu_recovery.dart`, which calls
  /// [stopSubmissions], [discardNativeResources], [recreateDevice] and then
  /// every resource's `repopulate` in that order. Keeping the two apart is what
  /// makes a present able to report a loss without deciding, in the middle of a
  /// frame, to spend forty milliseconds building a device.
  ///
  /// The three things recovery needs, and where each now is:
  ///
  ///   1. A new `ID3D11Device`, context and pipeline - [recreateDevice].
  ///   2. Every target's resources - `D3d11RecoverableTarget`. The one
  ///      exception is a window target's **swap chain**, which belongs to the
  ///      platform code that owns the window and is reported as
  ///      [GpuResourceRecovery.orphaned] rather than silently reused.
  ///   3. Every uploaded texture - [D3d11ImageCache], which keeps the source
  ///      `Framebuffer` unless the caller dropped it with `dropSource`, and
  ///      names the ones it cannot rebuild.
  bool checkDeviceRemoved(String what) {
    if (_state.isLost) return true;
    final int reason = hresult(device.getDeviceRemovedReason(device.pointer));
    if (reason == sOk) return false;
    _state.markLost(BackendDiagnostic(
      kind: DiagnosticKind.connectionFailed,
      message: 'the D3D11 device was removed, noticed during $what',
      detail: hresultName(reason),
    ));
    return true;
  }

  /// Records a loss the caller diagnosed itself - a present that returned a
  /// removal code, a test that wants the loss path without a real GPU reset.
  void markLost(BackendDiagnostic reason) => _state.markLost(reason);

  // -------------------------------------------------------------------
  // Recovery - the eight steps of section 23.12, see gpu_recovery.dart
  // -------------------------------------------------------------------

  final Set<D3d11RecoverableTarget> _targets = <D3d11RecoverableTarget>{};

  bool _submissionsStopped = false;

  /// How many submissions were refused because a recovery was in progress.
  /// Invisible from the pixels, which is why it is counted: a device that went
  /// on issuing draws into a removed device produces the same blank frame as
  /// one that correctly refused.
  int get blockedSubmissionCount => _blockedSubmissionCount;
  int _blockedSubmissionCount = 0;

  bool get submissionsStopped => _submissionsStopped;

  @override
  String get backendName => D3d11RendererBackend.backendName;

  @override
  GpuDeviceState get deviceState => _state;

  void registerTarget(D3d11RecoverableTarget target) => _targets.add(target);

  void unregisterTarget(D3d11RecoverableTarget target) =>
      _targets.remove(target);

  /// Step 1.
  @override
  void stopSubmissions() => _submissionsStopped = true;

  /// Step 3: release every COM reference this device holds.
  ///
  /// ## Why this calls the API and the GL backend's twin does not
  ///
  /// The two APIs want opposite things after a loss, and doing either one's
  /// thing on the other is a bug. A GL name is an integer the driver has
  /// already freed, so `glDeleteTextures` on it is undefined and may delete a
  /// name the driver has since handed back out - `GlRenderDevice`'s
  /// `discardNativeResources` therefore *forgets* rather than deletes.
  ///
  /// A COM pointer is reference counted by the runtime, and `Release` is the
  /// one call that still works on an object whose device was removed - it is
  /// how the refcount reaches zero and the memory is freed. Skipping it leaks
  /// the whole pipeline: two shaders, an input layout, a rasteriser state, two
  /// samplers, a constant buffer, one blend state per blend mode, and every
  /// texture. On a device that resets four times before the CPU fallback that
  /// is four whole renderers' worth of objects held for the life of the
  /// process.
  @override
  void discardNativeResources() {
    for (final D3d11Texture texture in _texturesById.values.toList()) {
      releaseTexture(texture);
    }
    _texturesById.clear();
    _vertexBuffer?.dispose();
    _vertexBuffer = null;
    _vertexBufferBytes = 0;
    _indexBuffer?.dispose();
    _indexBuffer = null;
    _indexBufferBytes = 0;
    _blendStates.clear();
    _objects.dispose();
    _objects = ComBag();
    _vertexShader = null;
    _pixelShader = null;
    _inputLayout = null;
    _rasterizerState = null;
    _samplerPoint = null;
    _samplerLinear = null;
    _constantBuffer = null;
    // The factory belongs to the removed device's adapter. Keeping it would
    // make the next swap chain be created by a factory for a device that is
    // gone, which is the two-GPU laptop failure `dxgiFactory` documents.
    _factory?.dispose();
    _factory = null;
    _drawState.reset();
    _constantsWidth = -1;
    _constantsHeight = -1;
    _constantsMode = -1;
  }

  /// Step 4: a genuinely new `ID3D11Device`, its context, and the pipeline.
  ///
  /// Unlike the GL backend, this really does create a new device - that is what
  /// `D3D11CreateDevice` is for and it is the documented recovery from
  /// `DXGI_ERROR_DEVICE_REMOVED`. The window is untouched: a swap chain belongs
  /// to a device and is recreated by its target, but the `HWND` outlives every
  /// device made for it, which is exactly the split `renderer.dart` describes.
  ///
  /// The adapter may have changed underneath - that is what unplugging an
  /// external GPU is - so [info], [featureLevel] and [capabilities] are all
  /// re-derived from the new device rather than carried over. A renderer that
  /// kept the old feature level would go on allowing 16384-pixel textures on an
  /// adapter whose limit is 8192.
  @override
  BackendDiagnostic? recreateDevice() {
    if (isDisposed) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'a disposed Direct3D 11 device cannot be recovered',
      );
    }
    final BackendDiagnostic? cause = _state.lossDiagnostic;

    // The old device and context, released before the new ones are asked for:
    // a removed device holds its adapter's resources until its refcount
    // reaches zero, and creating the replacement first would mean both exist
    // at once on a machine that has just run out of whatever killed the first.
    if (!_state.isLost) {
      // A recovery of a healthy device would otherwise release a device that
      // is still drawing.
      unbindTargets();
      context.flush(context.pointer);
    }
    context.dispose();
    device.dispose();

    final _DeviceAttempt attempt = D3d11RendererBackend._createRawDevice(_api);
    if (attempt.device == null) {
      final failure = BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'no Direct3D 11 device could be created to replace the lost '
            'one',
        detail: '${attempt.diagnostics.join('; ')}. The original loss was: '
            '${cause ?? 'not recorded'}',
      );
      _state.recover();
      _state.markLost(failure);
      return failure;
    }

    device = attempt.device!;
    context = attempt.context!;
    _featureLevel = attempt.featureLevel;
    _info = RendererInfo(
      name: D3d11RendererBackend.backendName,
      deviceDescription: D3d11RendererBackend._adapterDescription(device) ??
          'Direct3D 11 (${attempt.driverTypeName})',
      driverVersion: 'feature level '
          '${d3dFeatureLevelName(attempt.featureLevel)}',
    );

    // Cleared only now, and only once a device exists: every creation call
    // below refuses while the state says lost.
    _state.recover();

    final BackendDiagnostic? failure = _initialise();
    if (failure != null) {
      _state.markLost(failure);
      return failure;
    }
    _submissionsStopped = false;
    return null;
  }

  /// Step 5's inventory: everything every live target owns.
  ///
  /// The device's own pipeline objects are not here because [_initialise]
  /// rebuilt them inside step 4; they have no Dart-side source beyond the HLSL
  /// this backend compiles at run time, which is a property worth naming - see
  /// [D3d11RendererBackend.shaderCompilationPolicy]. Compiling at run time is
  /// what makes a recovery able to produce shaders at all; an embedded-bytecode
  /// backend would have to keep the blobs alive across the loss.
  @override
  Iterable<GpuRecoverableResource> recoverableResources() sync* {
    for (final D3d11RecoverableTarget target
        in List<D3d11RecoverableTarget>.of(_targets)) {
      yield* target.recoverableResources();
    }
  }

  // -------------------------------------------------------------------
  // Setup and teardown
  // -------------------------------------------------------------------

  /// Compiles the shaders and builds the pipeline objects.
  ///
  /// Returns a diagnostic on failure instead of throwing, so device creation
  /// can report it the same way a probe does.
  BackendDiagnostic? _initialise() {
    final compile = _api.compile;
    if (compile == null) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.missingLibrary,
        message: 'd3dcompiler_47.dll is not loadable, so there are no shaders',
        detail: 'this backend compiles its HLSL at device creation rather '
            'than embedding bytecode; see '
            'D3d11RendererBackend.shaderCompilationPolicy for why, and for '
            'what embedding instead would cost',
      );
    }

    final Object vertex = _compile(kD3d11VertexProfile, kD3d11VertexEntryPoint);
    if (vertex is BackendDiagnostic) return vertex;
    final Object pixel = _compile(kD3d11PixelProfile, kD3d11PixelEntryPoint);
    if (pixel is BackendDiagnostic) {
      (vertex as D3dBlob).dispose();
      return pixel;
    }
    final vertexBlob = vertex as D3dBlob;
    final pixelBlob = pixel as D3dBlob;
    try {
      final int vsHr = hresult(device.createVertexShader(
        device.pointer,
        vertexBlob.bufferPointer,
        vertexBlob.bufferSize,
        nullptr,
        _out,
      ));
      if (failed(vsHr)) {
        return BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'CreateVertexShader refused the compiled bytecode',
          detail: hresultName(vsHr),
        );
      }
      _vertexShader = _objects
          .keep(ComObject(_out.value, interfaceName: 'ID3D11VertexShader'));

      final int psHr = hresult(device.createPixelShader(
        device.pointer,
        pixelBlob.bufferPointer,
        pixelBlob.bufferSize,
        nullptr,
        _out,
      ));
      if (failed(psHr)) {
        return BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'CreatePixelShader refused the compiled bytecode',
          detail: hresultName(psHr),
        );
      }
      _pixelShader = _objects
          .keep(ComObject(_out.value, interfaceName: 'ID3D11PixelShader'));

      final BackendDiagnostic? layout = _createInputLayout(vertexBlob);
      if (layout != null) return layout;
    } finally {
      vertexBlob.dispose();
      pixelBlob.dispose();
    }

    // A constant buffer's ByteWidth must be a multiple of 16; the four values
    // it holds are exactly one such register.
    final desc = _scratchDesc.cast<Uint32>();
    desc[0] = 16;
    desc[1] = d3d11UsageDefault;
    desc[2] = d3d11BindConstantBuffer;
    desc[3] = 0;
    desc[4] = 0;
    desc[5] = 0;
    final int cbHr = hresult(device.createBuffer(
        device.pointer, _scratchDesc.cast(), nullptr, _out));
    if (failed(cbHr)) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the constant buffer could not be created',
        detail: hresultName(cbHr),
      );
    }
    _constantBuffer =
        _objects.keep(ComObject(_out.value, interfaceName: 'ID3D11Buffer'));

    // Scissoring is always on, unlike GL where it is toggled: a batch without
    // a clip gets a scissor rectangle equal to the viewport, which costs one
    // RSSetScissorRects and removes a piece of state that can be left in the
    // wrong position across a pass boundary. Culling is off for the reason
    // gpu_vertex_buffer.dart gives - a 2D UI has no back faces, and enabling
    // it only creates a way for a projection sign error to make geometry
    // vanish instead of appearing mirrored.
    final rast = _scratchDesc.cast<Uint32>();
    rast[0] = d3d11FillSolid;
    rast[1] = d3d11CullNone;
    rast[2] = 0; // FrontCounterClockwise
    rast[3] = 0; // DepthBias
    _scratchDesc.cast<Float>()[4] = 0; // DepthBiasClamp
    _scratchDesc.cast<Float>()[5] = 0; // SlopeScaledDepthBias
    rast[6] = 1; // DepthClipEnable
    rast[7] = 1; // ScissorEnable
    rast[8] = 0; // MultisampleEnable
    rast[9] = 0; // AntialiasedLineEnable
    final int rsHr = hresult(device.createRasterizerState(
        device.pointer, _scratchDesc.cast(), _out));
    if (failed(rsHr)) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the rasterizer state could not be created',
        detail: hresultName(rsHr),
      );
    }
    _rasterizerState = _objects
        .keep(ComObject(_out.value, interfaceName: 'ID3D11RasterizerState'));

    final ComObject? point = _createSampler(d3d11FilterMinMagMipPoint);
    final ComObject? linear = _createSampler(d3d11FilterMinMagMipLinear);
    if (point == null || linear == null) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'a sampler state could not be created',
      );
    }
    _samplerPoint = point;
    _samplerLinear = linear;
    return null;
  }

  ComObject? _createSampler(int filter) {
    final desc = _scratchDesc.cast<Uint32>();
    for (var i = 0; i < sizeOfSamplerDesc ~/ 4; i++) {
      desc[i] = 0;
    }
    desc[0] = filter;
    desc[1] = d3d11TextureAddressClamp;
    desc[2] = d3d11TextureAddressClamp;
    desc[3] = d3d11TextureAddressClamp;
    _scratchDesc.cast<Float>()[4] = 0; // MipLODBias
    desc[5] = 1; // MaxAnisotropy
    desc[6] = d3d11ComparisonNever;
    // BorderColor[4] at 28..43 stays zero; MinLOD 0, MaxLOD at 48.
    _scratchDesc.cast<Float>()[12] = 0;
    // FLT_MAX, so no mip level is ever clamped away. Written as the literal
    // the header uses rather than double.infinity, which is a different bit
    // pattern and makes CreateSamplerState return E_INVALIDARG.
    _scratchDesc.cast<Float>()[12] = 3.402823466e+38;
    final int hr = hresult(
        device.createSamplerState(device.pointer, _scratchDesc.cast(), _out));
    if (failed(hr)) return null;
    return _objects
        .keep(ComObject(_out.value, interfaceName: 'ID3D11SamplerState'));
  }

  BackendDiagnostic? _createInputLayout(D3dBlob vertexBlob) {
    const List<int> formats = <int>[
      dxgiFormatR32G32Float,
      dxgiFormatR32G32Float,
      dxgiFormatR32G32B32A32Float,
      dxgiFormatR32G32B32A32Float,
    ];
    const List<int> offsets = <int>[
      kGpuPositionOffset * 4,
      kGpuTexCoordOffset * 4,
      kGpuColorOffset * 4,
      kGpuShapeRectOffset * 4,
    ];
    final Pointer<Uint8> elements =
        _arena.allocate<Uint8>(sizeOfInputElementDesc * formats.length);
    for (var i = 0; i < formats.length; i++) {
      final Pointer<Uint8> element =
          Pointer<Uint8>.fromAddress(elements.address + i * 32);
      element.cast<IntPtr>()[0] =
          _arena.allocateAscii(kD3d11SemanticNames[i]).address; // SemanticName
      final fields = Pointer<Uint32>.fromAddress(element.address + 8);
      fields[0] = kD3d11SemanticIndices[i];
      fields[1] = formats[i];
      fields[2] = 0; // InputSlot
      fields[3] = offsets[i]; // AlignedByteOffset
      fields[4] = d3d11InputPerVertexData;
      fields[5] = 0; // InstanceDataStepRate
    }
    final int hr = hresult(device.createInputLayout(
      device.pointer,
      elements.cast(),
      formats.length,
      vertexBlob.bufferPointer,
      vertexBlob.bufferSize,
      _out,
    ));
    if (failed(hr)) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the input layout does not match the vertex shader',
        detail: '${hresultName(hr)}; the layout is the one interleaved vertex '
            'of gpu_pipeline.dart - $kGpuFloatsPerVertex floats - and the '
            'shader declares POSITION0, TEXCOORD0, COLOR0, TEXCOORD1',
      );
    }
    _inputLayout = _objects
        .keep(ComObject(_out.value, interfaceName: 'ID3D11InputLayout'));
    return null;
  }

  /// Compiles [entryPoint] at [profile]. Returns a [D3dBlob] or a diagnostic.
  Object _compile(String profile, String entryPoint) {
    final arena = NativeArena();
    try {
      final Pointer<Uint8> source = arena.allocateAscii(kD3d11ShaderSource);
      final Pointer<Pointer<Void>> code = arena.allocateOutPointer();
      final Pointer<Pointer<Void>> errors = arena.allocateOutPointer();
      final int hr = hresult(_api.compile!(
        source,
        kD3d11ShaderSource.length,
        arena.allocateAscii('dart_ui_d3d11.hlsl'),
        nullptr,
        nullptr,
        arena.allocateAscii(entryPoint),
        arena.allocateAscii(profile),
        // Row-major packing is declared rather than defaulted; see
        // d3d11_shaders.dart, "Disagreement 2".
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
          // The compiler's own message, verbatim. Anything less turns a
          // one-line HLSL error into an afternoon.
          detail: '${hresultName(hr)}: $message',
        );
      }
      return D3dBlob(code.value);
    } finally {
      arena.dispose();
    }
  }

  D3d11LayerTarget _createLayerTarget(int width, int height) {
    final D3d11Texture texture = _createTexture(
      width: width,
      height: height,
      format: GpuTextureFormat.rgba8888Premultiplied,
      // A layer is composited one texel per pixel, so point sampling
      // reproduces exactly what was rendered; a linear tap would resample a
      // grid-aligned image against itself and soften every layer.
      filter: GpuTextureFilter.nearest,
      bindFlags: d3d11BindShaderResource | d3d11BindRenderTarget,
    );
    checkHresult(
      device.createRenderTargetView(
          device.pointer, texture.texture.pointer, nullptr, _out),
      'ID3D11Device::CreateRenderTargetView(layer)',
    );
    return D3d11LayerTarget._(
      _nextLayerId++,
      width,
      height,
      texture,
      ComObject(_out.value, interfaceName: 'ID3D11RenderTargetView'),
    );
  }

  void _destroyLayerTarget(D3d11LayerTarget target) {
    target.renderTarget.dispose();
    releaseTexture(target.texture);
  }

  @override
  void onDispose() {
    // Reverse order throughout: the context first, because it holds references
    // to everything currently bound, then the pipeline objects, then the
    // device. ComBag enforces the order; this only has to register in the
    // order things were acquired.
    if (!_state.isLost) {
      unbindTargets();
      context.flush(context.pointer);
    }
    for (final texture in _texturesById.values.toList()) {
      releaseTexture(texture);
    }
    _vertexBuffer?.dispose();
    _indexBuffer?.dispose();
    _objects.dispose();
    context.dispose();
    device.dispose();
    _arena.dispose();
  }
}

/// A render target backed by a texture the CPU can read back.
final class D3d11OffscreenTarget
    with DisposableMixin
    implements RenderTarget, D3d11RecoverableTarget {
  D3d11OffscreenTarget(this._device, MemorySurfaceDescriptor surface)
      : _surface = surface {
    _maskAtlas = GpuMaskAtlas();
    _glyphAtlas = GpuGlyphAtlas();
    _fonts = D3d11FontResolver();
    _images = D3d11ImageCache(_device);
    _buildAtlasObjects();
    final BackendDiagnostic? failure = _createSurfaceObjects();
    if (failure != null) _device.markLost(failure);
    _device.registerTarget(this);
  }

  /// Creates the atlas textures and everything downstream of their ids.
  ///
  /// Shared by the constructor and by the recovery, for the reason
  /// `gl_backend.dart` gives: the sink holds the two texture ids as final
  /// fields, so rebuilding a texture means rebuilding the sink, and two copies
  /// of that wiring would drift.
  void _buildAtlasObjects() {
    _maskTexture = _device.createTexture(
      width: _maskAtlas.width,
      height: _maskAtlas.height,
      format: GpuTextureFormat.alpha8,
      filter: GpuTextureFilter.nearest,
    );
    _glyphTexture = _device.createTexture(
      width: _glyphAtlas.width,
      height: _glyphAtlas.height,
      format: GpuTextureFormat.alpha8,
      filter: GpuTextureFilter.nearest,
    );
    _layerPool = D3d11LayerPool(_device);
    _layers = GpuLayerStack(
      allocator: _layerPool,
      backendName: D3d11RendererBackend.backendName,
    );
    _sink = GpuRasterSink(
      batcher: _batcher,
      backendName: D3d11RendererBackend.backendName,
      maskAtlas: _maskAtlas,
      maskTextureId: _maskTexture.id,
      imageResolver: _images,
      glyphAtlas: _glyphAtlas,
      glyphTextureId: _glyphTexture.id,
      fontResolver: _fonts,
      layerStack: _layers,
      onAtlasFlush: _flushAtlases,
    );
    _player = DisplayListPlayer(_sink);
  }

  // -------------------------------------------------------------------
  // Device-loss recovery
  // -------------------------------------------------------------------

  /// Step 5's inventory for this target, in rebuild order.
  @override
  Iterable<GpuRecoverableResource> recoverableResources() sync* {
    yield CallbackGpuResource.fixed(
      resourceName: 'direct3d11 offscreen atlases '
          '(mask ${_maskAtlas.width}x${_maskAtlas.height}, glyph '
          '${_glyphAtlas.width}x${_glyphAtlas.height})',
      // Caches: the mask atlas is rewritten every frame from path geometry and
      // the glyph atlas is re-rasterised from outlines that never left Dart.
      recovery: GpuResourceRecovery.rebuilt,
      onDiscard: _discardAtlasObjects,
      onRepopulate: _repopulateAtlasObjects,
    );
    yield CallbackGpuResource.fixed(
      resourceName: 'direct3d11 offscreen surface '
          '${_surface.pixelWidth}x${_surface.pixelHeight}',
      recovery: GpuResourceRecovery.recreated,
      onDiscard: _forgetSurfaceObjects,
      onRepopulate: _createSurfaceObjects,
    );
    yield* _images.recoverableResources();
  }

  void _discardAtlasObjects() {
    // The frame in flight goes with the device: its batches name textures the
    // removed device owned, so it must never be submitted after the recovery.
    _batcher.beginFrame();
    _submittedBatches = 0;
    _pendingClear = null;
    _layers.endFrame();
    _layerPool.dispose();
    _device
      ..releaseTexture(_maskTexture)
      ..releaseTexture(_glyphTexture);
    // Both atlases are caches that outlive a frame, so both have to be told
    // their texels are gone. The mask atlas is the one that is easy to miss:
    // its `beginFrame` deliberately *keeps* every cached mask, so a static
    // rounded rectangle drawn before the loss would be found resident,
    // re-batched against a texture that was never re-uploaded, and drawn as
    // nothing at all - a frame that differs from the pre-loss one by exactly
    // the shapes the cache was working for.
    _maskAtlas.recycle();
    _glyphAtlas.clear();
  }

  BackendDiagnostic? _repopulateAtlasObjects() {
    try {
      _buildAtlasObjects();
    } on Object catch (error) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the recreated Direct3D 11 device refused an atlas texture',
        detail: '$error',
      );
    }
    return null;
  }

  /// Releases the surface COM references without touching the removed device.
  ///
  /// `Release` is legal on an object whose device was removed - see
  /// [D3d11RenderDevice.discardNativeResources] for why that is the opposite of
  /// what GL wants - so this is the same code the healthy path runs.
  void _forgetSurfaceObjects() => _destroySurfaceObjects();

  final D3d11RenderDevice _device;
  final GpuBatcher _batcher = GpuBatcher();

  late final GpuMaskAtlas _maskAtlas;
  late final GpuGlyphAtlas _glyphAtlas;
  late final D3d11FontResolver _fonts;
  late final D3d11ImageCache _images;

  // Not final: a device loss destroys all six and a recovery rebuilds them.
  late D3d11Texture _maskTexture;
  late D3d11Texture _glyphTexture;
  late D3d11LayerPool _layerPool;
  late GpuLayerStack _layers;
  late GpuRasterSink _sink;
  late DisplayListPlayer _player;

  int _submittedBatches = 0;
  int? _pendingClear;

  MemorySurfaceDescriptor _surface;
  late D3d11Texture _colorTexture;
  late ComObject _renderTargetView;
  late ComObject _stagingTexture;
  late Framebuffer _readback;
  int _generation = 0;
  int _observedLossCount = 0;

  /// The textures this target uploaded for drawn images.
  D3d11ImageCache get images => _images;

  /// The glyph coverage this target keeps between frames.
  GpuGlyphAtlas get glyphAtlas => _glyphAtlas;

  /// Where layers get their offscreen targets.
  D3d11LayerPool get layerPool => _layerPool;

  /// The layer stack this target's sink drives.
  GpuLayerStack get layers => _layers;

  GpuBatcher get batcher => _batcher;

  /// The last pixels read back. Golden and parity tests read this.
  Framebuffer get framebuffer => _readback;

  @override
  NativeSurfaceDescriptor get surface => _surface;

  @override
  int get generation {
    final int losses = _device.state.lossCount;
    if (losses != _observedLossCount) {
      _observedLossCount = losses;
      _generation++;
    }
    return _generation;
  }

  @override
  Frame beginFrame(FrameRequest request) {
    throwIfDisposed();
    _batcher.beginFrame();
    _maskAtlas.beginFrame();
    _glyphAtlas.beginFrame();
    _layers.beginFrame(
      surfaceWidth: _readback.width,
      surfaceHeight: _readback.height,
    );
    _submittedBatches = 0;
    _pendingClear = request.clearColor;
    return Frame(
      target: this,
      framebuffer: _readback,
      damage: request.damage ??
          Rect.fromLTWH(
            0,
            0,
            _readback.width.toDouble(),
            _readback.height.toDouble(),
          ),
      generation: generation,
    );
  }

  @override
  Future<PresentResult> present(Frame frame) async {
    throwIfDisposed();
    final PresentResult? blocked = _device.state.blockedPresent();
    if (blocked != null) return blocked;
    if (frame.generation != generation) {
      return const PresentResult(
        status: PresentStatus.stale,
        diagnostic: BackendDiagnostic.note(
          'frame belonged to a previous generation of the target',
        ),
      );
    }

    _uploadMaskAtlas();
    _uploadGlyphAtlas();
    final int? clear = _pendingClear;
    _pendingClear = null;
    final bool drawn = _device.submit(
      _batcher,
      _readback.width,
      _readback.height,
      clear,
      _renderTargetView.pointer,
      layers: _layers,
      firstBatch: _submittedBatches,
    );
    _submittedBatches = _batcher.batchCount;
    // After the draws and never before: until they are issued, the composite
    // quads are still going to sample those layer textures.
    _layers.endFrame();
    if (drawn) _readPixels();

    final PresentResult? lost = _device.state.blockedPresent();
    if (lost != null) return lost;
    return const PresentResult(status: PresentStatus.presented);
  }

  /// Copies the render target into the staging texture and maps it.
  ///
  /// The copy is not avoidable: a texture the GPU renders into cannot also be
  /// `CPU_ACCESS_READ`, so D3D11 splits the two roles and `CopyResource` moves
  /// between them. It is the offscreen target's cost alone; the window target
  /// never does it, which is the rule section 23 sets.
  ///
  /// **No row flip.** A D3D11 render target's row 0 is the top row, and a
  /// [Framebuffer] is top-down, so the rows come out in the order they are
  /// wanted. `GlRenderDevice._readPixels` flips because GL's origin is at the
  /// bottom; doing the same here would mirror every readback vertically.
  void _readPixels() {
    _device.context.copyResource(_device.context.pointer,
        _stagingTexture.pointer, _colorTexture.texture.pointer);
    final NativeArena arena = NativeArena();
    try {
      final Pointer<Uint8> mapped =
          arena.allocate<Uint8>(sizeOfMappedSubresource);
      final int hr = hresult(_device.context.map(_device.context.pointer,
          _stagingTexture.pointer, 0, d3d11MapRead, 0, mapped.cast()));
      if (failed(hr)) {
        _device.checkDeviceRemoved('mapping the readback texture');
        return;
      }
      final Pointer<Uint8> data =
          Pointer<Uint8>.fromAddress(mapped.cast<IntPtr>()[0]);
      final int rowPitch = mapped.cast<Uint32>()[2];
      final int width = _readback.width;
      final int height = _readback.height;
      final source = data.asTypedList(rowPitch * height);
      final bool swizzle =
          _readback.format == PixelFormat.bgra8888Premultiplied;
      for (var y = 0; y < height; y++) {
        final int sourceRow = y * rowPitch;
        final int destinationRow = y * _readback.bytesPerRow;
        if (!swizzle) {
          _readback.pixels.setRange(
            destinationRow,
            destinationRow + width * 4,
            source,
            sourceRow,
          );
          continue;
        }
        for (var x = 0; x < width; x++) {
          final int s = sourceRow + x * 4;
          final int d = destinationRow + x * 4;
          _readback.pixels[d] = source[s + 2];
          _readback.pixels[d + 1] = source[s + 1];
          _readback.pixels[d + 2] = source[s];
          _readback.pixels[d + 3] = source[s + 3];
        }
      }
      _device.context
          .unmap(_device.context.pointer, _stagingTexture.pointer, 0);
    } finally {
      arena.dispose();
    }
  }

  void _uploadMaskAtlas() {
    if (!_maskAtlas.isDirty) return;
    final int top = _maskAtlas.dirtyTop;
    final int height = _maskAtlas.dirtyBottom - top;
    _device.uploadRegion(
      _maskTexture,
      x: 0,
      y: top,
      width: _maskAtlas.width,
      height: height,
      pixels: Uint8List.sublistView(_maskAtlas.pixels, top * _maskAtlas.width),
      bytesPerRow: _maskAtlas.width,
    );
    _maskAtlas.markUploaded();
  }

  /// Sends the plots the frame wrote into, and nothing else.
  ///
  /// Orientation, declared for the same reason `gl_backend.dart` declares it:
  /// the atlas is *uploaded*, not rendered into, so nothing about render-target
  /// orientation applies. `UpdateSubresource` writes the first row of the
  /// pointer it is given at texture row `y`, and [GpuGlyphAtlas.pixels] is
  /// row-major top-down, so atlas row `y` is texture row `y` is texture
  /// coordinate `y / height` - exactly the `v` the sink computes for a glyph
  /// quad's top edge.
  void _uploadGlyphAtlas() {
    if (!_glyphAtlas.isDirty) return;
    final int width = _glyphAtlas.width;
    _glyphAtlas.forEachDirtyRegion((int x, int y, int regionWidth, int height) {
      _glyphUploadCount++;
      _device.uploadRegion(
        _glyphTexture,
        x: x,
        y: y,
        width: regionWidth,
        height: height,
        pixels: Uint8List.sublistView(_glyphAtlas.pixels, y * width + x),
        bytesPerRow: width,
      );
    });
    _glyphAtlas.markUploaded();
  }

  /// `UpdateSubresource` calls this target has made for glyph coverage.
  int get glyphUploadCount => _glyphUploadCount;
  int _glyphUploadCount = 0;

  void _flushAtlases() {
    _uploadMaskAtlas();
    _uploadGlyphAtlas();
    final int? clear = _pendingClear;
    _pendingClear = null;
    _device.submit(
      _batcher,
      _readback.width,
      _readback.height,
      clear,
      _renderTargetView.pointer,
      layers: _layers,
      firstBatch: _submittedBatches,
    );
    _submittedBatches = _batcher.batchCount;
  }

  @override
  void resize(int pixelWidth, int pixelHeight, double scale) {
    throwIfDisposed();
    if (pixelWidth == _readback.width &&
        pixelHeight == _readback.height &&
        scale == _surface.scale) {
      return;
    }
    _generation++;
    _surface = MemorySurfaceDescriptor(
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      scale: scale,
      format: _surface.format,
    );
    _destroySurfaceObjects();
    final BackendDiagnostic? failure = _createSurfaceObjects();
    if (failure != null) _device.markLost(failure);
  }

  /// Rasterises [list] into this target and presents it.
  ///
  /// Mirrors [MemoryRenderTarget.renderDisplayList] and
  /// `GlOffscreenTarget.renderDisplayList` argument for argument, so a parity
  /// test can swap one for another and compare the pixels.
  Future<PresentResult> renderDisplayList(
    DisplayList list, {
    int? clearColor,
    Transform2D deviceTransform = Transform2D.identity,
  }) async {
    final Frame frame = beginFrame(FrameRequest(clearColor: clearColor));
    final resources = DisplayListResources(list);
    _fonts.bind(resources);
    _player.play(
      DisplayListReader(list),
      resources,
      deviceBounds: Rect.fromLTWH(
        0,
        0,
        _readback.width.toDouble(),
        _readback.height.toDouble(),
      ),
      deviceTransform: deviceTransform,
    );
    return present(frame);
  }

  /// Allocates the readback buffer, the colour texture, the render-target view
  /// and the staging texture.
  ///
  /// Returns a diagnostic rather than throwing, because it is called from three
  /// places that want different things: the constructor and [resize] turn a
  /// failure into a device loss, and a *recovery* must not - a recovery that
  /// marked the device lost again would look exactly like a second GPU reset
  /// and would spend one of the policy's attempts on its own bug.
  BackendDiagnostic? _createSurfaceObjects() {
    _readback = Framebuffer.allocate(
      width: _surface.pixelWidth,
      height: _surface.pixelHeight,
      format: _surface.format,
    );
    try {
      return _createSurfaceObjectsOrThrow();
    } on Object catch (error) {
      return BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'the offscreen surface objects could not be created',
        detail: '$error',
      );
    }
  }

  BackendDiagnostic? _createSurfaceObjectsOrThrow() {
    _colorTexture = _device._createTexture(
      width: _surface.pixelWidth,
      height: _surface.pixelHeight,
      format: GpuTextureFormat.rgba8888Premultiplied,
      filter: GpuTextureFilter.nearest,
      bindFlags: d3d11BindRenderTarget | d3d11BindShaderResource,
    );
    checkHresult(
      _device.device.createRenderTargetView(_device.device.pointer,
          _colorTexture.texture.pointer, nullptr, _device._out),
      'ID3D11Device::CreateRenderTargetView(offscreen)',
    );
    _renderTargetView =
        ComObject(_device._out.value, interfaceName: 'ID3D11RenderTargetView');

    _device._writeTexture2DDesc(
      _device._scratchDesc,
      width: _surface.pixelWidth,
      height: _surface.pixelHeight,
      format: dxgiFormatR8G8B8A8Unorm,
      usage: d3d11UsageStaging,
      bindFlags: 0,
      cpuAccess: d3d11CpuAccessRead,
    );
    checkHresult(
      _device.device.createTexture2D(_device.device.pointer,
          _device._scratchDesc.cast(), nullptr, _device._out),
      'ID3D11Device::CreateTexture2D(staging)',
    );
    _stagingTexture =
        ComObject(_device._out.value, interfaceName: 'ID3D11Texture2D');
    return null;
  }

  void _destroySurfaceObjects() {
    _stagingTexture.dispose();
    _renderTargetView.dispose();
    _device.releaseTexture(_colorTexture);
  }

  @override
  void onDispose() {
    _device.unregisterTarget(this);
    _destroySurfaceObjects();
    _images.clear();
    _layers.endFrame();
    _layerPool.dispose();
    _device
      ..releaseTexture(_maskTexture)
      ..releaseTexture(_glyphTexture);
    _glyphAtlas.clear();
    _fonts.bind(null);
  }
}

/// Turns the display list's interned font ids into faces for the sink.
///
/// The same class as `GlFontResolver` and for the same reason; see that file
/// for why the resolver holds the player's own resource table rather than a
/// map of its own.
final class D3d11FontResolver implements GpuFontResolver {
  ReplayResources? _resources;

  void bind(ReplayResources? resources) => _resources = resources;

  @override
  ScaledTypeface? resolveFont(int fontId) {
    final ReplayResources? resources = _resources;
    if (resources == null) return null;
    final Object font = resources.fontAt(fontId);
    return font is ScaledTypeface ? font : null;
  }
}

/// One image this cache uploaded, and whether it could do it again.
final class _D3d11ImageEntry {
  _D3d11ImageEntry({
    required this.index,
    required this.image,
    required this.width,
    required this.height,
    required this.texture,
    required this.source,
  });

  final int index;

  /// Weak, and only so [D3d11ImageCache.clear] can undo the [Expando]
  /// association. See `_GlImageEntry` for the whole argument.
  final WeakReference<Framebuffer> image;
  final int width;
  final int height;

  D3d11Texture? texture;
  Framebuffer? source;

  bool get isRecoverable => source != null;

  String get name => 'direct3d11 image #$index (${width}x$height)';
}

/// Uploads drawn images into textures, once each, and can do it again.
///
/// The D3D11 twin of `GlImageCache`, structurally identical and for the same
/// reasons: the lookup is a weak-keyed [Expando] so it holds nothing alive, and
/// the retention of the source bytes is an explicit policy rather than a side
/// effect of the map key. See [GpuImageSourceRetention] for what each answer
/// costs and what a device loss does to a texture whose source is gone.
///
/// The entry list never evicts: an eviction policy needs a frame budget this
/// framework does not measure yet, and a wrong one re-uploads the image being
/// animated.
final class D3d11ImageCache implements GpuImageResolver {
  D3d11ImageCache(
    this._device, {
    this.retention = GpuImageSourceRetention.retain,
  });

  final D3d11RenderDevice _device;

  final GpuImageSourceRetention retention;

  final Expando<_D3d11ImageEntry> _byImage = Expando<_D3d11ImageEntry>();
  final List<_D3d11ImageEntry> _entries = <_D3d11ImageEntry>[];

  int get length => _entries.length;

  /// How many bytes of image source this cache is keeping alive. Zero under
  /// [GpuImageSourceRetention.uploadOnly].
  int get retainedSourceBytes {
    var bytes = 0;
    for (final _D3d11ImageEntry entry in _entries) {
      if (entry.source != null) bytes += entry.width * entry.height * 4;
    }
    return bytes;
  }

  /// Entries whose source is gone, so a device loss would strand them.
  int get unrecoverableCount =>
      _entries.where((_D3d11ImageEntry e) => !e.isRecoverable).length;

  @override
  GpuTextureHandle? resolve(Object image) {
    if (image is! Framebuffer) return null;
    final _D3d11ImageEntry? cached = _byImage[image];
    if (cached != null) {
      final D3d11Texture? texture = cached.texture;
      if (texture != null && texture.isValid) return texture;
      // The texture died with the device and the bytes that made it are gone.
      // Null is the sink's "this device cannot draw it", which becomes a named
      // error rather than a wrong picture.
      if (!cached.isRecoverable) return null;
    }

    final D3d11Texture? texture = _upload(image);
    if (texture == null) return null;
    if (cached != null) {
      cached.texture = texture;
      return texture;
    }
    final entry = _D3d11ImageEntry(
      index: _entries.length,
      image: WeakReference<Framebuffer>(image),
      width: image.width,
      height: image.height,
      texture: texture,
      source: retention == GpuImageSourceRetention.retain ? image : null,
    );
    _entries.add(entry);
    _byImage[image] = entry;
    return texture;
  }

  D3d11Texture? _upload(Framebuffer image) {
    final D3d11Texture texture;
    try {
      texture = _device.createTexture(
        width: image.width,
        height: image.height,
        format: GpuTextureFormat.rgba8888Premultiplied,
        filter: GpuTextureFilter.linear,
      );
    } on UnsupportedCapabilityError {
      return null;
    }

    _device.uploadRegion(
      texture,
      x: 0,
      y: 0,
      width: image.width,
      height: image.height,
      pixels: _asRgba(image),
      bytesPerRow: image.width * 4,
    );
    return texture;
  }

  /// Forgets the bytes of [image] while keeping its texture. After this call a
  /// device loss strands the texture, and the recovery names it rather than
  /// drawing with a pointer into a released device.
  bool dropSource(Object image) {
    if (image is! Framebuffer) return false;
    final _D3d11ImageEntry? entry = _byImage[image];
    if (entry == null) return false;
    entry.source = null;
    return true;
  }

  /// This cache's contribution to step 5's inventory: one resource per image,
  /// because one entry can be recoverable while the one next to it is not.
  Iterable<GpuRecoverableResource> recoverableResources() sync* {
    for (final _D3d11ImageEntry entry in List<_D3d11ImageEntry>.of(_entries)) {
      yield CallbackGpuResource(
        resourceName: entry.name,
        recoveryOf: () => entry.isRecoverable
            ? GpuResourceRecovery.reuploaded
            : GpuResourceRecovery.orphaned,
        onDiscard: () => entry.texture = null,
        onRepopulate: () {
          final Framebuffer? source = entry.source;
          if (source == null) {
            return BackendDiagnostic(
              kind: DiagnosticKind.incompatibleDevice,
              message: '${entry.name} cannot be re-uploaded',
              detail: 'its source was dropped, so the only copy of the pixels '
                  'died with the device',
            );
          }
          final D3d11Texture? texture = _upload(source);
          if (texture == null) {
            return BackendDiagnostic(
              kind: DiagnosticKind.incompatibleDevice,
              message: '${entry.name} could not be re-uploaded',
              detail: 'the recreated device refused a '
                  '${entry.width}x${entry.height} texture',
            );
          }
          entry.texture = texture;
          return null;
        },
      );
    }
  }

  void clear() {
    for (final _D3d11ImageEntry entry in _entries) {
      final D3d11Texture? texture = entry.texture;
      if (texture != null) _device.releaseTexture(texture);
      entry.texture = null;
      entry.source = null;
      final Framebuffer? image = entry.image.target;
      if (image != null) _byImage[image] = null;
    }
    _entries.clear();
  }

  /// The image's bytes in the R8G8B8A8 order the texture was created with.
  ///
  /// D3D11 does have `DXGI_FORMAT_B8G8R8A8_UNORM` and could sample a BGRA
  /// image directly, unlike GLES. It is swizzled anyway, for a reason that is
  /// about this renderer and not about the API: a second texture format would
  /// be a second sampling path, and the shader's `mode == 2` branch would have
  /// to know which one it was reading. One format, one branch.
  static Uint8List _asRgba(Framebuffer image) {
    final packed = Uint8List(image.width * image.height * 4);
    final bool swizzle = image.format == PixelFormat.bgra8888Premultiplied;
    for (var y = 0; y < image.height; y++) {
      final int source = y * image.bytesPerRow;
      final int destination = y * image.width * 4;
      if (!swizzle) {
        packed.setRange(
          destination,
          destination + image.width * 4,
          image.pixels,
          source,
        );
        continue;
      }
      for (var x = 0; x < image.width; x++) {
        final int s = source + x * 4;
        final int d = destination + x * 4;
        packed[d] = image.pixels[s + 2];
        packed[d + 1] = image.pixels[s + 1];
        packed[d + 2] = image.pixels[s];
        packed[d + 3] = image.pixels[s + 3];
      }
    }
    return packed;
  }
}

/// The Direct3D 11 renderer backend.
final class D3d11RendererBackend implements RendererBackend {
  const D3d11RendererBackend();

  static const String backendName = 'direct3d11';

  @override
  RendererInfo get info => const RendererInfo(
        name: backendName,
        deviceDescription: 'Direct3D 11 via DXGI',
      );

  /// Why the HLSL is compiled at run time instead of embedded as bytecode.
  ///
  /// The two options are real and the trade is not obvious, so the reasoning is
  /// recorded here rather than left to be re-derived:
  ///
  /// **Embedding bytecode** means running `fxc.exe` - or `dxc` - over the HLSL
  /// and checking the resulting `.cso` into the repository as a Dart byte
  /// array. It removes a DLL dependency and a few milliseconds from device
  /// creation. It costs a build step that is not Dart, cannot run in this
  /// repository's CI (which is Linux and macOS as well as Windows), and cannot
  /// be regenerated by anyone who does not have the Windows SDK installed. The
  /// blob would be opaque: a reviewer could not tell whether it matched the
  /// HLSL next to it, and nothing in the test suite could check.
  ///
  /// **Compiling at run time** costs `d3dcompiler_47.dll`, which has shipped in
  /// `System32` on every Windows since 8.1, and one compile of two small
  /// shaders per device - measured in single-digit milliseconds, once per
  /// process, off the frame path. In exchange the shader source *is* the
  /// artefact: it is reviewable, greppable, diffable, and a test can assert
  /// that it compiles.
  ///
  /// This backend compiles at run time, and it says so when it cannot: a
  /// missing compiler is a named [DiagnosticKind.missingLibrary] from
  /// [probe] and a refused device from [createDevice], never a silent fallback
  /// to a backend that would have drawn a different picture.
  ///
  /// The decision is reversible without touching anything above this file: the
  /// only thing that would change is `_compile`, which already returns bytes.
  static const String shaderCompilationPolicy = 'runtime';

  @override
  bool supportsSurface(NativeSurfaceDescriptor surface) =>
      surface is MemorySurfaceDescriptor ||
      surface is D3d11WindowSurfaceDescriptor;

  /// Whether Direct3D 11 can run here, and if not, exactly what was missing.
  ///
  /// Never throws, for the reason section 6.6 gives: a probe that throws takes
  /// the whole backend selection down with it, which is worse than one that
  /// lies.
  @override
  BackendProbeResult probe() {
    try {
      return _probe();
    } on Object catch (error, stack) {
      return BackendProbeResult.unsupported(
        backendName,
        BackendDiagnostic(
          kind: DiagnosticKind.unsupportedPlatform,
          message: 'the Direct3D 11 probe threw, which is a bug in the probe',
          detail: '$error\n$stack',
        ),
      );
    }
  }

  BackendProbeResult _probe() {
    final D3d11LibraryLoad load = D3d11Libraries.open();
    if (!load.isLoaded) {
      return BackendProbeResult(
        backendName: backendName,
        supported: false,
        diagnostics: load.diagnostics,
      );
    }
    if (!NativeAllocator.isAvailable) {
      return BackendProbeResult.unsupported(
        backendName,
        const BackendDiagnostic.missingSymbol(
          'malloc',
          detail: 'no native allocator could be bound; see '
              'NativeAllocator.tryBind',
        ),
      );
    }

    final diagnostics = <BackendDiagnostic>[...load.diagnostics];
    final _DeviceAttempt attempt = _createRawDevice(D3d11Api(load.libraries!));
    if (attempt.device == null) {
      diagnostics.addAll(attempt.diagnostics);
      return BackendProbeResult(
        backendName: backendName,
        supported: false,
        diagnostics: diagnostics,
      );
    }

    final D3d11Device device = attempt.device!;
    final D3d11DeviceContext context = attempt.context!;
    diagnostics.addAll(attempt.diagnostics);
    try {
      diagnostics.add(BackendDiagnostic.note(
        '${_adapterDescription(device) ?? 'unknown adapter'}, feature level '
        '${d3dFeatureLevelName(attempt.featureLevel)}',
        detail: 'driver type ${attempt.driverTypeName}; shaders are compiled '
            'at run time by d3dcompiler_47.dll '
            '(${load.libraries!.compiler == null ? 'MISSING' : 'present'})',
      ));
      diagnostics.add(const BackendDiagnostic.note(
        'text: drawn on the GPU from a resident R8_UNORM glyph atlas',
        detail: 'every target this backend builds wires a GpuGlyphAtlas, the '
            'texture it stages into and a GpuFontResolver, so a glyph run is '
            'rasterised once and cached across frames rather than refused. '
            'Coverage only - no colour glyphs, no SDF, and text under a '
            'rotated, skewed or non-uniformly scaled transform is still '
            'refused by name',
      ));
      diagnostics.add(const BackendDiagnostic.note(
        'DirectComposition: not wired',
        detail: 'section 13.14 asks for IDCompositionDevice / Target / Visual '
            'so a swap chain can be a composed visual rather than a window\'s '
            'own back buffer. This backend presents through '
            'IDXGIFactory2::CreateSwapChainForHwnd only. What is missing, by '
            'name: DCompositionCreateDevice, IDCompositionDevice::'
            'CreateTargetForHwnd, IDCompositionDevice::CreateVisual, '
            'IDCompositionVisual::SetContent, IDCompositionTarget::SetRoot '
            'and IDCompositionDevice::Commit, plus '
            'IDXGIFactory2::CreateSwapChainForComposition in place of the '
            'ForHwnd call. Without it there is no per-visual transform and no '
            'transparent, non-rectangular window',
      ));
      if (load.libraries!.compiler == null) {
        return BackendProbeResult(
          backendName: backendName,
          supported: false,
          diagnostics: diagnostics,
        );
      }
      return BackendProbeResult(
        backendName: backendName,
        supported: true,
        capabilities: <Capability>{
          Capability.cpuPresentation,
          Capability.gpuPresentation,
          // Present's sync interval is the vsync control, and it is part of
          // the same call rather than a separate extension the driver may
          // lack - unlike WGL_EXT_swap_control.
          Capability.vsync,
        },
        diagnostics: diagnostics,
      );
    } finally {
      context.dispose();
      device.dispose();
    }
  }

  /// Opens a device, or throws [BackendSelectionError] carrying the probe.
  @override
  Future<RenderDevice> createDevice() async => openDevice();

  /// The synchronous form. Device creation is synchronous on this API and the
  /// tests want it without an await.
  static D3d11RenderDevice openDevice() {
    final D3d11LibraryLoad load = D3d11Libraries.open();
    if (!load.isLoaded) {
      throw BackendSelectionError(
        requested: backendName,
        attempts: <BackendProbeResult>[
          BackendProbeResult(
            backendName: backendName,
            supported: false,
            diagnostics: load.diagnostics,
          ),
        ],
      );
    }
    final api = D3d11Api(load.libraries!);
    final _DeviceAttempt attempt = _createRawDevice(api);
    if (attempt.device == null) {
      throw BackendSelectionError(
        requested: backendName,
        attempts: <BackendProbeResult>[
          BackendProbeResult(
            backendName: backendName,
            supported: false,
            diagnostics: <BackendDiagnostic>[
              ...load.diagnostics,
              ...attempt.diagnostics,
            ],
          ),
        ],
      );
    }

    final device = D3d11RenderDevice._(
      api: api,
      device: attempt.device!,
      context: attempt.context!,
      featureLevel: attempt.featureLevel,
      info: RendererInfo(
        name: backendName,
        deviceDescription: _adapterDescription(attempt.device!) ??
            'Direct3D 11 (${attempt.driverTypeName})',
        driverVersion: 'feature level '
            '${d3dFeatureLevelName(attempt.featureLevel)}',
      ),
    );
    final BackendDiagnostic? failure = device._initialise();
    if (failure != null) {
      device.dispose();
      throw BackendSelectionError(
        requested: backendName,
        attempts: <BackendProbeResult>[
          BackendProbeResult(
            backendName: backendName,
            supported: false,
            diagnostics: <BackendDiagnostic>[
              ...load.diagnostics,
              ...attempt.diagnostics,
              failure,
            ],
          ),
        ],
      );
    }
    return device;
  }

  /// The adapter string, or null when DXGI would not say.
  static String? _adapterDescription(D3d11Device device) {
    final ComObject? dxgiDevice =
        device.queryInterface(iidIdxgiDevice, interfaceName: 'IDXGIDevice');
    if (dxgiDevice == null) return null;
    final arena = NativeArena();
    try {
      final wrapped = DxgiDevice(dxgiDevice.pointer);
      final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
      if (failed(wrapped.getAdapter(wrapped.pointer, out)) ||
          out.value == nullptr) {
        return null;
      }
      final adapter = DxgiAdapter(out.value);
      try {
        final Pointer<Uint8> desc = arena.allocate<Uint8>(sizeOfAdapterDesc);
        if (failed(adapter.getDesc(adapter.pointer, desc.cast()))) return null;
        // DXGI_ADAPTER_DESC.Description is a fixed 128-WCHAR array, NUL
        // padded. Dart strings are UTF-16 code units already, so this is a
        // copy rather than a transcode.
        final units = desc.cast<Uint16>().asTypedList(128);
        var end = 0;
        while (end < 128 && units[end] != 0) {
          end++;
        }
        return String.fromCharCodes(units, 0, end);
      } finally {
        adapter.dispose();
      }
    } finally {
      arena.dispose();
      dxgiDevice.dispose();
    }
  }

  /// Creates the raw device, hardware first and WARP second.
  ///
  /// WARP is not a consolation prize here: it is a fully conformant feature
  /// level 11.1 software rasteriser that ships with Windows, so a CI machine
  /// or a remote-desktop session that has no GPU still runs the same shaders
  /// through the same code path. The fallback is *reported* rather than
  /// silent - section 6.6 - because a frame budget measured on WARP means
  /// nothing.
  static _DeviceAttempt _createRawDevice(D3d11Api api) {
    final diagnostics = <BackendDiagnostic>[];
    final arena = NativeArena();
    try {
      final Pointer<Uint32> levels =
          arena.allocate<Uint32>(4 * kD3d11FeatureLevels.length);
      for (var i = 0; i < kD3d11FeatureLevels.length; i++) {
        levels[i] = kD3d11FeatureLevels[i];
      }
      final Pointer<Pointer<Void>> deviceOut = arena.allocateOutPointer();
      final Pointer<Pointer<Void>> contextOut = arena.allocateOutPointer();
      final Pointer<Uint32> selected = arena.allocate<Uint32>(4);

      for (final int driverType in <int>[
        d3dDriverTypeHardware,
        d3dDriverTypeWarp,
      ]) {
        // Two attempts per driver type: the full list, then the list without
        // 11.1. A pre-11.1 runtime rejects the whole array with E_INVALIDARG
        // rather than skipping the level it does not know.
        for (var skip = 0; skip < 2; skip++) {
          final int hr = hresult(api.createDevice(
            nullptr,
            driverType,
            nullptr,
            d3d11CreateDeviceBgraSupport,
            Pointer<Uint32>.fromAddress(levels.address + skip * 4),
            kD3d11FeatureLevels.length - skip,
            d3d11SdkVersion,
            deviceOut,
            selected,
            contextOut,
          ));
          if (succeeded(hr) && deviceOut.value != nullptr) {
            if (driverType == d3dDriverTypeWarp) {
              diagnostics.add(const BackendDiagnostic.note(
                'no hardware Direct3D 11 device; running on WARP',
                detail: 'WARP is a conformant software rasteriser and runs the '
                    'same shaders, but any timing measured on it is a timing '
                    'of the CPU',
              ));
            }
            return _DeviceAttempt(
              device: D3d11Device(deviceOut.value),
              context: D3d11DeviceContext(contextOut.value),
              featureLevel: selected[0],
              driverType: driverType,
              diagnostics: diagnostics,
            );
          }
          if (hr != eInvalidArg) break;
        }
        diagnostics.add(BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: driverType == d3dDriverTypeHardware
              ? 'no hardware Direct3D 11 device'
              : 'no WARP Direct3D 11 device either',
          detail: 'D3D11CreateDevice refused every feature level down to '
              '${d3dFeatureLevelName(kD3d11FeatureLevels.last)}',
        ));
      }
      return _DeviceAttempt(diagnostics: diagnostics);
    } finally {
      arena.dispose();
    }
  }
}

final class _DeviceAttempt {
  const _DeviceAttempt({
    this.device,
    this.context,
    this.featureLevel = 0,
    this.driverType = d3dDriverTypeUnknown,
    required this.diagnostics,
  });

  final D3d11Device? device;
  final D3d11DeviceContext? context;
  final int featureLevel;
  final int driverType;
  final List<BackendDiagnostic> diagnostics;

  String get driverTypeName => switch (driverType) {
        d3dDriverTypeHardware => 'hardware',
        d3dDriverTypeWarp => 'WARP',
        d3dDriverTypeReference => 'reference',
        d3dDriverTypeSoftware => 'software',
        _ => 'unknown',
      };
}
