/// Where the widget layer gets a face from.
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
/// Two rules this file exists to keep:
///
///   * **discovery never throws.** A machine with no readable font, or with a
///     font this parser cannot read, must draw no text - not fail to start.
///     Every path out of [_discover] returns null instead of propagating;
///   * **a test never depends on the machine.** [useTypeface] and
///     [useFontFile] replace whatever discovery would have found, so a golden
///     asserts on Roboto from `test/fonts/` and means the same thing on a
///     Windows box, a CI container with no fonts installed, and a Mac.
library;

import 'dart:io';
import 'dart:typed_data';

import '../../geometry/size.dart';
import '../../platform/system_fonts.dart';
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

/// Resolves the interface font, once per process.
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
  FontRegistry({FontSearch? search}) : _search = search ?? _searchSystemFonts;

  final FontSearch _search;

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

  /// One [ScaledTypeface] per size.
  ///
  /// Bounded by how many distinct sizes an application uses - a handful - and
  /// worth keeping because the glyph cache and the display list's font table
  /// both key on the scaled face, and every control asks for one per paint.
  final Map<double, ScaledTypeface> _sized = <double, ScaledTypeface>{};

  /// The interface face at [pixelSize], or null when this machine has none.
  ///
  /// Null is the honest answer and callers must handle it; see
  /// [estimatedSize] for what they should reserve when they get it.
  ScaledTypeface? uiFont(double pixelSize) {
    final Typeface? face = uiTypeface;
    if (face == null) return null;
    return _sized[pixelSize] ??= face.atSize(pixelSize);
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
  /// supported way for a test to get a deterministic one.
  void useTypeface(Typeface face, {String source = 'override'}) {
    _face = face;
    _overridden = true;
    _source = source;
    _sized.clear();
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

  /// Forgets the override and the previous search.
  ///
  /// A test tear-down calls this so the next test does not inherit a face it
  /// never asked for.
  void reset() {
    _face = null;
    _searched = false;
    _overridden = false;
    _source = null;
    _sized.clear();
  }

  /// The first installed font that parses, or null.
  ///
  /// Tries the platform's preferred interface faces first and then anything
  /// else installed, because "preferred" is a guess made from a file name:
  /// `segoeui.ttf` on a Windows machine is the right face and `arial.otf`
  /// somewhere else is a CFF font the parser refuses. A single candidate would
  /// turn either mistake into no text at all.
  ///
  /// Never throws. Font discovery is filesystem work - a permission error, a
  /// dead symlink, a disconnected network drive - and none of that is a reason
  /// for an application to fail to start.
  static ({Typeface face, String source})? _searchSystemFonts() {
    const SystemFonts fonts = SystemFonts();
    final List<SystemFontFile> candidates = <SystemFontFile>[];
    try {
      final SystemFontFile? preferred = fonts.findPreferred();
      if (preferred != null) candidates.add(preferred);
      for (final SystemFontFile file in fonts.list()) {
        // Collections need a face index chosen for them, and a default must
        // not choose one silently.
        if (file.isCollection) continue;
        if (candidates.length >= _maxParseAttempts) break;
        candidates.add(file);
      }
    } on Object {
      return null;
    }

    for (final SystemFontFile file in candidates) {
      try {
        return (face: Typeface.parse(file.readBytes()), source: file.path);
      } on Object {
        continue; // Unreadable or unsupported outline format: try the next.
      }
    }
    return null;
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
