import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  test('bounded draggable clamps every edge and oversized children', () {
    expect(
      BoundedDraggable.clampPosition(
        position: const Offset(-20, 90),
        size: const Size(40, 30),
        bounds: const Size(100, 100),
      ),
      const Offset(0, 70),
    );
    expect(
      BoundedDraggable.clampPosition(
        position: const Offset(50, 50),
        size: const Size(120, 130),
        bounds: const Size(100, 100),
      ),
      Offset.zero,
    );
  });

  test('posição absoluta preserva o ponto de captura sem acumular deltas', () {
    expect(
      BoundedDraggable.positionFromDrag(
        startPosition: const Offset(100, 80),
        pointerDown: const Offset(125, 95),
        currentPointer: const Offset(190, 170),
      ),
      const Offset(165, 155),
    );
  });
}
