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

  /// Sends [event] to the current focus target.
  ///
  /// Returns whether the target consumed it - false both when nothing is
  /// focused and when the focused target declined. Callers use that to keep
  /// looking: traversal, then application shortcuts, then the platform.
  bool route(KeyEvent event) {
    final target = _focusedTarget;
    if (target == null) return false;
    return target.handleKeyEvent(event);
  }
}
