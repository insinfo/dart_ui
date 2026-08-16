/// Device-loss recovery, driven by a device that loses itself on demand.
///
/// Device loss is the hardest rendering condition to test honestly, because
/// the real thing needs a driver reset that no test can arrange. The usual
/// answer - assert that nothing threw - is worthless: a recovery that silently
/// did nothing passes it, and so does one that recreated the device and left
/// every atlas pointing at freed memory.
///
/// So this file injects the loss instead, into a host that records what was
/// asked of it and in what order. That makes the *protocol* testable on a
/// machine with no GPU at all - which is what CI is on Linux and macOS - and
/// leaves exactly one thing that needs a real driver: whether the pixels come
/// back identical. That claim is made in `gl_recovery_device_test.dart` and
/// `d3d11/d3d11_recovery_test.dart`, both of which skip with a stated reason
/// when there is no device.
///
/// Nothing here is skipped. Every assertion below is about the coordinator,
/// which is deliberately device-independent.
library;

import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_device_state.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_recovery.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';

void main() {
  group('the event channel', () {
    test('delivers synchronously, which is the whole reason it is not a Stream',
        () {
      final channel = RendererEventChannel();
      final seen = <RendererEvent>[];
      channel.listen(seen.add);

      channel.emit(const DeviceLost(
        backendName: 'test',
        diagnostic: BackendDiagnostic.note('gone'),
        lossCount: 1,
      ));

      // No await, no pumpEventQueue. A broadcast Stream would deliver on a
      // microtask, by which time the frame loop has already decided what to do
      // with the present result - and the decision is the reason the event
      // exists.
      expect(seen, hasLength(1));
      expect(seen.single, isA<DeviceLost>());
    });

    test('a listener that throws is contained, not allowed to abort the frame',
        () {
      final channel = RendererEventChannel();
      final seen = <String>[];
      channel.listen((_) => throw StateError('a broken handler'));
      channel.listen((_) => seen.add('second'));

      channel.emit(const OutOfMemory(
        backendName: 'test',
        diagnostic: BackendDiagnostic.note('no room'),
        resourceName: 'layer target 512x512',
      ));

      // The second listener still ran: a recovery must not be abandoned half
      // way through because somebody's logger had a bug.
      expect(seen, <String>['second']);
      expect(channel.listenerErrorCount, 1);
      expect(channel.lastListenerError, isA<StateError>());
    });

    test('a listener may cancel itself from inside its own callback', () {
      final channel = RendererEventChannel();
      var calls = 0;
      late RendererEventSubscription subscription;
      subscription = channel.listen((_) {
        calls++;
        subscription.cancel();
      });

      channel
        ..emit(_note())
        ..emit(_note());

      expect(calls, 1);
      expect(subscription.isCancelled, isTrue);
      expect(channel.listenerCount, 0);
    });

    test('the recording sink is bounded rather than unbounded', () {
      // A device resetting in a loop must not turn a rendering problem into an
      // out-of-memory one.
      final sink = RecordingRendererEventSink(capacity: 3);
      for (var i = 0; i < 5; i++) {
        sink.emit(DeviceLost(
          backendName: 'test',
          diagnostic: const BackendDiagnostic.note('gone'),
          lossCount: i + 1,
        ));
      }

      expect(sink.events, hasLength(3));
      expect(sink.droppedCount, 2);
      expect(sink.ofType<DeviceLost>().first.lossCount, 3);
    });
  });

  group('a clean recovery', () {
    test('runs the eight steps in the order section 23.12 gives them', () {
      final host = _FakeHost()..resources = <_FakeResource>[_FakeResource('a')];
      final sink = RecordingRendererEventSink();
      final coordinator = GpuRecoveryCoordinator(host: host, events: sink);

      host.lose('a TDR');
      final GpuRecoveryReport report = coordinator.recover();

      expect(report.status, GpuRecoveryStatus.recovered);
      // The order is the assertion. A discard that ran after the device was
      // recreated would be deleting objects on the *new* device, and a
      // repopulate that ran before it would be creating them on the dead one.
      expect(host.log, <String>[
        'stopSubmissions',
        'discardNativeResources',
        'discard:a',
        'recreateDevice',
        'repopulate:a',
      ]);
      expect(report.discardedCount, 1);
      expect(report.repopulatedCount, 1);
      expect(report.unrecoverableResources, isEmpty);
      expect(report.cause!.message, contains('a TDR'));
    });

    test('emits DeviceLost before DeviceRecovered, and both name the backend',
        () {
      final host = _FakeHost();
      final sink = RecordingRendererEventSink();
      final coordinator = GpuRecoveryCoordinator(host: host, events: sink);

      host.lose('a driver update');
      coordinator.recover();

      expect(sink.events.map((RendererEvent e) => e.runtimeType.toString()),
          <String>['DeviceLost', 'DeviceRecovered']);
      final DeviceLost lost = sink.ofType<DeviceLost>().single;
      final DeviceRecovered recovered = sink.ofType<DeviceRecovered>().single;
      expect(lost.backendName, 'fake');
      expect(lost.lossCount, 1);
      expect(recovered.lossCount, 1);
      // Step 6, as a field rather than an implication: a caller that redrew
      // only its damage rectangle would show whatever the driver left in a
      // freshly allocated surface everywhere else.
      expect(recovered.needsFullRepaint, isTrue);
      expect(recovered.unrecoverableResources, isEmpty);
    });

    test('leaves the state healthy and the loss count where it was', () {
      final host = _FakeHost();
      final coordinator = GpuRecoveryCoordinator(host: host);

      host.lose('once');
      coordinator.recover();

      expect(host.deviceState.isLost, isFalse);
      expect(host.deviceState.blockedPresent(), isNull);
      // lossCount deliberately does not go back down: a target derives its
      // generation from it, so a frame begun before the loss must still
      // present as stale after the recovery.
      expect(host.deviceState.lossCount, 1);
    });

    test('a healthy device is left alone rather than torn down', () {
      final host = _FakeHost()..resources = <_FakeResource>[_FakeResource('a')];
      final coordinator = GpuRecoveryCoordinator(host: host);

      final GpuRecoveryReport report = coordinator.recover();

      expect(report.status, GpuRecoveryStatus.notLost);
      expect(host.log, isEmpty,
          reason: 'recovering a device that never died would throw away every '
              'atlas for nothing');
    });

    test('reportLoss emits once per loss, however many targets ask', () {
      final host = _FakeHost();
      final sink = RecordingRendererEventSink();
      final coordinator = GpuRecoveryCoordinator(host: host, events: sink);

      host.lose('one reset');
      // Three targets sharing one device all notice the same loss.
      expect(coordinator.reportLoss(), isTrue);
      expect(coordinator.reportLoss(), isFalse);
      expect(coordinator.reportLoss(), isFalse);

      expect(sink.ofType<DeviceLost>(), hasLength(1));
    });
  });

  group('the inventory', () {
    test('an orphaned resource is named, and the rest still come back', () {
      final host = _FakeHost()
        ..resources = <_FakeResource>[
          _FakeResource('mask atlas 1024x1024'),
          _FakeResource('image #7 (64x64)', recoverable: false),
          _FakeResource('image #8 (32x32)'),
        ];
      final sink = RecordingRendererEventSink();
      final coordinator = GpuRecoveryCoordinator(host: host, events: sink);

      host.lose('a reset');
      final GpuRecoveryReport report = coordinator.recover();

      // Recovered, not failed: the device draws again. What is lost is named.
      expect(report.status, GpuRecoveryStatus.recoveredWithLosses);
      expect(report.isRecovered, isTrue);
      expect(report.unrecoverableResources, <String>['image #7 (64x64)']);
      expect(report.repopulatedCount, 2);
      // And an orphan is never asked to repopulate, because there is nothing
      // it could honestly do.
      expect(host.log, isNot(contains('repopulate:image #7 (64x64)')));
      expect(host.log, contains('discard:image #7 (64x64)'));

      final DeviceRecovered recovered = sink.ofType<DeviceRecovered>().single;
      expect(recovered.unrecoverableResources, <String>['image #7 (64x64)']);
      expect(recovered.toString(), contains('image #7 (64x64)'));
    });

    test('a resource that refuses to come back fails the whole recovery', () {
      final host = _FakeHost()
        ..resources = <_FakeResource>[
          _FakeResource('mask atlas'),
          _FakeResource('glyph atlas', repopulateFailure: 'no texture memory'),
        ];
      final sink = RecordingRendererEventSink();
      final coordinator = GpuRecoveryCoordinator(host: host, events: sink);

      host.lose('a reset');
      final GpuRecoveryReport report = coordinator.recover();

      expect(report.status, GpuRecoveryStatus.failed);
      expect(report.failedStep, GpuRecoveryStep.repopulateResources);
      expect(report.failure!.detail, contains('no texture memory'));
      // Still lost, so the caller may try again and every present goes on
      // answering deviceLost rather than drawing into nothing.
      expect(host.deviceState.isLost, isTrue);
      expect(sink.ofType<DeviceRecoveryFailed>(), hasLength(1));
      expect(sink.ofType<DeviceRecovered>(), isEmpty);
    });
  });

  group('a failing recovery', () {
    test('a device that cannot be recreated leaves the state lost', () {
      final host = _FakeHost()..recreateFailure = 'no adapter answered';
      final sink = RecordingRendererEventSink();
      final coordinator = GpuRecoveryCoordinator(host: host, events: sink);

      host.lose('a reset');
      final GpuRecoveryReport report = coordinator.recover();

      expect(report.status, GpuRecoveryStatus.failed);
      expect(report.failedStep, GpuRecoveryStep.recreateDevice);
      expect(host.deviceState.isLost, isTrue);
      expect(
          host.deviceState.blockedPresent()!.status, PresentStatus.deviceLost);
      final DeviceRecoveryFailed failed =
          sink.ofType<DeviceRecoveryFailed>().single;
      expect(failed.attempt, 1);
      expect(failed.step, GpuRecoveryStep.recreateDevice);
    });

    test('a host that claims success and leaves the device lost is caught', () {
      // The one inconsistency that would be invisible otherwise: a device
      // reporting itself lost forever while every caller believes the recovery
      // worked, so every present answers deviceLost and nothing ever retries.
      final host = _FakeHost()..recoverStateOnRecreate = false;
      final coordinator = GpuRecoveryCoordinator(host: host);

      host.lose('a reset');
      final GpuRecoveryReport report = coordinator.recover();

      expect(report.status, GpuRecoveryStatus.failed);
      expect(report.failure!.message, contains('left the device marked lost'));
      expect(report.failure!.detail, contains('GpuDeviceState.recover'));
    });

    test('a host that throws becomes a failure, not an escaped exception', () {
      final host = _FakeHost()..throwOnRecreate = true;
      final coordinator = GpuRecoveryCoordinator(host: host);

      host.lose('a reset');
      late GpuRecoveryReport report;
      // The assertion is that this line does not need a try/catch. An exception
      // escaping a recovery unwinds through the frame loop and leaves a device
      // that is neither lost nor usable.
      expect(() => report = coordinator.recover(), returnsNormally);

      expect(report.status, GpuRecoveryStatus.failed);
      expect(report.failure!.message, contains('bug in the backend'));
      expect(host.deviceState.isLost, isTrue);
    });
  });

  group('the CPU fallback', () {
    test('three losses in the window recover; the fourth falls back', () {
      final clock = _Clock();
      final host = _FakeHost();
      final sink = RecordingRendererEventSink();
      final coordinator = GpuRecoveryCoordinator(
        host: host,
        events: sink,
        clock: clock.now,
      );

      // The declared policy: 3 attempts inside 10 seconds.
      expect(coordinator.policy.maxAttempts, 3);
      expect(coordinator.policy.window, const Duration(seconds: 10));

      for (var i = 0; i < 3; i++) {
        host.lose('reset ${i + 1}');
        expect(coordinator.recover().status, GpuRecoveryStatus.recovered);
        clock.advance(const Duration(seconds: 1));
      }

      host.lose('reset 4');
      final GpuRecoveryReport report = coordinator.recover();

      expect(report.status, GpuRecoveryStatus.fellBackToCpu);
      expect(coordinator.hasFallenBackToCpu, isTrue);
      expect(host.recreateCount, 3, reason: 'the fourth was refused, not run');
      final RendererFellBackToCpu event =
          sink.ofType<RendererFellBackToCpu>().single;
      expect(event.attempts, 3);
      expect(event.window, const Duration(seconds: 10));
      expect(event.diagnostic.detail, contains('DisplayList'),
          reason: 'the owner has to be told the scene survived and the GPU '
              'content did not');

      // Terminal. The device stays lost, which is what makes the owner switch
      // to the CPU renderer instead of showing a frozen window.
      expect(host.deviceState.isLost, isTrue);
      expect(coordinator.recover().status, GpuRecoveryStatus.fellBackToCpu);
      expect(host.recreateCount, 3);
    });

    test('losses spread outside the window never fall back', () {
      // The reason the criterion is a sliding window and not a consecutive
      // count: a GPU that resets once a minute for an hour recovers cleanly
      // every time and must not be demoted to software for it.
      final clock = _Clock();
      final host = _FakeHost();
      final coordinator = GpuRecoveryCoordinator(
        host: host,
        events: null,
        clock: clock.now,
      );

      for (var i = 0; i < 10; i++) {
        host.lose('reset $i');
        expect(coordinator.recover().status, GpuRecoveryStatus.recovered);
        clock.advance(const Duration(seconds: 60));
      }

      expect(coordinator.hasFallenBackToCpu, isFalse);
      expect(host.recreateCount, 10);
      expect(host.deviceState.lossCount, 10);
    });

    test('a failed recreation counts towards the limit like a successful one',
        () {
      final clock = _Clock();
      final host = _FakeHost()..recreateFailure = 'the adapter is gone';
      final coordinator = GpuRecoveryCoordinator(
        host: host,
        clock: clock.now,
      );

      host.lose('a reset');
      for (var i = 0; i < 3; i++) {
        expect(coordinator.recover().status, GpuRecoveryStatus.failed);
        clock.advance(const Duration(milliseconds: 100));
      }

      // A device that refuses three times in 300ms is not going to accept a
      // fourth, and each attempt costs a whole device creation.
      expect(coordinator.recover().status, GpuRecoveryStatus.fellBackToCpu);
      expect(host.log.where((String e) => e == 'recreateDevice').length, 3,
          reason: 'the fourth attempt was refused before it reached the '
              'backend');
      expect(host.recreateCount, 0, reason: 'none of the three succeeded');
    });

    test('a policy may refuse to fall back at all', () {
      final clock = _Clock();
      final host = _FakeHost();
      final coordinator = GpuRecoveryCoordinator(
        host: host,
        policy: GpuRecoveryPolicy.neverFallBack,
        clock: clock.now,
      );

      for (var i = 0; i < 50; i++) {
        host.lose('reset $i');
        expect(coordinator.recover().isRecovered, isTrue);
      }
      expect(coordinator.hasFallenBackToCpu, isFalse);
    });
  });

  group('the observable state', () {
    test('lossCount and attemptCount agree with what happened', () {
      final clock = _Clock();
      final host = _FakeHost();
      final coordinator = GpuRecoveryCoordinator(host: host, clock: clock.now);

      expect(host.deviceState.lossCount, 0);
      expect(coordinator.attemptCount, 0);

      host.lose('first');
      coordinator.recover();
      clock.advance(const Duration(seconds: 30));
      host.lose('second');
      coordinator.recover();

      expect(host.deviceState.lossCount, 2);
      expect(coordinator.attemptCount, 2);
      // Only one is still inside the ten-second window.
      expect(coordinator.attemptsInWindow, 1);
    });

    test('a second loss while already lost keeps the first reason', () {
      // The errors that follow a lost device are consequences; the first one
      // is the one worth reporting.
      final host = _FakeHost();
      host
        ..lose('the real cause')
        ..lose('a consequence');

      expect(host.deviceState.lossCount, 1);
      expect(
          host.deviceState.lossDiagnostic!.message, contains('the real cause'));
    });
  });
}

RendererEvent _note() => const SurfaceOutOfDate(
      backendName: 'test',
      diagnostic: BackendDiagnostic.note('resized'),
      generation: 2,
    );

/// A clock a test can move, so the ten-second window is exercised at its
/// boundary instead of near it and the loop test takes microseconds.
final class _Clock {
  DateTime _now = DateTime.utc(2026, 1, 1);

  DateTime now() => _now;

  void advance(Duration by) => _now = _now.add(by);
}

/// A device that loses itself on demand and records what it was asked to do.
final class _FakeHost implements GpuRecoveryHost {
  @override
  final GpuDeviceState deviceState = GpuDeviceState();

  @override
  String get backendName => 'fake';

  final List<String> log = <String>[];

  List<_FakeResource> resources = <_FakeResource>[];

  /// When set, [recreateDevice] refuses with this as the detail.
  String? recreateFailure;

  /// When false, [recreateDevice] returns success without clearing the state -
  /// the inconsistency the coordinator is required to catch.
  bool recoverStateOnRecreate = true;

  bool throwOnRecreate = false;

  int recreateCount = 0;

  void lose(String why) => deviceState.markLost(BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'injected loss: $why',
      ));

  @override
  void stopSubmissions() => log.add('stopSubmissions');

  @override
  void discardNativeResources() => log.add('discardNativeResources');

  @override
  BackendDiagnostic? recreateDevice() {
    log.add('recreateDevice');
    if (throwOnRecreate) throw StateError('a bug in the backend');
    if (recreateFailure != null) {
      return BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'the fake device could not be recreated',
        detail: recreateFailure,
      );
    }
    recreateCount++;
    if (recoverStateOnRecreate) deviceState.recover();
    return null;
  }

  @override
  Iterable<GpuRecoverableResource> recoverableResources() =>
      resources.map((_FakeResource r) => r.asResource(log));
}

final class _FakeResource {
  _FakeResource(
    this.name, {
    this.recoverable = true,
    this.repopulateFailure,
  });

  final String name;
  final bool recoverable;
  final String? repopulateFailure;

  GpuRecoverableResource asResource(List<String> log) => CallbackGpuResource(
        resourceName: name,
        recoveryOf: () => recoverable
            ? GpuResourceRecovery.reuploaded
            : GpuResourceRecovery.orphaned,
        onDiscard: () => log.add('discard:$name'),
        onRepopulate: () {
          log.add('repopulate:$name');
          if (repopulateFailure == null) return null;
          return BackendDiagnostic(
            kind: DiagnosticKind.incompatibleDevice,
            message: '$name could not be rebuilt',
            detail: repopulateFailure,
          );
        },
      );
}
