// GENERATED FILE - DO NOT EDIT.
//
// Source:     referencias/unicode/ucd.nounihan.flat.xml
// UCD:        17.0.0
// Regenerate: dart run tool/generate_unicode_tables.dart

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

/// How a character is drawn when the line runs top to bottom.
///
/// The member order is the one the generated table encodes. Reordering the
/// members silently re-labels every code point, so the enum and the table
/// are generated together and have to be regenerated together.
enum VerticalOrientation {
  /// Drawn upright in vertical text.
  upright,

  /// Rotated 90 degrees clockwise in vertical text.
  rotated,

  /// Drawn upright after a font transformation, if the font has one;
  /// upright otherwise.
  transformedUpright,

  /// Drawn upright after a font transformation, if the font has one;
  /// rotated otherwise.
  transformedRotated;
}

final RangeTable _orientations = RangeTable(_verticalOrientationTable);

/// The Vertical_Orientation of [codePoint].
VerticalOrientation verticalOrientationOf(int codePoint) =>
    VerticalOrientation.values[_orientations.lookup(codePoint)];

/// Vertical_Orientation for the whole code space. 280 runs.
const String _verticalOrientationTable =
    'ABnFABBBABBEABBCABBKADBYABBfABByPACB0wDAgIBhQA/TBwRAwCB24BABBBDCBCDCBC'
    'ACBOACBJACBFABBEADBHABBTABB3DAEBBADBbACBBAHBFABBDACBBACBGAGBBABBBABBBA'
    'BBEABBGALBFAGBBACBBA7BBCAEBuEABBVACBqGAIBEAUBEAFDCABBxCAeBjBAQBBABBBAL'
    'BGAhCBBA8GBgFA6DBGAoKBOAeB+bAeBgBAKB9BABBgBAaBBAZBEAQBwSACBuBAhMCCAFDK'
    'ACDMAQDBAQCBABCBABCBABCBABCBAZCBAfCBABCBABCBAGCBAGCCAECCADDBCBABCBABCB'
    'ABCBABCBAZCBAfCBABCBABCBAGCBAGCCAFDBAqBCBAsECEADCBA0BCQA/HC5CAjBCFAwqc'
    'BwkBAgBBgUAggLBggCAg4GBwYAQBQAZBHCDAFBBDGAEBEAJBxECBAGDCACCBBBCBALDCBD'
    'CBAbDBABDBABDBAbDGB/DADDBAEBIAJBDACBisCAgBBg/CAgEBggBAgGBgqFAg0FBgrKAg'
    'xHBwvIAiKCBAdCDACCBAOCEA4MBg+GAwIBwBAgQBgHAgFBgkBAwVBwqFAgQCCA+vBBgIAg'
    'QBgoBA+//BBCA+//BBiggWA+//BBCA+//BB';
