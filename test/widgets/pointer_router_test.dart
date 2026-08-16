import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('pointer routing', () {
    test('a primary down/up pair invokes GestureDetector.onTap', () {
      final BuildOwner owner = _owner();
      int taps = 0;
      owner.updateRoot(
        GestureDetector(
          onTap: () => taps++,
          child: const ColoredBox(color: 1),
        ),
      );
      owner.pipelineOwner.flushLayout();

      expect(owner.dispatchPointerEvent(_down(const Offset(5, 5))), isTrue);
      expect(taps, 0);
      expect(owner.dispatchPointerEvent(_up(const Offset(5, 5))), isTrue);
      expect(taps, 1);
    });

    test('events outside the hit-tested render tree do not trigger a tap', () {
      final BuildOwner owner = _owner();
      int taps = 0;
      owner.updateRoot(
        GestureDetector(
          onTap: () => taps++,
          child: const ColoredBox(color: 1),
        ),
      );
      owner.pipelineOwner.flushLayout();

      expect(owner.dispatchPointerEvent(_down(const Offset(30, 5))), isFalse);
      expect(owner.dispatchPointerEvent(_up(const Offset(30, 5))), isFalse);
      expect(taps, 0);
    });

    test('requires matching pointer and primary button', () {
      final BuildOwner owner = _owner();
      int taps = 0;
      owner.updateRoot(
        GestureDetector(
          onTap: () => taps++,
          child: const ColoredBox(color: 1),
        ),
      );
      owner.pipelineOwner.flushLayout();

      owner.dispatchPointerEvent(_down(const Offset(5, 5), pointerId: 1));
      owner.dispatchPointerEvent(_up(const Offset(5, 5), pointerId: 2));
      owner.dispatchPointerEvent(
        _down(const Offset(5, 5), button: PointerButton.secondary),
      );
      owner.dispatchPointerEvent(
        _up(const Offset(5, 5), button: PointerButton.secondary),
      );

      expect(taps, 0);
    });

    test('release outside cancels instead of arming a later outside drag', () {
      final BuildOwner owner = _owner();
      int taps = 0;
      owner.updateRoot(
        GestureDetector(
          onTap: () => taps++,
          child: const ColoredBox(color: 1),
        ),
      );
      owner.pipelineOwner.flushLayout();

      owner.dispatchPointerEvent(_down(const Offset(5, 5)));
      owner.dispatchPointerEvent(_up(const Offset(30, 5)));
      owner.dispatchPointerEvent(_down(const Offset(30, 5)));
      owner.dispatchPointerEvent(_up(const Offset(5, 5)));

      expect(taps, 0);
    });

    test('the innermost detector wins a nested tap', () {
      final BuildOwner owner = _owner();
      final List<String> calls = <String>[];
      owner.updateRoot(
        GestureDetector(
          onTap: () => calls.add('outer'),
          child: GestureDetector(
            onTap: () => calls.add('inner'),
            child: const ColoredBox(color: 1),
          ),
        ),
      );
      owner.pipelineOwner.flushLayout();

      owner.dispatchPointerEvent(_down(const Offset(5, 5)));
      owner.dispatchPointerEvent(_up(const Offset(5, 5)));

      expect(calls, <String>['inner']);
    });

    test('an in-place widget update changes the callback', () {
      final BuildOwner owner = _owner();
      final List<String> calls = <String>[];
      owner.updateRoot(
        GestureDetector(
          onTap: () => calls.add('old'),
          child: const ColoredBox(color: 1),
        ),
      );
      final RenderBox renderObject = owner.renderRoot!;
      owner.updateRoot(
        GestureDetector(
          onTap: () => calls.add('new'),
          child: const ColoredBox(color: 2),
        ),
      );
      owner.pipelineOwner.flushLayout();

      owner.dispatchPointerEvent(_down(const Offset(5, 5)));
      owner.dispatchPointerEvent(_up(const Offset(5, 5)));

      expect(owner.renderRoot, same(renderObject));
      expect(calls, <String>['new']);
    });
  });
}

BuildOwner _owner() => BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(20, 10)),
      ),
    );

PointerDownEvent _down(
  Offset position, {
  int pointerId = 0,
  PointerButton button = PointerButton.primary,
}) =>
    PointerDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: pointerId,
      kind: PointerKind.mouse,
      logicalPosition: position,
      button: button,
    );

PointerUpEvent _up(
  Offset position, {
  int pointerId = 0,
  PointerButton button = PointerButton.primary,
}) =>
    PointerUpEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: pointerId,
      kind: PointerKind.mouse,
      logicalPosition: position,
      button: button,
    );
