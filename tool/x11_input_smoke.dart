/// Proves X11 keys reach a real text field, under a real X server.
///
/// Until 12/10/2026 the X11 and Wayland backends put the keysym in
/// `KeyEvent.logicalKey`, and the widgets compare against Windows virtual-key
/// codes: Tab, the arrows, Home, Delete and Ctrl+C reached a `TextField` that
/// matched none of them, and only typing - which travels as text - worked.
/// `x11_text_field_keys_test.dart` composes the two halves from bytes; this
/// is the same claim against Xvfb, with the keys injected by `xdotool` through
/// XTEST - the server's own input path, not a SendEvent the backend could
/// treat differently - and the clipboard read back by `xclip`, which is
/// another X client and the only witness that does not share our code.
///
/// ```
/// Xvfb :99 & DISPLAY=:99 dart run tool/x11_input_smoke.dart
/// ```
///
/// Exits 0 on `X11_INPUT_SMOKE=PASS`, 1 on `=FAIL`, and 2 when there is no
/// display, no `xdotool` or no `xclip` - the convention of the other X11
/// smokes, so CI can tell "this machine cannot" from "this build is broken".
library;

import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/x11/x11_window.dart';

Future<void> main() async {
  if (!Platform.isLinux || (Platform.environment['DISPLAY'] ?? '').isEmpty) {
    stderr.writeln('X11_INPUT_SMOKE=SKIP needs Linux with a DISPLAY');
    exitCode = 2;
    return;
  }
  for (final String tool in const <String>['xdotool', 'xclip']) {
    if ((await Process.run('which', <String>[tool])).exitCode != 0) {
      stderr.writeln('X11_INPUT_SMOKE=SKIP $tool is not installed');
      exitCode = 2;
      return;
    }
  }

  var verdict = 'PASS';
  var reason = '';
  void record(String key, bool passed, String detail) {
    stdout.writeln('$key=${passed ? 'PASS' : 'FAIL'} $detail');
    if (!passed && verdict == 'PASS') {
      verdict = 'FAIL';
      reason = key;
    }
  }

  final controller = TextEditingController();
  var presses = 0;
  Application? application;
  try {
    application = await Application.start(
      rootWidget: Column(
        children: <Widget>[
          SizedBox(
            width: 280,
            height: 40,
            child: TextField(controller: controller, label: 'name'),
          ),
          SizedBox(
            width: 280,
            height: 40,
            child: Button(label: 'press', onPressed: () => presses++),
          ),
        ],
      ),
      backends: PlatformBackendResolver.defaultBackends(),
      presentations: PlatformBackendResolver.defaultPresentations(),
      options: ApplicationOptions(
        title: 'dart_ui x11 input smoke',
        size: const Size(320, 120),
        environment: Platform.environment,
      ),
    );
    final Application app = application;
    final NativeWindow native = app.primaryWindow.nativeWindow;
    stdout.writeln('X11_INPUT_BACKEND backend=${app.backend.name} '
        'window=${native.runtimeType}');
    if (native is! X11Window) {
      record('X11_INPUT_SMOKE', false, 'the window is ${native.runtimeType}');
      return;
    }
    // Shown by hand: this smoke pumps instead of calling Application.run,
    // which is what would show the primary window.
    native.show();
    await _pump(app, const Duration(milliseconds: 500));
    final String xid = '${native.xcbWindow}';

    Future<String> xdotool(List<String> arguments) async {
      final ProcessResult result = await Process.run('xdotool', arguments);
      await _pump(app, const Duration(milliseconds: 250));
      return '${result.exitCode}${(result.stderr as String).trim()}';
    }

    final String focus = await xdotool(<String>['windowfocus', '--sync', xid]);
    stdout.writeln('X11_INPUT_FOCUS xid=$xid xdotool=$focus');

    // --- a click on the button -------------------------------------------
    await xdotool(<String>['mousemove', '--window', xid, '140', '60']);
    await xdotool(<String>['click', '1']);
    record('X11_INPUT_CLICK', presses == 1, 'presses=$presses');

    // --- typing into the field -------------------------------------------
    await xdotool(<String>['mousemove', '--window', xid, '140', '20']);
    await xdotool(<String>['click', '1']);
    await xdotool(<String>['type', '--delay', '40', 'hello']);
    record('X11_INPUT_TYPING', controller.value == 'hello',
        'value="${controller.value}"');

    // --- keys that are not text: these are the ones that used to vanish ---
    await xdotool(<String>['key', '--delay', '40', 'Home', 'Delete']);
    record('X11_INPUT_NAVIGATION', controller.value == 'ello',
        'value="${controller.value}" after Home, Delete');

    // --- Ctrl+A, Ctrl+C, read back by another X client --------------------
    await xdotool(<String>['key', '--delay', '40', 'ctrl+a', 'ctrl+c']);
    await _pump(app, const Duration(milliseconds: 300));
    // xclip asks this process for the selection and waits for the answer,
    // which is served from this process's own event handling - so it runs
    // while the application pumps, not while this function waits on it.
    final Process xclip = await Process.start(
      'xclip',
      const <String>['-o', '-selection', 'clipboard'],
    );
    final Future<String> clipText =
        xclip.stdout.transform(const SystemEncoding().decoder).join();
    var clipDone = false;
    final Future<int> clipExit = xclip.exitCode..then((_) => clipDone = true);
    final DateTime clipDeadline =
        DateTime.now().add(const Duration(seconds: 5));
    while (!clipDone && DateTime.now().isBefore(clipDeadline)) {
      await _pump(app, const Duration(milliseconds: 50));
    }
    if (!clipDone) xclip.kill();
    final int clipCode = await clipExit;
    final String clipped = await clipText;
    record(
        'X11_INPUT_COPY', clipped == 'ello', 'xclip="$clipped" exit=$clipCode');

    // --- End, Ctrl+V: our own selection, read back through the server ------
    await xdotool(<String>['key', '--delay', '40', 'End', 'ctrl+v']);
    await _pump(app, const Duration(milliseconds: 500));
    record('X11_INPUT_PASTE', controller.value == 'elloello',
        'value="${controller.value}"');
  } on Object catch (error, stackTrace) {
    stderr
      ..writeln('X11_INPUT_SMOKE threw: $error')
      ..writeln(stackTrace);
    verdict = 'FAIL';
    if (reason.isEmpty) reason = 'threw ${error.runtimeType}';
  } finally {
    final Application? app = application;
    if (app != null) {
      app.dispose();
      await app.closed;
    }
  }

  stdout.writeln(
      'X11_INPUT_SMOKE=$verdict${verdict == 'PASS' ? '' : ' $reason'}');
  exitCode = verdict == 'PASS' ? 0 : 1;
}

Future<void> _pump(Application app, Duration duration) async {
  final DateTime deadline = DateTime.now().add(duration);
  while (DateTime.now().isBefore(deadline)) {
    if (app.isDisposed) return;
    if (!app.backend.pumpEvents(timeout: const Duration(milliseconds: 4))) {
      return;
    }
    await Future<void>.delayed(Duration.zero);
    app.requestFrame();
    await app.drawPendingFrames();
  }
}
