/// Flutter's `Focus`, `KeyboardListener` and `ExcludeFocus`: keys bubble
/// from the focused node up, and focus changes are reported up the tree.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

import 'input_test_harness.dart';

void main() {
  setUp(HardwareKeyboard.instance.clearState);

  test('a key goes to the focused Focus, then bubbles to its ancestors', () {
    final List<String> log = <String>[];
    final FocusNode inner = FocusNode(debugLabel: 'inner');
    final InputHarness h = InputHarness(
      Focus(
        debugLabel: 'outer',
        onKeyEvent: (FocusNode node, KeyEvent event) {
          log.add('outer ${event.logicalKey}');
          return KeyEventResult.handled;
        },
        child: Focus(
          focusNode: inner,
          onKeyEvent: (FocusNode node, KeyEvent event) {
            log.add('inner ${event.logicalKey}');
            return event.logicalKey == LogicalKeyboardKey.keyA
                ? KeyEventResult.handled
                : KeyEventResult.ignored;
          },
          child: const SizedBox(width: 10, height: 10),
        ),
      ),
      overlay: false,
    );
    inner.requestFocus();
    expect(inner.hasPrimaryFocus, isTrue);

    expect(h.key(LogicalKeyboardKey.keyA), isTrue);
    expect(h.key(LogicalKeyboardKey.keyB), isTrue);
    expect(log, <String>[
      'inner ${0x41}',
      'inner ${0x42}',
      'outer ${0x42}',
    ]);
    h.dispose();
  });

  test('skipRemainingHandlers stops the walk and leaves the key unhandled', () {
    int outer = 0;
    final FocusNode inner = FocusNode();
    final InputHarness h = InputHarness(
      Focus(
        onKeyEvent: (_, __) {
          outer++;
          return KeyEventResult.handled;
        },
        child: Focus(
          focusNode: inner,
          onKeyEvent: (_, __) => KeyEventResult.skipRemainingHandlers,
          child: const SizedBox(),
        ),
      ),
      overlay: false,
    );
    inner.requestFocus();
    expect(h.key(LogicalKeyboardKey.escape), isFalse);
    expect(outer, 0);
    h.dispose();
  });

  test('onFocusChange reports a descendant gaining and losing focus', () {
    final List<bool> changes = <bool>[];
    final FocusNode child = FocusNode();
    final InputHarness h = InputHarness(
      Focus(
        onFocusChange: changes.add,
        canRequestFocus: false,
        child: Focus(focusNode: child, child: const SizedBox()),
      ),
      overlay: false,
    );
    child.requestFocus();
    h.frame();
    child.unfocus();
    h.frame();
    expect(changes, <bool>[true, false]);
    h.dispose();
  });

  test('FocusNode takes a Flutter VoidCallback listener', () {
    final FocusNode node = FocusNode();
    int calls = 0;
    void listener() => calls++;
    node.addListener(listener);
    final InputHarness h = InputHarness(
      Focus(focusNode: node, child: const SizedBox()),
      overlay: false,
    );
    node.requestFocus();
    expect(calls, 1);
    node.removeListener(listener);
    node.unfocus();
    expect(calls, 1);
    expect(() => node.addListener((int x) {}), throwsArgumentError);
    h.dispose();
  });

  test('autofocus takes focus, and Focus.of finds the node', () {
    FocusNode? found;
    final InputHarness h = InputHarness(
      Focus(
        autofocus: true,
        debugLabel: 'auto',
        child: Builder(builder: (BuildContext context) {
          found = Focus.of(context);
          return const SizedBox();
        }),
      ),
      overlay: false,
    );
    expect(found, isNotNull);
    expect(found!.hasPrimaryFocus, isTrue);
    expect(found!.debugLabel, 'auto');
    h.dispose();
  });

  test('Focus.of throws without a Focus; maybeOf answers null', () {
    Object? error;
    FocusNode? maybe = FocusNode();
    final InputHarness h = InputHarness(
      Builder(builder: (BuildContext context) {
        maybe = Focus.maybeOf(context);
        try {
          Focus.of(context);
        } catch (e) {
          error = e;
        }
        return const SizedBox();
      }),
      overlay: false,
    );
    expect(maybe, isNull);
    expect(error, isA<StateError>());
    h.dispose();
  });

  test('KeyboardListener reports every key and passes it on', () {
    final List<int> keys = <int>[];
    int outer = 0;
    final FocusNode node = FocusNode();
    final InputHarness h = InputHarness(
      Focus(
        onKeyEvent: (_, KeyEvent e) {
          outer++;
          return KeyEventResult.ignored;
        },
        child: KeyboardListener(
          focusNode: node,
          autofocus: true,
          onKeyEvent: (KeyEvent e) => keys.add(e.logicalKey),
          child: const SizedBox(),
        ),
      ),
      overlay: false,
    );
    expect(node.hasPrimaryFocus, isTrue);
    h.key(LogicalKeyboardKey.enter);
    h.key(LogicalKeyboardKey.enter, up: true);
    expect(keys, <int>[0x0D, 0x0D]);
    expect(outer, 2);
    h.dispose();
  });

  test('ExcludeFocus takes the subtree out of focus and traversal', () {
    final FocusNode a = FocusNode(debugLabel: 'a');
    final FocusNode b = FocusNode(debugLabel: 'b');
    bool excluding = true;
    late void Function(void Function()) rebuild;
    final InputHarness h = InputHarness(
      StatefulBuilder(builder: (BuildContext context, setState) {
        rebuild = setState;
        return Column(children: <Widget>[
          Focus(focusNode: a, child: const SizedBox(width: 10, height: 10)),
          ExcludeFocus(
            excluding: excluding,
            child: Focus(
                focusNode: b, child: const SizedBox(width: 10, height: 10)),
          ),
        ]);
      }),
      overlay: false,
    );
    expect(b.canRequestFocus, isFalse);
    expect(b.requestFocus(), isFalse);
    a.requestFocus();
    expect(h.key(LogicalKeyboardKey.tab), isTrue);
    expect(a.hasPrimaryFocus, isTrue, reason: 'b is excluded: Tab wraps');

    rebuild(() => excluding = false);
    h.frame();
    expect(b.canRequestFocus, isTrue);
    h.key(LogicalKeyboardKey.tab);
    expect(b.hasPrimaryFocus, isTrue);

    rebuild(() => excluding = true);
    h.frame();
    expect(b.hasFocus, isFalse, reason: 'excluding again drops its focus');
    h.dispose();
  });

  test('HardwareKeyboard follows the keys and the modifiers', () {
    final InputHarness h = InputHarness(const SizedBox(), overlay: false);
    h.key(LogicalKeyboardKey.keyA, modifiers: <KeyModifier>{KeyModifier.shift});
    expect(HardwareKeyboard.instance.isShiftPressed, isTrue);
    expect(HardwareKeyboard.instance.logicalKeysPressed,
        contains(LogicalKeyboardKey.keyA));
    h.key(LogicalKeyboardKey.keyA, up: true);
    expect(HardwareKeyboard.instance.logicalKeysPressed, isEmpty);
    expect(HardwareKeyboard.instance.isShiftPressed, isFalse);
    h.dispose();
  });

  test('LogicalKeyboardKey compares and switches like an int key code', () {
    const int fromBackend = 0x1B;
    expect(fromBackend == LogicalKeyboardKey.escape, isTrue);
    final String name = switch (fromBackend) {
      LogicalKeyboardKey.enter => 'enter',
      LogicalKeyboardKey.escape => 'escape',
      _ => 'other',
    };
    expect(name, 'escape');
    expect(LogicalKeyboardKey.keyA.keyLabel, 'A');
    expect(LogicalKeyboardKey.arrowUp.keyLabel, 'Arrow Up');
    expect(const LogicalKeyboardKey(fromBackend).debugName, 'Escape');
    expect(LogicalKeyboardKey.findKeyByKeyId(0x41), LogicalKeyboardKey.keyA);
    expect(LogicalKeyboardKey.controlLeft.isModifier, isTrue);
  });
}
