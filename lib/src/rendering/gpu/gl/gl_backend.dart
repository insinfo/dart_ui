/// The OpenGL backend: the first concrete filling of the GPU abstraction.
///
/// OpenGL rather than Vulkan, Metal or D3D for one reason that outranks every
/// technical comparison: `poc/poc_06_opengl` already proves the FFI binding
/// loads and answers on Linux under software Mesa in this repository's CI. A
/// backend that can be *run* in CI is worth more than a faster one that can
/// only be reasoned about, because the whole point of this stage is to find
/// out whether the abstraction above it is right.
///
/// ## Two targets, and only one of them reads pixels back
///
/// [GlOffscreenTarget] renders into a framebuffer object, not a window. That
/// makes the GPU path testable with no display server, no compositor and no
/// window manager - the same property that makes the CPU renderer testable -
/// and it is the configuration a golden test needs.
///
/// It reads its pixels back on present, which section 23 of the roadmap
/// forbids for a *production* GPU backend ("backend GPU não deve fazer
/// readback por frame"). That rule is about presenting to a screen. An
/// offscreen target whose only consumer is a test or an image export has
/// nowhere else to put the pixels, and the rule does not apply to it.
///
/// `GlWindowTarget`, in `gl_window_target.dart`, is the target the rule *is*
/// about. It binds framebuffer 0 - the window's own back buffer - draws into
/// it and swaps. It does not read pixels back, and `_readPixels` is
/// deliberately left private to this file so it cannot.
///
/// ## Why the window target is a separate library and not a `part`
///
/// It needs [submit], [makeCurrentOrLose], [checkError] and [scratchNames],
/// all of which were private to this file. Two ways to give it them:
///
///   1. `part` / `part of`, which would put both classes in one library and
///      keep every one of those members private.
///   2. Promote the four members to public API of [GlRenderDevice].
///
/// This file chose **(2)**, for two reasons and one that decided it.
///
/// The reason that decided it: `part` is not an idiom this repository uses.
/// There is not one `part` or `part of` directive anywhere under `lib/`, and
/// introducing the first one inside the GPU backend would make this directory
/// read differently from the other forty. A layering rule that is enforced by
/// a test (`test/architecture/layering_test.dart`) and a file convention that
/// is enforced by nothing are both conventions; breaking the second one for
/// local convenience is how the first one eventually gets broken too.
///
/// The two supporting reasons. First, `part` files cannot have their own
/// imports, so `gl_window_target.dart` would have to import through this file
/// and the dependency of the window target on `gl_surface_descriptor.dart`
/// would become invisible at its top. Second, these four members are not
/// accidental internals: a target *is* the thing that submits geometry and
/// makes a context current, so "the device's API to its targets" is a real
/// interface that deserves a name and a doc comment rather than a language
/// loophole. Each of them below says so explicitly and says what a caller must
/// not assume.
///
/// The cost is stated rather than glossed: these members are now reachable by
/// anything that imports this file, including application code that has no
/// business calling them. They are documented as device-to-target plumbing and
/// nothing outside `lib/src/rendering/gpu/gl` calls them.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

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
import '../gpu_gradient.dart';
import '../gpu_layer_stack.dart';
import '../gpu_mask_atlas.dart';
import '../gpu_path_repetition.dart';
import '../gpu_path_strategy.dart';
import '../gpu_pipeline.dart';
import '../gpu_raster_sink.dart';
import '../gpu_recovery.dart';
import '../gpu_texture.dart';
import '../gpu_vector_command_stream.dart';
import '../gpu_vector_submission_cursor.dart';
import '../vector/cpu_tessellation.dart';
import '../vector/sparse_strip_draw_plan.dart';
import '../vector/stencil_cover_draw_plan.dart';
import '../vector/vector_plan_cache.dart';
import 'gl_bindings.dart';
import 'gl_context.dart';
import 'gl_framebuffer_pool.dart';
import 'gl_shaders.dart';
import 'gl_sparse_driver.dart';
import 'gl_sparse_executor.dart';
import 'gl_stencil_cover_driver.dart';
import 'gl_stencil_cover_executor.dart';
import 'gl_surface_descriptor.dart';
import 'gl_tessellated_driver.dart';
import 'gl_tessellated_executor.dart';
import 'gl_vector_path_recorder.dart';
import 'gl_vector_replay.dart';
import 'gl_window_target.dart';

/// A texture object owned by a [GlRenderDevice].
final class GlTexture implements GpuTextureHandle {
  GlTexture._(
    this.id,
    this.width,
    this.height,
    this.format,
    this.filter,
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

  final GpuDeviceState _state;
  bool _released = false;

  /// [GpuDeviceState.lossCount] when this name was generated.
  ///
  /// The field that makes device loss survivable rather than merely
  /// observable. `isLost` goes back to false when the device is recovered, so
  /// a validity check that asked only that question would declare every
  /// pre-loss texture healthy again the moment recovery finished - and those
  /// names point at memory the driver freed. Binding one is undefined output,
  /// which is the failure this whole file is trying not to have. `lossCount`
  /// never goes down, so comparing it is the check that survives a recovery.
  final int _bornAtLossCount;

  /// A texture is invalid the moment its device is lost, and stays invalid
  /// across the recovery: the name is still an integer but the driver freed
  /// what it pointed at, and binding it is undefined rather than an error.
  @override
  bool get isValid =>
      !_released && !_state.isLost && _state.lossCount == _bornAtLossCount;

  /// Whether the driver still owns this name, so a delete is legal.
  bool get _isDeletable =>
      !_released && !_state.isLost && _state.lossCount == _bornAtLossCount;

  @override
  String toString() =>
      'GlTexture($id, ${width}x$height, ${format.name}, ${filter.name})';
}

/// The GL state [GlRenderDevice.submit] has already sent, so it does not send
/// it again.
///
/// A mutable object rather than three locals because the loop that reads it is
/// now split across passes, and passing three `var`s in and back out of
/// `_drawBatches` would either allocate a record per pass or silently reset
/// the filter at every layer boundary - which would re-bind the same texture
/// and re-send the same blend function once per layer, for nothing.
///
/// -1 is "unknown", and it is not a legal value for any of the three: a
/// texture name of 0 means *no texture* and is legal, blend modes and pipeline
/// modes are non-negative.
final class _DrawState {
  int textureId = -1;
  int mode = -1;
  int blendMode = -1;

  void reset() {
    textureId = -1;
    mode = -1;
    blendMode = -1;
  }
}

/// A target that can put its GPU resources back after a device loss.
///
/// Implemented by [GlOffscreenTarget] and by `GlWindowTarget`, which live in
/// different libraries; the device holds them through this interface so it can
/// walk every live target's inventory without knowing what kind each one is.
///
/// Registration is the target's own job - see [GlRenderDevice.registerTarget] -
/// because a target created and disposed between two losses must not appear in
/// the second one's inventory.
abstract interface class GlRecoverableTarget {
  /// This target's resources, in the order they should be rebuilt.
  Iterable<GpuRecoverableResource> recoverableResources();
}

/// An open GL context plus the objects every target shares.
/// How hard this backend should try to use sparse strips.
///
/// ## Why a policy and not a boolean
///
/// Sparse strips stopped being an experiment when the cost rule that selects
/// them was measured rather than guessed - see
/// `GpuPathStrategySelector.sparseCrossingCostInDensePixels`. But "on by
/// default" and "on because the caller asked" cannot be the same state, and
/// the difference is what happens on a driver without instanced arrays:
///
///   * a caller who *asked* for sparse and cannot have it wants to hear so,
///     loudly, because their reason for asking is now unmet;
///   * a caller who asked for nothing wants a working renderer, and the
///     absence of one optional route is not a reason to refuse the backend.
///
/// A boolean has to pick one of those and be wrong for the other. Before this
/// existed the flag meant [required], so turning it on by default would have
/// made a missing symbol fail the whole GL backend.
enum GlSparseStripsPolicy {
  /// Use sparse strips when the driver supports them, and quietly do without
  /// when it does not. The default, and what production should want.
  auto,

  /// Never build the sparse executor. The kill switch: it exists so that a
  /// regression traced to this route can be turned off without a rebuild of
  /// the caller's expectations, and so a bisect has something to toggle.
  disabled,

  /// Build it or refuse the backend. For tests and for a caller measuring the
  /// route specifically, where silently getting the dense path instead would
  /// make the measurement meaningless.
  required,
}

final class GlRenderDevice
    with DisposableMixin
    implements RenderDevice, GpuTextureAllocator, GpuRecoveryHost {
  GlRenderDevice._({
    required GlContext context,
    required GlApi gl,
    required NativeHeap heap,
    required RendererInfo info,
    required int maxTextureSize,
    required bool sparseStripsRequested,
    required bool sparseStripsRequired,
    required bool stencilCoverRequested,
    required bool cpuTessellationRequested,
  })  : _context = context,
        _gl = gl,
        _heap = heap,
        _info = info,
        _maxTextureSize = maxTextureSize,
        _sparseStripsRequested = sparseStripsRequested,
        _sparseStripsRequired = sparseStripsRequired,
        _stencilCoverRequested = stencilCoverRequested,
        _cpuTessellationRequested = cpuTessellationRequested;

  final GlContext _context;
  final GlApi _gl;
  final NativeHeap _heap;
  final RendererInfo _info;
  final int _maxTextureSize;

  /// Whether the sparse executor should exist. Cleared when an *automatic*
  /// attempt fails, which is what keeps a missing optimisation from becoming a
  /// missing renderer.
  bool _sparseStripsRequested;

  /// Whether the caller demanded it. A required route that cannot be built is
  /// an error; an automatic one is simply absent. See [GlSparseStripsPolicy].
  final bool _sparseStripsRequired;
  final bool _stencilCoverRequested;
  final bool _cpuTessellationRequested;
  final GpuDeviceState _state = GpuDeviceState();

  GlApiSparseDriver? _sparseDriver;
  SparseGlExecutor? _sparseExecutor;
  GlApiStencilCoverDriver? _stencilCoverDriver;
  StencilCoverGlExecutor? _stencilCoverExecutor;
  GlApiTessellatedDriver? _tessellatedDriver;
  TessellatedGlExecutor? _tessellatedExecutor;

  /// Whether the sparse executor exists on this device.
  ///
  /// The name is a leftover from when it did: sparse strips are no longer an
  /// experiment on GL and no longer need an opt-in. Under the default
  /// [GlSparseStripsPolicy.auto] this is true on every context that exposes
  /// instancing plus the sparse uniforms the adapter uses, and false on the
  /// rest - so it reports the *driver*, not the caller's request. Only
  /// [GlSparseStripsPolicy.disabled] makes it false unconditionally.
  bool get experimentalSparseStripsEnabled => _sparseExecutor != null;

  /// True only when the caller explicitly enabled approach C and its optional
  /// GL symbols compiled successfully. Each submission still validates the
  /// stencil/MSAA attachments of the framebuffer it binds.
  bool get experimentalStencilCoverEnabled => _stencilCoverExecutor != null;

  /// True only when retained CPU tessellation was explicitly requested.
  /// Eligible aliased solid paths may then select it through ordered replay;
  /// without the opt-in the display-list route remains byte-for-byte dense.
  bool get experimentalCpuTessellationEnabled => _tessellatedExecutor != null;

  /// Queries the attachments of one currently selectable framebuffer.
  ///
  /// Unlike context features, stencil bits and sample count belong to the
  /// framebuffer. This intentionally performs a fresh query after binding the
  /// requested target, so callers can build a plan with truthful capabilities
  /// instead of reusing the default framebuffer's answer for an offscreen FBO.
  StencilCoverCapabilities queryStencilCoverCapabilities({
    int surfaceFramebuffer = 0,
  }) {
    final GlApiStencilCoverDriver? driver = _stencilCoverDriver;
    if (driver == null) {
      throw StateError(
        'stencil-then-cover is disabled; adopt the GL context with '
        'enableExperimentalStencilCover: true',
      );
    }
    if (surfaceFramebuffer < 0) {
      throw ArgumentError.value(
        surfaceFramebuffer,
        'surfaceFramebuffer',
        'must be non-negative',
      );
    }
    if (!makeCurrentOrLose()) throw StateError('the GL context is lost');
    _status[0] = 0;
    _gl.getIntegerv(glDrawFramebufferBinding, _status);
    if (checkError('query current draw framebuffer')) {
      throw StateError('${lastError ?? 'the draw framebuffer query failed'}');
    }
    final int previousDrawFramebuffer = _status[0];
    try {
      _gl.bindFramebuffer(glDrawFramebuffer, surfaceFramebuffer);
      _requireCompleteDrawFramebuffer(surfaceFramebuffer);
      final StencilCoverCapabilities capabilities = driver.capabilities;
      if (checkError('query stencil-cover capabilities')) {
        throw StateError(
          '${lastError ?? 'the stencil-cover capability query failed'}',
        );
      }
      return capabilities;
    } finally {
      _gl.bindFramebuffer(glDrawFramebuffer, previousDrawFramebuffer);
    }
  }

  /// Scratch native memory for the `GLuint*` out-parameters, allocated once.
  ///
  /// Every GL call that returns a name - `glGenTextures`, `glGenFramebuffers`,
  /// `glDeleteBuffers` - writes through this, so a frame performs no native
  /// allocation at all. Four slots because nothing here asks for more than
  /// four names at a time.
  ///
  /// Public for the reason given in the library comment: a target lives in
  /// another file and must be able to create and delete its own GL objects
  /// without every one of them costing a `malloc`. Callers may write to it and
  /// must assume nothing survives the next device call.
  late final Pointer<Uint32> scratchNames = _heap.allocate<Uint32>(4 * 4);
  late final Pointer<Int32> _status = _heap.allocate<Int32>(4 * 4);
  late final Pointer<Pointer<Uint8>> _stringSlot =
      _heap.allocatePointers<Uint8>(1);
  late final Pointer<Uint8> _log = _heap.allocate<Uint8>(_logCapacity);
  static const int _logCapacity = 4096;

  Pointer<Uint8> _vertexStaging = nullptr;
  int _vertexStagingBytes = 0;
  Pointer<Uint8> _indexStaging = nullptr;
  int _indexStagingBytes = 0;
  Pointer<Uint8> _pixelStaging = nullptr;
  int _pixelStagingBytes = 0;

  int _program = 0;
  int _vao = 0;
  int _vbo = 0;
  int _ebo = 0;
  int _uniformViewport = -1;
  int _uniformTexture = -1;
  int _uniformMode = -1;
  int _uniformYFlip = -1;

  GpuDeviceState get state => _state;

  GlApi get api => _gl;

  @override
  RendererInfo get info => _info;

  @override
  bool get isLost => _state.isLost;

  // -------------------------------------------------------------------
  // Device-loss recovery - see gpu_recovery.dart for the eight steps
  // -------------------------------------------------------------------

  final Set<GlRecoverableTarget> _targets = <GlRecoverableTarget>{};

  /// Whether step 1 of a recovery has closed submissions.
  bool _submissionsStopped = false;

  /// How many submissions were refused because a recovery was in progress.
  ///
  /// Exposed because "submissions stopped" is invisible from the pixels: a
  /// device that went on issuing draws into a dead driver produces the same
  /// blank frame as one that correctly refused, and only this number tells the
  /// two apart.
  int get blockedSubmissionCount => _blockedSubmissionCount;
  int _blockedSubmissionCount = 0;

  /// Whether submissions are currently closed by a recovery in progress.
  bool get submissionsStopped => _submissionsStopped;

  @override
  String get backendName => GlRendererBackend.backendName;

  @override
  GpuDeviceState get deviceState => _state;

  /// Registers [target] so a recovery can rebuild what it owns.
  ///
  /// Called by the target's constructor. A target that is never registered
  /// survives a recovery with textures the driver has freed, which is exactly
  /// the silent failure the loss generation on [GlTexture] turns into a named
  /// refusal - so the worst case is a target that refuses to draw, not one
  /// that draws garbage.
  void registerTarget(GlRecoverableTarget target) => _targets.add(target);

  void unregisterTarget(GlRecoverableTarget target) => _targets.remove(target);

  /// Step 1: nothing more goes to the driver until the device is back.
  @override
  void stopSubmissions() => _submissionsStopped = true;

  /// Step 3: forget the shared pipeline objects without calling the driver.
  ///
  /// No `glDeleteProgram`, no `glDeleteBuffers`. The names point at memory a
  /// lost context has already freed; deleting them is undefined, and on a
  /// driver that has since recycled the names it deletes somebody else's
  /// objects. Zero is GL's "no object" for all four, so the fields are simply
  /// reset - [_initialise] generates new ones.
  @override
  void discardNativeResources() {
    _sparseExecutor?.discardNativeResources();
    _stencilCoverExecutor?.discardNativeResources();
    _tessellatedExecutor?.discardNativeResources();
    _program = 0;
    _vao = 0;
    _vbo = 0;
    _ebo = 0;
    _uniformViewport = -1;
    _uniformTexture = -1;
    _uniformMode = -1;
    _uniformYFlip = -1;
    _drawState.reset();
    _lastError = null;
  }

  /// Step 4: bring the context back and recompile everything shared.
  ///
  /// ## What this can and cannot recreate, stated
  ///
  /// It does **not** create a new `GlContext`. On this backend the context is
  /// owned by whoever created it - `GlContextFactory` for the offscreen path,
  /// `lib/src/backends/win32` for a window - and a renderer that destroyed and
  /// rebuilt a window's context would have to destroy the window with it, which
  /// is the one thing `renderer.dart` promises device loss does not do.
  ///
  /// What it recreates is every GL *object*, which is what a reset actually
  /// destroys: `GL_ARB_robustness` describes exactly this state, where
  /// `glGetGraphicsResetStatus` reports a reset, every object is gone and the
  /// context handle survives to be made current again. That is the case this
  /// recovers from, and it is the common one - a TDR, a driver update, a GPU
  /// switch.
  ///
  /// The case it cannot recover from is a context that will not go current at
  /// all, and it says so by name instead of pretending: the diagnostic names
  /// the context and tells the owner it has to build a new device, which means
  /// a new context, which only the platform layer can do.
  @override
  BackendDiagnostic? recreateDevice() {
    if (isDisposed) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'a disposed GL device cannot be recovered',
        detail: 'the owner must create a new device through '
            'GlRendererBackend.createDevice or adoptContext',
      );
    }
    // Cleared before anything is attempted, because every call below refuses
    // while the state says lost - makeCurrentOrLose returns false, createTexture
    // would produce dead names. Put back if the recreation fails, so the
    // coordinator's contract ("failed means still lost") holds.
    final bool wasLost = _state.isLost;
    final BackendDiagnostic? cause = _state.lossDiagnostic;
    _state.recover();

    if (!_context.makeCurrent()) {
      final BackendDiagnostic failure = BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'the GL context could not be made current again, so this '
            'device cannot be recovered',
        detail: 'the context is ${_context.description}. A context that will '
            'not go current is gone rather than reset, and only the code that '
            'created it can make another - for a window that is '
            'lib/src/backends/win32 or lib/src/backends/x11. The original '
            'loss was: ${cause ?? 'not recorded'}',
      );
      _state.markLost(failure);
      return failure;
    }

    // Any error the dead context left queued belongs to the previous device
    // and would otherwise be reported against the first call made on the new
    // one.
    _gl.drainErrors();

    final BackendDiagnostic? failure = _initialise();
    if (failure != null) {
      _state.markLost(failure);
      return failure;
    }
    final BackendDiagnostic? sparseFailure = _initialiseSparseStrips();
    if (sparseFailure != null) {
      if (_sparseStripsRequired) {
        _state.markLost(sparseFailure);
        return sparseFailure;
      }
      // Optional route, failed recovery: drop it and carry on with the dense
      // atlas. Marking the device lost here would turn "this driver cannot
      // rebuild an optimisation" into "this renderer cannot draw", which is
      // exactly the regression turning sparse on by default must not cause.
      _disableSparseStrips();
    }
    final BackendDiagnostic? stencilFailure = _initialiseStencilCover();
    if (stencilFailure != null) {
      _state.markLost(stencilFailure);
      return stencilFailure;
    }
    final BackendDiagnostic? tessellationFailure = _initialiseCpuTessellation();
    if (tessellationFailure != null) {
      _state.markLost(tessellationFailure);
      return tessellationFailure;
    }
    _submissionsStopped = false;
    if (!wasLost) {
      // Recovering a device that was not lost is a caller error rather than a
      // silent success: it means somebody ran the recovery on a healthy device
      // and threw away every atlas for nothing.
      return const BackendDiagnostic(
        kind: DiagnosticKind.note,
        message: 'the GL device was not lost when the recovery ran',
      );
    }
    return null;
  }

  /// Step 5's inventory: everything every live target owns.
  ///
  /// The device itself contributes nothing, because everything it owns - the
  /// program, the VAO and the two buffers - is rebuilt by [_initialise] inside
  /// step 4 rather than being a resource with a source of its own.
  @override
  Iterable<GpuRecoverableResource> recoverableResources() sync* {
    for (final GlRecoverableTarget target
        in List<GlRecoverableTarget>.of(_targets)) {
      yield* target.recoverableResources();
    }
  }

  /// What this device can do, answered field by field.
  ///
  /// **Text.** Every target this device builds - [GlOffscreenTarget] and
  /// [GlWindowTarget] alike - carries a [GpuGlyphAtlas], the alpha8 texture it
  /// stages into and a [GlFontResolver], so a glyph run is drawn here rather
  /// than refused. None of the five booleans below is the field that says so,
  /// which is stated because the previous shape of this class invited the
  /// opposite reading: `supportsExternalTextures: false` is about *foreign*
  /// textures and has never had anything to do with glyphs, and a reader
  /// looking for "can this device draw text" would otherwise find no answer at
  /// all and assume the pessimistic one. The probe report says it in prose -
  /// see [GlRendererBackend.describeContext] - because [Capability] has no
  /// member for text rendering and inventing one here would mean changing an
  /// enum every backend switches on.
  ///
  /// The rest are honest answers to their own questions. Partial present is
  /// false because an FBO target redraws whole; MSAA is false because nothing
  /// here asks for a multisample renderbuffer, and the antialiasing is
  /// analytic instead (see gpu_mask_atlas.dart) - which is also how glyph
  /// coverage reaches the screen, one texel per pixel out of the atlas;
  /// compute is false because the subset in gl_bindings.dart deliberately
  /// stops before compute shaders.
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

  /// Builds the target that matches [surface], or names what is missing.
  ///
  /// Two descriptors are understood and they produce different classes rather
  /// than one class with a flag, because the two present in opposite ways: a
  /// [MemorySurfaceDescriptor] becomes a [GlOffscreenTarget] that renders to a
  /// framebuffer object and reads it back, and a [GlWindowSurfaceDescriptor]
  /// becomes a [GlWindowTarget] that renders to framebuffer 0 and swaps.
  ///
  /// Anything else throws. It does **not** quietly build an offscreen target
  /// for an unrecognised descriptor - that is the silent fallback section 6.6
  /// exists to forbid, and it is the worst possible one here: the frame would
  /// render perfectly and appear nowhere, which reads as a bug in the scene
  /// rather than a bug in the backend selection.
  @override
  RenderTarget createTarget(NativeSurfaceDescriptor surface) {
    throwIfDisposed();
    if (surface is MemorySurfaceDescriptor) {
      return GlOffscreenTarget._(this, surface);
    }
    if (surface is GlWindowSurfaceDescriptor) {
      return GlWindowTarget(this, surface);
    }
    throw UnsupportedCapabilityError(
      backendName: GlRendererBackend.backendName,
      capability: Capability.gpuPresentation,
      detail: 'this device builds an offscreen target from a '
          'MemorySurfaceDescriptor and a windowed target from a '
          'GlWindowSurfaceDescriptor; it was handed a ${surface.kind} '
          '(${surface.runtimeType}), which it has no way to present to. A '
          'window descriptor is built by the platform code that owns the '
          'window - lib/src/backends/win32/win32_gl_surface.dart or '
          'lib/src/backends/x11/x11_gl_surface.dart',
    );
  }

  // -------------------------------------------------------------------
  // Textures
  // -------------------------------------------------------------------

  /// Creates an empty texture, or throws when the device cannot hold one.
  ///
  /// The size check is against the limit the device already queried, and it
  /// throws rather than letting GL answer. Without it an oversized texture
  /// raises `GL_INVALID_VALUE`, which [checkError] would have to interpret -
  /// and "this image is bigger than the GPU allows" is a caller error with an
  /// obvious fix, not a driver fault.
  @override
  GlTexture createTexture({
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
        backendName: GlRendererBackend.backendName,
        capability: Capability.gpuPresentation,
        detail: 'a ${width}x$height texture exceeds this device\'s '
            'GL_MAX_TEXTURE_SIZE of $_maxTextureSize; the caller must tile '
            'the image or scale it down',
      );
    }
    makeCurrentOrLose();
    _gl.genTextures(1, scratchNames);
    final name = scratchNames[0];
    final sampling = filter == GpuTextureFilter.linear ? glLinear : glNearest;
    _gl
      ..bindTexture(glTexture2D, name)
      ..texParameteri(glTexture2D, glTextureMinFilter, sampling)
      ..texParameteri(glTexture2D, glTextureMagFilter, sampling)
      ..texParameteri(glTexture2D, glTextureWrapS, glClampToEdge)
      ..texParameteri(glTexture2D, glTextureWrapT, glClampToEdge)
      // Coverage masks are one byte per texel and their rows are not
      // 4-aligned; the default unpack alignment of 4 would shear them.
      ..pixelStorei(glUnpackAlignment, 1);
    final internal = format == GpuTextureFormat.alpha8 ? glR8 : glRgba8;
    final external = format == GpuTextureFormat.alpha8 ? glRed : glRgba;
    _gl.texImage2D(glTexture2D, 0, internal, width, height, 0, external,
        glUnsignedByte, nullptr);
    checkError('glTexImage2D(${width}x$height, ${format.name})');
    return GlTexture._(name, width, height, format, filter, _state);
  }

  /// Uploads [height] rows of [pixels], each [bytesPerRow] bytes apart.
  ///
  /// Rows are copied one at a time into packed staging rather than handed to
  /// the driver with `GL_UNPACK_ROW_LENGTH`, because that pixel-store
  /// parameter does not exist in GLES 2 and this renderer must run there.
  @override
  void uploadRegion(
    covariant GlTexture texture, {
    required int x,
    required int y,
    required int width,
    required int height,
    required Uint8List pixels,
    required int bytesPerRow,
  }) {
    if (width <= 0 || height <= 0) return;
    makeCurrentOrLose();
    final rowBytes = width * texture.format.bytesPerPixel;
    final bytes = rowBytes * height;
    final staging = _ensurePixelStaging(bytes);
    final view = staging.asTypedList(bytes);
    for (var row = 0; row < height; row++) {
      view.setRange(
        row * rowBytes,
        row * rowBytes + rowBytes,
        pixels,
        row * bytesPerRow,
      );
    }
    final external = texture.format == GpuTextureFormat.alpha8 ? glRed : glRgba;
    _gl
      ..bindTexture(glTexture2D, texture.id)
      ..pixelStorei(glUnpackAlignment, 1)
      ..texSubImage2D(glTexture2D, 0, x, y, width, height, external,
          glUnsignedByte, staging.cast<Void>());
    checkError('glTexSubImage2D');
  }

  /// Deletes [texture]'s name, or forgets it when the driver already has.
  ///
  /// The name is marked released either way. Only the `glDeleteTextures` is
  /// conditional, and on the texture's own loss generation rather than on the
  /// device's current one: after a recovery the device is healthy again while a
  /// pre-loss name still points at freed memory, and deleting it would hand the
  /// driver an integer that may since have been handed back out to somebody
  /// else's texture.
  @override
  void releaseTexture(covariant GlTexture texture) {
    if (texture._released) return;
    final bool deletable = texture._isDeletable;
    texture._released = true;
    if (!deletable || isDisposed) return;
    scratchNames[0] = texture.id;
    _gl.deleteTextures(1, scratchNames);
  }

  // -------------------------------------------------------------------
  // Frame submission
  // -------------------------------------------------------------------

  /// Issues a batch list, switching render targets where [layers] says to.
  ///
  /// Device-to-target plumbing, public because targets live in other files;
  /// see the library comment for why that is a promoted member and not a
  /// `part`. It is not application API.
  ///
  /// ## Two things this has to get right, and one it must not change
  ///
  /// **Where the batches go.** Without layers a frame is one target and one
  /// loop, and the caller's own binding is what everything lands in - that is
  /// the whole reason one method serves both targets: [GlOffscreenTarget]
  /// binds its framebuffer object first, [GlWindowTarget] binds framebuffer 0.
  /// With layers a frame is a *sequence* of (target, batch range) pairs, and
  /// this walks it, binding [GpuRenderPass.target] or - for the surface's own
  /// runs - [surfaceFramebuffer], which is why that argument exists: the
  /// caller's binding has to be restorable after a layer pass, and this file
  /// must not guess whether it was 0.
  ///
  /// **Which way up each pass is.** See [kYFlipTopDown]: a pass rendering into
  /// a texture that will be sampled is written top-down, which inverts both
  /// the projection and the scissor's y. Getting it backwards draws every
  /// layer upside down.
  ///
  /// [firstBatch] is what makes a mid-frame flush possible: an atlas that
  /// filled up mid-frame has to have the batches recorded so far *issued*
  /// before its texels are recycled, and the rest of the frame is submitted
  /// afterwards from where this left off. A batch drawn twice blends twice, so
  /// the caller owns that cursor and this honours it - including inside a
  /// pass, whose clear only runs when its own first batch is being drawn.
  ///
  /// [surfaceWidth] and [surfaceHeight] are physical pixels and set both the
  /// viewport and the scissor clamp of the surface's passes, so passing the
  /// logical size silently renders a quarter of a HiDPI window.
  ///
  /// Returns false when the device was lost on the way, which the caller
  /// turns into [PresentStatus.deviceLost].
  bool submit(
    GpuBatcher batcher,
    int surfaceWidth,
    int surfaceHeight,
    int? clearColor, {
    GpuLayerStack? layers,
    int surfaceFramebuffer = 0,
    int firstBatch = 0,
  }) {
    // Step 1 of a recovery closed the door. Checked before makeCurrentOrLose
    // rather than after, because the whole point is that no call reaches the
    // driver - including the one that asks it to make a context current.
    if (_submissionsStopped) {
      _blockedSubmissionCount++;
      return false;
    }
    if (!makeCurrentOrLose()) return false;

    // Bound here rather than left to the caller, which is a change of contract
    // worth stating: a mid-frame flush calls this from inside the player's
    // walk, where the last binding may well be a layer target this same method
    // left behind, and a clear issued into it would erase a layer instead of
    // the surface. Both targets pass their own framebuffer - 0 is the window's
    // back buffer and is the default because that is what a window target
    // binds.
    _gl
      ..bindFramebuffer(glFramebuffer, surfaceFramebuffer)
      ..viewport(0, 0, surfaceWidth, surfaceHeight)
      ..disable(glDepthTest)
      ..disable(glCullFace)
      ..enable(glBlend)
      ..disable(glScissorTest);

    // A caller resuming after a mid-frame flush passes null: the surface was
    // cleared by the submission that opened the frame, and clearing again
    // would erase everything drawn before the flush.
    if (clearColor != null) {
      // The clear colour arrives packed the way FrameRequest documents it -
      // premultiplied BGRA in a 32-bit int - and glClearColor wants
      // straight floats in RGBA order.
      _gl
        ..clearColor(
          ((clearColor >> 16) & 0xFF) / 255.0,
          ((clearColor >> 8) & 0xFF) / 255.0,
          (clearColor & 0xFF) / 255.0,
          ((clearColor >> 24) & 0xFF) / 255.0,
        )
        ..clear(glColorBufferBit);
    }

    final int batchCount = batcher.batchCount;
    if (batchCount <= firstBatch) return !_state.isLost;

    _uploadGeometry(batcher);

    _gl
      ..useProgram(_program)
      ..uniform1i(_uniformTexture, 0)
      ..activeTexture(glTexture0)
      ..bindVertexArray(_vao)
      ..enable(glScissorTest);

    // Bound GL state carried *across* passes on purpose: a texture binding, a
    // blend function and the mode uniform are context state, not framebuffer
    // state, so switching target does not invalidate them and re-sending them
    // per pass would cost a driver call per layer for nothing.
    final _DrawState state = _drawState..reset();

    final int passCount = layers?.passCount ?? 0;
    if (passCount == 0) {
      _drawBatches(
        batcher,
        firstBatch,
        batchCount,
        surfaceWidth,
        surfaceHeight,
        kYFlipDefault,
        state,
      );
    } else {
      for (var p = 0; p < passCount; p++) {
        final GpuRenderPass pass = layers!.passAt(p);
        final int end = layers.passEnd(p, batchCount);
        if (end <= firstBatch) continue;
        final int start =
            pass.firstBatch < firstBatch ? firstBatch : pass.firstBatch;
        // Only when this submission is the one that opens the pass: a pass
        // resumed after a mid-frame flush has already been cleared, and
        // clearing it again would erase what was just drawn into it.
        final bool clears = pass.clearsTarget && start == pass.firstBatch;
        // An *empty* pass that clears is not a contradiction and must not be
        // skipped: a layer whose first act is to open a nested layer records
        // no batches of its own until that one closes, and its target still
        // has to lose the previous tenant's pixels before the nested
        // composite is drawn into it.
        if (end <= start && !clears) continue;

        final GpuLayerTarget? target = pass.target;
        _gl
          ..bindFramebuffer(
              glFramebuffer, target == null ? surfaceFramebuffer : target.id)
          ..viewport(0, 0, pass.viewportWidth, pass.viewportHeight);

        if (clears) {
          // A layer composites what it drew over *transparency*. The scissor
          // is off for the clear because glClear obeys it, and the whole
          // target - including the slack a pooled target has past the layer's
          // own size - has to lose the previous tenant's pixels.
          _gl
            ..disable(glScissorTest)
            ..clearColor(0, 0, 0, 0)
            ..clear(glColorBufferBit)
            ..enable(glScissorTest);
        }
        if (end <= start) continue;

        _drawBatches(
          batcher,
          start,
          end,
          pass.viewportWidth,
          pass.viewportHeight,
          pass.rendersTopDown ? kYFlipTopDown : kYFlipDefault,
          state,
        );
        _resolveLayerTarget(target);
      }
      // The caller bound its own framebuffer before calling and is entitled to
      // find it bound afterwards - it reads pixels back or swaps it next.
      _gl.bindFramebuffer(glFramebuffer, surfaceFramebuffer);
    }

    _gl.disable(glScissorTest);
    checkError('draw');
    return !_state.isLost;
  }

  /// Issues an incrementally snapshot mixed dense/vector command stream.
  ///
  /// This is the opt-in replay counterpart of [submit]. The stream has already
  /// retained every experimental payload without native side effects, and the
  /// cursor makes atlas-pressure submissions resumable: dense batches, vector
  /// ordinals and offscreen clears are each issued once across snapshots.
  bool submitOrderedPaths(
    GpuBatcher batcher,
    GpuVectorCommandStream<ReplayPaint, GlVectorPathPayload> stream,
    GpuVectorSubmissionCursor cursor,
    int surfaceWidth,
    int surfaceHeight,
    int? clearColor, {
    int surfaceFramebuffer = 0,
  }) {
    if (_submissionsStopped) {
      _blockedSubmissionCount++;
      return false;
    }
    if (!makeCurrentOrLose()) return false;

    _gl
      ..bindFramebuffer(glFramebuffer, surfaceFramebuffer)
      ..viewport(0, 0, surfaceWidth, surfaceHeight)
      ..disable(glDepthTest)
      ..disable(glCullFace)
      ..disable(glScissorTest);
    if (clearColor != null) {
      _gl
        ..clearColor(
          ((clearColor >> 16) & 0xFF) / 255.0,
          ((clearColor >> 8) & 0xFF) / 255.0,
          (clearColor & 0xFF) / 255.0,
          ((clearColor >> 24) & 0xFF) / 255.0,
        )
        ..clear(glColorBufferBit);
    }

    if (batcher.batchCount > cursor.nextDenseBatch) {
      _uploadGeometry(batcher);
    }
    final _DrawState denseState = _drawState..reset();
    const GpuOrderedSubmissionWalker().submit(
      stream: stream,
      cursor: cursor,
      beginPass: (pass, clearTarget) {
        final int framebuffer = pass.target?.id ?? surfaceFramebuffer;
        _gl
          ..bindFramebuffer(glFramebuffer, framebuffer)
          ..viewport(0, 0, pass.viewportWidth, pass.viewportHeight);
        if (clearTarget) {
          _gl
            ..disable(glScissorTest)
            ..clearColor(0, 0, 0, 0)
            ..clear(glColorBufferBit);
        }
      },
      submitDense: (pass, range) {
        // Every experimental executor owns and then releases its program/VAO.
        // Rebind the dense pipeline for each resumed range; _DrawState still
        // avoids redundant texture/blend/mode changes within that range.
        _gl
          ..useProgram(_program)
          ..uniform1i(_uniformTexture, 0)
          ..activeTexture(glTexture0)
          ..bindVertexArray(_vao)
          ..enable(glBlend)
          ..enable(glScissorTest);
        _drawBatches(
          batcher,
          range.firstBatch,
          range.endBatch,
          pass.viewportWidth,
          pass.viewportHeight,
          pass.rendersTopDown ? kYFlipTopDown : kYFlipDefault,
          denseState,
        );
      },
      submitVector: (pass, command) {
        final int framebuffer = pass.target?.id ?? surfaceFramebuffer;
        final ReplayPaint paint = command.material;
        final int yFlip = pass.rendersTopDown ? kYFlipTopDown : kYFlipDefault;
        switch (command.payload) {
          case GlSparsePathPayload(:final plan, :final gradient):
            submitSparseStrips(
              plan,
              materials: <SparseGlMaterial>[
                // A gradient carries its colour in the ramp, including alpha -
                // the CPU replay reads the paint's own alpha channel for a
                // gradient too, so modulating here as well would darken it
                // twice. See `_CpuGradientShader` in `cpu_renderer.dart`.
                if (gradient != null)
                  SparseGlMaterial.gradient(
                    gradientBinding: gradient.binding,
                    gradientParameters: gradient.parameters,
                    blendMode: paint.blendMode,
                  )
                else
                  _solidMaterial(paint),
              ],
              viewportWidth: pass.viewportWidth,
              viewportHeight: pass.viewportHeight,
              yFlip: yFlip,
              surfaceFramebuffer: framebuffer,
            );
          case GlTessellatedPathPayload(
              :final mesh,
              :final localToTarget,
              :final clip,
            ):
            submitTessellatedPath(
              mesh,
              material: _tessellatedMaterial(paint),
              viewportWidth: pass.viewportWidth,
              viewportHeight: pass.viewportHeight,
              yFlip: yFlip,
              localToTarget: localToTarget,
              clip: clip.intersect(command.effectiveTargetClip),
              surfaceFramebuffer: framebuffer,
            );
          case GlStencilPathPayload(:final plan):
            submitStencilCover(
              plan,
              materials: <StencilGlMaterial>[_stencilMaterial(paint)],
              viewportWidth: pass.viewportWidth,
              viewportHeight: pass.viewportHeight,
              yFlip: yFlip,
              surfaceFramebuffer: framebuffer,
            );
        }
        denseState.reset();
      },
      endPass: (pass) => _resolveLayerTarget(pass.target),
    );

    _gl
      ..bindFramebuffer(glFramebuffer, surfaceFramebuffer)
      ..disable(glScissorTest);
    if (checkError('ordered dense/vector draw')) return false;
    return !_state.isLost;
  }

  /// Resolves a multisampled layer target so the composite can sample it.
  ///
  /// Called at the end of every pass that drew into a layer target, and a
  /// no-op for the surface and for single-sample targets - which is every
  /// layer target unless the stack's attachment policy asked for more.
  ///
  /// **Why the end of every pass and not the end of the layer.** A layer's
  /// batches are not one contiguous run: a nested layer splits them, and a
  /// mid-frame atlas flush splits them again. Resolving whenever a pass that
  /// wrote into the target finishes is therefore the only placement that is
  /// correct without tracking which pass was the last, and resolving twice is
  /// harmless - the second blit copies the same finished pixels. What matters
  /// is the ordering it guarantees: the composite quad that samples this
  /// target belongs to the *parent's* pass, which is appended after this one,
  /// so it can never be drawn before the resolve that feeds it.
  void _resolveLayerTarget(GpuLayerTarget? target) {
    if (target is! GlFramebuffer) return;
    if (!target.attachments.isMultisampled) return;
    _layerResolveCount++;
    final GlFramebufferFactory factory = _resolveFactory;
    if (factory is GlAttachmentFramebufferFactory) {
      factory.resolveFramebuffer(target);
    }
  }

  /// The factory used to resolve multisampled layer targets.
  ///
  /// The device does not own the layer pool - each target does - so this is
  /// built once from the same GL entry points the pools use. Resolving through
  /// the pool instead would mean the device holding a reference to whichever
  /// target's pool happened to allocate the framebuffer.
  late final GlFramebufferFactory _resolveFactory = GlDeviceFramebufferFactory(
    gl: _gl,
    scratchNames: scratchNames,
    makeCurrent: makeCurrentOrLose,
  );

  /// Multisample resolves this device has issued for layer targets. Invisible
  /// from the pixels - a missing one is - so a test asserts the count.
  int get layerResolveCount => _layerResolveCount;
  int _layerResolveCount = 0;

  /// The paint's premultiplied colour, for a route with no gradient material.
  ///
  /// Approaches B and C hand the rasteriser geometry and one solid colour, so
  /// a gradient reaching either of them would be drawn as its otherwise-unused
  /// fallback colour. `GlVectorPathRecorder` refuses that combination before a
  /// command is recorded, and `GlVectorReplay` never reports those routes as
  /// capable for a gradient draw; this is the assertion that both held.
  static (double, double, double, double) _premultipliedPaint(
    ReplayPaint paint,
  ) {
    if (paint.gradient != null) {
      throw UnsupportedError(
        'ordered GL path replay requires a resolved gradient material; the '
        'recorder must not accept a gradient paint for this route',
      );
    }
    final double alpha = ((paint.argbColor >> 24) & 0xFF) / 255.0;
    return (
      ((paint.argbColor >> 16) & 0xFF) / 255.0 * alpha,
      ((paint.argbColor >> 8) & 0xFF) / 255.0 * alpha,
      (paint.argbColor & 0xFF) / 255.0 * alpha,
      alpha,
    );
  }

  static SparseGlMaterial _solidMaterial(ReplayPaint paint) {
    final (double, double, double, double) color = _premultipliedPaint(paint);
    return SparseGlMaterial(
      red: color.$1,
      green: color.$2,
      blue: color.$3,
      alpha: color.$4,
      blendMode: paint.blendMode,
    );
  }

  static TessellatedGlMaterial _tessellatedMaterial(ReplayPaint paint) {
    final (double, double, double, double) color = _premultipliedPaint(paint);
    return TessellatedGlMaterial(
      red: color.$1,
      green: color.$2,
      blue: color.$3,
      alpha: color.$4,
      blendMode: paint.blendMode,
    );
  }

  static StencilGlMaterial _stencilMaterial(ReplayPaint paint) {
    final (double, double, double, double) color = _premultipliedPaint(paint);
    return StencilGlMaterial(
      red: color.$1,
      green: color.$2,
      blue: color.$3,
      alpha: color.$4,
      blendMode: paint.blendMode,
    );
  }

  /// Explicit sparse-strip submission seam.
  ///
  /// The display-list renderer does not call this method. A caller has to opt
  /// in while adopting the context and then explicitly provide a sparse plan;
  /// consequently the established dense atlas path remains the default even
  /// on hardware that supports instancing.
  SparseGlExecutionStats submitSparseStrips(
    SparseStripDrawPlan plan, {
    required List<SparseGlMaterial> materials,
    required int viewportWidth,
    required int viewportHeight,
    int yFlip = 0,
    int surfaceFramebuffer = 0,
  }) {
    final SparseGlExecutor? executor = _sparseExecutor;
    if (executor == null) {
      throw StateError(
        'sparse strips are disabled; adopt the GL context with '
        'enableExperimentalSparseStrips: true',
      );
    }
    if (_submissionsStopped) {
      _blockedSubmissionCount++;
      throw StateError('GL submissions are stopped during device recovery');
    }
    if (!makeCurrentOrLose()) {
      throw StateError('the GL context is lost');
    }
    _gl
      ..bindFramebuffer(glFramebuffer, surfaceFramebuffer)
      ..viewport(0, 0, viewportWidth, viewportHeight)
      ..disable(glDepthTest)
      ..disable(glCullFace)
      ..disable(glScissorTest);
    final SparseGlExecutionStats stats = executor.submit(
      plan,
      materials: materials,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
      yFlip: yFlip,
    );
    if (checkError('sparse-strip draw')) {
      throw StateError('${lastError ?? 'the sparse GL draw failed'}');
    }
    return stats;
  }

  /// Explicit approach-C submission seam.
  ///
  /// Like [submitSparseStrips], this is never called by the production
  /// display-list path. The selected framebuffer must carry stencil, and an
  /// antialiased plan additionally requires at least four samples; the
  /// executor queries those framebuffer-dependent facts after it is bound.
  StencilCoverGlExecutionStats submitStencilCover(
    StencilCoverDrawPlan plan, {
    required List<StencilGlMaterial> materials,
    required int viewportWidth,
    required int viewportHeight,
    int yFlip = 0,
    int surfaceFramebuffer = 0,
  }) {
    final StencilCoverGlExecutor? executor = _stencilCoverExecutor;
    if (executor == null) {
      throw StateError(
        'stencil-then-cover is disabled; adopt the GL context with '
        'enableExperimentalStencilCover: true',
      );
    }
    if (surfaceFramebuffer < 0) {
      throw ArgumentError.value(
        surfaceFramebuffer,
        'surfaceFramebuffer',
        'must be non-negative',
      );
    }
    if (_submissionsStopped) {
      _blockedSubmissionCount++;
      throw StateError('GL submissions are stopped during device recovery');
    }
    if (!makeCurrentOrLose()) {
      throw StateError('the GL context is lost');
    }
    _gl.bindFramebuffer(glDrawFramebuffer, surfaceFramebuffer);
    _requireCompleteDrawFramebuffer(surfaceFramebuffer);
    final StencilCoverGlExecutionStats stats = executor.submit(
      plan,
      materials: materials,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
      yFlip: yFlip,
    );
    if (checkError('stencil-cover draw')) {
      throw StateError('${lastError ?? 'the stencil-cover GL draw failed'}');
    }
    return stats;
  }

  /// Explicit approach-B submission seam for a retained tessellated mesh.
  ///
  /// Besides ordered replay, callers can use this seam to evaluate a retained
  /// mesh independently. The analytic atlas remains the default unless the GL
  /// context was adopted with experimental CPU tessellation enabled.
  TessellatedGlExecutionStats submitTessellatedPath(
    TessellatedPathMesh mesh, {
    required TessellatedGlMaterial material,
    required int viewportWidth,
    required int viewportHeight,
    int yFlip = 0,
    Transform2D localToTarget = Transform2D.identity,
    Rect? clip,
    int surfaceFramebuffer = 0,
  }) {
    final TessellatedGlExecutor? executor = _tessellatedExecutor;
    if (executor == null) {
      throw StateError(
        'CPU tessellation is disabled; adopt the GL context with '
        'enableExperimentalCpuTessellation: true',
      );
    }
    if (surfaceFramebuffer < 0) {
      throw ArgumentError.value(
        surfaceFramebuffer,
        'surfaceFramebuffer',
        'must be non-negative',
      );
    }
    if (_submissionsStopped) {
      _blockedSubmissionCount++;
      throw StateError('GL submissions are stopped during device recovery');
    }
    if (!makeCurrentOrLose()) throw StateError('the GL context is lost');
    _gl
      ..bindFramebuffer(glDrawFramebuffer, surfaceFramebuffer)
      ..viewport(0, 0, viewportWidth, viewportHeight)
      ..disable(glDepthTest)
      ..disable(glCullFace);
    _requireCompleteDrawFramebuffer(surfaceFramebuffer);
    late final TessellatedGlExecutionStats stats;
    try {
      stats = executor.submit(
        mesh,
        material: material,
        viewportWidth: viewportWidth,
        viewportHeight: viewportHeight,
        yFlip: yFlip,
        localToTarget: localToTarget,
        clip: clip,
      );
    } finally {
      // The explicit executor owns its program, VAO, blend and scissor state.
      // Invalidate the dense cache even after an exception so a following
      // dense batch rebinds state instead of trusting stale Dart values.
      _drawState.reset();
    }
    if (checkError('CPU-tessellated GL draw')) {
      throw StateError('${lastError ?? 'the tessellated GL draw failed'}');
    }
    return stats;
  }

  void _requireCompleteDrawFramebuffer(int surfaceFramebuffer) {
    final int status = _gl.checkFramebufferStatus(glDrawFramebuffer);
    if (status == glFramebufferComplete) return;
    throw StateError(
      'stencil-cover framebuffer $surfaceFramebuffer is incomplete: '
      'glCheckFramebufferStatus returned 0x${status.toRadixString(16)}',
    );
  }

  /// Issues batches `[first, last)` into whatever is bound, at [viewportWidth]
  /// by [viewportHeight] and in the orientation [yFlip] names.
  void _drawBatches(
    GpuBatcher batcher,
    int first,
    int last,
    int viewportWidth,
    int viewportHeight,
    int yFlip,
    _DrawState state,
  ) {
    _gl.uniform2f(
      _uniformViewport,
      viewportWidth.toDouble(),
      viewportHeight.toDouble(),
    );
    _gl.uniform1i(_uniformYFlip, yFlip);

    for (var i = first; i < last; i++) {
      final batch = batcher.batchAt(i);
      var left = batch.scissorLeft;
      var top = batch.scissorTop;
      var right = batch.scissorRight;
      var bottom = batch.scissorBottom;
      if (left < 0) left = 0;
      if (top < 0) top = 0;
      if (right > viewportWidth) right = viewportWidth;
      if (bottom > viewportHeight) bottom = viewportHeight;
      if (right <= left || bottom <= top) continue;

      // GL's scissor origin is the bottom-left corner and device space's is
      // the top-left, so the y is flipped - *unless* this pass already
      // inverted its projection to write the target top-down, in which case
      // device row 0 is framebuffer row 0 and flipping again would scissor
      // the mirror image of the batch's clip.
      _gl.scissor(
        left,
        yFlip == kYFlipTopDown ? top : viewportHeight - bottom,
        right - left,
        bottom - top,
      );

      if (batch.blendMode != state.blendMode) {
        state.blendMode = batch.blendMode;
        final blend = gpuBlendForMode(batch.blendMode);
        _gl.blendFunc(_glFactor(blend.source), _glFactor(blend.destination));
      }
      final mode = switch (batch.pipeline) {
        GpuPipelineKind.solid => kModeSolid,
        GpuPipelineKind.coverageMask => kModeCoverageMask,
        GpuPipelineKind.texturedImage => kModeTexturedImage,
      };
      if (mode != state.mode) {
        state.mode = mode;
        _gl.uniform1i(_uniformMode, mode);
      }
      if (batch.textureId != state.textureId) {
        state.textureId = batch.textureId;
        _gl.bindTexture(glTexture2D, batch.textureId);
      }
      _gl.drawElements(
        glTriangles,
        batch.indexCount,
        glUnsignedInt,
        Pointer<Void>.fromAddress(batch.indexOffset * 4),
      );
    }
  }

  /// The redundant-state filter, reused across submissions rather than
  /// rebuilt: [submit] runs per frame and this must not allocate.
  final _DrawState _drawState = _DrawState();

  void _uploadGeometry(GpuBatcher batcher) {
    final buffer = batcher.buffer;
    final floatCount = buffer.vertexCount * kGpuFloatsPerVertex;
    final vertexBytes = floatCount * 4;
    final staging = _ensureVertexStaging(vertexBytes);
    staging
        .cast<Float>()
        .asTypedList(floatCount)
        .setRange(0, floatCount, buffer.vertexStorage);
    _gl
      ..bindBuffer(glArrayBuffer, _vbo)
      ..bufferData(
          glArrayBuffer, vertexBytes, staging.cast<Void>(), glDynamicDraw);

    final indexCount = buffer.indexCount;
    final indexBytes = indexCount * 4;
    final indexStaging = _ensureIndexStaging(indexBytes);
    indexStaging
        .cast<Uint32>()
        .asTypedList(indexCount)
        .setRange(0, indexCount, buffer.indexStorage);
    _gl
      ..bindBuffer(glElementArrayBuffer, _ebo)
      ..bufferData(glElementArrayBuffer, indexBytes, indexStaging.cast<Void>(),
          glDynamicDraw);
    checkError('glBufferData');
  }

  /// Reads the bound framebuffer into [destination], flipping rows.
  ///
  /// GL hands back rows bottom-up because its framebuffer origin is at the
  /// bottom left; [Framebuffer] is top-down. The flip is here rather than in
  /// the shader because flipping the projection instead would put the whole
  /// renderer in a coordinate system that disagrees with every rectangle the
  /// layout produced.
  bool _readPixels(Framebuffer destination) {
    if (_submissionsStopped) {
      _blockedSubmissionCount++;
      return false;
    }
    if (!makeCurrentOrLose()) return false;
    final width = destination.width;
    final height = destination.height;
    final bytes = width * height * 4;
    final staging = _ensurePixelStaging(bytes);
    _gl
      ..pixelStorei(glPackAlignment, 1)
      ..readPixels(
          0, 0, width, height, glRgba, glUnsignedByte, staging.cast<Void>());
    if (checkError('glReadPixels')) return false;

    final source = staging.asTypedList(bytes);
    final swizzle = destination.format == PixelFormat.bgra8888Premultiplied;
    for (var y = 0; y < height; y++) {
      final sourceRow = (height - 1 - y) * width * 4;
      final destinationRow = y * destination.bytesPerRow;
      if (!swizzle) {
        destination.pixels.setRange(
          destinationRow,
          destinationRow + width * 4,
          source,
          sourceRow,
        );
        continue;
      }
      // GL_BGRA exists on desktop GL and not in ES core, so the swizzle is
      // done here instead of asked of the driver. It costs a pass over the
      // surface, which only the readback path pays.
      for (var x = 0; x < width; x++) {
        final s = sourceRow + x * 4;
        final d = destinationRow + x * 4;
        destination.pixels[d] = source[s + 2];
        destination.pixels[d + 1] = source[s + 1];
        destination.pixels[d + 2] = source[s];
        destination.pixels[d + 3] = source[s + 3];
      }
    }
    return true;
  }

  // -------------------------------------------------------------------
  // Setup and teardown
  // -------------------------------------------------------------------

  /// Compiles the program and creates the shared buffers.
  ///
  /// Returns a diagnostic on failure instead of throwing, so device creation
  /// can report it the same way a probe does.
  BackendDiagnostic? _initialise() {
    if (!makeCurrentOrLose()) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'the GL context could not be made current',
      );
    }

    final vertex = _compile(
      glVertexShader,
      vertexShaderSource(desktop: _context.isDesktopGl),
    );
    if (vertex is BackendDiagnostic) return vertex;
    final fragment = _compile(
      glFragmentShader,
      fragmentShaderSource(desktop: _context.isDesktopGl),
    );
    if (fragment is BackendDiagnostic) {
      _gl.deleteShader(vertex as int);
      return fragment;
    }

    _program = _gl.createProgram();
    _gl
      ..attachShader(_program, vertex as int)
      ..attachShader(_program, fragment as int);
    for (var i = 0; i < kAttributeNames.length; i++) {
      final name = _heap.allocateUtf8(kAttributeNames[i]);
      _gl.bindAttribLocation(_program, i, name);
      _heap.release(name);
    }
    _gl
      ..linkProgram(_program)
      ..getProgramiv(_program, glLinkStatus, _status);
    if (_status[0] == glFalseValue) {
      final log = _programLog();
      _gl
        ..deleteShader(vertex)
        ..deleteShader(fragment);
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'shader program failed to link',
        detail: log,
      );
    }
    // Attached shaders are reference counted by the program, so deleting them
    // here frees the compiler's copies while the program keeps working.
    _gl
      ..deleteShader(vertex)
      ..deleteShader(fragment);

    _uniformViewport = _uniformLocation('uViewport');
    _uniformTexture = _uniformLocation('uTexture');
    _uniformMode = _uniformLocation('uMode');
    _uniformYFlip = _uniformLocation('uYFlip');
    if (_uniformViewport < 0 || _uniformMode < 0 || _uniformYFlip < 0) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the linked program is missing a uniform the renderer needs',
        detail: 'uViewport, uMode or uYFlip was optimised away, which means '
            'the shader source and this file have drifted apart. uYFlip in '
            'particular decides which way up a layer is drawn, and a driver '
            'that folded it away would render every layer mirrored',
      );
    }

    _gl
      ..genVertexArrays(1, scratchNames)
      ..bindVertexArray(scratchNames[0]);
    _vao = scratchNames[0];
    _gl.genBuffers(1, scratchNames);
    _vbo = scratchNames[0];
    _gl.genBuffers(1, scratchNames);
    _ebo = scratchNames[0];

    const stride = kGpuFloatsPerVertex * 4;
    _gl
      ..bindBuffer(glArrayBuffer, _vbo)
      ..bindBuffer(glElementArrayBuffer, _ebo);
    _attribute(kAttributePosition, 2, kGpuPositionOffset * 4, stride);
    _attribute(kAttributeTexCoord, 2, kGpuTexCoordOffset * 4, stride);
    _attribute(kAttributeColor, 4, kGpuColorOffset * 4, stride);
    _attribute(kAttributeShapeRect, 4, kGpuShapeRectOffset * 4, stride);

    if (checkError('device initialisation')) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'GL reported an error while creating the renderer objects',
        detail: _lastError?.detail,
      );
    }
    return null;
  }

  /// Drops the sparse route after an *automatic* attempt failed.
  ///
  /// The dense atlas draws every one of these paths correctly, and a caller
  /// who asked for a renderer rather than for this route specifically should
  /// get one. Only reachable when the policy is not
  /// [GlSparseStripsPolicy.required].
  void _disableSparseStrips() {
    _sparseExecutor?.dispose();
    _sparseExecutor = null;
    _sparseDriver?.disposeHostResources();
    _sparseDriver = null;
    _sparseStripsRequested = false;
  }

  BackendDiagnostic? _initialiseSparseStrips() {
    if (!_sparseStripsRequested) return null;
    final GlApiSparseDriver driver =
        _sparseDriver ??= GlApiSparseDriver(_gl, _heap);
    final SparseGlExecutor executor = _sparseExecutor ??= SparseGlExecutor(
      driver,
      textureAllocator: this,
    );
    try {
      executor.initialize(desktop: _context.isDesktopGl);
    } on Object catch (error) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the opt-in sparse GL pipeline could not be initialized',
        detail: '$error',
      );
    }
    if (checkError('sparse GL initialisation')) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'GL rejected the opt-in sparse renderer objects',
        detail: lastError?.detail,
      );
    }
    return null;
  }

  BackendDiagnostic? _initialiseStencilCover() {
    if (!_stencilCoverRequested) return null;
    final GlApiStencilCoverDriver driver =
        _stencilCoverDriver ??= GlApiStencilCoverDriver(_gl, _heap);
    final StencilCoverGlExecutor executor =
        _stencilCoverExecutor ??= StencilCoverGlExecutor(driver);
    try {
      executor.initialize(desktop: _context.isDesktopGl);
    } on Object catch (error) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the opt-in stencil-cover GL pipeline could not be '
            'initialized',
        detail: '$error',
      );
    }
    if (checkError('stencil-cover GL initialisation')) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'GL rejected the opt-in stencil-cover renderer objects',
        detail: lastError?.detail,
      );
    }
    return null;
  }

  BackendDiagnostic? _initialiseCpuTessellation() {
    if (!_cpuTessellationRequested) return null;
    final GlApiTessellatedDriver driver =
        _tessellatedDriver ??= GlApiTessellatedDriver(_gl, _heap);
    final TessellatedGlExecutor executor =
        _tessellatedExecutor ??= TessellatedGlExecutor(driver);
    try {
      executor.initialize(desktop: _context.isDesktopGl);
    } on Object catch (error) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the opt-in CPU-tessellated GL pipeline could not be '
            'initialized',
        detail: '$error',
      );
    }
    if (checkError('CPU-tessellated GL initialisation')) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'GL rejected the opt-in CPU-tessellated renderer objects',
        detail: lastError?.detail,
      );
    }
    return null;
  }

  void _attribute(int index, int size, int offset, int stride) {
    _gl
      ..enableVertexAttribArray(index)
      ..vertexAttribPointer(index, size, glFloat, glFalseValue, stride,
          Pointer<Void>.fromAddress(offset));
  }

  int _uniformLocation(String name) {
    final native = _heap.allocateUtf8(name);
    final location = _gl.getUniformLocation(_program, native);
    _heap.release(native);
    return location;
  }

  /// Returns the shader name on success, a [BackendDiagnostic] on failure.
  Object _compile(int type, String source) {
    final shader = _gl.createShader(type);
    final native = _heap.allocateUtf8(source);
    _stringSlot[0] = native;
    _gl
      ..shaderSource(shader, 1, _stringSlot, nullptr)
      ..compileShader(shader)
      ..getShaderiv(shader, glCompileStatus, _status);
    _heap.release(native);
    if (_status[0] != glFalseValue) return shader;

    _gl
      ..getShaderInfoLog(shader, _logCapacity, nullptr, _log)
      ..deleteShader(shader);
    return BackendDiagnostic(
      kind: DiagnosticKind.incompatibleDevice,
      message: type == glVertexShader
          ? 'vertex shader failed to compile'
          : 'fragment shader failed to compile',
      // The driver's own message, verbatim. Anything less turns a one-line
      // GLSL error into an afternoon.
      detail: readNativeUtf8(_log, limit: _logCapacity),
    );
  }

  String _programLog() {
    _gl.getProgramInfoLog(_program, _logCapacity, nullptr, _log);
    return readNativeUtf8(_log, limit: _logCapacity);
  }

  /// Makes this device's context current, or marks the device lost.
  ///
  /// Device-to-target plumbing, public for the reason the library comment
  /// gives. Every target must call it before touching GL, and the result must
  /// be checked rather than assumed: issuing a GL call through a context that
  /// is not current does not fail, it writes into whichever context *is*,
  /// which on a machine running two GL applications is the other one's.
  ///
  /// Never throws. A driver that refuses is device loss, which is a state the
  /// caller reports, not an exception it catches.
  bool makeCurrentOrLose() {
    if (_state.isLost) return false;
    if (_context.makeCurrent()) return true;
    _state.markLost(
      const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'the GL context could not be made current',
        detail: 'the driver refused to make the context current, which is '
            'what a lost or reset context looks like from here',
      ),
    );
    return false;
  }

  /// The last GL error this device saw that was not fatal, or null.
  ///
  /// Kept rather than thrown so a caller can report it without the renderer
  /// deciding that a recoverable mistake ends the device. Cleared by the next
  /// clean [checkError].
  BackendDiagnostic? get lastError => _lastError;
  BackendDiagnostic? _lastError;

  /// Drains GL's error queue, and decides whether the device survived it.
  ///
  /// Returns true when something was wrong. Only two errors mark the device
  /// lost, and the distinction is the spec's own: `GL_OUT_OF_MEMORY` and
  /// `GL_CONTEXT_LOST` leave the contents of every object undefined, while
  /// every other error is defined to have "no other side effect than to set
  /// the error flag" - the command is ignored and the context is still valid.
  ///
  /// Treating all of them as loss, which this did, meant one oversized
  /// texture or one bad enum turned a recoverable mistake into a device that
  /// could never draw again and could not be recovered either. That is a
  /// worse failure than the bug it was reporting.
  ///
  /// Device-to-target plumbing, public for the reason the library comment
  /// gives: a target creates GL objects of its own and has to be able to ask
  /// whether the driver accepted them. [what] is pasted verbatim into the
  /// diagnostic, so it should name the call, not the module.
  bool checkError(String what) {
    final error = _gl.drainErrors();
    if (error == glNoError) {
      _lastError = null;
      return false;
    }
    final fatal = error == glContextLost || error == glOutOfMemory;
    final diagnostic = BackendDiagnostic(
      kind: error == glContextLost
          ? DiagnosticKind.connectionFailed
          : DiagnosticKind.incompatibleDevice,
      message: switch (error) {
        glContextLost => 'the GL context was lost',
        glOutOfMemory => 'the GL driver ran out of memory during $what',
        _ => 'GL error during $what',
      },
      detail: '0x${error.toRadixString(16)}',
    );
    _lastError = diagnostic;
    if (fatal) _state.markLost(diagnostic);
    return true;
  }

  Pointer<Uint8> _ensureVertexStaging(int bytes) {
    if (bytes <= _vertexStagingBytes) return _vertexStaging;
    _heap.release(_vertexStaging);
    _vertexStagingBytes = bytes * 2;
    return _vertexStaging = _heap.allocate<Uint8>(_vertexStagingBytes);
  }

  Pointer<Uint8> _ensureIndexStaging(int bytes) {
    if (bytes <= _indexStagingBytes) return _indexStaging;
    _heap.release(_indexStaging);
    _indexStagingBytes = bytes * 2;
    return _indexStaging = _heap.allocate<Uint8>(_indexStagingBytes);
  }

  Pointer<Uint8> _ensurePixelStaging(int bytes) {
    if (bytes <= _pixelStagingBytes) return _pixelStaging;
    _heap.release(_pixelStaging);
    _pixelStagingBytes = bytes;
    return _pixelStaging = _heap.allocate<Uint8>(_pixelStagingBytes);
  }

  static int _glFactor(GpuBlendFactor factor) => switch (factor) {
        GpuBlendFactor.zero => glZero,
        GpuBlendFactor.one => glOne,
        GpuBlendFactor.oneMinusSrcAlpha => glOneMinusSrcAlpha,
      };

  @override
  void onDispose() {
    // Reverse order, and only when the context is still usable: deleting GL
    // objects through a lost context is undefined, and the driver has freed
    // them already anyway.
    if (!_state.isLost && _context.makeCurrent()) {
      _sparseExecutor?.dispose();
      _stencilCoverExecutor?.dispose();
      _tessellatedExecutor?.dispose();
      if (_vbo != 0) {
        scratchNames[0] = _vbo;
        _gl.deleteBuffers(1, scratchNames);
      }
      if (_ebo != 0) {
        scratchNames[0] = _ebo;
        _gl.deleteBuffers(1, scratchNames);
      }
      if (_vao != 0) {
        scratchNames[0] = _vao;
        _gl.deleteVertexArrays(1, scratchNames);
      }
      if (_program != 0) _gl.deleteProgram(_program);
    } else {
      if (_sparseExecutor != null && !_sparseExecutor!.isDisposed) {
        _sparseExecutor!.disposeAfterDeviceLoss();
      }
      if (_stencilCoverExecutor != null && !_stencilCoverExecutor!.isDisposed) {
        _stencilCoverExecutor!.disposeAfterDeviceLoss();
      }
      if (_tessellatedExecutor != null && !_tessellatedExecutor!.isDisposed) {
        _tessellatedExecutor!.disposeAfterDeviceLoss();
      }
    }
    _sparseDriver?.disposeHostResources();
    _stencilCoverDriver?.disposeHostResources();
    _tessellatedDriver?.disposeHostResources();
    _context.dispose();
    _heap
      ..release(scratchNames)
      ..release(_status)
      ..release(_stringSlot)
      ..release(_log)
      ..release(_vertexStaging)
      ..release(_indexStaging)
      ..release(_pixelStaging);
  }
}

/// A render target backed by a framebuffer object.
final class GlOffscreenTarget
    with DisposableMixin
    implements RenderTarget, GlRecoverableTarget {
  GlOffscreenTarget._(this._device, MemorySurfaceDescriptor surface)
      : _surface = surface {
    _maskAtlas = GpuMaskAtlas();
    _glyphAtlas = GpuGlyphAtlas();
    _fonts = GlFontResolver();
    _images = GlImageCache(_device);
    _buildAtlasObjects();
    final BackendDiagnostic? failure = _createSurfaceObjects();
    if (failure != null) _device.state.markLost(failure);
    _device.registerTarget(this);
  }

  final GlRenderDevice _device;
  final GpuBatcher _batcher = GpuBatcher();

  late final GpuMaskAtlas _maskAtlas;
  late final GpuGlyphAtlas _glyphAtlas;
  late final GlFontResolver _fonts;
  late final GlImageCache _images;

  // Not final: a device loss destroys every one of these, and a recovery
  // rebuilds them. The sink in particular is rebuilt rather than mutated,
  // because it carries the mask and glyph texture *ids* as final fields and a
  // recreated texture has a new name - a sink that kept the old id would batch
  // every mask against a texture the driver has freed.
  late GlTexture _maskTexture;
  late GlTexture _glyphTexture;
  late GlFramebufferPool _layerPool;
  late GpuLayerStack _layers;
  late GpuRasterSink _sink;
  late DisplayListPlayer _player;
  GlVectorReplay? _vector;
  GpuVectorCommandStream<ReplayPaint, GlVectorPathPayload>? _vectorStream;
  GlVectorPathRecorder? _vectorRecorder;
  final GpuVectorSubmissionCursor _vectorCursor = GpuVectorSubmissionCursor();

  /// Creates the atlas textures and everything downstream of their ids.
  ///
  /// Shared by the constructor and by the recovery, so the two cannot drift:
  /// a rebuild that forgot the layer pool or wired the sink to a stale texture
  /// id would draw a frame that is subtly wrong rather than one that fails.
  void _buildAtlasObjects() {
    _maskTexture = _device.createTexture(
      width: _maskAtlas.width,
      height: _maskAtlas.height,
      format: GpuTextureFormat.alpha8,
      // One texel per pixel by construction, so nearest reproduces the CPU
      // rasteriser's coverage byte exactly and linear would blur it.
      filter: GpuTextureFilter.nearest,
    );
    _glyphTexture = _device.createTexture(
      width: _glyphAtlas.width,
      height: _glyphAtlas.height,
      format: GpuTextureFormat.alpha8,
      // Nearest, for the mask atlas's reason and one of its own: a glyph quad
      // is placed on whole pixels precisely so that one texel is one pixel,
      // and a linear tap would resample coverage that already sits on the
      // grid - which is the soft, muddy text a bitmap cache is blamed for.
      filter: GpuTextureFilter.nearest,
    );
    _layerPool = GlFramebufferPool(
      factory: GlDeviceFramebufferFactory(
        gl: _device._gl,
        scratchNames: _device.scratchNames,
        makeCurrent: _device.makeCurrentOrLose,
        onError: (String what) => _device.state.markLost(
          BackendDiagnostic(
            kind: DiagnosticKind.surfaceCreationFailed,
            message: 'a layer target could not be created',
            detail: what,
          ),
        ),
      ),
    );
    _layers = GpuLayerStack(
      allocator: _layerPool,
      backendName: GlRendererBackend.backendName,
      // Stencil and samples for a layer big enough that a promoted draw
      // inside it could pay for them. See `GpuLayerStack.layerAttachmentPolicy`
      // for why the answer cannot be derived from the layer's contents, and
      // `glLayerAttachmentsFor` for the size threshold.
      layerAttachmentPolicy: (int width, int height) => glLayerAttachmentsFor(
        width: width,
        height: height,
        stencilCoverEnabled: _device.experimentalStencilCoverEnabled,
      ),
    );
    final GlVectorReplay? vector = GlVectorReplay.create(
      layers: _layers,
      sparseEnabled: _device.experimentalSparseStripsEnabled,
      stencilEnabled: _device.experimentalStencilCoverEnabled,
      tessellationEnabled: _device.experimentalCpuTessellationEnabled,
      queryStencil: (int framebuffer) => _device.queryStencilCoverCapabilities(
          surfaceFramebuffer: framebuffer),
      // The framebuffer an executor will actually bind, which is the
      // multisampled one when there is one. Querying the resolve target
      // instead would report no stencil and refuse every promotion.
      surfaceFramebuffer: () => _drawFramebuffer,
      // Rebuilt with the wiring, so a device loss cannot leave a gradient
      // binding pointing at a texture name the driver already freed.
      gradientCache: GpuGradientCache(allocator: _device),
    );
    _vector = vector;
    _vectorStream = vector?.stream;
    _vectorRecorder = vector?.recorder;
    _sink = GpuRasterSink(
      batcher: _batcher,
      backendName: GlRendererBackend.backendName,
      maskAtlas: _maskAtlas,
      maskTextureId: _maskTexture.id,
      imageResolver: _images,
      glyphAtlas: _glyphAtlas,
      glyphTextureId: _glyphTexture.id,
      fontResolver: _fonts,
      layerStack: _layers,
      onAtlasFlush: _flushAtlases,
      pathPlanningTelemetry: vector?.telemetry,
      pathCommandRecorder: vector?.recorder,
    );
    _player = DisplayListPlayer(_sink);
  }

  // -------------------------------------------------------------------
  // Device-loss recovery
  // -------------------------------------------------------------------

  /// Step 5's inventory for this target, in rebuild order.
  ///
  /// The atlases come first because the sink is rebuilt with them and the
  /// surface's own objects do not depend on it; the images come last because
  /// they are the only entries whose answer can be
  /// [GpuResourceRecovery.orphaned], and a reader of a failed recovery's report
  /// should see the device's own objects accounted for before the caller's.
  @override
  Iterable<GpuRecoverableResource> recoverableResources() sync* {
    yield CallbackGpuResource.fixed(
      resourceName: 'opengl offscreen atlases '
          '(mask ${_maskAtlas.width}x${_maskAtlas.height}, glyph '
          '${_glyphAtlas.width}x${_glyphAtlas.height})',
      // A cache with no authoritative content: the mask atlas is rewritten
      // every frame from the path geometry, and the glyph atlas is
      // re-rasterised from font outlines that never left Dart.
      recovery: GpuResourceRecovery.rebuilt,
      onDiscard: _discardAtlasObjects,
      onRepopulate: _repopulateAtlasObjects,
    );
    yield CallbackGpuResource.fixed(
      resourceName: 'opengl offscreen surface '
          '${_surface.pixelWidth}x${_surface.pixelHeight}',
      recovery: GpuResourceRecovery.recreated,
      onDiscard: _forgetSurfaceObjects,
      onRepopulate: _createSurfaceObjects,
    );
    yield* _images.recoverableResources();
  }

  /// Step 3 for this target: drop the handles, draw nothing, call nothing.
  void _discardAtlasObjects() {
    // The frame in flight goes with the device. Its batches reference texture
    // names the driver has freed, and its layer targets are gone; presenting it
    // after the recovery would draw a frame recorded for a dead device.
    _batcher.beginFrame();
    _submittedBatches = 0;
    _pendingClear = null;
    _layers.endFrame();
    _layerPool.discardAfterDeviceLoss();
    // The gradient ramps go with the context. `clear` skips handles that
    // are already invalid, so this frees what survived and forgets the
    // rest; the rebuild below installs a fresh cache either way.
    _vector?.dispose();
    _device
      ..releaseTexture(_maskTexture)
      ..releaseTexture(_glyphTexture);
    // The staging bytes go with the texture: an entry that outlived it would
    // claim a glyph is resident in a texture that no longer exists.
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
    } on UnsupportedCapabilityError catch (error) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the recovered GL device refused an atlas texture',
        detail: '$error',
      );
    }
    return _device.lastError;
  }

  void _forgetSurfaceObjects() {
    // No glDeleteFramebuffers and no releaseTexture that reaches the driver:
    // both names point at memory a lost context already freed. The texture is
    // marked released so nothing draws with it, and the framebuffer name is
    // simply forgotten.
    _fbo = 0;
    _device.releaseTexture(_colorTexture);
  }

  /// How many batches of the current frame have already been drawn.
  ///
  /// Zero for a frame with no mid-frame flush, which is every frame whose
  /// atlases had room. When one does fill up, [_flushAtlases] issues what has
  /// been recorded and moves this forward, and [present] draws the rest from
  /// here - a batch drawn twice blends twice, which on a source-over fill
  /// darkens it and on a `plus` one doubles it.
  int _submittedBatches = 0;

  /// The textures this target uploaded for drawn images. Exposed so a caller
  /// that finished with a picture can drop them without disposing the target.
  GlImageCache get images => _images;

  /// The glyph coverage this target keeps between frames.
  ///
  /// Exposed for the same kind of question [layerPool] answers and for no
  /// drawing: whether the second frame of a static screen rasterised anything
  /// ([GpuGlyphAtlas.missCount]) and whether a full atlas was recycled
  /// mid-frame ([GpuGlyphAtlas.plotRecycleCount]). Both are invisible from the
  /// pixels - an atlas that re-rasterised every glyph on every frame produces
  /// identical output and spends the frame budget doing it.
  GpuGlyphAtlas get glyphAtlas => _glyphAtlas;

  /// What the dense coverage atlas has cost this target in transfers.
  ///
  /// The dense route's cost is proportional to the *area* of every shape it
  /// rasterises, and that area leaves Dart as an alpha8 upload once per frame
  /// that dirtied the atlas. Neither number is visible in the pixels - a
  /// backend uploading the whole atlas every frame draws the same picture - so
  /// preferring one route over the other has to be argued from counters like
  /// these rather than from frame time alone, which mixes in everything else
  /// the frame did. The sparse route's counterpart is
  /// `SparseStripPlanMetrics.alphaUploadBytes`.
  ///
  /// Whole rows, not sub-rectangles: `_uploadMaskAtlas` sends whole atlas rows
  /// because a narrower one costs the same number of rows once the stride is
  /// honoured.
  int get maskUploadCount => _maskUploadCount;
  int _maskUploadCount = 0;

  int get maskUploadBytes => _maskUploadBytes;
  int _maskUploadBytes = 0;

  /// The dense atlas this target rasterises coverage into, for a test that
  /// needs to know whether a shape was rasterised again or found resident.
  GpuMaskAtlas get maskAtlas => _maskAtlas;

  /// `glTexSubImage2D` calls this target has made for glyph coverage.
  ///
  /// The number the incremental-upload claim rests on. A second frame drawing
  /// the text of the first must not increase it: nothing was written, so
  /// nothing is dirty, so there is nothing to send. Counted per *region*, not
  /// per frame or per glyph, because the region is what the driver is asked
  /// for - see [_uploadGlyphAtlas].
  int get glyphUploadCount => _glyphUploadCount;
  int _glyphUploadCount = 0;

  /// Where layers get their offscreen targets.
  ///
  /// Exposed for two things and neither is drawing: a memory report, and a
  /// test that asserts the same layer drawn on ten frames created one
  /// framebuffer. Reuse is invisible from the pixels - a pool that allocated
  /// per frame would produce identical output and a stuttering frame time.
  GlFramebufferPool get layerPool => _layerPool;

  /// The layer stack this target's sink drives, for a caller that wants to
  /// know how deep a frame went or how many passes it cost.
  GpuLayerStack get layers => _layers;

  /// Accepted automatic B commands in the current frame (opt-in devices).
  int get experimentalVectorCommandCount =>
      _vectorStream?.vectorCommandCount ?? 0;
  int get experimentalVectorAcceptedCount =>
      _vectorRecorder?.acceptedCount ?? 0;

  /// The strategy that really owned the pixels of the last observed path.
  ///
  /// Null when nothing was observed or the device runs no experimental
  /// executor. Exposed because "this path took route C" is otherwise invisible
  /// from the pixels - and a test that only compared pixels would pass just as
  /// happily if every promotion had silently fallen back to the dense atlas,
  /// which is exactly the regression worth catching.
  GpuPathStrategy? get lastExecutedPathStrategy =>
      _vector?.telemetry.lastEvent?.executedStrategy;

  /// The candidate the selector proposed for that same path, which differs
  /// from [lastExecutedPathStrategy] whenever a recorder refused it.
  GpuPathStrategy? get lastCandidatePathStrategy =>
      _vector?.telemetry.lastEvent?.candidate.strategy;

  /// Where this target's gradient ramps live, or null when it has no executor
  /// that can sample one.
  ///
  /// Exposed for the question pixels cannot answer: whether the second draw of
  /// the same gradient uploaded a second ramp. A cache that missed every time
  /// produces an identical image and spends the frame budget doing it.
  GpuGradientCache? get gradientCache => _vector?.gradientCache;

  /// The sparse encodings this target retains between draws and frames.
  ///
  /// Exposed for the question pixels cannot answer: whether the second frame
  /// of a static scene rasterised its coverage again. A cache that missed
  /// every time draws an identical picture and spends the frame budget doing
  /// it - see `vector_plan_cache.dart`.
  VectorPlanCache<SparseStripDrawPlan>? get sparsePlanCache =>
      _vector?.recorder.sparsePlanCache;

  /// How often this target has seen each draw come back, which is what keeps
  /// a promoted route from starving the dense atlas it competes with.
  GpuPathRepetitionTracker? get pathRepetition => _vector?.repetition;

  MemorySurfaceDescriptor _surface;
  late GlTexture _colorTexture;
  int _fbo = 0;

  /// The multisampled draw framebuffer and its colour renderbuffer, or 0 when
  /// this target draws straight into [_fbo]. See [_attachStencilIfRequested].
  int _multisampleFbo = 0;
  int _multisampleColor = 0;

  /// The stencil buffer, attached to the multisampled framebuffer when there
  /// is one and to [_fbo] otherwise. Zero on a colour-only target.
  int _stencilRenderbuffer = 0;

  /// What [_fbo] carries, declared to the layer stack at [beginFrame] so a
  /// per-draw strategy decision reads a fact instead of a global assumption.
  GpuPassAttachments _surfaceAttachments = GpuPassAttachments.colorOnly;

  /// Exposed so a test can assert this target really is what it claims: an
  /// attachment nothing verified is exactly the kind of claim that lets a
  /// stencil pass run against a framebuffer with no stencil.
  GpuPassAttachments get surfaceAttachments => _surfaceAttachments;

  /// The framebuffer object this target's passes draw into, so a test can ask
  /// the *driver* what it carries rather than believing [surfaceAttachments].
  ///
  /// The multisampled one when there is one - that is the framebuffer the
  /// descriptor describes and the one an executor binds. [_fbo], which holds
  /// the single-sample texture the pixels are resolved into, carries no
  /// stencil and would answer the question about the wrong object.
  ///
  /// Not for drawing: nothing outside this file binds it.
  int get debugFramebuffer => _drawFramebuffer;

  late Framebuffer _readback;
  int _generation = 0;

  /// The loss count the generation already accounts for, so a device lost
  /// twice bumps the generation twice and no more.
  int _observedLossCount = 0;

  /// The last pixels read back. Golden tests read this after [present].
  Framebuffer get framebuffer => _readback;

  GpuBatcher get batcher => _batcher;

  @override
  NativeSurfaceDescriptor get surface => _surface;

  @override
  int get generation {
    final losses = _device.state.lossCount;
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
    // Advances the frame counter the glyph atlas's LRU compares against, and
    // keeps every glyph. Skipping it would leave every plot looking used by
    // the frame in progress, so nothing could ever be evicted and the atlas
    // would report itself permanently full - see gpu_glyph_atlas.dart.
    _glyphAtlas.beginFrame();
    _layers.beginFrame(
      surfaceWidth: _readback.width,
      surfaceHeight: _readback.height,
      surfaceAttachments: _surfaceAttachments,
    );
    _vector?.beginFrame();
    _vectorCursor.reset();
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

  int? _pendingClear;

  @override
  Future<PresentResult> present(Frame frame) async {
    throwIfDisposed();
    final blocked = _device.state.blockedPresent();
    if (blocked != null) return blocked;
    if (frame.generation != generation) {
      return const PresentResult(
        status: PresentStatus.stale,
        diagnostic: BackendDiagnostic.note(
          'frame belonged to a previous generation of the target',
        ),
      );
    }

    // Binding a framebuffer through a context that is not current writes into
    // whichever context *is*, which on a shared-GPU machine is another
    // application's. So the result is checked before anything is bound.
    if (!_device.makeCurrentOrLose()) {
      return _device.state.blockedPresent() ??
          const PresentResult(
            status: PresentStatus.deviceLost,
            diagnostic: BackendDiagnostic(
              kind: DiagnosticKind.connectionFailed,
              message: 'the GL context could not be made current to present',
            ),
          );
    }
    _device._gl.bindFramebuffer(glFramebuffer, _drawFramebuffer);
    _uploadMaskAtlas();
    _uploadGlyphAtlas();

    final int? clear = _pendingClear;
    _pendingClear = null;
    final vectorStream = _vectorStream;
    final bool drawn;
    if (vectorStream == null) {
      drawn = _device.submit(
        _batcher,
        _readback.width,
        _readback.height,
        clear,
        layers: _layers,
        surfaceFramebuffer: _drawFramebuffer,
        firstBatch: _submittedBatches,
      );
    } else {
      vectorStream.finish(totalBatchCount: _batcher.batchCount);
      drawn = _device.submitOrderedPaths(
        _batcher,
        vectorStream,
        _vectorCursor,
        _readback.width,
        _readback.height,
        clear,
        surfaceFramebuffer: _drawFramebuffer,
      );
    }
    _submittedBatches = _batcher.batchCount;
    // After the draws and never before: until they are issued, the composite
    // quads are still going to sample those layer textures.
    _layers.endFrame();
    if (drawn) {
      // After every pass and before the readback: the samples only become a
      // readable, sampleable image once they are resolved.
      _resolveMultisample();
      _device._readPixels(_readback);
    }

    final lost = _device.state.blockedPresent();
    if (lost != null) return lost;
    return const PresentResult(status: PresentStatus.presented);
  }

  /// Uploads what the frame's masks wrote, over whole rows.
  ///
  /// Whole rows because a narrower sub-rectangle would upload the same number
  /// of rows anyway once the stride is honoured, and the atlas is dirty in
  /// bands rather than columns.
  void _uploadMaskAtlas() {
    if (!_maskAtlas.isDirty) return;
    final top = _maskAtlas.dirtyTop;
    final height = _maskAtlas.dirtyBottom - top;
    _maskUploadCount++;
    _maskUploadBytes += _maskAtlas.width * height;
    _device.uploadRegion(
      _maskTexture,
      x: 0,
      y: top,
      width: _maskAtlas.width,
      height: height,
      pixels: Uint8List.sublistView(
        _maskAtlas.pixels,
        top * _maskAtlas.width,
      ),
      bytesPerRow: _maskAtlas.width,
    );
    _maskAtlas.markUploaded();
  }

  /// Sends the plots the frame wrote into, and nothing else.
  ///
  /// ## Why this is per region and not one upload
  ///
  /// The glyph atlas outlives the frame - that is the whole reason it is not
  /// the mask atlas - so on a static screen the honest amount of data to move
  /// is *zero*, and a full-texture upload would move a megabyte instead. The
  /// atlas therefore hands out one rectangle per plot it wrote into, and each
  /// becomes one `glTexSubImage2D`. Per plot rather than per glyph because a
  /// driver call costs more than the untouched texels in between, and per plot
  /// rather than per atlas because two glyphs admitted into opposite corners
  /// would otherwise union into the whole thing.
  ///
  /// ## Orientation, declared
  ///
  /// The atlas is **uploaded**, not rendered into, so [kYFlipTopDown] has
  /// nothing to do with it: that uniform exists for a pass whose *output*
  /// lands in a texture something else samples, and it inverts the projection
  /// of the geometry being drawn. Here the texels are handed to the driver
  /// directly. `glTexSubImage2D` writes the first row of the pointer it is
  /// given at texture row `y`, and [GpuGlyphAtlas.pixels] is row-major
  /// top-down like every mask this renderer produces, so atlas row `y` is
  /// texture row `y` is texture coordinate `y / height` - which is exactly the
  /// `v` `gpu_raster_sink.dart` computes for the top edge of a glyph's quad.
  /// Top edge to top row: the coverage comes out the way it was rasterised.
  ///
  /// This is the same convention `_uploadMaskAtlas` above has always used, and
  /// it is stated rather than inherited because getting it wrong draws text
  /// upside down or mirrored, and the failure hides: Ahem's glyphs are solid
  /// squares, so the test that would notice has to use a face whose glyphs are
  /// asymmetric.
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
        // A view, not a copy: `uploadRegion` repacks rows into its own staging
        // buffer anyway, and this is the offset of the region's first texel.
        pixels: Uint8List.sublistView(_glyphAtlas.pixels, y * width + x),
        bytesPerRow: width,
      );
    });
    _glyphAtlas.markUploaded();
  }

  /// The backend's half of the atlas flush protocol - see
  /// [GpuRasterSink.onAtlasFlush] for the whole of it and for why the order
  /// below is the only safe one.
  ///
  /// Upload first: the batches about to be drawn sample texels this frame
  /// wrote, which so far exist only in the atlas's staging image. Submit
  /// second, and remember how far it got, because the sink is about to hand
  /// those texels to a different mask and the rest of the frame is drawn from
  /// [_submittedBatches] afterwards.
  ///
  /// The clear travels with the *first* submission of a frame, whichever one
  /// that is, so a frame whose atlas filled up before its first present still
  /// starts from the requested background instead of the last frame's pixels.
  /// Both atlases are uploaded, not just the one that ran out: the sink closed
  /// its open batch before calling this, and the batches about to be issued
  /// may sample a glyph *and* a mask this frame wrote. The sink calls
  /// `markUploaded` on both afterwards, which the two methods below have
  /// already done - it is idempotent, and doing it here as well is what makes
  /// each of them correct when called from [present] too.
  void _flushAtlases() {
    _uploadMaskAtlas();
    _uploadGlyphAtlas();
    final int? clear = _pendingClear;
    _pendingClear = null;
    final vectorStream = _vectorStream;
    if (vectorStream == null) {
      _device.submit(
        _batcher,
        _readback.width,
        _readback.height,
        clear,
        layers: _layers,
        surfaceFramebuffer: _drawFramebuffer,
        firstBatch: _submittedBatches,
      );
    } else {
      vectorStream.snapshot(totalBatchCount: _batcher.batchCount);
      _device.submitOrderedPaths(
        _batcher,
        vectorStream,
        _vectorCursor,
        _readback.width,
        _readback.height,
        clear,
        surfaceFramebuffer: _drawFramebuffer,
      );
    }
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
    if (failure != null) _device.state.markLost(failure);
  }

  /// Rasterises [list] into this target and presents it.
  ///
  /// Mirrors [MemoryRenderTarget.renderDisplayList] argument for argument, so
  /// a golden test can swap one for the other and compare.
  Future<PresentResult> renderDisplayList(
    DisplayList list, {
    int? clearColor,
    Transform2D deviceTransform = Transform2D.identity,
  }) async {
    final frame = beginFrame(FrameRequest(clearColor: clearColor));
    // The sink is handed a font *id* and resolves it through the same resource
    // table the player walks, so the two cannot disagree about which face an
    // id names. Bound per list rather than per target because a target draws
    // whatever list it is given.
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
      // The application's per-subtree advice, carried beside the op stream so
      // that a list encoded with it is byte for byte the list encoded without
      // it. `GpuRasterSink` is the only sink here that reads it; every other
      // consumer is unable to tell the difference. See `content_hint.dart`.
      contentHints: list.contentHints,
    );
    return present(frame);
  }

  /// Allocates the readback buffer, the colour texture and the FBO.
  ///
  /// Returns a diagnostic instead of marking the device lost, because it is
  /// called from two places that want opposite things: the constructor and
  /// [resize] turn a failure into a loss, and a *recovery* must not - a
  /// recovery that marked the device lost again would be indistinguishable
  /// from a second GPU reset and would burn one of the policy's attempts on
  /// its own bug.
  BackendDiagnostic? _createSurfaceObjects() {
    _readback = Framebuffer.allocate(
      width: _surface.pixelWidth,
      height: _surface.pixelHeight,
      format: _surface.format,
    );
    try {
      _colorTexture = _device.createTexture(
        width: _surface.pixelWidth,
        height: _surface.pixelHeight,
        format: GpuTextureFormat.rgba8888Premultiplied,
      );
    } on UnsupportedCapabilityError catch (error) {
      return BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'the device refused the offscreen colour texture',
        detail: '$error',
      );
    }
    final gl = _device._gl;
    gl.genFramebuffers(1, _device.scratchNames);
    _fbo = _device.scratchNames[0];
    gl
      ..bindFramebuffer(glFramebuffer, _fbo)
      ..framebufferTexture2D(
          glFramebuffer, glColorAttachment0, glTexture2D, _colorTexture.id, 0);
    _attachStencilIfRequested();
    final status = gl.checkFramebufferStatus(glFramebuffer);
    if (status != glFramebufferComplete) {
      return BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'the offscreen framebuffer is incomplete',
        detail: 'glCheckFramebufferStatus returned '
            '0x${status.toRadixString(16)} for '
            '${_surface.pixelWidth}x${_surface.pixelHeight}',
      );
    }
    _device.checkError('framebuffer creation');
    return _device.lastError;
  }

  /// Gives this target's framebuffer a stencil buffer when approach C is
  /// enabled, and declares what it ended up with.
  ///
  /// The default framebuffer of a hidden GL context routinely has neither
  /// stencil nor samples - it is measured as having neither on the Intel UHD
  /// this was written against - so a stencil-then-cover executor that only
  /// ever saw framebuffer 0 could never be exercised, and the pass descriptor
  /// would honestly report "colour-only" forever. This target *creates* its
  /// framebuffer, so it can create one that carries stencil, and then the
  /// attachments it declares are a fact rather than a hope.
  ///
  /// ## Multisampled, and why that is the whole point
  ///
  /// A filled path in this renderer is analytically antialiased on every
  /// route: the CPU rasteriser, the dense atlas and the sparse encoder all
  /// take their coverage from one `ScanlineFiller`. A **one-sample** cover
  /// pass produces a binary edge instead, measured at 144 levels of difference
  /// over 572 boundary pixels, which is why `gl_vector_replay.dart` refuses
  /// approach C below four samples. Creating the samples here is what makes
  /// that capability reachable instead of permanently theoretical.
  ///
  /// So [_fbo] keeps the single-sample colour texture and becomes the
  /// **resolve** target, and a second framebuffer with multisampled colour and
  /// stencil renderbuffers becomes what the frame actually draws into. One
  /// `glBlitFramebuffer` at the end of [present] moves the pixels across; see
  /// [_resolveMultisample] for why it cannot be skipped.
  ///
  /// Every step is checked, and every failure falls back rather than raising:
  /// a driver with no `GL_MAX_SAMPLES` of four, or one that reports the
  /// framebuffer incomplete, leaves the target single-sample stencil8 - or
  /// colour-only if even that fails. The target then declares what it really
  /// has, the selector believes it, and those paths go through the dense
  /// atlas exactly as before. Nothing here can make a frame fail to render.
  void _attachStencilIfRequested() {
    _surfaceAttachments = GpuPassAttachments.colorOnly;
    if (!_device.experimentalStencilCoverEnabled) return;
    final gl = _device._gl;
    if (!GlDeviceFramebufferFactory.supportsAttachments(gl)) return;
    if (_createMultisampleTarget(gl)) return;
    // Single-sample stencil8 on the resolve framebuffer itself. Enough for an
    // explicit approach-C caller to bind, not enough for the selector to
    // promote into - which is the truthful pair of facts.
    _device.scratchNames[0] = 0;
    gl.genRenderbuffers(1, _device.scratchNames);
    final int renderbuffer = _device.scratchNames[0];
    if (renderbuffer == 0) return;
    gl
      ..bindFramebuffer(glFramebuffer, _fbo)
      ..bindRenderbuffer(glRenderbuffer, renderbuffer)
      ..renderbufferStorage(
        glRenderbuffer,
        glStencilIndex8,
        _surface.pixelWidth,
        _surface.pixelHeight,
      )
      ..framebufferRenderbuffer(
        glFramebuffer,
        glStencilAttachment,
        glRenderbuffer,
        renderbuffer,
      );
    if (gl.checkFramebufferStatus(glFramebuffer) != glFramebufferComplete) {
      _device.scratchNames[0] = renderbuffer;
      gl.deleteRenderbuffers(1, _device.scratchNames);
      gl.getError();
      return;
    }
    _stencilRenderbuffer = renderbuffer;
    _surfaceAttachments = const GpuPassAttachments(stencilBits: 8);
  }

  /// Builds the multisampled draw framebuffer, or reports that it could not.
  ///
  /// False leaves nothing behind: every object created on the way is deleted
  /// and the GL error queue is drained, because a sticky error picked up by an
  /// unrelated `checkError` later is what turns a failed *optional* allocation
  /// into a device this backend believes is lost. See
  /// `gl_stencil_cover_driver.dart` for the measured instance of that.
  bool _createMultisampleTarget(GlApi gl) {
    _device.scratchNames[0] = 0;
    gl.getIntegerv(glMaxSamples, _device.scratchNames.cast<Int32>());
    final int maxSamples = _device.scratchNames.cast<Int32>()[0];
    if (maxSamples < _minimumSampleCount) {
      gl.getError();
      return false;
    }
    // As many samples as the driver offers, up to the cap. The count is not a
    // constant because it is the only lever this route has on edge quality:
    // coverage from N samples takes N+1 values, so the gap against the
    // analytic routes shrinks as 1/N. It is measured, not assumed - see the
    // deviation table in `doc/architecture/ACELERACAO_GPU_VETORIAL.md`.
    final int samples =
        maxSamples < _preferredSampleCount ? maxSamples : _preferredSampleCount;

    final int drawFbo = _genName(gl.genFramebuffers);
    final int colour = _genName(gl.genRenderbuffers);
    final int stencil = _genName(gl.genRenderbuffers);
    if (drawFbo == 0 || colour == 0 || stencil == 0) {
      _deleteMultisampleObjects(drawFbo, colour, stencil);
      gl.getError();
      return false;
    }

    final int width = _surface.pixelWidth;
    final int height = _surface.pixelHeight;
    gl
      ..bindFramebuffer(glFramebuffer, drawFbo)
      ..bindRenderbuffer(glRenderbuffer, colour)
      ..renderbufferStorageMultisample(
        glRenderbuffer,
        samples,
        glRgba8,
        width,
        height,
      )
      ..framebufferRenderbuffer(
        glFramebuffer,
        glColorAttachment0,
        glRenderbuffer,
        colour,
      )
      ..bindRenderbuffer(glRenderbuffer, stencil)
      ..renderbufferStorageMultisample(
        glRenderbuffer,
        samples,
        glStencilIndex8,
        width,
        height,
      )
      ..framebufferRenderbuffer(
        glFramebuffer,
        glStencilAttachment,
        glRenderbuffer,
        stencil,
      );

    final bool complete =
        gl.checkFramebufferStatus(glFramebuffer) == glFramebufferComplete;
    // Restored before anything can observe it, and before the completeness
    // result is acted on: `_createSurfaceObjects` checks `_fbo` next and would
    // otherwise be checking whichever framebuffer this left bound.
    gl.bindFramebuffer(glFramebuffer, _fbo);
    if (!complete || gl.getError() != glNoError) {
      _deleteMultisampleObjects(drawFbo, colour, stencil);
      gl.getError();
      gl.bindFramebuffer(glFramebuffer, _fbo);
      return false;
    }

    _multisampleFbo = drawFbo;
    _multisampleColor = colour;
    _stencilRenderbuffer = stencil;
    _surfaceAttachments = GpuPassAttachments(
      stencilBits: 8,
      sampleCount: samples,
    );
    return true;
  }

  /// Copies the multisampled draw buffer into the sampleable colour texture.
  ///
  /// Called once per present, after every pass and before the readback.
  /// `glReadPixels` cannot read a multisample renderbuffer at all, so without
  /// this the readback returns nothing usable - and the composite of a layer
  /// samples a texture, which a multisample renderbuffer is not.
  ///
  /// Both bindings are set explicitly and the single framebuffer binding is
  /// restored afterwards, so a caller that had its own read framebuffer bound
  /// does not find this one in its place.
  void _resolveMultisample() {
    if (_multisampleFbo == 0) return;
    final gl = _device._gl;
    gl
      ..bindFramebuffer(glReadFramebuffer, _multisampleFbo)
      ..bindFramebuffer(glDrawFramebuffer, _fbo)
      ..blitFramebuffer(
        0,
        0,
        _readback.width,
        _readback.height,
        0,
        0,
        _readback.width,
        _readback.height,
        glColorBufferBit,
        glNearest,
      )
      ..bindFramebuffer(glFramebuffer, _fbo);
  }

  /// The framebuffer this frame's passes draw into: the multisampled one when
  /// there is one, and the resolve target otherwise.
  int get _drawFramebuffer => _multisampleFbo != 0 ? _multisampleFbo : _fbo;

  int _genName(void Function(int, Pointer<Uint32>) generate) {
    _device.scratchNames[0] = 0;
    generate(1, _device.scratchNames);
    return _device.scratchNames[0];
  }

  void _deleteMultisampleObjects(int fbo, int colour, int stencil) {
    final gl = _device._gl;
    if (fbo != 0) {
      _device.scratchNames[0] = fbo;
      gl.deleteFramebuffers(1, _device.scratchNames);
    }
    for (final int name in <int>[colour, stencil]) {
      if (name == 0) continue;
      _device.scratchNames[0] = name;
      gl.deleteRenderbuffers(1, _device.scratchNames);
    }
  }

  /// Four: what `StencilCoverRequirements.forDraw` demands of an antialiased
  /// cover pass, and the minimum every GL 3.3 driver must support for RGBA8.
  /// Below this the selector refuses approach C outright.
  static const int _minimumSampleCount = 4;

  /// Sixteen, taken when the driver offers it - the Intel UHD this was
  /// measured against does.
  ///
  /// The count is the only lever a cover pass has on edge quality: coverage
  /// from N samples takes N+1 values, so the gap against the analytic routes
  /// shrinks as 1/N. The cap is memory rather than quality - multisampled
  /// colour plus stencil cost about `samples * 5` bytes per pixel, so 16x on a
  /// 4K surface is around 660 MiB and stops being a sensible default long
  /// before it stops improving edges. At the sizes this target is used at -
  /// offscreen readback, golden tests, image export - it is a few megabytes.
  static const int _preferredSampleCount = 16;

  void _destroySurfaceObjects() {
    if (!_device.state.isLost) {
      if (_fbo != 0) {
        _device.scratchNames[0] = _fbo;
        _device._gl.deleteFramebuffers(1, _device.scratchNames);
      }
      _deleteMultisampleObjects(
        _multisampleFbo,
        _multisampleColor,
        _stencilRenderbuffer,
      );
    }
    _multisampleFbo = 0;
    _multisampleColor = 0;
    _stencilRenderbuffer = 0;
    _surfaceAttachments = GpuPassAttachments.colorOnly;
    _fbo = 0;
    _device.releaseTexture(_colorTexture);
  }

  @override
  void onDispose() {
    _device.unregisterTarget(this);
    _destroySurfaceObjects();
    _images.clear();
    // After endFrame has returned every target: the pool only deletes what is
    // idle, so disposing mid-frame would leak the ones still in flight.
    _layers.endFrame();
    _layerPool.dispose();
    _vector?.dispose();
    _device
      ..releaseTexture(_maskTexture)
      ..releaseTexture(_glyphTexture);
    // The staging bytes go with the texture: keeping the entries would say a
    // glyph is resident in a texture that no longer exists.
    _glyphAtlas.clear();
    _fonts.bind(null);
  }
}

/// Turns the display list's interned font ids into faces for the sink.
///
/// The sink is handed a raw `fontId` because the player never asks what a
/// glyph looks like - see [ReplayResources.fontAt] - so somebody who *does*
/// have to rasterise has to be able to look one up. That somebody is a target,
/// and the table it looks it up in is the one the player is walking, which is
/// why this holds a [ReplayResources] rather than a map of its own: a second
/// table would be a second answer to "what is font 3", and the two would
/// disagree the first time a list was replayed with different resources.
///
/// [bind] is called before each play and with null on dispose. An unbound
/// resolver answers null, which the sink turns into a named refusal rather
/// than a wrong face - and that is the honest answer, because a font id means
/// nothing without the list that interned it.
final class GlFontResolver implements GpuFontResolver {
  ReplayResources? _resources;

  /// Points this resolver at the table [resources] ids belong to, or at
  /// nothing when it is null.
  void bind(ReplayResources? resources) => _resources = resources;

  @override
  ScaledTypeface? resolveFont(int fontId) {
    final ReplayResources? resources = _resources;
    if (resources == null) return null;
    final Object font = resources.fontAt(fontId);
    // Not a cast: the display list stores a font as an opaque `Object`, and a
    // list built by something that interned another kind of face must be
    // refused by name rather than crash with a type error in the middle of a
    // frame.
    return font is ScaledTypeface ? font : null;
  }
}

/// One image this cache uploaded, and whether it could do it again.
final class _GlImageEntry {
  _GlImageEntry({
    required this.index,
    required this.image,
    required this.width,
    required this.height,
    required this.texture,
    required this.source,
  });

  /// Weak, and only so [GlImageCache.clear] can undo the [Expando]
  /// association: an entry left behind in the expando would answer a later
  /// `resolve` with "no texture and no source", which reads as an orphaned
  /// image rather than as a cache that was emptied on purpose.
  final WeakReference<Framebuffer> image;

  /// Position in the cache's insertion order. Part of the resource name, so a
  /// diagnostic identifies *which* image could not be restored.
  final int index;
  final int width;
  final int height;

  /// Null once the device that made it was lost, or once it was released.
  GlTexture? texture;

  /// The bytes, or null when the retention policy dropped them.
  Framebuffer? source;

  bool get isRecoverable => source != null;

  String get name => 'opengl image #$index (${width}x$height)';
}

/// Uploads drawn images into textures, once each, and can do it again.
///
/// `GpuRasterSink` asks for one of these. The display list interns an image as
/// an opaque `Object`; the CPU renderer fixes what that object is (a
/// [Framebuffer]), and agreeing with it here is what lets one display list be
/// drawn by either backend and compared.
///
/// ## Lookup is weak, retention is explicit
///
/// The cache used to be a `Map<Object, GlTexture>.identity()`, which conflated
/// two things: finding the texture for an image, and keeping the image alive.
/// The map key did both, so "drop the source to save memory" was not
/// expressible - the key would have gone on holding it.
///
/// So the lookup is an [Expando], whose keys are weak and hold nothing, and the
/// retention is a field on the entry. [GpuImageSourceRetention.retain] holds
/// the source and the texture comes back after a device loss;
/// [GpuImageSourceRetention.uploadOnly] does not and it cannot. [dropSource]
/// makes the same trade for one image after the fact, for a caller that
/// uploaded a large bitmap and has decided it will never need to re-upload it.
///
/// The entry list never evicts, exactly as before: an eviction policy needs a
/// frame budget this framework does not measure yet, and a wrong one is worse
/// than none because it re-uploads the image being animated. [clear] is the
/// escape hatch, and the target calls it on dispose.
final class GlImageCache implements GpuImageResolver {
  GlImageCache(
    this._device, {
    this.retention = GpuImageSourceRetention.retain,
  });

  final GlRenderDevice _device;

  /// What happens to an image's bytes after it is uploaded. See the enum for
  /// the memory cost of each answer.
  final GpuImageSourceRetention retention;

  /// Weak-keyed, so the cache's lookup structure holds no image alive. The
  /// strong reference, when there is one, is [_GlImageEntry.source].
  final Expando<_GlImageEntry> _byImage = Expando<_GlImageEntry>();

  final List<_GlImageEntry> _entries = <_GlImageEntry>[];

  /// How many entries are held. For tests and for a memory report.
  int get length => _entries.length;

  /// How many bytes of image source this cache is keeping alive.
  ///
  /// The number the retention policy is about. Zero under
  /// [GpuImageSourceRetention.uploadOnly].
  int get retainedSourceBytes {
    var bytes = 0;
    for (final _GlImageEntry entry in _entries) {
      if (entry.source != null) bytes += entry.width * entry.height * 4;
    }
    return bytes;
  }

  /// Entries whose source is gone, so a device loss would strand them.
  int get unrecoverableCount =>
      _entries.where((_GlImageEntry e) => !e.isRecoverable).length;

  @override
  GpuTextureHandle? resolve(Object image) {
    if (image is! Framebuffer) return null;
    final _GlImageEntry? cached = _byImage[image];
    if (cached != null) {
      final GlTexture? texture = cached.texture;
      if (texture != null && texture.isValid) return texture;
      if (!cached.isRecoverable) {
        // The honest refusal. The texture died with the device and the bytes
        // that made it are gone, so there is nothing to upload. Null is the
        // sink's "this device cannot draw it", which becomes a named error.
        return null;
      }
    }

    final GlTexture? texture = _upload(image);
    if (texture == null) return null;
    if (cached != null) {
      cached.texture = texture;
      return texture;
    }
    final entry = _GlImageEntry(
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

  GlTexture? _upload(Framebuffer image) {
    final GlTexture texture;
    try {
      texture = _device.createTexture(
        width: image.width,
        height: image.height,
        format: GpuTextureFormat.rgba8888Premultiplied,
        // Linear, unlike the mask atlas: an image is drawn at whatever scale
        // the layout produced, and nearest sampling there is the blocky,
        // shimmering resampling that reads as a renderer bug.
        filter: GpuTextureFilter.linear,
      );
    } on UnsupportedCapabilityError {
      // Larger than the device allows. Null is the sink's "this device cannot
      // draw it", which becomes a named error rather than a dead texture.
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

  /// Forgets the bytes of [image] while keeping its texture.
  ///
  /// The escape hatch for the memory cost [GpuImageSourceRetention.retain]
  /// documents, and the reason a resource can be genuinely unrecoverable in
  /// this renderer rather than only in theory. After this call the texture goes
  /// on drawing exactly as before - and a device loss strands it, because there
  /// is no second copy of the pixels anywhere.
  ///
  /// Returns false when [image] was never uploaded here.
  bool dropSource(Object image) {
    if (image is! Framebuffer) return false;
    final _GlImageEntry? entry = _byImage[image];
    if (entry == null) return false;
    entry.source = null;
    return true;
  }

  /// This cache's contribution to step 5's inventory: one resource per image.
  ///
  /// Per image and not one for the whole cache, because the answer differs per
  /// image: one entry with its source is [GpuResourceRecovery.reuploaded] while
  /// the one next to it is [GpuResourceRecovery.orphaned], and a single
  /// resource for the cache could only report the pessimistic answer for both.
  Iterable<GpuRecoverableResource> recoverableResources() sync* {
    for (final _GlImageEntry entry in List<_GlImageEntry>.of(_entries)) {
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
          final GlTexture? texture = _upload(source);
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

  /// Releases every texture and forgets every source. The next [resolve]
  /// re-uploads from whatever the caller still holds.
  void clear() {
    for (final _GlImageEntry entry in _entries) {
      final GlTexture? texture = entry.texture;
      if (texture != null) _device.releaseTexture(texture);
      entry.texture = null;
      entry.source = null;
      final Framebuffer? image = entry.image.target;
      if (image != null) _byImage[image] = null;
    }
    _entries.clear();
  }

  /// The image's bytes in the RGBA order `glTexImage2D` was told to expect.
  ///
  /// `GL_BGRA` as an upload format is desktop GL only and this renderer also
  /// targets GLES, so a BGRA framebuffer is swizzled here instead of being
  /// handed to the driver. Rows are repacked at the same time, because a
  /// [Framebuffer] wrapping a platform surface routinely has a stride wider
  /// than its width.
  static Uint8List _asRgba(Framebuffer image) {
    final packed = Uint8List(image.width * image.height * 4);
    final swizzle = image.format == PixelFormat.bgra8888Premultiplied;
    for (var y = 0; y < image.height; y++) {
      final source = y * image.bytesPerRow;
      final destination = y * image.width * 4;
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
        final s = source + x * 4;
        final d = destination + x * 4;
        packed[d] = image.pixels[s + 2];
        packed[d + 1] = image.pixels[s + 1];
        packed[d + 2] = image.pixels[s];
        packed[d + 3] = image.pixels[s + 3];
      }
    }
    return packed;
  }
}

/// The OpenGL renderer backend.
final class GlRendererBackend implements RendererBackend {
  const GlRendererBackend();

  static const String backendName = 'opengl';

  @override
  RendererInfo get info => const RendererInfo(
        name: backendName,
        deviceDescription: 'OpenGL via EGL, offscreen framebuffer objects',
        rasterizationApproach: RasterizationApproach.analyticCoverageAtlas,
      );

  /// Both descriptors this backend knows how to build a target for.
  ///
  /// [GlWindowSurfaceDescriptor] is included even though [probe] on this
  /// machine may not be able to *create* one: the two questions are different.
  /// This one is "given such a surface, could you present to it", and the
  /// answer is yes on every platform where a GL context exists, because the
  /// descriptor carries its own [GlSwapChain]. Whether a window can be made in
  /// the first place is the windowing backend's question, not the renderer's.
  @override
  bool supportsSurface(NativeSurfaceDescriptor surface) =>
      surface is MemorySurfaceDescriptor ||
      surface is GlWindowSurfaceDescriptor;

  /// Whether OpenGL can run here, and if not, exactly what was missing.
  ///
  /// Never throws - not for a missing library, not for a driver that returns
  /// nonsense, not for a bug in this file. Section 6.6 exists because a
  /// silent fallback is indistinguishable from a backend nobody tried, and a
  /// probe that throws is worse than one that lies: it takes the whole
  /// selection down with it.
  @override
  BackendProbeResult probe() {
    try {
      return _probe();
    } on Object catch (error, stack) {
      return BackendProbeResult.unsupported(
        backendName,
        BackendDiagnostic(
          kind: DiagnosticKind.unsupportedPlatform,
          message: 'the OpenGL probe threw, which is a bug in the probe',
          detail: '$error\n$stack',
        ),
      );
    }
  }

  BackendProbeResult _probe() {
    final load = GlLibrary.open();
    if (!load.isLoaded) {
      return BackendProbeResult.unsupported(
        backendName,
        BackendDiagnostic.missingLibrary(
          load.attempted.join(', '),
          detail: load.error,
        ),
      );
    }

    // What this machine can do about *windows*, asked before a context is
    // created because the answer does not depend on one and because it must
    // appear in the report even when no context could be made at all. This is
    // the part that used to lie: the old probe hard-coded "offscreen only" no
    // matter what the machine offered.
    final windowing = GlContextFactory.probeWindowPresentation();

    // A context comes first, and the symbol check second. That order is
    // forced by Windows, where a driver's entry points do not exist as
    // symbols at all until a context is current - checking the export table
    // first would report forty missing functions on a machine with a working
    // OpenGL 4.6. It is also the more honest order everywhere else: a driver
    // can export every symbol and still have no device behind it, which is
    // what a container with Mesa installed but no DRM node is.
    final attempt = const GlContextFactory()
        .create(width: 16, height: 16, glLibrary: load.library!);
    final context = attempt.context;
    if (context == null) {
      return BackendProbeResult(
        backendName: backendName,
        supported: false,
        diagnostics: <BackendDiagnostic>[
          ...attempt.diagnostics,
          windowing.diagnostic,
        ],
      );
    }

    try {
      return describeContext(
        context,
        <BackendDiagnostic>[...attempt.diagnostics, windowing.diagnostic],
        windowing.available,
      );
    } finally {
      context.dispose();
    }
  }

  /// What a live context reports about itself, as a probe result.
  ///
  /// Public because the Windows path creates its context elsewhere - a WGL
  /// context needs a window, and windows live in `lib/src/backends` - and
  /// then wants exactly this report about it.
  ///
  /// [windowPresentation] overrides what the context says about itself, for
  /// the caller that knows more than the context does. The pbuffer probe uses
  /// it to report that *the machine* can present to a window even though the
  /// throwaway context it created cannot, which is the difference between
  /// "this machine has no GPU presentation" and "the probe did not ask for
  /// any". Null means "believe the context", which is what the Windows path
  /// wants.
  static BackendProbeResult describeContext(
    GlContext context, [
    List<BackendDiagnostic> prior = const <BackendDiagnostic>[],
    bool? windowPresentation,
  ]) {
    if (!context.makeCurrent()) {
      return BackendProbeResult(
        backendName: backendName,
        supported: false,
        diagnostics: <BackendDiagnostic>[
          ...prior,
          const BackendDiagnostic(
            kind: DiagnosticKind.connectionFailed,
            message: 'the context could not be made current to be probed',
          ),
        ],
      );
    }

    final gl = GlApi(context.procAddress);
    final missing = missingGlSymbols(context.procAddress);
    if (missing.isNotEmpty) {
      return BackendProbeResult(
        backendName: backendName,
        supported: false,
        diagnostics: <BackendDiagnostic>[
          ...prior,
          BackendDiagnostic.missingSymbol(
            missing.length > 6
                ? '${missing.take(6).join(', ')} and ${missing.length - 6} '
                    'more'
                : missing.join(', '),
            detail: 'the context resolved '
                '${kRequiredGlSymbols.length - missing.length} of '
                '${kRequiredGlSymbols.length} required entry points: '
                '${context.description}',
          ),
        ],
      );
    }

    final version = gl.stringOf(glVersion);
    final renderer = gl.stringOf(glRenderer);
    final vendor = gl.stringOf(glVendor);
    if (version.isEmpty) {
      return BackendProbeResult(
        backendName: backendName,
        supported: false,
        diagnostics: <BackendDiagnostic>[
          ...prior,
          const BackendDiagnostic(
            kind: DiagnosticKind.incompatibleDevice,
            message: 'glGetString(GL_VERSION) returned nothing with a context '
                'current',
          ),
        ],
      );
    }
    // The truthful part. Every GL context can present a CPU framebuffer,
    // because GlOffscreenTarget reads the FBO back into one - that is what
    // cpuPresentation means and it is always available here. gpuPresentation
    // is the claim that used to be missing entirely: it means a
    // GlWindowSurfaceDescriptor can be handed to createTarget and the pixels
    // will reach a screen without a readback.
    final windowed = windowPresentation ?? context.presentsToWindow;
    return BackendProbeResult(
      backendName: backendName,
      supported: true,
      capabilities: <Capability>{
        Capability.cpuPresentation,
        if (windowed) ...<Capability>[
          Capability.gpuPresentation,
          // Swap interval control comes with the swap on both WGL and EGL. It
          // is claimed with the swap and not separately because there is no
          // configuration in which one exists and the other does not; a
          // driver that refuses the *request* reports that at the call, which
          // is why GlSwapChain.setSwapInterval returns a bool.
          Capability.vsync,
        ],
      },
      diagnostics: <BackendDiagnostic>[
        ...prior,
        BackendDiagnostic.note(
          '$renderer, GL $version',
          detail: 'vendor: $vendor; ${context.description}; GLSL '
              '${gl.stringOf(glShadingLanguageVersion)}',
        ),
        // Text, reported because nothing else in this result can say it.
        // [Capability] has no member for glyph rendering and
        // [RendererCapabilities] has no field for it, so until this note
        // existed a reader of a probe report had no way to tell a device that
        // draws text from one that refuses a run by name - and this backend
        // was, for several sections, the second kind. It is a note rather than
        // a capability because adding an enum member is a change every backend
        // switches on; see [GlRenderDevice.capabilities].
        const BackendDiagnostic.note(
          'text: drawn on the GPU from a resident alpha8 glyph atlas',
          detail: 'every target this backend builds wires a GpuGlyphAtlas, the '
              'texture it stages into and a GpuFontResolver, so a glyph run is '
              'rasterised once and cached across frames rather than refused. '
              'Coverage only - no colour glyphs, no SDF, and text under a '
              'rotated, skewed or non-uniformly scaled transform is still '
              'refused by name',
        ),
        BackendDiagnostic.note(
          windowed
              ? 'windowed presentation: GlWindowTarget binds framebuffer 0 and '
                  'swaps it, with no per-frame readback'
              : 'offscreen only: no window-system surface is reachable from '
                  'here, so createTarget accepts MemorySurfaceDescriptor and '
                  'refuses GlWindowSurfaceDescriptor',
          detail: context.presentsToWindow
              ? 'the probed context owns a window surface'
              : 'the probed context is a pbuffer; a windowed context is '
                  'created by the platform code that owns the window',
        ),
      ],
    );
  }

  /// Opens a device, or throws [BackendSelectionError] carrying the probe.
  ///
  /// Throwing here and not in [probe] is the split section 6.6 asks for:
  /// asking whether a backend works must be safe, and asking it to work when
  /// it cannot is a caller error that has to be loud.
  @override
  Future<RenderDevice> createDevice() async {
    final load = GlLibrary.open();
    if (!load.isLoaded) {
      throw BackendSelectionError(
        requested: backendName,
        attempts: <BackendProbeResult>[
          BackendProbeResult.unsupported(
            backendName,
            BackendDiagnostic.missingLibrary(
              load.attempted.join(', '),
              detail: load.error,
            ),
          ),
        ],
      );
    }

    final attempt = const GlContextFactory()
        .create(width: 16, height: 16, glLibrary: load.library!);
    final context = attempt.context;
    if (context == null) {
      throw BackendSelectionError(
        requested: backendName,
        attempts: <BackendProbeResult>[
          BackendProbeResult(
            backendName: backendName,
            supported: false,
            diagnostics: attempt.diagnostics,
          ),
        ],
      );
    }
    return adoptContext(context, load.library!);
  }

  /// Builds a device on a context somebody else created.
  ///
  /// The seam the Windows path needs: `lib/src/backends/win32` owns the
  /// window and the WGL context, and hands the finished context here rather
  /// than this file learning what a window is. Takes ownership - the returned
  /// device disposes the context.
  ///
  /// Throws [BackendSelectionError] carrying the reason, like [createDevice].
  static GlRenderDevice adoptContext(
    GlContext context,
    DynamicLibrary glLibrary, {
    bool enableExperimentalSparseStrips = false,
    GlSparseStripsPolicy sparseStrips = GlSparseStripsPolicy.auto,
    bool enableExperimentalStencilCover = false,
    bool enableExperimentalCpuTessellation = false,
  }) {
    // The old boolean meant "build it or refuse the backend", which is
    // [GlSparseStripsPolicy.required]. Callers that pass it keep exactly that,
    // so a test measuring the route still fails loudly if it is unavailable.
    final GlSparseStripsPolicy sparsePolicy = enableExperimentalSparseStrips
        ? GlSparseStripsPolicy.required
        : sparseStrips;
    final report = describeContext(context);
    if (!report.supported) {
      context.dispose();
      throw BackendSelectionError(
        requested: backendName,
        attempts: <BackendProbeResult>[report],
      );
    }

    final heap = NativeHeap.tryBind(glLibrary);
    if (heap == null) {
      context.dispose();
      throw BackendSelectionError(
        requested: backendName,
        attempts: <BackendProbeResult>[
          BackendProbeResult.unsupported(
            backendName,
            const BackendDiagnostic.missingSymbol(
              'malloc',
              detail: 'no native allocator could be bound; see '
                  'NativeHeap.tryBind',
            ),
          ),
        ],
      );
    }

    final gl = GlApi(context.procAddress);
    // Resolved once, here, so the rest of the device sees a plain "is it on"
    // and cannot re-derive the policy differently.
    var sparseRequested = sparsePolicy != GlSparseStripsPolicy.disabled;
    if (sparseRequested) {
      final List<String> missing = missingSparseGlSymbols(context.procAddress);
      if (missing.isNotEmpty) {
        if (sparsePolicy == GlSparseStripsPolicy.required) {
          context.dispose();
          throw BackendSelectionError(
            requested: backendName,
            attempts: <BackendProbeResult>[
              BackendProbeResult.unsupported(
                backendName,
                BackendDiagnostic.missingSymbol(
                  missing.join(', '),
                  detail: 'required only because sparse strips were '
                      'explicitly required',
                ),
              ),
            ],
          );
        }
        // Automatic: a driver without instanced arrays keeps the dense
        // coverage atlas, which draws every one of these paths correctly. The
        // backend is not refused over a missing *optimisation*.
        sparseRequested = false;
      }
    }
    if (enableExperimentalStencilCover) {
      final List<String> missing =
          missingStencilCoverGlSymbols(context.procAddress);
      if (missing.isNotEmpty) {
        context.dispose();
        throw BackendSelectionError(
          requested: backendName,
          attempts: <BackendProbeResult>[
            BackendProbeResult.unsupported(
              backendName,
              BackendDiagnostic.missingSymbol(
                missing.join(', '),
                detail: 'required only because experimental '
                    'stencil-then-cover was explicitly enabled',
              ),
            ),
          ],
        );
      }
    }
    final device = GlRenderDevice._(
      context: context,
      gl: gl,
      heap: heap,
      info: RendererInfo(
        name: backendName,
        deviceDescription: gl.stringOf(glRenderer),
        driverVersion: gl.stringOf(glVersion),
        rasterizationApproach: RasterizationApproach.analyticCoverageAtlas,
      ),
      maxTextureSize: _queryMaxTextureSize(gl, heap),
      sparseStripsRequested: sparseRequested,
      sparseStripsRequired: sparsePolicy == GlSparseStripsPolicy.required,
      stencilCoverRequested: enableExperimentalStencilCover,
      cpuTessellationRequested: enableExperimentalCpuTessellation,
    );
    final failure = device._initialise();
    if (failure != null) {
      device.dispose();
      throw BackendSelectionError(
        requested: backendName,
        attempts: <BackendProbeResult>[
          BackendProbeResult.unsupported(backendName, failure),
        ],
      );
    }
    final BackendDiagnostic? sparseFailure = device._initialiseSparseStrips();
    if (sparseFailure != null) {
      device.dispose();
      throw BackendSelectionError(
        requested: backendName,
        attempts: <BackendProbeResult>[
          BackendProbeResult.unsupported(backendName, sparseFailure),
        ],
      );
    }
    final BackendDiagnostic? stencilFailure = device._initialiseStencilCover();
    if (stencilFailure != null) {
      device.dispose();
      throw BackendSelectionError(
        requested: backendName,
        attempts: <BackendProbeResult>[
          BackendProbeResult.unsupported(backendName, stencilFailure),
        ],
      );
    }
    final BackendDiagnostic? tessellationFailure =
        device._initialiseCpuTessellation();
    if (tessellationFailure != null) {
      device.dispose();
      throw BackendSelectionError(
        requested: backendName,
        attempts: <BackendProbeResult>[
          BackendProbeResult.unsupported(backendName, tessellationFailure),
        ],
      );
    }
    return device;
  }

  static int _queryMaxTextureSize(GlApi gl, NativeHeap heap) {
    final slot = heap.allocateInt32(1);
    try {
      slot[0] = 0;
      gl.getIntegerv(glMaxTextureSize, slot);
      // 2048 is the GL 2.0 floor; a driver that answers 0 is answering "I do
      // not know", and reporting that as the limit would make every texture
      // creation illegal.
      return slot[0] > 0 ? slot[0] : 2048;
    } finally {
      heap.release(slot);
    }
  }
}
