/// Script itemization (UAX #24).
///
/// The cases below are written as the failures a reader would see rather than
/// as property assertions: an Arabic word swept into a Latin run and shaped
/// with `latn`, a parenthesis that mirrors at one end and not the other, an
/// accent cut off the letter it sits on, a run boundary landing between the two
/// halves of a surrogate pair.
///
/// Every itemization is also checked for the two invariants the rest of the
/// text stack depends on: the runs tile the string with no gap and no overlap,
/// and their offsets are UTF-16 code units so they can index the same string as
/// `BidiParagraph.levels` and `GlyphRun.clusters`.
library;

import 'package:dart_ui/src/text/script.dart';
import 'package:test/test.dart';

/// Itemizes [text] and asserts the invariants before returning the runs.
List<ScriptRun> runsOf(String text) {
  final List<ScriptRun> runs = itemize(text);
  if (text.isEmpty) {
    expect(runs, isEmpty, reason: 'empty text has no runs');
    return runs;
  }
  final StringBuffer rebuilt = StringBuffer();
  int expectedStart = 0;
  for (final ScriptRun run in runs) {
    expect(run.start, expectedStart, reason: 'runs must be contiguous');
    expect(run.end, greaterThan(run.start), reason: 'runs must be non-empty');
    rebuilt.write(run.textIn(text));
    expectedStart = run.end;
  }
  expect(expectedStart, text.length, reason: 'runs must cover the whole text');
  expect(rebuilt.toString(), text, reason: 'runs must reconstruct the text');
  return runs;
}

/// The scripts of [text]'s runs, for the compact assertions below.
List<Script> scriptsOf(String text) =>
    runsOf(text).map((ScriptRun run) => run.script).toList();

/// The slices of [text] its runs cover.
List<String> slicesOf(String text) =>
    runsOf(text).map((ScriptRun run) => run.textIn(text)).toList();

void main() {
  group('property lookup', () {
    test('letters report their own script', () {
      expect(scriptOf(0x0041), Script.latn); // A
      expect(scriptOf(0x05D0), Script.hebr); // ALEF
      expect(scriptOf(0x0628), Script.arab); // BEH
      expect(scriptOf(0x0905), Script.deva); // A
      expect(scriptOf(0x0985), Script.beng); // A
      expect(scriptOf(0x0E01), Script.thai); // KO KAI
      expect(scriptOf(0x4E00), Script.hani); // one
      expect(scriptOf(0x3042), Script.hira); // A
      expect(scriptOf(0x30A2), Script.kana); // A
      expect(scriptOf(0xAC00), Script.hang); // GA
      expect(scriptOf(0x0410), Script.cyrl); // A
      expect(scriptOf(0x03B1), Script.grek); // alpha
    });

    test('shared characters are Common, marks are Inherited', () {
      expect(scriptOf(0x0020), Script.zyyy); // SPACE
      expect(scriptOf(0x0030), Script.zyyy); // DIGIT ZERO
      expect(scriptOf(0x0301), Script.zinh); // COMBINING ACUTE
      expect(Script.zyyy.isContextual, isTrue);
      expect(Script.zinh.isContextual, isTrue);
      expect(Script.latn.isContextual, isFalse);
    });

    test('unassigned code points are Unknown, not a guess', () {
      // U+0378 is reserved. Reporting it as Latin because of its neighbours
      // would put it in a Latin run and shape it with `latn`.
      expect(scriptOf(0x0378), Script.zzzz);
      expect(scriptOf(0x10FFFF), Script.zzzz);
      expect(Script.zzzz.isContextual, isFalse);
    });

    test('Script_Extensions names the scripts a shared character occurs in',
        () {
      // U+0640 ARABIC TATWEEL is Common, but it does not occur in Latin.
      expect(scriptOf(0x0640), Script.zyyy);
      expect(hasScriptExtension(0x0640, Script.arab), isTrue);
      expect(hasScriptExtension(0x0640, Script.syrc), isTrue);
      expect(hasScriptExtension(0x0640, Script.latn), isFalse);
    });

    test('a character with a real script extends to just that script', () {
      expect(scriptExtensionsOf(0x0041), <Script>[Script.latn]);
      expect(scriptExtensionsOf(0x0628), <Script>[Script.arab]);
    });

    test('the extension sets are shared, not rebuilt per call', () {
      // The itemizer asks per code point; an allocation here would be one per
      // character of every paragraph.
      expect(
        identical(scriptExtensionsOf(0x0640), scriptExtensionsOf(0x0640)),
        isTrue,
      );
    });
  });

  group('itemization', () {
    test('empty text has no runs at all', () {
      expect(itemize(''), isEmpty);
    });

    test('plain Latin is one run', () {
      expect(runsOf('hello'), <ScriptRun>[
        const ScriptRun(0, 5, Script.latn),
      ]);
    });

    test('Latin and Arabic are separate runs', () {
      // Without this, the Arabic is shaped with `latn`: no joining, no marks,
      // a row of isolated letterforms.
      const String text = 'Hello مرحبا world';
      expect(scriptsOf(text), <Script>[Script.latn, Script.arab, Script.latn]);
      expect(slicesOf(text), <String>['Hello ', 'مرحبا ', 'world']);
    });

    test('Latin and CJK are separate runs', () {
      const String text = 'Hello 世界!';
      expect(scriptsOf(text), <Script>[Script.latn, Script.hani]);
      // The trailing '!' is Common and joins the run before it.
      expect(slicesOf(text), <String>['Hello ', '世界!']);
    });

    test('numbers and punctuation stay inside a Hebrew run', () {
      // A run per comma would cut the sentence into six pieces and make the
      // shaper restart at each one.
      const String text = 'שלום 123, עולם!';
      expect(scriptsOf(text), <Script>[Script.hebr]);
    });

    test('Devanagari is its own run', () {
      const String text = 'नमस्ते world';
      expect(scriptsOf(text), <Script>[Script.deva, Script.latn]);
      expect(slicesOf(text).first, 'नमस्ते ');
    });

    test('Japanese gives Han, Hiragana and Katakana their own runs', () {
      const String text = '漢字ひらがなカタ';
      expect(scriptsOf(text), <Script>[Script.hani, Script.hira, Script.kana]);
      // They agree on their OpenType tag, so the split costs the shaper
      // nothing beyond an extra run.
      expect(openTypeTagOf(Script.hira), openTypeTagOf(Script.kana));
    });

    test('a Common character that cannot occur in the run leaves it', () {
      // U+0640 ARABIC TATWEEL is Common, so the naive rule would keep it in
      // the Latin run. Script_Extensions says it does not occur in Latin.
      const String text = 'abc ـ بيت';
      expect(scriptsOf(text), <Script>[Script.latn, Script.arab]);
      expect(slicesOf(text), <String>['abc ', 'ـ بيت']);
    });

    test('a combining mark never moves forward off its base', () {
      // 'e' + COMBINING ACUTE, then Cyrillic 'е' + COMBINING ACUTE. The mark
      // is Inherited; taking the following script would attach each accent to
      // the wrong letter.
      const String text = 'éе́';
      expect(scriptsOf(text), <Script>[Script.latn, Script.cyrl]);
      expect(slicesOf(text), <String>['é', 'е́']);
    });

    test('text with no script at all is one Common run', () {
      expect(runsOf('123'), <ScriptRun>[const ScriptRun(0, 3, Script.zyyy)]);
    });

    test('leading Common characters join the first real script', () {
      const String text = '  שלום';
      expect(scriptsOf(text), <Script>[Script.hebr]);
    });
  });

  group('bracket pairs', () {
    test('a pair opened in Arabic closes in Arabic', () {
      // The point of the rule: under bidi L4 both parentheses have to mirror,
      // and they only do if both resolved to the right-to-left script.
      const String text = 'مرحبا (hello) بكم';
      expect(scriptsOf(text), <Script>[Script.arab, Script.latn, Script.arab]);
      final List<String> slices = slicesOf(text);
      expect(slices[0].endsWith('('), isTrue);
      expect(slices[2].startsWith(')'), isTrue);
    });

    test('a pair opened in Latin closes in Latin', () {
      const String text = 'a (شكرا) b';
      expect(scriptsOf(text), <Script>[Script.latn, Script.arab, Script.latn]);
      expect(slicesOf(text)[0], 'a (');
      expect(slicesOf(text)[2].startsWith(')'), isTrue);
    });

    test('nested pairs each resolve to their own opener', () {
      const String text = 'مرحبا [a (b) c] بكم';
      final List<ScriptRun> runs = runsOf(text);
      expect(runs.first.script, Script.arab);
      expect(runs.last.script, Script.arab);
      expect(runs.first.textIn(text).endsWith('['), isTrue);
      expect(runs.last.textIn(text).startsWith(']'), isTrue);
    });

    test('an unmatched closer does not steal a later opener', () {
      // `a) (b`: the ')' pairs with nothing, so the '(' must still be free to
      // pair with a later ')'.
      const String text = 'مرحبا) (b) c';
      final List<ScriptRun> runs = runsOf(text);
      expect(runs.first.script, Script.arab);
      expect(
        runs.map((ScriptRun r) => r.textIn(text)).join(),
        text,
        reason: 'unmatched brackets must not lose text',
      );
    });

    test('brackets inside one script change nothing', () {
      expect(scriptsOf('a (b) c'), <Script>[Script.latn]);
    });
  });

  group('surrogate pairs', () {
    test('both halves of an astral character get its script', () {
      // U+10330 GOTHIC LETTER AHSA is two UTF-16 units. A run boundary
      // between them would hand the shaper half a character.
      const String text = 'a\u{10330}\u{10331}b';
      expect(text.length, 6, reason: 'the test needs non-BMP code points');
      expect(scriptsOf(text), <Script>[Script.latn, Script.goth, Script.latn]);
      expect(runsOf(text), <ScriptRun>[
        const ScriptRun(0, 1, Script.latn),
        const ScriptRun(1, 5, Script.goth),
        const ScriptRun(5, 6, Script.latn),
      ]);
    });

    test('offsets are UTF-16 units, not code points', () {
      const String text = '\u{10330}ab';
      expect(text.runes.length, 3);
      expect(text.length, 4);
      expect(runsOf(text), <ScriptRun>[
        const ScriptRun(0, 2, Script.goth),
        const ScriptRun(2, 4, Script.latn),
      ]);
    });

    test('an astral emoji ZWJ sequence stays one Common run', () {
      // A family emoji: three astral code points joined by two ZWJs, eight
      // code units. Splitting it would break the ligature the font forms.
      const String text = '\u{1F468}‍\u{1F469}‍\u{1F466}';
      expect(text.length, 8);
      expect(runsOf(text), <ScriptRun>[const ScriptRun(0, 8, Script.zyyy)]);
    });

    test('an emoji joins the Latin text around it', () {
      const String text = 'hi \u{1F44B}';
      expect(runsOf(text), <ScriptRun>[const ScriptRun(0, 5, Script.latn)]);
    });

    test('a lone high surrogate is Unknown, not part of its neighbour', () {
      // Mangled input reaches a text stack constantly. It must not silently
      // become Latin.
      const String text = 'a\uD800b';
      expect(scriptsOf(text), <Script>[Script.latn, Script.zzzz, Script.latn]);
    });
  });

  group('OpenType tags', () {
    test('the ordinary case is the lower-cased ISO code', () {
      expect(openTypeTagOf(Script.latn), 'latn');
      expect(openTypeTagOf(Script.arab), 'arab');
      expect(openTypeTagOf(Script.hebr), 'hebr');
      expect(openTypeTagOf(Script.thai), 'thai');
      expect(openTypeTagOf(Script.khmr), 'khmr');
      expect(openTypeTagOf(Script.hani), 'hani');
      expect(openTypeTagOf(Script.hang), 'hang');
      expect(openTypeTagOf(Script.cyrl), 'cyrl');
      expect(openTypeTagOf(Script.grek), 'grek');
    });

    test('the padded three-letter tags keep their spaces', () {
      // A tag is four bytes. Trimming these produces a tag no font contains.
      expect(openTypeTagOf(Script.laoo), 'lao ');
      expect(openTypeTagOf(Script.nkoo), 'nko ');
      expect(openTypeTagOf(Script.vaii), 'vai ');
      expect(openTypeTagOf(Script.yiii), 'yi  ');
    });

    test('Hiragana and Katakana share `kana`', () {
      expect(openTypeTagOf(Script.hira), 'kana');
      expect(openTypeTagOf(Script.kana), 'kana');
    });

    test('the non-scripts map to DFLT', () {
      expect(openTypeTagOf(Script.zyyy), defaultOpenTypeTag);
      expect(openTypeTagOf(Script.zinh), defaultOpenTypeTag);
      expect(openTypeTagOf(Script.zzzz), defaultOpenTypeTag);
    });

    test('the Indic scripts prefer their v2 tag and offer v1 after it', () {
      expect(openTypeTagOf(Script.deva), 'dev2');
      expect(openTypeTagOf(Script.beng), 'bng2');
      expect(openTypeTagOf(Script.mymr), 'mym2');
      expect(openTypeTagsOf(Script.deva), <String>['dev2', 'deva', 'DFLT']);
      expect(openTypeTagsOf(Script.taml), <String>['tml2', 'taml', 'DFLT']);
    });

    test('every other script offers its tag then DFLT', () {
      expect(openTypeTagsOf(Script.latn), <String>['latn', 'DFLT']);
      expect(openTypeTagsOf(Script.zyyy), <String>['DFLT']);
    });

    test('every script has a four-character tag', () {
      // A shaper writes the tag into a 32-bit field. Anything else is a bug
      // that only shows up on the one script nobody tested.
      for (final Script script in Script.values) {
        expect(
          openTypeTagOf(script).length,
          4,
          reason: '${script.code} has tag "${openTypeTagOf(script)}"',
        );
        expect(script.code.length, 4, reason: '${script.name} has no ISO code');
      }
    });

    test('the tag lists are shared and unmodifiable', () {
      expect(
        identical(openTypeTagsOf(Script.arab), openTypeTagsOf(Script.arab)),
        isTrue,
      );
      expect(
        () => openTypeTagsOf(Script.arab).add('x'),
        throwsUnsupportedError,
      );
    });
  });

  group('ScriptRun', () {
    test('equality is by value, so runs can be compared in tests', () {
      expect(
        const ScriptRun(0, 3, Script.latn),
        const ScriptRun(0, 3, Script.latn),
      );
      expect(
        const ScriptRun(0, 3, Script.latn),
        isNot(const ScriptRun(0, 3, Script.arab)),
      );
      expect(
        const ScriptRun(0, 3, Script.latn).hashCode,
        const ScriptRun(0, 3, Script.latn).hashCode,
      );
    });

    test('length is in UTF-16 units', () {
      expect(const ScriptRun(2, 7, Script.latn).length, 5);
    });

    test('toString names the script by its ISO code', () {
      expect(const ScriptRun(0, 3, Script.arab).toString(), contains('Arab'));
    });
  });
}
