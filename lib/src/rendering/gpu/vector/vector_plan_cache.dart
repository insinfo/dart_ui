/// A retained cache for the per-draw encodings the vector routes build.
///
/// ## The gap this closes, and how it was found
///
/// The dense coverage atlas keeps a rasterised mask by content, so a path that
/// does not change costs a quad after its first frame. Neither of the
/// experimental routes had anything equivalent, and the measurement said so
/// plainly: on a 256x256 panel, a *static* path and a path that moved by a
/// pixel every frame cost sparse strips and compute tiles almost exactly the
/// same, because both re-encoded from scratch every time. See
/// `test/rendering/gpu/d3d12/d3d12_vector_cost_test.dart` and the Direct3D 12
/// section of `doc/architecture/ACELERACAO_GPU_VETORIAL.md`.
///
/// `CpuTessellatedPathCache` already does this for approach B, keyed by path
/// content, fill rule and tolerance. This is the same idea generalised over the
/// *value* being retained, because the two routes retain different things - a
/// `SparseStripDrawPlan` and a `ComputeTilePlan` - while keying on the same
/// facts.
///
/// ## What the key has to contain, and why each part is load bearing
///
/// A cached encoding is only valid for geometry in the same *device* position,
/// against the same clip, under the same rule:
///
///   * [VectorPlanCacheKey.path] - by content, not identity. [Path] is
///     immutable and carries a precomputed hash, so a rebuilt-but-identical
///     path hits, which is exactly what an animation that rebuilds its display
///     list every frame produces.
///   * [VectorPlanCacheKey.transform] - the encodings are in device space.
///   * [VectorPlanCacheKey.clip] - both routes fold the clip into what they
///     encode rather than applying it later.
///   * [VectorPlanCacheKey.fillRule] and
///     [VectorPlanCacheKey.flattenTolerance] - as approach B's key does.
///   * [VectorPlanCacheKey.variant] - anything else the *consumer* needs to be
///     the same. The compute route bins over a grid anchored at the target
///     origin, so a plan built for one surface size or tile size must not be
///     handed to another; sparse strips have no such dependency and pass zero.
///
/// A key that is too *narrow* is a wrong picture. A key that is too *wide* is
/// only a miss, which costs what the route costs today - so every doubtful
/// field is in the key.
///
/// ## What it does not do
///
/// It does not retain GPU resources. A cached sparse plan still uploads its
/// alpha pages and a cached compute plan still uploads its buffers, because
/// residency belongs to the executor and to the frame ring's lifetime rather
/// than to a value cache. What is saved is the CPU encode: the analytic
/// coverage rasterisation for sparse, the flatten and the tile binning for
/// compute.
library;

import '../../../geometry/path.dart';
import '../../../geometry/rect.dart';
import '../../../geometry/transform2d.dart';
import '../../path/fill_rule.dart';

/// Everything that has to be equal for a retained encoding to be reusable.
final class VectorPlanCacheKey {
  const VectorPlanCacheKey(
    this.path, {
    required this.transform,
    required this.clip,
    required this.fillRule,
    required this.flattenTolerance,
    this.variant = 0,
  });

  final Path path;
  final Transform2D transform;
  final Rect clip;
  final FillRule fillRule;
  final double flattenTolerance;

  /// Consumer-defined discriminator. See the library comment: the compute route
  /// puts its surface size and tile size here, sparse strips put zero.
  final int variant;

  @override
  bool operator ==(Object other) =>
      other is VectorPlanCacheKey &&
      other.variant == variant &&
      other.fillRule == fillRule &&
      other.flattenTolerance == flattenTolerance &&
      other.clip == clip &&
      other.transform == transform &&
      other.path == path;

  @override
  int get hashCode => Object.hash(
        path,
        transform,
        clip,
        fillRule,
        flattenTolerance,
        variant,
      );

  @override
  String toString() => 'VectorPlanCacheKey(${path.verbCount} verbs, '
      '$transform, $clip, ${fillRule.name}, $flattenTolerance, $variant)';
}

/// A bounded, least-recently-used cache of retained encodings.
///
/// Least-recently-used rather than unbounded, and the reason is the key: it
/// contains a device-space transform, so a shape that is being animated
/// produces a *new* key on every frame and an unbounded map would grow without
/// limit for exactly the workload the cache is meant to help. Bounded, that
/// workload simply misses - which is the cost of the route today - while a
/// static or repeating scene hits.
///
/// The value is whatever the consumer retains. This class never inspects it, so
/// it cannot accidentally depend on one route's representation.
final class VectorPlanCache<T extends Object> {
  VectorPlanCache({this.capacity = 64}) {
    if (capacity <= 0) {
      throw ArgumentError.value(capacity, 'capacity', 'must be positive');
    }
  }

  /// How many encodings are retained before the least recently used is dropped.
  ///
  /// Sixty-four is enough for the distinct shapes of a screenful of UI - a
  /// scene draws the same few paths at the same few transforms - and small
  /// enough that the retained arenas are bounded by something a reader can
  /// picture rather than by how long the process has been running.
  final int capacity;

  /// Insertion-ordered, and re-inserted on a hit, so the first key is always
  /// the least recently used one. A `LinkedHashMap` is what Dart's `Map`
  /// literal already is, so this needs no second structure to track order.
  final Map<VectorPlanCacheKey, T> _entries = <VectorPlanCacheKey, T>{};

  int _hits = 0;
  int _misses = 0;
  int _evictions = 0;

  int get length => _entries.length;
  int get hits => _hits;
  int get misses => _misses;
  int get evictions => _evictions;

  /// The retained encoding for [key], or null. A hit makes it the most recently
  /// used entry.
  T? lookup(VectorPlanCacheKey key) {
    final T? found = _entries.remove(key);
    if (found == null) {
      _misses++;
      return null;
    }
    _entries[key] = found;
    _hits++;
    return found;
  }

  /// Retains [value] under [key], evicting the least recently used entry when
  /// the cache is full.
  void store(VectorPlanCacheKey key, T value) {
    _entries.remove(key);
    _entries[key] = value;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
      _evictions++;
    }
  }

  /// Forgets every entry. The counters are kept: they describe the run, and a
  /// cache cleared on a device reset has not stopped having had the hits it
  /// had.
  void clear() => _entries.clear();

  /// Forgets every entry and the counters. For a test that measures one scene.
  void reset() {
    _entries.clear();
    _hits = 0;
    _misses = 0;
    _evictions = 0;
  }

  @override
  String toString() => 'VectorPlanCache($length/$capacity, $_hits hits, '
      '$_misses misses, $_evictions evictions)';
}
