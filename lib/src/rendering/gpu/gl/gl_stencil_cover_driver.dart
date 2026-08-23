/// Production [GlApi] adapter for the opt-in stencil-then-cover executor.
library;

import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import '../gpu_pipeline.dart';
import '../vector/stencil_cover_draw_plan.dart';
import 'gl_bindings.dart';
import 'gl_stencil_cover_executor.dart';

/// Integer GL scissor obtained by outward-rounding device-space bounds.
final class StencilCoverGlScissor {
  const StencilCoverGlScissor(this.x, this.y, this.width, this.height);

  factory StencilCoverGlScissor.fromBounds({
    required double left,
    required double top,
    required double right,
    required double bottom,
    required int viewportWidth,
    required int viewportHeight,
    required int yFlip,
  }) {
    if (viewportWidth <= 0 || viewportHeight <= 0) {
      throw ArgumentError('viewport must be positive');
    }
    if (yFlip != 0 && yFlip != 1) {
      throw ArgumentError.value(yFlip, 'yFlip', 'must be 0 or 1');
    }
    final int x0 = left.floor().clamp(0, viewportWidth);
    final int x1 = right.ceil().clamp(0, viewportWidth);
    final int y0 = top.floor().clamp(0, viewportHeight);
    final int y1 = bottom.ceil().clamp(0, viewportHeight);
    return StencilCoverGlScissor(
      x0,
      yFlip == 0 ? viewportHeight - y1 : y0,
      math.max(0, x1 - x0),
      math.max(0, y1 - y0),
    );
  }

  final int x;
  final int y;
  final int width;
  final int height;
}

final class GlApiStencilCoverDriver implements StencilCoverGlDriver {
  GlApiStencilCoverDriver(this._gl, this._heap)
      : _names = _heap.allocate<Uint32>(sizeOf<Uint32>()),
        _status = _heap.allocate<Int32>(sizeOf<Int32>()),
        _sourceSlot = _heap.allocatePointers<Uint8>(1),
        _log = _heap.allocate<Uint8>(_logCapacity);

  final GlApi _gl;
  final NativeHeap _heap;
  final Pointer<Uint32> _names;
  final Pointer<Int32> _status;
  final Pointer<Pointer<Uint8>> _sourceSlot;
  final Pointer<Uint8> _log;
  static const int _logCapacity = 4096;

  Pointer<Uint8> _staging = nullptr;
  int _stagingBytes = 0;
  int _program = 0;
  int _vao = 0;
  int _geometryBuffer = 0;
  int _coverBuffer = 0;
  int _viewportUniform = -1;
  int _yFlipUniform = -1;
  int _colorUniform = -1;
  int _viewportWidth = 0;
  int _viewportHeight = 0;
  int _yFlip = 0;
  bool _disposed = false;

  static bool isSupported(GlApi gl) =>
      missingStencilCoverGlSymbols(gl.resolveProc).isEmpty;

  @override
  StencilCoverCapabilities get capabilities {
    _throwIfDisposed();
    // STENCIL_BITS and SAMPLES describe the framebuffer bound right now, not
    // the context. Never cache them across targets, resize or recovery.
    return _queryCapabilities();
  }

  @override
  void createResources({
    required String vertexSource,
    required String fragmentSource,
  }) {
    _throwIfDisposed();
    if (_program != 0) return;
    if (!isSupported(_gl)) {
      throw UnsupportedError(
        'missing stencil-cover GL symbols: '
        '${missingStencilCoverGlSymbols(_gl.resolveProc).join(', ')}',
      );
    }
    final int vertex = _compile(glVertexShader, vertexSource);
    final int fragment;
    try {
      fragment = _compile(glFragmentShader, fragmentSource);
    } catch (_) {
      _gl.deleteShader(vertex);
      rethrow;
    }
    final int program = _gl.createProgram();
    if (program == 0) {
      _gl
        ..deleteShader(vertex)
        ..deleteShader(fragment);
      throw StateError('GL returned object name zero for stencil program');
    }
    try {
      final Pointer<Uint8> position = _heap.allocateUtf8('aPosition');
      try {
        _gl
          ..attachShader(program, vertex)
          ..attachShader(program, fragment)
          ..bindAttribLocation(program, 0, position)
          ..linkProgram(program)
          ..getProgramiv(program, glLinkStatus, _status);
      } finally {
        _heap.release(position);
      }
      if (_status[0] == glFalseValue) {
        _gl.getProgramInfoLog(program, _logCapacity, nullptr, _log);
        throw StateError(
          'stencil-cover GL program failed to link: '
          '${readNativeUtf8(_log, limit: _logCapacity)}',
        );
      }
    } catch (_) {
      _gl.deleteProgram(program);
      rethrow;
    } finally {
      _gl
        ..deleteShader(vertex)
        ..deleteShader(fragment);
    }

    _program = program;
    _viewportUniform = _uniform(program, 'uViewport');
    _yFlipUniform = _uniform(program, 'uYFlip');
    _colorUniform = _uniform(program, 'uColor');
    if (_viewportUniform < 0 || _yFlipUniform < 0 || _colorUniform < 0) {
      _gl.deleteProgram(program);
      _forgetNames();
      throw StateError('stencil-cover program is missing a required uniform');
    }
    _gl.genVertexArrays(1, _names);
    _vao = _names[0];
    if (_vao == 0) {
      _gl.deleteProgram(_program);
      _forgetNames();
      throw StateError('GL returned object name zero for stencil VAO');
    }
    _gl.genBuffers(1, _names);
    _geometryBuffer = _names[0];
    _gl.genBuffers(1, _names);
    _coverBuffer = _names[0];
    if (_geometryBuffer == 0 || _coverBuffer == 0) {
      _deleteObjects();
      throw StateError('GL returned object name zero for stencil buffer');
    }
  }

  @override
  void deleteResources() => _deleteObjects();

  @override
  void uploadVertices(Float32List vertices, int vertexCount) {
    _requireResources();
    final int floatCount = vertexCount * kStencilCoverVertexStride;
    if (vertexCount < 0 || floatCount > vertices.length) {
      throw RangeError('stencil vertex upload exceeds source arena');
    }
    final int bytes = floatCount * sizeOf<Float>();
    final Pointer<Uint8> native = _ensureStaging(bytes);
    native.asTypedList(bytes).setAll(
          0,
          vertices.buffer.asUint8List(vertices.offsetInBytes, bytes),
        );
    _gl
      ..bindVertexArray(_vao)
      ..bindBuffer(glArrayBuffer, _geometryBuffer)
      ..bufferData(glArrayBuffer, bytes, native.cast<Void>(), glDynamicDraw)
      ..enableVertexAttribArray(0)
      ..vertexAttribPointer(
        0,
        2,
        glFloat,
        glFalseValue,
        kStencilCoverVertexStride * sizeOf<Float>(),
        nullptr,
      );
  }

  @override
  void beginStencilCoverPass({
    required int viewportWidth,
    required int viewportHeight,
    required int yFlip,
  }) {
    _requireResources();
    _viewportWidth = viewportWidth;
    _viewportHeight = viewportHeight;
    _yFlip = yFlip;
    _gl
      ..viewport(0, 0, viewportWidth, viewportHeight)
      ..useProgram(_program)
      ..bindVertexArray(_vao)
      ..uniform2f(
        _viewportUniform,
        viewportWidth.toDouble(),
        viewportHeight.toDouble(),
      )
      ..uniform1i(_yFlipUniform, yFlip)
      ..disable(glDepthTest)
      ..disable(glCullFace)
      ..enable(glStencilTest)
      ..enable(glScissorTest)
      ..enable(glBlend)
      // Keep positive signed device-space triangles on GL's front face under
      // both projection orientations.
      ..frontFace(yFlip == 0 ? glCw : glCcw);
  }

  @override
  void clearStencil({
    required double left,
    required double top,
    required double right,
    required double bottom,
    required int value,
    required int writeMask,
  }) {
    _setScissor(left, top, right, bottom);
    _gl
      ..colorMask(0, 0, 0, 0)
      ..stencilMask(writeMask)
      ..clearStencil(value)
      ..clear(glStencilBufferBit);
  }

  @override
  void setPassState(StencilCoverPassState state) {
    final int color = state.colorWrites ? 1 : 0;
    final (int, int) comparison = switch (state.compare) {
      StencilCompare.always => (glAlways, 0),
      StencilCompare.notEqualZero => (glNotEqual, 0),
      StencilCompare.leastSignificantBitSet => (glEqual, 1),
    };
    _gl
      ..colorMask(color, color, color, color)
      ..stencilMask(state.writeMask)
      ..stencilFunc(comparison.$1, comparison.$2, state.compareMask)
      ..stencilOpSeparate(
        glFront,
        glKeep,
        glKeep,
        _stencilOperation(state.frontPass),
      )
      ..stencilOpSeparate(
        glBack,
        glKeep,
        glKeep,
        _stencilOperation(state.backPass),
      );
  }

  @override
  void setBlendState(GpuBlendState blend) => _gl.blendFunc(
        _glFactor(blend.source),
        _glFactor(blend.destination),
      );

  @override
  void setPremultipliedColor(
    double red,
    double green,
    double blue,
    double alpha,
  ) =>
      _gl.uniform4f(_colorUniform, red, green, blue, alpha);

  @override
  void drawTriangles({required int firstVertex, required int vertexCount}) {
    _bindPositionBuffer(_geometryBuffer);
    _gl.drawArrays(glTriangles, firstVertex, vertexCount);
  }

  @override
  void drawCover({
    required double left,
    required double top,
    required double right,
    required double bottom,
  }) {
    _setScissor(left, top, right, bottom);
    const int vertices = 6;
    final Pointer<Uint8> native =
        _ensureStaging(vertices * 2 * sizeOf<Float>());
    native.cast<Float>().asTypedList(vertices * 2).setAll(0, <double>[
      left,
      top,
      right,
      top,
      left,
      bottom,
      left,
      bottom,
      right,
      top,
      right,
      bottom,
    ]);
    _gl
      ..bindBuffer(glArrayBuffer, _coverBuffer)
      ..bufferData(
        glArrayBuffer,
        vertices * 2 * sizeOf<Float>(),
        native.cast<Void>(),
        glDynamicDraw,
      );
    _bindPositionBuffer(_coverBuffer);
    _gl.drawArrays(glTriangles, 0, vertices);
  }

  @override
  void endStencilCoverPass() {
    _gl
      ..colorMask(1, 1, 1, 1)
      ..stencilMask(0xFFFFFFFF)
      ..disable(glStencilTest)
      ..disable(glScissorTest)
      ..disable(glBlend)
      ..frontFace(glCcw)
      ..bindVertexArray(0)
      ..useProgram(0);
  }

  @override
  void discardNativeResources() => _forgetNames();

  /// Releases native host staging after GL resources have been dealt with.
  void disposeHostResources() {
    if (_disposed) return;
    _disposed = true;
    _heap
      ..release(_names)
      ..release(_status)
      ..release(_sourceSlot)
      ..release(_log)
      ..release(_staging);
    _staging = nullptr;
  }

  StencilCoverCapabilities _queryCapabilities() {
    _status[0] = 0;
    _gl.getIntegerv(glDrawFramebufferBinding, _status);
    final int framebuffer = _status[0];
    final int bits = framebuffer == 0
        ? _defaultFramebufferStencilBits()
        : _attachmentStencilBits(glStencilAttachment);
    _status[0] = 0;
    _gl.getIntegerv(glSamples, _status);
    final int samples = math.max(1, _status[0]);
    return StencilCoverCapabilities(
      stencilBits: bits,
      sampleCount: samples,
      separateFrontBackOperations: true,
      wrapOperations: true,
      invertOperation: true,
      scissoredClear: true,
    );
  }

  int _defaultFramebufferStencilBits() {
    // Core profiles removed GL_STENCIL_BITS from glGetIntegerv. Attachment
    // queries remain valid, but a double-buffered window exposes BACK_LEFT
    // while a single-buffered pbuffer exposes FRONT_LEFT.
    _gl.drainErrors();
    final int back = _attachmentStencilBits(glBackLeft);
    if (_gl.getError() == glNoError) return back;
    _gl.drainErrors();
    final int front = _attachmentStencilBits(glFrontLeft);
    return _gl.getError() == glNoError ? front : 0;
  }

  /// Stencil bits of [attachment] on the bound draw framebuffer, or 0.
  ///
  /// The object type is asked for first, and that ordering is required rather
  /// than defensive. `GL_FRAMEBUFFER_ATTACHMENT_STENCIL_SIZE` is only a legal
  /// query when the attachment exists: on an attachment whose object type is
  /// `GL_NONE`, the specification says the call generates
  /// `GL_INVALID_OPERATION` - and a GL error is *sticky*. Asking anyway
  /// therefore does not merely return a wrong number; it leaves an error in
  /// the queue that the next unrelated `checkError` picks up, and that one
  /// marks the device lost. It was measured doing exactly that: a colour-only
  /// FBO queried here poisoned every following test in the file, which read as
  /// a driver that had stopped drawing.
  ///
  /// A colour-only framebuffer having no stencil is an ordinary answer - it is
  /// what every pooled layer target reports - so it is answered with 0 and no
  /// error at all.
  int _attachmentStencilBits(int attachment) {
    _status[0] = glNone;
    _gl.getFramebufferAttachmentParameteriv(
      glDrawFramebuffer,
      attachment,
      glFramebufferAttachmentObjectType,
      _status,
    );
    if (_gl.getError() != glNoError || _status[0] == glNone) return 0;
    _status[0] = 0;
    _gl.getFramebufferAttachmentParameteriv(
      glDrawFramebuffer,
      attachment,
      glFramebufferAttachmentStencilSize,
      _status,
    );
    return _gl.getError() == glNoError ? _status[0] : 0;
  }

  int _compile(int type, String source) {
    final int shader = _gl.createShader(type);
    if (shader == 0) throw StateError('GL returned shader object name zero');
    final Pointer<Uint8> native = _heap.allocateUtf8(source);
    try {
      _sourceSlot[0] = native;
      _gl
        ..shaderSource(shader, 1, _sourceSlot, nullptr)
        ..compileShader(shader)
        ..getShaderiv(shader, glCompileStatus, _status);
    } finally {
      _heap.release(native);
    }
    if (_status[0] != glFalseValue) return shader;
    _gl
      ..getShaderInfoLog(shader, _logCapacity, nullptr, _log)
      ..deleteShader(shader);
    throw StateError(
      'stencil-cover shader failed to compile: '
      '${readNativeUtf8(_log, limit: _logCapacity)}',
    );
  }

  int _uniform(int program, String name) {
    final Pointer<Uint8> native = _heap.allocateUtf8(name);
    try {
      return _gl.getUniformLocation(program, native);
    } finally {
      _heap.release(native);
    }
  }

  Pointer<Uint8> _ensureStaging(int bytes) {
    if (bytes <= _stagingBytes) return _staging;
    _heap.release(_staging);
    _stagingBytes = math.max(64, bytes * 2);
    return _staging = _heap.allocate<Uint8>(_stagingBytes);
  }

  void _bindPositionBuffer(int buffer) {
    _gl
      ..bindVertexArray(_vao)
      ..bindBuffer(glArrayBuffer, buffer)
      ..enableVertexAttribArray(0)
      ..vertexAttribPointer(
        0,
        2,
        glFloat,
        glFalseValue,
        2 * sizeOf<Float>(),
        nullptr,
      );
  }

  void _setScissor(double left, double top, double right, double bottom) {
    final StencilCoverGlScissor scissor = StencilCoverGlScissor.fromBounds(
      left: left,
      top: top,
      right: right,
      bottom: bottom,
      viewportWidth: _viewportWidth,
      viewportHeight: _viewportHeight,
      yFlip: _yFlip,
    );
    _gl.scissor(scissor.x, scissor.y, scissor.width, scissor.height);
  }

  void _deleteObjects() {
    if (_geometryBuffer != 0) {
      _names[0] = _geometryBuffer;
      _gl.deleteBuffers(1, _names);
    }
    if (_coverBuffer != 0) {
      _names[0] = _coverBuffer;
      _gl.deleteBuffers(1, _names);
    }
    if (_vao != 0) {
      _names[0] = _vao;
      _gl.deleteVertexArrays(1, _names);
    }
    if (_program != 0) _gl.deleteProgram(_program);
    _forgetNames();
  }

  void _forgetNames() {
    _program = 0;
    _vao = 0;
    _geometryBuffer = 0;
    _coverBuffer = 0;
    _viewportUniform = -1;
    _yFlipUniform = -1;
    _colorUniform = -1;
  }

  void _requireResources() {
    _throwIfDisposed();
    if (_program == 0 ||
        _vao == 0 ||
        _geometryBuffer == 0 ||
        _coverBuffer == 0) {
      throw StateError('stencil-cover GL resources are not initialized');
    }
  }

  void _throwIfDisposed() {
    if (_disposed) throw StateError('the stencil-cover GL driver is disposed');
  }

  static int _stencilOperation(StencilOperation operation) =>
      switch (operation) {
        StencilOperation.keep => glKeep,
        StencilOperation.zero => glZero,
        StencilOperation.incrementWrap => glIncrementWrap,
        StencilOperation.decrementWrap => glDecrementWrap,
        StencilOperation.invertLeastSignificantBit => glInvert,
      };

  static int _glFactor(GpuBlendFactor factor) => switch (factor) {
        GpuBlendFactor.zero => glZero,
        GpuBlendFactor.one => glOne,
        GpuBlendFactor.oneMinusSrcAlpha => glOneMinusSrcAlpha,
      };
}
