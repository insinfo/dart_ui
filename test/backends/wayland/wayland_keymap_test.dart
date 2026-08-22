import 'package:dart_ui/src/backends/wayland/wayland_keymap.dart';
import 'package:test/test.dart';

/// A trimmed-down but structurally faithful xkb v1 keymap, shaped like what
/// xkbcommon serialises: keycodes with aliases, nested key blocks with type
/// annotations, and both legacy and `U+` symbol spellings.
const String _sampleKeymap = '''
xkb_keymap {
xkb_keycodes "(unnamed)" {
	minimum = 8;
	maximum = 255;
	<ESC>  = 9;
	<AE01> = 10;
	<AD01> = 24;
	<AC01> = 38;
	<AB01> = 52;
	<SPCE> = 65;
	<RTRN> = 36;
	<LFSH> = 50;
	<UP>   = 111;
	alias <LatQ> = <AD01>;
};
xkb_types "(unnamed)" {
	type "ALPHABETIC" {
		modifiers= Shift+Lock;
		map[Shift]= Level2;
		level_name[Level1]= "Base";
	};
};
xkb_compatibility "(unnamed)" {
	interpret Any+AnyOf(all) {
		action= SetMods(modifiers=modMapMods,clearLocks);
	};
};
xkb_symbols "(unnamed)" {
	name[group1]="Portuguese (Brazil)";
	key <ESC>  { [ Escape ] };
	key <AE01> { [ 1, exclam ] };
	key <AD01> { type= "ALPHABETIC", [ q, Q ] };
	key <AC01> { [ a, A ] };
	key <AB01> { [ U00E7, U00C7 ] };
	key <SPCE> { [ space ] };
	key <RTRN> { [ Return ] };
	key <LFSH> { [ Shift_L ] };
	key <UP>   { [ Up ] };
};
};
''';

void main() {
  group('xkbKeysymFromName', () {
    test('resolves single ASCII characters to themselves', () {
      expect(xkbKeysymFromName('a'), 0x61);
      expect(xkbKeysymFromName('Z'), 0x5a);
      expect(xkbKeysymFromName('7'), 0x37);
    });

    test('resolves U+XXXX spellings, Latin-1 flat and Unicode offset', () {
      expect(xkbKeysymFromName('U00E7'), 0xe7); // ç fits in Latin-1.
      expect(xkbKeysymFromName('U20AC'), 0x01000000 + 0x20ac); // €.
    });

    test('resolves named punctuation and controls', () {
      expect(xkbKeysymFromName('exclam'), 0x21);
      expect(xkbKeysymFromName('Return'), xkbKeysymReturn);
      expect(xkbKeysymFromName('F12'), xkbKeysymF1 + 11);
    });

    test('unknown names collapse to NoSymbol, never to a guess', () {
      expect(xkbKeysymFromName('dead_acute'), xkbNoSymbol);
      expect(xkbKeysymFromName('NoSymbol'), xkbNoSymbol);
      expect(xkbKeysymFromName(''), xkbNoSymbol);
    });
  });

  group('xkbKeysymToText', () {
    test('printable ranges map to their own code points', () {
      expect(xkbKeysymToText(0x41), 'A');
      expect(xkbKeysymToText(0xe7), 'ç');
      expect(xkbKeysymToText(0x01000000 + 0x20ac), '€');
    });

    test('function and modifier keysyms have no text', () {
      expect(xkbKeysymToText(xkbKeysymReturn), isNull);
      expect(xkbKeysymToText(xkbKeysymShiftL), isNull);
      expect(xkbKeysymToText(xkbNoSymbol), isNull);
    });
  });

  group('WaylandXkbKeymap.parse', () {
    late WaylandXkbKeymap keymap;

    setUp(() {
      final parsed = WaylandXkbKeymap.parse(_sampleKeymap);
      expect(parsed, isNotNull);
      keymap = parsed!;
    });

    test('reports its provenance and key count', () {
      expect(keymap.source, 'xkb-v1');
      expect(keymap.keyCount, 9);
    });

    test('maps keycodes through the keycodes section', () {
      // <AE01> = 10 carries [1, exclam].
      expect(keymap.keysymFor(10), 0x31);
      expect(keymap.keysymFor(10, shift: true), 0x21);
    });

    test('keeps both levels of alphabetic keys', () {
      expect(keymap.textFor(24), 'q');
      expect(keymap.textFor(24, shift: true), 'Q');
    });

    test('resolves U+ spellings inside symbol lists', () {
      expect(keymap.textFor(52), 'ç');
      expect(keymap.textFor(52, shift: true), 'Ç');
    });

    test('caps lock upper-cases letters but not digits', () {
      expect(keymap.textFor(38, capsLock: true), 'A');
      expect(keymap.textFor(10, capsLock: true), '1');
    });

    test('control keys produce keysyms but no text', () {
      expect(keymap.keysymFor(36), xkbKeysymReturn);
      expect(keymap.textFor(36), isNull);
      expect(keymap.keysymFor(111), xkbKeysymUp);
      expect(keymap.textFor(111), isNull);
    });

    test('unknown keycodes are NoSymbol', () {
      expect(keymap.keysymFor(200), xkbNoSymbol);
      expect(keymap.textFor(200), isNull);
    });

    test('text without both sections is rejected, not half-parsed', () {
      expect(WaylandXkbKeymap.parse('xkb_keymap { }'), isNull);
      expect(
        WaylandXkbKeymap.parse('xkb_keycodes { <A> = 9; };'),
        isNull,
      );
    });
  });

  group('WaylandXkbKeymap.usFallback', () {
    late WaylandXkbKeymap keymap;

    setUp(() => keymap = WaylandXkbKeymap.usFallback());

    test('says what it is', () {
      expect(keymap.source, 'evdev-us-fallback');
    });

    test('letters and shifted punctuation follow the US layout', () {
      // evdev KEY_A = 30, xkb keycode 38.
      expect(keymap.textFor(30 + 8), 'a');
      expect(keymap.textFor(30 + 8, shift: true), 'A');
      // evdev KEY_2 = 3 shifts to @ on US.
      expect(keymap.textFor(3 + 8), '2');
      expect(keymap.textFor(3 + 8, shift: true), '@');
    });

    test('named keys resolve to their keysyms', () {
      expect(keymap.keysymFor(28 + 8), xkbKeysymReturn); // KEY_ENTER
      expect(keymap.keysymFor(1 + 8), xkbKeysymEscape); // KEY_ESC
      expect(keymap.keysymFor(103 + 8), xkbKeysymUp); // KEY_UP
    });
  });

  group('WaylandModifiersState', () {
    test('effective state is the union of depressed, latched and locked', () {
      final state = WaylandModifiersState();
      expect(state.shift, isFalse);
      state.update(depressed: 0x01, latched: 0, locked: 0x02, group: 0);
      expect(state.shift, isTrue);
      expect(state.capsLock, isTrue);
      expect(state.control, isFalse);
      state.update(depressed: 0x04 | 0x08, latched: 0, locked: 0x40, group: 0);
      expect(state.control, isTrue);
      expect(state.alt, isTrue);
      expect(state.meta, isTrue);
      state.reset();
      expect(state.control, isFalse);
    });
  });
}
