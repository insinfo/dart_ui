/// Which shaping model a script needs, and what happens when it is missing.
///
/// A shaper is not one algorithm. `cmap` then `GSUB` then `GPOS` is the whole
/// story for Latin, Greek, Cyrillic, Hebrew and Han, and it is *not* the story
/// for Arabic, for the Indic scripts, or for the several dozen scripts the
/// Universal Shaping Engine covers. Those need work done to the character
/// sequence before the font's rules are consulted at all: Arabic needs the
/// joining state of every letter, Devanagari needs its syllables identified and
/// its matras and reph moved, and no amount of correctly implemented `GSUB`
/// supplies either.
///
/// ## Why this file refuses rather than approximates
///
/// A Devanagari run pushed through the default path does not fail. It produces
/// glyphs, at plausible positions, with a plausible total width - and with the
/// vowel signs on the wrong side of their consonants and the reph at the wrong
/// end of the syllable. To a caller it looks exactly like success, and to a
/// reader of Hindi it is gibberish. There is no assertion a caller could write
/// to detect it and no exception to catch, which is the definition of the
/// failure mode section 6.6 forbids.
///
/// So an unimplemented model is *named*: [ShapingModel] has a member for each
/// one, [UnsupportedScriptException] says which script wanted which model, and
/// the default [UnsupportedScriptPolicy] is to throw. A caller who would rather
/// have approximate text than an exception can ask for it explicitly, and gets
/// the same named report through a callback instead.
///
/// ## Dispatch is on the script's own tag, not the font's
///
/// The tag used here is the script's canonical OpenType tag, from
/// `openTypeTagOf`, and not the tag that survived being looked for in the
/// font's script list. A font with no `arab` script table still needs the
/// joining machine: the machine is what decides that a lam and an alef must be
/// drawn as one shape, and that stays true when the font states no rules and
/// the shaper has to reach for the Unicode presentation form instead. Choosing
/// the model from what the font happened to contain would turn "this font has
/// no Arabic features" into "this text is not Arabic".
library;

/// The shaping model a script's text has to go through.
enum ShapingModel {
  /// `cmap`, then the font's features in lookup order, then done.
  ///
  /// Correct - not merely adequate - for every script whose rules the font can
  /// state entirely in `GSUB` and `GPOS`: the European alphabets, Hebrew,
  /// Ethiopic, Han, Kana, Hangul in its precomposed form, Thai and Lao.
  simple,

  /// The cursive joining model: a joining state per letter, then the
  /// positional features applied one glyph at a time.
  ///
  /// Implemented, in `arabic.dart`. Shared by every script that joins, not
  /// only Arabic - see [_models].
  arabic,

  /// The Indic model: syllable identification, then reordering of the reph,
  /// the matras and the halant, then the font's features in a fixed order.
  ///
  /// **Not implemented.** Naming it is the point of this member.
  indic,

  /// The Khmer model - Indic-like syllables with its own coeng and register
  /// shifter rules.
  ///
  /// **Not implemented.**
  khmer,

  /// The Myanmar model, which reorders differently from Indic and has its own
  /// kinzi and medial consonant handling.
  ///
  /// **Not implemented.**
  myanmar,

  /// The Universal Shaping Engine: one cluster model covering the several
  /// dozen Brahmic and Brahmic-derived scripts that are not Indic, Khmer or
  /// Myanmar.
  ///
  /// **Not implemented.**
  universalShapingEngine;

  /// Whether this framework has the model.
  bool get isImplemented => this == simple || this == arabic;

  /// A human-readable name, for the message of [UnsupportedScriptException].
  String get label => switch (this) {
        ShapingModel.simple => 'the default model',
        ShapingModel.arabic => 'the cursive joining model',
        ShapingModel.indic => 'the Indic syllable model',
        ShapingModel.khmer => 'the Khmer syllable model',
        ShapingModel.myanmar => 'the Myanmar syllable model',
        ShapingModel.universalShapingEngine => 'the Universal Shaping Engine',
      };
}

/// What a shaper does with a run whose model is not implemented.
enum UnsupportedScriptPolicy {
  /// Throw [UnsupportedScriptException]. The default.
  ///
  /// Loud, and deliberately so: text that renders and is wrong is the outcome
  /// this exists to prevent, and a caller who has not thought about Devanagari
  /// is better served by a stack trace naming the missing model than by a
  /// paragraph of misplaced matras.
  fail,

  /// Shape it through [ShapingModel.simple] anyway, after reporting.
  ///
  /// The choice a caller makes when partial text beats no text - a diagnostics
  /// overlay, a font inspector, a document viewer that would rather show
  /// something. It is not a silent fallback: the shaper still builds the same
  /// [UnsupportedScriptException] and hands it to the callback it was given, so
  /// the condition is on the record either way.
  shapeAsSimple,
}

/// Reported when a run needs a shaping model this framework does not have.
///
/// Carries the script tag *and* the model rather than only the tag, because
/// "Devanagari is unsupported" and "the Indic model is unsupported" are
/// different facts and only the second one tells a reader that Bengali, Tamil
/// and eight others are in the same position.
final class UnsupportedScriptException implements Exception {
  const UnsupportedScriptException(this.scriptTag, this.model);

  /// The OpenType script tag of the run, such as `dev2`.
  final String scriptTag;

  /// The model that tag needs, and which is not implemented.
  final ShapingModel model;

  String get message =>
      'script "$scriptTag" needs ${model.label}, which is not implemented; '
      'shaping it with the default model produces glyphs in the wrong order '
      'rather than an error, so it is refused instead';

  @override
  String toString() => 'UnsupportedScriptException: $message';
}

/// Called with the report when an unsupported run is shaped anyway.
typedef UnsupportedScriptReporter = void Function(
    UnsupportedScriptException report);

/// The model [tag] needs.
///
/// [tag] is an OpenType script tag - four characters, space-padded, as
/// `openTypeTagOf` returns. Anything not listed is [ShapingModel.simple], which
/// is the right default for the large majority of scripts and is why the
/// exceptions are enumerated rather than the rule.
ShapingModel shapingModelForTag(String tag) =>
    _models[tag] ?? ShapingModel.simple;

/// Every script tag whose model is not [ShapingModel.simple].
///
/// ## The cursive group
///
/// Arabic's joining machinery is not Arabic-specific. Every script in the
/// cursive group here is written with the same four positional features driven
/// by the same `Joining_Type` property, which is why they share one entry point
/// rather than getting a shaper each. Syriac is included with a named
/// reservation: its Alaph takes three distinct final forms that need two extra
/// columns in the state machine, and `arabic.dart` says so.
///
/// Mongolian is included on the same terms. It joins, and the joining machine
/// is right for it, but Mongolian additionally needs variation-selector
/// handling and vertical layout that are not here - so its letters connect and
/// its free variation selectors do nothing.
///
/// ## The unimplemented groups
///
/// The Indic, Khmer and Myanmar lists are complete: those are exactly the
/// scripts those three models cover, in both their v1 and v2 tags.
///
/// The Universal Shaping Engine list is **deliberately partial**. USE covers
/// upwards of sixty scripts and grows with each Unicode release; the ones
/// listed are those with meaningful font coverage today. A USE script that is
/// not listed falls through to [ShapingModel.simple] and is shaped
/// approximately without a report - the one silent gap left, recorded here
/// rather than discovered.
const Map<String, ShapingModel> _models = <String, ShapingModel>{
  // Cursive joining - implemented.
  'arab': ShapingModel.arabic,
  'syrc': ShapingModel.arabic,
  'mand': ShapingModel.arabic,
  'mani': ShapingModel.arabic,
  'mong': ShapingModel.arabic,
  'nko ': ShapingModel.arabic,
  'phag': ShapingModel.arabic,
  'phlp': ShapingModel.arabic,
  'adlm': ShapingModel.arabic,
  'chrs': ShapingModel.arabic,
  'sogd': ShapingModel.arabic,
  'sogo': ShapingModel.arabic,
  'ougr': ShapingModel.arabic,
  'rohg': ShapingModel.arabic,

  // Indic - not implemented. Both tag generations, because a font may only
  // carry the old one and the run is equally unshapeable either way.
  'beng': ShapingModel.indic,
  'bng2': ShapingModel.indic,
  'deva': ShapingModel.indic,
  'dev2': ShapingModel.indic,
  'gujr': ShapingModel.indic,
  'gjr2': ShapingModel.indic,
  'guru': ShapingModel.indic,
  'gur2': ShapingModel.indic,
  'knda': ShapingModel.indic,
  'knd2': ShapingModel.indic,
  'mlym': ShapingModel.indic,
  'mlm2': ShapingModel.indic,
  'orya': ShapingModel.indic,
  'ory2': ShapingModel.indic,
  'taml': ShapingModel.indic,
  'tml2': ShapingModel.indic,
  'telu': ShapingModel.indic,
  'tel2': ShapingModel.indic,
  'sinh': ShapingModel.indic,

  // Khmer and Myanmar - not implemented.
  'khmr': ShapingModel.khmer,
  'mymr': ShapingModel.myanmar,
  'mym2': ShapingModel.myanmar,

  // Universal Shaping Engine - not implemented, list partial by design.
  'bali': ShapingModel.universalShapingEngine,
  'batk': ShapingModel.universalShapingEngine,
  'brah': ShapingModel.universalShapingEngine,
  'bugi': ShapingModel.universalShapingEngine,
  'buhd': ShapingModel.universalShapingEngine,
  'cakm': ShapingModel.universalShapingEngine,
  'cham': ShapingModel.universalShapingEngine,
  'gran': ShapingModel.universalShapingEngine,
  'hano': ShapingModel.universalShapingEngine,
  'java': ShapingModel.universalShapingEngine,
  'kali': ShapingModel.universalShapingEngine,
  'khar': ShapingModel.universalShapingEngine,
  'khoj': ShapingModel.universalShapingEngine,
  'kthi': ShapingModel.universalShapingEngine,
  'lana': ShapingModel.universalShapingEngine,
  'lepc': ShapingModel.universalShapingEngine,
  'limb': ShapingModel.universalShapingEngine,
  'mahj': ShapingModel.universalShapingEngine,
  'modi': ShapingModel.universalShapingEngine,
  'mtei': ShapingModel.universalShapingEngine,
  'mult': ShapingModel.universalShapingEngine,
  'newa': ShapingModel.universalShapingEngine,
  'rjng': ShapingModel.universalShapingEngine,
  'saur': ShapingModel.universalShapingEngine,
  'shrd': ShapingModel.universalShapingEngine,
  'sidd': ShapingModel.universalShapingEngine,
  'sind': ShapingModel.universalShapingEngine,
  'sund': ShapingModel.universalShapingEngine,
  'sylo': ShapingModel.universalShapingEngine,
  'tagb': ShapingModel.universalShapingEngine,
  'takr': ShapingModel.universalShapingEngine,
  'tale': ShapingModel.universalShapingEngine,
  'talu': ShapingModel.universalShapingEngine,
  'tavt': ShapingModel.universalShapingEngine,
  'tglg': ShapingModel.universalShapingEngine,
  'tibt': ShapingModel.universalShapingEngine,
  'tirh': ShapingModel.universalShapingEngine,
};
