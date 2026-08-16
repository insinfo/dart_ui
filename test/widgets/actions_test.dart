import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

final class _SaveIntent extends Intent {
  const _SaveIntent();
}

void main() {
  group('key gestures', () {
    test('a gesture is built from an event, ignoring lock keys', () {
      final gesture = KeyGesture.fromEvent(_key(
        0x53,
        modifiers: <KeyModifier>{
          KeyModifier.control,
          KeyModifier.capsLock,
          KeyModifier.numLock,
        },
      ));

      // Lock state is not part of a shortcut: a Ctrl+S that stops working
      // because Num Lock is on is a bug, not a feature.
      expect(gesture, const KeyGesture(0x53, control: true));
    });

    test('modifiers distinguish otherwise identical gestures', () {
      expect(
        const KeyGesture(0x53, control: true),
        isNot(const KeyGesture(0x53, control: true, shift: true)),
      );
    });
  });

  group('shortcut map', () {
    test('resolves a bound gesture and ignores key-up', () {
      final map = ShortcutMap(<KeyGesture, Intent>{
        const KeyGesture(0x53, control: true): const _SaveIntent(),
      });

      expect(
        map.resolve(_key(0x53, modifiers: <KeyModifier>{KeyModifier.control})),
        isA<_SaveIntent>(),
      );
      expect(map.resolve(_key(0x53)), isNull);
      expect(
        map.resolve(
            _keyUp(0x53, modifiers: <KeyModifier>{KeyModifier.control})),
        isNull,
        reason: 'a shortcut fires on press, not release',
      );
    });

    test('an inner map overrides one binding without losing the others', () {
      final application = ShortcutMap(<KeyGesture, Intent>{
        const KeyGesture(0x53, control: true): const _SaveIntent(),
        const KeyGesture(logicalKeyEscape): const DismissIntent(),
      });
      final dialog = ShortcutMap(
        <KeyGesture, Intent>{
          const KeyGesture(logicalKeyEscape): const ActivateIntent(),
        },
        parent: application,
      );

      expect(dialog.resolve(_key(logicalKeyEscape)), isA<ActivateIntent>());
      expect(
        dialog
            .resolve(_key(0x53, modifiers: <KeyModifier>{KeyModifier.control})),
        isA<_SaveIntent>(),
      );
    });
  });

  group('actions', () {
    test('an intent runs the action bound to its exact type', () {
      var saves = 0;
      final actions = ActionMap()
        ..register<_SaveIntent>(
          CallbackAction<_SaveIntent>((_SaveIntent intent) => saves++),
        );

      expect(actions.invoke(const _SaveIntent()), isTrue);
      expect(saves, 1);
      expect(actions.invoke(const DismissIntent()), isFalse);
    });

    test('a disabled action lets the intent fall through to an outer map', () {
      final outer = ActionMap()
        ..register<_SaveIntent>(
          CallbackAction<_SaveIntent>((_) {}),
        );
      var innerRan = false;
      final inner = ActionMap(null, outer)
        ..register<_SaveIntent>(CallbackAction<_SaveIntent>(
          (_) => innerRan = true,
          isEnabled: (_) => false,
        ));

      expect(inner.invoke(const _SaveIntent()), isTrue);
      expect(innerRan, isFalse,
          reason: 'the disabled inner action was skipped');
    });

    test('an unhandled intent reports that nothing took it', () {
      expect(ActionMap().invoke(const DismissIntent()), isFalse);
    });
  });

  group('dispatcher', () {
    test('a key becomes an intent becomes an effect', () {
      var saves = 0;
      final dispatcher = ShortcutDispatcher(
        shortcuts: ShortcutMap(<KeyGesture, Intent>{
          const KeyGesture(0x53, control: true): const _SaveIntent(),
        }),
        actions: ActionMap()
          ..register<_SaveIntent>(
            CallbackAction<_SaveIntent>((_) => saves++),
          ),
      );

      expect(
        dispatcher.dispatch(
          _key(0x53, modifiers: <KeyModifier>{KeyModifier.control}),
        ),
        isTrue,
      );
      expect(saves, 1);
      expect(dispatcher.dispatch(_key(0x41)), isFalse);
    });

    test('a bound key with no action leaves the key unhandled', () {
      final dispatcher = ShortcutDispatcher(
        shortcuts: ShortcutMap(<KeyGesture, Intent>{
          const KeyGesture(0x53): const _SaveIntent(),
        }),
        actions: ActionMap(),
      );

      expect(dispatcher.dispatch(_key(0x53)), isFalse);
    });
  });

  test('an owner consults shortcuts only after the focused control declines',
      () {
    var saves = 0;
    final controller = TextEditingController();
    final owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(200, 40)),
      ),
    )..shortcuts = ShortcutDispatcher(
        shortcuts: ShortcutMap(<KeyGesture, Intent>{
          const KeyGesture(0x53): const _SaveIntent(),
        }),
        actions: ActionMap()
          ..register<_SaveIntent>(
            CallbackAction<_SaveIntent>((_) => saves++),
          ),
      );
    owner.updateRoot(TextField(controller: controller));
    owner.pipelineOwner.drawFrame(DisplayList());
    owner.requestKeyboardFocus(owner.renderRoot! as RenderTextField);

    // The field claims the 'S' key because the layout is about to turn it into
    // text, so the shortcut must not fire - but the key itself inserts
    // nothing. The character arrives separately, from the platform.
    owner.dispatchKeyEvent(_key(0x53));
    expect(saves, 0);
    expect(
      controller.value,
      isEmpty,
      reason: 'a virtual key code is not a character',
    );

    owner.dispatchTextInputEvent(FakeTextInput().typeText('s'));
    expect(controller.value, 's');
    expect(saves, 0);

    // With nothing focused the shortcut chain sees the key.
    owner.clearKeyboardFocus(owner.renderRoot! as RenderTextField);
    owner.dispatchKeyEvent(_key(0x53));
    expect(saves, 1);
    owner.dispose();
  });
}

KeyDownEvent _key(int logicalKey, {Set<KeyModifier> modifiers = const {}}) =>
    KeyDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      physicalKey: logicalKey,
      logicalKey: logicalKey,
      modifiers: modifiers,
    );

KeyUpEvent _keyUp(int logicalKey, {Set<KeyModifier> modifiers = const {}}) =>
    KeyUpEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      physicalKey: logicalKey,
      logicalKey: logicalKey,
      modifiers: modifiers,
    );
