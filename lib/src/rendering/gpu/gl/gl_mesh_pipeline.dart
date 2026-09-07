/// Triangles on the GPU, with a depth buffer and a shader program.
///
/// `lib/src/rendering/mesh/mesh_rasterizer.dart` draws models on the CPU and
/// presents the result as one image. Its own library comment says why that was
/// the honest thing to build first and states the gap it leaves: "a GPU mesh
/// path would be a new vertex format, a depth attachment, a shader and a
/// pipeline in each of five backends". This file is that path for OpenGL, and
/// it exists because §8.1.1 of
/// `doc/ROTEIRO_FRAMEWORK_MULTIPLATAFORMA_100_PURO_DART.md` says the GPU comes
/// first and the CPU is for the three cases where it cannot: no hardware, an
/// off-screen render, or a caller who asked.
///
/// ## The contract is the CPU rasteriser's picture
///
/// Not "a reasonable 3D renderer" - *the same picture*. [MeshCamera] and
/// [MeshShading] are that rasteriser's vocabulary and are reused rather than
/// re-invented, `gl_mesh_shaders.dart` is a transcription of its `_shade`, and
/// `test/rendering/gpu/gl/gl_mesh_pipeline_test.dart` renders the same model
/// through both and subtracts. A GPU path that draws a *better* picture is a
/// failure here, because then nothing can say which of the two is right.
///
/// Four decisions carry that contract and each of them has a specific
/// wrongness attached:
///
///   1. **Depth.** `GL_DEPTH_TEST` with `GL_LESS`, because the CPU keeps a
///      fragment when `depth < _depth[index]`. GL's window-space z is an
///      affine, increasing function of the NDC z the CPU compares, so the two
///      orderings are identical. The symptom of getting this wrong - or of
///      running on a surface with **no depth bits**, which silently tests
///      against nothing - is a model whose far side draws over its near side.
///      [depthBitsOfCurrentTarget] is how a caller finds out before drawing,
///      and [render] asks it once and records the answer in
///      [depthDiagnostic], so a surface with no depth is a named complaint
///      rather than a picture nobody questions.
///   2. **Winding.** The CPU projects with `y_screen = (1 - y_ndc) * h / 2`
///      and GL's viewport transform is `y_window = (1 + y_ndc) * h / 2`, so
///      `y_screen = h - y_window` and every signed area changes sign between
///      the two. The CPU calls `area > 0` back-facing; substituting the flip
///      makes that "GL's signed area is negative", which is clockwise in
///      window coordinates, which is `GL_BACK` under `GL_CCW`. So
///      `glFrontFace(GL_CCW)` with `glCullFace(GL_BACK)` is the match, and it
///      is the *opposite* of what the CPU's sign test looks like if the flip
///      is forgotten. Getting it backwards leaves a model looking hollow,
///      which reads as a normals bug and is not one.
///   3. **Near clipping.** The CPU clips against `w > camera.near` by hand.
///      With `Matrix4.perspective`, `w = -z_view` and the near plane is
///      exactly `z_clip = -w`, which is the plane GL's own clipper uses. So
///      the hardware does what `_clipAndDraw` does and no vertex behind the
///      camera reaches the divide.
///   4. **Geometry per shading mode.** [MeshShading.flat] shades from the
///      face normal, which is not any vertex's attribute, so its vertex
///      buffer is **de-indexed**: three corners per triangle, each carrying
///      the face normal. That costs memory - 43 MB for a 451,838-triangle
///      model - and it is the only way to get the CPU's exact normal without
///      a geometry shader. [MeshShading.smooth] and [MeshShading.unlit] share
///      one indexed buffer, and [MeshShading.wireframe] shares its vertices
///      and adds a line index buffer.
///
/// ## Buffers are cached, and the cache is countable
///
/// A 451,838-triangle model re-uploaded at 60 Hz is roughly 200 MB/s of
/// traffic for geometry that never changes. So vertex and index buffers are
/// keyed on the [MeshPrimitive] object and uploaded once, with `GL_STATIC_DRAW`
/// so the driver may place them in device memory. [bufferUploadCount] and
/// [uploadedByteCount] exist because "cached" is invisible in the pixels: a
/// second frame of the same model must not increase either, and only a number
/// can say so.
///
/// ## Renderer-agnostic in shape
///
/// Nothing in [render]'s signature is an OpenGL type: it takes a [Mesh3D], a
/// [MeshCamera], a size and the same shading parameters the CPU rasteriser
/// takes, and returns the same [MeshRenderStats]. A Direct3D 11 pipeline
/// implements the identical method with the identical arguments; only
/// [create] and [dispose] name GL. That is deliberate - the two backends have
/// to be swappable behind one call site - and it is why `Mesh3D` and
/// `MeshCamera` are treated as a shared contract that neither backend changes
/// on its own.
library;

import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../../foundation/diagnostics.dart';
import '../../../geometry/rect.dart';
import '../../../graphics/mesh/mesh3d.dart';
import '../../framebuffer.dart';
import '../../mesh/mesh_rasterizer.dart';
import 'gl_bindings.dart';
import 'gl_mesh_shaders.dart';

/// The result of trying to build a [GlMeshPipeline].
///
/// The same shape `GlContextAttempt` and `Win32GlSurfaceAttempt` use, for the
/// same reason: a missing entry point or a shader the driver refused is a
/// diagnostic a caller reports and falls back from, not an exception that
/// unwinds a frame.
final class GlMeshPipelineAttempt {
  const GlMeshPipelineAttempt(this.pipeline, this.diagnostics);

  final GlMeshPipeline? pipeline;
  final List<BackendDiagnostic> diagnostics;
}

/// A GL program, a depth state and a per-mesh buffer cache.
final class GlMeshPipeline {
  GlMeshPipeline._({
    required GlApi gl,
    required NativeHeap heap,
    required int program,
    required this.desktop,
    required Map<String, int> uniforms,
  })  : _gl = gl,
        _heap = heap,
        _program = program,
        _uModelViewProjection = uniforms['uModelViewProjection']!,
        _uNormalMatrix = uniforms['uNormalMatrix']!,
        _uBaseColor = uniforms['uBaseColor']!,
        _uLightDirection = uniforms['uLightDirection']!,
        _uAmbient = uniforms['uAmbient']!,
        _uLit = uniforms['uLit']!,
        _uHasTexture = uniforms['uHasTexture']!,
        _uBaseColorTexture = uniforms['uBaseColorTexture']!;

  /// Builds the program on the context that is **already current**.
  ///
  /// [heap] may be omitted, in which case one is bound from the process. The
  /// device's heap is preferred when the caller has one: two `malloc`s from
  /// two libraries both work, but only one of them shows up in a leak report
  /// next to the rest of the renderer's allocations.
  static GlMeshPipelineAttempt create({
    required GlApi gl,
    NativeHeap? heap,
    bool? desktop,
  }) {
    final diagnostics = <BackendDiagnostic>[];
    final List<String> missing = missingMeshGlSymbols(gl.resolveProc);
    if (missing.isNotEmpty) {
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'this GL context cannot draw meshes',
        detail: 'missing entry points: ${missing.join(', ')}. All of them are '
            'core GL 2.0 or older, so a driver without them cannot run the 2D '
            'renderer either',
      ));
      return GlMeshPipelineAttempt(null, diagnostics);
    }

    final NativeHeap? bound = heap ?? NativeHeap.tryBind(null);
    if (bound == null) {
      diagnostics.add(const BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'no native allocator could be bound for the mesh pipeline',
      ));
      return GlMeshPipelineAttempt(null, diagnostics);
    }

    final bool isDesktop = desktop ?? !isEsContext(gl);
    final _Builder builder = _Builder(gl, bound);
    final Object built = builder.build(desktop: isDesktop);
    if (built is BackendDiagnostic) {
      diagnostics.add(built);
      return GlMeshPipelineAttempt(null, diagnostics);
    }
    return GlMeshPipelineAttempt(built as GlMeshPipeline, diagnostics);
  }

  /// Whether [gl]'s context reports an OpenGL ES version string.
  ///
  /// Asked of the driver rather than of the caller because [create] can be
  /// handed a bare [GlApi] - by a tool that opened its own context - and
  /// compiling the wrong GLSL dialect fails at link time with a message about
  /// a version directive, which is a long way from the mistake.
  static bool isEsContext(GlApi gl) =>
      gl.stringOf(glVersion).startsWith('OpenGL ES');

  final GlApi _gl;
  final NativeHeap _heap;
  final int _program;

  /// Which GLSL dialect was compiled. Reported so a probe can print it.
  final bool desktop;

  final int _uModelViewProjection;
  final int _uNormalMatrix;
  final int _uBaseColor;
  final int _uLightDirection;
  final int _uAmbient;
  final int _uLit;
  final int _uHasTexture;
  final int _uBaseColorTexture;

  late final Pointer<Uint32> _names = _heap.allocate<Uint32>(4 * 4);
  late final Pointer<Int32> _status = _heap.allocate<Int32>(4 * 4);
  late final Pointer<Float> _matrix = _heap.allocate<Float>(16 * 4);

  Pointer<Uint8> _staging = nullptr;
  int _stagingBytes = 0;

  final Map<MeshPrimitive, _CachedPrimitive> _primitives =
      <MeshPrimitive, _CachedPrimitive>{};
  final Map<MeshTexture, int> _textures = <MeshTexture, int>{};

  bool _disposed = false;

  /// `glBufferData` calls this pipeline has made for mesh geometry.
  ///
  /// The number the caching claim rests on. A second frame of the same model
  /// must not increase it; see the library comment.
  int get bufferUploadCount => _bufferUploadCount;
  int _bufferUploadCount = 0;

  /// Bytes handed to `glBufferData` and `glTexImage2D`, cumulative.
  int get uploadedByteCount => _uploadedByteCount;
  int _uploadedByteCount = 0;

  /// The last GL error this pipeline saw, or null.
  ///
  /// Kept rather than thrown, like `GlRenderDevice.lastError`: a driver that
  /// rejects one draw has not ended the pipeline, and a caller that wants to
  /// refuse can read this.
  BackendDiagnostic? get lastError => _lastError;
  BackendDiagnostic? _lastError;

  /// What the first [render] found when it asked the bound target for its
  /// depth bits, or null when the target had some.
  ///
  /// Separate from [lastError] because it must survive: a surface with no
  /// depth raises no GL error at all - it depth-tests against nothing and
  /// draws a model with its far side over its near side - so the only way it
  /// can be noticed is a caller reading this.
  BackendDiagnostic? get depthDiagnostic => _depthDiagnostic;
  BackendDiagnostic? _depthDiagnostic;

  /// The depth bits the first [render] observed, or -1 before it ran.
  int get observedDepthBits => _observedDepthBits;
  int _observedDepthBits = -1;
  bool _depthChecked = false;

  /// The depth comparison. **Diagnostics only.**
  ///
  /// Exists so a test can prove it is actually being enforced: a parity suite
  /// that passes with `GL_LESS` and also passes with `GL_GREATER` is not
  /// testing the depth buffer, it is testing a model with no occlusion. See
  /// the sabotage case in `gl_mesh_pipeline_test.dart`. Nothing in a frame
  /// writes it.
  int debugDepthFunc = glLess;

  /// The front-face winding. **Diagnostics only**, for the same reason as
  /// [debugDepthFunc]: flipping it to [glCw] must turn a closed model inside
  /// out, and a suite where it does not is not testing culling.
  int debugFrontFace = glCcw;

  /// The depth bits of the framebuffer currently bound for drawing.
  ///
  /// Zero means the surface has none, and drawing into it would depth-test
  /// against nothing - the far side of a model over its near side, with no
  /// error anywhere. -1 means the driver refused both queries, which is not
  /// the same as "none" and must not be treated as it.
  ///
  /// Two queries because neither works everywhere.
  /// `glGetFramebufferAttachmentParameteriv` is the modern one and is the only
  /// one that can answer for an FBO, but it is a GL 3.0 entry point that this
  /// backend does not require; `GL_DEPTH_BITS` answers for the *bound* buffer
  /// and was removed from the core profile in 3.1. The object-type query comes
  /// first for the reason `gl_stencil_cover_driver.dart` records: asking for a
  /// size on a `GL_NONE` attachment raises `GL_INVALID_OPERATION`, and a GL
  /// error is sticky.
  int depthBitsOfCurrentTarget() {
    _gl.drainErrors();
    if (_gl.resolveProc('glGetFramebufferAttachmentParameteriv') != nullptr) {
      _gl.getIntegerv(glDrawFramebufferBinding, _status);
      if (_gl.drainErrors() == glNoError) {
        // Framebuffer zero has no attachment points, so its depth buffer is
        // named GL_DEPTH; an FBO's is GL_DEPTH_ATTACHMENT. Swapping the two
        // is GL_INVALID_ENUM.
        final int attachment = _status[0] == 0 ? glDepth : glDepthAttachment;
        _gl.getFramebufferAttachmentParameteriv(
          glDrawFramebuffer,
          attachment,
          glFramebufferAttachmentObjectType,
          _status,
        );
        if (_gl.drainErrors() == glNoError) {
          if (_status[0] == glNone) return 0;
          _gl.getFramebufferAttachmentParameteriv(
            glDrawFramebuffer,
            attachment,
            glFramebufferAttachmentDepthSize,
            _status,
          );
          if (_gl.drainErrors() == glNoError) return _status[0];
        }
      }
    }
    _gl.getIntegerv(glDepthBits, _status);
    if (_gl.drainErrors() != glNoError) return -1;
    return _status[0];
  }

  /// Draws [mesh] seen from [camera] into the framebuffer bound for drawing.
  ///
  /// The arguments after [height] are the CPU rasteriser's, with the same
  /// defaults, so the same call renders the same picture through either.
  ///
  /// [width] and [height] are the **surface**, and [viewport] narrows the draw
  /// to a rectangle inside it - in surface pixels with the origin at the top
  /// left, which is the framework's convention and not GL's; the flip to GL's
  /// bottom-left origin happens here, once. Null means the whole surface, and
  /// then the projection's aspect ratio is `width / height` exactly as before.
  ///
  /// **The clear is not clipped to [viewport]**, and that is a contract rather
  /// than an oversight: `MeshSceneRenderer` has a Direct3D 11 implementation
  /// whose `ClearRenderTargetView` takes no rectangle and ignores the scissor,
  /// so a GL path that cleared only the box would draw a *different picture*
  /// from the other backend for the same [MeshScene]. See
  /// [MeshScene.backgroundArgb], which records the same rule and points a
  /// caller drawing a 3D view inside an interface at `null` - the case where
  /// clearing anything at all is wrong.
  ///
  /// The scissor test is switched off across the clear for the reason it was
  /// always switched off here - `glClear` obeys it, and a stale rectangle left
  /// by the 2D renderer would clear a corner of the frame - and switched back
  /// on around the draws only when there is a [viewport] to confine them to.
  ///
  /// [modelMatrix] defaults to the identity, which is the only case the CPU
  /// rasteriser can be compared against: it has no model matrix and shades in
  /// model space.
  ///
  /// Set [measure] to fold a `glFinish` into the returned
  /// [MeshRenderStats.microseconds]. Without it the number is *submission*
  /// time - GL is asynchronous, and a frame that has not been waited for is
  /// almost free to record. A real frame loop leaves it false and lets the
  /// swap pace the pipeline.
  MeshRenderStats render({
    required Mesh3D mesh,
    required MeshCamera camera,
    required int width,
    required int height,
    Rect? viewport,
    MeshShading shading = MeshShading.smooth,
    int backgroundArgb = 0xFF10151F,
    Vector3 lightDirection = const Vector3(-0.4, -0.8, -0.45),
    double ambient = 0.22,
    Matrix4? modelMatrix,
    bool clear = true,
    bool measure = false,
  }) {
    _throwIfDisposed();
    if (width <= 0 || height <= 0) return MeshRenderStats.zero;

    // Rounded outward and clamped to the surface before anything reads it. A
    // viewport partly outside the target is `GL_INVALID_VALUE` only for a
    // negative width, so the half that is silent - a box hanging off the right
    // edge - would simply scissor away pixels the other backend drew.
    final int boxLeft =
        viewport == null ? 0 : viewport.left.floor().clamp(0, width);
    final int boxTop =
        viewport == null ? 0 : viewport.top.floor().clamp(0, height);
    final int boxRight =
        viewport == null ? width : viewport.right.ceil().clamp(boxLeft, width);
    final int boxBottom = viewport == null
        ? height
        : viewport.bottom.ceil().clamp(boxTop, height);
    final int boxWidth = boxRight - boxLeft;
    final int boxHeight = boxBottom - boxTop;
    if (boxWidth <= 0 || boxHeight <= 0) return MeshRenderStats.zero;

    final Stopwatch watch = Stopwatch()..start();

    final Matrix4 model = modelMatrix ?? Matrix4.identity();
    final Matrix4 view = camera.viewMatrix();
    // The *box*, not the surface: a scene drawn into a narrow strip must not
    // be stretched, which is what `MeshSceneRenderer.drawScene` promises.
    final Matrix4 projection = camera.projectionMatrix(boxWidth / boxHeight);
    final Matrix4 mvp = projection.multiply(view).multiply(model);
    final Matrix4 normals = normalMatrixOf(model);
    final Vector3 light = lightDirection.normalized;

    // Drained before anything is issued, so a sticky error the 2D renderer
    // left behind is not reported as a mesh failure.
    _gl.drainErrors();
    if (!_depthChecked) {
      _depthChecked = true;
      _observedDepthBits = depthBitsOfCurrentTarget();
      _depthDiagnostic = _observedDepthBits > 0
          ? null
          : BackendDiagnostic(
              kind: DiagnosticKind.incompatibleDevice,
              message: _observedDepthBits == 0
                  ? 'the bound framebuffer has no depth buffer'
                  : 'this driver would not report the depth bits',
              detail: 'GL_DEPTH_TEST against a surface without depth silently '
                  'passes every fragment, so the model draws in submission '
                  'order and its far side covers its near side. A window '
                  'needs cDepthBits in its PIXELFORMATDESCRIPTOR; an FBO '
                  'needs a GL_DEPTH_COMPONENT renderbuffer, which '
                  'GlMeshOffscreenSurface attaches',
            );
    }

    _gl
      ..useProgram(_program)
      // GL's window origin is the bottom-left corner and the box arrived
      // top-left, so the y of the box's *bottom* edge measured from the top is
      // what becomes its bottom in GL. Subtracting `boxTop` instead puts a
      // viewport pinned to the top of the surface at the bottom of it, which
      // looks like the camera pitched rather than like a viewport bug.
      ..viewport(boxLeft, height - boxBottom, boxWidth, boxHeight)
      ..disable(glScissorTest)
      ..disable(glStencilTest)
      // Opaque, like the CPU rasteriser, which writes `argb | 0xFF000000`
      // and never blends. Leaving the 2D renderer's source-over enabled would
      // composite every triangle against the one behind it.
      ..disable(glBlend)
      ..colorMask(1, 1, 1, 1)
      ..enable(glDepthTest)
      ..depthFunc(debugDepthFunc)
      // Depth writes have to be on before the clear, not only before the
      // draws: `glClear(GL_DEPTH_BUFFER_BIT)` is masked by glDepthMask, so a
      // pipeline that cleared with writes disabled would depth-test the whole
      // frame against whatever the previous one left.
      ..depthMask(glTrueValue)
      ..frontFace(debugFrontFace);

    if (clear) {
      _gl
        ..clearColor(
          ((backgroundArgb >> 16) & 0xFF) / 255.0,
          ((backgroundArgb >> 8) & 0xFF) / 255.0,
          (backgroundArgb & 0xFF) / 255.0,
          1,
        )
        ..clear(glColorBufferBit | glDepthBufferBit);
    }

    // After the clear and never before. The depth clear in particular has to
    // reach the whole attachment: a scissored depth clear leaves the previous
    // frame's depth outside the box, and the frame after a viewport moves
    // would test against it and drop triangles with no error anywhere.
    final bool confined =
        boxLeft != 0 || boxTop != 0 || boxWidth != width || boxHeight != height;
    if (confined) {
      _gl
        ..scissor(boxLeft, height - boxBottom, boxWidth, boxHeight)
        ..enable(glScissorTest);
    }

    _setMatrix(_uModelViewProjection, mvp);
    _setMatrix(_uNormalMatrix, normals);
    _gl
      ..uniform3f(_uLightDirection, light.x, light.y, light.z)
      ..uniform1f(_uAmbient, ambient)
      ..uniform1i(_uBaseColorTexture, 0)
      ..activeTexture(glTexture0);

    final bool lit =
        shading == MeshShading.flat || shading == MeshShading.smooth;
    _gl.uniform1i(_uLit, lit ? kMeshShadeLit : kMeshShadeUnlit);

    var triangles = 0;
    var drawn = 0;
    for (final MeshPrimitive primitive in mesh.primitives) {
      triangles += primitive.triangleCount;
      final _Geometry? geometry = _geometryFor(primitive, shading);
      if (geometry == null) continue;

      // Culling exactly where the CPU culls: `cull = !material.doubleSided`,
      // and the wireframe branch there sits *after* the cull test, so a
      // wireframe of a single-sided mesh hides its back edges too.
      if (primitive.material.doubleSided) {
        _gl.disable(glCullFace);
      } else {
        _gl
          ..enable(glCullFace)
          ..cullFace(glBack);
      }

      final int color = primitive.material.colorArgb;
      _gl.uniform3f(
        _uBaseColor,
        ((color >> 16) & 0xFF) / 255.0,
        ((color >> 8) & 0xFF) / 255.0,
        (color & 0xFF) / 255.0,
      );

      final int texture =
          shading == MeshShading.wireframe ? 0 : _textureFor(primitive);
      _gl.uniform1i(_uHasTexture, texture == 0 ? 0 : 1);
      if (texture != 0) _gl.bindTexture(glTexture2D, texture);

      _gl.bindVertexArray(geometry.vao);
      if (geometry.indexCount == 0) {
        _gl.drawArrays(geometry.mode, 0, geometry.vertexCount);
      } else {
        _gl.drawElements(
          geometry.mode,
          geometry.indexCount,
          glUnsignedInt,
          nullptr,
        );
      }
      drawn += primitive.triangleCount;
    }

    _gl.bindVertexArray(0);
    // Put back what the 2D renderer assumes. It never touches GL_DEPTH_TEST
    // or GL_CULL_FACE, so a mesh frame that left them on would depth-test the
    // whole user interface against a stale depth buffer - which draws nothing
    // and reports no error.
    _gl
      ..disable(glDepthTest)
      ..disable(glCullFace)
      ..disable(glScissorTest);

    if (measure) _gl.finish();
    watch.stop();
    _checkError('mesh draw');

    return MeshRenderStats(
      triangles: triangles,
      drawn: drawn,
      // Zero means *not measured*, not none. GL culls and clips inside the
      // hardware and reports neither without an occlusion query, and the
      // pixels that survived the depth test need a second one. Reporting a
      // guess next to the CPU's exact counts would be worse than reporting
      // nothing.
      culled: 0,
      clipped: 0,
      pixels: 0,
      microseconds: watch.elapsedMicroseconds,
    );
  }

  /// Frees the GL objects cached for [mesh]. Idempotent.
  void releaseMesh(Mesh3D mesh) {
    for (final MeshPrimitive primitive in mesh.primitives) {
      final _CachedPrimitive? cached = _primitives.remove(primitive);
      if (cached == null) continue;
      _deleteCached(cached);
      final MeshTexture? texture = primitive.material.baseColorTexture;
      if (texture == null) continue;
      final int? name = _textures.remove(texture);
      if (name != null && name != 0) {
        _names[0] = name;
        _gl.deleteTextures(1, _names);
      }
    }
  }

  void dispose() {
    if (_disposed) return;
    for (final _CachedPrimitive cached in _primitives.values) {
      _deleteCached(cached);
    }
    for (final int name in _textures.values) {
      if (name == 0) continue;
      _names[0] = name;
      _gl.deleteTextures(1, _names);
    }
    _gl.deleteProgram(_program);
    _releaseWithoutDriver();
  }

  /// Step 3 of a device-loss recovery: forget every GL name, call no GL.
  ///
  /// The name and the shape are `GlFramebufferPool.discardAfterDeviceLoss`'s,
  /// and so is the argument. A GL name is an integer indexing memory the lost
  /// context already freed; `glDeleteBuffers` on one is undefined and on some
  /// drivers is a second crash on top of the first. So nothing here reaches
  /// the driver - not even `glDeleteProgram`, which is the one that looks
  /// harmless.
  ///
  /// The native heap allocations *are* released, and that is not an
  /// inconsistency: they are process memory this pipeline malloc'd, no context
  /// owns them, and a recovery that skipped them would leak the staging buffer
  /// - up to a whole model's vertices - on every GPU reset.
  ///
  /// The pipeline is unusable afterwards, exactly as if [dispose] had been
  /// called. `GlMeshRenderer` builds a fresh one rather than reviving this,
  /// because a program name is a `final` field and a half-revived object is
  /// how a renderer ends up drawing with a shader from a dead context.
  void discardAfterDeviceLoss() {
    if (_disposed) return;
    _releaseWithoutDriver();
  }

  void _releaseWithoutDriver() {
    _disposed = true;
    for (final _CachedPrimitive cached in _primitives.values) {
      cached.geometries.clear();
      cached.sharedVbo = 0;
    }
    _primitives.clear();
    _textures.clear();
    _heap
      ..release(_names)
      ..release(_status)
      ..release(_matrix);
    if (_staging != nullptr) _heap.release(_staging);
    _staging = nullptr;
    _stagingBytes = 0;
  }

  // -------------------------------------------------------------------
  // Geometry
  // -------------------------------------------------------------------

  _Geometry? _geometryFor(MeshPrimitive primitive, MeshShading shading) {
    if (primitive.triangleCount == 0 || primitive.vertexCount == 0) return null;
    final _MeshGeometryKind kind = switch (shading) {
      MeshShading.flat => _MeshGeometryKind.faceted,
      MeshShading.smooth || MeshShading.unlit => _MeshGeometryKind.indexed,
      MeshShading.wireframe => _MeshGeometryKind.lines,
    };
    final _CachedPrimitive cached =
        _primitives.putIfAbsent(primitive, _CachedPrimitive.new);
    final _Geometry? existing = cached.geometries[kind];
    if (existing != null) return existing;
    final _Geometry built = switch (kind) {
      _MeshGeometryKind.indexed => _buildIndexed(cached, primitive),
      _MeshGeometryKind.faceted => _buildFaceted(cached, primitive),
      _MeshGeometryKind.lines => _buildLines(cached, primitive),
    };
    cached.geometries[kind] = built;
    return built;
  }

  /// The shared indexed buffer: one vertex per vertex, smooth normals.
  ///
  /// The normals are the file's when it carried them and
  /// [MeshPrimitive.computeSmoothNormals] otherwise, which is exactly what
  /// `MeshRasterizer.render` chooses for [MeshShading.smooth]. Choosing
  /// differently here is the one way this pipeline could disagree with the CPU
  /// on a model that has no normals at all.
  _Geometry _buildIndexed(_CachedPrimitive cached, MeshPrimitive primitive) {
    final int count = primitive.vertexCount;
    final Float32List positions = primitive.positions;
    final Float32List normals =
        primitive.normals ?? primitive.computeSmoothNormals();
    final Float32List? uvs = primitive.uvs;
    final Float32List interleaved = Float32List(count * kMeshFloatsPerVertex);
    for (var i = 0; i < count; i++) {
      final int out = i * kMeshFloatsPerVertex;
      final int p = i * 3;
      interleaved[out] = positions[p];
      interleaved[out + 1] = positions[p + 1];
      interleaved[out + 2] = positions[p + 2];
      if (p + 2 < normals.length) {
        interleaved[out + 3] = normals[p];
        interleaved[out + 4] = normals[p + 1];
        interleaved[out + 5] = normals[p + 2];
      }
      final int t = i * 2;
      if (uvs != null && t + 1 < uvs.length) {
        interleaved[out + 6] = uvs[t];
        interleaved[out + 7] = uvs[t + 1];
      }
    }
    cached.sharedVbo = _createArrayBuffer(interleaved);
    // Indices copied rather than handed over: the model's Uint32List is the
    // loader's and may be a view into a glTF buffer that the caller still
    // owns, and `asTypedList(...).setRange` needs a source it can read from
    // start to finish.
    final int ebo = _createIndexBuffer(primitive.indices);
    return _Geometry(
      vao: _createVertexArray(cached.sharedVbo, ebo),
      vbo: cached.sharedVbo,
      ownsVertexBuffer: true,
      ebo: ebo,
      indexCount: primitive.indices.length,
      vertexCount: count,
      mode: glTriangles,
    );
  }

  /// The de-indexed buffer for [MeshShading.flat]: three corners per triangle,
  /// each carrying the triangle's own plane normal.
  ///
  /// `(b - a) x (c - a)`, normalised - the same cross product
  /// `MeshRasterizer._drawProjected` computes on demand. Reversing the
  /// operands would negate every face normal and light every model from
  /// behind, which looks like the light direction is wrong.
  _Geometry _buildFaceted(_CachedPrimitive cached, MeshPrimitive primitive) {
    final Uint32List indices = primitive.indices;
    final Float32List positions = primitive.positions;
    final Float32List? uvs = primitive.uvs;
    final int vertexCount = primitive.vertexCount;
    final int corners = (indices.length ~/ 3) * 3;
    final Float32List interleaved = Float32List(corners * kMeshFloatsPerVertex);
    var out = 0;
    for (var t = 0; t + 2 < indices.length; t += 3) {
      final int ia = indices[t];
      final int ib = indices[t + 1];
      final int ic = indices[t + 2];
      if (ia >= vertexCount || ib >= vertexCount || ic >= vertexCount) {
        out += 3 * kMeshFloatsPerVertex;
        continue;
      }
      final double ax = positions[ia * 3];
      final double ay = positions[ia * 3 + 1];
      final double az = positions[ia * 3 + 2];
      final double e0x = positions[ib * 3] - ax;
      final double e0y = positions[ib * 3 + 1] - ay;
      final double e0z = positions[ib * 3 + 2] - az;
      final double e1x = positions[ic * 3] - ax;
      final double e1y = positions[ic * 3 + 1] - ay;
      final double e1z = positions[ic * 3 + 2] - az;
      var nx = e0y * e1z - e0z * e1y;
      var ny = e0z * e1x - e0x * e1z;
      var nz = e0x * e1y - e0y * e1x;
      final double length = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (length != 0) {
        nx /= length;
        ny /= length;
        nz /= length;
      }
      for (final int index in <int>[ia, ib, ic]) {
        interleaved[out] = positions[index * 3];
        interleaved[out + 1] = positions[index * 3 + 1];
        interleaved[out + 2] = positions[index * 3 + 2];
        interleaved[out + 3] = nx;
        interleaved[out + 4] = ny;
        interleaved[out + 5] = nz;
        if (uvs != null && index * 2 + 1 < uvs.length) {
          interleaved[out + 6] = uvs[index * 2];
          interleaved[out + 7] = uvs[index * 2 + 1];
        }
        out += kMeshFloatsPerVertex;
      }
    }
    final int vbo = _createArrayBuffer(interleaved);
    return _Geometry(
      vao: _createVertexArray(vbo, 0),
      vbo: vbo,
      ownsVertexBuffer: true,
      ebo: 0,
      indexCount: 0,
      vertexCount: corners,
      mode: glTriangles,
    );
  }

  /// The line index buffer, over the shared indexed vertices.
  ///
  /// Three edges per triangle and no deduplication, so a shared edge is drawn
  /// twice. That matches what the CPU does - it draws all three edges of every
  /// triangle it accepts - and the pixels are identical either way because the
  /// lines are opaque.
  _Geometry _buildLines(_CachedPrimitive cached, MeshPrimitive primitive) {
    if (cached.sharedVbo == 0) {
      // The line buffer borrows the indexed geometry's vertices, so build
      // that first rather than duplicating them.
      _geometryFor(primitive, MeshShading.smooth);
    }
    final Uint32List indices = primitive.indices;
    final int triangleCount = indices.length ~/ 3;
    final Uint32List lines = Uint32List(triangleCount * 6);
    for (var t = 0; t < triangleCount; t++) {
      final int a = indices[t * 3];
      final int b = indices[t * 3 + 1];
      final int c = indices[t * 3 + 2];
      final int out = t * 6;
      lines[out] = a;
      lines[out + 1] = b;
      lines[out + 2] = b;
      lines[out + 3] = c;
      lines[out + 4] = c;
      lines[out + 5] = a;
    }
    final int ebo = _createIndexBuffer(lines);
    return _Geometry(
      vao: _createVertexArray(cached.sharedVbo, ebo),
      vbo: cached.sharedVbo,
      // The vertices belong to the indexed geometry, which deletes them.
      ownsVertexBuffer: false,
      ebo: ebo,
      indexCount: lines.length,
      vertexCount: primitive.vertexCount,
      mode: glLines,
    );
  }

  int _createArrayBuffer(Float32List data) {
    _gl.genBuffers(1, _names);
    final int buffer = _names[0];
    final int bytes = data.lengthInBytes;
    final Pointer<Uint8> staging = _ensureStaging(bytes);
    staging.cast<Float>().asTypedList(data.length).setAll(0, data);
    _gl
      ..bindBuffer(glArrayBuffer, buffer)
      ..bufferData(glArrayBuffer, bytes, staging.cast<Void>(), glStaticDraw);
    _bufferUploadCount++;
    _uploadedByteCount += bytes;
    _checkError('glBufferData(mesh vertices)');
    return buffer;
  }

  int _createIndexBuffer(Uint32List data) {
    // Vertex array zero first, and this is not tidiness. The element array
    // binding is *part of a vertex array object's state*, so binding a new
    // index buffer while some other primitive's array object is still current
    // silently rewrites that primitive's indices. The symptom was the first
    // frame being right and every frame after it drawing one model's triangles
    // through the next model's index buffer - shapes that vanish or shear,
    // with no GL error anywhere.
    _gl.bindVertexArray(0);
    _gl.genBuffers(1, _names);
    final int buffer = _names[0];
    final int bytes = data.lengthInBytes;
    final Pointer<Uint8> staging = _ensureStaging(bytes);
    staging.cast<Uint32>().asTypedList(data.length).setAll(0, data);
    _gl
      ..bindBuffer(glElementArrayBuffer, buffer)
      ..bufferData(
          glElementArrayBuffer, bytes, staging.cast<Void>(), glStaticDraw);
    _bufferUploadCount++;
    _uploadedByteCount += bytes;
    _checkError('glBufferData(mesh indices)');
    return buffer;
  }

  int _createVertexArray(int vbo, int ebo) {
    _gl.genVertexArrays(1, _names);
    final int vao = _names[0];
    const int stride = kMeshFloatsPerVertex * 4;
    _gl
      ..bindVertexArray(vao)
      ..bindBuffer(glArrayBuffer, vbo);
    // The element buffer binding is part of the vertex array's state, which is
    // why every index buffer needs its own array object rather than a rebind
    // before the draw: rebinding would silently edit whichever array is
    // current.
    if (ebo != 0) _gl.bindBuffer(glElementArrayBuffer, ebo);
    _attribute(kMeshAttributePosition, 3, kMeshPositionOffset * 4, stride);
    _attribute(kMeshAttributeNormal, 3, kMeshNormalOffset * 4, stride);
    _attribute(kMeshAttributeTexCoord, 2, kMeshTexCoordOffset * 4, stride);
    _gl.bindVertexArray(0);
    _checkError('mesh vertex array');
    return vao;
  }

  void _attribute(int index, int size, int offset, int stride) {
    _gl
      ..enableVertexAttribArray(index)
      ..vertexAttribPointer(index, size, glFloat, glFalseValue, stride,
          Pointer<Void>.fromAddress(offset));
  }

  void _deleteCached(_CachedPrimitive cached) {
    for (final _Geometry geometry in cached.geometries.values) {
      _names[0] = geometry.vao;
      _gl.deleteVertexArrays(1, _names);
      if (geometry.ebo != 0) {
        _names[0] = geometry.ebo;
        _gl.deleteBuffers(1, _names);
      }
      if (geometry.ownsVertexBuffer && geometry.vbo != 0) {
        _names[0] = geometry.vbo;
        _gl.deleteBuffers(1, _names);
      }
    }
    cached.geometries.clear();
    cached.sharedVbo = 0;
  }

  // -------------------------------------------------------------------
  // Textures
  // -------------------------------------------------------------------

  /// The GL name of [primitive]'s base-colour map, or 0 for no texture.
  ///
  /// Refuses the map when the primitive has no texture coordinates, or fewer
  /// than one per vertex, because that is what the CPU does: `uvs` is only
  /// read when a texture exists, and a vertex past the end of the array gets
  /// NaN coordinates and skips the sample. Sampling a partial array with
  /// zeroes instead would tint half the model with the texture's first texel.
  int _textureFor(MeshPrimitive primitive) {
    final MeshTexture? texture = primitive.material.baseColorTexture;
    if (texture == null) return 0;
    final Float32List? uvs = primitive.uvs;
    if (uvs == null || uvs.length < primitive.vertexCount * 2) return 0;
    final int? existing = _textures[texture];
    if (existing != null) return existing;

    _gl.genTextures(1, _names);
    final int name = _names[0];
    final int pixelCount = texture.width * texture.height;
    final int bytes = pixelCount * 4;
    final Pointer<Uint8> staging = _ensureStaging(bytes);
    final Uint8List view = staging.asTypedList(bytes);
    // `0xAARRGGBB` unpacked to RGBA bytes rather than uploaded as GL_BGRA.
    // GL_BGRA is a desktop-only upload format and this pipeline compiles for
    // ES too; one pass per texture at load time is not worth a dialect split.
    for (var i = 0; i < pixelCount; i++) {
      final int argb = texture.pixels[i];
      final int at = i * 4;
      view[at] = (argb >> 16) & 0xFF;
      view[at + 1] = (argb >> 8) & 0xFF;
      view[at + 2] = argb & 0xFF;
      view[at + 3] = (argb >> 24) & 0xFF;
    }
    _gl
      ..bindTexture(glTexture2D, name)
      ..pixelStorei(glUnpackAlignment, 1)
      ..texImage2D(glTexture2D, 0, glRgba8, texture.width, texture.height, 0,
          glRgba, glUnsignedByte, staging.cast<Void>())
      // GL_REPEAT, because that is what `MeshTexture.sample`'s `% width` does
      // and what glTF and OBJ both default to. A model that tiles a floor
      // carries u well outside the unit square.
      ..texParameteri(glTexture2D, glTextureWrapS, glRepeat)
      ..texParameteri(glTexture2D, glTextureWrapT, glRepeat)
      // Nearest, and not because filtering is expensive here: the CPU
      // sampler is nearest-neighbour by an explicit decision recorded on
      // `MeshTexture.sample`, and a bilinear GPU sampler would disagree with
      // it on every texel boundary. It also removes the mipmap question - a
      // GL_NEAREST minification filter never consults a level that does not
      // exist, where GL_NEAREST_MIPMAP_LINEAR (the default) would leave the
      // texture incomplete and sample black.
      ..texParameteri(glTexture2D, glTextureMinFilter, glNearest)
      ..texParameteri(glTexture2D, glTextureMagFilter, glNearest);
    _uploadedByteCount += bytes;
    _checkError('glTexImage2D(mesh base colour)');
    _textures[texture] = name;
    return name;
  }

  // -------------------------------------------------------------------
  // Plumbing
  // -------------------------------------------------------------------

  void _setMatrix(int location, Matrix4 value) {
    final Float64List storage = value.storage;
    final Float32List slot = _matrix.asTypedList(16);
    for (var i = 0; i < 16; i++) {
      slot[i] = storage[i];
    }
    // transpose = false and column-major floats: `Matrix4` documents that
    // layout and glUniformMatrix4fv wants exactly it. Passing true instead
    // transposes every model once, which looks like a broken camera.
    _gl.uniformMatrix4fv(location, 1, glFalseValue, _matrix);
  }

  Pointer<Uint8> _ensureStaging(int bytes) {
    if (bytes <= _stagingBytes) return _staging;
    if (_staging != nullptr) _heap.release(_staging);
    _stagingBytes = bytes;
    return _staging = _heap.allocate<Uint8>(bytes);
  }

  bool _checkError(String what) {
    final int error = _gl.drainErrors();
    if (error == glNoError) {
      _lastError = null;
      return false;
    }
    _lastError = BackendDiagnostic(
      kind: error == glContextLost
          ? DiagnosticKind.connectionFailed
          : DiagnosticKind.incompatibleDevice,
      message: 'GL error during $what',
      detail: '0x${error.toRadixString(16)}',
    );
    return true;
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('this GlMeshPipeline has been disposed');
    }
  }
}

/// The upper 3x3 inverse transpose of [model], as a [Matrix4].
///
/// A normal is not transformed by the model matrix. Under a non-uniform scale
/// the surface tilts one way and the naive normal tilts the other, so a
/// squashed sphere lights as if the light had moved. The inverse transpose is
/// the matrix that does not have that error.
///
/// A singular matrix - a scale with a zero axis, which exporters do produce -
/// returns the identity rather than a matrix of infinities, for the reason
/// `Vector3.normalized` returns zero rather than NaN: a NaN normal propagates
/// into everything that shares the vertex.
Matrix4 normalMatrixOf(Matrix4 model) {
  final Float64List m = model.storage;
  final double a00 = m[0];
  final double a01 = m[4];
  final double a02 = m[8];
  final double a10 = m[1];
  final double a11 = m[5];
  final double a12 = m[9];
  final double a20 = m[2];
  final double a21 = m[6];
  final double a22 = m[10];

  final double c00 = a11 * a22 - a12 * a21;
  final double c01 = -(a10 * a22 - a12 * a20);
  final double c02 = a10 * a21 - a11 * a20;
  final double determinant = a00 * c00 + a01 * c01 + a02 * c02;
  if (determinant == 0) return Matrix4.identity();

  final double c10 = -(a01 * a22 - a02 * a21);
  final double c11 = a00 * a22 - a02 * a20;
  final double c12 = -(a00 * a21 - a01 * a20);
  final double c20 = a01 * a12 - a02 * a11;
  final double c21 = -(a00 * a12 - a02 * a10);
  final double c22 = a00 * a11 - a01 * a10;
  final double inverse = 1 / determinant;

  // The cofactor matrix over the determinant *is* the inverse transpose:
  // inverse = adjugate / det and adjugate is the transposed cofactor matrix,
  // so transposing again cancels. Written out so nobody has to re-derive
  // whether one transpose was dropped.
  //
  // `Matrix4` is **column-major**, so each line below is a column and not a
  // row: element (r, c) lives at `c * 4 + r`. Writing the cofactors out in
  // reading order instead produces the plain inverse - correct-looking,
  // identical on any diagonal matrix, and wrong the moment a model is
  // rotated. `gl_mesh_pipeline_test.dart` catches exactly that by asserting a
  // rotation is its own inverse transpose.
  return Matrix4(Float64List.fromList(<double>[
    c00 * inverse, c10 * inverse, c20 * inverse, 0, //
    c01 * inverse, c11 * inverse, c21 * inverse, 0, //
    c02 * inverse, c12 * inverse, c22 * inverse, 0, //
    0, 0, 0, 1, //
  ]));
}

enum _MeshGeometryKind { indexed, faceted, lines }

final class _CachedPrimitive {
  /// The indexed vertex buffer, shared with the wireframe geometry. Zero until
  /// [_MeshGeometryKind.indexed] has been built.
  int sharedVbo = 0;

  final Map<_MeshGeometryKind, _Geometry> geometries =
      <_MeshGeometryKind, _Geometry>{};
}

final class _Geometry {
  const _Geometry({
    required this.vao,
    required this.vbo,
    required this.ownsVertexBuffer,
    required this.ebo,
    required this.indexCount,
    required this.vertexCount,
    required this.mode,
  });

  final int vao;
  final int vbo;

  /// Whether deleting this geometry deletes [vbo]. False for the wireframe
  /// geometry, which borrows the indexed geometry's vertices; deleting them
  /// twice is a name the driver has already freed being freed again.
  final bool ownsVertexBuffer;

  final int ebo;

  /// Zero for a de-indexed geometry, which draws with `glDrawArrays`.
  final int indexCount;

  final int vertexCount;
  final int mode;
}

/// Compiles and links the mesh program.
final class _Builder {
  _Builder(this._gl, this._heap);

  final GlApi _gl;
  final NativeHeap _heap;
  static const int _logCapacity = 4096;

  Object build({required bool desktop}) {
    final Pointer<Int32> status = _heap.allocateInt32(1);
    final Pointer<Uint8> log = _heap.allocate<Uint8>(_logCapacity);
    final Pointer<Pointer<Uint8>> slot = _heap.allocatePointers<Uint8>(1);
    try {
      final Object vertex = _compile(
        glVertexShader,
        meshVertexShaderSource(desktop: desktop),
        status,
        log,
        slot,
      );
      if (vertex is BackendDiagnostic) return vertex;
      final Object fragment = _compile(
        glFragmentShader,
        meshFragmentShaderSource(desktop: desktop),
        status,
        log,
        slot,
      );
      if (fragment is BackendDiagnostic) {
        _gl.deleteShader(vertex as int);
        return fragment;
      }

      final int program = _gl.createProgram();
      _gl
        ..attachShader(program, vertex as int)
        ..attachShader(program, fragment as int);
      for (var i = 0; i < kMeshAttributeNames.length; i++) {
        final Pointer<Uint8> name = _heap.allocateUtf8(kMeshAttributeNames[i]);
        _gl.bindAttribLocation(program, i, name);
        _heap.release(name);
      }
      _gl
        ..linkProgram(program)
        ..getProgramiv(program, glLinkStatus, status);
      _gl
        ..deleteShader(vertex)
        ..deleteShader(fragment);
      if (status[0] == glFalseValue) {
        _gl.getProgramInfoLog(program, _logCapacity, nullptr, log);
        final String detail = readNativeUtf8(log, limit: _logCapacity);
        _gl.deleteProgram(program);
        return BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'the mesh shader program failed to link',
          detail: detail,
        );
      }

      const List<String> names = <String>[
        'uModelViewProjection',
        'uNormalMatrix',
        'uBaseColor',
        'uLightDirection',
        'uAmbient',
        'uLit',
        'uHasTexture',
        'uBaseColorTexture',
      ];
      final uniforms = <String, int>{};
      final absent = <String>[];
      for (final String name in names) {
        final Pointer<Uint8> native = _heap.allocateUtf8(name);
        final int location = _gl.getUniformLocation(program, native);
        _heap.release(native);
        uniforms[name] = location;
        if (location < 0) absent.add(name);
      }
      if (absent.isNotEmpty) {
        _gl.deleteProgram(program);
        return BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'the linked mesh program is missing a uniform',
          detail: '${absent.join(', ')} was optimised away, which means '
              'gl_mesh_shaders.dart and this file have drifted apart. Setting '
              'a uniform at location -1 is silently ignored, so the failure '
              'would be a wrongly lit model rather than an error',
        );
      }

      return GlMeshPipeline._(
        gl: _gl,
        heap: _heap,
        program: program,
        desktop: desktop,
        uniforms: uniforms,
      );
    } finally {
      _heap
        ..release(status)
        ..release(log)
        ..release(slot);
    }
  }

  Object _compile(
    int type,
    String source,
    Pointer<Int32> status,
    Pointer<Uint8> log,
    Pointer<Pointer<Uint8>> slot,
  ) {
    final int shader = _gl.createShader(type);
    final Pointer<Uint8> native = _heap.allocateUtf8(source);
    slot[0] = native;
    _gl
      ..shaderSource(shader, 1, slot, nullptr)
      ..compileShader(shader)
      ..getShaderiv(shader, glCompileStatus, status);
    _heap.release(native);
    if (status[0] != glFalseValue) return shader;
    _gl
      ..getShaderInfoLog(shader, _logCapacity, nullptr, log)
      ..deleteShader(shader);
    return BackendDiagnostic(
      kind: DiagnosticKind.incompatibleDevice,
      message: type == glVertexShader
          ? 'the mesh vertex shader failed to compile'
          : 'the mesh fragment shader failed to compile',
      detail: readNativeUtf8(log, limit: _logCapacity),
    );
  }
}

/// An off-screen colour-plus-depth target for the mesh pipeline.
///
/// `GlFramebufferPool` allocates colour and stencil and no depth, which is
/// correct for the 2D renderer and useless here: a mesh drawn into one of its
/// framebuffers would depth-test against nothing. Rather than widen a pool
/// every 2D layer allocates out of, this owns the two attachments a mesh
/// render needs and nothing else.
///
/// It reads its pixels back, which is what makes a parity comparison against
/// the CPU rasteriser possible at all. §23 of the roadmap forbids a readback
/// per frame for a *presenting* backend; this is not one.
final class GlMeshOffscreenSurface {
  GlMeshOffscreenSurface._(
    this._gl,
    this._heap,
    this.width,
    this.height,
    this._framebuffer,
    this._color,
    this._depth,
  );

  /// Creates the target, or returns why the driver refused it.
  static Object create({
    required GlApi api,
    required NativeHeap heap,
    required int width,
    required int height,
  }) {
    final Pointer<Uint32> names = heap.allocate<Uint32>(4);
    try {
      // Written as separate statements rather than a cascade on purpose. The
      // analyzer resolves `target..member(...)` against the *enclosing class*
      // when the member is a function-typed field and the method is static,
      // and every entry point on GlApi is a function-typed field, so a
      // cascade here is `instance_member_access_from_static` on every line.
      api.drainErrors();
      api.genTextures(1, names);
      final int color = names[0];
      api.bindTexture(glTexture2D, color);
      api.texImage2D(glTexture2D, 0, glRgba8, width, height, 0, glRgba,
          glUnsignedByte, nullptr);
      api.texParameteri(glTexture2D, glTextureMinFilter, glNearest);
      api.texParameteri(glTexture2D, glTextureMagFilter, glNearest);
      api.texParameteri(glTexture2D, glTextureWrapS, glClampToEdge);
      api.texParameteri(glTexture2D, glTextureWrapT, glClampToEdge);

      api.genRenderbuffers(1, names);
      final int depth = names[0];
      api.bindRenderbuffer(glRenderbuffer, depth);
      // 24 bits, matching the pixel format `win32_gl_surface.dart` asks a
      // window for. A comparison between a window frame and an off-screen one
      // is only meaningful when both resolve depth at the same precision.
      api.renderbufferStorage(
          glRenderbuffer, glDepthComponent24, width, height);
      api.bindRenderbuffer(glRenderbuffer, 0);

      api.genFramebuffers(1, names);
      final int framebuffer = names[0];
      api.bindFramebuffer(glFramebuffer, framebuffer);
      api.framebufferTexture2D(
          glFramebuffer, glColorAttachment0, glTexture2D, color, 0);
      api.framebufferRenderbuffer(
          glFramebuffer, glDepthAttachment, glRenderbuffer, depth);
      final int status = api.checkFramebufferStatus(glFramebuffer);
      if (status != glFramebufferComplete) {
        return BackendDiagnostic(
          kind: DiagnosticKind.surfaceCreationFailed,
          message: 'the off-screen mesh framebuffer is incomplete',
          detail: '0x${status.toRadixString(16)} for ${width}x$height with a '
              'GL_DEPTH_COMPONENT24 renderbuffer',
        );
      }
      final int error = api.drainErrors();
      if (error != glNoError) {
        return BackendDiagnostic(
          kind: DiagnosticKind.surfaceCreationFailed,
          message: 'GL rejected the off-screen mesh framebuffer',
          detail: '0x${error.toRadixString(16)}',
        );
      }
      return GlMeshOffscreenSurface._(
          api, heap, width, height, framebuffer, color, depth);
    } finally {
      heap.release(names);
    }
  }

  final GlApi _gl;
  final NativeHeap _heap;
  final int width;
  final int height;
  final int _framebuffer;
  final int _color;
  final int _depth;

  Pointer<Uint8> _staging = nullptr;

  /// Makes this the framebuffer draws land in.
  void bind() => _gl.bindFramebuffer(glFramebuffer, _framebuffer);

  /// Copies the colour attachment into [destination], flipping rows.
  ///
  /// GL hands rows back bottom-up because its framebuffer origin is at the
  /// bottom left and [Framebuffer] is top-down - the same flip
  /// `GlRenderDevice._readPixels` performs, repeated here rather than shared
  /// because that one is private to the device on purpose.
  bool readInto(Framebuffer destination) {
    if (destination.width != width || destination.height != height) {
      throw ArgumentError('the destination is ${destination.width}x'
          '${destination.height}, not ${width}x$height');
    }
    final int bytes = width * height * 4;
    _staging = _staging == nullptr ? _heap.allocate<Uint8>(bytes) : _staging;
    _gl
      ..bindFramebuffer(glFramebuffer, _framebuffer)
      ..pixelStorei(glPackAlignment, 1)
      ..readPixels(
          0, 0, width, height, glRgba, glUnsignedByte, _staging.cast<Void>());
    if (_gl.drainErrors() != glNoError) return false;

    final Uint8List source = _staging.asTypedList(bytes);
    final bool swizzle =
        destination.format == PixelFormat.bgra8888Premultiplied;
    for (var y = 0; y < height; y++) {
      final int sourceRow = (height - 1 - y) * width * 4;
      final int destinationRow = y * destination.bytesPerRow;
      if (!swizzle) {
        destination.pixels.setRange(
            destinationRow, destinationRow + width * 4, source, sourceRow);
        continue;
      }
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

  void dispose() {
    final Pointer<Uint32> names = _heap.allocate<Uint32>(4);
    names[0] = _framebuffer;
    _gl.deleteFramebuffers(1, names);
    names[0] = _color;
    _gl.deleteTextures(1, names);
    names[0] = _depth;
    _gl.deleteRenderbuffers(1, names);
    _heap.release(names);
    if (_staging != nullptr) _heap.release(_staging);
    _staging = nullptr;
  }
}
