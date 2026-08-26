/// Production [GlApi] adapter for retained CPU-tessellated meshes.
library;

import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../../geometry/rect.dart';
import '../../../geometry/transform2d.dart';
import '../gpu_pipeline.dart';
import '../vector/cpu_tessellation.dart';
import 'gl_bindings.dart';
import 'gl_tessellated_executor.dart';

const int _glStaticDraw = 0x88E4;

final class GlApiTessellatedDriver implements TessellatedGlDriver {
  GlApiTessellatedDriver(this._gl, this._heap)
      : _names = _heap.allocate<Uint32>(sizeOf<Uint32>() * 2),
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

  Pointer<Uint8> _vertexStaging = nullptr;
  int _vertexStagingBytes = 0;
  Pointer<Uint8> _indexStaging = nullptr;
  int _indexStagingBytes = 0;
  int _program = 0;
  int _vao = 0;
  int _viewport = -1;
  int _yFlipUniform = -1;
  int _transform0 = -1;
  int _transform1 = -1;
  int _color = -1;
  int _viewportWidth = 0;
  int _viewportHeight = 0;
  int _yFlip = 0;
  bool _disposed = false;

  @override
  void createResources({
    required String vertexSource,
    required String fragmentSource,
  }) {
    _throwIfDisposed();
    if (_program != 0) return;
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
      throw StateError('GL returned object name zero for tessellation program');
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
          'tessellated GL program failed to link: '
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
    _viewport = _uniform('uViewport');
    _yFlipUniform = _uniform('uYFlip');
    _transform0 = _uniform('uLocalToTarget0');
    _transform1 = _uniform('uLocalToTarget1');
    _color = _uniform('uColor');
    if (<int>[_viewport, _yFlipUniform, _transform0, _transform1, _color]
        .any((int value) => value < 0)) {
      deleteResources();
      throw StateError('tessellated GL program is missing a required uniform');
    }
    _gl.genVertexArrays(1, _names);
    _vao = _names[0];
    if (_vao == 0) {
      deleteResources();
      throw StateError('GL returned object name zero for tessellation VAO');
    }
  }

  @override
  void deleteResources() {
    if (_vao != 0) {
      _names[0] = _vao;
      _gl.deleteVertexArrays(1, _names);
    }
    if (_program != 0) _gl.deleteProgram(_program);
    _forgetObjects();
  }

  @override
  TessellatedGlMeshHandle uploadMesh(TessellatedPathMesh mesh) {
    _throwIfDisposed();
    if (_program == 0 || _vao == 0) {
      throw StateError('tessellated GL resources are not initialized');
    }
    final int vertexBytes = mesh.vertices.lengthInBytes;
    final int indexBytes = mesh.indices.lengthInBytes;
    final Pointer<Uint8> vertexStaging = _ensureVertexStaging(vertexBytes);
    final Pointer<Uint8> indexStaging = _ensureIndexStaging(indexBytes);
    vertexStaging.asTypedList(vertexBytes).setAll(
          0,
          mesh.vertices.buffer.asUint8List(
            mesh.vertices.offsetInBytes,
            vertexBytes,
          ),
        );
    indexStaging.asTypedList(indexBytes).setAll(
          0,
          mesh.indices.buffer
              .asUint8List(mesh.indices.offsetInBytes, indexBytes),
        );

    _gl.genBuffers(2, _names);
    final int vertexBuffer = _names[0];
    final int indexBuffer = _names[1];
    if (vertexBuffer == 0 || indexBuffer == 0) {
      if (vertexBuffer != 0) {
        _names[0] = vertexBuffer;
        _gl.deleteBuffers(1, _names);
      }
      if (indexBuffer != 0) {
        _names[0] = indexBuffer;
        _gl.deleteBuffers(1, _names);
      }
      throw StateError('GL returned object name zero for a retained mesh');
    }
    _gl
      ..bindVertexArray(_vao)
      ..bindBuffer(glArrayBuffer, vertexBuffer)
      ..bufferData(
        glArrayBuffer,
        vertexBytes,
        vertexStaging.cast<Void>(),
        _glStaticDraw,
      )
      ..bindBuffer(glElementArrayBuffer, indexBuffer)
      ..bufferData(
        glElementArrayBuffer,
        indexBytes,
        indexStaging.cast<Void>(),
        _glStaticDraw,
      )
      ..enableVertexAttribArray(0)
      ..vertexAttribPointer(
        0,
        2,
        glFloat,
        glFalseValue,
        2 * Float32List.bytesPerElement,
        nullptr,
      )
      ..bindVertexArray(0);
    return TessellatedGlMeshHandle(
      vertexBuffer: vertexBuffer,
      indexBuffer: indexBuffer,
      indexCount: mesh.indices.length,
      retainedBytes: vertexBytes + indexBytes,
    );
  }

  @override
  void deleteMesh(TessellatedGlMeshHandle mesh) {
    _names[0] = mesh.vertexBuffer;
    _names[1] = mesh.indexBuffer;
    _gl.deleteBuffers(2, _names);
  }

  @override
  void beginTessellatedPass({
    required int viewportWidth,
    required int viewportHeight,
    required int yFlip,
  }) {
    if (_program == 0 || _vao == 0) {
      throw StateError('tessellated GL resources are not initialized');
    }
    _viewportWidth = viewportWidth;
    _viewportHeight = viewportHeight;
    _yFlip = yFlip;
    _gl
      ..useProgram(_program)
      ..bindVertexArray(_vao)
      ..uniform2f(
          _viewport, viewportWidth.toDouble(), viewportHeight.toDouble())
      ..uniform1i(_yFlipUniform, yFlip)
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
  void setLocalToTarget(Transform2D transform) {
    _gl
      ..uniform4f(_transform0, transform.a, transform.c, transform.tx, 0)
      ..uniform4f(_transform1, transform.b, transform.d, transform.ty, 0);
  }

  @override
  void setClip(Rect? clip) {
    if (clip == null) {
      _gl.disable(glScissorTest);
      return;
    }
    final int left = clip.left.floor().clamp(0, _viewportWidth);
    final int right = clip.right.ceil().clamp(0, _viewportWidth);
    final int top = clip.top.floor().clamp(0, _viewportHeight);
    final int bottom = clip.bottom.ceil().clamp(0, _viewportHeight);
    final int width = math.max(0, right - left);
    final int height = math.max(0, bottom - top);
    final int glY = _yFlip == 0 ? _viewportHeight - bottom : top;
    _gl
      ..enable(glScissorTest)
      ..scissor(left, glY, width, height);
  }

  @override
  void drawMesh(TessellatedGlMeshHandle mesh) {
    _gl
      ..bindBuffer(glArrayBuffer, mesh.vertexBuffer)
      ..bindBuffer(glElementArrayBuffer, mesh.indexBuffer)
      ..enableVertexAttribArray(0)
      ..vertexAttribPointer(
        0,
        2,
        glFloat,
        glFalseValue,
        2 * Float32List.bytesPerElement,
        nullptr,
      )
      ..drawElements(glTriangles, mesh.indexCount, glUnsignedInt, nullptr);
  }

  @override
  void endTessellatedPass() {
    _gl
      ..disable(glScissorTest)
      ..bindVertexArray(0)
      ..useProgram(0);
  }

  @override
  void discardNativeResources() => _forgetObjects();

  void disposeHostResources() {
    if (_disposed) return;
    _disposed = true;
    _heap
      ..release(_names)
      ..release(_status)
      ..release(_sourceSlot)
      ..release(_log)
      ..release(_vertexStaging)
      ..release(_indexStaging);
    _vertexStaging = nullptr;
    _indexStaging = nullptr;
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
      'tessellated GL shader failed to compile: '
      '${readNativeUtf8(_log, limit: _logCapacity)}',
    );
  }

  int _uniform(String name) {
    final Pointer<Uint8> native = _heap.allocateUtf8(name);
    try {
      return _gl.getUniformLocation(_program, native);
    } finally {
      _heap.release(native);
    }
  }

  Pointer<Uint8> _ensureVertexStaging(int bytes) {
    if (bytes <= _vertexStagingBytes) return _vertexStaging;
    _heap.release(_vertexStaging);
    _vertexStagingBytes = bytes;
    return _vertexStaging = _heap.allocate<Uint8>(bytes);
  }

  Pointer<Uint8> _ensureIndexStaging(int bytes) {
    if (bytes <= _indexStagingBytes) return _indexStaging;
    _heap.release(_indexStaging);
    _indexStagingBytes = bytes;
    return _indexStaging = _heap.allocate<Uint8>(bytes);
  }

  void _forgetObjects() {
    _program = 0;
    _vao = 0;
    _viewport = -1;
    _yFlipUniform = -1;
    _transform0 = -1;
    _transform1 = -1;
    _color = -1;
    _viewportWidth = 0;
    _viewportHeight = 0;
  }

  static int _glFactor(GpuBlendFactor factor) => switch (factor) {
        GpuBlendFactor.zero => glZero,
        GpuBlendFactor.one => glOne,
        GpuBlendFactor.oneMinusSrcAlpha => glOneMinusSrcAlpha,
      };

  void _throwIfDisposed() {
    if (_disposed) throw StateError('the tessellated GL driver is disposed');
  }
}
