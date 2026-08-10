import 'dart:typed_data';

import 'package:dart_ui/src/backends/x11/x11_surface.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:test/test.dart';

void main() {
  late _FakeCpuClient client;

  setUp(() {
    client = _FakeCpuClient();
  });

  X11PutImageSurface createSurface({
    int width = 8,
    int height = 6,
    double scale = 1,
    int generation = 3,
  }) =>
      X11PutImageSurface.create(
        client: client,
        xcbWindow: 0x120001,
        pixelWidth: width,
        pixelHeight: height,
        scale: scale,
        generation: generation,
      );

  test('exposes a BGRA framebuffer as an X11 native surface descriptor', () {
    final surface = createSurface(width: 7, height: 5, scale: 1.5);

    expect(surface.kind, 'x11-put-image');
    expect(surface.xcbWindow, 0x120001);
    expect(surface.pixelWidth, 7);
    expect(surface.pixelHeight, 5);
    expect(surface.scale, 1.5);
    expect(surface.generation, 3);
    expect(surface.framebuffer.format, PixelFormat.bgra8888Premultiplied);
    expect(surface.framebuffer.bytesPerRow, 28);
    expect(client.created, [(0x120001, 7, 5)]);

    surface.dispose();
  });

  test('rejects an incompatible client before allocating', () {
    client.supported = false;

    expect(
      createSurface,
      throwsA(isA<UnsupportedCapabilityError>()),
    );
    expect(client.created, isEmpty);
    expect(client.destroyed, isEmpty);
  });

  test('destroys a malformed allocation before reporting it', () {
    client.bufferFactory = (_, width, height) => _FakeCpuBuffer(
          Framebuffer.allocate(width: width + 1, height: height),
        );

    expect(createSurface, throwsStateError);
    expect(client.destroyed, hasLength(1));
  });

  test('presents the whole framebuffer when damage is absent', () {
    final surface = createSurface(width: 9, height: 4);

    expect(surface.present(), isNull);
    expect(client.presented,
        [const X11CpuDamage(x: 0, y: 0, width: 9, height: 4)]);
    expect(
        identical(client.presentedBuffers.single, surface.framebuffer), isTrue);

    surface.dispose();
  });

  test('rounds logical damage outward and clips it to device bounds', () {
    final surface = createSurface(width: 10, height: 8, scale: 2);

    surface.present(damage: const Rect.fromLTRB(-1, 0.6, 3.2, 9));

    expect(
      client.presented,
      [const X11CpuDamage(x: 0, y: 1, width: 7, height: 7)],
    );
    surface.dispose();
  });

  test('fully clipped and empty damage perform no upload', () {
    final surface = createSurface();

    expect(
      surface.present(damage: const Rect.fromLTRB(20, 20, 30, 30)),
      isNull,
    );
    expect(surface.present(damage: Rect.zero), isNull);
    expect(client.presented, isEmpty);

    surface.dispose();
  });

  test('returns the client diagnostic without replacing it', () {
    const failure = BackendDiagnostic(
      kind: DiagnosticKind.connectionFailed,
      message: 'synthetic PutImage failure',
    );
    client.failure = failure;
    final surface = createSurface();

    expect(identical(surface.present(), failure), isTrue);

    surface.dispose();
  });

  test('turns an upload exception into a connection diagnostic', () {
    client.presentError = StateError('synthetic disconnect');
    final surface = createSurface();

    final result = surface.present();

    expect(result?.kind, DiagnosticKind.connectionFailed);
    expect(result?.message, 'X11 PutImage presentation threw');
    expect(result?.detail, contains('synthetic disconnect'));
    surface.dispose();
  });

  test('dispose destroys the buffer exactly once and prevents presentation',
      () {
    final surface = createSurface();
    final buffer = client.lastBuffer;

    surface.dispose();
    surface.dispose();

    expect(client.destroyed, [buffer]);
    expect(() => surface.present(), throwsStateError);
  });
}

final class _FakeCpuBuffer implements X11CpuBuffer {
  _FakeCpuBuffer(this.framebuffer);

  @override
  final Framebuffer framebuffer;
}

final class _FakeCpuClient implements X11CpuClient {
  bool supported = true;
  BackendDiagnostic? failure;
  Object? presentError;

  final List<(int, int, int)> created = <(int, int, int)>[];
  final List<X11CpuBuffer> destroyed = <X11CpuBuffer>[];
  final List<X11CpuDamage> presented = <X11CpuDamage>[];
  final List<Framebuffer> presentedBuffers = <Framebuffer>[];

  _FakeCpuBuffer Function(int window, int width, int height)? bufferFactory;
  late _FakeCpuBuffer lastBuffer;

  @override
  bool get supportsBgraPutImage => supported;

  @override
  X11CpuBuffer createCpuBuffer({
    required int xcbWindow,
    required int pixelWidth,
    required int pixelHeight,
  }) {
    created.add((xcbWindow, pixelWidth, pixelHeight));
    return lastBuffer = bufferFactory?.call(
          xcbWindow,
          pixelWidth,
          pixelHeight,
        ) ??
        _FakeCpuBuffer(
          Framebuffer(
            width: pixelWidth,
            height: pixelHeight,
            bytesPerRow: pixelWidth * 4,
            format: PixelFormat.bgra8888Premultiplied,
            pixels: Uint8List(pixelWidth * pixelHeight * 4),
          ),
        );
  }

  @override
  void destroyCpuBuffer(X11CpuBuffer buffer) {
    destroyed.add(buffer);
  }

  @override
  BackendDiagnostic? presentCpuBuffer({
    required int xcbWindow,
    required X11CpuBuffer buffer,
    required X11CpuDamage damage,
  }) {
    final error = presentError;
    if (error != null) throw error;
    expect(xcbWindow, 0x120001);
    presented.add(damage);
    presentedBuffers.add(buffer.framebuffer);
    return failure;
  }
}
