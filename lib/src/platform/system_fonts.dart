/// Finding the fonts already installed on the machine.
///
/// A UI framework cannot ship a font. Fonts are separately licensed - the ones
/// on a Windows machine are proprietary and cannot be redistributed - and even
/// where licensing allows it, bundling one means shipping megabytes to draw
/// text in a face the user did not choose. So the framework finds what is
/// installed.
///
/// This deliberately does **not** use DirectWrite, fontconfig or Core Text.
/// Each of those is a native dependency with its own initialisation, its own
/// failure modes and its own per-platform API, in exchange for a list of file
/// paths that a directory listing already provides. Reading the `name` table
/// out of the files themselves is one code path for all three platforms, needs
/// nothing installed, and is testable on any machine with a fonts folder.
///
/// What this file returns is **paths, bytes and plain values**, never parsed
/// tables. That is what keeps it in the platform layer: it knows about
/// directories and operating systems, and nothing about OpenType.
///
/// ## Why there is an index here, and why it does not parse fonts
///
/// Matching a font by *file name* is matching on something the format does not
/// define: `arialbd.ttf` and `Arial Bold.ttf` are the same face, `ARIALN.TTF`
/// is the family "Arial" at width class 3, and nothing stops a file called
/// `segoeui.ttf` from containing Comic Sans. The authoritative family lives in
/// the font's `name` table and the axes to sort it on live in `OS/2`.
///
/// Reading those is the text layer's job, and the dependency rule in section
/// 8.2 - checked by `test/architecture/layering_test.dart` - forbids `platform`
/// from importing `text`. So the split is: this file walks directories and owns
/// the *index* ([SystemFontIndex]) and the *matching rule* ([FaceMatch]), both
/// of which are arithmetic over plain integers and strings; the OpenType half
/// arrives through a [SystemFontFaceReader] the caller supplies. The one the
/// framework itself uses lives in `rendering/text/font_registry.dart`, which
/// may depend on both layers.
library;

import 'dart:io';
import 'dart:typed_data';

/// A font file found on this machine.
final class SystemFontFile {
  const SystemFontFile({required this.path, required this.fileName});

  final String path;

  /// The file's own name, which is the only thing known about a font before
  /// its `name` table is read. Useful for the heuristics below and useless for
  /// anything else - a file called `arial.ttf` is not required to contain
  /// Arial.
  final String fileName;

  /// Whether this looks like a font collection, which holds several faces.
  bool get isCollection =>
      fileName.toLowerCase().endsWith('.ttc') ||
      fileName.toLowerCase().endsWith('.otc');

  Uint8List readBytes() => File(path).readAsBytesSync();

  @override
  String toString() => 'SystemFontFile($fileName)';
}

/// The 128 coverage bits of `OS/2.ulUnicodeRange1..4`, carried as four words.
///
/// Held as raw words rather than as a set of blocks because *what a bit means*
/// is the text layer's business - the bit-to-block table lives in
/// `Os2Table.unicodeRanges` - while *whether a face claims bit 13* is a number
/// this layer can store and test without knowing that 13 is Arabic.
///
/// **A claim, not a guarantee.** The manufacturer writes these bits and nothing
/// verifies them: fonts set a bit for a block they half-cover, and subsetters
/// strip glyphs while leaving the bits behind. They exist so that font fallback
/// can skip four hundred faces with four masked reads each instead of opening
/// four hundred `cmap` tables; the face that survives the filter must still be
/// asked through its `cmap` before anything is drawn.
final class UnicodeCoverage {
  const UnicodeCoverage(this.range1, this.range2, this.range3, this.range4);

  /// A face that declared nothing - no `OS/2`, or an unreadable one.
  static const UnicodeCoverage none = UnicodeCoverage(0, 0, 0, 0);

  /// Bits 0..31, 32..63, 64..95 and 96..127 respectively.
  final int range1, range2, range3, range4;

  /// Whether the face claims bit [bit] (0..127).
  ///
  /// Out-of-range bits answer false rather than throwing: this is a filter on a
  /// scan of every installed face, and a caller that computed a bit from a code
  /// point with no assigned bit should get "not claimed", not an exception.
  bool hasBit(int bit) {
    if (bit < 0 || bit > 127) return false;
    final int word = switch (bit >> 5) {
      0 => range1,
      1 => range2,
      2 => range3,
      _ => range4,
    };
    return word & (1 << (bit & 31)) != 0;
  }

  /// Whether the face claimed nothing at all, which is what a missing `OS/2`
  /// looks like. Such a face must be tried by `cmap`, never filtered out.
  bool get isEmpty => (range1 | range2 | range3 | range4) == 0;

  @override
  String toString() => 'UnicodeCoverage(0x${range1.toRadixString(16)}, '
      '0x${range2.toRadixString(16)}, 0x${range3.toRadixString(16)}, '
      '0x${range4.toRadixString(16)})';
}

/// One face of one font file, described by the values a font manager selects
/// on.
///
/// Deliberately a snapshot of values rather than a handle to a parsed face: the
/// index holds several hundred of these for the life of the process, and a
/// parsed face is megabytes. Opening the file is the caller's decision, made
/// once a face has been *chosen*.
final class SystemFontFace {
  const SystemFontFace({
    required this.path,
    required this.faceIndex,
    required this.family,
    required this.weight,
    required this.width,
    required this.italic,
    required this.oblique,
    required this.declaresStyle,
    this.legacyFamily,
    this.subfamily,
    this.postScriptName,
    this.coverage = UnicodeCoverage.none,
  });

  final String path;

  /// Which face inside the file. Always 0 outside a `.ttc`/`.otc` collection,
  /// and the reason a collection is not skipped: on macOS most system faces
  /// only exist inside one.
  final int faceIndex;

  /// The family a user means: `name` 16 when present, else `name` 1. See the
  /// 16/17 rule on `NameTable`.
  final String family;

  /// `name` 1 exactly, when it differs from [family].
  ///
  /// Kept because it is a second, legitimate name for the same face: a user who
  /// types "Roboto Light" is naming the four-style family, and a user who types
  /// "Roboto" is naming the typographic one. The index answers both.
  final String? legacyFamily;

  /// `name` 17, else `name` 2 - "Semibold Italic" and the like.
  final String? subfamily;

  final String? postScriptName;

  /// 1..1000. 400 is Regular, 700 Bold.
  final int weight;

  /// 1..9. 1 is Ultra-condensed, 5 Normal, 9 Ultra-expanded.
  final int width;

  final bool italic;

  /// Slanted by shearing rather than drawn as a separate italic. Matching may
  /// substitute an oblique for an italic, and says so - see [FaceMatch].
  final bool oblique;

  /// Whether [weight], [width] and [italic] were *read* from `OS/2` rather than
  /// inferred from `head.macStyle`.
  ///
  /// False means the face said only "bold" and "italic" and everything else in
  /// those three fields is a default. It breaks ties in [FaceMatch] so that a
  /// face that states its weight beats one that had a weight assumed for it.
  final bool declaresStyle;

  final UnicodeCoverage coverage;

  /// A stable identity for the face inside the process: the file plus the index
  /// within it. Two entries with the same key are the same face found twice.
  String get key => faceIndex == 0 ? path : '$path#$faceIndex';

  @override
  String toString() => 'SystemFontFace($family'
      '${subfamily == null ? '' : ' $subfamily'}, w$weight, wd$width'
      '${italic ? ', italic' : ''}${oblique ? ', oblique' : ''})';
}

/// Reads every face in one font file, or returns an empty list if it cannot.
///
/// The seam that keeps OpenType out of this layer. It must **never throw**: a
/// font directory contains bitmap fonts, truncated files and formats this
/// framework does not read, and none of that is a reason for enumeration to
/// fail.
typedef SystemFontFaceReader = List<SystemFontFace> Function(
  SystemFontFile file,
);

/// The result of asking a family for the closest face to a requested style.
final class FaceMatch {
  const FaceMatch({
    required this.face,
    required this.exact,
    required this.substitutedSlant,
  });

  final SystemFontFace face;

  /// Whether weight, width and slant all matched what was asked for.
  ///
  /// False is not a failure - it is the normal answer for "Bold" in a family
  /// that ships only Regular and Black - but it is the caller's cue that
  /// synthetic emboldening or slanting may be wanted, and the reason this type
  /// exists instead of a bare face.
  final bool exact;

  /// Whether an oblique was accepted where an italic was asked for, or the
  /// reverse.
  ///
  /// Worth reporting separately because the two are not interchangeable to a
  /// typographer: a true italic is a different design with different
  /// letterforms, and an oblique is the upright sheared. A caller that must not
  /// substitute checks this.
  final bool substitutedSlant;

  @override
  String toString() => 'FaceMatch($face, exact: $exact'
      '${substitutedSlant ? ', slant substituted' : ''})';
}

/// Installed faces, grouped by family, with the CSS matching rule over them.
///
/// ## The rule, and why this one
///
/// Font matching is not "find the nearest number". CSS Fonts Level 4 §5.2
/// fixes both the *order* the axes are considered in and, for weight, a search
/// that is deliberately **not** symmetric. Every browser implements it, every
/// designer's mental model is built on it, and a framework that invents its own
/// rule produces text that is defensible and different from everything else on
/// the machine.
///
/// The axes are considered in this order, each narrowing the candidates handed
/// to the next:
///
///   1. **width** (`font-stretch`). Exact if present. Otherwise, for a
///      requested width at or below Normal, narrower widths are searched first
///      in descending order and only then wider ones ascending; for a width
///      above Normal, wider first ascending, then narrower descending. The
///      asymmetry is the point: asking for Condensed and getting Expanded is a
///      worse answer than getting Normal;
///   2. **slant** (`font-style`). Italic prefers italic, then oblique, then
///      upright; oblique prefers oblique, then italic, then upright; upright
///      prefers upright, then oblique, then italic. A slant that had to be
///      substituted is reported in [FaceMatch.substitutedSlant] rather than
///      quietly accepted;
///   3. **weight** (`font-weight`), in three regimes:
///      * **below 400**: weights at or below the request, descending; then
///        weights above it, ascending;
///      * **above 500**: weights at or above the request, ascending; then
///        weights below it, descending;
///      * **400 to 500 inclusive**: the special case. Weights from the request
///        up to 500 ascending first, then everything *below* the request
///        descending, and only then everything above 500 ascending. So a family
///        of {100, 600, 900} answers a request for 400 with **100**, not 600.
///        That looks wrong and is correct: 600 is visibly bold where 400 was
///        asked for, and a text face that is too light is a smaller error than
///        one that is too heavy.
///
/// Ties - two faces with identical axes, which happens when the same font is
/// installed system-wide and per-user - are broken in favour of the face that
/// declared its axes ([SystemFontFace.declaresStyle]) and then by index order,
/// which is directory precedence: user fonts shadow system ones.
final class SystemFontIndex {
  SystemFontIndex._(
    this.faces,
    this._byFamily, {
    required this.filesScanned,
    required this.filesRefused,
  });

  /// Every face found, in directory precedence order.
  final List<SystemFontFace> faces;

  final Map<String, List<SystemFontFace>> _byFamily;

  /// How many font files the walk opened.
  final int filesScanned;

  /// How many of those yielded no face at all - a format this framework does
  /// not read, a truncated file, an unreadable one. A large number here on a
  /// machine with fonts is the diagnostic for "why does nothing match".
  final int filesRefused;

  /// An index over nothing, for a machine with no readable font.
  static final SystemFontIndex empty = SystemFontIndex._(
    List<SystemFontFace>.unmodifiable(<SystemFontFace>[]),
    <String, List<SystemFontFace>>{},
    filesScanned: 0,
    filesRefused: 0,
  );

  /// Builds an index by reading every file in [files] through [reader].
  ///
  /// [reader] is called once per file and must not throw; see
  /// [SystemFontFaceReader].
  static SystemFontIndex build({
    required Iterable<SystemFontFile> files,
    required SystemFontFaceReader reader,
  }) {
    final List<SystemFontFace> faces = <SystemFontFace>[];
    final Map<String, List<SystemFontFace>> byFamily =
        <String, List<SystemFontFace>>{};
    final Set<String> seen = <String>{};
    int scanned = 0;
    int refused = 0;

    for (final SystemFontFile file in files) {
      scanned++;
      final List<SystemFontFace> read = reader(file);
      if (read.isEmpty) {
        refused++;
        continue;
      }
      for (final SystemFontFace face in read) {
        // The same face reachable by two paths - a per-user copy of a system
        // font - is indexed once, and the first one wins because directory
        // order puts the user's copy first.
        if (!seen.add(face.key)) continue;
        faces.add(face);
        _addAlias(byFamily, face.family, face);
        final String? legacy = face.legacyFamily;
        if (legacy != null && legacy != face.family) {
          _addAlias(byFamily, legacy, face);
        }
      }
    }

    return SystemFontIndex._(
      List<SystemFontFace>.unmodifiable(faces),
      byFamily,
      filesScanned: scanned,
      filesRefused: refused,
    );
  }

  static void _addAlias(
    Map<String, List<SystemFontFace>> into,
    String family,
    SystemFontFace face,
  ) {
    final String key = normalizeFamily(family);
    if (key.isEmpty) return;
    (into[key] ??= <SystemFontFace>[]).add(face);
  }

  /// The key a family name is looked up by: case-folded, with runs of
  /// whitespace collapsed to one space.
  ///
  /// "Segoe UI", "segoe ui" and "Segoe  UI" are one family. Punctuation is
  /// **not** stripped: "Noto Sans" and "Noto-Sans" are different names and
  /// conflating them would merge families that a foundry deliberately split.
  static String normalizeFamily(String family) {
    final StringBuffer out = StringBuffer();
    bool pendingSpace = false;
    for (int i = 0; i < family.length; i++) {
      final int unit = family.codeUnitAt(i);
      final bool isSpace = unit == 0x20 || unit == 0x09 || unit == 0x0A;
      if (isSpace) {
        pendingSpace = out.isNotEmpty;
        continue;
      }
      if (pendingSpace) {
        out.write(' ');
        pendingSpace = false;
      }
      out.writeCharCode(
        unit >= 0x41 && unit <= 0x5A ? unit + 0x20 : unit,
      );
    }
    return out.toString().toLowerCase();
  }

  /// Every distinct family name, in the spelling the fonts themselves use.
  Iterable<String> get familyNames {
    final Set<String> names = <String>{};
    for (final SystemFontFace face in faces) {
      names.add(face.family);
    }
    return names;
  }

  int get faceCount => faces.length;

  bool get isEmpty => faces.isEmpty;

  /// The faces of [family], or an empty list. Matching is by name, not by file.
  List<SystemFontFace> facesFor(String family) =>
      _byFamily[normalizeFamily(family)] ?? const <SystemFontFace>[];

  /// Whether any installed face belongs to [family].
  bool hasFamily(String family) =>
      _byFamily.containsKey(normalizeFamily(family));

  /// The closest face in [family] to the requested style, or null when the
  /// family is not installed.
  ///
  /// The rule is the one documented on this class. Note what this does **not**
  /// do: it never falls back to another family. A caller asking for "Segoe UI"
  /// and getting a face from "Arial" would be told nothing about the
  /// substitution, and section 6.6 forbids choosing a worse font silently -
  /// null is the honest answer, and the caller decides what to ask for next.
  FaceMatch? match(
    String family, {
    int weight = 400,
    int width = 5,
    bool italic = false,
    bool oblique = false,
  }) =>
      matchAmong(
        facesFor(family),
        weight: weight,
        width: width,
        italic: italic,
        oblique: oblique,
      );

  /// The CSS matching rule over an arbitrary set of faces.
  ///
  /// Exposed separately from [match] because the rule is worth testing without
  /// a font directory behind it, and because a caller with its own candidate
  /// list - a family it has already merged, a bundled set - needs the same
  /// arithmetic.
  static FaceMatch? matchAmong(
    Iterable<SystemFontFace> candidates, {
    int weight = 400,
    int width = 5,
    bool italic = false,
    bool oblique = false,
  }) {
    final List<SystemFontFace> faces = candidates.toList(growable: false);
    if (faces.isEmpty) return null;

    final List<SystemFontFace> byWidth = _narrowByWidth(faces, width);
    final ({List<SystemFontFace> faces, bool substituted}) bySlant =
        _narrowBySlant(byWidth, italic: italic, oblique: oblique);
    final SystemFontFace chosen = _narrowByWeight(bySlant.faces, weight);

    return FaceMatch(
      face: chosen,
      exact: chosen.width == width &&
          chosen.weight == weight &&
          chosen.italic == italic &&
          chosen.oblique == oblique,
      substitutedSlant: bySlant.substituted,
    );
  }

  /// Step 1: `font-stretch`. See the class doc for the direction rule.
  static List<SystemFontFace> _narrowByWidth(
    List<SystemFontFace> faces,
    int width,
  ) {
    final Set<int> widths = <int>{
      for (final SystemFontFace face in faces) face.width,
    };
    if (widths.contains(width)) return _withWidth(faces, width);

    final List<int> narrower = widths.where((int w) => w < width).toList()
      ..sort((int a, int b) => b.compareTo(a));
    final List<int> wider = widths.where((int w) => w > width).toList()..sort();
    // At or below Normal: prefer narrower. Above Normal: prefer wider. Asking
    // for Condensed and being handed Expanded is the worst available answer.
    final List<int> order = width <= 5
        ? <int>[...narrower, ...wider]
        : <int>[...wider, ...narrower];
    return _withWidth(faces, order.first);
  }

  static List<SystemFontFace> _withWidth(
    List<SystemFontFace> faces,
    int width,
  ) =>
      <SystemFontFace>[
        for (final SystemFontFace face in faces)
          if (face.width == width) face,
      ];

  /// Step 2: `font-style`, with the substitution reported rather than hidden.
  static ({List<SystemFontFace> faces, bool substituted}) _narrowBySlant(
    List<SystemFontFace> faces, {
    required bool italic,
    required bool oblique,
  }) {
    List<SystemFontFace> take(bool Function(SystemFontFace) test) =>
        <SystemFontFace>[
          for (final SystemFontFace face in faces)
            if (test(face)) face,
        ];

    bool isUpright(SystemFontFace f) => !f.italic && !f.oblique;
    bool isTrueItalic(SystemFontFace f) => f.italic && !f.oblique;
    bool isOblique(SystemFontFace f) => f.oblique;

    // Each request has an ordered preference over the three kinds, and only the
    // first non-empty one is used. `substituted` is true when the kind that
    // answered is not the kind that was asked for - which upright never is,
    // since asking for upright and getting upright is the whole preference.
    final List<({bool Function(SystemFontFace) test, bool substituted})> order;
    if (italic) {
      order = <({bool Function(SystemFontFace) test, bool substituted})>[
        (test: isTrueItalic, substituted: false),
        (test: isOblique, substituted: true),
        (test: isUpright, substituted: true),
      ];
    } else if (oblique) {
      order = <({bool Function(SystemFontFace) test, bool substituted})>[
        (test: isOblique, substituted: false),
        (test: isTrueItalic, substituted: true),
        (test: isUpright, substituted: true),
      ];
    } else {
      order = <({bool Function(SystemFontFace) test, bool substituted})>[
        (test: isUpright, substituted: false),
        (test: isOblique, substituted: true),
        (test: isTrueItalic, substituted: true),
      ];
    }

    for (final ({bool Function(SystemFontFace) test, bool substituted}) step
        in order) {
      final List<SystemFontFace> kept = take(step.test);
      if (kept.isNotEmpty) {
        return (faces: kept, substituted: step.substituted);
      }
    }
    return (faces: faces, substituted: false);
  }

  /// Step 3: `font-weight`, in the three regimes documented on the class.
  static SystemFontFace _narrowByWeight(
    List<SystemFontFace> faces,
    int weight,
  ) {
    SystemFontFace? best;
    int bestRank = 1 << 30;
    for (final SystemFontFace face in faces) {
      final int rank = _weightRank(face.weight, weight);
      if (best == null ||
          rank < bestRank ||
          // Ties: a face that read its axes beats one that had them inferred.
          (rank == bestRank && face.declaresStyle && !best.declaresStyle)) {
        best = face;
        bestRank = rank;
      }
    }
    return best!;
  }

  /// How bad a substitution [available] is for [wanted]. Lower is better.
  ///
  /// The three ranges below are disjoint, so a candidate from an earlier tier
  /// always beats one from a later tier however far away it is; within a tier
  /// the nearer weight wins. 1000 is the widest possible gap between two legal
  /// weight classes, which is what makes the tiers 1000 apart.
  static int _weightRank(int available, int wanted) {
    if (available == wanted) return 0;
    if (wanted >= 400 && wanted <= 500) {
      // The 400..500 special case, in its three steps.
      if (available > wanted && available <= 500) return available - wanted;
      if (available < wanted) return 1000 + (wanted - available);
      return 2000 + (available - wanted);
    }
    if (wanted < 400) {
      if (available < wanted) return wanted - available;
      return 1000 + (available - wanted);
    }
    if (available > wanted) return available - wanted;
    return 1000 + (wanted - available);
  }

  /// Every face whose `OS/2` claims coverage bit [bit], in index order.
  ///
  /// The cheap first pass of font fallback: four masked reads per face instead
  /// of opening a `cmap`. Faces that declared **no** coverage at all are
  /// included, because "declared nothing" is not "covers nothing" - a face with
  /// no `OS/2` is invisible to this filter and would otherwise never be tried.
  /// Everything this returns is still a candidate, never an answer; see
  /// [UnicodeCoverage].
  Iterable<SystemFontFace> facesDeclaringBit(int bit) sync* {
    for (final SystemFontFace face in faces) {
      if (face.coverage.hasBit(bit) || face.coverage.isEmpty) yield face;
    }
  }

  @override
  String toString() => 'SystemFontIndex(${faces.length} faces, '
      '${_byFamily.length} family names, $filesScanned files, '
      '$filesRefused refused)';
}

/// Enumerates installed font files.
final class SystemFonts {
  const SystemFonts();

  /// Extensions worth opening. `.fon` and `.pfb` are bitmap and Type 1 fonts
  /// that this framework cannot parse, so listing them would only produce
  /// failures later.
  static const Set<String> _extensions = <String>{
    '.ttf',
    '.otf',
    '.ttc',
    '.otc',
  };

  /// The directories this platform keeps fonts in, most specific first.
  ///
  /// User directories come before system ones so that a font the user
  /// installed shadows a system font of the same name, which is what every
  /// platform's own resolution does.
  ///
  /// ## Windows
  ///
  /// `%WINDIR%\Fonts` for machine-wide fonts and
  /// `%LOCALAPPDATA%\Microsoft\Windows\Fonts` for the per-user ones a "Install
  /// for me only" produces. The registry lists both too, and is not read: it
  /// holds display names rather than families, so it would still take opening
  /// the files to know what is in them.
  ///
  /// ## Linux
  ///
  /// `$XDG_DATA_HOME/fonts` (defaulting to `~/.local/share/fonts`), the legacy
  /// `~/.fonts`, then `/usr/local/share/fonts` and `/usr/share/fonts`. Those
  /// are the directories fontconfig's stock `/etc/fonts/fonts.conf` lists, and
  /// they are hard-coded here rather than read out of it: parsing fontconfig's
  /// XML - with its includes, its `<dir>` prefixes and its selectors - is a
  /// second configuration language to implement for the sake of directories
  /// that have not changed in fifteen years. The limit that buys is stated
  /// plainly: **a font in a directory added only to `fonts.conf` is not
  /// found.**
  ///
  /// ## macOS
  ///
  /// `~/Library/Fonts`, `/Library/Fonts`, then `/System/Library/Fonts` and its
  /// `Supplemental` subdirectory, which is where most system faces have lived
  /// since Catalina. Nearly all of them are `.ttc` collections, which is why
  /// the index enumerates every face in a file rather than only the first.
  ///
  /// **Only the Windows paths have been executed.** The other two are written
  /// from the platforms' documented layouts and have no machine here to run on.
  static List<String> fontDirectories() {
    final Map<String, String> env = Platform.environment;
    if (Platform.isWindows) {
      return <String>[
        if (env['LOCALAPPDATA'] != null)
          '${env['LOCALAPPDATA']}\\Microsoft\\Windows\\Fonts',
        '${env['WINDIR'] ?? 'C:\\Windows'}\\Fonts',
      ];
    }
    if (Platform.isMacOS) {
      final String? home = env['HOME'];
      return <String>[
        if (home != null) '$home/Library/Fonts',
        '/Library/Fonts',
        // Since Catalina most system faces live here rather than in Fonts
        // itself, and they are overwhelmingly .ttc collections.
        '/System/Library/Fonts/Supplemental',
        '/System/Library/Fonts',
      ];
    }
    final String? home = env['HOME'];
    final String? xdgData = env['XDG_DATA_HOME'];
    return <String>[
      if (xdgData != null && xdgData.isNotEmpty) '$xdgData/fonts',
      if (home != null && (xdgData == null || xdgData.isEmpty))
        '$home/.local/share/fonts',
      if (home != null) '$home/.fonts',
      '/usr/local/share/fonts',
      '/usr/share/fonts',
    ];
  }

  /// Every font file found, in directory precedence order.
  ///
  /// Never throws: a directory that does not exist, or that this process may
  /// not read, is skipped. Font enumeration failing should degrade text, not
  /// prevent an application from starting.
  List<SystemFontFile> list({int maxFiles = 4096}) {
    final List<SystemFontFile> found = <SystemFontFile>[];
    for (final String directory in fontDirectories()) {
      if (found.length >= maxFiles) break;
      _collect(Directory(directory), found, maxFiles);
    }
    return found;
  }

  void _collect(Directory directory, List<SystemFontFile> into, int maxFiles) {
    if (!directory.existsSync()) return;
    final List<FileSystemEntity> entries;
    try {
      // Recursive because Linux distributions nest by foundry and by family,
      // and macOS nests too. Windows does not, and pays nothing for it.
      entries = directory.listSync(recursive: true, followLinks: false);
    } on FileSystemException {
      return; // Unreadable directory: skip it rather than fail enumeration.
    }
    for (final FileSystemEntity entry in entries) {
      if (into.length >= maxFiles) return;
      if (entry is! File) continue;
      final String name = entry.path.split(Platform.pathSeparator).last;
      final int dot = name.lastIndexOf('.');
      if (dot < 0) continue;
      if (!_extensions.contains(name.substring(dot).toLowerCase())) continue;
      into.add(SystemFontFile(path: entry.path, fileName: name));
    }
  }

  /// The first font file whose name matches one of [preferred], or any font.
  ///
  /// Matching is on the *file* name, which is a heuristic and is marked as one:
  /// the authoritative family name lives in the font's `name` table, so this
  /// finds Arial in `arial.ttf` and misses it in `Arial.ttf`, and would happily
  /// return a `segoeui.ttf` that somebody replaced with a different face.
  ///
  /// **Prefer [findPreferredFamily]**, which matches the family a font declares
  /// and is what the framework itself uses. This one is kept for the caller
  /// that has no reader to give - a bootstrap that wants *some* font file
  /// before anything can parse one - and for the diagnostic value of being able
  /// to compare the two answers.
  SystemFontFile? findPreferred({List<String>? preferred}) {
    final List<SystemFontFile> files = list();
    if (files.isEmpty) return null;

    final List<String> wanted = preferred ?? defaultUiFontNames();
    for (final String candidate in wanted) {
      final String needle = candidate.toLowerCase();
      for (final SystemFontFile file in files) {
        // Collections are skipped here: picking a face out of one needs the
        // caller to choose an index, and a default should not make that choice
        // silently.
        if (file.isCollection) continue;
        if (file.fileName.toLowerCase() == needle) return file;
      }
    }
    for (final SystemFontFile file in files) {
      if (!file.isCollection) return file;
    }
    return null;
  }

  /// The family index for this machine, built once per process.
  ///
  /// ## Why it is cached, and what invalidates it
  ///
  /// Building it opens every installed font file: 479 files and 502 faces on
  /// the Windows machine this was developed on, about 310 ms of file reads and
  /// table parsing. That is affordable once and absurd per query - a text run
  /// with three scripts in it would rebuild it three times.
  ///
  /// So the index is a **snapshot taken at first use and never refreshed**.
  /// There is no filesystem watch and no timestamp check: watching a font
  /// directory means a platform-specific notification API on each of the three
  /// operating systems, and stat-ing several hundred files to decide whether to
  /// rebuild costs a large fraction of just rebuilding. The consequence is
  /// stated rather than hidden: **a font installed after this index was built
  /// is invisible until [invalidateIndex] is called**, which is what an
  /// application should do in response to whatever font-change notification its
  /// platform gives it, and what a test does in its tear-down.
  ///
  /// [reader] is only consulted when there is no cached index. A caller that
  /// passes a different reader than the one that built the cache gets the
  /// cached index; that is deliberate - the cache is the machine's font list,
  /// not the reader's - and a test that wants a different one calls
  /// [invalidateIndex] first.
  static SystemFontIndex cachedIndex({
    required SystemFontFaceReader reader,
    int maxFiles = 4096,
  }) =>
      _cachedIndex ??= SystemFontIndex.build(
        files: const SystemFonts().list(maxFiles: maxFiles),
        reader: reader,
      );

  static SystemFontIndex? _cachedIndex;

  /// Whether [cachedIndex] has already paid for a scan.
  static bool get hasCachedIndex => _cachedIndex != null;

  /// Drops the cached index so the next [cachedIndex] rebuilds it.
  ///
  /// The only invalidation there is - see [cachedIndex] for why it is manual.
  static void invalidateIndex() => _cachedIndex = null;

  /// The best installed face for the platform's interface font, or null.
  ///
  /// Matching is by **family**, through [SystemFontIndex]: asking for "Segoe
  /// UI" finds the face whose `name` table says Segoe UI, whatever the file is
  /// called, and finds it inside a `.ttc` collection too. The families are
  /// tried in order and the first one installed wins, so a machine missing the
  /// first choice degrades to the next *named* choice rather than to whatever
  /// file the directory listing happened to return first.
  ///
  /// Contrast [findPreferred], which matches file names and is kept only for
  /// callers that cannot supply a reader.
  static FaceMatch? findPreferredFamily({
    required SystemFontFaceReader reader,
    List<String>? families,
    int weight = 400,
    int width = 5,
    bool italic = false,
  }) {
    final SystemFontIndex index = cachedIndex(reader: reader);
    for (final String family in families ?? defaultUiFamilies()) {
      final FaceMatch? match = index.match(
        family,
        weight: weight,
        width: width,
        italic: italic,
      );
      if (match != null) return match;
    }
    return null;
  }

  /// The *family names* of each platform's usual interface font, best first.
  ///
  /// These are names out of a `name` table, not file names: "Segoe UI" is what
  /// `segoeui.ttf`, `seguisb.ttf` and every other file in that family agree
  /// they are called, and a machine that ships the family under different file
  /// names still matches.
  ///
  /// The Linux list is the usual metric-compatible substitutes plus the two
  /// families almost every distribution installs. Which one is present varies
  /// by distribution, which is exactly why several are named.
  static List<String> defaultUiFamilies() {
    if (Platform.isWindows) {
      return <String>['Segoe UI', 'Tahoma', 'Arial', 'Verdana'];
    }
    if (Platform.isMacOS) {
      return <String>[
        // The system UI family since Catalina, then the two that predate it.
        'SF Pro Text',
        '.SF NS Text',
        'Helvetica Neue',
        'Helvetica',
      ];
    }
    return <String>[
      'DejaVu Sans',
      'Liberation Sans',
      'Noto Sans',
      'Ubuntu',
      'Cantarell',
    ];
  }

  /// File names of each platform's usual interface font, best first.
  ///
  /// These are the faces the platform itself draws its own UI in, so text
  /// rendered with them looks native by default. They are also all
  /// TrueType-outline fonts, which is what the parser reads today.
  static List<String> defaultUiFontNames() {
    if (Platform.isWindows) {
      return <String>['segoeui.ttf', 'tahoma.ttf', 'arial.ttf', 'verdana.ttf'];
    }
    if (Platform.isMacOS) {
      return <String>['SFNSText.ttf', 'Helvetica.ttf', 'Geneva.ttf'];
    }
    return <String>[
      'DejaVuSans.ttf',
      'LiberationSans-Regular.ttf',
      'NotoSans-Regular.ttf',
      'Ubuntu-R.ttf',
    ];
  }
}
