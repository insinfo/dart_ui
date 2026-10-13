import 'dart:async';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/immediate.dart';
import 'package:test/test.dart';

/// The immediate mode inside a real application: a headless window, a click
/// delivered through the backend and the pointer router, a frame drawn.
void main() {
  Future<(Application, HeadlessWindow)> start(void Function(Ui) build) async {
    final Application app = await Application.start(
      rootWidget: ImmediateArea(builder: build),
      backends: <WindowingBackendEntry>[
        const WindowingBackendEntry(
            name: 'headless', create: HeadlessWindowingBackend.new),
      ],
      options: const ApplicationOptions(size: Size(400, 300)),
    );
    await app.drawFrame();
    final HeadlessWindow window =
        app.primaryWindow.nativeWindow as HeadlessWindow;
    return (app, window);
  }

  void click(HeadlessWindow window, Offset at) {
    for (final bool down in <bool>[true, false]) {
      window.dispatchInput(down
          ? PointerDownEvent(
              windowId: window.id,
              generation: window.generation,
              timestamp: Duration.zero,
              pointerId: 0,
              kind: PointerKind.mouse,
              logicalPosition: at,
              button: PointerButton.primary,
            )
          : PointerUpEvent(
              windowId: window.id,
              generation: window.generation,
              timestamp: Duration.zero,
              pointerId: 0,
              kind: PointerKind.mouse,
              logicalPosition: at,
              button: PointerButton.primary,
            ));
    }
  }

  /// Delivers what is queued and draws the frames something asked for -
  /// only those, as the application loop does.
  Future<void> settle(Application app) async {
    for (var i = 0; i < 4; i++) {
      app.backend.pumpEvents();
      await Future<void>.delayed(Duration.zero);
      await app.drawPendingFrames();
    }
  }

  test('a click on an immediate button runs its branch once', () async {
    var clicks = 0;
    var frames = 0;
    final (Application app, HeadlessWindow window) = await start((Ui ui) {
      frames++;
      if (ui.button('Contar')) clicks++;
      ui.label('cliques: $clicks');
    });
    expect(frames, greaterThanOrEqualTo(1));
    click(window, const Offset(10, 10));
    await settle(app);
    expect(clicks, 1);
    click(window, const Offset(10, 10));
    await settle(app);
    expect(clicks, 2);
    app.dispose();
    await app.closed;
  });

  test('typing reaches a focused immediate text field', () async {
    var text = '';
    final (Application app, HeadlessWindow window) =
        await start((Ui ui) => text = ui.textField(text, key: 'campo'));
    click(window, const Offset(10, 10));
    await settle(app);
    window.dispatchInput(TextInputEvent(
      windowId: window.id,
      generation: window.generation,
      timestamp: Duration.zero,
      text: 'olá',
    ));
    await settle(app);
    expect(text, 'olá');
    app.dispose();
    await app.closed;
  });

  test('an idle area stops drawing', () async {
    var frames = 0;
    final (Application app, HeadlessWindow _) = await start((Ui ui) {
      frames++;
      ui.label('parado');
    });
    await settle(app);
    final int before = frames;
    await settle(app);
    expect(frames, before, reason: 'no input, nothing asked for a frame');
    app.dispose();
    await app.closed;
  });
}
