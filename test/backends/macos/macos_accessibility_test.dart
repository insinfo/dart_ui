import 'dart:convert';

import 'package:dart_ui/src/backends/macos/host_protocol.dart';
import 'package:dart_ui/src/backends/macos/macos_accessibility.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/semantics/semantics.dart';
import 'package:test/test.dart';

void main() {
  test('a node line carries role, text, frame, states and actions', () {
    // The host builds an NSAccessibilityElement from exactly these fields; a
    // state or action index that moved would read as a different control.
    final String line = macosA11yNode(
      const SemanticsNode(
        id: 7,
        role: SemanticsRole.checkbox,
        bounds: Rect.fromLTWH(10, 20.5, 120, 24),
        label: 'Aceito',
        hint: 'os termos',
        states: <SemanticsState>{
          SemanticsState.checked,
          SemanticsState.focused,
        },
        actions: <SemanticsAction>{SemanticsAction.activate},
      ),
      3,
    );
    final List<String> parts = line.trim().split(' ');
    expect(parts[0], 'A11Y_NODE');
    expect(parts[1], '7');
    expect(parts[2], '3');
    expect(parts[3], 'checkbox');
    expect(utf8.decode(base64.decode(parts[4])), 'Aceito, os termos');
    expect(parts[5], '-', reason: 'no value');
    expect(parts.sublist(6, 10), <String>['10.00', '20.50', '120.00', '24.00']);
    expect(
        int.parse(parts[10]),
        (1 << SemanticsState.checked.index) |
            (1 << SemanticsState.focused.index));
    expect(int.parse(parts[11]), 1 << SemanticsAction.activate.index);
    // The bit positions the host's Objective-C hard-codes.
    expect(SemanticsState.disabled.index, 0);
    expect(SemanticsState.checked.index, 1);
    expect(SemanticsState.mixed.index, 2);
    expect(SemanticsState.selected.index, 3);
    expect(SemanticsState.focused.index, 4);
    expect(SemanticsState.expanded.index, 5);
    expect(SemanticsAction.activate.index, 1);
    expect(SemanticsAction.increment.index, 3);
    expect(SemanticsAction.decrement.index, 4);
  });

  test('nothing is published until a client asks', () {
    // A window nobody reads must cost nothing per frame, as on Windows.
    final _Window window = _Window();
    final MacosAccessibilityHost host =
        MacosAccessibilityHost((int handle) => handle == 4 ? window : null);
    host.register(4, (owner: SemanticsOwner(), root: () => null));
    expect(host.forWindow(4), isNull);
    expect(window.commands, isEmpty);

    window.accessibility!.onRequested();
    expect(host.forWindow(4), isNotNull);
    expect(window.commands, <String>[macosA11yBegin(), macosA11yEnd()],
        reason: 'an empty tree is still a tree: the host swaps it in');

    host.unregister(4);
    expect(window.accessibility, isNull);
    expect(host.forWindow(4), isNull);
  });

  test('the three host lines parse', () {
    final List<String> seen = <String>[];
    HostProtocolParser(_Sink(seen)).addBytes(utf8.encode(
      'A11Y_REQUESTED\nA11Y_ACTION=12:activate\nA11Y_DUMP=0:AXButton:cA==:-\n'
      'A11Y_ACTION=x\n',
    ));
    expect(seen, <String>[
      'requested',
      'action 12 activate',
      'dump 0:AXButton:cA==:-',
      'error BAD_A11Y_ACTION',
    ]);
  });
}

final class _Window implements MacosAccessibilityWindow {
  final List<String> commands = <String>[];

  @override
  MacosWindowAccessibility? accessibility;

  @override
  bool sendAccessibilityCommand(String command) {
    commands.add(command);
    return true;
  }
}

final class _Sink with HostMessageSinkAdapter {
  _Sink(this.seen);
  final List<String> seen;

  @override
  void onAccessibilityRequested() => seen.add('requested');

  @override
  void onAccessibilityAction(int node, String action) =>
      seen.add('action $node $action');

  @override
  void onAccessibilityDump(String line) => seen.add('dump $line');

  @override
  void onError(String code) => seen.add('error $code');
}
