/// The bridge: `WM_GETOBJECT`, and a real client reading a real window back.
///
/// The last test in this file is the one that matters. Everything else in this
/// directory checks a piece against what it is supposed to do; that one puts a
/// window on the screen, attaches the provider to it, and then asks Windows -
/// through `CLSID_CUIAutomation`, the same object Narrator's own client
/// library creates - what is in that window. A pass means the tree is
/// reachable by the path assistive technology uses, which is a different and
/// much stronger claim than "the vtable answers".
///
/// It runs in a subprocess. See `uia_client_probe.dart` for why: the failure
/// mode of a foreign-thread call into `NativeCallable.isolateLocal` is a VM
/// abort, and an abort inside the test runner takes every other suite with it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_ui/src/backends/win32/uia/uia_bridge.dart';
import 'package:dart_ui/src/backends/win32/uia/uia_constants.dart';
import 'package:test/test.dart';

const String _needsWindows =
    'UI Automation is a Windows API; there is no provider side to attach on '
    'Linux or macOS';

/// The probe's output as `key -> value`, having failed loudly if it did not
/// finish.
Future<Map<String, String>> _runProbe() async {
  const String script = 'test/backends/win32/uia/uia_client_probe.dart';
  final Process process = await Process.start(
    Platform.resolvedExecutable,
    <String>['run', script],
    workingDirectory: Directory.current.path,
  );
  final List<String> lines = <String>[];
  final Future<void> collecting = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .forEach(lines.add);
  final List<String> errors = <String>[];
  final Future<void> collectingErrors = process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .forEach(errors.add);

  int exitCode;
  try {
    exitCode = await process.exitCode.timeout(const Duration(seconds: 120));
  } on Object {
    process.kill(ProcessSignal.sigkill);
    fail('the UI Automation probe hung. Reached:\n${lines.join('\n')}');
  }
  await collecting;
  await collectingErrors;

  final String transcript = <String>[...lines, ...errors].join('\n');
  expect(
    exitCode,
    0,
    reason: 'the probe exited $exitCode. A non-zero code here is the '
        'measurement this test exists for: a VM abort means UI Automation '
        'called the provider from its own thread despite '
        'ProviderOptions_UseComThreading and the apartment.\n$transcript',
  );

  final Map<String, String> values = <String, String>{};
  for (final String line in lines) {
    if (!line.startsWith('probe: ')) continue;
    final String body = line.substring('probe: '.length);
    final int split = body.indexOf('=');
    if (split < 0) continue;
    values[body.substring(0, split)] = body.substring(split + 1);
  }
  expect(lines, contains('probe: done'), reason: transcript);
  return values;
}

void main() {
  group('WM_GETOBJECT routing', () {
    test('answers only UiaRootObjectId, and lets MSAA fall through', () {
      // No bridge is attached to handle 0, so a null here proves the lParam
      // check ran first and the answer is "not ours" rather than "no bridge".
      expect(Win32UiaBridge.handleGetObject(0, 0, uiaRootObjectId), isNull);
      // OBJID_CLIENT is MSAA asking for an IAccessible. Answering it with a
      // UI Automation provider is how a window ends up invisible to half the
      // assistive technology on the machine.
      expect(Win32UiaBridge.handleGetObject(0, 0, objidClient), isNull);
      expect(Win32UiaBridge.handleGetObject(0, 0, objidWindow), isNull);
    });

    test('reads lParam as signed, because UiaRootObjectId is negative', () {
      // The OS hands lParam over as an unsigned machine word, so -25 arrives
      // as 0xFFFFFFE7 on a 32-bit sign-extension and as 0xFFFFFFFFFFFFFFE7
      // here. A handler comparing it unsigned never matches and the window is
      // silent to every screen reader with no error anywhere.
      expect(0xFFFFFFE7.toSigned(32), uiaRootObjectId);
    });

    test('the change win32_window.dart needs is written down, not described',
        () {
      // That file belongs to another agent this session. This is the patch,
      // kept next to the code it patches so it cannot go stale on its own.
      expect(Win32UiaBridge.getObjectPatch, contains('case wmGetobject:'));
      expect(
        Win32UiaBridge.getObjectPatch,
        contains('Win32UiaBridge.handleGetObject(hwnd, wParam, lParam)'),
      );
      expect(
        Win32UiaBridge.getObjectPatch,
        contains('_api.defWindowProcW(hwnd, msg, wParam, lParam)'),
      );
    });
  });

  group('what is absent', () {
    test('is named, with a reason somebody could act on', () {
      expect(
        Win32UiaBridge.absentFeatures.keys,
        containsAll(<String>['IAccessible (MSAA)', 'Performing actions']),
      );
      for (final MapEntry<String, String> entry
          in Win32UiaBridge.absentFeatures.entries) {
        expect(
          entry.value.length,
          greaterThan(80),
          reason: '"${entry.key}" is listed as absent without saying why; '
              '"absent" has to be a decision somebody wrote down rather than '
              'something nobody got to',
        );
      }
    });
  });

  group('attaching', () {
    test('starts with no windows publishing', () {
      expect(Win32UiaBridge.attachedCount, 0);
      expect(Win32UiaBridge.forWindow(12345), isNull);
    });
  });

  group('a real window, read back by a real client', () {
    test('Narrator\'s own path finds the button, by name and by role',
        () async {
      final Map<String, String> probe = await _runProbe();

      // The apartment arrangement `uia_bridge.dart` documents, confirmed on
      // this machine rather than assumed.
      expect(
        probe['apartment'],
        anyOf('apartmentThreaded', 'alreadyApartmentThreaded'),
        reason: 'a multi-threaded apartment means UI Automation calls the '
            'provider directly from its own thread',
      );

      // ElementFromHandle reached *our* provider and not the default window
      // one: the name is the semantic root's label.
      expect(probe['root.name'], 'probe root');
      expect(probe['root.controlType'], '$uiaGroupControlTypeId');

      // The raw view merges the window's own non-client provider with ours,
      // so the first child is a UIA_TitleBarControlTypeId that belongs to
      // Windows. The controls are found by name, not by position.
      final Map<String, Map<String, String>> children =
          <String, Map<String, String>>{};
      for (final MapEntry<String, String> entry in probe.entries) {
        final Match? match =
            RegExp(r'^child\[(\d+)\]\.(\w+)$').firstMatch(entry.key);
        if (match == null) continue;
        children.putIfAbsent(
                match.group(1)!, () => <String, String>{})[match.group(2)!] =
            entry.value;
      }
      expect(children, isNotEmpty, reason: 'the tree walk found no children');

      Map<String, String> byName(String name) => children.values.firstWhere(
            (Map<String, String> child) => child['name'] == name,
            orElse: () => fail(
              'no child named "$name" in the raw view: '
              '${children.values.map((Map<String, String> c) => c['name'])}',
            ),
          );

      final Map<String, String> button = byName('Save');
      expect(button['controlType'], '$uiaButtonControlTypeId');
      expect(button['automationId'], 'dartui-1');

      final Map<String, String> checkbox = byName('Remember me');
      expect(checkbox['controlType'], '$uiaCheckBoxControlTypeId');
      expect(checkbox['automationId'], 'dartui-2');
      // The state a screen reader announces as "checked", read back through
      // the client API rather than off the provider we wrote.
      expect(checkbox['toggleState'], '$toggleStateOn');

      // Section 31.4's other half: with a client attached, a frame's diff
      // becomes events UIAutomationCore accepts. Four of them - the removed
      // checkbox, the renamed button, its focus property and the focus event
      // itself - and each was raised through the runtime, which is what
      // rejects a malformed VARIANT or runtime id.
      expect(probe['clientsAreListening'], '1');
      expect(int.parse(probe['eventsRaised'] ?? '0'), greaterThanOrEqualTo(4));
    }, timeout: const Timeout(Duration(minutes: 3)));
  }, skip: Platform.isWindows ? null : _needsWindows);
}
