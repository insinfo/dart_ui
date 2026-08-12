/// Styles, selectors, pseudo-classes and resources.
///
/// The goal in section 28.1 is that a reusable control must not hard-code its
/// appearance. That needs three things, and this file has exactly those:
///
///   * a **selector** narrow enough to be cheap and expressive enough to be
///     useful - type, class, key, ancestor/child, pseudo-class. Section 28.2 is
///     explicit that this is not CSS and must not grow into it;
///   * a **specificity** rule, so two matching rules have a defined winner
///     rather than a load-order-dependent one;
///   * a **resource lookup** that walks a hierarchy, caches, and detects
///     cycles instead of overflowing the stack on a self-referential alias.
///
/// Styles write into [PropertyStore] at the `style` and `trigger` precedence
/// levels, which is why a hover rule cannot clobber a local assignment.
library;

import 'properties.dart';

/// The states a selector can test, per section 28.3.
enum PseudoClass {
  hover,
  pressed,
  focused,
  focusVisible,
  disabled,
  checked,
  selected,
  expanded,
  invalid,
  dragging,
  windowInactive,
  dark,
  light,
  highContrast,
}

/// What a selector is matched against: one styleable object's identity and
/// current state.
///
/// Deliberately a value, not the control itself. Matching therefore cannot
/// call back into the control, which is what keeps a style pass free of
/// re-entrancy.
final class StyleTarget {
  StyleTarget({
    required this.type,
    this.classes = const <String>{},
    this.key,
    this.states = const <PseudoClass>{},
    this.parent,
  });

  /// The control's type name - `Button`, `CheckBox`.
  final String type;

  /// Style classes, the `class` selector.
  final Set<String> classes;

  /// An optional identity, the `#id` selector.
  final String? key;

  /// The pseudo-classes currently true for this target.
  final Set<PseudoClass> states;

  /// The target's parent, so ancestor and child selectors can walk upward.
  final StyleTarget? parent;
}

/// A matchable condition. Subclasses are the subset named in section 28.2.
sealed class StyleSelector {
  const StyleSelector();

  bool matches(StyleTarget target);

  /// How specific this selector is, used to order competing rules.
  ///
  /// The scale is coarse on purpose - id beats class beats type - because the
  /// value of specificity is a deterministic winner, not an expressive one.
  int get specificity;
}

/// Matches a control by type name.
final class TypeSelector extends StyleSelector {
  const TypeSelector(this.type);

  final String type;

  @override
  bool matches(StyleTarget target) => target.type == type;

  @override
  int get specificity => 1;

  @override
  String toString() => type;
}

/// Matches a control carrying a style class.
final class ClassSelector extends StyleSelector {
  const ClassSelector(this.className);

  final String className;

  @override
  bool matches(StyleTarget target) => target.classes.contains(className);

  @override
  int get specificity => 10;

  @override
  String toString() => '.$className';
}

/// Matches one identified control.
final class KeySelector extends StyleSelector {
  const KeySelector(this.key);

  final String key;

  @override
  bool matches(StyleTarget target) => target.key == key;

  @override
  int get specificity => 100;

  @override
  String toString() => '#$key';
}

/// Matches while a pseudo-class holds.
final class PseudoClassSelector extends StyleSelector {
  const PseudoClassSelector(this.pseudoClass);

  final PseudoClass pseudoClass;

  @override
  bool matches(StyleTarget target) => target.states.contains(pseudoClass);

  @override
  int get specificity => 10;

  @override
  String toString() => ':${pseudoClass.name}';
}

/// Every part must match the same target: `Button.primary:hover`.
final class AndSelector extends StyleSelector {
  const AndSelector(this.parts);

  final List<StyleSelector> parts;

  @override
  bool matches(StyleTarget target) =>
      parts.every((StyleSelector part) => part.matches(target));

  @override
  int get specificity =>
      parts.fold(0, (int sum, StyleSelector part) => sum + part.specificity);

  @override
  String toString() => parts.join();
}

/// Matches when [subject] matches and some ancestor matches [ancestor].
final class DescendantSelector extends StyleSelector {
  const DescendantSelector({required this.ancestor, required this.subject});

  final StyleSelector ancestor;
  final StyleSelector subject;

  @override
  bool matches(StyleTarget target) {
    if (!subject.matches(target)) return false;
    for (StyleTarget? node = target.parent; node != null; node = node.parent) {
      if (ancestor.matches(node)) return true;
    }
    return false;
  }

  @override
  int get specificity => ancestor.specificity + subject.specificity;

  @override
  String toString() => '$ancestor $subject';
}

/// Matches when [subject] matches and its *immediate* parent matches [parent].
final class ChildSelector extends StyleSelector {
  const ChildSelector({required this.parent, required this.subject});

  final StyleSelector parent;
  final StyleSelector subject;

  @override
  bool matches(StyleTarget target) {
    if (!subject.matches(target)) return false;
    final StyleTarget? owner = target.parent;
    return owner != null && parent.matches(owner);
  }

  @override
  int get specificity => parent.specificity + subject.specificity + 1;

  @override
  String toString() => '$parent > $subject';
}

/// One property assignment a rule performs when it matches.
final class StyleSetter<T> {
  const StyleSetter(this.property, this.value);

  final UiProperty<T> property;
  final T value;

  /// Applies this setter at [precedence] on [store].
  void applyTo(PropertyStore store, PropertyPrecedence precedence) =>
      store.write<T>(property, value, precedence: precedence);
}

/// A selector plus the setters it applies.
final class StyleRule {
  const StyleRule({required this.selector, required this.setters});

  final StyleSelector selector;
  final List<StyleSetter<Object?>> setters;

  /// Whether this rule depends on any pseudo-class.
  ///
  /// State-dependent rules land at the `trigger` precedence level and are
  /// re-applied on every state change; stateless ones land at `style` and are
  /// applied once, which is the difference between a hover that costs a
  /// re-match and a background colour that does not.
  bool get isStateDependent => _dependsOnState(selector);

  static bool _dependsOnState(StyleSelector selector) => switch (selector) {
        PseudoClassSelector() => true,
        AndSelector(parts: final List<StyleSelector> parts) =>
          parts.any(_dependsOnState),
        DescendantSelector(
          ancestor: final StyleSelector a,
          subject: final StyleSelector s
        ) =>
          _dependsOnState(a) || _dependsOnState(s),
        ChildSelector(
          parent: final StyleSelector p,
          subject: final StyleSelector s
        ) =>
          _dependsOnState(p) || _dependsOnState(s),
        TypeSelector() || ClassSelector() || KeySelector() => false,
      };
}

/// An ordered collection of rules, with an optional parent scope.
///
/// Scoping mirrors section 28.4: application, window, subtree. A lookup
/// consults the innermost scope last so that it wins ties.
final class Styles {
  Styles({List<StyleRule>? rules, this.parent})
      : _rules = <StyleRule>[...?rules];

  final List<StyleRule> _rules;
  final Styles? parent;

  List<StyleRule> get rules => List<StyleRule>.unmodifiable(_rules);

  void add(StyleRule rule) => _rules.add(rule);

  /// Every matching rule, weakest first.
  ///
  /// Sorted by specificity, and by declaration order within equal specificity,
  /// so applying them in sequence leaves the strongest value on top. Outer
  /// scopes are collected first, so an inner rule of equal specificity wins.
  List<StyleRule> match(StyleTarget target) {
    final List<StyleRule> matched = <StyleRule>[];
    _collect(target, matched);
    return matched;
  }

  void _collect(StyleTarget target, List<StyleRule> into) {
    parent?._collect(target, into);
    final List<StyleRule> local = <StyleRule>[
      for (final StyleRule rule in _rules)
        if (rule.selector.matches(target)) rule,
    ];
    local.sort((StyleRule a, StyleRule b) =>
        a.selector.specificity.compareTo(b.selector.specificity));
    into.addAll(local);
  }

  /// Applies matching rules to [store].
  ///
  /// Stateless rules go to `style` and state-dependent ones to `trigger`, and
  /// both levels are cleared first so a state that stopped holding leaves no
  /// residue. Neither level can disturb a local assignment or a running
  /// animation, by construction.
  PropertyInvalidation applyTo(StyleTarget target, PropertyStore store) {
    PropertyInvalidation invalidation = store.clearLevel(
      PropertyPrecedence.style,
    );
    invalidation = mergeInvalidation(
      invalidation,
      store.clearLevel(PropertyPrecedence.trigger),
    );
    for (final StyleRule rule in match(target)) {
      final PropertyPrecedence level = rule.isStateDependent
          ? PropertyPrecedence.trigger
          : PropertyPrecedence.style;
      for (final StyleSetter<Object?> setter in rule.setters) {
        final Object? before = store.read<Object?>(setter.property);
        setter.applyTo(store, level);
        if (store.read<Object?>(setter.property) != before) {
          invalidation = mergeInvalidation(
            invalidation,
            setter.property.invalidation,
          );
        }
      }
    }
    return invalidation;
  }
}

/// A named value looked up by a hierarchy of dictionaries.
///
/// Section 28.4 asks for hierarchical search, static and dynamic resources,
/// caching, cycle detection and a fallback. All five live here because they
/// interact: the cache must not memoize a value found through a cycle, and the
/// fallback must not fire before the parent chain was searched.
final class ResourceDictionary {
  ResourceDictionary({Map<String, Object?>? values, this.parent})
      : _values = <String, Object?>{...?values};

  final Map<String, Object?> _values;
  final ResourceDictionary? parent;
  final Map<String, Object?> _cache = <String, Object?>{};

  /// Aliases: a key whose value is the name of another key. Stored apart from
  /// plain values so a string value is never mistaken for a reference.
  final Map<String, String> _aliases = <String, String>{};

  void define(String key, Object? value) {
    _values[key] = value;
    invalidate();
  }

  /// Defines [key] as another name for [target].
  void alias(String key, String target) {
    _aliases[key] = target;
    invalidate();
  }

  /// Drops cached lookups here and, necessarily, nothing above: a child that
  /// cached a parent's value must be invalidated by whoever holds it.
  void invalidate() => _cache.clear();

  /// The value for [key], searching this dictionary then its parents.
  ///
  /// Returns [fallback] when nothing is found. Throws [StateError] on an alias
  /// cycle rather than recursing until the stack ends, because a cycle in a
  /// theme file is a data error that must name itself.
  T? lookup<T>(String key, {T? fallback}) {
    final Object? cached = _cache[key];
    if (cached != null) return cached as T;
    final Object? resolved = _resolve(key, <String>{});
    if (resolved == null) return fallback;
    _cache[key] = resolved;
    return resolved as T;
  }

  Object? _resolve(String key, Set<String> followedAliases) {
    // Only an *alias hop* counts toward the cycle check. Delegating the same
    // key to a parent dictionary is the normal hierarchical search, and
    // counting it would make every inherited lookup look like a cycle.
    final String? aliasTarget = _aliases[key];
    if (aliasTarget != null) {
      if (!followedAliases.add(key)) {
        throw StateError(
          'resource alias cycle: ${followedAliases.join(' -> ')} -> $key',
        );
      }
      final Object? value = _resolve(aliasTarget, followedAliases);
      if (value != null) return value;
    }
    if (_values.containsKey(key)) return _values[key];
    return parent?._resolve(key, followedAliases);
  }

  /// Whether [key] resolves anywhere in the chain.
  bool contains(String key) => lookup<Object?>(key) != null;
}
