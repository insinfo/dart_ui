import 'package:poc_20_macos_three_backends/poc_20_macos_three_backends.dart';
import 'package:test/test.dart';

void main() {
  test('lifecycle follows normal initialization and shutdown', () {
    final lifecycle = MacosBackendLifecycle();

    expect(lifecycle.state, MacosBackendState.created);
    lifecycle.beginInitialize();
    final activeGeneration = lifecycle.generation;
    lifecycle.finishInitialize();

    expect(lifecycle.state, MacosBackendState.running);
    expect(lifecycle.acceptsCallback(activeGeneration), isTrue);
    expect(lifecycle.beginShutdown(), isTrue);
    expect(lifecycle.acceptsCallback(activeGeneration), isFalse);
    lifecycle.finishShutdown();

    expect(lifecycle.state, MacosBackendState.stopped);
    expect(lifecycle.beginShutdown(), isFalse);
  });

  test('failed initialization invalidates its callback generation', () {
    final lifecycle = MacosBackendLifecycle()..beginInitialize();
    final failedGeneration = lifecycle.generation;

    lifecycle.failInitialize();

    expect(lifecycle.state, MacosBackendState.failed);
    expect(lifecycle.acceptsCallback(failedGeneration), isFalse);
    expect(lifecycle.beginShutdown(), isTrue);
    lifecycle.finishShutdown();
  });

  test('invalid transition fails before touching native resources', () {
    final lifecycle = MacosBackendLifecycle();

    expect(
      lifecycle.finishInitialize,
      throwsA(isA<MacosBackendStateError>()),
    );
    expect(
      () => lifecycle.requireRunning('create window'),
      throwsA(isA<MacosBackendStateError>()),
    );
  });

  test('callback from a different generation is rejected', () {
    final lifecycle = MacosBackendLifecycle()
      ..beginInitialize()
      ..finishInitialize();

    expect(lifecycle.acceptsCallback(lifecycle.generation + 1), isFalse);
  });
}
