import 'dart:async';
import 'dart:typed_data';

import 'package:dart_ui/src/backends/macos/host_process.dart';
import 'package:dart_ui/src/backends/macos/host_protocol.dart';
import 'package:dart_ui/src/backends/macos/io_surface.dart';
import 'package:dart_ui/src/backends/macos/macos_window.dart';
import 'package:dart_ui/src/backends/macos/surface_pool.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/platform/window_events.dart';
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
  _FakeHost({double renderScale = 1})
      : handshake = MacosHostHandshake(
          windowNumber: 42,
          hostPid: 123,
          protocolVersion: 4,
          features: 'surface-port,window-events',
          renderScale: renderScale,
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

void main() {
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
}
