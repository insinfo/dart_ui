/// The editing model a text field is built on: a value, a selection, an IME
/// composing region, and motion over user-perceived characters.
///
/// This file exists because the three pieces of state a text field carries are
/// **one** value and not three. Text, selection and composing region are
/// mutually constrained - a selection offset only means something against a
/// particular string, and a composing region only means something while that
/// same string is the one the IME is composing into - so a control that stores
/// them as three independent fields has a window, however short, in which they
/// disagree. Every "caret past the end of the string" crash and every "the IME
/// underlined the wrong three characters" bug is that window.
///
/// ## The unit of motion is the grapheme cluster
///
/// Before this file, [TextEditingController] moved its caret by one **UTF-16
/// code unit**. That is wrong three separate ways, and all three are visible:
///
///  * A caret stepping over `😀` (U+1F600, a surrogate pair) lands *between the
///    surrogates*. The string is still well formed, but the next backspace cuts
///    it in half and leaves an unpaired surrogate that encodes nothing.
///  * A caret stepping over decomposed `á` (`a` + U+0301) lands between the
///    letter and its accent. Backspace then deletes the `a` and leaves the
///    accent orphaned, attaching itself to whatever is now in front of it.
///  * A caret stepping over `👨‍👩‍👧` (three emoji and two ZWJs, eight code
///    units) needs eight presses to cross one character, and seven of the eight
///    intermediate positions are inside a cluster.
///
/// So every offset this file produces is a **grapheme cluster boundary** per
/// UAX #29, computed by `GraphemeBreaks`, and [TextEditingValue] refuses to
/// exist with an offset that is not one. The invariant is enforced rather than
/// documented, because a documented invariant is one that holds until somebody
/// is in a hurry.
///
/// ## Indices
///
/// Every offset here is a UTF-16 code unit offset into the value's `text`, the
/// same indexing `GraphemeBreaks`, `WordBreaks`, `GlyphRun.clusters` and
/// `Paragraph` use, so an offset can be handed to `String.substring` and to
/// `Paragraph.getCaretRect` without conversion. Converting at the boundary
/// would only move the off-by-one somewhere less visible.
///
/// ## Limits, stated out loud
///
///  * **Motion is logical, not visual.** [TextMotion] moves toward lower or
///    higher offsets. In bidirectional text the caret therefore moves *toward
///    the start of the string*, which at a direction boundary is not the same
///    as moving physically left. Visual-order caret motion needs the line's
///    reordered runs, which is a `Paragraph` query and a different feature; it
///    is not implemented, and a caret in mixed-direction text will jump across
///    the boundary rather than sliding along it.
///  * **Word motion is UAX #29 default segmentation.** No dictionary, so a run
///    of Thai, Khmer or Japanese without spaces is one segment. That is the
///    annex's own default and it is a plausible caret, not a linguistic
///    analysis. See `word_break.dart`.
///  * **No line motion.** Up/Down and word-wrap-aware Home/End need the line
///    array of a laid-out paragraph. [TextEditingValue] carries no geometry and
///    deliberately does not gain any: a value that knew its own line breaks
///    would be invalidated by a resize.
///  * **The IME itself is not here.** [TextEditingValue.composing] is the
///    contract a platform input method writes into; the Win32 `WM_IME_*`,
///    X11 XIM/ibus and macOS `NSTextInputClient` bridges that would call it are
///    a backend concern. What each of them must call is spelled out on
///    [TextEditingValue.composing] itself so the contract cannot be guessed at.
library;

import '../text/grapheme.dart';
import '../text/paragraph.dart' show TextAffinity, TextPosition;
import '../text/word_break.dart';

export '../text/paragraph.dart' show TextAffinity, TextPosition;

// ---------------------------------------------------------------------------
// Ranges
// ---------------------------------------------------------------------------

/// A half-open range `[start, end)` of UTF-16 offsets, or [TextRange.empty].
///
/// Half-open because that is what `String.substring` takes and what every
/// boundary list in `lib/src/text` produces; a closed range would need a
/// conversion at every call site, and conversions are where off-by-ones live.
///
/// "No range" is spelled [TextRange.empty] - both ends `-1` - rather than as a
/// null or as a zero-length range at some offset. A zero-length range *at an
/// offset* is a meaningful thing (a caret), so overloading it to also mean
/// "absent" would make `composing.start` ambiguous exactly where an IME bridge
/// reads it.
final class TextRange {
  const TextRange(this.start, this.end);

  /// The absent range. Not a range at offset zero: see the class comment.
  static const TextRange empty = TextRange(-1, -1);

  final int start;
  final int end;

  /// Whether this range refers to a stretch of text at all.
  bool get isValid => start >= 0 && end >= 0;

  /// Whether this range is a point rather than a span. False for [empty],
  /// which is not a point but an absence.
  bool get isCollapsed => isValid && start == end;

  /// Length in code units; zero for [empty].
  int get length => isValid ? end - start : 0;

  /// Whether [offset] is inside, treating the range as half-open.
  bool contains(int offset) => isValid && offset >= start && offset < end;

  /// The substring this range names, or `''` for [empty].
  ///
  /// Throws [RangeError] rather than clamping if the range does not fit
  /// [text]: a range that outlives the string it indexed is a bug in the
  /// caller, and silently returning a shorter string would hide it.
  String textInside(String text) => isValid ? text.substring(start, end) : '';

  @override
  bool operator ==(Object other) =>
      other is TextRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => isValid ? 'TextRange($start, $end)' : 'TextRange.empty';
}

/// A selection: an anchor, a moving end, and which side of the moving end the
/// caret belongs to.
///
/// Stored as base/extent rather than as an ordered pair because the *direction*
/// is observable. Shift+Left from a selection made left-to-right shrinks it;
/// Shift+Left from one made right-to-left grows it. Normalising to
/// `(min, max)` on the way in throws that away and makes shift-arrow behave
/// differently depending on how the selection was created - which users notice
/// immediately even though they could not name it.
///
/// [start] and [end] are the ordered view, and they are what every *edit* uses,
/// because replacing a selection cannot care which end the user dragged from.
final class TextSelection {
  const TextSelection({
    required this.baseOffset,
    required this.extentOffset,
    this.affinity = TextAffinity.downstream,
  });

  /// A caret: no selected text, only a position.
  const TextSelection.collapsed(
    int offset, {
    this.affinity = TextAffinity.downstream,
  })  : baseOffset = offset,
        extentOffset = offset;

  /// Where the selection was anchored - the end that does *not* move when the
  /// user extends with Shift.
  final int baseOffset;

  /// The moving end, and where the caret is drawn.
  final int extentOffset;

  /// Which side of [extentOffset] the caret belongs to.
  ///
  /// Only observable where one offset has two positions on screen: a direction
  /// change inside a line, and a soft line break, where the same offset is both
  /// the end of one line and the start of the next. Carrying it is what stops
  /// the caret jumping to the far end of the screen at those two places.
  final TextAffinity affinity;

  int get start => baseOffset <= extentOffset ? baseOffset : extentOffset;

  int get end => baseOffset <= extentOffset ? extentOffset : baseOffset;

  bool get isCollapsed => baseOffset == extentOffset;

  /// Whether the extent is before the base - a selection dragged backwards.
  bool get isReversed => extentOffset < baseOffset;

  /// The ordered range, which is what an edit replaces.
  TextRange get range => TextRange(start, end);

  /// The caret, as something [Paragraph.getCaretRect] can be handed directly.
  TextPosition get extent => TextPosition(extentOffset, affinity: affinity);

  TextSelection copyWith({
    int? baseOffset,
    int? extentOffset,
    TextAffinity? affinity,
  }) =>
      TextSelection(
        baseOffset: baseOffset ?? this.baseOffset,
        extentOffset: extentOffset ?? this.extentOffset,
        affinity: affinity ?? this.affinity,
      );

  @override
  bool operator ==(Object other) =>
      other is TextSelection &&
      other.baseOffset == baseOffset &&
      other.extentOffset == extentOffset &&
      other.affinity == affinity;

  @override
  int get hashCode => Object.hash(baseOffset, extentOffset, affinity);

  @override
  String toString() =>
      'TextSelection($baseOffset, $extentOffset, ${affinity.name})';
}

// ---------------------------------------------------------------------------
// The value
// ---------------------------------------------------------------------------

/// Text, selection and composing region as one immutable value.
///
/// This is section 30.7's editing value. It is the unit a control replaces
/// atomically and the unit an input method hands back, and its invariants are
/// checked in the constructor - so a `TextEditingValue` that exists is one that
/// makes sense, and the failure surfaces at the line that built the nonsense
/// rather than three frames later inside a `substring`.
///
/// ## The invariants, and why each one throws
///
///  1. **Selection offsets lie within the text.** An offset past the end is the
///     classic stale-selection bug: the text shrank and the caret did not.
///     Clamping instead of throwing is what lets it survive to production.
///  2. **Selection offsets sit on grapheme cluster boundaries.** Not on code
///     point boundaries - on *cluster* boundaries. An offset between `a` and
///     its combining acute is a legal string index and an illegal caret, and it
///     is the position from which one backspace produces an orphaned accent.
///  3. **The composing region is [TextRange.empty] or a real, non-inverted,
///     in-bounds, cluster-aligned span.** A collapsed composing region is
///     rejected on purpose: "the IME is composing zero characters" is the same
///     state as "the IME is not composing", and allowing two spellings of one
///     state means every consumer has to test for both and half of them will
///     not.
///
/// The selection is **not** normalised: base and extent are kept as given, so a
/// backwards selection stays backwards. See [TextSelection] for why that is
/// observable. Only [TextSelection.start] and [TextSelection.end] are ordered.
final class TextEditingValue {
  /// Builds a value, checking every invariant.
  ///
  /// Throws [ArgumentError] on any violation. That is the section 6.6 choice:
  /// a caret that has fallen inside a cluster is a bug in whoever computed it,
  /// and repairing it here would move the symptom without moving the cause.
  /// Callers that legitimately hold an arbitrary offset - a hit test, a
  /// deserialised document - snap it first with [TextMotion.snapDown] or
  /// [TextMotion.snapUp], which is one line and says what it chose.
  TextEditingValue({
    this.text = '',
    TextSelection? selection,
    this.composing = TextRange.empty,
  }) : selection = selection ?? TextSelection.collapsed(text.length) {
    _validate();
  }

  /// The empty document: no text, caret at zero, nothing composing.
  static final TextEditingValue empty = TextEditingValue();

  /// The full text. The string every offset in this value indexes.
  final String text;

  /// The selection, or the caret when [TextSelection.isCollapsed].
  final TextSelection selection;

  /// The region an input method is currently composing, or [TextRange.empty].
  ///
  /// **What this is for.** An IME turns several keystrokes into one character.
  /// While it is doing so, the *provisional* text lives in the document - so
  /// that it is laid out, wrapped and drawn in the right font, at the right
  /// place - but it is not yet committed, and the platform can replace or
  /// withdraw all of it. This range is that provisional span. A text field
  /// paints it differently (conventionally an underline), and an edit that is
  /// not from the IME must clear it, because the IME's idea of which characters
  /// it owns is now wrong.
  ///
  /// **The contract each backend has to implement.** None of this is done in
  /// `lib/src/platform` yet, and none of it belongs in this file; what belongs
  /// here is that the shape is fixed so the three bridges cannot each invent
  /// their own:
  ///
  ///  * **Win32.** On `WM_IME_STARTCOMPOSITION`, note the current selection as
  ///    the insertion point. On `WM_IME_COMPOSITION` with `GCS_COMPSTR`, read
  ///    the composition string with `ImmGetCompositionString` and apply it with
  ///    [TextEditingController.replaceComposingRegion]; the cursor position
  ///    comes from `GCS_CURSORPOS` and becomes the collapsed selection. On the
  ///    same message with `GCS_RESULTSTR`, read the result string and call
  ///    [TextEditingController.commitComposing] after applying it. On
  ///    `WM_IME_ENDCOMPOSITION`, call
  ///    [TextEditingController.clearComposing]. The candidate window is
  ///    positioned from `Paragraph.getCaretRect` of
  ///    [TextSelection.extent] via `IMR_QUERYCHARPOSITION`.
  ///  * **X11.** With XIM or ibus over the input-context protocol, the
  ///    preedit-draw callback carries the preedit string and a caret index;
  ///    that is [TextEditingController.replaceComposingRegion] plus a collapsed
  ///    selection. Preedit-done is [TextEditingController.clearComposing], and
  ///    a committed string arrives as an ordinary
  ///    [TextEditingController.replaceSelection]. The preedit *spot* the server
  ///    asks for is again the caret rectangle.
  ///  * **macOS.** `NSTextInputClient` maps almost one to one:
  ///    `setMarkedText:selectedRange:replacementRange:` is
  ///    [TextEditingController.replaceComposingRegion],
  ///    `insertText:replacementRange:` is
  ///    [TextEditingController.commitText], `unmarkText` is
  ///    [TextEditingController.clearComposing], `markedRange` and
  ///    `selectedRange` read back [composing] and [selection], and
  ///    `firstRectForCharacterRange:` is `Paragraph.getBoxesForSelection`.
  ///
  /// The one thing every backend must respect: the ranges it passes are UTF-16
  /// offsets into [text] on cluster boundaries. Win32 and macOS both speak
  /// UTF-16 natively; an X11 bridge working in UTF-8 has to convert, and
  /// converting wrongly shows up as a composing underline under the wrong
  /// characters rather than as a crash - so it is worth a test on the bridge.
  final TextRange composing;

  /// Whether an input method is mid-composition.
  bool get isComposing => composing.isValid && !composing.isCollapsed;

  /// The provisional text, or `''` when nothing is composing.
  String get composingText => composing.textInside(text);

  TextEditingValue copyWith({
    String? text,
    TextSelection? selection,
    TextRange? composing,
  }) =>
      TextEditingValue(
        text: text ?? this.text,
        selection: selection ?? this.selection,
        composing: composing ?? this.composing,
      );

  void _validate() {
    final int limit = text.length;

    void checkOffset(int offset, String name) {
      if (offset < 0 || offset > limit) {
        throw ArgumentError.value(
          offset,
          name,
          'outside the text, which is $limit code units long',
        );
      }
      if (!GraphemeBreaks.isBoundary(text, offset)) {
        throw ArgumentError.value(
          offset,
          name,
          'falls inside a grapheme cluster of ${_describe(text, offset)}; a '
          'caret there would let one keystroke delete half a character',
        );
      }
    }

    checkOffset(selection.baseOffset, 'selection.baseOffset');
    checkOffset(selection.extentOffset, 'selection.extentOffset');

    if (composing == TextRange.empty) return;
    if (!composing.isValid) {
      throw ArgumentError.value(
        composing,
        'composing',
        'a range with one negative end is not a range; the absent composing '
            'region is spelled TextRange.empty',
      );
    }
    if (composing.start > composing.end) {
      throw ArgumentError.value(
        composing,
        'composing',
        'inverted; a composing region has no direction to preserve, unlike a '
            'selection, so it must be given in order',
      );
    }
    if (composing.isCollapsed) {
      throw ArgumentError.value(
        composing,
        'composing',
        'collapsed; "composing nothing" is TextRange.empty, and two spellings '
            'of one state is one spelling too many',
      );
    }
    checkOffset(composing.start, 'composing.start');
    checkOffset(composing.end, 'composing.end');
  }

  /// The cluster [offset] fell inside, quoted, for the error message.
  ///
  /// An error that says only "offset 1 is invalid" sends the reader looking at
  /// the wrong thing; one that says the offset landed inside `á` names
  /// the cause.
  static String _describe(String text, int offset) {
    final int from = GraphemeBreaks.previous(text, offset);
    final int to = GraphemeBreaks.next(text, offset);
    final StringBuffer out = StringBuffer('"');
    for (final int unit in text.substring(from, to).codeUnits) {
      out.write(
        unit >= 0x20 && unit < 0x7F
            ? String.fromCharCode(unit)
            : '\\u${unit.toRadixString(16).padLeft(4, '0').toUpperCase()}',
      );
    }
    return (out..write('"')).toString();
  }

  @override
  bool operator ==(Object other) =>
      other is TextEditingValue &&
      other.text == text &&
      other.selection == selection &&
      other.composing == composing;

  @override
  int get hashCode => Object.hash(text, selection, composing);

  @override
  String toString() => 'TextEditingValue(${text.length} units, $selection, '
      '$composing)';
}

// ---------------------------------------------------------------------------
// Motion
// ---------------------------------------------------------------------------

/// Caret motion over a string, by cluster and by word.
///
/// Static and stateless, like `GraphemeBreaks` and `WordBreaks` themselves: an
/// instance would only invite someone to cache one per text field and then keep
/// using it after an edit, at which point every offset it produces refers to a
/// string that no longer exists.
///
/// **Cost.** Every function here is bounded by the size of the thing it steps
/// over, not by the length of the paragraph, which is what makes holding an
/// arrow key down in a long document linear rather than quadratic:
///
///  * [nextCluster] and [previousCluster] cost the cluster. `GraphemeBreaks`
///    rebuilds its rule state from a bounded point - back over the run of
///    extenders, joiners, jamo or regional indicators plus one character - and
///    not from the start of the string.
///  * [nextWord] and [previousWord] cost the segment crossed plus, for the
///    boundary decision itself, `WordBreaks`' own bounded look-back: the run of
///    regional indicators, plus two items for the three-character rules WB7,
///    WB7c and WB11. Nothing walks the paragraph.
///  * The one loop that is *not* constant is the whitespace skip described on
///    [nextWord]: a caret crossing a run of blank lines does one bounded step
///    per line. That is linear in the whitespace crossed, which is the work the
///    user asked for, and it is stated here rather than left to be discovered.
final class TextMotion {
  const TextMotion._();

  /// The next grapheme cluster boundary after [offset], clamped to the end.
  static int nextCluster(String text, int offset) =>
      GraphemeBreaks.next(text, offset);

  /// The previous grapheme cluster boundary before [offset], clamped to zero.
  static int previousCluster(String text, int offset) =>
      GraphemeBreaks.previous(text, offset);

  /// [offset] itself if it is a cluster boundary, else the **start** of the
  /// cluster containing it.
  ///
  /// The direction is declared rather than "nearest", because nearest is not
  /// well defined for a five-code-point cluster and because a caret that never
  /// moves forward on its own cannot skip over text the user can still see.
  static int snapDown(String text, int offset) {
    final int clamped = offset.clamp(0, text.length);
    return GraphemeBreaks.isBoundary(text, clamped)
        ? clamped
        : GraphemeBreaks.previous(text, clamped);
  }

  /// [offset] itself if it is a cluster boundary, else the **end** of the
  /// cluster containing it.
  ///
  /// The counterpart to [snapDown], and the right one after an *insertion*:
  /// typing `a` in front of a lone combining accent produces one cluster
  /// `á`, and the caret belongs after the accent. Snapping down there
  /// would put the caret in front of the character the user just typed.
  static int snapUp(String text, int offset) {
    final int clamped = offset.clamp(0, text.length);
    return GraphemeBreaks.isBoundary(text, clamped)
        ? clamped
        : GraphemeBreaks.next(text, clamped);
  }

  /// Where `Ctrl+Right` goes from [offset].
  ///
  /// The start of the next word, not the end of the current one: that is what
  /// Windows and the X11 toolkits do, and it is the convention this framework's
  /// two shipped backends live under. macOS moves to the *end* of the next word
  /// instead; that difference is a platform tailoring and it is not applied
  /// here, so a macOS build will feel subtly wrong until somebody adds it.
  ///
  /// Whitespace-only segments are skipped, so `Ctrl+Right` from the start of
  /// `hello world` lands on `w` rather than stopping on the space between them.
  /// A newline is *not* skipped past silently in bulk: each blank line costs
  /// one step, so the caret still stops at the start of each one.
  static int nextWord(String text, int offset) {
    int at = WordBreaks.next(text, offset);
    while (at < text.length) {
      final int segmentEnd = WordBreaks.next(text, at);
      if (!_isBlank(text, at, segmentEnd)) break;
      at = segmentEnd;
    }
    return at;
  }

  /// Where `Ctrl+Left` goes from [offset].
  ///
  /// The start of the word behind the caret, skipping the whitespace in
  /// between, so `Ctrl+Left` from the end of `hello world` lands on `w` and the
  /// press after it lands on `h` - never pausing on the space, which is the
  /// behaviour that makes people press the key twice.
  static int previousWord(String text, int offset) {
    int segmentEnd = offset.clamp(0, text.length);
    int at = WordBreaks.previous(text, segmentEnd);
    while (at > 0 && _isBlank(text, at, segmentEnd)) {
      segmentEnd = at;
      at = WordBreaks.previous(text, at);
    }
    return at;
  }

  /// Whether `[start, end)` is entirely whitespace.
  ///
  /// The set is written out rather than taken from a Unicode property because
  /// the property that would be right - White_Space - includes characters no
  /// caret should skip silently, and because a word-motion rule that depends on
  /// a table is a word-motion rule nobody can predict. These are the separators
  /// UAX #14 and every editor treat as blank.
  static bool _isBlank(String text, int start, int end) {
    if (start >= end) return false;
    for (int i = start; i < end; i++) {
      if (!_isBlankUnit(text.codeUnitAt(i))) return false;
    }
    return true;
  }

  static bool _isBlankUnit(int unit) =>
      (unit >= 0x09 && unit <= 0x0D) || // tab, LF, VT, FF, CR
      unit == 0x20 || // space
      unit == 0x85 || // NEL
      unit == 0xA0 || // no-break space
      unit == 0x1680 || // Ogham space mark
      (unit >= 0x2000 && unit <= 0x200A) || // en quad .. hair space
      unit == 0x2028 || // line separator
      unit == 0x2029 || // paragraph separator
      unit == 0x202F || // narrow no-break space
      unit == 0x205F || // medium mathematical space
      unit == 0x3000; // ideographic space
}
