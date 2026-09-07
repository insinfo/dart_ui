/// Turning a shaped glyph run back into characters, and getting the browser
/// to draw them in the same face this framework shaped them with.
///
/// ## This is now the fallback, not the main road
///
/// `DisplayList.drawGlyphRun` carries a font id, a paint id, an origin and a
/// list of **glyph ids**. It does not carry the string. That is exactly right
/// for a rasteriser - a glyph id is what indexes an outline - and it was the
/// single biggest obstacle to a DOM backend, because the DOM's unit of text is
/// a character and there is no way to put a glyph id into a text node.
///
/// `graphics/glyph_text.dart` closes it: an opt-in side table on `DisplayList`
/// in the shape `ContentHintSpans` established, filled by `TextPainter.emitRun`
/// from the string the shaper already had, keyed by op offset so the op and
/// float streams stay byte-for-byte identical. `DomCanvasPresenter` turns it on,
/// and `DomScene` uses it whenever a run has it.
///
/// Everything below stays because a display list built by something that never
/// asked for capture is still a legal input - a test that encodes commands by
/// hand, a list that crossed an isolate as two typed buffers, the first frame
/// after this presenter is chosen - and a backend that answered such a list
/// with no text at all would be a regression against the day this file was the
/// only road.
///
/// So this file inverts the `cmap`. That recovers the characters for every
/// glyph the font maps from exactly one code point, which is the overwhelming
/// majority of Latin, Greek and Cyrillic text. It cannot recover:
///
///   * a **ligature** - `GSUB` replaced two glyphs with one that no code point
///     maps to, so `office` shaped with an `fi` ligature comes back `oce`;
///   * a **positional form** - the initial, medial and final glyphs of an
///     Arabic letter are all substitutions, and only one of them is in `cmap`;
///   * anything reached by a **contextual substitution** at all.
///
/// Every one of those is *counted*, per run, and the count is put on the
/// element as `data-dartui-unresolved`. A backend that silently dropped them
/// would produce text that looks right, copies wrong, and searches wrong -
/// which is worse than one that is visibly incomplete.
///
/// ## The half of it that turned out to be recoverable
///
/// The first run of these tests against Roboto came back with `findable`
/// spelled with U+FB01: not a dropped character, but the `fi` ligature the
/// shaper had formed, which Roboto's `cmap` does map from LATIN SMALL LIGATURE
/// FI. Visually identical, and wrong for every purpose a DOM backend exists to
/// serve - Ctrl+F for "find" would not match it, and neither would a copy-paste
/// into a search box.
///
/// Unicode has exactly the answer for this and the framework already carries
/// it: `text/normalize.dart` implements NFKC, and NFKC of that ligature is the
/// two letters. It is applied **per code point and only inside the
/// presentation-form blocks**, never to the string as a whole. Wholesale NFKC
/// is lossy in ways that matter here - a superscript two becomes a plain two, a
/// vulgar fraction becomes three characters - and rewriting a superscript
/// because a ligature needed fixing would be a worse bug than the one being
/// fixed. Restricting it to U+FB00..U+FDFF and U+FE70..U+FEFF hits every glyph
/// a `GSUB` substitution can have produced and nothing else.
///
/// This closes the ligature case *for a face that maps the presentation form*.
/// It does not close the general one: a font whose ligature glyph has no `cmap`
/// entry at all, or whose substitution has no Unicode presentation form, is
/// still unnameable, and that is what the count is for. Neither limit applies
/// to a run whose text the display list recorded, which is why that is the
/// path taken first.
///
/// ## Why the browser needs the font file a second time
///
/// `web_fonts.dart` fetches a `.ttf` and hands the *bytes* to
/// `FontRegistry`, because this framework parses and rasterises outlines
/// itself. The browser is never told. That is fine for a canvas backend and
/// fatal here: a `<span>` styled `font-family: Roboto` falls back to whatever
/// the machine has, so the DOM text would be laid out in a different face from
/// the one the framework measured with, and every advance would disagree.
///
/// So [DomFontRegistry] registers the same bytes with the browser through the
/// CSS Font Loading API, under a *private* family name derived from the
/// typeface's identity. Private because the point is to name this exact file:
/// `Roboto` might already mean something else on the page, and matching by the
/// name table is how you end up rendering in a face that merely shares a name.
///
/// ## Why the metrics come back out of the browser
///
/// A glyph run's origin is its **baseline**, and CSS has no way to position an
/// element by its baseline. Placing a span by its top requires the ascent the
/// browser will use, and that is not necessarily the ascent
/// `ScaledTypeface.ascent` reports: `VerticalMetrics.resolve` picks between
/// `hhea`, `OS/2` typo and `OS/2` win metrics by a documented rule, and a
/// browser picks by its own. Guessing produces text that sits one or two
/// pixels off its box on some fonts and not others, which reads as a layout
/// bug in the framework.
///
/// [DomFontRegistry.metricsFor] asks the browser instead, through
/// `TextMetrics.fontBoundingBoxAscent` on a 2D canvas, and caches per CSS font
/// string. The `line-height` is then set to `ascent + descent` so that the
/// half-leading is zero and the baseline lands exactly `ascent` below the
/// element's top edge - which makes the placement arithmetic exact rather than
/// approximately right.
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../../../text/normalize.dart';
import '../../../text/typeface.dart';

/// Where the browser's own idea of a face's line box lives.
///
/// [ascent] and [descent] are pixels from the baseline, both positive.
typedef DomFontMetrics = ({double ascent, double descent});

/// One glyph run, resolved back to text.
typedef ResolvedGlyphText = ({String text, int unresolved});

/// The browser-side half of a typeface: a CSS family name and a reverse
/// `cmap`.
///
/// One per [Typeface], created on first use and never released. That is
/// deliberate rather than a leak: a `FontFace` added to `document.fonts`
/// cannot be un-added without invalidating every element still styled with it,
/// and a framework loads a handful of faces for the life of a page.
final class DomTypeface {
  DomTypeface._(
    this.typeface,
    this.cssFamily,
    this._glyphToCodePoint,
    this._glyphToText,
  );

  final Typeface typeface;

  /// The `font-family` value that names *this file* and no other.
  final String cssFamily;

  /// Glyph id to code point, for the glyphs `cmap` maps.
  ///
  /// A `Map` rather than an `Int32List` of `maxp.numGlyphs` entries because
  /// the table is sparse in practice - a face with 3000 glyphs typically maps
  /// fewer than half of them from a code point, and the rest are ligatures,
  /// alternates and marks that this table would only ever answer -1 for.
  final Map<int, int> _glyphToCodePoint;

  /// The few glyphs whose code point is a presentation form, and the plain
  /// spelling they stand for.
  ///
  /// A second, tiny table rather than turning the one above into
  /// `Map<int, String>`, because a face maps thousands of glyphs and a
  /// handful of them are ligatures: paying one `String` object per mapped
  /// glyph to spell a dozen of them correctly is the wrong trade in a table
  /// built per face.
  final Map<int, String> _glyphToText;

  /// The characters [glyphIds] stood for, and how many could not be named.
  ///
  /// The unresolved count is returned rather than logged because the caller -
  /// [DomScene] - puts it on the element, and a diagnostic that is visible in
  /// the DOM is one a test can assert on.
  ResolvedGlyphText textOf(Int32List glyphIds, int count) {
    final StringBuffer buffer = StringBuffer();
    int unresolved = 0;
    for (int i = 0; i < count; i++) {
      final int glyph = glyphIds[i];
      final String? expansion = _glyphToText[glyph];
      if (expansion != null) {
        buffer.write(expansion);
        continue;
      }
      final int? codePoint = _glyphToCodePoint[glyph];
      if (codePoint == null) {
        unresolved++;
        continue;
      }
      buffer.writeCharCode(codePoint);
    }
    return (text: buffer.toString(), unresolved: unresolved);
  }
}

/// Faces this page has told the browser about.
///
/// A singleton because `document.fonts` is one per document and a second
/// registry would register the same bytes twice under two names, which shows
/// up as a page that downloads nothing and still doubles its font memory.
final class DomFontRegistry {
  DomFontRegistry._();

  static final DomFontRegistry instance = DomFontRegistry._();

  /// Keyed by identity: two `Typeface` objects parsed from the same bytes are
  /// two faces as far as `ScaledTypeface` is concerned - its `==` compares
  /// `identical(typeface, ...)` - so this table has to agree with it or a
  /// second parse of the same file would silently share the first one's CSS
  /// family and its reverse map.
  final Map<Typeface, DomTypeface> _faces =
      Map<Typeface, DomTypeface>.identity();

  final Map<String, DomFontMetrics> _metrics = <String, DomFontMetrics>{};

  int _nextFamilyId = 0;

  web.CanvasRenderingContext2D? _measureContext;

  /// How many faces have been handed to the browser. For diagnostics and for
  /// the tests, which assert that a second `present` registers nothing new.
  int get registeredFaceCount => _faces.length;

  /// The browser-side face for [typeface], registering it on first sight.
  ///
  /// Registration is fire-and-forget: `FontFace.load()` returns a promise and
  /// nothing here awaits it. Awaiting would mean a `present` that yields, and
  /// the first frame after a font loads would be the one that yields - which
  /// is the frame most likely to be racing a resize. The cost of not awaiting
  /// is that the very first frame after registration may lay text out in a
  /// fallback face; the browser then reflows it, and because every span is
  /// absolutely positioned by this backend, the reflow moves nothing.
  DomTypeface faceFor(Typeface typeface) {
    final DomTypeface? existing = _faces[typeface];
    if (existing != null) return existing;

    final String family = 'dartui-${_nextFamilyId++}';
    final Map<int, int> reverse = _invertCmap(typeface);
    final DomTypeface face = DomTypeface._(
      typeface,
      family,
      reverse,
      _expandPresentationForms(reverse),
    );
    _faces[typeface] = face;

    final Uint8List bytes = typeface.sfnt.data.bytes;
    try {
      final web.FontFace fontFace = web.FontFace(family, bytes.toJS);
      web.document.fonts.add(fontFace);
      fontFace.load();
    } on Object {
      // Swallowed on purpose and only here. A browser that refuses the bytes
      // - an unsupported flavour, a security policy - leaves the family
      // unresolvable, and every span styled with it falls back to the generic
      // family in the stack. That is a page with the wrong face, which is bad;
      // a page that threw out of `present` is a blank page, which is worse.
      // The condition is observable through `registeredFaceCount` against the
      // document's own `fonts.check`.
    }
    return face;
  }

  /// The browser's ascent and descent for [cssFont], a full CSS `font`
  /// shorthand such as `16px "dartui-0", sans-serif`.
  ///
  /// Falls back to a 0.8/0.2 split of the pixel size when the browser does not
  /// report font bounding boxes. That fallback is wrong by a pixel or two and
  /// is still the right answer: the alternative is text at y=0.
  DomFontMetrics metricsFor(String cssFont, double pixelSize) {
    final DomFontMetrics? cached = _metrics[cssFont];
    if (cached != null) return cached;

    DomFontMetrics resolved = (
      ascent: pixelSize * 0.8,
      descent: pixelSize * 0.2,
    );
    final web.CanvasRenderingContext2D? context = _context();
    if (context != null) {
      context.font = cssFont;
      final web.TextMetrics metrics = context.measureText('Hg');
      final double ascent = metrics.fontBoundingBoxAscent;
      final double descent = metrics.fontBoundingBoxDescent;
      // Both can be zero on a face the browser has not finished loading, and
      // a zero line box would collapse every span onto y=0. Keeping the
      // fallback in that case - rather than caching the zero - is what makes
      // the *next* frame correct instead of permanently wrong.
      if (ascent > 0 && descent >= 0) {
        resolved = (ascent: ascent, descent: descent);
        _metrics[cssFont] = resolved;
      }
      return resolved;
    }
    _metrics[cssFont] = resolved;
    return resolved;
  }

  web.CanvasRenderingContext2D? _context() {
    final web.CanvasRenderingContext2D? existing = _measureContext;
    if (existing != null) return existing;
    // Detached: never appended to the document, so it is never laid out or
    // composited. 1x1 because nothing is ever drawn into it - `measureText`
    // does not touch the backing store.
    final web.HTMLCanvasElement canvas =
        web.document.createElement('canvas') as web.HTMLCanvasElement;
    canvas
      ..width = 1
      ..height = 1;
    final web.CanvasRenderingContext2D? context =
        canvas.getContext('2d') as web.CanvasRenderingContext2D?;
    _measureContext = context;
    return context;
  }

  /// Visible for tests, which need a registry that has forgotten the faces a
  /// previous test registered. Does **not** remove anything from
  /// `document.fonts`; see [DomTypeface] on why that is not reversible.
  void resetForTesting() {
    _faces.clear();
    _metrics.clear();
  }
}

/// Builds the glyph-to-code-point table by walking the `cmap` forwards.
///
/// Forwards, because that is the only direction the table can be read: a
/// `CharacterMap` answers `glyphFor(codePoint)` and enumerates its code
/// points, and nothing in the format indexes the other way.
///
/// The **lowest** code point wins a collision. Fonts routinely map several code
/// points to one glyph - U+0020 and U+00A0 both to `space`, U+002D and U+2010
/// both to `hyphen` - and picking the lowest picks the ASCII spelling, which is
/// the one a user searching the page will type.
Map<int, int> _invertCmap(Typeface typeface) {
  final Map<int, int> table = <int, int>{};
  for (final int codePoint in typeface.cmap.characterMap.codePoints) {
    final int glyph = typeface.cmap.glyphFor(codePoint);
    if (glyph == 0) continue;
    final int? existing = table[glyph];
    if (existing == null || codePoint < existing) {
      table[glyph] = codePoint;
    }
  }
  return table;
}

/// The subset of [reverse] whose code points are presentation forms, mapped to
/// the plain text NFKC says they stand for.
///
/// The three blocks are the whole of what a `GSUB` substitution can land in:
/// U+FB00..U+FB4F is the Latin, Armenian and Hebrew ligatures, and
/// U+FB50..U+FDFF plus U+FE70..U+FEFF are the Arabic initial, medial, final and
/// isolated forms. Everything outside them is left exactly as the font mapped
/// it - see the library comment on why applying NFKC to the whole string is a
/// worse bug than the one it fixes.
///
/// An expansion is only kept when NFKC actually changes the character. Some
/// code points in these blocks - the Hebrew points, an Arabic form with no
/// compatibility mapping - normalise to themselves, and storing those would put
/// an entry in the fast path's way for no gain.
Map<int, String> _expandPresentationForms(Map<int, int> reverse) {
  final Map<int, String> expansions = <int, String>{};
  for (final MapEntry<int, int> entry in reverse.entries) {
    final int codePoint = entry.value;
    final bool isPresentationForm =
        (codePoint >= 0xFB00 && codePoint <= 0xFDFF) ||
            (codePoint >= 0xFE70 && codePoint <= 0xFEFF);
    if (!isPresentationForm) continue;
    final String original = String.fromCharCode(codePoint);
    final String plain = nfkc(original);
    if (plain == original) continue;
    expansions[entry.key] = plain;
  }
  return expansions;
}
