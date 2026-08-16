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
///
/// Section 28.7 adds the fourth thing: a **transition**, so that a value
/// changed by a pseudo-class is reached over time instead of instantly. That
/// lives at the end of this file, in [PropertyTransition] and
/// [StyleTransitionRunner], and it is the one writer of
/// [PropertyPrecedence.animation] in the framework.
library;

import '../animation/animation.dart';
import '../animation/clock.dart';
import '../animation/curves.dart';
import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
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

/// One property that animates instead of jumping when a style changes it.
///
/// Section 28.7 names the properties worth transitioning - colour, opacity,
/// transform, border, shadow, and size "with caution". Nothing here restricts
/// *which* property may be declared; the caution is the caller's, because a
/// transition on a layout-invalidating property re-runs layout on every frame
/// of it, which the [UiProperty.invalidation] of that property already says.
///
/// [lerp] is supplied rather than inferred. A registry mapping types to
/// interpolators would have to be consulted per frame and could not handle a
/// type this layer has never seen, so the transition carries its own.
final class PropertyTransition<T> {
  const PropertyTransition({
    required this.property,
    required this.duration,
    required this.lerp,
    this.curve = Curves.easeOut,
  });

  final UiProperty<T> property;

  /// How long the change takes. [Duration.zero] means "do not animate", which
  /// is legal and is how a single property opts out of a transition set.
  final Duration duration;

  /// The easing applied to progress. [Curves.easeOut] by default because a
  /// state transition should *settle*: the control has already responded, and
  /// what is left is it coming to rest.
  final Curve curve;

  final T Function(T a, T b, double t) lerp;

  // The four operations below exist so the runner can hold a
  // `PropertyTransition<Object?>` and still have `T` bound correctly at
  // runtime. Dart generics are covariant, so the runner may *store* a
  // `PropertyTransition<int>` in a `PropertyTransition<Object?>` slot - and
  // would then fail at the call site when it passed an `Object?` into an
  // `int` parameter. Routing through instance methods keeps the cast inside
  // the object that knows its own type argument.

  /// [lerp], reached through an erased signature.
  Object? lerpErased(Object? a, Object? b, double t) => lerp(a as T, b as T, t);

  /// The effective value of [property] on [store].
  Object? readFrom(PropertyStore store) => store.read<T>(property);

  /// Writes [value] at [PropertyPrecedence.animation].
  bool writeAnimated(PropertyStore store, Object? value) => store.write<T>(
        property,
        value as T,
        precedence: PropertyPrecedence.animation,
      );

  /// Drops the animation slot, revealing whatever the styles put underneath.
  bool clearAnimated(PropertyStore store) => store.clear<T>(
        property,
        precedence: PropertyPrecedence.animation,
      );

  @override
  String toString() => 'PropertyTransition(${property.name}, $duration)';
}

/// Ready-made transitions for the types the framework already interpolates.
abstract final class PropertyTransitions {
  static PropertyTransition<double> ofDouble(
    UiProperty<double> property, {
    required Duration duration,
    Curve curve = Curves.easeOut,
  }) =>
      PropertyTransition<double>(
        property: property,
        duration: duration,
        curve: curve,
        lerp: DoubleTween.interpolate,
      );

  /// A `0xAARRGGBB` colour. See [ColorTween] for why the interpolation is
  /// premultiplied and what that saves you from.
  static PropertyTransition<int> ofColor(
    UiProperty<int> property, {
    required Duration duration,
    Curve curve = Curves.easeOut,
  }) =>
      PropertyTransition<int>(
        property: property,
        duration: duration,
        curve: curve,
        lerp: ColorTween.interpolate,
      );

  static PropertyTransition<Offset> ofOffset(
    UiProperty<Offset> property, {
    required Duration duration,
    Curve curve = Curves.easeOut,
  }) =>
      PropertyTransition<Offset>(
        property: property,
        duration: duration,
        curve: curve,
        lerp: Offset.lerp,
      );

  static PropertyTransition<Size> ofSize(
    UiProperty<Size> property, {
    required Duration duration,
    Curve curve = Curves.easeOut,
  }) =>
      PropertyTransition<Size>(
        property: property,
        duration: duration,
        curve: curve,
        lerp: Size.lerp,
      );

  static PropertyTransition<Rect> ofRect(
    UiProperty<Rect> property, {
    required Duration duration,
    Curve curve = Curves.easeOut,
  }) =>
      PropertyTransition<Rect>(
        property: property,
        duration: duration,
        curve: curve,
        lerp: Rect.lerp,
      );
}

/// One transition in flight. Pre-allocated, never created per frame.
final class _RunningTransition {
  bool active = false;
  Object? begin;
  Object? end;
  Object? current;
  double elapsedMicros = 0.0;
}

/// Applies styles to a [PropertyStore] and animates the properties that
/// declare a transition.
///
/// ## The mechanism, and why [PropertyPrecedence.animation] is the right slot
///
/// `properties.dart` reserves the strongest precedence level for a running
/// animation and, until now, nothing wrote to it. It is the right slot for
/// exactly the reason its own documentation gives: a transition must win over
/// the style that triggered it. Consider hovering a button whose hover rule
/// sets the background to blue. The rule lands at `trigger`; if the transition
/// wrote at `trigger` too the two would fight, and if it wrote at `local` it
/// would be indistinguishable from - and would destroy - a user assignment.
///
/// Writing at `animation` means the style layer underneath is *already* the
/// final value, which is what makes the ending free: when the transition
/// finishes it clears its slot, and the value beneath is the one it was
/// heading for. Nothing is restored, because nothing was overwritten.
///
/// ## Interruption
///
/// The case implementations get wrong: a second state change arriving while a
/// transition is running. The new animation must start from the value **on
/// screen right now**, not from the value the interrupted transition started
/// at. Moving a pointer on and off a button faster than the transition lasts
/// otherwise makes the colour snap backwards on every crossing.
///
/// [apply] handles it by snapshotting the *effective* value before it touches
/// anything. Since a running transition owns the `animation` slot, that
/// snapshot is by construction the displayed value - mid-interpolation or not.
///
/// A re-apply that resolves to the same destination is not an interruption and
/// does not restart the clock: [apply] detects it and lets the running
/// transition continue. Without that check, a style pass that ran every frame
/// would reset the elapsed time every frame and the transition would never
/// finish.
///
/// ## Reduced motion
///
/// When [reducedMotion] is set, [apply] does not animate: it leaves the
/// `animation` slot empty so the style value is the effective value
/// immediately. See `ThemeData.reducedMotion` for the accessibility argument
/// and for what that flag deliberately does *not* do.
///
/// ## Declared limits
///
/// * The runner animates only properties it was constructed with. A property
///   with no declared transition changes instantly, which is the right default
///   - the alternative is a framework that animates layout nobody asked it to.
/// * It holds one [PropertyStore]: one runner per styled element, not one per
///   application. The cost is a fixed-size array of the declared transitions.
final class StyleTransitionRunner implements AnimationTicker {
  StyleTransitionRunner({
    required this.store,
    required List<PropertyTransition<Object?>> transitions,
    AnimationClock? clock,
    bool reducedMotion = false,
  })  : _transitions =
            List<PropertyTransition<Object?>>.unmodifiable(transitions),
        _running = List<_RunningTransition>.generate(
          transitions.length,
          (int _) => _RunningTransition(),
          growable: false,
        ),
        _before = List<Object?>.filled(transitions.length, null),
        _reducedMotion = reducedMotion,
        _clock = clock {
    for (int i = 0; i < _transitions.length; i++) {
      for (int j = i + 1; j < _transitions.length; j++) {
        if (identical(_transitions[i].property, _transitions[j].property)) {
          throw ArgumentError(
            'two transitions declared for the same property '
            '"${_transitions[i].property.name}"; they would fight over the '
            'animation slot and the winner would depend on list order',
          );
        }
      }
    }
    _clock?.addTicker(this);
  }

  final PropertyStore store;

  final List<PropertyTransition<Object?>> _transitions;

  /// Parallel to [_transitions]: index `i` is the state of transition `i`.
  /// Allocated once, so a frame of transitions allocates nothing
  /// (section 6.5).
  final List<_RunningTransition> _running;

  /// Scratch for [apply]'s before-snapshot. Also allocated once.
  final List<Object?> _before;

  final AnimationClock? _clock;

  bool _reducedMotion;
  int _activeCount = 0;
  Duration? _origin;

  List<PropertyTransition<Object?>> get transitions => _transitions;

  /// How many transitions are currently in flight.
  int get activeTransitionCount => _activeCount;

  @override
  bool get isTicking => _activeCount > 0;

  /// Whether transitions are being skipped for accessibility.
  bool get reducedMotion => _reducedMotion;

  /// Turning this on finishes every transition in flight *now*, rather than
  /// letting the current ones run out. A user who just asked the system to
  /// stop animating should not have to sit through the animation that was
  /// already playing.
  set reducedMotion(bool value) {
    if (_reducedMotion == value) return;
    _reducedMotion = value;
    if (value) finishAll();
  }

  /// Applies [styles] for [target] to [store], animating what it can.
  ///
  /// Returns the merged invalidation, exactly as [Styles.applyTo] does, so a
  /// caller can substitute this for a direct call without changing how it
  /// reacts.
  PropertyInvalidation apply(Styles styles, StyleTarget target) {
    // 1. What is on screen right now. For a transition in flight this is the
    //    interpolated value, because the animation slot is the winning one -
    //    which is the whole reason interruption works.
    for (int i = 0; i < _transitions.length; i++) {
      _before[i] = _transitions[i].readFrom(store);
    }

    // 2. Uncover the style layer so step 3 can see where the styles want the
    //    property to be. There is no "read the slot underneath" accessor on
    //    PropertyStore, so the slot has to be dropped and, when the transition
    //    continues, written back.
    for (int i = 0; i < _transitions.length; i++) {
      if (_running[i].active) _transitions[i].clearAnimated(store);
    }

    PropertyInvalidation invalidation = styles.applyTo(target, store);

    // 3. Decide, per property: continue, retarget, or nothing.
    for (int i = 0; i < _transitions.length; i++) {
      final PropertyTransition<Object?> transition = _transitions[i];
      final _RunningTransition state = _running[i];
      final Object? goal = transition.readFrom(store);
      final Object? from = _before[i];

      if (state.active && goal == state.end) {
        // Same destination as before: not an interruption. Put back what the
        // transition was showing and let it keep running.
        transition.writeAnimated(store, state.current);
        continue;
      }

      if (state.active) {
        state.active = false;
        _activeCount--;
      }

      if (goal == from) continue;
      if (_reducedMotion || transition.duration <= Duration.zero) {
        // The animation slot is already empty, so `goal` is the effective
        // value. Jumping straight to the end is literally doing nothing.
        continue;
      }

      if (_activeCount == 0) {
        // First transition of this burst: forget the old origin so the next
        // tick establishes a fresh baseline instead of charging this
        // transition for however long the runner sat idle.
        _origin = null;
      }
      state
        ..active = true
        ..begin = from
        ..end = goal
        ..current = from
        ..elapsedMicros = 0.0;
      _activeCount++;
      transition.writeAnimated(store, from);
      invalidation = mergeInvalidation(
        invalidation,
        transition.property.invalidation,
      );
    }

    if (_activeCount > 0) _clock?.requestFrame();
    return invalidation;
  }

  @override
  void tick(Duration timestamp) {
    final Duration origin = _origin ?? timestamp;
    _origin = timestamp;
    if (_activeCount == 0) return;
    final double deltaMicros = (timestamp - origin).inMicroseconds.toDouble();
    if (deltaMicros <= 0.0) return;

    for (int i = 0; i < _transitions.length; i++) {
      final _RunningTransition state = _running[i];
      if (!state.active) continue;
      final PropertyTransition<Object?> transition = _transitions[i];
      state.elapsedMicros += deltaMicros;
      final double durationMicros =
          transition.duration.inMicroseconds.toDouble();
      final double progress =
          (state.elapsedMicros / durationMicros).clamp(0.0, 1.0);
      if (progress >= 1.0) {
        _finish(i);
        continue;
      }
      final Object? value = transition.lerpErased(
        state.begin,
        state.end,
        transition.curve.transform(progress),
      );
      state.current = value;
      transition.writeAnimated(store, value);
    }
  }

  /// Ends every transition in flight, leaving each property at its final
  /// value.
  void finishAll() {
    for (int i = 0; i < _transitions.length; i++) {
      if (_running[i].active) _finish(i);
    }
  }

  /// Unregisters from the clock and lands any transition in flight.
  void dispose() {
    finishAll();
    _clock?.removeTicker(this);
  }

  /// Ends transition [index] by dropping the animation slot.
  ///
  /// Nothing is written: the style layer underneath already holds the target,
  /// so clearing *is* landing on it - and because it is the same value, the
  /// store reports no change and notifies nobody. A transition therefore ends
  /// without a final redundant repaint.
  void _finish(int index) {
    final _RunningTransition state = _running[index];
    state
      ..active = false
      ..current = state.end;
    _activeCount--;
    _transitions[index].clearAnimated(store);
  }
}
