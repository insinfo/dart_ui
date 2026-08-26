/// One Direct2D bitmap holding every resident glyph mask, and the reason the
/// Direct2D text path needed one.
///
/// ## The measurement this file exists because of
///
/// `d2d_text_cost_test.dart` draws 3400 glyph-sized quads over a 1280x720
/// surface three ways on the same target in the same run. On this machine:
///
///   * one `FillOpacityMask` per quad, each from **its own small bitmap** -
///     the shape `d2d_raster_sink.dart` had - **12.1 ms**, 3.56 us a quad;
///   * one `FillOpacityMask` per quad, all from **one atlas bitmap** -
///     **5.4 ms**, 1.58 us a quad;
///   * **one `DrawSpriteBatch`** over the same atlas - **4.5 ms**.
///
/// So the dominant cost was never the call count: two thirds of it was
/// *changing which bitmap the call reads*, and that is what this file removes.
/// Batching the calls on top is worth a further 15%, and the sink takes it
/// where the runtime offers `ID2D1DeviceContext3` - but the atlas is the part
/// that matters, and it is also what makes a sprite batch possible at all,
/// because `DrawSpriteBatch` draws from exactly one bitmap.
///
/// ## The key, and why it is copied rather than invented
///
/// An entry is identified by exactly what [GlyphCache] identifies a mask by:
/// the face by identity, the pixel size quantised to 1/64 px, the glyph id and
/// the horizontal subpixel bucket. `gpu_glyph_atlas.dart` states at length why
/// two caches that disagree about what "the same glyph" means is how text goes
/// subtly wrong at some sizes and not others; the same argument applies here
/// and the same four components are used, in the same order.
///
/// ## Packing
///
/// [ShelfGlyphPacker], imported from `gpu_glyph_atlas.dart` rather than
/// written again. It is a pure packing algorithm with no GPU dependency, its
/// reasoning about shelves and best-fit is stated there, and a second copy of
/// it in this directory would be a second place for a fencepost to live.
///
/// ## Eviction: wholesale, on a stated signal
///
/// When the packer has no room the atlas is emptied entirely, exactly the
/// policy `d2d_raster_sink.dart` already applies to its geometry and bitmap
/// caches. Not LRU: freeing one slot inside a shelf implies compaction, and
/// compaction means moving texels that draw calls recorded earlier in this
/// frame still point at. A glyph is cheap to rasterise again, and a page of
/// text re-admits its own alphabet within one frame.
///
/// The caller is *required* to have flushed Direct2D's command batch before
/// [reset] and before any [upload] that overwrites texels an already-recorded
/// draw samples. That rule is not this file's to enforce - it has no way to
/// know what has been recorded - and [D2dBitmap.copyFromMemory] states it.
///
/// ## What does not come in here
///
///   * **Nothing rotated.** The key has nowhere to record an angle, so a run
///     under a matrix [glyphMasksFit] rejects goes down the outline route and
///     never touches this atlas. `d2d_glyph_transform_test.dart` asserts that.
///   * **Nothing too large.** A mask that cannot fit an empty atlas, padding
///     included, is reported as [D2dGlyphAtlasResult.tooLarge] and the sink
///     gives it a bitmap of its own. Very large text is a handful of glyphs,
///     where a call each costs nothing measurable, and letting one of them
///     evict a whole page of body text would be the wrong trade.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../../../rendering/gpu/gpu_glyph_atlas.dart'
    show GlyphPackerSlot, ShelfGlyphPacker;
import '../../../rendering/text/glyph_cache.dart';
import '../../../rendering/text/glyph_raster.dart' show GlyphMask;
import '../../../text/typeface.dart';
import '../d3d12/d3d12_com.dart';
import 'd2d1_interfaces.dart';
import 'd2d1_library.dart';
import 'd2d1_structs.dart';

/// The atlas is this many texels on a side.
///
/// 1024 by 1024 in BGRA is 4 MB of video memory and 4 MB of the system copy
/// this file keeps to upload from - the same order as the 4096-mask bitmap
/// cache it replaces, whose own budget comment named the same figure. It holds
/// something like five thousand body-text glyphs, which is every size and
/// weight a dense interface uses at once with room left over.
const int kD2dGlyphAtlasSize = 1024;

/// Why [D2dGlyphAtlas.acquire] returned no slot.
enum D2dGlyphAtlasResult {
  /// A slot was returned.
  placed,

  /// The glyph rasterises to nothing - a space. The caller draws nothing and
  /// must not treat this as a failure.
  blank,

  /// The packer is full. The caller flushes Direct2D, calls [D2dGlyphAtlas
  /// .reset] and asks again.
  full,

  /// The mask cannot fit an empty atlas. Retrying would loop; the caller
  /// gives this glyph a bitmap of its own.
  tooLarge,
}

/// Where one glyph's coverage lives inside the atlas, and where it draws.
///
/// [x] and [y] are texels of the atlas; [left] and [top] are the mask's own
/// bearings, carried through unchanged from [GlyphMask] so the caller places
/// the quad exactly as it placed a standalone bitmap.
final class D2dGlyphSlot {
  const D2dGlyphSlot({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.left,
    required this.top,
  });

  final int x;
  final int y;
  final int width;
  final int height;
  final int left;
  final int top;

  @override
  String toString() =>
      'D2dGlyphSlot($x, $y ${width}x$height, bearing $left,$top)';
}

/// The atlas: one `ID2D1Bitmap`, one packer, one system-memory copy.
final class D2dGlyphAtlas {
  /// Creates the bitmap on [target] and the system copy behind it.
  ///
  /// Throws when Direct2D refuses the bitmap, because a glyph atlas that
  /// silently became null would turn every later run into a fallback nobody
  /// asked for; the sink catches this and reports the backend as unable to
  /// draw text rather than drawing it wrong.
  D2dGlyphAtlas({
    required D2dRenderTarget target,
    required Allocator allocator,
    required this.backendName,
    this.size = kD2dGlyphAtlasSize,
  })  : _allocator = allocator,
        _packer = ShelfGlyphPacker(width: size, height: size) {
    _pitch = size * 4;
    final int bytes = _pitch * size;
    _texels = allocator.allocate<Uint8>(bytes);
    _bytes = _texels.asTypedList(bytes);
    _bytes.fillRange(0, bytes, 0);

    _slotRect = allocator.allocate<D2dRectU>(sizeOf<D2dRectU>());
    final Pointer<D2dSizeU> pixelSize =
        allocator.allocate<D2dSizeU>(sizeOf<D2dSizeU>());
    pixelSize.ref
      ..width = size
      ..height = size;
    final Pointer<D2dBitmapProperties> properties =
        allocator.allocate<D2dBitmapProperties>(sizeOf<D2dBitmapProperties>());
    properties.ref
      ..dpiX = 96
      ..dpiY = 96;
    properties.ref.pixelFormat
      ..format = dxgiFormatB8G8R8A8Unorm
      ..alphaMode = d2d1AlphaModePremultiplied;
    final Pointer<Pointer<Void>> out =
        allocator.allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());
    final int hr = target.createBitmap(
        pixelSize.ref, _texels.cast<Void>(), _pitch, properties, out);
    final Pointer<Void> raw = out.value;
    allocator
      ..free(pixelSize)
      ..free(properties)
      ..free(out);
    if (comFailed(hr) || raw == nullptr) {
      allocator
        ..free(_texels)
        ..free(_slotRect);
      throw StateError('$backendName: CreateBitmap for a '
          '${size}x$size glyph atlas failed: ${d2dHresultText(hr)}');
    }
    _bitmap = D2dBitmap(raw);
  }

  /// Named in every failure, per section 6.6.
  final String backendName;

  /// Texels on a side.
  final int size;

  final Allocator _allocator;
  final ShelfGlyphPacker _packer;

  late final int _pitch;
  late final Pointer<Uint8> _texels;
  late final Uint8List _bytes;
  late final Pointer<D2dRectU> _slotRect;
  late final D2dBitmap _bitmap;

  final Map<(Typeface, int, int, int), D2dGlyphSlot> _slots =
      <(Typeface, int, int, int), D2dGlyphSlot>{};

  /// Glyphs whose mask is empty, remembered so a page of spaces is not
  /// re-rasterised once per frame.
  final Set<(Typeface, int, int, int)> _blanks = <(Typeface, int, int, int)>{};

  /// The rectangle written since the last [upload], as left/top/right/bottom.
  /// Empty when [_dirtyRight] is 0.
  int _dirtyLeft = 0;
  int _dirtyTop = 0;
  int _dirtyRight = 0;
  int _dirtyBottom = 0;

  /// The bitmap every sprite in a run samples from.
  Pointer<Void> get bitmap => _bitmap.pointer;

  /// Resident glyphs, for tests and diagnostics. The cost model is asserted
  /// through this rather than assumed - see `d2d_glyph_transform_test.dart`.
  int get entryCount => _slots.length;

  /// How many times the atlas has been emptied. A steady interface should see
  /// this stop growing; one that keeps climbing is thrashing.
  int get resetCount => _resetCount;
  int _resetCount = 0;

  /// Whether texels have been written that the bitmap does not have yet.
  bool get isDirty => _dirtyRight > _dirtyLeft;

  /// The slot for one glyph, rasterising and admitting it if need be.
  ///
  /// [outSlot] carries the answer when the result is [D2dGlyphAtlasResult
  /// .placed]; the enum carries every other outcome, so a caller cannot
  /// confuse "no room" with "draws nothing" the way a bare null would.
  (D2dGlyphAtlasResult, D2dGlyphSlot?) acquire(
    GlyphCache cache,
    ScaledTypeface font,
    int sizeKey,
    int glyphId,
    int bucket,
  ) {
    final (Typeface, int, int, int) key =
        (font.typeface, sizeKey, glyphId, bucket);
    final D2dGlyphSlot? resident = _slots[key];
    if (resident != null) {
      return (D2dGlyphAtlasResult.placed, resident);
    }
    if (_blanks.contains(key)) {
      return (D2dGlyphAtlasResult.blank, null);
    }

    final GlyphMask mask = cache.maskFor(font, glyphId, subpixelBucket: bucket);
    if (mask.isEmpty) {
      _blanks.add(key);
      return (D2dGlyphAtlasResult.blank, null);
    }
    final int padding = _packer.padding;
    if (mask.width + padding * 2 > size || mask.height + padding * 2 > size) {
      return (D2dGlyphAtlasResult.tooLarge, null);
    }
    final GlyphPackerSlot? placed = _packer.allocate(mask.width, mask.height);
    if (placed == null) {
      return (D2dGlyphAtlasResult.full, null);
    }

    _write(mask, placed.x, placed.y);
    final D2dGlyphSlot slot = D2dGlyphSlot(
      x: placed.x,
      y: placed.y,
      width: mask.width,
      height: mask.height,
      left: mask.left,
      top: mask.top,
    );
    _slots[key] = slot;
    return (D2dGlyphAtlasResult.placed, slot);
  }

  /// Sends the texels written since the last call to the bitmap.
  ///
  /// A single rectangle covering everything that changed, not one copy per
  /// glyph: a run that admits thirty glyphs writes them across a few shelves,
  /// and thirty `CopyFromMemory` calls to upload what one covers is the cost
  /// this whole file is about, paid on the other side of the API.
  ///
  /// **The caller must have flushed Direct2D** if any command already recorded
  /// in this frame samples texels this call overwrites. See [D2dBitmap
  /// .copyFromMemory].
  void upload() {
    if (!isDirty) return;
    _slotRect.ref
      ..left = _dirtyLeft
      ..top = _dirtyTop
      ..right = _dirtyRight
      ..bottom = _dirtyBottom;
    final Pointer<Uint8> source = _texels + _dirtyTop * _pitch + _dirtyLeft * 4;
    final int hr =
        _bitmap.copyFromMemory(_slotRect, source.cast<Void>(), _pitch);
    _dirtyLeft = 0;
    _dirtyTop = 0;
    _dirtyRight = 0;
    _dirtyBottom = 0;
    if (comFailed(hr)) {
      throw StateError('$backendName: CopyFromMemory into the glyph atlas '
          'failed: ${d2dHresultText(hr)}');
    }
  }

  /// Forgets every glyph and every reservation.
  ///
  /// The texels are left as they are, because every slot is fully written -
  /// coverage and the ring around it - before it is used. **The caller must
  /// have flushed Direct2D first**: recycled slots are overwritten in place,
  /// and a draw still sitting in the command batch points at them.
  void reset() {
    _slots.clear();
    _blanks.clear();
    _packer.reset();
    _dirtyLeft = 0;
    _dirtyTop = 0;
    _dirtyRight = 0;
    _dirtyBottom = 0;
    _resetCount++;
  }

  void dispose() {
    _bitmap.release();
    _allocator
      ..free(_texels)
      ..free(_slotRect);
    _slots.clear();
    _blanks.clear();
  }

  /// Writes one mask's coverage plus the zeroed ring around it.
  ///
  /// Coverage byte to premultiplied white, the same conversion the standalone
  /// bitmaps used: `FillOpacityMask` reads only the alpha channel, and a
  /// sprite's tint multiplies all four, so a texel that carries the coverage
  /// in every channel is correct under both and honest if anything ever draws
  /// the atlas directly.
  ///
  /// The ring is zeroed on every write rather than once at allocation, for the
  /// reason `gpu_glyph_atlas.dart` states: a recycled slot's neighbourhood is
  /// whatever the previous tenant left there.
  void _write(GlyphMask mask, int x, int y) {
    final int padding = _packer.padding;
    final int left = x - padding < 0 ? 0 : x - padding;
    final int top = y - padding < 0 ? 0 : y - padding;
    final int right =
        x + mask.width + padding > size ? size : x + mask.width + padding;
    final int bottom =
        y + mask.height + padding > size ? size : y + mask.height + padding;

    for (var row = top; row < bottom; row++) {
      final int base = row * _pitch;
      final bool inside = row >= y && row < y + mask.height;
      for (var column = left; column < right; column++) {
        final int t = base + column * 4;
        final int coverage = inside && column >= x && column < x + mask.width
            ? mask.coverage[(row - y) * mask.width + (column - x)]
            : 0;
        _bytes[t] = coverage;
        _bytes[t + 1] = coverage;
        _bytes[t + 2] = coverage;
        _bytes[t + 3] = coverage;
      }
    }

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
}
