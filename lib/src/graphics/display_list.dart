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

import 'content_hint.dart';
import 'display_list_opcodes.dart';
import 'glyph_text.dart';
import 'gradient.dart';

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
        _paintFloats = Float32List(initialPaintCapacity + 1),
        _paintWidthBits = _noBits,
        _paintSlots = Uint32List(_slotCountFor(initialPaintCapacity)) {
    _paintWidthBits = Uint32List.view(_paintFloats.buffer);
    _paintSlotMask = _paintSlots.length - 1;
  }

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

  /// The bit patterns of [_paintFloats], aliasing the same storage.
  ///
  /// A stroke width is already narrowed to float32 the moment it is stored,
  /// so its 32 bits *are* the value the renderer will see. Reading them as an
  /// integer gives the dedup key without boxing and without a second
  /// conversion, and keeps hash and comparison working on exactly the stored
  /// value - quantisation included - which is the property [addPaint]
  /// depends on. Rebuilt whenever [_paintFloats] is reallocated.
  Uint32List _paintWidthBits;

  /// Paint id + 1 per slot, 0 meaning empty: an open-addressed index from a
  /// paint key to its id, probed linearly.
  ///
  /// A `Map<int, List<int>>` of hash buckets is the obvious spelling and the
  /// wrong one here: it allocates a bucket list per distinct hash and a map
  /// node per entry, and [reset] drops all of them, so a frame with a
  /// hundred-odd distinct paints turned over tens of kilobytes per frame for
  /// a table that is rebuilt identically every time. A flat typed table
  /// allocates nothing in steady state and [reset] becomes a fill.
  ///
  /// Sized by [_slotCountFor] to twice the paint capacity, so the load factor
  /// never passes 1/2. That bound is what lets the probe loop in [addPaint]
  /// run without an emptiness guard: the table can never be full.
  Uint32List _paintSlots;
  int _paintSlotMask = 0;

  /// Placeholder for [_paintWidthBits] in the initialiser list, which cannot
  /// see the `_paintFloats` it must alias. The constructor body replaces it
  /// before anything can read it, and it is shared, so it costs one empty
  /// list for the whole program rather than one per display list.
  static final Uint32List _noBits = Uint32List(0);

  // Content hints. See [pushContentHint] for why they are a side table and
  // not an opcode.
  Uint32List _hintStarts = Uint32List(4);
  Uint32List _hintValues = Uint32List(4);
  int _hintSpanCount = 0;
  Uint32List _hintStack = Uint32List(8);
  int _hintDepth = 0;
  ContentHintSpans? _hintView;

  /// Where [recordGlyphText] sends the text behind a glyph run.
  ///
  /// The `const` disabled capture, so a list that is never asked to capture
  /// holds one shared object for the whole program and allocates nothing per
  /// frame. See [capturesGlyphText] and `glyph_text.dart`.
  GlyphTextCapture _glyphText = GlyphTextCapture.disabled;

  final List<Object> _paths = <Object>[];
  final Map<Object, int> _pathIds = <Object, int>{};

  final List<Object> _images = <Object>[];
  final Map<Object, int> _imageIds = <Object, int>{};

  final List<Object> _fonts = <Object>[];
  final Map<Object, int> _fontIds = <Object, int>{};

  /// Gradient table: interned [Gradient] objects, referenced from a paint's
  /// flag word. Objects rather than flat arrays because a frame holds a
  /// handful of gradients where it holds thousands of paints - the same trade
  /// the path and image tables made, argued in `gradient.dart`.
  final List<Gradient> _gradients = <Gradient>[];
  final Map<Gradient, int> _gradientIds = <Gradient, int>{};

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

  int get fontCount => _fonts.length;

  int get gradientCount => _gradients.length;

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
    if (_paintCount != 0) {
      _paintCount = 0;
      _paintSlots.fillRange(0, _paintSlots.length, 0);
    }
    _paths.clear();
    _pathIds.clear();
    _images.clear();
    _imageIds.clear();
    _fonts.clear();
    _fontIds.clear();
    _gradients.clear();
    _gradientIds.clear();
    _hintSpanCount = 0;
    _hintDepth = 0;
    _glyphText.reset();
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
  ///
  /// [gradient] turns the paint into a gradient fill: the [Gradient] is
  /// interned by value in the gradient table, its kind and id are packed into
  /// the flag word (bits 4..5 and 16..31), and the paint dedup then works
  /// unchanged because two equal gradients share one id and therefore one
  /// flag word. When a gradient is set the paint's [colorArgb] is **not
  /// sampled** - the stop colours carry the alpha; see `gradient.dart`. The
  /// solid path pays exactly one null test for this parameter.
  int addPaint({
    required int colorArgb,
    int style = paintStyleFill,
    double strokeWidth = 0.0,
    int blendMode = blendModeSrcOver,
    bool antiAlias = true,
    int fillRule = pathFillRuleNonZero,
    Gradient? gradient,
  }) {
    if (style < 0 || style >= kPaintStyleCount) {
      throw ArgumentError.value(style, 'style', 'unknown paint style');
    }
    if (blendMode < 0 || blendMode >= kBlendModeCount) {
      throw ArgumentError.value(blendMode, 'blendMode', 'unknown blend mode');
    }
    if (fillRule < 0 || fillRule >= kPathFillRuleCount) {
      throw ArgumentError.value(fillRule, 'fillRule', 'unknown path fill rule');
    }
    _ensurePaintCapacity(_paintCount + 1);

    var shaderBits = 0;
    if (gradient != null) {
      final int gradientId = _internGradient(gradient);
      shaderBits = ((gradient.shaderKind & 0x3) << 4) | (gradientId << 16);
    }
    final int flags = (style & 0x3) |
        (antiAlias ? 0x4 : 0x0) |
        ((fillRule & 0x1) << 3) |
        ((blendMode & 0xFF) << 8) |
        shaderBits;
    final int base = _paintCount * 2;
    // Written before the lookup so the comparison runs against the exact
    // values that would be stored, quantisation included.
    _paintInts[base] = colorArgb;
    _paintInts[base + 1] = flags;
    _paintFloats[_paintCount] = strokeWidth;

    final int storedColor = _paintInts[base];
    final int storedFlags = _paintInts[base + 1];
    var storedWidth = _paintWidthBits[_paintCount];
    if (storedWidth == 0x80000000) {
      // -0.0. It is `==` to 0.0 and strokes identically, and the old
      // `==`-based comparison already collapsed the two, so the bit-pattern
      // key has to as well. Normalising the *stored* slot rather than only
      // the key keeps one representation in the buffer.
      storedWidth = 0;
      _paintWidthBits[_paintCount] = 0;
    } else if ((storedWidth & 0x7FFFFFFF) > 0x7F800000) {
      // NaN. `==` is false for it, so the old comparison never matched and
      // every NaN-width paint interned a fresh id - a leak in a table that is
      // supposed to be bounded by the palette. Collapsing every NaN onto one
      // canonical quiet NaN makes the dedup total: two paints intern to one
      // id iff their colour and flag words are equal and their widths are
      // either `==` or both NaN.
      storedWidth = 0x7FC00000;
      _paintWidthBits[_paintCount] = 0x7FC00000;
    }

    final int mask = _paintSlotMask;
    var slot = _hashPaint(storedColor, storedFlags, storedWidth) & mask;
    while (true) {
      final int entry = _paintSlots[slot];
      if (entry == 0) {
        _paintSlots[slot] = _paintCount + 1;
        return _paintCount++;
      }
      // The full key is compared, never the hash, so a probe collision can
      // only cost one more step - it can never merge two different paints.
      final int candidate = entry - 1;
      final int candidateBase = candidate * 2;
      if (_paintInts[candidateBase] == storedColor &&
          _paintInts[candidateBase + 1] == storedFlags &&
          _paintWidthBits[candidate] == storedWidth) {
        return candidate;
      }
      slot = (slot + 1) & mask;
    }
  }

  /// Hash of a stored paint key, over the three 32-bit words themselves.
  ///
  /// Deliberately not `Object.hash`: its parameters are `Object?`, so the
  /// float32 stroke width was boxed on every call - one allocation per
  /// encoded paint, dedup hit or not.
  ///
  /// The words are folded one at a time rather than xored together first,
  /// because a colour's low byte and a flag word live in the same numeric
  /// range: `colour ^ flags` would make (colour, flags) and
  /// (colour ^ d, flags ^ d) collide for small `d`, which is exactly the
  /// pattern a palette produces. The trailing rounds are a finaliser: the
  /// table indexes on the low bits, and a stroke width differs from its
  /// neighbours mostly in the float32 exponent, up at bits 23..30.
  ///
  /// Arithmetic is kept inside 32 bits, and the multiplies are split into
  /// 16-bit halves by [_mul32], because this library is compiled for the web
  /// too, where an `int` is a double and a 64-bit product would silently lose
  /// its low bits.
  static int _hashPaint(int color, int flags, int widthBits) {
    var h = _mul32(color, 0xCC9E2D51);
    h = _mul32(h ^ flags, 0x1B873593);
    h = _mul32(h ^ widthBits, 0x85EBCA6B);
    h ^= h >>> 15;
    h = _mul32(h, 0xC2B2AE35);
    return h ^ (h >>> 16);
  }

  /// The low 32 bits of `a * b`, exact on a 53-bit double as well as on a
  /// 64-bit integer: each partial product stays under 2^48.
  static int _mul32(int a, int b) {
    final int low = (a & 0xFFFF) * b;
    final int high = ((a >>> 16) * b) & 0xFFFF;
    return (low + high * 0x10000) & 0xFFFFFFFF;
  }

  /// Slot count for a paint capacity: a power of two at least twice the
  /// capacity, never below 16.
  static int _slotCountFor(int capacity) {
    var slots = 16;
    while (slots < capacity * 2) {
      slots *= 2;
    }
    return slots;
  }

  int paintColor(int id) => _paintInts[_checkPaint(id) * 2];

  int paintStyle(int id) => _paintInts[_checkPaint(id) * 2 + 1] & 0x3;

  bool paintAntiAlias(int id) =>
      (_paintInts[_checkPaint(id) * 2 + 1] & 0x4) != 0;

  int paintFillRule(int id) => (_paintInts[_checkPaint(id) * 2 + 1] >> 3) & 0x1;

  int paintBlendMode(int id) =>
      (_paintInts[_checkPaint(id) * 2 + 1] >> 8) & 0xFF;

  double paintStrokeWidth(int id) => _paintFloats[_checkPaint(id)];

  /// One of `shaderKindSolid`, `shaderKindLinear`, `shaderKindRadial` from
  /// `gradient.dart`. Bits 4..5 of the flag word.
  int paintShaderKind(int id) =>
      (_paintInts[_checkPaint(id) * 2 + 1] >> 4) & 0x3;

  /// The gradient table id of a non-solid paint. Only meaningful when
  /// [paintShaderKind] is not solid; a solid paint reports 0.
  int paintGradientId(int id) =>
      (_paintInts[_checkPaint(id) * 2 + 1] >> 16) & 0xFFFF;

  /// The [Gradient] behind [id]'s paint, or null for a solid paint. This is
  /// the accessor replay code reads; the id-level pair above exists for wire
  /// round-trip tests.
  Gradient? paintGradient(int id) => paintShaderKind(id) == shaderKindSolid
      ? null
      : _gradients[paintGradientId(id)];

  Gradient gradientAt(int id) => _gradients[id];

  int _internGradient(Gradient gradient) {
    final int? existing = _gradientIds[gradient];
    if (existing != null) return existing;
    if (_gradients.length >= kMaxGradientsPerList) {
      throw StateError(
          'too many gradients in one display list ($kMaxGradientsPerList); '
          'the paint flag word carries a 16-bit gradient id');
    }
    final int id = _gradients.length;
    _gradients.add(gradient);
    _gradientIds[gradient] = id;
    return id;
  }

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

  /// Interns the font a [drawGlyphRun] draws with, and returns its id.
  ///
  /// ## Why the size is in the id and not in the opcode
  ///
  /// A `fontId` names a *face at a size*, not a face. The opcode carries no
  /// size operand, and this is the design rather than an omission.
  ///
  /// The alternative was a float operand holding the pixel size. It loses on
  /// three counts. First, a glyph run is the output of a shaper, and a shaper
  /// shapes *at a size*: the glyph ids it chose, the offsets it computed and
  /// the size it did both at are one indivisible decision, so splitting the
  /// size back out invites a run whose offsets and size disagree - text that
  /// is subtly mis-spaced with nothing in the stream saying so. Second, the
  /// glyph offsets in the float stream are device-space coordinates and the
  /// float buffer is documented as carrying exactly that; a pixel size is not
  /// a coordinate, and its presence would move every offset by one slot, so
  /// [glyphRunFloatSlots] and every reader of it would change to encode
  /// something the reader can already reach through the resource table.
  /// Third, and decisive: the renderer needs a *scaled* face to rasterize -
  /// metrics and outlines at that size - so a size operand would only be a
  /// number it has to pair back up with a face before it can do anything. The
  /// id already is that pair.
  ///
  /// Equality follows the same rule as [addPath]: the resource's own `==`.
  /// Two draws sharing one face-at-size object share an id, which is what lets
  /// a frame of body text intern one font and a glyph cache key off it.
  int addFont(Object font) => _intern(font, _fonts, _fontIds);

  Object pathAt(int id) => _paths[id];

  Object imageAt(int id) => _images[id];

  Object fontAt(int id) => _fonts[id];

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
  // Content hints
  // ---------------------------------------------------------------------

  /// The hint side table, for a replayer that wants to read it.
  ///
  /// One object for the life of the list rather than one per frame, because
  /// [reset] keeps the arena and so does this.
  ContentHintSpans get contentHints =>
      _hintView ??= _DisplayListContentHints(this);

  /// True when anything was ever declared. The cheap test a replayer uses to
  /// skip hint bookkeeping altogether.
  bool get hasContentHints => _hintSpanCount > 0;

  /// Open push/pop pairs. Exposed so a caller can assert its own balance;
  /// [reset] returns it to zero.
  int get contentHintDepth => _hintDepth;

  /// Declares [hint] over every command encoded until the matching
  /// [popContentHint].
  ///
  /// ## Why this is not an opcode
  ///
  /// It was the first design and it is the wrong one. An opcode pair would
  /// change the wire format, which means a reader change, a debug-dump change
  /// and - decisively - a new method on `RasterSink`, an
  /// `abstract interface class` that six sinks in this repository implement.
  /// Every one of them would have to acquire a body for a command that says
  /// nothing about pixels.
  ///
  /// Worse, it would put advice *in* the stream that defines the picture. The
  /// contract in `content_hint.dart` is that a wrong hint can never change the
  /// image, and the strongest possible form of that promise is that the bytes
  /// which describe the image do not move: the op and float streams a hinted
  /// subtree produces are identical, word for word, to the ones it produces
  /// unhinted. A side table gives that by construction rather than by
  /// discipline, and `test/graphics/content_hint_test.dart` asserts it.
  ///
  /// The table is a run-length encoding over word offsets: each entry is the
  /// op-stream offset at which a hint took effect, and it stays in effect
  /// until the next entry. A pair that encloses no commands, or that repeats
  /// the value already in force, records nothing at all - so a tree full of
  /// hints around empty subtrees still leaves `hasContentHints` false.
  ///
  /// Nesting resolves per field through [ContentHint.inheritFrom]: an inner
  /// declaration overrides the outer one where it says something and inherits
  /// it where it does not.
  void pushContentHint(ContentHint hint) {
    final ContentHint merged = _hintDepth == 0
        ? hint
        : hint.inheritFrom(ContentHint.unpack(_hintStack[_hintDepth - 1]));
    if (_hintDepth == _hintStack.length) {
      final Uint32List grown = Uint32List(_hintStack.length * 2);
      grown.setRange(0, _hintDepth, _hintStack);
      _hintStack = grown;
      _bufferGrowths++;
    }
    _hintStack[_hintDepth++] = merged.packed;
    _recordHint(merged.packed);
  }

  /// Closes the innermost [pushContentHint].
  ///
  /// Throws [StateError] on an unbalanced pop: a hint that leaked past its
  /// subtree would advise the rest of the frame, and the symptom - some
  /// unrelated widget picking a strange route - is a long way from the cause.
  void popContentHint() {
    if (_hintDepth == 0) {
      throw StateError('popContentHint without a matching pushContentHint');
    }
    _hintDepth--;
    _recordHint(_hintDepth == 0 ? 0 : _hintStack[_hintDepth - 1]);
  }

  void _recordHint(int packed) {
    // A span that would start where the previous one starts covers no
    // commands: overwrite instead of appending, so a push/pop pair around an
    // empty subtree leaves no trace.
    if (_hintSpanCount > 0 && _hintStarts[_hintSpanCount - 1] == _opLength) {
      _hintValues[_hintSpanCount - 1] = packed;
      final int previous =
          _hintSpanCount > 1 ? _hintValues[_hintSpanCount - 2] : 0;
      if (previous == packed) _hintSpanCount--;
      return;
    }
    if (_hintSpanCount == 0
        ? packed == 0
        : _hintValues[_hintSpanCount - 1] == packed) {
      return;
    }
    if (_hintSpanCount == _hintStarts.length) {
      final Uint32List starts = Uint32List(_hintStarts.length * 2);
      final Uint32List values = Uint32List(_hintValues.length * 2);
      starts.setRange(0, _hintSpanCount, _hintStarts);
      values.setRange(0, _hintSpanCount, _hintValues);
      _hintStarts = starts;
      _hintValues = values;
      _bufferGrowths++;
    }
    _hintStarts[_hintSpanCount] = _opLength;
    _hintValues[_hintSpanCount] = packed;
    _hintSpanCount++;
  }

  // ---------------------------------------------------------------------
  // Glyph text
  // ---------------------------------------------------------------------

  /// Whether [recordGlyphText] keeps anything.
  ///
  /// False by default and free when false: the capture is the `const`
  /// singleton from `glyph_text.dart`, so an untouched list allocates nothing
  /// for this and [recordGlyphText] is a call with an empty body rather than a
  /// branch. Only a backend that turns characters back into characters - the
  /// DOM presenter - sets it, and it sets it on the list it is handed, so the
  /// first frame after it is chosen still falls back.
  ///
  /// Setting it back to false drops the table. Setting it to the value it
  /// already has does nothing, so a presenter can assert it every frame.
  bool get capturesGlyphText => _glyphText.isRecording;

  set capturesGlyphText(bool value) {
    if (value == _glyphText.isRecording) return;
    _glyphText =
        value ? GlyphTextCapture.recording() : GlyphTextCapture.disabled;
  }

  /// The text side table, for a replayer that wants to read it.
  ///
  /// [GlyphTextSpans.empty] while [capturesGlyphText] is false, which is the
  /// same const instance every time.
  GlyphTextSpans get glyphTexts => _glyphText.spans;

  /// Records that the **next** command appended draws the glyphs of
  /// `text.substring(start, end)`.
  ///
  /// Next, not last, so that the offset recorded is [opLength] exactly as
  /// [_recordHint] uses it - a caller pairs this immediately before its
  /// [drawGlyphRun] and the two cannot drift apart.
  ///
  /// [text] is retained by reference. The string is one the widget tree
  /// already built and `GlyphRunCache` already keys on, so recording it costs
  /// a pointer and no characters.
  void recordGlyphText(String text, int start, int end) =>
      _glyphText.record(_opLength, text, start, end);

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
  /// [fontId] comes from [addFont] and names a face at a size; see there for
  /// why no size travels in the operands.
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
  // Splicing
  // ---------------------------------------------------------------------

  /// Scratch id maps used by [appendFrom], one per resource table.
  ///
  /// Kept across calls and across [reset] for the same reason the command
  /// buffers are: a boundary that splices a cached sub-list does it every
  /// frame, and allocating four typed lists per splice would put an allocation
  /// per repaint boundary per frame back on the exact path section 6.5 says
  /// must not have one. They grow to the widest sub-list ever spliced and stay
  /// there. Lazily created, so a program that never splices pays four null
  /// fields.
  Uint32List? _splicePaintMap;
  Uint32List? _splicePathMap;
  Uint32List? _spliceImageMap;
  Uint32List? _spliceFontMap;

  /// Appends every command of [other] to this list, rewriting its resource ids
  /// into this list's tables.
  ///
  /// This is the primitive a retained sub-list is replayed through: a repaint
  /// boundary records its subtree once into a private [DisplayList] and, on a
  /// frame where nothing under it changed, splices those words here instead of
  /// walking the subtree again. See `RenderBox.paintFromParent`.
  ///
  /// ## Why the ids have to be rewritten and the floats do not
  ///
  /// An id in the operand stream indexes the resource tables of *the list that
  /// produced it* - the format says so, and that is the whole reason an
  /// encoded list is self-contained. Paint, path, image and font ids are dense
  /// per-list indices, so a raw copy of [other]'s words into this list would
  /// point every draw at whatever resource happens to sit at that index here:
  /// the wrong colour, the wrong glyph face, or a [RangeError] when the index
  /// is past the end.
  ///
  /// The maps below are built by re-adding [other]'s tables in id order, which
  /// is exactly what a direct walk would have done. Interning dedups, and
  /// dedup is order-preserving and idempotent, so an id that already exists
  /// here collapses onto it and a new one lands at the same index a direct
  /// walk would have given it. Re-adding the *whole* table rather than only
  /// the ids the commands mention is deliberate: a resource that was interned
  /// and then not drawn still consumed an id in [other], and skipping it would
  /// shift every later id by one against the direct walk. That property - that
  /// a spliced frame is word-for-word the frame a walk produces - is the only
  /// evidence that a repaint boundary is an optimisation and not a rendering
  /// change, and `test/layout/repaint_boundary_cache_test.dart` asserts it.
  ///
  /// The floats need none of that. Every float slot in the format is a
  /// coordinate, a radius or a glyph offset, and none of them is an index into
  /// anything, so they are copied with one bulk [setRange]. Nothing here
  /// translates them either: shifting a sub-list to a new position would mean
  /// knowing, per opcode, which floats are positions and which are extents,
  /// and a mistake in that table is a silent geometry bug rather than a loud
  /// one. A caller that needs the sub-list somewhere else wraps the splice in
  /// [save]/[transform]/[restore] and records the sub-list in its own local
  /// space, which is what [RenderBox] does.
  ///
  /// Throws when [other] carries content hints. A hint span is an op-stream
  /// offset plus a packed value that *already has its enclosing hints merged
  /// into it* - see [pushContentHint] - so replaying spans recorded with no
  /// enclosing hint into a stream where one is in force would silently drop
  /// the outer declaration, and the sub-list would be advised differently from
  /// the way the same subtree is advised when it is walked. Rather than merge
  /// the two stacks and hope, this refuses; the caller declines to cache that
  /// subtree at all.
  void appendFrom(DisplayList other) {
    if (identical(other, this)) {
      throw ArgumentError.value(
        other,
        'other',
        'a display list cannot be spliced into itself; the read cursor would '
            'chase the write cursor forever',
      );
    }
    if (other._hintSpanCount != 0) {
      throw StateError(
        'cannot splice a display list that carries content hints: a hint span '
        'records the value already merged with its enclosing hints, so '
        'replaying it here would drop whatever hint is in force at the splice '
        'point',
      );
    }
    if (other._hintDepth != 0) {
      throw StateError(
        'cannot splice a display list with ${other._hintDepth} unbalanced '
        'pushContentHint; finish the recording first',
      );
    }
    if (other._opLength == 0) return;

    final Uint32List paintMap =
        _spliceMap(_splicePaintTable, other._paintCount);
    for (var id = 0; id < other._paintCount; id++) {
      paintMap[id] = addPaint(
        colorArgb: other.paintColor(id),
        style: other.paintStyle(id),
        strokeWidth: other.paintStrokeWidth(id),
        blendMode: other.paintBlendMode(id),
        antiAlias: other.paintAntiAlias(id),
        fillRule: other.paintFillRule(id),
        gradient: other.paintGradient(id),
      );
    }
    final Uint32List pathMap =
        _spliceMap(_splicePathTable, other._paths.length);
    for (var id = 0; id < other._paths.length; id++) {
      pathMap[id] = addPath(other._paths[id]);
    }
    final Uint32List imageMap =
        _spliceMap(_spliceImageTable, other._images.length);
    for (var id = 0; id < other._images.length; id++) {
      imageMap[id] = addImage(other._images[id]);
    }
    final Uint32List fontMap =
        _spliceMap(_spliceFontTable, other._fonts.length);
    for (var id = 0; id < other._fonts.length; id++) {
      fontMap[id] = addFont(other._fonts[id]);
    }

    // One bulk copy rather than a slot at a time: the float stream carries no
    // framing of its own, so a command's floats are simply wherever the
    // running cursor left off, and appending the whole run keeps the relative
    // order every header already describes.
    _ensureFloats(other._floatLength);
    _floats.setRange(
      _floatLength,
      _floatLength + other._floatLength,
      other._floats,
    );
    _floatLength += other._floatLength;

    _ensureOps(other._opLength);
    // Every op offset in `other` shifts by exactly this, because the words
    // below are appended in order and none is added or dropped. That is what
    // lets the glyph-text spans be replayed rather than refused the way
    // content hints are: a text span carries no inherited state, so shifting
    // its offset is the whole of the translation.
    final int opBase = _opLength;
    final Uint32List source = other._ops;
    var read = 0;
    while (read < other._opLength) {
      final int header = source[read];
      final int opcode = headerOpcode(header);
      final int intSlots = headerIntSlots(header);
      final int operands = read + 1;
      _ops[_opLength++] = header;
      switch (opcode) {
        case opSave:
        case opRestore:
        case opTransform:
          break;
        case opSaveLayer:
        case opDrawRect:
        case opDrawRRect:
          _ops[_opLength++] = paintMap[source[operands]];
        case opClipRect:
          // The lone operand is a clip op, not an id.
          _ops[_opLength++] = source[operands];
        case opClipPath:
          _ops[_opLength++] = pathMap[source[operands]];
          _ops[_opLength++] = source[operands + 1];
        case opDrawPath:
          _ops[_opLength++] = pathMap[source[operands]];
          _ops[_opLength++] = paintMap[source[operands + 1]];
        case opDrawImage:
          _ops[_opLength++] = imageMap[source[operands]];
          _ops[_opLength++] = paintMap[source[operands + 1]];
        case opDrawGlyphRun:
          _ops[_opLength++] = fontMap[source[operands]];
          _ops[_opLength++] = paintMap[source[operands + 1]];
          // The glyph count and the ids behind it are values, not resource
          // ids: a glyph id names a glyph inside the face the fontId already
          // resolved, so remapping one would draw a different letter.
          for (var i = 2; i < intSlots; i++) {
            _ops[_opLength++] = source[operands + i];
          }
        default:
          throw DisplayListFormatException(
            'unknown opcode ${opcodeName(opcode)} while splicing',
            wordOffset: read,
          );
      }
      read = operands + intSlots;
    }
    _commandCount += other._commandCount;

    // Free when neither list captures: `spanCount` is zero on the const empty
    // table, so the common splice does one integer comparison.
    final GlyphTextSpans texts = other.glyphTexts;
    for (var i = 0; i < texts.spanCount; i++) {
      _glyphText.record(
        opBase + texts.spanStart(i),
        texts.spanText(i),
        texts.spanTextStart(i),
        texts.spanTextEnd(i),
      );
    }
  }

  static const int _splicePaintTable = 0;
  static const int _splicePathTable = 1;
  static const int _spliceImageTable = 2;
  static const int _spliceFontTable = 3;

  /// The scratch id map for resource table [which], at least [length] long.
  Uint32List _spliceMap(int which, int length) {
    final Uint32List? existing = switch (which) {
      _splicePaintTable => _splicePaintMap,
      _splicePathTable => _splicePathMap,
      _spliceImageTable => _spliceImageMap,
      _ => _spliceFontMap,
    };
    if (existing != null && existing.length >= length) return existing;
    final Uint32List grown =
        Uint32List(_grownCapacity(existing?.length ?? 0, length));
    switch (which) {
      case _splicePaintTable:
        _splicePaintMap = grown;
      case _splicePathTable:
        _splicePathMap = grown;
      case _spliceImageTable:
        _spliceImageMap = grown;
      default:
        _spliceFontMap = grown;
    }
    return grown;
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
    _paintWidthBits = Uint32List.view(grownFloats.buffer);
    _bufferGrowths++;

    // The index is keyed by hash modulo its size, so growing it is a rehash,
    // not a copy. It is O(paints) and happens only on a doubling, so it is
    // amortised away exactly like the buffer copies above.
    final int slots = _slotCountFor(capacity);
    if (slots == _paintSlots.length) return;
    _paintSlots = Uint32List(slots);
    _paintSlotMask = slots - 1;
    for (var id = 0; id < _paintCount; id++) {
      final int idBase = id * 2;
      var slot = _hashPaint(
            _paintInts[idBase],
            _paintInts[idBase + 1],
            _paintWidthBits[id],
          ) &
          _paintSlotMask;
      while (_paintSlots[slot] != 0) {
        slot = (slot + 1) & _paintSlotMask;
      }
      _paintSlots[slot] = id + 1;
    }
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

/// The [ContentHintSpans] face of a [DisplayList].
///
/// Separate from the list so that the two accessors a replayer needs do not
/// become two more names on the encoder's own surface, which is already the
/// widest type in `graphics`.
final class _DisplayListContentHints implements ContentHintSpans {
  const _DisplayListContentHints(this._list);

  final DisplayList _list;

  @override
  int get spanCount => _list._hintSpanCount;

  @override
  int spanStart(int index) => _list._hintStarts[_check(index)];

  @override
  ContentHint spanHint(int index) =>
      ContentHint.unpack(_list._hintValues[_check(index)]);

  int _check(int index) {
    if (index < 0 || index >= _list._hintSpanCount) {
      throw RangeError.index(
        index,
        this,
        'index',
        'no such hint span',
        _list._hintSpanCount,
      );
    }
    return index;
  }
}
