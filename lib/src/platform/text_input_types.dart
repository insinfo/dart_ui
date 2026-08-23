/// The values an input method and an editor exchange: a composition, the text
/// around the caret, and what kind of text is being edited.
///
/// Split from `text_input.dart` the way `drag_drop_types.dart` is split from
/// `drag_drop.dart`: the interfaces there are the *port*, and a backend that
/// implements them needs these types without needing the port's callbacks.
///
/// ## Why a composition is not just a string
///
/// An input method turns several keystrokes into one character, and while it is
/// doing so it owns a span of provisional text - the *preedit*. Three things
/// about that span are not derivable from the text itself and every platform
/// reports them separately:
///
///  1. **Where the caret is inside it.** A Japanese IME converting
///     `にほんご` puts the caret between clauses, not at the end. Windows
///     reports it as `GCS_CURSORPOS`, Wayland as `preedit_string`'s
///     `cursor_begin`/`cursor_end`, macOS as the `selectedRange` of
///     `setMarkedText:`.
///  2. **Which part of it is being converted right now.** Windows reports one
///     attribute byte per code unit (`GCS_COMPATTR`), which is how a CJK IME
///     shows the user that clause 2 of 4 is the one the candidate window is
///     about. That is [ImeCompositionClause].
///  3. **That it is provisional at all**, which is why it is drawn underlined
///     rather than as ordinary text.
///
/// ## The clause asymmetry, stated rather than smoothed over
///
/// `zwp_text_input_v3` deliberately dropped the styling that `v2` had: its
/// `preedit_string` carries text and a cursor and nothing else. So
/// [ImeComposition.clauses] is populated on Win32 and **empty on Wayland**, and
/// a renderer must treat "no clauses" as "underline the whole preedit" rather
/// than as "draw nothing special". Inventing clause boundaries from the text
/// would be a guess about a foreign language's segmentation, which is exactly
/// the work the input method was doing.
library;

/// How one run of the preedit should be drawn.
///
/// The names are the framework's; the mapping from each platform's own
/// vocabulary lives in that platform's bridge, because only it knows how its
/// numbers are spelled. Windows' `ATTR_*` values map here directly; Wayland
/// v3 reports none of them.
enum ImeCompositionStyle {
  /// Raw input the method has not converted yet. Windows `ATTR_INPUT`.
  input,

  /// Converted text that is *not* the clause under conversion. Windows
  /// `ATTR_CONVERTED`.
  converted,

  /// The clause the candidate window is currently about, converted. Windows
  /// `ATTR_TARGET_CONVERTED`. This is the run a field should emphasise: it is
  /// what the arrow keys are moving through.
  targetConverted,

  /// The clause under the cursor, not yet converted. Windows
  /// `ATTR_TARGET_NOTCONVERTED`.
  targetNotConverted,

  /// The method flagged this run as un-convertible. Windows
  /// `ATTR_INPUT_ERROR`. Drawn as an error, not merely underlined - a user who
  /// cannot see that the IME rejected the run will keep typing into it.
  error,

  /// Converted and locked; further keystrokes will not change it. Windows
  /// `ATTR_FIXEDCONVERTED`.
  fixedConverted,
}

/// One run of a preedit string, in UTF-16 offsets into
/// [ImeComposition.text].
///
/// Half-open, `[start, end)`, and non-empty: a zero-length clause carries no
/// information and would only give two spellings of "no clause here".
final class ImeCompositionClause {
  ImeCompositionClause({
    required this.start,
    required this.end,
    required this.style,
  }) {
    if (start < 0) {
      throw ArgumentError.value(start, 'start', 'must not be negative');
    }
    if (end <= start) {
      throw ArgumentError.value(
        end,
        'end',
        'must be greater than start; an empty clause says nothing',
      );
    }
  }

  final int start;
  final int end;
  final ImeCompositionStyle style;

  @override
  bool operator ==(Object other) =>
      other is ImeCompositionClause &&
      other.start == start &&
      other.end == end &&
      other.style == style;

  @override
  int get hashCode => Object.hash(start, end, style);

  @override
  String toString() => 'ImeCompositionClause($start, $end, ${style.name})';
}

/// The provisional text an input method currently owns, with its caret.
///
/// [ImeComposition.none] is the *absence* of a composition and is what ends
/// one: an empty preedit and "nothing is being composed" are the same state on
/// every platform, and having two spellings of it is how a field ends up
/// painting an underline nobody will ever clear.
final class ImeComposition {
  ImeComposition({
    required this.text,
    this.clauses = const <ImeCompositionClause>[],
    int? cursorStart,
    int? cursorEnd,
  })  : cursorStart = cursorStart ?? text.length,
        cursorEnd = cursorEnd ?? cursorStart ?? text.length {
    if (this.cursorStart != _hiddenCursor) {
      if (this.cursorStart < 0 || this.cursorStart > text.length) {
        throw ArgumentError.value(
          this.cursorStart,
          'cursorStart',
          'outside the preedit (0..${text.length})',
        );
      }
      if (this.cursorEnd < this.cursorStart || this.cursorEnd > text.length) {
        throw ArgumentError.value(
          this.cursorEnd,
          'cursorEnd',
          'must be between cursorStart and the end of the preedit',
        );
      }
    }
    for (final ImeCompositionClause clause in clauses) {
      if (clause.end > text.length) {
        throw ArgumentError.value(
          clause,
          'clauses',
          'runs past the end of a ${text.length}-unit preedit',
        );
      }
    }
  }

  /// No composition. The state a field is in whenever no input method is
  /// mid-conversion, and the value that ends one.
  static final ImeComposition none = ImeComposition(text: '');

  /// The value [cursorStart] takes when the input method asked for the caret
  /// to be *hidden* inside the preedit.
  ///
  /// `zwp_text_input_v3` spells this `cursor_begin == cursor_end == -1`, and it
  /// is a real request rather than an omission: some methods draw their own
  /// caret in the candidate window and a second one in the document is noise.
  static const int _hiddenCursor = -1;

  /// A composition whose caret the input method asked not to be drawn.
  factory ImeComposition.withHiddenCursor(
    String text, {
    List<ImeCompositionClause> clauses = const <ImeCompositionClause>[],
  }) =>
      ImeComposition(
        text: text,
        clauses: clauses,
        cursorStart: _hiddenCursor,
        cursorEnd: _hiddenCursor,
      );

  /// The provisional text, in logical order. Empty means no composition.
  final String text;

  /// Runs of [text] the method wants drawn differently, or empty when the
  /// platform reports none. See the library comment: empty means "underline
  /// all of it", not "draw nothing".
  final List<ImeCompositionClause> clauses;

  /// Where the caret sits inside [text], in UTF-16 units, or -1 when the
  /// method asked for no caret at all.
  final int cursorStart;

  /// The other end of the caret's selection inside [text]. Equal to
  /// [cursorStart] for an ordinary caret.
  final int cursorEnd;

  bool get isEmpty => text.isEmpty;

  bool get isNotEmpty => text.isNotEmpty;

  /// Whether the input method asked for the in-document caret to be hidden.
  bool get hasHiddenCursor => cursorStart == _hiddenCursor;

  @override
  bool operator ==(Object other) =>
      other is ImeComposition &&
      other.text == text &&
      other.cursorStart == cursorStart &&
      other.cursorEnd == cursorEnd &&
      _sameClauses(other.clauses, clauses);

  @override
  int get hashCode => Object.hash(
        text,
        cursorStart,
        cursorEnd,
        Object.hashAll(clauses),
      );

  static bool _sameClauses(
    List<ImeCompositionClause> a,
    List<ImeCompositionClause> b,
  ) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  String toString() => text.isEmpty
      ? 'ImeComposition.none'
      : 'ImeComposition("$text", cursor $cursorStart..$cursorEnd, '
          '${clauses.length} clauses)';
}

/// The document text around the caret, as the input method is allowed to see
/// it.
///
/// **Why an input method wants this at all**: contextual conversion. A Japanese
/// or Chinese method converts the same reading differently depending on the
/// words before it, and a method that never sees the document converts every
/// phrase in isolation. `zwp_text_input_v3.set_surrounding_text` exists for
/// exactly this and is the reason [TextInputClient.surroundingText] is part of
/// the port rather than a Wayland detail.
///
/// **Three rules, each of which is a bug when broken:**
///
///  1. **The preedit is not in [text].** The provisional characters belong to
///     the input method, not to the document; sending them back would make the
///     method see its own output as context and, on Wayland, is an explicit
///     protocol violation.
///  2. **[cursor] and [anchor] are UTF-16 offsets into [text]**, not into the
///     whole document. A backend whose protocol counts UTF-8 bytes (Wayland)
///     converts at its own edge, and converting wrongly shows up as a
///     `delete_surrounding_text` eating the wrong characters.
///  3. **[text] may be a window, not the whole document.** Wayland caps the
///     message at 4000 bytes and a client that exceeds it is disconnected, so
///     a large document is clipped around the caret. Clipping is done on
///     grapheme boundaries by the sender; the offsets always describe [text]
///     as it stands.
final class ImeSurroundingText {
  ImeSurroundingText({
    required this.text,
    required this.cursor,
    int? anchor,
  }) : anchor = anchor ?? cursor {
    if (cursor < 0 || cursor > text.length) {
      throw ArgumentError.value(
        cursor,
        'cursor',
        'outside the surrounding text (0..${text.length})',
      );
    }
    if (this.anchor < 0 || this.anchor > text.length) {
      throw ArgumentError.value(
        this.anchor,
        'anchor',
        'outside the surrounding text (0..${text.length})',
      );
    }
  }

  /// Nothing around the caret: an empty document, or a field that refuses to
  /// share its content (see [TextInputConfiguration.isSensitive]).
  static final ImeSurroundingText empty =
      ImeSurroundingText(text: '', cursor: 0);

  final String text;

  /// The moving end of the selection, in UTF-16 units into [text].
  final int cursor;

  /// The fixed end of the selection. Equal to [cursor] for a plain caret.
  final int anchor;

  bool get hasSelection => cursor != anchor;

  @override
  bool operator ==(Object other) =>
      other is ImeSurroundingText &&
      other.text == text &&
      other.cursor == cursor &&
      other.anchor == anchor;

  @override
  int get hashCode => Object.hash(text, cursor, anchor);

  @override
  String toString() =>
      'ImeSurroundingText(${text.length} units, cursor $cursor, '
      'anchor $anchor)';
}

/// What kind of text a field holds, so the input method can behave sensibly.
///
/// The vocabulary is `zwp_text_input_v3.content_purpose`, because it is the
/// most explicit of the three and the others map onto it rather than the other
/// way round. Win32 has no equivalent enumeration - IMM32 offers only
/// "associate an input context or do not" - so its bridge collapses the whole
/// enumeration to that one bit, which is the honest translation and is
/// documented at the call site.
enum ImeContentPurpose {
  normal,
  alpha,
  digits,
  number,
  phone,
  url,
  email,
  name,
  password,
  pin,
  date,
  time,
  datetime,
  terminal,
}

/// Behaviour hints, `zwp_text_input_v3.content_hint`.
enum ImeContentHint {
  completion,
  spellcheck,
  autoCapitalization,
  lowercase,
  uppercase,
  titlecase,
  hiddenText,
  sensitiveData,
  latin,
  multiline,
}

/// Everything a field tells the input method about itself.
final class TextInputConfiguration {
  const TextInputConfiguration({
    this.purpose = ImeContentPurpose.normal,
    this.hints = const <ImeContentHint>{},
  });

  /// A password field: the purpose that turns composition off entirely on
  /// Win32 and marks the content sensitive on Wayland.
  static const TextInputConfiguration password = TextInputConfiguration(
    purpose: ImeContentPurpose.password,
    hints: <ImeContentHint>{
      ImeContentHint.hiddenText,
      ImeContentHint.sensitiveData,
    },
  );

  final ImeContentPurpose purpose;
  final Set<ImeContentHint> hints;

  /// Whether this field's content must never be handed to an input method.
  ///
  /// The same argument `RenderTextField.copySelection` makes about the
  /// clipboard: an obscured field renders bullets precisely so its value cannot
  /// be read, and `set_surrounding_text` would hand the plaintext to another
  /// process by a different door. So a sensitive field reports
  /// [ImeSurroundingText.empty] rather than its text, and composition itself is
  /// disabled where the platform can disable it.
  bool get isSensitive =>
      purpose == ImeContentPurpose.password ||
      purpose == ImeContentPurpose.pin ||
      hints.contains(ImeContentHint.sensitiveData) ||
      hints.contains(ImeContentHint.hiddenText);

  @override
  bool operator ==(Object other) =>
      other is TextInputConfiguration &&
      other.purpose == purpose &&
      _sameSet(other.hints, hints);

  @override
  int get hashCode => Object.hash(purpose, Object.hashAllUnordered(hints));

  static bool _sameSet(Set<ImeContentHint> a, Set<ImeContentHint> b) =>
      a.length == b.length && a.containsAll(b);

  @override
  String toString() => 'TextInputConfiguration(${purpose.name}, '
      '${hints.map((ImeContentHint hint) => hint.name).join('+')})';
}

/// An input-method operation that did not happen, named.
///
/// The shape of [ClipboardException] and [DragDropException], for the same
/// reason: "the IME did nothing" is not an answer anybody can act on, while
/// "ImmGetContext returned 0 in win32" says the window has no input context and
/// points at the association call that should have made one.
final class TextInputException implements Exception {
  const TextInputException({
    required this.operation,
    required this.reason,
    this.backend,
  });

  /// The call that failed: `ImmGetContext`, `enable`, `set_surrounding_text`.
  final String operation;

  /// Why, in words that name the cause rather than restate the failure.
  final String reason;

  /// Which implementation reported it, when there is one.
  final String? backend;

  @override
  String toString() => 'TextInputException: $operation failed'
      '${backend == null ? '' : ' in $backend'} - $reason';
}
