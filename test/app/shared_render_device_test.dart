/// One device for every window of an application, proved through the shell.
///
/// `test/rendering/render_device_registry_test.dart` pins the registry's own
/// contract against a fake that never draws. This file is the other half and
/// the one that would actually catch the regression: it drives the *production*
/// `Application`, opens and closes real windows on the headless backend, and
/// asserts on how many times the renderer backend was asked for a device.
///
/// The six cases below are the whole risk of moving device lifetime out of the
/// presenter. Until this change, a device was created by the attachment and
/// disposed by the presenter, so it lived and died with one window and nothing
/// could get the order wrong. Now it outlives windows, which puts it in the
/// same territory as `DisposableBag` and the teardown ordering that
/// `multi_window_test.dart` counts - the most heavily tested code here - and
/// every one of these is a way to get that wrong that produces either a black
/// second window or a driver allocation nobody ever frees.
///
/// The backend is a counting wrapper over the real CPU renderer rather than a
/// stub, so the windows really lay out and really present: a test that shared a
/// device nothing ever drew through would prove the counter, not the framework.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('one device, N windows', () {
    test('a second window is handed the first window\'s device', () async {
      final backend = _CountingBackend();
      final app = await _start(backend);
      addTearDown(() => _stop(app));

      final owner = app.primaryWindow;
      final popup = await app.openWindow(
        rootWidget: const ColoredBox(color: Color(0xFF00FF00)),
        size: const Size(20, 10),
        kind: WindowKind.popup,
        owner: owner.id,
      );

      expect(
        backend.createDeviceCalls,
        1,
        reason: 'the popup must not open a second device; that was 20.7 ms of '
            'a 30 ms menu open on the machine this was measured on',
      );
      expect(identical(_deviceOf(owner), _deviceOf(popup)), isTrue);
      expect(_presenterOf(popup).sharesDevice, isTrue);

      // And both really draw through it, so this is not a shared handle to
      // something nothing uses.
      await owner.drawFrame();
      await popup.drawFrame();
      expect(owner.framesPresented, greaterThan(0));
      expect(popup.framesPresented, greaterThan(0));
    });

    test('the device the application hands out is the registry\'s', () async {
      final backend = _CountingBackend();
      final app = await _start(backend);
      addTearDown(() => _stop(app));

      expect(app.devices.sharesDevices, isTrue);
      expect(app.presentationPath.sharesDevice, isTrue);
    });
  });

  // --- 1 -------------------------------------------------------------------
  test('the presenter releases its lease and never disposes the device',
      () async {
    final backend = _CountingBackend();
    final app = await _start(backend);
    addTearDown(() => _stop(app));

    final owner = app.primaryWindow;
    final second = await app.openWindow(
      rootWidget: const ColoredBox(color: Color(0xFF00FF00)),
      size: const Size(20, 10),
    );
    final _CountingDevice device = _deviceOf(owner);

    // Disposing the presenter directly, which is what `host.dispose()` does
    // and therefore the narrowest place the old behaviour lived: this call
    // used to run `device.dispose()`.
    _presenterOf(second).dispose();

    expect(device.disposeCalls, 0);
    expect(owner.host.presenter.isDeviceLost, isFalse);
  });

  // --- 2 -------------------------------------------------------------------
  test('the release is registered in the window bag, and changes no order',
      () async {
    final backend = _CountingBackend();
    final app = await _start(backend);
    final owner = app.primaryWindow;
    final device = _deviceOf(owner);

    app.closeWindow(owner.id);

    // The exact list `multi_window_test.dart` and `application_test.dart`
    // assert on. A device release announced as a teardown step would change
    // this for every window in the framework, to record something that had
    // already happened inside `host`.
    expect(app.teardownOrder, <String>[
      'events',
      'buildOwner',
      'scheduler',
      'host',
      'window',
    ]);
    expect(device.disposeCalls, 1,
        reason: 'it still happened, it is simply part of `host`');

    await _stop(app);
  });

  // --- 3 -------------------------------------------------------------------
  test('closing one window while another draws disposes nothing', () async {
    final backend = _CountingBackend();
    final app = await _start(backend);
    addTearDown(() => _stop(app));

    final a = app.primaryWindow;
    final b = await app.openWindow(
      rootWidget: const ColoredBox(color: Color(0xFF00FF00)),
      size: const Size(20, 10),
    );
    final device = _deviceOf(a);

    app.closeWindow(b.id);

    expect(device.disposeCalls, 0);
    // The surviving window has to still be able to present, which is the
    // symptom a user would report: the main window goes black when a menu
    // closes.
    await a.drawFrame();
    expect(a.host.framesRejected, 0);
    expect(a.framesPresented, greaterThan(0));
  });

  // --- 4 -------------------------------------------------------------------
  test('closing the last window disposes the device exactly once', () async {
    final backend = _CountingBackend();
    final app = await _start(backend, exitWhenLastWindowClosed: false);
    final a = app.primaryWindow;
    final b = await app.openWindow(
      rootWidget: const ColoredBox(color: Color(0xFF00FF00)),
      size: const Size(20, 10),
    );
    final device = _deviceOf(a);

    app.closeWindow(b.id);
    expect(device.disposeCalls, 0);
    app.closeWindow(a.id);
    expect(device.disposeCalls, 1);

    // And nothing is left holding a driver allocation across the interval a
    // tray application spends most of its life in.
    expect((app.devices as SharedRenderDeviceRegistry).liveDeviceCount, 0);

    // Opening again after that opens a device again, rather than resurrecting
    // a disposed one.
    final c = await app.openWindow(
      rootWidget: const ColoredBox(color: Color(0xFF0000FF)),
      size: const Size(20, 10),
    );
    expect(backend.createDeviceCalls, 2);
    expect(identical(_deviceOf(c), device), isFalse);
    await c.drawFrame();
    expect(c.framesPresented, greaterThan(0));

    await _stop(app);
    expect(device.disposeCalls, 1,
        reason: 'the application teardown must not dispose it a second time');
  });

  // --- 5 -------------------------------------------------------------------
  test('an attach that fails gives the lease back', () async {
    // The window offers a surface the backend accepts and then the *target*
    // refuses to be built, which is the shape of a swap-chain failure: the
    // device is already leased when the failure happens, so the only correct
    // recovery is a release. Disposing instead would kill the first window's
    // device; leaking instead would pin it for the process.
    final backend = _CountingBackend(failTargetsAfter: 1);
    final app = await _start(backend);
    addTearDown(() => _stop(app));

    final owner = app.primaryWindow;
    final device = _deviceOf(owner);

    await expectLater(
      app.openWindow(
        rootWidget: const ColoredBox(color: Color(0xFF00FF00)),
        size: const Size(20, 10),
      ),
      throwsA(isA<StateError>()),
    );

    final registry = app.devices as SharedRenderDeviceRegistry;
    expect(registry.leaseCount, 1,
        reason: 'the failed window took a lease and must have given it back');
    expect(device.disposeCalls, 0,
        reason: 'and it must not have disposed the device the owner is using');
    expect(app.windows, hasLength(1));

    await owner.drawFrame();
    expect(owner.framesPresented, greaterThan(0));
  });

  // --- 6 -------------------------------------------------------------------
  test('two windows opening in the same turn get one device', () async {
    final backend = _CountingBackend(delayDevice: true);
    final app = await _start(backend, exitWhenLastWindowClosed: false);
    addTearDown(() => _stop(app));
    final registry = app.devices as SharedRenderDeviceRegistry;

    // The startup window is closed first, deliberately. With it still open the
    // registry would already hold a device and both concurrent windows would
    // hit a warm cache, so `createDeviceCalls == 1` would pass against a
    // registry with no in-flight guard at all: the two below have to be the
    // ones that race to open it.
    app.closeWindow(app.primaryWindow.id);
    expect(registry.liveDeviceCount, 0);
    expect(backend.createDeviceCalls, 1);

    // Not awaited one after the other: both `openWindow` calls are in flight
    // across the same `createDevice`, which is the only arrangement that can
    // catch a guard placed on the result instead of on the in-flight future.
    final List<ApplicationWindow> opened = await Future.wait(
      <Future<ApplicationWindow>>[
        app.openWindow(
          rootWidget: const ColoredBox(color: Color(0xFF00FF00)),
          size: const Size(20, 10),
        ),
        app.openWindow(
          rootWidget: const ColoredBox(color: Color(0xFF0000FF)),
          size: const Size(20, 10),
        ),
      ],
    );

    expect(
      backend.createDeviceCalls,
      2,
      reason: 'one for the startup window that has gone, and exactly one more '
          'for the two that opened together',
    );
    expect(identical(_deviceOf(opened[0]), _deviceOf(opened[1])), isTrue);
    expect(registry.liveDeviceCount, 1);
    expect(registry.leaseCount, 2);

    // Both really draw through the one device they raced for.
    await opened[0].drawFrame();
    await opened[1].drawFrame();
    expect(opened[0].framesPresented, greaterThan(0));
    expect(opened[1].framesPresented, greaterThan(0));
  });
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

Future<Application> _start(
  _CountingBackend backend, {
  bool exitWhenLastWindowClosed = true,
}) =>
    Application.start(
      rootWidget: const ColoredBox(color: Color(0xFF204080)),
      backends: <WindowingBackendEntry>[
        const WindowingBackendEntry(
          name: 'headless',
          create: HeadlessWindowingBackend.new,
        ),
      ],
      presentations: <PresentationPathEntry>[
        PresentationPathEntry.cpuRenderer(backend: backend, name: 'counting'),
      ],
      options: ApplicationOptions(
        title: 'shared device test',
        size: const Size(30, 20),
        visible: true,
        exitWhenLastWindowClosed: exitWhenLastWindowClosed,
      ),
    );

Future<void> _stop(Application app) async {
  if (!app.isDisposed) app.dispose();
  await app.closed;
}

RenderTargetPresenter _presenterOf(ApplicationWindow window) =>
    window.host.presenter as RenderTargetPresenter;

_CountingDevice _deviceOf(ApplicationWindow window) =>
    _presenterOf(window).device as _CountingDevice;

// ---------------------------------------------------------------------------
// A real renderer that counts
// ---------------------------------------------------------------------------

/// The CPU renderer, wrapped so every device it opens is counted and every
/// disposal is recorded.
///
/// Delegating rather than stubbing matters here: the windows in this file lay
/// out and present for real, so "they share a device" is a claim about a device
/// that is actually drawing rather than about a handle nothing touches.
final class _CountingBackend implements RendererBackend {
  _CountingBackend({
    this.delayDevice = false,
    this.failTargetsAfter,
  });

  static const CpuRendererBackend _real = CpuRendererBackend();

  /// Whether opening yields before returning, which is what lets two windows
  /// be genuinely in flight at once.
  final bool delayDevice;

  /// After this many targets have been built, refuse. Models a swap chain that
  /// fails on a device that opened perfectly well.
  final int? failTargetsAfter;

  int createDeviceCalls = 0;
  final List<_CountingDevice> devices = <_CountingDevice>[];

  @override
  RendererInfo get info => _real.info;

  @override
  BackendProbeResult probe() => _real.probe();

  @override
  bool supportsSurface(NativeSurfaceDescriptor surface) =>
      _real.supportsSurface(surface);

  @override
  Future<RenderDevice> createDevice() async {
    createDeviceCalls++;
    if (delayDevice) await Future<void>.delayed(Duration.zero);
    final device = _CountingDevice(
      await _real.createDevice(),
      failTargetsAfter: failTargetsAfter,
    );
    devices.add(device);
    return device;
  }
}

final class _CountingDevice implements RenderDevice {
  _CountingDevice(this._inner, {this.failTargetsAfter});

  final RenderDevice _inner;
  final int? failTargetsAfter;

  int disposeCalls = 0;
  int targetsCreated = 0;

  @override
  RendererInfo get info => _inner.info;

  @override
  RendererCapabilities get capabilities => _inner.capabilities;

  @override
  bool get isLost => _inner.isLost;

  @override
  RenderTarget createTarget(NativeSurfaceDescriptor surface) {
    final int limit = failTargetsAfter ?? -1;
    if (limit >= 0 && targetsCreated >= limit) {
      targetsCreated++;
      throw StateError('the swap chain could not be created');
    }
    targetsCreated++;
    return _inner.createTarget(surface);
  }

  @override
  bool get isDisposed => disposeCalls > 0;

  @override
  void dispose() {
    disposeCalls++;
    _inner.dispose();
  }
}
