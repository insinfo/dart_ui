/// What `saveLayer` costs on a GPU, and where the pixels of one go.
///
/// A layer is the one thing in this renderer that cannot be expressed as
/// "another quad in the same buffer". Everything else the display list can
/// say - a colour, a clip, a blend mode, a transform - is either vertex data
/// or one of the four state components [GpuBatcher] breaks a batch on. A
/// layer is different in kind: its contents have to be composited against
/// *transparency* first and the result composited against the parent, because
/// that is what its opacity and its blend mode are defined to apply to. There
/// is no arrangement of per-primitive state that produces that from one pass.
///
/// So a real layer needs a second render target and a second pass, and this
/// file is the device-independent half of that: it decides *when* a pass
/// starts and stops, *what size* a target has to be, *where* the layer's
/// pixels sit relative to the surface, and *how* the finished target is
/// composited back. What it never does is touch a graphics API. That is the
/// same split `gpu_batcher.dart`, `gpu_pipeline.dart` and `gpu_mask_atlas.dart`
/// already make, and it exists for the same reason: the arithmetic that decides
/// whether a layer lands one pixel off is exactly the arithmetic nobody can
/// step through inside a driver, so it is tested here with no driver at all.
///
/// ## The three kinds of layer, and why only one of them costs anything
///
/// [GpuLayerKind.empty] - the layer's bounds survived nothing. The player
/// still emits a balanced begin/end pair for it, and every primitive inside is
/// already culled by the clip it hands down, so this allocates nothing and
/// draws nothing.
///
/// [GpuLayerKind.flattened] - alpha 255 and source-over. Compositing such a
/// layer back is the identity, so its contents are drawn straight into the
/// parent and the layer is exactly its clip, which the player has already
/// folded into the clip of every primitive inside it. This is not an
/// approximation with a rounding error hiding in it; it is an algebraic
/// identity, **with one stated exception** (see [GpuLayerStack.push]).
///
/// [GpuLayerKind.offscreen] - anything else. A target is acquired, the pass
/// switches to it, and [GpuLayerStack.pop] hands back everything needed to
/// draw one textured quad that composites it.
///
/// ## Coordinates: the layer renders at its own origin, not the surface's
///
/// A layer's target is only as large as the layer, so geometry inside it is
/// written with the layer's whole-pixel top-left corner subtracted -
/// [GpuLayerStack.originX] and [GpuLayerStack.originY], which a caller applies
/// to every quad and every scissor. The alternative, a surface-sized target
/// per layer, needs no subtraction and costs a full-screen allocation and a
/// full-screen clear for a badge in a corner.
///
/// The origin is whole pixels - the bounds are snapped outward - and that is
/// load-bearing rather than tidy. A fractional origin would shift every mask
/// and every glyph inside the layer by a fraction of a pixel relative to the
/// coverage that was rasterised for them, which is the sub-pixel resampling
/// that makes text inside an opacity animation look softer than the same text
/// outside it.
///
/// ## Texture orientation is declared, not discovered
///
/// A layer's colour texture is **top-down**: texel row 0 is the layer's
/// topmost device row, exactly like every other texture this renderer samples
/// (uploaded images, the mask atlas, the glyph atlas). That is why the
/// composite quad below hands out `v0 = 0` for its top edge and nothing here
/// mentions a flip.
///
/// Whether that is *true* is the backend's promise to keep, and on OpenGL it
/// costs something: GL's framebuffer origin is the bottom-left corner, so a
/// pass that renders into a sampled texture has to invert its projection - see
/// [GpuRenderPass.rendersTopDown] and `gl_backend.dart`. Putting the flip in
/// the backend rather than in the composite's texture coordinates is
/// deliberate: this file and `gpu_raster_sink.dart` are shared by every future
/// backend, and Vulkan, Metal and D3D all store a rendered texture top-down
/// already. A flip written here would be a GL detail that every other backend
/// would have to undo.
///
/// ## What this file does not do, said plainly
///
///   * **No filters.** A layer carries an alpha and a blend mode. A blur, a
///     colour matrix or a backdrop filter needs a second sampling pass with a
///     kernel, and none exists; the display list cannot encode one either, so
///     there is nothing to refuse yet.
///   * **No target reuse inside a frame.** A layer's target is released back
///     to the allocator at [GpuLayerStack.endFrame] and not at [pop], because
///     the composite quad that samples it has only been *recorded* at that
///     point - it is drawn when the backend submits. Peak layer memory in a
///     frame is therefore proportional to the number of layers in it, not to
///     the nesting depth. The allocator's own budget is what bounds that, and
///     it is the allocator that says so.
///   * **No implicit depth.** Nesting is bounded by [GpuLayerStack.maxDepth]
///     and exceeding it raises [GpuLayerDepthExceededError] by name. A
///     runaway tree would otherwise consume one target per level until the
///     driver refused an allocation, which surfaces as a device loss three
///     layers of abstraction away from the widget that caused it.
library;

import '../../geometry/rect.dart';
import '../../graphics/display_list_opcodes.dart';

/// An offscreen colour target a layer renders into.
///
/// Deliberately four integers and no methods. The GPU-side object is a
/// framebuffer object plus a texture on GL, a `VkFramebuffer` plus a
/// `VkImageView` elsewhere; all this layer needs is a handle it can hand back
/// to the backend, the id of the texture the composite quad samples, and the
/// *allocated* size - which is at least the requested size and usually larger,
/// because an allocator that hands out exactly the requested pixels never
/// reuses anything (see `gl_framebuffer_pool.dart`).
abstract interface class GpuLayerTarget {
  /// The backend's own handle. Opaque here; on GL it is the framebuffer name.
  int get id;

  /// The colour texture the composite quad samples, in the same id space
  /// [GpuBatcher] compares to decide a batch break.
  int get textureId;

  /// Allocated size in texels, `>=` the size that was asked for. The extra is
  /// never rendered into and never sampled: the composite's texture
  /// coordinates stop at the layer's own pixel size.
  int get width;
  int get height;
}

/// Where a [GpuLayerStack] gets its targets.
///
/// An interface, and the reason the stack is testable with no GPU: a test
/// implements this with four integers and a counter and asserts that a second
/// layer of the same size allocated nothing.
abstract interface class GpuLayerTargetAllocator {
  /// A target of at least [width] by [height] texels, cleared or not - the
  /// pass clears it, because only the pass knows when the previous tenant's
  /// pixels stop being read.
  ///
  /// Must not return null: a layer that cannot get a target cannot be drawn
  /// correctly, and returning null would push that decision to a caller that
  /// has no better answer than the allocator does. An allocator that has hit
  /// its budget throws by name.
  GpuLayerTarget acquireLayerTarget(int width, int height);

  /// Returns [target] for reuse. Called once per acquired target, at the end
  /// of the frame that used it - never at [GpuLayerStack.pop], because the
  /// composite quad has only been recorded by then.
  void releaseLayerTarget(GpuLayerTarget target);
}

/// Raised when layers nest deeper than the declared limit.
///
/// A named error rather than an assertion or a silent clamp, per section 6.6.
/// The three things that go wrong without it are all worse than a thrown
/// error: the Dart stack overflows inside the player, the allocator's budget
/// is exhausted by targets nobody will ever composite, or - if the limit were
/// a silent clamp - a layer's contents would be drawn into its grandparent
/// with the wrong opacity and no diagnostic anywhere.
final class GpuLayerDepthExceededError extends Error {
  GpuLayerDepthExceededError({
    required this.backendName,
    required this.depth,
    required this.maxDepth,
  });

  /// Named in the message, per section 6.6.
  final String backendName;

  /// The depth the caller tried to reach - always [maxDepth] + 1.
  final int depth;

  final int maxDepth;

  @override
  String toString() => 'GpuLayerDepthExceededError: $backendName refuses to '
      'open layer $depth; the limit is $maxDepth nested layers. Each level '
      'holds its own offscreen target for the whole frame, so the limit '
      'bounds video memory rather than taste. A tree this deep is almost '
      'always a saveLayer inside a loop; a legitimate one raises maxDepth on '
      'the GpuLayerStack and pays for it.';
}

/// What a pushed layer turned out to be.
enum GpuLayerKind {
  /// No pixels: the bounds were empty after clipping. Nothing was allocated.
  empty,

  /// Composited back with alpha 255 and source-over, which is the identity, so
  /// the contents were drawn straight into the parent.
  flattened,

  /// Rendered into its own target and composited back with one quad.
  offscreen,
}

/// One layer on the stack: what it is, where it is and how it composites.
///
/// Returned by both [GpuLayerStack.push] and [GpuLayerStack.pop] so that a
/// caller reads the same object twice rather than re-deriving the geometry -
/// re-deriving it is how the composite quad ends up half a pixel from the
/// contents it is meant to hold.
final class GpuLayer {
  GpuLayer._({
    required this.kind,
    required this.deviceBounds,
    required this.clip,
    required this.alpha,
    required this.blendMode,
    required this.target,
    required this.parentOriginX,
    required this.parentOriginY,
    required this.firstBatch,
  });

  final GpuLayerKind kind;

  /// The layer's pixels in device space, snapped **outward** to whole pixels.
  /// [Rect.zero] for an empty layer.
  final Rect deviceBounds;

  /// The clip that was in force when the layer opened, in device space. The
  /// composite quad is scissored to it: the layer's own contents were already
  /// clipped, but the quad is drawn in the parent's pass and has to obey the
  /// parent's clip.
  final Rect clip;

  /// Composite opacity, 0..255, taken from the layer paint's alpha channel.
  final int alpha;

  /// One of the display list's `blendMode*` constants.
  final int blendMode;

  /// Null unless [kind] is [GpuLayerKind.offscreen].
  final GpuLayerTarget? target;

  /// The origin geometry was being written against *outside* this layer, so a
  /// composite quad can be placed in the parent's coordinates.
  final double parentOriginX;
  final double parentOriginY;

  /// The batch index the layer's contents start at. Compared against the live
  /// batch count at [GpuLayerStack.pop] to tell "this layer drew nothing" from
  /// "this layer drew something", which decides whether a composite is worth a
  /// draw call at all.
  final int firstBatch;

  /// Whether anything was actually batched inside this layer. False makes the
  /// composite a no-op the caller must skip - not merely to save a draw call,
  /// but because a target nothing rendered into holds the previous tenant's
  /// pixels and the pass that would have cleared it was dropped with it.
  bool get drewSomething => _drewSomething;
  bool _drewSomething = false;

  /// Width in device pixels, which is also the width in texels: the composite
  /// samples one texel per pixel.
  int get pixelWidth => deviceBounds.width.round();
  int get pixelHeight => deviceBounds.height.round();

  /// The composite's premultiplied modulation factor, the same quantity an
  /// image quad carries: the texture is premultiplied, so all four channels
  /// are scaled by the opacity and nothing is tinted.
  double get opacity => alpha / 255.0;

  /// Texture coordinates of the layer inside its (possibly larger) target.
  /// `u0`/`v0` are zero because the layer renders at the target's top-left
  /// corner; see the library comment for why the texture is top-down.
  double get u0 => 0;
  double get v0 => 0;
  double get u1 => target == null ? 0 : pixelWidth / target!.width;
  double get v1 => target == null ? 0 : pixelHeight / target!.height;

  @override
  String toString() => 'GpuLayer(${kind.name}, $deviceBounds, alpha $alpha, '
      'blend $blendMode${target == null ? '' : ', target ${target!.id}'})';
}

/// One contiguous run of batches drawn into one render target.
///
/// The whole point of the type: a frame with layers is no longer "one target,
/// N batches". It is a *sequence* of (target, batch range) pairs, in the order
/// the display list produced them, and a backend replays it by binding a
/// target and drawing that range. Nesting does not need a nested
/// representation - a layer that opens inside another simply appends a pass
/// and the parent appends a second one when it resumes.
///
/// The end of a pass is not stored. It is the next pass's [firstBatch], or the
/// batcher's live batch count for the last one, and deriving it means there is
/// no field that can be stale while a frame is still being recorded. See
/// [GpuLayerStack.passEnd].
final class GpuRenderPass {
  GpuRenderPass._();

  GpuLayerTarget? _target;
  int _firstBatch = 0;
  int _viewportWidth = 0;
  int _viewportHeight = 0;
  bool _clearsTarget = false;
  bool _rendersTopDown = false;

  /// The target this run draws into, or null for the surface the frame is
  /// being rendered to. Null rather than a sentinel id because the surface's
  /// own handle belongs to the backend - a window's back buffer and an
  /// offscreen readback buffer are different objects with the same role.
  GpuLayerTarget? get target => _target;

  /// Index of the first batch in this run, into [GpuBatcher.batchAt].
  int get firstBatch => _firstBatch;

  /// The viewport this run needs, in pixels. For a layer it is the layer's own
  /// size and *not* the target's allocated size: the rest of a pooled target
  /// is never rendered into.
  int get viewportWidth => _viewportWidth;
  int get viewportHeight => _viewportHeight;

  /// Whether the target must be cleared to transparent before the first batch
  /// of this run. True exactly once per layer target: its texels are whatever
  /// the previous tenant left, and a layer composites what it drew *over
  /// transparency*, not over a ghost.
  bool get clearsTarget => _clearsTarget;

  /// Whether this run renders into a texture that will be sampled, and so must
  /// be written top-down. See the library comment: on GL this inverts the
  /// projection and the scissor's y; on an API whose framebuffer origin is
  /// already the top-left corner it changes nothing.
  bool get rendersTopDown => _rendersTopDown;

  @override
  String toString() => 'GpuRenderPass(${_target == null ? 'surface' : 'target '
          '${_target!.id}'}, from batch $_firstBatch, viewport '
      '${_viewportWidth}x$_viewportHeight'
      '${_clearsTarget ? ', clears' : ''}'
      '${_rendersTopDown ? ', top-down' : ''})';
}

/// The stack of open layers, and the passes they cut a frame into.
final class GpuLayerStack {
  GpuLayerStack({
    required this.allocator,
    this.backendName = 'gpu',
    this.maxDepth = kDefaultMaxLayerDepth,
  }) : assert(maxDepth > 0);

  /// Eight, and the number is a memory budget rather than a guess.
  ///
  /// Every open layer holds a target for the rest of the frame (see the
  /// library comment), so depth multiplies peak layer memory directly: eight
  /// full-screen layers on a 4K surface is already half a gigabyte, and no
  /// real interface nests opacity more than three or four deep - a dialog
  /// fading inside a page fading inside a transition is three. Eight leaves
  /// generous headroom over the deepest legitimate case and still catches the
  /// runaway - a `saveLayer` inside a build loop - within a few frames.
  static const int kDefaultMaxLayerDepth = 8;

  final GpuLayerTargetAllocator allocator;

  /// Named in every error this stack raises, per section 6.6.
  final String backendName;

  final int maxDepth;

  final List<GpuLayer> _open = <GpuLayer>[];

  /// Every target acquired this frame, released together at [endFrame].
  final List<GpuLayerTarget> _acquired = <GpuLayerTarget>[];

  /// Pooled and rewritten in place across frames, the way [GpuBatch] objects
  /// are: a frame with layers must not allocate a pass object per layer per
  /// frame just to describe where its batches went.
  final List<GpuRenderPass> _passPool = <GpuRenderPass>[];
  int _passCount = 0;

  int _surfaceWidth = 0;
  int _surfaceHeight = 0;
  double _originX = 0;
  double _originY = 0;

  /// Layers currently open. Zero between frames, or the player and this stack
  /// disagree about a clip.
  int get depth => _open.length;

  /// The device-space origin every quad and scissor is currently written
  /// against. Zero outside a layer; the innermost offscreen layer's top-left
  /// corner inside one, always on a whole pixel.
  double get originX => _originX;
  double get originY => _originY;

  /// The size of the surface or layer being rendered into right now, which is
  /// what a scissor is clamped against.
  int get targetWidth => _open.isEmpty
      ? _surfaceWidth
      : (_innermostOffscreen?.pixelWidth ?? _surfaceWidth);
  int get targetHeight => _open.isEmpty
      ? _surfaceHeight
      : (_innermostOffscreen?.pixelHeight ?? _surfaceHeight);

  /// Passes recorded so far, in submission order. Valid until [beginFrame].
  int get passCount => _passCount;

  GpuRenderPass passAt(int index) {
    if (index < 0 || index >= _passCount) {
      throw RangeError.index(index, _passPool, 'index', null, _passCount);
    }
    return _passPool[index];
  }

  Iterable<GpuRenderPass> get passes => _passPool.take(_passCount);

  /// Whether this frame needs more than the one implicit surface pass.
  ///
  /// A backend reads it to keep the no-layer path exactly as it was: one
  /// viewport, one framebuffer binding, one loop over every batch.
  bool get hasLayerPasses => _passCount > 1;

  /// Where pass [index] stops, exclusive, given the batcher's current count.
  ///
  /// [totalBatchCount] rather than a stored field so that the last pass is
  /// correct while a frame is still being recorded - which is exactly the
  /// state a mid-frame atlas flush submits from.
  int passEnd(int index, int totalBatchCount) => index + 1 < _passCount
      ? _passPool[index + 1]._firstBatch
      : totalBatchCount;

  /// Opens a frame on a [surfaceWidth] by [surfaceHeight] surface.
  ///
  /// Releases anything a previous frame left behind. That is defensive rather
  /// than decorative: a frame that threw halfway - an unsupported primitive,
  /// a full atlas - never reached [endFrame], and leaking one target per
  /// failed frame turns a recoverable error into an allocator that fills up.
  void beginFrame({required int surfaceWidth, required int surfaceHeight}) {
    endFrame();
    _surfaceWidth = surfaceWidth;
    _surfaceHeight = surfaceHeight;
    _originX = 0;
    _originY = 0;
    _passCount = 0;
    _appendPass(
      target: null,
      firstBatch: 0,
      viewportWidth: surfaceWidth,
      viewportHeight: surfaceHeight,
      clearsTarget: false,
      rendersTopDown: false,
    );
  }

  /// Opens a layer whose contents start at batch [batchIndex].
  ///
  /// [deviceBounds] is the layer's bounds already intersected with the clip,
  /// as the player delivers them; [clip] is the clip the *composite* obeys;
  /// [alpha] and [blendMode] come from the layer paint.
  ///
  /// The caller must have closed the batcher's open batch first, or the
  /// layer's first quad would merge into a batch that belongs to the parent
  /// pass and be drawn into the wrong target.
  ///
  /// ## The one case where flattening is not an identity
  ///
  /// A layer with alpha 255 and source-over is flattened, because compositing
  /// its contents over transparency and then that over the parent is the same
  /// arithmetic as drawing them over the parent - *for source-over contents*.
  /// A primitive **inside** it drawn with `plus` or `src` is the exception:
  /// `plus` against transparency then over the parent is not `plus` against
  /// the parent. That case is refused by name in `gpu_raster_sink.dart` rather
  /// than drawn wrong, which is the whole reason the exception is written down
  /// here instead of being left as a comfortable assumption.
  GpuLayer push({
    required Rect deviceBounds,
    required Rect clip,
    required int alpha,
    required int blendMode,
    required int batchIndex,
  }) {
    if (_open.length >= maxDepth) {
      throw GpuLayerDepthExceededError(
        backendName: backendName,
        depth: _open.length + 1,
        maxDepth: maxDepth,
      );
    }

    // Outward to whole pixels, for the reason the library comment gives: the
    // origin is subtracted from every mask and glyph quad inside the layer,
    // and a fractional subtraction resamples coverage that was rasterised for
    // a different phase.
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

    if (degenerate) {
      return _pushOpen(
        GpuLayer._(
          kind: GpuLayerKind.empty,
          deviceBounds: Rect.zero,
          clip: clip,
          alpha: alpha,
          blendMode: blendMode,
          target: null,
          parentOriginX: _originX,
          parentOriginY: _originY,
          firstBatch: batchIndex,
        ),
      );
    }

    if (alpha == 0xFF && blendMode == blendModeSrcOver) {
      return _pushOpen(
        GpuLayer._(
          kind: GpuLayerKind.flattened,
          deviceBounds: Rect.fromLTRB(left, top, right, bottom),
          clip: clip,
          alpha: alpha,
          blendMode: blendMode,
          target: null,
          parentOriginX: _originX,
          parentOriginY: _originY,
          firstBatch: batchIndex,
        ),
      );
    }

    final int width = (right - left).round();
    final int height = (bottom - top).round();
    final GpuLayerTarget target = allocator.acquireLayerTarget(width, height);
    _acquired.add(target);

    final GpuLayer layer = _pushOpen(
      GpuLayer._(
        kind: GpuLayerKind.offscreen,
        deviceBounds: Rect.fromLTRB(left, top, right, bottom),
        clip: clip,
        alpha: alpha,
        blendMode: blendMode,
        target: target,
        parentOriginX: _originX,
        parentOriginY: _originY,
        firstBatch: batchIndex,
      ),
    );
    _originX = left;
    _originY = top;
    _appendPass(
      target: target,
      firstBatch: batchIndex,
      viewportWidth: width,
      viewportHeight: height,
      clearsTarget: true,
      rendersTopDown: true,
    );
    return layer;
  }

  /// Closes the innermost layer and returns it so the caller can composite it.
  ///
  /// [batchIndex] is the batcher's live batch count, which is both where the
  /// layer's contents stopped and where the parent's resumed run starts.
  ///
  /// A layer that batched nothing takes its pass with it: the pass is dropped,
  /// the target is returned to the allocator immediately - nothing recorded
  /// samples it - and [GpuLayer.drewSomething] is false so the caller skips
  /// the composite. Keeping a zero-batch pass would be worse than wasteful: a
  /// backend that skips empty passes would never clear the target, and the
  /// composite would then sample the previous tenant's pixels.
  GpuLayer pop({required int batchIndex}) {
    if (_open.isEmpty) {
      throw StateError('$backendName: pop() without a matching push(); the '
          'player and the layer stack disagree about how many layers are '
          'open, which means a clip is still in force that should not be');
    }
    final GpuLayer layer = _open.removeLast();
    _originX = layer.parentOriginX;
    _originY = layer.parentOriginY;
    if (layer.kind != GpuLayerKind.offscreen) return layer;

    layer._drewSomething = batchIndex > layer.firstBatch;
    if (!layer.drewSomething) {
      // The pass this layer appended is necessarily the last one, because a
      // nested layer would have appended and then removed or resumed its own.
      _passCount--;
      _acquired.remove(layer.target);
      allocator.releaseLayerTarget(layer.target!);
      return layer;
    }

    _appendPass(
      target: _innermostOffscreen?.target,
      firstBatch: batchIndex,
      viewportWidth: targetWidth,
      viewportHeight: targetHeight,
      // The parent's target was cleared when *it* opened. Clearing again here
      // would erase everything drawn before the layer opened.
      clearsTarget: false,
      rendersTopDown: _innermostOffscreen != null,
    );
    return layer;
  }

  /// Returns every target this frame used. Call after the backend has
  /// submitted, never before: until the draws are issued the composite quads
  /// are still going to sample those textures.
  void endFrame() {
    for (var i = 0; i < _acquired.length; i++) {
      allocator.releaseLayerTarget(_acquired[i]);
    }
    _acquired.clear();
    _open.clear();
    _originX = 0;
    _originY = 0;
  }

  GpuLayer? get _innermostOffscreen {
    for (var i = _open.length - 1; i >= 0; i--) {
      if (_open[i].kind == GpuLayerKind.offscreen) return _open[i];
    }
    return null;
  }

  GpuLayer _pushOpen(GpuLayer layer) {
    _open.add(layer);
    return layer;
  }

  void _appendPass({
    required GpuLayerTarget? target,
    required int firstBatch,
    required int viewportWidth,
    required int viewportHeight,
    required bool clearsTarget,
    required bool rendersTopDown,
  }) {
    if (_passCount == _passPool.length) _passPool.add(GpuRenderPass._());
    _passPool[_passCount++]
      .._target = target
      .._firstBatch = firstBatch
      .._viewportWidth = viewportWidth
      .._viewportHeight = viewportHeight
      .._clearsTarget = clearsTarget
      .._rendersTopDown = rendersTopDown;
  }
}
