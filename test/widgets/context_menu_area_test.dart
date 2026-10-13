import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(FrameworkFonts.install);
  tearDownAll(FontRegistry.instance.reset);

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
}
