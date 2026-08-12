import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

const UiProperty<int> background = UiProperty<int>(
  name: 'background',
  defaultValue: 0xFF000000,
);

const UiProperty<double> width = UiProperty<double>(
  name: 'width',
  defaultValue: 0,
  invalidation: PropertyInvalidation.layout,
);

const UiProperty<int> foreground = UiProperty<int>(
  name: 'foreground',
  defaultValue: 0xFFFFFFFF,
  inherits: true,
);

void main() {
  group('precedence', () {
    test('the declared default answers a property nobody set', () {
      final store = PropertyStore(Object());

      expect(store.read(background), 0xFF000000);
      expect(store.effectivePrecedence(background), isNull);
    });

    test('each source wins over every weaker one, in the declared order', () {
      final store = PropertyStore(Object());
      const List<PropertyPrecedence> weakestFirst = <PropertyPrecedence>[
        PropertyPrecedence.inherited,
        PropertyPrecedence.style,
        PropertyPrecedence.trigger,
        PropertyPrecedence.template,
        PropertyPrecedence.binding,
        PropertyPrecedence.local,
        PropertyPrecedence.animation,
      ];

      for (int i = 0; i < weakestFirst.length; i++) {
        store.write(background, i, precedence: weakestFirst[i]);
        expect(store.read(background), i,
            reason: '${weakestFirst[i].name} must win over everything weaker');
        expect(store.effectivePrecedence(background), weakestFirst[i]);
      }
    });

    test('a weaker source writes without disturbing the effective value', () {
      final store = PropertyStore(Object())
        ..write(background, 0xFFFF0000,
            precedence: PropertyPrecedence.animation);

      final bool changed = store.write(
        background,
        0xFF00FF00,
        precedence: PropertyPrecedence.style,
      );

      expect(changed, isFalse, reason: 'the effective value did not move');
      expect(store.read(background), 0xFFFF0000);
      expect(store.isSetAt(background, PropertyPrecedence.style), isTrue);
    });

    test('clearing a level reveals what was underneath it', () {
      final store = PropertyStore(Object())
        ..write(background, 0xFF0000FF, precedence: PropertyPrecedence.style)
        ..write(background, 0xFFFF0000,
            precedence: PropertyPrecedence.animation);
      expect(store.read(background), 0xFFFF0000);

      // This is the whole reason the levels are separate: an animation ends
      // without having to remember - or restore - the style beneath it.
      store.clear(background, precedence: PropertyPrecedence.animation);

      expect(store.read(background), 0xFF0000FF);
    });

    test('clearing a whole level reports the strongest invalidation', () {
      final store = PropertyStore(Object())
        ..write(background, 1, precedence: PropertyPrecedence.trigger)
        ..write(width, 20.0, precedence: PropertyPrecedence.trigger);

      final PropertyInvalidation invalidation =
          store.clearLevel(PropertyPrecedence.trigger);

      expect(invalidation, PropertyInvalidation.layout);
      expect(store.read(width), 0);
      expect(store.read(background), 0xFF000000);
    });
  });

  group('validation and coercion', () {
    test('a rejected value throws rather than being silently dropped', () {
      const UiProperty<double> positive = UiProperty<double>(
        name: 'positive',
        defaultValue: 1,
      );
      final store = PropertyStore(Object());

      expect(
        () => store.write(
          const UiProperty<double>(
            name: 'positive',
            defaultValue: 1,
            validate: _isFinite,
          ),
          double.nan,
        ),
        throwsArgumentError,
      );
      expect(store.read(positive), 1);
    });

    test('coercion clamps on the way in, so every read is already valid', () {
      const UiProperty<double> opacity = UiProperty<double>(
        name: 'opacity',
        defaultValue: 1,
        coerce: _clamp01,
      );
      final store = PropertyStore(Object())..write(opacity, 4.0);

      expect(store.read(opacity), 1.0);
    });
  });

  group('inheritance', () {
    test('an inheriting property falls through to an ancestor store', () {
      final parent = PropertyStore('parent')..write(foreground, 0xFF112233);
      final child = PropertyStore('child')..inheritedParent = parent;

      expect(child.read(foreground), 0xFF112233);
      expect(child.read(background), 0xFF000000,
          reason: 'a non-inheriting property does not walk up');
    });

    test('a local value shadows the inherited one', () {
      final parent = PropertyStore('parent')..write(foreground, 0xFF112233);
      final child = PropertyStore('child')
        ..inheritedParent = parent
        ..write(foreground, 0xFF445566);

      expect(child.read(foreground), 0xFF445566);
    });
  });

  test('a listener hears only effective changes, with the invalidation', () {
    final changes = <(String, PropertyInvalidation)>[];
    final store = PropertyStore(Object())
      ..addListener(
          (UiProperty<Object?> property, PropertyInvalidation invalidation) =>
              changes.add((property.name, invalidation)));

    store
      ..write(width, 10.0)
      ..write(width, 10.0)
      ..write(background, 1, precedence: PropertyPrecedence.style);

    expect(changes, <(String, PropertyInvalidation)>[
      ('width', PropertyInvalidation.layout),
      ('background', PropertyInvalidation.paint),
    ]);
  });

  test('invalidations merge to the strongest', () {
    expect(
      mergeInvalidation(
        PropertyInvalidation.paint,
        PropertyInvalidation.layout,
      ),
      PropertyInvalidation.layout,
    );
    expect(
      mergeInvalidation(
        PropertyInvalidation.visualTree,
        PropertyInvalidation.layout,
      ),
      PropertyInvalidation.visualTree,
    );
  });
}

bool _isFinite(double value) => value.isFinite;

double _clamp01(Object owner, double value) => value.clamp(0.0, 1.0);
