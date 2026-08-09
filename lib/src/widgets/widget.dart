library;

import 'element.dart';

/// A key controls how one widget replaces another widget in the tree.
abstract class Key {
  const factory Key(String value) = ValueKey<String>;
  const Key._();
}

final class ValueKey<T> extends Key {
  const ValueKey(this.value) : super._();
  final T value;

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    return other is ValueKey<T> && other.value == value;
  }

  @override
  int get hashCode => Object.hash(runtimeType, value);
}

/// A handle to the location of a widget in the widget tree.
abstract interface class BuildContext {
  Widget get widget;
}

/// Describes the configuration for an [Element].
abstract class Widget {
  const Widget({this.key});

  final Key? key;

  Element createElement();

  static bool canUpdate(Widget oldWidget, Widget newWidget) {
    return oldWidget.runtimeType == newWidget.runtimeType &&
        oldWidget.key == newWidget.key;
  }
}

/// A widget that does not require mutable state.
abstract class StatelessWidget extends Widget {
  const StatelessWidget({super.key});

  @override
  StatelessElement createElement() => StatelessElement(this);

  Widget build(BuildContext context);
}

/// A widget that has mutable state.
abstract class StatefulWidget extends Widget {
  const StatefulWidget({super.key});

  @override
  StatefulElement createElement() => StatefulElement(this);

  State createState();
}

/// The logic and internal state for a [StatefulWidget].
abstract class State<T extends StatefulWidget> {
  T get widget => _widget!;
  T? _widget;
  set internalWidget(T? w) => _widget = w;

  BuildContext get context => _element!;
  StatefulElement? _element;
  set internalElement(StatefulElement? e) => _element = e;

  void initState() {}
  void didUpdateWidget(T oldWidget) {}
  void dispose() {}

  void setState(void Function() fn) {
    fn();
    _element?.markNeedsBuild();
  }

  Widget build(BuildContext context);
}
