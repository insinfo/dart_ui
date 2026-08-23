/// What the application knows about a subtree, and the renderer cannot.
///
/// The per-draw selector in `rendering/gpu/gpu_path_strategy.dart` decides
/// from facts it can measure: how big the shape is, how many tile crossings it
/// costs, whether its mask is already resident. Those facts are all about the
/// frame it is looking at, and the one thing they cannot contain is what
/// happens *next*. A card that has been still for twenty-six frames and a card
/// that is one frame into a pinch-zoom present the renderer with identical
/// evidence and want opposite answers: the first should be rasterised once and
/// cached, and the second should never touch the mask cache at all, because
/// every entry it writes is dead before it is read.
///
/// Only the application knows which one it is looking at, so this file is how
/// it says so. The model is CSS `will-change` and the placement rule is
/// `RepaintBoundary`'s: a value declared on a subtree, inherited by everything
/// inside it, overridable further in.
///
/// ## The contract, and it is the whole point
///
/// **A hint is advice. A wrong hint costs performance and never changes the
/// image.** Two mechanisms hold that up, and both are checked by tests:
///
///   1. a hint is not encoded as a command. It travels beside the op and float
///      streams (see `DisplayList.pushContentHint`), so the encoded display
///      list produced with a hint is byte-for-byte the list produced without
///      one, and every consumer that ignores hints - the CPU renderer, the
///      recording sink, a golden file - cannot tell the difference;
///   2. the seam that consumes it, `RenderPolicy.applyContentHint`, may only
///      move the two *cost* facts of a workload (`geometryStable` and
///      `denseMaskLikelyCacheable`). It cannot touch a capability, and it
///      cannot touch a correctness fact such as `tessellationEligible` or
///      `hasSelfIntersections`. A hint therefore chooses between routes that
///      the device and the policy had already declared legal for that draw.
///
/// The residual honesty: routes are not pixel-identical to each other, and
/// `doc/architecture/ACELERACAO_GPU_VETORIAL.md` measures how far apart they
/// are. Every route that starts from the shared analytic coverage deviates by
/// 0; stencil-then-cover deviates by up to 18 levels on an off-grid fringe,
/// because MSAA quantises coverage. That deviation belongs to the route and
/// exists with or without hints. An application that wants it gone sets
/// [RenderQualityPreference.exact], which removes the only route that has it.
library;

/// How a subtree changes from frame to frame.
///
/// The axis that matters is repetition, not motion: what decides whether the
/// dense mask atlas is the cheapest answer is whether the *same* rasterised
/// coverage will be asked for again.
enum ContentMotionHint {
  /// Nothing declared. Inherits the enclosing hint, and at the root means the
  /// selector's own measurements decide alone.
  unspecified,

  /// Geometry and transform repeat frame to frame.
  ///
  /// The chrome of an editor, a form, a list that is not scrolling. The dense
  /// atlas is nearly unbeatable here - a static UI was measured at one
  /// rasterisation in twenty-six frames - and this says so a frame earlier
  /// than the repetition model could work it out for itself.
  staticContent,

  /// The geometry itself is different every frame.
  ///
  /// A path being dragged by a control point, a shape being morphed, a
  /// particle field. Every mask written for this subtree is evicted before it
  /// is hit, so caching it is pure cost: the raster, the upload and the atlas
  /// space are all spent on an entry nobody will read.
  animating,

  /// The geometry repeats but its transform does not.
  ///
  /// Zoom, pinch and pan of a canvas. Distinct from [animating] because the
  /// *local* geometry is stable even though the device-space coverage is not,
  /// which is exactly the split that decides between a retained mesh (keyed on
  /// local coordinates, survives the transform) and a dense mask (keyed on
  /// device coordinates, misses every frame).
  transforming,
}

/// What a subtree wants when speed and edge quality disagree.
///
/// Local override of [RenderPolicy.quality]; see it for what each value costs
/// and why the default is what it is.
enum RenderQualityHint {
  /// Nothing declared. Inherits the enclosing hint, then the policy.
  unspecified,

  /// Keep the analytic edge even when a cheaper route is available.
  preferQuality,

  /// Trade edge quality for throughput on this subtree.
  preferSpeed,
}

/// One subtree's declaration, as a value.
///
/// Immutable and cheap to compare, because it is pushed and popped around
/// every painted subtree that declares one and compared once per encoded
/// command by the player.
final class ContentHint {
  const ContentHint({
    this.motion = ContentMotionHint.unspecified,
    this.quality = RenderQualityHint.unspecified,
  });

  /// Declares nothing. The identity of [inheritFrom] and the value the player
  /// starts every frame at.
  static const ContentHint none = ContentHint();

  /// Shorthands for the three motion declarations, so the common case is a
  /// constant rather than a constructor call.
  static const ContentHint staticContent =
      ContentHint(motion: ContentMotionHint.staticContent);
  static const ContentHint animating =
      ContentHint(motion: ContentMotionHint.animating);
  static const ContentHint transforming =
      ContentHint(motion: ContentMotionHint.transforming);

  final ContentMotionHint motion;
  final RenderQualityHint quality;

  /// True when this declares nothing at all, in which case pushing it is a
  /// no-op that the encoder is entitled to drop entirely.
  bool get isEmpty =>
      motion == ContentMotionHint.unspecified &&
      quality == RenderQualityHint.unspecified;

  /// This hint resolved against the one enclosing it.
  ///
  /// Per field, and that is the useful part: an inner subtree that declares
  /// only [RenderQualityHint.preferSpeed] keeps the motion its parent
  /// declared, instead of silently resetting it to unspecified. Inheritance
  /// that worked per *object* would make every inner hint a full
  /// redeclaration, which is how a declaration ends up being copied and then
  /// diverging.
  ContentHint inheritFrom(ContentHint outer) {
    if (outer.isEmpty) return this;
    final ContentMotionHint resolvedMotion =
        motion == ContentMotionHint.unspecified ? outer.motion : motion;
    final RenderQualityHint resolvedQuality =
        quality == RenderQualityHint.unspecified ? outer.quality : quality;
    if (resolvedMotion == motion && resolvedQuality == quality) return this;
    return _table[_packOf(resolvedMotion, resolvedQuality)];
  }

  /// The dense integer this hint is stored as in the side table.
  ///
  /// Small and contiguous on purpose: the encoder keeps hints in a
  /// `Uint32List` beside the op stream, so the value has to be an integer, and
  /// [unpack] has to be able to answer without allocating.
  int get packed => _packOf(motion, quality);

  /// Inverse of [packed], and allocation-free: the twelve legal combinations
  /// are a constant table, so a frame that changes hint on every command still
  /// creates no objects.
  static ContentHint unpack(int packed) {
    if (packed < 0 || packed >= _table.length) {
      throw RangeError.value(packed, 'packed', 'not a content hint');
    }
    return _table[packed];
  }

  static int _packOf(ContentMotionHint motion, RenderQualityHint quality) =>
      motion.index * RenderQualityHint.values.length + quality.index;

  static const List<ContentHint> _table = <ContentHint>[
    ContentHint(),
    ContentHint(quality: RenderQualityHint.preferQuality),
    ContentHint(quality: RenderQualityHint.preferSpeed),
    ContentHint(motion: ContentMotionHint.staticContent),
    ContentHint(
      motion: ContentMotionHint.staticContent,
      quality: RenderQualityHint.preferQuality,
    ),
    ContentHint(
      motion: ContentMotionHint.staticContent,
      quality: RenderQualityHint.preferSpeed,
    ),
    ContentHint(motion: ContentMotionHint.animating),
    ContentHint(
      motion: ContentMotionHint.animating,
      quality: RenderQualityHint.preferQuality,
    ),
    ContentHint(
      motion: ContentMotionHint.animating,
      quality: RenderQualityHint.preferSpeed,
    ),
    ContentHint(motion: ContentMotionHint.transforming),
    ContentHint(
      motion: ContentMotionHint.transforming,
      quality: RenderQualityHint.preferQuality,
    ),
    ContentHint(
      motion: ContentMotionHint.transforming,
      quality: RenderQualityHint.preferSpeed,
    ),
  ];

  @override
  bool operator ==(Object other) =>
      other is ContentHint &&
      other.motion == motion &&
      other.quality == quality;

  @override
  int get hashCode => packed;

  @override
  String toString() => isEmpty
      ? 'ContentHint.none'
      : 'ContentHint(${motion.name}, '
          '${quality.name})';
}

/// The hint side table of an encoded display list, as the player reads it.
///
/// A span covers every command from [spanStart] - a word offset into the op
/// stream - up to the next span's start. Spans are ordered, non-empty and
/// never repeat a value, so "what is in force here" is one forward cursor and
/// no search.
///
/// This is an interface rather than a concrete list because the only producer
/// is `DisplayList` and the only consumer is `DisplayListPlayer`: making the
/// player depend on the encoder would drag the whole `graphics` writer into
/// every replay, and making the encoder build a list per frame would allocate
/// on the path section 6.5 forbids allocating on.
abstract interface class ContentHintSpans {
  /// How many hint changes the list recorded. Zero for every list that never
  /// saw a hint, which is what makes the player's per-command cost a single
  /// integer comparison.
  int get spanCount;

  /// Word offset in the op stream of the first command [index] covers.
  int spanStart(int index);

  /// The hint in force from [spanStart] onward.
  ContentHint spanHint(int index);

  /// A list that declares nothing. Const, so the player's default costs no
  /// allocation and no null test.
  static const ContentHintSpans empty = _EmptyContentHintSpans();
}

final class _EmptyContentHintSpans implements ContentHintSpans {
  const _EmptyContentHintSpans();

  @override
  int get spanCount => 0;

  @override
  int spanStart(int index) =>
      throw RangeError.index(index, this, 'index', 'no spans', 0);

  @override
  ContentHint spanHint(int index) =>
      throw RangeError.index(index, this, 'index', 'no spans', 0);
}
