import 'dart:io';

import 'package:dart_ui/dart_ui.dart' show DiagnosticKind;
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
  Object? failure;
  StackTrace? failureStack;

  try {
    final probe = backend.probe();
    final deferred = !probe.supported &&
        probe.diagnostics.any(
          (item) => item.kind == DiagnosticKind.rejectedByPolicy,
        );
    final hardFailures = probe.failures
        .where((item) => item.kind != DiagnosticKind.rejectedByPolicy)
        .toList();
    final probePassed = deferred && hardFailures.isEmpty;
    stdout.writeln(
      'X11_BACKEND_PROBE=${probePassed ? 'PASS' : 'FAIL'} '
      'supported=${probe.supported} deferred=createWindow',
    );
    if (!probePassed) {
      throw StateError(probe.describe());
    }

    await backend.initialize().timeout(const Duration(seconds: 10));
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
