/// Grapheme cluster boundaries (UAX #29).
///
/// Two layers. The hand-written cases below name the failures a text field
/// would actually show - a caret splitting an accent off its letter, backspace
/// eating half a surrogate pair, a flag coming apart into two letters. The
/// conformance suite at the bottom is the Unicode Consortium's own exhaustive
/// pairwise test, which is worth more than any list a person would think to
/// write.
library;

import 'package:dart_ui/src/text/grapheme.dart';
import 'package:test/test.dart';

import '../data/unicode/ucd_data.dart';

void main() {
  group('cluster boundaries', () {
    test('empty text has one boundary, not two', () {
      // GB1 and GB2 coincide at offset 0. Returning [0, 0] would make every
      // consumer that pairs adjacent boundaries emit one phantom cluster.
      expect(GraphemeBreaks.boundaries(''), <int>[0]);
      expect(GraphemeBreaks.clusters(''), isEmpty);
    });

    test('plain ASCII is one cluster per character', () {
      expect(GraphemeBreaks.clusters('abc'), <String>['a', 'b', 'c']);
    });

    test('a combining accent stays with its base', () {
      // e + COMBINING ACUTE. Two code points, one thing the user can delete.
      const String text = 'é';
      expect(GraphemeBreaks.clusters(text), <String>[text]);
      expect(GraphemeBreaks.previous(text, text.length), 0);
    });

    test('several combining marks all stay with one base', () {
      const String text = 'ä̧́';
      expect(GraphemeBreaks.clusters(text), <String>[text]);
    });

    test('a surrogate pair is one cluster', () {
      // U+1D400 MATHEMATICAL BOLD CAPITAL A: two UTF-16 units, one character.
      const String text = '\u{1D400}';
      expect(text.length, 2, reason: 'the test needs a non-BMP code point');
      expect(GraphemeBreaks.clusters(text), <String>[text]);
      expect(GraphemeBreaks.isBoundary(text, 1), isFalse);
      expect(GraphemeBreaks.previous(text, 2), 0);
    });

    test('an emoji with a variation selector is one cluster', () {
      const String text = '❤️';
      expect(GraphemeBreaks.clusters(text), <String>[text]);
    });

    test('an emoji with a skin tone modifier is one cluster', () {
      const String text = '\u{1F44D}\u{1F3FD}';
      expect(GraphemeBreaks.clusters(text), <String>[text]);
    });

    test('a regional indicator pair is one flag', () {
      const String br = '\u{1F1E7}\u{1F1F7}';
      expect(GraphemeBreaks.clusters(br), <String>[br]);
    });

    test('four regional indicators are two flags, not one blob', () {
      // GB12/GB13 count parity. An implementation that merely says "RI joins
      // RI" glues a whole row of flags into a single uneditable cluster.
      const String br = '\u{1F1E7}\u{1F1F7}';
      const String pt = '\u{1F1F5}\u{1F1F9}';
      expect(GraphemeBreaks.clusters('$br$pt'), <String>[br, pt]);
    });

    test('a ZWJ emoji sequence is one cluster', () {
      const String family = '\u{1F468}‍\u{1F469}‍\u{1F467}';
      expect(GraphemeBreaks.clusters(family), <String>[family]);
    });

    test('CRLF is one cluster but CR and LF apart are two', () {
      expect(GraphemeBreaks.clusters('\r\n'), <String>['\r\n']);
      expect(GraphemeBreaks.clusters('\n\r'), <String>['\n', '\r']);
    });

    test('a Hangul syllable spelled with jamo is one cluster', () {
      // U+1100 HANGUL CHOSEONG KIYEOK + U+1161 JUNGSEONG A + U+11A8 JONGSEONG.
      const String text = '각';
      expect(GraphemeBreaks.clusters(text), <String>[text]);
    });

    test('an Indic conjunct joined by a virama is one cluster', () {
      // GB9c. DEVANAGARI KA + VIRAMA + SSA: without the rule the caret lands
      // between the virama and the second consonant, inside one glyph.
      const String text = 'क्ष';
      expect(GraphemeBreaks.clusters(text), <String>[text]);
    });
  });

  group('caret movement', () {
    const String text = 'á\u{1F1E7}\u{1F1F7}b';

    test('next walks cluster by cluster and stops at the end', () {
      final List<int> visited = <int>[0];
      int position = 0;
      while (position < text.length) {
        position = GraphemeBreaks.next(text, position);
        visited.add(position);
      }
      expect(visited, GraphemeBreaks.boundaries(text));
    });

    test('previous is the exact inverse of next', () {
      for (final int mark in GraphemeBreaks.boundaries(text)) {
        if (mark == text.length) continue;
        expect(GraphemeBreaks.previous(text, GraphemeBreaks.next(text, mark)),
            mark);
      }
    });

    test('an index inside a cluster is not a boundary', () {
      expect(GraphemeBreaks.isBoundary(text, 1), isFalse,
          reason: 'between the a and its accent');
      expect(GraphemeBreaks.isBoundary(text, 3), isFalse,
          reason: 'inside the first regional indicator surrogate pair');
      expect(GraphemeBreaks.isBoundary(text, 4), isFalse,
          reason: 'between the two halves of the flag');
    });

    test('out-of-range indices clamp instead of throwing', () {
      expect(GraphemeBreaks.next(text, -5), GraphemeBreaks.next(text, 0));
      expect(GraphemeBreaks.next(text, 999), text.length);
      expect(GraphemeBreaks.previous(text, -5), 0);
      expect(GraphemeBreaks.previous(text, 999),
          GraphemeBreaks.previous(text, text.length));
    });

    test('a long run of extenders does not cost the whole paragraph', () {
      // Not a timing assertion - just that the bounded backward seek in
      // _seekTo produces the same answer as a scan from offset zero would.
      final String long = '${'x' * 5000}é́́';
      expect(GraphemeBreaks.previous(long, long.length), 5000);
    });
  });

  group('degenerate input', () {
    test('a lone high surrogate is its own cluster', () {
      const String text = 'a\uD800b';
      expect(GraphemeBreaks.clusters(text), <String>['a', '\uD800', 'b']);
    });

    test('a lone low surrogate is its own cluster', () {
      const String text = 'a\uDC00b';
      expect(GraphemeBreaks.clusters(text), <String>['a', '\uDC00', 'b']);
    });
  });

  group('property lookup', () {
    test('classes match the UCD for a spot sample', () {
      expect(graphemeClassOf(0x000D), GraphemeClass.cr);
      expect(graphemeClassOf(0x000A), GraphemeClass.lf);
      expect(graphemeClassOf(0x0000), GraphemeClass.control);
      expect(graphemeClassOf(0x0301), GraphemeClass.extend);
      expect(graphemeClassOf(0x200D), GraphemeClass.zwj);
      expect(graphemeClassOf(0x1F1E6), GraphemeClass.regionalIndicator);
      expect(graphemeClassOf(0x0600), GraphemeClass.prepend);
      expect(graphemeClassOf(0x0903), GraphemeClass.spacingMark);
      expect(graphemeClassOf(0x1100), GraphemeClass.hangulL);
      expect(graphemeClassOf(0xAC00), GraphemeClass.hangulLV);
      expect(graphemeClassOf(0xAC01), GraphemeClass.hangulLVT);
      expect(graphemeClassOf(0x0041), GraphemeClass.other);
    });

    test('extended pictographic covers emoji and not letters', () {
      expect(isExtendedPictographic(0x1F600), isTrue);
      expect(isExtendedPictographic(0x00A9), isTrue, reason: 'copyright sign');
      expect(isExtendedPictographic(0x0041), isFalse);
    });
  });

  group('UCD conformance', () {
    final List<String>? lines = ucdConformanceLines('GraphemeBreakTest.txt');
    if (lines == null) {
      test('GraphemeBreakTest.txt', () {},
          skip: 'missing: $ucdDataDirectory/GraphemeBreakTest.txt.gz');
      return;
    }

    test('every case in GraphemeBreakTest.txt', () {
      int cases = 0;
      final List<String> failures = <String>[];
      for (final String rawLine in lines) {
        final _ConformanceCase? item = _parse(rawLine);
        if (item == null) continue;
        cases++;
        final List<int> actual = GraphemeBreaks.boundaries(item.text);
        if (!_sameList(actual, item.expected)) {
          failures.add('${item.source}\n  expected $item.expected got $actual');
        }
      }
      expect(cases, greaterThan(500), reason: 'the file should be exhaustive');
      expect(failures, isEmpty,
          reason: '${failures.length} of $cases cases failed');
    });
  });
}

final class _ConformanceCase {
  _ConformanceCase(this.text, this.expected, this.source);

  final String text;
  final List<int> expected;
  final String source;
}

/// Parses one `÷ 0061 × 0301 ÷` line into text plus expected UTF-16 boundaries.
_ConformanceCase? _parse(String rawLine) {
  final int hash = rawLine.indexOf('#');
  final String line = (hash >= 0 ? rawLine.substring(0, hash) : rawLine).trim();
  if (line.isEmpty) return null;

  final StringBuffer text = StringBuffer();
  final List<int> expected = <int>[];
  int offset = 0;
  for (final String token in line.split(RegExp(r'\s+'))) {
    if (token == '÷') {
      expected.add(offset);
    } else if (token == '×') {
      // an explicit non-break: nothing to record
    } else if (token.isNotEmpty) {
      final int codePoint = int.parse(token, radix: 16);
      text.writeCharCode(codePoint);
      offset += codePoint > 0xFFFF ? 2 : 1;
    }
  }
  return _ConformanceCase(text.toString(), expected, line);
}

bool _sameList(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
