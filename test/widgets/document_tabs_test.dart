import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

/// A strip of three tabs, 900 px wide, each at its 240 px maximum.
final class _Strip {
  _Strip({this.style = DocumentTabStyle.raised}) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(900, 40)),
      ),
    );
    frame();
  }

  final DocumentTabStyle style;
  late final BuildOwner owner;
  final List<String> tabs = <String>['Home', 'Documents', 'Downloads'];
  int selected = 0;
  int adds = 0;

  void frame() {
    for (var pass = 0; pass < 6; pass++) {
      owner.updateRoot(Directionality(
        textDirection: TextDirection.leftToRight,
        child: Align(
          alignment: Alignment.centerLeft,
          child: DocumentTabStrip(
            style: style,
            height: 40,
            tabs: <DocumentTab>[
              for (final String t in tabs)
                DocumentTab(label: t, icon: PhosphorIcons.folder),
            ],
            selectedIndex: selected,
            onSelected: (int i) => selected = i,
            onClosed: (int i) => tabs.removeAt(i),
            onAdd: () => adds++,
          ),
        ),
      ));
      owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
  }

  void _send(PointerEvent event) => owner.dispatchPointerEvent(event);

  void click(Offset at, {PointerButton button = PointerButton.primary}) {
    _send(PointerDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
      button: button,
    ));
    _send(PointerUpEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
      button: button,
    ));
    frame();
  }

  void dispose() => owner.dispose();
}

void main() {
  setUpAll(FrameworkFonts.install);
  tearDownAll(FontRegistry.instance.reset);

  for (final DocumentTabStyle style in DocumentTabStyle.values) {
    group(style.name, () {
      test('a click selects a tab', () {
        final _Strip strip = _Strip(style: style);
        strip.click(const Offset(240 + 60, 20));
        expect(strip.selected, 1);
        strip.dispose();
      });

      test('a middle click closes the tab under it', () {
        final _Strip strip = _Strip(style: style);
        strip.click(const Offset(480 + 60, 20), button: PointerButton.middle);
        expect(strip.tabs, <String>['Home', 'Documents']);
        strip.dispose();
      });

      test('the add button follows the last tab', () {
        final _Strip strip = _Strip(style: style);
        strip.click(const Offset(3 * 240 + 18, 20));
        expect(strip.adds, 1);
        strip.dispose();
      });

      test('the label and icon sit in the middle of the tab', () {
        final _Strip strip = _Strip(style: style);
        RenderBox? label;
        void walk(RenderBox node) {
          if (node is RenderText && node.text == 'Documents') label = node;
          node.visitChildren(walk);
        }

        walk(strip.owner.renderRoot!);
        final double middle =
            label!.localToGlobal(Offset.zero).dy + label!.size.height / 2;
        // The raised card starts 4 px down, leaving the strip's colour
        // above it; the label is centred in what is the card.
        expect(middle,
            closeTo(style == DocumentTabStyle.raised ? (4 + 40) / 2 : 20, .5));
        strip.dispose();
      });
    });
  }
}
