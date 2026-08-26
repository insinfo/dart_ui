/// A real `dart_ui` application, running, for another process to read.
///
/// **Not a test file** - no `_test` suffix. `uia_app_test.dart` starts this as
/// a subprocess, reads the HWND it prints, starts `uia_app_client.dart` against
/// that HWND, and asserts on what both of them say.
///
/// ## Why two processes
///
/// This is the only arrangement in which the measurement is the real one.
/// Narrator, NVDA and Inspect are **out-of-process** UI Automation clients:
/// their calls arrive at a provider through COM's cross-apartment marshalling
/// and are delivered on the provider thread by its own message pump. An
/// in-process client - which is what `uia_widget_probe.dart` is - exercises the
/// same interfaces without ever crossing that boundary, so it cannot tell you
/// whether the boundary works.
///
/// Everything the provider needs in order to survive that crossing is claimed
/// by `uia_bridge.dart` and was, until this file, unverified: the
/// single-threaded apartment, `ProviderOptions_UseComThreading`, and a message
/// pump that keeps running while a client is asking. If any of the three were
/// wrong, a `NativeCallable.isolateLocal` would be entered from a foreign
/// thread and this process would abort - which is why it is a process and not
/// a test.
///
/// ## What it does not do
///
/// It does not attach a provider, register a window with
/// [WindowsAccessibility], or pump a semantic tree. Every one of those is done
/// by `lib/` - `win32_backend.dart` installs the host, `application.dart`
/// registers the window and pumps it after each frame - and this file's silence
/// on the subject is the point: what the client finds is what an ordinary
/// application publishes.
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_ui/dart_ui.dart';

void _say(String message) => print('host: $message');

/// How long the window stays up if the client never signals it is done.
const Duration _lifetime = Duration(seconds: 60);

int _presses = 0;
bool _checked = false;
double _slider = 0.25;

void main(List<String> args) async {
  if (!Platform.isWindows) {
    _say('skipped: not Windows');
    return;
  }
  final String title = 'dart_ui UIA app host $pid';
  final TextEditingController controller = TextEditingController('before');

  final Application app = await Application.start(
    rootWidget: _Form(controller: controller),
    backends: PlatformBackendResolver.defaultBackends(),
    presentations: PlatformBackendResolver.defaultPresentations(),
    options: ApplicationOptions(
      title: title,
      size: const Size(420, 360),
      // Shown: a window an assistive client is asked about should be one a
      // user could be looking at, and a hidden window is a different code path
      // in the client.
      visible: true,
      onError: (FrameworkError error) => _say('error: $error'),
    ),
  );

  final NativeWindow window = app.window;
  if (window is! NativeHandleWindow) {
    _say('failed: this backend has no native handle to publish');
    exit(2);
  }
  _say('hwnd=${(window as NativeHandleWindow).nativeHandle}');
  _say('title=$title');
  _say('ready');

  // The client prints `client: done` and exits; the parent test then closes
  // this process. The timer is the backstop for a client that died first, so
  // an abandoned window never outlives the run.
  Timer(_lifetime, () {
    _say('lifetime expired');
    app.requestClose();
  });

  // stdin is how the parent says "you can go": one line, any line. Reading it
  // rather than waiting on a signal because Windows has no SIGTERM worth the
  // name and killing the process would lose the counters below.
  unawaited(stdin.first.then((_) {
    _say('presses=$_presses');
    _say('checked=$_checked');
    _say('slider=${_slider.toStringAsFixed(2)}');
    _say('text=${controller.value}');
    _say('done');
    app.requestClose();
  }).catchError((Object _) {}));

  await app.run();
  await app.closed;
  exit(0);
}

final class _Form extends StatefulWidget {
  const _Form({required this.controller});

  final TextEditingController controller;

  @override
  State<_Form> createState() => _FormState();
}

final class _FormState extends State<_Form> {
  @override
  Widget build(BuildContext context) => Column(
        children: <Widget>[
          Button(
            label: 'Save',
            onPressed: () {
              _presses++;
              // Printed as it happens, so a transcript shows the client's
              // Invoke and the widget's reaction in order rather than only in
              // a total at the end.
              _say('pressed=$_presses');
              setState(() {});
            },
          ),
          CheckBox(
            label: 'Remember me',
            value: _checked,
            onChanged: (bool value) => setState(() {
              _checked = value;
              _say('toggled=$value');
            }),
          ),
          Slider(
            value: _slider,
            step: 0.05,
            onChanged: (double value) => setState(() {
              _slider = value;
              _say('slid=${value.toStringAsFixed(2)}');
            }),
          ),
          TextField(controller: widget.controller, label: 'Name'),
        ],
      );
}
