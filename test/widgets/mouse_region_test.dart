import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

PointerMoveEvent _move(Offset at) => PointerMoveEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
    );

void main() {
  test('the innermost region under the pointer sets the cursor', () {
    final List<SystemCursor> shown = <SystemCursor>[];
    final BuildOwner owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(200, 100)),
      ),
    )..onCursorChanged = shown.add;
    owner.updateRoot(const Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          width: 100,
          child: MouseRegion(
            cursor: SystemCursor.hand,
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: MouseRegion(cursor: SystemCursor.text),
              ),
            ),
          ),
        ),
        Expanded(child: SizedBox()),
      ],
    ));
    owner.pipelineOwner.drawFrame(DisplayList());

    owner.dispatchPointerEvent(_move(const Offset(10, 10)));
    expect(shown, <SystemCursor>[SystemCursor.hand]);
    owner.dispatchPointerEvent(_move(const Offset(12, 10)));
    expect(shown, hasLength(1), reason: 'only changes are reported');
    owner.dispatchPointerEvent(_move(const Offset(50, 50)));
    expect(shown.last, SystemCursor.text, reason: 'nested region wins');
    owner.dispatchPointerEvent(_move(const Offset(150, 50)));
    expect(shown.last, SystemCursor.arrow, reason: 'outside every region');
  });
}
