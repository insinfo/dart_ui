/// Mesh rendering for WebGL2, without importing the native OpenGL backend.
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../../../foundation/diagnostics.dart';
import '../../../geometry/rect.dart';
import '../../../graphics/mesh/mesh3d.dart';
import '../../mesh/mesh_rasterizer.dart';
import '../../mesh/mesh_scene.dart';
import '../../renderer.dart';
import '../gl/gl_mesh_shaders.dart';
import 'webgl_backend.dart';
import 'webgl_canvas_target.dart';

final class WebGlMeshRendererAttempt {
  const WebGlMeshRendererAttempt(this.renderer, this.diagnostics);

  final WebGlMeshRenderer? renderer;
  final List<BackendDiagnostic> diagnostics;
}

/// A WebGL2 mesh program and its per-model GPU cache.
///
/// WebGL objects are opaque JavaScript objects, so this cannot reuse
/// `GlMeshPipeline` even though the shader and all rendering decisions are the
/// same. Keeping the shader source shared is what prevents the browser and
/// desktop paths from silently acquiring different lighting.
final class WebGlMeshRenderer implements MeshSceneRenderer {
  WebGlMeshRenderer._(this._device, this._program, this._uniforms);

  static WebGlMeshRendererAttempt create(WebGlRenderDevice device) {
    final web.WebGL2RenderingContext gl = device.gl;
    final Object vertex = _compile(gl, web.WebGL2RenderingContext.VERTEX_SHADER,
        meshVertexShaderSource(desktop: false));
    if (vertex is BackendDiagnostic) {
      return WebGlMeshRendererAttempt(null, <BackendDiagnostic>[vertex]);
    }
    final Object fragment = _compile(
        gl,
        web.WebGL2RenderingContext.FRAGMENT_SHADER,
        meshFragmentShaderSource(desktop: false));
    if (fragment is BackendDiagnostic) {
      gl.deleteShader(vertex as web.WebGLShader);
      return WebGlMeshRendererAttempt(null, <BackendDiagnostic>[fragment]);
    }
    final web.WebGLProgram? program = gl.createProgram();
    if (program == null) {
      return const WebGlMeshRendererAttempt(null, <BackendDiagnostic>[
        BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'WebGL2 refused to create the mesh program',
        ),
      ]);
    }
    gl
      ..attachShader(program, vertex as web.WebGLShader)
      ..attachShader(program, fragment as web.WebGLShader);
    for (var i = 0; i < kMeshAttributeNames.length; i++) {
      gl.bindAttribLocation(program, i, kMeshAttributeNames[i]);
    }
    gl.linkProgram(program);
    final JSAny? linked =
        gl.getProgramParameter(program, web.WebGL2RenderingContext.LINK_STATUS);
    if (linked == null || !(linked as JSBoolean).toDart) {
      final String log = gl.getProgramInfoLog(program) ?? '';
      gl.deleteProgram(program);
      return WebGlMeshRendererAttempt(null, <BackendDiagnostic>[
        BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'WebGL2 mesh program failed to link',
          detail: log,
        ),
      ]);
    }
    gl
      ..deleteShader(vertex)
      ..deleteShader(fragment);
    final uniforms = <String, web.WebGLUniformLocation>{};
    for (final String name in <String>[
      'uModelViewProjection',
      'uNormalMatrix',
      'uBaseColor',
      'uLightDirection',
      'uAmbient',
      'uLit',
      'uHasTexture',
      'uBaseColorTexture',
    ]) {
      final web.WebGLUniformLocation? location =
          gl.getUniformLocation(program, name);
      if (location == null) {
        gl.deleteProgram(program);
        return WebGlMeshRendererAttempt(null, <BackendDiagnostic>[
          BackendDiagnostic(
            kind: DiagnosticKind.incompatibleDevice,
            message: 'WebGL2 mesh program is missing $name',
          ),
        ]);
      }
      uniforms[name] = location;
    }
    return WebGlMeshRendererAttempt(
        WebGlMeshRenderer._(device, program, uniforms),
        const <BackendDiagnostic>[]);
  }

  final WebGlRenderDevice _device;
  final web.WebGLProgram _program;
  final Map<String, web.WebGLUniformLocation> _uniforms;
  final Map<MeshPrimitive, Map<MeshShading, _Geometry>> _geometry =
      <MeshPrimitive, Map<MeshShading, _Geometry>>{};
  final Map<MeshTexture, web.WebGLTexture> _textures =
      <MeshTexture, web.WebGLTexture>{};
  web.WebGLRenderbuffer? _depth;
  Object? _depthOwner;
  int _depthWidth = 0;
  int _depthHeight = 0;
  int _depthGeneration = -1;
  bool _disposed = false;

  int get bufferUploadCount => _bufferUploadCount;
  int _bufferUploadCount = 0;

  @override
  MeshRenderStats drawScene(RenderTarget target, MeshScene scene,
      {Rect? viewport}) {
    if (_disposed) throw StateError('this WebGlMeshRenderer is disposed');
    if (_device.isLost) return MeshRenderStats.zero;
    final _Surface? surface = switch (target) {
      WebGlOffscreenTarget() => _Surface(
          target,
          target.debugFramebuffer,
          target.surface.pixelWidth,
          target.surface.pixelHeight,
          target.generation),
      WebGlCanvasTarget() => _Surface(target, null, target.surface.pixelWidth,
          target.surface.pixelHeight, target.generation),
      _ => null,
    };
    if (surface == null || surface.width <= 0 || surface.height <= 0) {
      return MeshRenderStats.zero;
    }
    final web.WebGL2RenderingContext gl = _device.gl;
    gl.bindFramebuffer(web.WebGL2RenderingContext.FRAMEBUFFER, surface.fbo);
    if (!_ensureDepth(surface)) return MeshRenderStats.zero;

    final int left = viewport?.left.floor().clamp(0, surface.width) ?? 0;
    final int top = viewport?.top.floor().clamp(0, surface.height) ?? 0;
    final int right =
        viewport?.right.ceil().clamp(left, surface.width) ?? surface.width;
    final int bottom =
        viewport?.bottom.ceil().clamp(top, surface.height) ?? surface.height;
    final int width = right - left;
    final int height = bottom - top;
    if (width <= 0 || height <= 0) return MeshRenderStats.zero;

    final Stopwatch watch = Stopwatch()..start();
    final mvp = scene.camera
        .projectionMatrix(width / height)
        .multiply(scene.camera.viewMatrix());
    final normals = Matrix4.identity();
    final Vector3 light = scene.lightDirection.normalized;
    gl
      ..useProgram(_program)
      ..viewport(left, surface.height - bottom, width, height)
      ..disable(web.WebGL2RenderingContext.BLEND)
      ..disable(web.WebGL2RenderingContext.STENCIL_TEST)
      ..enable(web.WebGL2RenderingContext.DEPTH_TEST)
      ..depthFunc(web.WebGL2RenderingContext.LESS)
      ..depthMask(true)
      ..frontFace(web.WebGL2RenderingContext.CCW);
    if (scene.backgroundArgb case final int background) {
      gl
        ..disable(web.WebGL2RenderingContext.SCISSOR_TEST)
        ..clearColor(((background >> 16) & 255) / 255,
            ((background >> 8) & 255) / 255, (background & 255) / 255, 1)
        ..clear(web.WebGL2RenderingContext.COLOR_BUFFER_BIT |
            web.WebGL2RenderingContext.DEPTH_BUFFER_BIT);
    }
    if (left != 0 ||
        top != 0 ||
        right != surface.width ||
        bottom != surface.height) {
      gl
        ..scissor(left, surface.height - bottom, width, height)
        ..enable(web.WebGL2RenderingContext.SCISSOR_TEST);
    }
    _matrix('uModelViewProjection', mvp.storage);
    _matrix('uNormalMatrix', normals.storage);
    gl
      ..uniform3f(_uniforms['uLightDirection'], light.x, light.y, light.z)
      ..uniform1f(_uniforms['uAmbient'], scene.ambient)
      ..uniform1i(_uniforms['uBaseColorTexture'], 0)
      ..uniform1i(
          _uniforms['uLit'],
          scene.shading == MeshShading.unlit ||
                  scene.shading == MeshShading.wireframe
              ? kMeshShadeUnlit
              : kMeshShadeLit);
    var triangles = 0;
    var drawn = 0;
    for (final MeshPrimitive primitive in scene.mesh.primitives) {
      triangles += primitive.triangleCount;
      if (primitive.triangleCount == 0) continue;
      final _Geometry geometry = _geometryFor(primitive, scene.shading);
      final int color = primitive.material.colorArgb;
      gl.uniform3f(_uniforms['uBaseColor'], ((color >> 16) & 255) / 255,
          ((color >> 8) & 255) / 255, (color & 255) / 255);
      final web.WebGLTexture? texture = scene.shading == MeshShading.wireframe
          ? null
          : _textureFor(primitive);
      gl.uniform1i(_uniforms['uHasTexture'], texture == null ? 0 : 1);
      if (texture != null) {
        gl
          ..activeTexture(web.WebGL2RenderingContext.TEXTURE0)
          ..bindTexture(web.WebGL2RenderingContext.TEXTURE_2D, texture);
      }
      if (primitive.material.doubleSided) {
        gl.disable(web.WebGL2RenderingContext.CULL_FACE);
      } else {
        gl
          ..enable(web.WebGL2RenderingContext.CULL_FACE)
          ..cullFace(web.WebGL2RenderingContext.BACK);
      }
      gl.bindVertexArray(geometry.vao);
      gl.drawElements(geometry.mode, geometry.count,
          web.WebGL2RenderingContext.UNSIGNED_INT, 0);
      drawn += primitive.triangleCount;
    }
    gl
      ..bindVertexArray(null)
      ..disable(web.WebGL2RenderingContext.DEPTH_TEST)
      ..disable(web.WebGL2RenderingContext.CULL_FACE)
      ..disable(web.WebGL2RenderingContext.SCISSOR_TEST);
    watch.stop();
    return MeshRenderStats(
        triangles: triangles,
        drawn: drawn,
        culled: 0,
        clipped: 0,
        pixels: 0,
        microseconds: watch.elapsedMicroseconds);
  }

  _Geometry _geometryFor(MeshPrimitive primitive, MeshShading shading) {
    final Map<MeshShading, _Geometry> cache =
        _geometry.putIfAbsent(primitive, () => <MeshShading, _Geometry>{});
    return cache.putIfAbsent(shading, () {
      final bool lines = shading == MeshShading.wireframe;
      late final Float32List vertices;
      late Uint32List indices;
      if (shading == MeshShading.flat) {
        (vertices, indices) = _facetedGeometry(primitive);
      } else {
        final Float32List normals =
            primitive.normals ?? primitive.computeSmoothNormals();
        vertices = Float32List(primitive.vertexCount * 8);
        for (var i = 0; i < primitive.vertexCount; i++) {
          final int o = i * 8;
          vertices.setRange(o, o + 3, primitive.positions, i * 3);
          if (i * 3 + 2 < normals.length) {
            vertices.setRange(o + 3, o + 6, normals, i * 3);
          }
          if (primitive.uvs != null && i * 2 + 1 < primitive.uvs!.length) {
            vertices.setRange(o + 6, o + 8, primitive.uvs!, i * 2);
          }
        }
        indices = Uint32List.fromList(primitive.indices);
      }
      if (lines) {
        indices = Uint32List((primitive.indices.length ~/ 3) * 6);
        for (var i = 0; i < primitive.indices.length ~/ 3; i++) {
          final int a = primitive.indices[i * 3];
          final int b = primitive.indices[i * 3 + 1];
          final int c = primitive.indices[i * 3 + 2];
          indices.setRange(i * 6, i * 6 + 6, <int>[a, b, b, c, c, a]);
        }
      }
      final web.WebGL2RenderingContext gl = _device.gl;
      final web.WebGLVertexArrayObject vao = gl.createVertexArray()!;
      final web.WebGLBuffer vbo = gl.createBuffer()!;
      final web.WebGLBuffer ebo = gl.createBuffer()!;
      gl
        ..bindVertexArray(vao)
        ..bindBuffer(web.WebGL2RenderingContext.ARRAY_BUFFER, vbo)
        ..bufferData(web.WebGL2RenderingContext.ARRAY_BUFFER, vertices.toJS,
            web.WebGL2RenderingContext.STATIC_DRAW)
        ..bindBuffer(web.WebGL2RenderingContext.ELEMENT_ARRAY_BUFFER, ebo)
        ..bufferData(web.WebGL2RenderingContext.ELEMENT_ARRAY_BUFFER,
            indices.toJS, web.WebGL2RenderingContext.STATIC_DRAW);
      for (final (int index, int size, int offset) in <(int, int, int)>[
        (0, 3, 0),
        (1, 3, 12),
        (2, 2, 24)
      ]) {
        gl
          ..enableVertexAttribArray(index)
          ..vertexAttribPointer(
              index, size, web.WebGL2RenderingContext.FLOAT, false, 32, offset);
      }
      _bufferUploadCount += 2;
      return _Geometry(
          vao,
          vbo,
          ebo,
          indices.length,
          lines
              ? web.WebGL2RenderingContext.LINES
              : web.WebGL2RenderingContext.TRIANGLES);
    });
  }

  (Float32List, Uint32List) _facetedGeometry(MeshPrimitive primitive) {
    final int corners = (primitive.indices.length ~/ 3) * 3;
    final Float32List vertices = Float32List(corners * 8);
    final Uint32List indices = Uint32List(corners);
    var out = 0;
    for (var triangle = 0; triangle < corners; triangle += 3) {
      final int ia = primitive.indices[triangle];
      final int ib = primitive.indices[triangle + 1];
      final int ic = primitive.indices[triangle + 2];
      final Vector3 a = _position(primitive, ia);
      final Vector3 normal = (_position(primitive, ib) - a)
          .cross(_position(primitive, ic) - a)
          .normalized;
      for (final int source in <int>[ia, ib, ic]) {
        final int vertex = out ~/ 8;
        final int p = source * 3;
        vertices[out] = primitive.positions[p];
        vertices[out + 1] = primitive.positions[p + 1];
        vertices[out + 2] = primitive.positions[p + 2];
        vertices[out + 3] = normal.x;
        vertices[out + 4] = normal.y;
        vertices[out + 5] = normal.z;
        if (primitive.uvs != null && source * 2 + 1 < primitive.uvs!.length) {
          vertices[out + 6] = primitive.uvs![source * 2];
          vertices[out + 7] = primitive.uvs![source * 2 + 1];
        }
        indices[vertex] = vertex;
        out += 8;
      }
    }
    return (vertices, indices);
  }

  Vector3 _position(MeshPrimitive primitive, int index) => Vector3(
        primitive.positions[index * 3],
        primitive.positions[index * 3 + 1],
        primitive.positions[index * 3 + 2],
      );

  web.WebGLTexture? _textureFor(MeshPrimitive primitive) {
    final MeshTexture? texture = primitive.material.baseColorTexture;
    final Float32List? uvs = primitive.uvs;
    if (texture == null ||
        uvs == null ||
        uvs.length < primitive.vertexCount * 2) {
      return null;
    }
    return _textures.putIfAbsent(texture, () {
      final web.WebGL2RenderingContext gl = _device.gl;
      final web.WebGLTexture object = gl.createTexture()!;
      final Uint8List rgba = Uint8List(texture.width * texture.height * 4);
      for (var i = 0; i < texture.pixels.length; i++) {
        final int argb = texture.pixels[i];
        final int at = i * 4;
        rgba[at] = (argb >> 16) & 255;
        rgba[at + 1] = (argb >> 8) & 255;
        rgba[at + 2] = argb & 255;
        rgba[at + 3] = (argb >> 24) & 255;
      }
      gl
        ..bindTexture(web.WebGL2RenderingContext.TEXTURE_2D, object)
        ..pixelStorei(web.WebGL2RenderingContext.UNPACK_ALIGNMENT, 1)
        ..texImage2D(
            web.WebGL2RenderingContext.TEXTURE_2D,
            0,
            web.WebGL2RenderingContext.RGBA8,
            texture.width.toJS,
            texture.height.toJS,
            0.toJS,
            web.WebGL2RenderingContext.RGBA,
            web.WebGL2RenderingContext.UNSIGNED_BYTE,
            rgba.toJS)
        ..texParameteri(
            web.WebGL2RenderingContext.TEXTURE_2D,
            web.WebGL2RenderingContext.TEXTURE_WRAP_S,
            web.WebGL2RenderingContext.REPEAT)
        ..texParameteri(
            web.WebGL2RenderingContext.TEXTURE_2D,
            web.WebGL2RenderingContext.TEXTURE_WRAP_T,
            web.WebGL2RenderingContext.REPEAT)
        ..texParameteri(
            web.WebGL2RenderingContext.TEXTURE_2D,
            web.WebGL2RenderingContext.TEXTURE_MIN_FILTER,
            web.WebGL2RenderingContext.NEAREST)
        ..texParameteri(
            web.WebGL2RenderingContext.TEXTURE_2D,
            web.WebGL2RenderingContext.TEXTURE_MAG_FILTER,
            web.WebGL2RenderingContext.NEAREST);
      return object;
    });
  }

  bool _ensureDepth(_Surface surface) {
    // The default framebuffer's depth attachment belongs to the canvas and
    // cannot be replaced by application code. The context is created with
    // `depth: true`; only an offscreen framebuffer needs an attachment here.
    if (surface.fbo == null) return true;
    if (_depth != null &&
        identical(_depthOwner, surface.owner) &&
        _depthWidth == surface.width &&
        _depthHeight == surface.height &&
        _depthGeneration == surface.generation) {
      return true;
    }
    final web.WebGL2RenderingContext gl = _device.gl;
    if (_depth != null) gl.deleteRenderbuffer(_depth);
    final web.WebGLRenderbuffer? depth = gl.createRenderbuffer();
    if (depth == null) return false;
    gl
      ..bindRenderbuffer(web.WebGL2RenderingContext.RENDERBUFFER, depth)
      ..renderbufferStorage(
          web.WebGL2RenderingContext.RENDERBUFFER,
          web.WebGL2RenderingContext.DEPTH_COMPONENT24,
          surface.width,
          surface.height);
    if (surface.fbo != null) {
      gl.framebufferRenderbuffer(
          web.WebGL2RenderingContext.FRAMEBUFFER,
          web.WebGL2RenderingContext.DEPTH_ATTACHMENT,
          web.WebGL2RenderingContext.RENDERBUFFER,
          depth);
    }
    _depth = depth;
    _depthOwner = surface.owner;
    _depthWidth = surface.width;
    _depthHeight = surface.height;
    _depthGeneration = surface.generation;
    return surface.fbo == null ||
        gl.checkFramebufferStatus(web.WebGL2RenderingContext.FRAMEBUFFER) ==
            web.WebGL2RenderingContext.FRAMEBUFFER_COMPLETE;
  }

  void _matrix(String name, Float64List source) {
    final Float32List value = Float32List(16);
    for (var i = 0; i < 16; i++) {
      value[i] = source[i];
    }
    _device.gl.uniformMatrix4fv(_uniforms[name], false, value.toJS);
  }

  @override
  void discardMesh(Mesh3D mesh) {
    final web.WebGL2RenderingContext gl = _device.gl;
    for (final MeshPrimitive primitive in mesh.primitives) {
      for (final _Geometry item
          in _geometry.remove(primitive)?.values ?? const <_Geometry>[]) {
        gl
          ..deleteVertexArray(item.vao)
          ..deleteBuffer(item.vbo)
          ..deleteBuffer(item.ebo);
      }
      final MeshTexture? texture = primitive.material.baseColorTexture;
      final bool stillUsed = texture != null &&
          _geometry.keys.any((MeshPrimitive remaining) =>
              identical(remaining.material.baseColorTexture, texture));
      final web.WebGLTexture? object =
          texture == null || stillUsed ? null : _textures.remove(texture);
      if (object != null) {
        gl.deleteTexture(object);
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    final web.WebGL2RenderingContext gl = _device.gl;
    for (final Map<MeshShading, _Geometry> cache in _geometry.values) {
      for (final _Geometry item in cache.values) {
        gl
          ..deleteVertexArray(item.vao)
          ..deleteBuffer(item.vbo)
          ..deleteBuffer(item.ebo);
      }
    }
    _geometry.clear();
    for (final web.WebGLTexture texture in _textures.values) {
      gl.deleteTexture(texture);
    }
    _textures.clear();
    if (_depth != null) _device.gl.deleteRenderbuffer(_depth);
    _device.gl.deleteProgram(_program);
    _disposed = true;
  }

  static Object _compile(
      web.WebGL2RenderingContext gl, int type, String source) {
    final web.WebGLShader? shader = gl.createShader(type);
    if (shader == null) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'WebGL2 refused to create a mesh shader',
      );
    }
    gl
      ..shaderSource(shader, source)
      ..compileShader(shader);
    final JSAny? compiled = gl.getShaderParameter(
        shader, web.WebGL2RenderingContext.COMPILE_STATUS);
    if (compiled != null && (compiled as JSBoolean).toDart) return shader;
    final String log = gl.getShaderInfoLog(shader) ?? '';
    gl.deleteShader(shader);
    return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'WebGL2 mesh shader failed to compile',
        detail: log);
  }
}

final class _Geometry {
  const _Geometry(this.vao, this.vbo, this.ebo, this.count, this.mode);
  final web.WebGLVertexArrayObject vao;
  final web.WebGLBuffer vbo;
  final web.WebGLBuffer ebo;
  final int count;
  final int mode;
}

final class _Surface {
  const _Surface(
      this.owner, this.fbo, this.width, this.height, this.generation);
  final Object owner;
  final web.WebGLFramebuffer? fbo;
  final int width;
  final int height;
  final int generation;
}
