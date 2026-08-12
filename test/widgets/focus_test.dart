import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

final class _Target implements KeyboardEventTarget {
  final List<KeyEvent> events = <KeyEvent>[];

  @override
  bool handleKeyEvent(KeyEvent event) {
    events.add(event);
    return true;
  }
}

void main() {
  group('focus tree', () {
    test('a node reports focus, and its ancestors report containing it', () {
      final manager = FocusManager();
      final scope = FocusScopeNode(debugLabel: 'panel');
      final node = FocusNode(debugLabel: 'a');
      manager.rootScope.add(scope);
      scope.add(node);

      expect(node.requestFocus(), isTrue);
      expect(node.hasPrimaryFocus, isTrue);
      expect(scope.hasPrimaryFocus, isFalse);
      expect(scope.hasFocus, isTrue, reason: 'a scope contains its focus');
      expect(manager.primaryFocus, same(node));
    });

    test('a node that cannot request focus is refused and left out of the ring',
        () {
      final manager = FocusManager();
      final enabled = FocusNode(debugLabel: 'enabled');
      final disabled =
          FocusNode(debugLabel: 'disabled', canRequestFocus: false);
      manager.rootScope
        ..add(enabled)
        ..add(disabled);

      expect(disabled.requestFocus(), isFalse);
      expect(manager.traversalRing(), <FocusNode>[enabled]);
    });

    test('disabling the focused node surrenders focus', () {
      final manager = FocusManager();
      final node = FocusNode(debugLabel: 'a');
      manager.rootScope.add(node);
      node.requestFocus();

      node.canRequestFocus = false;

      expect(manager.primaryFocus, isNull);
    });

    test('skipTraversal keeps a node focusable but out of the tab ring', () {
      final manager = FocusManager();
      final tabbable = FocusNode(debugLabel: 'tabbable');
      final clickOnly = FocusNode(debugLabel: 'clickable', skipTraversal: true);
      manager.rootScope
        ..add(tabbable)
        ..add(clickOnly);

      expect(manager.traversalRing(), <FocusNode>[tabbable]);
      expect(clickOnly.requestFocus(), isTrue);
    });

    test('unmounting the focused node clears focus, a sibling does not', () {
      final manager = FocusManager();
      final first = FocusNode(debugLabel: 'first');
      final second = FocusNode(debugLabel: 'second');
      manager.rootScope
        ..add(first)
        ..add(second);
      second.requestFocus();

      first.dispose();
      expect(manager.primaryFocus, same(second),
          reason: 'an unrelated node leaving must not steal focus away');

      second.dispose();
      expect(manager.primaryFocus, isNull);
    });
  });

  group('traversal', () {
    test('Tab moves forward and Shift+Tab back, wrapping both ways', () {
      final manager = FocusManager();
      final nodes = <FocusNode>[
        for (int i = 0; i < 3; i++) FocusNode(debugLabel: 'n$i'),
      ];
      for (final node in nodes) {
        manager.rootScope.add(node);
      }

      expect(manager.moveFocus(TraversalDirection.next), isTrue);
      expect(manager.primaryFocus, same(nodes[0]));
      manager.moveFocus(TraversalDirection.next);
      manager.moveFocus(TraversalDirection.next);
      expect(manager.primaryFocus, same(nodes[2]));

      manager.moveFocus(TraversalDirection.next);
      expect(manager.primaryFocus, same(nodes[0]), reason: 'wraps forward');

      manager.moveFocus(TraversalDirection.previous);
      expect(manager.primaryFocus, same(nodes[2]), reason: 'wraps backward');
    });

    test('traversal marks focus visible, a pointer does not', () {
      final manager = FocusManager();
      final node = FocusNode(debugLabel: 'a');
      manager.rootScope.add(node);

      manager.moveFocus(TraversalDirection.next);
      expect(node.isFocusVisible, isTrue);
      expect(node.focusChangeReason, FocusChangeReason.traversal);

      node.requestFocus(FocusChangeReason.pointer);
      expect(node.isFocusVisible, isFalse);
    });

    test('a Tab key event is interpreted as traversal', () {
      final manager = FocusManager();
      final node = FocusNode(debugLabel: 'a');
      manager.rootScope.add(node);

      expect(manager.handleTraversalKey(_key(logicalKeyTab)), isTrue);
      expect(manager.primaryFocus, same(node));
      expect(manager.handleTraversalKey(_key(logicalKeyEnter)), isFalse);
    });
  });

  group('modal scopes', () {
    test('a modal scope traps the ring inside itself', () {
      final manager = FocusManager();
      final background = FocusNode(debugLabel: 'background');
      final dialog = FocusScopeNode(debugLabel: 'dialog', modal: true);
      final ok = FocusNode(debugLabel: 'ok');
      final cancel = FocusNode(debugLabel: 'cancel');
      manager.rootScope
        ..add(background)
        ..add(dialog);
      dialog
        ..add(ok)
        ..add(cancel);

      expect(manager.traversalRing(), <FocusNode>[ok, cancel]);

      manager.moveFocus(TraversalDirection.next);
      manager.moveFocus(TraversalDirection.next);
      expect(manager.primaryFocus, same(cancel));
      manager.moveFocus(TraversalDirection.next);
      expect(manager.primaryFocus, same(ok),
          reason: 'Tab wraps inside the dialog rather than reaching behind it');
    });

    test('a modal refuses a direct focus request from outside itself', () {
      final manager = FocusManager();
      final background = FocusNode(debugLabel: 'background');
      final dialog = FocusScopeNode(debugLabel: 'dialog', modal: true);
      final ok = FocusNode(debugLabel: 'ok');
      manager.rootScope
        ..add(background)
        ..add(dialog);
      dialog.add(ok);

      expect(background.requestFocus(), isFalse);
      expect(ok.requestFocus(), isTrue);
    });
  });

  group('restoration', () {
    test('a scope restores the child that had focus, not the first one', () {
      final manager = FocusManager();
      final scope = FocusScopeNode(debugLabel: 'panel');
      final first = FocusNode(debugLabel: 'first');
      final second = FocusNode(debugLabel: 'second');
      manager.rootScope.add(scope);
      scope
        ..add(first)
        ..add(second);

      second.requestFocus();
      expect(scope.rememberedChild, same(second));

      second.unfocus();
      expect(manager.primaryFocus, isNull);

      expect(scope.focusRemembered(), isTrue);
      expect(manager.primaryFocus, same(second));
    });

    test('an empty scope reports that it could not restore focus', () {
      final manager = FocusManager();
      final scope = FocusScopeNode(debugLabel: 'empty');
      manager.rootScope.add(scope);

      expect(scope.focusRemembered(), isFalse);
    });
  });

  group('router integration and window activation', () {
    test('focus points the keyboard router at the node target', () {
      final router = KeyboardRouter();
      final manager = FocusManager(router: router);
      final target = _Target();
      final node = FocusNode(debugLabel: 'a', target: target);
      manager.rootScope.add(node);

      node.requestFocus();
      expect(router.focusedTarget, same(target));

      router.route(_key(65));
      expect(target.events, hasLength(1));

      node.unfocus();
      expect(router.focusedTarget, isNull);
    });

    test('a node adopts a target that appears after it', () {
      final router = KeyboardRouter();
      final manager = FocusManager(router: router);
      final node = FocusNode(debugLabel: 'a');
      manager.rootScope.add(node);
      node.requestFocus();
      expect(router.focusedTarget, isNull);

      final target = _Target();
      node.target = target;

      // Re-pointed while focused: otherwise the control looks focused and
      // receives nothing.
      expect(router.focusedTarget, same(target));
    });

    test('an inactive window keeps its focus assignment', () {
      final manager = FocusManager();
      final node = FocusNode(debugLabel: 'a');
      manager.rootScope.add(node);
      node.requestFocus();

      manager.isWindowActive = false;
      expect(manager.primaryFocus, same(node),
          reason: 'deactivating must not lose which control was in use');
      expect(manager.isWindowActive, isFalse);

      manager.isWindowActive = true;
      expect(manager.primaryFocus, same(node));
    });
  });

  test('a cycle in the focus tree is refused', () {
    final parent = FocusScopeNode(debugLabel: 'parent');
    final child = FocusScopeNode(debugLabel: 'child');
    parent.add(child);

    expect(() => child.add(parent), throwsStateError);
    expect(() => parent.add(parent), throwsStateError);
  });

  test('a node cannot be in two places at once', () {
    final first = FocusScopeNode(debugLabel: 'first');
    final second = FocusScopeNode(debugLabel: 'second');
    final node = FocusNode(debugLabel: 'a');
    first.add(node);

    expect(() => second.add(node), throwsStateError);
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
