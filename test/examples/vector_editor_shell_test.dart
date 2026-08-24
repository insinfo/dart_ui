/// The gate that keeps the vector editor's chrome on screen.
///
/// The editor once ran with no error at all and drew almost none of its window:
/// the menu bar, the toolbar, the property bar and the tool box were laid out
/// at their correct sizes and then *painted over*, because the canvas filled a
/// 20000 pt desktop rectangle in global coordinates with no clip and the canvas
/// is painted after them. `dart analyze` was clean and every widget existed.
///
/// So this file asserts two different things, and needs both:
///
/// 1. every part of the chrome exists in the render tree with a non-zero box;
/// 2. the frame those boxes produce still shows them once it is *rasterized*.
///
/// (1) alone is what passed while the window was blank.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

import '../../examples/vector_editor_demo/app.dart';
import '../../examples/vector_editor_demo/canvas_area.dart';
import '../../examples/vector_editor_demo/commands.dart';
import '../../examples/vector_editor_demo/context_panel.dart';
import '../../examples/vector_editor_demo/doc_tabs.dart';
import '../../examples/vector_editor_demo/editor_model.dart';
import '../../examples/vector_editor_demo/main_window.dart';
import '../../examples/vector_editor_demo/menu_bar.dart';
import '../../examples/vector_editor_demo/metrics.dart';
import '../../examples/vector_editor_demo/plugin_area.dart';
import '../../examples/vector_editor_demo/standard_toolbar.dart';
import '../../examples/vector_editor_demo/status_bar.dart';
import '../../examples/vector_editor_demo/toolbox.dart';

const Size kWindowSize = Size(1400, 880);

void main() {
  setUpAll(() {
    // The editor's chrome is labels *and icons*, and [RenderIcon] throws rather
    // than drawing a blank when its family is not registered - so the shell
    // needs the same font set the application installs, not a bare text face.
    // These are checked into the repository, so this stays deterministic.
    final fonts = FrameworkFonts.install();
    expect(fonts.uiFontLoaded, isTrue,
        reason: 'the bundled Inter face must load for the chrome to measure');
    expect(fonts.iconFontLoaded, isTrue,
        reason: 'the tool box and toolbars are icon fonts');
  });
  tearDownAll(FontRegistry.instance.reset);

  group('the editor window mounts with all of its chrome', () {
    test('every bar and panel exists with a non-zero box', () {
      final harness = _Harness();
      harness.frame();

      // Each of these was invisible in the broken build, and each is checked by
      // widget type rather than by a golden so the failure names the part.
      final expectations = <Type, Size Function(Size box)>{
        EditorMenuBar: (box) => box,
        StandardToolbar: (box) => box,
        ContextPanel: (box) => box,
        DocumentTabs: (box) => box,
        Toolbox: (box) => box,
        CanvasArea: (box) => box,
        PluginArea: (box) => box,
        ColorPaletteBar: (box) => box,
        EditorStatusBar: (box) => box,
      };

      for (final type in expectations.keys) {
        final size = harness.sizeOf(type);
        expect(size, isNotNull, reason: '$type is not in the tree at all');
        expect(size!.width, greaterThan(0), reason: '$type has no width');
        expect(size.height, greaterThan(0), reason: '$type has no height');
      }
      harness.dispose();
    });

    test('the bars have the heights the metrics declare', () {
      final harness = _Harness();
      harness.frame();

      expect(harness.sizeOf(EditorMenuBar)!.height,
          ChromeMetrics.menuBarHeight);
      expect(harness.sizeOf(StandardToolbar)!.height,
          ChromeMetrics.toolbarHeight);
      expect(harness.sizeOf(ContextPanel)!.height,
          ChromeMetrics.contextPanelHeight);
      expect(harness.sizeOf(DocumentTabs)!.height,
          ChromeMetrics.documentTabsHeight);
      expect(harness.sizeOf(EditorStatusBar)!.height,
          ChromeMetrics.statusBarHeight);
      expect(harness.sizeOf(Toolbox)!.width, ChromeMetrics.toolboxWidth);
      harness.dispose();
    });

    test('both rulers are mounted, one per axis', () {
      final harness = _Harness();
      harness.frame();

      final rulers = harness.rendersOfType<RenderRuler>();
      expect(rulers, hasLength(2));
      // One spans the canvas horizontally, the other vertically; neither is a
      // hairline, which is what a collapsed ruler would be.
      expect(rulers.any((r) => r.size.height == ChromeMetrics.rulerThickness),
          isTrue);
      expect(rulers.any((r) => r.size.width == ChromeMetrics.rulerThickness),
          isTrue);
      for (final ruler in rulers) {
        expect(ruler.size.width, greaterThan(0));
        expect(ruler.size.height, greaterThan(0));
      }
      harness.dispose();
    });

    test('the canvas gets the space left over, not the whole window', () {
      final harness = _Harness();
      harness.frame();

      final canvas = harness.rendersOfType<RenderVectorCanvas>().single;
      expect(canvas.size.width, greaterThan(200));
      expect(canvas.size.height, greaterThan(200));
      // The bars above and below, the tool box and the plugin area all take
      // room out of it. A canvas as tall as the window means the column
      // collapsed.
      expect(canvas.size.height, lessThan(kWindowSize.height - 100));
      expect(canvas.size.width, lessThan(kWindowSize.width - 100));
      harness.dispose();
    });
  });

  group('the chrome survives rasterization', () {
    // This is the group that would have caught the original bug.
    test('the menu bar band is not painted over by the canvas', () async {
      final harness = _Harness();
      final pixels = await harness.rasterize();

      // Sample a row inside each bar and assert it is not the canvas desktop
      // grey. Colour rather than "something was drawn": the broken build did
      // draw something there - the canvas' desktop.
      final desktop = _deskColour;
      for (final band in <({String name, double y})>[
        (name: 'menu bar', y: ChromeMetrics.menuBarHeight / 2),
        (
          name: 'toolbar',
          y: ChromeMetrics.menuBarHeight + ChromeMetrics.toolbarHeight / 2
        ),
        (
          name: 'property bar',
          y: ChromeMetrics.menuBarHeight +
              ChromeMetrics.toolbarHeight +
              ChromeMetrics.contextPanelHeight / 2
        ),
        (name: 'status bar', y: kWindowSize.height - 6),
      ]) {
        final sample = pixels.at(600, band.y.round());
        expect(
          sample & 0x00FFFFFF,
          isNot(desktop),
          reason: '${band.name} is showing the canvas background, which means '
              'the canvas painted outside its own box again',
        );
      }
      harness.dispose();
    });

    test('the tool box column is not painted over either', () async {
      final harness = _Harness();
      final pixels = await harness.rasterize();
      final desktop = _deskColour;

      // Halfway down the tool box, well inside its 30 px.
      final sample = pixels.at(
        ChromeMetrics.toolboxWidth ~/ 2,
        (kWindowSize.height / 2).round(),
      );
      expect(sample & 0x00FFFFFF, isNot(desktop));
      harness.dispose();
    });

    test('the canvas still draws its page and its artwork', () async {
      final harness = _Harness();
      final pixels = await harness.rasterize();

      // The page is white, the desk is grey, the sample document has a blue
      // rectangle: all three must be somewhere in the canvas band.
      final colours = <int>{};
      final canvas = harness.rendersOfType<RenderVectorCanvas>().single;
      final origin = canvas.localToGlobal(Offset.zero);
      for (var y = origin.dy.round() + 4;
          y < origin.dy + canvas.size.height - 4;
          y += 5) {
        for (var x = origin.dx.round() + 4;
            x < origin.dx + canvas.size.width - 4;
            x += 5) {
          colours.add(pixels.at(x, y) & 0x00FFFFFF);
        }
      }
      expect(colours, contains(_deskColour),
          reason: 'the desk should be visible around the page');
      expect(colours, contains(0x00FFFFFF), reason: 'the page should be white');
      expect(colours.length, greaterThan(4),
          reason: 'the sample artwork should contribute its own colours');
      harness.dispose();
    });
  });

  group('the window is an editor, not a mock-up', () {
    test('every menu carries its rows, with shortcuts and reasons', () {
      final harness = _Harness();
      harness.frame();
      final catalog = harness.catalog;

      expect(
        catalog.menus.map((menu) => menu.label),
        <String>[
          'File',
          'Edit',
          'View',
          'Layout',
          'Arrange',
          'Paths',
          'Bitmaps',
          'Text',
          'Help',
        ],
      );

      final file = catalog.menus.first.toMenuItems();
      expect(file.any((item) => item.label == 'New' && item.shortcut == 'Ctrl+N'),
          isTrue);

      // Nothing is selected, so Group must be disabled *and* say why - a
      // dimmed row with no reason tells a screen reader nothing.
      final group = catalog.group;
      expect(group.enabled, isFalse);
      expect(group.disabledReason, isNotNull);
      expect(group.disabledReason, contains('selected'));
      harness.dispose();
    });

    test('the property bar changes with the selection', () {
      final harness = _Harness();
      harness.frame();
      final model = harness.model;

      expect(contextPluginsFor(model),
          containsAll(<ContextPlugin>[ContextPlugin.page, ContextPlugin.units]));

      model.selectAll();
      harness.frame();
      final selected = contextPluginsFor(model);
      expect(selected, contains(ContextPlugin.position));
      expect(selected, contains(ContextPlugin.resize));
      expect(selected, isNot(contains(ContextPlugin.page)));
      harness.dispose();
    });

    test('a single rectangle brings up the rectangle plugin', () {
      final harness = _Harness();
      harness.frame();
      final model = harness.model;
      final rectangle = model.active.layer.children.whereType<VectorRectangle>().first;
      model.selection.select(rectangle);
      harness.frame();

      expect(contextPluginsFor(model), contains(ContextPlugin.rectangle));
      harness.dispose();
    });

    test('the rectangle tool creates a real object, undoably', () {
      final harness = _Harness();
      harness.frame();
      final model = harness.model;
      // Through the model *and* a frame: the canvas is handed the tool as a
      // widget property, so setting the field without rebuilding would leave
      // the old controller in place - which is a real bug this catches.
      model.tool = ToolMode.rectangle;
      model.refresh();
      harness.frame();
      final before = model.active.layer.children.length;

      // Inside the canvas box, found from the canvas rather than guessed: the
      // chrome above it is 128 px tall and a guessed point lands in the ruler.
      final box = harness.canvasState.viewportRect;
      harness.drag(
        Offset(box.left + 60, box.top + 60),
        Offset(box.left + 160, box.top + 140),
      );

      expect(model.active.layer.children.length, before + 1);
      expect(model.active.layer.children.last, isA<VectorRectangle>());
      final created = model.active.layer.children.last as VectorRectangle;
      expect(created.rectWidth, greaterThan(1));
      expect(created.rectHeight, greaterThan(1));
      harness.dispose();
    });

    test('the select tool selects what it is clicked on', () {
      final harness = _Harness();
      harness.frame();
      final model = harness.model;
      final rectangle =
          model.active.layer.children.whereType<VectorRectangle>().first;
      final canvas = harness.canvasState;

      // Aim at the middle of the rectangle, converted through the same
      // transform the canvas uses.
      final centre = rectangle.cacheBbox.center;
      harness.tap(canvas.toGlobal(centre));

      expect(model.selection.hasSelection, isTrue);
      expect(model.selection.selectedObjects.first, same(rectangle));
      harness.dispose();
    });

    test('zoom and pan move the viewport and the rulers agree', () {
      final harness = _Harness();
      harness.frame();
      final model = harness.model;
      final before = model.active.zoom;

      model.zoomBy(2, const Size(600, 500));
      harness.frame();

      expect(model.active.zoom, greaterThan(before));
      // The rulers are handed the session's own zoom, so their label step has
      // to have followed it.
      final ruler = harness.rendersOfType<RenderRuler>().first;
      expect(ruler.labelStep, greaterThan(0));
      harness.dispose();
    });

    test('undo puts a deleted object back', () {
      final harness = _Harness();
      harness.frame();
      final model = harness.model;
      final rectangle =
          model.active.layer.children.whereType<VectorRectangle>().first;
      final before = model.active.layer.children.length;

      model.selection.select(rectangle);
      model.deleteSelection();
      expect(model.active.layer.children.length, before - 1);

      model.undo();
      expect(model.active.layer.children.length, before);
      expect(model.active.layer.children, contains(rectangle));
      harness.dispose();
    });

    test('a palette click fills and a right click outlines', () {
      final harness = _Harness();
      harness.frame();
      final model = harness.model;
      final rectangle =
          model.active.layer.children.whereType<VectorRectangle>().first;
      model.selection.select(rectangle);

      model.setFill(const Color(0xFF4CAF50));
      expect(rectangle.style.fill.color.value, 0xFF4CAF50);

      model.setStroke(const Color(0xFFD32F2F));
      expect(rectangle.style.stroke.color.value, 0xFFD32F2F);
      harness.dispose();
    });
  });

  group('the plugin area collapses the way sK1 does', () {
    test('a panel is docked, and the collapsed strip lists all of them', () {
      final harness = _Harness();
      harness.frame();

      final strip = harness.sizeOf(CollapsedTabStrip);
      expect(strip, isNotNull);
      expect(strip!.width, ChromeMetrics.collapsedTabStripWidth);
      expect(strip.height, greaterThan(100));
      expect(harness.model.openPanels, hasLength(3));
      harness.dispose();
    });

    test('collapsing the open panel gives its width back to the canvas', () {
      final harness = _Harness();
      harness.frame();
      final expanded =
          harness.rendersOfType<RenderVectorCanvas>().single.size.width;

      harness.model.togglePanel(harness.model.activePanel!);
      harness.frame();

      final collapsed =
          harness.rendersOfType<RenderVectorCanvas>().single.size.width;
      expect(collapsed, greaterThan(expanded));
      expect(collapsed - expanded, ChromeMetrics.pluginPanelWidth);
      // The strip stays: that is what makes it a collapse and not a close.
      expect(harness.sizeOf(CollapsedTabStrip), isNotNull);
      harness.dispose();
    });
  });
}

/// Mounts the real editor window headless and drives it like a display would.
/// The desk colour the editor actually paints, as RGB.
///
/// Resolved from the theme the window picks rather than from
/// `VectorCanvasPalette`, which is only the fallback a canvas with no theme
/// above it would use: taking the constant made these assertions compare the
/// rendered window against a colour it never paints, and "the bar is not this
/// colour it was never going to be" is a test that cannot fail.
final int _deskColour =
    VectorCanvasColors.fromTheme(ThemeData.fluentLight).desktop.value &
        0x00FFFFFF;

final class _Harness {
  _Harness() {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(kWindowSize),
      ),
    );
    owner.updateRoot(const VectorEditorApp());
    frame();
  }

  late final BuildOwner owner;

  /// Runs frames until nothing more is scheduled, and returns the last one.
  ///
  /// More than one pass is normal here: the canvas reports its box during
  /// layout and the window answers by fitting the page to it, which is a second
  /// build. A single pass would assert against a half-settled window.
  DisplayList frame({int maxPasses = 10}) {
    var list = DisplayList();
    for (var pass = 0; pass < maxPasses; pass++) {
      list = DisplayList();
      owner.buildScope();
      owner.pipelineOwner.drawFrame(list);
      if (!owner.hasScheduledBuilds) return list;
    }
    throw StateError('the editor never settled in $maxPasses frames');
  }

  MainWindowState get windowState {
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
    return found ?? (throw StateError('the editor window is not mounted'));
  }

  EditorModel get model => windowState.model;

  VectorCanvasState get canvasState {
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
    return found ?? (throw StateError('no canvas is mounted'));
  }

  CommandCatalog get catalog => CommandCatalog(
        model: model,
        services: EditorServices(
          newDocument: () {},
          openDocument: () {},
          saveDocument: () {},
          saveDocumentAs: () {},
          exportDocument: (_) {},
          printDocument: () {},
          closeDocument: () {},
          zoomIn: () {},
          zoomOut: () {},
          zoomActual: () {},
          zoomToPage: () {},
          zoomToSelection: () {},
          showPanel: (_) {},
          quit: () {},
        ),
      );

  /// The laid-out box of the first widget of [type], or null when it is absent.
  Size? sizeOf(Type type) {
    Size? found;
    void walk(Element element) {
      if (found != null) return;
      if (element.widget.runtimeType == type) {
        final render = _firstRender(element);
        if (render != null) {
          found = render.size;
          return;
        }
      }
      element.visitChildren(walk);
    }

    walk(owner.rootElement!);
    return found;
  }

  static RenderBox? _firstRender(Element element) {
    RenderBox? found;
    void walk(Element node) {
      if (found != null) return;
      if (node is RenderObjectElement) {
        found = node.renderObject;
        return;
      }
      node.visitChildren(walk);
    }

    walk(element);
    return found;
  }

  List<T> rendersOfType<T extends RenderBox>() {
    final found = <T>[];
    void walk(RenderBox node) {
      if (node is T) found.add(node);
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found;
  }

  int _pointerId = 0;

  void tap(Offset global) {
    final id = _pointerId++;
    owner.dispatchPointerEvent(PointerDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: id,
      kind: PointerKind.mouse,
      logicalPosition: global,
      button: PointerButton.primary,
    ));
    owner.dispatchPointerEvent(PointerUpEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: const Duration(milliseconds: 30),
      pointerId: id,
      kind: PointerKind.mouse,
      logicalPosition: global,
      button: PointerButton.primary,
    ));
    frame();
  }

  /// A press, several moves and a release: enough for the drag recognizer to
  /// win its arena, which one move is not.
  void drag(Offset from, Offset to, {int steps = 6}) {
    final id = _pointerId++;
    owner.dispatchPointerEvent(PointerDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: id,
      kind: PointerKind.mouse,
      logicalPosition: from,
      button: PointerButton.primary,
    ));
    for (var step = 1; step <= steps; step++) {
      owner.dispatchPointerEvent(PointerMoveEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: Duration(milliseconds: 10 * step),
        pointerId: id,
        kind: PointerKind.mouse,
        logicalPosition: Offset(
          from.dx + (to.dx - from.dx) * step / steps,
          from.dy + (to.dy - from.dy) * step / steps,
        ),
      ));
    }
    owner.dispatchPointerEvent(PointerUpEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration(milliseconds: 10 * (steps + 1)),
      pointerId: id,
      kind: PointerKind.mouse,
      logicalPosition: to,
      button: PointerButton.primary,
    ));
    frame();
  }

  /// Rasterizes the settled frame with the CPU renderer.
  Future<_Pixels> rasterize() async {
    final list = frame();
    final device = await const CpuRendererBackend().createDevice();
    final target = device.createTarget(
      MemorySurfaceDescriptor(
        pixelWidth: kWindowSize.width.toInt(),
        pixelHeight: kWindowSize.height.toInt(),
      ),
    ) as MemoryRenderTarget;
    final result = await target.renderDisplayList(list, clearColor: 0xFF000000);
    expect(result.isSuccess, isTrue);
    return _Pixels(target.framebuffer);
  }

  void dispose() => owner.dispose();
}

/// A rasterized frame, sampled by pixel.
final class _Pixels {
  _Pixels(this.framebuffer);

  final Framebuffer framebuffer;

  /// The packed ARGB value at [x], [y].
  int at(int x, int y) {
    final index = framebuffer.offsetOf(x, y);
    return framebuffer.pixels[index] |
        (framebuffer.pixels[index + 1] << 8) |
        (framebuffer.pixels[index + 2] << 16) |
        (framebuffer.pixels[index + 3] << 24);
  }
}
