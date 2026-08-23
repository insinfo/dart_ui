/// Text entry: the editing model, the clipboard scope and the field itself.
///
/// Split out of `controls.dart` because it was a third of it - 1.6k lines of
/// 3.7k - and because it is the part that keeps growing. Everything the caret
/// learned recently landed here (grapheme clusters, word motion, the
/// clipboard, selection as N rectangles, the composing range an input method
/// needs), and what is queued lands here too: a multi-line variant, native
/// IME, and caret motion in visual order.
///
/// That is the criterion, and it is not size. A large file nobody edits costs
/// nothing; this is the one where separate pieces of work collide. The rest of
/// `controls.dart` - button, checkbox, radio, switch, slider, progress - is
/// small and settled, and splitting it would buy a longer import list and
/// nothing else.
///
/// `controls.dart` re-exports this file, so no existing import changes.
library;

import '../foundation/diagnostics.dart' show UnsupportedCapabilityError;
import '../foundation/value_notifier.dart';
import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/color.dart';
import '../graphics/display_list.dart';
import '../layout/render_box.dart';
import '../platform/clipboard.dart';
import '../platform/input_events.dart';
import '../platform/native_window.dart';
import '../platform/text_input.dart';
import '../rendering/text/font_registry.dart';
import '../text/paragraph.dart' show Paragraph, TextBox;
import '../text/shaper.dart' show UnsupportedScriptException;
import '../text/typeface.dart' show ScaledTypeface;
import 'context_menu.dart';
import 'control.dart';
import 'element.dart';
import 'focus.dart';
import 'focus_scope.dart';
import 'keyboard_router.dart';
import 'menu.dart';
import 'semantics.dart';
import 'text_editing.dart';
import 'theme.dart';
import 'widget.dart';

/// The editing model is part of this file's contract, not an implementation
/// detail of it: a caller holding a [TextEditingController] needs
/// [TextEditingValue], [TextSelection] and [TextRange] to say anything about
/// it.
export 'text_editing.dart';

// ---------------------------------------------------------------------------
// Observable values and text editing state
// ---------------------------------------------------------------------------

/// Text, a selection and an IME composing region, which are one value and not
/// three.
///
/// Keeping them together is what makes an edit atomic: replacing a selection
/// changes the text and collapses the caret in a single notification, so no
/// listener can observe a caret pointing past the end of the string. The whole
/// triple is available as a [TextEditingValue] through [editingValue], which is
/// the unit an input method reads and writes.
///
/// ## Every offset here is a grapheme cluster boundary
///
/// This class used to move its caret and delete by one **UTF-16 code unit**,
/// which put the caret between the halves of a surrogate pair and let one
/// backspace cut `😀` in half or strip the accent off a decomposed `á` and
/// leave it hanging on the letter before. Motion now goes through [TextMotion],
/// which goes through `GraphemeBreaks` (UAX #29), and every offset that enters
/// this class from outside is snapped to a cluster boundary - see
/// [setSelection] for the direction it snaps and why.
///
/// The invariant is *also* checked, not merely maintained: [_pushUndo] and
/// [editingValue] both build a [TextEditingValue], whose constructor throws on
/// a mid-cluster offset. So the undo stack doubles as an assertion that this
/// controller has never put its caret somewhere illegal.
///
/// ## Limits, stated out loud
///
///  * **Motion is logical.** Left means "toward offset zero", not "toward the
///    left edge of the screen". In bidirectional text those differ, and the
///    caret will jump across a direction boundary rather than sliding along it.
///    Visual-order motion needs the reordered runs of a laid-out line; see
///    `text_editing.dart`.
///  * **No line motion.** Up, Down and wrap-aware Home/End need the line array
///    of a `Paragraph`. Home and End here go to the ends of the whole value.
///  * **The undo stack is unbounded and per-edit.** No coalescing of runs of
///    typing into one entry, and no cap, so a very long session holds every
///    intermediate string. Both are real and both are deliberate for now: the
///    coalescing policy is a timing question, and a cap without one silently
///    throws away the entries a user is most likely to want.
final class TextEditingController extends ValueNotifier<String> {
  TextEditingController([super.value = '']) {
    _base = value.length;
    _extent = value.length;
  }

  int _base = 0;
  int _extent = 0;
  TextAffinity _affinity = TextAffinity.downstream;
  TextRange _composing = TextRange.empty;
  final List<TextEditingValue> _undo = <TextEditingValue>[];
  final List<TextEditingValue> _redo = <TextEditingValue>[];

  /// The anchor of the selection: the end Shift does *not* move.
  int get selectionStart => _base;

  /// The moving end of the selection, and where the caret is drawn.
  int get selectionEnd => _extent;

  bool get hasSelection => _base != _extent;

  /// The selection with its ends ordered, which is what every edit needs.
  ({int start, int end}) get orderedSelection => _base <= _extent
      ? (start: _base, end: _extent)
      : (start: _extent, end: _base);

  String get selectedText {
    final ({int start, int end}) range = orderedSelection;
    return value.substring(range.start, range.end);
  }

  /// The caret's side of its offset; see [TextSelection.affinity].
  TextAffinity get affinity => _affinity;

  /// The region an input method is composing into, or [TextRange.empty].
  TextRange get composing => _composing;

  bool get isComposing => _composing.isValid;

  /// The whole editing state as one immutable value.
  ///
  /// Building it validates it, so reading this getter is also a self-check.
  TextEditingValue get editingValue => TextEditingValue(
        text: value,
        selection: TextSelection(
          baseOffset: _base,
          extentOffset: _extent,
          affinity: _affinity,
        ),
        composing: _composing,
      );

  /// Replaces the whole editing state in one notification.
  ///
  /// This is the atomic apply point an IME bridge should use when it has a
  /// complete new state rather than a delta. It does **not** push an undo
  /// entry: like `value =`, it is an assignment of state rather than a user
  /// edit, and a bridge that wants the change to be undoable pushes its own
  /// entry by going through [replaceSelection] or [commitText] instead.
  set editingValue(TextEditingValue next) {
    if (next == editingValue) return;
    silentValue = next.text;
    _base = next.selection.baseOffset;
    _extent = next.selection.extentOffset;
    _affinity = next.selection.affinity;
    _composing = next.composing;
    notifyListeners();
  }

  /// Replaces the text, keeping the selection where it still fits.
  ///
  /// The order matters and it changed: the selection is repaired *before*
  /// listeners are told, so no listener can see a caret pointing past the end
  /// of the new string. Any composing region is dropped, because the input
  /// method's idea of which characters it owns cannot survive a wholesale
  /// replacement it did not make.
  @override
  set value(String value) {
    if (value == this.value) return;
    silentValue = value;
    _composing = TextRange.empty;
    _normalizeSelection();
    notifyListeners();
  }

  /// Places the selection, snapping both ends onto grapheme cluster
  /// boundaries.
  ///
  /// Snapping rather than throwing, because this is where arbitrary offsets
  /// legitimately arrive: a hit test, a restored document, an accessibility
  /// client. The direction is **down** - an offset inside a cluster becomes
  /// that cluster's start - which is declared rather than "nearest" because
  /// nearest is not well defined for a seven-code-point family emoji, and
  /// because a selection that only ever shrinks toward the start cannot swallow
  /// a character the caller never named. Callers that want the invariant
  /// *enforced* instead of repaired build a [TextEditingValue].
  void setSelection(
    int start,
    int end, {
    TextAffinity affinity = TextAffinity.downstream,
  }) {
    _base = TextMotion.snapDown(value, start);
    _extent = TextMotion.snapDown(value, end);
    _affinity = affinity;
    notifyListeners();
  }

  void collapseTo(int offset) => setSelection(offset, offset);

  /// Collapses the caret to a position that already carries an affinity, which
  /// is what `Paragraph.getPositionForOffset` returns from a hit test.
  void collapseToPosition(TextPosition position) => setSelection(
        position.offset,
        position.offset,
        affinity: position.affinity,
      );

  void selectAll() => setSelection(0, value.length);

  /// Replaces the selection with [replacement] and collapses the caret after
  /// it.
  ///
  /// The caret snaps **up** afterwards, not down: typing `a` in front of a lone
  /// combining accent makes the two into one cluster, and the caret belongs
  /// after the accent rather than in front of the letter that was just typed.
  void replaceSelection(String replacement) {
    final ({int start, int end}) range = orderedSelection;
    _pushUndo();
    final String next =
        '${value.substring(0, range.start)}$replacement${value.substring(range.end)}';
    silentValue = next;
    _collapseTo(TextMotion.snapUp(next, range.start + replacement.length));
    _composing = TextRange.empty;
    notifyListeners();
  }

  /// Deletes backwards: the selection if there is one, otherwise **one
  /// grapheme cluster**.
  ///
  /// One cluster, so backspace over `👨‍👩‍👧` removes the whole family rather
  /// than the last of its three faces, and backspace over decomposed `á`
  /// removes letter and accent together instead of leaving an orphan.
  void deleteBackward() {
    if (hasSelection) {
      replaceSelection('');
      return;
    }
    _deleteRange(TextMotion.previousCluster(value, _extent), _extent);
  }

  /// Deletes forwards, the Delete key, one grapheme cluster at a time.
  void deleteForward() {
    if (hasSelection) {
      replaceSelection('');
      return;
    }
    _deleteRange(_extent, TextMotion.nextCluster(value, _extent));
  }

  /// Ctrl+Backspace: deletes back to the start of the previous word, taking the
  /// whitespace in between with it.
  ///
  /// At offset zero this does nothing at all - no notification, no undo entry -
  /// rather than deleting "the empty word", which is the shape of bug that
  /// leaves an undo stack full of no-ops.
  void deleteWordBackward() {
    if (hasSelection) {
      replaceSelection('');
      return;
    }
    _deleteRange(TextMotion.previousWord(value, _extent), _extent);
  }

  /// Ctrl+Delete: deletes forward to the start of the next word.
  void deleteWordForward() {
    if (hasSelection) {
      replaceSelection('');
      return;
    }
    _deleteRange(_extent, TextMotion.nextWord(value, _extent));
  }

  /// Moves the caret by [delta] **grapheme clusters**, extending the selection
  /// when [extend].
  ///
  /// The unit changed: [delta] used to be a count of UTF-16 code units, so
  /// `moveCaret(1)` could land inside a surrogate pair. It is now a count of
  /// user-perceived characters, which is what an arrow key means. The sign is
  /// the direction and the magnitude is the number of clusters, so
  /// `moveCaret(-3)` is three presses of Left.
  void moveCaret(int delta, {bool extend = false}) {
    int target = _extent;
    for (int i = 0; i < delta.abs(); i++) {
      target = delta < 0
          ? TextMotion.previousCluster(value, target)
          : TextMotion.nextCluster(value, target);
    }
    if (extend) {
      _extent = target;
    } else {
      // Collapsing a selection with an arrow key lands on the edge you moved
      // toward, which is what every platform's text field does.
      final ({int start, int end}) range = orderedSelection;
      _collapseTo(
          hasSelection ? (delta < 0 ? range.start : range.end) : target);
    }
    _affinity = TextAffinity.downstream;
    notifyListeners();
  }

  /// Ctrl+Left and Ctrl+Right: moves the caret one word, extending when
  /// [extend].
  ///
  /// [direction] is a sign, not a count: negative is toward the start. Zero
  /// does nothing rather than being read as "one step in some direction".
  ///
  /// Unlike [moveCaret], a word move with a selection and without [extend] does
  /// not merely collapse to the edge - it moves a whole word from the extent,
  /// which is what Ctrl+Left does in every editor that has both keys.
  ///
  /// **Cost.** Bounded per press: `WordBreaks` reconstructs its rule context
  /// from a bounded point - back over the run of regional indicators plus two
  /// items, for the three-character rules WB7, WB7c and WB11 - so a press costs
  /// the segment it crosses and not the paragraph. The one unbounded-looking
  /// part is skipping blank segments, which costs one bounded step per blank
  /// line crossed; see [TextMotion.nextWord].
  void moveCaretByWord(int direction, {bool extend = false}) {
    if (direction == 0) return;
    final int target = direction < 0
        ? TextMotion.previousWord(value, _extent)
        : TextMotion.nextWord(value, _extent);
    if (extend) {
      _extent = target;
    } else {
      _collapseTo(target);
    }
    _affinity = TextAffinity.downstream;
    notifyListeners();
  }

  void moveCaretToStart({bool extend = false}) {
    _extent = 0;
    if (!extend) _base = 0;
    _affinity = TextAffinity.downstream;
    notifyListeners();
  }

  void moveCaretToEnd({bool extend = false}) {
    _extent = value.length;
    if (!extend) _base = value.length;
    // Upstream: the caret at the end of the text belongs to the run that ends
    // there, which is the only answer that keeps it beside the last character
    // when that character is right-to-left.
    _affinity = TextAffinity.upstream;
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Input method composition
  // -------------------------------------------------------------------------

  /// Replaces the composing region - or the selection, when no composition is
  /// under way - with the input method's provisional text.
  ///
  /// This is the one call every backend's "set composition string" path lands
  /// on: `WM_IME_COMPOSITION`/`GCS_COMPSTR` on Win32, the XIM preedit-draw
  /// callback on X11, `setMarkedText:selectedRange:replacementRange:` on macOS.
  ///
  /// [caretOffset] is the caret's position **within** [composingText], in code
  /// units, which is how all three platforms report it; null puts the caret at
  /// its end.
  ///
  /// A composing session pushes **one** undo entry, taken when the session
  /// starts. Pushing one per keystroke of a Japanese conversion would make a
  /// single Ctrl+Z undo one hiragana of a word the user experienced as one
  /// action.
  ///
  /// If the platform hands back a span that cuts a cluster - which it can, when
  /// the surrounding text combines with the provisional text - the region is
  /// widened outwards to whole clusters. Widened rather than narrowed: a
  /// narrowed region would paint part of the provisional text as though it were
  /// already committed.
  void replaceComposingRegion(String composingText, {int? caretOffset}) {
    final int start;
    final int end;
    if (_composing.isValid) {
      start = _composing.start;
      end = _composing.end;
    } else {
      final ({int start, int end}) range = orderedSelection;
      start = range.start;
      end = range.end;
      _pushUndo();
    }
    final String next =
        '${value.substring(0, start)}$composingText${value.substring(end)}';
    silentValue = next;
    if (composingText.isEmpty) {
      _composing = TextRange.empty;
    } else {
      _composing = TextRange(
        TextMotion.snapDown(next, start),
        TextMotion.snapUp(next, start + composingText.length),
      );
    }
    _collapseTo(
      TextMotion.snapUp(
        next,
        start +
            (caretOffset ?? composingText.length)
                .clamp(0, composingText.length),
      ),
    );
    notifyListeners();
  }

  /// Accepts the provisional text as it stands and ends the composition.
  ///
  /// The text does not change; the region stops being provisional and the caret
  /// moves to its end. This is the `GCS_RESULTSTR` path once the result string
  /// has already been applied, and macOS's `insertText:` when the marked text
  /// and the inserted text are the same string.
  void commitComposing() {
    if (!_composing.isValid) return;
    _collapseTo(_composing.end);
    _composing = TextRange.empty;
    notifyListeners();
  }

  /// Commits [text] over the composing region, or over the selection when
  /// nothing is composing.
  ///
  /// macOS `insertText:replacementRange:`; Win32 `GCS_RESULTSTR`; an X11
  /// commit string.
  void commitText(String text) {
    if (!_composing.isValid) {
      replaceSelection(text);
      return;
    }
    final int start = _composing.start;
    final String next =
        '${value.substring(0, start)}$text${value.substring(_composing.end)}';
    silentValue = next;
    _composing = TextRange.empty;
    _collapseTo(TextMotion.snapUp(next, start + text.length));
    notifyListeners();
  }

  /// Drops the composing region without touching the text or the caret.
  ///
  /// `WM_IME_ENDCOMPOSITION`, XIM preedit-done, `unmarkText`. Distinct from
  /// [commitComposing], which also moves the caret to the end of the region:
  /// this one is "the input method has stopped telling me about this span",
  /// which can happen with the caret anywhere.
  void clearComposing() {
    if (!_composing.isValid) return;
    _composing = TextRange.empty;
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Undo
  // -------------------------------------------------------------------------

  bool get canUndo => _undo.isNotEmpty;

  bool get canRedo => _redo.isNotEmpty;

  void undo() {
    if (_undo.isEmpty) return;
    _redo.add(editingValue);
    _restore(_undo.removeLast());
  }

  void redo() {
    if (_redo.isEmpty) return;
    _undo.add(editingValue);
    _restore(_redo.removeLast());
  }

  /// Restores a recorded state, **without** its composing region.
  ///
  /// A composing region belongs to a live input-method session, and undoing
  /// back into one would leave the field painting an underline that no IME is
  /// behind and that nothing will ever clear.
  void _restore(TextEditingValue state) {
    silentValue = state.text;
    _base = state.selection.baseOffset;
    _extent = state.selection.extentOffset;
    _affinity = state.selection.affinity;
    _composing = TextRange.empty;
    notifyListeners();
  }

  void _pushUndo() {
    // Built through TextEditingValue on purpose: its constructor rejects a
    // mid-cluster offset, so every edit path is checked against the invariant
    // rather than trusted to have kept it.
    _undo.add(editingValue);
    // A new edit invalidates the redo branch; keeping it would let redo
    // resurrect text the user has since replaced.
    _redo.clear();
  }

  /// Deletes [beforeLength] units before the caret and [afterLength] after it.
  ///
  /// `zwp_text_input_v3.delete_surrounding_text`, which an input method uses to
  /// replace text it did not compose - a Korean method rewriting the previous
  /// syllable, a predictive method correcting the word before the caret.
  ///
  /// Three rules, each of which is a bug when broken:
  ///
  ///  * **Both lengths are clamped, never refused.** A method that asks to
  ///    delete more than exists is not malfunctioning; it is working from a
  ///    document snapshot that has since changed. Refusing leaves its idea of
  ///    the text permanently ahead of this one's, and the next thing it sends
  ///    lands in the wrong place.
  ///  * **The boundaries snap outward to whole clusters.** A length that cuts
  ///    a surrogate pair or separates a letter from its combining accent would
  ///    leave the text well-formed and meaningless, and `TextEditingValue`
  ///    rejects the offsets outright.
  ///  * **Any composing region goes.** The characters around the caret are
  ///    changing, so the input method's idea of which span it owns is now
  ///    wrong; keeping the range would underline text that nothing will clear.
  void deleteSurrounding({required int beforeLength, required int afterLength}) {
    if (beforeLength <= 0 && afterLength <= 0) return;
    final ({int start, int end}) range = orderedSelection;
    final int from = TextMotion.snapDown(
      value,
      (range.start - beforeLength).clamp(0, value.length),
    );
    final int to = TextMotion.snapUp(
      value,
      (range.end + afterLength).clamp(0, value.length),
    );
    _deleteRange(from, to);
  }

  /// Removes `[from, to)`, collapsing the caret where the text was.
  ///
  /// Silent and free when the range is empty, which is what makes backspace at
  /// offset zero and Delete at the end do nothing at all rather than pushing an
  /// undo entry that restores the same string.
  void _deleteRange(int from, int to) {
    if (from >= to) return;
    _pushUndo();
    silentValue = value.substring(0, from) + value.substring(to);
    _collapseTo(from);
    _composing = TextRange.empty;
    notifyListeners();
  }

  void _collapseTo(int offset) {
    _base = offset;
    _extent = offset;
    _affinity = TextAffinity.downstream;
  }

  /// Brings the selection back inside the text and onto cluster boundaries
  /// after the text has changed underneath it.
  void _normalizeSelection() {
    _base = TextMotion.snapDown(value, _base.clamp(0, value.length));
    _extent = TextMotion.snapDown(value, _extent.clamp(0, value.length));
  }
}

// ---------------------------------------------------------------------------
// Button and toggles
// ---------------------------------------------------------------------------

/// A push button.

// ---------------------------------------------------------------------------
// Text entry
// ---------------------------------------------------------------------------

/// The Insert key, `VK_INSERT`.
///
/// Private to this file rather than added beside the other key constants in
/// `focus.dart`: that file belongs to focus and traversal, and the only reason
/// this key exists here is the pre-Ctrl+X clipboard idiom - Ctrl+Insert to
/// copy, Shift+Insert to paste, Shift+Delete to cut - which people who learned
/// it on a terminal still use daily.
const int _logicalKeyInsert = 0x2D;

/// Publishes the platform clipboard to a subtree.
///
/// The same shape as [Theme], and installed at the same place - the
/// application wraps the root widget in one - because a clipboard is ambient in
/// exactly the way a theme is: every text field needs it, none of them should
/// be handed one by its parent, and a global would make it impossible for a
/// test to run two applications in one process with different clipboards.
///
/// A subtree with no scope above it gets an [UnavailableClipboard], so a
/// control mounted alone in a widget test still works and a Ctrl+V in it fails
/// by name instead of throwing on a null.
final class ClipboardScope extends InheritedWidget {
  const ClipboardScope({
    super.key,
    required this.clipboard,
    required super.child,
  });

  final Clipboard clipboard;

  /// The nearest clipboard, or one that fails by name when there is none.
  static Clipboard of(BuildContext context) =>
      maybeOf(context) ??
      const UnavailableClipboard(
        'no ClipboardScope is installed above this control; an application '
        'installs one from ApplicationOptions.clipboard',
      );

  /// The nearest clipboard, or null - for a caller that wants to hide a menu
  /// item rather than show one that will fail.
  static Clipboard? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ClipboardScope>()?.clipboard;

  @override
  bool updateShouldNotify(ClipboardScope oldWidget) =>
      !identical(clipboard, oldWidget.clipboard);
}

/// One run of a preedit, ready to paint: a document range and how the input
/// method wants it drawn.
///
/// The style-to-pixels mapping lives here rather than in `text_input_types.dart`
/// because it is a *rendering* decision and the port must not carry one: the
/// same [ImeCompositionStyle] should be able to look different in a different
/// theme, and a platform enum that dictated a thickness would be a platform
/// enum dictating a design.
final class _CompositionRun {
  const _CompositionRun(this.start, this.end, this.style);

  final int start;
  final int end;
  final ImeCompositionStyle style;

  /// How thick the underline is, in logical units.
  ///
  /// Two pixels for the clause under conversion and one for everything else,
  /// which is the convention every desktop IME host uses and which survives
  /// being drawn at 1x. A *colour* difference alone would be invisible to a
  /// user who cannot distinguish it, and this is the one cue that says which
  /// clause the arrow keys are moving through.
  double get thickness => switch (style) {
        ImeCompositionStyle.targetConverted ||
        ImeCompositionStyle.targetNotConverted =>
          2,
        _ => 1,
      };

  /// The underline colour.
  ///
  /// An error run is drawn in the theme's danger colour when it has one:
  /// `ATTR_INPUT_ERROR` means the method could not convert those characters,
  /// and a user who cannot see that will keep typing into a run that will never
  /// become anything.
  Color color(ThemeData theme) => switch (style) {
        ImeCompositionStyle.error => theme.colorScheme.error,
        _ => theme.foreground,
      };
}

/// Publishes the platform's input method, and the window it belongs to, to a
/// subtree.
///
/// The shape of [ClipboardScope], installed in the same place and for the same
/// reason - every text field needs it, none of them should be handed one by its
/// parent - with one difference that is not cosmetic: **the window travels with
/// it**. An input method is attached to a window, not to an application: a
/// composition belongs to one `HWND` or one `wl_surface`, and a field that
/// could not name its own window would have nothing to attach to. That is the
/// same argument `DragDropScope` makes for carrying [window], and it is why
/// this cannot simply hang off the application the way the clipboard does.
///
/// A subtree with no scope above it composes nothing at all and keeps working:
/// plain typing arrives as `TextInputEvent` from the platform's own keyboard
/// translation and never goes through here. See
/// [RenderTextField.textInputError] for how a field reports the difference.
final class TextInputScope extends InheritedWidget {
  const TextInputScope({
    super.key,
    required this.textInput,
    required this.window,
    required super.child,
  });

  final TextInputBackend textInput;

  /// The window this subtree is mounted in, or null in a test that mounted a
  /// tree with no window behind it.
  ///
  /// Null disables composition rather than failing: a headless widget test has
  /// no window and must still be able to type.
  final NativeWindow? window;

  /// The nearest input method, or one that refuses by name when there is none.
  static TextInputBackend of(BuildContext context) =>
      maybeOf(context)?.textInput ??
      const UnavailableTextInput(
        name: 'none',
        reason: 'no TextInputScope is installed above this control; an '
            'application installs one from the backend it selected',
      );

  /// The nearest scope, for a caller that needs the window as well.
  static TextInputScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TextInputScope>();

  @override
  bool updateShouldNotify(TextInputScope oldWidget) =>
      !identical(textInput, oldWidget.textInput) ||
      !identical(window, oldWidget.window);
}

/// What a field does with its selection while some *other* control in the same
/// window holds the keyboard.
///
/// ## There is no cross-platform consensus, so this is a property
///
/// It used to be a fixed policy in this file, justified by a claim that turns
/// out to be false. The platforms actually split three ways:
///
///  * **Hidden.** A Win32 `EDIT` control hides its selection on losing focus;
///    `ES_NOHIDESEL` exists precisely to *opt out* of that, which is the
///    clearest possible statement of what the default is. WPF agrees -
///    `TextBoxBase.IsInactiveSelectionHighlightEnabled` defaults to false - and
///    so does every browser's `<input>`.
///  * **Shown.** Avalonia's `TextBox.IsInactiveSelectionHighlightEnabled`
///    defaults to **true**, and Avalonia also skips its clear-on-blur path
///    entirely while a context menu is open, so that right-clicking a selection
///    cannot destroy it.
///
/// Two respectable toolkits, opposite defaults. That is the definition of a
/// thing that must be the application's choice.
///
/// ## What this is *not* evidence about
///
/// `NSColor.unemphasizedSelectedTextBackgroundColor` on macOS and GTK's
/// `:backdrop` are **window-inactive** states: they describe a window that has
/// lost activation to another application, not a control that has lost focus to
/// its neighbour. Citing them here - as an earlier version of this comment did
/// - is using window-level evidence to justify control-level behaviour, and
/// they are listed now only so nobody reaches for them again.
///
/// ## The third state, named but not implemented
///
/// There are really three: this field focused, another control in this window
/// focused, and **the whole window deactivated**. Only the first two exist
/// here. The third has a home already - [FocusManager.isWindowActive], which
/// the window backend sets from `WM_ACTIVATE` - and the socket for it is
/// [RenderTextField.selectionColorFor], which would take a second bool and pick
/// a third colour. Nothing calls it that way yet, and inventing the colour
/// before there is a signal to drive it would be untestable.
enum InactiveSelectionHighlight {
  /// Not painted at all: the Win32, WPF and browser behaviour.
  hidden,

  /// Painted, muted. Keeps the range visible - so a user who selected a phrase
  /// and then clicked something else can still see what the next command will
  /// apply to - while making it unambiguous which field the keyboard is in.
  dimmed,

  /// Painted exactly as if focused: `ES_NOHIDESEL`.
  visible,
}

final class TextField extends StatefulWidget {
  const TextField({
    super.key,
    required this.controller,
    this.focusNode,
    this.label = '',
    this.obscure = false,
    this.readOnly = false,
    this.enabled = true,
    this.inactiveSelection = InactiveSelectionHighlight.dimmed,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String label;

  /// How the selection is painted when another control holds the keyboard.
  ///
  /// Defaults to [InactiveSelectionHighlight.dimmed], which is the behaviour
  /// this field has always had; it is defensible as a default because it is the
  /// only one of the three that loses no information, and it is now only a
  /// default rather than a law. An application that wants the Win32 and browser
  /// behaviour asks for [InactiveSelectionHighlight.hidden].
  ///
  /// **The controller's range is never touched by any of these**: this decides
  /// a colour, not a selection. Losing focus must not lose the selection, or
  /// right-clicking a field - which moves focus to the menu - would silently
  /// discard what the user was about to copy.
  final InactiveSelectionHighlight inactiveSelection;

  /// Renders the value as bullets. Section 30.8 requires the *value* still be
  /// the real text; only the painting changes, so copy remains the caller's
  /// policy rather than something a display trick decides.
  final bool obscure;

  final bool readOnly;
  final bool enabled;

  @override
  State<TextField> createState() => _TextFieldState();
}

/// A password field: a text field that never paints its value.
final class PasswordField extends StatelessWidget {
  const PasswordField({super.key, required this.controller, this.label = ''});

  final TextEditingController controller;
  final String label;

  @override
  Widget build(BuildContext context) =>
      TextField(controller: controller, label: label, obscure: true);
}

final class _TextFieldState extends State<TextField> {
  FocusNode? _ownedFocusNode;

  FocusNode get _focusNode =>
      widget.focusNode ??
      (_ownedFocusNode ??= FocusNode(debugLabel: 'TextField'));

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void didUpdateWidget(TextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onTextChanged);
      widget.controller.addListener(_onTextChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    _ownedFocusNode?.dispose();
    super.dispose();
  }

  void _onTextChanged(String value) {
    // The render object repaints itself; the element rebuilds only so that a
    // caller reading the value in build() sees the new one.
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => FocusAttachment(
        node: _focusNode,
        child: _TextFieldRenderWidget(
          controller: widget.controller,
          label: widget.label,
          obscure: widget.obscure,
          readOnly: widget.readOnly,
          enabled: widget.enabled,
          inactiveSelection: widget.inactiveSelection,
          theme: Theme.of(context),
          // Read where the theme is read, and for the same reason: the field
          // must not be handed a clipboard by its parent, and must not reach
          // for a global one.
          clipboard: ClipboardScope.of(context),
          // Null when no scope is installed, and that is a supported state: a
          // field without one answers a secondary click by moving the caret and
          // opening nothing, rather than failing.
          contextMenu: ContextMenuScope.maybeOf(context),
          // Null when no scope is installed, which is the state of every
          // headless widget test: the field then composes nothing and types
          // exactly as it does today. See [TextInputScope].
          textInputScope: TextInputScope.maybeOf(context),
          focusNode: _focusNode,
        ),
      );
}

final class _TextFieldRenderWidget extends RenderObjectWidget {
  const _TextFieldRenderWidget({
    required this.controller,
    required this.label,
    required this.obscure,
    required this.readOnly,
    required this.enabled,
    required this.inactiveSelection,
    required this.theme,
    required this.clipboard,
    required this.contextMenu,
    required this.textInputScope,
    required this.focusNode,
  });

  final TextEditingController controller;
  final String label;
  final bool obscure;
  final bool readOnly;
  final bool enabled;
  final InactiveSelectionHighlight inactiveSelection;
  final ThemeData theme;
  final Clipboard clipboard;
  final ContextMenuController? contextMenu;
  final TextInputScope? textInputScope;
  final FocusNode focusNode;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderTextField createRenderObject(BuildContext context) => RenderTextField(
        controller: controller,
        label: label,
        obscure: obscure,
        readOnly: readOnly,
      )
        ..inactiveSelection = inactiveSelection
        ..theme = theme
        ..clipboard = clipboard
        ..contextMenu = contextMenu
        ..focusNode = focusNode
        ..enabled = enabled
        // Last: attaching the input method reads the configuration, which
        // `obscure` and `enabled` decide.
        ..setTextInput(textInputScope?.textInput, textInputScope?.window);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderTextField object,
  ) {
    object
      ..controller = controller
      ..label = label
      ..obscure = obscure
      ..readOnly = readOnly
      ..inactiveSelection = inactiveSelection
      ..theme = theme
      ..clipboard = clipboard
      ..contextMenu = contextMenu
      ..focusNode = focusNode
      ..enabled = enabled
      ..setTextInput(textInputScope?.textInput, textInputScope?.window);
  }
}

final class RenderTextField extends RenderBox
    with ControlBehavior
    implements TextInputTarget, TextInputClient {
  RenderTextField({
    required TextEditingController controller,
    required String label,
    required bool obscure,
    required bool readOnly,
  })  : _controller = controller,
        _label = label,
        _obscure = obscure,
        _readOnly = readOnly {
    _controller.addListener(_onValueChanged);
  }

  TextEditingController _controller;
  String _label;
  bool _obscure;
  bool _readOnly;
  InactiveSelectionHighlight _inactiveSelection =
      InactiveSelectionHighlight.dimmed;
  Clipboard _clipboard = const UnavailableClipboard();

  /// The platform's input method, and the window it composes into.
  ///
  /// Both null is the ordinary state of a widget test and of any tree mounted
  /// without a [TextInputScope]: the field then composes nothing, and typing -
  /// which arrives as [TextInputEvent] from the platform's own keyboard
  /// translation - is unaffected.
  TextInputBackend? _textInput;
  NativeWindow? _textInputWindow;
  TextInputConnection? _textInputConnection;

  /// The clauses of the current preedit, as the input method described them.
  ///
  /// Empty while nothing is composing **and** while composing on a platform
  /// that reports no clauses at all - `zwp_text_input_v3` removed the styling
  /// its predecessor had. The two are not distinguished on purpose: a renderer
  /// that has no clauses underlines the whole preedit, which is right in both
  /// cases.
  List<ImeCompositionClause> _compositionClauses =
      const <ImeCompositionClause>[];

  /// Whether the input method asked for no caret inside the preedit.
  bool _hidesCompositionCaret = false;

  /// Why the last input-method operation did not happen, or null.
  ///
  /// The shape of [lastClipboardError] and for its reason: "this field does not
  /// compose" is a question a caller can ask, and answering it needs the reason
  /// rather than a bool. A field on a backend with no IME carries the
  /// [TextInputException] that `attach` refused with.
  TextInputException? get textInputError => _textInputError;
  TextInputException? _textInputError;

  ClipboardException? _lastClipboardError;
  Future<void> _clipboardWork = Future<void>.value();

  /// What the last clipboard probe found, or null when the answer is not known
  /// yet - which is a genuinely different state from "empty" and is why this is
  /// a nullable bool rather than a bool. See [buildContextMenuItems].
  bool? _clipboardHasText;

  /// Whether the open context menu is *this* field's.
  ///
  /// Opening one moves the keyboard to the menu, so without this the field
  /// would go inactive and dim the very selection the menu is about to copy.
  /// Avalonia solves the same problem the same way, by exempting an open
  /// context flyout from its lost-focus handling.
  bool _menuOpen = false;

  /// Whether a drag begun on this field is still selecting.
  bool _dragging = false;

  /// 1, 2 or 3: how many clicks the last press was part of.
  int _clickCount = 0;
  Duration _lastClickAt = Duration.zero;
  Offset _lastClickPosition = Offset.zero;

  /// The modifiers reported by the most recent key transition.
  ///
  /// **This is a workaround and it is the one place a Shift+click can be
  /// wrong.** [PointerEvent] in this framework carries no modifier set - only
  /// [KeyEvent] does - so the only way to know whether Shift was down when the
  /// mouse went down is to remember what the last key transition said. That is
  /// accurate for the ordinary sequence (press Shift, click) *while this field
  /// has focus*, because pressing Shift is itself a key transition that arrives
  /// here. It is wrong in exactly one case: Shift was already held before this
  /// field got focus, so no key event has reached it yet, and the click
  /// collapses the caret instead of extending. The real fix is a modifier set
  /// on [PointerEvent], which every backend already samples - `win32_window`
  /// calls `GetKeyState` for each key event and could do the same for each
  /// mouse message - and which this work does not own.
  Set<KeyModifier> _modifiers = const <KeyModifier>{};

  /// How long after a click a second one still counts as a double click, **on
  /// a platform that did not count for us**.
  ///
  /// 500 ms is the Windows default (`GetDoubleClickTime`), and it is only ever
  /// a fallback: when [PointerDownEvent.clickCount] is above 1 the platform
  /// already matched the two presses against the interval and the rectangle the
  /// *user* configured, and that answer wins over this constant. X11 reports no
  /// count, so this is what a click there is measured against.
  static const Duration _multiClickInterval = Duration(milliseconds: 500);

  /// How far the pointer may move between clicks of one multi-click, in
  /// logical units. Without it, two clicks at opposite ends of the field count
  /// as a double click and select a word nobody pointed at.
  static const double _multiClickSlop = 4;

  TextEditingController get controller => _controller;

  set controller(TextEditingController value) {
    if (identical(value, _controller)) return;
    _controller.removeListener(_onValueChanged);
    _controller = value..addListener(_onValueChanged);
    markNeedsPaint();
  }

  String get label => _label;

  set label(String value) {
    if (value == _label) return;
    _label = value;
    markNeedsPaint();
  }

  bool get obscure => _obscure;

  set obscure(bool value) {
    if (value == _obscure) return;
    _obscure = value;
    markNeedsPaint();
  }

  bool get readOnly => _readOnly;

  set readOnly(bool value) {
    if (value == _readOnly) return;
    _readOnly = value;
    markNeedsPaint();
  }

  /// How the selection is painted while another control holds the keyboard.
  InactiveSelectionHighlight get inactiveSelection => _inactiveSelection;

  set inactiveSelection(InactiveSelectionHighlight value) {
    if (value == _inactiveSelection) return;
    _inactiveSelection = value;
    markNeedsPaint();
  }

  /// Where a secondary click opens its menu, or null when no
  /// [ContextMenuScope] encloses this field.
  ///
  /// A plain field: it is a route out, not state this control paints from, so
  /// swapping it invalidates nothing.
  ContextMenuController? contextMenu;

  /// Where Ctrl+C, Ctrl+X and Ctrl+V go.
  ///
  /// Defaults to [UnavailableClipboard] rather than to null, so that a field
  /// mounted without a [ClipboardScope] answers a paste with a named failure in
  /// [lastClipboardError] instead of dereferencing a null - and so that no call
  /// site has to test for absence.
  Clipboard get clipboard => _clipboard;

  set clipboard(Clipboard value) {
    if (identical(value, _clipboard)) return;
    _clipboard = value;
  }

  /// Why the last clipboard operation did not happen, or null if the last one
  /// did.
  ///
  /// Holds both kinds of "no": a real backend failure ([ClipboardException]
  /// from the port - the Windows clipboard held by another process) and a
  /// refusal by this field's own policy (copy from an obscured field, paste
  /// into a read-only one). Both are the same question for a caller - *why did
  /// my Ctrl+V do nothing* - and answering it needs a reason, not a bool.
  ///
  /// This is where the asynchrony surfaces: the key that started the operation
  /// was consumed frames before this is set. See [clipboardSettled].
  ClipboardException? get lastClipboardError => _lastClipboardError;

  /// Completes when every clipboard operation started so far has finished.
  ///
  /// Clipboard operations are queued and run one after another, so two quick
  /// pastes apply in the order they were typed rather than racing. A test
  /// awaits this after synthesizing Ctrl+V; nothing in the frame loop does,
  /// because a frame must never block on another process.
  Future<void> get clipboardSettled => _clipboardWork;

  /// What is painted: the value, or one bullet per character.
  String get displayText =>
      _obscure ? '*' * _controller.value.length : _controller.value;

  /// [displayText] laid out: the source of every caret, selection and hit-test
  /// coordinate this field uses.
  ///
  /// A `Paragraph` rather than the single shaped run [ControlBehavior] measures
  /// labels with, because a run has one direction and a caret does not. At a
  /// direction boundary an offset has two positions on the line, a selection
  /// that crosses one is several disjoint rectangles, and a hit test has to
  /// snap to a grapheme cluster - three things a single run cannot express and
  /// this does. The layout goes through `uiTextPainter`'s cache, so redrawing
  /// an unchanged field re-shapes nothing.
  ///
  /// **Null in two cases, both of which fall back to the single-run geometry
  /// and both of which are wrong for bidirectional text - stated here rather
  /// than hidden:**
  ///
  ///  * No face is installed, in which case nothing is drawn either.
  ///  * The text contains a script whose shaping model is not implemented.
  ///    `sharedShaper`'s documented policy is to throw rather than render
  ///    wrongly, and that policy is right for a paragraph the caller asked for;
  ///    it is not right for a *caret*, which would take down the whole frame
  ///    over text the label painter is still willing to draw. So exactly one
  ///    named exception is caught, and only around layout.
  Paragraph? get paragraph {
    final ScaledTypeface? font = labelFont;
    if (font == null) return null;
    try {
      return uiTextPainter.layout(displayText, font);
    } on UnsupportedScriptException {
      return null;
    }
  }

  @override
  void performLayout() => size = constraints.constrain(
        Size(160, theme.effectiveControlHeight),
      );

  @override
  bool hitTestSelf(Offset position) => true;

  /// Mouse selection: press to anchor, drag to extend, release to finish.
  ///
  /// The four gestures a text field owes the mouse, and what each does here:
  ///
  ///  * **Press and drag.** The press anchors the selection where it landed and
  ///    every move extends it, so the base stays put and only the extent
  ///    follows the pointer. A backwards drag therefore produces a *reversed*
  ///    [TextSelection] and stays reversed - which is not a detail: the next
  ///    Shift+Left has to shrink or grow depending on which end the user
  ///    dragged from, and normalising here would throw that away.
  ///  * **Shift+click** extends from the existing anchor instead of moving it,
  ///    which is the same operation as a drag with a very long pause in the
  ///    middle. See [_modifiers] for the one case where the Shift is missed.
  ///  * **Double click** selects the UAX #29 word segment under the pointer;
  ///    see [TextMotion.wordAt] for the boundary tie-break.
  ///  * **Triple click** selects everything. There is one line, so "the
  ///    paragraph" and "all of it" are the same range.
  ///
  /// **Two limits, declared rather than discovered:**
  ///
  ///  * **A drag past the edge selects to the end and stops there. There is no
  ///    auto-scroll**, because there is nothing to scroll: this field has no
  ///    horizontal offset of its own - overlong text is *clipped* by
  ///    `paintLabel` - so text past the edge cannot be brought into view by any
  ///    means, and a repeating timer that extended the selection into text the
  ///    user cannot see would be worse than stopping. A scrolling field would
  ///    add the offset first and the auto-scroll on top of it.
  ///  * **Dragging after a double click extends by character, not by word.**
  ///    The word-granularity drag every editor has needs the anchor to be a
  ///    *range* rather than an offset, which is a change to what the controller
  ///    stores.
  @override
  void handlePointerEvent(PointerEvent event) {
    super.handlePointerEvent(event);
    if (!enabled) return;
    switch (event) {
      case PointerDownEvent(button: PointerButton.primary):
        _onSelectionPointerDown(event);
      case PointerDownEvent(button: PointerButton.secondary):
        _onContextMenuPointerDown(event);
      case PointerMoveEvent() when _dragging:
        // The pointer is captured by [ControlBehavior], so this arrives even
        // when it has left the field - which is exactly when a selection drag
        // is most in need of it.
        _extendSelectionTo(event.logicalPosition);
      case PointerUpEvent(button: PointerButton.primary):
      case PointerCancelEvent():
        // The selection built so far stands. A cancelled drag is the pointer
        // being taken away, not the user changing their mind, and throwing the
        // selection away would lose work with no way to get it back.
        _dragging = false;
      default:
        break;
    }
  }

  void _onSelectionPointerDown(PointerDownEvent event) {
    final TextPosition position = _positionAt(event.logicalPosition);
    switch (_countClick(event)) {
      case 1:
        if (_modifiers.contains(KeyModifier.shift)) {
          _controller.setSelection(
            _controller.selectionStart,
            position.offset,
            affinity: position.affinity,
          );
        } else {
          _controller.collapseToPosition(position);
        }
        _dragging = true;
      case 2:
        final TextRange word =
            TextMotion.wordAt(_controller.value, position.offset);
        _controller.setSelection(word.start, word.end);
        _dragging = false;
      default:
        _controller.selectAll();
        _dragging = false;
    }
  }

  /// The secondary press: the caret rule, then the menu.
  ///
  /// **Inside the selection preserves it; outside it moves the caret.** That is
  /// what every editor does and the reason is asymmetric: a right-click on a
  /// selection is nearly always the first half of "copy this", so collapsing it
  /// would destroy the thing the user is about to act on - and there is no
  /// undo for a lost selection. A right-click *outside* one is the user
  /// pointing somewhere else, and leaving the old selection in place would make
  /// the menu's commands act on text nowhere near the pointer.
  ///
  /// The boundaries count as inside: the caret positions at each end of a
  /// selection are part of it, and a press one pixel past the last selected
  /// glyph is aimed at that glyph.
  ///
  /// Focus is taken first, whether or not a menu opens: the commands in the
  /// menu act on *this* field, and Escape has to bring the keyboard back here.
  void _onContextMenuPointerDown(PointerDownEvent event) {
    if (focusOnPointerDown) focusNode?.requestFocus(FocusChangeReason.pointer);
    final TextPosition position = _positionAt(event.logicalPosition);
    final ({int start, int end}) range = _controller.orderedSelection;
    final bool insideSelection = _controller.hasSelection &&
        position.offset >= range.start &&
        position.offset <= range.end;
    if (!insideSelection) _controller.collapseToPosition(position);
    openContextMenu(event.logicalPosition);
  }

  /// Opens this field's context menu with its corner at [globalPosition].
  ///
  /// A no-op with no [ContextMenuScope] above the field - the caret has already
  /// moved by then, which is the half of a secondary click that does not need
  /// an overlay.
  void openContextMenu(Offset globalPosition) {
    final ContextMenuController? menu = contextMenu;
    if (menu == null || !enabled) return;
    _probeClipboard(menu);
    _menuOpen = true;
    markNeedsPaint();
    menu.open(
      globalPosition: globalPosition,
      itemsBuilder: buildContextMenuItems,
      theme: theme,
      onClosed: () {
        _menuOpen = false;
        markNeedsPaint();
      },
    );
  }

  /// Asks the clipboard whether it holds pasteable text, without waiting.
  ///
  /// ## Why the question is asked at all, and what happens before it is
  /// answered
  ///
  /// [Clipboard.readText] is asynchronous - on Windows it opens a buffer owned
  /// by another process, which can be locked, slow, or held by an application
  /// that is itself blocked - so "is Paste available" cannot be answered while
  /// building a menu. The two honest options are to enable Paste always and let
  /// it fail, or to ask and show the answer when it lands. **This does both, in
  /// that order:** the probe starts when the menu opens, and until it answers
  /// Paste is enabled.
  ///
  /// Optimistic while pending, for three reasons:
  ///
  ///  * **A disabled item is unreachable.** Not just unclickable - initial-
  ///    letter navigation skips it and a screen reader announces it as
  ///    unavailable. A user who right-clicks and immediately presses P would
  ///    find nothing there, and would have no way to know it was a timing
  ///    accident.
  ///  * **The optimistic guess is nearly always right.** A clipboard with text
  ///    in it is the ordinary case, and the read is normally sub-millisecond.
  ///  * **The pessimistic guess has no recovery.** An enabled Paste that turns
  ///    out to have nothing to paste refuses through exactly the path Ctrl+V
  ///    refuses through, and names the reason in [lastClipboardError]. A
  ///    disabled Paste that was wrong just does not work.
  ///
  /// **A failed probe leaves the item enabled**, because a probe that threw is
  /// not evidence that the clipboard is empty - it is evidence that this one
  /// read failed. Treating it as "empty" would turn one transient fault into a
  /// permanently dead Paste, which is the same shape as the poisoned-queue bug
  /// [_enqueueClipboard] exists to prevent.
  ///
  /// A read-only field starts no probe: it refuses to paste anyway, so a round
  /// trip to another process whose answer can only be discarded is work nobody
  /// asked for. [pasteFromClipboard] makes the same call for the same reason.
  ///
  /// The probe runs on the same serialised queue as every other clipboard
  /// operation, so it cannot overlap a paste, and it deliberately does **not**
  /// touch [lastClipboardError]: a probe is the framework's question, not the
  /// user's, and a failed one must not be reported as a failed command.
  void _probeClipboard(ContextMenuController menu) {
    _clipboardHasText = null;
    if (_readOnly) return;
    _clipboardWork = _clipboardWork.then((void _) async {
      try {
        final String? text = await _clipboard.readText();
        _clipboardHasText =
            text != null && PastedText.forSingleLine(text).isNotEmpty;
      } on Object {
        _clipboardHasText = null;
      }
      if (menu.isOpen) menu.refresh();
    });
  }

  /// The commands this field offers, with today's state baked into each one.
  ///
  /// Rebuilt every time the menu needs them - see
  /// [ContextMenuController.refresh] - so the enablement below is always a
  /// snapshot of *now* rather than of when the pointer went down.
  ///
  /// The rules, and the one place this is stricter than the keyboard:
  ///
  ///  * **Copy and Cut need a selection, and are refused outright by an
  ///    obscured field.** The refusal already exists in [copySelection]; the
  ///    menu reflects it rather than routing around it, because a menu that
  ///    offered Copy on a password field and silently did nothing would be
  ///    worse than one that says it cannot.
  ///  * **Cut additionally needs a writable field.** This *is* stricter than
  ///    Ctrl+X, which in a read-only field copies and reports success. That is
  ///    the right behaviour for a chord - it makes Ctrl+X and Ctrl+C agree, and
  ///    nothing on screen claimed otherwise - and the wrong behaviour for a row
  ///    labelled **Cut**, which promises that the text will be removed. A menu
  ///    is where enablement is *stated*, so a statement that will not come true
  ///    does not belong in one. Avalonia draws the line in the same place
  ///    (`CanCut` requires `!IsReadOnly`).
  ///  * **Paste needs a writable field and a clipboard with something in it.**
  ///    See [_probeClipboard] for what "has something in it" means before the
  ///    answer arrives.
  ///  * **Select all needs text.**
  List<MenuItem> buildContextMenuItems() {
    final bool hasSelection = _controller.hasSelection;
    final bool canCopy = enabled && hasSelection && !_obscure;
    return <MenuItem>[
      MenuItem(
        label: 'Cut',
        shortcut: 'Ctrl+X',
        enabled: canCopy && !_readOnly,
        disabledReason: _obscure
            ? 'the field is obscured; cutting would put its value on a buffer '
                'every other process can read'
            : _readOnly
                ? 'the field is read-only'
                : 'nothing is selected',
        onSelected: () => _enqueueClipboard(cutSelection),
      ),
      MenuItem(
        label: 'Copy',
        shortcut: 'Ctrl+C',
        enabled: canCopy,
        disabledReason: _obscure
            ? 'the field is obscured; copying would put its value on a buffer '
                'every other process can read'
            : 'nothing is selected',
        onSelected: () => _enqueueClipboard(copySelection),
      ),
      MenuItem(
        label: 'Paste',
        shortcut: 'Ctrl+V',
        enabled: enabled && !_readOnly && (_clipboardHasText ?? true),
        disabledReason: _readOnly
            ? 'the field is read-only'
            : 'the clipboard holds no text this field can accept',
        onSelected: () => _enqueueClipboard(pasteFromClipboard),
      ),
      const MenuItem.separator(),
      MenuItem(
        label: 'Select all',
        shortcut: 'Ctrl+A',
        enabled: enabled && _controller.value.isNotEmpty,
        disabledReason: 'the field is empty',
        onSelected: _controller.selectAll,
      ),
    ];
  }

  /// Which click of a multi-click this press is: 1, 2 or 3.
  ///
  /// **The platform's own answer wins when it has one.**
  /// [PointerDownEvent.clickCount] above 1 means the OS matched this press
  /// against the previous one using the double-click interval *and* the
  /// double-click rectangle from the user's settings - which on Windows is
  /// `GetDoubleClickTime()` and `SM_CXDOUBLECLK`, both of them accessibility
  /// settings that somebody with a tremor really does change. Re-deciding it
  /// here against [_multiClickInterval] and [_multiClickSlop] would quietly
  /// override that, and a user who set a 900 ms interval would find the
  /// double click they configured stops working inside this framework.
  ///
  /// Without a platform count it is time *and* distance, because either alone
  /// is wrong: two clicks a second apart at the same pixel are two clicks, and
  /// two fast clicks at opposite ends of the field are also two clicks.
  ///
  /// A fourth click starts the cycle again at one, which is what Windows does.
  /// Note that the *third* click of a triple always lands on the fallback path
  /// even on Windows: there is no `WM_LBUTTONTRIPLECLK`, so the OS counts to
  /// two and no further.
  int _countClick(PointerDownEvent event) {
    final Duration since = event.timestamp - _lastClickAt;
    final Offset moved = event.logicalPosition - _lastClickPosition;
    final bool continues = event.clickCount > 1 ||
        (since >= Duration.zero &&
            since <= _multiClickInterval &&
            moved.dx.abs() <= _multiClickSlop &&
            moved.dy.abs() <= _multiClickSlop);
    _clickCount = continues ? _clickCount % 3 + 1 : 1;
    _lastClickAt = event.timestamp;
    _lastClickPosition = event.logicalPosition;
    return _clickCount;
  }

  void _extendSelectionTo(Offset globalPosition) {
    final TextPosition position = _positionAt(globalPosition);
    if (position.offset == _controller.selectionEnd &&
        position.affinity == _controller.affinity) {
      // A mouse move that does not change the selection must not notify: the
      // controller's listeners include a repaint, and a drag across one glyph
      // would otherwise cost a frame per motion event.
      return;
    }
    _controller.setSelection(
      _controller.selectionStart,
      position.offset,
      affinity: position.affinity,
    );
  }

  /// The text position under a point in root coordinates.
  ///
  /// The text painted is not the text stored when the field is obscured, so the
  /// hit test measures what is on screen; anything else puts the caret at the
  /// wrong bullet. Beyond either edge the paragraph clamps to the end of the
  /// line, which is what makes a drag off the field select to the extreme.
  TextPosition _positionAt(Offset globalPosition) {
    final Offset local = globalToLocal(globalPosition);
    final double x = local.dx - theme.effectiveControlPadding;
    final Paragraph? laid = paragraph;
    if (laid != null) {
      // The paragraph snaps to a grapheme cluster and reports which side of the
      // boundary was hit, so a click on the right half of an emoji lands after
      // it rather than between its surrogates, and the affinity it returns is
      // what puts the caret on the correct side of a direction change.
      return laid.getPositionForOffset(Offset(x, 0));
    }
    return TextPosition(
      labelIndexAtOffset(displayText, x).clamp(0, _controller.value.length),
    );
  }

  @override
  bool handleKeyEvent(KeyEvent event) {
    // Every transition, press *and* release, so that the modifier state a
    // Shift+click reads is the current one. See [_modifiers].
    _modifiers = event.modifiers;
    if (!enabled || event is! KeyDownEvent) return false;
    final bool shift = event.modifiers.contains(KeyModifier.shift);
    final bool control = event.modifiers.contains(KeyModifier.control);
    if (control) {
      // Ctrl turns the four editing keys into their word-wise forms, and Shift
      // still extends. Routed here rather than inside the plain switch below so
      // that an unhandled Ctrl chord falls through to `false` and reaches
      // whatever above this field owns application shortcuts.
      switch (event.logicalKey) {
        case 0x41: // Ctrl+A
          _controller.selectAll();
          return true;
        case 0x5A: // Ctrl+Z
          if (!_readOnly) _controller.undo();
          return true;
        case 0x59: // Ctrl+Y
          if (!_readOnly) _controller.redo();
          return true;
        // The clipboard chords, claimed whether or not they end up doing
        // anything. A refused copy - from an obscured field - that returned
        // false would fall through to the application's shortcut map, and
        // Ctrl+C aimed at a password would fire whatever the application bound
        // to it. Claiming is about precedence, and the precedence is the
        // field's either way; the *reason* the operation did nothing goes to
        // [lastClipboardError].
        case 0x43: // Ctrl+C
          _enqueueClipboard(copySelection);
          return true;
        case 0x58: // Ctrl+X
          _enqueueClipboard(cutSelection);
          return true;
        case 0x56: // Ctrl+V
          _enqueueClipboard(pasteFromClipboard);
          return true;
        case _logicalKeyInsert: // Ctrl+Insert: copy, the older spelling
          _enqueueClipboard(copySelection);
          return true;
        case logicalKeyArrowLeft:
          _controller.moveCaretByWord(-1, extend: shift);
          return true;
        case logicalKeyArrowRight:
          _controller.moveCaretByWord(1, extend: shift);
          return true;
        case logicalKeyBackspace:
          // Swallowed even when read-only: a read-only field that let
          // Ctrl+Backspace through would fire an application shortcut the user
          // aimed at the text.
          if (!_readOnly) _controller.deleteWordBackward();
          return true;
        case logicalKeyDelete:
          if (!_readOnly) _controller.deleteWordForward();
          return true;
        default:
          return false;
      }
    }
    switch (event.logicalKey) {
      case logicalKeyArrowLeft:
        _controller.moveCaret(-1, extend: shift);
        return true;
      case logicalKeyArrowRight:
        _controller.moveCaret(1, extend: shift);
        return true;
      case logicalKeyHome:
        _controller.moveCaretToStart(extend: shift);
        return true;
      case logicalKeyEnd:
        _controller.moveCaretToEnd(extend: shift);
        return true;
      case logicalKeyBackspace:
        if (_readOnly) return true;
        _controller.deleteBackward();
        return true;
      case logicalKeyDelete:
        // Shift+Delete is cut, the pre-Ctrl+X spelling that Windows still
        // honours everywhere. With no selection it cuts nothing rather than
        // falling back to a forward delete: a chord that deletes a character
        // *and* leaves the clipboard untouched is the surprising one.
        if (shift) {
          _enqueueClipboard(cutSelection);
          return true;
        }
        if (_readOnly) return true;
        _controller.deleteForward();
        return true;
      case _logicalKeyInsert:
        // Shift+Insert is paste. Plain Insert is declined: it means overtype,
        // which this field does not implement, and claiming it would stop an
        // application binding it to something that does.
        if (shift) {
          _enqueueClipboard(pasteFromClipboard);
          return true;
        }
        return false;
      case logicalKeyContextMenu:
        // The dedicated Menu key. Claimed whether or not a scope is installed:
        // its only meaning is "show the context menu for what has focus", so
        // letting it fall through to an application shortcut would be wrong
        // even when this field has nowhere to put a menu.
        openContextMenu(_caretAnchor());
        return true;
      case logicalKeyF10:
        // Shift+F10, the keyboard route on a keyboard with no Menu key. Bare
        // F10 is left alone: on Windows it activates the window's menu bar,
        // which is not this field's to claim.
        if (!shift) return false;
        openContextMenu(_caretAnchor());
        return true;
      case logicalKeyEscape:
        // Escape means "abandon what the input method is composing" **while**
        // it is composing, and nothing at all otherwise. Claimed only in the
        // first case: a field that ate every Escape would strand a keyboard
        // user inside a dialog it cannot dismiss, and one that never claimed it
        // would close the dialog out from under a half-typed Japanese word.
        // Every platform's own edit control draws the line here.
        if (_controller.isComposing) {
          _textInputConnection?.cancelComposition();
          _clearComposition();
          return true;
        }
        return false;
      case logicalKeyTab:
        // Declined on purpose: Tab belongs to traversal, and a text field that
        // ate it would strand a keyboard user inside it.
        return false;
    }
    if (_readOnly) return false;
    // Claimed, and deliberately *without* inserting anything.
    //
    // This is not where text comes from - [handleTextInput] is - but a key
    // that the layout is about to turn into a character still belongs to this
    // field, or an application that bound a bare letter as a shortcut would
    // steal every keystroke aimed at the document. Claiming is about
    // precedence, not content: it decides who owns the keystroke, while the OS
    // decides what it says.
    return _mayProduceText(event.logicalKey);
  }

  /// Where a keyboard-opened menu is anchored: under the caret.
  ///
  /// Not the pointer, which may be anywhere on the screen or nowhere at all -
  /// a menu opened by Shift+F10 that appeared next to a mouse the user is not
  /// touching is a menu they will not find. Under the caret is where the thing
  /// the commands act on actually is. Avalonia makes the same split, anchoring
  /// a keyboard-raised menu to the control rather than to `PlacementMode`
  /// `.Pointer`.
  Offset _caretAnchor() {
    final Paragraph? laid = paragraph;
    final double caretX = laid != null
        ? laid
            .getCaretRect(
              TextPosition(
                _controller.selectionEnd,
                affinity: _controller.affinity,
              ),
            )
            .left
        : labelOffsetOfIndex(displayText, _controller.selectionEnd);
    return localToGlobal(
      Offset(theme.effectiveControlPadding + caretX, size.height),
    );
  }

  /// Whether a virtual key is one the keyboard layout may turn into text.
  ///
  /// A bounded allow-list rather than a guess at the character, because the
  /// character is not knowable here - the whole point of the split. Every key
  /// in it is a key that carries a printed legend on some layout somewhere:
  /// space, the digit row, the letter block, the numeric keypad (whose digits
  /// only reach us with NumLock on), and the OEM keys that hold punctuation
  /// and move around between layouts. Anything else - function keys, Insert,
  /// Pause, the modifiers themselves - never produces a character, so an
  /// application shortcut bound to one keeps working from inside a field.
  static bool _mayProduceText(int virtualKey) =>
      virtualKey == logicalKeySpace ||
      (virtualKey >= 0x30 && virtualKey <= 0x39) || // 0-9
      (virtualKey >= 0x41 && virtualKey <= 0x5A) || // A-Z
      (virtualKey >= 0x60 && virtualKey <= 0x6F) || // numpad digits, operators
      (virtualKey >= 0xBA && virtualKey <= 0xC0) || // OEM punctuation
      (virtualKey >= 0xDB && virtualKey <= 0xDF) || // OEM brackets, quotes
      virtualKey == 0xE2; // OEM_102, the extra key on ISO keyboards

  /// Inserts what the platform's keyboard layout produced.
  ///
  /// The entire content of a typed character arrives here and nowhere else.
  /// The field used to build the character out of [KeyEvent.logicalKey], which
  /// is a virtual-key code: it typed `a` for the numeric keypad's `1`, `(` for
  /// the down arrow, could produce only capitals, and could not produce `ç`,
  /// `€` or anything behind a dead key at all. See [TextInputEvent] for why no
  /// arithmetic on a key code can be made to work.
  ///
  /// [TextEditingController.replaceSelection] does the rest: it replaces the
  /// selection if there is one and snaps the caret onto a grapheme cluster
  /// boundary afterwards, so typing an accent onto a letter leaves the caret
  /// after the pair rather than inside it.
  @override
  bool handleTextInput(TextInputEvent event) {
    if (!enabled || _readOnly) return false;
    // A keystroke that produced text while an input method was composing is
    // not a second opinion about the preedit - it is the platform having
    // decided the method did not want this key. Dropping the composition first
    // keeps the two from interleaving; without it the character lands *inside*
    // the underlined span and the IME goes on owning a range it no longer
    // recognises.
    if (_controller.isComposing) {
      _textInputConnection?.cancelComposition();
      _clearComposition();
    }
    _controller.replaceSelection(event.text);
    _syncTextInputState();
    return true;
  }

  // -------------------------------------------------------------------------
  // Input method
  // -------------------------------------------------------------------------

  /// Points this field at a platform input method, or at none.
  ///
  /// Called by the widget on every build with whatever [TextInputScope] is
  /// above it. Identity-compared on both halves, because a rebuild that changed
  /// nothing must not tear down a live composition - which is exactly what
  /// re-attaching does.
  void setTextInput(TextInputBackend? backend, NativeWindow? window) {
    if (identical(backend, _textInput) && identical(window, _textInputWindow)) {
      return;
    }
    _releaseTextInput();
    _textInput = backend;
    _textInputWindow = window;
    // Only when this field already has the keyboard: attaching an unfocused
    // field would point the input method at a field the user is not typing in.
    if (hasFocus) _attachTextInput();
  }

  /// Whether a platform input method is attached and switched on for this
  /// field right now.
  bool get isTextInputAttached => _textInputConnection?.isEnabled ?? false;

  void _attachTextInput() {
    final TextInputBackend? backend = _textInput;
    final NativeWindow? window = _textInputWindow;
    if (backend == null || window == null) return;
    // Asked rather than tried: `attach` throws by design on a backend with no
    // input method (see [UnavailableTextInput]), and a field that took that
    // exception on every focus change would turn a known platform fact into a
    // per-keystroke failure.
    if (!backend.supportsComposition) return;
    if (_textInputConnection != null) return;
    try {
      final TextInputConnection connection =
          backend.attach(window: window, client: this);
      _textInputConnection = connection;
      connection.enable();
      _textInputError = null;
    } on TextInputException catch (error) {
      _textInputError = error;
    }
  }

  void _releaseTextInput() {
    final TextInputConnection? connection = _textInputConnection;
    if (connection == null) return;
    _textInputConnection = null;
    // Disable before detach: the order matters on Win32, where detaching
    // restores the window's default input context and a composition still in
    // flight would be handed to nobody.
    connection.disable();
    connection.detach();
    _clearComposition();
  }

  /// Drops a composition **and the provisional text with it**.
  ///
  /// Not [TextEditingController.clearComposing], which forgets the range and
  /// leaves the characters behind: those characters were never accepted by
  /// anybody, and leaving them turns a cancelled Japanese conversion into a
  /// document full of hiragana the user never asked for. A cancelled preedit
  /// leaves no trace, which is what every platform's own edit control does.
  ///
  /// Usually a no-op by the time it runs: a connection that was told to cancel
  /// answers with `updateComposition(ImeComposition.none)`, which does this
  /// through the ordinary path. It is here for the case with no connection at
  /// all - a field whose backend has no input method, which can still have a
  /// composing range left over from a test or a previous backend.
  void _clearComposition() {
    _compositionClauses = const <ImeCompositionClause>[];
    _hidesCompositionCaret = false;
    if (_controller.isComposing) _controller.replaceComposingRegion('');
  }

  @override
  TextInputConfiguration get textInputConfiguration {
    if (_obscure) return TextInputConfiguration.password;
    if (_readOnly || !enabled) {
      // Not a purpose but a refusal: `isSensitive` is what every backend reads
      // to decide whether to compose at all, and a field that cannot be typed
      // into must not have an input method aimed at it. Spelled as a hint
      // rather than as an invented `readOnly` purpose, so the enumeration stays
      // the protocol's.
      return const TextInputConfiguration(
        hints: <ImeContentHint>{ImeContentHint.sensitiveData},
      );
    }
    return const TextInputConfiguration();
  }

  /// The text around the caret, **with the preedit taken back out**.
  ///
  /// The provisional characters live in [TextEditingController.value] so that
  /// they are laid out and drawn in place, but they belong to the input method
  /// and not to the document. Sending them back would make the method see its
  /// own output as context, and on Wayland it is an explicit protocol
  /// violation. See [ImeSurroundingText] for the other two rules.
  @override
  ImeSurroundingText get surroundingText {
    if (textInputConfiguration.isSensitive) return ImeSurroundingText.empty;
    final String text = _controller.value;
    if (!_controller.isComposing) {
      return ImeSurroundingText(
        text: text,
        cursor: _controller.selectionEnd.clamp(0, text.length),
        anchor: _controller.selectionStart.clamp(0, text.length),
      );
    }
    final TextRange composing = _controller.composing;
    final String without =
        text.substring(0, composing.start) + text.substring(composing.end);
    int shift(int offset) {
      if (offset <= composing.start) return offset;
      if (offset >= composing.end) {
        return offset - (composing.end - composing.start);
      }
      // A caret inside the preedit has no place in a document that does not
      // contain it; where the preedit starts is the only honest answer.
      return composing.start;
    }

    return ImeSurroundingText(
      text: without,
      cursor: shift(_controller.selectionEnd).clamp(0, without.length),
      anchor: shift(_controller.selectionStart).clamp(0, without.length),
    );
  }

  /// Where the caret is, in the window's client coordinates.
  ///
  /// The caret and not the field: a candidate window opens *below this
  /// rectangle*, and handing over the whole control would put the list under
  /// the wrong place on a wide field. Zero-sized before the first layout, which
  /// is a state a focus change can genuinely reach.
  @override
  Rect get caretRect {
    if (!hasSize) return Rect.zero;
    final Rect local = _localCaretRect();
    final Offset topLeft = localToGlobal(Offset(local.left, local.top));
    return Rect.fromLTWH(topLeft.dx, topLeft.dy, local.width, local.height);
  }

  /// The caret rectangle in this render object's own coordinates.
  ///
  /// Shared with [paint] so that the caret the user sees and the caret the
  /// candidate window is anchored to cannot disagree - which they did in every
  /// toolkit that computed them in two places.
  Rect _localCaretRect() {
    final double padding = theme.effectiveControlPadding;
    final double lineHeight = labelLineHeight;
    final double textTop = ((size.height - lineHeight) / 2).roundToDouble();
    final Paragraph? laid = paragraph;
    final double caretX = laid != null
        ? laid
            .getCaretRect(
              TextPosition(
                _controller.selectionEnd,
                affinity: _controller.affinity,
              ),
            )
            .left
        : labelOffsetOfIndex(displayText, _controller.selectionEnd);
    return Rect.fromLTWH(padding + caretX, textTop - 1, 1, lineHeight + 2);
  }

  /// Whether an input-method callback is mid-flight.
  ///
  /// The edits an IME asks for must not push state back at the platform on
  /// their way through: see [_syncTextInputState] for the Wayland serial rule
  /// that makes an extra commit here a real bug rather than a wasted call.
  bool _applyingImeEdit = false;

  /// Runs an input-method edit without letting it notify the platform back.
  void _applyImeEdit(void Function() body) {
    _applyingImeEdit = true;
    try {
      body();
    } finally {
      _applyingImeEdit = false;
    }
  }

  @override
  void updateComposition(ImeComposition composition) {
    if (!enabled || _readOnly) return;
    _compositionClauses = composition.clauses;
    _hidesCompositionCaret = composition.hasHiddenCursor;
    _applyImeEdit(
      () => _controller.replaceComposingRegion(
        composition.text,
        // The caret goes to the end of the preedit when the method asked for
        // none: it has to be *somewhere*, and the end is where the next
        // keystroke lands. Only the painting of it is suppressed.
        caretOffset: composition.hasHiddenCursor
            ? composition.text.length
            : composition.cursorStart,
      ),
    );
    if (composition.isEmpty) {
      _compositionClauses = const <ImeCompositionClause>[];
      _hidesCompositionCaret = false;
    }
  }

  @override
  void commitText(String text) {
    if (!enabled || _readOnly) return;
    _compositionClauses = const <ImeCompositionClause>[];
    _hidesCompositionCaret = false;
    _applyImeEdit(() => _controller.commitText(text));
  }

  @override
  void deleteSurroundingText({
    required int beforeLength,
    required int afterLength,
  }) {
    if (!enabled || _readOnly) return;
    _applyImeEdit(
      () => _controller.deleteSurrounding(
        beforeLength: beforeLength,
        afterLength: afterLength,
      ),
    );
  }

  /// Tells the platform that the caret or the document moved.
  ///
  /// Called for edits **this field** made - typing, deleting, moving the caret,
  /// pasting - and deliberately *not* from inside the input method's own
  /// callbacks.
  ///
  /// The asymmetry is the Wayland serial rule. A `commit` bumps the count every
  /// `done` event's serial is compared against, so pushing state from inside
  /// the three callbacks a single `done` may call in sequence would leave the
  /// client's count ahead of the compositor's replies and make the next
  /// `delete_surrounding_text` look stale and be discarded - which is the
  /// classic text-input-v3 bug. `WaylandTextInputManager` pushes once, after
  /// the whole transaction has been applied, which is step 4 of the protocol's
  /// own ordering.
  void _syncTextInputState() {
    if (_applyingImeEdit) return;
    _textInputConnection?.updateEditingState();
  }

  /// Observes focus for the input method, on top of what [ControlBehavior]
  /// already does with it.
  ///
  /// The mixin's own listener repaints; this one attaches and detaches. A
  /// second listener rather than an override because the mixin's is private,
  /// and keeping them apart means a repaint can never be lost to an exception
  /// thrown while attaching.
  @override
  set focusNode(FocusNode? value) {
    final FocusNode? previous = focusNode;
    if (identical(value, previous)) return;
    previous?.removeListener(_onImeFocusChanged);
    super.focusNode = value;
    value?.addListener(_onImeFocusChanged);
    _onImeFocusChanged(value);
  }

  void _onImeFocusChanged(FocusNode? node) {
    if (hasFocus) {
      _attachTextInput();
    } else {
      _releaseTextInput();
    }
  }

  // -------------------------------------------------------------------------
  // Clipboard
  // -------------------------------------------------------------------------

  /// Puts the selected text on the clipboard. Returns whether it got there.
  ///
  /// Three rules that are easy to get wrong and are each a test:
  ///
  ///  * **An empty selection copies nothing and leaves the clipboard alone.**
  ///    Writing the empty string would destroy whatever the user copied a
  ///    moment ago, and Ctrl+C with no selection is something people press by
  ///    accident constantly.
  ///  * **An obscured field refuses.** A password field renders bullets
  ///    precisely so the value cannot be read off the screen; handing the same
  ///    value to a process-global buffer that every other application can read
  ///    - and that clipboard managers write to disk - gives it away by another
  ///    door. Every platform's password field refuses this, and so does this
  ///    one. Pasting *into* one is still allowed: the secret is moving toward
  ///    the field, not out of it, which is how password managers work.
  ///  * **A failed write is not a silent no-op.** The reason lands in
  ///    [lastClipboardError].
  Future<bool> copySelection() async {
    if (!enabled) return false;
    if (_obscure) {
      return _refuse(
        'copy',
        'the field is obscured; copying would put its value on a buffer every '
            'other process can read',
      );
    }
    if (!_controller.hasSelection) {
      return _refuse(
        'copy',
        'the selection is empty; the clipboard was left as it was rather than '
            'being emptied',
      );
    }
    return _write(_controller.selectedText);
  }

  /// Copies the selection and then removes it.
  ///
  /// **The write happens first and the delete only if it succeeded**, so a
  /// clipboard held by another process cannot cost the user their text. In a
  /// [readOnly] field the copy still happens and the delete does not: the text
  /// is readable on screen, so there is nothing to protect by refusing to copy
  /// it, and refusing would only make Ctrl+X in a read-only field behave
  /// differently from Ctrl+C for no reason the user can see. In an [obscure]
  /// field the whole operation is refused, for the reason on [copySelection].
  Future<bool> cutSelection() async {
    if (!enabled) return false;
    if (_obscure) {
      return _refuse(
        'cut',
        'the field is obscured; cutting would put its value on a buffer every '
            'other process can read',
      );
    }
    if (!_controller.hasSelection) {
      return _refuse('cut', 'the selection is empty; nothing was cut');
    }
    if (!await _write(_controller.selectedText)) return false;
    if (_readOnly) {
      // Copied, not cut. Reported as a success - the clipboard does hold the
      // text - with the reason the text is still on screen.
      _lastClipboardError = null;
      return true;
    }
    _controller.replaceSelection('');
    return true;
  }

  /// Replaces the selection with the clipboard's text.
  ///
  /// The caret lands **after** the inserted text, the whole insertion is
  /// **one** undo entry - `replaceSelection` pushes exactly one, so a single
  /// Ctrl+Z takes back the entire paste rather than one character of it - and
  /// the text is put through [PastedText.forSingleLine] first, which is where
  /// the line-break policy and the "no half a character" rule live.
  ///
  /// Nothing happens, and no undo entry is pushed, when the clipboard holds no
  /// text or holds only characters the policy drops. A read-only field refuses
  /// without reading: the read is a round trip to another process, and starting
  /// one whose result can only be thrown away is work the user did not ask for.
  Future<bool> pasteFromClipboard() async {
    if (!enabled) return false;
    if (_readOnly) {
      return _refuse('paste', 'the field is read-only');
    }
    final String? raw = await _read();
    if (raw == null) return false;
    final String text = PastedText.forSingleLine(raw);
    if (text.isEmpty) {
      return _refuse(
        'paste',
        'the clipboard held no text this field can accept',
      );
    }
    _controller.replaceSelection(text);
    return true;
  }

  /// Runs [operation] after everything already queued.
  ///
  /// Serialised rather than fired in parallel: two Ctrl+V presses one frame
  /// apart must insert in the order they were typed, and two overlapping reads
  /// of the Windows clipboard would have the second fail on the lock the first
  /// is holding.
  ///
  /// ## Why the failure is swallowed *here*, and what "swallowed" means
  ///
  /// This used to be `_clipboardWork.then((_) => operation())` with no error
  /// handler, and that shape has two failure modes, both of which the user hit
  /// at once:
  ///
  ///  1. **The error escaped.** A future produced by `then` with nobody
  ///     listening for its error is an unhandled asynchronous error: it reaches
  ///     `Zone.handleUncaughtError`, which in a test fails an unrelated test and
  ///     in the gallery prints a `_microtaskLoop` stack trace over the running
  ///     application.
  ///  2. **The chain stayed poisoned.** `_clipboardWork` was left holding the
  ///     rejected future, and every later `then` on it short-circuits straight
  ///     to that same error - so *one* failed Ctrl+V permanently disabled copy,
  ///     cut and paste in that field, silently, for the life of the process.
  ///     That is the part a user notices: the clipboard "just stops working".
  ///
  /// So the link is wrapped in a `try` that cannot rethrow, which makes both
  /// impossible by construction: [_clipboardWork] can only ever complete
  /// *normally*, so it can never be poisoned and never carries an error for
  /// anybody to leave unhandled. The failure is not lost - it becomes
  /// [lastClipboardError], which is observable state a caller can read and a
  /// test can assert, rather than an exception thrown at nobody several
  /// microtasks after the keystroke that caused it.
  void _enqueueClipboard(Future<bool> Function() operation) {
    _clipboardWork = _clipboardWork.then((void _) async {
      try {
        await operation();
      } on ClipboardException catch (error) {
        // A port failure that got past the guards in [_write] / [_read] - a
        // Clipboard implementation that throws from somewhere else in its
        // contract, for instance.
        _lastClipboardError = error;
      } on Object catch (error) {
        // Anything at all: a backend throwing a type this file has never heard
        // of is still not a reason to take down the frame loop or to break the
        // next paste. Named, not hidden.
        _lastClipboardError = ClipboardException(
          operation: 'clipboard',
          reason: 'the operation failed with an unexpected error: $error',
        );
      }
    });
  }

  Future<bool> _write(String text) async {
    try {
      await _clipboard.writeText(text);
      _lastClipboardError = null;
      return true;
    } on ClipboardException catch (error) {
      _lastClipboardError = error;
      return false;
    } on UnsupportedCapabilityError catch (error) {
      _lastClipboardError = ClipboardException(
        operation: 'writeText',
        reason: error.toString(),
      );
      return false;
    }
  }

  Future<String?> _read() async {
    try {
      final String? text = await _clipboard.readText();
      _lastClipboardError = text == null
          ? const ClipboardException(
              operation: 'paste',
              reason: 'the clipboard holds no text',
            )
          : null;
      return text;
    } on ClipboardException catch (error) {
      _lastClipboardError = error;
      return null;
    } on UnsupportedCapabilityError catch (error) {
      _lastClipboardError = ClipboardException(
        operation: 'readText',
        reason: error.toString(),
      );
      return null;
    }
  }

  /// The colour of an inactive selection, when one is painted at all.
  ///
  /// ## The policy is [inactiveSelection]'s, not this method's
  ///
  /// The bug this replaced was that the selection was painted at full strength
  /// whichever field had focus, so clicking into a second field left two fields
  /// looking selected and the user could not tell which one a keystroke would
  /// reach. The fix was to dim it - and then to *hard-code* dimming, on a
  /// justification that does not survive checking:
  ///
  ///  * The claim that "a Windows edit control greys its selection when the
  ///    control is not the focus" is **false**. A Win32 `EDIT` hides it; the
  ///    `ES_NOHIDESEL` style exists to turn that off. WPF and browsers hide it
  ///    too. Avalonia shows it. See [InactiveSelectionHighlight].
  ///  * The macOS and GTK colours cited alongside it -
  ///    `NSColor.unemphasizedSelectedTextBackgroundColor` and `:backdrop` - are
  ///    **window-inactive** states, not control-unfocused ones. They were
  ///    window-level evidence for a control-level rule.
  ///  * The "select a phrase, then click *Bold*" argument was answering a
  ///    different question. That flow works on real platforms because a command
  ///    button **does not take focus**, so the field never becomes inactive at
  ///    all. It is an argument about focus policy for toolbar buttons, and it
  ///    belongs there rather than here.
  ///
  /// So the policy is a property with a declared default, and this method is
  /// only the colour arithmetic for one of its three values. **The controller's
  /// selection is never touched by any of them.**
  ///
  /// ## How the colour is derived, and the one case it is wrong
  ///
  /// Half way between [ThemeData.selection] and the field's own fill, per
  /// channel, un-premultiplied 0xAARRGGBB. That keeps it recognisably the
  /// selection colour, always lands between the two colours the field already
  /// uses, and needs no new palette entry.
  ///
  /// **In a high-contrast theme, muting a colour is the wrong instinct** - that
  /// theme exists to remove exactly this kind of subtlety. It is still done
  /// here, because leaving high contrast at full strength would keep the
  /// reported bug alive for the users most affected by it, and the focused
  /// field's accent border remains an unmuted focus signal. The tidier answer
  /// is a `selectionInactive` entry on [ThemeData] that each palette sets for
  /// itself - high contrast picking something with contrast rather than
  /// something faded - which is a change to `theme.dart`, a file this work does
  /// not own.
  /// The colour to paint the selection in right now, or null to paint none.
  ///
  /// The one place [inactiveSelection] is consulted, and therefore the socket
  /// the third state named on [InactiveSelectionHighlight] plugs into: a window
  /// that has lost activation entirely would arrive here as a second named
  /// argument - `windowActive`, from [FocusManager.isWindowActive] - and pick a
  /// third colour. Nothing sets it yet, so it is not a parameter yet.
  ///
  /// "Focused" here includes *this field's own context menu being open*. The
  /// menu holds the keyboard while it is up, and dimming the selection at
  /// exactly the moment the user is choosing **Copy** from a menu about that
  /// selection would be the worst possible time to go quiet.
  Color? selectionColorFor({required Color background}) {
    if (hasFocus || _menuOpen) return theme.selection;
    return switch (_inactiveSelection) {
      InactiveSelectionHighlight.hidden => null,
      InactiveSelectionHighlight.dimmed =>
        _inactiveSelectionColor(theme.selection, background),
      InactiveSelectionHighlight.visible => theme.selection,
    };
  }

  static Color _inactiveSelectionColor(Color selection, Color background) {
    int mix(int selected, int behind) => (selected + behind) ~/ 2;
    return Color.fromARGB(
      selection.alpha,
      mix(selection.red, background.red),
      mix(selection.green, background.green),
      mix(selection.blue, background.blue),
    );
  }

  /// Records why an operation did not happen and reports that it did not.
  bool _refuse(String operation, String reason) {
    _lastClipboardError = ClipboardException(
      operation: operation,
      reason: reason,
    );
    return false;
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      size.width,
      size.height,
    );
    final Color fillColor =
        enabled ? theme.surfaceAlternate : theme.disabledSurface;
    paintFill(list, rect, fillColor);
    // A field whose own context menu is up still reads as the active one: the
    // keyboard is on loan to the menu, not gone somewhere else. See
    // [selectionColorFor].
    final bool looksFocused = hasFocus || _menuOpen;
    paintBorder(list, rect, looksFocused ? theme.accent : theme.border);
    final double padding = theme.effectiveControlPadding;
    final double textTop =
        (rect.top + (rect.height - labelLineHeight) / 2).roundToDouble();
    final String text = displayText;
    // One layout for the whole paint: selection boxes, the composing underline
    // and the caret all read the same geometry, so they cannot disagree about
    // where a character is.
    final Paragraph? laid = paragraph;
    final double left = rect.left + padding;
    if (text.isEmpty && _label.isNotEmpty) {
      paintLabel(
        list,
        _label,
        Offset(left, textTop),
        theme.foregroundSecondary,
        maxWidth: rect.width - padding * 2,
      );
    } else {
      final Color? selectionColor = _controller.hasSelection && !_obscure
          ? selectionColorFor(background: fillColor)
          : null;
      if (selectionColor != null) {
        final ({int start, int end}) range = _controller.orderedSelection;
        if (laid != null) {
          // **N rectangles, not one.** A logically contiguous selection that
          // crosses a direction boundary is drawn in two or three disjoint
          // pieces, because the characters between its ends are somewhere else
          // on the line entirely. One rectangle would either miss selected text
          // or highlight text that is not selected, and there is no third
          // option.
          for (final TextBox box
              in laid.getBoxesForSelection(range.start, range.end)) {
            paintFill(
              list,
              Rect.fromLTWH(
                left + box.rect.left,
                textTop - 1,
                box.rect.width,
                labelLineHeight + 2,
              ),
              selectionColor,
            );
          }
        } else {
          // No paragraph: no face, or a script the shaper will not shape. Both
          // edges still come from the shaped run, so the highlight ends where
          // the last selected glyph ends - but this is the single-run path and
          // it is only correct for text of one direction.
          final double from = labelOffsetOfIndex(text, range.start);
          final double to = labelOffsetOfIndex(text, range.end);
          paintFill(
            list,
            Rect.fromLTWH(
                left + from, textTop - 1, to - from, labelLineHeight + 2),
            selectionColor,
          );
        }
      }
      paintLabel(
        list,
        text,
        Offset(left, textTop),
        foregroundColor(),
        maxWidth: rect.width - padding * 2,
      );
      // The composing region, underlined. Provisional text has to look
      // provisional or the user cannot tell what the input method still owns,
      // and the same N-rectangle argument applies: a composition inside
      // right-to-left text is not one span on screen.
      //
      // The *thickness* is the input method's, not a constant: it reports one
      // attribute per code unit of the preedit and the runs of equal attributes
      // are its clauses, so the clause the candidate window is currently about
      // is drawn thicker than the rest. A Japanese conversion of four clauses
      // is unusable without that distinction - the arrow keys move between
      // clauses and nothing on screen would say which one they are on.
      //
      // `zwp_text_input_v3` reports no clauses at all (v3 dropped v2's
      // styling), so there the list is empty and the whole preedit gets one
      // plain underline. That is the fallback and not a bug; see
      // [ImeComposition.clauses].
      if (_controller.isComposing && !_obscure && laid != null) {
        final TextRange composing = _controller.composing;
        for (final _CompositionRun run in _compositionRuns(composing)) {
          for (final TextBox box
              in laid.getBoxesForSelection(run.start, run.end)) {
            paintFill(
              list,
              Rect.fromLTWH(
                left + box.rect.left,
                textTop + labelLineHeight,
                box.rect.width,
                run.thickness,
              ),
              run.color(theme),
            );
          }
        }
      }
    }
    // `_hidesCompositionCaret` is an explicit request, not a missing value: an
    // input method that draws its own caret in the candidate window asks for
    // the document's to be hidden (`cursor_begin == cursor_end == -1` on
    // Wayland), and two carets on screen is exactly the confusion it is trying
    // to avoid.
    if (looksFocused && !_controller.hasSelection && !_hidesCompositionCaret) {
      // The caret's x comes from the paragraph *with its affinity*, which is
      // the whole reason the controller carries one: at a direction change the
      // same offset is the trailing edge of one run and the leading edge of
      // another, and those are different places on the line.
      //
      // Only the x is taken. The vertical placement stays with the control's
      // single-line metrics because the text beside it is drawn by
      // `paintLabel`, which owns that baseline; a caret positioned from the
      // paragraph's line box and text positioned from the label painter would
      // be two independent answers to the same question. Making them one
      // answer means painting the text through the paragraph too, which is a
      // change to `ControlBehavior` - a file this work does not own.
      final double caretX = laid != null
          ? laid
              .getCaretRect(
                TextPosition(
                  _controller.selectionEnd,
                  affinity: _controller.affinity,
                ),
              )
              .left
          : labelOffsetOfIndex(text, _controller.selectionEnd);
      paintFill(
        list,
        Rect.fromLTWH(left + caretX, textTop - 1, 1, labelLineHeight + 2),
        theme.foreground,
      );
    }
  }

  /// The preedit split into the runs the input method described, in document
  /// offsets.
  ///
  /// One run covering the whole region when no clauses were reported, which is
  /// every Wayland composition and every Win32 one before the first
  /// `GCS_COMPATTR`. Clause offsets are relative to the preedit and are
  /// translated here, clamped to the region: the platform's idea of the preedit
  /// length and this document's can differ by a frame when an edit raced the
  /// message, and a clause that ran past the end would ask the paragraph for
  /// boxes it has no glyphs for.
  List<_CompositionRun> _compositionRuns(TextRange composing) {
    if (_compositionClauses.isEmpty) {
      return <_CompositionRun>[
        _CompositionRun(composing.start, composing.end,
            ImeCompositionStyle.input),
      ];
    }
    final runs = <_CompositionRun>[];
    for (final ImeCompositionClause clause in _compositionClauses) {
      final int start =
          (composing.start + clause.start).clamp(composing.start, composing.end);
      final int end =
          (composing.start + clause.end).clamp(composing.start, composing.end);
      if (end > start) runs.add(_CompositionRun(start, end, clause.style));
    }
    return runs.isEmpty
        ? <_CompositionRun>[
            _CompositionRun(
                composing.start, composing.end, ImeCompositionStyle.input),
          ]
        : runs;
  }

  void _onValueChanged(String value) {
    markNeedsPaint();
    // The caret rectangle and the surrounding text are both functions of this
    // value, so an edit is exactly when the input method needs to hear about
    // them - the candidate window follows the caret, and contextual conversion
    // needs the words around it. See [_syncTextInputState] for why the IME's
    // own edits do not travel this way.
    _syncTextInputState();
  }

  @override
  void detach() {
    _controller.removeListener(_onValueChanged);
    // Before the render object leaves the tree, not after: on Win32 the
    // connection restores the window's default input context on its way out,
    // and a field that dropped its reference first would leave IMM32 pointed
    // at a client that no longer exists.
    _releaseTextInput();
    // The mixin removes *its* focus listener in `super.detach()`; this one is
    // ours and it is not the same subscription. A field that left it behind
    // would keep a detached render object reachable from a node that outlives
    // it, and would re-attach an input method from a tree that is gone.
    focusNode?.removeListener(_onImeFocusChanged);
    super.detach();
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.textField,
        label: _label,
        // Never the real text when obscured: a screen reader announcing a
        // password aloud is the failure section 30.8 is about.
        value: _obscure ? null : _controller.value,
        states: <SemanticsState>{
          if (!enabled) SemanticsState.disabled,
          if (_readOnly) SemanticsState.readOnly,
          if (_obscure) SemanticsState.obscured,
          if (hasFocus) SemanticsState.focused,
        },
        actions: enabled
            ? const <SemanticsAction>{
                SemanticsAction.focus,
                SemanticsAction.setValue,
              }
            : const <SemanticsAction>{},
      );
}
