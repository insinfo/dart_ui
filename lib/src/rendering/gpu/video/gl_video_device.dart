/// The OpenGL implementation of the streaming video contract.
///
/// Self-contained on purpose: it owns its own program, its own vertex array
/// and its own staging arena, and it reaches OpenGL through [GlApi] rather
/// than through `GlRenderDevice`. Two reasons.
///
/// First, it has nothing to share with the dense renderer. Its vertices carry
/// source-pixel coordinates instead of a colour and a shape rectangle, it
/// binds up to three samplers where that program binds one, and it never
/// batches - a video frame is one quad, and a timeline showing eight of them
/// is eight draw calls, which is not a number worth batching away.
///
/// Second, and more practically: the file that would have to change to fold it
/// in is the largest and busiest in the renderer. A video path that can be
/// added, tested and measured without touching it is a video path that can
/// land while the rest of the GPU work is in flight. Wiring it into the
/// batching sink is a separate, later decision, and the shape of that wiring
/// is [GlVideoDevice.drawFrame].
///
/// ## What this file requires of the context
///
/// GL 3.3 core or GLES 3.0: `texelFetch`, two-channel textures and vertex
/// array objects. That is the same floor `gl_shaders.dart` already sets with
/// `#version 330 core` / `300 es`, so it costs no device that the renderer
/// could otherwise have used.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../../../geometry/offset.dart';
import '../../../geometry/rect.dart';
import '../../../geometry/transform2d.dart';
import '../../../graphics/video/video_color_conversion.dart';
import '../../../graphics/video/video_frame.dart';
import '../gl/gl_bindings.dart';
import 'gpu_video_texture.dart';
import 'video_gl_shaders.dart';
import 'video_upload_ring.dart';

/// Two-channel formats, which `gl_bindings.dart` has no need of.
///
/// Declared here rather than added there because NV12's interleaved chroma is
/// the only thing in this renderer that wants them, and a constant in the
/// shared table is a constant every backend author has to wonder about.
const int _glRg = 0x8227;
const int _glRg8 = 0x822B;

/// One plane of one buffer.
final class GlVideoPlaneTexture implements VideoPlaneTexture {
  GlVideoPlaneTexture._(this.id, this.width, this.height, this.sampleFormat);

  @override
  final int id;

  @override
  final int width;

  @override
  final int height;

  @override
  final VideoPlaneSampleFormat sampleFormat;

  bool _released = false;

  @override
  bool get isValid => !_released && id != 0;

  @override
  String toString() => 'GlVideoPlaneTexture($id, ${width}x$height, '
      '${sampleFormat.name})';
}

/// A stream's textures: `bufferCount` sets of planes and the ring over them.
final class GlStreamingVideoTexture implements GpuStreamingVideoTexture {
  GlStreamingVideoTexture._({
    required this.format,
    required this.streamId,
    required this.bufferCount,
    required List<List<GlVideoPlaneTexture>> buffers,
  })  : _buffers = buffers,
        ring = VideoUploadRing(bufferCount: bufferCount);

  @override
  final VideoFrameFormat format;

  @override
  final int streamId;

  @override
  final int bufferCount;

  @override
  final VideoUploadRing ring;

  final List<List<GlVideoPlaneTexture>> _buffers;
  bool _released = false;

  @override
  int get planeCount => format.planeCount;

  @override
  int get frontSequence => ring.frontSequence;

  @override
  bool get isValid => !_released;

  /// Plane [index] of the buffer the last upload presented.
  ///
  /// Before the first upload there is no front buffer and buffer zero is
  /// answered with instead of throwing: a caller that draws a stream before
  /// feeding it gets a black frame, which is what an empty texture holds and
  /// what a timeline scrubbed past the end of a clip should show anyway.
  @override
  GlVideoPlaneTexture plane(int index) =>
      _buffers[ring.frontBuffer < 0 ? 0 : ring.frontBuffer][index];

  @override
  GlVideoPlaneTexture planeOfBuffer(int buffer, int index) =>
      _buffers[buffer][index];

  @override
  String toString() => 'GlStreamingVideoTexture(stream $streamId, $format, '
      '$bufferCount buffers)';
}

/// Counters for one [GlVideoDevice.drawFrame], for the benchmark and for a
/// test that wants to prove a partial upload stayed partial.
final class VideoDrawStats {
  const VideoDrawStats({
    required this.planeBinds,
    required this.vertexBytes,
  });

  final int planeBinds;
  final int vertexBytes;
}

/// Creates, feeds and draws video textures on a live GL context.
///
/// The context must be current on the calling thread for every method here.
/// This class deliberately does not make it current itself: it does not own
/// the context, and a class that silently switches the current context is a
/// class that will do it in the middle of somebody else's pass.
final class GlVideoDevice implements GpuVideoTextureAllocator {
  GlVideoDevice(
    this._gl,
    this._heap, {
    required bool desktop,
  })  : _desktop = desktop,
        _names = _heap.allocate<Uint32>(sizeOf<Uint32>() * 4),
        _status = _heap.allocate<Int32>(sizeOf<Int32>()),
        _sourceSlot = _heap.allocatePointers<Uint8>(1),
        _log = _heap.allocate<Uint8>(_logCapacity),
        _vertices = _heap.allocate<Float>(sizeOf<Float>() * 16);

  static const int _logCapacity = 4096;

  /// Four vertices of four floats: position x, y and source x, y.
  static const int _floatsPerVertex = 4;
  static const int _vertexCount = 4;

  final GlApi _gl;
  final NativeHeap _heap;
  final bool _desktop;

  final Pointer<Uint32> _names;
  final Pointer<Int32> _status;
  final Pointer<Pointer<Uint8>> _sourceSlot;
  final Pointer<Uint8> _log;
  final Pointer<Float> _vertices;

  Pointer<Uint8> _staging = nullptr;
  int _stagingBytes = 0;

  int _program = 0;
  int _vao = 0;
  int _vbo = 0;
  bool _disposed = false;

  int _uViewport = -1;
  int _uYFlip = -1;
  int _uFormat = -1;
  int _uFrameSize = -1;
  int _uOpacity = -1;
  int _uMatrixR = -1;
  int _uMatrixG = -1;
  int _uMatrixB = -1;
  final List<int> _uPlanes = <int>[-1, -1, -1];

  bool get isInitialized => _program != 0;
  bool get isDisposed => _disposed;

  /// Every format is streamable here, because every one of them decomposes
  /// into R8, RG8 and RGBA8 textures - the three formats any GL 3.3 or ES 3.0
  /// context has. Partial upload is honoured because `glTexSubImage2D` is
  /// exactly that call.
  @override
  VideoTextureCapabilities get videoCapabilities => const VideoTextureCapabilities(
        streamingFormats: <VideoPixelFormat>{
          VideoPixelFormat.nv12,
          VideoPixelFormat.i420,
          VideoPixelFormat.yuy2,
          VideoPixelFormat.bgra8888,
          VideoPixelFormat.rgba8888,
        },
        supportsPartialUpload: true,
        // Not a driver limit; a policy one. Past three the ring stops hiding
        // latency and starts adding it, and a frame of 1080p NV12 is three
        // megabytes of device memory per buffer.
        maxBufferCount: 4,
        supportsForeignImport: false,
      );

  /// Compiles the program and allocates the quad's buffer.
  void initialize() {
    _throwIfDisposed();
    if (isInitialized) return;
    validateVideoGlShaderContract();

    final int vertex = _compile(
      glVertexShader,
      videoVertexShaderSource(desktop: _desktop),
    );
    final int fragment;
    try {
      fragment = _compile(
        glFragmentShader,
        videoFragmentShaderSource(desktop: _desktop),
      );
    } on Object {
      _gl.deleteShader(vertex);
      rethrow;
    }

    final int program = _gl.createProgram();
    if (program == 0) {
      _gl
        ..deleteShader(vertex)
        ..deleteShader(fragment);
      throw StateError('GL returned object name zero for the video program');
    }
    try {
      _gl
        ..attachShader(program, vertex)
        ..attachShader(program, fragment);
      for (var i = 0; i < kVideoAttributeNames.length; i++) {
        final Pointer<Uint8> name = _heap.allocateUtf8(kVideoAttributeNames[i]);
        try {
          _gl.bindAttribLocation(program, i, name);
        } finally {
          _heap.release(name);
        }
      }
      _gl
        ..linkProgram(program)
        ..getProgramiv(program, glLinkStatus, _status);
      if (_status[0] == glFalseValue) {
        _gl.getProgramInfoLog(program, _logCapacity, nullptr, _log);
        throw StateError('the video GL program failed to link: '
            '${readNativeUtf8(_log, limit: _logCapacity)}');
      }
    } on Object {
      _gl.deleteProgram(program);
      rethrow;
    } finally {
      _gl
        ..deleteShader(vertex)
        ..deleteShader(fragment);
    }

    _program = program;
    _uViewport = _uniform('uViewport');
    _uYFlip = _uniform('uYFlip');
    _uFormat = _uniform('uFormat');
    _uFrameSize = _uniform('uFrameSize');
    _uOpacity = _uniform('uOpacity');
    _uMatrixR = _uniform('uMatrixR');
    _uMatrixG = _uniform('uMatrixG');
    _uMatrixB = _uniform('uMatrixB');
    for (var i = 0; i < kVideoSamplerNames.length; i++) {
      _uPlanes[i] = _uniform(kVideoSamplerNames[i]);
    }
    // Every uniform above is used by the shader body, so a driver may not
    // optimise any of them away. A -1 here means the source and this file
    // disagree about a name, which would otherwise surface as a frame that
    // renders black with no error anywhere.
    for (final int location in <int>[
      _uViewport,
      _uYFlip,
      _uFormat,
      _uFrameSize,
      _uOpacity,
      _uMatrixR,
      _uMatrixG,
      _uMatrixB,
    ]) {
      if (location < 0) {
        throw StateError('the video GL program is missing a uniform this file '
            'requires; the shader source and gl_video_device.dart have '
            'drifted apart');
      }
    }

    _gl.genVertexArrays(1, _names);
    _vao = _names[0];
    _gl.genBuffers(1, _names);
    _vbo = _names[0];
    if (_vao == 0 || _vbo == 0) {
      throw StateError('GL returned object name zero for the video quad');
    }

    final int stride = _floatsPerVertex * sizeOf<Float>();
    _gl
      ..bindVertexArray(_vao)
      ..bindBuffer(glArrayBuffer, _vbo)
      ..enableVertexAttribArray(kVideoAttributePosition)
      ..vertexAttribPointer(
          kVideoAttributePosition, 2, glFloat, 0, stride, nullptr)
      ..enableVertexAttribArray(kVideoAttributeSource)
      ..vertexAttribPointer(kVideoAttributeSource, 2, glFloat, 0, stride,
          Pointer<Void>.fromAddress(2 * sizeOf<Float>()))
      ..bindVertexArray(0);
    _checkError('video program setup');
  }

  // -------------------------------------------------------------------
  // Allocation
  // -------------------------------------------------------------------

  @override
  GlStreamingVideoTexture createStreamingTexture({
    required VideoFrameFormat format,
    required int streamId,
    int bufferCount = VideoUploadRing.doubleBuffered,
  }) {
    _throwIfDisposed();
    if (!videoCapabilities.supportsStreaming(format.pixelFormat)) {
      throw ArgumentError.value(
        format.pixelFormat,
        'format.pixelFormat',
        'this device cannot stream it',
      );
    }
    if (bufferCount < 1 || bufferCount > videoCapabilities.maxBufferCount) {
      throw ArgumentError.value(
        bufferCount,
        'bufferCount',
        'must be 1..${videoCapabilities.maxBufferCount}',
      );
    }

    final List<List<GlVideoPlaneTexture>> buffers =
        <List<GlVideoPlaneTexture>>[];
    try {
      for (var buffer = 0; buffer < bufferCount; buffer++) {
        final List<GlVideoPlaneTexture> planes = <GlVideoPlaneTexture>[];
        for (var index = 0; index < format.planeCount; index++) {
          planes.add(_createPlane(format, index));
        }
        buffers.add(planes);
      }
    } on Object {
      for (final List<GlVideoPlaneTexture> planes in buffers) {
        for (final GlVideoPlaneTexture plane in planes) {
          _deletePlane(plane);
        }
      }
      rethrow;
    }

    return GlStreamingVideoTexture._(
      format: format,
      streamId: streamId,
      bufferCount: bufferCount,
      buffers: buffers,
    );
  }

  GlVideoPlaneTexture _createPlane(VideoFrameFormat format, int index) {
    final VideoPlaneSampleFormat sampleFormat =
        VideoPlaneSampleFormat.forPlane(format.pixelFormat, index);
    final int width = format.planeWidth(index);
    final int height = format.planeHeight(index);
    final (int internal, int external) = _glFormatsFor(sampleFormat);

    _gl.genTextures(1, _names);
    final int name = _names[0];
    if (name == 0) {
      throw StateError('GL returned texture name zero for a video plane');
    }
    _gl
      ..bindTexture(glTexture2D, name)
      // Nearest and clamp even though every fetch is a texelFetch, which
      // ignores both: a texture with the default mipmap min filter is
      // *incomplete*, and an incomplete texture samples as black with no error
      // raised anywhere.
      ..texParameteri(glTexture2D, glTextureMinFilter, glNearest)
      ..texParameteri(glTexture2D, glTextureMagFilter, glNearest)
      ..texParameteri(glTexture2D, glTextureWrapS, glClampToEdge)
      ..texParameteri(glTexture2D, glTextureWrapT, glClampToEdge)
      ..pixelStorei(glUnpackAlignment, 1)
      ..texImage2D(glTexture2D, 0, internal, width, height, 0, external,
          glUnsignedByte, nullptr);
    _checkError('glTexImage2D(video plane $index, ${width}x$height)');
    return GlVideoPlaneTexture._(name, width, height, sampleFormat);
  }

  static (int, int) _glFormatsFor(VideoPlaneSampleFormat format) =>
      switch (format) {
        VideoPlaneSampleFormat.r8 => (glR8, glRed),
        VideoPlaneSampleFormat.rg8 => (_glRg8, _glRg),
        VideoPlaneSampleFormat.rgba8 => (glRgba8, glRgba),
      };

  // -------------------------------------------------------------------
  // Upload
  // -------------------------------------------------------------------

  @override
  VideoUploadReceipt uploadFrame(
    covariant GlStreamingVideoTexture texture,
    VideoFrame frame, {
    VideoRegion? region,
  }) {
    _throwIfDisposed();
    if (!texture.isValid) {
      throw StateError('the streaming texture was released');
    }
    if (frame.streamId != texture.streamId) {
      throw ArgumentError.value(
        frame.streamId,
        'frame.streamId',
        'this texture belongs to stream ${texture.streamId}; uploading a '
            'frame from another stream into it is how one clip\'s pixels end '
            'up inside another\'s rectangle',
      );
    }
    if (!frame.format.hasSameLayoutAs(texture.format)) {
      throw ArgumentError.value(
        frame.format,
        'frame.format',
        'does not match the texture\'s ${texture.format}; a stream that '
            'changes size or pixel format needs a new texture',
      );
    }

    final VideoRegion whole =
        VideoRegion.wholeFrame(frame.width, frame.height);
    final VideoRegion asked = region == null
        ? whole
        : region.alignedTo(frame.format.pixelFormat).intersect(whole);
    if (asked.isEmpty) {
      throw ArgumentError.value(
        region,
        'region',
        'does not overlap the ${frame.width}x${frame.height} frame',
      );
    }
    final bool partial = asked != whole;

    final int buffer = texture.ring.acquire(frame.sequence);
    var bytes = 0;
    try {
      for (var index = 0; index < frame.format.planeCount; index++) {
        bytes += _uploadPlane(
          texture.planeOfBuffer(buffer, index),
          frame,
          index,
          asked,
        );
      }
    } on Object {
      texture.ring.abandon(buffer);
      rethrow;
    }
    texture.ring.present(buffer);

    return VideoUploadReceipt(
      buffer: buffer,
      sequence: frame.sequence,
      region: asked,
      bytesUploaded: bytes,
      wasPartial: partial,
    );
  }

  /// Copies one plane's rows into native staging and hands them to GL.
  ///
  /// The copy is not avoidable: `glTexSubImage2D` wants an address, and Dart
  /// typed data has none that survives a call into native code. What *is*
  /// avoidable is doing it a row at a time, so the contiguous case - a
  /// tightly packed plane uploaded whole, which is what a decoder that writes
  /// into its own buffer produces - is one bulk `setRange` instead of `height`
  /// of them. At 1080p that is the difference between one copy of two
  /// megabytes and one thousand and eighty copies of two kilobytes.
  int _uploadPlane(
    GlVideoPlaneTexture texture,
    VideoFrame frame,
    int index,
    VideoRegion region,
  ) {
    final VideoFrameFormat format = frame.format;
    final VideoPlaneGeometry geometry = format.planeGeometry(index);
    final VideoPlane plane = frame.plane(index);

    // The region in this plane's own sample grid. The alignment done by
    // `VideoRegion.alignedTo` is what makes these divisions exact.
    final int x = region.left ~/ geometry.widthDivisor;
    final int y = region.top ~/ geometry.heightDivisor;
    final int width = geometry.width(region.right) - x;
    final int height = geometry.height(region.bottom) - y;
    if (width <= 0 || height <= 0) return 0;

    final int rowBytes = width * geometry.bytesPerSample;
    final int total = rowBytes * height;
    final Pointer<Uint8> staging = _ensureStaging(total);
    final Uint8List view = staging.asTypedList(total);
    final int sourceStart = plane.rowOffset(y) + x * geometry.bytesPerSample;

    if (rowBytes == plane.bytesPerRow) {
      view.setRange(0, total, plane.bytes, sourceStart);
    } else {
      for (var row = 0; row < height; row++) {
        view.setRange(
          row * rowBytes,
          row * rowBytes + rowBytes,
          plane.bytes,
          sourceStart + row * plane.bytesPerRow,
        );
      }
    }

    final (int _, int external) = _glFormatsFor(texture.sampleFormat);
    _gl
      ..bindTexture(glTexture2D, texture.id)
      ..pixelStorei(glUnpackAlignment, 1)
      ..texSubImage2D(glTexture2D, 0, x, y, width, height, external,
          glUnsignedByte, staging.cast<Void>());
    _checkError('glTexSubImage2D(video plane $index)');
    return total;
  }

  @override
  void releaseStreamingTexture(covariant GlStreamingVideoTexture texture) {
    if (texture._released) return;
    texture._released = true;
    if (_disposed) return;
    for (final List<GlVideoPlaneTexture> planes in texture._buffers) {
      for (final GlVideoPlaneTexture plane in planes) {
        _deletePlane(plane);
      }
    }
  }

  void _deletePlane(GlVideoPlaneTexture plane) {
    if (plane._released || plane.id == 0) return;
    plane._released = true;
    _names[0] = plane.id;
    _gl.deleteTextures(1, _names);
  }

  // -------------------------------------------------------------------
  // Drawing
  // -------------------------------------------------------------------

  /// Draws [sourceRect] of [texture]'s front buffer into the quad that
  /// [transform] maps [destination] to.
  ///
  /// [transform] is applied here rather than by the caller so that a rotated
  /// or skewed frame is *correct*, not bounded: the four corners are
  /// transformed and handed to the vertex stage, which is the one place in
  /// this renderer where an arbitrary matrix costs nothing at all. The
  /// display-list path can only ask for an axis-aligned box - see the
  /// transform note in `display_list_player.dart` - but nothing here is
  /// limited by that.
  ///
  /// [clip] is a device rectangle and becomes the scissor. [opacity] is 0..1
  /// and multiplies the premultiplied result, so a frame at half opacity is
  /// half its colour and half its alpha, exactly as `saveLayer` would produce.
  ///
  /// The GL state this leaves behind: the program, the vertex array and the
  /// array buffer are unbound, the scissor test is disabled, and blending is
  /// left enabled with the premultiplied source-over function. A caller that
  /// wanted something else sets it after; a caller that shares a context with
  /// the dense renderer is going to reset all of this at the top of its own
  /// pass anyway, which is why nothing here tries to save and restore.
  VideoDrawStats drawFrame(
    GlStreamingVideoTexture texture, {
    required Rect sourceRect,
    required Rect destination,
    required Rect clip,
    required int viewportWidth,
    required int viewportHeight,
    Transform2D transform = Transform2D.identity,
    double opacity = 1.0,
    int yFlip = 0,
  }) {
    _throwIfDisposed();
    if (!isInitialized) {
      throw StateError('initialize the video GL device before drawing');
    }
    if (!texture.isValid) {
      throw StateError('the streaming texture was released');
    }
    if (viewportWidth <= 0 || viewportHeight <= 0) {
      throw ArgumentError('the viewport must be positive');
    }
    if (yFlip != 0 && yFlip != 1) {
      throw ArgumentError.value(yFlip, 'yFlip', 'must be 0 or 1');
    }
    if (!opacity.isFinite || opacity < 0 || opacity > 1) {
      throw ArgumentError.value(opacity, 'opacity', 'must be 0..1');
    }

    final Offset topLeft =
        transform.transformOffset(Offset(destination.left, destination.top));
    final Offset topRight =
        transform.transformOffset(Offset(destination.right, destination.top));
    final Offset bottomLeft =
        transform.transformOffset(Offset(destination.left, destination.bottom));
    final Offset bottomRight = transform
        .transformOffset(Offset(destination.right, destination.bottom));

    // Triangle strip order: top-left, bottom-left, top-right, bottom-right.
    _writeVertex(0, topLeft, sourceRect.left, sourceRect.top);
    _writeVertex(1, bottomLeft, sourceRect.left, sourceRect.bottom);
    _writeVertex(2, topRight, sourceRect.right, sourceRect.top);
    _writeVertex(3, bottomRight, sourceRect.right, sourceRect.bottom);

    final YuvToRgbMatrix matrix = YuvToRgbMatrix.forFormat(texture.format);
    final int vertexBytes = _vertexCount * _floatsPerVertex * sizeOf<Float>();

    _gl
      ..useProgram(_program)
      ..bindVertexArray(_vao)
      ..bindBuffer(glArrayBuffer, _vbo)
      ..bufferData(
          glArrayBuffer, vertexBytes, _vertices.cast<Void>(), glDynamicDraw)
      ..uniform2f(_uViewport, viewportWidth.toDouble(), viewportHeight.toDouble())
      ..uniform1i(_uYFlip, yFlip)
      ..uniform1i(_uFormat, videoGlModeFor(texture.format.pixelFormat))
      ..uniform2f(_uFrameSize, texture.format.width.toDouble(),
          texture.format.height.toDouble());
    _setOpacity(opacity);
    _gl
      ..uniform4f(_uMatrixR, matrix.rY, matrix.rU, matrix.rV, matrix.rOffset)
      ..uniform4f(_uMatrixG, matrix.gY, matrix.gU, matrix.gV, matrix.gOffset)
      ..uniform4f(_uMatrixB, matrix.bY, matrix.bU, matrix.bV, matrix.bOffset);

    final int planeCount = texture.planeCount;
    for (var index = 0; index < kVideoSamplerNames.length; index++) {
      final int location = _uPlanes[index];
      if (location < 0) continue;
      _gl.uniform1i(location, index);
    }
    for (var index = 0; index < planeCount; index++) {
      _gl
        ..activeTexture(glTexture0 + index)
        ..bindTexture(glTexture2D, texture.plane(index).id);
    }

    final int scissorY = yFlip == 0
        ? viewportHeight - clip.bottom.round()
        : clip.top.round();
    _gl
      ..viewport(0, 0, viewportWidth, viewportHeight)
      ..enable(glScissorTest)
      ..scissor(
        clip.left.round(),
        scissorY,
        clip.width.round(),
        clip.height.round(),
      )
      ..enable(glBlend)
      ..blendFunc(glOne, glOneMinusSrcAlpha)
      ..drawArrays(glTriangleStrip, 0, _vertexCount)
      ..disable(glScissorTest)
      ..bindVertexArray(0)
      ..bindBuffer(glArrayBuffer, 0)
      ..useProgram(0);
    _checkError('video drawArrays');

    return VideoDrawStats(planeBinds: planeCount, vertexBytes: vertexBytes);
  }

  /// Sets the scalar opacity uniform.
  ///
  /// `glUniform1f` is not in `gl_bindings.dart`'s table, and three other
  /// backends are editing that file. Rather than widen it, the uniform is set
  /// through `glUniform4f`, which is legal for a `float` uniform in GL: the
  /// extra components are ignored. That is a documented property of the API
  /// and not a trick - `glUniform4f` on a `float` sets the first component -
  /// but it is the kind of thing that looks like a bug to the next reader, so
  /// it says so here.
  void _setOpacity(double opacity) {
    _gl.uniform4f(_uOpacity, opacity, 0, 0, 0);
  }

  void _writeVertex(int index, Offset position, double sx, double sy) {
    final int base = index * _floatsPerVertex;
    _vertices[base] = position.dx;
    _vertices[base + 1] = position.dy;
    _vertices[base + 2] = sx;
    _vertices[base + 3] = sy;
  }

  // -------------------------------------------------------------------
  // Lifetime
  // -------------------------------------------------------------------

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_vbo != 0) {
      _names[0] = _vbo;
      _gl.deleteBuffers(1, _names);
      _vbo = 0;
    }
    if (_vao != 0) {
      _names[0] = _vao;
      _gl.deleteVertexArrays(1, _names);
      _vao = 0;
    }
    if (_program != 0) {
      _gl.deleteProgram(_program);
      _program = 0;
    }
    if (_staging != nullptr) {
      _heap.release(_staging);
      _staging = nullptr;
      _stagingBytes = 0;
    }
    _heap
      ..release(_names)
      ..release(_status)
      ..release(_sourceSlot)
      ..release(_log)
      ..release(_vertices);
  }

  Pointer<Uint8> _ensureStaging(int bytes) {
    if (_stagingBytes >= bytes) return _staging;
    if (_staging != nullptr) _heap.release(_staging);
    // Grow by halves rather than exactly. A stream whose dirty region grows a
    // row at a time would otherwise reallocate once per frame forever.
    final int size = bytes + (bytes >> 1);
    _staging = _heap.allocate<Uint8>(size);
    _stagingBytes = size;
    return _staging;
  }

  int _uniform(String name) {
    final Pointer<Uint8> encoded = _heap.allocateUtf8(name);
    try {
      return _gl.getUniformLocation(_program, encoded);
    } finally {
      _heap.release(encoded);
    }
  }

  int _compile(int stage, String source) {
    final int shader = _gl.createShader(stage);
    if (shader == 0) {
      throw StateError('GL returned object name zero for a video shader');
    }
    final Pointer<Uint8> encoded = _heap.allocateUtf8(source);
    try {
      _sourceSlot[0] = encoded;
      _gl
        ..shaderSource(shader, 1, _sourceSlot, nullptr)
        ..compileShader(shader)
        ..getShaderiv(shader, glCompileStatus, _status);
      if (_status[0] == glFalseValue) {
        _gl.getShaderInfoLog(shader, _logCapacity, nullptr, _log);
        final String log = readNativeUtf8(_log, limit: _logCapacity);
        _gl.deleteShader(shader);
        throw StateError(
          'a video GL shader failed to compile: $log',
        );
      }
    } on Object {
      rethrow;
    } finally {
      _heap.release(encoded);
    }
    return shader;
  }

  void _checkError(String what) {
    final int error = _gl.getError();
    if (error == glNoError) return;
    throw StateError('$what raised GL error 0x${error.toRadixString(16)}');
  }

  void _throwIfDisposed() {
    if (_disposed) throw StateError('the video GL device is disposed');
  }
}
