/// The CPU renderer: a display list in, pixels out, on every platform.
///
/// This is where the two halves meet. [DisplayListPlayer] walks the encoded
/// list and resolves transforms and clips into device space; [CpuRasterizer]
/// turns device-space primitives into bytes. Neither knows about the other -
/// the player emits to a [RasterSink] and this file is the adapter - which is
/// what let both be built and tested independently.
///
/// It is also the backend that makes everything above it testable. A golden
/// test does not need a window, a GPU or a display server: it asks for a
/// memory surface and compares bytes.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../foundation/diagnostics.dart';
import '../foundation/lifecycle.dart';
import '../geometry/offset.dart';
import '../geometry/path.dart';
import '../geometry/rect.dart';
import '../geometry/transform2d.dart';
import '../graphics/display_list.dart';
import '../graphics/display_list_opcodes.dart';
import '../graphics/display_list_reader.dart';
import '../text/typeface.dart';
import 'framebuffer.dart';
import 'path/coverage_span_sink.dart';
import 'path/fill_rule.dart';
import 'path/scanline_filler.dart';
import 'path/stroker.dart';
import 'raster/blend.dart';
import 'raster/clip_stack.dart' show pixelEdge;
import 'raster/rasterizer.dart';
import 'renderer.dart';
import 'replay/display_list_player.dart';
import 'text/glyph_cache.dart';
import 'text/glyph_raster.dart';

/// How deep `saveLayer` may nest on the CPU before it is refused by name.
///
/// Eight, and the same number `GpuLayerStack.kDefaultMaxLayerDepth` uses. The
/// two limits do not have to agree - the CPU's cost per level is a
/// `Uint8List`, not video memory, and a CPU layer's buffer is released at
/// [RasterSink.endLayer] rather than at the end of the frame - but they are
/// kept equal on purpose: a scene that renders on one backend and is refused
/// by the other is the worst kind of divergence, because it does not look like
/// a rendering difference at all.
///
/// No real interface nests opacity more than three or four deep. A dialog
/// fading inside a page fading inside a transition is three; eight leaves
/// headroom over the deepest legitimate case and still catches the runaway - a
/// `saveLayer` inside a build loop - on the frame it starts.
const int kMaxCpuLayerDepth = 8;

/// Raised when layers nest deeper than [kMaxCpuLayerDepth].
///
/// A named error rather than an assertion or a silent clamp, per section 6.6,
/// and the counterpart of `GpuLayerDepthExceededError`. Without it a runaway
/// tree has three ways to end and all of them are worse: the Dart stack
/// overflows inside the player, one buffer per level is allocated until the
/// process runs out of memory, or - if the limit were a silent clamp - a
/// layer's contents are drawn into its grandparent at the wrong opacity with
/// no diagnostic anywhere.
final class CpuLayerDepthExceededError extends Error {
  CpuLayerDepthExceededError({
    required this.depth,
    required this.maxDepth,
  });

  /// Named in the message, per section 6.6.
  String get backendName => 'cpu';

  /// The depth the caller tried to reach - always [maxDepth] + 1.
  final int depth;

  final int maxDepth;

  @override
  String toString() => 'CpuLayerDepthExceededError: $backendName refuses to '
      'open layer $depth; the limit is $maxDepth nested layers. Every open '
      'level holds its own offscreen buffer, so the limit bounds memory rather '
      'than taste. A tree this deep is almost always a saveLayer inside a '
      'loop; a legitimate one raises the limit and pays for it.';
}

/// One open layer on the CPU sink's stack.
///
/// A class rather than parallel lists because a layer is opened and closed
/// once per `saveLayer`, not once per primitive: there is no hot path here to
/// keep an allocation off. The fields are what [_RasterizerSink.endLayer]
/// needs to put the pixels back where they came from, and they are captured at
/// push time rather than re-derived at pop time - re-deriving the geometry is
/// how a composite ends up half a pixel from the contents it holds.
final class _CpuLayer {
  /// An empty or flattened layer: a clip on the parent's own target, and
  /// nothing else. The two cases are indistinguishable from here on, because
  /// an empty layer is a flattened one whose clip admits nothing.
  _CpuLayer.flattened({
    required this.drewBefore,
    required this.originX,
    required this.originY,
  })  : deviceBounds = Rect.zero,
        clip = Rect.zero,
        alpha = 0xFF,
        blendMode = CpuBlendMode.srcOver,
        buffer = null,
        poolSlot = -1,
        parent = null;

  _CpuLayer.offscreen({
    required this.deviceBounds,
    required this.clip,
    required this.alpha,
    required this.blendMode,
    required this.buffer,
    required this.poolSlot,
    required this.parent,
    required this.drewBefore,
    required this.originX,
    required this.originY,
  });

  /// The layer's pixels in device space, snapped outward to whole pixels.
  final Rect deviceBounds;

  /// The clip in force when the layer opened, in device space. The composite
  /// obeys it: the contents were already clipped, but the composite is drawn
  /// in the parent's space.
  final Rect clip;

  final int alpha;
  final CpuBlendMode blendMode;

  /// Null for a flattened layer, which has no buffer to composite.
  final Framebuffer? buffer;

  /// Slot in [CpuLayerBufferPool], or -1 when the buffer was allocated privately
  /// because the slot was already in use.
  final int poolSlot;

  /// The rasteriser drawing resumes into. Null for a flattened layer, which
  /// never left it.
  final CpuRasterizer? parent;

  /// Whether anything had been drawn into the *parent* before this layer
  /// opened, so closing it restores the parent's answer rather than inheriting
  /// the child's.
  final bool drewBefore;

  /// The origin outside this layer, restored on pop.
  final double originX;
  final double originY;

  bool get isOffscreen => buffer != null;
}

/// The backing stores layer buffers are cut out of, reused across layers and
/// across frames.
///
/// ## The policy, stated
///
/// One slot per *offscreen nesting depth*, grown on demand and never shrunk,
/// shared by every CPU surface in the isolate. A layer at depth `d` takes slot
/// `d` and gives it back at `endLayer`.
///
/// That is a different policy from `gl_framebuffer_pool.dart`'s, and the
/// difference is forced rather than chosen. A GPU layer's target has to live
/// until the frame is *submitted*, because the composite quad has only been
/// recorded when the layer closes - so peak GPU layer memory is proportional
/// to the number of layers in a frame, and a pool keyed by size class is the
/// only way to make a hundred sibling layers share anything. A CPU layer is
/// composited *immediately* at `endLayer`, so its buffer is free one statement
/// later: a hundred sibling layers reuse one slot, and only nesting costs a
/// second. Keying by depth rather than by size is therefore both simpler and
/// tighter here.
///
/// ## What it costs, bounded
///
/// A slot grows to the largest layer that depth has ever held and stays there.
/// The player clips a layer's bounds to the device bounds before this sink
/// sees them, so a slot can never exceed the surface, and the whole pool is
/// bounded by `kMaxCpuLayerDepth` surfaces - eight, and only for a process
/// that actually nested eight deep. Capacity is rounded up to a power of two,
/// with a 4 KiB floor, so a layer that grows by a pixel a frame - a list one
/// row taller each time, which is the case that defeats an exact-size pool -
/// reallocates a logarithmic number of times rather than every frame.
///
/// ## Re-entrancy
///
/// A slot in use hands back null and the caller allocates privately. Rendering
/// is synchronous and a sink never calls back into the player, so this cannot
/// currently happen; the guard costs a bool and turns a future re-entrant
/// caller into a slow frame instead of two layers writing over each other.
final class CpuLayerBufferPool {
  CpuLayerBufferPool._();

  /// Process-wide, for the same reason `GlyphCache.shared` is: a sink lives
  /// for one frame, so a pool it owned would be thrown away with it and every
  /// frame would allocate again.
  ///
  /// Statics are per-isolate in Dart, so two isolates rendering at once hold
  /// two pools and share nothing - which is the correct answer, since they
  /// share no surfaces either.
  static final CpuLayerBufferPool shared = CpuLayerBufferPool._();

  final List<Uint8List> _slots = <Uint8List>[];
  final List<bool> _busy = <bool>[];
  int _allocationCount = 0;

  /// Stores allocated since construction. The number a reuse test asserts:
  /// drawing the same layer on ten frames must leave this at one. Reuse is
  /// invisible from the pixels - a pool that allocated per frame would produce
  /// identical output and a slower frame - so it is only observable here.
  int get allocationCount => _allocationCount;

  /// Bytes retained right now, which is what a memory report wants.
  int get retainedBytes {
    var total = 0;
    for (var i = 0; i < _slots.length; i++) {
      total += _slots[i].length;
    }
    return total;
  }

  /// Slots that have ever been handed out, which is the deepest nesting this
  /// isolate has reached.
  int get slotCount => _slots.length;

  /// Smallest allocation, 32x32 pixels. Below this the rounding saves nothing
  /// and the object header is a bigger share of the cost than the pixels.
  static const int _minBytes = 32 * 32 * 4;

  /// A store of at least [minBytes] for [slot], or null if the slot is busy.
  ///
  /// Called by the CPU sink when a layer opens. Public only because Dart has
  /// no visibility between "this file" and "this package"; nothing outside
  /// `cpu_renderer.dart` should call it, and a caller that does must pair it
  /// with [give].
  Uint8List? take(int slot, int minBytes) {
    while (_slots.length <= slot) {
      _slots.add(_empty);
      _busy.add(false);
    }
    if (_busy[slot]) return null;
    Uint8List store = _slots[slot];
    if (store.length < minBytes) {
      store = Uint8List(_capacityFor(minBytes));
      _slots[slot] = store;
      _allocationCount++;
    }
    _busy[slot] = true;
    return store;
  }

  /// Returns [slot] for reuse. Paired with [take], once per layer.
  void give(int slot) => _busy[slot] = false;

  /// Drops every retained store that is not in use. For a caller that knows
  /// the screen has stopped using layers and would rather have the memory back
  /// than the next frame's allocation.
  void trim() {
    for (var i = 0; i < _slots.length; i++) {
      if (!_busy[i]) _slots[i] = _empty;
    }
  }

  static final Uint8List _empty = Uint8List(0);

  static int _capacityFor(int bytes) {
    var capacity = _minBytes;
    while (capacity < bytes) {
      capacity *= 2;
    }
    return capacity;
  }
}

/// Bridges the player's device-space calls onto the rasteriser.
///
/// The player guarantees `clip` is non-empty and overlaps the primitive, but
/// only *overlaps* - so every call still applies it. Doing that here rather
/// than trusting the player keeps the rasteriser's clip stack the single
/// authority on what is on screen.
final class _RasterizerSink implements RasterSink {
  _RasterizerSink(
    CpuRasterizer rasterizer,
    this._resources,
    this._glyphs, {
    this.maxLayerDepth = kMaxCpuLayerDepth,
  })  : _rasterizer = rasterizer,
        _spanSink = _CoverageToRasterizer(rasterizer);

  /// The rasteriser every draw below goes through: the surface's, or the
  /// innermost open offscreen layer's.
  CpuRasterizer _rasterizer;

  /// How deep `saveLayer` may nest before [CpuLayerDepthExceededError].
  final int maxLayerDepth;

  /// Held only for [fontAt]. The player resolves paths and images itself but
  /// hands a glyph run's font through as an id, because a sink with no glyph
  /// rasterizer has no use for a face; see [ReplayResources.fontAt].
  final ReplayResources _resources;

  final GlyphCache _glyphs;

  /// Kept across draws: the filler holds the edge and accumulator buffers that
  /// must not be rebuilt per path.
  final ScanlineFiller _filler = ScanlineFiller();

  /// Kept for the same reason, and it matters more here: [PathStroker] grows a
  /// segment buffer and an output builder to the largest contour it has seen
  /// and then stops allocating, which a per-draw instance would throw away
  /// every time.
  ///
  /// Reuse, not a cache of finished outlines. That was measured rather than
  /// assumed: for a 200x100 rounded rectangle with an 8 px radius, stroking
  /// costs about 10 us and rasterising the outline it produces about 58 us,
  /// so an outline cache could remove at most a seventh of a stroked border -
  /// and for a plain rectangle, a fiftieth. Against that sits a keyed map, an
  /// eviction policy, and unbounded retention of outlines for shapes that
  /// resize every frame. The 58 us is where the time is, and `span` below
  /// says what to do about it (one rasteriser call per scanline). A cache
  /// here would be optimising the cheap half.
  final PathStroker _stroker = PathStroker();

  final _CoverageToRasterizer _spanSink;

  /// Open layers, innermost last. Empty between frames, or the player and this
  /// sink disagree about how many clips are in force.
  final List<_CpuLayer> _open = <_CpuLayer>[];

  /// Open layers that took a buffer. Indexes the buffer pool's slots, so a
  /// flattened layer - which takes none - does not shift the numbering and
  /// make two frames disagree about which slot a depth owns.
  int _offscreenDepth = 0;

  /// The device-space corner every coordinate below is written relative to:
  /// the innermost offscreen layer's whole-pixel top-left, or the origin when
  /// none is open. Whole pixels always; see [beginLayer].
  double _originX = 0;
  double _originY = 0;

  /// The same origin as integers, for the glyph path. Not a cache - that path
  /// is integral end to end, and may only subtract a whole number of pixels or
  /// the coverage it rasterised stops landing on the pixel it was made for.
  int _originIntX = 0;
  int _originIntY = 0;

  /// True exactly when the origin is not (0, 0), so the common case - no layer
  /// open - pays a comparison instead of a `Rect` per primitive.
  bool _shifted = false;

  /// Whether anything has been drawn into the innermost open layer.
  ///
  /// Mirrors `GpuLayer.drewSomething`, and it is not an optimisation: the GPU
  /// skips the composite of a layer that batched nothing, and with
  /// [CpuBlendMode.src] "skip the composite" and "composite a transparent
  /// layer" are different pictures - the first leaves the parent alone, the
  /// second erases it.
  bool _drew = false;

  /// Layers currently open. A backend can assert it is zero after a frame.
  int get layerDepth => _open.length;

  /// [rect] in the coordinates the current target is indexed by.
  ///
  /// Allocates one `Rect` per primitive *while a layer is open* and none
  /// otherwise. That is the cost of a layer-sized buffer instead of a
  /// surface-sized one, it is charged only to frames that use layers, and the
  /// alternative - a full-surface allocation and a full-surface clear for a
  /// badge in a corner - is worse on every frame that has one.
  Rect _toLayer(Rect rect) =>
      _shifted ? rect.translate(-_originX, -_originY) : rect;

  /// [transform] with the layer origin folded into its translation.
  ///
  /// Post-multiplying by a translation only ever moves `tx`/`ty`, so this is
  /// `Transform2D.translation(-ox, -oy).multiply(transform)` written without
  /// the intermediate matrix. The linear part is untouched, which matters:
  /// the stroker's tolerance and the glyph size are both derived from it.
  Transform2D _toLayerTransform(Transform2D transform) => _shifted
      ? Transform2D(
          transform.a,
          transform.b,
          transform.c,
          transform.d,
          transform.tx - _originX,
          transform.ty - _originY,
        )
      : transform;

  void _fillClipped(Rect deviceRect, Rect clip, ReplayPaint paint) {
    final visible = deviceRect.intersect(clip);
    if (visible.isEmpty) return;
    _drew = true;
    // The intersection happens in double space, so a clipped edge arrives here
    // fractional and comes out soft. Antialiasing everything is the right
    // default for a UI: the shapes are axis-aligned most of the time, where
    // coverage is exact and the interior spans take the same loop the hard
    // fill takes, so the cost is confined to boundary pixels.
    //
    // paint.antiAlias exists to turn it OFF - for a caller who has measured
    // that a particular fill is on a hot path and lands on integer bounds
    // anyway, where the two produce identical bytes.
    final Rect local = _toLayer(visible);
    if (paint.antiAlias) {
      _rasterizer.fillRectAntiAliased(local, paint.argbColor);
    } else {
      _rasterizer.fillRect(local, paint.argbColor);
    }
  }

  @override
  void fillDeviceRect(Rect deviceRect, Rect clip, ReplayPaint paint) {
    _requireFillStyle(paint, 'rectangle');
    _fillClipped(deviceRect, clip, paint);
  }

  @override
  void fillDeviceRRect(
    Rect deviceRect,
    Rect clip,
    Float32List deviceRadii,
    ReplayPaint paint,
  ) {
    _requireFillStyle(paint, 'rounded rectangle');
    // Through the path filler rather than a special-case span loop in the
    // rasteriser. The filler already antialiases by exact area, so the corners
    // come out at the same quality as every other curve, and there is one
    // implementation of a rounded rectangle rather than two that can disagree.
    //
    // The radii arrive already in device space and in the encoder's order, so
    // addRoundedRectRadii consumes the borrowed scratch buffer directly and
    // the eight-value order is stated in one place instead of here.
    final builder = PathBuilder()
      ..addRoundedRectRadii(_toLayer(deviceRect), deviceRadii);
    _drew = true;
    _spanSink.paint = paint;
    _filler.fill(builder.build(), _toLayer(clip), _spanSink);
  }

  /// Refuses a stroke on the primitives that cannot carry one.
  ///
  /// Stroking *is* implemented here - see [drawDevicePath] - but only where
  /// the local-to-device matrix comes with the geometry, because the paint's
  /// width is in local units. These primitives arrive already in device space
  /// with no matrix, so there is nothing to scale the width by, and filling
  /// them anyway would draw a solid block where a border was asked for: wrong
  /// output that looks deliberate.
  ///
  /// The player never sends a stroke-bearing style here (it rebuilds those
  /// shapes as centrelines), so this firing means a different producer drove
  /// the sink - which is exactly when a silent fill would be hardest to trace.
  void _requireFillStyle(ReplayPaint paint, String what) {
    if (paint.style == paintStyleFill) return;
    throw UnsupportedCapabilityError(
      backendName: 'cpu',
      capability: Capability.cpuPresentation,
      detail: 'stroking a device-space $what is not implemented: the stroke '
          'width is in local units and this call carries no transform to '
          'scale it by. Send the shape through drawDevicePath, which strokes',
    );
  }

  /// Opens a layer, taking an offscreen buffer when one is needed.
  ///
  /// The three outcomes are the three `gpu_layer_stack.dart` defines, decided
  /// by the same tests in the same order, because a layer that is offscreen on
  /// one backend and flattened on the other is a difference no golden can
  /// explain:
  ///
  ///   * **empty** - the bounds survived nothing. Nothing is allocated; the
  ///     pair is still delivered by the player, so an empty clip is pushed and
  ///     everything inside is culled by it.
  ///   * **flattened** - alpha 255 and source-over. Compositing such a layer
  ///     back is the identity, so its contents go straight into the parent and
  ///     the layer is exactly its clip. This is what this method used to do to
  ///     *every* layer, and it is correct only here.
  ///   * **offscreen** - anything else. A buffer is taken, cleared to
  ///     transparency, and every primitive until the matching [endLayer] is
  ///     written into it with the layer's whole-pixel corner subtracted.
  ///
  /// ## The bounds are snapped outward, and that is load-bearing
  ///
  /// `floor` on the left and top, `ceil` on the right and bottom - the same
  /// convention `GpuLayerStack.push` uses, and it has to be the same one. The
  /// snapped left/top become the origin every coordinate inside the layer is
  /// written against, and a *fractional* origin would shift every glyph mask
  /// and every coverage span inside the layer by a fraction of a pixel
  /// relative to the coverage that was rasterised for them. That is the
  /// sub-pixel resampling that makes text inside an opacity animation look
  /// softer than the same text outside it.
  ///
  /// Snapping outward rather than to the nearest pixel is what guarantees the
  /// buffer contains every pixel the layer's contents can touch: the player
  /// has already clipped those contents to the *unsnapped* bounds, so an
  /// inward snap would cut a partially covered edge column that the composite
  /// then could not restore.
  ///
  /// ## What this does not do, said plainly
  ///
  ///   * **No filters.** A layer carries an alpha and a blend mode; the
  ///     display list cannot encode a blur or a colour matrix, so there is
  ///     nothing to refuse yet.
  ///   * **No isolation for a primitive's own blend mode.** The sink below
  ///     composites every *primitive* source-over regardless of
  ///     `paint.blendMode` - that predates layers and is unchanged here - so
  ///     the one case where flattening an opaque source-over layer is not an
  ///     identity (a `plus` primitive inside it, which `gpu_raster_sink.dart`
  ///     refuses by name) cannot arise on this backend: nothing here can draw
  ///     a `plus` primitive in the first place.
  @override
  void beginLayer(Rect deviceBounds, Rect clip, ReplayPaint paint) {
    if (_open.length >= maxLayerDepth) {
      throw CpuLayerDepthExceededError(
        depth: _open.length + 1,
        maxDepth: maxLayerDepth,
      );
    }

    final double left = deviceBounds.left.floorToDouble();
    final double top = deviceBounds.top.floorToDouble();
    final double right = deviceBounds.right.ceilToDouble();
    final double bottom = deviceBounds.bottom.ceilToDouble();
    final bool degenerate = !(right > left) ||
        !(bottom > top) ||
        !left.isFinite ||
        !top.isFinite ||
        !right.isFinite ||
        !bottom.isFinite;

    final int alpha = (paint.argbColor >> 24) & 0xFF;
    final int blendMode = paint.blendMode;

    if (degenerate || (alpha == 0xFF && blendMode == blendModeSrcOver)) {
      // Empty and flattened are the same code: a clip on the target already in
      // hand. They differ only in that an empty one clips everything away,
      // which the intersection below does on its own.
      _open.add(_CpuLayer.flattened(
        drewBefore: _drew,
        originX: _originX,
        originY: _originY,
      ));
      _rasterizer
        ..save()
        ..clipRect(_toLayer(deviceBounds.intersect(clip)));
      return;
    }

    final int width = (right - left).round();
    final int height = (bottom - top).round();
    final Framebuffer surface = _rasterizer.target;
    final int slot = _offscreenDepth;
    final Uint8List? pooled =
        CpuLayerBufferPool.shared.take(slot, width * height * 4);
    final Framebuffer buffer = Framebuffer.wrap(
      pooled ?? Uint8List(width * height * 4),
      width: width,
      height: height,
      // Tightly packed, never the pooled allocation's own stride: rows that
      // are contiguous are what let the clear below take the word path and
      // what keeps a small layer's rows in one cache line's worth of strides.
      bytesPerRow: width * 4,
      // The parent's format, so the composite is a straight copy of channels
      // rather than a swizzle per pixel - and so a layer inside a layer keeps
      // the surface's order all the way down.
      format: surface.format,
    );
    // A pooled buffer holds the previous tenant's pixels, and a layer
    // composites what it drew *over transparency*, not over a ghost.
    buffer.clear(0, 0, 0, 0);

    final _CpuLayer layer = _CpuLayer.offscreen(
      deviceBounds: Rect.fromLTRB(left, top, right, bottom),
      clip: clip,
      alpha: alpha,
      blendMode: cpuBlendForMode(blendMode),
      buffer: buffer,
      poolSlot: pooled == null ? -1 : slot,
      parent: _rasterizer,
      drewBefore: _drew,
      originX: _originX,
      originY: _originY,
    );
    _open.add(layer);
    _offscreenDepth++;

    _setTarget(CpuRasterizer(buffer), left, top);
    _drew = false;
    // The layer's own contents are clipped to the *unsnapped* bounds, so an
    // antialiased shape drawn to the layer's edge keeps the fractional
    // coverage it would have had on the surface. The buffer is one pixel
    // wider than that wherever the bounds were fractional; those pixels are
    // cleared, composited, and contribute nothing.
    _rasterizer.clipRect(_toLayer(deviceBounds.intersect(clip)));
  }

  /// Closes the innermost layer and composites it into its parent.
  ///
  /// The composite is one blit of the layer's buffer at the layer's opacity
  /// and blend mode, scissored to the clip that was in force when the layer
  /// opened - the contents were already clipped, but the composite is drawn in
  /// the parent's space and has to obey the parent's clip. It is exactly the
  /// arithmetic `gpu_raster_sink.dart` writes into a textured quad, because a
  /// finished layer is an image.
  ///
  /// A layer nothing drew into takes its buffer back and composites nothing,
  /// matching `GpuLayerStack.pop`. See [_drew] for why that is a correctness
  /// rule rather than a saved blit.
  @override
  void endLayer() {
    if (_open.isEmpty) {
      throw StateError('cpu: endLayer() without a matching beginLayer(); the '
          'player and this sink disagree about how many layers are open, '
          'which means a clip is still in force that should not be');
    }
    final _CpuLayer layer = _open.removeLast();
    if (!layer.isOffscreen) {
      _rasterizer.restore();
      _drew = _drew || layer.drewBefore;
      return;
    }

    final bool drewInside = _drew;
    _offscreenDepth--;
    _setTarget(layer.parent!, layer.originX, layer.originY);
    _drew = layer.drewBefore;

    if (drewInside) {
      final Rect bounds = layer.deviceBounds;
      _rasterizer
        ..save()
        ..clipRect(_toLayer(layer.clip))
        ..compositeLayer(
          layer.buffer!,
          (bounds.left - _originX).toInt(),
          (bounds.top - _originY).toInt(),
          layer.alpha,
          layer.blendMode,
        )
        ..restore();
      _drew = true;
    }
    if (layer.poolSlot >= 0) CpuLayerBufferPool.shared.give(layer.poolSlot);
  }

  /// Gives back every buffer still held by an open layer.
  ///
  /// Defensive rather than decorative, and the same duty
  /// `GpuLayerStack.beginFrame` performs for the same reason: a frame that
  /// threw half way - an unsupported primitive, a depth limit, a corrupt list
  /// - never reached its last [endLayer], and a pool slot left marked in use
  /// is never reused again. Leaking one slot per failed frame turns a
  /// recoverable error into a renderer that allocates a fresh buffer for every
  /// layer forever, with nothing to point at the frame that caused it.
  void releaseOpenLayers() {
    for (var i = 0; i < _open.length; i++) {
      final int slot = _open[i].poolSlot;
      if (slot >= 0) CpuLayerBufferPool.shared.give(slot);
    }
    _open.clear();
    _offscreenDepth = 0;
  }

  /// Points every draw below at [rasterizer], written against ([x], [y]).
  ///
  /// The integer copy of the origin is a requirement rather than a cache: the
  /// glyph path is integral end to end and may only subtract whole pixels.
  /// The assert states that the bounds really were snapped, because rounding
  /// here instead would misplace a whole layer by a pixel and leave nothing
  /// to find it by.
  void _setTarget(CpuRasterizer rasterizer, double x, double y) {
    assert(
      x == x.roundToDouble() && y == y.roundToDouble(),
      'a layer origin must be a whole pixel; got $x, $y',
    );
    _rasterizer = rasterizer;
    _spanSink.rasterizer = rasterizer;
    _originX = x;
    _originY = y;
    _originIntX = x.toInt();
    _originIntY = y.toInt();
    _shifted = x != 0 || y != 0;
  }

  @override
  void drawDevicePath(
    Object path,
    Transform2D transform,
    Rect clip,
    ReplayPaint paint,
  ) {
    if (path is! Path) {
      throw ArgumentError.value(
        path,
        'path',
        'the CPU renderer fills and strokes Path objects; got '
            '${path.runtimeType}',
      );
    }
    // The layer origin is folded into the matrix once, here, rather than into
    // the geometry: stroking happens in the path's own coordinates and only
    // the outline is transformed, so a shift applied to the path would be
    // applied before the stroke and scaled by the matrix on the way out.
    final Transform2D local = _toLayerTransform(transform);
    switch (paint.style) {
      case paintStyleFill:
        _fill(path, local, clip, paint);
      case paintStyleStroke:
        _fill(_outlineOf(path, transform, paint), local, clip, paint);
      case paintStyleFillAndStroke:
        // Order is load-bearing, not incidental. The stroke straddles the
        // centreline, so its inner half lies inside the region the fill
        // covers; drawing the fill second paints over that half and the
        // border comes out half as wide as it was asked for - and only on
        // the inside, so it also looks like a positioning bug.
        _fill(path, local, clip, paint);
        _fill(_outlineOf(path, transform, paint), local, clip, paint);
      default:
        throw UnsupportedCapabilityError(
          backendName: 'cpu',
          capability: Capability.cpuPresentation,
          detail: 'paint style ${paint.style} is not fill, stroke or '
              'fillAndStroke; this sink has no drawing for it',
        );
    }
  }

  /// Fills [path] under [transform], non-zero.
  ///
  /// The rule is stated rather than left to the filler's default because a
  /// stroke outline *requires* it: the inner side of a join crosses itself and
  /// a closed contour becomes two wound against each other, both of which
  /// even-odd would turn inside out. See `stroker.dart`.
  ///
  /// [transform] is already in the current target's coordinates; [clip] is
  /// still in device space and is moved here.
  void _fill(Path path, Transform2D transform, Rect clip, ReplayPaint paint) {
    if (path.isEmpty) return;
    _drew = true;
    _spanSink.paint = paint;
    _filler.fill(
      path,
      _toLayer(clip),
      _spanSink,
      rule: FillRule.nonZero,
      transform: transform,
    );
  }

  /// The outline swept by the pen along [path], in [path]'s own coordinates.
  ///
  /// Stroking happens *before* the transform, which is what makes a stroke
  /// scale with the shape it outlines: a 2 px border under a 2x scale is four
  /// device pixels, the same as every other length in the subtree. Stroking
  /// after would need an inverse-transformed width, and under a non-uniform
  /// scale there is no single width to use - the pen there is an ellipse.
  ///
  /// A width that is zero, negative or not finite comes back as an empty path
  /// and draws nothing. That is the stroker's contract and the right one: a
  /// width animating through zero is not a programming error the frame can do
  /// anything about, and it is a stroke of no width, not a hairline.
  ///
  /// Cap, join and miter limit take [StrokeStyle]'s defaults because the
  /// display list has no operand for them; see `ReplayPaint.strokeWidth`.
  Path _outlineOf(Path path, Transform2D transform, ReplayPaint paint) {
    // The stroker's tolerance is in local units and the error it allows is
    // magnified by the transform, so a curve stroked inside a 4x scale would
    // come out at four times the intended deviation - visible faceting on a
    // zoomed-in border. Dividing by the scale spends the same tenth of a
    // device pixel at every zoom level.
    final double scale = _maxAxisScale(transform);
    return _stroker.stroke(
      path,
      StrokeStyle(width: paint.strokeWidth),
      tolerance: scale > 0 && scale.isFinite
          ? kDefaultStrokeTolerance / scale
          : kDefaultStrokeTolerance,
    );
  }

  /// The larger of the two factors a unit length is scaled by, which is the
  /// one that has to be budgeted for.
  static double _maxAxisScale(Transform2D t) {
    final double x = math.sqrt(t.a * t.a + t.b * t.b);
    final double y = math.sqrt(t.c * t.c + t.d * t.d);
    return x > y ? x : y;
  }

  @override
  void drawDeviceImage(
    Object image,
    Rect sourceRect,
    Rect deviceRect,
    Rect clip,
    ReplayPaint paint,
  ) {
    if (image is! Framebuffer) {
      throw ArgumentError.value(
        image,
        'image',
        'the CPU renderer draws Framebuffer images; got ${image.runtimeType}',
      );
    }
    // Clipping is the rasteriser's job here: it walks rows anyway, so folding
    // the clip into the blit costs nothing extra.
    _drew = true;
    _rasterizer
      ..save()
      ..clipRect(_toLayer(clip))
      ..drawFramebuffer(image, _toLayer(deviceRect))
      ..restore();
  }

  /// Draws a shaped run as one cached coverage mask per glyph.
  ///
  /// Three decisions are worth stating, because each is a place text goes
  /// subtly wrong and looks like a font bug rather than a positioning one.
  ///
  /// The **baseline snaps to a whole pixel** and the **pen's x does not**.
  /// Horizontal subpixel positioning is what keeps letter spacing even (see
  /// `glyph_cache.dart`), while vertical subpixel positioning would only blur
  /// the horizontal stems that carry a Latin face's legibility - and would
  /// multiply the cache by another four buckets to do it. Every engine that
  /// renders horizontal text makes this same asymmetric choice.
  ///
  /// The **font is scaled by the transform**, not the mask. Scaling a mask
  /// resamples an antialiased edge and produces the soft, muddy text that
  /// gives bitmap font caches their reputation; rasterizing the outline at the
  /// device size is the whole reason an outline was kept. The player has
  /// already applied the transform to the pen positions, so only the size is
  /// left to carry.
  ///
  /// A **rotated or skewed** transform is refused rather than approximated.
  /// The glyph rasterizer takes a scale and a subpixel offset, so text under
  /// such a matrix would silently come out upright - a wrong picture that
  /// looks deliberate.
  @override
  void drawDeviceGlyphRun(
    int fontId,
    Offset deviceOrigin,
    Transform2D transform,
    Int32List glyphIds,
    Float32List deviceOffsets,
    int glyphCount,
    Rect clip,
    ReplayPaint paint,
  ) {
    final Object resource = _resources.fontAt(fontId);
    if (resource is! ScaledTypeface) {
      throw ArgumentError.value(
        resource,
        'font',
        'the CPU renderer rasterizes ScaledTypeface faces; got '
            '${resource.runtimeType}',
      );
    }
    // Not [_requireFillStyle]: this call does carry a transform, so the reason
    // is a different one. Stroked text needs the glyph's *outline* to hand to
    // the stroker, and what this sink has is a cached alpha8 coverage mask -
    // outlining that would trace the antialiased edge of a bitmap, which is
    // the classic "furry text" artefact rather than a stroke.
    if (paint.style != paintStyleFill) {
      throw UnsupportedCapabilityError(
        backendName: 'cpu',
        capability: Capability.cpuPresentation,
        detail: 'stroked text is not implemented; the glyph cache stores '
            'coverage masks, and the stroker needs the outline the mask was '
            'rasterized from',
      );
    }
    final int argb = paint.argbColor;
    // A fully transparent run still costs a rasterization per glyph if it is
    // not stopped here, and invisible text is common: a fade at t = 0.
    if ((argb >> 24) & 0xFF == 0) return;

    final ScaledTypeface font = _deviceFont(resource, transform);

    _drew = true;
    _rasterizer
      ..save()
      ..clipRect(_toLayer(clip));
    for (var i = 0; i < glyphCount; i++) {
      final double penX = deviceOrigin.dx + deviceOffsets[i * 2];
      final double penY = deviceOrigin.dy + deviceOffsets[i * 2 + 1];
      final GlyphMask mask = _glyphs.maskFor(
        font,
        glyphIds[i],
        subpixelBucket: glyphSubpixelBucket(penX),
      );
      if (mask.isEmpty) continue;
      // The mask's own left/top are offsets from the pen, and top is negative
      // because a glyph rises above the baseline.
      //
      // The subpixel bucket and the whole-pixel origin are both taken from the
      // *device* pen and only then moved into the layer, by a whole number of
      // pixels. Quantising in layer space would give the same answer for a
      // whole-pixel origin and a different one the moment that assumption
      // slipped, which is exactly the bug the assert in [_setTarget] guards.
      _rasterizer.blendCoverageMask(
        mask.coverage,
        mask.width,
        mask.height,
        glyphPixelOrigin(penX) + mask.left - _originIntX,
        pixelEdge(penY) + mask.top - _originIntY,
        argb,
      );
    }
    _rasterizer.restore();
  }

  /// [font] at the size the device transform asks for.
  ///
  /// Returns [font] itself at unit scale, so the common case - no device pixel
  /// ratio, or one already folded into the layout - allocates nothing and hits
  /// the cache under the key the caller interned.
  ScaledTypeface _deviceFont(ScaledTypeface font, Transform2D transform) {
    final double a = transform.a;
    final double d = transform.d;
    if (transform.b != 0 || transform.c != 0 || a <= 0 || d <= 0 || a != d) {
      throw UnsupportedCapabilityError(
        backendName: 'cpu',
        capability: Capability.cpuPresentation,
        detail: 'text under a rotated, skewed, mirrored or non-uniformly '
            'scaled transform is not implemented; the glyph rasterizer takes '
            'a uniform scale, and drawing this run would silently produce '
            'upright text (transform $transform)',
      );
    }
    if (a == 1) return font;
    return ScaledTypeface(font.typeface, font.pixelSize * a);
  }
}

/// Turns coverage spans into composited pixels.
///
/// A span is already whole pixels with its antialiasing carried as a coverage
/// byte, so folding that byte into the paint's alpha and asking for a hard
/// fill on integer bounds is exactly right - no second antialiasing pass, and
/// no new compositor. `mul255` is the same rounding the filler used, which is
/// what makes a full-coverage span composite bit-identically to a rect fill.
///
/// One fill call per span is the cost. Spans are per-scanline runs rather than
/// per-pixel, so this is on the order of the shape's height; a public
/// span-level entry point on the rasteriser would remove even that, and is the
/// obvious next optimisation if paths ever show up in a profile.
final class _CoverageToRasterizer implements CoverageSpanSink {
  _CoverageToRasterizer(this.rasterizer);

  /// Where spans land. Mutable because a layer moves it: the same span sink
  /// serves the surface and every layer's buffer, and a sink allocated per
  /// layer would still have to be threaded through the filler.
  CpuRasterizer rasterizer;

  /// Set immediately before each fill. Mutable on purpose: a sink allocated
  /// per draw would put an allocation on the path-drawing path.
  ReplayPaint? paint;

  @override
  void span(int y, int xStart, int xEnd, int coverage) {
    final current = paint;
    if (current == null) return;
    final argb = current.argbColor;
    final alpha = mul255((argb >> 24) & 0xFF, coverage);
    if (alpha == 0) return;
    rasterizer.fillRect(
      Rect.fromLTRB(
        xStart.toDouble(),
        y.toDouble(),
        xEnd.toDouble(),
        (y + 1).toDouble(),
      ),
      (alpha << 24) | (argb & 0x00FFFFFF),
    );
  }
}

/// Rasterises [list] directly into an existing [framebuffer].
///
/// This is the shared CPU drawing path for owned memory targets and native
/// framebuffers such as a Win32 DIB section. Keeping the adapter here avoids a
/// full-frame staging copy and, more importantly, prevents platform backends
/// from growing their own subtly different display-list players.
///
/// [glyphCache] defaults to [GlyphCache.shared], because a cache that did not
/// outlive the frame would rasterize every glyph again on the next one.
///
/// [maxLayerDepth] bounds `saveLayer` nesting; past it the frame raises
/// [CpuLayerDepthExceededError] rather than allocating a buffer per level for
/// a tree that has run away. It is a parameter rather than a constant so that
/// a caller with a genuinely deep scene can pay for it, and so the refusal is
/// testable without a nine-level display list.
void rasterizeDisplayList(
  DisplayList list,
  Framebuffer framebuffer, {
  int? clearColor,
  Rect? damage,
  Transform2D deviceTransform = Transform2D.identity,
  GlyphCache? glyphCache,
  int maxLayerDepth = kMaxCpuLayerDepth,
}) {
  if (clearColor != null) {
    final blue = clearColor & 0xFF;
    final green = (clearColor >> 8) & 0xFF;
    final red = (clearColor >> 16) & 0xFF;
    final alpha = (clearColor >> 24) & 0xFF;
    if (damage == null) {
      framebuffer.clear(blue, green, red, alpha);
    } else {
      framebuffer.clearRect(damage, blue, green, red, alpha);
    }
  }
  final rasterizer = CpuRasterizer(framebuffer);
  final resources = DisplayListResources(list);
  final sink = _RasterizerSink(
    rasterizer,
    resources,
    glyphCache ?? GlyphCache.shared,
    maxLayerDepth: maxLayerDepth,
  );
  try {
    DisplayListPlayer(sink).play(
      DisplayListReader(list),
      resources,
      deviceBounds: (damage ??
              Rect.fromLTWH(
                0,
                0,
                framebuffer.width.toDouble(),
                framebuffer.height.toDouble(),
              ))
          .intersect(Rect.fromLTWH(
        0,
        0,
        framebuffer.width.toDouble(),
        framebuffer.height.toDouble(),
      )),
      deviceTransform: deviceTransform,
    );
  } finally {
    // Nothing is caught - a frame that cannot be interpreted must not be
    // half-drawn and the caller has to hear about it - but the layer buffers
    // an aborted frame is still holding have to go back, or the pool loses a
    // slot per failure. See [_RasterizerSink.releaseOpenLayers].
    sink.releaseOpenLayers();
  }
}

/// A render target backed by plain memory.
final class MemoryRenderTarget with DisposableMixin implements RenderTarget {
  MemoryRenderTarget(MemorySurfaceDescriptor surface)
      : _surface = surface,
        _framebuffer = Framebuffer.allocate(
          width: surface.pixelWidth,
          height: surface.pixelHeight,
          format: surface.format,
        );

  MemorySurfaceDescriptor _surface;
  Framebuffer _framebuffer;
  int _generation = 0;

  @override
  void onDispose() {}

  /// The last presented pixels. Golden tests read this.
  Framebuffer get framebuffer => _framebuffer;

  @override
  NativeSurfaceDescriptor get surface => _surface;

  @override
  int get generation => _generation;

  @override
  Frame beginFrame(FrameRequest request) {
    throwIfDisposed();
    final clear = request.clearColor;
    if (clear != null) {
      _framebuffer.clear(
        clear & 0xFF,
        (clear >> 8) & 0xFF,
        (clear >> 16) & 0xFF,
        (clear >> 24) & 0xFF,
      );
    }
    return Frame(
      target: this,
      framebuffer: _framebuffer,
      damage: request.damage ??
          Rect.fromLTWH(
            0,
            0,
            _framebuffer.width.toDouble(),
            _framebuffer.height.toDouble(),
          ),
      generation: _generation,
    );
  }

  @override
  Future<PresentResult> present(Frame frame) async {
    throwIfDisposed();
    // Rejecting rather than drawing is the whole reason Frame carries a
    // generation: a resize between beginFrame and present means these pixels
    // describe a surface that no longer exists.
    if (frame.generation != _generation) {
      return const PresentResult(
        status: PresentStatus.stale,
        diagnostic: BackendDiagnostic.note(
          'frame belonged to a previous generation of the target',
        ),
      );
    }
    return const PresentResult(status: PresentStatus.presented);
  }

  @override
  void resize(int pixelWidth, int pixelHeight, double scale) {
    throwIfDisposed();
    if (pixelWidth == _framebuffer.width &&
        pixelHeight == _framebuffer.height &&
        scale == _surface.scale) {
      return;
    }
    _generation++;
    _surface = MemorySurfaceDescriptor(
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      scale: scale,
      format: _surface.format,
    );
    _framebuffer = Framebuffer.allocate(
      width: pixelWidth,
      height: pixelHeight,
      format: _surface.format,
    );
  }

  /// Rasterises [list] into this target and presents it.
  ///
  /// The convenience that makes a golden test three lines long instead of
  /// thirty.
  Future<PresentResult> renderDisplayList(
    DisplayList list, {
    int? clearColor,
    Transform2D deviceTransform = Transform2D.identity,
    GlyphCache? glyphCache,
    int maxLayerDepth = kMaxCpuLayerDepth,
  }) async {
    final frame = beginFrame(const FrameRequest());
    rasterizeDisplayList(
      list,
      frame.framebuffer,
      clearColor: clearColor,
      deviceTransform: deviceTransform,
      glyphCache: glyphCache,
      maxLayerDepth: maxLayerDepth,
    );
    return present(frame);
  }
}

final class CpuRenderDevice with DisposableMixin implements RenderDevice {
  @override
  void onDispose() {}

  @override
  RendererInfo get info => const RendererInfo(
        name: 'cpu',
        deviceDescription: 'software scanline rasteriser',
      );

  @override
  RendererCapabilities get capabilities => const RendererCapabilities(
        // Honest answers, not aspirational ones. Partial present is true
        // because a memory target simply does not clear what it was not asked
        // to; msaa and compute are false because there is no path to them from
        // a scanline filler.
        supportsPartialPresent: true,
        supportsMsaa: false,
        supportsCompute: false,
        supportsExternalTextures: false,
        supportsLinearColor: false,
        maxTextureSize: 1 << 16,
        formats: {
          PixelFormat.bgra8888Premultiplied,
          PixelFormat.rgba8888Premultiplied,
        },
      );

  @override
  bool get isLost => false;

  @override
  RenderTarget createTarget(NativeSurfaceDescriptor surface) {
    throwIfDisposed();
    if (surface is! MemorySurfaceDescriptor) {
      throw UnsupportedCapabilityError(
        backendName: 'cpu',
        capability: Capability.cpuPresentation,
        detail: 'the CPU renderer presents to memory surfaces, not '
            '${surface.kind}',
      );
    }
    return MemoryRenderTarget(surface);
  }
}

/// Always available: it has no library to load and no device to lose.
final class CpuRendererBackend implements RendererBackend {
  const CpuRendererBackend();

  @override
  RendererInfo get info => const RendererInfo(
        name: 'cpu',
        deviceDescription: 'software scanline rasteriser',
      );

  @override
  BackendProbeResult probe() => BackendProbeResult(
        backendName: 'cpu',
        supported: true,
        capabilities: const {
          Capability.cpuPresentation,
          Capability.partialPresent,
        },
        diagnostics: const [
          BackendDiagnostic.note(
            'pure Dart scanline path with antialiasing; text renders through '
            'the same filler, cached as alpha8 glyph masks',
          ),
        ],
      );

  @override
  bool supportsSurface(NativeSurfaceDescriptor surface) =>
      surface is MemorySurfaceDescriptor;

  @override
  Future<RenderDevice> createDevice() async => CpuRenderDevice();
}
