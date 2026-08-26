/// Dead keys on Wayland: the keysym path, end to end without a compositor.
///
/// `wl_keyboard` delivers keysyms, and `dead_acute` followed by `a` is two of
/// them and one character. The compositor will not join them - that is the
/// client's job unless an input method is in the loop - so this is where the
/// framework either types `á` or types the bare accent, which is exactly what a
/// dead key exists to suppress.
///
/// Driven through the real [WaylandEventTranslator], so a regression that
/// stopped passing the engine through, or started letting the keymap answer
/// first, fails here.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/wayland/wayland_events.dart';
import 'package:dart_ui/src/backends/wayland/wayland_keymap.dart';
import 'package:dart_ui/src/backends/wayland/wayland_protocol.dart';
import 'package:dart_ui/src/platform/compose_sequences.dart';
import 'package:test/test.dart';

/// A Brazilian layout in miniature: one dead key, one letter, one Compose key.
const String _keymap = '''
xkb_keymap {
xkb_keycodes "(unnamed)" {
	<AD01> = 24;
	<AC01> = 38;
	<AC11> = 48;
	<LFSH> = 50;
};
xkb_symbols "(unnamed)" {
	name[group1]="Portuguese (Brazil)";
	key <AD01> { [ q, Q ] };
	key <AC01> { [ a, A ] };
	key <AC11> { [ dead_acute, dead_grave ] };
	key <LFSH> { [ Shift_L ] };
};
};
''';

const String _table = '''
<dead_acute> <a> : "á"   aacute
<dead_acute> <A> : "Á"   Aacute
''';

void main() {
  const NativeWindowId windowId = NativeWindowId(7);

  late WaylandXkbKeymap keymap;
  late WaylandModifiersState modifiers;
  late List<PlatformWindowEvent> emitted;
  late ComposeEngine engine;
  late WaylandRawEvent raw;

  setUp(() {
    keymap = WaylandXkbKeymap.parse(_keymap)!;
    modifiers = WaylandModifiersState();
    emitted = <PlatformWindowEvent>[];
    engine = ComposeEngine(ComposeTable.parse(_table));
    raw = WaylandRawEvent();
  });

  /// One `wl_keyboard.key`, through the real translator.
  ///
  /// The evdev code is the xkb keycode minus 8, which is the offset the
  /// protocol constant names.
  void key(int xkbKeycode, {bool pressed = true, ComposeEngine? compose}) {
    raw
      ..reset()
      ..type = WaylandRawEventType.keyboardKey
      ..surfaceId = 3
      ..timeMilliseconds = 1
      ..key = xkbKeycode - evdevToXkbKeycodeOffset
      ..state =
          pressed ? wlKeyboardKeyStatePressed : wlKeyboardKeyStateReleased;
    WaylandEventTranslator.translateKey(
      raw,
      windowId: windowId,
      generation: 1,
      keymap: keymap,
      modifiers: modifiers,
      emit: emitted.add,
      compose: compose,
    );
  }

  List<String> typed() => emitted
      .whereType<TextInputEvent>()
      .map((TextInputEvent event) => event.text)
      .toList();

  test('the layout really does put a dead key on that keycode', () {
    // If this fails everything below is testing nothing: the keymap subset has
    // to resolve `dead_acute` by name before a compose sequence can ever see
    // it, which is why the name table is shared with `compose_sequences.dart`.
    expect(keymap.keysymFor(48), composeKeysymFromName('dead_acute'));
    expect(
      keymap.textFor(48),
      isNull,
      reason: 'a dead key has no text of its own; that is what makes it dead',
    );
  });

  test('a dead key produces a KeyEvent and no text', () {
    key(48, compose: engine);

    expect(emitted.single, isA<KeyDownEvent>());
    expect(
      typed(),
      isEmpty,
      reason: 'the KeyEvent still goes out, so a shortcut bound to the '
          'physical key keeps working; what must not happen is text',
    );
    expect(engine.isComposing, isTrue);
  });

  test('the accent and the letter become one character', () {
    key(48, compose: engine);
    key(38, compose: engine);

    expect(typed(), <String>['á']);
  });

  test(
      'a dead key followed by something it does not combine with types '
      'nothing at all', () {
    key(48, compose: engine);
    key(24, compose: engine);

    expect(
      typed(),
      isEmpty,
      reason: 'X11 discards the sequence; replaying it would type the bare '
          'accent the dead key exists to suppress',
    );
    expect(engine.isComposing, isFalse);
  });

  test('Shift held during a sequence does not break it', () {
    key(48, compose: engine);
    // The physical Shift press arrives as its own key event in the middle of
    // the sequence. Half the standard table needs Shift held, so feeding it to
    // the engine would break the sequence the user is in the middle of.
    key(50, compose: engine);
    modifiers.update(depressed: 0x01, latched: 0, locked: 0, group: 0);
    key(38, compose: engine);

    expect(typed(), <String>['Á']);
  });

  test('a key outside any sequence types as itself', () {
    key(24, compose: engine);

    expect(typed(), <String>['q']);
  });

  test('a release never produces text, composing or not', () {
    key(48, compose: engine);
    key(38, pressed: false, compose: engine);

    expect(typed(), isEmpty);
  });

  test('without an engine the keymap answers as it always did', () {
    key(24);
    key(48);

    expect(
      typed(),
      <String>['q'],
      reason: 'a machine with no Compose table behaves exactly as before: the '
          'dead key resolves to no text and everything else is unchanged',
    );
  });

  test('an empty table changes nothing', () {
    final passthrough = ComposeEngine(ComposeTable.empty);
    key(24, compose: passthrough);

    expect(typed(), <String>['q']);
  });
}
