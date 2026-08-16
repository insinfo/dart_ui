/// The framework-owned control set.
///
/// Every control here satisfies the criterion in section 29.4 - built from Dart
/// code, measured and arranged by the layout tree, drawn by the CPU backend,
/// hit-tested, hoverable, pressable, focusable by Tab, activatable by
/// Space/Enter, and exposing a role to accessibility - **with no native control
/// anywhere**. A control that delegated any of those to the platform would
/// still look right on Windows and be missing on the other two backends.
///
/// The division of labour: a control widget reads the theme from context and
/// configures a render object; the render object owns state and painting via
/// [ControlBehavior]. Appearance therefore lives in one place and can be
/// replaced by a template without touching the control.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/display_list.dart';
import '../layout/edge_insets.dart';
import '../layout/render_box.dart';
import '../layout/render_viewport.dart';
import '../platform/input_events.dart';
import '../rendering/text/font_registry.dart';
import '../text/paragraph.dart' show Paragraph, TextBox;
import '../text/shaper.dart' show UnsupportedScriptException;
import '../text/typeface.dart' show ScaledTypeface;
import 'control.dart';
import 'element.dart';
import 'focus.dart';
import 'focus_scope.dart';
import 'semantics.dart';
import 'style.dart';
import 'text_editing.dart';
import 'theme.dart';
import 'widget.dart';

/// The editing model is part of this file's contract, not an implementation
/// detail of it: a caller that holds a [TextEditingController] needs
/// [TextEditingValue], [TextSelection] and [TextRange] to say anything about
/// it. Re-exported here rather than added to `lib/dart_ui.dart` so the whole
/// text-editing surface arrives with the control that uses it.
export 'text_editing.dart';

// ---------------------------------------------------------------------------
// Observable values and text editing state
// ---------------------------------------------------------------------------

/// A mutable value with synchronous listeners.
///
/// Synchronous on purpose: a control that learns about a change one microtask
/// later paints one frame with the old value, and that frame is visible.
class ValueNotifier<T> {
  ValueNotifier(this._value);

  T _value;
  final List<void Function(T value)> _listeners = <void Function(T value)>[];

  T get value => _value;

  set value(T value) {
    if (value == _value) return;
    _value = value;
    notifyListeners();
  }

  void addListener(void Function(T value) listener) => _listeners.add(listener);

  void removeListener(void Function(T value) listener) =>
      _listeners.remove(listener);

  void notifyListeners() {
    for (final void Function(T) listener in List<void Function(T)>.of(
      _listeners,
    )) {
      listener(_value);
    }
  }
}

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
    _base = _value.length;
    _extent = _value.length;
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
        text: _value,
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
    _value = next.text;
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
    if (value == _value) return;
    _value = value;
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
    _base = TextMotion.snapDown(_value, start);
    _extent = TextMotion.snapDown(_value, end);
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
    _value = next;
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
    _deleteRange(TextMotion.previousCluster(_value, _extent), _extent);
  }

  /// Deletes forwards, the Delete key, one grapheme cluster at a time.
  void deleteForward() {
    if (hasSelection) {
      replaceSelection('');
      return;
    }
    _deleteRange(_extent, TextMotion.nextCluster(_value, _extent));
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
    _deleteRange(TextMotion.previousWord(_value, _extent), _extent);
  }

  /// Ctrl+Delete: deletes forward to the start of the next word.
  void deleteWordForward() {
    if (hasSelection) {
      replaceSelection('');
      return;
    }
    _deleteRange(_extent, TextMotion.nextWord(_value, _extent));
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
          ? TextMotion.previousCluster(_value, target)
          : TextMotion.nextCluster(_value, target);
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
        ? TextMotion.previousWord(_value, _extent)
        : TextMotion.nextWord(_value, _extent);
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
        '${_value.substring(0, start)}$composingText${_value.substring(end)}';
    _value = next;
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
        '${_value.substring(0, start)}$text${_value.substring(_composing.end)}';
    _value = next;
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
    _value = state.text;
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

  /// Removes `[from, to)`, collapsing the caret where the text was.
  ///
  /// Silent and free when the range is empty, which is what makes backspace at
  /// offset zero and Delete at the end do nothing at all rather than pushing an
  /// undo entry that restores the same string.
  void _deleteRange(int from, int to) {
    if (from >= to) return;
    _pushUndo();
    _value = _value.substring(0, from) + _value.substring(to);
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
    _base = TextMotion.snapDown(_value, _base.clamp(0, _value.length));
    _extent = TextMotion.snapDown(_value, _extent.clamp(0, _value.length));
  }
}

// ---------------------------------------------------------------------------
// Button and toggles
// ---------------------------------------------------------------------------

/// A push button.
final class Button extends StatefulWidget {
  const Button({
    super.key,
    required this.label,
    this.onPressed,
    this.isDefault = false,
    this.isCancel = false,
    this.styleClasses = const <String>{},
  });

  final String label;
  final void Function()? onPressed;

  /// The button Enter activates when nothing else has focus.
  final bool isDefault;

  /// The button Escape activates.
  final bool isCancel;

  final Set<String> styleClasses;

  @override
  State<Button> createState() => _ButtonState();
}

final class _ButtonState extends State<Button> {
  late final FocusNode _focusNode = FocusNode(debugLabel: 'Button');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FocusAttachment(
        node: _focusNode,
        child: _ButtonRenderWidget(
          label: widget.label,
          onPressed: widget.onPressed,
          theme: Theme.of(context),
          focusNode: _focusNode,
          isDefault: widget.isDefault,
          isCancel: widget.isCancel,
          styleClasses: widget.styleClasses,
        ),
      );
}

final class _ButtonRenderWidget extends RenderObjectWidget {
  const _ButtonRenderWidget({
    required this.label,
    required this.onPressed,
    required this.theme,
    required this.focusNode,
    required this.isDefault,
    required this.isCancel,
    required this.styleClasses,
  });

  final String label;
  final void Function()? onPressed;
  final ThemeData theme;
  final FocusNode focusNode;
  final bool isDefault;
  final bool isCancel;
  final Set<String> styleClasses;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderButton createRenderObject(BuildContext context) => RenderButton(
        label: label,
        onPressed: onPressed,
      )
        ..theme = theme
        ..focusNode = focusNode
        ..enabled = onPressed != null
        ..isDefault = isDefault
        ..isCancel = isCancel
        ..styleClasses = styleClasses;

  @override
  void updateRenderObject(BuildContext context, covariant RenderButton object) {
    object
      ..label = label
      ..onPressed = onPressed
      ..theme = theme
      ..focusNode = focusNode
      ..enabled = onPressed != null
      ..isDefault = isDefault
      ..isCancel = isCancel
      ..styleClasses = styleClasses;
  }
}

final class RenderButton extends RenderBox with ControlBehavior {
  RenderButton({required String label, this.onPressed}) : _label = label;

  String _label;
  void Function()? onPressed;
  bool isDefault = false;
  bool isCancel = false;

  String get label => _label;

  set label(String value) {
    if (value == _label) return;
    _label = value;
    markNeedsLayout();
  }

  @override
  void activate() => onPressed?.call();

  @override
  void performLayout() => size = constraints.constrain(labelledSize(_label));

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      size.width,
      size.height,
    );
    paintFill(list, rect, surfaceColor());
    if (theme.highContrast || !enabled) {
      paintBorder(
          list, rect, enabled ? theme.border : theme.disabledForeground);
    }
    if (isDefault && enabled) paintBorder(list, rect, theme.focusRing);
    paintCenteredLabel(
      list,
      _label,
      rect,
      enabled ? theme.surfaceAlternate : theme.disabledForeground,
    );
    paintFocusRing(list, rect);
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.button,
        label: _label,
        states: <SemanticsState>{
          if (!enabled) SemanticsState.disabled,
          if (hasFocus) SemanticsState.focused,
        },
        actions: enabled
            ? const <SemanticsAction>{
                SemanticsAction.activate,
                SemanticsAction.focus,
              }
            : const <SemanticsAction>{},
        mergesDescendants: true,
      );
}

/// A button that carries an on/off value.
final class ToggleButton extends StatefulWidget {
  const ToggleButton({
    super.key,
    required this.label,
    required this.value,
    this.onChanged,
  });

  final String label;
  final bool value;
  final void Function(bool value)? onChanged;

  @override
  State<ToggleButton> createState() => _ToggleButtonState();
}

final class _ToggleButtonState extends State<ToggleButton> {
  late final FocusNode _focusNode = FocusNode(debugLabel: 'ToggleButton');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FocusAttachment(
        node: _focusNode,
        child: _ToggleRenderWidget(
          label: widget.label,
          value: widget.value,
          onChanged: widget.onChanged,
          theme: Theme.of(context),
          focusNode: _focusNode,
          style: ToggleStyle.button,
        ),
      );
}

/// How a two-state control draws itself.
enum ToggleStyle { button, checkBox, radio, switchControl }

final class _ToggleRenderWidget extends RenderObjectWidget {
  const _ToggleRenderWidget({
    required this.label,
    required this.value,
    required this.onChanged,
    required this.theme,
    required this.focusNode,
    required this.style,
    this.tristate = false,
    this.isNull = false,
  });

  final String label;
  final bool value;
  final void Function(bool value)? onChanged;
  final ThemeData theme;
  final FocusNode focusNode;
  final ToggleStyle style;
  final bool tristate;
  final bool isNull;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderToggle createRenderObject(BuildContext context) => RenderToggle(
        label: label,
        value: value,
        style: style,
        onChanged: onChanged,
      )
        ..theme = theme
        ..focusNode = focusNode
        ..enabled = onChanged != null
        ..isIndeterminate = isNull;

  @override
  void updateRenderObject(BuildContext context, covariant RenderToggle object) {
    object
      ..label = label
      ..value = value
      ..onChanged = onChanged
      ..theme = theme
      ..focusNode = focusNode
      ..enabled = onChanged != null
      ..isIndeterminate = isNull;
  }
}

/// The shared render object behind CheckBox, Radio, Switch and ToggleButton.
///
/// One class rather than four, because they differ only in the glyph they draw
/// and the role they report - the state machine, the keyboard activation and
/// the focus handling are identical, and four copies of that is four chances
/// for them to drift.
final class RenderToggle extends RenderBox with ControlBehavior {
  RenderToggle({
    required String label,
    required bool value,
    required this.style,
    this.onChanged,
  })  : _label = label,
        _value = value;

  final ToggleStyle style;
  String _label;
  bool _value;
  bool _indeterminate = false;
  void Function(bool value)? onChanged;

  /// The size of the box or circle drawn beside the label.
  static const double indicatorExtent = 14.0;

  String get label => _label;

  set label(String value) {
    if (value == _label) return;
    _label = value;
    markNeedsLayout();
  }

  bool get value => _value;

  set value(bool next) {
    if (next == _value) return;
    _value = next;
    markNeedsPaint();
  }

  /// The mixed state of a tri-state check box.
  bool get isIndeterminate => _indeterminate;

  set isIndeterminate(bool next) {
    if (next == _indeterminate) return;
    _indeterminate = next;
    markNeedsPaint();
  }

  @override
  void activate() => onChanged?.call(!_value);

  @override
  void performLayout() {
    if (style == ToggleStyle.button) {
      size = constraints.constrain(labelledSize(_label));
      return;
    }
    final double indicator = style == ToggleStyle.switchControl
        ? indicatorExtent * 1.8
        : indicatorExtent;
    final Size text = measureLabel(_label);
    size = constraints.constrain(Size(
      indicator + (text.width > 0 ? text.width + 6 : 0),
      theme.effectiveControlHeight,
    ));
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      size.width,
      size.height,
    );
    switch (style) {
      case ToggleStyle.button:
        paintFill(
          list,
          rect,
          _value ? surfaceColor(normal: theme.accentPressed) : surfaceColor(),
        );
        paintCenteredLabel(list, _label, rect, theme.surfaceAlternate);
        paintFocusRing(list, rect);
      case ToggleStyle.checkBox:
        _paintIndicator(list, rect, square: true);
      case ToggleStyle.radio:
        _paintIndicator(list, rect, square: false);
      case ToggleStyle.switchControl:
        _paintSwitch(list, rect);
    }
  }

  void _paintIndicator(DisplayList list, Rect rect, {required bool square}) {
    final double top =
        (rect.top + (rect.height - indicatorExtent) / 2).roundToDouble();
    final Rect box =
        Rect.fromLTWH(rect.left, top, indicatorExtent, indicatorExtent);
    paintFill(
        list, box, enabled ? theme.surfaceAlternate : theme.disabledSurface);
    paintBorder(
      list,
      box,
      isHovered && enabled ? theme.accentHovered : theme.border,
    );
    if (_indeterminate) {
      // A mixed check box is a bar, not a tick: a partially checked group is
      // not the same claim as a checked one and must not look like it.
      paintFill(
        list,
        Rect.fromLTWH(box.left + 3, box.top + indicatorExtent / 2 - 1,
            indicatorExtent - 6, 2),
        enabled ? theme.accent : theme.disabledForeground,
      );
    } else if (_value) {
      final int mark = enabled ? theme.accent : theme.disabledForeground;
      if (square) {
        paintFill(
          list,
          Rect.fromLTWH(box.left + 3, box.top + 3, indicatorExtent - 6,
              indicatorExtent - 6),
          mark,
        );
      } else {
        // A circle is still a rect here: the rasterizer owns round shapes, and
        // an inset square reads correctly at 14 px until it does.
        paintFill(
          list,
          Rect.fromLTWH(box.left + 4, box.top + 4, indicatorExtent - 8,
              indicatorExtent - 8),
          mark,
        );
      }
    }
    paintLabel(
      list,
      _label,
      Offset(
        box.right + 6,
        (rect.top + (rect.height - labelLineHeight) / 2).roundToDouble(),
      ),
      foregroundColor(),
    );
    paintFocusRing(list, rect);
  }

  void _paintSwitch(DisplayList list, Rect rect) {
    const double width = indicatorExtent * 1.8;
    final double top =
        (rect.top + (rect.height - indicatorExtent) / 2).roundToDouble();
    final Rect track = Rect.fromLTWH(rect.left, top, width, indicatorExtent);
    paintFill(
      list,
      track,
      !enabled
          ? theme.disabledSurface
          : _value
              ? theme.accent
              : theme.surface,
    );
    paintBorder(list, track, theme.border);
    const double thumb = indicatorExtent - 4;
    paintFill(
      list,
      Rect.fromLTWH(
        _value ? track.right - thumb - 2 : track.left + 2,
        top + 2,
        thumb,
        thumb,
      ),
      enabled ? theme.surfaceAlternate : theme.disabledForeground,
    );
    paintLabel(
      list,
      _label,
      Offset(
        track.right + 6,
        (rect.top + (rect.height - labelLineHeight) / 2).roundToDouble(),
      ),
      foregroundColor(),
    );
    paintFocusRing(list, rect);
  }

  @override
  Set<PseudoClass> get controlStates => <PseudoClass>{
        if (_value) PseudoClass.checked,
      };

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: switch (style) {
          ToggleStyle.checkBox => SemanticsRole.checkbox,
          ToggleStyle.radio => SemanticsRole.radio,
          ToggleStyle.switchControl => SemanticsRole.toggleButton,
          ToggleStyle.button => SemanticsRole.toggleButton,
        },
        label: _label,
        value: _indeterminate
            ? 'mixed'
            : _value
                ? 'checked'
                : 'unchecked',
        states: <SemanticsState>{
          if (_indeterminate)
            SemanticsState.mixed
          else if (_value)
            SemanticsState.checked,
          if (!enabled) SemanticsState.disabled,
          if (hasFocus) SemanticsState.focused,
        },
        actions: enabled
            ? const <SemanticsAction>{
                SemanticsAction.activate,
                SemanticsAction.focus,
              }
            : const <SemanticsAction>{},
        mergesDescendants: true,
      );
}

/// A two- or three-state check box.
final class CheckBox extends StatefulWidget {
  const CheckBox({
    super.key,
    required this.value,
    this.label = '',
    this.onChanged,
    this.tristate = false,
  });

  /// Null means mixed, which is only legal when [tristate].
  final bool? value;
  final String label;
  final void Function(bool value)? onChanged;
  final bool tristate;

  @override
  State<CheckBox> createState() => _CheckBoxState();
}

final class _CheckBoxState extends State<CheckBox> {
  late final FocusNode _focusNode = FocusNode(debugLabel: 'CheckBox');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FocusAttachment(
        node: _focusNode,
        child: _ToggleRenderWidget(
          label: widget.label,
          value: widget.value ?? false,
          isNull: widget.value == null,
          tristate: widget.tristate,
          onChanged: widget.onChanged,
          theme: Theme.of(context),
          focusNode: _focusNode,
          style: ToggleStyle.checkBox,
        ),
      );
}

/// One option of a mutually exclusive group.
final class Radio<T> extends StatefulWidget {
  const Radio({
    super.key,
    required this.value,
    required this.groupValue,
    this.label = '',
    this.onChanged,
  });

  final T value;
  final T? groupValue;
  final String label;
  final void Function(T value)? onChanged;

  @override
  State<Radio<T>> createState() => _RadioState<T>();
}

final class _RadioState<T> extends State<Radio<T>> {
  late final FocusNode _focusNode = FocusNode(debugLabel: 'Radio');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final void Function(T value)? onChanged = widget.onChanged;
    return FocusAttachment(
      node: _focusNode,
      child: _ToggleRenderWidget(
        label: widget.label,
        value: widget.value == widget.groupValue,
        // Selecting an already-selected radio is a no-op, not a deselect: a
        // radio group has no empty state once one option is chosen.
        onChanged:
            onChanged == null ? null : (bool _) => onChanged(widget.value),
        theme: Theme.of(context),
        focusNode: _focusNode,
        style: ToggleStyle.radio,
      ),
    );
  }
}

/// An on/off switch.
final class Switch extends StatefulWidget {
  const Switch({
    super.key,
    required this.value,
    this.label = '',
    this.onChanged,
  });

  final bool value;
  final String label;
  final void Function(bool value)? onChanged;

  @override
  State<Switch> createState() => _SwitchState();
}

final class _SwitchState extends State<Switch> {
  late final FocusNode _focusNode = FocusNode(debugLabel: 'Switch');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FocusAttachment(
        node: _focusNode,
        child: _ToggleRenderWidget(
          label: widget.label,
          value: widget.value,
          onChanged: widget.onChanged,
          theme: Theme.of(context),
          focusNode: _focusNode,
          style: ToggleStyle.switchControl,
        ),
      );
}

// ---------------------------------------------------------------------------
// Slider and progress
// ---------------------------------------------------------------------------

final class Slider extends StatefulWidget {
  const Slider({
    super.key,
    required this.value,
    this.min = 0,
    this.max = 1,
    this.step = 0.1,
    this.onChanged,
  });

  final double value;
  final double min;
  final double max;
  final double step;
  final void Function(double value)? onChanged;

  @override
  State<Slider> createState() => _SliderState();
}

final class _SliderState extends State<Slider> {
  late final FocusNode _focusNode = FocusNode(debugLabel: 'Slider');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FocusAttachment(
        node: _focusNode,
        child: _SliderRenderWidget(
          value: widget.value,
          min: widget.min,
          max: widget.max,
          step: widget.step,
          onChanged: widget.onChanged,
          theme: Theme.of(context),
          focusNode: _focusNode,
        ),
      );
}

final class _SliderRenderWidget extends RenderObjectWidget {
  const _SliderRenderWidget({
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.onChanged,
    required this.theme,
    required this.focusNode,
  });

  final double value;
  final double min;
  final double max;
  final double step;
  final void Function(double value)? onChanged;
  final ThemeData theme;
  final FocusNode focusNode;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderSlider createRenderObject(BuildContext context) => RenderSlider(
        value: value,
        min: min,
        max: max,
        step: step,
        onChanged: onChanged,
      )
        ..theme = theme
        ..focusNode = focusNode
        ..enabled = onChanged != null;

  @override
  void updateRenderObject(BuildContext context, covariant RenderSlider object) {
    object
      ..value = value
      ..min = min
      ..max = max
      ..step = step
      ..onChanged = onChanged
      ..theme = theme
      ..focusNode = focusNode
      ..enabled = onChanged != null;
  }
}

final class RenderSlider extends RenderBox with ControlBehavior {
  RenderSlider({
    required double value,
    required double min,
    required double max,
    required this.step,
    this.onChanged,
  })  : _value = value,
        _min = min,
        _max = max;

  static const double trackThickness = 4.0;
  static const double thumbExtent = 12.0;

  double _value;
  double _min;
  double _max;
  double step;
  void Function(double value)? onChanged;

  double get value => _value;

  set value(double next) {
    if (next == _value) return;
    _value = next;
    markNeedsPaint();
  }

  double get min => _min;

  set min(double next) {
    if (next == _min) return;
    _min = next;
    markNeedsPaint();
  }

  double get max => _max;

  set max(double next) {
    if (next == _max) return;
    _max = next;
    markNeedsPaint();
  }

  /// Where the value sits in its range, 0 to 1. Guards a zero-width range,
  /// which would otherwise divide by zero on a slider with min == max.
  double get normalized {
    final double range = _max - _min;
    if (range <= 0) return 0;
    return ((_value - _min) / range).clamp(0.0, 1.0);
  }

  void _emit(double next) {
    final double clamped = next.clamp(_min, _max);
    if (clamped == _value) return;
    onChanged?.call(clamped);
  }

  @override
  void activate() {}

  @override
  void performLayout() => size = constraints.constrain(
        Size(140, theme.effectiveControlHeight),
      );

  @override
  bool hitTestSelf(Offset position) => true;

  /// True from the press until the release, whether or not the pointer is
  /// still over the slider.
  ///
  /// [ControlBehavior.isPressed] cannot serve here: it deliberately goes false
  /// when a captured pointer wanders off, so the control stops *looking*
  /// pressed. A slider must keep *tracking* in exactly that situation - a
  /// mouse drifting above or below the track is the normal way people drag one
  /// - so the two states are genuinely different and need separate fields.
  bool _dragging = false;

  @override
  void handlePointerEvent(PointerEvent event) {
    super.handlePointerEvent(event);
    if (!enabled) return;
    switch (event) {
      // Pressing anywhere on the track jumps there and starts a drag, which is
      // what a scrollbar-style slider does on all three targets.
      case PointerDownEvent(button: PointerButton.primary):
        _dragging = true;
      case PointerUpEvent() || PointerCancelEvent():
        _dragging = false;
        return;
      case PointerMoveEvent():
        if (!_dragging) return;
      default:
        return;
    }
    // The pointer is captured by now, so its position may be anywhere on
    // screen - including well outside this control. Converting into this
    // slider's own space and then clamping onto the track is what lets the
    // drag continue when the mouse is above, below, or past the end of it.
    final Offset local = globalToLocal(event.logicalPosition);
    final double usable =
        (size.width - thumbExtent).clamp(1.0, double.infinity);
    final double fraction =
        ((local.dx - thumbExtent / 2) / usable).clamp(0.0, 1.0);
    _emit(_min + fraction * (_max - _min));
  }

  @override
  bool handleKeyEvent(KeyEvent event) {
    if (!enabled || event is! KeyDownEvent) return false;
    switch (event.logicalKey) {
      case logicalKeyArrowLeft || logicalKeyArrowDown:
        _emit(_value - step);
        return true;
      case logicalKeyArrowRight || logicalKeyArrowUp:
        _emit(_value + step);
        return true;
      case logicalKeyHome:
        _emit(_min);
        return true;
      case logicalKeyEnd:
        _emit(_max);
        return true;
      case logicalKeyPageDown:
        _emit(_value - step * 5);
        return true;
      case logicalKeyPageUp:
        _emit(_value + step * 5);
        return true;
      default:
        return false;
    }
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final double centerY =
        (offset.dy + size.height / 2 - trackThickness / 2).roundToDouble();
    final Rect track = Rect.fromLTWH(
      offset.dx,
      centerY,
      size.width,
      trackThickness,
    );
    paintFill(list, track, enabled ? theme.surface : theme.disabledSurface);
    paintBorder(list, track, theme.border);
    final double usable =
        (size.width - thumbExtent).clamp(0.0, double.infinity);
    final double thumbLeft = (offset.dx + usable * normalized).roundToDouble();
    paintFill(
      list,
      Rect.fromLTWH(offset.dx, centerY, thumbLeft - offset.dx, trackThickness),
      enabled ? theme.accent : theme.disabledForeground,
    );
    final Rect thumb = Rect.fromLTWH(
      thumbLeft,
      (offset.dy + size.height / 2 - thumbExtent / 2).roundToDouble(),
      thumbExtent,
      thumbExtent,
    );
    paintFill(
      list,
      thumb,
      !enabled
          ? theme.disabledForeground
          : isPressed
              ? theme.accentPressed
              : isHovered
                  ? theme.accentHovered
                  : theme.accent,
    );
    paintBorder(list, thumb, theme.border);
    paintFocusRing(
      list,
      Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height),
    );
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.slider,
        value: _value.toStringAsFixed(2),
        increasedValue: (_value + step).clamp(_min, _max).toStringAsFixed(2),
        decreasedValue: (_value - step).clamp(_min, _max).toStringAsFixed(2),
        states: <SemanticsState>{
          if (!enabled) SemanticsState.disabled,
          if (hasFocus) SemanticsState.focused,
        },
        actions: enabled
            ? const <SemanticsAction>{
                SemanticsAction.increment,
                SemanticsAction.decrement,
                SemanticsAction.setValue,
                SemanticsAction.focus,
              }
            : const <SemanticsAction>{},
      );
}

/// A determinate progress bar.
final class ProgressBar extends StatelessWidget {
  const ProgressBar({super.key, required this.value});

  /// 0 to 1.
  final double value;

  @override
  Widget build(BuildContext context) =>
      _ProgressRenderWidget(value: value, theme: Theme.of(context));
}

final class _ProgressRenderWidget extends RenderObjectWidget {
  const _ProgressRenderWidget({required this.value, required this.theme});

  final double value;
  final ThemeData theme;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderProgressBar createRenderObject(BuildContext context) =>
      RenderProgressBar(value: value)..theme = theme;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderProgressBar object,
  ) {
    object
      ..value = value
      ..theme = theme;
  }
}

final class RenderProgressBar extends RenderBox with ControlBehavior {
  RenderProgressBar({required double value}) : _value = value;

  double _value;

  double get value => _value;

  set value(double next) {
    if (next == _value) return;
    _value = next;
    markNeedsPaint();
  }

  @override
  bool get focusOnPointerDown => false;

  @override
  void performLayout() => size = constraints.constrain(const Size(140, 6));

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      size.width,
      size.height,
    );
    paintFill(list, rect, theme.surface);
    paintBorder(list, rect, theme.border);
    paintFill(
      list,
      Rect.fromLTWH(
        rect.left,
        rect.top,
        (rect.width * _value.clamp(0.0, 1.0)).roundToDouble(),
        rect.height,
      ),
      theme.accent,
    );
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.progressBar,
        value: '${(_value.clamp(0.0, 1.0) * 100).round()}%',
      );
}

// ---------------------------------------------------------------------------
// Text entry
// ---------------------------------------------------------------------------

final class TextField extends StatefulWidget {
  const TextField({
    super.key,
    required this.controller,
    this.label = '',
    this.obscure = false,
    this.readOnly = false,
    this.enabled = true,
  });

  final TextEditingController controller;
  final String label;

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
  late final FocusNode _focusNode = FocusNode(debugLabel: 'TextField');

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
    _focusNode.dispose();
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
          theme: Theme.of(context),
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
    required this.theme,
    required this.focusNode,
  });

  final TextEditingController controller;
  final String label;
  final bool obscure;
  final bool readOnly;
  final bool enabled;
  final ThemeData theme;
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
        ..theme = theme
        ..focusNode = focusNode
        ..enabled = enabled;

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
      ..theme = theme
      ..focusNode = focusNode
      ..enabled = enabled;
  }
}

final class RenderTextField extends RenderBox with ControlBehavior {
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

  @override
  void handlePointerEvent(PointerEvent event) {
    super.handlePointerEvent(event);
    if (!enabled || event is! PointerDownEvent) return;
    // Place the caret where the click landed. The text painted is not the text
    // stored when the field is obscured, so the hit test measures what is on
    // screen; anything else puts the caret at the wrong bullet.
    final Offset local = globalToLocal(event.logicalPosition);
    final double x = local.dx - theme.effectiveControlPadding;
    final Paragraph? laid = paragraph;
    if (laid != null) {
      // The paragraph snaps to a grapheme cluster and reports which side of the
      // boundary was hit, so a click on the right half of an emoji lands after
      // it rather than between its surrogates, and the affinity it returns is
      // what puts the caret on the correct side of a direction change.
      _controller.collapseToPosition(laid.getPositionForOffset(Offset(x, 0)));
      return;
    }
    final int index =
        labelIndexAtOffset(displayText, x).clamp(0, _controller.value.length);
    _controller.collapseTo(index);
  }

  @override
  bool handleKeyEvent(KeyEvent event) {
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
        if (_readOnly) return true;
        _controller.deleteForward();
        return true;
      case logicalKeyTab:
      case logicalKeyEscape:
        // Declined on purpose: Tab belongs to traversal and Escape to whatever
        // is dismissible above, and a text field that ate them would strand a
        // keyboard user inside it.
        return false;
    }
    if (_readOnly) return false;
    if (event.logicalKey >= 0x20 && event.logicalKey <= 0x7E) {
      _controller.replaceSelection(String.fromCharCode(event.logicalKey));
      return true;
    }
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
    paintFill(
      list,
      rect,
      enabled ? theme.surfaceAlternate : theme.disabledSurface,
    );
    paintBorder(list, rect, hasFocus ? theme.accent : theme.border);
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
      if (_controller.hasSelection && !_obscure) {
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
              theme.selection,
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
            theme.selection,
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
      if (_controller.isComposing && !_obscure && laid != null) {
        final TextRange composing = _controller.composing;
        for (final TextBox box
            in laid.getBoxesForSelection(composing.start, composing.end)) {
          paintFill(
            list,
            Rect.fromLTWH(
              left + box.rect.left,
              textTop + labelLineHeight,
              box.rect.width,
              1,
            ),
            theme.foreground,
          );
        }
      }
    }
    if (hasFocus && !_controller.hasSelection) {
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

  void _onValueChanged(String value) => markNeedsPaint();

  @override
  void detach() {
    _controller.removeListener(_onValueChanged);
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

// ---------------------------------------------------------------------------
// Containers: scroll, dialog, menu, tooltip
// ---------------------------------------------------------------------------

/// Scrolls one child, with a scrollbar and wheel/keyboard handling.
final class ScrollViewer extends StatefulWidget {
  const ScrollViewer({
    super.key,
    required this.child,
    this.axis = ScrollAxis.vertical,
    this.controller,
  });

  final Widget child;
  final ScrollAxis axis;
  final ScrollPosition? controller;

  @override
  State<ScrollViewer> createState() => _ScrollViewerState();
}

final class _ScrollViewerState extends State<ScrollViewer> {
  late final ScrollPosition _position =
      widget.controller ?? ScrollPosition(axis: widget.axis);

  @override
  Widget build(BuildContext context) => _ScrollViewerRenderWidget(
        position: _position,
        theme: Theme.of(context),
        child: widget.child,
      );
}

final class _ScrollViewerRenderWidget extends SingleChildRenderObjectWidget {
  const _ScrollViewerRenderWidget({
    required this.position,
    required this.theme,
    required super.child,
  });

  final ScrollPosition position;
  final ThemeData theme;

  @override
  RenderScrollViewer createRenderObject(BuildContext context) =>
      RenderScrollViewer(position: position)..theme = theme;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderScrollViewer object,
  ) {
    object
      ..position = position
      ..theme = theme;
  }
}

/// A viewport that also handles wheel, keyboard and scrollbar painting.
final class RenderScrollViewer extends RenderViewport with ControlBehavior {
  RenderScrollViewer({required super.position, super.child});

  static const double scrollbarThickness = 8.0;

  @override
  bool get focusOnPointerDown => false;

  @override
  void handlePointerEvent(PointerEvent event) {
    super.handlePointerEvent(event);
    if (event is! PointerScrollEvent) return;
    final double delta = position.axis == ScrollAxis.vertical
        ? event.scrollDelta.dy
        : event.scrollDelta.dx;
    position.applyScrollDelta(
      delta,
      inLines: event.scrollDeltaUnit == ScrollDeltaUnit.lines,
    );
  }

  @override
  bool handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    switch (event.logicalKey) {
      case logicalKeyArrowDown:
        return position.applyDelta(defaultLineExtent) == 0;
      case logicalKeyArrowUp:
        return position.applyDelta(-defaultLineExtent) == 0;
      case logicalKeyPageDown:
        return position.pageBy(1) == 0;
      case logicalKeyPageUp:
        return position.pageBy(-1) == 0;
      case logicalKeyHome:
        return position.jumpTo(0);
      case logicalKeyEnd:
        return position.jumpTo(position.maxScrollExtent);
      default:
        return false;
    }
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(DisplayList list, Offset offset) {
    super.paint(list, offset);
    final ({double start, double extent})? thumb = position.thumb;
    if (thumb == null) return;
    final bool vertical = position.axis == ScrollAxis.vertical;
    final double trackExtent = vertical ? size.height : size.width;
    final Rect track = vertical
        ? Rect.fromLTWH(offset.dx + size.width - scrollbarThickness, offset.dy,
            scrollbarThickness, size.height)
        : Rect.fromLTWH(offset.dx, offset.dy + size.height - scrollbarThickness,
            size.width, scrollbarThickness);
    paintFill(list, track, theme.surface);
    final double thumbStart = (thumb.start * trackExtent).roundToDouble();
    final double thumbExtent =
        (thumb.extent * trackExtent).clamp(12.0, trackExtent);
    paintFill(
      list,
      vertical
          ? Rect.fromLTWH(track.left, track.top + thumbStart,
              scrollbarThickness, thumbExtent)
          : Rect.fromLTWH(track.left + thumbStart, track.top, thumbExtent,
              scrollbarThickness),
      isHovered ? theme.accentHovered : theme.foregroundSecondary,
    );
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.scrollView,
        value: position.pixels.toStringAsFixed(0),
        actions: <SemanticsAction>{
          if (position.axis == ScrollAxis.vertical) ...<SemanticsAction>{
            if (!position.atEnd) SemanticsAction.scrollDown,
            if (!position.atStart) SemanticsAction.scrollUp,
          } else ...<SemanticsAction>{
            if (!position.atEnd) SemanticsAction.scrollRight,
            if (!position.atStart) SemanticsAction.scrollLeft,
          },
        },
      );
}

/// A modal surface with a title.
final class Dialog extends StatelessWidget {
  const Dialog({
    super.key,
    required this.title,
    required this.child,
    this.onDismiss,
  });

  final String title;
  final Widget child;
  final void Function()? onDismiss;

  @override
  Widget build(BuildContext context) => _DialogRenderWidget(
        title: title,
        theme: Theme.of(context),
        onDismiss: onDismiss,
        child: child,
      );
}

final class _DialogRenderWidget extends SingleChildRenderObjectWidget {
  const _DialogRenderWidget({
    required this.title,
    required this.theme,
    required this.onDismiss,
    required super.child,
  });

  final String title;
  final ThemeData theme;
  final void Function()? onDismiss;

  @override
  RenderDialog createRenderObject(BuildContext context) =>
      RenderDialog(title: title, onDismiss: onDismiss)..theme = theme;

  @override
  void updateRenderObject(BuildContext context, covariant RenderDialog object) {
    object
      ..title = title
      ..onDismiss = onDismiss
      ..theme = theme;
  }
}

final class RenderDialog extends RenderSingleChildBox with ControlBehavior {
  RenderDialog({required String title, this.onDismiss}) : _title = title;

  static const double titleBarHeight = 22.0;

  String _title;
  void Function()? onDismiss;

  String get title => _title;

  set title(String value) {
    if (value == _title) return;
    _title = value;
    markNeedsPaint();
  }

  @override
  bool get focusOnPointerDown => false;

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    final double padding = theme.effectiveControlPadding;
    if (child == null) {
      size = constraints.constrain(Size(120, titleBarHeight + padding * 2));
      return;
    }
    child.layout(
      constraints.deflate(EdgeInsets.only(
        left: padding,
        right: padding,
        top: titleBarHeight + padding,
        bottom: padding,
      )),
      parentUsesSize: true,
    );
    child.parentData!.offset = Offset(padding, titleBarHeight + padding);
    size = constraints.constrain(Size(
      child.size.width + padding * 2,
      child.size.height + titleBarHeight + padding * 2,
    ));
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  bool handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == logicalKeyEscape) {
      onDismiss?.call();
      return true;
    }
    return super.handleKeyEvent(event);
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      size.width,
      size.height,
    );
    paintFill(list, rect, theme.surfaceAlternate);
    paintBorder(list, rect, theme.border);
    final Rect titleBar =
        Rect.fromLTWH(rect.left, rect.top, rect.width, titleBarHeight);
    paintFill(list, titleBar, theme.accent);
    paintLabel(
      list,
      _title,
      Offset(
        rect.left + 4,
        (titleBar.top + (titleBarHeight - labelLineHeight) / 2).roundToDouble(),
      ),
      theme.surfaceAlternate,
      maxWidth: rect.width - 8,
    );
    super.paint(list, offset);
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.dialog,
        label: _title,
        states: const <SemanticsState>{SemanticsState.modal},
        actions: const <SemanticsAction>{SemanticsAction.dismiss},
        // A modal hides what is behind it from assistive technology too, which
        // is the accessibility half of "modal" and the half most often missed.
        isBlocking: true,
      );
}

/// One entry of a [Menu].
final class MenuItem {
  const MenuItem({
    required this.label,
    this.onSelected,
    this.enabled = true,
    this.isSeparator = false,
  });

  const MenuItem.separator()
      : label = '',
        onSelected = null,
        enabled = false,
        isSeparator = true;

  final String label;
  final void Function()? onSelected;
  final bool enabled;
  final bool isSeparator;
}

/// A vertical list of commands, keyboard-navigable.
final class Menu extends StatefulWidget {
  const Menu({super.key, required this.items});

  final List<MenuItem> items;

  @override
  State<Menu> createState() => _MenuState();
}

final class _MenuState extends State<Menu> {
  late final FocusNode _focusNode = FocusNode(debugLabel: 'Menu');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FocusAttachment(
        node: _focusNode,
        child: _MenuRenderWidget(
          items: widget.items,
          theme: Theme.of(context),
          focusNode: _focusNode,
        ),
      );
}

final class _MenuRenderWidget extends RenderObjectWidget {
  const _MenuRenderWidget({
    required this.items,
    required this.theme,
    required this.focusNode,
  });

  final List<MenuItem> items;
  final ThemeData theme;
  final FocusNode focusNode;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderMenu createRenderObject(BuildContext context) =>
      RenderMenu(items: items)
        ..theme = theme
        ..focusNode = focusNode;

  @override
  void updateRenderObject(BuildContext context, covariant RenderMenu object) {
    object
      ..items = items
      ..theme = theme
      ..focusNode = focusNode;
  }
}

final class RenderMenu extends RenderBox with ControlBehavior {
  RenderMenu({required List<MenuItem> items}) : _items = items;

  static const double itemHeight = 20.0;
  static const double separatorHeight = 5.0;

  List<MenuItem> _items;
  int _highlighted = -1;

  List<MenuItem> get items => _items;

  set items(List<MenuItem> value) {
    _items = value;
    _highlighted = _highlighted.clamp(-1, value.length - 1);
    markNeedsLayout();
  }

  /// The item the keyboard cursor is on, or -1.
  int get highlightedIndex => _highlighted;

  @override
  void performLayout() {
    double height = 0;
    double width = 0;
    for (final MenuItem item in _items) {
      height += item.isSeparator ? separatorHeight : itemHeight;
      final double itemWidth = measureLabel(item.label).width;
      if (itemWidth > width) width = itemWidth;
    }
    size = constraints.constrain(
      Size(width + theme.effectiveControlPadding * 2, height),
    );
  }

  @override
  bool hitTestSelf(Offset position) => true;

  /// The item index at [y] within this menu, or -1.
  int indexAt(double y) {
    double cursor = 0;
    for (int i = 0; i < _items.length; i++) {
      final double extent =
          _items[i].isSeparator ? separatorHeight : itemHeight;
      if (y >= cursor && y < cursor + extent) {
        return _items[i].isSeparator ? -1 : i;
      }
      cursor += extent;
    }
    return -1;
  }

  @override
  void handlePointerEvent(PointerEvent event) {
    super.handlePointerEvent(event);
    if (event is PointerMoveEvent) {
      final int index = indexAt(globalToLocal(event.logicalPosition).dy);
      if (index != _highlighted) {
        _highlighted = index;
        markNeedsPaint();
      }
    }
  }

  @override
  void activate() {
    if (_highlighted < 0 || _highlighted >= _items.length) return;
    final MenuItem item = _items[_highlighted];
    if (item.enabled) item.onSelected?.call();
  }

  @override
  bool handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    switch (event.logicalKey) {
      case logicalKeyArrowDown:
        _moveHighlight(1);
        return true;
      case logicalKeyArrowUp:
        _moveHighlight(-1);
        return true;
      case logicalKeyHome:
        _highlighted = -1;
        _moveHighlight(1);
        return true;
      case logicalKeyEnd:
        _highlighted = _items.length;
        _moveHighlight(-1);
        return true;
      default:
        return super.handleKeyEvent(event);
    }
  }

  /// Moves the highlight by [delta], skipping separators and disabled items.
  void _moveHighlight(int delta) {
    if (_items.isEmpty) return;
    int index = _highlighted;
    for (int step = 0; step < _items.length; step++) {
      index = (index + delta) % _items.length;
      if (index < 0) index += _items.length;
      final MenuItem item = _items[index];
      if (!item.isSeparator && item.enabled) {
        _highlighted = index;
        markNeedsPaint();
        return;
      }
    }
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      size.width,
      size.height,
    );
    paintFill(list, rect, theme.surfaceAlternate);
    paintBorder(list, rect, theme.border);
    double y = offset.dy;
    for (int i = 0; i < _items.length; i++) {
      final MenuItem item = _items[i];
      if (item.isSeparator) {
        paintFill(
          list,
          Rect.fromLTWH(
              offset.dx + 2, y + separatorHeight / 2, size.width - 4, 1),
          theme.border,
        );
        y += separatorHeight;
        continue;
      }
      if (i == _highlighted) {
        paintFill(
          list,
          Rect.fromLTWH(offset.dx + 1, y, size.width - 2, itemHeight),
          theme.accent,
        );
      }
      paintLabel(
        list,
        item.label,
        Offset(
          offset.dx + theme.effectiveControlPadding,
          (y + (itemHeight - labelLineHeight) / 2).roundToDouble(),
        ),
        !item.enabled
            ? theme.disabledForeground
            : i == _highlighted
                ? theme.surfaceAlternate
                : theme.foreground,
      );
      y += itemHeight;
    }
    paintFocusRing(list, rect);
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.menu,
        value: '${_items.where((MenuItem i) => !i.isSeparator).length} items',
        actions: const <SemanticsAction>{
          SemanticsAction.focus,
          SemanticsAction.dismiss,
        },
      );
}

/// A hover label attached to a child.
///
/// The tooltip's own surface is placed by [PopupPositioner] when it is shown;
/// this widget is the trigger and the message, not the window.
final class Tooltip extends StatelessWidget {
  const Tooltip({super.key, required this.message, required this.child});

  final String message;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// The surface a tooltip paints when shown.
final class TooltipSurface extends StatelessWidget {
  const TooltipSurface({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) =>
      _TooltipRenderWidget(message: message, theme: Theme.of(context));
}

final class _TooltipRenderWidget extends RenderObjectWidget {
  const _TooltipRenderWidget({required this.message, required this.theme});

  final String message;
  final ThemeData theme;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderTooltip createRenderObject(BuildContext context) =>
      RenderTooltip(message: message)..theme = theme;

  @override
  void updateRenderObject(
      BuildContext context, covariant RenderTooltip object) {
    object
      ..message = message
      ..theme = theme;
  }
}

final class RenderTooltip extends RenderBox with ControlBehavior {
  RenderTooltip({required String message}) : _message = message;

  String _message;

  String get message => _message;

  set message(String value) {
    if (value == _message) return;
    _message = value;
    markNeedsLayout();
  }

  @override
  bool get focusOnPointerDown => false;

  @override
  void performLayout() {
    final Size text = measureLabel(_message);
    size = constraints.constrain(Size(text.width + 8, text.height + 6));
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      size.width,
      size.height,
    );
    paintFill(list, rect, theme.surface);
    paintBorder(list, rect, theme.border);
    paintCenteredLabel(list, _message, rect, theme.foreground);
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.tooltip,
        label: _message,
      );
}
