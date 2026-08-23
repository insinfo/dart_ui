/// How often the same path draw comes back, frame after frame.
///
/// ## The defect this exists to close
///
/// The dense coverage atlas keeps a rasterised mask by content, so a shape
/// that does not change costs one rasterisation and one upload on the frame it
/// first appears and a single quad on every frame after. `GpuMaskAtlas` makes
/// that measurable: six frames of one shape are one rasterisation and five
/// cache hits.
///
/// A draw promoted to an experimental route never reaches that atlas. Its mask
/// is therefore never resident, `denseMaskCacheHit` is false for it for ever,
/// and the selector's first branch - "the exact dense mask is already in the
/// atlas" - can never fire. The route that stole the draw keeps the cheaper
/// route permanently expensive and then wins the comparison against it. That
/// is not a threshold being wrong; it is the cost model asking a question
/// whose answer it has already made false.
///
/// Measured, on the scene in `gl_vector_cost_test.dart`: a static panel took
/// 1.141 ms through sparse strips against 0.865 ms through the dense atlas,
/// because the atlas was hitting and sparse re-encoded and re-uploaded every
/// frame.
///
/// ## What is modelled, and what deliberately is not
///
/// The honest question is not "is this mask resident" - the promoted route
/// guarantees it is not - but "**would** it be resident, had this draw been
/// left alone". That is a prediction, and the only evidence available is the
/// past: a draw whose exact geometry, placement, clip and rule were also
/// present in the previous frames is one the dense atlas would be caching.
///
/// So this counts *consecutive* appearances and nothing else. It does not
/// model eviction pressure, atlas capacity, or how expensive the mask would
/// have been - all of which are real and none of which change the answer for
/// the case that matters, which is a UI that redraws the same panel.
///
/// Being wrong is a cost decision in both directions and never a wrong
/// picture: a repeat mistaken for new is one draw that could have been
/// cheaper, and a new draw mistaken for a repeat is one draw that goes through
/// the parity route.
library;

import '../../geometry/path.dart';
import '../../geometry/rect.dart';
import '../../geometry/transform2d.dart';
import '../path/fill_rule.dart';

/// One draw's identity for repetition purposes.
///
/// The same fields a retained encoding is keyed by, and for the same reason:
/// a shape that moved is a different draw to the dense atlas as much as to a
/// vector encoder, because the mask it would cache is in device space.
final class GpuPathRepetitionKey {
  const GpuPathRepetitionKey._(
    this.path, {
    required this.a,
    required this.b,
    required this.c,
    required this.d,
    required this.subPixelX,
    required this.subPixelY,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.fillRule,
  });

  /// The identity of a draw *as the dense atlas would see it*.
  ///
  /// This deliberately mirrors `GpuMaskAtlas`'s own key rather than being the
  /// obvious (path, transform, clip) tuple, and the difference is not cosmetic.
  /// The atlas does not key on the absolute translation: it keys on the mask's
  /// **sub-pixel** offset from its whole-pixel origin, plus the mask's size. So
  /// a shape scrolled by exactly one pixel is a cache *hit* there - which is
  /// what a scrolling list is - while a key holding the raw transform would
  /// call every frame of that scroll a new draw and hand it to another route.
  ///
  /// Predicting "would the atlas have this cached" with a key coarser or finer
  /// than the atlas's own is simply predicting the wrong thing. Skia makes the
  /// same split and goes one step further, quantising the fractional
  /// translation to 8 bits per axis
  /// (`SoftwarePathRenderer.cpp:341-343`); this repository's atlas compares it
  /// exactly, so this does too. Raising that is a change to the *atlas's*
  /// fidelity policy and is noted as a proposal in the architecture document
  /// rather than made here.
  ///
  /// The 2x2 is compared exactly, which is what every reference does: Skia
  /// requires "the upper left 2x2 of the matrix to match exactly for a cache
  /// hit" (`SoftwarePathRenderer.cpp:321`), Vello's glyph cache compares f32
  /// bits, and Flutter compares the whole `SkMatrix`. Nobody tolerates
  /// approximate scale, because a mask resampled to a different scale is a
  /// blurrier mask, not a cheaper one.
  factory GpuPathRepetitionKey(
    Path path, {
    required Transform2D transform,
    required Rect clip,
    required FillRule fillRule,
  }) {
    final Rect visible = transform.transformRect(path.bounds).intersect(clip);
    final int left = visible.left.floor();
    final int top = visible.top.floor();
    return GpuPathRepetitionKey._(
      path,
      a: transform.a,
      b: transform.b,
      c: transform.c,
      d: transform.d,
      subPixelX: transform.tx - left,
      subPixelY: transform.ty - top,
      pixelWidth: visible.right.ceil() - left,
      pixelHeight: visible.bottom.ceil() - top,
      fillRule: fillRule,
    );
  }

  final Path path;

  /// The linear part, compared exactly.
  final double a;
  final double b;
  final double c;
  final double d;

  /// Translation relative to the mask's whole-pixel origin.
  final double subPixelX;
  final double subPixelY;

  /// Size of the mask the atlas would have stored.
  final int pixelWidth;
  final int pixelHeight;

  final FillRule fillRule;

  @override
  bool operator ==(Object other) =>
      other is GpuPathRepetitionKey &&
      other.fillRule == fillRule &&
      other.pixelWidth == pixelWidth &&
      other.pixelHeight == pixelHeight &&
      other.subPixelX == subPixelX &&
      other.subPixelY == subPixelY &&
      other.a == a &&
      other.b == b &&
      other.c == c &&
      other.d == d &&
      other.path == path;

  @override
  int get hashCode => Object.hash(path, a, b, c, d, _zero(subPixelX),
      _zero(subPixelY), pixelWidth, pixelHeight, fillRule);

  /// -0.0 must hash like 0.0, because `==` says they are the same number. The
  /// same trap `GpuMaskAtlas` documents on its own hash.
  static double _zero(double value) => value == 0 ? 0 : value;
}

/// Counts how many consecutive frames each draw has appeared in.
///
/// Bounded, and least-recently-used, for the reason `VectorPlanCache` is: the
/// key holds a device-space transform, so an animation produces a new key
/// every frame and an unbounded map would grow without limit for exactly the
/// workload this is meant to identify as *not* repeating.
final class GpuPathRepetitionTracker {
  GpuPathRepetitionTracker({
    this.capacity = 128,
    this.repeatsBeforeCacheable = 2,
  }) {
    if (capacity <= 0) {
      throw ArgumentError.value(capacity, 'capacity', 'must be positive');
    }
    if (repeatsBeforeCacheable < 1) {
      throw ArgumentError.value(
        repeatsBeforeCacheable,
        'repeatsBeforeCacheable',
        'must be at least one',
      );
    }
  }

  /// Distinct draws remembered. Larger than `VectorPlanCache`'s default
  /// because this retains four small references per entry rather than an
  /// encoding, and a busy screen has more distinct draws than distinct
  /// *encodings* worth keeping.
  final int capacity;

  /// Consecutive appearances after which a draw is treated as one the dense
  /// atlas would be caching.
  ///
  /// Two, which means "seen on the previous frame as well". One would treat
  /// every first appearance as cacheable and hand the dense route work it has
  /// no cache for yet; three or more spends an extra frame per shape on the
  /// experimental route for no benefit, because the atlas would already have
  /// been hitting by then. Two is the smallest number that means *repeated*.
  final int repeatsBeforeCacheable;

  /// Insertion-ordered; re-inserted on every sighting, so the first key is the
  /// least recently seen.
  final Map<GpuPathRepetitionKey, _Sighting> _seen =
      <GpuPathRepetitionKey, _Sighting>{};

  int _frame = 0;
  int _cacheableCount = 0;
  int _freshCount = 0;

  int get length => _seen.length;

  /// Draws judged to be dense-cacheable repeats, and draws judged fresh.
  /// Neither is visible in the pixels, so a test that wants to know which way
  /// the policy went has to read these.
  int get cacheableCount => _cacheableCount;
  int get freshCount => _freshCount;

  /// Starts a frame. Sightings are compared against the previous frame's
  /// index, so this must be called once per frame and before any [observe].
  void beginFrame() => _frame++;

  /// Records that [key] was drawn this frame and answers whether the dense
  /// atlas would by now be caching it.
  ///
  /// A draw seen in the immediately preceding frame continues its run; a gap
  /// of a frame or more starts a new one, because the atlas may well have
  /// evicted it and because a shape that flickers is not the steady state this
  /// is protecting.
  bool observe(GpuPathRepetitionKey key) {
    final _Sighting? previous = _seen.remove(key);
    final int run;
    if (previous == null || previous.frame != _frame - 1) {
      run = 1;
    } else {
      run = previous.run + 1;
    }
    _seen[key] = _Sighting(_frame, run);
    while (_seen.length > capacity) {
      _seen.remove(_seen.keys.first);
    }
    final bool cacheable = run >= repeatsBeforeCacheable;
    if (cacheable) {
      _cacheableCount++;
    } else {
      _freshCount++;
    }
    return cacheable;
  }

  void clear() {
    _seen.clear();
    _frame = 0;
  }

  /// Forgets the sightings and the counters. For a test measuring one scene.
  void reset() {
    clear();
    _cacheableCount = 0;
    _freshCount = 0;
  }

  @override
  String toString() => 'GpuPathRepetitionTracker($length draws, frame $_frame, '
      '$_cacheableCount cacheable, $_freshCount fresh)';
}

final class _Sighting {
  const _Sighting(this.frame, this.run);

  /// The frame index this draw was last seen on.
  final int frame;

  /// Consecutive frames it has appeared in, ending at [frame].
  final int run;
}
