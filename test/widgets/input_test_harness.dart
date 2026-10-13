/// A window without a window, for the input tests of Flutter's `Listener`,
/// `Draggable`, `Dismissible`, `InteractiveViewer`, `Focus` and
/// `Shortcuts`: a build owner with a virtual clock, an animation scope, a
/// gesture scope and an overlay, and helpers that send pointer and key
/// events with advancing timestamps.
library;

import 'package:dart_ui/dart_ui.dart';

const NativeWindowId inputTestWindow = NativeWindowId(1);
const Duration inputTestFrame = Duration(milliseconds: 16);

final class InputHarness {
  InputHarness(
    Widget child, {
    Size size = const Size(400, 300),
    bool overlay = true,
  }) {
    dispatcher = ManualDispatcher();
    pipeline = PipelineOwner(rootConstraints: BoxConstraints.tight(size));
    final FrameScheduler scheduler = FrameScheduler(
      dispatcher: dispatcher,
      pipelineOwner: pipeline,
      frameInterval: inputTestFrame,
      onFrame: (DisplayList list) {},
    );
    clock = AnimationClock()..attachTo(scheduler);
    owner = BuildOwner(
      pipelineOwner: pipeline,
      onBuildScheduled: scheduler.scheduleFrame,
    );
    Widget root = child;
    if (overlay) {
      root = Overlay(
        initialEntries: <OverlayEntry>[
          OverlayEntry(builder: (BuildContext context) => child),
        ],
      );
    }
    root = GestureScope(
      dispatcher: dispatcher,
      child: AnimationScope(clock: clock, child: root),
    );
    owner.updateRoot(root);
    frame();
  }

  late final ManualDispatcher dispatcher;
  late final PipelineOwner pipeline;
  late final AnimationClock clock;
  late final BuildOwner owner;
  Duration _time = Duration.zero;

  /// Builds, lays out and paints until nothing is dirty.
  DisplayList frame() {
    DisplayList list = DisplayList();
    for (int pass = 0; pass < 8; pass++) {
      if (owner.hasScheduledBuilds) owner.buildScope();
      list = DisplayList();
      pipeline.drawFrame(list);
      if (!owner.hasScheduledBuilds) break;
    }
    return list;
  }

  /// Lets [time] pass on the virtual clock, frame by frame.
  void pump([Duration time = inputTestFrame]) {
    Duration left = time;
    while (left > Duration.zero) {
      final Duration step = left < inputTestFrame ? left : inputTestFrame;
      _time += step;
      dispatcher.advance(step);
      frame();
      left -= step;
    }
  }

  /// Advances the event clock by a frame without running a frame.
  Duration _tick() => _time += const Duration(milliseconds: 8);

  bool pointer(PointerEvent event) {
    final bool hit = owner.dispatchPointerEvent(event);
    frame();
    return hit;
  }

  bool down(
    Offset at, {
    int pointer = 0,
    PointerButton button = PointerButton.primary,
    PointerKind kind = PointerKind.mouse,
  }) =>
      this.pointer(PointerDownEvent(
        windowId: inputTestWindow,
        generation: 1,
        timestamp: _tick(),
        pointerId: pointer,
        kind: kind,
        logicalPosition: at,
        button: button,
      ));

  bool move(Offset at,
          {int pointer = 0, PointerKind kind = PointerKind.mouse}) =>
      this.pointer(PointerMoveEvent(
        windowId: inputTestWindow,
        generation: 1,
        timestamp: _tick(),
        pointerId: pointer,
        kind: kind,
        logicalPosition: at,
      ));

  bool up(
    Offset at, {
    int pointer = 0,
    PointerButton button = PointerButton.primary,
    PointerKind kind = PointerKind.mouse,
  }) =>
      this.pointer(PointerUpEvent(
        windowId: inputTestWindow,
        generation: 1,
        timestamp: _tick(),
        pointerId: pointer,
        kind: kind,
        logicalPosition: at,
        button: button,
      ));

  bool cancel(Offset at, {int pointer = 0}) => this.pointer(PointerCancelEvent(
        windowId: inputTestWindow,
        generation: 1,
        timestamp: _tick(),
        pointerId: pointer,
        kind: PointerKind.mouse,
        logicalPosition: at,
      ));

  bool wheel(
    Offset at,
    Offset delta, {
    PointerKind kind = PointerKind.mouse,
  }) =>
      pointer(PointerScrollEvent(
        windowId: inputTestWindow,
        generation: 1,
        timestamp: _tick(),
        pointerId: 0,
        kind: kind,
        logicalPosition: at,
        scrollDelta: delta,
        scrollDeltaUnit: ScrollDeltaUnit.pixels,
      ));

  bool panZoom(
    Offset at,
    PanZoomPhase phase, {
    double scale = 1,
    Offset pan = Offset.zero,
  }) =>
      pointer(PointerPanZoomEvent(
        windowId: inputTestWindow,
        generation: 1,
        timestamp: _tick(),
        pointerId: 0,
        kind: PointerKind.trackpad,
        logicalPosition: at,
        phase: phase,
        scale: scale,
        pan: pan,
      ));

  /// Drags from [from] to [to] in [steps] moves and releases.
  void drag(Offset from, Offset to, {int steps = 5, bool release = true}) {
    down(from);
    for (int i = 1; i <= steps; i++) {
      move(Offset.lerp(from, to, i / steps));
    }
    if (release) up(to);
  }

  bool key(
    int logicalKey, {
    Set<KeyModifier> modifiers = const <KeyModifier>{},
    bool up = false,
    bool repeat = false,
  }) {
    final KeyEvent event = up
        ? KeyUpEvent(
            windowId: inputTestWindow,
            generation: 1,
            timestamp: _tick(),
            physicalKey: logicalKey,
            logicalKey: logicalKey,
            modifiers: modifiers,
          )
        : KeyDownEvent(
            windowId: inputTestWindow,
            generation: 1,
            timestamp: _tick(),
            physicalKey: logicalKey,
            logicalKey: logicalKey,
            modifiers: modifiers,
            isRepeat: repeat,
          );
    final bool handled = owner.dispatchKeyEvent(event);
    frame();
    return handled;
  }

  /// Every render box of type [T], in paint order.
  List<T> find<T extends RenderBox>() {
    final List<T> found = <T>[];
    void walk(RenderBox node) {
      if (node is T) found.add(node);
      node.visitChildren(walk);
    }

    final RenderBox? root = owner.renderRoot;
    if (root != null) walk(root);
    return found;
  }

  /// Where [box] is on the window.
  Rect rectOf(RenderBox box) {
    final Offset at = box.localToGlobal(Offset.zero);
    return Rect.fromLTWH(at.dx, at.dy, box.size.width, box.size.height);
  }

  void dispose() => owner.dispose();
}
