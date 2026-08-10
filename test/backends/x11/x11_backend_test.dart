import 'dart:async';

import 'package:dart_ui/src/backends/x11/x11_backend.dart';
import 'package:dart_ui/src/backends/x11/x11_connection.dart';
import 'package:dart_ui/src/backends/x11/x11_events.dart';
import 'package:dart_ui/src/backends/x11/x11_protocol.dart';
import 'package:dart_ui/src/backends/x11/x11_scale.dart';
import 'package:dart_ui/src/backends/x11/x11_window.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/platform/native_window.dart';
import 'package:dart_ui/src/platform/window_events.dart';
import 'package:test/test.dart';

final class _FakeConnection implements X11WindowClient {
  _FakeConnection({
    this.valid = true,
    this.invalidateDuringInspection = false,
    this.resourceManager,
    Set<String> extensions = const <String>{},
    X11PhysicalScreen? screen,
  })  : extensions = Set<String>.of(extensions),
        physicalScreen = screen ??
            const X11PhysicalScreen(
              widthInPixels: 1920,
              heightInPixels: 1080,
              widthInMillimetres: 509,
              heightInMillimetres: 286,
            );

  bool valid;
  final bool invalidateDuringInspection;
  final String? resourceManager;

  @override
  final Set<String> extensions;

  @override
  final X11PhysicalScreen physicalScreen;

  @override
  bool isDisposed = false;

  int disposeCalls = 0;
  int wakeCalls = 0;
  int nextWindow = 100;
  int waitCalls = 0;
  final List<int> destroyedWindows = <int>[];
  final List<X11TopLevelWindowRequest> createRequests =
      <X11TopLevelWindowRequest>[];
  final List<void Function(X11RawEvent)> queuedEvents =
      <void Function(X11RawEvent)>[];
  final List<String> recordedErrors = <String>[];

  @override
  int root = 1;

  @override
  int atom(String name) =>
      <String, int>{
        'WM_PROTOCOLS': 10,
        'WM_DELETE_WINDOW': 11,
        '_NET_WM_STATE': 12,
        'WM_STATE': 13,
      }[name] ??
      0;

  @override
  int createTopLevelWindow(X11TopLevelWindowRequest request) {
    createRequests.add(request);
    return nextWindow++;
  }

  @override
  void destroyTopLevelWindow(int window) => destroyedWindows.add(window);

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
  bool pollEventInto(X11RawEvent target) {
    if (queuedEvents.isEmpty) return false;
    queuedEvents.removeAt(0)(target);
    return true;
  }

  @override
  bool waitForActivity(int timeoutMilliseconds) {
    waitCalls++;
    return queuedEvents.isNotEmpty;
  }

  @override
  ({int x, int y})? translateToRoot(int window) => null;

  @override
  int flush() => 1;

  @override
  void recordError(String message) => recordedErrors.add(message);

  @override
  bool get isValid => valid && !isDisposed;

  @override
  String? readResourceManager() {
    if (invalidateDuringInspection) valid = false;
    return resourceManager;
  }

  @override
  bool signalWake() {
    wakeCalls++;
    return true;
  }

  @override
  void dispose() {
    if (isDisposed) return;
    isDisposed = true;
    disposeCalls++;
  }
}

X11ConnectionAttempt _success(_FakeConnection connection) {
  return X11ConnectionAttempt(
    connection: connection,
    diagnostics: const <BackendDiagnostic>[
      BackendDiagnostic.note('fake X11 connection opened'),
    ],
  );
}

void main() {
  group('probe', () {
    test('rejects another OS before trying to load or connect', () {
      var openCalls = 0;
      final backend = X11WindowingBackend(
        isLinux: false,
        operatingSystem: 'windows',
        environment: const <String, String>{'DISPLAY': ':0'},
        connectionOpener: (_) {
          openCalls++;
          return const X11ConnectionAttempt(
            connection: null,
            diagnostics: <BackendDiagnostic>[],
          );
        },
      );

      final result = backend.probe();

      expect(result.supported, isFalse);
      expect(result.capabilities, isEmpty);
      expect(result.failures.single.kind, DiagnosticKind.unsupportedPlatform);
      expect(result.failures.single.detail, contains('windows'));
      expect(openCalls, 0);
    });

    test('requires DISPLAY before opening a connection', () {
      var openCalls = 0;
      final backend = X11WindowingBackend(
        isLinux: true,
        operatingSystem: 'linux',
        environment: const <String, String>{},
        connectionOpener: (_) {
          openCalls++;
          return const X11ConnectionAttempt(
            connection: null,
            diagnostics: <BackendDiagnostic>[],
          );
        },
      );

      final result = backend.probe();

      expect(result.supported, isFalse);
      expect(result.capabilities, isEmpty);
      expect(result.failures.single.message, 'DISPLAY not set');
      expect(openCalls, 0);
    });

    test('opens, inspects and closes a temporary connection', () {
      final connection = _FakeConnection(
        resourceManager: 'Xft.dpi: 144',
        extensions: const <String>{'RANDR', 'MIT-SHM'},
      );
      final backend = X11WindowingBackend(
        isLinux: true,
        operatingSystem: 'linux',
        environment: const <String, String>{'DISPLAY': ':77'},
        connectionOpener: (display) {
          expect(display, ':77');
          return _success(connection);
        },
      );

      final result = backend.probe();

      expect(result.supported, isTrue);
      expect(
        result.capabilities,
        containsAll(<Capability>[
          Capability.window,
          Capability.multipleWindows,
          Capability.orderlyShutdown,
        ]),
      );
      expect(backend.scale?.scale, 1.5);
      expect(backend.scale?.source, X11ScaleSource.xftDpi);
      expect(connection.disposeCalls, 1);
      expect(
        result.diagnostics.map((item) => item.message).join('\n'),
        contains('core window lifecycle is available'),
      );
      expect(
        result.diagnostics.map((item) => item.message).join('\n'),
        contains('randr=yes'),
      );
    });

    test('rejects a connection that becomes invalid during inspection', () {
      final connection = _FakeConnection(invalidateDuringInspection: true);
      final backend = X11WindowingBackend(
        isLinux: true,
        environment: const <String, String>{'DISPLAY': ':78'},
        connectionOpener: (_) => _success(connection),
      );

      final result = backend.probe();

      expect(result.supported, isFalse);
      expect(connection.disposeCalls, 1);
      expect(
        result.failures.map((item) => item.message),
        contains('X11 connection became invalid after probe inspection'),
      );
      expect(
        result.failures.map((item) => item.kind),
        isNot(contains(DiagnosticKind.rejectedByPolicy)),
      );
    });

    test('reports opener failure and does not claim support', () {
      final backend = X11WindowingBackend(
        isLinux: true,
        environment: const <String, String>{'DISPLAY': ':88'},
        connectionOpener: (_) => const X11ConnectionAttempt(
          connection: null,
          diagnostics: <BackendDiagnostic>[
            BackendDiagnostic(
              kind: DiagnosticKind.connectionFailed,
              message: 'synthetic refusal',
            ),
          ],
        ),
      );

      final result = backend.probe();

      expect(result.supported, isFalse);
      expect(result.capabilities, isEmpty);
      expect(result.failures.map((item) => item.message),
          contains('synthetic refusal'));
      expect(backend.diagnostics, result.diagnostics);
    });

    test('turns an opener exception into a diagnostic', () {
      final backend = X11WindowingBackend(
        isLinux: true,
        environment: const <String, String>{'DISPLAY': ':89'},
        connectionOpener: (_) => throw StateError('synthetic opener crash'),
      );

      final result = backend.probe();

      expect(result.supported, isFalse);
      expect(
        result.failures.map((item) => item.message),
        contains('X11 connection opener threw'),
      );
    });
  });

  group('connection ownership', () {
    test('initialize owns one connection and shutdown closes it once',
        () async {
      final connection = _FakeConnection();
      var openCalls = 0;
      final backend = X11WindowingBackend(
        isLinux: true,
        environment: const <String, String>{'DISPLAY': ':99'},
        connectionOpener: (_) {
          openCalls++;
          return _success(connection);
        },
      );

      await backend.initialize();
      await backend.initialize();
      expect(openCalls, 1);
      expect(connection.disposeCalls, 0);

      backend.wake();
      expect(connection.wakeCalls, 1);

      await backend.shutdown();
      await backend.shutdown();
      expect(connection.disposeCalls, 1);

      backend.wake();
      expect(connection.wakeCalls, 1);
    });

    test('initialize failure carries the real connection diagnostic', () async {
      final backend = X11WindowingBackend(
        isLinux: true,
        environment: const <String, String>{'DISPLAY': ':100'},
        connectionOpener: (_) => const X11ConnectionAttempt(
          connection: null,
          diagnostics: <BackendDiagnostic>[
            BackendDiagnostic(
              kind: DiagnosticKind.connectionFailed,
              message: 'xcb_connect failed in test',
            ),
          ],
        ),
      );

      await expectLater(
        backend.initialize(),
        throwsA(
          isA<BackendSelectionError>()
              .having((error) => error.requested, 'requested', 'x11')
              .having(
                (error) =>
                    error.attempts.single.failures.map((item) => item.message),
                'failures',
                contains('xcb_connect failed in test'),
              ),
        ),
      );
      await backend.shutdown();
    });

    test('invalid returned connection is disposed and rejected', () async {
      final connection = _FakeConnection(valid: false);
      final backend = X11WindowingBackend(
        isLinux: true,
        environment: const <String, String>{'DISPLAY': ':101'},
        connectionOpener: (_) => _success(connection),
      );

      await expectLater(
        backend.initialize(),
        throwsA(isA<BackendSelectionError>()),
      );
      expect(connection.disposeCalls, 1);
    });

    test('initialize revalidates the connection after inspection', () async {
      final connection = _FakeConnection(invalidateDuringInspection: true);
      final backend = X11WindowingBackend(
        isLinux: true,
        environment: const <String, String>{'DISPLAY': ':102'},
        connectionOpener: (_) => _success(connection),
      );

      await expectLater(
        backend.initialize(),
        throwsA(
          isA<BackendSelectionError>().having(
            (error) =>
                error.attempts.single.failures.map((item) => item.message),
            'failures',
            contains(
              'X11 connection became invalid after initialization inspection',
            ),
          ),
        ),
      );
      expect(connection.disposeCalls, 1);
      backend.wake();
      expect(connection.wakeCalls, 0);
    });
  });

  group('window lifecycle and pump', () {
    late _FakeConnection connection;
    late X11WindowingBackend backend;

    setUp(() async {
      connection = _FakeConnection();
      backend = X11WindowingBackend(
        isLinux: true,
        environment: const <String, String>{'DISPLAY': ':103'},
        connectionOpener: (_) => _success(connection),
      );
      await backend.initialize();
    });

    tearDown(() => backend.shutdown());

    test('creates stable framework ids and shuts XIDs down in reverse',
        () async {
      final first = await backend.createWindow(
        const WindowOptions(size: Size(320, 200), visible: false),
      );
      final second = await backend.createWindow(
        const WindowOptions(size: Size(640, 480), visible: false),
      );

      expect(first, isA<X11Window>());
      expect(second, isA<X11Window>());
      expect(first.id.value, 1);
      expect(second.id.value, 2);
      expect(backend.windows, <NativeWindow>[first, second]);
      expect(
          connection.createRequests.map((item) => item.width), <int>[320, 640]);
      expect(first.surfaces, isEmpty);

      await backend.shutdown();

      expect(connection.destroyedWindows, <int>[101, 100]);
      expect(connection.disposeCalls, 1);
      expect(backend.windows, isEmpty);
    });

    test('routes and coalesces native events by XID', () async {
      final window = await backend.createWindow(
        const WindowOptions(size: Size(100, 80), visible: false),
      ) as X11Window;
      final events = <PlatformWindowEvent>[];
      final subscription = window.events.listen(events.add);
      connection.queuedEvents
        ..add((raw) {
          raw
            ..type = xcbConfigureNotify
            ..window = window.xcbWindow
            ..x = 3
            ..y = 4
            ..width = 150
            ..height = 90
            ..synthetic = false;
        })
        ..add((raw) {
          raw
            ..type = xcbExpose
            ..window = window.xcbWindow
            ..x = 2
            ..y = 5
            ..width = 20
            ..height = 10;
        });

      expect(backend.pumpEvents(), isTrue);
      await Future<void>.delayed(Duration.zero);

      expect(events.whereType<WindowResizedEvent>(), hasLength(1));
      expect(events.whereType<WindowMovedEvent>(), hasLength(1));
      expect(events.whereType<WindowExposedEvent>(), hasLength(1));
      expect(window.clientSize, const Size(150, 90));
      expect(window.generation, 1);
      await subscription.cancel();
    });

    test('waits only when the queue starts empty', () async {
      await backend.createWindow(
        const WindowOptions(size: Size(10, 10), visible: false),
      );

      expect(
        backend.pumpEvents(timeout: const Duration(milliseconds: 7)),
        isTrue,
      );
      expect(connection.waitCalls, 1);
    });

    test('closing the last window requests application quit', () async {
      final window = await backend.createWindow(
        const WindowOptions(size: Size(10, 10), visible: false),
      );

      window.close();

      expect(backend.windows, isEmpty);
      expect(
        backend.pumpEvents(timeout: const Duration(microseconds: -1)),
        isFalse,
      );
      expect(connection.waitCalls, 0);
      expect(connection.destroyedWindows, <int>[100]);
    });

    test('a lost X server terminates the pump with one diagnostic', () async {
      await backend.createWindow(
        const WindowOptions(size: Size(10, 10), visible: false),
      );
      connection.valid = false;

      expect(backend.pumpEvents(), isFalse);
      expect(backend.pumpEvents(), isFalse);
      expect(
        backend.diagnostics
            .where((item) => item.message.contains('connection was lost')),
        hasLength(1),
      );
    });

    test('records X errors instead of routing them to a window', () async {
      await backend.createWindow(
        const WindowOptions(size: Size(10, 10), visible: false),
      );
      connection.queuedEvents.add((raw) {
        raw
          ..type = xcbError
          ..errorCode = 3
          ..majorOpcode = 1
          ..minorOpcode = 0
          ..resourceId = 100
          ..sequence = 7;
      });

      backend.pumpEvents();

      expect(connection.recordedErrors.single, contains('CreateWindow'));
    });
  });
}
