import 'dart:async';
import 'dart:typed_data';

import 'package:dart_ui/src/backends/wayland/wayland_cpu_presenter.dart';
import 'package:dart_ui/src/backends/wayland/wayland_shm.dart';
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
  late WaylandCpuPresenter presenter;
  final diagnostics = <BackendDiagnostic>[];
  final errors = <Object>[];

  setUp(() {
    events = StreamController<PlatformWindowEvent>.broadcast();
    surface = _FakeSurface(width: 6, height: 5, generation: 1);
    diagnostics.clear();
    errors.clear();
    presenter = WaylandCpuPresenter.withSurfaceProvider(
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

  test('rasterises a display list into the shm framebuffer', () async {
    final result = await presenter.renderDisplayList(
      redRectangle(),
      clearColor: 0,
    );

    expect(result.status, PresentStatus.presented);
    expect(surface.presentedDamage, <Rect?>[null]);
    expect(_rgbaAt(surface.framebuffer, 2, 2), (255, 0, 0, 255));
    expect(_rgbaAt(surface.framebuffer, 0, 0), (0, 0, 0, 0));
  });

  // Unit tests for the pacing seam. They prove the presenter *uses* the
  // commit hook; that the hook the production constructor installs is the
  // window's paced `present` - and that a real compositor then answers with a
  // frame callback - is what `tool/wayland_backend_smoke.dart` proves under
  // Weston, because no fake can send a frame callback it was not written to
  // send.
  test('commits through the pacing hook rather than the surface', () async {
    final damages = <Rect?>[];
    final paced = WaylandCpuPresenter.withSurfaceProvider(
      surfaceProvider: () => surface,
      commit: ({Rect? damage}) {
        damages.add(damage);
        return null;
      },
      events: events.stream,
      onDiagnostic: diagnostics.add,
      onError: (error, _) => errors.add(error),
    );
    addTearDown(paced.dispose);

    final result = await paced.renderDisplayList(
      redRectangle(),
      clearColor: 0,
      damage: const Rect.fromLTWH(1, 1, 4, 4),
    );

    expect(result.status, PresentStatus.presented);
    expect(damages, <Rect?>[const Rect.fromLTWH(1, 1, 4, 4)]);
    // The pixels were still rasterised; only the commit changed hands.
    expect(_rgbaAt(surface.framebuffer, 2, 2), (255, 0, 0, 255));
    expect(surface.presentedDamage, isEmpty);
  });

  test('a coalesced commit is presented, not a failure', () async {
    // The window returns null both when it committed and when it coalesced
    // the frame behind an in-flight callback. Nothing is lost in the second
    // case - the damage is replayed as an expose - so the presenter must not
    // report it as a failed frame.
    var calls = 0;
    final paced = WaylandCpuPresenter.withSurfaceProvider(
      surfaceProvider: () => surface,
      commit: ({Rect? damage}) {
        calls++;
        return null;
      },
      events: events.stream,
    );
    addTearDown(paced.dispose);

    final first = await paced.renderDisplayList(redRectangle(), clearColor: 0);
    final second = await paced.renderDisplayList(redRectangle(), clearColor: 0);

    expect(first.status, PresentStatus.presented);
    expect(second.status, PresentStatus.presented);
    expect(calls, 2);
  });

  test('an expose re-commits retained pixels and forwards its damage',
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
    await presenter.renderDisplayList(redRectangle(), clearColor: 0);
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

  test('a scale change also replays into the new surface', () async {
    await presenter.renderDisplayList(redRectangle(), clearColor: 0);
    surface = _FakeSurface(width: 12, height: 10, generation: 2, scale: 2);

    events.add(
      const WindowScaleChangedEvent(
        windowId: NativeWindowId(7),
        generation: 2,
        renderScale: 2,
        desktopScale: 2,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await presenter.idle;

    expect(surface.presentedDamage, <Rect?>[null]);
  });

  test(
      'the first expose after a configure replays instead of committing '
      'stale pixels', () async {
    await presenter.renderDisplayList(redRectangle(), clearColor: 0);
    // A new generation arrives with no frame presented into it yet.
    surface = _FakeSurface(width: 6, height: 5, generation: 2);

    events.add(
      const WindowExposedEvent(
        windowId: NativeWindowId(7),
        generation: 2,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await presenter.idle;

    expect(surface.presentedDamage, <Rect?>[null],
        reason: 'the retained list must be rasterised, then committed whole');
    expect(_rgbaAt(surface.framebuffer, 2, 2), (255, 0, 0, 255));
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

  test('rejects a frame when the surface identity changes before present',
      () async {
    final first = surface;
    final replacement = _FakeSurface(width: 6, height: 5, generation: 1);
    var reads = 0;
    presenter.dispose();
    presenter = WaylandCpuPresenter.withSurfaceProvider(
      surfaceProvider: () => ++reads == 1 ? first : replacement,
      events: events.stream,
      onDiagnostic: diagnostics.add,
      onError: (error, _) => errors.add(error),
    );

    final result = await presenter.renderDisplayList(
      redRectangle(),
      clearColor: 0,
    );

    expect(result.status, PresentStatus.stale);
    expect(first.presentedDamage, isEmpty);
    expect(replacement.presentedDamage, isEmpty);
  });

  test('automatic resize replay reports presentation diagnostics', () async {
    await presenter.renderDisplayList(redRectangle(), clearColor: 0);
    const failure = BackendDiagnostic(
      kind: DiagnosticKind.connectionFailed,
      message: 'synthetic commit failure',
    );
    surface = _FakeSurface(width: 8, height: 7, generation: 2)
      ..failure = failure;

    events.add(
      const WindowResizedEvent(
        windowId: NativeWindowId(7),
        generation: 2,
        clientSize: Size(8, 7),
        renderScale: 1,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await presenter.idle;

    expect(diagnostics, [failure]);
  });

  test('expose commit exceptions reach the error callback', () async {
    await presenter.renderDisplayList(redRectangle(), clearColor: 0);
    surface.presentError = StateError('synthetic expose failure');

    events.add(
      const WindowExposedEvent(
        windowId: NativeWindowId(7),
        generation: 1,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(errors.single, isA<StateError>());
  });

  test('dispose cancels event-driven presentation', () async {
    await presenter.renderDisplayList(redRectangle(), clearColor: 0);
    final count = surface.presentedDamage.length;
    presenter.dispose();

    events.add(
      const WindowExposedEvent(
        windowId: NativeWindowId(7),
        generation: 1,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(surface.presentedDamage, hasLength(count));
    expect(() => presenter.renderDisplayList(redRectangle()), throwsStateError);
  });
}

(int, int, int, int) _rgbaAt(Framebuffer buffer, int x, int y) {
  final index = buffer.offsetOf(x, y);
  return (
    buffer.pixels[index + 2],
    buffer.pixels[index + 1],
    buffer.pixels[index],
    buffer.pixels[index + 3],
  );
}

final class _FakeSurface implements WaylandCpuSurface {
  _FakeSurface({
    required int width,
    required int height,
    required this.generation,
    this.scale = 1,
  })  : pixelWidth = width,
        pixelHeight = height,
        framebuffer = Framebuffer(
          width: width,
          height: height,
          bytesPerRow: width * 4,
          format: PixelFormat.bgra8888Premultiplied,
          pixels: Uint8List(width * 4 * height),
        );

  @override
  String get kind => 'fake-wayland-shm';

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
  Object? presentError;

  @override
  BackendDiagnostic? present({Rect? damage}) {
    final error = presentError;
    if (error != null) throw error;
    presentedDamage.add(damage);
    return failure;
  }
}
