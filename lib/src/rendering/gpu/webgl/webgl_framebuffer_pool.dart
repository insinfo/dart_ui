/// Where a `saveLayer` gets its offscreen surface on WebGL2.
///
/// `GpuLayerStack` asks a [GpuLayerTargetAllocator] for a target of a given
/// size and hands it back when the layer closes. Allocating a framebuffer plus
/// a texture per layer per frame would be one of the most expensive things a
/// renderer can do - a driver allocation and a completeness check inside the
/// frame - so this pools them, keyed on the size bucket, exactly as
/// `gl_framebuffer_pool.dart` does for the desktop backend.
///
/// ## Why the sizes are rounded up
///
/// A layer's bounds are whatever the scene produced, so a scrolling list of
/// cards asks for 300x81, then 300x82, then 300x81 again. Keying the pool on
/// the exact size would make every one of those a miss and the pool would be a
/// map of single-use targets. Rounding up to a power of two per axis turns the
/// whole run into one bucket, at the cost of some slack texels - which cost
/// nothing to draw, because `GpuRenderPass.viewportWidth` is the *layer's* own
/// size and the composite quad's `u1`/`v1` come from
/// `GpuLayer.pixelWidth / target.width`. The slack is never sampled and never
/// rasterised over.
///
/// ## The integer id, and why there is one at all
///
/// [GpuLayerTarget.id] and [GpuLayerTarget.textureId] are `int`, because on
/// OpenGL, Direct3D and Vulkan a framebuffer and a texture *are* integers or
/// can be numbered as such, and `GpuBatch.textureId` is one integer that the
/// batcher compares to break batches. WebGL has no such numbers: `WebGLTexture`
/// and `WebGLFramebuffer` are opaque JavaScript objects with no identity a
/// batcher could compare cheaply.
///
/// So this backend keeps its own numbering, handed out by
/// [WebGlObjectTable], and every place that would have bound `batch.textureId`
/// directly looks the object up instead. One map lookup per *batch* - not per
/// quad, not per vertex - which is the same order of cost as the redundant
/// state filter it sits next to.
library;

import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../../../foundation/diagnostics.dart';
import '../gpu_layer_stack.dart';

/// The numbering that stands in for GL's object names.
///
/// Ids start at 1 because `kNoTexture` is 0 and `GpuBatch.textureId == 0` has
/// to keep meaning "this batch samples nothing". A monotonic counter rather
/// than reusing freed ids: an id that was handed out twice would let a batch
/// recorded against a released texture silently bind its replacement, which is
/// a wrong picture rather than a failure.
final class WebGlObjectTable<T extends Object> {
  final Map<int, T> _byId = <int, T>{};
  int _next = 1;

  int get length => _byId.length;

  /// The next id this table will hand out. For diagnostics and tests.
  int get nextId => _next;

  int register(T object) {
    final int id = _next++;
    _byId[id] = object;
    return id;
  }

  T? lookup(int id) => _byId[id];

  T? release(int id) => _byId.remove(id);

  void clear() => _byId.clear();
}

/// One pooled render-to-texture surface.
final class WebGlLayerTarget implements GpuLayerTarget {
  WebGlLayerTarget._({
    required this.id,
    required this.textureId,
    required this.width,
    required this.height,
    required this.framebuffer,
    required this.texture,
  });

  @override
  final int id;

  @override
  final int textureId;

  @override
  final int width;

  @override
  final int height;

  /// Null when the context refused to create one, which is what a lost
  /// context does. The target still exists so `GpuLayerStack.push` - which is
  /// called from inside a display-list walk and cannot handle a null - gets
  /// something back; the diagnostic that accompanied the refusal has already
  /// marked the device lost, so nothing will be drawn into it.
  final web.WebGLFramebuffer? framebuffer;
  final web.WebGLTexture? texture;

  /// Whether this target is backed by real driver objects.
  bool get isBacked => framebuffer != null && texture != null;

  @override
  String toString() => 'WebGlLayerTarget(#$id, texture #$textureId, '
      '${width}x$height${isBacked ? '' : ', unbacked'})';
}

/// Rounds up to the next power of two, with a floor of 16.
///
/// The floor exists because a tooltip's shadow layer can be four pixels tall,
/// and a pool of 1x1, 2x2 and 4x4 buckets is a pool that never hits.
int webGlLayerBucket(int extent) {
  if (extent <= 16) return 16;
  var size = 16;
  while (size < extent) {
    size <<= 1;
  }
  return size;
}

/// The pool `GpuLayerStack` allocates from.
///
/// Not disposable-by-mixin: it is owned by a target, which disposes it as part
/// of its own teardown, and a pool that could be disposed independently would
/// let a layer stack hold framebuffers the device had already deleted.
final class WebGlFramebufferPool implements GpuLayerTargetAllocator {
  WebGlFramebufferPool({
    required web.WebGL2RenderingContext gl,
    required WebGlObjectTable<web.WebGLTexture> textures,
    required void Function(BackendDiagnostic) onError,
    this.maxIdlePerBucket = 4,
  })  : _gl = gl,
        _textures = textures,
        _onError = onError;

  final web.WebGL2RenderingContext _gl;

  /// The device's texture numbering, shared so a composite quad can bind a
  /// layer's texture by the same integer everything else uses.
  final WebGlObjectTable<web.WebGLTexture> _textures;

  final void Function(BackendDiagnostic) _onError;

  /// How many idle targets a bucket keeps before the next release deletes
  /// instead of parking.
  ///
  /// Bounded because a frame that opened forty layers of one size would
  /// otherwise leave forty full-size textures resident for the rest of the
  /// session. Four is the depth a nested-layer scene actually reaches -
  /// `GpuLayerStack.kDefaultMaxLayerDepth` is 8 and half of that is the
  /// observed worst case for the gallery.
  final int maxIdlePerBucket;

  final Map<int, List<WebGlLayerTarget>> _idle =
      <int, List<WebGlLayerTarget>>{};
  final Set<WebGlLayerTarget> _live = <WebGlLayerTarget>{};

  int _createdCount = 0;
  int _reuseCount = 0;

  /// Framebuffers this pool has asked the driver for, ever. The number the
  /// pooling claim rests on: a scene that draws the same layer on ten frames
  /// must not increase it past one.
  int get createdCount => _createdCount;

  /// Acquisitions served from the idle list.
  int get reuseCount => _reuseCount;

  int get liveCount => _live.length;

  int get idleCount => _idle.values
      .fold(0, (int sum, List<WebGlLayerTarget> l) => sum + l.length);

  static int _key(int width, int height) => (width << 16) | height;

  @override
  GpuLayerTarget acquireLayerTarget(int width, int height) {
    final int bucketWidth = webGlLayerBucket(width);
    final int bucketHeight = webGlLayerBucket(height);
    final int key = _key(bucketWidth, bucketHeight);
    final List<WebGlLayerTarget>? free = _idle[key];
    if (free != null && free.isNotEmpty) {
      final WebGlLayerTarget target = free.removeLast();
      _live.add(target);
      _reuseCount++;
      return target;
    }
    final WebGlLayerTarget created = _create(bucketWidth, bucketHeight);
    _live.add(created);
    return created;
  }

  @override
  void releaseLayerTarget(GpuLayerTarget target) {
    if (target is! WebGlLayerTarget) return;
    if (!_live.remove(target)) return;
    final int key = _key(target.width, target.height);
    final List<WebGlLayerTarget> free =
        _idle.putIfAbsent(key, () => <WebGlLayerTarget>[]);
    if (free.length >= maxIdlePerBucket) {
      _destroy(target);
      return;
    }
    free.add(target);
  }

  WebGlLayerTarget _create(int width, int height) {
    _createdCount++;
    final web.WebGLTexture? texture = _gl.createTexture();
    final web.WebGLFramebuffer? framebuffer = _gl.createFramebuffer();
    if (texture == null || framebuffer == null) {
      _onError(BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'the WebGL2 context refused a layer target',
        detail: 'createTexture or createFramebuffer returned null for a '
            '${width}x$height layer, which is what a lost context answers',
      ));
      // Whatever half was created is deleted rather than leaked; the other
      // half is what failed.
      if (texture != null) _gl.deleteTexture(texture);
      if (framebuffer != null) _gl.deleteFramebuffer(framebuffer);
      return WebGlLayerTarget._(
        id: 0,
        textureId: 0,
        width: width,
        height: height,
        framebuffer: null,
        texture: null,
      );
    }

    _gl
      ..bindTexture(web.WebGL2RenderingContext.TEXTURE_2D, texture)
      ..texParameteri(
        web.WebGL2RenderingContext.TEXTURE_2D,
        web.WebGL2RenderingContext.TEXTURE_MIN_FILTER,
        web.WebGL2RenderingContext.LINEAR,
      )
      ..texParameteri(
        web.WebGL2RenderingContext.TEXTURE_2D,
        web.WebGL2RenderingContext.TEXTURE_MAG_FILTER,
        web.WebGL2RenderingContext.LINEAR,
      )
      // Clamped, not repeated: the composite quad samples up to the layer's
      // own edge, and a wrapped tap at u == 1 would pull in the opposite side
      // of the texture - a one-pixel bright seam down the far edge of every
      // layer, which is the classic symptom and is easy to blame on the
      // rounding instead.
      ..texParameteri(
        web.WebGL2RenderingContext.TEXTURE_2D,
        web.WebGL2RenderingContext.TEXTURE_WRAP_S,
        web.WebGL2RenderingContext.CLAMP_TO_EDGE,
      )
      ..texParameteri(
        web.WebGL2RenderingContext.TEXTURE_2D,
        web.WebGL2RenderingContext.TEXTURE_WRAP_T,
        web.WebGL2RenderingContext.CLAMP_TO_EDGE,
      )
      ..texImage2D(
        web.WebGL2RenderingContext.TEXTURE_2D,
        0,
        web.WebGL2RenderingContext.RGBA8,
        width.toJS,
        height.toJS,
        0.toJS,
        web.WebGL2RenderingContext.RGBA,
        web.WebGL2RenderingContext.UNSIGNED_BYTE,
        null,
      )
      ..bindFramebuffer(web.WebGL2RenderingContext.FRAMEBUFFER, framebuffer)
      ..framebufferTexture2D(
        web.WebGL2RenderingContext.FRAMEBUFFER,
        web.WebGL2RenderingContext.COLOR_ATTACHMENT0,
        web.WebGL2RenderingContext.TEXTURE_2D,
        texture,
        0,
      );

    final int status =
        _gl.checkFramebufferStatus(web.WebGL2RenderingContext.FRAMEBUFFER);
    if (status != web.WebGL2RenderingContext.FRAMEBUFFER_COMPLETE) {
      _onError(BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'a WebGL2 layer framebuffer is incomplete',
        detail: 'checkFramebufferStatus returned '
            '0x${status.toRadixString(16)} for a ${width}x$height layer',
      ));
    }
    _gl.bindFramebuffer(web.WebGL2RenderingContext.FRAMEBUFFER, null);

    return WebGlLayerTarget._(
      id: _framebuffers.register(framebuffer),
      textureId: _textures.register(texture),
      width: width,
      height: height,
      framebuffer: framebuffer,
      texture: texture,
    );
  }

  /// This pool's own framebuffer numbering.
  ///
  /// Separate from the device's texture table because the two id spaces are
  /// independent: `GpuLayerTarget.id` is only ever handed back to this
  /// backend's `submit`, while `textureId` is compared against every other
  /// texture the batcher sees.
  final WebGlObjectTable<web.WebGLFramebuffer> _framebuffers =
      WebGlObjectTable<web.WebGLFramebuffer>();

  /// The framebuffer object [id] names, for the submit loop.
  web.WebGLFramebuffer? framebufferFor(int id) => _framebuffers.lookup(id);

  void _destroy(WebGlLayerTarget target) {
    _framebuffers.release(target.id);
    _textures.release(target.textureId);
    _gl
      ..deleteFramebuffer(target.framebuffer)
      ..deleteTexture(target.texture);
  }

  /// Forgets every object without calling the driver.
  ///
  /// For a lost context, where the names point at memory the browser already
  /// freed. Deleting them is a no-op on a lost WebGL context rather than
  /// undefined behaviour - the specification says every entry point becomes a
  /// no-op - but going through the id tables is still required, or the next
  /// pool would hand out ids that resolve to dead objects.
  void forget() {
    _framebuffers.clear();
    for (final WebGlLayerTarget target in _live) {
      _textures.release(target.textureId);
    }
    for (final List<WebGlLayerTarget> free in _idle.values) {
      for (final WebGlLayerTarget target in free) {
        _textures.release(target.textureId);
      }
    }
    _live.clear();
    _idle.clear();
  }

  /// Deletes every idle target. Live ones are left alone, because a pool
  /// disposed mid-frame would delete framebuffers a pass is still writing to.
  void dispose() {
    for (final List<WebGlLayerTarget> free in _idle.values) {
      for (final WebGlLayerTarget target in free) {
        _destroy(target);
      }
    }
    _idle.clear();
  }
}
