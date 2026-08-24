/// Routes physical key events to the focused render-tree target.
library;

import '../platform/input_events.dart';

/// A render-tree object that can consume keyboard events.
///
/// [handleKeyEvent] returns whether the event was consumed. That answer is not
/// bookkeeping: an unconsumed key is what lets Tab reach the traversal policy
/// and Ctrl+C reach the application's shortcut map, while a text field that
/// consumed its own Tab keeps it. A target that always claimed every key would
/// make keyboard navigation impossible from inside any control.
abstract interface class KeyboardEventTarget {
  bool handleKeyEvent(KeyEvent event);
}

/// A render-tree object that can consume *text*, as opposed to keys.
///
/// Separate from [KeyboardEventTarget] rather than another method on it, and
/// deliberately so: almost nothing accepts text - a button, a slider and a
/// menu never do - while nearly every control accepts keys. A control that
/// does not implement this simply never sees a [TextInputEvent], and the two
/// interfaces travel the same focus route, so the target that gets the keys is
/// the target that gets the text they produced.
abstract interface class TextInputTarget {
  /// Inserts [event] and reports whether it was consumed.
  bool handleTextInput(TextInputEvent event);
}

/// Owns keyboard focus for one window/render tree.
///
/// Focus is deliberately a small service instead of a platform concern. The
/// backend normalizes native key messages into [KeyEvent] and this router
/// decides which Dart object receives them.
final class KeyboardRouter {
  KeyboardEventTarget? _focusedTarget;

  KeyboardEventTarget? get focusedTarget => _focusedTarget;

  /// Gives focus to [target], replacing the previous focused target.
  void requestFocus(KeyboardEventTarget target) {
    if (identical(target, _focusedTarget)) return;
    _focusedTarget = target;
  }

  /// Removes focus only when [target] is currently focused.
  ///
  /// The identity check prevents an unmounting widget from clearing focus that
  /// was already assigned to its replacement.
  void clearFocus(KeyboardEventTarget target) {
    if (identical(target, _focusedTarget)) _focusedTarget = null;
  }

  void clearFocusFromTree() => _focusedTarget = null;

  Set<KeyModifier> _heldModifiers = const <KeyModifier>{};

  /// Which modifiers the last key transition reported as held.
  ///
  /// This exists because **[PointerEvent] carries no modifier set**, and a
  /// desktop application needs one on nearly every press: Shift+click extends
  /// a selection, Ctrl+click toggles a row, Ctrl+wheel zooms. `text_field.dart`
  /// and `data_grid.dart` each grew a private copy of this field and each
  /// documented the same limitation - "the real fix is a modifier set on
  /// PointerEvent" - and each copy is only correct while *that control* has
  /// focus, so Shift+clicking a canvas the user had not typed into yet read as
  /// no Shift at all.
  ///
  /// Keeping it on the router fixes that half: every key transition in the
  /// window passes through [route], focused or not, so the answer is the
  /// window's and not one control's. The remaining gap is honest and small: a
  /// modifier already held when the window gained focus has produced no
  /// transition here, so it reads as released until the user lets go of it or
  /// presses it again. Closing *that* needs the platform's modifier state on
  /// the pointer event itself, which is a backend change.
  Set<KeyModifier> get heldModifiers => _heldModifiers;

  /// Sends [event] to the current focus target.
  ///
  /// Returns whether the target consumed it - false both when nothing is
  /// focused and when the focused target declined. Callers use that to keep
  /// looking: traversal, then application shortcuts, then the platform.
  bool route(KeyEvent event) {
    // Before the target is consulted, and whether or not there is one: the
    // modifier state belongs to the window, and a press with nothing focused
    // still tells us Shift went down.
    _heldModifiers = event.modifiers;
    final target = _focusedTarget;
    if (target == null) return false;
    return target.handleKeyEvent(event);
  }

  /// Sends translated text to the current focus target.
  ///
  /// The same route as [route], and that is the point: the control the user is
  /// typing into is the focused one, so text must not travel by a path of its
  /// own that could disagree about where focus is. A focused target that is
  /// not a [TextInputTarget] declines by construction - a button cannot
  /// swallow the text somebody meant for the field behind it - and the false
  /// it returns lets a caller keep looking.
  bool routeTextInput(TextInputEvent event) {
    final KeyboardEventTarget? target = _focusedTarget;
    if (target == null || target is! TextInputTarget) return false;
    return (target as TextInputTarget).handleTextInput(event);
  }
}
