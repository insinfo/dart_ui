library;

import 'element.dart';

/// A key controls whether an existing element may be reused for a new widget.
abstract class Key {
  const factory Key(String value) = ValueKey<String>;
  const Key._();
}

final class ValueKey<T> extends Key {
  const ValueKey(this.value) : super._();

  final T value;

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is ValueKey<T> &&
      other.value == value;

  @override
  int get hashCode => Object.hash(runtimeType, value);

  @override
  String toString() => 'ValueKey<$T>($value)';
}

/// A handle to a mounted location in the widget tree.
abstract interface class BuildContext {
  Widget get widget;

  bool get mounted;
}

/// Immutable configuration for one location in the element tree.
abstract class Widget {
  const Widget({this.key});

  final Key? key;

  Element createElement();

  /// The only legal reconciliation rule for an existing element.
  static bool canUpdate(Widget oldWidget, Widget newWidget) =>
      oldWidget.runtimeType == newWidget.runtimeType &&
      oldWidget.key == newWidget.key;
}

abstract class StatelessWidget extends Widget {
  const StatelessWidget({super.key});

  @override
  StatelessElement createElement() => StatelessElement(this);

  Widget build(BuildContext context);
}

abstract class StatefulWidget extends Widget {
  const StatefulWidget({super.key});

  @override
  StatefulElement createElement() => StatefulElement(this);

  State<StatefulWidget> createState();
}

/// Mutable state owned by exactly one [StatefulElement].
abstract class State<T extends StatefulWidget> {
  T? _widget;
  StatefulElement? _element;
  bool _canSetState = false;

  T get widget {
    final T? value = _widget;
    if (value == null) {
      throw StateError('$runtimeType.widget was read after dispose().');
    }
    return value;
  }

  BuildContext get context {
    final StatefulElement? value = _element;
    if (value == null || !value.mounted) {
      throw StateError('$runtimeType.context was read while not mounted.');
    }
    return value;
  }

  bool get mounted => _element?.mounted ?? false;

  set internalWidget(T? value) => _widget = value;

  set internalElement(StatefulElement? value) => _element = value;

  set internalCanSetState(bool value) => _canSetState = value;

  void initState() {}

  void didUpdateWidget(covariant T oldWidget) {}

  void dispose() {}

  /// Mutates state and schedules one rebuild in the owning [BuildOwner].
  void setState(void Function() mutation) {
    final StatefulElement? element = _element;
    if (!_canSetState || element == null || !element.mounted) {
      throw StateError('$runtimeType.setState() called after dispose().');
    }
    mutation();
    element.markNeedsBuild();
  }

  Widget build(BuildContext context);
}
