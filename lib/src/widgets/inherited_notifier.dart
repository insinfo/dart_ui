/// `InheritedNotifier`: an inherited widget whose dependents rebuild when a
/// [Listenable] notifies, not only when the widget is replaced.
library;

import '../foundation/change_notifier.dart';
import 'element.dart';
import 'widget.dart';

/// Publishes [notifier] to the subtree and rebuilds every dependent when it
/// notifies - Flutter's `InheritedNotifier`.
///
/// The usual shape is a subclass with a static `of`:
///
/// ```dart
/// class Counter extends InheritedNotifier<ValueNotifier<int>> {
///   const Counter({super.key, required super.notifier, required super.child});
///
///   static int of(BuildContext context) => context
///       .dependOnInheritedWidgetOfExactType<Counter>()!.notifier!.value;
/// }
/// ```
///
/// A notification marks this element for rebuild and its dependents are
/// rebuilt in the same build scope, so many notifications between two frames
/// cost one rebuild of each dependent.
abstract class InheritedNotifier<T extends Listenable> extends InheritedWidget {
  const InheritedNotifier({super.key, this.notifier, required super.child});

  /// The listenable whose notifications rebuild the dependents, or null for
  /// none.
  final T? notifier;

  /// Whether replacing this widget notifies the dependents: by default only
  /// when the [notifier] itself was replaced.
  @override
  bool updateShouldNotify(InheritedNotifier<T> oldWidget) =>
      oldWidget.notifier != notifier;

  @override
  InheritedElement createElement() => _InheritedNotifierElement<T>(this);
}

final class _InheritedNotifierElement<T extends Listenable>
    extends InheritedElement {
  _InheritedNotifierElement(InheritedNotifier<T> super.widget);

  bool _notified = false;

  @override
  InheritedNotifier<T> get widget => super.widget as InheritedNotifier<T>;

  @override
  void mount(Element? parent, BuildOwner owner) {
    super.mount(parent, owner);
    widget.notifier?.addListener(_handleUpdate);
  }

  @override
  void update(covariant InheritedNotifier<T> newWidget) {
    final T? oldNotifier = widget.notifier;
    final T? newNotifier = newWidget.notifier;
    if (!identical(oldNotifier, newNotifier)) {
      oldNotifier?.removeListener(_handleUpdate);
      newNotifier?.addListener(_handleUpdate);
    }
    super.update(newWidget);
  }

  @override
  Widget build() {
    if (_notified) {
      _notified = false;
      notifyDependents();
    }
    return super.build();
  }

  void _handleUpdate() {
    if (!mounted) return;
    _notified = true;
    markNeedsBuild();
  }

  @override
  void unmount() {
    widget.notifier?.removeListener(_handleUpdate);
    super.unmount();
  }
}
