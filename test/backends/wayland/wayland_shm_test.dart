import 'dart:typed_data';

import 'package:dart_ui/src/backends/wayland/wayland_protocol.dart';
import 'package:dart_ui/src/backends/wayland/wayland_shm.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:test/test.dart';

void main() {
  group('WaylandShmPoolPlan', () {
    test('derives stride, byte length and format together', () {
      final plan = WaylandShmPoolPlan(pixelWidth: 640, pixelHeight: 480);
      expect(plan.strideBytes, 640 * 4);
      expect(plan.byteLength, 640 * 4 * 480);
      expect(plan.format, wlShmFormatArgb8888);
    });

    test('rejects impossible geometry before any allocation', () {
      expect(
        () => WaylandShmPoolPlan(pixelWidth: 0, pixelHeight: 5),
        throwsArgumentError,
      );
      expect(
        () => WaylandShmPoolPlan(pixelWidth: 5, pixelHeight: -1),
        throwsArgumentError,
      );
      expect(
        () => WaylandShmPoolPlan(pixelWidth: 0x8000, pixelHeight: 5),
        throwsRangeError,
      );
    });
  });

  group('WaylandShmSurface', () {
    late _FakeCpuClient client;

    setUp(() => client = _FakeCpuClient());

    WaylandShmSurface create({
      int width = 8,
      int height = 6,
      double scale = 1,
      int bufferScale = 1,
      int generation = 1,
    }) =>
        WaylandShmSurface.create(
          client: client,
          surfaceId: 3,
          pixelWidth: width,
          pixelHeight: height,
          scale: scale,
          bufferScale: bufferScale,
          generation: generation,
        );

    test('refuses to exist without shm support', () {
      client.supported = false;
      expect(create, throwsA(isA<UnsupportedCapabilityError>()));
      expect(client.created, isEmpty);
    });

    test('validates its arguments before allocating', () {
      expect(
        () => WaylandShmSurface.create(
          client: client,
          surfaceId: 0,
          pixelWidth: 8,
          pixelHeight: 6,
          scale: 1,
          bufferScale: 1,
          generation: 1,
        ),
        throwsArgumentError,
      );
      expect(() => create(width: 0), throwsArgumentError);
      expect(() => create(scale: double.nan), throwsArgumentError);
      expect(() => create(bufferScale: 0), throwsArgumentError);
      expect(() => create(generation: -1), throwsArgumentError);
      expect(client.created, isEmpty);
    });

    test('destroys the buffer when the created geometry is wrong', () {
      client.geometryOverride = (width: 4, height: 4);
      expect(create, throwsStateError);
      expect(client.destroyed, hasLength(1));
    });

    test('a full present covers the whole buffer in device pixels', () {
      final surface = create(width: 8, height: 6, scale: 2, bufferScale: 2);
      expect(surface.present(), isNull);
      expect(client.presented.single.damage,
          const WaylandCpuDamage(x: 0, y: 0, width: 8, height: 6));
      expect(client.presented.single.bufferScale, 2);
      expect(client.presented.single.surfaceId, 3);
    });

    test('logical damage is scaled outward and clipped', () {
      final surface = create(width: 8, height: 6, scale: 2, bufferScale: 2);
      expect(
        surface.present(damage: const Rect.fromLTRB(0.4, 0.4, 2.6, 9)),
        isNull,
      );
      // floor(0.4*2)=0, ceil(2.6*2)=6; bottom clips to 6.
      expect(client.presented.single.damage,
          const WaylandCpuDamage(x: 0, y: 0, width: 6, height: 6));
    });

    test('empty or fully clipped damage is a successful no-op', () {
      final surface = create();
      expect(surface.present(damage: Rect.zero), isNull);
      expect(
        surface.present(damage: const Rect.fromLTRB(100, 100, 200, 200)),
        isNull,
      );
      expect(client.presented, isEmpty);
    });

    test('non-finite damage is a caller bug, reported as such', () {
      final surface = create();
      expect(
        () => surface.present(
          damage: const Rect.fromLTRB(0, 0, double.infinity, 4),
        ),
        throwsArgumentError,
      );
    });

    test('a thrown commit becomes a diagnostic, not an escape', () {
      final surface = create();
      client.presentError = StateError('synthetic commit failure');
      final failure = surface.present();
      expect(failure, isNotNull);
      expect(failure!.kind, DiagnosticKind.connectionFailed);
    });

    test('support withdrawn after creation fails presents cleanly', () {
      final surface = create();
      client.supported = false;
      final failure = surface.present();
      expect(failure!.kind, DiagnosticKind.incompatibleDevice);
    });

    test('dispose releases the buffer exactly once', () {
      final surface = create();
      surface.dispose();
      surface.dispose();
      expect(client.destroyed, hasLength(1));
      expect(surface.present, throwsStateError);
    });
  });
}

final class _FakeBuffer implements WaylandShmBufferHandle {
  _FakeBuffer(int width, int height)
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

final class _FakeCpuClient implements WaylandCpuClient {
  bool supported = true;
  ({int width, int height})? geometryOverride;
  Object? presentError;

  final List<_FakeBuffer> created = <_FakeBuffer>[];
  final List<WaylandShmBufferHandle> destroyed = <WaylandShmBufferHandle>[];
  final List<
      ({
        int surfaceId,
        WaylandCpuDamage damage,
        int bufferScale,
      })> presented = <({
    int surfaceId,
    WaylandCpuDamage damage,
    int bufferScale,
  })>[];

  @override
  bool get supportsShmPresentation => supported;

  @override
  WaylandShmBufferHandle createShmBuffer({
    required int pixelWidth,
    required int pixelHeight,
  }) {
    final geometry = geometryOverride;
    final buffer = _FakeBuffer(
      geometry?.width ?? pixelWidth,
      geometry?.height ?? pixelHeight,
    );
    created.add(buffer);
    return buffer;
  }

  @override
  void destroyShmBuffer(WaylandShmBufferHandle buffer) {
    destroyed.add(buffer);
  }

  @override
  BackendDiagnostic? presentShmBuffer({
    required int surfaceId,
    required WaylandShmBufferHandle buffer,
    required WaylandCpuDamage damage,
    required int bufferScale,
  }) {
    final error = presentError;
    if (error != null) throw error;
    presented.add(
      (surfaceId: surfaceId, damage: damage, bufferScale: bufferScale),
    );
    return null;
  }
}
