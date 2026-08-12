/// The property system that templated controls and styles are built on.
///
/// A templated control cannot store its appearance in plain fields, because a
/// single visual value has up to eight sources competing for it: an animation,
/// a local assignment, a binding, the template, a pseudo-class trigger, a
/// style, an inherited value from an ancestor, and finally the declared
/// default. Section 24.6 of the roadmap fixes that order, and this file is the
/// mechanism that enforces it.
///
/// The rule that makes it usable: **a source only ever writes its own slot.**
/// A style never has to know whether an animation is running, and clearing an
/// animation never has to remember what was underneath - the value underneath
/// was never overwritten in the first place.
library;

/// What must be redone when a property changes.
///
/// The point of naming this per property is that the property itself decides,
/// so a colour change does not conservatively invalidate layout. Values are
/// ordered from cheapest to most expensive, and [PropertyInvalidation.merge]
/// keeps the strongest of a batch.
enum PropertyInvalidation {
  /// Nothing to redo; the value is not visual (a command, a tag, a callback).
  none,

  /// Redraw only. Colour, opacity, anything that cannot move a box.
  paint,

  /// Re-measure and re-arrange, which implies a repaint.
  layout,

  /// The visual tree itself changes: a template swap, a control's content.
  visualTree,
}

/// The competing sources for one property value, strongest first.
///
/// The declaration order *is* the precedence order - [PropertyStore.read]
/// walks this enum's values and returns the first slot that is set - so
/// reordering these constants changes framework semantics and must not be done
/// casually.
enum PropertyPrecedence {
  /// A running animation. Wins over everything so that a transition is not
  /// fought by the style that triggered it.
  animation,

  /// An explicit assignment in user code: `button.width = 120`.
  local,

  /// A value pushed by a data binding.
  binding,

  /// A value set by the control template that produced this element.
  template,

  /// A pseudo-class trigger: `:hover`, `:pressed`, `:disabled`.
  trigger,

  /// A matched style rule.
  style,

  /// A value inherited from an ancestor, for properties that inherit.
  inherited,

  /// The property's declared default. Always present, so a read never fails.
  defaultValue,
}

/// The declaration of one property: its identity, its default, and the rules
/// that every write to it must satisfy.
///
/// Identity is the object, not the name. Two properties called `width` on
/// unrelated controls are different properties, and comparing by name would
/// silently merge them; the name exists for diagnostics only.
final class UiProperty<T> {
  const UiProperty({
    required this.name,
    required this.defaultValue,
    this.inherits = false,
    this.coerce,
    this.validate,
    this.invalidation = PropertyInvalidation.paint,
  });

  /// Human-readable name, used in diagnostics and style rules.
  final String name;

  /// The value a read returns when no source has set one.
  final T defaultValue;

  /// Whether a descendant with no value of its own picks this up from an
  /// ancestor. Font and foreground inherit; width does not.
  final bool inherits;

  /// Clamps or normalizes an incoming value. Runs *after* [validate], so a
  /// coercion never has to defend itself against nonsense.
  final T Function(Object owner, T value)? coerce;

  /// Rejects values that are not merely out of range but meaningless - a NaN
  /// width, a negative item count. A rejected write throws rather than being
  /// dropped, because a silently ignored assignment is the harder bug.
  final bool Function(T value)? validate;

  /// What a change to this property invalidates.
  final PropertyInvalidation invalidation;

  @override
  String toString() => 'UiProperty<$T>($name)';
}

/// One property's value at one precedence level.
final class _Slot {
  _Slot(this.value);
  Object? value;
}

/// Holds every property value for one owner, resolved by precedence.
///
/// Storage is lazy on both axes: an owner that never sets a property allocates
/// nothing for it, and a property that is only ever set locally allocates one
/// slot rather than eight. A control with forty declared properties and two
/// assignments therefore costs two slots.
final class PropertyStore {
  PropertyStore(this.owner);

  /// The object these values belong to, handed to [UiProperty.coerce] so that
  /// a coercion can depend on sibling values (a max that clamps a value).
  final Object owner;

  final Map<UiProperty<Object?>, List<_Slot?>> _values =
      <UiProperty<Object?>, List<_Slot?>>{};

  final List<
          void Function(
              UiProperty<Object?> property, PropertyInvalidation invalidation)>
      _listeners = <void Function(UiProperty<Object?>, PropertyInvalidation)>[];

  /// Values inherited from an ancestor store, consulted at the `inherited`
  /// precedence level only for properties declared with `inherits: true`.
  PropertyStore? inheritedParent;

  /// Called after every effective change, with what that change invalidated.
  void addListener(
    void Function(
            UiProperty<Object?> property, PropertyInvalidation invalidation)
        listener,
  ) =>
      _listeners.add(listener);

  void removeListener(
    void Function(
            UiProperty<Object?> property, PropertyInvalidation invalidation)
        listener,
  ) =>
      _listeners.remove(listener);

  /// The effective value: the highest-precedence slot that is set, or the
  /// declared default.
  ///
  /// Never throws and never returns null for a non-nullable [T] - a property
  /// always has a value, which is what lets a control read one during layout
  /// without a null check on every access.
  T read<T>(UiProperty<T> property) {
    final List<_Slot?>? slots = _values[property];
    if (slots != null) {
      for (int level = 0; level < slots.length; level++) {
        final _Slot? slot = slots[level];
        if (slot != null) return slot.value as T;
      }
    }
    // Only reached when no local slot is set at all: an explicitly pushed
    // `inherited` value above wins over walking the ancestor chain here.
    if (property.inherits) {
      final T? inherited = inheritedParent?._readInherited(property);
      if (inherited != null) return inherited;
    }
    return property.defaultValue;
  }

  T? _readInherited<T>(UiProperty<T> property) {
    final List<_Slot?>? slots = _values[property];
    if (slots != null) {
      for (int level = 0; level < slots.length; level++) {
        final _Slot? slot = slots[level];
        if (slot != null) return slot.value as T;
      }
    }
    return inheritedParent?._readInherited(property);
  }

  /// Whether [precedence] currently holds a value for [property].
  bool isSetAt<T>(UiProperty<T> property, PropertyPrecedence precedence) =>
      _values[property]?[precedence.index] != null;

  /// The precedence level that currently wins, or null when the default does.
  PropertyPrecedence? effectivePrecedence<T>(UiProperty<T> property) {
    final List<_Slot?>? slots = _values[property];
    if (slots == null) return null;
    for (int level = 0; level < slots.length; level++) {
      if (slots[level] != null) return PropertyPrecedence.values[level];
    }
    return null;
  }

  /// Writes [value] at [precedence], leaving every other level untouched.
  ///
  /// Returns true when the *effective* value changed. A style write underneath
  /// a running animation returns false and notifies nobody, which is the whole
  /// reason the levels are stored separately.
  bool write<T>(
    UiProperty<T> property,
    T value, {
    PropertyPrecedence precedence = PropertyPrecedence.local,
  }) {
    final bool? valid = property.validate?.call(value);
    if (valid == false) {
      throw ArgumentError.value(
        value,
        property.name,
        'rejected by ${property.name}.validate',
      );
    }
    final T coerced = property.coerce?.call(owner, value) ?? value;
    final Object? before = read<T>(property);
    final List<_Slot?> slots = _slotsFor(property);
    final _Slot? existing = slots[precedence.index];
    if (existing == null) {
      slots[precedence.index] = _Slot(coerced);
    } else {
      existing.value = coerced;
    }
    final Object? after = read<T>(property);
    if (before == after) return false;
    _notify(property, property.invalidation);
    return true;
  }

  /// Removes the value at [precedence], revealing whatever is beneath it.
  ///
  /// This is how an animation ends without having to know - or restore - the
  /// style value it was covering.
  bool clear<T>(
    UiProperty<T> property, {
    PropertyPrecedence precedence = PropertyPrecedence.local,
  }) {
    final List<_Slot?>? slots = _values[property];
    if (slots == null || slots[precedence.index] == null) return false;
    final Object? before = read<T>(property);
    slots[precedence.index] = null;
    if (slots.every((_Slot? slot) => slot == null)) _values.remove(property);
    final Object? after = read<T>(property);
    if (before == after) return false;
    _notify(property, property.invalidation);
    return true;
  }

  /// Drops every value at [precedence] across all properties.
  ///
  /// Used when a whole layer is replaced at once: re-matching styles after a
  /// pseudo-class change clears the `trigger` level rather than diffing it.
  PropertyInvalidation clearLevel(PropertyPrecedence precedence) {
    PropertyInvalidation strongest = PropertyInvalidation.none;
    for (final UiProperty<Object?> property in _values.keys.toList()) {
      final Object? before = _readDynamic(property);
      final List<_Slot?> slots = _values[property]!;
      if (slots[precedence.index] == null) continue;
      slots[precedence.index] = null;
      if (slots.every((_Slot? slot) => slot == null)) _values.remove(property);
      if (_readDynamic(property) == before) continue;
      strongest = mergeInvalidation(strongest, property.invalidation);
      _notify(property, property.invalidation);
    }
    return strongest;
  }

  Object? _readDynamic(UiProperty<Object?> property) => read<Object?>(property);

  List<_Slot?> _slotsFor(UiProperty<Object?> property) => _values.putIfAbsent(
        property,
        () => List<_Slot?>.filled(PropertyPrecedence.values.length, null),
      );

  void _notify(
      UiProperty<Object?> property, PropertyInvalidation invalidation) {
    if (_listeners.isEmpty) return;
    for (final void Function(UiProperty<Object?>, PropertyInvalidation) listener
        in List<void Function(UiProperty<Object?>, PropertyInvalidation)>.of(
            _listeners)) {
      listener(property, invalidation);
    }
  }
}

/// The stronger of two invalidations, per the order declared in
/// [PropertyInvalidation].
PropertyInvalidation mergeInvalidation(
  PropertyInvalidation a,
  PropertyInvalidation b,
) =>
    a.index >= b.index ? a : b;
