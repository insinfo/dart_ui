// GENERATED FILE - DO NOT EDIT.
//
// Source:     referencias/unicode/ucd.nounihan.flat.xml
// UCD:        17.0.0
// Regenerate: dart run tool/generate_unicode_tables.dart

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

/// How a character joins to its neighbours.
///
/// The member order is the one the generated table encodes. Reordering the
/// members silently re-labels every code point, so the enum and the table
/// are generated together and have to be regenerated together.
enum JoiningType {
  /// Joins to nothing on either side.
  nonJoining,

  /// Invisible to joining: the shaper looks straight through it to the
  /// characters on either side. Combining marks and most format
  /// characters.
  transparent,

  /// Forces its neighbours into their joined forms without taking one
  /// itself. U+200D ZERO WIDTH JOINER and U+0640 ARABIC TATWEEL.
  joinCausing,

  /// Joins on both sides, like ARABIC LETTER BEH.
  dualJoining,

  /// Joins only on its left.
  leftJoining,

  /// Joins only on its right, like ARABIC LETTER ALEF - which is why an
  /// alef in the middle of a word breaks the connection after it.
  rightJoining;
}

/// The letter skeleton a character shares with others of its group.
///
/// The member order is the one the generated table encodes. Reordering the
/// members silently re-labels every code point, so the enum and the table
/// are generated together and have to be regenerated together.
enum JoiningGroup {
  africanFeh,
  africanNoon,
  africanQaf,
  ain,
  alaph,
  alef,
  beh,
  beth,
  burushaskiYehBarree,
  dal,
  dalathRish,
  e,
  farsiYeh,
  fe,
  feh,
  finalSemkath,
  gaf,
  gamal,
  hah,
  hanifiRohingyaKinnaYa,
  hanifiRohingyaPa,
  he,
  heh,
  hehGoal,
  heth,
  kaf,
  kaph,
  kashmiriYeh,
  khaph,
  knottedHeh,
  lam,
  lamadh,
  malayalamBha,
  malayalamJa,
  malayalamLla,
  malayalamLlla,
  malayalamNga,
  malayalamNna,
  malayalamNnna,
  malayalamNya,
  malayalamRa,
  malayalamSsa,
  malayalamTta,
  manichaeanAleph,
  manichaeanAyin,
  manichaeanBeth,
  manichaeanDaleth,
  manichaeanDhamedh,
  manichaeanFive,
  manichaeanGimel,
  manichaeanHeth,
  manichaeanHundred,
  manichaeanKaph,
  manichaeanLamedh,
  manichaeanMem,
  manichaeanNun,
  manichaeanOne,
  manichaeanPe,
  manichaeanQoph,
  manichaeanResh,
  manichaeanSadhe,
  manichaeanSamekh,
  manichaeanTaw,
  manichaeanTen,
  manichaeanTeth,
  manichaeanThamedh,
  manichaeanTwenty,
  manichaeanWaw,
  manichaeanYodh,
  manichaeanZayin,
  meem,
  mim,
  noJoiningGroup,
  noon,
  nun,
  nya,
  pe,
  qaf,
  qaph,
  reh,
  reversedPe,
  rohingyaYeh,
  sad,
  sadhe,
  seen,
  semkath,
  shin,
  straightWaw,
  swashKaf,
  syriacWaw,
  tah,
  taw,
  tehMarbuta,
  tehMarbutaGoal,
  teth,
  thinNoon,
  thinYeh,
  verticalTail,
  waw,
  yeh,
  yehBarree,
  yehWithTail,
  yudh,
  yudhHe,
  zain,
  zhain;
}

final RangeTable _types = RangeTable(_joiningTypeTable);
final RangeTable _groups = RangeTable(_joiningGroupTable);

/// The Joining_Type of [codePoint].
JoiningType joiningTypeOf(int codePoint) =>
    JoiningType.values[_types.lookup(codePoint)];

/// The Joining_Group of [codePoint], [JoiningGroup.noJoiningGroup] for
/// characters that are not cursive letters.
JoiningGroup joiningGroupOf(int codePoint) =>
    JoiningGroup.values[_groups.lookup(codePoint)];

/// Joining_Type for the whole code space. 932 runs.
const String _joiningTypeTable =
    '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';

/// Joining_Group for the whole code space. 252 runs.
const String _joiningGroupTable =
    'AoCgxBbBoCBFCiDBFBjDBFBGB8CBGCSDJCvCC0CCyCC6CCDCQCMDoCBOBtCBZBeBmCBpCB'
    'WBiDBjDCoCjBGBtCBoCBFDoCBFBiDCjDBGISHJJvCJ0CDyCC6CBDBOGtCCQB4CBQBZDQGe'
    'EpCErCBdBSB8CBXC9CBiDIMBlDBMBiDBjDCkDCoCB8CBoCYJBvCBoCK0CByCBDBoCCdBoC'
    'QEBoCBHBRCKCVB5CBoDBYB+CCmDBnDBaBfBnCBqCB1CBPBLBsCBwCBzCBuCBKB2CB7CBHB'
    'RBKBoCdpDBcBNBGHSCJCvCB0CBDDOCQDmCCpCDeBvCC0CBSC0CBvCBSBFCMCjDBiDCICSB'
    '0CCZBoCgHkBBhBBnBBqBBlBBmBBgBBoBBiBBjBBpBBoCFFToCDgDBoCCpCBSB6CCQBhDBp'
    'CBoCQGCSB6CBOBtCBeBmCBjDCvCBiDBxCBoCBJByCBQB3CBvCBDBZBtCBGDvCBjDBABCBB'
    'BGDSBQBDBCBSCeBQBoC3vgCrBBtBCxBCuBBoCBjCBoCBlCCoCCyBBgCBkCB0BD1BBvBBhC'
    'B2BB3BB9BBsBC5BC8BB6BD7BBoCC+BBoCG4BBwBB/BBiCBzBBoCyQUBoCGUBoCPTBoCCUB'
    'oCBTBoCBTBoCCTBoC+MJB6CBZBoCB/CBjDBoC';
