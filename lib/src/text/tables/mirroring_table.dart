// GENERATED FILE - DO NOT EDIT.
//
// Source:     referencias/unicode/ucd.nounihan.flat.xml
// UCD:        17.0.0
// Regenerate: dart run tool/generate_unicode_tables.dart

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

/// Bidi_Paired_Bracket_Type (`bpt`).
///
/// The member order is the one the generated table encodes. Reordering the
/// members silently re-labels every code point, so the enum and the table
/// are generated together and have to be regenerated together.
enum BracketType {
  /// Not a paired bracket.
  none,

  /// An opening paired bracket.
  open,

  /// A closing paired bracket.
  close;
}

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

/// Bidi_Mirrored and Bidi_Paired_Bracket_Type, packed. 331 runs.
const String _mirrorFlagTable =
    'AAoBDBFBASBBABBBAcDBABFBAdDBABFBAtBBBAPBBA+zDDBFBDBFBA96BDBFBA8sCBCAKD'
    'BFBA2BDBFBAODBFBAxFBBAgGBEADBGADBBADBCADBEABBEABBBABBBAEBJAFBBABBSAFBE'
    'AJBCABBBABBIABBgBACBEAFBBAJBCACBTAFBCAJBFACBCAEBYACBQAIDBFBDBFBAUBCAHD'
    'BFBA9hBDBFBDBFBDBFBDBFBDBFBDBFBDBFBAqCBBACBCDBFBABBCABBDAFBEAFBDADBEDB'
    'FBDBFBDBFBDBFBDBFBAzMDBFBDBFBDBFBDBFBDBFBDBFBDBFBDBFBDBFBDBFBDBFBACBGA'
    'BBOAIBBAHBGADBBAEBFABBCACDBFBDBFBBBAEBBABBDACBCAKBGACDBFBAMBTABBEACBBA'
    'BBBACBBABBEAFBCAGBDAYBCALBCAEBEABBCACBCAEBrBACBIABBoBAFBBABBBADBFAFBDA'
    'EBBADBFABBBAgIBBAjQBEADBCABBCAOBCACBCDBFBDBFBDBFBDBFBArBDBFBDBFBDBFBDB'
    'FBArNDBFBDBFBDBFBDBFBDBFBACDBFBDBFBDBFBDBFBA9xzBDBFBDBFBDBFBAFBCAiFDBF'
    'BASBBABBBAcDBABFBAdDBABFBABDBFBABDBFBA371BBBA5BBBA5BBBA5BBBA5BBBA';

/// Bidi_Mirroring_Glyph. 428 entries.
const String _mirrorGlyphTable =
    'oBCBBTECDdECDeECDuBgBQf/zDCBBBCBB+6BCBB9sCCBBLCBB3BCBBPCBB6LGBGBGBFBFB'
    'FIg+DK+9EBm4DB03DB83DC0sEYCBBG0ICOHNGCBBBCBBPCBBBCBBBCBBBCBBDCBBBCBBBC'
    'BBBCBBBCBBBCBBBCBBBCBBBCBBBCBBBCBBBCBBBCBBBCBBBCBBECBBBCBBGgyDKCBBDwjE'
    'C4jEB0jEC0jEFCBBBCBBBCBBBCBBBoyCRCBBBCBBBzIDCBBFCBBBCBBBCBBBCBBBCBBBCB'
    'BBCBBBCBBBCBBBCBBBCBBBCBBDCBBBQBQBQCOBODPBPBPBNBNKCBBBCBBeCBB+hBCBBBCB'
    'BBCBBBCBBBCBBBCBBBCBBuCCBBBCBBCCBBCECDICBBGnyCBCBBECBBBCBBBCBBBCBBBCBB'
    'BCBBBCBB0MCBBBCBBBCBBBCBBBCBBBGBCBBBFBCBBBCBBBCBBBCBBDz3DF73DDl4DBCBBD'
    'CBBBCBBBCBBBCBBJ/xDICBBDCBBKCBBBCBBCCBBDCBBBCBBNCBBM/9DDCBBDCBBuBCBBBC'
    'BBGCBBHCBBnBCBBUCBBBCBBBCBBBCBBBCBBBCBBBCBBBCBBBCBBBCBBBCBBBCBBBCBBBCB'
    'BBCBBBCBBBCBBBCBBBCBBBCBBBCBBECBBBCBBBCBBBCBBCCBBBCBBBCBBBCBBBCBBBCBBB'
    'CBBBCBBBCBBBCBBBCBBBCBBBCBBBCBBBCBBBCBBBCBBBCBBBCBBBCBBIvjEFzjEB3jEBzj'
    'EHCBBBzsEJCBBBCBBkI99EkQCBBBCBBECBBCCBBPCBBDCBBBCBBBCBBBCBBBCBBsBCBBBC'
    'BBBCBBBCBBsNCBBBCBBBCBBBCBBBCBBDCBBBCBBBCBBBCBB+xzBCBBBCBBBCBBGCBBjFCB'
    'BTECDdECDeECDCCBBCCBB';

/// Bidi_Paired_Bracket. 128 entries.
const String _pairedBracketTable =
    'oBCBByBECDeECD91DCBBBCBB+6BCBBptCCBB3BCBBPCBB6TCBBBCBBeCBB+hBCBBBCBBBC'
    'BBBCBBBCBBBCBBBCBBwCCBBgBCBBBCBBBCBBBCBBBCBB0MCBBBCBBBCBBBCBBBCBBBGBCB'
    'BBFBCBBBCBBBCBBBCBBgCCBBBCBBhBCBBlhBCBBBCBBBCBBBCBBsBCBBBCBBBCBBBCBBsN'
    'CBBBCBBBCBBBCBBBCBBDCBBBCBBBCBBBCBB+xzBCBBBCBBBCBBqFCBByBECDeECDCCBBCC'
    'BB';
