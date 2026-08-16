/// `GPOS` lookup types 3 and 5: cursive attachment and mark-to-ligature.
///
/// Both are Arabic-shaped holes, and neither has a fixture font here: the
/// faces in `test/fonts` are Latin, and a Latin font has no reason to join
/// glyph strokes or to anchor a vowel sign to one half of a ligature. So the
/// subtables are built byte by byte, which is also the only way to assert on a
/// null anchor or a malformed table without shipping a broken font.
///
/// The assertions are numeric on purpose. Cursive attachment that puts the
/// displacement on the wrong glyph of a pair still produces a joined-looking
/// word; mark-to-ligature that falls back to the last component still puts the
/// mark *somewhere* on the ligature. Neither failure is visible as an
/// exception, and both are visible as a coordinate.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/text/font_data.dart';
import 'package:dart_ui/src/text/gpos.dart';
import 'package:dart_ui/src/text/gsub.dart';
import 'package:dart_ui/src/text/layout_common.dart';
import 'package:test/test.dart';

/// Three joining letters, a mark, and the ligature the first two form.
const int _first = 1;
const int _second = 2;
const int _third = 3;
const int _ligature = 5;
const int _mark = 9;

/// A glyph no fixture covers, for the "the chain breaks here" tests.
const int _foreign = 77;

/// Every glyph starts one em wide, so a changed advance is unmistakable.
const double _advance = 1000;

void main() {
  group('cursive attachment (GPOS type 3)', () {
    test('a pair is joined and the later glyph is the one that moves', () {
      // The ordinary case: the lookup does not set RIGHT_TO_LEFT, so the glyph
      // that arrives is the one displaced onto the height the previous glyph's
      // stroke left at. Exit y is 100 and entry y is 20, so the second glyph
      // climbs 80 units.
      final GlyphBuffer buffer = _joiningBuffer(<int>[_first, _second]);

      _applyCursive(buffer);

      expect(buffer.cursiveAttachedTo, <int>[-1, 0]);
      expect(buffer.yOffsets, <double>[0, 80]);
      expect(buffer.xOffsets, <double>[0, 0]);
    });

    test('the join eats the gap between origin and anchor', () {
      // In-stream: the first glyph's advance is cut back to its exit anchor,
      // so the second glyph's origin lands exactly where the stroke left off.
      // Assigned rather than adjusted - the joined advance *is* the anchor.
      final GlyphBuffer buffer = _joiningBuffer(<int>[_first, _second]);

      _applyCursive(buffer);

      expect(buffer.xAdvances, <double>[700, _advance]);
    });

    test('a chain of three propagates the whole displacement', () {
      // What makes a Nastaliq word cascade instead of stepping once. The third
      // letter is 150 below its neighbour, which is itself 80 above the first:
      // 230, not 150. Resolving each link against the baseline instead of
      // against the parent is the bug this number catches.
      final GlyphBuffer buffer = _joiningBuffer(<int>[_first, _second, _third]);

      _applyCursive(buffer);
      expect(buffer.yOffsets, <double>[0, 80, 150],
          reason: 'each link is recorded relative to its parent');
      expect(buffer.cursiveAttachedTo, <int>[-1, 0, 1]);

      buffer.resolveAttachments();

      expect(buffer.yOffsets, <double>[0, 80, 230]);
      expect(buffer.xAdvances, <double>[700, 700, _advance]);
    });

    test('the RIGHT_TO_LEFT flag moves the other glyph of every pair', () {
      // The same anchors, the same run direction, one bit different in the
      // lookup - and it is the *earlier* glyph of each pair that is displaced,
      // so the chain runs the other way through the buffer and the last glyph
      // is the one left on the baseline. Reading this flag as "the text is
      // Arabic" and using the paragraph direction instead inverts the join on
      // exactly the fonts that bothered to state it.
      final GlyphBuffer buffer = _joiningBuffer(<int>[_first, _second, _third]);

      _applyCursive(buffer, flags: Lookup.flagRightToLeft);

      expect(buffer.cursiveAttachedTo, <int>[1, 2, -1]);
      buffer.resolveAttachments();
      expect(buffer.yOffsets, <double>[-230, -150, 0]);
    });

    test('the flag does not change which glyph gives up advance', () {
      // The two directions are separate decisions. The flag chose the child
      // above; the in-stream correction still follows the *run*, which is
      // still left to right, so the numbers are the ones from the plain case.
      final GlyphBuffer buffer = _joiningBuffer(<int>[_first, _second, _third]);

      _applyCursive(buffer, flags: Lookup.flagRightToLeft);

      expect(buffer.xAdvances, <double>[700, 700, _advance]);
    });

    test('a left-to-right run trims the leading glyph of each pair', () {
      final GlyphBuffer buffer = _joiningBuffer(<int>[_first, _second, _third]);

      _applyCursive(buffer);

      expect(buffer.xAdvances.first, 700);
      expect(buffer.xAdvances.last, _advance,
          reason: 'nothing joins onto the end of the run');
    });

    test('a right-to-left run trims the trailing glyph of each pair', () {
      // The mirror image, with a mirrored font: in right-to-left text a
      // stroke leaves at the *left* edge of a glyph and arrives at the right
      // edge of the next, so the anchors swap and so does the glyph that
      // gives up the gap. The first glyph now keeps its full advance.
      final GlyphBuffer buffer = _joiningBuffer(<int>[_first, _second, _third]);

      _applyCursive(buffer, entryX: 700, exitX: 0, rightToLeft: true);

      expect(buffer.xAdvances, <double>[_advance, 700, 700]);
      buffer.resolveAttachments();
      expect(buffer.yOffsets, <double>[0, 80, 230],
          reason: 'the run direction decides advances, not attachment');
    });

    test('a glyph with no exit anchor joins to nothing after it', () {
      // Null anchors are the format's way of saying "this form does not join
      // that way" - a final form has no exit - and they are ordinary rather
      // than exceptional. The third glyph's exit anchor is null.
      final GlyphBuffer buffer = _joiningBuffer(<int>[_third, _second]);

      _applyCursive(buffer);

      expect(buffer.cursiveAttachedTo, <int>[-1, -1]);
      expect(buffer.yOffsets, <double>[0, 0]);
      expect(buffer.xAdvances, <double>[_advance, _advance]);
    });

    test('a glyph with no entry anchor joins to nothing before it', () {
      // The first glyph's entry anchor is null: an initial form.
      final GlyphBuffer buffer = _joiningBuffer(<int>[_second, _first]);

      _applyCursive(buffer);

      expect(buffer.cursiveAttachedTo, <int>[-1, -1]);
      expect(buffer.xAdvances, <double>[_advance, _advance]);
    });

    test('an uncovered glyph breaks the chain', () {
      final GlyphBuffer buffer =
          _joiningBuffer(<int>[_first, _foreign, _second]);

      _applyCursive(buffer);

      expect(buffer.cursiveAttachedTo, <int>[-1, -1, -1]);
      expect(buffer.yOffsets, <double>[0, 0, 0]);
    });

    test('a mark between two letters does not break the join', () {
      // An Arabic vowel sign sits between two letters that are still joined
      // underneath it, which is why the previous glyph is found through the
      // lookup's filter rather than at index - 1.
      final GlyphBuffer buffer = _joiningBuffer(<int>[_first, _mark, _second]);

      _applyCursive(buffer,
          flags: Lookup.flagIgnoreMarks, gdef: _syntheticGdef());

      expect(buffer.cursiveAttachedTo, <int>[-1, -1, 0]);
      expect(buffer.yOffsets, <double>[0, 0, 80]);
    });

    test('an undefined subtable format is a font format error', () {
      expect(
        () => _applyCursive(_joiningBuffer(<int>[_first, _second]), format: 2),
        throwsA(isA<FontFormatException>()),
      );
    });
  });

  group('mark-to-ligature attachment (GPOS type 5)', () {
    test('a mark on the first component lands on the first anchor', () {
      final GlyphBuffer buffer = _ligatureBuffer(component: 1);

      _applyMarkToLigature(buffer);

      expect(buffer.attachedTo, <int>[-1, 0]);
      expect(buffer.xOffsets, <double>[0, 100]);
      expect(buffer.yOffsets, <double>[0, 700]);
    });

    test('a mark on the second component lands on the second anchor', () {
      // The whole point of the lookup type, in one number. Under mark-to-base
      // both marks would take the ligature's single anchor and stack on the
      // same half of the glyph.
      final GlyphBuffer buffer = _ligatureBuffer(component: 2);

      _applyMarkToLigature(buffer);

      expect(buffer.xOffsets[1], 400);
      expect(buffer.yOffsets[1], 700);
    });

    test('a mark on the third component of a three-part ligature', () {
      final GlyphBuffer buffer = _ligatureBuffer(component: 3);

      _applyMarkToLigature(buffer);

      expect(buffer.xOffsets[1], 800);
    });

    test('a mark that belongs to no ligature takes the last component', () {
      // A mark that merely trails a ligature it was never part of is being
      // attached at the end of it, which is where a trailing mark belongs.
      // Named fallback, not silence.
      final GlyphBuffer buffer = _ligatureBuffer(component: 0, ligatureId: 0);

      _applyMarkToLigature(buffer);

      expect(buffer.attachedTo, <int>[-1, 0]);
      expect(buffer.xOffsets[1], 800);
    });

    test('a mark from a different ligature takes the last component', () {
      final GlyphBuffer buffer =
          _ligatureBuffer(component: 1, markLigatureId: 7);

      _applyMarkToLigature(buffer);

      expect(buffer.xOffsets[1], 800);
    });

    test('a component number past the table takes the last component', () {
      // A font whose ligature has more components than it published anchors
      // for. Falling back to the last row is the alternative to reading two
      // bytes of whatever follows the table.
      final GlyphBuffer buffer = _ligatureBuffer(component: 9);

      _applyMarkToLigature(buffer);

      expect(buffer.xOffsets[1], 800);
    });

    test('a null anchor on the right component attaches nothing', () {
      // Legal and common: most components accept only some classes of mark.
      // The mark stays at the pen rather than being attached at (0, 0), and
      // nothing throws.
      final GlyphBuffer buffer = _ligatureBuffer(component: 2);

      _applyMarkToLigature(buffer,
          componentAnchors: const <int?>[100, null, 800]);

      expect(buffer.attachedTo, <int>[-1, -1]);
      expect(buffer.xOffsets, <double>[0, 0]);
      expect(buffer.yOffsets, <double>[0, 0]);
    });

    test('a null anchor on another component is not confused for this one', () {
      final GlyphBuffer buffer = _ligatureBuffer(component: 1);

      _applyMarkToLigature(buffer,
          componentAnchors: const <int?>[100, null, 800]);

      expect(buffer.attachedTo[1], 0);
      expect(buffer.xOffsets[1], 100);
    });

    test('a mark with no ligature before it is left alone', () {
      final GlyphBuffer buffer = GlyphBuffer()
        ..add(_foreign, 0)
        ..add(_mark, 1);

      _applyMarkToLigature(buffer);

      expect(buffer.attachedTo, <int>[-1, -1]);
    });

    test('an undefined subtable format is a font format error', () {
      expect(
        () => _applyMarkToLigature(_ligatureBuffer(component: 1), format: 2),
        throwsA(isA<FontFormatException>()),
      );
    });
  });

  group('ligature substitution feeds mark-to-ligature', () {
    test('a mark caught between two components ends up on the first', () {
      // The end-to-end path, and the one that is easy to get wrong: `GSUB`
      // merges the two letters across the mark, the mark survives after the
      // ligature, and the only remaining record of which letter it was on is
      // the component number ligature substitution wrote. Attached to the
      // second component instead, the mark would sit 300 units to the right.
      final GdefTable gdef = _syntheticGdef();
      final GlyphBuffer buffer = GlyphBuffer()
        ..add(_first, 0)
        ..add(_mark, 1)
        ..add(_second, 2);

      GsubTable.at(FontData(_ligatureGsub()), 0).apply(
        buffer,
        features: const <String>{'liga'},
        script: 'DFLT',
        gdef: gdef,
      );

      expect(buffer.glyphs, <int>[_ligature, _mark]);
      expect(buffer.ligatureComponents[1], 1);
      expect(buffer.ligatureIds[1], buffer.ligatureIds[0]);

      for (int i = 0; i < buffer.length; i++) {
        buffer.xAdvances[i] = i == 0 ? _advance : 0;
      }
      _applyMarkToLigature(buffer, gdef: gdef);

      expect(buffer.attachedTo, <int>[-1, 0]);
      expect(buffer.xOffsets[1], 100, reason: 'the first component');
      expect(buffer.yOffsets[1], 700);
    });

    test('resolving turns it into an offset from the run origin', () {
      final GdefTable gdef = _syntheticGdef();
      final GlyphBuffer buffer = GlyphBuffer()
        ..add(_first, 0)
        ..add(_mark, 1)
        ..add(_second, 2);

      GsubTable.at(FontData(_ligatureGsub()), 0).apply(
        buffer,
        features: const <String>{'liga'},
        script: 'DFLT',
        gdef: gdef,
      );
      buffer.xAdvances[0] = _advance;
      _applyMarkToLigature(buffer, gdef: gdef);
      buffer.resolveAttachments();

      // 100 into a ligature the pen has already passed by 1000. Forgetting
      // that subtraction puts every mark one glyph to the right.
      expect(buffer.xOffsets[1], -900);
      expect(buffer.yOffsets[1], 700);
      expect(buffer.attachedTo[1], -1);
    });
  });
}

// ---------------------------------------------------------------------------
// Applying the fixtures
// ---------------------------------------------------------------------------

/// A buffer of joining letters, each one em wide.
GlyphBuffer _joiningBuffer(List<int> glyphs) {
  final GlyphBuffer buffer = GlyphBuffer();
  for (int i = 0; i < glyphs.length; i++) {
    buffer.add(glyphs[i], i);
    buffer.xAdvances[i] = glyphs[i] == _mark ? 0 : _advance;
  }
  return buffer;
}

void _applyCursive(
  GlyphBuffer buffer, {
  int flags = 0,
  int entryX = 0,
  int exitX = 700,
  int format = 1,
  bool rightToLeft = false,
  GdefTable? gdef,
}) {
  GposTable.at(
    FontData(_cursiveGpos(
      flags: flags,
      entryX: entryX,
      exitX: exitX,
      format: format,
    )),
    0,
  ).apply(
    buffer,
    features: const <String>{'curs'},
    script: 'DFLT',
    gdef: gdef,
    rightToLeft: rightToLeft,
  );
}

/// A ligature glyph followed by a mark that claims to be on [component].
GlyphBuffer _ligatureBuffer({
  required int component,
  int ligatureId = 3,
  int? markLigatureId,
}) {
  final GlyphBuffer buffer = GlyphBuffer()
    ..add(_ligature, 0)
    ..add(_mark, 1);
  buffer.xAdvances[0] = _advance;
  buffer.ligatureIds[0] = ligatureId;
  buffer.ligatureComponentCounts[0] = 3;
  buffer.ligatureIds[1] = markLigatureId ?? ligatureId;
  buffer.ligatureComponents[1] = component;
  return buffer;
}

void _applyMarkToLigature(
  GlyphBuffer buffer, {
  List<int?> componentAnchors = const <int?>[100, 400, 800],
  int format = 1,
  GdefTable? gdef,
}) {
  GposTable.at(
    FontData(_markLigatureGpos(
      componentAnchors: componentAnchors,
      format: format,
    )),
    0,
  ).apply(
    buffer,
    features: const <String>{'mark'},
    script: 'DFLT',
    gdef: gdef ?? _syntheticGdef(),
  );
}

/// A `GDEF` that names the letters bases, [_ligature] a ligature and [_mark]
/// a mark - the classes every backwards search in `GPOS` turns on.
GdefTable _syntheticGdef() => GdefTable(
      glyphClasses: ClassDef.parse(
        FontData(_table((_Table t) {
          t.u16(0); // padding: offset zero would mean "no table"
          t.u16(2); // format 2, ranges
          t.u16(3);
          t.u16(_first);
          t.u16(_third);
          t.u16(GdefTable.classBase);
          t.u16(_ligature);
          t.u16(_ligature);
          t.u16(GdefTable.classLigature);
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

/// A `GPOS` whose only lookup joins [_first], [_second] and [_third].
///
/// The anchors are chosen so that every join is visible in two ways at once:
/// the exit heights differ from the entry heights, so a chain accumulates, and
/// the entry and exit abscissae differ from the advance, so the in-stream
/// correction is a number and not a rounding difference.
///
/// [_first] has no entry anchor and [_third] no exit anchor, which is how a
/// font writes an initial and a final form.
Uint8List _cursiveGpos({
  int flags = 0,
  int entryX = 0,
  int exitX = 700,
  int format = 1,
}) =>
    _table((_Table t) {
      _writeHeader(t, root: 'gpos', features: const <(String, List<int>)>[
        ('curs', <int>[0]),
      ]);

      t.label('lookups');
      t.u16(1);
      t.offset16('lookup', from: 'lookups');
      t.label('lookup');
      t.u16(3);
      t.u16(flags);
      t.u16(1);
      t.offset16('cursive', from: 'lookup');

      t.label('cursive');
      t.u16(format);
      t.offset16('coverage', from: 'cursive');
      t.u16(3); // entryExitCount

      t.u16(0); // _first: no entry anchor
      t.offset16('exit1', from: 'cursive');
      t.offset16('entry2', from: 'cursive');
      t.offset16('exit2', from: 'cursive');
      t.offset16('entry3', from: 'cursive');
      t.u16(0); // _third: no exit anchor

      _writeCoverage(t, 'coverage', const <int>[_first, _second, _third]);

      _writeAnchor(t, 'exit1', exitX, 100);
      _writeAnchor(t, 'entry2', entryX, 20);
      _writeAnchor(t, 'exit2', exitX, 200);
      _writeAnchor(t, 'entry3', entryX, 50);
    });

/// A `GPOS` whose only lookup anchors [_mark] to a component of [_ligature].
///
/// One mark class, because the class dimension is [_markToBase]'s business and
/// tested there; the component dimension is what this table exists for. A null
/// entry in [componentAnchors] writes a null offset, which is the format's way
/// of saying that component takes no mark of this class.
Uint8List _markLigatureGpos({
  List<int?> componentAnchors = const <int?>[100, 400, 800],
  int format = 1,
}) =>
    _table((_Table t) {
      _writeHeader(t, root: 'gpos', features: const <(String, List<int>)>[
        ('mark', <int>[0]),
      ]);

      t.label('lookups');
      t.u16(1);
      t.offset16('lookup', from: 'lookups');
      t.label('lookup');
      t.u16(5);
      t.u16(0);
      t.u16(1);
      t.offset16('markLig', from: 'lookup');

      t.label('markLig');
      t.u16(format);
      t.offset16('markCoverage', from: 'markLig');
      t.offset16('ligCoverage', from: 'markLig');
      t.u16(1); // markClassCount
      t.offset16('markArray', from: 'markLig');
      t.offset16('ligArray', from: 'markLig');

      _writeCoverage(t, 'markCoverage', const <int>[_mark]);
      _writeCoverage(t, 'ligCoverage', const <int>[_ligature]);

      t.label('markArray');
      t.u16(1);
      t.u16(0); // mark class
      t.offset16('markAnchor', from: 'markArray');
      _writeAnchor(t, 'markAnchor', 0, 0);

      t.label('ligArray');
      t.u16(1);
      t.offset16('ligAttach', from: 'ligArray');

      t.label('ligAttach');
      t.u16(componentAnchors.length);
      for (int i = 0; i < componentAnchors.length; i++) {
        if (componentAnchors[i] == null) {
          t.u16(0);
        } else {
          t.offset16('component$i', from: 'ligAttach');
        }
      }
      for (int i = 0; i < componentAnchors.length; i++) {
        final int? x = componentAnchors[i];
        if (x == null) continue;
        _writeAnchor(t, 'component$i', x, 700);
      }
    });

/// A `GSUB` that merges [_first] and [_second] into [_ligature], stepping over
/// marks - which is what leaves a mark stranded between two components.
Uint8List _ligatureGsub() => _table((_Table t) {
      _writeHeader(t, root: 'gsub', features: const <(String, List<int>)>[
        ('liga', <int>[0]),
      ]);

      t.label('lookups');
      t.u16(1);
      t.offset16('lookup', from: 'lookups');
      t.label('lookup');
      t.u16(4);
      t.u16(Lookup.flagIgnoreMarks);
      t.u16(1);
      t.offset16('ligature', from: 'lookup');

      t.label('ligature');
      t.u16(1);
      t.offset16('coverage', from: 'ligature');
      t.u16(1);
      t.offset16('ligSet', from: 'ligature');

      _writeCoverage(t, 'coverage', const <int>[_first]);

      t.label('ligSet');
      t.u16(1);
      t.offset16('lig', from: 'ligSet');
      t.label('lig');
      t.u16(_ligature);
      t.u16(2); // componentCount, the first being the covered glyph
      t.u16(_second);
    });

/// A format 1 anchor: coordinates in font units, y up.
void _writeAnchor(_Table t, String name, int x, int y) {
  t.label(name);
  t.u16(1);
  t.i16(x);
  t.i16(y);
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
void _writeHeader(
  _Table t, {
  required String root,
  required List<(String, List<int>)> features,
}) {
  t.label(root);
  t.u16(1);
  t.u16(0);
  t.offset16('scripts', from: root);
  t.offset16('features', from: root);
  t.offset16('lookups', from: root);

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

  void i16(int value) => u16(value & 0xFFFF);

  void tag(String value) => _bytes.addAll(value.codeUnits);

  void offset16(String label, {required String from}) {
    _fixups.add((at: _bytes.length, label: label, from: from, wide: false));
    u16(0);
  }

  Uint8List build() {
    final Uint8List bytes = Uint8List.fromList(_bytes);
    final ByteData view = ByteData.sublistView(bytes);
    for (final ({int at, String label, String from, bool wide}) fixup
        in _fixups) {
      final int delta = _labels[fixup.label]! - _labels[fixup.from]!;
      view.setUint16(fixup.at, delta);
    }
    return bytes;
  }
}

Uint8List _table(void Function(_Table) write) {
  final _Table table = _Table();
  write(table);
  return table.build();
}
