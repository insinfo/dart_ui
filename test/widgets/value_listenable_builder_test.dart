import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(FrameworkFonts.install);
  tearDownAll(FontRegistry.instance.reset);

  test('only the builder rebuilds when the value changes', () {
    final ValueNotifier<int> count = ValueNotifier<int>(0);
    var outer = 0;
    var inner = 0;
    final BuildOwner owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(100, 50)),
      ),
    );
    owner.updateRoot(Directionality(
      textDirection: TextDirection.leftToRight,
      child: Builder(builder: (BuildContext context) {
        outer++;
        return ValueListenableBuilder<int>(
          valueListenable: count,
          builder: (BuildContext context, int value, Widget? child) {
            inner++;
            return Text('$value');
          },
        );
      }),
    ));
    owner.buildScope();
    expect((outer, inner), (1, 1));

    count.value = 1;
    owner.buildScope();
    count.value = 2;
    owner.buildScope();
    expect((outer, inner), (1, 3));
    owner.dispose();
  });
}
