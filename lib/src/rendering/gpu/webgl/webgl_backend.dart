/// The WebGL2 backend: the same renderer as `gl_backend.dart`, in a browser.
///
/// This file is a port, not a parallel design, and saying so is the most useful
/// thing its header can do. Every structural decision here was made in
/// `gl_backend.dart` first and is explained there at length: one shader program
/// with a mode uniform, a redundant-state filter carried across layer passes, a
/// mid-frame atlas flush that remembers how many batches it already issued, an
/// offscreen target that reads pixels back and a surface target that never
/// does. Where this file differs from that one, the difference is forced by the
/// platform, and each is called out where it happens.
///
/// ## The four things a browser makes different
///
/// **1. GL objects are JavaScript objects, not integers.** `glGenTextures`
/// hands back a `GLuint`; `gl.createTexture()` hands back a `WebGLTexture`,
/// which is an opaque object with no number attached. But `GpuBatch.textureId`
/// is an `int` - the batcher compares it to decide whether a batch can continue
/// - and `GpuTextureHandle.id` is an `int` too. So this backend keeps its own
/// numbering in a [WebGlObjectTable] and looks the object up when it binds. The
/// cost is one map lookup *per batch*, not per quad, which is the same order as
/// the redundant-state filter sitting next to it. See
/// `webgl_framebuffer_pool.dart`, where that table is defined and where the
/// argument is made in full.
///
/// **2. There is no `makeCurrent`.** A WebGL context belongs to its canvas and
/// is always current for it; the whole class of bug `GlRenderDevice.
/// makeCurrentOrLose` guards against - issuing calls into another context -
/// cannot happen. What replaces it is [WebGlRenderDevice.checkContextAlive],
/// which asks `gl.isContextLost()`. That is a real and *common* condition here
/// in a way it is not on the desktop: a browser drops a context when the tab is
/// backgrounded, when the GPU process restarts, and when too many contexts are
/// live on one page. Every entry point on a lost context becomes a silent
/// no-op rather than an error, which is precisely why it must be asked about
/// explicitly - a device that never checked would draw nothing, report success,
/// and look like a bug in the scene.
///
/// **3. There is no native heap.** `gl_backend.dart` allocates scratch memory
/// once and writes `GLuint*` out-parameters through it so a frame performs no
/// allocation. Here the equivalent is a `Float32List`/`Uint32List` handed to
/// `bufferData` as a typed-array view, and the staging lists are grown and
/// reused for the same reason: a frame must not allocate.
///
/// **4. `dart:ffi` must never appear.** Not in this file, not in anything it
/// imports. That is what makes the package compile under `dart2js` and
/// `dart2wasm`, and it is checked by a test rather than trusted to review -
/// see `test/backends/web/web_compilation_test.dart`, which runs both
/// compilers over an entrypoint that imports this library and fails if either
/// one does.
///
/// ## Two targets, and only one of them reads pixels back
///
/// [WebGlOffscreenTarget] renders into a framebuffer object and calls
/// `readPixels` on present. That is what makes the GPU path comparable against
/// `CpuRasterizer` pixel for pixel, and it is the target the parity suite uses.
///
/// `WebGlCanvasTarget`, in `webgl_canvas_target.dart`, is the one that puts
/// pixels on a page. It draws into the context's default framebuffer, which the
/// browser's compositor picks up, and it never reads back - section 23 of the
/// roadmap forbids a per-frame readback for a production backend, and
/// [WebGlRenderDevice.readPixelsInto] is public only because the offscreen
/// target lives in this same library and the canvas target does not call it.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../../../foundation/diagnostics.dart';
import '../../../foundation/lifecycle.dart';
import '../../../geometry/rect.dart';
import '../../../geometry/transform2d.dart';
import '../../../graphics/display_list.dart';
import '../../../graphics/display_list_reader.dart';
import '../../../graphics/image/decoded_image.dart' show ImageChannelOrder;
import '../../../text/typeface.dart';
import '../../framebuffer.dart';
import '../../renderer.dart';
import '../../replay/display_list_player.dart';
import '../gl/gl_shaders.dart';
import '../gl/gl_sparse_executor.dart';
import '../gpu_batcher.dart';
import '../gpu_device_state.dart';
import '../gpu_glyph_atlas.dart';
import '../gpu_layer_stack.dart';
import '../gpu_mask_atlas.dart';
import '../gpu_pipeline.dart';
import '../gpu_raster_sink.dart';
import '../gpu_recovery.dart';
import '../gpu_texture.dart';
import '../gpu_vertex_buffer.dart';
import '../gpu_video_image.dart';
import '../vector/sparse_strip_draw_plan.dart';
import 'webgl_framebuffer_pool.dart';
import 'webgl_sparse_driver.dart';
import 'webgl_surface_descriptor.dart';

/// The GLSL this backend compiles.
///
/// `desktop: false` selects the GLSL ES 3.00 dialect out of `gl_shaders.dart`,
/// which is exactly the language WebGL2 accepts - `#version 300 es` plus
/// explicit precision qualifiers. Importing the shaders rather than copying
/// them is the point: the coverage term in the fragment shader *is* the
/// antialiasing, and a copy would let the desktop and the browser drift into
/// drawing different edges from the same display list. The parity suite would
/// then be comparing this backend against a CPU rasteriser it no longer agrees
/// with, and the divergence would look like a driver difference.
const bool _kWebGlUsesEsDialect = true;

/// A texture owned by a [WebGlRenderDevice].
///
/// Carries both identities: [id], the integer this backend invented so the
/// batcher can compare textures cheaply, and [object], the `WebGLTexture` the
/// browser actually binds.
final class WebGlTexture implements GpuTextureHandle {
  WebGlTexture._(
    this.id,
    this.object,
    this.width,
    this.height,
    this.format,
    this.filter,
    this._state,
  ) : _bornAtLossCount = _state.lossCount;

  @override
  final int id;

  /// The browser's own handle. Bound through the device's table rather than
  /// read from here by the draw loop, because the loop only has the integer.
  final web.WebGLTexture object;

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

  /// [GpuDeviceState.lossCount] when this texture was created.
  ///
  /// The same field, for the same reason, as `GlTexture._bornAtLossCount`:
  /// `isLost` goes back to false when the device recovers, so a check that
  /// asked only that question would declare every pre-loss texture healthy
  /// again. On WebGL the consequence is milder than on the desktop - a
  /// `WebGLTexture` from a lost context is inert rather than undefined, so
  /// binding one draws nothing instead of drawing whatever memory was recycled
  /// - but "draws nothing" is still a wrong picture, and `lossCount` never goes
  /// down, so comparing it is the check that survives a recovery.
  final int _bornAtLossCount;

  @override
  bool get isValid =>
      !_released && !_state.isLost && _state.lossCount == _bornAtLossCount;

  bool get _isDeletable => isValid;

  @override
  String toString() =>
      'WebGlTexture($id, ${width}x$height, ${format.name}, ${filter.name})';
}

/// The GL state [WebGlRenderDevice.submit] has already sent, so it does not
/// send it again. See `gl_backend.dart`'s `_DrawState` for why this is an
/// object that survives across passes rather than three locals.
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

/// A target that can put its GPU resources back after a context loss.
///
/// Implemented by [WebGlOffscreenTarget] and by `WebGlCanvasTarget`, which live
/// in different libraries; the device holds them through this interface so a
/// recovery can walk every live target without knowing which kind each is.
abstract interface class WebGlRecoverableTarget {
  Iterable<GpuRecoverableResource> recoverableResources();
}

/// A WebGL2 context plus the objects every target on it shares.
final class WebGlRenderDevice
    with DisposableMixin
    implements RenderDevice, GpuTextureAllocator, GpuRecoveryHost {
  WebGlRenderDevice._({
    required web.WebGL2RenderingContext gl,
    required RendererInfo info,
    required int maxTextureSize,
    required bool sparseStripsRequested,
  })  : _gl = gl,
        _info = info,
        _maxTextureSize = maxTextureSize,
        _sparseStripsRequested = sparseStripsRequested;

  /// Wraps an already-created WebGL2 context.
  ///
  /// The context is **borrowed**, exactly as `GlRenderDevice.adoptContext`
  /// borrows a `GlContext`: whoever created the canvas created the context, and
  /// disposing this device does not remove either from the page. That is what
  /// lets a device be lost and rebuilt without the window going with it, which
  /// `renderer.dart` promises and which on a page would otherwise mean
  /// destroying a DOM element the application put there.
  ///
  /// Returns the device, or a diagnostic naming what the context refused. Never
  /// throws: a browser that will not compile the shader is a machine this
  /// backend cannot run on, which section 6.6 says must be reported rather than
  /// raised.
  /// [enableExperimentalSparseStrips] is the opt-in `gl_backend.dart` spells
  /// the same way, and it buys the same thing: a second, independent pipeline
  /// - the GLES dialect of the sparse shader, its own VAO and its own alpha
  /// pages - reachable only through [submitSparseStrips]. Nothing about the
  /// dense path changes, and a context adopted without the flag never compiles
  /// the sparse program at all.
  static ({WebGlRenderDevice? device, BackendDiagnostic? failure}) adoptContext(
    web.WebGL2RenderingContext gl, {
    bool enableExperimentalSparseStrips = false,
  }) {
    final int maxTextureSize = _intParameter(
      gl,
      web.WebGL2RenderingContext.MAX_TEXTURE_SIZE,
      fallback: 2048,
    );
    final WebGlRenderDevice device = WebGlRenderDevice._(
      gl: gl,
      info: RendererInfo(
        name: WebGlRendererBackend.backendName,
        deviceDescription: describeWebGlContext(gl),
        rasterizationApproach: RasterizationApproach.analyticCoverageAtlas,
      ),
      maxTextureSize: maxTextureSize,
      sparseStripsRequested: enableExperimentalSparseStrips,
    );
    final BackendDiagnostic? failure = device._initialise();
    if (failure != null) {
      device.dispose();
      return (device: null, failure: failure);
    }
    final BackendDiagnostic? sparseFailure = device._initialiseSparseStrips();
    if (sparseFailure != null) {
      device.dispose();
      return (device: null, failure: sparseFailure);
    }
    return (device: device, failure: null);
  }

  final web.WebGL2RenderingContext _gl;
  final RendererInfo _info;
  final int _maxTextureSize;
  final bool _sparseStripsRequested;
  final GpuDeviceState _state = GpuDeviceState();

  WebGlSparseDriver? _sparseDriver;
  SparseGlExecutor? _sparseExecutor;

  /// True only when the caller explicitly opted in and the context accepted
  /// the sparse program. The dense path never consults it; it is the fact a
  /// strategy selector needs before it can prefer sparse strips for a draw.
  bool get experimentalSparseStripsEnabled => _sparseExecutor != null;

  /// The context, for the targets that issue their own calls.
  ///
  /// Public for the reason `gl_backend.dart`'s library comment gives about its
  /// own promoted members: the canvas target is a separate library and a target
  /// *is* the thing that binds a framebuffer and draws. It is device-to-target
  /// plumbing, not application API.
  web.WebGL2RenderingContext get gl => _gl;

  GpuDeviceState get state => _state;

  /// The integer numbering that stands in for GL's texture names.
  ///
  /// Shared with every target and with each layer pool, because
  /// `GpuBatch.textureId` is compared across all of them: two tables would
  /// hand out the same integer for two different textures and a batch would
  /// bind whichever one happened to be registered second.
  final WebGlObjectTable<web.WebGLTexture> textures =
      WebGlObjectTable<web.WebGLTexture>();

  web.WebGLProgram? _program;
  web.WebGLVertexArrayObject? _vao;
  web.WebGLBuffer? _vbo;
  web.WebGLBuffer? _ebo;
  web.WebGLUniformLocation? _uniformViewport;
  web.WebGLUniformLocation? _uniformTexture;
  web.WebGLUniformLocation? _uniformMode;
  web.WebGLUniformLocation? _uniformYFlip;

  /// Staging for the geometry upload, grown and reused.
  ///
  /// A frame must not allocate, which is the same rule `gl_backend.dart`'s
  /// native scratch buffers exist for. `bufferData` is handed a *view* of these
  /// - `Float32List.sublistView` - rather than the whole list, because the
  /// buffer is usually larger than the frame needs and uploading the slack
  /// would send megabytes of stale floats to the driver every frame.
  Float32List _vertexStaging = Float32List(0);
  Uint32List _indexStaging = Uint32List(0);
  Uint8List _pixelStaging = Uint8List(0);

  @override
  RendererInfo get info => _info;

  @override
  bool get isLost => _state.isLost;

  final Set<WebGlRecoverableTarget> _targets = <WebGlRecoverableTarget>{};
  bool _submissionsStopped = false;
  int _blockedSubmissionCount = 0;

  /// How many submissions were refused because a recovery was in progress.
  /// Exposed because it is invisible from the pixels: a device that went on
  /// issuing draws into a dead context produces the same blank frame as one
  /// that correctly refused.
  int get blockedSubmissionCount => _blockedSubmissionCount;

  bool get submissionsStopped => _submissionsStopped;

  @override
  String get backendName => WebGlRendererBackend.backendName;

  @override
  GpuDeviceState get deviceState => _state;

  void registerTarget(WebGlRecoverableTarget target) => _targets.add(target);

  void unregisterTarget(WebGlRecoverableTarget target) =>
      _targets.remove(target);

  /// Step 1 of a recovery: nothing more goes to the driver.
  @override
  void stopSubmissions() => _submissionsStopped = true;

  /// Step 3: forget the shared pipeline objects without calling the context.
  ///
  /// No `deleteProgram`, no `deleteBuffer`. On a lost WebGL context every one
  /// of those is defined to be a no-op, so calling them would not be *unsafe*
  /// the way it is on the desktop - but the handles refer to objects the
  /// browser has already reclaimed, and keeping them would let a later frame
  /// bind a program that can never link again. Null is WebGL's "no object" for
  /// all four, so the fields are simply dropped and [_initialise] makes new
  /// ones.
  @override
  void discardNativeResources() {
    _program = null;
    _vao = null;
    _vbo = null;
    _ebo = null;
    _uniformViewport = null;
    _uniformTexture = null;
    _uniformMode = null;
    _uniformYFlip = null;
    _drawState.reset();
    _lastError = null;
    // The opt-in inventory is separate from the dense one and forgets itself
    // the same way; a device that never enabled it has nothing to forget.
    if (_sparseExecutor != null && !_sparseExecutor!.isDisposed) {
      _sparseExecutor!.discardNativeResources();
    }
    // The integer numbering goes too. Every `WebGLTexture` it named died with
    // the context, and an id that resolved to one of them would let a batch
    // recorded before the loss bind a dead object and draw nothing.
    textures.clear();
  }

  /// Step 4: recompile everything shared, on the context that came back.
  ///
  /// ## What this can and cannot recover
  ///
  /// It does not create a new context, for the reason `gl_backend.dart` gives
  /// about `GlContext`: the canvas and its context belong to the page, and a
  /// renderer that replaced them would be replacing a DOM element the
  /// application owns.
  ///
  /// What it recreates is every WebGL *object*, which is what a context loss
  /// actually destroys. The case it cannot recover from is a context that is
  /// still lost - the browser restores one asynchronously, after the page
  /// handles `webglcontextrestored`, and a recovery driven before that event
  /// arrives has nothing to build on. It says so by name rather than
  /// pretending, and the owner may try again when the event fires.
  @override
  BackendDiagnostic? recreateDevice() {
    if (isDisposed) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'a disposed WebGL2 device cannot be recovered',
        detail: 'the owner must create a new device through '
            'WebGlRendererBackend.createDevice or adoptContext',
      );
    }
    final bool wasLost = _state.isLost;
    final BackendDiagnostic? cause = _state.lossDiagnostic;
    _state.recover();

    if (_gl.isContextLost()) {
      final BackendDiagnostic failure = BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'the WebGL2 context is still lost, so this device cannot be '
            'recovered yet',
        detail: 'the browser restores a context asynchronously and signals it '
            'with a webglcontextrestored event on the canvas. A recovery run '
            'before that event has nothing to rebuild on; the owner should '
            'retry from the event handler. The original loss was: '
            '${cause ?? 'not recorded'}',
      );
      _state.markLost(failure);
      return failure;
    }

    // Any error the dead context left queued belongs to the previous device and
    // would otherwise be reported against the first call made on the new one.
    _drainErrors();

    final BackendDiagnostic? failure = _initialise();
    if (failure != null) {
      _state.markLost(failure);
      return failure;
    }
    final BackendDiagnostic? sparseFailure = _initialiseSparseStrips();
    if (sparseFailure != null) {
      _state.markLost(sparseFailure);
      return sparseFailure;
    }
    _submissionsStopped = false;
    if (!wasLost) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.note,
        message: 'the WebGL2 device was not lost when the recovery ran',
      );
    }
    return null;
  }

  /// Step 5's inventory: everything every live target owns.
  @override
  Iterable<GpuRecoverableResource> recoverableResources() sync* {
    for (final WebGlRecoverableTarget target
        in List<WebGlRecoverableTarget>.of(_targets)) {
      yield* target.recoverableResources();
    }
  }

  /// What this device can do, answered field by field.
  ///
  /// The answers match `GlRenderDevice`'s and for the same reasons, with one
  /// that is specific to a browser: **`supportsPartialPresent` is false**. A
  /// canvas is composited whole by the page's compositor, and there is no
  /// equivalent of a damage rectangle to hand it - `preserveDrawingBuffer` is
  /// false (see `defaultWebGl2ContextAttributes`), so the drawing buffer's
  /// previous contents are not even guaranteed to survive to the next frame.
  /// Damage tracking is still worth doing above this line because it saves
  /// rasterisation; it saves nothing at the present.
  ///
  /// `supportsMsaa` is false because the antialiasing is analytic - the
  /// coverage term in the shader and the mask atlas - and the context is
  /// created with `antialias: false` so a multisampled default framebuffer
  /// cannot add a second, disagreeing one on top.
  ///
  /// **Text is drawn, and none of these booleans says so.** Every target
  /// carries a [GpuGlyphAtlas], an alpha8 texture and a [WebGlFontResolver], so
  /// a glyph run rasterises here rather than being refused.
  /// `supportsExternalTextures: false` is about *foreign* textures and has
  /// never had anything to do with glyphs; it is stated because a reader
  /// looking for "can this draw text" would otherwise find no field and assume
  /// the pessimistic answer.
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
  /// Anything unrecognised throws rather than quietly becoming an offscreen
  /// target. That silent fallback is the worst one available here: the frame
  /// would render perfectly and appear nowhere, which reads as a bug in the
  /// scene rather than in the backend selection.
  ///
  /// Note that a [WebGlCanvasSurfaceDescriptor] is *not* handled in this file.
  /// It is handled by `WebGlCanvasTarget.forSurface`, which the canvas target's
  /// own library provides, because a `createTarget` that returned it would make
  /// this library import that one and that one already imports this. The
  /// platform code that owns the canvas builds the canvas target directly, the
  /// same way `lib/src/backends/win32` builds a `GlWindowTarget`.
  @override
  RenderTarget createTarget(NativeSurfaceDescriptor surface) {
    throwIfDisposed();
    if (surface is MemorySurfaceDescriptor) {
      return WebGlOffscreenTarget._(this, surface);
    }
    throw UnsupportedCapabilityError(
      backendName: WebGlRendererBackend.backendName,
      capability: Capability.gpuPresentation,
      detail: 'this device builds an offscreen target from a '
          'MemorySurfaceDescriptor; it was handed a ${surface.kind} '
          '(${surface.runtimeType}), which it has no way to present to. A '
          'canvas is presented to by WebGlCanvasTarget, which the code that '
          'owns the canvas constructs - see '
          'lib/src/backends/web/web_window.dart',
    );
  }

  // -------------------------------------------------------------------
  // Textures
  // -------------------------------------------------------------------

  @override
  WebGlTexture createTexture({
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
        backendName: WebGlRendererBackend.backendName,
        capability: Capability.gpuPresentation,
        detail: 'a ${width}x$height texture exceeds this context\'s '
            'MAX_TEXTURE_SIZE of $_maxTextureSize; the caller must tile the '
            'image or scale it down',
      );
    }
    if (format == GpuTextureFormat.bgra8888Premultiplied) {
      // WebGL 2 is ES 3.0, which has no `GL_BGRA` upload format at all - not
      // even the desktop GL path this backend's sibling can take. Refusing is
      // the contract on [GpuTextureFormat.bgra8888Premultiplied]: the caller
      // converts instead, which costs time. Creating an RGBA texture and
      // uploading BGRA bytes into it would cost nothing and swap red with
      // blue.
      throw UnsupportedCapabilityError(
        backendName: WebGlRendererBackend.backendName,
        capability: Capability.gpuPresentation,
        detail: 'WebGL2 is ES 3.0 and has no BGRA upload format, so a BGRA '
            'texture cannot be sampled with the right channel order here',
      );
    }
    final web.WebGLTexture? object = _gl.createTexture();
    if (object == null) {
      // Null is what a lost context answers. The device is marked lost so the
      // caller stops rather than getting a handle that can never be bound.
      _state.markLost(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'the WebGL2 context refused a texture',
        detail: 'createTexture returned null, which is what a lost context '
            'answers for every object it is asked to make',
      ));
      throw UnsupportedCapabilityError(
        backendName: WebGlRendererBackend.backendName,
        capability: Capability.gpuPresentation,
        detail: 'the WebGL2 context is lost and cannot create textures',
      );
    }

    final int sampling = filter == GpuTextureFilter.linear
        ? web.WebGL2RenderingContext.LINEAR
        : web.WebGL2RenderingContext.NEAREST;
    const int target = web.WebGL2RenderingContext.TEXTURE_2D;
    _gl
      ..bindTexture(target, object)
      ..texParameteri(
          target, web.WebGL2RenderingContext.TEXTURE_MIN_FILTER, sampling)
      ..texParameteri(
          target, web.WebGL2RenderingContext.TEXTURE_MAG_FILTER, sampling)
      ..texParameteri(target, web.WebGL2RenderingContext.TEXTURE_WRAP_S,
          web.WebGL2RenderingContext.CLAMP_TO_EDGE)
      ..texParameteri(target, web.WebGL2RenderingContext.TEXTURE_WRAP_T,
          web.WebGL2RenderingContext.CLAMP_TO_EDGE)
      // Coverage masks are one byte per texel and their rows are not
      // 4-aligned; the default unpack alignment of 4 would shear them.
      ..pixelStorei(web.WebGL2RenderingContext.UNPACK_ALIGNMENT, 1);

    final int internal = format == GpuTextureFormat.alpha8
        ? web.WebGL2RenderingContext.R8
        : web.WebGL2RenderingContext.RGBA8;
    final int external = format == GpuTextureFormat.alpha8
        ? web.WebGL2RenderingContext.RED
        : web.WebGL2RenderingContext.RGBA;
    _gl.texImage2D(
      target,
      0,
      internal,
      width.toJS,
      height.toJS,
      0.toJS,
      external,
      web.WebGL2RenderingContext.UNSIGNED_BYTE,
      null,
    );
    checkError('texImage2D(${width}x$height, ${format.name})');
    return WebGlTexture._(
      textures.register(object),
      object,
      width,
      height,
      format,
      filter,
      _state,
    );
  }

  /// Uploads [height] rows of [pixels], each [bytesPerRow] bytes apart.
  ///
  /// Rows are repacked into contiguous staging rather than handed over with
  /// `UNPACK_ROW_LENGTH`. WebGL2 does support that pixel-store parameter -
  /// unlike GLES 2, which is why `gl_backend.dart` repacks - but repacking
  /// keeps the two backends' upload paths identical, and the copy is over the
  /// dirty region only, which for the glyph atlas is a few hundred bytes on a
  /// typical frame and zero on a static one.
  @override
  void uploadRegion(
    covariant WebGlTexture texture, {
    required int x,
    required int y,
    required int width,
    required int height,
    required Uint8List pixels,
    required int bytesPerRow,
  }) {
    if (width <= 0 || height <= 0) return;
    if (!checkContextAlive()) return;
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
    final int external = texture.format == GpuTextureFormat.alpha8
        ? web.WebGL2RenderingContext.RED
        : web.WebGL2RenderingContext.RGBA;
    const int target = web.WebGL2RenderingContext.TEXTURE_2D;
    _gl
      ..bindTexture(target, texture.object)
      ..pixelStorei(web.WebGL2RenderingContext.UNPACK_ALIGNMENT, 1)
      ..texSubImage2D(
        target,
        0,
        x,
        y,
        width.toJS,
        height.toJS,
        external.toJS,
        web.WebGL2RenderingContext.UNSIGNED_BYTE,
        // A view of exactly the bytes this region needs. The staging list is
        // usually larger, and handing over the whole of it would tell the
        // driver to read past the region and unpack stale texels.
        Uint8List.sublistView(staging, 0, bytes).toJS,
      );
    // The binding is context state and the draw loop keeps its own filter, so
    // an upload between two batches that used the same texture would otherwise
    // leave the filter believing a texture is bound that is not.
    _drawState.textureId = -1;
    checkError('texSubImage2D');
  }

  /// Deletes [texture], or forgets it when the context already has.
  ///
  /// The delete is conditional on the texture's own loss generation rather than
  /// on the device's current one: after a recovery the device is healthy again
  /// while a pre-loss handle refers to an object the browser reclaimed.
  @override
  void releaseTexture(covariant WebGlTexture texture) {
    if (texture._released) return;
    final bool deletable = texture._isDeletable;
    texture._released = true;
    textures.release(texture.id);
    if (!deletable || isDisposed) return;
    _gl.deleteTexture(texture.object);
  }

  // -------------------------------------------------------------------
  // Frame submission
  // -------------------------------------------------------------------

  /// Issues a batch list, switching render targets where [layers] says to.
  ///
  /// The port of `GlRenderDevice.submit`, and the three things it has to get
  /// right are the same three:
  ///
  /// **Where the batches go.** Without layers, one target and one loop, into
  /// whatever the caller bound. With layers, a sequence of (target, batch
  /// range) pairs, each binding [GpuRenderPass.target]'s framebuffer or - for
  /// the surface's own runs - [surfaceFramebuffer], which is why that argument
  /// exists: the caller's binding has to be restorable after a layer pass and
  /// this file must not guess whether it was the default one. `null` is the
  /// default framebuffer here, where GL used the integer 0.
  ///
  /// **Which way up each pass is.** See [kYFlipTopDown] in `gl_shaders.dart`:
  /// a pass rendering into a texture that will be sampled is written top-down,
  /// which inverts both the projection and the scissor's y. Getting it
  /// backwards draws every layer upside down.
  ///
  /// **How far it already got.** [firstBatch] is what makes a mid-frame atlas
  /// flush possible; a batch drawn twice blends twice.
  ///
  /// [surfaceWidth] and [surfaceHeight] are physical pixels and set both the
  /// viewport and the scissor clamp, so passing a logical size silently renders
  /// a quarter of a HiDPI canvas.
  ///
  /// Returns false when the context was lost on the way, which the caller turns
  /// into [PresentStatus.deviceLost].
  bool submit(
    GpuBatcher batcher,
    int surfaceWidth,
    int surfaceHeight,
    int? clearColor, {
    GpuLayerStack? layers,
    web.WebGLFramebuffer? surfaceFramebuffer,
    WebGlFramebufferPool? layerPool,
    int firstBatch = 0,
  }) {
    if (_submissionsStopped) {
      _blockedSubmissionCount++;
      return false;
    }
    if (!checkContextAlive()) return false;

    const int fb = web.WebGL2RenderingContext.FRAMEBUFFER;
    _gl
      ..bindFramebuffer(fb, surfaceFramebuffer)
      ..viewport(0, 0, surfaceWidth, surfaceHeight)
      ..disable(web.WebGL2RenderingContext.DEPTH_TEST)
      ..disable(web.WebGL2RenderingContext.CULL_FACE)
      ..enable(web.WebGL2RenderingContext.BLEND)
      ..disable(web.WebGL2RenderingContext.SCISSOR_TEST);

    // A caller resuming after a mid-frame flush passes null: the surface was
    // cleared by the submission that opened the frame, and clearing again would
    // erase everything drawn before the flush.
    if (clearColor != null) {
      // Packed premultiplied BGRA in a 32-bit int, per FrameRequest;
      // clearColor wants straight floats in RGBA order.
      _gl
        ..clearColor(
          ((clearColor >> 16) & 0xFF) / 255.0,
          ((clearColor >> 8) & 0xFF) / 255.0,
          (clearColor & 0xFF) / 255.0,
          ((clearColor >> 24) & 0xFF) / 255.0,
        )
        ..clear(web.WebGL2RenderingContext.COLOR_BUFFER_BIT);
    }

    final int batchCount = batcher.batchCount;
    if (batchCount <= firstBatch) return !_state.isLost;

    _uploadGeometry(batcher);

    _gl
      ..useProgram(_program)
      ..uniform1i(_uniformTexture, 0)
      ..activeTexture(web.WebGL2RenderingContext.TEXTURE0)
      ..bindVertexArray(_vao)
      ..enable(web.WebGL2RenderingContext.SCISSOR_TEST);

    // Carried across passes on purpose: a texture binding, a blend function and
    // the mode uniform are context state, not framebuffer state, so switching
    // target does not invalidate them.
    final _DrawState state = _drawState..reset();

    final int passCount = layers?.passCount ?? 0;
    if (passCount == 0) {
      _drawBatches(batcher, firstBatch, batchCount, surfaceWidth, surfaceHeight,
          kYFlipDefault, state);
    } else {
      for (var p = 0; p < passCount; p++) {
        final GpuRenderPass pass = layers!.passAt(p);
        final int end = layers.passEnd(p, batchCount);
        if (end <= firstBatch) continue;
        final int start =
            pass.firstBatch < firstBatch ? firstBatch : pass.firstBatch;
        final bool clears = pass.clearsTarget && start == pass.firstBatch;
        // An empty pass that clears is not a contradiction and must not be
        // skipped: a layer whose first act is to open a nested layer records no
        // batches of its own until that one closes, and its target still has to
        // lose the previous tenant's pixels.
        if (end <= start && !clears) continue;

        final GpuLayerTarget? target = pass.target;
        _gl
          ..bindFramebuffer(
            fb,
            target == null
                ? surfaceFramebuffer
                : layerPool?.framebufferFor(target.id),
          )
          ..viewport(0, 0, pass.viewportWidth, pass.viewportHeight);

        if (clears) {
          // A layer composites what it drew over transparency. The scissor is
          // off for the clear because clear obeys it, and the whole target -
          // including the slack a pooled target has past the layer's own size -
          // has to lose the previous tenant's pixels.
          _gl
            ..disable(web.WebGL2RenderingContext.SCISSOR_TEST)
            ..clearColor(0, 0, 0, 0)
            ..clear(web.WebGL2RenderingContext.COLOR_BUFFER_BIT)
            ..enable(web.WebGL2RenderingContext.SCISSOR_TEST);
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
      }
      // The caller bound its own framebuffer before calling and is entitled to
      // find it bound afterwards - it reads pixels back or lets the compositor
      // pick it up next.
      _gl.bindFramebuffer(fb, surfaceFramebuffer);
    }

    _gl.disable(web.WebGL2RenderingContext.SCISSOR_TEST);
    checkError('draw');
    return !_state.isLost;
  }

  // -------------------------------------------------------------------
  // Experimental sparse strips
  // -------------------------------------------------------------------

  /// Explicit sparse-strip submission seam.
  ///
  /// The display-list renderer does not call this method, exactly as it does
  /// not call `GlRenderDevice.submitSparseStrips`. A caller opts in while
  /// adopting the context and then hands over a plan, so the established dense
  /// atlas path stays the default on every browser.
  ///
  /// [surfaceFramebuffer] is the attachment, `null` being the default
  /// framebuffer - the same convention [submit] uses and for the same reason:
  /// this file must not guess whether the caller had bound one.
  ///
  /// Refusals are transactional. The feature check, the recovery check, the
  /// context check and every material check happen before a buffer is written
  /// or a draw is issued, so a caller that catches the error can fall back to
  /// the coverage atlas with the target's contents, the blend state and the
  /// submission order untouched. What this method *does* change on the way in
  /// is the same state [submit] sets on every frame - framebuffer, viewport,
  /// depth, cull and scissor - which the next dense submission sets again
  /// before it draws anything.
  SparseGlExecutionStats submitSparseStrips(
    SparseStripDrawPlan plan, {
    required List<SparseGlMaterial> materials,
    required int viewportWidth,
    required int viewportHeight,
    int yFlip = kYFlipDefault,
    web.WebGLFramebuffer? surfaceFramebuffer,
  }) {
    final SparseGlExecutor? executor = _sparseExecutor;
    if (executor == null) {
      throw StateError(
        'sparse strips are disabled; adopt the WebGL2 context with '
        'enableExperimentalSparseStrips: true',
      );
    }
    if (_submissionsStopped) {
      _blockedSubmissionCount++;
      throw StateError('WebGL2 submissions are stopped during device recovery');
    }
    if (!checkContextAlive()) {
      throw StateError('the WebGL2 context is lost');
    }
    const int fb = web.WebGL2RenderingContext.FRAMEBUFFER;
    _gl
      ..bindFramebuffer(fb, surfaceFramebuffer)
      ..viewport(0, 0, viewportWidth, viewportHeight)
      ..disable(web.WebGL2RenderingContext.DEPTH_TEST)
      ..disable(web.WebGL2RenderingContext.CULL_FACE)
      ..disable(web.WebGL2RenderingContext.SCISSOR_TEST);
    final SparseGlExecutionStats stats = executor.submit(
      plan,
      materials: materials,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
      yFlip: yFlip,
    );
    if (checkError('sparse-strip draw')) {
      throw StateError('${_lastError ?? 'the sparse WebGL2 draw failed'}');
    }
    return stats;
  }

  /// Compiles the sparse program, or says why the context refused it.
  ///
  /// Returns a diagnostic rather than throwing, so an opt-in the context
  /// rejects reports itself the way a probe does and [adoptContext] hands it
  /// back instead of raising out of device creation.
  BackendDiagnostic? _initialiseSparseStrips() {
    if (!_sparseStripsRequested) return null;
    final WebGlSparseDriver driver = _sparseDriver ??= WebGlSparseDriver(this);
    final SparseGlExecutor executor = _sparseExecutor ??= SparseGlExecutor(
      driver,
      textureAllocator: this,
    );
    try {
      // `desktop: false` for `_kWebGlUsesEsDialect`'s reason: GLSL ES 3.00 is
      // exactly the language WebGL2 accepts.
      executor.initialize(desktop: !_kWebGlUsesEsDialect);
    } on Object catch (error) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the opt-in sparse WebGL2 pipeline could not be initialized',
        detail: '$error',
      );
    }
    if (checkError('sparse WebGL2 initialisation')) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'WebGL2 rejected the opt-in sparse renderer objects',
        detail: _lastError?.detail,
      );
    }
    return null;
  }

  void _drawBatches(
    GpuBatcher batcher,
    int first,
    int last,
    int viewportWidth,
    int viewportHeight,
    int yFlip,
    _DrawState state,
  ) {
    _gl
      ..uniform2f(
          _uniformViewport, viewportWidth.toDouble(), viewportHeight.toDouble())
      ..uniform1i(_uniformYFlip, yFlip);

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

      // GL's scissor origin is the bottom-left corner and device space's is the
      // top-left, so the y is flipped - unless this pass already inverted its
      // projection to write the target top-down, in which case device row 0 is
      // framebuffer row 0 and flipping again would scissor the mirror image of
      // the batch's clip.
      _gl.scissor(
        left,
        yFlip == kYFlipTopDown ? top : viewportHeight - bottom,
        right - left,
        bottom - top,
      );

      if (batch.blendMode != state.blendMode) {
        state.blendMode = batch.blendMode;
        final GpuBlendState blend = gpuBlendForMode(batch.blendMode);
        _gl.blendFunc(_glFactor(blend.source), _glFactor(blend.destination));
      }
      final int mode = switch (batch.pipeline) {
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
        // The one lookup a browser costs that a desktop GL does not. Per batch,
        // which is the same order as this filter itself; `kNoTexture` is 0 and
        // resolves to null, which unbinds - exactly what a solid batch wants.
        _gl.bindTexture(
          web.WebGL2RenderingContext.TEXTURE_2D,
          textures.lookup(batch.textureId),
        );
      }
      _gl.drawElements(
        web.WebGL2RenderingContext.TRIANGLES,
        batch.indexCount,
        web.WebGL2RenderingContext.UNSIGNED_INT,
        // A byte offset into the element buffer, where desktop GL takes a
        // pointer-shaped integer. Four bytes per index.
        batch.indexOffset * 4,
      );
    }
  }

  final _DrawState _drawState = _DrawState();

  void _uploadGeometry(GpuBatcher batcher) {
    final GpuVertexBuffer buffer = batcher.buffer;
    final int floatCount = buffer.vertexCount * kGpuFloatsPerVertex;
    final Float32List vertexStaging = _ensureVertexStaging(floatCount);
    vertexStaging.setRange(0, floatCount, buffer.vertexStorage);
    _gl
      ..bindBuffer(web.WebGL2RenderingContext.ARRAY_BUFFER, _vbo)
      ..bufferData(
        web.WebGL2RenderingContext.ARRAY_BUFFER,
        Float32List.sublistView(vertexStaging, 0, floatCount).toJS,
        web.WebGL2RenderingContext.DYNAMIC_DRAW,
      );

    final int indexCount = buffer.indexCount;
    final Uint32List indexStaging = _ensureIndexStaging(indexCount);
    indexStaging.setRange(0, indexCount, buffer.indexStorage);
    _gl
      ..bindBuffer(web.WebGL2RenderingContext.ELEMENT_ARRAY_BUFFER, _ebo)
      ..bufferData(
        web.WebGL2RenderingContext.ELEMENT_ARRAY_BUFFER,
        Uint32List.sublistView(indexStaging, 0, indexCount).toJS,
        web.WebGL2RenderingContext.DYNAMIC_DRAW,
      );
    checkError('bufferData');
  }

  /// Reads the bound framebuffer into [destination], flipping rows.
  ///
  /// GL hands back rows bottom-up because its framebuffer origin is at the
  /// bottom left; [Framebuffer] is top-down. The flip is here rather than in
  /// the shader because flipping the projection instead would put the whole
  /// renderer in a coordinate system that disagrees with every rectangle the
  /// layout produced.
  ///
  /// **Only the offscreen target may call this.** It is public because that
  /// target is in this library and Dart has no narrower visibility; the canvas
  /// target does not call it, and section 23 of the roadmap is why.
  bool readPixelsInto(Framebuffer destination) {
    if (_submissionsStopped) {
      _blockedSubmissionCount++;
      return false;
    }
    if (!checkContextAlive()) return false;
    final int width = destination.width;
    final int height = destination.height;
    final int bytes = width * height * 4;
    final Uint8List staging = _ensurePixelStaging(bytes);
    final JSUint8Array view = Uint8List.sublistView(staging, 0, bytes).toJS;
    _gl
      ..pixelStorei(web.WebGL2RenderingContext.PACK_ALIGNMENT, 1)
      ..readPixels(
        0,
        0,
        width,
        height,
        web.WebGL2RenderingContext.RGBA,
        web.WebGL2RenderingContext.UNSIGNED_BYTE,
        view,
      );
    if (checkError('readPixels')) return false;
    // Under dart2wasm a typed list handed to JS may be a *copy* rather than a
    // view onto the same memory, so the bytes the browser wrote are read back
    // out of the JS array rather than assumed to have landed in `staging`.
    // Reading through `toDart` is correct under both compilers; assuming the
    // aliasing that dart2js happens to give would make this backend read an
    // all-zero surface under wasm, which looks like a renderer that drew
    // nothing.
    final Uint8List source = view.toDart;
    final bool swizzle =
        destination.format == PixelFormat.bgra8888Premultiplied;
    for (var y = 0; y < height; y++) {
      final int sourceRow = (height - 1 - y) * width * 4;
      final int destinationRow = y * destination.bytesPerRow;
      if (!swizzle) {
        destination.pixels.setRange(
          destinationRow,
          destinationRow + width * 4,
          source,
          sourceRow,
        );
        continue;
      }
      // There is no BGRA upload/download format in ES core, so the swizzle is
      // done here instead of asked of the driver. It costs a pass over the
      // surface, which only the readback path pays.
      for (var x = 0; x < width; x++) {
        final int s = sourceRow + x * 4;
        final int d = destinationRow + x * 4;
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
    if (_gl.isContextLost()) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'the WebGL2 context is lost',
      );
    }

    final Object vertex = _compile(
      web.WebGL2RenderingContext.VERTEX_SHADER,
      vertexShaderSource(desktop: !_kWebGlUsesEsDialect),
    );
    if (vertex is BackendDiagnostic) return vertex;
    final Object fragment = _compile(
      web.WebGL2RenderingContext.FRAGMENT_SHADER,
      fragmentShaderSource(desktop: !_kWebGlUsesEsDialect),
    );
    if (fragment is BackendDiagnostic) {
      _gl.deleteShader(vertex as web.WebGLShader);
      return fragment;
    }

    final web.WebGLProgram? program = _gl.createProgram();
    if (program == null) {
      _gl
        ..deleteShader(vertex as web.WebGLShader)
        ..deleteShader(fragment as web.WebGLShader);
      return const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'the WebGL2 context refused to create a program',
        detail: 'createProgram returned null, which is what a lost context '
            'answers',
      );
    }
    _program = program;
    _gl
      ..attachShader(program, vertex as web.WebGLShader)
      ..attachShader(program, fragment as web.WebGLShader);
    // Bound before linking so neither GLSL dialect needs a `layout(location=)`
    // qualifier, matching `gl_backend.dart`.
    for (var i = 0; i < kAttributeNames.length; i++) {
      _gl.bindAttribLocation(program, i, kAttributeNames[i]);
    }
    _gl.linkProgram(program);
    if (!_programParameterIsTrue(
        program, web.WebGL2RenderingContext.LINK_STATUS)) {
      final String log = _gl.getProgramInfoLog(program) ?? '';
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

    _uniformViewport = _gl.getUniformLocation(program, 'uViewport');
    _uniformTexture = _gl.getUniformLocation(program, 'uTexture');
    _uniformMode = _gl.getUniformLocation(program, 'uMode');
    _uniformYFlip = _gl.getUniformLocation(program, 'uYFlip');
    if (_uniformViewport == null ||
        _uniformMode == null ||
        _uniformYFlip == null) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the linked program is missing a uniform the renderer needs',
        detail: 'uViewport, uMode or uYFlip was optimised away, which means '
            'the shader source and this file have drifted apart. uYFlip in '
            'particular decides which way up a layer is drawn, and a driver '
            'that folded it away would render every layer mirrored',
      );
    }

    _vao = _gl.createVertexArray();
    _gl.bindVertexArray(_vao);
    _vbo = _gl.createBuffer();
    _ebo = _gl.createBuffer();

    const int stride = kGpuFloatsPerVertex * 4;
    _gl
      ..bindBuffer(web.WebGL2RenderingContext.ARRAY_BUFFER, _vbo)
      ..bindBuffer(web.WebGL2RenderingContext.ELEMENT_ARRAY_BUFFER, _ebo);
    _attribute(kAttributePosition, 2, kGpuPositionOffset * 4, stride);
    _attribute(kAttributeTexCoord, 2, kGpuTexCoordOffset * 4, stride);
    _attribute(kAttributeColor, 4, kGpuColorOffset * 4, stride);
    _attribute(kAttributeShapeRect, 4, kGpuShapeRectOffset * 4, stride);

    if (checkError('device initialisation')) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'WebGL2 reported an error while creating the renderer objects',
        detail: _lastError?.detail,
      );
    }
    return null;
  }

  void _attribute(int index, int size, int offset, int stride) {
    _gl
      ..enableVertexAttribArray(index)
      ..vertexAttribPointer(
        index,
        size,
        web.WebGL2RenderingContext.FLOAT,
        false,
        stride,
        offset,
      );
  }

  /// Returns the shader on success, a [BackendDiagnostic] on failure.
  Object _compile(int type, String source) {
    final web.WebGLShader? shader = _gl.createShader(type);
    if (shader == null) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'the WebGL2 context refused to create a shader',
        detail: 'createShader returned null, which is what a lost context '
            'answers',
      );
    }
    _gl
      ..shaderSource(shader, source)
      ..compileShader(shader);
    if (_shaderParameterIsTrue(
        shader, web.WebGL2RenderingContext.COMPILE_STATUS)) {
      return shader;
    }
    // The driver's own message, verbatim. Anything less turns a one-line GLSL
    // error into an afternoon.
    final String log = _gl.getShaderInfoLog(shader) ?? '';
    _gl.deleteShader(shader);
    return BackendDiagnostic(
      kind: DiagnosticKind.incompatibleDevice,
      message: type == web.WebGL2RenderingContext.VERTEX_SHADER
          ? 'vertex shader failed to compile'
          : 'fragment shader failed to compile',
      detail: log,
    );
  }

  bool _shaderParameterIsTrue(web.WebGLShader shader, int pname) {
    final JSAny? value = _gl.getShaderParameter(shader, pname);
    return value != null && (value as JSBoolean).toDart;
  }

  bool _programParameterIsTrue(web.WebGLProgram program, int pname) {
    final JSAny? value = _gl.getProgramParameter(program, pname);
    return value != null && (value as JSBoolean).toDart;
  }

  /// Whether the context is still usable, marking the device lost when not.
  ///
  /// The replacement for `GlRenderDevice.makeCurrentOrLose`, and the reason
  /// this must be asked rather than assumed: on a lost WebGL context every
  /// entry point is *defined* to become a no-op that raises nothing. A device
  /// that skipped this check would issue a whole frame of draws into nothing,
  /// return success, and present an empty canvas - which reads as a bug in the
  /// scene, not as a lost GPU.
  ///
  /// Never throws. A lost context is a state the caller reports, not an
  /// exception it catches.
  bool checkContextAlive() {
    if (_state.isLost) return false;
    if (!_gl.isContextLost()) return true;
    _state.markLost(
      const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'the WebGL2 context was lost',
        detail: 'isContextLost() reports true. The browser drops a context '
            'when the GPU process restarts, when the page has too many live '
            'contexts, and sometimes when a tab is backgrounded. The canvas '
            'fires webglcontextrestored when it comes back, and the owner may '
            'run a recovery from there',
      ),
    );
    return false;
  }

  /// The last WebGL error this device saw that was not fatal, or null.
  BackendDiagnostic? get lastError => _lastError;
  BackendDiagnostic? _lastError;

  /// Drains the error queue, and decides whether the device survived it.
  ///
  /// Returns true when something was wrong. Only two errors mark the device
  /// lost, and the distinction is the specification's own: `OUT_OF_MEMORY` and
  /// `CONTEXT_LOST_WEBGL` leave the contents of every object undefined, while
  /// every other error is defined to have "no other side effect than to set the
  /// error flag" - the command is ignored and the context is still valid.
  /// Treating all of them as loss would turn one bad enum into a device that
  /// could never draw again, which is a worse failure than the bug it reports.
  bool checkError(String what) {
    final int error = _drainErrors();
    if (error == web.WebGL2RenderingContext.NO_ERROR) {
      _lastError = null;
      return false;
    }
    final bool fatal = error == _kContextLostWebGl ||
        error == web.WebGL2RenderingContext.OUT_OF_MEMORY;
    final BackendDiagnostic diagnostic = BackendDiagnostic(
      kind: error == _kContextLostWebGl
          ? DiagnosticKind.connectionFailed
          : DiagnosticKind.incompatibleDevice,
      message: switch (error) {
        _kContextLostWebGl => 'the WebGL2 context was lost',
        web.WebGL2RenderingContext.OUT_OF_MEMORY =>
          'the browser ran out of GPU memory during $what',
        _ => 'WebGL error during $what',
      },
      detail: '0x${error.toRadixString(16)}',
    );
    _lastError = diagnostic;
    if (fatal) _state.markLost(diagnostic);
    return true;
  }

  /// Empties the error queue, answering the first error it held.
  ///
  /// A loop rather than one `getError`, because the queue holds one error per
  /// failing call and leaving the rest behind would report them against
  /// whichever innocent call asked next. Bounded so a context that answers an
  /// error forever - which a lost one does - cannot spin the frame loop.
  int _drainErrors() {
    final int first = _gl.getError();
    if (first == web.WebGL2RenderingContext.NO_ERROR) return first;
    for (var i = 0; i < 32; i++) {
      if (_gl.getError() == web.WebGL2RenderingContext.NO_ERROR) break;
    }
    return first;
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

  static int _glFactor(GpuBlendFactor factor) => switch (factor) {
        GpuBlendFactor.zero => web.WebGL2RenderingContext.ZERO,
        GpuBlendFactor.one => web.WebGL2RenderingContext.ONE,
        GpuBlendFactor.oneMinusSrcAlpha =>
          web.WebGL2RenderingContext.ONE_MINUS_SRC_ALPHA,
      };

  @override
  void onDispose() {
    // The opt-in inventory first, and only through its executor: it is the one
    // that knows which pages, buffers and programs exist. A lost context gets
    // the loss variant, which forgets the handles rather than deleting objects
    // the browser already reclaimed.
    final SparseGlExecutor? sparse = _sparseExecutor;
    if (sparse != null && !sparse.isDisposed) {
      if (_state.isLost || _gl.isContextLost()) {
        sparse.disposeAfterDeviceLoss();
      } else {
        sparse.dispose();
      }
    }
    _sparseExecutor = null;
    _sparseDriver = null;
    // Only when the context is still usable. On a lost context every delete is
    // a no-op anyway, and the objects are gone.
    if (!_state.isLost && !_gl.isContextLost()) {
      if (_vbo != null) _gl.deleteBuffer(_vbo);
      if (_ebo != null) _gl.deleteBuffer(_ebo);
      if (_vao != null) _gl.deleteVertexArray(_vao);
      if (_program != null) _gl.deleteProgram(_program);
    }
    _program = null;
    _vao = null;
    _vbo = null;
    _ebo = null;
    textures.clear();
    // The canvas and its context belong to the page. Disposing a device does
    // not remove either, which is the whole reason `adoptContext` says it
    // borrows.
  }
}

/// The `WEBGL_lose_context` extension object.
///
/// Declared here rather than imported because `package:web` has none: it is
/// generated from the WebIDL of the DOM specifications, and a WebGL *extension*
/// is defined by the WebGL extension registry instead. An extension type over
/// `JSObject` is the typed way to name one - the cast is unchecked either way,
/// since every extension object is a plain `JSObject` at runtime, but this puts
/// the method name in one place where a typo is a compile error rather than a
/// string that silently does nothing.
extension type _WebGlLoseContext._(JSObject _) implements JSObject {
  external void loseContext();
}

/// `CONTEXT_LOST_WEBGL`, which is a WebGL-only error code.
///
/// Not a member of `WebGL2RenderingContext` in `package:web` because it is
/// defined by the WebGL specification rather than by ES, so it is written out
/// here with its specification value.
const int _kContextLostWebGl = 0x9242;

/// Reads an integer context parameter, or [fallback] when the browser will not
/// answer.
///
/// A lost context answers null to every `getParameter`, and so does a browser
/// that has disabled the query. Falling back rather than throwing keeps device
/// creation on the "report it" path: 2048 is the smallest `MAX_TEXTURE_SIZE`
/// WebGL2 is allowed to have, so a device built on the fallback refuses
/// textures it might actually have supported rather than accepting ones it
/// cannot hold.
int _intParameter(
  web.WebGL2RenderingContext gl,
  int pname, {
  required int fallback,
}) {
  try {
    final JSAny? value = gl.getParameter(pname);
    if (value == null) return fallback;
    return (value as JSNumber).toDartInt;
  } on Object {
    return fallback;
  }
}

/// A human description of what is behind [gl], for [RendererInfo] and logs.
///
/// Prefers the unmasked strings `WEBGL_debug_renderer_info` exposes, because
/// "ANGLE (NVIDIA GeForce RTX 3070 Direct3D11 vs_5_0 ps_5_0)" is the line that
/// makes a bug report actionable and the masked `RENDERER` is the constant
/// string "WebKit WebGL" on several browsers. The extension is absent in
/// Firefox with `privacy.resistFingerprinting` and in any browser where the
/// user disabled it, so its absence is normal and falls back to the masked
/// pair rather than being reported as a fault.
String describeWebGlContext(web.WebGL2RenderingContext gl) {
  String? read(int pname) {
    try {
      final JSAny? value = gl.getParameter(pname);
      if (value == null) return null;
      return (value as JSString).toDart;
    } on Object {
      return null;
    }
  }

  const int unmaskedVendor = 0x9245;
  const int unmaskedRenderer = 0x9246;
  final bool hasDebugInfo =
      gl.getExtension('WEBGL_debug_renderer_info') != null;
  final String? renderer = (hasDebugInfo ? read(unmaskedRenderer) : null) ??
      read(web.WebGL2RenderingContext.RENDERER);
  final String? vendor = (hasDebugInfo ? read(unmaskedVendor) : null) ??
      read(web.WebGL2RenderingContext.VENDOR);
  final String? version = read(web.WebGL2RenderingContext.VERSION);
  final List<String> parts = <String>[
    if (vendor != null && vendor.isNotEmpty) vendor,
    if (renderer != null && renderer.isNotEmpty) renderer,
    if (version != null && version.isNotEmpty) version,
  ];
  return parts.isEmpty ? 'WebGL2, adapter not reported' : parts.join(', ');
}

/// A render target backed by a framebuffer object, which reads its pixels back.
///
/// The target the parity suite uses: it renders with no canvas on the page and
/// no compositor involved, and hands back a [Framebuffer] that can be compared
/// against `CpuRasterizer` byte for byte.
final class WebGlOffscreenTarget
    with DisposableMixin
    implements RenderTarget, WebGlRecoverableTarget {
  WebGlOffscreenTarget._(this._device, MemorySurfaceDescriptor surface)
      : _surface = surface {
    _maskAtlas = GpuMaskAtlas();
    _glyphAtlas = GpuGlyphAtlas();
    _fonts = WebGlFontResolver();
    _images = WebGlImageCache(_device);
    _buildAtlasObjects();
    final BackendDiagnostic? failure = _createSurfaceObjects();
    if (failure != null) _device.state.markLost(failure);
    _device.registerTarget(this);
  }

  final WebGlRenderDevice _device;
  final GpuBatcher _batcher = GpuBatcher();

  late final GpuMaskAtlas _maskAtlas;
  late final GpuGlyphAtlas _glyphAtlas;
  late final WebGlFontResolver _fonts;
  late final WebGlImageCache _images;

  // Not final: a context loss destroys every one of these and a recovery
  // rebuilds them. The sink in particular is rebuilt rather than mutated,
  // because it holds the mask and glyph texture *ids* as final fields and a
  // recreated texture gets a new id - a sink that kept the old one would batch
  // every mask against a texture that no longer exists.
  late WebGlTexture _maskTexture;
  late WebGlTexture _glyphTexture;
  late WebGlFramebufferPool _layerPool;
  late GpuLayerStack _layers;
  late GpuRasterSink _sink;
  late DisplayListPlayer _player;

  void _buildAtlasObjects() {
    _maskTexture = _device.createTexture(
      width: _maskAtlas.width,
      height: _maskAtlas.height,
      format: GpuTextureFormat.alpha8,
      // One texel per pixel by construction, so nearest reproduces the CPU
      // rasteriser's coverage byte exactly and linear would blur it. This is
      // the filter the parity claim rests on.
      filter: GpuTextureFilter.nearest,
    );
    _glyphTexture = _device.createTexture(
      width: _glyphAtlas.width,
      height: _glyphAtlas.height,
      format: GpuTextureFormat.alpha8,
      // Nearest, for the mask atlas's reason and one of its own: a glyph quad
      // is placed on whole pixels precisely so one texel is one pixel, and a
      // linear tap would resample coverage that already sits on the grid.
      filter: GpuTextureFilter.nearest,
    );
    _layerPool = WebGlFramebufferPool(
      gl: _device.gl,
      textures: _device.textures,
      onError: _device.state.markLost,
    );
    _layers = GpuLayerStack(
      allocator: _layerPool,
      backendName: WebGlRendererBackend.backendName,
    );
    _sink = GpuRasterSink(
      batcher: _batcher,
      backendName: WebGlRendererBackend.backendName,
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

  @override
  Iterable<GpuRecoverableResource> recoverableResources() sync* {
    yield CallbackGpuResource.fixed(
      resourceName: 'webgl2 offscreen atlases '
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
      resourceName: 'webgl2 offscreen surface '
          '${_surface.pixelWidth}x${_surface.pixelHeight}',
      recovery: GpuResourceRecovery.recreated,
      onDiscard: _forgetSurfaceObjects,
      onRepopulate: _createSurfaceObjects,
    );
    yield* _images.recoverableResources();
  }

  void _discardAtlasObjects() {
    // The frame in flight goes with the device: its batches name textures the
    // browser has reclaimed, so it must never be submitted after the recovery.
    _batcher.beginFrame();
    _submittedBatches = 0;
    _pendingClear = null;
    _layers.endFrame();
    _layerPool.forget();
    _device
      ..releaseTexture(_maskTexture)
      ..releaseTexture(_glyphTexture);
    // Both atlases are caches that outlive a frame, so both have to be told
    // their texels are gone. The mask atlas is the one that is easy to miss:
    // its `beginFrame` deliberately keeps every cached mask, so a static
    // rounded rectangle drawn before the loss would be found resident,
    // re-batched against a texture that was never re-uploaded, and drawn as
    // nothing at all.
    _maskAtlas.recycle();
    _glyphAtlas.clear();
  }

  BackendDiagnostic? _repopulateAtlasObjects() {
    try {
      _buildAtlasObjects();
    } on UnsupportedCapabilityError catch (error) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the recovered WebGL2 device refused an atlas texture',
        detail: '$error',
      );
    }
    return _device.lastError;
  }

  void _forgetSurfaceObjects() {
    // No deleteFramebuffer and no releaseTexture that reaches the context: both
    // refer to objects a lost context already reclaimed.
    _fbo = null;
    _device.releaseTexture(_colorTexture);
  }

  int _submittedBatches = 0;

  WebGlImageCache get images => _images;

  /// The glyph coverage this target keeps between frames. Exposed for the
  /// questions that are invisible from the pixels: whether a static screen
  /// stopped rasterising after its first frame, and whether a full atlas was
  /// recycled mid-frame.
  GpuGlyphAtlas get glyphAtlas => _glyphAtlas;

  /// `texSubImage2D` calls this target has made for glyph coverage. A frame
  /// that redraws the same text must not increase it.
  int get glyphUploadCount => _glyphUploadCount;
  int _glyphUploadCount = 0;

  /// Where layers get their offscreen targets. Exposed for a memory report and
  /// for a test that asserts the same layer drawn on ten frames created one
  /// framebuffer; reuse is invisible from the pixels.
  WebGlFramebufferPool get layerPool => _layerPool;

  GpuLayerStack get layers => _layers;

  GpuBatcher get batcher => _batcher;

  MemorySurfaceDescriptor _surface;
  late WebGlTexture _colorTexture;
  web.WebGLFramebuffer? _fbo;
  late Framebuffer _readback;
  int _generation = 0;
  int _observedLossCount = 0;

  /// The last pixels read back. Golden and parity tests read this after
  /// [present].
  Framebuffer get framebuffer => _readback;

  /// This target's framebuffer object, for an alternative executor's seam.
  ///
  /// The dense renderer never needs it - [present] binds `_fbo` itself - but
  /// `WebGlRenderDevice.submitSparseStrips` takes an attachment, and a test
  /// that wants to compare sparse pixels against the CPU rasteriser has to be
  /// able to name the one this target reads back from. Null before the surface
  /// objects exist and after a context loss discards them.
  web.WebGLFramebuffer? get debugFramebuffer => _fbo;

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
    // Advances the frame counter the glyph atlas's LRU compares against, and
    // keeps every glyph. Skipping it would leave every plot looking used by the
    // frame in progress, so nothing could be evicted and the atlas would report
    // itself permanently full.
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

  int? _pendingClear;

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
    if (!_device.checkContextAlive()) {
      return _device.state.blockedPresent() ??
          const PresentResult(
            status: PresentStatus.deviceLost,
            diagnostic: BackendDiagnostic(
              kind: DiagnosticKind.connectionFailed,
              message: 'the WebGL2 context was lost before the present',
            ),
          );
    }

    _device.gl.bindFramebuffer(web.WebGL2RenderingContext.FRAMEBUFFER, _fbo);
    _uploadMaskAtlas();
    _uploadGlyphAtlas();

    final int? clear = _pendingClear;
    _pendingClear = null;
    final bool drawn = _device.submit(
      _batcher,
      _readback.width,
      _readback.height,
      clear,
      layers: _layers,
      surfaceFramebuffer: _fbo,
      layerPool: _layerPool,
      firstBatch: _submittedBatches,
    );
    _submittedBatches = _batcher.batchCount;
    // After the draws and never before: until they are issued, the composite
    // quads are still going to sample those layer textures.
    _layers.endFrame();
    if (drawn) _device.readPixelsInto(_readback);

    final PresentResult? lost = _device.state.blockedPresent();
    if (lost != null) return lost;
    return const PresentResult(status: PresentStatus.presented);
  }

  /// Uploads what the frame's masks wrote, over whole rows.
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
  /// One `texSubImage2D` per dirty plot, so a page redrawing the same label
  /// sixty times a second uploads nothing after the first frame - which is the
  /// entire reason the glyph atlas survives [beginFrame] while the mask atlas
  /// does not.
  ///
  /// Orientation: an atlas is *uploaded*, not rendered into, so `uYFlip` does
  /// not apply - that uniform inverts the projection of a pass whose output is
  /// sampled later. `texSubImage2D` puts the first row it is given at texture
  /// row `y`, and the staging image is top-down, so atlas row `y` is texture
  /// coordinate `y / height`, which is what the sink computes for the *top*
  /// edge of a glyph quad. Getting it wrong draws text upside down, and the
  /// failure hides: Ahem's glyphs are solid squares and a square is its own
  /// mirror image.
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

  /// The backend's half of the atlas flush protocol - see
  /// [GpuRasterSink.onAtlasFlush]. Upload first, because the batches about to
  /// be drawn sample texels that so far exist only in the staging image; submit
  /// second, and remember how far it got.
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
      layers: _layers,
      surfaceFramebuffer: _fbo,
      layerPool: _layerPool,
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
    if (failure != null) _device.state.markLost(failure);
  }

  /// Rasterises [list] into this target and presents it.
  ///
  /// Mirrors `GlOffscreenTarget.renderDisplayList` argument for argument, so a
  /// parity test can swap one for the other and compare.
  Future<PresentResult> renderDisplayList(
    DisplayList list, {
    int? clearColor,
    Transform2D deviceTransform = Transform2D.identity,
  }) async {
    final Frame frame = beginFrame(FrameRequest(clearColor: clearColor));
    // The sink is handed a font *id* and resolves it through the same resource
    // table the player walks, so the two cannot disagree about which face an id
    // names.
    final DisplayListResources resources = DisplayListResources(list);
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

  /// Allocates the readback buffer, the colour texture and the framebuffer.
  ///
  /// Returns a diagnostic instead of marking the device lost, because it is
  /// called from two places that want opposite things: the constructor and
  /// [resize] turn a failure into a loss, and a recovery must not - a recovery
  /// that marked the device lost again would be indistinguishable from a second
  /// context loss and would burn one of the policy's attempts on its own bug.
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
    final web.WebGL2RenderingContext gl = _device.gl;
    _fbo = gl.createFramebuffer();
    if (_fbo == null) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'the WebGL2 context refused an offscreen framebuffer',
        detail: 'createFramebuffer returned null, which is what a lost context '
            'answers',
      );
    }
    const int fb = web.WebGL2RenderingContext.FRAMEBUFFER;
    gl
      ..bindFramebuffer(fb, _fbo)
      ..framebufferTexture2D(
        fb,
        web.WebGL2RenderingContext.COLOR_ATTACHMENT0,
        web.WebGL2RenderingContext.TEXTURE_2D,
        _colorTexture.object,
        0,
      );
    final int status = gl.checkFramebufferStatus(fb);
    if (status != web.WebGL2RenderingContext.FRAMEBUFFER_COMPLETE) {
      return BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'the offscreen framebuffer is incomplete',
        detail: 'checkFramebufferStatus returned 0x'
            '${status.toRadixString(16)} for '
            '${_surface.pixelWidth}x${_surface.pixelHeight}',
      );
    }
    _device.checkError('framebuffer creation');
    return _device.lastError;
  }

  void _destroySurfaceObjects() {
    if (_fbo != null && !_device.state.isLost) {
      _device.gl.deleteFramebuffer(_fbo);
    }
    _fbo = null;
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
    _device
      ..releaseTexture(_maskTexture)
      ..releaseTexture(_glyphTexture);
    _glyphAtlas.clear();
    _fonts.bind(null);
  }
}

/// Turns the display list's interned font ids into faces for the sink.
///
/// Identical in shape to `GlFontResolver`, and for the reason that file gives:
/// the sink is handed a raw `fontId` because the player never asks what a glyph
/// looks like, so whoever has to rasterise must be able to look one up - in the
/// *same* table the player is walking, or the two would disagree about which
/// face an id names the first time a list was replayed with different
/// resources.
final class WebGlFontResolver implements GpuFontResolver {
  ReplayResources? _resources;

  void bind(ReplayResources? resources) => _resources = resources;

  @override
  ScaledTypeface? resolveFont(int fontId) {
    final ReplayResources? resources = _resources;
    if (resources == null) return null;
    final Object font = resources.fontAt(fontId);
    // Not a cast: the display list stores a font as an opaque `Object`, and a
    // list built by something that interned another kind of face must be
    // refused by name rather than crash with a type error mid-frame.
    return font is ScaledTypeface ? font : null;
  }
}

/// One image this cache uploaded, and whether it could do it again.
final class _WebGlImageEntry {
  _WebGlImageEntry({
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
  WebGlTexture? texture;
  Framebuffer? source;

  bool get isRecoverable => source != null;

  String get name => 'webgl2 image #$index (${width}x$height)';
}

/// Uploads drawn images into textures, once each, and can do it again.
///
/// The port of `GlImageCache`, including its two-part design: the lookup is an
/// [Expando] whose keys are weak and hold nothing, and the retention is a field
/// on the entry. A `Map` key would do both jobs at once, which makes "drop the
/// bytes to save memory" inexpressible.
final class WebGlImageCache implements GpuImageResolver {
  WebGlImageCache(
    this._device, {
    this.retention = GpuImageSourceRetention.retain,
  });

  final WebGlRenderDevice _device;

  final GpuImageSourceRetention retention;

  final Expando<_WebGlImageEntry> _byImage = Expando<_WebGlImageEntry>();
  final List<_WebGlImageEntry> _entries = <_WebGlImageEntry>[];

  /// Where a decoded video frame becomes a texture.
  ///
  /// A separate cache and not another kind of entry above, because the entries
  /// above are keyed by image identity and never evict - which is right for a
  /// still and ruinous for a stream that produces a new object twenty-five
  /// times a second. See `gpu_video_image.dart` for the whole argument and for
  /// how one texture per stream is reused instead.
  ///
  /// [ImageChannelOrder.rgba] because [_upload] creates every image texture as
  /// `rgba8888Premultiplied` and [_asRgba] swizzles a BGRA source into it; the
  /// video conversion writes that order directly instead.
  late final GpuVideoImageCache _video = GpuVideoImageCache(
    _device,
    channelOrder: ImageChannelOrder.rgba,
  );

  int get length => _entries.length;

  /// The video streams this cache holds a texture for. One per stream, never
  /// one per frame.
  int get videoStreamCount => _video.streamCount;

  /// How many bytes of image source this cache is keeping alive. Zero under
  /// [GpuImageSourceRetention.uploadOnly].
  int get retainedSourceBytes {
    var bytes = 0;
    for (final _WebGlImageEntry entry in _entries) {
      if (entry.source != null) bytes += entry.width * entry.height * 4;
    }
    return bytes;
  }

  /// Entries whose source is gone, so a context loss would strand them.
  int get unrecoverableCount =>
      _entries.where((_WebGlImageEntry e) => !e.isRecoverable).length;

  @override
  GpuTextureHandle? resolve(Object image) {
    // A VideoFrame is not a Framebuffer, and returning null for it is what
    // made every accelerated backend refuse to draw video by name. The video
    // cache answers null for anything that is not a frame either, so this
    // stays the single "this device cannot draw it" exit.
    if (image is! Framebuffer) return _video.resolve(image);
    final _WebGlImageEntry? cached = _byImage[image];
    if (cached != null) {
      final WebGlTexture? texture = cached.texture;
      if (texture != null && texture.isValid) return texture;
      if (!cached.isRecoverable) {
        // The honest refusal. The texture died with the context and the bytes
        // that made it are gone, so there is nothing to upload. Null is the
        // sink's "this device cannot draw it", which becomes a named error.
        return null;
      }
    }

    final WebGlTexture? texture = _upload(image);
    if (texture == null) return null;
    if (cached != null) {
      cached.texture = texture;
      return texture;
    }
    final _WebGlImageEntry entry = _WebGlImageEntry(
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

  WebGlTexture? _upload(Framebuffer image) {
    final WebGlTexture texture;
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
      // Larger than the device allows, or the context is lost. Null is the
      // sink's "this device cannot draw it", which becomes a named error rather
      // than a dead texture.
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
  /// context loss strands it, because there is no second copy of the pixels.
  bool dropSource(Object image) {
    if (image is! Framebuffer) return false;
    final _WebGlImageEntry? entry = _byImage[image];
    if (entry == null) return false;
    entry.source = null;
    return true;
  }

  /// This cache's contribution to step 5's inventory: one resource per image,
  /// because the answer differs per image - one entry with its source is
  /// [GpuResourceRecovery.reuploaded] while the one next to it is
  /// [GpuResourceRecovery.orphaned].
  Iterable<GpuRecoverableResource> recoverableResources() sync* {
    for (final _WebGlImageEntry entry in List<_WebGlImageEntry>.of(_entries)) {
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
                  'died with the context',
            );
          }
          final WebGlTexture? texture = _upload(source);
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
    for (final _WebGlImageEntry entry in _entries) {
      final WebGlTexture? texture = entry.texture;
      if (texture != null) _device.releaseTexture(texture);
      entry.texture = null;
      entry.source = null;
      final Framebuffer? image = entry.image.target;
      if (image != null) _byImage[image] = null;
    }
    _entries.clear();
    _video.clear();
  }

  /// The image's bytes in the RGBA order `texImage2D` was told to expect.
  ///
  /// There is no BGRA upload format in ES core, so a BGRA framebuffer is
  /// swizzled here instead of being handed to the driver. Rows are repacked at
  /// the same time, because a [Framebuffer] routinely has a stride wider than
  /// its width.
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

/// The WebGL2 renderer backend.
///
/// ## Why the probe needs a canvas and makes its own
///
/// Every other backend's probe asks the operating system a question that does
/// not require a window: whether a library loads, whether a driver answers.
/// There is no equivalent here - the only way to find out whether WebGL2 works
/// in this browser is to ask a canvas for a context, and `getContext` is a
/// method on the element.
///
/// So [probe] creates a 1x1 *detached* canvas, one that is never added to the
/// document, asks it for a context and throws the whole thing away. A detached
/// canvas still gets a real context, still consumes one of the browser's
/// limited context slots for the moment it is alive, and costs nothing on the
/// page because it is never laid out or composited.
final class WebGlRendererBackend implements RendererBackend {
  const WebGlRendererBackend();

  static const String backendName = 'webgl2';

  @override
  RendererInfo get info => const RendererInfo(
        name: backendName,
        deviceDescription: 'WebGL2 on an HTML canvas',
        rasterizationApproach: RasterizationApproach.analyticCoverageAtlas,
      );

  /// Both descriptors this backend knows how to build a target for.
  @override
  bool supportsSurface(NativeSurfaceDescriptor surface) =>
      surface is MemorySurfaceDescriptor ||
      surface is WebGlCanvasSurfaceDescriptor;

  /// Whether WebGL2 can run here, and if not, exactly what was missing.
  ///
  /// Never throws - not for a browser with WebGL disabled by policy, not for a
  /// machine with no GPU process, not for a bug in this method. Section 6.6
  /// exists because a silent fallback is indistinguishable from a backend
  /// nobody tried, and a probe that throws is worse than one that lies: it
  /// takes the whole selection down with it.
  @override
  BackendProbeResult probe() {
    try {
      return _probe();
    } on Object catch (error, stack) {
      return BackendProbeResult.unsupported(
        backendName,
        BackendDiagnostic(
          kind: DiagnosticKind.unsupportedPlatform,
          message: 'the WebGL2 probe threw, which is a bug in the probe',
          detail: '$error\n$stack',
        ),
      );
    }
  }

  BackendProbeResult _probe() {
    final web.HTMLCanvasElement canvas =
        web.document.createElement('canvas') as web.HTMLCanvasElement;
    canvas
      ..width = 1
      ..height = 1;
    final web.WebGL2RenderingContext? gl = createWebGl2Context(canvas);
    if (gl == null) {
      return BackendProbeResult.unsupported(
        backendName,
        const BackendDiagnostic(
          kind: DiagnosticKind.unsupportedPlatform,
          message: 'this browser did not give a canvas a WebGL2 context',
          detail: 'getContext("webgl2") answered null or something that is not '
              'a WebGL2RenderingContext. WebGL may be disabled by policy or by '
              'the user, the machine may have no usable GPU process, or the '
              'browser may support only WebGL1 - which this backend does not '
              'target, because the renderer\'s shaders are GLSL ES 3.00',
        ),
      );
    }
    if (gl.isContextLost()) {
      return BackendProbeResult.unsupported(
        backendName,
        const BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'the WebGL2 context was born lost',
          detail: 'getContext returned a context that immediately reports '
              'isContextLost(), which is what a browser answers when the GPU '
              'process is unavailable',
        ),
      );
    }
    final BackendProbeResult supported = BackendProbeResult(
      backendName: backendName,
      supported: true,
      // `gpuPresentation` and not `cpuPresentation`: the pixels a canvas target
      // draws are handed to the page's compositor as they are, with no readback
      // and no CPU round trip. That is exactly the distinction the capability
      // was introduced to draw - see its doc comment - and it is the honest
      // answer for the canvas target even though the *offscreen* target in this
      // same backend does read pixels back, because that one exists for tests
      // and image export rather than for a screen.
      capabilities: const <Capability>{Capability.gpuPresentation},
      diagnostics: <BackendDiagnostic>[
        BackendDiagnostic.note(
          'WebGL2 is available',
          detail: describeWebGlContext(gl),
        ),
      ],
    );
    // The probe's context is released rather than kept: a browser allows a
    // small number of live WebGL contexts per page - commonly 16 - and one held
    // by a probe forever is one an application cannot have. Losing it on
    // purpose is what `WEBGL_lose_context` is for.
    _releaseProbeContext(gl);
    return supported;
  }

  static void _releaseProbeContext(web.WebGL2RenderingContext gl) {
    try {
      final JSObject? extension = gl.getExtension('WEBGL_lose_context');
      if (extension == null) return;
      (extension as _WebGlLoseContext).loseContext();
    } on Object {
      // The extension is optional and losing the context is an optimisation.
      // A browser without it simply drops the context when the detached canvas
      // is collected.
    }
  }

  /// Opens a device on a detached 1x1 canvas.
  ///
  /// The device an *offscreen* target is built on, which is what the parity
  /// suite wants: the surface it renders into is a framebuffer object of its
  /// own, so the canvas behind the context is never drawn to and its size is
  /// irrelevant. A device for a canvas on the page is built by
  /// [WebGlRenderDevice.adoptContext] from that canvas's own context instead,
  /// because a target must draw into the context that owns the canvas the
  /// compositor shows.
  @override
  Future<RenderDevice> createDevice() async {
    final web.HTMLCanvasElement canvas =
        web.document.createElement('canvas') as web.HTMLCanvasElement;
    canvas
      ..width = 1
      ..height = 1;
    final web.WebGL2RenderingContext? gl = createWebGl2Context(canvas);
    if (gl == null) {
      throw UnsupportedCapabilityError(
        backendName: backendName,
        capability: Capability.gpuPresentation,
        detail: 'this browser did not give a canvas a WebGL2 context; call '
            'probe() before createDevice() to get the reason as a diagnostic '
            'instead of an exception',
      );
    }
    final ({WebGlRenderDevice? device, BackendDiagnostic? failure}) result =
        WebGlRenderDevice.adoptContext(gl);
    final WebGlRenderDevice? device = result.device;
    if (device == null) {
      throw UnsupportedCapabilityError(
        backendName: backendName,
        capability: Capability.gpuPresentation,
        detail: 'the WebGL2 context refused the renderer objects: '
            '${result.failure}',
      );
    }
    return device;
  }
}
