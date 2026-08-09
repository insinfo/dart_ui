import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/win32/win32_backend.dart';

void main() async {
  final backend = Win32WindowingBackend();
  await backend.initialize();

  final window = await backend.createWindow(
    const WindowOptions(
      title: 'Hello Button (dart_ui Win32 CPU)',
      size: Size(400, 300),
    ),
  );

  bool running = true;

  window.events.listen((event) {
    if (event is WindowCloseRequestedEvent) {
      window.close();
    } else if (event is WindowClosedEvent) {
      running = false;
    } else if (event is PointerDownEvent) {
      print('Pointer down at ${event.logicalPosition} button ${event.button}');
    } else if (event is PointerUpEvent) {
      print('Pointer up at ${event.logicalPosition} button ${event.button}');
    } else if (event is PointerMoveEvent) {
      print('Pointer move at ${event.logicalPosition}');
    } else if (event is WindowPointerEnterEvent) {
      print('Pointer entered window');
    } else if (event is WindowPointerLeaveEvent) {
      print('Pointer left window');
    } else if (event is KeyDownEvent) {
      print('Key down: ${event.logicalKey}');
    } else if (event is KeyUpEvent) {
      print('Key up: ${event.logicalKey}');
    } else if (event is WindowExposedEvent) {
      // Paint something simple since we don't have the widget tree fully wired
      // to paint onto a window yet (RenderBox logic and LayerTree is not fully built).
      final rect = event.dirtyRect ?? const Rect.fromLTWH(0, 0, 400, 300);
      print('Window exposed: $rect');
    }
  });

  while (running) {
    if (!backend.pumpEvents(timeout: const Duration(milliseconds: 16))) {
      running = false;
    }
  }

  await backend.shutdown();
}
