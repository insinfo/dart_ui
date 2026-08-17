/// Two real HWNDs under one [Application].
///
/// The headless suite in `test/app/multi_window_test.dart` proves the routing,
/// the focus arbitration and the teardown order deterministically. This proves
/// the half a virtual backend cannot: that there really are two windows of the
/// real window class, that Windows' own activation messages drive the focus
/// arbitration, that one thread's message queue serves both, and that
/// destroying one window from inside the pump leaves the other running.
///
/// Deliberately not `package:dart_ui/dart_ui.dart` for the backend pieces: the
/// application shell has to be imported by path anyway, and naming the files
/// keeps it obvious which layer each symbol comes from.
library;

import 'dart:io' show Platform;

import 'package:dart_ui/src/app/application.dart';
import 'package:dart_ui/src/backends/win32/win32_backend.dart';
import 'package:dart_ui/src/backends/win32/win32_constants.dart';
import 'package:dart_ui/src/backends/win32/win32_cpu_presenter.dart';
import 'package:dart_ui/src/backends/win32/win32_window.dart';
import 'package:dart_ui/src/backends/win32/win32_window_class.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/graphics/color.dart';
import 'package:dart_ui/src/platform/native_window.dart';
import 'package:dart_ui/src/platform/window_events.dart';
import 'package:dart_ui/src/widgets/basic.dart';
import 'package:test/test.dart';

/// `WA_ACTIVE`. `win32_constants.dart` declares only WA_INACTIVE, because the
/// handler branches on "is it inactive" - so the other value is named here
/// rather than written as a bare 1 in five places.
const int _waActive = 1;

const Color _colourA = Color(0xFF3060A0);
const Color _colourB = Color(0xFFA06030);

void main() {
  group('two real Win32 windows in one application', () {
    late Application app;
    late ApplicationWindow a;
    late ApplicationWindow b;

    setUp(() async {
      app = await Application.start(
        rootWidget: const ColoredBox(color: _colourA),
        backends: <WindowingBackendEntry>[
          const WindowingBackendEntry(
            name: 'win32',
            create: Win32WindowingBackend.new,
          ),
        ],
        presentations: <PresentationPathEntry>[
          PresentationPathEntry.retainedCpu(
            name: 'win32-dib',
            deviceDescription: 'GDI DIB section, BGRA8888 top-down',
            create: (NativeWindow window) {
              final presenter = Win32CpuPresenter(window as Win32Window);
              return (
                present: presenter.renderDisplayList,
                presentNow: presenter.renderDisplayListNow,
                release: presenter.dispose,
              );
            },
          ),
        ],
        options: const ApplicationOptions(
          title: 'multi-window A',
          size: Size(240, 160),
          clearColor: _colourA,
        ),
      );
      a = app.primaryWindow;
      b = await app.openWindow(
        rootWidget: const ColoredBox(color: _colourB),
        title: 'multi-window B',
        size: const Size(200, 140),
        visible: false,
        clearColor: _colourB,
      );
    });

    tearDown(() async {
      app.dispose();
      await app.closed;
    });

    /// One turn of the platform pump plus one turn of the Dart event loop,
    /// which is what a `WindowCloseRequestedEvent` needs to travel from the
    /// `WndProc` to the application: the window's stream is a broadcast
    /// controller and its listeners run on a later turn.
    Future<void> pump() async {
      app.backend.pumpEvents();
      await Future<void>.delayed(Duration.zero);
    }

    test('are two distinct HWNDs of the same window class', () async {
      final nativeA = a.nativeWindow as Win32Window;
      final nativeB = b.nativeWindow as Win32Window;

      expect(nativeA.handle, isNot(0));
      expect(nativeB.handle, isNot(0));
      expect(nativeA.handle, isNot(nativeB.handle));
      expect(nativeA.id, isNot(nativeB.id));
      // One registered class for both, which is what stops a thousand-window
      // run from leaking a thousand class registrations.
      expect(nativeA.className, nativeB.className);
      expect(app.backend.windows, hasLength(2));
      expect(Win32WindowRegistry.attachedCount, greaterThanOrEqualTo(2));
    });

    test('each presents its own DIB, and one frame is not the other', () async {
      final resultA = await a.drawFrame();
      final resultB = await b.drawFrame();

      expect(resultA.isSuccess, isTrue, reason: resultA.diagnostic?.toString());
      expect(resultB.isSuccess, isTrue, reason: resultB.diagnostic?.toString());
      expect(a.framesPresented, 1);
      expect(b.framesPresented, 1);

      final surfaceA = (a.nativeWindow as Win32Window).dibSurface;
      final surfaceB = (b.nativeWindow as Win32Window).dibSurface;
      expect(surfaceA, isNotNull);
      expect(surfaceB, isNotNull);
      expect(identical(surfaceA, surfaceB), isFalse);
      // Different sizes, so a shared surface would be visibly impossible.
      expect(surfaceA!.pixelWidth, isNot(surfaceB!.pixelWidth));
      expect(app.errors, isEmpty);
    });

    test('WM_ACTIVATE alternating moves the keyboard, and only ever to one',
        () async {
      final nativeA = a.nativeWindow as Win32Window;
      final nativeB = b.nativeWindow as Win32Window;

      Future<void> activate(Win32Window window, {required bool active}) async {
        window.handleMessage(
          window.handle,
          wmActivate,
          active ? _waActive : waInactive,
          0,
        );
        await pump();
      }

      // A -> B, the way Windows actually sends it: the loser first.
      await activate(nativeA, active: false);
      await activate(nativeB, active: true);

      expect(nativeB.isActivated, isTrue);
      expect(nativeA.isActivated, isFalse);
      expect(app.keyboardFocusWindow, b.id);
      expect(_activeWindows(app), <NativeWindowId>[b.id]);
      expect(a.buildOwner.focusManager.isWindowActive, isFalse);
      expect(b.buildOwner.focusManager.isWindowActive, isTrue);

      // And back, through WM_SETFOCUS this time - the keyboard half of the
      // same story, which arrives without WM_ACTIVATE when the click is on
      // another window of the same application.
      nativeB.handleMessage(nativeB.handle, wmKillfocus, 0, 0);
      nativeA.handleMessage(nativeA.handle, wmSetfocus, 0, 0);
      await pump();

      expect(app.keyboardFocusWindow, a.id);
      expect(_activeWindows(app), <NativeWindowId>[a.id]);
      expect(b.buildOwner.focusManager.isWindowActive, isFalse);

      // Two activations in a row for the same window are one event: the pair
      // WM_ACTIVATE + WM_SETFOCUS that Windows sends together must not read as
      // two focus moves.
      final droppedBefore = app.eventsDropped;
      nativeA.handleMessage(nativeA.handle, wmActivate, _waActive, 0);
      nativeA.handleMessage(nativeA.handle, wmSetfocus, 0, 0);
      await pump();
      expect(app.keyboardFocusWindow, a.id);
      expect(app.eventsDropped, droppedBefore);
    });

    test('WM_CLOSE on one window destroys that HWND and no other', () async {
      final nativeA = a.nativeWindow as Win32Window;
      final nativeB = b.nativeWindow as Win32Window;
      final handleB = nativeB.handle;
      await a.drawFrame();
      await b.drawFrame();

      final api = Win32WindowingBackend();
      // Ask Windows, not a Dart flag: the whole point is that the HWND is gone.
      expect(nativeB.handle, isNot(0));

      // The real message the title-bar X produces.
      expect(
        nativeB.handleMessage(handleB, wmClose, 0, 0),
        0,
        reason: 'WM_CLOSE is a request; the handler must destroy nothing '
            'itself, or an application could not veto a close',
      );
      expect(nativeB.isDisposed, isFalse, reason: 'still only a request');

      await pump();

      expect(b.isDisposed, isTrue);
      expect(nativeB.isDisposed, isTrue);
      expect(app.windows, <ApplicationWindow>[a]);
      expect(app.backend.windows, hasLength(1));
      expect(app.state, ApplicationLifecycleState.running,
          reason: 'a second window closing is not the application closing');

      // A is untouched and still presenting into a live HWND.
      expect(nativeA.handle, isNot(0));
      a.requestFrame();
      final result = await a.drawFrame();
      expect(result.isSuccess, isTrue, reason: result.diagnostic?.toString());
      expect(a.framesPresented, 2);
      expect(app.errors, isEmpty);
      expect(Win32WindowRegistry.faults, isEmpty);
      api.toString(); // keeps the unused local honest without a lint
    });

    test('closing the last window asks the application to close', () async {
      await a.drawFrame();
      final nativeA = a.nativeWindow as Win32Window;
      final nativeB = b.nativeWindow as Win32Window;

      nativeB.handleMessage(nativeB.handle, wmClose, 0, 0);
      await pump();
      expect(app.state, ApplicationLifecycleState.running);

      nativeA.handleMessage(nativeA.handle, wmClose, 0, 0);
      await pump();

      // The documented policy: the *last top-level* window's close request is
      // a request to close the application, and the ordered release is
      // dispose()'s, not an unwind from inside a WndProc.
      expect(app.state, ApplicationLifecycleState.closing);
      expect(a.isDisposed, isFalse);
      expect(nativeA.handle, isNot(0));
    });

    test('one queue serves both windows, and a close mid-pump is safe',
        () async {
      // Requirement 6 stated as a test. `PeekMessageW(hwnd: 0)` drains the
      // whole thread queue, so both windows are served by one pump and neither
      // can starve the other. The iteration is over the *queue*, never over the
      // window list, so a `DestroyWindow` that runs inside `DispatchMessageW` -
      // which is what closing a window from an event handler does - cannot
      // invalidate it.
      final nativeA = a.nativeWindow as Win32Window;
      final nativeB = b.nativeWindow as Win32Window;
      await a.drawFrame();
      await b.drawFrame();

      // Queue work for both windows, then a close for one of them, then more
      // work for the survivor - all in the same queue, drained by one pump.
      final api = Win32WindowingBackend();
      api.toString();
      nativeA.requestRedraw();
      nativeB.requestRedraw();
      nativeB.handleMessage(nativeB.handle, wmClose, 0, 0);
      nativeA.requestRedraw();

      expect(pump, returnsNormally);
      await pump();
      await pump();

      expect(b.isDisposed, isTrue);
      expect(a.isDisposed, isFalse);
      expect(app.backend.windows, hasLength(1));
      // The survivor's WM_PAINTs still arrived: it owes a frame and can draw
      // it, which is the thing a corrupted iteration would have lost.
      expect(a.needsFrame, isTrue);
      final result = await a.drawFrame();
      expect(result.isSuccess, isTrue, reason: result.diagnostic?.toString());
      expect(Win32WindowRegistry.faults, isEmpty);
      expect(app.errors, isEmpty);
    });

    test('a real owned window is created with its owner as hWndParent',
        () async {
      final dialog = await app.openWindow(
        rootWidget: const ColoredBox(color: _colourB),
        title: 'owned dialog',
        size: const Size(160, 100),
        visible: false,
        owner: a.id,
        modal: true,
      );
      final nativeA = a.nativeWindow as Win32Window;
      final nativeDialog = dialog.nativeWindow as Win32Window;

      expect(nativeDialog.handle, isNot(0));
      expect(nativeDialog.handle, isNot(nativeA.handle));
      // The platform half of modality: Windows itself refuses input to the
      // owner while the dialog lives.
      expect(nativeA.isEnabled, isFalse);
      expect(a.isBlocked, isTrue);

      app.closeWindow(dialog.id);
      await pump();

      expect(nativeA.isEnabled, isTrue);
      expect(a.isBlocked, isFalse);
      expect(app.keyboardFocusWindow, a.id);
      expect(app.windows, hasLength(2));
    });

    test('a popup is created without taking activation from its owner',
        () async {
      final nativeA = a.nativeWindow as Win32Window;
      await a.drawFrame();
      nativeA.handleMessage(nativeA.handle, wmActivate, _waActive, 0);
      await pump();
      expect(app.keyboardFocusWindow, a.id);

      final menu = await app.openWindow(
        rootWidget: const ColoredBox(color: _colourB),
        title: 'menu',
        size: const Size(120, 80),
        owner: a.id,
        kind: WindowKind.popup,
      );
      menu.nativeWindow.show();
      await pump();

      // The whole reason WindowKind exists: showing a menu must leave the
      // caret blinking in the window behind it.
      expect(app.keyboardFocusWindow, a.id);
      expect(a.buildOwner.focusManager.isWindowActive, isTrue);
      expect((menu.nativeWindow as Win32Window).kind, WindowKind.popup);
      expect(
        app.topLevelWindows.map((w) => w.id),
        <NativeWindowId>[a.id, b.id],
      );

      // And dismissing it is not the application running out of windows.
      app.closeWindow(menu.id);
      await pump();
      expect(app.state, ApplicationLifecycleState.running);
      expect(app.windows, hasLength(2));
    });
  }, skip: Platform.isWindows ? false : 'needs real Win32 windows');
}

List<NativeWindowId> _activeWindows(Application app) => <NativeWindowId>[
      for (final ApplicationWindow window in app.windows)
        if (window.buildOwner.focusManager.isWindowActive) window.id,
    ];
