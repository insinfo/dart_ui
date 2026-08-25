/// The Direct3D 12 device: everything a target needs and nothing a target owns.
///
/// ## Where this file sits, and why it is not under `lib/src/rendering`
///
/// The OpenGL backend keeps its device in `lib/src/rendering/gpu/gl/` because
/// nothing in it names an operating system. This one cannot: it is built on
/// `d3d12_library.dart`, which opens `d3d12.dll`, `dxgi.dll`,
/// `d3dcompiler_47.dll` and the kernel, and `test/architecture/layering_test.dart`
/// forbids a core file from naming any of them. The parts that *are* portable -
/// the HLSL and the window surface descriptor - live in
/// `lib/src/rendering/gpu/d3d12/`, which is exactly the split the GL backend
/// makes between `gl_shaders.dart` and `win32_gl_surface.dart`.
///
/// The layer above is untouched by the difference: this device drives the same
/// [GpuBatcher], [GpuMaskAtlas], [GpuGlyphAtlas] and [GpuRasterSink] the GL one
/// does. They are device-independent on purpose and duplicating any of them
/// here would be duplicating the renderer, not porting it.
///
/// ## What is declared and what is refused
///
/// **Drawn:** solid rectangles with analytic coverage, antialiased paths and
/// rounded rectangles through the coverage-mask atlas, images, and text through
/// the glyph atlas. All three pipeline modes of `gpu_pipeline.dart`, all three
/// blend modes of the display list.
///
/// **Refused by name:** `saveLayer` that needs a real offscreen pass. This
/// device passes no [GpuLayerStack] to its sink, so `gpu_raster_sink.dart`
/// raises a named [UnsupportedCapabilityError] instead of flattening the layer
/// into its parent - which would render a subtree at full opacity and look like
/// a paint bug rather than a missing feature. Section 6.6: a backend that says
/// what it cannot do is worth more than one that quietly does it wrong. The
/// machinery it needs is a pooled render-target texture with an RTV and an SRV,
/// which this file already builds for [D3d12OffscreenTarget]; what is missing
/// is the pool and the `GpuLayerTargetAllocator` over it.
///
/// ## The debug layer, and how it is decided
///
/// `ID3D12Debug::EnableDebugLayer` is called **only when the caller asks**, via
/// `debugLayer: true` on [D3d12RenderDevice.open]. It is not tied to Dart's
/// assert mode, and that is a deliberate choice rather than an oversight: the
/// debug layer costs a large multiple of the driver's own validation on every
/// call, it requires the optional "Graphics Tools" Windows feature (without
/// which `D3D12GetDebugInterface` answers
/// `DXGI_ERROR_SDK_COMPONENT_MISSING`), and a renderer that enabled it because
/// the Dart VM happened to be in checked mode would make a debug build's frame
/// times meaningless. The tests ask for it; an application asks for it when it
/// is chasing a barrier bug. Everything else runs without it and says so in the
/// probe report.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../../../foundation/diagnostics.dart';
import '../../../foundation/lifecycle.dart';
import '../../../graphics/display_list_opcodes.dart';
import '../../../graphics/image/decoded_image.dart' show ImageChannelOrder;
import '../../../rendering/framebuffer.dart';
import '../../../rendering/gpu/d3d12/d3d12_compute_tile_executor.dart';
import '../../../rendering/gpu/d3d12/d3d12_shaders.dart';
import '../../../rendering/gpu/d3d12/d3d12_sparse_executor.dart';
import '../../../rendering/gpu/d3d12/d3d12_surface_descriptor.dart';
import '../../../rendering/gpu/gpu_batcher.dart';
import '../../../rendering/gpu/gpu_device_state.dart';
import '../../../rendering/gpu/gpu_path_strategy.dart';
import '../../../rendering/gpu/gpu_pipeline.dart';
import '../../../rendering/gpu/gpu_raster_sink.dart';
import '../../../rendering/gpu/gpu_texture.dart';
import '../../../rendering/gpu/gpu_video_image.dart';
import '../../../rendering/gpu/vector/compute_tile_scene.dart';
import '../../../rendering/gpu/vector/sparse_strip_draw_plan.dart';
import '../../../rendering/renderer.dart';
import '../../../rendering/replay/display_list_player.dart';
import '../../../text/typeface.dart';
import 'd3d12_arena.dart';
import 'd3d12_com.dart';
import 'd3d12_compute_tile_driver.dart';
import 'd3d12_frame_ring.dart';
import 'd3d12_interfaces.dart';
import 'd3d12_library.dart';
import 'd3d12_offscreen_target.dart';
import 'd3d12_sparse_driver.dart';
import 'd3d12_structs.dart';
import 'd3d12_window_target.dart';

/// The pixel format every surface and every image texture this backend creates
/// carries.
///
/// `DXGI_FORMAT_R8G8B8A8_UNORM`, so a readback is already in the byte order
/// [PixelFormat.rgba8888Premultiplied] names and a BGRA caller pays one
/// swizzle on the readback path only. Fixing it here rather than negotiating
/// per surface is what keeps one set of pipeline state objects valid for every
/// target: the render-target format is part of a PSO, so a second surface
/// format would mean a second set of them.
const int kD3d12SurfaceFormat = dxgiFormatR8G8B8A8Unorm;

/// The `DXGI_FORMAT` a texture in [format] is created and copied into.
///
/// One function and not a ternary at each of the two sites that need it - the
/// resource description and the copy footprint - because those two must agree
/// or the upload writes correct bytes at an incorrect pitch. It is a `switch`
/// so that a format added to [GpuTextureFormat] later fails to compile here
/// instead of silently landing in the wrong layout.
///
/// [GpuTextureFormat.bgra8888Premultiplied] is a *sampled* format only. It
/// never reaches a render target, so it needs no second set of pipeline state
/// objects: the format baked into a PSO is the render-target's, and a
/// shader-resource view's format lives in the descriptor.
int _dxgiFormatFor(GpuTextureFormat format) => switch (format) {
      GpuTextureFormat.alpha8 => dxgiFormatR8Unorm,
      GpuTextureFormat.bgra8888Premultiplied => dxgiFormatB8G8R8A8Unorm,
      GpuTextureFormat.rgba8888Straight ||
      GpuTextureFormat.rgba8888Premultiplied =>
        kD3d12SurfaceFormat,
    };

/// A texture owned by a [D3d12RenderDevice].
///
/// [id] is the index of its shader-resource view in the device's descriptor
/// heap, which makes binding it one add rather than a map lookup. Index 0 is
/// reserved for the 1x1 placeholder the device binds when a batch samples
/// nothing, so a real texture's id is never [kNoTexture].
final class D3d12Texture implements GpuTextureHandle {
  D3d12Texture._(
    this.id,
    this.width,
    this.height,
    this.format,
    this.filter,
    this._resource,
    this._state,
  );

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

  final Pointer<Void> _resource;
  final GpuDeviceState _state;

  /// The Direct3D resource state this texture is currently in.
  ///
  /// Tracked on the Dart side because Direct3D 12 has no way to ask. A barrier
  /// whose `StateBefore` does not match the resource's actual state is the
  /// error the debug layer complains loudest about, and without it the driver
  /// is entitled to leave the resource in a layout the shader cannot read.
  int _resourceState = d3d12ResourceStateCopyDest;

  /// Whether this texture was created with `ALLOW_RENDER_TARGET`.
  ///
  /// Render targets are excluded from the bulk transition into
  /// `PIXEL_SHADER_RESOURCE` that runs before every submission: a surface
  /// being drawn into must stay in `RENDER_TARGET`, and moving it would make
  /// the very next draw call illegal. Nothing samples one today, because
  /// layers are not implemented here; the flag is what will keep this correct
  /// when they are.
  bool _isRenderTarget = false;

  /// Whether this texture is written by a compute shader through a UAV.
  ///
  /// Excluded from the bulk transition into `PIXEL_SHADER_RESOURCE` for the
  /// same reason a render target is, and the failure is worse: a coverage
  /// texture moved to a read state behind the dispatch's back makes the very
  /// next `Dispatch` an illegal write, and the debug layer reports it against
  /// the dispatch rather than against the barrier. Its state is moved
  /// explicitly, twice per composed draw, by the compute-tile driver.
  bool _isUnorderedAccess = false;

  bool _released = false;

  @override
  bool get isValid => !_released && !_state.isLost;

  @override
  String toString() =>
      'D3d12Texture($id, ${width}x$height, ${format.name}, ${filter.name})';
}

/// A coverage texture and the two descriptor indices that view it.
///
/// The pair exists because the two views live in the same shader-visible heap
/// but at different slots, and both have to be released together: a UAV slot
/// left behind would be handed to the next texture while still describing a
/// resource that no longer exists.
final class D3d12ComputeCoverageTexture {
  const D3d12ComputeCoverageTexture._(this.texture, this.unorderedAccessIndex);

  /// The resource. Its [D3d12Texture.id] is the *shader resource* descriptor
  /// index, which is what the composite pass binds.
  final D3d12Texture texture;

  /// The descriptor index of the unordered-access view, which is what the
  /// dispatch binds.
  final int unorderedAccessIndex;

  int get width => texture.width;
  int get height => texture.height;
}

/// What [D3d12RenderDevice.open] found, whether or not it succeeded.
final class D3d12DeviceAttempt {
  const D3d12DeviceAttempt(this.device, this.diagnostics);

  final D3d12RenderDevice? device;
  final List<BackendDiagnostic> diagnostics;

  bool get isOpen => device != null;

  /// The failures, joined, for a `skip:` reason or a log line.
  String get failureText =>
      diagnostics.where((BackendDiagnostic d) => d.isFailure).join('; ');
}

/// An open Direct3D 12 device, its queue, its frame ring and its shared state.
final class D3d12RenderDevice
    with DisposableMixin
    implements RenderDevice, GpuTextureAllocator {
  D3d12RenderDevice._({
    required D3d12Library library,
    required DxgiFactory4 factory,
    required D3d12Device device,
    required D3d12CommandQueue queue,
    required D3d12FrameRing frames,
    required int featureLevel,
    required String adapterDescription,
    required D3d12InfoQueue? infoQueue,
    required List<BackendDiagnostic> notes,
    required bool sparseStripsRequested,
    required bool computeTilesRequested,
  })  : _library = library,
        _factory = factory,
        _device = device,
        _queue = queue,
        _frames = frames,
        _featureLevel = featureLevel,
        _adapterDescription = adapterDescription,
        _infoQueue = infoQueue,
        _notes = notes,
        _sparseStripsRequested = sparseStripsRequested,
        _computeTilesRequested = computeTilesRequested;

  static const String backendName = 'direct3d12';

  /// Descriptors in the shader-visible heap, which is also the ceiling on how
  /// many textures one device may hold at once.
  ///
  /// 256 is generous for a UI: two atlases plus one texture per distinct drawn
  /// image. It is fixed rather than grown because growing a shader-visible heap
  /// means creating a second one and re-creating every view in it, and a
  /// renderer that silently did that mid-frame would stall on a boundary nobody
  /// could see. Running out is reported by name from [createTexture].
  static const int kTextureCapacity = 256;

  /// Descriptors in the render-target-view heap.
  ///
  /// Enough for several swap chains' worth of back buffers plus the offscreen
  /// targets a test opens. Not shader-visible, so it costs almost nothing.
  static const int kRenderTargetCapacity = 64;

  /// The largest texture feature level 11_0 guarantees.
  ///
  /// A constant rather than a query: `D3D12_REQ_TEXTURE2D_U_OR_V_DIMENSION` is
  /// 16384 for every feature level this backend accepts, so there is nothing to
  /// ask the device.
  static const int kMaxTextureSize = 16384;

  final D3d12Library _library;
  final DxgiFactory4 _factory;
  final D3d12Device _device;
  final D3d12CommandQueue _queue;
  final D3d12FrameRing _frames;
  final int _featureLevel;
  final String _adapterDescription;
  final D3d12InfoQueue? _infoQueue;
  final List<BackendDiagnostic> _notes;
  final GpuDeviceState _state = GpuDeviceState();

  /// Whether the caller asked for the opt-in sparse-strip executor.
  ///
  /// A field rather than a lazily-built object: a renderer that compiled a
  /// second pair of shaders and built three more pipeline state objects the
  /// first time somebody happened to call [submitSparseStrips] would stall on a
  /// driver compile inside a frame, which is the cost `d3d12_shaders.dart` says
  /// this backend does not pay.
  final bool _sparseStripsRequested;
  D3d12SparseDriver? _sparseDriver;
  SparseD3d12Executor? _sparseExecutor;

  /// Whether the caller asked for the opt-in compute-tile executor, for the
  /// same reason [_sparseStripsRequested] is a field.
  final bool _computeTilesRequested;
  D3d12ComputeTileDriver? _computeTileDriver;
  ComputeTileD3d12Executor? _computeTileExecutor;

  /// The one storage texture every composed draw writes and then samples.
  ///
  /// One for the device rather than one per target: it is transient within a
  /// draw - written, read, and never looked at again - so two targets can share
  /// it as long as neither is mid-composite, which single-threaded frame
  /// submission guarantees.
  D3d12ComputeCoverageTexture? _computeCoverage;

  /// The per-draw strategy policy this device's targets plan with.
  ///
  /// Device level rather than target level because the thresholds it carries
  /// are about what this hardware is good at, not about which surface is being
  /// drawn into. A target reads it when it builds its planning telemetry, so a
  /// change takes effect for targets created afterwards - which is the only
  /// point at which changing it is safe, because a plan measured under one
  /// policy must not be executed under another.
  GpuPathStrategySelector experimentalPathStrategySelector =
      const GpuPathStrategySelector();

  /// Whether an opt-in sparse-strip pipeline exists on this device.
  bool get experimentalSparseStripsEnabled => _sparseExecutor != null;

  /// Whether an opt-in compute-tile pipeline exists on this device.
  bool get experimentalComputeTilesEnabled => _computeTileExecutor != null;

  late final D3d12DescriptorHeap _rtvHeap;
  late final D3d12DescriptorHeap _srvHeap;
  late final int _rtvStride;
  late final int _srvStride;
  late final Pointer<Void> _rootSignature;
  late final Map<int, Pointer<Void>> _pipelines;
  late final D3dBlob _vertexBlob;
  late final D3dBlob _pixelBlob;
  late final D3d12Texture _placeholder;

  final List<int> _freeRtv = <int>[];
  final List<int> _freeSrv = <int>[];
  int _nextRtv = 0;

  /// The next unused shader-resource view index. Starts at 1: index 0 is the
  /// placeholder, whose id would otherwise be [kNoTexture].
  int _nextSrv = 1;

  /// The `HRESULT` of the last refused `CreateCommittedResource`, so the error
  /// a caller sees names the driver's own reason instead of guessing between
  /// "out of memory" and "out of descriptors".
  int _lastTextureHresult = 0;

  final List<D3d12Texture> _textures = <D3d12Texture>[];

  /// Which static sampler each descriptor index wants, indexed by texture id.
  ///
  /// A flat list rather than a lookup through [_textures], because [submit]
  /// asks once per batch and a linear scan there would turn a per-frame cost
  /// into a quadratic one on a scene with many images.
  final List<int> _samplers =
      List<int>.filled(kTextureCapacity, kD3d12SamplerPoint);

  // Per-frame scratch, allocated once. A frame performs no native allocation.
  late final Pointer<D3d12Viewport> _viewport =
      _library.allocator.allocate<D3d12Viewport>(sizeOf<D3d12Viewport>());
  late final Pointer<D3d12Rect> _scissor =
      _library.allocator.allocate<D3d12Rect>(sizeOf<D3d12Rect>());
  late final Pointer<IntPtr> _rtvSlot =
      _library.allocator.allocate<IntPtr>(sizeOf<IntPtr>());
  late final Pointer<Float> _clearColor =
      _library.allocator.allocate<Float>(sizeOf<Float>() * 4);
  late final Pointer<Uint32> _rootConstants =
      _library.allocator.allocate<Uint32>(4 * kD3d12RootConstantCount);
  late final Pointer<D3d12VertexBufferView> _vertexView = _library.allocator
      .allocate<D3d12VertexBufferView>(sizeOf<D3d12VertexBufferView>());
  late final Pointer<D3d12IndexBufferView> _indexView = _library.allocator
      .allocate<D3d12IndexBufferView>(sizeOf<D3d12IndexBufferView>());
  late final Pointer<Pointer<Void>> _heapSlot =
      _library.allocator.allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());
  late final Pointer<D3d12TextureCopyLocation> _copyDestination = _library
      .allocator
      .allocate<D3d12TextureCopyLocation>(sizeOf<D3d12TextureCopyLocation>());
  late final Pointer<D3d12TextureCopyLocation> _copySource = _library.allocator
      .allocate<D3d12TextureCopyLocation>(sizeOf<D3d12TextureCopyLocation>());

  /// Eight bytes the descriptor heaps write their start handles through.
  ///
  /// See [D3d12DescriptorHeap]: the runtime returns those two handles by
  /// hidden pointer rather than in a register, so a buffer has to exist and
  /// has to outlive every heap that was handed it.
  late final Pointer<Uint64> _descriptorHandleSlot =
      _library.allocator.allocate<Uint64>(8);

  Pointer<D3d12ResourceBarrier> _barriers = nullptr;
  int _barrierCapacity = 0;

  /// The redundant-state filter, reused across submissions rather than rebuilt.
  final _DrawState _drawState = _DrawState();

  // -------------------------------------------------------------------
  // Creation
  // -------------------------------------------------------------------

  /// Opens a device, or names everything that stopped it.
  ///
  /// Never throws for a missing DLL, an adapter that refuses or a driver that
  /// answers nonsense: all three come back as diagnostics, because a machine
  /// without Direct3D 12 has to be distinguishable from a bug in this file.
  static D3d12DeviceAttempt open({
    bool debugLayer = false,
    int frameCount = D3d12FrameRing.kDefaultFrameCount,
    bool enableExperimentalSparseStrips = false,
    bool enableExperimentalComputeTiles = false,
  }) {
    final List<BackendDiagnostic> diagnostics = <BackendDiagnostic>[];
    final D3d12LibraryLoad load = D3d12Library.open();
    final D3d12Library? library = load.library;
    if (library == null) {
      return D3d12DeviceAttempt(null, load.diagnostics);
    }
    diagnostics.addAll(load.diagnostics);

    try {
      return _open(
        library,
        debugLayer,
        frameCount,
        enableExperimentalSparseStrips,
        enableExperimentalComputeTiles,
        diagnostics,
      );
    } on Object catch (error, stack) {
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'creating the Direct3D 12 device threw, which is a bug here',
        detail: '$error\n$stack',
      ));
      return D3d12DeviceAttempt(null, diagnostics);
    }
  }

  static D3d12DeviceAttempt _open(
    D3d12Library library,
    bool wantDebugLayer,
    int frameCount,
    bool sparseStripsRequested,
    bool computeTilesRequested,
    List<BackendDiagnostic> diagnostics,
  ) {
    var debugEnabled = false;
    if (wantDebugLayer) {
      debugEnabled = _enableDebugLayer(library, diagnostics);
    }

    return D3d12Arena.using(library.allocator, (D3d12Arena arena) {
      final Pointer<Guid> iid = arena<Guid>(sizeOf<Guid>());
      final Pointer<Pointer<Void>> out = arena.allocatePointers(1);

      writeGuid(iid, D3d12Iids.dxgiFactory4);
      final int factoryHr = library.createFactory2(
          debugEnabled ? dxgiCreateFactoryDebug : 0, iid, out);
      if (comFailed(factoryHr)) {
        diagnostics.add(BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'CreateDXGIFactory2 refused',
          detail: hresultText(factoryHr),
        ));
        return D3d12DeviceAttempt(null, diagnostics);
      }
      final DxgiFactory4 factory = DxgiFactory4(out.value);

      final _AdapterChoice? chosen =
          _chooseAdapter(library, factory, arena, diagnostics);
      if (chosen == null) {
        factory.release();
        return D3d12DeviceAttempt(null, diagnostics);
      }
      final D3d12Device device = chosen.device;

      D3d12InfoQueue? infoQueue;
      if (debugEnabled) {
        writeGuid(iid, D3d12Iids.infoQueue);
        final int hr = ComObject(device.pointer).queryInterface(iid, out);
        if (comFailed(hr)) {
          diagnostics.add(BackendDiagnostic.note(
            'the debug layer is on but ID3D12InfoQueue is not available',
            detail: hresultText(hr),
          ));
        } else {
          infoQueue = D3d12InfoQueue(out.value);
        }
      }

      final Pointer<D3d12CommandQueueDesc> queueDesc =
          arena<D3d12CommandQueueDesc>(sizeOf<D3d12CommandQueueDesc>());
      queueDesc.ref
        ..type = d3d12CommandListTypeDirect
        ..priority = 0
        ..flags = 0
        ..nodeMask = 0;
      writeGuid(iid, D3d12Iids.commandQueue);
      final int queueHr =
          device.createCommandQueue(device.pointer, queueDesc, iid, out);
      if (comFailed(queueHr)) {
        infoQueue?.release();
        device.release();
        factory.release();
        diagnostics.add(BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'CreateCommandQueue refused a direct queue',
          detail: hresultText(queueHr),
        ));
        return D3d12DeviceAttempt(null, diagnostics);
      }
      final D3d12CommandQueue queue = D3d12CommandQueue(out.value);

      final D3d12FrameRingAttempt ring = D3d12FrameRing.create(
        library: library,
        device: device,
        queue: queue,
        frameCount: frameCount,
      );
      if (ring.ring == null) {
        queue.release();
        infoQueue?.release();
        device.release();
        factory.release();
        diagnostics.add(BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'the frame ring could not be created',
          detail: ring.diagnostic,
        ));
        return D3d12DeviceAttempt(null, diagnostics);
      }

      final D3d12RenderDevice renderDevice = D3d12RenderDevice._(
        library: library,
        factory: factory,
        device: device,
        queue: queue,
        frames: ring.ring!,
        featureLevel: chosen.featureLevel,
        adapterDescription: chosen.description,
        infoQueue: infoQueue,
        notes: diagnostics,
        sparseStripsRequested: sparseStripsRequested,
        computeTilesRequested: computeTilesRequested,
      );

      final BackendDiagnostic? failure = renderDevice._initialise();
      if (failure != null) {
        renderDevice.dispose();
        diagnostics.add(failure);
        return D3d12DeviceAttempt(null, diagnostics);
      }
      final BackendDiagnostic? sparseFailure =
          renderDevice._initialiseSparseStrips();
      if (sparseFailure != null) {
        renderDevice.dispose();
        diagnostics.add(sparseFailure);
        return D3d12DeviceAttempt(null, diagnostics);
      }
      final BackendDiagnostic? computeFailure =
          renderDevice._initialiseComputeTiles();
      if (computeFailure != null) {
        renderDevice.dispose();
        diagnostics.add(computeFailure);
        return D3d12DeviceAttempt(null, diagnostics);
      }
      return D3d12DeviceAttempt(renderDevice, diagnostics);
    });
  }

  /// Turns the debug layer on, before any device exists.
  ///
  /// The order is the API's own rule and not a preference: a debug layer
  /// enabled after `D3D12CreateDevice` applies to nothing at all, silently.
  static bool _enableDebugLayer(
    D3d12Library library,
    List<BackendDiagnostic> diagnostics,
  ) {
    final D3d12GetDebugInterfaceDart? entry = library.getDebugInterface;
    if (entry == null) {
      diagnostics.add(const BackendDiagnostic.note(
        'the debug layer was requested but d3d12.dll does not export '
        'D3D12GetDebugInterface',
      ));
      return false;
    }
    return D3d12Arena.using(library.allocator, (D3d12Arena arena) {
      final Pointer<Guid> iid = arena<Guid>(sizeOf<Guid>());
      writeGuid(iid, D3d12Iids.debug);
      final Pointer<Pointer<Void>> out = arena.allocatePointers(1);
      final int hr = entry(iid, out);
      if (comFailed(hr)) {
        diagnostics.add(BackendDiagnostic.note(
          'the debug layer was requested but is not installed; it ships in '
          'the optional "Graphics Tools" Windows feature',
          detail: hresultText(hr),
        ));
        return false;
      }
      final D3d12Debug debug = D3d12Debug(out.value)..enableDebugLayer();
      debug.release();
      diagnostics.add(const BackendDiagnostic.note(
        'the Direct3D 12 debug layer is enabled; validation costs several '
        'times the driver call itself and frame times are not comparable to '
        'a run without it',
      ));
      return true;
    });
  }

  /// The first adapter that creates a device, hardware before software.
  static _AdapterChoice? _chooseAdapter(
    D3d12Library library,
    DxgiFactory4 factory,
    D3d12Arena arena,
    List<BackendDiagnostic> diagnostics,
  ) {
    final Pointer<Guid> iid = arena<Guid>(sizeOf<Guid>())
      ..let(D3d12Iids.device);
    final Pointer<Pointer<Void>> out = arena.allocatePointers(1);
    final Pointer<Pointer<Void>> adapterOut = arena.allocatePointers(1);
    final Pointer<DxgiAdapterDesc1> desc =
        arena<DxgiAdapterDesc1>(sizeOf<DxgiAdapterDesc1>());

    // Hardware first, then software. Two passes rather than a sort, because
    // "Microsoft Basic Render Driver" is a real and useful answer on a virtual
    // machine and a wrong one on a laptop with a discrete GPU, and the note it
    // produces has to say which happened.
    for (var pass = 0; pass < 2; pass++) {
      final bool allowSoftware = pass == 1;
      for (var index = 0;; index++) {
        final int hr = factory.enumAdapters1(index, adapterOut);
        if (comFailed(hr)) break;
        final DxgiAdapter1 adapter = DxgiAdapter1(adapterOut.value);
        // The adapter came back as IDXGIAdapter1 already; the identifier is
        // asked for only so a wrong vtable shows up here rather than inside
        // GetDesc1.
        if (comFailed(adapter.getDesc1(desc))) {
          adapter.release();
          continue;
        }
        final bool isSoftware = desc.ref.flags & _dxgiAdapterFlagSoftware != 0;
        final String description = _readUtf16(desc.ref.description, 128);
        if (isSoftware != allowSoftware) {
          adapter.release();
          continue;
        }

        for (final int level in kD3dFeatureLevels) {
          final int deviceHr =
              library.createDevice(adapter.pointer, level, iid, out);
          if (comFailed(deviceHr)) continue;
          adapter.release();
          if (isSoftware) {
            diagnostics.add(BackendDiagnostic.note(
              'no hardware adapter answered Direct3D 12; using the software '
              'adapter "$description"',
              detail: 'frame times from this device say nothing about a real '
                  'GPU, and this note is the only thing that distinguishes '
                  'the two in a bug report',
            ));
          }
          return _AdapterChoice(D3d12Device(out.value), level, description);
        }
        adapter.release();
      }
    }

    diagnostics.add(const BackendDiagnostic(
      kind: DiagnosticKind.incompatibleDevice,
      message: 'no adapter on this machine created a Direct3D 12 device',
      detail: 'd3d12.dll loaded and DXGI enumerated, so this is a driver or '
          'adapter that does not reach feature level 11_0 rather than a '
          'missing runtime; the CPU or OpenGL backend is the answer',
    ));
    return null;
  }

  /// Compiles the shaders, builds the root signature, the pipeline states and
  /// the descriptor heaps.
  ///
  /// Returns a diagnostic on failure instead of throwing, so device creation
  /// reports it the same way a probe does.
  BackendDiagnostic? _initialise() {
    return D3d12Arena.using(_library.allocator, (D3d12Arena arena) {
      final Pointer<Guid> iid = arena<Guid>(sizeOf<Guid>());
      final Pointer<Pointer<Void>> out = arena.allocatePointers(1);

      // --- descriptor heaps -------------------------------------------
      final Pointer<D3d12DescriptorHeapDesc> heapDesc =
          arena<D3d12DescriptorHeapDesc>(sizeOf<D3d12DescriptorHeapDesc>());
      writeGuid(iid, D3d12Iids.descriptorHeap);
      heapDesc.ref
        ..type = d3d12DescriptorHeapTypeRtv
        ..numDescriptors = kRenderTargetCapacity
        ..flags = 0
        ..nodeMask = 0;
      var hr =
          _device.createDescriptorHeap(_device.pointer, heapDesc, iid, out);
      if (comFailed(hr)) return _heapFailure('render target view', hr);
      _rtvHeap = D3d12DescriptorHeap(out.value, _descriptorHandleSlot);
      _rtvStride = _device.getDescriptorHandleIncrementSize(
          _device.pointer, d3d12DescriptorHeapTypeRtv);

      heapDesc.ref
        ..type = d3d12DescriptorHeapTypeCbvSrvUav
        ..numDescriptors = kTextureCapacity
        ..flags = d3d12DescriptorHeapFlagShaderVisible
        ..nodeMask = 0;
      hr = _device.createDescriptorHeap(_device.pointer, heapDesc, iid, out);
      if (comFailed(hr)) return _heapFailure('shader resource view', hr);
      _srvHeap = D3d12DescriptorHeap(out.value, _descriptorHandleSlot);
      _srvStride = _device.getDescriptorHandleIncrementSize(
          _device.pointer, d3d12DescriptorHeapTypeCbvSrvUav);

      // --- root signature ---------------------------------------------
      final BackendDiagnostic? rootFailure = _createRootSignature(arena);
      if (rootFailure != null) return rootFailure;

      // --- shaders ------------------------------------------------------
      final Object vertex = _compile(arena, kD3d12VertexShader,
          kD3d12VertexEntryPoint, kD3d12VertexTarget);
      if (vertex is BackendDiagnostic) return vertex;
      final Object pixel = _compile(
          arena, kD3d12PixelShader, kD3d12PixelEntryPoint, kD3d12PixelTarget);
      if (pixel is BackendDiagnostic) {
        (vertex as D3dBlob).release();
        return pixel;
      }
      _vertexBlob = vertex as D3dBlob;
      _pixelBlob = pixel as D3dBlob;

      // --- pipeline states, one per blend mode --------------------------
      //
      // Direct3D 12 has no dynamic blend state: the factors are baked into the
      // pipeline state object. That is the one structural difference from the
      // GL backend, where a batch's blend mode is a `glBlendFunc` call. Three
      // objects, built up front, because the display list encodes exactly
      // three modes and building one mid-frame would stall on a driver
      // compile at the worst possible moment.
      _pipelines = <int, Pointer<Void>>{};
      for (final int mode in <int>[
        blendModeSrcOver,
        blendModeSrc,
        blendModePlus,
      ]) {
        final Object pso = _createPipelineState(arena, mode);
        if (pso is BackendDiagnostic) return pso;
        _pipelines[mode] = pso as Pointer<Void>;
      }

      // --- the placeholder texture --------------------------------------
      //
      // Descriptor index 0, bound whenever a batch samples nothing. Without it
      // a solid batch would leave the root descriptor table pointing at an
      // uninitialised descriptor, which the debug layer reports and which a
      // driver is entitled to treat as anything at all.
      final D3d12Texture? placeholder = _allocateTexture(
        width: 1,
        height: 1,
        format: GpuTextureFormat.rgba8888Premultiplied,
        filter: GpuTextureFilter.nearest,
        forcedIndex: 0,
      );
      if (placeholder == null) {
        return const BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'the 1x1 placeholder texture could not be created',
        );
      }
      _placeholder = placeholder;
      uploadRegion(
        _placeholder,
        x: 0,
        y: 0,
        width: 1,
        height: 1,
        pixels: Uint8List.fromList(<int>[0, 0, 0, 0]),
        bytesPerRow: 4,
      );
      return null;
    });
  }

  /// Builds the opt-in sparse-strip root signature and pipeline states, or
  /// names why it could not.
  ///
  /// Runs at device creation and never inside a frame, for the reason the field
  /// comment gives. Returns a diagnostic rather than throwing, so a machine
  /// whose compiler refuses the sparse HLSL reports it exactly the way a
  /// missing adapter is reported.
  BackendDiagnostic? _initialiseSparseStrips() {
    // Compute composition draws its coverage quad through the sparse pipeline -
    // an alpha instance whose page happens to be target-sized - so asking for
    // compute builds the sparse objects too. Requiring the caller to ask for
    // both would be exporting an implementation detail as an API rule.
    if (!_sparseStripsRequested && !_computeTilesRequested) return null;
    final D3d12SparseDriver driver = _sparseDriver ??= D3d12SparseDriver(this);
    final SparseD3d12Executor executor =
        _sparseExecutor ??= SparseD3d12Executor(driver, textureAllocator: this);
    try {
      executor.initialize();
    } on Object catch (error) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the opt-in sparse Direct3D 12 pipeline could not be '
            'initialized',
        detail: '$error',
      );
    }
    return null;
  }

  /// Builds the opt-in compute-tile root signature and pipeline state, or names
  /// why it could not.
  ///
  /// Runs at device creation, like [_initialiseSparseStrips]. A machine whose
  /// compiler refuses `cs_5_0` - or a driver that refuses a compute pipeline -
  /// reports it here rather than at the first dispatch.
  BackendDiagnostic? _initialiseComputeTiles() {
    if (!_computeTilesRequested) return null;
    final D3d12ComputeTileDriver driver =
        _computeTileDriver ??= D3d12ComputeTileDriver(this);
    final ComputeTileD3d12Executor executor =
        _computeTileExecutor ??= ComputeTileD3d12Executor(driver);
    try {
      executor.initialize();
    } on Object catch (error) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the opt-in compute-tile Direct3D 12 pipeline could not be '
            'initialized',
        detail: '$error',
      );
    }
    return null;
  }

  BackendDiagnostic _heapFailure(String which, int hr) => BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the $which descriptor heap could not be created',
        detail: hresultText(hr),
      );

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
    // Slot 0: the five root constants. See kD3d12RootConstantCount for why the
    // count is five and how they pack.
    parameters[kD3d12RootConstantsSlot]
      ..parameterType = d3d12RootParameterTypeConstants
      ..field8 = 0 // ShaderRegister: b0
      ..fieldC = 0 // RegisterSpace
      ..field10 = kD3d12RootConstantCount // Num32BitValues
      ..shaderVisibility = d3d12ShaderVisibilityAll;
    // Slot 1: one SRV, pixel stage only.
    parameters[kD3d12RootTextureSlot]
      ..parameterType = d3d12RootParameterTypeDescriptorTable
      ..field8 = 1 // NumDescriptorRanges
      ..field10 = range.address // pDescriptorRanges
      ..shaderVisibility = d3d12ShaderVisibilityPixel;

    final Pointer<D3d12StaticSamplerDesc> samplers =
        arena<D3d12StaticSamplerDesc>(sizeOf<D3d12StaticSamplerDesc>() * 2);
    for (var i = 0; i < 2; i++) {
      samplers[i]
        ..filter =
            i == 0 ? d3d12FilterMinMagMipPoint : d3d12FilterMinMagMipLinear
        ..addressU = d3d12TextureAddressModeClamp
        ..addressV = d3d12TextureAddressModeClamp
        ..addressW = d3d12TextureAddressModeClamp
        ..mipLodBias = 0
        ..maxAnisotropy = 1
        ..comparisonFunc = d3d12ComparisonFuncAlways
        ..borderColor = d3d12StaticBorderColorTransparentBlack
        ..minLod = 0
        ..maxLod = 0
        ..shaderRegister = i
        ..registerSpace = 0
        ..shaderVisibility = d3d12ShaderVisibilityPixel;
    }

    final Pointer<D3d12RootSignatureDesc> desc =
        arena<D3d12RootSignatureDesc>(sizeOf<D3d12RootSignatureDesc>());
    desc.ref
      ..numParameters = 2
      ..parameters = parameters
      ..numStaticSamplers = 2
      ..staticSamplers = samplers
      ..flags = d3d12RootSignatureFlagAllowInputAssemblerInputLayout;

    final Pointer<Pointer<Void>> blobOut = arena.allocatePointers(1);
    final Pointer<Pointer<Void>> errorOut = arena.allocatePointers(1);
    final int hr = _library.serializeRootSignature(
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
        message: 'the root signature could not be serialised',
        detail: detail,
      );
    }
    final D3dBlob blob = D3dBlob(blobOut.value);
    final Pointer<Guid> iid = arena<Guid>(sizeOf<Guid>())
      ..let(D3d12Iids.rootSignature);
    final Pointer<Pointer<Void>> out = arena.allocatePointers(1);
    final int createHr = _device.createRootSignature(
        _device.pointer, 0, blob.data, blob.length, iid, out);
    blob.release();
    if (comFailed(createHr)) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'CreateRootSignature refused',
        detail: hresultText(createHr),
      );
    }
    _rootSignature = out.value;
    return null;
  }

  /// Compiles one HLSL stage with the device's own `D3DCompile` binding.
  ///
  /// Public because the experimental sparse-strip and compute-tile executors
  /// live in other files and must not open a second path to the compiler: the
  /// flags, the source name and the verbatim error text are decisions this
  /// device already made, and two copies of them is two answers to "why did
  /// the shader fail".
  ///
  /// Returns a [D3dBlob] on success, a [BackendDiagnostic] on failure.
  Object compileShader(
    D3d12Arena arena,
    String source,
    String entryPoint,
    String target,
  ) =>
      _compile(arena, source, entryPoint, target);

  /// Returns a [D3dBlob] on success, a [BackendDiagnostic] on failure.
  Object _compile(
    D3d12Arena arena,
    String source,
    String entryPoint,
    String target,
  ) {
    final Pointer<Uint8> text = arena.allocateAscii(source);
    final Pointer<Uint8> name = arena.allocateAscii('dart_ui.hlsl');
    final Pointer<Uint8> entry = arena.allocateAscii(entryPoint);
    final Pointer<Uint8> profile = arena.allocateAscii(target);
    final Pointer<Pointer<Void>> code = arena.allocatePointers(1);
    final Pointer<Pointer<Void>> errors = arena.allocatePointers(1);
    final int hr = _library.compile(
      text,
      source.length,
      name,
      nullptr,
      nullptr,
      entry,
      profile,
      // Enable strictness and warnings-as-errors would be tempting; neither is
      // set, because a driver-specific warning must not stop a renderer from
      // starting on a machine whose compiler is a different build.
      0,
      0,
      code,
      errors,
    );
    if (comFailed(hr)) {
      final String detail = errors.value == nullptr
          ? hresultText(hr)
          : '${hresultText(hr)}: ${D3dBlob(errors.value).text}';
      if (errors.value != nullptr) ComObject(errors.value).release();
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: '$target failed to compile',
        // The compiler's own message, verbatim. Anything less turns a one-line
        // HLSL error into an afternoon.
        detail: detail,
      );
    }
    if (errors.value != nullptr) ComObject(errors.value).release();
    return D3dBlob(code.value);
  }

  /// Returns a `Pointer<Void>` on success, a [BackendDiagnostic] on failure.
  Object _createPipelineState(D3d12Arena arena, int blendMode) {
    final GpuBlendState blend = gpuBlendForMode(blendMode);
    final int source = _blendFactor(blend.source);
    final int destination = _blendFactor(blend.destination);

    final Pointer<D3d12InputElementDesc> elements =
        arena<D3d12InputElementDesc>(sizeOf<D3d12InputElementDesc>() * 4);
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
    for (var i = 0; i < 4; i++) {
      elements[i]
        ..semanticName = arena.allocateAscii(kD3d12SemanticNames[i])
        ..semanticIndex = kD3d12SemanticIndices[i]
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
      ..dsvFormat = dxgiFormatUnknown
      ..nodeMask = 0
      ..flags = d3d12PipelineStateFlagNone;
    desc.ref.vs
      ..shaderBytecode = _vertexBlob.data
      ..bytecodeLength = _vertexBlob.length;
    desc.ref.ps
      ..shaderBytecode = _pixelBlob.data
      ..bytecodeLength = _pixelBlob.length;
    desc.ref.rtvFormats[0] = kD3d12SurfaceFormat;
    desc.ref.sampleDesc
      ..count = 1
      ..quality = 0;
    desc.ref.inputLayout
      ..inputElementDescs = elements
      ..numElements = 4;
    desc.ref.blendState
      ..alphaToCoverageEnable = 0
      ..independentBlendEnable = 0;
    desc.ref.blendState.renderTarget[0]
      ..blendEnable = 1
      ..logicOpEnable = 0
      ..srcBlend = source
      ..destBlend = destination
      // The alpha factors are the colour factors, exactly as `glBlendFunc`
      // applies one pair to both. A separate alpha equation here would make
      // this backend composite differently from the GL one on the first
      // translucent surface, and the parity test would find it as a
      // whole-channel difference rather than as rounding.
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

    final Pointer<Guid> iid = arena<Guid>(sizeOf<Guid>())
      ..let(D3d12Iids.pipelineState);
    final Pointer<Pointer<Void>> out = arena.allocatePointers(1);
    final int hr =
        _device.createGraphicsPipelineState(_device.pointer, desc, iid, out);
    if (comFailed(hr)) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the pipeline state for blend mode $blendMode was refused',
        detail: hresultText(hr),
      );
    }
    return out.value;
  }

  static int _blendFactor(GpuBlendFactor factor) => switch (factor) {
        GpuBlendFactor.zero => d3d12BlendZero,
        GpuBlendFactor.one => d3d12BlendOne,
        GpuBlendFactor.oneMinusSrcAlpha => d3d12BlendInvSrcAlpha,
      };

  // -------------------------------------------------------------------
  // Identity
  // -------------------------------------------------------------------

  /// Everything device creation had to say, successes included. Handed to the
  /// probe report so a machine that fell back to the software adapter says so.
  List<BackendDiagnostic> get diagnostics =>
      List<BackendDiagnostic>.unmodifiable(_notes);

  /// The feature level the device was actually created at, as the SDK spells
  /// it - `12_1`, `11_0`.
  String get featureLevelText => featureLevelName(_featureLevel);

  int get featureLevel => _featureLevel;

  @override
  RendererInfo get info => RendererInfo(
        name: backendName,
        deviceDescription: _adapterDescription,
        driverVersion: 'feature level $featureLevelText',
        rasterizationApproach: RasterizationApproach.analyticCoverageAtlas,
      );

  /// What this device can do, answered field by field.
  ///
  /// Every one is a real answer and not a placeholder. Partial present is
  /// false because `DXGI_SWAP_EFFECT_FLIP_DISCARD` discards the back buffer's
  /// contents on every present, so there is nothing to preserve and a damage
  /// rectangle can only save rasterisation. MSAA is false because nothing here
  /// creates a multisample resource, and the antialiasing is analytic instead
  /// - `boxCoverage` in the pixel shader and the coverage-mask atlas.
  ///
  /// Compute follows [experimentalComputeTilesEnabled] and is therefore false
  /// unless the caller asked for the opt-in tile executor. It is not a constant
  /// any more, and the reason is honesty in both directions: a device that has
  /// built a compute root signature and a compute pipeline state *does* support
  /// compute, and one that has not must not claim to - a selector that read a
  /// hard-coded `true` would choose approach D on a device with nothing to
  /// execute it.
  @override
  RendererCapabilities get capabilities => RendererCapabilities(
        supportsPartialPresent: false,
        supportsMsaa: false,
        supportsCompute: experimentalComputeTilesEnabled,
        supportsExternalTextures: false,
        supportsLinearColor: false,
        maxTextureSize: kMaxTextureSize,
        formats: <PixelFormat>{
          PixelFormat.rgba8888Premultiplied,
          PixelFormat.bgra8888Premultiplied,
        },
      );

  @override
  bool get isLost => _state.isLost;

  GpuDeviceState get state => _state;

  D3d12Library get library => _library;
  D3d12Device get nativeDevice => _device;
  D3d12CommandQueue get queue => _queue;
  DxgiFactory4 get factory => _factory;

  /// The frame ring. Device-to-target plumbing: a target opens and closes the
  /// frame, and the ring is what makes reusing an allocator legal. Exposed for
  /// the same reason `GlRenderDevice.submit` is public - the targets live in
  /// other files - and, for the fence tests, because the proof of the wait is
  /// this object's own record.
  D3d12FrameRing get frames => _frames;

  /// The debug layer's message store, or null when it is not enabled.
  D3d12InfoQueue? get infoQueue => _infoQueue;

  /// Marks the device lost and names why. Called by the targets.
  ///
  /// When the caller has no detail of its own, `GetDeviceRemovedReason` is
  /// asked - it is the only way to tell a genuinely removed device (a driver
  /// update, a TDR, a GPU switch) from a bug in this backend, and both arrive
  /// here as the same failed call.
  void markLost(String message, {String? detail}) {
    _state.markLost(
      BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: message,
        detail: detail ??
            'GetDeviceRemovedReason: '
                '${hresultText(_device.getDeviceRemovedReason(_device.pointer))}',
      ),
    );
    // Every object a removed device created is invalid, and releasing one
    // through the removed device is undefined - the pointer may already have
    // been recycled. The experimental executor therefore *forgets* its root
    // signature, pipeline states and alpha pages rather than releasing them,
    // and a recovered device rebuilds them through _initialiseSparseStrips.
    final SparseD3d12Executor? executor = _sparseExecutor;
    if (executor != null && !executor.isDisposed) {
      executor.discardNativeResources();
    }
    final ComputeTileD3d12Executor? compute = _computeTileExecutor;
    if (compute != null && !compute.isDisposed) {
      compute.discardNativeResources();
    }
    // The coverage texture belonged to the removed device too. Forgetting the
    // handle without releasing it is the same rule the executors follow.
    _computeCoverage = null;
  }

  @override
  RenderTarget createTarget(NativeSurfaceDescriptor surface) {
    throwIfDisposed();
    if (surface is MemorySurfaceDescriptor) {
      return D3d12OffscreenTarget(this, surface);
    }
    if (surface is D3d12WindowSurfaceDescriptor) {
      return D3d12WindowTarget(this, surface);
    }
    throw UnsupportedCapabilityError(
      backendName: backendName,
      capability: Capability.gpuPresentation,
      detail: 'this device builds an offscreen target from a '
          'MemorySurfaceDescriptor and a windowed target from a '
          'D3d12WindowSurfaceDescriptor; it was handed a ${surface.kind} '
          '(${surface.runtimeType}), which it has no way to present to',
    );
  }

  // -------------------------------------------------------------------
  // Descriptor heaps
  // -------------------------------------------------------------------

  /// Reserves a render-target-view descriptor and returns its CPU handle.
  ///
  /// Handles are integers because that is what the x64 ABI returns them as -
  /// see the library comment of `d3d12_interfaces.dart` - which is also what
  /// makes offsetting one by the heap's increment size a plain add.
  int allocateRenderTargetView() {
    final int index = _freeRtv.isNotEmpty ? _freeRtv.removeLast() : _nextRtv++;
    if (index >= kRenderTargetCapacity) {
      _nextRtv = kRenderTargetCapacity;
      throw UnsupportedCapabilityError(
        backendName: backendName,
        capability: Capability.gpuPresentation,
        detail: 'this device holds at most $kRenderTargetCapacity render '
            'target views and they are all in use; a target that was not '
            'disposed is the usual cause',
      );
    }
    return _rtvHeap.cpuHandleStart + index * _rtvStride;
  }

  void releaseRenderTargetView(int handle) {
    final int index = (handle - _rtvHeap.cpuHandleStart) ~/ _rtvStride;
    if (index >= 0 && index < kRenderTargetCapacity) _freeRtv.add(index);
  }

  /// Points [handle] at [resource] as a render target.
  void createRenderTargetView(Pointer<Void> resource, int handle) => _device
      .createRenderTargetView(_device.pointer, resource, nullptr, handle);

  /// The shader-visible descriptor heap, for a `SetDescriptorHeaps` issued by
  /// an executor that records into this device's command list.
  ///
  /// Exposed rather than duplicated: a second shader-visible heap would mean
  /// re-creating every view in it, and `SetDescriptorHeaps` may name only one
  /// CBV/SRV/UAV heap at a time - so an executor that brought its own would
  /// unbind the atlases the dense path is about to sample.
  Pointer<Void> get shaderVisibleHeap => _srvHeap.pointer;

  /// The GPU descriptor handle of [textureId], which is that texture's index in
  /// [shaderVisibleHeap]. Index 0 is the 1x1 placeholder.
  int gpuDescriptorHandleFor(int textureId) =>
      _srvHeap.gpuHandleStart + textureId * _srvStride;

  /// Moves every live texture into `PIXEL_SHADER_RESOURCE`.
  ///
  /// Public for the experimental executors, which sample textures this device
  /// created - alpha pages, gradient ramps - from a pass this device's own
  /// [submit] does not record. Idempotent: a texture already in that state
  /// contributes no barrier.
  void prepareTexturesForSampling() => _prepareTexturesForSampling();

  // -------------------------------------------------------------------
  // Textures
  // -------------------------------------------------------------------

  @override
  D3d12Texture createTexture({
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
    if (width > kMaxTextureSize || height > kMaxTextureSize) {
      throw UnsupportedCapabilityError(
        backendName: backendName,
        capability: Capability.gpuPresentation,
        detail: 'a ${width}x$height texture exceeds the $kMaxTextureSize '
            'limit every Direct3D 12 feature level guarantees; the caller '
            'must tile the image or scale it down',
      );
    }
    final D3d12Texture? texture = _allocateTexture(
      width: width,
      height: height,
      format: format,
      filter: filter,
    );
    if (texture == null) {
      throw UnsupportedCapabilityError(
        backendName: backendName,
        capability: Capability.gpuPresentation,
        detail: _lastTextureHresult == 0
            ? 'the ${width}x$height texture could not be created; all '
                '$kTextureCapacity shader-resource descriptors are in use'
            : 'the ${width}x$height texture was refused by '
                'CreateCommittedResource with '
                '${hresultText(_lastTextureHresult)}',
      );
    }
    return texture;
  }

  /// Creates the resource and its view, or returns null.
  ///
  /// [forcedIndex] is only for the placeholder, which must land on descriptor
  /// zero so that a real texture's id is never [kNoTexture].
  D3d12Texture? _allocateTexture({
    required int width,
    required int height,
    required GpuTextureFormat format,
    required GpuTextureFilter filter,
    int? forcedIndex,
    bool renderTarget = false,
    bool unorderedAccess = false,
    int? dxgiFormatOverride,
  }) {
    final int index;
    if (forcedIndex != null) {
      index = forcedIndex;
    } else if (_freeSrv.isNotEmpty) {
      index = _freeSrv.removeLast();
    } else if (_nextSrv < kTextureCapacity) {
      index = _nextSrv++;
    } else {
      return null;
    }

    // A switch and not a ternary, so a format added later is a compile error
    // here rather than a resource quietly created in the wrong layout. The
    // SRV format is per-descriptor and is not baked into a pipeline state
    // object, so BGRA needs no second PSO and no second shader - the texture
    // unit returns RGBA either way. See
    // [GpuTextureFormat.bgra8888Premultiplied].
    final int dxgiFormat = dxgiFormatOverride ?? _dxgiFormatFor(format);

    return D3d12Arena.using(_library.allocator, (D3d12Arena arena) {
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
        ..format = dxgiFormat
        ..layout = d3d12TextureLayoutUnknown
        ..flags = renderTarget
            ? d3d12ResourceFlagAllowRenderTarget
            : unorderedAccess
                ? d3d12ResourceFlagAllowUnorderedAccess
                : d3d12ResourceFlagNone;
      desc.ref.sampleDesc
        ..count = 1
        ..quality = 0;

      final Pointer<Guid> iid = arena<Guid>(sizeOf<Guid>())
        ..let(D3d12Iids.resource);
      final Pointer<Pointer<Void>> out = arena.allocatePointers(1);
      final int initialState = renderTarget
          ? d3d12ResourceStateRenderTarget
          : unorderedAccess
              ? d3d12ResourceStateUnorderedAccess
              : d3d12ResourceStateCopyDest;
      final int hr = _device.createCommittedResource(
        _device.pointer,
        heap,
        0,
        desc,
        initialState,
        nullptr,
        iid,
        out,
      );
      if (comFailed(hr)) {
        _lastTextureHresult = hr;
        if (forcedIndex == null) _freeSrv.add(index);
        return null;
      }
      _lastTextureHresult = 0;

      final Pointer<D3d12ShaderResourceViewDesc> view =
          arena<D3d12ShaderResourceViewDesc>(
              sizeOf<D3d12ShaderResourceViewDesc>());
      view.ref
        ..format = dxgiFormat
        ..viewDimension = d3d12SrvDimensionTexture2d
        ..shader4ComponentMapping = d3d12DefaultShader4ComponentMapping
        ..mostDetailedMip = 0
        ..mipLevels = 1
        ..planeSlice = 0
        ..resourceMinLodClamp = 0;
      _device.createShaderResourceView(
        _device.pointer,
        out.value,
        view,
        _srvHeap.cpuHandleStart + index * _srvStride,
      );

      final D3d12Texture texture = D3d12Texture._(
        index,
        width,
        height,
        format,
        filter,
        out.value,
        _state,
      )
        .._resourceState = initialState
        .._isRenderTarget = renderTarget
        .._isUnorderedAccess = unorderedAccess;
      _textures.add(texture);
      _samplers[index] = filter == GpuTextureFilter.linear
          ? kD3d12SamplerLinear
          : kD3d12SamplerPoint;
      return texture;
    });
  }

  /// A texture that can also be drawn into. Used by the offscreen target for
  /// its colour surface; the same call is what a layer pool would need.
  D3d12Texture? createRenderTargetTexture(int width, int height) =>
      _allocateTexture(
        width: width,
        height: height,
        format: GpuTextureFormat.rgba8888Premultiplied,
        filter: GpuTextureFilter.nearest,
        renderTarget: true,
      );

  /// A target-sized single-channel float texture a compute shader writes and a
  /// pixel shader then samples: the coverage approach D produces.
  ///
  /// `R32_FLOAT` rather than `R8_UNORM`, and the reason is in
  /// `d3d12_structs.dart`: it is one of the three formats every Direct3D 12
  /// device must support for a typed UAV store, and this backend does not query
  /// the capability that would let it use the smaller one.
  ///
  /// Two descriptors are created for it in the one shader-visible heap - an SRV
  /// at [D3d12Texture.id] so the composite pixel shader can `Load` it, and a
  /// UAV at the returned index so the dispatch can write it. Two views of one
  /// resource, never bound at the same time; [transitionTexture] is what makes
  /// that safe.
  ///
  /// Returns null when the resource or a descriptor could not be obtained.
  D3d12ComputeCoverageTexture? createComputeCoverageTexture(
    int width,
    int height,
  ) {
    final D3d12Texture? texture = _allocateTexture(
      width: width,
      height: height,
      // The nominal format is never consulted: nothing uploads to this texture
      // and nothing reads its bytesPerPixel. The DXGI format below is what the
      // views actually carry.
      format: GpuTextureFormat.alpha8,
      filter: GpuTextureFilter.nearest,
      unorderedAccess: true,
      dxgiFormatOverride: dxgiFormatR32Float,
    );
    if (texture == null) return null;

    final int? uavIndex = _freeSrv.isNotEmpty
        ? _freeSrv.removeLast()
        : (_nextSrv < kTextureCapacity ? _nextSrv++ : null);
    if (uavIndex == null) {
      releaseTexture(texture);
      return null;
    }
    D3d12Arena.using(_library.allocator, (D3d12Arena arena) {
      final Pointer<D3d12UnorderedAccessViewDesc> view =
          arena<D3d12UnorderedAccessViewDesc>(
              sizeOf<D3d12UnorderedAccessViewDesc>());
      view.ref
        ..format = dxgiFormatR32Float
        ..viewDimension = d3d12UavDimensionTexture2d
        ..mipSlice = 0
        ..planeSlice = 0;
      _device.createUnorderedAccessView(
        _device.pointer,
        texture._resource,
        nullptr,
        view,
        _srvHeap.cpuHandleStart + uavIndex * _srvStride,
      );
    });
    return D3d12ComputeCoverageTexture._(texture, uavIndex);
  }

  /// Releases a coverage texture and both of its descriptors.
  void releaseComputeCoverageTexture(D3d12ComputeCoverageTexture coverage) {
    // The UAV slot first, and pointed at the placeholder rather than left
    // dangling, for the reason releaseTexture gives about the SRV one.
    if (!_state.isLost) _pointAtPlaceholder(coverage.unorderedAccessIndex);
    _freeSrv.add(coverage.unorderedAccessIndex);
    releaseTexture(coverage.texture);
  }

  /// Moves [texture] into [state] on the open command list.
  ///
  /// Public for the compute-tile driver, which owns the only textures this
  /// device does not transition in bulk - see [D3d12Texture._isUnorderedAccess].
  void transitionTexture(D3d12Texture texture, int state) =>
      _transition(texture, state);

  /// The underlying resource of [texture]. Device-to-target plumbing.
  Pointer<Void> resourceOf(D3d12Texture texture) => texture._resource;

  @override
  void uploadRegion(
    covariant D3d12Texture texture, {
    required int x,
    required int y,
    required int width,
    required int height,
    required Uint8List pixels,
    required int bytesPerRow,
  }) {
    if (width <= 0 || height <= 0 || _state.isLost) return;
    final int bytesPerPixel = texture.format.bytesPerPixel;
    final int rowBytes = width * bytesPerPixel;
    // The API's own constant, not a device property: a copy source's rows must
    // be 256-byte aligned, and the whole footprint 512-byte aligned inside its
    // buffer. Both are why this cannot simply memcpy the caller's rows.
    final int rowPitch = alignUp(rowBytes, d3d12TextureDataPitchAlignment);

    // A frame that is already recording gets the copy for free. Anything else
    // - a texture uploaded outside a frame, which is what the placeholder and
    // an image cache warmed up front do - opens a list of its own and waits,
    // because there is no later point at which somebody would flush it.
    final bool opened = !_frames.isRecording;
    if (opened && _frames.begin() == null) {
      markLost('a command list could not be opened to upload a texture');
      return;
    }

    final D3d12UploadRange? range = _frames.reserveUpload(
      rowPitch * height,
      alignment: d3d12TextureDataPlacementAlignment,
    );
    if (range == null) {
      if (opened) _frames.abandon();
      markLost('an upload buffer could not be created for a '
          '${width}x$height texture region');
      return;
    }

    final Uint8List destination = range.cpu.asTypedList(rowPitch * height);
    for (var row = 0; row < height; row++) {
      destination.setRange(
        row * rowPitch,
        row * rowPitch + rowBytes,
        pixels,
        row * bytesPerRow,
      );
    }

    _transition(texture, d3d12ResourceStateCopyDest);

    _copyDestination.ref
      ..resource = texture._resource
      ..type = d3d12TextureCopyTypeSubresourceIndex;
    // The subresource index occupies the first four bytes of the union, which
    // is where the little-endian `offset` field starts. See the declaration of
    // D3d12TextureCopyLocation.
    _copyDestination.ref.placedFootprint.offset = 0;

    _copySource.ref
      ..resource = range.resource
      ..type = d3d12TextureCopyTypePlacedFootprint;
    _copySource.ref.placedFootprint.offset = range.offset;
    _copySource.ref.placedFootprint.footprint
      // The footprint's format has to be the resource's, or the copy writes
      // the right bytes with the wrong pitch arithmetic.
      ..format = _dxgiFormatFor(texture.format)
      ..width = width
      ..height = height
      ..depth = 1
      ..rowPitch = rowPitch;

    _frames.list.copyTextureRegion(
      _frames.list.pointer,
      _copyDestination,
      x,
      y,
      0,
      _copySource,
      nullptr,
    );

    if (opened && !_frames.end(waitForCompletion: true)) {
      markLost('the upload command list could not be executed');
    }
  }

  @override
  void releaseTexture(covariant D3d12Texture texture) {
    if (texture._released || isDisposed) return;
    texture._released = true;
    _textures.remove(texture);
    if (texture.id != 0) _freeSrv.add(texture.id);
    // Point the freed descriptor at the placeholder rather than leaving it
    // dangling: a shader-visible heap slot that names a released resource is
    // exactly the "uninitialised descriptor" the debug layer reports, and a
    // later batch could still have the index cached in a pooled GpuBatch.
    if (texture.id != 0 && !_state.isLost) _pointAtPlaceholder(texture.id);
    ComObject(texture._resource).release();
  }

  void _pointAtPlaceholder(int index) =>
      D3d12Arena.using(_library.allocator, (D3d12Arena arena) {
        final Pointer<D3d12ShaderResourceViewDesc> view =
            arena<D3d12ShaderResourceViewDesc>(
                sizeOf<D3d12ShaderResourceViewDesc>());
        view.ref
          ..format = kD3d12SurfaceFormat
          ..viewDimension = d3d12SrvDimensionTexture2d
          ..shader4ComponentMapping = d3d12DefaultShader4ComponentMapping
          ..mostDetailedMip = 0
          ..mipLevels = 1
          ..planeSlice = 0
          ..resourceMinLodClamp = 0;
        _device.createShaderResourceView(
          _device.pointer,
          _placeholder._resource,
          view,
          _srvHeap.cpuHandleStart + index * _srvStride,
        );
      });

  // -------------------------------------------------------------------
  // Barriers
  // -------------------------------------------------------------------

  /// Records a transition of [texture] into [state], if it is not there.
  ///
  /// The other half of the rule the debug layer enforces: every resource has a
  /// state, every read requires the matching one, and a barrier whose
  /// `StateBefore` disagrees with the truth is an error the runtime reports
  /// and a driver is entitled to act on.
  void _transition(D3d12Texture texture, int state) {
    if (texture._resourceState == state) return;
    transitionResource(texture._resource, texture._resourceState, state);
    texture._resourceState = state;
  }

  /// Records one transition barrier on the open command list.
  ///
  /// Public because the targets own resources this device does not - a swap
  /// chain's back buffers, an offscreen readback buffer - and the barrier that
  /// moves them between `PRESENT` and `RENDER_TARGET` has to be recorded on
  /// the same list as the draws.
  void transitionResource(Pointer<Void> resource, int before, int after) {
    if (before == after) return;
    final Pointer<D3d12ResourceBarrier> barriers = _ensureBarriers(1);
    barriers.ref
      ..type = d3d12ResourceBarrierTypeTransition
      ..flags = 0
      ..resource = resource
      ..subresource = d3d12ResourceBarrierAllSubresources
      ..stateBefore = before
      ..stateAfter = after;
    _frames.list.resourceBarrier(_frames.list.pointer, 1, barriers);
  }

  Pointer<D3d12ResourceBarrier> _ensureBarriers(int count) {
    if (count <= _barrierCapacity) return _barriers;
    _library.allocator.free(_barriers);
    _barrierCapacity = count * 2;
    return _barriers = _library.allocator.allocate<D3d12ResourceBarrier>(
        sizeOf<D3d12ResourceBarrier>() * _barrierCapacity);
  }

  /// Moves every live texture into `PIXEL_SHADER_RESOURCE`.
  ///
  /// Called once per submission, before the draws. Batching it here rather
  /// than transitioning per batch is deliberate: a texture is sampled by many
  /// batches and a barrier per batch would serialise the GPU between them,
  /// which is exactly the "barriers everywhere" pattern that makes a naive
  /// Direct3D 12 port slower than the Direct3D 11 it replaced.
  void _prepareTexturesForSampling() {
    var pending = 0;
    for (final D3d12Texture texture in _textures) {
      if (!texture._isRenderTarget &&
          !texture._isUnorderedAccess &&
          texture._resourceState != d3d12ResourceStatePixelShaderResource) {
        pending++;
      }
    }
    if (pending == 0) return;
    final Pointer<D3d12ResourceBarrier> barriers = _ensureBarriers(pending);
    var index = 0;
    for (final D3d12Texture texture in _textures) {
      if (texture._isRenderTarget ||
          texture._isUnorderedAccess ||
          texture._resourceState == d3d12ResourceStatePixelShaderResource) {
        continue;
      }
      barriers[index]
        ..type = d3d12ResourceBarrierTypeTransition
        ..flags = 0
        ..resource = texture._resource
        ..subresource = d3d12ResourceBarrierAllSubresources
        ..stateBefore = texture._resourceState
        ..stateAfter = d3d12ResourceStatePixelShaderResource;
      texture._resourceState = d3d12ResourceStatePixelShaderResource;
      index++;
    }
    _frames.list.resourceBarrier(_frames.list.pointer, pending, barriers);
  }

  // -------------------------------------------------------------------
  // Readback
  // -------------------------------------------------------------------

  /// A buffer on the readback heap, or `nullptr`.
  ///
  /// The readback heap rather than the upload heap, and the difference is not
  /// cosmetic: upload memory is write-combined, which makes CPU *reads* of it
  /// an order of magnitude slower than reads of ordinary memory, and reading
  /// back a surface is exactly a CPU read of every byte.
  Pointer<Void> createReadbackBuffer(int bytes) =>
      D3d12Arena.using(_library.allocator, (D3d12Arena arena) {
        final Pointer<D3d12HeapProperties> heap =
            arena<D3d12HeapProperties>(sizeOf<D3d12HeapProperties>());
        heap.ref
          ..type = d3d12HeapTypeReadback
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
        final Pointer<Guid> iid = arena<Guid>(sizeOf<Guid>())
          ..let(D3d12Iids.resource);
        final Pointer<Pointer<Void>> out = arena.allocatePointers(1);
        final int hr = _device.createCommittedResource(
          _device.pointer,
          heap,
          0,
          desc,
          d3d12ResourceStateCopyDest,
          nullptr,
          iid,
          out,
        );
        return comFailed(hr) ? nullptr : out.value;
      });

  /// Records a copy of [texture] into [buffer] and puts it back where it was.
  ///
  /// [rowPitch] must already be rounded up to
  /// [d3d12TextureDataPitchAlignment]; the caller sizes the buffer from it, so
  /// computing it in two places would be two chances to disagree.
  ///
  /// No row flip and none needed: Direct3D writes render-target row 0 at the
  /// top and `CopyTextureRegion` preserves the order, so the buffer comes out
  /// top-down like every [Framebuffer].
  void copyRenderTargetToBuffer(
    D3d12Texture texture,
    Pointer<Void> buffer,
    int rowPitch,
  ) {
    if (!_frames.isRecording || buffer == nullptr) return;
    final int restore = texture._resourceState;
    _transition(texture, d3d12ResourceStateCopySource);

    _copyDestination.ref
      ..resource = buffer
      ..type = d3d12TextureCopyTypePlacedFootprint;
    _copyDestination.ref.placedFootprint.offset = 0;
    _copyDestination.ref.placedFootprint.footprint
      ..format = kD3d12SurfaceFormat
      ..width = texture.width
      ..height = texture.height
      ..depth = 1
      ..rowPitch = rowPitch;

    _copySource.ref
      ..resource = texture._resource
      ..type = d3d12TextureCopyTypeSubresourceIndex;
    _copySource.ref.placedFootprint.offset = 0;

    _frames.list.copyTextureRegion(
      _frames.list.pointer,
      _copyDestination,
      0,
      0,
      0,
      _copySource,
      nullptr,
    );
    _transition(texture, restore);
  }

  // -------------------------------------------------------------------
  // Frame submission
  // -------------------------------------------------------------------

  /// Issues [batcher]'s draw calls into the render target [renderTargetView]
  /// names.
  ///
  /// Device-to-target plumbing, public because targets live in other files.
  /// The command list must already be open and the render target must already
  /// be in `RENDER_TARGET` state - both are the caller's job, because only the
  /// caller knows whether the resource came from a swap chain (and was in
  /// `PRESENT`) or is its own texture (and never left).
  ///
  /// [firstBatch] is what makes a mid-frame flush possible: an atlas that
  /// filled up has to have the batches recorded so far *issued* before its
  /// texels are recycled, and the rest of the frame is submitted afterwards
  /// from where this left off. A batch drawn twice blends twice.
  ///
  /// Returns false when the device was lost on the way.
  bool submit(
    GpuBatcher batcher,
    int surfaceWidth,
    int surfaceHeight,
    int? clearColor, {
    required int renderTargetView,
    int firstBatch = 0,
    int? endBatch,
  }) {
    if (_state.isLost || !_frames.isRecording) return false;
    final D3d12GraphicsCommandList list = _frames.list;

    _rtvSlot.value = renderTargetView;
    list.omSetRenderTargets(list.pointer, 1, _rtvSlot, 0, nullptr);

    if (clearColor != null) {
      // The clear colour arrives packed the way FrameRequest documents it -
      // premultiplied BGRA in a 32-bit int - and ClearRenderTargetView wants
      // straight floats in RGBA order.
      _clearColor[0] = ((clearColor >> 16) & 0xFF) / 255.0;
      _clearColor[1] = ((clearColor >> 8) & 0xFF) / 255.0;
      _clearColor[2] = (clearColor & 0xFF) / 255.0;
      _clearColor[3] = ((clearColor >> 24) & 0xFF) / 255.0;
      list.clearRenderTargetView(
          list.pointer, renderTargetView, _clearColor, 0, nullptr);
    }

    // A half-open upper bound, so an experimental vector command can be drawn
    // *between* two dense batches instead of after all of them. Null means "to
    // the end", which is what every caller that has no vector work passes.
    final int batchCount = endBatch == null
        ? batcher.batchCount
        : (endBatch < batcher.batchCount ? endBatch : batcher.batchCount);
    if (batchCount <= firstBatch) return true;

    if (!_uploadGeometry(batcher)) return false;
    _prepareTexturesForSampling();

    _viewport.ref
      ..topLeftX = 0
      ..topLeftY = 0
      ..width = surfaceWidth.toDouble()
      ..height = surfaceHeight.toDouble()
      ..minDepth = 0
      ..maxDepth = 1;
    list
      ..rsSetViewports(list.pointer, 1, _viewport)
      ..setGraphicsRootSignature(list.pointer, _rootSignature)
      ..iaSetPrimitiveTopology(list.pointer, d3dPrimitiveTopologyTriangleList)
      ..iaSetVertexBuffers(list.pointer, 0, 1, _vertexView)
      ..iaSetIndexBuffer(list.pointer, _indexView);
    _heapSlot.value = _srvHeap.pointer;
    list.setDescriptorHeaps(list.pointer, 1, _heapSlot);

    // The viewport half of the root constants never changes inside a
    // submission, so it is written once. uYFlip is always 0 - see
    // d3d12_shaders.dart on why Direct3D needs no flip where OpenGL does.
    _rootConstants.cast<Float>()[0] = surfaceWidth.toDouble();
    _rootConstants.cast<Float>()[1] = surfaceHeight.toDouble();
    _rootConstants[3] = kD3d12YFlipDefault;

    final _DrawState state = _drawState..reset();
    for (var i = firstBatch; i < batchCount; i++) {
      final GpuBatch batch = batcher.batchAt(i);
      var left = batch.scissorLeft;
      var top = batch.scissorTop;
      var right = batch.scissorRight;
      var bottom = batch.scissorBottom;
      if (left < 0) left = 0;
      if (top < 0) top = 0;
      if (right > surfaceWidth) right = surfaceWidth;
      if (bottom > surfaceHeight) bottom = surfaceHeight;
      if (right <= left || bottom <= top) continue;

      // No y conversion: `D3D12_RECT` is half-open and y-down from the
      // top-left corner, which is exactly what the batcher produces. The GL
      // backend has to flip this and Direct3D does not - see the orientation
      // section of d3d12_shaders.dart.
      _scissor.ref
        ..left = left
        ..top = top
        ..right = right
        ..bottom = bottom;
      list.rsSetScissorRects(list.pointer, 1, _scissor);

      if (batch.blendMode != state.blendMode) {
        state.blendMode = batch.blendMode;
        final Pointer<Void>? pso = _pipelines[batch.blendMode];
        if (pso == null) {
          // gpuBlendForMode would have thrown for an unknown mode, so this can
          // only mean a mode was added there and not here. Naming it beats
          // drawing it with whatever happened to be bound.
          throw UnsupportedCapabilityError(
            backendName: backendName,
            capability: Capability.gpuPresentation,
            detail: 'no pipeline state for blend mode ${batch.blendMode}; a '
                'mode added to gpu_pipeline.dart needs one built in '
                'D3d12RenderDevice._initialise',
          );
        }
        list.setPipelineState(list.pointer, pso);
      }

      final int mode = switch (batch.pipeline) {
        GpuPipelineKind.solid => kD3d12ModeSolid,
        GpuPipelineKind.coverageMask => kD3d12ModeCoverageMask,
        GpuPipelineKind.texturedImage => kD3d12ModeTexturedImage,
      };
      final int textureIndex =
          batch.textureId == kNoTexture ? 0 : batch.textureId;
      final int sampler = _samplerFor(textureIndex);
      if (mode != state.mode || sampler != state.sampler) {
        state.mode = mode;
        state.sampler = sampler;
        _rootConstants[2] = mode;
        _rootConstants[4] = sampler;
      }
      // Root constants are per-draw state in Direct3D 12 rather than a program
      // uniform, and re-sending five dwords costs less than tracking whether
      // the previous draw left them alone would.
      list.setGraphicsRoot32BitConstants(list.pointer, kD3d12RootConstantsSlot,
          kD3d12RootConstantCount, _rootConstants.cast<Void>(), 0);

      if (textureIndex != state.textureId) {
        state.textureId = textureIndex;
        list.setGraphicsRootDescriptorTable(
          list.pointer,
          kD3d12RootTextureSlot,
          _srvHeap.gpuHandleStart + textureIndex * _srvStride,
        );
      }

      list.drawIndexedInstanced(
          list.pointer, batch.indexCount, 1, batch.indexOffset, 0, 0);
    }
    return true;
  }

  /// Explicit sparse-strip submission seam.
  ///
  /// The display-list renderer does not call this method, and that is the whole
  /// shape of the opt-in: a caller has to open the device with
  /// `enableExperimentalSparseStrips: true` and then hand over a plan, so the
  /// established dense atlas path stays the default even on hardware that
  /// would run this faster.
  ///
  /// The command list must already be open and [renderTargetView] must already
  /// be in `RENDER_TARGET` state, exactly as [submit] requires - and for the
  /// same reason: only the caller knows whether the resource came from a swap
  /// chain or is its own texture.
  SparseD3d12ExecutionStats submitSparseStrips(
    SparseStripDrawPlan plan, {
    required List<SparseD3d12Material> materials,
    required int viewportWidth,
    required int viewportHeight,
    required int renderTargetView,
  }) {
    throwIfDisposed();
    final SparseD3d12Executor? executor = _sparseExecutor;
    if (executor == null) {
      throw StateError(
        'sparse strips are disabled; open the Direct3D 12 device with '
        'enableExperimentalSparseStrips: true',
      );
    }
    if (_state.isLost) {
      throw StateError('the Direct3D 12 device is lost');
    }
    if (!_frames.isRecording) {
      throw StateError(
        'no Direct3D 12 command list is open for a sparse-strip submission',
      );
    }
    _rtvSlot.value = renderTargetView;
    _frames.list
        .omSetRenderTargets(_frames.list.pointer, 1, _rtvSlot, 0, nullptr);
    final SparseD3d12ExecutionStats stats = executor.submit(
      plan,
      materials: materials,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
    );
    // The sparse pass replaced the root signature, the pipeline state, the
    // topology and the scissor. A dense range issued after it re-sends all of
    // them at the top of `submit`, but the redundant-state filter would still
    // believe its own record, so it is invalidated here rather than there.
    _drawState.reset();
    return stats;
  }

  /// Explicit compute-tile submission seam.
  ///
  /// Opt-in exactly like [submitSparseStrips], and additionally *outside* a
  /// frame: this pass opens its own command list and waits for the GPU, because
  /// it ends by reading the coverage buffer on the CPU. See the library comment
  /// of `d3d12_compute_tile_driver.dart`.
  /// Rasterises [plan] with the tile shader and **composites it into the render
  /// target**, in draw order, inside the caller's open command list.
  ///
  /// This is the pass that makes approach D produce pixels. Per draw:
  ///
  ///   1. the coverage texture is moved into `UNORDERED_ACCESS`;
  ///   2. one dispatch writes that draw's coverage into it - and only that
  ///      draw's, which is what keeps two overlapping promoted paths from
  ///      reading each other's coverage;
  ///   3. it is moved into `PIXEL_SHADER_RESOURCE`, which is also the
  ///      synchronisation the read needs: a transition out of
  ///      `UNORDERED_ACCESS` is ordered after every write the dispatch issued,
  ///      so no separate UAV barrier is required;
  ///   4. a single quad over the draw's pixel bounds is composited through the
  ///      sparse pipeline, with the draw's material and blend.
  ///
  /// The texture is never cleared between draws, and that is safe rather than
  /// lucky: step 4 draws exactly the rectangle step 2 promises to have written
  /// every pixel of. See [ComputeTileD3d12Executor.dispatchDrawCoverage].
  ///
  /// The command list must already be recording and [renderTargetView] must
  /// already be in `RENDER_TARGET` state, exactly as [submit] requires.
  int submitComputeTilesComposited(
    ComputeTilePlan plan, {
    required List<SparseD3d12Material> materials,
    required int viewportWidth,
    required int viewportHeight,
    required int renderTargetView,
    int sampleGrid = 4,
  }) {
    throwIfDisposed();
    final ComputeTileD3d12Executor? compute = _computeTileExecutor;
    final SparseD3d12Executor? sparse = _sparseExecutor;
    if (compute == null) {
      throw StateError(
        'compute tiles are disabled; open the Direct3D 12 device with '
        'enableExperimentalComputeTiles: true',
      );
    }
    if (sparse == null) {
      throw StateError(
        'the compute composition quad is drawn by the sparse pipeline, which '
        'is not built on this device',
      );
    }
    if (_state.isLost) throw StateError('the Direct3D 12 device is lost');
    if (!_frames.isRecording) {
      throw StateError(
        'no Direct3D 12 command list is open for a compute composition',
      );
    }
    if (plan.drawCount == 0 || plan.commandCount == 0) return 0;

    final D3d12ComputeCoverageTexture coverage =
        _ensureComputeCoverage(viewportWidth, viewportHeight);

    _rtvSlot.value = renderTargetView;
    _frames.list
        .omSetRenderTargets(_frames.list.pointer, 1, _rtvSlot, 0, nullptr);

    var composed = 0;
    for (var draw = 0; draw < plan.drawCount; draw++) {
      if (draw >= materials.length) {
        throw RangeError.range(draw, 0, materials.length - 1, 'materialIndex');
      }
      _transition(coverage.texture, d3d12ResourceStateUnorderedAccess);
      final ComputeTileCompositeRect? rect = compute.dispatchDrawCoverage(
        plan,
        draw: draw,
        coverageDescriptorIndex: coverage.unorderedAccessIndex,
        sampleGrid: sampleGrid,
      );
      if (rect == null) continue;
      _transition(coverage.texture, d3d12ResourceStatePixelShaderResource);
      sparse.submitCoverageQuad(
        coverageTexture: coverage.texture.id,
        left: rect.left,
        top: rect.top,
        right: rect.right,
        bottom: rect.bottom,
        material: materials[draw],
        viewportWidth: viewportWidth,
        viewportHeight: viewportHeight,
      );
      composed++;
    }
    _drawState.reset();
    return composed;
  }

  /// The coverage texture, grown to the largest surface this device has
  /// composed into and reused after that.
  ///
  /// Grown rather than resized to fit exactly: a target that shrinks by a pixel
  /// would otherwise reallocate a full-surface texture and wait for the GPU to
  /// be idle, mid-frame.
  D3d12ComputeCoverageTexture _ensureComputeCoverage(int width, int height) {
    final D3d12ComputeCoverageTexture? existing = _computeCoverage;
    if (existing != null &&
        existing.width >= width &&
        existing.height >= height) {
      return existing;
    }
    final int newWidth =
        existing == null || width > existing.width ? width : existing.width;
    final int newHeight =
        existing == null || height > existing.height ? height : existing.height;
    if (existing != null) {
      // The GPU may still be reading it. Nothing else here is in flight during
      // a resize - a target resize already waited - but the ring's idle wait is
      // the only honest answer to "is anybody still using this".
      _frames.waitIdle();
      releaseComputeCoverageTexture(existing);
      _computeCoverage = null;
    }
    final D3d12ComputeCoverageTexture? created =
        createComputeCoverageTexture(newWidth, newHeight);
    if (created == null) {
      throw UnsupportedCapabilityError(
        backendName: backendName,
        capability: Capability.gpuPresentation,
        detail: 'a ${newWidth}x$newHeight R32_FLOAT compute coverage texture '
            'could not be created; approach D has nowhere to write',
      );
    }
    return _computeCoverage = created;
  }

  ComputeTileCoverage submitComputeTiles(
    ComputeTilePlan plan, {
    int sampleGrid = 4,
  }) {
    throwIfDisposed();
    final ComputeTileD3d12Executor? executor = _computeTileExecutor;
    if (executor == null) {
      throw StateError(
        'compute tiles are disabled; open the Direct3D 12 device with '
        'enableExperimentalComputeTiles: true',
      );
    }
    if (_state.isLost) {
      throw StateError('the Direct3D 12 device is lost');
    }
    return executor.submit(plan, sampleGrid: sampleGrid);
  }

  int _samplerFor(int textureIndex) =>
      textureIndex >= 0 && textureIndex < kTextureCapacity
          ? _samplers[textureIndex]
          : kD3d12SamplerPoint;

  /// Copies the frame's vertices and indices into upload memory and points the
  /// input assembler at them.
  ///
  /// Straight out of the upload heap, with no copy into a default-heap buffer.
  /// A default-heap vertex buffer would be faster for geometry the GPU reads
  /// many times, and this geometry is read exactly once - the copy would cost
  /// more than the read it accelerates.
  bool _uploadGeometry(GpuBatcher batcher) {
    final buffer = batcher.buffer;
    final int floatCount = buffer.vertexCount * kGpuFloatsPerVertex;
    final int vertexBytes = floatCount * 4;
    final int indexCount = buffer.indexCount;
    final int indexBytes = indexCount * 4;
    if (vertexBytes == 0 || indexBytes == 0) return true;

    final D3d12UploadRange? vertices =
        _frames.reserveUpload(vertexBytes, alignment: 256);
    final D3d12UploadRange? indices =
        _frames.reserveUpload(indexBytes, alignment: 256);
    if (vertices == null || indices == null) {
      markLost('the frame geometry did not fit in an upload buffer',
          detail: '$vertexBytes vertex bytes and $indexBytes index bytes');
      return false;
    }

    vertices.cpu
        .cast<Float>()
        .asTypedList(floatCount)
        .setRange(0, floatCount, buffer.vertexStorage);
    indices.cpu
        .cast<Uint32>()
        .asTypedList(indexCount)
        .setRange(0, indexCount, buffer.indexStorage);

    _vertexView.ref
      ..bufferLocation = vertices.gpuAddress
      ..sizeInBytes = vertexBytes
      ..strideInBytes = kGpuFloatsPerVertex * 4;
    _indexView.ref
      ..bufferLocation = indices.gpuAddress
      ..sizeInBytes = indexBytes
      ..format = dxgiFormatR32Uint;
    return true;
  }

  // -------------------------------------------------------------------
  // Teardown
  // -------------------------------------------------------------------

  @override
  void onDispose() {
    _frames.waitIdle();
    // Before the textures, because the executor hands its alpha pages back
    // through releaseTexture and a page released twice is a double release.
    final SparseD3d12Executor? sparse = _sparseExecutor;
    if (sparse != null && !sparse.isDisposed) {
      if (_state.isLost) {
        sparse.disposeAfterDeviceLoss();
      } else {
        sparse.dispose();
      }
    }
    _sparseExecutor = null;
    _sparseDriver?.dispose();
    _sparseDriver = null;
    final ComputeTileD3d12Executor? compute = _computeTileExecutor;
    if (compute != null && !compute.isDisposed) {
      if (_state.isLost) {
        compute.disposeAfterDeviceLoss();
      } else {
        compute.dispose();
      }
    }
    _computeTileExecutor = null;
    _computeTileDriver?.dispose();
    _computeTileDriver = null;
    final D3d12ComputeCoverageTexture? coverage = _computeCoverage;
    _computeCoverage = null;
    if (coverage != null && !_state.isLost) {
      releaseComputeCoverageTexture(coverage);
    }
    for (final D3d12Texture texture in _textures.toList()) {
      texture._released = true;
      ComObject(texture._resource).release();
    }
    _textures.clear();
    for (final Pointer<Void> pso in _pipelines.values) {
      ComObject(pso).release();
    }
    _pipelines.clear();
    releaseCom(_rootSignature);
    _vertexBlob.release();
    _pixelBlob.release();
    _srvHeap.release();
    _rtvHeap.release();
    _frames.dispose();
    _queue.release();
    _infoQueue?.release();
    _device.release();
    _factory.release();
    _library.allocator
      ..free(_viewport)
      ..free(_scissor)
      ..free(_rtvSlot)
      ..free(_clearColor)
      ..free(_rootConstants)
      ..free(_vertexView)
      ..free(_indexView)
      ..free(_heapSlot)
      ..free(_copyDestination)
      ..free(_copySource)
      ..free(_descriptorHandleSlot)
      ..free(_barriers);
  }
}

/// The state [D3d12RenderDevice.submit] has already sent, so it does not send
/// it again.
final class _DrawState {
  int textureId = -1;
  int mode = -1;
  int blendMode = -1;
  int sampler = -1;

  void reset() {
    textureId = -1;
    mode = -1;
    blendMode = -1;
    sampler = -1;
  }
}

/// The adapter that answered, and at which level.
final class _AdapterChoice {
  const _AdapterChoice(this.device, this.featureLevel, this.description);

  final D3d12Device device;
  final int featureLevel;
  final String description;
}

/// `DXGI_ADAPTER_FLAG_SOFTWARE`.
const int _dxgiAdapterFlagSoftware = 2;

/// A fixed-width UTF-16 field as a Dart string, stopping at the first NUL.
String _readUtf16(Array<Uint16> array, int capacity) {
  final StringBuffer buffer = StringBuffer();
  for (var i = 0; i < capacity; i++) {
    final int unit = array[i];
    if (unit == 0) break;
    buffer.writeCharCode(unit);
  }
  return buffer.toString();
}

/// Turns the display list's interned font ids into faces for the sink.
///
/// The same shape as `GlFontResolver`, and for the same reason: the sink is
/// handed a raw `fontId` because the player never asks what a glyph looks
/// like, so whoever has to rasterise needs the table the player is walking.
final class D3d12FontResolver implements GpuFontResolver {
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

/// Uploads drawn images into textures, once each.
///
/// Keyed by identity and never evicting, exactly like `GlImageCache`: an
/// eviction policy needs a frame budget this framework does not measure yet,
/// and a wrong one re-uploads the image being animated. [clear] is the escape
/// hatch and the target calls it on dispose.
final class D3d12ImageCache implements GpuImageResolver {
  D3d12ImageCache(this._device);

  final D3d12RenderDevice _device;
  final Map<Object, D3d12Texture> _textures =
      Map<Object, D3d12Texture>.identity();

  /// Where a decoded video frame becomes a texture.
  ///
  /// A separate cache and not another entry in the map above, because that map
  /// is keyed by image identity and never evicts - which is right for a still
  /// and ruinous for a stream that produces a new object twenty-five times a
  /// second. See `gpu_video_image.dart` for the whole argument and for how one
  /// texture per stream is reused instead.
  ///
  /// [ImageChannelOrder.rgba] because every image texture here is created as
  /// `rgba8888Premultiplied` and [_asRgba] swizzles a BGRA source into it; the
  /// video conversion writes that order directly instead.
  late final GpuVideoImageCache _video = GpuVideoImageCache(
    _device,
    channelOrder: ImageChannelOrder.rgba,
  );

  int get length => _textures.length;

  /// The video streams this cache holds a texture for. One per stream, never
  /// one per frame.
  int get videoStreamCount => _video.streamCount;

  @override
  GpuTextureHandle? resolve(Object image) {
    // A VideoFrame is not a Framebuffer, and returning null for it is what
    // made every accelerated backend refuse to draw video by name. The video
    // cache answers null for anything that is not a frame either, so this
    // stays the single "this device cannot draw it" exit.
    if (image is! Framebuffer) return _video.resolve(image);
    final D3d12Texture? cached = _textures[image];
    if (cached != null && cached.isValid) return cached;

    final D3d12Texture texture;
    try {
      texture = _device.createTexture(
        width: image.width,
        height: image.height,
        format: GpuTextureFormat.rgba8888Premultiplied,
        // Linear, unlike the atlases: an image is drawn at whatever scale the
        // layout produced, and nearest sampling there is the blocky,
        // shimmering resampling that reads as a renderer bug.
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
    _textures[image] = texture;
    return texture;
  }

  void clear() {
    for (final D3d12Texture texture in _textures.values) {
      _device.releaseTexture(texture);
    }
    _textures.clear();
    _video.clear();
  }

  /// The image's bytes in the order `DXGI_FORMAT_R8G8B8A8_UNORM` expects.
  ///
  /// A BGRA `Framebuffer` is swizzled here rather than given its own texture
  /// format, because the format is baked into the pipeline state objects and a
  /// second one would double them - see [kD3d12SurfaceFormat]. Rows are
  /// repacked at the same time, since a [Framebuffer] wrapping a platform
  /// surface routinely has a stride wider than its width.
  static Uint8List _asRgba(Framebuffer image) {
    final Uint8List packed = Uint8List(image.width * image.height * 4);
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

/// Writes the interface identifier [text] into this pointer and returns it.
extension _GuidTarget on Pointer<Guid> {
  void let(String text) => writeGuid(this, text);
}
