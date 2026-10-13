/// Flutter's `Shortcuts` and `Actions`: a key that the focused widget did
/// not use becomes an intent, carried out by the nearest action for it.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

import 'input_test_harness.dart';

final class _SaveIntent extends Intent {
  const _SaveIntent();
}

final class _DeleteIntent extends Intent {
  const _DeleteIntent();
}

const Set<KeyModifier> _ctrl = <KeyModifier>{KeyModifier.control};

void main() {
  setUp(HardwareKeyboard.instance.clearState);
  tearDown(() => debugEditingConventionOverride = null);

  test('Shortcuts maps a key to an intent that the Actions below carry out',
      () {
    int saves = 0;
    final InputHarness h = InputHarness(
      Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.keyS, control: true):
              _SaveIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            _SaveIntent: CallbackAction<_SaveIntent>(
              onInvoke: (_SaveIntent intent) => saves++,
            ),
          },
          child: const Focus(autofocus: true, child: SizedBox()),
        ),
      ),
      overlay: false,
    );
    expect(h.key(LogicalKeyboardKey.keyS, modifiers: _ctrl), isTrue);
    expect(saves, 1);
    expect(h.key(LogicalKeyboardKey.keyS), isFalse, reason: 'no Control');
    expect(
        h.key(LogicalKeyboardKey.keyS,
            modifiers: <KeyModifier>{KeyModifier.control, KeyModifier.shift}),
        isFalse,
        reason: 'exactly the modifiers named');
    expect(saves, 1);
    h.dispose();
  });

  test('the action is found from the focused widget, innermost first', () {
    final List<String> log = <String>[];
    final FocusNode left = FocusNode();
    final FocusNode right = FocusNode();
    final InputHarness h = InputHarness(
      Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.delete): _DeleteIntent(),
        },
        child: Column(children: <Widget>[
          Actions(
            actions: <Type, Action<Intent>>{
              _DeleteIntent: CallbackAction<_DeleteIntent>(
                  onInvoke: (_) => log.add('left')),
            },
            child: Focus(focusNode: left, child: const SizedBox(height: 10)),
          ),
          Actions(
            actions: <Type, Action<Intent>>{
              _DeleteIntent: CallbackAction<_DeleteIntent>(
                  onInvoke: (_) => log.add('right')),
            },
            child: Focus(focusNode: right, child: const SizedBox(height: 10)),
          ),
        ]),
      ),
      overlay: false,
    );
    left.requestFocus();
    h.key(LogicalKeyboardKey.delete);
    right.requestFocus();
    h.key(LogicalKeyboardKey.delete);
    expect(log, <String>['left', 'right']);
    h.dispose();
  });

  test('a disabled action lets the key through to the next handler', () {
    int outer = 0;
    final InputHarness h = InputHarness(
      Focus(
        onKeyEvent: (_, __) {
          outer++;
          return KeyEventResult.handled;
        },
        child: Shortcuts(
          shortcuts: const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.keyS, control: true):
                _SaveIntent(),
          },
          child: Actions(
            actions: <Type, Action<Intent>>{
              _SaveIntent: CallbackAction<_SaveIntent>(
                onInvoke: (_) => null,
                isEnabled: (_) => false,
              ),
            },
            child: const Focus(autofocus: true, child: SizedBox()),
          ),
        ),
      ),
      overlay: false,
    );
    expect(h.key(LogicalKeyboardKey.keyS, modifiers: _ctrl), isTrue);
    expect(outer, 1);
    h.dispose();
  });

  test('DoNothingAction swallows, and Intent.doNothing masks an outer key', () {
    int outer = 0;
    final InputHarness h = InputHarness(
      Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.escape): _DeleteIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            _DeleteIntent:
                CallbackAction<_DeleteIntent>(onInvoke: (_) => outer++),
            DoNothingIntent: DoNothingAction(),
          },
          child: const Shortcuts(
            shortcuts: <ShortcutActivator, Intent>{
              SingleActivator(LogicalKeyboardKey.escape): Intent.doNothing,
            },
            child: Focus(autofocus: true, child: SizedBox()),
          ),
        ),
      ),
      overlay: false,
    );
    expect(h.key(LogicalKeyboardKey.escape), isTrue);
    expect(outer, 0);
    h.dispose();
  });

  test('VoidCallbackIntent runs its callback through VoidCallbackAction', () {
    int calls = 0;
    final InputHarness h = InputHarness(
      Shortcuts(
        shortcuts: <ShortcutActivator, Intent>{
          const SingleActivator(LogicalKeyboardKey.f5):
              VoidCallbackIntent(() => calls++),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            VoidCallbackIntent: VoidCallbackAction(),
          },
          child: const Focus(autofocus: true, child: SizedBox()),
        ),
      ),
      overlay: false,
    );
    h.key(LogicalKeyboardKey.f5);
    expect(calls, 1);
    h.dispose();
  });

  test('LogicalKeySet, CharacterActivator and KeyGesture all bind', () {
    debugEditingConventionOverride = EditingConvention.pc;
    final List<String> log = <String>[];
    final InputHarness h = InputHarness(
      Shortcuts(
        shortcuts: <ShortcutActivator, Intent>{
          LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyC):
              VoidCallbackIntent(() => log.add('copy')),
          const CharacterActivator('?'):
              VoidCallbackIntent(() => log.add('help')),
          const KeyGesture(0x53, command: true):
              VoidCallbackIntent(() => log.add('save')),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            VoidCallbackIntent: VoidCallbackAction(),
          },
          child: const Focus(autofocus: true, child: SizedBox()),
        ),
      ),
      overlay: false,
    );
    h.key(LogicalKeyboardKey.keyC, modifiers: _ctrl);
    h.key(LogicalKeyboardKey.slash,
        modifiers: <KeyModifier>{KeyModifier.shift});
    h.key(LogicalKeyboardKey.keyS, modifiers: _ctrl);
    h.key(LogicalKeyboardKey.keyC);
    expect(log, <String>['copy', 'help', 'save']);
    h.dispose();
  });

  test('includeRepeats false ignores a held key', () {
    int calls = 0;
    final InputHarness h = InputHarness(
      Shortcuts(
        shortcuts: <ShortcutActivator, Intent>{
          const SingleActivator(LogicalKeyboardKey.space,
              includeRepeats: false): VoidCallbackIntent(() => calls++),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            VoidCallbackIntent: VoidCallbackAction(),
          },
          child: const Focus(autofocus: true, child: SizedBox()),
        ),
      ),
      overlay: false,
    );
    h.key(LogicalKeyboardKey.space);
    h.key(LogicalKeyboardKey.space, repeat: true);
    expect(calls, 1);
    h.dispose();
  });

  test('Actions.invoke, maybeInvoke, handler and find', () {
    late BuildContext inner;
    int saves = 0;
    final InputHarness h = InputHarness(
      Actions(
        actions: <Type, Action<Intent>>{
          _SaveIntent: CallbackAction<_SaveIntent>(onInvoke: (_) {
            saves++;
            return 'saved';
          }),
        },
        child: Builder(builder: (BuildContext context) {
          inner = context;
          return const SizedBox();
        }),
      ),
      overlay: false,
    );
    expect(Actions.invoke(inner, const _SaveIntent()), 'saved');
    expect(Actions.maybeInvoke(inner, const _DeleteIntent()), isNull);
    expect(
        () => Actions.invoke(inner, const _DeleteIntent()), throwsStateError);
    final void Function()? handler =
        Actions.handler(inner, const _SaveIntent());
    expect(handler, isNotNull);
    handler!();
    expect(saves, 2);
    expect(Actions.handler(inner, const _DeleteIntent()), isNull);
    expect(
        Actions.find<_SaveIntent>(inner), isA<CallbackAction<_SaveIntent>>());
    expect(Actions.maybeFind<_DeleteIntent>(inner), isNull);
    h.dispose();
  });

  test('a ContextAction is told where it was invoked from', () {
    BuildContext? seen;
    late BuildContext inner;
    final InputHarness h = InputHarness(
      Actions(
        actions: <Type, Action<Intent>>{
          _SaveIntent: _RecordingAction((BuildContext? c) => seen = c),
        },
        child: Builder(builder: (BuildContext context) {
          inner = context;
          return const SizedBox();
        }),
      ),
      overlay: false,
    );
    Actions.invoke(inner, const _SaveIntent());
    expect(seen, same(inner));
    h.dispose();
  });

  test('a modal ShortcutManager stops unbound keys from going further', () {
    int outer = 0;
    final ShortcutManager manager = ShortcutManager(modal: true);
    final InputHarness h = InputHarness(
      Focus(
        onKeyEvent: (_, __) {
          outer++;
          return KeyEventResult.handled;
        },
        child: Shortcuts.manager(
          manager: manager,
          child: const Focus(autofocus: true, child: SizedBox()),
        ),
      ),
      overlay: false,
    );
    expect(h.key(LogicalKeyboardKey.keyQ), isFalse);
    expect(outer, 0);
    h.dispose();
  });

  test('CallbackShortcuts takes Flutter activators too', () {
    int calls = 0;
    final InputHarness h = InputHarness(
      CallbackShortcuts(
        bindings: <ShortcutActivator, void Function()?>{
          const SingleActivator(LogicalKeyboardKey.keyN, control: true): () =>
              calls++,
        },
        child: const SizedBox(),
      ),
      overlay: false,
    );
    expect(h.key(LogicalKeyboardKey.keyN, modifiers: _ctrl), isTrue);
    expect(calls, 1);
    h.dispose();
  });
}

final class _RecordingAction extends ContextAction<_SaveIntent> {
  _RecordingAction(this.record);

  final void Function(BuildContext? context) record;

  @override
  Object? invoke(_SaveIntent intent, [BuildContext? context]) {
    record(context);
    return null;
  }
}
