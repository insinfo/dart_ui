/// Line breaking (UAX #14).
///
/// The hand-written cases name the visual defect each rule prevents; the
/// Unicode conformance suite at the bottom is what establishes correctness,
/// because it enumerates every pair of line break classes and every rule
/// interaction the Consortium could construct, and it is written by people who
/// are not the author of this implementation.
library;

import 'package:dart_ui/src/text/line_break.dart';
import 'package:test/test.dart';

import '../data/unicode/ucd_data.dart';

/// The break positions of [text], excluding the always-present one at the end.
List<int> _breaks(String text) => LineBreaker.breakOpportunities(text)
    .where((LineBreakOpportunity o) => o.position != text.length)
    .map((LineBreakOpportunity o) => o.position)
    .toList();

List<int> _mandatory(String text) => LineBreaker.breakOpportunities(text)
    .where((LineBreakOpportunity o) => o.isMandatory)
    .map((LineBreakOpportunity o) => o.position)
    .toList();

void main() {
  group('the shape of the result', () {
    test('empty text has no opportunities', () {
      expect(LineBreaker.breakOpportunities(''), isEmpty);
    });

    test('the end of text is always an opportunity and is mandatory', () {
      final List<LineBreakOpportunity> o =
          LineBreaker.breakOpportunities('word');
      expect(o.last.position, 4);
      expect(o.last.isMandatory, isTrue);
    });

    test('position zero is never an opportunity', () {
      // LB2. A caller that broke here would emit an empty first line.
      for (final String text in <String>['a b', ' a', '\na', '。a']) {
        expect(
            LineBreaker.breakOpportunities(text).first.position, greaterThan(0),
            reason: text);
      }
    });
  });

  group('words and spaces', () {
    test('no break inside a word', () {
      // LB28.
      expect(_breaks('hello'), isEmpty);
      expect(_breaks('Straße'), isEmpty);
    });

    test('break after a space, not before it', () {
      // LB7 then LB18: the space belongs to the line it ends, so the next
      // line starts at the word. Breaking before the space would leave a
      // trailing gap that justification then stretches.
      expect(_breaks('one two'), <int>[4]);
    });

    test('a run of spaces breaks only once, after the last one', () {
      expect(_breaks('one   two'), <int>[6]);
    });

    test('a non-breaking space does not break', () {
      // LB12.
      expect(_breaks('one two'), isEmpty);
    });

    test('a word joiner suppresses a break that would otherwise happen', () {
      // LB11 beats LB18.
      expect(_breaks('one ⁠two'), isEmpty);
    });
  });

  group('punctuation', () {
    test('no break after an opening bracket, even across spaces', () {
      // LB14. Without it, "( word" wraps after the bracket and leaves a lone
      // "(" at the end of the line.
      expect(_breaks('a (b'), <int>[2]);
      expect(_breaks('a ( b'), <int>[2]);
    });

    test('no break before a closing bracket', () {
      // LB13. "word )" must not put the bracket alone on the next line.
      expect(_breaks('a b) c'), <int>[2, 5]);
      expect(_breaks('a b ) c'), <int>[2, 6],
          reason: 'not even when a space intervenes');
    });

    test('no break before an exclamation mark or a full stop', () {
      // LB13 and LB15d.
      expect(_breaks('a b! c'), <int>[2, 5]);
      expect(_breaks('a b. c'), <int>[2, 5]);
    });

    test('brackets stay attached to the word they enclose', () {
      // LB30. "person(s)" is one unit.
      expect(_breaks('person(s)'), isEmpty);
    });

    test('an ellipsis stays with what precedes it', () {
      // LB22.
      expect(_breaks('wait… now'), <int>[6]);
    });

    test('a hyphen allows a break after it but not before', () {
      // LB21: × HY forbids the break before, LB31 allows the one after.
      expect(_breaks('well-known'), <int>[5]);
    });

    test('a word-initial hyphen keeps its word', () {
      // LB20a. A dash introducing dialogue is not a place to wrap.
      expect(_breaks('a -b'), <int>[2]);
    });
  });

  group('numbers', () {
    test('no break inside a number with separators', () {
      // LB25.
      expect(_breaks('1,234.56'), isEmpty);
    });

    test('no break between a number and its unit', () {
      // LB24 and LB25: the currency symbol, the percent sign and the unit all
      // belong to the number, so "50" never ends a line with "%" starting the
      // next one.
      expect(_breaks('50%'), isEmpty);
      expect(_breaks('\$50'), isEmpty);
      expect(_breaks('50km'), isEmpty);
    });

    test('no break between a digit and a letter', () {
      // LB23.
      expect(_breaks('a1'), isEmpty);
      expect(_breaks('1a'), isEmpty);
    });

    test('a bracketed signed amount holds together', () {
      // The regular expression LB25 is written to implement: "$(12.35)".
      expect(_breaks('\$(12.35)'), isEmpty);
    });

    test('a decimal mark after a space starts a new number', () {
      // LB15c: in "subtract .5" the break belongs before the dot, not after.
      expect(_breaks('subtract .5'), <int>[9]);
    });
  });

  group('mandatory breaks', () {
    test('a line feed is a mandatory break', () {
      // LB5.
      expect(_mandatory('a\nb'), <int>[2, 3]);
    });

    test('CR LF is one break, not two', () {
      expect(_mandatory('a\r\nb'), <int>[3, 4]);
    });

    test('U+2028 LINE SEPARATOR is a mandatory break', () {
      // LB4: the character exists precisely to force a break, and a
      // space-splitting implementation ignores it entirely.
      expect(_mandatory('a b'), <int>[2, 3]);
    });

    test('U+2029 PARAGRAPH SEPARATOR is a mandatory break', () {
      expect(_mandatory('a b'), <int>[2, 3]);
    });

    test('a form feed and a vertical tab are mandatory breaks', () {
      expect(_mandatory('ab'), <int>[2, 3]);
      expect(_mandatory('ab'), <int>[2, 3]);
    });

    test('no break between a character and the hard break after it', () {
      // LB6. The newline ends the line it is on; it does not start one.
      expect(_breaks('ab\ncd'), <int>[3]);
    });

    test('a zero width space is an ordinary break, not a mandatory one', () {
      // LB8.
      final List<LineBreakOpportunity> o =
          LineBreaker.breakOpportunities('a​b');
      expect(o.first.position, 2);
      expect(o.first.isMandatory, isFalse);
    });
  });

  group('CJK and Korean', () {
    test('ideographs break between any two of them', () {
      // LB31 with nothing to stop it. This is the whole reason Chinese and
      // Japanese wrap at all: there are no spaces to split on.
      expect(_breaks('日中韓'), <int>[1, 2]);
    });

    test('a small kana does not start a line', () {
      // LB21 (× NS): the non-starters of Japanese typography.
      expect(_breaks('きゃ'), isEmpty);
    });

    test('an ideographic full stop does not start a line', () {
      // LB13 (× CL).
      expect(_breaks('日。中'), <int>[2]);
    });

    test('a Korean syllable spelled with jamo is one unit', () {
      // LB26. U+1100 + U+1161 + U+11A8 is one syllable block.
      expect(_breaks('각'), isEmpty);
    });

    test('Korean syllables break between blocks', () {
      expect(_breaks('한국어'), <int>[1, 2]);
    });

    test('a prefix stays with the ideograph it counts', () {
      // LB23a: "$100" in the CJK sense.
      expect(_breaks('\$日'), isEmpty);
      expect(_breaks('日%'), isEmpty);
    });
  });

  group('emoji and marks', () {
    test('a combining mark never starts a line', () {
      // LB9. Otherwise a wrap can put an accent at the start of a line with
      // nothing under it.
      expect(_breaks('á b'), <int>[3]);
    });

    test('a ZWJ emoji sequence does not break', () {
      // LB8a.
      expect(_breaks('\u{1F468}‍\u{1F469}'), isEmpty);
    });

    test('a skin tone modifier stays with its base', () {
      // LB30b.
      expect(_breaks('\u{1F44D}\u{1F3FD}'), isEmpty);
    });

    test('a flag is two regional indicators and breaks between pairs', () {
      // LB30a.
      const String br = '\u{1F1E7}\u{1F1F7}';
      const String pt = '\u{1F1F5}\u{1F1F9}';
      expect(_breaks('$br$pt'), <int>[4]);
    });
  });

  group('property lookup', () {
    test('classes match the UCD for a spot sample', () {
      expect(lineBreakClassOf(0x0041), LineBreakClass.al);
      expect(lineBreakClassOf(0x0020), LineBreakClass.sp);
      expect(lineBreakClassOf(0x000A), LineBreakClass.lf);
      expect(lineBreakClassOf(0x000D), LineBreakClass.cr);
      expect(lineBreakClassOf(0x2028), LineBreakClass.bk);
      expect(lineBreakClassOf(0x0085), LineBreakClass.nl);
      expect(lineBreakClassOf(0x200B), LineBreakClass.zw);
      expect(lineBreakClassOf(0x2060), LineBreakClass.wj);
      expect(lineBreakClassOf(0x00A0), LineBreakClass.gl);
      expect(lineBreakClassOf(0x0028), LineBreakClass.op);
      expect(lineBreakClassOf(0x0029), LineBreakClass.cp);
      expect(lineBreakClassOf(0x007D), LineBreakClass.cl);
      expect(lineBreakClassOf(0x005D), LineBreakClass.cp,
          reason: 'a square bracket is CP, not CL, so LB30 applies to it');
      expect(lineBreakClassOf(0x0021), LineBreakClass.ex);
      expect(lineBreakClassOf(0x002F), LineBreakClass.sy);
      expect(lineBreakClassOf(0x002E), LineBreakClass.is_);
      expect(lineBreakClassOf(0x0030), LineBreakClass.nu);
      expect(lineBreakClassOf(0x0024), LineBreakClass.pr);
      expect(lineBreakClassOf(0x0025), LineBreakClass.po);
      expect(lineBreakClassOf(0x002D), LineBreakClass.hy);
      expect(lineBreakClassOf(0x2014), LineBreakClass.b2);
      expect(lineBreakClassOf(0x2026), LineBreakClass.in_);
      expect(lineBreakClassOf(0x0022), LineBreakClass.qu);
      expect(lineBreakClassOf(0x0301), LineBreakClass.cm);
      expect(lineBreakClassOf(0x200D), LineBreakClass.zwj);
      expect(lineBreakClassOf(0x4E00), LineBreakClass.id);
      expect(lineBreakClassOf(0x1100), LineBreakClass.jl);
      expect(lineBreakClassOf(0xAC00), LineBreakClass.h2);
      expect(lineBreakClassOf(0x05D0), LineBreakClass.hl);
      expect(lineBreakClassOf(0x1F1E6), LineBreakClass.ri);
      expect(lineBreakClassOf(0xFFFC), LineBreakClass.cb);
    });

    test('LB1 is baked into the table', () {
      // The five tailorable classes have no runtime representation at all, so
      // nothing downstream can see an AI or a CJ and guess at it.
      expect(lineBreakClassOf(0x2757), LineBreakClass.al,
          reason: 'AI resolves to AL');
      expect(lineBreakClassOf(0x3041), LineBreakClass.ns,
          reason: 'CJ resolves to NS');
      expect(lineBreakClassOf(0xD800), LineBreakClass.al,
          reason: 'SG resolves to AL');
      expect(lineBreakClassOf(0x0E01), LineBreakClass.al,
          reason: 'a Thai letter is SA with a non-mark category, so AL');
      expect(lineBreakClassOf(0x0E31), LineBreakClass.cm,
          reason: 'a Thai vowel sign is SA with category Mn, so CM');
      expect(lineBreakClassOf(0x0378), LineBreakClass.al,
          reason: 'an unassigned code point is XX, so AL');
      expect(lineBreakClassOf(0x3400), LineBreakClass.id,
          reason: 'but an unassigned CJK ideograph defaults to ID');
    });
  });

  group('nextBreak', () {
    test('walks the opportunities in order', () {
      const String text = 'one two three';
      expect(LineBreaker.nextBreak(text, 0), 4);
      expect(LineBreaker.nextBreak(text, 4), 8);
      expect(LineBreaker.nextBreak(text, 8), text.length);
      expect(LineBreaker.nextBreak(text, text.length), text.length);
    });
  });

  group('UCD conformance', () {
    final List<String>? lines = ucdConformanceLines('LineBreakTest.txt');
    if (lines == null) {
      test('LineBreakTest.txt', () {},
          skip: 'missing: $ucdDataDirectory/LineBreakTest.txt.gz');
      return;
    }

    test('every case in LineBreakTest.txt', () {
      int cases = 0;
      final List<String> failures = <String>[];
      for (final String rawLine in lines) {
        final int hash = rawLine.indexOf('#');
        final String line =
            (hash >= 0 ? rawLine.substring(0, hash) : rawLine).trim();
        if (line.isEmpty) continue;
        cases++;

        final StringBuffer text = StringBuffer();
        final List<int> expected = <int>[];
        int offset = 0;
        for (final String token in line.split(RegExp(r'\s+'))) {
          if (token == '÷') {
            // LB2 forbids a break at the start of text; the file writes one
            // there anyway, so it is dropped rather than compared.
            if (offset > 0) expected.add(offset);
          } else if (token == '×' || token.isEmpty) {
            continue;
          } else {
            final int codePoint = int.parse(token, radix: 16);
            text.writeCharCode(codePoint);
            offset += codePoint > 0xFFFF ? 2 : 1;
          }
        }

        final List<int> actual = LineBreaker.breakOpportunities(text.toString())
            .map((LineBreakOpportunity o) => o.position)
            .toList();
        if (!_sameList(actual, expected)) {
          failures.add('$line\n  expected $expected got $actual');
          if (failures.length > 20) break;
        }
      }
      expect(cases, greaterThan(5000), reason: 'the file should be exhaustive');
      expect(failures, isEmpty, reason: 'of $cases cases');
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}

bool _sameList(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
