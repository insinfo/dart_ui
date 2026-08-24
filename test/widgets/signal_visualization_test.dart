import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  test('SignalPlot records one reusable waveform path', () {
    final BuildOwner owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(320, 160)),
      ),
    );
    owner.updateRoot(const SignalPlot(samples: <double>[-1, 0, 1, 0, -1]));
    final DisplayList list = DisplayList();
    owner.pipelineOwner.drawFrame(list);

    expect(list.pathCount, 1);
    expect(list.commandCount, greaterThanOrEqualTo(6));
    owner.dispose();
  });

  test('SpectrumBars paints every band without child render boxes', () {
    final BuildOwner owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(320, 160)),
      ),
    );
    owner.updateRoot(const SpectrumBars(values: <double>[0, 0.25, 0.5, 1]));
    final DisplayList list = DisplayList();
    owner.pipelineOwner.drawFrame(list);

    expect(owner.renderRoot, isA<RenderSpectrumBars>());
    expect(list.commandCount, 4);
    owner.dispose();
  });
}
