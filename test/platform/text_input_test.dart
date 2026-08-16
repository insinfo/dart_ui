/// Typed text is what the platform says it is, never what a key code implies.
///
/// The rules asserted here are the ones every backend would otherwise have to
/// re-derive: which code units are text at all, and how a character delivered
/// in two pieces becomes one. Both were learned from a real bug - the numeric
/// keypad typing `abc` because `String.fromCharCode(VK_NUMPAD1)` is `a` - and
/// both are cheap to get wrong again.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

/// GRINNING FACE, the canonical astral character: U+1F600 is U+D83D U+DE00.
const int _emojiHigh = 0xD83D;
const int _emojiLow = 0xDE00;

void main() {
  group('a control character is not text', () {
    test('the four keys Windows also sends as WM_CHAR produce nothing', () {
      final assembler = TextInputAssembler();

      // Backspace, Tab, Enter, Escape. Every one of them arrives as a key
      // event too, which is where an editor acts on it; inserting it here
      // would put an unprintable code point into the document.
      expect(assembler.accept(0x08), isNull, reason: 'Backspace');
      expect(assembler.accept(0x09), isNull, reason: 'Tab');
      expect(assembler.accept(0x0D), isNull, reason: 'Enter');
      expect(assembler.accept(0x1B), isNull, reason: 'Escape');
    });

    test('Ctrl+letter arrives as 0x01-0x1A and inserts nothing', () {
      final assembler = TextInputAssembler();

      // Ctrl+A is 0x01, Ctrl+Z is 0x1A. A field that inserted these would put
      // U+0001 into the text every time somebody pressed Select All.
      for (int unit = 0x01; unit <= 0x1A; unit++) {
        expect(assembler.accept(unit), isNull, reason: 'Ctrl+$unit');
      }
    });

    test('the boundary is the Cc category, both halves of it', () {
      // U+001F is the last C0 control and U+0020 is a space, which *is* text.
      expect(isTextInputControlUnit(0x1F), isTrue);
      expect(isTextInputControlUnit(0x20), isFalse);
      expect(TextInputAssembler().accept(0x20), ' ');

      // U+007F DELETE and the C1 block are controls as well; U+00A0 is a
      // no-break space, which a Brazilian layout really can type.
      expect(isTextInputControlUnit(0x7F), isTrue);
      expect(isTextInputControlUnit(0x9F), isTrue);
      expect(isTextInputControlUnit(0xA0), isFalse);
      expect(TextInputAssembler().accept(0xA0), '\u00A0');
    });
  });

  group('a surrogate pair is one character, delivered in two messages', () {
    test('the high half is held and the low half completes it', () {
      final assembler = TextInputAssembler();

      expect(assembler.accept(_emojiHigh), isNull);
      expect(assembler.isPending, isTrue);
      expect(assembler.accept(_emojiLow), '\u{1F600}');
      expect(assembler.isPending, isFalse);
    });

    test('the completed character is one code point in two code units', () {
      final String? text = _feed(<int>[_emojiHigh, _emojiLow]).single;

      expect(text!.runes.length, 1);
      expect(text.length, 2, reason: 'still two UTF-16 units');
      expect(text.runes.single, 0x1F600);
    });

    test('an unpaired low surrogate is dropped rather than emitted', () {
      // Half a character is not a character, and emitting it would leave the
      // editor with an offset that TextEditingValue refuses.
      expect(TextInputAssembler().accept(_emojiLow), isNull);
    });

    test('a high surrogate followed by a letter drops the orphan', () {
      final assembler = TextInputAssembler();

      expect(assembler.accept(_emojiHigh), isNull);
      expect(
        assembler.accept(0x61),
        'a',
        reason: 'the letter is text; the orphaned half is not fused onto it',
      );
      expect(assembler.isPending, isFalse);
    });

    test('two high surrogates keep the newer one', () {
      final assembler = TextInputAssembler();
      const int other = 0xD83C; // the flag/symbol plane's lead unit

      assembler.accept(other);
      assembler.accept(_emojiHigh);

      expect(
        assembler.accept(_emojiLow),
        '\u{1F600}',
        reason: 'pairing with the stale lead would build a different emoji',
      );
    });

    test('reset forgets a half-delivered character', () {
      final assembler = TextInputAssembler()..accept(_emojiHigh);

      assembler.reset();

      expect(assembler.isPending, isFalse);
      expect(assembler.accept(_emojiLow), isNull);
    });
  });

  group('the event itself', () {
    test('carries text rather than a code, and refuses to be empty', () {
      final event = TextInputEvent(
        windowId: const NativeWindowId(1),
        generation: 1,
        timestamp: Duration.zero,
        text: 'ç',
      );

      expect(event.text, 'ç');
      expect(event.toString(), contains('U+00E7'));
      expect(
        () => TextInputEvent(
          windowId: const NativeWindowId(1),
          generation: 1,
          timestamp: Duration.zero,
          text: '',
        ),
        throwsA(isA<ArgumentError>()),
        reason: 'an empty insertion is a backend that should have emitted '
            'nothing at all',
      );
    });

    test('is an input event, so it carries the staleness stamps', () {
      final event = TextInputEvent(
        windowId: const NativeWindowId(7),
        generation: 3,
        timestamp: const Duration(milliseconds: 5),
        text: 'a',
      );

      expect(event, isA<PlatformInputEvent>());
      expect(event.windowId, const NativeWindowId(7));
      expect(event.generation, 3);
      expect(event.timestamp, const Duration(milliseconds: 5));
    });
  });

  group('the headless synthesizer speaks the same contract', () {
    test('typeText refuses what no backend may emit', () {
      final input = FakeTextInput();

      expect(() => input.typeText(''), throwsA(isA<ArgumentError>()));
      expect(
        () => input.typeText('\u0001'),
        throwsA(isA<ArgumentError>()),
        reason: 'Ctrl+A is not text',
      );
      expect(
        () => input.typeText(String.fromCharCode(_emojiHigh)),
        throwsA(isA<ArgumentError>()),
        reason: 'half a surrogate pair is not text',
      );
    });

    test('feedCodeUnit reproduces a UTF-16 stream one message at a time', () {
      final input = FakeTextInput();

      expect(input.feedCodeUnit(0x41)!.text, 'A');
      expect(input.feedCodeUnit(0x08), isNull, reason: 'Backspace');
      expect(input.feedCodeUnit(_emojiHigh), isNull);
      expect(input.feedCodeUnit(_emojiLow)!.text, '\u{1F600}');

      final events = input.feedCodeUnits(<int>[0x63, 0x0D, 0xE7]);
      expect(
        events.map((TextInputEvent event) => event.text).toList(),
        <String>['c', 'ç'],
        reason: 'the Enter in the middle is a key, not text',
      );
    });

    test('every synthesized event is stamped for the window it targets', () {
      final input = FakeTextInput(
        windowId: const NativeWindowId(4),
        generation: 9,
      );

      final event = input.typeText('a');

      expect(event.windowId, const NativeWindowId(4));
      expect(event.generation, 9);
      expect(input.typeText('b').timestamp, greaterThan(event.timestamp));
    });
  });
}

List<String?> _feed(List<int> units) {
  final assembler = TextInputAssembler();
  return units
      .map(assembler.accept)
      .where((String? text) => text != null)
      .toList();
}
