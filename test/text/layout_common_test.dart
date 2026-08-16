/// The bookkeeping [GlyphBuffer] does between lookups.
///
/// Two pieces of state here exist only because one lookup writes them and a
/// *different* lookup, later, reads them - which is precisely the kind of
/// coupling that breaks silently:
///
/// * **Ligature membership.** `GSUB` type 4 merges glyphs and records which
///   component of the resulting ligature each surviving mark belonged to;
///   `GPOS` type 5 reads it back to decide which half of an "fi" a dot goes
///   under. Nothing in between checks it, and a wrong component number is a
///   correctly-positioned mark on the wrong letter.
/// * **Cursive chains.** `GPOS` type 3 links joined glyphs while lookups are
///   still running, and the accumulated displacement is only computed at the
///   end. A chain resolved eagerly, or resolved twice, moves a word's letters
///   by the wrong amount rather than not at all.
///
/// Both are asserted here directly on the buffer, in numbers, so that a
/// failure names the arithmetic rather than a shaped string that looks odd.
library;

import 'package:dart_ui/src/text/layout_common.dart';
import 'package:test/test.dart';

const int _f = 1;
const int _i = 2;
const int _x = 3;
const int _mark = 9;
const int _ligature = 50;
const int _outerLigature = 51;

GlyphBuffer _bufferOf(List<int> glyphs) {
  final GlyphBuffer buffer = GlyphBuffer();
  for (int i = 0; i < glyphs.length; i++) {
    buffer.add(glyphs[i], i);
  }
  return buffer;
}

void main() {
  group('a fresh glyph belongs to no ligature', () {
    test('the three ligature arrays start neutral', () {
      final GlyphBuffer buffer = _bufferOf(<int>[_f, _i]);

      expect(buffer.ligatureIds, <int>[0, 0]);
      expect(buffer.ligatureComponents, <int>[0, 0]);
      expect(buffer.ligatureComponentCounts, <int>[1, 1],
          reason: 'an ordinary glyph is one component of itself');
      expect(buffer.cursiveAttachedTo, <int>[-1, -1]);
    });
  });

  group('ligature component accounting', () {
    test('two adjacent components leave one ligature glyph', () {
      final GlyphBuffer buffer = _bufferOf(<int>[_f, _i]);

      buffer.ligate(<int>[0, 1], _ligature);

      expect(buffer.glyphs, <int>[_ligature]);
      expect(buffer.ligatureIds[0], isNot(0), reason: 'it is a ligature now');
      expect(buffer.ligatureComponents[0], 0,
          reason: 'the ligature is not a component of itself');
      expect(buffer.ligatureComponentCounts[0], 2);
    });

    test('a mark between the components belongs to the first', () {
      // The case the whole mechanism exists for. "f", accent, "i" ligate
      // across the accent; the accent stays where it is and is now the only
      // thing that remembers it was sitting on the "f".
      final GlyphBuffer buffer = _bufferOf(<int>[_f, _mark, _i]);

      buffer.ligate(<int>[0, 2], _ligature);

      expect(buffer.glyphs, <int>[_ligature, _mark]);
      expect(buffer.ligatureIds[1], buffer.ligatureIds[0],
          reason: 'the mark and the ligature are the same ligature');
      expect(buffer.ligatureComponents[1], 1,
          reason: 'component numbers are one-based, and this is the first');
      expect(buffer.ligatureComponentCounts[1], 1);
    });

    test(
        'a mark between the second and third components belongs to the '
        'second', () {
      final GlyphBuffer buffer = _bufferOf(<int>[_f, _i, _mark, _x]);

      buffer.ligate(<int>[0, 1, 3], _ligature);

      expect(buffer.glyphs, <int>[_ligature, _mark]);
      expect(buffer.ligatureComponents[1], 2);
      expect(buffer.ligatureComponentCounts[0], 3);
    });

    test('two marks in different gaps get different components', () {
      final GlyphBuffer buffer = _bufferOf(<int>[_f, _mark, _i, _mark, _x]);

      buffer.ligate(<int>[0, 2, 4], _ligature);

      expect(buffer.glyphs, <int>[_ligature, _mark, _mark]);
      expect(buffer.ligatureComponents[1], 1);
      expect(buffer.ligatureComponents[2], 2);
      expect(buffer.clusters, <int>[0, 0, 0],
          reason: 'the whole span is one indivisible unit of text');
    });

    test('a mark inside a nested ligature keeps its component number', () {
      // "ff" first, then "ff" plus "i". The mark was on the first "f" and must
      // still be on the first component of the three, not on the first of two:
      // the outer ligature's first component is worth two, and forgetting that
      // is how a mark ends up one letter to the right.
      final GlyphBuffer buffer = _bufferOf(<int>[_f, _mark, _f, _i]);
      buffer.ligate(<int>[0, 2], _ligature);
      expect(buffer.ligatureComponents[1], 1, reason: 'inside "ff"');

      buffer.ligate(<int>[0, 2], _outerLigature);

      expect(buffer.glyphs, <int>[_outerLigature, _mark]);
      expect(buffer.ligatureComponentCounts[0], 3,
          reason: 'two components from the inner ligature plus the "i"');
      expect(buffer.ligatureComponents[1], 1);
    });

    test('a mark with no component of its own lands on the last one', () {
      // The mark follows an "ff" that is already a ligature and carries no
      // component number, so there is nothing to preserve - only a rule to
      // apply, and the rule is that such a mark sits at the *end* of the
      // component it follows. That component is the second "f".
      final GlyphBuffer buffer = _bufferOf(<int>[_f, _f, _mark, _i]);
      buffer.ligate(<int>[0, 1], _ligature);
      expect(buffer.ligatureComponentCounts[0], 2);
      expect(buffer.ligatureComponents[1], 0, reason: 'not inside "ff"');

      buffer.ligate(<int>[0, 2], _outerLigature);

      expect(buffer.glyphs, <int>[_outerLigature, _mark]);
      expect(buffer.ligatureComponents[1], 2);
      expect(buffer.ligatureComponentCounts[0], 3);
    });

    test('a mark trailing an absorbed ligature is renumbered', () {
      // The mark is *after* the inner ligature rather than between the outer
      // one's components, so the merge never steps over it - but it belonged
      // to a component that has just become part of something larger, and its
      // number is stated in the inner ligature's coordinates.
      final GlyphBuffer buffer = _bufferOf(<int>[_x, _f, _mark, _f]);
      buffer.ligate(<int>[1, 3], _ligature);
      final int innerId = buffer.ligatureIds[1];
      expect(buffer.glyphs, <int>[_x, _ligature, _mark]);
      expect(buffer.ligatureIds[2], innerId);
      expect(buffer.ligatureComponents[2], 1, reason: 'the first "f"');

      // Now "x" plus that "ff". The mark was on the first "f", which is the
      // second component of the three.
      buffer.ligate(<int>[0, 1], _outerLigature);

      expect(buffer.glyphs, <int>[_outerLigature, _mark]);
      expect(buffer.ligatureIds[1], buffer.ligatureIds[0]);
      expect(buffer.ligatureIds[1], isNot(innerId), reason: 'a new ligature');
      expect(buffer.ligatureComponents[1], 2);
      expect(buffer.ligatureComponentCounts[0], 3);
    });

    test('each ligature in a buffer gets its own id', () {
      // The only property anything relies on: mark-to-ligature compares ids
      // for equality, so two ligatures in one run must not collide.
      final GlyphBuffer buffer = _bufferOf(<int>[_f, _i, _f, _i]);

      buffer.ligate(<int>[0, 1], _ligature);
      buffer.ligate(<int>[1, 2], _ligature);

      expect(buffer.glyphs, <int>[_ligature, _ligature]);
      expect(buffer.ligatureIds[0], isNot(0));
      expect(buffer.ligatureIds[1], isNot(0));
      expect(buffer.ligatureIds[0], isNot(buffer.ligatureIds[1]));
    });

    test('clearing the buffer restarts the numbering', () {
      final GlyphBuffer buffer = _bufferOf(<int>[_f, _i]);
      buffer.ligate(<int>[0, 1], _ligature);
      final int first = buffer.ligatureIds[0];

      buffer.clear();
      buffer.add(_f, 0);
      buffer.add(_i, 1);
      buffer.ligate(<int>[0, 1], _ligature);

      expect(buffer.ligatureIds[0], first,
          reason: 'a reused buffer must not drift towards large serials');
      expect(buffer.length, 1);
    });

    test('expanding a glyph hands its membership to every piece', () {
      final GlyphBuffer buffer = _bufferOf(<int>[_f, _mark, _i]);
      buffer.ligate(<int>[0, 2], _ligature);
      final int id = buffer.ligatureIds[1];

      // The mark decomposes into two marks; both are still on component 1.
      buffer.expand(1, <int>[_mark, _mark]);

      expect(buffer.glyphs, <int>[_ligature, _mark, _mark]);
      expect(buffer.ligatureIds, <int>[id, id, id]);
      expect(buffer.ligatureComponents, <int>[0, 1, 1]);
      expect(buffer.ligatureComponentCounts, <int>[2, 1, 1]);
    });

    test('substituting a glyph leaves its membership alone', () {
      final GlyphBuffer buffer = _bufferOf(<int>[_f, _mark, _i]);
      buffer.ligate(<int>[0, 2], _ligature);

      buffer.substitute(1, _mark + 1);

      expect(buffer.ligatureComponents[1], 1);
      expect(buffer.ligatureIds[1], buffer.ligatureIds[0]);
    });
  });

  group('cursive chains', () {
    test('a link is recorded, not applied', () {
      final GlyphBuffer buffer = _bufferOf(<int>[_f, _i]);

      buffer.attachCursive(1, 0, 80);

      expect(buffer.cursiveAttachedTo, <int>[-1, 0]);
      expect(buffer.yOffsets, <double>[0, 80]);
    });

    test('a chain of three accumulates', () {
      // The property that makes a Nastaliq word cascade: each letter is placed
      // against its neighbour, and the third letter's displacement is the sum
      // of two links, not the second link alone.
      final GlyphBuffer buffer = _bufferOf(<int>[_f, _i, _x]);
      buffer.attachCursive(1, 0, 80);
      buffer.attachCursive(2, 1, 150);

      buffer.resolveAttachments();

      expect(buffer.yOffsets, <double>[0, 80, 230]);
      expect(buffer.cursiveAttachedTo, <int>[-1, -1, -1],
          reason: 'a resolved link is spent');
    });

    test('resolving twice does not double the displacement', () {
      final GlyphBuffer buffer = _bufferOf(<int>[_f, _i, _x]);
      buffer.attachCursive(1, 0, 80);
      buffer.attachCursive(2, 1, 150);

      buffer.resolveAttachments();
      buffer.resolveAttachments();

      expect(buffer.yOffsets, <double>[0, 80, 230]);
    });

    test('a chain may run backwards through the buffer', () {
      // Which glyph is the child is the lookup's business, not the buffer's,
      // and with the RIGHT_TO_LEFT flag set it is the *earlier* one. So the
      // parent index may exceed the child's, unlike mark attachment.
      final GlyphBuffer buffer = _bufferOf(<int>[_f, _i, _x]);
      buffer.attachCursive(1, 2, -150);
      buffer.attachCursive(0, 1, -80);

      buffer.resolveAttachments();

      expect(buffer.yOffsets, <double>[-230, -150, 0]);
    });

    test('relinking a glyph carries its old chain with it', () {
      // Glyph 1 hangs off glyph 0; then glyph 0 is joined to glyph 2 instead.
      // Glyph 1 must end up 50 units from glyph 0 still - it was never
      // unjoined - which is only true if the old link was reversed rather than
      // dropped.
      final GlyphBuffer buffer = _bufferOf(<int>[_f, _i, _x]);
      buffer.attachCursive(0, 1, 50);

      buffer.attachCursive(0, 2, 70);

      expect(buffer.cursiveAttachedTo, <int>[2, 0, -1],
          reason: 'the old link now points the other way');
      buffer.resolveAttachments();
      expect(buffer.yOffsets, <double>[70, 20, 0]);
      expect(buffer.yOffsets[0] - buffer.yOffsets[1], 50,
          reason: 'the original join survived the relink');
    });

    test('relinking to the parent it already had leaves the chain alone', () {
      // A second subtable joining the same pair replaces the cross-stream
      // displacement and nothing else: the reversal walk stops the moment it
      // sees the new parent, so the rest of the chain is untouched.
      final GlyphBuffer buffer = _bufferOf(<int>[_f, _i, _x]);
      buffer.attachCursive(0, 1, 50);
      buffer.attachCursive(1, 2, 30);

      buffer.attachCursive(0, 1, 70);

      expect(buffer.cursiveAttachedTo, <int>[1, 2, -1]);
      buffer.resolveAttachments();
      expect(buffer.yOffsets, <double>[100, 30, 0],
          reason: '70 from the new link plus the 30 its parent inherited');
    });

    test('two lookups linking the same pair both ways do not loop', () {
      // Reachable only from a font whose two cursive lookups disagree about
      // which glyph is the child - one with RIGHT_TO_LEFT set and one without.
      // The result is arbitrary, and the requirement is that it is *finite*:
      // an unguarded walk here hangs the shaper.
      final GlyphBuffer buffer = _bufferOf(<int>[_f, _i]);
      buffer.attachCursive(0, 1, 50);

      buffer.attachCursive(1, 0, 90);

      expect(buffer.cursiveAttachedTo, <int>[1, 0],
          reason: 'each glyph is now the other one\'s child');
      buffer.resolveAttachments();
      expect(buffer.cursiveAttachedTo, <int>[-1, -1]);
      expect(buffer.yOffsets[0].isFinite, isTrue);
      expect(buffer.yOffsets[1].isFinite, isTrue);
    });

    test('a hand-made cycle terminates instead of hanging', () {
      // The arrays are public, so the guard is asserted directly rather than
      // only through the sequence of calls that happens to produce a cycle.
      final GlyphBuffer buffer = _bufferOf(<int>[_f, _i, _x]);
      buffer.cursiveAttachedTo[0] = 1;
      buffer.cursiveAttachedTo[1] = 2;
      buffer.cursiveAttachedTo[2] = 0;

      buffer.resolveAttachments();

      expect(buffer.cursiveAttachedTo, <int>[-1, -1, -1]);
      for (int i = 0; i < 3; i++) {
        expect(buffer.yOffsets[i].isFinite, isTrue);
      }
    });

    test('a mark inherits the lift of the letter it sits on', () {
      // Cursive chains are resolved before marks for exactly this: the letter
      // moved off the baseline after the mark was attached to it.
      final GlyphBuffer buffer = _bufferOf(<int>[_f, _i, _mark]);
      buffer.xAdvances[0] = 700;
      buffer.xAdvances[1] = 700;
      buffer.attachCursive(1, 0, 80);
      buffer.xOffsets[2] = 200;
      buffer.yOffsets[2] = 300;
      buffer.attachedTo[2] = 1;

      buffer.resolveAttachments();

      expect(buffer.yOffsets[2], 380,
          reason: '300 above a letter raised by 80');
      expect(buffer.xOffsets[2], -500,
          reason: '200 into a glyph the pen has already passed by 700');
    });
  });

  group('reversing a run', () {
    test('the ligature arrays are reversed with everything else', () {
      final GlyphBuffer buffer = _bufferOf(<int>[_f, _mark, _i]);
      buffer.ligate(<int>[0, 2], _ligature);
      final int id = buffer.ligatureIds[0];

      buffer.reverse();

      expect(buffer.glyphs, <int>[_mark, _ligature]);
      expect(buffer.ligatureIds, <int>[id, id]);
      expect(buffer.ligatureComponents, <int>[1, 0],
          reason: 'the mark is still component 1 of the same ligature');
      expect(buffer.ligatureComponentCounts, <int>[1, 2]);
    });
  });

  group('lookup flags', () {
    test('RIGHT_TO_LEFT is readable and independent of the others', () {
      const Lookup plain = Lookup(
        type: 3,
        flags: 0,
        subtableOffsets: <int>[],
        markFilteringSet: 0,
      );
      const Lookup rtl = Lookup(
        type: 3,
        flags: Lookup.flagRightToLeft | Lookup.flagIgnoreMarks,
        subtableOffsets: <int>[],
        markFilteringSet: 0,
      );

      expect(plain.rightToLeft, isFalse);
      expect(rtl.rightToLeft, isTrue);
      expect(rtl.ignoreMarks, isTrue);
      expect(plain.ignoreMarks, isFalse);
    });
  });
}
