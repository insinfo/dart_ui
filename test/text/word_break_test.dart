/// Word segmentation (UAX #29 section 4).
///
/// **There is no conformance suite here, because there is no data file to run
/// one from.** `referencias/unicode/` carries `GraphemeBreakTest.txt` and
/// `LineBreakTest.txt`, which the grapheme and line-breaking suites consume,
/// but not `WordBreakTest.txt` - the Unicode Consortium's exhaustive pairwise
/// test for these rules. So the cases below are hand-written, and each says
/// which rule it exercises; the running sentence is UAX #29's own worked
/// example from section 4. Adding `WordBreakTest.txt` to `test/data/unicode/`
/// is what would turn "the cases we thought of" into a proof.
///
/// What partly stands in for it is the last group: the boundary list, the
/// point query and the two directions of movement are derived by three
/// different code paths - a full scan, a bounded backward seek, and a walk -
/// and they are cross-checked against each other over pseudo-random strings
/// built from one code point of every Word_Break class. A disagreement there
/// is a bug in one of the three, and it is exactly the kind of bug a caret
/// finds in production and a hand-written test does not.
library;

import 'dart:math';

import 'package:dart_ui/src/text/word_break.dart';
import 'package:test/test.dart';

void main() {
  group('the annex worked example', () {
    test('a sentence segments the way UAX #29 section 4 says', () {
      // The example sentence from the annex, with its punctuation.
      const String text = 'The quick ("brown") fox can\'t jump 32.3 feet, '
          'right?';
      expect(WordBreaks.segments(text), <String>[
        'The', ' ', 'quick', ' ', '(', '"', 'brown', '"', ')', ' ', //
        'fox', ' ', "can't", ' ', 'jump', ' ', '32.3', ' ', 'feet', ',', //
        ' ', 'right', '?',
      ]);
    });

    test('the words of that sentence are the ones a user would count', () {
      const String text = 'The quick ("brown") fox can\'t jump 32.3 feet, '
          'right?';
      expect(WordBreaks.words(text), <String>[
        'The',
        'quick',
        'brown',
        'fox',
        "can't",
        'jump',
        '32.3',
        'feet',
        'right',
      ]);
    });

    test('boundaries include both ends, and empty text has one', () {
      // WB1 and WB2. Empty text gets a single boundary rather than two, so a
      // consumer pairing adjacent entries produces no segment at all.
      expect(WordBreaks.boundaries(''), <int>[0]);
      expect(WordBreaks.segments(''), isEmpty);
      expect(WordBreaks.boundaries('a'), <int>[0, 1]);
      expect(wordBreaks('ab cd'), <int>[0, 2, 3, 5]);
    });
  });

  group('letters and punctuation (WB5, WB6, WB7)', () {
    test('letters stick together', () {
      expect(WordBreaks.segments('hello'), <String>['hello']);
    });

    test('an apostrophe inside a word does not split it', () {
      // WB6/WB7 with Single_Quote as MidNumLetQ. Splitting here is the single
      // most visible failure of a space-based tokenizer.
      expect(WordBreaks.segments("can't"), <String>["can't"]);
      expect(WordBreaks.segments("o'clock"), <String>["o'clock"]);
      // U+2019 RIGHT SINGLE QUOTATION MARK is MidLetter, and works the same.
      expect(WordBreaks.segments('can’t'), <String>['can’t']);
    });

    test('a trailing apostrophe is not part of the word', () {
      // WB6 needs a letter on *both* sides. `boys'` ends with punctuation.
      expect(WordBreaks.segments("boys'"), <String>['boys', "'"]);
    });

    test('a full stop between letters joins them, at the end does not', () {
      // `example.com` is one segment; a sentence-final full stop is its own.
      expect(WordBreaks.segments('example.com'), <String>['example.com']);
      expect(WordBreaks.segments('end.'), <String>['end', '.']);
      expect(WordBreaks.segments('e.g'), <String>['e.g']);
    });

    test('a colon joins letters, which is MidLetter', () {
      expect(WordBreaks.segments('a:b'), <String>['a:b']);
      expect(WordBreaks.segments('a::b'), <String>['a', ':', ':', 'b']);
    });

    test('Hebrew quotation marks stay inside the word (WB7a, WB7b, WB7c)', () {
      // U+05D0..U+05D2 with a double quote between them: WB7b and WB7c.
      expect(
        WordBreaks.segments('א"ב'),
        <String>['א"ב'],
      );
      // WB7a: a single quote after a Hebrew letter attaches even with no
      // letter after it, which is not true for ALetter.
      expect(WordBreaks.segments("ג'"), <String>["ג'"]);
      // A double quote with no Hebrew letter after it does not attach.
      expect(WordBreaks.segments('א"'), <String>['א', '"']);
    });
  });

  group('numbers (WB8 to WB12)', () {
    test('a decimal number is one segment', () {
      expect(WordBreaks.segments('3.14'), <String>['3.14']);
    });

    test('a grouped number keeps its separators', () {
      // WB11 and WB12 together: `3,456.789` has both a MidNum and a
      // MidNumLet inside it.
      expect(WordBreaks.segments('3,456.789'), <String>['3,456.789']);
    });

    test('a separator with no digit after it ends the number', () {
      expect(WordBreaks.segments('12, 3'), <String>['12', ',', ' ', '3']);
      expect(WordBreaks.segments('1.'), <String>['1', '.']);
    });

    test('digits and letters join in both directions (WB9, WB10)', () {
      expect(WordBreaks.segments('3a'), <String>['3a']);
      expect(WordBreaks.segments('A3'), <String>['A3']);
      expect(WordBreaks.segments('utf8'), <String>['utf8']);
    });
  });

  group('connectors and Katakana (WB13, WB13a, WB13b)', () {
    test('an underscore glues identifiers together', () {
      expect(WordBreaks.segments('foo_bar'), <String>['foo_bar']);
      expect(WordBreaks.segments('snake_case_2'), <String>['snake_case_2']);
      expect(WordBreaks.segments('_leading'), <String>['_leading']);
    });

    test('a hyphen does not', () {
      expect(WordBreaks.segments('baz-qux'), <String>['baz', '-', 'qux']);
    });

    test('a run of Katakana is one segment', () {
      // WB13. Japanese has no spaces, so this is the only thing keeping
      // katakana words together at all.
      expect(
        WordBreaks.segments('カタカナ'),
        <String>['カタカナ'],
      );
    });

    test('each ideograph is its own segment', () {
      // WB999. Real Chinese word boundaries need a dictionary, which the annex
      // says is out of scope; one segment per ideograph is the default and it
      // is what makes a caret move plausibly.
      expect(
        WordBreaks.segments('一二三'),
        <String>['一', '二', '三'],
      );
    });
  });

  group('line terminators (WB3, WB3a, WB3b) and spaces (WB3d)', () {
    test('CRLF is one segment but CR and LF apart are two', () {
      expect(WordBreaks.segments('\r\n'), <String>['\r\n']);
      expect(WordBreaks.segments('\n\r'), <String>['\n', '\r']);
    });

    test('a newline is always its own segment', () {
      expect(WordBreaks.segments('a\nb'), <String>['a', '\n', 'b']);
      expect(WordBreaks.segments('a\r\nb'), <String>['a', '\r\n', 'b']);
    });

    test('a run of spaces is one segment', () {
      // WB3d. Without it, every space in a run would be its own segment and
      // Ctrl+Right would crawl through indentation one column at a time.
      expect(WordBreaks.segments('a   b'), <String>['a', '   ', 'b']);
    });

    test('a tab is not WSegSpace and stands alone', () {
      expect(WordBreaks.segments('a\t\tb'), <String>['a', '\t', '\t', 'b']);
    });
  });

  group('ignorables (WB4)', () {
    test('a combining mark never starts a segment', () {
      // `e + acute` and `a + diaeresis` are inside their words; WB4 folds the
      // mark into the letter before it.
      expect(
        WordBreaks.segments('école näive'),
        <String>['école', ' ', 'näive'],
      );
    });

    test('a format character does not split a word', () {
      // U+00AD SOFT HYPHEN is Format: invisible, and it must not break `ab`
      // into two words.
      expect(WordBreaks.segments('a­b'), <String>['a­b']);
      // U+200C ZWNJ inside a word, which is a real letter joiner in Persian.
      expect(WordBreaks.segments('a‌b'), <String>['a‌b']);
    });

    test('an extender after a newline starts its own segment', () {
      // WB4's exception: after CR, LF or Newline the ignorables are *not*
      // ignored, because there is nothing for them to attach to. The mark
      // becomes a base of its own, and a base whose class is Extend matches
      // no rule, so it does not glue to the letter after it either.
      expect(
        WordBreaks.segments('\ńa'),
        <String>['\n', '\u0301', 'a'],
      );
    });

    test('a leading combining mark at the start of text is its own base', () {
      // Same exception at sot. The orphaned mark is one segment and the word
      // after it another; what must not happen is the mark vanishing into a
      // segment it cannot belong to.
      expect(WordBreaks.segments('\u0301ab'), <String>['\u0301', 'ab']);
      // A second mark attaches to the first, which is now a base.
      expect(WordBreaks.segments('\u0301\u0323ab'),
          <String>['\u0301\u0323', 'ab']);
    });
  });

  group('emoji (WB3c, WB15, WB16)', () {
    test('a ZWJ emoji sequence is one segment', () {
      // WB3c, checked before WB4 can hide the joiner. Without it a family
      // emoji is three segments and Ctrl+Left walks into the middle of it.
      const String family = '\u{1F468}‍\u{1F469}‍\u{1F467}';
      expect(
        WordBreaks.segments('a${family}b'),
        <String>['a', family, 'b'],
      );
    });

    test('a ZWJ between non-emoji does not join them', () {
      // The joiner is ignorable there, so the two ideographs stay apart.
      expect(
        WordBreaks.segments('一‍二'),
        <String>['一‍', '二'],
      );
    });

    test('a pair of regional indicators is one flag', () {
      const String br = '\u{1F1E7}\u{1F1F7}';
      expect(WordBreaks.segments(br), <String>[br]);
    });

    test('four regional indicators are two flags, not one blob', () {
      // WB15/WB16 count parity from the start of the run. An implementation
      // that only says "RI joins RI" glues a whole row of flags together.
      const String br = '\u{1F1E7}\u{1F1F7}';
      const String pt = '\u{1F1F5}\u{1F1F9}';
      expect(WordBreaks.segments('$br$pt'), <String>[br, pt]);
    });

    test('an odd run leaves the last indicator alone', () {
      const String br = '\u{1F1E7}\u{1F1F7}';
      expect(
        WordBreaks.segments('$br\u{1F1F5}'),
        <String>[br, '\u{1F1F5}'],
      );
    });

    test('the parity restarts after a non-indicator', () {
      const String br = '\u{1F1E7}\u{1F1F7}';
      const String pt = '\u{1F1F5}\u{1F1F9}';
      expect(
        WordBreaks.segments('${br}x$pt'),
        <String>[br, 'x', pt],
      );
    });
  });

  group('surrogate pairs', () {
    test('an astral letter joins the word around it', () {
      // U+1D400 MATHEMATICAL BOLD CAPITAL A has Word_Break=ALetter, so WB5
      // applies across it - and it is two UTF-16 units.
      const String text = 'a\u{1D400}b';
      expect(text.length, 4);
      expect(WordBreaks.segments(text), <String>[text]);
    });

    test('no boundary falls inside a surrogate pair', () {
      const String text = '\u{1F1E7}\u{1F1F7}';
      for (int i = 1; i < text.length; i++) {
        if (i == 4) continue;
        expect(
          WordBreaks.isBoundary(text, i),
          isFalse,
          reason: 'offset $i is inside a code point or a flag',
        );
      }
    });

    test('movement never lands inside a surrogate pair', () {
      const String text = 'a\u{1F600}b';
      expect(WordBreaks.next(text, 2), 3);
      expect(WordBreaks.previous(text, 2), 1);
    });
  });

  group('point queries and movement', () {
    const String text = 'hello world';

    test('isBoundary agrees with the boundary list', () {
      final Set<int> marks = WordBreaks.boundaries(text).toSet();
      for (int i = 0; i <= text.length; i++) {
        expect(WordBreaks.isBoundary(text, i), marks.contains(i), reason: '$i');
      }
    });

    test('next and previous move by whole words', () {
      expect(WordBreaks.next(text, 0), 5);
      expect(WordBreaks.next(text, 3), 5);
      expect(WordBreaks.next(text, 5), 6);
      expect(WordBreaks.previous(text, text.length), 6);
      expect(WordBreaks.previous(text, 6), 5);
    });

    test('movement clamps instead of running off the end', () {
      expect(WordBreaks.next(text, text.length), text.length);
      expect(WordBreaks.next(text, 1000), text.length);
      expect(WordBreaks.previous(text, 0), 0);
      expect(WordBreaks.previous(text, -5), 0);
    });

    test('the iterator walks the same boundaries in both directions', () {
      final List<int> forward = <int>[0];
      final WordBreakIterator cursor = WordBreakIterator(text);
      while (cursor.moveNext()) {
        forward.add(cursor.index);
      }
      expect(forward, WordBreaks.boundaries(text));

      final List<int> backward = <int>[text.length];
      final WordBreakIterator back =
          WordBreakIterator(text, index: text.length);
      while (back.movePrevious()) {
        backward.add(back.index);
      }
      expect(backward.reversed.toList(), WordBreaks.boundaries(text));
    });

    test('the iterator clamps its starting index', () {
      expect(WordBreakIterator(text, index: -3).index, 0);
      expect(WordBreakIterator(text, index: 99).index, text.length);
      expect(WordBreakIterator('').moveNext(), isFalse);
    });
  });

  group('the three code paths agree', () {
    /// One code point of every Word_Break class, plus a few characters that
    /// only the rules distinguish. A random string over this alphabet reaches
    /// rule combinations nobody writes a test for - WB7 with an ignorable in
    /// the middle, a regional indicator run interrupted by a format
    /// character, a MidNum between a number and a Katakana.
    const List<String> alphabet = <String>[
      '\r', '\n', '', // CR, LF, Newline
      '́', '‍', '­', // Extend, ZWJ, Format
      '\u{1F1E7}', '\u{1F1F7}', // Regional_Indicator
      'カ', // Katakana
      'א', // Hebrew_Letter
      'a', 'Z', '\u{1D400}', // ALetter, including an astral one
      "'", '"', '.', ':', ',', // Single_Quote, Double_Quote, MidNumLet,
      // MidLetter, MidNum
      '3', '_', ' ', // Numeric, ExtendNumLet, WSegSpace
      '一', '\u{1F600}', '-', // Other, Extended_Pictographic, dash
    ];

    /// Everything below is derived three different ways - a forward scan, a
    /// bounded backward seek, and a walk - and they have to agree at every
    /// offset of every string.
    void checkAgreement(String text) {
      final List<int> marks = WordBreaks.boundaries(text);
      final Set<int> set = marks.toSet();
      final String reason = text.codeUnits
          .map((int u) => u.toRadixString(16).padLeft(4, '0'))
          .join(' ');

      expect(marks.first, 0, reason: reason);
      expect(marks.last, text.isEmpty ? 0 : text.length, reason: reason);
      for (int i = 1; i < marks.length; i++) {
        expect(marks[i], greaterThan(marks[i - 1]), reason: reason);
      }
      expect(WordBreaks.segments(text).join(), text, reason: reason);

      for (int i = 0; i <= text.length; i++) {
        expect(WordBreaks.isBoundary(text, i), set.contains(i),
            reason: '$reason at $i');

        final Iterable<int> after = marks.where((int m) => m > i);
        expect(
          WordBreaks.next(text, i),
          after.isEmpty ? text.length : after.first,
          reason: '$reason next from $i',
        );

        final Iterable<int> before = marks.where((int m) => m < i);
        expect(
          WordBreaks.previous(text, i),
          before.isEmpty ? 0 : before.last,
          reason: '$reason previous from $i',
        );
      }
    }

    test('over hand-picked strings', () {
      for (final String text in <String>[
        '',
        'a',
        '\r\ńa',
        '\u{1F1E7}\u{1F1F7}\u{1F1F5}\u{1F1F9}x\u{1F1E7}',
        'a\u{1F468}‍\u{1F469}‍\u{1F467}b',
        "The quick ('brown') fox can't jump 32.3 feet, right?",
        'א"בג\'ד',
        'カタ3.14_x一',
      ]) {
        checkAgreement(text);
      }
    });

    test('over pseudo-random strings', () {
      // Fixed seed: a failure has to be reproducible, and a suite that picks a
      // new seed every run is a suite that fails on someone else's machine.
      final Random random = Random(20250815);
      for (int trial = 0; trial < 300; trial++) {
        final StringBuffer text = StringBuffer();
        final int length = random.nextInt(8) + 1;
        for (int i = 0; i < length; i++) {
          text.write(alphabet[random.nextInt(alphabet.length)]);
        }
        checkAgreement(text.toString());
      }
    });
  });
}
