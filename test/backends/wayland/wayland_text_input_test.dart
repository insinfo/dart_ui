/// `zwp_text_input_v3`, driven over a fake client instead of a compositor.
///
/// The shape `wayland_drag_drop_test.dart` established: everything with a
/// protocol rule in it lives in [WaylandTextInputManager], the manager talks to
/// a [WaylandTextInputClient], and a fake one turns every rule into an
/// assertion that runs on a machine with no Wayland at all.
///
/// The two rules that are the whole reason this file exists:
///
///  1. **The serial is a commit count.** `commit` carries no argument; the
///     compositor counts commits and echoes the count in `done`. A `done` whose
///     serial is behind describes a state the client has replaced, and its
///     `delete_surrounding_text` is measured in bytes against a surrounding
///     text that no longer applies. Applying it deletes the wrong characters -
///     which looks like an IME that occasionally eats a letter and is nearly
///     impossible to attribute after the fact.
///  2. **The order of application is the protocol's**, not the order the events
///     arrived in: remove the preedit, delete, commit, then the new preedit.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/wayland/wayland_protocol.dart';
import 'package:dart_ui/src/backends/wayland/wayland_text_input.dart';
import 'package:test/test.dart';

void main() {
  group('offsets cross the UTF-8 boundary without drifting', () {
    test('a byte offset and a code-unit offset agree on ASCII', () {
      expect(waylandUtf8OffsetOf('hello', 3), 3);
      expect(waylandUtf16OffsetOf('hello', 3), 3);
    });

    test('an accented letter is two bytes and one code unit', () {
      // 'ç' is U+00E7: two UTF-8 bytes, one UTF-16 unit. A bridge that used
      // the byte count as a character count would underline one letter too
      // many on every Portuguese word.
      expect(waylandUtf8OffsetOf('ç', 1), 2);
      expect(waylandUtf16OffsetOf('ç', 2), 1);
    });

    test('a CJK character is three bytes and one code unit', () {
      expect(waylandUtf8OffsetOf('日本', 2), 6);
      expect(waylandUtf16OffsetOf('日本', 3), 1);
    });

    test('an astral character is four bytes and two code units', () {
      const String emoji = '\u{1F600}';
      expect(emoji.length, 2, reason: 'a surrogate pair');
      expect(waylandUtf8OffsetOf(emoji, 2), 4);
      expect(waylandUtf16OffsetOf(emoji, 4), 2);
    });

    test('a byte offset inside a character rounds down to its start', () {
      // An input method computing a deletion from its own snapshot can name a
      // boundary this document does not have; the alternative to rounding is
      // throwing inside an event handler.
      expect(waylandUtf16OffsetOf('aç', 2), 1);
      expect(waylandUtf16OffsetOf('\u{1F600}', 2), 0);
    });

    test('surrounding text is clipped around the caret, never split mid-'
        'character', () {
      final String long = 'a' * 5000;
      final ({String text, int cursor, int anchor}) clipped =
          waylandClipSurroundingText(long, 2500, 2500);

      expect(
        clipped.text.length,
        lessThan(zwpTextInputV3SurroundingTextMaxBytes),
        reason: 'the protocol disconnects a client that oversteps 4000 bytes; '
            'it does not warn it',
      );
      expect(
        clipped.text.length,
        greaterThan(0),
        reason: 'clipped around the caret, not emptied',
      );
      expect(
        long.substring(2500 - clipped.cursor, 2500),
        clipped.text.substring(0, clipped.cursor),
        reason: 'the offsets describe the clipped string, which is what the '
            'protocol will see',
      );
    });

    test('a short document is sent whole', () {
      final ({String text, int cursor, int anchor}) clipped =
          waylandClipSurroundingText('hello', 2, 5);
      expect(clipped.text, 'hello');
      expect(clipped.cursor, 2);
      expect(clipped.anchor, 5);
    });

    test('content hints and purposes map one to one onto the protocol', () {
      expect(
        waylandContentPurposeValue(ImeContentPurpose.password),
        zwpTextInputV3ContentPurposePassword,
      );
      expect(
        waylandContentPurposeValue(ImeContentPurpose.normal),
        zwpTextInputV3ContentPurposeNormal,
      );
      expect(
        waylandContentHintBits(<ImeContentHint>{
          ImeContentHint.hiddenText,
          ImeContentHint.sensitiveData,
        }),
        zwpTextInputV3ContentHintHiddenText |
            zwpTextInputV3ContentHintSensitiveData,
      );
      expect(waylandContentHintBits(const <ImeContentHint>{}), 0);
    });
  });

  group('the state machine', () {
    late _FakeWire wire;
    late WaylandTextInputManager manager;
    late _RecordingClient client;

    setUp(() {
      wire = _FakeWire();
      manager = WaylandTextInputManager(wire);
      client = _RecordingClient();
      manager.clientForSurface = (int surfaceId) =>
          surfaceId == _surfaceId ? client : null;
    });

    /// Focus the surface and enable, which is what a field taking focus does.
    void focusAndEnable() {
      manager.onEnter(_surfaceId);
      manager.enable(client);
    }

    test('enable sends the whole state and one commit', () {
      client
        ..text = 'hello'
        ..cursor = 5;
      focusAndEnable();

      expect(wire.calls, contains('enable'));
      expect(
        wire.calls.where((String call) => call == 'commit').length,
        1,
        reason: 'one commit for the whole batch: the requests before it are '
            'staged and do nothing until it arrives',
      );
      expect(manager.commitCount, 1);
      expect(
        wire.calls.indexOf('enable'),
        lessThan(wire.calls.indexOf('commit')),
      );
      expect(
        wire.calls,
        contains('surrounding("hello",5,5)'),
        reason: 'enable resets everything the compositor holds to the protocol '
            'defaults, so the full state has to follow it - a delta would '
            'leave this field described by the previous one',
      );
      expect(wire.calls, contains('cursorRect(0,0,1,16)'));
    });

    test('an empty document sends no surrounding text after enable', () {
      focusAndEnable();

      expect(
        wire.calls.any((String call) => call.startsWith('surrounding')),
        isFalse,
        reason: 'the protocol default after enable is exactly an empty '
            'surrounding text with the cursor at zero; re-stating it would be '
            'a request that changes nothing',
      );
      expect(manager.commitCount, 1, reason: 'the content type still changed');
    });

    test('a state push that changes nothing sends no commit', () {
      focusAndEnable();
      wire.calls.clear();

      manager.updateEditingState();

      expect(
        wire.calls,
        isEmpty,
        reason: 'a commit bumps the count every done is compared against, so '
            'committing for nothing leaves the client permanently ahead of '
            'the compositor and makes every deletion look stale',
      );
      expect(manager.commitCount, 1);
    });

    test('a moved caret sends a new rectangle and one more commit', () {
      focusAndEnable();
      wire.calls.clear();
      client.caret = const Rect.fromLTWH(40, 0, 1, 16);

      manager.updateEditingState();

      expect(wire.calls, contains('cursorRect(40,0,1,16)'));
      expect(wire.calls, contains('commit'));
      expect(manager.commitCount, 2);
    });

    test('a preedit reaches the client with its caret in code units', () {
      focusAndEnable();

      manager
        ..onPreeditString('日本', 3, 3)
        ..onDone(manager.commitCount);

      expect(client.composition!.text, '日本');
      expect(
        client.composition!.cursorStart,
        1,
        reason: 'byte offset 3 is one three-byte character in',
      );
      expect(manager.isComposing, isTrue);
    });

    test('cursor_begin == -1 is a request to hide the caret, not a missing '
        'value', () {
      focusAndEnable();

      manager
        ..onPreeditString('abc', -1, -1)
        ..onDone(manager.commitCount);

      expect(client.composition!.hasHiddenCursor, isTrue);
    });

    test('a commit string ends the composition and inserts text', () {
      focusAndEnable();
      manager
        ..onPreeditString('にほん', 9, 9)
        ..onDone(manager.commitCount);
      client.log.clear();

      manager
        ..onCommitString('日本')
        ..onDone(manager.commitCount);

      expect(client.log, <String>[
        'composition:',
        'commit:日本',
      ]);
      expect(
        manager.isComposing,
        isFalse,
        reason: 'the preedit was removed before the commit, which is step 1 of '
            'the protocol order',
      );
    });

    test('one done applies delete, commit and preedit in the protocol order',
        () {
      focusAndEnable();
      client.text = 'hello';
      client.cursor = 5;
      manager.updateEditingState();
      manager
        ..onPreeditString('xy', 4, 4)
        ..onDone(manager.commitCount);
      client.log.clear();

      manager
        ..onDeleteSurroundingText(2, 0)
        ..onCommitString('LO')
        ..onPreeditString('z', 1, 1)
        ..onDone(manager.commitCount);

      expect(client.log, <String>[
        // 1. the old preedit goes, so the deletion is measured against the
        //    document and not against provisional text;
        'composition:',
        // 2. the deletion, in code units;
        'delete:2/0',
        // 3. the commit;
        'commit:LO',
        // 4. and only then the new preedit.
        'composition:z',
      ]);
    });

    test('a stale done keeps its text and discards its deletion', () {
      focusAndEnable();
      client.text = 'hello';
      client.cursor = 5;
      manager.updateEditingState();
      final int staleSerial = manager.commitCount;

      // The client moves on - a keystroke of its own - before the compositor's
      // answer to the previous state arrives.
      client.cursor = 3;
      manager.updateEditingState();
      expect(manager.commitCount, greaterThan(staleSerial));
      client.log.clear();

      manager
        ..onDeleteSurroundingText(2, 0)
        ..onCommitString('X')
        ..onDone(staleSerial);

      expect(
        client.log,
        <String>['commit:X'],
        reason: 'the commit string is absolute and stays correct; the deletion '
            'is byte lengths around a cursor in a surrounding text the client '
            'has already replaced, and applying it deletes the wrong '
            'characters',
      );
      expect(manager.lastDoneSerial, staleSerial);
    });

    test('pending state is emptied by a done, applied or not', () {
      focusAndEnable();
      manager
        ..onCommitString('a')
        ..onDone(manager.commitCount);
      client.log.clear();

      // A second done with nothing staged must not re-apply the first.
      manager.onDone(manager.commitCount);

      expect(client.log, isEmpty);
    });

    test('an empty preedit ends the composition', () {
      focusAndEnable();
      manager
        ..onPreeditString('ab', 2, 2)
        ..onDone(manager.commitCount);
      client.log.clear();

      manager
        ..onPreeditString('', 0, 0)
        ..onDone(manager.commitCount);

      expect(client.log, <String>['composition:']);
      expect(manager.isComposing, isFalse);
    });

    test('a new preedit replacing an old one is one update, not two', () {
      focusAndEnable();
      manager
        ..onPreeditString('a', 1, 1)
        ..onDone(manager.commitCount);
      client.log.clear();

      manager
        ..onPreeditString('ab', 2, 2)
        ..onDone(manager.commitCount);

      expect(
        client.log,
        <String>['composition:ab'],
        reason: 'clearing first would push a second undo entry, and a Japanese '
            'conversion the user experienced as one action would take a dozen '
            'Ctrl+Z to undo',
      );
    });

    test('leave abandons the composition rather than committing it', () {
      focusAndEnable();
      manager
        ..onPreeditString('ab', 2, 2)
        ..onDone(manager.commitCount);
      client.log.clear();

      manager.onLeave(_surfaceId);

      expect(
        client.log,
        <String>['composition:'],
        reason: 'the characters were provisional and the user went elsewhere; '
            'committing them inserts text nobody accepted',
      );
      expect(manager.focusedSurfaceId, 0);
      expect(manager.isEnabled, isFalse);
    });

    test('enter re-sends the whole state, because enter reset it', () {
      focusAndEnable();
      final int before = manager.commitCount;
      wire.calls.clear();

      manager.onEnter(_surfaceId);

      expect(wire.calls, contains('enable'));
      expect(manager.commitCount, greaterThan(before));
    });

    test('disable turns it off and drops the preedit', () {
      focusAndEnable();
      manager
        ..onPreeditString('ab', 2, 2)
        ..onDone(manager.commitCount);
      client.log.clear();
      wire.calls.clear();

      manager.disable();

      expect(client.log, <String>['composition:']);
      expect(wire.calls, containsAllInOrder(<String>['disable', 'commit']));
      expect(manager.isEnabled, isFalse);
    });

    test('a done for a client that went away reaches nobody', () {
      focusAndEnable();
      manager.forget(client);
      client.log.clear();

      expect(
        manager.onDone(manager.commitCount),
        isFalse,
        reason: 'nothing was applied, which is what a caller counts',
      );
    });

    test('a sensitive field sends no surrounding text', () {
      client
        ..text = 'hunter2'
        ..cursor = 7
        ..configuration = TextInputConfiguration.password;
      focusAndEnable();

      expect(
        wire.calls.any((String call) => call.contains('hunter2')),
        isFalse,
        reason: 'handing a password to an input-method process is the same '
            'leak as putting it on the clipboard',
      );
      expect(
        wire.calls,
        contains('contentType(${zwpTextInputV3ContentHintHiddenText | zwpTextInputV3ContentHintSensitiveData},'
            '$zwpTextInputV3ContentPurposePassword)'),
      );
    });
  });

  group('the port half', () {
    test('a backend with no protocol refuses by name', () {
      final wire = _FakeWire(supported: false);
      final backend = WaylandTextInputBackend(WaylandTextInputManager(wire));

      expect(backend.supportsComposition, isFalse);
      expect(
        backend.usesSurroundingText,
        isTrue,
        reason: 'the protocol is what put surrounding text on the port',
      );
    });
  });
}

const int _surfaceId = 42;

/// The wire, recorded as strings so an assertion reads as the protocol does.
final class _FakeWire implements WaylandTextInputClient {
  _FakeWire({this.supported = true});

  final bool supported;
  final List<String> calls = <String>[];

  @override
  bool get supportsTextInput => supported;

  @override
  void textInputEnable() => calls.add('enable');

  @override
  void textInputDisable() => calls.add('disable');

  @override
  void textInputSetSurroundingText(String text, int cursor, int anchor) =>
      calls.add('surrounding("$text",$cursor,$anchor)');

  @override
  void textInputSetTextChangeCause(int cause) => calls.add('cause($cause)');

  @override
  void textInputSetContentType(int hint, int purpose) =>
      calls.add('contentType($hint,$purpose)');

  @override
  void textInputSetCursorRectangle(int x, int y, int width, int height) =>
      calls.add('cursorRect($x,$y,$width,$height)');

  @override
  void textInputCommit() => calls.add('commit');
}

/// A [TextInputClient] that records what it was told, in order.
final class _RecordingClient implements TextInputClient {
  String text = '';
  int cursor = 0;
  Rect caret = const Rect.fromLTWH(0, 0, 1, 16);
  TextInputConfiguration configuration = const TextInputConfiguration();

  final List<String> log = <String>[];
  ImeComposition? composition;

  @override
  TextInputConfiguration get textInputConfiguration => configuration;

  @override
  ImeSurroundingText get surroundingText => configuration.isSensitive
      ? ImeSurroundingText.empty
      : ImeSurroundingText(text: text, cursor: cursor);

  @override
  Rect get caretRect => caret;

  @override
  void updateComposition(ImeComposition value) {
    composition = value.isEmpty ? null : value;
    log.add('composition:${value.text}');
  }

  @override
  void commitText(String value) => log.add('commit:$value');

  @override
  void deleteSurroundingText({
    required int beforeLength,
    required int afterLength,
  }) =>
      log.add('delete:$beforeLength/$afterLength');
}
