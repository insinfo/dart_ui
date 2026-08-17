/// Where the widget layer gets a face from - and where a *second* face comes
/// from when the first one cannot draw a character.
///
/// A [Typeface] is parsed font bytes: it cannot be `const`, it costs a file
/// read and a table walk to build, and it is worth exactly one per face for the
/// life of the process. A [ThemeData] is `const` and there are `static const`
/// instances of it. Those two facts cannot both hold if the theme carries the
/// face, so the theme carries the *size* - a double - and the face is resolved
/// here, by identity rather than by value.
///
/// That split is the whole design. A control asks the theme how big its text
/// is and asks this registry what to draw it with; neither question can make
/// the other one fail.
///
/// ## Why one face is not enough
///
/// No font covers Unicode. A Latin interface face has no Han ideographs, no
/// Arabic, and no emoji, so a registry that holds a single [Typeface] cannot
/// draw a Japanese name, an Arabic label or a 🙂 - and the failure is silent,
/// because a missing glyph is `.notdef` and `.notdef` is a box that draws
/// perfectly well. This file therefore holds a **registry of faces** and a
/// **fallback chain** over them, described on [FontRegistry.resolveCodePoint].
///
/// Three rules this file exists to keep:
///
///   * **discovery never throws.** A machine with no readable font, or with a
///     font this parser cannot read, must draw no text - not fail to start.
///     Every path out of [_searchSystemFonts] returns null instead of
///     propagating;
///   * **a test never depends on the machine.** [useTypeface] and
///     [useFontFile] replace whatever discovery would have found, and an
///     injected [SystemFontIndex] replaces the machine's font list entirely, so
///     a golden asserts on Roboto from `test/fonts/` and means the same thing
///     on a Windows box, a CI container with no fonts installed, and a Mac;
///   * **a substitution is reported, never assumed.** Every fallback answer
///     carries how it was reached ([FontFallbackStep]) and every emoji answer
///     carries what could not be honoured ([EmojiResolution.limitation]).
///     Section 6.6: choosing a worse font silently is worse than choosing
///     nothing.
library;

import 'dart:io';
import 'dart:typed_data';

import '../../geometry/size.dart';
import '../../platform/system_fonts.dart';
import '../../text/cmap.dart';
import '../../text/font_data.dart';
import '../../text/font_tables.dart';
import '../../text/script.dart';
import '../../text/sfnt.dart';
import '../../text/typeface.dart';
import 'text_painter.dart';

/// A search for the interface font: the face it found and where it came from,
/// or null if it found none.
typedef FontSearch = ({Typeface face, String source})? Function();

/// The pixel size interface text is drawn at when nothing says otherwise.
///
/// Lives here rather than in the theme so that the widgets layer and this
/// layer cannot disagree about it; [ThemeData.fontSize] defaults to it.
const double kDefaultUiFontSize = 12.0;

/// The painter the framework's own widgets draw their labels with.
///
/// Shared for the same reason the face is: a [TextPainter] owns the shaper,
/// and the shaper owns both its scratch buffers and the parsed `kern` table of
/// every face it has seen. One painter per control would re-parse kerning for
/// every button on screen and allocate a set of buffers to go with it.
///
/// Sharing is safe because painting is synchronous and single-threaded: a run
/// returned by it borrows the shaper's buffers and every caller here consumes
/// the run before shaping again.
final TextPainter uiTextPainter = TextPainter();

/// Reads the identity of every face in [file], or an empty list.
///
/// This is the OpenType half of system font discovery, and it lives here rather
/// than beside the directory walk because `platform` may not depend on `text` -
/// see the library comment of `platform/system_fonts.dart`. It is the default
/// [SystemFontFaceReader] and it honours that type's contract: **it never
/// throws.** A fonts directory holds bitmap fonts, Type 1 fonts, truncated
/// downloads and files that are not fonts at all, and none of that may stop the
/// enumeration.
///
/// Only three tables are read - `name`, `OS/2` and `head` - because that is
/// everything a face is *selected* by. The outlines, which are all of the file
/// size, are read later and only for a face that was actually chosen.
///
/// Collections are expanded: every face inside a `.ttc`/`.otc` is indexed
/// separately, which is not an optional nicety - on macOS nearly every system
/// family only exists inside one.
///
/// A face with no family name at all is skipped rather than indexed under its
/// file name. A file name is not a family (see `NameTable`), and indexing one
/// as though it were is precisely the mistake this whole path exists to undo.
List<SystemFontFace> readSystemFontFaces(SystemFontFile file) {
  final Uint8List bytes;
  try {
    bytes = file.readBytes();
  } on Object {
    return const <SystemFontFace>[];
  }

  final FontData data = FontData(bytes);
  final SfntFile first;
  try {
    first = SfntFile.parse(data);
  } on Object {
    return const <SystemFontFace>[];
  }

  final List<SystemFontFace> faces = <SystemFontFace>[];
  for (int index = 0; index < first.faceCount; index++) {
    try {
      final SfntFile sfnt =
          index == 0 ? first : SfntFile.parse(data, faceIndex: index);
      final NameTable? name = NameTable.parse(sfnt);
      final String? family = name?.family;
      if (family == null || family.isEmpty) continue;
      final Os2Table? os2 = Os2Table.parse(sfnt);
      final HeadTable head = HeadTable.parse(sfnt);
      faces.add(
        SystemFontFace(
          path: file.path,
          faceIndex: index,
          family: family,
          legacyFamily: name?.legacyFamily,
          subfamily: name?.subfamily,
          postScriptName: name?.postScriptName,
          // Without OS/2 the only style information in the file is macStyle's
          // two bits, and `declaresStyle: false` says so rather than letting a
          // matcher treat an assumed 400 as a stated one.
          weight: os2?.weightClass ?? (head.isBold ? 700 : 400),
          width: os2?.widthClass ?? 5,
          italic: os2?.isItalic ?? head.isItalic,
          oblique: os2?.isOblique ?? false,
          declaresStyle: os2 != null,
          coverage: os2 == null
              ? UnicodeCoverage.none
              : UnicodeCoverage(
                  os2.ulUnicodeRange1,
                  os2.ulUnicodeRange2,
                  os2.ulUnicodeRange3,
                  os2.ulUnicodeRange4,
                ),
        ),
      );
    } on Object {
      continue; // One unreadable face does not condemn the others.
    }
  }
  return faces;
}

/// How a character's face was arrived at. Reported, never inferred.
enum FontFallbackStep {
  /// The face the caller already had covers the character. The common case,
  /// and the only one that costs nothing.
  requested,

  /// Another face of the same family covers it. Families are not uniform: a
  /// family's Bold may carry a script its Regular does not.
  family,

  /// A family named in the per-script preference list for this platform.
  scriptPreference,

  /// Found by scanning the index for a face whose `OS/2` claims the
  /// character's block, then confirming with that face's `cmap`.
  coverageScan,

  /// The scan hit its budget before finding a face. Distinct from [none]
  /// because it means "we stopped looking", not "there is nothing".
  budgetExhausted,

  /// No installed face has the character.
  none,
}

/// The outcome of asking for a face that can draw one character.
final class FallbackResolution {
  const FallbackResolution({
    required this.face,
    required this.glyph,
    required this.step,
    required this.facesExamined,
  });

  /// The face to draw with, or null when nothing on the machine has the
  /// character.
  final Typeface? face;

  /// The glyph in [face], already looked up. [notdefGlyph] when [face] is null.
  final int glyph;

  final FontFallbackStep step;

  /// How many faces had to be opened to reach this answer, for the diagnostic
  /// "why did the first frame take 300 ms".
  final int facesExamined;

  bool get found => face != null;

  @override
  String toString() => 'FallbackResolution(${face ?? 'none'} '
      'glyph $glyph, ${step.name}, $facesExamined examined)';
}

/// Which presentation an emoji code point was resolved for.
enum EmojiPresentation {
  /// A monochrome glyph was asked for, by `U+FE0E` VARIATION SELECTOR-15.
  text,

  /// A colour glyph was asked for, by `U+FE0F` VARIATION SELECTOR-16.
  emoji,

  /// No selector was present, so the character's own default applies. This
  /// engine does not carry the Emoji_Presentation property, so it does not
  /// pretend to know which that is; see [EmojiResolution.limitation].
  unspecified,
}

/// What could be honoured of an emoji request, and what could not.
///
/// ## The limit this type exists to declare
///
/// Colour glyphs are stored in tables this engine does not implement: `COLR`
/// and `CPAL` (layered vector), `CBDT`/`CBLC` and `sbix` (embedded bitmaps).
/// A face carrying them still parses, because they sit alongside ordinary
/// `glyf` outlines, and drawing it produces the *base* outlines - a monochrome
/// silhouette - or, where the base glyph is empty because all the artwork is in
/// the bitmap, nothing at all.
///
/// Both outcomes are legitimate engineering states and neither may be silent. A
/// blank where an emoji was asked for, discovered by a user, is a bug report
/// with no information in it. So [limitation] carries the sentence that explains
/// it and [drawable] says outright whether anything would appear on screen.
final class EmojiResolution {
  const EmojiResolution({
    required this.face,
    required this.glyph,
    required this.presentation,
    required this.isZwjSequence,
    required this.drawable,
    required this.colourTable,
    this.limitation,
  });

  final Typeface? face;

  /// The glyph for the first base character of the cluster, in [face].
  final int glyph;

  final EmojiPresentation presentation;

  /// Whether the cluster joined several characters with `U+200D`, as the family
  /// and profession emoji do.
  ///
  /// A ZWJ sequence draws as one glyph only if the face's `GSUB` ligates it;
  /// this type reports the face that covers the sequence, and the ligature is
  /// the shaper's business. When no single face covers every part, [limitation]
  /// says so, because a sequence split across faces renders as its pieces -
  /// which is the difference between 👨‍👩‍👧 and three separate people.
  final bool isZwjSequence;

  /// Whether drawing [glyph] would put anything on screen at all.
  ///
  /// False for a face whose emoji artwork lives entirely in a colour bitmap:
  /// the outline is empty, and this engine draws outlines.
  final bool drawable;

  /// The colour table the chosen face carries - `COLR`, `CBDT` or `sbix` - or
  /// null when it has none. Never implemented, always reported.
  final String? colourTable;

  /// The one sentence describing what was not honoured, or null when the
  /// request was met exactly.
  final String? limitation;

  bool get found => face != null;

  @override
  String toString() => 'EmojiResolution(${face ?? 'none'}, '
      'glyph $glyph, ${presentation.name}'
      '${colourTable == null ? '' : ', $colourTable'}'
      '${drawable ? '' : ', not drawable'})';
}

/// Resolves the interface font, and every face text falls back to.
///
/// Not an inherited widget and not a theme field: a face is a shared,
/// expensive, mutable-only-by-configuration resource, which is what a registry
/// is for. An application that ships its own font calls [useTypeface] at
/// startup and never thinks about it again.
final class FontRegistry {
  /// [search] replaces the walk over the machine's font directories.
  ///
  /// The seam exists for one case that cannot be reproduced otherwise: a
  /// machine with **no** usable font. Every development machine has one, so
  /// without an injectable search the degraded path would only ever be
  /// exercised in production.
  ///
  /// [index] replaces the machine's font list for family lookup and fallback.
  /// With one supplied, nothing under this registry ever reads a system font
  /// directory, which is what makes a fallback chain testable: the same three
  /// files from `test/fonts/` on every machine.
  ///
  /// [faceReader] replaces how a font file's identity is read. Its only
  /// purpose is to let a test count file opens; the default is
  /// [readSystemFontFaces].
  FontRegistry({
    FontSearch? search,
    SystemFontIndex? index,
    SystemFontFaceReader? faceReader,
  })  : _search = search ?? _searchSystemFonts,
        _injectedIndex = index,
        _faceReader = faceReader ?? readSystemFontFaces;

  final FontSearch _search;
  final SystemFontIndex? _injectedIndex;
  final SystemFontFaceReader _faceReader;

  /// The registry the widget layer reads.
  ///
  /// Replaceable rather than final so a test can install one that finds
  /// nothing; the ordinary path is [useTypeface] on this instance followed by
  /// [reset] in a tear-down.
  static FontRegistry instance = FontRegistry();

  Typeface? _face;

  /// Whether discovery has already run. Separate from `_face != null` because
  /// a *failed* search must not be retried on every paint: enumerating a fonts
  /// directory costs hundreds of stat calls, and a machine that had no usable
  /// font a moment ago still has none.
  bool _searched = false;

  bool _overridden = false;

  /// Where the face came from, for a diagnostic that would otherwise be
  /// "text is missing and nobody knows why".
  String? _source;

  /// One [ScaledTypeface] per size and requested weight.
  ///
  /// Bounded by how many distinct sizes an application uses - a handful - and
  /// worth keeping because the glyph cache and the display list's font table
  /// both key on the scaled face, and every control asks for one per paint.
  final Map<(double, int), ScaledTypeface> _sized =
      <(double, int), ScaledTypeface>{};

  /// Faces this registry has parsed, by [SystemFontFace.key].
  ///
  /// Holds nulls: a file that failed to parse is remembered as having failed,
  /// so a fallback scan cannot re-read and re-fail the same broken font once
  /// per character.
  final Map<String, Typeface?> _opened = <String, Typeface?>{};

  /// Faces handed to [registerTypeface], described the way an indexed face is
  /// so that one matching rule covers both.
  final List<SystemFontFace> _registeredFaces = <SystemFontFace>[];

  int _opens = 0;

  /// How many font files this registry has opened and parsed.
  ///
  /// The number a test asserts on to prove the caches work, and the number to
  /// look at when the first frame is slow.
  int get facesOpened => _opens;

  /// Resolved fallbacks, per starting face, keyed by script and code point.
  ///
  /// Nested by the face the search *started* from because the answer depends on
  /// it: the chain's first two steps are "the face you have" and "its family",
  /// so a decision made for a Roboto run says nothing about a DejaVu one. The
  /// outer map holds one or two entries in practice and is keyed by identity,
  /// since [Typeface] does not define equality.
  final Map<Typeface?, Map<int, FallbackResolution>> _fallbackCache =
      <Typeface?, Map<int, FallbackResolution>>{};

  int _fallbackQueries = 0;
  int _fallbackMisses = 0;

  /// Fallback lookups served, and how many of those had to search.
  ///
  /// A run of Japanese text asks per character and gets the same answer every
  /// time; without the cache each of those characters would re-scan the index.
  ({int queries, int searches}) get fallbackCacheStats =>
      (queries: _fallbackQueries, searches: _fallbackMisses);

  /// The interface face at [pixelSize], or null when this machine has none.
  ///
  /// Null is the honest answer and callers must handle it; see
  /// [estimatedSize] for what they should reserve when they get it.
  ScaledTypeface? uiFont(double pixelSize, {int weight = 400}) {
    final Typeface? face = uiTypeface;
    if (face == null) return null;
    final Typeface resolved = weight == face.weightClass
        ? face
        : faceFor(face.familyName ?? '', weight: weight) ?? face;
    return _sized[(pixelSize, weight)] ??= resolved.atSize(pixelSize);
  }

  /// The unsized interface face, discovering it on first use.
  Typeface? get uiTypeface {
    if (_searched || _overridden) return _face;
    _searched = true;
    final ({Typeface face, String source})? found = _search();
    _face = found?.face;
    _source = found?.source;
    return _face;
  }

  /// Whether text will actually be drawn. False means every label is blank.
  bool get hasUiFont => uiTypeface != null;

  /// A human-readable note about which font is in use; null when there is none.
  String? get source {
    // Touches the getter so that a caller who only asks this question still
    // gets an answer rather than "not searched yet".
    uiTypeface;
    return _source;
  }

  /// Uses [face] for interface text, in place of anything on the machine.
  ///
  /// The escape hatch for an application that ships its own font and the only
  /// supported way for a test to get a deterministic one. The face is also
  /// registered for fallback, since a face good enough to draw the interface in
  /// is good enough to fall back to.
  void useTypeface(Typeface face, {String source = 'override'}) {
    _face = face;
    _overridden = true;
    _source = source;
    _sized.clear();
    _fallbackCache.clear();
    registerTypeface(face, source: source);
  }

  /// Parses [path] and uses it. Returns false, and changes nothing, if the
  /// file cannot be read or parsed - the caller decides whether that is fatal,
  /// which is the difference between an application's own font and a fallback.
  bool useFontFile(String path) {
    try {
      final Uint8List bytes = File(path).readAsBytesSync();
      useTypeface(Typeface.parse(bytes), source: path);
      return true;
    } on Object {
      return false;
    }
  }

  /// Adds [face] to the faces this registry can choose from.
  ///
  /// For an application that ships fonts: a Latin face for the interface and a
  /// CJK or emoji face beside it. Registered faces are searched **before** the
  /// machine's, both for [faceFor] and for fallback, because a font the
  /// application shipped is a font it chose, and a font on the machine is one
  /// it merely found.
  ///
  /// [family] overrides the name in the file, for the rare face whose `name`
  /// table is unusable. Registering the same face twice is a no-op.
  void registerTypeface(
    Typeface face, {
    String? family,
    String source = 'registered',
  }) {
    for (final MapEntry<String, Typeface?> entry in _opened.entries) {
      if (identical(entry.value, face)) return;
    }
    final String name = family ?? face.familyName ?? source;
    // The source doubles as the key when it is a path, so that a face
    // registered from `test/fonts/Roboto-Regular.ttf` and the *indexed* face
    // for that same file are one entry rather than two: without this the
    // fallback chain would parse the file a second time on its way past the
    // family step.
    final String key = _opened.containsKey(source)
        ? '$source#${_registeredFaces.length}'
        : source;
    _registeredFaces.add(
      SystemFontFace(
        path: key,
        faceIndex: 0,
        family: name,
        legacyFamily: face.name?.legacyFamily,
        subfamily: face.subfamilyName,
        postScriptName: face.name?.postScriptName,
        weight: face.weightClass,
        width: face.widthClass,
        italic: face.isItalic,
        oblique: face.isOblique,
        declaresStyle: face.declaresStyle,
        coverage: face.os2 == null
            ? UnicodeCoverage.none
            : UnicodeCoverage(
                face.os2!.ulUnicodeRange1,
                face.os2!.ulUnicodeRange2,
                face.os2!.ulUnicodeRange3,
                face.os2!.ulUnicodeRange4,
              ),
      ),
    );
    // Pre-populating the open-face cache is what makes a registered face cost
    // nothing to "open": `open` finds it here and never touches a file.
    _opened[key] = face;
    _fallbackCache.clear();
  }

  /// The faces this registry was handed directly, in registration order.
  List<SystemFontFace> get registeredFaces =>
      List<SystemFontFace>.unmodifiable(_registeredFaces);

  /// The machine's font index, built on first use and then cached.
  ///
  /// **This is the expensive one.** Building it opens every installed font
  /// file - a third of a second on a well-stocked Windows machine - so it is
  /// deliberately not touched by [uiTypeface], which resolves the interface
  /// face from a handful of files instead. It is built the first time somebody
  /// asks for a family by name or for a character the current face lacks, both
  /// of which genuinely need to know what is installed.
  ///
  /// The cache and its invalidation policy live in [SystemFonts.cachedIndex];
  /// an injected index bypasses it entirely.
  SystemFontIndex get systemFonts =>
      _injectedIndex ?? SystemFonts.cachedIndex(reader: _faceReader);

  /// Parses the file behind [face], or returns null if it cannot be read.
  ///
  /// Cached by [SystemFontFace.key], including the failures: a fallback scan
  /// that meets a broken font must not re-read it once per character.
  Typeface? open(SystemFontFace face) {
    final String key = face.key;
    if (_opened.containsKey(key)) return _opened[key];
    _opens++;
    Typeface? parsed;
    try {
      parsed = Typeface.parse(
        File(face.path).readAsBytesSync(),
        faceIndex: face.faceIndex,
      );
    } on Object {
      parsed = null;
    }
    _opened[key] = parsed;
    return parsed;
  }

  /// The closest face in [family] to the requested style, or null.
  ///
  /// Registered faces first, then the machine's index, each matched by the CSS
  /// rule documented on [SystemFontIndex]. Null means the family is not
  /// installed - **not** "here is something else": substituting a different
  /// family without saying so is the failure section 6.6 forbids, and the
  /// caller that wants a substitute asks for one by name or uses
  /// [resolveCodePoint].
  Typeface? faceFor(
    String family, {
    int weight = 400,
    int width = 5,
    bool italic = false,
    bool oblique = false,
  }) {
    final String key = SystemFontIndex.normalizeFamily(family);
    final List<SystemFontFace> registered = <SystemFontFace>[
      for (final SystemFontFace face in _registeredFaces)
        if (SystemFontIndex.normalizeFamily(face.family) == key ||
            (face.legacyFamily != null &&
                SystemFontIndex.normalizeFamily(face.legacyFamily!) == key))
          face,
    ];
    final FaceMatch? match = registered.isNotEmpty
        ? SystemFontIndex.matchAmong(
            registered,
            weight: weight,
            width: width,
            italic: italic,
            oblique: oblique,
          )
        : systemFonts.match(
            family,
            weight: weight,
            width: width,
            italic: italic,
            oblique: oblique,
          );
    if (match == null) return null;
    return open(match.face);
  }

  // --- the fallback chain --------------------------------------------------

  /// A face that can draw [codePoint], searching outward from [from].
  ///
  /// ## The chain
  ///
  /// Each step is tried in order and the first face whose **`cmap`** answers
  /// wins. The steps differ only in which candidates they offer and how much
  /// they cost:
  ///
  ///   1. **[FontFallbackStep.requested]** - [from], or the interface face when
  ///      [from] is null. One binary search, no allocation, no file opened.
  ///      This is the answer for essentially all Latin text and it is why the
  ///      chain is cheap in the common case;
  ///   2. **[FontFallbackStep.family]** - the other faces of that face's
  ///      family. A family is not uniform: its Bold may carry a script its
  ///      Regular does not, and staying inside the family keeps the run's
  ///      design consistent;
  ///   3. **[FontFallbackStep.scriptPreference]** - the families this platform
  ///      ships the character's script in, by name, in preference order (see
  ///      [fallbackFamiliesFor]). Named rather than discovered because "the
  ///      face Windows draws Japanese in" is knowledge no table in a font
  ///      contains;
  ///   4. **[FontFallbackStep.coverageScan]** - the indexed faces, ordered by
  ///      whether their `OS/2` claims the character's Unicode range. See
  ///      [_coverageCandidates] for the exact order and for why the claim only
  ///      ever sorts the list rather than filtering it.
  ///
  /// ## The bit is a hint, the `cmap` is the truth
  ///
  /// Step 4 consults `OS/2.ulUnicodeRange` so that the face most likely to have
  /// the character is opened first instead of the four hundredth. That field is
  /// **the manufacturer's claim** and real fonts get it wrong in both
  /// directions - the DejaVu Sans in this repository's own test fixtures claims
  /// the Thai bit and has no Thai glyph at all. So it decides only what order to
  /// look in, and every candidate is confirmed through
  /// [Typeface.coversCodePoint] before it is returned.
  ///
  /// ## Budget
  ///
  /// The scan stops after [maxFallbackOpens] files. A character in no installed
  /// font would otherwise open and parse every font on the machine, once, to
  /// prove it - and would then be asked again for the next character. Hitting
  /// the budget is reported as [FontFallbackStep.budgetExhausted] rather than
  /// as "not found", because the two call for different fixes.
  ///
  /// ## Caching
  ///
  /// The answer is cached per `(starting face, script, code point)` and reused
  /// for the life of the registry, so a paragraph of Japanese searches once and
  /// then costs a map lookup per character. Registering a face or overriding
  /// the interface face clears the cache, since either can change the answer.
  /// [script] does not steer coverage - the code point does - it selects the
  /// preference list in step 3, which is why it is part of the key.
  FallbackResolution resolveCodePoint(
    int codePoint, {
    Script? script,
    Typeface? from,
  }) {
    _fallbackQueries++;
    final Typeface? start = from ?? uiTypeface;
    final Map<int, FallbackResolution> cache =
        _fallbackCache[start] ??= <int, FallbackResolution>{};
    // One integer key rather than a record, because this is called per
    // character of every non-Latin run and a record key allocates.
    final int key = _cacheKey(script, codePoint);
    final FallbackResolution? cached = cache[key];
    if (cached != null) return cached;

    _fallbackMisses++;
    final FallbackResolution resolved = _search1(codePoint, script, start);
    cache[key] = resolved;
    return resolved;
  }

  static int _cacheKey(Script? script, int codePoint) =>
      ((script == null ? 0 : script.index + 1) << 21) | (codePoint & 0x1FFFFF);

  FallbackResolution _search1(int codePoint, Script? script, Typeface? start) {
    int examined = 0;

    if (start != null) {
      final int glyph = start.glyphForCodePoint(codePoint);
      if (glyph != notdefGlyph) {
        return FallbackResolution(
          face: start,
          glyph: glyph,
          step: FontFallbackStep.requested,
          facesExamined: 0,
        );
      }
    }

    // Step 2: the rest of the starting face's family.
    final String? family = start?.familyName;
    if (family != null) {
      for (final SystemFontFace candidate in _plausibleIn(family, codePoint)) {
        final ({Typeface face, int glyph})? hit =
            _tryFace(candidate, codePoint);
        examined++;
        if (hit != null) {
          return FallbackResolution(
            face: hit.face,
            glyph: hit.glyph,
            step: FontFallbackStep.family,
            facesExamined: examined,
          );
        }
      }
    }

    // Step 3: the families this platform draws the script in.
    final Script resolvedScript = script ?? scriptOf(codePoint);
    for (final String preferred in fallbackFamiliesFor(resolvedScript)) {
      for (final SystemFontFace candidate
          in _plausibleIn(preferred, codePoint)) {
        final ({Typeface face, int glyph})? hit =
            _tryFace(candidate, codePoint);
        examined++;
        if (hit != null) {
          return FallbackResolution(
            face: hit.face,
            glyph: hit.glyph,
            step: FontFallbackStep.scriptPreference,
            facesExamined: examined,
          );
        }
      }
    }

    // Step 4: the coverage scan, cheapest filter first.
    int opens = 0;
    for (final SystemFontFace candidate in _coverageCandidates(codePoint)) {
      if (opens >= maxFallbackOpens) {
        return FallbackResolution(
          face: null,
          glyph: notdefGlyph,
          step: FontFallbackStep.budgetExhausted,
          facesExamined: examined,
        );
      }
      // A face already parsed costs nothing and does not count against the
      // budget, which is a budget on *file reads*.
      if (!_opened.containsKey(candidate.key)) opens++;
      examined++;
      final ({Typeface face, int glyph})? hit = _tryFace(candidate, codePoint);
      if (hit != null) {
        return FallbackResolution(
          face: hit.face,
          glyph: hit.glyph,
          step: FontFallbackStep.coverageScan,
          facesExamined: examined,
        );
      }
    }

    return FallbackResolution(
      face: null,
      glyph: notdefGlyph,
      step: FontFallbackStep.none,
      facesExamined: examined,
    );
  }

  /// Opens [candidate] and asks its `cmap`. Null when it cannot draw the
  /// character - or cannot be parsed at all.
  ({Typeface face, int glyph})? _tryFace(
    SystemFontFace candidate,
    int codePoint,
  ) {
    final Typeface? face = open(candidate);
    if (face == null) return null;
    final int glyph = face.glyphForCodePoint(codePoint);
    if (glyph == notdefGlyph) return null;
    return (face: face, glyph: glyph);
  }

  /// The faces of [family] worth *opening* for [codePoint].
  ///
  /// Steps 2 and 3 of the chain walk named families, and a family can be large:
  /// Segoe UI ships twelve faces, and opening all twelve to discover that none
  /// of them has a Han ideograph costs a second of file reads before the search
  /// has even reached the font that does. So a face whose `OS/2` claims a
  /// coverage summary that does **not** include this character's block is
  /// skipped here.
  ///
  /// This is the one place the claim is allowed to exclude rather than only to
  /// order, and it is safe for a stated reason: nothing is lost, because step 4
  /// ends with an unfiltered tail over the whole index. A face wrongly skipped
  /// here is still reached, just later - which is exactly the right trade for a
  /// step whose entire purpose is to be fast.
  ///
  /// Faces that claim nothing at all - no `OS/2` - are never skipped, and
  /// neither is anything when the character has no range bit.
  Iterable<SystemFontFace> _plausibleIn(String family, int codePoint) sync* {
    final UnicodeRange? range = Os2Table.rangeForCodePoint(codePoint);
    final int bit = range?.bit ?? (codePoint > 0xFFFF ? 57 : -1);
    for (final SystemFontFace face in _familyCandidates(family)) {
      if (bit < 0 || face.coverage.isEmpty || face.coverage.hasBit(bit)) {
        yield face;
      }
    }
  }

  /// Registered faces of [family] first, then the machine's.
  Iterable<SystemFontFace> _familyCandidates(String family) sync* {
    final String key = SystemFontIndex.normalizeFamily(family);
    for (final SystemFontFace face in _registeredFaces) {
      if (SystemFontIndex.normalizeFamily(face.family) == key) yield face;
    }
    yield* systemFonts.facesFor(family);
  }

  /// Every candidate face for [codePoint], most likely first.
  ///
  /// **The coverage bit orders this list; it never shortens it.** That is the
  /// whole design of the filter and it is worth being exact about, because the
  /// tempting version - drop the faces that do not claim the bit - is wrong in
  /// both directions:
  ///
  ///   * a face may claim a block it does not have. DejaVu Sans claims the Thai
  ///     bit and has no Thai glyph, so a filter that *selected* on the bit would
  ///     hand back a face full of `.notdef`. That is why every candidate is
  ///     confirmed through `cmap`;
  ///   * a face may have a character it does not claim. The bit table stopped
  ///     tracking Unicode in 2008, so emoji, and every script encoded since,
  ///     land in no bit at all - and a filter that *excluded* on the bit would
  ///     declare a perfectly good emoji font unable to draw 🙂.
  ///
  /// So the order is: registered faces first, whatever they claim, because an
  /// application that shipped a font meant it to be used; then the indexed faces
  /// that claim the character's range bit; then those that claim nothing, which
  /// is what a face without `OS/2` looks like; then everything else. Above the
  /// BMP the bit used is 57, "Non-Plane 0", which is precisely the claim "I have
  /// supplementary-plane coverage".
  ///
  /// The tail is what makes the search complete and [maxFallbackOpens] is what
  /// keeps it affordable.
  Iterable<SystemFontFace> _coverageCandidates(int codePoint) sync* {
    yield* _registeredFaces;

    final UnicodeRange? range = Os2Table.rangeForCodePoint(codePoint);
    final int bit = range?.bit ?? (codePoint > 0xFFFF ? 57 : -1);
    final List<SystemFontFace> unclaimed = <SystemFontFace>[];
    final List<SystemFontFace> rest = <SystemFontFace>[];
    for (final SystemFontFace face in systemFonts.faces) {
      if (bit >= 0 && face.coverage.hasBit(bit)) {
        yield face;
      } else if (face.coverage.isEmpty) {
        unclaimed.add(face);
      } else {
        rest.add(face);
      }
    }
    yield* unclaimed;
    yield* rest;
  }

  /// How many font files one fallback search may open. See
  /// [resolveCodePoint].
  static const int maxFallbackOpens = 48;

  /// The families this platform draws [script] in, in preference order.
  ///
  /// Hard-coded per platform because nothing in a font says "I am what this
  /// system draws Japanese in" - that is a property of the platform, not of the
  /// file, and the alternative to naming them is picking whichever font
  /// happened to be enumerated first, which is how an application ends up
  /// rendering a Japanese menu in a decorative brush face.
  ///
  /// Names that are not installed simply do not match, so listing several
  /// generations of each platform's default is free: a Windows 8 machine has
  /// Meiryo where a Windows 11 one has Yu Gothic, and both are named.
  ///
  /// Every list ends implicitly in the coverage scan, so a script with no entry
  /// here - and most of the 160-odd in [Script] have none - is still resolved,
  /// just more slowly.
  ///
  /// **Only the Windows lists have been executed.** The macOS and Linux ones
  /// are written from those platforms' shipped font sets.
  static List<String> fallbackFamiliesFor(Script script) {
    final List<String> generic = _genericFallbacks[script] ?? const <String>[];
    if (Platform.isWindows) {
      return <String>[...?_windowsFallbacks[script], ...generic];
    }
    if (Platform.isMacOS) {
      return <String>[...?_macFallbacks[script], ...generic];
    }
    return <String>[...?_linuxFallbacks[script], ...generic];
  }

  /// The Noto families, which are named the same way on every platform that
  /// installs them and are increasingly the answer everywhere.
  static const Map<Script, List<String>> _genericFallbacks =
      <Script, List<String>>{
    Script.arab: <String>['Noto Sans Arabic', 'Noto Naskh Arabic'],
    Script.hebr: <String>['Noto Sans Hebrew'],
    Script.hani: <String>[
      'Noto Sans SC',
      'Noto Sans TC',
      'Noto Sans JP',
      'Noto Sans KR',
    ],
    Script.hira: <String>['Noto Sans JP'],
    Script.kana: <String>['Noto Sans JP'],
    Script.hang: <String>['Noto Sans KR'],
    Script.thai: <String>['Noto Sans Thai'],
    Script.deva: <String>['Noto Sans Devanagari'],
    Script.beng: <String>['Noto Sans Bengali'],
    Script.taml: <String>['Noto Sans Tamil'],
    Script.grek: <String>['Noto Sans'],
    Script.cyrl: <String>['Noto Sans'],
  };

  static const Map<Script, List<String>> _windowsFallbacks =
      <Script, List<String>>{
    Script.arab: <String>['Segoe UI', 'Tahoma', 'Arial'],
    Script.hebr: <String>['Segoe UI', 'Tahoma'],
    Script.hani: <String>[
      'Microsoft YaHei',
      'Microsoft JhengHei',
      'SimSun',
      'Yu Gothic',
      'MS Gothic',
      'Malgun Gothic',
    ],
    Script.hira: <String>['Yu Gothic', 'Meiryo', 'MS Gothic'],
    Script.kana: <String>['Yu Gothic', 'Meiryo', 'MS Gothic'],
    Script.hang: <String>['Malgun Gothic', 'Gulim'],
    Script.thai: <String>['Leelawadee UI', 'Tahoma'],
    Script.deva: <String>['Nirmala UI'],
    Script.beng: <String>['Nirmala UI'],
    Script.taml: <String>['Nirmala UI'],
    Script.geor: <String>['Sylfaen'],
    Script.armn: <String>['Sylfaen'],
    Script.ethi: <String>['Ebrima'],
    Script.zyyy: <String>['Segoe UI', 'Segoe UI Symbol', 'Segoe UI Emoji'],
  };

  static const Map<Script, List<String>> _macFallbacks = <Script, List<String>>{
    Script.arab: <String>['Geeza Pro', 'Al Bayan'],
    Script.hebr: <String>['Arial Hebrew'],
    Script.hani: <String>['PingFang SC', 'PingFang TC', 'Hiragino Sans'],
    Script.hira: <String>['Hiragino Sans', 'Hiragino Kaku Gothic ProN'],
    Script.kana: <String>['Hiragino Sans', 'Hiragino Kaku Gothic ProN'],
    Script.hang: <String>['Apple SD Gothic Neo'],
    Script.thai: <String>['Thonburi'],
    Script.deva: <String>['Kohinoor Devanagari', 'Devanagari MT'],
    Script.zyyy: <String>['Apple Color Emoji', 'Apple Symbols'],
  };

  static const Map<Script, List<String>> _linuxFallbacks =
      <Script, List<String>>{
    Script.arab: <String>['DejaVu Sans', 'Liberation Sans'],
    Script.hebr: <String>['DejaVu Sans'],
    Script.hani: <String>['Source Han Sans', 'WenQuanYi Zen Hei'],
    Script.hira: <String>['Source Han Sans', 'IPAGothic'],
    Script.kana: <String>['Source Han Sans', 'IPAGothic'],
    Script.hang: <String>['Source Han Sans', 'NanumGothic'],
    Script.zyyy: <String>['Noto Color Emoji', 'DejaVu Sans'],
  };

  // --- emoji ---------------------------------------------------------------

  /// The face for an emoji [cluster], and everything about it that could not
  /// be honoured.
  ///
  /// ## What a cluster is here
  ///
  /// The string of one user-perceived emoji: a base character, optionally a
  /// variation selector, optionally several bases joined by `U+200D` ZERO WIDTH
  /// JOINER, and optionally skin-tone modifiers. The grapheme breaker produces
  /// them; this method takes one and answers which face draws it.
  ///
  /// ## Variation selectors
  ///
  /// `U+FE0E` asks for the text (monochrome) presentation and `U+FE0F` for the
  /// emoji (colour) one. A font declares which of its glyphs answer those pairs
  /// in `cmap` format 14, so the selector is honoured by asking
  /// [Typeface.glyphForVariation] **before** falling back to the plain
  /// mapping - a face that has a specific glyph for `☺ U+FE0F` is preferred
  /// over one that merely has `☺`. When no installed face declares the pair,
  /// the base glyph is used and [EmojiResolution.limitation] records that the
  /// requested presentation was not available; the selector is not silently
  /// dropped.
  ///
  /// ## Colour
  ///
  /// **This engine draws outlines and nothing else.** `COLR`/`CPAL`,
  /// `CBDT`/`CBLC` and `sbix` are not implemented, so a colour emoji face
  /// yields its monochrome base outlines, and a face whose artwork exists only
  /// as a bitmap yields an empty glyph. [EmojiResolution.drawable] and
  /// [EmojiResolution.colourTable] report which of those happened. Returning a
  /// face and letting the caller discover a row of blanks is exactly the
  /// silent-degradation failure section 6.6 forbids.
  EmojiResolution resolveEmoji(String cluster, {Script? script}) {
    final List<int> bases = <int>[];
    int selector = 0;
    bool zwj = false;
    for (final int rune in cluster.runes) {
      if (rune == 0x200D) {
        zwj = true;
        continue;
      }
      if (rune == 0xFE0E || rune == 0xFE0F) {
        selector = rune;
        continue;
      }
      bases.add(rune);
    }
    if (bases.isEmpty) {
      return const EmojiResolution(
        face: null,
        glyph: notdefGlyph,
        presentation: EmojiPresentation.unspecified,
        isZwjSequence: false,
        drawable: false,
        colourTable: null,
        limitation: 'the cluster is only joiners and selectors, so there is '
            'no character to draw',
      );
    }

    final EmojiPresentation presentation = switch (selector) {
      0xFE0E => EmojiPresentation.text,
      0xFE0F => EmojiPresentation.emoji,
      _ => EmojiPresentation.unspecified,
    };
    final int base = bases.first;

    // A face that declares the exact pair is the only one that can honour the
    // selector, so it is looked for first, across every candidate the ordinary
    // chain would consider.
    Typeface? face;
    int glyph = notdefGlyph;
    bool selectorHonoured = false;
    if (selector != 0) {
      int opens = 0;
      for (final SystemFontFace candidate in _emojiCandidates(base)) {
        // The same budget the ordinary chain uses, and for the same reason:
        // a selector nothing declares must not cost a walk over every font on
        // the machine. Falling out of this loop is not a failure - the plain
        // mapping below still answers, and the shortfall is recorded.
        if (!_opened.containsKey(candidate.key) && ++opens > maxFallbackOpens) {
          break;
        }
        final Typeface? opened = open(candidate);
        if (opened == null) continue;
        final int? variant = opened.glyphForVariation(base, selector);
        if (variant != null && variant != notdefGlyph) {
          face = opened;
          glyph = variant;
          selectorHonoured = true;
          break;
        }
      }
    }

    // The dedicated emoji families come before the ordinary chain, which is the
    // difference between 😀 in Segoe UI Emoji and 😀 in Segoe UI Symbol: both
    // have the character, and only one of them was drawn for it.
    if (face == null) {
      for (final String family in emojiFamilies()) {
        for (final SystemFontFace candidate in _familyCandidates(family)) {
          final ({Typeface face, int glyph})? hit = _tryFace(candidate, base);
          if (hit != null) {
            face = hit.face;
            glyph = hit.glyph;
            break;
          }
        }
        if (face != null) break;
      }
    }

    if (face == null) {
      final FallbackResolution resolved =
          resolveCodePoint(base, script: script ?? Script.zyyy);
      face = resolved.face;
      glyph = resolved.glyph;
    }

    if (face == null) {
      return EmojiResolution(
        face: null,
        glyph: notdefGlyph,
        presentation: presentation,
        isZwjSequence: zwj,
        drawable: false,
        colourTable: null,
        limitation: 'no installed face has U+${_hex(base)}',
      );
    }

    // Everything the answer falls short of, in the order a reader would want
    // to hear it: the sequence first, then the presentation, then colour.
    final List<String> notes = <String>[];
    for (int i = 1; i < bases.length; i++) {
      if (!face.coversCodePoint(bases[i])) {
        notes.add(
          'no single face covers the whole sequence - U+${_hex(bases[i])} is '
          'missing from ${face.familyName ?? 'the chosen face'}, so the '
          'cluster will draw as separate parts',
        );
        break;
      }
    }
    if (selector != 0 && !selectorHonoured) {
      notes.add(
        'no installed face declares a '
        '${presentation == EmojiPresentation.text ? 'text' : 'emoji'} '
        'presentation for U+${_hex(base)} in cmap format 14, so the default '
        'glyph is used',
      );
    }
    final String? colour = _colourTableOf(face);
    if (colour != null) {
      notes.add(
        '${face.familyName ?? 'the chosen face'} stores its colour artwork in '
        '"$colour", which this engine does not implement; the monochrome base '
        'outline is what will be drawn',
      );
    }
    final bool drawable = face.hasOutline(glyph);
    if (!drawable) {
      notes.add(
        'the chosen glyph has no outline at all, so nothing would appear; the '
        'artwork exists only as colour data this engine cannot read',
      );
    }

    return EmojiResolution(
      face: face,
      glyph: glyph,
      presentation: presentation,
      isZwjSequence: zwj,
      drawable: drawable,
      colourTable: colour,
      limitation: notes.isEmpty ? null : notes.join('; '),
    );
  }

  /// The families this platform keeps its emoji in, best first.
  ///
  /// Separate from [fallbackFamiliesFor] rather than folded into `Script.zyyy`
  /// because the two questions differ: a missing *punctuation* mark should not
  /// send the search into an emoji font, and a missing emoji should not be
  /// answered by the first symbol font that happens to contain a monochrome
  /// version of it. Windows ships both - Segoe UI Symbol has 😀 as an outline
  /// and Segoe UI Emoji has it as colour artwork - and only the second is what
  /// anybody means.
  ///
  /// **Only the Windows list has been executed.**
  static List<String> emojiFamilies() {
    if (Platform.isWindows) {
      return const <String>['Segoe UI Emoji', 'Segoe UI Symbol'];
    }
    if (Platform.isMacOS) {
      return const <String>['Apple Color Emoji'];
    }
    return const <String>['Noto Color Emoji', 'Noto Emoji', 'JoyPixels'];
  }

  /// Emoji-family faces first, then the ordinary coverage order.
  Iterable<SystemFontFace> _emojiCandidates(int base) sync* {
    for (final String family in emojiFamilies()) {
      yield* _familyCandidates(family);
    }
    yield* _coverageCandidates(base);
  }

  /// Which colour-glyph table [face] carries, or null. None are implemented.
  static String? _colourTableOf(Typeface face) {
    for (final String tag in const <String>['COLR', 'CBDT', 'sbix', 'SVG ']) {
      if (face.sfnt.hasTable(tag)) return tag;
    }
    return null;
  }

  static String _hex(int codePoint) =>
      codePoint.toRadixString(16).toUpperCase().padLeft(4, '0');

  /// Forgets the override, the previous search and every cached decision.
  ///
  /// A test tear-down calls this so the next test does not inherit a face it
  /// never asked for. It does **not** drop [SystemFonts.cachedIndex]: that is
  /// the machine's font list, not this registry's state, and rebuilding it per
  /// test would cost a third of a second each time.
  void reset() {
    _face = null;
    _searched = false;
    _overridden = false;
    _source = null;
    _sized.clear();
    _opened.clear();
    _registeredFaces.clear();
    _fallbackCache.clear();
    _fallbackQueries = 0;
    _fallbackMisses = 0;
    _opens = 0;
  }

  /// The first installed font that parses, or null.
  ///
  /// Resolution is by **family**, not by file name: the platform's usual
  /// interface families ([SystemFonts.defaultUiFamilies]) are tried in order,
  /// and a candidate is accepted only once its `name` table has confirmed it
  /// really is that family. `segoeui.ttf` is a hint about where Segoe UI lives,
  /// nothing more - the file may have been replaced, and on a machine that
  /// spells its files differently the hint simply misses.
  ///
  /// The hint is still used, as a *cheap first pass*: files whose name looks
  /// like the family are opened first, and only if none of them turns out to be
  /// the family does this fall back to the full index, which reads every
  /// installed font. That ordering matters - the fast path resolves Segoe UI
  /// from four files, and the slow path costs a third of a second - and it is
  /// the reason the first frame does not pay for a font enumeration.
  ///
  /// Last of all comes any font at all that parses, because a machine whose
  /// fonts are all unfamiliar should still show text.
  ///
  /// Never throws. Font discovery is filesystem work - a permission error, a
  /// dead symlink, a disconnected network drive - and none of that is a reason
  /// for an application to fail to start.
  static ({Typeface face, String source})? _searchSystemFonts() {
    const SystemFonts fonts = SystemFonts();
    final List<SystemFontFile> files;
    try {
      files = fonts.list();
    } on Object {
      return null;
    }
    if (files.isEmpty) return null;

    for (final String family in SystemFonts.defaultUiFamilies()) {
      final ({Typeface face, String source})? found =
          _familyFromFileNameHints(files, family);
      if (found != null) return found;
    }

    // Nothing on this machine spells its files the way we guessed. Pay for the
    // full index once; it is cached for the rest of the process.
    try {
      final FaceMatch? match = SystemFonts.findPreferredFamily(
        reader: readSystemFontFaces,
      );
      if (match != null) {
        final Typeface? face = _parse(match.face.path, match.face.faceIndex);
        if (face != null) {
          return (face: face, source: match.face.key);
        }
      }
    } on Object {
      // Fall through to the blunt scan below.
    }

    for (final SystemFontFile file in files.take(_maxParseAttempts)) {
      // Collections need a face index chosen for them, and a default must not
      // choose one silently.
      if (file.isCollection) continue;
      final Typeface? face = _parse(file.path, 0);
      if (face != null) return (face: face, source: file.path);
    }
    return null;
  }

  /// Opens the files whose *name* suggests [family] and returns the one whose
  /// `name` table proves it, matched to a regular upright face.
  static ({Typeface face, String source})? _familyFromFileNameHints(
    List<SystemFontFile> files,
    String family,
  ) {
    final String hint = _fileNameKey(family);
    final List<SystemFontFile> candidates = <SystemFontFile>[
      for (final SystemFontFile file in files)
        if (!file.isCollection && _fileNameKey(file.fileName).startsWith(hint))
          file,
    ];
    if (candidates.isEmpty) return null;

    final String wanted = SystemFontIndex.normalizeFamily(family);
    final List<SystemFontFace> faces = <SystemFontFace>[];
    for (final SystemFontFile file in candidates.take(_maxParseAttempts)) {
      for (final SystemFontFace face in readSystemFontFaces(file)) {
        if (SystemFontIndex.normalizeFamily(face.family) == wanted) {
          faces.add(face);
        }
      }
    }
    // The same rule the index uses, so the interface face is chosen the way
    // every other face is rather than by a second, private heuristic.
    final FaceMatch? match = SystemFontIndex.matchAmong(faces);
    if (match == null) return null;
    final Typeface? parsed = _parse(match.face.path, match.face.faceIndex);
    if (parsed == null) return null;
    return (face: parsed, source: match.face.key);
  }

  /// A file name reduced to letters and digits, so that `segoeui.ttf`,
  /// `SegoeUI.ttf` and the family "Segoe UI" all key alike.
  static String _fileNameKey(String name) {
    final StringBuffer out = StringBuffer();
    for (int i = 0; i < name.length; i++) {
      final int unit = name.codeUnitAt(i);
      final bool isDigit = unit >= 0x30 && unit <= 0x39;
      final bool isUpper = unit >= 0x41 && unit <= 0x5A;
      final bool isLower = unit >= 0x61 && unit <= 0x7A;
      if (isDigit || isLower) {
        out.writeCharCode(unit);
      } else if (isUpper) {
        out.writeCharCode(unit + 0x20);
      }
    }
    final String key = out.toString();
    // The extension is three or four letters and would otherwise make every
    // name end in "ttf", which no family does.
    for (final String extension in const <String>['ttf', 'otf', 'ttc', 'otc']) {
      if (key.endsWith(extension)) {
        return key.substring(0, key.length - extension.length);
      }
    }
    return key;
  }

  static Typeface? _parse(String path, int faceIndex) {
    try {
      return Typeface.parse(
        File(path).readAsBytesSync(),
        faceIndex: faceIndex,
      );
    } on Object {
      return null; // Unreadable or unsupported: the caller tries the next.
    }
  }

  /// How many files a failed search is allowed to open.
  ///
  /// A machine can have hundreds of font files; parsing every one of them to
  /// discover that none is usable would turn a missing font into a multi-second
  /// stall on the first frame.
  static const int _maxParseAttempts = 8;

  /// The box to reserve for [text] when [uiFont] returned null.
  ///
  /// Deliberately an estimate and deliberately not zero. Collapsing every
  /// label to nothing would reflow the whole tree - buttons become padding-only
  /// slivers, a list's rows lose their height - so a font that could not be
  /// found would look like a layout bug rather than a missing font. Reserving a
  /// plausible box keeps every other property of the frame testable and leaves
  /// exactly one visible symptom: blank text.
  ///
  /// The ratios are those of a typical sans-serif interface face: an average
  /// advance around half the em, and a line about a fifth taller than it.
  static Size estimatedSize(String text, double pixelSize) => Size(
        text.runes.length * pixelSize * 0.5,
        estimatedLineHeight(pixelSize),
      );

  /// The line height to assume with no face, so that a caller centring text
  /// vertically puts the empty box where the text would have been.
  static double estimatedLineHeight(double pixelSize) => pixelSize * 1.2;
}
