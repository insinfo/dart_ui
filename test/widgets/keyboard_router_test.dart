import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

final class _KeyTarget implements KeyboardEventTarget {
  _KeyTarget({this.consumes = true});

  final bool consumes;
  final List<KeyEvent> events = <KeyEvent>[];

  @override
  bool handleKeyEvent(KeyEvent event) {
    events.add(event);
    return consumes;
  }
}

KeyDownEvent _down({int generation = 1, int logicalKey = 65}) => KeyDownEvent(
      windowId: const NativeWindowId(3),
      generation: generation,
      timestamp: Duration.zero,
      physicalKey: 30,
      logicalKey: logicalKey,
      modifiers: const <KeyModifier>{KeyModifier.control},
      isRepeat: true,
      location: KeyLocation.left,
    );

void main() {
  test('routes keys to the focused target', () {
    final router = KeyboardRouter();
    final target = _KeyTarget();

    expect(router.route(_down()), isFalse);
    router.requestFocus(target);

    expect(router.route(_down()), isTrue);
    expect(target.events, hasLength(1));
    final event = target.events.single as KeyDownEvent;
    expect(event.modifiers, contains(KeyModifier.control));
    expect(event.isRepeat, isTrue);
    expect(event.location, KeyLocation.left);
  });

  test('an unconsumed key is reported as unhandled', () {
    final router = KeyboardRouter();
    final target = _KeyTarget(consumes: false);
    router.requestFocus(target);

    // Delivered but declined: the caller must be free to try traversal and
    // application shortcuts next.
    expect(router.route(_down()), isFalse);
    expect(target.events, hasLength(1));
  });

  test('replacing focus stops delivery to the previous target', () {
    final router = KeyboardRouter();
    final first = _KeyTarget();
    final second = _KeyTarget();

    router
      ..requestFocus(first)
      ..requestFocus(second)
      ..route(_down());

    expect(first.events, isEmpty);
    expect(second.events, hasLength(1));
  });

  test('stale target cannot clear replacement focus', () {
    final router = KeyboardRouter();
    final oldTarget = _KeyTarget();
    final newTarget = _KeyTarget();
    router
      ..requestFocus(oldTarget)
      ..requestFocus(newTarget)
      ..clearFocus(oldTarget)
      ..route(_down(generation: 2));

    expect(router.focusedTarget, same(newTarget));
    expect(newTarget.events, hasLength(1));
  });
}
