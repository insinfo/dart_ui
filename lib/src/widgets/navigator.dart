/// The history of screens, and everything that follows from having one.
///
/// Without this file an application is one screen: something builds a tree, the
/// tree is what is on the window, and the only way to show something else is to
/// rebuild the whole thing from a variable somebody remembered to keep. Every
/// feature that makes a desktop application feel like one - pushing a detail
/// view, going back with Escape, a dialog that survives its opener rebuilding,
/// a form that refuses to be left with unsaved work - is a consequence of the
/// history being a real object.
///
/// ## What this is built out of
///
/// One [Overlay] and a list. The overlay is the layer (`overlay.dart`), the
/// list is the history, and a [Route] (`routes.dart`) is one entry in both.
/// There is deliberately no second stacking mechanism here: the ordering and
/// the modal barrier are [OverlayEntry.opaque], and a route that wants to be a
/// dialog is one that declares `opaque: false`.
///
/// ## Focus
///
/// The navigator owns the focus *structure* of its routes, and it does that
/// directly on the focus tree rather than through the widget tree, because the
/// two do not happen at the same time: a route is pushed now and its subtree is
/// built later in the frame, so anything that waited for the subtree would move
/// focus a frame late, or not at all when a route has nothing focusable yet.
///
/// The rule is one sentence: **exactly the current route's focus scope is
/// attached to the real focus tree**, and the rest are parked on a scope of the
/// navigator's own that no [FocusManager] owns. That single invariant produces
/// three behaviours that are otherwise three separate mechanisms:
///
///   * pushing moves focus into the new route, because the old route's scope
///     stops being reachable and the new route's own [Route.focusNode] takes
///     primary focus;
///   * Tab cannot leave the current screen, because the nodes of every other
///     route are not in the traversal ring at all - no modal flag required;
///   * popping gives focus *back to the exact control that had it*, because the
///     route below kept its scope and its remembered child while it was parked,
///     and re-attaching restores the whole subtree at once.
library;

import '../animation/clock.dart';
import '../platform/input_events.dart';
import 'actions.dart';
import 'element.dart';
import 'focus.dart';
import 'focus_scope.dart';
import 'overlay.dart';
import 'routes.dart';
import 'widget.dart';

/// Builds the route for a name the navigator was asked to go to.
///
/// Returning null means "I do not know this name", which is what lets a
/// generator handle a family of names and leave the rest to the next one.
typedef RouteFactory = Route<Object?>? Function(RouteSettings settings);

/// "Go back", independent of whether it arrived from Escape, Alt+Left, a
/// toolbar button or a mouse's fourth button.
final class PopRouteIntent extends Intent {
  const PopRouteIntent();
}

/// A stack of [Route] objects, and the operations that change it.
final class Navigator extends StatefulWidget {
  const Navigator({
    super.key,
    required this.clock,
    this.initialRoute = defaultRouteName,
    this.routes = const <String, WidgetBuilder>{},
    this.onGenerateRoute,
    this.onUnknownRoute,
    this.transitionDuration = const Duration(milliseconds: 200),
    this.installBackShortcuts = true,
  });

  /// The name of the route a navigator starts on.
  static const String defaultRouteName = '/';

  /// The clock every route transition is driven by.
  ///
  /// Required, and injected rather than ambient, for the reason stated at
  /// length in `animation/clock.dart`: the moment a layer reads a wall clock,
  /// two frames stop being reproducible. The application that owns the frame
  /// loop owns the clock and hands it here.
  final AnimationClock clock;

  final String initialRoute;

  /// Named routes, each built into the default page transition.
  final Map<String, WidgetBuilder> routes;

  /// Consulted for names [routes] does not contain.
  final RouteFactory? onGenerateRoute;

  /// The last resort before a name becomes an error.
  final RouteFactory? onUnknownRoute;

  /// How long the default transition takes.
  final Duration transitionDuration;

  /// Whether this navigator installs Escape and Alt+Left on the build owner's
  /// shortcut map when nothing else has claimed it.
  ///
  /// It matters because `keyboard_router.dart` routes a key to exactly one
  /// target and has no bubbling: a route can catch Escape while it holds focus
  /// itself, but the moment a text field inside it is focused, the only path
  /// left for an unhandled Escape is [BuildOwner.shortcuts]. This flag makes
  /// "back" work in that case without every application having to write the
  /// same two bindings. It never overwrites a dispatcher somebody else
  /// installed, and it puts back whatever was there when the navigator is
  /// disposed.
  final bool installBackShortcuts;

  /// The nearest navigator, or null when there is none.
  static NavigatorState? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_NavigatorScope>()?.state;

  /// The nearest navigator.
  static NavigatorState of(BuildContext context) {
    final NavigatorState? navigator = maybeOf(context);
    if (navigator == null) {
      throw StateError(
        'no Navigator above ${context.widget.runtimeType}. Pushing, popping '
        'and PopScope all need a history to act on; put a Navigator above '
        'this widget.',
      );
    }
    return navigator;
  }

  /// A predicate for [NavigatorState.popUntil] that stops at a named route.
  static bool Function(Route<Object?> route) withName(String name) =>
      (Route<Object?> route) => route.settings.name == name;

  /// `Navigator.of(context).push(route)`, spelled the short way.
  static void push<T extends Object?>(BuildContext context, Route<T> route) =>
      of(context).push<T>(route);

  static void pushNamed(
    BuildContext context,
    String name, {
    Object? arguments,
  }) =>
      of(context).pushNamed(name, arguments: arguments);

  static bool pop<T extends Object?>(BuildContext context, [T? result]) =>
      of(context).pop<T>(result);

  static bool maybePop<T extends Object?>(BuildContext context, [T? result]) =>
      of(context).maybePop<T>(result);

  static bool canPop(BuildContext context) => maybeOf(context)?.canPop ?? false;

  @override
  NavigatorState createState() => NavigatorState();
}

/// The history behind a [Navigator].
final class NavigatorState extends State<Navigator> {
  final GlobalKey<OverlayState> _overlayKey =
      GlobalKey<OverlayState>(debugLabel: 'navigator overlay');

  /// The live history, bottom first. The last entry is the current route.
  final List<Route<Object?>> _history = <Route<Object?>>[];

  /// Routes that have been popped and are still animating out. They are no
  /// longer in the history - `canPop`, `currentRoute` and every predicate see
  /// the history as it will be - but they are still in the overlay, which is
  /// what lets a leaving screen finish leaving.
  final List<Route<Object?>> _popping = <Route<Object?>>[];

  /// Entries created before the overlay exists. See [Overlay.initialEntries].
  final List<OverlayEntry> _initialEntries = <OverlayEntry>[];

  /// Routes to remove once a given route has finished arriving, which is how
  /// `pushReplacement` keeps the old screen visible under the new one until
  /// there is something to see.
  final Map<Route<Object?>, List<Route<Object?>>> _pendingRemovals =
      <Route<Object?>, List<Route<Object?>>>{};

  /// Where the focus scopes of routes that are not current are parked.
  ///
  /// A scope node with no manager: its subtree keeps its structure and its
  /// remembered child, and is reachable from no traversal ring. Parking rather
  /// than detaching outright matters because `FocusScope` re-attaches any node
  /// whose parent is null, and a leaving route rebuilds every frame.
  final FocusScopeNode _limbo = FocusScopeNode(debugLabel: 'navigator limbo');

  BuildOwner? _owner;
  FocusScopeNode? _enclosingScope;
  ShortcutDispatcher? _installedShortcuts;

  AnimationClock get clock => widget.clock;

  /// The overlay this navigator's routes live in, once it is mounted.
  OverlayState? get overlay => _overlayKey.currentState;

  /// The route the user is on, or null before the first one is installed.
  Route<Object?>? get currentRoute => _history.isEmpty ? null : _history.last;

  /// The history, bottom first.
  List<Route<Object?>> get history => List<Route<Object?>>.unmodifiable(
        _history,
      );

  /// Routes that are on their way out and still on screen.
  List<Route<Object?>> get poppingRoutes =>
      List<Route<Object?>>.unmodifiable(_popping);

  /// How deep the history is. One means the root route.
  int get depth => _history.length;

  /// Whether there is something to go back to.
  ///
  /// False on the root route, and [pop] refuses there: a navigator with an
  /// empty history is a window showing nothing, which is never what "back"
  /// meant. An application that wants Escape to close the window reads this
  /// and does that itself.
  bool get canPop => _history.length > 1;

  /// Whether [route] is in the history (as opposed to leaving, or gone).
  bool isActive(Route<Object?> route) =>
      _history.any((Route<Object?> other) => identical(other, route));

  @override
  void initState() {
    super.initState();
    final BuildContext context = this.context;
    _owner = context is Element ? context.owner : null;
    _enclosingScope = FocusScope.of(context) ?? _owner?.focusManager.rootScope;
    _installShortcuts();

    final Route<Object?> initial = _routeFor(
      RouteSettings(name: widget.initialRoute),
    );
    _adoptRoute(initial);
    _history.add(initial);
    _insertEntries(initial);
    _activateFocusScope(initial);
    initial.focusNode.requestFocus();
    initial.didAdd();
  }

  // -------------------------------------------------------------------------
  // The history
  // -------------------------------------------------------------------------

  /// Pushes [route] on top of the history and animates it in.
  void push<T extends Object?>(Route<T> route) {
    final Route<Object?>? previous = currentRoute;
    _adoptRoute(route);
    _history.add(route);
    _insertEntries(route);
    _takeFocusFor(route, from: previous);
    previous?.didChangeNext(route);
    route.didPush();
    _markDirty();
  }

  /// Pushes the route [name] resolves to.
  void pushNamed(String name, {Object? arguments}) =>
      push<Object?>(_routeFor(RouteSettings(name: name, arguments: arguments)));

  /// Pushes [route] and removes the current one once [route] has arrived.
  ///
  /// The old route is kept until then on purpose: removing it immediately
  /// would leave the arriving route animating over whatever is *below* the
  /// screen being replaced, which is usually nothing.
  void pushReplacement<T extends Object?>(Route<T> route, {Object? result}) {
    final Route<Object?>? replaced = currentRoute;
    if (replaced == null) {
      push<T>(route);
      return;
    }
    _history.removeLast();
    _adoptRoute(route);
    _history.add(route);
    _insertEntries(route);
    _takeFocusFor(route, from: replaced);
    route.didReplace(replaced);
    route.didPush();
    replaced.internalComplete(result);
    (_pendingRemovals[route] ??= <Route<Object?>>[]).add(replaced);
    _markDirty();
  }

  /// Puts [newRoute] where [oldRoute] is, with no animation at either end.
  void replace<T extends Object?>({
    required Route<Object?> oldRoute,
    required Route<T> newRoute,
  }) {
    final int index = _history.indexWhere(
      (Route<Object?> other) => identical(other, oldRoute),
    );
    if (index < 0) {
      throw ArgumentError('the route being replaced is not in this Navigator');
    }
    final bool wasCurrent = index == _history.length - 1;
    _adoptRoute(newRoute);
    _history[index] = newRoute;
    _insertEntries(newRoute, above: oldRoute);
    newRoute.didReplace(oldRoute);
    newRoute.didAdd();
    if (wasCurrent) _takeFocusFor(newRoute, from: oldRoute);
    _syncNextRoutes();
    _removeImmediately(oldRoute);
    _markDirty();
  }

  /// Pops the current route, animating it out and restoring focus.
  ///
  /// Returns false when there is nothing to pop - see [canPop] - and does
  /// *not* consult [PopScope]; that is [maybePop]'s job, and the difference is
  /// deliberate. `pop` is the confirmation ("the user said discard"), so a
  /// guard that could veto it would make the confirmation impossible.
  bool pop<T extends Object?>([T? result]) {
    if (!canPop) return false;
    final Route<Object?> route = _history.removeLast();
    final Route<Object?> below = _history.last;

    _restoreFocusAfterPop(popped: route, below: below);
    below.didPopNext(route);
    route.internalComplete(result);
    if (route.internalPop(result)) {
      finalizeRoute(route);
    } else {
      _popping.add(route);
    }
    _markDirty();
    return true;
  }

  /// Pops unless something in the current route objects.
  ///
  /// This is what Escape, Alt+Left and a back button call, and the only path
  /// that consults [PopScope]. The guard is asked even on the root route,
  /// where there is nothing to pop: a form with unsaved changes wants to hear
  /// about an attempt to leave whether or not there is a screen behind it.
  bool maybePop<T extends Object?>([T? result]) {
    final Route<Object?>? route = currentRoute;
    if (route == null) return false;
    if (route.popDisposition() == RoutePopDisposition.doNotPop) {
      route.notifyPopInvoked(didPop: false);
      return false;
    }
    if (!canPop) return false;
    final bool popped = pop<T>(result);
    if (popped) route.notifyPopInvoked(didPop: true);
    return popped;
  }

  /// Pops until [predicate] accepts the current route.
  ///
  /// Stops at the root route when nothing ever matches. That is the whole
  /// contract: a predicate that never matches is a caller's mistake, and a
  /// navigator that emptied itself over it would replace a wrong screen with
  /// no screen - a blank window and no way back.
  void popUntil(bool Function(Route<Object?> route) predicate) {
    while (canPop) {
      final Route<Object?> route = currentRoute!;
      if (predicate(route)) return;
      if (!pop<Object?>()) return;
    }
  }

  /// Removes [route] from the history at once, with no exit animation.
  void removeRoute(Route<Object?> route) {
    final int index = _history.indexWhere(
      (Route<Object?> other) => identical(other, route),
    );
    if (index < 0) {
      finalizeRoute(route);
      return;
    }
    final bool wasCurrent = index == _history.length - 1;
    _history.removeAt(index);
    if (wasCurrent && _history.isNotEmpty) {
      final Route<Object?> below = _history.last;
      _restoreFocusAfterPop(popped: route, below: below);
      below.didPopNext(route);
    }
    _removeImmediately(route);
    _markDirty();
  }

  // -------------------------------------------------------------------------
  // Called by routes
  // -------------------------------------------------------------------------

  /// Tears [route] down: takes its entries out of the overlay and disposes it.
  ///
  /// Called by a [TransitionRoute] when its exit animation reaches the bottom,
  /// and by the navigator for routes that leave without animating. Idempotent,
  /// because a route that was removed while it was already leaving would
  /// otherwise be disposed twice - and the second dispose is the one that
  /// throws from inside an animation tick.
  void finalizeRoute(Route<Object?> route) {
    if (route.isDisposed) return;
    _popping.removeWhere((Route<Object?> other) => identical(other, route));
    _pendingRemovals.remove(route);
    overlay?.removeAll(route.overlayEntries);
    _initialEntries.removeWhere(
      (OverlayEntry entry) => route.overlayEntries.any(
        (OverlayEntry other) => identical(other, entry),
      ),
    );
    _parkFocusScope(route);
    route.dispose();
    // Only now: while the route was leaving, the route below it was following
    // its animation backwards, and cutting that link earlier would drop the
    // covered screen back to its resting state one frame into the exit.
    _syncNextRoutes();
    _markDirty();
  }

  /// A route finished arriving.
  void routeDidSettle(Route<Object?> route) {
    final List<Route<Object?>>? pending = _pendingRemovals.remove(route);
    if (pending == null) return;
    for (final Route<Object?> stale in pending) {
      _removeImmediately(stale);
    }
    _markDirty();
  }

  /// Interprets a key event as "go back". Returns whether it did.
  ///
  /// Two spellings, and both are the platform convention rather than a choice:
  /// Escape closes the thing in front of you, and Alt+Left is the browser and
  /// file-manager back gesture that every desktop toolkit inherited.
  bool handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final KeyGesture gesture = KeyGesture.fromEvent(event);
    const KeyGesture escape = KeyGesture(logicalKeyEscape);
    const KeyGesture back = KeyGesture(logicalKeyArrowLeft, alt: true);
    if (gesture != escape && gesture != back) return false;
    return maybePop<Object?>();
  }

  // -------------------------------------------------------------------------
  // Internals
  // -------------------------------------------------------------------------

  Route<Object?> _routeFor(RouteSettings settings) {
    final WidgetBuilder? builder = widget.routes[settings.name];
    if (builder != null) {
      return FadePageRoute<Object?>(
        builder: builder,
        settings: settings,
        transitionDuration: widget.transitionDuration,
      );
    }
    final Route<Object?>? generated = widget.onGenerateRoute?.call(settings);
    if (generated != null) return generated;
    final Route<Object?>? unknown = widget.onUnknownRoute?.call(settings);
    if (unknown != null) return unknown;
    throw StateError(
      'no route for "${settings.name}". A Navigator resolves a name against '
      'its `routes` map, then `onGenerateRoute`, then `onUnknownRoute`; none '
      'of the three produced one, and guessing a blank screen here would hide '
      'a typo until somebody navigated to it.',
    );
  }

  void _adoptRoute(Route<Object?> route) {
    if (route.isInstalled) {
      throw StateError(
        'this Route is already in a Navigator. A route is an identity - it '
        'owns an animation controller and a focus scope - and cannot be in '
        'two histories, or twice in one.',
      );
    }
    route.internalNavigator = this;
    route.focusScope.add(route.focusNode);
    _limbo.add(route.focusScope);
    route.install();
  }

  void _insertEntries(Route<Object?> route, {Route<Object?>? above}) {
    final List<OverlayEntry> entries = route.overlayEntries;
    if (entries.isEmpty) return;
    final OverlayState? overlay = this.overlay;
    if (overlay == null) {
      _initialEntries.addAll(entries);
      return;
    }
    final List<OverlayEntry> anchor =
        above == null ? const <OverlayEntry>[] : above.overlayEntries;
    overlay.insertAll(entries, above: anchor.isEmpty ? null : anchor.last);
  }

  /// Removes a route that is neither animating nor current.
  void _removeImmediately(Route<Object?> route) {
    _popping.removeWhere((Route<Object?> other) => identical(other, route));
    finalizeRoute(route);
  }

  /// Re-points every route's secondary animation at whatever is above it now.
  void _syncNextRoutes() {
    for (int i = 0; i < _history.length; i++) {
      final Route<Object?>? next =
          i + 1 < _history.length ? _history[i + 1] : null;
      _history[i].didChangeNext(next);
    }
  }

  // --- focus ---------------------------------------------------------------

  FocusManager? get _focusManager => _owner?.focusManager;

  void _takeFocusFor(Route<Object?> route, {required Route<Object?>? from}) {
    route.internalPreviousFocus = _focusManager?.primaryFocus;
    if (from != null) _parkFocusScope(from);
    _activateFocusScope(route);
    route.focusNode.requestFocus();
  }

  void _restoreFocusAfterPop({
    required Route<Object?> popped,
    required Route<Object?> below,
  }) {
    // Parked first, and that order is the whole trick: parking clears the
    // focus the leaving route held, and re-attaching the route below brings
    // its whole node subtree - including the control that had focus before the
    // push - back into the manager's tree, where it can be focused again.
    _parkFocusScope(popped);
    _activateFocusScope(below);

    final FocusNode? previous = popped.previousFocus;
    if (previous != null &&
        previous.manager != null &&
        previous.canRequestFocus &&
        previous.requestFocus(FocusChangeReason.restoration)) {
      return;
    }
    // The exact node is gone - the route below was not kept in state, or the
    // control it named has been rebuilt. The scope's own memory is the next
    // best answer, and the route itself is the last one.
    if (below.focusScope.focusRemembered()) return;
    below.focusNode.requestFocus(FocusChangeReason.restoration);
  }

  void _activateFocusScope(Route<Object?> route) {
    final FocusScopeNode? enclosing = _enclosingScope;
    if (enclosing == null) return;
    final FocusScopeNode scope = route.focusScope;
    if (identical(scope.parent, enclosing)) return;
    scope.parent?.remove(scope);
    enclosing.add(scope);
  }

  void _parkFocusScope(Route<Object?> route) {
    final FocusScopeNode scope = route.focusScope;
    if (identical(scope.parent, _limbo) || scope.parent == null) return;
    scope.parent?.remove(scope);
    _limbo.add(scope);
  }

  // --- keyboard ------------------------------------------------------------

  void _installShortcuts() {
    if (!widget.installBackShortcuts) return;
    final BuildOwner? owner = _owner;
    if (owner == null || owner.shortcuts != null) return;
    final ActionMap actions = ActionMap()
      ..register<PopRouteIntent>(
        CallbackAction<PopRouteIntent>(
          (PopRouteIntent intent) => maybePop<Object?>(),
        ),
      );
    final ShortcutDispatcher dispatcher = ShortcutDispatcher(
      shortcuts: ShortcutMap(<KeyGesture, Intent>{
        const KeyGesture(logicalKeyEscape): const PopRouteIntent(),
        const KeyGesture(logicalKeyArrowLeft, alt: true):
            const PopRouteIntent(),
      }),
      actions: actions,
    );
    owner.shortcuts = dispatcher;
    _installedShortcuts = dispatcher;
  }

  void _restoreShortcuts() {
    final ShortcutDispatcher? installed = _installedShortcuts;
    if (installed == null) return;
    final BuildOwner? owner = _owner;
    if (owner != null && identical(owner.shortcuts, installed)) {
      owner.shortcuts = null;
    }
    _installedShortcuts = null;
  }

  void _markDirty() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    _restoreShortcuts();
    final List<Route<Object?>> all = <Route<Object?>>[..._history, ..._popping];
    _history.clear();
    _popping.clear();
    _pendingRemovals.clear();
    _initialEntries.clear();
    for (final Route<Object?> route in all) {
      route.dispose();
    }
    _limbo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _NavigatorScope(
        state: this,
        child: Overlay(key: _overlayKey, initialEntries: _initialEntries),
      );
}

/// Publishes the navigator's state to its subtree.
final class _NavigatorScope extends InheritedWidget {
  const _NavigatorScope({required this.state, required super.child});

  final NavigatorState state;

  @override
  bool updateShouldNotify(_NavigatorScope oldWidget) =>
      !identical(state, oldWidget.state);
}
