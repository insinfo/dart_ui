import 'dart:async';
import 'dart:typed_data';

import 'package:dart_ui/src/backends/win32/win32_cpu_presenter.dart';
import 'package:dart_ui/src/backends/win32/win32_dib_surface.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/platform/window_events.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';

void main() {
  late StreamController<PlatformWindowEvent> events;
  late _FakeSurface surface;
  late Win32CpuPresenter presenter;
  final diagnostics = <BackendDiagnostic>[];
  final errors = <Object>[];

  setUp(() {
    events = StreamController<PlatformWindowEvent>.broadcast();
    surface = _FakeSurface(width: 6, height: 5, generation: 1);
    diagnostics.clear();
    errors.clear();
    presenter = Win32CpuPresenter.withSurfaceProvider(
      surfaceProvider: () => surface,
      events: events.stream,
      onDiagnostic: diagnostics.add,
      onError: (error, _) => errors.add(error),
    );
  });

  tearDown(() async {
    presenter.dispose();
    await events.close();
  });

  DisplayList redRectangle() {
    final list = DisplayList();
    list.drawRect(1, 1, 4, 4, list.addPaint(colorArgb: 0xFFFF0000));
    return list;
  }

  test('rasterises a display list into the DIB-shaped framebuffer', () async {
    final result = await presenter.renderDisplayList(
      redRectangle(),
      clearColor: 0,
    );

    expect(result.status, PresentStatus.presented);
    expect(surface.presentedDamage, <Rect?>[null]);
    expect(_rgbaAt(surface.framebuffer, 2, 2), (255, 0, 0, 255));
    expect(_rgbaAt(surface.framebuffer, 0, 0), (0, 0, 0, 0));
  });

  test('direct rasterization respects DIB stride and row padding', () async {
    surface = _FakeSurface(
      width: 3,
      height: 3,
      generation: 1,
      bytesPerRow: 20,
      paddingByte: 0xA5,
    );
    final list = DisplayList();
    list.drawRect(0, 0, 3, 3, list.addPaint(colorArgb: 0xFF00FF00));

    await presenter.renderDisplayList(list, clearColor: 0);

    for (var y = 0; y < 3; y++) {
      expect(
        surface.framebuffer.pixels.sublist(y * 20 + 12, y * 20 + 20),
        everyElement(0xA5),
      );
    }
  });

  test('an expose reblits retained DIB pixels and honours its damage',
      () async {
    await presenter.renderDisplayList(redRectangle(), clearColor: 0);
    const damage = Rect.fromLTRB(1, 2, 3, 4);

    events.add(
      const WindowExposedEvent(
        windowId: NativeWindowId(7),
        generation: 1,
        dirtyRect: damage,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(surface.presentedDamage, <Rect?>[null, damage]);
    expect(_rgbaAt(surface.framebuffer, 2, 2), (255, 0, 0, 255));
  });

  test('resize replays and rescales into the replacement surface', () async {
    final list = redRectangle();
    await presenter.renderDisplayList(list, clearColor: 0);
    surface = _FakeSurface(width: 10, height: 8, generation: 2, scale: 2);

    events.add(
      const WindowResizedEvent(
        windowId: NativeWindowId(7),
        generation: 2,
        clientSize: Size(5, 4),
        renderScale: 2,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await presenter.idle;

    expect(surface.presentedDamage, <Rect?>[null]);
    expect(_rgbaAt(surface.framebuffer, 6, 6), (255, 0, 0, 255));
    expect(errors, isEmpty);
  });

  test('late expose from an old surface generation is ignored', () async {
    await presenter.renderDisplayList(redRectangle(), clearColor: 0);
    surface = _FakeSurface(width: 6, height: 5, generation: 2);

    events.add(
      const WindowExposedEvent(
        windowId: NativeWindowId(7),
        generation: 1,
        dirtyRect: Rect.fromLTRB(0, 0, 2, 2),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(surface.presentedDamage, isEmpty);
    expect(diagnostics, isEmpty);
    expect(errors, isEmpty);
  });
}

(int, int, int, int) _rgbaAt(Framebuffer buffer, int x, int y) {
  final index = buffer.offsetOf(x, y);
  return switch (buffer.format) {
    PixelFormat.bgra8888Premultiplied => (
        buffer.pixels[index + 2],
        buffer.pixels[index + 1],
        buffer.pixels[index],
        buffer.pixels[index + 3],
      ),
    PixelFormat.rgba8888Premultiplied => (
        buffer.pixels[index],
        buffer.pixels[index + 1],
        buffer.pixels[index + 2],
        buffer.pixels[index + 3],
      ),
  };
}

final class _FakeSurface implements Win32CpuSurface {
  _FakeSurface({
    required int width,
    required int height,
    required this.generation,
    int? bytesPerRow,
    int paddingByte = 0,
    this.scale = 1,
  })  : pixelWidth = width,
        pixelHeight = height,
        framebuffer = Framebuffer(
          width: width,
          height: height,
          bytesPerRow: bytesPerRow ?? width * 4,
          format: PixelFormat.bgra8888Premultiplied,
          pixels: Uint8List((bytesPerRow ?? width * 4) * height)
            ..fillRange(
              0,
              (bytesPerRow ?? width * 4) * height,
              paddingByte,
            ),
        );

  @override
  String get kind => 'fake-win32-dib';

  @override
  final int pixelWidth;

  @override
  final int pixelHeight;

  @override
  final double scale;

  @override
  final int generation;

  @override
  final Framebuffer framebuffer;

  final List<Rect?> presentedDamage = <Rect?>[];
  BackendDiagnostic? failure;

  @override
  BackendDiagnostic? present({Rect? damage}) {
    presentedDamage.add(damage);
    return failure;
  }
}
