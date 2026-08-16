/// Small collection helpers shared by framework layers.
library;

/// Nullable accessors that avoid repeating boundary checks at call sites.
extension ListNullableAccessors<T> on List<T> {
  /// The final element, or null when this list is empty.
  T? get lastOrNull => isEmpty ? null : this[length - 1];
}
