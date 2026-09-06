/// The sharing rule, on its own: one device per adapter, reference counted.
///
/// `test/app/shared_render_device_test.dart` proves the same rule holds
/// through the production shell, with real windows opening and closing. This
/// file pins the registry's own contract, because the contract is the half
/// that is easy to weaken by accident: a cache that returns the same device
/// twice passes a naive test even if it opened two and threw one away, and a
/// refcount that is incremented after the `await` instead of before it passes
/// every test that never opens two windows in the same turn.
///
/// So the backend here counts, and the devices record their own disposal.
/// "Shared" is asserted as *`createDevice` was called once*, never as "the two
/// devices compare equal", and "released" is asserted as *this device object
/// was disposed*, never as "the lease says it is released".
library;

import 'dart:async';

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('sharing', () {
    test('a second acquisition for one adapter opens no second device',
        () async {
      final backend = _CountingBackend();
      final registry = SharedRenderDeviceRegistry();

      final a = await registry.acquire(backend, const RenderDeviceRequest());
      final b = await registry.acquire(backend, const RenderDeviceRequest());

      expect(backend.createDeviceCalls, 1,
          reason: 'the point of the registry is that the driver is asked once');
      expect(identical(a.device, b.device), isTrue);
      expect(registry.liveDeviceCount, 1);
      expect(registry.leaseCount, 2);

      a.release();
      b.release();
      registry.dispose();
    });

    test('a different adapter is a different device', () async {
      final backend = _CountingBackend();
      final registry = SharedRenderDeviceRegistry();

      final integrated =
          await registry.acquire(backend, const RenderDeviceRequest());
      final discrete = await registry.acquire(
        backend,
        const RenderDeviceRequest(adapter: 'discrete'),
      );

      // The adapter is in the key from the first commit rather than added the
      // day a laptop with two GPUs shows up, which is the day every call site
      // would otherwise have to be revisited.
      expect(backend.createDeviceCalls, 2);
      expect(identical(integrated.device, discrete.device), isFalse);
      expect(registry.liveDeviceCount, 2);

      integrated.release();
      discrete.release();
      registry.dispose();
    });

    test('two backends never share, even for the same adapter', () async {
      final registry = SharedRenderDeviceRegistry();
      final one = _CountingBackend();
      final two = _CountingBackend();

      final a = await registry.acquire(one, const RenderDeviceRequest());
      final b = await registry.acquire(two, const RenderDeviceRequest());

      expect(identical(a.device, b.device), isFalse);
      expect(registry.liveDeviceCount, 2);

      a.release();
      b.release();
      registry.dispose();
    });

    test('an exclusive request gets a device of its own and pollutes nothing',
        () async {
      final backend = _CountingBackend();
      final registry = SharedRenderDeviceRegistry();

      final shared =
          await registry.acquire(backend, const RenderDeviceRequest());
      final mine = await registry.acquire(
        backend,
        const RenderDeviceRequest(exclusive: true),
      );
      final alsoShared =
          await registry.acquire(backend, const RenderDeviceRequest());

      expect(identical(mine.device, shared.device), isFalse);
      expect(
        identical(alsoShared.device, shared.device),
        isTrue,
        reason: 'an exclusive device must never end up in the map, or the '
            'next ordinary window adopts the one somebody asked to keep',
      );
      expect(backend.createDeviceCalls, 2);

      final mineDevice = mine.device as _CountingDevice;
      mine.release();
      expect(mineDevice.isDisposed, isTrue,
          reason: 'nobody else can hold an exclusive device, so releasing it '
              'is disposing it');

      shared.release();
      alsoShared.release();
      registry.dispose();
    });

    test('a provider that does not share says so and still hands out devices',
        () async {
      // Avalonia's `UsesSharedContext == false`, which this framework's GL
      // paths answer. Not an error state: the caller gets a device, it simply
      // gets its own.
      const provider = PerWindowRenderDeviceProvider();
      final backend = _CountingBackend();

      expect(provider.sharesDevices, isFalse);
      final a = await provider.acquire(backend, const RenderDeviceRequest());
      final b = await provider.acquire(backend, const RenderDeviceRequest());

      expect(identical(a.device, b.device), isFalse);
      expect(backend.createDeviceCalls, 2);

      final first = a.device as _CountingDevice;
      a.release();
      expect(first.isDisposed, isTrue);
      b.release();
    });

    test('openDevice replaces how, never what it is keyed by', () async {
      // The Vulkan case: the presentation device cannot come from
      // `createDevice`, and the registry must still hand the same one to every
      // window rather than calling the override once per window.
      final backend = _CountingBackend();
      final registry = SharedRenderDeviceRegistry();
      var opened = 0;
      Future<RenderDevice> open() async {
        opened++;
        return _CountingDevice('opened-by-hand');
      }

      final a = await registry.acquire(
        backend,
        const RenderDeviceRequest(),
        openDevice: open,
      );
      final b = await registry.acquire(
        backend,
        const RenderDeviceRequest(),
        openDevice: open,
      );

      expect(opened, 1);
      expect(backend.createDeviceCalls, 0);
      expect(identical(a.device, b.device), isTrue);

      a.release();
      b.release();
      registry.dispose();
    });
  });

  group('reference counting', () {
    test('releasing one of two holders disposes nothing', () async {
      final backend = _CountingBackend();
      final registry = SharedRenderDeviceRegistry();

      final owner =
          await registry.acquire(backend, const RenderDeviceRequest());
      final popup =
          await registry.acquire(backend, const RenderDeviceRequest());
      final device = owner.device as _CountingDevice;

      popup.release();

      expect(device.isDisposed, isFalse,
          reason: 'the owner window is still drawing through it');
      expect(registry.liveDeviceCount, 1);
      expect(registry.leaseCount, 1);

      owner.release();
      expect(device.isDisposed, isTrue);
      expect(device.disposeCalls, 1);
      expect(registry.liveDeviceCount, 0);
      registry.dispose();
    });

    test('the last release disposes exactly once, however often it is called',
        () async {
      final backend = _CountingBackend();
      final registry = SharedRenderDeviceRegistry();

      final lease =
          await registry.acquire(backend, const RenderDeviceRequest());
      final device = lease.device as _CountingDevice;

      lease
        ..release()
        ..release()
        ..release();

      expect(device.disposeCalls, 1);
      expect(lease.isReleased, isTrue);
      registry.dispose();
    });

    test('a released lease refuses to name the device it no longer holds',
        () async {
      final backend = _CountingBackend();
      final registry = SharedRenderDeviceRegistry();
      final lease = await registry.acquire(backend, const RenderDeviceRequest())
        ..release();

      // A stale lease that still answered would hand out a disposed device, or
      // worse, one that now belongs to a window opened after this one closed.
      expect(() => lease.device, throwsStateError);
      registry.dispose();
    });

    test('closing everything and opening again gets a fresh device', () async {
      final backend = _CountingBackend();
      final registry = SharedRenderDeviceRegistry();

      final first =
          await registry.acquire(backend, const RenderDeviceRequest());
      final RenderDevice firstDevice = first.device;
      first.release();
      expect(registry.liveDeviceCount, 0,
          reason: 'an application with no windows holds no driver allocation');

      final second =
          await registry.acquire(backend, const RenderDeviceRequest());
      expect(backend.createDeviceCalls, 2);
      expect(identical(second.device, firstDevice), isFalse);

      second.release();
      registry.dispose();
    });
  });

  group('reentrancy', () {
    test('two acquisitions in one turn get one device, not two', () async {
      // The bug this guards is the fix for the bug the class exists to fix:
      // `acquire` is asynchronous, so a registry that stored the *device*
      // instead of the *future* would let two windows opening in the same turn
      // both find an empty map.
      final backend = _CountingBackend(delay: true);
      final registry = SharedRenderDeviceRegistry();

      final List<RenderDeviceLease> leases = await Future.wait(
        <Future<RenderDeviceLease>>[
          registry.acquire(backend, const RenderDeviceRequest()),
          registry.acquire(backend, const RenderDeviceRequest()),
          registry.acquire(backend, const RenderDeviceRequest()),
        ],
      );

      expect(backend.createDeviceCalls, 1);
      expect(identical(leases[0].device, leases[1].device), isTrue);
      expect(identical(leases[1].device, leases[2].device), isTrue);
      expect(registry.leaseCount, 3);

      for (final RenderDeviceLease lease in leases) {
        lease.release();
      }
      expect((leases.first.isReleased), isTrue);
      expect(registry.liveDeviceCount, 0);
      registry.dispose();
    });

    test('an open that fails is not cached, so the next window retries',
        () async {
      final backend = _CountingBackend(failFirst: true);
      final registry = SharedRenderDeviceRegistry();

      await expectLater(
        registry.acquire(backend, const RenderDeviceRequest()),
        throwsA(isA<StateError>()),
      );
      expect(registry.liveDeviceCount, 0,
          reason: 'a device that never opened must leave nothing behind');

      final lease =
          await registry.acquire(backend, const RenderDeviceRequest());
      expect(backend.createDeviceCalls, 2);
      expect(lease.device, isA<_CountingDevice>());

      lease.release();
      registry.dispose();
    });
  });

  group('device loss', () {
    test('a lost device is evicted on the next acquisition', () async {
      final backend = _CountingBackend();
      final registry = SharedRenderDeviceRegistry();

      final owner =
          await registry.acquire(backend, const RenderDeviceRequest());
      final lost = owner.device as _CountingDevice..lose();

      final replacement =
          await registry.acquire(backend, const RenderDeviceRequest());

      expect(identical(replacement.device, lost), isFalse,
          reason: 'Avalonia rebuilds the context when IsLost; a registry that '
              'kept handing out a dead device would make every new window '
              'inherit the loss');
      expect(backend.createDeviceCalls, 2);
      // The evicted one is still held by a window that has not noticed yet, so
      // it is still counted and still alive.
      expect(registry.liveDeviceCount, 2);
      expect(lost.isDisposed, isFalse);

      owner.release();
      expect(lost.isDisposed, isTrue);
      expect(registry.liveDeviceCount, 1);

      replacement.release();
      registry.dispose();
    });

    test('the replacement survives the stale holder letting go', () async {
      final backend = _CountingBackend();
      final registry = SharedRenderDeviceRegistry();

      final stale =
          await registry.acquire(backend, const RenderDeviceRequest());
      (stale.device as _CountingDevice).lose();
      final fresh =
          await registry.acquire(backend, const RenderDeviceRequest());

      stale.release();

      // The evicted entry must not take its replacement out of the map with
      // it: a third window acquiring now has to find the fresh device rather
      // than open a third one.
      final third =
          await registry.acquire(backend, const RenderDeviceRequest());
      expect(identical(third.device, fresh.device), isTrue);
      expect(backend.createDeviceCalls, 2);

      fresh.release();
      third.release();
      registry.dispose();
    });
  });

  group('the registry itself', () {
    test('disposing it releases devices a leaked lease still holds', () async {
      final backend = _CountingBackend();
      final registry = SharedRenderDeviceRegistry();
      final leaked =
          await registry.acquire(backend, const RenderDeviceRequest());
      final device = leaked.device as _CountingDevice;

      registry.dispose();

      expect(device.isDisposed, isTrue,
          reason: 'a lease nobody released must not outlive the process that '
              'created it');
      expect(registry.liveDeviceCount, 0);
      // And the lease still releases cleanly afterwards rather than throwing
      // into a teardown that is already running.
      leaked.release();
    });

    test('a disposed registry refuses to hand out anything else', () async {
      final backend = _CountingBackend();
      final registry = SharedRenderDeviceRegistry()..dispose();
      await expectLater(
        registry.acquire(backend, const RenderDeviceRequest()),
        throwsStateError,
        reason: 'and on the future, not on the stack: a caller awaiting an '
            'acquisition must not have to also wrap it in a try',
      );
    });
  });

  test('a request compares by value, so it can be a map key', () {
    expect(
      const RenderDeviceRequest(),
      const RenderDeviceRequest(adapter: null),
    );
    expect(
      const RenderDeviceRequest(adapter: 'a'),
      isNot(const RenderDeviceRequest(adapter: 'b')),
    );
    expect(
      const RenderDeviceRequest(),
      isNot(const RenderDeviceRequest(exclusive: true)),
    );
    expect(
      const RenderDeviceRequest(adapter: 'a').hashCode,
      const RenderDeviceRequest(adapter: 'a').hashCode,
    );
  });
}

// ---------------------------------------------------------------------------
// Fakes that count
// ---------------------------------------------------------------------------

/// A backend that records every time somebody asked it for a device.
///
/// The count is the assertion. "Both windows have the same device" can be true
/// of a registry that opened two and returned one of them, and that registry
/// would leak a driver allocation per window while every equality test passed.
final class _CountingBackend implements RendererBackend {
  _CountingBackend({this.delay = false, this.failFirst = false});

  /// Whether opening yields, which is what makes the reentrancy test able to
  /// interleave two acquisitions.
  final bool delay;
  final bool failFirst;

  int createDeviceCalls = 0;

  @override
  RendererInfo get info => const RendererInfo(
        name: 'counting',
        deviceDescription: 'a device that only counts',
        rasterizationApproach: RasterizationApproach.custom,
      );

  @override
  BackendProbeResult probe() => BackendProbeResult(
        backendName: 'counting',
        supported: true,
      );

  @override
  bool supportsSurface(NativeSurfaceDescriptor surface) => true;

  @override
  Future<RenderDevice> createDevice() async {
    final int call = ++createDeviceCalls;
    if (delay) await Future<void>.delayed(Duration.zero);
    if (failFirst && call == 1) {
      throw StateError('the driver refused this time');
    }
    return _CountingDevice('device-$call');
  }
}

/// A device that remembers being disposed, and can be told it was lost.
final class _CountingDevice implements RenderDevice {
  _CountingDevice(this.name);

  final String name;
  int disposeCalls = 0;
  bool _lost = false;

  void lose() => _lost = true;

  @override
  bool get isLost => _lost;

  @override
  RendererInfo get info => RendererInfo(
        name: 'counting',
        deviceDescription: name,
        rasterizationApproach: RasterizationApproach.custom,
      );

  @override
  RendererCapabilities get capabilities => const RendererCapabilities(
        supportsPartialPresent: false,
        supportsMsaa: false,
        supportsCompute: false,
        supportsExternalTextures: false,
        supportsLinearColor: false,
        maxTextureSize: 0,
        formats: <PixelFormat>{},
      );

  @override
  RenderTarget createTarget(NativeSurfaceDescriptor surface) =>
      throw UnimplementedError('this device never draws');

  @override
  bool get isDisposed => disposeCalls > 0;

  @override
  void dispose() => disposeCalls++;

  @override
  String toString() => 'device($name)';
}
