/// `WidgetsApp`: the application widget a Flutter `main` hands to `runApp`,
/// built on dart_ui's [Navigator].
library;

import '../animation/clock.dart';
import '../graphics/color.dart';
import 'animation_scope.dart';
import 'basic.dart' show DefaultTextStyle;
import 'layout_builder.dart' show Builder;
import 'localizations.dart';
import 'navigator.dart';
import 'overlay.dart' show WidgetBuilder;
import 'routes.dart';
import 'theme.dart' show TextStyle;
import 'widget.dart';
import 'window_scope.dart';

/// Wraps the navigator (or null when there is none) - Flutter's
/// `TransitionBuilder`, the type of [WidgetsApp.builder].
typedef TransitionBuilder = Widget Function(
    BuildContext context, Widget? child);

/// Computes the application title under the app's localizations.
typedef GenerateAppTitle = String Function(BuildContext context);

/// Makes the route for a named page from its builder: how [WidgetsApp]
/// turns [WidgetsApp.routes] and [WidgetsApp.home] into routes when the
/// default page transition is not wanted.
typedef PageRouteFactory = PageRoute<T> Function<T>(
  RouteSettings settings,
  WidgetBuilder builder,
);

/// Picks the locale to use from the requested one and the supported ones.
typedef LocaleResolutionCallback = Locale? Function(
  Locale? locale,
  Iterable<Locale> supportedLocales,
);

/// Picks the locale to use from the requested list and the supported ones.
typedef LocaleListResolutionCallback = Locale? Function(
  List<Locale>? locales,
  Iterable<Locale> supportedLocales,
);

/// Flutter's `WidgetsApp`, with the same parameters.
///
/// What it does here:
///
///   * builds a [Navigator] from [home], [routes], [initialRoute],
///     [onGenerateRoute] and [onUnknownRoute] (with [navigatorKey] as its
///     key), when any of those is given, and hands it to [builder];
///   * routes [home] and [routes] through [pageRouteBuilder] when one is
///     given, and through the navigator's default page transition otherwise
///     (Flutter requires a `pageRouteBuilder`; `MaterialApp` supplies one);
///   * sets the **window title** from [title] or [onGenerateTitle], when it is
///     not empty. That is a difference from Flutter on desktop, where the
///     title only reaches the task switcher: here the window's title bar is
///     the place a desktop shows it. An empty title leaves the window's title
///     (`ApplicationOptions.title`) alone;
///   * installs [Localizations] for [locale] and [localizationsDelegates] when
///     either is given;
///   * applies [textStyle] as the [DefaultTextStyle].
///
/// What it does not do, and why:
///
///   * no `MediaQuery`, `Theme`, `Directionality`, focus scope or popup layer
///     of its own: `runApp`'s window already installs them above the root;
///   * no system locale: without [locale] the first of [supportedLocales]
///     is used, and without either no [Localizations] is installed;
///   * [color], [showPerformanceOverlay], [showSemanticsDebugger],
///     [debugShowWidgetInspector], [debugShowCheckedModeBanner] and
///     [restorationScopeId] are accepted and ignored; there is no
///     `WidgetsApp.router`, `navigatorObservers`, `onGenerateInitialRoutes`,
///     `shortcuts` or `actions` (the navigator installs Escape/Alt+Left
///     itself);
///   * route transitions run on the window's animation clock; outside an
///     application (a test with a bare `BuildOwner`), wrap the app in an
///     `AnimationScope` for them to advance.
class WidgetsApp extends StatefulWidget {
  const WidgetsApp({
    super.key,
    this.navigatorKey,
    this.onGenerateRoute,
    this.onUnknownRoute,
    this.initialRoute,
    this.pageRouteBuilder,
    this.home,
    this.routes = const <String, WidgetBuilder>{},
    this.builder,
    this.title = '',
    this.onGenerateTitle,
    this.textStyle,
    required this.color,
    this.locale,
    this.localizationsDelegates,
    this.localeListResolutionCallback,
    this.localeResolutionCallback,
    this.supportedLocales = const <Locale>[],
    this.showPerformanceOverlay = false,
    this.showSemanticsDebugger = false,
    this.debugShowWidgetInspector = false,
    this.debugShowCheckedModeBanner = true,
    this.restorationScopeId,
  });

  /// The navigator's key, to reach it from outside the tree.
  final GlobalKey<NavigatorState>? navigatorKey;

  /// Builds routes for names [routes] does not contain.
  final RouteFactory? onGenerateRoute;

  /// The last resort for a name nothing else knows.
  final RouteFactory? onUnknownRoute;

  /// The route the navigator starts on; `'/'` when null.
  final String? initialRoute;

  /// Turns a page builder into a route; see the class comment.
  final PageRouteFactory? pageRouteBuilder;

  /// The `'/'` route. Not together with a `'/'` entry in [routes].
  final Widget? home;

  /// Named routes.
  final Map<String, WidgetBuilder> routes;

  /// Wraps the navigator - or, with no navigator, builds the whole app.
  final TransitionBuilder? builder;

  /// The window title; empty leaves the window's own title.
  final String title;

  /// Computes the title under the app's [Localizations]; wins over [title].
  final GenerateAppTitle? onGenerateTitle;

  /// The default text style of the app, or null to keep the theme's.
  final TextStyle? textStyle;

  /// Flutter's task-switcher colour. Accepted and ignored.
  final Color color;

  /// The locale to install, or null.
  final Locale? locale;

  /// The localizations to load for [locale].
  final Iterable<LocalizationsDelegate<Object>>? localizationsDelegates;

  /// Picks the locale from the requested list; consulted before
  /// [localeResolutionCallback].
  final LocaleListResolutionCallback? localeListResolutionCallback;

  /// Picks the locale from the requested one.
  final LocaleResolutionCallback? localeResolutionCallback;

  /// The locales the app supports; empty means any.
  final Iterable<Locale> supportedLocales;

  /// Accepted and ignored.
  final bool showPerformanceOverlay;

  /// Accepted and ignored.
  final bool showSemanticsDebugger;

  /// Accepted and ignored.
  final bool debugShowWidgetInspector;

  /// Accepted and ignored: there is no debug banner.
  final bool debugShowCheckedModeBanner;

  /// Accepted and ignored: there is no state restoration.
  final String? restorationScopeId;

  @override
  State<WidgetsApp> createState() => _WidgetsAppState();
}

class _WidgetsAppState extends State<WidgetsApp> {
  /// Used only when no [AnimationScope] is above the app.
  AnimationClock? _ownClock;

  bool get _usesNavigator =>
      widget.home != null ||
      widget.routes.isNotEmpty ||
      widget.onGenerateRoute != null ||
      widget.onUnknownRoute != null ||
      widget.initialRoute != null;

  Map<String, WidgetBuilder> get _pages {
    final Widget? home = widget.home;
    if (home == null) return widget.routes;
    if (widget.routes.containsKey(Navigator.defaultRouteName)) {
      throw ArgumentError(
        'WidgetsApp has both home and a "/" entry in routes; give only one',
      );
    }
    return <String, WidgetBuilder>{
      Navigator.defaultRouteName: (BuildContext _) => home,
      ...widget.routes,
    };
  }

  Route<Object?>? _generate(RouteSettings settings) {
    final PageRouteFactory? factory = widget.pageRouteBuilder;
    final WidgetBuilder? page = _pages[settings.name];
    if (factory != null && page != null) {
      return factory<Object?>(settings, page);
    }
    return widget.onGenerateRoute?.call(settings);
  }

  Widget _buildNavigator(BuildContext context) {
    final bool customPages = widget.pageRouteBuilder != null;
    return Navigator(
      key: widget.navigatorKey,
      clock:
          AnimationScope.maybeOf(context) ?? (_ownClock ??= AnimationClock()),
      initialRoute: widget.initialRoute ?? Navigator.defaultRouteName,
      // With a page factory every page goes through [_generate], so the
      // navigator's own default transition never sees them.
      routes: customPages ? const <String, WidgetBuilder>{} : _pages,
      onGenerateRoute: customPages ? _generate : widget.onGenerateRoute,
      onUnknownRoute: widget.onUnknownRoute,
    );
  }

  Locale? _resolveLocale() {
    final Locale? requested = widget.locale;
    final List<Locale> supported = widget.supportedLocales.toList();
    final LocaleListResolutionCallback? listCallback =
        widget.localeListResolutionCallback;
    if (listCallback != null) {
      final Locale? picked = listCallback(
        requested == null ? null : <Locale>[requested],
        supported,
      );
      if (picked != null) return picked;
    }
    final LocaleResolutionCallback? callback = widget.localeResolutionCallback;
    if (callback != null) {
      final Locale? picked = callback(requested, supported);
      if (picked != null) return picked;
    }
    return requested ?? (supported.isEmpty ? null : supported.first);
  }

  @override
  Widget build(BuildContext context) {
    final TransitionBuilder? builder = widget.builder;
    final Widget? navigator =
        _usesNavigator ? Builder(builder: _buildNavigator) : null;
    Widget result;
    if (builder != null) {
      result = Builder(
        builder: (BuildContext context) => builder(context, navigator),
      );
    } else if (navigator != null) {
      result = navigator;
    } else {
      throw StateError(
        'WidgetsApp has nothing to show: give it home, routes, '
        'onGenerateRoute, initialRoute or builder',
      );
    }
    final TextStyle? textStyle = widget.textStyle;
    if (textStyle != null) {
      result = DefaultTextStyle(style: textStyle, child: result);
    }
    result = _AppTitle(
      title: widget.title,
      onGenerateTitle: widget.onGenerateTitle,
      child: result,
    );
    final Iterable<LocalizationsDelegate<Object>>? delegates =
        widget.localizationsDelegates;
    final Locale? locale = _resolveLocale();
    if (locale != null) {
      result = Localizations(
        locale: locale,
        delegates:
            delegates?.toList() ?? const <LocalizationsDelegate<Object>>[],
        child: result,
      );
    }
    return result;
  }
}

/// Puts the app's title on the window, recomputing it under the app's
/// localizations so [GenerateAppTitle] can translate it.
class _AppTitle extends StatefulWidget {
  const _AppTitle({
    required this.title,
    required this.onGenerateTitle,
    required this.child,
  });

  final String title;
  final GenerateAppTitle? onGenerateTitle;
  final Widget child;

  @override
  State<_AppTitle> createState() => _AppTitleState();
}

class _AppTitleState extends State<_AppTitle> {
  String? _shown;

  @override
  Widget build(BuildContext context) {
    final GenerateAppTitle? generate = widget.onGenerateTitle;
    final String title = generate == null ? widget.title : generate(context);
    final WindowController? window = WindowScope.of(context);
    if (title.isNotEmpty && title != _shown && window != null) {
      _shown = title;
      window.setTitle(title);
    }
    return widget.child;
  }
}
