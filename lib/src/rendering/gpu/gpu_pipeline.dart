/// Pipeline and vertex-layout description, shared by every GPU backend.
///
/// A "pipeline" here is the pair (what the fragment shader does, how the
/// result is blended). It is deliberately not a program object, a
/// `VkPipeline` or an `MTLRenderPipelineState`: those are created by a device
/// and cached by it, while this is the *description* the batcher compares to
/// decide whether two primitives can share a draw call. Keeping the
/// description separate from the object is what lets the batching tests run
/// with no device at all.
///
/// ## One vertex layout for all three pipelines
///
/// There is exactly one interleaved layout, [kGpuFloatsPerVertex] floats wide,
/// and every pipeline reads a subset of it:
///
///     offset  0  x, y                 device pixels
///     offset  2  u, v                 texture coordinates, 0..1
///     offset  4  r, g, b, a           premultiplied, 0..1
///     offset  8  cl, ct, cr, cb       the exact shape rect, device pixels
///
/// A solid fill leaves u,v at zero; a textured image leaves the coverage rect
/// at its own quad, where it evaluates to full coverage. That wastes 32 bytes
/// per textured vertex, and it buys a single vertex array object, a single
/// buffer upload per frame and a batcher that never has to ask "do these two
/// primitives even have the same stride?" before merging them. For a UI, where
/// vertex counts are in the thousands and not the millions, that is the right
/// side of the trade - and it is a trade a profile can revisit without
/// touching anything above this file.
///
/// ## Why the colour is premultiplied here and not in the shader
///
/// The framework's compositor is premultiplied end to end (`blend.dart`,
/// `PixelFormat`). Premultiplying at vertex-write time means the blend state
/// for source-over is the plain `(ONE, ONE_MINUS_SRC_ALPHA)` every API
/// spells the same way, and a coverage multiply is a single scalar multiply
/// of all four channels rather than a special case for alpha. Doing it in the
/// fragment shader instead would run it per pixel to save four multiplies per
/// vertex.
library;

import '../../graphics/display_list_opcodes.dart';

/// What the fragment stage does with a batch's vertices.
enum GpuPipelineKind {
  /// Solid colour with analytic coverage against the vertex's shape rect.
  ///
  /// This is the antialiasing for axis-aligned rectangles: the fragment
  /// shader computes the exact area of the pixel square that the rect covers,
  /// which for an axis-aligned rect is separable and costs two clamps and a
  /// multiply. It is the same quantity `raster/coverage.dart` computes on the
  /// CPU, so the two rasterisers disagree only by the CPU's deliberate
  /// quantisation of positions to 1/255ths of a pixel.
  solid,

  /// Solid colour modulated by an [GpuTextureFormat.alpha8] coverage mask.
  ///
  /// Paths and rounded rectangles arrive this way: their coverage was
  /// computed by the CPU scanline filler and uploaded to an atlas. See
  /// `gpu_mask_atlas.dart` for why that is the chosen antialiasing strategy.
  coverageMask,

  /// A premultiplied RGBA texture modulated by the vertex colour.
  texturedImage,
}

/// Blend factors, named as the two APIs that matter both name them.
///
/// Three of them, because the three blend modes the display list can encode
/// (`blendModeSrcOver`, `blendModeSrc`, `blendModePlus`) need exactly these.
/// A fourth factor arriving here means the display list grew a mode, and the
/// compiler will point at [gpuBlendForMode].
enum GpuBlendFactor { zero, one, oneMinusSrcAlpha }

/// The fixed-function blend a batch is drawn with.
final class GpuBlendState {
  const GpuBlendState(this.source, this.destination);

  final GpuBlendFactor source;
  final GpuBlendFactor destination;

  @override
  bool operator ==(Object other) =>
      other is GpuBlendState &&
      other.source == source &&
      other.destination == destination;

  @override
  int get hashCode => Object.hash(source, destination);

  @override
  String toString() => 'GpuBlendState(${source.name}, ${destination.name})';
}

/// The blend state for one of the display list's `blendMode*` constants.
///
/// Throws rather than defaulting to source-over. A blend mode that silently
/// becomes source-over draws a picture that is wrong in a way that looks like
/// a paint bug, and section 23.7 of the roadmap requires CPU/GPU parity per
/// mode to be *measured*, which is impossible if one side quietly substitutes.
GpuBlendState gpuBlendForMode(int blendMode) => switch (blendMode) {
      // dst = src + dst * (1 - a), the premultiplied source-over of blend.dart.
      blendModeSrcOver =>
        const GpuBlendState(GpuBlendFactor.one, GpuBlendFactor.oneMinusSrcAlpha),
      blendModeSrc =>
        const GpuBlendState(GpuBlendFactor.one, GpuBlendFactor.zero),
      blendModePlus =>
        const GpuBlendState(GpuBlendFactor.one, GpuBlendFactor.one),
      _ => throw ArgumentError.value(
          blendMode,
          'blendMode',
          'no GPU blend state; the display list encodes only srcOver, src '
              'and plus, and a new mode must be given factors here rather '
              'than falling back to srcOver',
        ),
    };

/// Floats per vertex in the one interleaved layout. See the library comment.
const int kGpuFloatsPerVertex = 12;

/// Offset of `x, y` within a vertex.
const int kGpuPositionOffset = 0;

/// Offset of `u, v` within a vertex.
const int kGpuTexCoordOffset = 2;

/// Offset of premultiplied `r, g, b, a` within a vertex.
const int kGpuColorOffset = 4;

/// Offset of the exact device-space shape rect `l, t, r, b` within a vertex.
const int kGpuShapeRectOffset = 8;

/// A quad is four vertices and two triangles.
///
/// Indexed rather than six duplicated vertices: 4 * 12 floats plus 6 indices
/// is 216 bytes against 288, and the index buffer is the thing a future
/// instanced path would replace anyway.
const int kGpuVerticesPerQuad = 4;
const int kGpuIndicesPerQuad = 6;
