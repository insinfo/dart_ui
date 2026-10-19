import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  test('the drag strip counts double clicks when the backend supplies no count',
      () {
    final window = _CaptionWindow();
    final harness = _Harness(WindowScope(
        controller: _Controller(window),
        child: const WindowDragArea(child: SizedBox(width: 400, height: 40))));
    addTearDown(harness.dispose);
    for (final ms in [100, 200]) {
      harness.pointer(PointerDownEvent(
          windowId: const NativeWindowId(1),
          generation: 1,
          timestamp: Duration(milliseconds: ms),
          pointerId: 0,
          kind: PointerKind.mouse,
          logicalPosition: const Offset(160, 20),
          button: PointerButton.primary));
      harness.pointer(_up(const Offset(160, 20)));
    }
    harness.frame();
    expect(window.moves, 1);
    expect(window.state, WindowState.maximised);
  });

  test('integrated caption preserves tabs, drag handle and all three controls',
      () {
    final window = _CaptionWindow();
    final controller = _Controller(window);
    var tabs = 0;
    final harness = _Harness(Theme(
        data: ThemeData.fluentLight,
        child: WindowScope(
            controller: controller,
            child: Column(children: [
              WindowDragArea(
                  child: SizedBox(
                      height: 40,
                      child: Align(
                          alignment: Alignment.centerLeft,
                          child: GestureDetector(
                              behavior: GestureHitTestBehavior.opaque,
                              onTap: () => tabs++,
                              child: const SizedBox(width: 100, height: 30))))),
              const Expanded(child: SizedBox()),
            ]))));
    addTearDown(harness.dispose);
    harness.click(const Offset(30, 20));
    expect(tabs, 1);
    expect(window.moves, 0);
    harness.click(const Offset(180, 20));
    expect(window.moves, 1);
    harness.pointer(_down(const Offset(180, 20), PointerButton.secondary));
    harness.pointer(_up(const Offset(180, 20), PointerButton.secondary));
    harness.frame();
    expect(window.windowMenus, [const Offset(180, 20)]);
    harness.pointer(_move(const Offset(377, 16)));
    harness.frame();
    expect(window.moves, 1);
    harness.click(const Offset(285, 16));
    expect(window.minimizes, 1);
    harness.click(const Offset(330, 16));
    expect(window.state, WindowState.maximised);
    harness.click(const Offset(377, 16));
    expect(window.closes, 1);
    expect(window.moves, 1);
    // A fullscreen transition removes the controls without changing tab input.
    window.systemButtons.value = Rect.zero;
    harness.frame();
    harness.click(const Offset(30, 20));
    expect(tabs, 2);
    expect(window.closes, 1);
  });
}

final class _Controller implements WindowController {
  _Controller(this.hiddenTitleBar);
  @override
  final HiddenTitleBarWindow hiddenTitleBar;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _CaptionWindow implements ClientCaptionWindow {
  @override
  final systemButtons =
      ValueNotifier<Rect>(const Rect.fromLTWH(262, 0, 138, 32));
  @override
  bool get isTitleBarHidden => true;
  @override
  double get titleBarHeight => 40;
  @override
  bool get canMinimize => true;
  @override
  bool get canMaximize => true;
  @override
  final ValueNotifier<WindowState> captionState =
      ValueNotifier<WindowState>(WindowState.normal);
  WindowState get state => captionState.value;
  int moves = 0, minimizes = 0, closes = 0;
  @override
  bool showWindowMenu(Offset position) {
    windowMenus.add(position);
    return true;
  }

  final List<Offset> windowMenus = [];
  @override
  bool beginMove() {
    moves++;
    return true;
  }

  @override
  void minimize() {
    minimizes++;
  }

  @override
  void requestClose() {
    closes++;
  }

  @override
  void toggleMaximized() {
    captionState.value = state == WindowState.maximised
        ? WindowState.normal
        : WindowState.maximised;
  }
}

final class _Harness {
  _Harness(Widget widget, {Size size = const Size(400, 300)}) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(rootConstraints: BoxConstraints.tight(size)),
    );
    owner.updateRoot(widget);
    frame();
  }

  late final BuildOwner owner;

  void frame({int maxPasses = 8}) {
    for (int pass = 0; pass < maxPasses; pass++) {
      if (owner.hasScheduledBuilds) owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
    throw StateError('the tree never settled');
  }

  bool pointer(PointerEvent event) => owner.dispatchPointerEvent(event);

  void click(Offset at) {
    pointer(_down(at));
    pointer(_up(at));
    frame();
  }

  void dispose() => owner.dispose();
}

const NativeWindowId _window = NativeWindowId(1);

PointerDownEvent _down(Offset at,
        [PointerButton button = PointerButton.primary]) =>
    PointerDownEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
      button: button,
    );

PointerMoveEvent _move(Offset at) => PointerMoveEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
    );

PointerUpEvent _up(Offset at, [PointerButton button = PointerButton.primary]) =>
    PointerUpEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
      button: button,
    );
