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

const int blendModeSrcOver = 0;
const int blendModeSrc = 1;
const int blendModePlus = 2;
const int kBlendModeCount = 3;

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
