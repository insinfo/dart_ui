/// Renders the vector editor shell headless and writes a PNG.
///
/// This is the loop the editor was built in: mount the real widget tree with no
/// window, rasterize it with the CPU renderer, and look at the picture. A
/// layout or paint mistake that a `dart analyze` cannot see - a bar that is laid
/// out and then painted over, say - is obvious in the PNG in one look.
///
/// ```
/// dart run tool/headless_shot.dart out.png 1400 880
/// dart run tool/headless_shot.dart out.png 1400 880 menu:1
/// dart run tool/headless_shot.dart out.png 1400 880 select
/// dart run tool/headless_shot.dart out.png 1400 880 nodes
/// ```
library;

import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:vector_editor_demo/src/ui/app.dart';
import 'package:vector_editor_demo/src/ui/main_window.dart';
import 'package:vector_editor_demo/src/ui/workspace.dart';

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
  owner.updateRoot(
      PopupScope(host: InTreePopupHost(), child: const VectorEditorApp()));

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
    state.ui.menuControllers[int.parse(scenario.substring(5))].open();
    state.model.refresh();
  } else if (scenario == 'select') {
    state.registry.execute('edit.selectAll');
  } else if (scenario == 'align') {
    state.registry
      ..execute('edit.selectAll')
      ..execute('panel.align');
  } else if (scenario == 'fill') {
    state.registry
      ..execute('edit.selectAll')
      ..execute('panel.fillStroke');
  } else if (scenario == 'collapsed') {
    state.ui.workspace.layout.removeItem(
        item: state.ui.workspace.layout
            .findDockingItem(WorkspacePanels.objects)!);
    state.model.refresh();
  } else if (scenario == 'drag-star') {
    // Bug 1: the star used to leave the viewport on the first drag.
    final star = objectOfType((o) => o is VectorPolygon);
    final from = star.cacheBbox.center;
    driver.drag(
        canvas.toGlobal(from), canvas.toGlobal(from + const Offset(-140, 90)));
  } else if (scenario == 'handle') {
    // Bug 2: a handle held mid-resize, with the frame following the pointer.
    final rect = objectOfType((o) => o is VectorRectangle);
    state.model.selection.select(rect);
    settle();
    final box = rect.cacheBbox;
    driver
      ..press(canvas.toGlobal(Offset(box.right, box.bottom)))
      ..moveTo(canvas.toGlobal(Offset(box.right + 120, box.bottom + 70)));
  } else if (scenario == 'rotate') {
    // The rotate frame: a second click on an already-selected object swaps the
    // eight scale squares for four corner diamonds, four edge bars and the
    // pivot ring.
    final rect = objectOfType((o) => o is VectorRectangle);
    final at = canvas.toGlobal(rect.cacheBbox.center);
    driver
      ..click(at)
      ..click(at, clickCount: 2);
  } else if (scenario == 'rotating') {
    // The same frame with a corner held mid-turn.
    final rect = objectOfType((o) => o is VectorRectangle);
    final at = canvas.toGlobal(rect.cacheBbox.center);
    driver
      ..click(at)
      ..click(at, clickCount: 2);
    settle();
    final box = rect.cacheBbox;
    driver
      ..press(canvas.toGlobal(Offset(box.right, box.top)))
      ..moveTo(canvas.toGlobal(Offset(box.right + 40, box.top + 70)));
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
  } else if (scenario == 'nodes') {
    // The Shape tool on a converted rectangle, every node picked.
    state.model.selection.select(objectOfType((o) => o is VectorRectangle));
    state.registry
      ..execute('object.toCurves')
      ..execute('tool.shape')
      ..execute('path.selectAllNodes');
  } else if (scenario == 'arrows') {
    // Curves with every arrowhead, and the line bar for the last one.
    var y = 420.0;
    for (final ArrowHead head in ArrowHead.values.skip(1)) {
      state.registry
        ..execute('shape.curve', <String, Object?>{
          'points': <double>[60, y, 260, y - 30],
        })
        ..execute('object.outlineWidth', <String, Object?>{'width': 2})
        ..execute('object.arrows',
            <String, Object?>{'start': head.name, 'end': head.name});
      y += 50;
    }
  } else if (scenario == 'text-style') {
    // Three texts on one anchor line: left, centred and right aligned, in a
    // serif face, bold and italic; the last one selected for the text bar.
    for (final (String align, double y) in <(String, double)>[
      ('left', 430),
      ('center', 480),
      ('right', 530),
    ]) {
      state.registry
        ..execute('shape.text', <String, Object?>{
          'x': 300,
          'y': y,
          'text': 'Aligned $align',
        })
        ..execute('text.size', <String, Object?>{'size': 24})
        ..execute('text.font', <String, Object?>{'family': 'Georgia'})
        ..execute('text.italic', <String, Object?>{'on': true})
        ..execute('text.align', <String, Object?>{'align': align});
    }
    state.registry.execute('text.bold', <String, Object?>{'on': true});
  } else if (scenario == 'paragraph' || scenario == 'paragraph-edit') {
    // Paragraph text: a justified frame, a centred one with a hard break,
    // and artistic text broken in two lines; with -edit, the first frame
    // open for editing with a selection across a line break.
    state.registry
      ..execute('shape.text', <String, Object?>{
        'x': 300,
        'y': 400,
        'width': 260,
        'size': 14,
        'text': 'Paragraph text wraps inside its frame, as wide as the drag '
            'that made it; a long sentence becomes several lines, and the '
            'frame grows downward as it fills.',
      })
      ..execute('text.align', <String, Object?>{'align': 'justify'})
      ..execute('shape.text', <String, Object?>{
        'x': 300,
        'y': 500,
        'width': 200,
        'size': 14,
        'text': 'A centred frame\nwith a line break,\nthen more words that '
            'wrap to fit.',
      })
      ..execute('text.align', <String, Object?>{'align': 'center'})
      ..execute('shape.text', <String, Object?>{
        'x': 300,
        'y': 640,
        'size': 20,
        'text': 'Artistic text\non two lines',
      });
    if (scenario == 'paragraph-edit') {
      final text = objectOfType(
          (o) => o is VectorText && o.textContent.startsWith('Paragraph'));
      final at = canvas.toGlobal(text.cacheBbox.topLeft + const Offset(20, 8));
      driver
        ..click(at)
        ..click(at, clickCount: 2)
        ..key(logicalKeyArrowDown, modifiers: const {KeyModifier.shift})
        ..key(logicalKeyArrowRight, modifiers: const {KeyModifier.shift})
        ..key(logicalKeyArrowRight, modifiers: const {KeyModifier.shift});
    }
  } else if (scenario == 'calligraphy') {
    // A wave and an ellipse drawn with a flat chisel at 45 degrees: thick
    // where the line runs across the nib, thin along it.
    state.registry
      ..execute('shape.curve', <String, Object?>{
        'points': <double>[300, 440, 380, 380, 460, 500, 540, 400, 620, 460],
      })
      ..execute('object.outlineWidth', <String, Object?>{'width': 12})
      ..execute(
          'object.calligraphy', <String, Object?>{'stretch': 15, 'angle': 45})
      ..execute('shape.ellipse', <String, Object?>{
        'x': 320,
        'y': 540,
        'width': 160,
        'height': 100,
      })
      ..execute('object.fill', <String, Object?>{'color': null})
      ..execute('object.outlineWidth', <String, Object?>{'width': 14})
      ..execute(
          'object.calligraphy', <String, Object?>{'stretch': 10, 'angle': -30});
  } else if (scenario == 'fountain') {
    // A linear fountain on the rectangle, a radial one on the ellipse; the
    // Properties panel on the ellipse shows both colours.
    state.model.selection.select(objectOfType((o) => o is VectorRectangle));
    state.registry.execute('object.fountainFill', <String, Object?>{
      'type': 'linear',
      'from': '#1E88E5',
      'to': '#FFEB3B',
      'angle': 30,
    });
    state.model.selection.select(objectOfType((o) => o is VectorCircle));
    state.registry
      ..execute('object.fountainFill', <String, Object?>{
        'type': 'radial',
        'from': '#FFFFFF',
        'to': '#E53935',
      })
      ..execute('panel.properties');
  } else if (scenario == 'find') {
    // Edit > Find and Replace, the editor's first dialog.
    state.registry.execute('edit.findReplace');
  } else if (scenario == 'outline') {
    // Every object with a thick dashed outline, round caps and joins.
    state.model.selectAll();
    state.model.applyToSelection((VectorStyle s) => s.copyWith(
        stroke: s.stroke.copyWith(
            width: 3,
            color: const Color(0xFF202020),
            cap: LineCap.round,
            join: LineJoin.round,
            dashPattern: const <double>[8, 6])));
    state.model.selection.deselectAll();
  } else if (scenario == 'corners') {
    // The Shape tool on a rectangle, its corners half rounded, and on the
    // ellipse opened into a pie.
    final VectorRectangle rect =
        objectOfType((o) => o is VectorRectangle) as VectorRectangle;
    rect
      ..corners = <double>[.5, .5, .5, .5]
      ..update();
    final VectorCircle circle =
        objectOfType((o) => o is VectorCircle) as VectorCircle;
    circle
      ..angle1 = 1.2
      ..angle2 = 0
      ..arcType = ArcType.pieslice
      ..update();
    state.model.selection.select(rect);
    state.registry.execute('tool.shape');
  } else if (scenario == 'shaping') {
    // Weld, Trim and Intersect on the bar with two objects selected.
    state.model.selection.select(objectOfType((o) => o is VectorRectangle));
    state.model
        .pickObject(objectOfType((o) => o is VectorCircle), toggle: true);
  } else if (scenario == 'properties') {
    // The Properties panel (Alt+Enter) on the rectangle.
    state.model.selection.select(objectOfType((o) => o is VectorRectangle));
    state.registry.execute('panel.properties');
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

  void press(Offset global,
      {PointerButton button = PointerButton.primary, int clickCount = 1}) {
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
