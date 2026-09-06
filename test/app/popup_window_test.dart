/// Popups in windows of their own, exercised end to end on the headless
/// backend.
///
/// The same rules `multi_window_test.dart` holds itself to apply here: the
/// production shell, no wall clock, and assertions on concrete values rather
/// than on "it did not throw". One rule is added, because this is where it can
/// go wrong invisibly:
///
///   * **the window is the assertion.** A test that only checked a
///     `PopupHandle` would pass against an implementation that leaked the
///     window behind it, which is precisely the bug the asynchronous open
///     invites. So `application.windows` is counted, owner chains are walked,
///     and client sizes are read off the native window.
///
/// The headless backend deliberately reports itself as having no popup
/// windows - see `Application.canOpenPopupWindows` - so `PopupPolicy.auto`
/// gives every window an `InTreePopupHost` here. That is not an obstacle to
/// testing this file's subject: `Application.openPopup` and `WindowPopupHost`
/// are driven directly, which is also how an application on a backend that
/// *does* have popup windows reaches them.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

const int _colourOwner = 0xFF203040;
const int _colourPopup = 0xFFC08020;

/// A desktop small enough that a test can reason about the whole of it, with a
/// reserved strip along the bottom so that the work area and the bounds are
/// never accidentally the same rectangle.
const ScreenInfo _screen = ScreenInfo(
  bounds: Rect.fromLTRB(0, 0, 400, 300),
  workArea: Rect.fromLTRB(0, 0, 400, 280),
  scale: 1,
  isPrimary: true,
  name: 'test-1',
);

void main() {
  group('screens', () {
    test('a backend that describes its monitors is believed', () async {
      final app = await _start();

      expect(app.screens, <ScreenInfo>[_screen]);
      expect(app.hasScreenCoordinates, isTrue);
      expect(app.screenFor(app.primaryWindow), _screen);
      // Outside every screen still resolves to one: a popup anchored past the
      // edge has to be placed somewhere, and "nowhere" is not a placement.
      expect(app.screenAt(const Offset(9999, 9999)), _screen);

      await _stop(app);
    });

    test('a backend with no monitors gets one synthesised from its window',
        () async {
      final app = await _start(screens: const <ScreenInfo>[]);
      final ApplicationWindow window = app.primaryWindow;

      final List<ScreenInfo> screens = app.screens;
      expect(screens, hasLength(1));
      expect(screens.single.bounds, const Rect.fromLTWH(0, 0, 200, 150));
      // Equal to the bounds, because nothing here can find out what a shell
      // reserved and a guessed inset would be a lie with a taskbar in it.
      expect(screens.single.workArea, screens.single.bounds);
      expect(screens.single.scale, window.host.renderScale);

      // And the fabrication is admitted: there are no screen *coordinates*, so
      // placement passes the anchor through instead of computing a flip.
      expect(app.hasScreenCoordinates, isFalse);
      expect(
        app.placePopup(
          owner: window,
          anchorRect: const Rect.fromLTWH(10, 10, 50, 20),
          size: const Size(80, 40),
        ),
        const Rect.fromLTWH(10, 30, 80, 40),
      );

      await _stop(app);
    });
  });

  group('openPopup', () {
    test('auto-sizes the window to the content, not to the provisional size',
        () async {
      final app = await _start();
      final owner = app.primaryWindow;
      await owner.drawFrame();

      final popup = await app.openPopup(
        owner: owner,
        anchorRect: const Rect.fromLTWH(10, 10, 50, 20),
        content: const _Recorder(
          colour: _colourPopup,
          fixedSize: Size(120, 60),
        ),
        kind: PopupKind.menu,
      );

      // The provisional size was the whole work area - 400x280 - and the
      // measured one is the box's. A window still 400 wide would mean the
      // measurement never happened.
      expect(popup.nativeWindow.clientSize, const Size(120, 60));
      // And the host follows once the platform's own resize is delivered,
      // which is the ordinary route and not a popup-specific one.
      app.backend.pumpEvents();
      expect(popup.host.logicalSize, const Size(120, 60));
      expect(popup.popupKind, PopupKind.menu);
      expect(popup.kind, WindowKind.popup);
      expect(popup.ownerId, owner.id);
      // And the tree is laid out against the *final* size, not against the
      // loose constraint it was measured with.
      expect(popup.pipelineOwner.rootConstraints.isTight, isTrue);

      await _stop(app);
    });

    test('places under the anchor, and flips rather than leaving the work area',
        () async {
      final app = await _start();
      final owner = app.primaryWindow;
      await owner.drawFrame();

      final under = await app.openPopup(
        owner: owner,
        anchorRect: const Rect.fromLTWH(10, 10, 50, 20),
        content: const _Recorder(colour: _colourPopup, fixedSize: Size(80, 40)),
        kind: PopupKind.menu,
      );
      expect(_boundsOf(under), const Rect.fromLTWH(10, 30, 80, 40));

      // Anchored so low that the popup would cross the reserved strip. The
      // work area is 280 tall while the screen is 300, so a run that used the
      // bounds instead would place it at y=260 and pass by accident.
      final flipped = await app.openPopup(
        owner: owner,
        anchorRect: const Rect.fromLTWH(10, 250, 50, 20),
        content: const _Recorder(colour: _colourPopup, fixedSize: Size(80, 40)),
        kind: PopupKind.menu,
      );
      expect(_boundsOf(flipped), const Rect.fromLTWH(10, 210, 80, 40),
          reason: 'flipped above the anchor to stay inside the work area');

      await _stop(app);
    });

    test('a constrained popup is measured inside its constraints', () async {
      final app = await _start();
      final owner = app.primaryWindow;
      await owner.drawFrame();

      final popup = await app.openPopup(
        owner: owner,
        anchorRect: const Rect.fromLTWH(0, 0, 10, 10),
        // No fixed size: the box takes everything it is offered, so the only
        // thing that can bound it is the constraint.
        content: const _Recorder(colour: _colourPopup),
        kind: PopupKind.dropdown,
        constraints: BoxConstraints.tightFor(width: 90),
      );

      expect(popup.nativeWindow.clientSize.width, 90);
      expect(popup.nativeWindow.clientSize.height, 280,
          reason: 'height was unconstrained, so it fills the work area');

      await _stop(app);
    });
  });

  group('the keyboard is redirected into the popup', () {
    test('typing with a popup open reaches the popup, not the owner', () async {
      final ownerLog = _Log();
      final popupLog = _Log();
      final app = await _start(ownerLog: ownerLog);
      final owner = app.primaryWindow;
      await owner.drawFrame();
      _focus(owner, ownerLog);

      final popup = await app.openPopup(
        owner: owner,
        anchorRect: const Rect.fromLTWH(10, 10, 20, 20),
        content: _Recorder(
          colour: _colourPopup,
          fixedSize: const Size(80, 40),
          log: popupLog,
        ),
        kind: PopupKind.menu,
      );
      _focus(popup, popupLog);

      // Aimed at the owner, because a popup never activates and the platform
      // therefore never addresses it.
      expect(app.handleEvent(_text(owner, 'X')), isTrue);
      expect(popupLog.text, <String>['X']);
      expect(ownerLog.text, isEmpty);

      expect(app.handleEvent(_key(owner, _keyA)), isTrue);
      expect(popupLog.keys, <int>[_keyA]);
      expect(ownerLog.keys, isEmpty);

      await _stop(app);
    });

    test('the owner still gets what the popup declined', () async {
      final ownerLog = _Log();
      final popupLog = _Log(consumes: false);
      final app = await _start(ownerLog: ownerLog);
      final owner = app.primaryWindow;
      await owner.drawFrame();
      _focus(owner, ownerLog);

      final popup = await app.openPopup(
        owner: owner,
        anchorRect: const Rect.fromLTWH(10, 10, 20, 20),
        content: _Recorder(
          colour: _colourPopup,
          fixedSize: const Size(80, 40),
          log: popupLog,
        ),
        kind: PopupKind.menu,
      );
      _focus(popup, popupLog);

      expect(app.handleEvent(_key(owner, _keyF4)), isTrue);
      // Both saw it, in that order, and the owner is what makes Alt+F4 still
      // close the application with a menu open.
      expect(popupLog.keys, <int>[_keyF4]);
      expect(ownerLog.keys, <int>[_keyF4]);

      await _stop(app);
    });

    test('a tooltip never takes the keyboard', () async {
      final ownerLog = _Log();
      final tipLog = _Log();
      final app = await _start(ownerLog: ownerLog);
      final owner = app.primaryWindow;
      await owner.drawFrame();
      _focus(owner, ownerLog);

      final tip = await app.openPopup(
        owner: owner,
        anchorRect: const Rect.fromLTWH(10, 10, 20, 20),
        content: _Recorder(
          colour: _colourPopup,
          fixedSize: const Size(80, 40),
          log: tipLog,
        ),
        kind: PopupKind.tooltip,
      );
      _focus(tip, tipLog);
      expect(tip.kind, WindowKind.tooltip);

      expect(app.handleEvent(_text(owner, 'Q')), isTrue);
      expect(ownerLog.text, <String>['Q']);
      expect(tipLog.text, isEmpty,
          reason: 'a hover label that ate the typing would be a dead keyboard');

      await _stop(app);
    });

    test('the innermost popup gets the key, and only it', () async {
      final ownerLog = _Log();
      final outerLog = _Log();
      final innerLog = _Log();
      final app = await _start(ownerLog: ownerLog);
      final owner = app.primaryWindow;
      await owner.drawFrame();
      _focus(owner, ownerLog);

      final outer = await app.openPopup(
        owner: owner,
        anchorRect: const Rect.fromLTWH(10, 10, 20, 20),
        content: _Recorder(
          colour: _colourPopup,
          fixedSize: const Size(80, 40),
          log: outerLog,
        ),
        kind: PopupKind.menu,
      );
      _focus(outer, outerLog);
      final inner = await app.openPopup(
        owner: owner,
        parentPopup: outer,
        anchorRect: const Rect.fromLTWH(30, 30, 20, 20),
        content: _Recorder(
          colour: _colourPopup,
          fixedSize: const Size(60, 30),
          log: innerLog,
        ),
        kind: PopupKind.submenu,
      );
      _focus(inner, innerLog);

      expect(app.handleEvent(_key(owner, _keyEscape)), isTrue);
      expect(innerLog.keys, <int>[_keyEscape]);
      expect(outerLog.keys, isEmpty,
          reason: 'Escape closes one level, so only one level sees it');
      expect(ownerLog.keys, isEmpty);

      await _stop(app);
    });
  });

  group('the four dismissal routes', () {
    test('a press in the owner with a menu open dismisses it and is swallowed',
        () async {
      final ownerLog = _Log();
      final app = await _start(ownerLog: ownerLog);
      final owner = app.primaryWindow;
      await owner.drawFrame();

      final menu = await app.openPopup(
        owner: owner,
        anchorRect: const Rect.fromLTWH(10, 10, 20, 20),
        content: const _Recorder(colour: _colourPopup, fixedSize: Size(80, 40)),
        kind: PopupKind.menu,
      );

      expect(app.handleEvent(_down(owner, const Offset(150, 100))), isTrue);
      expect(menu.isDisposed, isTrue);
      expect(ownerLog.presses, 0,
          reason: 'the click that closes a menu must not press what is behind');
      expect(app.windows, <ApplicationWindow>[owner]);

      await _stop(app);
    });

    test('a press with a dropdown open dismisses it and is delivered',
        () async {
      final ownerLog = _Log();
      final app = await _start(ownerLog: ownerLog);
      final owner = app.primaryWindow;
      await owner.drawFrame();

      final list = await app.openPopup(
        owner: owner,
        anchorRect: const Rect.fromLTWH(10, 10, 20, 20),
        content: const _Recorder(colour: _colourPopup, fixedSize: Size(80, 40)),
        kind: PopupKind.dropdown,
      );

      expect(app.handleEvent(_down(owner, const Offset(150, 100))), isTrue);
      expect(list.isDisposed, isTrue);
      expect(ownerLog.presses, 1,
          reason: 'closing a combo list by clicking a button presses it');

      await _stop(app);
    });

    test('the owner moving dismisses its popups', () async {
      final app = await _start();
      final owner = app.primaryWindow;
      await owner.drawFrame();
      final menu = await app.openPopup(
        owner: owner,
        anchorRect: const Rect.fromLTWH(10, 10, 20, 20),
        content: const _Recorder(colour: _colourPopup, fixedSize: Size(80, 40)),
        kind: PopupKind.menu,
      );

      app.handleEvent(WindowMovedEvent(
        windowId: owner.id,
        generation: owner.nativeWindow.generation,
        screenPosition: const Offset(40, 40),
      ));

      expect(menu.isDisposed, isTrue,
          reason: 'a menu anchored to a window that moved points at nothing');
      expect(app.windows, <ApplicationWindow>[owner]);

      await _stop(app);
    });

    test('a press on the owner\'s frame dismisses them', () async {
      final app = await _start();
      final owner = app.primaryWindow;
      await owner.drawFrame();
      final menu = await app.openPopup(
        owner: owner,
        anchorRect: const Rect.fromLTWH(10, 10, 20, 20),
        content: const _Recorder(colour: _colourPopup, fixedSize: Size(80, 40)),
        kind: PopupKind.menu,
      );

      app.handleEvent(WindowNonClientPressEvent(
        windowId: owner.id,
        generation: owner.nativeWindow.generation,
        timestamp: Duration.zero,
      ));

      expect(menu.isDisposed, isTrue);
      expect(app.windows, <ApplicationWindow>[owner]);

      await _stop(app);
    });

    test('the owner losing activation to a foreign application dismisses them',
        () async {
      final app = await _start();
      final owner = app.primaryWindow;
      await owner.drawFrame();
      final menu = await app.openPopup(
        owner: owner,
        anchorRect: const Rect.fromLTWH(10, 10, 20, 20),
        content: const _Recorder(colour: _colourPopup, fixedSize: Size(80, 40)),
        kind: PopupKind.menu,
      );

      // No other window of ours took the keyboard: this is the user clicking
      // another application, which is the case `focusWindow` alone misses.
      app.handleEvent(WindowActivationEvent(
        windowId: owner.id,
        generation: owner.nativeWindow.generation,
        activation: WindowActivation.deactivated,
      ));

      expect(menu.isDisposed, isTrue);
      expect(app.windows, <ApplicationWindow>[owner]);

      await _stop(app);
    });

    test('a press inside a popup closes its children and still reaches it',
        () async {
      final parentLog = _Log();
      final app = await _start();
      final owner = app.primaryWindow;
      await owner.drawFrame();

      final parent = await app.openPopup(
        owner: owner,
        anchorRect: const Rect.fromLTWH(10, 10, 20, 20),
        content: _Recorder(
          colour: _colourPopup,
          fixedSize: const Size(80, 40),
          log: parentLog,
        ),
        kind: PopupKind.menu,
      );
      await parent.drawFrame();
      final child = await app.openPopup(
        owner: owner,
        parentPopup: parent,
        anchorRect: const Rect.fromLTWH(30, 30, 20, 20),
        content: const _Recorder(colour: _colourPopup, fixedSize: Size(60, 30)),
        kind: PopupKind.submenu,
      );

      app.handleEvent(_down(parent, const Offset(10, 10)));

      // The same rule `RenderPopupLayer._isModal` implements: only the owner's
      // content is shielded, so a press on a parent menu item still activates
      // it while the submenu closes.
      expect(child.isDisposed, isTrue);
      expect(parent.isDisposed, isFalse);
      expect(parentLog.presses, 1);

      await _stop(app);
    });
  });

  group('WindowPopupHost', () {
    test('reports that it leaves the owner window, and counts what is open',
        () async {
      final app = await _start();
      final owner = app.primaryWindow;
      await owner.drawFrame();
      final host = WindowPopupHost(application: app, owner: owner);

      expect(host.escapesOwnerWindow, isTrue);
      expect(host.openCount, 0);
      expect(host.topmost, isNull);

      final handle = host.open(_spec(kind: PopupKind.menu));
      // Synchronously open, and synchronously unplaced: the window has not
      // been created yet and pretending otherwise is what a caller must not
      // be allowed to do.
      expect(handle.isOpen, isTrue);
      expect(handle.placedRect, isNull);
      expect(host.openCount, 1);
      expect(identical(host.topmost, handle), isTrue);

      await _settle();
      expect(handle.placedRect, const Rect.fromLTWH(10, 30, 80, 40));
      expect(app.windows, hasLength(2));

      handle.close();
      expect(handle.isOpen, isFalse);
      expect(handle.placedRect, isNull);
      expect(host.openCount, 0);
      expect(app.windows, <ApplicationWindow>[owner]);

      await _stop(app);
    });

    test('close() before the open lands leaves no window behind', () async {
      final app = await _start();
      final owner = app.primaryWindow;
      await owner.drawFrame();
      final host = WindowPopupHost(application: app, owner: owner);

      var dismissed = 0;
      final handle = host.open(_spec(onDismiss: () => dismissed++));
      handle.close();

      // The race this whole class is written around: a hover that moved on
      // before the tooltip landed. Everything the launch would have created
      // must not exist, and it must not exist *later* either.
      await _settle();
      expect(app.windows, <ApplicationWindow>[owner],
          reason: 'a cancelled open must not leave an orphan window');
      expect(host.openCount, 0);
      expect(dismissed, 1);

      await _stop(app);
    });

    test('onDismiss fires exactly once however many routes race', () async {
      final app = await _start();
      final owner = app.primaryWindow;
      await owner.drawFrame();
      final host = WindowPopupHost(application: app, owner: owner);

      var dismissed = 0;
      final handle = host.open(_spec(onDismiss: () => dismissed++));
      await _settle();
      final ApplicationWindow window = (handle as WindowPopupHandle).window!;

      // Four routes at once, which is not contrived: a click outside, a
      // `popup_done` from the compositor and the widget's own close all
      // describe the same dismissal and all arrive.
      handle.close();
      app.closeWindow(window.id);
      handle.close();
      app.handleEvent(WindowCloseRequestedEvent(
        windowId: window.id,
        generation: window.nativeWindow.generation,
      ));

      expect(dismissed, 1);
      expect(handle.isOpen, isFalse);
      expect(app.windows, <ApplicationWindow>[owner]);

      await _stop(app);
    });

    test('the platform destroying the window dismisses the handle', () async {
      final app = await _start();
      final owner = app.primaryWindow;
      await owner.drawFrame();
      final host = WindowPopupHost(application: app, owner: owner);

      var dismissed = 0;
      final handle = host.open(_spec(onDismiss: () => dismissed++));
      await _settle();
      final window = (handle as WindowPopupHandle).window!;

      // Nobody called close(): the window went away underneath the handle,
      // which is what a `popup_done` or an owner teardown looks like.
      app.closeWindow(window.id);

      expect(handle.isOpen, isFalse);
      expect(dismissed, 1);
      expect(host.openCount, 0);

      await _stop(app);
    });

    test('closing the middle of a chain closes the inner and spares the outer',
        () async {
      final app = await _start();
      final owner = app.primaryWindow;
      await owner.drawFrame();
      final host = WindowPopupHost(application: app, owner: owner);

      final dismissals = <String>[];
      final outer = host.open(
        _spec(onDismiss: () => dismissals.add('outer')),
      );
      await _settle();
      final middle = host.open(_spec(
        kind: PopupKind.submenu,
        parent: outer,
        onDismiss: () => dismissals.add('middle'),
      ));
      await _settle();
      final inner = host.open(_spec(
        kind: PopupKind.submenu,
        parent: middle,
        onDismiss: () => dismissals.add('inner'),
      ));
      await _settle();

      expect(host.openCount, 3);
      expect(app.windows, hasLength(4));
      // A real chain, one owner link per level: this is what the platform is
      // handed, and on Wayland a wrong parent here is a protocol error.
      final outerWindow = (outer as WindowPopupHandle).window!;
      final middleWindow = (middle as WindowPopupHandle).window!;
      final innerWindow = (inner as WindowPopupHandle).window!;
      expect(outerWindow.ownerId, owner.id);
      expect(middleWindow.ownerId, outerWindow.id);
      expect(innerWindow.ownerId, middleWindow.id);

      middle.close();

      expect(inner.isOpen, isFalse);
      expect(middle.isOpen, isFalse);
      expect(outer.isOpen, isTrue);
      expect(dismissals, <String>['inner', 'middle']);
      expect(app.windows, <ApplicationWindow>[owner, outerWindow]);

      await _stop(app);
    });

    test('a submenu opened from inside a popup window chains onto that popup',
        () async {
      final app = await _start();
      final owner = app.primaryWindow;
      await owner.drawFrame();
      final host = WindowPopupHost(application: app, owner: owner);

      // The host the popup's *own* tree publishes. If that were a fresh host
      // per window, this submenu would be opened as a root popup of the
      // top-level window and the platform would be handed a broken chain.
      PopupHost? insidePopup;
      final menu = host.open(_spec(
        builder: (BuildContext context) {
          insidePopup = PopupHost.of(context);
          return const _Recorder(
            colour: _colourPopup,
            fixedSize: Size(80, 40),
          );
        },
      ));
      await _settle();

      expect(insidePopup, isNotNull);
      final submenu = insidePopup!.open(_spec(
        kind: PopupKind.submenu,
        anchorRect: const Rect.fromLTWH(20, 20, 20, 10),
      ));
      await _settle();

      expect(identical(submenu.parent, menu), isTrue,
          reason: 'the enclosing popup is the parent, with no parent: passed');
      // One owner link per menu level, nested rather than flat.
      final menuWindow = (menu as WindowPopupHandle).window!;
      final submenuWindow = (submenu as WindowPopupHandle).window!;
      expect(menuWindow.ownerId, owner.id);
      expect(submenuWindow.ownerId, menuWindow.id);
      expect(app.windows, hasLength(3));

      // And it is one host, not two: the count is the chain's, seen from
      // either view of it.
      expect(host.openCount, 2);

      await _stop(app);
    });

    test('closeAll closes every popup, deepest first', () async {
      final app = await _start();
      final owner = app.primaryWindow;
      await owner.drawFrame();
      final host = WindowPopupHost(application: app, owner: owner);

      final order = <String>[];
      final first = host.open(_spec(onDismiss: () => order.add('first')));
      await _settle();
      host.open(_spec(
        kind: PopupKind.submenu,
        parent: first,
        onDismiss: () => order.add('second'),
      ));
      await _settle();

      host.closeAll();

      expect(order, <String>['second', 'first']);
      expect(host.openCount, 0);
      expect(app.windows, <ApplicationWindow>[owner]);

      await _stop(app);
    });

    test('updateAnchor moves the window that is already up', () async {
      final app = await _start();
      final owner = app.primaryWindow;
      await owner.drawFrame();
      final host = WindowPopupHost(application: app, owner: owner);

      final handle = host.open(_spec());
      await _settle();
      expect(handle.placedRect, const Rect.fromLTWH(10, 30, 80, 40));

      handle.updateAnchor(const Rect.fromLTWH(100, 100, 50, 20));
      expect(handle.placedRect, const Rect.fromLTWH(100, 120, 80, 40));

      await _stop(app);
    });
  });

  group('PopupPolicy', () {
    test('inTree gives the window an InTreePopupHost', () async {
      final holder = _HostHolder();
      final app = await _start(
        root: _HostProbe(holder: holder),
        popupPolicy: PopupPolicy.inTree,
      );
      await app.primaryWindow.drawFrame();

      expect(holder.host, isA<InTreePopupHost>());
      expect(holder.host!.escapesOwnerWindow, isFalse);

      await _stop(app);
    });

    test('auto falls back to in-tree on a backend with no popup windows',
        () async {
      final holder = _HostHolder();
      final app = await _start(root: _HostProbe(holder: holder));
      await app.primaryWindow.drawFrame();

      expect(app.canOpenPopupWindows, isFalse,
          reason: 'a headless window is an object in a list, not a surface '
              'the user can see beside another one');
      expect(holder.host, isA<InTreePopupHost>());

      await _stop(app);
    });

    test('window on a backend with none throws, loudly and by name', () async {
      await expectLater(
        _start(popupPolicy: PopupPolicy.window),
        throwsA(isA<PopupWindowUnavailableError>().having(
          (PopupWindowUnavailableError error) => error.toString(),
          'toString',
          allOf(contains('headless'), contains('PopupPolicy.window')),
        )),
      );
    });
  });
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

Future<Application> _start({
  Widget? root,
  _Log? ownerLog,
  PopupPolicy popupPolicy = PopupPolicy.auto,
  List<ScreenInfo> screens = const <ScreenInfo>[_screen],
}) =>
    Application.start(
      rootWidget: root ?? _Recorder(colour: _colourOwner, log: ownerLog),
      backends: <WindowingBackendEntry>[
        WindowingBackendEntry(
          name: 'headless',
          create: () => HeadlessWindowingBackend(screens: screens),
        ),
      ],
      options: ApplicationOptions(
        title: 'popup window test',
        size: const Size(200, 150),
        visible: true,
        popupPolicy: popupPolicy,
      ),
    );

Future<void> _stop(Application app) async {
  app.dispose();
  await app.closed;
}

/// Lets every pending microtask and zero-duration timer run.
///
/// Opening a popup window is asynchronous - the backend creates the window,
/// a presenter attaches to it, a surface is allocated - and `PopupHost.open`
/// is not. This is the wait a caller does not have to do and a test does.
Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// A popup spec with the one anchor every placement assertion in this file is
/// written against: 50x20 at (10,10), so `bottomLeft` puts the popup at y=30.
PopupSpec _spec({
  PopupKind kind = PopupKind.menu,
  Rect anchorRect = const Rect.fromLTWH(10, 10, 50, 20),
  PopupHandle? parent,
  void Function()? onDismiss,
  WidgetBuilder? builder,
}) =>
    PopupSpec(
      anchorRect: anchorRect,
      kind: kind,
      parent: parent,
      onDismiss: onDismiss,
      builder: builder ??
          (BuildContext context) => const _Recorder(
                colour: _colourPopup,
                fixedSize: Size(80, 40),
              ),
    );

/// The popup window's rectangle in the owner's logical space, read back from
/// the platform rather than from what we asked for.
Rect _boundsOf(ApplicationWindow window) {
  final Offset origin = window.nativeWindow.clientToScreen(Offset.zero);
  final Size size = window.nativeWindow.clientSize;
  return Rect.fromLTWH(origin.dx, origin.dy, size.width, size.height);
}

/// Gives the recorder in [window]'s tree the keyboard focus of that window.
void _focus(ApplicationWindow window, _Log log) {
  final _RenderRecorder? target = log.target;
  expect(target, isNotNull, reason: 'the recorder never reached a tree');
  window.buildOwner.requestKeyboardFocus(target!);
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

TextInputEvent _text(ApplicationWindow window, String text) => TextInputEvent(
      windowId: window.id,
      generation: window.nativeWindow.generation,
      timestamp: Duration.zero,
      text: text,
    );

/// A key transition, identified by its logical code - the number is opaque to
/// the framework and only has to be distinguishable, which is all these tests
/// ask of it.
KeyDownEvent _key(ApplicationWindow window, int logicalKey) => KeyDownEvent(
      windowId: window.id,
      generation: window.nativeWindow.generation,
      timestamp: Duration.zero,
      physicalKey: logicalKey,
      logicalKey: logicalKey,
    );

const int _keyA = 0x41;
const int _keyF4 = 0x73;
const int _keyEscape = 0x1B;

/// What one window's tree was asked to do.
final class _Log {
  _Log({this.consumes = true});

  /// Whether the recorder claims the keys it sees. False is the case that
  /// matters most: an unconsumed key must reach the owner, which is what keeps
  /// Alt+F4 working with a menu open.
  final bool consumes;

  final List<int> keys = <int>[];
  final List<String> text = <String>[];
  int presses = 0;

  /// The render object, so a test can hand it the focus without going through
  /// a pointer press it is not testing.
  _RenderRecorder? target;
}

/// A filled box that records the input it receives.
final class _Recorder extends SingleChildRenderObjectWidget {
  const _Recorder({required this.colour, this.log, this.fixedSize});

  final int colour;
  final _Log? log;
  final Size? fixedSize;

  @override
  _RenderRecorder createRenderObject(BuildContext context) {
    final recorder = _RenderRecorder(
      colour: colour,
      log: log,
      fixedSize: fixedSize,
    );
    log?.target = recorder;
    return recorder;
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderRecorder renderObject,
  ) {
    log?.target = renderObject;
  }
}

final class _RenderRecorder extends RenderSingleChildBox
    implements KeyboardEventTarget, TextInputTarget, PointerEventTarget {
  _RenderRecorder({required int colour, this.log, this.fixedSize})
      : _colour = colour;

  final _Log? log;
  final Size? fixedSize;
  final int _colour;

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void handlePointerEvent(PointerEvent event) {
    if (event is PointerDownEvent) log?.presses++;
  }

  @override
  bool handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    log?.keys.add(event.logicalKey);
    return log?.consumes ?? false;
  }

  @override
  bool handleTextInput(TextInputEvent event) {
    log?.text.add(event.text);
    return log?.consumes ?? false;
  }

  @override
  void performLayout() {
    final Size? fixed = fixedSize;
    size = fixed == null
        ? constraints.largestFinite
        : constraints.constrain(fixed);
    child?.layout(constraints.loosen());
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final int paintId = list.addPaint(colorArgb: _colour);
    list.drawRectangle(
      Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height),
      paintId,
    );
    super.paint(list, offset);
  }
}

final class _HostHolder {
  PopupHost? host;
}

/// Reads the host its own window published, which is the only way to assert
/// which of the two implementations a policy produced.
final class _HostProbe extends StatelessWidget {
  const _HostProbe({required this.holder});

  final _HostHolder holder;

  @override
  Widget build(BuildContext context) {
    holder.host = PopupHost.maybeOf(context);
    return const _Recorder(colour: _colourOwner);
  }
}
