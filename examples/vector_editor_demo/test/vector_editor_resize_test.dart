/// Resizing or maximizing the editor window must redraw it, not leave it
/// blank - reported on macOS on 12/10/2026.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

import 'package:vector_editor_demo/src/ui/app.dart';

void main() {
  setUpAll(FrameworkFonts.install);
  tearDownAll(FontRegistry.instance.reset);

  test('a resized window draws its next frame without errors', () async {
    final Application app = await Application.start(
      rootWidget: const VectorEditorApp(),
      backends: <WindowingBackendEntry>[
        const WindowingBackendEntry(
            name: 'headless', create: HeadlessWindowingBackend.new),
      ],
      options: const ApplicationOptions(size: Size(1200, 800)),
    );
    await app.drawFrame();
    final window = app.primaryWindow;
    final HeadlessWindow native = window.nativeWindow as HeadlessWindow;
    for (final Size size in <Size>[
      const Size(1600, 1000),
      const Size(1000, 700),
      const Size(1920, 1080),
    ]) {
      native.setBounds(Rect.fromLTWH(0, 0, size.width, size.height));
      for (var i = 0; i < 4; i++) {
        app.backend.pumpEvents();
        await Future<void>.delayed(Duration.zero);
        await app.drawPendingFrames();
      }
      final errors = window.buildOwner.errorReporter.errors;
      expect(errors, isEmpty,
          reason: errors.isEmpty
              ? null
              : '${errors.first.cause}\n${errors.first.stackTrace}');
    }
    app.dispose();
    await app.closed;
  });
}
