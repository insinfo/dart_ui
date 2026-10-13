/// Default_Ignorable_Code_Point: the characters that draw as nothing when a
/// font has nothing to say about them.
///
/// Unicode's rule (section 5.21, "Ignoring Characters in Processing") is that a
/// renderer which does not *support* one of these characters must not show it
/// at all - not as a `.notdef` box, not as a hex box, not as a gap. They are
/// format controls: a variation selector asks for a different glyph of the
/// character before it, a zero width joiner asks for a ligature, a bidi
/// control steers reordering. When the font declines the request the text
/// reads exactly as it would have without the control, which is invisible.
///
/// That is what makes "Hello ❤️" safe to draw with a face that has a heart and
/// no `U+FE0F`: the selector shapes to nothing, and the heart is drawn in
/// whichever presentation the face has. Before this rule existed here, the
/// selector became `.notdef` and drew a box beside the heart.
///
/// The list is `DerivedCoreProperties.txt` of Unicode 16.0, including the
/// reserved code points the property assigns in advance - those ranges exist so
/// that a character encoded there later is already handled as invisible by
/// software written today.
library;

/// Whether [codePoint] has Default_Ignorable_Code_Point=Yes.
///
/// A range test rather than a table: the property is 27 ranges, all but three
/// of them in places no ordinary text reaches, so the common case - a letter -
/// is decided by the first two comparisons.
bool isDefaultIgnorable(int codePoint) {
  if (codePoint < 0x00AD) return false;
  if (codePoint <= 0x206F) {
    return codePoint == 0x00AD || // SOFT HYPHEN
        codePoint == 0x034F || // COMBINING GRAPHEME JOINER
        codePoint == 0x061C || // ARABIC LETTER MARK
        codePoint == 0x115F || // HANGUL CHOSEONG FILLER
        codePoint == 0x1160 || // HANGUL JUNGSEONG FILLER
        codePoint == 0x17B4 || // KHMER VOWEL INHERENT AQ
        codePoint == 0x17B5 || // KHMER VOWEL INHERENT AA
        (codePoint >= 0x180B && codePoint <= 0x180F) || // Mongolian FVS, MVS
        (codePoint >= 0x200B && codePoint <= 0x200F) || // ZWSP..RLM
        (codePoint >= 0x202A && codePoint <= 0x202E) || // LRE..RLO
        (codePoint >= 0x2060 && codePoint <= 0x206F); // WJ..NOMINAL DIGIT
  }
  if (codePoint <= 0xFFFF) {
    return codePoint == 0x3164 || // HANGUL FILLER
        (codePoint >= 0xFE00 && codePoint <= 0xFE0F) || // VS1..VS16
        codePoint == 0xFEFF || // ZERO WIDTH NO-BREAK SPACE
        codePoint == 0xFFA0 || // HALFWIDTH HANGUL FILLER
        (codePoint >= 0xFFF0 && codePoint <= 0xFFF8); // reserved
  }
  return (codePoint >= 0x1BCA0 && codePoint <= 0x1BCA3) || // shorthand format
      (codePoint >= 0x1D173 && codePoint <= 0x1D17A) || // musical format
      (codePoint >= 0xE0000 && codePoint <= 0xE0FFF); // tags, VS17..VS256
}

/// Whether [codePoint] is a variation selector: `U+FE00..U+FE0F` or
/// `U+E0100..U+E01EF`.
///
/// The subset of [isDefaultIgnorable] that `cmap` format 14 gives meaning to,
/// paired with the character before it.
bool isVariationSelector(int codePoint) =>
    (codePoint >= 0xFE00 && codePoint <= 0xFE0F) ||
    (codePoint >= 0xE0100 && codePoint <= 0xE01EF);
