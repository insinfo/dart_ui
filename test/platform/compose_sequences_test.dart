/// Dead keys, asserted at the character rather than at "it did not throw".
///
/// The cases here are the ones that decide whether somebody can type their own
/// name. `á` on a Brazilian keyboard is `dead_acute` then `a`; getting the
/// *pending* state wrong types `´a`, and getting the *invalid* state wrong
/// types `´q`. Both are what this file exists to pin.
///
/// The tables are written inline rather than read from the machine, so the
/// grammar is tested on Windows CI where `/usr/share/X11/locale` does not
/// exist. Reading the real files is [loadSystemComposeTable]'s job and is
/// exercised only for its precedence order.
library;

import 'dart:io' show Platform;

import 'package:dart_ui/src/platform/compose_sequences.dart';
import 'package:dart_ui/src/platform/compose_sequences_platform_io.dart';
import 'package:test/test.dart';

/// The keysyms this file feeds, by their X11 names.
const int _deadAcute = 0xfe51;
const int _deadTilde = 0xfe53;
const int _multiKey = 0xff20;
const int _keyA = 0x61;
const int _keyQ = 0x71;
const int _keyN = 0x6e;
const int _keyO = 0x6f;
const int _keyC = 0x63;
const int _shiftL = 0xffe1;

/// A minimal table with the three shapes that matter: a dead key, a
/// three-keysym Compose sequence, and a sequence that is a prefix of another.
const String _table = '''
# A comment, and a blank line follows.

<dead_acute> <a> : "á"   aacute
<dead_tilde> <n> : "ñ"   ntilde
<Multi_key> <o> <c> : "©"   copyright
<Multi_key> <c> : "ç"   ccedilla
''';

void main() {
  group('the Compose grammar', () {
    test('a sequence is parsed into its keysyms and its string', () {
      final ComposeTable table = ComposeTable.parse(_table);

      expect(table.sequenceCount, 4);
      expect(table.skippedSequences, 0);

      final engine = ComposeEngine(table);
      expect(engine.accept(_deadAcute).status, ComposeStatus.pending);
      expect(engine.accept(_keyA).text, 'á');
    });

    test('a comment inside the result string is not a comment', () {
      // `<Multi_key> <n> <s> : "#"` is a real line in the standard table, and
      // a naive strip-after-hash turns it into a sequence with no result.
      final ComposeTable table = ComposeTable.parse(
        '<Multi_key> <n> <s> : "#"   numbersign # this part is a comment\n',
      );

      expect(table.sequenceCount, 1);
      final engine = ComposeEngine(table)..accept(_multiKey);
      expect(engine.accept(_keyN).status, ComposeStatus.pending);
      expect(engine.accept(0x73).text, '#');
    });

    test('a keysym name this file cannot resolve drops the line, counted', () {
      final ComposeTable table = ComposeTable.parse(
        '<dead_acute> <a> : "á"\n'
        '<Arabic_hamza_above> <alef> : "أ"\n',
      );

      expect(table.sequenceCount, 1);
      expect(
        table.skippedSequences,
        1,
        reason: 'counted rather than silently ignored, so a user reporting '
            '"one accent works and another does not" has a number to quote',
      );
    });

    test('U+ and 0x keysym spellings both resolve', () {
      expect(composeKeysymFromName('U00E7'), 0xe7);
      expect(composeKeysymFromName('U+00E7'), 0xe7);
      expect(composeKeysymFromName('0xfe51'), _deadAcute);
      expect(composeKeysymFromName('dead_acute'), _deadAcute);
      expect(composeKeysymFromName('a'), 0x61);
      expect(
        composeKeysymFromName('U1F600'),
        // Sem separador de digito: o CI fixa o SDK 3.6.0, que ainda nao
        // habilita `digit-separators`, e o gate de formatacao nem parseia.
        0x01000000 + 0x1F600,
        reason: 'a code point above Latin-1 carries the 0x01000000 prefix, '
            'which is how xkb spells every non-legacy keysym',
      );
      expect(composeKeysymFromName('not_a_keysym'), 0);
    });

    test('the escapes X11 allows survive into the result', () {
      final ComposeTable table = ComposeTable.parse(
        '<Multi_key> <a> : "\\"" quotedbl\n'
        '<Multi_key> <b> : "\\\\" backslash\n'
        '<Multi_key> <d> : "\\x41" A\n',
      );
      expect(table.sequenceCount, 3);

      String composed(int second) {
        final engine = ComposeEngine(table)..accept(_multiKey);
        return engine.accept(second).text!;
      }

      expect(composed(0x61), '"');
      expect(composed(0x62), r'\');
      expect(composed(0x64), 'A');
    });

    test('include is followed, once, through the resolver it is given', () {
      var calls = 0;
      final ComposeTable table = ComposeTable.parse(
        'include "%L"\n'
        'include "%L"\n'
        '<dead_tilde> <n> : "ñ"\n',
        resolveInclude: (String path) {
          calls++;
          expect(path, '%L', reason: 'unexpanded, as written in the file');
          return '<dead_acute> <a> : "á"\n';
        },
      );

      expect(table.sequenceCount, 2, reason: 'both files contributed');
      expect(
        calls,
        1,
        reason: 'the same include twice is one read; a table that includes '
            'itself back is a real configuration and must not hang',
      );
    });

    test('a conditional section is skipped whole rather than misread', () {
      final ComposeTable table = ComposeTable.parse(
        '! Ctrl <a> : "x"\n'
        '<dead_acute> <a> : "á"\n',
      );
      expect(table.sequenceCount, 1);
      expect(table.skippedSequences, 1);
    });
  });

  group('the engine', () {
    late ComposeTable table;

    setUp(() => table = ComposeTable.parse(_table));

    test('a dead key produces no text and is not passed through', () {
      final engine = ComposeEngine(table);
      final ComposeResult result = engine.accept(_deadAcute);

      expect(result.status, ComposeStatus.pending);
      expect(
        result.text,
        isNull,
        reason: 'inserting the bare accent is precisely the bug a dead key '
            'exists to avoid',
      );
      expect(engine.isComposing, isTrue);
    });

    test('the pair composes, and the engine is ready for the next one', () {
      final engine = ComposeEngine(table)..accept(_deadAcute);

      expect(engine.accept(_keyA).text, 'á');
      expect(engine.isComposing, isFalse);
      expect(
        engine.accept(_keyA).status,
        ComposeStatus.pass,
        reason: 'the sequence ended; a plain letter is the caller\'s again',
      );
    });

    test(
        'a dead key followed by nothing it combines with is invalid, not '
        'text', () {
      final engine = ComposeEngine(table)..accept(_deadAcute);
      final ComposeResult result = engine.accept(_keyQ);

      expect(result.status, ComposeStatus.invalid);
      expect(result.text, isNull);
      expect(
        engine.isComposing,
        isFalse,
        reason: 'X11 discards the sequence; keeping it would swallow the next '
            'keystroke too',
      );
    });

    test('an unrelated keysym passes straight through', () {
      final engine = ComposeEngine(table);
      expect(engine.accept(_keyQ).status, ComposeStatus.pass);
      expect(engine.isComposing, isFalse);
    });

    test('a three-keysym sequence needs all three', () {
      final engine = ComposeEngine(table);
      expect(engine.accept(_multiKey).status, ComposeStatus.pending);
      expect(engine.accept(_keyO).status, ComposeStatus.pending);
      expect(engine.accept(_keyC).text, '©');
    });

    test('a shorter sequence that is also a prefix resolves at once', () {
      // `<Multi_key> <c>` completes while `<Multi_key> <o> <c>` is a longer
      // branch of the same trie. Waiting for the longer one would mean the
      // shorter never fires.
      final engine = ComposeEngine(table)..accept(_multiKey);
      expect(engine.accept(_keyC).text, 'ç');
    });

    test('reset forgets a half-typed sequence', () {
      final engine = ComposeEngine(table)..accept(_deadTilde);
      expect(engine.isComposing, isTrue);

      engine.reset();

      expect(engine.isComposing, isFalse);
      expect(
        engine.accept(_keyN).status,
        ComposeStatus.pass,
        reason: 'the rest of that sequence went to another window; fusing it '
            'onto the next thing typed here is the bug reset prevents',
      );
    });

    test('an empty table passes everything', () {
      final engine = ComposeEngine(ComposeTable.empty);
      expect(engine.accept(_deadAcute).status, ComposeStatus.pass);
      expect(engine.accept(_keyA).status, ComposeStatus.pass);
    });

    test('a modifier keysym is the caller\'s to filter, not the engine\'s', () {
      // Documented rather than handled here: Shift is held during half the
      // sequences in the standard table, so a caller that fed it would break
      // `<dead_tilde> <N>`. The engine treats it like any other keysym, which
      // is what makes feeding it a bug at the call site.
      final engine = ComposeEngine(table)..accept(_deadTilde);
      expect(engine.accept(_shiftL).status, ComposeStatus.invalid);
    });
  });

  group('finding the machine\'s table', () {
    test(
        'the candidate order is XCOMPOSEFILE, then ~/.XCompose, then the '
        'locale table', () {
      final List<String> candidates = systemComposeFileCandidates(
        environment: <String, String>{
          'XCOMPOSEFILE': '/etc/custom.compose',
          'HOME': '/home/someone',
          'LANG': 'pt_BR.UTF-8',
        },
      );

      expect(candidates, <String>[
        '/etc/custom.compose',
        '/home/someone/.XCompose',
        '/usr/share/X11/locale/pt_BR.UTF-8/Compose',
      ]);
    });

    test('LC_ALL wins over LC_CTYPE, which wins over LANG', () {
      String locale(Map<String, String> environment) =>
          systemComposeFileCandidates(environment: environment).last;

      expect(
        locale(<String, String>{
          'LC_ALL': 'fr_FR.UTF-8',
          'LC_CTYPE': 'de_DE.UTF-8',
          'LANG': 'en_US.UTF-8',
        }),
        '/usr/share/X11/locale/fr_FR.UTF-8/Compose',
      );
      expect(
        locale(<String, String>{
          'LC_CTYPE': 'de_DE.UTF-8',
          'LANG': 'en_US.UTF-8',
        }),
        '/usr/share/X11/locale/de_DE.UTF-8/Compose',
      );
      expect(
        locale(<String, String>{'LANG': 'en_US.UTF-8'}),
        '/usr/share/X11/locale/en_US.UTF-8/Compose',
      );
    });

    test('the glibc .utf8 spelling is normalised to the directory name', () {
      expect(
        systemComposeFileCandidates(
          environment: <String, String>{'LANG': 'pt_BR.utf8'},
        ).last,
        '/usr/share/X11/locale/pt_BR.UTF-8/Compose',
        reason: 'glibc accepts both spellings; only one has a directory',
      );
    });

    test('a machine that is not Linux has no table at all', () {
      // Windows composes dead keys inside the OS - WM_DEADCHAR then a composed
      // WM_CHAR - so composing them again here would double every accent.
      // Only meaningful off Linux: a Linux machine really does ship
      // /usr/share/X11/locale/*/Compose, so there the table is rightly not
      // empty and the assertion would be testing the runner, not the code.
      final ComposeTable table = loadSystemComposeTable(
        environment: <String, String>{'HOME': '/nonexistent'},
      );
      expect(table.isEmpty, isTrue);
    },
        skip: Platform.isLinux
            ? 'runs only off Linux: a Linux machine has an X11 compose table'
            : false);
  });
}
