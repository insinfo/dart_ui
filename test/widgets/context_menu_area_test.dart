import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(FrameworkFonts.install);
  tearDownAll(FontRegistry.instance.reset);

  test(
      'opening builds items after the hit selection changes without an owner rebuild',
      () {
    var selected = true;
    final host = InTreePopupHost();
    final owner = BuildOwner(
        pipelineOwner: PipelineOwner(
            rootConstraints: BoxConstraints.tight(const Size(400, 300))));
    addTearDown(owner.dispose);
    owner.updateRoot(PopupScope(
        host: host,
        child: ContextMenuArea(
            onOpen: (_) => selected = false,
            menuChildren: () => [
                  MenuItemButton(
                      onPressed: () {},
                      child: Text(selected ? 'File action' : 'Folder action'))
                ],
            child: const SizedBox(width: 400, height: 300))));
    void frame() {
      for (var i = 0; i < 8; i++) {
        owner.buildScope();
        owner.pipelineOwner.drawFrame(DisplayList());
        if (!owner.hasScheduledBuilds) return;
      }
    }

    frame();
    owner.dispatchPointerEvent(const PointerDownEvent(
        windowId: NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: Offset(100, 100),
        button: PointerButton.secondary));
    frame();
    final texts = <String>[];
    void walk(RenderBox box) {
      if (box is RenderText) texts.add(box.text);
      box.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    expect(texts, contains('Folder action'));
    expect(texts, isNot(contains('File action')));
  });

  test('opaque native menu corners contain the panel colour', () async {
    final device = await const CpuRendererBackend().createDevice();
    addTearDown(device.dispose);
    for (final bool opaque in <bool>[false, true]) {
      final panel = RenderMenuPanel(horizontal: false, decorated: true)
        ..theme = ThemeData.studioDark
        ..opaqueWindow = opaque;
      panel.layout(BoxConstraints.tight(const Size(80, 40)));
      final list = DisplayList();
      panel.paint(list, Offset.zero);
      final target = device.createTarget(const MemorySurfaceDescriptor(
        pixelWidth: 80,
        pixelHeight: 40,
        format: PixelFormat.rgba8888Premultiplied,
      )) as MemoryRenderTarget;
      addTearDown(target.dispose);
      await target.renderDisplayList(list, clearColor: 0);
      final pixels = target.framebuffer.pixels;
      final colour = ThemeData.studioDark.surfaceRaised;
      expect(
          pixels.sublist(0, 4),
          opaque
              ? <int>[colour.red, colour.green, colour.blue, 255]
              : <int>[0, 0, 0, 0]);
    }
  });

  test('a right click opens the menu where it happened, submenus and all', () {
    final InTreePopupHost host = InTreePopupHost();
    final BuildOwner owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(400, 300)),
      ),
    );
    Offset? openedAt;
    var builds = 0;
    owner.updateRoot(PopupScope(
      host: host,
      child: Theme(
        data: ThemeData.studioDark,
        child: Directionality(
          textDirection: TextDirection.leftToRight,
          child: ContextMenuArea(
            onOpen: (Offset at) => openedAt = at,
            menuChildren: () {
              builds++;
              return <Widget>[
                MenuItemButton(onPressed: () {}, child: const Text('Copy')),
                SubmenuButton(
                  menuChildren: <Widget>[
                    MenuItemButton(
                        onPressed: () {}, child: const Text('To front')),
                  ],
                  child: const Text('Order'),
                ),
              ];
            },
            child: const SizedBox(width: 400, height: 300),
          ),
        ),
      ),
    ));
    void frame() {
      for (var i = 0; i < 8; i++) {
        owner.buildScope();
        owner.pipelineOwner.drawFrame(DisplayList());
        if (!owner.hasScheduledBuilds) return;
      }
    }

    frame();
    owner.dispatchPointerEvent(const PointerDownEvent(
      windowId: NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: Offset(120, 80),
      button: PointerButton.secondary,
    ));
    frame();
    expect(openedAt, const Offset(120, 80));
    expect(builds, greaterThan(0));

    final List<RenderMenuPanel> panels = <RenderMenuPanel>[];
    void walk(RenderBox node) {
      if (node is RenderMenuPanel && node.decorated) panels.add(node);
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    expect(panels, hasLength(1));
    final List<String> labels = <String>[
      for (final RenderBox child in panels.single.children)
        if (child is MenuRowBehavior) child.rowLabel ?? '',
    ];
    expect(labels, <String>['Copy', 'Order']);
    owner.dispose();
  });
  for (final bool enabled in <bool>[true, false]) {
    test('nested menu claims secondary presses only when enabled=$enabled', () {
      final host = InTreePopupHost();
      final owner = BuildOwner(
          pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(600, 400)),
      ));
      addTearDown(owner.dispose);
      var outerOpens = 0;
      Offset? innerAt;
      owner.updateRoot(PopupScope(
          host: host,
          child: Theme(
            data: ThemeData.studioDark,
            child: Directionality(
              textDirection: TextDirection.leftToRight,
              child: ContextMenuArea(
                onOpen: (_) => outerOpens++,
                menuChildren: () => <Widget>[
                  MenuItemButton(onPressed: () {}, child: const Text('Files')),
                ],
                child: Padding(
                  padding: const EdgeInsets.only(left: 100, top: 50),
                  child: ContextMenuArea(
                    enabled: enabled,
                    onOpen: (at) => innerAt = at,
                    menuChildren: () => <Widget>[
                      MenuItemButton(
                          onPressed: () {}, child: const Text('Columns')),
                    ],
                    child: const SizedBox(width: 400, height: 300),
                  ),
                ),
              ),
            ),
          )));
      void frame() {
        for (var i = 0; i < 8; i++) {
          owner.buildScope();
          owner.pipelineOwner.drawFrame(DisplayList());
          if (!owner.hasScheduledBuilds) break;
        }
      }

      frame();
      owner.dispatchPointerEvent(const PointerDownEvent(
        windowId: NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: Offset(140, 90),
        button: PointerButton.secondary,
      ));
      frame();
      expect(outerOpens, enabled ? 0 : 1);
      expect(innerAt, enabled ? const Offset(40, 40) : isNull);
      final panels = <RenderMenuPanel>[];
      void walk(RenderBox box) {
        if (box is RenderMenuPanel && box.decorated) panels.add(box);
        box.visitChildren(walk);
      }

      walk(owner.renderRoot!);
      expect(panels, hasLength(1));
      final panel = panels.single;
      expect(panel.localToGlobal(Offset.zero), const Offset(140, 90));
      expect(panel.children.whereType<MenuRowBehavior>().single.rowLabel,
          enabled ? 'Columns' : 'Files');
    });
  }
}
