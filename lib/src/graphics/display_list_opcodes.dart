/// Wire format of the encoded display list, per section 9.6 of the roadmap.
///
/// The display list has to survive being handed to another isolate, written
/// to a golden file, or replayed by a backend that never saw the widget tree.
/// So the format is defined here, in one place, precisely enough to be
/// reimplemented from this comment alone.
///
/// ## Buffers
///
/// An encoded list is two parallel buffers plus two lengths:
///
///   * `opBuffer`    `Uint32List`, `opLength` words in use;
///   * `floatBuffer` `Float32List`, `floatLength` slots in use.
///
/// Everything past the length is scratch capacity owned by the arena and has
/// no meaning.
///
/// ## Command framing
///
/// The word stream is a flat sequence of commands. One command is
///
///     word 0        header
///     word 1..N     N integer operands, N = intSlots
///
/// and additionally consumes `floatSlots` slots from the float stream. The
/// float stream carries no framing of its own: a reader keeps a float cursor
/// that starts at 0 and only ever moves forward by the `floatSlots` of each
/// command it has already read. Splitting coordinates out of the word stream
/// keeps them contiguous and 4-byte aligned for the rasteriser, and keeps the
/// word stream small enough to stay in cache while walking commands.
///
/// ## Header layout
///
///     bits  0..7    opcode
///     bits  8..17   intSlots   (0..1023, header word not counted)
///     bits 18..27   floatSlots (0..1023)
///     bits 28..31   marker, always [kHeaderMarker]
///
/// The marker and the two slot counts are what make the stream
/// self-describing. A reader that lands on a word that is not a header - a
/// truncated buffer, a wrong length, an operand mistaken for an opcode - sees
/// a wrong marker, an unknown opcode, or a slot count that disagrees with the
/// table below, and fails. It never reinterprets operand data as a command
/// and drifts on silently, which is the failure mode that makes a corrupt
/// display list expensive to debug.
///
/// ## Operands per opcode
///
/// | opcode          | int operands              | float operands           |
/// |-----------------|---------------------------|--------------------------|
/// | [opSave]        | -                         | -                        |
/// | [opSaveLayer]   | paintId                   | l, t, r, b               |
/// | [opRestore]     | -                         | -                        |
/// | [opTransform]   | -                         | a, b, c, d, tx, ty       |
/// | [opClipRect]    | clipOp                    | l, t, r, b               |
/// | [opClipPath]    | pathId, clipOp            | -                        |
/// | [opDrawRect]    | paintId                   | l, t, r, b               |
/// | [opDrawRRect]   | paintId                   | l, t, r, b + 8 radii     |
/// | [opDrawPath]    | pathId, paintId           | -                        |
/// | [opDrawImage]   | imageId, paintId          | 4 src + 4 dst            |
/// | [opDrawGlyphRun]| fontId, paintId, n, ids.. | originX, originY, n * xy |
///
/// [opTransform] carries a 2D affine matrix in the column order
/// `a, b, c, d, tx, ty`, mapping `(x, y)` to `(a*x + c*y + tx,
/// b*x + d*y + ty)`.
///
/// [opDrawRRect] radii follow the bounds in the order top-left x/y,
/// top-right x/y, bottom-right x/y, bottom-left x/y.
///
/// [opDrawGlyphRun] carries no pixel size, and must not grow one: its `fontId`
/// resolves to a face *at a size*, because the ids, the offsets and the size a
/// shaper produced are one decision and a stream that can express them
/// separately can express them disagreeing. See `DisplayList.addFont`.
///
/// [opDrawGlyphRun] is the only variable-arity opcode. Its third integer
/// operand is the glyph count `n`, followed by `n` glyph ids; its float
/// operands are the run origin followed by `n` (x, y) offsets relative to
/// that origin. A reader must check that the declared slot counts agree with
/// the embedded `n` - see [glyphRunIntSlots] and [glyphRunFloatSlots] -
/// because for this opcode the table alone cannot pin them down.
///
/// ## Resources
///
/// Ids in the operand stream index the resource tables of the display list
/// that produced it. Ids are dense, start at 0, and are only meaningful
/// together with those tables.
library;

/// Nibble stamped into the top of every header word.
///
/// Chosen to be non-zero so that zeroed or freshly allocated memory never
/// reads as a valid command.
const int kHeaderMarker = 0xD;

/// Widest slot count a header can express, from the 10-bit fields.
const int kMaxSlots = 1023;

/// Glyphs a single [opDrawGlyphRun] can carry.
///
/// Bounded by the float field: `2 + 2 * n <= kMaxSlots`. Longer text is split
/// into several runs, which the shaper has to be able to do anyway for font
/// fallback and bidi.
const int kMaxGlyphsPerRun = 510;

/// Never encoded. Reserved so that 0 is not a legal opcode.
const int opInvalid = 0;

const int opSave = 1;
const int opSaveLayer = 2;
const int opRestore = 3;
const int opTransform = 4;
const int opClipRect = 5;
const int opClipPath = 6;
const int opDrawRect = 7;
const int opDrawRRect = 8;
const int opDrawPath = 9;
const int opDrawImage = 10;
const int opDrawGlyphRun = 11;

/// One past the highest legal opcode.
const int kOpcodeCount = 12;

/// Slot count that depends on the operands themselves, not on the opcode.
const int kVariableSlots = -1;

const List<int> _intSlotTable = <int>[
  0, // opInvalid
  0, // opSave
  1, // opSaveLayer
  0, // opRestore
  0, // opTransform
  1, // opClipRect
  2, // opClipPath
  1, // opDrawRect
  1, // opDrawRRect
  2, // opDrawPath
  2, // opDrawImage
  kVariableSlots, // opDrawGlyphRun
];

const List<int> _floatSlotTable = <int>[
  0, // opInvalid
  0, // opSave
  4, // opSaveLayer
  0, // opRestore
  6, // opTransform
  4, // opClipRect
  0, // opClipPath
  4, // opDrawRect
  12, // opDrawRRect
  0, // opDrawPath
  8, // opDrawImage
  kVariableSlots, // opDrawGlyphRun
];

const List<String> _opcodeNames = <String>[
  'invalid',
  'save',
  'saveLayer',
  'restore',
  'transform',
  'clipRect',
  'clipPath',
  'drawRect',
  'drawRRect',
  'drawPath',
  'drawImage',
  'drawGlyphRun',
];

/// Clip operations, encoded as an integer operand rather than an enum so the
/// encoder stays on primitives all the way down.
const int clipOpIntersect = 0;
const int clipOpDifference = 1;
const int kClipOpCount = 2;

const int paintStyleFill = 0;
const int paintStyleStroke = 1;
const int paintStyleFillAndStroke = 2;
const int kPaintStyleCount = 3;

/// Path fill rule, carried in bit 3 of a paint's flag word.
const int pathFillRuleNonZero = 0;
const int pathFillRuleEvenOdd = 1;
const int kPathFillRuleCount = 2;

/// Porter-Duff equations on premultiplied colour, carried in bits 8..15 of a
/// paint's flag word.
///
/// Each one is exactly a fixed-function blend - a source factor times the
/// fragment plus a destination factor times the pixel already there - because
/// that is what every GPU backend can draw without reading the target back.
/// The factors are in `gpu_pipeline.dart` and the CPU's term-for-term copy of
/// them in `raster/blend.dart`.
///
/// The three masking modes ([blendModeSrcIn], [blendModeDstIn],
/// [blendModeDstOut]) are what `ShaderMask` is built from: draw a subtree into
/// a layer, then draw a gradient over it with one of them. Like every mode
/// here they are *bounded* - a pixel the primitive does not cover is left
/// alone - which differs from Skia's unbounded `kSrcIn` and is why a mask is
/// drawn over the whole layer rather than over the part that should survive.
const int blendModeSrcOver = 0;
const int blendModeSrc = 1;
const int blendModePlus = 2;

/// `dst = src * dstAlpha`: the source, kept only where the destination has
/// alpha. Gradient text - the ramp's colour inside the glyphs, nothing outside.
const int blendModeSrcIn = 3;

/// `dst = dst * srcAlpha`: the destination, kept only where the source has
/// alpha. A fade-out mask - the source's colour is ignored, only its alpha
/// matters.
const int blendModeDstIn = 4;

/// `dst = dst * (1 - srcAlpha)`: the destination, erased where the source has
/// alpha. The complement of [blendModeDstIn].
const int blendModeDstOut = 5;
const int kBlendModeCount = 6;

/// Whether a fully transparent source still changes the destination under
/// [blendMode], so a primitive whose paint (or whose coverage-scaled colour)
/// is transparent must still be drawn.
///
/// For source-over, plus and dst-out a transparent source is an identity and
/// skipping it is free. For `src` the framework *chose* to skip it - see
/// `blendPixelSrc` - so an invisible primitive draws nothing on any backend.
/// The two "in" modes are different in kind: a transparent source is the
/// strongest thing they can say, `erase`, and it is the whole point of a fade
/// mask whose ramp ends at alpha 0. Skipping it there would leave the content
/// fully visible exactly where the mask says it should be gone. It is also the
/// continuous limit: a source that rounds to alpha 0 under a sliver of
/// coverage multiplies the destination by almost nothing, so erasing it is the
/// nearest representable answer, not a hole.
///
/// Coverage zero is a different question with one answer in every mode: a
/// pixel the shape does not touch is not drawn.
bool blendModeWritesTransparentSource(int blendMode) =>
    blendMode == blendModeSrcIn || blendMode == blendModeDstIn;

/// Bit 6 of a paint's flag word: a `saveLayer` with this paint always gets its
/// own offscreen buffer, even at full opacity in source-over.
///
/// A layer that composites as an identity is normally *flattened* - drawn
/// straight into its parent, because an offscreen pass that multiplies by one
/// costs a buffer and buys nothing. That is only an identity while everything
/// inside draws source-over. A masking blend mode inside it would blend
/// against the parent's pixels instead of against the layer's own transparent
/// start, and every renderer refuses that by name. A `ShaderMask` is exactly
/// that subtree - its child, then a gradient in `blendModeDstIn` - so it asks
/// for isolation explicitly, the way Skia's `saveLayer` always isolates. The
/// bit means nothing on a paint that is not used by a `saveLayer`.
const int paintFlagIsolatedLayer = 0x40;

bool isKnownOpcode(int opcode) => opcode > opInvalid && opcode < kOpcodeCount;

/// Integer operands [opcode] must declare, or [kVariableSlots].
int intSlotsFor(int opcode) => _intSlotTable[opcode];

/// Float operands [opcode] must declare, or [kVariableSlots].
int floatSlotsFor(int opcode) => _floatSlotTable[opcode];

String opcodeName(int opcode) =>
    opcode >= 0 && opcode < kOpcodeCount ? _opcodeNames[opcode] : '0x$opcode';

String clipOpName(int op) =>
    op == clipOpDifference ? 'difference' : 'intersect';

/// Integer operands a glyph run of [glyphCount] glyphs declares:
/// fontId, paintId, the count itself, then one word per glyph id.
int glyphRunIntSlots(int glyphCount) => 3 + glyphCount;

/// Float operands a glyph run of [glyphCount] glyphs declares: the run origin
/// followed by one (x, y) pair per glyph.
int glyphRunFloatSlots(int glyphCount) => 2 + 2 * glyphCount;

/// Packs a command header.
///
/// The result is forced unsigned because the marker occupies bit 31 and Dart
/// on the web evaluates `<<` in 32-bit signed arithmetic; without this the
/// value would compare unequal to the same header read back out of a
/// `Uint32List`.
int encodeHeader(int opcode, int intSlots, int floatSlots) =>
    ((kHeaderMarker << 28) | (floatSlots << 18) | (intSlots << 8) | opcode)
        .toUnsigned(32);

int headerOpcode(int header) => header & 0xFF;

int headerIntSlots(int header) => (header >> 8) & 0x3FF;

int headerFloatSlots(int header) => (header >> 18) & 0x3FF;

int headerMarker(int header) => (header >> 28) & 0xF;

/// Raised when an encoded buffer cannot be walked.
///
/// Distinct from an [ArgumentError] on the encoder side: this one says the
/// bytes are wrong, not that the caller passed a bad argument. It always
/// carries the word offset so a corrupt buffer can be dumped around the exact
/// point where framing was lost.
final class DisplayListFormatException implements Exception {
  const DisplayListFormatException(this.message, {required this.wordOffset});

  final String message;

  /// Index into the word stream where the problem was detected.
  final int wordOffset;

  @override
  String toString() =>
      'DisplayListFormatException at word $wordOffset: $message';
}
