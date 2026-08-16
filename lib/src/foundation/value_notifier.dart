/// A mutable value with synchronous listeners.
///
/// Lives in `foundation` and not beside the controls that use it, because it
/// depends on nothing: no widget, no render object, no geometry. It was
/// written inside `widgets/controls.dart` and stayed there while that file
/// was the only consumer, which stopped being true - `Localizations` drives a
/// locale through one, and a scroll position, an animation and a form all
/// want the same shape.
///
/// This is also the seat the reactivity of section 24.5 belongs in: `Signal`,
/// `Computed` and `Effect` are the same idea with dependency tracking, and
/// putting the first one in the widget layer is how the other three would end
/// up there too.
library;

import 'package:meta/meta.dart';

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

  /// Replaces the value **without notifying**, for a subclass that has more to
  /// do before its listeners should see anything.
  ///
  /// This exists because moving this class out of `widgets/controls.dart`
  /// revealed that it was already needed. `TextEditingController` overrides
  /// `value` and, in a dozen edit operations, wrote the private field directly
  /// and then called [notifyListeners] itself - it has to normalise the
  /// selection and clear the composing range *between* the two, and one
  /// notification per edit is the contract a text field is written against.
  /// That worked only because the two classes shared a library, which is not a
  /// design so much as an accident of where the code was typed.
  ///
  /// So the hook is named rather than reached for: a subclass that writes here
  /// is stating that it will notify, and one that forgets is easier to find
  /// than a field write that was never supposed to be visible.
  @protected
  set silentValue(T next) => _value = next;

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
