import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';

import 'clock.dart';
import 'cpu_meter.dart';
import 'run_config.dart';
import 'run_result.dart';
import 'sender_isolate.dart';
import 'stats.dart';
import 'win32_bindings.dart';

/// Runs one measured configuration end to end.
Future<RunResult> runMeasurement(RunConfig config) async {
  final wakeHandle = config.usesWakeEvent
      ? createEvent(nullptr, 0 /* auto-reset */, 0 /* unsignalled */, nullptr)
      : 0;
  if (config.usesWakeEvent && wakeHandle == 0) {
    throw StateError('CreateEventW failed.');
  }

  final handles = calloc<IntPtr>();
  final message = calloc<Msg>();
  handles.value = wakeHandle;
  final handleCount = wakeHandle == 0 ? 0 : 1;

  final inbox = ReceivePort();
  final frameGaps = <int>[];
  final messageLatency = <int>[];
  final nativeWaits = <int>[];
  final requestedWaits = <int>[];
  final yieldCosts = <int>[];
  var frameTicks = 0;
  var messagesReceived = 0;

  // Started before the clock so isolate spawn cost is not attributed to the
  // loop under test.
  final controlPortReady = Completer<SendPort>();
  final isolate = await Isolate.spawn(
    senderMain,
    <Object>[inbox.sendPort, config.profile.messageIntervalUs, wakeHandle],
  );

  final startUs = Clock.nowUs();
  final endUs = startUs + config.duration.inMicroseconds;

  inbox.listen((Object? raw) {
    if (raw is SendPort) {
      controlPortReady.complete(raw);
      return;
    }
    if (raw is int) {
      messagesReceived++;
      messageLatency.add(Clock.nowUs() - raw);
    }
  });

  final frameIntervalUs = config.profile.frameIntervalUs;
  Timer? frameTimer;
  if (frameIntervalUs != null) {
    var lastTickUs = startUs;
    frameTimer = Timer.periodic(Duration(microseconds: frameIntervalUs), (_) {
      frameTicks++;
      final nowUs = Clock.nowUs();
      frameGaps.add(nowUs - lastTickUs);
      lastTickUs = nowUs;
    });
  }

  final startThreadId = getCurrentThreadId();
  var threadMigrations = 0;
  var lastThreadId = startThreadId;

  var iterations = 0;
  var wakeupsByTimeout = 0;
  var wakeupsByEvent = 0;
  var wakeupsByMessage = 0;
  var idleWakeups = 0;

  final cpu = CpuMeter();

  if (config.mode == LoopMode.baseline) {
    // Control group: no native loop, the VM schedules the isolate normally.
    await Future<void>.delayed(config.duration);
  } else {
    while (Clock.nowUs() < endUs) {
      final beforeWork = frameTicks + messagesReceived;
      final nowUs = Clock.nowUs();
      final timeoutMs = _timeoutMs(
        config: config,
        nowUs: nowUs,
        endUs: endUs,
        nextDeadlineUs: _nextFrameDeadlineUs(
          startUs: startUs,
          intervalUs: frameIntervalUs,
          nowUs: nowUs,
        ),
      );

      final beforeWaitUs = Clock.nowUs();
      final cause = msgWaitForMultipleObjectsEx(
        handleCount,
        handles,
        timeoutMs,
        qsAllInput,
        mwmoInputAvailable,
      );
      final afterWaitUs = Clock.nowUs();
      nativeWaits.add(afterWaitUs - beforeWaitUs);
      requestedWaits.add(timeoutMs * 1000);
      iterations++;
      if (cause == waitFailed) {
        throw StateError('MsgWaitForMultipleObjectsEx failed.');
      }
      if (cause == waitTimeout) {
        wakeupsByTimeout++;
      } else if (handleCount == 1 && cause == waitObject0) {
        wakeupsByEvent++;
      } else {
        wakeupsByMessage++;
      }

      final drained = _drainMessages(message);

      // The only way to run a turn of the Dart event loop from Dart today.
      final beforeYieldUs = Clock.nowUs();
      await Future<void>.delayed(Duration.zero);
      yieldCosts.add(Clock.nowUs() - beforeYieldUs);

      final currentThreadId = getCurrentThreadId();
      if (currentThreadId != lastThreadId) {
        threadMigrations++;
        lastThreadId = currentThreadId;
      }

      final didWork = (frameTicks + messagesReceived) != beforeWork;
      if (cause == waitTimeout && !didWork && drained == 0) {
        idleWakeups++;
      }
    }
  }

  final cpuMs = cpu.elapsedMs();
  final cpuCycles = cpu.elapsedCycles();
  final wallMs = (Clock.nowUs() - startUs) / 1000.0;

  frameTimer?.cancel();
  if (controlPortReady.isCompleted) {
    (await controlPortReady.future).send('stop');
  }
  isolate.kill(priority: Isolate.beforeNextEvent);
  inbox.close();
  calloc.free(handles);
  calloc.free(message);
  if (wakeHandle != 0) {
    closeHandle(wakeHandle);
  }

  return RunResult(
    label: config.label,
    mode: config.mode,
    scenario: config.scenario,
    wallMs: wallMs,
    iterations: iterations,
    wakeupsByTimeout: wakeupsByTimeout,
    wakeupsByEvent: wakeupsByEvent,
    wakeupsByMessage: wakeupsByMessage,
    idleWakeups: idleWakeups,
    cpuMs: cpuMs,
    cpuCycles: cpuCycles,
    requestedWaitUs: Stats.fromMicros(requestedWaits),
    nativeWaitUs: Stats.fromMicros(nativeWaits),
    yieldUs: Stats.fromMicros(yieldCosts),
    frameGapUs: Stats.fromMicros(frameGaps),
    messageLatencyUs: Stats.fromMicros(messageLatency),
    frameTicks: frameTicks,
    nominalFrameIntervalUs: frameIntervalUs,
    messagesReceived: messagesReceived,
    threadMigrations: threadMigrations,
  );
}

/// Drains the thread message queue, returning how many messages were handled.
int _drainMessages(Pointer<Msg> message) {
  var handled = 0;
  while (peekMessage(message, nullptr, 0, 0, pmRemove) != 0) {
    handled++;
    translateMessage(message);
    dispatchMessage(message);
  }
  return handled;
}

/// The deadline the proposed `EventLoopDriver.nextDeadline` would report.
///
/// `null` means nothing is scheduled, so an oracle loop may block until it is
/// woken by the event.
int? _nextFrameDeadlineUs({
  required int startUs,
  required int? intervalUs,
  required int nowUs,
}) {
  if (intervalUs == null) {
    return null;
  }
  final elapsed = nowUs - startUs;
  final ticks = elapsed ~/ intervalUs + 1;
  return startUs + ticks * intervalUs;
}

int _timeoutMs({
  required RunConfig config,
  required int nowUs,
  required int endUs,
  required int? nextDeadlineUs,
}) {
  final remainingUs = endUs - nowUs;
  if (remainingUs <= 0) {
    return 0;
  }
  // Every mode is capped by the remaining run time so the harness terminates.
  // This adds at most one extra wakeup per run.
  final capMs = (remainingUs / 1000).ceil();

  return switch (config.mode) {
    LoopMode.baseline => 0,
    LoopMode.spin => 0,
    LoopMode.polling => math.min(config.fixedTimeoutMs ?? 50, capMs),
    LoopMode.oracle => nextDeadlineUs == null
        ? capMs
        : math.min(
            math.max(0, ((nextDeadlineUs - nowUs) / 1000).ceil()),
            capMs,
          ),
  };
}
