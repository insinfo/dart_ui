/// Editing a text object *in the canvas*, with a real caret.
///
/// sK1 has a `TEXT_EDIT_MODE` reached by double-clicking a text with the
/// selection tool; this is that mode. Before it, the editor's own comment said
/// "the framework has no in-canvas text caret yet" and pushed the user at the
/// property bar instead - which is not the same feature: you cannot see where
/// the caret is, you cannot select a word, and the text you are editing is not
/// where you are looking.
///
/// **Nothing about text editing is re-implemented here.** The model is
/// [TextEditingValue] and the motion is [TextMotion], the same two the
/// framework's `TextField` is built on, so a caret in the canvas steps over a
/// grapheme cluster - an emoji, an `a` plus a combining accent - exactly as a
/// caret in a form field does. What this class adds is the three things a
/// canvas has and a field does not: the value lives in a document object, an
/// edit has to be undoable as one step, and Escape has to be able to put the
/// original string back.
library;

import '../../graphics/vector/primitives.dart';
import '../../platform/input_events.dart';
// The virtual-key codes the framework interprets itself live in `focus.dart`,
// which is where every other control reads them from; a private copy here
// would be a second source of truth for what Backspace is.
import '../focus.dart'
    show
        logicalKeyArrowLeft,
        logicalKeyArrowRight,
        logicalKeyBackspace,
        logicalKeyDelete,
        logicalKeyEnd,
        logicalKeyHome;
import '../text_editing.dart';
import 'text_metrics.dart';

/// A caret and a selection inside one [VectorText], while it is being edited.
final class CanvasTextEditor {
  CanvasTextEditor(this.object, {int? caretOffset})
      : originalText = object.textContent,
        _value = TextEditingValue(
          text: object.textContent,
          selection: TextSelection.collapsed(
            TextMotion.snapDown(
              object.textContent,
              (caretOffset ?? object.textContent.length)
                  .clamp(0, object.textContent.length),
            ),
          ),
        );

  /// The object being edited. Its `textContent` is kept in step with [value],
  /// so the canvas draws what is being typed with no extra plumbing.
  final VectorText object;

  /// What the text said when editing began, for Escape and for undo.
  final String originalText;

  TextEditingValue _value;

  TextEditingValue get value => _value;

  set value(TextEditingValue next) {
    _value = next;
    if (object.textContent != next.text) {
      object.textContent = next.text;
      // The box has to follow the string: a text that grew while being typed
      // would otherwise keep the selection frame - and the hit area - it had
      // when the edit started.
      object.update();
    }
  }

  /// Whether the string differs from where it started.
  bool get isDirty => object.textContent != originalText;

  /// The caret's distance along the baseline, in the object's own units.
  double get caretX =>
      VectorTextMetrics.caretX(object, _value.selection.extentOffset);

  /// The baseline distance of one end of the selection.
  double selectionX(int offset) => VectorTextMetrics.caretX(object, offset);

  /// Puts the caret at the cluster nearest [x], measured along the baseline.
  void placeCaretAtX(double x, {bool extend = false}) {
    final int offset = VectorTextMetrics.offsetAtX(object, x);
    _moveTo(offset, extend: extend);
  }

  /// Selects the word under [x]. What a double click inside an open edit does.
  void selectWordAtX(double x) {
    final int offset = VectorTextMetrics.offsetAtX(object, x);
    final TextRange word = TextMotion.wordAt(_value.text, offset);
    value = _value.copyWith(
      selection: TextSelection(baseOffset: word.start, extentOffset: word.end),
    );
  }

  void selectAll() {
    value = _value.copyWith(
      selection: TextSelection(baseOffset: 0, extentOffset: _value.text.length),
    );
  }

  /// Inserts [text] at the caret, replacing the selection.
  ///
  /// Returns whether anything changed, so a caller can skip a rebuild for a
  /// keystroke that produced nothing.
  bool insert(String text) {
    if (text.isEmpty) return false;
    final TextRange range = _value.selection.range;
    final String next = _value.text.replaceRange(range.start, range.end, text);
    value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(
        TextMotion.snapUp(next, range.start + text.length),
      ),
    );
    return true;
  }

  /// Interprets one key transition, returning whether it was consumed.
  ///
  /// Escape and Enter are deliberately *not* handled: they end the edit, and
  /// that is the canvas' decision - it owns whether the result is committed or
  /// abandoned, and it is the thing that has to leave edit mode.
  bool handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final bool shift = event.modifiers.contains(KeyModifier.shift);
    final bool control = event.modifiers.contains(KeyModifier.control);
    final String text = _value.text;
    final TextSelection selection = _value.selection;

    switch (event.logicalKey) {
      case logicalKeyArrowLeft:
        final int from = shift || selection.isCollapsed
            ? selection.extentOffset
            : selection.start;
        _moveTo(
          control
              ? TextMotion.previousWord(text, from)
              : TextMotion.previousCluster(text, from),
          extend: shift,
        );
        return true;
      case logicalKeyArrowRight:
        final int from = shift || selection.isCollapsed
            ? selection.extentOffset
            : selection.end;
        _moveTo(
          control
              ? TextMotion.nextWord(text, from)
              : TextMotion.nextCluster(text, from),
          extend: shift,
        );
        return true;
      case logicalKeyHome:
        _moveTo(0, extend: shift);
        return true;
      case logicalKeyEnd:
        _moveTo(text.length, extend: shift);
        return true;
      case logicalKeyBackspace:
        return _delete(forward: false, byWord: control);
      case logicalKeyDelete:
        return _delete(forward: true, byWord: control);
      case 0x41: // 'A'
        if (!control) return false;
        selectAll();
        return true;
      default:
        return false;
    }
  }

  /// Puts the text back exactly as it was found.
  void cancel() {
    if (object.textContent == originalText) return;
    object
      ..textContent = originalText
      ..update();
    _value = TextEditingValue(
      text: originalText,
      selection: TextSelection.collapsed(originalText.length),
    );
  }

  void _moveTo(int offset, {required bool extend}) {
    final int clamped =
        TextMotion.snapDown(_value.text, offset.clamp(0, _value.text.length));
    value = _value.copyWith(
      selection: extend
          ? _value.selection.copyWith(extentOffset: clamped)
          : TextSelection.collapsed(clamped),
    );
  }

  bool _delete({required bool forward, required bool byWord}) {
    final TextSelection selection = _value.selection;
    final String text = _value.text;
    int start = selection.start;
    int end = selection.end;
    if (selection.isCollapsed) {
      if (forward) {
        if (end >= text.length) return false;
        end = byWord
            ? TextMotion.nextWord(text, end)
            : TextMotion.nextCluster(text, end);
      } else {
        if (start <= 0) return false;
        start = byWord
            ? TextMotion.previousWord(text, start)
            : TextMotion.previousCluster(text, start);
      }
    }
    if (start == end) return false;
    final String next = text.replaceRange(start, end, '');
    value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(TextMotion.snapDown(next, start)),
    );
    return true;
  }
}
