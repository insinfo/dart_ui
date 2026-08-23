/// Production [GlApi] adapter for the opt-in sparse-strip executor.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../gpu_pipeline.dart';
import 'gl_bindings.dart';
import 'gl_sparse_executor.dart';

/// Maps the narrow, fakeable sparse contract to a context-bound [GlApi].
///
/// The adapter owns the sparse VAO and native staging arenas. The executor
/// owns program, VBO and texture names through this object. Keeping those
/// inventories separate from the dense renderer is what makes the feature
/// genuinely opt-in rather than another stateful branch in every dense draw.
final class GlApiSparseDriver implements SparseGlDriver {
  GlApiSparseDriver(this._gl, this._heap)
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

  Pointer<Uint8> _instanceStaging = nullptr;
  int _instanceStagingBytes = 0;
  Pointer<Uint8> _alphaStaging = nullptr;
  int _alphaStagingBytes = 0;
  int _vao = 0;
  int _program = 0;
  int _viewport = -1;
  int _yFlip = -1;
  int _color = -1;
  int _mode = -1;
  int _alphaAtlas = -1;
  bool _disposed = false;

  /// Whether the current context exposes the three entry points that are not
  /// required by the established dense renderer.
  static bool isSupported(GlApi gl) =>
      missingSparseGlSymbols(gl.resolveProc).isEmpty;

  @override
  int createSparseProgram({
    required String vertexSource,
    required String fragmentSource,
  }) {
    _throwIfDisposed();
    final int vertex = _compile(glVertexShader, vertexSource);
    final int fragment;
    try {
      fragment = _compile(glFragmentShader, fragmentSource);
    } on Object {
      _gl.deleteShader(vertex);
      rethrow;
    }
    final int program = _gl.createProgram();
    if (program == 0) {
      _gl
        ..deleteShader(vertex)
        ..deleteShader(fragment);
      throw StateError('GL returned object name zero for the sparse program');
    }
    try {
      _gl
        ..attachShader(program, vertex)
        ..attachShader(program, fragment)
        ..linkProgram(program)
        ..getProgramiv(program, glLinkStatus, _status);
      if (_status[0] == glFalseValue) {
        _gl.getProgramInfoLog(program, _logCapacity, nullptr, _log);
        throw StateError(
          'sparse GL program failed to link: '
          '${readNativeUtf8(_log, limit: _logCapacity)}',
        );
      }
    } catch (_) {
      if (program != 0) _gl.deleteProgram(program);
      rethrow;
    } finally {
      _gl
        ..deleteShader(vertex)
        ..deleteShader(fragment);
    }

    _program = program;
    _viewport = _uniform(program, 'uViewport');
    _yFlip = _uniform(program, 'uYFlip');
    _color = _uniform(program, 'uColor');
    _mode = _uniform(program, 'uMode');
    _alphaAtlas = _uniform(program, 'uAlphaAtlas');
    if (<int>[_viewport, _yFlip, _color, _mode, _alphaAtlas]
        .any((int value) => value < 0)) {
      _gl.deleteProgram(program);
      _program = 0;
      throw StateError('the sparse GL program is missing a required uniform');
    }
    return program;
  }

  @override
  void deleteProgram(int program) {
    if (program != 0) _gl.deleteProgram(program);
    if (_program == program) _forgetProgram();
  }

  @override
  int createInstanceBuffer() {
    _throwIfDisposed();
    _gl.genVertexArrays(1, _names);
    _vao = _names[0];
    if (_vao == 0) return 0;
    _gl.bindVertexArray(_vao);
    _gl.genBuffers(1, _names);
    final int buffer = _names[0];
    if (buffer == 0) {
      _names[0] = _vao;
      _gl
        ..deleteVertexArrays(1, _names)
        ..bindVertexArray(0);
      _vao = 0;
      return 0;
    }
    _gl.bindBuffer(glArrayBuffer, buffer);
    return buffer;
  }

  @override
  void deleteBuffer(int buffer) {
    if (buffer != 0) {
      _names[0] = buffer;
      _gl.deleteBuffers(1, _names);
    }
    if (_vao != 0) {
      _names[0] = _vao;
      _gl.deleteVertexArrays(1, _names);
      _vao = 0;
    }
  }

  @override
  int createAlpha8Texture({required int width, required int height}) {
    _throwIfDisposed();
    _gl.genTextures(1, _names);
    final int texture = _names[0];
    if (texture == 0) return 0;
    _gl
      ..bindTexture(glTexture2D, texture)
      ..pixelStorei(glUnpackAlignment, 1)
      ..texParameteri(glTexture2D, glTextureMinFilter, glNearest)
      ..texParameteri(glTexture2D, glTextureMagFilter, glNearest)
      ..texParameteri(glTexture2D, glTextureWrapS, glClampToEdge)
      ..texParameteri(glTexture2D, glTextureWrapT, glClampToEdge)
      ..texImage2D(
        glTexture2D,
        0,
        glR8,
        width,
        height,
        0,
        glRed,
        glUnsignedByte,
        nullptr,
      );
    return texture;
  }

  @override
  void deleteTexture(int texture) {
    if (texture == 0) return;
    _names[0] = texture;
    _gl.deleteTextures(1, _names);
  }

  @override
  void uploadInstances(int buffer, Float32List instances) {
    final int bytes = instances.lengthInBytes;
    final Pointer<Uint8> staging = _ensureInstanceStaging(bytes);
    staging.asTypedList(bytes).setAll(
        0,
        instances.buffer.asUint8List(
          instances.offsetInBytes,
          bytes,
        ));
    _gl
      ..bindVertexArray(_vao)
      ..bindBuffer(glArrayBuffer, buffer)
      ..bufferData(glArrayBuffer, bytes, staging.cast<Void>(), glDynamicDraw);
  }

  @override
  void uploadAlpha8Region(
    int texture, {
    required int x,
    required int y,
    required int width,
    required int height,
    required Uint8List pixels,
    required int sourceOffset,
    required int sourceBytesPerRow,
  }) {
    if (width <= 0 || height <= 0 || sourceBytesPerRow < width) {
      throw ArgumentError('invalid sparse alpha upload dimensions');
    }
    final int last = sourceOffset + (height - 1) * sourceBytesPerRow + width;
    if (sourceOffset < 0 || last > pixels.length) {
      throw RangeError('sparse alpha upload exceeds its source page');
    }
    final int bytes = width * height;
    final Pointer<Uint8> staging = _ensureAlphaStaging(bytes);
    final Uint8List compact = staging.asTypedList(bytes);
    for (var row = 0; row < height; row++) {
      final int source = sourceOffset + row * sourceBytesPerRow;
      compact.setRange(row * width, (row + 1) * width, pixels, source);
    }
    _gl
      ..activeTexture(glTexture0)
      ..bindTexture(glTexture2D, texture)
      ..pixelStorei(glUnpackAlignment, 1)
      ..texSubImage2D(
        glTexture2D,
        0,
        x,
        y,
        width,
        height,
        glRed,
        glUnsignedByte,
        staging.cast<Void>(),
      );
  }

  @override
  void beginSparsePass({
    required int program,
    required int instanceBuffer,
    required int viewportWidth,
    required int viewportHeight,
    required int yFlip,
  }) {
    if (program != _program || _vao == 0) {
      throw StateError('sparse GL objects do not belong to this driver');
    }
    _gl
      ..useProgram(program)
      ..bindVertexArray(_vao)
      ..bindBuffer(glArrayBuffer, instanceBuffer)
      ..uniform2f(
          _viewport, viewportWidth.toDouble(), viewportHeight.toDouble())
      ..uniform1i(_yFlip, yFlip)
      ..uniform1i(_alphaAtlas, 0)
      ..enable(glBlend);
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
      _gl.uniform4f(_color, red, green, blue, alpha);

  @override
  void setSparseMode(int mode) => _gl.uniform1i(_mode, mode);

  @override
  void bindAlpha8Texture(int texture) {
    _gl
      ..activeTexture(glTexture0)
      ..bindTexture(glTexture2D, texture);
  }

  @override
  void setInstanceAttribute({
    required int location,
    required int components,
    required int strideBytes,
    required int offsetBytes,
    required int divisor,
  }) {
    _gl
      ..enableVertexAttribArray(location)
      ..vertexAttribPointer(
        location,
        components,
        glFloat,
        glFalseValue,
        strideBytes,
        Pointer<Void>.fromAddress(offsetBytes),
      )
      ..vertexAttribDivisor(location, divisor);
  }

  @override
  void drawTriangleStripInstanced({
    required int vertexCount,
    required int instanceCount,
  }) =>
      _gl.drawArraysInstanced(glTriangleStrip, 0, vertexCount, instanceCount);

  @override
  void endSparsePass() {
    // Dense rendering owns another VAO, so rebinding zero prevents sparse
    // attribute rebases from leaking into whichever path runs next.
    _gl
      ..bindVertexArray(0)
      ..useProgram(0);
  }

  @override
  void discardNativeResources() {
    // Device loss already destroyed these names. Never send deletion through
    // a reset context, where an integer may have been recycled for new state.
    _vao = 0;
    _forgetProgram();
  }

  /// Releases the host-side arenas after the owning device has dealt with GL.
  void disposeHostResources() {
    if (_disposed) return;
    _disposed = true;
    _heap
      ..release(_names)
      ..release(_status)
      ..release(_sourceSlot)
      ..release(_log)
      ..release(_instanceStaging)
      ..release(_alphaStaging);
    _instanceStaging = nullptr;
    _alphaStaging = nullptr;
  }

  int _compile(int type, String source) {
    final int shader = _gl.createShader(type);
    if (shader == 0) {
      throw StateError(
        'GL returned object name zero for the sparse '
        '${type == glVertexShader ? 'vertex' : 'fragment'} shader',
      );
    }
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
      'sparse ${type == glVertexShader ? 'vertex' : 'fragment'} shader failed '
      'to compile: ${readNativeUtf8(_log, limit: _logCapacity)}',
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

  Pointer<Uint8> _ensureInstanceStaging(int bytes) {
    if (bytes <= _instanceStagingBytes) return _instanceStaging;
    _heap.release(_instanceStaging);
    _instanceStagingBytes = bytes * 2;
    return _instanceStaging = _heap.allocate<Uint8>(_instanceStagingBytes);
  }

  Pointer<Uint8> _ensureAlphaStaging(int bytes) {
    if (bytes <= _alphaStagingBytes) return _alphaStaging;
    _heap.release(_alphaStaging);
    _alphaStagingBytes = bytes * 2;
    return _alphaStaging = _heap.allocate<Uint8>(_alphaStagingBytes);
  }

  void _forgetProgram() {
    _program = 0;
    _viewport = -1;
    _yFlip = -1;
    _color = -1;
    _mode = -1;
    _alphaAtlas = -1;
  }

  static int _glFactor(GpuBlendFactor factor) => switch (factor) {
        GpuBlendFactor.zero => glZero,
        GpuBlendFactor.one => glOne,
        GpuBlendFactor.oneMinusSrcAlpha => glOneMinusSrcAlpha,
      };

  void _throwIfDisposed() {
    if (_disposed) throw StateError('the sparse GL driver is disposed');
  }
}
