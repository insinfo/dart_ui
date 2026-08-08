/// The display list encoder, per section 9.6 of the roadmap.
///
/// The wire format is specified in `display_list_opcodes.dart`; this file is
/// the writer for it. Two rules shape everything here:
///
///   * section 6.5 forbids allocation on the command-serialisation path, so
///     no method below builds a Dart object per command. Commands are words
///     appended to two typed buffers, and every encoding method takes
///     primitives;
///   * the buffers are an arena. [reset] rewinds the write cursors and keeps
///     the storage, so a steady-state frame allocates nothing at all - the
///     buffers reach the high-water mark of a few frames and stay there.
///
/// ## Why `Float32List` is enough for coordinates
///
/// The values stored here are device-space coordinates, produced after the
/// layout and transform stack have already been composed in `double`. Their
/// magnitude is bounded by the surface, and no realistic surface exceeds
/// 65536 device pixels on a side. Float32 has a 24-bit mantissa, so at 65536
/// the representable step is about 0.0039 px - an order of magnitude finer
/// than the 1/256 px subpixel grid a rasteriser can act on, and finer still
/// than anything a display can show. Float64 would double the bandwidth of
/// the hottest buffer in the frame to carry precision that nothing
/// downstream consumes. Composition of transforms still happens in `double`
/// above this layer; only the final device-space result is narrowed.
///
/// TODO(geometry): once `lib/src/geometry/` lands with `Offset`, `Size`,
/// `Rect` and `Transform2D`, add a thin geometry-typed convenience layer on
/// top of this class (an extension or a wrapper) that unpacks those values
/// into the primitive calls below. It must stay a layer *on top*: the
/// primitive entry points are what the frame pipeline calls, because passing
/// a `Rect` per command would reintroduce the per-command object this file
/// exists to avoid.
library;

import 'dart:typed_data';

import 'display_list_opcodes.dart';

/// Builder and owner of an encoded display list.
///
/// A [DisplayList] is normally long-lived: one per frame producer, reset at
/// the start of every frame rather than reallocated.
final class DisplayList {
  DisplayList({
    int initialOpCapacity = 1024,
    int initialFloatCapacity = 2048,
    int initialPaintCapacity = 32,
  })  : assert(initialOpCapacity > 0),
        assert(initialFloatCapacity > 0),
        assert(initialPaintCapacity > 0),
        _ops = Uint32List(initialOpCapacity),
        _floats = Float32List(initialFloatCapacity),
        _paintInts = Uint32List(initialPaintCapacity * 2),
        _paintFloats = Float32List(initialPaintCapacity + 1);

  Uint32List _ops;
  int _opLength = 0;

  Float32List _floats;
  int _floatLength = 0;

  int _commandCount = 0;
  int _bufferGrowths = 0;

  // Paints are stored flat, two words and one float each, so that adding one
  // costs no object either. Slot `_paintCount` of `_paintFloats` doubles as
  // the scratch slot used to narrow a candidate stroke width before
  // comparing it - which is why that buffer is one slot longer than the
  // paint capacity.
  Uint32List _paintInts;
  Float32List _paintFloats;
  int _paintCount = 0;

  /// Candidate paint ids grouped by hash. A bucket list is allocated only the
  /// first time a hash is seen, so a frame that reuses last frame's palette
  /// pays nothing after the first few commands.
  final Map<int, List<int>> _paintBuckets = <int, List<int>>{};

  final List<Object> _paths = <Object>[];
  final Map<Object, int> _pathIds = <Object, int>{};

  final List<Object> _images = <Object>[];
  final Map<Object, int> _imageIds = <Object, int>{};

  /// Backing store of the word stream. Only the first [opLength] words are
  /// meaningful; the rest is arena capacity.
  Uint32List get opBuffer => _ops;

  int get opLength => _opLength;

  /// Backing store of the coordinate stream. Only the first [floatLength]
  /// slots are meaningful.
  Float32List get floatBuffer => _floats;

  int get floatLength => _floatLength;

  int get commandCount => _commandCount;

  int get opCapacity => _ops.length;

  int get floatCapacity => _floats.length;

  /// How many times a buffer has been reallocated since construction.
  ///
  /// Exposed because it is the observable proof that the arena works: across
  /// steady-state frames this must stop increasing.
  int get bufferGrowths => _bufferGrowths;

  int get paintCount => _paintCount;

  int get pathCount => _paths.length;

  int get imageCount => _images.length;

  /// Rewinds the write cursors and drops the resource tables, keeping every
  /// buffer.
  ///
  /// Resource ids are frame-local: they are dropped here because their
  /// meaning depends on tables that are being rebuilt. A cache that outlives
  /// a frame belongs to the layer that knows a texture's or a path's
  /// lifetime, not to the arena.
  void reset() {
    _opLength = 0;
    _floatLength = 0;
    _commandCount = 0;
    _paintCount = 0;
    _paintBuckets.clear();
    _paths.clear();
    _pathIds.clear();
    _images.clear();
    _imageIds.clear();
  }

  // ---------------------------------------------------------------------
  // Resources
  // ---------------------------------------------------------------------

  /// Interns a paint and returns its id.
  ///
  /// Equality is decided on the *stored* representation: the masked colour
  /// and flag words plus the stroke width after narrowing to float32. Two
  /// paints that differ only below float32 precision therefore collapse to
  /// one id, which is correct - the renderer can never see a difference the
  /// buffer cannot hold. Nothing about the caller's object identity matters.
  int addPaint({
    required int colorArgb,
    int style = paintStyleFill,
    double strokeWidth = 0.0,
    int blendMode = blendModeSrcOver,
    bool antiAlias = true,
  }) {
    if (style < 0 || style >= kPaintStyleCount) {
      throw ArgumentError.value(style, 'style', 'unknown paint style');
    }
    if (blendMode < 0 || blendMode >= kBlendModeCount) {
      throw ArgumentError.value(blendMode, 'blendMode', 'unknown blend mode');
    }
    _ensurePaintCapacity(_paintCount + 1);

    final int flags =
        (style & 0x3) | (antiAlias ? 0x4 : 0x0) | ((blendMode & 0xFF) << 8);
    final int base = _paintCount * 2;
    // Written before the lookup so the comparison runs against the exact
    // values that would be stored, quantisation included.
    _paintInts[base] = colorArgb;
    _paintInts[base + 1] = flags;
    _paintFloats[_paintCount] = strokeWidth;

    final int storedColor = _paintInts[base];
    final double storedWidth = _paintFloats[_paintCount];
    final int hash = Object.hash(storedColor, flags, storedWidth);

    final List<int>? bucket = _paintBuckets[hash];
    if (bucket != null) {
      for (var i = 0; i < bucket.length; i++) {
        final int candidate = bucket[i];
        final int candidateBase = candidate * 2;
        if (_paintInts[candidateBase] == storedColor &&
            _paintInts[candidateBase + 1] == flags &&
            _paintFloats[candidate] == storedWidth) {
          return candidate;
        }
      }
      bucket.add(_paintCount);
    } else {
      _paintBuckets[hash] = <int>[_paintCount];
    }
    return _paintCount++;
  }

  int paintColor(int id) => _paintInts[_checkPaint(id) * 2];

  int paintStyle(int id) => _paintInts[_checkPaint(id) * 2 + 1] & 0x3;

  bool paintAntiAlias(int id) =>
      (_paintInts[_checkPaint(id) * 2 + 1] & 0x4) != 0;

  int paintBlendMode(int id) =>
      (_paintInts[_checkPaint(id) * 2 + 1] >> 8) & 0xFF;

  double paintStrokeWidth(int id) => _paintFloats[_checkPaint(id)];

  /// Interns a path and returns its id.
  ///
  /// Equality is delegated to the resource's own `==` and `hashCode`. For a
  /// mutable path builder that means identity, which is the honest answer:
  /// comparing path contents would be O(n) on every draw call. A path
  /// implementation that wants content dedup opts in by defining value
  /// equality - and then must not be mutated after being added, because its
  /// id is already in the stream.
  int addPath(Object path) => _intern(path, _paths, _pathIds);

  /// Interns an image. Equality follows the same rule as [addPath].
  int addImage(Object image) => _intern(image, _images, _imageIds);

  Object pathAt(int id) => _paths[id];

  Object imageAt(int id) => _images[id];

  int _intern(Object resource, List<Object> table, Map<Object, int> ids) {
    final int? existing = ids[resource];
    if (existing != null) return existing;
    final int id = table.length;
    table.add(resource);
    ids[resource] = id;
    return id;
  }

  int _checkPaint(int id) {
    if (id < 0 || id >= _paintCount) {
      throw RangeError.index(id, this, 'paintId', 'no such paint', _paintCount);
    }
    return id;
  }

  // ---------------------------------------------------------------------
  // Commands
  // ---------------------------------------------------------------------

  void save() {
    _ensureOps(1);
    _ops[_opLength++] = encodeHeader(opSave, 0, 0);
    _commandCount++;
  }

  void saveLayer(
    double left,
    double top,
    double right,
    double bottom,
    int paintId,
  ) {
    _ensureOps(2);
    _ensureFloats(4);
    _ops[_opLength++] = encodeHeader(opSaveLayer, 1, 4);
    _ops[_opLength++] = paintId;
    _writeRect(left, top, right, bottom);
    _commandCount++;
  }

  void restore() {
    _ensureOps(1);
    _ops[_opLength++] = encodeHeader(opRestore, 0, 0);
    _commandCount++;
  }

  /// Concatenates a 2D affine matrix; see the operand table in
  /// `display_list_opcodes.dart` for the component order.
  void transform(
    double a,
    double b,
    double c,
    double d,
    double tx,
    double ty,
  ) {
    _ensureOps(1);
    _ensureFloats(6);
    _ops[_opLength++] = encodeHeader(opTransform, 0, 6);
    _floats[_floatLength++] = a;
    _floats[_floatLength++] = b;
    _floats[_floatLength++] = c;
    _floats[_floatLength++] = d;
    _floats[_floatLength++] = tx;
    _floats[_floatLength++] = ty;
    _commandCount++;
  }

  void clipRect(
    double left,
    double top,
    double right,
    double bottom, {
    int op = clipOpIntersect,
  }) {
    _checkClipOp(op);
    _ensureOps(2);
    _ensureFloats(4);
    _ops[_opLength++] = encodeHeader(opClipRect, 1, 4);
    _ops[_opLength++] = op;
    _writeRect(left, top, right, bottom);
    _commandCount++;
  }

  void clipPath(int pathId, {int op = clipOpIntersect}) {
    _checkClipOp(op);
    _ensureOps(3);
    _ops[_opLength++] = encodeHeader(opClipPath, 2, 0);
    _ops[_opLength++] = pathId;
    _ops[_opLength++] = op;
    _commandCount++;
  }

  void drawRect(
    double left,
    double top,
    double right,
    double bottom,
    int paintId,
  ) {
    _ensureOps(2);
    _ensureFloats(4);
    _ops[_opLength++] = encodeHeader(opDrawRect, 1, 4);
    _ops[_opLength++] = paintId;
    _writeRect(left, top, right, bottom);
    _commandCount++;
  }

  /// Rounded rectangle with independent corner radii.
  ///
  /// Twelve positional doubles rather than a radii object, for the reason the
  /// whole file exists.
  void drawRRect(
    double left,
    double top,
    double right,
    double bottom,
    double radiusTopLeftX,
    double radiusTopLeftY,
    double radiusTopRightX,
    double radiusTopRightY,
    double radiusBottomRightX,
    double radiusBottomRightY,
    double radiusBottomLeftX,
    double radiusBottomLeftY,
    int paintId,
  ) {
    _ensureOps(2);
    _ensureFloats(12);
    _ops[_opLength++] = encodeHeader(opDrawRRect, 1, 12);
    _ops[_opLength++] = paintId;
    _writeRect(left, top, right, bottom);
    _floats[_floatLength++] = radiusTopLeftX;
    _floats[_floatLength++] = radiusTopLeftY;
    _floats[_floatLength++] = radiusTopRightX;
    _floats[_floatLength++] = radiusTopRightY;
    _floats[_floatLength++] = radiusBottomRightX;
    _floats[_floatLength++] = radiusBottomRightY;
    _floats[_floatLength++] = radiusBottomLeftX;
    _floats[_floatLength++] = radiusBottomLeftY;
    _commandCount++;
  }

  /// The common case of [drawRRect] where all four corners share a radius.
  void drawRRectUniform(
    double left,
    double top,
    double right,
    double bottom,
    double radiusX,
    double radiusY,
    int paintId,
  ) {
    drawRRect(
      left,
      top,
      right,
      bottom,
      radiusX,
      radiusY,
      radiusX,
      radiusY,
      radiusX,
      radiusY,
      radiusX,
      radiusY,
      paintId,
    );
  }

  void drawPath(int pathId, int paintId) {
    _ensureOps(3);
    _ops[_opLength++] = encodeHeader(opDrawPath, 2, 0);
    _ops[_opLength++] = pathId;
    _ops[_opLength++] = paintId;
    _commandCount++;
  }

  void drawImage(
    int imageId,
    double srcLeft,
    double srcTop,
    double srcRight,
    double srcBottom,
    double dstLeft,
    double dstTop,
    double dstRight,
    double dstBottom,
    int paintId,
  ) {
    _ensureOps(3);
    _ensureFloats(8);
    _ops[_opLength++] = encodeHeader(opDrawImage, 2, 8);
    _ops[_opLength++] = imageId;
    _ops[_opLength++] = paintId;
    _writeRect(srcLeft, srcTop, srcRight, srcBottom);
    _writeRect(dstLeft, dstTop, dstRight, dstBottom);
    _commandCount++;
  }

  /// Appends a shaped run.
  ///
  /// [glyphIds] and [glyphOffsets] are borrowed, not retained: their contents
  /// are copied into the arena, so the shaper can keep reusing one scratch
  /// pair of buffers for every run in the frame. [glyphOffsets] holds
  /// `2 * glyphCount` values, x then y, relative to the run origin.
  void drawGlyphRun(
    int fontId,
    int paintId,
    double originX,
    double originY,
    Int32List glyphIds,
    Float32List glyphOffsets,
    int glyphCount,
  ) {
    if (glyphCount < 0 || glyphCount > kMaxGlyphsPerRun) {
      throw ArgumentError.value(
        glyphCount,
        'glyphCount',
        'must be in 0..$kMaxGlyphsPerRun; split longer text into runs',
      );
    }
    if (glyphIds.length < glyphCount) {
      throw ArgumentError.value(
        glyphIds.length,
        'glyphIds.length',
        'shorter than glyphCount ($glyphCount)',
      );
    }
    if (glyphOffsets.length < glyphCount * 2) {
      throw ArgumentError.value(
        glyphOffsets.length,
        'glyphOffsets.length',
        'needs $glyphCount x/y pairs',
      );
    }

    final int intSlots = glyphRunIntSlots(glyphCount);
    final int floatSlots = glyphRunFloatSlots(glyphCount);
    _ensureOps(1 + intSlots);
    _ensureFloats(floatSlots);
    _ops[_opLength++] = encodeHeader(opDrawGlyphRun, intSlots, floatSlots);
    _ops[_opLength++] = fontId;
    _ops[_opLength++] = paintId;
    _ops[_opLength++] = glyphCount;
    for (var i = 0; i < glyphCount; i++) {
      _ops[_opLength++] = glyphIds[i];
    }
    _floats[_floatLength++] = originX;
    _floats[_floatLength++] = originY;
    final int offsetCount = glyphCount * 2;
    for (var i = 0; i < offsetCount; i++) {
      _floats[_floatLength++] = glyphOffsets[i];
    }
    _commandCount++;
  }

  // ---------------------------------------------------------------------
  // Arena
  // ---------------------------------------------------------------------

  void _writeRect(double left, double top, double right, double bottom) {
    _floats[_floatLength++] = left;
    _floats[_floatLength++] = top;
    _floats[_floatLength++] = right;
    _floats[_floatLength++] = bottom;
  }

  void _checkClipOp(int op) {
    if (op < 0 || op >= kClipOpCount) {
      throw ArgumentError.value(op, 'op', 'unknown clip operation');
    }
  }

  void _ensureOps(int extra) {
    final int needed = _opLength + extra;
    if (needed <= _ops.length) return;
    final Uint32List grown = Uint32List(_grownCapacity(_ops.length, needed));
    grown.setRange(0, _opLength, _ops);
    _ops = grown;
    _bufferGrowths++;
  }

  void _ensureFloats(int extra) {
    final int needed = _floatLength + extra;
    if (needed <= _floats.length) return;
    final Float32List grown = Float32List(
      _grownCapacity(_floats.length, needed),
    );
    grown.setRange(0, _floatLength, _floats);
    _floats = grown;
    _bufferGrowths++;
  }

  void _ensurePaintCapacity(int count) {
    // One spare float slot is always kept for the dedup scratch write.
    if (count * 2 <= _paintInts.length && count < _paintFloats.length) {
      return;
    }
    final int capacity = _grownCapacity(_paintInts.length ~/ 2, count);
    final Uint32List grownInts = Uint32List(capacity * 2);
    grownInts.setRange(0, _paintCount * 2, _paintInts);
    _paintInts = grownInts;
    final Float32List grownFloats = Float32List(capacity + 1);
    grownFloats.setRange(0, _paintCount, _paintFloats);
    _paintFloats = grownFloats;
    _bufferGrowths++;
  }

  /// Doubling, so that appending n items costs O(n) copies in total and the
  /// buffer settles after a handful of frames instead of reallocating per
  /// command.
  static int _grownCapacity(int current, int needed) {
    var capacity = current < 16 ? 16 : current;
    while (capacity < needed) {
      capacity *= 2;
    }
    return capacity;
  }
}
