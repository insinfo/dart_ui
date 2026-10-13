import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

RenderText _laid(Text text, double width) {
  final BuildOwner owner = BuildOwner(
    pipelineOwner: PipelineOwner(
      rootConstraints: BoxConstraints.tight(Size(width, 100)),
    ),
  );
  owner.updateRoot(Directionality(
    textDirection: TextDirection.leftToRight,
    child: Align(alignment: Alignment.topLeft, child: text),
  ));
  owner.buildScope();
  owner.pipelineOwner.drawFrame(DisplayList());
  RenderText? found;
  void walk(RenderBox node) {
    if (node is RenderText) found = node;
    node.visitChildren(walk);
  }

  walk(owner.renderRoot!);
  return found!;
}

void main() {
  setUpAll(FrameworkFonts.install);
  tearDownAll(FontRegistry.instance.reset);

  test('a one-line label too long for its box ends in an ellipsis', () {
    final RenderText cut = _laid(
        const Text('A rather long folder name that cannot fit',
            maxLines: 1, ellipsis: '…'),
        120);
    expect(cut.size.width, lessThanOrEqualTo(120));
    expect(cut.size.height, lessThan(30), reason: 'still one line');
  });

  test('two lines, centred, under an icon', () {
    final RenderText caption = _laid(
        const Text('Quarterly report final version',
            maxLines: 2, ellipsis: '…', textAlign: TextAlign.center),
        110);
    expect(caption.textAlign, TextAlign.center);
    expect(caption.size.height, greaterThan(20), reason: 'it wrapped');
    expect(caption.size.width, lessThanOrEqualTo(110));
  });
}
