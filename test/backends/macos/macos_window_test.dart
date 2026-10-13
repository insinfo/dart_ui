import 'dart:async';
import 'dart:typed_data';

import 'package:dart_ui/src/backends/macos/host_process.dart';
import 'package:dart_ui/src/backends/macos/host_protocol.dart';
import 'package:dart_ui/src/backends/macos/io_surface.dart';
import 'package:dart_ui/src/backends/macos/macos_window.dart';
import 'package:dart_ui/src/backends/macos/surface_pool.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/platform/system_settings.dart';
import 'package:dart_ui/src/platform/window_events.dart';
import 'package:dart_ui/src/rendering/present_mode.dart';
import 'package:test/test.dart';

final class _FakeSurface implements MacosPoolSurface {
  _FakeSurface(this.id, this.width, this.height)
      : bytesPerRow = width * 4,
        pixels = Uint8List(width * height * 4);

  @override
  final int id;

  @override
  final int width;

  @override
  final int height;

  @override
  final int bytesPerRow;

  final Uint8List pixels;

  @override
  bool isDisposed = false;

  @override
  int createMachPort() => throw StateError('host should not attach');

  @override
  void dispose() => isDisposed = true;

  @override
  void withPixels(void Function(Uint8List pixels) write) => write(pixels);
}

final class _FakeHost implements MacosHostProcessHandle {
  _FakeHost({double renderScale = 1, List<MacosHostScreen>? screens})
      : handshake = MacosHostHandshake(
          windowNumber: 42,
          hostPid: 123,
          protocolVersion: 4,
          features: 'surface-port,window-events',
          renderScale: renderScale,
          screens: screens ?? const <MacosHostScreen>[],
        );

  @override
  final MacosHostHandshake handshake;

  final Completer<int> _exit = Completer<int>();

  @override
  MacosHostExitReason exitReason = MacosHostExitReason.none;

  @override
  Future<int> get exitStatus => _exit.future;

  @override
  int get pid => handshake.hostPid;

  @override
  Future<bool> awaitAck(HostAckKind kind, Duration timeout) async => true;

  @override
  Future<bool> awaitPresented(int sequence, Duration timeout) async => true;

  @override
  Future<bool> awaitSurfaceAttached(int slot, Duration timeout) async => true;

  @override
  Future<int> close({Duration timeout = const Duration(seconds: 5)}) {
    exitReason = MacosHostExitReason.requested;
    if (!_exit.isCompleted) _exit.complete(0);
    return _exit.future;
  }

  @override
  Future<int> kill() => close();

  @override
  bool send(String command) => true;
}

/// A host that reports refreshes only when the test says so.
final class _PacedHost implements MacosHostProcessHandle, MacosVsyncChannel {
  _PacedHost({this.supportsVsync = true});

  @override
  final bool supportsVsync;

  @override
  final MacosHostHandshake handshake = const MacosHostHandshake(
    windowNumber: 42,
    hostPid: 123,
    protocolVersion: 4,
    features: 'surface-port,window-events,vsync',
    renderScale: 1,
    screens: <MacosHostScreen>[],
  );

  final List<String> sent = <String>[];
  final Map<int, Completer<bool>> refreshes = <int, Completer<bool>>{};
  final Completer<int> _exit = Completer<int>();

  @override
  Future<bool> awaitVsync(int sequence, Duration timeout) =>
      (refreshes[sequence] = Completer<bool>()).future;

  @override
  MacosHostExitReason exitReason = MacosHostExitReason.none;

  @override
  Future<int> get exitStatus => _exit.future;

  @override
  int get pid => handshake.hostPid;

  @override
  Future<bool> awaitAck(HostAckKind kind, Duration timeout) async => true;

  @override
  Future<bool> awaitPresented(int sequence, Duration timeout) async => true;

  @override
  Future<bool> awaitSurfaceAttached(int slot, Duration timeout) async => true;

  @override
  Future<int> close({Duration timeout = const Duration(seconds: 5)}) {
    exitReason = MacosHostExitReason.requested;
    if (!_exit.isCompleted) _exit.complete(0);
    return _exit.future;
  }

  @override
  Future<int> kill() => close();

  @override
  bool send(String command) {
    sent.add(command.trim());
    return true;
  }

  List<String> get presents =>
      sent.where((String c) => c.startsWith('PRESENT_SLOT')).toList();
}

Future<MacosWindow> _openPaced(_PacedHost host) async {
  final window = MacosWindow(
    id: const NativeWindowId(9),
    surfaceFactory: ({
      required pixelWidth,
      required pixelHeight,
      required global,
    }) =>
        MacosSurfacePool(<_FakeSurface>[
      _FakeSurface(1, pixelWidth, pixelHeight),
      _FakeSurface(2, pixelWidth, pixelHeight),
    ]),
    clientSize: const Size(8, 6),
    renderScale: 1,
    desktopScale: 1,
    onDiagnostic: (_) {},
    onClosed: (_) {},
    hostStarter: (options, sink, onDiagnostic) async => host,
    poolAttacher: (candidate, pool) async => identical(candidate, host),
  );
  expect(
    await window.open(
      spawnOptions: const MacosHostSpawnOptions(
        binaryPath: 'fake',
        logicalWidth: 8,
        logicalHeight: 6,
      ),
    ),
    isTrue,
  );
  return window;
}

void main() {
  group('pacing to the display', () {
    test('FIFO holds a present until the previous one reached the screen',
        () async {
      // An IOSurface present is a line on a pipe and returns at once, so a
      // loop asking for a frame every frame ran at a thousand frames a second
      // on a 60 Hz screen. FIFO now sends each present with `vsync` and holds
      // the next one until the host reports the refresh after it.
      final host = _PacedHost();
      final window = await _openPaced(host);
      expect(window.presentMode, PresentMode.fifo);

      await window.drawAndPresent((_) {});
      expect(host.presents, <String>['PRESENT_SLOT 1 0 vsync']);

      var second = false;
      final Future<void> pending =
          window.drawAndPresent((_) {}).then((_) => second = true);
      await Future<void>.delayed(Duration.zero);
      expect(second, isFalse, reason: 'the first frame has not been shown');
      expect(host.presents, hasLength(1));

      host.refreshes[1]!.complete(true);
      await pending;
      expect(second, isTrue);
      expect(host.presents.last, 'PRESENT_SLOT 2 1 vsync');

      window.dispose();
      await window.teardown;
    });

    test('immediate sends without waiting and without asking', () async {
      final host = _PacedHost();
      final window = await _openPaced(host);
      expect(window.requestPresentMode(PresentMode.immediate).accepted, isTrue);
      await window.drawAndPresent((_) {});
      await window.drawAndPresent((_) {});
      expect(host.presents, <String>['PRESENT_SLOT 1 0', 'PRESENT_SLOT 2 1']);
      expect(host.refreshes, isEmpty);

      expect(window.requestPresentMode(PresentMode.mailbox).accepted, isFalse,
          reason: 'there is no present queue for mailbox to replace in');
      window.dispose();
      await window.teardown;
    });

    test('a host that never announced vsync is not waited on', () async {
      // An older host would answer `PRESENT_SLOT ... vsync` with an error and
      // never send VSYNC; every frame would then sit out the timeout.
      final host = _PacedHost(supportsVsync: false);
      final window = await _openPaced(host);
      await window.drawAndPresent((_) {});
      await window.drawAndPresent((_) {});
      expect(host.presents, <String>['PRESENT_SLOT 1 0', 'PRESENT_SLOT 2 1']);
      window.dispose();
      await window.teardown;
    });
  });

  test('failed host spawn does not allocate a pool it cannot attach', () async {
    var allocated = false;
    final window = MacosWindow(
      id: const NativeWindowId(1),
      surfaceFactory: ({
        required pixelWidth,
        required pixelHeight,
        required global,
      }) {
        allocated = true;
        return MacosSurfacePool(<_FakeSurface>[
          _FakeSurface(1, pixelWidth, pixelHeight),
          _FakeSurface(2, pixelWidth, pixelHeight),
        ]);
      },
      clientSize: const Size(8, 6),
      renderScale: 2,
      desktopScale: 2,
      onDiagnostic: (_) {},
      onClosed: (_) {},
    );

    final opened = await window.open(
      spawnOptions: const MacosHostSpawnOptions(
        binaryPath: '__dart_ui_host_that_does_not_exist__',
        logicalWidth: 8,
        logicalHeight: 6,
        handshakeTimeout: Duration(milliseconds: 10),
      ),
    );

    expect(opened, isFalse);
    expect(allocated, isFalse);
    expect(window.surfaces, isEmpty);

    window.dispose();
    await window.teardown;
  });

  test('handshake scale sizes the first private pool before attach', () async {
    bool? requestedGlobal;
    late List<_FakeSurface> surfaces;
    final host = _FakeHost(renderScale: 2);
    final window = MacosWindow(
      id: const NativeWindowId(3),
      surfaceFactory: ({
        required pixelWidth,
        required pixelHeight,
        required global,
      }) {
        requestedGlobal = global;
        surfaces = <_FakeSurface>[
          _FakeSurface(1, pixelWidth, pixelHeight),
          _FakeSurface(2, pixelWidth, pixelHeight),
        ];
        return MacosSurfacePool(surfaces);
      },
      clientSize: const Size(8, 6),
      renderScale: 1,
      desktopScale: 1,
      onDiagnostic: (_) {},
      onClosed: (_) {},
      hostStarter: (options, sink, onDiagnostic) async => host,
      poolAttacher: (candidate, pool) async => identical(candidate, host),
    );

    expect(
      await window.open(
        spawnOptions: const MacosHostSpawnOptions(
          binaryPath: 'fake',
          logicalWidth: 8,
          logicalHeight: 6,
        ),
      ),
      isTrue,
    );
    expect(window.renderScale, 2);
    expect(requestedGlobal, isFalse);
    expect(surfaces.first.width, 16);
    expect(surfaces.first.height, 12);

    window.dispose();
    await window.teardown;
    expect(
        surfaces, everyElement(predicate<_FakeSurface>((s) => s.isDisposed)));
  });

  test('host screen snapshot becomes logical ScreenInfo', () async {
    final host = _FakeHost(
      screens: const <MacosHostScreen>[
        MacosHostScreen(
          x: 0,
          y: 0,
          width: 1512,
          height: 982,
          workX: 0,
          workY: 25,
          workWidth: 1512,
          workHeight: 932,
          scale: 2,
          isPrimary: true,
          name: 'Built-in Display',
        ),
      ],
    );
    final window = MacosWindow(
      id: const NativeWindowId(4),
      surfaceFactory: ({
        required pixelWidth,
        required pixelHeight,
        required global,
      }) =>
          MacosSurfacePool(<_FakeSurface>[
        _FakeSurface(1, pixelWidth, pixelHeight),
        _FakeSurface(2, pixelWidth, pixelHeight),
      ]),
      clientSize: const Size(8, 6),
      renderScale: 1,
      desktopScale: 1,
      onDiagnostic: (_) {},
      onClosed: (_) {},
      hostStarter: (options, sink, onDiagnostic) async => host,
      poolAttacher: (candidate, pool) async => true,
    );

    expect(
      await window.open(
        spawnOptions: const MacosHostSpawnOptions(
          binaryPath: 'fake',
          logicalWidth: 8,
          logicalHeight: 6,
        ),
      ),
      isTrue,
    );
    expect(window.hostScreens.single.name, 'Built-in Display');
    expect(window.hostScreens.single.bounds.height, 982);
    expect(window.hostScreens.single.workArea.top, 25);
    expect(window.hostScreens.single.scale, 2);

    window.dispose();
    await window.teardown;
  });

  test('close emits once, unregisters once, and disposes without a live host',
      () async {
    var closedCallbacks = 0;
    final window = MacosWindow(
      id: const NativeWindowId(2),
      surfaceFactory: ({
        required pixelWidth,
        required pixelHeight,
        required global,
      }) =>
          throw StateError('close before open must not allocate'),
      clientSize: const Size(10, 10),
      renderScale: 1,
      desktopScale: 1,
      onDiagnostic: (_) {},
      onClosed: (_) => closedCallbacks++,
    );
    final events = window.events.toList();

    window
      ..close()
      ..close();
    await window.teardown;

    expect(await events, hasLength(1));
    expect(closedCallbacks, 1);
    expect(window.isDisposed, isTrue);
  });

  test('a SYSTEM_SETTINGS line becomes a settings event on the stream',
      () async {
    HostMessageSink? sink;
    final host = _FakeHost();
    final window = MacosWindow(
      id: const NativeWindowId(4),
      surfaceFactory: ({
        required pixelWidth,
        required pixelHeight,
        required global,
      }) =>
          MacosSurfacePool(<_FakeSurface>[
        _FakeSurface(1, pixelWidth, pixelHeight),
        _FakeSurface(2, pixelWidth, pixelHeight),
      ]),
      clientSize: const Size(8, 6),
      renderScale: 1,
      desktopScale: 1,
      onDiagnostic: (_) {},
      onClosed: (_) {},
      hostStarter: (options, hostSink, onDiagnostic) async {
        sink = hostSink;
        return host;
      },
      poolAttacher: (candidate, pool) async => identical(candidate, host),
    );
    // Before anybody listens, as the banner's copy arrives: the stream is
    // single-subscription precisely so that this one is buffered, not lost.
    expect(
      await window.open(
        spawnOptions: const MacosHostSpawnOptions(
          binaryPath: 'fake',
          logicalWidth: 8,
          logicalHeight: 6,
        ),
      ),
      isTrue,
    );
    sink!.onSystemSettings(true, false, true);

    final List<PlatformWindowEvent> events = <PlatformWindowEvent>[];
    final StreamSubscription<PlatformWindowEvent> subscription =
        window.events.listen(events.add);
    await Future<void>.delayed(Duration.zero);

    final SystemSettingsChangedEvent event =
        events.whereType<SystemSettingsChangedEvent>().single;
    expect(event.windowId, window.id);
    expect(event.generation, window.generation);
    expect(
      event.settings,
      const SystemSettings(
        brightness: Brightness.dark,
        disableAnimations: true,
      ),
    );

    await subscription.cancel();
    window.dispose();
    await window.teardown;
  });
}
