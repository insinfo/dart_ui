/// The OpenGL backend: the first concrete filling of the GPU abstraction.
///
/// OpenGL rather than Vulkan, Metal or D3D for one reason that outranks every
/// technical comparison: `poc/poc_06_opengl` already proves the FFI binding
/// loads and answers on Linux under software Mesa in this repository's CI. A
/// backend that can be *run* in CI is worth more than a faster one that can
/// only be reasoned about, because the whole point of this stage is to find
/// out whether the abstraction above it is right.
///
/// ## The target is offscreen on purpose
///
/// [GlOffscreenTarget] renders into a framebuffer object, not a window. That
/// makes the entire GPU path testable with no display server, no compositor
/// and no window manager - the same property that makes the CPU renderer
/// testable - and it is the configuration a golden test needs. A windowed
/// target is a different class with the same interface: it swaps a
/// window-system surface in for the FBO and does not read pixels back. Its
/// absence here is a scope decision, not an oversight; windows belong to
/// `lib/src/backends/*`.
///
/// ## Readback
///
/// This target reads its pixels back on present, which section 25 of the
/// roadmap forbids for a *production* GPU backend ("backend GPU não deve
/// fazer readback por frame"). That rule is about presenting to a screen. An
/// offscreen target whose only consumer is a test or an image export has
/// nowhere else to put the pixels, and the rule does not apply to it. A
/// windowed target must not inherit this method.
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
import '../../framebuffer.dart';
import '../../renderer.dart';
import '../../replay/display_list_player.dart';
import '../gpu_batcher.dart';
import '../gpu_device_state.dart';
import '../gpu_mask_atlas.dart';
import '../gpu_pipeline.dart';
import '../gpu_raster_sink.dart';
import '../gpu_texture.dart';
import 'gl_bindings.dart';
import 'gl_context.dart';
import 'gl_shaders.dart';

/// A texture object owned by a [GlRenderDevice].
final class GlTexture implements GpuTextureHandle {
  GlTexture._(
    this.id,
    this.width,
    this.height,
    this.format,
    this.filter,
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

  final GpuDeviceState _state;
  bool _released = false;

  /// A texture is invalid the moment its device is lost: the name is still an
  /// integer but the driver freed what it pointed at, and binding it is
  /// undefined rather than an error.
  @override
  bool get isValid => !_released && !_state.isLost;

  @override
  String toString() =>
      'GlTexture($id, ${width}x$height, ${format.name}, ${filter.name})';
}

/// An open GL context plus the objects every target shares.
final class GlRenderDevice
    with DisposableMixin
    implements RenderDevice, GpuTextureAllocator {
  GlRenderDevice._({
    required GlContext context,
    required GlApi gl,
    required NativeHeap heap,
    required RendererInfo info,
    required int maxTextureSize,
  })  : _context = context,
        _gl = gl,
        _heap = heap,
        _info = info,
        _maxTextureSize = maxTextureSize;

  final GlContext _context;
  final GlApi _gl;
  final NativeHeap _heap;
  final RendererInfo _info;
  final int _maxTextureSize;
  final GpuDeviceState _state = GpuDeviceState();

  // Scratch native memory, allocated once. Every GL call that returns a name
  // or a status writes through one of these, so a frame performs no native
  // allocation at all.
  late final Pointer<Uint32> _names = _heap.allocate<Uint32>(4 * 4);
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

  GpuDeviceState get state => _state;

  GlApi get api => _gl;

  @override
  RendererInfo get info => _info;

  @override
  bool get isLost => _state.isLost;

  @override
  RendererCapabilities get capabilities => RendererCapabilities(
        // Honest answers. Partial present is false because an FBO target
        // redraws whole; MSAA is false because nothing here asks for a
        // multisample renderbuffer, and the antialiasing is analytic instead
        // (see gpu_mask_atlas.dart); compute is false because the subset in
        // gl_bindings.dart deliberately stops before compute shaders.
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

  @override
  RenderTarget createTarget(NativeSurfaceDescriptor surface) {
    throwIfDisposed();
    if (surface is! MemorySurfaceDescriptor) {
      throw UnsupportedCapabilityError(
        backendName: 'opengl',
        capability: Capability.cpuPresentation,
        detail: 'this device creates offscreen framebuffer targets from '
            'memory surface descriptors, not ${surface.kind}; a windowed '
            'target needs a window-system surface, which lives in '
            'lib/src/backends',
      );
    }
    return GlOffscreenTarget._(this, surface);
  }

  // -------------------------------------------------------------------
  // Textures
  // -------------------------------------------------------------------

  /// Creates an empty texture, or throws when the device cannot hold one.
  ///
  /// The size check is against the limit the device already queried, and it
  /// throws rather than letting GL answer. Without it an oversized texture
  /// raises `GL_INVALID_VALUE`, which [_checkError] would have to interpret -
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
        capability: Capability.cpuPresentation,
        detail: 'a ${width}x$height texture exceeds this device\'s '
            'GL_MAX_TEXTURE_SIZE of $_maxTextureSize; the caller must tile '
            'the image or scale it down',
      );
    }
    _makeCurrentOrLose();
    _gl.genTextures(1, _names);
    final name = _names[0];
    final sampling =
        filter == GpuTextureFilter.linear ? glLinear : glNearest;
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
    _checkError('glTexImage2D(${width}x$height, ${format.name})');
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
    _makeCurrentOrLose();
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
    _checkError('glTexSubImage2D');
  }

  @override
  void releaseTexture(covariant GlTexture texture) {
    if (texture._released || _state.isLost || isDisposed) return;
    texture._released = true;
    _names[0] = texture.id;
    _gl.deleteTextures(1, _names);
  }

  // -------------------------------------------------------------------
  // Frame submission
  // -------------------------------------------------------------------

  /// Issues one batch list into the currently bound framebuffer.
  ///
  /// Returns false when the device was lost on the way, which the caller
  /// turns into [PresentStatus.deviceLost].
  bool _submit(
    GpuBatcher batcher,
    int surfaceWidth,
    int surfaceHeight,
    int? clearColor,
  ) {
    if (!_makeCurrentOrLose()) return false;

    _gl
      ..viewport(0, 0, surfaceWidth, surfaceHeight)
      ..disable(glDepthTest)
      ..disable(glCullFace)
      ..enable(glBlend)
      ..disable(glScissorTest);

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

    if (batcher.batchCount == 0) return !_state.isLost;

    _uploadGeometry(batcher);

    _gl
      ..useProgram(_program)
      ..uniform2f(
          _uniformViewport, surfaceWidth.toDouble(), surfaceHeight.toDouble())
      ..uniform1i(_uniformTexture, 0)
      ..activeTexture(glTexture0)
      ..bindVertexArray(_vao)
      ..enable(glScissorTest);

    var boundTexture = -1;
    var boundMode = -1;
    var boundBlend = -1;
    for (var i = 0; i < batcher.batchCount; i++) {
      final batch = batcher.batchAt(i);
      var left = batch.scissorLeft;
      var top = batch.scissorTop;
      var right = batch.scissorRight;
      var bottom = batch.scissorBottom;
      if (left < 0) left = 0;
      if (top < 0) top = 0;
      if (right > surfaceWidth) right = surfaceWidth;
      if (bottom > surfaceHeight) bottom = surfaceHeight;
      if (right <= left || bottom <= top) continue;

      // GL's scissor origin is the bottom-left corner, device space's is the
      // top-left. Same flip the vertex shader applies to positions.
      _gl.scissor(left, surfaceHeight - bottom, right - left, bottom - top);

      if (batch.blendMode != boundBlend) {
        boundBlend = batch.blendMode;
        final blend = gpuBlendForMode(batch.blendMode);
        _gl.blendFunc(_glFactor(blend.source), _glFactor(blend.destination));
      }
      final mode = switch (batch.pipeline) {
        GpuPipelineKind.solid => kModeSolid,
        GpuPipelineKind.coverageMask => kModeCoverageMask,
        GpuPipelineKind.texturedImage => kModeTexturedImage,
      };
      if (mode != boundMode) {
        boundMode = mode;
        _gl.uniform1i(_uniformMode, mode);
      }
      if (batch.textureId != boundTexture) {
        boundTexture = batch.textureId;
        _gl.bindTexture(glTexture2D, batch.textureId);
      }
      _gl.drawElements(
        glTriangles,
        batch.indexCount,
        glUnsignedInt,
        Pointer<Void>.fromAddress(batch.indexOffset * 4),
      );
    }

    _gl.disable(glScissorTest);
    _checkError('draw');
    return !_state.isLost;
  }

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
    _checkError('glBufferData');
  }

  /// Reads the bound framebuffer into [destination], flipping rows.
  ///
  /// GL hands back rows bottom-up because its framebuffer origin is at the
  /// bottom left; [Framebuffer] is top-down. The flip is here rather than in
  /// the shader because flipping the projection instead would put the whole
  /// renderer in a coordinate system that disagrees with every rectangle the
  /// layout produced.
  bool _readPixels(Framebuffer destination) {
    if (!_makeCurrentOrLose()) return false;
    final width = destination.width;
    final height = destination.height;
    final bytes = width * height * 4;
    final staging = _ensurePixelStaging(bytes);
    _gl
      ..pixelStorei(glPackAlignment, 1)
      ..readPixels(
          0, 0, width, height, glRgba, glUnsignedByte, staging.cast<Void>());
    if (_checkError('glReadPixels')) return false;

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
    if (!_makeCurrentOrLose()) {
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
    if (_uniformViewport < 0 || _uniformMode < 0) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the linked program is missing a uniform the renderer needs',
        detail: 'uViewport or uMode was optimised away, which means the '
            'shader source and this file have drifted apart',
      );
    }

    _gl
      ..genVertexArrays(1, _names)
      ..bindVertexArray(_names[0]);
    _vao = _names[0];
    _gl.genBuffers(1, _names);
    _vbo = _names[0];
    _gl.genBuffers(1, _names);
    _ebo = _names[0];

    const stride = kGpuFloatsPerVertex * 4;
    _gl
      ..bindBuffer(glArrayBuffer, _vbo)
      ..bindBuffer(glElementArrayBuffer, _ebo);
    _attribute(kAttributePosition, 2, kGpuPositionOffset * 4, stride);
    _attribute(kAttributeTexCoord, 2, kGpuTexCoordOffset * 4, stride);
    _attribute(kAttributeColor, 4, kGpuColorOffset * 4, stride);
    _attribute(kAttributeShapeRect, 4, kGpuShapeRectOffset * 4, stride);

    if (_checkError('device initialisation')) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'GL reported an error while creating the renderer objects',
        detail: _lastError?.detail,
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

  bool _makeCurrentOrLose() {
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
  /// clean [_checkError].
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
  bool _checkError(String what) {
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
      if (_vbo != 0) {
        _names[0] = _vbo;
        _gl.deleteBuffers(1, _names);
      }
      if (_ebo != 0) {
        _names[0] = _ebo;
        _gl.deleteBuffers(1, _names);
      }
      if (_vao != 0) {
        _names[0] = _vao;
        _gl.deleteVertexArrays(1, _names);
      }
      if (_program != 0) _gl.deleteProgram(_program);
    }
    _context.dispose();
    _heap
      ..release(_names)
      ..release(_status)
      ..release(_stringSlot)
      ..release(_log)
      ..release(_vertexStaging)
      ..release(_indexStaging)
      ..release(_pixelStaging);
  }
}

/// A render target backed by a framebuffer object.
final class GlOffscreenTarget with DisposableMixin implements RenderTarget {
  GlOffscreenTarget._(this._device, MemorySurfaceDescriptor surface)
      : _surface = surface {
    _maskAtlas = GpuMaskAtlas();
    _maskTexture = _device.createTexture(
      width: _maskAtlas.width,
      height: _maskAtlas.height,
      format: GpuTextureFormat.alpha8,
      // One texel per pixel by construction, so nearest reproduces the CPU
      // rasteriser's coverage byte exactly and linear would blur it.
      filter: GpuTextureFilter.nearest,
    );
    _images = GlImageCache(_device);
    _sink = GpuRasterSink(
      batcher: _batcher,
      backendName: 'opengl',
      maskAtlas: _maskAtlas,
      maskTextureId: _maskTexture.id,
      imageResolver: _images,
    );
    _player = DisplayListPlayer(_sink);
    _createSurfaceObjects();
  }

  final GlRenderDevice _device;
  final GpuBatcher _batcher = GpuBatcher();

  late final GpuMaskAtlas _maskAtlas;
  late final GlTexture _maskTexture;
  late final GlImageCache _images;
  late final GpuRasterSink _sink;
  late final DisplayListPlayer _player;

  /// The textures this target uploaded for drawn images. Exposed so a caller
  /// that finished with a picture can drop them without disposing the target.
  GlImageCache get images => _images;

  MemorySurfaceDescriptor _surface;
  late GlTexture _colorTexture;
  int _fbo = 0;
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
    if (!_device._makeCurrentOrLose()) {
      return _device.state.blockedPresent() ??
          const PresentResult(
            status: PresentStatus.deviceLost,
            diagnostic: BackendDiagnostic(
              kind: DiagnosticKind.connectionFailed,
              message: 'the GL context could not be made current to present',
            ),
          );
    }
    _device._gl.bindFramebuffer(glFramebuffer, _fbo);

    // One upload for everything the frame's masks wrote, over whole rows.
    // Whole rows because a narrower sub-rectangle would upload the same
    // number of rows anyway once the stride is honoured, and the atlas is
    // dirty in bands rather than columns.
    if (_maskAtlas.isDirty) {
      final top = _maskAtlas.dirtyTop;
      final height = _maskAtlas.dirtyBottom - top;
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

    final drawn = _device._submit(
      _batcher,
      _readback.width,
      _readback.height,
      _pendingClear,
    );
    if (drawn) _device._readPixels(_readback);

    final lost = _device.state.blockedPresent();
    if (lost != null) return lost;
    return const PresentResult(status: PresentStatus.presented);
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
    _createSurfaceObjects();
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
    _player.play(
      DisplayListReader(list),
      DisplayListResources(list),
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

  void _createSurfaceObjects() {
    _readback = Framebuffer.allocate(
      width: _surface.pixelWidth,
      height: _surface.pixelHeight,
      format: _surface.format,
    );
    _colorTexture = _device.createTexture(
      width: _surface.pixelWidth,
      height: _surface.pixelHeight,
      format: GpuTextureFormat.rgba8888Premultiplied,
    );
    final gl = _device._gl;
    gl.genFramebuffers(1, _device._names);
    _fbo = _device._names[0];
    gl
      ..bindFramebuffer(glFramebuffer, _fbo)
      ..framebufferTexture2D(
          glFramebuffer, glColorAttachment0, glTexture2D, _colorTexture.id, 0);
    final status = gl.checkFramebufferStatus(glFramebuffer);
    if (status != glFramebufferComplete) {
      _device.state.markLost(
        BackendDiagnostic(
          kind: DiagnosticKind.surfaceCreationFailed,
          message: 'the offscreen framebuffer is incomplete',
          detail: 'glCheckFramebufferStatus returned '
              '0x${status.toRadixString(16)} for '
              '${_surface.pixelWidth}x${_surface.pixelHeight}',
        ),
      );
    }
    _device._checkError('framebuffer creation');
  }

  void _destroySurfaceObjects() {
    if (_fbo != 0 && !_device.state.isLost) {
      _device._names[0] = _fbo;
      _device._gl.deleteFramebuffers(1, _device._names);
    }
    _fbo = 0;
    _device.releaseTexture(_colorTexture);
  }

  @override
  void onDispose() {
    _destroySurfaceObjects();
    _images.clear();
    _device.releaseTexture(_maskTexture);
  }
}

/// Uploads drawn images into textures, once each.
///
/// `GpuRasterSink` asks for one of these and, until now, nothing implemented
/// the interface - so every `drawImage` on this backend threw. The display
/// list interns an image as an opaque `Object`; the CPU renderer already
/// fixes what that object is (a [Framebuffer]), and agreeing with it here is
/// what lets one display list be drawn by either backend and compared.
///
/// The cache is keyed by identity and never evicts. That is honest rather
/// than clever: an eviction policy needs a frame budget this framework does
/// not measure yet, and a wrong one is worse than none because it re-uploads
/// the image being animated. [clear] is the escape hatch, and the target
/// calls it on dispose.
final class GlImageCache implements GpuImageResolver {
  GlImageCache(this._device);

  final GlRenderDevice _device;
  final Map<Object, GlTexture> _textures = Map<Object, GlTexture>.identity();

  /// How many textures are held. For tests and for a memory report.
  int get length => _textures.length;

  @override
  GpuTextureHandle? resolve(Object image) {
    if (image is! Framebuffer) return null;
    final cached = _textures[image];
    if (cached != null && cached.isValid) return cached;

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
    _textures[image] = texture;
    return texture;
  }

  /// Releases every texture. The next [resolve] re-uploads.
  void clear() {
    for (final texture in _textures.values) {
      _device.releaseTexture(texture);
    }
    _textures.clear();
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
      );

  @override
  bool supportsSurface(NativeSurfaceDescriptor surface) =>
      surface is MemorySurfaceDescriptor;

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
        diagnostics: attempt.diagnostics,
      );
    }

    try {
      return describeContext(context, attempt.diagnostics);
    } finally {
      context.dispose();
    }
  }

  /// What a live context reports about itself, as a probe result.
  ///
  /// Public because the Windows path creates its context elsewhere - a WGL
  /// context needs a window, and windows live in `lib/src/backends` - and
  /// then wants exactly this report about it.
  static BackendProbeResult describeContext(
    GlContext context, [
    List<BackendDiagnostic> prior = const <BackendDiagnostic>[],
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
            message:
                'glGetString(GL_VERSION) returned nothing with a context '
                'current',
          ),
        ],
      );
    }
    return BackendProbeResult(
      backendName: backendName,
      supported: true,
      capabilities: const <Capability>{Capability.cpuPresentation},
      diagnostics: <BackendDiagnostic>[
        ...prior,
        BackendDiagnostic.note(
          '$renderer, GL $version',
          detail: 'vendor: $vendor; ${context.description}; GLSL '
              '${gl.stringOf(glShadingLanguageVersion)}',
        ),
        const BackendDiagnostic.note(
          'offscreen only: this backend renders to framebuffer objects and '
          'has no windowed target yet',
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
    DynamicLibrary glLibrary,
  ) {
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
    final device = GlRenderDevice._(
      context: context,
      gl: gl,
      heap: heap,
      info: RendererInfo(
        name: backendName,
        deviceDescription: gl.stringOf(glRenderer),
        driverVersion: gl.stringOf(glVersion),
      ),
      maxTextureSize: _queryMaxTextureSize(gl, heap),
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
