/// Many windows in one application, exercised end to end on the headless
/// backend.
///
/// Every test drives the *production* shell: the same `Application` a Win32
/// gallery runs, the same `WindowHost`, the same per-window `BuildOwner` and
/// `PipelineOwner`. There is no mock window and no multi-window branch in
/// `application.dart` that only tests take.
///
/// Three rules the suite holds itself to:
///
///   * **No wall clock.** Nothing calls `DateTime.now`; every timestamp is
///     `Duration.zero` and the headless pump is deterministic by construction.
///   * **Concrete values.** A test that only proved "it did not throw" would
///     pass against a shell that routed every event to the first window. So
///     the assertions are on pixel bytes, on counted `performLayout` calls, on
///     which controller received the text, and on the exact teardown order.
///   * **The invariant, not an example of it.** "Only one window has the
///     keyboard" is asserted over *every* window on every move, not on the one
///     that was expected to change.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

const int _colourA = 0xFF204080;
const int _colourB = 0xFF80C020;
const int _colourC = 0xFFC02040;

void main() {
  group('two windows, two trees', () {
    test('each presents its own pixels into its own surface', () async {
      final app = await _start(size: const Size(6, 4), colour: _colourA);
      final a = app.primaryWindow;
      final b = await app.openWindow(
        rootWidget: const _CountingBox(colour: _colourB),
        size: const Size(10, 3),
      );

      await a.drawFrame();
      await b.drawFrame();

      final pixelsA = _framebufferOf(a);
      final pixelsB = _framebufferOf(b);
      expect(pixelsA.width, 6);
      expect(pixelsA.height, 4);
      expect(pixelsB.width, 10);
      expect(pixelsB.height, 3);
      // Different bytes, not merely different objects: the whole claim of a
      // second window is that its own tree reached its own surface.
      expect(_pixelAt(pixelsA, 0, 0), _colourA);
      expect(_pixelAt(pixelsA, 5, 3), _colourA);
      expect(_pixelAt(pixelsB, 0, 0), _colourB);
      expect(_pixelAt(pixelsB, 9, 2), _colourB);
      expect(
        HeadlessScreenshot.fromFramebuffer(pixelsA).checksum,
        isNot(HeadlessScreenshot.fromFramebuffer(pixelsB).checksum),
      );

      expect(a.framesPresented, 1);
      expect(b.framesPresented, 1);
      expect(app.framesPresented, 2);
      expect(app.framesRejected, 0);

      await _stop(app);
    });

    test('the owners are separate objects, not one shared by two roots',
        () async {
      final app = await _start(size: const Size(4, 4), colour: _colourA);
      final a = app.primaryWindow;
      final b = await app.openWindow(
        rootWidget: const _CountingBox(colour: _colourB),
        size: const Size(4, 4),
      );

      expect(identical(a.buildOwner, b.buildOwner), isFalse);
      expect(identical(a.pipelineOwner, b.pipelineOwner), isFalse);
      expect(identical(a.scheduler, b.scheduler), isFalse);
      expect(identical(a.host, b.host), isFalse);
      // And the focus managers, which is the reason `element.dart` says focus
      // is per owner in the first place.
      expect(
        identical(a.buildOwner.focusManager, b.buildOwner.focusManager),
        isFalse,
      );

      await _stop(app);
    });

    test('one window marking itself dirty never lays the other out', () async {
      final counterA = _LayoutCounter();
      final counterB = _LayoutCounter();
      final app = await _start(
        size: const Size(8, 8),
        colour: _colourA,
        counter: counterA,
      );
      final a = app.primaryWindow;
      final b = await app.openWindow(
        rootWidget: _CountingBox(colour: _colourB, counter: counterB),
        size: const Size(8, 8),
      );

      await a.drawFrame();
      await b.drawFrame();
      final layoutsB = counterB.layouts;
      final layoutsA = counterA.layouts;
      expect(layoutsA, greaterThan(0));
      expect(layoutsB, greaterThan(0));

      // A structural change in A: a new child, so its subtree must relayout.
      a.updateRoot(_CountingBox(
        colour: _colourA,
        counter: counterA,
        child: const SizedBox(width: 3, height: 3),
      ));

      // Before a single frame is drawn, B must already be untouched: its dirty
      // list is a different list, and nothing put anything in it.
      expect(b.needsFrame, isFalse,
          reason: 'A asking for a frame must not ask for B');
      expect(b.pipelineOwner.needsLayout, isFalse);
      expect(b.buildOwner.hasScheduledBuilds, isFalse);
      expect(a.needsFrame, isTrue);

      await a.drawFrame();

      expect(counterA.layouts, greaterThan(layoutsA));
      expect(counterB.layouts, layoutsB,
          reason: 'B ran no layout at all for a frame that was not its own');
      expect(b.framesPresented, 1);

      await _stop(app);
    });
  });

  group('event routing by windowId', () {
    test('a click tagged A reaches A and never B', () async {
      final pressedA = <String>[];
      final pressedB = <String>[];
      final app = await _start(
        size: const Size(120, 40),
        root: _ButtonTree(label: 'A', onPressed: pressedA.add),
      );
      final a = app.primaryWindow;
      final b = await app.openWindow(
        rootWidget: _ButtonTree(label: 'B', onPressed: pressedB.add),
        size: const Size(120, 40),
      );
      await a.drawFrame();
      await b.drawFrame();

      _click(a, const Offset(30, 15));
      app.backend.pumpEvents();
      expect(pressedA, <String>['A']);
      expect(pressedB, isEmpty);

      _click(b, const Offset(30, 15));
      app.backend.pumpEvents();
      expect(pressedA, <String>['A']);
      expect(pressedB, <String>['B']);

      // The proof that routing is by id and not by subscription: an event
      // carrying B's id, handed to the application directly, still lands in B.
      app.handleEvent(_down(b, const Offset(30, 15)));
      app.handleEvent(_up(b, const Offset(30, 15)));
      expect(pressedA, hasLength(1));
      expect(pressedB, hasLength(2));

      await _stop(app);
    });

    test('an event naming a closed window is dropped, not thrown', () async {
      final app = await _start(size: const Size(8, 8), colour: _colourA);
      final a = app.primaryWindow;
      final b = await app.openWindow(
        rootWidget: const _CountingBox(colour: _colourB),
        size: const Size(8, 8),
      );
      await a.drawFrame();
      await b.drawFrame();

      final closedId = b.id;
      final closedGeneration = b.nativeWindow.generation;
      app.closeWindow(closedId);
      final droppedBefore = app.eventsDropped;

      // Native code goes on delivering callbacks for windows that have already
      // closed - `lifecycle.dart` opens with that sentence - so every one of
      // these is the normal case and every one must be silent.
      expect(
        () => app.handleEvent(WindowExposedEvent(
          windowId: closedId,
          generation: closedGeneration,
        )),
        returnsNormally,
      );
      expect(
        () => app.handleEvent(WindowResizedEvent(
          windowId: closedId,
          generation: closedGeneration,
          clientSize: const Size(99, 99),
          renderScale: 1,
        )),
        returnsNormally,
      );
      expect(
        () => app.handleEvent(PointerDownEvent(
          windowId: closedId,
          generation: closedGeneration,
          timestamp: Duration.zero,
          pointerId: 0,
          kind: PointerKind.mouse,
          logicalPosition: const Offset(1, 1),
          button: PointerButton.primary,
        )),
        returnsNormally,
      );
      expect(
        () => app.handleEvent(WindowClosedEvent(
          windowId: closedId,
          generation: closedGeneration,
        )),
        returnsNormally,
      );

      // Dropped in *declared* silence: the count is the difference between
      // "discarded on purpose" and "never routed anywhere", which are
      // indistinguishable without it.
      expect(app.eventsDropped - droppedBefore, 4);
      expect(app.windows, hasLength(1));
      expect(a.isDisposed, isFalse);

      await _stop(app);
    });

    test('an input event from a superseded generation is dropped', () async {
      final pressed = <String>[];
      final app = await _start(
        size: const Size(120, 40),
        root: _ButtonTree(label: 'A', onPressed: pressed.add),
      );
      final a = app.primaryWindow;
      await a.drawFrame();

      final stale = a.nativeWindow.generation - 1;
      final droppedBefore = app.eventsDropped;
      app.handleEvent(PointerDownEvent(
        windowId: a.id,
        generation: stale,
        timestamp: Duration.zero,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: const Offset(30, 15),
        button: PointerButton.primary,
      ));

      expect(pressed, isEmpty);
      expect(app.eventsDropped - droppedBefore, 1);

      await _stop(app);
    });
  });

  group('keyboard focus is exclusive', () {
    test('exactly one window ever reports itself active', () async {
      final app = await _start(size: const Size(8, 8), colour: _colourA);
      final a = app.primaryWindow;
      final b = await app.openWindow(
        rootWidget: const _CountingBox(colour: _colourB),
        size: const Size(8, 8),
      );
      final c = await app.openWindow(
        rootWidget: const _CountingBox(colour: _colourC),
        size: const Size(8, 8),
      );

      for (final ApplicationWindow focused in <ApplicationWindow>[a, b, c, a]) {
        app.focusWindow(focused.id);
        expect(app.keyboardFocusWindow, focused.id);
        expect(_activeWindows(app), <NativeWindowId>[focused.id],
            reason: 'exactly one window may report isWindowActive');
        expect(focused.hasKeyboardFocus, isTrue);
      }

      await _stop(app);
    });

    test('typing reaches only the window that holds the keyboard', () async {
      final controllerA = TextEditingController('a');
      final controllerB = TextEditingController('b');
      final app = await _start(
        size: const Size(140, 40),
        root: _FieldTree(controller: controllerA),
      );
      final a = app.primaryWindow;
      final b = await app.openWindow(
        rootWidget: _FieldTree(controller: controllerB),
        size: const Size(140, 40),
      );
      await a.drawFrame();
      await b.drawFrame();

      // Give each field the focus *inside* its own window, so the only thing
      // left to decide is which window the keyboard belongs to.
      _click(a, const Offset(40, 12));
      _click(b, const Offset(40, 12));
      app.backend.pumpEvents();
      await a.drawFrame();
      await b.drawFrame();

      app.focusWindow(a.id);
      final droppedBefore = app.eventsDropped;
      expect(app.handleEvent(_text(a, 'X')), isTrue);
      expect(controllerA.value, contains('X'));
      expect(controllerB.value, isNot(contains('X')));

      // The same keystroke aimed at the window that does *not* have the
      // keyboard is refused rather than delivered.
      expect(app.handleEvent(_text(b, 'Y')), isFalse);
      expect(controllerB.value, isNot(contains('Y')));
      expect(app.eventsDropped - droppedBefore, 1);

      // And it is a move, not a preference: focus B and the two swap.
      app.focusWindow(b.id);
      expect(app.handleEvent(_text(b, 'Z')), isTrue);
      expect(controllerB.value, contains('Z'));
      expect(app.handleEvent(_text(a, 'W')), isFalse);
      expect(controllerA.value, isNot(contains('W')));

      await _stop(app);
    });

    test('a window that loses activation is told, and keeps its assignment',
        () async {
      final controller = TextEditingController('hello');
      final app = await _start(
        size: const Size(140, 40),
        root: _FieldTree(controller: controller),
      );
      final a = app.primaryWindow;
      await a.drawFrame();
      _click(a, const Offset(40, 12));
      app.backend.pumpEvents();
      await a.drawFrame();

      final focused = a.buildOwner.focusedTarget;
      expect(focused, isNotNull, reason: 'the click focused the field');
      expect(a.buildOwner.focusManager.isWindowActive, isTrue);

      app.handleEvent(WindowActivationEvent(
        windowId: a.id,
        generation: a.nativeWindow.generation,
        activation: WindowActivation.deactivated,
      ));

      // The third state the whole section is about: the window is inactive and
      // the field is *still* its focus. Losing the window must not lose the
      // assignment, or coming back would land on the first control instead of
      // the one in use.
      expect(a.buildOwner.focusManager.isWindowActive, isFalse);
      expect(a.buildOwner.focusedTarget, same(focused));
      expect(a.isActive, isFalse);
      expect(app.keyboardFocusWindow, isNull);

      app.handleEvent(WindowActivationEvent(
        windowId: a.id,
        generation: a.nativeWindow.generation,
        activation: WindowActivation.activated,
      ));
      expect(a.buildOwner.focusManager.isWindowActive, isTrue);
      expect(app.keyboardFocusWindow, a.id);

      await _stop(app);
    });

    test('the backend deactivates the previous holder, and the shell follows',
        () async {
      final app = await _start(size: const Size(8, 8), colour: _colourA);
      final a = app.primaryWindow;
      final b = await app.openWindow(
        rootWidget: const _CountingBox(colour: _colourB),
        size: const Size(8, 8),
        visible: false,
      );

      // Showing B is what a real window manager turns into a deactivation of A
      // followed by an activation of B, and the headless backend models it.
      b.nativeWindow.show();
      app.backend.pumpEvents();

      expect(a.isActive, isFalse);
      expect(b.isActive, isTrue);
      expect(_activeWindows(app), <NativeWindowId>[b.id]);
      expect(app.keyboardFocusWindow, b.id);

      await _stop(app);
    });
  });

  group('closing one window', () {
    test('releases in reverse order, is idempotent, and leaves the other alive',
        () async {
      final app = await _start(size: const Size(8, 8), colour: _colourA);
      final a = app.primaryWindow;
      final b = await app.openWindow(
        rootWidget: const _CountingBox(colour: _colourB),
        size: const Size(8, 8),
      );
      await a.drawFrame();
      await b.drawFrame();
      expect(app.teardownOrder, isEmpty);

      final bHost = b.host;
      final bPresenter = b.host.presenter;
      final bNative = b.nativeWindow;

      expect(app.closeWindow(b.id), isTrue);

      // Acquisition was window, host, scheduler, buildOwner, events; release is
      // that list backwards. Any adjacent swap is a use-after-free on a real
      // backend.
      expect(app.teardownOrder, <String>[
        'events',
        'buildOwner',
        'scheduler',
        'host',
        'window',
      ]);
      expect(b.isDisposed, isTrue);
      expect(bHost.isDisposed, isTrue);
      expect(bPresenter.isDisposed, isTrue);
      expect(bNative.isDisposed, isTrue);

      // Idempotent: a second close releases nothing and says so.
      expect(app.closeWindow(b.id), isFalse);
      expect(app.teardownOrder, hasLength(5));
      expect(() => app.closeWindow(b.id), returnsNormally);

      // And A is untouched: still open, still presenting, still counting.
      expect(app.windows, <ApplicationWindow>[a]);
      expect(app.state, ApplicationLifecycleState.running);
      final before = a.framesPresented;
      a.requestFrame();
      final result = await a.drawFrame();
      expect(result.isSuccess, isTrue, reason: result.diagnostic?.toString());
      expect(a.framesPresented, before + 1);
      expect(_pixelAt(_framebufferOf(a), 0, 0), _colourA);
      // The closed window's frames stay in the application's total; the run
      // presented them.
      expect(app.framesPresented, before + 1 + 1);

      await _stop(app);
    });

    test('closing the primary promotes the next window', () async {
      final app = await _start(size: const Size(8, 8), colour: _colourA);
      final a = app.primaryWindow;
      final b = await app.openWindow(
        rootWidget: const _CountingBox(colour: _colourB),
        size: const Size(8, 8),
      );

      app.closeWindow(a.id);

      expect(app.primaryWindow, same(b));
      expect(app.window, same(b.nativeWindow));
      expect(app.buildOwner, same(b.buildOwner));
      expect(app.keyboardFocusWindow, b.id);

      await _stop(app);
    });
  });

  group('the last window', () {
    test('by default, closing it closes the application', () async {
      final app = await _start(size: const Size(8, 8), colour: _colourA);
      final a = app.primaryWindow;
      await a.drawFrame();

      expect(app.options.exitWhenLastWindowClosed, isTrue);
      app.closeWindow(a.id);

      expect(app.windows, isEmpty);
      expect(app.state, ApplicationLifecycleState.closing);
      // No window means no frame, and asking for one says so rather than
      // throwing: a timer that fires after the last window closed is normal.
      final result = await app.drawFrame();
      expect(result.status, PresentStatus.stale);
      expect(result.diagnostic!.message, contains('no open windows'));

      app.dispose();
      await app.closed;
      expect(app.state, ApplicationLifecycleState.closed);
    });

    test('a close *request* for the last window defers teardown to dispose',
        () async {
      final app = await _start(size: const Size(8, 8), colour: _colourA);
      final a = app.primaryWindow;
      await a.drawFrame();

      // The frame in flight is what makes the deferral necessary: it must be
      // rejected, not drawn into a surface teardown is about to free.
      final inFlight = a.host.beginFrame();
      app.handleEvent(WindowCloseRequestedEvent(
        windowId: a.id,
        generation: a.nativeWindow.generation,
      ));

      expect(app.state, ApplicationLifecycleState.closing);
      expect(a.isDisposed, isFalse, reason: 'dispose() owns the release');
      final rejected = await a.host.present(inFlight, DisplayList());
      expect(rejected.status, PresentStatus.stale);
      expect(app.framesRejected, 1);

      await _stop(app);
    });

    test('with exitWhenLastWindowClosed false the application survives',
        () async {
      final app = await _start(
        size: const Size(8, 8),
        colour: _colourA,
        exitWhenLastWindowClosed: false,
      );
      final a = app.primaryWindow;
      await a.drawFrame();

      app.closeWindow(a.id);

      expect(app.windows, isEmpty);
      expect(app.state, ApplicationLifecycleState.running,
          reason: 'a tray application outlives its windows');
      expect(app.isDisposed, isFalse);

      // And it can open one again, which is the whole point of the policy.
      final revived = await app.openWindow(
        rootWidget: const _CountingBox(colour: _colourC),
        size: const Size(5, 5),
      );
      await revived.drawFrame();
      expect(_pixelAt(_framebufferOf(revived), 0, 0), _colourC);
      expect(app.windows, hasLength(1));

      await _stop(app);
    });

    test('a dismissed popup is not the last window closing', () async {
      final app = await _start(size: const Size(20, 20), colour: _colourA);
      final a = app.primaryWindow;
      await a.drawFrame();
      final menu = await app.openWindow(
        rootWidget: const _CountingBox(colour: _colourC),
        size: const Size(10, 8),
        owner: a.id,
        kind: WindowKind.popup,
      );

      // A menu never takes the keyboard, or every caret in the window behind
      // it would stop blinking while the user read it.
      expect(app.keyboardFocusWindow, a.id);
      expect(menu.kind, WindowKind.popup);
      expect(app.topLevelWindows, <ApplicationWindow>[a]);

      // Closing the *menu* while it is the newest window must not be read as
      // "the application ran out of windows".
      app.handleEvent(WindowCloseRequestedEvent(
        windowId: menu.id,
        generation: menu.nativeWindow.generation,
      ));

      expect(menu.isDisposed, isTrue);
      expect(app.state, ApplicationLifecycleState.running);
      expect(app.windows, <ApplicationWindow>[a]);

      await _stop(app);
    });

    test('moving focus away dismisses a popup', () async {
      final app = await _start(size: const Size(20, 20), colour: _colourA);
      final a = app.primaryWindow;
      final b = await app.openWindow(
        rootWidget: const _CountingBox(colour: _colourB),
        size: const Size(20, 20),
      );
      final menu = await app.openWindow(
        rootWidget: const _CountingBox(colour: _colourC),
        size: const Size(8, 8),
        owner: a.id,
        kind: WindowKind.popup,
      );
      expect(menu.isDisposed, isFalse);

      app.focusWindow(b.id);

      expect(menu.isDisposed, isTrue,
          reason: 'a menu closes when focus leaves');
      expect(app.windows, hasLength(2));
      expect(app.keyboardFocusWindow, b.id);

      await _stop(app);
    });

    test('a popup requires an owner', () async {
      final app = await _start(size: const Size(8, 8), colour: _colourA);
      await expectLater(
        () => app.openWindow(
          rootWidget: const _CountingBox(colour: _colourC),
          kind: WindowKind.popup,
        ),
        throwsA(isA<ArgumentError>()),
      );
      await _stop(app);
    });
  });

  group('modal windows', () {
    test('a modal blocks its owner and hands focus back when it closes',
        () async {
      final pressed = <String>[];
      final app = await _start(
        size: const Size(120, 40),
        root: _ButtonTree(label: 'owner', onPressed: pressed.add),
      );
      final owner = app.primaryWindow;
      await owner.drawFrame();

      final dialog = await app.openWindow(
        rootWidget: const _CountingBox(colour: _colourC),
        size: const Size(60, 30),
        owner: owner.id,
        modal: true,
      );

      expect(owner.isBlocked, isTrue);
      expect(owner.activeModal, same(dialog));
      expect(app.keyboardFocusWindow, dialog.id);
      expect(owner.buildOwner.focusManager.isWindowActive, isFalse);
      // The platform half: the backend was told to refuse input too.
      expect((owner.nativeWindow as EnableableWindow).isEnabled, isFalse);

      // The application half: even an event that reached us anyway is refused.
      final droppedBefore = app.eventsDropped;
      app.handleEvent(_down(owner, const Offset(30, 15)));
      app.handleEvent(_up(owner, const Offset(30, 15)));
      expect(pressed, isEmpty, reason: 'a blocked window takes no input');
      expect(app.eventsDropped - droppedBefore, 2);

      // Clicking the blocked window flashes the dialog rather than closing it.
      app.handleEvent(WindowCloseRequestedEvent(
        windowId: owner.id,
        generation: owner.nativeWindow.generation,
      ));
      expect(owner.isDisposed, isFalse);
      expect(app.keyboardFocusWindow, dialog.id);

      app.closeWindow(dialog.id);

      expect(owner.isBlocked, isFalse);
      expect((owner.nativeWindow as EnableableWindow).isEnabled, isTrue);
      expect(app.keyboardFocusWindow, owner.id,
          reason: 'closing a dialog puts the keyboard back where it was');
      expect(owner.buildOwner.focusManager.isWindowActive, isTrue);

      app.handleEvent(_down(owner, const Offset(30, 15)));
      app.handleEvent(_up(owner, const Offset(30, 15)));
      expect(pressed, <String>['owner']);

      await _stop(app);
    });

    test('closing an owner closes the windows it owns', () async {
      final app = await _start(size: const Size(20, 20), colour: _colourA);
      final owner = app.primaryWindow;
      await owner.drawFrame();
      final second = await app.openWindow(
        rootWidget: const _CountingBox(colour: _colourB),
        size: const Size(20, 20),
      );
      final dialog = await app.openWindow(
        rootWidget: const _CountingBox(colour: _colourC),
        size: const Size(10, 10),
        owner: owner.id,
        modal: true,
      );

      app.closeWindow(owner.id);

      expect(dialog.isDisposed, isTrue, reason: 'an owned window dies with it');
      expect(owner.isDisposed, isTrue);
      expect(second.isDisposed, isFalse);
      expect(app.windows, <ApplicationWindow>[second]);
      expect(app.state, ApplicationLifecycleState.running);

      await _stop(app);
    });

    test('modal without an owner is a caller error, named as one', () async {
      final app = await _start(size: const Size(8, 8), colour: _colourA);
      await expectLater(
        () => app.openWindow(
          rootWidget: const _CountingBox(colour: _colourC),
          modal: true,
        ),
        throwsA(isA<ArgumentError>()),
      );
      await _stop(app);
    });
  });

  group('short-lived windows', () {
    test('opening and closing a child in a burst while the owner presents',
        () async {
      // The reported failure mode for every toolkit that grew popups: a window
      // created and destroyed inside one frame, with a present and a stream of
      // events still in flight for it. Nothing here may throw, and the owner
      // must be unaffected.
      final app = await _start(size: const Size(12, 12), colour: _colourA);
      final owner = app.primaryWindow;
      await owner.drawFrame();

      final retired = <NativeWindowId>[];
      for (var i = 0; i < 20; i++) {
        final popup = await app.openWindow(
          rootWidget: const _CountingBox(colour: _colourC),
          size: const Size(6, 6),
          owner: owner.id,
          kind: WindowKind.popup,
        );
        retired.add(popup.id);
        await popup.drawFrame();
        owner.requestFrame();
        app.closeWindow(popup.id);
        // Everything the platform still had queued for it now arrives late.
        app.backend.pumpEvents();
        expect(popup.isDisposed, isTrue);
        // A closed window refuses to draw rather than drawing into a surface
        // that has been freed. This is the crash the race produces when the
        // refusal is missing.
        await expectLater(popup.drawFrame(), throwsStateError);
        expect(await owner.drawFrame(), isA<PresentResult>());
      }

      expect(app.windows, <ApplicationWindow>[owner]);
      expect(app.state, ApplicationLifecycleState.running);
      expect(app.errors, isEmpty);
      expect(owner.framesPresented, 21);
      expect(_pixelAt(_framebufferOf(owner), 0, 0), _colourA);

      // And every late callback for the twenty dead windows - the ones native
      // code keeps delivering after a destroy - is dropped in declared
      // silence rather than routed into a torn-down tree.
      final droppedBefore = app.eventsDropped;
      for (final NativeWindowId id in retired) {
        expect(
          () => app.handleEvent(
            WindowExposedEvent(windowId: id, generation: 0),
          ),
          returnsNormally,
        );
      }
      expect(app.eventsDropped - droppedBefore, retired.length);

      await _stop(app);
    });
  });

  group('the single-window shape still works', () {
    test('runApp with one window behaves exactly as before', () async {
      final app = await runApp(
        const _CountingBox(colour: _colourA),
        backends: <WindowingBackendEntry>[
          const WindowingBackendEntry(
            name: 'headless',
            create: HeadlessWindowingBackend.new,
          ),
        ],
        options: const ApplicationOptions(size: Size(6, 6), frameBudget: 3),
      );

      expect(app.framesPresented, 3);
      expect(app.framesRejected, 0);
      expect(app.errors, isEmpty);
      expect(app.teardownOrder, <String>[
        'events',
        'buildOwner',
        'scheduler',
        'host',
        'window',
        'backend',
      ]);
      expect(app.state, ApplicationLifecycleState.closed);
    });

    test('run() drives every window, and one window closing does not stop it',
        () async {
      final app = await _start(size: const Size(6, 6), colour: _colourA);
      final a = app.primaryWindow;
      final b = await app.openWindow(
        rootWidget: const _CountingBox(colour: _colourB),
        size: const Size(6, 6),
      );

      await app.run(frameBudget: 8);

      expect(a.framesPresented, greaterThan(0));
      expect(b.framesPresented, greaterThan(0));
      expect(app.framesPresented, greaterThanOrEqualTo(8));
      expect(app.errors, isEmpty);

      app.dispose();
      await app.closed;
    });
  });
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

Future<Application> _start({
  required Size size,
  Widget? root,
  int colour = _colourA,
  _LayoutCounter? counter,
  bool exitWhenLastWindowClosed = true,
}) =>
    Application.start(
      rootWidget: root ?? _CountingBox(colour: colour, counter: counter),
      backends: <WindowingBackendEntry>[
        const WindowingBackendEntry(
          name: 'headless',
          create: HeadlessWindowingBackend.new,
        ),
      ],
      options: ApplicationOptions(
        title: 'multi-window test',
        size: size,
        visible: true,
        exitWhenLastWindowClosed: exitWhenLastWindowClosed,
      ),
    );

Future<void> _stop(Application app) async {
  app.dispose();
  await app.closed;
}

List<NativeWindowId> _activeWindows(Application app) => <NativeWindowId>[
      for (final ApplicationWindow window in app.windows)
        if (window.buildOwner.focusManager.isWindowActive) window.id,
    ];

Framebuffer _framebufferOf(ApplicationWindow window) =>
    ((window.host.presenter as RenderTargetPresenter).target
            as MemoryRenderTarget)
        .framebuffer;

/// The pixel at [x],[y] as packed ARGB, from the BGRA byte order the
/// framebuffer stores.
int _pixelAt(Framebuffer framebuffer, int x, int y) {
  final index = framebuffer.offsetOf(x, y);
  return (framebuffer.pixels[index + 3] << 24) |
      (framebuffer.pixels[index + 2] << 16) |
      (framebuffer.pixels[index + 1] << 8) |
      framebuffer.pixels[index];
}

PointerDownEvent _down(ApplicationWindow window, Offset position) =>
    PointerDownEvent(
      windowId: window.id,
      generation: window.nativeWindow.generation,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: position,
      button: PointerButton.primary,
    );

PointerUpEvent _up(ApplicationWindow window, Offset position) => PointerUpEvent(
      windowId: window.id,
      generation: window.nativeWindow.generation,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: position,
      button: PointerButton.primary,
    );

TextInputEvent _text(ApplicationWindow window, String text) => TextInputEvent(
      windowId: window.id,
      generation: window.nativeWindow.generation,
      timestamp: Duration.zero,
      text: text,
    );

void _click(ApplicationWindow window, Offset position) {
  final native = window.nativeWindow as HeadlessWindow;
  native
    ..dispatchInput(_down(window, position))
    ..dispatchInput(_up(window, position));
}

/// Counts the layouts and paints one window's tree actually ran.
///
/// The only way to state "B did not relayout" as a number rather than as a
/// hope: `PipelineOwner` has no counter, and a test that asserted on
/// `needsLayout` alone would pass against an implementation that laid the tree
/// out and then cleaned the flag.
final class _LayoutCounter {
  int layouts = 0;
  int paints = 0;

  @override
  String toString() => 'layouts: $layouts, paints: $paints';
}

final class _CountingBox extends SingleChildRenderObjectWidget {
  const _CountingBox({required this.colour, this.counter, super.child});

  final int colour;
  final _LayoutCounter? counter;

  @override
  _RenderCountingBox createRenderObject(BuildContext context) =>
      _RenderCountingBox(colour: colour, counter: counter);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderCountingBox renderObject,
  ) {
    renderObject.color = colour;
  }
}

/// A coloured box that counts what it was asked to do.
///
/// Written out rather than subclassed from `RenderColoredBox`, which is final:
/// the point is the two counters, and the rest is the four lines any filled
/// box needs.
final class _RenderCountingBox extends RenderSingleChildBox {
  _RenderCountingBox({required int colour, this.counter}) : _colour = colour;

  final _LayoutCounter? counter;
  int _colour;

  set color(int value) {
    if (value == _colour) return;
    _colour = value;
    markNeedsPaint();
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void performLayout() {
    counter?.layouts++;
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.largestFinite;
      return;
    }
    child.layout(constraints.loosen(), parentUsesSize: true);
    size = constraints.largestFinite;
  }

  @override
  void paint(DisplayList list, Offset offset) {
    counter?.paints++;
    final int paintId = list.addPaint(colorArgb: _colour);
    list.drawRectangle(
      Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height),
      paintId,
    );
    super.paint(list, offset);
  }
}

/// One button filling the window, reporting its own name.
final class _ButtonTree extends StatelessWidget {
  const _ButtonTree({required this.label, required this.onPressed});

  final String label;
  final void Function(String which) onPressed;

  @override
  Widget build(BuildContext context) => _CountingBox(
        colour: _colourA,
        child: SizedBox(
          width: 100,
          height: 30,
          child: Button(label: label, onPressed: () => onPressed(label)),
        ),
      );
}

/// One text field filling the window.
final class _FieldTree extends StatelessWidget {
  const _FieldTree({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) => _CountingBox(
        colour: _colourB,
        child: SizedBox(
          width: 120,
          height: 24,
          child: TextField(controller: controller, label: 'field'),
        ),
      );
}
