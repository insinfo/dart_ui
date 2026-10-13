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

import 'change_notifier.dart';

/// A [Listenable] that also holds a current [value] - Flutter's
/// `ValueListenable`, what [ValueListenableBuilder] and anything else that
/// only reads takes, so a caller can hand over a [ValueNotifier] without
/// handing over the right to set it.
abstract interface class ValueListenable<T> implements Listenable {
  /// The current value.
  T get value;
}

/// A [ChangeNotifier] holding one value, notifying when it is replaced by a
/// value that is not `==` to it - Flutter's `ValueNotifier`, so it goes
/// wherever a [Listenable] does: `CustomPainter(repaint:)`,
/// `AnimatedBuilder(animation:)`, `ListenableBuilder`, `Listenable.merge`.
///
/// Synchronous on purpose: a control that learns about a change one microtask
/// later paints one frame with the old value, and that frame is visible.
///
/// ## Listeners of either shape
///
/// [addListener] takes Flutter's `void Function()` and also this framework's
/// older `void Function(T value)`, which is handed the new value - the same
/// accept-both rule `ScrollPosition` and `FocusNode` follow, so code written
/// against either keeps compiling. The parameter is typed [Function] for that
/// reason; anything that is neither shape is an [ArgumentError]. Through a
/// [ValueListenable] or [Listenable] type only the zero-argument shape is
/// visible, as in Flutter.
class ValueNotifier<T> extends ChangeNotifier implements ValueListenable<T> {
  ValueNotifier(this._value);

  T _value;

  /// Listeners that take the value, each with the zero-argument wrapper
  /// actually registered, so [removeListener] can find the wrapper again.
  final List<(Function, void Function())> _valueListeners =
      <(Function, void Function())>[];

  @override
  T get value => _value;

  set value(T newValue) {
    if (newValue == _value) return;
    _value = newValue;
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

  /// Calls [listener] after every change: `() {...}`, as Flutter does, or
  /// `(T value) {...}`, which is handed the new value. See the class comment.
  @override
  void addListener(Function listener) {
    if (listener is void Function()) {
      super.addListener(listener);
      return;
    }
    if (listener is void Function(T)) {
      void wrapper() => listener(_value);
      super.addListener(wrapper);
      _valueListeners.add((listener, wrapper));
      return;
    }
    throw ArgumentError.value(
      listener,
      'listener',
      'must be a void Function() or a void Function($T)',
    );
  }

  /// Stops calling [listener], of either shape. Removing one that was never
  /// added does nothing.
  @override
  void removeListener(Function listener) {
    if (listener is void Function()) {
      super.removeListener(listener);
      return;
    }
    for (var i = 0; i < _valueListeners.length; i++) {
      if (_valueListeners[i].$1 == listener) {
        super.removeListener(_valueListeners.removeAt(i).$2);
        return;
      }
    }
  }

  @override
  String toString() => '$runtimeType($value)';
}
