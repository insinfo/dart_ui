/// The per-frame vertex and index arena.
///
/// This is the display list's arena idea applied one stage later: the buffers
/// grow to the largest frame the process has drawn and are then reused
/// forever, so a steady-state frame allocates nothing here. [bufferGrowths] is
/// the observable proof, and a test asserts it stops increasing - the same
/// contract `DisplayList` and `ScanlineFiller` already carry.
///
/// That matters more on the GPU path than on the CPU one. A frame of a
/// scrolling list is tens of thousands of vertices; allocating a fresh
/// `Float32List` for them every 16 ms hands the collector a megabyte of
/// short-lived typed data per second, and typed-data allocation is exactly
/// what a generational collector is worst at hiding.
library;

import 'dart:typed_data';

import 'gpu_pipeline.dart';

/// Interleaved vertices plus 32-bit indices, appended to and reset per frame.
///
/// ## Winding
///
/// [addQuad] emits its four vertices as top-left, top-right, bottom-right,
/// bottom-left and indexes them `0,1,2, 0,2,3`. Device space has y growing
/// downward, so that order is clockwise on screen; after the projection flips
/// y into normalised device coordinates it becomes counter-clockwise, which is
/// the front face every API defaults to. Face culling is disabled anyway - a
/// 2D UI has no back faces to cull and enabling it only creates a way for a
/// projection sign error to make geometry vanish instead of appearing
/// mirrored, which is much harder to diagnose.
///
/// ## 32-bit indices
///
/// Not 16-bit. A single scrolling frame can pass 65 536 vertices, and the
/// alternative to a wide index is a batch break at an arbitrary vertex count,
/// which is a correctness-irrelevant reason to lose batching. The cost is a
/// requirement: desktop GL 2.0+ has `GL_UNSIGNED_INT` natively, GLES 2 needs
/// `OES_element_index_uint`. A backend without it must say so in its probe
/// rather than truncating.
final class GpuVertexBuffer {
  GpuVertexBuffer({int initialQuads = 256})
      : assert(initialQuads > 0),
        _vertices =
            Float32List(initialQuads * kGpuVerticesPerQuad * kGpuFloatsPerVertex),
        _indices = Uint32List(initialQuads * kGpuIndicesPerQuad);

  Float32List _vertices;
  Uint32List _indices;

  int _vertexCount = 0;
  int _indexCount = 0;
  int _growths = 0;

  /// Vertices written since the last [reset].
  int get vertexCount => _vertexCount;

  /// Indices written since the last [reset].
  int get indexCount => _indexCount;

  /// How many times a backing buffer was reallocated since construction.
  /// Across steady-state frames this must stop increasing.
  int get bufferGrowths => _growths;

  /// The whole backing store, including capacity past [vertexCount].
  ///
  /// Exposed rather than copied because the upload path wants to hand the
  /// driver a view of the first `vertexCount * kGpuFloatsPerVertex` floats
  /// without touching them. Nothing past that offset has meaning.
  Float32List get vertexStorage => _vertices;

  Uint32List get indexStorage => _indices;

  /// A view of exactly the floats written this frame.
  Float32List get vertices => Float32List.sublistView(
        _vertices,
        0,
        _vertexCount * kGpuFloatsPerVertex,
      );

  /// A view of exactly the indices written this frame.
  Uint32List get indices => Uint32List.sublistView(_indices, 0, _indexCount);

  /// Forgets the frame's contents while keeping the memory.
  void reset() {
    _vertexCount = 0;
    _indexCount = 0;
  }

  /// Reads one float of one vertex. For tests and diagnostics.
  double vertexFloat(int vertexIndex, int offset) =>
      _vertices[vertexIndex * kGpuFloatsPerVertex + offset];

  int indexAt(int index) => _indices[index];

  /// Appends one quad and returns the index of its first vertex.
  ///
  /// Every parameter is a `double` or an `int`, so a call allocates nothing:
  /// there is no rect object, no colour object and no vertex object between
  /// the caller and the typed array. That is the reason this signature is
  /// sixteen named arguments instead of four small value types.
  ///
  /// [left]..[bottom] are the quad's *geometry* - the pixels the rasteriser
  /// will visit. [shapeLeft]..[shapeBottom] are the exact, possibly
  /// fractional, shape the fragment stage computes coverage against. For a
  /// pixel-snapped quad around a fractional rect the two differ, and that
  /// difference is where antialiasing comes from; see [GpuPipelineKind.solid].
  int addQuad({
    required double left,
    required double top,
    required double right,
    required double bottom,
    required double u0,
    required double v0,
    required double u1,
    required double v1,
    required double red,
    required double green,
    required double blue,
    required double alpha,
    required double shapeLeft,
    required double shapeTop,
    required double shapeRight,
    required double shapeBottom,
  }) {
    _ensureCapacity();

    final base = _vertexCount;
    var o = base * kGpuFloatsPerVertex;
    final v = _vertices;

    // Top-left, top-right, bottom-right, bottom-left. Unrolled deliberately:
    // a loop over four corners needs a per-corner select of x and u, which is
    // two unpredictable-looking branches in the hottest function on the GPU
    // path.
    o = _writeVertex(v, o, left, top, u0, v0, red, green, blue, alpha,
        shapeLeft, shapeTop, shapeRight, shapeBottom);
    o = _writeVertex(v, o, right, top, u1, v0, red, green, blue, alpha,
        shapeLeft, shapeTop, shapeRight, shapeBottom);
    o = _writeVertex(v, o, right, bottom, u1, v1, red, green, blue, alpha,
        shapeLeft, shapeTop, shapeRight, shapeBottom);
    _writeVertex(v, o, left, bottom, u0, v1, red, green, blue, alpha, shapeLeft,
        shapeTop, shapeRight, shapeBottom);
    _vertexCount = base + kGpuVerticesPerQuad;

    final i = _indices;
    var k = _indexCount;
    i[k++] = base;
    i[k++] = base + 1;
    i[k++] = base + 2;
    i[k++] = base;
    i[k++] = base + 2;
    i[k++] = base + 3;
    _indexCount = k;

    return base;
  }

  static int _writeVertex(
    Float32List v,
    int offset,
    double x,
    double y,
    double u,
    double w,
    double red,
    double green,
    double blue,
    double alpha,
    double shapeLeft,
    double shapeTop,
    double shapeRight,
    double shapeBottom,
  ) {
    v[offset + kGpuPositionOffset] = x;
    v[offset + kGpuPositionOffset + 1] = y;
    v[offset + kGpuTexCoordOffset] = u;
    v[offset + kGpuTexCoordOffset + 1] = w;
    v[offset + kGpuColorOffset] = red;
    v[offset + kGpuColorOffset + 1] = green;
    v[offset + kGpuColorOffset + 2] = blue;
    v[offset + kGpuColorOffset + 3] = alpha;
    v[offset + kGpuShapeRectOffset] = shapeLeft;
    v[offset + kGpuShapeRectOffset + 1] = shapeTop;
    v[offset + kGpuShapeRectOffset + 2] = shapeRight;
    v[offset + kGpuShapeRectOffset + 3] = shapeBottom;
    return offset + kGpuFloatsPerVertex;
  }

  void _ensureCapacity() {
    final neededFloats =
        (_vertexCount + kGpuVerticesPerQuad) * kGpuFloatsPerVertex;
    if (neededFloats > _vertices.length) {
      final grown = Float32List(_vertices.length * 2);
      grown.setRange(0, _vertexCount * kGpuFloatsPerVertex, _vertices);
      _vertices = grown;
      _growths++;
    }
    final neededIndices = _indexCount + kGpuIndicesPerQuad;
    if (neededIndices > _indices.length) {
      final grown = Uint32List(_indices.length * 2);
      grown.setRange(0, _indexCount, _indices);
      _indices = grown;
      _growths++;
    }
  }
}
