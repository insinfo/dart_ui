/// The navigator: history, transitions, focus and the ways a pop goes wrong.
///
/// Everything here runs on `ManualDispatcher`'s virtual clock. Nothing sleeps,
/// nothing polls and nothing reads `DateTime.now`, so "six frames after the
/// push the entering route is at exactly 0.5" is an equality rather than a
/// tolerance - which is the only way the awkward cases (a pop landing in the
/// middle of a push, a route disposed while its own animation is notifying)
/// can be asserted at all.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

import '../layout/helpers.dart';

const Duration _frame = Duration(milliseconds: 10);
const Duration _transition = Duration(milliseconds: 100);

const Color _background = Color(0xFF000000);
const Color _homeColor = Color(0xFFCC3311);
const Color _detailColor = Color(0xFF3366CC);
const Color _dialogColor = Color(0xFF117744);

const (int, int, int, int) _backgroundPixel = (0x00, 0x00, 0x00, 0xFF);
const (int, int, int, int) _homePixel = (0xCC, 0x33, 0x11, 0xFF);
const (int, int, int, int) _detailPixel = (0x33, 0x66, 0xCC, 0xFF);
const (int, int, int, int) _dialogPixel = (0x11, 0x77, 0x44, 0xFF);

void main() {
  late ManualDispatcher dispatcher;
  late PipelineOwner pipeline;
  late FrameScheduler scheduler;
  late AnimationClock clock;
  late BuildOwner owner;
  late NavigatorState nav;

  /// Mounts a navigator whose root route paints [_homeColor].
  ///
  /// The wiring is the application's, in miniature: one dispatcher owns
  /// virtual time, the scheduler turns it into frames, the clock is ticked by
  /// those frames, and the build owner asks the scheduler for one whenever a
  /// `setState` lands.
  NavigatorState mount({
    Map<String, WidgetBuilder>? routes,
    RouteFactory? onGenerateRoute,
    RouteFactory? onUnknownRoute,
    String initialRoute = '/',
    bool installBackShortcuts = true,
    Size viewport = const Size(16, 16),
  }) {
    dispatcher = ManualDispatcher();
    pipeline = PipelineOwner(rootConstraints: BoxConstraints.tight(viewport));
    scheduler = FrameScheduler(
      dispatcher: dispatcher,
      pipelineOwner: pipeline,
      frameInterval: _frame,
      onFrame: (DisplayList list) {},
    );
    clock = AnimationClock()..attachTo(scheduler);
    owner = BuildOwner(
      pipelineOwner: pipeline,
      onBuildScheduled: scheduler.scheduleFrame,
    );
    addTearDown(owner.dispose);

    final GlobalKey<NavigatorState> key = GlobalKey<NavigatorState>();
    owner.updateRoot(
      Navigator(
        key: key,
        clock: clock,
        initialRoute: initialRoute,
        installBackShortcuts: installBackShortcuts,
        transitionDuration: _transition,
        onGenerateRoute: onGenerateRoute,
        onUnknownRoute: onUnknownRoute,
        routes: routes ??
            <String, WidgetBuilder>{
              '/': (BuildContext context) =>
                  const ColoredBox(color: _homeColor),
            },
      ),
    );
    pipeline.flushLayout();
    nav = key.currentState!;
    return nav;
  }

  /// Advances virtual time by [count] frames, then brings the tree up to date.
  ///
  /// The order is the application's order: the frames inside `advance` tick the
  /// animations, and the build that consumes those ticks happens after.
  void pump([int count = 1]) {
    dispatcher.advance(_frame * count);
    owner.buildScope();
    pipeline.flushLayout();
  }

  /// Runs long enough for any transition in flight to finish.
  void settle() => pump(20);

  Future<Framebuffer> pixels({int side = 16}) async {
    owner.buildScope();
    final DisplayList list = DisplayList();
    pipeline.drawFrame(list);
    final MemoryRenderTarget target = await memoryTarget(side, side);
    addTearDown(target.dispose);
    await target.renderDisplayList(list, clearColor: _background.value);
    return target.framebuffer;
  }

  int drawnRectangles() {
    owner.buildScope();
    final DisplayList list = DisplayList();
    pipeline.drawFrame(list);
    return expandDisplayList(list).whereType<DrawRectCommand>().length;
  }

  group('the history', () {
    test('a navigator starts on its initial route and cannot pop it', () async {
      mount();

      expect(nav.depth, 1);
      expect(nav.canPop, isFalse);
      expect(nav.currentRoute!.settings.name, '/');
      expect(pixelAt(await pixels(), 8, 8), _homePixel);
      expect(nav.pop(), isFalse, reason: 'a navigator keeps a root route');
      expect(nav.depth, 1);
    });

    test('push then pop puts the pixels back', () async {
      mount();
      final FadePageRoute<String> detail = _page(_detailColor);
      String? result;
      detail.onPopped = (String? value) => result = value;

      nav.push<String>(detail);
      settle();
      expect(nav.depth, 2);
      expect(nav.canPop, isTrue);
      expect(pixelAt(await pixels(), 8, 8), _detailPixel);

      expect(nav.pop<String>('saved'), isTrue);
      expect(result, 'saved', reason: 'the result reaches the caller at once');
      settle();

      expect(nav.depth, 1);
      expect(nav.poppingRoutes, isEmpty);
      expect(detail.isDisposed, isTrue);
      expect(pixelAt(await pixels(), 8, 8), _homePixel);
    });

    test('an opaque route hides the one below it once it has arrived',
        () async {
      mount();
      nav.push<void>(_page(_detailColor));
      settle();

      expect(
        drawnRectangles(),
        1,
        reason: 'the covered page is not painted at all',
      );
      final OverlayState overlay = nav.overlay!;
      expect(
          overlay.isOnstage(nav.history.first.overlayEntries.single), isFalse);
      expect(overlay.isBuilt(nav.history.first.overlayEntries.single), isTrue,
          reason: 'maintainState keeps the page below alive');
    });

    test('a route cannot be pushed onto two navigators, or twice onto one', () {
      mount();
      final FadePageRoute<void> route = _page(_detailColor);
      nav.push<void>(route);

      expect(() => nav.push<void>(route), throwsStateError);
    });

    test('an unknown name is an error rather than a blank screen', () {
      mount();

      expect(() => nav.pushNamed('/nowhere'), throwsStateError);
    });

    test('named routes come from the map, then the generator, then unknown',
        () async {
      mount(
        routes: <String, WidgetBuilder>{
          '/': (BuildContext context) => const ColoredBox(color: _homeColor),
        },
        onGenerateRoute: (RouteSettings settings) => settings.name == '/detail'
            ? _page(_detailColor, settings: settings)
            : null,
        onUnknownRoute: (RouteSettings settings) =>
            _page(_dialogColor, settings: settings),
      );

      nav.pushNamed('/detail', arguments: 7);
      settle();
      expect(nav.currentRoute!.settings.name, '/detail');
      expect(nav.currentRoute!.settings.arguments, 7);
      expect(pixelAt(await pixels(), 8, 8), _detailPixel);

      nav.pushNamed('/who-knows');
      settle();
      expect(pixelAt(await pixels(), 8, 8), _dialogPixel);
    });

    test('pushReplacement keeps the old screen until the new one has arrived',
        () async {
      mount();
      final FadePageRoute<void> replaced = _page(_detailColor);
      nav.push<void>(replaced);
      settle();

      final FadePageRoute<void> replacement = _page(_dialogColor);
      nav.pushReplacement<void>(replacement);
      pump(6);

      expect(nav.depth, 2, reason: 'the replaced route left the history');
      expect(replaced.isDisposed, isFalse, reason: 'but not the screen');
      settle();

      expect(replaced.isDisposed, isTrue);
      expect(nav.currentRoute, same(replacement));
      expect(pixelAt(await pixels(), 8, 8), _dialogPixel);
    });
  });

  group('transitions', () {
    test('the arriving route and the one it covers animate on one clock',
        () async {
      mount();
      final Route<Object?> home = nav.currentRoute!;
      final FadePageRoute<void> detail = _page(_detailColor);

      nav.push<void>(detail);
      // The push posts a frame, which is where the controller takes its
      // origin; five frame intervals of a hundred-millisecond transition is
      // therefore exactly half of it, with no tolerance needed anywhere.
      pump(5);

      expect(detail.animation.value, 0.5);
      expect(
        home.secondaryAnimation.value,
        0.5,
        reason: 'the covered route reads the covering one, not a clock of its '
            'own',
      );
      expect(
        drawnRectangles(),
        2,
        reason: 'both routes are on screen for the whole transition',
      );

      settle();
      expect(detail.animation.value, 1.0);
      expect(home.secondaryAnimation.value, 1.0);
      expect(drawnRectangles(), 1);
    });

    test(
        'the covered route really moves, in pixels, while the new one '
        'arrives', () async {
      // The page below slides up as it is covered, and the page above covers
      // only the middle, so the framebuffer shows both halves of one
      // transition: the bottom rows the covered page has vacated, and the
      // square the arriving page occupies.
      mount(
        routes: const <String, WidgetBuilder>{},
        onGenerateRoute: (RouteSettings settings) => PageRouteBuilder<void>(
          settings: settings,
          transitionDuration: _transition,
          pageBuilder: (
            BuildContext context,
            Animation<double> animation,
            Animation<double> secondaryAnimation,
          ) =>
              const ColoredBox(color: _homeColor),
          transitionBuilder: (
            BuildContext context,
            Animation<double> animation,
            Animation<double> secondaryAnimation,
            Widget child,
          ) =>
              Transform.translate(
            offset: Offset(0, -8.0 * secondaryAnimation.value),
            child: child,
          ),
        ),
      );

      nav.push<void>(
        PageRouteBuilder<void>(
          opaque: false,
          transitionDuration: _transition,
          pageBuilder: (
            BuildContext context,
            Animation<double> animation,
            Animation<double> secondaryAnimation,
          ) =>
              const Center(
            child: SizedBox(
              width: 4,
              height: 4,
              child: ColoredBox(color: _dialogColor),
            ),
          ),
        ),
      );
      pump(5);

      final Framebuffer buffer = await pixels();
      expect(pixelAt(buffer, 1, 1), _homePixel, reason: 'still covered here');
      expect(
        pixelAt(buffer, 1, 14),
        _backgroundPixel,
        reason: 'the covered page moved up by exactly half of eight pixels '
            'while the route above it was halfway in',
      );
      expect(pixelAt(buffer, 8, 8), _dialogPixel);
    });

    test('a sliding route carries its hit region with it', () {
      mount();
      int taps = 0;
      nav.push<void>(
        SlidePageRoute<void>(
          transitionDuration: _transition,
          travel: 8,
          curve: Curves.linear,
          builder: (BuildContext context) =>
              _Tappable(onTap: () => taps++, color: _detailColor),
        ),
      );
      pump(5);

      _tap(owner, const Offset(1, 8));
      expect(
        taps,
        0,
        reason: 'the arriving page is still four pixels to the right of where '
            'it will settle, and it is not hit where it is not drawn',
      );

      _tap(owner, const Offset(10, 8));
      expect(taps, 1);

      settle();
      _tap(owner, const Offset(1, 8));
      expect(taps, 2, reason: 'and it fills the window once it has arrived');
    });

    test('a route only stops covering when its exit animation ends', () async {
      mount();
      final FadePageRoute<void> detail = _page(_detailColor);
      nav.push<void>(detail);
      settle();

      nav.pop();
      pump(4);

      expect(nav.depth, 1, reason: 'the history changed immediately');
      expect(nav.poppingRoutes, <Route<Object?>>[detail]);
      expect(detail.isDisposed, isFalse);
      expect(drawnRectangles(), 2, reason: 'the leaving page is still drawn');
      expect(nav.overlay!.length, 2);

      settle();
      expect(detail.isDisposed, isTrue);
      expect(nav.overlay!.length, 1);
      expect(pixelAt(await pixels(), 8, 8), _homePixel);
    });

    test('a translucent route leaves the page below visible and unclickable',
        () async {
      mount();
      int homeTaps = 0;
      // The home route is replaced by one with a tap counter so the barrier
      // can be observed rather than inferred.
      nav.pushReplacement<void>(
        _page(
          _homeColor,
          child: _Tappable(onTap: () => homeTaps++, color: _homeColor),
        ),
      );
      settle();

      nav.push<void>(
        _page(
          _dialogColor,
          opaque: false,
          child: const Center(
            child: SizedBox(
              width: 4,
              height: 4,
              child: ColoredBox(color: _dialogColor),
            ),
          ),
        ),
      );
      settle();

      final Framebuffer buffer = await pixels();
      expect(pixelAt(buffer, 8, 8), _dialogPixel);
      expect(pixelAt(buffer, 1, 1), _homePixel,
          reason: 'not opaque, so the '
              'page below still paints');

      _tap(owner, const Offset(1, 1));
      expect(
        homeTaps,
        0,
        reason: 'a route that is not current takes no pointers, which is what '
            'makes a translucent route modal',
      );

      nav.pop();
      settle();
      _tap(owner, const Offset(1, 1));
      expect(homeTaps, 1);
    });
  });

  group('popping while pushing', () {
    test('a pop in the middle of a push discards exactly the pushed route',
        () async {
      mount();
      final Route<Object?> home = nav.currentRoute!;
      final _CountingRoute detail = _CountingRoute(color: _detailColor);
      final int tickersBefore = clock.tickerCount;

      nav.push<void>(detail);
      pump(2);
      expect(detail.animation.value, 0.2);

      // The double tap: back pressed before the new screen even arrived.
      expect(nav.pop(), isTrue);
      expect(nav.currentRoute, same(home));
      expect(detail.animation.status, AnimationStatus.reverse);

      settle();

      expect(detail.disposeCount, 1, reason: 'disposed once, not twice');
      expect(home.isDisposed, isFalse, reason: 'and not the route below');
      expect(nav.depth, 1);
      expect(nav.poppingRoutes, isEmpty);
      expect(nav.overlay!.length, 1, reason: 'no orphaned overlay entry');
      expect(
        clock.tickerCount,
        tickersBefore,
        reason: 'a discarded route releases its AnimationController',
      );
      expect(home.secondaryAnimation.value, 0.0);
      expect(pixelAt(await pixels(), 8, 8), _homePixel);
    });

    test(
        'a second pop during the exit animation pops the route below, not '
        'the one already leaving', () {
      mount();
      final FadePageRoute<void> first = _page(_detailColor);
      final FadePageRoute<void> second = _page(_dialogColor);
      nav.push<void>(first);
      settle();
      nav.push<void>(second);
      pump(3);

      expect(nav.pop(), isTrue, reason: 'pops `second`');
      expect(nav.pop(), isTrue, reason: 'pops `first`, which is now current');
      expect(nav.depth, 1);
      expect(nav.poppingRoutes.length, 2);

      settle();
      expect(first.isDisposed, isTrue);
      expect(second.isDisposed, isTrue);
      expect(nav.overlay!.length, 1);
      expect(clock.tickerCount, 1, reason: 'only the root route still ticks');
    });

    test('disposing the navigator releases every route it still owns', () {
      mount();
      nav.push<void>(_page(_detailColor));
      settle();
      final _CountingRoute leaving = _CountingRoute(color: _dialogColor);
      nav.push<void>(leaving);
      pump(3);
      nav.pop();
      expect(clock.tickerCount, 3);

      owner.dispose();

      expect(leaving.disposeCount, 1);
      expect(clock.tickerCount, 0, reason: 'nothing is left asking for frames');
    });
  });

  group('popUntil', () {
    test('a predicate that never matches stops at the root', () {
      mount();
      nav.push<void>(_page(_detailColor,
          settings: const RouteSettings(
            name: '/a',
          )));
      settle();
      nav.push<void>(_page(_dialogColor,
          settings: const RouteSettings(
            name: '/b',
          )));
      settle();
      expect(nav.depth, 3);

      nav.popUntil(Navigator.withName('/nowhere'));

      expect(nav.depth, 1, reason: 'stopped at the root instead of emptying');
      expect(nav.currentRoute!.settings.name, '/');
      settle();
      expect(nav.overlay!.length, 1);
    });

    test('popUntil stops at the named route it was given', () {
      mount();
      nav.push<void>(_page(_detailColor,
          settings: const RouteSettings(
            name: '/a',
          )));
      settle();
      nav.push<void>(_page(_dialogColor,
          settings: const RouteSettings(
            name: '/b',
          )));
      settle();

      nav.popUntil(Navigator.withName('/a'));

      expect(nav.depth, 2);
      expect(nav.currentRoute!.settings.name, '/a');
    });
  });

  group('PopScope', () {
    test('a dirty form refuses the pop and hears about the attempt', () {
      final GlobalKey<_FormState> formKey = GlobalKey<_FormState>();
      final List<bool> invocations = <bool>[];
      mount();
      nav.push<void>(
        _page(
          _detailColor,
          child: _Form(key: formKey, log: invocations),
        ),
      );
      settle();

      expect(nav.maybePop(), isFalse);
      expect(nav.depth, 2, reason: 'the guard held');
      expect(invocations, <bool>[false]);

      // The user saved, so the guard opens.
      formKey.currentState!.setDirty(false);
      pump();

      expect(nav.maybePop(), isTrue);
      expect(invocations, <bool>[false, true]);
      settle();
      expect(nav.depth, 1);
    });

    test('pop bypasses the guard, because pop is the confirmation', () {
      final GlobalKey<_FormState> formKey = GlobalKey<_FormState>();
      mount();
      nav.push<void>(
        _page(_detailColor, child: _Form(key: formKey, log: <bool>[])),
      );
      settle();

      expect(nav.pop(), isTrue);
      settle();
      expect(nav.depth, 1);
    });

    test('a guard on the root route is still consulted', () {
      final GlobalKey<_FormState> formKey = GlobalKey<_FormState>();
      final List<bool> invocations = <bool>[];
      mount(
        routes: <String, WidgetBuilder>{
          '/': (BuildContext context) => _Form(key: formKey, log: invocations),
        },
      );

      expect(nav.maybePop(), isFalse);
      expect(invocations, <bool>[false],
          reason: 'a form wants to know about an attempt to leave even when '
              'there is nothing behind it');
    });
  });

  group('going back from the keyboard', () {
    test('Escape pops the route that has focus', () {
      mount();
      nav.push<void>(_page(_detailColor));
      settle();

      expect(owner.dispatchKeyEvent(_key(logicalKeyEscape)), isTrue);
      settle();
      expect(nav.depth, 1);
    });

    test('Alt+Left pops as well, and a bare Left does not', () {
      mount();
      nav.push<void>(_page(_detailColor));
      settle();

      expect(owner.dispatchKeyEvent(_key(logicalKeyArrowLeft)), isFalse);
      expect(nav.depth, 2);

      expect(
        owner.dispatchKeyEvent(
          _key(logicalKeyArrowLeft, modifiers: <KeyModifier>{KeyModifier.alt}),
        ),
        isTrue,
      );
      settle();
      expect(nav.depth, 1);
    });

    test('Escape still pops when a control inside the route holds focus', () {
      final FocusNode field = FocusNode(debugLabel: 'field');
      addTearDown(field.dispose);
      mount();
      nav.push<void>(_page(_detailColor, focusNode: field));
      settle();
      field.requestFocus();
      expect(owner.focusManager.primaryFocus, same(field));

      // Nothing consumed the key on the focus route, so the shortcut map the
      // navigator installed is what catches it.
      expect(owner.dispatchKeyEvent(_key(logicalKeyEscape)), isTrue);
      settle();
      expect(nav.depth, 1);
    });

    test('a navigator that was told not to claim the shortcut map does not',
        () {
      final FocusNode field = FocusNode(debugLabel: 'field');
      addTearDown(field.dispose);
      mount(installBackShortcuts: false);
      nav.push<void>(_page(_detailColor, focusNode: field));
      settle();
      field.requestFocus();

      expect(owner.shortcuts, isNull);
      expect(owner.dispatchKeyEvent(_key(logicalKeyEscape)), isFalse);
      expect(nav.depth, 2);
    });
  });

  group('focus', () {
    test('pushing moves focus into the new route and popping gives it back',
        () {
      final FocusNode field = FocusNode(debugLabel: 'home field');
      addTearDown(field.dispose);
      mount(
        routes: <String, WidgetBuilder>{
          '/': (BuildContext context) => FocusAttachment(
                node: field,
                child: const ColoredBox(color: _homeColor),
              ),
        },
      );
      final Route<Object?> home = nav.currentRoute!;
      expect(owner.focusManager.primaryFocus, same(home.focusNode),
          reason: 'the route itself holds focus until something in it does');

      field.requestFocus();
      expect(owner.focusManager.primaryFocus, same(field));

      final FadePageRoute<void> detail = _page(_detailColor);
      nav.push<void>(detail);
      settle();

      expect(owner.focusManager.primaryFocus, same(detail.focusNode));
      expect(
        owner.focusManager.traversalRing(),
        isNot(contains(field)),
        reason: 'Tab cannot walk into the screen behind the one on top',
      );

      nav.pop();
      settle();

      expect(
        owner.focusManager.primaryFocus,
        same(field),
        reason: 'the exact control that had focus before the push',
      );
      expect(owner.focusManager.traversalRing(), contains(field));
    });

    test('focus falls back to the route when the control is gone', () {
      final FocusNode field = FocusNode(debugLabel: 'home field');
      addTearDown(field.dispose);
      // The *root* route is the one that declines to be maintained, so being
      // covered tears its page down and takes the node with it.
      mount(
        routes: const <String, WidgetBuilder>{},
        onGenerateRoute: (RouteSettings settings) => _page<void>(
          _homeColor,
          settings: settings,
          maintainState: false,
          focusNode: field,
        ),
      );
      final Route<Object?> home = nav.currentRoute!;
      field.requestFocus();
      expect(owner.focusManager.primaryFocus, same(field));

      nav.push<void>(_page(_detailColor));
      settle();
      expect(field.parent, isNull, reason: 'the page below was torn down');

      nav.pop();
      settle();

      expect(
        owner.focusManager.primaryFocus,
        same(home.focusNode),
        reason: 'the exact node is gone, so the route itself takes focus '
            'rather than nothing having it',
      );
    });
  });

  group('lookup', () {
    test('Navigator.of finds the navigator from inside a page', () {
      NavigatorState? found;
      mount(
        routes: <String, WidgetBuilder>{
          '/': (BuildContext context) {
            found = Navigator.of(context);
            return const ColoredBox(color: _homeColor);
          },
        },
      );

      expect(found, same(nav));
    });

    test('Route.of finds the enclosing route', () {
      Route<Object?>? found;
      mount(
        routes: <String, WidgetBuilder>{
          '/': (BuildContext context) {
            found = Route.of(context);
            return const ColoredBox(color: _homeColor);
          },
        },
      );

      expect(found, same(nav.currentRoute));
    });

    test('a widget with no navigator above it gets a named failure', () {
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(8, 8)),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline);
      addTearDown(owner.dispose);

      expect(
        () => owner.updateRoot(
          _Probe(onBuild: (BuildContext context) => Navigator.of(context)),
        ),
        throwsStateError,
      );
    });
  });
}

/// A page route painting one colour, with the hooks the tests need.
FadePageRoute<T> _page<T extends Object?>(
  Color color, {
  RouteSettings settings = const RouteSettings(),
  Widget? child,
  FocusNode? focusNode,
  bool opaque = true,
  bool maintainState = true,
}) =>
    FadePageRoute<T>(
      settings: settings,
      transitionDuration: _transition,
      opaque: opaque,
      maintainState: maintainState,
      // Linear so a test can name the exact opacity at a given frame.
      curve: Curves.linear,
      builder: (BuildContext context) {
        final Widget content = child ?? ColoredBox(color: color);
        return focusNode == null
            ? content
            : FocusAttachment(node: focusNode, child: content);
      },
    );

/// A route that counts its own disposals, which is the only way to tell
/// "disposed once" from "disposed twice" from outside.
final class _CountingRoute extends PageRoute<void> {
  _CountingRoute({required this.color})
      : super(transitionDuration: _transition);

  final Color color;
  int disposeCount = 0;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) =>
      ColoredBox(color: color);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) =>
      Opacity(opacity: animation.value.clamp(0.0, 1.0), child: child);

  @override
  void dispose() {
    disposeCount++;
    super.dispose();
  }
}

/// A page with unsaved work in it.
final class _Form extends StatefulWidget {
  const _Form({required super.key, required this.log});

  final List<bool> log;

  @override
  State<_Form> createState() => _FormState();
}

final class _FormState extends State<_Form> {
  bool _dirty = true;

  void setDirty(bool value) => setState(() => _dirty = value);

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_dirty,
        onPopInvoked: widget.log.add,
        child: const ColoredBox(color: _detailColor),
      );
}

final class _Tappable extends StatelessWidget {
  const _Tappable({required this.onTap, required this.color});

  final void Function() onTap;
  final Color color;

  @override
  Widget build(BuildContext context) =>
      GestureDetector(onTap: onTap, child: ColoredBox(color: color));
}

final class _Probe extends StatelessWidget {
  const _Probe({required this.onBuild});

  final void Function(BuildContext context) onBuild;

  @override
  Widget build(BuildContext context) {
    onBuild(context);
    return const ColoredBox(color: _background);
  }
}

KeyDownEvent _key(
  int logicalKey, {
  Set<KeyModifier> modifiers = const <KeyModifier>{},
}) =>
    KeyDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      physicalKey: logicalKey,
      logicalKey: logicalKey,
      modifiers: modifiers,
    );

void _tap(BuildOwner owner, Offset position) {
  owner.dispatchPointerEvent(
    PointerDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: position,
      button: PointerButton.primary,
    ),
  );
  owner.dispatchPointerEvent(
    PointerUpEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: position,
      button: PointerButton.primary,
    ),
  );
}
