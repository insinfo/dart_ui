/// The strongest claim in this directory: a real application, read and operated
/// by a client in another process.
///
/// Everything else here is a step short of the thing itself.
/// `uia_provider_test.dart` checks vtables. `uia_bridge_test.dart` publishes a
/// hand-written tree and reads it back in-process. `uia_session_test.dart`
/// builds real render objects and drives them, still in-process. This file
/// starts `uia_app_host.dart` - an ordinary `dart_ui` application, which does
/// nothing accessibility-specific at all - and points `uia_app_client.dart` at
/// it from a **separate process**.
///
/// That separation is the measurement. An in-process client shares the
/// apartment with the provider, so COM hands its calls straight through and the
/// marshalling `uia_bridge.dart` depends on is never exercised. Narrator, NVDA
/// and Inspect are out-of-process: their calls cross an apartment boundary and
/// are delivered to the provider thread by the application's own message pump.
/// If the apartment were wrong, or `ProviderOptions_UseComThreading` were not
/// returned, or the pump were not running, a `NativeCallable.isolateLocal`
/// would be entered from a foreign thread and the host process would abort -
/// which is what the exit-code assertions below are looking for.
///
/// What the pass covers, end to end and with nothing stubbed:
///
///   * `win32_backend.dart` installs the accessibility host on `initialize`;
///   * `application.dart` registers the window and pumps the tree after each
///     frame;
///   * a `WM_GETOBJECT` from a foreign process activates the provider lazily;
///   * the **control view** - what a screen reader navigates, not the raw view
///     - contains the four controls with the right roles and names;
///   * `Invoke`, `Toggle` and `SetValue` reach the widgets, and the host's own
///     callbacks run;
///   * the changed values come back out through the tree on a later frame.
///
/// It costs a visible window and a few seconds. That is what this claim costs.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

const String _needsWindows =
    'UI Automation is a Windows API; there is no provider side to attach on '
    'Linux or macOS';

/// One process's `prefix: key=value` lines, plus the raw transcript.
typedef _Transcript = ({Map<String, String> values, List<String> lines});

_Transcript _parse(List<String> lines, String prefix) {
  final Map<String, String> values = <String, String>{};
  for (final String line in lines) {
    if (!line.startsWith(prefix)) continue;
    final String body = line.substring(prefix.length);
    final int split = body.indexOf('=');
    if (split < 0) continue;
    values[body.substring(0, split)] = body.substring(split + 1);
  }
  return (values: values, lines: lines);
}

void main() {
  group('a real application, read by another process', () {
    late Process host;
    final List<String> hostLines = <String>[];

    tearDown(() {
      // Belt and braces: the host closes itself when its stdin sees a line and
      // has a 60 second backstop of its own, but a test that failed early must
      // not leave a window on the user's desktop.
      host.kill(ProcessSignal.sigkill);
    });

    test('Narrator\'s own path finds the controls and operates them', () async {
      host = await Process.start(
        Platform.resolvedExecutable,
        <String>['run', 'test/backends/win32/uia/uia_app_host.dart'],
        workingDirectory: Directory.current.path,
      );
      final Completer<void> ready = Completer<void>();
      unawaited(host.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach((String line) {
        hostLines.add(line);
        if (line == 'host: ready' && !ready.isCompleted) ready.complete();
      }));
      final List<String> hostErrors = <String>[];
      unawaited(host.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach(hostErrors.add));

      try {
        await ready.future.timeout(const Duration(seconds: 90));
      } on TimeoutException {
        fail('the host application never reported a window. Reached:\n'
            '${hostLines.join('\n')}\n${hostErrors.join('\n')}');
      }

      final _Transcript hostStart = _parse(hostLines, 'host: ');
      final String? handle = hostStart.values['hwnd'];
      expect(
        handle,
        isNotNull,
        reason: 'the host did not publish a native window handle, so there is '
            'nothing for a client to be pointed at',
      );

      final ProcessResult client = await Process.run(
        Platform.resolvedExecutable,
        <String>[
          'run',
          'test/backends/win32/uia/uia_app_client.dart',
          handle!,
        ],
        workingDirectory: Directory.current.path,
      );
      final List<String> clientLines =
          const LineSplitter().convert(client.stdout as String);
      final String clientTranscript =
          <String>[...clientLines, client.stderr as String].join('\n');

      expect(
        client.exitCode,
        0,
        reason: 'the client exited ${client.exitCode}\n$clientTranscript',
      );
      final _Transcript read = _parse(clientLines, 'client: ');

      // Reached the provider at all. A window with no provider answers
      // ElementFromHandle with the default window element, which has none of
      // the names below.
      expect(read.values['elements'], isNotNull, reason: clientTranscript);

      // Role and name, in the **control view** - the tree a screen reader
      // navigates. The title bar and its three buttons belong to Windows and
      // are in this list too, which is why the assertions name the controls
      // instead of counting them.
      expect(read.values['element[Save].controlType'], '50000'); // Button
      expect(
        read.values['element[Remember me].controlType'],
        '50002', // CheckBox
      );
      expect(read.values['element[Name].controlType'], '50004'); // Edit
      expect(
        clientLines,
        contains('client: element[].controlType=50015'), // Slider, unlabelled
        reason: 'the slider carries no label and is identified by role alone; '
            'a screen reader would announce it as "slider"\n$clientTranscript',
      );

      // Operated, not merely read. Each HRESULT is the client's; each host
      // line under it is the widget's own callback having run in the other
      // process.
      expect(read.values['button.invoke'], startsWith('S_OK'));
      expect(read.values['checkBox.toggleBefore'], '0'); // ToggleState_Off
      expect(read.values['checkBox.toggle'], startsWith('S_OK'));
      expect(read.values['slider.setValue'], startsWith('S_OK'));
      expect(read.values['field.setValue'], startsWith('S_OK'));

      // And the new values came back out through the tree, on a frame the
      // application ran on its own clock. This is the half that proves
      // `application.dart` pumps: without it the widgets would have changed and
      // the client would still be reading the old tree.
      expect(read.values['checkBox.toggleAfter'], '1'); // ToggleState_On
      expect(read.values['slider.valueAfter'], '0.75');
      expect(read.values['field.valueAfter'], 'after');

      // Let the host print its own counters and shut down.
      host.stdin.writeln('go');
      await host.stdin.flush();
      final int hostExit = await host.exitCode
          .timeout(const Duration(seconds: 30), onTimeout: () => -1);

      final _Transcript hostEnd = _parse(hostLines, 'host: ');
      expect(
        hostExit,
        0,
        reason: 'a non-zero host exit is the measurement this test exists for: '
            'an abort means UI Automation called the provider from a foreign '
            'thread despite the apartment and '
            'ProviderOptions_UseComThreading.\n${hostLines.join('\n')}\n'
            '${hostErrors.join('\n')}',
      );
      expect(
        hostEnd.values['presses'],
        '1',
        reason: 'the client\'s Invoke did not reach the button\'s onPressed - '
            'the same callback a mouse click and the space bar '
            'reach\n${hostLines.join('\n')}',
      );
      expect(hostEnd.values['checked'], 'true');
      expect(hostEnd.values['slider'], '0.75');
      expect(hostEnd.values['text'], 'after');
      expect(
        hostErrors,
        isEmpty,
        reason: 'the host reported errors on stderr',
      );
    }, timeout: const Timeout(Duration(minutes: 5)));
  }, skip: Platform.isWindows ? null : _needsWindows);
}
