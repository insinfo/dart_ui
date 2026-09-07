/// The continuous frame loop, from the application's loop rather than from a
/// controller held by a test.
///
/// `frame_loop_test.dart` pins the controller's policy: what `isFrameDue`
/// answers, how a late frame is counted, what the accumulator does with a
/// nine-millisecond delta. Every case in it constructs the controller itself,
/// which is exactly the shape of test that let this whole file sit written,
/// reviewed and **reachable from nothing** - the same gap
/// `compute_route_reachability_test.dart` was written for, in a different
/// subsystem.
///
/// So these cases start a real [Application] and let `run()` drive it, and the
/// question each asks is one an application can ask:
///
///   * does a default application still draw exactly when something changed,
///     and never because time passed;
///   * does a continuous one draw with nothing invalidating at all;
///   * does the platform wait shorten to the frame interval, or does the loop
///     sleep straight past its own deadline;
///   * does switching at runtime take effect on the loop that is running.
///
/// The pairing is the evidence: the **same static tree** for the same wall
/// time in the two modes, and the frame counts have to differ. A single-mode
/// test would pass just as happily against a loop that ignored the controller
/// and drew whenever it felt like it.
library;

import 'dart:async' show Timer;
import 'dart:io' show sleep;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

/// A headless backend whose `pumpEvents` actually waits.
///
/// The stock headless pump returns immediately - "a headless pump never
/// sleeps" - which makes every timeout in this file unobservable and turns a
/// continuous run into a spin that produces frames for the wrong reason. This
/// one sleeps for the timeout it was given and records it, so the clamp is
/// checkable rather than asserted.
final class _WaitingHeadlessBackend implements WindowingBackend {
  final HeadlessWindowingBackend _delegate = HeadlessWindowingBackend();
  final List<Duration> positiveTimeouts = <Duration>[];

  @override
  String get name => _delegate.name;

  @override
  BackendProbeResult probe() => _delegate.probe();

  @override
  Future<void> initialize() => _delegate.initialize();

  @override
  Future<void> shutdown() => _delegate.shutdown();

  @override
  Future<NativeWindow> createWindow(WindowOptions options) =>
      _delegate.createWindow(options);

  @override
  List<NativeWindow> get windows => _delegate.windows;

  @override
  bool pumpEvents({Duration timeout = Duration.zero}) {
    if (timeout > Duration.zero) {
      positiveTimeouts.add(timeout);
      sleep(timeout);
    }
    return _delegate.pumpEvents();
  }

  @override
  void wake() => _delegate.wake();
}

/// A tree that never asks for a frame: no animation, no timer, no state.
///
/// Deliberately the dullest thing that lays out. Anything that invalidated on
/// its own would supply the frames the continuous case is supposed to be
/// producing by itself, and the comparison below would prove nothing.
const Widget _static = Center(child: SizedBox(width: 40, height: 40));

/// Runs one application for [duration] and hands it back for inspection.
Future<Application> _runFor(
  Duration duration, {
  required FrameLoopOptions frameLoop,
  _WaitingHeadlessBackend? backend,
  void Function(Application app)? midway,
}) async {
  final _WaitingHeadlessBackend host = backend ?? _WaitingHeadlessBackend();
  final Application application = await Application.start(
    rootWidget: _static,
    backends: <WindowingBackendEntry>[
      WindowingBackendEntry(name: 'headless', create: () => host),
    ],
    options: ApplicationOptions(
      size: const Size(64, 64),
      idleTimeout: const Duration(milliseconds: 250),
      frameLoop: frameLoop,
    ),
  );
  if (midway != null) {
    final Duration half = Duration(microseconds: duration.inMicroseconds ~/ 2);
    Timer(
      half,
      () {
        midway(application);
        // A busy shared runner may deliver this timer later than requested.
        // Start the observation half when the switch is actually delivered,
        // instead of letting an already-due close timer run in the same turn.
        Timer(half, application.requestClose);
      },
    );
  } else {
    Timer(duration, application.requestClose);
  }
  await application.run();
  return application;
}

void main() {
  const Duration window = Duration(milliseconds: 240);
  const Duration interval = Duration(milliseconds: 10);
  const FrameLoopOptions continuous = FrameLoopOptions.continuous(
    frameInterval: interval,
  );

  group('the default is the loop this framework already had', () {
    test('a static tree draws once and then stops', () async {
      final Application app = await _runFor(
        window,
        frameLoop: const FrameLoopOptions(),
      );
      addTearDown(() async {
        app.dispose();
        await app.closed;
      });

      // The regression this pins: wiring a real-time loop into `run()` must
      // not give an ordinary window a heartbeat. If this ever reads 20, the
      // coexistence guarantee is gone and every idle form in every
      // application is drawing at 100 Hz.
      expect(app.framesPresented, 1);
      expect(app.frameLoop.isContinuous, isFalse);
      expect(app.frameLoop.isFrameDue, isFalse);
    });

    test('and nothing is bracketed, so the pacing record stays empty',
        () async {
      final Application app = await _runFor(
        window,
        frameLoop: const FrameLoopOptions(),
      );
      addTearDown(() async {
        app.dispose();
        await app.closed;
      });

      // Deliberate, not an oversight. On demand, an interval between frames
      // is the interval between two unrelated user actions - "37 seconds
      // since the last frame" is true and means nothing - and every one of
      // those gaps would land in `framesDropped`.
      expect(app.frameLoop.statistics.framesProduced, 0);
      expect(app.frameLoop.statistics.count, 0);
      expect(app.frameLoop.statistics.framesDropped, 0);
    });
  });

  group('continuous draws because time passed', () {
    test('the same static tree produces many frames instead of one', () async {
      final Application app = await _runFor(window, frameLoop: continuous);
      addTearDown(() async {
        app.dispose();
        await app.closed;
      });

      // 240 ms at 10 ms is 24 frames on an unloaded machine. The floor is
      // deliberately far below that: this suite shares a runner with GPU work
      // and the claim being made is "many, not one", which a shared machine
      // cannot take away.
      expect(
        app.framesPresented,
        greaterThanOrEqualTo(5),
        reason: 'nothing in this tree ever invalidates, so every frame after '
            'the first exists because a deadline came round',
      );
      expect(app.frameLoop.statistics.framesProduced, app.framesPresented);
      expect(
        app.frameLoop.statistics.count,
        app.frameLoop.statistics.framesProduced,
        reason: 'every frame opened must also be recorded, or the averages '
            'are computed over a subset nobody chose',
      );
    });

    test('the platform wait never sleeps past the deadline', () async {
      final _WaitingHeadlessBackend backend = _WaitingHeadlessBackend();
      final Application app = await _runFor(
        window,
        frameLoop: continuous,
        backend: backend,
      );
      addTearDown(() async {
        app.dispose();
        await app.closed;
      });

      // Without the clamp the loop takes the 250 ms idle timeout, wakes once,
      // and the whole run is one frame. This is the assertion that separates
      // "the controller is consulted" from "the controller is built".
      expect(backend.positiveTimeouts, isNotEmpty);
      expect(
        backend.positiveTimeouts,
        everyElement(lessThanOrEqualTo(interval)),
      );
    });

    test('input latency is measured, which fixes the pump/draw order',
        () async {
      final Application app = await _runFor(window, frameLoop: continuous);
      addTearDown(() async {
        app.dispose();
        await app.closed;
      });

      // Non-zero only if `notePumpComplete` ran *before* `beginFrame`. A loop
      // that drew first and pumped afterwards would compute every frame from
      // input one whole frame old, and no dispatcher priority rescues that.
      expect(
        app.frameLoop.statistics.inputToFrameLatency,
        greaterThan(Duration.zero),
      );
    });
  });

  group('switching mode at runtime', () {
    test('turning it on midway starts the heartbeat', () async {
      final Application app = await _runFor(
        window,
        frameLoop: const FrameLoopOptions(frameInterval: interval),
        midway: (Application a) =>
            a.frameLoop.setMode(FrameLoopMode.continuous),
      );
      addTearDown(() async {
        app.dispose();
        await app.closed;
      });

      expect(app.frameLoop.isContinuous, isTrue);
      expect(
        app.framesPresented,
        greaterThan(1),
        reason: 'an editor turns this on when a clip starts playing; if the '
            'switch only took effect at startup it would be useless',
      );
    });

    test('turning it off midway stops it', () async {
      final Application app = await _runFor(
        window,
        frameLoop: continuous,
        midway: (Application a) => a.frameLoop.setMode(FrameLoopMode.onDemand),
      );
      addTearDown(() async {
        app.dispose();
        await app.closed;
      });

      expect(app.frameLoop.isContinuous, isFalse);
      final int produced = app.frameLoop.statistics.framesProduced;
      expect(
        produced,
        greaterThan(0),
        reason: 'the first half of the run was continuous',
      );
      // The second half must have cost nothing. Half of 240 ms at 10 ms is
      // about 12 frames; a run that never stopped would be about 24.
      expect(
        produced,
        lessThan(window.inMilliseconds ~/ interval.inMilliseconds),
      );
    });
  });
}
