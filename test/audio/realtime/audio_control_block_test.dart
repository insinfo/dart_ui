import 'package:dart_ui/audio.dart';
import 'package:test/test.dart';

void main() {
  test('parameters, triggers and telemetry are seen through an attached view',
      () {
    final AudioControlBlock owner = AudioControlBlock.allocate(
      parameters: 2,
      triggers: 1,
      telemetry: 3,
    );
    final AudioControlBlock view = AudioControlBlock.attach(owner.address);
    expect((view.parameterCount, view.triggerCount, view.telemetryCount),
        (2, 1, 3));

    owner.setParameter(1, 0.25);
    expect(view.parameter(1), 0.25);
    expect(view.parameter(0), 0, reason: 'a new block starts at zero');

    final int before = view.triggerSequence(0);
    owner
      ..trigger(0)
      ..trigger(0);
    expect(view.triggerSequence(0), before + 2);

    view.publish(2, -0.5);
    expect(owner.telemetry(2), -0.5);

    view.dispose();
    expect(owner.parameter(1), 0.25, reason: 'a view frees nothing');
    owner.dispose();
  });

  test('indices are checked per region', () {
    final AudioControlBlock block =
        AudioControlBlock.allocate(parameters: 1, telemetry: 1);
    expect(() => block.parameter(1), throwsRangeError);
    expect(() => block.trigger(0), throwsRangeError);
    expect(() => block.publish(1, 0), throwsRangeError);
    block.dispose();
  });

  test('attach refuses memory that is not a control block', () {
    final AudioControlBlock block = AudioControlBlock.allocate(parameters: 4);
    expect(() => AudioControlBlock.attach(block.address + 4), throwsStateError);
    expect(() => AudioControlBlock.attach(0), throwsArgumentError);
    block.dispose();
  });
}
