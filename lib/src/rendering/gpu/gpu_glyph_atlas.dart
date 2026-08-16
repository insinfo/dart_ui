/// The glyph atlas: the one texture cache in the GPU path that outlives a
/// frame, and the reasoning behind every number in it.
///
/// ## Why this is not [GpuMaskAtlas]
///
/// The mask atlas resets its packer in `beginFrame`, which is the right policy
/// for a path - a path is usually drawn under a transform that changed, so
/// last frame's coverage is worthless - and exactly the wrong policy for a
/// glyph. A glyph is *the* thing that repeats: the same face, at the same
/// size, draws the same few dozen shapes on every frame for the lifetime of a
/// window. Re-rasterising them every frame would leave text costing what it
/// costs on the CPU backend plus an upload, which is worse than the CPU
/// backend, not better.
///
/// So this atlas keeps its contents across frames, uploads only what changed,
/// and evicts on a stated policy when it runs out of room. Those three
/// sentences are the whole file.
///
/// ## The key, taken from `glyph_cache.dart` rather than invented here
///
/// An entry is identified by exactly what [GlyphCache] identifies a mask by:
///
///   1. **which face** - by object identity, as a dense small index;
///   2. **the pixel size**, quantised to 1/64 px (26.6 fixed point);
///   3. **the glyph id**;
///   4. **the horizontal subpixel bucket**, one of [kSubpixelBuckets].
///
/// The components, their order and their quantisation are copied deliberately
/// and must stay copied. Two caches that disagree about what "the same glyph"
/// means is how text goes subtly wrong at some sizes and not others - a mask
/// rasterised for a pen at x.0 uploaded into a slot a quad positioned for x.5
/// samples is a half-pixel error that only shows up as unevenly spaced
/// letters. The packing arithmetic is replicated rather than imported because
/// it is private to that file; if the cache's key ever grows a component, this
/// one has to grow it in the same place.
///
/// Like the cache, the mask is rasterised at the *quantised* size, so the key
/// fixes the pixels completely and two callers whose sizes round to the same
/// bucket get the same texels no matter which arrived first.
///
/// ## Plots: the unit of eviction and of upload
///
/// The atlas is divided into a grid of square plots. A plot owns a packer, a
/// dirty rectangle and the keys of the glyphs inside it, and it is what gets
/// evicted and what gets uploaded.
///
/// Per-plot rather than per-glyph, for one reason: freeing an individual slot
/// inside a shelf packer implies compaction, and compaction means moving
/// texels that quads already emitted this frame still point at. Skia's atlas
/// makes the same choice for the same reason. The cost is honest and worth
/// stating - evicting one glyph evicts its neighbours - and it is small,
/// because a glyph is cheap to rasterise again and a plot's worth of glyphs
/// that were genuinely still in use will be re-admitted over the next frame.
///
/// **Eviction policy: least recently used plot, by frame number.** A plot
/// whose `lastUsedFrame` equals the current frame is never a candidate, which
/// is the rule that matters: the frame in progress has already emitted quads
/// pointing into that plot, and recycling it would repaint those glyphs with
/// whatever landed there afterwards. Empty plots are skipped as victims too -
/// recycling one frees nothing and would hide a real "atlas full".
///
/// This requires [beginFrame] to actually be called once per frame. A backend
/// that forgets it leaves every plot looking used-right-now, so nothing is
/// ever evictable and the atlas reports itself permanently full.
///
/// ## Padding: one texel, on every side
///
/// Every slot is surrounded by at least one texel that this atlas zeroes, so
/// any two glyphs' coverage is at least two texels apart. One texel is the
/// smallest that survives bilinear filtering, which reaches half a texel past
/// a quad's edge; without it the right column of one glyph would fetch a
/// fraction of its neighbour's left column and show as a faint smudge on one
/// letter in a hundred - findable only by staring at a screenshot. The ring is
/// zeroed on every write rather than once at allocation, because a recycled
/// plot's texels are whatever the previous tenant left there, and the ring is
/// included in the dirty rectangle so the *uploaded* texture has it too.
///
/// ## What this does not do, said plainly
///
///   * **No mid-frame flush of its own.** When the atlas is full and nothing
///     is evictable, [acquire] returns null and sets [needsFlush]; it does not
///     throw and it does not silently drop the glyph. Acting on that signal
///     needs the backend to issue the draw calls recorded so far - see
///     [recycleAll] - because until they are issued the texels are still being
///     read. `gpu_raster_sink.dart` turns an unhandled signal into a named
///     error.
///   * **No tiling.** A glyph bigger than a plot fails with
///     [GlyphAtlasFailure.glyphTooLarge]. Very large text belongs on the path
///     rasteriser, where it costs one mask and no atlas pressure.
///   * **No colour glyphs, no SDF.** Coverage only, alpha8, one texel per
///     device pixel - the same bytes the CPU renderer composites, which is
///     what keeps CPU/GPU text comparable in a golden test.
///   * **No hinting-aware invalidation, and none is needed.** Faces are keyed
///     by identity, so a reloaded font is a different key; its predecessor's
///     entries simply stop being touched and age out through plot LRU.
library;

import 'dart:typed_data';

import '../../text/typeface.dart';
import '../text/glyph_cache.dart';
import '../text/glyph_raster.dart';
import 'gpu_texture.dart' show GpuTextureFormat;

/// Where one glyph's coverage lives in the atlas, and where to draw it.
///
/// Returned by reference on a cache hit and never copied, so reading one costs
/// nothing on the per-glyph path. Immutable: the plot that owns it is recycled
/// wholesale rather than edited.
final class GlyphAtlasEntry {
  const GlyphAtlasEntry._({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.left,
    required this.top,
    required this.plotIndex,
  });

  /// Top-left texel of the coverage inside the atlas.
  final int x;
  final int y;

  /// Size of the coverage in texels, which is also its size in device pixels:
  /// the quad is drawn one texel per pixel, so nearest filtering reproduces
  /// the rasteriser's bytes exactly.
  final int width;
  final int height;

  /// Offset of the coverage's top-left corner from the pen position, in whole
  /// pixels - [GlyphMask.left] and [GlyphMask.top] carried through unchanged.
  /// [top] is nearly always negative, because glyphs rise above the baseline.
  final int left;
  final int top;

  /// The plot holding this entry, or -1 for a blank glyph that holds no
  /// texels at all.
  final int plotIndex;

  /// True for a glyph that draws nothing - a space, or an outline that
  /// collapsed below a pixel.
  ///
  /// Cached rather than skipped, because a space is in every run and a lookup
  /// that missed on it would rasterise (and re-decode its outline) on every
  /// frame forever.
  bool get isBlank => width == 0 || height == 0;

  @override
  String toString() => isBlank
      ? 'GlyphAtlasEntry(blank)'
      : 'GlyphAtlasEntry(${width}x$height at $x,$y, pen offset $left,$top, '
          'plot $plotIndex)';
}

/// Why [GpuGlyphAtlas.acquire] returned null.
///
/// Two failures rather than one because they need opposite reactions: a full
/// atlas is fixed by flushing and recycling, and a glyph too large for a plot
/// is not fixed by anything this class can do.
enum GlyphAtlasFailure {
  none,

  /// Every plot is either full or pinned to the current frame.
  atlasFull,

  /// The glyph does not fit in an empty plot, padding included.
  glyphTooLarge,
}

/// A rectangle reserved by a [GlyphPacker], in the packer's own coordinates.
final class GlyphPackerSlot {
  const GlyphPackerSlot(this.x, this.y);

  final int x;
  final int y;

  @override
  String toString() => 'GlyphPackerSlot($x, $y)';
}

/// Reserves rectangles inside one plot.
///
/// An interface with three members, and it exists to be replaced. The shelf
/// packer in `gpu_texture.dart` is being consolidated separately; wrapping it
/// in this interface later is a five-line adapter, and until then
/// [ShelfGlyphPacker] below keeps this file free of a dependency on a file
/// that is changing underneath it. Nothing outside the packer knows how a slot
/// was chosen, which is what makes that swap safe.
abstract interface class GlyphPacker {
  int get width;
  int get height;

  /// Texels left empty on every side of a reserved rectangle. The atlas reads
  /// this to decide whether a glyph can fit at all, and zeroes exactly this
  /// many texels around each slot it writes.
  int get padding;

  /// Reserves [w] by [h] texels plus [padding] on each side, returning the
  /// top-left texel of the *unpadded* rectangle, or null when there is no
  /// room. Null rather than an exception: running out is an expected state
  /// that the atlas answers with eviction.
  GlyphPackerSlot? allocate(int w, int h);

  /// Forgets every reservation. The texels are not cleared - whoever writes a
  /// slot writes all of it, plus the ring around it.
  void reset();
}

/// Builds the packer for one plot. See [GpuGlyphAtlas.new].
typedef GlyphPackerFactory = GlyphPacker Function(
  int width,
  int height,
  int padding,
);

/// Rows of equal height, filled left to right, best fit by height.
///
/// The same family of packer the mask atlas uses, and for the same reason:
/// what goes in is glyph coverage, whose heights cluster tightly around a line
/// of text's, so the waste a shelf leaves between the tallest item on a row
/// and the rest is small. Best fit rather than first fit, because first fit
/// drops a 4 px comma onto a 40 px shelf and loses that column of the plot
/// until the plot is recycled.
final class ShelfGlyphPacker implements GlyphPacker {
  ShelfGlyphPacker({
    required this.width,
    required this.height,
    this.padding = 1,
  })  : assert(width > 0 && height > 0),
        assert(padding >= 0);

  @override
  final int width;

  @override
  final int height;

  @override
  final int padding;

  /// `y`, `height`, `nextX` per shelf, flat so a scan touches one array.
  final List<int> _shelves = <int>[];

  int _nextShelfY = 0;

  /// How many shelves are open, for diagnostics.
  int get shelfCount => _shelves.length ~/ 3;

  @override
  GlyphPackerSlot? allocate(int w, int h) {
    if (w <= 0 || h <= 0) return null;
    final int paddedWidth = w + padding * 2;
    final int paddedHeight = h + padding * 2;
    if (paddedWidth > width || paddedHeight > height) return null;

    var bestIndex = -1;
    var bestHeight = 1 << 30;
    for (var i = 0; i < _shelves.length; i += 3) {
      final int shelfHeight = _shelves[i + 1];
      if (shelfHeight < paddedHeight || shelfHeight >= bestHeight) continue;
      if (_shelves[i + 2] + paddedWidth > width) continue;
      bestIndex = i;
      bestHeight = shelfHeight;
    }

    if (bestIndex >= 0) {
      final int x = _shelves[bestIndex + 2];
      _shelves[bestIndex + 2] = x + paddedWidth;
      return GlyphPackerSlot(x + padding, _shelves[bestIndex] + padding);
    }

    if (_nextShelfY + paddedHeight > height) return null;
    final int y = _nextShelfY;
    _nextShelfY += paddedHeight;
    _shelves
      ..add(y)
      ..add(paddedHeight)
      ..add(paddedWidth);
    return GlyphPackerSlot(padding, y + padding);
  }

  @override
  void reset() {
    _shelves.clear();
    _nextShelfY = 0;
  }
}

/// Where the atlas gets coverage for a glyph it does not have.
///
/// An interface rather than a hard dependency on [GlyphRasterizer] for two
/// reasons. A test needs to *count* rasterisations to prove that a glyph drawn
/// on ten frames was rasterised once, and [GlyphRasterizer] is a `final class`
/// that cannot be subclassed. And a host that already keeps a [GlyphCache] for
/// its CPU renderer can hand the same masks to both rather than rasterising
/// each glyph twice.
abstract interface class GlyphMaskSource {
  /// The mask for [glyphId] of [font], shifted right by [subpixelOffsetX].
  ///
  /// The signature is [GlyphRasterizer.render]'s, deliberately, so an adapter
  /// is one line and a divergence is a compile error.
  GlyphMask render(
    ScaledTypeface font,
    int glyphId, {
    double subpixelOffsetX,
  });
}

/// The default source: the framework's own scanline rasteriser.
///
/// Holds one [GlyphRasterizer], because it reuses its edge and accumulator
/// buffers between glyphs and building one per call would throw that away.
final class GlyphRasterizerSource implements GlyphMaskSource {
  final GlyphRasterizer rasterizer = GlyphRasterizer();

  @override
  GlyphMask render(
    ScaledTypeface font,
    int glyphId, {
    double subpixelOffsetX = 0,
  }) =>
      rasterizer.render(font, glyphId, subpixelOffsetX: subpixelOffsetX);
}

/// A CPU-side alpha8 staging image of glyph coverage that survives frames.
///
/// The texture itself lives in the backend; this owns the bytes, the packing
/// and the residency, and tells the backend which rectangles changed.
final class GpuGlyphAtlas {
  /// Creates an atlas of [width] by [height] texels, in [plotSize] squares.
  ///
  /// The defaults hold roughly a thousand glyphs of a 16 px UI face: sixteen
  /// 256 px plots, which is enough for several faces and sizes at once while
  /// keeping a plot small enough that losing one to eviction is cheap. Both
  /// dimensions must be whole multiples of [plotSize]; a leftover strip would
  /// be texels that can never be allocated and never be found missing.
  GpuGlyphAtlas({
    this.width = 1024,
    this.height = 1024,
    this.plotSize = 256,
    this.padding = 1,
    GlyphMaskSource? source,
    GlyphPackerFactory? packerFactory,
  })  : assert(width > 0 && height > 0),
        assert(plotSize > 0),
        assert(padding >= 0),
        pixels = Uint8List(width * height),
        texelWidth = 1.0 / width,
        texelHeight = 1.0 / height,
        _source = source ?? GlyphRasterizerSource() {
    if (width % plotSize != 0 || height % plotSize != 0) {
      throw ArgumentError.value(
        plotSize,
        'plotSize',
        'must divide both atlas dimensions (${width}x$height); a leftover '
            'strip would be texels no plot can allocate and no diagnostic can '
            'account for',
      );
    }
    final GlyphPackerFactory factory = packerFactory ?? _defaultPacker;
    for (var y = 0; y < height; y += plotSize) {
      for (var x = 0; x < width; x += plotSize) {
        _plots.add(
          _Plot(_plots.length, x, y, factory(plotSize, plotSize, padding)),
        );
      }
    }
  }

  final int width;
  final int height;

  /// Side of one plot, the unit of eviction and of upload.
  final int plotSize;

  /// Texels left empty around every glyph. See the library comment for why
  /// this is one and not zero.
  final int padding;

  /// One byte of coverage per texel, row-major, `bytesPerRow == width`.
  final Uint8List pixels;

  /// `1 / width` and `1 / height`, so turning a texel into a texture
  /// coordinate on the per-glyph path is a multiply rather than a divide.
  final double texelWidth;
  final double texelHeight;

  final GlyphMaskSource _source;

  final List<_Plot> _plots = <_Plot>[];

  /// Resident glyphs by packed key. A plain map: recency is tracked per plot,
  /// not per entry, so nothing here depends on iteration order.
  final Map<int, GlyphAtlasEntry> _entries = <int, GlyphAtlasEntry>{};

  /// Dense small indices for the faces seen, so a face fits in the packed key.
  ///
  /// Identity-keyed, matching [GlyphCache]: a face parsed twice from the same
  /// bytes is two objects with independently decoded outlines, and treating
  /// them as one would hand out coverage built from the other's tables.
  final Map<Typeface, int> _faceIndices = <Typeface, int>{};

  int _frame = 0;
  int _hitCount = 0;
  int _missCount = 0;
  int _evictionCount = 0;
  int _plotRecycleCount = 0;
  GlyphAtlasFailure _lastFailure = GlyphAtlasFailure.none;

  GpuTextureFormat get format => GpuTextureFormat.alpha8;

  /// Frames begun since construction. Also the value a plot's last use is
  /// compared against, which is why it must advance once per frame exactly.
  int get frameIndex => _frame;

  int get plotCount => _plots.length;

  /// Plots holding at least one glyph.
  int get usedPlotCount {
    var used = 0;
    for (final _Plot plot in _plots) {
      if (!plot.isEmpty) used++;
    }
    return used;
  }

  /// Glyphs resident right now.
  int get entryCount => _entries.length;

  /// Lookups answered from the atlas - the number text performance depends on.
  int get hitCount => _hitCount;

  /// Lookups that had to rasterise. After the first frame of a static screen
  /// this must stop increasing; that is the whole claim this file makes.
  int get missCount => _missCount;

  /// Glyph entries dropped by plot recycling.
  int get evictionCount => _evictionCount;

  /// Plots recycled, by eviction or by [recycleAll].
  int get plotRecycleCount => _plotRecycleCount;

  /// Why the last [acquire] returned null. [GlyphAtlasFailure.none] once a
  /// later call succeeded, so it is only meaningful immediately after a null.
  GlyphAtlasFailure get lastFailure => _lastFailure;

  /// Whether the atlas ran out of room for a glyph the current frame wanted.
  ///
  /// The signal, in place of an exception: fullness is a state a caller that
  /// knows how to flush can recover from, and only a caller that does not can
  /// turn it into an error. Recovering means issuing the draw calls recorded
  /// so far, uploading, and calling [recycleAll] - in that order, because
  /// until the draws are issued the texels are still being read.
  bool get needsFlush => _lastFailure == GlyphAtlasFailure.atlasFull;

  /// Whether anything has been written since the last [markUploaded].
  bool get isDirty {
    for (final _Plot plot in _plots) {
      if (plot.isDirty) return true;
    }
    return false;
  }

  /// How many rectangles [forEachDirtyRegion] would visit.
  int get dirtyRegionCount {
    var count = 0;
    for (final _Plot plot in _plots) {
      if (plot.isDirty) count++;
    }
    return count;
  }

  /// Advances to the next frame. Keeps every glyph - that is the point.
  ///
  /// It does *not* clear the dirty region: what changed still has to reach the
  /// texture, and only the backend knows when it has. Call [markUploaded] for
  /// that.
  void beginFrame() {
    _frame++;
    _lastFailure = GlyphAtlasFailure.none;
  }

  /// The atlas entry for [glyphId] of [font] at [subpixelBucket], rasterising
  /// and packing it if this is the first time it has been asked for.
  ///
  /// Returns null only when the glyph could not be placed; [lastFailure] then
  /// says which of the two reasons it was. A glyph that draws nothing comes
  /// back as an entry with [GlyphAtlasEntry.isBlank] set, not as null, so that
  /// a space is a hit rather than a rasterisation every frame.
  ///
  /// Allocates nothing on a hit. On a miss it allocates a mask, an entry and
  /// possibly a slot - a miss has already paid for a rasterisation, so one
  /// small object is noise, and the whole design is that misses stop.
  GlyphAtlasEntry? acquire(
    ScaledTypeface font,
    int glyphId, {
    int subpixelBucket = 0,
  }) {
    if (subpixelBucket < 0 || subpixelBucket >= kSubpixelBuckets) {
      throw ArgumentError.value(
        subpixelBucket,
        'subpixelBucket',
        'must be in 0..${kSubpixelBuckets - 1}; use glyphSubpixelBucket, and '
            'use its glyphPixelOrigin for the quad or the glyph lands a pixel '
            'off',
      );
    }
    if (glyphId < 0 || glyphId > _maxGlyphId) {
      throw ArgumentError.value(
        glyphId,
        'glyphId',
        'outside the key\'s 16-bit range; a TrueType face cannot have more '
            'than ${_maxGlyphId + 1} glyphs, so this id did not come from one',
      );
    }
    final int sizeKey = (font.pixelSize * kSizeQuantum).round();
    if (sizeKey <= 0 || sizeKey > _maxSizeKey) {
      throw ArgumentError.value(
        font.pixelSize,
        'font.pixelSize',
        'outside the key\'s 26.6 range of 1/$kSizeQuantum..'
            '${_maxSizeKey ~/ kSizeQuantum} px; text that large belongs on the '
            'path rasteriser, where it costs one mask instead of an atlas',
      );
    }

    _lastFailure = GlyphAtlasFailure.none;
    final int key = _packKey(
      _faceIndexOf(font.typeface),
      sizeKey,
      glyphId,
      subpixelBucket,
    );

    final GlyphAtlasEntry? cached = _entries[key];
    if (cached != null) {
      _hitCount++;
      // Touching the plot, not the entry: the plot is the unit of eviction,
      // so this is the whole of the LRU bookkeeping.
      if (cached.plotIndex >= 0) {
        _plots[cached.plotIndex].lastUsedFrame = _frame;
      }
      return cached;
    }

    _missCount++;
    // Rasterised at the quantised size rather than the requested one, so the
    // key fixes the texels. Identical to what GlyphCache does, on purpose.
    final double quantisedSize = sizeKey / kSizeQuantum;
    final ScaledTypeface canonical = quantisedSize == font.pixelSize
        ? font
        : ScaledTypeface(font.typeface, quantisedSize);
    final GlyphMask mask = _source.render(
      canonical,
      glyphId,
      subpixelOffsetX: glyphSubpixelOffset(subpixelBucket),
    );

    if (mask.isEmpty) {
      const GlyphAtlasEntry blank = GlyphAtlasEntry._(
        x: 0,
        y: 0,
        width: 0,
        height: 0,
        left: 0,
        top: 0,
        plotIndex: -1,
      );
      _entries[key] = blank;
      return blank;
    }

    return _place(key, mask);
  }

  /// Whether a glyph is resident, *without* counting as a use.
  ///
  /// For diagnostics and for tests that assert an entry survived an eviction;
  /// going through [acquire] there would touch the plot it is asking about and
  /// change the answer it is checking.
  bool isResident(
    ScaledTypeface font,
    int glyphId, {
    int subpixelBucket = 0,
  }) {
    final int sizeKey = (font.pixelSize * kSizeQuantum).round();
    final int? faceIndex = _faceIndices[font.typeface];
    if (faceIndex == null) return false;
    return _entries
        .containsKey(_packKey(faceIndex, sizeKey, glyphId, subpixelBucket));
  }

  /// Visits every rectangle written since the last [markUploaded].
  ///
  /// One call per plot that changed, in atlas coordinates, which is what the
  /// backend turns into `glTexSubImage2D` calls. Plot-granular rather than one
  /// rectangle for the whole atlas: two glyphs admitted into opposite corners
  /// would otherwise union into a full-atlas upload, which is the megabyte per
  /// frame this class exists to avoid. It is also not per glyph - a driver
  /// call per glyph costs more than the few unchanged texels in between.
  ///
  /// Allocation-free: nothing is built to describe the regions.
  void forEachDirtyRegion(
    void Function(int x, int y, int width, int height) visit,
  ) {
    for (final _Plot plot in _plots) {
      if (!plot.isDirty) continue;
      visit(
        plot.dirtyLeft,
        plot.dirtyTop,
        plot.dirtyRight - plot.dirtyLeft,
        plot.dirtyBottom - plot.dirtyTop,
      );
    }
  }

  /// Declares every dirty region consumed. The backend calls this after the
  /// upload; nothing else may, or a glyph is drawn from texels the texture
  /// never received.
  void markUploaded() {
    for (final _Plot plot in _plots) {
      plot.clearDirty();
    }
  }

  /// Frees every plot, including ones the current frame has drawn from.
  ///
  /// The recovery half of [needsFlush], and legal only once the backend has
  /// issued the draw calls that sample those texels. Calling it earlier
  /// repaints already-emitted glyphs with whatever is packed next, which looks
  /// like random letters swapping places.
  void recycleAll() {
    for (final _Plot plot in _plots) {
      if (!plot.isEmpty) _plotRecycleCount++;
      _evictionCount += plot.keys.length;
      plot.recycle();
    }
    _entries.clear();
    _lastFailure = GlyphAtlasFailure.none;
  }

  /// Drops everything, including the counters' notion of what is resident.
  ///
  /// Separate from [recycleAll] only in that it is what a caller means when it
  /// is throwing the atlas away rather than making room in it.
  void clear() {
    recycleAll();
    _faceIndices.clear();
  }

  @override
  String toString() => 'GpuGlyphAtlas(${width}x$height in $plotSize plots, '
      '$entryCount glyphs in $usedPlotCount/$plotCount plots, '
      'hits $_hitCount, misses $_missCount, evictions $_evictionCount)';

  // -------------------------------------------------------------------
  // Packing and residency
  // -------------------------------------------------------------------

  /// Finds room for [mask], evicting one plot if it has to.
  GlyphAtlasEntry? _place(int key, GlyphMask mask) {
    if (mask.width + padding * 2 > plotSize ||
        mask.height + padding * 2 > plotSize) {
      // No eviction helps, and no tiling exists. Said as its own failure so a
      // caller does not answer it by flushing forever.
      _lastFailure = GlyphAtlasFailure.glyphTooLarge;
      return null;
    }

    _Plot? plot;
    GlyphPackerSlot? slot;
    for (final _Plot candidate in _plots) {
      final GlyphPackerSlot? attempt =
          candidate.packer.allocate(mask.width, mask.height);
      if (attempt != null) {
        plot = candidate;
        slot = attempt;
        break;
      }
    }

    if (slot == null) {
      final _Plot? victim = _evictOnePlot();
      if (victim == null) {
        _lastFailure = GlyphAtlasFailure.atlasFull;
        return null;
      }
      slot = victim.packer.allocate(mask.width, mask.height);
      if (slot == null) {
        // A freshly recycled plot that still cannot hold a glyph the size
        // check above admitted means the packer disagrees with [padding].
        throw StateError(
          'a recycled ${plotSize}x$plotSize plot refused a '
          '${mask.width}x${mask.height} glyph; the packer\'s padding and the '
          'atlas\'s disagree',
        );
      }
      plot = victim;
    }

    final int x = plot!.x + slot.x;
    final int y = plot.y + slot.y;
    _write(mask, x, y, plot);

    final GlyphAtlasEntry entry = GlyphAtlasEntry._(
      x: x,
      y: y,
      width: mask.width,
      height: mask.height,
      left: mask.left,
      top: mask.top,
      plotIndex: plot.index,
    );
    _entries[key] = entry;
    plot.keys.add(key);
    plot.lastUsedFrame = _frame;
    return entry;
  }

  /// Recycles the least recently used plot that the current frame has not
  /// drawn from, or returns null when there is no such plot.
  ///
  /// Empty plots are skipped: recycling one frees nothing, and returning it
  /// would turn a genuinely full atlas into an infinite retry.
  _Plot? _evictOnePlot() {
    _Plot? victim;
    for (final _Plot plot in _plots) {
      if (plot.isEmpty) continue;
      // The pin. A plot this frame has already sampled must survive the frame,
      // or quads already in the vertex buffer sample the next tenant.
      if (plot.lastUsedFrame == _frame) continue;
      if (victim == null || plot.lastUsedFrame < victim.lastUsedFrame) {
        victim = plot;
      }
    }
    if (victim == null) return null;

    for (final int key in victim.keys) {
      if (_entries.remove(key) != null) _evictionCount++;
    }
    _plotRecycleCount++;
    victim.recycle();
    return victim;
  }

  /// Copies [mask] to ([x], [y]) and zeroes the ring of padding around it.
  void _write(GlyphMask mask, int x, int y, _Plot plot) {
    for (var row = 0; row < mask.height; row++) {
      final int destination = (y + row) * width + x;
      pixels.setRange(
        destination,
        destination + mask.width,
        mask.coverage,
        row * mask.width,
      );
    }

    // The ring is zeroed rather than left alone because a recycled plot's
    // texels are the previous tenant's ink, and a bilinear tap that reaches
    // into them is exactly the bleed [padding] exists to prevent.
    final int left = _clampX(x - padding);
    final int top = _clampY(y - padding);
    final int right = _clampX(x + mask.width + padding);
    final int bottom = _clampY(y + mask.height + padding);
    for (var row = top; row < y; row++) {
      pixels.fillRange(row * width + left, row * width + right, 0);
    }
    for (var row = y + mask.height; row < bottom; row++) {
      pixels.fillRange(row * width + left, row * width + right, 0);
    }
    for (var row = y; row < y + mask.height; row++) {
      final int base = row * width;
      pixels.fillRange(base + left, base + x, 0);
      pixels.fillRange(base + x + mask.width, base + right, 0);
    }

    plot.growDirty(left, top, right, bottom);
  }

  int _clampX(int value) => value < 0 ? 0 : (value > width ? width : value);

  int _clampY(int value) => value < 0 ? 0 : (value > height ? height : value);

  int _faceIndexOf(Typeface face) => _faceIndices[face] ??= _faceIndices.length;

  static GlyphPacker _defaultPacker(int width, int height, int padding) =>
      ShelfGlyphPacker(width: width, height: height, padding: padding);

  // The key. Multiplication rather than shifts, because on the web an `int` is
  // a double and the bitwise operators truncate to 32 bits, which would mangle
  // a 52-bit key. Every constant below mirrors `glyph_cache.dart`; see the
  // library comment for why they must keep mirroring it.
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

  static const int _glyphStride = kSubpixelBuckets;
  static const int _maxGlyphId = 0xFFFF;
  static const int _sizeStride = _glyphStride * (_maxGlyphId + 1);
  static const int _maxSizeKey = 0x3FFFF;
  static const int _faceStride = _sizeStride * (_maxSizeKey + 1);
}

/// One square of the atlas: a packer, the glyphs in it, and when it was last
/// drawn from.
final class _Plot {
  _Plot(this.index, this.x, this.y, this.packer);

  final int index;

  /// Top-left texel of this plot within the atlas.
  final int x;
  final int y;

  final GlyphPacker packer;

  /// Keys of the entries packed here, so recycling can drop them from the
  /// atlas's map. A list rather than a set: it is appended to per admission
  /// and walked once per recycle, and never searched.
  final List<int> keys = <int>[];

  /// The frame this plot was last read or written. -1 for never, which sorts
  /// before every real frame and so makes an untouched plot the first victim.
  int lastUsedFrame = -1;

  int dirtyLeft = 0;
  int dirtyTop = 0;
  int dirtyRight = 0;
  int dirtyBottom = 0;

  bool get isDirty => dirtyRight > dirtyLeft && dirtyBottom > dirtyTop;

  bool get isEmpty => keys.isEmpty;

  void growDirty(int left, int top, int right, int bottom) {
    if (!isDirty) {
      dirtyLeft = left;
      dirtyTop = top;
      dirtyRight = right;
      dirtyBottom = bottom;
      return;
    }
    if (left < dirtyLeft) dirtyLeft = left;
    if (top < dirtyTop) dirtyTop = top;
    if (right > dirtyRight) dirtyRight = right;
    if (bottom > dirtyBottom) dirtyBottom = bottom;
  }

  void clearDirty() {
    dirtyLeft = 0;
    dirtyTop = 0;
    dirtyRight = 0;
    dirtyBottom = 0;
  }

  /// Empties this plot without clearing its texels. The next glyph written
  /// here zeroes its own padding ring, which is the only part of the stale
  /// content anything can sample.
  void recycle() {
    keys.clear();
    packer.reset();
    lastUsedFrame = -1;
  }
}
