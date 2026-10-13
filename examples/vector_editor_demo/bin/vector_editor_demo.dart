/// The vector editor (100% Dart).
///
/// ```
/// dart run bin/vector_editor_demo.dart [drawing.svg|drawing.cdr] [--control <port>]
/// ```
///
/// `--control <port>` opens the control channel on `127.0.0.1:<port>`: JSON
/// requests, one per line, that run any command, read the menus and the
/// document, drive the pointer and the keyboard and take screenshots - see
/// `doc/vector_editor_arquitetura.md` and `package:dart_ui/automation.dart`.
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_ui/automation.dart';
import 'package:dart_ui/dart_ui.dart';
import 'package:vector_editor_demo/src/engine/editor_files.dart';
import 'package:vector_editor_demo/src/engine/editor_inspect.dart';
import 'package:vector_editor_demo/src/ui/app.dart';
import 'package:vector_editor_demo/src/ui/main_window.dart';

Future<void> main(List<String> arguments) async {
  FrameworkFonts.install();
  FontRegistry.warmSystemFonts();

  final int? controlPort = _controlPort(arguments);
  final options = ApplicationOptions.fromArguments(
    arguments,
    environment: Platform.environment,
    title: 'Vector Editor (100% Pure Dart)',
    size: const Size(1400, 880),
    minimumSize: const Size(960, 600),
  );

  VectorDocument? initialDoc;
  String? initialName;
  for (final String argument in _files(arguments)) {
    try {
      initialDoc = readDrawing(argument, File(argument).readAsBytesSync());
      initialName = basenameOf(argument);
    } on Object catch (error) {
      stderr.writeln('Could not read $argument: $error');
    }
    break;
  }

  final Completer<MainWindowState> ready = Completer<MainWindowState>();
  await runApp(
    VectorEditorApp(
      initialDoc: initialDoc,
      initialName: initialName,
      onReady: ready.complete,
    ),
    options: options,
    onStarted: controlPort == null
        ? null
        // The window mounts - and registers its commands - on its first
        // frame, which needs the event loop this callback runs before; so
        // the channel opens once it is ready, without holding the loop up.
        : (Application app) => unawaited(ready.future.then(
              (MainWindowState window) => _serve(app, window, controlPort),
            )),
  );
}

/// The port after `--control` (or in `--control=<port>`), or null.
int? _controlPort(List<String> arguments) {
  for (var i = 0; i < arguments.length; i++) {
    final String argument = arguments[i];
    final String? value = argument.startsWith('--control=')
        ? argument.substring('--control='.length)
        : argument == '--control' && i + 1 < arguments.length
            ? arguments[i + 1]
            : null;
    if (value == null) continue;
    final int? port = int.tryParse(value);
    if (port == null || port < 0 || port > 65535) {
      stderr.writeln('--control takes a port number; got "$value"');
      exit(64);
    }
    return port;
  }
  return null;
}

/// The arguments that name files: not flags, and not a flag's value.
Iterable<String> _files(List<String> arguments) sync* {
  for (var i = 0; i < arguments.length; i++) {
    final String argument = arguments[i];
    if (argument == '--control') {
      i++;
      continue;
    }
    if (argument.startsWith('--')) continue;
    if (File(argument).existsSync()) yield argument;
  }
}

Future<void> _serve(Application app, MainWindowState window, int port) async {
  try {
    final ControlServer server = await ControlServer.start(
      port: port,
      host: WindowAutomation(
        application: app,
        window: app.primaryWindow,
        registry: window.registry,
        menus: () => window.menus.bar,
        contextMenu: () => window.menus.canvas,
        inspect: () => inspectEditor(window.model),
        document: () => inspectDocument(window.model),
      ),
    );
    stderr.writeln('control channel on 127.0.0.1:${server.port}');
  } on SocketException catch (error) {
    stderr.writeln('could not open the control channel on port $port: '
        '${error.message}');
  }
}
