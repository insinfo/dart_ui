import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/x11/x11_backend.dart';

Future<void> main() async {
  if (!Platform.isLinux) {
    stderr.writeln(
      'X11_BACKEND_SMOKE=SKIP platform=${Platform.operatingSystem}',
    );
    exitCode = 2;
    return;
  }

  final backend = X11WindowingBackend();
  NativeWindow? window;
  Object? failure;
  StackTrace? failureStack;

  try {
    final probe = backend.probe();
    final probePassed = probe.supported &&
        probe.supports(Capability.window) &&
        !probe.supports(Capability.cpuPresentation);
    stdout.writeln(
      'X11_BACKEND_PROBE=${probePassed ? 'PASS' : 'FAIL'} '
      'supported=${probe.supported} window=true cpu=false',
    );
    if (!probePassed) {
      throw StateError(probe.describe());
    }

    await backend.initialize().timeout(const Duration(seconds: 10));
    window = await backend
        .createWindow(
          const WindowOptions(
            size: Size(320, 200),
            title: 'dart_ui X11 production smoke',
          ),
        )
        .timeout(const Duration(seconds: 10));
    var exposed = false;
    var resized = false;
    final subscription = window.events.listen((event) {
      exposed |= event is WindowExposedEvent;
      resized |= event is WindowResizedEvent;
    });
    try {
      await _pumpUntil(
        backend,
        () => exposed,
        const Duration(seconds: 5),
        'Expose',
      );
      window.setBounds(const Rect.fromLTWH(10, 12, 360, 240));
      await _pumpUntil(
        backend,
        () => resized,
        const Duration(seconds: 5),
        'ConfigureNotify',
      );
    } finally {
      await subscription.cancel();
    }
    stdout.writeln('X11_BACKEND_WINDOW=PASS id=${window.id.value}');
    window.close();
    if (backend.windows.isNotEmpty || backend.pumpEvents()) {
      throw StateError('closing the final X11 window did not request quit');
    }
    backend.wake();
  } on Object catch (error, stack) {
    failure = error;
    failureStack = stack;
  }

  try {
    await backend.shutdown().timeout(const Duration(seconds: 10));
    if (backend.windows.isNotEmpty) {
      throw StateError('X11 backend retained windows after shutdown');
    }
  } on Object catch (error, stack) {
    failure ??= error;
    failureStack ??= stack;
  }

  final capturedFailure = failure;
  if (capturedFailure != null) {
    Error.throwWithStackTrace(
      capturedFailure,
      failureStack ?? StackTrace.current,
    );
  }
  stdout.writeln('X11_BACKEND_SMOKE=PASS');
}

Future<void> _pumpUntil(
  X11WindowingBackend backend,
  bool Function() predicate,
  Duration timeout,
  String eventName,
) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate() && DateTime.now().isBefore(deadline)) {
    backend.pumpEvents(timeout: const Duration(milliseconds: 25));
    await Future<void>.delayed(Duration.zero);
  }
  if (!predicate()) throw StateError('timed out waiting for $eventName');
}
