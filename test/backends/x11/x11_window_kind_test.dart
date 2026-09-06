/// `WindowKind` as X11 spells it, tested on the request rather than on a
/// server.
///
/// Everything the X11 backend does about a window's kind is decided before a
/// single byte reaches libxcb: which bit goes into the `CreateWindow` value
/// mask, which `_NET_WM_WINDOW_TYPE` atom is published, and whether
/// `WM_TRANSIENT_FOR` names the owner. Those three decisions are pure - see
/// [X11WindowKindPlan] and [X11CreateWindowAttributes], which exist in that
/// shape precisely so this file can exist - so they are asserted directly,
/// which is the only honest coverage available on a machine with no X server.
///
/// **What this does not prove**: that the server honoured any of it. A popup
/// that asked for `override_redirect` and got a title bar anyway would pass
/// every test here. That half is `X11_POPUP=` in `tool/x11_backend_smoke.dart`,
/// which reads the three values back off a real server with
/// `GetWindowAttributes` and `GetProperty`.
library;

import 'package:dart_ui/src/backends/x11/x11_connection.dart';
import 'package:dart_ui/src/backends/x11/x11_events.dart';
import 'package:dart_ui/src/backends/x11/x11_protocol.dart';
import 'package:dart_ui/src/backends/x11/x11_scale.dart';
import 'package:dart_ui/src/backends/x11/x11_window.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/platform/native_window.dart';
import 'package:dart_ui/src/platform/window_events.dart';
import 'package:test/test.dart';

void main() {
  group('X11WindowKindPlan', () {
    test('only popup and tooltip are override-redirect', () {
      // The bit that makes the window manager not exist for this window. A
      // dialog must stay managed or the user loses the frame they close it
      // with; a normal window must stay managed or it loses placement, the
      // taskbar and the ability to be focused at all.
      expect(X11WindowKindPlan.of(WindowKind.normal).overrideRedirect, isFalse);
      expect(X11WindowKindPlan.of(WindowKind.dialog).overrideRedirect, isFalse);
      expect(X11WindowKindPlan.of(WindowKind.popup).overrideRedirect, isTrue);
      expect(X11WindowKindPlan.of(WindowKind.tooltip).overrideRedirect, isTrue);
    });

    test('each kind publishes its own _NET_WM_WINDOW_TYPE atom', () {
      expect(
        X11WindowKindPlan.of(WindowKind.normal).windowTypeAtom,
        '_NET_WM_WINDOW_TYPE_NORMAL',
      );
      expect(
        X11WindowKindPlan.of(WindowKind.dialog).windowTypeAtom,
        '_NET_WM_WINDOW_TYPE_DIALOG',
      );
      expect(
        X11WindowKindPlan.of(WindowKind.popup).windowTypeAtom,
        '_NET_WM_WINDOW_TYPE_POPUP_MENU',
      );
      expect(
        X11WindowKindPlan.of(WindowKind.tooltip).windowTypeAtom,
        '_NET_WM_WINDOW_TYPE_TOOLTIP',
      );
    });

    test('every type atom this backend can choose is interned up front', () {
      // A type atom interned lazily is a round trip inside the click that
      // opened the menu, and an unmapped window in the meantime.
      for (final kind in WindowKind.values) {
        expect(
          x11WellKnownAtoms,
          contains(X11WindowKindPlan.of(kind).windowTypeAtom),
          reason: '${kind.name} names an atom nobody interns',
        );
      }
    });

    test('an owned window is transient for its owner, a normal one is not', () {
      expect(
        X11WindowKindPlan.of(WindowKind.normal).wantsTransientForOwner,
        isFalse,
      );
      for (final kind in const <WindowKind>[
        WindowKind.dialog,
        WindowKind.popup,
        WindowKind.tooltip,
      ]) {
        expect(
          X11WindowKindPlan.of(kind).wantsTransientForOwner,
          isTrue,
          reason: '${kind.name} belongs to another window',
        );
      }
    });

    test('an unmanaged window is never decorated', () {
      // Not a policy: there is nobody left to draw a frame once the window
      // manager has been told to ignore the window.
      for (final kind in WindowKind.values) {
        final plan = X11WindowKindPlan.of(kind);
        expect(plan.decorated, !plan.overrideRedirect);
      }
    });
  });

  group('X11CreateWindowAttributes', () {
    test('override_redirect adds bit 9 and one word before the event mask', () {
      final attributes = X11CreateWindowAttributes(
        borderPixel: 0x010203,
        eventMask: xcbEventMaskExposure,
        overrideRedirect: true,
      );
      expect(
          attributes.valueMask & xcbCwOverrideRedirect, xcbCwOverrideRedirect);
      // The server reads one word per set bit from the lowest bit upwards, so
      // the boolean must sit between win_gravity (bit 5) and event_mask (11).
      expect(attributes.values, <int>[
        xcbBackPixmapNone,
        0x010203,
        xcbGravityNorthWest,
        xcbGravityNorthWest,
        1,
        xcbEventMaskExposure,
      ]);
    });

    test('without it neither the bit nor the word is there', () {
      final attributes = X11CreateWindowAttributes(
        borderPixel: 0x010203,
        eventMask: xcbEventMaskExposure,
        overrideRedirect: false,
      );
      expect(attributes.valueMask & xcbCwOverrideRedirect, 0);
      expect(attributes.values, <int>[
        xcbBackPixmapNone,
        0x010203,
        xcbGravityNorthWest,
        xcbGravityNorthWest,
        xcbEventMaskExposure,
      ]);
    });

    test('the value list always has one word per set mask bit', () {
      // The invariant the protocol enforces with a BadLength that names
      // nothing. Checked for both shapes so a future attribute cannot be added
      // to one and forgotten in the other.
      for (final overrideRedirect in const <bool>[false, true]) {
        final attributes = X11CreateWindowAttributes(
          borderPixel: 0,
          eventMask: 0,
          overrideRedirect: overrideRedirect,
        );
        var bits = 0;
        for (var bit = 0; bit < 32; bit++) {
          if (attributes.valueMask & (1 << bit) != 0) bits++;
        }
        expect(attributes.values.length, bits);
      }
    });
  });

  group('X11Window.create', () {
    test('a popup and a tooltip are created override-redirect', () {
      for (final kind in const <WindowKind>[
        WindowKind.popup,
        WindowKind.tooltip,
      ]) {
        final client = _FakeWindowClient();
        _create(client, kind: kind);
        final request = client.createRequests.single;
        expect(request.overrideRedirect, isTrue, reason: kind.name);
        // And the value list that request produces really carries the word:
        // this is the seam between the plan and the wire, and the connection
        // builds it from exactly these two arguments.
        final attributes = X11CreateWindowAttributes(
          borderPixel: 0,
          eventMask: xcbEventMaskExposure,
          overrideRedirect: request.overrideRedirect,
        );
        expect(attributes.valueMask & xcbCwOverrideRedirect,
            xcbCwOverrideRedirect);
        expect(attributes.values[4], 1);
      }
    });

    test('a normal window and a dialog are left to the window manager', () {
      for (final kind in const <WindowKind>[
        WindowKind.normal,
        WindowKind.dialog,
      ]) {
        final client = _FakeWindowClient();
        _create(client, kind: kind);
        final request = client.createRequests.single;
        expect(request.overrideRedirect, isFalse, reason: kind.name);
        final attributes = X11CreateWindowAttributes(
          borderPixel: 0,
          eventMask: xcbEventMaskExposure,
          overrideRedirect: request.overrideRedirect,
        );
        expect(attributes.valueMask & xcbCwOverrideRedirect, 0);
        expect(attributes.values.length, 5);
      }
    });

    test('the window type atom follows the kind', () {
      const expected = <WindowKind, String>{
        WindowKind.normal: '_NET_WM_WINDOW_TYPE_NORMAL',
        WindowKind.dialog: '_NET_WM_WINDOW_TYPE_DIALOG',
        WindowKind.popup: '_NET_WM_WINDOW_TYPE_POPUP_MENU',
        WindowKind.tooltip: '_NET_WM_WINDOW_TYPE_TOOLTIP',
      };
      for (final entry in expected.entries) {
        final client = _FakeWindowClient();
        _create(client, kind: entry.key);
        expect(client.createRequests.single.windowTypeAtom, entry.value);
      }
    });

    test('WM_TRANSIENT_FOR names the owner when there is one', () {
      final client = _FakeWindowClient();
      final owner = _create(client, kind: WindowKind.normal);
      for (final kind in const <WindowKind>[
        WindowKind.dialog,
        WindowKind.popup,
        WindowKind.tooltip,
      ]) {
        client.createRequests.clear();
        _create(client, kind: kind, owner: owner);
        expect(
          client.createRequests.single.transientFor,
          owner.xcbWindow,
          reason: '${kind.name} must stay above the window it belongs to',
        );
      }
    });

    test('WM_TRANSIENT_FOR is absent without an owner', () {
      // Zero is "do not write the property at all". Writing it with a window
      // id we do not have would be worse than not writing it: a window manager
      // acts on the value, and it acts by losing the child behind everything.
      for (final kind in WindowKind.values) {
        final client = _FakeWindowClient();
        _create(client, kind: kind);
        expect(client.createRequests.single.transientFor, 0);
      }
    });

    test('a normal window with an owner is still not transient for it', () {
      // The owner exists (the application layer allows one), but a normal
      // window is a top-level window: making it transient would iconify it
      // with the other one and take it out of the taskbar.
      final client = _FakeWindowClient();
      final owner = _create(client, kind: WindowKind.normal);
      client.createRequests.clear();
      _create(client, kind: WindowKind.normal, owner: owner);
      expect(client.createRequests.single.transientFor, 0);
    });

    test('an override-redirect window is never asked to be decorated', () {
      for (final kind in WindowKind.values) {
        final client = _FakeWindowClient();
        _create(client, kind: kind);
        final request = client.createRequests.single;
        expect(request.decorated, !request.overrideRedirect);
      }
    });
  });
}

X11Window _create(
  _FakeWindowClient client, {
  required WindowKind kind,
  NativeWindow? owner,
}) =>
    X11Window.create(
      client: client,
      id: NativeWindowId(client.createRequests.length + 1),
      options: WindowOptions(
        size: const Size(200, 120),
        kind: kind,
        owner: owner,
      ),
      scale: 1,
      desktopScale: 1,
      onClosed: (_) {},
    );

/// Just enough connection for [X11Window.create] to run off an X server.
///
/// Deliberately not an [X11CpuClient]: this file is about the creation
/// request, and a window with no presentation surface exercises exactly the
/// path that builds one.
final class _FakeWindowClient implements X11WindowClient {
  final List<X11TopLevelWindowRequest> createRequests =
      <X11TopLevelWindowRequest>[];
  int _nextWindow = 0x200;

  @override
  int createTopLevelWindow(X11TopLevelWindowRequest request) {
    createRequests.add(request);
    return _nextWindow += 4;
  }

  @override
  int atom(String name) => name.hashCode & 0x7fffffff;

  @override
  X11ServerWindowKind? readWindowKind(int window) => null;

  @override
  int root = 1;

  @override
  bool isDisposed = false;

  @override
  bool isValid = true;

  @override
  final Set<String> extensions = <String>{};

  @override
  X11PhysicalScreen physicalScreen = const X11PhysicalScreen(
    widthInPixels: 1920,
    heightInPixels: 1080,
    widthInMillimetres: 509,
    heightInMillimetres: 286,
  );

  @override
  void destroyTopLevelWindow(int window) {}

  @override
  void mapTopLevelWindow(int window) {}

  @override
  void unmapTopLevelWindow(int window) {}

  @override
  void setTopLevelTitle(int window, String title) {}

  @override
  void configureTopLevelWindow(int window, X11TopLevelBounds bounds) {}

  @override
  void requestTopLevelRedraw(int window, X11RedrawRegion? region) {}

  @override
  bool pollEventInto(X11RawEvent target) => false;

  @override
  bool waitForActivity(int timeoutMilliseconds) => false;

  @override
  ({int x, int y})? translateToRoot(int window) => null;

  @override
  int flush() => 1;

  @override
  void recordError(String message) {}

  @override
  String? readResourceManager() => null;

  @override
  bool signalWake() => true;

  @override
  void dispose() => isDisposed = true;
}
