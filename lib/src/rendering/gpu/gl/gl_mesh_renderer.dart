/// The OpenGL half of [MeshSceneRenderer], and the depth buffer it needs.
///
/// `gl_mesh_pipeline.dart` draws a model with GL and does it well - 3.98 ms
/// against the CPU rasteriser's 191 ms on a 451,838-triangle model - but it
/// draws into *whatever framebuffer happens to be bound* and takes a width, a
/// height and the CPU rasteriser's shading arguments. `mesh_scene.dart` asks
/// for something else: a [MeshSceneRenderer] taking a [RenderTarget] and a
/// [MeshScene], so that an application can hold one variable and have it be
/// Direct3D 11 on one machine and OpenGL on another. This file is what turns
/// the first into the second.
///
/// ## Why an adapter and not a change to `GlMeshPipeline`
///
/// The pipeline's arguments already line up with [MeshScene] field for field,
/// so `implements MeshSceneRenderer` on the pipeline itself was the shorter
/// diff. It was not taken, for two reasons that are about what the pipeline
/// *is*:
///
///   1. **The pipeline has no target and must not acquire one.** It draws into
///      the bound framebuffer, which is what lets `tool/gl_mesh_probe.dart`
///      and `gl_mesh_pipeline_test.dart` drive it against a
///      [GlMeshOffscreenSurface] they created themselves, with no
///      `GlRenderDevice` anywhere. Making it name [RenderTarget] would make
///      the mesh path depend on `gl_backend.dart`, and the probe that measures
///      it would then need a whole device to open a context it already has.
///   2. **The depth attachment is a property of the target, not of the draw.**
///      A window carries depth in its pixel format; an offscreen target does
///      not carry it at all. Deciding which is which is exactly the work the
///      pipeline is free of today, and putting it there would mean the
///      pipeline consulted a target on every frame to answer a question whose
///      answer changes only on a resize.
///
/// So the pipeline stays the thing that draws triangles, and this stays the
/// thing that knows what a [RenderTarget] is.
///
/// ## The depth attachment, and what it costs
///
/// `GlOffscreenTarget`'s framebuffer carries colour and - only when approach C
/// is enabled - stencil. It has never carried depth, and neither does anything
/// `GlFramebufferPool` hands out. A mesh drawn into one of them enables
/// `GL_DEPTH_TEST` against nothing: every fragment passes, the model draws in
/// submission order, its far side covers its near side, and **no GL error is
/// raised anywhere**. That was the blocker, and there were two ways to remove
/// it.
///
/// **Widening the pool was rejected.** Every 2D layer allocates from
/// `GlFramebufferPool`, and none of them ever enables the depth test - the
/// renderer's own `submit` disables it on the way into every pass. A
/// colour-only pooled target costs 4 bytes a pixel by
/// `GlFramebufferAttachments.byteSize`; a `GL_DEPTH_COMPONENT24` attachment is
/// a fifth colour-sized plane, so the honest figure is 8 bytes a pixel - the
/// pool's memory **doubled** for a buffer nothing in the 2D renderer reads.
/// Against `kDefaultMaxIdleBytes` that halves the idle targets an animation
/// can keep resident before reallocating; against `kDefaultMaxTotalBytes` it
/// halves how many layers a frame may open before `GlFramebufferBudgetError`.
/// And the cost is not only memory: a new size class pays a second
/// `glRenderbufferStorage`, which allocates *and zeroes* video memory, on the
/// frame a dialog first fades in. A 3D view is one surface; layers are dozens
/// per frame.
///
/// **So the mesh path owns its own attachment**, allocated to the target's
/// size and sample count and attached to the framebuffer that target draws
/// into. This is the arrangement `D3d11MeshRenderer` already reached from the
/// other end - a swap chain's back buffer has no depth-stencil view either, so
/// that renderer allocates a `D24_UNORM_S8_UINT` of its own and reallocates it
/// when the target grows. Two backends, one policy, stated in both places.
///
/// The price is named rather than hidden: one depth buffer per *renderer*, not
/// per target. A renderer alternating between two targets of different sizes
/// reallocates on every draw, which is a `glRenderbufferStorage` per frame.
/// The fix is one [GlMeshRenderer] per surface, and the counter that makes the
/// mistake visible instead of merely slow is [depthAllocationCount].
///
/// ## Framebuffer zero is not this file's to attach to
///
/// A window target draws into framebuffer 0, which has no attachment points: a
/// caller cannot give it depth, and `win32_gl_surface.dart` therefore asks for
/// `cDepthBits = 24` in the pixel format when the context is created. So the
/// window path attaches nothing and relies on that, and
/// [GlMeshPipeline.depthDiagnostic] is what says so out loud when a driver
/// hands back a format with no depth bits - which is a real outcome and a
/// silent one.
library;

import 'dart:ffi';

import '../../../foundation/diagnostics.dart';
import '../../../geometry/rect.dart';
import '../../../graphics/mesh/mesh3d.dart';
import '../../mesh/mesh_rasterizer.dart';
import '../../mesh/mesh_scene.dart';
import '../../renderer.dart';
import '../gpu_recovery.dart';
import 'gl_backend.dart';
import 'gl_bindings.dart';
import 'gl_mesh_pipeline.dart';
import 'gl_window_target.dart';

/// The result of trying to build a [GlMeshRenderer].
///
/// The same shape [GlMeshPipelineAttempt] uses, for the same reason: a driver
/// that refused a shader is a diagnostic a caller reports and falls back from,
/// not an exception that unwinds a frame.
final class GlMeshRendererAttempt {
  const GlMeshRendererAttempt(this.renderer, this.diagnostics);

  final GlMeshRenderer? renderer;
  final List<BackendDiagnostic> diagnostics;
}

/// Draws a [MeshScene] into a [GlOffscreenTarget] or a [GlWindowTarget].
///
/// One per surface - see the depth argument in the library comment. It owns GL
/// objects, so it must be disposed before the device it was built from.
final class GlMeshRenderer implements MeshSceneRenderer, GlRecoverableTarget {
  GlMeshRenderer._(this._device, this._pipeline);

  /// Builds the mesh program on [device]'s context.
  ///
  /// Makes the context current first: a `glCreateShader` issued through a
  /// context that is not current compiles into whichever context *is*, which
  /// on a machine running two GL applications is the other one's.
  static GlMeshRendererAttempt create(GlRenderDevice device) {
    if (!device.makeCurrentOrLose()) {
      return GlMeshRendererAttempt(null, <BackendDiagnostic>[
        device.lastError ??
            const BackendDiagnostic(
              kind: DiagnosticKind.connectionFailed,
              message: 'the GL context would not go current to build the mesh '
                  'program',
            ),
      ]);
    }
    final GlMeshPipelineAttempt attempt =
        GlMeshPipeline.create(gl: device.api, heap: device.heap);
    final GlMeshPipeline? pipeline = attempt.pipeline;
    if (pipeline == null) return GlMeshRendererAttempt(null, attempt.diagnostics);
    final renderer = GlMeshRenderer._(device, pipeline);
    // Registered only once the program linked, so a device never holds a
    // renderer whose repopulate is certain to fail - that would turn every
    // later recovery on this device into `recoveredWithLosses` over a
    // renderer nothing ever drew with.
    device.registerTarget(renderer);
    return GlMeshRendererAttempt(renderer, attempt.diagnostics);
  }

  final GlRenderDevice _device;

  /// Null only between a device loss and a recovery that could not put the
  /// program back. [drawScene] refuses rather than drawing with a shader name
  /// belonging to a context that no longer exists.
  GlMeshPipeline? _pipeline;

  bool _disposed = false;

  /// The pipeline this renderer draws with, for a probe that wants the numbers
  /// on it - [GlMeshPipeline.bufferUploadCount],
  /// [GlMeshPipeline.depthDiagnostic] - without going through a second object.
  ///
  /// Null after a device loss whose recovery failed.
  GlMeshPipeline? get pipeline => _pipeline;

  // The depth attachment, and the exact description of what it was made for.
  // Every field is part of the key: a target that resized, a target that was
  // recreated by a device loss, and a *different* target of the same size all
  // need a different renderbuffer, and the one that is easy to miss is the
  // middle one - GL reuses framebuffer names, so a recreated surface can come
  // back with the number the old one had.
  int _depthRenderbuffer = 0;
  int _depthFramebuffer = 0;
  int _depthWidth = 0;
  int _depthHeight = 0;
  int _depthSamples = 0;
  int _depthGeneration = -1;
  Object? _depthOwner;

  /// How many depth renderbuffers this renderer has allocated.
  ///
  /// The number that makes the one-renderer-per-surface rule checkable. A
  /// viewer orbiting one model for a hundred frames must leave this at one; a
  /// renderer alternating between two differently sized targets drives it up
  /// by one per frame, which is invisible in the pixels and is a
  /// `glRenderbufferStorage` - an allocate-and-zero of video memory - inside
  /// the frame budget.
  int get depthAllocationCount => _depthAllocationCount;
  int _depthAllocationCount = 0;

  /// Why the last [drawScene] could not give its target a depth buffer, or
  /// null.
  ///
  /// Kept rather than thrown, like [GlMeshPipeline.lastError]. Separate from
  /// [GlMeshPipeline.depthDiagnostic], which answers the *other* half of the
  /// question - that one says the bound framebuffer reported no depth bits,
  /// this one says the attachment could not be made in the first place.
  BackendDiagnostic? get depthDiagnostic => _depthDiagnostic;
  BackendDiagnostic? _depthDiagnostic;

  // -------------------------------------------------------------------
  // MeshSceneRenderer
  // -------------------------------------------------------------------

  /// Draws [scene] into [target], covering [viewport] or the whole surface.
  ///
  /// Returns [MeshRenderStats.zero] without submitting anything when the
  /// target belongs to another backend, when the device is lost, or when the
  /// target could not be given a depth buffer. The last one is a refusal and
  /// not a best effort on purpose: a mesh drawn with `GL_DEPTH_TEST` against
  /// no depth buffer is a picture with its far side over its near side and no
  /// error anywhere, and a blank frame with [depthDiagnostic] set is the only
  /// version of that a reader can act on.
  @override
  MeshRenderStats drawScene(
    RenderTarget target,
    MeshScene scene, {
    Rect? viewport,
  }) {
    _throwIfDisposed();
    final _GlMeshSurface? surface = _surfaceOf(target);
    if (surface == null) return MeshRenderStats.zero;
    final GlMeshPipeline? pipeline = _pipeline;
    if (pipeline == null || _device.state.isLost) return MeshRenderStats.zero;
    // Checked before anything is bound: binding a framebuffer through a
    // context that is not current writes into whichever context is, which on a
    // shared-GPU machine is another application's. `GlOffscreenTarget._present`
    // makes the same check for the same reason.
    if (!_device.makeCurrentOrLose()) return MeshRenderStats.zero;

    _device.api.bindFramebuffer(glFramebuffer, surface.framebuffer);
    if (!_ensureDepth(surface)) return MeshRenderStats.zero;

    final int? background = scene.backgroundArgb;
    return pipeline.render(
      mesh: scene.mesh,
      camera: scene.camera,
      width: surface.width,
      height: surface.height,
      viewport: viewport,
      shading: scene.shading,
      // The one field of [MeshScene] whose null is not a default. Null means
      // "draw over what is there", which is how a 3D view sits inside an
      // interface a 2D pass already painted, so it becomes `clear: false`
      // rather than a background colour of zero.
      clear: background != null,
      backgroundArgb: background ?? 0,
      lightDirection: scene.lightDirection,
      ambient: scene.ambient,
    );
  }

  /// Forgets the GL buffers cached for [mesh].
  @override
  void discardMesh(Mesh3D mesh) => _pipeline?.releaseMesh(mesh);

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // Before the GL objects go, so a recovery running afterwards cannot walk a
    // disposed renderer. Unregistering something never registered is a no-op,
    // which is what a `create` that failed half way needs.
    _device.unregisterTarget(this);
    if (!_device.state.isLost && _device.makeCurrentOrLose()) {
      _deleteDepth();
      _pipeline?.dispose();
    } else {
      // The context is gone; every name below indexes memory it already freed.
      // See [GlMeshPipeline.discardAfterDeviceLoss].
      _forgetDepth();
      _pipeline?.discardAfterDeviceLoss();
    }
    _pipeline = null;
  }

  // -------------------------------------------------------------------
  // The depth attachment
  // -------------------------------------------------------------------

  /// Which framebuffer and how big, for a target this renderer recognises.
  ///
  /// The one place this file knows about concrete target types, and it is
  /// unavoidable for the reason `D3d11MeshRenderer._colorTargetOf` gives:
  /// [MeshSceneRenderer] promises to take a [RenderTarget] so that the two
  /// backends can be swapped behind one call site, which means each backend
  /// has to recognise its own.
  _GlMeshSurface? _surfaceOf(RenderTarget target) => switch (target) {
        GlOffscreenTarget() => _GlMeshSurface(
            owner: target,
            // The multisampled draw buffer when there is one. Binding the
            // resolve target instead would put the model where
            // `_resolveMultisample` is about to blit the 2D frame over it.
            framebuffer: target.drawFramebuffer,
            width: target.surface.pixelWidth,
            height: target.surface.pixelHeight,
            samples: target.surfaceAttachments.sampleCount,
            generation: target.generation,
          ),
        GlWindowTarget() => _GlMeshSurface(
            owner: target,
            // Framebuffer 0: the window's back buffer, which has no attachment
            // points. Its depth comes from the pixel format the context was
            // created with; see the library comment.
            framebuffer: 0,
            width: target.surface.pixelWidth,
            height: target.surface.pixelHeight,
            samples: 1,
            generation: target.generation,
          ),
        _ => null,
      };

  /// Gives [surface] a depth buffer matching its size and sample count.
  ///
  /// False means the driver refused and nothing should be drawn. True with
  /// nothing allocated is the framebuffer-zero case.
  bool _ensureDepth(_GlMeshSurface surface) {
    if (surface.framebuffer == 0) {
      _depthDiagnostic = null;
      return true;
    }
    if (_depthRenderbuffer != 0 &&
        identical(_depthOwner, surface.owner) &&
        _depthGeneration == surface.generation &&
        _depthFramebuffer == surface.framebuffer &&
        _depthWidth == surface.width &&
        _depthHeight == surface.height &&
        _depthSamples == surface.samples) {
      return true;
    }
    _deleteDepth();

    final GlApi gl = _device.api;
    // Drained first, so a sticky error the 2D renderer left behind is not read
    // below as this allocation failing. GL errors are sticky and the whole
    // point of `drainErrors` is that the next check measures this call.
    gl.drainErrors();
    gl.genRenderbuffers(1, _device.scratchNames);
    final int renderbuffer = _device.scratchNames[0];
    if (renderbuffer == 0) {
      _depthDiagnostic = const BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'GL would not name a depth renderbuffer for the mesh pass',
      );
      return false;
    }

    gl.bindRenderbuffer(glRenderbuffer, renderbuffer);
    if (surface.samples > 1) {
      // Matched to the colour attachment's sample count, and not optional: a
      // framebuffer whose attachments disagree about samples is
      // GL_FRAMEBUFFER_INCOMPLETE_MULTISAMPLE, which turns the whole target
      // into one that draws nothing - the 2D frame included.
      gl.renderbufferStorageMultisample(
        glRenderbuffer,
        surface.samples,
        glDepthComponent24,
        surface.width,
        surface.height,
      );
    } else {
      // 24 bits, matching what `win32_gl_surface.dart` asks a window's pixel
      // format for and what `GlMeshOffscreenSurface` attaches. A comparison
      // between a window frame and an off-screen one is only meaningful when
      // both resolve depth at the same precision.
      gl.renderbufferStorage(
          glRenderbuffer, glDepthComponent24, surface.width, surface.height);
    }
    gl
      ..bindRenderbuffer(glRenderbuffer, 0)
      ..bindFramebuffer(glFramebuffer, surface.framebuffer)
      ..framebufferRenderbuffer(
          glFramebuffer, glDepthAttachment, glRenderbuffer, renderbuffer);

    final int status = gl.checkFramebufferStatus(glFramebuffer);
    final int error = gl.drainErrors();
    if (status != glFramebufferComplete || error != glNoError) {
      // Detached before it is deleted, and this is the step that is easy to
      // skip: a framebuffer left holding a name whose object was freed stays
      // incomplete, and the *2D* pass into the same target then draws nothing.
      // Failing the mesh draw must not take the interface with it.
      _device.scratchNames[0] = renderbuffer;
      gl
        ..framebufferRenderbuffer(
            glFramebuffer, glDepthAttachment, glRenderbuffer, 0)
        ..deleteRenderbuffers(1, _device.scratchNames)
        ..drainErrors();
      _depthDiagnostic = BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'the mesh pass could not attach a depth buffer to this target',
        detail: 'glCheckFramebufferStatus 0x${status.toRadixString(16)}, '
            'error 0x${error.toRadixString(16)} for ${surface.width}x'
            '${surface.height} at ${surface.samples} sample(s) with a '
            'GL_DEPTH_COMPONENT24 renderbuffer',
      );
      return false;
    }

    _depthRenderbuffer = renderbuffer;
    _depthFramebuffer = surface.framebuffer;
    _depthWidth = surface.width;
    _depthHeight = surface.height;
    _depthSamples = surface.samples;
    _depthGeneration = surface.generation;
    _depthOwner = surface.owner;
    _depthAllocationCount++;
    _depthDiagnostic = null;
    return true;
  }

  /// Detaches and deletes the depth renderbuffer. Requires a current context.
  void _deleteDepth() {
    if (_depthRenderbuffer == 0) return;
    final GlApi gl = _device.api;
    // Detached explicitly rather than relying on deletion to do it. GL only
    // auto-detaches from the framebuffer that is *bound at the time*, so a
    // renderer that deleted the name while some other framebuffer was current
    // would leave the target holding an attachment nobody can name and the
    // storage alive until the target itself dies.
    _device.scratchNames[0] = _depthRenderbuffer;
    gl
      ..bindFramebuffer(glFramebuffer, _depthFramebuffer)
      ..framebufferRenderbuffer(
          glFramebuffer, glDepthAttachment, glRenderbuffer, 0)
      ..deleteRenderbuffers(1, _device.scratchNames)
      ..drainErrors();
    _forgetDepth();
  }

  void _forgetDepth() {
    _depthRenderbuffer = 0;
    _depthFramebuffer = 0;
    _depthWidth = 0;
    _depthHeight = 0;
    _depthSamples = 0;
    _depthGeneration = -1;
    _depthOwner = null;
  }

  // -------------------------------------------------------------------
  // Device-loss recovery
  // -------------------------------------------------------------------

  /// Step 5's inventory for this renderer: one entry, because everything here
  /// comes back from bytes that never left Dart.
  ///
  /// After a loss and a successful recovery the program is **recreated** from
  /// the GLSL in `gl_mesh_shaders.dart`, and the vertex, index and texture
  /// caches are **dropped rather than re-uploaded**: their source is the
  /// [Mesh3D] the caller still holds, so the first frame afterwards pays the
  /// upload again - 46.5 MB of vertices for a 451,838-triangle model - and
  /// every frame after that is cached as before. [GpuResourceRecovery.rebuilt]
  /// says exactly that; `reuploaded` would promise the megabytes are back when
  /// the recovery returns, which is a promise this deliberately does not make.
  ///
  /// A recovery that *fails* leaves [pipeline] null, and [drawScene] returns
  /// [MeshRenderStats.zero] rather than drawing with a dead program name.
  @override
  Iterable<GpuRecoverableResource> recoverableResources() sync* {
    yield CallbackGpuResource.fixed(
      resourceName: 'opengl mesh pipeline '
          '(depth ${_depthWidth}x$_depthHeight, '
          '${_pipeline?.uploadedByteCount ?? 0} bytes uploaded)',
      recovery: GpuResourceRecovery.rebuilt,
      onDiscard: _discardAfterDeviceLoss,
      onRepopulate: _rebuildAfterDeviceLoss,
    );
  }

  /// Step 3: drop every GL name without calling GL.
  void _discardAfterDeviceLoss() {
    _forgetDepth();
    _pipeline?.discardAfterDeviceLoss();
    _pipeline = null;
  }

  BackendDiagnostic? _rebuildAfterDeviceLoss() {
    final GlMeshPipelineAttempt attempt =
        GlMeshPipeline.create(gl: _device.api, heap: _device.heap);
    _pipeline = attempt.pipeline;
    if (attempt.pipeline != null) return null;
    return attempt.diagnostics.isEmpty
        ? const BackendDiagnostic(
            kind: DiagnosticKind.incompatibleDevice,
            message: 'the recovered GL context refused the mesh program',
          )
        : attempt.diagnostics.first;
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('this GlMeshRenderer has been disposed');
    }
  }
}

/// The framebuffer a mesh pass draws into, and everything the depth attachment
/// has to match.
final class _GlMeshSurface {
  const _GlMeshSurface({
    required this.owner,
    required this.framebuffer,
    required this.width,
    required this.height,
    required this.samples,
    required this.generation,
  });

  /// The target itself, compared by identity. Two targets on one device can
  /// have the same size and, after one of them is destroyed, the same
  /// framebuffer name.
  final Object owner;

  final int framebuffer;
  final int width;
  final int height;
  final int samples;

  /// [RenderTarget.generation], which a resize and a device loss both bump.
  /// The only thing that distinguishes a recreated framebuffer from the one it
  /// replaced when the driver reissues the same name.
  final int generation;
}
