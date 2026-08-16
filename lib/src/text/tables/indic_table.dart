// GENERATED FILE - DO NOT EDIT.
//
// Source:     referencias/unicode/ucd.nounihan.flat.xml
// UCD:        17.0.0
// Regenerate: dart run tool/generate_unicode_tables.dart

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

/// What a character is, in Brahmic terms.
///
/// The member order is the one the generated table encodes. Reordering the
/// members silently re-labels every code point, so the enum and the table
/// are generated together and have to be regenerated together.
enum IndicSyllabicCategory {
  avagraha,
  bindu,
  brahmiJoiningNumber,
  cantillationMark,
  consonant,
  consonantDead,
  consonantFinal,
  consonantHeadLetter,
  consonantInitialPostfixed,
  consonantKiller,
  consonantMedial,
  consonantPlaceholder,
  consonantPrecedingRepha,
  consonantPrefixed,
  consonantSubjoined,
  consonantSucceedingRepha,
  consonantWithStacker,
  geminationMark,
  invisibleStacker,
  joiner,
  modifyingLetter,
  nonJoiner,
  nukta,
  number,
  numberJoiner,
  other,
  pureKiller,
  registerShifter,
  reorderingKiller,
  syllableModifier,
  toneLetter,
  toneMark,
  virama,
  visarga,
  vowel,
  vowelDependent,
  vowelIndependent;
}

/// Where a dependent character is drawn relative to its base.
///
/// [IndicPositionalCategory.na] means the question does not apply,
/// which is the value of every character outside the Brahmic scripts.
///
/// The member order is the one the generated table encodes. Reordering the
/// members silently re-labels every code point, so the enum and the table
/// are generated together and have to be regenerated together.
enum IndicPositionalCategory {
  bottom,
  bottomAndLeft,
  bottomAndRight,
  left,
  leftAndRight,
  na,
  overstruck,
  right,
  top,
  topAndBottom,
  topAndBottomAndLeft,
  topAndBottomAndRight,
  topAndLeft,
  topAndLeftAndRight,
  topAndRight,
  visualOrderLeft;
}

final RangeTable _syllabic = RangeTable(_indicSyllabicTable);
final RangeTable _positional = RangeTable(_indicPositionalTable);

/// The Indic_Syllabic_Category of [codePoint].
IndicSyllabicCategory indicSyllabicCategoryOf(int codePoint) =>
    IndicSyllabicCategory.values[_syllabic.lookup(codePoint)];

/// The Indic_Positional_Category of [codePoint].
IndicPositionalCategory indicPositionalCategoryOf(int codePoint) =>
    IndicPositionalCategory.values[_positional.lookup(codePoint)];

/// Indic_Syllabic_Category for the whole code space. 1154 runs.
const String _indicSyllabicTable =
    'AZtBLBZCXKZmDLBZRdCZjBLBZohCBDhBBkBRElBjBCWBABjBPgBBjBCZBDCZCjBDEIkBCj'
    'BCZCXKZCkBGEILBBChBBZBkBIZCkBCZCkBCEUZBEHZBEBZDEEZCWBABjBHZCjBCZCjBCgB'
    'BFBZIjBBZEECZBEBkBCjBCZCXKECZKBBZBdBZCBChBBZBkBGZEkBCZCkBCEUZBEHZBECZB'
    'ECZBECZCWBZBjBFZEjBCZCjBCgBBZDDBZHEEZBEBZHXKBBRBLCZBKBZLBChBBZBkBJZBkB'
    'DZBkBCEUZBEHZBECZBEFZCWBABjBIZBjBDZBjBCgBBZSkBCjBCZCXKZJEBDBRBDBWDZBBC'
    'hBBZBkBIZCkBCZCkBCEUZBEHZBECZBEFZCWBABjBHZCjBCZCjBCgBBZHjBDZEECZBEBkBC'
    'jBCZCXKZBEBZQBBUBZBkBGZDkBDZBkBDEBZDECZBEBZBECZDECZDEDZDEMZEjBFZDjBDZB'
    'jBDgBBZJjBBZOXKZQBDhBBBBkBIZBkBDZBkBDEUZBEQZCWBABjBHZBjBDZBjBDgBBZHjBC'
    'ZBEDZCFBZCkBCjBCZCXKZQBDhBBZBkBIZBkBDZBkBDEUZBEKZBEFZCWBABjBHZBjBDZBjB'
    'DgBBZHjBCZGFBEBZBkBCjBCZCXKZBQCBBZMBDhBBBBkBIZBkBDZBkBDEmBaCABjBHZBjBD'
    'ZBjBDgBBMBZFFDjBBZHkBDjBCZCXKZKFGZBBChBBZBkBSZDEYZBEJZBEBZCEHZDgBBZEjB'
    'GZBjBBZBjBIZGXKZCjBCZNEuBZBjBKaBZFjBGZBjBBfEJBBBaBZBXKZnBECZBEBZBEFZBE'
    'YZBEBZBEIZBjBKaBjBBKCZCjBFZDfEZBBBdBZBXKZCEEZgCXUZBdBZBdBZBWBZGEIZBEkB'
    'ZEjBNBBhBBjBCBCaBABZCHFOLZBOkBZJdBZ5BEhBkBKjBLBBfBhBBSBaBKEEBXKZBLBZCL'
    'BZBECkBEjBEEEKDEBjBBfCECjBCfFEDjBEENKBjBEfHEBfBXKfCjBCZizBkBDEPjBCaCZJ'
    'EBkBDEPjBCaBZLkBDEPjBCZMkBDEKZBEDZBjBCZMEjBkBRZCjBQBBhBBjBBbCdBPBJBdDa'
    'BSBdBZIABdBZCXKZ2IEfZBjBJODZEGCBBGHjBBdBZKXKETiBLZCeFZLEsBZEjBRGHfCZGX'
    'LZlBEXjBFZEEtBkBGECKCOBGCIBOEZBSBjBTBBfFaBdCZCdBXKZGXKZmDBDGBhBBkBOEhB'
    'WBjBPgBBEIZDXKZmBBBGBhBBkBHEXODjBGaBSBOCECXKABEDGCEkBkBCWBjBJGCcCZMEkB'
    'OCjBHGHBCdBWBZIXKZDEDZgEDDZBDOZQFCDBQCDDLBZgIdBZwQVBTBZCLFZ/CdBZNdDZrD'
    'DBZ7mBLBZzxgBkBCjBBkBDgBBEEBBEXjBFZEaBZTEeiBEEEiBBOCEIOBEBBBZMBBhBBkBQ'
    'EiBKBjBPgBBBBZKXKZGDSBCZKkBBjBBXKEYiBJfDZCEXjBIGEaBZsBBCGBhBBkBFEDkBDE'
    'kBWBjBJKDgBBZPXKZGEFjBBZBEJXKEFZBkBGEjBjBKKEZJGOZCXKZGEQZBEDLDZDEBfDEy'
    'BjBPfBeBfBeBZdkBCEJjBFZFhBBSBZpGEOkBCEBkBBEJGIjBIZBfBaBZCXKZmwXEBjBDZB'
    'jBCZFjBCBBhBBEEZBEDZBEdZCWDZESBXJZ3tBBChBBQCkBOElBjBOgBBZLCUXKaBkBCjBC'
    'EBZJYBBChBBkBKEjBjBJgBBWBZHjBBZ9BBChBBkBEEgBjBMSBaBZBXKZEEBjBCEBZIiBFE'
    'eWBZMBChBBkBOEiBjBNgBBABNCZFdBWBjBCZBjBBBBXKZHXUZLkBIEKZBEZjBIBBgBBWBR'
    'BZGDBEBkBBjBBZ+BkBEEDZBEBZBEEZBEPZBEKZHkBKElBBBjBJWBaBZFXKZGBDhBBZBkBI'
    'ZCkBCZCkBCEUZBEHZBECZBEFZBWCABjBHZCjBCZCjBCgBBZJjBBZGBCkBCjBCZCDHZDDFZ'
    'LkBKZBkBBZCkBBZBkBCEkBZBABjBJZBjBBZCjBBZBjBDBBZBBBhBBaCSBMBRBZODCZdkBO'
    'EnBjBNgBBBChBBWBABZIXKZEdBBBQCZfkBOEhBjBPBChBBgBBWBABZLXKZmFkBOEhBjBHZ'
    'CjBEBChBBgBBWBZXkBEjBCZiBkBOEiBjBNBBhBBgBBjBBZPXKZmBkBKEhBBBhBBjBJgBBW'
    'BEBZHXKZGXUZcEbZCKDjBLaBZEXMZEEHZ5FkBKEiBjBLBBhBBgBBWBZlGkBHZCkBBZCEIZ'
    'BECZBEYjBGZBjBCZCBCaBSBNBKBMBKBWBZMXKZmCkBIZCkBEEjBjBHZCjBEBBhBBgBBABZ'
    'CjBBZbEBjBKEoBdBaBBEhBBQBKELBZFLBZBSBZIEBjBLEoBNCMBNDGMBBhBBRBSBZDABZi'
    'GjBIZ4EkBJZBkBEEhBjBIZBjBEBChBBgBBABZPXdZFEeZCOWZBOHjBFBCZpCkBHZBkBCZB'
    'kBBElBjBGZDjBBZBjBCZBjBBBBhBBWBjBBaBSBMBKBZIXKZGkBGZBkBCZBkBCEejBFZBjB'
    'CZBjBCBBhBBSBZIXKZ2JESLBjBEZJBCMBhBBkBNZBEiBjBHZDjBDaBSBZNXKWBZltQkBBE'
    'djBMKDBBKBaBXKZmgDBChBBEgBjBIaCZDXKZ';

/// Indic_Positional_Category for the whole code space. 884 runs.
const String _indicPositionalTable =
    'AFgoCIDHBF2BIBHBABFBHBDBHBAEIEHEABDBHBFBIBABFCIBACFKACFdIBHCF4BABFBHBD'
    'BHBAEFCDCFCECABFJHBFKACFaIBFCICHBF4BABFBHBDBHBACFEICFCICABFDABFeICFDAB'
    'FLICHBF4BABFBHBDBHBAEIBFBICOBFBHCABFUACFWIGFBIBHCF4BABFBHBIBHBAEFCDBMB'
    'FCEBNBABFHICOBFKACFeIBF7BHCIBHCFDDDFBEDIBFJHBFoBIBHDIBF3BABFBIDHEFBICJ'
    'BFBIEFHIBABFLACFdIBHCF4BABFBHBIBOBHEFBIBOCFBOCICFHHCFLACFPHBFMICHCF3BI'
    'CFBHDAEFBDDFBEDICFIHBFKACFdIBHCFmCIBFEHDICABFBABFBHBDBMBDBEBNBEBHBFSHC'
    'F8BHBIBHCIEADFFPFHBFBIIFhDHBIBHCIEADIBABFDPFFDIHFpCACFbABFBABFBIBFEHBD'
    'BFxBABIBJBACJEIFHBIBJBICABFBICFFALFBAkBFJABFkDHCICACDBIFABHBFBIBHBKBAC'
    'FXHCACFEADFBHDFCHHFDIEFNABHBDBICHGABFBHBFKHDIBF0zBIBACHBFcIBABHBFdIBAB'
    'FeIBABFiCHBIEADMBNBEBDDECIBHCIJFBIBFJIBFiKICABHCOCICHDFEHCABHGABIBABF0'
    'DHFPDHCPBHGFHHCFtCIBABDBHBIBF5BDBABHBIDAEFCHBIBHCIEACIBABHBDFIKFCABFgE'
    'IEHBFvBIBHBICADCBJBLBDCECIBOBHBFmBIBABIHFMICHBFeHBACIBABDBHBICHBFBACF4'
    'BIBHBICHDIBHBIDHCFwBHDDCMBHCABIHDCIBABF4EIDFBGBAFICAEIBHBGHFEABFGIBFCH'
    'BFjIIBF0XIBFx4hBIBFDIBFEIBFXHCABIBHBFEABFzCHCFyBHQABIBFaISFNIBFmBIFADF'
    'ZADIBAEIDHCFsBIDHBFvBIBHCICACDCIBABCBBBCBFkBIBFjCIEABIBDCIBABHBDBACFMI'
    'BFIIBHBFtBHBIBHBFyBIBHBICABPCICPBHBPCHBICFBIBFpBDBABIBDBHBFFHBFtHHCIBH'
    'CABHCFBHBABFzwXGBACFBIBGBFFADIBFoBIBACFluBHBIBHBF1BIEAGIFFpBIBFCICFLIC'
    'HBFtBHBDBHBACICHCACFHABF9BIDFkBIDACDBIBJCIBACFBIBFQHCFsBABFMICHBFwBHBD'
    'BHBAGIDOBHBFBICFFACIBABFBDBIBF8CHDABICOCIBHBICFGIBFCABF9EIBHBDBHBACIEA'
    'CFVICHCF3BACFBHCIBHEFCDCFCECHBFJHBFKHCFCIHFDIFFjCHBOCAGFBDBFCDBFBECHCF'
    'BHCIBHBFBIBABFOIBABFyCHBDBHBAGICHCABICHBABFXIBFxCHBDBHBAGDBIBMBEBHBEBI'
    'CHBACFrHHBDBHBAEFCDBMBEBNBICHBACFbACFyCHDAGICHCIBHBABIBFqDIBHBIBDBHBAC'
    'IEHBABFlDABKBIBHCICACDBIBABIDFgIHBDBHBAEIFHBACF1HHFDBFBDBEBFCICHBFBIBH'
    'BIBCBABFtEHBDBHBAEFCICHEABFDDBFcIBACIGABFoBACIEHBFBAEFSIBACIDHCADFoBIG'
    'AMIBHBIBFnGIBHBACIBHBIBHBFnGHBICAFFBIGHBABFyCAWFBHBAHDBABIBHBICF6DIFAB'
    'FDIBFBICFBIDABIBABFBHBABFiCHFFBICFBHCIBHBF8KIBABDBHBFJIDHBFwBHCICADFDD'
    'CIBHBFYIBFjuQIMDCHBIBACFwgDHDFgBHKF';
