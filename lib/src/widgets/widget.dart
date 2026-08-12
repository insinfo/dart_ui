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
///
/// Section 24.8 of the roadmap requires the context to be the *only* route to
/// ambient values - theme, resources, focus scope, shortcuts, media query -
/// precisely so that none of them becomes a global service locator. Everything
/// ambient therefore arrives through [dependOnInheritedWidgetOfExactType],
/// which both reads the value and records the dependency that will rebuild
/// this location when the value changes.
abstract interface class BuildContext {
  Widget get widget;

  bool get mounted;

  /// The nearest enclosing [T], registering this location as a dependent.
  ///
  /// A dependent is rebuilt whenever that ancestor's
  /// [InheritedWidget.updateShouldNotify] returns true. Returns null when no
  /// such ancestor exists, which callers must treat as "the feature is not
  /// installed" rather than as an error.
  T? dependOnInheritedWidgetOfExactType<T extends InheritedWidget>();

  /// Reads the nearest enclosing [T] *without* creating a dependency.
  ///
  /// Correct only for values that cannot change for the lifetime of this
  /// element; anything else silently goes stale.
  T? getInheritedWidgetOfExactType<T extends InheritedWidget>();

  /// The nearest ancestor widget whose runtime type is exactly [T].
  ///
  /// Walks the element tree, so it is O(depth) and creates no dependency. Use
  /// it for one-shot structural questions, never per frame.
  T? findAncestorWidgetOfExactType<T extends Widget>();

  /// Walks ancestors from the parent upward until [visitor] returns false.
  void visitAncestorElements(bool Function(Element element) visitor);
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

/// A widget that publishes a value to its whole subtree.
///
/// The subtree does not search for it: every element mounted below one of these
/// carries a map from widget type to the publishing element, so a lookup is a
/// hash probe rather than a walk to the root. That is the property which makes
/// theme and resource lookup affordable inside `build`.
abstract class InheritedWidget extends Widget {
  const InheritedWidget({super.key, required this.child});

  final Widget child;

  @override
  InheritedElement createElement() => InheritedElement(this);

  /// Whether dependents must rebuild because this value differs from
  /// [oldWidget]'s.
  ///
  /// Returning true unconditionally is correct but rebuilds the subtree on
  /// every ancestor rebuild; returning false when the payload is unchanged is
  /// what keeps a theme swap from costing a full-tree rebuild.
  bool updateShouldNotify(covariant InheritedWidget oldWidget);
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
