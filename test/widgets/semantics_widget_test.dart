/// Semantics: an application's own widget, described and operated from
/// the widget tree.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  test('a composed button reads as one and can be pressed', () {
    var taps = 0;
    var level = 3;
    final BuildOwner owner = BuildOwner(
      pipelineOwner: PipelineOwner(
          rootConstraints: BoxConstraints.tight(const Size(200, 100))),
    )..updateRoot(Directionality(
        textDirection: TextDirection.leftToRight,
        child: Column(children: <Widget>[
          Semantics(
            button: true,
            label: 'Save',
            hint: 'writes the file',
            onTap: () => taps++,
            child: GestureDetector(
              onTap: () => taps++,
              child: const SizedBox(width: 60, height: 20),
            ),
          ),
          Semantics(
            label: 'Volume',
            value: '3',
            increasedValue: '4',
            onIncrease: () => level++,
            child: const SizedBox(width: 60, height: 20),
          ),
          const Semantics(
            enabled: false,
            button: true,
            label: 'Delete',
            child: SizedBox(width: 60, height: 20),
          ),
        ]),
      ));
    owner.buildScope();
    owner.pipelineOwner.drawFrame(DisplayList());
    final SemanticsSnapshot snapshot = owner.buildSemantics();
    final SemanticsNode save =
        snapshot.nodes.firstWhere((SemanticsNode n) => n.label == 'Save');
    expect(save.role, SemanticsRole.button);
    expect(save.hint, 'writes the file');
    expect(save.actions, contains(SemanticsAction.activate));
    expect(
        owner.semanticsOwner.performAction(save.id, SemanticsAction.activate),
        isTrue);
    expect(taps, 1, reason: 'the screen reader pressed it');

    final SemanticsNode volume =
        snapshot.nodes.firstWhere((SemanticsNode n) => n.label == 'Volume');
    expect(volume.value, '3');
    owner.semanticsOwner.performAction(volume.id, SemanticsAction.increment);
    expect(level, 4);

    final SemanticsNode delete =
        snapshot.nodes.firstWhere((SemanticsNode n) => n.label == 'Delete');
    expect(delete.states, contains(SemanticsState.disabled));
    expect(delete.actions, isNot(contains(SemanticsAction.activate)));
    owner.dispose();
  });
}
