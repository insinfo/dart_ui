/// `GSUB` lookup type 8: reverse chaining contextual single substitution.
///
/// The one lookup that runs backwards, and the reason it gets a file of its
/// own: no fixture font here contains one. Type 8 is used almost exclusively
/// by Arabic - Nastaliq picks each letter's form from the form of the letter
/// *after* it, propagating right to left along a word - and the fonts in
/// `test/fonts` are Latin. So the subtables are built here byte by byte, which
/// is also the only way to assert on a malformed one without shipping a broken
/// font.
///
/// Every assertion below is on glyph ids after a real [GsubTable.apply], not
/// on parser internals, because the failure this file exists to catch is not a
/// crash: a type 8 applied in the wrong order still produces glyphs, and they
/// are the glyphs a font would have produced for different text.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/text/font_data.dart';
import 'package:dart_ui/src/text/gsub.dart';
import 'package:dart_ui/src/text/layout_common.dart';
import 'package:test/test.dart';

/// The glyph the rules below substitute, and what they substitute it with.
const int _input = 20;
const int _substitute = 99;

/// A glyph the rules require before the input, and one they require after.
const int _before = 10;
const int _after = 30;

/// A glyph `GDEF` calls a mark, for the "stepped over" tests.
const int _mark = 40;

void main() {
  group('reverse chaining single substitution (GSUB type 8)', () {
    test('it fires when both contexts match', () {
      final GlyphBuffer buffer = _bufferOf(<int>[_before, _input, _after]);

      _applyReverse(buffer);

      expect(buffer.glyphs, <int>[_before, _substitute, _after]);
      expect(buffer.length, 3, reason: 'it substitutes one for one, always');
    });

    test('a wrong backtrack glyph stops it', () {
      final GlyphBuffer buffer = _bufferOf(<int>[_before + 1, _input, _after]);

      _applyReverse(buffer);

      expect(buffer.glyphs, <int>[_before + 1, _input, _after]);
    });

    test('a wrong lookahead glyph stops it', () {
      final GlyphBuffer buffer = _bufferOf(<int>[_before, _input, _after + 1]);

      _applyReverse(buffer);

      expect(buffer.glyphs, <int>[_before, _input, _after + 1]);
    });

    test('a missing backtrack glyph stops it', () {
      // The input is the first glyph of the run, so there is nothing before
      // it. A rule that requires one glyph of backtrack must not match, and
      // must not read past the start of the buffer looking for it.
      final GlyphBuffer buffer = _bufferOf(<int>[_input, _after]);

      _applyReverse(buffer);

      expect(buffer.glyphs, <int>[_input, _after]);
    });

    test('a missing lookahead glyph stops it', () {
      final GlyphBuffer buffer = _bufferOf(<int>[_before, _input]);

      _applyReverse(buffer);

      expect(buffer.glyphs, <int>[_before, _input]);
    });

    test('a glyph outside the input coverage is left alone', () {
      final GlyphBuffer buffer = _bufferOf(<int>[_before, _input + 1, _after]);

      _applyReverse(buffer);

      expect(buffer.glyphs, <int>[_before, _input + 1, _after]);
    });

    test('backtrack means earlier in the buffer, not earlier on the page', () {
      // The buffer is in logical order for the whole of layout - `shaper.dart`
      // reverses it into visual order once, at the very end - so a rule that
      // wants "_before" before the input wants it at a *lower index*, in
      // right-to-left text as much as in left-to-right. Reading the rule
      // visually would make this mirrored run match, and it must not.
      final GlyphBuffer buffer = _bufferOf(<int>[_after, _input, _before]);

      _applyReverse(buffer);

      expect(buffer.glyphs, <int>[_after, _input, _before]);
    });
  });

  group('the sweep runs backwards', () {
    test('a substitution is visible to the rule that runs after it', () {
      // The point of the whole lookup type, made observable. The rule accepts
      // either the original following glyph or the substitute as lookahead, so
      // a decision propagates leftwards one glyph at a time:
      //
      //   backwards (correct): index 1 sees _after and becomes _substitute,
      //     then index 0 sees that new _substitute and becomes one too.
      //   forwards (wrong): index 0 sees an unchanged _input and does not
      //     match; only index 1 is substituted.
      //
      // So [_substitute, _substitute, _after] and [_input, _substitute,
      // _after] distinguish the two orders exactly.
      final GlyphBuffer buffer = _bufferOf(<int>[_input, _input, _after]);

      _applyReverse(
        buffer,
        backtrack: const <List<int>>[],
        lookahead: const <List<int>>[
          <int>[_after, _substitute]
        ],
      );

      expect(buffer.glyphs, <int>[_substitute, _substitute, _after]);
    });

    test('a chain of four propagates the whole way', () {
      final GlyphBuffer buffer =
          _bufferOf(<int>[_input, _input, _input, _after]);

      _applyReverse(
        buffer,
        backtrack: const <List<int>>[],
        lookahead: const <List<int>>[
          <int>[_after, _substitute]
        ],
      );

      expect(
          buffer.glyphs, <int>[_substitute, _substitute, _substitute, _after]);
    });

    test('the propagation stops where the context does', () {
      // A glyph that is not in the input coverage breaks the chain, and
      // everything before it stays as it was. Without this the test above
      // could pass on an implementation that substituted the whole run.
      final GlyphBuffer buffer =
          _bufferOf(<int>[_input, _before, _input, _after]);

      _applyReverse(
        buffer,
        backtrack: const <List<int>>[],
        lookahead: const <List<int>>[
          <int>[_after, _substitute]
        ],
      );

      expect(buffer.glyphs, <int>[_input, _before, _substitute, _after]);
    });

    test('an extension-wrapped type 8 still runs backwards', () {
      // A font compiler that outgrew 16-bit offsets wraps every lookup it
      // emits, so this is the shape a real Nastaliq font ships. A shaper that
      // decided the direction from the *wrapper's* type would sweep forwards
      // here and produce the other answer.
      final GlyphBuffer buffer = _bufferOf(<int>[_input, _input, _after]);

      _applyReverse(
        buffer,
        backtrack: const <List<int>>[],
        lookahead: const <List<int>>[
          <int>[_after, _substitute]
        ],
        extension: true,
      );

      expect(buffer.glyphs, <int>[_substitute, _substitute, _after]);
    });
  });

  group('it cannot be called by anything', () {
    test('a contextual lookup naming it substitutes nothing', () {
      // The spec forbids a sequence lookup record from pointing at a reverse
      // chaining lookup, because "apply it at this one position" is not a
      // thing it can do - its meaning is the order its whole sweep runs in.
      // Refused by name; the contextual rule matches and then does nothing.
      final GlyphBuffer buffer = _bufferOf(<int>[_input]);

      GsubTable.at(FontData(_nestedGsub()), 0).apply(
        buffer,
        features: const <String>{'rclt'},
        script: 'DFLT',
      );

      expect(buffer.glyphs, <int>[_input]);
    });

    test('the same lookup applied directly does substitute', () {
      // The control. Without it the test above passes on a table whose
      // reverse lookup was simply never reachable.
      final GlyphBuffer buffer = _bufferOf(<int>[_input]);

      GsubTable.at(FontData(_nestedGsub()), 0).apply(
        buffer,
        features: const <String>{'rlig'},
        script: 'DFLT',
      );

      expect(buffer.glyphs, <int>[_substitute]);
    });
  });

  group('lookup flags', () {
    test('a mark is stepped over when the lookup ignores marks', () {
      // An Arabic vowel sign between two letters must not break a contextual
      // rule that joins them, which is why the rule is matched through the
      // lookup's filter rather than over raw buffer positions.
      final GlyphBuffer buffer =
          _bufferOf(<int>[_before, _mark, _input, _after]);

      _applyReverse(buffer,
          flags: Lookup.flagIgnoreMarks, gdef: _syntheticGdef());

      expect(buffer.glyphs, <int>[_before, _mark, _substitute, _after]);
    });

    test('without the flag the mark blocks the rule', () {
      // The same buffer, the same table, one bit different - so the test above
      // is provably about the filter and not about the backtrack being
      // ignored entirely.
      final GlyphBuffer buffer =
          _bufferOf(<int>[_before, _mark, _input, _after]);

      _applyReverse(buffer, gdef: _syntheticGdef());

      expect(buffer.glyphs, <int>[_before, _mark, _input, _after]);
    });
  });

  group('malformed subtables', () {
    test('a substitute array shorter than the coverage substitutes nothing',
        () {
      // The substitute array is indexed by coverage index, so a font whose two
      // arrays disagree has no answer for the later glyphs. Reading one anyway
      // would substitute a glyph id made of whatever bytes follow the table.
      final GlyphBuffer covered = _bufferOf(<int>[_before, _input, _after]);
      final GlyphBuffer beyond = _bufferOf(<int>[_before, _input + 1, _after]);
      final Uint8List table = _reverseGsub(
        input: const <int>[_input, _input + 1],
        substitutes: const <int>[_substitute],
      );

      GsubTable.at(FontData(table), 0)
          .apply(covered, features: const <String>{'rclt'}, script: 'DFLT');
      GsubTable.at(FontData(table), 0)
          .apply(beyond, features: const <String>{'rclt'}, script: 'DFLT');

      expect(covered.glyphs, <int>[_before, _substitute, _after],
          reason: 'the glyph the array does cover is still substituted');
      expect(beyond.glyphs, <int>[_before, _input + 1, _after]);
    });

    test('an undefined subtable format is a font format error', () {
      expect(
        () => GsubTable.at(FontData(_reverseGsub(format: 2)), 0).apply(
          _bufferOf(<int>[_before, _input, _after]),
          features: const <String>{'rclt'},
          script: 'DFLT',
        ),
        throwsA(isA<FontFormatException>()),
      );
    });

    test('an empty run is not swept off the front of the buffer', () {
      final GlyphBuffer buffer = GlyphBuffer();

      _applyReverse(buffer);

      expect(buffer.isEmpty, isTrue);
    });
  });
}

// ---------------------------------------------------------------------------
// Applying the fixtures
// ---------------------------------------------------------------------------

/// Runs the reverse lookup of a table built to order over [buffer].
void _applyReverse(
  GlyphBuffer buffer, {
  List<List<int>> backtrack = const <List<int>>[
    <int>[_before]
  ],
  List<List<int>> lookahead = const <List<int>>[
    <int>[_after]
  ],
  bool extension = false,
  int flags = 0,
  GdefTable? gdef,
}) {
  GsubTable.at(
    FontData(_reverseGsub(
      backtrack: backtrack,
      lookahead: lookahead,
      extension: extension,
      flags: flags,
    )),
    0,
  ).apply(
    buffer,
    features: const <String>{'rclt'},
    script: 'DFLT',
    gdef: gdef,
  );
}

GlyphBuffer _bufferOf(List<int> glyphs) {
  final GlyphBuffer buffer = GlyphBuffer();
  for (int i = 0; i < glyphs.length; i++) {
    buffer.add(glyphs[i], i);
  }
  return buffer;
}

/// A `GDEF` that calls [_mark] a mark and everything else a base.
GdefTable _syntheticGdef() => GdefTable(
      glyphClasses: ClassDef.parse(
        FontData(_table((_Table t) {
          t.u16(0); // padding: offset zero would mean "no table"
          t.u16(2); // format 2, ranges
          t.u16(2);
          t.u16(0);
          t.u16(_mark - 1);
          t.u16(GdefTable.classBase);
          t.u16(_mark);
          t.u16(_mark);
          t.u16(GdefTable.classMark);
        })),
        2,
      ),
      markAttachClasses: ClassDef.empty,
      markGlyphSets: const <Coverage>[],
    );

// ---------------------------------------------------------------------------
// Building tables by hand
// ---------------------------------------------------------------------------

/// A `GSUB` whose only lookup is a reverse chaining single substitution.
///
/// One coverage table per backtrack and lookahead element, as the format
/// requires - the arrays are of *coverages*, not of glyphs, and each element
/// is a set. [backtrack] is written nearest-first, which is the file's order
/// and the opposite of how the rule reads on the page.
Uint8List _reverseGsub({
  List<List<int>> backtrack = const <List<int>>[
    <int>[_before]
  ],
  List<int> input = const <int>[_input],
  List<List<int>> lookahead = const <List<int>>[
    <int>[_after]
  ],
  List<int> substitutes = const <int>[_substitute],
  bool extension = false,
  int flags = 0,
  int format = 1,
}) =>
    _table((_Table t) {
      _writeHeader(t, features: const <(String, List<int>)>[
        ('rclt', <int>[0]),
      ]);

      t.label('lookups');
      t.u16(1);
      t.offset16('lookup', from: 'lookups');
      t.label('lookup');
      t.u16(extension ? 7 : 8);
      t.u16(flags);
      t.u16(1);
      t.offset16(extension ? 'extension' : 'reverse', from: 'lookup');

      if (extension) {
        t.label('extension');
        t.u16(1);
        t.u16(8);
        t.offset32('reverse', from: 'extension');
      }

      _writeReverse(
        t,
        name: 'reverse',
        backtrack: backtrack,
        input: input,
        lookahead: lookahead,
        substitutes: substitutes,
        format: format,
      );
    });

/// A `GSUB` with a reverse lookup at index 0 and a context lookup at index 1
/// that names it, plus one feature selecting each.
///
/// The pair is the only way to test the prohibition: `rclt` reaches the
/// context lookup, which matches and then tries to call the reverse one;
/// `rlig` reaches the reverse lookup directly, and must still work.
Uint8List _nestedGsub() => _table((_Table t) {
      _writeHeader(t, features: const <(String, List<int>)>[
        ('rclt', <int>[1]),
        ('rlig', <int>[0]),
      ]);

      t.label('lookups');
      t.u16(2);
      t.offset16('reverseLookup', from: 'lookups');
      t.offset16('contextLookup', from: 'lookups');

      t.label('reverseLookup');
      t.u16(8);
      t.u16(0);
      t.u16(1);
      t.offset16('reverse', from: 'reverseLookup');

      t.label('contextLookup');
      t.u16(5);
      t.u16(0);
      t.u16(1);
      t.offset16('context', from: 'contextLookup');

      // Context format 3: one input coverage, one "then run lookup 0 here".
      t.label('context');
      t.u16(3);
      t.u16(1); // glyphCount
      t.u16(1); // seqLookupCount
      t.offset16('contextCoverage', from: 'context');
      t.u16(0); // sequenceIndex
      t.u16(0); // lookupIndex - the reverse lookup
      _writeCoverage(t, 'contextCoverage', const <int>[_input]);

      _writeReverse(
        t,
        name: 'reverse',
        backtrack: const <List<int>>[],
        input: const <int>[_input],
        lookahead: const <List<int>>[],
        substitutes: const <int>[_substitute],
        format: 1,
      );
    });

/// One `ReverseChainSingleSubstFormat1` subtable, labelled [name].
void _writeReverse(
  _Table t, {
  required String name,
  required List<List<int>> backtrack,
  required List<int> input,
  required List<List<int>> lookahead,
  required List<int> substitutes,
  required int format,
}) {
  t.label(name);
  t.u16(format);
  t.offset16('$name.input', from: name);
  t.u16(backtrack.length);
  for (int i = 0; i < backtrack.length; i++) {
    t.offset16('$name.bt$i', from: name);
  }
  t.u16(lookahead.length);
  for (int i = 0; i < lookahead.length; i++) {
    t.offset16('$name.la$i', from: name);
  }
  t.u16(substitutes.length);
  for (final int glyph in substitutes) {
    t.u16(glyph);
  }

  _writeCoverage(t, '$name.input', input);
  // Each element of the two arrays is a set of its own. The fixtures here use
  // one-glyph sets except where a test needs a rule to accept either the
  // original glyph or its substitute.
  for (int i = 0; i < backtrack.length; i++) {
    _writeCoverage(t, '$name.bt$i', backtrack[i]);
  }
  for (int i = 0; i < lookahead.length; i++) {
    _writeCoverage(t, '$name.la$i', lookahead[i]);
  }
}

/// A format 1 coverage table, sorted because the format requires ascending
/// order and a binary search over an unsorted one silently misses glyphs.
void _writeCoverage(_Table t, String name, List<int> glyphs) {
  final List<int> sorted = <int>[...glyphs]..sort();
  t.label(name);
  t.u16(1);
  t.u16(sorted.length);
  for (final int glyph in sorted) {
    t.u16(glyph);
  }
}

/// The script and feature scaffolding, with one entry per (tag, lookups) pair.
void _writeHeader(_Table t, {required List<(String, List<int>)> features}) {
  t.label('gsub');
  t.u16(1);
  t.u16(0);
  t.offset16('scripts', from: 'gsub');
  t.offset16('features', from: 'gsub');
  t.offset16('lookups', from: 'gsub');

  t.label('scripts');
  t.u16(1);
  t.tag('DFLT');
  t.offset16('script', from: 'scripts');
  t.label('script');
  t.offset16('langSys', from: 'script');
  t.u16(0);
  t.label('langSys');
  t.u16(0); // lookupOrder
  t.u16(0xFFFF); // no required feature
  t.u16(features.length);
  for (int i = 0; i < features.length; i++) {
    t.u16(i);
  }

  t.label('features');
  t.u16(features.length);
  for (int i = 0; i < features.length; i++) {
    t.tag(features[i].$1);
    t.offset16('feature$i', from: 'features');
  }
  for (int i = 0; i < features.length; i++) {
    t.label('feature$i');
    t.u16(0); // featureParams
    t.u16(features[i].$2.length);
    for (final int lookup in features[i].$2) {
      t.u16(lookup);
    }
  }
}

/// A big-endian byte builder with named, back-patched offsets.
///
/// A layout table is a graph of offsets, each relative to a different base,
/// and writing one with literal numbers means recomputing every offset
/// whenever a field is added. Labels make the fixtures readable and, more
/// importantly, make them wrong in obvious ways rather than subtle ones.
final class _Table {
  final List<int> _bytes = <int>[];
  final Map<String, int> _labels = <String, int>{};
  final List<({int at, String label, String from, bool wide})> _fixups =
      <({int at, String label, String from, bool wide})>[];

  void label(String name) => _labels[name] = _bytes.length;

  void u16(int value) {
    _bytes.add((value >> 8) & 0xFF);
    _bytes.add(value & 0xFF);
  }

  void u32(int value) {
    u16((value >> 16) & 0xFFFF);
    u16(value & 0xFFFF);
  }

  void tag(String value) => _bytes.addAll(value.codeUnits);

  void offset16(String label, {required String from}) {
    _fixups.add((at: _bytes.length, label: label, from: from, wide: false));
    u16(0);
  }

  void offset32(String label, {required String from}) {
    _fixups.add((at: _bytes.length, label: label, from: from, wide: true));
    u32(0);
  }

  Uint8List build() {
    final Uint8List bytes = Uint8List.fromList(_bytes);
    final ByteData view = ByteData.sublistView(bytes);
    for (final ({int at, String label, String from, bool wide}) fixup
        in _fixups) {
      final int delta = _labels[fixup.label]! - _labels[fixup.from]!;
      if (fixup.wide) {
        view.setUint32(fixup.at, delta);
      } else {
        view.setUint16(fixup.at, delta);
      }
    }
    return bytes;
  }
}

Uint8List _table(void Function(_Table) write) {
  final _Table table = _Table();
  write(table);
  return table.build();
}
