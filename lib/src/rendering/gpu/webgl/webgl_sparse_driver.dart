/// Production [SparseGlDriver] over a `WebGL2RenderingContext`.
///
/// ## Why this implements the *GL* contract rather than a web one
///
/// WebGL2 is GLES 3.0. `gl_sparse_strips.dart` already emits the GLES dialect
/// of the sparse shader - `#version 300 es`, explicit precision, explicit
/// attribute locations - and `SparseGlSubmission` next to it already turns a
/// [SparseStripDrawPlan] into the instances and ordered commands that shader
/// consumes. Neither contains a single GL call. So the browser needs no second
/// shader, no second encoder and no second executor: it needs an *adapter*,
/// which is this file, and `SparseGlExecutor` drives it unchanged.
///
/// That is the same argument `webgl_backend.dart` makes at length for
/// importing `gl_shaders.dart` instead of copying it, and it matters more here
/// than there. The coverage in a sparse strip is the antialiasing; a browser
/// copy that drifted from the desktop source would make the two backends draw
/// different edges from the same [SparseStripDrawPlan], and the difference
/// would read as a driver bug rather than as the divergence it was.
///
/// The three entry points GL needs to look up dynamically -
/// `glVertexAttribDivisor`, `glDrawArraysInstanced`, `glUniform4f` - are core
/// methods on a `WebGL2RenderingContext`, so there is no probe here and no
/// "missing symbol" failure mode: a context that exists supports instancing.
///
/// ## `dart:ffi` must never appear
///
/// Same rule, same reason, same enforcement as `webgl_backend.dart`. This
/// library is reachable from the web compilation fixture, and
/// `test/backends/web/web_compilation_test.dart` runs `dart2js` and
/// `dart2wasm` over it. `gl_sparse_strips.dart` imports only `dart:typed_data`
/// and the backend-neutral plan, which is what makes importing it from a
/// browser library legal at all.
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../gl/gl_sparse_executor.dart';
import '../gl/gl_sparse_strips.dart';
import '../gpu_gradient.dart';
import '../gpu_pipeline.dart';
import '../gpu_texture.dart';
import 'webgl_backend.dart';

/// Maps the narrow, fakeable sparse contract to a real WebGL2 context.
///
/// Object identity is the browser's problem as always: WebGL hands back
/// JavaScript objects and the contract speaks integers, so this keeps its own
/// small numbering for the program and the instance buffer and borrows the
/// device's [WebGlRenderDevice.textures] table for alpha pages - borrowed, not
/// duplicated, because a gradient material names its LUT with an id from that
/// same table and two tables would hand out the same integer twice.
final class WebGlSparseDriver implements SparseGlDriver {
  WebGlSparseDriver(this._device);

  final WebGlRenderDevice _device;

  web.WebGL2RenderingContext get _gl => _device.gl;

  web.WebGLProgram? _program;
  web.WebGLVertexArrayObject? _vao;
  web.WebGLBuffer? _buffer;
  final Map<int, WebGlTexture> _pages = <int, WebGlTexture>{};

  /// One texel each, bound to units 0 and 1 at the top of every pass.
  ///
  /// Not decoration, and the bug they prevent is worth stating because it is
  /// invisible from the Dart side. A solid interior samples neither the alpha
  /// atlas nor the gradient LUT, so the executor never binds anything for it -
  /// and whatever the *previous* GL call left bound to unit 0 stays bound. On
  /// an offscreen target the last thing bound is very often that target's own
  /// colour texture, which is also the current framebuffer's attachment: a
  /// texture that is simultaneously sampled and rendered into is a feedback
  /// loop, and WebGL2 answers a whole `drawArraysInstanced` with
  /// `INVALID_OPERATION` rather than drawing it. Chrome does exactly that, and
  /// the failure looks like a shader bug: the alpha-carrying draws in the same
  /// suite succeed, because binding a page happens to break the loop.
  ///
  /// The atlas stand-in is zero, so a mode that read it by mistake draws
  /// nothing rather than a full-coverage rectangle; the LUT stand-in is opaque
  /// white for the reason `webgpu_backend.dart` gives about its own dummy - a
  /// gradient routed here by a bug shows as unmodulated colour, not black.
  WebGlTexture? _standInAtlas;
  WebGlTexture? _standInLut;

  web.WebGLUniformLocation? _viewport;
  web.WebGLUniformLocation? _yFlip;
  web.WebGLUniformLocation? _color;
  web.WebGLUniformLocation? _mode;
  web.WebGLUniformLocation? _alphaAtlas;
  web.WebGLUniformLocation? _paintMode;
  web.WebGLUniformLocation? _gradientLut;
  web.WebGLUniformLocation? _gradientKind;
  web.WebGLUniformLocation? _gradientSpread;
  web.WebGLUniformLocation? _gradientLookup;
  web.WebGLUniformLocation? _targetToLocal0;
  web.WebGLUniformLocation? _targetToLocal1;
  web.WebGLUniformLocation? _gradientGeometry0;
  web.WebGLUniformLocation? _gradientGeometry1;

  /// The handles this driver hands out. Never zero: the executor reads zero as
  /// "the context refused", which is what a lost WebGL2 context answers for
  /// every object it is asked to make.
  static const int _programHandle = 1;
  static const int _bufferHandle = 2;

  @override
  int createSparseProgram({
    required String vertexSource,
    required String fragmentSource,
  }) {
    final web.WebGLShader? vertex = _compile(
      web.WebGL2RenderingContext.VERTEX_SHADER,
      vertexSource,
    );
    if (vertex == null) return 0;
    final web.WebGLShader? fragment = _compile(
      web.WebGL2RenderingContext.FRAGMENT_SHADER,
      fragmentSource,
    );
    if (fragment == null) {
      _gl.deleteShader(vertex);
      return 0;
    }
    final web.WebGLProgram? program = _gl.createProgram();
    if (program == null) {
      _gl
        ..deleteShader(vertex)
        ..deleteShader(fragment);
      return 0;
    }
    // No bindAttribLocation: the sparse GLSL declares
    // `layout(location = ...)` in both dialects, and GLSL ES 3.00 honours it.
    _gl
      ..attachShader(program, vertex)
      ..attachShader(program, fragment)
      ..linkProgram(program)
      ..deleteShader(vertex)
      ..deleteShader(fragment);
    final JSAny? linkStatus = _gl.getProgramParameter(
      program,
      web.WebGL2RenderingContext.LINK_STATUS,
    );
    if (linkStatus == null || !(linkStatus as JSBoolean).toDart) {
      final String log = _gl.getProgramInfoLog(program) ?? '';
      _gl.deleteProgram(program);
      throw StateError('the sparse WebGL2 program failed to link: $log');
    }

    _program = program;
    _viewport = _gl.getUniformLocation(program, 'uViewport');
    _yFlip = _gl.getUniformLocation(program, 'uYFlip');
    _color = _gl.getUniformLocation(program, 'uColor');
    _mode = _gl.getUniformLocation(program, 'uMode');
    _alphaAtlas = _gl.getUniformLocation(program, 'uAlphaAtlas');
    _paintMode = _gl.getUniformLocation(program, 'uPaintMode');
    _gradientLut = _gl.getUniformLocation(program, 'uGradientLut');
    _gradientKind = _gl.getUniformLocation(program, 'uGradientKind');
    _gradientSpread = _gl.getUniformLocation(program, 'uGradientSpread');
    _gradientLookup = _gl.getUniformLocation(program, 'uGradientLookup');
    _targetToLocal0 = _gl.getUniformLocation(program, 'uTargetToLocal0');
    _targetToLocal1 = _gl.getUniformLocation(program, 'uTargetToLocal1');
    _gradientGeometry0 = _gl.getUniformLocation(program, 'uGradientGeometry0');
    _gradientGeometry1 = _gl.getUniformLocation(program, 'uGradientGeometry1');
    if (<web.WebGLUniformLocation?>[
      _viewport,
      _yFlip,
      _color,
      _mode,
      _alphaAtlas,
      _paintMode,
      _gradientLut,
      _gradientKind,
      _gradientSpread,
      _gradientLookup,
      _targetToLocal0,
      _targetToLocal1,
      _gradientGeometry0,
      _gradientGeometry1,
    ].any((web.WebGLUniformLocation? location) => location == null)) {
      _gl.deleteProgram(program);
      _forgetProgram();
      throw StateError(
        'the sparse WebGL2 program is missing a required uniform, which means '
        'the shader source and gl_sparse_strips.dart have drifted apart',
      );
    }
    return _programHandle;
  }

  @override
  void deleteProgram(int program) {
    if (program != _programHandle) return;
    final web.WebGLProgram? object = _program;
    if (object != null && !_gl.isContextLost()) _gl.deleteProgram(object);
    // The executor deletes its pages and its buffer explicitly; the stand-ins
    // are this driver's own and have no other owner to release them.
    _releaseStandIns();
    _forgetProgram();
  }

  @override
  int createInstanceBuffer() {
    final web.WebGLVertexArrayObject? vao = _gl.createVertexArray();
    if (vao == null) return 0;
    final web.WebGLBuffer? buffer = _gl.createBuffer();
    if (buffer == null) {
      _gl.deleteVertexArray(vao);
      return 0;
    }
    _vao = vao;
    _buffer = buffer;
    _gl
      ..bindVertexArray(vao)
      ..bindBuffer(web.WebGL2RenderingContext.ARRAY_BUFFER, buffer)
      // The dense renderer owns another VAO and expects to find it bound; the
      // attribute state this one accumulates must not leak into it.
      ..bindVertexArray(null);
    return _bufferHandle;
  }

  @override
  void deleteBuffer(int buffer) {
    if (buffer != _bufferHandle) return;
    if (!_gl.isContextLost()) {
      if (_buffer != null) _gl.deleteBuffer(_buffer);
      if (_vao != null) _gl.deleteVertexArray(_vao);
    }
    _buffer = null;
    _vao = null;
  }

  @override
  int createAlpha8Texture({required int width, required int height}) {
    // Through the device rather than the context: it already creates an R8
    // texture with nearest filtering, clamped wrap and an unpack alignment of
    // one - which is exactly an alpha page - and it registers the object in
    // the numbering a gradient LUT is named by.
    final WebGlTexture texture = _device.createTexture(
      width: width,
      height: height,
      format: GpuTextureFormat.alpha8,
    );
    _pages[texture.id] = texture;
    return texture.id;
  }

  @override
  void deleteTexture(int texture) {
    final WebGlTexture? page = _pages.remove(texture);
    if (page == null) return;
    _device.releaseTexture(page);
  }

  @override
  void uploadInstances(int buffer, Float32List instances) {
    if (buffer != _bufferHandle || _buffer == null || _vao == null) {
      throw StateError('sparse WebGL2 objects do not belong to this driver');
    }
    _gl
      ..bindVertexArray(_vao)
      ..bindBuffer(web.WebGL2RenderingContext.ARRAY_BUFFER, _buffer)
      ..bufferData(
        web.WebGL2RenderingContext.ARRAY_BUFFER,
        // A view of exactly the frame's instances: the arena is retained at
        // its high-water mark and uploading the slack would send stale floats
        // to the driver every frame.
        instances.toJS,
        web.WebGL2RenderingContext.DYNAMIC_DRAW,
      );
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
    final WebGlTexture? page = _pages[texture];
    if (page == null) {
      throw StateError('unknown sparse WebGL2 alpha page $texture');
    }
    // `uploadRegion` repacks the rows itself and invalidates the dense draw
    // state's cached texture binding, which is the thing a sparse upload
    // between two dense batches would otherwise silently break.
    _device.uploadRegion(
      page,
      x: x,
      y: y,
      width: width,
      height: height,
      pixels: Uint8List.sublistView(pixels, sourceOffset),
      bytesPerRow: sourceBytesPerRow,
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
    if (program != _programHandle ||
        instanceBuffer != _bufferHandle ||
        _program == null ||
        _vao == null) {
      throw StateError('sparse WebGL2 objects do not belong to this driver');
    }
    _ensureStandIns();
    _gl
      ..useProgram(_program)
      ..bindVertexArray(_vao)
      ..bindBuffer(web.WebGL2RenderingContext.ARRAY_BUFFER, _buffer)
      // Units 1 then 0, so the pass starts with unit 0 selected - the unit
      // `bindAlpha8Texture` writes to and the one every other path here
      // assumes. See [_standInAtlas] for what these prevent.
      ..activeTexture(web.WebGL2RenderingContext.TEXTURE1)
      ..bindTexture(
        web.WebGL2RenderingContext.TEXTURE_2D,
        _standInLut?.object,
      )
      ..activeTexture(web.WebGL2RenderingContext.TEXTURE0)
      ..bindTexture(
        web.WebGL2RenderingContext.TEXTURE_2D,
        _standInAtlas?.object,
      )
      ..uniform2f(
        _viewport,
        viewportWidth.toDouble(),
        viewportHeight.toDouble(),
      )
      ..uniform1i(_yFlip, yFlip)
      ..uniform1i(_alphaAtlas, 0)
      ..uniform1i(_gradientLut, 1)
      ..enable(web.WebGL2RenderingContext.BLEND);
  }

  @override
  void setBlendState(GpuBlendState blend) => _gl.blendFunc(
        _factor(blend.source),
        _factor(blend.destination),
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
  void useSolidPaint() => _gl.uniform1i(_paintMode, kSparseGlPaintSolid);

  @override
  void useGradientPaint(
    GpuGradientBinding binding,
    GpuGradientShaderParameters parameters,
  ) {
    final Float32List scalars = parameters.scalars;
    const int transform = GpuGradientUniformOffset.targetToLocal;
    const int geometry = GpuGradientUniformOffset.geometry;
    // The LUT lives in the device's numbering, not this driver's: it was
    // created by `GpuGradientCache` through the device as a texture allocator.
    final web.WebGLTexture? lut = _device.textures.lookup(binding.texture.id);
    _gl
      ..uniform1i(_paintMode, kSparseGlPaintGradient)
      ..uniform1i(
        _gradientKind,
        scalars[GpuGradientUniformOffset.kind].toInt(),
      )
      ..uniform1i(_gradientSpread, binding.spread.index)
      ..uniform2f(_gradientLookup, binding.lookupScale, binding.lookupBias)
      ..uniform4f(
        _targetToLocal0,
        scalars[transform],
        scalars[transform + 2],
        scalars[transform + 4],
        0,
      )
      ..uniform4f(
        _targetToLocal1,
        scalars[transform + 1],
        scalars[transform + 3],
        scalars[transform + 5],
        0,
      )
      ..uniform4f(
        _gradientGeometry0,
        scalars[geometry],
        scalars[geometry + 1],
        scalars[geometry + 2],
        scalars[geometry + 3],
      )
      ..uniform4f(
        _gradientGeometry1,
        scalars[geometry + 4],
        scalars[geometry + 5],
        scalars[geometry + 6],
        scalars[geometry + 7],
      )
      ..activeTexture(web.WebGL2RenderingContext.TEXTURE1)
      ..bindTexture(web.WebGL2RenderingContext.TEXTURE_2D, lut);
  }

  @override
  void setSparseMode(int mode) => _gl.uniform1i(_mode, mode);

  @override
  void bindAlpha8Texture(int texture) {
    final WebGlTexture? page = _pages[texture];
    if (page == null) {
      throw StateError('unknown sparse WebGL2 alpha page $texture');
    }
    _gl
      ..activeTexture(web.WebGL2RenderingContext.TEXTURE0)
      ..bindTexture(web.WebGL2RenderingContext.TEXTURE_2D, page.object);
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
        web.WebGL2RenderingContext.FLOAT,
        false,
        strideBytes,
        offsetBytes,
      )
      ..vertexAttribDivisor(location, divisor);
  }

  @override
  void drawTriangleStripInstanced({
    required int vertexCount,
    required int instanceCount,
  }) =>
      _gl.drawArraysInstanced(
        web.WebGL2RenderingContext.TRIANGLE_STRIP,
        0,
        vertexCount,
        instanceCount,
      );

  @override
  void endSparsePass() {
    // The dense renderer owns another VAO and rebinds its own program at the
    // top of every submission, but it does *not* rebind the active texture
    // unit, so leaving unit 1 selected would send its first upload to the
    // wrong unit.
    _gl
      ..bindVertexArray(null)
      ..activeTexture(web.WebGL2RenderingContext.TEXTURE0)
      ..useProgram(null);
  }

  @override
  void discardNativeResources() {
    // A lost context already reclaimed all of these. Nothing is deleted: the
    // handles refer to objects the browser has thrown away, and every delete
    // on a lost context is a defined no-op anyway.
    _buffer = null;
    _vao = null;
    _pages.clear();
    _standInAtlas = null;
    _standInLut = null;
    _forgetProgram();
  }

  /// Creates the one-texel stand-ins, once per device generation.
  void _ensureStandIns() {
    if (_standInAtlas != null && _standInLut != null) return;
    final WebGlTexture atlas = _standInAtlas ??= _device.createTexture(
      width: 1,
      height: 1,
      format: GpuTextureFormat.alpha8,
    );
    final WebGlTexture lut = _standInLut ??= _device.createTexture(
      width: 1,
      height: 1,
      format: GpuTextureFormat.rgba8888Straight,
    );
    _device
      ..uploadRegion(
        atlas,
        x: 0,
        y: 0,
        width: 1,
        height: 1,
        pixels: Uint8List(1),
        bytesPerRow: 1,
      )
      ..uploadRegion(
        lut,
        x: 0,
        y: 0,
        width: 1,
        height: 1,
        pixels: Uint8List.fromList(const <int>[0xFF, 0xFF, 0xFF, 0xFF]),
        bytesPerRow: 4,
      );
  }

  void _releaseStandIns() {
    final WebGlTexture? atlas = _standInAtlas;
    final WebGlTexture? lut = _standInLut;
    _standInAtlas = null;
    _standInLut = null;
    if (_gl.isContextLost()) return;
    if (atlas != null) _device.releaseTexture(atlas);
    if (lut != null) _device.releaseTexture(lut);
  }

  web.WebGLShader? _compile(int type, String source) {
    final web.WebGLShader? shader = _gl.createShader(type);
    if (shader == null) return null;
    _gl
      ..shaderSource(shader, source)
      ..compileShader(shader);
    final JSAny? compileStatus = _gl.getShaderParameter(
      shader,
      web.WebGL2RenderingContext.COMPILE_STATUS,
    );
    if (compileStatus != null && (compileStatus as JSBoolean).toDart) {
      return shader;
    }
    final String log = _gl.getShaderInfoLog(shader) ?? '';
    _gl.deleteShader(shader);
    throw StateError(
      'the sparse WebGL2 ${type == web.WebGL2RenderingContext.VERTEX_SHADER ? 'vertex' : 'fragment'} shader failed to compile: $log',
    );
  }

  void _forgetProgram() {
    _program = null;
    _viewport = null;
    _yFlip = null;
    _color = null;
    _mode = null;
    _alphaAtlas = null;
    _paintMode = null;
    _gradientLut = null;
    _gradientKind = null;
    _gradientSpread = null;
    _gradientLookup = null;
    _targetToLocal0 = null;
    _targetToLocal1 = null;
    _gradientGeometry0 = null;
    _gradientGeometry1 = null;
  }

  static int _factor(GpuBlendFactor factor) => switch (factor) {
        GpuBlendFactor.zero => web.WebGL2RenderingContext.ZERO,
        GpuBlendFactor.one => web.WebGL2RenderingContext.ONE,
        GpuBlendFactor.oneMinusSrcAlpha =>
          web.WebGL2RenderingContext.ONE_MINUS_SRC_ALPHA,
      };
}
