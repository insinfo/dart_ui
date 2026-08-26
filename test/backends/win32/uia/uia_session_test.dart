/// The wiring: lazy activation, a per-frame pump, and a client that *operates*
/// the widgets rather than only reading them.
///
/// The last group is the one that matters, and it is a stronger claim than the
/// one `uia_bridge_test.dart` makes. That file proves a hand-written semantic
/// tree is reachable through `CLSID_CUIAutomation`. This one builds real render
/// objects from `lib/src/widgets/`, lets Windows activate the provider through
/// `WM_GETOBJECT`, and then calls `Invoke`, `Toggle` and `SetValue` through the
/// client - the same three patterns Narrator uses - and checks the *widgets*
/// changed.
///
/// Read the group names as a claim ladder:
///
///   * **registration** - in-process, no COM, no window. Proves the bookkeeping;
///   * **dispatching an action** - in-process, real render objects, no COM.
///     Proves `SemanticsOwner.performAction` refuses what it should;
///   * **a real window, operated by a real client** - a subprocess with an
///     HWND, `uiautomationcore.dll` and a live `IUIAutomation`. This is the
///     integration evidence; everything above it is a unit test and is labelled
///     as one on purpose.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_ui/src/backends/win32/uia/uia_session.dart';
import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/layout/box_constraints.dart';
import 'package:dart_ui/src/layout/pipeline.dart';
import 'package:dart_ui/src/layout/render_box.dart';
import 'package:dart_ui/src/semantics/semantics.dart';
import 'package:test/test.dart';

const String _needsWindows =
    'UI Automation is a Windows API; there is no provider side to attach on '
    'Linux or macOS';

/// A render box that declares semantics and can perform them.
///
/// Deliberately not one of the real controls: this group is about
/// [SemanticsOwner.performAction]'s refusals, and a real control would drag in
/// a theme, a typeface and a focus manager without making the refusals any
/// clearer.
final class _Actor extends RenderBox
    implements SemanticsProvider, SemanticsActionTarget {
  _Actor(this.config);

  SemanticsConfiguration config;
  final List<(SemanticsAction, String?)> performed =
      <(SemanticsAction, String?)>[];

  /// What [performSemanticsAction] answers, so a test can make the widget
  /// itself refuse.
  bool answer = true;

  @override
  SemanticsConfiguration describeSemantics() => config;

  @override
  bool performSemanticsAction(SemanticsAction action, {String? value}) {
    performed.add((action, value));
    return answer;
  }

  @override
  void performLayout() => size = constraints.constrain(const Size(40, 20));
}

/// A described box with no action path at all, which is the honest state for a
/// control that says what it is and does nothing.
final class _Mute extends RenderBox implements SemanticsProvider {
  _Mute(this.config);

  final SemanticsConfiguration config;

  @override
  SemanticsConfiguration describeSemantics() => config;

  @override
  void performLayout() => size = constraints.constrain(const Size(40, 20));
}

SemanticsConfiguration _button({
  Set<SemanticsAction> actions = const <SemanticsAction>{
    SemanticsAction.activate,
  },
}) =>
    SemanticsConfiguration(
      role: SemanticsRole.button,
      label: 'Save',
      actions: actions,
    );

PipelineOwner _pipeline(RenderBox root) => PipelineOwner(
      rootConstraints: BoxConstraints.loose(const Size(200, 200)),
    )
      ..root = root
      ..drawFrame(DisplayList());

/// The probe's output as `key -> value`, having failed loudly if it did not
/// finish.
Future<Map<String, String>> _runProbe() async {
  const String script = 'test/backends/win32/uia/uia_widget_probe.dart';
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
    fail('the UI Automation widget probe hung. Reached:\n${lines.join('\n')}');
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
  group('registration (unit: no COM, no window)', () {
    tearDown(WindowsAccessibility.reset);

    test('registering builds nothing', () {
      final SemanticsOwner owner = SemanticsOwner();
      WindowsAccessibility.register(4242, (owner: owner, root: () => null));

      // The cost model this file exists to keep: a window that no assistive
      // technology ever looks at pays one map entry and nothing else. If a
      // provider were built here, every window on every machine would carry a
      // COM apartment and a per-frame tree walk for nobody.
      expect(WindowsAccessibility.isRegistered(4242), isTrue);
      expect(WindowsAccessibility.forWindow(4242), isNull);
      expect(WindowsAccessibility.liveCount, 0);
    });

    test('unregistering forgets the window', () {
      final SemanticsOwner owner = SemanticsOwner();
      WindowsAccessibility.register(4242, (owner: owner, root: () => null));
      WindowsAccessibility.unregister(4242);

      expect(WindowsAccessibility.isRegistered(4242), isFalse);
      expect(WindowsAccessibility.liveCount, 0);
    });

    test('a window nobody registered has no failure to report either', () {
      // Empty is not the same as "asked and refused"; the two are separated by
      // `forWindow`, and conflating them would make a machine without
      // uiautomationcore.dll indistinguishable from a machine nobody asked.
      expect(WindowsAccessibility.failureFor(999), isEmpty);
    });
  });

  group('dispatching an action (unit: real render objects, no COM)', () {
    test('reaches the render object that owns the id', () {
      final _Actor actor = _Actor(_button());
      final PipelineOwner pipeline = _pipeline(actor);
      final SemanticsOwner owner = SemanticsOwner();
      final int id = owner.build(pipeline.root).root!.id;

      expect(owner.performAction(id, SemanticsAction.activate), isTrue);
      expect(actor.performed, <(SemanticsAction, String?)>[
        (SemanticsAction.activate, null),
      ]);
    });

    test('carries the value for setValue and nothing for the rest', () {
      final _Actor actor = _Actor(_button(
        actions: const <SemanticsAction>{SemanticsAction.setValue},
      ));
      final PipelineOwner pipeline = _pipeline(actor);
      final SemanticsOwner owner = SemanticsOwner();
      final int id = owner.build(pipeline.root).root!.id;

      owner.performAction(id, SemanticsAction.setValue, value: 'typed');

      expect(actor.performed.single, (SemanticsAction.setValue, 'typed'));
    });

    test('refuses an action the node never declared', () {
      // The declaration is what a client reads to decide the call is legal.
      // Honouring an undeclared action would make the declaration a lie in the
      // other direction: a screen reader would have no way to know the control
      // could be operated.
      final _Actor actor = _Actor(_button());
      final PipelineOwner pipeline = _pipeline(actor);
      final SemanticsOwner owner = SemanticsOwner();
      final int id = owner.build(pipeline.root).root!.id;

      expect(owner.performAction(id, SemanticsAction.increment), isFalse);
      expect(actor.performed, isEmpty);
    });

    test('refuses a render object that cannot perform actions', () {
      final PipelineOwner pipeline = _pipeline(_Mute(_button()));
      final SemanticsOwner owner = SemanticsOwner();
      final int id = owner.build(pipeline.root).root!.id;

      expect(owner.performAction(id, SemanticsAction.activate), isFalse);
    });

    test('refuses a stale id rather than throwing', () {
      // A client holds ids across frames and is entitled to ask about one whose
      // control has since been removed. This crossing an FFI trampoline as an
      // exception would be an abort, not a failed call.
      final SemanticsOwner owner = SemanticsOwner();
      expect(owner.performAction(12345, SemanticsAction.activate), isFalse);
    });

    test('passes the widget\'s own refusal through', () {
      final _Actor actor = _Actor(_button())..answer = false;
      final PipelineOwner pipeline = _pipeline(actor);
      final SemanticsOwner owner = SemanticsOwner();
      final int id = owner.build(pipeline.root).root!.id;

      expect(owner.performAction(id, SemanticsAction.activate), isFalse);
      expect(actor.performed, hasLength(1), reason: 'it was asked');
    });

    test('an id is forgotten with the render object it named', () {
      final _Actor first = _Actor(_button());
      final _Actor second = _Actor(_button());
      final _Row row = _Row()
        ..add(first)
        ..add(second);
      final PipelineOwner pipeline = _pipeline(row);
      final SemanticsOwner owner = SemanticsOwner()..build(pipeline.root);
      final int id = owner.idFor(second);

      row.remove(second);
      pipeline.drawFrame(DisplayList());
      owner.build(pipeline.root);

      expect(owner.renderObjectFor(id), isNull);
      expect(owner.performAction(id, SemanticsAction.activate), isFalse);
    });
  });

  group('a real window, operated by a real client', () {
    test('Invoke, Toggle and SetValue reach the widgets', () async {
      final Map<String, String> probe = await _runProbe();

      // Lazy activation, measured rather than assumed: nothing was live before
      // the client asked, and something was live after.
      expect(probe['liveBeforeClient'], '0');
      expect(probe['liveAfterClient'], '1');
      expect(
        probe['apartment'],
        anyOf('apartmentThreaded', 'alreadyApartmentThreaded'),
      );
      // Activation publishes immediately: a bridge with nothing published
      // answers null to the very WM_GETOBJECT that built it, and the window
      // would look like it had no provider at all.
      expect(int.parse(probe['pumpsAfterActivation'] ?? '0'), 1);

      // Role and name, read through the client API. The raw view merges the
      // window's own non-client provider with ours, so the title bar (50037)
      // is in this list and belongs to Windows.
      expect(probe['child[Save].controlType'], '50000'); // Button
      expect(probe['child[Remember me].controlType'], '50002'); // CheckBox
      expect(probe['child[Name].controlType'], '50004'); // Edit

      // Invoke. `button.presses` counts calls to the render object's own
      // `onPressed`, which is the same callback a mouse click and the space
      // bar reach - so this is the client having *operated* the widget.
      expect(probe['button.hasInvokePattern'], '1');
      expect(probe['button.invokeHresult'], startsWith('S_OK'));
      expect(probe['button.presses'], '1');

      // Toggle, and the round trip back: the widget changed, a frame ran, the
      // session pumped, and the client reads the new state through the same
      // property it read the old one from.
      expect(probe['checkBox.toggleBefore'], '0'); // ToggleState_Off
      expect(probe['checkBox.toggleHresult'], startsWith('S_OK'));
      expect(probe['checkBox.dartValue'], 'true');
      expect(probe['checkBox.toggleAfter'], '1'); // ToggleState_On
      expect(
        int.parse(probe['checkBox.eventsRaised'] ?? '0'),
        greaterThan(0),
        reason: 'a toggled check box must produce at least one property '
            'change event, or a screen reader announces nothing',
      );

      // SetValue on a slider, which the bridge exposes as IValueProvider with
      // the widget's own string rather than as IRangeValueProvider - see the
      // uiaAbsentPatterns entry that explains why.
      expect(probe['slider.valueBefore'], '0.25');
      expect(probe['slider.setValueHresult'], startsWith('S_OK'));
      expect(probe['slider.dartValue'], '0.75');
      expect(probe['slider.valueAfter'], '0.75');

      // SetValue on a text field, through selectAll + replaceSelection, which
      // is the path a paste takes and therefore records one undo entry.
      expect(probe['field.setValueHresult'], startsWith('S_OK'));
      expect(probe['field.dartValue'], 'after');
      expect(probe['field.valueAfter'], 'after');

      // Teardown: a session outliving its window is a provider pointing at a
      // dead HWND, which a client discovers by timing out.
      expect(probe['liveAfterUnregister'], '0');
    }, timeout: const Timeout(Duration(minutes: 3)));
  }, skip: Platform.isWindows ? null : _needsWindows);
}

/// The smallest multi-child box that will hold two actors side by side.
final class _Row extends RenderBox {
  final List<RenderBox> _children = <RenderBox>[];

  void add(RenderBox child) {
    _children.add(child);
    adoptChild(child);
  }

  void remove(RenderBox child) {
    _children.remove(child);
    dropChild(child);
  }

  @override
  void visitChildren(void Function(RenderBox child) visitor) {
    for (final RenderBox child in _children.toList()) {
      visitor(child);
    }
  }

  @override
  void performLayout() {
    double x = 0;
    for (final RenderBox child in _children) {
      child.layout(constraints.loosen(), parentUsesSize: true);
      child.parentData!.offset = Offset(x, 0);
      x += child.size.width;
    }
    size = constraints.constrain(Size(x, 20));
  }
}
