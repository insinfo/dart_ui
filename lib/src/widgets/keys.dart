/// The rest of Flutter's key family - `UniqueKey`, `ObjectKey`,
/// `GlobalObjectKey`, `LabeledGlobalKey`, `PageStorageKey` - plus
/// `KeyedSubtree` and a small `PageStorage`.
///
/// [Key], [LocalKey], [ValueKey] and [GlobalKey] live in `widget.dart`,
/// beside the reconciler that reads them.
library;

import 'element.dart';
import 'widget.dart';

/// A key equal only to itself: every `UniqueKey()` is a new identity.
///
/// Giving a widget a fresh `UniqueKey` each build forces a new element (and
/// new state) each build, which is the usual reason to use one.
class UniqueKey extends LocalKey {
  // Not const, on purpose: a const instance would be canonicalised and every
  // `const UniqueKey()` would be the same key.
  UniqueKey();

  @override
  String toString() => '[#${identityHashCode(this).toRadixString(16)}]';
}

/// A key whose identity is the identity of [value]: two `ObjectKey`s are
/// equal when they wrap the same object (`identical`), not merely equal ones.
class ObjectKey extends LocalKey {
  const ObjectKey(this.value);

  /// The object whose identity this key carries.
  final Object? value;

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is ObjectKey &&
      identical(other.value, value);

  @override
  int get hashCode => Object.hash(runtimeType, identityHashCode(value));

  @override
  String toString() => '[${_typeName(this)} '
      '${value.runtimeType}#${identityHashCode(value).toRadixString(16)}]';
}

/// A [GlobalKey] whose identity is the identity of [value].
///
/// Two `GlobalObjectKey`s of the same type wrapping the same object are the
/// same global key, so a const one can be written at two call sites and still
/// name one element.
class GlobalObjectKey<T extends State<StatefulWidget>> extends GlobalKey<T> {
  const GlobalObjectKey(this.value) : super.constructor();

  /// The object whose identity this key carries.
  final Object value;

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is GlobalObjectKey<T> &&
      identical(other.value, value);

  @override
  int get hashCode => identityHashCode(value);

  @override
  String toString() => '[${_typeName(this)} ${value.runtimeType}#'
      '${identityHashCode(value).toRadixString(16)}]';
}

/// A [GlobalKey] with a label for diagnostics - what Flutter's
/// `GlobalKey(debugLabel: ...)` factory returns.
///
/// Here `GlobalKey(debugLabel: ...)` is itself the labelled key, so this class
/// only exists for code that names it.
class LabeledGlobalKey<T extends State<StatefulWidget>> extends GlobalKey<T> {
  LabeledGlobalKey(String? debugLabel) : super(debugLabel: debugLabel);
}

/// A [ValueKey] that also names where a widget's state is saved in a
/// [PageStorage] - typically the scroll offset of one tab's list.
class PageStorageKey<T> extends ValueKey<T> {
  const PageStorageKey(super.value);
}

/// Attaches a [key] to a [child] without any other effect.
///
/// The way to key something that is not a widget you construct yourself, such
/// as the result of a builder.
class KeyedSubtree extends StatelessWidget {
  const KeyedSubtree({super.key, required this.child});

  /// Wraps [child] in a `KeyedSubtree` keyed by [child]'s own key, or by
  /// [childIndex] when it has none.
  factory KeyedSubtree.wrap(Widget child, int childIndex) {
    final Key key = child.key ?? ValueKey<int>(childIndex);
    return KeyedSubtree(key: key, child: child);
  }

  /// The widget below this one.
  final Widget child;

  /// Wraps each item of [items] with [KeyedSubtree.wrap], indexes starting at
  /// [baseIndex]. Returns [items] itself when every item already has a key.
  static List<Widget> ensureUniqueKeysForList(
    List<Widget> items, {
    int baseIndex = 0,
  }) {
    if (items.isEmpty) return items;
    if (items.every((Widget item) => item.key != null)) return items;
    return <Widget>[
      for (int i = 0; i < items.length; i++)
        KeyedSubtree.wrap(items[i], baseIndex + i),
    ];
  }

  @override
  Widget build(BuildContext context) => child;
}

/// Where widgets save state that should outlive their elements, such as a
/// list's scroll offset when its tab is switched away.
///
/// Entries are addressed by the chain of [PageStorageKey]s above the widget
/// (or an explicit identifier), as in Flutter.
class PageStorageBucket {
  final Map<Object, Object?> _storage = <Object, Object?>{};

  /// Saves [data] for [context] (or under [identifier] when given).
  void writeState(BuildContext context, Object? data, {Object? identifier}) {
    _storage[identifier ?? _identifierFor(context)] = data;
  }

  /// The data saved for [context] (or under [identifier]), or null.
  Object? readState(BuildContext context, {Object? identifier}) =>
      _storage[identifier ?? _identifierFor(context)];

  static Object _identifierFor(BuildContext context) {
    final List<PageStorageKey<Object?>> keys = <PageStorageKey<Object?>>[];
    final Key? own = context.widget.key;
    if (own is PageStorageKey<Object?>) keys.add(own);
    context.visitAncestorElements((Element element) {
      final Key? key = element.widget.key;
      if (key is PageStorageKey<Object?>) keys.add(key);
      return true;
    });
    return _StorageEntryIdentifier(keys);
  }
}

/// The identifier a [PageStorageBucket] files an entry under: the
/// [PageStorageKey]s from the widget up to the root.
final class _StorageEntryIdentifier {
  _StorageEntryIdentifier(this.keys);

  final List<PageStorageKey<Object?>> keys;

  @override
  bool operator ==(Object other) {
    if (other is! _StorageEntryIdentifier) return false;
    if (other.keys.length != keys.length) return false;
    for (int i = 0; i < keys.length; i++) {
      if (other.keys[i] != keys[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(keys);
}

/// Provides a [PageStorageBucket] to the subtree.
///
/// Only the storage: dart_ui's scroll views do not yet save their offset into
/// it on their own, which Flutter's `Scrollable` does.
class PageStorage extends StatelessWidget {
  const PageStorage({super.key, required this.bucket, required this.child});

  /// The bucket the subtree saves into.
  final PageStorageBucket bucket;

  /// The widget below this one.
  final Widget child;

  /// The nearest bucket, or null.
  static PageStorageBucket? maybeOf(BuildContext context) =>
      context.findAncestorWidgetOfExactType<PageStorage>()?.bucket;

  /// The nearest bucket; throws [StateError] when there is none.
  static PageStorageBucket of(BuildContext context) {
    final PageStorageBucket? bucket = maybeOf(context);
    if (bucket == null) {
      throw StateError(
        'no PageStorage above ${context.widget.runtimeType}; wrap the '
        'subtree in PageStorage(bucket: PageStorageBucket(), child: ...)',
      );
    }
    return bucket;
  }

  @override
  Widget build(BuildContext context) => child;
}

String _typeName(Object object) => object.runtimeType.toString();
