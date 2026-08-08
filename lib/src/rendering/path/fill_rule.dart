/// Which points a closed outline encloses.
///
/// Its own file because the answer belongs to the shape, not to the filler:
/// a hit test, a clip mask and a coverage pass all have to agree on it, and
/// only one of those is in this directory.
library;

/// The rule deciding whether a point is inside a path.
///
/// The two rules only disagree where a path overlaps itself, and there they
/// disagree visibly - which is why the filler takes this as a parameter rather
/// than picking one. A five-pointed star drawn as a single self-crossing
/// contour is solid under [nonZero] and hollow in the middle under [evenOdd];
/// both are what somebody wants, and neither is a reasonable default for the
/// other's case.
enum FillRule {
  /// Inside where the signed number of times the outline winds around the
  /// point is not zero.
  ///
  /// Direction matters: a hole is a contour wound against its container. This
  /// is the rule most drawing APIs default to, because it makes overlapping
  /// shapes merge the way a person expects.
  nonZero,

  /// Inside where a ray from the point crosses the outline an odd number of
  /// times.
  ///
  /// Direction is irrelevant: any overlap of two subpaths is a hole. What
  /// fonts and SVG's `fill-rule: evenodd` mean, and the only way to punch a
  /// hole without caring which way a contour was wound.
  evenOdd,
}
