// ignore_for_file: avoid_print

/// Generates the packed Unicode property tables under `lib/src/text/tables/`.
///
/// Three files in `lib/src/text/` - `bidi.dart`, `grapheme.dart` and
/// `line_break.dart` - each carry a string literal whose comment says
/// "generated from UCD 17.0.0". Until this tool existed, that sentence was not
/// checkable by anyone: the tables were correct, but nothing in the repository
/// could say *how* they had been derived, so a Unicode version bump meant
/// re-deriving them by hand and hoping. This tool is the missing half.
///
/// It does two jobs.
///
///  1. It **writes** the tables that had no source at all: Script and
///     Script_Extensions, Joining_Type and Joining_Group, Word_Break,
///     normalization data, case mappings, the Indic categories, Vertical
///     Orientation, and mirroring and paired brackets.
///
///  2. It **verifies**, under `--verify-existing`, that the tables already
///     committed in `bidi.dart`, `grapheme.dart` and `line_break.dart` are
///     byte-for-byte what this tool would produce from the same UCD file. It
///     deliberately cannot rewrite them: those files belong to their annexes,
///     the enum order they encode is part of their public API, and a generator
///     that could silently re-lay them out is a generator that can silently
///     re-label every character in the code space. Verification either passes
///     or prints the divergence and exits non-zero.
///
/// ## The source
///
/// `referencias/unicode/ucd.nounihan.flat.xml`, the flat XML view of the
/// Unicode Character Database, rather than the individual `.txt` files. The
/// flat XML is the *derived* view: the `@missing` block defaults are already
/// applied to every code point, including unassigned ones, so nothing here has
/// to re-derive Joining_Type=T for combining marks or Script=Zzzz for reserved
/// code points and get one wrong. The file also covers U+0000..U+10FFFF with no
/// holes, which is what lets every range table below be total.
///
/// It is 67 MB, so it is read as a line stream and matched with a regular
/// expression rather than parsed into a DOM. Every `<char>`, `<reserved>`,
/// `<noncharacter>` and `<surrogate>` element opens on its own line with all of
/// its attributes on that line, which is what makes that safe; the parser
/// checks that the elements it saw tile the code space exactly and throws if
/// they did not, so a future file that breaks the assumption fails loudly
/// instead of producing a table with a hole in it.
///
/// ## Usage
///
/// ```
/// dart run tool/generate_unicode_tables.dart
/// dart run tool/generate_unicode_tables.dart --verify-existing
/// dart run tool/generate_unicode_tables.dart --ucd <path> --out <dir>
/// ```
library;

import 'dart:convert';
import 'dart:io';

/// The Unicode version this run is expected to read, checked against the
/// `<description>` element so a swapped-in file of another version cannot be
/// generated from silently.
const String _expectedUcdVersion = '17.0.0';

const String _defaultUcdPath = 'referencias/unicode/ucd.nounihan.flat.xml';
const String _defaultOutDir = 'lib/src/text/tables';
const String _regenerateCommand = 'dart run tool/generate_unicode_tables.dart';

/// Hangul syllables, which are excluded from the decomposition pool.
///
/// The block holds 11172 code points and every one of them has a canonical
/// decomposition, which would be two thirds of the entire normalization table
/// for data that UAX #15 defines arithmetically. The generator checks every one
/// of them against the arithmetic instead, and the generated lookup computes
/// them. See [_hangulDecomposition].
const int _hangulSyllableBase = 0xAC00;
const int _hangulLeadBase = 0x1100;
const int _hangulVowelBase = 0x1161;
const int _hangulTrailBase = 0x11A7;
const int _hangulVowelCount = 21;
const int _hangulTrailCount = 28;
const int _hangulSyllableCount = 11172;

Future<void> main(List<String> args) async {
  final _Options options;
  try {
    options = _Options.parse(args);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln(
      'usage: $_regenerateCommand [--ucd <path>] [--out <dir>] '
      '[--verify-existing]',
    );
    exitCode = 2;
    return;
  }

  final _Ucd ucd = await _Ucd.read(options.ucdPath);
  print(
    'read ${ucd.elements} elements covering ${ucd.codePoints} code points '
    'from UCD ${ucd.version}',
  );

  if (options.verifyExisting) {
    exitCode = _verifyExisting(ucd) ? 0 : 1;
    return;
  }

  final Directory out = Directory(options.outDir);
  if (!out.existsSync()) out.createSync(recursive: true);
  final Map<String, String> files = _renderAll(ucd);
  files.forEach((String name, String source) {
    final File file = File('${options.outDir}/$name');
    file.writeAsStringSync(source);
    print('wrote ${file.path} (${source.length} bytes)');
  });
}

// ---------------------------------------------------------------------------
// Command line
// ---------------------------------------------------------------------------

final class _Options {
  _Options(this.ucdPath, this.outDir, this.verifyExisting);

  factory _Options.parse(List<String> args) {
    String ucdPath = _defaultUcdPath;
    String outDir = _defaultOutDir;
    bool verify = false;
    for (int i = 0; i < args.length; i++) {
      switch (args[i]) {
        case '--ucd':
          if (++i == args.length) {
            throw const FormatException('--ucd needs a path');
          }
          ucdPath = args[i];
        case '--out':
          if (++i == args.length) {
            throw const FormatException('--out needs a path');
          }
          outDir = args[i];
        case '--verify-existing':
          verify = true;
        default:
          throw FormatException('unknown argument: ${args[i]}');
      }
    }
    return _Options(ucdPath, outDir, verify);
  }

  final String ucdPath;
  final String outDir;
  final bool verifyExisting;
}

// ---------------------------------------------------------------------------
// Packing
// ---------------------------------------------------------------------------

const String _base64 =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

/// Appends [value] as a little-end-first varint, five payload bits per
/// character with the sixth set on every character but the last.
void _writeVarint(StringBuffer out, int value) {
  if (value < 0) {
    throw ArgumentError.value(value, 'value', 'varints are unsigned');
  }
  int remaining = value;
  while (true) {
    final int chunk = remaining & 31;
    remaining >>= 5;
    if (remaining == 0) {
      out.write(_base64[chunk]);
      return;
    }
    out.write(_base64[chunk | 32]);
  }
}

/// Maps a signed number onto the naturals so it can be a varint.
int _zigzag(int value) => value >= 0 ? value << 1 : (-value << 1) - 1;

/// Accumulates one run-length coded property over the whole code space.
///
/// [add] must be called with ascending, contiguous ranges: the builder throws
/// on a gap or an overlap rather than papering over it, because a table with a
/// hole in it decodes without complaint and answers wrongly for every code
/// point in the hole.
final class _RunBuilder<T> {
  _RunBuilder(this.property);

  final String property;
  final List<int> starts = <int>[];
  final List<T> values = <T>[];
  int _expected = 0;

  void add(int first, int last, T value) {
    if (first != _expected) {
      throw StateError(
        '$property: expected U+${_hex(_expected)} but the UCD gave '
        'U+${_hex(first)}..U+${_hex(last)}',
      );
    }
    _expected = last + 1;
    if (values.isEmpty || values.last != value) {
      starts.add(first);
      values.add(value);
    }
  }

  void finish() {
    if (_expected != 0x110000) {
      throw StateError(
        '$property: coverage stops at U+${_hex(_expected)}, not U+110000',
      );
    }
  }

  int get runs => starts.length;

  /// The set of distinct values, in first-seen order.
  Set<T> get distinct => values.toSet();

  String encode(int Function(T) indexOf) {
    final StringBuffer out = StringBuffer();
    int previous = 0;
    for (int i = 0; i < starts.length; i++) {
      _writeVarint(out, starts[i] - previous);
      previous = starts[i];
      _writeVarint(out, indexOf(values[i]));
    }
    return out.toString();
  }
}

/// Accumulates a sparse code-point-to-code-point property.
final class _SparseBuilder {
  _SparseBuilder(this.property);

  final String property;
  final List<int> keys = <int>[];
  final List<int> values = <int>[];

  void add(int key, int value) {
    if (keys.isNotEmpty && key <= keys.last) {
      throw StateError('$property: keys must ascend');
    }
    keys.add(key);
    values.add(value);
  }

  int get entries => keys.length;

  String encode() {
    final StringBuffer out = StringBuffer();
    int previous = 0;
    for (int i = 0; i < keys.length; i++) {
      _writeVarint(out, keys[i] - previous);
      previous = keys[i];
      _writeVarint(out, _zigzag(values[i] - keys[i]));
    }
    return out.toString();
  }
}

/// Accumulates a sparse code-point-to-sequence property.
final class _PoolBuilder {
  _PoolBuilder(this.property);

  final String property;
  final List<int> keys = <int>[];
  final List<List<int>> values = <List<int>>[];

  void add(int key, List<int> value) {
    if (keys.isNotEmpty && key <= keys.last) {
      throw StateError('$property: keys must ascend');
    }
    keys.add(key);
    values.add(value);
  }

  int get entries => keys.length;

  String encode() {
    int pooled = 0;
    for (final List<int> value in values) {
      pooled += value.length;
    }
    final StringBuffer out = StringBuffer();
    _writeVarint(out, keys.length);
    _writeVarint(out, pooled);
    int previous = 0;
    for (int i = 0; i < keys.length; i++) {
      _writeVarint(out, keys[i] - previous);
      previous = keys[i];
      _writeVarint(out, values[i].length);
      for (final int component in values[i]) {
        _writeVarint(out, _zigzag(component - keys[i]));
      }
    }
    return out.toString();
  }
}

String _hex(int codePoint) =>
    codePoint.toRadixString(16).toUpperCase().padLeft(4, '0');

// ---------------------------------------------------------------------------
// Property value vocabularies
// ---------------------------------------------------------------------------

/// One member of a generated enum: its UCD alias, its Dart name and its doc.
final class _Value {
  const _Value(this.alias, this.member, [this.doc = '']);

  final String alias;
  final String member;
  final String doc;
}

/// Turns a UCD long alias into a Dart identifier: `Consonant_With_Stacker`
/// becomes `consonantWithStacker`, `NA` becomes `na`.
String _camel(String alias) {
  final List<String> parts = alias.split('_');
  final StringBuffer out = StringBuffer(parts.first.toLowerCase());
  for (int i = 1; i < parts.length; i++) {
    final String part = parts[i].toLowerCase();
    out.write(part[0].toUpperCase());
    out.write(part.substring(1));
  }
  return out.toString();
}

const List<_Value> _joiningTypeValues = <_Value>[
  _Value('U', 'nonJoining', 'Joins to nothing on either side.'),
  _Value(
    'T',
    'transparent',
    'Invisible to joining: the shaper looks straight through it to the\n'
        'characters on either side. Combining marks and most format\n'
        'characters.',
  ),
  _Value(
    'C',
    'joinCausing',
    'Forces its neighbours into their joined forms without taking one\n'
        'itself. U+200D ZERO WIDTH JOINER and U+0640 ARABIC TATWEEL.',
  ),
  _Value('D', 'dualJoining', 'Joins on both sides, like ARABIC LETTER BEH.'),
  _Value('L', 'leftJoining', 'Joins only on its left.'),
  _Value(
    'R',
    'rightJoining',
    'Joins only on its right, like ARABIC LETTER ALEF - which is why an\n'
        'alef in the middle of a word breaks the connection after it.',
  ),
];

const List<_Value> _wordBreakValues = <_Value>[
  _Value('XX', 'other', 'Anything the rules do not name.'),
  _Value('CR', 'cr', 'U+000D.'),
  _Value('LF', 'lf', 'U+000A.'),
  _Value('NL', 'newline', 'U+000B, U+000C, U+0085, U+2028, U+2029.'),
  _Value('Extend', 'extend', 'Grapheme_Extend, which never starts a word.'),
  _Value('ZWJ', 'zwj', 'U+200D.'),
  _Value('FO', 'format', 'Format characters other than ZWJ and ZWNJ.'),
  _Value('RI', 'regionalIndicator', 'One half of a flag.'),
  _Value('KA', 'katakana', 'Katakana, which words together as a block.'),
  _Value(
    'HL',
    'hebrewLetter',
    'Hebrew letters, separated from ALetter for the single quote rules\n'
        'WB7a and WB7b - Hebrew uses U+0027 inside words.',
  ),
  _Value('LE', 'aLetter', 'Ordinary word-forming letters.'),
  _Value('SQ', 'singleQuote', 'U+0027.'),
  _Value('DQ', 'doubleQuote', 'U+0022.'),
  _Value('MB', 'midNumLet', 'Joins letters and numbers alike, like U+002E.'),
  _Value('ML', 'midLetter', 'Joins letters only, like U+00B7.'),
  _Value('MN', 'midNum', 'Joins numbers only, like U+002C.'),
  _Value('NU', 'numeric', 'Digits.'),
  _Value('EX', 'extendNumLet', 'U+005F and friends, which glue words.'),
  _Value(
      'WSegSpace', 'wSegSpace', 'Ordinary space, which WB3d keeps together.'),
];

const List<_Value> _decompositionTypeValues = <_Value>[
  _Value('none', 'none', 'No decomposition.'),
  _Value(
    'can',
    'canonical',
    'Canonical: the decomposition is equivalent to the character, and NFC\n'
        '/// and NFD both use it.',
  ),
  _Value('com', 'compat', 'Otherwise unspecified compatibility.'),
  _Value('enc', 'circle', 'Encircled form.'),
  _Value('fin', 'finalForm', 'Arabic final presentation form.'),
  _Value('font', 'font', 'Font variant.'),
  _Value('fra', 'fraction', 'Vulgar fraction.'),
  _Value('init', 'initialForm', 'Arabic initial presentation form.'),
  _Value('iso', 'isolatedForm', 'Arabic isolated presentation form.'),
  _Value('med', 'medialForm', 'Arabic medial presentation form.'),
  _Value('nar', 'narrow', 'Narrow (halfwidth) form.'),
  _Value('nb', 'noBreak', 'Non-breaking form, like U+00A0.'),
  _Value('sml', 'small', 'CNS small form variant.'),
  _Value('sqr', 'square', 'CJK squared form.'),
  _Value('sub', 'subscript', 'Subscript form.'),
  _Value('sup', 'superscript', 'Superscript form.'),
  _Value('vert', 'vertical', 'Vertical layout form.'),
  _Value('wide', 'wide', 'Wide (fullwidth) form.'),
];

const List<_Value> _quickCheckValues = <_Value>[
  _Value('Y', 'yes', 'Already in this normalization form.'),
  _Value('N', 'no', 'Not in this form, and normalizing will change it.'),
  _Value(
    'M',
    'maybe',
    'Depends on what precedes it: a combining character that may or may\n'
        'not compose with its base. Only NFC and NFKC produce this.',
  ),
];

const List<_Value> _verticalOrientationValues = <_Value>[
  _Value('U', 'upright', 'Drawn upright in vertical text.'),
  _Value('R', 'rotated', 'Rotated 90 degrees clockwise in vertical text.'),
  _Value(
    'Tu',
    'transformedUpright',
    'Drawn upright after a font transformation, if the font has one;\n'
        'upright otherwise.',
  ),
  _Value(
    'Tr',
    'transformedRotated',
    'Drawn upright after a font transformation, if the font has one;\n'
        'rotated otherwise.',
  ),
];

const List<_Value> _bracketTypeValues = <_Value>[
  _Value('n', 'none', 'Not a paired bracket.'),
  _Value('o', 'open', 'An opening paired bracket.'),
  _Value('c', 'close', 'A closing paired bracket.'),
];

/// Bidi_Class in the order `bidi.dart` already encodes. Used only by
/// `--verify-existing`.
const List<String> _bidiClassOrder = <String>[
  'L', 'R', 'AL', 'EN', 'ES', 'ET', 'AN', 'CS', 'NSM', 'BN', 'B', 'S', 'WS', //
  'ON', 'LRE', 'LRO', 'RLE', 'RLO', 'PDF', 'LRI', 'RLI', 'FSI', 'PDI',
];

/// Grapheme_Cluster_Break in the order `grapheme.dart` already encodes.
const List<String> _graphemeClassOrder = <String>[
  'XX', 'CR', 'LF', 'CN', 'EX', 'ZWJ', 'RI', 'PP', 'SM', 'L', 'V', 'T', //
  'LV', 'LVT',
];

/// Indic_Conjunct_Break in the order `grapheme.dart` already encodes.
const List<String> _incbOrder = <String>[
  'None',
  'Linker',
  'Consonant',
  'Extend',
];

/// Line_Break, post-LB1, in the order `line_break.dart` already encodes.
const List<String> _lineBreakOrder = <String>[
  'AK', 'AL', 'AP', 'AS', 'B2', 'BA', 'BB', 'BK', 'CB', 'CL', 'CM', 'CP', //
  'CR', 'EB', 'EM', 'EX', 'GL', 'H2', 'H3', 'HH', 'HL', 'HY', 'ID', 'IN',
  'IS', 'JL', 'JT', 'JV', 'LF', 'NL', 'NS', 'NU', 'OP', 'PO', 'PR', 'QU',
  'RI', 'SP', 'SY', 'VF', 'VI', 'WJ', 'ZW', 'ZWJ',
];

// ---------------------------------------------------------------------------
// Reading the UCD
// ---------------------------------------------------------------------------

/// Everything the generator collects in its single pass over the XML.
final class _Ucd {
  _Ucd();

  String version = '';
  int elements = 0;
  int codePoints = 0;

  // Newly generated properties.
  final _RunBuilder<String> script = _RunBuilder<String>('sc');
  final _RunBuilder<String> scriptExtensions = _RunBuilder<String>('scx');
  final _RunBuilder<String> joiningType = _RunBuilder<String>('jt');
  final _RunBuilder<String> joiningGroup = _RunBuilder<String>('jg');
  final _RunBuilder<String> wordBreak = _RunBuilder<String>('WB');
  final _RunBuilder<int> combiningClass = _RunBuilder<int>('ccc');
  final _RunBuilder<int> normalizationFlags = _RunBuilder<int>('dt+QC');
  final _RunBuilder<String> indicSyllabic = _RunBuilder<String>('InSC');
  final _RunBuilder<String> indicPositional = _RunBuilder<String>('InPC');
  final _RunBuilder<String> verticalOrientation = _RunBuilder<String>('vo');
  final _RunBuilder<int> mirrorFlags = _RunBuilder<int>('Bidi_M+bpt');

  final _PoolBuilder decomposition = _PoolBuilder('dm');
  final _SparseBuilder simpleUpper = _SparseBuilder('suc');
  final _SparseBuilder simpleLower = _SparseBuilder('slc');
  final _SparseBuilder simpleTitle = _SparseBuilder('stc');
  final _SparseBuilder simpleFold = _SparseBuilder('scf');
  final _PoolBuilder fullUpper = _PoolBuilder('uc');
  final _PoolBuilder fullLower = _PoolBuilder('lc');
  final _PoolBuilder fullTitle = _PoolBuilder('tc');
  final _PoolBuilder fullFold = _PoolBuilder('cf');
  final _SparseBuilder mirrorGlyph = _SparseBuilder('bmg');
  final _SparseBuilder pairedBracket = _SparseBuilder('bpb');

  // Properties that already have committed tables, kept only so that
  // `--verify-existing` can re-derive them.
  final _RunBuilder<String> bidiClass = _RunBuilder<String>('bc');
  final _RunBuilder<int> graphemeFlags = _RunBuilder<int>('GCB+ExtPict+InCB');
  final _RunBuilder<String> lineBreak = _RunBuilder<String>('lb');
  final _RunBuilder<int> lineBreakFlags = _RunBuilder<int>('ea+gc+ExtPict');
  final List<int> bracketOpeners = <int>[];
  final List<int> bracketClosers = <int>[];

  static final RegExp _attribute =
      RegExp(r'([A-Za-z_][A-Za-z0-9_-]*)="([^"]*)"');
  static final RegExp _element =
      RegExp(r'^\s*<(char|reserved|noncharacter|surrogate)\s');

  static Future<_Ucd> read(String path) async {
    final File file = File(path);
    if (!file.existsSync()) {
      throw StateError(
        'no UCD at $path. The flat XML is a 67 MB download from '
        'https://www.unicode.org/Public/17.0.0/ucdxml/',
      );
    }
    final _Ucd ucd = _Ucd();
    final Stream<String> lines =
        file.openRead().transform(utf8.decoder).transform(const LineSplitter());
    await for (final String line in lines) {
      if (ucd.version.isEmpty && line.contains('<description>')) {
        final int start = line.indexOf('<description>') + 13;
        final int end = line.indexOf('</description>');
        ucd.version = line.substring(start, end).replaceFirst('Unicode ', '');
        if (ucd.version != _expectedUcdVersion) {
          throw StateError(
            'the file at $path is UCD ${ucd.version}, but this generator was '
            'written against $_expectedUcdVersion. Bumping the version means '
            'regenerating every table in one run and re-verifying the three '
            'committed ones, so it has to be deliberate: change '
            '_expectedUcdVersion.',
          );
        }
      }
      // Everything after </repertoire> is blocks, named sequences and emoji
      // sources, none of which is a per-code-point property.
      if (line.contains('</repertoire>')) break;
      if (!_element.hasMatch(line)) continue;
      ucd._consume(line);
    }
    ucd._finish();
    return ucd;
  }

  void _consume(String line) {
    final Map<String, String> a = <String, String>{};
    for (final RegExpMatch match in _attribute.allMatches(line)) {
      a[match.group(1)!] = match.group(2)!;
    }
    final int first;
    final int last;
    final String? single = a['cp'];
    if (single != null) {
      first = last = int.parse(single, radix: 16);
    } else {
      first = int.parse(a['first-cp']!, radix: 16);
      last = int.parse(a['last-cp']!, radix: 16);
    }
    elements++;
    codePoints += last - first + 1;

    final String gc = _need(a, 'gc', first);

    script.add(first, last, _need(a, 'sc', first));
    scriptExtensions.add(first, last, _need(a, 'scx', first));
    joiningType.add(first, last, _need(a, 'jt', first));
    joiningGroup.add(first, last, _need(a, 'jg', first));
    wordBreak.add(first, last, _need(a, 'WB', first));
    combiningClass.add(first, last, int.parse(_need(a, 'ccc', first)));
    indicSyllabic.add(first, last, _need(a, 'InSC', first));
    indicPositional.add(first, last, _need(a, 'InPC', first));
    verticalOrientation.add(first, last, _need(a, 'vo', first));

    normalizationFlags.add(
      first,
      last,
      _index(_decompositionTypeValues, _need(a, 'dt', first)) |
          (_need(a, 'Comp_Ex', first) == 'Y' ? 1 : 0) << 5 |
          _index(_quickCheckValues, _need(a, 'NFC_QC', first)) << 6 |
          _index(_quickCheckValues, _need(a, 'NFD_QC', first)) << 8 |
          _index(_quickCheckValues, _need(a, 'NFKC_QC', first)) << 10 |
          _index(_quickCheckValues, _need(a, 'NFKD_QC', first)) << 12,
    );

    final String bpt = _need(a, 'bpt', first);
    mirrorFlags.add(
      first,
      last,
      (_need(a, 'Bidi_M', first) == 'Y' ? 1 : 0) |
          _index(_bracketTypeValues, bpt) << 1,
    );

    bidiClass.add(first, last, _need(a, 'bc', first));
    graphemeFlags.add(
      first,
      last,
      _position(_graphemeClassOrder, _need(a, 'GCB', first)) |
          (_need(a, 'ExtPict', first) == 'Y' ? 1 : 0) << 4 |
          _position(_incbOrder, _need(a, 'InCB', first)) << 5,
    );
    lineBreak.add(first, last, _resolveLineBreak(_need(a, 'lb', first), gc));
    final String ea = _need(a, 'ea', first);
    lineBreakFlags.add(
      first,
      last,
      (ea == 'F' || ea == 'W' || ea == 'H' ? 1 : 0) |
          (_need(a, 'ExtPict', first) == 'Y' && gc == 'Cn' ? 2 : 0) |
          (gc == 'Pi' ? 4 : 0) |
          (gc == 'Pf' ? 8 : 0),
    );

    // Sparse properties only ever appear on single code points; the range
    // elements are reserved, surrogate and noncharacter blocks, which have
    // none. Assert it rather than assume it.
    if (single == null) {
      for (final String key in const <String>[
        'dm', 'uc', 'lc', 'tc', 'suc', 'slc', 'stc', 'cf', 'scf', 'bmg',
        'bpb', //
      ]) {
        final String value = a[key] ?? '#';
        if (value != '#' && value.isNotEmpty) {
          throw StateError(
            'U+${_hex(first)}..U+${_hex(last)} is a range with $key="$value"; '
            'the sparse builders assume ranges carry no mappings',
          );
        }
      }
      return;
    }
    _consumeMappings(first, a);
  }

  void _consumeMappings(int cp, Map<String, String> a) {
    final String dt = a['dt']!;
    final String dm = a['dm']!;
    if (dt == 'none') {
      if (dm != '#') {
        throw StateError('U+${_hex(cp)} has dt=none but dm="$dm"');
      }
    } else {
      final List<int> mapping = _codePoints(dm, cp);
      if (cp >= _hangulSyllableBase &&
          cp < _hangulSyllableBase + _hangulSyllableCount) {
        // Checked, then dropped: see [_hangulDecomposition].
        final List<int> expected = _hangulDecomposition(cp);
        if (dt != 'can' || !_sameList(mapping, expected)) {
          throw StateError(
            'U+${_hex(cp)} is in the Hangul syllable block but decomposes to '
            '$mapping, not the arithmetic $expected',
          );
        }
      } else {
        decomposition.add(cp, mapping);
      }
    }

    _addSimple(simpleUpper, cp, a['suc']!);
    _addSimple(simpleLower, cp, a['slc']!);
    _addSimple(simpleTitle, cp, a['stc']!);
    _addSimple(simpleFold, cp, a['scf']!);
    _addFull(fullUpper, cp, a['uc']!, _simple(a['suc']!, cp));
    _addFull(fullLower, cp, a['lc']!, _simple(a['slc']!, cp));
    _addFull(fullTitle, cp, a['tc']!, _simple(a['stc']!, cp));
    _addFull(fullFold, cp, a['cf']!, _simple(a['scf']!, cp));

    final String bmg = a['bmg']!;
    if (bmg.isNotEmpty) mirrorGlyph.add(cp, int.parse(bmg, radix: 16));

    final String bpt = a['bpt']!;
    if (bpt != 'n') {
      final int pair = int.parse(a['bpb']!, radix: 16);
      pairedBracket.add(cp, pair);
      if (bpt == 'o') {
        bracketOpeners.add(cp);
        bracketClosers.add(pair);
      }
    }
  }

  void _addSimple(_SparseBuilder builder, int cp, String value) {
    if (value == '#') return;
    builder.add(cp, int.parse(value, radix: 16));
  }

  /// The value of a simple mapping attribute: `#` means the code point itself.
  int _simple(String value, int cp) =>
      value == '#' ? cp : int.parse(value, radix: 16);

  /// Records a full mapping, unless it says nothing the simple mapping does
  /// not.
  ///
  /// The UCD sometimes spells out a full mapping that is one code point long
  /// and identical to the simple one - U+0345 has both `suc` and `uc` equal to
  /// U+0399. Keeping those would make "null means: use the simple mapping" a
  /// contract the generated accessors do not quite honour, and a caller that
  /// trusted it would be right anyway, which is the worst kind of wrong.
  void _addFull(_PoolBuilder builder, int cp, String value, int simple) {
    if (value == '#') return;
    final List<int> mapping = _codePoints(value, cp);
    if (mapping.length == 1 && mapping.first == simple) return;
    builder.add(cp, mapping);
  }

  List<int> _codePoints(String value, int cp) {
    final List<int> result = <int>[];
    for (final String part in value.split(' ')) {
      if (part.isEmpty) throw StateError('U+${_hex(cp)}: empty mapping part');
      result.add(int.parse(part, radix: 16));
    }
    return result;
  }

  String _need(Map<String, String> a, String key, int cp) {
    final String? value = a[key];
    if (value == null) {
      throw StateError('U+${_hex(cp)} has no $key attribute');
    }
    return value;
  }

  void _finish() {
    if (codePoints != 0x110000) {
      throw StateError('the UCD covered $codePoints code points, not 1114112');
    }
    for (final _RunBuilder<Object?> builder in <_RunBuilder<Object?>>[
      script, scriptExtensions, joiningType, joiningGroup, wordBreak, //
      combiningClass, normalizationFlags, indicSyllabic, indicPositional,
      verticalOrientation, mirrorFlags, bidiClass, graphemeFlags, lineBreak,
      lineBreakFlags,
    ]) {
      builder.finish();
    }
  }
}

/// LB1, applied to the raw Line_Break value.
///
/// AI, SG and XX resolve to AL, CJ to NS, and SA to CM or AL by General
/// Category. `line_break.dart` has no enum member for any of the five, which is
/// the point: a class that cannot reach the rules cannot be mishandled there.
String _resolveLineBreak(String lb, String gc) {
  switch (lb) {
    case 'AI':
    case 'SG':
    case 'XX':
      return 'AL';
    case 'CJ':
      return 'NS';
    case 'SA':
      return gc == 'Mn' || gc == 'Mc' ? 'CM' : 'AL';
    default:
      return lb;
  }
}

/// The canonical decomposition of a Hangul syllable, per UAX #15.
///
/// Single-step, like every other `dm` value in the UCD: an LVT syllable
/// decomposes into its LV syllable and its trailing jamo, not into three jamo.
/// A caller that wants the full decomposition applies this twice, which is what
/// it already has to do for every other recursive mapping.
List<int> _hangulDecomposition(int cp) {
  final int index = cp - _hangulSyllableBase;
  final int trail = index % _hangulTrailCount;
  if (trail != 0) {
    return <int>[cp - trail, _hangulTrailBase + trail];
  }
  const int block = _hangulVowelCount * _hangulTrailCount;
  return <int>[
    _hangulLeadBase + index ~/ block,
    _hangulVowelBase + index % block ~/ _hangulTrailCount,
  ];
}

bool _sameList(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

int _index(List<_Value> values, String alias) {
  for (int i = 0; i < values.length; i++) {
    if (values[i].alias == alias) return i;
  }
  throw StateError(
    'the UCD used the property value "$alias", which this generator does not '
    'know. Add it to the end of the vocabulary in '
    'tool/generate_unicode_tables.dart and regenerate everything, so the '
    'existing members keep their numbers.',
  );
}

int _position(List<String> order, String alias) {
  final int index = order.indexOf(alias);
  if (index < 0) {
    throw StateError('unknown property value "$alias"');
  }
  return index;
}

// ---------------------------------------------------------------------------
// Emitting
// ---------------------------------------------------------------------------

String _header() => '// GENERATED FILE - DO NOT EDIT.\n'
    '//\n'
    '// Source:     $_defaultUcdPath\n'
    '// UCD:        $_expectedUcdVersion\n'
    '// Regenerate: $_regenerateCommand\n'
    '\n';

/// Writes [doc] as a doc comment, one `///` line per line of text.
void _writeDoc(StringBuffer out, String doc, String indent) {
  for (final String line in doc.split('\n')) {
    if (line.isEmpty) {
      out.writeln('$indent///');
    } else {
      out.writeln('$indent/// $line');
    }
  }
}

/// Renders `const String name = '...';` the way the committed tables are laid
/// out: 70 characters of payload per line, four-space continuation indent.
String _literal(String name, String data, String doc) {
  final StringBuffer out = StringBuffer();
  _writeDoc(out, doc, '');
  // A table short enough to fit on the declaration line goes there, because
  // that is where `dart format` would put it and the generator's output has to
  // already be formatted.
  if ("const String $name = '$data';".length <= 80) {
    out.writeln("const String $name = '$data';");
    return out.toString();
  }
  out.writeln('const String $name =');
  for (int i = 0; i < data.length; i += 70) {
    final int end = i + 70 < data.length ? i + 70 : data.length;
    final bool isLast = end == data.length;
    out.writeln("    '${data.substring(i, end)}'${isLast ? ';' : ''}");
  }
  return out.toString();
}

/// Renders an enum whose members carry no payload.
String _enum(String name, String doc, List<_Value> values) {
  final StringBuffer out = StringBuffer();
  _writeDoc(out, doc, '');
  out.writeln('enum $name {');
  for (int i = 0; i < values.length; i++) {
    final _Value value = values[i];
    if (value.doc.isNotEmpty) _writeDoc(out, value.doc, '  ');
    out.write('  ${value.member}');
    out.writeln(i == values.length - 1 ? ';' : ',');
    if (i != values.length - 1) out.writeln();
  }
  out.writeln('}');
  return out.toString();
}

/// Renders an enum whose members are derived from the data rather than
/// hand-declared, so only their names are known.
String _plainEnum(String name, String doc, List<String> members) {
  final StringBuffer out = StringBuffer();
  _writeDoc(out, doc, '');
  out.writeln('enum $name {');
  for (int i = 0; i < members.length; i++) {
    out.write('  ${members[i]}');
    out.writeln(i == members.length - 1 ? ';' : ',');
  }
  out.writeln('}');
  return out.toString();
}

const String _orderWarning =
    'The member order is the one the generated table encodes. Reordering the\n'
    'members silently re-labels every code point, so the enum and the table\n'
    'are generated together and have to be regenerated together.';

Map<String, String> _renderAll(_Ucd ucd) => <String, String>{
      'script_table.dart': _renderScript(ucd),
      'joining_table.dart': _renderJoining(ucd),
      'word_break_table.dart': _renderWordBreak(ucd),
      'normalization_table.dart': _renderNormalization(ucd),
      'case_table.dart': _renderCase(ucd),
      'indic_table.dart': _renderIndic(ucd),
      'vertical_table.dart': _renderVertical(ucd),
      'mirroring_table.dart': _renderMirroring(ucd),
    };

String _renderScript(_Ucd ucd) {
  final List<String> codes = ucd.script.distinct.toList()..sort();
  final Map<String, int> indexOf = <String, int>{
    for (int i = 0; i < codes.length; i++) codes[i]: i,
  };

  // Script_Extensions is a set per code point, but only a few hundred distinct
  // sets occur and they occur in runs, so the sets are pooled and the per-code
  // point table stores an index into the pool.
  final List<String> sets = ucd.scriptExtensions.distinct.toList()..sort();
  final Map<String, int> setIndex = <String, int>{
    for (int i = 0; i < sets.length; i++) sets[i]: i,
  };
  final StringBuffer pool = StringBuffer();
  int pooled = 0;
  for (final String set in sets) {
    pooled += set.split(' ').length;
  }
  _writeVarint(pool, sets.length);
  _writeVarint(pool, pooled);
  for (final String set in sets) {
    final List<String> members = set.split(' ');
    _writeVarint(pool, members.length);
    for (final String member in members) {
      final int? index = indexOf[member];
      if (index == null) {
        throw StateError(
          'Script_Extensions names the script "$member", which never occurs as '
          'a Script value; the enum could not represent it',
        );
      }
      _writeVarint(pool, index);
    }
  }

  final StringBuffer out = StringBuffer(_header());
  out.write('''
/// Script (`sc`) and Script_Extensions (`scx`), UAX #24.
///
/// Script is what turns a string into runs a shaper can act on. Nothing else in
/// the text stack can: `cmap` says which glyphs a font has, not which language
/// system to shape them with, and a shaper handed Arabic text under the `latn`
/// script tag applies no joining and no mark positioning and draws a row of
/// disconnected isolated forms - text that is legible to no one.
///
/// ## Two properties, not one
///
/// [scriptOf] answers Script, which is a single value per code point and is
/// `Zyyy` (Common) or `Zinh` (Inherited) for everything shared between scripts:
/// digits, punctuation, most combining marks. Those two values are not answers,
/// they are "ask the context", which is why itemization in `script.dart` exists
/// at all.
///
/// [scriptExtensionsOf] answers Script_Extensions, the set of scripts a shared
/// character actually occurs in. U+0640 ARABIC TATWEEL has Script=Common but
/// Script_Extensions={Adlm, Arab, Mand, Mani, Ougr, Phlp, Rohg, Sogd, Syrc},
/// which is what lets an itemizer refuse to hand it to a Latin run. For a code
/// point whose Script is a real script the set is that one script, so the two
/// functions agree and a caller can use the set unconditionally.
///
/// ## Coverage
///
/// Total over U+0000..U+10FFFF. Unassigned code points read as `Zzzz`
/// (Unknown), which is a real value rather than a failure: an itemizer treats
/// it as its own script, so a code point assigned after $_expectedUcdVersion
/// becomes its own run and is shaped with the default script rather than being
/// silently swept into whatever ran before it.
library;

import 'packed_table.dart';

''');

  final StringBuffer members = StringBuffer();
  for (int i = 0; i < codes.length; i++) {
    members.write("  ${codes[i].toLowerCase()}('${codes[i]}')");
    members.writeln(i == codes.length - 1 ? ';' : ',');
  }
  _writeDoc(
    out,
    'A Unicode script, named by its ISO 15924 code in lower case.\n'
        '\n'
        '$_orderWarning\n'
        '\n'
        'The three values that are not scripts are spelled the same way as the\n'
        'rest: [Script.zyyy] is Common, [Script.zinh] is Inherited and\n'
        '[Script.zzzz] is Unknown.',
    '',
  );
  out.write('''
enum Script {
${members.toString().trimRight()}

  const Script(this.code);

  /// The ISO 15924 four-letter code, capitalised as the UCD writes it.
  final String code;

  /// Whether this is Common or Inherited - a value that defers to context
  /// rather than naming a script.
  bool get isContextual => this == Script.zyyy || this == Script.zinh;
}

final RangeTable _scripts = RangeTable(_scriptTable);
final RangeTable _extensionIndex = RangeTable(_scriptExtensionIndexTable);
final SetTable _extensionSets = SetTable(_extensionIndex, _scriptExtensionSets);

List<List<Script>>? _extensionCache;

/// The Script of [codePoint].
Script scriptOf(int codePoint) => Script.values[_scripts.lookup(codePoint)];

/// The Script_Extensions of [codePoint], ascending by enum index.
///
/// Never empty: a code point with no extensions of its own reports the set
/// containing its own Script. The returned list is a shared, unmodifiable view
/// and is not rebuilt per call, so this is safe to call once per character.
List<Script> scriptExtensionsOf(int codePoint) =>
    (_extensionCache ??= _buildExtensionCache())[_extensionIndex.lookup(
      codePoint,
    )];

/// Whether [script] is among the Script_Extensions of [codePoint].
///
/// A linear scan of a set that is almost always one element and never more than
/// a few dozen, which beats building a `Set` per code point.
bool hasScriptExtension(int codePoint, Script script) {
  final List<Script> set = scriptExtensionsOf(codePoint);
  for (int i = 0; i < set.length; i++) {
    if (set[i] == script) return true;
  }
  return false;
}

List<List<Script>> _buildExtensionCache() => List<List<Script>>.generate(
      _extensionSets.length,
      (int i) => List<Script>.unmodifiable(
        _extensionSets[i].map((int value) => Script.values[value]),
      ),
      growable: false,
    );

''');

  out.write(
    _literal(
      '_scriptTable',
      ucd.script.encode((String code) => indexOf[code]!),
      'Script for the whole code space. ${ucd.script.runs} runs.',
    ),
  );
  out.writeln();
  out.write(
    _literal(
      '_scriptExtensionIndexTable',
      ucd.scriptExtensions.encode((String set) => setIndex[set]!),
      'The Script_Extensions set number of every code point.\n'
          '${ucd.scriptExtensions.runs} runs over ${sets.length} distinct sets.',
    ),
  );
  out.writeln();
  out.write(
    _literal(
      '_scriptExtensionSets',
      pool.toString(),
      'The Script_Extensions sets themselves, as [Script] indices.',
    ),
  );
  return out.toString();
}

String _renderJoining(_Ucd ucd) {
  final List<String> groups = ucd.joiningGroup.distinct.toList()..sort();
  final Map<String, int> groupIndex = <String, int>{
    for (int i = 0; i < groups.length; i++) groups[i]: i,
  };

  final StringBuffer out = StringBuffer(_header());
  out.write('''
/// Joining_Type (`jt`) and Joining_Group (`jg`), the cursive-joining data.
///
/// Arabic is not written as a row of letters. Each letter has up to four
/// shapes - isolated, initial, medial, final - and which one is drawn depends
/// on whether the letters on either side join. A shaper that skips this draws
/// every letter in its isolated form, which to a reader looks roughly like
/// ENGLISH WRITTEN ENTIRELY IN CAPITALS WITH SPACES BETWEEN EVERY LETTER: not
/// wrong exactly, and completely unacceptable.
///
/// [joiningTypeOf] drives the state machine that picks the shape and then asks
/// the font's GSUB `init`/`medi`/`fina`/`isol` features for the glyph.
///
/// [joiningGroupOf] is the tie-breaker underneath it. Letters in the same
/// joining group have the same skeleton and differ only in dots - beh, teh and
/// theh are all `Beh` - and the Arabic mark-positioning and ligature rules are
/// written in terms of groups, not letters. It is also what a fallback shaper
/// needs in order to choose a shape for a letter the font does not cover.
///
/// ## Coverage and defaults
///
/// Total over U+0000..U+10FFFF, with the derived defaults already applied:
/// Joining_Type is [JoiningType.transparent] for every nonspacing mark,
/// enclosing mark and format character - so a mark between two Arabic letters
/// does not break the join - and [JoiningType.nonJoining] for everything else,
/// including every unassigned code point.
library;

import 'packed_table.dart';

''');
  out.write(
    _enum(
      'JoiningType',
      'How a character joins to its neighbours.\n\n$_orderWarning',
      _joiningTypeValues,
    ),
  );
  out.writeln();

  out.write(
    _plainEnum(
      'JoiningGroup',
      'The letter skeleton a character shares with others of its '
          'group.\n\n$_orderWarning',
      <String>[for (final String group in groups) _camel(group)],
    ),
  );
  out.write('''

final RangeTable _types = RangeTable(_joiningTypeTable);
final RangeTable _groups = RangeTable(_joiningGroupTable);

/// The Joining_Type of [codePoint].
JoiningType joiningTypeOf(int codePoint) =>
    JoiningType.values[_types.lookup(codePoint)];

/// The Joining_Group of [codePoint], [JoiningGroup.noJoiningGroup] for
/// characters that are not cursive letters.
JoiningGroup joiningGroupOf(int codePoint) =>
    JoiningGroup.values[_groups.lookup(codePoint)];

''');
  out.write(
    _literal(
      '_joiningTypeTable',
      ucd.joiningType.encode(
        (String alias) => _index(_joiningTypeValues, alias),
      ),
      'Joining_Type for the whole code space. ${ucd.joiningType.runs} runs.',
    ),
  );
  out.writeln();
  out.write(
    _literal(
      '_joiningGroupTable',
      ucd.joiningGroup.encode((String alias) => groupIndex[alias]!),
      'Joining_Group for the whole code space. ${ucd.joiningGroup.runs} runs.',
    ),
  );
  return out.toString();
}

String _renderWordBreak(_Ucd ucd) {
  final StringBuffer out = StringBuffer(_header());
  out.write('''
/// Word_Break (`WB`), the property table behind UAX #29 word segmentation.
///
/// This is the data a double-click needs, and the data `Ctrl+Left` needs, and
/// the data a spell checker needs to know where one word stops. Splitting on
/// spaces gets all three wrong the moment the text contains `don't`, `3.14`,
/// `C++` or any Japanese at all.
///
/// ## Scope
///
/// This file is the **property table only**; the WB1-WB999 rules that consume
/// it are not here. That is deliberate: the rules need a scanner with the same
/// shape as the one in `grapheme.dart`, and putting the table in first means
/// the shaper and the caret code can use Word_Break for the things it answers
/// directly - is this character a letter, a number, a Katakana - before the
/// segmenter exists.
///
/// ## Coverage
///
/// Total over U+0000..U+10FFFF. Unassigned code points read as
/// [WordBreak.other], which the rules treat as a word boundary on both sides.
library;

import 'packed_table.dart';

''');
  out.write(
    _enum(
      'WordBreak',
      'Word_Break property values, named after their UAX #29 long '
          'aliases.\n\n$_orderWarning',
      _wordBreakValues,
    ),
  );
  out.write('''

final RangeTable _wordBreaks = RangeTable(_wordBreakTable);

/// The Word_Break value of [codePoint].
WordBreak wordBreakOf(int codePoint) =>
    WordBreak.values[_wordBreaks.lookup(codePoint)];

''');
  out.write(
    _literal(
      '_wordBreakTable',
      ucd.wordBreak.encode((String alias) => _index(_wordBreakValues, alias)),
      'Word_Break for the whole code space. ${ucd.wordBreak.runs} runs.',
    ),
  );
  return out.toString();
}

String _renderNormalization(_Ucd ucd) {
  final StringBuffer out = StringBuffer(_header());
  out.write('''
/// The Unicode normalization data: decompositions, combining classes and the
/// quick-check properties, UAX #15.
///
/// Two strings that a user cannot tell apart can be different sequences of code
/// points - `é` is either U+00E9 or U+0065 U+0301 - and every comparison in a
/// text stack breaks on that: search finds nothing, a sorted list is out of
/// order, a password does not match, and a shaper looks up a glyph the font has
/// under the other spelling and falls back to tofu.
///
/// ## What this file is
///
/// The **data**, not the algorithm. There is no `normalize()` here, because a
/// normalizer is a piece of code with a canonical-ordering loop and a
/// composition step, and this file has to exist first and be testable on its
/// own. What is here is everything such a normalizer reads:
///
///  * [decompositionOf] and [decompositionTypeOf] - the `dm` and `dt`
///    properties, which is the mapping and whether it is canonical.
///  * [canonicalDecompositionOf] - the same, filtered to canonical, because
///    that is the one NFC and NFD use and mixing the two silently turns `ﬁ`
///    into `fi` in text the user did not ask to change.
///  * [combiningClassOf] - `ccc`, which drives canonical ordering.
///  * [isFullCompositionExclusion] - `Comp_Ex`, the characters that must not be
///    recomposed even though they decompose canonically.
///  * The four quick-check properties, which let a normalizer skip text that is
///    already normalized - the common case by a wide margin.
///
/// ## Hangul
///
/// The 11172 Hangul syllables all decompose canonically, and their mappings are
/// **not** in the table. UAX #15 defines them arithmetically, and storing them
/// would have made this file several times larger than every other table here
/// put together for data that is three multiplications. [decompositionOf]
/// computes them. The generator checks all 11172 against the UCD on every run,
/// so the arithmetic cannot drift from the data.
///
/// ## What is not here
///
/// The **composition** direction. The primary composites are exactly the code
/// points whose decomposition is canonical, two code points long, and not
/// composition-excluded, so everything needed to build a composition index is
/// in this file - but the index itself is a hash table, which is the
/// normalizer's business rather than the table's.
library;

import 'packed_table.dart';

''');
  out.write(
    _enum(
      'DecompositionType',
      'Decomposition_Type (`dt`): what kind of equivalence a decomposition '
          'expresses.\n\nOnly [DecompositionType.canonical] is loss-free. '
          'Every other value marks a\ncompatibility decomposition, which NFKC '
          'and NFKD apply and NFC and NFD\nmust not.\n\n$_orderWarning',
      _decompositionTypeValues,
    ),
  );
  out.writeln();
  out.write(
    _enum(
      'QuickCheck',
      'The answer to "is this code point already in normalization form X?".'
          '\n\n$_orderWarning',
      _quickCheckValues,
    ),
  );
  out.write('''

final RangeTable _combining = RangeTable(_combiningClassTable);
final RangeTable _flags = RangeTable(_normalizationFlagTable);
final PoolTable _decompositions = PoolTable(_decompositionTable);

// The flag word packs six properties that change at almost the same code
// points, so one run table and one binary search serve all six.
const int _decompositionTypeMask = 0x1F;
const int _compositionExclusionBit = 0x20;
const int _nfcQuickCheckShift = 6;
const int _nfdQuickCheckShift = 8;
const int _nfkcQuickCheckShift = 10;
const int _nfkdQuickCheckShift = 12;
const int _quickCheckMask = 0x3;

const int _hangulSyllableBase = 0xAC00;
const int _hangulLeadBase = 0x1100;
const int _hangulVowelBase = 0x1161;
const int _hangulTrailBase = 0x11A7;
const int _hangulVowelCount = 21;
const int _hangulTrailCount = 28;
const int _hangulSyllableCount = $_hangulSyllableCount;

/// The Canonical_Combining_Class of [codePoint], 0 for a starter.
///
/// The value is the raw UCD number, not an index: U+0301 COMBINING ACUTE ACCENT
/// really is 230. Canonical ordering sorts non-starters by it, so the numbers
/// themselves - not their order in some enum - are what matters.
int combiningClassOf(int codePoint) => _combining.lookup(codePoint);

/// The Decomposition_Type of [codePoint].
DecompositionType decompositionTypeOf(int codePoint) {
  if (_isHangulSyllable(codePoint)) return DecompositionType.canonical;
  return DecompositionType
      .values[_flags.lookup(codePoint) & _decompositionTypeMask];
}

/// The decomposition mapping of [codePoint], canonical or compatibility, or
/// null when it has none.
///
/// Read [decompositionTypeOf] before using the result for NFC or NFD: this
/// returns the compatibility mappings too, and applying one of those in a
/// canonical form rewrites text the caller never asked to change.
///
/// The result is a shared unmodifiable view except for Hangul syllables, where
/// it is computed and therefore fresh.
List<int>? decompositionOf(int codePoint) {
  if (_isHangulSyllable(codePoint)) return _hangulDecomposition(codePoint);
  return _decompositions.lookup(codePoint);
}

/// The decomposition mapping of [codePoint] if it is canonical, else null.
///
/// This is the one NFC and NFD use.
List<int>? canonicalDecompositionOf(int codePoint) {
  if (_isHangulSyllable(codePoint)) return _hangulDecomposition(codePoint);
  final int flags = _flags.lookup(codePoint);
  if (flags & _decompositionTypeMask != DecompositionType.canonical.index) {
    return null;
  }
  return _decompositions.lookup(codePoint);
}

/// Whether [codePoint] has Full_Composition_Exclusion.
///
/// These decompose canonically but must never be recomposed - the singleton
/// decompositions, the non-starter decompositions, and the script-specific
/// exclusions. A composer that ignores this un-normalizes the text it was asked
/// to normalize.
bool isFullCompositionExclusion(int codePoint) =>
    _flags.lookup(codePoint) & _compositionExclusionBit != 0;

/// NFC_Quick_Check for [codePoint].
QuickCheck nfcQuickCheck(int codePoint) =>
    _quickCheck(codePoint, _nfcQuickCheckShift);

/// NFD_Quick_Check for [codePoint]. Never [QuickCheck.maybe].
QuickCheck nfdQuickCheck(int codePoint) =>
    _quickCheck(codePoint, _nfdQuickCheckShift);

/// NFKC_Quick_Check for [codePoint].
QuickCheck nfkcQuickCheck(int codePoint) =>
    _quickCheck(codePoint, _nfkcQuickCheckShift);

/// NFKD_Quick_Check for [codePoint]. Never [QuickCheck.maybe].
QuickCheck nfkdQuickCheck(int codePoint) =>
    _quickCheck(codePoint, _nfkdQuickCheckShift);

QuickCheck _quickCheck(int codePoint, int shift) =>
    QuickCheck.values[_flags.lookup(codePoint) >> shift & _quickCheckMask];

bool _isHangulSyllable(int codePoint) =>
    codePoint >= _hangulSyllableBase &&
    codePoint < _hangulSyllableBase + _hangulSyllableCount;

/// The canonical decomposition of a Hangul syllable, single-step like every
/// other `dm` value: an LVT syllable gives its LV syllable and its trailing
/// jamo, not three jamo. Applying it twice gives the full decomposition, which
/// is what a normalizer already does for every other recursive mapping.
List<int> _hangulDecomposition(int codePoint) {
  final int index = codePoint - _hangulSyllableBase;
  final int trail = index % _hangulTrailCount;
  if (trail != 0) {
    return <int>[codePoint - trail, _hangulTrailBase + trail];
  }
  const int block = _hangulVowelCount * _hangulTrailCount;
  return <int>[
    _hangulLeadBase + index ~/ block,
    _hangulVowelBase + index % block ~/ _hangulTrailCount,
  ];
}

''');
  out.write(
    _literal(
      '_combiningClassTable',
      ucd.combiningClass.encode((int value) => value),
      'Canonical_Combining_Class for the whole code space, as raw UCD numbers.\n'
          '${ucd.combiningClass.runs} runs.',
    ),
  );
  out.writeln();
  out.write(
    _literal(
      '_normalizationFlagTable',
      ucd.normalizationFlags.encode((int value) => value),
      'Decomposition_Type, Full_Composition_Exclusion and the four quick-check\n'
          'properties, packed one word per run. ${ucd.normalizationFlags.runs} runs.',
    ),
  );
  out.writeln();
  out.write(
    _literal(
      '_decompositionTable',
      ucd.decomposition.encode(),
      'Decomposition mappings, Hangul excluded. '
          '${ucd.decomposition.entries} entries.',
    ),
  );
  return out.toString();
}

String _renderCase(_Ucd ucd) {
  final StringBuffer out = StringBuffer(_header());
  out.write('''
/// The Unicode case mappings: uppercase, lowercase, titlecase and case folding.
///
/// `toUpperCase` on a Dart `String` is ASCII-only in some contexts and locale
/// blind in all of them, and neither is enough for a text stack: `ß`
/// uppercases to two characters, `ǅ` has a titlecase that is neither its upper
/// nor its lower case, and case-insensitive matching is not "lowercase both
/// sides" - it is case *folding*, a third mapping that exists precisely because
/// lowercasing is not idempotent under comparison.
///
/// ## Simple and full
///
/// Every property comes in two forms. The **simple** mapping is one code point
/// to one code point, which is what a fixed-width buffer and a `cmap` lookup
/// need. The **full** mapping may be longer - `ß` uppercases to `SS`, `ﬀ` folds
/// to `ff` - and is what a correct `toUpperCase` needs.
///
/// The full accessors return null when the full mapping is the same as the
/// simple one, which is the overwhelmingly common case. That is not an oversight
/// to work around; it is the calling convention: ask [fullUppercaseOf] first
/// and fall back to [simpleUppercaseOf]. Returning a one-element list instead
/// would mean an allocation per character for every character in the language.
///
/// ## What is deliberately not here
///
/// **Conditional and locale-sensitive mappings** - `SpecialCasing.txt`. Final
/// sigma (`Σ` lowercases to `ς` at the end of a word and `σ` elsewhere),
/// Lithuanian dot retention, and the Turkish dotted and dotless I. All three
/// need context or a locale, neither of which a per-code-point table has, and a
/// table that pretended otherwise would be wrong in exactly the languages that
/// notice. A caller doing user-visible case conversion for Turkish or
/// Lithuanian must layer those rules on top of this.
///
/// **Case_Ignorable and the derived Changes_When_* properties**, which the
/// conditional rules need. They belong with the rules.
library;

import 'packed_table.dart';

final SparseTable _simpleUpper = SparseTable(_simpleUppercaseTable);
final SparseTable _simpleLower = SparseTable(_simpleLowercaseTable);
final SparseTable _simpleTitle = SparseTable(_simpleTitlecaseTable);
final SparseTable _simpleFold = SparseTable(_simpleCaseFoldingTable);
final PoolTable _fullUpper = PoolTable(_fullUppercaseTable);
final PoolTable _fullLower = PoolTable(_fullLowercaseTable);
final PoolTable _fullTitle = PoolTable(_fullTitlecaseTable);
final PoolTable _fullFold = PoolTable(_fullCaseFoldingTable);

/// Simple_Uppercase_Mapping: the single code point [codePoint] uppercases to,
/// or [codePoint] itself when it has no uppercase.
int simpleUppercaseOf(int codePoint) =>
    _simpleUpper.lookup(codePoint, orElse: codePoint);

/// Simple_Lowercase_Mapping, or [codePoint] itself.
int simpleLowercaseOf(int codePoint) =>
    _simpleLower.lookup(codePoint, orElse: codePoint);

/// Simple_Titlecase_Mapping, or [codePoint] itself.
///
/// Not the same as the uppercase for the digraphs: U+01C4 `Ǆ` uppercases to
/// itself and titlecases to U+01C5 `ǅ`.
int simpleTitlecaseOf(int codePoint) =>
    _simpleTitle.lookup(codePoint, orElse: codePoint);

/// Simple_Case_Folding, or [codePoint] itself.
///
/// The mapping to use for case-insensitive comparison when the result has to
/// stay the same length as the input.
int simpleCaseFoldingOf(int codePoint) =>
    _simpleFold.lookup(codePoint, orElse: codePoint);

/// Uppercase_Mapping when it differs from [simpleUppercaseOf], else null.
List<int>? fullUppercaseOf(int codePoint) => _fullUpper.lookup(codePoint);

/// Lowercase_Mapping when it differs from [simpleLowercaseOf], else null.
List<int>? fullLowercaseOf(int codePoint) => _fullLower.lookup(codePoint);

/// Titlecase_Mapping when it differs from [simpleTitlecaseOf], else null.
List<int>? fullTitlecaseOf(int codePoint) => _fullTitle.lookup(codePoint);

/// Case_Folding when it differs from [simpleCaseFoldingOf], else null.
List<int>? fullCaseFoldingOf(int codePoint) => _fullFold.lookup(codePoint);

''');
  out.write(
    _literal(
      '_simpleUppercaseTable',
      ucd.simpleUpper.encode(),
      'Simple_Uppercase_Mapping. ${ucd.simpleUpper.entries} entries.',
    ),
  );
  out.writeln();
  out.write(
    _literal(
      '_simpleLowercaseTable',
      ucd.simpleLower.encode(),
      'Simple_Lowercase_Mapping. ${ucd.simpleLower.entries} entries.',
    ),
  );
  out.writeln();
  out.write(
    _literal(
      '_simpleTitlecaseTable',
      ucd.simpleTitle.encode(),
      'Simple_Titlecase_Mapping. ${ucd.simpleTitle.entries} entries.',
    ),
  );
  out.writeln();
  out.write(
    _literal(
      '_simpleCaseFoldingTable',
      ucd.simpleFold.encode(),
      'Simple_Case_Folding. ${ucd.simpleFold.entries} entries.',
    ),
  );
  out.writeln();
  out.write(
    _literal(
      '_fullUppercaseTable',
      ucd.fullUpper.encode(),
      'Uppercase_Mapping, only where it differs from the simple mapping.\n'
          '${ucd.fullUpper.entries} entries.',
    ),
  );
  out.writeln();
  out.write(
    _literal(
      '_fullLowercaseTable',
      ucd.fullLower.encode(),
      'Lowercase_Mapping, only where it differs from the simple mapping.\n'
          '${ucd.fullLower.entries} entries.',
    ),
  );
  out.writeln();
  out.write(
    _literal(
      '_fullTitlecaseTable',
      ucd.fullTitle.encode(),
      'Titlecase_Mapping, only where it differs from the simple mapping.\n'
          '${ucd.fullTitle.entries} entries.',
    ),
  );
  out.writeln();
  out.write(
    _literal(
      '_fullCaseFoldingTable',
      ucd.fullFold.encode(),
      'Case_Folding, only where it differs from the simple mapping.\n'
          '${ucd.fullFold.entries} entries.',
    ),
  );
  return out.toString();
}

String _renderIndic(_Ucd ucd) {
  final List<String> syllabic = ucd.indicSyllabic.distinct.toList()..sort();
  final List<String> positional = ucd.indicPositional.distinct.toList()..sort();
  final Map<String, int> syllabicIndex = <String, int>{
    for (int i = 0; i < syllabic.length; i++) syllabic[i]: i,
  };
  final Map<String, int> positionalIndex = <String, int>{
    for (int i = 0; i < positional.length; i++) positional[i]: i,
  };

  final StringBuffer out = StringBuffer(_header());
  out.write('''
/// Indic_Syllabic_Category (`InSC`) and Indic_Positional_Category (`InPC`).
///
/// Devanagari, Bengali, Tamil, Khmer, Myanmar and their relatives are not
/// written in logical order. A vowel sign stored *after* its consonant is drawn
/// *before* it - U+093F DEVANAGARI VOWEL SIGN I is the standard example - and a
/// virama between two consonants asks for a conjunct glyph that replaces both.
/// A shaper that hands these to the font in logical order produces text that is
/// unreadable rather than merely ugly, and no amount of GSUB fixes it, because
/// the reordering has to happen before the font is consulted.
///
/// These two properties are what the reordering is written against.
/// [indicSyllabicCategoryOf] says what a character *is* - consonant, vowel
/// sign, virama, nukta - and [indicPositionalCategoryOf] says where it is drawn
/// relative to its base, which is what decides where it moves to.
///
/// ## Scope
///
/// The **properties**, not the shaper. The Indic shaping engines are per-script
/// state machines that consume these values along with GSUB features, and they
/// belong next to the shaper. This file is what they read.
///
/// ## Coverage
///
/// Total over U+0000..U+10FFFF. Everything outside the Brahmic scripts reads as
/// [IndicSyllabicCategory.other] and [IndicPositionalCategory.na].
library;

import 'packed_table.dart';

''');

  out.write(
    _plainEnum(
      'IndicSyllabicCategory',
      'What a character is, in Brahmic terms.\n\n$_orderWarning',
      <String>[for (final String value in syllabic) _camel(value)],
    ),
  );
  out.writeln();
  out.write(
    _plainEnum(
      'IndicPositionalCategory',
      'Where a dependent character is drawn relative to its base.\n'
          '\n'
          '[IndicPositionalCategory.na] means the question does not apply,\n'
          'which is the value of every character outside the Brahmic '
          'scripts.\n'
          '\n$_orderWarning',
      <String>[for (final String value in positional) _camel(value)],
    ),
  );
  out.write('''

final RangeTable _syllabic = RangeTable(_indicSyllabicTable);
final RangeTable _positional = RangeTable(_indicPositionalTable);

/// The Indic_Syllabic_Category of [codePoint].
IndicSyllabicCategory indicSyllabicCategoryOf(int codePoint) =>
    IndicSyllabicCategory.values[_syllabic.lookup(codePoint)];

/// The Indic_Positional_Category of [codePoint].
IndicPositionalCategory indicPositionalCategoryOf(int codePoint) =>
    IndicPositionalCategory.values[_positional.lookup(codePoint)];

''');
  out.write(
    _literal(
      '_indicSyllabicTable',
      ucd.indicSyllabic.encode((String alias) => syllabicIndex[alias]!),
      'Indic_Syllabic_Category for the whole code space. '
          '${ucd.indicSyllabic.runs} runs.',
    ),
  );
  out.writeln();
  out.write(
    _literal(
      '_indicPositionalTable',
      ucd.indicPositional.encode((String alias) => positionalIndex[alias]!),
      'Indic_Positional_Category for the whole code space. '
          '${ucd.indicPositional.runs} runs.',
    ),
  );
  return out.toString();
}

String _renderVertical(_Ucd ucd) {
  final StringBuffer out = StringBuffer(_header());
  out.write('''
/// Vertical_Orientation (`vo`), UAX #50.
///
/// Japanese, Chinese and Mongolian text can run top to bottom, and when it
/// does, not every character turns with it. Ideographs stay upright; Latin
/// words rotate ninety degrees clockwise; some brackets and dashes are replaced
/// by rotated forms from the font's `vert` feature. Getting this wrong gives
/// vertical text with sideways kana or upright Latin, which is the visual
/// equivalent of a mirrored Arabic paragraph.
///
/// [verticalOrientationOf] is the per-character half of that decision. The
/// other half is the font: [VerticalOrientation.transformedUpright] and
/// [VerticalOrientation.transformedRotated] both mean "use the glyph the `vert`
/// or `vrt2` feature substitutes, if the font has one", and only the fallback
/// differs. A layout with no vertical writing mode never asks.
///
/// ## Coverage
///
/// Total over U+0000..U+10FFFF, with the block defaults already applied - which
/// matters here, because the default is [VerticalOrientation.rotated] for most
/// of the code space but [VerticalOrientation.upright] inside the CJK, Yi and
/// vertical-forms blocks, including their unassigned code points.
library;

import 'packed_table.dart';

''');
  out.write(
    _enum(
      'VerticalOrientation',
      'How a character is drawn when the line runs top to '
          'bottom.\n\n$_orderWarning',
      _verticalOrientationValues,
    ),
  );
  out.write('''

final RangeTable _orientations = RangeTable(_verticalOrientationTable);

/// The Vertical_Orientation of [codePoint].
VerticalOrientation verticalOrientationOf(int codePoint) =>
    VerticalOrientation.values[_orientations.lookup(codePoint)];

''');
  out.write(
    _literal(
      '_verticalOrientationTable',
      ucd.verticalOrientation.encode(
        (String alias) => _index(_verticalOrientationValues, alias),
      ),
      'Vertical_Orientation for the whole code space. '
          '${ucd.verticalOrientation.runs} runs.',
    ),
  );
  return out.toString();
}

String _renderMirroring(_Ucd ucd) {
  final StringBuffer out = StringBuffer(_header());
  out.write('''
/// Bidi_Mirrored, Bidi_Mirroring_Glyph and Bidi_Paired_Bracket: the character
/// pairings the bidi algorithm and script itemization both need.
///
/// ## Mirroring, rule L4
///
/// `bidi.dart` resolves embedding levels and stops there, and its own comment
/// says why: L4 is a glyph substitution, not an ordering step. This is the data
/// it deferred. In a right-to-left run, `(` must be *drawn* as `)` - the code
/// point does not change, the glyph does - and the same goes for every bracket,
/// angle bracket, inequality sign and arrow. Skipping L4 leaves an Arabic
/// sentence with its parentheses opening the wrong way, which readers of the
/// script notice immediately.
///
/// [isMirrored] says a character participates. [mirrorOf] gives the code point
/// whose glyph to draw instead - and the two are not the same question:
/// U+2226 NOT PARALLEL TO is mirrored but has no mirror *glyph*, so a renderer
/// that only checks [mirrorOf] silently skips it and one that only checks
/// [isMirrored] has nothing to draw. A font's `rtlm` feature, where present,
/// takes priority over both.
///
/// ## Paired brackets
///
/// Bidi_Paired_Bracket is a stricter property than mirroring: `(` and `)` pair,
/// but `<` and `>` do not, even though both mirror. Two algorithms need it.
/// BD14-BD16 and rule N0 of UAX #9 use it to give a bracket pair one direction
/// instead of resolving each half separately, and UAX #24 uses it so that a
/// parenthesis opened inside an Arabic run and closed after a Latin one
/// resolves to Arabic on both sides. `bidi.dart` carries its own copy for N0;
/// this one exists because `script.dart` needs the same pairs and reaching into
/// another annex's private tables would couple two files that have no other
/// reason to know about each other.
///
/// ## Coverage
///
/// [isMirrored] and [bracketTypeOf] are total over U+0000..U+10FFFF. [mirrorOf]
/// and [pairedBracketOf] are sparse and say so: they answer with the code point
/// itself and with -1 respectively.
library;

import 'packed_table.dart';

''');
  out.write(
    _enum(
      'BracketType',
      'Bidi_Paired_Bracket_Type (`bpt`).\n\n$_orderWarning',
      _bracketTypeValues,
    ),
  );
  out.write('''

final RangeTable _flags = RangeTable(_mirrorFlagTable);
final SparseTable _mirrors = SparseTable(_mirrorGlyphTable);
final SparseTable _brackets = SparseTable(_pairedBracketTable);

const int _mirroredBit = 0x1;
const int _bracketTypeShift = 1;
const int _bracketTypeMask = 0x3;

/// Whether [codePoint] has Bidi_Mirrored=Yes.
bool isMirrored(int codePoint) => _flags.lookup(codePoint) & _mirroredBit != 0;

/// The Bidi_Mirroring_Glyph of [codePoint], or [codePoint] when it has none.
///
/// A character can be mirrored without having one; see the library comment.
int mirrorOf(int codePoint) => _mirrors.lookup(codePoint, orElse: codePoint);

/// The Bidi_Paired_Bracket_Type of [codePoint].
BracketType bracketTypeOf(int codePoint) => BracketType
    .values[_flags.lookup(codePoint) >> _bracketTypeShift & _bracketTypeMask];

/// The bracket [codePoint] pairs with, or -1 when it is not a paired bracket.
///
/// -1 rather than [codePoint] itself, because no bracket pairs with itself and
/// a caller that forgot to check would otherwise match every character against
/// itself.
int pairedBracketOf(int codePoint) => _brackets.lookup(codePoint, orElse: -1);

''');
  out.write(
    _literal(
      '_mirrorFlagTable',
      ucd.mirrorFlags.encode((int value) => value),
      'Bidi_Mirrored and Bidi_Paired_Bracket_Type, packed. '
          '${ucd.mirrorFlags.runs} runs.',
    ),
  );
  out.writeln();
  out.write(
    _literal(
      '_mirrorGlyphTable',
      ucd.mirrorGlyph.encode(),
      'Bidi_Mirroring_Glyph. ${ucd.mirrorGlyph.entries} entries.',
    ),
  );
  out.writeln();
  out.write(
    _literal(
      '_pairedBracketTable',
      ucd.pairedBracket.encode(),
      'Bidi_Paired_Bracket. ${ucd.pairedBracket.entries} entries.',
    ),
  );
  return out.toString();
}

// ---------------------------------------------------------------------------
// Verifying the tables that are already committed
// ---------------------------------------------------------------------------

/// Re-derives the tables in `bidi.dart`, `grapheme.dart` and `line_break.dart`
/// and compares them with what is committed.
///
/// Nothing is written. A mismatch prints where the two diverge and returns
/// false, because the three annex files own their tables and a generator that
/// could rewrite them is a generator that can silently re-label the code space.
bool _verifyExisting(_Ucd ucd) {
  bool ok = true;

  ok &= _compareLiteral(
    'lib/src/text/bidi.dart',
    '_bidiClassTable',
    ucd.bidiClass.encode((String alias) => _position(_bidiClassOrder, alias)),
  );
  ok &= _compareLiteral(
    'lib/src/text/grapheme.dart',
    '_graphemeTable',
    ucd.graphemeFlags.encode((int value) => value),
  );
  ok &= _compareLiteral(
    'lib/src/text/line_break.dart',
    '_lineBreakClassTable',
    ucd.lineBreak.encode((String alias) => _position(_lineBreakOrder, alias)),
  );
  ok &= _compareLiteral(
    'lib/src/text/line_break.dart',
    '_lineBreakFlagTable',
    ucd.lineBreakFlags.encode((int value) => value),
  );
  ok &= _compareIntList(
    'lib/src/text/bidi.dart',
    '_bracketOpeners',
    ucd.bracketOpeners,
  );
  ok &= _compareIntList(
    'lib/src/text/bidi.dart',
    '_bracketClosers',
    ucd.bracketClosers,
  );

  print(ok
      ? 'verify: every committed table matches this UCD byte for byte'
      : 'verify: FAILED');
  return ok;
}

bool _compareLiteral(String path, String name, String generated) {
  final String source = File(path).readAsStringSync();
  final int declaration = source.indexOf('const String $name =');
  if (declaration < 0) {
    print('verify: $path has no $name');
    return false;
  }
  final int end = source.indexOf(';', declaration);
  final String body = source.substring(declaration, end);
  final StringBuffer committed = StringBuffer();
  for (final RegExpMatch match in RegExp("'([^']*)'").allMatches(body)) {
    committed.write(match.group(1));
  }
  final String actual = committed.toString();
  if (actual == generated) {
    print('verify: $path $name matches (${actual.length} chars)');
    return true;
  }
  print(
    'verify: $path $name DIFFERS - committed ${actual.length} chars, '
    'generated ${generated.length}',
  );
  for (int i = 0; i < actual.length && i < generated.length; i++) {
    if (actual[i] != generated[i]) {
      print('  first difference at offset $i: '
          "committed '${actual[i]}', generated '${generated[i]}'");
      break;
    }
  }
  return false;
}

bool _compareIntList(String path, String name, List<int> generated) {
  final String source = File(path).readAsStringSync();
  final int declaration = source.indexOf('const List<int> $name =');
  if (declaration < 0) {
    print('verify: $path has no $name');
    return false;
  }
  final int end = source.indexOf('];', declaration);
  final String body = source.substring(declaration, end);
  final List<int> committed = <int>[
    for (final RegExpMatch match
        in RegExp(r'0x([0-9A-Fa-f]+)').allMatches(body))
      int.parse(match.group(1)!, radix: 16),
  ];
  if (_sameList(committed, generated)) {
    print('verify: $path $name matches (${committed.length} entries)');
    return true;
  }
  print(
    'verify: $path $name DIFFERS - committed ${committed.length} entries, '
    'generated ${generated.length}',
  );
  return false;
}
