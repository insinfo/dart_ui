/// The process ends with the application's last window, as a desktop
/// application's does.
///
/// A Dart process ends when its main isolate has nothing left to wait for: no
/// timer, no stream subscription on a socket, a file watcher or a child
/// process, no open port. The framework releases everything it opened when the
/// last window closes, so a process whose application did the same ends on
/// its own the moment `runApp` returns. One that left something open - a
/// `Directory.watch` nobody cancelled, an isolate still decoding - would
/// otherwise sit in the terminal with no window, which is the bug a user sees
/// as "closing the window does not end the program".
///
/// Flutter's desktop runners do not have this problem to solve: their native
/// `main` returns when the window is destroyed and the engine is torn down
/// with whatever the Dart side still held. This is the same contract, reached
/// without killing anybody's teardown: [endProcessWithLastWindow] starts a
/// watchdog **isolate** that calls `exit` after [kProcessEndGrace]. A spawned
/// isolate does not keep the process alive - the VM ends with the main isolate
/// - so a process that ends on its own is never delayed by it, and code after
/// `await runApp(...)` (a summary, an `await model.dispose()`) still runs.
library;

import 'dart:async';
import 'dart:io' show exit, exitCode;
import 'dart:isolate';

import '../app/application.dart';
import 'headless/headless_backend.dart';

/// How long the process may outlive its last window before it is ended.
///
/// Long enough for the orderly cleanup an application does after `runApp`
/// returns, short enough that a user who closed the window never notices.
const Duration kProcessEndGrace = Duration(seconds: 1);

Isolate? _watchdog;
int _armed = 0;

/// Makes sure the process ends soon after [application] did, when it ended
/// because its last top-level window was closed
/// ([Application.endedWithLastWindow]).
///
/// Does nothing for any other end (a frame budget, a direct
/// [Application.requestClose]) and nothing on the headless backend, whose
/// applications run inside test processes that must outlive them. Returns
/// whether the watchdog was armed.
bool endProcessWithLastWindow(
  Application application, {
  Duration grace = kProcessEndGrace,
}) {
  if (!application.endedWithLastWindow) return false;
  if (application.backend is HeadlessWindowingBackend) return false;
  cancelProcessEnd();
  final int armed = ++_armed;
  unawaited(Isolate.spawn<int>(
    _endProcessAfter,
    grace.inMilliseconds,
    debugName: 'dart_ui process end',
  ).then((Isolate isolate) {
    // A new application started while the watchdog was being spawned.
    if (armed != _armed) {
      isolate.kill(priority: Isolate.immediate);
    } else {
      _watchdog = isolate;
    }
  }, onError: (Object _) {}));
  return true;
}

/// Disarms [endProcessWithLastWindow]: another application is starting, so
/// the process has more to do than end.
void cancelProcessEnd() {
  _armed++;
  _watchdog?.kill(priority: Isolate.immediate);
  _watchdog = null;
}

void _endProcessAfter(int milliseconds) {
  Timer(Duration(milliseconds: milliseconds), () => exit(exitCode));
}
