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
/// ## What this cannot do yet, said plainly
///
///   * **It is a CPU rasteriser.** A path costs the same CPU time it costs on
///     the CPU backend, plus an upload. The GPU wins the compositing, the
///     blending and the fill rate; it does not win the path. An animated
///     complex path is therefore *not* faster here.
///   * **Masks are frame-local.** The atlas resets every frame, so a path
///     that did not change is re-rasterised anyway. Caching by (path,
///     transform) is the obvious next step and is deliberately absent: a
///     cache with no eviction policy is worse than none, and the policy needs
///     a frame budget this framework does not measure yet.
///   * **A shape larger than the atlas fails loudly.** No tiling, no
///     splitting. [rasterize] returns null and the sink turns that into a
///     named error rather than dropping the shape.
///   * **The atlas cannot be flushed mid-frame.** When it fills, the frame
///     fails. The fix is a flush-upload-reset cycle driven by the backend,
///     which needs [GpuBatcher.flush] plus an upload callback; the hook is
///     there and the policy is not.
///   * **No strokes.** Same reason as the CPU path: filling a stroke-styled
///     paint would draw the region the outline encloses, which looks
///     deliberate and is wrong.
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
  String toString() =>
      'MaskQuad($deviceRect, uv $u0,$v0..$u1,$v1)';
}

/// A CPU-side alpha8 staging image plus the packer that carves it up.
///
/// The texture itself lives in the backend; this owns the bytes and the
/// dirty region, so the upload is one `glTexSubImage2D` per frame over the
/// rectangle that actually changed rather than one per shape.
final class GpuMaskAtlas {
  GpuMaskAtlas({this.width = 1024, this.height = 1024})
      : assert(width > 0 && height > 0),
        pixels = Uint8List(width * height),
        _packer = ShelfAtlas(width: width, height: height);

  final int width;
  final int height;

  /// One byte per texel, row-major, `bytesPerRow == width`.
  final Uint8List pixels;

  final ShelfAtlas _packer;

  /// Kept across frames: it owns the edge and accumulator buffers that must
  /// not be rebuilt per path. Same reason `_RasterizerSink` keeps one.
  final ScanlineFiller _filler = ScanlineFiller();
  late final _MaskSpanSink _sink = _MaskSpanSink(this);

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

  /// Texels reserved since the last [beginFrame], for diagnostics.
  int get shelfCount => _packer.shelfCount;

  /// Drops every allocation. See the library comment for why this is per
  /// frame and what it costs.
  void beginFrame() {
    _packer.reset();
    markUploaded();
  }

  /// Declares the dirty region consumed. The backend calls this after the
  /// upload; nothing else may.
  void markUploaded() {
    _dirtyLeft = 0;
    _dirtyTop = 0;
    _dirtyRight = 0;
    _dirtyBottom = 0;
  }

  /// Rasterises [path] under [transform], clipped to [clip], into a free slot.
  ///
  /// Returns null when the shape is invisible (nothing to draw) or when the
  /// atlas has no room (the caller must decide what that means - see the
  /// library comment). Never throws for either.
  MaskQuad? rasterize(
    Path path, {
    required Transform2D transform,
    required Rect clip,
    FillRule rule = FillRule.nonZero,
  }) {
    final visible = transform.transformRect(path.bounds).intersect(clip);
    if (visible.isEmpty) return null;

    // Outward to whole pixels: an edge at x = 10.2 still puts ink in column
    // 10, and the mask has to contain every pixel the quad will sample.
    final left = visible.left.floor();
    final top = visible.top.floor();
    final right = visible.right.ceil();
    final bottom = visible.bottom.ceil();
    final w = right - left;
    final h = bottom - top;
    if (w <= 0 || h <= 0) return null;

    final slot = _packer.allocate(w, h);
    if (slot == null) return null;

    // The slot is reused memory from a previous frame, and the filler only
    // writes covered spans. Without this the uncovered interior of a shape
    // would show last frame's coverage.
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

    // Texel edges, not centres. The quad is exactly w by h device pixels and
    // is sampled with nearest filtering, so pixel centres land on texel
    // centres and the mapping is one to one.
    return MaskQuad(
      Rect.fromLTRB(
        left.toDouble(),
        top.toDouble(),
        right.toDouble(),
        bottom.toDouble(),
      ),
      slot.x / width,
      slot.y / height,
      (slot.x + w) / width,
      (slot.y + h) / height,
    );
  }

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
}

/// Writes the filler's coverage runs straight into the staging bytes.
///
/// A span is a run of one coverage value, so this is a `fillRange` and not a
/// per-pixel loop - which is why a mask costs about what the CPU renderer's
/// span compositing costs, minus the blending.
final class _MaskSpanSink implements CoverageSpanSink {
  _MaskSpanSink(this._atlas);

  final GpuMaskAtlas _atlas;

  @override
  void span(int y, int xStart, int xEnd, int coverage) {
    if (xEnd <= xStart) return;
    final base = y * _atlas.width;
    _atlas.pixels.fillRange(base + xStart, base + xEnd, coverage);
  }
}
