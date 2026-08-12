/// The cache that makes text affordable to draw.
///
/// Rasterizing an outline is the single most expensive thing a frame of text
/// does, and it is also the most repetitive: the same face, at the same size,
/// draws the same few dozen glyphs on every frame, and a paragraph repeats one
/// glyph a dozen times within a single frame. So the mask is computed once and
/// looked up afterwards. Without this, text cost is proportional to the number
/// of glyphs *drawn*; with it, to the number of distinct glyphs *seen*, which
/// stops growing after the first frame.
///
/// Section 23.5 of the roadmap requires every cache to state its key,
/// generation, size, usage, eviction policy, metrics and invalidation. Each has
/// its own member below, and the reasons the interesting ones are what they are
/// follow here.
///
/// ## The key, and why subpixel offsets are quartered
///
/// A mask is identified by four things: which face, which glyph, at what pixel
/// size, and at which horizontal subpixel offset.
///
/// The last one is the one that looks optional and is not. Text that snaps
/// every glyph to the pixel grid loses up to half a pixel of advance per
/// glyph, and those losses do not cancel - they accumulate along a line, so
/// letter spacing visibly ripples and a word looks unevenly set. Positioning
/// glyphs at a fraction of a pixel fixes that, but a mask rasterized for a pen
/// at x.0 is *not* the mask for a pen at x.5: the antialiased fringe falls on
/// different sides. So the offset is part of the key.
///
/// It is quantised to quarters, which is the industry norm (FreeType, Skia and
/// CoreText all land on four or fewer horizontal positions). The trade is
/// exact: n buckets cost n times the entries and leave a positioning error up
/// to 1/(2n) px. At four buckets that error is an eighth of a pixel, which is
/// below what anyone can see even on a 1x display, and the next step up would
/// double the memory to buy nothing visible.
///
/// The pixel size is quantised too, to 1/64 px - the same 26.6 fixed point
/// fonts have used for decades. On a miss the mask is rasterized at the
/// *quantised* size rather than the requested one, so the key determines the
/// pixels completely: two callers whose sizes round to the same bucket get the
/// same mask no matter which of them arrived first. An animated size sweeping
/// through 16.0 to 17.0 therefore produces 64 entries rather than one per
/// distinct double, and the difference between a glyph at 16.0 and at 16.015
/// is not representable in the mask anyway.
///
/// ## Why the key is packed into an integer
///
/// Because a lookup happens per glyph per frame, and a key object per lookup
/// would put an allocation on exactly the path section 6.5 rules out. The four
/// components fit in 52 bits, which is inside the range an integer keeps
/// exactly on every Dart target including the web, where an `int` is a double.
library;

import 'dart:collection';

import '../../text/typeface.dart';
import 'glyph_raster.dart';

/// Distinct horizontal subpixel positions a glyph is rasterized at.
const int kSubpixelBuckets = 4;

/// Fractions of a pixel the cache distinguishes in a font size: 26.6 fixed
/// point, matching what font engines have quantised sizes to since TrueType.
const int kSizeQuantum = 64;

/// The subpixel bucket a pen position falls in, in `0..kSubpixelBuckets - 1`.
///
/// Rounds to the nearest bucket rather than truncating, so the worst error is
/// half a bucket in either direction instead of a whole one biased left. A pen
/// that rounds up to a full pixel reports bucket 0, and [glyphPixelOrigin]
/// moves the whole-pixel part up to match - the two must be read as a pair or
/// the glyph lands a pixel to the left of where it was measured.
int glyphSubpixelBucket(double penX) {
  final int bucket = ((penX - penX.floorToDouble()) * kSubpixelBuckets).round();
  return bucket == kSubpixelBuckets ? 0 : bucket;
}

/// The whole pixel a pen position snaps to, paired with [glyphSubpixelBucket].
int glyphPixelOrigin(double penX) {
  final int floor = penX.floor();
  final int bucket = ((penX - penX.floorToDouble()) * kSubpixelBuckets).round();
  return bucket == kSubpixelBuckets ? floor + 1 : floor;
}

/// The horizontal offset a mask in [bucket] was rasterized with.
double glyphSubpixelOffset(int bucket) => bucket / kSubpixelBuckets;

/// An LRU cache of rasterized glyph masks, bounded by a byte budget.
final class GlyphCache {
  GlyphCache({
    this.byteBudget = 4 << 20,
    GlyphRasterizer? rasterizer,
  })  : _rasterizer = rasterizer ?? GlyphRasterizer(),
        assert(byteBudget > 0);

  /// The process-wide cache the CPU renderer uses when a caller does not
  /// supply one.
  ///
  /// Shared on purpose. The point of the cache is to survive between frames,
  /// and a renderer that built one per frame would rasterize every glyph every
  /// frame while looking, from the outside, exactly like a cache. A caller who
  /// needs isolation - a test asserting on the counters, or a tool that
  /// measures cold rasterization - passes its own.
  static final GlyphCache shared = GlyphCache();

  /// Bytes of mask coverage this cache will hold before it starts evicting.
  ///
  /// Counted as the coverage buffers plus a flat [_entryOverheadBytes] each,
  /// because a cache of ten thousand empty glyphs still costs ten thousand map
  /// entries and a budget that ignored them would never bound anything.
  final int byteBudget;

  final GlyphRasterizer _rasterizer;

  /// Insertion order *is* the LRU order: a hit removes and re-inserts, so the
  /// least recently used entry is always the first key. That is why this is a
  /// [LinkedHashMap] rather than any map - the ordering is load-bearing.
  final LinkedHashMap<int, _CachedGlyph> _entries =
      LinkedHashMap<int, _CachedGlyph>();

  /// Dense small indices for the faces seen, so a face fits in the packed key.
  ///
  /// [Typeface] has no value equality, so this is identity - which is right: a
  /// face parsed twice from the same bytes is two independent objects with
  /// independently cached outlines, and pretending otherwise would hand out
  /// masks built from a different object's tables.
  final Map<Typeface, int> _faceIndices = <Typeface, int>{};

  /// Indices handed out to faces that have since been invalidated; see
  /// [invalidate] for why they are never handed out again.
  int _retiredFaceCount = 0;

  int _bytes = 0;
  int _generation = 0;
  int _hitCount = 0;
  int _missCount = 0;
  int _evictionCount = 0;
  int _bypassCount = 0;

  /// How many masks are held.
  int get entryCount => _entries.length;

  /// Bytes accounted against [byteBudget].
  int get byteCount => _bytes;

  /// Bumped by [clear] and [invalidate], never by eviction.
  ///
  /// Eviction is invisible - the same key rasterizes to the same mask, so a
  /// caller cannot tell an evicted entry from one that was never there.
  /// Invalidation is not: it means the answers have *changed*, so anything
  /// derived from masks handed out earlier - a GPU atlas page, a laid-out line
  /// - is stale. Comparing generations is how such a holder finds out without
  /// this cache having to know it exists.
  int get generation => _generation;

  int get hitCount => _hitCount;

  /// Lookups that had to rasterize. The number this cache exists to hold down.
  int get missCount => _missCount;

  int get evictionCount => _evictionCount;

  /// Lookups that could not be keyed and were rasterized without being stored.
  ///
  /// A glyph id or a size outside the packed key's range, or a mask larger
  /// than the whole budget. Kept as its own counter rather than folded into
  /// misses, because a cache whose hit rate is fine but whose bypass count is
  /// high is a differently broken thing from one that simply thrashes.
  int get bypassCount => _bypassCount;

  /// Hits over lookups, or 1.0 before the first lookup.
  double get hitRate {
    final int lookups = _hitCount + _missCount + _bypassCount;
    return lookups == 0 ? 1.0 : _hitCount / lookups;
  }

  /// The mask for [glyphId] of [font] at [subpixelBucket].
  ///
  /// The returned mask is shared and must be treated as immutable; its
  /// coverage buffer belongs to the cache.
  GlyphMask maskFor(
    ScaledTypeface font,
    int glyphId, {
    int subpixelBucket = 0,
  }) {
    if (subpixelBucket < 0 || subpixelBucket >= kSubpixelBuckets) {
      throw ArgumentError.value(
        subpixelBucket,
        'subpixelBucket',
        'must be in 0..${kSubpixelBuckets - 1}; use glyphSubpixelBucket',
      );
    }

    final int sizeKey = (font.pixelSize * kSizeQuantum).round();
    if (glyphId < 0 ||
        glyphId > _maxGlyphId ||
        sizeKey <= 0 ||
        sizeKey > _maxSizeKey) {
      _bypassCount++;
      return _rasterizer.render(
        font,
        glyphId,
        subpixelOffsetX: glyphSubpixelOffset(subpixelBucket),
      );
    }

    final int key =
        _packKey(_faceIndexOf(font.typeface), sizeKey, glyphId, subpixelBucket);
    final _CachedGlyph? cached = _entries.remove(key);
    if (cached != null) {
      // Removed and re-inserted rather than read in place: that is the whole
      // of the LRU bookkeeping, and it is why nothing here walks the entries.
      _entries[key] = cached;
      _hitCount++;
      return cached.mask;
    }

    _missCount++;
    // Rasterized at the quantised size, not the requested one, so the key
    // fixes the pixels. See the library comment.
    final double quantisedSize = sizeKey / kSizeQuantum;
    final ScaledTypeface canonical = quantisedSize == font.pixelSize
        ? font
        : ScaledTypeface(font.typeface, quantisedSize);
    final GlyphMask mask = _rasterizer.render(
      canonical,
      glyphId,
      subpixelOffsetX: glyphSubpixelOffset(subpixelBucket),
    );

    final int cost = mask.coverage.length + _entryOverheadBytes;
    if (cost > byteBudget) {
      // Storing it would evict everything else and then still not fit under
      // the budget on the next insert. One enormous glyph is not worth the
      // whole cache.
      _bypassCount++;
      return mask;
    }
    _entries[key] = _CachedGlyph(mask, cost);
    _bytes += cost;
    _evictToBudget();
    return mask;
  }

  /// Drops everything. Callers holding a [GlyphMask] keep a valid one - masks
  /// are immutable and detached from this cache once returned.
  void clear() {
    _entries.clear();
    _bytes = 0;
    _generation++;
  }

  /// Drops every mask built from [face].
  ///
  /// What a font reload or an unloaded face calls. The face's index is *not*
  /// reused: a stale key that survived somewhere would then resolve to a
  /// different face, which is a wrong glyph rather than a missing one, and
  /// wrong glyphs are the harder bug. Indices are 16 bits and faces are
  /// counted in tens, so leaking one costs nothing worth having.
  void invalidate(Typeface face) {
    final int? index = _faceIndices.remove(face);
    if (index == null) return;
    _retiredFaceCount++;
    _generation++;
    final List<int> doomed = <int>[
      for (final int key in _entries.keys)
        if (_faceOfKey(key) == index) key,
    ];
    for (final int key in doomed) {
      _bytes -= _entries.remove(key)!.cost;
    }
  }

  /// Resets the counters without touching the contents.
  ///
  /// For a benchmark or a test that wants to measure one phase; it deliberately
  /// does not bump the generation, because nothing about the cached answers
  /// changed.
  void resetMetrics() {
    _hitCount = 0;
    _missCount = 0;
    _evictionCount = 0;
    _bypassCount = 0;
  }

  @override
  String toString() => 'GlyphCache($entryCount entries, $_bytes/$byteBudget B, '
      'hits $_hitCount, misses $_missCount, evictions $_evictionCount)';

  void _evictToBudget() {
    while (_bytes > byteBudget && _entries.isNotEmpty) {
      final int oldest = _entries.keys.first;
      _bytes -= _entries.remove(oldest)!.cost;
      _evictionCount++;
    }
  }

  int _faceIndexOf(Typeface face) =>
      _faceIndices[face] ??= _faceIndices.length + _retiredFaceCount;

  static int _packKey(
    int faceIndex,
    int sizeKey,
    int glyphId,
    int subpixelBucket,
  ) =>
      (faceIndex * _faceStride) +
      (sizeKey * _sizeStride) +
      (glyphId * _glyphStride) +
      subpixelBucket;

  static int _faceOfKey(int key) => key ~/ _faceStride;

  // Multiplication rather than shifts: on the web an `int` is a double and the
  // bitwise operators there truncate to 32 bits, which would silently mangle a
  // 52-bit key. The arithmetic below stays exact for every value in range.
  static const int _glyphStride = kSubpixelBuckets;
  static const int _maxGlyphId = 0xFFFF;
  static const int _sizeStride = _glyphStride * (_maxGlyphId + 1);
  static const int _maxSizeKey = 0x3FFFF;
  static const int _faceStride = _sizeStride * (_maxSizeKey + 1);

  /// Charged per entry on top of its coverage, for the map node, the mask and
  /// its header. An estimate, and only has to be the right order of magnitude:
  /// its job is to stop empty glyphs from being free.
  static const int _entryOverheadBytes = 64;
}

final class _CachedGlyph {
  const _CachedGlyph(this.mask, this.cost);

  final GlyphMask mask;

  /// Bytes this entry charges against the budget, stored rather than
  /// recomputed so eviction subtracts exactly what insertion added.
  final int cost;
}
