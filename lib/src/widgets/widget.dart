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

/// A key that identifies one element across the *whole* tree, not just among
/// its siblings.
///
/// A [ValueKey] answers a local question - "is this the same list row as last
/// frame?" - and is compared only against the widgets at the same position
/// under the same parent. A [GlobalKey] answers two questions that nothing else
/// in the framework can:
///
///   1. **Reach.** A dialog needs the [State] of a form that is nowhere near it
///      in the tree. Without this the only route is an ambient service, which
///      is the global locator section 24.8 exists to forbid; with it, the
///      dialog holds a key and asks the key.
///   2. **Move.** A subtree that changes parents - a panel dragged into another
///      dock, a row promoted out of a group - is, positionally, a deletion and
///      an unrelated insertion. Reconciliation would dispose every [State] in
///      it and build a new one. A global key makes the element itself the thing
///      being matched, so the subtree is *reparented* and its state, its
///      scroll offsets and its render objects survive the move.
///
/// Identity, not value, is what a global key means, so equality is identity:
/// two `GlobalKey()` instances are always different keys, and the same instance
/// is always the same key. That is also why this cannot be `const` - a const
/// instance would be canonicalised and two unrelated widgets would silently
/// share one identity.
///
/// Exactly one live element may carry a given key at a time; a second is a
/// [DuplicateGlobalKeyError] rather than a tree in which the registry answers
/// with whichever widget was built last.
final class GlobalKey<T extends State<StatefulWidget>> extends Key {
  GlobalKey({this.debugLabel}) : super._();

  /// A name for diagnostics. Never used for identity.
  final String? debugLabel;

  /// The one element currently carrying each live key.
  ///
  /// A map rather than a field on the key so that a key held by application
  /// code cannot keep a defunct element alive: [Element.unmount] removes the
  /// entry, and the key that outlives its tree simply answers null.
  static final Map<GlobalKey<State<StatefulWidget>>, Element> _registry =
      <GlobalKey<State<StatefulWidget>>, Element>{};

  /// The element this key currently names, or null when nothing carries it.
  ///
  /// May be an element that has been detached from the tree during the current
  /// build scope and not yet reclaimed; [currentContext] filters those out.
  Element? get currentElement => _registry[this];

  /// The build context of the element this key names, when it is mounted.
  BuildContext? get currentContext {
    final Element? element = _registry[this];
    return element != null && element.mounted ? element : null;
  }

  /// The widget at this key's location, or null.
  Widget? get currentWidget => currentContext?.widget;

  /// The [State] at this key's location, when it is a [StatefulWidget] whose
  /// state is a [T].
  ///
  /// This is the whole point of the "reach" half of a global key: a dialog with
  /// a `GlobalKey<FormState>` calls `key.currentState?.validate()` and never
  /// learns where the form is.
  T? get currentState {
    final Element? element = _registry[this];
    if (element is! StatefulElement || !element.mounted) return null;
    final State<StatefulWidget> state = element.state;
    return state is T ? state : null;
  }

  /// Records [element] as the carrier of this key. Called by [Element.mount]
  /// and by the reconciler when a subtree is reparented.
  void internalRegister(Element element) => _registry[this] = element;

  /// Drops [element]'s claim, if it still holds one.
  ///
  /// The identity test matters: a key whose element was replaced within one
  /// build scope must not have the *new* element's registration removed when
  /// the old one is finally unmounted at the end of that scope.
  void internalUnregister(Element element) {
    if (identical(_registry[this], element)) _registry.remove(this);
  }

  @override
  String toString() {
    final String label = debugLabel == null ? '' : ' $debugLabel';
    return 'GlobalKey#${identityHashCode(this).toRadixString(16)}$label';
  }
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
