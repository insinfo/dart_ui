/// `zwp_text_input_v3`: input methods over Wayland, transcribed the way every
/// other protocol in this backend is.
///
/// ## The shape of the protocol, and the two places it bites
///
/// A client binds `zwp_text_input_manager_v3`, asks it for one
/// `zwp_text_input_v3` **per seat**, and from then on:
///
///   * the compositor sends `enter(surface)` / `leave(surface)` to say which of
///     this client's surfaces the input method is aimed at - the object is
///     per-seat, not per-surface, exactly as `wl_data_device` is;
///   * the client sends `enable`, then any of `set_surrounding_text`,
///     `set_content_type`, `set_cursor_rectangle`, `set_text_change_cause`, and
///     finally `commit`, which is what makes all of them take effect;
///   * the compositor sends `preedit_string`, `commit_string` and
///     `delete_surrounding_text` into a pending state, and `done(serial)` to
///     apply it.
///
/// **First bite: the serial is a commit *count*, not a token.** `commit` takes
/// no argument. The compositor counts the commits it has received on the object
/// and puts that count in every `done`. So the client keeps its own count and
/// compares - `done.serial == commitCount` means "this describes the state you
/// last sent"; anything else means the client has moved on since. That
/// comparison is not decoration:
/// `delete_surrounding_text` is expressed in **byte lengths around the cursor
/// of the surrounding text the client last sent**, so applying a stale one
/// deletes the wrong characters. GTK gates exactly this way, and getting it
/// wrong is the classic text-input-v3 bug - it looks like an IME that
/// occasionally eats a character, which is nearly impossible to attribute
/// after the fact. [WaylandTextInputManager] therefore discards a stale
/// deletion and applies the preedit and commit strings, which are absolute and
/// stay correct.
///
/// **Second bite: the order of application is mandated.** The protocol spells
/// it out, and it is not the order the events arrived in:
///
///   1. remove the existing preedit;
///   2. delete the requested surrounding text;
///   3. insert the commit string, caret at its end;
///   4. recompute and send the surrounding text;
///   5. insert the new preedit and place the caret inside it.
///
/// Applying the commit string before removing the old preedit leaves the
/// provisional characters in the document; deleting after committing counts
/// the just-committed characters as surrounding text. Both are silent
/// corruption rather than errors.
///
/// ## What v3 does not carry, and is not faked
///
/// `zwp_text_input_v2` had `preedit_styling`; **v3 removed it**. There is no
/// way for a compositor to say "clause two of four is the one being converted",
/// so [ImeComposition.clauses] is always empty here and a field must fall back
/// to underlining the whole preedit. Synthesising clause boundaries from the
/// text would be a guess about a foreign language's segmentation - which is the
/// work the input method was doing - so this file does not.
///
/// There is also no cancel request. [WaylandTextInputConnection.cancelComposition]
/// therefore disables and re-enables, which the protocol defines as resetting
/// the input method's state, and which is what GTK and Qt both do.
library;

import 'dart:convert';

import '../../geometry/rect.dart';
import '../../platform/native_window.dart';
import '../../platform/text_input.dart';
import '../../platform/window_events.dart';
import 'wayland_protocol.dart';
import 'wayland_window.dart';

/// The protocol operations the manager needs from a connection.
///
/// The seam `WaylandDragDropClient` established: everything below is a request
/// on the wire, so a fake implementation makes the whole state machine testable
/// with no compositor and no socket.
abstract interface class WaylandTextInputClient {
  /// Whether the compositor advertised `zwp_text_input_manager_v3` **and** a
  /// seat to hang it on.
  bool get supportsTextInput;

  void textInputEnable();

  void textInputDisable();

  /// `set_surrounding_text`. [cursorBytes] and [anchorBytes] are **UTF-8 byte**
  /// offsets into [text], which is the protocol's unit and not the framework's.
  void textInputSetSurroundingText(String text, int cursorBytes, int anchorBytes);

  void textInputSetTextChangeCause(int cause);

  void textInputSetContentType(int hint, int purpose);

  /// `set_cursor_rectangle`, in **surface-local** coordinates. No conversion
  /// happens on the way: Wayland surface coordinates are the framework's
  /// logical units, which is the one place this protocol is easier than Win32.
  void textInputSetCursorRectangle(int x, int y, int width, int height);

  /// `commit`. Takes no serial: see the library comment.
  void textInputCommit();
}

// ---------------------------------------------------------------------------
// Offset conversion: the part every UTF-8 protocol gets wrong once
// ---------------------------------------------------------------------------

/// The UTF-8 byte offset of the UTF-16 offset [utf16Offset] in [text].
///
/// Clamped rather than throwing: the caller is usually converting a caret it
/// just derived from a live document, and a one-unit disagreement mid-frame
/// must not take the window down.
int waylandUtf8OffsetOf(String text, int utf16Offset) {
  final int clamped = utf16Offset.clamp(0, text.length);
  if (clamped == 0) return 0;
  if (clamped == text.length) return utf8.encode(text).length;
  return utf8.encode(text.substring(0, clamped)).length;
}

/// The UTF-16 offset of the UTF-8 byte offset [byteOffset] in [text].
///
/// A byte offset that lands **inside** a multi-byte sequence is rounded *down*
/// to the start of that character. That happens for real: an input method
/// computing `delete_surrounding_text` from its own idea of the document can
/// name a boundary this document does not have, and the alternative to rounding
/// is throwing inside an event handler.
int waylandUtf16OffsetOf(String text, int byteOffset) {
  if (byteOffset <= 0) return 0;
  int bytes = 0;
  int index = 0;
  while (index < text.length) {
    if (bytes >= byteOffset) return index;
    final int unit = text.codeUnitAt(index);
    final int width;
    final int units;
    if (unit >= 0xD800 && unit <= 0xDBFF && index + 1 < text.length) {
      // A surrogate pair is one 4-byte UTF-8 sequence and two UTF-16 units.
      width = 4;
      units = 2;
    } else if (unit < 0x80) {
      width = 1;
      units = 1;
    } else if (unit < 0x800) {
      width = 2;
      units = 1;
    } else {
      width = 3;
      units = 1;
    }
    // The offset lands inside this character: round down to its start rather
    // than past it. Rounding up would put a caret - or the end of a deletion -
    // one character further than the input method asked for.
    if (bytes + width > byteOffset) return index;
    bytes += width;
    index += units;
  }
  return text.length;
}

/// A window of [text] around the caret that fits in [maxBytes] of UTF-8.
///
/// The protocol does not warn a client that oversteps `set_surrounding_text`'s
/// 4000-byte limit; it **disconnects** it. So a large document is clipped, and
/// clipped around the caret rather than from the start, because the characters
/// an input method can use are the ones next to what is being typed.
///
/// Clipping is done on UTF-16 code-unit boundaries that are also character
/// boundaries - a surrogate pair is never split - and the returned offsets
/// describe the clipped string, which is what the protocol will see.
({String text, int cursor, int anchor}) waylandClipSurroundingText(
  String text,
  int cursor,
  int anchor, {
  int maxBytes = zwpTextInputV3SurroundingTextMaxBytes,
}) {
  if (utf8.encode(text).length <= maxBytes) {
    return (text: text, cursor: cursor, anchor: anchor);
  }
  // Half the budget on each side of the caret, in code units. Four bytes per
  // code unit is the worst case, so this can never overshoot the byte cap and
  // never needs a second pass.
  final int halfUnits = maxBytes ~/ 8;
  final int low = cursor < anchor ? cursor : anchor;
  final int high = cursor < anchor ? anchor : cursor;
  int start = (low - halfUnits).clamp(0, text.length);
  int end = (high + halfUnits).clamp(0, text.length);
  // Never between the halves of a surrogate pair: the offsets would be legal
  // and the string would contain a lone surrogate, which utf8.encode turns
  // into a replacement character and the input method into nonsense.
  if (start > 0 && _isLowSurrogate(text.codeUnitAt(start))) start -= 1;
  if (end < text.length && _isLowSurrogate(text.codeUnitAt(end))) end += 1;
  return (
    text: text.substring(start, end),
    cursor: cursor - start,
    anchor: anchor - start,
  );
}

bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

/// The `content_hint` bitmask for a set of framework hints.
int waylandContentHintBits(Set<ImeContentHint> hints) {
  int bits = zwpTextInputV3ContentHintNone;
  for (final ImeContentHint hint in hints) {
    bits |= switch (hint) {
      ImeContentHint.completion => zwpTextInputV3ContentHintCompletion,
      ImeContentHint.spellcheck => zwpTextInputV3ContentHintSpellcheck,
      ImeContentHint.autoCapitalization =>
        zwpTextInputV3ContentHintAutoCapitalization,
      ImeContentHint.lowercase => zwpTextInputV3ContentHintLowercase,
      ImeContentHint.uppercase => zwpTextInputV3ContentHintUppercase,
      ImeContentHint.titlecase => zwpTextInputV3ContentHintTitlecase,
      ImeContentHint.hiddenText => zwpTextInputV3ContentHintHiddenText,
      ImeContentHint.sensitiveData => zwpTextInputV3ContentHintSensitiveData,
      ImeContentHint.latin => zwpTextInputV3ContentHintLatin,
      ImeContentHint.multiline => zwpTextInputV3ContentHintMultiline,
    };
  }
  return bits;
}

/// The `content_purpose` value for a framework purpose.
///
/// One-to-one, and deliberately so: [ImeContentPurpose] was taken from this
/// enumeration precisely because it is the most explicit of the three
/// platforms' and the others collapse into it rather than the reverse.
int waylandContentPurposeValue(ImeContentPurpose purpose) => switch (purpose) {
      ImeContentPurpose.normal => zwpTextInputV3ContentPurposeNormal,
      ImeContentPurpose.alpha => zwpTextInputV3ContentPurposeAlpha,
      ImeContentPurpose.digits => zwpTextInputV3ContentPurposeDigits,
      ImeContentPurpose.number => zwpTextInputV3ContentPurposeNumber,
      ImeContentPurpose.phone => zwpTextInputV3ContentPurposePhone,
      ImeContentPurpose.url => zwpTextInputV3ContentPurposeUrl,
      ImeContentPurpose.email => zwpTextInputV3ContentPurposeEmail,
      ImeContentPurpose.name => zwpTextInputV3ContentPurposeName,
      ImeContentPurpose.password => zwpTextInputV3ContentPurposePassword,
      ImeContentPurpose.pin => zwpTextInputV3ContentPurposePin,
      ImeContentPurpose.date => zwpTextInputV3ContentPurposeDate,
      ImeContentPurpose.time => zwpTextInputV3ContentPurposeTime,
      ImeContentPurpose.datetime => zwpTextInputV3ContentPurposeDatetime,
      ImeContentPurpose.terminal => zwpTextInputV3ContentPurposeTerminal,
    };

// ---------------------------------------------------------------------------
// The state machine
// ---------------------------------------------------------------------------

/// The `zwp_text_input_v3` state machine, with no socket in it.
///
/// Everything with a protocol rule lives here: the commit count, the pending
/// double-buffered state, the mandated order of application and the staleness
/// gate. `WaylandTextInputBackend` is the seam to the framework's port and does
/// bookkeeping only.
final class WaylandTextInputManager {
  WaylandTextInputManager(this._client);

  final WaylandTextInputClient _client;

  /// Resolves the surface the compositor named to the field focused in it.
  ///
  /// Set by the backend, which is the only thing that knows the mapping - the
  /// manager sees `wl_surface` ids and the port speaks about windows and
  /// clients.
  TextInputClient? Function(int surfaceId)? clientForSurface;

  /// The surface the input method is currently aimed at, or 0.
  int get focusedSurfaceId => _focusedSurfaceId;
  int _focusedSurfaceId = 0;

  /// How many `commit` requests have been issued on the object. This is the
  /// number a `done` event's serial is compared against; see the library
  /// comment for why the comparison is load-bearing.
  int get commitCount => _commitCount;
  int _commitCount = 0;

  /// The serial of the last `done`, for diagnostics.
  int get lastDoneSerial => _lastDoneSerial;
  int _lastDoneSerial = -1;

  /// Whether `enable` has been sent and not yet undone.
  bool get isEnabled => _enabled;
  bool _enabled = false;

  /// The `TextInputClient` the framework attached, when one is focused.
  TextInputClient? _attachedClient;

  /// Pending incoming state, replaced by `done`. All three are cleared on
  /// every `done` whether or not it was applied, because the protocol's
  /// double buffer is emptied by the apply and a leftover would be applied
  /// twice.
  String? _pendingPreeditText;
  int _pendingPreeditCursorBeginBytes = 0;
  int _pendingPreeditCursorEndBytes = 0;
  String? _pendingCommitString;
  int _pendingDeleteBeforeBytes = 0;
  int _pendingDeleteAfterBytes = 0;

  /// Whether a preedit is currently in the document.
  bool get isComposing => _composing;
  bool _composing = false;

  /// The surrounding text last sent, which is the string
  /// `delete_surrounding_text`'s byte lengths are measured against.
  String _sentSurroundingText = '';
  int _sentSurroundingCursor = 0;
  int _sentSurroundingAnchor = 0;
  Rect? _sentCaretRect;
  TextInputConfiguration? _sentConfiguration;

  bool get supportsTextInput => _client.supportsTextInput;

  // -------------------------------------------------------------------------
  // Events from the compositor
  // -------------------------------------------------------------------------

  /// `zwp_text_input_v3.enter`.
  ///
  /// The input method is now aimed at [surfaceId]. All state was reset by the
  /// compositor, so a client that was already enabled has to say so again -
  /// which is what re-enabling does here rather than assuming continuity.
  void onEnter(int surfaceId) {
    _focusedSurfaceId = surfaceId;
    final TextInputClient? client = clientForSurface?.call(surfaceId);
    if (client == null) return;
    _attachedClient = client;
    if (_enabled) {
      // Not "already enabled, nothing to do": `enter` resets the object's
      // state, so the surrounding text, content type and cursor rectangle the
      // compositor holds are the protocol defaults again.
      _enabled = false;
      enable(client);
    }
  }

  /// `zwp_text_input_v3.leave`.
  ///
  /// The composition dies with the focus. Anything provisional is dropped
  /// rather than committed, for the reason `TextInputConnection.disable`
  /// gives: the characters were never accepted.
  void onLeave(int surfaceId) {
    if (surfaceId != _focusedSurfaceId) return;
    _abandonComposition();
    _focusedSurfaceId = 0;
    _enabled = false;
    _attachedClient = null;
    _resetSentState();
  }

  /// `zwp_text_input_v3.preedit_string`. Staged until `done`.
  void onPreeditString(String text, int cursorBeginBytes, int cursorEndBytes) {
    _pendingPreeditText = text;
    _pendingPreeditCursorBeginBytes = cursorBeginBytes;
    _pendingPreeditCursorEndBytes = cursorEndBytes;
  }

  /// `zwp_text_input_v3.commit_string`. Staged until `done`.
  void onCommitString(String text) => _pendingCommitString = text;

  /// `zwp_text_input_v3.delete_surrounding_text`. Staged until `done`.
  ///
  /// The lengths are **UTF-8 bytes** relative to the cursor of the surrounding
  /// text this client last sent, which is why [_sentSurroundingText] is kept
  /// and why a stale `done` throws this away.
  void onDeleteSurroundingText(int beforeBytes, int afterBytes) {
    _pendingDeleteBeforeBytes = beforeBytes;
    _pendingDeleteAfterBytes = afterBytes;
  }

  /// `zwp_text_input_v3.done`: apply the pending state, in the protocol's own
  /// order.
  ///
  /// Returns whether anything reached a client, which is what the tests assert
  /// on and what a diagnostic counts.
  bool onDone(int serial) {
    _lastDoneSerial = serial;
    final String? preedit = _pendingPreeditText;
    final String? commit = _pendingCommitString;
    final int deleteBefore = _pendingDeleteBeforeBytes;
    final int deleteAfter = _pendingDeleteAfterBytes;
    final int preeditCursorBegin = _pendingPreeditCursorBeginBytes;
    final int preeditCursorEnd = _pendingPreeditCursorEndBytes;
    _clearPending();

    final TextInputClient? client = _attachedClient;
    if (client == null) return false;

    // The gate. A `done` whose serial is not this client's commit count
    // describes a state the client has already replaced, and
    // `delete_surrounding_text`'s byte lengths are measured against the
    // surrounding text of *that* state. The preedit and commit strings are
    // absolute and stay correct, so only the deletion is discarded.
    final bool current = serial == _commitCount;
    final bool deleting = (deleteBefore > 0 || deleteAfter > 0) && current;

    bool applied = false;

    // 1. Remove the existing preedit - but only when something else is about
    //    to change the document underneath it. When the whole transaction is
    //    "here is a new preedit", replacing it in one step is the same result
    //    and keeps a composing session to a single undo entry, which is the
    //    rule `TextEditingController.replaceComposingRegion` documents.
    if (_composing && (deleting || (commit != null && commit.isNotEmpty))) {
      client.updateComposition(ImeComposition.none);
      _composing = false;
      applied = true;
    }

    // 2. Delete around the caret, in the framework's UTF-16 units.
    if (deleting) {
      client.deleteSurroundingText(
        beforeLength: _unitsBeforeCursor(deleteBefore),
        afterLength: _unitsAfterCursor(deleteAfter),
      );
      applied = true;
    }

    // 3. Commit.
    if (commit != null && commit.isNotEmpty) {
      client.commitText(commit);
      _composing = false;
      applied = true;
    }

    // 5. The new preedit. (4, recomputing the surrounding text, is
    //    `updateEditingState`, which the field calls once the document has
    //    settled - doing it here would send the state before the edit above
    //    had been applied to the document.)
    if (preedit != null) {
      if (preedit.isEmpty) {
        if (_composing) {
          client.updateComposition(ImeComposition.none);
          _composing = false;
          applied = true;
        }
      } else {
        final int cursorStart = preeditCursorBegin < 0
            ? -1
            : waylandUtf16OffsetOf(preedit, preeditCursorBegin);
        final int cursorEnd = preeditCursorEnd < 0
            ? -1
            : waylandUtf16OffsetOf(preedit, preeditCursorEnd);
        client.updateComposition(
          cursorStart < 0 || cursorEnd < 0
              // cursor_begin == cursor_end == -1 is the protocol's request for
              // no caret at all, not a missing value.
              ? ImeComposition.withHiddenCursor(preedit)
              : ImeComposition(
                  text: preedit,
                  cursorStart: cursorStart,
                  cursorEnd: cursorEnd < cursorStart ? cursorStart : cursorEnd,
                ),
        );
        _composing = true;
        applied = true;
      }
    }
    // Step 4 of the protocol's own ordering, done once for the whole
    // transaction rather than once per part. The field deliberately does not
    // push state from inside the callbacks above: each push is a `commit`, and
    // three commits for one `done` would leave this client's count permanently
    // ahead of the compositor's replies and make the next
    // `delete_surrounding_text` look stale and be discarded.
    if (applied) updateEditingState();
    return applied;
  }

  int _unitsBeforeCursor(int bytes) {
    final int cursorBytes =
        waylandUtf8OffsetOf(_sentSurroundingText, _sentSurroundingCursor);
    final int start = waylandUtf16OffsetOf(
      _sentSurroundingText,
      cursorBytes - bytes < 0 ? 0 : cursorBytes - bytes,
    );
    final int units = _sentSurroundingCursor - start;
    return units < 0 ? 0 : units;
  }

  int _unitsAfterCursor(int bytes) {
    final int cursorBytes =
        waylandUtf8OffsetOf(_sentSurroundingText, _sentSurroundingCursor);
    final int end =
        waylandUtf16OffsetOf(_sentSurroundingText, cursorBytes + bytes);
    final int units = end - _sentSurroundingCursor;
    return units < 0 ? 0 : units;
  }

  // -------------------------------------------------------------------------
  // Requests from the framework
  // -------------------------------------------------------------------------

  /// Sends `enable` and the full state, then `commit`.
  ///
  /// The full state and not a delta: `enable` resets everything the compositor
  /// holds to the protocol defaults, so an implementation that only sent what
  /// had changed since the last field would leave the new one described by the
  /// old one's content type.
  void enable(TextInputClient client) {
    if (!supportsTextInput) return;
    _attachedClient = client;
    if (_enabled) {
      // Already on. Re-reading the configuration is how a field that turned
      // read-only stops being composed into without re-attaching.
      _resetSentState();
      _pushState(client, cause: zwpTextInputV3ChangeCauseOther);
      return;
    }
    _client.textInputEnable();
    _enabled = true;
    _resetSentState();
    _pushState(client, cause: zwpTextInputV3ChangeCauseOther);
  }

  /// Sends `disable` and `commit`, abandoning any composition first.
  void disable() {
    if (!_enabled) return;
    _abandonComposition();
    _client.textInputDisable();
    _enabled = false;
    _resetSentState();
    _commit();
  }

  /// Pushes the caret rectangle, the surrounding text and the content type,
  /// then commits - but only when something actually changed.
  ///
  /// The guard is not an optimisation. A `commit` bumps the count every `done`
  /// is compared against, so committing on every keystroke that changed
  /// nothing would keep the client's count permanently ahead of the
  /// compositor's replies and make every `delete_surrounding_text` look stale.
  void updateEditingState() {
    final TextInputClient? client = _attachedClient;
    if (!_enabled || client == null) return;
    _pushState(client, cause: zwpTextInputV3ChangeCauseOther);
  }

  void _pushState(TextInputClient client, {required int cause}) {
    bool dirty = false;

    final TextInputConfiguration configuration =
        client.textInputConfiguration;
    if (configuration != _sentConfiguration) {
      _sentConfiguration = configuration;
      _client.textInputSetContentType(
        waylandContentHintBits(configuration.hints),
        waylandContentPurposeValue(configuration.purpose),
      );
      dirty = true;
    }

    // A sensitive field sends nothing at all rather than an empty string with
    // a cursor: `ImeSurroundingText.empty` is what the client hands over, and
    // sending it is both harmless and honest - the input method is told there
    // is no context, which is exactly true.
    final ImeSurroundingText surrounding = client.surroundingText;
    final ({String text, int cursor, int anchor}) clipped =
        waylandClipSurroundingText(
      surrounding.text,
      surrounding.cursor,
      surrounding.anchor,
    );
    if (clipped.text != _sentSurroundingText ||
        clipped.cursor != _sentSurroundingCursor ||
        clipped.anchor != _sentSurroundingAnchor) {
      _sentSurroundingText = clipped.text;
      _sentSurroundingCursor = clipped.cursor;
      _sentSurroundingAnchor = clipped.anchor;
      _client.textInputSetSurroundingText(
        clipped.text,
        waylandUtf8OffsetOf(clipped.text, clipped.cursor),
        waylandUtf8OffsetOf(clipped.text, clipped.anchor),
      );
      _client.textInputSetTextChangeCause(cause);
      dirty = true;
    }

    final Rect caret = client.caretRect;
    if (caret != _sentCaretRect) {
      _sentCaretRect = caret;
      _client.textInputSetCursorRectangle(
        caret.left.round(),
        caret.top.round(),
        caret.width.round(),
        caret.height.round(),
      );
      dirty = true;
    }

    if (dirty) _commit();
  }

  void _commit() {
    _client.textInputCommit();
    _commitCount++;
  }

  /// Drops a composition without committing it, telling the field so.
  void _abandonComposition() {
    if (!_composing) return;
    _composing = false;
    _attachedClient?.updateComposition(ImeComposition.none);
  }

  void _clearPending() {
    _pendingPreeditText = null;
    _pendingPreeditCursorBeginBytes = 0;
    _pendingPreeditCursorEndBytes = 0;
    _pendingCommitString = null;
    _pendingDeleteBeforeBytes = 0;
    _pendingDeleteAfterBytes = 0;
  }

  void _resetSentState() {
    _sentSurroundingText = '';
    _sentSurroundingCursor = 0;
    _sentSurroundingAnchor = 0;
    _sentCaretRect = null;
    _sentConfiguration = null;
  }

  /// Forgets the attached client without touching the wire. Called when the
  /// framework detaches a field that is not the focused one any more.
  void forget(TextInputClient client) {
    if (!identical(_attachedClient, client)) return;
    _abandonComposition();
    _attachedClient = null;
  }

  void dispose() {
    _attachedClient = null;
    _composing = false;
    _enabled = false;
    _clearPending();
    _resetSentState();
  }
}

// ---------------------------------------------------------------------------
// The port half
// ---------------------------------------------------------------------------

/// `zwp_text_input_v3` behind the framework's [TextInputBackend] contract.
///
/// Small on purpose, the way `WaylandDragDropBackend` is: everything with a
/// protocol rule stayed in [WaylandTextInputManager], and what is here is the
/// bookkeeping the port asks for and the protocol does not have - one client
/// per *window*, from an object that is per *seat*.
final class WaylandTextInputBackend implements TextInputBackend {
  WaylandTextInputBackend(this._manager) {
    _manager.clientForSurface = _clientForSurface;
  }

  final WaylandTextInputManager _manager;

  final Map<int, WaylandTextInputConnection> _bySurface =
      <int, WaylandTextInputConnection>{};

  @override
  String get name => 'text-input-v3';

  @override
  bool get supportsComposition => _manager.supportsTextInput;

  /// True, and it is the reason surrounding text is on the port at all.
  @override
  bool get usesSurroundingText => true;

  TextInputClient? _clientForSurface(int surfaceId) =>
      _bySurface[surfaceId]?.client;

  @override
  TextInputConnection attach({
    required NativeWindow window,
    required TextInputClient client,
  }) {
    if (window is! WaylandWindow) {
      throw TextInputException(
        operation: 'attach',
        reason: 'a Wayland text input is aimed at a wl_surface and '
            '${window.runtimeType} has none',
        backend: name,
      );
    }
    if (!_manager.supportsTextInput) {
      throw const TextInputException(
        operation: 'attach',
        reason: 'the compositor advertises no zwp_text_input_manager_v3, so '
            'there is no input method to attach to; plain typing still works '
            'through wl_keyboard',
        backend: 'text-input-v3',
      );
    }
    final int surfaceId = window.surfaceId;
    // One field per surface: a second attach replaces the first, because focus
    // moving between two fields in one window is exactly that and not two
    // simultaneously focused fields.
    _bySurface.remove(surfaceId)?._forget();
    final connection = WaylandTextInputConnection._(
      backend: this,
      manager: _manager,
      windowId: window.id,
      surfaceId: surfaceId,
      client: client,
    );
    _bySurface[surfaceId] = connection;
    return connection;
  }

  void _detach(WaylandTextInputConnection connection) {
    if (identical(_bySurface[connection._surfaceId], connection)) {
      _bySurface.remove(connection._surfaceId);
    }
  }
}

/// One focused field's association with the seat's `zwp_text_input_v3`.
final class WaylandTextInputConnection implements TextInputConnection {
  WaylandTextInputConnection._({
    required WaylandTextInputBackend backend,
    required WaylandTextInputManager manager,
    required NativeWindowId windowId,
    required int surfaceId,
    required this.client,
  })  : _backend = backend,
        _manager = manager,
        _windowId = windowId,
        _surfaceId = surfaceId;

  final WaylandTextInputBackend _backend;
  final WaylandTextInputManager _manager;
  final NativeWindowId _windowId;
  final int _surfaceId;

  /// The field this connection speaks for.
  final TextInputClient client;

  bool _attached = true;
  bool _enabled = false;

  @override
  NativeWindowId get windowId => _windowId;

  @override
  bool get isAttached => _attached;

  @override
  bool get isEnabled => _enabled;

  @override
  void enable() {
    if (!_attached) return;
    // A field that refuses to share its content also refuses composition: an
    // input method with a candidate window full of somebody's password is the
    // same leak as putting it on the clipboard, and Wayland's `sensitive_data`
    // hint is advisory where this is not.
    if (client.textInputConfiguration.isSensitive) {
      disable();
      return;
    }
    _manager.enable(client);
    _enabled = true;
  }

  @override
  void disable() {
    if (!_attached) return;
    _manager.disable();
    _enabled = false;
  }

  @override
  void updateEditingState() {
    if (!_attached || !_enabled) return;
    _manager.updateEditingState();
  }

  /// Resets the input method.
  ///
  /// There is no cancel request in v3. Disabling and re-enabling is what the
  /// protocol defines as clearing the method's state, and is what GTK and Qt
  /// both do for the same reason; the preedit is dropped on the way through
  /// [WaylandTextInputManager.disable].
  @override
  void cancelComposition() {
    if (!_attached || !_enabled) return;
    _manager.disable();
    _manager.enable(client);
  }

  @override
  void detach() {
    if (!_attached) return;
    _forget();
    _backend._detach(this);
  }

  void _forget() {
    if (_enabled) {
      _manager.disable();
      _enabled = false;
    }
    _manager.forget(client);
    _attached = false;
  }
}
