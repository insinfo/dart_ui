/// Closing the last window ends the application *and lets the process end*.
///
/// The bug this pins: the file explorer's window closed on macOS and the
/// terminal stayed blocked, because something was still open after `runApp`
/// returned. A Dart isolate ends exactly when nothing it owns can deliver an
/// event any more - no timer, no subscription, no port - so the test runs the
/// whole application inside a spawned isolate and waits for that isolate to
/// end on its own. A timer or a subscription the framework forgot to release
/// keeps it alive, and the test times out instead of passing.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/process_end_io.dart';
import 'package:test/test.dart';

const List<WindowingBackendEntry> _headless = <WindowingBackendEntry>[
  WindowingBackendEntry(name: 'headless', create: HeadlessWindowingBackend.new),
];

/// The user's close button on the last window, once the loop is running.
void _closeSoon(Application app) {
  Timer(const Duration(milliseconds: 20), () {
    final ApplicationWindow window = app.primaryWindow;
    app.handleEvent(WindowCloseRequestedEvent(
      windowId: window.id,
      generation: window.nativeWindow.generation,
    ));
  });
}

/// Runs in its own isolate: the application from start to the close of its
/// last window, then a report of how it ended. Returning is all it does
/// after that - whether the isolate then *ends* is the test.
Future<void> _runAndCloseLastWindow(SendPort report) async {
  final Application app = await runApp(
    const SizedBox(width: 8, height: 8),
    backends: _headless,
    options: const ApplicationOptions(size: Size(8, 8)),
    onStarted: _closeSoon,
  );
  report.send(<String, Object?>{
    'state': app.state.name,
    'endedWithLastWindow': app.endedWithLastWindow,
    'teardown': app.teardownOrder,
    'errors': app.errors.length,
    'processEndArmed': endProcessWithLastWindow(app),
  });
}

/// The same, with one timer of its own left running - the shape of the
/// explorer's file watcher. It proves the check below can fail.
Future<void> _runAndLeakATimer(SendPort report) async {
  Timer.periodic(const Duration(milliseconds: 50), (_) {});
  await runApp(
    const SizedBox(width: 8, height: 8),
    backends: _headless,
    options: const ApplicationOptions(size: Size(8, 8)),
    onStarted: _closeSoon,
  );
  report.send(<String, Object?>{});
}

/// Spawns [entry]; completes with its report and whether the isolate ended by
/// itself within [patience] of sending it.
Future<(Map<String, Object?>, bool)> _spawn(
  Future<void> Function(SendPort report) entry, {
  Duration patience = const Duration(seconds: 10),
}) async {
  final ReceivePort reports = ReceivePort();
  final ReceivePort exits = ReceivePort();
  final ReceivePort errors = ReceivePort();
  final Isolate isolate = await Isolate.spawn<SendPort>(
    entry,
    reports.sendPort,
    onExit: exits.sendPort,
    onError: errors.sendPort,
  );
  final Completer<void> exited = Completer<void>();
  exits.listen((_) {
    if (!exited.isCompleted) exited.complete();
  });
  errors.listen((Object? error) {
    if (!exited.isCompleted) exited.completeError(StateError('$error'));
  });
  try {
    final Map<String, Object?> report = await reports.first
        .timeout(const Duration(seconds: 30)) as Map<String, Object?>;
    final bool ended = await exited.future
        .then((_) => true)
        .timeout(patience, onTimeout: () => false);
    return (report, ended);
  } finally {
    isolate.kill(priority: Isolate.immediate);
    reports.close();
    exits.close();
    errors.close();
  }
}

void main() {
  test(
      'closing the last window ends run(), tears down, and leaves nothing '
      'that keeps the isolate alive', () async {
    final (Map<String, Object?> report, bool ended) =
        await _spawn(_runAndCloseLastWindow);

    expect(report['state'], ApplicationLifecycleState.closed.name);
    expect(report['endedWithLastWindow'], isTrue);
    expect(report['errors'], 0);
    expect(
        report['teardown'], containsAllInOrder(<String>['window', 'backend']));
    expect(report['processEndArmed'], isFalse,
        reason: 'the headless backend runs inside test processes, which must '
            'outlive their applications');
    expect(ended, isTrue,
        reason: 'a timer, a subscription or a port the framework opened was '
            'still alive after runApp returned');
  });

  test('an application resource left open does keep it alive', () async {
    final (_, bool ended) = await _spawn(
      _runAndLeakATimer,
      patience: const Duration(milliseconds: 500),
    );
    expect(ended, isFalse);
  });

  test('a frame budget or a direct requestClose is not the last window',
      () async {
    final Application budgeted = await runApp(
      const SizedBox(width: 8, height: 8),
      backends: _headless,
      options: const ApplicationOptions(size: Size(8, 8), frameBudget: 2),
    );
    expect(budgeted.endedWithLastWindow, isFalse);
    expect(endProcessWithLastWindow(budgeted), isFalse);

    final Application closed = await runApp(
      const SizedBox(width: 8, height: 8),
      backends: _headless,
      options: const ApplicationOptions(size: Size(8, 8)),
      onStarted: (Application app) {
        Timer(const Duration(milliseconds: 20), app.requestClose);
      },
    );
    expect(closed.state, ApplicationLifecycleState.closed);
    expect(closed.endedWithLastWindow, isFalse);
  });

  test('closing a window that is not the last one is not the end', () async {
    final Application app = await Application.start(
      rootWidget: const SizedBox(width: 8, height: 8),
      backends: _headless,
      options: const ApplicationOptions(size: Size(8, 8)),
    );
    final ApplicationWindow second = await app.openWindow(
      rootWidget: const SizedBox(width: 8, height: 8),
      size: const Size(8, 8),
    );
    app.handleEvent(WindowCloseRequestedEvent(
      windowId: second.id,
      generation: second.nativeWindow.generation,
    ));
    expect(app.endedWithLastWindow, isFalse);
    expect(app.state, isNot(ApplicationLifecycleState.closing));

    final ApplicationWindow first = app.primaryWindow;
    app.handleEvent(WindowCloseRequestedEvent(
      windowId: first.id,
      generation: first.nativeWindow.generation,
    ));
    expect(app.endedWithLastWindow, isTrue);
    expect(app.state, ApplicationLifecycleState.closing);
    app.dispose();
    await app.closed;
  });
}
