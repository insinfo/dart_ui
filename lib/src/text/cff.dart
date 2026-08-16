/// `CFF ` and `CFF2` - PostScript outlines, decoded one glyph at a time.
///
/// An OpenType file whose first four bytes are `OTTO` does not carry a `glyf`
/// table. Its outlines live in a Compact Font Format container as *Type 2
/// charstrings*: a stack machine with subroutines, arithmetic, hint operators
/// and cubic Béziers. Half of the `.otf` files on a Windows install and most of
/// the macOS system faces are this, so "we only read `glyf`" is not a small
/// gap - it is the difference between a font picker that works and one that
/// silently falls back to something worse.
///
/// Three decisions shape this file, and they mirror `glyf.dart` on purpose.
///
/// **Lazy, like `glyf`.** The container - the INDEXes, the DICTs, the charset,
/// the FDSelect - is parsed once at load, because it is small and every glyph
/// needs it. Charstrings are *not* interpreted at load: a CJK OTF has tens of
/// thousands of them and a menu draws a few dozen.
///
/// **Straight into a [Path].** Type 2 charstrings are cubic, and
/// [PathBuilder.cubicTo] takes cubics, so the two meet directly. There is no
/// intermediate point model and no flattening on the way in.
///
/// **One reusable interpreter.** The operand stack, the transient array and
/// the interpreter state are allocated once per [CffFont] and reset per glyph,
/// because section 6.5 forbids allocation in a hot path and glyph decode is
/// one. The only per-glyph allocations are the [PathBuilder] and the [Path] it
/// produces, which is exactly what `glyf` allocates too.
///
/// ## What this parser refuses, out loud
///
/// Section 6.6 of the roadmap forbids accepting malformed input and quietly
/// producing something wrong. Everything below throws rather than guesses:
///
/// * **CFF2 `blend` and `vsindex`.** Variable-font interpolation is not
///   implemented. A CFF2 charstring that blends is refused with
///   [CffUnsupportedFeature] instead of being drawn at its default instance,
///   because a default-instance glyph is indistinguishable from a correct one
///   at a glance and would ship as a silent weight bug. [CffFont.fromSfnt]
///   refuses a CFF2 face with an ItemVariationStore up front, for the same
///   reason: such a face is a variable font, and every glyph in it is
///   suspect.
/// * **`CharstringType` 1.** A CFF wrapping Type 1 charstrings is legal and
///   almost extinct. The operators overlap numerically with Type 2 but mean
///   different things, so interpreting one as the other produces garbage
///   outlines rather than an error. Refused by name.
/// * **Type 1 leftovers in a Type 2 stream** (`hsbw`, `closepath`, `seac`,
///   `sbw`, `callothersubr`, `pop`, `setcurrentpoint`) and the multiple-master
///   `store`/`load`. Refused.
/// * **Predefined `Expert` charsets.** Recognised and refused rather than
///   mapped through a table this file does not carry.
///
/// ## What it implements that is easy to get wrong
///
/// * Subroutine **bias** (107 / 1131 / 32768), computed per INDEX, so a font
///   with 300 local subrs and 5000 global ones gets two different biases.
/// * The **implicit width**: the first stack-clearing operator may carry one
///   extra leading argument which is `nominalWidthX + w`; when it does not,
///   the width is `defaultWidthX`. Miscounting it shifts every remaining
///   argument by one and skews the whole glyph.
/// * `hintmask`/`cntrmask` **inline mask bytes**, `(hints + 7) >> 3` of them,
///   where hints include the ones declared implicitly by arguments left on the
///   stack before the first `hintmask`.
/// * **`endchar` with four trailing arguments** is the legacy `seac`: an
///   accented glyph assembled from two Standard Encoding glyphs. Implemented,
///   including the width interaction, and refused when nested.
/// * **CID-keyed fonts**: `FDSelect` picks the Private DICT - and therefore
///   the local subrs and the widths - per glyph. Getting it wrong misplaces
///   subroutine calls, not just hints.
///
/// ## Units
///
/// Charstring coordinates are in *charstring space*, which the Top DICT's
/// `FontMatrix` maps to the em square; the default matrix is
/// `[0.001 0 0 0.001 0 0]`, i.e. 1000 units per em. The rest of this engine
/// works in `head.unitsPerEm` units, so [CffFont.fromSfnt] folds
/// `FontMatrix * unitsPerEm` into the interpreter and every emitted point
/// comes out in the same units a `glyf` outline would. For the overwhelmingly
/// common case - `FontMatrix` 0.001 and `head.unitsPerEm` 1000 - that product
/// is the identity and costs nothing.
library;

import 'dart:typed_data';

import '../geometry/path.dart';
import 'font_data.dart';
import 'sfnt.dart';

/// A CFF construct this parser deliberately does not implement.
///
/// Distinct from [FontFormatException] because the font is *not* malformed:
/// it is well-formed and uses something we would have to guess at. Callers
/// that fall back to another face treat both the same way; callers reporting
/// to a human should say "unsupported", not "corrupt".
final class CffUnsupportedFeature implements Exception {
  const CffUnsupportedFeature(this.feature, this.reason);

  /// The construct, named the way the CFF spec names it.
  final String feature;

  /// Why it is refused rather than approximated.
  final String reason;

  @override
  String toString() => 'CffUnsupportedFeature: $feature - $reason';
}

/// Type 2 operand stack limit for CFF 1.0.
///
/// The spec says 48 and means it: a charstring that pushes a 49th operand is
/// malformed, and the only reason to grow the stack instead of failing is to
/// paper over a font that will misdraw anyway.
const int _maxOperandsCff1 = 48;

/// Type 2 operand stack limit for CFF2, which raised it for `blend`.
const int _maxOperandsCff2 = 513;

/// How deep `callsubr`/`callgsubr` may nest.
///
/// The Type 2 spec caps subroutine nesting at 10. As in `glyf.dart`'s
/// composite-depth guard, the cap is *ours* and not the font's: a charstring
/// that calls itself is a stack overflow driven by untrusted input, and a
/// self-referential font is precisely the font that would declare a legal
/// depth.
const int _maxSubrDepth = 10;

/// Entries in the Type 2 transient array, addressed by `put`/`get`.
const int _transientSize = 32;

/// How many strings the CFF standard string table holds. SIDs below this index
/// name a predefined glyph; SIDs at or above it index the font's String INDEX.
const int nStdStrings = 391;

/// A glyph decoded from a charstring.
///
/// [width] is the charstring's own advance - `defaultWidthX`, or
/// `nominalWidthX` plus the implicit leading operand. In an OpenType file
/// `hmtx` is authoritative and this value is redundant; it is exposed because
/// parsing it correctly is *not* optional (see the library doc) and because a
/// disagreement between the two is a useful signal that the width logic is
/// wrong.
typedef CffGlyph = ({Path path, double width});

/// A CFF INDEX: a count, an offset array, and the bytes they slice.
///
/// Held as a view over the font, never copied. [operator []] returns a
/// [Uint8List.sublistView] into the original allocation, which is what makes
/// "parse the container, not the glyphs" cheap.
final class CffIndex {
  const CffIndex._(this._bytes, this._offsets, this._base, this.endOffset);

  /// An INDEX with no entries, for the many optional ones a font omits.
  static final CffIndex empty = CffIndex._(Uint8List(0), Uint32List(0), 0, 0);

  final Uint8List _bytes;

  /// `count + 1` offsets, already made absolute into [_bytes].
  final Uint32List _offsets;

  /// Absolute offset of the byte the 1-based offsets are measured from.
  final int _base;

  /// The first byte after this INDEX, so the caller can find what follows.
  final int endOffset;

  int get count => _offsets.isEmpty ? 0 : _offsets.length - 1;

  bool get isEmpty => count == 0;

  /// Entry [index], as a view over the font bytes.
  ///
  /// Throws [FontFormatException] rather than [RangeError] for an out-of-range
  /// index, because in practice the index comes from a glyph id or a biased
  /// subroutine number - both of which arrive from the font, not from us.
  Uint8List operator [](int index) {
    if (index < 0 || index >= count) {
      throw FontFormatException(
        'INDEX entry $index requested from an INDEX of $count',
        table: 'CFF ',
      );
    }
    return Uint8List.sublistView(
      _bytes,
      _base + _offsets[index],
      _base + _offsets[index + 1],
    );
  }

  /// The subroutine bias for an INDEX of [count] entries.
  ///
  /// Type 2 subroutine numbers are signed and biased so that the most-used
  /// subroutines get one-byte operands. The three ranges are the single most
  /// commonly mis-transcribed constant in CFF implementations, and getting one
  /// wrong does not fail - it draws a different, plausible-looking glyph.
  static int biasFor(int count) {
    if (count < 1240) return 107;
    if (count < 33900) return 1131;
    return 32768;
  }

  /// This INDEX's bias, for `callsubr`/`callgsubr`.
  int get bias => biasFor(count);

  /// Parses an INDEX starting at [offset].
  ///
  /// [wide] selects the CFF2 header, whose count is a `uint32` rather than the
  /// `uint16` of CFF 1.0 - the one structural difference between the two
  /// INDEX encodings, and the one that silently shifts every later offset by
  /// two bytes if it is missed.
  static CffIndex parse(
    FontData data,
    int offset, {
    required bool wide,
    required String table,
  }) {
    final FontReader reader = data.readerAt(offset, table: table);
    final int count = wide ? reader.readUint32() : reader.readUint16();
    if (count == 0) {
      // An empty INDEX is *just* the count - there is no offSize byte. Reading
      // one anyway is the classic off-by-one here, and it desynchronises every
      // structure that follows.
      return CffIndex._(data.bytes, Uint32List(0), 0, reader.offset);
    }
    if (count < 0 || count > 0xFFFFFF) {
      throw FontFormatException(
        'INDEX declares $count entries, which cannot be true',
        offset: offset,
        table: table,
      );
    }

    final int offSize = reader.readUint8();
    if (offSize < 1 || offSize > 4) {
      throw FontFormatException(
        'INDEX offSize is $offSize, outside the legal range 1..4',
        offset: reader.offset - 1,
        table: table,
      );
    }

    final Uint32List offsets = Uint32List(count + 1);
    int previous = 0;
    for (int i = 0; i <= count; i++) {
      int value = 0;
      for (int b = 0; b < offSize; b++) {
        value = (value << 8) | reader.readUint8();
      }
      // Offsets are 1-based and must not go backwards. A decreasing pair would
      // produce a negative-length entry, which downstream turns into a silent
      // empty glyph instead of an error.
      if (value < 1 || value < previous) {
        throw FontFormatException(
          'INDEX offset $i is $value, which is before offset ${i - 1} '
          '($previous)',
          offset: offset,
          table: table,
        );
      }
      offsets[i] = value;
      previous = value;
    }

    final int base = reader.offset - 1;
    final int end = base + offsets[count];
    if (!data.contains(base, offsets[count])) {
      throw FontFormatException(
        'INDEX data runs to $end, past the end of the font',
        offset: offset,
        table: table,
      );
    }
    return CffIndex._(data.bytes, offsets, base, end);
  }

  @override
  String toString() => 'CffIndex($count entries, ends at $endOffset)';
}

/// A parsed CFF DICT.
///
/// Keys are the operator number for a one-byte operator and `1200 + n` for the
/// two-byte `12 n` escape form. Encoding them in one integer space keeps the
/// map a `Map<int, ...>` rather than a map of records, and the `1200` offset is
/// safe because one-byte operators stop at 31.
final class CffDict {
  const CffDict._(this._entries);

  final Map<int, Float64List> _entries;

  /// The operands stored for [key], or null when the DICT omits it.
  Float64List? operator [](int key) => _entries[key];

  bool contains(int key) => _entries.containsKey(key);

  Iterable<int> get keys => _entries.keys;

  /// The single operand for [key] as an int, or [orElse] when absent.
  int intOr(int key, int orElse) {
    final Float64List? values = _entries[key];
    if (values == null || values.isEmpty) return orElse;
    return values[values.length - 1].toInt();
  }

  /// The single operand for [key] as a double, or [orElse] when absent.
  double doubleOr(int key, double orElse) {
    final Float64List? values = _entries[key];
    if (values == null || values.isEmpty) return orElse;
    return values[values.length - 1];
  }

  /// A delta-encoded array, accumulated.
  ///
  /// Several Private DICT arrays - `BlueValues`, `StemSnapH` and friends - are
  /// stored as differences from the previous element to keep them small.
  /// Returning them raw is a bug that only shows up as hints in the wrong
  /// place, which is invisible until someone looks at a stem at 11px.
  Float64List? delta(int key) {
    final Float64List? values = _entries[key];
    if (values == null) return null;
    final Float64List result = Float64List(values.length);
    double running = 0;
    for (int i = 0; i < values.length; i++) {
      running += values[i];
      result[i] = running;
    }
    return result;
  }

  /// Parses a DICT out of [bytes].
  ///
  /// [table] only reaches error messages, and is worth passing because a
  /// malformed Private DICT and a malformed Top DICT fail identically
  /// otherwise.
  ///
  /// [cff2] widens the operator range. CFF 1.0 stops at operator 21 and marks
  /// 22..27 reserved; CFF2 spends three of them - `vsindex` (22), `blend` (23)
  /// and `vstore` (24). Accepting those in a CFF 1.0 DICT would let a
  /// misaligned read look like a valid entry, so the range is gated rather
  /// than simply widened for everyone.
  static CffDict parse(
    Uint8List bytes, {
    String table = 'CFF ',
    bool cff2 = false,
  }) {
    final Map<int, Float64List> entries = <int, Float64List>{};
    final Float64List operands = Float64List(_maxOperandsCff1);
    int count = 0;
    int i = 0;

    while (i < bytes.length) {
      final int b0 = bytes[i];

      if (b0 <= 27) {
        if (b0 > 21 && !cff2) {
          throw FontFormatException(
            'DICT operator $b0 is reserved in CFF 1.0; only CFF2 defines '
            'operators above 21',
            offset: i,
            table: table,
          );
        }
        // Operator. Two-byte operators escape through 12.
        int key = b0;
        i++;
        if (b0 == 12) {
          if (i >= bytes.length) {
            throw FontFormatException(
              'DICT ends inside a two-byte operator escape',
              offset: i,
              table: table,
            );
          }
          key = 1200 + bytes[i];
          i++;
        }
        entries[key] = Float64List(count)..setRange(0, count, operands);
        count = 0;
        continue;
      }

      // Operand.
      if (count >= _maxOperandsCff1) {
        throw FontFormatException(
          'DICT pushes more than $_maxOperandsCff1 operands before an '
          'operator',
          offset: i,
          table: table,
        );
      }
      final _DictOperand operand = _readDictOperand(bytes, i, table);
      operands[count++] = operand.value;
      i = operand.next;
    }

    // Trailing operands with no operator mean the DICT was truncated mid-entry.
    if (count != 0) {
      throw FontFormatException(
        'DICT ends with $count operands and no operator',
        table: table,
      );
    }
    return CffDict._(entries);
  }

  @override
  String toString() => 'CffDict(${_entries.length} entries)';
}

typedef _DictOperand = ({double value, int next});

/// Decodes one DICT operand: integer in 1, 2, 3 or 5 bytes, or a real.
_DictOperand _readDictOperand(Uint8List bytes, int i, String table) {
  void need(int extra) {
    if (i + extra >= bytes.length) {
      throw FontFormatException(
        'DICT operand runs past the end of the DICT',
        offset: i,
        table: table,
      );
    }
  }

  final int b0 = bytes[i];
  if (b0 >= 32 && b0 <= 246) {
    return (value: (b0 - 139).toDouble(), next: i + 1);
  }
  if (b0 >= 247 && b0 <= 250) {
    need(1);
    return (
      value: ((b0 - 247) * 256 + bytes[i + 1] + 108).toDouble(),
      next: i + 2
    );
  }
  if (b0 >= 251 && b0 <= 254) {
    need(1);
    return (
      value: (-(b0 - 251) * 256 - bytes[i + 1] - 108).toDouble(),
      next: i + 2
    );
  }
  if (b0 == 28) {
    need(2);
    final int raw = (bytes[i + 1] << 8) | bytes[i + 2];
    return (
      value: (raw >= 0x8000 ? raw - 0x10000 : raw).toDouble(),
      next: i + 3
    );
  }
  if (b0 == 29) {
    need(4);
    final int raw = (bytes[i + 1] << 24) |
        (bytes[i + 2] << 16) |
        (bytes[i + 3] << 8) |
        bytes[i + 4];
    return (value: raw.toSigned(32).toDouble(), next: i + 5);
  }
  if (b0 == 30) {
    return _readRealOperand(bytes, i + 1, table);
  }
  throw FontFormatException(
    'DICT operand byte $b0 is reserved',
    offset: i,
    table: table,
  );
}

/// Decodes a nibble-packed BCD real.
///
/// Two nibbles per byte, most significant first: 0-9 are digits, `a` is the
/// decimal point, `b` and `c` are `E` and `E-`, `e` is a minus sign and `f`
/// terminates. `d` is reserved and is refused rather than skipped, because a
/// `d` in the stream means the offset is wrong and every byte after it is
/// being misread.
_DictOperand _readRealOperand(Uint8List bytes, int start, String table) {
  final StringBuffer text = StringBuffer();
  int i = start;
  while (true) {
    if (i >= bytes.length) {
      throw FontFormatException(
        'DICT real operand is not terminated',
        offset: start,
        table: table,
      );
    }
    final int byte = bytes[i++];
    for (int half = 0; half < 2; half++) {
      final int nibble = half == 0 ? (byte >> 4) & 0x0F : byte & 0x0F;
      switch (nibble) {
        case 0xF:
          final double? parsed = double.tryParse(text.toString());
          if (parsed == null) {
            throw FontFormatException(
              'DICT real operand "$text" is not a number',
              offset: start,
              table: table,
            );
          }
          return (value: parsed, next: i);
        case 0xA:
          text.write('.');
        case 0xB:
          text.write('e');
        case 0xC:
          text.write('e-');
        case 0xD:
          throw FontFormatException(
            'DICT real operand contains the reserved nibble 0xd',
            offset: i - 1,
            table: table,
          );
        case 0xE:
          text.write('-');
        default:
          text.write(nibble);
      }
    }
  }
}

/// A Private DICT: local subroutines, the two widths, and the hint parameters.
///
/// **The hint parameters are parsed and exposed but not applied.** There is no
/// PostScript hinting engine in this repository yet, so [blueValues],
/// [stdHW] and the rest are data a future autohinter will need and nothing
/// reads today. They are surfaced rather than skipped so that adding that
/// engine is not also a parser change - and so that this limit is visible in
/// the API instead of being a surprise.
final class CffPrivateDict {
  const CffPrivateDict._({
    required this.subrs,
    required this.defaultWidthX,
    required this.nominalWidthX,
    required this.blueValues,
    required this.otherBlues,
    required this.familyBlues,
    required this.familyOtherBlues,
    required this.blueScale,
    required this.blueShift,
    required this.blueFuzz,
    required this.stdHW,
    required this.stdVW,
    required this.stemSnapH,
    required this.stemSnapV,
    required this.forceBold,
    required this.languageGroup,
    required this.expansionFactor,
  });

  /// A Private DICT with every default, for a font that omits one.
  static final CffPrivateDict defaults = CffPrivateDict._(
    subrs: CffIndex.empty,
    defaultWidthX: 0,
    nominalWidthX: 0,
    blueValues: null,
    otherBlues: null,
    familyBlues: null,
    familyOtherBlues: null,
    blueScale: 0.039625,
    blueShift: 7,
    blueFuzz: 1,
    stdHW: null,
    stdVW: null,
    stemSnapH: null,
    stemSnapV: null,
    forceBold: false,
    languageGroup: 0,
    expansionFactor: 0.06,
  );

  /// Local subroutines, biased separately from the global ones.
  final CffIndex subrs;

  /// The advance a charstring gets when it carries no explicit width.
  final double defaultWidthX;

  /// The base an explicit width is a difference from.
  final double nominalWidthX;

  final Float64List? blueValues;
  final Float64List? otherBlues;
  final Float64List? familyBlues;
  final Float64List? familyOtherBlues;
  final double blueScale;
  final double blueShift;
  final double blueFuzz;
  final double? stdHW;
  final double? stdVW;
  final Float64List? stemSnapH;
  final Float64List? stemSnapV;
  final bool forceBold;
  final int languageGroup;
  final double expansionFactor;

  /// Parses the Private DICT at `[offset, offset + size)`, plus its `Subrs`.
  ///
  /// `Subrs` (op 19) is an offset **relative to the Private DICT's own start**,
  /// not to the table. That relativity is the reason this function takes the
  /// offset rather than just the bytes: a parser that treats it as absolute
  /// reads another structure entirely and usually still "succeeds".
  static CffPrivateDict parse(
    FontData data,
    int offset,
    int size, {
    required bool cff2,
    required String table,
  }) {
    if (!data.contains(offset, size)) {
      throw FontFormatException(
        'Private DICT claims $size bytes at $offset, past the end of the font',
        offset: offset,
        table: table,
      );
    }
    final CffDict dict = CffDict.parse(
      Uint8List.sublistView(data.bytes, offset, offset + size),
      table: table,
      cff2: cff2,
    );

    CffIndex subrs = CffIndex.empty;
    final int subrsOffset = dict.intOr(19, -1);
    if (subrsOffset > 0) {
      subrs = CffIndex.parse(
        data,
        offset + subrsOffset,
        wide: cff2,
        table: table,
      );
    }

    return CffPrivateDict._(
      subrs: subrs,
      defaultWidthX: dict.doubleOr(20, 0),
      nominalWidthX: dict.doubleOr(21, 0),
      blueValues: dict.delta(6),
      otherBlues: dict.delta(7),
      familyBlues: dict.delta(8),
      familyOtherBlues: dict.delta(9),
      blueScale: dict.doubleOr(1209, 0.039625),
      blueShift: dict.doubleOr(1210, 7),
      blueFuzz: dict.doubleOr(1211, 1),
      stdHW: dict.contains(10) ? dict.doubleOr(10, 0) : null,
      stdVW: dict.contains(11) ? dict.doubleOr(11, 0) : null,
      stemSnapH: dict.delta(1212),
      stemSnapV: dict.delta(1213),
      forceBold: dict.doubleOr(1214, 0) != 0,
      languageGroup: dict.intOr(1217, 0),
      expansionFactor: dict.doubleOr(1218, 0.06),
    );
  }

  @override
  String toString() => 'CffPrivateDict(${subrs.count} subrs, '
      'defaultWidthX $defaultWidthX, nominalWidthX $nominalWidthX)';
}

/// The charset: glyph id to SID, or to CID in a CID-keyed font.
///
/// Two jobs in one structure, which is why it is one class. In a name-keyed
/// font the value is a String ID naming the glyph, and it is what makes
/// `seac` and glyph-name lookup possible. In a CID-keyed font the same bytes
/// mean Character IDs, and the charset becomes the glyph-to-CID map a PDF or a
/// CJK `cmap` subtable needs.
final class CffCharset {
  CffCharset._(this._values, this.isCid);

  /// One entry per glyph. `_values[0]` is 0 - glyph 0 is always `.notdef`.
  final Uint16List _values;

  final bool isCid;

  int get glyphCount => _values.length;

  /// The SID (or CID) for [glyphId]. Returns 0 - `.notdef` - out of range,
  /// which matches how every other lookup in this engine degrades.
  int sidFor(int glyphId) =>
      glyphId >= 0 && glyphId < _values.length ? _values[glyphId] : 0;

  Map<int, int>? _reverse;

  /// The glyph whose charset entry is [sid], or null.
  ///
  /// Built lazily and once: `seac` needs it, and `seac` appears in a minority
  /// of fonts. Building it eagerly would cost a map of `numGlyphs` entries for
  /// every face that never asks.
  int? glyphForSid(int sid) {
    final Map<int, int> reverse = _reverse ??= <int, int>{
      for (int glyph = _values.length - 1; glyph >= 0; glyph--)
        _values[glyph]: glyph,
    };
    return reverse[sid];
  }

  /// The identity charset, `gid == sid`, for a font that omits one.
  ///
  /// Offset 0 selects the predefined ISOAdobe charset, in which the first 229
  /// SIDs are in glyph order - so for those glyphs identity *is* ISOAdobe.
  /// Beyond that the mapping is undefined and this returns the SID anyway,
  /// which is what FreeType does; the consequence is that glyph names past
  /// glyph 228 in such a font are guesses, and this is the only place that
  /// says so.
  static CffCharset identity(int glyphCount, {required bool isCid}) {
    final Uint16List values = Uint16List(glyphCount);
    for (int i = 0; i < glyphCount; i++) {
      values[i] = i;
    }
    return CffCharset._(values, isCid);
  }

  /// Parses the charset at [offset] for [glyphCount] glyphs.
  ///
  /// Offsets 0, 1 and 2 are not offsets at all - they name the predefined
  /// ISOAdobe, Expert and ExpertSubset charsets. Only ISOAdobe is handled
  /// (as [identity]); the two Expert charsets are refused rather than
  /// approximated, because approximating them means naming glyphs wrongly.
  static CffCharset parse(
    FontData data,
    int offset,
    int glyphCount, {
    required bool isCid,
    required String table,
  }) {
    if (offset == 0) return identity(glyphCount, isCid: isCid);
    if (offset == 1 || offset == 2) {
      throw CffUnsupportedFeature(
        'predefined charset ${offset == 1 ? 'Expert' : 'ExpertSubset'}',
        'its SID table is not carried by this parser, and guessing it would '
            'name glyphs wrongly',
      );
    }

    final FontReader reader = data.readerAt(offset, table: table);
    final int format = reader.readUint8();
    final Uint16List values = Uint16List(glyphCount);
    // Glyph 0 is .notdef and is never listed; the table starts at glyph 1.
    int glyph = 1;

    switch (format) {
      case 0:
        while (glyph < glyphCount) {
          values[glyph++] = reader.readUint16();
        }
      case 1:
      case 2:
        while (glyph < glyphCount) {
          final int first = reader.readUint16();
          final int left =
              format == 1 ? reader.readUint8() : reader.readUint16();
          // `nLeft` counts glyphs *after* the first, so a range covers
          // `left + 1` glyphs. Reading it as the total is an off-by-one that
          // shifts every name in the font by a growing amount.
          for (int i = 0; i <= left && glyph < glyphCount; i++) {
            values[glyph++] = first + i;
          }
        }
      default:
        throw FontFormatException(
          'charset format $format is not one of 0, 1 or 2',
          offset: offset,
          table: table,
        );
    }

    return CffCharset._(values, isCid);
  }

  @override
  String toString() =>
      'CffCharset($glyphCount glyphs, ${isCid ? 'CID' : 'SID'})';
}

/// FDSelect: which Font DICT - and therefore which Private DICT - a glyph uses.
///
/// Only CID-keyed fonts have one. Choosing the wrong entry does not fail: it
/// hands the interpreter the wrong local subroutine INDEX, so `callsubr`
/// resolves to a different subroutine and the glyph draws something else
/// entirely. That is why this is parsed strictly.
final class CffFdSelect {
  const CffFdSelect._(this._format0, this._first, this._fd);

  /// Format 0: one byte per glyph.
  final Uint8List? _format0;

  /// Format 3: range starts, with a sentinel entry at the end.
  final Uint16List? _first;

  /// Format 3: the FD index for each range.
  final Uint8List? _fd;

  /// The Font DICT index for [glyphId]. Zero when out of range, because an
  /// FD index is used to select from a list and a wild value there would throw
  /// from somewhere that cannot explain itself.
  int fdFor(int glyphId) {
    final Uint8List? direct = _format0;
    if (direct != null) {
      return glyphId >= 0 && glyphId < direct.length ? direct[glyphId] : 0;
    }
    final Uint16List first = _first!;
    final Uint8List fd = _fd!;
    // Binary search: a CJK CID font has thousands of ranges and this runs once
    // per glyph decode.
    int low = 0;
    int high = fd.length - 1;
    while (low <= high) {
      final int mid = (low + high) >> 1;
      if (glyphId < first[mid]) {
        high = mid - 1;
      } else if (glyphId >= first[mid + 1]) {
        low = mid + 1;
      } else {
        return fd[mid];
      }
    }
    return 0;
  }

  static CffFdSelect parse(
    FontData data,
    int offset,
    int glyphCount, {
    required String table,
  }) {
    final FontReader reader = data.readerAt(offset, table: table);
    final int format = reader.readUint8();
    switch (format) {
      case 0:
        final Uint8List values = Uint8List(glyphCount);
        for (int i = 0; i < glyphCount; i++) {
          values[i] = reader.readUint8();
        }
        return CffFdSelect._(values, null, null);
      case 3:
        final int rangeCount = reader.readUint16();
        final Uint16List first = Uint16List(rangeCount + 1);
        final Uint8List fd = Uint8List(rangeCount);
        for (int i = 0; i < rangeCount; i++) {
          first[i] = reader.readUint16();
          fd[i] = reader.readUint8();
          // Ranges must ascend, or the binary search above is meaningless.
          if (i > 0 && first[i] < first[i - 1]) {
            throw FontFormatException(
              'FDSelect range $i starts before range ${i - 1}',
              offset: offset,
              table: table,
            );
          }
        }
        // The sentinel is the first glyph *past* the last range.
        first[rangeCount] = reader.readUint16();
        if (rangeCount > 0 && first[rangeCount] < first[rangeCount - 1]) {
          throw FontFormatException(
            'FDSelect sentinel is before the last range start',
            offset: offset,
            table: table,
          );
        }
        return CffFdSelect._(null, first, fd);
      default:
        throw FontFormatException(
          'FDSelect format $format is neither 0 nor 3',
          offset: offset,
          table: table,
        );
    }
  }

  @override
  String toString() => _format0 != null
      ? 'CffFdSelect(format 0, ${_format0.length} glyphs)'
      : 'CffFdSelect(format 3, ${_fd!.length} ranges)';
}

/// A parsed CFF or CFF2 font: the container, plus a Type 2 interpreter.
final class CffFont {
  CffFont._({
    required this.data,
    required this.isCff2,
    required this.charStrings,
    required this.globalSubrs,
    required this.topDict,
    required this.charset,
    required this.fontMatrix,
    required this.isCid,
    required List<CffPrivateDict> privateDicts,
    required CffFdSelect? fdSelect,
    required CffIndex strings,
    required this.name,
    required double outputScale,
  })  : _privateDicts = privateDicts,
        _fdSelect = fdSelect,
        _strings = strings,
        _outputScale = outputScale {
    _interpreter = _Type2Interpreter(this);
  }

  final FontData data;

  /// Whether this came from a `CFF2` table rather than a `CFF ` one.
  final bool isCff2;

  final CffIndex charStrings;
  final CffIndex globalSubrs;
  final CffDict topDict;
  final CffCharset charset;

  /// The Top DICT's `FontMatrix`, as `[a, b, c, d, e, f]`, before the
  /// unitsPerEm fold described in the library doc.
  final Float64List fontMatrix;

  /// Whether the font is CID-keyed, i.e. the Top DICT carries `ROS`.
  final bool isCid;

  /// The font's PostScript name, from the Name INDEX. Empty for CFF2, which
  /// has no Name INDEX at all - the `name` table is the only source there.
  final String name;

  final List<CffPrivateDict> _privateDicts;
  final CffFdSelect? _fdSelect;
  final CffIndex _strings;
  final double _outputScale;

  late final _Type2Interpreter _interpreter;

  int get glyphCount => charStrings.count;

  /// How many Private DICTs the font has: one, or one per Font DICT in a
  /// CID-keyed font's FDArray.
  int get privateDictCount => _privateDicts.length;

  /// The uniform scale folded into emitted coordinates.
  ///
  /// `FontMatrix[0] * unitsPerEm`. 1.0 for the ordinary case of a 0.001 matrix
  /// in a 1000-upem face, in which case no transform is applied at all.
  double get outputScale => _outputScale;

  /// The Private DICT that governs [glyphId].
  ///
  /// For a name-keyed font this is always the single Private DICT. For a
  /// CID-keyed one it is `FDArray[FDSelect[glyphId]]`, and the whole reason
  /// FDSelect is parsed strictly is that this lookup feeds `callsubr`.
  CffPrivateDict privateDictFor(int glyphId) {
    if (_privateDicts.isEmpty) return CffPrivateDict.defaults;
    final CffFdSelect? select = _fdSelect;
    if (select == null) return _privateDicts[0];
    final int fd = select.fdFor(glyphId);
    if (fd < 0 || fd >= _privateDicts.length) return _privateDicts[0];
    return _privateDicts[fd];
  }

  /// The string for [sid]: a standard string, or one from the String INDEX.
  String stringForSid(int sid) {
    if (sid < 0) return '';
    if (sid < nStdStrings) return standardStrings[sid];
    final int index = sid - nStdStrings;
    if (index >= _strings.count) return '';
    return String.fromCharCodes(_strings[index]);
  }

  /// The PostScript name of [glyphId].
  ///
  /// A CID-keyed font has no glyph names - its charset holds CIDs - so this
  /// returns `cid<n>`, which is the convention FreeType and the PDF spec both
  /// use. Callers that need real names from a CID font need the CIDFont's
  /// registry-ordering resources, which are not in the font file.
  String glyphName(int glyphId) {
    if (isCid) return 'cid${charset.sidFor(glyphId)}';
    return stringForSid(charset.sidFor(glyphId));
  }

  Map<String, int>? _namesToGlyphs;

  /// The glyph called [name], or null. Lazy for the same reason as
  /// [CffCharset.glyphForSid].
  int? glyphForName(String name) {
    if (isCid) return null;
    final Map<String, int> map = _namesToGlyphs ??= <String, int>{
      for (int glyph = glyphCount - 1; glyph >= 0; glyph--)
        glyphName(glyph): glyph,
    };
    return map[name];
  }

  /// Whether [glyphId] draws anything.
  ///
  /// Unlike `glyf`, where an empty glyph is a zero-length `loca` entry that
  /// costs nothing to detect, a CFF charstring must be interpreted to find
  /// out: a space is a charstring that sets a width and ends. So this decodes.
  /// [Typeface] caches outlines, which is what keeps that from being a repeat
  /// cost.
  bool hasOutline(int glyphId) => !outlineOf(glyphId).path.isEmpty;

  /// Decodes [glyphId] into a [Path] in output units, y up.
  ///
  /// Returns an empty path with the `hmtx`-independent default width when the
  /// glyph id is out of range, matching `glyf`'s "one broken glyph costs that
  /// glyph" policy. A malformed *charstring*, by contrast, throws: it means
  /// the font's own data disagrees with itself, and swallowing that is how a
  /// parser bug hides behind a blank glyph.
  CffGlyph outlineOf(int glyphId) {
    if (glyphId < 0 || glyphId >= charStrings.count) {
      return (path: _emptyPath, width: 0);
    }
    return _interpreter.run(glyphId);
  }

  /// Parses the `CFF ` or `CFF2` table of [file].
  ///
  /// [unitsPerEm] is `head.unitsPerEm`; passing it folds
  /// `FontMatrix * unitsPerEm` into every emitted coordinate so that CFF
  /// outlines arrive in the same units as `glyf` ones. Pass 0 to get raw
  /// charstring units.
  static CffFont fromSfnt(SfntFile file, {int unitsPerEm = 0}) {
    final TableRecord? cff2 = file.tableRecord('CFF2');
    if (cff2 != null) {
      return parseCff2(
        file.data,
        cff2.offset,
        cff2.length,
        unitsPerEm: unitsPerEm,
      );
    }
    final TableRecord record = file.requireTable('CFF ');
    return parse(
      file.data,
      record.offset,
      record.length,
      unitsPerEm: unitsPerEm,
    );
  }

  /// Parses a bare CFF 1.0 container at `[offset, offset + length)`.
  ///
  /// Exposed separately from [fromSfnt] because a CFF is also a standalone
  /// file format, and because tests build one in memory without an sfnt
  /// wrapper around it.
  static CffFont parse(
    FontData data,
    int offset,
    int length, {
    int unitsPerEm = 0,
  }) {
    const String table = 'CFF ';
    if (!data.contains(offset, length)) {
      throw FontFormatException(
        'CFF table claims $length bytes at $offset, past the end of the file',
        offset: offset,
        table: table,
      );
    }

    final FontReader header = data.readerAt(offset, table: table);
    final int major = header.readUint8();
    header.readUint8(); // minor: additive changes only, nothing branches on it
    final int headerSize = header.readUint8();
    header.readUint8(); // absOffSize: unused since CFF 1.0, kept for layout

    if (major == 2) {
      throw FontFormatException(
        'a CFF2 font is stored in a "CFF2" table, not "CFF "',
        offset: offset,
        table: table,
      );
    }
    if (major != 1) {
      throw FontFormatException(
        'CFF major version $major is not 1',
        offset: offset,
        table: table,
      );
    }
    if (headerSize < 4) {
      throw FontFormatException(
        'CFF hdrSize is $headerSize, smaller than the header itself',
        offset: offset,
        table: table,
      );
    }

    final CffIndex names =
        CffIndex.parse(data, offset + headerSize, wide: false, table: table);
    final CffIndex topDicts =
        CffIndex.parse(data, names.endOffset, wide: false, table: table);
    final CffIndex strings =
        CffIndex.parse(data, topDicts.endOffset, wide: false, table: table);
    final CffIndex globalSubrs =
        CffIndex.parse(data, strings.endOffset, wide: false, table: table);

    if (topDicts.isEmpty) {
      throw const FontFormatException(
        'the Top DICT INDEX is empty, so the font describes no face',
        table: table,
      );
    }
    // A CFF may hold several faces; an OpenType one never does, and choosing
    // silently between them is exactly the kind of guess section 6.6 forbids.
    // Face 0 is the only one an sfnt wrapper can refer to.
    final CffDict top = CffDict.parse(topDicts[0], table: table);

    final int charstringType = top.intOr(1206, 2);
    if (charstringType != 2) {
      throw CffUnsupportedFeature(
        'CharstringType $charstringType',
        'only Type 2 charstrings are interpreted; Type 1 operators overlap '
            'numerically with Type 2 and would decode into wrong outlines '
            'rather than into an error',
      );
    }

    final int charStringsOffset = top.intOr(17, 0);
    if (charStringsOffset <= 0) {
      throw const FontFormatException(
        'the Top DICT has no CharStrings offset, so the font has no outlines',
        table: table,
      );
    }
    final CffIndex charStrings = CffIndex.parse(
      data,
      offset + charStringsOffset,
      wide: false,
      table: table,
    );

    final bool isCid = top.contains(1230); // ROS
    final Float64List matrix = _matrixOf(top);

    final List<CffPrivateDict> privates = <CffPrivateDict>[];
    CffFdSelect? fdSelect;

    if (isCid) {
      final int fdArrayOffset = top.intOr(1236, 0);
      if (fdArrayOffset <= 0) {
        throw const FontFormatException(
          'a CID-keyed font must have an FDArray, and this one has none',
          table: table,
        );
      }
      final CffIndex fdArray = CffIndex.parse(
        data,
        offset + fdArrayOffset,
        wide: false,
        table: table,
      );
      for (int i = 0; i < fdArray.count; i++) {
        final CffDict fontDict = CffDict.parse(fdArray[i], table: table);
        privates.add(_privateOf(data, fontDict, offset, cff2: false));
      }
      final int fdSelectOffset = top.intOr(1237, 0);
      if (fdSelectOffset > 0) {
        fdSelect = CffFdSelect.parse(
          data,
          offset + fdSelectOffset,
          charStrings.count,
          table: table,
        );
      } else if (privates.length > 1) {
        // With one Font DICT the answer is unambiguous. With several and no
        // FDSelect there is no answer, and picking the first would hand most
        // glyphs the wrong subroutines.
        throw const FontFormatException(
          'a CID-keyed font with several Font DICTs has no FDSelect, so no '
          'glyph can be assigned a Private DICT',
          table: table,
        );
      }
    } else {
      privates.add(_privateOf(data, top, offset, cff2: false));
    }

    final CffCharset charset = CffCharset.parse(
      data,
      top.intOr(15, 0) == 0 ? 0 : offset + top.intOr(15, 0),
      charStrings.count,
      isCid: isCid,
      table: table,
    );

    return CffFont._(
      data: data,
      isCff2: false,
      charStrings: charStrings,
      globalSubrs: globalSubrs,
      topDict: top,
      charset: charset,
      fontMatrix: matrix,
      isCid: isCid,
      privateDicts: privates,
      fdSelect: fdSelect,
      strings: strings,
      name: names.isEmpty ? '' : String.fromCharCodes(names[0]),
      outputScale: unitsPerEm > 0 ? matrix[0] * unitsPerEm : 1.0,
    );
  }

  /// Parses a `CFF2` table.
  ///
  /// CFF2 drops the Name INDEX, the String INDEX, the Encoding and the
  /// charset - the sfnt wrapper already carries all of that - and it adds an
  /// ItemVariationStore plus the `vsindex` and `blend` charstring operators.
  ///
  /// **A CFF2 face with a `vstore` is refused here.** Rendering it without
  /// `blend` would draw the default instance, which looks like a perfectly
  /// good glyph and is the wrong weight, width or optical size. A named
  /// refusal costs the caller a fallback face; a silent default instance costs
  /// them a bug they cannot see. Non-variable CFF2 - legal, and produced by a
  /// few subsetters - is parsed and drawn normally, and a stray `blend` inside
  /// one still throws.
  static CffFont parseCff2(
    FontData data,
    int offset,
    int length, {
    int unitsPerEm = 0,
  }) {
    const String table = 'CFF2';
    if (!data.contains(offset, length)) {
      throw FontFormatException(
        'CFF2 table claims $length bytes at $offset, past the end of the file',
        offset: offset,
        table: table,
      );
    }
    final FontReader header = data.readerAt(offset, table: table);
    final int major = header.readUint8();
    header.readUint8(); // minor
    final int headerSize = header.readUint8();
    final int topDictLength = header.readUint16();

    if (major != 2) {
      throw FontFormatException(
        'CFF2 major version is $major, not 2',
        offset: offset,
        table: table,
      );
    }
    if (headerSize < 5) {
      throw FontFormatException(
        'CFF2 headerSize is $headerSize, smaller than the header itself',
        offset: offset,
        table: table,
      );
    }

    final int topDictOffset = offset + headerSize;
    if (!data.contains(topDictOffset, topDictLength)) {
      throw const FontFormatException(
        'the CFF2 Top DICT runs past the end of the table',
        table: table,
      );
    }
    final CffDict top = CffDict.parse(
      Uint8List.sublistView(
        data.bytes,
        topDictOffset,
        topDictOffset + topDictLength,
      ),
      table: table,
      cff2: true,
    );

    if (top.contains(24)) {
      throw const CffUnsupportedFeature(
        'CFF2 ItemVariationStore',
        'this is a variable font and `blend` is not implemented; drawing it '
            'would silently produce the default instance, which is a wrong '
            'weight that looks correct',
      );
    }

    final CffIndex globalSubrs = CffIndex.parse(
      data,
      topDictOffset + topDictLength,
      wide: true,
      table: table,
    );

    final int charStringsOffset = top.intOr(17, 0);
    if (charStringsOffset <= 0) {
      throw const FontFormatException(
        'the CFF2 Top DICT has no CharStrings offset',
        table: table,
      );
    }
    final CffIndex charStrings = CffIndex.parse(
      data,
      offset + charStringsOffset,
      wide: true,
      table: table,
    );

    // FDArray is mandatory in CFF2 even for a single-master font: the Private
    // DICT lives there and nowhere else.
    final int fdArrayOffset = top.intOr(1236, 0);
    if (fdArrayOffset <= 0) {
      throw const FontFormatException(
        'a CFF2 font must have an FDArray, and this one has none',
        table: table,
      );
    }
    final CffIndex fdArray = CffIndex.parse(
      data,
      offset + fdArrayOffset,
      wide: true,
      table: table,
    );
    final List<CffPrivateDict> privates = <CffPrivateDict>[];
    for (int i = 0; i < fdArray.count; i++) {
      final CffDict fontDict =
          CffDict.parse(fdArray[i], table: table, cff2: true);
      privates.add(_privateOf(data, fontDict, offset, cff2: true));
    }

    CffFdSelect? fdSelect;
    final int fdSelectOffset = top.intOr(1237, 0);
    if (fdSelectOffset > 0) {
      fdSelect = CffFdSelect.parse(
        data,
        offset + fdSelectOffset,
        charStrings.count,
        table: table,
      );
    } else if (privates.length > 1) {
      throw const FontFormatException(
        'a CFF2 font with several Font DICTs has no FDSelect',
        table: table,
      );
    }

    final Float64List matrix = _matrixOf(top);
    return CffFont._(
      data: data,
      isCff2: true,
      charStrings: charStrings,
      globalSubrs: globalSubrs,
      topDict: top,
      charset: CffCharset.identity(charStrings.count, isCid: false),
      fontMatrix: matrix,
      isCid: false,
      privateDicts: privates,
      fdSelect: fdSelect,
      strings: CffIndex.empty,
      name: '',
      outputScale: unitsPerEm > 0 ? matrix[0] * unitsPerEm : 1.0,
    );
  }

  static Float64List _matrixOf(CffDict dict) {
    final Float64List matrix = Float64List.fromList(
      <double>[0.001, 0, 0, 0.001, 0, 0],
    );
    final Float64List? declared = dict[1207];
    if (declared != null && declared.length == 6) {
      matrix.setAll(0, declared);
    }
    if (matrix[0] == 0 || matrix[3] == 0) {
      throw const FontFormatException(
        'the FontMatrix collapses the em square to a line',
        table: 'CFF ',
      );
    }
    return matrix;
  }

  /// Reads the `Private` entry - a `[size, offset]` pair - out of [dict].
  static CffPrivateDict _privateOf(
    FontData data,
    CffDict dict,
    int tableOffset, {
    required bool cff2,
  }) {
    final Float64List? entry = dict[18];
    if (entry == null || entry.length < 2) return CffPrivateDict.defaults;
    final int size = entry[0].toInt();
    final int at = entry[1].toInt();
    if (size <= 0) return CffPrivateDict.defaults;
    return CffPrivateDict.parse(
      data,
      tableOffset + at,
      size,
      cff2: cff2,
      table: cff2 ? 'CFF2' : 'CFF ',
    );
  }

  @override
  String toString() => 'CffFont(${isCff2 ? 'CFF2' : 'CFF'}, $glyphCount glyphs'
      '${isCid ? ', CID-keyed' : ''}, ${_privateDicts.length} private DICTs)';
}

/// The outline handed back for a glyph that draws nothing. Shared, because a
/// font full of spaces produces many of them and they are all the same
/// nothing.
final Path _emptyPath = PathBuilder().build();

/// The Type 2 charstring interpreter.
///
/// One instance per [CffFont], reset per glyph. Not re-entrant, and it does not
/// need to be: `callsubr` recursion is a loop over an explicit return stack
/// only in the sense that Dart's own call stack carries it, bounded by
/// [_maxSubrDepth], and `seac` is run as two further top-level passes rather
/// than nested inside the operator loop.
final class _Type2Interpreter {
  _Type2Interpreter(CffFont font)
      : _font = font,
        _stack = Float64List(
          font.isCff2 ? _maxOperandsCff2 : _maxOperandsCff1,
        ),
        _stackLimit = font.isCff2 ? _maxOperandsCff2 : _maxOperandsCff1;

  final CffFont _font;
  final Float64List _stack;
  final int _stackLimit;
  final Float64List _transient = Float64List(_transientSize);

  int _size = 0;
  int _hintCount = 0;
  bool _widthTaken = false;
  double _width = 0;
  double _x = 0;
  double _y = 0;
  bool _open = false;
  bool _ended = false;

  /// Offset applied to every point before the font matrix, in charstring
  /// units. Non-zero only while placing a `seac` accent.
  double _offsetX = 0;
  double _offsetY = 0;

  /// The pending `seac`, captured by `endchar` and executed by [run].
  double _seacAdx = 0;
  double _seacAdy = 0;
  int _seacBase = -1;
  int _seacAccent = -1;
  bool _inSeac = false;

  late PathBuilder _builder;
  late CffIndex _localSubrs;
  late double _defaultWidthX;
  late double _nominalWidthX;

  /// A deterministic source for the `random` operator.
  ///
  /// The Type 2 spec wants a pseudo-random number in (0, 1]. A real random
  /// source would make a glyph's outline differ between two runs of the same
  /// program, which would break outline caching, golden tests and any hope of
  /// reproducible rendering. So this is a fixed-seed linear congruential
  /// generator: `random` still returns varying values within a charstring, and
  /// the same glyph always draws the same way. **Declared limit:** a font that
  /// genuinely wants randomised outlines will not get them.
  int _randomState = 0x2545F491;

  double _nextRandom() {
    _randomState = (_randomState * 1103515245 + 12345) & 0x7FFFFFFF;
    // (0, 1], never 0, because `div` by a random value is legal Type 2.
    return (_randomState + 1) / 0x80000000;
  }

  CffGlyph run(int glyphId) {
    final PathBuilder builder = PathBuilder();
    _builder = builder;
    _prepareFor(glyphId);
    _widthTaken = _font.isCff2; // CFF2 charstrings carry no width at all.
    _width = _defaultWidthX;
    _x = 0;
    _y = 0;
    _offsetX = 0;
    _offsetY = 0;
    _open = false;
    _ended = false;
    _hintCount = 0;
    _size = 0;
    _seacBase = -1;
    _inSeac = false;

    _execute(_font.charStrings[glyphId], 0);
    if (_open) builder.close();

    if (_seacBase >= 0) {
      _runSeac(builder);
    }

    return (path: builder.build(), width: _width);
  }

  /// Runs the two components of a legacy `seac`.
  ///
  /// The composite's own width, already computed from the `endchar` that
  /// triggered this, wins over the components' - matching FreeType, and
  /// matching the fact that the composite is the glyph `hmtx` describes.
  void _runSeac(PathBuilder builder) {
    final int baseGlyph = _seacBase;
    final int accentGlyph = _seacAccent;
    final double adx = _seacAdx;
    final double ady = _seacAdy;
    final double compositeWidth = _width;

    for (int part = 0; part < 2; part++) {
      final int glyph = part == 0 ? baseGlyph : accentGlyph;
      _prepareFor(glyph);
      _widthTaken = false;
      _x = 0;
      _y = 0;
      _offsetX = part == 0 ? 0 : adx;
      _offsetY = part == 0 ? 0 : ady;
      _open = false;
      _ended = false;
      _hintCount = 0;
      _size = 0;
      _seacBase = -1;
      _inSeac = true;
      _execute(_font.charStrings[glyph], 0);
      if (_open) builder.close();
      if (_seacBase >= 0) {
        throw const FontFormatException(
          'a seac component is itself a seac, which the format forbids',
          table: 'CFF ',
        );
      }
    }
    _inSeac = false;
    _width = compositeWidth;
  }

  void _prepareFor(int glyphId) {
    final CffPrivateDict private = _font.privateDictFor(glyphId);
    _localSubrs = private.subrs;
    _defaultWidthX = private.defaultWidthX;
    _nominalWidthX = private.nominalWidthX;
  }

  // --- geometry --------------------------------------------------------
  //
  // Points leave here already in output units. The transform is the Top DICT
  // FontMatrix scaled by unitsPerEm; when that product is the identity - the
  // ordinary 0.001 matrix in a 1000-upem face - the scale branch is skipped
  // entirely rather than multiplying by 1.0 six times per point.

  bool get _scaled => _font.outputScale != 1.0;

  double _outX(double x) =>
      _scaled ? (x + _offsetX) * _font.outputScale : x + _offsetX;

  double _outY(double y) =>
      _scaled ? (y + _offsetY) * _font.outputScale : y + _offsetY;

  void _moveTo(double x, double y) {
    if (_open) _builder.close();
    _builder.moveTo(_outX(x), _outY(y));
    _open = true;
  }

  void _lineTo(double x, double y) {
    if (!_open) {
      // A charstring that draws before its first moveto is malformed. Opening
      // a contour at the current point keeps one bad glyph from failing the
      // face, which is `glyf.dart`'s policy too.
      _builder.moveTo(_outX(_x), _outY(_y));
      _open = true;
    }
    _builder.lineTo(_outX(x), _outY(y));
  }

  void _curveTo(
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
  ) {
    if (!_open) {
      _builder.moveTo(_outX(_x), _outY(_y));
      _open = true;
    }
    _builder.cubicTo(
      _outX(x1),
      _outY(y1),
      _outX(x2),
      _outY(y2),
      _outX(x3),
      _outY(y3),
    );
  }

  /// A relative cubic: three deltas, chained from the current point.
  void _relativeCurve(
    double dx1,
    double dy1,
    double dx2,
    double dy2,
    double dx3,
    double dy3,
  ) {
    final double x1 = _x + dx1;
    final double y1 = _y + dy1;
    final double x2 = x1 + dx2;
    final double y2 = y1 + dy2;
    _x = x2 + dx3;
    _y = y2 + dy3;
    _curveTo(x1, y1, x2, y2, _x, _y);
  }

  // --- stack -----------------------------------------------------------

  void _push(double value) {
    if (_size >= _stackLimit) {
      throw FontFormatException(
        'charstring pushes more than $_stackLimit operands',
        table: 'CFF ',
      );
    }
    _stack[_size++] = value;
  }

  double _pop() {
    if (_size == 0) {
      throw const FontFormatException(
        'charstring operator needs an operand and the stack is empty',
        table: 'CFF ',
      );
    }
    return _stack[--_size];
  }

  void _need(int count, String operator) {
    if (_size < count) {
      throw FontFormatException(
        '$operator needs $count operands and the stack holds $_size',
        table: 'CFF ',
      );
    }
  }

  /// Consumes the implicit width when this is the first stack-clearing
  /// operator and the argument count says one is there.
  ///
  /// [expected] is how many operands the operator itself takes. Returns the
  /// index of the operator's first real operand: 1 when a width was taken,
  /// 0 otherwise. Every stack-clearing operator must route through here
  /// *before* reading its arguments, because a width shifts them all by one.
  int _takeWidth(int expected) {
    if (_widthTaken) return 0;
    _widthTaken = true;
    if (_size > expected) {
      _width = _nominalWidthX + _stack[0];
      return 1;
    }
    _width = _defaultWidthX;
    return 0;
  }

  /// The width rule for the stem and mask operators, whose operand count is
  /// even: an odd count means the first operand is a width.
  int _takeWidthOdd() {
    if (_widthTaken) return 0;
    _widthTaken = true;
    if (_size.isOdd) {
      _width = _nominalWidthX + _stack[0];
      return 1;
    }
    _width = _defaultWidthX;
    return 0;
  }

  /// Counts a run of stem hints. Returns nothing; the count feeds `hintmask`.
  void _countStems() {
    final int first = _takeWidthOdd();
    _hintCount += (_size - first) >> 1;
    _size = 0;
  }

  // --- the operator loop ------------------------------------------------

  void _execute(Uint8List code, int depth) {
    if (depth > _maxSubrDepth) {
      throw const FontFormatException(
        'charstring subroutines nest more than $_maxSubrDepth deep, which '
        'means a subroutine calls itself',
        table: 'CFF ',
      );
    }

    int i = 0;
    while (i < code.length) {
      if (_ended) return;
      final int b0 = code[i++];

      // Operands first: they are the overwhelming majority of bytes.
      if (b0 >= 32) {
        if (b0 <= 246) {
          _push((b0 - 139).toDouble());
        } else if (b0 <= 250) {
          i = _requireByte(code, i, 'a two-byte operand');
          _push(((b0 - 247) * 256 + code[i - 1] + 108).toDouble());
        } else if (b0 <= 254) {
          i = _requireByte(code, i, 'a two-byte operand');
          _push((-(b0 - 251) * 256 - code[i - 1] - 108).toDouble());
        } else {
          // 255: a 16.16 fixed-point number. Note this differs from a DICT,
          // where 255 is not an operand prefix at all.
          if (i + 4 > code.length) {
            throw const FontFormatException(
              'charstring ends inside a 16.16 operand',
              table: 'CFF ',
            );
          }
          final int raw = (code[i] << 24) |
              (code[i + 1] << 16) |
              (code[i + 2] << 8) |
              code[i + 3];
          i += 4;
          _push(raw.toSigned(32) / 65536.0);
        }
        continue;
      }
      if (b0 == 28) {
        if (i + 2 > code.length) {
          throw const FontFormatException(
            'charstring ends inside a 16-bit operand',
            table: 'CFF ',
          );
        }
        final int raw = (code[i] << 8) | code[i + 1];
        i += 2;
        _push(raw.toSigned(16).toDouble());
        continue;
      }

      switch (b0) {
        case 1: // hstem
        case 3: // vstem
        case 18: // hstemhm
        case 23: // vstemhm
          _countStems();

        case 19: // hintmask
        case 20: // cntrmask
          {
            // Operands still on the stack here are an implicit vstemhm - the
            // spec's own words - and they count towards the mask width. A
            // parser that ignores them reads too few mask bytes and then
            // interprets mask bits as operators.
            _countStems();
            final int maskBytes = (_hintCount + 7) >> 3;
            if (i + maskBytes > code.length) {
              throw FontFormatException(
                'hintmask needs $maskBytes mask bytes and the charstring has '
                '${code.length - i} left',
                table: 'CFF ',
              );
            }
            i += maskBytes;
          }

        case 21: // rmoveto
          {
            final int base = _takeWidth(2);
            _need(base + 2, 'rmoveto');
            _x += _stack[base];
            _y += _stack[base + 1];
            _moveTo(_x, _y);
            _size = 0;
          }

        case 22: // hmoveto
          {
            final int base = _takeWidth(1);
            _need(base + 1, 'hmoveto');
            _x += _stack[base];
            _moveTo(_x, _y);
            _size = 0;
          }

        case 4: // vmoveto
          {
            final int base = _takeWidth(1);
            _need(base + 1, 'vmoveto');
            _y += _stack[base];
            _moveTo(_x, _y);
            _size = 0;
          }

        case 5: // rlineto
          for (int k = 0; k + 1 < _size; k += 2) {
            _x += _stack[k];
            _y += _stack[k + 1];
            _lineTo(_x, _y);
          }
          _size = 0;

        case 6: // hlineto
        case 7: // vlineto
          {
            bool horizontal = b0 == 6;
            for (int k = 0; k < _size; k++) {
              if (horizontal) {
                _x += _stack[k];
              } else {
                _y += _stack[k];
              }
              _lineTo(_x, _y);
              horizontal = !horizontal;
            }
            _size = 0;
          }

        case 8: // rrcurveto
          for (int k = 0; k + 5 < _size; k += 6) {
            _relativeCurve(_stack[k], _stack[k + 1], _stack[k + 2],
                _stack[k + 3], _stack[k + 4], _stack[k + 5]);
          }
          _size = 0;

        case 24: // rcurveline
          {
            int k = 0;
            while (_size - k >= 8) {
              _relativeCurve(_stack[k], _stack[k + 1], _stack[k + 2],
                  _stack[k + 3], _stack[k + 4], _stack[k + 5]);
              k += 6;
            }
            _need(k + 2, 'rcurveline');
            _x += _stack[k];
            _y += _stack[k + 1];
            _lineTo(_x, _y);
            _size = 0;
          }

        case 25: // rlinecurve
          {
            int k = 0;
            while (_size - k >= 8) {
              _x += _stack[k];
              _y += _stack[k + 1];
              _lineTo(_x, _y);
              k += 2;
            }
            _need(k + 6, 'rlinecurve');
            _relativeCurve(_stack[k], _stack[k + 1], _stack[k + 2],
                _stack[k + 3], _stack[k + 4], _stack[k + 5]);
            _size = 0;
          }

        case 26: // vvcurveto
          {
            int k = 0;
            double dx1 = 0;
            if (_size.isOdd) {
              dx1 = _stack[0];
              k = 1;
            }
            for (; k + 3 < _size; k += 4) {
              _relativeCurve(dx1, _stack[k], _stack[k + 1], _stack[k + 2], 0,
                  _stack[k + 3]);
              dx1 = 0;
            }
            _size = 0;
          }

        case 27: // hhcurveto
          {
            int k = 0;
            double dy1 = 0;
            if (_size.isOdd) {
              dy1 = _stack[0];
              k = 1;
            }
            for (; k + 3 < _size; k += 4) {
              _relativeCurve(_stack[k], dy1, _stack[k + 1], _stack[k + 2],
                  _stack[k + 3], 0);
              dy1 = 0;
            }
            _size = 0;
          }

        case 30: // vhcurveto
        case 31: // hvcurveto
          {
            bool horizontal = b0 == 31;
            int k = 0;
            while (_size - k >= 4) {
              // A trailing fifth operand on the last curve sets the coordinate
              // the alternation would otherwise leave at zero. Reading it on
              // any but the last curve is the classic bug here.
              final bool last = _size - k == 5;
              if (horizontal) {
                _relativeCurve(_stack[k], 0, _stack[k + 1], _stack[k + 2],
                    last ? _stack[k + 4] : 0, _stack[k + 3]);
              } else {
                _relativeCurve(0, _stack[k], _stack[k + 1], _stack[k + 2],
                    _stack[k + 3], last ? _stack[k + 4] : 0);
              }
              k += 4;
              horizontal = !horizontal;
            }
            _size = 0;
          }

        case 10: // callsubr
          _call(_localSubrs, 'callsubr', depth);

        case 29: // callgsubr
          _call(_font.globalSubrs, 'callgsubr', depth);

        case 11: // return
          return;

        case 14: // endchar
          _endchar();
          return;

        case 15: // vsindex (CFF2)
          throw const CffUnsupportedFeature(
            'vsindex',
            'it selects a variation-store subtable, and variation blending is '
                'not implemented',
          );

        case 16: // blend (CFF2)
          throw const CffUnsupportedFeature(
            'blend',
            'variable-font interpolation is not implemented; drawing the '
                'default instance instead would be a silent weight bug',
          );

        case 12:
          i = _requireByte(code, i, 'a two-byte operator escape');
          _escaped(code[i - 1]);

        default:
          throw FontFormatException(
            'charstring operator $b0 is reserved',
            table: 'CFF ',
          );
      }
    }
  }

  int _requireByte(Uint8List code, int i, String what) {
    if (i >= code.length) {
      throw FontFormatException(
        'charstring ends inside $what',
        table: 'CFF ',
      );
    }
    return i + 1;
  }

  void _call(CffIndex subrs, String operator, int depth) {
    final double raw = _pop();
    final int index = raw.toInt() + subrs.bias;
    if (index < 0 || index >= subrs.count) {
      throw FontFormatException(
        '$operator asks for subroutine ${raw.toInt()} (biased to $index) from '
        'an INDEX of ${subrs.count}',
        table: 'CFF ',
      );
    }
    _execute(subrs[index], depth + 1);
  }

  /// `endchar`, including the legacy `seac` form.
  ///
  /// Four trailing operands mean the glyph is `adx ady bchar achar`: a base
  /// letter and an accent, both named by Standard Encoding character codes,
  /// composed into one outline. Five means the same plus a leading width. This
  /// is how a Type 1 font expressed `é`, and OTFs converted from Type 1 still
  /// use it.
  void _endchar() {
    final int base = _takeWidthOdd();
    final int arguments = _size - base;
    _ended = true;

    if (arguments == 0) {
      _size = 0;
      return;
    }
    if (arguments != 4) {
      throw FontFormatException(
        'endchar has $arguments operands; only 0 (plain) and 4 (seac) are '
        'defined',
        table: 'CFF ',
      );
    }
    if (_inSeac) {
      // Caught here as well as in _runSeac so the error names the nesting even
      // when the inner charstring is the one that misbehaves.
      throw const FontFormatException(
        'a seac component is itself a seac, which the format forbids',
        table: 'CFF ',
      );
    }
    if (_font.isCff2) {
      throw const FontFormatException(
        'a CFF2 charstring used the seac form of endchar, which CFF2 removed',
        table: 'CFF2',
      );
    }
    if (_font.isCid) {
      // A CID font's charset holds CIDs, so a Standard Encoding code cannot be
      // resolved to a glyph at all. Guessing would draw an arbitrary glyph.
      throw const FontFormatException(
        'a CID-keyed font used seac, whose character codes cannot be resolved '
        'through a CID charset',
        table: 'CFF ',
      );
    }

    final int last = _size;
    _seacAdx = _stack[last - 4];
    _seacAdy = _stack[last - 3];
    final int baseCode = _stack[last - 2].toInt();
    final int accentCode = _stack[last - 1].toInt();
    _size = 0;

    final int? baseGlyph = _glyphForStandardCode(baseCode);
    final int? accentGlyph = _glyphForStandardCode(accentCode);
    if (baseGlyph == null || accentGlyph == null) {
      throw FontFormatException(
        'seac names Standard Encoding codes $baseCode and $accentCode, and '
        'the font has no glyph for '
        '${baseGlyph == null ? baseCode : accentCode}',
        table: 'CFF ',
      );
    }
    _seacBase = baseGlyph;
    _seacAccent = accentGlyph;
  }

  int? _glyphForStandardCode(int code) {
    if (code < 0 || code > 255) return null;
    final int sid = standardEncoding[code];
    if (sid == 0) return null;
    return _font.charset.glyphForSid(sid);
  }

  /// The `12 xx` operators: arithmetic, storage, and the four flex forms.
  ///
  /// The arithmetic ones do *not* clear the stack - they are meant to compute
  /// operands for the drawing operator that follows - which is why none of
  /// them touches `_size` beyond what they push and pop.
  void _escaped(int b1) {
    switch (b1) {
      case 0: // dotsection
        // Deprecated in Type 2 and specified as a no-op. Accepted silently
        // because it is well-formed, unlike the Type 1 leftovers below.
        _size = 0;

      case 3: // and
        {
          _need(2, 'and');
          final double b = _pop();
          final double a = _pop();
          _push(a != 0 && b != 0 ? 1 : 0);
        }

      case 4: // or
        {
          _need(2, 'or');
          final double b = _pop();
          final double a = _pop();
          _push(a != 0 || b != 0 ? 1 : 0);
        }

      case 5: // not
        _need(1, 'not');
        _push(_pop() == 0 ? 1 : 0);

      case 9: // abs
        _need(1, 'abs');
        _push(_pop().abs());

      case 10: // add
        {
          _need(2, 'add');
          final double b = _pop();
          _push(_pop() + b);
        }

      case 11: // sub
        {
          _need(2, 'sub');
          final double b = _pop();
          _push(_pop() - b);
        }

      case 12: // div
        {
          _need(2, 'div');
          final double b = _pop();
          final double a = _pop();
          if (b == 0) {
            throw const FontFormatException(
              'charstring divides by zero',
              table: 'CFF ',
            );
          }
          _push(a / b);
        }

      case 14: // neg
        _need(1, 'neg');
        _push(-_pop());

      case 15: // eq
        {
          _need(2, 'eq');
          final double b = _pop();
          _push(_pop() == b ? 1 : 0);
        }

      case 18: // drop
        _need(1, 'drop');
        _pop();

      case 20: // put
        {
          _need(2, 'put');
          final int index = _pop().toInt();
          final double value = _pop();
          if (index < 0 || index >= _transientSize) {
            throw FontFormatException(
              'put addresses transient slot $index, outside 0..'
              '${_transientSize - 1}',
              table: 'CFF ',
            );
          }
          _transient[index] = value;
        }

      case 21: // get
        {
          _need(1, 'get');
          final int index = _pop().toInt();
          if (index < 0 || index >= _transientSize) {
            throw FontFormatException(
              'get addresses transient slot $index, outside 0..'
              '${_transientSize - 1}',
              table: 'CFF ',
            );
          }
          _push(_transient[index]);
        }

      case 22: // ifelse
        {
          _need(4, 'ifelse');
          final double v2 = _pop();
          final double v1 = _pop();
          final double s2 = _pop();
          final double s1 = _pop();
          _push(v1 <= v2 ? s1 : s2);
        }

      case 23: // random
        _push(_nextRandom());

      case 24: // mul
        {
          _need(2, 'mul');
          final double b = _pop();
          _push(_pop() * b);
        }

      case 26: // sqrt
        {
          _need(1, 'sqrt');
          final double a = _pop();
          if (a < 0) {
            throw const FontFormatException(
              'charstring takes the square root of a negative number',
              table: 'CFF ',
            );
          }
          _push(_squareRoot(a));
        }

      case 27: // dup
        _need(1, 'dup');
        _push(_stack[_size - 1]);

      case 28: // exch
        {
          _need(2, 'exch');
          final double top = _stack[_size - 1];
          _stack[_size - 1] = _stack[_size - 2];
          _stack[_size - 2] = top;
        }

      case 29: // index
        {
          _need(1, 'index');
          int n = _pop().toInt();
          // A negative index duplicates the top element, per the spec.
          if (n < 0) n = 0;
          _need(n + 1, 'index');
          _push(_stack[_size - 1 - n]);
        }

      case 30: // roll
        {
          _need(2, 'roll');
          final int shift = _pop().toInt();
          final int count = _pop().toInt();
          _roll(count, shift);
        }

      case 34: // hflex
        {
          _need(7, 'hflex');
          // Both curves ride on the starting y: the first ends where it began
          // vertically, and the second undoes dy2. That is the whole reason
          // hflex is shorter than flex.
          final double dy2 = _stack[2];
          _relativeCurve(_stack[0], 0, _stack[1], dy2, _stack[3], 0);
          _relativeCurve(_stack[4], 0, _stack[5], -dy2, _stack[6], 0);
          _size = 0;
        }

      case 35: // flex
        _need(13, 'flex');
        _relativeCurve(
            _stack[0], _stack[1], _stack[2], _stack[3], _stack[4], _stack[5]);
        _relativeCurve(
            _stack[6], _stack[7], _stack[8], _stack[9], _stack[10], _stack[11]);
        // _stack[12] is fd, the flex depth, which only a hinter would use.
        _size = 0;

      case 36: // hflex1
        {
          _need(9, 'hflex1');
          final double dy1 = _stack[1];
          final double dy2 = _stack[3];
          final double dy5 = _stack[7];
          _relativeCurve(_stack[0], dy1, _stack[2], dy2, _stack[4], 0);
          // The final dy returns the pen to the y it started at, which is what
          // makes this a *flex* rather than an arbitrary pair of curves.
          _relativeCurve(
              _stack[5], 0, _stack[6], dy5, _stack[8], -(dy1 + dy2 + dy5));
          _size = 0;
        }

      case 37: // flex1
        {
          _need(11, 'flex1');
          double dx = 0;
          double dy = 0;
          for (int k = 0; k < 10; k += 2) {
            dx += _stack[k];
            dy += _stack[k + 1];
          }
          _relativeCurve(
              _stack[0], _stack[1], _stack[2], _stack[3], _stack[4], _stack[5]);
          // The dominant direction decides which coordinate the last operand
          // supplies; the other closes the flex back onto its starting line.
          if (dx.abs() > dy.abs()) {
            _relativeCurve(
                _stack[6], _stack[7], _stack[8], _stack[9], _stack[10], -dy);
          } else {
            _relativeCurve(
                _stack[6], _stack[7], _stack[8], _stack[9], -dx, _stack[10]);
          }
          _size = 0;
        }

      case 8: // store
      case 13: // load
        throw CffUnsupportedFeature(
          b1 == 8 ? 'store' : 'load',
          'it addresses a multiple-master weight vector, and this parser has '
          'no interpolation machinery to address',
        );

      case 6: // seac (Type 1)
      case 7: // sbw (Type 1)
      case 16: // callothersubr (Type 1)
      case 17: // pop (Type 1)
      case 33: // setcurrentpoint (Type 1)
        throw CffUnsupportedFeature(
          'the Type 1 operator 12 $b1',
          'it appeared in a stream declared as Type 2 charstrings; the two '
              'dialects disagree about what these bytes mean, so continuing '
              'would draw a wrong outline instead of failing',
        );

      default:
        throw FontFormatException(
          'charstring escape operator 12 $b1 is reserved',
          table: 'CFF ',
        );
    }
  }

  /// Rotates the top [count] stack elements by [shift].
  ///
  /// Done in place with a triple reversal rather than by allocating a scratch
  /// list: `roll` is rare, but this runs inside glyph decode and section 6.5
  /// does not carve out an exception for rare.
  void _roll(int count, int shift) {
    if (count <= 0) return;
    _need(count, 'roll');
    final int start = _size - count;
    int by = shift % count;
    if (by < 0) by += count;
    if (by == 0) return;
    _reverse(start, start + count - 1);
    _reverse(start, start + by - 1);
    _reverse(start + by, start + count - 1);
  }

  void _reverse(int from, int to) {
    int low = from;
    int high = to;
    while (low < high) {
      final double swap = _stack[low];
      _stack[low] = _stack[high];
      _stack[high] = swap;
      low++;
      high--;
    }
  }
}

/// Square root without importing `dart:math` for one call.
///
/// Newton-Raphson from a `pow`-free seed. `dart:math`'s `sqrt` would do, but
/// this file otherwise has no imports beyond the font layer and the geometry
/// layer, and `sqrt` on a charstring operand is not a hot path by any measure.
double _squareRoot(double value) {
  if (value == 0) return 0;
  double guess = value;
  for (int i = 0; i < 24; i++) {
    final double next = 0.5 * (guess + value / guess);
    if (next == guess) break;
    guess = next;
  }
  return guess;
}

/// The 391 CFF standard strings, indexed by SID.
///
/// Stored as one space-separated literal and split once, rather than as 391
/// separate literals: the split happens the first time a glyph name is asked
/// for, and a great many faces never ask.
final List<String> standardStrings = _standardStringsPacked.split(' ');

const String _standardStringsPacked = '.notdef space exclam quotedbl '
    'numbersign dollar percent ampersand quoteright parenleft parenright '
    'asterisk plus comma hyphen period slash zero one two three four five '
    'six seven eight nine colon semicolon less equal greater question at '
    'A B C D E F G H I J K L M N O P Q R S T U V W X Y Z '
    'bracketleft backslash bracketright asciicircum underscore quoteleft '
    'a b c d e f g h i j k l m n o p q r s t u v w x y z '
    'braceleft bar braceright asciitilde exclamdown cent sterling fraction '
    'yen florin section currency quotesingle quotedblleft guillemotleft '
    'guilsinglleft guilsinglright fi fl endash dagger daggerdbl '
    'periodcentered paragraph bullet quotesinglbase quotedblbase '
    'quotedblright guillemotright ellipsis perthousand questiondown grave '
    'acute circumflex tilde macron breve dotaccent dieresis ring cedilla '
    'hungarumlaut ogonek caron emdash AE ordfeminine Lslash Oslash OE '
    'ordmasculine ae dotlessi lslash oslash oe germandbls onesuperior '
    'logicalnot mu trademark Eth onehalf plusminus Thorn onequarter divide '
    'brokenbar degree thorn threequarters twosuperior registered minus eth '
    'multiply threesuperior copyright Aacute Acircumflex Adieresis Agrave '
    'Aring Atilde Ccedilla Eacute Ecircumflex Edieresis Egrave Iacute '
    'Icircumflex Idieresis Igrave Ntilde Oacute Ocircumflex Odieresis '
    'Ograve Otilde Scaron Uacute Ucircumflex Udieresis Ugrave Yacute '
    'Ydieresis Zcaron aacute acircumflex adieresis agrave aring atilde '
    'ccedilla eacute ecircumflex edieresis egrave iacute icircumflex '
    'idieresis igrave ntilde oacute ocircumflex odieresis ograve otilde '
    'scaron uacute ucircumflex udieresis ugrave yacute ydieresis zcaron '
    'exclamsmall Hungarumlautsmall dollaroldstyle dollarsuperior '
    'ampersandsmall Acutesmall parenleftsuperior parenrightsuperior '
    'twodotenleader onedotenleader zerooldstyle oneoldstyle twooldstyle '
    'threeoldstyle fouroldstyle fiveoldstyle sixoldstyle sevenoldstyle '
    'eightoldstyle nineoldstyle commasuperior threequartersemdash '
    'periodsuperior questionsmall asuperior bsuperior centsuperior '
    'dsuperior esuperior isuperior lsuperior msuperior nsuperior osuperior '
    'rsuperior ssuperior tsuperior ff ffi ffl parenleftinferior '
    'parenrightinferior Circumflexsmall hyphensuperior Gravesmall Asmall '
    'Bsmall Csmall Dsmall Esmall Fsmall Gsmall Hsmall Ismall Jsmall Ksmall '
    'Lsmall Msmall Nsmall Osmall Psmall Qsmall Rsmall Ssmall Tsmall Usmall '
    'Vsmall Wsmall Xsmall Ysmall Zsmall colonmonetary onefitted rupiah '
    'Tildesmall exclamdownsmall centoldstyle Lslashsmall Scaronsmall '
    'Zcaronsmall Dieresissmall Brevesmall Caronsmall Dotaccentsmall '
    'Macronsmall figuredash hypheninferior Ogoneksmall Ringsmall '
    'Cedillasmall questiondownsmall oneeighth threeeighths fiveeighths '
    'seveneighths onethird twothirds zerosuperior foursuperior '
    'fivesuperior sixsuperior sevensuperior eightsuperior ninesuperior '
    'zeroinferior oneinferior twoinferior threeinferior fourinferior '
    'fiveinferior sixinferior seveninferior eightinferior nineinferior '
    'centinferior dollarinferior periodinferior commainferior Agravesmall '
    'Aacutesmall Acircumflexsmall Atildesmall Adieresissmall Aringsmall '
    'AEsmall Ccedillasmall Egravesmall Eacutesmall Ecircumflexsmall '
    'Edieresissmall Igravesmall Iacutesmall Icircumflexsmall '
    'Idieresissmall Ethsmall Ntildesmall Ogravesmall Oacutesmall '
    'Ocircumflexsmall Otildesmall Odieresissmall OEsmall Oslashsmall '
    'Ugravesmall Uacutesmall Ucircumflexsmall Udieresissmall Yacutesmall '
    'Thornsmall Ydieresissmall 001.000 001.001 001.002 001.003 Black Bold '
    'Book Light Medium Regular Roman Semibold';

/// Standard Encoding, as character code to SID.
///
/// Only `seac` reads this: its `bchar` and `achar` operands are Standard
/// Encoding *character codes*, not glyph ids, and turning one into a glyph
/// means going code to SID to charset to glyph. A zero entry means the code is
/// unassigned, which `seac` must treat as an error rather than as glyph 0.
final Uint8List standardEncoding = Uint8List.fromList(<int>[
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, //
  17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, //
  33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, //
  49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, //
  65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, //
  81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 0, //
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  0, 96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, //
  0, 111, 112, 113, 114, 0, 115, 116, 117, 118, 119, 120, 121, 122, 0, 123, //
  0, 124, 125, 126, 127, 128, 129, 130, 131, 0, 132, 133, 0, 134, 135, 136, //
  137, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  0, 138, 0, 139, 0, 0, 0, 0, 140, 141, 142, 143, 0, 0, 0, 0, //
  0, 144, 0, 0, 0, 145, 0, 0, 146, 147, 148, 149, 0, 0, 0, 0, //
]);
