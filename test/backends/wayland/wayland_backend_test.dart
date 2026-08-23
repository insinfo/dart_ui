import 'dart:typed_data';

import 'package:dart_ui/src/backends/wayland/wayland_backend.dart';
import 'package:dart_ui/src/backends/wayland/wayland_connection.dart';
import 'package:dart_ui/src/backends/wayland/wayland_events.dart';
import 'package:dart_ui/src/backends/wayland/wayland_keymap.dart';
import 'package:dart_ui/src/backends/wayland/wayland_shm.dart';
import 'package:dart_ui/src/backends/wayland/wayland_window.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/platform/input_events.dart';
import 'package:dart_ui/src/platform/native_window.dart';
import 'package:dart_ui/src/platform/window_events.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:test/test.dart';

const Map<String, String> _waylandSession = <String, String>{
  'WAYLAND_DISPLAY': 'wayland-1',
  'XDG_RUNTIME_DIR': '/run/user/1000',
};

void main() {
  group('resolveWaylandSocketPath', () {
    test('joins XDG_RUNTIME_DIR and WAYLAND_DISPLAY', () {
      final resolution = resolveWaylandSocketPath(_waylandSession);
      expect(resolution.path, '/run/user/1000/wayland-1');
    });

    test('an absolute WAYLAND_DISPLAY needs no runtime dir', () {
      final resolution = resolveWaylandSocketPath(<String, String>{
        'WAYLAND_DISPLAY': '/tmp/custom-socket',
      });
      expect(resolution.path, '/tmp/custom-socket');
    });

    test('XDG_SESSION_TYPE=wayland supplies the wayland-0 default', () {
      final resolution = resolveWaylandSocketPath(<String, String>{
        'XDG_SESSION_TYPE': 'wayland',
        'XDG_RUNTIME_DIR': '/run/user/7',
      });
      expect(resolution.path, '/run/user/7/wayland-0');
      expect(resolution.detail, contains('wayland-0 default'));
    });

    test('an X11 session yields no path and the reason', () {
      final resolution = resolveWaylandSocketPath(<String, String>{
        'XDG_SESSION_TYPE': 'x11',
        'XDG_RUNTIME_DIR': '/run/user/7',
      });
      expect(resolution.path, isNull);
      expect(resolution.detail, contains('WAYLAND_DISPLAY not set'));
    });

    test('a display name without XDG_RUNTIME_DIR cannot be located', () {
      final resolution = resolveWaylandSocketPath(<String, String>{
        'WAYLAND_DISPLAY': 'wayland-0',
      });
      expect(resolution.path, isNull);
      expect(resolution.detail, contains('XDG_RUNTIME_DIR not set'));
    });
  });

  group('probe', () {
    test('is unsupported off Linux, naming the platform', () {
      final backend = WaylandWindowingBackend(
        isLinux: false,
        operatingSystem: 'windows',
        environment: _waylandSession,
      );
      final result = backend.probe();
      expect(result.supported, isFalse);
      expect(
          result.diagnostics.single.kind, DiagnosticKind.unsupportedPlatform);
    });

    test('is unsupported without session variables, with the reason', () {
      final backend = WaylandWindowingBackend(
        isLinux: true,
        environment: const <String, String>{},
        connectionOpener: (_) => fail('must not try to connect'),
      );
      final result = backend.probe();
      expect(result.supported, isFalse);
      expect(
        result.failures.map((d) => d.message),
        anyElement(contains('no Wayland session detected')),
      );
    });

    test('a healthy connection reports capabilities and is closed', () {
      final client = _FakeWaylandClient();
      String? openedPath;
      final backend = WaylandWindowingBackend(
        isLinux: true,
        environment: _waylandSession,
        connectionOpener: (String path) {
          openedPath = path;
          return WaylandConnectionAttempt(
            connection: client,
            diagnostics: const <BackendDiagnostic>[],
          );
        },
      );

      final result = backend.probe();

      expect(openedPath, '/run/user/1000/wayland-1');
      expect(result.supported, isTrue);
      expect(
        result.capabilities,
        containsAll(<Capability>[
          Capability.window,
          Capability.multipleWindows,
          Capability.pointerInput,
          Capability.scrollInput,
          Capability.keyboardInput,
          Capability.clipboardText,
          Capability.cpuPresentation,
          Capability.orderlyShutdown,
        ]),
      );
      expect(client.isDisposed, isTrue,
          reason: 'a probe connection must not leak');
    });

    test('a failed opener propagates its diagnostics', () {
      final backend = WaylandWindowingBackend(
        isLinux: true,
        environment: _waylandSession,
        connectionOpener: (_) => const WaylandConnectionAttempt(
          connection: null,
          diagnostics: <BackendDiagnostic>[
            BackendDiagnostic(
              kind: DiagnosticKind.connectionFailed,
              message: 'connect refused (synthetic)',
            ),
          ],
        ),
      );
      final result = backend.probe();
      expect(result.supported, isFalse);
      expect(
        result.failures.map((d) => d.message),
        contains('connect refused (synthetic)'),
      );
    });

    test('shm-less connections lose only cpuPresentation', () {
      final client = _FakeWaylandClient()..shmSupported = false;
      final backend = WaylandWindowingBackend(
        isLinux: true,
        environment: _waylandSession,
        connectionOpener: (_) => WaylandConnectionAttempt(
          connection: client,
          diagnostics: const <BackendDiagnostic>[],
        ),
      );
      final result = backend.probe();
      expect(result.supported, isTrue);
      expect(result.capabilities, isNot(contains(Capability.cpuPresentation)));
    });
  });

  group('windows and the event pump', () {
    late _FakeWaylandClient client;
    late WaylandWindowingBackend backend;
    late int nowMilliseconds;

    setUp(() async {
      client = _FakeWaylandClient();
      nowMilliseconds = 0;
      backend = WaylandWindowingBackend(
        isLinux: true,
        environment: _waylandSession,
        connectionOpener: (_) => WaylandConnectionAttempt(
          connection: client,
          diagnostics: const <BackendDiagnostic>[],
        ),
        monotonicMilliseconds: () => nowMilliseconds,
      );
      await backend.initialize();
    });

    tearDown(() async {
      await backend.shutdown();
    });

    Future<WaylandWindow> createWindow({bool resizable = true}) async =>
        await backend.createWindow(WindowOptions(
          size: const Size(640, 480),
          title: 'janela',
          resizable: resizable,
        )) as WaylandWindow;

    void configure(WaylandWindow window, int width, int height, int serial) {
      client.script(WaylandRawEvent()
        ..type = WaylandRawEventType.xdgToplevelConfigure
        ..surfaceId = window.surfaceId
        ..width = width
        ..height = height);
      client.script(WaylandRawEvent()
        ..type = WaylandRawEventType.xdgSurfaceConfigure
        ..surfaceId = window.surfaceId
        ..serial = serial);
    }

    test('createWindow forwards the request and registers the window',
        () async {
      final window = await createWindow();

      final request = client.createRequests.single;
      expect(request.width, 640);
      expect(request.height, 480);
      expect(request.title, 'janela');
      expect(backend.windows, contains(window));
      expect(window.clientSize, const Size(640, 480));
      expect(window.surfaces, isEmpty,
          reason: 'no drawing before the first configure');
    });

    test('the configure cycle acks, builds the surface and emits events',
        () async {
      final window = await createWindow();
      final events = <PlatformWindowEvent>[];
      window.events.listen(events.add);

      configure(window, 800, 600, 41);
      expect(backend.pumpEvents(), isTrue);
      await Future<void>.delayed(Duration.zero);

      expect(client.ackedSerials, <int>[41]);
      expect(window.clientSize, const Size(800, 600));
      expect(window.surfaces, hasLength(1));
      expect(window.cpuSurface!.pixelWidth, 800);
      expect(events.whereType<WindowResizedEvent>(), hasLength(1));
      expect(events.whereType<WindowExposedEvent>(), hasLength(1));
    });

    test('a close request is a question, not a teardown', () async {
      final window = await createWindow();
      final events = <PlatformWindowEvent>[];
      window.events.listen(events.add);

      client.script(WaylandRawEvent()
        ..type = WaylandRawEventType.xdgToplevelClose
        ..surfaceId = window.surfaceId);
      expect(backend.pumpEvents(), isTrue);
      await Future<void>.delayed(Duration.zero);

      expect(events.single, isA<WindowCloseRequestedEvent>());
      expect(window.isDisposed, isFalse);
      expect(backend.windows, contains(window));
    });

    test('closing the last window requests quit on the next pump', () async {
      final window = await createWindow();
      window.close();

      expect(client.destroyedToplevels, hasLength(1));
      expect(backend.windows, isEmpty);
      expect(backend.pumpEvents(), isFalse);
    });

    test('a scale change rebuilds the surface at the new density', () async {
      final window = await createWindow();
      configure(window, 640, 480, 1);
      backend.pumpEvents();
      expect(window.cpuSurface!.pixelWidth, 640);

      client.scale = 2;
      client.script(WaylandRawEvent()..type = WaylandRawEventType.scaleChanged);
      final events = <PlatformWindowEvent>[];
      window.events.listen(events.add);
      backend.pumpEvents();
      await Future<void>.delayed(Duration.zero);

      expect(window.renderScale, 2);
      expect(window.cpuSurface!.pixelWidth, 1280);
      expect(window.cpuSurface!.bufferScale, 2);
      expect(events.whereType<WindowScaleChangedEvent>(), hasLength(1));
    });

    test('pointer events reach only the window they belong to', () async {
      final first = await createWindow();
      final second = await createWindow();
      final firstEvents = <PlatformWindowEvent>[];
      final secondEvents = <PlatformWindowEvent>[];
      first.events.listen(firstEvents.add);
      second.events.listen(secondEvents.add);

      client.script(WaylandRawEvent()
        ..type = WaylandRawEventType.pointerEnter
        ..surfaceId = second.surfaceId);
      backend.pumpEvents();
      await Future<void>.delayed(Duration.zero);

      expect(firstEvents, isEmpty);
      expect(secondEvents.single, isA<WindowPointerEnterEvent>());
    });

    test('key repeat follows compositor delay/rate and clamps blocking wait',
        () async {
      final window = await createWindow();
      final events = <PlatformWindowEvent>[];
      window.events.listen(events.add);
      client
        ..repeatRateHz = 20
        ..repeatDelayMilliseconds = 300;
      client.script(WaylandRawEvent()
        ..type = WaylandRawEventType.keyboardKey
        ..surfaceId = window.surfaceId
        ..key = 30 // evdev KEY_A
        ..state = 1);

      backend.pumpEvents();
      backend.pumpEvents(timeout: const Duration(seconds: 1));
      expect(client.waitTimeouts.last, 300,
          reason: 'the event wait must wake for the repeat deadline');

      nowMilliseconds = 300;
      backend.pumpEvents();
      await Future<void>.delayed(Duration.zero);

      final downs = events.whereType<KeyDownEvent>().toList();
      expect(downs, hasLength(2));
      expect(downs.first.isRepeat, isFalse);
      expect(downs.last.isRepeat, isTrue);
    });

    test('a lost connection stops the pump with a diagnostic', () async {
      await createWindow();
      client.isValidFlag = false;

      expect(backend.pumpEvents(), isFalse);
      expect(
        backend.diagnostics.map((d) => d.message),
        anyElement(contains('connection was lost')),
      );
    });

    test('wake reaches the connection doorbell', () {
      backend.wake();
      expect(client.wakeCalls, 1);
    });

    test('backend clipboard delegates text to the Wayland selection client',
        () async {
      await backend.clipboard.writeText('texto Wayland');
      expect(client.clipboardText, 'texto Wayland');
      expect(await backend.clipboard.readText(), 'texto Wayland');
    });

    test('setTitle and hide are forwarded', () async {
      final window = await createWindow();
      window.setTitle('novo título');
      window.hide();

      expect(client.titles.single.title, 'novo título');
      expect(client.hiddenToplevels, hasLength(1));
    });
  });
}

// ---------------------------------------------------------------------------
// Fake connection
// ---------------------------------------------------------------------------

final class _FakeShmBuffer implements WaylandShmBufferHandle {
  _FakeShmBuffer(int width, int height)
      : framebuffer = Framebuffer(
          width: width,
          height: height,
          bytesPerRow: width * 4,
          format: PixelFormat.bgra8888Premultiplied,
          pixels: Uint8List(width * height * 4),
        );

  @override
  final Framebuffer framebuffer;

  @override
  bool get isBusy => false;
}

final class _FakeWaylandClient
    implements WaylandWindowClient, WaylandCpuClient, WaylandSelectionClient {
  bool isValidFlag = true;
  bool shmSupported = true;
  bool clipboardSupported = true;
  String? clipboardText;
  int scale = 1;
  int wakeCalls = 0;
  int _nextId = 10;

  final List<WaylandToplevelRequest> createRequests =
      <WaylandToplevelRequest>[];
  final List<WaylandToplevelIds> destroyedToplevels = <WaylandToplevelIds>[];
  final List<WaylandToplevelIds> hiddenToplevels = <WaylandToplevelIds>[];
  final List<({WaylandToplevelIds ids, String title})> titles =
      <({WaylandToplevelIds ids, String title})>[];
  final List<int> ackedSerials = <int>[];
  final List<String> errors = <String>[];
  final List<_FakeShmBuffer> buffers = <_FakeShmBuffer>[];
  final List<WaylandCpuDamage> presentedDamage = <WaylandCpuDamage>[];
  final List<WaylandRawEvent> _scripted = <WaylandRawEvent>[];
  final List<int> waitTimeouts = <int>[];

  void script(WaylandRawEvent event) => _scripted.add(event);

  @override
  bool isDisposed = false;

  @override
  void dispose() => isDisposed = true;

  @override
  bool get isValid => isValidFlag && !isDisposed;

  @override
  final Set<String> globalInterfaces = <String>{
    'wl_compositor',
    'wl_shm',
    'wl_seat',
    'wl_output',
    'xdg_wm_base',
  };

  @override
  bool signalWake() {
    wakeCalls++;
    return true;
  }

  @override
  WaylandToplevelIds createToplevel(WaylandToplevelRequest request) {
    createRequests.add(request);
    return WaylandToplevelIds(
      surfaceId: _nextId++,
      xdgSurfaceId: _nextId++,
      toplevelId: _nextId++,
    );
  }

  @override
  void destroyToplevel(WaylandToplevelIds ids) => destroyedToplevels.add(ids);

  @override
  void setToplevelTitle(WaylandToplevelIds ids, String title) {
    titles.add((ids: ids, title: title));
  }

  @override
  void ackConfigure(WaylandToplevelIds ids, int serial) {
    ackedSerials.add(serial);
  }

  @override
  void hideToplevel(WaylandToplevelIds ids) => hiddenToplevels.add(ids);

  @override
  bool pollEventInto(WaylandRawEvent target) {
    if (_scripted.isEmpty) return false;
    final next = _scripted.removeAt(0);
    target
      ..reset()
      ..type = next.type
      ..surfaceId = next.surfaceId
      ..serial = next.serial
      ..timeMilliseconds = next.timeMilliseconds
      ..width = next.width
      ..height = next.height
      ..key = next.key
      ..state = next.state
      ..axis = next.axis
      ..x = next.x
      ..y = next.y
      ..axisValue = next.axisValue
      ..stateFlags = next.stateFlags;
    return true;
  }

  @override
  bool waitForActivity(int timeoutMilliseconds) {
    waitTimeouts.add(timeoutMilliseconds);
    return false;
  }

  @override
  int flush() => 1;

  @override
  void recordError(String message) => errors.add(message);

  @override
  WaylandXkbKeymap? keymap = WaylandXkbKeymap.usFallback();

  @override
  final WaylandModifiersState modifiers = WaylandModifiersState();

  @override
  int get bufferScaleHint => scale;

  @override
  int repeatRateHz = 25;

  @override
  int repeatDelayMilliseconds = 400;

  @override
  bool get supportsClipboard => clipboardSupported;

  @override
  void setClipboardText(String text) => clipboardText = text;

  @override
  Future<String?> readClipboardText() async => clipboardText;

  @override
  bool get supportsShmPresentation => shmSupported;

  @override
  WaylandShmBufferHandle createShmBuffer({
    required int pixelWidth,
    required int pixelHeight,
  }) {
    final buffer = _FakeShmBuffer(pixelWidth, pixelHeight);
    buffers.add(buffer);
    return buffer;
  }

  @override
  void destroyShmBuffer(WaylandShmBufferHandle buffer) {}

  @override
  BackendDiagnostic? presentShmBuffer({
    required int surfaceId,
    required WaylandShmBufferHandle buffer,
    required WaylandCpuDamage damage,
    required int bufferScale,
  }) {
    presentedDamage.add(damage);
    return null;
  }
}
