/// The antialiasing strategy for everything that is not an axis-aligned
/// rectangle, and the reasoning that chose it.
///
/// ## The three honest options
///
/// **A. Tessellate on the CPU, upload triangles.** Flatten each path to a
/// polygon, triangulate it, upload the triangles. Cheap per pixel and the
/// geometry caches well under a static transform. Two costs: there is no
/// triangulator in this repository, and a correct one for self-intersecting
/// contours under both fill rules is a substantial piece of work with its own
/// numerical failure modes; and triangles have *hard edges*. Antialiasing
/// them means adding a feathered border strip whose coverage is a per-vertex
/// ramp, which is an approximation that visibly fails where two contours meet
/// at a shallow angle - exactly the case a font renders all day.
///
/// **B. MSAA.** Ask the surface for 4 or 8 samples and let the hardware do
/// it. Trivial to implement and wrong in a specific, well-known way: N
/// samples give N+1 levels of grey, so a nearly horizontal edge bands into
/// visible steps, and 4x MSAA quadruples the bandwidth of every pixel in the
/// surface to improve the few percent that are on an edge. It also does not
/// exist on a software GL implementation with any useful performance, which
/// would make the one configuration this backend is *verifiable* in the one
/// configuration where its antialiasing is untested.
///
/// **C. CPU analytic coverage into a mask texture, sampled by one quad.**
/// Run the existing [ScanlineFiller] - which computes exact area coverage,
/// not samples - into an 8-bit atlas, upload the dirty region once per frame,
/// and draw each shape as a single textured quad that multiplies the paint
/// colour by the mask.
///
/// ## The choice: C, with rectangles taking a shader shortcut
///
/// Chosen because it is the only one of the three that gives the *same*
/// antialiasing the CPU renderer already produces. That is not an aesthetic
/// preference: section 23.7 of the roadmap requires CPU/GPU parity to be
/// measured, and a golden test can only compare a GPU frame against
/// `MemoryRenderTarget` if the two rasterise coverage the same way. With C
/// the two differ only in how coverage is quantised (the CPU folds a byte
/// through `mul255`, the shader multiplies floats), which is a bounded
/// one-or-two-level difference rather than a different-looking edge.
///
/// It also reuses code that exists and is tested, instead of adding a
/// triangulator that would need its own correctness corpus before drawing a
/// single correct frame.
///
/// Axis-aligned rectangles skip the atlas entirely. Their coverage is
/// separable - the area of a pixel square inside an axis-aligned rect is the
/// product of the x overlap and the y overlap - so the fragment shader
/// computes it exactly in two clamps and a multiply, with no texture, no
/// upload and no atlas pressure. Since a UI is mostly rectangles, that keeps
/// the expensive path off the common case. See [GpuPipelineKind.solid].
///
/// ## Rasterising is CPU work, so it is cached across frames
///
/// A path costs the same CPU time it costs on the CPU backend, plus an
/// upload. The GPU wins the compositing, the blending and the fill rate; it
/// does not win the path. That is why [GpuMaskAtlas] keeps its slots **across
/// frames** and looks a shape up by content before rasterising it: a static
/// icon, a rounded rectangle that did not move, a button redrawn every frame
/// because something else animated - each of those costs one rasterisation
/// ever, and every later frame costs a map lookup and a quad.
///
/// What that buys is bounded and worth stating: an *animated* path still
/// rasterises every frame, because its device geometry genuinely changes and
/// its coverage bytes with it. Sub-pixel motion is animation. Whole-pixel
/// motion is not - see [GpuMaskAtlas.rasterizeMask] for exactly which
/// changes miss the cache and why each one has to.
///
/// ## What this cannot do yet, said plainly
///
///   * **Nothing here rasterises on the GPU.** Coverage is computed by the
///     CPU scanline filler. The cache removes the *repeat* cost, not the
///     first one.
///   * **A shape larger than the atlas is refused by name, not tiled.**
///     [MaskRasterStatus.tooLarge] says so specifically, and the caller can
///     tile it itself with the recipe on that constant - the clip is part of
///     the mask's identity, so one call per tile is already correct. What
///     this class will not do is split a draw call the caller owns.
///   * **The flush cycle needs a backend that implements it.** This class can
///     say "I am full and everything in me is in use this frame"
///     ([MaskRasterStatus.needsFlush]); actually uploading the dirty region
///     and submitting the pending batches is the backend's half. `GpuRasterSink`
///     performs that half through its `onAtlasFlush` hook and retries once, so
///     a full atlas costs an extra pass rather than failing the frame; a sink
///     constructed without the hook still turns the signal into a named error,
///     because drawing the shape from a recycled atlas would draw it wrong.
///     The protocol is spelled out on [MaskRasterStatus.needsFlush].
///   * **Stroke expansion happens before this layer.** [GpuRasterSink] uses
///     the shared `PathStroker` to turn a centreline into a fillable outline;
///     this atlas therefore remains concerned with coverage and fill rules,
///     independent of how geometry was produced.
///   * **No path clipping.** The clip is still a rectangle. This file is
///     literally the machinery a clip mask needs - the next user of it.
library;

import 'dart:typed_data';

import '../../geometry/path.dart';
import '../../geometry/rect.dart';
import '../../geometry/transform2d.dart';
import '../path/coverage_span_sink.dart';
import '../path/fill_rule.dart';
import '../path/scanline_filler.dart';
import 'gpu_pipeline.dart';
import 'gpu_texture.dart';

/// Where a rasterised mask ended up: the device pixels it covers and the
/// texels that hold its coverage.
///
/// [deviceRect] is always on whole pixels. The shape inside it is fractional;
/// the mask carries that fraction, which is the point.
final class MaskQuad {
  const MaskQuad(this.deviceRect, this.u0, this.v0, this.u1, this.v1);

  final Rect deviceRect;
  final double u0;
  final double v0;
  final double u1;
  final double v1;

  @override
  String toString() => 'MaskQuad($deviceRect, uv $u0,$v0..$u1,$v1)';
}

/// The four answers [GpuMaskAtlas.rasterizeMask] can give.
///
/// Four and not two, because "no quad for you" hides three completely
/// different situations that need three different reactions, and collapsing
/// them is how a frame ends up failing over a shape that was merely
/// off-screen.
enum MaskRasterStatus {
  /// A quad is available. It may or may not have cost a rasterisation; the
  /// caller cannot tell and does not need to.
  ok,

  /// The shape covers no device pixel - clipped away, degenerate, or with a
  /// non-finite device rectangle. Nothing to draw and nothing wrong.
  empty,

  /// The shape fits in this atlas, but not right now: every texel is spoken
  /// for by a mask that has already been used **in this frame**, so nothing
  /// can be evicted without changing texels a quad already in the vertex
  /// buffer points at.
  ///
  /// This is a resource limit, not a missing capability, and the recovery is
  /// mechanical:
  ///
  /// ```dart
  /// var result = atlas.rasterizeMask(path, transform: t, clip: c);
  /// if (result.status == MaskRasterStatus.needsFlush) {
  ///   batcher.flush();          // close the open batch
  ///   backend.uploadDirtyRegionOf(atlas);
  ///   backend.submitPending();  // draw everything batched so far
  ///   atlas.markUploaded();
  ///   atlas.recycle();          // every texel is free again
  ///   result = atlas.rasterizeMask(path, transform: t, clip: c);
  /// }
  /// ```
  ///
  /// The order is not negotiable. The submit has to happen **before** the
  /// recycle, because recycling declares every texel reusable and the pending
  /// draws still sample the old ones. The upload has to happen before the
  /// submit for the same reason in the other direction: the pending draws
  /// sample texels this frame wrote and the texture does not have them yet.
  ///
  /// The retry cannot return [needsFlush] again - the atlas is empty and the
  /// shape was already known to fit one - so a caller that sees two in a row
  /// has found a bug in this file and should say so rather than loop.
  needsFlush,

  /// The shape is larger than an *empty* atlas. Flushing changes nothing;
  /// only a different strategy will draw it.
  ///
  /// Deliberately not tiled here. Tiling a mask means emitting several quads
  /// for one shape, and the quads belong to the caller's batcher, not to this
  /// class; an API that returned a list of them would allocate per draw and
  /// would still leave the caller deciding how many flush cycles a shape
  /// deserves. What this class does instead is make the caller's tiling loop
  /// *correct*: the clip is part of a mask's identity, so
  ///
  /// ```dart
  /// for (final tile in tilesOf(deviceBounds, atlas.maxMaskWidth,
  ///                            atlas.maxMaskHeight)) {
  ///   final result = atlas.rasterizeMask(path, transform: t, clip: tile);
  ///   ...
  /// }
  /// ```
  ///
  /// produces, tile by tile, exactly the coverage one impossible full-size
  /// mask would have carried. That is a property of the scanline filler -
  /// coverage at a pixel depends only on the edges crossing that pixel's row,
  /// and edges outside the clip are clamped onto its boundary rather than
  /// dropped - and it is verified by a test, not assumed.
  ///
  /// A caller that does not want to tile falls back to the CPU renderer or
  /// refuses by name. What it must not do is treat this as "the GPU backend
  /// cannot draw paths", because it can, and only this one is too big.
  tooLarge,
}

/// What [GpuMaskAtlas.rasterizeMask] returns: a status and, when the status
/// is [MaskRasterStatus.ok], the quad to draw.
///
/// The quad's geometry is inlined rather than held as a [MaskQuad] so that
/// the three failure results can be `const` singletons and cost nothing. The
/// success path allocates one of these per drawn mask, which is the same
/// order of allocation the mask path already accepted (see the note on
/// allocation in `gpu_raster_sink.dart`) and is dwarfed by the [Rect] the
/// device bounds need anyway.
final class MaskRasterResult {
  const MaskRasterResult._(
    this.status,
    this.deviceRect,
    this.u0,
    this.v0,
    this.u1,
    this.v1,
  );

  static const MaskRasterResult empty =
      MaskRasterResult._(MaskRasterStatus.empty, Rect.zero, 0, 0, 0, 0);

  static const MaskRasterResult needsFlush =
      MaskRasterResult._(MaskRasterStatus.needsFlush, Rect.zero, 0, 0, 0, 0);

  static const MaskRasterResult tooLarge =
      MaskRasterResult._(MaskRasterStatus.tooLarge, Rect.zero, 0, 0, 0, 0);

  final MaskRasterStatus status;

  /// Whole device pixels the quad covers. [Rect.zero] unless [isOk].
  final Rect deviceRect;

  /// Texel *edges* in `0..1`, not centres. Meaningless unless [isOk].
  final double u0;
  final double v0;
  final double u1;
  final double v1;

  bool get isOk => status == MaskRasterStatus.ok;

  /// The same geometry as a [MaskQuad], for callers holding the older shape.
  /// Allocates; a caller on the batching path should read the fields.
  MaskQuad toQuad() => MaskQuad(deviceRect, u0, v0, u1, v1);

  @override
  String toString() => isOk
      ? 'MaskRasterResult(ok, $deviceRect, uv $u0,$v0..$u1,$v1)'
      : 'MaskRasterResult(${status.name})';
}

/// A CPU-side alpha8 staging image, the packer that carves it up, and a cache
/// that keeps a mask alive until its space is needed.
///
/// The texture itself lives in the backend; this owns the bytes and the
/// dirty region, so the upload is one `glTexSubImage2D` per frame over the
/// rectangle that actually changed rather than one per shape.
///
/// ## The cache key, component by component
///
/// A mask is identified by everything that changes a coverage byte, and by
/// nothing else. Getting this list wrong in the *incomplete* direction draws
/// the wrong shape - the worst failure mode available here, far worse than
/// not caching - so each component is justified:
///
///   * **The path**, by content. [Path] defines `==` and a precomputed
///     [Path.hashCode] over its verb and point streams, so two separately
///     built copies of the same icon are one entry.
///   * **The linear part of the transform** (`a`, `b`, `c`, `d`). Scale,
///     rotation and skew all change the rasterised outline.
///   * **The sub-pixel phase** (`transform.tx - left`, `transform.ty - top`,
///     where `left`/`top` are the mask's snapped device origin). Not the raw
///     translation: a shape moved by a whole number of pixels produces the
///     *same* coverage bytes at a different address, and re-rasterising it
///     would be pure waste. A shape moved by a third of a pixel produces
///     genuinely different bytes and must miss. Storing the difference
///     expresses exactly that distinction, exactly - no rounding, no
///     quantisation. Quantising the phase to, say, quarter pixels would raise
///     the hit rate and shift shapes by up to an eighth of a pixel, which is
///     a visible seam between a mask and the rectangle beside it.
///   * **The mask's pixel size** (`w`, `h`). This is where the **clip**
///     enters. The clip never appears in the key literally, because its only
///     influence on the bytes is through the snapped rectangle it produces
///     together with the path's device bounds; two clips that leave the same
///     window over the same phase leave the same mask. A partially clipped
///     shape therefore cannot be confused with the unclipped one: its window
///     is smaller.
///   * **The fill rule.** A self-intersecting contour is solid under
///     non-zero and hollow under even-odd.
///   * **Anti-aliasing.** An aliased mask is the same coverage thresholded,
///     which is a different set of bytes.
///
/// Not in the key, and each for a reason: the paint colour, alpha and blend
/// mode (they are vertex data and never touch the mask); the flattening
/// tolerance (this class never varies it); the atlas slot (that is the
/// *answer*, not the question).
///
/// A key holding NaN never equals itself, so such a mask is rasterised every
/// frame and its entry is evicted like any other. That is the same behaviour
/// [Path.operator ==] already has for NaN coordinates, and it is a symptom of
/// the NaN rather than of the cache.
///
/// ## Eviction policy, stated out loud
///
///   * **Nothing is evicted by age.** A mask stays until its space is needed.
///     An atlas full of masks nobody draws any more costs zero - the memory
///     was allocated at construction either way.
///   * **Under pressure, least-recently-used first**, ordered by the last
///     frame the mask was returned in, ties broken by the order within that
///     frame. Victims are taken one at a time until the new mask fits.
///   * **A mask already used in the current frame is never a victim.** Its
///     texels are underneath a quad that is already in the vertex buffer and
///     has not been drawn yet; overwriting them would silently repaint an
///     earlier shape with a later shape's coverage. When the least recently
///     used mask is one of those, there is nothing evictable at all and the
///     answer is [MaskRasterStatus.needsFlush].
///   * **Repacking is a frame-boundary act.** [compact] moves texels, which
///     invalidates every quad that references them, so it runs from
///     [beginFrame] and never mid-frame. It triggers when [fragmentation]
///     exceeds [compactionThreshold] *and* the packer has already committed
///     half the atlas's rows - below that there is still open space and
///     repacking would buy nothing.
final class GpuMaskAtlas {
  GpuMaskAtlas({
    this.width = 1024,
    this.height = 1024,
    this.compactionThreshold = 0.5,
  })  : assert(width > 0 && height > 0),
        assert(compactionThreshold > 0 && compactionThreshold < 1),
        pixels = Uint8List(width * height),
        _packer = ShelfAtlas(width: width, height: height);

  final int width;
  final int height;

  /// Wasted fraction of the committed rows above which [beginFrame] repacks.
  ///
  /// A half by default: repacking costs a full-atlas copy and a full-atlas
  /// upload in the frame it happens, so it has to be paying for a real amount
  /// of recovered space, and losing half of what the packer has committed is
  /// that. Raising it trades atlas space for upload bandwidth; lowering it
  /// does the opposite.
  final double compactionThreshold;

  /// One byte per texel, row-major, `bytesPerRow == width`.
  final Uint8List pixels;

  final ShelfAtlas _packer;

  /// Kept across frames: it owns the edge and accumulator buffers that must
  /// not be rebuilt per path. Same reason `_RasterizerSink` keeps one.
  final ScanlineFiller _filler = ScanlineFiller();
  late final _MaskSpanSink _sink = _MaskSpanSink(this);

  /// Hash of the cache key to the head of a chain of entries that share it.
  ///
  /// A chain rather than `Map<MaskKey, Entry>` so that a lookup builds no key
  /// object: the hash is computed from scalars and the candidates are
  /// compared field by field. Section 6.5 - the per-primitive path allocates
  /// nothing, and on a cache hit this *is* the per-primitive path.
  final Map<int, _MaskEntry> _buckets = <int, _MaskEntry>{};

  /// Most recently used first. Both ends are held so that a touch is an
  /// unlink and a push, with no scan.
  _MaskEntry? _lruHead;
  _MaskEntry? _lruTail;

  int _frame = 0;
  int _entryCount = 0;
  int _rasterizations = 0;
  int _hits = 0;
  int _evictions = 0;
  int _compactions = 0;

  /// Fragmentation the last repack left behind, or -1 when none has run.
  ///
  /// The anti-thrash term of the compaction policy. Shelf waste is not always
  /// recoverable: an atlas full of masks that are all the same height packs
  /// into the same shelves however it is repacked, and without this a layout
  /// like that would be copied and re-uploaded whole *every frame* for no
  /// gain. A repack is therefore attempted only when the layout is worse than
  /// the one the last repack produced.
  double _lastCompactionFragmentation = -1;

  int _dirtyLeft = 0;
  int _dirtyTop = 0;
  int _dirtyRight = 0;
  int _dirtyBottom = 0;

  GpuTextureFormat get format => GpuTextureFormat.alpha8;

  /// Whether anything was written since the last [markUploaded].
  bool get isDirty => _dirtyRight > _dirtyLeft && _dirtyBottom > _dirtyTop;

  int get dirtyLeft => _dirtyLeft;
  int get dirtyTop => _dirtyTop;
  int get dirtyRight => _dirtyRight;
  int get dirtyBottom => _dirtyBottom;

  /// Shelves the packer currently holds, for diagnostics.
  int get shelfCount => _packer.shelfCount;

  /// Masks currently occupying a slot, whether or not this frame used them.
  int get cachedMaskCount => _entryCount;

  /// How many times a mask was actually run through the scanline filler.
  ///
  /// The number a caching test asserts on, and the number a profile wants:
  /// the difference between this and [maskLookupCount] is what the cache
  /// saved.
  int get rasterizationCount => _rasterizations;

  /// Lookups that found their mask already rasterised.
  int get cacheHitCount => _hits;

  /// Lookups answered with a quad, hit or miss.
  int get maskLookupCount => _hits + _rasterizations;

  /// Masks dropped to make room for another. See the eviction policy.
  int get evictionCount => _evictions;

  int get compactionCount => _compactions;

  /// Frames begun since construction. The clock the LRU order runs on.
  int get frameIndex => _frame;

  /// Fraction of the rows the packer has committed that carry no live mask.
  double get fragmentation => _packer.fragmentation;

  /// The largest mask this atlas can ever hold, in device pixels. Anything
  /// wider or taller is [MaskRasterStatus.tooLarge] and has to be tiled by
  /// the caller or drawn some other way.
  int get maxMaskWidth => _packer.maxSlotWidth;
  int get maxMaskHeight => _packer.maxSlotHeight;

  /// Opens a frame. **Keeps every cached mask.**
  ///
  /// This used to call `reset()` on the packer, which meant a static shape
  /// was re-rasterised on the CPU every single frame and the atlas was a
  /// staging buffer wearing a cache's name. What it does now is advance the
  /// LRU clock, consume the dirty region the backend has just uploaded, and
  /// repack if the layout has become too holey to be worth keeping.
  ///
  /// The repack is here and nowhere else because it moves texels: between
  /// frames every quad that referenced them has been drawn, and mid-frame
  /// they have not.
  void beginFrame() {
    _frame++;
    markUploaded();
    if (_packer.fragmentation > compactionThreshold &&
        _packer.reservedRows * 2 >= height &&
        _packer.fragmentation > _lastCompactionFragmentation) {
      compact();
    }
  }

  /// Declares the dirty region consumed. The backend calls this after the
  /// upload; nothing else may.
  void markUploaded() {
    _dirtyLeft = 0;
    _dirtyTop = 0;
    _dirtyRight = 0;
    _dirtyBottom = 0;
  }

  /// Drops every cached mask and returns the whole atlas to its empty state.
  ///
  /// The second half of the [MaskRasterStatus.needsFlush] cycle, and the
  /// right answer to a lost device or a re-created mask texture: the texels
  /// this class believes are on the GPU are gone, so the entries describing
  /// them are lies and have to go with them.
  ///
  /// Call it **after** the pending draws have been submitted and the dirty
  /// region uploaded. Anything still batched is pointing at texels this call
  /// hands to the next mask. The dirty region is left alone, because whether
  /// it has been uploaded is the caller's fact to state, not this class's to
  /// guess.
  void recycle() {
    _buckets.clear();
    _lruHead = null;
    _lruTail = null;
    _entryCount = 0;
    _packer.reset();
    _lastCompactionFragmentation = -1;
  }

  /// Repacks every live mask tightly and moves its texels to match.
  ///
  /// Only legal between frames - see the eviction policy. Afterwards every
  /// texture coordinate this atlas ever handed out is stale, the whole atlas
  /// is dirty, and the frame that follows pays one full-size upload.
  ///
  /// The masks themselves survive: this moves bytes, it does not re-rasterise
  /// anything, so a compaction costs a memory copy rather than the CPU
  /// rasterisation the cache exists to avoid. A mask that fails to find a
  /// place in the fresh layout - possible in principle, because packing is
  /// order-dependent - is dropped rather than lost track of; it is a cache,
  /// and the next draw rebuilds it.
  ///
  /// Allocates a full-size scratch image for the duration, because packing
  /// in place would overwrite masks not yet moved. That allocation is why
  /// this is threshold-driven and not automatic.
  void compact() {
    _compactions++;
    if (_entryCount == 0) {
      _packer.reset();
      _lastCompactionFragmentation = -1;
      return;
    }

    // Tallest first: shelf packing is order-dependent, and feeding it in
    // descending height is what makes the shelves it opens dense.
    final live = <_MaskEntry>[];
    for (var entry = _lruHead; entry != null; entry = entry.lruNext) {
      live.add(entry);
    }
    live.sort((a, b) => b.h.compareTo(a.h));

    final scratch = Uint8List(width * height);
    _packer.reset();
    for (var i = 0; i < live.length; i++) {
      final entry = live[i];
      final slot = _packer.allocate(entry.w, entry.h);
      if (slot == null) {
        _unlink(entry);
        continue;
      }
      for (var y = 0; y < entry.h; y++) {
        final from = (entry.slot.y + y) * width + entry.slot.x;
        final to = (slot.y + y) * width + slot.x;
        scratch.setRange(to, to + entry.w, pixels, from);
      }
      entry.slot = slot;
      _setUv(entry, slot);
    }
    pixels.setRange(0, pixels.length, scratch);
    _lastCompactionFragmentation = _packer.fragmentation;
    _growDirty(0, 0, width, height);
  }

  /// Rasterises [path] under [transform], clipped to [clip], reusing the
  /// mask from a previous frame when nothing that changes a coverage byte has
  /// changed.
  ///
  /// See the class comment for what "nothing that changes a coverage byte"
  /// means precisely, and [MaskRasterStatus] for the three non-drawing
  /// answers and what a caller does about each.
  ///
  /// [antiAlias] false thresholds the filler's exact area coverage at a half
  /// pixel: a span at 128 or more becomes opaque, anything less disappears.
  /// That is a *coverage* threshold and not a pixel-centre test, so the two
  /// disagree on a thin diagonal wedge that covers more than half of a pixel
  /// without touching its centre - a bounded, stated difference. It is also
  /// not what the CPU backend does today, because `cpu_renderer` fills every
  /// path antialiased and ignores the flag; when it stops ignoring it, this
  /// rule is the one to match, and the two are named together here so they
  /// cannot drift apart silently.
  MaskRasterResult rasterizeMask(
    Path path, {
    required Transform2D transform,
    required Rect clip,
    FillRule rule = FillRule.nonZero,
    bool antiAlias = true,
  }) {
    final visible = transform.transformRect(path.bounds).intersect(clip);
    if (visible.isEmpty) return MaskRasterResult.empty;
    // A non-finite device rectangle would throw out of floor()/ceil() below,
    // and a NaN one is not even caught by isEmpty (every comparison against
    // NaN is false). A shape whose device bounds are not a number covers no
    // definable pixel, so it is empty rather than an exception thrown from
    // three frames deep in a transform chain.
    if (!visible.left.isFinite ||
        !visible.top.isFinite ||
        !visible.right.isFinite ||
        !visible.bottom.isFinite) {
      return MaskRasterResult.empty;
    }

    // Outward to whole pixels: an edge at x = 10.2 still puts ink in column
    // 10, and the mask has to contain every pixel the quad will sample.
    final left = visible.left.floor();
    final top = visible.top.floor();
    final right = visible.right.ceil();
    final bottom = visible.bottom.ceil();
    final w = right - left;
    final h = bottom - top;
    if (w <= 0 || h <= 0) return MaskRasterResult.empty;
    if (!_packer.canEverFit(w, h)) return MaskRasterResult.tooLarge;

    // The sub-pixel phase. See the class comment: this and not tx/ty is what
    // makes a whole-pixel move a cache hit and a fractional one a miss.
    final dx = transform.tx - left;
    final dy = transform.ty - top;
    final hash = _hashKey(path, transform, dx, dy, w, h, rule, antiAlias);

    for (var entry = _buckets[hash]; entry != null; entry = entry.nextInChain) {
      if (entry.matches(path, transform, dx, dy, w, h, rule, antiAlias)) {
        _hits++;
        _touch(entry);
        return _resultFor(entry, left, top);
      }
    }

    final slot = _allocate(w, h);
    if (slot == null) return MaskRasterResult.needsFlush;

    _rasterize(path, transform, slot, left, top, w, h, rule, antiAlias);

    final entry = _MaskEntry(
      hash,
      transform,
      path,
      dx,
      dy,
      w,
      h,
      rule,
      antiAlias,
      slot,
    );
    _setUv(entry, slot);
    entry.nextInChain = _buckets[hash];
    _buckets[hash] = entry;
    _entryCount++;
    _touch(entry);
    return _resultFor(entry, left, top);
  }

  /// [rasterizeMask] for callers that only want the quad.
  ///
  /// Null merges the three non-drawing answers back into one, which is
  /// exactly the ambiguity [MaskRasterStatus] exists to remove - a caller on
  /// this method cannot tell "clipped away" from "flush me" from "impossible"
  /// and will have to guess. It stays because `GpuRasterSink` is owned
  /// elsewhere and still calls it; new code should not.
  MaskQuad? rasterize(
    Path path, {
    required Transform2D transform,
    required Rect clip,
    FillRule rule = FillRule.nonZero,
    bool antiAlias = true,
  }) {
    final result = rasterizeMask(
      path,
      transform: transform,
      clip: clip,
      rule: rule,
      antiAlias: antiAlias,
    );
    return result.isOk ? result.toQuad() : null;
  }

  // -------------------------------------------------------------------
  // Allocation and eviction
  // -------------------------------------------------------------------

  /// A slot for a `w` by `h` mask, evicting as far as the policy allows.
  ///
  /// Null means "not without changing texels this frame already drew with",
  /// which the caller reports as [MaskRasterStatus.needsFlush].
  AtlasSlot? _allocate(int w, int h) {
    var slot = _packer.allocate(w, h);
    while (slot == null) {
      // The tail is the least recently used entry, and every entry used this
      // frame has been moved to the head - so if the tail is from this frame,
      // the whole atlas is, and there is nothing safe to take.
      final victim = _lruTail;
      if (victim == null || victim.lastUsedFrame == _frame) return null;
      _unlink(victim);
      _evictions++;
      slot = _packer.allocate(w, h);
    }
    return slot;
  }

  /// Removes [entry] from the chain, the LRU list and the packer.
  void _unlink(_MaskEntry entry) {
    final head = _buckets[entry.keyHash];
    if (identical(head, entry)) {
      final next = entry.nextInChain;
      if (next == null) {
        _buckets.remove(entry.keyHash);
      } else {
        _buckets[entry.keyHash] = next;
      }
    } else {
      var previous = head;
      while (previous != null && !identical(previous.nextInChain, entry)) {
        previous = previous.nextInChain;
      }
      previous?.nextInChain = entry.nextInChain;
    }
    entry.nextInChain = null;

    final prev = entry.lruPrev;
    final next = entry.lruNext;
    if (prev == null) {
      _lruHead = next;
    } else {
      prev.lruNext = next;
    }
    if (next == null) {
      _lruTail = prev;
    } else {
      next.lruPrev = prev;
    }
    entry.lruPrev = null;
    entry.lruNext = null;

    _packer.free(entry.slot);
    _entryCount--;
  }

  /// Moves [entry] to the head of the LRU list and stamps it with the frame.
  void _touch(_MaskEntry entry) {
    entry.lastUsedFrame = _frame;
    if (identical(_lruHead, entry)) return;

    final prev = entry.lruPrev;
    final next = entry.lruNext;
    if (prev != null) prev.lruNext = next;
    if (next != null) next.lruPrev = prev;
    if (identical(_lruTail, entry)) _lruTail = prev;

    entry.lruPrev = null;
    entry.lruNext = _lruHead;
    _lruHead?.lruPrev = entry;
    _lruHead = entry;
    _lruTail ??= entry;
  }

  // -------------------------------------------------------------------
  // Rasterisation
  // -------------------------------------------------------------------

  void _rasterize(
    Path path,
    Transform2D transform,
    AtlasSlot slot,
    int left,
    int top,
    int w,
    int h,
    FillRule rule,
    bool antiAlias,
  ) {
    _rasterizations++;

    // The slot is reused memory from an evicted mask, and the filler only
    // writes covered spans. Without this the uncovered interior of a shape
    // would show the coverage of whatever used to live here.
    for (var y = 0; y < h; y++) {
      final rowStart = (slot.y + y) * width + slot.x;
      pixels.fillRange(rowStart, rowStart + w, 0);
    }

    // Device space to atlas space is a pure translation, so composing it in
    // front of the path's device transform costs nothing and means the path
    // is never copied or re-flattened into another coordinate system.
    final toAtlas = Transform2D.translation(
      (slot.x - left).toDouble(),
      (slot.y - top).toDouble(),
    ).multiply(transform);

    _sink.aliased = !antiAlias;
    _filler.fill(
      path,
      Rect.fromLTRB(
        slot.x.toDouble(),
        slot.y.toDouble(),
        (slot.x + w).toDouble(),
        (slot.y + h).toDouble(),
      ),
      _sink,
      rule: rule,
      transform: toAtlas,
    );

    _growDirty(slot.x, slot.y, slot.x + w, slot.y + h);
  }

  /// Texel edges, not centres. The quad is exactly `w` by `h` device pixels
  /// and is sampled with nearest filtering, so pixel centres land on texel
  /// centres and the mapping is one to one.
  void _setUv(_MaskEntry entry, AtlasSlot slot) {
    entry
      ..u0 = slot.x / width
      ..v0 = slot.y / height
      ..u1 = (slot.x + entry.w) / width
      ..v1 = (slot.y + entry.h) / height;
  }

  MaskRasterResult _resultFor(_MaskEntry entry, int left, int top) =>
      MaskRasterResult._(
        MaskRasterStatus.ok,
        Rect.fromLTRB(
          left.toDouble(),
          top.toDouble(),
          (left + entry.w).toDouble(),
          (top + entry.h).toDouble(),
        ),
        entry.u0,
        entry.v0,
        entry.u1,
        entry.v1,
      );

  void _growDirty(int left, int top, int right, int bottom) {
    if (!isDirty) {
      _dirtyLeft = left;
      _dirtyTop = top;
      _dirtyRight = right;
      _dirtyBottom = bottom;
      return;
    }
    if (left < _dirtyLeft) _dirtyLeft = left;
    if (top < _dirtyTop) _dirtyTop = top;
    if (right > _dirtyRight) _dirtyRight = right;
    if (bottom > _dirtyBottom) _dirtyBottom = bottom;
  }

  /// The cache key folded into one int, built from scalars so that a lookup
  /// allocates nothing.
  ///
  /// Collisions are handled by the chain, not avoided here: a wrong hash
  /// costs a comparison, while a missing *component* would return the wrong
  /// mask - which is why the component list is the same one
  /// [_MaskEntry.matches] compares, in the same order.
  static int _hashKey(
    Path path,
    Transform2D transform,
    double dx,
    double dy,
    int w,
    int h,
    FillRule rule,
    bool antiAlias,
  ) {
    var hash = path.hashCode;
    hash = 0x3fffffff & (hash * 31 + _hashDouble(transform.a));
    hash = 0x3fffffff & (hash * 31 + _hashDouble(transform.b));
    hash = 0x3fffffff & (hash * 31 + _hashDouble(transform.c));
    hash = 0x3fffffff & (hash * 31 + _hashDouble(transform.d));
    hash = 0x3fffffff & (hash * 31 + _hashDouble(dx));
    hash = 0x3fffffff & (hash * 31 + _hashDouble(dy));
    hash = 0x3fffffff & (hash * 31 + w);
    hash = 0x3fffffff & (hash * 31 + h);
    hash = 0x3fffffff & (hash * 31 + rule.index);
    return 0x3fffffff & (hash * 31 + (antiAlias ? 1 : 0));
  }

  /// -0.0 has to hash like 0.0, because `==` says the two are the same
  /// number and the comparison in [_MaskEntry.matches] uses `==`. The same
  /// trap [Path] documents on its own hash.
  static int _hashDouble(double value) => value == 0 ? 0 : value.hashCode;
}

/// One cached mask: its key, where it lives, and its place in two lists.
///
/// A plain mutable object rather than a record or a pair of maps, because the
/// hash chain and the LRU order are both threaded through it and both have to
/// be O(1) without allocating on the hit path.
final class _MaskEntry {
  _MaskEntry(
    this.keyHash,
    this.transform,
    this.path,
    this.dx,
    this.dy,
    this.w,
    this.h,
    this.rule,
    this.antiAlias,
    this.slot,
  );

  final int keyHash;

  /// Kept for its linear part only; the translation is superseded by [dx] and
  /// [dy]. Holding the object rather than four doubles keeps the comparison
  /// to one `==` per component and costs one reference.
  final Transform2D transform;

  /// Pinned for as long as the mask is cached. [Path] is immutable, so this
  /// cannot go stale, and the display list that produced it normally outlives
  /// the frame anyway.
  final Path path;

  final double dx;
  final double dy;
  final int w;
  final int h;
  final FillRule rule;
  final bool antiAlias;

  /// Moved by `GpuMaskAtlas.compact`, hence not final.
  AtlasSlot slot;

  double u0 = 0;
  double v0 = 0;
  double u1 = 0;
  double v1 = 0;

  int lastUsedFrame = -1;

  _MaskEntry? nextInChain;
  _MaskEntry? lruPrev;
  _MaskEntry? lruNext;

  /// Cheapest components first: two ints and two flags reject nearly every
  /// candidate before a double or a path walk is touched.
  bool matches(
    Path other,
    Transform2D otherTransform,
    double otherDx,
    double otherDy,
    int otherW,
    int otherH,
    FillRule otherRule,
    bool otherAntiAlias,
  ) =>
      w == otherW &&
      h == otherH &&
      rule == otherRule &&
      antiAlias == otherAntiAlias &&
      dx == otherDx &&
      dy == otherDy &&
      transform.a == otherTransform.a &&
      transform.b == otherTransform.b &&
      transform.c == otherTransform.c &&
      transform.d == otherTransform.d &&
      (identical(path, other) || path == other);
}

/// Writes the filler's coverage runs straight into the staging bytes.
///
/// A span is a run of one coverage value, so this is a `fillRange` and not a
/// per-pixel loop - which is why a mask costs about what the CPU renderer's
/// span compositing costs, minus the blending.
final class _MaskSpanSink implements CoverageSpanSink {
  _MaskSpanSink(this._atlas);

  final GpuMaskAtlas _atlas;

  /// Set by the atlas before each fill. A field rather than a constructor
  /// argument because the sink is created once and reused for every mask;
  /// allocating a sink per shape is what section 6.5 rules out.
  bool aliased = false;

  @override
  void span(int y, int xStart, int xEnd, int coverage) {
    if (xEnd <= xStart) return;
    var value = coverage;
    if (aliased) {
      // Half a pixel of area is the threshold. See the note on antiAlias in
      // GpuMaskAtlas.rasterizeMask for what this is not.
      if (coverage < 128) return;
      value = 255;
    }
    final base = y * _atlas.width;
    _atlas.pixels.fillRange(base + xStart, base + xEnd, value);
  }
}
