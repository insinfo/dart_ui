/// The locale as an inherited value, and the delegate seam around it.
///
/// The claims asserted here, each of which is a whole language when it is
/// wrong:
///
///  * a locale is published, scoped per node, and its absence is a **named**
///    failure rather than a silent English default;
///  * resources arrive through delegates keyed by type, synchronously when the
///    delegate has them and behind a placeholder when it does not;
///  * a request for `pt-PT` against a build that ships `pt-BR` resolves, and
///    one for `ja` against the same build fails by name;
///  * the reading direction is *derived* from the locale, so an application
///    states its language once;
///  * a runtime locale change costs a rebuild of the subtree under the
///    [Localizations] and nothing above it - counted, not described;
///  * pseudo-localization lengthens and marks strings without touching the
///    placeholders inside them;
///  * and asking for a Turkish upper case still refuses by name, because this
///    file does not carry a second copy of `case_mapping.dart`'s refusal list.
library;

import 'dart:async';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/widgets/localizations.dart';
import 'package:test/test.dart';

void main() {
  final Locale english = Locale.parse('en');
  final Locale brazilian = Locale.parse('pt-BR');
  final Locale arabic = Locale.parse('ar');

  (BuildOwner, PipelineOwner) mounted(Widget root,
      [Size viewport = _viewport]) {
    final PipelineOwner pipeline = PipelineOwner(
      rootConstraints: BoxConstraints.tight(viewport),
    );
    final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
      ..updateRoot(root);
    pipeline.flushLayout();
    return (owner, pipeline);
  }

  group('publication and scoping', () {
    test('localeOf returns the locale in scope', () {
      final List<Locale> seen = <Locale>[];
      mounted(
        Localizations(
          locale: brazilian,
          child: _LocaleProbe(seen.add),
        ),
      );
      expect(seen, <Locale>[brazilian]);
    });

    test('a nested Localizations shadows only its own subtree', () {
      final List<Locale> outer = <Locale>[];
      final List<Locale> island = <Locale>[];
      final List<Locale> belowIsland = <Locale>[];

      mounted(
        Localizations(
          locale: brazilian,
          child: Column(
            children: <Widget>[
              _LocaleProbe(outer.add),
              Localizations(
                locale: arabic,
                child: Column(
                  children: <Widget>[
                    _LocaleProbe(island.add),
                    Localizations(
                      locale: english,
                      child: _LocaleProbe(belowIsland.add),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

      expect(outer, <Locale>[brazilian]);
      expect(island, <Locale>[arabic]);
      expect(belowIsland, <Locale>[english]);
    });

    test('localeOf throws by name outside a Localizations', () {
      final List<BuildContext> captured = <BuildContext>[];
      mounted(_Capture(captured.add));
      final BuildContext context = captured.single;

      expect(
        () => Localizations.localeOf(context),
        throwsA(
          isA<MissingLocalizationsError>().having(
            (MissingLocalizationsError error) => error.requestedBy,
            'requestedBy',
            '_Capture',
          ),
        ),
      );
      // The message is what gets pasted into an issue.
      expect(
        () => Localizations.localeOf(context),
        throwsA(
          isA<MissingLocalizationsError>().having(
            (MissingLocalizationsError error) => error.toString(),
            'toString',
            allOf(
              contains('No Localizations ancestor'),
              contains('Localizations.maybeLocaleOf'),
            ),
          ),
        ),
      );
    });

    test('maybeLocaleOf answers null instead', () {
      final List<BuildContext> captured = <BuildContext>[];
      mounted(_Capture(captured.add));
      expect(Localizations.maybeLocaleOf(captured.single), isNull);
    });
  });

  group('delegates', () {
    test('a synchronous delegate is visible on the very first build', () {
      // No placeholder frame at all: the FutureOr in LocalizationsDelegate.load
      // exists precisely so that compiled-in strings do not cost one.
      final List<String?> seen = <String?>[];
      mounted(
        Localizations(
          locale: brazilian,
          delegates: const <LocalizationsDelegate<Object>>[_GreetingDelegate()],
          child: _GreetingProbe(seen.add),
        ),
      );
      expect(seen, <String?>['ola']);
    });

    test('resources are keyed by type, so two delegates coexist', () {
      final List<String?> greetings = <String?>[];
      final List<String?> farewells = <String?>[];
      mounted(
        Localizations(
          locale: english,
          delegates: const <LocalizationsDelegate<Object>>[
            _GreetingDelegate(),
            _FarewellDelegate(),
          ],
          child: Column(
            children: <Widget>[
              _GreetingProbe(greetings.add),
              _FarewellProbe(farewells.add),
            ],
          ),
        ),
      );
      expect(greetings, <String?>['hello']);
      expect(farewells, <String?>['bye']);
    });

    test('an unsupported locale simply publishes nothing for that type', () {
      // Null rather than a throw: "this package has no data here" is a state a
      // well-written optional feature handles, and the `?? fallback` idiom is
      // written at the call site where a reviewer can see it.
      final List<String?> seen = <String?>[];
      mounted(
        Localizations(
          locale: Locale.parse('ja'),
          delegates: const <LocalizationsDelegate<Object>>[_GreetingDelegate()],
          child: _GreetingProbe(seen.add),
        ),
      );
      expect(seen, <String?>[null]);
    });

    test('an asynchronous delegate draws the placeholder, then the child',
        () async {
      final Completer<_Greeting> completer = Completer<_Greeting>();
      final List<String?> seen = <String?>[];
      int placeholderBuilds = 0;

      final (BuildOwner owner, PipelineOwner pipeline) = mounted(
        Localizations(
          locale: english,
          delegates: <LocalizationsDelegate<Object>>[
            _AsyncGreetingDelegate(completer.future),
          ],
          placeholder: _BuildCounter(() => placeholderBuilds++),
          child: _GreetingProbe(seen.add),
        ),
      );

      // Nothing below the Localizations has been built: the resources are not
      // there yet and publishing half of them would make every caller defend
      // against a state that lasts one frame.
      expect(seen, isEmpty);
      expect(placeholderBuilds, 1);

      completer.complete(const _Greeting('hello'));
      await Future<void>.delayed(Duration.zero);
      owner.buildScope();
      pipeline.flushLayout();

      expect(seen, <String?>['hello']);
      expect(placeholderBuilds, 1, reason: 'the placeholder is not rebuilt');
    });

    test('a load that lands after the locale moved on is discarded', () async {
      // The generation guard. Without it a slow `en` load overwrites the `ar`
      // resources the user is already looking at.
      final Completer<_Greeting> slow = Completer<_Greeting>();
      final ValueNotifier<Locale> controller = ValueNotifier<Locale>(english);
      final List<String?> seen = <String?>[];

      final (BuildOwner owner, _) = mounted(
        Localizations.controlled(
          controller: controller,
          delegates: <LocalizationsDelegate<Object>>[
            _SwitchingDelegate(slow.future),
          ],
          child: _GreetingProbe(seen.add),
        ),
      );
      expect(seen, isEmpty, reason: 'the first load is asynchronous');

      // Move to a locale the delegate answers synchronously, then let the
      // stale future land.
      controller.value = brazilian;
      owner.buildScope();
      expect(seen, <String?>['ola']);

      slow.complete(const _Greeting('hello'));
      await Future<void>.delayed(Duration.zero);
      owner.buildScope();
      expect(seen, <String?>['ola'], reason: 'the stale load did not win');
    });

    test('a rebuild with an equal delegate list does not reload', () {
      Widget tree() => Localizations(
            locale: english,
            delegates: const <LocalizationsDelegate<Object>>[
              _CountingDelegate(),
            ],
            child: const SizedBox(width: 1, height: 1),
          );

      _CountingDelegate.loads = 0;
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(_viewport),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
        ..updateRoot(tree());
      expect(_CountingDelegate.loads, 1);

      owner.updateRoot(tree());
      expect(
        _CountingDelegate.loads,
        1,
        reason: 'a constant delegate rebuilt into a new tree is the same '
            'delegate; reloading would discard resources to get identical '
            'ones back',
      );
    });

    test('a delegate that says it changed does reload', () {
      _ConfiguredDelegate.loads = 0;
      Widget tree(String suffix) => Localizations(
            locale: english,
            delegates: <LocalizationsDelegate<Object>>[
              _ConfiguredDelegate(suffix),
            ],
            child: const SizedBox(width: 1, height: 1),
          );

      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(_viewport),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
        ..updateRoot(tree('a'));
      expect(_ConfiguredDelegate.loads, 1);

      owner.updateRoot(tree('a'));
      expect(_ConfiguredDelegate.loads, 1);

      owner.updateRoot(tree('b'));
      expect(_ConfiguredDelegate.loads, 2);
    });
  });

  group('resolution against the supported list', () {
    test('pt-PT resolves to pt-BR and the tree sees pt-BR', () {
      final List<Locale> seen = <Locale>[];
      mounted(
        Localizations(
          locale: Locale.parse('pt-PT'),
          supportedLocales: <Locale>[english, brazilian],
          child: _LocaleProbe(seen.add),
        ),
      );
      // Not pt-PT: the tree is told what it actually got, so a widget that
      // formats a date does not format it for a locale nothing was loaded for.
      expect(seen, <Locale>[brazilian]);
    });

    test('with no supported list the locale is published as asked', () {
      final List<Locale> seen = <Locale>[];
      mounted(
        Localizations(
          locale: Locale.parse('pt-PT'),
          child: _LocaleProbe(seen.add),
        ),
      );
      expect(seen, <Locale>[Locale.parse('pt-PT')]);
    });

    test('a locale nothing can serve fails by name at mount', () {
      // Not an English fallback. The application is told, once, at the point
      // the tree is built.
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(_viewport),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline);

      expect(
        () => owner.updateRoot(
          Localizations(
            locale: Locale.parse('ja'),
            supportedLocales: <Locale>[english, brazilian],
            child: const SizedBox(width: 1, height: 1),
          ),
        ),
        throwsA(
          isA<UnresolvedLocaleError>().having(
            (UnresolvedLocaleError error) => error.toString(),
            'toString',
            allOf(contains('ja'), contains('pt-BR')),
          ),
        ),
      );
    });
  });

  group('the reading direction, derived', () {
    test('the pure function answers for the four scripts that matter', () {
      expect(textDirectionForLocale(arabic), TextDirection.rightToLeft);
      expect(
        textDirectionForLocale(Locale.parse('he')),
        TextDirection.rightToLeft,
      );
      expect(
        textDirectionForLocale(Locale.parse('fa-IR')),
        TextDirection.rightToLeft,
      );
      expect(
        textDirectionForLocale(Locale.parse('ur-PK')),
        TextDirection.rightToLeft,
      );
      expect(textDirectionForLocale(english), TextDirection.leftToRight);
      expect(textDirectionForLocale(brazilian), TextDirection.leftToRight);
      expect(
        textDirectionForLocale(Locale.parse('ja')),
        TextDirection.leftToRight,
      );
    });

    test('an application declares its language and gets its direction', () {
      // The point of the bridge: no Directionality anywhere in this tree, and
      // Directionality.of still answers - correctly, and loudly if it could
      // not.
      for (final (Locale locale, TextDirection expected)
          in <(Locale, TextDirection)>[
        (arabic, TextDirection.rightToLeft),
        (Locale.parse('he-IL'), TextDirection.rightToLeft),
        (Locale.parse('fa'), TextDirection.rightToLeft),
        (Locale.parse('ur'), TextDirection.rightToLeft),
        (english, TextDirection.leftToRight),
        (brazilian, TextDirection.leftToRight),
      ]) {
        final List<TextDirection> seen = <TextDirection>[];
        mounted(
          Localizations(locale: locale, child: _DirectionProbe(seen.add)),
        );
        expect(seen, <TextDirection>[expected], reason: '$locale');
      }
    });

    test('the derived direction reaches a real layout', () {
      // Asserted numerically, because "it flipped" and "it flipped twice" look
      // the same to a boolean.
      final (BuildOwner owner, _) = mounted(
        Localizations(
          locale: arabic,
          child: const Row(
            children: <Widget>[
              SizedBox(width: 20, height: 10),
              SizedBox(width: 30, height: 10),
            ],
          ),
        ),
        const Size(200, 50),
      );
      final RenderFlex row = owner.renderRoot! as RenderFlex;
      expect(row.textDirection, TextDirection.rightToLeft);
      expect(row.childAt(0).offsetFromParent.dx, 180);
      expect(row.childAt(1).offsetFromParent.dx, 150);
    });

    test('the override exists, and has to be written down', () {
      // A right-to-left document inside a left-to-right tool chrome is real,
      // and it is expressible - by saying so.
      final List<TextDirection> seen = <TextDirection>[];
      mounted(
        Localizations(
          locale: arabic,
          textDirection: TextDirection.leftToRight,
          child: _DirectionProbe(seen.add),
        ),
      );
      expect(seen, <TextDirection>[TextDirection.leftToRight]);
    });
  });

  group('runtime locale change', () {
    test('the counted cost of a switch', () {
      final ValueNotifier<Locale> controller = ValueNotifier<Locale>(english);
      final List<Locale> dependentSaw = <Locale>[];
      final List<String?> greetings = <String?>[];
      int independentBuilds = 0;
      int outsideBuilds = 0;

      final (BuildOwner owner, _) = mounted(
        Column(
          children: <Widget>[
            // Outside the Localizations entirely: the application chrome that
            // a language menu must not re-render.
            _BuildCounter(() => outsideBuilds++),
            Localizations.controlled(
              controller: controller,
              delegates: const <LocalizationsDelegate<Object>>[
                _GreetingDelegate(),
              ],
              child: Column(
                children: <Widget>[
                  _LocaleProbe(dependentSaw.add),
                  _GreetingProbe(greetings.add),
                  _BuildCounter(() => independentBuilds++),
                ],
              ),
            ),
          ],
        ),
      );

      expect(dependentSaw, <Locale>[english]);
      expect(greetings, <String?>['hello']);
      expect(independentBuilds, 1);
      expect(outsideBuilds, 1);

      controller.value = brazilian;
      owner.buildScope();

      // The locale and the resources both changed, in one pass.
      expect(dependentSaw, <Locale>[english, brazilian]);
      expect(greetings, <String?>['hello', 'ola']);
      // Nothing above the Localizations was touched. That is the scoping claim
      // and it is the one an application can act on: where the widget is put
      // decides what a language switch costs.
      expect(outsideBuilds, 1);
      // And the honest half. The widget below the scope that reads nothing was
      // rebuilt anyway, because `Element.updateChild` in `widgets/element.dart`
      // has no widget-identity short circuit: a rebuilt parent always rebuilds
      // its child. The inherited-widget dependency set therefore decides who is
      // *notified*, not who is rebuilt. Asserted rather than described so that
      // adding such a short circuit shows up here as a deliberate change.
      expect(independentBuilds, 2);
    });

    test('setting the same locale again costs nothing at all', () {
      final ValueNotifier<Locale> controller = ValueNotifier<Locale>(english);
      final List<Locale> seen = <Locale>[];
      int builds = 0;

      final (BuildOwner owner, _) = mounted(
        Localizations.controlled(
          controller: controller,
          child: Column(
            children: <Widget>[
              _LocaleProbe(seen.add),
              _BuildCounter(() => builds++),
            ],
          ),
        ),
      );
      expect(seen, <Locale>[english]);
      expect(builds, 1);

      controller.value = Locale.parse('EN');
      owner.buildScope();

      expect(seen, <Locale>[english], reason: 'normalization made them equal');
      expect(builds, 1);
      expect(owner.hasScheduledBuilds, isFalse);
    });

    test('the declarative form switches too', () {
      // The other half of the API: an application whose locale arrives from
      // above rebuilds this widget with a new one.
      final List<Locale> seen = <Locale>[];
      final Widget child = _LocaleProbe(seen.add);
      Widget tree(Locale locale) => Localizations(locale: locale, child: child);

      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(_viewport),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
        ..updateRoot(tree(english));
      expect(seen, <Locale>[english]);

      owner.updateRoot(tree(arabic));
      expect(seen, <Locale>[english, arabic]);
    });

    test('a switch into a right-to-left locale re-lays the row out', () {
      final ValueNotifier<Locale> controller = ValueNotifier<Locale>(english);
      final (BuildOwner owner, PipelineOwner pipeline) = mounted(
        Localizations.controlled(
          controller: controller,
          child: const Row(
            children: <Widget>[
              SizedBox(width: 20, height: 10),
              SizedBox(width: 30, height: 10),
            ],
          ),
        ),
        const Size(200, 50),
      );
      final RenderFlex row = owner.renderRoot! as RenderFlex;
      expect(row.childAt(0).offsetFromParent.dx, 0);

      controller.value = arabic;
      owner.buildScope();
      pipeline.flushLayout();

      expect(row.textDirection, TextDirection.rightToLeft);
      expect(row.childAt(0).offsetFromParent.dx, 180);
      expect(row.childAt(1).offsetFromParent.dx, 150);
    });
  });

  group('formatting through the tree', () {
    test('formatsOf falls back to the declared table', () {
      final List<String> seen = <String>[];
      mounted(
        Localizations(
          locale: brazilian,
          child: _FormatProbe(seen.add),
        ),
      );
      expect(seen, <String>['1.234,50']);
    });

    test('a delegate that publishes LocaleFormats wins over the table', () {
      // The whole extension story for formatting: one delegate, and every call
      // site keeps working.
      final List<String> seen = <String>[];
      mounted(
        Localizations(
          locale: brazilian,
          delegates: const <LocalizationsDelegate<Object>>[_FormatsDelegate()],
          child: _FormatProbe(seen.add),
        ),
      );
      expect(seen, <String>["1'234.50"]);
    });
  });

  group('pseudo-localization', () {
    const PseudoLocalization pseudo = PseudoLocalization();

    test('it lengthens, by the declared ratio', () {
      const String source = 'Save';
      final String transformed = pseudo.transform(source);
      // Brackets plus the accented text plus the padding.
      expect(transformed.length, 4 + 2 + 2);
      expect(
        transformed.length - 2,
        greaterThanOrEqualTo((source.length * 1.35).ceil()),
      );
      expect(transformed.startsWith('['), isTrue);
      expect(transformed.endsWith(']'), isTrue);
    });

    test('a bigger ratio really is bigger', () {
      const PseudoLocalization tripled = PseudoLocalization(expansion: 3);
      expect(tripled.transform('Save').length, 4 + 8 + 2);
      expect(
        tripled.transform('Save').length,
        greaterThan(pseudo.transform('Save').length),
      );
    });

    test('every ASCII letter is replaced, so a hard-coded string shows up', () {
      const String alphabet =
          'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
      final String transformed = pseudo.transform(alphabet);
      for (final String letter in alphabet.split('')) {
        expect(
          transformed.contains(letter),
          isFalse,
          reason: '$letter survived untransformed',
        );
      }
      // Still the same number of letters: an accent is a replacement, not an
      // insertion, so the transformation cannot be mistaken for the padding.
      expect(
        transformed.substring(1, 1 + alphabet.length).length,
        alphabet.length,
      );
    });

    test('placeholders are left exactly as they were', () {
      // Accenting `{count}` into `{çóúñţ}` would be a bug introduced by the
      // test tool, which is the one thing a test tool must not do.
      expect(pseudo.transform('Hi {name}!'), contains('{name}'));
      expect(pseudo.transform('{count} of {total}'), contains('{count}'));
      expect(pseudo.transform('{count} of {total}'), contains('{total}'));
      expect(pseudo.transform('%s items'), contains('%s'));
      expect(pseudo.transform('%1\$s of %2\$d'), contains('%1\$s'));
      expect(pseudo.transform('%1\$s of %2\$d'), contains('%2\$d'));
    });

    test('an unterminated placeholder is copied rather than mangled', () {
      expect(pseudo.transform('a {b'), contains('{b'));
    });

    test('the empty string stays empty', () {
      // Bracketing nothing would draw a visible `[]` where the application
      // deliberately drew nothing.
      expect(pseudo.transform(''), '');
    });

    test('accenting can be turned off, leaving only the width test', () {
      const PseudoLocalization widthOnly = PseudoLocalization(accent: false);
      final String transformed = widthOnly.transform('Save');
      expect(transformed.startsWith('[Save'), isTrue);
      expect(transformed.length, 4 + 2 + 2);
    });

    test('the delegate activates on the pseudo-locale and nowhere else', () {
      const PseudoLocalizationsDelegate delegate =
          PseudoLocalizationsDelegate();
      expect(delegate.isSupported(Locale.pseudo), isTrue);
      expect(delegate.isSupported(english), isFalse);
      expect(Locale.pseudo.toLanguageTag(), 'en-XA');

      final List<String> seen = <String>[];
      mounted(
        Localizations(
          locale: Locale.pseudo,
          delegates: const <LocalizationsDelegate<Object>>[delegate],
          child: _PseudoProbe(seen.add),
        ),
      );
      expect(seen.single.startsWith('['), isTrue);
      expect(seen.single.contains('Save'), isFalse);
    });

    test('in any other locale the idiom leaves the string alone', () {
      final List<String> seen = <String>[];
      mounted(
        Localizations(
          locale: english,
          delegates: const <LocalizationsDelegate<Object>>[
            PseudoLocalizationsDelegate(),
          ],
          child: _PseudoProbe(seen.add),
        ),
      );
      expect(seen, <String>['Save']);
    });
  });

  group('case conversion for a Locale', () {
    test('Turkish still refuses, by name, through the Locale bridge', () {
      // The point: normalizing a tag must not turn a refusal into a silent
      // root-locale answer. Every spelling of the tag reaches the same set in
      // case_mapping.dart, which is the only place that set exists.
      for (final String tag in <String>[
        'tr',
        'TR',
        'tr-TR',
        'tr_TR',
        'TR-tr'
      ]) {
        expect(
          () => upperCaseIn(Locale.parse(tag), 'istanbul'),
          throwsA(
            isA<UnsupportedCaseLocaleError>()
                .having(
                  (UnsupportedCaseLocaleError error) => error.language,
                  'language',
                  'tr',
                )
                .having(
                  (UnsupportedCaseLocaleError error) => error.operation,
                  'operation',
                  'toUpperCase',
                ),
          ),
          reason: tag,
        );
      }
    });

    test('Azeri and Lithuanian too, and lower case and title case as well', () {
      expect(
        () => lowerCaseIn(Locale.parse('az-Latn-AZ'), 'I'),
        throwsA(isA<UnsupportedCaseLocaleError>()),
      );
      expect(
        () => titleCaseIn(Locale.parse('lt-LT'), 'i'),
        throwsA(isA<UnsupportedCaseLocaleError>()),
      );
      expect(
        () => upperCaseIn(Locale.parse('tur'), 'i'),
        throwsA(isA<UnsupportedCaseLocaleError>()),
      );
    });

    test('the escape hatch still has to be asked for by name', () {
      final List<String> warnings = <String>[];
      final void Function(String) previous = caseMappingWarningHandler;
      caseMappingWarningHandler = warnings.add;
      addTearDown(() => caseMappingWarningHandler = previous);

      expect(
        upperCaseIn(
          Locale.parse('tr-TR'),
          'i',
          onUnsupportedLocale: LocaleHandling.warn,
        ),
        'I',
      );
      expect(warnings, hasLength(1));
      expect(warnings.single, contains('SpecialCasing.txt'));
    });

    test('a locale with no special casing converts normally', () {
      expect(upperCaseIn(brazilian, 'ola'), 'OLA');
      expect(lowerCaseIn(english, 'HELLO'), 'hello');
      // The full mappings are still the ones in use: one code point becomes
      // two, which is the whole reason case_mapping.dart exists.
      expect(upperCaseIn(Locale.parse('de'), 'straße'), 'STRASSE');
    });
  });
}

const Size _viewport = Size(100, 50);

// ---------------------------------------------------------------------------
// Resources and delegates
// ---------------------------------------------------------------------------

final class _Greeting {
  const _Greeting(this.text);

  final String text;
}

final class _Farewell {
  const _Farewell(this.text);

  final String text;
}

const Map<String, String> _greetings = <String, String>{
  'en': 'hello',
  'pt': 'ola',
  'ar': 'marhaba',
};

final class _GreetingDelegate extends LocalizationsDelegate<_Greeting> {
  const _GreetingDelegate();

  @override
  bool isSupported(Locale locale) =>
      _greetings.containsKey(locale.languageCode);

  @override
  _Greeting load(Locale locale) => _Greeting(_greetings[locale.languageCode]!);
}

final class _FarewellDelegate extends LocalizationsDelegate<_Farewell> {
  const _FarewellDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  _Farewell load(Locale locale) => const _Farewell('bye');
}

final class _AsyncGreetingDelegate extends LocalizationsDelegate<_Greeting> {
  const _AsyncGreetingDelegate(this.pending);

  final Future<_Greeting> pending;

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<_Greeting> load(Locale locale) => pending;
}

/// Asynchronous for English and synchronous for everything else, so one test
/// can move off a locale whose load is still in flight.
final class _SwitchingDelegate extends LocalizationsDelegate<_Greeting> {
  const _SwitchingDelegate(this.pending);

  final Future<_Greeting> pending;

  @override
  bool isSupported(Locale locale) =>
      _greetings.containsKey(locale.languageCode);

  @override
  FutureOr<_Greeting> load(Locale locale) => locale.languageCode == 'en'
      ? pending
      : _Greeting(_greetings[locale.languageCode]!);
}

final class _CountingDelegate extends LocalizationsDelegate<_Greeting> {
  const _CountingDelegate();

  static int loads = 0;

  @override
  bool isSupported(Locale locale) => true;

  @override
  _Greeting load(Locale locale) {
    loads++;
    return const _Greeting('hello');
  }
}

final class _ConfiguredDelegate extends LocalizationsDelegate<_Greeting> {
  const _ConfiguredDelegate(this.suffix);

  static int loads = 0;

  final String suffix;

  @override
  bool isSupported(Locale locale) => true;

  @override
  _Greeting load(Locale locale) {
    loads++;
    return _Greeting('hello$suffix');
  }

  @override
  bool shouldReload(_ConfiguredDelegate old) => old.suffix != suffix;
}

final class _FormatsDelegate extends LocalizationsDelegate<LocaleFormats> {
  const _FormatsDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  LocaleFormats load(Locale locale) => const LocaleFormats(
        numbers: NumberSymbols(decimalSeparator: '.', groupSeparator: "'"),
        dates: DateSymbols(fieldOrder: DateFieldOrder.dayMonthYear),
      );
}

// ---------------------------------------------------------------------------
// Probes
// ---------------------------------------------------------------------------

final class _LocaleProbe extends StatelessWidget {
  const _LocaleProbe(this.onLocale);

  final void Function(Locale) onLocale;

  @override
  Widget build(BuildContext context) {
    onLocale(Localizations.localeOf(context));
    return const SizedBox(width: 1, height: 1);
  }
}

final class _GreetingProbe extends StatelessWidget {
  const _GreetingProbe(this.onGreeting);

  final void Function(String?) onGreeting;

  @override
  Widget build(BuildContext context) {
    onGreeting(Localizations.of<_Greeting>(context)?.text);
    return const SizedBox(width: 1, height: 1);
  }
}

final class _FarewellProbe extends StatelessWidget {
  const _FarewellProbe(this.onFarewell);

  final void Function(String?) onFarewell;

  @override
  Widget build(BuildContext context) {
    onFarewell(Localizations.of<_Farewell>(context)?.text);
    return const SizedBox(width: 1, height: 1);
  }
}

final class _DirectionProbe extends StatelessWidget {
  const _DirectionProbe(this.onDirection);

  final void Function(TextDirection) onDirection;

  @override
  Widget build(BuildContext context) {
    onDirection(Directionality.of(context));
    return const SizedBox(width: 1, height: 1);
  }
}

final class _FormatProbe extends StatelessWidget {
  const _FormatProbe(this.onFormatted);

  final void Function(String) onFormatted;

  @override
  Widget build(BuildContext context) {
    onFormatted(
      Localizations.formatsOf(context).formatDecimal(1234.5, fractionDigits: 2),
    );
    return const SizedBox(width: 1, height: 1);
  }
}

/// The production idiom: one null check, and nothing else, when the pseudo
/// delegate is not installed.
final class _PseudoProbe extends StatelessWidget {
  const _PseudoProbe(this.onText);

  final void Function(String) onText;

  @override
  Widget build(BuildContext context) {
    const String label = 'Save';
    onText(
      Localizations.of<PseudoLocalization>(context)?.transform(label) ?? label,
    );
    return const SizedBox(width: 1, height: 1);
  }
}

final class _BuildCounter extends StatelessWidget {
  const _BuildCounter(this.onBuild);

  final void Function() onBuild;

  @override
  Widget build(BuildContext context) {
    onBuild();
    return const SizedBox(width: 1, height: 1);
  }
}

/// Hands its own [BuildContext] out so a lookup can be made from outside a
/// build, where a throw is observed directly rather than through the
/// framework's build-error containment.
final class _Capture extends StatelessWidget {
  const _Capture(this.onContext);

  final void Function(BuildContext) onContext;

  @override
  Widget build(BuildContext context) {
    onContext(context);
    return const SizedBox(width: 1, height: 1);
  }
}
