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

  /// False once the owning device was lost or the texture was released.
  bool get isValid;
}

/// What a device must offer so the device-independent layer can hold pixels.
///
/// Deliberately three methods. Anything richer - mipmaps, array layers,
/// compressed uploads - is a backend detail that no batching code needs, and
/// adding it here would make a second backend implement it before it could
/// draw its first rectangle.
abstract interface class GpuTextureAllocator {
  GpuTextureHandle createTexture({
    required int width,
    required int height,
    required GpuTextureFormat format,
  });

  /// Replaces a rectangle of [texture] with [pixels].
  ///
  /// [bytesPerRow] is carried explicitly for the same reason
  /// [Framebuffer.bytesPerRow] is: a staging buffer's stride is not always
  /// `width * bytesPerPixel`, and recomputing it at the call site is how a
  /// skewed upload gets written.
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
final class AtlasSlot {
  const AtlasSlot(this.x, this.y, this.width, this.height);

  final int x;
  final int y;
  final int width;
  final int height;

  @override
  String toString() => 'AtlasSlot($x, $y, $width x $height)';
}

/// A shelf packer: rows of equal height, filled left to right.
///
/// Chosen over a full skyline or MaxRects packer because the things going in
/// are glyph and shape coverage masks, whose heights cluster tightly (a line
/// of text is one height; a frame's rounded rectangles are a handful of
/// heights). Shelf packing wastes the difference between the tallest item on
/// a shelf and the rest, which for that distribution is small, and it costs
/// one linear scan over a handful of shelves per allocation instead of a
/// rectangle-set maintenance pass. When a profile ever shows the waste
/// mattering, the replacement is a drop-in: [allocate] and [reset] are the
/// whole interface.
///
/// Nothing here frees an individual slot. Freeing implies compaction, and
/// compaction implies moving texels other draw calls already reference. The
/// atlas is reset wholesale instead - see [GpuMaskAtlas] for the frame-local
/// policy that makes that acceptable and for what it costs.
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

  /// `y`, `height`, `nextX` per shelf, flat so that a scan touches one array.
  final List<int> _shelves = <int>[];

  int _nextShelfY = 0;

  int get shelfCount => _shelves.length ~/ 3;

  /// Reserves [w] by [h] texels, or returns null when the atlas is full.
  ///
  /// Null rather than an exception: fullness is an expected steady state for
  /// a caller that knows how to flush and reset, and only a caller that does
  /// not know how can turn it into an error. See [GpuMaskAtlas.rasterize].
  AtlasSlot? allocate(int w, int h) {
    if (w <= 0 || h <= 0) return null;
    final paddedWidth = w + padding * 2;
    final paddedHeight = h + padding * 2;
    if (paddedWidth > width || paddedHeight > height) return null;

    // Best fit by shelf height, not first fit. First fit drops a 4 px glyph
    // onto a 40 px shelf and wastes 36 px of column for the rest of the
    // frame; scanning a handful of shelves to find the tightest one that
    // still fits is cheaper than that waste by orders of magnitude.
    var bestIndex = -1;
    var bestHeight = 1 << 30;
    for (var i = 0; i < _shelves.length; i += 3) {
      final shelfHeight = _shelves[i + 1];
      if (shelfHeight < paddedHeight || shelfHeight >= bestHeight) continue;
      if (_shelves[i + 2] + paddedWidth > width) continue;
      bestIndex = i;
      bestHeight = shelfHeight;
    }

    if (bestIndex >= 0) {
      final x = _shelves[bestIndex + 2];
      _shelves[bestIndex + 2] = x + paddedWidth;
      return AtlasSlot(x + padding, _shelves[bestIndex] + padding, w, h);
    }

    if (_nextShelfY + paddedHeight > height) return null;
    final y = _nextShelfY;
    _nextShelfY += paddedHeight;
    _shelves
      ..add(y)
      ..add(paddedHeight)
      ..add(paddedWidth);
    return AtlasSlot(padding, y + padding, w, h);
  }

  /// Forgets every allocation. The texels are not cleared - the caller that
  /// writes a slot writes all of it, and clearing a megabyte of texture to
  /// hide bytes nobody samples is pure cost.
  void reset() {
    _shelves.clear();
    _nextShelfY = 0;
  }
}
