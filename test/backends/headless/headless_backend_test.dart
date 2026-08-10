import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('HeadlessWindowingBackend', () {
    test('is always available and reports its real capabilities', () {
      final probe = HeadlessWindowingBackend().probe();

      expect(probe.supported, isTrue);
      expect(probe.supports(Capability.window), isTrue);
      expect(probe.supports(Capability.cpuPresentation), isTrue);
      expect(probe.supports(Capability.pointerInput), isTrue);
      expect(probe.supports(Capability.scrollInput), isTrue);
      expect(probe.failures, isEmpty);
    });

    test('requires initialization and supports orderly reinitialization',
        () async {
      final backend = HeadlessWindowingBackend();

      expect(
        () => backend.createWindow(
          const WindowOptions(size: Size(10, 10)),
        ),
        throwsStateError,
      );

      await backend.initialize();
      final first = await backend.createWindow(
        const WindowOptions(size: Size(10, 10)),
      );
      await backend.shutdown();
      expect(first.isDisposed, isTrue);
      expect(backend.windows, isEmpty);

      await backend.initialize();
      final second = await backend.createWindow(
        const WindowOptions(size: Size(10, 10)),
      );
      expect(second.id, isNot(first.id));
      await backend.shutdown();
    });

    test('creates independent memory surfaces at the configured scale',
        () async {
      final backend = HeadlessWindowingBackend(
        renderScale: 1.5,
        desktopScale: 1.25,
      );
      await backend.initialize();

      final first = await backend.createWindow(
        const WindowOptions(size: Size(20, 10), title: 'first'),
      );
      final second = await backend.createWindow(
        const WindowOptions(size: Size(4, 6), visible: false),
      );

      expect(backend.windows, <HeadlessWindow>[first, second]);
      expect(first.memorySurface.pixelWidth, 30);
      expect(first.memorySurface.pixelHeight, 15);
      expect(first.desktopScale, 1.25);
      expect(second.isVisible, isFalse);
      expect(first.id, isNot(second.id));
      await backend.shutdown();
    });

    test('its surface is consumed directly by the CPU renderer', () async {
      final backend = HeadlessWindowingBackend();
      await backend.initialize();
      final window = await backend.createWindow(
        const WindowOptions(size: Size(4, 3)),
      );
      final device = await const CpuRendererBackend().createDevice();
      final target =
          device.createTarget(window.memorySurface) as MemoryRenderTarget;
      final list = DisplayList();
      final paint = list.addPaint(colorArgb: 0xFFFF0000);
      list.drawRectangle(const Rect.fromLTWH(0, 0, 4, 3), paint);

      final result = await target.renderDisplayList(list, clearColor: 0);

      expect(result.isSuccess, isTrue);
      expect(target.framebuffer.width, 4);
      expect(target.framebuffer.height, 3);
      final pixel = target.framebuffer.offsetOf(2, 1);
      expect(
        target.framebuffer.pixels.sublist(pixel, pixel + 4),
        <int>[0, 0, 255, 255],
      );

      target.dispose();
      device.dispose();
      await backend.shutdown();
    });

    test('resize replaces the surface and invalidates stale input', () async {
      final backend = HeadlessWindowingBackend(renderScale: 2);
      await backend.initialize();
      final window = await backend.createWindow(
        const WindowOptions(size: Size(10, 8)),
      );
      final oldSurface = window.memorySurface;
      final oldGeneration = window.generation;
      final events = <PlatformWindowEvent>[];
      final subscription = window.events.listen(events.add);

      window.setBounds(const Rect.fromLTWH(5, 7, 12, 9));

      expect(window.generation, oldGeneration + 1);
      expect(window.memorySurface, isNot(same(oldSurface)));
      expect(window.memorySurface.pixelWidth, 24);
      expect(window.memorySurface.pixelHeight, 18);
      expect(events, isEmpty);
      expect(backend.pendingEventCount, 2);
      expect(backend.pumpEvents(), isTrue);
      expect(events, hasLength(2));
      expect(events[0], isA<WindowMovedEvent>());
      expect(events[1], isA<WindowResizedEvent>());

      final stale = PointerMoveEvent(
        windowId: window.id,
        generation: oldGeneration,
        timestamp: Duration.zero,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: Offset.zero,
      );
      expect(window.dispatchInput(stale), isFalse);
      expect(events, hasLength(2));

      await subscription.cancel();
      await backend.shutdown();
    });

    test('redraw and normalized input use the platform event stream', () async {
      final backend = HeadlessWindowingBackend();
      await backend.initialize();
      final window = await backend.createWindow(
        const WindowOptions(size: Size(20, 20)),
      );
      final events = <PlatformWindowEvent>[];
      final subscription = window.events.listen(events.add);
      const damage = Rect.fromLTWH(2, 3, 4, 5);

      window.requestRedraw(damage);
      final input = PointerDownEvent(
        windowId: window.id,
        generation: window.generation,
        timestamp: const Duration(milliseconds: 12),
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: const Offset(6, 7),
        button: PointerButton.primary,
      );

      expect(window.dispatchInput(input), isTrue);
      expect(events, isEmpty);
      expect(backend.pendingEventCount, 2);
      expect(backend.pumpEvents(), isTrue);
      expect((events[0] as WindowExposedEvent).dirtyRect, damage);
      expect(events[1], same(input));

      await subscription.cancel();
      await backend.shutdown();
    });

    test('coordinates, visibility, cursor, title, and close are deterministic',
        () async {
      final backend = HeadlessWindowingBackend();
      await backend.initialize();
      final window = await backend.createWindow(
        const WindowOptions(
          size: Size(10, 10),
          position: Offset(100, 50),
          title: 'before',
        ),
      );
      final events = <PlatformWindowEvent>[];
      final subscription = window.events.listen(events.add);

      expect(window.screenToClient(const Offset(104, 53)), const Offset(4, 3));
      expect(window.clientToScreen(const Offset(4, 3)), const Offset(104, 53));
      window
        ..hide()
        ..show()
        ..setCursor(SystemCursor.hand)
        ..setTitle('after')
        ..close();

      expect(window.cursor, SystemCursor.hand);
      expect(window.title, 'after');
      expect(window.isDisposed, isTrue);
      expect(window.surfaces, isEmpty);
      expect(backend.windows, isEmpty);
      expect(events, isEmpty);
      expect(backend.pendingEventCount, 3);
      expect(backend.pumpEvents(), isFalse);
      expect(events.whereType<WindowActivationEvent>(), hasLength(2));
      expect(events.last, isA<WindowClosedEvent>());
      expect(backend.pendingEventCount, 0);

      await subscription.cancel();
      await backend.shutdown();
    });

    test('pump drains FIFO work, including events queued by listeners',
        () async {
      final backend = HeadlessWindowingBackend();
      await backend.initialize();
      final window = await backend.createWindow(
        const WindowOptions(size: Size(20, 20)),
      );
      final events = <PlatformWindowEvent>[];
      final subscription = window.events.listen((event) {
        events.add(event);
        if (event is WindowActivationEvent) {
          window.requestRedraw(const Rect.fromLTWH(1, 2, 3, 4));
        }
      });

      window.hide();

      expect(events, isEmpty);
      expect(backend.pendingEventCount, 1);
      expect(
        backend.pumpEvents(timeout: const Duration(days: 365)),
        isTrue,
      );
      expect(events, hasLength(2));
      expect(events[0], isA<WindowActivationEvent>());
      expect(events[1], isA<WindowExposedEvent>());
      expect(backend.pendingEventCount, 0);

      await subscription.cancel();
      await backend.shutdown();
    });

    test('shutdown drains close notifications without a wall-clock pump',
        () async {
      final backend = HeadlessWindowingBackend();
      await backend.initialize();
      final window = await backend.createWindow(
        const WindowOptions(size: Size(10, 10)),
      );
      final events = <PlatformWindowEvent>[];
      var streamEnded = false;
      final subscription = window.events.listen(
        events.add,
        onDone: () => streamEnded = true,
      );

      window.requestRedraw();
      await backend.shutdown();

      expect(events, hasLength(2));
      expect(events.first, isA<WindowExposedEvent>());
      expect(events.last, isA<WindowClosedEvent>());
      expect(streamEnded, isTrue);
      expect(backend.pendingEventCount, 0);

      await subscription.cancel();
    });

    test('invalid virtual geometry is rejected at the boundary', () async {
      expect(
        () => HeadlessWindowingBackend(renderScale: 0),
        throwsArgumentError,
      );
      final backend = HeadlessWindowingBackend();
      await backend.initialize();
      await expectLater(
        backend.createWindow(const WindowOptions(size: Size.zero)),
        throwsArgumentError,
      );
      final window = await backend.createWindow(
        const WindowOptions(size: Size(10, 10)),
      );
      expect(
        () => window.setBounds(Rect.zero),
        throwsArgumentError,
      );
      await backend.shutdown();
    });
  });
}
