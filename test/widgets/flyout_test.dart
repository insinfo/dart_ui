/// A Flyout: any widget in a light-dismiss popup at an anchor, closed by a
/// click outside, by Escape - before the dialog it may sit in - and by its
/// anchor going away.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

KeyDownEvent _down(int key) => KeyDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      physicalKey: key,
      logicalKey: key,
    );

PointerDownEvent _press(Offset at) => PointerDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
      button: PointerButton.primary,
    );

PointerUpEvent _release(Offset at) => PointerUpEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
      button: PointerButton.primary,
    );

final class _Content extends StatelessWidget {
  const _Content();

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 120,
        height: 80,
        child: Button(label: 'Inside', onPressed: () {}),
      );
}

void main() {
  late BuildOwner owner;
  late FlyoutController controller;
  late BuildContext window;

  void frame() {
    for (var i = 0; i < 8; i++) {
      owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
  }

  T? find<T extends RenderBox>() {
    T? found;
    void walk(RenderBox node) {
      if (found != null) return;
      if (node is T) {
        found = node;
        return;
      }
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found;
  }

  RenderButton? button(String label) {
    RenderButton? found;
    void walk(RenderBox node) {
      if (node is RenderButton && node.label == label) found = node;
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found;
  }

  Widget flyout({bool anchored = true, ThemeData? theme}) {
    Widget anchor = Builder(builder: (BuildContext context) {
      window = context;
      return Align(
        alignment: Alignment.topLeft,
        child: anchored
            ? Flyout(
                controller: controller,
                builder: (_, FlyoutController c) =>
                    Button(label: 'Open', onPressed: c.toggle),
                content: (_, __) => const _Content(),
              )
            : const SizedBox(),
      );
    });
    if (theme != null) anchor = Theme(data: theme, child: anchor);
    return Directionality(
      textDirection: TextDirection.leftToRight,
      child: PopupScope(child: anchor),
    );
  }

  void mount({ThemeData? theme}) {
    controller = FlyoutController();
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(400, 300)),
      ),
    )..updateRoot(flyout(theme: theme));
    frame();
  }

  tearDown(() => owner.dispose());

  test('the controller opens and closes it, and says so', () {
    mount();
    final List<bool> heard = <bool>[];
    controller.addListener(() => heard.add(controller.isOpen));
    expect(button('Inside'), isNull);
    controller.open();
    frame();
    expect(controller.isOpen, isTrue);
    expect(button('Inside'), isNotNull);
    final Offset at = button('Inside')!.localToGlobal(Offset.zero);
    expect(at.dy, greaterThanOrEqualTo(button('Open')!.size.height),
        reason: 'below its anchor');
    expect(owner.focusManager.primaryFocus, isNotNull,
        reason: 'its first control took the keyboard');
    controller.toggle();
    frame();
    expect(controller.isOpen, isFalse);
    expect(button('Inside'), isNull);
    expect(heard, <bool>[true, false]);
  });

  test('a click outside closes it', () {
    mount();
    controller.open();
    frame();
    owner
      ..dispatchPointerEvent(_press(const Offset(380, 280)))
      ..dispatchPointerEvent(_release(const Offset(380, 280)));
    frame();
    expect(controller.isOpen, isFalse);
  });

  test('its anchor going away takes it along', () {
    mount();
    controller.open();
    frame();
    owner.updateRoot(flyout(anchored: false));
    frame();
    expect(button('Inside'), isNull, reason: 'no orphan popup');
  });

  test('the content wears the anchor\'s theme on a raised surface', () {
    mount(theme: ThemeData.neutralDark);
    controller.open();
    frame();
    final RenderDecoratedBox surface = find<RenderDecoratedBox>()!;
    expect((surface.decoration as BoxDecoration).color,
        ThemeData.neutralDark.surfaceRaised);
  });

  test('Escape closes the flyout, not the dialog it sits in', () async {
    mount();
    var dialogOpen = true;
    final FlyoutController inner = FlyoutController();
    showDialog<void>(
      context: window,
      builder: (_) => Flyout(
        controller: inner,
        builder: (_, FlyoutController c) =>
            Button(label: 'In dialog', onPressed: c.open),
        content: (_, __) => const _Content(),
      ),
    ).then((_) => dialogOpen = false);
    frame();
    inner.open();
    frame();
    expect(inner.isOpen, isTrue);
    expect(owner.dispatchKeyEvent(_down(logicalKeyEscape)), isTrue);
    frame();
    await Future<void>.delayed(Duration.zero);
    expect(inner.isOpen, isFalse);
    expect(dialogOpen, isTrue, reason: 'only the flyout closed');
    owner.dispatchKeyEvent(_down(logicalKeyEscape));
    frame();
    await Future<void>.delayed(Duration.zero);
    expect(dialogOpen, isFalse, reason: 'the next Escape is the dialog\'s');
  });
}
