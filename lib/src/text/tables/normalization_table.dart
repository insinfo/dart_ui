// GENERATED FILE - DO NOT EDIT.
//
// Source:     referencias/unicode/ucd.nounihan.flat.xml
// UCD:        17.0.0
// Regenerate: dart run tool/generate_unicode_tables.dart

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

/// Decomposition_Type (`dt`): what kind of equivalence a decomposition expresses.
///
/// Only [DecompositionType.canonical] is loss-free. Every other value marks a
/// compatibility decomposition, which NFKC and NFKD apply and NFC and NFD
/// must not.
///
/// The member order is the one the generated table encodes. Reordering the
/// members silently re-labels every code point, so the enum and the table
/// are generated together and have to be regenerated together.
enum DecompositionType {
  /// No decomposition.
  none,

  /// Canonical: the decomposition is equivalent to the character, and NFC
  /// /// and NFD both use it.
  canonical,

  /// Otherwise unspecified compatibility.
  compat,

  /// Encircled form.
  circle,

  /// Arabic final presentation form.
  finalForm,

  /// Font variant.
  font,

  /// Vulgar fraction.
  fraction,

  /// Arabic initial presentation form.
  initialForm,

  /// Arabic isolated presentation form.
  isolatedForm,

  /// Arabic medial presentation form.
  medialForm,

  /// Narrow (halfwidth) form.
  narrow,

  /// Non-breaking form, like U+00A0.
  noBreak,

  /// CNS small form variant.
  small,

  /// CJK squared form.
  square,

  /// Subscript form.
  subscript,

  /// Superscript form.
  superscript,

  /// Vertical layout form.
  vertical,

  /// Wide (fullwidth) form.
  wide;
}

/// The answer to "is this code point already in normalization form X?".
///
/// The member order is the one the generated table encodes. Reordering the
/// members silently re-labels every code point, so the enum and the table
/// are generated together and have to be regenerated together.
enum QuickCheck {
  /// Already in this normalization form.
  yes,

  /// Not in this form, and normalizing will change it.
  no,

  /// Depends on what precedes it: a combining character that may or may
  /// not compose with its base. Only NFC and NFKC produce this.
  maybe;
}

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
const int _hangulSyllableCount = 11172;

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

/// Canonical_Combining_Class for the whole code space, as raw UCD numbers.
/// 606 runs.
const String _combiningClassTable =
    'AAgYmHVoHB8GEoHB4GB8GFqGC8GEqGC8GLBF8GEmHIwHBmHB8GDmHD8GCABmHD8GEmHBoH'
    'B8GCmHBpHBqHCpHBqHCpHBmHNAzImHFApI8GBmHE8GBmHD+GB8GBmHG8GGmHC8GBmHC+GB'
    'kHBmHBKBLBMBNBOBPBQBRBSBTCUBVBWBABXBABYBZBABmHB8GBABSBAoCmHIeBfBgBBAwB'
    'bBcBdBeBfBgBBhBBiBBmHC8GCmHF8GBmHC8GBAQjBBAlDmHHACmHE8GBmHBACmHCAB8GBm'
    'HC8GBAjBkBBAemHB8GBmHC8GBmHC8GDmHB8GCmHB8GBmHD8GBmHB8GBmHB8GBmHB8GBmHC'
    'AgFmHH8GBmHBAJ8GBAYmHEABmHJABmHDABmHFArB8GDA7BmHC8GDmHEAqBmHF8GFmHOAB8'
    'GBmHC8GBmHC8GBmHD8GDbBcBdBmHD8GBmHC8GCmHFA8BHBAQJBADmHB8GBmHCAnDHBAQJB'
    'AwBmHBA9BHBAQJBAuDHBAQJBAuDHBAQJBA/DJBAuDHBAQJBAH0CB7CBAlDHBAQJBAtDJCA'
    'QJBA8DJBAtDnDCJBANrDEAsD2DCJBAN6DEAsC8GCAb8GBAB8GBAB4GBA3BhEBiEBABkEBA'
    'FiEEACiEBABmHCJBABmHCA+B8GBAwDHBABJCAyC8GBAvWmHDA0dJCAeJBA9EJBAKmHBArG'
    'kHBAvE+GBmHB8GBA7GmHB8GBAnCJBAUmHIAC8GBAwBmHF8GGmHC8GBAB8GCmHC8GCmHF8G'
    'BmHS8GBACmHG8GBmHEqHBAoCHBAPJBAmBmHB8GBmHHA2BJCA6BHBALJCAjCHBA4EmHDABB'
    'B8GFmHC8GEmHBABBHAE8GBAGmHBADmHCAmGmHC8GBmHH8GBmHCqHB2GB8GBqGBmHlBoHBk'
    'HC8GB6GBmHBpHB8GBmHB8GBAwWmHCBCmHEBDmHCAEmHBADBCmHB8GBmHBBC8GEmHBA+/Cm'
    'HDAtEJBAgDmHgBAqR6GBkHBoHB+GBgHCApDICA0udmHBAEmHKAgBmHCAwCmHCA0IJBAlBJ'
    'BA3EJBAbmHSA5B8GDAlBJBA/CHBAMJBAvHmHBABmHC8GBACmHCAFmHCABmHBA0BJBA2HJB'
    'Aw5TaBAhYmHH8GHmHCAte8GBAiH8GBA1EmHFAy0B8GBABmHBAoBmHBBB8GBAEJBAlFmHB8'
    'GBA9RmHEAhCmHFA9JmHCAtC8GCAB8GDAmC8GCmHD8GBmHB8GEAxBmHB8GBmHB8GBAgGJBA'
    'pBJBAOJBA5BJBHBAlCmHDAwBJCA+BHBAsCJBAJHBAqDJBHBAyFHBJBAwCHCAQJBAYmHHAD'
    'mHFA5CJDAxDJBADHBAXmHBAjDJBHBA7HJBHBA+DJBA2DJBHBAzDJBAtIJBHBAiIJCAEHBA'
    '8EJBAzCJBASJBAxCJBAlNJBAiIHBABJCAxCJBApNJCAsvQJBAguCBFA7BmHHA5lBGCAslT'
    'BBAmmF4GCBDADiHB4GFAI8GIACmHF8GCAemHEA0EmHDA7tDmHHABmHRACmHHABmHCABmHF'
    'AkDmHBAgFmHHA3LmHBA9BmHEA8PoHC8GBmHBA+HmHB8GBAzHmHBACmHBAHmHCAFmHBA6O8'
    'GHAtDmHGHBA';

/// Decomposition_Type, Full_Composition_Exclusion and the four quick-check
/// properties, packed one word per run. 1338 runs.
const String _normalizationFlagTable =
    'AAgFrgFBAHigFBABvgFBAEigFBACvgFCigFCACigFBvgFCABmgFDABhoEGABhoEJABhoEG'
    'AChoEFAChoEGABhoEJABhoEGAChoEFABhoERAChoEUAChoEJABigFChoEEABhoEGigFCAC'
    'hoEGigFBAChoEGAChoESAChoEXigFBAgBhoECANhoECATigFJhoEQABhoEGAChoELigFDh'
    'oECAChoEkBAChoECAGhoEOA8DvgFJAfigFGACvgFFAbgkCFABgkCHACgkCBABgkCBABgkC'
    'CAGgkCBAHgkCGAEgkCCABgkCCAGgkCBAHhrFCgkCBhrFCgkCBAuBhrFBAFigFBADhrFBAF'
    'igFBhoFBhoEBhrFBhoEDABhoEBABhoEDAZhoEHAZhoEFABigFDhoFCigFCAZigFDABigFC'
    'ADigFBAGhoECABhoEBADhoEBAEhoEDAKhoEBAfhoEBAWhoECABhoEBADhoEBAEhoEDAXho'
    'ECApChoECANhoEEAChoECAChoEGAChoEGAChoEMAChoECAtEigFBA6EhoEFAsBgkCDAfig'
    'FEAnChoEBABhoEBAQhoEBA1ShoEBAHhoEBAChoEBAHgkCBAbhrFIA+CgkCBAMhoECAKgkC'
    'BAEhrFCABhrFBAzChrFBAChrFBAiBhrFDAChrFBA/GgkCBAJhoEBAChoECAJgkCCAEhrFC'
    'A2BhoEBApBgkCBALhoEDAKgkCBAwDhoEBANgkCBApDhoEBABgkCBAEhoECABhoECAJgkCC'
    'AnDgkCBALhoEDAKgkCBAyDgkCBAEgkCBAKhoEBABhoEDgkCBAzCigFBA/DigFBAoBigFCA'
    'uBrgFBA2BhrFBAJhrFBAEhrFBAEhrFBAEhrFBAMhrFBAJhrFBABhrFCigFBhrFBigFBAHh'
    'rFBARhrFBAJhrFBAEhrFBAEhrFBAEhrFBAMhrFBAsDhoEBAHgkCBAtGvgFBAkDgkCVAyBg'
    'kCbAjqChoEBABhoEBABhoEBABhoEBABhoEBADhoEBAiBgkCBAFhoEBABhoEBAChoECABho'
    'EBAoPvgFDABvgFLABvgFSABvgFTugFJANvgFBAiBvgFlBAgChoE6EigFBhoFBAEhoE6CAG'
    'hoEWAChoEGAChoEmBAChoEGAChoEIABhoEBABhoEBABhoEBABhoEShrFBhoEBhrFBhoEBh'
    'rFBhoEBhrFBhoEBhrFBhoEBhrFBhoEBhrFBAChoE1BABhoEFhrFBhoEBigFBhrFBigFCho'
    'FBhoEDABhoEDhrFBhoEBhrFBhoEBhoFDhoEDhrFBAChoEFhrFBABhoFDhoEDhrFBhoEHhr'
    'FBhoEBhoFBhrFCAChoEDABhoEDhrFBhoEBhrFBhoEBhrFBigFBABhrFCigFFrgFBigFDAG'
    'rgFBAFigFBAMigFDAIrgFBADigFCABigFCAEigFBABigFBAIigFDANigFBAHigFBAQvgFC'
    'ACvgFMugFPABugFNALigFBA3CigFClgFBigFBABigFDABigFBlgFKABlgFBigFBAClgFFA'
    'CvgFBigFBvgFBABlgFBABhrFBABlgFBABhrFClgFCABlgFDABlgFCigFElgFBABigFBlgF'
    'FAElgFFAGmgFQigFgBAJmgFBAQhoECAShoEBAehoEDA0BhoEBAEhoEBAChoEBAXhoEBABh'
    'oEBAFigFCABigFCAQhoEBAChoEBAChoEBABhoEBAWhoEBABhoEBAKhoEFAChoECAChoECA'
    'GhoECAChoECAChoECAiBhoEEAwBhoEEAGhoEEA7BhrFCA1JjgFUigFiCjgF1BAhpBigFBA'
    'nDigFDAlDhrFBA/MugFBvgFBAxHvgFBAvJigFBAzCigFBAMigF2GAqBxgFBA1BigFBABig'
    'FDARhoEBABhoEBABhoEBABhoEBABhoEBABhoEBABhoEBABhoEBABhoEBABhoEBABhoEBAB'
    'hoEBAChoEBABhoEBABhoEBAGhoECABhoECABhoECABhoECABhoECAWhoEBAEgkCCigFCAB'
    'hoEBwgFBAMhoEBABhoEBABhoEBABhoEBABhoEBABhoEBABhoEBABhoEBABhoEBABhoEBAB'
    'hoEBABhoEBAChoEBABhoEBABhoEBAGhoECABhoECABhoECABhoECABhoECAWhoEBAChoEE'
    'ADhoEBwgFBAxBigF+CADvgFOAgDigFfABigFkBjgFEAItgFBjgFuBABjgFgCigFMtgFEjg'
    'FvBtgF5CigFZtgFvDigFftgFBA80cvgFCAyGvgFBAgEvgFEADvgFCAibvgFEAJvgFBA2Eh'
    'oEk9KA8qIhrFuIAChrFBABhrFBAChrFKABhrFBABhrFBAChrFCADhrFkCAChrFqDAmBigF'
    'HAMigFFAFhrFBABhrFBlgFKhrFNABhrFFABhrFBABhrFCABhrFCABhrFJigFBogFBkgFBo'
    'gFBkgFBngFBpgFBogFBkgFBngFBpgFBogFBkgFBngFBpgFBogFBkgFBngFBpgFBogFBkgF'
    'BngFBpgFBogFBkgFBngFBpgFBogFBkgFBngFBpgFBogFBkgFBngFBpgFBogFBkgFBngFBp'
    'gFBogFBkgFBngFBpgFBogFBkgFBngFBpgFBogFBkgFBngFBpgFBogFBkgFBogFBkgFBogF'
    'BkgFBogFBkgFBogFBkgFBogFBkgFBogFBkgFBngFBpgFBogFBkgFBngFBpgFBogFBkgFBn'
    'gFBpgFBogFBkgFBngFBpgFBogFBkgFBogFBkgFBngFBpgFBogFBkgFBogFBkgFBngFBpgF'
    'BogFBkgFBngFBpgFBogFBkgFBogFBkgFBAhBogFBkgFBngFBpgFBogFBkgFBogFBkgFBog'
    'FBkgFBogFCkgFBogFBkgFBogFBkgFBogFBkgFBngFBpgFBngFBpgFBogFBkgFBogFBkgFB'
    'ogFBkgFBogFBkgFBogFBkgFBogFBkgFBogFBkgFBngFBogFBkgFBngFBogFBkgFBngFBpg'
    'FBogFkDkgFzBngFoCpgFWogFckgFcngFHpgFIkgFBogFBASngFBkgFBngFGkgFBngFBkgF'
    'CngFCkgFCngFCkgFBngFBkgFBngFBkgFCngFBkgFCngFBkgFBngFBkgFCngFBkgFBngFCk'
    'gFDngFBkgFFngFBkgFFngFBkgFCngFBkgFBngFDkgFBngFEACngFEkgFCngFBkgFEngFBk'
    'gFWngFCkgFCngFBkgFBngFBkgFIngFDkgFCAoBogFNATwgFKAWwgFVACwgFCigFHsgFDAB'
    'sgFTABsgFEAEogFBpgFBogFBABogFBABogFBpgFBogFBpgFBogFBpgFBogFBpgFBogFBpg'
    'FBogFCkgFBogFBkgFBogFBkgFBogFBkgFBogFBkgFBngFBpgFBogFBkgFBogFBkgFBngFB'
    'pgFBogFBkgFBogFBkgFBngFBpgFBogFBkgFBngFBpgFBogFBkgFBngFBpgFBogFBkgFBng'
    'FBpgFBogFBkgFBngFBpgFBogFBkgFBogFBkgFBogFBkgFBogFBkgFBogFBkgFBngFBpgFB'
    'ogFBkgFBngFBpgFBogFBkgFBngFBpgFBogFBkgFBngFBpgFBogFBkgFBngFBpgFBogFBkg'
    'FBngFBpgFBogFBkgFBngFBpgFBogFBkgFBngFBpgFBogFBkgFBngFBpgFBogFBkgFBngFB'
    'pgFBogFBkgFBngFBpgFBogFBkgFBngFBpgFBogFBkgFBngFBpgFBogFBkgFBngFBpgFBog'
    'FBkgFBngFBpgFBogFBkgFBogFBkgFBogFBkgFBngFBpgFBogFBkgFBogFBkgFBogFBkgFB'
    'ogFBkgFBAExgFgDqgF+CADqgFGACqgFGACqgFGACqgFDADxgFHABqgFHA6uBhoEBAahoEB'
    'A8MvgFFABvgFqBABvgFJA/mChoEBABhoEBAOhoEBAOgkCBAsDgkCBAGhoECAuQgkCBAMho'
    'ECAKgkCBArBhoEBABhoEBAIhoEBAChoEBAmBgkCBACgkCBAGgkCBAChsGBABhsGCgkCBAm'
    'HgkCBAJgkCBhoECgkCBhoEBAwHgkCBAKhoECA0bgkCBAHhoEBAl/RgkCDhsGIgkCBA9hDg'
    'kCBhsGBhoECAr7XlgFkBAkjBhrFHA2ChrFGA/RlgF1CABlgFnCABlgFCAClgFBAClgFCAC'
    'lgFEABlgFMABlgFBABlgFHABlgFhCABlgFEAClgFIABlgFHABlgFcABlgFEABlgFFABlgF'
    'BADlgFHABlgF0KAClgFkJAClgFyBAwhCvgFhBugFavgFDAysDlgFEABlgFbABlgFCABlgF'
    'BAClgFBABlgFKABlgFEABlgFBABlgFBAGlgFBAElgFBABlgFBABlgFBABlgFDABlgFCABl'
    'gFBAClgFBABlgFBABlgFBABlgFBABlgFBABlgFCABlgFBAClgFEABlgFHABlgFEABlgFEA'
    'BlgFBABlgFKABlgFRAFlgFDABlgFFABlgFRAkSigFLAFigFbjgFEABtgFgBAavgFDAjBtg'
    'FBAvDtgFDANtgFsBAEigFJAHjgFCA+sClgFKAmg/BhrF+QA';

/// Decomposition mappings, Hangul excluded. 5914 entries.
const String _decompositionTable =
    '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'
    'gNhCC97O1tNBC/5O3tNBC/7O1vNBCh6O3vNBCj8OhuNBCl6OjuNBCn8OptNBCp6OrtNBCh'
    '0OtwNBCjyOvwNBCr8OlwNBCt6OnwNBCv8OxuNBCx6OzuNBCz8O5tNBC16O7tNBC38OxuNB'
    'C56OzuNBC78OpuNBC96OruNBCjwOnxNBCjwOpxNBCnwOpxNBCnwOrxNBCl9O1uNBCn7O3u'
    'NBCp9OzuNBCr7O1uNBCn/NrxNBCn/NtxNBCv9OtxNBCx7OvxNBCx9O3xNBCz7O5xNBCz9O'
    '1xNBC17O3xNBC39OhwNBC57OjwNBC79O7xNBC97O9xNBC/9OhwNBCh8OjwNBCj+O3vNBCl'
    '8O5vNBCl+O3vNBCn8O5vNBC91O5yNBC/zO7yNBCp+O9yNBCr8O/yNBCt+O9wNBCv8O/wNB'
    'Cx+OlwNBCz8OnwNBCz+OlxNBC18OnxNBCDnzNBCDpzNBC7+OxwNBC98OzwNBC/+O9wNBCh'
    '9O/wNBCh/O5zNBCj9O7zNBCl/OxzNBCn9OzzNBCp/O9xNBCr9O/xNBCr/O5zNBCt9O7zNB'
    'Cv/OlyNBCx9OnyNBCz/OtxNBC19OvxNBC3/O5xNBC59O7xNBCt3O10NBCv1O30NBCx3Or0'
    'NBCz1Ot0NBCnwO/0NBCnwOh1NBCrwOh1NBCrwOj1NBCngPl1NBCp+On1NBCrgP90NBCt+O'
    '/0NBCrgPh1NBCt+Oj1NBCvgPtzNBCx+OvzNBCDv1NBCDx1NBC3gP5yNBC5+O7yNBC5gPx1'
    'NBC7+Oz1NBC9gP9zNBC/+O/zNBCzwO51NBCzwO71NBCrwO91NBCrwO/1NBCLh2NBCLj2NB'
    'CrhPl2NBCt/On2NBCvhPx0NBCx/Oz0NBCzhP5zNBC1/O7zNBC3hPl0NBC5/On0NBC5hP70'
    'NBC7/O90NBC9hPn0NBC//Op0NBChiPx0NBCjgPz0NBC/wOt3NBC/wOv3NBC/wOj3NBC/wO'
    'l3NBCriPx3NBCtgPz3NBCviP11NBCxgP31NBCxiP/3NBCzgPh4NBC1iPh4NBC3gPj4NBC5'
    'iP33NBC7gP53NBC9iP93NBC/gP/3NBChjPp2NBCjhPr2NBCjjPl4NBClhPn4NBCnjPn4NB'
    'CphPp4NBCpjPt4NBCrhPv4NBCrjP74NBCthP94NBCvjP92NBCxhP/2NBCzjPl2NBC1hPn2'
    'NBC7iPp2NBCliP94NBChiP74NBC/hP94NBCxjP39NBC3xOn5NFC9lP53NBC/jP73NBChmP'
    'x5NBCjkPz5NBCj+Ol6NBCl8On6NBCn+Or6NBCp8Ot6NBCr+O95NBCt8O/5NBCv+Ot6NBCx'
    '8Ov6NBCXz6NBCX16NBC36O56NBC36O76NBC76O/6NBC76Oh7NBC/6Ox6NBC/6Oz6NBCj7O'
    'h7NBCj7Oj7NBCrB/6NBCrBh7NBClnPp5NBCnlPr5NBCpnPh7NBCrlPj7NBCtnPx7NBCvlP'
    'z7NBCn/O57NBCp9O77NBCr/O/7NBCt9Oh8NBCv/Ox7NBCx9Oz7NBCz/Oh8NBC19Oj8NBCb'
    'n8NBCbp8NBC9nP97NBC/lP/7NBChoPt6NBCjmPv6NBC5nPx6NBC7lPz6NBC9nPp8NBC/lP'
    'r8NBC3/O98NBC59O/8NBC7/Oj9NBC99Ol9NBC//O18NBCh+O38NBCjgPl9NBCl+On9NBCX'
    'r9NBCXt9NBCzzOx9NBCzzOz9NBC3zO39NBC3zO59NBC7zOp9NBC7zOr9NBC/zO59NBC/zO'
    '79NBCj0O97NBCj0O/7NBC9oPh8NBC/mPj8NBChpP59NBCjnP79NBCxzOt+NBCxzOv+NBC1'
    'zOz+NBC1zO1+NBC5zOl+NBC5zOn+NBC9zO1+NBC9zO3+NBCh0O58NBCh0O78NBCxpPj/NB'
    'CznPl/NBC1pPh9NBC3nPj9NBC5pP5+NBC7nP7+NBC9pPp/NBC/nPr/NHC90N5+NBC/0N5+'
    'NBCDjgOBCDlgOBCHlgOBCHngOBCLn8NBCLp8NBCt3Np/NBCv3Np/NBCDzgOBCD1gOBCH1g'
    'OBCH3gOBCL38NBCL58NBC11N5/NBC31N5/NBCDjhOBCDlhOBCHlhOBCHnhODCl4NpgOBCn'
    '4NpgOBCDzhOBCD1hOBCH1hOBCH3hODCx2N5gOBCz2N5gOBCDjiOBCDliOBCHliOBCHniOB'
    'CLn+NBCLp+NBCh5NphOBCj5NphOBCDziOBCD1iOBCH1iOBCH3iOBCL3+NBCL5+NBCt3N5h'
    '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'
    'Z0qO/gZBDjhZkkRhhZBDlhZ2yUjhZBDnhZuqiBlhZBDphZosOnhZBDrhZyotBphZBDthZq'
    'xQrhZBDvhZ6yjBthZBDxhZgtOvhZBDzhZw6nBxhZBD1hZg7nBzhZBB2wRBBujWBBi0ZBBw'
    '0kBJD//Y3/Y1gZBC9hZ/hZBC/hZ/hZBChiZ/hZBCjiZ/hZBCliZ/hZBCniZ/hZBCpiZ/hZ'
    'BCriZ/hZBCtiZ/hZBCtiZziZBCviZziZBCxiZziZBCziZziZBC1iZziZBC3iZziZBB/1QB'
    'B91QBB91QBB71QBB71QBB71QBB51QBB31QBB31QBB11QBB11QBB11QBB11QBB11QBC72Q5'
    'wQBC52Q7wQBC52Q9wQBC32Q/wQBC32QhxQBC32QjxQBC12QlxQBCz2QnxQBCz2QpxQBCx2'
    'QrxQBCx2QtxQBCx2QvxQBCx2QxxQBCx2QzxQBF72Q1xQpsQ33QlxQBEh3Q9wQj3QxwQBCl'
    '3Q/wQCBg4NBB2gOBBu4NBBwlSBBghOBBwuPBB63NBBouPBBq9NBBwrQBB8naBBg+eBBw6c'
    'BB2paBBm0vBBBgpSBBq1ZBBy5aBBunaBB2qjBBBy3QBBo+fBB2gtBBBssjBBB4hQBB+zjB'
    'BB6phBBBwtTBB68uBBB6oPBBktQBBykdBBq2yBBBgnOBBuvPBBgscBBs2NBBw4NBBq2NBB'
    '+zVBB20QBBkpQBB6uUBB2rUBBujiBBBolOBByhtBBBqqQBB4mTBC7nZ1nZBC9nZ1nZBC/n'
    'Z1nZBChoZ1nZBChoZpoZBCjoZpoZBCloZpoZBCnoZpoZBCpoZpoZBCroZpoZBCtoZpoZBC'
    'voZpoZBCxoZpoZBCzoZpoZBCzoZ9oZBC9oZwkaBC9oZukaBC9oZskaBC9oZqkaBC9oZoka'
    'BC9oZmkaBC9oZkkaBC9oZikaBC9oZgkaBDvpZxpZ+jaBDxpZxpZ8jaBDzpZxpZ6jaBCnoZ'
    'pmZBDvmZ1lZrmZBCxmZvnZBDloZ1nZ1oZBB7iBBB5iBBB3iBBB1iBBBziBBBziBBBxiBBB'
    'viBBBtiBBBriBBBpiBBBniBBBliBBBjiBBBhiBBB/hBBB9hBBB5hBBB3hBBB1hBBBzhBBB'
    'zhBBBzhBBBzhBBBzhBBBzhBBBvhBBBrhBBBnhBBBjhBBB/gBBB/gBBB/gBBB/gBBB/gBBB'
    '9gBBB7gBBB5gBBB5gBBB5gBBB5gBBB5gBBB5gBBB3gBBB3gBBB3gBBB3gBBCq+N64QBE7l'
    'B9iBngBvjBBE9lBrhB3iB/lBBE/lB9gBviB/lBBDhmBtgBvhBBE/lBxjBhhBnlBBDhmBjh'
    'BnkBBD/lB5lBlhBBF9lB7kBvlB1gB7jBBE/lB3gB5lB3gBBD9lBrhB/kBBD/lB7gBziBBD'
    '/lBtmBhiBBEhmBliBxkBnkBBEjmB/hBliBhhBBDjmBhiB1hBBDlmB3hBhjBBCjmBnmBBDl'
    'mBrkBphBBEpmB5iBviBrhBBEpmBviBllBthBBCtmBtiBBFvmBviBpmB3iBpjBBGxmBxiBp'
    'jBzhB7kB1iBBFzmBziBviBnlB9kBBDvmB9iBvjBBFxmB/iBxjBhlBriBBF1mB9iB7lBrnB'
    '5iBBE3mB7iB9hB7kBBD1mB/hBlmBBDzmBjjBllBBD1mBjiBhkBBEzmB1nB/mBnjBBF1mB5'
    'iB9lBniB/jBBEzmBtjB7iBhnBBDtmB9iBhmBBDvmB/iB1lBBDnmBviB1mBBC7lB7mBBC5l'
    'B1jBBC9lBnjBBC7lBzlBBD1lBrmBhmBBD1lBroBrmBBFzlB9iB/mBvjBlmBBD1lB/iBvmB'
    'BE5lBhjBhkBjkBBFzlB3oBpnBrmBlkBBD1lB/nBnkBBC3lB5nBBC7lBrkBBF5lBhpBxkB9'
    'mBxmBBE7lB/oBtjB1mBBF7lBhnB5nB5oBxkBBD/lB3kBjkBBF7lBtoBtnBzjB1kBBC5lBz'
    'nBBD7lB5mBrmBBDhmB7kBpnBBD/lBtkBhoBBDhmB9jBloBBDlmB/jB5nBBE/lBxpBzkBpn'
    'BBDjmBllBrnBBCnmB3kBBDlmB5kBtnBBDrmBpkBrlBBDtmBrkB9kBBEpmB9pBnpBrlBBDr'
    'mB/pBxlBBDtmBjoBrnBBDvmB1lBtpBBFxmBnlB/oB/lBnlBBExmBxpB1lBplBBCzmB9lBB'
    'F1mB/lBznB7kB9lBBCzmB9pBBE1mB/pBnoBxlBBE3mBhlBpoBjmBBDzmBjlBpoBBD1mBll'
    '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'
    'Bl3lCBB9jlCBB/h+BBBxx9BBBrwxBBB/nzCBBvs8BBBv3zCBBx4zCBBzz/BBBx59BBBt26'
    'BBBnuxBBBz92BBB3orCBBz1nCBB9l3BBBpy1CBBv3uCBB70sCBBz9iCBBj/hCBB3kzCBBx'
    'mgCBBr60CBB57sCBBz11CBB3pmCBBh/pCBBvk+BBBv6yCBB7wwCBB3mhCBBpy6BBBps3BB'
    'Br7mCBBh80BBBzumCBBpnrCBB9o7BBBp9qCBBhhiCBBxs1CBB9g0CBB/6zCBBxvoCBBnp+'
    'BBB5w7BBB1q3BBB96zBBBzozCBB7zyCBB7gwCBBrptCBB77pCBBr4kCBB1lgCBBx9xBBB5'
    'xvBBBhvtBBB1rtBBB9uzCBBpspCBBphnCBB1i1BBBzxtCBB9/rCBB/4rCBBtvqCBB9mlCB'
    'BzkkCBB1wiCBB18/BBBj69BBBvy8BBBjn1BBB1q6BBBt30BBBhlzBBBp4zCBBzvzCBBhuy'
    'CBBttkCBB7t4BBBtv3BBBxttCBB76sCBBxirCBBt/mCBBv2+BBBjjjCBBns1CBB/qxCBBl'
    '8uCBBh/tCBB/4sCBB1/iCBBp0iCBBph9BBBz28BBB53zBBB3rxBBB1mxBBB35wBBBzi1CB'
    'BvggCBBlg0BBB/vxBBBvtsCBBnz1CBBhu0CBB78uCBB73uCBBpiqCBB57nCBBj/jCBB93h'
    'CBBrs6BBBt00BBBtjtBBB5zpCBBv5xBBB7zzCBB5kpCBBr9oCBBxomCBB9ylCBBl8iCBBn'
    'niCBBl2gCBB9r+BBBj3wBBBnm0CBBn6rCBB11xBBBx60CBB3ruCBB3+lCBB5q1BBB5ktCB'
    'BppsCBBl8oCBBnljCBBr1xBBBn7zCBB98yCBBz3uCBB58pCBBlppCBBzzoCBB7vmCBB79i'
    'CBBlgiCBB5m9BBBvx4BBBtw4BBB5h0BBBvwxBBB3qzCBBjzlCBB/8yCBB7hkCBBt1iCBBr'
    '/5BBB70xBBB15uBBBn1tBBB5lpCBBzimCBB7g8BBB3y/BBBvt/BBBt2+BBBzzjCBBj2kCB'
    'Bnq3BBB5z1CBBvs7BBBp8zCBBx/zCBB11tCBB9yrCBB5y+BBB9nvCBBtumCBBj1pCBB3s1'
    'BBB374BBB37xBBB9n4BBBvztCBB3s0CBB5kyCDBr7wCCB75pCDBtj0CBB3ujCBB50hCBB3'
    'tgCBB1rgCBBprgCBB3ogCBBrsxBBB91+BBBhm9BCB7g6BCBzy3BDB5+0BBBxy0BEB1zwBB'
    'B9ywBBBnwwBBBxnuBBB/00BBBv3xBBBjo1CBBz00CBBpu0CBBz2zCBB/0zCBBnuzCBBxpy'
    'CBBhjyCBB/8xCBBx/wCBBj5wCBBt9uCBB78uCBBx6sCBBrtsCBBhrsCBB7ksCBBjvqCBB/'
    'lqCBBj7pCBB97oCBB7smCBB3imCBBpylCBBztkCBB7hkCBBvijCBBz7gCBB7wgCBBnwgCB'
    'BrwgCBB9vgCBBzvgCBBnvgCBBpsgCBBpsgCBBnhgCBBn9/BBBrp/BBBlm+BBB9k+BBBvh+'
    'BBBvu9BBBrl9BBB9m8BBBn+7BBBp+7BBBvg7BBB/04BBB1s4BBBh23BBBzy3BBBh52BBB5'
    '12BBB/q1BBB9i1BBBp4xBBBzmxBBB9ixBBBr/sCBBkokFBBpl8BDBzk2CBB3r0CBBzw0CB'
    'Blv1CBB9y0CBBpv0CBB96zCBB53zCBB1tyCBBnyyCBBhuyCBBxpyCBBjixCBBz8wCBBzzw'
    'CBB1ywCBB7hwCBBx1vCBB/6tCBBz6tCBB1xtCBBvttCBB76sCBBxzsCBB/3sCBB1vsCBBz'
    'ysCBBxpsCBBvlsCBBxsrCBBjnrCBB5jrCBBzzqCBB5hqCBB13pCBBv3pCBB7zpCBB3xnCB'
    'B3tnCBBr1mCBB57lCBB78lCBBv3lCBB5nlCBB7ykCBBrvhCBBxmkCBB/+jCBBr3jCBB/ij'
    'CBB35iCBBv2iCBBtoiCBBroiCBB39hCBB38hCBBn7hCBB91hCBBz2hCBB99gCBB1//BBB5'
    'u/BBBlj/BBBn1+BBB3r+BBBl39BBB5q9BBBh27BBBps7BBB3z5BBBp34BBBhz4BBBjy4BB'
    'Bz/3BBBj83BBB/+3BBB173BBB973BBBh93BBBr43BBBrz3BBBx72BBBz41BBBhl1BBB1y0'
    'BBB9k0BBBzkyBBBn+xBBBj3xBBB7uxBBB1sxBBB/rxBBBhpxBBB17vBBBjztBBB232EBBo'
    '32EBBow8EBBpz/CBB1r9CBB1p9CBBo3rFBB0/wFBB4/hGBBp5tBBB10tBnBCzp9Dzp9DBC'
    '1p9Dvp9DBC3p9Drp9DBD5p9D5p9Dzp9DBD7p9D7p9Dvp9DBCr48Dhp9DBClp9Djp9DNC95'
    '6D556DBC/56D966DBCh66Dz66DBCv56D/56DBCl66Dz66DGCn06Dx26DCC5y6Dv26DBB7z'
    '6DBBh16DBB906DBB906DBBx06DBBx06DBBx06DBB9z6DBB7z6DBB7v9DBCh06Dx26DBCj0'
    '6Dx26DBC6B126DBC4B126DBC716Dt36DBC916Dt36DBC/16Dn36DBC/16Dp36DBC/16Dr3'
    '6DBC/16Dt36DBC/16Dv36DBC/16Dx36DBC/16Dz36DCC/16D336DBC/16D536DBC/16D73'
    '6DBC/16D936DBC/16D/36DCC/16Dj46DCC/16Dn46DBC/16Dp46DCC/16Dt46DBC/16Dv4'
    '6DCC/16Dz46DBC/16D146DBC/16D346DBC/16D546DBC/16D746DBCr36Dj56DBC136D54'
    '6DBCj36D746DBCz26D946DBC936Dl36DBB9t6DBB/t6DBBtt6DBBvt6DBBxt6DBBzt6DBB'
    'vt6DBBxt6DBBzt6DBB1t6DBBzt6DBB1t6DBB3t6DBB5t6DBBnu6DBBpu6DBBru6DBBtu6D'
    'BBlu6DBBnu6DBBpu6DBBru6DBB5u6DBB7u6DBB9u6DBB/u6DBBrs6DBBts6DBBvs6DBBxs'
    '6DBBvs6DBBxs6DBBzs6DBB1s6DBB7u6DBB9u6DBB/u6DBBhv6DBBlv6DBBnv6DBBpv6DBB'
    'rv6DBBnv6DBBpv6DBBrv6DBBtv6DBBtv6DBBvv6DBBxv6DBBzv6DBBpv6DBBrv6DBBvv6D'
    'BBxv6DBBvv6DBBxv6DBB/v6DBBhw6DBBjv6DBBlv6DBB1v6DBB3v6DBBpu6DBBru6DBBtu'
    '6DBBvu6DBBlu6DBBnu6DBBpu6DBBru6DBBlu6DBBnu6DBBpu6DBBru6DBBxu6DBBzu6DBB'
    '1u6DBB3u6DBBnu6DBBpu6DBBpu6DBBru6DBBtu6DBBvu6DBBnu6DBBpu6DBBpu6DBBru6D'
    'BBtu6DBBvu6DBB3u6DBB5u6DBB7u6DBB9u6DBB3t6DBB5t6DBB5t6DBB7t6DiBBry6DBBt'
    'y6DBBvy6DBBxy6DBB/w6DBBhx6DBBlx6DBBnx6DBBlx6DBBnx6DBBr26DBBlx6DBBnx6DB'
    'B1x6DBB3x6DBBxx6DBBzx6DBBnx6DBBpx6DBBrx6DBBtx6DBB956DBB/56DBCn86Dl86DB'
    'Cp86Dn86DBCr86Dtx6DBCt86Dvx6DBCv86Dr66DBCx86Dt66DBCz86Dxy6DBC186Dzy6DB'
    'C386D3y6DBC586D5y6DBC786D3y6DBC986D5y6DBC/86Dry6DBCh96Dty6DBCj96Dvy6DB'
    'Cl96D/66DBCn96Dh76DBCp96Dj76DBB/y6DBBhz6DBBjz6DBBlz6DBCz96Dn96DBC196Dn'
    '96DBC396D576DBC596Dz76DBC796Dz76DBC596Dx96DBC796Dx96DBC996Dx96DBC/96Dl'
    '86DBCh+6D/76DBCj+6D/76DBCh+6D996DBCj+6D996DBCl+6D996DBCn+6Dx86DBCp+6Dr'
    '86DBCr+6Dr86DBCr+6Dp+6DBCt+6D586DBCv+6Dz86DBCx+6Dz86DBCx+6Dv+6DBCz+6Dh'
    '96DBCz+6D1+6DBC1+6Dl96DBC1+6D5+6DBC3+6D5+6DBC5+6Dr96DBCx+6D/+6DBCz+6D/'
    '+6DBC1+6D/+6DBC3+6Dz96DBC1+6Dl/6DBC3+6D396DBC3+6Dr/6DBC5+6Dr/6DBC7+6Dr'
    '/6DBC9+6D/96DBC9+6Dx/6DBC/+6Dj+6DBC/+6Dl+6DBC/+6D5/6DBCh/6Dp+6DBCh/6D9'
    '/6DBCj/6Dt+6DBC3+6Dhg7DBC5+6Dhg7DBC7+6Dhg7DBC9+6D1+6DBC/+6Dv+6DBCh/6Dv'
    '+6DBCh/6Drg7DBCj/6D9+6DBCl/6D3+6DBCn/6D3+6DBCn/6D/g7DBCp/6D3g7DBCr/6D3'
    'g7DBCt/6D3g7DBCv/6Dt/6DBCx/6Dt/6DBCz/6Dn/6DBC1/6Dn/6DBC1/6Dlh7DBC3/6Dl'
    'h7DBC5/6Dlh7DBC7/6D5/6DBC9/6Dz/6DBC//6Dz/6DBC//6Dxh7DBChg7Dxh7DBCjg7Dx'
    'h7DBClg7Dlg7DBCng7D//6DBCpg7D//6DBCpg7D9h7DBCrg7D9h7DBCtg7D9h7DBCvg7Dx'
    'g7DBCxg7Drg7DBCzg7Drg7DBCzg7Dpi7DBC1g7D5g7DBC3g7Dzg7DBC5g7Dzg7DBC1g7Dx'
    'i7DBC3g7Dxi7DBC5g7Dxi7DBC7g7Dlh7DBC9g7D/g7DBC/g7D/g7DBC1i7D1+6DBC1i7D3'
    '+6DBCnh7D5+6DBD7j+Djh7D5g7DBD9j+Djh7D7g7DBD/j+Djh7D9g7DBDhk+Djh7D/g7DB'
    'Djk+Djh7Dhh7DBDlk+Djh7Dl/6DBC7j7Dlj7DBC9j7Dlj7DBC/j7Dhi7DBChk7Dhi7DBCj'
    'k7D9h7DBClk7D9h7DBCjk7Dxj7DBClk7Dxj7DBCnk7Dti7DBCpk7Dti7DBCrk7Dpi7DBCt'
    'k7Dpi7DBCrk7D9j7DBCtk7D9j7DBCvk7D5i7DBCxk7D5i7DBCzk7D1i7DBC1k7D1i7DBC1'
    'k7Dpk7DBC3k7Dpk7DBC5k7Dlj7DBC7k7Dlj7DBC9k7Dhj7DBC/k7Dhj7DBC1j7Dlj7DBC3'
    'j7Dlj7DBC3j7Dpj7DBC5j7Dpj7DBC5j7Dxl7DBC7j7D5j7DBC9j7D5j7DBC/j7Dzj7DBCh'
    'k7Dzj7DBChk7D/j7DBCjk7D5j7DBClk7D5j7DBClk7Dhm7DBCnk7Dnk7DBCnk7Dxl7DBCp'
    'k7Dxl7DBCrk7Dtk7DBCtk7Dtk7DBCvk7Dpk7DBCxk7Dpk7DBCtk7D/h7DBCtk7D/l7DBCv'
    'k7D/l7DBCxk7D7k7DBCzk7D7k7DBC1k7D3k7DBC3k7D3k7DBChn7D1m7DBCjn7D1m7DBCl'
    'n7D1m7DBCnn7Dpl7DBCpn7Dnl7DBCnn7D/m7DBCpn7D/m7DBCrn7D/m7DBCtn7Dzl7DBCv'
    'n7Dxl7DBCtn7Dpn7DBCvn7Dpn7DBCxn7Dpn7DBCzn7D9l7DBC1n7D7l7DBC1n7Dhm7DBC1'
    'n7Dzn7DBC3n7Dlm7DBC3n7D5n7DBC5n7Dpm7DBC5n7D9n7DBC7n7Dtm7DBCzn7Dho7DBC1'
    'n7Dho7DBC3n7Dho7DBC5n7D1m7DBC3n7Dno7DBC5n7Dno7DBC7n7D7m7DBC7n7Dvo7DBC9'
    'n7Dvo7DBC/n7Dvo7DBCho7Djn7DBCho7D1o7DBCho7Dnn7DBCho7D7o7DBCjo7Drn7DBCj'
    'o7D/o7DBClo7Dvn7DBC5n7Djp7DBC7n7Djp7DBC9n7Djp7DBC/n7D3n7DBC/n7Dpp7DBCh'
    'o7D7n7DBCho7Dvp7DBCjo7Dvp7DBClo7Dvp7DBCno7Dlo7DBCpo7Dlo7DBCpo7D5p7DBCr'
    'o7D5p7DBCto7D5p7DBCvo7Dto7DBCxo7Dro7DBCxo7Djq7DBCzo7Djq7DBC1o7Djq7DBC3'
    'o7D3o7DBC3o7Drq7DBC5o7Drq7DBC7o7Drq7DBC9o7D/o7DBC/o7D9o7DBC/o7D1q7DBCh'
    'p7Dlp7DBCjp7Dxm7DBC/o7D7q7DBChp7D7q7DBCjp7D7q7DBClp7Dvp7DBCnp7Dtp7DBCx'
    'r7Dzp7DBCzr7Dxp7DBCxr7D3p7DBCzr7D1p7DBCxr7D7p7DBCzr7D5p7DBCzr7D/p7DBC1'
    'r7D9p7DBCnr7Djq7DBCpr7Dhq7DBCpr7Dnq7DBCrr7Dlq7DBCvq7Dtq7DBCxq7Dtq7DBCx'
    'q7Dvq7DBCvq7Dxq7DBCxq7Dvq7DBCrq7D1q7DBCtq7Dzq7DBDjr7Dnq7Dhq7DBDlr7Dnq7'
    'Djq7DBDnr7Dnq7Dlq7DBC7r7D3q7DBC9r7D3q7DBC7r7D7q7DBC9r7D7q7DBC9r7D/q7DB'
    'C/r7D/q7DBCvs7Djr7DBCxs7Djr7DBCxs7Dnr7DBCzs7Dnr7DBCjt7Drr7DBClt7Drr7DB'
    'Cpt7Dvr7DBCrt7Dvr7DBCpt7Dzr7DBCrt7Dzr7DBC/s7D3r7DBCht7D3r7DBCht7D7r7DB'
    'Cjt7D7r7DBCpt7D5t7DBCrt7D5t7DBCtt7D5t7DBCvt7Dts7DBCxt7D3t7DBC1t7D5t7DB'
    'Czt7D7t7DBCzt7D9t7DBCzt7Dvs7DBC1t7Dvs7DBCzt7Dzs7DBC1t7Dzs7DBC1t7D3s7DB'
    'C3t7D3s7DBCnu7D7s7DBCpu7D7s7DBCpu7D/s7DBCru7D/s7DBC7u7Djt7DBC9u7Djt7DB'
    'Chv7Dnt7DBCjv7Dnt7DBChv7Drt7DBCjv7Drt7DBC3u7Dvt7DBC5u7Dvt7DBC5u7Dzt7DB'
    'C7u7Dzt7DBChv7Dxv7DBCjv7Dxv7DBClv7Dxv7DBCnv7Dlu7DBCpv7Dvv7DBCtv7Dxv7DB'
    'Crv7Dzv7DBCrv7D1v7DBCxv7Dhw7DBCzv7Dhw7DBC1v7Dhw7DBC3v7D1u7DBC7v7Dzu7DB'
    'C7v7D1u7DBC3v7D7u7DBChw7Dvw7DBCjw7Dvw7DBClw7Dvw7DBClw7D1w7DBCnw7D1w7DB'
    'Cpw7D1w7DBClw7Dpv7DBClw7Drv7DBCpx7Dhv7DBCrx7Djv7DTDry7Dny7D1w7DBDty7Dn'
    'y7Dpy7DBDvy7Dpy7Dry7DBDxy7Dry7D7w7DBDzy7Dry7D9w7DBD1y7D/w7Dxy7DBD3y7Dh'
    'x7Dxy7DBD5y7Djx7Dxy7DBD3y7Dlx7D1y7DBD5y7Dnx7D3y7DBD5y7Dpx7D/w7DBD7y7Dr'
    'x7Djx7DBDxy7D9y7D/y7DBDzy7Dhz7D/y7DBD1y7Djz7Dpx7DBD3y7Dzx7Djz7DBD5y7D1'
    'x7Dlz7DBD7y7D3x7Dpz7DBD9y7D5x7D5x7DBD/y7D7x7D7x7DBD9y7Dtz7Dtz7DBD/y7Dv'
    'z7Dvz7DBDhz7Dhy7Dhy7DBDlz7Dzz7Djy7DBDnz7D1z7Dly7DBDpz7D5z7D9x7DBDrz7Dp'
    'y7D3z7DBDtz7Dry7D5z7DBDvz7Dty7Dty7DBDxz7Dvy7Dvy7DBDvz7Dh07Dpy7DBDxz7Dh'
    '07Dzy7DBDzz7Dj07D1y7DBDzz7D3y7Dn07DBD1z7D5y7Dp07DBD3z7D7y7D7y7DBD5z7D9'
    'y7Dzy7DBD3z7Dx07D/y7DBD5z7Dhz7Dhz7DBD7z7Djz7Djz7DBD9z7Dlz7D9y7DBD9z7Dn'
    'z7Dnz7DBD/z7Dpz7D/y7DBDh07Drz7Djz7DBD1z7D707Dtz7DBD3z7D907Dvz7DBD3z7Dx'
    'z7Dh17DBD5z7Dzz7Dzz7DBD3z7Dl17D1z7DBD5z7Dn17Dtz7DBD7z7Dp17Dxz7DBD9z7Dt'
    '17Dt17DBD/z7Dv17Dv17DBDh07Dt17D/z7DBDj07Dv17Dh07DBDl07Dj07Dz17DBDn07Dl'
    '07D117DBDn07D317D517DBDp07D517Dp07DBDr07D717Dh07DBDt07D/17D917DBDv07Dh'
    '27Dv07DBDx07D/17Dj27DBDz07Dh27Dz07DDD507Dr27Dn27DBD307D707Dt27DBD507D9'
    '07D907DBD907Dv27D/07DBD/07Dx27D507DBDh17D127Dj17DBDj17D327Dl17DBDl17D5'
    '27D/07DBDn17Dp17D/07DBDp17Dr17Dj17DBDj17Dt17Dt17DBDl17Dv17Dv17DBDr37D/'
    '27Dn17DBDp37Dl37Dp17DBDr37Dn37Dt17DBDt37Dl37Dt17DBDv37Dn37Dx17DBDx37D7'
    '17Dx17DBDz37D917D117DBDx37D/17D117DBDz37Dx37D517DBD137Dj27D717DBDp37Dz'
    '37D917DBDn37D337D917DBDr37D537D/17DBDp37D737Dh27DBDv27D/37Dj27DBDx27Dv'
    '27Dl27DBDn27Dh47Dn27DBDp27Dl47Dp27DBDr27D127Dr27DBD327D327Dt27DBD/27D5'
    '27Dv27DBD527Dr47Dx27DBDj37D927Dt47DBDh37Dv47D/27DBD537Dh37D327DBDn37Dj'
    '37D527DBDj37D347D147DBDn37D147D927DBDr37D747Dp37DBDv37Dr37Dr37DBDv37D/'
    '47Dt37DBDt37Dh57D/47DBDj57Dh57Dn37DBDj57Dl57Dp37DBD137Dn57Dr37DBD/37D3'
    '37Dt37DBDz57Dp57Dv37DBD/37D737D737DBD147Dv57D937DBD/47D/37D/37DBDl57Dv'
    '57D337DBDh47D157D537DpBD177D367D7x7DBD967D567D9x7DBE187D767D767D167DBE'
    '387D/67D187Dj87DBE967Dt87D967Dp87DBE/77Dh77D377D/67DBEp87Dl87D767Dj77D'
    'BE777Dl77D567D/67DBE/67Dp87Dn77Dl77DBDn87Dp77D/67DBSp87Dr77Dh77Dz9+Dl9'
    '7Dr77Dr77Dl77Dz9+Dh87Dr77D/67Dl77Dz9+Dj77Dt87Dr77Dp77DBI987Dt77D19+D98'
    '7Dt77Dn97Dt77Dn77DBE187D/y7Dp97Dv77DUBn++DBB/gnDBB/gnDBBx9+DBBx9+DBBn/'
    '+DBBt9+DBBhgnDBBhgnDBBl/uDXB1gvDBB5hvDBB9hvDBBn9+DBBp9+DBB5g/DBB5g/DBB'
    '37+DBB17+DBBpinDBBpinDBB1inDBB1inDBBljnDBBljnDBBtjnDBBtjnDBBpjnDBBpjnD'
    'BBpjnDBBpjnDDB3++DBB1++DBB1gvDBB3gvDBB5gvDBB7gvDBB7++DBB9++DBB/++DBBni'
    '/DBB/knDBBni/DCBxh/DBB1h/DBBth/DBBrj/DBBnkvDBBhj/DBBhj/DBB/9+DBB99+DBB'
    'xknDBBxknDBB3j/DBBzj/DBBtj/DBBtj/DBBrj/DBBvi/DBBti/DBBxi/DCB3g/DBBpk/D'
    'BBpk/DBB1i/DFC/k/Dpi8DBChj8Dri8DBCjl/Dri8DCCnl/Dti8DCCrl/Dvi8DBCtj8Dxi'
    '8DBCvl/Dxi8DBCxj8Dzi8DBCzl/Dzi8DBC1j8D1i8DBC3l/D1i8DBC5j8D3i8DBC7l/D3i'
    '8DBC9j8D5i8DBB9l8DBB9l8DBB/l8DBB/l8DBBhm8DBBhm8DBBjm8DBBjm8DBBlm8DBBlm'
    '8DBBnm8DBBpm8DBBrm8DBBrm8DBBtm8DBBtm8DBBvm8DBBxm8DBBzm8DBBzm8DBB1m8DBB'
    '1m8DBB3m8DBB5m8DBB7m8DBB7m8DBB9m8DBB/m8DBBhn8DBBhn8DBBjn8DBBln8DBBnn8D'
    'BBnn8DBBpn8DBBrn8DBBtn8DBBtn8DBBvn8DBBxn8DBBzn8DBBzn8DBB1n8DBB1n8DBB3n'
    '8DBB3n8DBB5n8DBB5n8DBB7n8DBB7n8DBB9n8DBB/n8DBBho8DBBho8DBBjo8DBBlo8DBB'
    'no8DBBno8DBBpo8DBBro8DBBto8DBBto8DBBvo8DBBxo8DBBzo8DBBzo8DBB1o8DBB3o8D'
    'BB5o8DBB5o8DBB7o8DBB9o8DBB/o8DBB/o8DBBhp8DBBjp8DBBlp8DBBlp8DBBnp8DBBpp'
    '8DBBrp8DBB/o8DBBhp8DBBjp8DBBlp8DBBlp8DBBnp8DBBpp8DBBrp8DBBrp8DBBtp8DBB'
    'vp8DBBxp8DBBxp8DBBzp8DBB1p8DBB3p8DBB3p8DBB5p8DBB7p8DBB9p8DBB9p8DBB/p8D'
    'BBhq8DBBjq8DBBjq8DBBlq8DBBnq8DBBpq8DBBpq8DBBrq8DBBrq8DBBtq8DBBtq8DBBvq'
    '8DBBxq8DBBzq8DBChr8Dlt8DBCjr8Dnt8DBClr8Dnt8DBCnr8Dpt8DBCpr8Dnt8DBCrr8D'
    'pt8DBCtr8Dnt8DBCvr8Dpt8DFB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t'
    '/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB'
    '/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/D'
    'BB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t'
    '/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB'
    '/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/D'
    'BB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t'
    '/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB/t/DBB'
    '/t/DBB/t/DBB/t/DBB/t/DBB/t/DBBz9qDBBz9qDBB91nDBBr1nDBBr1nDBBl2nDBBzmnD'
    'BBnnnDBBrsnDBBpsnDBBnsnDBBlsnDBBjsnDBBxonDBBvonDBBtonDBB3qnDBBnnnDBB9s'
    'nDBB7snDBB5snDBB3snDBB1snDBB1snDBBzsnDBBxsnDBBvsnDBBtsnDBBrsnDBBpsnDBB'
    'nsnDBBlsnDBBjsnDBBhsnDBB/rnDBB7rnDBB5rnDBB3rnDBB1rnDBB1rnDBB1rnDBB1rnD'
    'BB1rnDBB1rnDBBxrnDBBtrnDBBprnDBBlrnDBBhrnDBBhrnDBBhrnDBBhrnDBBhrnDBB/q'
    'nDBB9qnDBB7qnDBB7qnDBB7qnDBB7qnDBB7qnDBB7qnDBB5qnDBBzqnDBBpwnDBBpwnDBB'
    '3jnDBB/mnDBB/mnDBB/mnDBB/mnDBB/mnDBB/mnDBB/mnDBB/mnDBB/mnDBB/mnDBB/mnD'
    'BB/mnDBB/mnDBB/mnDBB/mnDBB/mnDBB/mnDBB/mnDBB/mnDBB/mnDBB/mnDBB/mnDBB/m'
    'nDBB/mnDBB/mnDBB/mnDBB/mnDBB/mnDBB/mnDBB/mnDEBlnnDBBlnnDBBlnnDBBlnnDBB'
    'lnnDBBlnnDDBpnnDBBpnnDBBpnnDBBpnnDBBpnnDBBpnnDDBtnnDBBtnnDBBtnnDBBtnnD'
    'BBtnnDBBtnnDDBxnnDBBxnnDBBxnnDEB7z/DBB7z/DBBrz/DBBnz/DBB7z/DBB/z/DBB5z'
    'vDCBrutDBBxlvDBBxlvDBBxlvDBBxlvDBB5ktDBBlitD7uBCSjshEbCT5thE9MBhriEBBh'
    'riEBB5pjEBB1uiEBBjziECBnuiEBBjiuBBBnuiEBBruiEBBpziEBBpziEBB3/0DBBrziEB'
    'BhziEBBtuiEBB5yiEBB/yiEBBlziEBBxviEBB7mjEBBzviEBB/yiEBBnxiEBB9uiEBB9ui'
    'EBB9yiEBBw2rDBB9gwBBB/yiEBBs2rDBBjxiEBBq2rDBBzqjEBB5yiEBB5yiEBBnzjEBB3'
    'yiEBBi2rDBB1yiEBB1yiEBBzyiEBBlwiEBBrwiEBBrkuBBBtwiEBBtyiEBB9ztDCBlyiEB'
    'BjxiEBBjxiEBB5xiEBBr/iEBBr/iEBBr/iEBBi1rDBBo2rDgnCCBgCCCB8BPCLejECGNBC'
    'GP8QCHZBCJW3BCBsECCBsDJCFoDDCBwD0BCFFCCJdBCLCzHCDBBCFXCCJB8HCDVBCDX9bC'
    'FPp/RCFFBCHOBCJHBCKJBCNJBCJNBCJPBCNPgiDCBBBCLDBCBFs7XBppmHBBppmHBBppmH'
    'BBppmHBBppmHBBppmHBBppmHBBppmHBBppmHBBppmHBBppmHBBppmHBBppmHBBppmHBBpp'
    'mHBBppmHBBppmHBBppmHBBppmHBBppmHBBppmHBBppmHBBppmHBBppmHBBppmHBBppmHBB'
    '/rmHBB/rmHBB/rmHBB/rmHBB/rmHBB/rmHBB/rmHBB/rmHBB/rmHBB/rmHljBCNOBCNMBC'
    'BcBCDcBCFcBCHcBCJc3CCDrFBCDtFBCD9EBCD/EBCH/EBCHhFgSB97pHBB97pHBB97pHBB'
    '97pHBB97pHBB97pHBB97pHBB97pHBB97pHBB97pHBB97pHBB97pHBB97pHBB97pHBB97pH'
    'BB97pHBB97pHBB97pHBB97pHBB97pHBB97pHBB97pHBB97pHBB97pHBB97pHBB97pHBBx7'
    'pHBBx7pHBBx7pHBBx7pHBBx7pHBBx7pHBBx7pHBBx7pHBBx7pHBBx7pHBBx7pHBBx7pHBB'
    'x7pHBBx7pHBBx7pHBBx7pHBBx7pHBBx7pHBBx7pHBBx7pHBBx7pHBBx7pHBBx7pHBBx7pH'
    'BBx7pHBBx7pHBBl/pHBBl/pHBBl/pHBBl/pHBBl/pHBBl/pHBBl/pHBBl/pHBBl/pHBBl/'
    'pHBBl/pHBBl/pHBBl/pHBBl/pHBBl/pHBBl/pHBBl/pHBBl/pHBBl/pHBBl/pHBBl/pHBB'
    'l/pHBBl/pHBBl/pHBBl/pHBBl/pHBB5+pHBB5+pHBB5+pHBB5+pHBB5+pHBB5+pHBB5+pH'
    'CB5+pHBB5+pHBB5+pHBB5+pHBB5+pHBB5+pHBB5+pHBB5+pHBB5+pHBB5+pHBB5+pHBB5+'
    'pHBB5+pHBB5+pHBB5+pHBB5+pHBB5+pHBB5+pHBBtiqHBBtiqHBBtiqHBBtiqHBBtiqHBB'
    'tiqHBBtiqHBBtiqHBBtiqHBBtiqHBBtiqHBBtiqHBBtiqHBBtiqHBBtiqHBBtiqHBBtiqH'
    'BBtiqHBBtiqHBBtiqHBBtiqHBBtiqHBBtiqHBBtiqHBBtiqHBBtiqHBBhiqHBBhiqHBBhi'
    'qHBBhiqHBBhiqHBBhiqHBBhiqHBBhiqHBBhiqHBBhiqHBBhiqHBBhiqHBBhiqHBBhiqHBB'
    'hiqHBBhiqHBBhiqHBBhiqHBBhiqHBBhiqHBBhiqHBBhiqHBBhiqHBBhiqHBBhiqHBBhiqH'
    'BB1lqHCB1lqHBB1lqHDB1lqHDB1lqHBB1lqHDB1lqHBB1lqHBB1lqHBB1lqHCB1lqHBB1l'
    'qHBB1lqHBB1lqHBB1lqHBB1lqHBB1lqHBB1lqHBBplqHBBplqHBBplqHBBplqHCBplqHCB'
    'plqHBBplqHBBplqHBBplqHBBplqHBBplqHBBplqHCBplqHBBplqHBBplqHBBplqHBBplqH'
    'BBplqHBBplqHBBplqHBBplqHBBplqHBBplqHBB9oqHBB9oqHBB9oqHBB9oqHBB9oqHBB9o'
    'qHBB9oqHBB9oqHBB9oqHBB9oqHBB9oqHBB9oqHBB9oqHBB9oqHBB9oqHBB9oqHBB9oqHBB'
    '9oqHBB9oqHBB9oqHBB9oqHBB9oqHBB9oqHBB9oqHBB9oqHBB9oqHBBxoqHBBxoqHBBxoqH'
    'BBxoqHBBxoqHBBxoqHBBxoqHBBxoqHBBxoqHBBxoqHBBxoqHBBxoqHBBxoqHBBxoqHBBxo'
    'qHBBxoqHBBxoqHBBxoqHBBxoqHBBxoqHBBxoqHBBxoqHBBxoqHBBxoqHBBxoqHBBxoqHBB'
    'lsqHBBlsqHCBlsqHBBlsqHBBlsqHBBlsqHDBlsqHBBlsqHBBlsqHBBlsqHBBlsqHBBlsqH'
    'BBlsqHBBlsqHCBlsqHBBlsqHBBlsqHBBlsqHBBlsqHBBlsqHBBlsqHCB5rqHBB5rqHBB5r'
    'qHBB5rqHBB5rqHBB5rqHBB5rqHBB5rqHBB5rqHBB5rqHBB5rqHBB5rqHBB5rqHBB5rqHBB'
    '5rqHBB5rqHBB5rqHBB5rqHBB5rqHBB5rqHBB5rqHBB5rqHBB5rqHBB5rqHBB5rqHBB5rqH'
    'BBtvqHBBtvqHCBtvqHBBtvqHBBtvqHBBtvqHCBtvqHBBtvqHBBtvqHBBtvqHBBtvqHCBtv'
    'qHEBtvqHBBtvqHBBtvqHBBtvqHBBtvqHBBtvqHBBtvqHCBhvqHBBhvqHBBhvqHBBhvqHBB'
    'hvqHBBhvqHBBhvqHBBhvqHBBhvqHBBhvqHBBhvqHBBhvqHBBhvqHBBhvqHBBhvqHBBhvqH'
    'BBhvqHBBhvqHBBhvqHBBhvqHBBhvqHBBhvqHBBhvqHBBhvqHBBhvqHBBhvqHBB1yqHBB1y'
    'qHBB1yqHBB1yqHBB1yqHBB1yqHBB1yqHBB1yqHBB1yqHBB1yqHBB1yqHBB1yqHBB1yqHBB'
    '1yqHBB1yqHBB1yqHBB1yqHBB1yqHBB1yqHBB1yqHBB1yqHBB1yqHBB1yqHBB1yqHBB1yqH'
    'BB1yqHBBpyqHBBpyqHBBpyqHBBpyqHBBpyqHBBpyqHBBpyqHBBpyqHBBpyqHBBpyqHBBpy'
    'qHBBpyqHBBpyqHBBpyqHBBpyqHBBpyqHBBpyqHBBpyqHBBpyqHBBpyqHBBpyqHBBpyqHBB'
    'pyqHBBpyqHBBpyqHBBpyqHBB91qHBB91qHBB91qHBB91qHBB91qHBB91qHBB91qHBB91qH'
    'BB91qHBB91qHBB91qHBB91qHBB91qHBB91qHBB91qHBB91qHBB91qHBB91qHBB91qHBB91'
    'qHBB91qHBB91qHBB91qHBB91qHBB91qHBB91qHBBx1qHBBx1qHBBx1qHBBx1qHBBx1qHBB'
    'x1qHBBx1qHBBx1qHBBx1qHBBx1qHBBx1qHBBx1qHBBx1qHBBx1qHBBx1qHBBx1qHBBx1qH'
    'BBx1qHBBx1qHBBx1qHBBx1qHBBx1qHBBx1qHBBx1qHBBx1qHBBx1qHBBl5qHBBl5qHBBl5'
    'qHBBl5qHBBl5qHBBl5qHBBl5qHBBl5qHBBl5qHBBl5qHBBl5qHBBl5qHBBl5qHBBl5qHBB'
    'l5qHBBl5qHBBl5qHBBl5qHBBl5qHBBl5qHBBl5qHBBl5qHBBl5qHBBl5qHBBl5qHBBl5qH'
    'BB54qHBB54qHBB54qHBB54qHBB54qHBB54qHBB54qHBB54qHBB54qHBB54qHBB54qHBB54'
    'qHBB54qHBB54qHBB54qHBB54qHBB54qHBB54qHBB54qHBB54qHBB54qHBB54qHBB54qHBB'
    '54qHBB54qHBB54qHBBt8qHBBt8qHBBt8qHBBt8qHBBt8qHBBt8qHBBt8qHBBt8qHBBt8qH'
    'BBt8qHBBt8qHBBt8qHBBt8qHBBt8qHBBt8qHBBt8qHBBt8qHBBt8qHBBt8qHBBt8qHBBt8'
    'qHBBt8qHBBt8qHBBt8qHBBt8qHBBt8qHBBh8qHBBh8qHBBh8qHBBh8qHBBh8qHBBh8qHBB'
    'h8qHBBh8qHBBh8qHBBh8qHBBh8qHBBh8qHBBh8qHBBh8qHBBh8qHBBh8qHBBh8qHBBh8qH'
    'BBh8qHBBh8qHBBh8qHBBh8qHBBh8qHBBh8qHBBh8qHBBh8qHBB1/qHBB1/qHBB1/qHBB1/'
    'qHBB1/qHBB1/qHBB1/qHBB1/qHBB1/qHBB1/qHBB1/qHBB1/qHBB1/qHBB1/qHBB1/qHBB'
    '1/qHBB1/qHBB1/qHBB1/qHBB1/qHBB1/qHBB1/qHBB1/qHBB1/qHBB1/qHBB1/qHBBp/qH'
    'BBp/qHBBp/qHBBp/qHBBp/qHBBp/qHBBp/qHBBp/qHBBp/qHBBp/qHBBp/qHBBp/qHBBp/'
    'qHBBp/qHBBp/qHBBp/qHBBp/qHBBp/qHBBp/qHBBp/qHBBp/qHBBp/qHBBp/qHBBp/qHBB'
    'p/qHBBp/qHBB9irHBB9irHBB9irHBB9irHBB9irHBB9irHBB9irHBB9irHBB9irHBB9irH'
    'BB9irHBB9irHBB9irHBB9irHBB9irHBB9irHBB9irHBB9irHBB9irHBB9irHBB9irHBB9i'
    'rHBB9irHBB9irHBB9irHBB9irHBBxirHBBxirHBBxirHBBxirHBBxirHBBxirHBBxirHBB'
    'xirHBBxirHBBxirHBBxirHBBxirHBBxirHBBxirHBBxirHBBxirHBBxirHBBxirHBBxirH'
    'BBxirHBBxirHBBxirHBBxirHBBxirHBBxirHBBxirHBBl3qHBB7mqHDBtxpHBBtxpHBBtx'
    'pHBBtxpHBBtxpHBBtxpHBBtxpHBBtxpHBBtxpHBBtxpHBBtxpHBBtxpHBBtxpHBBtxpHBB'
    'txpHBBtxpHBBtxpHBBpspHBBtxpHBBtxpHBBtxpHBBtxpHBBtxpHBBtxpHBBtxpHBBzr6G'
    'BBhxpHBBhxpHBBhxpHBBhxpHBBhxpHBBhxpHBBhxpHBBhxpHBBhxpHBBhxpHBBhxpHBBhx'
    'pHBBhxpHBBhxpHBBhxpHBBhxpHBBhxpHBBhxpHBBhxpHBBhxpHBBhxpHBBhxpHBBhxpHBB'
    'hxpHBBhxpHBBxt6GBBtupHBB3wpHBB7upHBBzwpHBB9upHBB1wpHBBh1pHBBh1pHBBh1pH'
    'BBh1pHBBh1pHBBh1pHBBh1pHBBh1pHBBh1pHBBh1pHBBh1pHBBh1pHBBh1pHBBh1pHBBh1'
    'pHBBh1pHBBh1pHBB9vpHBBh1pHBBh1pHBBh1pHBBh1pHBBh1pHBBh1pHBBh1pHBBnv6GBB'
    '10pHBB10pHBB10pHBB10pHBB10pHBB10pHBB10pHBB10pHBB10pHBB10pHBB10pHBB10pH'
    'BB10pHBB10pHBB10pHBB10pHBB10pHBB10pHBB10pHBB10pHBB10pHBB10pHBB10pHBB10'
    'pHBB10pHBBlx6GBBhypHBBr0pHBBvypHBBn0pHBBxypHBBp0pHBB14pHBB14pHBB14pHBB'
    '14pHBB14pHBB14pHBB14pHBB14pHBB14pHBB14pHBB14pHBB14pHBB14pHBB14pHBB14pH'
    'BB14pHBB14pHBBxzpHBB14pHBB14pHBB14pHBB14pHBB14pHBB14pHBB14pHBB7y6GBBp4'
    'pHBBp4pHBBp4pHBBp4pHBBp4pHBBp4pHBBp4pHBBp4pHBBp4pHBBp4pHBBp4pHBBp4pHBB'
    'p4pHBBp4pHBBp4pHBBp4pHBBp4pHBBp4pHBBp4pHBBp4pHBBp4pHBBp4pHBBp4pHBBp4pH'
    'BBp4pHBB506GBB11pHBB/3pHBBj2pHBB73pHBBl2pHBB93pHBBp8pHBBp8pHBBp8pHBBp8'
    'pHBBp8pHBBp8pHBBp8pHBBp8pHBBp8pHBBp8pHBBp8pHBBp8pHBBp8pHBBp8pHBBp8pHBB'
    'p8pHBBp8pHBBl3pHBBp8pHBBp8pHBBp8pHBBp8pHBBp8pHBBp8pHBBp8pHBBv26GBB97pH'
    'BB97pHBB97pHBB97pHBB97pHBB97pHBB97pHBB97pHBB97pHBB97pHBB97pHBB97pHBB97'
    'pHBB97pHBB97pHBB97pHBB97pHBB97pHBB97pHBB97pHBB97pHBB97pHBB97pHBB97pHBB'
    '97pHBBt46GBBp5pHBBz7pHBB35pHBBv7pHBB55pHBBx7pHBB9/pHBB9/pHBB9/pHBB9/pH'
    'BB9/pHBB9/pHBB9/pHBB9/pHBB9/pHBB9/pHBB9/pHBB9/pHBB9/pHBB9/pHBB9/pHBB9/'
    'pHBB9/pHBB56pHBB9/pHBB9/pHBB9/pHBB9/pHBB9/pHBB9/pHBB9/pHBBj66GBBx/pHBB'
    'x/pHBBx/pHBBx/pHBBx/pHBBx/pHBBx/pHBBx/pHBBx/pHBBx/pHBBx/pHBBx/pHBBx/pH'
    'BBx/pHBBx/pHBBx/pHBBx/pHBBx/pHBBx/pHBBx/pHBBx/pHBBx/pHBBx/pHBBx/pHBBx/'
    'pHBBh86GBB98pHBBn/pHBBr9pHBBj/pHBBt9pHBBl/pHBB7+pHBB7+pHDB75rHBB75rHBB'
    '75rHBB75rHBB75rHBB75rHBB75rHBB75rHBB75rHBB75rHBBv6rHBBv6rHBBv6rHBBv6rH'
    'BBv6rHBBv6rHBBv6rHBBv6rHBBv6rHBBv6rHBBj7rHBBj7rHBBj7rHBBj7rHBBj7rHBBj7'
    'rHBBj7rHBBj7rHBBj7rHBBj7rHBB37rHBB37rHBB37rHBB37rHBB37rHBB37rHBB37rHBB'
    '37rHBB37rHBB37rHBBr8rHBBr8rHBBr8rHBBr8rHBBr8rHBBr8rHBBr8rHBBr8rHBBr8rH'
    'BBr8rHxhCB//tHBB//tHBB//tHBB//tHBB//tHBB//tHBB//tHBB//tHBB//tHBB9/tHBB'
    '9/tHBB9/tHBB7/tHBB7/tHBB7/tHBB7/tHBB7/tHBB7/tHBB7/tHBB7/tHBB7/tHBB7/tH'
    'BB7/tHBB3/tHBB1/tHBB1/tHBBh88EBBj3tHBBr/tHBBp/tHBBp2tHBB/5tHBBh4tHBBhi'
    'uHBBhiuHBBhiuHBBhiuHBBhiuHBBhiuHBBhiuHBBhiuHBBhiuHBB/huHBB/huHBB7huHBB'
    '7huHBB5huHBB3huHBB3huHBB3huHBB3huHBB3huHBB3huHBB1huHBB1huHBBr9tHBBjhuH'
    'BBnhuHBB1guHBB/7tHBB1h9EBB37tHzsDBx9zHBBx9zHBBr9zHBBn9zHCB57zHBBn9zHBB'
    'z9zHBBh9zHBB97zHBBt8zHBBt8zHBBt8zHBBt8zHBB19zHBBr9zHBB98zHBB39zHBB/8zH'
    'BBj+zHBB/9zHBB1+zHBB1+zHBBx+zHBBv+zHBBl+zHBBj+zHBBh+zHBB76zHBBl2zHBB53'
    'zHBB/6zHCBx/zHBBr/zHCB59zHDBz/zHCB99zHBBt+zHBBt+zHBBt+zHBBt+zHBB1/zHBB'
    'r/zHBB9+zHBB3/zHBB/+zHCB//zHBB1g0HBB1g0HBBxg0HCBlg0HCBhg0HHBrh0HFBzh0H'
    'CB9/zHCBtg0HCBtg0HBB1h0HBBrh0HCB3h0HBB/g0HCB/h0HDBxi0HCBli0HCBhi0HCBl6'
    'zHCB/+zHCBxj0HBBrj0HCB5h0HDBzj0HBBhj0HBB9h0HBBti0HCBti0HBBti0HBB1j0HBB'
    'rj0HBB9i0HBB3j0HBB/i0HCB/j0HBB1k0HBB1k0HBBxk0HCBlk0HBBjk0HBBhk0HBB7g0H'
    'CB59zHCBxl0HBBxl0HBBrl0HBBnl0HBB5j0HBB5j0HBBnl0HBBzl0HBBhl0HBB9j0HCBtk'
    '0HBBtk0HBBtk0HBB1l0HBBrl0HBB9k0HBB3l0HBB/k0HBBjm0HBB/l0HBB1m0HBB1m0HBB'
    'xm0HBBvm0HBBlm0HBBjm0HBBhm0HGBxn0HBBrn0HBBnn0HCB5l0HBBnn0HBBzn0HBBhn0H'
    'BB9l0HCBtm0HBBtm0HBBtm0HBB1n0HBBrn0HBB9m0HBB3n0HBB/m0HBBjo0HBB/n0HBB1o'
    '0HBB1o0HBBxo0HBBvo0HBBlo0HBBjo0HBBho0HlSC/s4Hjt4HBCht4Hpt4HBCht4Hrt4HB'
    'Cht4Htt4HBCht4Hvt4HBCht4Hxt4HBCht4Hzt4HBCht4H1t4HBCht4H3t4HBCht4H5t4HB'
    'Cht4H7t4HGDvu4H9s4Htu4HBDxu4H9s4Hvu4HBDzu4H9s4Hxu4HBD1u4H9s4Hzu4HBD3u4'
    'H9s4H1u4HBD5u4H9s4H3u4HBD7u4H9s4H5u4HBD9u4H9s4H7u4HBD/u4H9s4H9u4HBDhv4'
    'H9s4H/u4HBDjv4H9s4Hhv4HBDlv4H9s4Hjv4HBDnv4H9s4Hlv4HBDpv4H9s4Hnv4HBDrv4'
    'H9s4Hpv4HBDtv4H9s4Hrv4HBDvv4H9s4Htv4HBDxv4H9s4Hvv4HBDzv4H9s4Hxv4HBD1v4'
    'H9s4Hzv4HBD3v4H9s4H1v4HBD5v4H9s4H3v4HBD7v4H9s4H5v4HBD9v4H9s4H7v4HBD/v4'
    'H9s4H9v4HBDhw4H9s4H/v4HBDrxgHtt4HpxgHBBvu4HBBzt4HBCzu4Hxu4HBCtt4Hnt4HC'
    'B9u4HBB9u4HBB9u4HBB9u4HBB9u4HBB9u4HBB9u4HBB9u4HBB9u4HBB9u4HBB9u4HBB9u4'
    'HBB9u4HBB9u4HBB9u4HBB9u4HBB9u4HBB9u4HBB9u4HBB9u4HBB9u4HBB9u4HBB9u4HBB9'
    'u4HBB9u4HBB9u4HBCjw4Hnv4HBC7v4Hpv4HBCxv4Hvw4HBCzv4Hzv4HBD7v4H7v4Hvv4HB'
    'Cvv4H3w4HbC5x4Hty4HBC7x4Hty4HBC9x4Hzx4HkBC304Hr04HwDCp4gHp7gHBC70gH70g'
    'HBB50gHOBp8nGBBzrrGBBrkvGBB30gHBBv4xGBB1vsGBBlj0FBB7usGBBn3xGBBx/lGBBx'
    'vgGBBjomGBB98vGBBhppGBBhpwGBB9mmGBBlgwGBB9t6FBBlw+FBBz3yFBBnzsGBB3+uGB'
    'BjxhGBBj5nGBBltnGBBxiyGBBhiyGBBh+wFBBrkqGBB//xGBB1jvGBBvynGBB/ryFBB79n'
    'GBBhr8FBBx77FBB3ivGBBp7hGBB5ylGBB9ylGBBpw+FBBt8vGBBnouGBB7uwFFD3ihHnxl'
    'G1ihHBD5ihHvjyG3ihHBD7ihHr7xG5ihHBD9ihHzrrG7ihHBD/ihH14gG9ihHBDhjhHj/n'
    'G/ihHBDjjhH929FhjhHBDljhHz2vGjjhHBDnjhHhvmGljhHIBxrpGBBjmvG/sCB/79HBB/'
    '79HBB/79HBB/79HBB/79HBB/79HBB/79HBB/79HBB/79HBB/79Hng/BBl80KBBx80KBBh8'
    '0KBBhu7DBBnq0KBBtl0KBB1k0KBBpg0KBB74zKBB/2zKBBlyzKBB3zzKBB72hLBBl94DBB'
    'hszKBB1rzKBB3qzKBBzpzKBBrv5DBBz1hLBB5qzKBBvozKBB1s5DBB/nzKBBnnzKBB500K'
    'BB7mzKBBrmzKBB5jzBBBvizKBB1hzKBB/zhLBBp+yKBB19yKBB/6yKBB36yKBB9whLBB71'
    'yKBB51yKBBl0yKBB7yyKBBnyyKBBnyyKBBnxyKBBluyKBB3tyKBBntyKBB3ryKBBlryKBB'
    'jryKBBlryKBBnryKBBvg3DBBp8jKBB3myKBBvlyKBBpt2DBB7kyKBBxkyKBBpjyKBB75xK'
    'BBpgyKBBr/xKBBt9xKBB75xKBB10xKBBjzxKBB/uxKBBhuxKBBhsxKBBjsxKBB7qxKBB5p'
    'xKBBrpxKBBvoxKBBpzwKBBrkxKBBrzwKBB5/wKBB19wKBBxkzKBBl2vKBBnowKBB9lwKBB'
    'tkwKBBzswKBBniwKBBriwKBB36vKBBp3xDBBv2vKBBn2vKBBr1vKBBl0vKBB3zvKBB5vvK'
    'BBv7wDBBt3wDBBrnvKBBvkvKBB5jvKBB5ovKBB//uKBBx3gLBB32gLBBh2uKBB3yuKBB5y'
    'uKBBnqvDBBzquKBBrpuKBBvouKBB5nuKBBx1uDBBlnuKBB5muKBBhysKBBlluKBBpvgLBB'
    'thuKBBzguKBBx7tKBB5+tKBBtptDBBxztKBBtptDBB/wtKBBnxtKBBnwtKBB/ptKBB/ptK'
    'BBnlgLBBtotKBB5ltKBBxktKBB7htKBBrigLBBrwrDBB7ggLBB19sKBBx9sKBBt9sKBBn8'
    'sKBB5vqBBBj5sKBB/1qDBBh2qDBBjp7JBBj3sKBBl3sKBB98/KBB99iDBB7rrCBBtzsKBB'
    '9ysKBBv7/KBBjwsKBB/ssKBBtssKBBrqsKBB9hsKBBt2/KBBr4/KBB9gsKBB/8oDBB79rK'
    'BB71rKBB11rKBBz1rKBB51rKBB/yrKBB5xrKBBzvrKBBxwrKBB9vrKBBhtrKBB7rrKBB1r'
    'rKBBjqrKBBvprKBBtlrKBBngrKBBj+qKBBt2qKBB36mDBB33qKBB77qKBBl1qKBBxzqKBB'
    'xtqKBB5smDBB5pqKBB1vqKBBvxqKBBnp/KBBzlqKBBrkqKBBviqKBB9kqKBB1l/KBBx3pK'
    'BB51pKBB/rkDBBvupKBBn9oKBBnopKBBp7+KBB7jpKBBv8+KBB5++KBB/zzKBB7zzKBBn9'
    'oKBBxjpKBBxi8JBB7v6KBBh8oKBB77oKBBx7oKBB53oKBBx4oKBBzxiDBBp5+KBBpuoKBB'
    '11oKBB9ooKBB5loKBBrniDBBrloKBBrsoKBBj9nKBBz0+KBBr6nKBBr0nKBB/vnKBBlknK'
    'BBxkhDBBjhnKBBrt+KBB78mKBBxkgDBB55mKBBnq+KBBh4mKBBp1mKBB1zmKBB1zmKBBzm'
    '/CBB5+tDBB9/+CBB3qmKBB9j+CBB5jmKBB/imKBBtpmKBBx+lKBBj8lKBBz4lKBBh8lKBB'
    'z5lKBB34lKBB/3lKBBv+9CBBl9lKBBxtlKBB1plKBBt99KBB/jlKBBpklKBB3j9CBBpxlK'
    'BBh6kKBBj78CBBl48CBB30kKBBztkKBBrvkKBBzvkKBB/39KBB5skKBB1pkKBBjqkKBB5m'
    'kKBBr/5DBBt9jKBBzr7CBBj4jKBBn36CBBvvjKBB3ujKBBjtjKBB1x5CBBnqjKBB/ojKBB'
    'h/4CBBlx4CBB76iKBB75iKBB7n9KBBr4iKBBnn9KBBpn9KBBtuiKBBltiKBB9riKBB3qiK'
    'BBvmiKBBvh9KBB/giKBB9v2CBBv/hKBBpq2CBBv8hKBBz5rDBBzyhKBBz50CBBn40CBBxv'
    '0CBBj08KBBtz8KBB3khKBB7k0CBB/k0CBBzi0CBBhh0CBBtihKBBtihKBBvihKBB7/gKBB'
    '/w8KBB97gKBBpw8KBBrr8KBB/yyCBB/vgKBBlsgKBBnogKBB7m8KBB3yxCBB5//JBBzrxC'
    'BB/oxCBBt8/JBB32/JBBxi8KBBxx/JBB/w/JBB3w/JBB/9vCBBrrvCBBtrvCBBhn/JBB71'
    '7KBBr7uCBB35+JBBz5+JBB5z7KBBpuuCBBnp+JBBts7KBB/n+JBBro+JBBzm+JBBp+sCBB'
    'xg+JBB3m7KBBt69JBB529JBB1y9JBB5j7KBBz0rCBB3yrCBB1h7KBB3prCBB3/8JBBxjrC'
    'BBl+8JBB938JBBp38JBBhqqCBBxlqCBB5x8JBBr9pCBB9w8JBBhijDBB366KBB/s8JBB/n'
    '8JBBx36KBBtk8JBBhtvKBB/9oCBBl9oCBBr/iDBB7+iDBBz47JBBv47JBB9+0JBBly6KBB'
    '7v7JBBpw7JBBnv7JBB9tzKBBju7JBBhu7JBBvt7JBB/q7JBB1lnCBBlr7JBB3n7JBBtj7J'
    'BB7+6JBBxn7JBB/96JBBt76JBBv06JBB5k7JBBt96JBBr96JBBt86JBB72mCBBzjmCBBht'
    'mCBB3n6KBBtr6JBBrr6JBBnp6JBBh+iCBBvk6JBBholCBBhl6KBB7k6KBB9/kCBB9tkCBB'
    'tk6KBBl25JBBv15JBB705JBB505JBB7w5JBB/y5JBB1q5JBBvt5JBBjk5JBBnp5JBBjl5J'
    'BBvj5JBBv+5KBB994JBB/74JBBx85KBBl24JBBh24JBB71hCBB9u4JBBxu4JBBl55KBB9s'
    '4JBB9wiLBB5xgCBBrmgCBB9w5KBBtw5KBB9y3JBBlu3JBBtk3JBB532JBB1y+BBBxy2JBB'
    'nx2JBB1r2JBB/l2JBBxq9BBBp94DBB9g2JBB9h2JBB3+1JBB9v4DBBzw1JBBtq1JBB7g6B'
    'BBn/5BBB700JBBjv0JBBlt0JBBtr5BBB1s0JBB96zJBBhxzJBBhxzJBB72zJBBj/yJBBt9'
    'yJBBl/2BBBlmyJBBzl4KBBxjyJBBzn2BBB3g4KBB/yxJBBjkuKBBjtxJBBhr0BBB59zBBB'
    'z43KBBl43KBBzhxJBBh/yBBBz03KBBt2yBBBl/wJBBn/wJBBt9wJBB1kyBBB/xwJBB/s3K'
    'BB1twJBB7lwJBBnkwJBBxgwJBBzj3KBBxtvBBBvvvJBB18uJBB9wuJBB9z2KBBhy2KBBvq'
    'uJBBj0sBBBxx2KBB5wsBBBpgsBBBl4rBBBz1tJBB/r2KBB7xtJBBzxtJBBnxtJBB1wtJBB'
    'pwtJBBhutJBB5hqB';
