import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

final class _Bar {
  _Bar(this.items, {this.width = 600}) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(Size(width, 32)),
      ),
    );
    frame();
  }

  List<String> items;
  final double width;
  late final BuildOwner owner;
  final List<int> selected = <int>[];
  final List<String> submitted = <String>[];

  void frame() {
    for (var pass = 0; pass < 6; pass++) {
      owner.updateRoot(Directionality(
        textDirection: TextDirection.leftToRight,
        child: PopupScope(
          host: InTreePopupHost(),
          child: BreadcrumbBar(
            items: <BreadcrumbItem>[
              for (final String item in items) BreadcrumbItem(label: item),
            ],
            onSelected: selected.add,
            editText: '/${items.join('/')}',
            onSubmitted: submitted.add,
            childrenMenu: (int index) => const <Widget>[],
          ),
        ),
      ));
      owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
  }

  List<T> renders<T extends RenderBox>() {
    final List<T> found = <T>[];
    void walk(RenderBox node) {
      if (node is T) found.add(node);
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found;
  }

  List<String> get shownLabels => <String>[
        for (final RenderText text in renders<RenderText>()) text.text,
      ];

  void click(Offset at) {
    for (final bool down in <bool>[true, false]) {
      owner.dispatchPointerEvent(down
          ? PointerDownEvent(
              windowId: const NativeWindowId(1),
              generation: 1,
              timestamp: Duration.zero,
              pointerId: 0,
              kind: PointerKind.mouse,
              logicalPosition: at,
              button: PointerButton.primary,
            )
          : PointerUpEvent(
              windowId: const NativeWindowId(1),
              generation: 1,
              timestamp: Duration.zero,
              pointerId: 0,
              kind: PointerKind.mouse,
              logicalPosition: at,
              button: PointerButton.primary,
            ));
    }
    frame();
  }

  void dispose() => owner.dispose();
}

void main() {
  setUpAll(FrameworkFonts.install);
  tearDownAll(FontRegistry.instance.reset);

  test('every step shows when there is room', () {
    final _Bar bar = _Bar(<String>['Users', 'ana', 'Documents']);
    expect(bar.shownLabels, <String>['Users', 'ana', 'Documents']);
    bar.dispose();
  });

  test('a narrow bar keeps the last steps and collapses the first', () {
    final _Bar bar = _Bar(<String>[
      'Volumes',
      'ssd_dock',
      'MyProjectsDart',
      'dart_ui',
      'examples',
      'file_explorer',
    ], width: 260);
    expect(bar.shownLabels.last, 'file_explorer');
    expect(bar.shownLabels, isNot(contains('Volumes')));
    expect(bar.renders<RenderIcon>().map((RenderIcon i) => i.icon),
        contains(PhosphorIcons.caretDoubleLeft));
    bar.dispose();
  });

  test('a step goes there; the empty end types an address', () {
    final _Bar bar = _Bar(<String>['Users', 'ana']);
    final RenderText users = bar
        .renders<RenderText>()
        .firstWhere((RenderText t) => t.text == 'Users');
    bar.click(users.localToGlobal(Offset.zero) + const Offset(4, 4));
    expect(bar.selected, <int>[0]);

    bar.click(const Offset(590, 16));
    final RenderTextField field = bar.renders<RenderTextField>().single;
    expect(field.controller.value, '/Users/ana');
    field.onSubmitted!(field.controller.value);
    bar.frame();
    expect(bar.submitted, <String>['/Users/ana']);
    expect(bar.renders<RenderTextField>(), isEmpty,
        reason: 'back to the steps after Enter');
    bar.dispose();
  });

  test('going somewhere else leaves the address being typed', () {
    final _Bar bar = _Bar(<String>['Users', 'ana']);
    bar.click(const Offset(590, 16));
    expect(bar.renders<RenderTextField>(), hasLength(1));
    bar.items = <String>['Users', 'ana', 'Music'];
    bar.frame();
    expect(bar.renders<RenderTextField>(), isEmpty);
    expect(bar.shownLabels, contains('Music'));
    bar.dispose();
  });
}
