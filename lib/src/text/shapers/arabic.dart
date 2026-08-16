/// Arabic shaping: the cursive joining machine and the features it drives.
///
/// Arabic is not written as a row of letters. Every cursive letter has up to
/// four shapes - isolated, initial, medial, final - and which one is drawn
/// depends on whether the letters on either side of it join. A shaper that
/// skips this step does not fail: it draws every letter in its isolated form,
/// which reads roughly like ENGLISH SET ENTIRELY IN CAPITALS WITH A SPACE
/// BETWEEN EVERY LETTER. Legible to nobody, and the failure is invisible to a
/// test that only counts glyphs.
///
/// ## The two halves, and why they are separate
///
/// The **joining machine** ([ArabicShaper.planJoining]) is pure Unicode: it
/// reads `Joining_Type` from the UCD and decides, per character, which of the
/// four forms that character wants. It knows nothing about fonts, and it is
/// deliberately callable on its own - [arabicJoiningForms] exposes it - because
/// it is the part that has an objectively right answer and therefore the part
/// worth testing character by character.
///
/// The **feature application** ([ArabicShaper.substitute]) is where the font
/// gets a say. Each of `isol`, `fina`, `medi` and `init` is applied *to the
/// glyphs in that state and to no others*. This is the step naive
/// implementations get wrong: they enable all four features and run them over
/// the whole run at once, and because a font implements each of them as a
/// single substitution covering every Arabic letter, the first one to be
/// reached wins on every glyph. DejaVu shaped that way turns "بببب" into four
/// *final* forms, which is not "slightly off" - it is a word rendered as four
/// disconnected tails.
///
/// ## The rule that decides whether words connect
///
/// `Joining_Type=Transparent` - every nonspacing mark and most format
/// characters - is **invisible to the machine**. The state does not advance and
/// the "previous letter" does not change when one is seen. A vowel sign written
/// between two letters must not break the connection underneath it, and a
/// shaper that lets a mark reset the state disconnects a word at every vowel.
/// That is the single most consequential line in this file, and it is the one
/// [arabicJoiningForms] is tested on hardest.
///
/// ## What this file does not do, named rather than hidden
///
/// * **Syriac Alaph.** Syriac's Alaph takes three different final forms
///   selected by `fin2`, `fin3` and `med2`, chosen from the joining group of
///   what precedes it. The state machine here has the four columns that every
///   other cursive script needs and not the two extra Syriac ones, so Syriac
///   shapes with ordinary `fina` - correct for most letters, wrong for Alaph.
/// * **`stch`.** Syriac's stretching feature, which distributes extra width
///   across a kashida, is not applied.
/// * **`rclt`.** HarfBuzz enables required contextual alternates alongside
///   `calt`; the feature order this file implements is the one section 30
///   fixes, and adding a feature to it would change shaped output, so `rclt`
///   is left off deliberately rather than forgotten.
/// * **Mark reordering.** The Unicode "modifier combining marks" reordering
///   that moves shadda relative to a vowel sign is not implemented; marks keep
///   their logical order.
library;

import 'dart:typed_data';

import '../gsub.dart';
import '../layout_common.dart';
import '../tables/joining_table.dart';
import '../typeface.dart';

/// One of the four cursive shapes a letter can take, or none.
///
/// The names are the OpenType feature tags, because that is the only place the
/// distinction is cashed out: a form is a request to the font, and [feature] is
/// the tag that carries it. A character that is not a cursive letter - a space,
/// a digit, a combining mark - is [none] and no positional feature is applied
/// to its glyph.
enum ArabicJoiningForm {
  /// Not a cursive letter: nothing positional applies.
  none(null),

  /// Joined on neither side. The shape a letter has standing alone, and the
  /// shape the plain `cmap` glyph already is in every font - which is why a
  /// font may legitimately ship no `isol` feature at all.
  isolated('isol'),

  /// Joined only to what follows it.
  initial('init'),

  /// Joined on both sides.
  medial('medi'),

  /// Joined only to what precedes it.
  ///
  /// Named with a suffix because `final` is a Dart keyword; the OpenType tag
  /// it maps to is `fina`.
  finalForm('fina');

  const ArabicJoiningForm(this.feature);

  /// The OpenType feature tag that asks a font for this shape, null for
  /// [none].
  final String? feature;
}

/// Thrown when a font states a positional feature in a form that cannot be
/// applied to one glyph at a time.
///
/// `isol`, `fina`, `medi` and `init` are per-glyph requests, and this shaper
/// expresses "apply feature F to glyph i only" by running F over a copy of the
/// run and adopting the result at the positions that asked for it. That is
/// exact for the single substitutions every shipping Arabic font uses, and it
/// breaks down the moment a font implements a positional feature with a lookup
/// that changes the glyph count - a ligature or a decomposition - because there
/// is then no position-by-position correspondence to adopt.
///
/// It is thrown rather than swallowed. Adopting the whole result would apply
/// the feature to letters in the wrong joining state, which is precisely the
/// bug this file exists to prevent, and dropping the result silently would make
/// a font's ligatures vanish with no way to find out why.
final class ArabicMaskLimitException implements Exception {
  const ArabicMaskLimitException(this.feature, this.before, this.after);

  /// The positional feature tag that could not be masked.
  final String feature;

  /// How many glyphs the run held before the feature ran.
  final int before;

  /// How many it held after.
  final int after;

  String get message =>
      'the font implements the positional feature "$feature" with a lookup '
      'that changes the glyph count ($before -> $after); this shaper can only '
      'apply a positional feature per glyph when it substitutes one glyph for '
      'one glyph';

  @override
  String toString() => 'ArabicMaskLimitException: $message';
}

/// Every `GSUB` feature tag the Arabic model may ask a font for.
///
/// Published so that a caller can resolve, once per face, which of them the
/// font actually states - see [ArabicShaper.substitute]'s `offered`. The order
/// is the stage order, and it is normative; the list is not a set for that
/// reason.
const List<String> arabicGsubFeatures = <String>[
  'ccmp',
  'locl',
  'isol',
  'fina',
  'medi',
  'init',
  'rlig',
  'calt',
  'liga',
  'mset',
];

/// The `GPOS` feature tags an Arabic run needs on top of a Latin run's.
///
/// Only `curs` is added: cursive attachment is what keeps a joined word on one
/// continuous stroke, and no default feature list written for Latin has any
/// reason to contain it. `kern`, `mark` and `mkmk` are already there.
///
/// Unlike `GSUB`, these are applied in **one** call rather than one per tag.
/// Within a table the spec fixes the order as ascending lookup index, and
/// splitting them into stages would impose a different order on the font than
/// the one it was compiled against.
const List<String> arabicGposFeatures = <String>['curs'];

/// The joining form of every code point of [text], in logical order.
///
/// One entry per **code point**, not per UTF-16 unit and not per glyph: this is
/// the Unicode half of shaping, and it has an answer before any font is chosen.
/// Allocates, and is meant for tests, diagnostics and callers that want the
/// analysis without the shaping; [ArabicShaper] computes the same thing into a
/// reused buffer.
List<ArabicJoiningForm> arabicJoiningForms(String text) {
  final ArabicShaper shaper = ArabicShaper();
  shaper.planJoining(text);
  final List<ArabicJoiningForm> forms = <ArabicJoiningForm>[];
  for (int i = 0; i < text.length;) {
    final int cp = _codePointAt(text, i);
    forms.add(shaper.formAt(i));
    i += cp > 0xFFFF ? 2 : 1;
  }
  return forms;
}

/// The cursive joining pass and the GSUB stages that depend on it.
///
/// Stateful and reused: one instance per shaper, not one per run. Everything it
/// needs per run - the form of each character, the mandatory ligatures it
/// found, the scratch buffer the masking uses - lives in arrays that are grown
/// and refilled rather than reallocated.
final class ArabicShaper {
  ArabicShaper();

  /// The joining form of the character starting at each UTF-16 offset.
  ///
  /// Indexed by offset rather than by code point index so that a glyph can be
  /// asked about directly: `GlyphBuffer.clusters` holds UTF-16 offsets, so
  /// `_forms[buffer.clusters[i]]` is the form the glyph at `i` asked for, with
  /// no search and no second index to keep aligned. Offsets that are not the
  /// start of a character - the low half of a surrogate pair - are never read.
  Uint8List _forms = Uint8List(64);

  /// How much of [_forms] the current run filled.
  int _formsLength = 0;

  /// Mandatory ligature candidates, as flat triples.
  ///
  /// `(offset of the lam, offset of the alef, code point of the alef)`. Flat
  /// because a run holds at most a handful and a list of records would allocate
  /// one object per pair per run.
  Int32List _ligatures = Int32List(12);
  int _ligatureCount = 0;

  /// Where a positional feature is applied before being adopted per glyph.
  final GlyphBuffer _scratch = GlyphBuffer();

  /// Computes the joining form of every character of [text].
  ///
  /// Runs the Unicode cursive joining state machine over the run's code points
  /// and records, for each one, which of the four shapes it wants. Also records
  /// the lam-alef pairs [substitute] may have to ligate by hand.
  ///
  /// The machine has three states - "the previous letter will not join
  /// forwards", "it will, and currently reads as isolated", "it will, and
  /// currently reads as final" - and each transition may rewrite the *previous*
  /// letter's form as well as setting this one's. That backward edit is what
  /// turns an isolated letter into an initial one when a second letter arrives,
  /// and it is why the forms cannot be decided in a single forward pass over
  /// independent characters.
  void planJoining(String text) {
    final int units = text.length;
    _ensureForms(units);
    _formsLength = units;
    for (int i = 0; i < units; i++) {
      _forms[i] = ArabicJoiningForm.none.index;
    }
    _ligatureCount = 0;

    int state = _stateNotJoining;
    int previous = -1;
    bool previousIsLam = false;

    for (int i = 0; i < units;) {
      final int cp = _codePointAt(text, i);
      final int width = cp > 0xFFFF ? 2 : 1;
      final JoiningType type = joiningTypeOf(cp);

      // The line the whole script turns on. A transparent character - every
      // nonspacing mark, and the format characters that are not join controls -
      // leaves the state and the previous letter exactly as they were, so the
      // letters on either side of it still see each other.
      if (type == JoiningType.transparent) {
        i += width;
        continue;
      }

      final int entry = state * _columns + _columnOf(type);
      final int previousAction = _previousAction[entry];
      if (previousAction != ArabicJoiningForm.none.index && previous >= 0) {
        _forms[previous] = previousAction;
      }
      _forms[i] = _currentAction[entry];

      // Joining_Group, not the letter: beh, teh and theh share a skeleton and
      // a group, and the mandatory ligature rules are written about groups.
      // The exact presentation form still needs the code point - there are four
      // alefs and four ligatures - so the code point is carried along.
      if (previousIsLam &&
          previous >= 0 &&
          joiningGroupOf(cp) == JoiningGroup.alef) {
        _recordLigature(previous, i, cp);
      }

      state = _nextState[entry];
      previous = i;
      previousIsLam = joiningGroupOf(cp) == JoiningGroup.lam;
      i += width;
    }
  }

  /// The form planned for the character at UTF-16 [offset].
  ///
  /// [ArabicJoiningForm.none] for an offset the last [planJoining] did not
  /// cover, which is what a glyph inserted by `ccmp` with a cluster outside the
  /// run would report - it asks for no positional feature, which is the safe
  /// answer.
  ArabicJoiningForm formAt(int offset) {
    if (offset < 0 || offset >= _formsLength) return ArabicJoiningForm.none;
    return ArabicJoiningForm.values[_forms[offset]];
  }

  /// How many mandatory-ligature candidates the last [planJoining] found.
  int get mandatoryLigatureCount => _ligatureCount;

  /// The UTF-16 offset of the lam of mandatory-ligature candidate [index].
  int mandatoryLigatureLam(int index) => _ligatures[index * 3];

  /// The UTF-16 offset of the alef of mandatory-ligature candidate [index].
  int mandatoryLigatureAlef(int index) => _ligatures[index * 3 + 1];

  /// Runs the `GSUB` half of Arabic shaping over [buffer].
  ///
  /// [planJoining] must have run on the same text first; the two are separate
  /// so that the joining analysis can be inspected without a font.
  ///
  /// ## The order is normative
  ///
  /// `ccmp`, `locl`, then `isol` / `fina` / `medi` / `init` **per glyph**, then
  /// `rlig`, `calt`, `liga`, `mset`. It is not a preference. Composition has to
  /// precede the positional features or a decomposed letter-plus-mark is not
  /// yet the letter whose shape is being chosen; the positional features have
  /// to precede `rlig` because the lam-alef ligature in every real font is
  /// written over the *initial* lam and the *final* alef, not over the base
  /// forms - substitute in the other order and the ligature simply never fires.
  ///
  /// Each stage is a separate call into `GSUB`, because a call applies its
  /// lookups in lookup-index order and that is the wrong order across stages.
  /// Within one stage lookup order is the spec's rule and is kept.
  ///
  /// [enabled] is the caller's feature set and governs `ccmp`, `locl`, `calt`
  /// and `liga`. The positional four, `rlig` and `mset` are **not** governed by
  /// it: they are what makes Arabic Arabic, and a caller that omitted them from
  /// a default feature list written for Latin did not mean to ask for
  /// disconnected letterforms.
  ///
  /// [offered] is which of those tags the font actually states for this script,
  /// resolved once per face by the caller. Asking `GSUB` per stage per run
  /// would rebuild a feature-index list eight times a run, which is exactly the
  /// per-run allocation the buffers above exist to avoid.
  void substitute(
    GlyphBuffer buffer, {
    required Typeface face,
    required GsubTable? gsub,
    required GdefTable? gdef,
    required String script,
    required String? language,
    required Set<String> enabled,
    required Set<String> offered,
  }) {
    if (gsub != null) {
      _stage(gsub, buffer, 'ccmp', gdef, script, language, enabled, offered);
      _stage(gsub, buffer, 'locl', gdef, script, language, enabled, offered);
      for (final ArabicJoiningForm form in _positionalOrder) {
        _masked(gsub, buffer, form, gdef, script, language, offered);
      }
      _stage(gsub, buffer, 'rlig', gdef, script, language, null, offered);
    }
    // After `rlig`, because a font that states the ligature is the authority on
    // what it looks like; this only covers fonts that do not.
    _formMandatoryLigatures(buffer, face);
    if (gsub != null) {
      _stage(gsub, buffer, 'calt', gdef, script, language, enabled, offered);
      _stage(gsub, buffer, 'liga', gdef, script, language, enabled, offered);
      _stage(gsub, buffer, 'mset', gdef, script, language, null, offered);
    }
  }

  /// Applies one whole-run feature, when the font offers it and, for the
  /// caller-governed features, when [enabled] lists it.
  ///
  /// A null [enabled] means the feature is mandatory for the script.
  void _stage(
    GsubTable gsub,
    GlyphBuffer buffer,
    String feature,
    GdefTable? gdef,
    String script,
    String? language,
    Set<String>? enabled,
    Set<String> offered,
  ) {
    if (enabled != null && !enabled.contains(feature)) return;
    if (!offered.contains(feature)) return;
    final Set<String>? only = _singletons[feature];
    if (only == null) return;
    gsub.apply(buffer,
        features: only, script: script, language: language, gdef: gdef);
  }

  /// Applies one positional feature to the glyphs in that joining state only.
  ///
  /// There is no per-glyph mask in [GsubTable.apply] to ask for this directly,
  /// so it is expressed the only way the public surface allows: the feature is
  /// run over a copy of the run, and its result is adopted at the positions
  /// whose character asked for this form. The copy is a field, not an
  /// allocation, and the whole stage is skipped when no glyph wants the form or
  /// the font does not offer the feature - which is the common case for `isol`,
  /// since the plain `cmap` glyph usually is the isolated form.
  ///
  /// Two consequences, stated rather than discovered:
  ///
  /// * A positional feature written as a *contextual* lookup that substitutes
  ///   at a position other than the one it matched at will have that
  ///   substitution dropped. Shipping Arabic fonts write the four positional
  ///   features as plain single substitutions; DejaVu does.
  /// * A positional feature that changes the glyph count throws
  ///   [ArabicMaskLimitException] rather than being applied to letters in the
  ///   wrong state.
  void _masked(
    GsubTable gsub,
    GlyphBuffer buffer,
    ArabicJoiningForm form,
    GdefTable? gdef,
    String script,
    String? language,
    Set<String> offered,
  ) {
    final String feature = form.feature!;
    if (!offered.contains(feature)) return;
    final Set<String>? only = _singletons[feature];
    if (only == null) return;

    bool wanted = false;
    for (int i = 0; i < buffer.length; i++) {
      if (formAt(buffer.clusters[i]) == form) {
        wanted = true;
        break;
      }
    }
    if (!wanted) return;

    _scratch.clear();
    for (int i = 0; i < buffer.length; i++) {
      _scratch.add(buffer.glyphs[i], buffer.clusters[i]);
    }
    gsub.apply(_scratch,
        features: only, script: script, language: language, gdef: gdef);
    if (_scratch.length != buffer.length) {
      throw ArabicMaskLimitException(feature, buffer.length, _scratch.length);
    }
    for (int i = 0; i < buffer.length; i++) {
      if (formAt(buffer.clusters[i]) != form) continue;
      final int substituted = _scratch.glyphs[i];
      if (substituted != buffer.glyphs[i]) buffer.substitute(i, substituted);
    }
  }

  /// Forms any lam-alef pair the font's `rlig` left unjoined.
  ///
  /// The lam-alef ligature is not a typographic nicety a font may decline: in
  /// Arabic orthography the sequence is *always* written as the one joined
  /// shape, and two separate letters is a spelling error rather than a plain
  /// style. A font that covers the letters but states no rule for the pair - a
  /// text face with a partial Arabic set, which is common - still usually has
  /// the four Unicode presentation forms in its `cmap`, and this reaches for
  /// them.
  ///
  /// Which of the four is decided by the alef (there are four: plain, madda,
  /// hamza above, hamza below) and by whether the lam is joined on its right,
  /// which is exactly the isolated/final distinction the joining machine has
  /// already made.
  ///
  /// Skipped entirely when the font's own `rlig` already merged the pair - the
  /// two glyphs are then one, and the search for the second cluster fails.
  void _formMandatoryLigatures(GlyphBuffer buffer, Typeface face) {
    for (int pair = 0; pair < _ligatureCount; pair++) {
      final int lamOffset = _ligatures[pair * 3];
      final int alefOffset = _ligatures[pair * 3 + 1];
      final int alef = _ligatures[pair * 3 + 2];

      final int lamIndex = _indexOfCluster(buffer, lamOffset);
      final int alefIndex = _indexOfCluster(buffer, alefOffset);
      if (lamIndex < 0 || alefIndex < 0 || lamIndex >= alefIndex) continue;

      final bool joinedBefore = formAt(lamOffset) == ArabicJoiningForm.medial ||
          formAt(lamOffset) == ArabicJoiningForm.finalForm;
      final int presentation = _lamAlefPresentation(alef, joinedBefore);
      if (presentation == 0) continue;
      final int glyph = face.glyphForCodePoint(presentation);
      // Zero is `.notdef`: the font does not have the presentation form
      // either, and two disconnected letters is better than a box.
      if (glyph == 0) continue;
      buffer.ligate(<int>[lamIndex, alefIndex], glyph);
    }
  }

  /// The buffer position whose cluster is exactly [cluster], or -1.
  ///
  /// Exact equality, not the "greatest cluster not past it" rule a caret uses:
  /// a cluster that has been absorbed into a ligature no longer starts a glyph,
  /// and the right answer here is "not found" rather than the glyph that
  /// swallowed it.
  static int _indexOfCluster(GlyphBuffer buffer, int cluster) {
    for (int i = 0; i < buffer.length; i++) {
      if (buffer.clusters[i] == cluster) return i;
    }
    return -1;
  }

  void _recordLigature(int lamOffset, int alefOffset, int alef) {
    if (_ligatureCount * 3 + 3 > _ligatures.length) {
      final Int32List grown = Int32List(_ligatures.length * 2);
      grown.setRange(0, _ligatures.length, _ligatures);
      _ligatures = grown;
    }
    _ligatures[_ligatureCount * 3] = lamOffset;
    _ligatures[_ligatureCount * 3 + 1] = alefOffset;
    _ligatures[_ligatureCount * 3 + 2] = alef;
    _ligatureCount++;
  }

  void _ensureForms(int units) {
    if (_forms.length >= units) return;
    int capacity = _forms.length;
    while (capacity < units) {
      capacity *= 2;
    }
    _forms = Uint8List(capacity);
  }
}

// ---------------------------------------------------------------------------
// The state machine
// ---------------------------------------------------------------------------

/// The previous letter will not join forwards.
const int _stateNotJoining = 0;

/// The previous letter will join forwards and currently reads as isolated.
const int _stateIsolatedPending = 1;

/// The previous letter will join forwards and currently reads as final.
const int _stateFinalPending = 2;

/// How many Joining_Type columns the table has: U, L, R, D.
const int _columns = 4;

const int _columnNonJoining = 0;
const int _columnLeft = 1;
const int _columnRight = 2;
const int _columnDual = 3;

/// The column a Joining_Type selects.
///
/// `Join_Causing` - ZWJ and tatweel - is folded into the dual-joining column
/// rather than given one of its own. That is the whole of its definition: it
/// joins on both sides and takes no shape itself, and since it has no shape to
/// take, asking the font for one is harmless. Folding it here is what makes
/// `ب` + ZWJ come out as an initial beh, which is exactly what a user typing
/// ZWJ asked for.
///
/// `Transparent` never reaches this function - it is filtered out before the
/// machine steps - and there is no column for it.
int _columnOf(JoiningType type) => switch (type) {
      JoiningType.nonJoining => _columnNonJoining,
      JoiningType.leftJoining => _columnLeft,
      JoiningType.rightJoining => _columnRight,
      JoiningType.dualJoining => _columnDual,
      JoiningType.joinCausing => _columnDual,
      JoiningType.transparent => _columnNonJoining,
    };

/// What each transition does to the *previous* letter's form.
///
/// The backward edit, and the reason a forward-only pass cannot produce these
/// forms: a letter is isolated until a second letter arrives, at which point it
/// retroactively becomes initial, and final until a third arrives, at which
/// point it becomes medial.
///
/// Indexed `state * _columns + column`, values are [ArabicJoiningForm] indices.
/// [ArabicJoiningForm.none] means "leave the previous letter alone".
const List<int> _previousAction = <int>[
  // _stateNotJoining: nothing before is willing to join, so nothing changes.
  0, 0, 0, 0,
  // _stateIsolatedPending: the previous letter is isolated and a joining
  // letter has arrived, so it becomes initial.
  0, 0, 2, 2,
  // _stateFinalPending: the previous letter is final and a joining letter has
  // arrived, so it becomes medial.
  0, 0, 3, 3,
];

/// What each transition sets the *current* letter's form to.
const List<int> _currentAction = <int>[
  // _stateNotJoining
  0, 1, 1, 1,
  // _stateIsolatedPending: R and D join backwards onto the previous letter.
  0, 1, 4, 4,
  // _stateFinalPending: the same.
  0, 1, 4, 4,
];

/// The state each transition moves to.
const List<int> _nextState = <int>[
  // _stateNotJoining
  _stateNotJoining,
  _stateIsolatedPending,
  _stateNotJoining,
  _stateIsolatedPending,
  // _stateIsolatedPending
  _stateNotJoining,
  _stateIsolatedPending,
  _stateNotJoining,
  _stateFinalPending,
  // _stateFinalPending
  _stateNotJoining,
  _stateIsolatedPending,
  _stateNotJoining,
  _stateFinalPending,
];

/// The order the positional features are applied in.
///
/// Isolated first and initial last, which is HarfBuzz's order and the one the
/// OpenType Arabic shaping model specifies. It matters only for a font whose
/// four features overlap on a glyph, which a correct font's do not - but a
/// masked stage makes overlap harmless anyway, since each stage only adopts
/// glyphs in its own state.
const List<ArabicJoiningForm> _positionalOrder = <ArabicJoiningForm>[
  ArabicJoiningForm.isolated,
  ArabicJoiningForm.finalForm,
  ArabicJoiningForm.medial,
  ArabicJoiningForm.initial,
];

/// One immutable single-tag feature set per stage.
///
/// A stage asks `GSUB` for exactly one feature, and building `<String>{tag}` at
/// each stage of each run would allocate eight sets per run in the hot path.
const Map<String, Set<String>> _singletons = <String, Set<String>>{
  'ccmp': <String>{'ccmp'},
  'locl': <String>{'locl'},
  'isol': <String>{'isol'},
  'fina': <String>{'fina'},
  'medi': <String>{'medi'},
  'init': <String>{'init'},
  'rlig': <String>{'rlig'},
  'calt': <String>{'calt'},
  'liga': <String>{'liga'},
  'mset': <String>{'mset'},
};

/// The Arabic Presentation Forms-B code point for a lam joined to [alef].
///
/// Zero when [alef] is not one of the four alefs that have a ligature. The two
/// forms of each are the isolated one and the final one, and [joinedBefore] -
/// whether the lam itself is joined on its right - is what chooses between
/// them: a lam-alef at the start of a word is the isolated ligature, one after
/// a joining letter is the final ligature.
int _lamAlefPresentation(int alef, bool joinedBefore) => switch (alef) {
      0x0622 => joinedBefore ? 0xFEF6 : 0xFEF5, // alef with madda above
      0x0623 => joinedBefore ? 0xFEF8 : 0xFEF7, // alef with hamza above
      0x0625 => joinedBefore ? 0xFEFA : 0xFEF9, // alef with hamza below
      0x0627 => joinedBefore ? 0xFEFC : 0xFEFB, // plain alef
      _ => 0,
    };

/// The code point starting at UTF-16 [index] of [text].
///
/// Surrogate pairs are decoded because the cursive scripts are not all in the
/// BMP: Adlam, Hanifi Rohingya, Sogdian and the Manichaean scripts all join,
/// and all live above U+FFFF. Reading their halves separately would give each
/// one Joining_Type Non_Joining and disconnect every word.
int _codePointAt(String text, int index) {
  final int unit = text.codeUnitAt(index);
  if (unit >= 0xD800 && unit < 0xDC00 && index + 1 < text.length) {
    final int low = text.codeUnitAt(index + 1);
    if (low >= 0xDC00 && low < 0xE000) {
      return 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
    }
  }
  return unit;
}
