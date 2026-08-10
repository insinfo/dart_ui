import 'dart:async';
import 'dart:typed_data';

import 'package:dart_ui/src/backends/x11/x11_connection.dart';
import 'package:dart_ui/src/backends/x11/x11_events.dart';
import 'package:dart_ui/src/backends/x11/x11_protocol.dart';
import 'package:dart_ui/src/backends/x11/x11_scale.dart';
import 'package:dart_ui/src/backends/x11/x11_surface.dart';
import 'package:dart_ui/src/backends/x11/x11_window.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/platform/input_events.dart';
import 'package:dart_ui/src/platform/native_window.dart';
import 'package:dart_ui/src/platform/window_events.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:test/test.dart';

final class _FakeCpuBuffer implements X11CpuBuffer {
  _FakeCpuBuffer(int width, int height)
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

final class _FakeX11WindowClient implements X11WindowClient, X11CpuClient {
  final int nextWindow = 0x220011;

  @override
  int root = 0x100;

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

  final List<X11TopLevelWindowRequest> createRequests =
      <X11TopLevelWindowRequest>[];
  final List<int> destroyedWindows = <int>[];
  final List<int> mappedWindows = <int>[];
  final List<int> unmappedWindows = <int>[];
  final List<({int window, String title})> titles =
      <({int window, String title})>[];
  final List<({int window, X11TopLevelBounds bounds})> bounds =
      <({int window, X11TopLevelBounds bounds})>[];
  final List<({int window, X11RedrawRegion? region})> redraws =
      <({int window, X11RedrawRegion? region})>[];
  final List<String> errors = <String>[];
  final List<_FakeCpuBuffer> createdBuffers = <_FakeCpuBuffer>[];
  final List<X11CpuBuffer> destroyedBuffers = <X11CpuBuffer>[];
  final List<X11CpuDamage> presentedDamage = <X11CpuDamage>[];
  final List<String> teardownOrder = <String>[];

  int flushCalls = 0;
  int wakeCalls = 0;
  ({int x, int y})? translatedOrigin;
  bool cpuSupported = false;

  @override
  bool get supportsBgraPutImage => cpuSupported;

  @override
  X11CpuBuffer createCpuBuffer({
    required int xcbWindow,
    required int pixelWidth,
    required int pixelHeight,
  }) {
    final buffer = _FakeCpuBuffer(pixelWidth, pixelHeight);
    createdBuffers.add(buffer);
    return buffer;
  }

  @override
  void destroyCpuBuffer(X11CpuBuffer buffer) {
    destroyedBuffers.add(buffer);
    teardownOrder.add('surface');
  }

  @override
  BackendDiagnostic? presentCpuBuffer({
    required int xcbWindow,
    required X11CpuBuffer buffer,
    required X11CpuDamage damage,
  }) {
    presentedDamage.add(damage);
    return null;
  }

  @override
  int atom(String name) => switch (name) {
        'WM_PROTOCOLS' => 101,
        'WM_DELETE_WINDOW' => 102,
        '_NET_WM_STATE' => 103,
        'WM_STATE' => 104,
        _ => 0,
      };

  @override
  int createTopLevelWindow(X11TopLevelWindowRequest request) {
    createRequests.add(request);
    return nextWindow;
  }

  @override
  void destroyTopLevelWindow(int window) {
    destroyedWindows.add(window);
    teardownOrder.add('window');
  }

  @override
  void mapTopLevelWindow(int window) => mappedWindows.add(window);

  @override
  void unmapTopLevelWindow(int window) => unmappedWindows.add(window);

  @override
  void setTopLevelTitle(int window, String title) {
    titles.add((window: window, title: title));
  }

  @override
  void configureTopLevelWindow(int window, X11TopLevelBounds value) {
    bounds.add((window: window, bounds: value));
  }

  @override
  void requestTopLevelRedraw(int window, X11RedrawRegion? region) {
    redraws.add((window: window, region: region));
  }

  @override
  ({int x, int y})? translateToRoot(int window) => translatedOrigin;

  @override
  int flush() {
    flushCalls++;
    return 1;
  }

  @override
  void recordError(String message) => errors.add(message);

  @override
  bool pollEventInto(X11RawEvent target) => false;

  @override
  bool waitForActivity(int timeoutMilliseconds) => false;

  @override
  String? readResourceManager() => null;

  @override
  bool signalWake() {
    wakeCalls++;
    return true;
  }

  @override
  void dispose() => isDisposed = true;
}

X11Window _createWindow(
  _FakeX11WindowClient client, {
  WindowOptions options = const WindowOptions(size: Size(100, 80)),
  double scale = 1,
  double? desktopScale,
  void Function(X11Window window)? onClosed,
}) {
  return X11Window.create(
    client: client,
    id: const NativeWindowId(7),
    options: options,
    scale: scale,
    desktopScale: desktopScale ?? scale,
    onClosed: onClosed ?? (_) {},
  );
}

X11RawEvent _raw({
  required int type,
  int window = 0x220011,
  bool synthetic = false,
  int x = 0,
  int y = 0,
  int width = 0,
  int height = 0,
  int detail = 0,
  int timestamp = 0,
}) {
  return X11RawEvent()
    ..type = type
    ..window = window
    ..synthetic = synthetic
    ..x = x
    ..y = y
    ..width = width
    ..height = height
    ..detail = detail
    ..timestamp = timestamp;
}

void main() {
  test('creation converts logical geometry and exposes scale and identity', () {
    final client = _FakeX11WindowClient();
    final window = _createWindow(
      client,
      scale: 1.5,
      desktopScale: 1.25,
      options: const WindowOptions(
        size: Size(100.25, 80),
        position: Offset(10.4, -4.4),
        title: 'Janela λ',
        resizable: false,
        decorated: false,
        visible: true,
      ),
    );
    addTearDown(window.dispose);

    expect(client.createRequests, hasLength(1));
    final request = client.createRequests.single;
    expect(request.width, 151);
    expect(request.height, 120);
    expect(request.x, 16);
    expect(request.y, -7);
    expect(request.title, 'Janela λ');
    expect(request.resizable, isFalse);
    expect(request.decorated, isFalse);
    expect(request.visible, isTrue);

    expect(window.id, const NativeWindowId(7));
    expect(window.xcbWindow, client.nextWindow);
    expect(window.pixelSize, (width: 151, height: 120));
    expect(window.clientSize, const Size(151 / 1.5, 80));
    expect(window.renderScale, 1.5);
    expect(window.desktopScale, 1.25);
    expect(window.generation, 0);
    expect(window.state, WindowState.normal);
    expect(window.surfaces, isEmpty);

    // A window created visible is already mapped; show must not map twice.
    window.show();
    expect(client.mappedWindows, isEmpty);
  });

  test('show and hide are idempotent for an initially hidden window', () {
    final client = _FakeX11WindowClient();
    final window = _createWindow(
      client,
      options: const WindowOptions(
        size: Size(40, 30),
        visible: false,
      ),
    );
    addTearDown(window.dispose);

    window.hide();
    window.show();
    window.show();
    window.hide();
    window.hide();

    expect(client.mappedWindows, <int>[client.nextWindow]);
    expect(client.unmappedWindows, <int>[client.nextWindow]);
  });

  test('title, bounds, cursor and redraw operations use device pixels', () {
    final client = _FakeX11WindowClient();
    final window = _createWindow(client, scale: 1.5);
    addTearDown(window.dispose);

    window.setTitle('Novo título');
    window.setBounds(const Rect.fromLTWH(-10.4, 20.4, 100.1, 50.1));
    window.setCursor(SystemCursor.hand);
    window.requestRedraw();
    window.requestRedraw(const Rect.fromLTRB(0.2, 1.1, 10.1, 20.4));

    expect(
      client.titles,
      <({int window, String title})>[
        (window: client.nextWindow, title: 'Novo título'),
      ],
    );
    expect(client.flushCalls, 1);

    final configured = client.bounds.single;
    expect(configured.window, client.nextWindow);
    expect(configured.bounds.x, -16);
    expect(configured.bounds.y, 31);
    expect(configured.bounds.width, 151);
    expect(configured.bounds.height, 76);
    expect(window.cursor, SystemCursor.hand);

    expect(client.redraws, hasLength(2));
    expect(client.redraws.first.window, client.nextWindow);
    expect(client.redraws.first.region, isNull);
    final damage = client.redraws.last.region!;
    expect(damage.x, 0);
    expect(damage.y, 1);
    expect(damage.width, 16);
    expect(damage.height, 30);
  });

  test('coalesced resize bumps generation once and emits the final size',
      () async {
    final client = _FakeX11WindowClient();
    final window = _createWindow(client, scale: 2);
    addTearDown(window.dispose);
    final events = <PlatformWindowEvent>[];
    final subscription = window.events.listen(events.add);
    addTearDown(subscription.cancel);

    expect(
      window.handleRawEvent(
        _raw(type: xcbConfigureNotify, width: 300, height: 200),
      ),
      isTrue,
    );
    window.handleRawEvent(
      _raw(type: xcbConfigureNotify, width: 640, height: 480),
    );
    window.flushPendingEvents();
    await Future<void>.delayed(Duration.zero);

    expect(window.generation, 1);
    expect(window.pixelSize, (width: 640, height: 480));
    expect(window.clientSize, const Size(320, 240));
    expect(events.whereType<WindowResizedEvent>(), hasLength(1));
    final resized = events.whereType<WindowResizedEvent>().single;
    expect(resized.generation, 1);
    expect(resized.clientSize, const Size(320, 240));
    expect(resized.renderScale, 2);
  });

  test('core pointer input is emitted immediately in logical coordinates',
      () async {
    final client = _FakeX11WindowClient();
    final window = _createWindow(client, scale: 2);
    addTearDown(window.dispose);
    final events = <PlatformWindowEvent>[];
    final subscription = window.events.listen(events.add);
    addTearDown(subscription.cancel);

    window.handleRawEvent(
      _raw(
        type: xcbMotionNotify,
        x: -20,
        y: 30,
        timestamp: 99,
      ),
    );
    window.handleRawEvent(
      _raw(type: xcbButtonPress, detail: 1, x: 40, y: 10),
    );
    window.handleRawEvent(_raw(type: xcbEnterNotify));
    window.handleRawEvent(_raw(type: xcbLeaveNotify));
    await Future<void>.delayed(Duration.zero);

    expect(events, hasLength(4));
    final move = events[0] as PointerMoveEvent;
    expect(move.logicalPosition, const Offset(-10, 15));
    expect(move.timestamp, const Duration(milliseconds: 99));
    final down = events[1] as PointerDownEvent;
    expect(down.logicalPosition, const Offset(20, 5));
    expect(down.button, PointerButton.primary);
    expect(events[2], isA<WindowPointerEnterEvent>());
    expect(events[3], isA<WindowPointerLeaveEvent>());
  });

  test('CPU surface is replaced on resize and freed before its XID', () {
    final client = _FakeX11WindowClient()..cpuSupported = true;
    final window = _createWindow(client);

    final first = window.cpuSurface!;
    expect(first.generation, 0);
    expect(first.pixelWidth, 100);
    expect(first.pixelHeight, 80);
    first.framebuffer.clear(0x10, 0x20, 0x30, 0xff);
    expect(window.present(), isNull);
    expect(
      client.presentedDamage,
      <X11CpuDamage>[
        const X11CpuDamage(x: 0, y: 0, width: 100, height: 80),
      ],
    );

    window.handleRawEvent(
      _raw(type: xcbConfigureNotify, width: 160, height: 90),
    );
    window.flushPendingEvents();

    final second = window.cpuSurface!;
    expect(first.isDisposed, isTrue);
    expect(second, isNot(same(first)));
    expect(second.generation, 1);
    expect(second.pixelWidth, 160);
    expect(second.pixelHeight, 90);
    expect(
        client.destroyedBuffers, <X11CpuBuffer>[client.createdBuffers.first]);

    window.dispose();
    expect(second.isDisposed, isTrue);
    expect(
      client.teardownOrder.sublist(client.teardownOrder.length - 2),
      <String>['surface', 'window'],
    );
  });

  test('close destroys and reports closure exactly once', () async {
    final client = _FakeX11WindowClient();
    final removed = <X11Window>[];
    final window = _createWindow(client, onClosed: removed.add);
    final eventsDone = Completer<void>();
    final events = <PlatformWindowEvent>[];
    window.events.listen(events.add, onDone: eventsDone.complete);

    window.close();
    window.close();
    await eventsDone.future;

    expect(window.isDisposed, isTrue);
    expect(window.generation, 1);
    expect(client.destroyedWindows, <int>[client.nextWindow]);
    expect(removed, <X11Window>[window]);
    expect(events.whereType<WindowClosedEvent>(), hasLength(1));
    expect(
      () => window.setTitle('late'),
      throwsA(isA<StateError>()),
    );
    expect(
      window.handleRawEvent(_raw(type: xcbExpose, width: 1, height: 1)),
      isFalse,
    );
  });

  test('server DestroyNotify closes without issuing a second destroy',
      () async {
    final client = _FakeX11WindowClient();
    final removed = <X11Window>[];
    final window = _createWindow(client, onClosed: removed.add);
    final eventsDone = Completer<void>();
    final events = <PlatformWindowEvent>[];
    window.events.listen(events.add, onDone: eventsDone.complete);

    expect(
      window.handleRawEvent(_raw(type: xcbDestroyNotify)),
      isTrue,
    );
    window.flushPendingEvents();
    await eventsDone.future;
    window.dispose();

    expect(window.isDisposed, isTrue);
    expect(client.destroyedWindows, isEmpty);
    expect(removed, <X11Window>[window]);
    expect(events.whereType<WindowClosedEvent>(), hasLength(1));
  });
}
