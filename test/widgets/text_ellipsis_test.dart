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

  test('a word with no break in it is cut where the width runs out', () {
    const String name = 'IMG_2022_06_01_holiday_photo.jpg';
    final RenderText overflowing =
        _laid(const Text(name, softWrap: true, maxLines: 3), 90);
    final RenderText broken = _laid(
        const Text(name, softWrap: true, maxLines: 3, breakWords: true), 90);
    expect(broken.size.width, lessThanOrEqualTo(90));
    expect(broken.size.height, greaterThan(overflowing.size.height),
        reason: 'it wrapped onto more lines instead of running past');
  });

  test(
      'a centred caption fills its width, so a parent centring it does '
      'not shift it twice', () {
    final RenderText caption = _laid(
        const Text('Adobe', maxLines: 2, textAlign: TextAlign.center), 120);
    expect(caption.size.width, 120);
  });
}
