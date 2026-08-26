/// The X11 core-protocol keyboard map, tested on bytes.
///
/// Every test here builds a `GetKeyboardMapping` or `GetModifierMapping` reply
/// by hand and asserts what comes out. That is deliberate and it is the only
/// honest coverage available on a machine with no X server: the decoders in
/// `x11_keyboard.dart` are pure functions over a [Uint8List], and the reply an
/// X server sends is exactly those bytes, so a test that builds one is
/// exercising the production path rather than a stand-in for it.
///
/// **What this does not prove**: that libxcb hands those bytes over unchanged,
/// or that a real server's map for a real keyboard looks like the ones built
/// here. Both are FFI and neither can run on Windows; see `tool/
/// x11_backend_smoke.dart`, which does exercise them on a Linux session.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/backends/x11/x11_events.dart';
import 'package:dart_ui/src/backends/x11/x11_keyboard.dart';
import 'package:dart_ui/src/backends/x11/x11_protocol.dart';
import 'package:dart_ui/src/platform/input_events.dart';
import 'package:dart_ui/src/platform/keysyms.dart';
import 'package:test/test.dart';

/// A `GetKeyboardMapping` reply, exactly as the wire carries one.
Uint8List _keyboardReply(List<List<int>> perKeycode, {required int width}) {
  final int words = perKeycode.length * width;
  final bytes = Uint8List(x11ReplyHeaderBytes + words * 4);
  bytes[0] = 1; // Reply.
  bytes[1] = width; // keysyms-per-keycode.
  x11WriteU32(bytes, 4, words); // reply length, in 32-bit words.
  for (var k = 0; k < perKeycode.length; k++) {
    for (var i = 0; i < width; i++) {
      final List<int> list = perKeycode[k];
      x11WriteU32(
        bytes,
        x11ReplyHeaderBytes + (k * width + i) * 4,
        i < list.length ? list[i] : keysymNoSymbol,
      );
    }
  }
  return bytes;
}

/// A `GetModifierMapping` reply: eight rows of [width] keycodes.
Uint8List _modifierReply(List<List<int>> rows, {required int width}) {
  final bytes = Uint8List(x11ReplyHeaderBytes + width * 8);
  bytes[0] = 1;
  bytes[1] = width;
  x11WriteU32(bytes, 4, width * 2);
  for (var r = 0; r < 8; r++) {
    for (var i = 0; i < rows[r].length && i < width; i++) {
      bytes[x11ReplyHeaderBytes + r * width + i] = rows[r][i];
    }
  }
  return bytes;
}

// A small but real Brazilian-ABNT2-shaped fragment. Keycode 38 is the `a` key,
// 46 is the `ç` key (`ccedilla` unshifted, `Ccedilla` shifted), 49 is the one
// whose AltGr layer holds a dead key, 24 is `q`/`Q` with `slash` on AltGr, 87
// is keypad 1, and 64 is the left Alt.
const int _keyA = 38;
const int _keyCcedilla = 46;
const int _keyQ = 24;
const int _keyKp1 = 87;
const int _keyAltL = 64;
const int _keyAltGr = 108;
const int _keyShiftL = 50;
const int _keySuperL = 133;
const int _keyNumLock = 77;

const int _keysymCcedilla = 0xe7;
const int _keysymCapitalCcedilla = 0xc7;
const int _keysymDeadAcute = 0xfe51;
const int _keysymKp1 = 0xffb1;
const int _keysymKpEnd = 0xff9c;

X11KeyboardMapping _abnt2Mapping() {
  return X11KeyboardMapping.decodeReply(
    _keyboardReply(
      <List<int>>[
        // 24: q Q, AltGr layer: / (slash) and nothing.
        <int>[0x71, 0x51, 0x2f, keysymNoSymbol],
        // 25..37 are filler so that 38 lands where it should.
        for (var i = 25; i <= 37; i++) <int>[keysymNoSymbol],
        // 38: the server lists ONE symbol - the alphabetic-implied-capital rule
        // has to make Shift work on this key.
        <int>[0x61],
        for (var i = 39; i <= 45; i++) <int>[keysymNoSymbol],
        // 46: ccedilla / Ccedilla, and a dead key on the AltGr layer.
        <int>[_keysymCcedilla, _keysymCapitalCcedilla, _keysymDeadAcute],
        for (var i = 47; i <= 49; i++) <int>[keysymNoSymbol],
        // 50: Shift_L.
        <int>[keysymShiftL],
        for (var i = 51; i <= 63; i++) <int>[keysymNoSymbol],
        // 64: Alt_L.
        <int>[keysymAltL],
        for (var i = 65; i <= 76; i++) <int>[keysymNoSymbol],
        // 77: Num_Lock.
        <int>[keysymNumLock],
        for (var i = 78; i <= 86; i++) <int>[keysymNoSymbol],
        // 87: KP_End / KP_1 - the pair NumLock inverts.
        <int>[_keysymKpEnd, _keysymKp1],
        for (var i = 88; i <= 107; i++) <int>[keysymNoSymbol],
        // 108: ISO_Level3_Shift, which is what AltGr is on a modern layout.
        <int>[keysymIsoLevel3Shift],
        for (var i = 109; i <= 132; i++) <int>[keysymNoSymbol],
        // 133: Super_L.
        <int>[keysymSuperL],
      ],
      width: 4,
    ),
    firstKeycode: _keyQ,
  )!;
}

X11ModifierMapping _abnt2Modifiers() {
  return X11ModifierMapping.decodeReply(
    _modifierReply(
      <List<int>>[
        <int>[_keyShiftL, 62], // Shift
        <int>[66], // Lock (Caps_Lock - not in the map fragment above)
        <int>[37, 105], // Control
        <int>[_keyAltL], // Mod1 - Alt
        <int>[_keyNumLock], // Mod2 - NumLock
        <int>[], // Mod3
        <int>[_keySuperL], // Mod4 - Super
        <int>[_keyAltGr], // Mod5 - AltGr
      ],
      width: 2,
    ),
  )!;
}

void main() {
  group('X11KeyboardMapping.decodeReply', () {
    test('reads keysyms-per-keycode and the keysym array off the wire', () {
      final mapping = X11KeyboardMapping.decodeReply(
        _keyboardReply(
          <List<int>>[
            <int>[0x61, 0x41],
            <int>[0x62, 0x42],
            <int>[0x63, 0x43],
          ],
          width: 2,
        ),
        firstKeycode: 38,
      );

      expect(mapping, isNotNull);
      expect(mapping!.keysymsPerKeycode, 2);
      expect(mapping.firstKeycode, 38);
      expect(mapping.keycodeCount, 3);
      expect(mapping.lastKeycode, 40);
      expect(mapping.rawKeysym(39, 0), 0x62);
      expect(mapping.rawKeysym(40, 1), 0x43);
    });

    test('a keycode outside the described range resolves to NoSymbol', () {
      final mapping = X11KeyboardMapping.decodeReply(
        _keyboardReply(<List<int>>[
          <int>[0x61, 0x41]
        ], width: 2),
        firstKeycode: 38,
      )!;

      expect(mapping.rawKeysym(37, 0), keysymNoSymbol);
      expect(mapping.rawKeysym(200, 0), keysymNoSymbol);
      expect(mapping.keysymFor(200), keysymNoSymbol);
      expect(mapping.textFor(200), isNull);
    });

    test('refuses a truncated reply rather than decoding half a map', () {
      final Uint8List full = _keyboardReply(
        <List<int>>[
          <int>[0x61, 0x41],
          <int>[0x62, 0x42],
        ],
        width: 2,
      );
      final Uint8List truncated = full.sublist(0, full.length - 4);

      expect(
          X11KeyboardMapping.decodeReply(truncated, firstKeycode: 38), isNull);
    });

    test('refuses a reply whose length is not a multiple of the width', () {
      final Uint8List bytes = _keyboardReply(
        <List<int>>[
          <int>[0x61, 0x41]
        ],
        width: 2,
      );
      x11WriteU32(bytes, 4, 3); // three words for a width of two.

      expect(X11KeyboardMapping.decodeReply(bytes, firstKeycode: 38), isNull);
    });

    test('refuses a reply that claims zero keysyms per keycode', () {
      final Uint8List bytes = _keyboardReply(
        <List<int>>[
          <int>[0x61, 0x41]
        ],
        width: 2,
      );
      bytes[1] = 0;

      expect(X11KeyboardMapping.decodeReply(bytes, firstKeycode: 38), isNull);
    });
  });

  group('the protocol padding rules', () {
    test('one alphabetic keysym becomes the lower/upper pair', () {
      // The classic way Shift stops working on half a keyboard: a server that
      // lists `a` alone for a key means `a` and `A`, not `a` and nothing.
      final mapping = _abnt2Mapping();

      expect(mapping.keysymFor(_keyA), 0x61);
      expect(mapping.keysymFor(_keyA, shift: true), 0x41);
      expect(mapping.textFor(_keyA, shift: true), 'A');
    });

    test('one non-alphabetic keysym does not grow a second level', () {
      final mapping = X11KeyboardMapping.decodeReply(
        _keyboardReply(<List<int>>[
          <int>[keysymReturn]
        ], width: 4),
        firstKeycode: 36,
      )!;

      expect(mapping.groupOf(36).level2, keysymNoSymbol);
      expect(mapping.keysymFor(36, shift: true), keysymReturn);
    });

    test('a list of two repeats into group two', () {
      // A keyboard with no AltGr layer must still answer group 2 sensibly,
      // rather than producing nothing when Mode_switch is held.
      final mapping = X11KeyboardMapping.decodeReply(
        _keyboardReply(<List<int>>[
          <int>[0x61, 0x41]
        ], width: 2),
        firstKeycode: 38,
      )!;

      expect(mapping.keysymFor(38, group2: true), 0x61);
      expect(mapping.keysymFor(38, group2: true, shift: true), 0x41);
    });

    test('group two is reached independently of group one', () {
      final mapping = _abnt2Mapping();

      expect(mapping.keysymFor(_keyCcedilla), _keysymCcedilla);
      expect(mapping.keysymFor(_keyCcedilla, group2: true), _keysymDeadAcute);
      expect(mapping.keysymFor(_keyQ, group2: true), 0x2f);
    });
  });

  group('the protocol keysym selection rules', () {
    test('CapsLock upper-cases the symbol rather than selecting level two', () {
      // The distinction matters on a layout whose shifted level is not that
      // letter's capital; here it is observable as `ç` upper-casing to `Ç`.
      final mapping = _abnt2Mapping();

      expect(mapping.keysymFor(_keyCcedilla, capsLock: true),
          _keysymCapitalCcedilla);
      expect(mapping.textFor(_keyA, capsLock: true), 'A');
    });

    test('CapsLock with Shift still resolves through level two', () {
      final mapping = _abnt2Mapping();

      expect(
        mapping.keysymFor(_keyCcedilla, capsLock: true, shift: true),
        _keysymCapitalCcedilla,
      );
    });

    test('ShiftLock selects the shifted symbol outright', () {
      // Not the same as CapsLock: a digit row under ShiftLock types symbols.
      final mapping = X11KeyboardMapping.decodeReply(
        _keyboardReply(<List<int>>[
          <int>[0x31, 0x21] // 1 and !
        ], width: 2),
        firstKeycode: 10,
      )!;

      expect(mapping.keysymFor(10, shiftLock: true), 0x21);
      expect(mapping.keysymFor(10, capsLock: true), 0x31);
    });

    test('NumLock inverts the keypad pair and Shift takes it back', () {
      final mapping = _abnt2Mapping();

      expect(mapping.keysymFor(_keyKp1), _keysymKpEnd);
      expect(mapping.keysymFor(_keyKp1, numLock: true), _keysymKp1);
      expect(
        mapping.keysymFor(_keyKp1, numLock: true, shift: true),
        _keysymKpEnd,
      );
    });

    test('NumLock is tested before CapsLock', () {
      // A keypad key under NumLock is a digit whatever CapsLock says; testing
      // in the other order upper-cases the digit's keysym into nothing useful.
      final mapping = _abnt2Mapping();

      expect(
        mapping.keysymFor(_keyKp1, numLock: true, capsLock: true),
        _keysymKp1,
      );
    });

    test('NumLock does not touch a key whose level two is not a keypad symbol',
        () {
      final mapping = _abnt2Mapping();

      expect(mapping.keysymFor(_keyA, numLock: true), 0x61);
    });
  });

  group('X11ModifierMapping', () {
    test('decodes eight rows and finds the mask a keycode is bound to', () {
      final modifiers = _abnt2Modifiers();

      expect(modifiers.keycodesPerModifier, 2);
      expect(modifiers.keycodesForRow(0), <int>[_keyShiftL, 62]);
      expect(modifiers.keycodesForRow(3), <int>[_keyAltL]);
      expect(modifiers.maskOfKeycode(_keyAltL), x11ModMod1);
      expect(modifiers.maskOfKeycode(_keyAltGr), x11ModMod5);
      expect(modifiers.maskOfKeycode(_keyA), 0);
    });

    test('a zero keycode is an empty slot, not keycode zero', () {
      final modifiers = _abnt2Modifiers();

      expect(modifiers.keycodesForRow(5), isEmpty);
      expect(modifiers.maskOfKeycode(0), 0);
    });

    test('a reply with no keycodes per modifier decodes to the empty map', () {
      final Uint8List bytes = _modifierReply(
        List<List<int>>.filled(8, const <int>[]),
        width: 1,
      );
      bytes[1] = 0;

      expect(X11ModifierMapping.decodeReply(bytes)!.keycodesPerModifier, 0);
    });

    test('refuses a truncated reply', () {
      final Uint8List full = _modifierReply(
        List<List<int>>.filled(8, const <int>[1]),
        width: 2,
      );

      expect(X11ModifierMapping.decodeReply(full.sublist(0, 40)), isNull);
    });
  });

  group('X11ModifierSemantics.resolve', () {
    test('finds Alt, Super, NumLock and AltGr by the keysyms they produce', () {
      final semantics = X11ModifierSemantics.resolve(
        _abnt2Modifiers(),
        _abnt2Mapping(),
      );

      expect(semantics.altMask, x11ModMod1);
      expect(semantics.superMask, x11ModMod4);
      expect(semantics.numLockMask, x11ModMod2);
      expect(semantics.modeSwitchMask, x11ModMod5);
      expect(semantics.lockIsCapsLock, isTrue);
      expect(semantics.lockIsShiftLock, isFalse);
    });

    test('follows a remapped keyboard instead of assuming Mod1 is Alt', () {
      // This is the case that breaks Alt+Tab in clients that hard-code the
      // conventional assignment: an `~/.Xmodmap` that swapped Alt and Super.
      final mapping = X11KeyboardMapping.fromLists(
        <List<int>>[
          <int>[keysymSuperL],
          <int>[keysymAltL],
        ],
        firstKeycode: 64,
      );
      final modifiers = X11ModifierMapping.fromRows(<List<int>>[
        <int>[],
        <int>[],
        <int>[],
        <int>[64], // Mod1 holds Super_L
        <int>[],
        <int>[],
        <int>[65], // Mod4 holds Alt_L
        <int>[],
      ]);

      final semantics = X11ModifierSemantics.resolve(modifiers, mapping);

      expect(semantics.superMask, x11ModMod1);
      expect(semantics.altMask, x11ModMod4);
      expect(semantics.describe(), contains('alt=Mod4'));
      expect(semantics.describe(), contains('super=Mod1'));
    });

    test('reads Mode_switch parked on a modifier key second level', () {
      // Several stock layouts spell AltGr for core clients by putting
      // `Mode_switch` on level 2 of the key whose level 1 is ISO_Level3_Shift.
      final mapping = X11KeyboardMapping.fromLists(
        <List<int>>[
          <int>[keysymIsoLevel3Shift, keysymModeSwitch],
        ],
        firstKeycode: 108,
      );
      final modifiers = X11ModifierMapping.fromRows(<List<int>>[
        <int>[], <int>[], <int>[], <int>[], //
        <int>[], <int>[], <int>[], <int>[108],
      ]);

      expect(
        X11ModifierSemantics.resolve(modifiers, mapping).modeSwitchMask,
        x11ModMod5,
      );
    });

    test('never binds Alt to Shift, Lock or Control', () {
      // A layout that puts Alt_L on the Shift row would otherwise make every
      // capital letter look like an Alt shortcut.
      final mapping = X11KeyboardMapping.fromLists(
        <List<int>>[
          <int>[keysymAltL]
        ],
        firstKeycode: 50,
      );
      final modifiers = X11ModifierMapping.fromRows(<List<int>>[
        <int>[50], <int>[], <int>[], <int>[], //
        <int>[], <int>[], <int>[], <int>[],
      ]);

      expect(X11ModifierSemantics.resolve(modifiers, mapping).altMask, 0);
    });

    test('a Lock row naming Shift_Lock is ShiftLock, not CapsLock', () {
      final mapping = X11KeyboardMapping.fromLists(
        <List<int>>[
          <int>[keysymShiftLock]
        ],
        firstKeycode: 66,
      );
      final modifiers = X11ModifierMapping.fromRows(<List<int>>[
        <int>[], <int>[66], <int>[], <int>[], //
        <int>[], <int>[], <int>[], <int>[],
      ]);

      final semantics = X11ModifierSemantics.resolve(modifiers, mapping);

      expect(semantics.lockIsShiftLock, isTrue);
      expect(semantics.lockIsCapsLock, isFalse);
      expect(semantics.describe(), contains('lock=ShiftLock'));
    });

    test('falls back to the conventional assignment when nothing is known', () {
      expect(
        X11ModifierSemantics.resolve(X11ModifierMapping.empty, null),
        same(X11ModifierSemantics.conventional),
      );
      expect(X11ModifierSemantics.conventional.altMask, x11ModMod1);
    });
  });

  group('X11KeyboardState', () {
    test('reads one state word into the protocol selection rules', () {
      final state = X11KeyboardState(
        keyboard: _abnt2Mapping(),
        modifiers: _abnt2Modifiers(),
        source: 'core-keyboard-mapping',
      );

      expect(state.hasKeymap, isTrue);
      expect(state.textFor(_keyA, 0), 'a');
      expect(state.textFor(_keyA, x11ModShift), 'A');
      expect(state.textFor(_keyCcedilla, 0), 'ç');
      expect(state.textFor(_keyCcedilla, x11ModShift), 'Ç');
      expect(state.textFor(_keyCcedilla, x11ModLock), 'Ç');
      // AltGr - Mod5 on this map - reaches the second group, whose symbol here
      // is a dead key and therefore has no text of its own.
      expect(state.keysymFor(_keyCcedilla, x11ModMod5), _keysymDeadAcute);
      expect(state.textFor(_keyCcedilla, x11ModMod5), isNull);
      expect(state.textFor(_keyQ, x11ModMod5), '/');
    });

    test('with no map at all, every keysym is NoSymbol and no text is made',
        () {
      final state = X11KeyboardState();

      expect(state.hasKeymap, isFalse);
      expect(state.keysymFor(_keyA, 0), keysymNoSymbol);
      expect(state.textFor(_keyA, 0), isNull);
    });

    test('turns a state word into the framework modifier set', () {
      final state = X11KeyboardState(
        keyboard: _abnt2Mapping(),
        modifiers: _abnt2Modifiers(),
      );

      expect(state.modifierSetOf(0), isEmpty);
      expect(
        state.modifierSetOf(x11ModShift | x11ModControl),
        <KeyModifier>{KeyModifier.shift, KeyModifier.control},
      );
      expect(state.modifierSetOf(x11ModMod1), <KeyModifier>{KeyModifier.alt});
      // Super and the historical Meta both arrive as KeyModifier.meta: the
      // framework has one, and a shortcut bound to it must fire for whichever
      // of the two this keyboard reports.
      expect(state.modifierSetOf(x11ModMod4), <KeyModifier>{KeyModifier.meta});
      expect(
        state.modifierSetOf(x11ModMod2 | x11ModLock),
        <KeyModifier>{KeyModifier.numLock, KeyModifier.capsLock},
      );
      // Mod5 is AltGr here, which is not one of the framework's modifiers.
      expect(state.modifierSetOf(x11ModMod5), isEmpty);
    });

    test('adopt re-resolves the semantics, which is what a remap changes', () {
      final state = X11KeyboardState();
      expect(state.altOf(x11ModMod1), isTrue); // conventional fallback

      state.adopt(
        keyboard: X11KeyboardMapping.fromLists(
          <List<int>>[
            <int>[keysymAltL]
          ],
          firstKeycode: 133,
        ),
        modifiers: X11ModifierMapping.fromRows(<List<int>>[
          <int>[], <int>[], <int>[], <int>[], //
          <int>[], <int>[], <int>[133], <int>[],
        ]),
        source: 'core-keyboard-mapping',
      );

      expect(state.source, 'core-keyboard-mapping');
      expect(state.altOf(x11ModMod1), isFalse);
      expect(state.altOf(x11ModMod4), isTrue);
    });
  });

  group('X11KeyRepeatFilter', () {
    List<({int type, int detail, bool repeat})> run(
      List<X11RawEvent> events, {
      bool detectable = false,
      bool flush = true,
    }) {
      final filter = X11KeyRepeatFilter(detectableAutoRepeat: detectable);
      final out = <({int type, int detail, bool repeat})>[];
      void deliver(X11RawEvent event) => out.add((
            type: event.type,
            detail: event.detail,
            repeat: event.repeat,
          ));
      for (final X11RawEvent event in events) {
        filter.accept(event, deliver);
      }
      if (flush) filter.flush(deliver);
      return out;
    }

    X11RawEvent key(int type, int detail, int timestamp) => X11RawEvent()
      ..type = type
      ..detail = detail
      ..timestamp = timestamp
      ..window = 0x400;

    test('a release followed by a press at the same time is one repeat', () {
      // The classic wire signature of auto-repeat without
      // DetectableAutoRepeat: the server stamps both edges from the same tick.
      final out = run(<X11RawEvent>[
        key(xcbKeyPress, 38, 1000),
        key(xcbKeyRelease, 38, 1050),
        key(xcbKeyPress, 38, 1050),
        key(xcbKeyRelease, 38, 1100),
        key(xcbKeyPress, 38, 1100),
        key(xcbKeyRelease, 38, 2000),
      ]);

      expect(out, <({int type, int detail, bool repeat})>[
        (type: xcbKeyPress, detail: 38, repeat: false),
        (type: xcbKeyPress, detail: 38, repeat: true),
        (type: xcbKeyPress, detail: 38, repeat: true),
        (type: xcbKeyRelease, detail: 38, repeat: false),
      ]);
    });

    test('a genuine release is delivered when the next event is not its press',
        () {
      final out = run(<X11RawEvent>[
        key(xcbKeyPress, 38, 1000),
        key(xcbKeyRelease, 38, 1100),
        key(xcbKeyPress, 39, 1200),
      ]);

      expect(out.map((e) => (e.type, e.detail)), <(int, int)>[
        (xcbKeyPress, 38),
        (xcbKeyRelease, 38),
        (xcbKeyPress, 39),
      ]);
      expect(out.every((e) => !e.repeat), isTrue);
    });

    test('a press of the same key at a different time is not a repeat', () {
      final out = run(<X11RawEvent>[
        key(xcbKeyRelease, 38, 1000),
        key(xcbKeyPress, 38, 1001),
      ]);

      expect(out.map((e) => (e.type, e.repeat)), <(int, bool)>[
        (xcbKeyRelease, false),
        (xcbKeyPress, false),
      ]);
    });

    test('a non-key event still releases the deferred release, in order', () {
      final out = run(<X11RawEvent>[
        key(xcbKeyRelease, 38, 1000),
        key(xcbMotionNotify, 0, 1001),
      ]);

      expect(out.map((e) => e.type), <int>[xcbKeyRelease, xcbMotionNotify]);
    });

    test('flush delivers a release that ended the pump', () {
      final filter = X11KeyRepeatFilter();
      final out = <int>[];
      filter.accept(key(xcbKeyRelease, 38, 1000), (e) => out.add(e.type));
      expect(out, isEmpty);
      expect(filter.isHolding, isTrue);

      filter.flush((e) => out.add(e.type));

      expect(out, <int>[xcbKeyRelease]);
      expect(filter.isHolding, isFalse);
    });

    test('cancel forgets the deferred release without delivering it', () {
      final filter = X11KeyRepeatFilter();
      final out = <int>[];
      filter.accept(key(xcbKeyRelease, 38, 1000), (e) => out.add(e.type));

      filter.cancel();
      filter.flush((e) => out.add(e.type));

      expect(out, isEmpty);
      expect(filter.isHolding, isFalse);
    });

    test('a release for another window does not cancel a held one', () {
      final filter = X11KeyRepeatFilter();
      final out = <(int, int)>[];
      void deliver(X11RawEvent e) => out.add((e.type, e.window));
      filter.accept(
        X11RawEvent()
          ..type = xcbKeyRelease
          ..detail = 38
          ..timestamp = 1000
          ..window = 0x400,
        deliver,
      );
      filter.accept(
        X11RawEvent()
          ..type = xcbKeyPress
          ..detail = 38
          ..timestamp = 1000
          ..window = 0x500,
        deliver,
      );
      filter.flush(deliver);

      expect(out, <(int, int)>[
        (xcbKeyRelease, 0x400),
        (xcbKeyPress, 0x500),
      ]);
    });

    test('with DetectableAutoRepeat the filter is a pass-through', () {
      final out = run(
        <X11RawEvent>[
          key(xcbKeyPress, 38, 1000),
          key(xcbKeyRelease, 38, 1050),
          key(xcbKeyPress, 38, 1050),
        ],
        detectable: true,
      );

      expect(out.length, 3);
      expect(out.every((e) => !e.repeat), isTrue);
    });
  });

  group('x11ReadU32 and x11WriteU32', () {
    test('round-trip in the host order the connection negotiated', () {
      final bytes = Uint8List(8);
      x11WriteU32(bytes, 0, 0x01020304);
      x11WriteU32(bytes, 4, 0xffffffff);

      expect(x11ReadU32(bytes, 0), 0x01020304);
      expect(x11ReadU32(bytes, 4), 0xffffffff);
    });
  });
}
