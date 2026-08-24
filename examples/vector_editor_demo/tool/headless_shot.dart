/// Renders the vector editor shell headless and writes a PNG.
///
/// This is the loop the editor was built in: mount the real widget tree with no
/// window, rasterize it with the CPU renderer, and look at the picture. A
/// layout or paint mistake that a `dart analyze` cannot see - a bar that is laid
/// out and then painted over, say - is obvious in the PNG in one look.
///
/// ```
/// dart run examples/vector_editor_demo/tool/headless_shot.dart out.png 1400 880
/// dart run examples/vector_editor_demo/tool/headless_shot.dart out.png 1400 880 menu:1
/// dart run examples/vector_editor_demo/tool/headless_shot.dart out.png 1400 880 select
/// ```
library;

import 'dart:io';

import 'package:dart_ui/dart_ui.dart';

import '../app.dart';
import '../editor_model.dart';
import '../main_window.dart';

Future<void> main(List<String> args) async {
  final path = args.isNotEmpty ? args[0] : 'shot.png';
  final width = args.length > 1 ? int.parse(args[1]) : 1400;
  final height = args.length > 2 ? int.parse(args[2]) : 880;
  final scenario = args.length > 3 ? args[3] : '';

  FrameworkFonts.install();
  FontRegistry.warmSystemFonts();

  final owner = BuildOwner(
    pipelineOwner: PipelineOwner(
      rootConstraints: BoxConstraints.tight(
        Size(width.toDouble(), height.toDouble()),
      ),
    ),
  );
  owner.updateRoot(const VectorEditorApp());

  DisplayList settle() {
    var list = DisplayList();
    for (var pass = 0; pass < 12; pass++) {
      list = DisplayList();
      owner.buildScope();
      owner.pipelineOwner.drawFrame(list);
      if (!owner.hasScheduledBuilds) break;
    }
    return list;
  }

  settle();

  final state = findState(owner);
  final driver = _Driver(owner, settle);
  final canvas = findCanvas(owner);

  SelectableObject objectOfType(bool Function(SelectableObject o) test) =>
      state.model.active.layer.children
          .whereType<SelectableObject>()
          .firstWhere(test);

  if (scenario.startsWith('menu:')) {
    state.model.openMenu = int.parse(scenario.substring(5));
    state.model.refresh();
  } else if (scenario == 'select') {
    state.model.selectAll();
  } else if (scenario == 'align') {
    state.model
      ..selectAll()
      ..activePanel = PanelIds.align
      ..refresh();
  } else if (scenario == 'collapsed') {
    state.model
      ..activePanel = null
      ..refresh();
  } else if (scenario == 'drag-star') {
    // Bug 1: the star used to leave the viewport on the first drag.
    final star = objectOfType((o) => o is VectorPolygon);
    final from = star.cacheBbox.center;
    driver.drag(canvas.toGlobal(from), canvas.toGlobal(from + const Offset(-140, 90)));
  } else if (scenario == 'handle') {
    // Bug 2: a handle held mid-resize, with the frame following the pointer.
    final rect = objectOfType((o) => o is VectorRectangle);
    state.model.selection.select(rect);
    settle();
    final box = rect.cacheBbox;
    driver
      ..press(canvas.toGlobal(Offset(box.right, box.bottom)))
      ..moveTo(canvas.toGlobal(Offset(box.right + 120, box.bottom + 70)));
  } else if (scenario == 'marquee') {
    // Bug 4: the rubber band, in progress.
    driver
      ..press(canvas.toGlobal(const Offset(40, 40)))
      ..moveTo(canvas.toGlobal(const Offset(360, 230)));
  } else if (scenario == 'text-edit') {
    // Bug 3: a text opened for editing, with a caret and a selected run.
    final text = objectOfType((o) => o is VectorText);
    final at = canvas.toGlobal(text.cacheBbox.center);
    driver
      ..click(at)
      ..click(at, clickCount: 2)
      ..key(logicalKeyHome)
      ..key(logicalKeyArrowRight, modifiers: const {KeyModifier.shift})
      ..key(logicalKeyArrowRight, modifiers: const {KeyModifier.shift})
      ..key(logicalKeyArrowRight, modifiers: const {KeyModifier.shift})
      ..key(logicalKeyArrowRight, modifiers: const {KeyModifier.shift})
      ..key(logicalKeyArrowRight, modifiers: const {KeyModifier.shift})
      ..key(logicalKeyArrowRight, modifiers: const {KeyModifier.shift});
  } else if (scenario == 'multi') {
    // Bug 5: three objects picked up with Shift.
    final rect = objectOfType((o) => o is VectorRectangle);
    final circle = objectOfType((o) => o is VectorCircle);
    final star = objectOfType((o) => o is VectorPolygon);
    driver.click(canvas.toGlobal(rect.cacheBbox.center));
    for (final object in <SelectableObject>[circle, star]) {
      driver
        ..keyDown(0x10, modifiers: const {KeyModifier.shift})
        ..click(canvas.toGlobal(object.cacheBbox.center))
        ..keyUp(0x10);
    }
  } else if (scenario == 'zoomed') {
    // Bug 7: two wheel notches at a point well off centre.
    final focus = canvas.viewportRect.center + const Offset(180, -90);
    driver
      ..wheel(focus, const Offset(0, -1))
      ..wheel(focus, const Offset(0, -1))
      ..wheel(focus, const Offset(0, -1));
  }

  final list = settle();

  final device = await const CpuRendererBackend().createDevice();
  final target = device.createTarget(
    MemorySurfaceDescriptor(pixelWidth: width, pixelHeight: height),
  ) as MemoryRenderTarget;
  final result = await target.renderDisplayList(list, clearColor: 0xFF202020);
  stdout.writeln('render success: ${result.isSuccess}');

  final shot = HeadlessScreenshot.fromFramebuffer(target.framebuffer);
  File(path).writeAsBytesSync(shot.toPng());
  stdout.writeln('wrote $path (${shot.width}x${shot.height})');

  final buffer = StringBuffer();
  void walk(RenderBox node, int depth) {
    buffer.writeln('${'  ' * depth}${node.runtimeType} ${node.size}');
    node.visitChildren((child) => walk(child, depth + 1));
  }

  final root = owner.renderRoot;
  if (root != null) walk(root, 0);
  File('$path.tree.txt').writeAsStringSync(buffer.toString());
  stdout.writeln('wrote $path.tree.txt');
  owner.dispose();
}

/// The mounted canvas, so a scenario can convert document points to the window.
VectorCanvasState findCanvas(BuildOwner owner) {
  VectorCanvasState? found;
  void walk(Element element) {
    if (found != null) return;
    if (element is StatefulElement && element.state is VectorCanvasState) {
      found = element.state as VectorCanvasState;
      return;
    }
    element.visitChildren(walk);
  }

  walk(owner.rootElement!);
  if (found == null) throw StateError('the canvas is not mounted');
  return found!;
}

/// Drives the window with the same events a display would send it.
///
/// A scenario that poked the model directly could not show an interaction: the
/// marquee, the grabbed handle and the caret only exist while a gesture is in
/// flight, and only the pointer path puts them there.
final class _Driver {
  _Driver(this.owner, this.settle);

  final BuildOwner owner;
  final DisplayList Function() settle;

  int _pointer = 0;
  int _millis = 0;

  Duration get _now => Duration(milliseconds: _millis += 10);

  void press(Offset global, {PointerButton button = PointerButton.primary, int clickCount = 1}) {
    owner.dispatchPointerEvent(PointerDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: _now,
      pointerId: _pointer,
      kind: PointerKind.mouse,
      logicalPosition: global,
      button: button,
      clickCount: clickCount,
    ));
    settle();
  }

  void moveTo(Offset global, {int steps = 6}) {
    for (var step = 1; step <= steps; step++) {
      owner.dispatchPointerEvent(PointerMoveEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: _now,
        pointerId: _pointer,
        kind: PointerKind.mouse,
        logicalPosition: global,
      ));
    }
    settle();
  }

  void release(Offset global, {PointerButton button = PointerButton.primary}) {
    owner.dispatchPointerEvent(PointerUpEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: _now,
      pointerId: _pointer,
      kind: PointerKind.mouse,
      logicalPosition: global,
      button: button,
    ));
    _pointer++;
    settle();
  }

  void click(Offset global, {int clickCount = 1}) {
    press(global, clickCount: clickCount);
    release(global);
  }

  void drag(Offset from, Offset to) {
    press(from);
    moveTo(to);
    release(to);
  }

  void wheel(Offset global, Offset delta) {
    owner.dispatchPointerEvent(PointerScrollEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: _now,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: global,
      scrollDelta: delta,
      scrollDeltaUnit: ScrollDeltaUnit.lines,
    ));
    settle();
  }

  void keyDown(int key, {Set<KeyModifier> modifiers = const {}}) {
    owner.dispatchKeyEvent(KeyDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: _now,
      physicalKey: key,
      logicalKey: key,
      modifiers: modifiers,
    ));
    settle();
  }

  void keyUp(int key, {Set<KeyModifier> modifiers = const {}}) {
    owner.dispatchKeyEvent(KeyUpEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: _now,
      physicalKey: key,
      logicalKey: key,
      modifiers: modifiers,
    ));
    settle();
  }

  void key(int value, {Set<KeyModifier> modifiers = const {}}) {
    keyDown(value, modifiers: modifiers);
    keyUp(value, modifiers: modifiers);
  }
}

/// The mounted window state, so a scenario can drive the real model.
MainWindowState findState(BuildOwner owner) {
  MainWindowState? found;
  void walk(Element element) {
    if (found != null) return;
    if (element is StatefulElement && element.state is MainWindowState) {
      found = element.state as MainWindowState;
      return;
    }
    element.visitChildren(walk);
  }

  walk(owner.rootElement!);
  if (found == null) throw StateError('the editor window is not mounted');
  return found!;
}
