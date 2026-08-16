/// The locale in the widget tree, and the seam application resources arrive
/// through.
///
/// Section 33 of the roadmap is explicit: *"Não incluir um sistema completo de
/// mensagens no núcleo gráfico; manter integração extensível."* So this file is
/// an **extension point** and not an ICU. It knows how to hold a [Locale], how
/// to resolve one against what an application supports, how to ask a set of
/// delegates for whatever they want to publish, what to draw while they are
/// still loading, and how to swap the whole lot at runtime. It knows nothing
/// about plurals, gender, message syntax or a `.arb` file, and it deliberately
/// never will: those belong to whatever package an application chooses, behind
/// a [LocalizationsDelegate].
///
/// ## The three things a tree needs
///
///  1. **Which locale.** [Localizations.localeOf], with the resolution rule in
///     `foundation/locale.dart` deciding what a request for `pt-PT` means when
///     only `pt-BR` was built.
///  2. **The resources for it.** [Localizations.of], keyed by the resource
///     type, so two unrelated packages can each publish their own strings into
///     the same subtree without agreeing on anything.
///  3. **Which way it reads.** Derived from the locale and published as a
///     [Directionality], so an application states its language once instead of
///     stating its language and then separately remembering that Arabic is
///     right to left. See [textDirectionForLocale].
///
/// ## Why the reading direction is *derived* here and not stored on the locale
///
/// `Directionality` deliberately carries no policy - see its own file - and
/// `Locale` deliberately lives in `foundation`, which may not name a
/// [TextDirection] at all under the layering rule. The bridge has to be
/// somewhere, and this is the first layer that can see both. That also keeps
/// the override honest: [Localizations.textDirection] exists for the tree that
/// really does want Hebrew text laid out inside a left-to-right chrome, and it
/// has to be written down.
///
/// ## What "runtime locale change" costs, measured
///
/// A locale change rebuilds the subtree under the [Localizations] and nothing
/// above it. Within that subtree it rebuilds everything, not only the widgets
/// that read the locale: `Element.updateChild` in `widgets/element.dart` has no
/// widget-identity short circuit, so a rebuilt parent always rebuilds its
/// child. The inherited-widget dependency mechanism therefore decides who is
/// *notified* rather than who is rebuilt, and the practical scoping tool is
/// where the [Localizations] is placed. `test/widgets/localizations_test.dart`
/// asserts the exact counts rather than describing them.
library;

import 'dart:async';

import '../foundation/locale.dart';
import '../text/case_mapping.dart';
import '../text/shaper.dart' show TextDirection;
import 'basic.dart';
import 'controls.dart' show ValueNotifier;
import 'directionality.dart';
import 'widget.dart';

export '../foundation/locale.dart';

// ---------------------------------------------------------------------------
// Locale to reading direction
// ---------------------------------------------------------------------------

/// The direction text in [locale] runs.
///
/// The whole of the bridge, kept as a free function so a render object or a
/// backend - neither of which has a [BuildContext] - can resolve it from a
/// locale it was handed. The data and the argument for deriving it from the
/// script rather than from the language are in [Locale.isRightToLeft].
TextDirection textDirectionForLocale(Locale locale) => locale.isRightToLeft
    ? TextDirection.rightToLeft
    : TextDirection.leftToRight;

// ---------------------------------------------------------------------------
// Delegates
// ---------------------------------------------------------------------------

/// Produces the resources of type [T] for a locale.
///
/// One delegate per resource type, and the type is the key: a
/// `LocalizationsDelegate<MyAppStrings>` and a
/// `LocalizationsDelegate<PaymentStrings>` coexist in one [Localizations]
/// without either knowing about the other, and neither has to agree on a
/// namespace with the framework. That is the entire extensibility mechanism
/// section 33 asks for, and it is two methods long on purpose.
abstract class LocalizationsDelegate<T extends Object> {
  const LocalizationsDelegate();

  /// Whether this delegate can produce resources for [locale].
  ///
  /// Consulted *after* the locale has been resolved against the supported
  /// list, so this answers "do I have data for this exact locale", not "is
  /// this locale close enough" - closeness is [resolveLocale]'s job and doing
  /// it twice, with two different rules, is how an application ends up with
  /// its strings in one language and its date format in another.
  bool isSupported(Locale locale);

  /// The resources for [locale].
  ///
  /// A [FutureOr] rather than a `Future`, and that is not a micro-optimisation.
  /// A delegate whose strings are compiled into the binary has the answer
  /// immediately; forcing it through a `Future` would mean the first frame of
  /// every application shows the placeholder and the second one shows the
  /// interface, which is a visible flash for a value that was never absent.
  /// Delegates that really do have to read a file or a resource bundle return
  /// a `Future`, and only then is a placeholder drawn.
  ///
  /// Called only when [isSupported] answered true for the same locale.
  FutureOr<T> load(Locale locale);

  /// Whether a rebuild with [old] replaced by this delegate must reload.
  ///
  /// False by default, because the overwhelmingly common delegate is a
  /// constant: `MyStrings.delegate` rebuilt into a new widget tree is the same
  /// delegate and reloading it would throw away resources to get identical
  /// ones back. A delegate that carries configuration - a resource path, an
  /// override table - overrides this and compares it.
  ///
  /// Only ever called with an [old] of the same runtime type.
  bool shouldReload(covariant LocalizationsDelegate<T> old) => false;

  /// The key this delegate's resources are published under, which is [T].
  ///
  /// Reified from the type parameter rather than declared by hand, so a
  /// delegate cannot accidentally publish under a type it does not produce.
  Type get type => T;

  @override
  String toString() => '$runtimeType($type)';
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Thrown when a widget asks for the locale outside a [Localizations].
///
/// The same reasoning as [MissingDirectionalityError]: a silent default is a
/// wrong language on somebody else's machine, and it looks perfect on the
/// machine of whoever forgot the widget.
final class MissingLocalizationsError extends Error {
  MissingLocalizationsError(this.requestedBy);

  /// The widget type that asked, so the message names something in the
  /// reader's own code.
  final String requestedBy;

  @override
  String toString() => 'No Localizations ancestor found for $requestedBy.\n'
      'Something in this subtree reads the ambient locale, and there is none '
      'in scope.\n'
      'Wrap the subtree - usually the whole application - in a Localizations:\n'
      '\n'
      '  Localizations(\n'
      "    locale: Locale.parse('en-US'),\n"
      '    delegates: <LocalizationsDelegate<Object>>[...],\n'
      '    child: ...,\n'
      '  )\n'
      '\n'
      'If this location genuinely has no locale, call '
      'Localizations.maybeLocaleOf and pick a fallback explicitly.';
}

// ---------------------------------------------------------------------------
// Localizations
// ---------------------------------------------------------------------------

/// Publishes a locale, its resources and the reading direction it implies.
///
/// See the library comment for the shape of the whole thing. Two constructors:
/// [Localizations.new] takes the locale as a value, which is what an
/// application whose locale comes from above should use, and
/// [Localizations.controlled] follows a [ValueNotifier], which is what an
/// in-application language switcher should use because it changes the locale
/// without rebuilding anything above this widget.
final class Localizations extends StatefulWidget {
  /// Publishes a fixed [locale]. Changing it means rebuilding this widget.
  const Localizations({
    super.key,
    required Locale locale,
    this.delegates = const <LocalizationsDelegate<Object>>[],
    this.supportedLocales,
    this.textDirection,
    this.placeholder = const SizedBox(width: 0, height: 0),
    required this.child,
  })  : _locale = locale,
        _controller = null;

  /// Publishes whatever [controller] holds, and follows it.
  ///
  /// The runtime language switch. A change to `controller.value` rebuilds this
  /// widget's subtree and nothing above it, which is the difference between a
  /// language menu that re-renders the application content and one that
  /// re-renders the application.
  const Localizations.controlled({
    super.key,
    required ValueNotifier<Locale> controller,
    this.delegates = const <LocalizationsDelegate<Object>>[],
    this.supportedLocales,
    this.textDirection,
    this.placeholder = const SizedBox(width: 0, height: 0),
    required this.child,
  })  : _locale = null,
        _controller = controller;

  final Locale? _locale;
  final ValueNotifier<Locale>? _controller;

  /// The delegates asked for resources, in order.
  ///
  /// Two delegates publishing the same type is a last-one-wins overwrite, and
  /// that is intentional: it is how an application overrides one of a
  /// package's resource sets by listing its own afterwards.
  final List<LocalizationsDelegate<Object>> delegates;

  /// What the application actually ships, or null to accept [locale] as given.
  ///
  /// When present the requested locale is put through [resolveLocaleOrThrow],
  /// so a request for `pt-PT` against `[en, pt-BR]` publishes `pt-BR` and a
  /// request for `ja` against the same list is an [UnresolvedLocaleError]
  /// rather than an application silently in English.
  final List<Locale>? supportedLocales;

  /// Overrides the direction [textDirectionForLocale] would derive.
  ///
  /// Null - the default - means the locale decides, which is the point of
  /// deriving it. Set it for the genuine exception: a right-to-left document
  /// being edited inside a left-to-right tool chrome, or the reverse.
  final TextDirection? textDirection;

  /// What is built while an asynchronous delegate is still loading.
  ///
  /// Reached only on the *first* load. A locale change keeps serving the old
  /// resources until the new ones are ready, because flashing a spinner
  /// between two fully usable languages is worse than one frame of slightly
  /// stale text.
  ///
  /// The default is a zero-sized box rather than a spinner: the framework has
  /// no opinion about what an application's loading state looks like, and a
  /// box that occupies nothing cannot be mistaken for the interface.
  final Widget placeholder;

  final Widget child;

  /// The locale this widget was asked for, before resolution.
  Locale get requestedLocale => _locale ?? _controller!.value;

  /// The locale this widget publishes: [requestedLocale] resolved against
  /// [supportedLocales] when there is one.
  ///
  /// Throws [UnresolvedLocaleError] when nothing supported shares a language
  /// with the request.
  Locale get resolvedLocale {
    final List<Locale>? supported = supportedLocales;
    if (supported == null) return requestedLocale;
    return resolveLocaleOrThrow(<Locale>[requestedLocale], supported);
  }

  /// The resources of type [T] in scope, or null when no delegate published
  /// any.
  ///
  /// Null rather than a throw, because "this package's strings are not
  /// installed" is a condition a well-written optional feature handles - see
  /// the `?? text` idiom on [PseudoLocalization]. A caller for whom the
  /// resources are mandatory writes the `!` and gets a location in its own
  /// code.
  ///
  /// Registers a dependency, so the caller is rebuilt when the locale or the
  /// resources change.
  static T? of<T extends Object>(BuildContext context) {
    final _LocalizationsScope? scope =
        context.dependOnInheritedWidgetOfExactType<_LocalizationsScope>();
    final Object? value = scope?.resources[T];
    return value is T ? value : null;
  }

  /// The locale in scope, or a thrown [MissingLocalizationsError].
  static Locale localeOf(BuildContext context) {
    final Locale? locale = maybeLocaleOf(context);
    if (locale == null) {
      throw MissingLocalizationsError('${context.widget.runtimeType}');
    }
    return locale;
  }

  /// The locale in scope, or null. The escape hatch, stated at the call site.
  static Locale? maybeLocaleOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_LocalizationsScope>()?.locale;

  /// The number and date formats in scope.
  ///
  /// A delegate that publishes a [LocaleFormats] wins; otherwise the small
  /// declared table in `foundation/locale.dart` answers. That ordering is the
  /// whole extension story for formatting: an application that needs real CLDR
  /// data adds one delegate and every call site here keeps working.
  static LocaleFormats formatsOf(BuildContext context) =>
      of<LocaleFormats>(context) ?? LocaleFormats.forLocale(localeOf(context));

  @override
  State<Localizations> createState() => _LocalizationsState();
}

final class _LocalizationsState extends State<Localizations> {
  /// The locale the current [_resources] belong to. Lags [Localizations
  /// .resolvedLocale] while an asynchronous load is in flight, on purpose:
  /// publishing the new locale next to the old strings would show a
  /// half-translated interface.
  Locale? _locale;

  /// Null until the first load completes, which is what the placeholder is
  /// for. Replaced wholesale rather than mutated, so identity is a valid
  /// change test in [_LocalizationsScope.updateShouldNotify].
  Map<Type, Object>? _resources;

  /// Incremented per load, so a slow load for a locale the user has already
  /// navigated away from cannot overwrite a newer one when it finally lands.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    widget._controller?.addListener(_onControllerChanged);
    _load();
  }

  @override
  void didUpdateWidget(Localizations oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget._controller, widget._controller)) {
      oldWidget._controller?.removeListener(_onControllerChanged);
      widget._controller?.addListener(_onControllerChanged);
    }
    if (widget.resolvedLocale != _locale ||
        _delegatesChanged(oldWidget.delegates, widget.delegates)) {
      _load();
    }
  }

  @override
  void dispose() {
    widget._controller?.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged(Locale value) {
    if (widget.resolvedLocale == _locale) return;
    setState(_load);
  }

  /// Asks every supporting delegate for its resources.
  ///
  /// Synchronous delegates land in the same turn and no placeholder is ever
  /// drawn; a single asynchronous one defers the whole set, because publishing
  /// half the resources would make `Localizations.of` answer null for the rest
  /// and every caller would have to defend against a state that lasts one
  /// frame.
  void _load() {
    final Locale locale = widget.resolvedLocale;
    final int generation = ++_generation;
    final Map<Type, Object> resources = <Type, Object>{};
    final List<Future<void>> pending = <Future<void>>[];
    for (final LocalizationsDelegate<Object> delegate in widget.delegates) {
      if (!delegate.isSupported(locale)) continue;
      final Type key = delegate.type;
      final FutureOr<Object> loaded = delegate.load(locale);
      if (loaded is Future<Object>) {
        pending.add(loaded.then((Object value) => resources[key] = value));
      } else {
        resources[key] = loaded;
      }
    }
    if (pending.isEmpty) {
      // No setState: this runs either from initState, where the element is
      // already scheduled, or from didUpdateWidget, where Element.update has
      // already marked it dirty, or from inside a setState call.
      _locale = locale;
      _resources = resources;
      return;
    }
    unawaited(Future.wait<void>(pending).then((List<void> _) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _locale = locale;
        _resources = resources;
      });
    }));
  }

  bool _delegatesChanged(
    List<LocalizationsDelegate<Object>> old,
    List<LocalizationsDelegate<Object>> current,
  ) {
    if (old.length != current.length) return true;
    for (int i = 0; i < current.length; i++) {
      final LocalizationsDelegate<Object> before = old[i];
      final LocalizationsDelegate<Object> after = current[i];
      if (before.runtimeType != after.runtimeType) return true;
      if (after.shouldReload(before)) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final Map<Type, Object>? resources = _resources;
    final Locale? locale = _locale;
    if (resources == null || locale == null) return widget.placeholder;
    return Directionality(
      textDirection: widget.textDirection ?? textDirectionForLocale(locale),
      child: _LocalizationsScope(
        locale: locale,
        resources: resources,
        child: widget.child,
      ),
    );
  }
}

/// The inherited half: one locale and one resource map, published to a subtree.
final class _LocalizationsScope extends InheritedWidget {
  const _LocalizationsScope({
    required this.locale,
    required this.resources,
    required super.child,
  });

  final Locale locale;
  final Map<Type, Object> resources;

  @override
  bool updateShouldNotify(_LocalizationsScope oldWidget) =>
      locale != oldWidget.locale || !identical(resources, oldWidget.resources);
}

// ---------------------------------------------------------------------------
// Pseudo-localization
// ---------------------------------------------------------------------------

/// Lengthens and marks text so a layout is tested against a language it was
/// never laid out in.
///
/// The cheapest internationalisation test there is. German runs roughly 35%
/// longer than English for short user-interface strings and considerably more
/// than that for single words; a button sized to `Save` and never seen in
/// anything else is a clipped `Speichern` in production. Pseudo-localization
/// finds that on the developer's own machine, before any translation exists,
/// by transforming every string the application draws:
///
///  * every Latin letter is replaced by an accented look-alike, which is still
///    readable but makes it obvious at a glance whether a string went through
///    the localization pipeline at all - a label that comes out in plain ASCII
///    is a hard-coded string somebody forgot;
///  * the string is padded to [expansion] times its length, which is what
///    exposes the clipping;
///  * it is wrapped in [prefix] and [suffix], so truncation is visible: a
///    label missing its closing bracket did not fit.
///
/// Placeholders are left alone. `{count}` and `%s` are substituted later by
/// code that matches on their exact spelling, and accenting them turns a
/// working message into a literal `{çóúñţ}` on screen - a bug introduced by
/// the test tool, which is the one thing a test tool must not do.
///
/// Used through a [PseudoLocalizationsDelegate] and the idiom
/// `Localizations.of<PseudoLocalization>(context)?.transform(s) ?? s`, which
/// costs one null check in production and nothing else.
final class PseudoLocalization {
  const PseudoLocalization({
    this.expansion = 1.35,
    this.prefix = '[',
    this.suffix = ']',
    this.accent = true,
  }) : assert(expansion >= 1.0);

  /// How much longer the transformed string is, as a multiple.
  ///
  /// 1.35 by default: the ratio commonly quoted for English into German across
  /// a body of interface strings. Short strings expand by much more than that
  /// in practice - `On` becomes `Eingeschaltet` - so a layout that has to
  /// survive real translation should be tested at 2.0 or 3.0 as well, which is
  /// why this is a parameter and not a constant.
  final double expansion;

  /// Written before the transformed text. ASCII by default, because the mark
  /// has to render in whatever font the application already has; a bracket the
  /// test font cannot draw is a tofu box that hides the very thing it marks.
  final String prefix;

  /// Written after the transformed text. Its absence on screen is the signal
  /// that the string was clipped.
  final String suffix;

  /// Whether Latin letters are replaced by accented look-alikes.
  ///
  /// Turn it off to test width alone - useful when a font is being brought up
  /// and the missing glyphs would be indistinguishable from a layout fault.
  final bool accent;

  /// [text], accented, padded and marked.
  ///
  /// The empty string is returned unchanged: an empty label is an absent
  /// label, and bracketing nothing produces a visible `[]` where the
  /// application deliberately drew nothing.
  String transform(String text) {
    if (text.isEmpty) return text;
    final StringBuffer out = StringBuffer(prefix);
    int index = 0;
    while (index < text.length) {
      final int unit = text.codeUnitAt(index);
      // `{name}` - copied verbatim, including the braces.
      if (unit == 0x7B) {
        final int close = text.indexOf('}', index);
        final int end = close < 0 ? text.length : close + 1;
        out.write(text.substring(index, end));
        index = end;
        continue;
      }
      // `%s`, `%d`, `%1$s` - copied verbatim through the conversion letter.
      if (unit == 0x25) {
        int end = index + 1;
        while (end < text.length && _isFormatUnit(text.codeUnitAt(end))) {
          end++;
        }
        if (end < text.length) end++;
        out.write(text.substring(index, end));
        index = end;
        continue;
      }
      out.write(accent ? _accentOf(unit) : text[index]);
      index++;
    }
    final int padding = (text.length * expansion).ceil() - text.length;
    for (int i = 0; i < padding; i++) {
      out.write(_padding[i % _padding.length]);
    }
    out.write(suffix);
    return out.toString();
  }

  @override
  String toString() => 'PseudoLocalization(x$expansion)';
}

/// Digits, `$` and `.` may appear between `%` and its conversion letter.
bool _isFormatUnit(int unit) =>
    (unit >= 0x30 && unit <= 0x39) || unit == 0x24 || unit == 0x2E;

/// What the string is padded with.
///
/// Vowels rather than a run of dots, so the padding wraps and hyphenates like
/// text and the resulting layout is the one real text would produce. Obviously
/// not a word in any language, so nobody mistakes it for a failed translation.
const String _padding = 'áéíóú';

/// ASCII letters and their accented look-alikes, in the same order.
///
/// Chosen so every replacement is a single UTF-16 code unit and every one is
/// still recognisable as the letter it replaces - the point is a string that
/// can be read and *seen* to have been transformed, not one that is unreadable.
const String _plainLetters =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
const String _accentedLetters =
    'áƀçðéƒĝĥíĵķłɱñóþɋŕšţúʋŵẍýžÁƁÇÐÉƑĜĤÍĴĶŁḾÑÓÞɊŔŠŢÚƲŴẌÝŽ';

String _accentOf(int unit) {
  final int index = _plainLetters.indexOf(String.fromCharCode(unit));
  return index < 0 ? String.fromCharCode(unit) : _accentedLetters[index];
}

/// Publishes a [PseudoLocalization] for the pseudo-locale and nothing else.
///
/// Listed unconditionally in an application's delegates: it activates only
/// under [Locale.pseudo], so a debug build and a release build can run the
/// same widget tree and the transformation is switched on by choosing a
/// locale rather than by a compile-time flag nobody remembers to flip.
final class PseudoLocalizationsDelegate
    extends LocalizationsDelegate<PseudoLocalization> {
  const PseudoLocalizationsDelegate({
    this.pseudoLocalization = const PseudoLocalization(),
    this.locale = Locale.pseudo,
  });

  final PseudoLocalization pseudoLocalization;

  /// The locale that switches the transformation on. [Locale.pseudo] - the
  /// CLDR `en-XA` - by default; see there for why that tag can never collide
  /// with a real region.
  final Locale locale;

  @override
  bool isSupported(Locale locale) => locale == this.locale;

  @override
  PseudoLocalization load(Locale locale) => pseudoLocalization;

  @override
  bool shouldReload(PseudoLocalizationsDelegate old) =>
      old.pseudoLocalization != pseudoLocalization || old.locale != locale;
}

// ---------------------------------------------------------------------------
// Case conversion for a Locale
// ---------------------------------------------------------------------------

/// [text] upper-cased for [locale].
///
/// A one-line bridge, and it lives here for a layering reason: `Locale` is in
/// `foundation`, which may not import `text`, and `text/case_mapping.dart`
/// takes a locale as a bare string precisely so that it does not have to. This
/// is the first layer that can name both.
///
/// It passes [Locale.languageCode] - already normalized to the lower-case
/// primary subtag - straight through, so the refusal in `case_mapping.dart`
/// applies unchanged: `tr`, `az` and `lt` throw [UnsupportedCaseLocaleError]
/// because the conditional rules those languages need live in
/// `SpecialCasing.txt`, which is not in the generated tables. A caller that
/// wants the root-locale answer for them asks for it by name with
/// [LocaleHandling.warn].
///
/// There is no second copy of that refusal list here. One list, in the file
/// that owns the missing data.
String upperCaseIn(
  Locale locale,
  String text, {
  LocaleHandling onUnsupportedLocale = LocaleHandling.fail,
}) =>
    toUpperCase(
      text,
      locale: locale.languageCode,
      onUnsupportedLocale: onUnsupportedLocale,
    );

/// [text] lower-cased for [locale]. See [upperCaseIn] for the refusal rule.
String lowerCaseIn(
  Locale locale,
  String text, {
  LocaleHandling onUnsupportedLocale = LocaleHandling.fail,
}) =>
    toLowerCase(
      text,
      locale: locale.languageCode,
      onUnsupportedLocale: onUnsupportedLocale,
    );

/// [text] title-cased for [locale]. See [upperCaseIn] for the refusal rule.
String titleCaseIn(
  Locale locale,
  String text, {
  LocaleHandling onUnsupportedLocale = LocaleHandling.fail,
}) =>
    toTitleCase(
      text,
      locale: locale.languageCode,
      onUnsupportedLocale: onUnsupportedLocale,
    );
