/// Routes: one screen's worth of content, its transition, and its exit.
///
/// A [Route] is the pairing of two things that are usually confused with each
/// other: *what is on screen* (a page, a dialog, a sheet) and *the animated
/// lifetime of it* (arriving, being covered by the next one, leaving with a
/// result). The first is a widget and could live anywhere. The second is why
/// this file exists, because it is the part that is hard to get right:
///
///   * a route that is leaving must stay on screen until its animation ends,
///     and must be torn down exactly once when it does;
///   * a route that is being covered must animate *at the same time* as the
///     one covering it, driven by that one's clock rather than by a second
///     controller that could drift;
///   * a route that is discarded must release its controller, or a screen the
///     user left ten minutes ago is still asking for frames.
///
/// The transition machinery is built on `animation/`, which takes its time
/// from an injected [AnimationClock] and never reads a wall clock. Nothing in
/// this file calls `DateTime.now`, and a test drives a whole push-and-pop with
/// `ManualDispatcher`'s virtual time.
library;

import '../animation/animation.dart';
import '../animation/curves.dart';
import '../foundation/lifecycle.dart';
import '../geometry/offset.dart';
import '../platform/input_events.dart';
import 'focus.dart';
import 'focus_scope.dart';
import 'keyboard_router.dart';
import 'navigator.dart';
import 'overlay.dart';
import 'proxy.dart';
import 'widget.dart';

/// What a route said when it was asked to go away.
enum RoutePopDisposition {
  /// Nothing objected; the navigator may pop.
  pop,

  /// Something objected - a [PopScope] guarding unsaved work - and the pop
  /// must not happen. The guard has been told, and it is now responsible for
  /// popping later if the user says so.
  doNotPop,
}

/// The name and arguments a route was created from.
final class RouteSettings {
  const RouteSettings({this.name, this.arguments});

  /// The route's name, for named navigation and for `popUntil` predicates.
  final String? name;

  /// Whatever the caller passed to `pushNamed`.
  final Object? arguments;

  RouteSettings copyWith({String? name, Object? arguments}) => RouteSettings(
        name: name ?? this.name,
        arguments: arguments ?? this.arguments,
      );

  @override
  String toString() => 'RouteSettings(${name ?? '<unnamed>'})';
}

/// An animation that never moves.
///
/// Not a shared mutable object with the value happening to be right: a route
/// with no transition genuinely has a constant animation, and handing out a
/// real controller parked at a value would let a caller start it.
final class _ConstantAnimation extends Animation<double> {
  _ConstantAnimation(this.value, this.status);

  @override
  final double value;

  @override
  final AnimationStatus status;

  @override
  bool get isAnimating => false;

  @override
  void addListener(void Function() listener) {}

  @override
  bool removeListener(void Function() listener) => false;

  @override
  void addStatusListener(void Function(AnimationStatus status) listener) {}

  @override
  bool removeStatusListener(void Function(AnimationStatus status) listener) =>
      false;
}

/// The animation of a route that nothing is covering.
///
/// Not `const`, only because [Animation] has no const constructor to call.
final Animation<double> kAlwaysDismissedAnimation =
    _ConstantAnimation(0.0, AnimationStatus.dismissed);

/// The animation of a route that is simply, statically, present.
final Animation<double> kAlwaysCompletedAnimation =
    _ConstantAnimation(1.0, AnimationStatus.completed);

/// An animation that forwards to a parent which may be swapped.
///
/// This is how "the route below animates with the route above" is expressed
/// without either route owning the other's controller. The route below holds
/// one of these as its `secondaryAnimation`; pushing a route on top points it
/// at the newcomer's controller and finalizing that newcomer points it back at
/// nothing. Listeners registered on the proxy survive the swap, which is the
/// whole reason it is not just a nullable field: the widget listening to it
/// was built once, and re-registering it on every push is how a transition
/// ends up with two listeners or none.
final class _ProxyAnimation extends Animation<double> {
  Animation<double>? _parent;
  final List<void Function()> _listeners = <void Function()>[];
  final List<void Function(AnimationStatus)> _statusListeners =
      <void Function(AnimationStatus)>[];

  Animation<double>? get parent => _parent;

  set parent(Animation<double>? value) {
    if (identical(value, _parent)) return;
    final Animation<double>? previous = _parent;
    if (previous != null) {
      previous.removeListener(_handleChange);
      previous.removeStatusListener(_handleStatusChange);
    }
    _parent = value;
    if (value != null) {
      value.addListener(_handleChange);
      value.addStatusListener(_handleStatusChange);
    }
    _handleChange();
    _handleStatusChange(status);
  }

  @override
  double get value => _parent?.value ?? 0.0;

  @override
  AnimationStatus get status => _parent?.status ?? AnimationStatus.dismissed;

  @override
  bool get isAnimating => _parent?.isAnimating ?? false;

  @override
  void addListener(void Function() listener) => _listeners.add(listener);

  @override
  bool removeListener(void Function() listener) => _listeners.remove(listener);

  @override
  void addStatusListener(void Function(AnimationStatus status) listener) =>
      _statusListeners.add(listener);

  @override
  bool removeStatusListener(void Function(AnimationStatus status) listener) =>
      _statusListeners.remove(listener);

  /// Drops the parent and every listener. Called when the owning route dies.
  void dispose() {
    parent = null;
    _listeners.clear();
    _statusListeners.clear();
  }

  void _handleChange() {
    for (final void Function() listener
        in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  void _handleStatusChange(AnimationStatus status) {
    for (final void Function(AnimationStatus) listener
        in List<void Function(AnimationStatus)>.of(_statusListeners)) {
      listener(status);
    }
  }
}

/// One entry in a [Navigator]'s history.
///
/// Everything a navigator does to a route goes through the methods below, and
/// they are called in one order only: [install], then [didAdd] or [didPush],
/// then any number of [didChangeNext] / [didPopNext], then [didPop], then
/// [dispose]. A subclass overrides the parts it needs and inherits the rest;
/// the base class is a route that appears instantly, leaves instantly, and
/// owns no resources.
abstract class Route<T> {
  Route({this.settings = const RouteSettings()});

  final RouteSettings settings;

  /// Called with the result when this route is popped, on the frame the pop is
  /// requested rather than when the exit animation finishes.
  ///
  /// A callback rather than a `Future` on purpose. The framework's determinism
  /// rests on `ManualDispatcher`, which has no event loop of its own; a result
  /// delivered through a microtask would arrive at a moment no test can name
  /// and no frame is responsible for.
  void Function(T? result)? onPopped;

  /// Resources released in reverse acquisition order when the route dies.
  final DisposableBag _resources = DisposableBag();

  /// The focus scope every focusable thing in this route hangs under.
  ///
  /// The navigator attaches exactly one of these to the real focus tree - the
  /// current route's - and parks the rest, which is what keeps Tab inside the
  /// screen the user is looking at. See `navigator.dart`.
  final FocusScopeNode _focusScope = FocusScopeNode(debugLabel: 'route scope');

  /// The route itself, as a focus target.
  ///
  /// It holds focus from the moment the route is pushed until something inside
  /// the route takes it, which is what makes Escape work on a screen the user
  /// has not clicked into yet.
  late final FocusNode _focusNode = FocusNode(
    debugLabel: 'route',
    skipTraversal: true,
    target: _RouteKeyboardTarget(this),
  );

  final List<OverlayEntry> _overlayEntries = <OverlayEntry>[];
  final List<_PopScopeState> _popScopes = <_PopScopeState>[];

  NavigatorState? _navigator;
  FocusNode? _previousFocus;
  bool _disposed = false;

  /// The navigator this route is in.
  NavigatorState get navigator {
    final NavigatorState? navigator = _navigator;
    if (navigator == null) {
      throw StateError(
        '$runtimeType is not in a Navigator. A route reaches its navigator '
        'only between install() and dispose().',
      );
    }
    return navigator;
  }

  bool get isInstalled => _navigator != null;

  bool get isDisposed => _disposed;

  /// This route's overlay entries, bottom first.
  List<OverlayEntry> get overlayEntries =>
      List<OverlayEntry>.unmodifiable(_overlayEntries);

  FocusScopeNode get focusScope => _focusScope;

  FocusNode get focusNode => _focusNode;

  /// Whether this route is the one the user is on.
  bool get isCurrent => identical(_navigator?.currentRoute, this);

  /// Whether this route is still in the history, as opposed to on its way out.
  bool get isActive => _navigator?.isActive(this) ?? false;

  /// This route's own entrance progress: 0 before it arrives, 1 once it has.
  Animation<double> get animation => kAlwaysCompletedAnimation;

  /// The progress of whatever is covering this route, 0 when nothing is.
  Animation<double> get secondaryAnimation => kAlwaysDismissedAnimation;

  /// The node that had focus when this route was pushed, to be restored when
  /// it is popped.
  FocusNode? get previousFocus => _previousFocus;

  // ---------------------------------------------------------------------
  // Lifecycle. Called by NavigatorState; see the class documentation for the
  // order. `internal` prefixes mark the plumbing an application never calls,
  // matching the convention `State.internalWidget` and
  // `GlobalKey.internalRegister` already set.
  // ---------------------------------------------------------------------

  /// Creates whatever this route puts in the overlay. The navigator inserts
  /// the entries; the route only builds them.
  void install() {}

  /// This route arrived without an animation - it is the first screen, or it
  /// replaced another in place.
  void didAdd() => didPush();

  /// This route was pushed on top of the history.
  void didPush() {}

  /// This route was asked to leave.
  ///
  /// Returns true when the navigator may tear it down immediately, and false
  /// when the route will call [NavigatorState.finalizeRoute] itself once its
  /// exit animation ends. Returning false is what keeps a leaving screen on
  /// screen while it leaves.
  bool didPop(T? result) => true;

  /// The route on top of this one changed, or went away (null).
  void didChangeNext(Route<Object?>? next) {}

  /// The route that was on top of this one was popped.
  void didPopNext(Route<Object?> next) {}

  /// This route took the place of [old].
  void didReplace(Route<Object?>? old) {}

  /// Whether anything in this route objects to being popped.
  RoutePopDisposition popDisposition() {
    for (final _PopScopeState scope in _popScopes) {
      if (!scope.widget.canPop) return RoutePopDisposition.doNotPop;
    }
    return RoutePopDisposition.pop;
  }

  /// Tells every [PopScope] in this route what happened to a pop request.
  void notifyPopInvoked({required bool didPop}) {
    for (final _PopScopeState scope in List<_PopScopeState>.of(_popScopes)) {
      scope.widget.onPopInvoked?.call(didPop);
    }
  }

  /// Releases everything this route owns. Idempotent.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _resources.dispose();
    _focusNode.dispose();
    _focusScope.dispose();
    _popScopes.clear();
    _overlayEntries.clear();
    _navigator = null;
  }

  set internalNavigator(NavigatorState? value) => _navigator = value;

  set internalPreviousFocus(FocusNode? value) => _previousFocus = value;

  /// Pops with a result whose static type was erased on the way through the
  /// navigator's history list. A mismatch is a real type error and says so.
  bool internalPop(Object? result) => didPop(result as T?);

  void internalComplete(Object? result) => onPopped?.call(result as T?);

  void internalAddEntries(Iterable<OverlayEntry> entries) =>
      _overlayEntries.addAll(entries);

  /// The nearest enclosing route, or null outside one.
  static Route<Object?>? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_RouteScope>()?.route;

  /// The nearest enclosing route.
  static Route<Object?> of(BuildContext context) {
    final Route<Object?>? route = maybeOf(context);
    if (route == null) {
      throw StateError(
        'no Route above ${context.widget.runtimeType}; this widget only means '
        'something inside a route pushed onto a Navigator',
      );
    }
    return route;
  }

  @override
  String toString() => '$runtimeType(${settings.name ?? '<unnamed>'})';
}

/// A route whose content lives in overlay entries.
abstract class OverlayRoute<T> extends Route<T> {
  OverlayRoute({super.settings});

  /// The entries this route puts in the overlay, bottom first.
  Iterable<OverlayEntry> createOverlayEntries();

  @override
  void install() {
    super.install();
    internalAddEntries(createOverlayEntries());
  }
}

/// An [OverlayRoute] with an entrance and an exit driven by one controller.
///
/// ## Why one controller for both directions
///
/// A push runs it forward and a pop runs it back from wherever it happens to
/// be. That is what makes the nastiest case correct without a special path:
/// popping *during* the push animation reverses from the current value, so a
/// double-tapped button produces one route that fades part-way in and back
/// out, rather than a route that snaps to fully visible before leaving, or two
/// controllers arguing over the same entry.
///
/// ## Why the entry stops being opaque while it animates
///
/// [OverlayEntry.opaque] is what hides the routes below (see `overlay.dart`).
/// A route that is *arriving* has not covered anything yet, and a route that
/// is leaving has stopped covering; if the entry stayed opaque throughout, the
/// screen underneath would be unbuilt for the whole transition and the user
/// would watch a page fade in over an empty window. So the flag follows the
/// animation status: opaque only while settled at the top.
abstract class TransitionRoute<T> extends OverlayRoute<T> {
  TransitionRoute({
    super.settings,
    this.transitionDuration = const Duration(milliseconds: 200),
  });

  /// How long the entrance takes, and the exit with it.
  final Duration transitionDuration;

  final _ProxyAnimation _secondaryAnimation = _ProxyAnimation();

  AnimationController? _controller;
  bool _popped = false;

  /// Whether this route hides what is under it once it has settled.
  bool get opaque => true;

  /// Whether the routes under an opaque one keep their state. See
  /// [OverlayEntry.maintainState].
  bool get maintainState => true;

  @override
  Animation<double> get animation => _controller ?? kAlwaysDismissedAnimation;

  @override
  Animation<double> get secondaryAnimation => _secondaryAnimation;

  /// The controller behind [animation], for a subclass that needs to drive it.
  AnimationController get controller {
    final AnimationController? controller = _controller;
    if (controller == null) {
      throw StateError('$runtimeType has no controller before install()');
    }
    return controller;
  }

  /// Whether the entrance or the exit is running right now.
  bool get isTransitioning => _controller?.isAnimating ?? false;

  @override
  void install() {
    final AnimationController controller = AnimationController(
      clock: navigator.clock,
      duration: transitionDuration,
    )..addStatusListener(_handleStatusChanged);
    _controller = controller;
    // Registered first, released last: the entries built below read the
    // controller every frame, so the controller must outlive them.
    _resources
      ..add(controller, controller.dispose)
      ..add(_secondaryAnimation, _secondaryAnimation.dispose);
    super.install();
  }

  @override
  void didPush() => controller.forward();

  @override
  void didAdd() {
    // Straight to the end rather than a zero-length animation: the first
    // screen of an application has nothing to animate over, and a fade from
    // nothing is a flash of empty window.
    controller.value = controller.upperBound;
  }

  @override
  bool didPop(T? result) {
    _popped = true;
    if (!isDisposed) controller.reverse();
    // The navigator keeps this route in the overlay until the reverse ends;
    // `_handleStatusChanged` calls `finalizeRoute` then.
    return false;
  }

  @override
  void didChangeNext(Route<Object?>? next) {
    _secondaryAnimation.parent = next?.animation;
  }

  @override
  void dispose() {
    _controller?.removeStatusListener(_handleStatusChanged);
    super.dispose();
  }

  void _handleStatusChanged(AnimationStatus status) {
    final OverlayEntry? entry =
        _overlayEntries.isEmpty ? null : _overlayEntries.first;
    switch (status) {
      case AnimationStatus.completed:
        entry?.opaque = opaque;
        _navigator?.routeDidSettle(this);
      case AnimationStatus.forward:
      case AnimationStatus.reverse:
        entry?.opaque = false;
      case AnimationStatus.dismissed:
        entry?.opaque = false;
        // Only a route that was *popped* dies at the bottom of its animation.
        // One that merely reversed for some other reason is still in the
        // history and would be torn down under its own feet.
        if (_popped) _navigator?.finalizeRoute(this);
    }
  }
}

/// A full screen: opaque when settled, and the thing `push` usually takes.
///
/// Subclasses supply [buildPage] - the content - and optionally
/// [buildTransitions], which wraps that content in whatever moves. The split
/// is what keeps the page from rebuilding its own subtree to animate: the page
/// is built once and the transition wraps it, so a fade does not re-run the
/// page's builder.
abstract class PageRoute<T> extends TransitionRoute<T> {
  PageRoute({
    super.settings,
    super.transitionDuration,
    bool opaque = true,
    bool maintainState = true,
  })  : _opaque = opaque,
        _maintainState = maintainState;

  final bool _opaque;
  final bool _maintainState;

  Widget? _page;

  @override
  bool get opaque => _opaque;

  @override
  bool get maintainState => _maintainState;

  /// The content of this route.
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  );

  /// Wraps [child] in this route's transition. The default is no transition at
  /// all, which is a legitimate route - a page that simply appears.
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) =>
      child;

  @override
  Iterable<OverlayEntry> createOverlayEntries() => <OverlayEntry>[
        OverlayEntry(
          builder: _buildEntry,
          // Not `opaque` yet: the route has not arrived, so it is not covering
          // anything. `_handleStatusChanged` sets it when the entrance ends.
          opaque: false,
          maintainState: maintainState,
        ),
      ];

  @override
  void dispose() {
    _page = null;
    super.dispose();
  }

  Widget _buildEntry(BuildContext context) => _RouteScope(
        route: this,
        child: FocusScope(
          node: focusScope,
          // A route that is not the current one takes no pointers. For an
          // opaque route the overlay has already stopped hit-testing what is
          // under it; this is what makes the *translucent* case - a dialog
          // over a still-visible page - modal as well.
          child: IgnorePointer(
            ignoring: !isCurrent,
            child: _RouteContent(route: this),
          ),
        ),
      );

  Widget _buildPageOnce(BuildContext context) =>
      _page ??= buildPage(context, animation, secondaryAnimation);
}

/// A [PageRoute] assembled from closures, for the common case where a whole
/// subclass would be one method.
final class PageRouteBuilder<T> extends PageRoute<T> {
  PageRouteBuilder({
    required this.pageBuilder,
    this.transitionBuilder,
    super.settings,
    super.transitionDuration,
    super.opaque,
    super.maintainState,
  });

  final Widget Function(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) pageBuilder;

  final Widget Function(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  )? transitionBuilder;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) =>
      pageBuilder(context, animation, secondaryAnimation);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) =>
      transitionBuilder?.call(
        context,
        animation,
        secondaryAnimation,
        child,
      ) ??
      child;
}

/// A page that fades in, and fades back out when it is popped.
///
/// The route being covered is left alone: two crossfading full-screen pages
/// spend the middle of the transition showing the window's clear colour
/// through both of them. [SlidePageRoute] is the one that moves both.
final class FadePageRoute<T> extends PageRoute<T> {
  FadePageRoute({
    required this.builder,
    super.settings,
    super.transitionDuration,
    super.opaque,
    super.maintainState,
    this.curve = Curves.easeInOut,
  });

  final WidgetBuilder builder;

  /// Shapes the fade. [Curves.linear] is the one to pass when a test wants to
  /// name the exact opacity at a given frame.
  final Curve curve;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) =>
      builder(context);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) =>
      Opacity(
        opacity: curve.transform(animation.value.clamp(0.0, 1.0)),
        child: child,
      );
}

/// A page that slides in as it fades, and pushes the page below it aside.
///
/// The distance is a fixed number of logical pixels rather than a fraction of
/// the screen, so the transition needs no [MediaQuery] and behaves identically
/// in a 200-pixel test viewport and on a 4K monitor. That is a deliberate
/// limitation, not an oversight: a full-width slide is a different transition
/// and belongs to whoever writes it with the size in hand.
final class SlidePageRoute<T> extends PageRoute<T> {
  SlidePageRoute({
    required this.builder,
    super.settings,
    super.transitionDuration,
    super.opaque,
    super.maintainState,
    this.travel = 24.0,
    this.curve = Curves.easeInOut,
  });

  final WidgetBuilder builder;

  /// How far, in logical pixels, the arriving page comes from and the covered
  /// page goes.
  final double travel;

  final Curve curve;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) =>
      builder(context);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final double entering = curve.transform(animation.value.clamp(0.0, 1.0));
    final double covered =
        curve.transform(secondaryAnimation.value.clamp(0.0, 1.0));
    return Transform.translate(
      offset: Offset(travel * (1.0 - entering) - travel * covered, 0.0),
      child: Opacity(opacity: entering, child: child),
    );
  }
}

/// Publishes the enclosing route to its content.
final class _RouteScope extends InheritedWidget {
  const _RouteScope({required this.route, required super.child});

  final Route<Object?> route;

  @override
  bool updateShouldNotify(_RouteScope oldWidget) =>
      !identical(route, oldWidget.route);
}

/// The widget that turns a route's animations into rebuilt frames.
///
/// One listener for both animations, registered once for the life of the
/// entry. A route being covered is driven through the [_ProxyAnimation], so
/// this widget keeps rebuilding correctly when the route above it is replaced
/// by another - it never re-subscribes, because the proxy is what changed.
final class _RouteContent extends StatefulWidget {
  const _RouteContent({required this.route});

  final PageRoute<Object?> route;

  @override
  State<_RouteContent> createState() => _RouteContentState();
}

final class _RouteContentState extends State<_RouteContent> {
  @override
  void initState() {
    super.initState();
    _subscribe(widget.route);
  }

  @override
  void didUpdateWidget(_RouteContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.route, widget.route)) return;
    _unsubscribe(oldWidget.route);
    _subscribe(widget.route);
  }

  @override
  void dispose() {
    _unsubscribe(widget.route);
    super.dispose();
  }

  void _subscribe(PageRoute<Object?> route) {
    route.animation.addListener(_handleTick);
    route.secondaryAnimation.addListener(_handleTick);
  }

  void _unsubscribe(PageRoute<Object?> route) {
    route.animation.removeListener(_handleTick);
    route.secondaryAnimation.removeListener(_handleTick);
  }

  void _handleTick() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final PageRoute<Object?> route = widget.route;
    return route.buildTransitions(
      context,
      route.animation,
      route.secondaryAnimation,
      route._buildPageOnce(context),
    );
  }
}

/// Lets the content of a route refuse, or postpone, its own pop.
///
/// The case this exists for is the only one that matters: a form with unsaved
/// changes. Escape, the back gesture and a `pop()` from a toolbar button all
/// arrive at [NavigatorState.maybePop], which asks the current route, which
/// asks these. Setting [canPop] to false stops the pop and calls
/// [onPopInvoked] with `false`, at which point the guard shows whatever
/// confirmation it wants and pops explicitly once the user agrees.
///
/// [onPopInvoked] is also called with `true` when the pop does happen, so a
/// single callback covers both branches and nothing has to guess which one it
/// is in.
final class PopScope extends StatefulWidget {
  const PopScope({
    super.key,
    this.canPop = true,
    this.onPopInvoked,
    required this.child,
  });

  /// Whether the enclosing route may be popped right now.
  final bool canPop;

  /// Called with whether the pop actually happened.
  final void Function(bool didPop)? onPopInvoked;

  final Widget child;

  @override
  State<PopScope> createState() => _PopScopeState();
}

final class _PopScopeState extends State<PopScope> {
  Route<Object?>? _route;

  /// Registered from `build` rather than `initState` for the same reason
  /// `FocusAttachment` attaches from build: the enclosing route is an
  /// inherited value, and reading one in `initState` reads it before this
  /// element has an inherited scope to read from.
  @override
  Widget build(BuildContext context) {
    final Route<Object?>? route = Route.maybeOf(context);
    if (!identical(route, _route)) {
      _detach();
      _route = route;
      route?._popScopes.add(this);
    }
    return widget.child;
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  void _detach() {
    final Route<Object?>? route = _route;
    if (route == null) return;
    route._popScopes
        .removeWhere((_PopScopeState other) => identical(other, this));
    _route = null;
  }
}

/// The keyboard target a route holds while nothing inside it has focus.
///
/// This is the path that makes Escape work on a screen the user has not
/// clicked into. Once a control inside the route takes focus, keys go to that
/// control instead - `keyboard_router.dart` routes to exactly one target and
/// has no bubbling - and the application shortcut map is what catches Escape
/// from there; see `Navigator.installBackShortcuts`.
final class _RouteKeyboardTarget implements KeyboardEventTarget {
  _RouteKeyboardTarget(this.route);

  final Route<Object?> route;

  @override
  bool handleKeyEvent(KeyEvent event) =>
      route._navigator?.handleKeyEvent(event) ?? false;
}
