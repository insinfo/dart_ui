/// Textures and atlases, described without naming a graphics API.
///
/// Everything a GPU backend needs from the layer above is here: a name for a
/// texture, a way to ask a device for one, and a packer that decides where in
/// it a small image goes. None of it mentions GL, Vulkan or Metal, which is
/// what lets the batcher and the mask atlas be tested on a machine with no
/// driver at all.
///
/// The handle is an *integer* id and not an object reference on the batching
/// path on purpose. A batch break is decided by comparing the incoming state
/// against the open batch's, once per primitive; comparing an int is a
/// register compare, while comparing an object is a virtual `==` that a
/// backend could make arbitrarily expensive.
library;

import 'dart:typed_data';

/// Byte layout of a GPU texture.
///
/// Only two, because only two are needed: coverage masks are one byte per
/// pixel, and images are the same premultiplied 32-bit pixels [Framebuffer]
/// already commits to. A backend that prefers a different internal format
/// converts at upload; it must not push that choice up here, because the mask
/// atlas writes its staging bytes with the CPU rasteriser and cannot know.
enum GpuTextureFormat {
  /// One byte per pixel, sampled as coverage. The shader multiplies the
  /// premultiplied vertex colour by it, which is exactly what
  /// `CoverageSpanSink` consumers do on the CPU.
  alpha8,

  /// Blue, green, red, alpha or the reverse - the channel order is the
  /// backend's business, matching `PixelFormat`. Premultiplied either way.
  rgba8888Premultiplied;

  int get bytesPerPixel => this == alpha8 ? 1 : 4;
}

/// How a texture is sampled between texel centres.
///
/// A per-texture property and not a device-wide setting, because the two
/// textures this renderer creates want opposite answers. The coverage-mask
/// atlas is drawn at exactly one texel per pixel (see [GpuMaskAtlas]), so
/// [nearest] reproduces the CPU rasteriser's coverage byte for byte and
/// [linear] would blur it against the padding around each slot. An image is
/// drawn at whatever scale the layout produced, and [nearest] there is the
/// blocky, shimmering resampling that makes a scaled photograph look like a
/// bug in the renderer.
enum GpuTextureFilter { nearest, linear }

/// Reserved id meaning "this batch samples no texture".
///
/// Zero rather than -1 because it is also the value GL uses for the default
/// (unbound) texture object, so a backend can bind [kNoTexture] literally.
const int kNoTexture = 0;

/// A texture the framework can name without knowing what it is.
///
/// [isValid] is not decoration. A device loss destroys every texture the
/// driver owned while the Dart-side handles survive; code that draws with a
/// stale handle gets undefined output rather than an error, so the handle has
/// to be able to say it is dead.
abstract interface class GpuTextureHandle {
  /// Unique within one device, and never [kNoTexture].
  int get id;

  int get width;
  int get height;
  GpuTextureFormat get format;
  GpuTextureFilter get filter;

  /// False once the owning device was lost or the texture was released.
  bool get isValid;
}

/// What a device must offer so the device-independent layer can hold pixels.
///
/// Deliberately three methods. Anything richer - mipmaps, array layers,
/// compressed uploads - is a backend detail that no batching code needs, and
/// adding it here would make a second backend implement it before it could
/// draw its first rectangle.
///
/// An implementation narrows the handle type with `covariant`: a device may
/// only be handed textures it created, and a runtime check for that is worse
/// than a compile-time one at every call site inside the backend.
abstract interface class GpuTextureAllocator {
  GpuTextureHandle createTexture({
    required int width,
    required int height,
    required GpuTextureFormat format,
    GpuTextureFilter filter,
  });

  /// Replaces a rectangle of [texture] with [pixels].
  ///
  /// [bytesPerRow] is carried explicitly for the same reason
  /// [Framebuffer.bytesPerRow] is: a staging buffer's stride is not always
  /// `width * bytesPerPixel`, and recomputing it at the call site is how a
  /// skewed upload gets written. [pixels] starts at the first byte of the
  /// first row to upload, so a caller with a larger staging image passes a
  /// `sublistView` rather than a separate offset.
  void uploadRegion(
    GpuTextureHandle texture, {
    required int x,
    required int y,
    required int width,
    required int height,
    required Uint8List pixels,
    required int bytesPerRow,
  });

  void releaseTexture(GpuTextureHandle texture);
}

/// A rectangle reserved inside an atlas, in texels.
///
/// It carries its **size**, not only its origin. That is the difference
/// between a slot that can be given back and one that cannot: [ShelfAtlas.free]
/// has to know how much space is returning, the mask atlas has to know how
/// many texels to clear before it fills them, and an upload has to know the
/// region. See the consolidation record on [ShelfAtlas] for the two-field
/// version this replaced and why it lost.
final class AtlasSlot {
  const AtlasSlot(this.x, this.y, this.width, this.height);

  final int x;
  final int y;
  final int width;
  final int height;

  @override
  String toString() => 'AtlasSlot($x, $y, $width x $height)';
}

/// A shelf packer: rows of equal height, filled left to right, with a free
/// list per shelf.
///
/// Chosen over a full skyline or MaxRects packer because the things going in
/// are glyph and shape coverage masks, whose heights cluster tightly (a line
/// of text is one height; a frame's rounded rectangles are a handful of
/// heights). Shelf packing wastes the difference between the tallest item on
/// a shelf and the rest, which for that distribution is small, and it costs
/// one linear scan over a handful of shelves per allocation instead of a
/// rectangle-set maintenance pass.
///
/// ## This is the only shelf packer in the tree
///
/// There used to be two - `gpu_shelf_atlas.dart` and this one - and
/// `doc/architecture/overview.md` records that as debt to close before the
/// GPU path grows. They differed in five ways, and each one is settled here
/// rather than left as an alias:
///
///   1. **The slot type.** The other one returned `AtlasSlot(x, y)` with no
///      size. Kept the size: without it nothing can be freed, cleared or
///      uploaded without the caller re-deriving numbers the packer already
///      knew, and a caller that re-derives them is a caller that can get them
///      wrong.
///   2. **Padding.** The other one had none. Kept [padding], because a mask
///      sampled with linear filtering instead of nearest would otherwise
///      bleed into its neighbour - a one-glyph-in-a-thousand ghost edge that
///      is close to unfindable once shipped.
///   3. **Shelf choice.** The other one took the *first* shelf that fits.
///      Kept best fit by shelf height: first fit drops a 4 px mask onto a
///      40 px shelf and burns 36 rows of that column until the atlas is
///      reset, which is precisely the waste a persistent atlas accumulates.
///   4. **Refusal.** The other one compared the *unpadded* size against the
///      atlas, so an item exactly as wide as the atlas was accepted and then
///      placed one padding-width past the right edge. Kept the padded
///      comparison.
///   5. **Storage.** The other one used three parallel `List<int>`; this one
///      used one flat `List<int>` of stride three. Both lost: a shelf now
///      owns a free list, so it is a small object. That costs one object per
///      *shelf* (a handful per atlas), never one per allocation, and the
///      allocation path is not the per-primitive path anyway - see
///      [GpuMaskAtlas], where the per-primitive path is a cache lookup that
///      never reaches this class.
///
/// ## Freeing, and what it does not do
///
/// [free] returns a slot's texels to the shelf it came from. The space
/// becomes either a rollback of the shelf's frontier (when the slot was the
/// last one on it) or a hole in that shelf's free list, coalesced with any
/// neighbouring hole, and reusable by a later allocation that is short enough
/// for the shelf and narrow enough for the hole. A shelf whose last live slot
/// is freed resets its frontier, and trailing empty shelves are dropped
/// outright so that draining the atlas returns it to exactly its initial
/// state.
///
/// What [free] deliberately does not do is **move anything**. Texels stay
/// where they are, because a slot's coordinates are already inside a vertex
/// buffer somewhere. Repacking is therefore a separate, caller-driven act at
/// a frame boundary - [reset] plus re-allocation, with the caller copying its
/// own pixels - and [fragmentation] is the number that says when it is worth
/// doing. See `GpuMaskAtlas.compact`.
///
/// Slots are not generation-tagged. Freeing the same slot twice is caught
/// while its space is still free, and is **not** caught once that space has
/// been handed to another allocation; the second free would then silently
/// hand one region to two owners. The one caller in this repository frees
/// each slot exactly once, from the single object that owns it.
final class ShelfAtlas {
  ShelfAtlas({
    required this.width,
    required this.height,
    this.padding = 1,
  })  : assert(width > 0 && height > 0),
        assert(padding >= 0);

  final int width;
  final int height;

  /// Texels left empty around each slot.
  ///
  /// One by default even though masks are sampled with nearest filtering, so
  /// that turning on linear filtering later cannot make a shape bleed into
  /// its neighbour - a bug that shows up as a faint ghost edge on one glyph
  /// in a thousand and is close to unfindable.
  final int padding;

  final List<_Shelf> _shelves = <_Shelf>[];

  int _nextShelfY = 0;
  int _liveCount = 0;
  int _usedArea = 0;

  int get shelfCount => _shelves.length;

  /// Slots handed out and not yet freed.
  int get liveCount => _liveCount;

  /// Texels those slots occupy, **counting their padding**, because padding
  /// is space no other slot can use.
  int get usedArea => _usedArea;

  /// Rows the packer has committed to shelves, whether or not they carry
  /// anything. New shelves can only open below this.
  int get reservedRows => _nextShelfY;

  /// [reservedRows] as an area. The denominator of [fragmentation].
  int get reservedArea => _nextShelfY * width;

  /// The fraction of the committed rows that is not carrying a live slot,
  /// in `0..1`; zero for an atlas with no shelves open.
  ///
  /// This counts both kinds of shelf waste - the holes inside a shelf and the
  /// rows a shelf reserved above its shortest items - because repacking
  /// recovers both and nothing else does. It deliberately ignores the rows
  /// below [reservedRows], which are free and need no repack to be used.
  double get fragmentation {
    final reserved = reservedArea;
    if (reserved == 0) return 0;
    return (reserved - _usedArea) / reserved;
  }

  /// The largest slot this atlas could ever hold, padding included.
  ///
  /// A caller that gets null from [allocate] uses these to tell "full right
  /// now, try again after a flush" from "will never fit, stop asking".
  int get maxSlotWidth => width - padding * 2;
  int get maxSlotHeight => height - padding * 2;

  /// Whether [w] by [h] could fit into an *empty* atlas of this size.
  bool canEverFit(int w, int h) =>
      w > 0 && h > 0 && w <= maxSlotWidth && h <= maxSlotHeight;

  /// Reserves [w] by [h] texels, or returns null when the atlas has no room.
  ///
  /// Null rather than an exception: fullness is an expected steady state for
  /// a caller that knows how to free or flush, and only a caller that does
  /// not know how can turn it into an error. Null does not say *why* - use
  /// [canEverFit] for that, and see [MaskRasterStatus] for the three-way
  /// answer the mask atlas builds on top of the two.
  AtlasSlot? allocate(int w, int h) {
    if (w <= 0 || h <= 0) return null;
    final paddedWidth = w + padding * 2;
    final paddedHeight = h + padding * 2;
    if (paddedWidth > width || paddedHeight > height) return null;

    // Best fit by shelf height, not first fit. First fit drops a 4 px glyph
    // onto a 40 px shelf and wastes 36 px of column for the rest of the
    // frame; scanning a handful of shelves to find the tightest one that
    // still fits is cheaper than that waste by orders of magnitude.
    //
    // Within the chosen shelf, best fit again - the tightest *hole* that
    // holds the item, falling back to the shelf's frontier. Reusing the
    // tightest hole is what stops a run of small masks from eating the one
    // wide hole a large mask will need.
    var bestShelf = -1;
    var bestHeight = 1 << 30;
    var bestHole = -1;
    var bestHoleWidth = 0;
    for (var i = 0; i < _shelves.length; i++) {
      final shelf = _shelves[i];
      if (shelf.height < paddedHeight || shelf.height >= bestHeight) continue;

      var hole = -1;
      var holeWidth = 1 << 30;
      final holes = shelf.holes;
      for (var k = 0; k < holes.length; k += 2) {
        final candidate = holes[k + 1];
        if (candidate < paddedWidth || candidate >= holeWidth) continue;
        hole = k;
        holeWidth = candidate;
      }
      if (hole < 0 && shelf.nextX + paddedWidth > width) continue;

      bestShelf = i;
      bestHeight = shelf.height;
      bestHole = hole;
      bestHoleWidth = holeWidth;
    }

    if (bestShelf >= 0) {
      final shelf = _shelves[bestShelf];
      final int x;
      if (bestHole >= 0) {
        x = shelf.holes[bestHole];
        final remaining = bestHoleWidth - paddedWidth;
        if (remaining > 0) {
          shelf.holes[bestHole] = x + paddedWidth;
          shelf.holes[bestHole + 1] = remaining;
        } else {
          shelf.holes.removeRange(bestHole, bestHole + 2);
        }
      } else {
        x = shelf.nextX;
        shelf.nextX = x + paddedWidth;
      }
      shelf.liveCount++;
      _liveCount++;
      _usedArea += paddedWidth * paddedHeight;
      return AtlasSlot(x + padding, shelf.y + padding, w, h);
    }

    if (_nextShelfY + paddedHeight > height) return null;
    final shelf = _Shelf(_nextShelfY, paddedHeight)
      ..nextX = paddedWidth
      ..liveCount = 1;
    _shelves.add(shelf);
    _nextShelfY += paddedHeight;
    _liveCount++;
    _usedArea += paddedWidth * paddedHeight;
    return AtlasSlot(padding, shelf.y + padding, w, h);
  }

  /// Returns [slot]'s texels, padding included, to the shelf they came from.
  ///
  /// Throws rather than shrugging when [slot] is not a live allocation of
  /// this atlas: a free that lands on the wrong shelf, or a second free of
  /// the same slot, ends with two masks writing the same texels, and that
  /// surfaces as one shape wearing another's coverage - the hardest class of
  /// rendering bug to trace back to its cause. Section 6.6: explicit failure,
  /// never silent.
  void free(AtlasSlot slot) {
    final x = slot.x - padding;
    final y = slot.y - padding;
    final paddedWidth = slot.width + padding * 2;
    final paddedHeight = slot.height + padding * 2;

    final shelf = _shelfAt(y);
    if (shelf == null ||
        paddedHeight > shelf.height ||
        x < 0 ||
        x + paddedWidth > shelf.nextX) {
      throw ArgumentError.value(
        slot,
        'slot',
        'not a live allocation of this ${width}x$height atlas',
      );
    }
    final holes = shelf.holes;
    for (var k = 0; k < holes.length; k += 2) {
      if (x < holes[k] + holes[k + 1] && holes[k] < x + paddedWidth) {
        throw ArgumentError.value(
          slot,
          'slot',
          'already free; freeing it twice would hand these texels to two '
              'masks at once',
        );
      }
    }

    shelf.liveCount--;
    _liveCount--;
    _usedArea -= paddedWidth * paddedHeight;
    _addHole(shelf, x, paddedWidth);

    if (shelf.liveCount == 0) {
      shelf.nextX = 0;
      shelf.holes.clear();
      // Trailing empty shelves are removed, not kept as empty rows: a
      // drained atlas must be indistinguishable from a fresh one, or a caller
      // that frees everything still cannot allocate a full-height item.
      while (_shelves.isNotEmpty && _shelves.last.liveCount == 0) {
        _nextShelfY = _shelves.last.y;
        _shelves.removeLast();
      }
    }
  }

  /// Forgets every allocation. The texels are not cleared - the caller that
  /// writes a slot writes all of it, and clearing a megabyte of texture to
  /// hide bytes nobody samples is pure cost.
  void reset() {
    _shelves.clear();
    _nextShelfY = 0;
    _liveCount = 0;
    _usedArea = 0;
  }

  @override
  String toString() => 'ShelfAtlas(${width}x$height, pad $padding, '
      '${_shelves.length} shelves, $_liveCount live, '
      'fragmentation ${(fragmentation * 100).round()}%)';

  _Shelf? _shelfAt(int y) {
    for (var i = 0; i < _shelves.length; i++) {
      if (_shelves[i].y == y) return _shelves[i];
    }
    return null;
  }

  /// Records `[x, x + w)` as free on [shelf], merging it with whatever it
  /// touches.
  ///
  /// Merging is not an optimisation here, it is the difference between a
  /// shelf that can take a wide mask again and one that only ever fits the
  /// exact sizes it already held: two adjacent 10-texel holes must be able to
  /// hold a 20-texel item, or a scrolling list of same-sized rows would
  /// fragment the atlas into unusable stripes within a second.
  void _addHole(_Shelf shelf, int x, int w) {
    final holes = shelf.holes;
    var i = 0;
    while (i < holes.length && holes[i] < x) {
      i += 2;
    }
    holes
      ..insert(i, w)
      ..insert(i, x);

    if (i + 2 < holes.length && holes[i] + holes[i + 1] == holes[i + 2]) {
      holes[i + 1] += holes[i + 3];
      holes.removeRange(i + 2, i + 4);
    }
    if (i >= 2 && holes[i - 2] + holes[i - 1] == holes[i]) {
      holes[i - 1] += holes[i + 1];
      holes.removeRange(i, i + 2);
      i -= 2;
    }
    // A hole that reaches the frontier is not a hole, it is unused shelf.
    // Rolling the frontier back is what lets a shelf that filled and drained
    // take a full-width item again.
    if (holes[i] + holes[i + 1] == shelf.nextX) {
      shelf.nextX = holes[i];
      holes.removeRange(i, i + 2);
    }
  }
}

/// One row of the packer: a fixed height, a frontier, and its holes.
final class _Shelf {
  _Shelf(this.y, this.height);

  final int y;

  /// Padded height of the first item placed here; every later item on this
  /// shelf is at most this tall, and the difference is waste that
  /// `ShelfAtlas.fragmentation` counts.
  final int height;

  /// First x no allocation has ever reached on this shelf.
  int nextX = 0;

  int liveCount = 0;

  /// `x, width` pairs of freed runs below [nextX], sorted by x, never
  /// adjacent to each other (see `ShelfAtlas._addHole`) and never touching
  /// [nextX].
  final List<int> holes = <int>[];
}
