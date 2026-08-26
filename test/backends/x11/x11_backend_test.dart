import 'dart:async';
import 'dart:typed_data';

import 'package:dart_ui/src/backends/x11/x11_backend.dart';
import 'package:dart_ui/src/backends/x11/x11_clipboard.dart';
import 'package:dart_ui/src/backends/x11/x11_connection.dart';
import 'package:dart_ui/src/backends/x11/x11_drag_drop.dart'
    show X11PropertyValue;
import 'package:dart_ui/src/backends/x11/x11_events.dart';
import 'package:dart_ui/src/backends/x11/x11_keyboard.dart';
import 'package:dart_ui/src/backends/x11/x11_protocol.dart';
import 'package:dart_ui/src/backends/x11/x11_scale.dart';
import 'package:dart_ui/src/backends/x11/x11_surface.dart';
import 'package:dart_ui/src/backends/x11/x11_window.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/platform/clipboard.dart';
import 'package:dart_ui/src/platform/input_events.dart';
import 'package:dart_ui/src/platform/keysyms.dart';
import 'package:dart_ui/src/platform/native_window.dart';
import 'package:dart_ui/src/platform/window_events.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:test/test.dart';

final class _FakeBackendCpuBuffer implements X11CpuBuffer {
  _FakeBackendCpuBuffer(int width, int height)
      : framebuffer = Framebuffer(
          width: width,
          height: height,
          bytesPerRow: width * 4,
          format: PixelFormat.bgra8888Premultiplied,
          pixels: Uint8List(width * height * 4),
        );

  @override
  final Framebuffer framebuffer;
}

final class _FakeConnection
    implements
        X11WindowClient,
        X11CpuClient,
        X11KeyboardClient,
        X11ClipboardClient {
  _FakeConnection({
    this.valid = true,
    this.invalidateDuringInspection = false,
    this.supportsBgraPutImage = false,
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

  /// A sentinel that means "hand out the default two-key map". Null is a
  /// meaningful answer here - a server that refused GetKeyboardMapping - so it
  /// cannot double as "not configured".
  static const Object _keyboardMapUnset = Object();

  /// Either [_keyboardMapUnset], null (the server refused), or an
  /// [X11KeyboardMapping].
  Object? keyboardMapping = _keyboardMapUnset;

  int keyboardMappingReads = 0;
  int modifierMappingReads = 0;

  @override
  int minKeycode = 8;

  @override
  int maxKeycode = 255;

  @override
  X11KeyboardMapping? readKeyboardMapping() {
    keyboardMappingReads++;
    final Object? configured = keyboardMapping;
    if (identical(configured, _keyboardMapUnset)) {
      return X11KeyboardMapping.fromLists(
        <List<int>>[
          <int>[0x61], // 38: a, one alphabetic keysym
          <int>[keysymNoSymbol], // 39
          <int>[keysymNoSymbol], // 40
          <int>[keysymNoSymbol], // 41
          <int>[keysymNoSymbol], // 42
          <int>[keysymNoSymbol], // 43
          <int>[keysymNoSymbol], // 44
          <int>[keysymNoSymbol], // 45
          <int>[0x62], // 46: b
        ],
        firstKeycode: 38,
      );
    }
    return configured as X11KeyboardMapping?;
  }

  @override
  X11ModifierMapping? readModifierMapping() {
    modifierMappingReads++;
    return X11ModifierMapping.fromRows(<List<int>>[
      <int>[50], <int>[], <int>[37], <int>[64], //
      <int>[], <int>[], <int>[], <int>[],
    ]);
  }

  @override
  final bool supportsBgraPutImage;

  @override
  X11CpuBuffer createCpuBuffer({
    required int xcbWindow,
    required int pixelWidth,
    required int pixelHeight,
  }) =>
      _FakeBackendCpuBuffer(pixelWidth, pixelHeight);

  @override
  void destroyCpuBuffer(X11CpuBuffer buffer) {}

  @override
  BackendDiagnostic? presentCpuBuffer({
    required int xcbWindow,
    required X11CpuBuffer buffer,
    required X11CpuDamage damage,
  }) =>
      null;

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
        'CLIPBOARD': 200,
        'UTF8_STRING': 201,
        'TARGETS': 202,
        'TIMESTAMP': 203,
        'INCR': 204,
        'TEXT': 205,
        'text/plain;charset=utf-8': 207,
        x11ClipboardProperty: 208,
      }[name] ??
      0;

  // --- X11ClipboardClient -------------------------------------------------
  //
  // Enough of the selection protocol for the backend's *routing* to be
  // observable. What the state machine does with these is proved in
  // x11_clipboard_test.dart, against a fake built for that job.

  int selectionOwner = 0;
  final List<(int, int, int)> ownerships = <(int, int, int)>[];
  final List<int> convertedTargets = <int>[];
  final List<int> notifiedProperties = <int>[];

  @override
  int getSelectionOwner(int selection) => selectionOwner;

  @override
  void setSelectionOwner(int owner, int selection, int time) {
    ownerships.add((owner, selection, time));
    selectionOwner = owner;
  }

  @override
  void convertSelection({
    required int requestor,
    required int selection,
    required int target,
    required int property,
    required int time,
  }) =>
      convertedTargets.add(target);

  @override
  X11PropertyValue? readPropertyBytes(
    int window,
    int property, {
    required int type,
    bool delete = false,
  }) =>
      null;

  @override
  void deleteWindowProperty(int window, int property) {}

  @override
  void setWindowPropertyBytes(
    int window,
    int property,
    int type,
    Uint8List bytes,
  ) {}

  @override
  void setWindowProperty32(
    int window,
    int property,
    int type,
    List<int> values,
  ) {}

  @override
  void sendSelectionNotify({
    required int requestor,
    required int selection,
    required int target,
    required int property,
    required int time,
  }) =>
      notifiedProperties.add(property);

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
          Capability.pointerInput,
          Capability.scrollInput,
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

    test('advertises CPU presentation only for a compatible visual', () {
      final connection = _FakeConnection(supportsBgraPutImage: true);
      final backend = X11WindowingBackend(
        isLinux: true,
        operatingSystem: 'linux',
        environment: const <String, String>{'DISPLAY': ':55'},
        connectionOpener: (_) => _success(connection),
      );

      final result = backend.probe();

      expect(result.supported, isTrue);
      expect(result.supports(Capability.cpuPresentation), isTrue);
      expect(connection.disposeCalls, 1);
      expect(
        result.diagnostics.map((diagnostic) => diagnostic.message),
        contains('core BGRA PutImage presentation is available'),
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

  group('keyboard', () {
    late _FakeConnection connection;
    late X11WindowingBackend backend;

    setUp(() {
      connection = _FakeConnection(supportsBgraPutImage: true);
      backend = X11WindowingBackend(
        isLinux: true,
        operatingSystem: 'linux',
        environment: const <String, String>{'DISPLAY': ':0'},
        connectionOpener: (_) => _success(connection),
      );
    });

    tearDown(() async {
      await backend.shutdown();
    });

    test('reads both halves of the map once at initialize', () async {
      await backend.initialize();

      expect(connection.keyboardMappingReads, 1);
      expect(connection.modifierMappingReads, 1);
      expect(
        backend.diagnostics.map((item) => item.message),
        contains(contains('keyboard: ')),
      );
    });

    test('claims Capability.keyboardInput once the map was read', () async {
      final result = backend.probe();

      expect(result.supported, isTrue);
      expect(result.capabilities, contains(Capability.keyboardInput));
    });

    test('does not claim the capability when the server refused the map',
        () async {
      connection.keyboardMapping = null;

      final result = backend.probe();

      expect(result.supported, isTrue);
      expect(result.capabilities, isNot(contains(Capability.keyboardInput)));
      expect(
        result.diagnostics.map((item) => item.message),
        contains(contains('no usable keyboard map')),
      );
    });

    test('a KeyPress through the pump becomes a KeyDownEvent and its text',
        () async {
      await backend.initialize();
      final window = await backend.createWindow(
        const WindowOptions(size: Size(100, 80), visible: false),
      ) as X11Window;
      final events = <PlatformWindowEvent>[];
      final subscription = window.events.listen(events.add);

      connection.queuedEvents.add((raw) {
        raw
          ..type = xcbKeyPress
          ..detail = 38
          ..window = window.xcbWindow
          ..timestamp = 900
          ..state = 0;
      });
      backend.pumpEvents();
      await Future<void>.delayed(Duration.zero);

      expect(events.whereType<KeyDownEvent>().single.logicalKey, 0x61);
      expect(events.whereType<TextInputEvent>().single.text, 'a');
      await subscription.cancel();
    });

    test('a window whose map could not be read still gets its KeyEvent',
        () async {
      connection.keyboardMapping = null;
      await backend.initialize();
      final window = await backend.createWindow(
        const WindowOptions(size: Size(100, 80), visible: false),
      ) as X11Window;
      final events = <PlatformWindowEvent>[];
      final subscription = window.events.listen(events.add);

      connection.queuedEvents.add((raw) {
        raw
          ..type = xcbKeyPress
          ..detail = 38
          ..window = window.xcbWindow
          ..timestamp = 900;
      });
      backend.pumpEvents();
      await Future<void>.delayed(Duration.zero);

      final KeyDownEvent down = events.whereType<KeyDownEvent>().single;
      expect(down.physicalKey, 38);
      expect(down.logicalKey, keysymNoSymbol);
      expect(events.whereType<TextInputEvent>(), isEmpty);
      await subscription.cancel();
    });

    test('the server auto-repeat pair becomes one repeated press', () async {
      // Without DetectableAutoRepeat a held key repeats as
      // release-then-press on the same timestamp. A client that believes the
      // release types the character with a spurious key-up between each one.
      await backend.initialize();
      final window = await backend.createWindow(
        const WindowOptions(size: Size(100, 80), visible: false),
      ) as X11Window;
      final events = <PlatformWindowEvent>[];
      final subscription = window.events.listen(events.add);

      void queueKey(int type, int timestamp) {
        connection.queuedEvents.add((raw) {
          raw
            ..type = type
            ..detail = 38
            ..window = window.xcbWindow
            ..timestamp = timestamp
            ..state = 0;
        });
      }

      queueKey(xcbKeyPress, 1000);
      queueKey(xcbKeyRelease, 1050);
      queueKey(xcbKeyPress, 1050);
      queueKey(xcbKeyRelease, 2000);
      backend.pumpEvents();
      await Future<void>.delayed(Duration.zero);

      final List<KeyEvent> keys = events.whereType<KeyEvent>().toList();
      expect(keys, hasLength(3));
      expect(keys[0], isA<KeyDownEvent>());
      expect((keys[0] as KeyDownEvent).isRepeat, isFalse);
      expect(keys[1], isA<KeyDownEvent>());
      expect((keys[1] as KeyDownEvent).isRepeat, isTrue);
      expect(keys[2], isA<KeyUpEvent>());
      expect(events.whereType<TextInputEvent>(), hasLength(2));
      await subscription.cancel();
    });

    test('a release that ends a pump is delivered in that pump', () async {
      // Held until the next event decides what it was - but the pump running
      // dry is that decision, or the keyboard feels stuck for a frame.
      await backend.initialize();
      final window = await backend.createWindow(
        const WindowOptions(size: Size(100, 80), visible: false),
      ) as X11Window;
      final events = <PlatformWindowEvent>[];
      final subscription = window.events.listen(events.add);

      connection.queuedEvents.add((raw) {
        raw
          ..type = xcbKeyRelease
          ..detail = 38
          ..window = window.xcbWindow
          ..timestamp = 1000;
      });
      backend.pumpEvents();
      await Future<void>.delayed(Duration.zero);

      expect(events.whereType<KeyUpEvent>(), hasLength(1));
      await subscription.cancel();
    });

    test('MappingNotify re-reads the map, and a pointer remap does not',
        () async {
      await backend.initialize();
      await backend.createWindow(
        const WindowOptions(size: Size(10, 10), visible: false),
      );
      expect(connection.keyboardMappingReads, 1);

      connection.queuedEvents.add((raw) {
        raw
          ..type = xcbMappingNotify
          ..mode = x11MappingKeyboard;
      });
      backend.pumpEvents();
      expect(connection.keyboardMappingReads, 2);

      connection.queuedEvents.add((raw) {
        raw
          ..type = xcbMappingNotify
          ..mode = x11MappingPointer;
      });
      backend.pumpEvents();
      expect(connection.keyboardMappingReads, 2);
    });

    test('a re-read after MappingNotify changes what the keys type', () async {
      await backend.initialize();
      final window = await backend.createWindow(
        const WindowOptions(size: Size(100, 80), visible: false),
      ) as X11Window;
      final events = <PlatformWindowEvent>[];
      final subscription = window.events.listen(events.add);

      // The user switched to a layout where keycode 38 is `q`.
      connection.keyboardMapping = X11KeyboardMapping.fromLists(
        <List<int>>[
          <int>[0x71]
        ],
        firstKeycode: 38,
      );
      connection.queuedEvents
        ..add((raw) {
          raw
            ..type = xcbMappingNotify
            ..mode = x11MappingKeyboard;
        })
        ..add((raw) {
          raw
            ..type = xcbKeyPress
            ..detail = 38
            ..window = window.xcbWindow
            ..timestamp = 1200;
        });
      backend.pumpEvents();
      await Future<void>.delayed(Duration.zero);

      expect(events.whereType<TextInputEvent>().single.text, 'q');
      await subscription.cancel();
    });

    test('a MappingNotify is never routed to a window as a stale event',
        () async {
      // It names no window at all - byte 4 is `request` - so routing it by
      // window would deliver it to whichever window happened to have that id.
      await backend.initialize();
      final window = await backend.createWindow(
        const WindowOptions(size: Size(100, 80), visible: false),
      ) as X11Window;
      final events = <PlatformWindowEvent>[];
      final subscription = window.events.listen(events.add);

      connection.queuedEvents.add((raw) {
        raw
          ..type = xcbMappingNotify
          ..mode = x11MappingKeyboard
          ..window = window.xcbWindow;
      });
      backend.pumpEvents();
      await Future<void>.delayed(Duration.zero);

      expect(events, isEmpty);
      await subscription.cancel();
    });
  });

  group('clipboard', () {
    late _FakeConnection connection;
    late X11WindowingBackend backend;

    setUp(() {
      connection = _FakeConnection(supportsBgraPutImage: true);
      backend = X11WindowingBackend(
        isLinux: true,
        operatingSystem: 'linux',
        environment: const <String, String>{'DISPLAY': ':0'},
        connectionOpener: (_) => _success(connection),
      );
    });

    tearDown(() async {
      await backend.shutdown();
    });

    test('claims Capability.clipboardText when the connection has selections',
        () {
      final result = backend.probe();

      expect(result.capabilities, contains(Capability.clipboardText));
    });

    test('before initialize the clipboard is a named failure, not a null',
        () async {
      await expectLater(
        backend.clipboard.readText(),
        throwsA(isA<ClipboardException>()),
      );
    });

    test('after initialize the clipboard is the real one', () async {
      await backend.initialize();

      expect(backend.clipboard, isA<X11Clipboard>());
    });

    test('a copy takes ownership with the newest server time seen', () async {
      await backend.initialize();
      final window = await backend.createWindow(
        const WindowOptions(size: Size(10, 10), visible: false),
      ) as X11Window;
      // The backend learns the server clock from the events it drains.
      connection.queuedEvents.add((raw) {
        raw
          ..type = xcbKeyPress
          ..detail = 38
          ..window = window.xcbWindow
          ..timestamp = 7777;
      });
      backend.pumpEvents();

      await backend.clipboard.writeText('copied');

      expect(connection.ownerships.single, (window.xcbWindow, 200, 7777));
    });

    test('a SelectionRequest drained by the pump is answered', () async {
      // The routing proof: the event reaches the manager through pumpEvents
      // rather than through a window, because a selection request is about a
      // transfer and no window owns it.
      await backend.initialize();
      await backend.createWindow(
        const WindowOptions(size: Size(10, 10), visible: false),
      );
      await backend.clipboard.writeText('copied');

      connection.queuedEvents.add((raw) {
        raw
          ..type = xcbSelectionRequest
          ..requestor = 0x900
          ..selection = 200 // CLIPBOARD
          ..target = 201 // UTF8_STRING
          ..property = 300
          ..timestamp = 8000;
      });
      backend.pumpEvents();

      expect(connection.notifiedProperties, <int>[300]);
    });

    test('a SelectionClear drained by the pump drops the payload', () async {
      await backend.initialize();
      await backend.createWindow(
        const WindowOptions(size: Size(10, 10), visible: false),
      );
      await backend.clipboard.writeText('copied');

      connection.queuedEvents
        ..add((raw) {
          raw
            ..type = xcbSelectionClear
            ..selection = 200
            ..timestamp = 8100;
        })
        ..add((raw) {
          raw
            ..type = xcbSelectionRequest
            ..requestor = 0x900
            ..selection = 200
            ..target = 201
            ..property = 300
            ..timestamp = 8200;
        });
      backend.pumpEvents();

      // Nothing answered: we no longer own it, and serving stale text to a
      // requestor that reached us through a race is the bug this prevents.
      expect(connection.notifiedProperties, isEmpty);
    });

    test('shutdown fails a paste that is still waiting for an owner', () async {
      await backend.initialize();
      await backend.createWindow(
        const WindowOptions(size: Size(10, 10), visible: false),
      );
      connection.selectionOwner = 0x900; // somebody else owns CLIPBOARD
      // The matcher is attached before the shutdown, not after: an error on a
      // future nobody is listening to yet is an unhandled async error.
      final Future<void> settled = expectLater(
        backend.clipboard.readText(),
        throwsA(isA<ClipboardException>()),
      );

      await backend.shutdown();

      await settled;
    });
  });
}
