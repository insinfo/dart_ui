/// Arabic shaping: the joining machine, the per-glyph positional features, the
/// mandatory ligature, and the direction the cursive correction follows.
///
/// Two kinds of fixture, and the split is deliberate.
///
/// **DejaVu**, which really does cover Arabic and Hebrew - asserted rather than
/// assumed, in the first group - carries `ccmp`, `fina`, `medi`, `init`, `rlig`
/// and `liga` under its `arab` script. That makes every substitution assertion
/// here a statement about a shipping font rather than about a fixture built to
/// agree with the implementation.
///
/// **DejaVu with tables replaced** covers the two things no shipping fixture
/// can. DejaVu has no `curs` feature - almost no text face does; cursive
/// attachment is a Nastaliq and display-face technique - so the right-to-left
/// advance correction is proved against a synthetic `GPOS` grafted onto the
/// real font, which keeps the real `cmap`, the real advances and the real
/// glyph ids. And the lam-alef fallback only fires for a font that states no
/// rule for the pair, which is produced by removing `GSUB` outright.
library;

import 'dart:io';
import 'dart:typed_data';

// `shaper.dart` re-exports the joining forms and the script models, which is
// the surface a caller shapes through; importing them separately would say
// they are a different layer than they are.
import 'package:dart_ui/src/text/shaper.dart';
import 'package:dart_ui/src/text/typeface.dart';
import 'package:test/test.dart';

// Letters, named so the assertions read as Arabic rather than as hex.
const String _alef = 'ا'; // ا  Joining_Type R, Joining_Group Alef
const String _beh = 'ب'; // ب  Joining_Type D, Joining_Group Beh
const String _teh = 'ت'; // ت  Joining_Type D
const String _seen = 'س'; // س Joining_Type D
const String _kaf = 'ك'; // ك  Joining_Type D
const String _lam = 'ل'; // ل  Joining_Type D, Joining_Group Lam
const String _meem = 'م'; // م Joining_Type D
const String _waw = 'و'; // و  Joining_Type R
const String _fatha = 'َ'; // ◌َ Joining_Type T - a mark
const String _zwj = '‍'; //     Joining_Type C
const String _zwnj = '‌'; //    Joining_Type U

/// U+FEFB, the isolated lam-alef ligature.
const int _lamAlefIsolated = 0xFEFB;

/// U+FEFC, the final lam-alef ligature.
const int _lamAlefFinal = 0xFEFC;

Uint8List _fontBytes(String name) => File('test/fonts/$name').readAsBytesSync();

void main() {
  late Typeface dejaVu;
  late ScaledTypeface font;

  setUp(() {
    dejaVu = Typeface.parse(_fontBytes('DejaVuSans.ttf'));
    // One em to a pixel, so every assertion below is in font units and needs
    // no tolerance for a scale factor.
    font = dejaVu.atSize(dejaVu.unitsPerEm.toDouble());
  });

  group('the fixture', () {
    test('DejaVu covers Arabic and Hebrew', () {
      // The premise every end-to-end assertion here rests on. If the fixture
      // is ever replaced, this fails first and says why.
      expect(dejaVu.covers('$_seen$_lam$_alef$_meem'), isTrue);
      expect(dejaVu.covers('אבג'), isTrue,
          reason: 'Hebrew, for the right-to-left run that needs no joining');
      expect(dejaVu.covers('कि'), isFalse,
          reason: 'no Devanagari, which is what makes the refusal test honest');
    });

    test('DejaVu has the lam-alef presentation forms in its cmap', () {
      expect(dejaVu.glyphForCodePoint(_lamAlefIsolated), isNot(0));
      expect(dejaVu.glyphForCodePoint(_lamAlefFinal), isNot(0));
    });
  });

  group('the joining machine', () {
    test('a lone letter is isolated', () {
      expect(arabicJoiningForms(_beh), <ArabicJoiningForm>[
        ArabicJoiningForm.isolated,
      ]);
    });

    test('alef joins only to what precedes it', () {
      // Joining_Type R. It takes a final form after a letter and it does not
      // let the next letter join backwards onto it, which is why an alef in
      // the middle of a word breaks the stroke after itself.
      expect(arabicJoiningForms(_beh + _alef + _beh), <ArabicJoiningForm>[
        ArabicJoiningForm.initial,
        ArabicJoiningForm.finalForm,
        ArabicJoiningForm.isolated,
      ]);
    });

    test('waw joins only to what precedes it, like alef', () {
      expect(arabicJoiningForms(_beh + _waw + _beh), <ArabicJoiningForm>[
        ArabicJoiningForm.initial,
        ArabicJoiningForm.finalForm,
        ArabicJoiningForm.isolated,
      ]);
    });

    test('beh joins on both sides', () {
      expect(arabicJoiningForms(_beh + _beh + _beh), <ArabicJoiningForm>[
        ArabicJoiningForm.initial,
        ArabicJoiningForm.medial,
        ArabicJoiningForm.finalForm,
      ]);
    });

    test('a mark between two letters does not break the join', () {
      // The test this file exists for. A fatha is Joining_Type Transparent:
      // the machine must look straight through it, leaving both the state and
      // the previous letter untouched. Get this wrong - let a mark advance the
      // state - and every vowelled Arabic word comes apart into isolated
      // letterforms at every vowel, which is the single most visible way a
      // shaper can be wrong about Arabic.
      expect(arabicJoiningForms(_beh + _fatha + _beh), <ArabicJoiningForm>[
        ArabicJoiningForm.initial,
        ArabicJoiningForm.none,
        ArabicJoiningForm.finalForm,
      ]);
    });

    test('a mark does not join to anything itself', () {
      expect(arabicJoiningForms(_fatha), <ArabicJoiningForm>[
        ArabicJoiningForm.none,
      ]);
    });

    test('two marks between two letters still do not break the join', () {
      expect(
        arabicJoiningForms(_beh + _fatha + _fatha + _beh),
        <ArabicJoiningForm>[
          ArabicJoiningForm.initial,
          ArabicJoiningForm.none,
          ArabicJoiningForm.none,
          ArabicJoiningForm.finalForm,
        ],
      );
    });

    test('ZWJ forces a joined form where there is nothing to join to', () {
      // Joining_Type C: it joins on both sides and has no shape of its own, so
      // it is what a user types to get an initial form in isolation - the way
      // a letter is quoted in a grammar book.
      expect(arabicJoiningForms(_beh + _zwj), <ArabicJoiningForm>[
        ArabicJoiningForm.initial,
        ArabicJoiningForm.finalForm,
      ]);
      // ZWJ itself takes a form, and that is not a wart: it behaves as a
      // dual-joining letter in the machine and merely has no outline to show
      // for it, which is exactly how it makes the letter beside it join.
      expect(arabicJoiningForms(_zwj + _beh), <ArabicJoiningForm>[
        ArabicJoiningForm.initial,
        ArabicJoiningForm.finalForm,
      ]);
    });

    test('ZWNJ breaks a join that would otherwise happen', () {
      // Joining_Type U, and the exact opposite request: two letters that would
      // connect, written disconnected.
      expect(arabicJoiningForms(_beh + _zwnj + _beh), <ArabicJoiningForm>[
        ArabicJoiningForm.isolated,
        ArabicJoiningForm.none,
        ArabicJoiningForm.isolated,
      ]);
    });

    test('a space breaks a word into two', () {
      expect(arabicJoiningForms('$_beh$_beh $_beh$_beh'), <ArabicJoiningForm>[
        ArabicJoiningForm.initial,
        ArabicJoiningForm.finalForm,
        ArabicJoiningForm.none,
        ArabicJoiningForm.initial,
        ArabicJoiningForm.finalForm,
      ]);
    });

    test('a real four-letter word takes all four forms', () {
      // مكتب, "office": meem, kaf, teh, beh, every one of them dual-joining.
      expect(
        arabicJoiningForms(_meem + _kaf + _teh + _beh),
        <ArabicJoiningForm>[
          ArabicJoiningForm.initial,
          ArabicJoiningForm.medial,
          ArabicJoiningForm.medial,
          ArabicJoiningForm.finalForm,
        ],
      );
    });

    test('a Latin word asks for no forms at all', () {
      expect(
        arabicJoiningForms('ab'),
        <ArabicJoiningForm>[ArabicJoiningForm.none, ArabicJoiningForm.none],
      );
    });
  });

  group('positional features are applied per glyph', () {
    test('four identical letters get four different forms', () {
      // The assertion that separates a real Arabic shaper from one that
      // enables the four positional features and runs them over the whole run.
      // DejaVu writes `fina`, `medi` and `init` as single substitutions
      // covering every Arabic letter, so a whole-run application lets the
      // lowest-indexed lookup win everywhere and turns this word into four
      // identical final forms - connected to nothing, and not a word.
      final GlyphRun run = OpenTypeShaper().shape(
        _beh * 4,
        font,
        script: Script.arab,
        direction: TextDirection.rightToLeft,
      );

      expect(run.length, 4);
      final List<int> visual = run.glyphIds.take(4).toList();
      // Visual order is right to left, so the run reads final, medial, medial,
      // initial.
      expect(visual[0], _formOf(dejaVu, _beh, 'fina'));
      expect(visual[1], _formOf(dejaVu, _beh, 'medi'));
      expect(visual[2], _formOf(dejaVu, _beh, 'medi'));
      expect(visual[3], _formOf(dejaVu, _beh, 'init'));
      expect(visual.toSet().length, 3,
          reason: 'three distinct shapes, not one repeated four times');
    });

    test('a word keeps its letters when it is joined', () {
      final GlyphRun run = OpenTypeShaper().shape(
        _meem + _kaf + _teh + _beh,
        font,
        script: Script.arab,
        direction: TextDirection.rightToLeft,
      );

      expect(run.length, 4);
      expect(run.glyphIds.take(4), <int>[
        _formOf(dejaVu, _beh, 'fina'),
        _formOf(dejaVu, _teh, 'medi'),
        _formOf(dejaVu, _kaf, 'medi'),
        _formOf(dejaVu, _meem, 'init'),
      ]);
    });

    test('a mark between two letters leaves both of them joined', () {
      // The joining machine's transparency rule, carried all the way through
      // to glyph ids: the two behs must still be an initial and a final.
      final GlyphRun run = OpenTypeShaper().shape(
        _beh + _fatha + _beh,
        font,
        script: Script.arab,
        direction: TextDirection.rightToLeft,
      );

      expect(run.length, 3);
      expect(run.glyphIds[0], _formOf(dejaVu, _beh, 'fina'));
      expect(run.glyphIds[2], _formOf(dejaVu, _beh, 'init'));
    });

    test('a letter after alef is isolated, not initial', () {
      final GlyphRun run = OpenTypeShaper().shape(
        _beh + _alef + _beh,
        font,
        script: Script.arab,
        direction: TextDirection.rightToLeft,
      );

      expect(run.glyphIds[0], dejaVu.glyphForCodePoint(_beh.codeUnitAt(0)),
          reason: 'the isolated form is the plain cmap glyph in DejaVu');
      expect(run.glyphIds[2], _formOf(dejaVu, _beh, 'init'));
    });
  });

  group('the mandatory lam-alef ligature', () {
    test('lam plus alef is one glyph, in its isolated form', () {
      final GlyphRun run = OpenTypeShaper().shape(
        _lam + _alef,
        font,
        script: Script.arab,
        direction: TextDirection.rightToLeft,
      );

      expect(run.length, 1, reason: 'two letters, one shape - always');
      expect(run.glyphIds[0], dejaVu.glyphForCodePoint(_lamAlefIsolated));
      expect(run.clusters[0], 0);
    });

    test('lam plus alef after a letter takes the final form', () {
      // بلا. The lam is joined on its right, so the ligature is the *final*
      // one; getting this from the joining machine rather than guessing is
      // what keeps the connecting stroke on the correct side.
      final GlyphRun run = OpenTypeShaper().shape(
        _beh + _lam + _alef,
        font,
        script: Script.arab,
        direction: TextDirection.rightToLeft,
      );

      expect(run.length, 2);
      expect(run.glyphIds[0], dejaVu.glyphForCodePoint(_lamAlefFinal));
      expect(run.glyphIds[1], _formOf(dejaVu, _beh, 'init'));
    });

    test('the ligature forms even when the font states no rule for it', () {
      // DejaVu with `GSUB` removed: no `rlig`, no positional features, nothing.
      // The pair is still not allowed to render as two letters, because in
      // Arabic orthography it is not two letters - so the shaper reaches for
      // the Unicode presentation form, which the font does have in its `cmap`.
      final Typeface stripped = Typeface.parse(_replaceTables(
          _fontBytes('DejaVuSans.ttf'),
          const <String, Uint8List?>{'GSUB': null}));
      final GlyphRun run = OpenTypeShaper().shape(
        _lam + _alef,
        stripped.atSize(stripped.unitsPerEm.toDouble()),
        script: Script.arab,
        direction: TextDirection.rightToLeft,
      );

      expect(run.length, 1);
      expect(run.glyphIds[0], stripped.glyphForCodePoint(_lamAlefIsolated));
    });

    test('lam followed by something that is not an alef is left alone', () {
      final GlyphRun run = OpenTypeShaper().shape(
        _lam + _beh,
        font,
        script: Script.arab,
        direction: TextDirection.rightToLeft,
      );

      expect(run.length, 2);
    });
  });

  group('cursive attachment follows the direction of the run', () {
    // A font authored for right-to-left cursive text puts the exit anchor at
    // the origin and the entry anchor at the far side of the glyph, because in
    // right-to-left text the stroke leaves at the left edge and arrives at the
    // right edge of the next letter. `_cursiveFont` grafts exactly that onto
    // DejaVu, over the plain beh glyph, and removes `GSUB` so no positional
    // substitution moves the glyph out from under the coverage table.
    const int entryX = 700;
    const int exitX = 0;

    late Typeface joined;
    late ScaledTypeface joinedFont;
    late double advance;

    setUp(() {
      joined = _cursiveFont(dejaVu, entryX: entryX, exitX: exitX);
      joinedFont = joined.atSize(joined.unitsPerEm.toDouble());
      advance = joined.advanceOf(joined.glyphForCodePoint(_beh.codeUnitAt(0)));
    });

    test('the fixture joins a pair of behs and nothing else', () {
      expect(advance, greaterThan(entryX),
          reason: 'the anchor has to be inside the glyph for "trimmed" to '
              'mean anything');
    });

    test('a right-to-left run trims the trailing glyph of the pair', () {
      // The proof that the run's direction now reaches GposTable.apply. In a
      // right-to-left run the *second* glyph of the pair is the one that
      // trails the pen, so it is the one that gives up the distance between
      // its origin and its entry anchor: its advance becomes 700 instead of
      // the beh's full 1928 units, and the first glyph is untouched.
      final GlyphRun run = OpenTypeShaper(applyKerning: false).shape(
        _beh + _beh,
        joinedFont,
        script: Script.arab,
        direction: TextDirection.rightToLeft,
      );

      expect(run.length, 2);
      // Visual order: the trailing glyph of the pair is drawn first.
      expect(run.xOf(0), 0);
      expect(run.xOf(1), closeTo(entryX.toDouble(), 1e-6),
          reason: 'the trailing glyph advanced by its entry anchor, not by '
              'its full width');
      expect(run.width - run.xOf(1), closeTo(advance, 1e-6),
          reason: 'the leading glyph kept every unit of its advance');
      expect(run.width, closeTo(advance + entryX, 1e-6));
    });

    test('a left-to-right run trims the leading glyph instead', () {
      // The mirror image, and the numbers the right-to-left run used to get
      // before the direction was threaded: the leading glyph's advance
      // collapses to its exit anchor - zero, here - and the pair comes out
      // 1400 units narrower than it should be.
      final GlyphRun run = OpenTypeShaper(applyKerning: false).shape(
        _beh + _beh,
        joinedFont,
        script: Script.arab,
        direction: TextDirection.leftToRight,
      );

      expect(run.width, closeTo(advance - entryX, 1e-6));
      expect(run.xOf(0), closeTo(exitX.toDouble(), 1e-6));
      expect(run.xOf(1), closeTo(-entryX.toDouble(), 1e-6),
          reason: 'the trailing glyph was pulled back onto the leading one');
    });

    test('the two directions differ by twice the anchor', () {
      final ScaledTypeface size = joinedFont;
      final GlyphRun rightToLeft = OpenTypeShaper(applyKerning: false).shape(
        _beh + _beh,
        size,
        script: Script.arab,
        direction: TextDirection.rightToLeft,
      );
      final double rightToLeftWidth = rightToLeft.width;
      final GlyphRun leftToRight = OpenTypeShaper(applyKerning: false).shape(
        _beh + _beh,
        size,
        script: Script.arab,
        direction: TextDirection.leftToRight,
      );

      expect(rightToLeftWidth - leftToRight.width, closeTo(2 * entryX, 1e-6));
    });
  });

  group('script arrives per call', () {
    test('one shaper shapes a Latin run and an Arabic run in sequence', () {
      // The point of the whole interface change. Building a shaper per run
      // would re-parse GSUB, GPOS, GDEF and kern for the face every time, and
      // a paragraph of mixed script is exactly where that would happen most.
      final OpenTypeShaper shaper = OpenTypeShaper();

      final GlyphRun latin = shaper.shape('AV', font, script: Script.latn);
      final List<int> latinGlyphs = latin.glyphIds.take(latin.length).toList();
      final double latinWidth = latin.width;

      final GlyphRun arabic = shaper.shape(
        _beh * 4,
        font,
        script: Script.arab,
        direction: TextDirection.rightToLeft,
      );

      expect(arabic.glyphIds[0], _formOf(dejaVu, _beh, 'fina'),
          reason: 'the Arabic run got the Arabic model');
      expect(identical(latin.glyphIds, arabic.glyphIds), isTrue,
          reason: 'one shaper, one set of scratch buffers');

      final GlyphRun again = shaper.shape('AV', font, script: Script.latn);
      expect(again.glyphIds.take(again.length), latinGlyphs);
      expect(again.width, closeTo(latinWidth, 1e-9),
          reason: 'the Arabic run in between changed nothing about Latin');
    });

    test('the same text shaped as Latin does not join', () {
      final OpenTypeShaper shaper = OpenTypeShaper();

      // Copied out, not held: a run borrows the shaper's scratch arrays, so
      // the second call overwrites what the first returned.
      final GlyphRun first = shaper.shape(_beh * 2, font,
          script: Script.latn, direction: TextDirection.rightToLeft);
      final List<int> asLatin = first.glyphIds.take(first.length).toList();
      final GlyphRun second = shaper.shape(_beh * 2, font,
          script: Script.arab, direction: TextDirection.rightToLeft);
      final List<int> asArabic = second.glyphIds.take(second.length).toList();

      expect(asLatin[0], asLatin[1],
          reason: 'the Latin model leaves both letters in their plain form');
      expect(asLatin[0], dejaVu.glyphForCodePoint(_beh.codeUnitAt(0)));
      expect(asArabic[0], isNot(asArabic[1]),
          reason: 'the Arabic model gave them a final and an initial form');
    });

    test('a Hebrew run needs no joining and still reverses', () {
      final OpenTypeShaper shaper = OpenTypeShaper();
      const String hebrew = 'אב';

      final GlyphRun run = shaper.shape(hebrew, font,
          script: Script.hebr, direction: TextDirection.rightToLeft);

      expect(run.length, 2);
      expect(run.glyphIds[0], dejaVu.glyphForCodePoint(0x05D1));
      expect(run.glyphIds[1], dejaVu.glyphForCodePoint(0x05D0));
      expect(run.clusters.take(2), <int>[1, 0]);
    });

    test('the constructor tag is only a default', () {
      // A shaper built for one script still shapes another correctly when the
      // call says so; that is what makes the constructor argument a default
      // rather than the ceiling it used to be.
      final OpenTypeShaper shaper = OpenTypeShaper(script: 'latn');

      final GlyphRun run = shaper.shape(_beh * 2, font,
          script: Script.arab, direction: TextDirection.rightToLeft);

      expect(run.glyphIds[0], _formOf(dejaVu, _beh, 'fina'));
    });

    test('a language tag reaches the tables per call', () {
      // DejaVu states URD, SND and KUR language systems under `arab`. None of
      // them changes what this word looks like, so the assertion is that the
      // argument is accepted and shaping still succeeds - the plumbing is what
      // is under test, and a wrong tag would fall back to the script default
      // rather than fail.
      final OpenTypeShaper shaper = OpenTypeShaper();

      final GlyphRun urdu = shaper.shape(_beh * 2, font,
          script: Script.arab,
          language: 'URD',
          direction: TextDirection.rightToLeft);

      expect(urdu.glyphIds[0], _formOf(dejaVu, _beh, 'fina'));
    });
  });

  group('scripts with no shaper are refused by name', () {
    test('a Devanagari run throws, naming the model', () {
      final OpenTypeShaper shaper = OpenTypeShaper();

      expect(
        () => shaper.shape('कि', font, script: Script.deva),
        throwsA(
          isA<UnsupportedScriptException>()
              .having((UnsupportedScriptException e) => e.model, 'model',
                  ShapingModel.indic)
              .having(
                  (UnsupportedScriptException e) => e.scriptTag, 'tag', 'dev2')
              .having((UnsupportedScriptException e) => e.message, 'message',
                  contains('Indic')),
        ),
      );
    });

    test('the message says why it refuses rather than approximates', () {
      const UnsupportedScriptException report =
          UnsupportedScriptException('dev2', ShapingModel.indic);

      expect(report.toString(), contains('dev2'));
      expect(report.toString(), contains('wrong order'));
    });

    test('every unimplemented model has its own scripts', () {
      expect(shapingModelForTag('dev2'), ShapingModel.indic);
      expect(shapingModelForTag('deva'), ShapingModel.indic,
          reason: 'the v1 tag is equally unshapeable');
      expect(shapingModelForTag('khmr'), ShapingModel.khmer);
      expect(shapingModelForTag('mym2'), ShapingModel.myanmar);
      expect(shapingModelForTag('java'), ShapingModel.universalShapingEngine);
      expect(shapingModelForTag('arab'), ShapingModel.arabic);
      expect(shapingModelForTag('syrc'), ShapingModel.arabic);
      expect(shapingModelForTag('latn'), ShapingModel.simple);
      expect(shapingModelForTag('hebr'), ShapingModel.simple);
      expect(ShapingModel.indic.isImplemented, isFalse);
      expect(ShapingModel.arabic.isImplemented, isTrue);
    });

    test('the opt-out still reports before it approximates', () {
      // Shaping it anyway is a choice a caller can make, and it is not a quiet
      // one: the same report is built and handed over, and only then does the
      // run go through the simple model.
      final List<UnsupportedScriptException> reports =
          <UnsupportedScriptException>[];
      final OpenTypeShaper shaper = OpenTypeShaper(
        unsupportedScript: UnsupportedScriptPolicy.shapeAsSimple,
        onUnsupportedScript: reports.add,
      );

      final GlyphRun run = shaper.shape('कि', font,
          script: Script.deva, direction: TextDirection.leftToRight);

      expect(reports, hasLength(1));
      expect(reports.single.model, ShapingModel.indic);
      expect(run.length, 2, reason: 'notdef boxes, but glyphs');
    });

    test('a Latin run reports nothing', () {
      final List<UnsupportedScriptException> reports =
          <UnsupportedScriptException>[];
      final OpenTypeShaper shaper = OpenTypeShaper(
        unsupportedScript: UnsupportedScriptPolicy.shapeAsSimple,
        onUnsupportedScript: reports.add,
      );

      shaper.shape('AV', font, script: Script.latn);

      expect(reports, isEmpty);
    });
  });

  group('LatinShaper keeps its signature', () {
    test('it accepts a script and ignores it', () {
      final GlyphRun run =
          LatinShaper().shape(_beh * 2, font, script: Script.arab);

      expect(run.length, 2);
      expect(run.glyphIds[0], run.glyphIds[1],
          reason: 'no joining: that is the documented limit of this shaper');
    });
  });
}

/// The glyph DejaVu substitutes for [letter] under one positional [feature].
///
/// Read out of the font rather than written down, so the expectations track the
/// fixture instead of a table of glyph ids that would rot the moment DejaVu is
/// updated. It goes through the shaper rather than through `GSUB` directly, on
/// a run of one letter, where the requested form is the only one the joining
/// machine can produce.
int _formOf(Typeface face, String letter, String feature) {
  final String text = switch (feature) {
    // A lone letter is isolated; a letter followed by ZWJ is initial; preceded
    // by ZWJ, final; between two, medial.
    'isol' => letter,
    'init' => letter + _zwj,
    'fina' => _zwj + letter,
    _ => _zwj + letter + _zwj,
  };
  final GlyphRun run = OpenTypeShaper().shape(
    text,
    face.atSize(face.unitsPerEm.toDouble()),
    script: Script.arab,
  );
  // Left to right, so the letter sits where it does in logical order: first
  // for `isol` and `init`, second otherwise.
  return run.glyphIds[feature == 'isol' || feature == 'init' ? 0 : 1];
}

/// DejaVu with a synthetic cursive `GPOS` and no `GSUB`.
///
/// The real font supplies the `cmap`, the advances, the outlines and `GDEF`;
/// only the layout tables are replaced. Removing `GSUB` is what keeps the
/// coverage table meaningful - with it in place the positional features would
/// substitute the beh for a form the synthetic coverage does not list, and the
/// cursive lookup would silently do nothing.
Typeface _cursiveFont(
  Typeface face, {
  required int entryX,
  required int exitX,
}) {
  final int beh = face.glyphForCodePoint(_beh.codeUnitAt(0));
  return Typeface.parse(
    _replaceTables(_fontBytes('DejaVuSans.ttf'), <String, Uint8List?>{
      'GSUB': null,
      'GPOS': _cursiveGpos(beh, entryX: entryX, exitX: exitX),
    }),
  );
}

/// A `GPOS` table whose `arab` script offers one `curs` feature.
///
/// One lookup, one type 3 subtable, one covered glyph with both an entry and an
/// exit anchor - the minimum that makes a glyph join to a copy of itself.
Uint8List _cursiveGpos(int glyph, {required int entryX, required int exitX}) {
  final _Bytes out = _Bytes();
  out.label('gpos');
  out.uint32(0x00010000);
  out.offset16('scripts', from: 'gpos');
  out.offset16('features', from: 'gpos');
  out.offset16('lookups', from: 'gpos');

  out.label('scripts');
  out.uint16(1);
  out.tag('arab');
  out.offset16('script', from: 'scripts');
  out.label('script');
  out.offset16('langsys', from: 'script');
  out.uint16(0); // no named language systems
  out.label('langsys');
  out.uint16(0); // lookupOrder, reserved
  out.uint16(0xFFFF); // no required feature
  out.uint16(1);
  out.uint16(0);

  out.label('features');
  out.uint16(1);
  out.tag('curs');
  out.offset16('feature', from: 'features');
  out.label('feature');
  out.uint16(0); // featureParams
  out.uint16(1);
  out.uint16(0);

  out.label('lookups');
  out.uint16(1);
  out.offset16('lookup', from: 'lookups');
  out.label('lookup');
  out.uint16(3); // cursive attachment
  out.uint16(0); // flags: not the lookup's own RIGHT_TO_LEFT
  out.uint16(1);
  out.offset16('cursive', from: 'lookup');

  out.label('cursive');
  out.uint16(1); // format
  out.offset16('coverage', from: 'cursive');
  out.uint16(1); // one EntryExitRecord
  out.offset16('entry', from: 'cursive');
  out.offset16('exit', from: 'cursive');

  out.label('coverage');
  out.uint16(1); // format 1, a glyph list
  out.uint16(1);
  out.uint16(glyph);

  out.label('entry');
  out.uint16(1); // anchor format 1
  out.uint16(entryX);
  out.uint16(0);

  out.label('exit');
  out.uint16(1);
  out.uint16(exitX);
  out.uint16(0);

  return out.build();
}

/// [font] with tables replaced, and the ones mapped to null removed.
///
/// The sfnt directory is rebuilt from scratch: tags ascending, table data
/// four-byte aligned, checksums written as zero. Nothing in this framework
/// verifies a table checksum - see `sfnt.dart`, which validates ranges and not
/// contents - so a zero is honest rather than a forgery, and the alternative
/// would be computing checksums no reader reads.
Uint8List _replaceTables(Uint8List font, Map<String, Uint8List?> replacements) {
  final ByteData source = ByteData.sublistView(font);
  final int version = source.getUint32(0);
  final int count = source.getUint16(4);

  final Map<String, Uint8List> tables = <String, Uint8List>{};
  for (int i = 0; i < count; i++) {
    final int record = 12 + i * 16;
    final String tag = String.fromCharCodes(font, record, record + 4);
    final int offset = source.getUint32(record + 8);
    final int length = source.getUint32(record + 12);
    tables[tag] = Uint8List.sublistView(font, offset, offset + length);
  }
  replacements.forEach((String tag, Uint8List? bytes) {
    if (bytes == null) {
      tables.remove(tag);
    } else {
      tables[tag] = bytes;
    }
  });

  final List<String> tags = tables.keys.toList()..sort();
  final int directory = 12 + tags.length * 16;
  int cursor = directory;
  final Map<String, int> offsets = <String, int>{};
  for (final String tag in tags) {
    offsets[tag] = cursor;
    cursor += (tables[tag]!.length + 3) & ~3;
  }

  final Uint8List out = Uint8List(cursor);
  final ByteData view = ByteData.sublistView(out);
  view.setUint32(0, version);
  view.setUint16(4, tags.length);
  // searchRange, entrySelector and rangeShift are derivable and skipped by
  // every reader here, including ours.
  for (int i = 0; i < tags.length; i++) {
    final String tag = tags[i];
    final int record = 12 + i * 16;
    out.setRange(record, record + 4, tag.codeUnits);
    view.setUint32(record + 4, 0); // checksum
    view.setUint32(record + 8, offsets[tag]!);
    view.setUint32(record + 12, tables[tag]!.length);
    out.setRange(
        offsets[tag]!, offsets[tag]! + tables[tag]!.length, tables[tag]!);
  }
  return out;
}

/// A big-endian byte builder with named, back-patched offsets.
///
/// A layout table is a graph of offsets, each relative to a different base, and
/// writing one forwards means knowing where things will be before they are
/// written. Naming the destinations and patching afterwards is the difference
/// between a fixture that is readable and one that is a column of magic
/// numbers.
final class _Bytes {
  final List<int> _out = <int>[];
  final Map<String, int> _labels = <String, int>{};
  final List<({int at, String label, String from})> _fixups =
      <({int at, String label, String from})>[];

  void label(String name) => _labels[name] = _out.length;

  void uint16(int value) {
    _out.add((value >> 8) & 0xFF);
    _out.add(value & 0xFF);
  }

  void uint32(int value) {
    uint16((value >> 16) & 0xFFFF);
    uint16(value & 0xFFFF);
  }

  void tag(String value) => _out.addAll(value.codeUnits);

  /// A placeholder for the distance from [from]'s label to [label]'s.
  void offset16(String label, {required String from}) {
    _fixups.add((at: _out.length, label: label, from: from));
    uint16(0);
  }

  Uint8List build() {
    final Uint8List bytes = Uint8List.fromList(_out);
    final ByteData view = ByteData.sublistView(bytes);
    for (final ({int at, String label, String from}) fixup in _fixups) {
      view.setUint16(fixup.at, _labels[fixup.label]! - _labels[fixup.from]!);
    }
    return bytes;
  }
}
