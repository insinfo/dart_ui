/// Script itemization, UAX #24, and the map from a script to an OpenType tag.
///
/// A shaper is not script-neutral. Arabic needs the cursive joining machinery,
/// Devanagari needs its syllable reordering, Hangul needs jamo composition, and
/// each of those is selected by a four-letter OpenType script tag that the
/// shaper looks up in the font's GSUB and GPOS tables. Hand the shaper the
/// wrong tag and it does not fail - it applies the wrong feature set. Arabic
/// shaped as `latn` comes out as a row of disconnected isolated letterforms;
/// Devanagari shaped as `latn` comes out with its vowel signs on the wrong side
/// of their consonants. Both are legible-looking and wrong.
///
/// Which is why a fixed `script` on the shaper is not a simplification, it is a
/// ceiling: it makes every non-Latin string unshapeable, and the only symptom
/// is text that renders.
///
/// ## What itemization has to decide
///
/// Most characters carry their own answer - U+0628 is Arabic, U+05D0 is Hebrew.
/// The problem is everything shared. Space, digits, and most punctuation have
/// Script=Common; combining marks have Script=Inherited. Neither is a script,
/// both mean "take the script of the context", and a naive itemizer that gave
/// them their own runs would cut a word in half at every comma and separate
/// every accent from the letter it sits on.
///
/// [itemize] resolves them:
///
///  * **Inherited** always joins the run before it. A combining mark modifies
///    the character it follows, so it cannot belong to what comes after.
///  * **Common** also joins the run before it, *unless* its Script_Extensions
///    says it cannot occur in that script and can occur in the next one. That
///    is the tie-break UAX #24 §5.1 describes, and it is what keeps U+0640
///    ARABIC TATWEEL out of a Latin run.
///  * **Paired brackets** are matched. A parenthesis opened inside an Arabic
///    run and closed after some Latin resolves to Arabic at *both* ends, which
///    is what makes the two halves of a parenthetical mirror consistently under
///    bidi rule L4. Without it the opener would be Arabic and the closer Latin,
///    and only one of them would turn around.
///  * Leading Common or Inherited characters, which have no run before them,
///    join the first real script instead. A string that is entirely Common is
///    one run of [Script.zyyy].
///
/// ## Indices
///
/// [ScriptRun.start] and [ScriptRun.end] are **UTF-16 code unit offsets**, the
/// same indexing as `GlyphRun.clusters` and `BidiParagraph.levels` - see the
/// "## Indices" comment in `bidi.dart`. Both halves of a surrogate pair belong
/// to the same run, because a run boundary is always a code point boundary, so
/// a run can be sliced straight out of the source string and the levels array
/// can be sliced with the same offsets.
///
/// The runs are contiguous and in logical order: the first starts at 0, each
/// begins where the last ended, and the last ends at `text.length`. Joining
/// their slices reproduces the input exactly. Itemization is *not* reordering -
/// that is bidi's job, and it runs on these runs, not instead of them.
///
/// ## What is deliberately not here
///
/// **Font fallback.** Itemization says which script a run is; it says nothing
/// about which font can draw it. A run may still need splitting further because
/// no single face covers it, and that decision needs the font list, which lives
/// a layer up.
///
/// **Language.** The OpenType `language system` tag - `TRK` for Turkish, `SRB`
/// for Serbian - changes shaping within a script, and no property of a code
/// point can supply it. It has to come from the caller.
///
/// **Merging Han, Hiragana and Katakana.** Japanese text alternates between all
/// three within a word, and this file gives each its own run rather than
/// pretending they are one script. They agree on their OpenType tag anyway -
/// see [openTypeTagOf] - so a shaper that keys off the tag shapes them
/// identically; only the run boundaries differ.
library;

import 'dart:typed_data';

import 'tables/mirroring_table.dart';
import 'tables/script_table.dart';

export 'tables/script_table.dart'
    show Script, hasScriptExtension, scriptExtensionsOf, scriptOf;

// ---------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------

/// A maximal stretch of text that resolves to one script.
final class ScriptRun {
  /// Creates a run covering `[start, end)` of the itemized string.
  const ScriptRun(this.start, this.end, this.script);

  /// UTF-16 offset of the first code unit of the run.
  final int start;

  /// UTF-16 offset one past the last code unit of the run.
  final int end;

  /// The resolved script.
  ///
  /// [Script.zyyy] only when the run has no context to resolve against - text
  /// that is entirely Common, such as `"123"`. [Script.zinh] never: an
  /// Inherited character always has something to inherit from, or the text
  /// starts with it and it takes the script of what follows.
  final Script script;

  /// The number of UTF-16 code units in the run.
  int get length => end - start;

  /// The slice of [text] this run covers.
  ///
  /// A convenience for tests and diagnostics. Shaping wants the offsets, not a
  /// substring, so that cluster indices stay in the coordinate system of the
  /// whole paragraph.
  String textIn(String text) => text.substring(start, end);

  @override
  String toString() => 'ScriptRun($start..$end, ${script.code})';

  @override
  bool operator ==(Object other) =>
      other is ScriptRun &&
      other.start == start &&
      other.end == end &&
      other.script == script;

  @override
  int get hashCode => Object.hash(start, end, script);
}

// ---------------------------------------------------------------------------
// Itemization
// ---------------------------------------------------------------------------

/// How deep the bracket stack goes before pairing stops.
///
/// The same 63 as BD16 in UAX #9, and for the same reason: the stack exists to
/// make a common case right, not to survive adversarial input, and text nested
/// more than sixty-three brackets deep is not text. Past the limit, brackets
/// stop pairing and fall back to the ordinary Common rule, which still produces
/// contiguous runs covering the whole string - it just may split a parenthetical
/// that a deeper stack would have kept together.
const int _maxBracketDepth = 63;

/// Splits [text] into runs of one script each, in logical order.
///
/// Returns an empty list for empty text. Otherwise the runs are contiguous,
/// non-empty, and cover `0..text.length`, so `runs.map((r) => r.textIn(text))`
/// joined is [text].
List<ScriptRun> itemize(String text) {
  if (text.isEmpty) return const <ScriptRun>[];

  // Pass 1: decode to code points, remembering where each one started. A
  // string of n code units holds at most n code points, so both buffers are
  // allocated once at the worst-case size rather than grown.
  final int units = text.length;
  final Int32List codePoints = Int32List(units);
  final Int32List offsets = Int32List(units);
  int count = 0;
  for (int i = 0; i < units;) {
    final int unit = text.codeUnitAt(i);
    offsets[count] = i;
    if (unit >= 0xD800 && unit < 0xDC00 && i + 1 < units) {
      final int low = text.codeUnitAt(i + 1);
      if (low >= 0xDC00 && low < 0xE000) {
        // A surrogate pair is one code point occupying two offsets. Both
        // halves end up in whichever run the code point lands in, because the
        // run boundary is this offset or the next code point's.
        codePoints[count++] =
            0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
        i += 2;
        continue;
      }
    }
    // An unpaired surrogate is left as-is. Its Script is Unknown, which makes
    // it its own run rather than something that silently joins its neighbour.
    codePoints[count++] = unit;
    i += 1;
  }

  final _Itemizer itemizer = _Itemizer(codePoints, offsets, count, units);
  return itemizer.run();
}

final class _Itemizer {
  _Itemizer(this._codePoints, this._offsets, this._count, this._units)
      : _resolved = List<Script>.filled(_count, Script.zyyy),
        _forced = List<Script?>.filled(_count, null),
        _closerOf = Int32List(_count);

  final Int32List _codePoints;
  final Int32List _offsets;
  final int _count;
  final int _units;

  /// The script each code point ended up in.
  final List<Script> _resolved;

  /// For a closing bracket whose opener has already been resolved, the script
  /// the opener got. Null for everything else.
  final List<Script?> _forced;

  /// For an opening bracket, the index of the closer it pairs with, or -1.
  final Int32List _closerOf;

  /// The first index that has not been assigned a script yet.
  int _pending = 0;

  /// The script of the run being built, null before the first real script.
  Script? _current;

  List<ScriptRun> run() {
    _pairBrackets();
    _assign();
    return _collect();
  }

  /// Matches opening and closing brackets so that a pair can be forced to one
  /// script.
  void _pairBrackets() {
    _closerOf.fillRange(0, _count, -1);
    final Int32List stackIndex = Int32List(_maxBracketDepth);
    final Int32List stackCloser = Int32List(_maxBracketDepth);
    int depth = 0;
    for (int k = 0; k < _count; k++) {
      final int cp = _codePoints[k];
      switch (bracketTypeOf(cp)) {
        case BracketType.open:
          if (depth == _maxBracketDepth) break;
          stackIndex[depth] = k;
          stackCloser[depth] = pairedBracketOf(cp);
          depth++;
        case BracketType.close:
          // Scan down for the innermost opener this closes, and drop anything
          // that was left open inside it. An unmatched closer changes nothing,
          // which is what keeps `a) (b` from consuming the later opener.
          for (int d = depth - 1; d >= 0; d--) {
            if (stackCloser[d] == cp) {
              _closerOf[stackIndex[d]] = k;
              depth = d;
              break;
            }
          }
        case BracketType.none:
          break;
      }
    }
  }

  void _assign() {
    for (int k = 0; k < _count; k++) {
      final Script raw = _forced[k] ?? scriptOf(_codePoints[k]);
      if (raw.isContextual) {
        // Common or Inherited: it has no script of its own, so it waits for
        // one to arrive.
        continue;
      }
      final Script? current = _current;
      if (current == null || current == raw) {
        _flush(k + 1, raw);
      } else {
        _split(k, current, raw);
      }
      _current = raw;
    }
    if (_pending < _count) {
      // Trailing Common or Inherited characters, or a string with no real
      // script in it at all. The former join the run before them; the latter
      // is one Common run, which is the honest answer for "123" - there is no
      // script in it to find.
      _flush(_count, _current ?? Script.zyyy);
    }
  }

  /// Assigns [script] to everything from [_pending] up to (not including)
  /// [end].
  void _flush(int end, Script script) {
    for (int j = _pending; j < end; j++) {
      _place(j, script);
    }
    _pending = end;
  }

  /// Handles a change from [current] to [next] at index [k], dividing the
  /// undecided characters between them.
  ///
  /// The division is one cut, not a per-character decision. Once a character
  /// has been pulled forward into [next] - a tatweel before an Arabic word,
  /// say - everything between it and the boundary goes with it, including the
  /// space that would otherwise have tested as unconstrained and stayed
  /// behind. Deciding each character on its own produces `Latn Arab Latn Arab`
  /// for `abc _ بيت`, which is four runs where the text has two and hands the
  /// shaper a one-character Latin run containing a space.
  void _split(int k, Script current, Script next) {
    int cut = k;
    for (int j = _pending; j < k; j++) {
      if (_prefersNext(j, current, next)) {
        cut = j;
        break;
      }
    }
    for (int j = _pending; j < cut; j++) {
      _place(j, current);
    }
    for (int j = cut; j <= k; j++) {
      _place(j, next);
    }
    _pending = k + 1;
  }

  /// Whether the undecided character at [j] belongs with the run starting at
  /// the boundary rather than the one ending at it.
  ///
  /// The default is "with the run before", which is what makes a comma stay
  /// with the sentence it ends and a mark stay with its base. Script_Extensions
  /// overrides that only when it is decisive: the character cannot occur in
  /// [current] and can occur in [next].
  bool _prefersNext(int j, Script current, Script next) {
    final int cp = _codePoints[j];
    // Inherited characters modify what precedes them, so they never move
    // forward however permissive their extensions are.
    if (scriptOf(cp) == Script.zinh) return false;
    final List<Script> extensions = scriptExtensionsOf(cp);
    // A single contextual value is Script_Extensions saying nothing: the
    // character is not restricted to any script.
    if (extensions.length == 1 && extensions[0].isContextual) return false;
    return !hasScriptExtension(cp, current) && hasScriptExtension(cp, next);
  }

  /// Records the script of one code point, and propagates it to the closing
  /// bracket it pairs with.
  void _place(int index, Script script) {
    _resolved[index] = script;
    final int closer = _closerOf[index];
    if (closer >= 0) _forced[closer] = script;
  }

  List<ScriptRun> _collect() {
    final List<ScriptRun> runs = <ScriptRun>[];
    int start = 0;
    Script script = _resolved[0];
    for (int k = 1; k < _count; k++) {
      if (_resolved[k] == script) continue;
      runs.add(ScriptRun(start, _offsets[k], script));
      start = _offsets[k];
      script = _resolved[k];
    }
    runs.add(ScriptRun(start, _units, script));
    return runs;
  }
}

// ---------------------------------------------------------------------------
// OpenType script tags
// ---------------------------------------------------------------------------

/// The tag a shaper uses when the font has no table for the script.
const String defaultOpenTypeTag = 'DFLT';

/// The OpenType script tag to shape [script] with.
///
/// ## Where the tags come from
///
/// For all but a handful of scripts the OpenType tag is the ISO 15924 code in
/// lower case, and that is what this returns by default - including for scripts
/// added to Unicode too recently to appear in Microsoft's registry, which is
/// the same fallback HarfBuzz uses and the same convention every registration
/// since has followed. [_tagOverrides] holds the exceptions, and there are only
/// three kinds:
///
///  * The four tags that predate four-letter codes and are padded with spaces:
///    `lao `, `nko `, `vai `, `yi  `. A tag is four bytes; the space is part of
///    it, and trimming it produces a tag no font contains.
///  * Hiragana and Katakana, which share the tag `kana`. OpenType has no
///    `hira`, because no font distinguishes the two in its feature tables.
///  * Common, Inherited and Unknown, which are not scripts and map to `DFLT`.
///
/// ## v1 and v2 for the Indic scripts
///
/// Nine Indic scripts and Myanmar have two registered tags: an original
/// (`deva`, `beng`, `mymr`) and a second-generation one (`dev2`, `bng2`,
/// `mym2`). They are not spellings of the same thing. The v1 tags go with the
/// old Uniscribe shaping model, in which the *shaper* reordered the glyphs and
/// the font's features were written to expect the reordered order; the v2 tags
/// go with the model in which the font declares more of the work and the shaper
/// follows the font. Choosing the wrong one against a given font does not fail
/// cleanly - it produces mis-ordered matras.
///
/// **This function returns the v2 tag** for those ten scripts. It is what every
/// font shipped in the last fifteen years carries, what HarfBuzz prefers, and
/// what new fonts are authored against; v1-only fonts still exist, so
/// [openTypeTagsOf] returns both, newest first, for a shaper that can look in
/// the font before deciding. A caller that takes only [openTypeTagOf] and finds
/// no matching script table in the font must fall back rather than shape with
/// the tag it asked for.
String openTypeTagOf(Script script) => _tags[script.index];

/// Every tag worth trying for [script], best first, ending in `DFLT`.
///
/// A shaper should walk this list and use the first tag the font's GSUB or GPOS
/// table actually contains. The list is shared and unmodifiable; it is not
/// rebuilt per call.
List<String> openTypeTagsOf(Script script) => _tagChains[script.index];

/// The scripts whose OpenType tag is not simply their lower-cased ISO code.
const Map<Script, String> _tagOverrides = <Script, String>{
  // Not scripts: nothing to select, so the font's default script table.
  Script.zyyy: defaultOpenTypeTag,
  Script.zinh: defaultOpenTypeTag,
  Script.zzzz: defaultOpenTypeTag,

  // Three-letter tags padded to four. The trailing space is significant.
  Script.laoo: 'lao ',
  Script.nkoo: 'nko ',
  Script.vaii: 'vai ',
  Script.yiii: 'yi  ',

  // Japanese kana share one tag.
  Script.hira: 'kana',
  Script.kana: 'kana',

  // Second-generation Indic tags; see [openTypeTagOf].
  Script.beng: 'bng2',
  Script.deva: 'dev2',
  Script.gujr: 'gjr2',
  Script.guru: 'gur2',
  Script.knda: 'knd2',
  Script.mlym: 'mlm2',
  Script.mymr: 'mym2',
  Script.orya: 'ory2',
  Script.taml: 'tml2',
  Script.telu: 'tel2',
};

/// The v1 tag to fall back to for each script that has a v2 tag.
const Map<Script, String> _legacyTags = <Script, String>{
  Script.beng: 'beng',
  Script.deva: 'deva',
  Script.gujr: 'gujr',
  Script.guru: 'guru',
  Script.knda: 'knda',
  Script.mlym: 'mlym',
  Script.mymr: 'mymr',
  Script.orya: 'orya',
  Script.taml: 'taml',
  Script.telu: 'telu',
};

/// One tag per script, indexed by [Script.index].
///
/// Built once rather than computed per call, because the default case is
/// `code.toLowerCase()` and a shaper asks for the tag of every run of every
/// paragraph.
final List<String> _tags = List<String>.generate(
  Script.values.length,
  (int index) {
    final Script script = Script.values[index];
    return _tagOverrides[script] ?? script.code.toLowerCase();
  },
  growable: false,
);

final List<List<String>> _tagChains = List<List<String>>.generate(
  Script.values.length,
  (int index) {
    final Script script = Script.values[index];
    final String tag = _tags[index];
    final String? legacy = _legacyTags[script];
    return List<String>.unmodifiable(<String>[
      tag,
      if (legacy != null) legacy,
      if (tag != defaultOpenTypeTag) defaultOpenTypeTag,
    ]);
  },
  growable: false,
);
