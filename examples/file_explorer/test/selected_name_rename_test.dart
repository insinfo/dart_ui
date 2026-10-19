import 'package:dart_ui/dart_ui.dart';
import 'package:file_explorer/src/ui/selected_name_rename.dart';
import 'package:test/test.dart';

void main() {
  test(
      'selected-name rename waits, declines first click, double click and drag',
      () {
    final clock = ManualDispatcher();
    final owner = BuildOwner(
        pipelineOwner: PipelineOwner(
            rootConstraints: BoxConstraints.tight(const Size(100, 30))));
    addTearDown(owner.dispose);
    var selected = false;
    var renames = 0;
    owner.updateRoot(GestureScope(
        dispatcher: clock,
        child: SelectedNameRename(
            isEligible: () => selected,
            onRename: () => renames++,
            child: const SizedBox(width: 100, height: 30))));
    owner.buildScope();
    owner.pipelineOwner.drawFrame(DisplayList());
    void click(int ms, {int count = 1, bool drag = false}) {
      owner.dispatchPointerEvent(PointerDownEvent(
          windowId: const NativeWindowId(1),
          generation: 1,
          timestamp: Duration(milliseconds: ms),
          pointerId: 0,
          kind: PointerKind.mouse,
          logicalPosition: const Offset(10, 10),
          button: PointerButton.primary,
          clickCount: count));
      selected = true;
      if (drag) {
        owner.dispatchPointerEvent(PointerMoveEvent(
            windowId: const NativeWindowId(1),
            generation: 1,
            timestamp: Duration(milliseconds: ms + 1),
            pointerId: 0,
            kind: PointerKind.mouse,
            logicalPosition: const Offset(25, 10)));
      }
      owner.dispatchPointerEvent(PointerUpEvent(
          windowId: const NativeWindowId(1),
          generation: 1,
          timestamp: Duration(milliseconds: ms + 2),
          pointerId: 0,
          kind: PointerKind.mouse,
          logicalPosition: const Offset(10, 10),
          button: PointerButton.primary));
    }

    click(0);
    clock.advance(const Duration(seconds: 1));
    expect(renames, 0, reason: 'the click that selects must not rename');
    click(1000);
    clock.advance(const Duration(milliseconds: 499));
    expect(renames, 0);
    clock.advance(const Duration(milliseconds: 1));
    expect(renames, 1);
    click(2000);
    click(2100, count: 2);
    clock.advance(const Duration(seconds: 1));
    expect(renames, 1, reason: 'double click cancels the pending rename');
    click(3000, drag: true);
    clock.advance(const Duration(seconds: 1));
    expect(renames, 1, reason: 'dragging does not rename');
    click(4000);
    selected = false;
    clock.advance(const Duration(seconds: 1));
    expect(renames, 1, reason: 'selection must still belong to this item');
    selected = true;
    click(5000);
    owner.updateRoot(const SizedBox());
    owner.buildScope();
    owner.pipelineOwner.drawFrame(DisplayList());
    clock.advance(const Duration(seconds: 1));
    expect(renames, 1, reason: 'discarded labels cancel their timer');
  });
}
