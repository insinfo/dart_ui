import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

const UiProperty<int> background = UiProperty<int>(
  name: 'background',
  defaultValue: 0xFF000000,
);

const UiProperty<double> padding = UiProperty<double>(
  name: 'padding',
  defaultValue: 0,
  invalidation: PropertyInvalidation.layout,
);

StyleTarget _button({
  Set<String> classes = const <String>{},
  Set<PseudoClass> states = const <PseudoClass>{},
  String? key,
  StyleTarget? parent,
}) =>
    StyleTarget(
      type: 'Button',
      classes: classes,
      key: key,
      states: states,
      parent: parent,
    );

void main() {
  group('selectors', () {
    test('type, class and key match what they name', () {
      final target = _button(classes: <String>{'primary'}, key: 'ok');

      expect(const TypeSelector('Button').matches(target), isTrue);
      expect(const TypeSelector('CheckBox').matches(target), isFalse);
      expect(const ClassSelector('primary').matches(target), isTrue);
      expect(const ClassSelector('danger').matches(target), isFalse);
      expect(const KeySelector('ok').matches(target), isTrue);
    });

    test('specificity orders id over class over type', () {
      expect(
        const KeySelector('ok').specificity,
        greaterThan(const ClassSelector('primary').specificity),
      );
      expect(
        const ClassSelector('primary').specificity,
        greaterThan(const TypeSelector('Button').specificity),
      );
    });

    test('a pseudo-class matches only while the state holds', () {
      const selector = PseudoClassSelector(PseudoClass.hover);

      expect(selector.matches(_button()), isFalse);
      expect(
        selector.matches(_button(states: <PseudoClass>{PseudoClass.hover})),
        isTrue,
      );
    });

    test('an and-selector requires every part', () {
      const selector = AndSelector(<StyleSelector>[
        TypeSelector('Button'),
        ClassSelector('primary'),
        PseudoClassSelector(PseudoClass.pressed),
      ]);

      expect(
        selector.matches(_button(
          classes: <String>{'primary'},
          states: <PseudoClass>{PseudoClass.pressed},
        )),
        isTrue,
      );
      expect(selector.matches(_button(classes: <String>{'primary'})), isFalse);
    });

    test('descendant matches any ancestor, child only the parent', () {
      final StyleTarget toolbar = StyleTarget(type: 'Toolbar');
      final StyleTarget panel = StyleTarget(type: 'Panel', parent: toolbar);
      final StyleTarget button = _button(parent: panel);

      const descendant = DescendantSelector(
        ancestor: TypeSelector('Toolbar'),
        subject: TypeSelector('Button'),
      );
      const child = ChildSelector(
        parent: TypeSelector('Toolbar'),
        subject: TypeSelector('Button'),
      );

      expect(descendant.matches(button), isTrue);
      expect(child.matches(button), isFalse, reason: 'Panel is in between');
      expect(
        const ChildSelector(
          parent: TypeSelector('Panel'),
          subject: TypeSelector('Button'),
        ).matches(button),
        isTrue,
      );
    });
  });

  group('rules', () {
    test('a rule knows whether it depends on state', () {
      const stateless = StyleRule(
        selector: TypeSelector('Button'),
        setters: <StyleSetter<Object?>>[],
      );
      const stateful = StyleRule(
        selector: AndSelector(<StyleSelector>[
          TypeSelector('Button'),
          PseudoClassSelector(PseudoClass.hover),
        ]),
        setters: <StyleSetter<Object?>>[],
      );

      expect(stateless.isStateDependent, isFalse);
      expect(stateful.isStateDependent, isTrue);
    });

    test('matching returns rules weakest first', () {
      final styles = Styles(rules: <StyleRule>[
        const StyleRule(
          selector: KeySelector('ok'),
          setters: <StyleSetter<Object?>>[],
        ),
        const StyleRule(
          selector: TypeSelector('Button'),
          setters: <StyleSetter<Object?>>[],
        ),
      ]);

      final List<StyleRule> matched = styles.match(_button(key: 'ok'));
      expect(matched, hasLength(2));
      expect(matched.first.selector, isA<TypeSelector>());
      expect(matched.last.selector, isA<KeySelector>());
    });
  });

  group('applying styles', () {
    test('a stateless rule lands at style, a stateful one at trigger', () {
      final styles = Styles(rules: <StyleRule>[
        const StyleRule(
          selector: TypeSelector('Button'),
          setters: <StyleSetter<Object?>>[
            StyleSetter<int>(background, 0xFF111111)
          ],
        ),
        const StyleRule(
          selector: AndSelector(<StyleSelector>[
            TypeSelector('Button'),
            PseudoClassSelector(PseudoClass.hover),
          ]),
          setters: <StyleSetter<Object?>>[
            StyleSetter<int>(background, 0xFF222222)
          ],
        ),
      ]);
      final store = PropertyStore(Object());

      styles.applyTo(_button(states: <PseudoClass>{PseudoClass.hover}), store);

      expect(store.read(background), 0xFF222222);
      expect(store.isSetAt(background, PropertyPrecedence.style), isTrue);
      expect(store.isSetAt(background, PropertyPrecedence.trigger), isTrue);
    });

    test('a state that stopped holding leaves no residue', () {
      final styles = Styles(rules: <StyleRule>[
        const StyleRule(
          selector: TypeSelector('Button'),
          setters: <StyleSetter<Object?>>[
            StyleSetter<int>(background, 0xFF111111)
          ],
        ),
        const StyleRule(
          selector: PseudoClassSelector(PseudoClass.hover),
          setters: <StyleSetter<Object?>>[
            StyleSetter<int>(background, 0xFF222222)
          ],
        ),
      ]);
      final store = PropertyStore(Object());

      styles.applyTo(_button(states: <PseudoClass>{PseudoClass.hover}), store);
      expect(store.read(background), 0xFF222222);

      styles.applyTo(_button(), store);
      expect(store.read(background), 0xFF111111,
          reason: 'leaving hover must not keep the hover colour');
    });

    test('a style cannot overwrite a local assignment', () {
      final styles = Styles(rules: <StyleRule>[
        const StyleRule(
          selector: TypeSelector('Button'),
          setters: <StyleSetter<Object?>>[
            StyleSetter<int>(background, 0xFF111111)
          ],
        ),
      ]);
      final store = PropertyStore(Object())..write(background, 0xFFABCDEF);

      styles.applyTo(_button(), store);

      expect(store.read(background), 0xFFABCDEF);
    });

    test('applying reports the strongest invalidation it caused', () {
      final styles = Styles(rules: <StyleRule>[
        const StyleRule(
          selector: TypeSelector('Button'),
          setters: <StyleSetter<Object?>>[
            StyleSetter<int>(background, 0xFF111111),
            StyleSetter<double>(padding, 6),
          ],
        ),
      ]);

      expect(
        styles.applyTo(_button(), PropertyStore(Object())),
        PropertyInvalidation.layout,
      );
    });

    test('an inner scope wins a tie against an outer one', () {
      final application = Styles(rules: <StyleRule>[
        const StyleRule(
          selector: TypeSelector('Button'),
          setters: <StyleSetter<Object?>>[
            StyleSetter<int>(background, 0xFF111111)
          ],
        ),
      ]);
      final panel = Styles(
        rules: <StyleRule>[
          const StyleRule(
            selector: TypeSelector('Button'),
            setters: <StyleSetter<Object?>>[
              StyleSetter<int>(background, 0xFF222222),
            ],
          ),
        ],
        parent: application,
      );
      final store = PropertyStore(Object());

      panel.applyTo(_button(), store);

      expect(store.read(background), 0xFF222222);
    });
  });

  group('resources', () {
    test('a lookup walks the parent chain and falls back', () {
      final base = ResourceDictionary(
        values: <String, Object?>{'accent': 0xFF2D6CDF},
      );
      final panel = ResourceDictionary(parent: base);

      expect(panel.lookup<int>('accent'), 0xFF2D6CDF);
      expect(panel.lookup<int>('missing', fallback: 7), 7);
    });

    test('an inner definition shadows an outer one', () {
      final base = ResourceDictionary(
        values: <String, Object?>{'accent': 1},
      );
      final panel = ResourceDictionary(
        values: <String, Object?>{'accent': 2},
        parent: base,
      );

      expect(panel.lookup<int>('accent'), 2);
      expect(base.lookup<int>('accent'), 1);
    });

    test('an alias resolves to its target', () {
      final resources = ResourceDictionary(
        values: <String, Object?>{'accent': 42},
      )..alias('buttonBackground', 'accent');

      expect(resources.lookup<int>('buttonBackground'), 42);
    });

    test('an alias cycle is named rather than overflowing the stack', () {
      final resources = ResourceDictionary()
        ..alias('a', 'b')
        ..alias('b', 'a');

      expect(
        () => resources.lookup<int>('a'),
        throwsA(isA<StateError>().having(
          (StateError e) => e.message,
          'message',
          contains('cycle'),
        )),
      );
    });

    test('defining a value invalidates the cache', () {
      final resources = ResourceDictionary(
        values: <String, Object?>{'accent': 1},
      );
      expect(resources.lookup<int>('accent'), 1);

      resources.define('accent', 2);

      expect(resources.lookup<int>('accent'), 2);
    });
  });

  group('themes', () {
    test('a theme contributes ambient pseudo-classes', () {
      expect(
        ThemeData.neutralDark.ambientStates,
        contains(PseudoClass.dark),
      );
      expect(
        ThemeData.highContrastDark.ambientStates,
        containsAll(<PseudoClass>[PseudoClass.dark, PseudoClass.highContrast]),
      );
      expect(
        ThemeData.neutralLight.ambientStates,
        contains(PseudoClass.light),
      );
    });

    test('a template registry resolves innermost first', () {
      final base = TemplateRegistry()
        ..register<Button>(ControlTemplate<Button>(
          (BuildContext context, Button control) => Text(control.label),
        ));
      final override = TemplateRegistry(null, base)
        ..register<Button>(ControlTemplate<Button>(
          (BuildContext context, Button control) =>
              Text('OVERRIDE ${control.label}'),
        ));

      expect(base.find(Button), isNotNull);
      expect(override.find(Button), isNot(same(base.find(Button))));
      expect(override.find(CheckBox), isNull);
    });
  });
}
