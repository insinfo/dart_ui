import 'dart:async';
import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/macos/macos.dart';

Future<void> main() async {
  if (!Platform.isMacOS) {
    stderr.writeln(
        'MACOS_BACKEND_FACADE_SMOKE=SKIP platform=${Platform.operatingSystem}');
    exitCode = 2;
    return;
  }

  final hostPath = Platform.environment['DART_UI_MACOS_HOST'];
  if (hostPath == null || hostPath.isEmpty) {
    throw StateError('DART_UI_MACOS_HOST must name the production host');
  }

  final backend = MacosWindowingBackend(
    options: MacosBackendOptions(
      requested: MacosBackendKind.appkitNativeHost,
      hostBinaryPath: hostPath,
    ),
  );
  NativeWindow? window;
  Object? failure;
  StackTrace? failureStack;

  try {
    final probe = backend.probe();
    stdout.writeln('MACOS_BACKEND_PROBE=${probe.supported ? 'PASS' : 'FAIL'}');
    if (!probe.supported) {
      throw StateError(probe.describe());
    }

    await backend.initialize().timeout(const Duration(seconds: 10));
    window = await backend
        .createWindow(
          const WindowOptions(
            size: Size(320, 200),
            title: 'dart_ui production backend smoke',
            visible: false,
          ),
        )
        .timeout(const Duration(seconds: 20));
    if (backend.windows.length != 1 || window.surfaces.isEmpty) {
      throw StateError(
        'facade did not retain one window with a presentation surface',
      );
    }
    stdout.writeln('MACOS_BACKEND_WINDOW=PASS id=${window.id.value}');
  } on Object catch (error, stack) {
    failure = error;
    failureStack = stack;
  }

  try {
    await backend.shutdown().timeout(const Duration(seconds: 15));
    final createdWindow = window;
    if (createdWindow is MacosWindow) {
      await createdWindow.teardown.timeout(const Duration(seconds: 15));
    }
    if (backend.windows.isNotEmpty) {
      throw StateError('facade retained windows after shutdown');
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
  stdout.writeln('MACOS_BACKEND_FACADE_SMOKE=PASS');
}
