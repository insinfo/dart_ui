/// Where a Text's letters sit, whichever path lays it out.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(FrameworkFonts.install);
  tearDownAll(FontRegistry.instance.reset);

  test('wrapped text reports its first line, below half its leading', () {
    final BuildOwner owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(400, 100)),
      ),
    )..updateRoot(const Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        children: <Widget>[
          Text('Size:', style: TextStyle(height: 1.6)),
          Expanded(
              child: Text('2.30 MB',
                  softWrap: true, style: TextStyle(height: 1.6))),
        ],
      ));
    owner.buildScope();
    owner.pipelineOwner.drawFrame(DisplayList());
    final List<RenderText> texts = <RenderText>[];
    void walk(RenderBox node) {
      if (node is RenderText) texts.add(node);
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    final RenderText label =
        texts.firstWhere((RenderText t) => t.text == 'Size:');
    final RenderText value =
        texts.firstWhere((RenderText t) => t.text == '2.30 MB');
    final double labelBase = label.localToGlobal(Offset.zero).dy +
        label.computeDistanceToActualBaseline(TextBaseline.alphabetic)!;
    final double valueBase = value.localToGlobal(Offset.zero).dy +
        value.computeDistanceToActualBaseline(TextBaseline.alphabetic)!;
    expect(value.size.height, greaterThan(label.size.height),
        reason: 'the paragraph has leading, the label does not');
    expect(valueBase, closeTo(labelBase, 0.01), reason: 'and yet they line up');
    // What the row aligned is what is drawn: the paragraph's letters start
    // half a leading down, so its baseline is further from its top.
    expect(
      value.computeDistanceToActualBaseline(TextBaseline.alphabetic)!,
      greaterThan(
          label.computeDistanceToActualBaseline(TextBaseline.alphabetic)! + 1),
    );
    owner.dispose();
  });
}
