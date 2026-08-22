/// The WebGPU backend: the same renderer as `webgl_backend.dart`, one API up.
///
/// This file is a port of a port, and saying so places it exactly: every
/// structural decision was made in `gl_backend.dart`, carried into
/// `webgl_backend.dart` with the four browser differences its header lists,
/// and arrives here with those four intact plus the ones WebGPU itself forces.
/// Where this file repeats a neighbour's shape - the integer object table, the
/// grown-and-reused staging lists, the mid-frame flush that remembers how many
/// batches it issued - the argument for it lives in those files and is not
/// re-argued here.
///
/// ## The four things WebGPU makes different from WebGL2
///
/// **1. Everything that can refuse, refuses asynchronously.** `requestAdapter`
/// and `requestDevice` are promises, and validation errors arrive on an
/// `uncapturederror` event long after the call that caused them returned. So
/// the sync/async split moves: device *creation* happens in the presenter's
/// async `attach`, while this device adopts an already-answered `GPUDevice`
/// and does only synchronous work - which is also what keeps the
/// [RendererBackend.probe] contract honest, see [WebGpuRendererBackend.probe].
///
/// **2. Blend state lives inside the pipeline.** GL switches a blend function
/// between draw calls; WebGPU bakes it into a `GPURenderPipeline` at creation.
/// The mode uniform of `gl_shaders.dart` therefore dissolves into the pipeline
/// too: nine pipelines at most - three fragment entry points by three blend
/// modes - created lazily, cached for the device's life, and switched per
/// batch exactly where GL switched a uniform and a blend function. See
/// `wgsl_shaders.dart` for the whole argument.
///
/// **3. There is no `isContextLost()` to poll.** A `GPUDevice` reports loss by
/// resolving its `lost` promise, once. This device subscribes at adoption and
/// folds the answer into the same [GpuDeviceState] every other backend uses;
/// `checkDeviceAlive` reads that state rather than asking the API, because
/// there is nothing synchronous to ask.
///
/// **4. Loss is terminal for the object, not the canvas.** A lost WebGL
/// context is restored *in place* and signalled by an event on the canvas; a
/// lost `GPUDevice` never comes back - recovery means requesting a fresh
/// adapter and device, which is asynchronous. [recreateDevice] therefore
/// consumes a replacement the owner staged with [stageReplacementDevice], and
/// says so by name when the owner has not - the same honest refusal
/// `webgl_backend.dart` gives for a recovery driven before
/// `webglcontextrestored`.
///
/// ## One target, and it never reads pixels back
///
/// The WebGL backend carries an offscreen readback target for the CPU-parity
/// suite. This backend deliberately does not, yet: a WebGPU readback is
/// `copyTextureToBuffer` plus an async `mapAsync`, a different contract than
/// the synchronous `Framebuffer` the parity harness reads, and a half-ported
/// harness would be a parity claim nothing measures. `createTarget` refuses a
/// [MemorySurfaceDescriptor] by name; the canvas target in
/// `webgpu_canvas_target.dart` is the one that puts pixels on a page, and
/// section 23's no-readback rule is satisfied by construction.
///
/// `dart:ffi` must never appear here, for `webgl_backend.dart`'s reason, and
/// the same compilation test enforces it: this library is reachable from
/// `test/backends/web/web_compilation_fixture.dart`.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../../../foundation/diagnostics.dart';
import '../../../foundation/lifecycle.dart';
import '../../../text/typeface.dart';
import '../../framebuffer.dart';
import '../../renderer.dart';
import '../../replay/display_list_player.dart';
import '../gpu_batcher.dart';
import '../gpu_device_state.dart';
import '../gpu_layer_stack.dart';
import '../gpu_pipeline.dart';
import '../gpu_raster_sink.dart';
import '../gpu_recovery.dart';
import '../gpu_texture.dart';
import '../gpu_vertex_buffer.dart';
import '../webgl/webgl_framebuffer_pool.dart' show WebGlObjectTable;
import 'webgpu_interop.dart';
import 'webgpu_surface_descriptor.dart';
import 'wgsl_shaders.dart';

/// What the device binds when a batch names a texture id: the view to sample
/// and the filter its sampler must use.
///
/// The WebGPU face of the integer-numbering scheme `webgl_framebuffer_pool.
/// dart` explains: `GpuBatch.textureId` is an `int` the batcher compares, a
/// `GPUTextureView` is an opaque object with no number attached, so the
/// backend keeps its own table. The table type itself is *imported* from the
/// WebGL backend rather than copied - [WebGlObjectTable] is pure Dart, the
/// constraint it answers is identical in both backends, and a copy would be a
/// second monotonic counter whose only difference could be a bug.
final class WebGpuSampledTexture {
  const WebGpuSampledTexture({required this.view, required this.filter});

  final GPUTextureView view;
  final GpuTextureFilter filter;
}

/// A texture owned by a [WebGpuRenderDevice].
///
/// Carries both identities, like [WebGlObjectTable] demands: [id], the integer
/// the batcher compares, and [texture]/[view], the objects the browser binds.
final class WebGpuTexture implements GpuTextureHandle {
  WebGpuTexture._(
    this.id,
    this.texture,
    this.view,
    this.width,
    this.height,
    this.format,
    this.filter,
    this._state,
  ) : _bornAtLossCount = _state.lossCount;

  @override
  final int id;

  final GPUTexture texture;
  final GPUTextureView view;

  @override
  final int width;

  @override
  final int height;

  @override
  final GpuTextureFormat format;

  @override
  final GpuTextureFilter filter;

  final GpuDeviceState _state;
  bool _released = false;

  /// [GpuDeviceState.lossCount] when this texture was created. The same field,
  /// for the same reason, as `WebGlTexture._bornAtLossCount`: `isLost` goes
  /// back to false when the device recovers, `lossCount` never goes down, and
  /// a pre-loss handle must stay dead after the recovery.
  final int _bornAtLossCount;

  @override
  bool get isValid =>
      !_released && !_state.isLost && _state.lossCount == _bornAtLossCount;

  @override
  String toString() =>
      'WebGpuTexture($id, ${width}x$height, ${format.name}, ${filter.name})';
}

/// A target that can put its GPU resources back after a device loss.
///
/// The WebGPU twin of `WebGlRecoverableTarget`, held through an interface for
/// the same reason: the device walks every live target during a recovery
/// without knowing which kind each is.
abstract interface class WebGpuRecoverableTarget {
  Iterable<GpuRecoverableResource> recoverableResources();
}

/// The pipeline and bind-group state `submit` has already set on the current
/// render pass, so it does not set it again.
///
/// Unlike `webgl_backend.dart`'s `_DrawState`, this one is reset per *pass*
/// rather than carried across them: WebGPU render-pass encoders start with no
/// pipeline, no bind groups and no buffers bound, so state that GL could carry
/// across a framebuffer switch genuinely does not survive a pass boundary
/// here. Carrying it anyway would skip a `setPipeline` the encoder needs and
/// fail validation on the first batch of the second pass.
final class _PassState {
  int pipelineKey = -1;
  int textureId = -1;

  void reset() {
    pipelineKey = -1;
    textureId = -1;
  }
}

/// A `GPUDevice` plus the objects every target on it shares.
final class WebGpuRenderDevice
    with DisposableMixin
    implements RenderDevice, GpuTextureAllocator, GpuRecoveryHost {
  WebGpuRenderDevice._({
    required GPUDevice device,
    required String surfaceFormat,
    required RendererInfo info,
    required int maxTextureSize,
  })  : _gpuDevice = device,
        _surfaceFormat = surfaceFormat,
        _info = info,
        _maxTextureSize = maxTextureSize;

  /// Wraps an already-requested `GPUDevice`.
  ///
  /// **Takes ownership**, and that is a deliberate difference from
  /// `WebGlRenderDevice.adoptContext`, which borrows. A WebGL context belongs
  /// to its canvas - a DOM element the page owns - so disposing the wrapper
  /// must not touch it. A `GPUDevice` belongs to nobody but the code that
  /// requested it: it is not reachable from the DOM, and a wrapper that did
  /// not `destroy()` it on dispose would leave every buffer and texture alive
  /// until garbage collection got around to the handle, which for GPU memory
  /// is an unbounded leak with a working page in front of it.
  ///
  /// [surfaceFormat] is `navigator.gpu.getPreferredCanvasFormat()`, passed in
  /// rather than asked for here because asking needs the [GPU] object and the
  /// device deliberately does not hold one. Every render pipeline this device
  /// builds targets that format, and every render *target* - the canvas and
  /// the pooled layer textures alike - is created in it, which is what lets
  /// one pipeline cache serve both.
  ///
  /// Returns the device, or a diagnostic naming what refused. Never throws,
  /// per section 6.6: a browser that will not build the renderer objects is a
  /// machine this backend cannot run on, which is reported, not raised.
  static ({WebGpuRenderDevice? device, BackendDiagnostic? failure}) adoptDevice(
    GPUDevice gpuDevice, {
    required String surfaceFormat,
    String? deviceDescription,
  }) {
    final int maxTextureSize = _readMaxTextureSize(gpuDevice);
    final WebGpuRenderDevice device = WebGpuRenderDevice._(
      device: gpuDevice,
      surfaceFormat: surfaceFormat,
      info: RendererInfo(
        name: WebGpuRendererBackend.backendName,
        deviceDescription:
            deviceDescription ?? 'WebGPU, adapter not described',
        rasterizationApproach: RasterizationApproach.analyticCoverageAtlas,
      ),
      maxTextureSize: maxTextureSize,
    );
    final BackendDiagnostic? failure = device._initialise();
    if (failure != null) {
      device.dispose();
      return (device: null, failure: failure);
    }
    device._watchDevice(gpuDevice);
    return (device: device, failure: null);
  }

  GPUDevice _gpuDevice;
  final String _surfaceFormat;
  RendererInfo _info;
  final int _maxTextureSize;
  final GpuDeviceState _state = GpuDeviceState();

  /// The device, for the targets that configure a canvas context on it and
  /// for the layer pool that creates render textures. Device-to-target
  /// plumbing, not application API - `webgl_backend.dart`'s `gl` getter makes
  /// the same disclaimer for the same reason.
  GPUDevice get gpuDevice => _gpuDevice;

  GpuDeviceState get state => _state;

  /// The texture format every render pipeline targets and every render
  /// target is created in. See [adoptDevice].
  String get surfaceFormat => _surfaceFormat;

  /// The integer numbering that stands in for texture identity.
  ///
  /// Shared with every target and with each layer pool, for the reason
  /// `webgl_backend.dart` gives: `GpuBatch.textureId` is compared across all
  /// of them, and two tables would hand out the same integer twice.
  final WebGlObjectTable<WebGpuSampledTexture> sampledTextures =
      WebGlObjectTable<WebGpuSampledTexture>();

  // The shared pipeline objects. Not final: a recovery drops and rebuilds
  // them, exactly as the WebGL device drops its program and buffers.
  GPUShaderModule? _module;
  GPUBindGroupLayout? _frameLayout;
  GPUBindGroupLayout? _textureLayout;
  GPUPipelineLayout? _pipelineLayout;
  GPUSampler? _nearestSampler;
  GPUSampler? _linearSampler;
  GPUTexture? _dummyTexture;
  GPUBindGroup? _dummyBindGroup;
  GPUBuffer? _uniformBuffer;
  int _uniformCapacitySlices = 0;
  GPUBindGroup? _frameBindGroup;
  GPUBuffer? _vertexBuffer;
  GPUBuffer? _indexBuffer;

  /// Pipelines keyed by `(pipelineKind.index << 8) | blendMode`. Lazy: a page
  /// that never draws `plus`-blended images never pays for those pipelines.
  final Map<int, GPURenderPipeline> _pipelines = <int, GPURenderPipeline>{};

  /// Bind groups keyed by texture id, so a batch switch is a map hit rather
  /// than a descriptor build. Evicted with the texture that backs each one.
  final Map<int, GPUBindGroup> _textureBindGroups = <int, GPUBindGroup>{};

  /// Staging for uploads, grown and reused. A frame must not allocate - the
  /// rule `gl_backend.dart`'s native scratch buffers exist for.
  Float32List _vertexStaging = Float32List(0);
  Uint32List _indexStaging = Uint32List(0);
  Uint8List _pixelStaging = Uint8List(0);
  final Float32List _uniformStaging = Float32List(2);

  @override
  RendererInfo get info => _info;

  @override
  bool get isLost => _state.isLost;

  final Set<WebGpuRecoverableTarget> _targets = <WebGpuRecoverableTarget>{};
  bool _submissionsStopped = false;
  int _blockedSubmissionCount = 0;
  GPUDevice? _stagedReplacement;
  String? _stagedDescription;

  /// How many submissions were refused because a recovery was in progress.
  /// Exposed because it is invisible from the pixels.
  int get blockedSubmissionCount => _blockedSubmissionCount;

  bool get submissionsStopped => _submissionsStopped;

  @override
  String get backendName => WebGpuRendererBackend.backendName;

  @override
  GpuDeviceState get deviceState => _state;

  void registerTarget(WebGpuRecoverableTarget target) => _targets.add(target);

  void unregisterTarget(WebGpuRecoverableTarget target) =>
      _targets.remove(target);

  /// Step 1 of a recovery: nothing more goes to the driver.
  @override
  void stopSubmissions() => _submissionsStopped = true;

  /// Step 3: forget the shared objects without calling the device.
  ///
  /// Calling `destroy` on objects of a lost device is defined to be safe, but
  /// the handles refer to memory the browser has already reclaimed and keeping
  /// them would let a later frame bind a pipeline that can never run. The
  /// fields are dropped and [_initialise] makes new ones on the replacement.
  @override
  void discardNativeResources() {
    _module = null;
    _frameLayout = null;
    _textureLayout = null;
    _pipelineLayout = null;
    _nearestSampler = null;
    _linearSampler = null;
    _dummyTexture = null;
    _dummyBindGroup = null;
    _uniformBuffer = null;
    _uniformCapacitySlices = 0;
    _frameBindGroup = null;
    _vertexBuffer = null;
    _indexBuffer = null;
    _pipelines.clear();
    _textureBindGroups.clear();
    _lastError = null;
    // The integer numbering goes too, for `webgl_backend.dart`'s reason: every
    // view it named died with the device, and an id that resolved to one would
    // let a pre-loss batch bind a dead object and draw nothing.
    sampledTextures.clear();
  }

  /// Hands this device the `GPUDevice` a recovery will rebuild on.
  ///
  /// Split from [recreateDevice] because the request is asynchronous and the
  /// recovery step is not - see difference 4 in the library comment. The owner
  /// awaits `requestAdapter`/`requestDevice`, stages the answer here, and only
  /// then drives the synchronous recovery steps.
  void stageReplacementDevice(GPUDevice device, {String? deviceDescription}) {
    _stagedReplacement = device;
    _stagedDescription = deviceDescription;
  }

  /// Step 4: rebuild everything shared, on the staged replacement device.
  ///
  /// The case it cannot recover from is an owner that staged nothing: a lost
  /// `GPUDevice` never comes back and a new one can only be requested
  /// asynchronously, so a synchronous recovery with no staged device has
  /// nothing to build on. It says so by name, exactly as the WebGL device
  /// refuses a recovery driven before `webglcontextrestored`.
  @override
  BackendDiagnostic? recreateDevice() {
    if (isDisposed) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'a disposed WebGPU device cannot be recovered',
        detail: 'the owner must create a new device through '
            'WebGpuRendererBackend.createDevice or adoptDevice',
      );
    }
    final bool wasLost = _state.isLost;
    final BackendDiagnostic? cause = _state.lossDiagnostic;
    _state.recover();

    final GPUDevice? staged = _stagedReplacement;
    if (staged == null) {
      if (!wasLost) {
        return const BackendDiagnostic(
          kind: DiagnosticKind.note,
          message: 'the WebGPU device was not lost when the recovery ran',
        );
      }
      final BackendDiagnostic failure = BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'the lost GPUDevice cannot be rebuilt in place, and no '
            'replacement was staged',
        detail: 'a lost WebGPU device never comes back; the owner requests a '
            'new adapter and device - which is asynchronous - and stages the '
            'answer with stageReplacementDevice before recovering. The '
            'original loss was: ${cause ?? 'not recorded'}',
      );
      _state.markLost(failure);
      return failure;
    }

    _stagedReplacement = null;
    _detachDeviceListeners(_gpuDevice);
    _gpuDevice = staged;
    if (_stagedDescription != null) {
      _info = RendererInfo(
        name: WebGpuRendererBackend.backendName,
        deviceDescription: _stagedDescription!,
        rasterizationApproach: RasterizationApproach.analyticCoverageAtlas,
      );
      _stagedDescription = null;
    }

    final BackendDiagnostic? failure = _initialise();
    if (failure != null) {
      _state.markLost(failure);
      return failure;
    }
    _submissionsStopped = false;
    _watchDevice(_gpuDevice);
    if (!wasLost) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.note,
        message: 'the WebGPU device was not lost when the recovery ran',
      );
    }
    return null;
  }

  /// Step 5's inventory: everything every live target owns.
  @override
  Iterable<GpuRecoverableResource> recoverableResources() sync* {
    for (final WebGpuRecoverableTarget target
        in List<WebGpuRecoverableTarget>.of(_targets)) {
      yield* target.recoverableResources();
    }
  }

  /// What this device can do, answered field by field.
  ///
  /// The answers are the WebGL device's, and for its reasons: a canvas is
  /// composited whole (`supportsPartialPresent: false`), the antialiasing is
  /// analytic (`supportsMsaa: false`), and text is drawn even though no
  /// boolean here says so - every target carries a glyph atlas, an alpha8
  /// texture and a font resolver. `supportsCompute` stays false even though
  /// WebGPU has compute shaders, because *this renderer* submits none; the
  /// field describes the backend as built, not the API's brochure.
  @override
  RendererCapabilities get capabilities => RendererCapabilities(
        supportsPartialPresent: false,
        supportsMsaa: false,
        supportsCompute: false,
        supportsExternalTextures: false,
        supportsLinearColor: false,
        maxTextureSize: _maxTextureSize,
        formats: const <PixelFormat>{
          PixelFormat.rgba8888Premultiplied,
          PixelFormat.bgra8888Premultiplied,
        },
      );

  /// Refuses every descriptor, each by name.
  ///
  /// A [WebGpuCanvasSurfaceDescriptor] is handled by `WebGpuCanvasTarget`,
  /// which lives in another library, for the import-cycle reason
  /// `webgl_backend.dart` gives. A [MemorySurfaceDescriptor] is the offscreen
  /// readback target this backend deliberately does not have yet - see the
  /// library comment - and refusing it loudly is what keeps that a visible
  /// gap instead of a target that renders perfectly and reads back garbage.
  @override
  RenderTarget createTarget(NativeSurfaceDescriptor surface) {
    throwIfDisposed();
    if (surface is MemorySurfaceDescriptor) {
      throw UnsupportedCapabilityError(
        backendName: WebGpuRendererBackend.backendName,
        capability: Capability.gpuPresentation,
        detail: 'the WebGPU backend has no offscreen readback target yet: a '
            'readback is copyTextureToBuffer plus an async mapAsync, which is '
            'a different present contract than the synchronous Framebuffer '
            'the parity harness reads. The CPU-parity suite runs on the '
            'webgl2 backend; on-page presentation is WebGpuCanvasTarget',
      );
    }
    throw UnsupportedCapabilityError(
      backendName: WebGpuRendererBackend.backendName,
      capability: Capability.gpuPresentation,
      detail: 'this device was handed a ${surface.kind} '
          '(${surface.runtimeType}), which it has no way to present to. A '
          'canvas is presented to by WebGpuCanvasTarget, which the code that '
          'owns the canvas constructs - see '
          'lib/src/backends/web/web_gpu_presenter.dart',
    );
  }

  // -------------------------------------------------------------------
  // Textures
  // -------------------------------------------------------------------

  @override
  WebGpuTexture createTexture({
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
    if (width > _maxTextureSize || height > _maxTextureSize) {
      throw UnsupportedCapabilityError(
        backendName: WebGpuRendererBackend.backendName,
        capability: Capability.gpuPresentation,
        detail: 'a ${width}x$height texture exceeds this device\'s '
            'maxTextureDimension2D of $_maxTextureSize; the caller must tile '
            'the image or scale it down',
      );
    }
    // No null check, and that is not an oversight: WebGPU creation calls on a
    // lost device return inert objects rather than null, and validation
    // reports through `uncapturederror`. The state check is what stands in
    // for WebGL's `createTexture() == null`.
    final GPUTexture texture = _gpuDevice.createTexture(GPUTextureDescriptor(
      size: GPUExtent3DDict(width: width, height: height),
      format: format == GpuTextureFormat.alpha8 ? 'r8unorm' : 'rgba8unorm',
      usage: web.$GPUTextureUsage.TEXTURE_BINDING |
          web.$GPUTextureUsage.COPY_DST,
    ));
    final GPUTextureView view = texture.createView();
    return WebGpuTexture._(
      sampledTextures
          .register(WebGpuSampledTexture(view: view, filter: filter)),
      texture,
      view,
      width,
      height,
      format,
      filter,
      _state,
    );
  }

  /// Uploads [height] rows of [pixels], each [bytesPerRow] bytes apart.
  ///
  /// Rows are repacked into contiguous staging, keeping this backend's upload
  /// path identical to the other two GL-family backends'. `writeTexture` has
  /// no 256-byte row-alignment requirement - that rule is
  /// `copyBufferToTexture`'s - so the repacked rows go over as they are.
  @override
  void uploadRegion(
    covariant WebGpuTexture texture, {
    required int x,
    required int y,
    required int width,
    required int height,
    required Uint8List pixels,
    required int bytesPerRow,
  }) {
    if (width <= 0 || height <= 0) return;
    if (!checkDeviceAlive()) return;
    final int rowBytes = width * texture.format.bytesPerPixel;
    final int bytes = rowBytes * height;
    final Uint8List staging = _ensurePixelStaging(bytes);
    for (var row = 0; row < height; row++) {
      staging.setRange(
        row * rowBytes,
        row * rowBytes + rowBytes,
        pixels,
        row * bytesPerRow,
      );
    }
    _gpuDevice.queue.writeTexture(
      GPUTexelCopyTextureInfo(
        texture: texture.texture,
        origin: GPUOrigin3DDict(x: x, y: y),
      ),
      // A view of exactly this region's bytes, for `webgl_backend.dart`'s
      // reason: the staging list is usually larger, and handing the whole of
      // it over would send stale texels.
      Uint8List.sublistView(staging, 0, bytes).toJS,
      GPUTexelCopyBufferLayout(
        offset: 0,
        bytesPerRow: rowBytes,
        rowsPerImage: height,
      ),
      GPUExtent3DDict(width: width, height: height),
    );
  }

  /// Destroys [texture], or forgets it when the device already has.
  ///
  /// The destroy is unconditional where WebGL's delete is guarded, because
  /// `GPUTexture.destroy()` is defined to be safe on a lost device; what must
  /// still be conditional is the *bookkeeping*, and the bind-group cache entry
  /// goes with the id either way.
  @override
  void releaseTexture(covariant WebGpuTexture texture) {
    if (texture._released) return;
    texture._released = true;
    sampledTextures.release(texture.id);
    _textureBindGroups.remove(texture.id);
    if (isDisposed) return;
    texture.texture.destroy();
  }

  /// Registers a view someone else created - a layer pool's render texture -
  /// under this device's numbering, so a composite quad can name it the way
  /// it names every other texture.
  int registerSampledView(GPUTextureView view, GpuTextureFilter filter) =>
      sampledTextures.register(WebGpuSampledTexture(view: view, filter: filter));

  /// Forgets a registered view and the bind group cached for it.
  void releaseSampledView(int id) {
    sampledTextures.release(id);
    _textureBindGroups.remove(id);
  }

  // -------------------------------------------------------------------
  // Frame submission
  // -------------------------------------------------------------------

  /// Issues a batch list, switching render passes where [layers] says to.
  ///
  /// The port of `WebGlRenderDevice.submit`, with the target switch expressed
  /// the way WebGPU expresses it: one command encoder, one render pass per
  /// (target, batch range), one queue submit at the end. The three things it
  /// has to get right are the same three - where the batches go, which way up
  /// each pass is (nowhere: see `wgsl_shaders.dart` on the absent yFlip), and
  /// how far it already got ([firstBatch], because a batch drawn twice blends
  /// twice).
  ///
  /// [surfaceView] is the attachment for the surface's own runs - the canvas's
  /// current swap texture, fetched by the caller because `getCurrentTexture`
  /// belongs to the canvas context this device deliberately does not hold.
  ///
  /// The clear semantics differ from GL in mechanism and not in outcome: there
  /// is no free-standing `clear` call, so [clearColor] becomes the `loadOp` of
  /// the first surface pass this submission encodes, and a layer pass that
  /// `clearsTarget` clears through its own `loadOp`. A caller resuming after a
  /// mid-frame flush passes null and every pass loads, which is exactly the
  /// "clearing again would erase everything drawn before the flush" rule.
  ///
  /// Returns false when the device was lost on the way, which the caller turns
  /// into [PresentStatus.deviceLost].
  bool submit(
    GpuBatcher batcher,
    int surfaceWidth,
    int surfaceHeight,
    int? clearColor, {
    required GPUTextureView surfaceView,
    GpuLayerStack? layers,
    WebGpuLayerTargetPool? layerPool,
    int firstBatch = 0,
  }) {
    if (_submissionsStopped) {
      _blockedSubmissionCount++;
      return false;
    }
    if (!checkDeviceAlive()) return false;

    final int batchCount = batcher.batchCount;
    bool surfaceClearPending = clearColor != null;
    if (batchCount <= firstBatch && !surfaceClearPending) {
      // Nothing to draw and nothing to clear. GL would still bind and return;
      // here an encoder with no passes would be a submit of nothing.
      return !_state.isLost;
    }

    if (batchCount > firstBatch) _uploadGeometry(batcher);

    final GPUCommandEncoder encoder = _gpuDevice.createCommandEncoder();
    final _PassState state = _passState;
    var uniformSlice = 0;

    final int passCount = layers?.passCount ?? 0;
    if (passCount == 0) {
      _ensureUniformCapacity(1);
      final GPURenderPassEncoder pass = _beginPass(
        encoder,
        view: surfaceView,
        clear: surfaceClearPending ? clearColor : null,
        slice: uniformSlice,
        viewportWidth: surfaceWidth,
        viewportHeight: surfaceHeight,
      );
      surfaceClearPending = false;
      uniformSlice++;
      if (batchCount > firstBatch) {
        _drawBatches(pass, batcher, firstBatch, batchCount, surfaceWidth,
            surfaceHeight, state);
      }
      pass.end();
    } else {
      // Upper bound: one slice per pass. Grown before any pass is encoded,
      // because growing the buffer recreates the frame bind group and a bind
      // group must not change under an encoder that already referenced it.
      _ensureUniformCapacity(passCount);
      for (var p = 0; p < passCount; p++) {
        final GpuRenderPass renderPass = layers!.passAt(p);
        final int end = layers.passEnd(p, batchCount);
        if (end <= firstBatch) continue;
        final int start = renderPass.firstBatch < firstBatch
            ? firstBatch
            : renderPass.firstBatch;
        final bool clears =
            renderPass.clearsTarget && start == renderPass.firstBatch;
        // An empty pass that clears must still be encoded - see
        // `webgl_backend.dart`: a layer whose first act is to open a nested
        // layer records no batches until that one closes, and its target
        // still has to lose the previous tenant's pixels.
        if (end <= start && !clears && renderPass.target != null) continue;

        final GpuLayerTarget? target = renderPass.target;
        GPUTextureView view;
        int? passClear;
        if (target == null) {
          view = surfaceView;
          passClear = surfaceClearPending ? clearColor : null;
          if (end <= start && passClear == null) continue;
          surfaceClearPending = false;
        } else {
          final GPUTextureView? layerView = layerPool?.viewFor(target.id);
          if (layerView == null) {
            // An unbacked target: the pool already reported the refusal and
            // marked the device lost. Encoding a pass against nothing would
            // throw out of the frame loop, which is the one thing a loss must
            // never do.
            continue;
          }
          view = layerView;
          // A layer composites what it drew over transparency, and the clear
          // covers the whole pooled target - slack included - through the
          // loadOp, which scissors nothing.
          passClear = clears ? 0x00000000 : null;
        }

        final GPURenderPassEncoder pass = _beginPass(
          encoder,
          view: view,
          clear: passClear,
          slice: uniformSlice,
          viewportWidth: renderPass.viewportWidth,
          viewportHeight: renderPass.viewportHeight,
        );
        uniformSlice++;
        if (end > start) {
          _drawBatches(pass, batcher, start, end, renderPass.viewportWidth,
              renderPass.viewportHeight, state);
        }
        pass.end();
      }
    }

    _gpuDevice.queue.submit(<GPUCommandBuffer>[encoder.finish()].toJS);
    return !_state.isLost;
  }

  final _PassState _passState = _PassState();

  /// Opens one render pass: writes its viewport into the next uniform slice,
  /// begins the pass, and binds the geometry and the per-pass group.
  GPURenderPassEncoder _beginPass(
    GPUCommandEncoder encoder, {
    required GPUTextureView view,
    required int? clear,
    required int slice,
    required int viewportWidth,
    required int viewportHeight,
  }) {
    final int offset = slice * kWebGpuUniformSliceStride;
    _uniformStaging[0] = viewportWidth.toDouble();
    _uniformStaging[1] = viewportHeight.toDouble();
    // Ordered against the submit at the end of this frame's `submit` call:
    // writeBuffer executes in queue order before the command buffer, so every
    // pass reads the slice written for it.
    _gpuDevice.queue.writeBuffer(_uniformBuffer!, offset, _uniformStaging.toJS);

    final ({double r, double g, double b, double a})? clearValue =
        clear == null ? null : webGpuClearValue(clear);
    final GPURenderPassEncoder pass =
        encoder.beginRenderPass(GPURenderPassDescriptor(
      colorAttachments: <GPURenderPassColorAttachment>[
        clearValue == null
            ? GPURenderPassColorAttachment(
                view: view,
                loadOp: 'load',
                storeOp: 'store',
              )
            : GPURenderPassColorAttachment(
                view: view,
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
      ..setBindGroup(0, _frameBindGroup!, <JSNumber>[offset.toJS].toJS)
      ..setVertexBuffer(0, _vertexBuffer!)
      ..setIndexBuffer(_indexBuffer!, 'uint32');
    // The pass starts with no pipeline and no texture group bound, whatever
    // the previous pass set. See _PassState.
    _passState.reset();
    return pass;
  }

  void _drawBatches(
    GPURenderPassEncoder pass,
    GpuBatcher batcher,
    int first,
    int last,
    int viewportWidth,
    int viewportHeight,
    _PassState state,
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

      // Framebuffer coordinates share device space's top-left origin, so the
      // y-flip GL's scissor needs does not exist here - in either pass
      // orientation, because there is only one orientation. See
      // `wgsl_shaders.dart`.
      pass.setScissorRect(left, top, right - left, bottom - top);

      final int pipelineKey = _pipelineKey(batch.pipeline, batch.blendMode);
      if (pipelineKey != state.pipelineKey) {
        state.pipelineKey = pipelineKey;
        pass.setPipeline(_pipelineFor(batch.pipeline, batch.blendMode));
      }
      if (batch.textureId != state.textureId) {
        state.textureId = batch.textureId;
        // The one lookup a browser costs that a native backend does not, per
        // batch as always. kNoTexture binds the dummy group: the solid entry
        // point samples nothing, but the pipeline layout still names group 1
        // and WebGPU validates what is bound, not what is read.
        pass.setBindGroup(1, _bindGroupFor(batch.textureId));
      }
      pass.drawIndexed(batch.indexCount, 1, batch.indexOffset);
    }
  }

  void _uploadGeometry(GpuBatcher batcher) {
    final GpuVertexBuffer buffer = batcher.buffer;
    final int floatCount = buffer.vertexCount * kGpuFloatsPerVertex;
    final Float32List vertexStaging = _ensureVertexStaging(floatCount);
    vertexStaging.setRange(0, floatCount, buffer.vertexStorage);
    _ensureVertexBufferCapacity(floatCount * 4);
    _gpuDevice.queue.writeBuffer(
      _vertexBuffer!,
      0,
      Float32List.sublistView(vertexStaging, 0, floatCount).toJS,
    );

    final int indexCount = buffer.indexCount;
    final Uint32List indexStaging = _ensureIndexStaging(indexCount);
    indexStaging.setRange(0, indexCount, buffer.indexStorage);
    _ensureIndexBufferCapacity(indexCount * 4);
    _gpuDevice.queue.writeBuffer(
      _indexBuffer!,
      0,
      Uint32List.sublistView(indexStaging, 0, indexCount).toJS,
    );
  }

  // -------------------------------------------------------------------
  // Pipelines and bind groups
  // -------------------------------------------------------------------

  static int _pipelineKey(GpuPipelineKind kind, int blendMode) =>
      (kind.index << 8) | blendMode;

  GPURenderPipeline _pipelineFor(GpuPipelineKind kind, int blendMode) {
    final int key = _pipelineKey(kind, blendMode);
    final GPURenderPipeline? cached = _pipelines[key];
    if (cached != null) return cached;

    final GpuBlendState blend = gpuBlendForMode(blendMode);
    final GPUBlendComponent component = GPUBlendComponent(
      srcFactor: webGpuBlendFactorName(blend.source),
      dstFactor: webGpuBlendFactorName(blend.destination),
      operation: 'add',
    );
    final GPURenderPipeline pipeline =
        _gpuDevice.createRenderPipeline(GPURenderPipelineDescriptor(
      layout: _pipelineLayout!,
      vertex: GPUVertexState(
        module: _module!,
        entryPoint: kWgslVertexEntryPoint,
        buffers: <GPUVertexBufferLayout>[
          GPUVertexBufferLayout(
            arrayStride: kWebGpuVertexStrideBytes,
            attributes: <GPUVertexAttribute>[
              GPUVertexAttribute(
                format: 'float32x2',
                offset: kWebGpuPositionOffsetBytes,
                shaderLocation: 0,
              ),
              GPUVertexAttribute(
                format: 'float32x2',
                offset: kWebGpuTexCoordOffsetBytes,
                shaderLocation: 1,
              ),
              GPUVertexAttribute(
                format: 'float32x4',
                offset: kWebGpuColorOffsetBytes,
                shaderLocation: 2,
              ),
              GPUVertexAttribute(
                format: 'float32x4',
                offset: kWebGpuShapeRectOffsetBytes,
                shaderLocation: 3,
              ),
            ].toJS,
          ),
        ].toJS,
      ),
      fragment: GPUFragmentState(
        module: _module!,
        entryPoint: wgslFragmentEntryPoint(kind),
        targets: <GPUColorTargetState>[
          GPUColorTargetState(
            format: _surfaceFormat,
            // The same factors for colour and alpha, which is what
            // premultiplied compositing means and what glBlendFunc - as
            // opposed to glBlendFuncSeparate - has been saying all along.
            blend: GPUBlendStateDict(color: component, alpha: component),
          ),
        ].toJS,
      ),
      primitive: GPUPrimitiveState(topology: 'triangle-list'),
    ));
    _pipelines[key] = pipeline;
    return pipeline;
  }

  GPUBindGroup _bindGroupFor(int textureId) {
    if (textureId == kNoTexture) return _dummyBindGroup!;
    final GPUBindGroup? cached = _textureBindGroups[textureId];
    if (cached != null) return cached;
    final WebGpuSampledTexture? sampled = sampledTextures.lookup(textureId);
    if (sampled == null) {
      // A batch recorded against a texture that was released mid-frame is a
      // caller bug on every backend; drawing the dummy is the closest thing
      // to WebGL's "binds null, draws nothing" rather than a validation error
      // that kills the whole pass.
      return _dummyBindGroup!;
    }
    final GPUBindGroup group = _gpuDevice.createBindGroup(GPUBindGroupDescriptor(
      layout: _textureLayout!,
      entries: <GPUBindGroupEntry>[
        GPUBindGroupEntry(
          binding: 0,
          resource: sampled.filter == GpuTextureFilter.linear
              ? _linearSampler!
              : _nearestSampler!,
        ),
        GPUBindGroupEntry(binding: 1, resource: sampled.view),
      ].toJS,
    ));
    _textureBindGroups[textureId] = group;
    return group;
  }

  // -------------------------------------------------------------------
  // Setup and teardown
  // -------------------------------------------------------------------

  /// Creates the module, the layouts, the samplers, the dummy texture and the
  /// initial buffers.
  ///
  /// Returns a diagnostic on failure instead of throwing, so device creation
  /// reports the same way a probe does. Failures here are synchronous
  /// JavaScript errors only - WebGPU's own validation arrives later, on the
  /// `uncapturederror` channel [_watchDevice] subscribes to.
  BackendDiagnostic? _initialise() {
    try {
      final GPUDevice device = _gpuDevice;
      _module = device.createShaderModule(
        GPUShaderModuleDescriptor(code: kWgslShaderModuleSource),
      );
      _frameLayout = device.createBindGroupLayout(GPUBindGroupLayoutDescriptor(
        entries: <GPUBindGroupLayoutEntry>[
          GPUBindGroupLayoutEntry(
            binding: 0,
            visibility: web.$GPUShaderStage.VERTEX,
            buffer: GPUBufferBindingLayout(
              type: 'uniform',
              hasDynamicOffset: true,
              minBindingSize: kWebGpuUniformSliceSize,
            ),
          ),
        ].toJS,
      ));
      _textureLayout =
          device.createBindGroupLayout(GPUBindGroupLayoutDescriptor(
        entries: <GPUBindGroupLayoutEntry>[
          GPUBindGroupLayoutEntry(
            binding: 0,
            visibility: web.$GPUShaderStage.FRAGMENT,
            sampler: GPUSamplerBindingLayout(type: 'filtering'),
          ),
          GPUBindGroupLayoutEntry(
            binding: 1,
            visibility: web.$GPUShaderStage.FRAGMENT,
            texture: GPUTextureBindingLayout(sampleType: 'float'),
          ),
        ].toJS,
      ));
      _pipelineLayout = device.createPipelineLayout(GPUPipelineLayoutDescriptor(
        bindGroupLayouts:
            <GPUBindGroupLayout>[_frameLayout!, _textureLayout!].toJS,
      ));

      _nearestSampler = device.createSampler(GPUSamplerDescriptor(
        magFilter: 'nearest',
        minFilter: 'nearest',
        addressModeU: 'clamp-to-edge',
        addressModeV: 'clamp-to-edge',
      ));
      _linearSampler = device.createSampler(GPUSamplerDescriptor(
        magFilter: 'linear',
        minFilter: 'linear',
        // Clamped for the layer pool's reason in webgl_framebuffer_pool.dart:
        // a wrapped tap at u == 1 pulls in the opposite edge of the texture.
        addressModeU: 'clamp-to-edge',
        addressModeV: 'clamp-to-edge',
      ));

      // The stand-in for "no texture". Solid batches never read it - the
      // solid entry point samples nothing - but the pipeline layout names
      // group 1 for every pipeline, and WebGPU validates the binding's
      // existence regardless. 1x1 white, so that if a bug ever *does* route a
      // textured batch here it shows as unmodulated colour, not as black.
      final GPUTexture dummy = device.createTexture(GPUTextureDescriptor(
        size: GPUExtent3DDict(width: 1, height: 1),
        format: 'rgba8unorm',
        usage: web.$GPUTextureUsage.TEXTURE_BINDING |
            web.$GPUTextureUsage.COPY_DST,
      ));
      device.queue.writeTexture(
        GPUTexelCopyTextureInfo(
          texture: dummy,
          origin: GPUOrigin3DDict(x: 0, y: 0),
        ),
        Uint8List.fromList(const <int>[0xFF, 0xFF, 0xFF, 0xFF]).toJS,
        GPUTexelCopyBufferLayout(offset: 0, bytesPerRow: 4, rowsPerImage: 1),
        GPUExtent3DDict(width: 1, height: 1),
      );
      _dummyTexture = dummy;
      _dummyBindGroup = device.createBindGroup(GPUBindGroupDescriptor(
        layout: _textureLayout!,
        entries: <GPUBindGroupEntry>[
          GPUBindGroupEntry(binding: 0, resource: _nearestSampler!),
          GPUBindGroupEntry(binding: 1, resource: dummy.createView()),
        ].toJS,
      ));

      _uniformCapacitySlices = 0;
      _ensureUniformCapacity(8);
      _ensureVertexBufferCapacity(64 * 1024);
      _ensureIndexBufferCapacity(16 * 1024);
      _pipelines.clear();
      _textureBindGroups.clear();
    } on Object catch (error) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'WebGPU refused the renderer objects',
        detail: '$error',
      );
    }
    return null;
  }

  void _ensureUniformCapacity(int slices) {
    if (slices <= _uniformCapacitySlices) return;
    var capacity = _uniformCapacitySlices == 0 ? 8 : _uniformCapacitySlices;
    while (capacity < slices) {
      capacity *= 2;
    }
    _uniformBuffer?.destroy();
    _uniformBuffer = _gpuDevice.createBuffer(GPUBufferDescriptor(
      size: capacity * kWebGpuUniformSliceStride,
      usage: web.$GPUBufferUsage.UNIFORM | web.$GPUBufferUsage.COPY_DST,
    ));
    _uniformCapacitySlices = capacity;
    // The frame bind group references the buffer, so it goes with it. Group 1
    // never does - that is the whole reason the groups are split - so the
    // texture bind-group cache survives.
    _frameBindGroup = _gpuDevice.createBindGroup(GPUBindGroupDescriptor(
      layout: _frameLayout!,
      entries: <GPUBindGroupEntry>[
        GPUBindGroupEntry(
          binding: 0,
          resource: GPUBufferBinding(
            buffer: _uniformBuffer!,
            offset: 0,
            size: kWebGpuUniformSliceSize,
          ),
        ),
      ].toJS,
    ));
  }

  void _ensureVertexBufferCapacity(int bytes) {
    final GPUBuffer? current = _vertexBuffer;
    if (current != null && current.size >= bytes) return;
    current?.destroy();
    var capacity = current == null ? 64 * 1024 : current.size;
    while (capacity < bytes) {
      capacity *= 2;
    }
    _vertexBuffer = _gpuDevice.createBuffer(GPUBufferDescriptor(
      size: capacity,
      usage: web.$GPUBufferUsage.VERTEX | web.$GPUBufferUsage.COPY_DST,
    ));
  }

  void _ensureIndexBufferCapacity(int bytes) {
    final GPUBuffer? current = _indexBuffer;
    if (current != null && current.size >= bytes) return;
    current?.destroy();
    var capacity = current == null ? 16 * 1024 : current.size;
    while (capacity < bytes) {
      capacity *= 2;
    }
    _indexBuffer = _gpuDevice.createBuffer(GPUBufferDescriptor(
      size: capacity,
      usage: web.$GPUBufferUsage.INDEX | web.$GPUBufferUsage.COPY_DST,
    ));
  }

  /// Whether the device is still usable, per this device's own state.
  ///
  /// The replacement for `checkContextAlive`, and thinner by necessity:
  /// WebGPU has no synchronous liveness query, so the answer is whatever the
  /// `lost` promise and the error channel have reported so far. A device that
  /// died a microtask ago still answers true here and the draws land in a
  /// void - harmlessly, because every WebGPU call on a lost device is a
  /// defined no-op - and the *next* frame is refused, which is the same
  /// one-frame window every asynchronous loss signal has.
  bool checkDeviceAlive() => !_state.isLost;

  /// The last error WebGPU reported that did not kill the device, or null.
  BackendDiagnostic? get lastError => _lastError;
  BackendDiagnostic? _lastError;

  late final JSFunction _uncapturedErrorListener = ((JSObject event) {
    _handleUncapturedError(event as GPUUncapturedErrorEvent);
  }).toJS;

  void _watchDevice(GPUDevice device) {
    device.addEventListener('uncapturederror', _uncapturedErrorListener);
    unawaited(device.lost.toDart.then((GPUDeviceLostInfo info) {
      if (isDisposed) return;
      // A replaced device's loss is history, not news: the recovery already
      // built on a successor and marking the state lost again would kill it.
      if (device != _gpuDevice) return;
      // 'destroyed' is this backend's own destroy() on dispose, which is
      // teardown, not loss.
      if (info.reason == 'destroyed') return;
      _state.markLost(BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'the GPUDevice was lost',
        detail: 'reason: ${info.reason}; ${info.message}. A browser drops a '
            'device when the GPU process restarts or the adapter goes away; '
            'a lost GPUDevice never comes back, and the owner recovers by '
            'requesting a new one and staging it with '
            'stageReplacementDevice',
      ));
    }));
  }

  void _detachDeviceListeners(GPUDevice device) {
    try {
      device.removeEventListener('uncapturederror', _uncapturedErrorListener);
    } on Object {
      // A dead device that refuses the removal changes nothing: the listener
      // guards on identity and ignores stale sources.
    }
  }

  /// Folds an `uncapturederror` into the same two-tier scheme WebGL's error
  /// queue uses: out-of-memory kills the device, everything else is recorded
  /// and survives. A validation error here is a bug in this backend - the
  /// call was already issued - and turning one bad descriptor into a device
  /// that can never draw again would be a worse failure than the bug it
  /// reports.
  void _handleUncapturedError(GPUUncapturedErrorEvent event) {
    if (isDisposed) return;
    String message;
    var fatal = false;
    try {
      final GPUError error = event.error;
      fatal = (error as JSObject).instanceOfString('GPUOutOfMemoryError');
      message = error.message;
    } on Object catch (error) {
      message = '$error';
    }
    final BackendDiagnostic diagnostic = BackendDiagnostic(
      kind: fatal
          ? DiagnosticKind.connectionFailed
          : DiagnosticKind.incompatibleDevice,
      message: fatal
          ? 'the browser ran out of GPU memory'
          : 'WebGPU reported a validation error',
      detail: message,
    );
    _lastError = diagnostic;
    if (fatal) _state.markLost(diagnostic);
  }

  Float32List _ensureVertexStaging(int floats) {
    if (floats <= _vertexStaging.length) return _vertexStaging;
    return _vertexStaging = Float32List(floats * 2);
  }

  Uint32List _ensureIndexStaging(int indices) {
    if (indices <= _indexStaging.length) return _indexStaging;
    return _indexStaging = Uint32List(indices * 2);
  }

  Uint8List _ensurePixelStaging(int bytes) {
    if (bytes <= _pixelStaging.length) return _pixelStaging;
    return _pixelStaging = Uint8List(bytes);
  }

  static int _readMaxTextureSize(GPUDevice device) {
    try {
      final int size = device.limits.maxTextureDimension2D;
      // 2048 is a floor, not a plausible answer - the specification's own
      // default is 8192 - so anything smaller means the read went wrong and
      // the conservative fallback below is the honest number to build on.
      return size >= 2048 ? size : 2048;
    } on Object {
      return 2048;
    }
  }

  @override
  void onDispose() {
    _detachDeviceListeners(_gpuDevice);
    _uniformBuffer?.destroy();
    _vertexBuffer?.destroy();
    _indexBuffer?.destroy();
    _dummyTexture?.destroy();
    _uniformBuffer = null;
    _vertexBuffer = null;
    _indexBuffer = null;
    _dummyTexture = null;
    _dummyBindGroup = null;
    _frameBindGroup = null;
    _pipelines.clear();
    _textureBindGroups.clear();
    sampledTextures.clear();
    // Owned, not borrowed - see adoptDevice. destroy() frees every remaining
    // driver object deterministically and resolves `lost` with reason
    // 'destroyed', which _watchDevice ignores on purpose.
    _gpuDevice.destroy();
  }
}

/// Where a `saveLayer` gets its offscreen surface on WebGPU.
///
/// The port of `WebGlFramebufferPool`, with the framebuffer half gone: WebGPU
/// has no framebuffer object, a render pass attaches a texture view directly,
/// so a pooled target is one texture wearing two identities - a view the pass
/// renders into, and an entry in the device's sampled-texture table so the
/// composite quad can name it by integer like everything else. The size
/// bucketing, the idle bound and the reuse accounting are the WebGL pool's,
/// argued there.
final class WebGpuLayerTargetPool implements GpuLayerTargetAllocator {
  WebGpuLayerTargetPool({
    required WebGpuRenderDevice device,
    this.maxIdlePerBucket = 4,
  }) : _device = device;

  final WebGpuRenderDevice _device;

  /// The WebGL pool's bound, for the WebGL pool's reason: a frame that opened
  /// forty layers of one size must not leave forty full-size textures
  /// resident for the rest of the session.
  final int maxIdlePerBucket;

  final Map<int, List<WebGpuLayerTarget>> _idle =
      <int, List<WebGpuLayerTarget>>{};
  final Set<WebGpuLayerTarget> _live = <WebGpuLayerTarget>{};
  final WebGlObjectTable<GPUTextureView> _attachments =
      WebGlObjectTable<GPUTextureView>();

  int _createdCount = 0;
  int _reuseCount = 0;

  /// Textures this pool has asked the driver for, ever. The number the
  /// pooling claim rests on.
  int get createdCount => _createdCount;

  int get reuseCount => _reuseCount;

  int get liveCount => _live.length;

  int get idleCount => _idle.values
      .fold(0, (int sum, List<WebGpuLayerTarget> l) => sum + l.length);

  static int _key(int width, int height) => (width << 16) | height;

  /// Rounds up to the next power of two, with a floor of 16 - the same
  /// buckets as [webGlLayerBucket], restated here only because importing a
  /// function named `webGl...` into call sites that read `webGpu...` invites
  /// exactly the confusion a shared helper is meant to prevent.
  static int bucket(int extent) {
    if (extent <= 16) return 16;
    var size = 16;
    while (size < extent) {
      size <<= 1;
    }
    return size;
  }

  @override
  GpuLayerTarget acquireLayerTarget(int width, int height) {
    final int bucketWidth = bucket(width);
    final int bucketHeight = bucket(height);
    final int key = _key(bucketWidth, bucketHeight);
    final List<WebGpuLayerTarget>? free = _idle[key];
    if (free != null && free.isNotEmpty) {
      final WebGpuLayerTarget target = free.removeLast();
      _live.add(target);
      _reuseCount++;
      return target;
    }
    final WebGpuLayerTarget created = _create(bucketWidth, bucketHeight);
    _live.add(created);
    return created;
  }

  @override
  void releaseLayerTarget(GpuLayerTarget target) {
    if (target is! WebGpuLayerTarget) return;
    if (!_live.remove(target)) return;
    final int key = _key(target.width, target.height);
    final List<WebGpuLayerTarget> free =
        _idle.putIfAbsent(key, () => <WebGpuLayerTarget>[]);
    if (free.length >= maxIdlePerBucket) {
      _destroy(target);
      return;
    }
    free.add(target);
  }

  WebGpuLayerTarget _create(int width, int height) {
    _createdCount++;
    final GPUTexture texture;
    final GPUTextureView view;
    try {
      // The surface format, not rgba8unorm by habit: pipelines bake their
      // target format in, and a layer pass runs the same pipelines as the
      // canvas pass. A pool that allocated a different format would need a
      // second pipeline cache to draw into it.
      texture = _device.gpuDevice.createTexture(GPUTextureDescriptor(
        size: GPUExtent3DDict(width: width, height: height),
        format: _device.surfaceFormat,
        usage: web.$GPUTextureUsage.RENDER_ATTACHMENT |
            web.$GPUTextureUsage.TEXTURE_BINDING,
      ));
      view = texture.createView();
    } on Object catch (error) {
      _device.state.markLost(BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'WebGPU refused a layer target',
        detail: 'createTexture threw for a ${width}x$height layer: $error',
      ));
      // The unbacked target `webgl_framebuffer_pool.dart` documents:
      // GpuLayerStack.push is mid-walk and cannot take a null, and the
      // diagnostic above already stopped anything being drawn into this.
      return WebGpuLayerTarget._(
        id: 0,
        textureId: 0,
        width: width,
        height: height,
        texture: null,
        view: null,
      );
    }
    return WebGpuLayerTarget._(
      id: _attachments.register(view),
      // Linear, like every composite source: a layer is drawn back at the
      // scale the scene produced.
      textureId: _device.registerSampledView(view, GpuTextureFilter.linear),
      width: width,
      height: height,
      texture: texture,
      view: view,
    );
  }

  /// The attachment view [id] names, for the submit loop.
  GPUTextureView? viewFor(int id) => _attachments.lookup(id);

  void _destroy(WebGpuLayerTarget target) {
    _attachments.release(target.id);
    _device.releaseSampledView(target.textureId);
    target.texture?.destroy();
  }

  /// Forgets every object without touching the device - the lost-device path,
  /// where the id tables must still be emptied or the next pool would hand
  /// out ids resolving to dead views.
  void forget() {
    _attachments.clear();
    for (final WebGpuLayerTarget target in _live) {
      _device.releaseSampledView(target.textureId);
    }
    for (final List<WebGpuLayerTarget> free in _idle.values) {
      for (final WebGpuLayerTarget target in free) {
        _device.releaseSampledView(target.textureId);
      }
    }
    _live.clear();
    _idle.clear();
  }

  /// Destroys every idle target. Live ones are left alone, for the WebGL
  /// pool's reason: a pool disposed mid-frame would destroy textures a pass
  /// is still writing to.
  void dispose() {
    for (final List<WebGpuLayerTarget> free in _idle.values) {
      for (final WebGpuLayerTarget target in free) {
        _destroy(target);
      }
    }
    _idle.clear();
  }
}

/// One pooled render-to-texture surface.
final class WebGpuLayerTarget implements GpuLayerTarget {
  WebGpuLayerTarget._({
    required this.id,
    required this.textureId,
    required this.width,
    required this.height,
    required this.texture,
    required this.view,
  });

  @override
  final int id;

  @override
  final int textureId;

  @override
  final int width;

  @override
  final int height;

  /// Null when the device refused the texture; see the unbacked-target note
  /// in [WebGpuLayerTargetPool._create].
  final GPUTexture? texture;
  final GPUTextureView? view;

  bool get isBacked => texture != null && view != null;

  @override
  String toString() => 'WebGpuLayerTarget(#$id, texture #$textureId, '
      '${width}x$height${isBacked ? '' : ', unbacked'})';
}

/// Turns the display list's interned font ids into faces for the sink.
///
/// Identical to `WebGlFontResolver`, which is itself identical to
/// `GlFontResolver`, and the identity is the point - see the latter for why
/// the sink must resolve through the same table the player walks.
final class WebGpuFontResolver implements GpuFontResolver {
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
final class _WebGpuImageEntry {
  _WebGpuImageEntry({
    required this.index,
    required this.image,
    required this.width,
    required this.height,
    required this.texture,
    required this.source,
  });

  final WeakReference<Framebuffer> image;
  final int index;
  final int width;
  final int height;
  WebGpuTexture? texture;
  Framebuffer? source;

  bool get isRecoverable => source != null;

  String get name => 'webgpu image #$index (${width}x$height)';
}

/// Uploads drawn images into textures, once each, and can do it again.
///
/// The port of `WebGlImageCache`, two-part design included: the lookup is a
/// weak [Expando] and the retention is a field on the entry, because a `Map`
/// key would make "drop the bytes to save memory" inexpressible.
final class WebGpuImageCache implements GpuImageResolver {
  WebGpuImageCache(
    this._device, {
    this.retention = GpuImageSourceRetention.retain,
  });

  final WebGpuRenderDevice _device;

  final GpuImageSourceRetention retention;

  final Expando<_WebGpuImageEntry> _byImage = Expando<_WebGpuImageEntry>();
  final List<_WebGpuImageEntry> _entries = <_WebGpuImageEntry>[];

  int get length => _entries.length;

  /// How many bytes of image source this cache is keeping alive. Zero under
  /// [GpuImageSourceRetention.uploadOnly].
  int get retainedSourceBytes {
    var bytes = 0;
    for (final _WebGpuImageEntry entry in _entries) {
      if (entry.source != null) bytes += entry.width * entry.height * 4;
    }
    return bytes;
  }

  /// Entries whose source is gone, so a device loss would strand them.
  int get unrecoverableCount =>
      _entries.where((_WebGpuImageEntry e) => !e.isRecoverable).length;

  @override
  GpuTextureHandle? resolve(Object image) {
    if (image is! Framebuffer) return null;
    final _WebGpuImageEntry? cached = _byImage[image];
    if (cached != null) {
      final WebGpuTexture? texture = cached.texture;
      if (texture != null && texture.isValid) return texture;
      if (!cached.isRecoverable) {
        // The honest refusal: the texture died with the device and the bytes
        // that made it are gone. Null is the sink's "this device cannot draw
        // it", which becomes a named error.
        return null;
      }
    }

    final WebGpuTexture? texture = _upload(image);
    if (texture == null) return null;
    if (cached != null) {
      cached.texture = texture;
      return texture;
    }
    final _WebGpuImageEntry entry = _WebGpuImageEntry(
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

  WebGpuTexture? _upload(Framebuffer image) {
    final WebGpuTexture texture;
    try {
      texture = _device.createTexture(
        width: image.width,
        height: image.height,
        format: GpuTextureFormat.rgba8888Premultiplied,
        // Linear, unlike the atlases, for WebGlImageCache's reason: an image
        // is drawn at whatever scale the layout produced.
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

  /// Forgets the bytes of [image] while keeping its texture. After this call
  /// a device loss strands it: there is no second copy of the pixels.
  bool dropSource(Object image) {
    if (image is! Framebuffer) return false;
    final _WebGpuImageEntry? entry = _byImage[image];
    if (entry == null) return false;
    entry.source = null;
    return true;
  }

  /// This cache's contribution to step 5's inventory: one resource per image,
  /// because the answer differs per image.
  Iterable<GpuRecoverableResource> recoverableResources() sync* {
    for (final _WebGpuImageEntry entry in List<_WebGpuImageEntry>.of(_entries)) {
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
          final WebGpuTexture? texture = _upload(source);
          if (texture == null) {
            return BackendDiagnostic(
              kind: DiagnosticKind.incompatibleDevice,
              message: '${entry.name} could not be re-uploaded',
              detail: 'the recovered device refused a '
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
    for (final _WebGpuImageEntry entry in _entries) {
      final WebGpuTexture? texture = entry.texture;
      if (texture != null) _device.releaseTexture(texture);
      entry.texture = null;
      entry.source = null;
      final Framebuffer? image = entry.image.target;
      if (image != null) _byImage[image] = null;
    }
    _entries.clear();
  }

  /// The image's bytes in RGBA order, rows repacked - the same conversion,
  /// for the same two reasons, as `WebGlImageCache._asRgba`.
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

/// A human description of [adapter], for [RendererInfo] and logs.
///
/// `adapter.info` is the WebGPU equivalent of `WEBGL_debug_renderer_info` -
/// the line that makes a bug report actionable - and like that extension it
/// is legitimately absent: older browsers predate it and privacy modes mask
/// it. Absence falls back to a generic string rather than being reported as a
/// fault.
String describeWebGpuAdapter(GPUAdapter? adapter) {
  if (adapter == null) return 'WebGPU, adapter not reported';
  try {
    final GPUAdapterInfo? info = adapter.info;
    if (info == null) return 'WebGPU, adapter not described';
    final List<String> parts = <String>[
      if (info.vendor.isNotEmpty) info.vendor,
      if (info.architecture.isNotEmpty) info.architecture,
      if (info.device.isNotEmpty) info.device,
      if (info.description.isNotEmpty) info.description,
    ];
    return parts.isEmpty ? 'WebGPU, adapter not described' : parts.join(', ');
  } on Object {
    return 'WebGPU, adapter not described';
  }
}

/// The WebGPU renderer backend.
///
/// ## The probe is synchronous and the API is not, and how that is squared
///
/// [RendererBackend.probe] answers synchronously on every backend, and the
/// selection machinery is built on that. The only synchronous fact WebGPU
/// offers is whether `navigator.gpu` exists - the adapter behind it answers
/// by promise. So [probe] reports exactly that fact, names the limitation in
/// its own diagnostic, and the *attach* path asks the asynchronous questions:
/// `WebGpuCanvasPresenter.attach` awaits `requestAdapter` and `requestDevice`,
/// and throws a [BackendSelectionError] naming what refused, which is the
/// shape the selection loop above turns into "try the next entry" - the
/// WebGL2 fallback, with the refusal on the record. A `navigator.gpu` that
/// exists but yields no adapter (a blocklisted GPU, a policy flag) therefore
/// costs one failed attach and lands on WebGL2, reported, which is the
/// automatic-fallback contract.
final class WebGpuRendererBackend implements RendererBackend {
  const WebGpuRendererBackend();

  static const String backendName = 'webgpu';

  @override
  RendererInfo get info => const RendererInfo(
        name: backendName,
        deviceDescription: 'WebGPU on an HTML canvas',
        rasterizationApproach: RasterizationApproach.analyticCoverageAtlas,
      );

  /// Only the canvas descriptor: this backend has no offscreen readback
  /// target - see the library comment - so claiming [MemorySurfaceDescriptor]
  /// here would promise a target [WebGpuRenderDevice.createTarget] refuses.
  @override
  bool supportsSurface(NativeSurfaceDescriptor surface) =>
      surface is WebGpuCanvasSurfaceDescriptor;

  /// Whether WebGPU can exist here, to the extent a synchronous question can
  /// tell. Never throws, per section 6.6.
  @override
  BackendProbeResult probe() {
    try {
      final GPU? gpu = navigatorGpu();
      if (gpu == null) {
        return BackendProbeResult.unsupported(
          backendName,
          const BackendDiagnostic(
            kind: DiagnosticKind.unsupportedPlatform,
            message: 'this browser has no navigator.gpu',
            detail: 'WebGPU is absent, disabled by policy, or this is not a '
                'browser at all. The webgl2 entry behind this one is the '
                'fallback, and the selection report will show both',
          ),
        );
      }
      return BackendProbeResult(
        backendName: backendName,
        supported: true,
        capabilities: const <Capability>{Capability.gpuPresentation},
        diagnostics: <BackendDiagnostic>[
          const BackendDiagnostic.note(
            'navigator.gpu is present',
            detail: 'presence is all a synchronous probe can check: the '
                'adapter answers by promise. attach() requests it, and a '
                'refusal there falls back to the next presentation path '
                'with the refusal named',
          ),
        ],
      );
    } on Object catch (error, stack) {
      return BackendProbeResult.unsupported(
        backendName,
        BackendDiagnostic(
          kind: DiagnosticKind.unsupportedPlatform,
          message: 'the WebGPU probe threw, which is a bug in the probe',
          detail: '$error\n$stack',
        ),
      );
    }
  }

  /// Asks the browser for an adapter and a device, naming every refusal.
  ///
  /// The asynchronous half of the probe - see the class comment - shared by
  /// `WebGpuCanvasPresenter.attach`, by [createDevice] and by the recovery
  /// path, so the three cannot drift in how they interpret a refusal. Never
  /// throws.
  static Future<
      ({
        GPU? gpu,
        GPUAdapter? adapter,
        GPUDevice? device,
        BackendDiagnostic? failure,
      })> requestDevice() async {
    final GPU? gpu = navigatorGpu();
    if (gpu == null) {
      return (
        gpu: null,
        adapter: null,
        device: null,
        failure: const BackendDiagnostic(
          kind: DiagnosticKind.unsupportedPlatform,
          message: 'this browser has no navigator.gpu',
        ),
      );
    }
    GPUAdapter? adapter;
    try {
      adapter = await gpu.requestAdapter().toDart;
    } on Object catch (error) {
      return (
        gpu: gpu,
        adapter: null,
        device: null,
        failure: BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'requestAdapter rejected',
          detail: '$error',
        ),
      );
    }
    if (adapter == null) {
      return (
        gpu: gpu,
        adapter: null,
        device: null,
        failure: const BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'requestAdapter resolved null',
          detail: 'navigator.gpu exists but no adapter answered - a '
              'blocklisted GPU, a software-only machine, or WebGPU behind a '
              'flag. This is the case the WebGL2 fallback exists for',
        ),
      );
    }
    try {
      final GPUDevice device = await adapter.requestDevice().toDart;
      return (gpu: gpu, adapter: adapter, device: device, failure: null);
    } on Object catch (error) {
      return (
        gpu: gpu,
        adapter: adapter,
        device: null,
        failure: BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'requestDevice rejected',
          detail: '$error',
        ),
      );
    }
  }

  /// Opens a device with no canvas behind it.
  ///
  /// Useful to a test that exercises textures and uploads; a device for a
  /// canvas on the page is built by `WebGpuCanvasTarget.open`, which pairs it
  /// with that canvas's context.
  @override
  Future<RenderDevice> createDevice() async {
    final ({
      GPU? gpu,
      GPUAdapter? adapter,
      GPUDevice? device,
      BackendDiagnostic? failure,
    }) answer = await requestDevice();
    final GPUDevice? gpuDevice = answer.device;
    if (gpuDevice == null || answer.gpu == null) {
      throw UnsupportedCapabilityError(
        backendName: backendName,
        capability: Capability.gpuPresentation,
        detail: 'this browser did not answer a WebGPU device: '
            '${answer.failure}',
      );
    }
    final ({WebGpuRenderDevice? device, BackendDiagnostic? failure}) opened =
        WebGpuRenderDevice.adoptDevice(
      gpuDevice,
      surfaceFormat: answer.gpu!.getPreferredCanvasFormat(),
      deviceDescription: describeWebGpuAdapter(answer.adapter),
    );
    final WebGpuRenderDevice? device = opened.device;
    if (device == null) {
      throw UnsupportedCapabilityError(
        backendName: backendName,
        capability: Capability.gpuPresentation,
        detail: 'WebGPU refused the renderer objects: ${opened.failure}',
      );
    }
    return device;
  }
}
